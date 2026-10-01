import Foundation
import XCTest
@testable import DicomData

final class DicomNumericMeasurementMacroTests: XCTestCase {
    func test_measurementAndEmptyQualifiedValue_satisfyAttributeRequirements() {
        XCTAssertEqual(attributes(measurement())[.attributes], .passed)
        XCTAssertEqual(attributes(emptyQualified())[.attributes], .passed)
        XCTAssertEqual(DicomNumericMeasurementMacro.validate(measurement(), floatingPointRequired: .unsatisfied,
            rationalRepresentationRequired: .unsatisfied, versionRequirements: versions)[.attributes], .incomplete)
    }

    func test_absentAndEmptyMeasuredSequence_haveDifferentFailures() {
        let absent = attributes(.init())
        XCTAssertTrue(absent.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path == [.tag(0x0040A300)] })
        let empty = attributes(.init(elements: [sequence(0x0040A300, [])]))
        XCTAssertTrue(empty.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path == [.tag(0x0040A301)] })
        XCTAssertFalse(empty.diagnostics.contains { $0.path == [.tag(0x0040A300)] })
        let alternate = emptyQualified().setting(.init(tag: 0x0040A300, vr: .SQ, value: .empty))
        XCTAssertEqual(attributes(alternate)[.attributes], .passed)
    }

    func test_measurementAndQualifierSequenceCardinalities_areEnforced() {
        for dataSet in [measurement().setting(sequence(0x0040A300, [value(), value()])),
                        emptyQualified().setting(sequence(0x0040A301, [])),
                        emptyQualified().setting(sequence(0x0040A301, [qualifier(), qualifier()])),
                        measurement().setting(sequence(0x0040A301, [qualifier()]))] {
            XCTAssertEqual(attributes(dataSet)[.attributes], .failed)
        }
    }

    func test_numericValueAndUnits_requireUsableSingleItems() {
        for tag in [0x0040A30A, 0x004008EA] {
            let report = attributes(measurement(value().removing(tag)))
            XCTAssertTrue(report.diagnostics.contains { $0.code == .requiredAttributeMissing &&
                $0.path == [.tag(0x0040A300), .item(0), .tag(tag)] })
        }
        let badUnits = value().setting(sequence(0x004008EA, [unit().removing(0x00080104)]))
        XCTAssertTrue(attributes(measurement(badUnits)).diagnostics.contains {
            $0.code == .requiredAttributeMissing && $0.path == [.tag(0x0040A300), .item(0), .tag(0x004008EA), .item(0), .tag(0x00080104)]
        })
    }

    func test_unknownPrecision_isNotInferredFromAnApparentlySimpleDecimal() {
        let unknown = DicomAttributeValidator.validate(measurement(), rules: DicomNumericMeasurementMacro.rules(
            for: measurement(), versionRequirements: versions))
        XCTAssertEqual(unknown[.attributes], .incomplete)
        for tag in [0x0040A161, 0x0040A162] {
            XCTAssertTrue(unknown.diagnostics.contains { $0.code == .conditionUndetermined &&
                $0.path == [.tag(0x0040A300), .item(0), .tag(tag)] })
        }
    }

    func test_requiredFloatingPointValue_rejectsAbsenceAndAcceptsSuppliedValue() {
        let absent = attributes(measurement(), floatingPoint: .satisfied)
        XCTAssertTrue(absent.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path.last == .tag(0x0040A161) })
        let withFloat = measurement(value().setting(.init(tag: 0x0040A161, vr: .FD, value: .floats([42]))))
        XCTAssertEqual(attributes(withFloat, floatingPoint: .satisfied)[.attributes], .passed)
        XCTAssertEqual(attributes(withFloat)[.attributes], .passed) // Explicitly permitted otherwise.
    }

    func test_rationalValues_requireNonzeroDenominatorAndPermitSignedNumerator() {
        XCTAssertEqual(attributes(measurement(), rational: .satisfied)[.attributes], .failed)
        for numerator in [-1, 0, 1] {
            let item = value().setting(text(0x0040A30A, String(numerator), .DS))
                .setting(.init(tag: 0x0040A162, vr: .SL, value: .signedIntegers([numerator])))
                .setting(.init(tag: 0x0040A163, vr: .UL, value: .unsignedIntegers([1])))
            XCTAssertEqual(attributes(measurement(item), rational: .satisfied)[.attributes], .passed)
            XCTAssertEqual(attributes(measurement(item.removing(0x0040A163)))[.attributes], .failed)
            XCTAssertEqual(attributes(measurement(item.setting(.init(tag: 0x0040A163, vr: .UL,
                value: .unsignedIntegers([0])))))[.attributes], .failed)
        }
        let orphan = value().setting(.init(tag: 0x0040A163, vr: .UL, value: .unsignedIntegers([3])))
        XCTAssertTrue(attributes(measurement(orphan)).diagnostics.contains {
            $0.code == .conditionalAttributeForbidden && $0.path.last == .tag(0x0040A163)
        })
    }

    func test_macroRejectsMultipleNumericValuesEvenWhenWireDictionaryPermitsThem() throws {
        let multiple = measurement(value().setting(.init(tag: 0x0040A30A, vr: .DS, value: .strings(["1", "2"]))))
        let wire = try DicomDataSetWriter.dataSetData(from: multiple, purpose: .instance)
        let decoded = try DicomEncodedDataSetValidator.validate(wire, transferSyntax: .explicitVRLittleEndian)
        XCTAssertEqual(decoded.report[.vrAndVM], .passed)
        let report = attributes(try XCTUnwrap(decoded.dataSet))
        XCTAssertTrue(report.diagnostics.contains { $0.code == .invalidMultiplicity &&
            $0.path == [.tag(0x0040A300), .item(0), .tag(0x0040A30A)] })
        for element in [DicomDataElement(tag: 0x0040A161, vr: .FD, value: .floats([1, 2])),
                        .init(tag: 0x0040A162, vr: .SL, value: .signedIntegers([1, 2])),
                        .init(tag: 0x0040A163, vr: .UL, value: .unsignedIntegers([1, 2]))] {
            XCTAssertTrue(attributes(measurement(value().setting(element))).diagnostics.contains {
                $0.code == .invalidMultiplicity && $0.path.last == .tag(element.tag)
            })
        }
    }

    func test_opaqueSequence_doesNotProveQualifierConditionFalse() {
        let dataSet = DicomDataSet(elements: [.init(tag: 0x0040A300, vr: .UN, value: .bytes(Data([1, 2])))])
        let report = attributes(dataSet)
        XCTAssertEqual(report[.attributes], .incomplete)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .conditionUndetermined && $0.path == [.tag(0x0040A301)] })
        XCTAssertFalse(report.diagnostics.contains { $0.code == .conditionalAttributeForbidden })
    }

    func test_interruptedEvaluation_retainsQualificationWithinDocumentedBound() {
        let dataSet = measurement().setting(sequence(0x0040A301, [qualifier()]))
        let report = DicomNumericMeasurementMacro.validate(dataSet,
            limits: .init(maximumRuleEvaluations: 0, maximumDiagnostics: 1))
        XCTAssertEqual(report[.attributes], .incomplete)
        XCTAssertEqual(report.diagnostics.filter { $0.code == .evaluationLimitReached }.count, 1)
        XCTAssertEqual(report.diagnostics.filter { $0.code == .moduleRuleUnavailable }.count, 2)
        XCTAssertLessThanOrEqual(report.diagnostics.count, 1 + 1 + 2)
    }

    private let versions: [String: DicomAttributeRule.Truth] = ["UCUM": .unsatisfied, "DCM": .unsatisfied]

    private func attributes(_ dataSet: DicomDataSet, floatingPoint: DicomAttributeRule.Truth = .unsatisfied,
                            rational: DicomAttributeRule.Truth = .unsatisfied) -> DicomValidationReport {
        DicomAttributeValidator.validate(dataSet, rules: DicomNumericMeasurementMacro.rules(for: dataSet,
            floatingPointRequired: floatingPoint, rationalRepresentationRequired: rational, versionRequirements: versions))
    }

    private func measurement(_ item: DicomDataSet? = nil) -> DicomDataSet {
        .init(elements: [sequence(0x0040A300, [item ?? value()])])
    }

    private func value() -> DicomDataSet {
        .init(elements: [text(0x0040A30A, "42", .DS), sequence(0x004008EA, [unit()])])
    }

    private func emptyQualified() -> DicomDataSet {
        .init(elements: [sequence(0x0040A300, []), sequence(0x0040A301, [qualifier()])])
    }

    private func unit() -> DicomDataSet {
        .init(elements: [text(0x00080100, "mm", .SH), text(0x00080102, "UCUM", .SH), text(0x00080104, "millimeter", .LO)])
    }

    private func qualifier() -> DicomDataSet {
        .init(elements: [text(0x00080100, "114007", .SH), text(0x00080102, "DCM", .SH),
            text(0x00080104, "Measurement not attempted", .LO)])
    }

    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings([value]))
    }

    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
