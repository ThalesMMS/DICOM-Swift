//
//  DicomTool.swift
//  dicomtool
//
//  CLI tool for DICOM file inspection, validation, and conversion
//

import Foundation
import ArgumentParser
import DicomCore

// MARK: - Main CLI Entry Point

/// Command-line tool for DICOM file operations.
///
/// ## Overview
///
/// `dicomtool` provides developer-friendly commands for working with DICOM medical imaging files:
/// - Inspect metadata and patient information
/// - Validate DICOM conformance
/// - Extract pixel data to PNG/JPEG/TIFF with windowing
/// - Batch process directories with glob patterns
///
/// ## Usage
///
/// ```bash
/// # Inspect a DICOM file
/// dicomtool inspect image.dcm
///
/// # Validate DICOM conformance
/// dicomtool validate image.dcm --format json
///
/// # Extract to PNG with windowing
/// dicomtool extract image.dcm --output image.png --preset lung
///
/// # Batch process directory
/// dicomtool batch --pattern "*.dcm" --output-dir ./exports
/// ```
@main
struct DicomTool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dicomtool",
        abstract: "DICOM file inspection, validation, and conversion tool",
        discussion: """
            A command-line utility for working with DICOM medical imaging files.

            Supports metadata extraction, format validation, image export with
            medical windowing presets, and batch processing of directories.

            For detailed help on any command, run:
              dicomtool <command> --help
            """,
        version: "1.0.0",
        subcommands: [
            InspectCommand.self,
            ValidateCommand.self,
            ExtractCommand.self,
            BatchCommand.self,
            PreflightCommand.self,
            CodecCommand.self,
        ],
        defaultSubcommand: nil
    )
}
