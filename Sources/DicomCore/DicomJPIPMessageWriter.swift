import Foundation

/// Stateless T.808 message encoder. Every message explicitly identifies its class and codestream.
public struct DicomJPIPMessageWriter: Sendable {
    public let maximumMessageBytes: Int

    public init(maximumMessageBytes: Int = 32 * 1_024 * 1_024) {
        self.maximumMessageBytes = max(0, maximumMessageBytes)
    }

    public func encode(_ message: DicomJPIPMessage) throws -> Data {
        guard [0, 1, 2, 4, 5, 6, 8].contains(message.classID) else {
            throw DicomJPIPMessageError.unknownClass(message.classID)
        }
        guard message.binID >= 0, message.codestream >= 0, message.offset >= 0,
              message.offset <= Int.max - message.body.count,
              message.auxiliary.map({ $0 >= 0 }) ?? true,
              (message.classID % 2 == 1) == (message.auxiliary != nil) else {
            throw DicomJPIPCacheError.invalidMessage
        }
        // At most 61 header bytes for the supported nonnegative Int fields.
        guard message.body.count <= maximumMessageBytes else { throw DicomJPIPMessageError.messageTooLarge }
        var suffix: [UInt8] = []
        var bin = message.binID
        while bin > 15 { suffix.insert(UInt8(bin & 127), at: 0); bin >>= 7 }
        var output = Data([UInt8(bin) | 0x60 | (message.isComplete ? 0x10 : 0) | (suffix.isEmpty ? 0 : 0x80)])
        for (index, byte) in suffix.enumerated() { output.append(byte | (index + 1 < suffix.count ? 128 : 0)) }
        for value in [message.classID, message.codestream, message.offset, message.body.count] {
            output.append(Self.vbas(value))
        }
        if let auxiliary = message.auxiliary { output.append(Self.vbas(auxiliary)) }
        guard output.count <= maximumMessageBytes - message.body.count else {
            throw DicomJPIPMessageError.messageTooLarge
        }
        output.append(message.body)
        return output
    }

    public func endOfResponse(reason: UInt8, body: Data = Data()) throws -> Data {
        guard (1...7).contains(reason) || reason == 255 else {
            throw DicomJPIPMessageError.invalidEORReason(reason)
        }
        let length = Self.vbas(body.count)
        guard maximumMessageBytes >= 2 + length.count,
              body.count <= maximumMessageBytes - 2 - length.count else {
            throw DicomJPIPMessageError.messageTooLarge
        }
        return Data([0, reason]) + length + body
    }

    static func vbas(_ value: Int) -> Data {
        var value = value
        var bytes = [UInt8(value & 127)]
        value >>= 7
        while value > 0 { bytes.insert(UInt8(value & 127) | 128, at: 0); value >>= 7 }
        return Data(bytes)
    }
}
