//
//  InspectCommand.swift
//
//  Command for inspecting DICOM file metadata
//

import Foundation
import ArgumentParser
import DicomCore

// MARK: - Inspect Command

/// Extracts and displays DICOM file metadata.
///
/// ## Overview
///
/// ``InspectCommand`` loads a DICOM file and displays its metadata in human-readable text format
/// or machine-readable JSON format. Supports filtering to specific tags or displaying all available
/// metadata.
///
/// ## Usage
///
/// Inspect a DICOM file with default tags:
///
/// ```bash
/// dicomtool inspect image.dcm
/// ```
///
/// Display all metadata tags:
///
/// ```bash
/// dicomtool inspect image.dcm --all
/// ```
///
/// Display specific tags:
///
/// ```bash
/// dicomtool inspect image.dcm --tags PatientName,Modality,StudyDate
/// ```
///
/// Output as JSON for scripting:
///
/// ```bash
/// dicomtool inspect image.dcm --format json
/// ```
///
/// ## Topics
///
/// ### Command Execution
///
/// - ``run()``
///
/// ### Default Tags
///
/// The command displays these tags by default unless `--all` or `--tags` is specified:
/// - Patient Name
/// - Modality
/// - Study Date
/// - Series Description
/// - Rows (image height)
/// - Columns (image width)
/// - Bits Allocated
/// - Window Center
/// - Window Width
struct InspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Extract and display DICOM file metadata",
        discussion: """
            Loads a DICOM file and displays metadata including patient information,
            study/series details, and image properties.

            By default, shows commonly used tags. Use --all to display all available
            tags, or --tags to specify a custom list of tags to display.

            Supports both human-readable text output and JSON output for automation.
            """
    )

    // MARK: - Arguments

    @Argument(
        help: "Path to the DICOM file to inspect",
        completion: .file(extensions: ["dcm", "dicom"])
    )
    var file: String

    // MARK: - Options

    @Option(
        name: [.short, .long],
        help: "Output format: text or json (default: text)"
    )
    var format: OutputFormat = .text

    @Flag(
        name: .long,
        help: "Display all available metadata tags"
    )
    var all: Bool = false

    @Option(
        name: .long,
        help: "Comma-separated list of specific tags to display (e.g., PatientName,Modality)"
    )
    var tags: String?

    @Flag(name: .long, help: "Read metadata through bounded byte ranges without loading Pixel Data")
    var bounded = false

    @Flag(name: .long, help: "Use anonymous mapped range buffers with --bounded; file reads are still counted as copies")
    var mappedRanges = false

    @Flag(name: .long, help: "Include byte-read, copy and latency metrics with --bounded")
    var readMetrics = false

    @Option(name: .long, help: "Maximum metadata bytes for --bounded (default: 33554432)")
    var metadataByteLimit = 32 * 1024 * 1024

    @Option(name: .long, help: "Metadata validation with --bounded: legacy, strict or recover (default: legacy)")
    var readMode: MetadataReadMode = .legacy

    typealias DecoderFactory = @Sendable (String) async throws -> any DicomDecoderProtocol

    private static let defaultDecoderFactory: DecoderFactory = { path in
        try await DCMDecoder(contentsOfFile: path)
    }
    private static let decoderFactory = LockedValue<DecoderFactory>(defaultDecoderFactory)

    /// Replaces the decoder factory for a scoped test and returns the previous value.
    @discardableResult
    static func replaceDecoderFactory(_ factory: @escaping DecoderFactory) -> DecoderFactory {
        decoderFactory.replace(with: factory)
    }

    static func resetDecoderFactory() {
        decoderFactory.replace(with: defaultDecoderFactory)
    }

    // MARK: - Execution

    mutating func run() async throws {
        // Create output formatter
        let formatter = OutputFormatter(format: format)

        // Validate file path
        let fileURL = URL(fileURLWithPath: file)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CLIError.fileNotReadable(
                path: file,
                reason: "File does not exist"
            )
        }

        if bounded {
            let metadata = try await extractBoundedMetadata(from: fileURL)
            print(try formatter.formatMetadata(metadata, title: "DICOM Metadata: \(fileURL.lastPathComponent)"))
            return
        }
        guard !mappedRanges, !readMetrics, readMode == .legacy else {
            throw ValidationError("--mapped-ranges, --read-metrics and validated --read-mode require --bounded")
        }

        // Load DICOM file
        let decoder: any DicomDecoderProtocol
        do {
            decoder = try await Self.decoderFactory.value(fileURL.path)
        } catch {
            throw CLIError.invalidDICOMFile(
                path: file,
                reason: error.localizedDescription
            )
        }

        // Extract metadata based on options
        let metadata: [String: String]
        if all {
            metadata = extractAllMetadata(from: decoder)
        } else if let tagList = tags {
            metadata = try extractSpecificTags(tagList, from: decoder)
        } else {
            metadata = extractDefaultMetadata(from: decoder)
        }

        // Format and output
        let output = try formatter.formatMetadata(
            metadata,
            title: "DICOM Metadata: \(fileURL.lastPathComponent)"
        )
        print(output)
    }

    // MARK: - Metadata Extraction

    private func extractBoundedMetadata(from url: URL) async throws -> [String: String] {
        guard metadataByteLimit > 0 else { throw ValidationError("--metadata-byte-limit must be positive") }
        let start = ContinuousClock.now
        let source = try await DicomByteSource.openFile(url, storage: mappedRanges ? .mappedSnapshot : .buffer)
        do {
            let parsed: DicomSourceMetadata
            switch readMode {
            case .legacy:
                parsed = try await DicomSourceMetadata.readPart10(from: source, maximumMetadataBytes: metadataByteLimit)
            case .strict, .recover:
                parsed = try await DicomSourceMetadata.readPart10(from: source,
                    mode: readMode == .strict ? .strict : .recover, maximumMetadataBytes: metadataByteLimit)
            }
            var output: [String: String] = [:]
            let numericNames: [String: DicomTag] = ["Rows": .rows, "Columns": .columns,
                                                   "BitsAllocated": .bitsAllocated, "SamplesPerPixel": .samplesPerPixel]
            let names = Self.tagDisplayNameMap.merging(Dictionary(uniqueKeysWithValues: numericNames.map { ($0.value, $0.key) })) { first, _ in first }
            if let tags {
                for raw in tags.split(separator: ",") {
                    let name = raw.trimmingCharacters(in: .whitespaces)
                    guard let tag = names.first(where: { Self.normalizeTagName($0.value) == Self.normalizeTagName(name) })?.key else {
                        throw ValidationError("Unknown DICOM tag name: \(name)")
                    }
                    output[name] = Self.redactedOutputTags.contains(tag) ? "(redacted)"
                        : parsed.dataSet[tag]?.stringValues.joined(separator: "\\") ?? "(not present)"
                }
            } else {
                let defaults: Set<String> = ["PatientName", "PatientSex", "PatientAge", "Modality", "StudyDate",
                    "StudyDescription", "StudyInstanceUID", "SeriesDescription", "SeriesInstanceUID", "SeriesNumber",
                    "Rows", "Columns", "BitsAllocated", "SamplesPerPixel", "PhotometricInterpretation",
                    "WindowCenter", "WindowWidth", "RescaleSlope", "RescaleIntercept"]
                for element in parsed.dataSet.elements {
                    guard !Self.redactedOutputTags.contains(where: { $0.rawValue == element.tag }) else { continue }
                    let name = names.first(where: { $0.key.rawValue == element.tag })?.value
                        ?? String(format: "Tag_%08X", element.tag)
                    guard all || defaults.contains(name) else { continue }
                    switch element.value {
                    case .bytes(let bytes): output[name] = "(\(bytes.count) bytes)"
                    case .sequence(let items): output[name] = "(\(items.count) items)"
                    default: output[name] = element.stringValues.joined(separator: "\\")
                    }
                }
            }
            if readMode != .legacy {
                output["ReadMode"] = readMode.rawValue
                for (scope, diagnostics) in [("FileMeta", parsed.fileMetaDiagnostics), ("DataSet", parsed.dataSetDiagnostics)] {
                    output["Read\(scope)DiagnosticsCount"] = String(diagnostics.count)
                    for (index, diagnostic) in diagnostics.enumerated() {
                        output["Read\(scope)Diagnostic\(index)"] = String(format: "tag=%08X offset=%ld reason=%@",
                            diagnostic.tag, diagnostic.offset, diagnostic.reason.rawValue)
                        output["Read\(scope)Diagnostic\(index)Path"] = diagnostic.path.map { component in
                            switch component {
                            case .tag(let tag): return String(format: "tag:%08X", tag)
                            case .item(let item): return "item:\(item)"
                            case .frame(let frame): return "frame:\(frame)"
                            }
                        }.joined(separator: "/")
                    }
                }
            }
            if readMetrics {
                let metrics = await source.metrics
                let elapsed = start.duration(to: .now).components
                output["ReadSourceBytes"] = String(source.count)
                output["ReadReceivedBytes"] = String(metrics.receivedBytes)
                output["ReadStorageCopiedBytes"] = String(metrics.storageCopiedBytes)
                output["ReadMetadataCopiedBytes"] = String(parsed.metadataCopiedBytes)
                output["ReadRequestCount"] = String(metrics.readCount)
                output["ReadElapsedMilliseconds"] = String(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            }
            await source.close()
            return output
        } catch {
            await source.close()
            throw error
        }
    }

    /// Extracts default metadata tags commonly used in medical imaging workflows.
    private func extractDefaultMetadata(from decoder: any DicomDecoderProtocol) -> [String: String] {
        var metadata: [String: String] = [:]

        // Patient Information
        let patientName = decoder.info(for: .patientName)
        if !patientName.isEmpty {
            metadata["PatientName"] = patientName
        }
        let patientSex = decoder.info(for: .patientSex)
        if !patientSex.isEmpty {
            metadata["PatientSex"] = patientSex
        }
        let patientAge = decoder.info(for: .patientAge)
        if !patientAge.isEmpty {
            metadata["PatientAge"] = patientAge
        }

        // Study Information
        let modality = decoder.info(for: .modality)
        if !modality.isEmpty {
            metadata["Modality"] = modality
        }
        let studyDate = decoder.info(for: .studyDate)
        if !studyDate.isEmpty {
            metadata["StudyDate"] = studyDate
        }
        let studyDescription = decoder.info(for: .studyDescription)
        if !studyDescription.isEmpty {
            metadata["StudyDescription"] = studyDescription
        }
        let studyInstanceUID = decoder.info(for: .studyInstanceUID)
        if !studyInstanceUID.isEmpty {
            metadata["StudyInstanceUID"] = studyInstanceUID
        }

        // Series Information
        let seriesDescription = decoder.info(for: .seriesDescription)
        if !seriesDescription.isEmpty {
            metadata["SeriesDescription"] = seriesDescription
        }
        let seriesInstanceUID = decoder.info(for: .seriesInstanceUID)
        if !seriesInstanceUID.isEmpty {
            metadata["SeriesInstanceUID"] = seriesInstanceUID
        }
        let seriesNumber = decoder.info(for: .seriesNumber)
        if !seriesNumber.isEmpty {
            metadata["SeriesNumber"] = seriesNumber
        }

        // Image Properties
        metadata["Rows"] = String(decoder.height)
        metadata["Columns"] = String(decoder.width)
        metadata["BitsAllocated"] = String(decoder.bitDepth)
        metadata["SamplesPerPixel"] = String(decoder.samplesPerPixel)

        let photometricInterpretation = decoder.info(for: .photometricInterpretation)
        if !photometricInterpretation.isEmpty {
            metadata["PhotometricInterpretation"] = photometricInterpretation
        }

        // Display Parameters
        let windowSettings = decoder.windowSettingsV2
        if windowSettings.isValid {
            metadata["WindowCenter"] = String(format: "%.1f", windowSettings.center)
            metadata["WindowWidth"] = String(format: "%.1f", windowSettings.width)
        }

        let rescaleParams = decoder.rescaleParametersV2
        if !rescaleParams.isIdentity {
            metadata["RescaleIntercept"] = String(format: "%.2f", rescaleParams.intercept)
            metadata["RescaleSlope"] = String(format: "%.2f", rescaleParams.slope)
        }

        // Pixel Spacing
        let pixelSpacing = decoder.pixelSpacingV2
        if pixelSpacing.isValid {
            metadata["PixelSpacing"] = String(format: "%.4f × %.4f mm", pixelSpacing.x, pixelSpacing.y)
            if pixelSpacing.z > 0 {
                metadata["SliceThickness"] = String(format: "%.4f mm", pixelSpacing.z)
            }
        }

        return metadata
    }

    /// Extracts all available metadata tags from the decoder.
    private func extractAllMetadata(from decoder: any DicomDecoderProtocol) -> [String: String] {
        var metadata: [String: String] = [:]

        // Start with default metadata
        let defaultMeta = extractDefaultMetadata(from: decoder)
        metadata.merge(defaultMeta) { _, new in new }

        // Add additional common tags not in default set
        let additionalTags: [DicomTag] = [
            .studyID,
            .studyTime,
            .seriesDate,
            .seriesTime,
            .instanceNumber,
            .acquisitionDate,
            .acquisitionTime,
            .contentDate,
            .contentTime,
            .sopInstanceUID,
            .numberOfFrames,
            .imagePositionPatient,
            .imageOrientationPatient,
            .sliceThickness,
            .sliceSpacing,
            .patientPosition,
            .bodyPartExamined,
            .institutionName,
            .referringPhysicianName,
            .protocolName,
            .acquisitionProtocolName
        ]

        for tag in additionalTags {
            let value = decoder.info(for: tag)
            if !value.isEmpty {
                metadata[tagNameForDisplay(tag)] = value
            }
        }

        // Add pixel representation status
        if decoder.isSignedPixelRepresentation {
            metadata["PixelRepresentation"] = "Signed"
        } else {
            metadata["PixelRepresentation"] = "Unsigned"
        }

        // Add compression status
        if decoder.compressedImage {
            metadata["Compressed"] = "Yes"
        }

        return metadata
    }

    /// Extracts specific tags requested by the user.
    private func extractSpecificTags(_ tagList: String, from decoder: any DicomDecoderProtocol) throws -> [String: String] {
        var metadata: [String: String] = [:]
        let requestedTags = tagList.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        for tagName in requestedTags {
            guard !tagName.isEmpty else { continue }

            // Try to match tag name to DicomTag enum
            if let tag = dicomTagFromName(tagName) {
                if Self.redactedOutputTags.contains(tag) {
                    metadata[tagName] = "(redacted)"
                    continue
                }

                let value = decoder.info(for: tag)
                if !value.isEmpty {
                    metadata[tagName] = value
                } else {
                    metadata[tagName] = "(not present)"
                }
            } else if tagName == "Rows" {
                metadata[tagName] = String(decoder.height)
            } else if tagName == "Columns" {
                metadata[tagName] = String(decoder.width)
            } else if tagName == "BitsAllocated" {
                metadata[tagName] = String(decoder.bitDepth)
            } else {
                throw CLIError.invalidArgument(
                    argument: "--tags",
                    value: tagName,
                    reason: "Unknown tag name. Use standard DICOM tag names like PatientName, Modality, etc."
                )
            }
        }

        return metadata
    }

    // MARK: - Tag Name Helpers

    private static let redactedOutputTags: Set<DicomTag> = [
        .patientID
    ]

    private static let tagDisplayNameMap: [DicomTag: String] = [
        .patientName: "PatientName",
        .patientID: "PatientID",
        .patientSex: "PatientSex",
        .patientAge: "PatientAge",
        .studyInstanceUID: "StudyInstanceUID",
        .studyID: "StudyID",
        .studyDate: "StudyDate",
        .studyTime: "StudyTime",
        .studyDescription: "StudyDescription",
        .seriesInstanceUID: "SeriesInstanceUID",
        .seriesNumber: "SeriesNumber",
        .seriesDate: "SeriesDate",
        .seriesTime: "SeriesTime",
        .seriesDescription: "SeriesDescription",
        .modality: "Modality",
        .instanceNumber: "InstanceNumber",
        .acquisitionDate: "AcquisitionDate",
        .acquisitionTime: "AcquisitionTime",
        .contentDate: "ContentDate",
        .contentTime: "ContentTime",
        .sopInstanceUID: "SOPInstanceUID",
        .numberOfFrames: "NumberOfFrames",
        .imagePositionPatient: "ImagePositionPatient",
        .imageOrientationPatient: "ImageOrientationPatient",
        .sliceThickness: "SliceThickness",
        .sliceSpacing: "SliceSpacing",
        .patientPosition: "PatientPosition",
        .bodyPartExamined: "BodyPartExamined",
        .institutionName: "InstitutionName",
        .referringPhysicianName: "ReferringPhysicianName",
        .protocolName: "ProtocolName",
        .acquisitionProtocolName: "AcquisitionProtocolName",
        .photometricInterpretation: "PhotometricInterpretation",
        .windowCenter: "WindowCenter",
        .windowWidth: "WindowWidth",
        .rescaleIntercept: "RescaleIntercept",
        .rescaleSlope: "RescaleSlope",
    ]

    private static let tagNameLookupMap: [String: DicomTag] = {
        Dictionary(
            uniqueKeysWithValues: tagDisplayNameMap.map { tag, name in
                (normalizeTagName(name), tag)
            }
        )
    }()

    private static func normalizeTagName(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "_", with: "")
    }

    /// Converts a DicomTag enum case to a display name.
    private func tagNameForDisplay(_ tag: DicomTag) -> String {
        Self.tagDisplayNameMap[tag] ?? "Tag_\(String(format: "%08X", tag.rawValue))"
    }

    /// Converts a tag name string to a DicomTag enum case.
    private func dicomTagFromName(_ name: String) -> DicomTag? {
        Self.tagNameLookupMap[Self.normalizeTagName(name)]
    }
}
