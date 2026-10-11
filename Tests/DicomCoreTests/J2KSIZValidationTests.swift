@testable import DicomJPEG2000
import Foundation
import XCTest

/// The decoder core refuses a SIZ that would divide by zero or overflow, with a typed error, also for callers that
/// skip the backend's codestream inspector (#3018).
final class J2KSIZValidationTests: XCTestCase {
    // SIZ field offsets in a codestream that starts with SOC (FF4F) and SIZ (FF51).
    private enum Field: Int {
        case xsiz = 8, ysiz = 12, xosiz = 16, yosiz = 20, xtsiz = 24, ytsiz = 28, xtosiz = 32, ytosiz = 36
    }

    func test_validCodestream_decodes() async throws {
        let image = try await J2KDecoder().decode(try await codestream())
        XCTAssertEqual(image.width, 16)
    }

    func test_zeroTileSize_isRefused() async throws {
        try await assertRefused(patching: [(.xtsiz, 0)]) { if case .invalidTileConfiguration = $0 { true } else { false } }
        try await assertRefused(patching: [(.ytsiz, 0)]) { if case .invalidTileConfiguration = $0 { true } else { false } }
    }

    func test_imageOffsetOutsideTheImage_isRefused() async throws {
        try await assertRefused(patching: [(.xosiz, 16)]) { if case .invalidDimensions = $0 { true } else { false } }
        try await assertRefused(patching: [(.yosiz, 40)]) { if case .invalidDimensions = $0 { true } else { false } }
    }

    func test_tileOffsetBeyondTheImageOffset_isRefused() async throws {
        try await assertRefused(patching: [(.xtosiz, 4)]) { if case .invalidTileConfiguration = $0 { true } else { false } }
    }

    func test_zeroComponents_isRefused() async throws {
        var bytes = [UInt8](try await codestream())
        bytes[40] = 0
        bytes[41] = 0
        await assertRefused(Data(bytes)) { if case .invalidComponentConfiguration = $0 { true } else { false } }
    }

    func test_zeroSubsampling_isRefused() async throws {
        var bytes = [UInt8](try await codestream())
        bytes[43] = 0
        await assertRefused(Data(bytes)) { if case .invalidComponentConfiguration = $0 { true } else { false } }
    }

    func test_extentsWhoseProductsOverflow_areRefused() async throws {
        // A 0xFFFFFFFF square: in 1x1 tiles the tile count overflows, and in one tile the sample count does.
        try await assertRefused(patching: [(.xsiz, 0xFFFF_FFFF), (.ysiz, 0xFFFF_FFFF), (.xtsiz, 1), (.ytsiz, 1)]) {
            if case .invalidTileConfiguration = $0 { true } else { false }
        }
        var bytes = [UInt8](try await codestream())
        for (field, value) in [(Field.xsiz, UInt32.max), (.ysiz, .max), (.xtsiz, .max), (.ytsiz, .max)] {
            write(value, at: field.rawValue, in: &bytes)
        }
        await assertRefused(Data(bytes)) { if case .invalidDimensions = $0 { true } else { false } }
    }

    private func codestream() async throws -> Data {
        try await J2KEncoder().encode(J2KImage(width: 16, height: 16, components: 1))
    }

    private func assertRefused(
        patching fields: [(Field, UInt32)], file: StaticString = #filePath, line: UInt = #line,
        _ matches: (J2KError) -> Bool
    ) async throws {
        var bytes = [UInt8](try await codestream())
        for (field, value) in fields { write(value, at: field.rawValue, in: &bytes) }
        await assertRefused(Data(bytes), file: file, line: line, matches)
    }

    private func assertRefused(
        _ data: Data, file: StaticString = #filePath, line: UInt = #line, _ matches: (J2KError) -> Bool
    ) async {
        do {
            _ = try await J2KDecoder().decode(data)
            XCTFail("the SIZ was accepted", file: file, line: line)
        } catch let error as J2KError {
            XCTAssertTrue(matches(error), "unexpected \(error)", file: file, line: line)
        } catch {
            XCTFail("untyped \(error)", file: file, line: line)
        }
    }

    private func write(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        bytes.replaceSubrange(offset..<(offset + 4), with: withUnsafeBytes(of: value.bigEndian, Array.init))
    }
}
