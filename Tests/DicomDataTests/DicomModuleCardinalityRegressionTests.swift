import Foundation
import XCTest
@testable import DicomData

final class DicomModuleCardinalityRegressionTests: XCTestCase {

    func test_unavailableReferenceStillWalksNestedTargets() {
        let nested = DicomDataSet(elements: [
            .init(tag: 0x00081155, vr: .UI, value: .strings(["1.2.3"])),
            .init(tag: 0x00081150, vr: .UI, value: .strings(["1.2.4"]))])
        let source = DicomDataSet(elements: [
            .init(tag: 0x00081155, vr: .UI, value: .strings(["1.2.9"])),
            .init(tag: 0x00081140, vr: .SQ, value: .sequence([.init(dataSet: nested)]))])
        let target = DicomDataSet(elements: [.init(tag: 0x00080016, vr: .UI, value: .strings(["1.2.5"]))])
        var state = DicomEnhancedImageModules.State(limits: .init())
        DicomReferenceTargetWalk.validate(source, targets: ["1.2.3": target], state: &state)
        XCTAssertTrue(state.report.diagnostics.contains { $0.code == .referenceTargetUnavailable && $0.path == [.tag(0x00081155)] })
        XCTAssertTrue(state.report.diagnostics.contains { $0.code == .referenceIdentityContradiction
            && $0.path == [.tag(0x00081140), .item(0), .tag(0x00081150)] })
    }

    func test_srAndSpecimenSingleItemSequences_rejectMultipleItems() throws {
        let specimen = DicomSpecimenModule.rules(for: .init())
        let rules = DicomSRSeriesModule.rules(kind: .structuredReport).filter { $0.tag == 0x00081111 }
            + specimen.filter { [0x00400513, 0x00400518].contains($0.tag) }
            + (specimen.first { $0.tag == 0x00400515 }?.itemRules ?? []).filter { $0.tag == 0x00400513 }
            + (specimen.first { $0.tag == 0x00400560 }?.itemRules ?? []).filter { $0.tag == 0x00400562 }
        XCTAssertEqual(rules.count, 5)
        for rule in rules {
            for count in 0...2 {
                let value: DicomDataValue = .sequence(Array(repeating: .init(dataSet: .init()), count: count))
                let report = DicomAttributeValidator.validate(.init(elements: [.init(tag: rule.tag, vr: .SQ, value: value)]), rules: [rule])
                XCTAssertEqual(report.diagnostics.contains { $0.code == .sequenceItemCountInvalid && $0.path == [.tag(rule.tag)] }, count == 2,
                               "tag \(String(rule.tag, radix: 16)), count \(count)")
            }
        }
    }

    func test_contrastRoute_rejectsTwoItems() throws {
        let rule = try XCTUnwrap(DicomContrastBolusModule.rules().first { $0.tag == 0x00180014 })
        for count in 1...2 {
            let element = DicomDataElement(tag: rule.tag, vr: .SQ, value: .sequence(Array(repeating: .init(dataSet: .init()), count: count)))
            let diagnostics = rule.constraints.compactMap { DicomAttributeConstraintValidator.validate($0, element: element, dataSet: .init()) }
            XCTAssertEqual(diagnostics.contains { $0.code == .sequenceItemCountInvalid }, count == 2)
        }
    }

    func test_waveformWithoutSynchronizationEncoding_doesNotRequireAChannel() {
        let waveform = DicomDataSet(elements: [
            .init(tag: 0x00200200, vr: .UI, value: .strings(["1.2.840.10008.15.1.1"])),
            .init(tag: 0x0018106A, vr: .CS, value: .strings(["NO TRIGGER"])),
            .init(tag: 0x00181800, vr: .CS, value: .strings(["N"])),
            .init(tag: 0x54000100, vr: .SQ, value: .sequence([.init(dataSet: .init())]))
        ])
        let report = DicomSynchronizationModule.validate(waveform)
        XCTAssertFalse(report.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path == [.tag(0x0018106C)] })
        XCTAssertNotEqual(report[.attributes], .failed)
    }
}
