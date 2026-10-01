import Foundation
import XCTest
@testable import DicomCore

final class DicomCommonInstanceReferenceModuleTests: XCTestCase {
    func test_originalSC_requiresReferencedSeriesIdentityAndInstances() throws {
        for (item, missing) in [(DicomDataSet(), 0x0020000E),
            (DicomDataSet(elements: [text(0x0020000E, ["2.25.44"], .UI)]), 0x0008114A)] {
            let source = fixture().setting(.init(tag: 0x00081115, vr: .SQ, value: .sequence([.init(dataSet: item)])))
            let report = try DicomInstanceValidator.validate(DicomDataSetWriter.part10Data(from: source))
            XCTAssertTrue(report.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path.last == .tag(missing) })
        }
    }

    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }

    private func reference() -> DicomDataSet {
        .init(elements: [text(0x00081150, ["1.2.840.10008.5.1.4.1.1.7"], .UI), text(0x00081155, ["2.25.9001"], .UI)])
    }

    private func series(_ instance: DicomDataSet) -> DicomDataSet {
        .init(elements: [text(0x0020000E, ["2.25.44"], .UI), sequence(0x0008114A, [instance])])
    }

    func test_partialHierarchy_doesNotInventConflictOrHideKnownConflict() throws {
        let valid = series(reference())
        let missing = valid.removing(0x0020000E)
        let conflicting = valid.setting(text(0x0020000E, ["2.25.45"], .UI))
        for items in [[missing, valid], [valid, missing]] {
            let report = DicomCommonInstanceReferenceModule.validate(fixture().setting(sequence(0x00081115, items)))
            XCTAssertEqual(report[.attributes], .failed)
            XCTAssertEqual(report[.references], .incomplete)
            XCTAssertFalse(report.diagnostics.contains { $0.code == .referenceIdentityContradiction })
            let bytes = try DicomDataSetWriter.part10Data(from: fixture().setting(sequence(0x00081115, items)))
            let original = try DicomInstanceValidator.validate(bytes)
            XCTAssertEqual(original[.attributes], .failed)
            XCTAssertEqual(original[.references], .incomplete)
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes), original)
        }
        for items in [[missing, valid, conflicting], [valid, missing, conflicting], [valid, conflicting, missing]] {
            let report = DicomCommonInstanceReferenceModule.validate(fixture().setting(sequence(0x00081115, items)))
            XCTAssertEqual(report[.references], .failed)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .referenceIdentityContradiction })
        }
        let study = DicomDataSet(elements: [text(0x0020000D, ["2.25.55"], .UI), sequence(0x00081115, [valid])])
        for items in [[study.removing(0x0020000D), study], [study, study.removing(0x0020000D)]] {
            let report = DicomCommonInstanceReferenceModule.validate(fixture().setting(sequence(0x00081200, items)))
            XCTAssertEqual(report[.attributes], .failed)
            XCTAssertEqual(report[.references], .incomplete)
            XCTAssertFalse(report.diagnostics.contains { $0.code == .referenceIdentityContradiction })
        }
    }

    func test_complementaryIdentity_detectsSeriesAssignedToDifferentStudies() throws {
        let local = series(reference()).removing(0x0020000E)
        let partial = DicomDataSet(elements: [sequence(0x00081115, [series(reference())])])
        for (seriesUID, expected) in [("2.25.44", DicomValidationReport.Outcome.failed), ("2.25.45", .incomplete)] {
            let other = DicomDataSet(elements: [text(0x0020000D, ["2.25.55"], .UI),
                sequence(0x00081115, [series(reference().setting(text(0x00081155, ["2.25.9002"], .UI)))
                    .setting(text(0x0020000E, [seriesUID], .UI))])])
            for items in [[partial, other], [other, partial]] {
                let source = fixture().setting(sequence(0x00081115, [local])).setting(sequence(0x00081200, items))
                let report = DicomCommonInstanceReferenceModule.validate(source)
                XCTAssertEqual(report[.attributes], .failed)
                XCTAssertEqual(report[.references], expected)
                XCTAssertEqual(report.diagnostics.contains { $0.code == .referenceIdentityContradiction }, expected == .failed)
                let bytes = try DicomDataSetWriter.part10Data(from: source)
                let original = try DicomInstanceValidator.validate(bytes)
                XCTAssertEqual(original[.attributes], .failed)
                XCTAssertEqual(original[.references], expected)
                XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes), original)
            }
        }
    }

    func test_suppliedTargetIdentity_checksInstanceClassStudyAndSeries() throws {
        let source = fixture().setting(sequence(0x00081115, [series(reference())]))
        let target = fixture().setting(text(0x00080018, ["2.25.9001"], .UI))
            .setting(text(0x0020000E, ["2.25.44"], .UI))
        let matched = DicomCommonInstanceReferenceModule.validate(source, targets: ["2.25.9001": target])
        XCTAssertFalse(matched.diagnostics.contains { $0.code == .referenceTargetUnavailable || $0.severity == .error })
        XCTAssertEqual(matched[.references], .passed)
        // A General Reference to an instance outside the declared hierarchy violates C.12.2 completeness.
        let unlisted = source.setting(sequence(0x00082112, [reference().setting(text(0x00081155, ["2.25.9009"], .UI))]))
        XCTAssertTrue(DicomCommonInstanceReferenceModule.validate(unlisted, targets: ["2.25.9001": target]).diagnostics.contains {
            $0.code == .referenceEvidenceMissing && $0.path == [.tag(0x00082112), .item(0), .tag(0x00081155)]
        })
        let listed = source.setting(sequence(0x00082112, [reference()]))
        XCTAssertFalse(DicomCommonInstanceReferenceModule.validate(listed, targets: ["2.25.9001": target]).diagnostics.contains {
            $0.code == .referenceEvidenceMissing
        })
        for tag in [0x00080016, 0x00080018, 0x0020000D, 0x0020000E] {
            let wrong = target.setting(text(tag, ["2.25.999"], .UI))
            let report = DicomCommonInstanceReferenceModule.validate(source, targets: ["2.25.9001": wrong])
            XCTAssertTrue(report.diagnostics.contains { $0.code == .referenceIdentityContradiction &&
                $0.path == [.tag(0x00081115), .item(0), .tag(0x0008114A), .item(0)] })
            let bytes = try DicomDataSetWriter.part10Data(from: source)
            let composed = try DicomInstanceValidator.validate(bytes, targets: ["2.25.9001": wrong])
            XCTAssertEqual(composed[.references], .failed)
        }
        XCTAssertTrue(DicomCommonInstanceReferenceModule.validate(source).diagnostics.contains { $0.code == .referenceTargetUnavailable })
        for limits in [DicomAttributeValidator.Limits(maximumDepth: 0), .init(maximumRuleEvaluations: 1)] {
            let report = DicomCommonInstanceReferenceModule.validate(source, limits: limits)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .evaluationLimitReached })
        }
        // One unavailable target plus one unlisted reference exceed a single-diagnostic budget.
        XCTAssertTrue(DicomCommonInstanceReferenceModule.validate(unlisted, limits: .init(maximumDiagnostics: 1)).diagnostics.contains {
            $0.code == .evaluationLimitReached
        })
    }

    /// Isis issue #2516: without supplied targets, the references of an object are one limitation whatever their
    /// number, so a derived object over a long series keeps its diagnostic budget; a reference missing from supplied
    /// targets is still reported where it is.
    func test_unsuppliedTargets_areOneLimitationForTheWholeObject() throws {
        let references = (0..<300).map { reference().setting(text(0x00081155, ["2.25.9\($0)"], .UI)) }
        let source = fixture().setting(sequence(0x00081115, [DicomDataSet(elements: [text(0x0020000E, ["2.25.44"], .UI),
                                                                                   sequence(0x0008114A, references)])]))
        let report = DicomCommonInstanceReferenceModule.validate(source)
        XCTAssertEqual(report.diagnostics.filter { $0.code == .referenceTargetUnavailable }.map(\.path), [[]])
        XCTAssertFalse(report.diagnostics.contains { $0.code == .evaluationLimitReached })
        XCTAssertEqual(report[.references], .incomplete)
        let composed = try DicomInstanceValidator.validate(DicomDataSetWriter.part10Data(from: source))
        XCTAssertFalse(composed.diagnostics.contains { $0.code == .evaluationLimitReached })
        XCTAssertEqual(composed.diagnostics.filter { $0.code == .referenceTargetUnavailable }.count, 1)

        let target = fixture().setting(text(0x00080018, ["2.25.90"], .UI)).setting(text(0x0020000E, ["2.25.44"], .UI))
        let partial = DicomCommonInstanceReferenceModule.validate(source, targets: ["2.25.90": target],
                                                                  limits: .init(maximumDiagnostics: 1_000))
        let unavailable = partial.diagnostics.filter { $0.code == .referenceTargetUnavailable }
        XCTAssertEqual(unavailable.count, 299)
        XCTAssertEqual(unavailable.first?.path, [.tag(0x00081115), .item(0), .tag(0x0008114A), .item(1), .tag(0x00081155)])
    }

    func test_originalCorpus_preservesHierarchyRequirementsAndOtherStudyMeaning() throws {
        let validSeries = series(reference())
        let same = fixture().setting(sequence(0x00081115, [validSeries]))
        let other = DicomDataSet(elements: [text(0x0020000D, ["2.25.55"], .UI), sequence(0x00081115, [validSeries])])
        let cases: [(String, DicomDataSet, Bool)] = [
            ("same-study", same, false), ("other-study", fixture().setting(sequence(0x00081200, [other])), false),
            ("conflicting-hierarchies", same.setting(sequence(0x00081200, [other])), true),
            ("both-hierarchies", same.setting(sequence(0x00081200, [other.setting(sequence(0x00081115, [
                series(reference().setting(text(0x00081155, ["2.25.9002"], .UI))).setting(text(0x0020000E, ["2.25.45"], .UI))]))])), false),
            ("empty-series", fixture().setting(sequence(0x00081115, [])), true),
            ("missing-series-uid", fixture().setting(sequence(0x00081115, [validSeries.removing(0x0020000E)])), true),
            ("empty-instances", fixture().setting(sequence(0x00081115, [validSeries.setting(sequence(0x0008114A, []))])), true),
            ("missing-class", fixture().setting(sequence(0x00081115, [series(reference().removing(0x00081150))])), true),
            ("missing-instance", fixture().setting(sequence(0x00081115, [series(reference().removing(0x00081155))])), true),
            ("missing-study", fixture().setting(sequence(0x00081200, [other.removing(0x0020000D)])), true),
            ("current-as-other", fixture().setting(sequence(0x00081200, [other.setting(text(0x0020000D, ["2.25.23213702"], .UI))])), true)
        ]
        for (name, source, failed) in cases {
            let bytes = try DicomDataSetWriter.part10Data(from: source)
            let report = try DicomInstanceValidator.validate(bytes)
            XCTAssertEqual(report[.attributes] == .failed || report[.references] == .failed, failed, name)
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes), report)
            if let folder = ProcessInfo.processInfo.environment["DICOM_COMMON_REFERENCE_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: ["attributes": report[.attributes].rawValue,
                    "references": report[.references].rawValue, "exit": failed ? 1 : 2], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    private func fixture() -> DicomDataSet {
        var dataSet = DicomDataSet(elements: [text(0x00080016, ["1.2.840.10008.5.1.4.1.1.7"], .UI), text(0x00080018, ["2.25.23213701"], .UI),
            text(0x00280004, ["MONOCHROME2"], .CS), number(0x00280002, [1]), number(0x00280010, [2]), number(0x00280011, [2]),
            number(0x00280100, [8]), number(0x00280101, [8]), number(0x00280102, [7]), number(0x00280103, [0]),
            .init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data(repeating: 1, count: 4)))])
        for (tag, vr, value) in [(0x0020000D, DicomVR.UI, "2.25.23213702"), (0x0020000E, .UI, "2.25.23213703"),
            (0x00100010, .PN, ""), (0x00100020, .LO, ""), (0x00100030, .DA, ""), (0x00100040, .CS, ""),
            (0x00080020, .DA, ""), (0x00080030, .TM, ""), (0x00080090, .PN, ""), (0x00200010, .SH, ""),
            (0x00080050, .SH, ""), (0x00200011, .IS, ""), (0x00200013, .IS, ""), (0x00200020, .CS, ""),
            (0x00080064, .CS, "WSD"), (0x00080060, .CS, "OT")] { dataSet.set(text(tag, [value], vr)) }
        return dataSet
    }
    private func text(_ tag: Int, _ values: [String], _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings(values)) }
    private func number(_ tag: Int, _ values: [UInt]) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers(values)) }
}
