import Foundation

/// One line of a structured element dump: tag, VR, keyword, length and a bounded value preview.
/// Previews never exceed `maxPreviewBytes`; person names and other text are shown verbatim only
/// when `redactText` is false.
public struct DicomDumpLine: Codable, Equatable, Sendable {
    public let depth: Int
    public let tag: String
    public let vr: String
    public let keyword: String?
    public let valueMultiplicity: Int
    public let length: Int?
    public let preview: String
    public let hex: String?

    public init(depth: Int, tag: String, vr: String, keyword: String?, valueMultiplicity: Int, length: Int?, preview: String, hex: String?) {
        self.depth = depth
        self.tag = tag
        self.vr = vr
        self.keyword = keyword
        self.valueMultiplicity = valueMultiplicity
        self.length = length
        self.preview = preview
        self.hex = hex
    }
}

/// Metadata-only structural dump of a data set (sequences recursed, binary previewed as hex).
public enum DicomElementDump {
    public struct Options: Equatable, Sendable {
        public var maxPreviewBytes: Int
        public var maxDepth: Int
        public var includeHex: Bool
        /// Replace text values of identifying tags (PN, patient identifiers, dates of birth) with `(redacted)`.
        public var redactIdentifiers: Bool
        public init(maxPreviewBytes: Int = 32, maxDepth: Int = 16, includeHex: Bool = true, redactIdentifiers: Bool = true) {
            self.maxPreviewBytes = maxPreviewBytes
            self.maxDepth = maxDepth
            self.includeHex = includeHex
            self.redactIdentifiers = redactIdentifiers
        }
    }

    static let identifyingTags: Set<Int> = [0x0010_0010, 0x0010_0020, 0x0010_0021, 0x0010_0030, 0x0010_1000, 0x0010_1001, 0x0010_1040, 0x0010_2154, 0x0008_0090, 0x0008_1050, 0x0008_1060, 0x0008_1070, 0x0010_0032]

    public static func lines(for dataSet: DicomDataSet, options: Options = Options()) -> [DicomDumpLine] {
        var output: [DicomDumpLine] = []
        append(dataSet, depth: 0, options: options, into: &output)
        return output
    }

    private static func append(_ dataSet: DicomDataSet, depth: Int, options: Options, into output: inout [DicomDumpLine]) {
        guard depth < options.maxDepth else { return }
        for element in dataSet.elements {
            let tag = String(format: "(%04X,%04X)", element.group, element.element)
            var preview = ""
            var hex: String? = nil
            var multiplicity = 0
            var length: Int? = nil
            switch element.value {
            case .empty:
                preview = ""
                length = 0
            case .strings(let values):
                multiplicity = values.count
                length = values.joined(separator: "\\").utf8.count
                let redacted = options.redactIdentifiers && (Self.identifyingTags.contains(element.tag) || element.vr == DicomVR.PN)
                preview = redacted ? "(redacted)" : values.joined(separator: "\\")
                if preview.count > 96 { preview = String(preview.prefix(93)) + "..." }
            case .signedIntegers(let values):
                multiplicity = values.count
                preview = values.prefix(16).map(String.init).joined(separator: "\\") + (values.count > 16 ? "\\..." : "")
            case .unsignedIntegers(let values):
                multiplicity = values.count
                preview = values.prefix(16).map(String.init).joined(separator: "\\") + (values.count > 16 ? "\\..." : "")
            case .floats(let values):
                multiplicity = values.count
                preview = values.prefix(16).map { String($0) }.joined(separator: "\\") + (values.count > 16 ? "\\..." : "")
            case .bytes(let data):
                multiplicity = 1
                length = data.count
                preview = "(\(data.count) bytes)"
                if options.includeHex {
                    hex = data.prefix(options.maxPreviewBytes).map { String(format: "%02x", $0) }.joined(separator: " ") + (data.count > options.maxPreviewBytes ? " ..." : "")
                }
            case .sequence(let items):
                multiplicity = items.count
                preview = "(\(items.count) item\(items.count == 1 ? "" : "s"))"
            }
            output.append(DicomDumpLine(depth: depth, tag: tag, vr: element.vr.code, keyword: element.name, valueMultiplicity: multiplicity, length: length, preview: preview, hex: hex))
            if case .sequence(let items) = element.value {
                for (index, item) in items.enumerated() {
                    output.append(DicomDumpLine(depth: depth + 1, tag: "(FFFE,E000)", vr: "--", keyword: "Item", valueMultiplicity: index + 1, length: nil, preview: "item \(index + 1)", hex: nil))
                    append(item.dataSet, depth: depth + 2, options: options, into: &output)
                }
            }
        }
    }

    public static func text(_ lines: [DicomDumpLine]) -> String {
        lines.map { line in
            let indent = String(repeating: "  ", count: line.depth)
            let keyword = line.keyword.map { " " + $0 } ?? ""
            let length = line.length.map { " len=\($0)" } ?? ""
            let hex = line.hex.map { "  [" + $0 + "]" } ?? ""
            return indent + line.tag + " " + line.vr + keyword + length + " vm=\(line.valueMultiplicity) " + line.preview + hex
        }.joined(separator: "\n")
    }
}
