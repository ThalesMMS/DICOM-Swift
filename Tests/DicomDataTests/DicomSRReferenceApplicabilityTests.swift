import Foundation
import XCTest
@testable import DicomData

final class DicomSRReferenceApplicabilityTests: XCTestCase {
    func test_incompatiblePrimarySOPClass_failsEvenWithoutTarget() {
        for (kind, suffix) in [("IMAGE", "9.1.1"), ("IMAGE", "88.33"), ("WAVEFORM", "2"),
                               ("WAVEFORM", "9.100.1"), ("COMPOSITE", "2"), ("COMPOSITE", "9.8.1")] {
            let report = validate(kind: kind, sopClass: prefix + suffix, supplyTarget: false)
            XCTAssertEqual(report[.references], .failed, "\(kind) \(suffix)")
            XCTAssertTrue(report.diagnostics.contains { $0.severity == .error && $0.path == primaryPath + [.tag(0x00081150)] })
        }
    }

    func test_compatiblePrimarySOPClasses_passWithIdentityMatchedTargets() {
        for (kind, suffix) in [("IMAGE", "2"), ("IMAGE", "66.4"), ("IMAGE", "481.24"),
                               ("WAVEFORM", "9.1.1"), ("WAVEFORM", "9.8.1"), ("COMPOSITE", "88.33"),
                               ("COMPOSITE", "66.5"), ("COMPOSITE", "9.100.1"), ("COMPOSITE", "11.9")] {
            XCTAssertEqual(validate(kind: kind, sopClass: prefix + suffix)[.references], .passed, "\(kind) \(suffix)")
        }
    }

    func test_unknownSOPClass_cannotPassFromUIDPrefixOrPixelMetadata() {
        for sopClass in [prefix + "2.999", "2.25.23219999"] {
            let report = validate(kind: "IMAGE", sopClass: sopClass)
            XCTAssertEqual(report[.references], .incomplete)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .referenceRuleUnavailable &&
                $0.path == primaryPath + [.tag(0x00081150)] })
            XCTAssertFalse(report.diagnostics.contains { $0.severity == .error })
        }
    }

    func test_imageCompanions_requireSoftcopyPresentationStateOrRealWorldMap() {
        for suffix in ["11.1", "11.2", "11.3", "11.4", "11.5", "11.8", "11.12"] {
            XCTAssertEqual(validate(kind: "IMAGE", sopClass: prefix + "2", auxiliary: (0x00081199, prefix + suffix))[.references], .passed)
        }
        for suffix in ["2", "67", "11.6", "11.7", "11.9", "11.10", "11.11", "9.100.1", "9.100.2"] {
            let report = validate(kind: "IMAGE", sopClass: prefix + "2", auxiliary: (0x00081199, prefix + suffix))
            XCTAssertEqual(report[.references], .failed, suffix)
            XCTAssertTrue(report.diagnostics.contains { $0.severity == .error &&
                $0.path == primaryPath + [.tag(0x00081199), .item(0), .tag(0x00081150)] })
        }
        XCTAssertEqual(validate(kind: "IMAGE", sopClass: prefix + "2", auxiliary: (0x0008114B, prefix + "67"))[.references], .passed)
        XCTAssertEqual(validate(kind: "IMAGE", sopClass: prefix + "2", auxiliary: (0x0008114B, prefix + "11.1"))[.references], .failed)
    }

    func test_incompatibleOrUnknownClass_cannotSupplySelectorBoundsEvidence() {
        let frame = DicomDataElement(tag: 0x00081160, vr: .IS, value: .strings(["10"]))
        for suffix in ["9.1.1", "2.999"] {
            let report = validate(kind: "IMAGE", sopClass: prefix + suffix, selector: frame)
            XCTAssertNotEqual(report[.references], .passed)
            XCTAssertFalse(report.diagnostics.contains { $0.code == .referenceSelectionOutOfRange })
        }
        let invalid = DicomDataElement(tag: 0x00081160, vr: .IS, value: .strings(["0"]))
        XCTAssertTrue(validate(kind: "IMAGE", sopClass: prefix + "9.1.1", selector: invalid)
            .diagnostics.contains { $0.code == .referenceSelectionInvalid })
    }

    func test_unqualifiedReferencePlacement_remainsIncomplete() {
        let report = validate(kind: "NUM", sopClass: prefix + "2")
        XCTAssertEqual(report[.references], .incomplete)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .referenceRuleUnavailable && $0.path == primaryPath })
        XCTAssertEqual(validate(kind: "COMPOSITE", sopClass: prefix + "88.33",
            auxiliary: (0x00081199, prefix + "11.1"))[.references], .incomplete)
    }

    private let prefix = "1.2.840.10008.5.1.4.1.1."
    private let primaryPath: [DicomValidationReport.PathComponent] = [.tag(0x0040A730), .item(1), .tag(0x00081199), .item(0)]

    private func validate(kind: String, sopClass: String, supplyTarget: Bool = true,
                          auxiliary: (Int, String)? = nil, selector: DicomDataElement? = nil) -> DicomValidationReport {
        let primary = pair(sopClass: sopClass, instance: "2.25.23217001")
        var reference = selector.map { primary.setting($0) } ?? primary
        var evidence = [primary]
        var targets = supplyTarget ? ["2.25.23217001": target(sopClass: sopClass, instance: "2.25.23217001")] : [:]
        if let (tag, companionClass) = auxiliary {
            let companion = pair(sopClass: companionClass, instance: "2.25.23217002")
            reference = reference.setting(sequence(tag, [companion]))
            evidence.append(companion)
            if supplyTarget { targets["2.25.23217002"] = target(sopClass: companionClass, instance: "2.25.23217002") }
        }
        let child = DicomDataSet(elements: [text(0x0040A040, kind, .CS), sequence(0x00081199, [reference])])
        let series = DicomDataSet(elements: [text(0x0020000E, "2.25.23217004", .UI), sequence(0x00081199, evidence)])
        let study = DicomDataSet(elements: [text(0x0020000D, "2.25.23217003", .UI), sequence(0x00081115, [series])])
        let document = DicomDataSet(elements: [text(0x0040A040, "CONTAINER", .CS),
            sequence(0x0040A730, [.init(elements: [text(0x0040A040, "TEXT", .CS)]), child]), sequence(0x0040A375, [study])])
        return DicomSRReferenceValidator.validate(document, kind: .structuredReport, targets: targets).report
    }

    private func pair(sopClass: String, instance: String) -> DicomDataSet {
        .init(elements: [text(0x00081150, sopClass, .UI), text(0x00081155, instance, .UI)])
    }

    private func target(sopClass: String, instance: String) -> DicomDataSet {
        .init(elements: [text(0x00080016, sopClass, .UI), text(0x00080018, instance, .UI),
            text(0x0020000D, "2.25.23217003", .UI), text(0x0020000E, "2.25.23217004", .UI),
            text(0x00280008, "1", .IS), .init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data([0, 0])))])
    }

    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings([value])) }
    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
