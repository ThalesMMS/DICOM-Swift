import Foundation

/// The qualified Annex-B reordering subset: progressive Main/High 8-bit 4:2:0,
/// POC type 0 with non-reference B pictures or type 2 with IP-only pictures,
/// one slice per picture, and closed IDR GOPs.
/// Header syntax and POC derivation follow H.264 sections 7.3 and 8.2.1.1.
public enum DicomH264StreamPictureOrder {
    private static var unsupported: DicomVideoInspectionError {
        .unsupported("H264-qualified-POC-subset")
    }

    public static func presentationIndices(nalUnits: [Data], accessUnitCount: Int) throws -> [Int] {
        guard let sps = nalUnits.first(where: { $0.first.map { $0 & 31 == 7 } ?? false }),
              let pps = nalUnits.first(where: { $0.first.map { $0 & 31 == 8 } ?? false }) else {
            throw unsupported
        }
        let sequence = try Sequence(sps)
        let pictureID = try readPictureID(pps, sequenceID: sequence.id)
        var orders: [Int] = []
        var result: [Int] = []
        var previousMSB = 0
        var previousLSB = 0
        var previousFrameNumber = 0
        var frameOffset = 0

        func flushGOP() throws {
            guard !orders.isEmpty else { return }
            // This subset has one progressive picture per supplied frame duration.
            // Reject duplicate, missing, negative, or field-based picture orders.
            let sorted = orders.sorted()
            guard sorted.enumerated().allSatisfy({ $0.element == $0.offset * 2 }) else {
                throw unsupported
            }
            let start = result.count
            result.append(contentsOf: orders.map { start + $0 / 2 })
            orders.removeAll(keepingCapacity: true)
        }

        for data in nalUnits {
            guard let header = data.first, header & 0x80 == 0 else { throw unsupported }
            let type = header & 31
            switch type {
            case 7:
                guard data == sps else { throw unsupported }
                continue
            case 8:
                guard data == pps else { throw unsupported }
                continue
            case 6, 9, 10, 11, 12:
                continue
            case 1, 5:
                break
            default:
                throw unsupported
            }
            let isIDR = type == 5
            let isReference = header & 0x60 != 0
            var bits = Bits(data)
            guard try bits.ue() == 0 else { throw unsupported } // No multi-slice pictures.
            let rawSliceType = try bits.ue()
            let sliceType = rawSliceType % 5
            guard rawSliceType <= 9, sliceType <= 2,
                  try bits.ue() == pictureID,
                  (sliceType == 1 ? !isReference : isReference),
                  sliceType != 2 || isIDR else { throw unsupported }
            let frameNumber = try bits.read(sequence.frameNumberBits)
            if isIDR {
                guard sliceType == 2, isReference, frameNumber == 0 else { throw unsupported }
                _ = try bits.ue() // idr_pic_id
                try flushGOP()
                previousMSB = 0
                previousLSB = 0
                previousFrameNumber = 0
                frameOffset = 0
            } else if orders.isEmpty {
                throw unsupported // Random access must start at an IDR.
            }
            let lsb: Int
            if sequence.orderType == 2 {
                guard sliceType != 1 else { throw unsupported }
                if frameNumber < previousFrameNumber { frameOffset += 1 << sequence.frameNumberBits }
                lsb = 2 * (frameOffset + frameNumber)
                previousFrameNumber = frameNumber
            } else { lsb = try bits.read(sequence.orderBits) }
            if isIDR, lsb != 0 { throw unsupported }
            if sliceType == 1 { _ = try bits.read(1) } // direct_spatial_mv_pred_flag
            if sliceType != 2 {
                if try bits.read(1) != 0 {
                    guard try bits.ue() <= 31 else { throw unsupported }
                    if sliceType == 1, try bits.ue() > 31 { throw unsupported }
                }
                try skipReferenceList(&bits)
                if sliceType == 1 { try skipReferenceList(&bits) }
            }
            if isReference {
                if isIDR {
                    // Neither discard pending output nor establish long-term references.
                    guard try bits.read(2) == 0 else { throw unsupported }
                } else {
                    // Adaptive marking (including MMCO 5 POC reset) is not qualified.
                    guard try bits.read(1) == 0 else { throw unsupported }
                }
            }
            let maximumLSB = 1 << sequence.orderBits
            var msb = previousMSB
            if sequence.orderType == 0, lsb < previousLSB, previousLSB - lsb >= maximumLSB / 2 {
                msb += maximumLSB
            } else if sequence.orderType == 0, lsb > previousLSB, lsb - previousLSB > maximumLSB / 2 {
                msb -= maximumLSB
            }
            orders.append(msb + lsb)
            if isReference {
                previousMSB = msb
                previousLSB = lsb
            }
        }
        try flushGOP()
        guard result.count == accessUnitCount else { throw unsupported }
        return result
    }

    private static func readPictureID(_ data: Data, sequenceID: Int) throws -> Int {
        var bits = Bits(data)
        let id = try bits.ue()
        guard id <= 255, try bits.ue() == sequenceID else { throw unsupported }
        _ = try bits.read(1) // entropy_coding_mode_flag: CABAC and CAVLC are both allowed.
        guard try bits.read(1) == 0, try bits.ue() == 0,
              try bits.ue() <= 31, try bits.ue() <= 31,
              try bits.read(1) == 0, try bits.read(2) == 0 else { throw unsupported }
        // Signed Exp-Golomb fields have the same codeword length as unsigned fields.
        _ = try bits.ue() // pic_init_qp_minus26
        _ = try bits.ue() // pic_init_qs_minus26
        _ = try bits.ue() // chroma_qp_index_offset
        _ = try bits.read(2) // deblocking_filter_control_present / constrained_intra_pred
        guard try bits.read(1) == 0 else { throw unsupported } // redundant_pic_cnt_present
        return id
    }

    private static func skipReferenceList(_ bits: inout Bits) throws {
        guard try bits.read(1) != 0 else { return }
        // At most 32 active references plus the terminating command.
        for _ in 0...32 {
            let operation = try bits.ue()
            if operation == 3 { return }
            guard operation <= 1 else { throw unsupported } // No long-term references.
            _ = try bits.ue()
        }
        throw unsupported
    }

    private struct Sequence {
        let id: Int
        let frameNumberBits: Int
        let orderBits: Int
        let orderType: Int

        init(_ data: Data) throws {
            var bits = Bits(data)
            let profile = try bits.read(8)
            guard profile == 77 || profile == 100 else { throw unsupported }
            _ = try bits.read(16) // constraint flags and level_idc
            id = try bits.ue()
            guard id <= 31 else { throw unsupported }
            if profile == 100 {
                guard try bits.ue() == 1, try bits.ue() == 0, try bits.ue() == 0,
                      try bits.read(2) == 0 else { throw unsupported }
            }
            let frameBitsMinus4 = try bits.ue()
            orderType = try bits.ue()
            guard frameBitsMinus4 <= 12, orderType == 0 || orderType == 2 else { throw unsupported }
            let orderBitsMinus4 = orderType == 0 ? try bits.ue() : 0
            guard orderBitsMinus4 <= 12, try bits.ue() <= 16,
                  try bits.read(1) == 0 else { throw unsupported }
            frameNumberBits = frameBitsMinus4 + 4
            orderBits = orderBitsMinus4 + 4
            _ = try bits.ue() // pic_width_in_mbs_minus1
            _ = try bits.ue() // pic_height_in_map_units_minus1
            guard try bits.read(1) == 1 else { throw unsupported }
        }
    }

    private struct Bits {
        private let bytes: [UInt8]
        private var offset = 0

        init(_ nal: Data) {
            var result: [UInt8] = []
            var zeroCount = 0
            for byte in nal.dropFirst() {
                if zeroCount == 2, byte == 3 {
                    zeroCount = 0
                    continue
                }
                result.append(byte)
                zeroCount = byte == 0 ? zeroCount + 1 : 0
            }
            bytes = result
        }

        mutating func read(_ count: Int) throws -> Int {
            guard offset + count <= bytes.count * 8 else { throw unsupported }
            var value = 0
            for _ in 0..<count {
                value = (value << 1) | Int((bytes[offset / 8] >> (7 - offset % 8)) & 1)
                offset += 1
            }
            return value
        }

        mutating func ue() throws -> Int {
            var zeros = 0
            while try read(1) == 0 {
                zeros += 1
                guard zeros <= 31 else { throw unsupported }
            }
            return (1 << zeros) - 1 + (try read(zeros))
        }
    }
}

/// Header inspection is broader than the separately qualified POC operation.
enum DicomH264Inspector {
    static func parse(_ units: [DicomVideoNALUnit], count: Int) throws -> DicomVideoStreamDescription {
        var result = DicomVideoStreamDescription(codec: .h264)
        guard let sps = units.first(where: { $0.type == 7 }),
              let pps = units.first(where: { $0.type == 8 }) else {
            throw DicomVideoInspectionError.malformedStream
        }
        try sequence(sps.payload, result: &result)
        var picture = DicomVideoBits(pps.payload)
        _ = try picture.ue()
        _ = try picture.ue()
        result.entropyCodingMode = try picture.read(1) == 1
        var pendingStart = 0
        var start: Int?
        var slice = ""
        var key = false
        func flush(_ end: Int) {
            guard let current = start else { return }
            result.accessUnits.append(.init(decodeIndex: result.accessUnits.count,
                byteRange: current..<end, sliceType: slice, isKeyFrame: key))
            start = nil
        }
        for unit in units {
            if [6, 7, 8, 9].contains(unit.type), start != nil {
                flush(unit.byteRange.lowerBound)
                pendingStart = unit.byteRange.lowerBound
            }
            guard unit.type == 1 || unit.type == 5 else { continue }
            var bits = DicomVideoBits(unit.payload)
            let first = try bits.ue()
            let type = try bits.ue()
            guard type <= 9 else { throw DicomVideoInspectionError.malformedStream }
            if first == 0 {
                if start != nil { flush(unit.byteRange.lowerBound); pendingStart = unit.byteRange.lowerBound }
                start = pendingStart
                slice = ["P", "B", "I", "SP", "SI"][type % 5]
                key = unit.type == 5
            } else if !result.limitations.contains("multi-slice") { result.limitations.append("multi-slice") }
        }
        flush(count)
        guard !result.accessUnits.isEmpty else { throw DicomVideoInspectionError.malformedStream }
        do {
            let order = try DicomH264StreamPictureOrder.presentationIndices(
                nalUnits: units.map(\.payload), accessUnitCount: result.accessUnits.count)
            var gopStart = 0
            for index in result.accessUnits.indices {
                if result.accessUnits[index].isKeyFrame { gopStart = index }
                result.accessUnits[index].presentationIndex = order[index]
                result.accessUnits[index].pictureOrderCount = (order[index] - gopStart) * 2
            }
            result.closedGOP = true
        } catch {
            result.limitations.append("H264-qualified-POC-subset: B-pyramid, interlace, multi-slice, open-GOP or unqualified headers")
            result.closedGOP = nil
        }
        return result
    }

    private static func sequence(_ data: Data, result: inout DicomVideoStreamDescription) throws {
        var bits = DicomVideoBits(data)
        let profile = try bits.read(8)
        result.profileIDC = profile
        result.profile = [66: "Baseline", 77: "Main", 100: "High", 110: "High 10", 122: "High 4:2:2", 244: "High 4:4:4 Predictive"][profile]
        _ = try bits.read(8)
        result.levelIDC = try bits.read(8)
        _ = try bits.ue()
        var chroma = 1
        var depth = 8
        var chromaDepth = 8
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            chroma = try bits.ue()
            guard chroma <= 3 else { throw DicomVideoInspectionError.malformedStream }
            if chroma == 3 { _ = try bits.read(1) }
            depth = try bits.ue() + 8
            chromaDepth = try bits.ue() + 8
            _ = try bits.read(1)
            if try bits.read(1) == 1 {
                for index in 0..<(chroma == 3 ? 12 : 8) {
                    if try bits.read(1) == 1 {
                        var last = 8
                        var next = 8
                        for _ in 0..<(index < 6 ? 16 : 64) {
                            if next != 0 { next = (last + (try bits.se()) + 256) % 256 }
                            last = next == 0 ? last : next
                        }
                    }
                }
            }
        }
        result.chromaFormat = chroma
        result.bitDepth = depth
        result.chromaBitDepth = chromaDepth
        result.log2MaxFrameNum = try bits.ue() + 4
        let pocType = try bits.ue()
        result.picOrderCntType = pocType
        if pocType == 0 { result.log2MaxPicOrderCntLSB = try bits.ue() + 4 }
        else if pocType == 1 {
            _ = try bits.read(1)
            _ = try bits.se()
            _ = try bits.se()
            let cycle = try bits.ue()
            guard cycle <= 255 else { throw DicomVideoInspectionError.malformedStream }
            for _ in 0..<cycle { _ = try bits.se() }
        } else if pocType != 2 { throw DicomVideoInspectionError.malformedStream }
        _ = try bits.ue()
        _ = try bits.read(1)
        let width = try bits.ue() + 1
        let height = try bits.ue() + 1
        let progressive = try bits.read(1)
        result.frameMbsOnly = progressive == 1
        if progressive == 0 { _ = try bits.read(1); result.limitations.append("interlace") }
        _ = try bits.read(1)
        var crop = [0, 0, 0, 0]
        if try bits.read(1) == 1 { for index in crop.indices { crop[index] = try bits.ue() } }
        let subWidth = chroma == 1 || chroma == 2 ? 2 : 1
        let subHeight = chroma == 1 ? 2 : 1
        result.width = width * 16 - (crop[0] + crop[1]) * subWidth
        result.height = height * 16 * (2 - progressive) - (crop[2] + crop[3]) * subHeight * (2 - progressive)
        guard result.width! > 0, result.height! > 0 else { throw DicomVideoInspectionError.malformedStream }
        if try bits.read(1) == 1 {
            if try bits.read(1) == 1, try bits.read(8) == 255 { _ = try bits.read(16); _ = try bits.read(16) }
            if try bits.read(1) == 1 { _ = try bits.read(1) }
            if try bits.read(1) == 1 {
                _ = try bits.read(4)
                if try bits.read(1) == 1 { _ = try bits.read(24) }
            }
            if try bits.read(1) == 1 { _ = try bits.ue(); _ = try bits.ue() }
            if try bits.read(1) == 1 {
                result.numUnitsInTick = try bits.read(32)
                result.timeScale = try bits.read(32)
                result.fixedFrameRateFlag = try bits.read(1) == 1
            }
            result.limitations.append("VUI-HRD-and-SEI-timing-not-parsed")
        }
    }
}
