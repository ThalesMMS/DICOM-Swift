import XCTest
@testable import DicomCore

final class JPEGLosslessParsingTests: XCTestCase {

    // MARK: - Marker Parsing Tests

    func testMarkerParsingMissingSOI() throws {
        // Test that missing SOI marker is detected

        var jpegData = makeMinimalJPEGLosslessData(width: 2, height: 2)
        jpegData.replaceSubrange(0..<2, with: [0xFF, 0xC3])

        let decoder = JPEGLosslessDecoder()

        assertInvalidDICOMFormat(reasonContains: "SOI", try decoder.decode(data: jpegData))
    }

    func testMarkerParsingEmptyData() throws {
        // Test that empty data is rejected

        let jpegData = Data()
        let decoder = JPEGLosslessDecoder()

        assertInvalidDICOMFormat(reasonContains: "SOI", try decoder.decode(data: jpegData))
    }

    func testMarkerParsingTruncatedData() throws {
        // Test that truncated data is detected

        let jpegData = Data(makeMinimalJPEGLosslessData(width: 2, height: 2).prefix(2))

        let decoder = JPEGLosslessDecoder()

        assertInvalidDICOMFormat(reasonContains: "SOF3", try decoder.decode(data: jpegData))
    }

    func testMarkerParsingMissingSOF3() throws {
        // Test that missing SOF3 marker is detected

        var jpegData = Data()

        // SOI marker
        jpegData.append(contentsOf: [0xFF, 0xD8])

        // SOS marker without SOF3
        jpegData.append(contentsOf: [0xFF, 0xDA])
        let sosLength: UInt16 = 8
        jpegData.append(UInt8(sosLength >> 8))
        jpegData.append(UInt8(sosLength & 0xFF))
        jpegData.append(1)   // 1 component
        jpegData.append(1)   // Component ID
        jpegData.append(0x00) // DC table 0
        jpegData.append(1)   // Selection value
        jpegData.append(0)   // End spectral
        jpegData.append(0)   // Successive approximation

        let decoder = JPEGLosslessDecoder()

        assertInvalidDICOMFormat(reasonContains: "SOF3", try decoder.decode(data: jpegData))
    }

    func testMarkerParsingMissingSOS() throws {
        // Test that missing SOS marker is detected

        guard let jpegData = removingSegment(marker: 0xDA, from: makeMinimalJPEGLosslessData(width: 2, height: 2)) else {
            XCTFail("Failed to remove SOS segment from minimal JPEG Lossless data")
            return
        }

        let decoder = JPEGLosslessDecoder()

        assertInvalidDICOMFormat(reasonContains: "Expected marker prefix", try decoder.decode(data: jpegData))
    }

    /// DRI markers are parsed (restart intervals decode since #1229); a
    /// malformed DRI payload lengths still fail typed.
    func test_driParsing_acceptsValidAndRejectsMalformedPayloadLengths() throws {
        var jpegData = makeMinimalJPEGLosslessData(width: 2, height: 2)
        guard let sosIndex = markerIndex(0xDA, in: jpegData) else {
            XCTFail("Missing SOS marker in minimal JPEG Lossless data")
            return
        }

        let driSegment: [UInt8] = [
            0xFF, JPEGMarker.dri.rawValue,
            0x00, 0x04,
            0x00, 0x04
        ]
        jpegData.insert(contentsOf: driSegment, at: sosIndex)

        let decoder = JPEGLosslessDecoder()
        XCTAssertNoThrow(try decoder.decode(data: jpegData))
        XCTAssertEqual(decoder.restartInterval, 4)

        var truncated = makeMinimalJPEGLosslessData(width: 2, height: 2)
        guard let truncatedSOS = markerIndex(0xDA, in: truncated) else {
            XCTFail("Missing SOS marker in minimal JPEG Lossless data")
            return
        }
        truncated.insert(contentsOf: [0xFF, JPEGMarker.dri.rawValue, 0x00, 0x02], at: truncatedSOS)
        assertInvalidDICOMFormat(reasonContains: "DRI", try JPEGLosslessDecoder().decode(data: truncated))

        var oversized = makeMinimalJPEGLosslessData(width: 2, height: 2)
        guard let oversizedSOS = markerIndex(0xDA, in: oversized) else {
            XCTFail("Missing SOS marker in minimal JPEG Lossless data")
            return
        }
        oversized.insert(
            contentsOf: [0xFF, JPEGMarker.dri.rawValue, 0x00, 0x06, 0x00, 0x04],
            at: oversizedSOS
        )
        oversized = Data(oversized.prefix(oversizedSOS + 6))
        assertInvalidDICOMFormat(reasonContains: "DRI", try JPEGLosslessDecoder().decode(data: oversized))
    }

    func testDecodeRejectsRestartMarkerInEntropyData() throws {
        var jpegData = makeMinimalJPEGLosslessData(width: 1, height: 1)
        guard let eoiIndex = markerIndex(JPEGMarker.eoi.rawValue, in: jpegData) else {
            XCTFail("Missing EOI marker in minimal JPEG Lossless data")
            return
        }

        jpegData.insert(contentsOf: [JPEGMarker.prefix, 0xD0], at: eoiIndex)

        let decoder = JPEGLosslessDecoder()

        assertInvalidDICOMFormat(reasonContains: "restart markers", try decoder.decode(data: jpegData))
    }

    // MARK: - SOF3 Parsing Tests

    func testSOF3ParsingInvalidDimensions() throws {
        // Test that invalid dimensions (0x0) are rejected

        var jpegData = makeMinimalJPEGLosslessData(width: 2, height: 2)
        guard let sof3Index = markerIndex(0xC3, in: jpegData) else {
            XCTFail("Missing SOF3 marker in minimal JPEG Lossless data")
            return
        }
        jpegData[sof3Index + 5] = 0
        jpegData[sof3Index + 6] = 0
        jpegData[sof3Index + 7] = 0
        jpegData[sof3Index + 8] = 0

        let decoder = JPEGLosslessDecoder()

        assertInvalidDICOMFormat(reasonContains: "Invalid SOF3 dimensions", try decoder.decode(data: jpegData))
    }

    func testSOF3ParsingInvalidPrecision() throws {
        // T.81 lossless allows 2...16-bit samples; 1 and 17 are rejected.
        for precision: UInt8 in [0, 1, 17] {
            var jpegData = makeMinimalJPEGLosslessData(width: 2, height: 2)
            guard let sof3Index = markerIndex(0xC3, in: jpegData) else {
                XCTFail("Missing SOF3 marker in minimal JPEG Lossless data")
                return
            }
            jpegData[sof3Index + 4] = precision

            let decoder = JPEGLosslessDecoder()

            assertInvalidDICOMFormat(reasonContains: "Unsupported SOF3 precision", try decoder.decode(data: jpegData))
        }
    }

    func testSOF3ParsingTruncatedPayload() throws {
        // Test that truncated SOF3 payload is detected

        var jpegData = Data()

        // SOI marker
        jpegData.append(contentsOf: [0xFF, 0xD8])

        // SOF3 marker with incomplete payload
        jpegData.append(contentsOf: [0xFF, 0xC3])
        let sof3Length: UInt16 = 11
        jpegData.append(UInt8(sof3Length >> 8))
        jpegData.append(UInt8(sof3Length & 0xFF))
        jpegData.append(16)  // Precision
        jpegData.append(0)   // Height high
        // Missing rest of payload

        let decoder = JPEGLosslessDecoder()

        assertInvalidDICOMFormat(reasonContains: "payload extends beyond data", try decoder.decode(data: jpegData))
    }

    func testSOF3ParsingValidPrecisionValues() throws {
        // Test that all valid precision values (8, 12, 16) are accepted

        for precision in [8, 12, 16] {
            let jpegData = makeMinimalJPEGLosslessData(width: 2, height: 2, precision: precision)

            let decoder = JPEGLosslessDecoder()

            do {
                let result = try decoder.decode(data: jpegData)
                XCTAssertEqual(result.bitDepth, precision, "Decoded bit depth should match SOF3 precision")
            } catch {
                XCTFail("Failed to decode valid \(precision)-bit image: \(error)")
            }
        }
    }

    func testDecodeRejectsSSSSCategoryAboveSixteen() throws {
        // Categories above the precision are legitimate (predictors 4...7 can predict out of range); above 16 is not.
        var jpegData = makeMinimalJPEGLosslessData(width: 1, height: 1, precision: 12)
        guard let dhtIndex = markerIndex(0xC4, in: jpegData) else {
            XCTFail("Missing DHT marker in minimal JPEG Lossless data")
            return
        }

        let symbolValueIndex = dhtIndex + 2 + 2 + 1 + 16
        jpegData[symbolValueIndex] = 17

        let decoder = JPEGLosslessDecoder()

        assertInvalidDICOMFormat(reasonContains: "exceeds the maximum difference category 16", try decoder.decode(data: jpegData))
    }

    // MARK: - SOS Parsing Tests

    func testSOSParsingInvalidComponentCount() throws {
        // Test that invalid component count (0 or > 4) is rejected

        var jpegData = Data()

        // SOI marker
        jpegData.append(contentsOf: [0xFF, 0xD8])

        // SOF3 marker
        jpegData.append(contentsOf: [0xFF, 0xC3])
        let sof3Length: UInt16 = 11
        jpegData.append(UInt8(sof3Length >> 8))
        jpegData.append(UInt8(sof3Length & 0xFF))
        jpegData.append(16)
        jpegData.append(0)
        jpegData.append(2)
        jpegData.append(0)
        jpegData.append(2)
        jpegData.append(1)
        jpegData.append(1)
        jpegData.append(0x11)
        jpegData.append(0)

        // SOS marker with invalid component count
        jpegData.append(contentsOf: [0xFF, 0xDA])
        let sosLength: UInt16 = 6
        jpegData.append(UInt8(sosLength >> 8))
        jpegData.append(UInt8(sosLength & 0xFF))
        jpegData.append(0)   // Invalid: 0 components
        jpegData.append(1)
        jpegData.append(0)
        jpegData.append(0)

        let decoder = JPEGLosslessDecoder()

        assertInvalidDICOMFormat(reasonContains: "Invalid SOS component count", try decoder.decode(data: jpegData))
    }

    func testSOSParsingInvalidSelectionValue() throws {
        // Test that invalid selection value (> 7) is rejected

        var jpegData = makeMinimalJPEGLosslessData(width: 2, height: 2)
        guard let sosIndex = markerIndex(0xDA, in: jpegData) else {
            XCTFail("Missing SOS marker in minimal JPEG Lossless data")
            return
        }
        jpegData[sosIndex + 7] = 8

        let decoder = JPEGLosslessDecoder()

        assertInvalidDICOMFormat(reasonContains: "Invalid SOS selection value", try decoder.decode(data: jpegData))
    }

    func testSOSParsingMissingHuffmanTable() throws {
        // Test that missing referenced Huffman table is detected

        var jpegData = Data()

        // SOI marker
        jpegData.append(contentsOf: [0xFF, 0xD8])

        // SOF3 marker
        jpegData.append(contentsOf: [0xFF, 0xC3])
        let sof3Length: UInt16 = 11
        jpegData.append(UInt8(sof3Length >> 8))
        jpegData.append(UInt8(sof3Length & 0xFF))
        jpegData.append(16)
        jpegData.append(0)
        jpegData.append(2)
        jpegData.append(0)
        jpegData.append(2)
        jpegData.append(1)
        jpegData.append(1)
        jpegData.append(0x11)
        jpegData.append(0)

        // SOS marker referencing non-existent Huffman table
        jpegData.append(contentsOf: [0xFF, 0xDA])
        let sosLength: UInt16 = 8
        jpegData.append(UInt8(sosLength >> 8))
        jpegData.append(UInt8(sosLength & 0xFF))
        jpegData.append(1)
        jpegData.append(1)
        jpegData.append(0x03) // DC table 0, AC table 3 (no DHT defined)
        jpegData.append(1)
        jpegData.append(0)
        jpegData.append(0)

        let decoder = JPEGLosslessDecoder()

        assertInvalidDICOMFormat(reasonContains: "undefined Huffman table", try decoder.decode(data: jpegData))
    }

    private func assertInvalidDICOMFormat(
        reasonContains expectedReason: String? = nil,
        _ expression: @autoclosure () throws -> Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case DICOMError.invalidDICOMFormat(let reason) = error else {
                XCTFail("Expected invalidDICOMFormat error, got \(error)", file: file, line: line)
                return
            }

            if let expectedReason {
                XCTAssertTrue(
                    reason.localizedCaseInsensitiveContains(expectedReason),
                    "Expected invalidDICOMFormat reason to contain '\(expectedReason)', got '\(reason)'",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func markerIndex(_ marker: UInt8, in data: Data) -> Int? {
        guard data.count >= 2 else { return nil }
        for index in 0..<(data.count - 1) where data[index] == 0xFF && data[index + 1] == marker {
            return index
        }
        return nil
    }

    private func removingSegment(marker: UInt8, from data: Data) -> Data? {
        guard let markerStart = markerIndex(marker, in: data), markerStart + 3 < data.count else {
            return nil
        }

        let segmentLength = Int(data[markerStart + 2]) << 8 | Int(data[markerStart + 3])
        let segmentEnd = markerStart + 2 + segmentLength
        guard segmentEnd <= data.count else { return nil }

        var copy = data
        copy.removeSubrange(markerStart..<segmentEnd)
        return copy
    }
}
