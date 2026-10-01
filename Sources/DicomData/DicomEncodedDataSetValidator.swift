import Foundation

/// Composes framing and lexical evidence from the existing parser. Does not decode
/// pixels, infer absent IOD rules, or replace object-specific semantic validators.
public enum DicomEncodedDataSetValidator {
    /// Metadata may contain instance values; diagnostics never do. Cancellation and
    /// unexpected implementation errors propagate instead of becoming invalid-file reports.
    /// At most `maximumDiagnostics` ordinary diagnostics plus two terminal diagnostics are returned.
    public static func validate(_ data: Data, transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian,
                                limits: DicomDataSetParseLimits = .default,
                                privateDictionary: DicomPrivateDictionary = .standard,
                                dictionary: DCMDictionary = DCMDictionary(), maximumDiagnostics: Int = 128,
                                purpose: DicomDataSetPurpose = .instance) throws -> DicomDataSetValidationResult {
        let maximum = max(1, maximumDiagnostics)
        var state = DicomDataSetParseState(limits: limits, privateDictionary: privateDictionary,
            mode: .recover, maximumDiagnostics: maximum, resolvesContext: true, dictionary: dictionary, purpose: purpose)
        state.recordsValidationPaths = true
        let dataSet: DicomDataSet
        do {
            dataSet = try DicomDataSetParser.readDataSet(from: data, transferSyntax: transferSyntax, state: &state)
        } catch let diagnostic as DicomDataSetReadResult.Diagnostic {
            let issue = map(diagnostic)
            let interrupted: DicomValidationReport.Layer = issue.layer == .structure ? .vrAndVM : .structure
            return failure(state, terminal: [issue, .init(code: .validationInterrupted, severity: .limitation,
                                                          layer: interrupted, path: diagnostic.path)])
        } catch is DicomDataSetParseError {
            return failure(state, terminal: [.init(code: .evaluationLimitReached, severity: .limitation,
                                                   layer: .structure, path: state.structuralPath),
                                             .init(code: .validationInterrupted, severity: .limitation, layer: .vrAndVM)])
        } catch is DicomSequenceValueParserError {
            return failure(state, terminal: [.init(code: .invalidDataSetStructure, severity: .error,
                                                   layer: .structure, path: state.structuralPath),
                                             .init(code: .validationInterrupted, severity: .limitation, layer: .vrAndVM)])
        } catch let error as DicomDeflatedDataSetError {
            let limited: Bool
            if case .dataSetTooLarge = error { limited = true } else { limited = false }
            return failure(state, terminal: [.init(code: limited ? .evaluationLimitReached : .invalidDeflatedDataSet,
                severity: limited ? .limitation : .error, layer: .structure),
                .init(code: .validationInterrupted, severity: .limitation, layer: .vrAndVM)])
        }
        var diagnostics = state.diagnostics.map(map)
        var truncated = state.omittedPixelDataPathsTruncated
        func unavailable(_ path: [DicomValidationReport.PathComponent]) {
            if diagnostics.count < maximum {
                diagnostics.append(.init(code: .valueUnavailable, severity: .limitation, layer: .vrAndVM, path: path))
            } else { truncated = true }
        }
        for path in state.omittedPixelDataPaths { unavailable(path) }
        var pending: [(DicomDataSet, [DicomValidationReport.PathComponent])] = [(dataSet, [])]
        while let (item, path) = pending.popLast(), !truncated {
            try Task.checkCancellation()
            for element in item.elements {
                let location = path + [.tag(element.tag)]
                if element.vr == .UN || (dictionary.definition(forTag: element.tag) == nil
                    && !DicomPrivateDictionary.isCreatorTag(element.tag)) {
                    unavailable(location)
                }
                if truncated { break }
                if case .sequence(let items) = element.value {
                    for (index, child) in items.enumerated().reversed() {
                        pending.append((child.dataSet, location + [.item(index)]))
                    }
                }
            }
        }
        if truncated {
            diagnostics.append(.init(code: .evaluationLimitReached, severity: .limitation, layer: .vrAndVM))
        }
        try Task.checkCancellation()
        return .init(dataSet: dataSet, report: .init(evaluatedLayers: [.structure, .vrAndVM], diagnostics: diagnostics),
                     purpose: purpose, pixelDataHeaders: state.pixelDataHeaders,
                     pixelDataHeadersTruncated: state.pixelDataHeadersTruncated)
    }

    private static func failure(_ state: DicomDataSetParseState,
                                terminal: [DicomValidationReport.Diagnostic]) -> DicomDataSetValidationResult {
        .init(dataSet: nil, report: .init(diagnostics: state.diagnostics.map(map) + terminal), purpose: state.purpose)
    }

    private static func map(_ diagnostic: DicomDataSetReadResult.Diagnostic) -> DicomValidationReport.Diagnostic {
        let code: DicomValidationReport.Code
        var severity = DicomValidationReport.Severity.error
        var layer = DicomValidationReport.Layer.vrAndVM
        switch diagnostic.reason {
        case .invalidTextEncoding: code = .invalidTextEncoding
        case .invalidTextValue: code = .invalidTextValue
        case .unsupportedCharacterSet:
            code = .unsupportedCharacterSet
            severity = .limitation
        case .invalidBinaryLength: code = .invalidBinaryLength
        case .invalidValueLength: code = .invalidValueLength
        case .invalidMultiplicity: code = .invalidMultiplicity
        case .invalidPrivateCreator: code = .invalidPrivateCreator
        case .duplicatePrivateCreator:
            code = .duplicatePrivateCreator
            layer = .structure
        case .duplicateElement:
            code = .duplicateElement
            layer = .structure
        case .ambiguousVR:
            code = .ambiguousVR
            severity = .limitation
        case .incompatibleVR: code = .incompatibleVR
        }
        return .init(code: code, severity: severity, layer: layer, path: diagnostic.path)
    }
}
