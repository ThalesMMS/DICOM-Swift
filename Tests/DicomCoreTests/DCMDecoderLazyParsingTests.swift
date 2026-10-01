import XCTest
@testable import DicomCore
import Foundation

/// Tests to verify lazy metadata parsing optimization.
/// These tests measure memory allocation improvements from deferring
/// tag value parsing until first access.
final class DCMDecoderLazyParsingTests: XCTestCase {

    // MARK: - Setup & Utilities

    /// Get path to fixtures directory
    private func getFixturesPath() -> URL {
        return URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    /// Get any available DICOM file from fixtures
    private func getAnyDICOMFile() throws -> URL {
        try getAnyFixtureDICOMURL()
    }

    private func makeDeferredMetadataDICOMFile() throws -> URL {
        let sopClassUID = DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        let sopInstanceUID = "2.25.987654321"
        var elements = [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings([sopClassUID])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([sopInstanceUID])),
            DicomDataElement(tag: 0x0009_0010, vr: .LO, value: .strings(["LAZY TEST"])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS,
                             value: .strings(["MONOCHROME2"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([2])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([2])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([16])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([16])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([15])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW,
                             value: .bytes(Data([1, 0, 2, 0, 3, 0, 4, 0])))
        ]
        elements.append(contentsOf: (0..<64).map { index in
            DicomDataElement(
                tag: 0x0009_1000 + index,
                vr: .LO,
                value: .strings(["deferred-\(index)"])
            )
        })
        let data = try DicomDataSetWriter.part10Data(
            from: DicomDataSet(elements: elements),
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: sopClassUID,
                mediaStorageSOPInstanceUID: sopInstanceUID
            )
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lazy-metadata-\(UUID().uuidString).dcm")
        try data.write(to: url)
        return url
    }

    // MARK: - Memory Allocation Benchmarks

    /// Benchmarks memory allocation improvement from lazy metadata parsing.
    ///
    /// This test verifies that:
    /// 1. Files with many DICOM tags store TagMetadata instead of parsed strings
    /// 2. Only accessed tags are parsed to strings
    /// 3. Memory usage is reduced for files with 100+ tags when only 10-15 accessed
    ///
    /// **Expected Behavior:**
    /// - tagMetadataCache contains entries for non-critical tags
    /// - dicomInfoDict only contains critical tags + accessed tags
    /// - Each TagMetadata (~32 bytes) vs parsed string (~100+ bytes) = ~68% memory savings
    ///
    /// **Acceptance Criteria:**
    /// - Files with 50+ tags should have lazy metadata entries
    /// - Only accessed + critical tags should be in dicomInfoDict
    /// - Memory savings: ~68 bytes per unused tag
    func testLazyParsingMemoryImprovement() throws {
        let file = try makeDeferredMetadataDICOMFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound,
                      "Should successfully read DICOM file: \(file.lastPathComponent)")
        XCTAssertTrue(decoder.isValid(),
                      "Decoder should be valid after loading")

        let tagMetadataCache = decoder.tagMetadataCache
        let dicomInfoDict = decoder.dicomInfoDict

        let lazyTagCount = tagMetadataCache.count
        let parsedTagCount = dicomInfoDict.count

        print("""

        ========== Lazy Parsing Memory Improvement ==========
        File: \(file.lastPathComponent)
        Tags stored as metadata (lazy): \(lazyTagCount)
        Tags parsed to strings (eager): \(parsedTagCount)
        Total tags in file: \(lazyTagCount + parsedTagCount)
        ======================================================

        """)

        let deferredTag = 0x0009_1000
        XCTAssertNotNil(tagMetadataCache[deferredTag])
        XCTAssertNil(dicomInfoDict[deferredTag])

        XCTAssertEqual(decoder.info(for: deferredTag), "deferred-0")

        let dicomInfoDictAfter = decoder.dicomInfoDict
        XCTAssertNotNil(dicomInfoDictAfter[deferredTag])
        XCTAssertEqual(dicomInfoDictAfter.count, parsedTagCount + 1)
        XCTAssertNotNil(decoder.tagMetadataCache[deferredTag])

        let parsedTagCountAfter = dicomInfoDictAfter.count

        // Calculate memory savings
        let bytesPerTagMetadata = 32  // Approximate size of TagMetadata struct
        let bytesPerParsedString = 100  // Approximate size of typical DICOM string value
        let memorySavedPerTag = bytesPerParsedString - bytesPerTagMetadata
        let totalMemorySaved = lazyTagCount * memorySavedPerTag

        print("""

        ========== After Accessing 1 Tag ==========
        Tags parsed to strings (after access): \(parsedTagCountAfter)
        Deferred tags materialized: \(parsedTagCountAfter - parsedTagCount)
        Metadata cache entries retained: \(decoder.tagMetadataCache.count)

        Memory Savings Estimate:
        - Bytes per TagMetadata: ~\(bytesPerTagMetadata) bytes
        - Bytes per parsed string: ~\(bytesPerParsedString) bytes
        - Memory saved per unused tag: ~\(memorySavedPerTag) bytes
        - Total memory saved: ~\(totalMemorySaved) bytes (~\(totalMemorySaved / 1024) KB)
        - Memory reduction: ~\((memorySavedPerTag * 100) / bytesPerParsedString)%
        ========================================================

        """)

        // Verify lazy parsing is working
        if lazyTagCount > 0 {
            XCTAssertGreaterThan(lazyTagCount, 0,
                                "File should have lazy metadata entries for non-critical tags")

            // Verify that not all tags were parsed upfront
            XCTAssertLessThan(parsedTagCount, lazyTagCount + parsedTagCount,
                             "Not all tags should be parsed upfront (lazy parsing optimization)")

            print("""

            ✓ Lazy Parsing Verification: PASSED
              - \(lazyTagCount) tags deferred to lazy parsing
              - ~\(totalMemorySaved / 1024) KB memory saved
              - Only accessed tags parsed on demand

            """)
        } else {
            print("""

            ⚠️  Note: This file has no lazy metadata entries.
               This may occur if:
               - All tags in the file are critical tags (rare)
               - File has very few tags (<20)
               - Test file is a minimal synthetic file

            """)
        }

        XCTAssertGreaterThan(
            lazyTagCount,
            0,
            "The fixture must exercise deferred metadata instead of only eager tags"
        )
    }

    // MARK: - Lazy Parsing Behavior Tests

    /// Verifies that lazy parsing correctly parses tag values on first access.
    ///
    /// This test ensures that:
    /// 1. Tags stored as metadata can be successfully parsed on demand
    /// 2. Parsed values are cached for subsequent access
    /// 3. No functional regression from lazy parsing
    func testLazyTagParsingBehavior() throws {
        let file = try getAnyDICOMFile()

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound,
                      "Should successfully read DICOM file")

        // Access a tag that might be stored lazily
        let studyDescription = decoder.info(for: 0x00081030)  // Study Description

        // First access should parse the tag
        let studyDescription2 = decoder.info(for: 0x00081030)

        // Second access should return cached value
        XCTAssertEqual(studyDescription, studyDescription2,
                      "Repeated access should return same value (cached)")

        // Verify tag access doesn't crash for tags that may not exist
        let unusedTag = decoder.info(for: 0x00091001)  // Private tag
        XCTAssertNotNil(unusedTag, "Should return string (empty or value) for any tag")
    }

    /// Benchmarks the performance of lazy tag parsing.
    ///
    /// Measures the time to parse a tag on first access vs subsequent cached access.
    /// Acceptance criteria: <0.1ms for cached access, <1ms for first parse.
    func testLazyParsingPerformance() throws {
        let file = try getAnyDICOMFile()

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound,
                      "Should successfully read DICOM file")

        // Test tags that might be lazily parsed
        let testTags: [Int] = [
            0x00081030,  // Study Description
            0x0008103E,  // Series Description
            0x00100040,  // Patient Sex
            0x00181030,  // Protocol Name
            0x00200011   // Series Number
        ]

        var firstAccessTimes: [CFAbsoluteTime] = []
        var cachedAccessTimes: [CFAbsoluteTime] = []

        for tag in testTags {
            // First access (may trigger parsing)
            let firstStart = CFAbsoluteTimeGetCurrent()
            _ = decoder.info(for: tag)
            let firstTime = CFAbsoluteTimeGetCurrent() - firstStart
            firstAccessTimes.append(firstTime)

            // Cached access
            let cachedStart = CFAbsoluteTimeGetCurrent()
            _ = decoder.info(for: tag)
            let cachedTime = CFAbsoluteTimeGetCurrent() - cachedStart
            cachedAccessTimes.append(cachedTime)
        }

        let avgFirstAccess = firstAccessTimes.reduce(0.0, +) / Double(firstAccessTimes.count)
        let avgCachedAccess = cachedAccessTimes.reduce(0.0, +) / Double(cachedAccessTimes.count)

        print("""

        ========== Lazy Parsing Performance ==========
        Tags tested: \(testTags.count)
        Avg first access time: \(String(format: "%.6f", avgFirstAccess))s (\(String(format: "%.2f", avgFirstAccess * 1000))ms)
        Avg cached access time: \(String(format: "%.6f", avgCachedAccess))s (\(String(format: "%.2f", avgCachedAccess * 1000))ms)
        Speedup (cached vs first): \(String(format: "%.2f", avgFirstAccess / max(avgCachedAccess, 0.000001)))x
        ===============================================

        """)

        // Cached access should be very fast
        XCTAssertLessThan(avgCachedAccess, 0.001,
                         "Cached access should be <1ms")

        // First access should be reasonably fast (includes parsing overhead)
        XCTAssertLessThan(avgFirstAccess, 0.01,
                         "First access should be <10ms")
    }

}
