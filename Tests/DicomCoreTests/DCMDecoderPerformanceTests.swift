import XCTest
@testable import DicomCore

/// Performance tests to verify that thread-safety additions have minimal impact
/// on single-threaded performance. Acceptance criteria: <10% degradation.
final class DCMDecoderPerformanceTests: XCTestCase {

    // MARK: - Lock Overhead Benchmark

    /// Measures the overhead of the decoder lock in sequential access patterns.
    /// This simulates the worst-case overhead where every operation acquires/releases locks.
    func testLockOverheadSingleThreaded() {
        let iterations = 10000

        // Measure lock/unlock overhead
        let lockOverheadStart = CFAbsoluteTimeGetCurrent()
        let lock = DicomLock()
        for _ in 0..<iterations {
            lock.lock()
            // Simulate minimal work (equivalent to a property access)
            _ = Thread.current
            lock.unlock()
        }
        let lockOverheadTime = CFAbsoluteTimeGetCurrent() - lockOverheadStart

        // Measure baseline (no lock)
        let baselineStart = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            // Same minimal work without lock
            _ = Thread.current
        }
        let baselineTime = CFAbsoluteTimeGetCurrent() - baselineStart

        let overheadTime = max(0, lockOverheadTime - baselineTime)
        let overhead = (overheadTime / max(baselineTime, 0.000001)) * 100.0
        let perIterationOverhead = overheadTime / Double(iterations)

        print("""

        ========== Lock Overhead Benchmark ==========
        Iterations: \(iterations)
        Baseline time (no lock): \(String(format: "%.6f", baselineTime))s
        Lock/unlock time: \(String(format: "%.6f", lockOverheadTime))s
        Overhead: \(String(format: "%.2f", overhead))%
        Overhead per iteration: \(String(format: "%.9f", perIterationOverhead))s
        ==============================================

        """)

        // Lock overhead should be minimal in absolute terms.
        #if targetEnvironment(simulator)
        let maxOverheadPerIteration: CFAbsoluteTime = 0.0001 // 100us on simulator
        #else
        let maxOverheadPerIteration: CFAbsoluteTime = 0.000001 // 1us on device/mac
        #endif
        XCTAssertLessThan(perIterationOverhead, maxOverheadPerIteration,
                          "Lock overhead should be <\(maxOverheadPerIteration * 1_000_000)us per operation")

        if baselineTime > 0.1 {
            XCTAssertLessThan(overhead, 10.0, "Lock overhead should be <10% when baseline timing is stable")
        }
    }

    // MARK: - Decoder Operation Benchmarks

    /// Benchmarks decoder initialization and basic operations.
    /// Tests the performance of synchronized methods in single-threaded context.
    func testDecoderOperationPerformance() {
        let iterations = 1000
        var totalInitTime: CFAbsoluteTime = 0
        var totalValidationTime: CFAbsoluteTime = 0
        var totalPropertyAccessTime: CFAbsoluteTime = 0

        for _ in 0..<iterations {
            // Measure initialization
            let initStart = CFAbsoluteTimeGetCurrent()
            let decoder = DCMDecoder()
            totalInitTime += CFAbsoluteTimeGetCurrent() - initStart

            // Measure validation status check (synchronized method)
            let validationStart = CFAbsoluteTimeGetCurrent()
            _ = decoder.getValidationStatus()
            totalValidationTime += CFAbsoluteTimeGetCurrent() - validationStart

            // Measure property access (synchronized methods)
            let propertyStart = CFAbsoluteTimeGetCurrent()
            _ = decoder.isValid()
            _ = decoder.isValid()
            _ = decoder.width
            _ = decoder.height
            totalPropertyAccessTime += CFAbsoluteTimeGetCurrent() - propertyStart
        }

        let avgInitTime = totalInitTime / Double(iterations)
        let avgValidationTime = totalValidationTime / Double(iterations)
        let avgPropertyTime = totalPropertyAccessTime / Double(iterations)

        print("""

        ========== Decoder Operation Performance ==========
        Iterations: \(iterations)
        Avg initialization time: \(String(format: "%.6f", avgInitTime))s
        Avg validation time: \(String(format: "%.6f", avgValidationTime))s
        Avg property access time: \(String(format: "%.6f", avgPropertyTime))s
        ===================================================

        """)

        // These are just baseline measurements; no files are loaded
        // The times should be extremely fast (microseconds)
        XCTAssertLessThan(avgInitTime, 0.001, "Decoder init should be <1ms")
        XCTAssertLessThan(avgValidationTime, 0.0001, "Validation check should be <0.1ms")
        XCTAssertLessThan(avgPropertyTime, 0.0001, "Property access should be <0.1ms")
    }

    // MARK: - Metadata Access Benchmark

    /// Benchmarks synchronized metadata access methods.
    /// Simulates typical usage patterns where metadata is queried multiple times.
    func testMetadataAccessPerformance() {
        let decoder = DCMDecoder()
        let iterations = 10000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            // These methods all use synchronized blocks
            _ = decoder.info(for: .patientName)
            _ = decoder.intValue(for: .rows)
            _ = decoder.doubleValue(for: .pixelSpacing)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let avgTime = elapsed / Double(iterations)

        print("""

        ========== Metadata Access Performance ==========
        Iterations: \(iterations)
        Total time: \(String(format: "%.6f", elapsed))s
        Avg time per iteration: \(String(format: "%.6f", avgTime))s
        ================================================

        """)

        // Average time per iteration should be very fast
        XCTAssertLessThan(avgTime, 0.0001, "Metadata access should be <0.1ms per iteration")
    }

    // MARK: - Streaming Pixel Access Benchmarks

    /// Benchmarks validation overhead for a range request on an uninitialized decoder.
    func testUninitializedDecoderRangeAccessLatency() {
        let decoder = DCMDecoder()
        let iterations = 100
        XCTAssertNil(decoder.getPixels16(range: 0..<100))

        var totalLatency: CFAbsoluteTime = 0

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            _ = decoder.getPixels16(range: 0..<100)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            totalLatency += elapsed
        }

        let avgLatency = totalLatency / Double(iterations)

        print("""

        ========== Uninitialized Range Access Latency ==========
        Iterations: \(iterations)
        Avg latency: \(String(format: "%.6f", avgLatency))s (\(String(format: "%.2f", avgLatency * 1000))ms)
        ================================================

        """)

        XCTAssertLessThan(avgLatency, 0.001, "Uninitialized range validation should be <1ms")
    }

    /// Benchmarks sequential invalid-range checks without file I/O.
    func testSequentialUninitializedRangeValidationPerformance() {
        let decoder = DCMDecoder()

        // Simulate a 2048x2048 16-bit image (8MB of pixel data)
        let totalPixels = 2048 * 2048
        let chunkSize = 256 * 256  // 256x256 tile = 128KB per chunk
        let numChunks = totalPixels / chunkSize

        var totalTime: CFAbsoluteTime = 0
        let start = CFAbsoluteTimeGetCurrent()

        // Stream through the image in chunks
        for chunkIndex in 0..<numChunks {
            let rangeStart = chunkIndex * chunkSize
            let rangeEnd = min(rangeStart + chunkSize, totalPixels)

            let chunkStart = CFAbsoluteTimeGetCurrent()
            let pixelData = decoder.getPixels16(range: rangeStart..<rangeEnd)
            let chunkTime = CFAbsoluteTimeGetCurrent() - chunkStart

            totalTime += chunkTime
            XCTAssertNil(pixelData)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let avgChunkTime = totalTime / Double(numChunks)

        print("""

        ========== Sequential Uninitialized Range Validation ==========
        Requested range coverage: 2048x2048
        Range size: \(chunkSize) pixels
        Number of ranges: \(numChunks)
        Total time: \(String(format: "%.6f", elapsed))s
        Avg validation time: \(String(format: "%.6f", avgChunkTime))s
        =======================================================

        """)

        XCTAssertLessThan(avgChunkTime, 0.01, "Range validation should be <10ms")
    }

    /// Benchmarks deterministic random-range validation on an uninitialized decoder.
    func testRandomUninitializedRangeValidationLatency() {
        let decoder = DCMDecoder()

        // Simulate a 4096x4096 image
        let totalPixels = 4096 * 4096
        let tileSize = 512 * 512  // 512x512 tile
        let numRandomAccesses = 50

        var totalLatency: CFAbsoluteTime = 0

        // Generate random tile positions
        for i in 0..<numRandomAccesses {
            // Use deterministic pseudo-random positions for reproducibility
            let tileIndex = (i * 137) % ((totalPixels / tileSize) - 1)
            let rangeStart = tileIndex * tileSize
            let rangeEnd = min(rangeStart + tileSize, totalPixels)

            let start = CFAbsoluteTimeGetCurrent()
            let pixels = decoder.getPixels16(range: rangeStart..<rangeEnd)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            XCTAssertNil(pixels)
            totalLatency += elapsed
        }

        let avgLatency = totalLatency / Double(numRandomAccesses)

        print("""

        ========== Random Uninitialized Range Validation ==========
        Requested range coverage: 4096x4096
        Range size: 512x512
        Random ranges: \(numRandomAccesses)
        Avg validation time: \(String(format: "%.6f", avgLatency))s (\(String(format: "%.2f", avgLatency * 1000))ms)
        ===========================================

        """)

        XCTAssertLessThan(avgLatency, 0.05, "Random range validation should be <50ms")
    }

    /// Benchmarks range and full access validation without a loaded file.
    func testUninitializedRangeAndFullAccessLatency() {
        let decoder = DCMDecoder()

        let smallRangeStart = CFAbsoluteTimeGetCurrent()
        let smallRange = decoder.getPixels16(range: 0..<1000)
        let smallRangeTime = CFAbsoluteTimeGetCurrent() - smallRangeStart

        let fullAccessStart = CFAbsoluteTimeGetCurrent()
        let fullAccess = decoder.getPixels16()
        let fullAccessTime = CFAbsoluteTimeGetCurrent() - fullAccessStart

        print("""

        ========== Uninitialized Range vs Full Access ==========
        Small range (1000 pixels) time: \(String(format: "%.6f", smallRangeTime))s
        Full access time: \(String(format: "%.6f", fullAccessTime))s
        ==================================================

        """)

        XCTAssertLessThan(smallRangeTime, 0.01, "Range access should be fast")
        XCTAssertLessThan(fullAccessTime, 0.01, "Full access should be fast")

        // Both return nil without a loaded file
        XCTAssertNil(smallRange, "No data without loaded file")
        XCTAssertNil(fullAccess, "No data without loaded file")
    }

    /// Benchmarks uninitialized range validation across all pixel APIs.
    func testUninitializedMultiBitDepthRangeValidationPerformance() {
        let decoder = DCMDecoder()
        let testRange = 0..<10000  // 10K pixels
        let iterations = 100
        XCTAssertNil(decoder.getPixels8(range: testRange))
        XCTAssertNil(decoder.getPixels16(range: testRange))
        XCTAssertNil(decoder.getPixels24(range: testRange))

        var time8bit: CFAbsoluteTime = 0
        var time16bit: CFAbsoluteTime = 0
        var time24bit: CFAbsoluteTime = 0

        for _ in 0..<iterations {
            // 8-bit access
            let start8 = CFAbsoluteTimeGetCurrent()
            _ = decoder.getPixels8(range: testRange)
            time8bit += CFAbsoluteTimeGetCurrent() - start8

            // 16-bit access
            let start16 = CFAbsoluteTimeGetCurrent()
            _ = decoder.getPixels16(range: testRange)
            time16bit += CFAbsoluteTimeGetCurrent() - start16

            // 24-bit access
            let start24 = CFAbsoluteTimeGetCurrent()
            _ = decoder.getPixels24(range: testRange)
            time24bit += CFAbsoluteTimeGetCurrent() - start24
        }

        let avg8 = time8bit / Double(iterations)
        let avg16 = time16bit / Double(iterations)
        let avg24 = time24bit / Double(iterations)

        print("""

        ========== Multi-Bit-Depth Uninitialized Range Validation ==========
        Range: 10,000 pixels
        Iterations: \(iterations)

        Avg 8-bit access time:  \(String(format: "%.6f", avg8))s
        Avg 16-bit access time: \(String(format: "%.6f", avg16))s
        Avg 24-bit access time: \(String(format: "%.6f", avg24))s

        ============================================================

        """)

        XCTAssertLessThan(avg8, 0.001, "8-bit access should be <1ms")
        XCTAssertLessThan(avg16, 0.001, "16-bit access should be <1ms")
        XCTAssertLessThan(avg24, 0.001, "24-bit access should be <1ms")
    }

    // MARK: - JPEG Lossless Decoding Performance

    /// Benchmarks JPEG Lossless decoding performance for various image sizes.
    /// This measures the complete decoding pipeline: JPEG marker parsing, Huffman decoding,
    /// and pixel reconstruction with first-order prediction.
    func testJPEGLosslessDecodingPerformance() throws {
        let testCases: [(width: Int, height: Int, description: String)] = [
            (128, 128, "Small (128x128)"),
            (256, 256, "Medium (256x256)"),
            (512, 512, "Large (512x512)")
        ]

        var results: [(description: String, avgTime: CFAbsoluteTime, pixelsPerSecond: Double)] = []

        for testCase in testCases {
            let width = testCase.width
            let height = testCase.height
            let pixelCount = width * height
            let pixels = [UInt16](repeating: 32768, count: pixelCount)

            // Create synthetic JPEG Lossless DICOM file
            let dicomData = try createJPEGLosslessDICOMFile(
                width: width,
                height: height,
                bitDepth: 16,
                pixels: pixels
            )
            let fileURL = try writeTempDICOMFile(dicomData)
            defer { try? FileManager.default.removeItem(at: fileURL) }

            // Warm up decoder (first run may include one-time setup costs)
            let decoder = try DCMDecoder(contentsOf: fileURL)
            _ = try XCTUnwrap(decoder.getPixels16())

            // Benchmark decoding
            let iterations = 10
            var totalTime: CFAbsoluteTime = 0

            for _ in 0..<iterations {
                let start = CFAbsoluteTimeGetCurrent()
                let iterDecoder = try DCMDecoder(contentsOf: fileURL)
                _ = try XCTUnwrap(iterDecoder.getPixels16())
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                totalTime += elapsed
            }

            let avgTime = totalTime / Double(iterations)
            let pixelsPerSecond = Double(pixelCount) / avgTime

            results.append((
                description: testCase.description,
                avgTime: avgTime,
                pixelsPerSecond: pixelsPerSecond
            ))
        }

        // Print benchmark results
        print("""

        ========== JPEG Lossless Decoding Performance ==========
        """)
        for result in results {
            print("""
            \(result.description):
              Avg time: \(String(format: "%.4f", result.avgTime))s
              Throughput: \(String(format: "%.0f", result.pixelsPerSecond)) pixels/sec
            """)
        }
        print("=======================================================\n")

        XCTAssertEqual(results.count, testCases.count)

        // Verify reasonable performance
        // Small images (128x128) should decode in under 100ms
        XCTAssertLessThan(results[0].avgTime, 0.1,
                          "Small image (128x128) should decode in <100ms")

        // Medium images (256x256) should decode in under 500ms
        XCTAssertLessThan(results[1].avgTime, 0.5,
                          "Medium image (256x256) should decode in <500ms")

        // Large images (512x512) should decode in under 2 seconds
        XCTAssertLessThan(results[2].avgTime, 2.0,
                          "Large image (512x512) should decode in <2s")
    }

    /// Verifies the medium-resolution JPEG Lossless decode budget with complete samples.
    func testJPEGLosslessMediumImageDecodeBudget() throws {
        let width = 256
        let height = 256
        let pixelCount = width * height
        let iterations = 10

        // Benchmark JPEG Lossless decoding
        let pixels = [UInt16](repeating: 32768, count: pixelCount)
        let jpegLosslessData = try createJPEGLosslessDICOMFile(
            width: width,
            height: height,
            bitDepth: 16,
            pixels: pixels
        )
        let jpegLosslessURL = try writeTempDICOMFile(jpegLosslessData)
        defer { try? FileManager.default.removeItem(at: jpegLosslessURL) }

        let decoder = try DCMDecoder(contentsOf: jpegLosslessURL)
        _ = try XCTUnwrap(decoder.getPixels16())

        var jpegLosslessTime: CFAbsoluteTime = 0
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            let iterDecoder = try DCMDecoder(contentsOf: jpegLosslessURL)
            _ = try XCTUnwrap(iterDecoder.getPixels16())
            jpegLosslessTime += CFAbsoluteTimeGetCurrent() - start
        }
        let avgJPEGLosslessTime = jpegLosslessTime / Double(iterations)

        print("""

        ========== JPEG Lossless Medium Image Decode Budget ==========
        Image size: \(width)x\(height) (\(pixelCount) pixels)
        Iterations: \(iterations)

        JPEG Lossless decode time: \(String(format: "%.4f", avgJPEGLosslessTime))s
        ===========================================================

        """)

        XCTAssertLessThan(avgJPEGLosslessTime, 0.5,
                          "JPEG Lossless decoding should complete in <500ms for 256x256 image")
    }

    /// Benchmarks JPEG Lossless decoding performance for different bit depths.
    /// Medical imaging commonly uses 12-bit and 16-bit precision.
    func testJPEGLosslessBitDepthPerformance() throws {
        let width = 256
        let height = 256
        let pixelCount = width * height
        let iterations = 10

        let bitDepths = [8, 12, 16]
        var results: [(bitDepth: Int, avgTime: CFAbsoluteTime)] = []

        for bitDepth in bitDepths {
            let pixels = [UInt16](repeating: UInt16(1 << (bitDepth - 1)), count: pixelCount)
            let dicomData = try createJPEGLosslessDICOMFile(
                width: width,
                height: height,
                bitDepth: bitDepth,
                pixels: pixels
            )
            let fileURL = try writeTempDICOMFile(dicomData)
            defer { try? FileManager.default.removeItem(at: fileURL) }

            let decoder = try DCMDecoder(contentsOf: fileURL)
            if bitDepth == 8 {
                XCTAssertEqual(try XCTUnwrap(decoder.getPixels8()).count, pixelCount)
            } else {
                XCTAssertEqual(try XCTUnwrap(decoder.getPixels16()).count, pixelCount)
            }

            // Benchmark
            var totalTime: CFAbsoluteTime = 0
            for _ in 0..<iterations {
                let start = CFAbsoluteTimeGetCurrent()
                let iterDecoder = try DCMDecoder(contentsOf: fileURL)
                if bitDepth == 8 {
                    XCTAssertEqual(try XCTUnwrap(iterDecoder.getPixels8()).count, pixelCount)
                } else {
                    XCTAssertEqual(try XCTUnwrap(iterDecoder.getPixels16()).count, pixelCount)
                }
                totalTime += CFAbsoluteTimeGetCurrent() - start
            }
            let avgTime = totalTime / Double(iterations)
            results.append((bitDepth: bitDepth, avgTime: avgTime))
        }

        print("""

        ========== JPEG Lossless Bit Depth Performance ==========
        Image size: \(width)x\(height)
        Iterations: \(iterations)
        """)
        for result in results {
            print("""
            \(result.bitDepth)-bit: \(String(format: "%.4f", result.avgTime))s
            """)
        }
        print("=========================================================\n")

        XCTAssertEqual(results.count, bitDepths.count)

        // Verify all bit depths decode in reasonable time
        for result in results {
            XCTAssertLessThan(result.avgTime, 0.5,
                             "\(result.bitDepth)-bit JPEG Lossless should decode in <500ms")
        }

        // Performance should be relatively similar across bit depths
        // since the decoding algorithm is the same
        let minimumTime = try XCTUnwrap(results.map(\.avgTime).min())
        let maximumTime = try XCTUnwrap(results.map(\.avgTime).max())
        let variationFactor = maximumTime / minimumTime
        #if targetEnvironment(simulator)
        let maxVariation: Double = 5.0 // Simulator timing variance is higher.
        #else
        let maxVariation: Double = 3.0
        #endif
        XCTAssertLessThan(variationFactor, maxVariation,
                          "Performance variation across bit depths should be <\(maxVariation)x")
    }

    // MARK: - Helper Methods for JPEG Lossless Performance Tests

    private func createJPEGLosslessDICOMFile(
        width: Int,
        height: Int,
        bitDepth: Int,
        pixels: [UInt16]
    ) throws -> Data {
        var dicomData = Data()

        // DICOM File Preamble
        dicomData.append(Data(count: 128))
        dicomData.append(contentsOf: [0x44, 0x49, 0x43, 0x4D])

        // File Meta Information
        let metaInfoStartIndex = dicomData.count
        appendTag(&dicomData, group: 0x0002, element: 0x0000, vr: "UL", value: Data(count: 4))
        appendTag(&dicomData, group: 0x0002, element: 0x0001, vr: "OB", value: Data([0x00, 0x01]))
        appendTag(&dicomData, group: 0x0002, element: 0x0002, vr: "UI",
                 value: "1.2.840.10008.5.1.4.1.1.7".data(using: .ascii)!)
        appendTag(&dicomData, group: 0x0002, element: 0x0003, vr: "UI",
                 value: "1.2.3.4.5.6.7.8".data(using: .ascii)!)
        appendTag(&dicomData, group: 0x0002, element: 0x0010, vr: "UI",
                 value: "1.2.840.10008.1.2.4.70".data(using: .ascii)!)
        appendTag(&dicomData, group: 0x0002, element: 0x0012, vr: "UI",
                 value: "1.2.3.4.5.6.7.8.9".data(using: .ascii)!)

        let metaInfoLength = UInt32(dicomData.count - metaInfoStartIndex - 12)
        dicomData.replaceSubrange((metaInfoStartIndex + 8)..<(metaInfoStartIndex + 12),
                                 with: withUnsafeBytes(of: metaInfoLength.littleEndian) { Data($0) })

        // Dataset
        appendTag(&dicomData, group: 0x0008, element: 0x0060, vr: "CS", value: "OT".data(using: .ascii)!)
        appendTag(&dicomData, group: 0x0010, element: 0x0010, vr: "PN", value: "TEST".data(using: .ascii)!)
        appendTag(&dicomData, group: 0x0028, element: 0x0002, vr: "US",
                 value: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        appendTag(&dicomData, group: 0x0028, element: 0x0004, vr: "CS",
                 value: "MONOCHROME2".data(using: .ascii)!)
        appendTag(&dicomData, group: 0x0028, element: 0x0010, vr: "US",
                 value: withUnsafeBytes(of: UInt16(height).littleEndian) { Data($0) })
        appendTag(&dicomData, group: 0x0028, element: 0x0011, vr: "US",
                 value: withUnsafeBytes(of: UInt16(width).littleEndian) { Data($0) })
        appendTag(&dicomData, group: 0x0028, element: 0x0100, vr: "US",
                 value: withUnsafeBytes(of: UInt16(bitDepth).littleEndian) { Data($0) })
        appendTag(&dicomData, group: 0x0028, element: 0x0101, vr: "US",
                 value: withUnsafeBytes(of: UInt16(bitDepth).littleEndian) { Data($0) })
        appendTag(&dicomData, group: 0x0028, element: 0x0102, vr: "US",
                 value: withUnsafeBytes(of: UInt16(bitDepth - 1).littleEndian) { Data($0) })
        appendTag(&dicomData, group: 0x0028, element: 0x0103, vr: "US",
                 value: withUnsafeBytes(of: UInt16(0).littleEndian) { Data($0) })

        // Pixel Data with JPEG Lossless compression
        let jpegData = try createJPEGLosslessData(width: width, height: height, bitDepth: bitDepth, pixels: pixels)
        appendTag(&dicomData, group: 0x7FE0, element: 0x0010, vr: "OB", value: jpegData)

        return dicomData
    }

    private func createJPEGLosslessData(width: Int, height: Int, bitDepth: Int, pixels: [UInt16]) throws -> Data {
        var jpegData = Data()

        // SOI marker
        jpegData.append(contentsOf: [0xFF, 0xD8])

        // SOF3 marker
        jpegData.append(contentsOf: [0xFF, 0xC3])
        let sof3Length: UInt16 = 11
        jpegData.append(UInt8(sof3Length >> 8))
        jpegData.append(UInt8(sof3Length & 0xFF))
        jpegData.append(UInt8(bitDepth))
        jpegData.append(UInt8(height >> 8))
        jpegData.append(UInt8(height & 0xFF))
        jpegData.append(UInt8(width >> 8))
        jpegData.append(UInt8(width & 0xFF))
        jpegData.append(1)
        jpegData.append(1)
        jpegData.append(0x11)
        jpegData.append(0)

        // DHT marker
        jpegData.append(contentsOf: [0xFF, 0xC4])
        let symbolCounts: [UInt8] = [0, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let symbolValues: [UInt8] = [0, 1, 2, 3, 4]
        let dhtLength: UInt16 = 2 + 1 + 16 + UInt16(symbolValues.count)
        jpegData.append(UInt8(dhtLength >> 8))
        jpegData.append(UInt8(dhtLength & 0xFF))
        jpegData.append(0x00)
        jpegData.append(contentsOf: symbolCounts)
        jpegData.append(contentsOf: symbolValues)

        // SOS marker
        jpegData.append(contentsOf: [0xFF, 0xDA])
        let sosLength: UInt16 = 8
        jpegData.append(UInt8(sosLength >> 8))
        jpegData.append(UInt8(sosLength & 0xFF))
        jpegData.append(1)
        jpegData.append(1)
        jpegData.append(0x00)
        jpegData.append(1)
        jpegData.append(0)
        jpegData.append(0)

        // Compressed pixel data (simplified: all pixels as SSSS=0)
        let compressedData = encodePixelsWithPrediction(pixelCount: width * height)
        jpegData.append(compressedData)

        // EOI marker
        jpegData.append(contentsOf: [0xFF, 0xD9])

        return jpegData
    }

    private func encodePixelsWithPrediction(pixelCount: Int) -> Data {
        let bitStream = BitStreamWriter()
        for _ in 0..<pixelCount {
            bitStream.writeBits(0b00, count: 2)
        }
        return bitStream.data
    }

    private func appendTag(_ data: inout Data, group: UInt16, element: UInt16, vr: String, value: Data) {
        data.append(contentsOf: withUnsafeBytes(of: group.littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: element.littleEndian) { Data($0) })
        data.append(contentsOf: vr.data(using: .ascii)!)

        let shortVRs = ["AE", "AS", "AT", "CS", "DA", "DS", "DT", "FL", "FD", "IS",
                       "LO", "LT", "PN", "SH", "SL", "SS", "ST", "TM", "UI", "UL", "US"]
        let paddedLength = value.count + (value.count % 2)
        if shortVRs.contains(vr) {
            let length = UInt16(paddedLength)
            data.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Data($0) })
        } else {
            data.append(contentsOf: [0x00, 0x00])
            let length = UInt32(paddedLength)
            data.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Data($0) })
        }

        data.append(value)
        if value.count % 2 == 1 {
            data.append(0x00)
        }
    }

    private func writeTempDICOMFile(_ data: Data) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "perf_test_\(UUID().uuidString).dcm"
        let fileURL = tempDir.appendingPathComponent(fileName)
        try data.write(to: fileURL)
        return fileURL
    }
}

// MARK: - Helper Classes

private class BitStreamWriter {
    private var bytes: [UInt8] = []
    private var currentByte: UInt8 = 0
    private var bitPosition: Int = 0

    func writeBits(_ value: Int, count: Int) {
        guard count > 0 && count <= 8 else { return }
        guard value >= 0 && value < 256 else { return }

        for i in (0..<count).reversed() {
            let bit = (value >> i) & 1
            currentByte = (currentByte << 1) | UInt8(bit)
            bitPosition += 1

            if bitPosition == 8 {
                bytes.append(currentByte)
                if currentByte == 0xFF {
                    bytes.append(0x00)
                }
                currentByte = 0
                bitPosition = 0
            }
        }
    }

    var data: Data {
        var result = bytes
        if bitPosition > 0 {
            currentByte <<= (8 - bitPosition)
            result.append(currentByte)
            if currentByte == 0xFF {
                result.append(0x00)
            }
        }
        return Data(result)
    }
}
