//
//  BatchCommand.swift
//  dicomtool
//
//  Command for batch processing multiple DICOM files with glob patterns.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
import ArgumentParser
import DicomCore

// MARK: - Batch Operation Type

/// Type of operation to perform on each file in batch processing.
enum BatchOperation: String, CaseIterable, ExpressibleByArgument {
    case inspect
    case validate
    case extract

    var description: String {
        switch self {
        case .inspect:
            return "Extract metadata from files"
        case .validate:
            return "Validate DICOM conformance"
        case .extract:
            return "Export pixel data to images"
        }
    }
}

// MARK: - Batch Result

/// Result of processing a single file in batch mode.
struct BatchFileResult: Codable, Sendable {
    let file: String
    let success: Bool
    let message: String?
    let error: String?

    init(file: String, success: Bool, message: String? = nil, error: String? = nil) {
        self.file = file
        self.success = success
        self.message = message
        self.error = error
    }
}

// MARK: - Batch Summary

/// Summary of batch processing results.
struct BatchSummary: Codable, Sendable {
    let totalFiles: Int
    let successCount: Int
    let failureCount: Int
    let results: [BatchFileResult]

    var successRate: Double {
        guard totalFiles > 0 else { return 0.0 }
        return Double(successCount) / Double(totalFiles) * 100.0
    }
}

// MARK: - Batch Processor

/// Helper class to process files asynchronously without capturing mutating self.
private struct BatchProcessor {
    let maxConcurrent: Int
    let outputDir: String?
    let preset: MedicalPreset?
    let windowCenter: Double?
    let windowWidth: Double?
    let imageFormat: DicomImageExportFormat
    let jpegQuality: Double
    let frame: Int?
    let allFrames: Bool
    let preserve16Bit: Bool
    let metadata: Bool
    let overwrite: Bool

    /// Batch inspect operation: extract metadata from multiple files.
    func batchInspect(files: [URL]) async -> [BatchFileResult] {
        await processFilesConcurrently(files: files) { url in
            inspectFile(url: url)
        }
    }

    /// Batch validate operation: validate DICOM conformance for multiple files.
    func batchValidate(files: [URL]) async -> [BatchFileResult] {
        await processFilesConcurrently(files: files) { url in
            validateFile(url: url)
        }
    }

    /// Batch extract operation: export pixel data from multiple files.
    func batchExtract(files: [URL]) async -> [BatchFileResult] {
        await processFilesConcurrently(files: files) { url in
            extractFile(url: url)
        }
    }

    /// Inspects a single file and returns the result.
    private func inspectFile(url: URL) -> BatchFileResult {
        do {
            let decoder = try DCMDecoder(contentsOf: url)
            let patientName = decoder.info(for: .patientName)
            let modality = decoder.info(for: .modality)
            let dimensions = "\(decoder.width)×\(decoder.height)"

            var message = "[\(dimensions)]"
            if !modality.isEmpty {
                message += " \(modality)"
            }
            if !patientName.isEmpty {
                message += " - \(patientName)"
            }

            return BatchFileResult(
                file: url.lastPathComponent,
                success: true,
                message: message
            )
        } catch {
            return BatchFileResult(
                file: url.lastPathComponent,
                success: false,
                error: error.localizedDescription
            )
        }
    }

    /// Validates a single file and returns the result.
    private func validateFile(url: URL) -> BatchFileResult {
        let decoder = DCMDecoder()
        let validationResult = decoder.validateDICOMFile(url.path)

        if validationResult.isValid {
            var message = "Valid"
            if !validationResult.issues.isEmpty {
                // Count warnings (issues that are not critical errors)
                let warningCount = validationResult.issues.filter { issue in
                    ValidationIssueClassifier.isWarning(issue)
                }.count
                if warningCount > 0 {
                    message += " (\(warningCount) warning(s))"
                }
            }
            return BatchFileResult(
                file: url.lastPathComponent,
                success: true,
                message: message
            )
        } else {
            let errorMsg = validationResult.issues.joined(separator: "; ")
            return BatchFileResult(
                file: url.lastPathComponent,
                success: false,
                error: errorMsg
            )
        }
    }

    /// Extracts pixel data from a single file and returns the result.
    private func extractFile(url: URL) -> BatchFileResult {
        do {
            let decoder = try DCMDecoder(contentsOf: url)
            let baseName = url.deletingPathExtension().lastPathComponent
            guard let outputDir else {
                return BatchFileResult(
                    file: url.lastPathComponent,
                    success: false,
                    error: "Output directory is required for extract operation"
                )
            }
            let outputDirectoryURL = URL(fileURLWithPath: outputDir)
            let exportOptions = DicomImageExportOptions(
                format: imageFormat,
                quality: jpegQuality,
                overwrite: overwrite,
                pixelMode: exportPixelMode(),
                metadataPolicy: metadata ? .nonPHISidecar : .none
            )

            let message: String
            if allFrames {
                let results = try decoder.exportAllFrames(
                    to: outputDirectoryURL,
                    baseName: baseName,
                    options: exportOptions
                )
                message = "→ \(results.count) frame(s)"
            } else {
                let frameIndex = frame ?? 0
                let outputFileName: String
                if frame == nil {
                    outputFileName = "\(baseName).\(imageFormat.fileExtension)"
                } else {
                    outputFileName = DicomImageExporter.fileName(
                        baseName: baseName,
                        frameIndex: frameIndex,
                        frameCount: max(decoder.pixelDataDescriptor?.numberOfFrames ?? 1, frameIndex + 1),
                        format: imageFormat
                    )
                }
                let outputURL = outputDirectoryURL.appendingPathComponent(outputFileName)
                _ = try decoder.exportImage(frame: frameIndex, to: outputURL, options: exportOptions)
                message = "→ \(outputFileName)"
            }

            return BatchFileResult(
                file: url.lastPathComponent,
                success: true,
                message: message
            )
        } catch {
            return BatchFileResult(
                file: url.lastPathComponent,
                success: false,
                error: error.localizedDescription
            )
        }
    }

    private func exportPixelMode() -> DicomImageExportPixelMode {
        if preserve16Bit {
            return .native16Bit
        }
        if let preset {
            return .display8(selection: .preset(preset))
        }
        if let center = windowCenter, let width = windowWidth {
            return .display8(selection: .customWindow(WindowSettings(center: center, width: width)))
        }
        return .display8(selection: nil)
    }

    private func processFilesConcurrently(
        files: [URL],
        operation: @Sendable @escaping (URL) async -> BatchFileResult
    ) async -> [BatchFileResult] {
        guard !files.isEmpty else { return [] }

        let concurrencyLimit = max(1, maxConcurrent)

        return await withTaskGroup(of: (Int, BatchFileResult).self, returning: [BatchFileResult].self) { group in
            var nextIndexToLaunch = 0
            let initialLaunchCount = min(concurrencyLimit, files.count)

            for _ in 0..<initialLaunchCount {
                let index = nextIndexToLaunch
                let file = files[index]
                nextIndexToLaunch += 1

                group.addTask {
                    (index, await operation(file))
                }
            }

            var orderedResults = Array<BatchFileResult?>(repeating: nil, count: files.count)

            while let (completedIndex, result) = await group.next() {
                orderedResults[completedIndex] = result

                if nextIndexToLaunch < files.count {
                    let index = nextIndexToLaunch
                    let file = files[index]
                    nextIndexToLaunch += 1

                    group.addTask {
                        (index, await operation(file))
                    }
                }
            }

            return orderedResults.compactMap { $0 }
        }
    }
}

// MARK: - Batch Command

/// Batch process multiple DICOM files using glob patterns.
///
/// ## Overview
///
/// ``BatchCommand`` processes multiple DICOM files concurrently based on glob patterns.
/// It supports three operations: inspect (metadata extraction), validate (conformance checking),
/// and extract (pixel data export). Results are summarized with success/failure statistics.
///
/// ## Usage
///
/// Inspect all DICOM files in a directory:
///
/// ```bash
/// dicomtool batch --pattern "*.dcm" --operation inspect
/// ```
///
/// Validate all DICOM files with JSON output:
///
/// ```bash
/// dicomtool batch --pattern "studies/**/*.dcm" --operation validate --format json
/// ```
///
/// Extract all files to a directory with lung windowing:
///
/// ```bash
/// dicomtool batch --pattern "*.dcm" --operation extract --output-dir ./exports --preset lung
/// ```
///
/// Export every frame from matching files:
///
/// ```bash
/// dicomtool batch --pattern "*.dcm" --operation extract --output-dir ./frames --all-frames
/// ```
///
/// Process files sequentially (no parallelism):
///
/// ```bash
/// dicomtool batch --pattern "*.dcm" --operation inspect --max-concurrent 1
/// ```
///
/// ## Topics
///
/// ### Command Execution
///
/// - ``run()``
///
/// ### Batch Operations
///
/// The command supports three batch operations:
/// - **inspect**: Extract metadata from each file
/// - **validate**: Validate DICOM conformance
/// - **extract**: Export pixel data to images (requires `--output-dir`)
struct BatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batch",
        abstract: "Batch process multiple DICOM files with glob patterns",
        discussion: """
            Processes multiple DICOM files concurrently using glob pattern matching.

            Glob Patterns:
            • *.dcm - All .dcm files in current directory
            • **/*.dcm - All .dcm files recursively
            • study_*/series_*/*.dcm - Complex patterns with wildcards

            Operations:
            • inspect - Extract and display metadata from each file
            • validate - Validate DICOM conformance for each file
            • extract - Export pixel data to images (requires --output-dir)

            The command processes files concurrently by default. Use --max-concurrent
            to control parallelism (1 = sequential, higher = more concurrent tasks).

            Examples:
              dicomtool batch --pattern "*.dcm" --operation inspect
              dicomtool batch --pattern "**/*.dcm" --operation validate --format json
              dicomtool batch --pattern "*.dcm" --operation extract --output-dir ./exports
              dicomtool batch --pattern "*.dcm" --operation extract --output-dir ./frames --all-frames
            """
    )

    // MARK: - Required Options

    @Option(
        name: [.short, .long],
        help: "Glob pattern for matching DICOM files (e.g., '*.dcm', '**/*.dcm')"
    )
    var pattern: String

    @Option(
        name: [.short, .long],
        help: "Operation to perform: inspect, validate, or extract"
    )
    var operation: BatchOperation

    // MARK: - Output Options

    @Option(
        name: [.short, .long],
        help: "Output format: text or json (default: text)"
    )
    var format: OutputFormat = .text

    @Option(
        name: .long,
        help: "Output directory for extracted images (required for extract operation)"
    )
    var outputDir: String?

    // MARK: - Parallelism Options

    @Option(
        name: .long,
        help: "Maximum number of concurrent operations (default: 4, use 1 for sequential)"
    )
    var maxConcurrent: Int = 4

    // MARK: - Extract Operation Options

    @Option(
        name: .long,
        help: "Image format for extract operation: png, jpeg, or tiff (default: png)"
    )
    var imageFormat: DicomImageExportFormat = .png

    @Option(
        name: .long,
        help: "JPEG compression quality from 0.0 to 1.0 for extract operation (default: 1.0)"
    )
    var jpegQuality: Double = 1.0

    @Option(
        name: .long,
        help: "Zero-based frame index for extract operation (default: 0)"
    )
    var frame: Int?

    @Flag(
        name: .long,
        help: "Export every frame for extract operation"
    )
    var allFrames: Bool = false

    @Flag(
        name: .long,
        help: "Preserve stored unsigned 16-bit samples when extracting TIFF"
    )
    var preserve16Bit: Bool = false

    @Flag(
        name: .long,
        help: "Write non-PHI JSON metadata sidecars during extract operation"
    )
    var metadata: Bool = false

    @Option(
        name: .long,
        help: "Medical windowing preset for extract operation"
    )
    var preset: MedicalPreset?

    @Option(
        name: .long,
        help: "Window center for extract operation (use with --window-width)"
    )
    var windowCenter: Double?

    @Option(
        name: .long,
        help: "Window width for extract operation (use with --window-center)"
    )
    var windowWidth: Double?

    @Flag(
        name: .long,
        help: "Overwrite existing output files"
    )
    var overwrite: Bool = false

    // MARK: - Execution

    mutating func run() async throws {
        // Validate arguments
        try validateArguments()

        // Find matching files using glob pattern
        let matchingFiles = try findMatchingFiles(pattern: pattern)

        guard !matchingFiles.isEmpty else {
            throw CLIError.emptyInputSet
        }

        // Create output formatter
        let formatter = OutputFormatter(format: format)

        // Print start message (text mode only)
        if format == .text {
            print("Found \(matchingFiles.count) file(s) matching pattern '\(pattern)'")
            print("Operation: \(operation.description)")
            print("Processing with max \(maxConcurrent) concurrent task(s)...\n")
        }

        // Process files based on operation
        let results: [BatchFileResult]
        let batchProcessor = BatchProcessor(
            maxConcurrent: maxConcurrent,
            outputDir: outputDir,
            preset: preset,
            windowCenter: windowCenter,
            windowWidth: windowWidth,
            imageFormat: imageFormat,
            jpegQuality: jpegQuality,
            frame: frame,
            allFrames: allFrames,
            preserve16Bit: preserve16Bit,
            metadata: metadata,
            overwrite: overwrite
        )

        switch operation {
        case .inspect:
            results = await batchProcessor.batchInspect(files: matchingFiles)
        case .validate:
            results = await batchProcessor.batchValidate(files: matchingFiles)
        case .extract:
            results = await batchProcessor.batchExtract(files: matchingFiles)
        }

        // Create summary
        let summary = BatchSummary(
            totalFiles: matchingFiles.count,
            successCount: results.filter { $0.success }.count,
            failureCount: results.filter { !$0.success }.count,
            results: results
        )

        // Output results
        try outputResults(summary: summary, formatter: formatter)
    }

    // MARK: - Validation

    /// Validates command-line arguments.
    private func validateArguments() throws {
        // Validate max concurrent
        guard maxConcurrent > 0 else {
            throw CLIError.invalidArgument(
                argument: "--max-concurrent",
                value: String(maxConcurrent),
                reason: "Must be at least 1"
            )
        }

        // Validate extract-specific options
        if operation == .extract {
            guard let outputDir = outputDir else {
                throw CLIError.missingRequiredArgument(
                    argument: "--output-dir (required for extract operation)"
                )
            }

            // Ensure output directory exists or can be created
            let outputURL = URL(fileURLWithPath: outputDir)
            if !FileManager.default.fileExists(atPath: outputURL.path) {
                do {
                    try FileManager.default.createDirectory(
                        at: outputURL,
                        withIntermediateDirectories: true
                    )
                } catch {
                    throw CLIError.directoryNotFound(path: outputDir)
                }
            }

            if allFrames && frame != nil {
                throw CLIError.invalidArgument(
                    argument: "--frame / --all-frames",
                    value: "",
                    reason: "Cannot use --frame with --all-frames. Choose one frame selection mode."
                )
            }

            if let frame, frame < 0 {
                throw CLIError.invalidArgument(
                    argument: "--frame",
                    value: String(frame),
                    reason: "Frame index must be zero or greater"
                )
            }

            if jpegQuality < 0 || jpegQuality > 1 {
                throw CLIError.invalidArgument(
                    argument: "--jpeg-quality",
                    value: String(jpegQuality),
                    reason: "JPEG quality must be between 0.0 and 1.0"
                )
            }

            if preserve16Bit && imageFormat != .tiff {
                throw CLIError.invalidArgument(
                    argument: "--preserve-16-bit",
                    value: imageFormat.rawValue,
                    reason: "16-bit preservation is only supported for TIFF export"
                )
            }

            // Validate windowing options
            try validateWindowingOptions()
        }
    }

    /// Validates windowing options for extract operation.
    private func validateWindowingOptions() throws {
        let hasPreset = preset != nil
        let hasCustomCenter = windowCenter != nil
        let hasCustomWidth = windowWidth != nil

        // Preset and custom windowing are mutually exclusive
        if hasPreset && (hasCustomCenter || hasCustomWidth) {
            throw CLIError.conflictingArguments(
                arguments: ["--preset", "--window-center", "--window-width"]
            )
        }

        // If one custom windowing parameter is specified, both must be
        if hasCustomCenter != hasCustomWidth {
            throw CLIError.invalidArgument(
                argument: hasCustomCenter ? "--window-center" : "--window-width",
                value: "",
                reason: "Both --window-center and --window-width must be specified together"
            )
        }

        // Validate custom windowing values
        if let width = windowWidth, width <= 0 {
            throw CLIError.invalidArgument(
                argument: "--window-width",
                value: String(width),
                reason: "Window width must be positive"
            )
        }
    }

    // MARK: - File Discovery

    /// Finds files matching the glob pattern.
    private func findMatchingFiles(pattern: String) throws -> [URL] {
        // Expand the pattern to an absolute path
        let expandedPath: String
        if pattern.hasPrefix("/") {
            expandedPath = pattern
        } else {
            let currentDir = FileManager.default.currentDirectoryPath
            expandedPath = (currentDir as NSString).appendingPathComponent(pattern)
        }

        // Use glob to find matching files
        var files: [URL] = []
        var globResult = glob_t()

        let globFlags = GLOB_TILDE | GLOB_BRACE | GLOB_MARK
        let result = glob(expandedPath, globFlags, nil, &globResult)

        defer { globfree(&globResult) }

        guard result == 0 else {
            // GLOB_NOMATCH is not an error, just means no files found
            if result == GLOB_NOMATCH {
                return []
            }
            throw CLIError.invalidPath(
                path: pattern,
                reason: "Failed to evaluate glob pattern"
            )
        }

        let matchCount = Int(globResult.gl_matchc)
        for i in 0..<matchCount {
            if let cString = globResult.gl_pathv[i] {
                let path = String(cString: cString)
                // Filter out directories (glob with GLOB_MARK adds trailing /)
                if !path.hasSuffix("/") {
                    files.append(URL(fileURLWithPath: path))
                }
            }
        }

        return files.sorted { $0.path < $1.path }
    }

    // MARK: - Output

    /// Outputs batch processing results.
    private func outputResults(summary: BatchSummary, formatter: OutputFormatter) throws {
        switch format {
        case .text:
            print("\n" + String(repeating: "=", count: 60))
            print("BATCH PROCESSING SUMMARY")
            print(String(repeating: "=", count: 60))
            print("Total files:   \(summary.totalFiles)")
            print("Successful:    \(summary.successCount)")
            print("Failed:        \(summary.failureCount)")
            print("Success rate:  \(String(format: "%.1f", summary.successRate))%")
            print(String(repeating: "=", count: 60))

            // Show individual results
            if summary.failureCount > 0 {
                print("\nFailed files:")
                for result in summary.results where !result.success {
                    print("  ✗ \(result.file)")
                    if let error = result.error {
                        print("    Error: \(error)")
                    }
                }
            }

            if summary.successCount > 0 {
                print("\nSuccessful files:")
                for result in summary.results where result.success {
                    var line = "  ✓ \(result.file)"
                    if let message = result.message {
                        line += " \(message)"
                    }
                    print(line)
                }
            }

        case .json:
            let output = try formatter.formatJSON(summary)
            print(output)
        }
    }
}
