import Foundation
import XCTest
@testable import DicomCore

final class JPEGLosslessRestartIntervalTests: XCTestCase {
    func test_8BitMultipleRestartIntervals_decodeByteExactly() throws {
        try assertMultipleRestartIntervalDecode(
            precision: 8,
            samples: [
                0, 1, 255, 254, 128,
                127, 64, 32, 16, 8,
                255, 0, 200, 100, 50,
                25, 75, 125, 175, 225,
                2, 4, 6, 8, 10
            ]
        )
    }

    func test_12BitMultipleRestartIntervals_decodeByteExactly() throws {
        try assertMultipleRestartIntervalDecode(
            precision: 12,
            samples: [
                0, 1, 4_095, 4_094, 2_048,
                2_047, 1_024, 512, 256, 128,
                4_095, 0, 3_000, 2_000, 1_000,
                100, 200, 300, 400, 500,
                4_000, 3_500, 2_500, 1_500, 50
            ]
        )
    }

    func test_16BitMultipleRestartIntervals_decodeByteExactly() throws {
        try assertMultipleRestartIntervalDecode(
            precision: 16,
            samples: [
                0, 1, 65_535, 65_534, 32_767,
                1_234, 50_000, 40_000, 30_000, 42,
                43, 44, 60_000, 59_999, 100,
                200, 300, 400, 500, 600,
                65_000, 55_000, 45_000, 35_000, 25_000
            ]
        )
    }

    func test_missingRestartMarkers_failWithTypedFormatError() throws {
        let stream = Self.restartStream()
        let ranges = Self.restartMarkerRanges(in: stream)
        XCTAssertEqual(ranges.count, 4)
        for missingMarker in ranges.indices {
            var missing = stream
            missing.removeSubrange(ranges[missingMarker])
            assertInvalidFormat(missing, reasonContains: "restart marker")
        }
    }

    func test_outOfOrderRestartMarker_failsWithExpectedAndFoundNumbers() throws {
        var stream = Self.restartStream()
        let ranges = Self.restartMarkerRanges(in: stream)
        XCTAssertEqual(ranges.count, 4)
        stream[ranges[1].lowerBound + 1] = 0xD5

        assertInvalidFormat(stream, reasonContains: "expected RST1, found RST5")
    }

    func test_malformedRestartMarker_failsWithTypedFormatError() throws {
        var stream = Self.restartStream()
        let ranges = Self.restartMarkerRanges(in: stream)
        XCTAssertEqual(ranges.count, 4)
        stream[ranges[0].lowerBound + 1] = 0xE1

        assertInvalidFormat(stream, reasonContains: "Expected JPEG restart marker")
    }

    func test_entropyGarbageBeforeRestartMarker_failsWithTypedFormatError() throws {
        var stream = Self.restartStream()
        let ranges = Self.restartMarkerRanges(in: stream)
        XCTAssertEqual(ranges.count, 4)
        stream.insert(0x00, at: ranges[0].lowerBound)

        assertInvalidFormat(stream, reasonContains: "restart marker")
    }

    func test_fillBytesBeforeRestartMarkers_remainAccepted() throws {
        var stream = Self.restartStream()
        for range in Self.restartMarkerRanges(in: stream).reversed() {
            stream.insert(JPEGMarker.prefix, at: range.lowerBound)
        }

        let result = try JPEGLosslessDecoder().decode(data: stream)
        XCTAssertEqual(
            Self.decodedBytes(result.pixels, precision: 12),
            Self.expectedBytes(Self.restartSamples, precision: 12)
        )
    }

    func test_midRowRestartInterval_isRejectedAsNonConformant() {
        let stream = makeJPEGLosslessStream(
            planes: [Array(repeating: 2_048, count: 25)],
            width: 5,
            height: 5,
            precision: 12,
            restartInterval: 3
        )

        assertInvalidFormat(stream, reasonContains: "multiple of the MCU row width")
    }

    func test_restartMarkerSequence_wrapsFromRST7ToRST0() throws {
        let samples = Array(0..<20)
        let stream = makeJPEGLosslessStream(
            planes: [samples],
            width: 2,
            height: 10,
            precision: 8,
            restartInterval: 2
        )

        XCTAssertEqual(Self.restartMarkerNumbers(in: stream), [0, 1, 2, 3, 4, 5, 6, 7, 0])
        let result = try JPEGLosslessDecoder().decode(data: stream)
        XCTAssertEqual(result.pixels.map(Int.init), samples)
    }

    func test_noRestartStream_retainsByteExactDecode() throws {
        let samples = [
            0, 1, 4_095, 4_094, 2_048,
            2_047, 1_024, 512, 256, 128,
            4_095, 0, 3_000, 2_000, 1_000
        ]
        let stream = makeJPEGLosslessStream(
            planes: [samples],
            width: 5,
            height: 3,
            precision: 12
        )

        XCTAssertNil(stream.range(of: Data([0xFF, JPEGMarker.dri.rawValue])))
        XCTAssertTrue(Self.restartMarkerRanges(in: stream).isEmpty)
        let result = try JPEGLosslessDecoder().decode(data: stream)
        XCTAssertEqual(Self.decodedBytes(result.pixels, precision: 12), Self.expectedBytes(samples, precision: 12))
    }

    private func assertMultipleRestartIntervalDecode(
        precision: Int,
        samples: [Int],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let stream = makeJPEGLosslessStream(
            planes: [samples],
            width: 5,
            height: 5,
            precision: precision,
            restartInterval: 5
        )

        XCTAssertNotNil(stream.range(of: Data([0xFF, JPEGMarker.dri.rawValue, 0x00, 0x04, 0x00, 0x05])),
                        file: file,
                        line: line)
        XCTAssertEqual(Self.restartMarkerNumbers(in: stream), [0, 1, 2, 3], file: file, line: line)

        let result = try JPEGLosslessDecoder().decode(data: stream)
        XCTAssertEqual(result.width, 5, file: file, line: line)
        XCTAssertEqual(result.height, 5, file: file, line: line)
        XCTAssertEqual(result.bitDepth, precision, file: file, line: line)
        XCTAssertEqual(result.componentCount, 1, file: file, line: line)
        XCTAssertEqual(Self.decodedBytes(result.pixels, precision: precision),
                       Self.expectedBytes(samples, precision: precision),
                       file: file,
                       line: line)
    }

    private func assertInvalidFormat(
        _ stream: Data,
        reasonContains expectedText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try JPEGLosslessDecoder().decode(data: stream), file: file, line: line) { error in
            guard case DICOMError.invalidDICOMFormat(let reason) = error else {
                return XCTFail("Expected invalidDICOMFormat, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(reason.contains(expectedText), "Unexpected reason: \(reason)", file: file, line: line)
        }
    }

    private static func restartStream() -> Data {
        makeJPEGLosslessStream(
            planes: [restartSamples],
            width: 5,
            height: 5,
            precision: 12,
            restartInterval: 5
        )
    }

    private static let restartSamples = [
        0, 1, 4_095, 4_094, 2_048,
        2_047, 1_024, 512, 256, 128,
        4_095, 0, 3_000, 2_000, 1_000,
        100, 200, 300, 400, 500,
        4_000, 3_500, 2_500, 1_500, 50
    ]

    private static func restartMarkerRanges(in data: Data) -> [Range<Data.Index>] {
        guard data.count >= 2 else { return [] }
        var ranges: [Range<Data.Index>] = []
        var index = data.startIndex
        while index < data.index(before: data.endIndex) {
            let next = data.index(after: index)
            if data[index] == JPEGMarker.prefix, JPEGMarker.isRestart(data[next]) {
                ranges.append(index..<data.index(after: next))
                index = data.index(after: next)
            } else {
                index = next
            }
        }
        return ranges
    }

    private static func restartMarkerNumbers(in data: Data) -> [Int] {
        restartMarkerRanges(in: data).map { range in
            Int(data[data.index(after: range.lowerBound)] - 0xD0)
        }
    }

    private static func decodedBytes(_ pixels: [UInt16], precision: Int) -> Data {
        if precision <= 8 {
            return Data(pixels.map(UInt8.init))
        }
        var bytes = Data(capacity: pixels.count * 2)
        for pixel in pixels {
            bytes.append(UInt8(pixel & 0x00FF))
            bytes.append(UInt8(pixel >> 8))
        }
        return bytes
    }

    private static func expectedBytes(_ samples: [Int], precision: Int) -> Data {
        decodedBytes(samples.map(UInt16.init), precision: precision)
    }
}
