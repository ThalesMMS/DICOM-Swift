import Foundation
import XCTest
@testable import DicomData

final class DicomTemporalCoordinatesMacroTests: XCTestCase {
    func test_eachRangeAndRepresentation_acceptsItsRequiredCardinality() {
        for (type, count) in [("POINT", 1), ("BEGIN", 1), ("END", 1), ("SEGMENT", 2), ("MULTIPOINT", 3), ("MULTISEGMENT", 4)] {
            for tag in tags {
                XCTAssertEqual(validate(item(type, tag, count))[.attributes], .passed, "\(type) \(tag)")
            }
        }
        XCTAssertEqual(validate(item("MULTIPOINT", 0x0040A138, 2))[.attributes], .passed)
        XCTAssertEqual(validate(item("MULTISEGMENT", 0x0040A138, 6))[.attributes], .passed)
    }

    func test_wrongCardinality_failsWithType1CAndOriginalTag() {
        for (type, count) in [("POINT", 2), ("BEGIN", 2), ("END", 2), ("SEGMENT", 1), ("SEGMENT", 3),
                              ("MULTIPOINT", 1), ("MULTISEGMENT", 2), ("MULTISEGMENT", 3), ("MULTISEGMENT", 5)] {
            for tag in tags {
                let report = validate(item(type, tag, count))
                XCTAssertEqual(report[.attributes], .failed)
                XCTAssertTrue(report.diagnostics.contains { $0.code == .invalidMultiplicity && $0.path == [.tag(tag)] && $0.requirement == .type1C })
            }
        }
    }

    func test_allRepresentationPairs_areForbiddenEvenWhenOneIsEmpty() {
        for first in tags {
            for second in tags where first != second {
                for empty in [false, true] {
                    let source = item("POINT", first, 1).setting(empty ? .init(tag: second, vr: vr(second), value: .empty) : value(second, 1))
                    let report = validate(source)
                    XCTAssertEqual(report[.attributes], .failed)
                    XCTAssertTrue(report.diagnostics.contains { $0.code == .exclusiveAttributeChoiceInvalid && $0.path == [] })
                    XCTAssertTrue(report.diagnostics.contains { $0.code == .conditionalAttributeForbidden && $0.path == [.tag(first)] })
                }
            }
        }
        let missing = DicomDataSet(elements: [text(0x0040A130, "POINT", .CS)])
        XCTAssertTrue(validate(missing).diagnostics.contains { $0.code == .requiredAttributeMissing })
    }

    func test_samples_requireWaveformAndOneMultiplexGroupWithoutInferringFactsFromPresence() {
        let source = item("POINT", 0x0040A132, 1)
        XCTAssertEqual(DicomTemporalCoordinatesMacro.validate(source)[.attributes], .incomplete)
        for waveform in [DicomAttributeRule.Truth.satisfied, .unsatisfied, .undetermined] {
            for singleGroup in [DicomAttributeRule.Truth.satisfied, .unsatisfied, .undetermined] {
                var facts = DicomTemporalCoordinatesMacro.Conditions()
                facts.referencesWaveform = waveform
                facts.channelsUseSingleMultiplexGroup = singleGroup
                let expected: DicomValidationReport.Outcome = waveform == .unsatisfied || singleGroup == .unsatisfied ? .failed :
                    waveform == .undetermined || singleGroup == .undetermined ? .incomplete : .passed
                XCTAssertEqual(DicomTemporalCoordinatesMacro.validate(source, conditions: facts)[.attributes], expected)
            }
        }
        for tag in [0x0040A138, 0x0040A13A] {
            XCTAssertEqual(DicomTemporalCoordinatesMacro.validate(item("POINT", tag, 1))[.attributes], .passed)
        }
    }

    func test_invalidValues_cannotBeRepairedByProjection() {
        let invalid: [DicomDataElement] = [
            .init(tag: 0x0040A132, vr: .UL, value: .unsignedIntegers([0])),
            .init(tag: 0x0040A132, vr: .UL, value: .unsignedIntegers([UInt(UInt32.max) + 1])),
            text(0x0040A138, "NaN", .DS), text(0x0040A138, "1e999", .DS),
            text(0x0040A13A, "20260230", .DT)
        ]
        for element in invalid {
            let report = validate(item("POINT", element.tag, 1).setting(element))
            XCTAssertEqual(report[.attributes], .failed)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .attributeValueNotAllowed })
        }
        for tag in tags {
            XCTAssertEqual(validate(item("POINT", tag, 1).setting(.init(tag: tag, vr: vr(tag), value: .empty)))[.attributes], .failed)
        }
        XCTAssertEqual(validate(item("POINT", 0x0040A138, 1).setting(text(0x0040A138, "-0.25", .DS)))[.attributes], .passed)
        XCTAssertEqual(validate(item("POINT", 0x0040A13A, 1).setting(text(0x0040A13A, "2026", .DT)))[.attributes], .passed)
    }

    func test_unknownOrUnusableRange_doesNotInventCardinality() {
        let base = item("POINT", 0x0040A138, 1)
        for source in [base.removing(0x0040A130), base.setting(text(0x0040A130, "FUTURE", .CS)),
                       base.setting(.init(tag: 0x0040A130, vr: .UN, value: .bytes(Data([0, 0])))),
                       base.setting(.init(tag: 0x0040A130, vr: .CS, value: .strings(["POINT", "SEGMENT"])))] {
            let report = validate(source)
            XCTAssertNotEqual(report[.attributes], .passed)
            XCTAssertFalse(report.diagnostics.contains { $0.code == .invalidMultiplicity && $0.path == [.tag(0x0040A138)] })
        }
    }

    func test_unusableRepresentation_remainsUnavailable() {
        for tag in tags {
            let source = item("POINT", tag, 1).setting(.init(tag: tag, vr: .UN, value: .bytes(Data([0, 0]))))
            XCTAssertEqual(validate(source)[.attributes], .incomplete)
        }
        let wrongVR = item("POINT", 0x0040A138, 1).setting(text(0x0040A138, "0", .LO))
        XCTAssertEqual(validate(wrongVR)[.attributes], .incomplete)
    }

    func test_componentScanning_usesTheSharedWorkBudget() {
        let source = item("MULTIPOINT", 0x0040A138, 1000)
        let limited = DicomTemporalCoordinatesMacro.validate(source, limits: .init(maximumRuleEvaluations: 20))
        XCTAssertEqual(limited[.attributes], .incomplete)
        XCTAssertTrue(limited.diagnostics.contains { $0.code == .evaluationLimitReached && $0.path == [.tag(0x0040A138)] })
        let full = DicomAttributeValidator.evaluate(source, rules: DicomTemporalCoordinatesMacro.rules())
        XCTAssertEqual(full.report[.attributes], .passed)
        XCTAssertGreaterThanOrEqual(full.evaluations, 1000)
        let capped = DicomTemporalCoordinatesMacro.validate(.init(), limits: .init(maximumDiagnostics: 1))
        XCTAssertEqual(capped.diagnostics.count, 2)
        XCTAssertEqual(capped.diagnostics.last?.code, .evaluationLimitReached)
    }

    private let tags = [0x0040A132, 0x0040A138, 0x0040A13A]
    private func validate(_ source: DicomDataSet) -> DicomValidationReport {
        var facts = DicomTemporalCoordinatesMacro.Conditions()
        facts.referencesWaveform = .satisfied
        facts.channelsUseSingleMultiplexGroup = .satisfied
        return DicomTemporalCoordinatesMacro.validate(source, conditions: facts)
    }
    private func item(_ type: String, _ tag: Int, _ count: Int) -> DicomDataSet {
        .init(elements: [text(0x0040A130, type, .CS), value(tag, count)])
    }
    private func value(_ tag: Int, _ count: Int) -> DicomDataElement {
        if tag == 0x0040A132 { return .init(tag: tag, vr: .UL, value: .unsignedIntegers((0..<count).map { UInt($0 + 1) })) }
        return .init(tag: tag, vr: vr(tag), value: .strings((0..<count).map { tag == 0x0040A138 ? "\($0)" : "20260908120000" }))
    }
    private func vr(_ tag: Int) -> DicomVR { tag == 0x0040A132 ? .UL : tag == 0x0040A138 ? .DS : .DT }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings([value])) }
}
