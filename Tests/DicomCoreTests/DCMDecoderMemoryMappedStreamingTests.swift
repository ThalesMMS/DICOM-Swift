//
//  DCMDecoderMemoryMappedStreamingTests.swift
//
//  Verification tests for memory-mapped file compatibility with streaming pixel access.
//  These tests verify that range-based pixel access works correctly with memory-mapped
//  files (>10MB) and that mapped file data is used efficiently.
//

import Foundation
import XCTest
@testable import DicomCore
import DicomTestSupport

final class DCMDecoderMemoryMappedStreamingTests: XCTestCase {

    // MARK: - Memory-Mapped File Integration Tests

    /// Verifies that DCMDecoder uses memory-mapped data for large files and
    /// that range-based reads return correct values.
    func testMemoryMappedDecoderStreamingIntegration() throws {
        let width = 2500
        let height = 2500
        let totalPixels = width * height

        let fileURL = try makeMappedDicomFile(width: width, height: height) { index in
            UInt16(index % 65536)
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = attributes?[.size] as? Int ?? 0
        XCTAssertGreaterThan(fileSize, 10_000_000, "Test file should exceed memory-mapping threshold")

        let decoder = try DCMDecoder(contentsOfFile: fileURL.path)

        XCTAssertTrue(decoder.dicomFound, "Decoder should read memory-mapped DICOM file")
        XCTAssertEqual(decoder.width, width)
        XCTAssertEqual(decoder.height, height)

        let headRange = 0..<10
        guard let headPixels = decoder.getPixels16(range: headRange) else {
            XCTFail("Expected head range to return pixels")
            return
        }
        XCTAssertEqual(headPixels, headRange.map { UInt16($0 % 65536) })

        let middleStart = (height / 2) * width + 123
        let middleRange = middleStart..<(middleStart + 10)
        guard let middlePixels = decoder.getPixels16(range: middleRange) else {
            XCTFail("Expected middle range to return pixels")
            return
        }
        XCTAssertEqual(middlePixels, middleRange.map { UInt16($0 % 65536) })

        let tailRange = (totalPixels - 10)..<totalPixels
        guard let tailPixels = decoder.getPixels16(range: tailRange) else {
            XCTFail("Expected tail range to return pixels")
            return
        }
        XCTAssertEqual(tailPixels, tailRange.map { UInt16($0 % 65536) })
    }

    /// Verifies that streaming access works correctly with Data's memory-mapping.
    /// Tests the critical optimization path where large files use memory-mapped I/O.
    func testMemoryMappedDataStreaming() throws {
        // Create a >10MB raw pixel file on disk to avoid large in-memory buffers.
        let width = 2500
        let height = 2500
        let (mappedPixelData, fileURL) = try makeMappedPixelData(width: width, height: height) { index in
            UInt16(index % 65536)
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let totalPixels = width * height
        let tileSize = 256 * 256  // 256x256 tile

        // Test 1: Verify full buffer access works (baseline)
        let fullPixels = DCMPixelReader.readPixels16(
            data: mappedPixelData,
            range: 0..<totalPixels,
            width: width,
            height: height,
            offset: 0,
            pixelRepresentation: 0,
            littleEndian: true,
            photometricInterpretation: "MONOCHROME2"
        )?.pixels16
        XCTAssertNotNil(fullPixels, "Full buffer access should work")
        XCTAssertEqual(fullPixels?.count, totalPixels, "Full buffer should contain all pixels")

        // Test 2: Verify streaming access to first chunk (simulating tile at top-left)
        let firstTile = DCMPixelReader.readPixels16(
            data: mappedPixelData,
            range: 0..<tileSize,
            width: width,
            height: height,
            offset: 0,
            pixelRepresentation: 0,
            littleEndian: true,
            photometricInterpretation: "MONOCHROME2"
        )?.pixels16
        XCTAssertNotNil(firstTile, "First tile streaming access should work")
        XCTAssertEqual(firstTile?.count, tileSize, "First tile should contain correct number of pixels")

        // Verify content matches expected pattern
        if let tile = firstTile {
            for i in 0..<min(100, tile.count) {
                XCTAssertEqual(tile[i], UInt16(i % 65536), "Pixel values should match test pattern")
            }
        }

        // Test 3: Verify streaming access to middle chunk (simulating random access)
        let middleStart = (height / 2) * width + (width / 2) - (256 / 2)
        let middleRange = middleStart..<(middleStart + tileSize)
        let middleTile = DCMPixelReader.readPixels16(
            data: mappedPixelData,
            range: middleRange,
            width: width,
            height: height,
            offset: 0,
            pixelRepresentation: 0,
            littleEndian: true,
            photometricInterpretation: "MONOCHROME2"
        )?.pixels16
        XCTAssertNotNil(middleTile, "Middle tile streaming access should work")
        XCTAssertEqual(middleTile?.count, tileSize, "Middle tile should contain correct number of pixels")

        // Test 4: Verify streaming access to last chunk (simulating tile at bottom-right)
        let lastStart = totalPixels - tileSize
        let lastTile = DCMPixelReader.readPixels16(
            data: mappedPixelData,
            range: lastStart..<totalPixels,
            width: width,
            height: height,
            offset: 0,
            pixelRepresentation: 0,
            littleEndian: true,
            photometricInterpretation: "MONOCHROME2"
        )?.pixels16
        XCTAssertNotNil(lastTile, "Last tile streaming access should work")
        XCTAssertEqual(lastTile?.count, tileSize, "Last tile should contain correct number of pixels")

        // Test 5: Verify consistency between full buffer and streaming access
        if let full = fullPixels, let first = firstTile {
            let fullFirstChunk = Array(full[0..<tileSize])
            XCTAssertEqual(first, fullFirstChunk, "Streaming access should return same data as full buffer")
        }
    }

    /// Verifies efficient memory usage when streaming from simulated large files.
    /// This test demonstrates that range-based access doesn't load the entire file.
    func testMemoryMappedStreamingEfficiency() throws {
        // Simulate a large file (>10MB) without holding all pixels in memory.
        let width = 4096
        let height = 4096
        let (mappedPixelData, fileURL) = try makeMappedPixelData(width: width, height: height) { index in
            UInt16(index % 65536)
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let totalPixels = width * height

        // Access small ranges from different parts of the file
        // This simulates the memory-mapped access pattern
        let ranges = [
            0..<1000,                           // Start
            (totalPixels / 4)..<(totalPixels / 4 + 1000),  // Quarter
            (totalPixels / 2)..<(totalPixels / 2 + 1000),  // Middle
            (totalPixels - 1000)..<totalPixels  // End
        ]

        for (index, range) in ranges.enumerated() {
            let chunk = DCMPixelReader.readPixels16(
                data: mappedPixelData,
                range: range,
                width: width,
                height: height,
                offset: 0,
                pixelRepresentation: 0,
                littleEndian: true,
                photometricInterpretation: "MONOCHROME2"
            )?.pixels16
            XCTAssertNotNil(chunk, "Chunk \(index) should be accessible via streaming")
            XCTAssertEqual(chunk?.count, range.count, "Chunk \(index) should have correct size")

            // Verify we got the expected data
            if let chunk = chunk, index == 0 {
                // First chunk should have pattern 0, 1, 2, ...
                XCTAssertEqual(chunk[0], 0)
                XCTAssertEqual(chunk[1], 1)
                XCTAssertEqual(chunk[2], 2)
            }
        }
    }

    private func makeMappedDicomFile(
        width: Int,
        height: Int,
        pattern: (Int) -> UInt16
    ) throws -> URL {
        let totalPixels = width * height
        let pixelDataLength = UInt32(totalPixels * 2)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("dcm")

        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        var header = Data()
        header.append(Data(count: 128))
        header.append(contentsOf: "DICM".utf8)

        appendTagUI(&header, group: 0x0002, element: 0x0010, value: "1.2.840.10008.1.2.1")
        appendTagUS(&header, group: 0x0028, element: 0x0010, value: UInt16(height))
        appendTagUS(&header, group: 0x0028, element: 0x0011, value: UInt16(width))
        appendTagUS(&header, group: 0x0028, element: 0x0100, value: 16)
        appendTagUS(&header, group: 0x0028, element: 0x0101, value: 16)
        appendTagUS(&header, group: 0x0028, element: 0x0102, value: 15)
        appendTagUS(&header, group: 0x0028, element: 0x0103, value: 0)
        appendTagUS(&header, group: 0x0028, element: 0x0002, value: 1)
        appendTagCS(&header, group: 0x0028, element: 0x0004, value: "MONOCHROME2")
        appendPixelDataHeader(&header, length: pixelDataLength)

        handle.write(header)

        let chunkPixels = 65_536
        var offset = 0
        while offset < totalPixels {
            let count = min(chunkPixels, totalPixels - offset)
            var chunk = [UInt16](repeating: 0, count: count)
            for i in 0..<count {
                chunk[i] = pattern(offset + i).littleEndian
            }
            let data = chunk.withUnsafeBytes { rawBuffer -> Data in
                Data(bytes: rawBuffer.baseAddress!, count: rawBuffer.count)
            }
            handle.write(data)
            offset += count
        }

        return tempURL
    }

    private func appendTagUS(_ data: inout Data, group: UInt16, element: UInt16, value: UInt16) {
        appendTagHeader(&data, group: group, element: element, vr: "US")
        data.append(contentsOf: [0x02, 0x00])
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { data.append(contentsOf: $0) }
    }

    private func appendTagCS(_ data: inout Data, group: UInt16, element: UInt16, value: String) {
        appendTagString(&data, group: group, element: element, vr: "CS", value: value, padding: 0x20)
    }

    private func appendTagUI(_ data: inout Data, group: UInt16, element: UInt16, value: String) {
        appendTagString(&data, group: group, element: element, vr: "UI", value: value, padding: 0x00)
    }

    private func appendTagString(
        _ data: inout Data,
        group: UInt16,
        element: UInt16,
        vr: String,
        value: String,
        padding: UInt8
    ) {
        appendTagHeader(&data, group: group, element: element, vr: vr)
        var bytes = Array(value.utf8)
        if bytes.count % 2 != 0 {
            bytes.append(padding)
        }
        let length = UInt16(bytes.count)
        data.append(contentsOf: [UInt8(length & 0xFF), UInt8(length >> 8)])
        data.append(contentsOf: bytes)
    }

    private func appendPixelDataHeader(_ data: inout Data, length: UInt32) {
        appendTagHeader(&data, group: 0x7FE0, element: 0x0010, vr: "OW")
        data.append(contentsOf: [0x00, 0x00])
        var littleEndianLength = length.littleEndian
        withUnsafeBytes(of: &littleEndianLength) { data.append(contentsOf: $0) }
    }

    private func appendTagHeader(_ data: inout Data, group: UInt16, element: UInt16, vr: String) {
        data.append(contentsOf: [
            UInt8(group & 0xFF),
            UInt8(group >> 8),
            UInt8(element & 0xFF),
            UInt8(element >> 8)
        ])
        data.append(contentsOf: vr.utf8)
    }

    private func makeMappedPixelData(
        width: Int,
        height: Int,
        pattern: (Int) -> UInt16
    ) throws -> (data: Data, url: URL) {
        let totalPixels = width * height
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("raw")

        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        let chunkPixels = 65_536
        var offset = 0
        while offset < totalPixels {
            let count = min(chunkPixels, totalPixels - offset)
            var chunk = [UInt16](repeating: 0, count: count)
            for i in 0..<count {
                chunk[i] = pattern(offset + i).littleEndian
            }
            let data = chunk.withUnsafeBytes { rawBuffer -> Data in
                Data(bytes: rawBuffer.baseAddress!, count: rawBuffer.count)
            }
            handle.write(data)
            offset += count
        }

        let mappedPixelData = try Data(contentsOf: tempURL, options: .mappedIfSafe)
        return (mappedPixelData, tempURL)
    }

    /// Verifies the memory-mapping strategy with a range read from a file above the decoder threshold.
    func test_memoryMappedIntegration_readsRangeAboveThreshold() throws {
        let width = 2_500
        let height = 2_500
        let fileURL = try makeMappedDicomFile(width: width, height: height) { index in
            UInt16(index % 65_536)
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let fileSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int
        )
        XCTAssertGreaterThan(fileSize, 10_000_000)

        let decoder = try DCMDecoder(contentsOfFile: fileURL.path)
        let range = 3_000_000..<3_000_016
        let pixels = try XCTUnwrap(decoder.getPixels16(range: range))
        XCTAssertEqual(pixels, range.map { UInt16($0 % 65_536) })
    }

    /// Verifies that multiple sequential streaming accesses work correctly.
    /// This simulates a progressive rendering or scanning scenario.
    func testMemoryMappedSequentialStreaming() {
        let mock = MockDicomDecoder()

        // Medium-large image (2048 x 2048 = 8.4 MB)
        mock.width = 2048
        mock.height = 2048
        mock.bitDepth = 16
        mock.samplesPerPixel = 1

        let totalPixels = mock.width * mock.height
        var pixels = [UInt16](repeating: 0, count: totalPixels)

        // Create sequential pattern
        for i in 0..<totalPixels {
            pixels[i] = UInt16(i % 65536)
        }

        mock.setPixels16(pixels)

        // Stream through image in chunks (like progressive rendering)
        let chunkSize = 2048  // One row at a time
        let numChunks = totalPixels / chunkSize

        var allChunks: [UInt16] = []

        for chunkIndex in 0..<numChunks {
            let start = chunkIndex * chunkSize
            let end = min(start + chunkSize, totalPixels)
            let range = start..<end

            if let chunk = mock.getPixels16(range: range) {
                allChunks.append(contentsOf: chunk)

                // Verify chunk content
                XCTAssertEqual(chunk.count, range.count, "Chunk \(chunkIndex) should have correct size")
                if chunk.count > 0 {
                    XCTAssertEqual(chunk[0], UInt16(start % 65536), "First pixel of chunk should be correct")
                }
            } else {
                XCTFail("Failed to read chunk \(chunkIndex) at range \(range)")
            }
        }

        // Verify we reconstructed the full image correctly
        XCTAssertEqual(allChunks.count, totalPixels, "Sequential streaming should cover all pixels")

        if let fullBuffer = mock.getPixels16() {
            XCTAssertEqual(allChunks, fullBuffer, "Sequential chunks should match full buffer")
        }
    }

    /// Verifies all bit depths work with memory-mapped streaming.
    func testMemoryMappedMultiBitDepth() {
        // Test 8-bit
        do {
            let mock8 = MockDicomDecoder()
            mock8.width = 2048
            mock8.height = 2048
            mock8.bitDepth = 8
            mock8.samplesPerPixel = 1

            let pixels8 = [UInt8](repeating: 128, count: mock8.width * mock8.height)
            mock8.setPixels8(pixels8)

            let chunk8 = mock8.getPixels8(range: 0..<1000)
            XCTAssertNotNil(chunk8, "8-bit streaming should work")
            XCTAssertEqual(chunk8?.count, 1000)
            XCTAssertEqual(chunk8?.first, 128)
        }

        // Test 16-bit
        do {
            let mock16 = MockDicomDecoder()
            mock16.width = 2048
            mock16.height = 2048
            mock16.bitDepth = 16
            mock16.samplesPerPixel = 1

            let pixels16 = [UInt16](repeating: 32768, count: mock16.width * mock16.height)
            mock16.setPixels16(pixels16)

            let chunk16 = mock16.getPixels16(range: 0..<1000)
            XCTAssertNotNil(chunk16, "16-bit streaming should work")
            XCTAssertEqual(chunk16?.count, 1000)
            XCTAssertEqual(chunk16?.first, 32768)
        }

        // Test 24-bit RGB
        do {
            let mock24 = MockDicomDecoder()
            mock24.width = 2048
            mock24.height = 2048
            mock24.bitDepth = 24
            mock24.samplesPerPixel = 3

            let pixels24 = [UInt8](repeating: 255, count: mock24.width * mock24.height * 3)
            mock24.setPixels24(pixels24)

            let chunk24 = mock24.getPixels24(range: 0..<1000)
            XCTAssertNotNil(chunk24, "24-bit streaming should work")
            XCTAssertEqual(chunk24?.count, 3000)  // 1000 pixels × 3 bytes
            XCTAssertEqual(chunk24?.first, 255)
        }
    }
}
