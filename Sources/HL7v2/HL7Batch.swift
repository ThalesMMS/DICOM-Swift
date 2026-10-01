import Foundation

public struct HL7BatchLoss: Equatable, Sendable {
    /// Zero-based message index in the input, including rejected members.
    public let index: Int
    public let byteRange: Range<Int>
    public let code: HL7Diagnostic.Code
    public var byteLength: Int { byteRange.count }
}

public enum HL7BatchError: Error, Equatable, Sendable {
    case envelope(offset: Int)
    case count(path: HL7Path, expected: Int, actual: Int)
    case member(HL7BatchLoss)
}

/// Immutable wire document. Serialization preserves the original envelope and rejected bytes;
/// messages and lossReport describe what was successfully interpreted, without inventing members.
public struct HL7BatchDocument: Sendable {
    public let messages: [HL7Message]
    public let messageRanges: [Range<Int>]
    public let batches: [Range<Int>]
    public let lossReport: [HL7BatchLoss]
    private let wire: Data
    public func serialize() -> Data { wire }

    public static func parse(_ data: Data, options: HL7ParserOptions = .init(),
                             recoverMessages: Bool = false) throws -> Self {
        let bytes = Array(data)
        var lines: [(name: String, range: Range<Int>, content: Range<Int>)] = []
        var start = 0
        var cursor = 0
        while cursor < bytes.count {
            if bytes[cursor] == 13 || bytes[cursor] == 10 {
                let end = cursor
                let crlf = bytes[cursor] == 13 && cursor + 1 < bytes.count && bytes[cursor + 1] == 10
                guard options.lenientTerminators || (bytes[cursor] == 13 && !crlf) else {
                    throw HL7BatchError.envelope(offset: cursor)
                }
                cursor += crlf ? 2 : 1
                lines.append((String(decoding: bytes[start..<min(start + 3, end)], as: UTF8.self),
                              start..<cursor, start..<end))
                start = cursor
            } else { cursor += 1 }
        }
        if start < bytes.count {
            lines.append((String(decoding: bytes[start..<min(start + 3, bytes.count)], as: UTF8.self),
                          start..<bytes.count, start..<bytes.count))
        }
        var messages: [HL7Message] = []
        var ranges: [Range<Int>] = []
        var batches: [Range<Int>] = []
        var losses: [HL7BatchLoss] = []
        var fileOpen = false
        var fileClosed = false
        var batchStart: Int?
        var memberStart: Int?
        var memberCount = 0
        var messageIndex = 0
        var batchSeparator: UInt8 = 124
        var fileSeparator: UInt8 = 124
        var strict = options
        strict.recovery = .strict
        func finishMember(_ end: Int) throws {
            guard let begin = memberStart else { return }
            let range = begin..<end
            do {
                messages.append(try HL7Parser(options: strict).parse(Data(bytes[range])))
                ranges.append(range)
            } catch let error as HL7ParseError {
                // Resource limits must never be downgraded into recovery.
                if case .limitExceeded = error { throw error }
                let loss = HL7BatchLoss(index: messageIndex, byteRange: range, code: .malformedContent)
                guard recoverMessages else { throw HL7BatchError.member(loss) }
                losses.append(loss)
            }
            messageIndex += 1
            memberCount += 1
            memberStart = nil
        }
        func checkCount(_ line: (name: String, range: Range<Int>, content: Range<Int>),
                        separator: UInt8, actual: Int) throws {
            let content = Array(bytes[line.content])
            guard content.count >= 5, content[3] == separator else {
                throw HL7BatchError.envelope(offset: line.range.lowerBound)
            }
            let countBytes = content.dropFirst(4).prefix { $0 != separator }
            guard !countBytes.isEmpty, countBytes.allSatisfy({ (48...57).contains($0) }),
                  let expected = Int(String(decoding: countBytes, as: UTF8.self)) else {
                throw HL7BatchError.envelope(offset: line.range.lowerBound)
            }
            guard expected == actual else {
                throw HL7BatchError.count(path: .init(segment: line.name, field: 1), expected: expected, actual: actual)
            }
        }
        func separator(_ line: (name: String, range: Range<Int>, content: Range<Int>)) throws -> UInt8 {
            let content = Array(bytes[line.content])
            guard content.count >= 8 else { throw HL7BatchError.envelope(offset: line.range.lowerBound) }
            let end = content[4...].firstIndex(of: content[3]) ?? content.count
            _ = try HL7EncodingCharacters(field: Character(Unicode.Scalar(content[3])),
                msh2: String(decoding: content[4..<end], as: UTF8.self))
            return content[3]
        }
        for line in lines {
            guard !fileClosed else { throw HL7BatchError.envelope(offset: line.range.lowerBound) }
            switch line.name {
            case "FHS":
                guard line.range.lowerBound == 0, !fileOpen, batchStart == nil else {
                    throw HL7BatchError.envelope(offset: line.range.lowerBound)
                }
                fileSeparator = try separator(line)
                fileOpen = true
            case "BHS":
                guard batchStart == nil, memberStart == nil, fileOpen || line.range.lowerBound == 0 else {
                    throw HL7BatchError.envelope(offset: line.range.lowerBound)
                }
                batchSeparator = try separator(line)
                batchStart = line.range.lowerBound
                memberCount = 0
            case "MSH":
                guard batchStart != nil else { throw HL7BatchError.envelope(offset: line.range.lowerBound) }
                try finishMember(line.range.lowerBound)
                memberStart = line.range.lowerBound
            case "BTS":
                guard let begin = batchStart else { throw HL7BatchError.envelope(offset: line.range.lowerBound) }
                try finishMember(line.range.lowerBound)
                try checkCount(line, separator: batchSeparator, actual: memberCount)
                batches.append(begin..<line.range.upperBound)
                batchStart = nil
            case "FTS":
                guard fileOpen, batchStart == nil else { throw HL7BatchError.envelope(offset: line.range.lowerBound) }
                try checkCount(line, separator: fileSeparator, actual: batches.count)
                fileOpen = false
                fileClosed = true
            default:
                guard memberStart != nil else { throw HL7BatchError.envelope(offset: line.range.lowerBound) }
            }
        }
        guard !fileOpen, batchStart == nil, memberStart == nil, !batches.isEmpty else {
            throw HL7BatchError.envelope(offset: bytes.count)
        }
        return Self(messages: messages, messageRanges: ranges, batches: batches, lossReport: losses, wire: data)
    }

    public static func join(_ messages: [Data], fileEnvelope: Bool = false) throws -> Data {
        var data = Data((fileEnvelope ? "FHS|^~\\&\r" : "").utf8)
        data.append(Data("BHS|^~\\&\r".utf8))
        for bytes in messages {
            let message = try HL7Parser().parse(bytes)
            guard !message.segments.contains(where: { ["BHS", "BTS", "FHS", "FTS"].contains($0.name) }) else {
                throw HL7BatchError.envelope(offset: data.count)
            }
            data.append(bytes)
            if bytes.last != 13 { data.append(13) }
        }
        data.append(Data("BTS|\(messages.count)\r".utf8))
        if fileEnvelope { data.append(Data("FTS|1\r".utf8)) }
        return data
    }
}
