import Foundation
import XCTest
@testable import DicomData

final class DicomSRTemporalReferenceValidatorTests: XCTestCase {
    func test_samplePositions_useOneBasedSelectedGroupBounds() {
        for (sample, expected) in [(1, DicomValidationReport.Outcome.passed), (7, .passed), (8, .failed), (0, .failed)] {
            let result = validate(temporal([UInt(sample)]))
            XCTAssertEqual(result.report[.pixelsAndGeometry], expected)
            XCTAssertEqual(result.temporalConditions[[0]]?.referencesWaveform, .satisfied)
            XCTAssertEqual(result.temporalConditions[[0]]?.channelsUseSingleMultiplexGroup, .satisfied)
            if sample == 8 {
                XCTAssertTrue(result.report.diagnostics.contains { $0.code == .temporalCoordinateOutOfRange && $0.requirement == .type1C &&
                    $0.path == [.tag(0x0040A730), .item(0), .tag(0x0040A132)] })
            }
        }
        let second = temporal([9], children: [wave(channels: [2, 0])])
        XCTAssertEqual(validate(second, target: target(groups: [group(7), group(9)])).report[.pixelsAndGeometry], .passed)
    }

    func test_explicitChannelPairs_establishSingleGroupWithoutInferringMissingSelectors() {
        for (channels, expected) in [([UInt(1), 0], DicomAttributeRule.Truth.satisfied), ([1, 1, 1, 2], .satisfied), ([1, 1, 2, 1], .unsatisfied)] {
            let result = validate(temporal([1], children: [wave(channels: channels)]), target: target(groups: [group(7), group(9)]))
            XCTAssertEqual(result.temporalConditions[[0]]?.channelsUseSingleMultiplexGroup, expected)
            XCTAssertEqual(result.report[.pixelsAndGeometry], expected == .satisfied ? .passed : .failed)
        }
        for bad in [wave(channels: nil), wave(channels: []), wave(channels: [1]), wave(channels: [1, 3]), wave(channels: [3, 1])] {
            let result = validate(temporal([1], children: [bad]))
            XCTAssertEqual(result.temporalConditions[[0]]?.channelsUseSingleMultiplexGroup, .undetermined)
            XCTAssertNotEqual(result.report[.pixelsAndGeometry], .passed)
        }
    }

    func test_sharedMultiplexUID_distinguishesCrossInstanceGroupsFromOrdinalCoincidence() {
        let other = "2.25.23218802"
        let source = root([temporal([7], children: [wave(), wave(uid: other)])])
        for (firstUID, secondUID, expected) in [("2.25.1", "2.25.1", DicomAttributeRule.Truth.satisfied),
                                               ("2.25.1", "2.25.2", .unsatisfied), (nil, nil, .undetermined)] as [(String?, String?, DicomAttributeRule.Truth)] {
            let targets = [uid: target(groups: [group(7, uid: firstUID)]), other: target(uid: other, groups: [group(7, uid: secondUID)])]
            let result = DicomSRCoordinateReferenceValidator.validate(source, targets: targets)
            XCTAssertEqual(result.temporalConditions[[0]]?.channelsUseSingleMultiplexGroup, expected)
            XCTAssertEqual(result.report[.pixelsAndGeometry], expected == .satisfied ? .passed : expected == .unsatisfied ? .failed : .incomplete)
        }
        let duplicate = validate(temporal([7], children: [wave(), wave()]))
        XCTAssertEqual(duplicate.temporalConditions[[0]]?.channelsUseSingleMultiplexGroup, .satisfied)
    }

    func test_missingOpaqueOrContradictoryTargets_neverApproveSampleBounds() {
        let source = root([temporal([1])])
        let missing = DicomSRCoordinateReferenceValidator.validate(source)
        XCTAssertEqual(missing.report[.pixelsAndGeometry], .incomplete)
        XCTAssertEqual(missing.temporalConditions[[0]]?.referencesWaveform, .undetermined)
        for bad in [target(uid: "2.25.999"), target().setting(text(0x00080016, "1.2.840.10008.5.1.4.1.1.2", .UI))] {
            let result = validate(temporal([1]), target: bad)
            XCTAssertEqual(result.report[.references], .failed)
            XCTAssertEqual(result.report[.pixelsAndGeometry], .incomplete)
        }
        for bad in [group(7).removing(0x003A0010), group(7).setting(.init(tag: 0x003A0010, vr: .UN, value: .bytes(Data([0, 0])))),
                    group(7).removing(0x003A0200)] {
            XCTAssertEqual(validate(temporal([1]), target: target(groups: [bad])).report[.pixelsAndGeometry], .incomplete)
        }
        XCTAssertEqual(validate(temporal([1]), target: target(groups: [group(0)])).report[.pixelsAndGeometry], .failed)
        XCTAssertEqual(validate(temporal([UInt(UInt32.max)]), target: target(groups: [group(UInt(UInt32.max))])).report[.pixelsAndGeometry], .passed)
    }

    func test_forwardReferenceAndSpatialImageChain_preserveOriginalConditionPaths() {
        let reference = DicomDataSet(elements: [text(0x0040A010, "SELECTED FROM", .CS), number(0x0040DB73, [1, 2], .UL)])
        let result = DicomSRCoordinateReferenceValidator.validate(root([temporal([1], children: [reference]), wave().setting(text(0x0040A010, "CONTAINS", .CS))]), targets: [uid: target()])
        XCTAssertEqual(result.report[.references], .passed)
        XCTAssertEqual(result.report[.pixelsAndGeometry], .passed)
        XCTAssertEqual(result.temporalConditions[[0]]?.channelsUseSingleMultiplexGroup, .satisfied)
        let imageClass = "1.2.840.10008.5.1.4.1.1.2"
        let pair = DicomDataSet(elements: [text(0x00081150, imageClass, .UI), text(0x00081155, uid, .UI)])
        let image = wave(channels: nil).setting(text(0x0040A040, "IMAGE", .CS)).setting(sequence(0x00081199, [pair]))
        let spatial = DicomDataSet(elements: [text(0x0040A040, "SCOORD", .CS), text(0x0040A010, "SELECTED FROM", .CS),
            text(0x00700023, "POINT", .CS), .init(tag: 0x00700022, vr: .FL, value: .floats([1, 1])), sequence(0x0040A730, [image])])
        let imageTarget = target().setting(text(0x00080016, imageClass, .UI)).setting(number(0x00280010, [7], .US)).setting(number(0x00280011, [9], .US))
        let chain = validate(temporal([1], children: [spatial]), target: imageTarget)
        XCTAssertEqual(chain.temporalConditions[[0]]?.referencesWaveform, .unsatisfied)
        XCTAssertEqual(chain.report[.pixelsAndGeometry], .incomplete)
    }

    func test_timeOffsetsAndAbsoluteTimes_remainUnqualifiedForAcquisitionAlignment() {
        for element in [text(0x0040A138, "-1", .DS), text(0x0040A13A, "20260908", .DT)] {
            let source = temporal([1]).removing(0x0040A132).setting(element)
            let result = validate(source)
            XCTAssertEqual(result.report[.pixelsAndGeometry], .incomplete)
            XCTAssertTrue(result.report.diagnostics.contains { $0.code == .temporalAlignmentUnavailable })
            XCTAssertFalse(result.report.diagnostics.contains { $0.severity == .error })
        }
    }

    func test_partialGraphAndSharedBudgets_doNotPublishPartialFacts() {
        let reference = DicomDataSet(elements: [text(0x0040A010, "SELECTED FROM", .CS), number(0x0040DB73, [1, 99], .UL)])
        let partial = validate(temporal([1], children: [wave(), reference]))
        XCTAssertEqual(partial.temporalConditions[[0]]?.referencesWaveform, .satisfied)
        XCTAssertEqual(partial.temporalConditions[[0]]?.channelsUseSingleMultiplexGroup, .undetermined)
        XCTAssertEqual(partial.report[.pixelsAndGeometry], .incomplete)
        let source = root(Array(repeating: temporal([1]), count: 20))
        for limit in [1, 10, 100] {
            let result = DicomSRCoordinateReferenceValidator.validate(source, targets: [uid: target()], limits: .init(maximumRuleEvaluations: limit))
            XCTAssertNotEqual(result.report[.pixelsAndGeometry], .passed)
            XCTAssertTrue(result.temporalConditions.isEmpty)
            XCTAssertLessThanOrEqual(result.evaluations, limit)
        }
    }

    func test_repeatedReferences_toOneGroupUseLinearWork() {
        let result = validate(temporal([7], children: Array(repeating: wave(), count: 1_000)))
        XCTAssertEqual(result.report[.pixelsAndGeometry], .passed)
        XCTAssertEqual(result.temporalConditions[[0]]?.channelsUseSingleMultiplexGroup, .satisfied)
        XCTAssertLessThan(result.evaluations, 30_000)
    }

    private let uid = "2.25.23218801"
    private func validate(_ temporal: DicomDataSet, target: DicomDataSet? = nil) -> DicomSRCoordinateReferenceValidator.Result {
        DicomSRCoordinateReferenceValidator.validate(root([temporal]), targets: [uid: target ?? self.target()])
    }
    private func root(_ children: [DicomDataSet]) -> DicomDataSet {
        .init(elements: [text(0x00080016, "1.2.840.10008.5.1.4.1.1.88.33", .UI), text(0x0040A040, "CONTAINER", .CS), sequence(0x0040A730, children)])
    }
    private func temporal(_ samples: [UInt], children: [DicomDataSet]? = nil) -> DicomDataSet {
        .init(elements: [text(0x0040A040, "TCOORD", .CS), text(0x0040A010, "CONTAINS", .CS), text(0x0040A130, "POINT", .CS),
            number(0x0040A132, samples, .UL), sequence(0x0040A730, children ?? [wave()])])
    }
    private func wave(uid: String = "2.25.23218801", channels: [UInt]? = [1, 1]) -> DicomDataSet {
        var pair = DicomDataSet(elements: [text(0x00081150, "1.2.840.10008.5.1.4.1.1.9.1.1", .UI), text(0x00081155, uid, .UI)])
        if let channels { pair = pair.setting(number(0x0040A0B0, channels, .US)) }
        return .init(elements: [text(0x0040A040, "WAVEFORM", .CS), text(0x0040A010, "SELECTED FROM", .CS), sequence(0x00081199, [pair])])
    }
    private func target(uid: String = "2.25.23218801", groups: [DicomDataSet]? = nil) -> DicomDataSet {
        .init(elements: [text(0x00080016, "1.2.840.10008.5.1.4.1.1.9.1.1", .UI), text(0x00080018, uid, .UI), sequence(0x54000100, groups ?? [group(7)])])
    }
    private func group(_ samples: UInt, uid: String? = nil) -> DicomDataSet {
        var result = DicomDataSet(elements: [number(0x003A0005, [2], .US), number(0x003A0010, [samples], .UL), sequence(0x003A0200, [.init(), .init()])])
        if let uid { result = result.setting(text(0x003A0310, uid, .UI)) }
        return result
    }
    private func sequence(_ tag: Int, _ children: [DicomDataSet]) -> DicomDataElement { .init(tag: tag, vr: .SQ, value: .sequence(children.map { .init(dataSet: $0) })) }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings([value])) }
    private func number(_ tag: Int, _ values: [UInt], _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .unsignedIntegers(values)) }
}
