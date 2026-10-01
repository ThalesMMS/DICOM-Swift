import Foundation
import XCTest
@testable import DicomData

final class DicomSRReferenceSelectionTests: XCTestCase {
    func test_frames_useOneBasedTargetCountAndPreserveOriginalReferencePath() {
        let selected = reference().setting(text(0x00081160, ["1", "3"], .IS))
        XCTAssertEqual(validate(selected, target: target().setting(text(0x00280008, ["3"], .IS)))[.references], .passed)
        let report = validate(selected, target: target().setting(text(0x00280008, ["2"], .IS)))
        XCTAssertEqual(report[.references], .failed)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .referenceSelectionOutOfRange &&
            $0.path == path + [.tag(0x00081160), .frame(2)] })
        XCTAssertEqual(validate(reference().setting(text(0x00081160, ["0"], .IS)), target: target())[.references], .failed)
    }

    func test_missingOrUnusableFrameGeometry_isNotAssumedToBeSingleFrame() {
        let selected = reference().setting(text(0x00081160, ["1"], .IS))
        XCTAssertEqual(validate(selected, target: target())[.references], .incomplete)
        let opaque = target().setting(.init(tag: 0x00280008, vr: .UN, value: .bytes(Data([1, 2]))))
        XCTAssertEqual(validate(selected, target: opaque)[.references], .incomplete)
        let unparsed = target().setting(.init(tag: 0x00280008, vr: .IS, value: .bytes(Data([49, 32]))))
        XCTAssertEqual(validate(selected, target: unparsed)[.references], .incomplete)
        for value in ["0", "-1", "invalid"] {
            let report = validate(selected, target: target().setting(text(0x00280008, [value], .IS)))
            XCTAssertTrue(report.diagnostics.contains { $0.code == .referenceTargetGeometryInvalid })
            XCTAssertFalse(report.diagnostics.contains { $0.code == .referenceSelectionOutOfRange })
        }
    }

    func test_invalidSelectors_failEvenWhenTargetIsUnavailable() {
        for element in [text(0x00081160, ["-1"], .IS), text(0x00081160, ["not a frame"], .IS),
                        .init(tag: 0x00081160, vr: .IS, value: .empty), unsigned(0x0062000B, [0]),
                        unsigned(0x0040A0B0, [0, 1])] {
            let report = validate(reference().setting(element), target: nil)
            XCTAssertEqual(report[.references], .failed)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .referenceTargetUnavailable })
            XCTAssertTrue(report.diagnostics.contains { $0.code == .referenceSelectionInvalid })
        }
        let opaque = reference().setting(.init(tag: 0x00081160, vr: .UN, value: .bytes(Data([1, 2]))))
        XCTAssertEqual(validate(opaque, target: target())[.references], .incomplete)
    }

    func test_mismatchedTargetIdentity_cannotProduceFalseSelectorBoundsEvidence() {
        let selected = reference().setting(text(0x00081160, ["10"], .IS))
        for tag in [0x00080016, 0x00080018, 0x0020000D, 0x0020000E] {
            let wrong = target().setting(text(tag, ["2.25.999"], .UI)).setting(text(0x00280008, ["1"], .IS))
            let report = validate(selected, target: wrong)
            XCTAssertEqual(report[.references], .failed)
            // The content pair checks SOP identities; the evidence pair also checks study/series identity.
            if [0x00080016, 0x00080018].contains(tag) {
                XCTAssertFalse(report.diagnostics.contains { $0.code == .referenceSelectionOutOfRange })
            }
            XCTAssertTrue(report.diagnostics.contains { $0.code == .referenceIdentityContradiction })
        }
    }

    func test_segments_matchDeclaredNumbersRatherThanSequencePositions() {
        let geometry = target().setting(sequence(0x00620002, [segment(7), segment(42)]))
        let valid = reference().setting(unsigned(0x0062000B, [42, 7]))
        XCTAssertEqual(validate(valid, target: geometry)[.references], .passed)
        let missing = validate(reference().setting(unsigned(0x0062000B, [1])), target: geometry)
        XCTAssertTrue(missing.diagnostics.contains { $0.code == .referenceSelectionOutOfRange &&
            $0.path == path + [.tag(0x0062000B)] })
        let duplicate = target().setting(sequence(0x00620002, [segment(7), segment(7)]))
        XCTAssertTrue(validate(valid, target: duplicate).diagnostics.contains { $0.code == .referenceTargetGeometryInvalid })
    }

    func test_unknownSegmentMetadata_cannotProveSelectedSegmentAbsent() {
        let selected = reference().setting(unsigned(0x0062000B, [42]))
        for geometry in [target(), target().setting(sequence(0x00620002, [segment(7), .init()]))] {
            let report = validate(selected, target: geometry)
            XCTAssertEqual(report[.references], .incomplete)
            XCTAssertFalse(report.diagnostics.contains { $0.code == .referenceSelectionOutOfRange })
        }
        XCTAssertEqual(validate(selected, target: target().setting(sequence(0x00620002, [])))[.references], .failed)
    }

    func test_waveformPairs_useOriginalMultiplexAndChannelPositionsAndAllowChannelZero() {
        let waveform = target().setting(sequence(0x54000100, [multiplex(2), multiplex(1), multiplex(3)]))
        let selected = reference().setting(unsigned(0x0040A0B0, [1, 0, 3, 2, 3, 3]))
        XCTAssertEqual(validate(selected, target: waveform)[.references], .passed)
        for values: [UInt] in [[4, 1], [2, 2]] {
            let report = validate(reference().setting(unsigned(0x0040A0B0, values)), target: waveform)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .referenceSelectionOutOfRange &&
                $0.path == path + [.tag(0x0040A0B0)] })
        }
        let odd = validate(reference().setting(unsigned(0x0040A0B0, [1, 2, 3])), target: waveform)
        XCTAssertTrue(odd.diagnostics.contains { $0.code == .invalidMultiplicity })
    }

    func test_waveformChannelCount_mustMatchActualChannelDefinitions() {
        let selected = reference().setting(unsigned(0x0040A0B0, [1, 1]))
        let inconsistent = target().setting(sequence(0x54000100, [multiplex(2).setting(unsigned(0x003A0005, [3]))]))
        XCTAssertTrue(validate(selected, target: inconsistent).diagnostics.contains { $0.code == .referenceTargetGeometryInvalid })
        for group in [multiplex(1).removing(0x003A0200), multiplex(1).removing(0x003A0005)] {
            let report = validate(selected, target: target().setting(sequence(0x54000100, [group])))
            XCTAssertEqual(report[.references], .incomplete)
            XCTAssertFalse(report.diagnostics.contains { $0.code == .referenceSelectionOutOfRange })
        }
    }

    func test_selectorAndTargetWork_shareTheExistingReferenceBudget() {
        let selected = reference().setting(unsigned(0x0062000B, [1]))
        let large = target().setting(sequence(0x00620002, (1...100).map { segment(UInt($0)) }))
        let report = DicomSRReferenceValidator.validate(document(selected), kind: .structuredReport,
            targets: [instance: large], limits: .init(maximumRuleEvaluations: 30)).report
        XCTAssertEqual(report[.references], .incomplete)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .evaluationLimitReached })
        let frames = reference().setting(text(0x00081160, (1...100).map(String.init), .IS))
        let limited = DicomSRReferenceValidator.validate(document(frames), kind: .structuredReport,
            targets: [instance: target().setting(text(0x00280008, ["100"], .IS))],
            limits: .init(maximumRuleEvaluations: 30)).report
        XCTAssertEqual(limited[.references], .incomplete)
        XCTAssertTrue(limited.diagnostics.contains { $0.code == .evaluationLimitReached })
    }

    private let instance = "2.25.23214001"
    private let path: [DicomValidationReport.PathComponent] = [.tag(0x0040A730), .item(0), .tag(0x00081199), .item(0)]
    private func validate(_ selected: DicomDataSet, target: DicomDataSet?) -> DicomValidationReport {
        DicomSRReferenceValidator.validate(document(selected), kind: .structuredReport,
            targets: target.map { [instance: $0] } ?? [:]).report
    }

    private func reference() -> DicomDataSet {
        .init(elements: [text(0x00081150, ["1.2.840.10008.5.1.4.1.1.2.1"], .UI), text(0x00081155, [instance], .UI)])
    }

    private func target() -> DicomDataSet {
        .init(elements: [text(0x00080016, ["1.2.840.10008.5.1.4.1.1.2.1"], .UI), text(0x00080018, [instance], .UI),
            text(0x0020000D, ["2.25.23214002"], .UI), text(0x0020000E, ["2.25.23214003"], .UI)])
    }

    private func document(_ selected: DicomDataSet) -> DicomDataSet {
        let image = DicomDataSet(elements: [text(0x0040A040, ["IMAGE"], .CS), sequence(0x00081199, [selected])])
        let series = DicomDataSet(elements: [text(0x0020000E, ["2.25.23214003"], .UI), sequence(0x00081199, [reference()])])
        let study = DicomDataSet(elements: [text(0x0020000D, ["2.25.23214002"], .UI), sequence(0x00081115, [series])])
        return .init(elements: [text(0x0040A040, ["CONTAINER"], .CS), sequence(0x0040A730, [image]), sequence(0x0040A375, [study])])
    }

    private func segment(_ number: UInt) -> DicomDataSet { .init(elements: [unsigned(0x00620004, [number])]) }
    private func multiplex(_ count: Int) -> DicomDataSet {
        .init(elements: [unsigned(0x003A0005, [UInt(count)]), sequence(0x003A0200, Array(repeating: .init(), count: count))])
    }

    private func unsigned(_ tag: Int, _ values: [UInt]) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers(values)) }
    private func text(_ tag: Int, _ values: [String], _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings(values)) }
    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
