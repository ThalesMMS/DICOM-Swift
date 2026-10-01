import Foundation

public enum DicomVideoInspectionError: Error, Equatable, Sendable {
    case malformedStream
    case unsupported(String)
    case unknownTiming
    case openGOPDependencies
    case invalidTimeRange
    case outputLimitExceeded
}

public struct DicomVideoDiagnostic: Equatable, Sendable {
    public enum Code: String, Sendable {
        case frameCountMismatch, cineTimingMismatch, unknownTiming, unsupportedOrdering
    }
    public let code: Code
    public let message: String
}

/// Bounds-checked bit reader with optional NAL unescaping.
/// Exp-Golomb values are limited before shifts or allocation.
struct DicomVideoBits {
    let bytes: [UInt8]
    var offset = 0

    init(_ data: Data, headerBytes: Int = 1, removeEmulationPreventionBytes: Bool = true) {
        var result: [UInt8] = []
        var zeros = 0
        for byte in data.dropFirst(headerBytes) {
            if removeEmulationPreventionBytes, zeros >= 2, byte == 3 { zeros = 0; continue }
            result.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        bytes = result
    }

    mutating func read(_ count: Int) throws -> Int {
        guard (0...32).contains(count), offset <= bytes.count * 8 - count else {
            throw DicomVideoInspectionError.malformedStream
        }
        var value = 0
        for _ in 0..<count {
            value = value << 1 | Int(bytes[offset / 8] >> (7 - offset % 8) & 1)
            offset += 1
        }
        return value
    }

    mutating func ue() throws -> Int {
        var zeros = 0
        while try read(1) == 0 {
            zeros += 1
            guard zeros <= 30 else { throw DicomVideoInspectionError.malformedStream }
        }
        return (1 << zeros) - 1 + (try read(zeros))
    }

    mutating func se() throws -> Int {
        let value = try ue()
        return value.isMultiple(of: 2) ? -value / 2 : (value + 1) / 2
    }
}
