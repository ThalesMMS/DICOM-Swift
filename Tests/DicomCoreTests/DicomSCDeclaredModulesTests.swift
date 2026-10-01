import Foundation
import XCTest
@testable import DicomCore

final class DicomSCDeclaredModulesTests: XCTestCase {
    func test_originalCorpus_validatesDeclaredClinicalTrialAndDeviceModules() throws {
        let subject = DicomDataSet(elements: [text(0x00120010, "Synthetic sponsor"), text(0x00120020, "P1"),
            text(0x00120021, ""), text(0x00120030, ""), text(0x00120031, ""), text(0x00120040, "S1")])
        let consent = DicomDataSet(elements: [text(0x00120085, "YES", .CS), text(0x00120084, "PUBLIC_RELEASE", .CS)])
        let study = DicomDataSet(elements: [text(0x00120050, "", .LO), sequence(0x00120083, [consent])])
        let device = DicomDataSet(elements: [text(0x00080120, "urn:example:device", .UR),
            text(0x00080104, "Synthetic device")])
        let diameter = DicomDataElement(tag: 0x00500016, vr: .DS, value: .strings(["2"]))
        let cases: [(String, DicomDataSet, [DicomValidationReport.PathComponent]?)] = [
            ("subject", subject, nil),
            ("subject-reading", subject.removing(0x00120040).setting(text(0x00120042, "R1")), nil),
            ("subject-both", subject.setting(text(0x00120042, "R1")), nil),
            ("subject-missing-sponsor", subject.removing(0x00120010), [.tag(0x00120010)]),
            ("subject-empty-protocol", subject.setting(text(0x00120020, "")), [.tag(0x00120020)]),
            ("subject-missing-type2", subject.removing(0x00120030), [.tag(0x00120030)]),
            ("subject-missing-identifiers", subject.removing(0x00120040), [.tag(0x00120042)]),
            ("subject-ethics-condition", subject.setting(text(0x00120082, "A1")), [.tag(0x00120081)]),
            ("subject-other-protocol", subject.setting(sequence(0x00120023, [.init(elements: [text(0x00120020, "P2")])])),
             [.tag(0x00120023), .item(0), .tag(0x00120022)]),
            ("study-public", study, nil),
            ("study-no-consent", study.setting(sequence(0x00120083, [.init(elements: [text(0x00120085, "NO", .CS)])])), nil),
            ("study-withdrawn", study.setting(sequence(0x00120083, [consent.setting(text(0x00120085, "WITHDRAWN", .CS))])), nil),
            ("study-named-protocol", study.setting(sequence(0x00120083, [consent
                .setting(text(0x00120084, "NAMED_PROTOCOL", .CS)).setting(text(0x00120020, "P2"))])), nil),
            ("study-missing-named-protocol", study.setting(sequence(0x00120083, [consent
                .setting(text(0x00120084, "NAMED_PROTOCOL", .CS))])), [.tag(0x00120083), .item(0), .tag(0x00120020)]),
            ("study-missing-timepoint", study.removing(0x00120050), [.tag(0x00120050)]),
            ("study-missing-distribution", study.setting(sequence(0x00120083, [consent.removing(0x00120084)])),
             [.tag(0x00120083), .item(0), .tag(0x00120084)]),
            ("study-invalid-consent", study.setting(sequence(0x00120083, [consent.setting(text(0x00120085, "MAYBE", .CS))])),
             [.tag(0x00120083), .item(0), .tag(0x00120085)]),
            ("study-offset-condition", study.setting(.init(tag: 0x00120052, vr: .FD, value: .floats([1.5]))), [.tag(0x00120053)]),
            ("series-empty-center", .init(elements: [text(0x00120060, "")]), nil),
            ("series-missing-center", .init(elements: [text(0x00120071, "1")]), [.tag(0x00120060)]),
            ("device", .init(elements: [sequence(0x00500010, [device])]), nil),
            ("device-empty", .init(elements: [sequence(0x00500010, [])]), [.tag(0x00500010)]),
            ("device-missing-code", .init(elements: [sequence(0x00500010, [device.removing(0x00080120)])]),
             [.tag(0x00500010), .item(0)]),
            ("device-diameter-condition", .init(elements: [sequence(0x00500010, [device.setting(diameter)])]),
             [.tag(0x00500010), .item(0), .tag(0x00500017)]),
            ("device-empty-type2", .init(elements: [sequence(0x00500010, [device.setting(diameter).setting(text(0x00500017, "", .CS))])]), nil),
            ("device-private-defined-term", .init(elements: [sequence(0x00500010,
                [device.setting(diameter).setting(text(0x00500017, "PRIVATE", .CS))])]), nil)
        ]
        for (name, attributes, errorPath) in cases {
            var source = try fixture()
            for element in attributes.elements { source.set(element) }
            let bytes = try DicomDataSetWriter.part10Data(from: source)
            let report = try DicomInstanceValidator.validate(bytes)
            let errors = report.diagnostics.filter { $0.severity == .error }
            if let errorPath {
                XCTAssertTrue(errors.contains { $0.path == errorPath }, "\(name): \(errors)")
            } else {
                XCTAssertTrue(errors.isEmpty, "\(name): \(errors)")
            }
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes), report, name)
            if let folder = ProcessInfo.processInfo.environment["DICOM_SC_DECLARED_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONEncoder().encode(report).write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    func test_namedProtocolWithoutIntent_remainsUndeterminedAndPreservesItemPath() {
        let source = DicomDataSet(elements: [text(0x00120010, "Synthetic sponsor"), text(0x00120020, "P1"),
            text(0x00120021, ""), text(0x00120030, ""), text(0x00120031, ""), text(0x00120040, "S1"),
            text(0x00120050, ""), sequence(0x00120083, [
            .init(elements: [text(0x00120085, "YES", .CS), text(0x00120084, "NAMED_PROTOCOL", .CS)])
        ])])
        let report = DicomClinicalTrialModules.validate(source)
        XCTAssertEqual(report[.attributes], .incomplete)
        XCTAssertTrue(report.diagnostics.contains {
            $0.code == .conditionUndetermined && $0.path == [.tag(0x00120083), .item(0), .tag(0x00120020)]
        })
        let limited = DicomClinicalTrialModules.validate(source, limits: .init(maximumRuleEvaluations: 1))
        XCTAssertTrue(limited.diagnostics.contains { $0.code == .evaluationLimitReached })
        XCTAssertEqual(DicomClinicalTrialModules.validate(.init()).diagnostics, [])
        XCTAssertEqual(DicomDeviceModule.validate(.init()).diagnostics, [])
    }

    private func fixture() throws -> DicomDataSet {
        DicomSecondaryCaptureBuilder.dataSet(
            pixelData: try .rgb8(columns: 2, rows: 2, data: Data(repeating: 1, count: 12)),
            options: .init(sopInstanceUID: "2.25.23219801", studyInstanceUID: "2.25.23219802",
                           seriesInstanceUID: "2.25.23219803", seriesNumber: 1, instanceNumber: 1),
            requiredType2Attributes: .init()
        )
    }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR = .LO) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings([value]))
    }
    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
