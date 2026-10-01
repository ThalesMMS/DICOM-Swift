//
//  ExtractCommand.swift
//
//  Command for extracting pixel data from DICOM files with windowing
//

import Foundation
import ArgumentParser
import DicomCore

// MARK: - ArgumentParser Conformance Extensions

extension DicomImageExportFormat: ExpressibleByArgument {
    public init?(argument: String) {
        switch argument.lowercased() {
        case "png":
            self = .png
        case "jpg", "jpeg":
            self = .jpeg
        case "tif", "tiff":
            self = .tiff
        default:
            return nil
        }
    }
}

extension ProcessingMode: ExpressibleByArgument {
    public init?(argument: String) {
        switch argument.lowercased() {
        case "vdsp":
            self = .vdsp
        case "metal":
            self = .metal
        case "auto":
            self = .auto
        default:
            return nil
        }
    }
}

extension MedicalPreset: ExpressibleByArgument {
    public init?(argument: String) {
        // Try to find matching case by display name
        let normalized = argument.lowercased().replacingOccurrences(of: " ", with: "")

        for preset in MedicalPreset.allCases {
            let presetName = preset.displayName.lowercased().replacingOccurrences(of: " ", with: "")
            if normalized == presetName {
                self = preset
                return
            }
        }

        return nil
    }
}

// MARK: - Extract Command

/// Extracts pixel data from DICOM files with windowing and exports to image formats.
///
/// ## Overview
///
/// ``ExtractCommand`` loads a DICOM file, applies window/level transformations for medical image
/// display, and exports the result to standard image formats. Supports both
/// medical presets (lung, bone, brain, etc.) and custom windowing parameters.
///
/// ## Usage
///
/// Extract with lung preset:
///
/// ```bash
/// dicomtool extract image.dcm --output lung.png --preset lung
/// ```
///
/// Extract with custom windowing:
///
/// ```bash
/// dicomtool extract image.dcm --output custom.png --window-center 50 --window-width 400
/// ```
///
/// Extract to JPEG format:
///
/// ```bash
/// dicomtool extract image.dcm --output image.jpg --format jpeg --jpeg-quality 0.9
/// ```
///
/// Export all frames to a directory:
///
/// ```bash
/// dicomtool extract multiframe.dcm --output frames --all-frames
/// ```
///
/// Extract with automatic optimal windowing:
///
/// ```bash
/// dicomtool extract image.dcm --output auto.png
/// ```
///
/// ## Topics
///
/// ### Command Execution
///
/// - ``run()``
///
/// ### Windowing Options
///
/// The command supports three windowing modes (mutually exclusive):
/// 1. **Preset windowing**: Use `--preset` with a medical preset name
/// 2. **Custom windowing**: Use `--window-center` and `--window-width` together
/// 3. **Automatic windowing**: No windowing flags (calculates optimal values from image data)
struct ExtractCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract",
        abstract: "Extract and export DICOM pixel data with windowing",
        discussion: """
            Loads a DICOM file, applies window/level transformations, and exports to PNG, JPEG, or TIFF.

            Windowing Options (choose one):
            • Preset: --preset lung|bone|brain|softtissue|liver|mediastinum|abdomen|spine|pelvis|angiography|pulmonaryembolism|mammography|petscan
            • Custom: --window-center <value> --window-width <value>
            • Automatic: No windowing flags (calculates optimal values)

            Frame options:
            • Single frame: default is frame 0, or pass --frame <zero-based-index>
            • All frames: pass --all-frames and use --output as a directory

            Examples:
              dicomtool extract ct.dcm --output lung.png --preset lung
              dicomtool extract ct.dcm --output custom.png --window-center 50 --window-width 400
              dicomtool extract ct.dcm --output image.jpg --format jpeg --jpeg-quality 0.9
              dicomtool extract ct.dcm --output native.tiff --format tiff --preserve-16-bit
              dicomtool extract perfusion.dcm --output frames --all-frames --metadata
            """
    )

    // MARK: - Arguments

    @Argument(
        help: "Path to the DICOM file to extract",
        completion: .file(extensions: ["dcm", "dicom"])
    )
    var file: String

    // MARK: - Required Options

    @Option(
        name: [.short, .long],
        help: "Output file path, or output directory when --all-frames is set",
        completion: .file(extensions: ["png", "jpg", "jpeg", "tif", "tiff"])
    )
    var output: String

    // MARK: - Export Options

    @Option(
        name: [.short, .long],
        help: "Output format: png, jpeg, or tiff (default: png)"
    )
    var format: DicomImageExportFormat = .png

    @Option(
        name: .long,
        help: "JPEG compression quality from 0.0 to 1.0 (default: 1.0)"
    )
    var jpegQuality: Double = 1.0

    @Flag(
        name: .long,
        help: "Write JPEG output as a progressive (SOF2) codestream with the own encoder"
    )
    var progressiveJpeg: Bool = false

    @Option(
        name: .long,
        help: "Zero-based frame index to export (default: 0)"
    )
    var frame: Int?

    @Flag(
        name: .long,
        help: "Export every frame to the output directory"
    )
    var allFrames: Bool = false

    @Flag(
        name: .long,
        help: "Preserve stored unsigned 16-bit samples when exporting TIFF"
    )
    var preserve16Bit: Bool = false

    @Flag(
        name: .long,
        help: "Write a non-PHI JSON metadata sidecar next to each exported image"
    )
    var metadata: Bool = false

    @Flag(
        name: .long,
        help: "Overwrite output file if it exists"
    )
    var overwrite: Bool = false

    // MARK: - Windowing Options

    @Option(
        name: .long,
        help: "Medical windowing preset (lung, bone, brain, softtissue, liver, mediastinum, abdomen, spine, pelvis, angiography, pulmonaryembolism, mammography, petscan)"
    )
    var preset: MedicalPreset?

    @Option(
        name: .long,
        help: "Custom window center value (use with --window-width)"
    )
    var windowCenter: Double?

    @Option(
        name: .long,
        help: "Custom window width value (use with --window-center)"
    )
    var windowWidth: Double?

    // MARK: - Processing Options

    @Option(
        name: .long,
        help: "Compatibility option accepted by older scripts; image export uses the DicomCore frame exporter"
    )
    var processingMode: ProcessingMode = .auto

    @Flag(name: .long, help: "Use a bounded shared frame session; preserve original frame numbers in image sidecars")
    var bounded = false

    // MARK: - Execution

    mutating func run() async throws {
        // Validate file path
        let fileURL = URL(fileURLWithPath: file)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CLIError.fileNotReadable(
                path: file,
                reason: "File does not exist"
            )
        }

        // Validate windowing options
        try validateWindowingOptions()

        if bounded {
            try await extractBounded(from: fileURL)
            return
        }

        // Load DICOM file
        let decoder: DCMDecoder
        do {
            decoder = try await DCMDecoder(contentsOf: fileURL)
        } catch {
            throw CLIError.invalidDICOMFile(
                path: file,
                reason: error.localizedDescription
            )
        }

        let outputURL = URL(fileURLWithPath: output)
        let exportOptions = DicomImageExportOptions(
            format: format,
            quality: jpegQuality,
            overwrite: overwrite,
            pixelMode: try pixelMode(),
            metadataPolicy: metadata ? .nonPHISidecar : .none,
            progressiveJPEG: progressiveJpeg
        )

        if allFrames {
            let baseName = fileURL.deletingPathExtension().lastPathComponent
            let results = try decoder.exportAllFrames(to: outputURL, baseName: baseName, options: exportOptions)
            print("✓ Extracted \(results.count) frame(s) to \(outputURL.path)")
        } else {
            let frameIndex = frame ?? 0
            let result = try decoder.exportImage(frame: frameIndex, to: outputURL, options: exportOptions)
            print("✓ Extracted \(decoder.width)×\(decoder.height) frame \(result.frameIndex) to \(outputURL.lastPathComponent)")
            if let metadataURL = result.metadataURL {
                print("  Metadata: \(metadataURL.lastPathComponent)")
            }
        }

        print("  Windowing: \(windowingDescription())")
        print("  Format: \(format.description)")
    }

    private func extractBounded(from fileURL: URL) async throws {
        let source = try await DicomByteSource.openFile(fileURL, limits: .init(maximumTotalReadBytes: Int.max))
        var openedSession: DicomSourceFrameSession?
        do {
            let session = try await DicomSourceFrameSession.open(source: source)
            openedSession = session
            let outputURL = URL(fileURLWithPath: output)
            let options = DicomImageExportOptions(format: format, quality: jpegQuality, overwrite: overwrite,
                                                   pixelMode: try pixelMode(), metadataPolicy: metadata ? .nonPHISidecar : .none,
            progressiveJPEG: progressiveJpeg
        )
            let selected = frame ?? 0
            guard allFrames || (selected >= 0 && selected < session.index.frameCount) else {
                throw DicomImageExportError.invalidFrame(index: selected, frameCount: session.index.frameCount)
            }
            let frames = allFrames ? 0..<session.index.frameCount : selected..<(selected + 1)
            if allFrames { try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true) }
            for index in frames {
                try Task.checkCancellation()
                let target = allFrames ? outputURL.appendingPathComponent(DicomImageExporter.fileName(
                    baseName: fileURL.deletingPathExtension().lastPathComponent, frameIndex: index,
                    frameCount: session.index.frameCount, format: format)) : outputURL
                _ = try await DicomImageExporter().export(session: session, frame: index, to: target, options: options)
            }
            let metrics = await session.metrics
            print("✓ Extracted \(frames.count) frame(s) through bounded reads")
            print("  Read bytes: \(metrics.source.receivedBytes); materialized bytes: \(metrics.materializedBytes)")
            print("  Windowing: \(windowingDescription())")
            print("  Format: \(format.description)")
            await session.close()
        } catch {
            if let openedSession {
                await openedSession.close()
            } else {
                await source.close()
            }
            throw error
        }
    }

    // MARK: - Validation

    /// Validates that windowing options are used correctly.
    private func validateWindowingOptions() throws {
        // Check for conflicting options
        let hasPreset = preset != nil
        let hasCustomCenter = windowCenter != nil
        let hasCustomWidth = windowWidth != nil

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

        if preserve16Bit && format != .tiff {
            throw CLIError.invalidArgument(
                argument: "--preserve-16-bit",
                value: format.rawValue,
                reason: "16-bit preservation is only supported for TIFF export"
            )
        }

        // Preset and custom windowing are mutually exclusive
        if hasPreset && (hasCustomCenter || hasCustomWidth) {
            throw CLIError.invalidArgument(
                argument: "--preset / --window-center / --window-width",
                value: "",
                reason: "Cannot use --preset with --window-center/--window-width. Choose one windowing method."
            )
        }

        // If one custom windowing parameter is specified, both must be
        if hasCustomCenter != hasCustomWidth {
            throw CLIError.invalidArgument(
                argument: hasCustomCenter ? "--window-center" : "--window-width",
                value: "",
                reason: "Both --window-center and --window-width must be specified together for custom windowing"
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

    private func pixelMode() throws -> DicomImageExportPixelMode {
        guard !preserve16Bit else { return .native16Bit }
        if let preset {
            return .display8(selection: .preset(preset))
        }
        if let center = windowCenter, let width = windowWidth {
            return .display8(selection: .customWindow(WindowSettings(center: center, width: width)))
        }
        return .display8(selection: nil)
    }

    private func windowingDescription() -> String {
        if preserve16Bit {
            return "native 16-bit stored values"
        }
        if let preset {
            return "preset=\(preset.displayName)"
        }
        if let center = windowCenter, let width = windowWidth {
            return "center=\(String(format: "%.1f", center)), width=\(String(format: "%.1f", width))"
        }
        return "dicom/default or automatic percentile"
    }
}
