import Foundation

/// Marker-level evidence from one JPEG-LS (ISO/IEC 14495-1) frame: SOF55, LSE preset parameters and every scan
/// header up to EOI. Entropy-coded segments are skipped byte-wise; nothing is decoded.
public enum DicomJPEGLSFrameInspector {
    public enum Failure: Error, Equatable, Sendable { case invalidStream, unsupportedProcess, limitExceeded }

    public struct Component: Equatable, Sendable {
        public let identifier: UInt8
        public let horizontalSampling: Int
        public let verticalSampling: Int
    }

    public struct Scan: Equatable, Sendable {
        public let componentIdentifiers: [UInt8]
        /// NEAR: 0 for lossless, otherwise the near-lossless error bound.
        public let near: Int
        /// ILV: 0 none, 1 line, 2 sample interleaved.
        public let interleaveMode: Int
        public let pointTransform: Int
    }

    public struct Inspection: Equatable, Sendable {
        public let precision: Int
        public let width: Int
        public let height: Int
        public let components: [Component]
        public let scans: [Scan]
        /// MAXVAL from an LSE preset segment, when present.
        public let maximumSampleValue: Int?
        public var isLossless: Bool { scans.allSatisfy { $0.near == 0 } }
    }

    public static func inspect(_ data: Data, maximumEncodedBytes: Int = 64 * 1024 * 1024) throws -> Inspection {
        guard data.count <= max(0, maximumEncodedBytes) else { throw Failure.limitExceeded }
        return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw Failure.invalidStream }
            func word(_ index: Int) -> Int { Int(bytes[index]) << 8 | Int(bytes[index + 1]) }
            var cursor = 2, entropy = false, sawFrame = false
            var precision = 0, width = 0, height = 0, maximum: Int?
            var components: [Component] = [], scans: [Scan] = []
            var scanned: Set<UInt8> = []
            while cursor < bytes.count {
                if entropy {
                    // JPEG-LS stuffs a zero bit after 0xFF, so 0xFF followed by a byte below 0x80 stays entropy data.
                    while cursor < bytes.count, bytes[cursor] != 0xFF || (cursor + 1 < bytes.count && bytes[cursor + 1] < 0x80) { cursor += 1 }
                }
                guard cursor < bytes.count, bytes[cursor] == 0xFF else { throw Failure.invalidStream }
                cursor += 1
                while cursor < bytes.count, bytes[cursor] == 0xFF { cursor += 1 }
                guard cursor < bytes.count else { throw Failure.invalidStream }
                let marker = bytes[cursor]
                cursor += 1
                if entropy && (0xD0...0xD7).contains(marker) { continue }
                entropy = false
                if marker == 0xD9 {
                    guard sawFrame, !scans.isEmpty, scanned.count == components.count,
                          cursor == bytes.count || (cursor == bytes.count - 1 && bytes[cursor] == 0) else { throw Failure.invalidStream }
                    return .init(precision: precision, width: width, height: height, components: components, scans: scans, maximumSampleValue: maximum)
                }
                guard marker >= 0xC0, marker != 0xD8, !(0xD0...0xD7).contains(marker), bytes.count - cursor >= 2 else { throw Failure.invalidStream }
                let length = word(cursor)
                guard length >= 2, length <= bytes.count - cursor else { throw Failure.invalidStream }
                let start = cursor + 2, end = cursor + length
                cursor = end
                switch marker {
                case 0xF7:
                    guard !sawFrame, length >= 8 else { throw Failure.invalidStream }
                    precision = Int(bytes[start]); height = word(start + 1); width = word(start + 3)
                    let count = Int(bytes[start + 5])
                    guard (2...16).contains(precision), width > 0, (1...255).contains(count), length == 8 + count * 3 else { throw Failure.invalidStream }
                    // A zero height requires DNL, which needs additional evidence rather than a repaired dimension.
                    guard height > 0 else { throw Failure.unsupportedProcess }
                    var identifiers: Set<UInt8> = []
                    for index in 0..<count {
                        let offset = start + 6 + index * 3
                        let horizontal = Int(bytes[offset + 1] >> 4), vertical = Int(bytes[offset + 1] & 15)
                        guard identifiers.insert(bytes[offset]).inserted, (1...4).contains(horizontal), (1...4).contains(vertical), bytes[offset + 2] == 0
                        else { throw Failure.invalidStream }
                        components.append(.init(identifier: bytes[offset], horizontalSampling: horizontal, verticalSampling: vertical))
                    }
                    sawFrame = true
                case 0xF8:
                    guard length >= 3 else { throw Failure.invalidStream }
                    if bytes[start] == 1 {
                        guard length == 13 else { throw Failure.invalidStream }
                        maximum = word(start + 1)
                    }
                case 0xDA:
                    guard sawFrame, length >= 6 else { throw Failure.invalidStream }
                    let count = Int(bytes[start])
                    guard (1...4).contains(count), length == 6 + count * 2 else { throw Failure.invalidStream }
                    var identifiers: [UInt8] = []
                    for index in 0..<count {
                        let identifier = bytes[start + 1 + index * 2]
                        guard components.contains(where: { $0.identifier == identifier }), scanned.insert(identifier).inserted,
                              bytes[start + 2 + index * 2] == 0 else { throw Failure.invalidStream }
                        identifiers.append(identifier)
                    }
                    let near = Int(bytes[end - 3]), interleave = Int(bytes[end - 2]), transform = Int(bytes[end - 1])
                    guard interleave <= 2, count == 1 ? interleave == 0 : interleave != 0, transform >> 4 == 0, transform & 15 < precision,
                          near <= min(255, (maximum ?? (1 << precision) - 1) / 2) else { throw Failure.invalidStream }
                    scans.append(.init(componentIdentifiers: identifiers, near: near, interleaveMode: interleave, pointTransform: transform & 15))
                    entropy = true
                case 0xFE, 0xE0...0xEF:
                    break
                default:
                    throw Failure.unsupportedProcess
                }
            }
            throw Failure.invalidStream
        }
    }
}
