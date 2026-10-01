import Foundation

/// A T.808 message. Extended classes retain their auxiliary packet count.
public struct DicomJPIPMessage: Sendable, Equatable {
    public let classID: Int
    public let codestream: Int
    public let binID: Int
    public let offset: Int
    public let isComplete: Bool
    public let auxiliary: Int?
    public let body: Data

    public init(classID: Int, codestream: Int, binID: Int, offset: Int,
                isComplete: Bool = false, auxiliary: Int? = nil, body: Data) {
        self.classID = classID
        self.codestream = codestream
        self.binID = binID
        self.offset = offset
        self.isComplete = isComplete
        self.auxiliary = auxiliary
        self.body = body
    }
}

public enum DicomJPIPMessageError: Error, Sendable, Equatable {
    case overlongVBAS
    case truncatedVBAS
    case truncatedMessage
    case invalidIndicator
    case unknownClass(Int)
    case offsetOverflow
    case messageTooLarge
    case tooManyBins
    case totalBytesExceeded
    case messageAfterEOR
    case invalidEORReason(UInt8)
}

public struct DicomJPIPEndOfResponse: Sendable, Equatable {
    public let reason: UInt8
    public let body: Data
    public var windowDone: Bool { reason == 1 || reason == 2 }
}

/// Incremental response parser. Call `finish()` only at the HTTP entity boundary.
/// Incomplete messages are retained; only complete messages are returned by `feed`.
public struct DicomJPIPMessageParser: Sendable {
    private var buffer = Data()
    private var inheritedClass = 0
    private var inheritedCodestream = 0
    private var received = 0
    private var bins = Set<String>()
    private let maximumMessageLength: Int
    private let maximumBins: Int
    private let maximumTotalBytes: Int
    public private(set) var endOfResponse: DicomJPIPEndOfResponse?
    private enum Incomplete: Error { case integer, body }
    private var incompleteInteger = false

    public init(maximumMessageLength: Int = 32 * 1_024 * 1_024,
                maximumBins: Int = 65_536, maximumTotalBytes: Int = 64 * 1_024 * 1_024) {
        self.maximumMessageLength = max(0, maximumMessageLength)
        self.maximumBins = max(0, maximumBins)
        self.maximumTotalBytes = max(0, maximumTotalBytes)
    }

    public mutating func feed(_ chunk: Data) throws -> [DicomJPIPMessage] {
        guard chunk.count <= maximumTotalBytes - received else { throw DicomJPIPMessageError.totalBytesExceeded }
        guard endOfResponse == nil || chunk.isEmpty else { throw DicomJPIPMessageError.messageAfterEOR }
        received += chunk.count
        buffer.append(chunk)
        var messages: [DicomJPIPMessage] = []
        var consumed = 0
        defer {
            if consumed > 0 { buffer = Data(buffer.dropFirst(consumed)) }
        }
        while consumed < buffer.count {
            var cursor = consumed
            do {
                let first = buffer[cursor]
                cursor += 1
                if first == 0 {
                    guard cursor < buffer.count else { throw Incomplete.body }
                    let reason = buffer[cursor]
                    guard (1...7).contains(reason) || reason == 255 else {
                        throw DicomJPIPMessageError.invalidEORReason(reason)
                    }
                    cursor += 1
                    let length = try integer(&cursor)
                    guard length <= maximumMessageLength else { throw DicomJPIPMessageError.messageTooLarge }
                    guard length <= buffer.count - cursor else { throw Incomplete.body }
                    guard cursor + length == buffer.count else { throw DicomJPIPMessageError.messageAfterEOR }
                    endOfResponse = DicomJPIPEndOfResponse(reason: reason, body: buffer.subdata(in: cursor..<cursor + length))
                    consumed = cursor + length
                    break
                }
                let indicator = (first >> 5) & 3
                guard indicator != 0 else { throw DicomJPIPMessageError.invalidIndicator }
                let binID = try integer(&cursor, first: first, seed: Int(first & 15))
                let classID: Int
                if indicator >= 2 { classID = try integer(&cursor) }
                else { classID = inheritedClass }
                guard [0, 1, 2, 4, 5, 6, 8].contains(classID) else {
                    throw DicomJPIPMessageError.unknownClass(classID)
                }
                let codestream = indicator == 3 ? try integer(&cursor) : inheritedCodestream
                let offset = try integer(&cursor)
                let length = try integer(&cursor)
                guard length <= maximumMessageLength else { throw DicomJPIPMessageError.messageTooLarge }
                guard offset <= Int.max - length else { throw DicomJPIPMessageError.offsetOverflow }
                let auxiliary = classID % 2 == 1 ? try integer(&cursor) : nil
                guard length <= buffer.count - cursor else { throw Incomplete.body }
                let key = "\(codestream):\(classID & ~1):\(binID)"
                guard bins.contains(key) || bins.count < maximumBins else { throw DicomJPIPMessageError.tooManyBins }
                bins.insert(key)
                messages.append(DicomJPIPMessage(classID: classID, codestream: codestream, binID: binID,
                    offset: offset, isComplete: first & 16 != 0, auxiliary: auxiliary,
                    body: buffer.subdata(in: cursor..<cursor + length)))
                inheritedClass = classID
                inheritedCodestream = codestream
                consumed = cursor + length
                incompleteInteger = false
            } catch Incomplete.integer {
                incompleteInteger = true
                break
            } catch Incomplete.body {
                incompleteInteger = false
                break
            }
        }
        return messages
    }

    public func finish() throws {
        if !buffer.isEmpty {
            throw incompleteInteger ? DicomJPIPMessageError.truncatedVBAS : .truncatedMessage
        }
    }

    private func integer(_ cursor: inout Int, first: UInt8? = nil, seed: Int = 0) throws -> Int {
        var value = seed
        var continuation = first.map { $0 & 128 != 0 } ?? true
        var count = first == nil ? 0 : 1
        while continuation {
            guard cursor < buffer.count else { throw Incomplete.integer }
            let byte = buffer[cursor]
            cursor += 1
            count += 1
            guard count <= 10, value <= (Int.max - Int(byte & 127)) / 128 else {
                throw DicomJPIPMessageError.overlongVBAS
            }
            if first == nil && count == 1 && byte == 128 { throw DicomJPIPMessageError.overlongVBAS }
            value = value * 128 + Int(byte & 127)
            continuation = byte & 128 != 0
        }
        return value
    }
}
