import Foundation

public enum DicomWebMultipartEvent: Equatable, Sendable {
    case partHeaders([String: String], isRoot: Bool)
    case payload(Data)
    case partEnd
    case epilogue(Data)
}

public struct DicomWebMultipartLimits: Equatable, Sendable {
    public var maximumHeaderBytes: Int
    public var maximumPartBytes: Int
    public var maximumPartCount: Int
    public var maximumTotalBytes: Int

    public init(maximumHeaderBytes: Int = 64 * 1024, maximumPartBytes: Int = 128 * 1024 * 1024,
                maximumPartCount: Int = 10_000, maximumTotalBytes: Int = 1024 * 1024 * 1024) {
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumPartBytes = maximumPartBytes
        self.maximumPartCount = maximumPartCount
        self.maximumTotalBytes = maximumTotalBytes
    }
}

public enum DicomWebMultipartStreamError: Error, Equatable, Sendable {
    case limitExceeded(String, limit: Int)
    case invalidBoundary
    case malformedHeaders
    case invalidContentLength
    case missingFinalDelimiter
    case missingRoot
    case duplicateRoot
    case invalidState
}

/// Incremental MIME decoder. Data events use deterministic 16 KiB blocks and a final remainder.
/// A declared Content-Length takes precedence over delimiter-looking bytes inside the payload.
public struct DicomWebMultipartStreamParser: Sendable {
    private enum State { case preamble, headers, payload, delimiter, epilogue, finished }
    private var state: State = .preamble
    private var buffer = Data()
    private var pendingPayload = Data()
    private var pendingEpilogue = Data()
    private let marker: Data
    /// The marker after the line feed that opens a delimiter line inside a part.
    private let framedMarker: [UInt8]
    private let limits: DicomWebMultipartLimits
    private let rootID: String?
    private var foundRoot = false
    private var total = 0
    private var count = 0
    private var partBytes = 0
    private var remaining: Int?
    private var preambleLineStart = true
    /// The `type` of the outer Content-Type: a part without Content-Type has it, as dcm4che reads such parts.
    private var defaultPartType: String?
    /// The outer `transfer-syntax`, applied to every part whose Content-Type does not name one.
    private var defaultTransferSyntax: String?

    public init(boundary: String, start: String? = nil, limits: DicomWebMultipartLimits = .init()) throws {
        guard !boundary.isEmpty, boundary.utf8.count <= 70,
              boundary.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || "'()+_,-./:=? ".utf8.contains($0) }),
              !boundary.hasSuffix(" ") else { throw DicomWebMultipartStreamError.invalidBoundary }
        marker = Data("--\(boundary)".utf8)
        framedMarker = [10] + Array(marker)
        rootID = start
        self.limits = limits
    }

    public init(contentType: String, limits: DicomWebMultipartLimits = .init()) throws {
        let media = try DicomWebMediaType(contentType)
        guard media.type == "multipart/related", let boundary = media.parameters["boundary"] else {
            throw DicomWebMultipartStreamError.invalidBoundary
        }
        try self.init(boundary: boundary, start: media.parameters["start"], limits: limits)
        defaultPartType = media.parameters["type"]
        defaultTransferSyntax = media.parameters["transfer-syntax"]
    }

    public mutating func feed(_ chunk: Data) throws -> [DicomWebMultipartEvent] {
        try Task.checkCancellation()
        guard state != .finished else { throw DicomWebMultipartStreamError.invalidState }
        try check(total, adding: chunk.count, limit: limits.maximumTotalBytes, name: "maximumTotalBytes")
        total += chunk.count
        var events: [DicomWebMultipartEvent] = []
        // Never copy an arbitrarily large caller chunk into the carry buffer.
        for offset in stride(from: 0, to: chunk.count, by: 16 * 1024) {
            try Task.checkCancellation()
            let start = chunk.index(chunk.startIndex, offsetBy: offset)
            let end = chunk.index(start, offsetBy: min(16 * 1024, chunk.count - offset))
            // Consumed bytes are only skipped (#2890); drop them once per read, keeping the unread tail.
            if buffer.startIndex != 0 { buffer = Data(buffer) }
            buffer.append(chunk[start..<end])
            try drain(into: &events, finishing: false)
        }
        return events
    }

    public mutating func finish() throws -> [DicomWebMultipartEvent] {
        try Task.checkCancellation()
        var events: [DicomWebMultipartEvent] = []
        try drain(into: &events, finishing: true)
        guard state == .epilogue else { throw DicomWebMultipartStreamError.missingFinalDelimiter }
        guard rootID == nil || foundRoot else { throw DicomWebMultipartStreamError.missingRoot }
        if !pendingEpilogue.isEmpty { events.append(.epilogue(pendingEpilogue)); pendingEpilogue = Data() }
        state = .finished
        return events
    }

    public static func parts(from data: Data, contentType: String,
                             limits: DicomWebMultipartLimits = .init()) throws -> [DicomWebMultipartPart] {
        var parser = try Self(contentType: contentType, limits: limits)
        var parts: [DicomWebMultipartPart] = []
        for event in try parser.feed(data) + parser.finish() {
            switch event {
            case .partHeaders(let headers, let isRoot):
                var part = DicomWebMultipartPart(headers: headers, body: Data())
                part.isRoot = isRoot
                parts.append(part)
            case .payload(let bytes): parts[parts.count - 1].body.append(bytes)
            default: break
            }
        }
        return parts
    }

    private func check(_ value: Int, adding: Int, limit: Int, name: String) throws {
        guard value <= limit, adding <= limit - value else {
            throw DicomWebMultipartStreamError.limitExceeded(name, limit: limit)
        }
    }

    /// Gives a part without Content-Type the outer `type`, and the outer `transfer-syntax` to a part of that type
    /// that names none, as dcm4che derives the part type from the outer parameters.
    private func applyOuterType(to headers: inout [String: String]) throws {
        let name = headers.keys.first { $0.caseInsensitiveCompare("Content-Type") == .orderedSame } ?? "Content-Type"
        guard let value = headers[name] ?? defaultPartType else { throw DicomWebMultipartStreamError.malformedHeaders }
        headers[name] = value
        guard let syntax = defaultTransferSyntax, let media = try? DicomWebMediaType(value),
              media.parameters["transfer-syntax"] == nil,
              defaultPartType.map({ (try? DicomWebMediaType($0))?.type == media.type }) ?? true else { return }
        headers[name] = value + "; transfer-syntax=" + syntax
    }

    /// The first line break + marker in the buffer that opens a whole delimiter line, or that opens a line still too
    /// short to tell (`decided` false), with the payload bytes before its line break. One pass over the raw bytes:
    /// memmem keeps the search linear on bodies of '-', of near-delimiters or of one repeated byte, and each
    /// candidate is checked in place, so a body of whole delimiters followed by text costs a few compares each.
    private func delimiterCandidate(finishing: Bool) -> (payload: Int, lineBreak: Int, decided: Bool)? {
        let maximumBlanks = limits.maximumHeaderBytes
        return buffer.withUnsafeBytes { raw in
            framedMarker.withUnsafeBufferPointer { needle in
                guard let base = raw.baseAddress, let needleBase = needle.baseAddress else { return nil }
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                let count = raw.count
                var offset = 0
                while offset < count, let found = memmem(base + offset, count - offset, needleBase, needle.count) {
                    let start = UnsafeRawPointer(found) - base
                    let lineBreak = start > 0 && bytes[start - 1] == 13 ? 2 : 1
                    switch Self.delimiterLine(bytes, count: count, after: start + needle.count, finishing: finishing,
                                              maximumBlanks: maximumBlanks) {
                    case .some(true): return (start + 1 - lineBreak, lineBreak, true)
                    case .none: return (start + 1 - lineBreak, lineBreak, false)
                    case .some(false): offset = start + needle.count
                    }
                }
                return nil
            }
        }
    }

    /// Advances the read position without copying: the buffer becomes a slice of its own storage.
    private mutating func consume(_ n: Int) { buffer = buffer[(buffer.startIndex + n)...] }

    private mutating func emit(_ n: Int, into events: inout [DicomWebMultipartEvent]) throws {
        guard n > 0 else { return }
        try check(partBytes, adding: n, limit: limits.maximumPartBytes, name: "maximumPartBytes")
        partBytes += n
        let block = 16 * 1024
        var start = buffer.startIndex
        let end = start + n
        // Top up a partial block first, then copy whole blocks straight out of the buffer.
        if !pendingPayload.isEmpty {
            let take = min(n, block - pendingPayload.count)
            pendingPayload.append(buffer[start..<(start + take)])
            start += take
            if pendingPayload.count == block { events.append(.payload(pendingPayload)); pendingPayload = Data() }
        }
        while end - start >= block {
            events.append(.payload(Data(buffer[start..<(start + block)])))
            start += block
        }
        if start < end { pendingPayload.append(buffer[start..<end]) }
        consume(n)
    }

    /// Whether the bytes after a CRLF-boundary at `index` complete a delimiter
    /// line; nil while more bytes are needed to tell.
    private static func delimiterLine(_ bytes: UnsafePointer<UInt8>, count: Int, after index: Int, finishing: Bool,
                                      maximumBlanks: Int) -> Bool? {
        var position = index
        let closing = position + 1 < count && bytes[position] == 45 && bytes[position + 1] == 45
        if closing { position += 2 }
        while position < count, bytes[position] == 32 || bytes[position] == 9 {
            position += 1
            if position - index > maximumBlanks { return false }
        }
        guard position < count else {
            if !finishing { return nil }
            return closing
        }
        if bytes[position] == 10 { return true }
        guard bytes[position] == 13 else { return false }
        guard position + 1 < count else { return finishing ? false : nil }
        return bytes[position + 1] == 10
    }

    private mutating func drain(into events: inout [DicomWebMultipartEvent], finishing: Bool) throws {
        while true {
            switch state {
            case .preamble:
                if preambleLineStart, buffer.starts(with: marker) {
                    state = .delimiter
                    continue
                }
                if preambleLineStart, buffer.count < marker.count, marker.starts(with: buffer) { return }
                if let newline = buffer.firstIndex(of: 10) {
                    consume(newline - buffer.startIndex + 1)
                    preambleLineStart = true
                } else {
                    if !buffer.isEmpty { preambleLineStart = false; buffer.removeAll(keepingCapacity: true) }
                    return
                }
            case .delimiter:
                guard buffer.count >= marker.count + 2 else { return }
                guard buffer.starts(with: marker) else { throw DicomWebMultipartStreamError.invalidContentLength }
                let tail = buffer.dropFirst(marker.count)
                let closing = tail.starts(with: [45, 45])
                if let newline = tail.firstIndex(of: 10) {
                    let line = tail[..<newline]
                    let suffix = closing ? line.dropFirst(2) : line[...]
                    guard suffix.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) else {
                        throw DicomWebMultipartStreamError.missingFinalDelimiter
                    }
                    consume(newline - buffer.startIndex + 1)
                } else if closing, finishing, tail.dropFirst(2).allSatisfy({ $0 == 32 || $0 == 9 }) {
                    buffer.removeAll()
                } else {
                    try check(0, adding: buffer.count, limit: limits.maximumHeaderBytes, name: "maximumHeaderBytes")
                    return
                }
                if closing { state = .epilogue } else { state = .headers }
            case .headers:
                let crlf = buffer.range(of: Data([13, 10, 13, 10]))
                let lf = buffer.range(of: Data([10, 10]))
                guard let separator = [crlf, lf].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) else {
                    try check(0, adding: max(0, buffer.count - 3), limit: limits.maximumHeaderBytes, name: "maximumHeaderBytes")
                    return
                }
                try check(0, adding: separator.lowerBound - buffer.startIndex,
                          limit: limits.maximumHeaderBytes, name: "maximumHeaderBytes")
                guard let text = String(data: buffer[..<separator.lowerBound], encoding: .utf8) else {
                    throw DicomWebMultipartStreamError.malformedHeaders
                }
                var headers: [String: String] = [:]
                for line in text.components(separatedBy: "\n") {
                    let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    guard pair.count == 2 else { throw DicomWebMultipartStreamError.malformedHeaders }
                    let name = String(pair[0])
                    guard !name.isEmpty, !name.contains(where: { $0.isWhitespace }), headers.dicomWebHeaderValue(name) == nil else {
                        throw DicomWebMultipartStreamError.malformedHeaders
                    }
                    headers[name] = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                try applyOuterType(to: &headers)
                remaining = nil
                if let value = headers.dicomWebHeaderValue("Content-Length") {
                    guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(value) else {
                        throw DicomWebMultipartStreamError.invalidContentLength
                    }
                    try check(0, adding: n, limit: limits.maximumPartBytes, name: "maximumPartBytes")
                    remaining = n
                }
                try check(count, adding: 1, limit: limits.maximumPartCount, name: "maximumPartCount")
                count += 1
                let isRoot = rootID.map { headers.dicomWebHeaderValue("Content-ID") == $0 } ?? (count == 1)
                if isRoot {
                    guard !foundRoot else { throw DicomWebMultipartStreamError.duplicateRoot }
                    foundRoot = true
                }
                events.append(.partHeaders(headers, isRoot: isRoot))
                consume(separator.upperBound - buffer.startIndex)
                partBytes = 0
                state = .payload
            case .payload:
                if let n = remaining {
                    let available = min(n, buffer.count)
                    try emit(available, into: &events)
                    remaining = n - available
                    if remaining != 0 { return }
                    guard let first = buffer.first else { return }
                    let framing = first == 13 ? 2 : 1
                    guard buffer.count >= framing else { return }
                    guard buffer.prefix(framing) == Data(framing == 2 ? [13, 10] : [10]) else {
                        throw DicomWebMultipartStreamError.invalidContentLength
                    }
                    consume(framing)
                    if !pendingPayload.isEmpty { events.append(.payload(pendingPayload)); pendingPayload = Data() }
                    events.append(.partEnd)
                    state = .delimiter
                } else {
                    // Only a whole delimiter line ends the part: the boundary, "--" for the
                    // last one, blanks, then a line break. Anything else is payload.
                    let candidate = delimiterCandidate(finishing: finishing)
                    if let candidate, !candidate.decided {
                        // Keep the candidate until the bytes after it decide what it is.
                        try emit(candidate.payload, into: &events)
                        return
                    }
                    if let candidate {
                        try emit(candidate.payload, into: &events)
                        consume(candidate.lineBreak)
                        if !pendingPayload.isEmpty { events.append(.payload(pendingPayload)); pendingPayload = Data() }
                        events.append(.partEnd)
                        state = .delimiter
                    } else {
                        // boundary bytes + CRLF + leading '--'; two suffix bytes are retained too.
                        let carry = marker.count + 4
                        try emit(max(0, buffer.count - carry), into: &events)
                        return
                    }
                }
            case .epilogue:
                pendingEpilogue.append(buffer)
                buffer = Data()
                while pendingEpilogue.count >= 16 * 1024 {
                    events.append(.epilogue(Data(pendingEpilogue.prefix(16 * 1024))))
                    pendingEpilogue = Data(pendingEpilogue.dropFirst(16 * 1024))
                }
                return
            case .finished: throw DicomWebMultipartStreamError.invalidState
            }
        }
    }
}
