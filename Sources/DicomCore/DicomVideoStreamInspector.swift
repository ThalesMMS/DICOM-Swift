import Foundation

public struct DicomVideoNALUnit: Equatable, Sendable {
    public let type: Int
    /// Range includes the start code or length prefix in the original stream.
    public let byteRange: Range<Int>
    public let payload: Data
}

public struct DicomVideoAccessUnit: Equatable, Sendable {
    public let decodeIndex: Int
    public var presentationIndex: Int?
    public let byteRange: Range<Int>
    public let sliceType: String
    public let isKeyFrame: Bool
    public var pictureOrderCount: Int?
    public var temporalReference: Int?
}

public struct DicomVideoStreamDescription: Equatable, Sendable {
    public let codec: DicomVideoCodec
    public var framing = "Annex B"
    public var nalUnits: [DicomVideoNALUnit] = []
    public var accessUnits: [DicomVideoAccessUnit] = []
    public var profile: String?
    public var profileIDC: Int?
    public var videoParameterSetID: Int?
    public var maximumSubLayers: Int?
    public var vpsProfileIDC: Int?
    public var vpsLevelIDC: Int?
    public var vpsNumUnitsInTick: Int?
    public var vpsTimeScale: Int?
    public var levelIDC: Int?
    public var width: Int?
    public var height: Int?
    public var chromaFormat: Int?
    public var bitDepth: Int?
    public var chromaBitDepth: Int?
    public var picOrderCntType: Int?
    public var log2MaxFrameNum: Int?
    public var log2MaxPicOrderCntLSB: Int?
    public var frameMbsOnly: Bool?
    public var entropyCodingMode: Bool?
    public var numUnitsInTick: Int?
    public var timeScale: Int?
    public var fixedFrameRateFlag: Bool?
    public var frameRateCode: Int?
    public var bitRate: Int?
    public var closedGOP: Bool?
    public var limitations: [String] = []

    public struct GOP: Equatable, Sendable {
        public let decodeRange: Range<Int>
        public let closed: Bool?
    }

    public var gops: [GOP] {
        guard !accessUnits.isEmpty else { return [] }
        let starts = Array(Set([0] + accessUnits.filter(\.isKeyFrame).map(\.decodeIndex))).sorted()
        return starts.enumerated().map { index, start in
            GOP(decodeRange: start..<(index + 1 < starts.count ? starts[index + 1] : accessUnits.count), closed: closedGOP)
        }
    }
}

public enum DicomVideoStreamInspector {
    public static func inspect(_ stream: Data, codec: DicomVideoCodec) throws -> DicomVideoStreamDescription {
        guard !stream.isEmpty else { throw DicomVideoInspectionError.malformedStream }
        if codec == .mpeg2 { return try DicomMPEG2StreamParser.parse(stream) }
        guard codec == .h264 || codec == .hevc else { throw DicomVideoInspectionError.unsupported("codec") }
        let (units, framing) = try nalUnits(stream, codec: codec)
        var result = codec == .h264 ? try DicomH264Inspector.parse(units, count: stream.count) :
            try DicomHEVCStreamParser.parse(units, count: stream.count)
        result.nalUnits = units
        result.framing = framing
        return result
    }

    static func nalUnits(_ data: Data, codec: DicomVideoCodec) throws -> ([DicomVideoNALUnit], String) {
        let bytes = [UInt8](data)
        var starts: [(Int, Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 { starts.append((index, 3)); index += 3; continue }
                if index + 4 <= bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append((index, 4)); index += 4; continue
                }
            }
            index += 1
        }
        func unit(_ start: Int, _ payload: Int, _ end: Int) throws -> DicomVideoNALUnit {
            guard payload < end, codec != .hevc || end - payload >= 2,
                  bytes[payload] & 0x80 == 0 else { throw DicomVideoInspectionError.malformedStream }
            return .init(type: codec == .h264 ? Int(bytes[payload] & 31) : Int(bytes[payload] >> 1 & 63),
                         byteRange: start..<end, payload: Data(bytes[payload..<end]))
        }
        // A complete length-prefixed partition takes precedence over a coincidental
        // 00 00 01 inside a length (for example a 256-byte first parameter set).
        for width in [4, 2, 1] {
            var cursor = 0
            var result: [DicomVideoNALUnit] = []
            while cursor + width <= bytes.count {
                let length = bytes[cursor..<cursor + width].reduce(0) { $0 << 8 | Int($1) }
                guard length > 0, length <= bytes.count - cursor - width,
                      let value = try? unit(cursor, cursor + width, cursor + width + length) else { break }
                result.append(value)
                cursor += width + length
            }
            if cursor == bytes.count, !result.isEmpty { return (result, "length-prefixed-\(width)") }
        }
        // A start code is framing evidence only at the beginning, never inside a length-prefixed payload.
        if let first = starts.first, bytes[..<first.0].allSatisfy({ $0 == 0 }) {
            var result: [DicomVideoNALUnit] = []
            for (i, start) in starts.enumerated() {
                result.append(try unit(start.0, start.0 + start.1, i + 1 < starts.count ? starts[i + 1].0 : bytes.count))
            }
            return (result, "Annex B")
        }
        throw DicomVideoInspectionError.malformedStream
    }
}
