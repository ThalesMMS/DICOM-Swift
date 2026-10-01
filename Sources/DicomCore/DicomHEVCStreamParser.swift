import Foundation

enum DicomHEVCStreamParser {
    static func parse(_ units: [DicomVideoNALUnit], count: Int) throws -> DicomVideoStreamDescription {
        var result = DicomVideoStreamDescription(codec: .hevc)
        guard let sps = units.first(where: { $0.type == 33 }),
              let pps = units.first(where: { $0.type == 34 }), let vps = units.first(where: { $0.type == 32 }) else {
            throw DicomVideoInspectionError.malformedStream
        }
        try videoParameters(vps.payload, result: &result)
        try sequence(sps.payload, result: &result)
        result.entropyCodingMode = true // HEVC entropy coding is CABAC.
        for type in [32, 33, 34] {
            let values = units.filter { $0.type == type }.map(\.payload)
            if values.contains(where: { $0 != values.first }) { result.limitations.append("HEVC-changing-parameter-sets") }
        }
        var bits = DicomVideoBits(pps.payload, headerBytes: 2)
        _ = try bits.ue(); _ = try bits.ue()
        let dependent = try bits.read(1)
        let outputFlag = try bits.read(1)
        let extra = try bits.read(3)
        var pending = 0
        var start: Int?
        var typeName = ""
        var key = false
        var order: Int?
        var msb = 0
        var previousLSB = 0
        var previousMSB = 0
        var groupStart = 0
        func flush(_ end: Int) {
            guard let start else { return }
            result.accessUnits.append(.init(decodeIndex: result.accessUnits.count,
                byteRange: start..<end, sliceType: typeName, isKeyFrame: key, pictureOrderCount: order))
        }
        for unit in units {
            if [32, 33, 34, 35, 39].contains(unit.type), start != nil {
                flush(unit.byteRange.lowerBound); start = nil; pending = unit.byteRange.lowerBound
            }
            guard unit.type <= 31 else { continue }
            var header = DicomVideoBits(unit.payload, headerBytes: 2)
            guard try header.read(1) == 1 else {
                result.limitations.append("multi-slice"); continue
            }
            if start != nil { flush(unit.byteRange.lowerBound); pending = unit.byteRange.lowerBound }
            start = pending
            let irap = (16...23).contains(unit.type)
            if irap { _ = try header.read(1) }
            _ = try header.ue()
            _ = try header.read(extra)
            let sliceType = try header.ue()
            guard sliceType <= 2 else { throw DicomVideoInspectionError.malformedStream }
            typeName = ["B", "P", "I"][sliceType]
            key = unit.type == 19 || unit.type == 20
            if outputFlag == 1 { _ = try header.read(1) }
            if key { order = 0; previousLSB = 0; previousMSB = 0; msb = 0 }
            else {
                let width = result.log2MaxPicOrderCntLSB!
                guard (4...16).contains(width) else { throw DicomVideoInspectionError.malformedStream }
                let lsb = try header.read(width)
                let maximum = 1 << width
                msb = previousMSB
                if lsb < previousLSB, previousLSB - lsb >= maximum / 2 { msb += maximum }
                else if lsb > previousLSB, lsb - previousLSB > maximum / 2 { msb -= maximum }
                order = msb + lsb
                // prevTid0Pic excludes RASL/RADL and sub-layer non-reference pictures.
                let temporalID = Int(unit.payload[unit.payload.startIndex + 1] & 7) - 1
                if temporalID == 0, ![0, 2, 4, 6, 7, 8, 9].contains(unit.type) {
                    previousLSB = lsb; previousMSB = msb
                }
            }
            if irap && !key { result.limitations.append("HEVC-open-GOP-CRA-BLA") }
        }
        flush(count)
        guard !result.accessUnits.isEmpty else { throw DicomVideoInspectionError.malformedStream }
        var qualified = result.accessUnits.first?.isKeyFrame == true && !result.limitations.contains("HEVC-open-GOP-CRA-BLA") && !result.limitations.contains("HEVC-changing-parameter-sets")
        for index in result.accessUnits.indices {
            if result.accessUnits[index].isKeyFrame { groupStart = index }
            if let poc = result.accessUnits[index].pictureOrderCount {
                result.accessUnits[index].presentationIndex = groupStart + poc
            } else { qualified = false }
        }
        let presentation = result.accessUnits.compactMap(\.presentationIndex).sorted()
        qualified = qualified && presentation == Array(result.accessUnits.indices)
        result.closedGOP = qualified ? true : nil
        if !qualified { result.limitations.append("HEVC-unqualified-picture-order") }
        if dependent == 1 { result.limitations.append("HEVC-dependent-slice-segments-not-qualified") }
        result.limitations.append("HEVC-reference-picture-dependencies-not-qualified")
        return result
    }

    private static func videoParameters(_ data: Data, result: inout DicomVideoStreamDescription) throws {
        var bits = DicomVideoBits(data, headerBytes: 2)
        result.videoParameterSetID = try bits.read(4)
        _ = try bits.read(2)
        let layers = try bits.read(6)
        let subLayers = try bits.read(3)
        result.maximumSubLayers = subLayers + 1
        _ = try bits.read(1)
        guard try bits.read(16) == 0xFFFF else { throw DicomVideoInspectionError.malformedStream }
        _ = try bits.read(3)
        result.vpsProfileIDC = try bits.read(5)
        _ = try bits.read(32); _ = try bits.read(32); _ = try bits.read(16)
        result.vpsLevelIDC = try bits.read(8)
        var flags: [(Int, Int)] = []
        for _ in 0..<subLayers { flags.append((try bits.read(1), try bits.read(1))) }
        if subLayers > 0 { for _ in subLayers..<8 { _ = try bits.read(2) } }
        for flag in flags {
            if flag.0 == 1 { _ = try bits.read(32); _ = try bits.read(32); _ = try bits.read(24) }
            if flag.1 == 1 { _ = try bits.read(8) }
        }
        let allLayers = try bits.read(1)
        for _ in (allLayers == 1 ? 0 : subLayers)...subLayers {
            _ = try bits.ue(); _ = try bits.ue(); _ = try bits.ue()
        }
        let maximumLayerID = try bits.read(6)
        let layerSets = try bits.ue()
        guard layerSets <= 1023 else { throw DicomVideoInspectionError.malformedStream }
        for _ in 0..<layerSets { for _ in 0...maximumLayerID { _ = try bits.read(1) } }
        if try bits.read(1) == 1 {
            result.vpsNumUnitsInTick = try bits.read(32)
            result.vpsTimeScale = try bits.read(32)
        }
        if layers != 0 { result.limitations.append("HEVC-multilayer") }
    }

    private static func sequence(_ data: Data, result: inout DicomVideoStreamDescription) throws {
        var bits = DicomVideoBits(data, headerBytes: 2)
        _ = try bits.read(4)
        let layers = try bits.read(3)
        _ = try bits.read(1)
        _ = try bits.read(3)
        let profile = try bits.read(5)
        result.profileIDC = profile
        result.profile = [1: "Main", 2: "Main 10", 3: "Main Still Picture"][profile]
        _ = try bits.read(32)
        let progressive = try bits.read(1)
        let interlaced = try bits.read(1)
        _ = try bits.read(32); _ = try bits.read(14)
        result.levelIDC = try bits.read(8)
        result.frameMbsOnly = progressive == 1 && interlaced == 0
        var flags: [(Int, Int)] = []
        for _ in 0..<layers { flags.append((try bits.read(1), try bits.read(1))) }
        if layers > 0 { for _ in layers..<8 { _ = try bits.read(2) } }
        for flag in flags {
            if flag.0 == 1 { _ = try bits.read(32); _ = try bits.read(32); _ = try bits.read(24) }
            if flag.1 == 1 { _ = try bits.read(8) }
        }
        _ = try bits.ue()
        let chroma = try bits.ue()
        guard chroma <= 3 else { throw DicomVideoInspectionError.malformedStream }
        result.chromaFormat = chroma
        if chroma == 3 { _ = try bits.read(1) }
        var width = try bits.ue()
        var height = try bits.ue()
        if try bits.read(1) == 1 {
            let left = try bits.ue(), right = try bits.ue(), top = try bits.ue(), bottom = try bits.ue()
            width -= (left + right) * (chroma == 1 || chroma == 2 ? 2 : 1)
            height -= (top + bottom) * (chroma == 1 ? 2 : 1)
        }
        guard width > 0, height > 0 else { throw DicomVideoInspectionError.malformedStream }
        result.width = width; result.height = height
        result.bitDepth = try bits.ue() + 8
        result.chromaBitDepth = try bits.ue() + 8
        result.log2MaxPicOrderCntLSB = try bits.ue() + 4
        let allLayers = try bits.read(1)
        for _ in (allLayers == 1 ? 0 : layers)...layers { _ = try bits.ue(); _ = try bits.ue(); _ = try bits.ue() }
        for _ in 0..<6 { _ = try bits.ue() }
        if try bits.read(1) == 1, try bits.read(1) == 1 {
            for size in 0..<4 {
                for _ in stride(from: 0, to: 6, by: size == 3 ? 3 : 1) {
                    if try bits.read(1) == 0 { _ = try bits.ue() }
                    else {
                        if size > 1 { _ = try bits.se() }
                        for _ in 0..<min(64, 1 << (4 + (size << 1))) { _ = try bits.se() }
                    }
                }
            }
        }
        _ = try bits.read(2)
        if try bits.read(1) == 1 {
            _ = try bits.read(8); _ = try bits.ue(); _ = try bits.ue(); _ = try bits.read(1)
        }
        let sets = try bits.ue()
        guard sets <= 64 else { throw DicomVideoInspectionError.malformedStream }
        var deltas: [Int] = []
        for index in 0..<sets {
            if index > 0, try bits.read(1) == 1 {
                _ = try bits.read(1); _ = try bits.ue()
                var count = 0
                for _ in 0...deltas[index - 1] {
                    let used = try bits.read(1)
                    if used == 1 { count += 1 }
                    else if try bits.read(1) == 1 { count += 1 }
                }
                deltas.append(count)
            } else {
                let negative = try bits.ue(), positive = try bits.ue()
                guard negative + positive <= 64 else { throw DicomVideoInspectionError.malformedStream }
                for _ in 0..<(negative + positive) { _ = try bits.ue(); _ = try bits.read(1) }
                deltas.append(negative + positive)
            }
        }
        if try bits.read(1) == 1 {
            let count = try bits.ue()
            guard count <= 32 else { throw DicomVideoInspectionError.malformedStream }
            for _ in 0..<count { _ = try bits.read(result.log2MaxPicOrderCntLSB!); _ = try bits.read(1) }
        }
        _ = try bits.read(2)
        if try bits.read(1) == 1 {
            if try bits.read(1) == 1, try bits.read(8) == 255 { _ = try bits.read(16); _ = try bits.read(16) }
            if try bits.read(1) == 1 { _ = try bits.read(1) }
            if try bits.read(1) == 1 {
                _ = try bits.read(4)
                if try bits.read(1) == 1 { _ = try bits.read(24) }
            }
            if try bits.read(1) == 1 { _ = try bits.ue(); _ = try bits.ue() }
            _ = try bits.read(3)
            if try bits.read(1) == 1 { for _ in 0..<4 { _ = try bits.ue() } }
            if try bits.read(1) == 1 {
                result.numUnitsInTick = try bits.read(32)
                result.timeScale = try bits.read(32)
            }
        }
        result.limitations.append("HEVC-HRD-SEI-and-extensions-not-parsed")
    }
}
