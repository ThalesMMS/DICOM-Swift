import Foundation

/// Actual non-hierarchical Huffman JPEG marker evidence (SOF0/SOF1/SOF2/SOF3): frame header, components,
/// scans with their progressive or lossless parameters, tables and restart interval, without entropy decode.
/// Arithmetic, hierarchical and differential processes are explicit refusals.
public enum DicomJPEGFrameInspector {
    public enum Failure: Error, Equatable, Sendable { case invalidStream, unsupportedProcess, limitExceeded }

    /// The coding process the Start of Frame marker declares.
    public enum Process: String, Equatable, Sendable {
        case baseline = "SOF0 baseline DCT"
        case extendedSequential = "SOF1 extended sequential DCT"
        case progressive = "SOF2 progressive DCT"
        case lossless = "SOF3 lossless predictive"
    }

    public struct Component: Equatable, Sendable {
        public let identifier: UInt8
        public let horizontalSampling: Int
        public let verticalSampling: Int
        public let quantizationTable: Int
    }

    public struct Scan: Equatable, Sendable {
        public let componentIdentifiers: [UInt8]
        public let predictor: Int
        public let pointTransform: Int
        /// Whether every DC/AC Huffman table and quantization table the scan selects was defined before it.
        public let tablesDefined: Bool
        /// Progressive parameters (Ss, Se, Ah, Al); zero for sequential scans.
        public let spectralStart: Int
        public let spectralEnd: Int
        public let successiveHigh: Int
        public let successiveLow: Int

        public init(componentIdentifiers: [UInt8], predictor: Int, pointTransform: Int, tablesDefined: Bool,
                    spectralStart: Int = 0, spectralEnd: Int = 0, successiveHigh: Int = 0, successiveLow: Int = 0) {
            self.componentIdentifiers = componentIdentifiers
            self.predictor = predictor
            self.pointTransform = pointTransform
            self.tablesDefined = tablesDefined
            self.spectralStart = spectralStart
            self.spectralEnd = spectralEnd
            self.successiveHigh = successiveHigh
            self.successiveLow = successiveLow
        }
    }

    public struct Inspection: Equatable, Sendable {
        public let startOfFrame: UInt8
        public let precision: Int
        public let width: Int
        public let height: Int
        public let components: [Component]
        public let scans: [Scan]
        /// Restart interval in MCUs from DRI, zero when absent.
        public let restartInterval: Int
        /// Huffman tables (class × destination) and quantization tables defined in the stream.
        public let huffmanTableCount: Int
        public let quantizationTableCount: Int

        public var process: Process {
            switch startOfFrame {
            case 0xC0: return .baseline
            case 0xC1: return .extendedSequential
            case 0xC2: return .progressive
            default: return .lossless
            }
        }

        /// Chroma sampling of the second component relative to the first, e.g. `(2, 1)` for 4:2:2, `(2, 2)` for 4:2:0.
        public var chromaSubsampling: (horizontal: Int, vertical: Int)? {
            guard components.count == 3 else { return nil }
            return (components[0].horizontalSampling / max(1, components[1].horizontalSampling),
                    components[0].verticalSampling / max(1, components[1].verticalSampling))
        }
    }

    public static func inspect(_ data: Data, maximumEncodedBytes: Int = 64 * 1024 * 1024) throws -> Inspection {
        guard data.count <= max(0, maximumEncodedBytes) else { throw Failure.limitExceeded }
        return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw Failure.invalidStream }
            func word(_ index: Int) -> Int { Int(bytes[index]) << 8 | Int(bytes[index + 1]) }
            var cursor = 2, entropy = false
            var sof: UInt8?, precision = 0, width = 0, height = 0, restartInterval = 0
            var components: [Component] = [], scans: [Scan] = []
            var scanned: Set<UInt8> = [], quantization: Set<Int> = [], huffman: Set<Int> = []
            while cursor < bytes.count {
                if entropy {
                    while cursor < bytes.count, bytes[cursor] != 0xFF { cursor += 1 }
                }
                guard cursor < bytes.count, bytes[cursor] == 0xFF else { throw Failure.invalidStream }
                cursor += 1
                while cursor < bytes.count, bytes[cursor] == 0xFF { cursor += 1 }
                guard cursor < bytes.count else { throw Failure.invalidStream }
                let marker = bytes[cursor]
                cursor += 1
                if entropy && (marker == 0 || (0xD0...0xD7).contains(marker)) { continue }
                entropy = false
                if marker == 0xD9 {
                    // PS3.5 A.4: one even-length pad byte may follow EOI. Encoders write 0x00, 0xFF like GE (issue #2487), or
                    // whatever was in the buffer (0x20, 0xA2); GDCM reads them all (issue #2852).
                    guard let sof, !scans.isEmpty, scanned.count == components.count, cursor >= bytes.count - 1 else {
                        throw Failure.invalidStream
                    }
                    return .init(startOfFrame: sof, precision: precision, width: width, height: height, components: components, scans: scans,
                                 restartInterval: restartInterval, huffmanTableCount: huffman.count, quantizationTableCount: quantization.count)
                }
                guard marker >= 0xC0, marker != 0xD8, !(0xD0...0xD7).contains(marker), bytes.count - cursor >= 2 else { throw Failure.invalidStream }
                let length = word(cursor)
                guard length >= 2, length <= bytes.count - cursor else { throw Failure.invalidStream }
                let start = cursor + 2, end = cursor + length
                cursor = end
                if [0xC0, 0xC1, 0xC2, 0xC3].contains(marker) {
                    guard sof == nil, length >= 8 else { throw Failure.invalidStream }
                    precision = Int(bytes[start]); height = word(start + 1); width = word(start + 3)
                    let count = Int(bytes[start + 5])
                    guard count > 0, length == 8 + count * 3, width > 0 else { throw Failure.invalidStream }
                    // A zero height requires DNL; that process needs additional evidence rather than a repaired dimension.
                    guard height > 0 else { throw Failure.unsupportedProcess }
                    let precisionValid: Bool
                    switch marker {
                    case 0xC0: precisionValid = precision == 8
                    case 0xC1, 0xC2: precisionValid = [8, 12].contains(precision)
                    default: precisionValid = (2...16).contains(precision)
                    }
                    guard precisionValid else { throw Failure.invalidStream }
                    var identifiers: Set<UInt8> = []
                    for index in 0..<count {
                        let offset = start + 6 + index * 3
                        let identifier = bytes[offset], horizontal = Int(bytes[offset + 1] >> 4), vertical = Int(bytes[offset + 1] & 15)
                        guard identifiers.insert(identifier).inserted, (1...4).contains(horizontal), (1...4).contains(vertical),
                              bytes[offset + 2] <= 3, marker != 0xC3 || bytes[offset + 2] == 0 else { throw Failure.invalidStream }
                        components.append(.init(identifier: identifier, horizontalSampling: horizontal, verticalSampling: vertical,
                                                quantizationTable: Int(bytes[offset + 2])))
                    }
                    sof = marker
                } else if marker == 0xDA {
                    guard let sof, length >= 6 else { throw Failure.invalidStream }
                    let count = Int(bytes[start])
                    guard (1...4).contains(count), length == 6 + count * 2 else { throw Failure.invalidStream }
                    let ss = Int(bytes[end - 3]), se = Int(bytes[end - 2]), ah = Int(bytes[end - 1] >> 4), al = Int(bytes[end - 1] & 15)
                    var identifiers: [UInt8] = [], defined = true
                    for index in 0..<count {
                        let identifier = bytes[start + 1 + index * 2], table = bytes[start + 2 + index * 2]
                        // Progressive scans revisit components; sequential and lossless scans cover each component once.
                        guard let component = components.first(where: { $0.identifier == identifier }),
                              sof == 0xC2 || scanned.insert(identifier).inserted,
                              table >> 4 <= 3, table & 15 <= 3, sof != 0xC3 || table & 15 == 0 else { throw Failure.invalidStream }
                        if sof == 0xC2 { scanned.insert(identifier) }
                        identifiers.append(identifier)
                        // B.2.3: the DC table (class 0), the AC table (class 1) and the quantization table selected must be defined.
                        // Progressive DC scans use DC tables only; AC scans use AC tables only; refinement DC scans use none.
                        let needsDC = sof == 0xC3 || (sof != 0xC2) || (ss == 0 && ah == 0)
                        let needsAC = sof != 0xC3 && (sof != 0xC2 || ss > 0)
                        defined = defined && (!needsDC || huffman.contains(Int(table >> 4))) && (!needsAC || huffman.contains(16 + Int(table & 15)))
                            && (sof == 0xC3 || quantization.contains(component.quantizationTable))
                    }
                    if sof == 0xC3 {
                        guard (1...7).contains(ss), se == 0, ah == 0, al < precision else { throw Failure.invalidStream }
                    } else if sof == 0xC2 {
                        // G.1.1.1.1: DC scans have Ss = Se = 0; AC scans carry one component with 1 <= Ss <= Se <= 63;
                        // successive approximation refines one bit at a time (Ah = 0 or Ah = Al + 1).
                        guard ss <= se, se <= 63, ah <= 13, al <= 13, ss == 0 ? se == 0 : count == 1, ah == 0 || ah == al + 1 else {
                            throw Failure.invalidStream
                        }
                    } else {
                        // Some encoders write all zeroes in Ss, Se, Ah and Al; libjpeg decodes those scans over every
                        // coefficient with a warning (issue #2852).
                        guard ss == 0, se == 63 || se == 0, ah == 0, al == 0 else { throw Failure.invalidStream }
                    }
                    scans.append(.init(componentIdentifiers: identifiers, predictor: sof == 0xC3 ? ss : 0, pointTransform: sof == 0xC3 ? al : 0,
                                       tablesDefined: defined, spectralStart: sof == 0xC2 ? ss : 0, spectralEnd: sof == 0xC2 ? se : 0,
                                       successiveHigh: sof == 0xC2 ? ah : 0, successiveLow: sof == 0xC2 ? al : 0))
                    entropy = true
                } else if marker == 0xC4 {
                    // B.2.4.2: each DHT segment defines one or more (class, destination) tables.
                    var offset = start
                    while offset < end {
                        let selector = bytes[offset]
                        guard selector >> 4 <= 1, selector & 15 <= 3, end - offset >= 17 else { throw Failure.invalidStream }
                        let symbols = (1...16).reduce(0) { $0 + Int(bytes[offset + $1]) }
                        guard symbols <= 256, end - offset >= 17 + symbols else { throw Failure.invalidStream }
                        huffman.insert(Int(selector >> 4) * 16 + Int(selector & 15))
                        offset += 17 + symbols
                    }
                } else if marker == 0xDB {
                    // B.2.4.1: each DQT segment defines one or more 8- or 16-bit tables.
                    var offset = start
                    while offset < end {
                        let selector = bytes[offset]
                        let width = selector >> 4 == 0 ? 1 : 2
                        guard selector >> 4 <= 1, selector & 15 <= 3, end - offset >= 1 + 64 * width else { throw Failure.invalidStream }
                        for index in 0..<64 {
                            let position = offset + 1 + index * width
                            let coefficient = width == 1 ? Int(bytes[position]) : Int(bytes[position]) << 8 | Int(bytes[position + 1])
                            guard coefficient != 0 else { throw Failure.invalidStream }
                        }
                        quantization.insert(Int(selector & 15))
                        offset += 1 + 64 * width
                    }
                } else if marker == 0xDD {
                    // B.2.4.4: the restart interval in MCUs; zero disables restart markers.
                    guard length == 4 else { throw Failure.invalidStream }
                    restartInterval = word(start)
                } else if !(marker == 0xFE || (0xE0...0xEF).contains(marker)) {
                    // Arithmetic (SOF9–SOF15), hierarchical (SOF5–SOF7, DHP/EXP) and differential processes stay explicit refusals.
                    throw Failure.unsupportedProcess
                }
            }
            throw Failure.invalidStream
        }
    }
}
