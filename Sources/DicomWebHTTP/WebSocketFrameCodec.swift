import Foundation
import Network
import DicomCore

/// RFC 6455 section 5; decoding does not consume an incomplete frame.
enum WebSocketFrameCodec {
    struct Frame: Equatable, Sendable {
        let opcode: UInt8
        let payload: Data
        let final: Bool
    }
    enum Failure: Error { case protocolError, tooLarge }
    static func encode(opcode: UInt8, payload: Data, final: Bool = true) -> Data {
        var result = Data([opcode | (final ? 0x80 : 0)])
        if payload.count < 126 { result.append(UInt8(payload.count)) }
        else if payload.count <= 65535 {
            result.append(126)
            result.append(UInt8(payload.count >> 8)); result.append(UInt8(payload.count & 255))
        } else {
            result.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { result.append(UInt8((UInt64(payload.count) >> shift) & 255)) }
        }
        result.append(payload)
        return result
    }
    static func decode(_ buffer: inout Data, maximumBytes: Int) throws -> Frame? {
        guard buffer.count >= 2 else { return nil }
        let bytes = [UInt8](buffer.prefix(14))
        let opcode = bytes[0] & 15, final = bytes[0] & 128 != 0
        guard bytes[0] & 0x70 == 0, [0, 1, 2, 8, 9, 10].contains(opcode), bytes[1] & 128 != 0 else { throw Failure.protocolError }
        let marker = bytes[1] & 127
        var length = UInt64(marker), index = 2
        if marker == 126 {
            guard bytes.count >= 4 else { return nil }
            length = UInt64(bytes[2]) << 8 | UInt64(bytes[3]); index = 4
            guard length >= 126 else { throw Failure.protocolError }
        } else if marker == 127 {
            guard bytes.count >= 10 else { return nil }
            guard bytes[2] & 128 == 0 else { throw Failure.protocolError }
            length = bytes[2..<10].reduce(0) { $0 << 8 | UInt64($1) }; index = 10
            guard length > 65535 else { throw Failure.protocolError }
        }
        guard opcode < 8 || (final && length <= 125) else { throw Failure.protocolError }
        guard length <= UInt64(max(0, maximumBytes)) else { throw Failure.tooLarge }
        guard buffer.count >= index + 4, length <= UInt64(buffer.count - index - 4) else { return nil }
        let mask = bytes[index..<(index + 4)]
        let start = buffer.startIndex + index + 4
        let payload = Data(buffer[start..<(start + Int(length))].enumerated().map { $0.element ^ mask[mask.startIndex + $0.offset % 4] })
        buffer = Data(buffer.dropFirst(index + 4 + Int(length)))
        return Frame(opcode: opcode, payload: payload, final: final)
    }
}

actor DicomWebHTTPWebSocketSession: DicomWebNotificationConnection {
    private let connection: NWConnection
    private let maximumBytes: Int
    private var closed = false
    init(connection: NWConnection, maximumBytes: Int) {
        self.connection = connection; self.maximumBytes = maximumBytes
    }
    private func write(opcode: UInt8, payload: Data) async throws {
        guard !closed else { throw CancellationError() }
        let data = WebSocketFrameCodec.encode(opcode: opcode, payload: payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    func send(text: String) async throws {
        guard text.utf8.count <= maximumBytes else { await close(code: 1009); throw WebSocketFrameCodec.Failure.tooLarge }
        try await write(opcode: 1, payload: Data(text.utf8))
    }
    func close() async { await close(code: 1001) }
    func close(code: UInt16) async {
        guard !closed else { return }
        try? await write(opcode: 8, payload: Data([UInt8(code >> 8), UInt8(code & 255)]))
        closed = true
        connection.cancel()
    }
    func run(buffer initial: Data, channel: HTTPByteChannel) async {
        var buffer = initial
        var fragmented = false
        var messageBytes = 0
        do {
            while !closed && !Task.isCancelled {
                while let frame = try WebSocketFrameCodec.decode(&buffer, maximumBytes: maximumBytes) {
                    switch frame.opcode {
                    case 8:
                        guard frame.payload.count != 1 else { throw WebSocketFrameCodec.Failure.protocolError }
                        if frame.payload.count >= 2 {
                            let bytes = [UInt8](frame.payload)
                            let code = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
                            guard (1000...1014).contains(code) && ![1004, 1005, 1006].contains(code) || (3000...4999).contains(code),
                                  String(data: frame.payload.dropFirst(2), encoding: .utf8) != nil else { throw WebSocketFrameCodec.Failure.protocolError }
                        }
                        try await write(opcode: 8, payload: frame.payload)
                        closed = true
                        return
                    case 9: try await write(opcode: 10, payload: frame.payload)
                    case 10: break
                    default:
                        guard (frame.opcode == 0) == fragmented else { throw WebSocketFrameCodec.Failure.protocolError }
                        guard frame.payload.count <= maximumBytes - messageBytes else { throw WebSocketFrameCodec.Failure.tooLarge }
                        messageBytes += frame.payload.count
                        fragmented = !frame.final
                        if frame.final { messageBytes = 0 }
                    }
                }
                buffer.append(try await channel.next())
            }
        } catch WebSocketFrameCodec.Failure.tooLarge { await close(code: 1009) }
        catch WebSocketFrameCodec.Failure.protocolError { await close(code: 1002) }
        catch {}
    }
}
