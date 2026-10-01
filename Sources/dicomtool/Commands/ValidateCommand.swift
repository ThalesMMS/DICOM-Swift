//
//  ValidateCommand.swift
//
//  Command for validating DICOM file conformance
//

import Foundation
import ArgumentParser
import DicomCore

// MARK: - Validation Abstraction

protocol DICOMValidating: Sendable {
    func validateDICOMFile(_ filename: String) -> (isValid: Bool, issues: [String])
}

extension DCMDecoder: DICOMValidating {}

// MARK: - Validate Command

/// Validates DICOM file conformance and reports issues.
///
/// ## Overview
///
/// The legacy mode performs basic compatibility checks on DICOM files including:
/// - File format and structure validation
/// - Required metadata presence
/// - Image dimensions and pixel data integrity
/// - Transfer syntax support
///
/// The command reports validation status along with any errors or warnings found.
/// Supports both human-readable text output and machine-readable JSON output
/// for automation workflows.
///
/// ## Usage
///
/// Validate a DICOM file with text output:
///
/// ```bash
/// dicomtool validate image.dcm
/// ```
///
/// Output validation results as JSON for scripting:
///
/// ```bash
/// dicomtool validate image.dcm --format json
/// ```
///
/// ## Topics
///
/// ### Command Execution
///
/// - ``run()``
///
/// ### Validation Checks
///
/// The command performs the following validation checks:
/// - File exists and is readable
/// - File size is appropriate (>= 132 bytes for DICOM preamble)
/// - DICOM file signature is present
/// - Required metadata tags are present
/// - Image dimensions are valid
/// - Pixel data is accessible
/// - Transfer syntax is supported
struct ValidateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate DICOM file conformance",
        discussion: """
            Performs basic compatibility checks on a DICOM file. Use --composed
            for original Part 10 evidence separated into validation layers.

            Composed mode returns exit 1 for a failed layer and exit 2 when evidence
            is incomplete. A successful codec or legacy check does not establish
            complete IOD conformance.

            Supports human-readable text and JSON output for automation.
            """
    )

    // MARK: - Arguments

    @Argument(
        help: "Path to the DICOM file to validate",
        completion: .file(extensions: ["dcm", "dicom"])
    )
    var file: String

    // MARK: - Options

    @Option(
        name: [.short, .long],
        help: "Output format: text or json (default: text)"
    )
    var format: OutputFormat = .text

    @Flag(name: .long, help: "Compose original Part 10 evidence by layer. Exit 2 means incomplete, 1 means failed; no PHI in the report.")
    var composed = false

    @Option(name: .long, help: """
        External fact for composed mode as name=yes|no, repeatable. Names: animal, non-bipedal, \
        paired-body-part, temporally-related-series, calibrated-image, rescale-hu, cardiac-gating, requested-procedure, \
        predecessor-content, identical-documents, equivalent-cda, observation-time-differs, root-template, \
        sar-capable, gradient-output-capable, operating-mode-regulated, us-staged-protocol, contrast-media-used, \
        non-square-pixels, subject-is-specimen, frame-retrieve-response. Unstated facts stay undetermined.
        """)
    var fact: [String] = []

    static let factNames = ["animal", "non-bipedal", "paired-body-part", "temporally-related-series", "calibrated-image",
                            "rescale-hu", "cardiac-gating", "requested-procedure", "predecessor-content", "identical-documents",
                            "equivalent-cda", "observation-time-differs", "root-template", "sar-capable",
                            "gradient-output-capable", "operating-mode-regulated", "us-staged-protocol",
                            "contrast-media-used", "non-square-pixels", "subject-is-specimen", "frame-retrieve-response"]

    static func imageConditions(from facts: [String]) throws -> DicomCompositeImageModules.Conditions {
        var truths: [String: DicomAttributeRule.Truth] = [:]
        for fact in facts {
            let parts = fact.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, factNames.contains(parts[0]), ["yes", "no"].contains(parts[1]) else {
                throw ValidationError("Unknown fact '\(fact)'; expected one of \(factNames.joined(separator: ", ")) with yes or no")
            }
            truths[parts[0]] = parts[1] == "yes" ? .satisfied : .unsatisfied
        }
        return .init(nonHumanPatient: truths["animal"] ?? .undetermined,
                     nonBipedalAnatomy: truths["non-bipedal"] ?? .undetermined,
                     pairedBodyPart: truths["paired-body-part"] ?? .undetermined,
                     temporallyRelatedSeries: truths["temporally-related-series"] ?? .undetermined,
                     calibratedImage: truths["calibrated-image"] ?? .undetermined,
                     rescaleUnitsAreHU: truths["rescale-hu"] ?? .undetermined,
                     cardiacGating: truths["cardiac-gating"] ?? .undetermined,
                     fulfilsRequestedProcedure: truths["requested-procedure"] ?? .undetermined,
                     includesOtherDocumentContent: truths["predecessor-content"] ?? .undetermined,
                     identicalDocumentsStored: truths["identical-documents"] ?? .undetermined,
                     equivalentCDADocument: truths["equivalent-cda"] ?? .undetermined,
                     observationTimeDiffers: truths["observation-time-differs"] ?? .undetermined,
                     rootTemplateUsed: truths["root-template"] ?? .undetermined,
                     sarCapable: truths["sar-capable"] ?? .undetermined,
                     gradientOutputCapable: truths["gradient-output-capable"] ?? .undetermined,
                     operatingModeRegulated: truths["operating-mode-regulated"] ?? .undetermined,
                     ultrasoundStagedProtocol: truths["us-staged-protocol"] ?? .undetermined,
                     contrastMediaUsed: truths["contrast-media-used"] ?? .undetermined,
                     nonSquarePixels: truths["non-square-pixels"] ?? .undetermined,
                     imagingSubjectIsSpecimen: truths["subject-is-specimen"] ?? .undetermined,
                     frameLevelRetrieveResponse: truths["frame-retrieve-response"] ?? .undetermined)
    }

    typealias ValidatorFactory = @Sendable () -> any DICOMValidating

    private static let defaultValidatorFactory: ValidatorFactory = { DCMDecoder() }
    private static let validatorFactory = LockedValue<ValidatorFactory>(defaultValidatorFactory)

    /// Replaces the validator factory for a scoped test and returns the previous value.
    @discardableResult
    static func replaceValidatorFactory(_ factory: @escaping ValidatorFactory) -> ValidatorFactory {
        validatorFactory.replace(with: factory)
    }

    static func resetValidatorFactory() {
        validatorFactory.replace(with: defaultValidatorFactory)
    }

    // MARK: - Execution

    mutating func run() throws {
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

        if composed {
            let report = try DicomCodecWorkflowEngine().validateInstance(Data(contentsOf: fileURL, options: .mappedIfSafe),
                                                                         imageConditions: Self.imageConditions(from: fact))
            if format == .json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                print(String(decoding: try encoder.encode(report), as: UTF8.self))
            } else {
                for layer in DicomValidationReport.Layer.allCases { print("\(layer.rawValue): \(report[layer].rawValue)") }
                for diagnostic in report.diagnostics { print("\(diagnostic.severity.rawValue) \(diagnostic.code.rawValue) \(diagnostic.path)") }
            }
            let outcome = report.outcome(requiring: Set(DicomValidationReport.Layer.allCases.filter { $0 != .operation }))
            if outcome == .failed { throw ExitCode.failure }
            if outcome != .passed { throw ExitCode(2) }
            return
        }

        // Perform validation using DCMDecoder
        let validationResult = Self.validatorFactory.value().validateDICOMFile(fileURL.path)

        // Separate errors and warnings.
        // Classification is heuristic-based (message text) until upstream
        // validation exposes structured severity levels.
        var errors: [String] = []
        var warnings: [String] = []

        for issue in validationResult.issues {
            if ValidationIssueClassifier.isWarning(issue) {
                warnings.append(issue)
            } else {
                errors.append(issue)
            }
        }

        // Create validation result
        let result = ValidationResult(
            isValid: validationResult.isValid,
            errors: errors,
            warnings: warnings
        )

        // Format and output
        let output = try formatter.formatValidation(result)
        print(output)

        // Exit with error code if validation failed
        if !result.isValid {
            throw ExitCode.failure
        }
    }
}
