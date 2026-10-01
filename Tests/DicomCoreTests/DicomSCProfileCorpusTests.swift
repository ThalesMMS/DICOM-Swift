import Foundation
import XCTest
@testable import DicomCore

/// Profile-level corpus for single-frame Secondary Capture: original Part 10 objects crossing
/// module boundaries, evaluated with stated external facts through the engine and the codec API.
final class DicomSCProfileCorpusTests: XCTestCase {
    private enum Expectation {
        case passed
        case failed(DicomValidationReport.Code, [DicomValidationReport.PathComponent])
        case incomplete(DicomValidationReport.Code, [DicomValidationReport.PathComponent])
    }

    private let facts = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied, nonBipedalAnatomy: .unsatisfied,
        pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied, calibratedImage: .unsatisfied)
    private let requiredLayers = Set(DicomValidationReport.Layer.allCases.filter { $0 != .operation })

    func test_originalCorpus_qualifiesTheProfileWithStatedFactsAndExplicitResiduals() throws {
        let sourceUID = "2.25.23219931"
        let source = try fixture().setting(text(0x00080018, sourceUID, .UI))
        let sourceImage = DicomDataSet(elements: [text(0x00081150, "1.2.840.10008.5.1.4.1.1.7", .UI), text(0x00081155, sourceUID, .UI),
            text(0x0028135A, "YES", .CS)])
        let hierarchy = sequence(0x00081115, [.init(elements: [text(0x0020000E, "2.25.23219913", .UI),
            sequence(0x0008114A, [.init(elements: [text(0x00081150, "1.2.840.10008.5.1.4.1.1.7", .UI), text(0x00081155, sourceUID, .UI)])])])])
        let cases: [(String, DicomDataSet, Expectation, Bool)] = [
            ("minimal", .init(), .passed, false),
            ("declared-common", declaredCommon(), .passed, false),
            ("declared-references", .init(elements: [sequence(0x00082112, [sourceImage]), hierarchy]), .passed, true),
            ("terminology-orientation", .init(elements: [sequence(0x00540410, [code("102538003", "SCT", "recumbent")]),
                sequence(0x30100030, [code("102540008", "SCT", "headfirst")])]),
             .incomplete(.conditionUndetermined, [.tag(0x00540410)]), false),
            ("specimen-container-type", specimen().setting(sequence(0x00400518, [code("433466003", "SCT", "Microscope slide")])),
             .incomplete(.conditionUndetermined, [.tag(0x00400518)]), false),
            ("signature-unverified", .init(elements: [sequence(0xFFFAFFFA, [.init(elements: [
                .init(tag: 0x04000005, vr: .US, value: .unsignedIntegers([1])), text(0x04000100, "2.25.23219940", .UI),
                text(0x04000105, "20260101120000", .DT), text(0x04000110, "X509_1993_SIG", .CS),
                .init(tag: 0x04000115, vr: .OB, value: .bytes(Data([1, 2]))), .init(tag: 0x04000120, vr: .OB, value: .bytes(Data([3, 4])))])])]),
             .incomplete(.semanticScopeUnavailable, [.tag(0xFFFAFFFA)]), false),
            ("icc-unknown-label", .init(elements: [profile(), text(0x00282002, "PRIVATE", .CS)]),
             .incomplete(.valueUnavailable, [.tag(0x00282002)]), false),
            ("contributing-equipment-terminology", .init(elements: [sequence(0x0018A001, [.init(elements: [text(0x00080070, "Isis", .LO),
                sequence(0x0040A170, [code("109102", "DCM", "Processing Equipment")])])])]),
             .incomplete(.conditionUndetermined, [.tag(0x0018A001), .item(0), .tag(0x0040A170)]), false),
            ("private-scheme-version", .init(elements: [sequence(0x00082218, [code("T1", "99ISIS", "Thorax").setting(text(0x00080103, "1", .SH))])]),
             .incomplete(.conditionUndetermined, [.tag(0x00082218), .item(0), .tag(0x00080103)]), false),
            ("patient-study-pregnancy", .init(elements: [.init(tag: 0x001021C0, vr: .US, value: .unsignedIntegers([7]))]),
             .failed(.attributeValueNotAllowed, [.tag(0x001021C0)]), false),
            ("patient-study-neutered-human", .init(elements: [text(0x00102203, "ALTERED", .CS)]),
             .failed(.conditionalAttributeForbidden, [.tag(0x00102203)]), false),
            ("sync-missing-trigger", .init(elements: [text(0x00200200, "1.2.840.10008.15.1.1", .UI), text(0x00181800, "Y", .CS)]),
             .failed(.requiredAttributeMissing, [.tag(0x0018106A)]), false),
            ("sync-channel-without-waveform", synchronization().setting(.init(tag: 0x0018106C, vr: .US, value: .unsignedIntegers([1, 1]))),
             .failed(.conditionalAttributeForbidden, [.tag(0x0018106C)]), false),
            ("specimen-missing-container", specimen().removing(0x00400512), .failed(.requiredAttributeMissing, [.tag(0x00400512)]), false),
            ("specimen-localization-required", specimen().setting(sequence(0x00400560, [specimenItem("S1"), specimenItem("S2")])),
             .failed(.requiredAttributeMissing, [.tag(0x00400560), .item(0), .tag(0x00400620)]), false),
            ("orientation-missing-equipment", .init(elements: [sequence(0x00540410, [code("102538003", "SCT", "recumbent")])]),
             .failed(.requiredAttributeMissing, [.tag(0x30100030)]), false),
            ("icc-truncated", .init(elements: [profile(declaredSize: 4096)]), .failed(.invalidBinaryLength, [.tag(0x00282000)]), false),
            ("icc-wrong-class", .init(elements: [profile(deviceClass: "mntr")]), .failed(.attributeValueContradiction, [.tag(0x00282000)]), false),
            ("icc-label-contradiction", .init(elements: [profile(), text(0x00282002, "ADOBERGB", .CS)]),
             .failed(.attributeValueContradiction, [.tag(0x00282002)]), false),
            ("acquisition-negative-duration", .init(elements: [.init(tag: 0x00189073, vr: .FD, value: .floats([-1]))]),
             .failed(.attributeValueContradiction, [.tag(0x00189073)]), false),
            ("rwvm-missing-units", .init(elements: [sequence(0x00409096, [mapping().removing(0x004008EA)])]),
             .failed(.requiredAttributeMissing, [.tag(0x00409096), .item(0), .tag(0x004008EA)]), false),
            ("other-patient-ids-missing-type", .init(elements: [sequence(0x00101002, [.init(elements: [text(0x00100020, "ID2", .LO)])])]),
             .failed(.requiredAttributeMissing, [.tag(0x00101002), .item(0), .tag(0x00100022)]), false),
            ("original-attributes-missing-reason", .init(elements: [sequence(0x04000561, [originalAttributes().removing(0x04000565)])]),
             .failed(.requiredAttributeMissing, [.tag(0x04000561), .item(0), .tag(0x04000565)]), false),
            ("conversion-source-missing-instance", .init(elements: [sequence(0x00209172, [.init(elements: [
                text(0x00081150, "1.2.840.10008.5.1.4.1.1.2.1", .UI), .init(tag: 0x00081160, vr: .IS, value: .strings(["1"]))])])]),
             .failed(.requiredAttributeMissing, [.tag(0x00209172), .item(0), .tag(0x00081155)]), false),
            ("request-missing-issuer-type", .init(elements: [sequence(0x00400275, [.init(elements: [
                sequence(0x00080051, [.init(elements: [text(0x00400032, "1.2.3", .UT)])]), text(0x00400009, "SPS1", .SH), text(0x00401001, "RP1", .SH)])])]),
             .failed(.requiredAttributeMissing, [.tag(0x00400275), .item(0), .tag(0x00080051), .item(0), .tag(0x00400033)]), false),
            ("anatomic-region-two-items", .init(elements: [sequence(0x00082218, [code("51185008", "SCT", "Thorax"), code("818981001", "SCT", "Abdomen")])]),
             .failed(.sequenceItemCountInvalid, [.tag(0x00082218)]), false),
            ("reference-missing-in-hierarchy", .init(elements: [sequence(0x00082112, [sourceImage.setting(text(0x00081155, "2.25.23219932", .UI))]), hierarchy]),
             .failed(.referenceEvidenceMissing, [.tag(0x00082112), .item(0), .tag(0x00081155)]), true),
            ("spatial-geometry-mismatch", .init(elements: [sequence(0x00082112, [sourceImage]), hierarchy]),
             .failed(.referenceTargetGeometryInvalid, [.tag(0x00082112), .item(0), .tag(0x0028135A)]), true)
        ]
        for (name, attributes, expectation, needsTargets) in cases {
            var instance = try fixture()
            for element in attributes.elements { instance.set(element) }
            let bytes = try DicomDataSetWriter.part10Data(from: instance)
            let target = name == "spatial-geometry-mismatch" ? source.setting(.init(tag: 0x00280010, vr: .US, value: .unsignedIntegers([4]))) : source
            let targets = needsTargets ? [sourceUID: target] : [:]
            let report = try DicomInstanceValidator.validate(bytes, targets: targets, imageConditions: facts)
            let outcome = report.outcome(requiring: requiredLayers)
            switch expectation {
            case .passed:
                XCTAssertEqual(outcome, .passed, "\(name): \(report.diagnostics)")
            case .failed(let code, let path):
                XCTAssertEqual(outcome, .failed, name)
                XCTAssertTrue(report.diagnostics.contains { $0.code == code && $0.path == path && $0.severity == .error }, "\(name): \(report.diagnostics)")
            case .incomplete(let code, let path):
                XCTAssertEqual(outcome, .incomplete, "\(name): \(report.diagnostics)")
                XCTAssertFalse(report.diagnostics.contains { $0.severity == .error }, name)
                XCTAssertTrue(report.diagnostics.contains { $0.code == code && $0.path == path }, "\(name): \(report.diagnostics)")
            }
            XCTAssertFalse(report.diagnostics.contains { $0.code == .moduleRuleUnavailable && $0.path == [.tag(0x00080016)] }, name)
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes, targets: targets, imageConditions: facts), report, name)
            if let folder = ProcessInfo.processInfo.environment["DICOM_SC_PROFILE_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                // The CLI has no target metadata; its exit code follows the report without targets.
                let cliOutcome = try DicomInstanceValidator.validate(bytes, imageConditions: facts).outcome(requiring: requiredLayers)
                try JSONSerialization.data(withJSONObject: ["outcome": outcome.rawValue, "needsTargets": needsTargets,
                    "exit": cliOutcome == .passed ? 0 : cliOutcome == .failed ? 1 : 2], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    func test_unstatedFacts_keepTheProfileIncompleteWithoutAGlobalMarker() throws {
        let bytes = try DicomDataSetWriter.part10Data(from: try fixture())
        let report = try DicomInstanceValidator.validate(bytes)
        XCTAssertEqual(report.outcome(requiring: requiredLayers), .incomplete)
        XCTAssertEqual(report[.vrAndVM], .passed)
        XCTAssertEqual(report[.references], .passed)
        XCTAssertFalse(report.diagnostics.contains { $0.code == .moduleRuleUnavailable })
        XCTAssertTrue(report.diagnostics.allSatisfy { $0.code == .conditionUndetermined })
    }

    func test_specimenEmptyType2ContainerType_hasNoTerminologyToQualify() throws {
        var data = try fixture()
        for element in specimen().elements { data.set(element) }
        let bytes = try DicomDataSetWriter.part10Data(from: data)
        XCTAssertEqual(try DicomInstanceValidator.validate(bytes, imageConditions: facts).outcome(requiring: requiredLayers), .passed)
    }

    func test_specimenContainerType_rejectsMultipleCodedItems() throws {
        var data = try fixture()
        for element in specimen().elements { data.set(element) }
        let container = code("433466003", "SCT", "Microscope slide")
        data.set(sequence(0x00400518, [container, container]))
        let bytes = try DicomDataSetWriter.part10Data(from: data)
        XCTAssertEqual(try DicomInstanceValidator.validate(bytes, imageConditions: facts).outcome(requiring: requiredLayers), .failed)
    }

    private func declaredCommon() -> DicomDataSet {
        var declared = DicomDataSet(elements: [
            text(0x00101010, "030Y", .AS), text(0x001021A0, "NO", .CS), .init(tag: 0x001021C0, vr: .US, value: .unsignedIntegers([1])),
            text(0x00380010, "ADM1", .LO), sequence(0x00380014, [.init(elements: [text(0x00400031, "LOCAL", .UT)])]),
            .init(tag: 0x00200012, vr: .IS, value: .strings(["1"])), .init(tag: 0x00201002, vr: .IS, value: .strings(["1"])),
            .init(tag: 0x00189073, vr: .FD, value: .floats([2.5])), text(0x00080070, "", .LO),
            sequence(0x00081041, [code("RAD", "DCM", "Radiology")]),
            sequence(0x0018100A, [.init(elements: [text(0x00181009, "(01)00000000000000", .UT)])]),
            sequence(0x00101002, [.init(elements: [text(0x00100020, "ID2", .LO), text(0x00100022, "TEXT", .CS), text(0x00100021, "ISSUER", .LO)])]),
            sequence(0x00081110, [.init(elements: [text(0x00081150, "1.2.840.10008.3.1.2.3.1", .UI), text(0x00081155, "2.25.23219950", .UI)])]),
            sequence(0x00400275, [.init(elements: [text(0x00400009, "SPS1", .SH), text(0x00401001, "RP1", .SH),
                sequence(0x00400008, [code("113682", "DCM", "ACR-NEMA Frame")])])]),
            sequence(0x00082218, [code("51185008", "SCT", "Thorax")]),
            sequence(0x00409096, [mapping()]),
            sequence(0x04000561, [originalAttributes()]),
            profile(), text(0x00282002, "SRGB", .CS)
        ])
        for element in synchronization().elements { declared.set(element) }
        return declared
    }

    private func synchronization() -> DicomDataSet {
        .init(elements: [text(0x00200200, "1.2.840.10008.15.1.1", .UI), text(0x0018106A, "NO TRIGGER", .CS), text(0x00181800, "N", .CS),
            text(0x00181802, "NTP", .CS)])
    }

    private func specimen() -> DicomDataSet {
        .init(elements: [text(0x00400512, "C1", .LO), .init(tag: 0x00400513, vr: .SQ, value: .sequence([])),
            .init(tag: 0x00400518, vr: .SQ, value: .sequence([])), sequence(0x00400560, [specimenItem("S1")])])
    }

    private func specimenItem(_ identifier: String) -> DicomDataSet {
        .init(elements: [text(0x00400551, identifier, .LO), text(0x00400554, "2.25.2321996" + identifier.dropFirst(), .UI),
            .init(tag: 0x00400562, vr: .SQ, value: .sequence([])), .init(tag: 0x00400610, vr: .SQ, value: .sequence([]))])
    }

    private func mapping() -> DicomDataSet {
        .init(elements: [text(0x00283003, "Linear", .LO), sequence(0x004008EA, [code("1", "UCUM", "no units")]),
            text(0x00409210, "L1", .SH), .init(tag: 0x00409216, vr: .US, value: .unsignedIntegers([0])),
            .init(tag: 0x00409211, vr: .US, value: .unsignedIntegers([255])), .init(tag: 0x00409224, vr: .FD, value: .floats([0])),
            .init(tag: 0x00409225, vr: .FD, value: .floats([1]))])
    }

    private func originalAttributes() -> DicomDataSet {
        .init(elements: [sequence(0x04000550, [.init(elements: [text(0x00080080, "Old", .LO)])]), text(0x04000562, "20260101120000", .DT),
            text(0x04000563, "Isis", .LO), text(0x04000564, "", .LO), text(0x04000565, "COERCE", .CS)])
    }

    /// Minimal ICC input profile: header, one `desc` tag, sRGB description.
    private func profile(deviceClass: String = "scnr", declaredSize: Int? = nil) -> DicomDataElement {
        var description = Data("desc".utf8) + Data(repeating: 0, count: 4)
        let label = Data("sRGB IEC61966-2.1".utf8) + Data([0])
        description += UInt32(label.count).bigEndianBytes + label
        while !description.count.isMultiple(of: 4) { description.append(0) }
        var header = Data(repeating: 0, count: 128)
        header.replaceSubrange(8..<12, with: [2, 0x10, 0, 0])
        header.replaceSubrange(12..<16, with: Data(deviceClass.utf8))
        header.replaceSubrange(16..<20, with: Data("RGB ".utf8))
        header.replaceSubrange(20..<24, with: Data("XYZ ".utf8))
        header.replaceSubrange(36..<40, with: Data("acsp".utf8))
        var bytes = header + UInt32(1).bigEndianBytes + Data("desc".utf8) + UInt32(144).bigEndianBytes
            + UInt32(description.count).bigEndianBytes + description
        bytes.replaceSubrange(0..<4, with: UInt32(declaredSize ?? bytes.count).bigEndianBytes)
        if !bytes.count.isMultiple(of: 2) { bytes.append(0) }
        return .init(tag: 0x00282000, vr: .OB, value: .bytes(bytes))
    }

    private func fixture() throws -> DicomDataSet {
        DicomSecondaryCaptureBuilder.dataSet(
            pixelData: try .rgb8(columns: 2, rows: 2, data: Data(repeating: 1, count: 12)),
            options: .init(sopInstanceUID: "2.25.23219921", studyInstanceUID: "2.25.23219922",
                           seriesInstanceUID: "2.25.23219913", seriesNumber: 1, instanceNumber: 1),
            requiredType2Attributes: .init()
        )
    }
    private func code(_ value: String, _ scheme: String, _ meaning: String) -> DicomDataSet {
        .init(elements: [text(0x00080100, value, .SH), text(0x00080102, scheme, .SH), text(0x00080104, meaning, .LO)])
    }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings([value]))
    }
    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}

private extension UInt32 {
    var bigEndianBytes: Data { Data([UInt8(self >> 24), UInt8(self >> 16 & 0xFF), UInt8(self >> 8 & 0xFF), UInt8(self & 0xFF)]) }
}
