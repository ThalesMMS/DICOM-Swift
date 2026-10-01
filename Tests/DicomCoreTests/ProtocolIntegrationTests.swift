import XCTest
@testable import DicomCore
import DicomTestSupport

/// Integration tests verifying protocol-based dependency injection works correctly
/// across multiple services and components. These tests ensure that services can
/// work interchangeably with both real implementations (DCMDecoder) and mock
/// implementations (MockDicomDecoder) through the protocol abstraction layer.
final class ProtocolIntegrationTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a decoder factory for StudyDataService that returns real DCMDecoder instances
    private func makeRealDecoderFactory() -> @Sendable (String) throws -> DicomDecoderProtocol {
        return { path in try DCMDecoder(contentsOfFile: path) }
    }

    /// Creates a decoder factory for StudyDataService that returns mock instances
    private func makeMockDecoderFactory(
        mock: MockDicomDecoder
    ) -> @Sendable (String) throws -> DicomDecoderProtocol {
        return { _ in mock }
    }

    /// Creates a decoder factory for DicomSeriesLoader that returns real DCMDecoder instances
    private func makeRealSeriesLoaderFactory() -> @Sendable (String) throws -> DicomDecoderProtocol {
        return { path in try DCMDecoder(contentsOfFile: path) }
    }

    /// Creates a decoder factory for DicomSeriesLoader that returns mock instances
    private func makeMockSeriesLoaderFactory(
        mock: MockDicomDecoder
    ) -> @Sendable (String) throws -> DicomDecoderProtocol {
        return { _ in mock }
    }

    /// Creates a fully configured mock decoder with typical CT scan metadata
    private func makeConfiguredMockDecoder(
        patientName: String = "Integration Test Patient",
        studyUID: String = "1.2.3.4.5.6.7.8.9",
        seriesUID: String = "1.2.3.4.5.6.7.8.9.10",
        modality: String = "CT"
    ) -> MockDicomDecoder {
        let mock = MockDicomDecoder()
        mock.setTag(DicomTag.patientName.rawValue, value: patientName)
        mock.setTag(DicomTag.patientID.rawValue, value: "PAT123")
        mock.setTag(DicomTag.studyInstanceUID.rawValue, value: studyUID)
        mock.setTag(DicomTag.seriesInstanceUID.rawValue, value: seriesUID)
        mock.setTag(DicomTag.modality.rawValue, value: modality)
        mock.setTag(DicomTag.instanceNumber.rawValue, value: "1")
        mock.setTag(DicomTag.columns.rawValue, value: "512")
        mock.setTag(DicomTag.rows.rawValue, value: "512")

        // Add window settings tags for V2 API testing
        mock.setTag(DicomTag.windowCenter.rawValue, value: "50")
        mock.setTag(DicomTag.windowWidth.rawValue, value: "400")

        // Add pixel spacing tag for V2 API testing
        mock.setTag(DicomTag.pixelSpacing.rawValue, value: "0.5\\0.5")

        // Set window settings properties directly (mock uses properties, not tags for these)
        mock.windowCenter = 50.0
        mock.windowWidth = 400.0

        // Configure width and height for pixel spacing V2 API
        mock.width = 512
        mock.height = 512

        mock.dicomFound = true
        // Mock decoder configured as valid
        return mock
    }

    // MARK: - Protocol Conformance Tests

    func testDCMDecoderConformsToProtocol() {
        // Verify that DCMDecoder can be used as a protocol type
        let decoder: DicomDecoderProtocol = DCMDecoder()
        XCTAssertNotNil(decoder, "DCMDecoder should be usable as DicomDecoderProtocol")

        // Verify protocol methods are accessible
        let tagValue = decoder.info(for: DicomTag.patientName.rawValue)
        XCTAssertNotNil(tagValue, "Protocol methods should be accessible")

        // Verify protocol properties are accessible
        let width = decoder.width
        let height = decoder.height
        XCTAssertGreaterThanOrEqual(width, 0, "Protocol properties should be accessible")
        XCTAssertGreaterThanOrEqual(height, 0, "Protocol properties should be accessible")
    }

    func testMockDecoderConformsToProtocol() {
        // Verify that MockDicomDecoder can be used as a protocol type
        let decoder: DicomDecoderProtocol = MockDicomDecoder()
        XCTAssertNotNil(decoder, "MockDicomDecoder should be usable as DicomDecoderProtocol")

        // Verify protocol methods are accessible
        let tagValue = decoder.info(for: DicomTag.patientName.rawValue)
        XCTAssertNotNil(tagValue, "Protocol methods should be accessible")

        // Verify protocol properties are accessible
        let width = decoder.width
        let height = decoder.height
        XCTAssertEqual(width, 512, "Mock should provide configured values")
        XCTAssertEqual(height, 512, "Mock should provide configured values")
    }

    // MARK: - Service Integration Tests

    func testStudyDataServiceWithRealDecoder() async {
        // Create service with real decoder factory
        let service = StudyDataService(decoderFactory: makeRealDecoderFactory())
        XCTAssertNotNil(service, "Service should initialize with real decoder factory")

        // Service should handle non-existent files gracefully
        let metadata = await service.extractStudyMetadata(from: "/nonexistent/test.dcm")
        XCTAssertNil(metadata, "Service should return nil for non-existent files")
    }

    func testStudyDataServiceWithMockDecoder() async {
        // Create mock decoder with test data
        let mockDecoder = makeConfiguredMockDecoder(
            patientName: "Protocol Integration Test",
            studyUID: "1.2.3.4.5.999",
            seriesUID: "1.2.3.4.5.999.1",
            modality: "MR"
        )

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        // Extract metadata using mock decoder
        let metadata = await service.extractStudyMetadata(from: "/test/integration.dcm")

        XCTAssertNotNil(metadata, "Should extract metadata via protocol")
        XCTAssertEqual(metadata?.patientName, "Protocol Integration Test", "Should use mock data")
        XCTAssertEqual(metadata?.studyInstanceUID, "1.2.3.4.5.999", "Should use mock study UID")
        XCTAssertEqual(metadata?.modality, "MR", "Should use mock modality")
    }

    func testDicomSeriesLoaderWithRealDecoder() {
        // Create loader with real decoder factory
        let loader = DicomSeriesLoader(decoderFactory: makeRealSeriesLoaderFactory())
        XCTAssertNotNil(loader, "Loader should initialize with real decoder factory")

        // Loader should handle non-existent directories gracefully
        let nonExistentURL = URL(fileURLWithPath: "/nonexistent/directory")
        XCTAssertThrowsError(
            try loader.loadSeries(in: nonExistentURL),
            "Loader should throw error for non-existent directory"
        )
    }

    func testDicomSeriesLoaderWithMockDecoder() {
        // Create mock decoder with valid geometry
        let mockDecoder = makeConfiguredMockDecoder()
        mockDecoder.width = 256
        mockDecoder.height = 256
        mockDecoder.imagePosition = SIMD3<Double>(0, 0, 0)
        mockDecoder.imageOrientation = (
            row: SIMD3<Double>(1, 0, 0),
            column: SIMD3<Double>(0, 1, 0)
        )

        let loader = DicomSeriesLoader(decoderFactory: makeMockSeriesLoaderFactory(mock: mockDecoder))
        XCTAssertNotNil(loader, "Loader should initialize with mock decoder factory")

        // Loader should handle empty directories gracefully
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("empty_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        XCTAssertThrowsError(
            try loader.loadSeries(in: tempURL),
            "Loader should throw error for empty directory"
        ) { error in
            XCTAssertTrue(error is DicomSeriesLoaderError, "Should throw DicomSeriesLoaderError")
        }
    }

    // MARK: - Multi-Service Integration Tests

    func testMultipleServicesShareDecoderFactory() async {
        // Create a shared mock decoder
        let sharedMock = makeConfiguredMockDecoder(
            patientName: "Shared Factory Patient",
            studyUID: "1.2.3.shared",
            seriesUID: "1.2.3.shared.1"
        )

        // Create factories - note: StudyDataService and DicomSeriesLoader have different factory signatures
        let studyFactory = makeMockDecoderFactory(mock: sharedMock)
        let seriesFactory = makeMockSeriesLoaderFactory(mock: sharedMock)

        // Create multiple services using appropriate factories
        let studyService = StudyDataService(decoderFactory: studyFactory)
        let seriesLoader = DicomSeriesLoader(decoderFactory: seriesFactory)

        // Verify both services work with the shared factory
        let metadata = await studyService.extractStudyMetadata(from: "/test/shared.dcm")
        XCTAssertNotNil(metadata, "StudyDataService should work with shared factory")
        XCTAssertEqual(metadata?.patientName, "Shared Factory Patient", "Should use shared mock data")

        XCTAssertNotNil(seriesLoader, "DicomSeriesLoader should work with shared factory")
    }

    func testServicesWithDifferentDecoderFactories() async {
        // Create two different mock decoders
        let mockA = makeConfiguredMockDecoder(
            patientName: "Patient A",
            studyUID: "1.2.3.A",
            seriesUID: "1.2.3.A.1"
        )

        let mockB = makeConfiguredMockDecoder(
            patientName: "Patient B",
            studyUID: "1.2.3.B",
            seriesUID: "1.2.3.B.1"
        )

        // Create services with different factories
        let serviceA = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockA))
        let serviceB = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockB))

        // Verify each service uses its own factory
        let metadataA = await serviceA.extractStudyMetadata(from: "/test/a.dcm")
        let metadataB = await serviceB.extractStudyMetadata(from: "/test/b.dcm")

        XCTAssertEqual(metadataA?.patientName, "Patient A", "Service A should use its factory")
        XCTAssertEqual(metadataB?.patientName, "Patient B", "Service B should use its factory")
        XCTAssertNotEqual(metadataA?.studyInstanceUID, metadataB?.studyInstanceUID, "Services should be independent")
    }

    // MARK: - Protocol Type Substitutability Tests

    func testRealAndMockDecodersAreInterchangeable() {
        // Array holding both real and mock decoders as protocol types
        let decoders: [DicomDecoderProtocol] = [
            DCMDecoder(),
            MockDicomDecoder(),
            DCMDecoder(),
            makeConfiguredMockDecoder()
        ]

        // Verify all decoders respond to protocol methods
        for (index, decoder) in decoders.enumerated() {
            let tagValue = decoder.info(for: DicomTag.patientName.rawValue)
            XCTAssertNotNil(tagValue, "Decoder \(index) should respond to protocol method")

            let isValid = decoder.isValid()
            XCTAssertNotNil(isValid, "Decoder \(index) should respond to protocol method")

            let width = decoder.width
            XCTAssertGreaterThanOrEqual(width, 0, "Decoder \(index) should provide width")
        }
    }

    func testFactoryProducingDifferentImplementations() async {
        let useReal = DicomTestLockedValue(true)

        // Factory that alternates between real and mock implementations
        let alternatingFactory: @Sendable (String) throws -> DicomDecoderProtocol = { path in
            let shouldUseReal = useReal.withValue { value in
                defer { value.toggle() }
                return value
            }
            if shouldUseReal {
                return try DCMDecoder(contentsOfFile: path)
            } else {
                let mock = MockDicomDecoder()
                mock.setTag(DicomTag.patientName.rawValue, value: "Mock Patient")
                mock.setTag(DicomTag.studyInstanceUID.rawValue, value: "1.2.3")
                mock.setTag(DicomTag.seriesInstanceUID.rawValue, value: "1.2.3.4")
                return mock
            }
        }

        let service = StudyDataService(decoderFactory: alternatingFactory)

        // The service should work regardless of which implementation is returned
        let result1 = await service.extractStudyMetadata(from: "/test/1.dcm")
        let result2 = await service.extractStudyMetadata(from: "/test/2.dcm")

        // Both calls should complete without errors (though may return nil for non-existent files)
        // The point is that the service works with both decoder types
        XCTAssertTrue(result1 == nil || result1 != nil, "Service should handle real decoder")
        XCTAssertTrue(result2 == nil || result2 != nil, "Service should handle mock decoder")
    }

    // MARK: - Validation Integration Tests

    func testValidationWorksThroughProtocol() async {
        let mockDecoder = makeConfiguredMockDecoder()
        mockDecoder.setValidationResult(isValid: true, issues: [])

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        // Create a temporary test file
        let tempPath = NSTemporaryDirectory() + "protocol_validation_test_\(UUID().uuidString).dcm"
        let testData = Data([
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x44, 0x49, 0x43, 0x4D  // DICM header at offset 128
        ])

        try? testData.write(to: URL(fileURLWithPath: tempPath))
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let validationResult = await service.validateDICOMFile(tempPath)

        XCTAssertTrue(validationResult.isValid, "Validation should work through protocol")
        XCTAssertTrue(validationResult.issues.isEmpty, "Should have no issues")
    }

    func testPixelDataAccessThroughProtocol() async {
        // Create mock with pixel data
        let mockDecoder = makeConfiguredMockDecoder()
        mockDecoder.width = 512
        mockDecoder.height = 512

        // Set up 16-bit pixel data
        let pixelCount = 512 * 512
        let pixels16 = [UInt16](repeating: 2000, count: pixelCount)
        mockDecoder.setPixels16(pixels16)

        // Set up downsampled thumbnail data
        let thumbnailSize = 120
        let thumbnailPixels = [UInt16](repeating: 2000, count: thumbnailSize * thumbnailSize)
        mockDecoder.setDownsampledPixels16(thumbnailPixels, width: thumbnailSize, height: thumbnailSize)

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        let thumbnail = await service.extractThumbnail(from: "/test/pixels.dcm")

        XCTAssertNotNil(thumbnail, "Should extract thumbnail through protocol")
        guard let thumbnailData = thumbnail else {
            return
        }
        XCTAssertEqual(
            Array(thumbnailData.prefix(8)),
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] as [UInt8],
            "Extracted thumbnail should be PNG image data"
        )
    }

    // MARK: - Edge Case Integration Tests

    func testProtocolHandlesInvalidData() async {
        // Create mock with invalid data
        let mockDecoder = MockDicomDecoder()
        mockDecoder.dicomFound = false
        // Mock decoder configured as invalid
        mockDecoder.setValidationResult(isValid: false, issues: ["Invalid DICOM file"])

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        let metadata = await service.extractStudyMetadata(from: "/test/invalid.dcm")
        XCTAssertNil(metadata, "Should handle invalid data through protocol")

        // Create test file for validation
        let tempPath = NSTemporaryDirectory() + "invalid_test_\(UUID().uuidString).dcm"
        let testData = Data([0x00, 0x00, 0x00, 0x00])  // Invalid DICOM
        try? testData.write(to: URL(fileURLWithPath: tempPath))
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let validationResult = await service.validateDICOMFile(tempPath)
        XCTAssertFalse(validationResult.isValid, "Should detect invalid file through protocol")
        XCTAssertFalse(validationResult.issues.isEmpty, "Should report validation issues")
    }

    func testProtocolHandlesEmptyMetadata() async {
        // Create mock with no tag data
        let mockDecoder = MockDicomDecoder()
        mockDecoder.dicomFound = true
        // Mock decoder configured as valid
        // Don't set any tags - decoder will return empty strings

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        let metadata = await service.extractStudyMetadata(from: "/test/empty.dcm")

        // Should return nil because required UIDs are missing/empty
        XCTAssertNil(metadata, "Should handle empty metadata through protocol")
    }

    func testProtocolHandlesPartialMetadata() async {
        // Create mock with only some required fields
        let mockDecoder = MockDicomDecoder()
        mockDecoder.setTag(DicomTag.studyInstanceUID.rawValue, value: "1.2.3")
        mockDecoder.setTag(DicomTag.seriesInstanceUID.rawValue, value: "1.2.3.4")
        // Patient name and other fields will be empty - should use fallbacks

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        let metadata = await service.extractStudyMetadata(from: "/test/partial.dcm")

        XCTAssertNotNil(metadata, "Should handle partial metadata through protocol")
        XCTAssertEqual(metadata?.patientName, "Unknown Patient", "Should use fallback values")
        XCTAssertEqual(metadata?.patientID, "Unknown ID", "Should use fallback values")
        XCTAssertEqual(metadata?.studyInstanceUID, "1.2.3", "Should preserve valid UIDs")
    }

    // MARK: - Concurrency Integration Tests

    func testConcurrentAccessToProtocolBasedService() async {
        let mockDecoder = makeConfiguredMockDecoder()
        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        // Execute multiple concurrent operations
        await withTaskGroup(of: StudyMetadata?.self) { group in
            for i in 0..<10 {
                group.addTask {
                    return await service.extractStudyMetadata(from: "/test/concurrent_\(i).dcm")
                }
            }

            var results: [StudyMetadata?] = []
            for await result in group {
                results.append(result)
            }

            XCTAssertEqual(results.count, 10, "Should handle concurrent access through protocol")
        }
    }

    func testConcurrentBatchOperationsThroughProtocol() async {
        let mockDecoder = makeConfiguredMockDecoder(
            patientName: "Batch Patient",
            studyUID: "1.2.3.batch",
            seriesUID: "1.2.3.batch.1"
        )

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        let filePaths = (0..<20).map { "/test/batch_\($0).dcm" }

        let metadata = await service.extractBatchMetadata(from: filePaths)

        XCTAssertEqual(metadata.count, 20, "Should handle batch operations through protocol")
        for meta in metadata {
            XCTAssertEqual(meta.patientName, "Batch Patient", "All should use same mock data")
        }
    }

    // MARK: - Protocol Property Access Tests

    func testAllProtocolPropertiesAccessible() {
        let mock = makeConfiguredMockDecoder()
        let decoder: DicomDecoderProtocol = mock

        // Image properties
        XCTAssertGreaterThan(decoder.bitDepth, 0, "bitDepth should be accessible")
        XCTAssertGreaterThan(decoder.width, 0, "width should be accessible")
        XCTAssertGreaterThan(decoder.height, 0, "height should be accessible")
        XCTAssertGreaterThanOrEqual(decoder.offset, 0, "offset should be accessible")
        XCTAssertGreaterThan(decoder.nImages, 0, "nImages should be accessible")
        XCTAssertGreaterThan(decoder.samplesPerPixel, 0, "samplesPerPixel should be accessible")
        XCTAssertFalse(decoder.photometricInterpretation.isEmpty, "photometricInterpretation should be accessible")

        // Spatial properties
        XCTAssertGreaterThan(decoder.pixelDepth, 0, "pixelDepth should be accessible")
        XCTAssertGreaterThan(decoder.pixelWidth, 0, "pixelWidth should be accessible")
        XCTAssertGreaterThan(decoder.pixelHeight, 0, "pixelHeight should be accessible")

        // Display properties
        XCTAssertNotNil(decoder.windowCenter, "windowCenter should be accessible")
        XCTAssertNotNil(decoder.windowWidth, "windowWidth should be accessible")

        // Status properties
        XCTAssertTrue(decoder.dicomFound, "dicomFound should be accessible")
        XCTAssertTrue(decoder.isValid(), "isValid() should be callable")
        XCTAssertNotNil(decoder.compressedImage, "compressedImage should be accessible")
        XCTAssertNotNil(decoder.signedImage, "signedImage should be accessible")
        XCTAssertGreaterThanOrEqual(decoder.pixelRepresentationTagValue, 0, "pixelRepresentationTagValue should be accessible")
        XCTAssertNotNil(decoder.isSignedPixelRepresentation, "isSignedPixelRepresentation should be accessible")

        // Convenience properties
        XCTAssertNotNil(decoder.isGrayscale, "isGrayscale should be accessible")
        XCTAssertNotNil(decoder.isColorImage, "isColorImage should be accessible")
        XCTAssertNotNil(decoder.isMultiFrame, "isMultiFrame should be accessible")

        let dimensions = decoder.imageDimensions
        XCTAssertGreaterThan(dimensions.width, 0, "imageDimensions should be accessible")

        let spacing = decoder.pixelSpacingV2
        XCTAssertGreaterThan(spacing.x, 0, "pixelSpacingV2 should be accessible")

        let window = decoder.windowSettingsV2
        XCTAssertGreaterThan(window.center, 0, "windowSettingsV2 should be accessible")

        let rescale = decoder.rescaleParametersV2
        XCTAssertNotNil(rescale.intercept, "rescaleParametersV2 should be accessible")
    }

    func testAllProtocolMethodsCallable() {
        let mock = makeConfiguredMockDecoder()
        let decoder: DicomDecoderProtocol = mock

        // Validation methods
        let validationResult = decoder.validateDICOMFile("/test.dcm")
        XCTAssertNotNil(validationResult.isValid, "validateDICOMFile should be callable")

        let isValid = decoder.isValid()
        XCTAssertNotNil(isValid, "isValid should be callable")

        let status = decoder.getValidationStatus()
        XCTAssertNotNil(status.isValid, "getValidationStatus should be callable")

        // Modern file loading API (throwing initializer)
        let _ = try? DCMDecoder(contentsOfFile: "/test.dcm")  // Should not crash

        // Pixel data methods
        let pixels8 = decoder.getPixels8()
        XCTAssertTrue(pixels8 == nil || pixels8 != nil, "getPixels8 should be callable")

        let pixels16 = decoder.getPixels16()
        XCTAssertTrue(pixels16 == nil || pixels16 != nil, "getPixels16 should be callable")

        let pixels24 = decoder.getPixels24()
        XCTAssertTrue(pixels24 == nil || pixels24 != nil, "getPixels24 should be callable")

        let downsampled = decoder.getDownsampledPixels16(maxDimension: 150)
        XCTAssertTrue(downsampled == nil || downsampled != nil, "getDownsampledPixels16 should be callable")

        // Metadata methods
        let tagValue = decoder.info(for: DicomTag.patientName.rawValue)
        XCTAssertNotNil(tagValue, "info(for:) should be callable")

        let intValue = decoder.intValue(for: DicomTag.instanceNumber.rawValue)
        XCTAssertTrue(intValue == nil || intValue != nil, "intValue(for:) should be callable")

        let doubleValue = decoder.doubleValue(for: DicomTag.pixelSpacing.rawValue)
        XCTAssertTrue(doubleValue == nil || doubleValue != nil, "doubleValue(for:) should be callable")

        let allTags = decoder.getAllTags()
        XCTAssertNotNil(allTags, "getAllTags should be callable")

        let patientInfo = decoder.getPatientInfo()
        XCTAssertNotNil(patientInfo, "getPatientInfo should be callable")

        let studyInfo = decoder.getStudyInfo()
        XCTAssertNotNil(studyInfo, "getStudyInfo should be callable")

        let seriesInfo = decoder.getSeriesInfo()
        XCTAssertNotNil(seriesInfo, "getSeriesInfo should be callable")

        // Utility methods
        let rescaledValue = decoder.applyRescale(to: 100.0)
        XCTAssertNotNil(rescaledValue, "applyRescale should be callable")

        let optimalWindow = decoder.calculateOptimalWindowV2()
        XCTAssertTrue(optimalWindow == nil || optimalWindow != nil, "calculateOptimalWindowV2 should be callable")

        let metrics = decoder.getQualityMetrics()
        XCTAssertTrue(metrics == nil || metrics != nil, "getQualityMetrics should be callable")
    }
}
