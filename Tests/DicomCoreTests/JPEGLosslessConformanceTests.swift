//
//  JPEGLosslessConformanceTests.swift
//  DicomCoreTests
//
//  IMPORTANT: This test suite requires JPEG Lossless DICOM files from conformance test suites. See
//  Tests/DicomCoreTests/Fixtures/README.md section "6. JPEG Lossless Test Files" for instructions.
//
//  Expected test files (place in Tests/DicomCoreTests/Fixtures/Compressed/): - dcm4che test data:
//  Files with transfer syntax 1.2.840.10008.1.2.4.70 or .57 - NEMA conformance samples: JPEG
//  Lossless test images - Converted clinical samples: Real-world CT/MR images compressed with JPEG
//  Lossless
//
//  Validation approach: 1. Decode DICOM files with DCMDecoder (uses JPEGLosslessDecoder) 2. Verify
//  pixel data is successfully extracted 3. Validate image dimensions and bit depth 4. Check pixel
//  value ranges are reasonable for modality 5. Compare with reference decoder output if available
//  (external reference decoder).
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
import Foundation
import DicomTestSupport
@testable import DicomCore

// Compatibility coverage: this suite intentionally exercises deprecated
// public APIs that remain available (issue #1221); the annotation keeps
// the deliberate legacy usage warning-free without hiding new ones.
@available(*, deprecated)
final class JPEGLosslessConformanceTests: XCTestCase {

    // MARK: - Test Configuration

    /// Directory containing JPEG Lossless conformance test files
    private var conformanceDirectory: URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Compressed")
    }

    /// Transfer syntax UIDs for JPEG Lossless
    private let jpegLosslessUIDs = [
        "1.2.840.10008.1.2.4.70",  // JPEG Lossless, First-Order Prediction (Process 14) - Most common
        "1.2.840.10008.1.2.4.57"   // JPEG Lossless, Non-Hierarchical (Any Process)
    ]

    // MARK: - Setup

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Verify conformance directory exists
        guard FileManager.default.fileExists(atPath: conformanceDirectory.path) else {
            throw skipMissingConformanceFixtures("Fixtures/Compressed directory is absent.")
        }
    }

    // MARK: - Test Discovery

    /// Find all JPEG Lossless DICOM files in the conformance directory
    func findJPEGLosslessFiles() throws -> [URL] {
        let allFiles = try FileManager.default.contentsOfDirectory(
            at: conformanceDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "dcm" || $0.pathExtension == "DCM" }

        // Filter for JPEG Lossless files by checking transfer syntax
        var jpegLosslessFiles: [URL] = []

        for file in allFiles {
            // Quick check: try to decode and check transfer syntax
            guard let decoder = try? DCMDecoder(contentsOf: file) else {
                continue
            }

            // Check transfer syntax
            let transferSyntax = decoder.info(for: .transferSyntaxUID)
            if jpegLosslessUIDs.contains(where: { transferSyntax.contains($0) }) {
                jpegLosslessFiles.append(file)
            } else if file.lastPathComponent.lowercased().contains("lossless") {
                // Also check for "lossless" in filename (common convention)
                jpegLosslessFiles.append(file)
            }
        }

        return jpegLosslessFiles
    }

    // MARK: - Conformance Tests

    /// Test basic loading of JPEG Lossless conformance files
    func testLoadJPEGLosslessConformanceFiles() throws {
        let files = try findJPEGLosslessFiles()

        guard !files.isEmpty else {
            throw skipMissingConformanceFixtures("No JPEG Lossless DICOM files found in Fixtures/Compressed.")
        }

        print("\n=== Testing \(files.count) JPEG Lossless conformance files ===")

        var successCount = 0
        var failureReasons: [String: String] = [:]
        var selectionValueCounts: [Int: Int] = [:]
        var selectionValueFiles: [Int: [String]] = [:]

        for file in files {
            print("\nTesting: \(file.lastPathComponent)")

            guard let decoder = try? DCMDecoder(contentsOf: file) else {
                failureReasons[file.lastPathComponent] = "Failed to read DICOM file"
                print("  ❌ Failed to read DICOM file")
                continue
            }

            print("  ✓ DICOM file loaded")

            // Verify transfer syntax
            let transferSyntax = decoder.info(for: .transferSyntaxUID)
            print("  Transfer Syntax: \(transferSyntax)")

            // Verify image properties
            print("  Dimensions: \(decoder.width) x \(decoder.height)")

            let bitsAllocated = Int(decoder.info(for: .bitsAllocated)) ?? 16
            let bitsStored = Int(decoder.info(for: .bitsStored)) ?? bitsAllocated
            print("  Bits Allocated: \(bitsAllocated)")
            print("  Bits Stored: \(bitsStored)")

            guard decoder.width > 0 && decoder.height > 0 else {
                failureReasons[file.lastPathComponent] = "Invalid dimensions"
                print("  ❌ Invalid dimensions")
                continue
            }

            // Extract selection value from JPEG Lossless stream
            if let selectionValue = try? extractSelectionValue(from: file) {
                print("  Selection Value: \(selectionValue)")
                selectionValueCounts[selectionValue, default: 0] += 1
                selectionValueFiles[selectionValue, default: []].append(file.lastPathComponent)
            }

            // Attempt pixel data extraction
            if bitsAllocated == 16 {
                    guard let pixels = decoder.getPixels16() else {
                        failureReasons[file.lastPathComponent] = "getPixels16() returned nil"
                        print("  ❌ getPixels16() returned nil")
                        continue
                    }

                    let expectedCount = decoder.width * decoder.height * decoder.samplesPerPixel

                    guard pixels.count == expectedCount else {
                        failureReasons[file.lastPathComponent] = "Pixel count mismatch: got \(pixels.count), expected \(expectedCount)"
                        print("  ❌ Pixel count mismatch")
                        continue
                    }

                    print("  ✓ Extracted \(pixels.count) pixels (16-bit)")

                    // Verify pixel value range
                    if let minVal = pixels.min(), let maxVal = pixels.max() {
                        print("  Pixel range: \(minVal) - \(maxVal)")
                    }
                } else if bitsAllocated == 8 {
                    guard let pixels = decoder.getPixels8() else {
                        failureReasons[file.lastPathComponent] = "getPixels8() returned nil"
                        print("  ❌ getPixels8() returned nil")
                        continue
                    }

                    let expectedCount = decoder.width * decoder.height * decoder.samplesPerPixel

                    guard pixels.count == expectedCount else {
                        failureReasons[file.lastPathComponent] = "Pixel count mismatch: got \(pixels.count), expected \(expectedCount)"
                        print("  ❌ Pixel count mismatch")
                        continue
                    }

                    print("  ✓ Extracted \(pixels.count) pixels (8-bit)")
                } else {
                    failureReasons[file.lastPathComponent] = "Unsupported bit depth: \(bitsAllocated)"
                    print("  ❌ Unsupported bit depth")
                    continue
                }

                print("  ✅ Successfully decoded")
                successCount += 1
        }

        // Summary
        print("\n=== Conformance Test Summary ===")
        print("Total files tested: \(files.count)")
        print("Successful: \(successCount)")
        print("Failed: \(files.count - successCount)")

        // Selection value distribution
        if !selectionValueCounts.isEmpty {
            print("\n=== Selection Value Coverage ===")
            for selectionValue in selectionValueCounts.keys.sorted() {
                let count = selectionValueCounts[selectionValue]!
                let predictor = getSelectionValueDescription(selectionValue)
                print("Selection Value \(selectionValue) (\(predictor)): \(count) files")

                // List files for each selection value
                if let fileList = selectionValueFiles[selectionValue] {
                    for fileName in fileList {
                        print("  - \(fileName)")
                    }
                }
            }

            // Warn if we only have one selection value
            if selectionValueCounts.count == 1 {
                print("\n⚠️  Warning: Only one selection value found in test files.")
                print("   Consider adding files with other selection values (0-7) for comprehensive testing.")
            }
        }

        if !failureReasons.isEmpty {
            print("\nFailure details:")
            for (file, reason) in failureReasons {
                print("  - \(file): \(reason)")
            }
        }

        // All conformance files should decode successfully
        XCTAssertEqual(successCount, files.count, "Not all conformance files decoded successfully")
    }

    /// Test specific JPEG Lossless Process 14 (most common)
    func testJPEGLosslessProcess14Conformance() throws {
        let files = try findJPEGLosslessFiles()

        // Filter for Process 14 (transfer syntax 1.2.840.10008.1.2.4.70)
        var process14Files: [URL] = []

        for file in files {
            guard let decoder = try? DCMDecoder(contentsOf: file) else {
                continue
            }

            let transferSyntax = decoder.info(for: .transferSyntaxUID)
            if transferSyntax.contains("1.2.840.10008.1.2.4.70") {
                process14Files.append(file)
            }
        }

        guard !process14Files.isEmpty else {
            throw skipMissingConformanceFixtures(
                "No JPEG Lossless Process 14 files found. Transfer syntax: 1.2.840.10008.1.2.4.70."
            )
        }

        print("\n=== Testing \(process14Files.count) JPEG Lossless Process 14 files ===")

        for file in process14Files {
            print("\nTesting: \(file.lastPathComponent)")

            guard let decoder = try? DCMDecoder(contentsOf: file) else {
                XCTFail("Failed to load \(file.lastPathComponent)")
                continue
            }

            XCTAssertGreaterThan(decoder.width, 0, "Invalid width")
            XCTAssertGreaterThan(decoder.height, 0, "Invalid height")

            // Decode pixel data
            let bitsAllocated = Int(decoder.info(for: .bitsAllocated)) ?? 16

            if bitsAllocated == 16 {
                guard let pixels = decoder.getPixels16() else {
                    XCTFail("getPixels16() returned nil for \(file.lastPathComponent)")
                    continue
                }
                XCTAssertEqual(pixels.count, decoder.width * decoder.height * decoder.samplesPerPixel,
                              "Pixel count mismatch for \(file.lastPathComponent)")
                print("  ✓ Successfully decoded \(pixels.count) pixels")
            } else if bitsAllocated == 8 {
                guard let pixels = decoder.getPixels8() else {
                    XCTFail("getPixels8() returned nil for \(file.lastPathComponent)")
                    continue
                }
                XCTAssertEqual(pixels.count, decoder.width * decoder.height * decoder.samplesPerPixel,
                              "Pixel count mismatch for \(file.lastPathComponent)")
                print("  ✓ Successfully decoded \(pixels.count) pixels")
            }
        }
    }

    /// Test pixel value consistency across multiple decodes
    func testJPEGLosslessDecodeConsistency() throws {
        let files = try findJPEGLosslessFiles()

        guard let testFile = files.first else {
            throw skipMissingConformanceFixtures("No JPEG Lossless test files available.")
        }

        print("\nTesting decode consistency with: \(testFile.lastPathComponent)")

        // Decode the same file 3 times
        var pixelArrays: [[UInt16]] = []

        for iteration in 1...3 {
            guard let decoder = try? DCMDecoder(contentsOf: testFile) else {
                XCTFail("Failed to load file on iteration \(iteration)")
                return
            }

            guard let pixels = decoder.getPixels16() else {
                XCTFail("getPixels16() returned nil on iteration \(iteration)")
                return
            }
            pixelArrays.append(pixels)
            print("  Iteration \(iteration): \(pixels.count) pixels")
        }

        // Verify all decodes produced identical results
        XCTAssertEqual(pixelArrays[0].count, pixelArrays[1].count, "Pixel count differs between iterations")
        XCTAssertEqual(pixelArrays[1].count, pixelArrays[2].count, "Pixel count differs between iterations")

        // Check pixel values are identical
        for i in 0..<pixelArrays[0].count {
            XCTAssertEqual(pixelArrays[0][i], pixelArrays[1][i],
                          "Pixel \(i) differs between iteration 1 and 2")
            XCTAssertEqual(pixelArrays[1][i], pixelArrays[2][i],
                          "Pixel \(i) differs between iteration 2 and 3")
        }

        print("  ✓ All iterations produced identical pixel data")
    }

    /// Test metadata extraction from JPEG Lossless files
    func testJPEGLosslessMetadataExtraction() throws {
        let files = try findJPEGLosslessFiles()

        guard !files.isEmpty else {
            throw skipMissingConformanceFixtures("No JPEG Lossless test files available.")
        }

        print("\n=== Testing metadata extraction from \(files.count) files ===")

        for file in files {
            print("\nFile: \(file.lastPathComponent)")

            guard let decoder = try? DCMDecoder(contentsOf: file) else {
                XCTFail("Failed to load \(file.lastPathComponent)")
                continue
            }

            // Extract common metadata tags
            let modality = decoder.info(for: .modality)
            let patientName = decoder.info(for: .patientName)
            let studyDate = decoder.info(for: .studyDate)
            let bitsStored = decoder.info(for: .bitsStored)

            print("  Modality: \(modality)")
            print("  Patient Name: \(patientName)")
            print("  Study Date: \(studyDate)")
            print("  Image Size: \(decoder.width) x \(decoder.height)")
            print("  Bits Stored: \(bitsStored)")

            // Metadata should be accessible even with compressed pixel data
            XCTAssertNotEqual(modality, "", "Modality should be extractable")
        }
    }

    /// Test various bit depths in JPEG Lossless files
    func testJPEGLosslessBitDepthVariety() throws {
        let files = try findJPEGLosslessFiles()

        guard !files.isEmpty else {
            throw skipMissingConformanceFixtures("No JPEG Lossless test files available.")
        }

        var bitDepthCounts: [Int: Int] = [:]

        print("\n=== Testing bit depth variety ===")

        for file in files {
            guard let decoder = try? DCMDecoder(contentsOf: file) else {
                continue
            }

            let bitsStored = Int(decoder.info(for: .bitsStored)) ?? 16
            bitDepthCounts[bitsStored, default: 0] += 1

            // Verify decoder can handle this bit depth
            let bitsAllocated = Int(decoder.info(for: .bitsAllocated)) ?? 16
            if bitsAllocated == 16 {
                if let pixels = decoder.getPixels16() {
                    XCTAssertGreaterThan(pixels.count, 0)
                }
            } else if bitsAllocated == 8 {
                if let pixels = decoder.getPixels8() {
                    XCTAssertGreaterThan(pixels.count, 0)
                }
            }
        }

        print("\nBit depth distribution:")
        for (bitDepth, count) in bitDepthCounts.sorted(by: { $0.key < $1.key }) {
            print("  \(bitDepth)-bit: \(count) files")
        }

        // Common medical imaging bit depths: 8, 12, 16
        // At least one bit depth should be represented
        XCTAssertFalse(bitDepthCounts.isEmpty, "Should have files with various bit depths")
    }

    /// Test all JPEG Lossless selection values (predictors)
    /// Validates that the decoder correctly handles different predictor algorithms
    func testJPEGLosslessSelectionValues() throws {
        let files = try findJPEGLosslessFiles()

        guard !files.isEmpty else {
            throw skipMissingConformanceFixtures("No JPEG Lossless test files available.")
        }

        print("\n=== Testing JPEG Lossless Selection Values ===")

        // Group files by selection value
        var filesBySelectionValue: [Int: [URL]] = [:]

        for file in files {
            if let selectionValue = try? extractSelectionValue(from: file) {
                filesBySelectionValue[selectionValue, default: []].append(file)
            }
        }

        guard !filesBySelectionValue.isEmpty else {
            throw skipMissingConformanceFixtures("Could not extract selection values from any JPEG Lossless test files.")
        }

        print("\nFound \(filesBySelectionValue.count) distinct selection value(s):")

        // Test each selection value group
        for selectionValue in filesBySelectionValue.keys.sorted() {
            let filesForValue = filesBySelectionValue[selectionValue]!
            let predictor = getSelectionValueDescription(selectionValue)

            print("\n--- Selection Value \(selectionValue) (\(predictor)) ---")
            print("Testing \(filesForValue.count) file(s)")

            var successCount = 0

            for file in filesForValue {
                let decoder = DCMDecoder()
                decoder.setDicomFilename(file.path)

                guard decoder.dicomFileReadSuccess else {
                    print("  ❌ \(file.lastPathComponent): Failed to load")
                    continue
                }

                let bitsAllocated = Int(decoder.info(for: 0x00280100)) ?? 16

                // Attempt pixel extraction
                var pixelsExtracted = false
                if bitsAllocated == 16 {
                    if let pixels = decoder.getPixels16() {
                        let expectedCount = decoder.width * decoder.height * decoder.samplesPerPixel
                        if pixels.count == expectedCount {
                            pixelsExtracted = true
                            print("  ✓ \(file.lastPathComponent): \(decoder.width)x\(decoder.height), \(pixels.count) pixels")
                        } else {
                            print("  ❌ \(file.lastPathComponent): Pixel count mismatch")
                        }
                    }
                } else if bitsAllocated == 8 {
                    if let pixels = decoder.getPixels8() {
                        let expectedCount = decoder.width * decoder.height * decoder.samplesPerPixel
                        if pixels.count == expectedCount {
                            pixelsExtracted = true
                            print("  ✓ \(file.lastPathComponent): \(decoder.width)x\(decoder.height), \(pixels.count) pixels")
                        } else {
                            print("  ❌ \(file.lastPathComponent): Pixel count mismatch")
                        }
                    }
                }

                if pixelsExtracted {
                    successCount += 1
                }
            }

            // Validate that all files with this selection value decoded successfully
            XCTAssertEqual(successCount, filesForValue.count,
                          "Not all files with selection value \(selectionValue) decoded successfully (\(successCount)/\(filesForValue.count))")

            print("Result: \(successCount)/\(filesForValue.count) files decoded successfully")
        }

        // Summary
        print("\n=== Selection Value Summary ===")
        print("Total selection values tested: \(filesBySelectionValue.count)")
        print("Selection values found: \(filesBySelectionValue.keys.sorted().map(String.init).joined(separator: ", "))")

        // Note about comprehensive testing
        if filesBySelectionValue.count == 1 && filesBySelectionValue.keys.first == 1 {
            print("\n⚠️  Note: Only Selection Value 1 (1D predictor) found in test files.")
            print("   This is the most common predictor for DICOM (required by TS 1.2.840.10008.1.2.4.70).")
            print("   Consider adding test files with other selection values (0, 2-7) for comprehensive coverage.")
        }

        // At least one selection value should be tested
        XCTAssertGreaterThan(filesBySelectionValue.keys.count, 0, "Should test at least one selection value")
    }

    /// Regression test: a minimal synthetic SV1 file (2x2, 16-bit, built by
    /// `makeMinimalJPEGLosslessData`) used to crash the test runner with
    /// signal 5 inside `extractSelectionValue` — the pixel-data slice kept the
    /// parent Data's indices while the SOS offsets were zero-based, so the
    /// subscript trapped instead of failing. Unusual-but-valid lossless files
    /// must decode or fail gracefully, never crash.
    func testSelectionValueExtractionSurvivesMinimalSyntheticSV1File() throws {
        let fixtureData = try ClinicalParityCuratedFixtureTests.makeJPEGLosslessFixtureData()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JPEGLosslessConformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("jpeg_lossless_sv1_minimal.dcm")
        try fixtureData.write(to: fileURL)

        let selectionValue = try extractSelectionValue(from: fileURL)
        XCTAssertEqual(selectionValue, 1, "minimal SV1 fixture must report selection value 1")

        let decoder = try DCMDecoder(contentsOf: fileURL)
        let pixels = try XCTUnwrap(decoder.getPixels16(), "minimal SV1 fixture must decode to 16-bit pixels")
        XCTAssertEqual(pixels.count, decoder.width * decoder.height * decoder.samplesPerPixel)
    }

    // MARK: - Performance Testing

    /// Test decoding performance with conformance files
    func testJPEGLosslessConformancePerformance() throws {
        let files = try findJPEGLosslessFiles()

        guard !files.isEmpty else {
            throw skipMissingConformanceFixtures("No JPEG Lossless test files available.")
        }

        print("\n=== Performance testing \(files.count) conformance files ===")

        for file in files {
            let startTime = CFAbsoluteTimeGetCurrent()
            guard let decoder = try? DCMDecoder(contentsOf: file) else {
                continue
            }
            _ = decoder.getPixels16()
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime

            let pixels = decoder.width * decoder.height
            let throughput = Double(pixels) / elapsed / 1_000_000.0  // Megapixels/sec

            print("\n\(file.lastPathComponent):")
            print("  Size: \(decoder.width) x \(decoder.height)")
            print("  Time: \(String(format: "%.3f", elapsed * 1000)) ms")
            print("  Throughput: \(String(format: "%.1f", throughput)) Mpixels/sec")

            // Performance should be reasonable (not excessively slow)
            // Allow up to 5 seconds for very large images
            XCTAssertLessThan(elapsed, 5.0, "Decoding took too long for \(file.lastPathComponent)")
        }
    }
}

// MARK: - Helper Extensions

@available(*, deprecated)
extension JPEGLosslessConformanceTests {
    func skipMissingConformanceFixtures(_ detail: String) -> XCTSkip {
        let status = DicomRuntimeStatus(
            capability: .jpegLosslessConformanceFixtures,
            kind: .missingOptionalRuntime,
            message: detail
        )
        return XCTSkip(DicomTestRuntimePreflight.skipMessage(for: status))
    }

    /// Print detailed information about a DICOM file
    func printDICOMInfo(_ file: URL) {
        guard let decoder = try? DCMDecoder(contentsOf: file), decoder.isValid() else {
            print("Failed to read: \(file.lastPathComponent)")
            return
        }

        print("\n=== \(file.lastPathComponent) ===")
        print("Transfer Syntax: \(decoder.info(for: 0x00020010))")
        print("SOP Class: \(decoder.info(for: 0x00020002))")
        print("Modality: \(decoder.info(for: 0x00080060))")
        print("Patient Name: \(decoder.info(for: 0x00100010))")
        print("Dimensions: \(decoder.width) x \(decoder.height)")
        print("Bits Allocated: \(decoder.info(for: 0x00280100))")
        print("Bits Stored: \(decoder.info(for: 0x00280101))")
        print("High Bit: \(decoder.info(for: 0x00280102))")
        print("Samples Per Pixel: \(decoder.samplesPerPixel)")
        print("Photometric Interpretation: \(decoder.info(for: 0x00280004))")
    }

    /// Extract selection value from JPEG Lossless DICOM file
    /// - Parameter file: URL of DICOM file with JPEG Lossless pixel data
    /// - Returns: Selection value (0-7) if found
    /// - Throws: Error if file cannot be parsed
    func extractSelectionValue(from file: URL) throws -> Int {
        // Load DICOM file
        guard let data = try? Data(contentsOf: file) else {
            throw DICOMError.fileNotFound(path: file.path)
        }

        // Find pixel data tag (7FE0,0010)
        // This is a simplified search - in production use full DICOM parser
        let pixelDataTag: [UInt8] = [0xE0, 0x7F, 0x10, 0x00]
        var searchIndex = 0

        while searchIndex < data.count - 4 {
            let slice = data[searchIndex..<searchIndex+4]
            if Array(slice) == pixelDataTag {
                // Found pixel data tag, skip VR and length fields
                // Format depends on transfer syntax (explicit vs implicit VR)
                var pixelDataStart = searchIndex + 4

                // Skip VR (2 bytes) and reserved (2 bytes) for OB/OW
                if pixelDataStart + 8 < data.count {
                    pixelDataStart += 8

                    // Extract encapsulated pixel data, re-based to index 0.
                    // A plain `data[pixelDataStart...]` slice keeps the parent
                    // Data's indices, so subscripting it with the zero-based
                    // SOS offsets below traps (signal 5) instead of failing.
                    let jpegData = Data(data[pixelDataStart...])

                    // Parse JPEG markers to find SOS (Start of Scan)
                    if let sosIndex = findSOSMarker(in: jpegData) {
                        // SOS structure (after marker):
                        // Length (2 bytes)
                        // Number of components (1 byte)
                        // Component specs (2 bytes each)
                        // Start spectral (1 byte) <- This is the selection value
                        let sosDataIndex = sosIndex + 2 // Skip marker

                        // Length and component-count bytes must exist before reading.
                        guard sosDataIndex + 2 < jpegData.count else { break }
                        let sosLength = Int(jpegData[sosDataIndex]) << 8 | Int(jpegData[sosDataIndex + 1])

                        if sosDataIndex + sosLength < jpegData.count {
                            let numComponents = Int(jpegData[sosDataIndex + 2])
                            // Skip component specs (2 bytes each)
                            let selectionValueIndex = sosDataIndex + 3 + (numComponents * 2)

                            if selectionValueIndex < jpegData.count {
                                let selectionValue = Int(jpegData[selectionValueIndex])
                                return selectionValue
                            }
                        }
                    }
                }
                break
            }
            searchIndex += 1
        }

        throw DICOMError.invalidDICOMFormat(reason: "Could not extract selection value from JPEG Lossless stream")
    }

    /// Find Start of Scan (SOS) marker in JPEG data
    /// - Parameter data: JPEG bitstream
    /// - Returns: Index of SOS marker (0xFFDA) if found
    private func findSOSMarker(in data: Data) -> Int? {
        let sosMarker: [UInt8] = [0xFF, 0xDA]
        var index = 0

        while index < data.count - 1 {
            if data[index] == sosMarker[0] && data[index + 1] == sosMarker[1] {
                return index
            }
            index += 1
        }

        return nil
    }

    /// Get human-readable description of selection value (predictor)
    /// - Parameter selectionValue: Selection value (0-7)
    /// - Returns: Description of predictor algorithm
    func getSelectionValueDescription(_ selectionValue: Int) -> String {
        switch selectionValue {
        case 0:
            return "No prediction"
        case 1:
            return "1D predictor (Ra)"
        case 2:
            return "1D predictor (Rb)"
        case 3:
            return "1D predictor (Rc)"
        case 4:
            return "2D predictor (Ra + Rb - Rc)"
        case 5:
            return "2D predictor (Ra + ((Rb - Rc) >> 1))"
        case 6:
            return "2D predictor (Rb + ((Ra - Rc) >> 1))"
        case 7:
            return "2D predictor ((Ra + Rb) >> 1)"
        default:
            return "Unknown predictor"
        }
    }
}
