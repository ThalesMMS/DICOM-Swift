import Foundation
import XCTest
@testable import DicomData

final class DicomAttributeValidatorTests: XCTestCase {
    private let patientName = 0x00100010
    private let sequence = 0x0040A730
    private let valueType = 0x0040A040

    func test_evaluationCount_includesNestedRulesAndConstraintsWithoutExceedingBudget() {
        let child = DicomDataSet(elements: [.init(tag: valueType, vr: .CS, value: .strings(["TEXT"]))])
        let dataSet = DicomDataSet(elements: [.init(tag: sequence, vr: .SQ, value: .sequence([.init(dataSet: child)]))])
        let rules: [DicomAttributeRule] = [.init(tag: sequence, requirement: .type1,
            itemRules: [.init(tag: valueType, requirement: .type1)], constraints: [.itemCount(1...1)])]
        let complete = DicomAttributeValidator.evaluate(dataSet, rules: rules)
        XCTAssertEqual(complete.evaluations, 3)
        XCTAssertEqual(complete.report, DicomAttributeValidator.validate(dataSet, rules: rules))
        let limited = DicomAttributeValidator.evaluate(dataSet, rules: rules, limits: .init(maximumRuleEvaluations: 2))
        XCTAssertEqual(limited.evaluations, 2)
        XCTAssertEqual(limited.report[.attributes], .incomplete)
        XCTAssertEqual(limited.report.diagnostics.first?.path, [.tag(sequence), .item(0), .tag(valueType)])
    }

    func test_requiredTypes_distinguishAbsentEmptyAndPopulatedValues() {
        for requirement in [DicomAttributeRule.Requirement.type1, .type2, .type3] {
            let rule = DicomAttributeRule(tag: patientName, requirement: requirement)
            let absent = validate([], rules: [rule])
            XCTAssertEqual(absent[.attributes], requirement == .type3 ? .passed : .failed)
            for value in [DicomDataValue.empty, .strings([]), .strings(["", ""]), .strings(["^^^=="]) ] {
                let empty = validate([.init(tag: patientName, vr: .PN, value: value)], rules: [rule])
                XCTAssertEqual(empty[.attributes], requirement == .type1 ? .failed : .passed)
            }
            XCTAssertEqual(validate([.init(tag: patientName, vr: .PN, value: .strings(["SYNTHETIC"]))],
                                    rules: [rule])[.attributes], .passed)
        }
    }

    func test_conditionalTypes_evaluateTrueFalseUnknownAndOtherwiseException() {
        for requirement in [DicomAttributeRule.Requirement.type1C, .type2C] {
            let rule = DicomAttributeRule(tag: patientName, requirement: requirement,
                                          condition: .stringEquals(valueType, "PNAME"))
            let trueValue = DicomDataElement(tag: valueType, vr: .CS, value: .strings(["PNAME"]))
            let falseValue = DicomDataElement(tag: valueType, vr: .CS, value: .strings(["TEXT"]))
            let emptyName = DicomDataElement(tag: patientName, vr: .PN, value: .empty)
            XCTAssertEqual(validate([trueValue], rules: [rule]).diagnostics.first?.code, .requiredAttributeMissing)
            XCTAssertEqual(validate([trueValue, emptyName], rules: [rule])[.attributes],
                           requirement == .type1C ? .failed : .passed)
            XCTAssertEqual(validate([falseValue], rules: [rule])[.attributes], .passed)
            XCTAssertEqual(validate([falseValue, emptyName], rules: [rule]).diagnostics.first?.code,
                           .conditionalAttributeForbidden)
            XCTAssertEqual(validate([], rules: [rule])[.attributes], .incomplete)
            XCTAssertEqual(validate([emptyName], rules: [rule])[.attributes], .incomplete)
            let otherwise = DicomAttributeRule(tag: patientName, requirement: requirement,
                                               condition: .stringEquals(valueType, "PNAME"), mayBePresentOtherwise: true)
            XCTAssertEqual(validate([falseValue, emptyName], rules: [otherwise])[.attributes], .passed)
            let missingCondition = DicomAttributeRule(tag: patientName, requirement: requirement)
            XCTAssertEqual(validate([], rules: [missingCondition])[.attributes], .incomplete)
        }
    }

    func test_conditions_useThreeValuedLogicAndDoNotReadOpaqueValues() {
        typealias Condition = DicomAttributeRule.Condition
        let dataSet = DicomDataSet(elements: [
            .init(tag: valueType, vr: .CS, value: .strings(["CODE", "PNAME"])),
            .init(tag: 0x00280002, vr: .US, value: .unsignedIntegers([3]))
        ])
        XCTAssertEqual(Condition.stringEquals(valueType, "PNAME").evaluate(in: dataSet), .satisfied)
        XCTAssertEqual(Condition.integerGreaterThan(0x00280002, 1).evaluate(in: dataSet), .satisfied)
        XCTAssertEqual(Condition.integerGreaterThan(patientName, 1).evaluate(in: dataSet), .undetermined)
        XCTAssertEqual(Condition.all([.undetermined, .present(patientName)]).evaluate(in: dataSet), .unsatisfied)
        XCTAssertEqual(Condition.any([.undetermined, .present(valueType)]).evaluate(in: dataSet), .satisfied)
        XCTAssertEqual(Condition.not(.undetermined).evaluate(in: dataSet), .undetermined)
        XCTAssertEqual(Condition.all([]).evaluate(in: dataSet), .undetermined)
        XCTAssertEqual(Condition.any([]).evaluate(in: dataSet), .undetermined)
        let opaque = DicomDataSet(elements: [.init(tag: valueType, vr: .UN, value: .bytes(Data("PNAME".utf8)))])
        XCTAssertEqual(Condition.stringEquals(valueType, "PNAME").evaluate(in: opaque), .undetermined)
    }

    func test_sequenceRules_keepItemPathsAndEvaluateConditionsInEachItem() {
        let rule = DicomAttributeRule(tag: sequence, requirement: .type1, itemRules: [
            .init(tag: patientName, requirement: .type1C, condition: .stringEquals(valueType, "PNAME"))
        ])
        let items: [DicomSequenceItem] = [
            .init(dataSet: .init(elements: [.init(tag: valueType, vr: .CS, value: .strings(["TEXT"]))])),
            .init(dataSet: .init(elements: [.init(tag: valueType, vr: .CS, value: .strings(["PNAME"]))]))
        ]
        let report = validate([.init(tag: sequence, vr: .SQ, value: .sequence(items))], rules: [rule])
        XCTAssertEqual(report.diagnostics.count, 1)
        XCTAssertEqual(report.diagnostics[0].path, [.tag(sequence), .item(1), .tag(patientName)])
        XCTAssertEqual(report.diagnostics[0].requirement, .type1C)
        XCTAssertEqual(report.diagnostics[0].code, .requiredAttributeMissing)
    }

    func test_sequenceRequirement_checksItemsSeparatelyFromSequencePresence() {
        let child = DicomAttributeRule(tag: patientName, requirement: .type2)
        for requirement in [DicomAttributeRule.Requirement.type1, .type2] {
            let rule = DicomAttributeRule(tag: sequence, requirement: requirement, itemRules: [child])
            XCTAssertEqual(validate([.init(tag: sequence, vr: .SQ, value: .sequence([]))], rules: [rule])[.attributes],
                           requirement == .type1 ? .failed : .passed)
            let emptyItem = DicomSequenceItem(dataSet: .init(elements: []))
            let report = validate([.init(tag: sequence, vr: .SQ, value: .sequence([emptyItem]))], rules: [rule])
            XCTAssertEqual(report.diagnostics.first?.code, .requiredAttributeMissing)
            XCTAssertEqual(report.diagnostics.first?.path, [.tag(sequence), .item(0), .tag(patientName)])
        }
    }

    func test_typeOne_doesNotTreatZeroOrTextDelimitersAsEmptyOrOpaqueAsVerified() {
        let samples = DicomAttributeRule(tag: 0x00280002, requirement: .type1)
        XCTAssertEqual(validate([.init(tag: samples.tag, vr: .US, value: .unsignedIntegers([0]))],
                                rules: [samples])[.attributes], .passed)
        let text = DicomAttributeRule(tag: 0x0040A160, requirement: .type1)
        XCTAssertEqual(validate([.init(tag: text.tag, vr: .UT, value: .strings(["\\"]))],
                                rules: [text])[.attributes], .passed)
        XCTAssertEqual(validate([.init(tag: text.tag, vr: .UN, value: .bytes(Data([1])))],
                                rules: [text])[.attributes], .incomplete)
    }

    func test_limits_stopEvaluationWithoutClaimingSuccessOrUnboundedDiagnostics() {
        let rules = [DicomAttributeRule(tag: patientName, requirement: .type2),
                     DicomAttributeRule(tag: valueType, requirement: .type2)]
        let empty = DicomDataSet(elements: [])
        let zero = DicomAttributeValidator.validate(empty, rules: rules, limits: .init(maximumRuleEvaluations: 0))
        XCTAssertEqual(zero[.attributes], .incomplete)
        XCTAssertEqual(zero.diagnostics.map(\.code), [.evaluationLimitReached])
        let limited = DicomAttributeValidator.validate(empty, rules: rules, limits: .init(maximumDiagnostics: 1))
        XCTAssertEqual(limited[.attributes], .failed)
        XCTAssertEqual(limited.diagnostics.map(\.code), [.requiredAttributeMissing, .evaluationLimitReached])
        let nested = DicomAttributeRule(tag: sequence, requirement: .type1, itemRules: rules)
        let dataSet = DicomDataSet(elements: [.init(tag: sequence, vr: .SQ,
            value: .sequence([.init(dataSet: empty)]))])
        XCTAssertEqual(DicomAttributeValidator.validate(dataSet, rules: [nested],
            limits: .init(maximumDepth: 0))[.attributes], .incomplete)
    }

    func test_reports_preserveFailuresAndUnevaluatedLayersAndContainNoInstanceValues() throws {
        let marker = "SYNTHETIC_PRIVATE_VALUE"
        let rule = DicomAttributeRule(tag: patientName, requirement: .type2C,
                                      condition: .present(valueType))
        let report = validate([.init(tag: patientName, vr: .PN, value: .strings([marker]))], rules: [rule])
        XCTAssertEqual(report[.attributes], .failed)
        XCTAssertEqual(report[.structure], .notEvaluated)
        XCTAssertEqual(report[.operation], .notEvaluated)
        XCTAssertEqual(report.outcome(requiring: [.attributes, .structure]), .failed)
        let encoded = try JSONEncoder().encode(report.diagnostics)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(marker))
        let passed = DicomValidationReport(evaluatedLayers: [.structure])
        XCTAssertEqual(passed.outcome(requiring: [.structure, .attributes]), .incomplete)
        XCTAssertEqual(passed.outcome(requiring: []), .incomplete)
        XCTAssertEqual(passed.merging(report)[.attributes], .failed)
        XCTAssertEqual(passed.merging(report)[.structure], .passed)
        XCTAssertEqual(validate([], rules: [])[.attributes], .incomplete)
    }

    func test_diagnosticLimit_appliesWithinOneMalformedSequenceRule() {
        let rule = DicomAttributeRule(tag: sequence, requirement: .type1C,
            condition: .undetermined, itemRules: [.init(tag: patientName, requirement: .type1)])
        let malformed = DicomDataSet(elements: [.init(tag: sequence, vr: .UN, value: .bytes(Data([1])))])
        let report = DicomAttributeValidator.validate(malformed, rules: [rule], limits: .init(maximumDiagnostics: 1))
        XCTAssertEqual(report.diagnostics.map(\.code), [.conditionUndetermined, .evaluationLimitReached])
        XCTAssertEqual(report[.attributes], .incomplete)
    }

    func test_conditionLimitsAndUnusableDiscriminators_produceUnknown() {
        typealias Condition = DicomAttributeRule.Condition
        let dataSet = DicomDataSet(elements: [
            .init(tag: valueType, vr: .CS, value: .strings(["TEXT", ""])),
            .init(tag: patientName, vr: .PN, value: .strings(["3"]))
        ])
        XCTAssertEqual(Condition.stringEquals(valueType, "PNAME").evaluate(in: dataSet), .undetermined)
        XCTAssertEqual(Condition.stringEquals(valueType, "").evaluate(in: dataSet), .undetermined)
        XCTAssertEqual(Condition.integerGreaterThan(patientName, 1).evaluate(in: dataSet), .undetermined)
        XCTAssertEqual(Condition.all(Array(repeating: .present(valueType), count: 4096)).evaluate(in: dataSet), .undetermined)
        var deep = Condition.present(valueType)
        for _ in 0..<65 { deep = .not(deep) }
        XCTAssertEqual(deep.evaluate(in: dataSet), .undetermined)
    }

    func test_opaqueSequence_reportsUnavailableItemsInsteadOfClaimingWrongSourceVR() {
        let opaque = DicomDataElement(tag: sequence, vr: .UN, value: .bytes(Data([1, 2])))
        for requirement in [DicomAttributeRule.Requirement.type1, .type2, .type3] {
            let rule = DicomAttributeRule(tag: sequence, requirement: requirement,
                itemRules: [.init(tag: patientName, requirement: .type1)])
            let report = validate([opaque], rules: [rule])
            XCTAssertEqual(report[.attributes], .incomplete)
            XCTAssertEqual(report.diagnostics.map(\.code), [.valueUnavailable])
        }
    }

    func test_constraints_handleEmptyOptionalValuesMissingEvidenceAndArithmeticOverflow() {
        let rule = DicomAttributeRule(tag: 0x00280102, requirement: .type2,
            constraints: [.integerEqualsAttribute(0x00280101, offset: 1)])
        XCTAssertEqual(validate([.init(tag: rule.tag, vr: .US, value: .empty)], rules: [rule])[.attributes], .passed)
        XCTAssertEqual(validate([.init(tag: rule.tag, vr: .US, value: .unsignedIntegers([1]))],
                                rules: [rule])[.attributes], .incomplete)
        let overflow = validate([.init(tag: rule.tag, vr: .SV, value: .signedIntegers([1])),
            .init(tag: 0x00280101, vr: .SV, value: .signedIntegers([Int.max]))], rules: [rule])
        XCTAssertEqual(overflow[.attributes], .failed)
        XCTAssertEqual(overflow.diagnostics.first?.code, .attributeValueContradiction)
        let numeric = DicomAttributeRule(tag: rule.tag, requirement: .type2, constraints: [.integerRange(0...15)])
        XCTAssertEqual(validate([.init(tag: rule.tag, vr: .IS, value: .strings([""]))],
                                rules: [numeric])[.attributes], .passed)
    }

    func test_constraintWork_isIncludedInTheEvaluationBudget() {
        let rule = DicomAttributeRule(tag: 0x00280002, requirement: .type1,
            constraints: Array(repeating: .integerRange(1...1), count: 100))
        let dataSet = DicomDataSet(elements: [.init(tag: rule.tag, vr: .US, value: .unsignedIntegers([1]))])
        let report = DicomAttributeValidator.validate(dataSet, rules: [rule], limits: .init(maximumRuleEvaluations: 2))
        XCTAssertEqual(report[.attributes], .incomplete)
        XCTAssertEqual(report.diagnostics.map(\.code), [.evaluationLimitReached])
    }

    private func validate(_ elements: [DicomDataElement], rules: [DicomAttributeRule]) -> DicomValidationReport {
        DicomAttributeValidator.validate(.init(elements: elements), rules: rules)
    }

    func test_integerEnumerationAndUpperBound_requireUsableValuesAndCheckEveryComponent() {
        let tag = 0x00280101, bound = 0x00280100
        let rule = DicomAttributeRule(tag: tag, requirement: .type1,
            constraints: [.integers([1, 8]), .integerLessThanOrEqualAttribute(bound)])
        func values(_ tag: Int, _ values: [UInt]) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers(values)) }
        XCTAssertEqual(validate([values(tag, [1]), values(bound, [8])], rules: [rule])[.attributes], .passed)
        XCTAssertEqual(validate([values(tag, [8]), values(bound, [1])], rules: [rule])[.attributes], .failed)
        XCTAssertEqual(validate([values(tag, [1, 2]), values(bound, [8])], rules: [rule])[.attributes], .failed)
        XCTAssertEqual(validate([values(tag, [1])], rules: [rule])[.attributes], .incomplete)
        XCTAssertEqual(validate([values(tag, [1]), .init(tag: bound, vr: .UN, value: .bytes(Data([8, 0])))],
                                rules: [rule])[.attributes], .incomplete)
    }
}
