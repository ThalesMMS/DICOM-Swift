import Foundation
import XCTest
@testable import DicomData

final class DicomSRReferenceConditionTests: XCTestCase {
    func test_imageFacts_distinguishSingleMultiframeAndSegmentationWithoutInferringIntent() throws {
        for (suffix, multiframe, segmentation) in [("2", false, false), ("4", false, false), ("2.1", true, false),
                                                  ("481.24", true, false), ("66.4", true, true), ("66.7", true, true), ("66.8", true, true)] {
            let result = validate(suffix: suffix)
            let facts = try XCTUnwrap(result.contentReferenceConditions[[1, 0]], suffix)
            XCTAssertEqual(facts.isMultiframeImage, multiframe ? .satisfied : .unsatisfied)
            XCTAssertEqual(facts.isSegmentation, segmentation ? .satisfied : .unsatisfied)
            XCTAssertEqual(facts.waveformHasMultipleChannels, .unsatisfied)
            XCTAssertEqual(facts.appliesToAllFrames, .undetermined)
            XCTAssertEqual(facts.appliesToAllSegments, .undetermined)
            XCTAssertEqual(facts.appliesToAllWaveformChannels, .undetermined)
        }
    }

    func test_conditionalMultiframeClasses_requireUsableFrameMetadata() throws {
        for suffix in ["12.1", "12.2", "481.1", "481.2"] {
            XCTAssertEqual(try XCTUnwrap(validate(suffix: suffix).contentReferenceConditions[[1, 0]]).isMultiframeImage, .undetermined)
            for value in ["1", "3"] {
                let result = validate(suffix: suffix, geometry: [text(0x00280008, value, .IS)])
                XCTAssertEqual(try XCTUnwrap(result.contentReferenceConditions[[1, 0]]).isMultiframeImage, .satisfied)
            }
            for value in ["0", "-1", "invalid"] {
                let result = validate(suffix: suffix, geometry: [text(0x00280008, value, .IS)])
                XCTAssertEqual(try XCTUnwrap(result.contentReferenceConditions[[1, 0]]).isMultiframeImage, .undetermined)
            }
        }
    }

    func test_waveformFacts_countChannelsAcrossMultiplexGroups() throws {
        for (groups, expected) in [([group(1)], DicomAttributeRule.Truth.unsatisfied), ([group(2)], .satisfied),
                                    ([group(1), group(1)], .satisfied)] {
            let result = validate(suffix: "9.1.1", kind: "WAVEFORM", geometry: [sequence(0x54000100, groups)])
            let facts = try XCTUnwrap(result.contentReferenceConditions[[1, 0]])
            XCTAssertEqual(facts.waveformHasMultipleChannels, expected)
            XCTAssertEqual(facts.appliesToAllWaveformChannels, .undetermined)
        }
    }

    func test_missingOpaqueOrContradictoryChannelMetadata_remainsUnknown() throws {
        for geometry in [[], [sequence(0x54000100, [])], [sequence(0x54000100, [.init()])],
                         [sequence(0x54000100, [group(0)])], [sequence(0x54000100, [group(2), .init()])],
                         [sequence(0x54000100, [group(2).setting(sequence(0x003A0200, [.init()]))])],
                         [.init(tag: 0x54000100, vr: .UN, value: .bytes(Data([0, 0])))]] as [[DicomDataElement]] {
            let result = validate(suffix: "9.1.1", kind: "WAVEFORM", geometry: geometry)
            XCTAssertEqual(try XCTUnwrap(result.contentReferenceConditions[[1, 0]]).waveformHasMultipleChannels, .undetermined)
            // Target geometry is not fully validated here; these unknown facts feed the attribute component.
            XCTAssertEqual(result.report[.references], .passed)
        }
    }

    func test_missingMismatchedIncompatibleUnknownAndMultipleTargets_provideNoFacts() {
        XCTAssertTrue(validate(suffix: "2.1", supplyTarget: false).contentReferenceConditions.isEmpty)
        XCTAssertTrue(validate(suffix: "2.1", geometry: [text(0x00080016, prefix + "2", .UI)]).contentReferenceConditions.isEmpty)
        XCTAssertTrue(validate(suffix: "9.1.1").contentReferenceConditions.isEmpty)
        XCTAssertTrue(validate(suffix: "2.999").contentReferenceConditions.isEmpty)
        XCTAssertTrue(validate(suffix: "2.1", pairCount: 2).contentReferenceConditions.isEmpty)
    }

    func test_targetFactsComposeWithAuthorIntent_absentSelectorDenotesTheWholeObject() throws {
        let result = validate(suffix: "2.1")
        var facts = try XCTUnwrap(result.contentReferenceConditions[[1, 0]])
        let content = DicomDataSet(elements: [sequence(0x00081199, [pair("2.1")])])
        XCTAssertEqual(DicomContentReferenceMacro.validate(content, kind: .image, conditions: facts)[.attributes], .passed)
        facts.appliesToAllFrames = .unsatisfied
        let subset = DicomContentReferenceMacro.validate(content, kind: .image, conditions: facts)
        XCTAssertTrue(subset.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path.last == .tag(0x00081160) })
        facts.appliesToAllFrames = .satisfied
        XCTAssertEqual(DicomContentReferenceMacro.validate(content, kind: .image, conditions: facts)[.attributes], .passed)
    }

    func test_channelFactTraversal_sharesTheWorkBudget() {
        let result = validate(suffix: "9.1.1", kind: "WAVEFORM", geometry: [sequence(0x54000100, Array(repeating: group(1), count: 50))],
                              limits: .init(maximumRuleEvaluations: 25))
        XCTAssertEqual(result.report[.references], .incomplete)
        XCTAssertTrue(result.report.diagnostics.contains { $0.code == .evaluationLimitReached &&
            $0.path == [.tag(0x0040A730), .item(1), .tag(0x0040A730), .item(0), .tag(0x00081199), .item(0)] })
        XCTAssertNotEqual(result.contentReferenceConditions[[1, 0]]?.waveformHasMultipleChannels, .satisfied)
    }

    private let prefix = "1.2.840.10008.5.1.4.1.1."
    private func validate(suffix: String, kind: String = "IMAGE", geometry: [DicomDataElement] = [], supplyTarget: Bool = true,
                          pairCount: Int = 1, limits: DicomAttributeValidator.Limits = .init()) -> DicomSRReferenceValidator.Result {
        let child = DicomDataSet(elements: [text(0x0040A040, kind, .CS), sequence(0x00081199, Array(repeating: pair(suffix), count: pairCount))])
        let container = DicomDataSet(elements: [text(0x0040A040, "CONTAINER", .CS), sequence(0x0040A730, [child])])
        let series = DicomDataSet(elements: [text(0x0020000E, "2.25.23218003", .UI), sequence(0x00081199, [pair(suffix)])])
        let study = DicomDataSet(elements: [text(0x0020000D, "2.25.23218002", .UI), sequence(0x00081115, [series])])
        let source = DicomDataSet(elements: [text(0x0040A040, "CONTAINER", .CS),
            sequence(0x0040A730, [.init(elements: [text(0x0040A040, "TEXT", .CS)]), container]), sequence(0x0040A375, [study])])
        var target = DicomDataSet(elements: [text(0x00080016, prefix + suffix, .UI), text(0x00080018, "2.25.23218001", .UI),
            text(0x0020000D, "2.25.23218002", .UI), text(0x0020000E, "2.25.23218003", .UI)])
        for element in geometry { target = target.setting(element) }
        return DicomSRReferenceValidator.validate(source, kind: .structuredReport,
            targets: supplyTarget ? ["2.25.23218001": target] : [:], limits: limits)
    }

    private func pair(_ suffix: String) -> DicomDataSet {
        .init(elements: [text(0x00081150, prefix + suffix, .UI), text(0x00081155, "2.25.23218001", .UI)])
    }
    private func group(_ count: UInt) -> DicomDataSet {
        .init(elements: [.init(tag: 0x003A0005, vr: .US, value: .unsignedIntegers([count])),
                         sequence(0x003A0200, Array(repeating: .init(), count: Int(count)))])
    }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings([value])) }
    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
