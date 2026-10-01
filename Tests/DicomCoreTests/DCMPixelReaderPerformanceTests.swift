import XCTest
@testable import DicomCore
import Accelerate

/// Performance tests for vectorized pixel reading operations in DCMPixelReader.
/// Benchmarks the vDSP optimizations added for:
/// - Big endian byte swapping
/// - Signed pixel normalization
/// - MONOCHROME1 inversion
///
/// Acceptance criteria: 3-8x speedup for big endian and signed paths compared to scalar loops.
final class DCMPixelReaderPerformanceTests: XCTestCase {

    // MARK: - Test Configuration

    /// Standard medical imaging size for benchmarking
    private let standardWidth = 512
    private let standardHeight = 512

    /// Large medical imaging size (e.g., digital radiography)
    private let largeWidth = 2048
    private let largeHeight = 2048

    // MARK: - Big Endian Conversion Benchmarks

    /// Benchmarks vectorized big endian byte swapping for 16-bit pixels.
    /// Tests the optimized byteSwapped approach which uses hardware instructions.
    func testBigEndianConversionPerformance() {
        let width = largeWidth
        let height = largeHeight
        let numPixels = width * height
        let numBytes = numPixels * 2

        // Clear and reset pool statistics for clean baseline
        BufferPool.shared.clear()
        BufferPool.shared.resetStatistics()

        // Create synthetic big endian pixel data
        var testData = Data(count: numBytes + 100) // Extra offset bytes
        testData.withUnsafeMutableBytes { bytes in
            let uint16Ptr = bytes.baseAddress!.advanced(by: 100).assumingMemoryBound(to: UInt16.self)
            for i in 0..<numPixels {
                // Write big endian values (simulating CT/MR data)
                let value = UInt16(i % 4096) // Typical 12-bit CT range
                uint16Ptr[i] = value.bigEndian
            }
        }

        let iterations = 10
        var totalTime: CFAbsoluteTime = 0

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()

            // Benchmark the readPixels method with big endian data
            let result = DCMPixelReader.readPixels(
                data: testData,
                width: width,
                height: height,
                bitDepth: 16,
                samplesPerPixel: 1,
                offset: 100,
                pixelRepresentation: 0,
                littleEndian: false, // Big endian
                photometricInterpretation: "MONOCHROME2"
            )

            totalTime += CFAbsoluteTimeGetCurrent() - start

            XCTAssertNotNil(result.pixels16, "Should successfully read big endian pixels")
            XCTAssertEqual(result.pixels16?.count, numPixels, "Should read all pixels")
        }

        let avgTime = (totalTime / Double(iterations)) * 1000
        let pixelsPerSecond = Double(numPixels) / (totalTime / Double(iterations))

        // Capture pool statistics
        let stats = BufferPool.shared.statistics

        print("""

        ========== Big Endian Conversion Performance ==========
        Image size: \(width)x\(height) (\(numPixels / 1_000_000)M pixels)
        Iterations: \(iterations)
        Avg time: \(String(format: "%.2f", avgTime))ms
        Throughput: \(String(format: "%.2f", pixelsPerSecond / 1_000_000))M pixels/sec

        Buffer Pool Metrics:
          Total acquires: \(stats.totalAcquires)
          Pool hits: \(stats.hits)
          Pool misses: \(stats.misses)
          Hit rate: \(String(format: "%.1f", stats.hitRate))%
          Peak pool size: \(stats.peakPoolSize)
          Allocation reduction: \(String(format: "%.1f", (Double(stats.hits) / Double(iterations)) * 100.0))%
        ========================================================

        """)

        // Performance target: Big endian requires byte swapping for every pixel
        // 4M pixels in <1200ms = 3.5M+ pixels/sec (still much faster than scalar loops)
        XCTAssertLessThan(avgTime, 1200.0, "Big endian conversion should be <1200ms for 2048x2048 image")

        XCTAssertEqual(stats.totalAcquires, 0, "Native 16-bit reads should not acquire pooled buffers")
    }

    // MARK: - Signed Pixel Normalization Benchmarks

    /// Benchmarks vectorized signed pixel normalization using vDSP operations.
    /// Tests the normaliseSigned16Vectorized function which converts signed Int16
    /// to unsigned UInt16 representation using SIMD operations.
    func testSignedPixelNormalizationPerformance() {
        let width = largeWidth
        let height = largeHeight
        let numPixels = width * height
        let numBytes = numPixels * 2

        // Clear and reset pool statistics for clean baseline
        BufferPool.shared.clear()
        BufferPool.shared.resetStatistics()

        // Create synthetic signed pixel data (little endian)
        var testData = Data(count: numBytes + 100)
        testData.withUnsafeMutableBytes { bytes in
            let int16Ptr = bytes.baseAddress!.advanced(by: 100).assumingMemoryBound(to: Int16.self)
            for i in 0..<numPixels {
                // Simulate signed pixel data with values in range [-1024, +3071]
                // Typical for CT images with signed representation
                let signedValue = Int16((i % 4096) - 1024)
                int16Ptr[i] = signedValue
            }
        }

        let iterations = 10
        var totalTime: CFAbsoluteTime = 0

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()

            // Benchmark the readPixels method with signed pixel representation
            let result = DCMPixelReader.readPixels(
                data: testData,
                width: width,
                height: height,
                bitDepth: 16,
                samplesPerPixel: 1,
                offset: 100,
                pixelRepresentation: 1, // Signed
                littleEndian: true,
                photometricInterpretation: "MONOCHROME2"
            )

            totalTime += CFAbsoluteTimeGetCurrent() - start

            XCTAssertNotNil(result.pixels16, "Should successfully read signed pixels")
            XCTAssertEqual(result.pixels16?.count, numPixels, "Should read all pixels")
            XCTAssertTrue(result.signedImage, "Should mark as signed image")
        }

        let avgTime = (totalTime / Double(iterations)) * 1000
        let pixelsPerSecond = Double(numPixels) / (totalTime / Double(iterations))

        // Capture pool statistics
        let stats = BufferPool.shared.statistics

        print("""

        ========== Signed Pixel Normalization Performance ==========
        Image size: \(width)x\(height) (\(numPixels / 1_000_000)M pixels)
        Iterations: \(iterations)
        Avg time: \(String(format: "%.2f", avgTime))ms
        Throughput: \(String(format: "%.2f", pixelsPerSecond / 1_000_000))M pixels/sec

        Buffer Pool Metrics:
          Total acquires: \(stats.totalAcquires)
          Pool hits: \(stats.hits)
          Pool misses: \(stats.misses)
          Hit rate: \(String(format: "%.1f", stats.hitRate))%
          Peak pool size: \(stats.peakPoolSize)
          Allocation reduction: \(String(format: "%.1f", (Double(stats.hits) / Double(iterations)) * 100.0))%
        ================================================================

        """)

        #if DEBUG
        let expectedThreshold = 800.0
        #else
        let expectedThreshold = 100.0
        #endif
        XCTAssertLessThan(avgTime, expectedThreshold, "Signed normalization should be <\(expectedThreshold)ms for 2048x2048 image")

        XCTAssertEqual(stats.totalAcquires, 0, "Signed 16-bit normalization should not acquire pooled buffers")
    }

    // MARK: - MONOCHROME1 Inversion Benchmarks

    /// Benchmarks vectorized MONOCHROME1 inversion using vDSP operations.
    /// Tests the invertMonochrome1Vectorized function which performs
    /// pixel inversion (65535 - value) using SIMD operations.
    func testMonochrome1InversionPerformance() {
        let width = largeWidth
        let height = largeHeight
        let numPixels = width * height
        let numBytes = numPixels * 2

        // Clear and reset pool statistics for clean baseline
        BufferPool.shared.clear()
        BufferPool.shared.resetStatistics()

        // Create synthetic unsigned pixel data for MONOCHROME1
        var testData = Data(count: numBytes + 100)
        testData.withUnsafeMutableBytes { bytes in
            let uint16Ptr = bytes.baseAddress!.advanced(by: 100).assumingMemoryBound(to: UInt16.self)
            for i in 0..<numPixels {
                // Simulate X-ray pixel data (typical MONOCHROME1 use case)
                let value = UInt16(i % 65536)
                uint16Ptr[i] = value
            }
        }

        let iterations = 10
        var totalTime: CFAbsoluteTime = 0

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()

            // Benchmark the readPixels method with MONOCHROME1
            let result = DCMPixelReader.readPixels(
                data: testData,
                width: width,
                height: height,
                bitDepth: 16,
                samplesPerPixel: 1,
                offset: 100,
                pixelRepresentation: 0,
                littleEndian: true,
                photometricInterpretation: "MONOCHROME1" // Triggers inversion
            )

            totalTime += CFAbsoluteTimeGetCurrent() - start

            XCTAssertNotNil(result.pixels16, "Should successfully read MONOCHROME1 pixels")
            XCTAssertEqual(result.pixels16?.count, numPixels, "Should read all pixels")
        }

        let avgTime = (totalTime / Double(iterations)) * 1000
        let pixelsPerSecond = Double(numPixels) / (totalTime / Double(iterations))

        // Capture pool statistics
        let stats = BufferPool.shared.statistics

        print("""

        ========== MONOCHROME1 Inversion Performance ==========
        Image size: \(width)x\(height) (\(numPixels / 1_000_000)M pixels)
        Iterations: \(iterations)
        Avg time: \(String(format: "%.2f", avgTime))ms
        Throughput: \(String(format: "%.2f", pixelsPerSecond / 1_000_000))M pixels/sec

        Buffer Pool Metrics:
          Total acquires: \(stats.totalAcquires)
          Pool hits: \(stats.hits)
          Pool misses: \(stats.misses)
          Hit rate: \(String(format: "%.1f", stats.hitRate))%
          Peak pool size: \(stats.peakPoolSize)
          Allocation reduction: \(String(format: "%.1f", (Double(stats.hits) / Double(iterations)) * 100.0))%
        ========================================================

        """)

        #if DEBUG
        let expectedThreshold = 800.0
        #else
        let expectedThreshold = 100.0
        #endif
        XCTAssertLessThan(avgTime, expectedThreshold, "MONOCHROME1 inversion should be <\(expectedThreshold)ms for 2048x2048 image")

        XCTAssertGreaterThan(stats.hitRate, 50.0, "MONOCHROME1 inversion should reuse its temporary buffer")
    }

    /// Benchmarks vectorized MONOCHROME1 inversion for signed pixels.
    /// Tests the invertMonochrome1SignedVectorized function.
    func testMonochrome1SignedInversionPerformance() {
        let width = largeWidth
        let height = largeHeight
        let numPixels = width * height
        let numBytes = numPixels * 2

        // Create synthetic signed pixel data for MONOCHROME1
        var testData = Data(count: numBytes + 100)
        testData.withUnsafeMutableBytes { bytes in
            let int16Ptr = bytes.baseAddress!.advanced(by: 100).assumingMemoryBound(to: Int16.self)
            for i in 0..<numPixels {
                // Simulate signed X-ray pixel data
                let signedValue = Int16((i % 4096) - 1024)
                int16Ptr[i] = signedValue
            }
        }

        let iterations = 10
        var totalTime: CFAbsoluteTime = 0

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()

            // Benchmark with both signed representation and MONOCHROME1
            let result = DCMPixelReader.readPixels(
                data: testData,
                width: width,
                height: height,
                bitDepth: 16,
                samplesPerPixel: 1,
                offset: 100,
                pixelRepresentation: 1, // Signed
                littleEndian: true,
                photometricInterpretation: "MONOCHROME1" // Triggers signed inversion
            )

            totalTime += CFAbsoluteTimeGetCurrent() - start

            XCTAssertNotNil(result.pixels16, "Should successfully read signed MONOCHROME1 pixels")
            XCTAssertEqual(result.pixels16?.count, numPixels, "Should read all pixels")
            XCTAssertTrue(result.signedImage, "Should mark as signed image")
        }

        let avgTime = (totalTime / Double(iterations)) * 1000
        let pixelsPerSecond = Double(numPixels) / (totalTime / Double(iterations))

        print("""

        ========== MONOCHROME1 Signed Inversion Performance ==========
        Image size: \(width)x\(height) (\(numPixels / 1_000_000)M pixels)
        Iterations: \(iterations)
        Avg time: \(String(format: "%.2f", avgTime))ms
        Throughput: \(String(format: "%.2f", pixelsPerSecond / 1_000_000))M pixels/sec
        ===============================================================

        """)

        #if DEBUG
        let expectedThreshold = 800.0
        #else
        let expectedThreshold = 100.0
        #endif
        XCTAssertLessThan(avgTime, expectedThreshold, "Signed MONOCHROME1 should be <\(expectedThreshold)ms for 2048x2048 image")
    }

    // MARK: - Standard Size Benchmarks

    /// Benchmarks pixel reading for standard medical imaging size (512x512).
    /// This is the most common size for CT and MR images.
    func testStandardSizePerformance() {
        let width = standardWidth
        let height = standardHeight
        let numPixels = width * height
        let numBytes = numPixels * 2

        // Create synthetic pixel data
        var testData = Data(count: numBytes + 100)
        testData.withUnsafeMutableBytes { bytes in
            let uint16Ptr = bytes.baseAddress!.advanced(by: 100).assumingMemoryBound(to: UInt16.self)
            for i in 0..<numPixels {
                uint16Ptr[i] = UInt16(i % 4096)
            }
        }

        let iterations = 100
        var totalTime: CFAbsoluteTime = 0

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()

            let result = DCMPixelReader.readPixels(
                data: testData,
                width: width,
                height: height,
                bitDepth: 16,
                samplesPerPixel: 1,
                offset: 100,
                pixelRepresentation: 0,
                littleEndian: true,
                photometricInterpretation: "MONOCHROME2"
            )

            totalTime += CFAbsoluteTimeGetCurrent() - start

            XCTAssertNotNil(result.pixels16)
        }

        let avgTime = (totalTime / Double(iterations)) * 1000
        let pixelsPerSecond = Double(numPixels) / (totalTime / Double(iterations))

        print("""

        ========== Standard Size (512x512) Performance ==========
        Image size: \(width)x\(height) (\(numPixels / 1000)K pixels)
        Iterations: \(iterations)
        Avg time: \(String(format: "%.2f", avgTime))ms
        Throughput: \(String(format: "%.2f", pixelsPerSecond / 1_000_000))M pixels/sec
        ==========================================================

        """)

        // Performance target: Standard images should be very fast (<10ms)
        XCTAssertLessThan(avgTime, 10.0, "Standard 512x512 should be <10ms")
    }

    // MARK: - Streaming Access Benchmarks

    /// Benchmarks range-based pixel reading for streaming access.
    /// Tests the readPixels16 method which reads only a subset of pixels.
    func testStreamingAccessPerformance() {
        let width = largeWidth
        let height = largeHeight
        let numPixels = width * height
        let numBytes = numPixels * 2

        // Create synthetic pixel data
        var testData = Data(count: numBytes + 100)
        testData.withUnsafeMutableBytes { bytes in
            let uint16Ptr = bytes.baseAddress!.advanced(by: 100).assumingMemoryBound(to: UInt16.self)
            for i in 0..<numPixels {
                uint16Ptr[i] = UInt16(i % 4096)
            }
        }

        // Test reading 1000 rows (typical viewport size)
        let rowsToRead = 1000
        let pixelsToRead = width * rowsToRead
        let range = 0..<pixelsToRead

        let iterations = 100
        var totalTime: CFAbsoluteTime = 0

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()

            let result = DCMPixelReader.readPixels16(
                data: testData,
                range: range,
                width: width,
                height: height,
                offset: 100,
                pixelRepresentation: 0,
                littleEndian: true,
                photometricInterpretation: "MONOCHROME2"
            )

            totalTime += CFAbsoluteTimeGetCurrent() - start

            guard let result else {
                XCTFail("Streaming read should return a result")
                return
            }
            XCTAssertEqual(result.pixels16?.count, pixelsToRead)
        }

        let avgTime = (totalTime / Double(iterations)) * 1000
        let pixelsPerSecond = Double(pixelsToRead) / (totalTime / Double(iterations))

        print("""

        ========== Streaming Access Performance ==========
        Image size: \(width)x\(height)
        Range: \(range.lowerBound)..<\(range.upperBound) (\(pixelsToRead / 1_000_000)M pixels)
        Iterations: \(iterations)
        Avg time: \(String(format: "%.2f", avgTime))ms
        Throughput: \(String(format: "%.2f", pixelsPerSecond / 1_000_000))M pixels/sec
        ==================================================

        """)

        // Performance target: Partial reads should be very fast
        XCTAssertLessThan(avgTime, 50.0, "Streaming read of 2M pixels should be <50ms")
    }

    // MARK: - Combined Operation Benchmarks

    /// Benchmarks the worst-case scenario: big endian + signed + MONOCHROME1.
    /// This tests multiple vectorized operations in sequence.
    func testCombinedOperationsPerformance() {
        let width = largeWidth
        let height = largeHeight
        let numPixels = width * height
        let numBytes = numPixels * 2

        // Clear and reset pool statistics for clean baseline
        BufferPool.shared.clear()
        BufferPool.shared.resetStatistics()

        // Create synthetic big endian signed pixel data
        var testData = Data(count: numBytes + 100)
        testData.withUnsafeMutableBytes { bytes in
            let int16Ptr = bytes.baseAddress!.advanced(by: 100).assumingMemoryBound(to: Int16.self)
            for i in 0..<numPixels {
                let signedValue = Int16((i % 4096) - 1024)
                int16Ptr[i] = signedValue.bigEndian
            }
        }

        let iterations = 10
        var totalTime: CFAbsoluteTime = 0

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()

            // Worst case: big endian + signed + MONOCHROME1
            let result = DCMPixelReader.readPixels(
                data: testData,
                width: width,
                height: height,
                bitDepth: 16,
                samplesPerPixel: 1,
                offset: 100,
                pixelRepresentation: 1, // Signed
                littleEndian: false, // Big endian
                photometricInterpretation: "MONOCHROME1" // Inversion
            )

            totalTime += CFAbsoluteTimeGetCurrent() - start

            XCTAssertNotNil(result.pixels16)
            XCTAssertEqual(result.pixels16?.count, numPixels)
            XCTAssertTrue(result.signedImage)
        }

        let avgTime = (totalTime / Double(iterations)) * 1000
        let pixelsPerSecond = Double(numPixels) / (totalTime / Double(iterations))

        // Capture pool statistics
        let stats = BufferPool.shared.statistics

        print("""

        ========== Combined Operations (Big Endian + Signed + MONOCHROME1) ==========
        Image size: \(width)x\(height) (\(numPixels / 1_000_000)M pixels)
        Iterations: \(iterations)
        Avg time: \(String(format: "%.2f", avgTime))ms
        Throughput: \(String(format: "%.2f", pixelsPerSecond / 1_000_000))M pixels/sec

        Buffer Pool Metrics:
          Total acquires: \(stats.totalAcquires)
          Pool hits: \(stats.hits)
          Pool misses: \(stats.misses)
          Hit rate: \(String(format: "%.1f", stats.hitRate))%
          Peak pool size: \(stats.peakPoolSize)
          Allocation reduction: \(String(format: "%.1f", (Double(stats.hits) / Double(iterations)) * 100.0))%
        ==============================================================================

        """)

        // Performance target: Worst case (big endian + signed + MONOCHROME1)
        // Still much faster than non-vectorized implementation
        XCTAssertLessThan(avgTime, 800.0, "Combined operations should be <800ms for 2048x2048 image")

        XCTAssertEqual(stats.totalAcquires, 0, "Combined signed 16-bit reads should not acquire pooled buffers")
    }

    // MARK: - Repeated Read Tests

    /// Verifies repeated large pixel reads keep returning complete buffers.
    func test_repeatedLargeReads_returnCompleteBuffers() {
        let width = largeWidth
        let height = largeHeight
        let numPixels = width * height
        let numBytes = numPixels * 2

        // Create test data
        var testData = Data(count: numBytes + 100)
        testData.withUnsafeMutableBytes { bytes in
            let uint16Ptr = bytes.baseAddress!.advanced(by: 100).assumingMemoryBound(to: UInt16.self)
            for i in 0..<numPixels {
                uint16Ptr[i] = UInt16(i % 4096)
            }
        }

        // Perform multiple allocations to cover repeated buffer creation and release.
        let iterations = 50
        for _ in 0..<iterations {
            let result = DCMPixelReader.readPixels(
                data: testData,
                width: width,
                height: height,
                bitDepth: 16,
                samplesPerPixel: 1,
                offset: 100,
                pixelRepresentation: 0,
                littleEndian: true,
                photometricInterpretation: "MONOCHROME2"
            )

            XCTAssertNotNil(result.pixels16)
            XCTAssertEqual(result.pixels16?.count, numPixels)
        }

        print("""

        ========== Repeated Large Reads ==========
        Completed \(iterations) iterations of \(numPixels / 1_000_000)M pixel allocations
        ============================================

        """)

    }
}
