import XCTest
@testable import DicomCore
import DicomTestSupport

/// Tests for streaming/range-based pixel data access in DCMDecoder.
/// These tests verify correctness of range-based pixel reading without
/// requiring full pixel buffers to be loaded into memory.
final class DCMDecoderStreamingTests: XCTestCase {

    // MARK: - 8-bit Streaming Tests

    func testGetPixels8WithValidRange() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10

        // Create 100 pixels with sequential values
        let pixels = Array(UInt8(0)..<UInt8(100))
        mock.setPixels8(pixels)

        // Read middle 10 pixels (indices 40-50)
        let result = mock.getPixels8(range: 40..<50)

        XCTAssertNotNil(result, "Should return pixels for valid range")
        XCTAssertEqual(result?.count, 10, "Should return 10 pixels")
        XCTAssertEqual(result?.first, 40, "First pixel should be value 40")
        XCTAssertEqual(result?.last, 49, "Last pixel should be value 49")
    }

    func testGetPixels8WithEmptyRange() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10

        let pixels = Array(UInt8(0)..<UInt8(100))
        mock.setPixels8(pixels)

        // Test empty range
        let result = mock.getPixels8(range: 50..<50)

        XCTAssertNil(result, "Empty range should return nil")
    }

    func testGetPixels8WithSinglePixel() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10

        let pixels = Array(UInt8(0)..<UInt8(100))
        mock.setPixels8(pixels)

        // Read single pixel at index 42
        let result = mock.getPixels8(range: 42..<43)

        XCTAssertNotNil(result, "Should return single pixel")
        XCTAssertEqual(result?.count, 1, "Should return exactly 1 pixel")
        XCTAssertEqual(result?.first, 42, "Pixel value should be 42")
    }

    func testGetPixels8WithFullRange() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10

        let pixels = Array(UInt8(0)..<UInt8(100))
        mock.setPixels8(pixels)

        // Read entire image
        let result = mock.getPixels8(range: 0..<100)

        XCTAssertNotNil(result, "Should return all pixels")
        XCTAssertEqual(result?.count, 100, "Should return all 100 pixels")
        XCTAssertEqual(result, pixels, "Full range should match original pixels")
    }

    func testGetPixels8WithRangeAtStart() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10

        let pixels = Array(UInt8(0)..<UInt8(100))
        mock.setPixels8(pixels)

        // Read first 5 pixels
        let result = mock.getPixels8(range: 0..<5)

        XCTAssertNotNil(result, "Should return pixels at start")
        XCTAssertEqual(result?.count, 5, "Should return 5 pixels")
        XCTAssertEqual(result, [0, 1, 2, 3, 4], "Should match first 5 values")
    }

    func testGetPixels8WithRangeAtEnd() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10

        let pixels = Array(UInt8(0)..<UInt8(100))
        mock.setPixels8(pixels)

        // Read last 5 pixels
        let result = mock.getPixels8(range: 95..<100)

        XCTAssertNotNil(result, "Should return pixels at end")
        XCTAssertEqual(result?.count, 5, "Should return 5 pixels")
        XCTAssertEqual(result, [95, 96, 97, 98, 99], "Should match last 5 values")
    }

    func testGetPixels8WithUninitializedDecoder() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10
        // Don't set pixels

        let result = mock.getPixels8(range: 0..<10)

        XCTAssertNil(result, "Should return nil for uninitialized decoder")
    }

    // MARK: - 16-bit Streaming Tests

    func testGetPixels16WithValidRange() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10
        mock.bitDepth = 16

        // Create 100 pixels with sequential values
        let pixels = Array(UInt16(0)..<UInt16(100))
        mock.setPixels16(pixels)

        // Read middle 10 pixels (indices 40-50)
        let result = mock.getPixels16(range: 40..<50)

        XCTAssertNotNil(result, "Should return pixels for valid range")
        XCTAssertEqual(result?.count, 10, "Should return 10 pixels")
        XCTAssertEqual(result?.first, 40, "First pixel should be value 40")
        XCTAssertEqual(result?.last, 49, "Last pixel should be value 49")
    }

    func testGetPixels16WithEmptyRange() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10

        let pixels = Array(UInt16(0)..<UInt16(100))
        mock.setPixels16(pixels)

        // Test empty range
        let result = mock.getPixels16(range: 50..<50)

        XCTAssertNil(result, "Empty range should return nil")
    }

    func testGetPixels16WithSinglePixel() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10

        let pixels = Array(UInt16(0)..<UInt16(100))
        mock.setPixels16(pixels)

        // Read single pixel at index 42
        let result = mock.getPixels16(range: 42..<43)

        XCTAssertNotNil(result, "Should return single pixel")
        XCTAssertEqual(result?.count, 1, "Should return exactly 1 pixel")
        XCTAssertEqual(result?.first, 42, "Pixel value should be 42")
    }

    func testGetPixels16WithFullRange() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10

        let pixels = Array(UInt16(0)..<UInt16(100))
        mock.setPixels16(pixels)

        // Read entire image
        let result = mock.getPixels16(range: 0..<100)

        XCTAssertNotNil(result, "Should return all pixels")
        XCTAssertEqual(result?.count, 100, "Should return all 100 pixels")
        XCTAssertEqual(result, pixels, "Full range should match original pixels")
    }

    func testGetPixels16WithRangeAtStart() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10

        let pixels = Array(UInt16(0)..<UInt16(100))
        mock.setPixels16(pixels)

        // Read first 5 pixels
        let result = mock.getPixels16(range: 0..<5)

        XCTAssertNotNil(result, "Should return pixels at start")
        XCTAssertEqual(result?.count, 5, "Should return 5 pixels")
        XCTAssertEqual(result, [0, 1, 2, 3, 4], "Should match first 5 values")
    }

    func testGetPixels16WithRangeAtEnd() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10

        let pixels = Array(UInt16(0)..<UInt16(100))
        mock.setPixels16(pixels)

        // Read last 5 pixels
        let result = mock.getPixels16(range: 95..<100)

        XCTAssertNotNil(result, "Should return pixels at end")
        XCTAssertEqual(result?.count, 5, "Should return 5 pixels")
        XCTAssertEqual(result, [95, 96, 97, 98, 99], "Should match last 5 values")
    }

    func testGetPixels16WithUninitializedDecoder() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10
        // Don't set pixels

        let result = mock.getPixels16(range: 0..<10)

        XCTAssertNil(result, "Should return nil for uninitialized decoder")
    }

    func testGetPixels16WithLargeValues() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10

        // Test with large 16-bit values
        var pixels: [UInt16] = []
        for i in 0..<100 {
            pixels.append(UInt16(60000 + i))
        }
        mock.setPixels16(pixels)

        // Read a range
        let result = mock.getPixels16(range: 10..<20)

        XCTAssertNotNil(result, "Should handle large values")
        XCTAssertEqual(result?.count, 10, "Should return 10 pixels")
        XCTAssertEqual(result?.first, 60010, "First pixel should be 60010")
        XCTAssertEqual(result?.last, 60019, "Last pixel should be 60019")
    }

    // MARK: - 24-bit RGB Streaming Tests

    func testGetPixels24WithValidRange() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10
        mock.samplesPerPixel = 3

        // Create 100 RGB pixels (300 bytes total)
        var pixels: [UInt8] = []
        for i in 0..<100 {
            pixels.append(UInt8(i % 256))  // R
            pixels.append(UInt8((i + 1) % 256))  // G
            pixels.append(UInt8((i + 2) % 256))  // B
        }
        mock.setPixels24(pixels)

        // Read pixels 10-20 (should return 30 bytes: 10 pixels * 3 bytes)
        let result = mock.getPixels24(range: 10..<20)

        XCTAssertNotNil(result, "Should return pixels for valid range")
        XCTAssertEqual(result?.count, 30, "Should return 30 bytes (10 pixels * 3)")

        // Verify first pixel RGB values
        XCTAssertEqual(result?[0], 10, "First R value should be 10")
        XCTAssertEqual(result?[1], 11, "First G value should be 11")
        XCTAssertEqual(result?[2], 12, "First B value should be 12")
    }

    func testGetPixels24WithEmptyRange() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10
        mock.samplesPerPixel = 3

        var pixels: [UInt8] = []
        for i in 0..<100 {
            pixels.append(UInt8(i % 256))
            pixels.append(UInt8((i + 1) % 256))
            pixels.append(UInt8((i + 2) % 256))
        }
        mock.setPixels24(pixels)

        // Test empty range
        let result = mock.getPixels24(range: 50..<50)

        XCTAssertNil(result, "Empty range should return nil")
    }

    func testGetPixels24WithSinglePixel() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10
        mock.samplesPerPixel = 3

        var pixels: [UInt8] = []
        for i in 0..<100 {
            pixels.append(UInt8(i % 256))
            pixels.append(UInt8((i + 1) % 256))
            pixels.append(UInt8((i + 2) % 256))
        }
        mock.setPixels24(pixels)

        // Read single pixel at index 42 (should return 3 bytes)
        let result = mock.getPixels24(range: 42..<43)

        XCTAssertNotNil(result, "Should return single pixel")
        XCTAssertEqual(result?.count, 3, "Should return 3 bytes (1 pixel)")
        XCTAssertEqual(result?[0], 42, "R value should be 42")
        XCTAssertEqual(result?[1], 43, "G value should be 43")
        XCTAssertEqual(result?[2], 44, "B value should be 44")
    }

    func testGetPixels24WithFullRange() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10
        mock.samplesPerPixel = 3

        var pixels: [UInt8] = []
        for i in 0..<100 {
            pixels.append(UInt8(i % 256))
            pixels.append(UInt8((i + 1) % 256))
            pixels.append(UInt8((i + 2) % 256))
        }
        mock.setPixels24(pixels)

        // Read entire image (100 pixels = 300 bytes)
        let result = mock.getPixels24(range: 0..<100)

        XCTAssertNotNil(result, "Should return all pixels")
        XCTAssertEqual(result?.count, 300, "Should return 300 bytes (100 pixels * 3)")
        XCTAssertEqual(result, pixels, "Full range should match original pixels")
    }

    func testGetPixels24WithRangeAtStart() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10
        mock.samplesPerPixel = 3

        var pixels: [UInt8] = []
        for i in 0..<100 {
            pixels.append(UInt8(i % 256))
            pixels.append(UInt8((i + 1) % 256))
            pixels.append(UInt8((i + 2) % 256))
        }
        mock.setPixels24(pixels)

        // Read first 5 pixels (15 bytes)
        let result = mock.getPixels24(range: 0..<5)

        XCTAssertNotNil(result, "Should return pixels at start")
        XCTAssertEqual(result?.count, 15, "Should return 15 bytes (5 pixels * 3)")

        // Verify first pixel
        XCTAssertEqual(result?[0], 0, "First R should be 0")
        XCTAssertEqual(result?[1], 1, "First G should be 1")
        XCTAssertEqual(result?[2], 2, "First B should be 2")
    }

    func testGetPixels24WithRangeAtEnd() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10
        mock.samplesPerPixel = 3

        var pixels: [UInt8] = []
        for i in 0..<100 {
            pixels.append(UInt8(i % 256))
            pixels.append(UInt8((i + 1) % 256))
            pixels.append(UInt8((i + 2) % 256))
        }
        mock.setPixels24(pixels)

        // Read last 5 pixels (15 bytes)
        let result = mock.getPixels24(range: 95..<100)

        XCTAssertNotNil(result, "Should return pixels at end")
        XCTAssertEqual(result?.count, 15, "Should return 15 bytes (5 pixels * 3)")

        // Verify last pixel (pixel 99 at bytes 12-14)
        XCTAssertEqual(result?[12], 99, "Last pixel R should be 99")
        XCTAssertEqual(result?[13], 100, "Last pixel G should be 100")
        XCTAssertEqual(result?[14], 101, "Last pixel B should be 101")
    }

    func testGetPixels24WithUninitializedDecoder() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10
        mock.samplesPerPixel = 3
        // Don't set pixels

        let result = mock.getPixels24(range: 0..<10)

        XCTAssertNil(result, "Should return nil for uninitialized decoder")
    }

    // MARK: - Range Boundary Tests

    func testRangeBoundaryValidation() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10

        let pixels16 = Array(UInt16(0)..<UInt16(100))
        mock.setPixels16(pixels16)

        // Test exact boundaries
        let result1 = mock.getPixels16(range: 0..<100)
        XCTAssertNotNil(result1, "Should accept range at exact boundaries")
        XCTAssertEqual(result1?.count, 100, "Should return all pixels")

        // Test within boundaries
        let result2 = mock.getPixels16(range: 1..<99)
        XCTAssertNotNil(result2, "Should accept range within boundaries")
        XCTAssertEqual(result2?.count, 98, "Should return 98 pixels")
    }

    func testMultipleRangeAccesses() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10

        let pixels16 = Array(UInt16(0)..<UInt16(100))
        mock.setPixels16(pixels16)

        // Access multiple different ranges
        let range1 = mock.getPixels16(range: 0..<10)
        let range2 = mock.getPixels16(range: 10..<20)
        let range3 = mock.getPixels16(range: 20..<30)

        XCTAssertNotNil(range1, "First range should succeed")
        XCTAssertNotNil(range2, "Second range should succeed")
        XCTAssertNotNil(range3, "Third range should succeed")

        XCTAssertEqual(range1?.count, 10, "First range should have 10 pixels")
        XCTAssertEqual(range2?.count, 10, "Second range should have 10 pixels")
        XCTAssertEqual(range3?.count, 10, "Third range should have 10 pixels")

        // Verify values don't overlap
        XCTAssertEqual(range1?.first, 0, "First range starts at 0")
        XCTAssertEqual(range2?.first, 10, "Second range starts at 10")
        XCTAssertEqual(range3?.first, 20, "Third range starts at 20")
    }

    func testConsecutiveRangesCoverFullImage() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10

        let pixels8 = Array(UInt8(0)..<UInt8(100))
        mock.setPixels8(pixels8)

        // Read image in 10-pixel chunks
        var reconstructed: [UInt8] = []
        for i in stride(from: 0, to: 100, by: 10) {
            if let chunk = mock.getPixels8(range: i..<(i+10)) {
                reconstructed.append(contentsOf: chunk)
            }
        }

        XCTAssertEqual(reconstructed.count, 100, "Should reconstruct all pixels")
        XCTAssertEqual(reconstructed, pixels8, "Reconstructed should match original")
    }

    // MARK: - Edge Cases

    func testRangeWithLargeImage() {
        let mock = MockDicomDecoder()
        mock.width = 512
        mock.height = 512

        // Create large pixel array
        let totalPixels = 512 * 512
        var pixels: [UInt16] = []
        for i in 0..<totalPixels {
            pixels.append(UInt16(i % 65536))
        }
        mock.setPixels16(pixels)

        // Read a small range from large image
        let result = mock.getPixels16(range: 100000..<100100)

        XCTAssertNotNil(result, "Should handle large image")
        XCTAssertEqual(result?.count, 100, "Should return 100 pixels")
        XCTAssertEqual(result?.first, UInt16(100000 % 65536), "Should have correct first value")
    }

    func testOverlappingRanges() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10

        let pixels16 = Array(UInt16(0)..<UInt16(100))
        mock.setPixels16(pixels16)

        // Read overlapping ranges
        let range1 = mock.getPixels16(range: 10..<30)
        let range2 = mock.getPixels16(range: 20..<40)

        XCTAssertNotNil(range1, "First overlapping range should succeed")
        XCTAssertNotNil(range2, "Second overlapping range should succeed")

        // The overlapping portion (20-30) should have same values
        let overlap1 = Array(range1![10..<20])
        let overlap2 = Array(range2![0..<10])
        XCTAssertEqual(overlap1, overlap2, "Overlapping portions should be identical")
    }

    func testRangeConsistencyAcrossTypes() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10

        // For 8-bit and 16-bit, same range should return same number of pixels
        let pixels8 = Array(UInt8(0)..<UInt8(100))
        mock.setPixels8(pixels8)

        let pixels16 = Array(UInt16(0)..<UInt16(100))
        mock.setPixels16(pixels16)

        let result8 = mock.getPixels8(range: 10..<20)
        let result16 = mock.getPixels16(range: 10..<20)

        XCTAssertEqual(result8?.count, 10, "8-bit should return 10 pixels")
        XCTAssertEqual(result16?.count, 10, "16-bit should return 10 pixels")

        // For 24-bit, same range should return 3x bytes
        var pixels24: [UInt8] = []
        for i in 0..<100 {
            pixels24.append(UInt8(i % 256))
            pixels24.append(UInt8(i % 256))
            pixels24.append(UInt8(i % 256))
        }
        mock.setPixels24(pixels24)

        let result24 = mock.getPixels24(range: 10..<20)
        XCTAssertEqual(result24?.count, 30, "24-bit should return 30 bytes (10 pixels * 3)")
    }

    // MARK: - Integration with Full Buffer Access

    func testRangeMatchesFullBufferSubset() {
        let mock = MockDicomDecoder()
        mock.width = 10
        mock.height = 10

        let pixels16 = Array(UInt16(0)..<UInt16(100))
        mock.setPixels16(pixels16)

        // Get full buffer
        let fullBuffer = mock.getPixels16()

        // Get range
        let range = mock.getPixels16(range: 25..<75)

        XCTAssertNotNil(fullBuffer, "Full buffer should exist")
        XCTAssertNotNil(range, "Range should exist")

        // Range should match corresponding portion of full buffer
        let expectedSubset = Array(fullBuffer![25..<75])
        XCTAssertEqual(range, expectedSubset, "Range should match full buffer subset")
    }

    // MARK: - Memory Usage Tests

    /// Measures memory usage of streaming access vs full buffer loading.
    /// Note: This test uses MockDicomDecoder which holds full pixel data in memory.
    /// It validates that range-based access returns smaller allocations, but doesn't
    /// demonstrate memory-mapped streaming benefits (which require actual DICOM files).
    func testMemoryUsageStreamingVsFullBuffer() {
        let width = 4096
        let height = 4096
        let totalPixels = width * height

        let mock = MockDicomDecoder()
        mock.width = width
        mock.height = height

        // Create large 16-bit pixel array (4096x4096 = 16,777,216 pixels = ~33MB)
        var pixels: [UInt16] = []
        pixels.reserveCapacity(totalPixels)
        for i in 0..<totalPixels {
            pixels.append(UInt16(i % 65536))
        }
        mock.setPixels16(pixels)

        // Measure memory for full buffer access
        let memoryBeforeFull = getCurrentMemoryUsage()
        let fullBuffer = mock.getPixels16()
        let memoryAfterFull = getCurrentMemoryUsage()
        let fullBufferMemory = memoryAfterFull - memoryBeforeFull

        XCTAssertNotNil(fullBuffer, "Full buffer should be loaded")
        XCTAssertEqual(fullBuffer?.count, totalPixels, "Full buffer should contain all pixels")

        // Clear full buffer to measure streaming independently
        _ = fullBuffer // Keep reference to prevent early deallocation during test

        // Measure memory for streaming access (read 1% of image)
        let rangeSize = totalPixels / 100
        let memoryBeforeStream = getCurrentMemoryUsage()
        let streamedData = mock.getPixels16(range: 0..<rangeSize)
        let memoryAfterStream = getCurrentMemoryUsage()
        let streamingMemory = memoryAfterStream - memoryBeforeStream

        XCTAssertNotNil(streamedData, "Streamed data should be loaded")
        XCTAssertEqual(streamedData?.count, rangeSize, "Should return requested range size")

        let fullBufferMB = Double(fullBufferMemory) / (1024 * 1024)
        let streamingMB = Double(streamingMemory) / (1024 * 1024)
        let ratio = fullBufferMB / max(streamingMB, 0.01)

        print("""

        ========== Memory Usage: Streaming vs Full Buffer ==========
        Image size: \(width)x\(height) (\(totalPixels) pixels, 16-bit)
        Theoretical size: ~\(totalPixels * 2 / (1024 * 1024))MB

        Full buffer memory: \(String(format: "%.2f", fullBufferMB))MB
        Streaming memory (1% range): \(String(format: "%.2f", streamingMB))MB
        Memory reduction ratio: \(String(format: "%.1f", ratio))x
        =============================================================

        """)

        // Streaming should use significantly less memory than full buffer
        // Note: Some overhead is expected for small allocations
        if streamingMB > 1.0 {
            XCTAssertLessThan(streamingMB, fullBufferMB * 0.5,
                              "Streaming should use <50% of full buffer memory for small ranges")
        }
    }

    /// Verifies memory usage stays under 200MB threshold for large file access.
    /// This ensures streaming access is practical for memory-constrained environments.
    func testMemoryUsageLargeFileStreaming() {
        let width = 8192
        let height = 8192
        let totalPixels = width * height

        let mock = MockDicomDecoder()
        mock.width = width
        mock.height = height

        // Create very large 16-bit pixel array (8192x8192 = 67,108,864 pixels = ~134MB)
        var pixels: [UInt16] = []
        pixels.reserveCapacity(totalPixels)
        for i in 0..<totalPixels {
            pixels.append(UInt16(i % 65536))
        }
        mock.setPixels16(pixels)

        let memoryBefore = getCurrentMemoryUsage()

        // Access image in 1024-row chunks (streaming pattern)
        let rowsPerChunk = 1024
        let pixelsPerChunk = width * rowsPerChunk
        var maxMemoryUsed: Int64 = 0

        for startRow in stride(from: 0, to: height, by: rowsPerChunk) {
            let startPixel = startRow * width
            let endPixel = min(startPixel + pixelsPerChunk, totalPixels)

            let chunkData = mock.getPixels16(range: startPixel..<endPixel)
            XCTAssertNotNil(chunkData, "Chunk should be loaded")

            let currentMemory = getCurrentMemoryUsage() - memoryBefore
            maxMemoryUsed = max(maxMemoryUsed, currentMemory)
        }

        let maxMemoryMB = Double(maxMemoryUsed) / (1024 * 1024)

        print("""

        ========== Memory Usage: Large File Streaming ==========
        Image size: \(width)x\(height) (\(totalPixels) pixels, 16-bit)
        Theoretical size: ~\(totalPixels * 2 / (1024 * 1024))MB
        Chunk size: \(rowsPerChunk) rows (\(pixelsPerChunk) pixels)

        Max memory used during streaming: \(String(format: "%.2f", maxMemoryMB))MB
        =========================================================

        """)

        // Memory usage should stay under 200MB threshold even for very large files
        XCTAssertLessThan(maxMemoryMB, 200.0,
                          "Memory usage should stay under 200MB for streaming access")
    }

    /// Verifies that multiple small range accesses don't accumulate memory.
    /// Each range access should release memory before the next access.
    func testMemoryUsageMultipleSmallRanges() {
        let width = 2048
        let height = 2048
        let totalPixels = width * height

        let mock = MockDicomDecoder()
        mock.width = width
        mock.height = height

        // Create large pixel array (2048x2048 = 4,194,304 pixels = ~8MB)
        var pixels: [UInt16] = []
        pixels.reserveCapacity(totalPixels)
        for i in 0..<totalPixels {
            pixels.append(UInt16(i % 65536))
        }
        mock.setPixels16(pixels)

        let memoryBefore = getCurrentMemoryUsage()
        let iterations = 100
        let rangeSize = 1000
        var memoryReadings: [Double] = []

        // Access many small ranges
        for i in 0..<iterations {
            let start = (i * rangeSize) % (totalPixels - rangeSize)
            let end = start + rangeSize

            let rangeData = mock.getPixels16(range: start..<end)
            XCTAssertNotNil(rangeData, "Range \(i) should be loaded")
            XCTAssertEqual(rangeData?.count, rangeSize, "Should return correct range size")

            // Measure memory periodically
            if i % 10 == 0 {
                let currentMemory = getCurrentMemoryUsage() - memoryBefore
                memoryReadings.append(Double(currentMemory) / (1024 * 1024))
            }
        }

        // Calculate memory growth
        let firstReading = memoryReadings.first ?? 0
        let lastReading = memoryReadings.last ?? 0
        let memoryGrowth = lastReading - firstReading

        print("""

        ========== Memory Usage: Multiple Small Ranges ==========
        Image size: \(width)x\(height) (\(totalPixels) pixels)
        Iterations: \(iterations)
        Range size: \(rangeSize) pixels

        Initial memory: \(String(format: "%.2f", firstReading))MB
        Final memory: \(String(format: "%.2f", lastReading))MB
        Memory growth: \(String(format: "%.2f", memoryGrowth))MB
        ==========================================================

        """)

        // Memory shouldn't grow significantly with multiple accesses
        // Some growth is acceptable, but should be < 50MB for 100 iterations
        XCTAssertLessThan(memoryGrowth, 50.0,
                          "Memory growth should be minimal across multiple range accesses")
    }

    // MARK: - Helper Methods

    /// Returns current memory usage in bytes.
    /// This is an approximate measurement for testing purposes.
    private func getCurrentMemoryUsage() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }

        if kerr == KERN_SUCCESS {
            return Int64(info.resident_size)
        } else {
            return 0
        }
    }
}
