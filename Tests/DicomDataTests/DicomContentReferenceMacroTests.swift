import Foundation
import XCTest
@testable import DicomData

final class DicomContentReferenceMacroTests: XCTestCase {
    func test_multiframeSubset_requiresFramesAndPreservesType1CPath() {
        var facts = imageFacts()
        facts.appliesToAllFrames = .unsatisfied
        let missing = validate(pair(), facts: facts)
        XCTAssertEqual(missing[.attributes], .failed)
        XCTAssertTrue(missing.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.requirement == .type1C &&
            $0.path == [.tag(0x00081199), .item(0), .tag(0x00081160)] })
        XCTAssertEqual(validate(pair().setting(frames()), facts: facts)[.attributes], .passed)
        let empty = pair().setting(.init(tag: 0x00081160, vr: .IS, value: .empty))
        XCTAssertTrue(validate(empty, facts: facts).diagnostics.contains { $0.code == .requiredValueEmpty })
    }

    func test_allFramesAndSingleFrame_forbidConditionalFrameSelector() {
        let all = imageFacts()
        var single = all
        single.isMultiframeImage = .unsatisfied
        single.appliesToAllFrames = .undetermined
        for facts in [all, single] {
            XCTAssertEqual(validate(pair(), facts: facts)[.attributes], .passed)
            XCTAssertTrue(validate(pair().setting(frames()), facts: facts).diagnostics.contains {
                $0.code == .conditionalAttributeForbidden && $0.path.last == .tag(0x00081160)
            })
        }
    }

    func test_unknownTarget_absentSelectorDenotesWholeObjectAndPresentSelectorStaysUndetermined() {
        let whole = validate(pair(), facts: .init())
        XCTAssertEqual(whole[.attributes], .passed)
        XCTAssertFalse(whole.diagnostics.contains { $0.path.last == .tag(0x00081160) })
        let selected = validate(pair().setting(frames()), facts: .init())
        XCTAssertEqual(selected[.attributes], .incomplete)
        XCTAssertTrue(selected.diagnostics.contains { $0.code == .conditionUndetermined && $0.path.last == .tag(0x00081160) })
        XCTAssertFalse(selected.diagnostics.contains { $0.code == .conditionalAttributeForbidden })
    }

    func test_segmentAndFrameAlternatives_requireOneSelectorAndRejectBoth() {
        var facts = imageFacts()
        facts.isSegmentation = .satisfied
        facts.appliesToAllFrames = .unsatisfied
        facts.appliesToAllSegments = .unsatisfied
        let base = pair().setting(text(0x00081150, "1.2.840.10008.5.1.4.1.1.66.4"))
        let segments = DicomDataElement(tag: 0x0062000B, vr: .US, value: .unsignedIntegers([7]))
        XCTAssertEqual(validate(base, facts: facts)[.attributes], .failed)
        for selector in [frames(), segments] {
            XCTAssertEqual(validate(base.setting(selector), facts: facts)[.attributes], .passed)
        }
        let both = validate(base.setting(frames()).setting(segments), facts: facts)
        XCTAssertEqual(both[.attributes], .failed)
        XCTAssertEqual(both.diagnostics.filter { $0.code == .conditionalAttributeForbidden }.count, 2)
        let opaque = base.setting(.init(tag: 0x0062000B, vr: .UN, value: .bytes(Data([7, 0]))))
        let report = validate(opaque, facts: facts)
        XCTAssertEqual(report[.attributes], .incomplete)
        XCTAssertFalse(report.diagnostics.contains { $0.code == .requiredAttributeMissing })
    }

    func test_waveformSubset_requiresChannelsAndAllChannelsForbidsSelector() {
        var facts = DicomContentReferenceMacro.Conditions()
        facts.waveformHasMultipleChannels = .satisfied
        facts.appliesToAllWaveformChannels = .unsatisfied
        let base = pair().setting(text(0x00081150, "1.2.840.10008.5.1.4.1.1.9.1.1"))
        let selected = base.setting(.init(tag: 0x0040A0B0, vr: .US, value: .unsignedIntegers([1, 0])))
        XCTAssertEqual(validate(base, kind: .waveform, facts: facts)[.attributes], .failed)
        XCTAssertEqual(validate(selected, kind: .waveform, facts: facts)[.attributes], .passed)
        XCTAssertEqual(validate(base, kind: .waveform, facts: .init())[.attributes], .passed)
        XCTAssertEqual(validate(selected, kind: .waveform, facts: .init())[.attributes], .incomplete)
        facts.appliesToAllWaveformChannels = .satisfied
        XCTAssertEqual(validate(base, kind: .waveform, facts: facts)[.attributes], .passed)
        XCTAssertTrue(validate(selected, kind: .waveform, facts: facts).diagnostics.contains {
            $0.code == .conditionalAttributeForbidden && $0.path.last == .tag(0x0040A0B0)
        })
    }

    func test_accompanyingImageObjects_enforceSingleItemAndRequiredUIDs() {
        for tag in [0x00081199, 0x0008114B] {
            for items: [DicomDataSet] in [[], [pair(), pair()], [.init()]] {
                XCTAssertEqual(validate(pair().setting(sequence(tag, items)), facts: imageFacts())[.attributes], .failed)
            }
            XCTAssertEqual(validate(pair().setting(sequence(tag, [pair()])), facts: imageFacts())[.attributes], .passed)
        }
    }

    func test_waveformChannels_requireCompletePairs() {
        var facts = DicomContentReferenceMacro.Conditions()
        facts.waveformHasMultipleChannels = .satisfied
        facts.appliesToAllWaveformChannels = .unsatisfied
        let base = pair().setting(text(0x00081150, "1.2.840.10008.5.1.4.1.1.9.1.1"))
        for count in 1...6 {
            let selected = base.setting(.init(tag: 0x0040A0B0, vr: .US,
                                             value: .unsignedIntegers(Array(repeating: 1, count: count))))
            let report = validate(selected, kind: .waveform, facts: facts)
            XCTAssertEqual(report[.attributes], count.isMultiple(of: 2) ? .passed : .failed, "count=\(count)")
            if !count.isMultiple(of: 2) {
                XCTAssertTrue(report.diagnostics.contains { $0.code == .invalidMultiplicity &&
                    $0.path == [.tag(0x00081199), .item(0), .tag(0x0040A0B0)] })
            }
        }
    }

    func test_composite_hasNoImageOrWaveformConditionWithoutApplicableMacro() {
        let report = validate(pair(), kind: .composite, facts: .init())
        XCTAssertEqual(report[.attributes], .passed)
        XCTAssertEqual(report[.references], .notEvaluated)
        XCTAssertEqual(report[.pixelsAndGeometry], .notEvaluated)
    }

    func test_missingOrMultiplePrimaryPairs_failAndSharedBudgetStaysIncomplete() {
        XCTAssertEqual(DicomContentReferenceMacro.validate(.init(), kind: .composite)[.attributes], .failed)
        let multiple = DicomDataSet(elements: [sequence(0x00081199, [pair(), pair()])])
        XCTAssertEqual(DicomContentReferenceMacro.validate(multiple, kind: .image)[.attributes], .failed)
        let report = DicomContentReferenceMacro.validate(.init(elements: [sequence(0x00081199, [pair()])]),
            kind: .image, limits: .init(maximumRuleEvaluations: 1))
        XCTAssertEqual(report[.attributes], .incomplete)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .evaluationLimitReached })
    }

    private func imageFacts() -> DicomContentReferenceMacro.Conditions {
        var facts = DicomContentReferenceMacro.Conditions()
        facts.isMultiframeImage = .satisfied
        facts.isSegmentation = .unsatisfied
        facts.appliesToAllFrames = .satisfied
        return facts
    }

    private func validate(_ reference: DicomDataSet, kind: DicomContentReferenceMacro.Kind = .image,
                          facts: DicomContentReferenceMacro.Conditions) -> DicomValidationReport {
        DicomContentReferenceMacro.validate(.init(elements: [sequence(0x00081199, [reference])]), kind: kind, conditions: facts)
    }

    private func pair() -> DicomDataSet {
        .init(elements: [text(0x00081150, "1.2.840.10008.5.1.4.1.1.2.1"), text(0x00081155, "2.25.23215001")])
    }

    private func text(_ tag: Int, _ value: String) -> DicomDataElement { .init(tag: tag, vr: .UI, value: .strings([value])) }
    private func frames() -> DicomDataElement { .init(tag: 0x00081160, vr: .IS, value: .strings(["1"])) }
    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
