import Foundation

/// PS3.3 C.11.1. Composed for declared SC transforms; CT retains its own image rules.
public enum DicomModalityLUTModule {
    public static func applies(to dataSet: DicomDataSet) -> Bool {
        [0x00283000, 0x00281052, 0x00281053, 0x00281054].contains(where: dataSet.contains)
    }

    public static func validate(_ dataSet: DicomDataSet, littleEndian: Bool = true,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        let attributes = DicomAttributeValidator.evaluate(dataSet, rules: [
            .init(tag: 0x00283000, requirement: .type1C, condition: .not(.present(0x00281052)),
                  itemRules: [.init(tag: 0x00283002, requirement: .type1, constraints: [.valueCount(3...3)]),
                              .init(tag: 0x00283004, requirement: .type1), .init(tag: 0x00283006, requirement: .type1)],
                  constraints: [.itemCount(1...1), .forbiddenWhen(.present(0x00281053))]),
            .init(tag: 0x00281052, requirement: .type1C, condition: .not(.present(0x00283000)),
                  constraints: [.requiredCondition(.known(decimal(dataSet[0x00281052])))]),
            .init(tag: 0x00281053, requirement: .type1C, condition: .present(0x00281052), mayBePresentOtherwise: true,
                  constraints: [.requiredCondition(.known(decimal(dataSet[0x00281053])))]),
            .init(tag: 0x00281054, requirement: .type1C, condition: .present(0x00281052), mayBePresentOtherwise: true)
        ], limits: limits)
        var state = DicomVOILUTModule.State(report: attributes.report,
            remaining: limits.maximumRuleEvaluations - attributes.evaluations, maximumDiagnostics: limits.maximumDiagnostics)
        guard !state.report.diagnostics.contains(where: { $0.code == .evaluationLimitReached }) else { return state.report }
        let representation = dataSet[0x00280103]
        let expectedVR: DicomVR? = representation?.vr == .US && representation?.vm.count == 1
            ? (representation?.intValue == 0 ? .US : representation?.intValue == 1 ? .SS : nil) : nil
        if case .sequence(let items) = dataSet[0x00283000]?.value {
            for (index, item) in items.enumerated() {
                let path: [DicomValidationReport.PathComponent] = [.tag(0x00283000), .item(index)]
                guard state.consume(1, path: path) else { break }
                DicomVOILUTModule.validateTable(item, expectedVR: expectedVR, littleEndian: littleEndian, path: path, state: &state)
                if state.stopped { break }
            }
        }
        return state.report
    }

    private static func decimal(_ element: DicomDataElement?) -> DicomAttributeRule.Truth {
        guard let element else { return .satisfied }
        guard element.vr == .DS, case .strings(let values) = element.value else { return .undetermined }
        guard values.count == 1 else { return .unsatisfied }
        do { _ = try DicomDecimalString.parse(values[0]); return .satisfied }
        catch DicomDecimalString.Failure.invalid { return .unsatisfied }
        catch { return .undetermined }
    }
}
