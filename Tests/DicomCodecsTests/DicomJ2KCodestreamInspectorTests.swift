import Foundation
import XCTest
@testable import DicomCodecs

final class DicomJ2KCodestreamInspectorTests: XCTestCase {
    func test_componentAndTileOverrides_resolveLosslessCodingByPrecedence() throws {
        let irreversible = coc(false), quantized = qcc(2)
        for stream in [codestream(main: irreversible), codestream(main: quantized),
                       codestream(tile: cod(false)), codestream(tile: qcd(2)),
                       codestream(tile: irreversible), codestream(tile: quantized)] {
            XCTAssertFalse(try DicomJ2KCodestreamInspector.inspect(stream).isLosslessCoding)
        }
        for stream in [codestream(), codestream(main: irreversible, tile: cod(true)),
                       codestream(main: quantized, tile: qcd(0)),
                       codestream(tile: cod(false) + coc(true)),
                       codestream(tile: qcd(2) + qcc(0))] {
            XCTAssertTrue(try DicomJ2KCodestreamInspector.inspect(stream).isLosslessCoding)
        }
    }

    func test_secondTileOverrideAndMissingTiles_areNotClassifiedLossless() throws {
        XCTAssertFalse(try DicomJ2KCodestreamInspector.inspect(codestream(tiles: 2, secondTile: cod(false))).isLosslessCoding)
        var missing = codestream(tiles: 2)
        let second = try XCTUnwrap(missing.range(of: Data([0xFF, 0x90]), in: 60..<missing.count))
        // Remove every tile-part: main-header defaults alone do not establish lossless coding.
        missing = Data(missing.prefix(second.lowerBound)) + Data([0xFF, 0xD9])
        XCTAssertThrowsError(try DicomJ2KCodestreamInspector.inspect(missing)) {
            XCTAssertEqual($0 as? DicomJ2KCodestreamInspector.Failure, .invalidStream)
        }
    }

    func test_tileParts_rejectDuplicateSkippedOutOfOrderAndIncompleteStructures() throws {
        let original = codestream()
        let start = try XCTUnwrap(original.range(of: Data([0xFF, 0x90]))).lowerBound
        let header = Data(original.prefix(start))
        var first = Data(original[start..<(original.count - 2)])
        first[11] = 2
        var second = first
        second[10] = 1
        let eoc = Data([0xFF, 0xD9])
        XCTAssertTrue(try DicomJ2KCodestreamInspector.inspect(header + first + second + eoc).isLosslessCoding)
        // Issue #2858: a TNsot one short of the parts written, as some encoders emit, is accepted.
        var third = second
        third[10] = 2
        XCTAssertTrue(try DicomJ2KCodestreamInspector.inspect(header + first + second + third + eoc).isLosslessCoding)
        var inconsistent = second
        inconsistent[11] = 3
        for parts in [first + first, second + first, second, first, first + inconsistent] {
            XCTAssertThrowsError(try DicomJ2KCodestreamInspector.inspect(header + parts + eoc)) {
                XCTAssertEqual($0 as? DicomJ2KCodestreamInspector.Failure, .invalidStream)
            }
        }
    }

    /// PS3.5 A.4: an odd fragment ends with one pad byte after EOC; GDCM and GE write 0xFF, others 0x00 (issue #2487).
    func test_endOfCodestream_toleratesOneEvenLengthPadByteOfEitherValue() throws {
        let stream = codestream()
        XCTAssertTrue(try DicomJ2KCodestreamInspector.inspect(stream).hasEndOfCodestream)
        XCTAssertTrue(try DicomJ2KCodestreamInspector.inspect(stream + Data([0x00])).hasEndOfCodestream)
        XCTAssertTrue(try DicomJ2KCodestreamInspector.inspect(stream + Data([0xFF])).hasEndOfCodestream)
        // Issue #2858: real CT frames pad with whatever byte the encoder's buffer held.
        XCTAssertTrue(try DicomJ2KCodestreamInspector.inspect(stream + Data([0x5A])).hasEndOfCodestream)
        XCTAssertNotEqual((try? DicomJ2KCodestreamInspector.inspect(stream + Data([0xFF, 0xFF])))?.hasEndOfCodestream, true, "two bytes are payload, not padding")
        XCTAssertNotEqual((try? DicomJ2KCodestreamInspector.inspect(stream.dropLast(2) + Data([0xFF])))?.hasEndOfCodestream, true, "a pad byte is no EOC")
    }

    private func cod(_ reversible: Bool) -> Data { Data([0xFF, 0x52, 0, 12, 0, 0, 0, 1, 0, 0, 4, 4, 0, reversible ? 1 : 0]) }
    private func coc(_ reversible: Bool) -> Data { Data([0xFF, 0x53, 0, 9, 0, 0, 0, 4, 4, 0, reversible ? 1 : 0]) }
    private func qcd(_ style: UInt8) -> Data { Data([0xFF, 0x5C, 0, style == 0 ? 4 : 5, style, 0x40]) + (style == 0 ? Data() : Data([0])) }
    private func qcc(_ style: UInt8) -> Data { Data([0xFF, 0x5D, 0, style == 0 ? 5 : 6, 0, style, 0x40]) + (style == 0 ? Data() : Data([0])) }

    private func codestream(main: Data = Data(), tile: Data = Data(), tiles: Int = 1, secondTile: Data = Data()) -> Data {
        var siz = Data([0xFF, 0x4F, 0xFF, 0x51, 0, 41, 0, 0])
        for value in [tiles, 1, 0, 0, 1, 1, 0, 0] {
            withUnsafeBytes(of: UInt32(value).bigEndian) { siz.append(contentsOf: $0) }
        }
        siz.append(contentsOf: [0, 1, 7, 1, 1])
        var stream = siz + cod(true) + qcd(0) + main
        for index in 0..<tiles {
            let overrides = index == 0 ? tile : secondTile
            stream.append(contentsOf: [0xFF, 0x90, 0, 10, 0, UInt8(index)])
            withUnsafeBytes(of: UInt32(14 + overrides.count).bigEndian) { stream.append(contentsOf: $0) }
            stream.append(contentsOf: [0, 1])
            stream.append(overrides)
            stream.append(contentsOf: [0xFF, 0x93])
        }
        return stream + Data([0xFF, 0xD9])
    }
}
