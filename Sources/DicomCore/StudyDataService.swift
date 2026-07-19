//
//  StudyDataService.swift
//
//  DICOM data processing service for study metadata extraction and validation
//  Handles low-level DICOM file operations and metadata parsing
//

import Foundation
import OSLog
import CoreGraphics
import ImageIO

// MARK: - Study Data Service

/// DICOM study metadata extraction and validation service.
///
/// ## Overview
///
/// ``StudyDataService`` provides high-level operations for extracting and validating DICOM
/// study metadata from files and directories. It handles concurrent metadata extraction,
/// file validation, and provides structured data models for patient, study, and series information.
///
/// The service uses protocol-based dependency injection for ``DicomDecoderProtocol``,
/// enabling testability and customization. All operations are async and leverage Swift
/// concurrency for optimal performance when processing multiple files.
///
/// **Key Features:**
/// - Concurrent metadata extraction from multiple files
/// - DICOM file format validation
/// - Structured metadata models with proper fallbacks
/// - Study grouping and organization
/// - Logging support via ``LoggerProtocol``
/// - Thread-safe operations
///
/// ## Usage
///
/// Extract metadata from a single file:
///
/// ```swift
/// let service = StudyDataService(decoderFactory: { path in try DCMDecoder(contentsOfFile: path) })
/// if let metadata = await service.extractStudyMetadata(from: filePath) {
///     print("Patient: \(metadata.patientName)")
///     print("Study: \(metadata.studyDescription)")
///     print("Modality: \(metadata.modality)")
/// }
/// ```
///
/// Batch extract metadata from multiple files:
///
/// ```swift
/// let filePaths = ["file1.dcm", "file2.dcm", "file3.dcm"]
/// let allMetadata = await service.extractBatchMetadata(from: filePaths)
/// print("Extracted \(allMetadata.count) metadata records")
/// ```
///
/// Validate DICOM file integrity:
///
/// ```swift
/// let result = await service.validateDICOMFile(filePath)
/// if result.isValid {
///     print("Valid DICOM file (\(result.fileSize) bytes)")
/// } else {
///     print("Invalid DICOM: \(result.issues.joined(separator: ", "))")
/// }
/// ```
///
/// Batch validate multiple files:
///
/// ```swift
/// let filePaths = ["file1.dcm", "file2.dcm", "file3.dcm"]
/// let results = await service.validateBatchDICOMFiles(filePaths)
/// let validCount = results.filter { $0.isValid }.count
/// print("Valid: \(validCount)/\(results.count) files")
/// ```
///
/// Group studies by UID:
///
/// ```swift
/// let metadata = await service.extractBatchMetadata(from: filePaths)
/// let grouped = service.groupStudiesByUID(metadata)
/// for (studyUID, files) in grouped {
///     print("Study \(studyUID): \(files.count) files")
/// }
/// ```
///
/// ## Topics
///
/// ### Creating a Service
///
/// - ``init(fileManager:decoderFactory:)``
///
/// ### Metadata Extraction
///
/// - ``extractStudyMetadata(from:)``
/// - ``extractBatchMetadata(from:)``
/// - ``extractThumbnail(from:maxSize:)``
///
/// ### File Validation
///
/// - ``validateDICOMFile(_:)``
/// - ``validateBatchDICOMFiles(_:)``
///
/// ### Study Organization
///
/// - ``groupStudiesByUID(_:)``
/// - ``createPatientModel(from:)``
///
/// ### Supporting Types
///
/// - ``StudyMetadata``
/// - ``DICOMValidationResult``
///
public final class StudyDataService: StudyDataServiceProtocol, @unchecked Sendable {

    // MARK: - Properties

    private let logger: LoggerProtocol
    private let fileManager: FileManager
    private let decoderFactory: (String) throws -> DicomDecoderProtocol
    private let seriesLoaderFactory: () -> any DicomBatchFileLoading

    // MARK: - Initialization

    /// Creates a new DICOM study data service.
    ///
    /// - Parameters:
    ///   - fileManager: File system manager (defaults to `.default`)
    ///   - decoderFactory: Factory closure that creates ``DicomDecoderProtocol`` instances from a file path
    ///
    /// ## Example
    /// ```swift
    /// // Use default decoder
    /// let service = StudyDataService(decoderFactory: { path in try DCMDecoder(contentsOfFile: path) })
    ///
    /// // Use custom decoder for testing
    /// let mockDecoder = MockDicomDecoder()
    /// let testService = StudyDataService(decoderFactory: { _ in mockDecoder })
    /// ```
    public init(
        fileManager: FileManager = .default,
        decoderFactory: @escaping (String) throws -> DicomDecoderProtocol,
        seriesLoaderFactory: (() -> any DicomBatchFileLoading)? = nil
    ) {
        self.fileManager = fileManager
        self.decoderFactory = decoderFactory
        self.seriesLoaderFactory = seriesLoaderFactory ?? {
            DicomSeriesLoader(decoderFactory: decoderFactory)
        }
        self.logger = DicomLogger.make(subsystem: "com.dicomviewer", category: "StudyData")
        logger.info("🔬 StudyDataService initialized")
    }

    // MARK: - Public Interface

    /// Extracts comprehensive study metadata from a DICOM file.
    ///
    /// This method asynchronously reads and parses DICOM metadata including patient information,
    /// study details, series information, and modality data. It provides proper fallback values
    /// for missing or empty DICOM tags.
    ///
    /// - Parameter filePath: Absolute path to the DICOM file
    /// - Returns: ``StudyMetadata`` if the file is valid, `nil` if essential UIDs are missing
    ///
    /// ## Example
    /// ```swift
    /// if let metadata = await service.extractStudyMetadata(from: "/path/to/image.dcm") {
    ///     print("Patient: \(metadata.patientName)")
    ///     print("Study Date: \(metadata.studyDate)")
    ///     print("Modality: \(metadata.modality)")
    /// }
    /// ```
    ///
    /// - Note: Returns `nil` if Study Instance UID or Series Instance UID are missing
    public func extractStudyMetadata(from filePath: String) async -> StudyMetadata? {
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) {
                // Load DICOM file using decoder factory
                let decoder: DicomDecoderProtocol
                do {
                    decoder = try self.decoderFactory(filePath)
                } catch {
                    self.logger.warning("⚠️ Failed to load DICOM file: \(filePath) - \(error)")
                    continuation.resume(returning: nil)
                    return
                }

                let fileSize = self.fileSize(at: filePath)
                continuation.resume(returning: self.makeStudyMetadata(from: decoder, filePath: filePath, fileSize: fileSize))
            }
        }
    }
    
    /// Batch extracts metadata from multiple DICOM files concurrently.
    ///
    /// This method uses Swift structured concurrency to process multiple files in parallel,
    /// significantly improving performance when loading large datasets. Failed files are
    /// silently skipped - only successfully parsed metadata is returned.
    ///
    /// - Parameter filePaths: Array of absolute file paths to process
    /// - Returns: Array of ``StudyMetadata`` for all successfully parsed files
    ///
    /// ## Example
    /// ```swift
    /// let filePaths = FileManager.default.contentsOfDirectory(atPath: "/path/to/dicoms")
    /// let metadata = await service.extractBatchMetadata(from: filePaths)
    /// print("Extracted \(metadata.count)/\(filePaths.count) files")
    /// ```
    ///
    /// - Note: Processing is concurrent - execution time scales with the number of available CPU cores
    public func extractBatchMetadata(from filePaths: [String]) async -> [StudyMetadata] {
        let results = await withTaskGroup(of: StudyMetadata?.self, returning: [StudyMetadata].self) { group in
            for filePath in filePaths {
                group.addTask {
                    await self.extractStudyMetadata(from: filePath)
                }
            }
            
            var metadata: [StudyMetadata] = []
            for await result in group {
                if let meta = result {
                    metadata.append(meta)
                }
            }
            return metadata
        }
        
        logger.info("📊 Extracted metadata from \(results.count)/\(filePaths.count) files")
        return results
    }

    /// Recursively scans a directory for files that successfully decode as DICOM.
    ///
    /// This method validates file contents with the configured decoder factory rather
    /// than relying on filename extensions, so extensionless DICOM files are included
    /// and non-DICOM files with `.dcm` suffixes are ignored.
    public func scanDICOMFiles(in directoryPath: String) async throws -> [String] {
        let metadata = try await scanDICOMFilesWithMetadata(in: directoryPath)
        return metadata.map(\.filePath)
    }

    /// Loads a DICOMDIR file and returns its patient/study/series hierarchy.
    public func loadDICOMDirectory(at filePath: String) throws -> DicomDirectory {
        try DicomDirectoryReader.read(from: URL(fileURLWithPath: filePath))
    }

    /// Loads `DICOMDIR` from a media directory without recursively scanning every file.
    public func loadDICOMDirectory(in directoryPath: String) throws -> DicomDirectory {
        let url = URL(fileURLWithPath: directoryPath, isDirectory: true)
            .appendingPathComponent("DICOMDIR", isDirectory: false)
        return try DicomDirectoryReader.read(from: url)
    }

    /// Recursively scans a directory and extracts metadata for files that decode as DICOM.
    ///
    /// This combines content validation and metadata extraction in one decode pass,
    /// avoiding a scan-then-reopen cycle for callers that need study metadata.
    public func scanDICOMFilesWithMetadata(in directoryPath: String) async throws -> [StudyMetadata] {
        let fileManager = self.fileManager

        let scanResult = try await Task.detached(priority: .utility) {
            var isDirectory: ObjCBool = false

            guard fileManager.fileExists(atPath: directoryPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw DICOMError.fileNotFound(path: directoryPath)
            }

            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: directoryPath),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw DICOMError.fileReadError(path: directoryPath, underlyingError: "Unable to enumerate directory")
            }

            var candidateURLs: [URL] = []
            var fileSizesByPath: [String: Int64] = [:]
            var skippedEntries: [(path: String, reason: String)] = []

            while let fileURL = enumerator.nextObject() as? URL {
                do {
                    let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard resourceValues.isRegularFile == true else { continue }
                    candidateURLs.append(fileURL)
                    fileSizesByPath[fileURL.path] = Int64(resourceValues.fileSize ?? 0)
                } catch {
                    skippedEntries.append((fileURL.path, error.localizedDescription))
                }
            }

            return (candidateURLs, fileSizesByPath, skippedEntries)
        }.value

        let (candidateURLs, fileSizesByPath, skippedEntries) = scanResult

        for skippedEntry in skippedEntries {
            logger.debug("Skipping unreadable scan entry \(skippedEntry.path): \(skippedEntry.reason)")
        }

        let loader = seriesLoaderFactory()
        let results = await loader.batchLoadFiles(urls: candidateURLs, maxConcurrency: 4)

        var metadata: [StudyMetadata] = []
        for result in results {
            guard let decoder = result.decoder else {
                if let error = result.error {
                    switch error {
                    case .fileNotFound:
                        logger.debug("Skipping missing file during scan: \(result.url.path)")
                    case .invalidDICOMFormat:
                        logger.debug("Skipping non-DICOM file during scan: \(result.url.path) - \(error.localizedDescription)")
                    default:
                        logger.warning("Skipping DICOM file during scan: \(result.url.path) - \(error.localizedDescription)")
                    }
                }
                continue
            }

            guard let fileMetadata = makeStudyMetadata(
                from: decoder,
                filePath: result.url.path,
                fileSize: fileSizesByPath[result.url.path] ?? 0
            ) else {
                continue
            }
            metadata.append(fileMetadata)
        }

        return metadata.sorted { lhs, rhs in
            lhs.filePath < rhs.filePath
        }
    }
    
    /// Validates DICOM file integrity and format.
    ///
    /// Performs comprehensive validation including file existence, DICOM header signature,
    /// minimum file size requirements, and essential DICOM tag presence. This method is useful
    /// for pre-flight validation before attempting full file loading.
    ///
    /// - Parameter filePath: Absolute path to the DICOM file to validate
    /// - Returns: ``DICOMValidationResult`` with validation status and detailed issues
    ///
    /// ## Example
    /// ```swift
    /// let result = await service.validateDICOMFile("/path/to/image.dcm")
    /// if result.isValid {
    ///     print("✅ Valid DICOM file (\(result.fileSize) bytes)")
    /// } else {
    ///     print("❌ Issues found:")
    ///     result.issues.forEach { print("  - \($0)") }
    /// }
    /// ```
    ///
    /// ## Validation Checks
    /// 1. File existence
    /// 2. Minimum file size (≥132 bytes)
    /// 3. DICOM header signature ("DICM" at offset 128)
    /// 4. Study Instance UID presence
    /// 5. Series Instance UID presence
    public func validateDICOMFile(_ filePath: String) async -> DICOMValidationResult {
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) {
                var issues: [String] = []

                // 1. Check file existence
                guard self.fileManager.fileExists(atPath: filePath) else {
                    continuation.resume(returning: DICOMValidationResult(
                        isValid: false,
                        issues: ["File does not exist"],
                        fileSize: 0
                    ))
                    return
                }

                // 2. Check file size
                guard let attributes = try? self.fileManager.attributesOfItem(atPath: filePath),
                      let fileSize = attributes[.size] as? UInt64 else {
                    issues.append("Could not read file attributes")
                    continuation.resume(returning: DICOMValidationResult(
                        isValid: false,
                        issues: issues,
                        fileSize: 0
                    ))
                    return
                }

                // 3. Check minimum DICOM file size
                if fileSize < 132 {
                    issues.append("File too small to be valid DICOM (< 132 bytes)")
                }

                // 4. Check DICOM header
                if fileSize >= 132 {
                    do {
                        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
                        defer { try? handle.close() }
                        try handle.seek(toOffset: 128)
                        let dicmBytes: Data
                        if #available(iOS 13.4, macOS 10.15.4, *) {
                            dicmBytes = try handle.read(upToCount: 4) ?? Data()
                        } else {
                            dicmBytes = handle.readData(ofLength: 4)
                        }
                        if dicmBytes != Data([0x44, 0x49, 0x43, 0x4D]) { // "DICM"
                            issues.append("Missing DICOM header signature")
                        }
                    } catch {
                        issues.append("Could not read file data: \(error.localizedDescription)")
                    }
                }

                // 5. Try to load with decoder using factory
                let decoder: DicomDecoderProtocol
                do {
                    decoder = try self.decoderFactory(filePath)
                } catch {
                    issues.append("Failed to parse DICOM file: \(error.localizedDescription)")
                    continuation.resume(returning: DICOMValidationResult(
                        isValid: false,
                        issues: issues,
                        fileSize: fileSize
                    ))
                    return
                }

                let studyUID = decoder.info(for: DicomTag.studyInstanceUID.rawValue)
                let seriesUID = decoder.info(for: DicomTag.seriesInstanceUID.rawValue)

                if studyUID.isEmpty {
                    issues.append("Missing Study Instance UID")
                }
                if seriesUID.isEmpty {
                    issues.append("Missing Series Instance UID")
                }

                let result = DICOMValidationResult(
                    isValid: issues.isEmpty,
                    issues: issues,
                    fileSize: fileSize
                )

                continuation.resume(returning: result)
            }
        }
    }

    /// Batch validates multiple DICOM files concurrently.
    ///
    /// This method uses Swift structured concurrency to validate multiple files in parallel,
    /// significantly improving performance when validating large datasets. Unlike metadata
    /// extraction which filters failures, this method returns results for ALL files regardless
    /// of validation status.
    ///
    /// - Parameter filePaths: Array of absolute file paths to validate
    /// - Returns: Array of ``DICOMValidationResult`` for all files (one result per input file)
    ///
    /// ## Example
    /// ```swift
    /// let filePaths = FileManager.default.contentsOfDirectory(atPath: "/path/to/dicoms")
    /// let results = await service.validateBatchDICOMFiles(filePaths)
    /// let validCount = results.filter { $0.isValid }.count
    /// print("Valid: \(validCount)/\(results.count) files")
    /// ```
    ///
    /// - Note: Processing is concurrent - execution time scales with the number of available CPU cores
    public func validateBatchDICOMFiles(_ filePaths: [String]) async -> [DICOMValidationResult] {
        let results = await withTaskGroup(of: DICOMValidationResult.self, returning: [DICOMValidationResult].self) { group in
            for filePath in filePaths {
                group.addTask {
                    await self.validateDICOMFile(filePath)
                }
            }

            var validationResults: [DICOMValidationResult] = []
            for await result in group {
                validationResults.append(result)
            }
            return validationResults
        }

        let validCount = results.filter { $0.isValid }.count
        logger.info("✅ Validated \(validCount)/\(filePaths.count) files successfully")
        return results
    }

    /// Creates a ``PatientModel`` from study metadata.
    ///
    /// Converts extracted DICOM metadata into a structured patient model with typed
    /// modality enumeration and proper data organization.
    ///
    /// - Parameter metadata: The ``StudyMetadata`` to convert
    /// - Returns: A ``PatientModel`` instance with typed fields
    ///
    /// ## Example
    /// ```swift
    /// let metadata = await service.extractStudyMetadata(from: filePath)
    /// let patient = service.createPatientModel(from: metadata)
    /// print("Patient: \(patient.patientName) [\(patient.modality.displayName)]")
    /// ```
    public func createPatientModel(from metadata: StudyMetadata) -> PatientModel {
        let modality = DICOMModality.from(string: metadata.modality)
        
        return PatientModel(
            patientName: metadata.patientName,
            patientID: metadata.patientID,
            studyInstanceUID: metadata.studyInstanceUID,
            modality: modality
        )
    }
    
    /// Groups study metadata by Study Instance UID.
    ///
    /// Organizes a flat list of DICOM file metadata into studies by grouping files
    /// that share the same Study Instance UID. This is essential for building hierarchical
    /// views of DICOM data (Patient → Study → Series → Image).
    ///
    /// - Parameter metadata: Array of ``StudyMetadata`` to group
    /// - Returns: Dictionary mapping Study Instance UID to arrays of ``StudyMetadata``
    ///
    /// ## Example
    /// ```swift
    /// let metadata = await service.extractBatchMetadata(from: filePaths)
    /// let grouped = service.groupStudiesByUID(metadata)
    /// for (studyUID, files) in grouped {
    ///     let uniqueSeries = Set(files.map { $0.seriesInstanceUID }).count
    ///     print("Study \(studyUID): \(files.count) files, \(uniqueSeries) series")
    /// }
    /// ```
    public func groupStudiesByUID(_ metadata: [StudyMetadata]) -> [String: [StudyMetadata]] {
        let grouped = Dictionary(grouping: metadata) { $0.studyInstanceUID }
        
        logger.info("📊 Grouped \(metadata.count) files into \(grouped.count) studies")
        
        // Log study sizes for debugging
        for (studyUID, files) in grouped {
            let uniqueSeries = Set(files.map { $0.seriesInstanceUID }).count
            logger.debug("Study \(studyUID.prefix(8))...: \(files.count) files, \(uniqueSeries) series")
        }
        
        return grouped
    }

    private func makeStudyMetadata(from decoder: DicomDecoderProtocol, filePath: String, fileSize: Int64) -> StudyMetadata? {
        let patientName = decoder.info(for: DicomTag.patientName.rawValue)
        let patientID = decoder.info(for: DicomTag.patientID.rawValue)
        let patientSex = decoder.info(for: DicomTag.patientSex.rawValue)
        let patientAge = decoder.info(for: DicomTag.patientAge.rawValue)
        let studyInstanceUID = decoder.info(for: DicomTag.studyInstanceUID.rawValue)
        let studyDate = decoder.info(for: DicomTag.studyDate.rawValue)
        let studyDescription = decoder.info(for: DicomTag.studyDescription.rawValue)
        let seriesInstanceUID = decoder.info(for: DicomTag.seriesInstanceUID.rawValue)
        let modality = decoder.info(for: DicomTag.modality.rawValue)
        let instanceNumberStr = decoder.info(for: DicomTag.instanceNumber.rawValue)
        let bodyPartExamined = decoder.info(for: DicomTag.bodyPartExamined.rawValue)
        let institutionName = decoder.info(for: DicomTag.institutionName.rawValue)

        if studyDate.isEmpty {
            logger.debug("⚠️ Study Date empty for file: \(filePath)")
        }
        if institutionName.isEmpty {
            logger.debug("⚠️ Institution Name empty for file: \(filePath)")
        }
        if patientAge.isEmpty {
            logger.debug("⚠️ Patient Age empty for file: \(filePath)")
        }

        let metadata = StudyMetadata(
            filePath: filePath,
            patientName: patientName.isEmpty ? "Unknown Patient" : patientName,
            patientID: patientID.isEmpty ? "Unknown ID" : patientID,
            patientSex: patientSex,
            patientAge: patientAge.isEmpty ? "Unknown" : patientAge,
            studyInstanceUID: studyInstanceUID,
            studyDate: studyDate.isEmpty ? "Unknown Date" : studyDate,
            studyDescription: studyDescription,
            seriesInstanceUID: seriesInstanceUID,
            modality: modality.isEmpty ? "OT" : modality,
            instanceNumber: Int(instanceNumberStr) ?? 0,
            bodyPartExamined: bodyPartExamined,
            institutionName: institutionName.isEmpty ? "Unknown Location" : institutionName,
            fileSize: fileSize
        )

        guard !metadata.studyInstanceUID.isEmpty,
              !metadata.seriesInstanceUID.isEmpty else {
            logger.warning("⚠️ Invalid DICOM file: missing required UIDs - \(filePath)")
            return nil
        }

        return metadata
    }

    private func fileSize(at path: String) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return 0 }

        if let fileSize = attributes[.size] as? Int64 {
            return fileSize
        }
        if let fileSize = attributes[.size] as? UInt64 {
            return Int64(fileSize)
        }
        return 0
    }
    
    /// Extracts PNG thumbnail data from a DICOM file (first frame).
    ///
    /// Generates a downsampled preview image from the DICOM file, useful for thumbnail
    /// displays in file browsers and study lists. The image is automatically downsampled
    /// to fit within the specified maximum dimensions while preserving aspect ratio.
    ///
    /// - Parameters:
    ///   - filePath: Absolute path to the DICOM file
    ///   - maxSize: Maximum thumbnail dimensions (default: 120×120)
    /// - Returns: PNG thumbnail image data, or `nil` if extraction fails
    ///
    /// ## Example
    /// ```swift
    /// if let thumbData = await service.extractThumbnail(from: filePath, maxSize: CGSize(width: 200, height: 200)) {
    ///     try thumbData.write(to: outputURL)
    /// }
    /// ```
    ///
    public func extractThumbnail(from filePath: String, maxSize: CGSize = CGSize(width: 120, height: 120)) async -> Data? {
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) {
                // Load DICOM file using decoder factory
                let decoder: DicomDecoderProtocol
                do {
                    decoder = try self.decoderFactory(filePath)
                } catch {
                    self.logger.debug("Could not load DICOM file for thumbnail: \(filePath) - \(error)")
                    continuation.resume(returning: nil)
                    return
                }

                let maxDimension = Int(max(maxSize.width, maxSize.height))
                guard maxDimension > 0 else {
                    self.logger.debug("Invalid thumbnail size for \(filePath): \(maxSize.width)x\(maxSize.height)")
                    continuation.resume(returning: nil)
                    return
                }

                guard let thumbnail = decoder.getDownsampledPixels16(maxDimension: maxDimension),
                      thumbnail.width > 0, thumbnail.height > 0 else {
                    self.logger.debug("Could not extract thumbnail from \(filePath)")
                    continuation.resume(returning: nil)
                    return
                }
                
                guard let pngData = Self.encodePNG(
                    pixels: thumbnail.pixels,
                    width: thumbnail.width,
                    height: thumbnail.height
                ) else {
                    self.logger.debug("Could not encode thumbnail for \(filePath)")
                    continuation.resume(returning: nil)
                    return
                }

                self.logger.debug("Extracted thumbnail from \(filePath): \(thumbnail.width)x\(thumbnail.height)")
                continuation.resume(returning: pngData)
            }
        }
    }

    private static func encodePNG(pixels: [UInt16], width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, pixels.count == width * height else {
            return nil
        }

        let minValue = pixels.min() ?? 0
        let maxValue = pixels.max() ?? minValue
        let range = maxValue > minValue ? Double(maxValue - minValue) : 1
        let grayscalePixels = pixels.map { pixel -> UInt8 in
            UInt8(((Double(pixel - minValue) / range) * 255).rounded())
        }

        guard let provider = CGDataProvider(data: Data(grayscalePixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return data as Data
    }
}

// MARK: - Supporting Types

/// Comprehensive DICOM study metadata extracted from a single file.
///
/// Contains structured metadata from DICOM tags organized by category (patient, study,
/// series, instance). All fields provide sensible fallback values for missing or empty tags.
///
/// ## Usage Example
/// ```swift
/// let service = StudyDataService(decoderFactory: { path in try DCMDecoder(contentsOfFile: path) })
/// if let metadata = await service.extractStudyMetadata(from: filePath) {
///     print("Patient: \(metadata.patientName) [\(metadata.patientID)]")
///     print("Study: \(metadata.studyDescription) on \(metadata.studyDate)")
///     print("Series: \(metadata.modality) - \(metadata.bodyPartExamined)")
/// }
/// ```
public struct StudyMetadata: Sendable {
    // MARK: - File Information

    /// Absolute file path to the DICOM file
    public let filePath: String

    // MARK: - Patient Information

    /// Patient name (fallback: "Unknown Patient")
    public let patientName: String

    /// Patient ID (fallback: "Unknown ID")
    public let patientID: String

    /// Patient sex ("M", "F", "O", or empty string)
    public let patientSex: String

    /// Patient age as string (fallback: "Unknown")
    public let patientAge: String

    // MARK: - Study Information

    /// Study Instance UID - unique identifier for the study
    public let studyInstanceUID: String

    /// Study date in DICOM format (fallback: "Unknown Date")
    public let studyDate: String

    /// Human-readable study description
    public let studyDescription: String

    // MARK: - Series Information

    /// Series Instance UID - unique identifier for the series
    public let seriesInstanceUID: String

    /// Modality code (e.g., "CT", "MR", "XR") (fallback: "OT")
    public let modality: String

    // MARK: - Instance Information

    /// Instance number within the series (fallback: 0)
    public let instanceNumber: Int

    // MARK: - Additional Information

    /// Anatomical body part examined
    public let bodyPartExamined: String

    /// Institution where study was performed (fallback: "Unknown Location")
    public let institutionName: String

    /// Source file size in bytes
    public let fileSize: Int64

    public init(
        filePath: String,
        patientName: String,
        patientID: String,
        patientSex: String,
        patientAge: String,
        studyInstanceUID: String,
        studyDate: String,
        studyDescription: String,
        seriesInstanceUID: String,
        modality: String,
        instanceNumber: Int,
        bodyPartExamined: String,
        institutionName: String,
        fileSize: Int64 = 0
    ) {
        self.filePath = filePath
        self.patientName = patientName
        self.patientID = patientID
        self.patientSex = patientSex
        self.patientAge = patientAge
        self.studyInstanceUID = studyInstanceUID
        self.studyDate = studyDate
        self.studyDescription = studyDescription
        self.seriesInstanceUID = seriesInstanceUID
        self.modality = modality
        self.instanceNumber = instanceNumber
        self.bodyPartExamined = bodyPartExamined
        self.institutionName = institutionName
        self.fileSize = fileSize
    }
}

/// Result of DICOM file validation.
///
/// Provides validation status, detailed issues list, and file size information.
/// Used by ``StudyDataService/validateDICOMFile(_:)`` to report validation results.
///
/// ## Usage Example
/// ```swift
/// let result = await service.validateDICOMFile(filePath)
/// print(result.summary)  // Human-readable summary
/// if !result.isValid {
///     result.issues.forEach { print("  - \($0)") }
/// }
/// ```
public struct DICOMValidationResult: Sendable {
    /// Whether the file passed all validation checks
    let isValid: Bool

    /// List of validation issues found (empty if valid)
    let issues: [String]

    /// File size in bytes
    let fileSize: UInt64

    /// Human-readable validation summary with emoji indicators
    var summary: String {
        if isValid {
            return "✅ Valid DICOM file (\(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)))"
        } else {
            return "❌ Invalid DICOM file: \(issues.joined(separator: ", "))"
        }
    }
}
