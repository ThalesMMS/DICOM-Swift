import XCTest
@testable import DicomCore
import DicomTestSupport

final class StudyDataServiceTests: XCTestCase {

    private final class MockBatchFileLoader: DicomBatchFileLoading {
        private let loadedURLsStorage = DicomTestLockedValue<[URL]>([])
        private let resultsStorage = DicomTestLockedValue<[String: DicomFileResult]>([:])

        private(set) var loadedURLs: [URL] {
            get { loadedURLsStorage.value }
            set { loadedURLsStorage.replace(with: newValue) }
        }

        var resultsByLastPathComponent: [String: DicomFileResult] {
            get { resultsStorage.value }
            set { resultsStorage.replace(with: newValue) }
        }

        func batchLoadFiles(urls: [URL], maxConcurrency: Int) async -> [DicomFileResult] {
            loadedURLs = urls
            let resultsByLastPathComponent = resultsStorage.value
            return urls.map { url in
                guard let result = resultsByLastPathComponent[url.lastPathComponent] else {
                    return DicomFileResult(
                        url: url,
                        error: DICOMError.invalidDICOMFormat(reason: "No mock result")
                    )
                }

                if let decoder = result.decoder {
                    return DicomFileResult(url: url, decoder: decoder)
                }
                return DicomFileResult(
                    url: url,
                    error: result.error ?? DICOMError.invalidDICOMFormat(reason: "No mock result")
                )
            }
        }
    }

    // MARK: - Helpers

    /// Creates a decoder factory for testing
    private func makeDecoderFactory() -> @Sendable (String) throws -> DicomDecoderProtocol {
        return { path in try DCMDecoder(contentsOfFile: path) }
    }

    /// Creates a mock decoder factory for testing dependency injection
    private func makeMockDecoderFactory(
        mock: MockDicomDecoder
    ) -> @Sendable (String) throws -> DicomDecoderProtocol {
        return { _ in mock }
    }

    // MARK: - Service Initialization Tests

    func testServiceInitialization() {
        let service = StudyDataService(decoderFactory: makeDecoderFactory())
        XCTAssertNotNil(service, "Service should initialize successfully")
    }

    func testServiceInitializationWithCustomFileManager() {
        let customFileManager = FileManager.default
        let service = StudyDataService(fileManager: customFileManager, decoderFactory: makeDecoderFactory())
        XCTAssertNotNil(service, "Service should initialize with custom FileManager")
    }

    // MARK: - Dependency Injection Tests

    func testServiceUsesInjectedDecoderFactory() async {
        // Create mock decoder with test data
        let mockDecoder = MockDicomDecoder()
        mockDecoder.setTag(DicomTag.patientName.rawValue, value: "Mock Patient")
        mockDecoder.setTag(DicomTag.patientID.rawValue, value: "MOCK123")
        mockDecoder.setTag(DicomTag.studyInstanceUID.rawValue, value: "1.2.3.4.5")
        mockDecoder.setTag(DicomTag.seriesInstanceUID.rawValue, value: "1.2.3.4.5.6")
        mockDecoder.setTag(DicomTag.modality.rawValue, value: "CT")
        mockDecoder.setTag(DicomTag.instanceNumber.rawValue, value: "1")

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        let metadata = await service.extractStudyMetadata(from: "/test/mock.dcm")

        XCTAssertNotNil(metadata, "Should extract metadata using mock decoder")
        XCTAssertEqual(metadata?.patientName, "Mock Patient", "Should use mock patient name")
        XCTAssertEqual(metadata?.patientID, "MOCK123", "Should use mock patient ID")
        XCTAssertEqual(metadata?.studyInstanceUID, "1.2.3.4.5", "Should use mock study UID")
        XCTAssertEqual(metadata?.seriesInstanceUID, "1.2.3.4.5.6", "Should use mock series UID")
    }

    func testServiceUsesInjectedDecoderForValidation() async {
        // Create mock decoder with valid DICOM data
        let mockDecoder = MockDicomDecoder()
        mockDecoder.setTag(DicomTag.studyInstanceUID.rawValue, value: "1.2.3.4.5")
        mockDecoder.setTag(DicomTag.seriesInstanceUID.rawValue, value: "1.2.3.4.5.6")
        mockDecoder.dicomFound = true
        // Mock decoder configured as valid

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        // Create a temporary file for validation test
        let tempPath = NSTemporaryDirectory() + "test_validation_\(UUID().uuidString).dcm"
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

        let result = await service.validateDICOMFile(tempPath)

        // Validation should succeed because mock decoder has valid UIDs
        XCTAssertTrue(result.isValid, "Should validate successfully with mock decoder")
        XCTAssertTrue(result.issues.isEmpty, "Should have no validation issues")
    }

    func testServiceUsesInjectedDecoderForThumbnail() async {
        // Create mock decoder with pixel data
        let mockDecoder = MockDicomDecoder()
        mockDecoder.width = 512
        mockDecoder.height = 512
        mockDecoder.setTag(DicomTag.columns.rawValue, value: "512")
        mockDecoder.setTag(DicomTag.rows.rawValue, value: "512")

        // Configure downsampled pixels for thumbnail
        let thumbnailSize = 120
        let pixels = [UInt16](repeating: 1000, count: thumbnailSize * thumbnailSize)
        mockDecoder.setDownsampledPixels16(pixels, width: thumbnailSize, height: thumbnailSize)

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        let thumbnail = await service.extractThumbnail(from: "/test/mock.dcm")

        // Thumbnail extraction should use mock decoder
        XCTAssertNotNil(thumbnail, "Should extract thumbnail using mock decoder")
        guard let thumbnailData = thumbnail else {
            return
        }
        XCTAssertEqual(
            Array(thumbnailData.prefix(8)),
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] as [UInt8],
            "Extracted thumbnail should be PNG image data"
        )
    }

    func testServiceHandlesMissingUIDsFromMockDecoder() async {
        // Create mock decoder with missing UIDs
        let mockDecoder = MockDicomDecoder()
        mockDecoder.setTag(DicomTag.patientName.rawValue, value: "Test Patient")
        mockDecoder.setTag(DicomTag.patientID.rawValue, value: "PAT001")
        // Intentionally omit studyInstanceUID and seriesInstanceUID

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        let metadata = await service.extractStudyMetadata(from: "/test/mock.dcm")

        // Should return nil because required UIDs are missing
        XCTAssertNil(metadata, "Should return nil when required UIDs are missing")
    }

    func testServiceHandlesEmptyTagValuesFromMockDecoder() async {
        // Create mock decoder with empty values that should use fallbacks
        let mockDecoder = MockDicomDecoder()
        mockDecoder.setTag(DicomTag.patientName.rawValue, value: "")  // Empty - should fallback
        mockDecoder.setTag(DicomTag.patientID.rawValue, value: "")    // Empty - should fallback
        mockDecoder.setTag(DicomTag.studyInstanceUID.rawValue, value: "1.2.3.4.5")
        mockDecoder.setTag(DicomTag.seriesInstanceUID.rawValue, value: "1.2.3.4.5.6")
        mockDecoder.setTag(DicomTag.modality.rawValue, value: "")     // Empty - should fallback
        mockDecoder.setTag(DicomTag.studyDate.rawValue, value: "")    // Empty - should fallback
        mockDecoder.setTag(DicomTag.patientAge.rawValue, value: "")   // Empty - should fallback
        mockDecoder.setTag(DicomTag.institutionName.rawValue, value: "")  // Empty - should fallback

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        let metadata = await service.extractStudyMetadata(from: "/test/mock.dcm")

        XCTAssertNotNil(metadata, "Should extract metadata with fallback values")
        XCTAssertEqual(metadata?.patientName, "Unknown Patient", "Should use fallback for empty patient name")
        XCTAssertEqual(metadata?.patientID, "Unknown ID", "Should use fallback for empty patient ID")
        XCTAssertEqual(metadata?.modality, "OT", "Should use fallback for empty modality")
        XCTAssertEqual(metadata?.studyDate, "Unknown Date", "Should use fallback for empty study date")
        XCTAssertEqual(metadata?.patientAge, "Unknown", "Should use fallback for empty patient age")
        XCTAssertEqual(metadata?.institutionName, "Unknown Location", "Should use fallback for empty institution")
    }

    func testBatchMetadataExtractionUsesInjectedDecoder() async {
        // Create mock decoder with test data
        let mockDecoder = MockDicomDecoder()
        mockDecoder.setTag(DicomTag.patientName.rawValue, value: "Batch Patient")
        mockDecoder.setTag(DicomTag.patientID.rawValue, value: "BATCH001")
        mockDecoder.setTag(DicomTag.studyInstanceUID.rawValue, value: "1.2.3.4.5")
        mockDecoder.setTag(DicomTag.seriesInstanceUID.rawValue, value: "1.2.3.4.5.6")
        mockDecoder.setTag(DicomTag.modality.rawValue, value: "MR")
        mockDecoder.setTag(DicomTag.instanceNumber.rawValue, value: "1")

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        let filePaths = [
            "/test/file1.dcm",
            "/test/file2.dcm",
            "/test/file3.dcm"
        ]

        let metadata = await service.extractBatchMetadata(from: filePaths)

        XCTAssertEqual(metadata.count, 3, "Should extract metadata for all files")
        for meta in metadata {
            XCTAssertEqual(meta.patientName, "Batch Patient", "Should use mock patient name")
            XCTAssertEqual(meta.patientID, "BATCH001", "Should use mock patient ID")
            XCTAssertEqual(meta.modality, "MR", "Should use mock modality")
        }
    }

    func testScanDICOMFilesUsesContentValidationInsteadOfExtension() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan_dicom_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let extensionlessURL = directoryURL.appendingPathComponent("slice_without_extension")
        let alternateExtensionURL = directoryURL.appendingPathComponent("slice.payload")
        let invalidDcmURL = directoryURL.appendingPathComponent("not_dicom.dcm")

        for url in [extensionlessURL, alternateExtensionURL, invalidDcmURL] {
            try Data([0x01, 0x02, 0x03]).write(to: url)
        }

        let validFilenames = Set([extensionlessURL.lastPathComponent, alternateExtensionURL.lastPathComponent])
        let service = StudyDataService(decoderFactory: { path in
            guard validFilenames.contains(URL(fileURLWithPath: path).lastPathComponent) else {
                throw DICOMError.invalidDICOMFormat(reason: "Test decoder rejected file")
            }

            let mockDecoder = MockDicomDecoder()
            mockDecoder.setTag(DicomTag.studyInstanceUID.rawValue, value: "1.2.3")
            mockDecoder.setTag(DicomTag.seriesInstanceUID.rawValue, value: "1.2.3.4")
            return mockDecoder
        })

        let discoveredPaths = try await service.scanDICOMFiles(in: directoryURL.path)

        XCTAssertEqual(Set(discoveredPaths.map { URL(fileURLWithPath: $0).lastPathComponent }), validFilenames)
    }

    func testScanDICOMFilesWithMetadataUsesInjectedBatchLoader() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan_metadata_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let validURL = directoryURL.appendingPathComponent("valid_dicom")
        let invalidURL = directoryURL.appendingPathComponent("invalid_dicom")
        try Data([0x01]).write(to: validURL)
        try Data([0x02]).write(to: invalidURL)

        let decoder = MockDicomDecoder()
        decoder.setTag(DicomTag.patientName.rawValue, value: "Batch Loader Patient")
        decoder.setTag(DicomTag.patientID.rawValue, value: "BATCH-LOADER")
        decoder.setTag(DicomTag.studyInstanceUID.rawValue, value: "1.2.3")
        decoder.setTag(DicomTag.seriesInstanceUID.rawValue, value: "1.2.3.4")
        decoder.setTag(DicomTag.instanceNumber.rawValue, value: "7")

        let loader = MockBatchFileLoader()
        loader.resultsByLastPathComponent = [
            validURL.lastPathComponent: DicomFileResult(url: validURL, decoder: decoder),
            invalidURL.lastPathComponent: DicomFileResult(
                url: invalidURL,
                error: DICOMError.invalidDICOMFormat(reason: "Rejected by mock loader")
            )
        ]

        let service = StudyDataService(
            decoderFactory: { _ in
                XCTFail("scanDICOMFilesWithMetadata should reuse batch loader decoders")
                throw DICOMError.invalidDICOMFormat(reason: "Unexpected decoderFactory call")
            },
            seriesLoaderFactory: { loader }
        )

        let metadata = try await service.scanDICOMFilesWithMetadata(in: directoryURL.path)

        XCTAssertEqual(Set(loader.loadedURLs.map(\.lastPathComponent)), Set([validURL.lastPathComponent, invalidURL.lastPathComponent]))
        XCTAssertEqual(metadata.count, 1)
        XCTAssertEqual(metadata.first.map { URL(fileURLWithPath: $0.filePath).lastPathComponent }, validURL.lastPathComponent)
        XCTAssertEqual(metadata.first?.patientName, "Batch Loader Patient")
        XCTAssertEqual(metadata.first?.instanceNumber, 7)
        XCTAssertEqual(metadata.first?.fileSize, 1)
    }

    func testServiceWithDifferentModalitiesFromMockDecoder() async {
        let modalities = ["CT", "MR", "DX", "CR", "US", "MG", "PT", "NM"]

        for modality in modalities {
            let mockDecoder = MockDicomDecoder()
            mockDecoder.setTag(DicomTag.patientName.rawValue, value: "Test Patient")
            mockDecoder.setTag(DicomTag.patientID.rawValue, value: "PAT001")
            mockDecoder.setTag(DicomTag.studyInstanceUID.rawValue, value: "1.2.3.4.5")
            mockDecoder.setTag(DicomTag.seriesInstanceUID.rawValue, value: "1.2.3.4.5.6")
            mockDecoder.setTag(DicomTag.modality.rawValue, value: modality)

            let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

            let metadata = await service.extractStudyMetadata(from: "/test/\(modality).dcm")

            XCTAssertNotNil(metadata, "Should extract metadata for \(modality)")
            XCTAssertEqual(metadata?.modality, modality, "Should preserve \(modality) modality")
        }
    }

    func testServicePreservesInstanceNumberFromMockDecoder() async {
        let testInstanceNumbers = [1, 5, 10, 42, 100]

        for instanceNumber in testInstanceNumbers {
            let mockDecoder = MockDicomDecoder()
            mockDecoder.setTag(DicomTag.studyInstanceUID.rawValue, value: "1.2.3.4.5")
            mockDecoder.setTag(DicomTag.seriesInstanceUID.rawValue, value: "1.2.3.4.5.6")
            mockDecoder.setTag(DicomTag.instanceNumber.rawValue, value: "\(instanceNumber)")

            let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

            let metadata = await service.extractStudyMetadata(from: "/test/instance\(instanceNumber).dcm")

            XCTAssertNotNil(metadata, "Should extract metadata for instance \(instanceNumber)")
            XCTAssertEqual(metadata?.instanceNumber, instanceNumber, "Should preserve instance number \(instanceNumber)")
        }
    }

    // MARK: - StudyMetadata Structure Tests

    func testStudyMetadataCreation() {
        let metadata = StudyMetadata(
            filePath: "/test/path.dcm",
            patientName: "Test Patient",
            patientID: "PAT001",
            patientSex: "M",
            patientAge: "045Y",
            studyInstanceUID: "1.2.3.4.5",
            studyDate: "20240101",
            studyDescription: "CT Chest",
            seriesInstanceUID: "1.2.3.4.5.6",
            modality: "CT",
            instanceNumber: 1,
            bodyPartExamined: "CHEST",
            institutionName: "General Hospital"
        )

        XCTAssertEqual(metadata.filePath, "/test/path.dcm", "File path should match")
        XCTAssertEqual(metadata.patientName, "Test Patient", "Patient name should match")
        XCTAssertEqual(metadata.patientID, "PAT001", "Patient ID should match")
        XCTAssertEqual(metadata.patientSex, "M", "Patient sex should match")
        XCTAssertEqual(metadata.patientAge, "045Y", "Patient age should match")
        XCTAssertEqual(metadata.studyInstanceUID, "1.2.3.4.5", "Study UID should match")
        XCTAssertEqual(metadata.studyDate, "20240101", "Study date should match")
        XCTAssertEqual(metadata.studyDescription, "CT Chest", "Study description should match")
        XCTAssertEqual(metadata.seriesInstanceUID, "1.2.3.4.5.6", "Series UID should match")
        XCTAssertEqual(metadata.modality, "CT", "Modality should match")
        XCTAssertEqual(metadata.instanceNumber, 1, "Instance number should match")
        XCTAssertEqual(metadata.bodyPartExamined, "CHEST", "Body part should match")
        XCTAssertEqual(metadata.institutionName, "General Hospital", "Institution should match")
    }

    // MARK: - DICOMValidationResult Tests

    func testValidationResultValid() {
        let result = DICOMValidationResult(
            isValid: true,
            issues: [],
            fileSize: 1024000
        )

        XCTAssertTrue(result.isValid, "Result should be valid")
        XCTAssertTrue(result.issues.isEmpty, "Should have no issues")
        XCTAssertEqual(result.fileSize, 1024000, "File size should match")
        XCTAssertTrue(result.summary.contains("Valid"), "Summary should indicate valid file")
    }

    func testValidationResultInvalid() {
        let result = DICOMValidationResult(
            isValid: false,
            issues: ["Missing DICOM header signature", "File too small"],
            fileSize: 100
        )

        XCTAssertFalse(result.isValid, "Result should be invalid")
        XCTAssertEqual(result.issues.count, 2, "Should have two issues")
        XCTAssertTrue(result.summary.contains("Invalid"), "Summary should indicate invalid file")
        XCTAssertTrue(result.summary.contains("Missing DICOM header signature"), "Summary should include first issue")
    }

    func testValidationResultSummaryFormatting() {
        let validResult = DICOMValidationResult(
            isValid: true,
            issues: [],
            fileSize: 2048000
        )

        let summary = validResult.summary
        XCTAssertTrue(summary.contains("✅"), "Valid result should have checkmark")

        let invalidResult = DICOMValidationResult(
            isValid: false,
            issues: ["Test issue"],
            fileSize: 100
        )

        let invalidSummary = invalidResult.summary
        XCTAssertTrue(invalidSummary.contains("❌"), "Invalid result should have X mark")
        XCTAssertTrue(invalidSummary.contains("Test issue"), "Should include issue description")
    }

    // MARK: - Patient Model Creation Tests

    func testCreatePatientModel() {
        let service = StudyDataService(decoderFactory: makeDecoderFactory())
        let metadata = StudyMetadata(
            filePath: "/test/path.dcm",
            patientName: "John Doe",
            patientID: "PAT123",
            patientSex: "M",
            patientAge: "030Y",
            studyInstanceUID: "1.2.840.113619.2.1",
            studyDate: "20240115",
            studyDescription: "Brain MRI",
            seriesInstanceUID: "1.2.840.113619.2.1.1",
            modality: "MR",
            instanceNumber: 5,
            bodyPartExamined: "BRAIN",
            institutionName: "University Hospital"
        )

        let patientModel = service.createPatientModel(from: metadata)

        XCTAssertEqual(patientModel.patientName, "John Doe", "Patient name should match")
        XCTAssertEqual(patientModel.patientID, "PAT123", "Patient ID should match")
        XCTAssertEqual(patientModel.studyInstanceUID, "1.2.840.113619.2.1", "Study UID should match")
        XCTAssertEqual(patientModel.modality, DICOMModality.mr, "Modality should be MR")
    }

    func testCreatePatientModelWithUnknownModality() {
        let service = StudyDataService(decoderFactory: makeDecoderFactory())
        let metadata = StudyMetadata(
            filePath: "/test/path.dcm",
            patientName: "Jane Doe",
            patientID: "PAT456",
            patientSex: "F",
            patientAge: "025Y",
            studyInstanceUID: "1.2.3.4.5",
            studyDate: "20240115",
            studyDescription: "Test Study",
            seriesInstanceUID: "1.2.3.4.5.6",
            modality: "UNKNOWN_MODALITY",
            instanceNumber: 1,
            bodyPartExamined: "CHEST",
            institutionName: "Test Hospital"
        )

        let patientModel = service.createPatientModel(from: metadata)

        XCTAssertEqual(patientModel.modality, .unknown, "Unknown modality should map to .unknown")
    }

    func testCreatePatientModelWithKnownModalities() {
        let service = StudyDataService(decoderFactory: makeDecoderFactory())
        let testCases: [(String, DICOMModality)] = [
            ("CT", .ct),
            ("MR", .mr),
            ("DX", .dx),
            ("CR", .cr),
            ("US", .us),
            ("MG", .mg),
            ("PT", .pt),
            ("NM", .nm)
        ]

        for (modalityString, expectedModality) in testCases {
            let metadata = StudyMetadata(
                filePath: "/test/path.dcm",
                patientName: "Test Patient",
                patientID: "PAT001",
                patientSex: "M",
                patientAge: "040Y",
                studyInstanceUID: "1.2.3.4.5",
                studyDate: "20240115",
                studyDescription: "Test",
                seriesInstanceUID: "1.2.3.4.5.6",
                modality: modalityString,
                instanceNumber: 1,
                bodyPartExamined: "CHEST",
                institutionName: "Hospital"
            )

            let patientModel = service.createPatientModel(from: metadata)
            XCTAssertEqual(
                patientModel.modality,
                expectedModality,
                "\(modalityString) should map to \(expectedModality)"
            )
        }
    }

    // MARK: - Study Grouping Tests

    func testGroupStudiesByUID() {
        let service = StudyDataService(decoderFactory: makeDecoderFactory())

        let metadata1 = createTestMetadata(studyUID: "1.2.3", seriesUID: "1.2.3.1", instanceNumber: 1)
        let metadata2 = createTestMetadata(studyUID: "1.2.3", seriesUID: "1.2.3.2", instanceNumber: 2)
        let metadata3 = createTestMetadata(studyUID: "4.5.6", seriesUID: "4.5.6.1", instanceNumber: 1)

        let grouped = service.groupStudiesByUID([metadata1, metadata2, metadata3])

        XCTAssertEqual(grouped.count, 2, "Should have 2 unique studies")
        XCTAssertEqual(grouped["1.2.3"]?.count, 2, "Study 1.2.3 should have 2 files")
        XCTAssertEqual(grouped["4.5.6"]?.count, 1, "Study 4.5.6 should have 1 file")
    }

    func testGroupStudiesByUIDEmptyArray() {
        let service = StudyDataService(decoderFactory: makeDecoderFactory())
        let grouped = service.groupStudiesByUID([])

        XCTAssertTrue(grouped.isEmpty, "Grouping empty array should return empty dictionary")
    }

    func testGroupStudiesByUIDSingleStudy() {
        let service = StudyDataService(decoderFactory: makeDecoderFactory())

        let metadata1 = createTestMetadata(studyUID: "1.2.3", seriesUID: "1.2.3.1", instanceNumber: 1)
        let metadata2 = createTestMetadata(studyUID: "1.2.3", seriesUID: "1.2.3.1", instanceNumber: 2)
        let metadata3 = createTestMetadata(studyUID: "1.2.3", seriesUID: "1.2.3.1", instanceNumber: 3)

        let grouped = service.groupStudiesByUID([metadata1, metadata2, metadata3])

        XCTAssertEqual(grouped.count, 1, "Should have 1 unique study")
        XCTAssertEqual(grouped["1.2.3"]?.count, 3, "Study should have 3 files")
    }

    func testGroupStudiesByUIDMultipleSeries() {
        let service = StudyDataService(decoderFactory: makeDecoderFactory())

        // Same study, different series
        let metadata1 = createTestMetadata(studyUID: "1.2.3", seriesUID: "1.2.3.1", instanceNumber: 1)
        let metadata2 = createTestMetadata(studyUID: "1.2.3", seriesUID: "1.2.3.2", instanceNumber: 1)
        let metadata3 = createTestMetadata(studyUID: "1.2.3", seriesUID: "1.2.3.3", instanceNumber: 1)

        let grouped = service.groupStudiesByUID([metadata1, metadata2, metadata3])

        XCTAssertEqual(grouped.count, 1, "Should have 1 unique study")
        XCTAssertEqual(grouped["1.2.3"]?.count, 3, "Study should have 3 files from different series")

        // Verify all series UIDs are different
        let seriesUIDs = Set(grouped["1.2.3"]!.map { $0.seriesInstanceUID })
        XCTAssertEqual(seriesUIDs.count, 3, "Should have 3 unique series")
    }

    // MARK: - Validation Tests

    func testValidateDICOMFileNonExistent() async {
        let service = StudyDataService(decoderFactory: makeDecoderFactory())
        let nonExistentPath = "/tmp/nonexistent_\(UUID().uuidString).dcm"

        let result = await service.validateDICOMFile(nonExistentPath)

        XCTAssertFalse(result.isValid, "Non-existent file should be invalid")
        XCTAssertTrue(result.issues.contains("File does not exist"), "Should report file not found")
        XCTAssertEqual(result.fileSize, 0, "File size should be 0 for non-existent file")
    }

    func testValidateDICOMFileUsesLightweightHeaderReadForLargeFiles() async throws {
        let mockDecoder = MockDicomDecoder()
        mockDecoder.setTag(DicomTag.studyInstanceUID.rawValue, value: "1.2.3.4.5")
        mockDecoder.setTag(DicomTag.seriesInstanceUID.rawValue, value: "1.2.3.4.5.6")
        mockDecoder.dicomFound = true

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))
        let tempPath = NSTemporaryDirectory() + "test_large_validation_\(UUID().uuidString).dcm"
        let tempURL = URL(fileURLWithPath: tempPath)
        let largeFileSize = 16 * 1024 * 1024
        var testData = Data(repeating: 0, count: largeFileSize)
        testData.replaceSubrange(128..<132, with: Data([0x44, 0x49, 0x43, 0x4D]))

        try testData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let start = Date()
        let result = await service.validateDICOMFile(tempPath)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(result.isValid, "Large file should validate with mock decoder")
        XCTAssertTrue(result.issues.isEmpty, "Valid DICM signature should not produce header issues")
        XCTAssertEqual(result.fileSize, UInt64(largeFileSize), "Validation should preserve reported file size")
        XCTAssertLessThan(elapsed, 0.1, "Header validation should not scale with full file size")
    }

    // MARK: - Batch Validation Tests

    func testValidateBatchDICOMFilesWithValidFiles() async {
        // Create mock decoder with valid DICOM data
        let mockDecoder = MockDicomDecoder()
        mockDecoder.setTag(DicomTag.studyInstanceUID.rawValue, value: "1.2.3.4.5")
        mockDecoder.setTag(DicomTag.seriesInstanceUID.rawValue, value: "1.2.3.4.5.6")
        mockDecoder.dicomFound = true
        // Mock decoder configured as valid

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        // Create temporary files for validation test
        let tempPaths = (1...3).map { _ in NSTemporaryDirectory() + "test_batch_\(UUID().uuidString).dcm" }
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

        for path in tempPaths {
            try? testData.write(to: URL(fileURLWithPath: path))
        }
        defer {
            for path in tempPaths {
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        let results = await service.validateBatchDICOMFiles(tempPaths)

        XCTAssertEqual(results.count, 3, "Should validate all 3 files")
        for result in results {
            XCTAssertTrue(result.isValid, "All files should be valid with mock decoder")
            XCTAssertTrue(result.issues.isEmpty, "Valid files should have no issues")
        }
    }

    func testValidateBatchDICOMFilesWithNonExistentFiles() async {
        let service = StudyDataService(decoderFactory: makeDecoderFactory())
        let nonExistentPaths = [
            "/tmp/nonexistent1_\(UUID().uuidString).dcm",
            "/tmp/nonexistent2_\(UUID().uuidString).dcm",
            "/tmp/nonexistent3_\(UUID().uuidString).dcm"
        ]

        let results = await service.validateBatchDICOMFiles(nonExistentPaths)

        XCTAssertEqual(results.count, 3, "Should return results for all files")
        for result in results {
            XCTAssertFalse(result.isValid, "Non-existent files should be invalid")
            XCTAssertTrue(result.issues.contains("File does not exist"), "Should report file not found")
            XCTAssertEqual(result.fileSize, 0, "File size should be 0 for non-existent files")
        }
    }

    func testValidateBatchDICOMFilesWithMixedFiles() async {
        // Create mock decoder with valid DICOM data
        let mockDecoder = MockDicomDecoder()
        mockDecoder.setTag(DicomTag.studyInstanceUID.rawValue, value: "1.2.3.4.5")
        mockDecoder.setTag(DicomTag.seriesInstanceUID.rawValue, value: "1.2.3.4.5.6")
        mockDecoder.dicomFound = true
        // Mock decoder configured as valid

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        // Create one temporary file
        let validPath = NSTemporaryDirectory() + "test_valid_\(UUID().uuidString).dcm"
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

        try? testData.write(to: URL(fileURLWithPath: validPath))
        defer { try? FileManager.default.removeItem(atPath: validPath) }

        // Mix with non-existent files
        let mixedPaths = [
            validPath,
            "/tmp/nonexistent_\(UUID().uuidString).dcm",
            "/tmp/another_nonexistent_\(UUID().uuidString).dcm"
        ]

        let results = await service.validateBatchDICOMFiles(mixedPaths)

        XCTAssertEqual(results.count, 3, "Should return results for all files")

        let validCount = results.filter { $0.isValid }.count
        let invalidCount = results.filter { !$0.isValid }.count

        XCTAssertEqual(validCount, 1, "Should have 1 valid file")
        XCTAssertEqual(invalidCount, 2, "Should have 2 invalid files")
    }

    func testValidateBatchDICOMFilesWithEmptyArray() async {
        let service = StudyDataService(decoderFactory: makeDecoderFactory())

        let results = await service.validateBatchDICOMFiles([])

        XCTAssertTrue(results.isEmpty, "Batch validation with empty input should return empty array")
    }

    func testValidateBatchDICOMFilesWithInvalidDecoder() async {
        // Create mock decoder with invalid DICOM data (missing UIDs)
        let mockDecoder = MockDicomDecoder()
        mockDecoder.dicomFound = false
        // Mock decoder configured as invalid

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        // Create temporary files
        let tempPaths = (1...2).map { _ in NSTemporaryDirectory() + "test_invalid_\(UUID().uuidString).dcm" }
        let testData = Data([0x00, 0x01, 0x02, 0x03])  // Invalid DICOM data

        for path in tempPaths {
            try? testData.write(to: URL(fileURLWithPath: path))
        }
        defer {
            for path in tempPaths {
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        let results = await service.validateBatchDICOMFiles(tempPaths)

        XCTAssertEqual(results.count, 2, "Should return results for all files")
        for result in results {
            XCTAssertFalse(result.isValid, "Files with invalid decoder should be invalid")
            XCTAssertFalse(result.issues.isEmpty, "Invalid files should have issues")
        }
    }

    func testValidateBatchDICOMFilesWithMissingUIDs() async {
        // Create mock decoder with valid read but missing required UIDs
        let mockDecoder = MockDicomDecoder()
        mockDecoder.dicomFound = true
        // Mock decoder configured as valid
        // Intentionally omit studyInstanceUID and seriesInstanceUID

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        // Create temporary file
        let tempPath = NSTemporaryDirectory() + "test_missing_uids_\(UUID().uuidString).dcm"
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

        let results = await service.validateBatchDICOMFiles([tempPath])

        XCTAssertEqual(results.count, 1, "Should return result for the file")
        XCTAssertFalse(results[0].isValid, "File without UIDs should be invalid")
        XCTAssertTrue(results[0].issues.contains { $0.contains("UID") }, "Should report missing UID issue")
    }

    func testValidateBatchDICOMFilesConcurrentExecution() async {
        // Create mock decoder with valid DICOM data
        let mockDecoder = MockDicomDecoder()
        mockDecoder.setTag(DicomTag.studyInstanceUID.rawValue, value: "1.2.3.4.5")
        mockDecoder.setTag(DicomTag.seriesInstanceUID.rawValue, value: "1.2.3.4.5.6")
        mockDecoder.dicomFound = true
        // Mock decoder configured as valid

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        // Create multiple temporary files to test concurrent execution
        let tempPaths = (1...10).map { _ in NSTemporaryDirectory() + "test_concurrent_\(UUID().uuidString).dcm" }
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

        for path in tempPaths {
            try? testData.write(to: URL(fileURLWithPath: path))
        }
        defer {
            for path in tempPaths {
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        let results = await service.validateBatchDICOMFiles(tempPaths)

        XCTAssertEqual(results.count, 10, "Should validate all 10 files")
        for result in results {
            XCTAssertTrue(result.isValid, "All files should be valid")
        }
    }

    // MARK: - Metadata Extraction Tests

    func testExtractStudyMetadataAsync() async {
        // Note: This test requires actual DICOM files to work properly
        // For now, we test the async interface and expected behavior with invalid file
        let service = StudyDataService(decoderFactory: makeDecoderFactory())
        let invalidPath = "/tmp/invalid_\(UUID().uuidString).dcm"

        let metadata = await service.extractStudyMetadata(from: invalidPath)

        // Invalid file should return nil due to missing UIDs
        XCTAssertNil(metadata, "Invalid DICOM file should return nil metadata")
    }

    func testExtractBatchMetadataAsync() async {
        let service = StudyDataService(decoderFactory: makeDecoderFactory())
        let invalidPaths = [
            "/tmp/invalid1_\(UUID().uuidString).dcm",
            "/tmp/invalid2_\(UUID().uuidString).dcm",
            "/tmp/invalid3_\(UUID().uuidString).dcm"
        ]

        let metadata = await service.extractBatchMetadata(from: invalidPaths)

        // Invalid files should return empty array
        XCTAssertTrue(metadata.isEmpty, "Batch extraction of invalid files should return empty array")
    }

    func testExtractBatchMetadataEmptyArray() async {
        let service = StudyDataService(decoderFactory: makeDecoderFactory())

        let metadata = await service.extractBatchMetadata(from: [])

        XCTAssertTrue(metadata.isEmpty, "Batch extraction with empty input should return empty array")
    }

    // MARK: - Thumbnail Extraction Tests

    func testExtractThumbnailAsync() async {
        let service = StudyDataService(decoderFactory: makeDecoderFactory())
        let invalidPath = "/tmp/invalid_\(UUID().uuidString).dcm"

        let thumbnail = await service.extractThumbnail(from: invalidPath)

        // Invalid file should return nil thumbnail
        XCTAssertNil(thumbnail, "Thumbnail extraction from invalid file should return nil")
    }

    func testExtractThumbnailWithCustomSize() async {
        let service = StudyDataService(decoderFactory: makeDecoderFactory())
        let invalidPath = "/tmp/invalid_\(UUID().uuidString).dcm"
        let customSize = CGSize(width: 256, height: 256)

        let thumbnail = await service.extractThumbnail(from: invalidPath, maxSize: customSize)

        // Invalid file should return nil thumbnail regardless of size
        XCTAssertNil(thumbnail, "Thumbnail extraction from invalid file should return nil")
    }

    func testExtractThumbnailRejectsNonPositiveSize() async {
        let mockDecoder = MockDicomDecoder()
        mockDecoder.width = 512
        mockDecoder.height = 512
        mockDecoder.setDownsampledPixels16([UInt16](repeating: 1000, count: 4), width: 2, height: 2)

        let service = StudyDataService(decoderFactory: makeMockDecoderFactory(mock: mockDecoder))

        let zeroSizeThumbnail = await service.extractThumbnail(
            from: "/test/mock.dcm",
            maxSize: CGSize(width: 0, height: 0)
        )
        let negativeSizeThumbnail = await service.extractThumbnail(
            from: "/test/mock.dcm",
            maxSize: CGSize(width: -120, height: -80)
        )

        XCTAssertNil(zeroSizeThumbnail, "Thumbnail extraction should reject zero max size")
        XCTAssertNil(negativeSizeThumbnail, "Thumbnail extraction should reject negative max size")
    }

    // MARK: - Edge Cases and Error Handling Tests

    func testStudyMetadataWithEmptyValues() {
        // Test that metadata can handle empty values properly
        let metadata = StudyMetadata(
            filePath: "",
            patientName: "",
            patientID: "",
            patientSex: "",
            patientAge: "",
            studyInstanceUID: "1.2.3.4.5",
            studyDate: "",
            studyDescription: "",
            seriesInstanceUID: "1.2.3.4.5.6",
            modality: "",
            instanceNumber: 0,
            bodyPartExamined: "",
            institutionName: ""
        )

        XCTAssertEqual(metadata.patientName, "", "Empty patient name should be preserved")
        XCTAssertEqual(metadata.modality, "", "Empty modality should be preserved")
        XCTAssertEqual(metadata.instanceNumber, 0, "Zero instance number should be preserved")
    }

    func testStudyMetadataWithSpecialCharacters() {
        let metadata = StudyMetadata(
            filePath: "/test/path with spaces/file.dcm",
            patientName: "Müller, José^María",
            patientID: "PAT-001-α",
            patientSex: "M",
            patientAge: "045Y",
            studyInstanceUID: "1.2.840.113619.2.1",
            studyDate: "20240115",
            studyDescription: "Study with special chars: <>\"'&",
            seriesInstanceUID: "1.2.840.113619.2.1.1",
            modality: "CT",
            instanceNumber: 1,
            bodyPartExamined: "CHEST",
            institutionName: "Hôpital Général"
        )

        XCTAssertEqual(metadata.patientName, "Müller, José^María", "Special characters should be preserved")
        XCTAssertEqual(metadata.institutionName, "Hôpital Général", "Unicode characters should be preserved")
        XCTAssertTrue(metadata.studyDescription.contains("&"), "Special XML characters should be preserved")
    }

    func testGroupStudiesPreservesInstanceOrdering() {
        let service = StudyDataService(decoderFactory: makeDecoderFactory())

        let metadata1 = createTestMetadata(studyUID: "1.2.3", seriesUID: "1.2.3.1", instanceNumber: 5)
        let metadata2 = createTestMetadata(studyUID: "1.2.3", seriesUID: "1.2.3.1", instanceNumber: 2)
        let metadata3 = createTestMetadata(studyUID: "1.2.3", seriesUID: "1.2.3.1", instanceNumber: 8)

        let grouped = service.groupStudiesByUID([metadata1, metadata2, metadata3])

        XCTAssertEqual(grouped["1.2.3"]?.count, 3, "Should preserve all instances")

        // Verify instance numbers are preserved
        let instanceNumbers = grouped["1.2.3"]!.map { $0.instanceNumber }
        XCTAssertTrue(instanceNumbers.contains(5), "Should contain instance 5")
        XCTAssertTrue(instanceNumbers.contains(2), "Should contain instance 2")
        XCTAssertTrue(instanceNumbers.contains(8), "Should contain instance 8")
    }

    // MARK: - Integration Tests

    func testCompleteWorkflow() {
        let service = StudyDataService(decoderFactory: makeDecoderFactory())

        // Create sample metadata
        let metadata1 = createTestMetadata(studyUID: "Study1", seriesUID: "Series1", instanceNumber: 1)
        let metadata2 = createTestMetadata(studyUID: "Study1", seriesUID: "Series1", instanceNumber: 2)
        let metadata3 = createTestMetadata(studyUID: "Study2", seriesUID: "Series2", instanceNumber: 1)

        // Group studies
        let grouped = service.groupStudiesByUID([metadata1, metadata2, metadata3])

        XCTAssertEqual(grouped.count, 2, "Should have 2 studies")

        // Create patient models from first study
        if let study1Files = grouped["Study1"] {
            let patientModels = study1Files.map { service.createPatientModel(from: $0) }
            XCTAssertEqual(patientModels.count, 2, "Should create 2 patient models")
            XCTAssertEqual(patientModels[0].studyInstanceUID, "Study1", "Study UID should match")
        } else {
            XCTFail("Study1 should exist in grouped results")
        }
    }

    func testPatientModelDisplayProperties() {
        let service = StudyDataService(decoderFactory: makeDecoderFactory())
        let metadata = createTestMetadata(
            studyUID: "1.2.3.4.5",
            seriesUID: "1.2.3.4.5.6",
            instanceNumber: 1,
            patientName: "Test^Patient",
            modality: "CT"
        )

        let patientModel = service.createPatientModel(from: metadata)

        XCTAssertFalse(patientModel.displayName.isEmpty, "Display name should not be empty")
        XCTAssertNotNil(patientModel.modality, "Modality should be set")
        XCTAssertEqual(patientModel.modality, DICOMModality.ct, "Modality should be CT")
    }

    // MARK: - Helper Methods

    private func createTestMetadata(
        studyUID: String,
        seriesUID: String,
        instanceNumber: Int,
        patientName: String = "Test Patient",
        modality: String = "CT"
    ) -> StudyMetadata {
        return StudyMetadata(
            filePath: "/test/file_\(instanceNumber).dcm",
            patientName: patientName,
            patientID: "PAT001",
            patientSex: "M",
            patientAge: "045Y",
            studyInstanceUID: studyUID,
            studyDate: "20240115",
            studyDescription: "Test Study",
            seriesInstanceUID: seriesUID,
            modality: modality,
            instanceNumber: instanceNumber,
            bodyPartExamined: "CHEST",
            institutionName: "Test Hospital"
        )
    }
}
