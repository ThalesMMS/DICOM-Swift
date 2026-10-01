import Foundation

/// Classic image VOI requirements and source-value checks. Does not select a display
/// alternative or qualify the whole grayscale pipeline. Legacy LUT reading stays separate.
public enum DicomVOILUTModule {
    public static func applies(to dataSet: DicomDataSet) -> Bool {
        [0x00283010, 0x00281050, 0x00281051, 0x00281055, 0x00281056].contains(where: dataSet.contains)
    }

    public static func validate(_ dataSet: DicomDataSet, littleEndian: Bool = true,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        let mono = DicomAttributeRule.Condition.known(monochrome(dataSet))
        let attributes = DicomAttributeValidator.evaluate(dataSet, rules: [
            .init(tag: 0x00283010, requirement: .type1C, condition: .not(.present(0x00281050)), mayBePresentOtherwise: true,
                  itemRules: [.init(tag: 0x00283002, requirement: .type1, constraints: [.valueCount(3...3)]),
                              .init(tag: 0x00283006, requirement: .type1)], constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00281050, requirement: .type1C, condition: .not(.present(0x00283010)), mayBePresentOtherwise: true,
                  constraints: [.requiredCondition(mono)]),
            .init(tag: 0x00281051, requirement: .type1C, condition: .present(0x00281050), constraints: [.requiredCondition(mono)]),
            .init(tag: 0x00281056, requirement: .type3, constraints: [.requiredCondition(mono)])
        ], limits: limits)
        var state = State(report: attributes.report, remaining: limits.maximumRuleEvaluations - attributes.evaluations,
                          maximumDiagnostics: limits.maximumDiagnostics)
        guard !state.report.diagnostics.contains(where: { $0.code == .evaluationLimitReached }) else { return state.report }
        let function = function(dataSet)
        if dataSet.contains(0x00281056), function == nil { state.record(.valueUnavailable, path: [.tag(0x00281056)], limitation: true) }
        var counts: [Int: Int] = [:]
        for tag in [0x00281050, 0x00281051] {
            guard !state.stopped, let element = dataSet[tag] else { continue }
            guard element.vr == .DS, case .strings(let values) = element.value else {
                state.record(.valueUnavailable, path: [.tag(tag)], limitation: true); continue
            }
            guard state.consume(values.count, path: [.tag(tag)]) else { return state.report }
            if values.allSatisfy({ $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")).isEmpty }) { continue }
            counts[tag] = values.count
            for value in values {
                do {
                    let number = try DicomDecimalString.parse(value)
                    if tag == 0x00281051 {
                        if let function {
                            if function == "LINEAR" ? number < 1 : number <= 0 { state.record(.attributeValueContradiction, path: [.tag(tag)]) }
                        } else { state.record(.valueUnavailable, path: [.tag(tag)], limitation: true) }
                    }
                } catch DicomDecimalString.Failure.invalid { state.record(.invalidTextValue, path: [.tag(tag)]) }
                catch { state.record(.valueUnavailable, path: [.tag(tag)], limitation: true) }
                if state.stopped { return state.report }
            }
        }
        if let center = counts[0x00281050], let width = counts[0x00281051], center != width {
            state.record(.attributeValueContradiction, path: [.tag(0x00281051)])
        }
        if case .sequence(let items) = dataSet[0x00283010]?.value {
            for (index, item) in items.enumerated() {
                let path: [DicomValidationReport.PathComponent] = [.tag(0x00283010), .item(index)]
                guard state.consume(1, path: path) else { break }
                validateTable(item, expectedVR: DicomPixelValueContext(dataSet).voiInputVR, littleEndian: littleEndian, path: path, state: &state)
                if state.stopped { break }
            }
        }
        return state.report
    }

    static func validateTable(_ item: DicomSequenceItem, expectedVR: DicomVR?, littleEndian: Bool,
                                      path: [DicomValidationReport.PathComponent], state: inout State) {
        guard let descriptor = item.dataSet[0x00283002], [.US, .SS].contains(descriptor.vr),
              descriptor.vm.count == 3 else {
            state.record(.valueUnavailable, path: path + [.tag(0x00283002)], limitation: true); return
        }
        let words = descriptor.intValues
        guard words.count == 3, (0...65535).contains(words[0]), [8, 16].contains(words[2]),
              (descriptor.vr == .SS ? -32768...32767 : 0...65535).contains(words[1]) else {
            state.record(.attributeValueContradiction, path: path + [.tag(0x00283002)]); return
        }
        if let expected = expectedVR {
            if descriptor.vr != expected { state.record(.incompatibleVR, path: path + [.tag(0x00283002)]) }
        } else { state.record(.valueUnavailable, path: path + [.tag(0x00283002)], limitation: true) }
        guard let data = item.dataSet[0x00283006], [.US, .OW].contains(data.vr) else {
            state.record(.valueUnavailable, path: path + [.tag(0x00283006)], limitation: true); return
        }
        let entries = words[0] == 0 ? 65536 : words[0]
        guard state.consume(entries, path: path + [.tag(0x00283006)]) else { return }
        let actual: Int
        switch data.value {
        case .bytes(let bytes): actual = bytes.count
        case .unsignedIntegers(let values):
            guard values.count <= entries else { state.record(.invalidValueLength, path: path + [.tag(0x00283006)]); return }
            guard values.allSatisfy({ $0 <= 65535 }) else {
                state.record(.attributeValueContradiction, path: path + [.tag(0x00283006)]); return
            }
            actual = values.count * 2
        default:
            state.record(.valueUnavailable, path: path + [.tag(0x00283006)], limitation: true); return
        }
        let expected = words[2] == 16 ? entries * 2 : entries + entries % 2
        if actual != expected {
            if words[2] == 8, actual == entries * 2 {
                state.record(.moduleRuleUnavailable, path: path + [.tag(0x00283006)], limitation: true)
            } else { state.record(.invalidValueLength, path: path + [.tag(0x00283006)]); return }
        }
        if words[2] == 8, actual == expected, !littleEndian || data.vr == .US { state.record(.moduleRuleUnavailable, path: path + [.tag(0x00283006)], limitation: true) }
        guard !state.stopped else { return }
        // The existing reader can apply the checked table. Its truncation/legacy acceptance
        // is not used to approve extra original data or image-incompatible bit depths.
        let decoded = DicomVOILUTValidator.validate(items: [item], littleEndian: littleEndian)
        if !decoded.rejected.isEmpty { state.record(.attributeValueContradiction, path: path + [.tag(0x00283006)]) }
    }

    private static func monochrome(_ dataSet: DicomDataSet) -> DicomAttributeRule.Truth {
        guard let element = dataSet[0x00280004], element.vr == .CS,
              case .strings(let values) = element.value, values.count == 1, values[0].utf8.count <= 16 else { return .undetermined }
        let value = values[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
        guard !value.isEmpty else { return .undetermined }
        return ["MONOCHROME1", "MONOCHROME2"].contains(value) ? .satisfied : .unsatisfied
    }

    private static func function(_ dataSet: DicomDataSet) -> String? {
        guard let element = dataSet[0x00281056] else { return "LINEAR" }
        guard element.vr == .CS, case .strings(let values) = element.value, values.count == 1, values[0].utf8.count <= 16 else { return nil }
        let value = values[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
        return ["LINEAR", "LINEAR_EXACT", "SIGMOID"].contains(value) ? value : nil
    }

    struct State {
        var report: DicomValidationReport
        var remaining: Int
        let maximumDiagnostics: Int
        var stopped = false

        mutating func consume(_ work: Int, path: [DicomValidationReport.PathComponent]) -> Bool {
            guard !stopped else { return false }
            guard work <= remaining else { stop(path); return false }
            remaining -= work
            return true
        }
        mutating func record(_ code: DicomValidationReport.Code, path: [DicomValidationReport.PathComponent], limitation: Bool = false) {
            guard !stopped else { return }
            guard report.diagnostics.count < maximumDiagnostics else { stop(path); return }
            let requirement: DicomAttributeRule.Requirement?
            switch path.last {
            case .some(.tag(0x00283000)), .some(.tag(0x00281050)), .some(.tag(0x00281051)), .some(.tag(0x00283010)): requirement = .type1C
            case .some(.tag(0x00283002)), .some(.tag(0x00283006)): requirement = .type1
            case .some(.tag(0x00281056)): requirement = .type3
            default: requirement = nil
            }
            report = report.merging(.init(diagnostics: [.init(code: code, severity: limitation ? .limitation : .error,
                layer: .attributes, path: path, requirement: requirement)]))
        }
        mutating func stop(_ path: [DicomValidationReport.PathComponent]) {
            stopped = true
            report = report.merging(.init(diagnostics: [.init(code: .evaluationLimitReached, severity: .limitation, layer: .attributes, path: path)]))
        }
    }
}
