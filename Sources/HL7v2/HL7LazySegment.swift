import Foundation

/// An immutable segment view. Component trees and escape decoding are deferred until field access.
/// Access is throwing because malformed fields and lot A structural limits are checked at that point.
public struct HL7LazySegment: Sendable {
    public let name: String
    public let originalLineIndex: Int
    private let header: Data
    private let wire: Data
    private let options: HL7ParserOptions

    init(header: Data, wire: Data, options: HL7ParserOptions, lineIndex: Int) {
        self.name = String(decoding: wire.prefix(3), as: UTF8.self)
        self.originalLineIndex = lineIndex
        self.header = header; self.wire = wire; self.options = options
    }

    public func field(_ index: Int) throws -> HL7Field { try materialize()[index] }

    public func materialize() throws -> HL7Segment {
        var bytes = originalLineIndex == 0 ? Data() : header
        if !bytes.isEmpty && bytes.last != 13 && bytes.last != 10 { bytes.append(13) }
        bytes.append(wire)
        let parsed = try HL7Parser(options: options).parse(bytes)
        guard parsed.segments.count == (originalLineIndex == 0 ? 1 : 2), let segment = parsed.segments.last else {
            throw HL7ParseError.malformed(.init(), lineIndex: originalLineIndex)
        }
        return HL7Segment(name: segment.name, fields: segment.fields, originalLineIndex: originalLineIndex)
    }
}
