import Foundation

public enum HL7IncrementalEvent: Sendable {
    case message(HL7Message)
    case segment(HL7Segment)
    case lazySegment(HL7LazySegment)
}

/// Raw bytes are retained until a complete segment is available; no chunk is decoded in isolation.
public struct HL7IncrementalParser: Sendable {
    public enum Output: Sendable { case messages, segments, lazySegments }
    public let options: HL7ParserOptions
    public let output: Output
    private var line = Data()
    private var message = Data()
    private var header = Data()
    private var segmentCount = 0
    private var messageByteCount = 0
    private var pendingCR = false
    private var ended = false
    public var bufferedByteCount: Int { line.count + message.count + header.count }

    public init(options: HL7ParserOptions = .init(), output: Output = .messages) {
        self.options = options
        self.output = output
    }

    public mutating func feed(_ chunk: Data) throws -> [HL7IncrementalEvent] {
        guard !ended else { throw HL7ParseError.malformed(.init(), lineIndex: segmentCount) }
        var events: [HL7IncrementalEvent] = []
        for byte in chunk { try consume(byte, events: &events) }
        return events
    }

    public mutating func finish() throws -> [HL7IncrementalEvent] {
        guard !ended else { return [] }
        var events: [HL7IncrementalEvent] = []
        if pendingCR {
            try completeLine(terminator: Data([13]), events: &events)
            pendingCR = false
        } else if !line.isEmpty { try completeLine(terminator: Data(), events: &events) }
        try completeMessage(events: &events)
        ended = true
        return events
    }

    private mutating func consume(_ byte: UInt8, events: inout [HL7IncrementalEvent]) throws {
        if pendingCR {
            pendingCR = false
            if byte == 10 {
                guard options.lenientTerminators else { throw HL7ParseError.malformed(.init(), lineIndex: segmentCount) }
                try completeLine(terminator: Data([13, 10]), events: &events)
                return
            }
            try completeLine(terminator: Data([13]), events: &events)
        }
        if byte == 13 {
            // Strict CR streams can emit immediately. Lenient streams wait for a possible LF.
            if options.lenientTerminators { pendingCR = true }
            else { try completeLine(terminator: Data([13]), events: &events) }
        } else if byte == 10 {
            guard options.lenientTerminators else { throw HL7ParseError.malformed(.init(), lineIndex: segmentCount) }
            try completeLine(terminator: Data([10]), events: &events)
        } else {
            line.append(byte)
            if line.count == 3, ["MSH", "BTS", "FTS"].contains(String(decoding: line, as: UTF8.self)) {
                try completeMessage(events: &events)
            }
            // Three bytes of lookahead identify a boundary without charging the next MSH to the previous message.
            guard line.count <= options.maxMessageBytes,
                  line.count <= 3 || messageByteCount <= options.maxMessageBytes - line.count else {
                throw HL7ParseError.limitExceeded(.messageBytes, .init())
            }
        }
    }

    private mutating func completeLine(terminator: Data, events: inout [HL7IncrementalEvent]) throws {
        let name = String(decoding: line.prefix(3), as: UTF8.self)
        if ["FHS", "BHS", "BTS", "FTS"].contains(name) {
            try completeMessage(events: &events)
            line.removeAll(keepingCapacity: true)
            return
        }
        guard segmentCount < options.maxSegments else { throw HL7ParseError.limitExceeded(.segments, .init()) }
        guard line.count + terminator.count <= options.maxMessageBytes - messageByteCount else {
            throw HL7ParseError.limitExceeded(.messageBytes, .init())
        }
        var wire = line
        wire.append(terminator)
        if segmentCount == 0 {
            guard name == "MSH" else { throw HL7ParseError.malformed(.init(segment: "MSH"), lineIndex: 0) }
            header = wire
        }
        switch output {
        case .messages:
            message.append(wire)
            header.removeAll(keepingCapacity: false)
        case .segments, .lazySegments:
            let lazy = HL7LazySegment(header: header, wire: wire, options: options, lineIndex: segmentCount)
            if output == .segments { events.append(.segment(try lazy.materialize())) }
            else { events.append(.lazySegment(lazy)) }
        }
        messageByteCount += wire.count
        segmentCount += 1
        line.removeAll(keepingCapacity: true)
    }

    private mutating func completeMessage(events: inout [HL7IncrementalEvent]) throws {
        if !message.isEmpty { events.append(.message(try HL7Parser(options: options).parse(message))) }
        message.removeAll(keepingCapacity: true)
        header.removeAll(keepingCapacity: false)
        segmentCount = 0
        messageByteCount = 0
    }

    /// Pull-driven unfolding reads the next chunk only when the consumer requests another event.
    /// Supply chunks no larger than maxMessageBytes; oversized chunks fail with the lot A byte limit.
    /// The producer is never run in a detached task and no events are dropped by a buffering policy.
    public static func stream(options: HL7ParserOptions = .init(), output: Output = .messages,
        nextChunk: @escaping @Sendable () async throws -> Data?) -> AsyncThrowingStream<HL7IncrementalEvent, Error> {
        let state = HL7IncrementalStreamState(parser: .init(options: options, output: output), nextChunk: nextChunk)
        return AsyncThrowingStream(unfolding: { try await state.next() })
    }
}

private actor HL7IncrementalStreamState {
    var parser: HL7IncrementalParser
    let nextChunk: @Sendable () async throws -> Data?
    var chunk = Data()
    var cursor = 0
    var pending: [HL7IncrementalEvent] = []
    var ended = false
    init(parser: HL7IncrementalParser, nextChunk: @escaping @Sendable () async throws -> Data?) {
        self.parser = parser; self.nextChunk = nextChunk
    }
    func next() async throws -> HL7IncrementalEvent? {
        while pending.isEmpty && !ended {
            try Task.checkCancellation()
            if cursor < chunk.count {
                pending = try parser.feed(Data([chunk[chunk.startIndex + cursor]]))
                cursor += 1
            } else if let next = try await nextChunk() {
                guard next.count <= parser.options.maxMessageBytes else {
                    throw HL7ParseError.limitExceeded(.messageBytes, .init())
                }
                chunk = next; cursor = 0
            } else {
                pending = try parser.finish(); ended = true
            }
        }
        return pending.isEmpty ? nil : pending.removeFirst()
    }
}
