import Foundation
import XCTest
@testable import DicomWebHTTP

final class WebSocketFrameCodecTests: XCTestCase {
    func masked(_ data: Data, opcode: UInt8 = 1) -> Data {
        var bytes = [UInt8](WebSocketFrameCodec.encode(opcode: opcode, payload: data))
        let index = bytes[1] == 127 ? 10 : bytes[1] == 126 ? 4 : 2
        bytes[1] |= 128
        let mask: [UInt8] = [1, 2, 3, 4]
        return Data(bytes.prefix(index) + mask + bytes.dropFirst(index).enumerated().map { $0.element ^ mask[$0.offset % 4] })
    }
    func test_lengthForms_maskingAndIncompleteInput() throws {
        for count in [0, 1, 125, 126, 65535, 65536] {
            let payload = Data(repeating: 42, count: count)
            let encoded = WebSocketFrameCodec.encode(opcode: 1, payload: payload)
            XCTAssertEqual(encoded[0], 129); XCTAssertEqual(encoded[1] & 128, 0)
            var bytes = masked(payload)
            var partial = Data(bytes.dropLast())
            XCTAssertNil(try WebSocketFrameCodec.decode(&partial, maximumBytes: 65536))
            let decoded = try WebSocketFrameCodec.decode(&bytes, maximumBytes: 65536)
            XCTAssertEqual(decoded?.payload, payload); XCTAssertTrue(bytes.isEmpty)
        }
    }
    func test_unmasked_reservedAndOversizeFramesAreRejected() {
        for data in [Data([0x81, 0]), Data([0xC1, 0x80, 0, 0, 0, 0]), Data([0x83, 0x80, 0, 0, 0, 0]),
                     Data([0x09, 0x80, 0, 0, 0, 0]), Data([0x89, 0xFE, 0, 126])] {
            var bytes = data
            XCTAssertThrowsError(try WebSocketFrameCodec.decode(&bytes, maximumBytes: 65536))
        }
        var bytes = Data([0x81, 0xFF, 0, 0, 0, 0, 0, 1, 0, 0])
        XCTAssertThrowsError(try WebSocketFrameCodec.decode(&bytes, maximumBytes: 100)) { error in
            guard case WebSocketFrameCodec.Failure.tooLarge = error else { return XCTFail("Expected 1009") }
        }
    }
    func test_ping_close_andMultipleFrames() throws {
        var bytes = masked(Data("ping".utf8), opcode: 9) + masked(Data([3, 232]), opcode: 8)
        XCTAssertEqual(try WebSocketFrameCodec.decode(&bytes, maximumBytes: 125)?.opcode, 9)
        let close = try WebSocketFrameCodec.decode(&bytes, maximumBytes: 125)
        XCTAssertEqual(close?.opcode, 8); XCTAssertEqual(close?.payload, Data([3, 232]))
        XCTAssertTrue(bytes.isEmpty)
    }
}
