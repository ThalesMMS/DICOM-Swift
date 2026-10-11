import XCTest
import simd
@testable import DicomCore
import DicomTestSupport

// MARK: - DicomSeriesLoader Helpers Tests

// Compatibility coverage: this suite intentionally exercises deprecated
// public APIs that remain available (issue #1221); the annotation keeps
// the deliberate legacy usage warning-free without hiding new ones.
@available(*, deprecated)
final class DicomSeriesLoaderHelpersTests: XCTestCase {

    // MARK: - computeZSpacing Tests

    func testValidatedOrientationAcceptsRoundedDirectionCosines() throws {
        let loader = DicomSeriesLoader()

        let orientation = try loader.validatedOrientation(
            from: (
                row: SIMD3<Double>(0.9982, 0, 0),
                column: SIMD3<Double>(0, 1.0018, 0)
            )
        )

        XCTAssertEqual(simd_length(orientation.row), 1.0, accuracy: 1e-10)
        XCTAssertEqual(simd_length(orientation.column), 1.0, accuracy: 1e-10)
    }

    func testComputeZSpacingReturnNilForSingleSlice() throws {
        let loader = DicomSeriesLoader()
        let slice = SliceMeta(
            url: URL(fileURLWithPath: "/test/slice1.dcm"),
            position: SIMD3<Double>(0, 0, 0),
            instanceNumber: 1,
            projection: nil
        )

        let spacing = try loader.computeZSpacing(from: [slice], normal: SIMD3<Double>(0, 0, 1))
        XCTAssertNil(spacing, "Single slice should return nil spacing")
    }

    func testComputeZSpacingReturnNilForEmptySlices() throws {
        let loader = DicomSeriesLoader()
        let spacing = try loader.computeZSpacing(from: [], normal: SIMD3<Double>(0, 0, 1))
        XCTAssertNil(spacing, "Empty slices should return nil spacing")
    }

    func testComputeZSpacingUniformSpacing() throws {
        let loader = DicomSeriesLoader()
        // 5 slices with 2.5mm spacing along Z axis
        let slices = (0..<5).map { i in
            SliceMeta(
                url: URL(fileURLWithPath: "/test/slice\(i).dcm"),
                position: SIMD3<Double>(0, 0, Double(i) * 2.5),
                instanceNumber: i,
                projection: nil
            )
        }

        let spacing = try loader.computeZSpacing(from: slices, normal: SIMD3<Double>(0, 0, 1))
        XCTAssertNotNil(spacing, "Should compute spacing for valid slices")
        XCTAssertEqual(spacing!, 2.5, accuracy: 0.001, "Z spacing should be 2.5mm")
    }

    func testComputeZSpacingTwoSlices() throws {
        let loader = DicomSeriesLoader()
        let slices = [
            SliceMeta(url: URL(fileURLWithPath: "/1.dcm"), position: SIMD3<Double>(0, 0, 0), instanceNumber: 1, projection: nil),
            SliceMeta(url: URL(fileURLWithPath: "/2.dcm"), position: SIMD3<Double>(0, 0, 5.0), instanceNumber: 2, projection: nil)
        ]

        let spacing = try loader.computeZSpacing(from: slices, normal: SIMD3<Double>(0, 0, 1))
        XCTAssertNotNil(spacing, "Should compute spacing for two slices")
        XCTAssertEqual(spacing!, 5.0, accuracy: 0.001, "Spacing should be 5.0mm")
    }

    func testComputeZSpacingAlongArbitraryNormal() throws {
        let loader = DicomSeriesLoader()
        // Slices positioned along a diagonal normal
        let normal = SIMD3<Double>(1, 0, 0) // along X axis
        let slices = [
            SliceMeta(url: URL(fileURLWithPath: "/1.dcm"), position: SIMD3<Double>(0, 0, 0), instanceNumber: 1, projection: nil),
            SliceMeta(url: URL(fileURLWithPath: "/2.dcm"), position: SIMD3<Double>(3.0, 0, 0), instanceNumber: 2, projection: nil),
            SliceMeta(url: URL(fileURLWithPath: "/3.dcm"), position: SIMD3<Double>(6.0, 0, 0), instanceNumber: 3, projection: nil)
        ]

        let spacing = try loader.computeZSpacing(from: slices, normal: normal)
        XCTAssertNotNil(spacing, "Should compute spacing along X-axis normal")
        XCTAssertEqual(spacing!, 3.0, accuracy: 0.001, "Spacing along X axis should be 3.0mm")
    }

    func testComputeZSpacingWithNilPositions() throws {
        let loader = DicomSeriesLoader()
        // Slices with nil positions should be skipped
        let slices = [
            SliceMeta(url: URL(fileURLWithPath: "/1.dcm"), position: nil, instanceNumber: 1, projection: nil),
            SliceMeta(url: URL(fileURLWithPath: "/2.dcm"), position: nil, instanceNumber: 2, projection: nil),
            SliceMeta(url: URL(fileURLWithPath: "/3.dcm"), position: nil, instanceNumber: 3, projection: nil)
        ]

        let spacing = try loader.computeZSpacing(from: slices, normal: SIMD3<Double>(0, 0, 1))
        XCTAssertNil(spacing, "All nil positions should return nil spacing")
    }

    func testComputeZSpacingIgnoresZeroDistances() throws {
        let loader = DicomSeriesLoader()
        // Duplicate positions should be ignored (zero distance)
        let slices = [
            SliceMeta(url: URL(fileURLWithPath: "/1.dcm"), position: SIMD3<Double>(0, 0, 0), instanceNumber: 1, projection: nil),
            SliceMeta(url: URL(fileURLWithPath: "/2.dcm"), position: SIMD3<Double>(0, 0, 0), instanceNumber: 2, projection: nil), // duplicate
            SliceMeta(url: URL(fileURLWithPath: "/3.dcm"), position: SIMD3<Double>(0, 0, 5.0), instanceNumber: 3, projection: nil)
        ]

        let spacing = try loader.computeZSpacing(from: slices, normal: SIMD3<Double>(0, 0, 1))
        // The zero distance should be ignored, only one non-zero distance remains
        guard let spacing else {
            XCTFail("Non-zero spacing should be computed")
            return
        }
        XCTAssertEqual(spacing, 5.0, accuracy: 0.001, "Non-zero spacing should be 5.0mm")
    }

    func testComputeZSpacingUsesMedianForMultipleDistances() throws {
        let loader = DicomSeriesLoader()
        // Slightly irregular spacing within tolerance (2.46, 2.5, 2.54 -> median = 2.5)
        let slices = [
            SliceMeta(url: URL(fileURLWithPath: "/1.dcm"), position: SIMD3<Double>(0, 0, 0.0), instanceNumber: 1, projection: nil),
            SliceMeta(url: URL(fileURLWithPath: "/2.dcm"), position: SIMD3<Double>(0, 0, 2.46), instanceNumber: 2, projection: nil),
            SliceMeta(url: URL(fileURLWithPath: "/3.dcm"), position: SIMD3<Double>(0, 0, 4.96), instanceNumber: 3, projection: nil),
            SliceMeta(url: URL(fileURLWithPath: "/4.dcm"), position: SIMD3<Double>(0, 0, 7.5), instanceNumber: 4, projection: nil)
        ]

        let spacing = try loader.computeZSpacing(from: slices, normal: SIMD3<Double>(0, 0, 1))
        XCTAssertNotNil(spacing, "Should compute median spacing")
        // Distances are: 2.46, 2.5, 2.54 -> median = 2.5
        XCTAssertEqual(spacing!, 2.5, accuracy: 0.01, "Median spacing should be approximately 2.5mm")
    }

    func testComputeZSpacingAllowsSubmillimeterRoundingNoise() throws {
        let loader = DicomSeriesLoader()
        let slices = [
            SliceMeta(url: URL(fileURLWithPath: "/1.dcm"), position: SIMD3<Double>(0, 0, 0.000), instanceNumber: 1, projection: nil),
            SliceMeta(url: URL(fileURLWithPath: "/2.dcm"), position: SIMD3<Double>(0, 0, 0.300), instanceNumber: 2, projection: nil),
            SliceMeta(url: URL(fileURLWithPath: "/3.dcm"), position: SIMD3<Double>(0, 0, 0.615), instanceNumber: 3, projection: nil),
            SliceMeta(url: URL(fileURLWithPath: "/4.dcm"), position: SIMD3<Double>(0, 0, 0.900), instanceNumber: 4, projection: nil)
        ]

        let spacing = try loader.computeZSpacing(from: slices, normal: SIMD3<Double>(0, 0, 1))
        XCTAssertEqual(try XCTUnwrap(spacing), 0.3, accuracy: 0.001)
    }

    // MARK: - isApproximatelyEqual Tests

    func testIsApproximatelyEqualIdenticalVectors() {
        let loader = DicomSeriesLoader()
        let v = SIMD3<Double>(1.0, 2.0, 3.0)
        XCTAssertTrue(loader.isApproximatelyEqual(v, v), "Identical vectors should be approximately equal")
    }

    func testIsApproximatelyEqualWithinTolerance() {
        let loader = DicomSeriesLoader()
        let v1 = SIMD3<Double>(1.0, 2.0, 3.0)
        let v2 = SIMD3<Double>(1.00001, 2.00001, 3.00001) // within 1e-4 tolerance
        XCTAssertTrue(loader.isApproximatelyEqual(v1, v2), "Vectors within default tolerance should be equal")
    }

    func testIsApproximatelyEqualOutsideTolerance() {
        let loader = DicomSeriesLoader()
        let v1 = SIMD3<Double>(1.0, 2.0, 3.0)
        let v2 = SIMD3<Double>(1.001, 2.0, 3.0) // 0.001 > 1e-4 tolerance
        XCTAssertFalse(loader.isApproximatelyEqual(v1, v2), "Vectors outside default tolerance should not be equal")
    }

    func testIsApproximatelyEqualCustomTolerance() {
        let loader = DicomSeriesLoader()
        let v1 = SIMD3<Double>(1.0, 2.0, 3.0)
        let v2 = SIMD3<Double>(1.5, 2.5, 3.5) // 0.5 difference
        XCTAssertTrue(loader.isApproximatelyEqual(v1, v2, tolerance: 1.0), "Should be equal with tolerance=1.0")
        XCTAssertFalse(loader.isApproximatelyEqual(v1, v2, tolerance: 0.4), "Should not be equal with tolerance=0.4")
    }

    func testIsApproximatelyEqualZeroVectors() {
        let loader = DicomSeriesLoader()
        let zero = SIMD3<Double>(0, 0, 0)
        XCTAssertTrue(loader.isApproximatelyEqual(zero, zero), "Zero vectors should be approximately equal")
    }

    func testIsApproximatelyEqualNegativeComponents() {
        let loader = DicomSeriesLoader()
        let v1 = SIMD3<Double>(-1.0, -2.0, -3.0)
        let v2 = SIMD3<Double>(-1.0, -2.0, -3.0)
        XCTAssertTrue(loader.isApproximatelyEqual(v1, v2), "Identical negative vectors should be equal")
    }

    func testIsApproximatelyEqualOnlyXDiffers() {
        let loader = DicomSeriesLoader()
        let v1 = SIMD3<Double>(1.0, 0.0, 0.0)
        let v2 = SIMD3<Double>(1.0 + 1e-3, 0.0, 0.0) // only X differs by more than tolerance
        XCTAssertFalse(loader.isApproximatelyEqual(v1, v2), "Should fail when only X component exceeds tolerance")
    }

    func testIsApproximatelyEqualOnlyYDiffers() {
        let loader = DicomSeriesLoader()
        let v1 = SIMD3<Double>(0.0, 1.0, 0.0)
        let v2 = SIMD3<Double>(0.0, 1.0 + 1e-3, 0.0) // only Y differs
        XCTAssertFalse(loader.isApproximatelyEqual(v1, v2), "Should fail when only Y component exceeds tolerance")
    }

    func testIsApproximatelyEqualOnlyZDiffers() {
        let loader = DicomSeriesLoader()
        let v1 = SIMD3<Double>(0.0, 0.0, 1.0)
        let v2 = SIMD3<Double>(0.0, 0.0, 1.0 + 1e-3) // only Z differs
        XCTAssertFalse(loader.isApproximatelyEqual(v1, v2), "Should fail when only Z component exceeds tolerance")
    }

    // MARK: - listDicomFiles Tests

    func testListDicomFilesEmptyDirectory() throws {
        let loader = DicomSeriesLoader()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_empty_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let files = try loader.listDicomFiles(in: tempDir)
        XCTAssertTrue(files.isEmpty, "Empty directory should return no DICOM files")
    }

    func testListDicomFilesWithDCMExtension() throws {
        let loader = DicomSeriesLoader()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_dcm_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create fake .dcm files
        let file1 = tempDir.appendingPathComponent("slice1.dcm")
        let file2 = tempDir.appendingPathComponent("slice2.dcm")
        try Data().write(to: file1)
        try Data().write(to: file2)

        let files = try loader.listDicomFiles(in: tempDir)
        XCTAssertEqual(files.count, 2, "Should find 2 .dcm files")
    }

    func testListDicomFilesWithNoExtension() throws {
        let loader = DicomSeriesLoader()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_noext_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Files with no extension should be included
        let file = tempDir.appendingPathComponent("slice1")
        try Data().write(to: file)

        let files = try loader.listDicomFiles(in: tempDir)
        XCTAssertEqual(files.count, 1, "Should find file with no extension")
    }

    func testListDicomFilesIgnoresNonDCMFiles() throws {
        let loader = DicomSeriesLoader()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_mixed_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create files with various extensions
        let dcmFile = tempDir.appendingPathComponent("slice.dcm")
        let jpgFile = tempDir.appendingPathComponent("image.jpg")
        let txtFile = tempDir.appendingPathComponent("notes.txt")
        try Data().write(to: dcmFile)
        try Data().write(to: jpgFile)
        try Data().write(to: txtFile)

        let files = try loader.listDicomFiles(in: tempDir)
        XCTAssertEqual(files.count, 1, "Should only find .dcm file, not .jpg or .txt")
        XCTAssertTrue(files[0].pathExtension.lowercased() == "dcm", "Found file should have .dcm extension")
    }

    func testListDicomFilesSearchesRecursively() throws {
        let loader = DicomSeriesLoader()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_recursive_\(UUID().uuidString)", isDirectory: true)
        let subDir = tempDir.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create .dcm file in subdirectory
        let file = subDir.appendingPathComponent("slice.dcm")
        try Data().write(to: file)

        let files = try loader.listDicomFiles(in: tempDir)
        XCTAssertEqual(files.count, 1, "Should find .dcm files in subdirectories")
    }

    // MARK: - DicomFileResult Tests

    func testDicomFileResultSuccess() {
        let url = URL(fileURLWithPath: "/test/file.dcm")
        let mockDecoder = MockDicomDecoder()
        let result = DicomFileResult(url: url, decoder: mockDecoder)

        XCTAssertTrue(result.success, "Result with decoder should be success")
        XCTAssertNotNil(result.decoder, "Successful result should have decoder")
        XCTAssertNil(result.error, "Successful result should have no error")
        XCTAssertEqual(result.url, url, "Result URL should match")
    }

    func testDicomFileResultFailure() {
        let url = URL(fileURLWithPath: "/test/missing.dcm")
        let error = DICOMError.fileNotFound(path: "/test/missing.dcm")
        let result = DicomFileResult(url: url, error: error)

        XCTAssertFalse(result.success, "Result with error should not be success")
        XCTAssertNil(result.decoder, "Failed result should have no decoder")
        XCTAssertNotNil(result.error, "Failed result should have error")
        XCTAssertEqual(result.url, url, "Result URL should match")
    }

    // MARK: - DicomSeriesLoader+LegacyCompatibility Tests

    func testProtocolExtensionSetDicomFilenameNoCrash() {
        // Test that calling setDicomFilename on a non-DCMDecoder doesn't crash
        let mockDecoder = MockDicomDecoder()
        // The extension silently does nothing for non-DCMDecoder types
        mockDecoder.setDicomFilename("/some/path.dcm")
        // No assertion needed - just verify no crash
    }

    func testProtocolExtensionDicomFileReadSuccess() {
        // For a mock decoder (not DCMDecoder), dicomFileReadSuccess returns isValid()
        let mockDecoder = MockDicomDecoder()
        let expected = mockDecoder.isValid()
        let result = mockDecoder.dicomFileReadSuccess
        XCTAssertEqual(result, expected, "Non-DCMDecoder implementations should report isValid()")
    }

    // MARK: - Signed 16-bit Decode Fast Path Tests

    func testDecodeSliceIntoBufferForSigned16UsesRawCopyWithoutPixelPool() throws {
        let samples: [Int16] = [-1024, 0, 3071, Int16.max]
        let url = try makeSigned16Dicom(width: 2, height: 2, samples: samples, photometricInterpretation: "MONOCHROME2")
        defer { try? FileManager.default.removeItem(at: url) }

        BufferPool.shared.clear()
        BufferPool.shared.resetStatistics()

        let loader = DicomSeriesLoader()
        var output = [Int16](repeating: 0, count: samples.count)
        let count = try loader.decodeSliceIntoBuffer(
            at: url,
            buffer: &output,
            expectedWidth: 2,
            expectedHeight: 2,
            pixelFormat: signed16PixelFormat(photometricInterpretation: "MONOCHROME2")
        )

        XCTAssertEqual(count, samples.count)
        XCTAssertEqual(Array(output.prefix(count)), samples)
        XCTAssertEqual(BufferPool.shared.statistics.totalAcquires, 0)
    }

    func testDecodeSliceIntoBufferForSigned16Monochrome1KeepsStoredSamplesWithoutPixelPool() throws {
        let samples: [Int16] = [-2, -1, 0, 1]
        let url = try makeSigned16Dicom(width: 2, height: 2, samples: samples, photometricInterpretation: "MONOCHROME1")
        defer { try? FileManager.default.removeItem(at: url) }

        BufferPool.shared.clear()
        BufferPool.shared.resetStatistics()

        let loader = DicomSeriesLoader()
        var output = [Int16](repeating: 0, count: samples.count)
        let count = try loader.decodeSliceIntoBuffer(
            at: url,
            buffer: &output,
            expectedWidth: 2,
            expectedHeight: 2,
            pixelFormat: signed16PixelFormat(photometricInterpretation: "MONOCHROME1")
        )

        XCTAssertEqual(count, samples.count)
        // Issue #3032: MONOCHROME1 voxels are the values written; the inversion is a display step.
        XCTAssertEqual(Array(output.prefix(count)), samples)
        XCTAssertEqual(BufferPool.shared.statistics.totalAcquires, 0)
    }

    // MARK: - SliceMeta Tests

    func testSliceMetaCreation() throws {
        let url = URL(fileURLWithPath: "/test/slice.dcm")
        let position = SIMD3<Double>(10.0, 20.0, 30.0)
        let slice = SliceMeta(url: url, position: position, instanceNumber: 5, projection: 1.5)
        let unwrappedPosition = try XCTUnwrap(slice.position)
        let projection = try XCTUnwrap(slice.projection)

        XCTAssertEqual(slice.url, url, "SliceMeta URL should match")
        XCTAssertEqual(unwrappedPosition.x, 10.0, accuracy: 0.01, "SliceMeta position X should match")
        XCTAssertEqual(unwrappedPosition.y, 20.0, accuracy: 0.01, "SliceMeta position Y should match")
        XCTAssertEqual(unwrappedPosition.z, 30.0, accuracy: 0.01, "SliceMeta position Z should match")
        XCTAssertEqual(slice.instanceNumber, 5, "SliceMeta instanceNumber should match")
        XCTAssertEqual(projection, 1.5, accuracy: 0.01, "SliceMeta projection should match")
    }

    func testSliceMetaWithNilPosition() {
        let url = URL(fileURLWithPath: "/test/slice.dcm")
        let slice = SliceMeta(url: url, position: nil, instanceNumber: nil, projection: nil)

        XCTAssertNil(slice.position, "SliceMeta should allow nil position")
        XCTAssertNil(slice.instanceNumber, "SliceMeta should allow nil instanceNumber")
        XCTAssertNil(slice.projection, "SliceMeta should allow nil projection")
    }

    private func signed16PixelFormat(photometricInterpretation: String) -> DicomSeriesLoaderPixelFormat {
        DicomSeriesLoaderPixelFormat(
            bitsAllocated: 16,
            bitsStored: 16,
            highBit: 15,
            pixelRepresentation: 1,
            samplesPerPixel: 1,
            photometricInterpretation: photometricInterpretation,
            planarConfiguration: nil,
            numberOfFrames: 1,
            transferSyntaxUID: DicomTransferSyntax.explicitVRLittleEndian.rawValue,
            isCompressed: false
        )
    }

    private func makeSigned16Dicom(
        width: UInt16,
        height: UInt16,
        samples: [Int16],
        photometricInterpretation: String
    ) throws -> URL {
        var data = Data(repeating: 0, count: 128)
        data.append(contentsOf: "DICM".utf8)

        appendElement(DicomTag.transferSyntaxUID.rawValue, vr: "UI", value: paddedUID("1.2.840.10008.1.2.1"), to: &data)
        appendElement(DicomTag.samplesPerPixel.rawValue, vr: "US", value: uint16(1), to: &data)
        appendElement(DicomTag.photometricInterpretation.rawValue, vr: "CS", value: paddedASCII(photometricInterpretation), to: &data)
        appendElement(DicomTag.rows.rawValue, vr: "US", value: uint16(height), to: &data)
        appendElement(DicomTag.columns.rawValue, vr: "US", value: uint16(width), to: &data)
        appendElement(DicomTag.bitsAllocated.rawValue, vr: "US", value: uint16(16), to: &data)
        appendElement(DicomTag.bitsStored.rawValue, vr: "US", value: uint16(16), to: &data)
        appendElement(DicomTag.highBit.rawValue, vr: "US", value: uint16(15), to: &data)
        appendElement(DicomTag.pixelRepresentation.rawValue, vr: "US", value: uint16(1), to: &data)
        appendElement(DicomTag.pixelData.rawValue, vr: "OW", value: int16Samples(samples), to: &data)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("dcm")
        try data.write(to: url)
        return url
    }

    private func appendElement(_ tag: Int, vr: String, value: Data, to data: inout Data) {
        appendTag(tag, to: &data)
        data.append(contentsOf: vr.utf8)
        if ["OB", "OD", "OF", "OW", "OV", "SQ", "UN", "UR", "UT"].contains(vr) {
            data.append(contentsOf: [0, 0])
            appendUInt32(UInt32(value.count), to: &data)
        } else {
            appendUInt16(UInt16(value.count), to: &data)
        }
        data.append(value)
    }

    private func appendTag(_ tag: Int, to data: inout Data) {
        appendUInt16(UInt16((tag >> 16) & 0xFFFF), to: &data)
        appendUInt16(UInt16(tag & 0xFFFF), to: &data)
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0x00FF))
        data.append(UInt8((value >> 8) & 0x00FF))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0x000000FF))
        data.append(UInt8((value >> 8) & 0x000000FF))
        data.append(UInt8((value >> 16) & 0x000000FF))
        data.append(UInt8((value >> 24) & 0x000000FF))
    }

    private func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0x00FF), UInt8((value >> 8) & 0x00FF)])
    }

    private func int16Samples(_ samples: [Int16]) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let value = UInt16(bitPattern: sample)
            data.append(UInt8(value & 0x00FF))
            data.append(UInt8((value >> 8) & 0x00FF))
        }
        return data
    }

    private func paddedASCII(_ value: String) -> Data {
        var data = Data(value.utf8)
        if data.count % 2 != 0 {
            data.append(0x20)
        }
        return data
    }

    private func paddedUID(_ value: String) -> Data {
        var data = Data(value.utf8)
        if data.count % 2 != 0 {
            data.append(0)
        }
        return data
    }
}
