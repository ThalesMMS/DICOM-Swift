//
//  DicomCodecWorkflowEngine.swift
//  DicomCore
//
//  Shared in-memory codec workflow surface for apps, dicomtool, tests, and automation.
//

import Foundation

/// Shared in-memory codec, validation, comparison, and transcoding engine.
public struct DicomCodecWorkflowEngine: Sendable {
    /// Creates a stateless codec workflow engine.
    public init() {}

    /// Reports every registered codec backend and its live process capability.
    public func capabilities(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DicomCodecStructuredReport {
        DicomCodecStructuredReport(
            operation: .capabilities,
            success: true,
            backends: DicomCodecCapabilities.backendStatuses(environment: environment).map {
                backend($0, role: .available, selected: false)
            }
        )
    }

    /// Inspects pixel attributes, encapsulation, and eligible backends without decoding frames.
    public func inspect(
        _ data: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DicomCodecStructuredReport {
        let decoder = try makeDecoder(data)
        return report(
            operation: .inspect,
            decoder: decoder,
            environment: environment,
            validateEncapsulation: false
        )
    }

    /// Validates pixel attributes, encapsulation, offset tables, and declared frame mapping.
    public func validate(
        _ data: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DicomCodecStructuredReport {
        let decoder = try makeDecoder(data)
        return report(
            operation: .validate,
            decoder: decoder,
            environment: environment,
            validateEncapsulation: true
        )
    }

    /// Decodes selected or all frames into a contiguous in-memory pixel artifact.
    public func decode(
        _ data: Data,
        frameIndexes: [Int]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> DicomCodecArtifactResult {
        let decoder = try makeDecoder(data)
        let reader = DicomDecodedFrameReader(decoder: decoder)
        let indexes = frameIndexes ?? Array(0..<reader.frameCount)
        guard !indexes.isEmpty else {
            throw DicomCodecWorkflowError.invalidDICOM(reason: "The object has no addressable pixel frames.")
        }

        var decodedData = Data()
        var frameReports: [DicomCodecStructuredReport.Frame] = []
        var backendReports: [DicomCodecStructuredReport.Backend] = []
        for index in indexes {
            guard index >= 0, index < reader.frameCount else {
                throw DicomCodecWorkflowError.invalidFrameIndex(index: index, frameCount: reader.frameCount)
            }
            let execution: DicomDecodedFrameExecution
            do {
                execution = try await reader.frameExecution(at: index, environment: environment)
            } catch {
                throw mapReadError(error, frameIndex: index, sourceUID: decoder.transferSyntaxUID)
            }
            let bytes = pixelData(execution.frame.pixels)
            decodedData.append(bytes)
            frameReports.append(frame(execution.frame, bytes: bytes))
            appendBackend(execution, to: &backendReports)
        }

        let artifact = DicomCodecStructuredReport.Artifact(
            mediaType: "application/vnd.dicom.decoded-pixels",
            byteCount: decodedData.count,
            contentHash: stableHash(decodedData),
            transferSyntaxUID: nil,
            validationPassed: true,
            comparisonMode: nil,
            comparisonPassed: nil
        )
        let report = DicomCodecStructuredReport(
            operation: .decode,
            success: true,
            sourceObject: object(decoder),
            backends: backendReports,
            frames: frameReports,
            encapsulation: encapsulation(decoder, validatesDeclaredCount: true).value,
            artifact: artifact
        )
        return DicomCodecArtifactResult(data: decodedData, report: report)
    }

    /// Compares candidate and oracle decoded pixels for a JPEG-LS, JPEG 2000, or HTJ2K frame.
    public func compare(
        _ data: Data,
        frameIndex: Int = 0,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> DicomCodecStructuredReport {
        let decoder = try makeDecoder(data)
        guard let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID),
              let family = DicomCodecFamily.family(for: syntax),
              family == .jpeg2000 || family == .htj2k || family == .jpegLS else {
            throw DicomCodecWorkflowError.unsupported(
                sourceUID: decoder.transferSyntaxUID,
                targetUID: nil,
                reasons: ["Candidate/oracle comparison is available for JPEG 2000, HTJ2K, and JPEG-LS frames."]
            )
        }

        var candidateEnvironment = environment
        var oracleEnvironment = environment
        if family == .jpegLS {
            candidateEnvironment[DicomJLSwiftRolloutMode.environmentKey] =
                DicomJLSwiftRolloutMode.forcedForTests.rawValue
            oracleEnvironment[DicomJLSwiftRolloutMode.environmentKey] = DicomJLSwiftRolloutMode.disabled.rawValue
        } else {
            candidateEnvironment[DicomJ2KSwiftRolloutMode.environmentKey] =
                DicomJ2KSwiftRolloutMode.forcedForTests.rawValue
            oracleEnvironment[DicomJ2KSwiftRolloutMode.environmentKey] = DicomJ2KSwiftRolloutMode.disabled.rawValue
        }

        let reader = DicomDecodedFrameReader(decoder: decoder)
        guard frameIndex >= 0, frameIndex < reader.frameCount else {
            throw DicomCodecWorkflowError.invalidFrameIndex(index: frameIndex, frameCount: reader.frameCount)
        }
        let candidate: DicomDecodedFrameExecution
        let oracle: DicomDecodedFrameExecution
        do {
            candidate = try await reader.frameExecution(at: frameIndex, environment: candidateEnvironment)
            oracle = try await reader.frameExecution(at: frameIndex, environment: oracleEnvironment)
        } catch {
            throw mapReadError(error, frameIndex: frameIndex, sourceUID: decoder.transferSyntaxUID)
        }
        let candidateData = pixelData(candidate.frame.pixels)
        let oracleData = pixelData(oracle.frame.pixels)
        let matches = candidate.frame.metadata.width == oracle.frame.metadata.width
            && candidate.frame.metadata.height == oracle.frame.metadata.height
            && candidateData == oracleData
        let artifact = DicomCodecStructuredReport.Artifact(
            mediaType: "application/vnd.dicom.decoded-pixels",
            byteCount: candidateData.count,
            contentHash: stableHash(candidateData),
            transferSyntaxUID: nil,
            validationPassed: true,
            comparisonMode: "exact-decoded-pixels",
            comparisonPassed: matches
        )
        return DicomCodecStructuredReport(
            operation: .compare,
            success: matches,
            sourceObject: object(decoder),
            backends: [
                backend(candidate, role: .candidate),
                backend(oracle, role: .oracle)
            ],
            frames: [frame(candidate.frame, bytes: candidateData)],
            encapsulation: encapsulation(decoder, validatesDeclaredCount: true).value,
            artifact: artifact,
            diagnostics: matches ? [] : [
                .init(
                    severity: .error,
                    code: "codec.shadow.mismatch",
                    message: "Candidate and oracle decoded pixels differ."
                )
            ]
        )
    }

    /// Transcodes a complete Part 10 object and validates the generated in-memory artifact.
    public func transcode(
        _ data: Data,
        to destination: DicomTransferSyntax,
        intent: DicomEncodingIntent = .reversible,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        verifyDecodedPixels: Bool = true
    ) async throws -> DicomCodecArtifactResult {
        let decoder = try makeDecoder(data)
        let source = DicomTransferSyntax(uid: decoder.transferSyntaxUID) ?? .explicitVRLittleEndian
        let plan = DicomTransferSyntaxRegistry.standard.transcodePlan(from: source, to: destination)
        let output: Data
        do {
            output = try await DicomTranscoder().transcode(data, to: destination, intent: intent)
        } catch let error as DicomTranscoder.TranscodeError {
            throw mapTranscodeError(error)
        } catch {
            throw DicomCodecWorkflowError.artifactValidation(reason: error.localizedDescription)
        }

        let outputDecoder = try makeDecoder(output)
        guard outputDecoder.transferSyntaxUID == destination.rawValue else {
            throw DicomCodecWorkflowError.artifactValidation(
                reason: "The output declares transfer syntax \(outputDecoder.transferSyntaxUID), "
                    + "expected \(destination.rawValue)."
            )
        }
        let outputEncapsulation = encapsulation(outputDecoder, validatesDeclaredCount: true)
        let outputPixelDiagnostics = pixelDiagnostics(outputDecoder)
        guard outputEncapsulation.valid,
              !outputPixelDiagnostics.contains(where: { $0.severity == .error }) else {
            throw DicomCodecWorkflowError.artifactValidation(
                reason: (outputEncapsulation.diagnostics + outputPixelDiagnostics)
                    .map(\.message)
                    .joined(separator: " ")
            )
        }

        var comparisonMode: String?
        var comparisonPassed: Bool?
        if verifyDecodedPixels {
            let sourceFrames = try await decode(data, environment: environment)
            let outputFrames = try await decode(output, environment: environment)
            comparisonMode = intent.isLossy ? "decoded-shape" : "exact-decoded-pixels"
            comparisonPassed = intent.isLossy
                ? sourceFrames.report.frames.map { [$0.width, $0.height, $0.componentCount] }
                    == outputFrames.report.frames.map { [$0.width, $0.height, $0.componentCount] }
                : sourceFrames.data == outputFrames.data
            guard comparisonPassed == true else {
                throw DicomCodecWorkflowError.artifactValidation(
                    reason: "Decoded source/output comparison failed in \(comparisonMode ?? "unspecified") mode."
                )
            }
        }

        var backends: [DicomCodecStructuredReport.Backend] = []
        if let encoder = DicomCodecCapabilities.backendStatuses(environment: environment).first(where: {
            $0.isAvailable && $0.encodeTransferSyntaxUIDs.contains(destination.rawValue)
        }) {
            backends.append(backend(encoder, role: .encoder, selected: true))
        }
        let artifact = DicomCodecStructuredReport.Artifact(
            mediaType: "application/dicom",
            byteCount: output.count,
            contentHash: stableHash(output),
            transferSyntaxUID: destination.rawValue,
            validationPassed: true,
            comparisonMode: comparisonMode,
            comparisonPassed: comparisonPassed
        )
        let diagnostics = plan.diagnostics.map {
            DicomCodecStructuredReport.Diagnostic(
                severity: diagnosticSeverity($0.severity),
                code: "codec.transcode.plan",
                message: $0.message
            )
        }
        let report = DicomCodecStructuredReport(
            operation: .transcode,
            success: true,
            sourceObject: object(decoder),
            targetTransferSyntaxUID: destination.rawValue,
            transcodeRoute: routeName(plan.route),
            backends: backends,
            encapsulation: outputEncapsulation.value,
            artifact: artifact,
            diagnostics: diagnostics
        )
        return DicomCodecArtifactResult(data: output, report: report)
    }

    private func makeDecoder(_ data: Data) throws -> DCMDecoder {
        guard !data.isEmpty else {
            throw DicomCodecWorkflowError.invalidDICOM(reason: "The input is empty.")
        }
        let decoder: DCMDecoder
        do {
            decoder = try DCMDecoder(data: data)
        } catch {
            throw DicomCodecWorkflowError.invalidDICOM(reason: error.localizedDescription)
        }
        guard decoder.fileReadSucceeded else {
            throw DicomCodecWorkflowError.invalidDICOM(reason: "The Part 10 file or dataset could not be parsed.")
        }
        return decoder
    }

    private func report(
        operation: DicomCodecStructuredReport.Operation,
        decoder: DCMDecoder,
        environment: [String: String],
        validateEncapsulation: Bool
    ) -> DicomCodecStructuredReport {
        let validation = encapsulation(decoder, validatesDeclaredCount: validateEncapsulation)
        let diagnostics = pixelDiagnostics(decoder) + validation.diagnostics
        let valid = validation.valid && !diagnostics.contains { $0.severity == .error }
        let statuses = DicomCodecCapabilities.backendStatuses(environment: environment).filter {
            $0.decodeTransferSyntaxUIDs.contains(decoder.transferSyntaxUID)
        }
        return DicomCodecStructuredReport(
            operation: operation,
            success: valid,
            sourceObject: object(decoder),
            backends: statuses.map { backend($0, role: .available, selected: false) },
            encapsulation: validation.value,
            diagnostics: diagnostics
        )
    }

    private func pixelDiagnostics(_ decoder: DCMDecoder) -> [DicomCodecStructuredReport.Diagnostic] {
        var diagnostics: [DicomCodecStructuredReport.Diagnostic] = []
        func append(_ condition: Bool, code: String, message: String) {
            if condition {
                diagnostics.append(.init(severity: .error, code: code, message: message))
            }
        }
        let bitsAllocated = decoder.bitDepth
        let bitsStored = decoder.intValue(for: Int(DicomTag.bitsStored.rawValue)) ?? bitsAllocated
        append(decoder.width <= 0, code: "codec.pixel.columns", message: "Columns must be greater than zero.")
        append(decoder.height <= 0, code: "codec.pixel.rows", message: "Rows must be greater than zero.")
        append(bitsAllocated <= 0, code: "codec.pixel.bits-allocated", message: "Bits Allocated must be positive.")
        append(
            bitsStored <= 0 || bitsStored > bitsAllocated,
            code: "codec.pixel.bits-stored",
            message: "Bits Stored must be positive and no greater than Bits Allocated."
        )
        append(
            decoder.pixelRepresentationTagValue != 0 && decoder.pixelRepresentationTagValue != 1,
            code: "codec.pixel.representation",
            message: "Pixel Representation must be zero or one."
        )
        append(
            decoder.samplesPerPixel <= 0,
            code: "codec.pixel.samples",
            message: "Samples Per Pixel must be greater than zero."
        )
        append(
            decoder.photometricInterpretation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            code: "codec.pixel.photometric",
            message: "Photometric Interpretation is required."
        )
        append(
            DicomDecodedFrameReader(decoder: decoder).frameCount <= 0,
            code: "codec.pixel.frames",
            message: "The object has no addressable pixel frames."
        )
        return diagnostics
    }

    private func object(_ decoder: DCMDecoder) -> DicomCodecStructuredReport.Object {
        let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID) ?? .explicitVRLittleEndian
        let bitsAllocated = decoder.bitDepth
        let bitsStored = decoder.intValue(for: Int(DicomTag.bitsStored.rawValue)) ?? bitsAllocated
        let frameCount = DicomDecodedFrameReader(decoder: decoder).frameCount
        return DicomCodecStructuredReport.Object(
            transferSyntaxUID: decoder.transferSyntaxUID,
            rows: decoder.height,
            columns: decoder.width,
            bitsAllocated: bitsAllocated,
            bitsStored: bitsStored,
            pixelRepresentation: decoder.pixelRepresentationTagValue,
            samplesPerPixel: decoder.samplesPerPixel,
            photometricInterpretation: decoder.photometricInterpretation,
            frameCount: frameCount,
            compressed: syntax.registryEntry.isCompressed,
            encapsulated: syntax.registryEntry.isEncapsulated
        )
    }

    private func encapsulation(
        _ decoder: DCMDecoder,
        validatesDeclaredCount: Bool
    ) -> (
        value: DicomCodecStructuredReport.Encapsulation?,
        valid: Bool,
        diagnostics: [DicomCodecStructuredReport.Diagnostic]
    ) {
        guard decoder.compressedImage else { return (nil, true, []) }
        do {
            let reader = try decoder.makeEncapsulatedPixelFrameReader()
            if validatesDeclaredCount {
                try reader.validateDeclaredFrameCount()
            }
            let parserDiagnostics = reader.diagnostics.map {
                DicomCodecStructuredReport.Diagnostic(
                    severity: $0.severity == .error ? .error : .warning,
                    code: "codec.encapsulation.parser",
                    message: $0.message
                )
            }
            let valid = !parserDiagnostics.contains { $0.severity == .error }
            return (
                DicomCodecStructuredReport.Encapsulation(
                    valid: valid,
                    declaredFrameCount: reader.declaredNumberOfFrames,
                    mappedFrameCount: reader.frameCount,
                    fragmentCount: reader.descriptor.fragments.count,
                    basicOffsetCount: reader.descriptor.basicOffsetTable.offsets.count,
                    extendedOffsetCount: reader.descriptor.extendedOffsetTable?.offsets.count ?? 0
                ),
                valid,
                parserDiagnostics
            )
        } catch {
            let diagnostic = DicomCodecStructuredReport.Diagnostic(
                severity: .error,
                code: "codec.encapsulation.invalid",
                message: error.localizedDescription
            )
            return (
                DicomCodecStructuredReport.Encapsulation(
                    valid: false,
                    declaredFrameCount: max(1, decoder.nImages),
                    mappedFrameCount: 0,
                    fragmentCount: 0,
                    basicOffsetCount: 0,
                    extendedOffsetCount: 0
                ),
                false,
                [diagnostic]
            )
        }
    }

    private func backend(
        _ status: DicomCodecBackendStatus,
        role: DicomCodecStructuredReport.Backend.Role,
        selected: Bool
    ) -> DicomCodecStructuredReport.Backend {
        DicomCodecStructuredReport.Backend(
            identifier: status.identifier,
            role: role,
            version: status.version,
            source: status.source.rawValue,
            available: status.isAvailable,
            selected: selected,
            rolloutMode: nil,
            reason: status.isAvailable ? nil : "Backend is unavailable in this process.",
            decodeTransferSyntaxUIDs: status.decodeTransferSyntaxUIDs,
            encodeTransferSyntaxUIDs: status.encodeTransferSyntaxUIDs
        )
    }

    private func backend(
        _ execution: DicomDecodedFrameExecution,
        role: DicomCodecStructuredReport.Backend.Role = .production
    ) -> DicomCodecStructuredReport.Backend {
        DicomCodecStructuredReport.Backend(
            identifier: execution.backendIdentifier,
            role: role,
            version: execution.backendVersion,
            source: execution.backendSource.rawValue,
            available: execution.backendSource != .unavailable,
            selected: true,
            rolloutMode: execution.rolloutMode,
            reason: execution.fallbackReason,
            decodeTransferSyntaxUIDs: [execution.frame.metadata.transferSyntaxUID],
            encodeTransferSyntaxUIDs: []
        )
    }

    private func appendBackend(
        _ execution: DicomDecodedFrameExecution,
        to reports: inout [DicomCodecStructuredReport.Backend]
    ) {
        if !reports.contains(where: { $0.identifier == execution.backendIdentifier && $0.role == .production }) {
            reports.append(backend(execution))
        }
        if let shadow = execution.shadowBackendIdentifier,
           !reports.contains(where: { $0.identifier == shadow && $0.role == .shadow }) {
            reports.append(DicomCodecStructuredReport.Backend(
                identifier: shadow,
                role: .shadow,
                version: nil,
                source: DicomCodecBackendSource.packageLinked.rawValue,
                available: true,
                selected: false,
                rolloutMode: execution.rolloutMode,
                reason: nil,
                decodeTransferSyntaxUIDs: [execution.frame.metadata.transferSyntaxUID],
                encodeTransferSyntaxUIDs: []
            ))
        }
    }

    private func frame(
        _ frame: DicomDecodedFrame,
        bytes: Data
    ) -> DicomCodecStructuredReport.Frame {
        DicomCodecStructuredReport.Frame(
            index: frame.index,
            width: frame.metadata.width,
            height: frame.metadata.height,
            bitsPerSample: frame.metadata.bitsStored,
            componentCount: frame.metadata.samplesPerPixel,
            pixelByteCount: bytes.count,
            pixelHash: stableHash(bytes)
        )
    }

    private func pixelData(_ pixels: DicomDecodedFramePixelBuffer) -> Data {
        switch pixels {
        case .gray8(let values), .rgb8(let values):
            return Data(values)
        case .gray16(let values):
            var data = Data(capacity: values.count * MemoryLayout<UInt16>.size)
            for value in values {
                var littleEndian = value.littleEndian
                withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
            }
            return data
        }
    }

    private func stableHash(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(format: "fnv1a64:%016llx", hash)
    }

    private func mapReadError(
        _ error: Error,
        frameIndex: Int,
        sourceUID: String
    ) -> DicomCodecWorkflowError {
        guard let readError = error as? DicomDecodedFrameReader.ReadError else {
            return .corruptFrame(index: frameIndex, reason: error.localizedDescription)
        }
        switch readError {
        case .noPixelData:
            return .invalidDICOM(reason: readError.localizedDescription)
        case .frameIndexOutOfRange(let index, let count):
            return .invalidFrameIndex(index: index, frameCount: count)
        case .unsupportedTransferSyntax(_, let diagnostics):
            return .unsupported(sourceUID: sourceUID, targetUID: nil, reasons: diagnostics)
        case .unusableEncapsulation(let diagnostics):
            return .corruptFrame(index: frameIndex, reason: diagnostics.joined(separator: " "))
        case .decodeFailed(_, let reason):
            return .corruptFrame(index: frameIndex, reason: reason)
        }
    }

    private func mapTranscodeError(_ error: DicomTranscoder.TranscodeError) -> DicomCodecWorkflowError {
        switch error {
        case .routeUnsupported(let source, let destination, let diagnostics):
            return .unsupported(sourceUID: source, targetUID: destination, reasons: diagnostics)
        case .decodeFailed(let source, let reason):
            return .unsupported(sourceUID: source, targetUID: nil, reasons: [reason])
        case .unsupportedPixelShape(let reason):
            return .unsupported(sourceUID: "unknown", targetUID: nil, reasons: [reason])
        case .encodeFailed(_, let frameIndex, let reason):
            return .corruptFrame(index: frameIndex, reason: reason)
        }
    }

    private func routeName(_ route: DicomTranscodeRoute) -> String {
        switch route {
        case .passThrough: return "pass-through"
        case .rewriteNative: return "rewrite-native"
        case .reference: return "reference"
        case .decompress: return "decompress"
        case .compress: return "compress"
        case .recompress: return "recompress"
        }
    }

    private func diagnosticSeverity(
        _ severity: DicomTranscodeDiagnosticSeverity
    ) -> DicomCodecStructuredReport.Diagnostic.Severity {
        switch severity {
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        }
    }
}
