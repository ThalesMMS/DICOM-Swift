import Foundation
import XCTest
@testable import DicomCore

final class DicomUltrasoundCorpusTests: XCTestCase {
    private let sop = "1.2.840.10008.5.1.4.1.1.6.1"
    private let layers = Set(DicomValidationReport.Layer.allCases.filter { $0 != .operation })
    private let facts = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied,
        nonBipedalAnatomy: .unsatisfied, pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied,
        ultrasoundStagedProtocol: .unsatisfied, contrastMediaUsed: .unsatisfied, nonSquarePixels: .unsatisfied)

    private struct Case {
        let name: String
        let dataSet: DicomDataSet
        let outcome: DicomValidationReport.Outcome
        let tag: Int?
        let facts: DicomCompositeImageModules.Conditions?

        init(_ name: String, _ dataSet: DicomDataSet, _ outcome: DicomValidationReport.Outcome = .passed,
             tag: Int? = nil, facts: DicomCompositeImageModules.Conditions? = nil) {
            self.name = name; self.dataSet = dataSet; self.outcome = outcome; self.tag = tag; self.facts = facts
        }
    }

    func test_originalUltrasoundCorpus_composesModulesAndRejectsContradictions() throws {
        let base = fixture()
        let withRegion = base.setting(sequence(0x00186011, [region()]))
        let stagedFacts = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied,
            nonBipedalAnatomy: .unsatisfied, pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied,
            ultrasoundStagedProtocol: .satisfied, contrastMediaUsed: .unsatisfied, nonSquarePixels: .unsatisfied)
        let contrastFacts = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied,
            nonBipedalAnatomy: .unsatisfied, pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied,
            ultrasoundStagedProtocol: .unsatisfied, contrastMediaUsed: .satisfied, nonSquarePixels: .unsatisfied)
        var cases: [Case] = [
            .init("us-monochrome", base),
            .init("us-rgb", base.setting(text(0x00280004, "RGB", .CS)).setting(number(0x00280002, 3))
                .setting(number(0x00280006, 0)).setting(bytes(0x7FE00010, Data(repeating: 1, count: 12), .OB))),
            .init("us-non-square-pixels", base.setting(text(0x00280034, "2\\1", .IS))),
            .init("us-invalid-icc", base.setting(bytes(0x00282000, Data(repeating: 0, count: 12), .OB)), .failed, tag: 0x00282000),
            .init("us-sync-missing-uid", base.setting(text(0x00181800, "N", .CS)), .failed, tag: 0x00200200),
            .init("us-reference-target-unavailable", referenced(base), .incomplete),
            .init("us-region", withRegion),
            .init("us-negative-delta-and-outside-reference", base.setting(sequence(0x00186011, [region()
                .setting(float(0x0018602E, -0.2)).setting(signed(0x00186020, -20))]))),
            .init("us-missing-image-type", base.removing(0x00080008), .failed, tag: 0x00080008),
            .init("us-bits-16", base.setting(number(0x00280100, 16)).setting(number(0x00280101, 16))
                .setting(number(0x00280102, 15)).setting(bytes(0x7FE00010, Data(repeating: 0, count: 8))), .failed, tag: 0x00280100),
            .init("us-signed-pixels", base.setting(number(0x00280103, 1)), .failed, tag: 0x00280103),
            .init("us-bits-stored", base.setting(number(0x00280101, 7)).setting(number(0x00280102, 6)), .failed, tag: 0x00280101),
            .init("us-short-pixels", base.setting(bytes(0x7FE00010, Data([0, 1]), .OB)), .failed, tag: 0x7FE00010),
            .init("us-empty-regions", base.setting(sequence(0x00186011, [])), .failed, tag: 0x00186011),
            .init("us-region-missing-delta", base.setting(sequence(0x00186011, [region().removing(0x0018602C)])), .failed, tag: 0x0018602C),
            .init("us-region-outside-image", base.setting(sequence(0x00186011, [region().setting(number(0x0018601C, 2, .UL))])), .failed, tag: 0x0018601C),
            .init("us-region-reversed", base.setting(sequence(0x00186011, [region().setting(number(0x00186018, 2, .UL))])), .failed),
            .init("us-region-reserved-flags", base.setting(sequence(0x00186011, [region().setting(number(0x00186016, 32, .UL))])), .failed, tag: 0x00186016),
            .init("us-region-invalid-unit", base.setting(sequence(0x00186011, [region().setting(number(0x00186024, 13))])), .failed, tag: 0x00186024),
            .init("us-region-invalid-data-type", base.setting(sequence(0x00186011, [region().setting(number(0x00186014, 9))])), .failed, tag: 0x00186014),
            .init("us-region-component-without-organization", base.setting(sequence(0x00186011, [region().setting(number(0x0018604C, 3))])), .failed, tag: 0x0018604C),
            .init("us-staged", base.setting(text(0x00082124, "2", .IS)).setting(text(0x0008212A, "3", .IS)), facts: stagedFacts),
            .init("us-staged-missing-counts", base, .failed, tag: 0x00082124, facts: stagedFacts),
            .init("us-contrast", base.setting(text(0x00180010, "TEST CONTRAST", .LO)), facts: contrastFacts),
            .init("us-contrast-missing-module", base, .failed, tag: 0x00180010, facts: contrastFacts),
            .init("us-contrast-missing-agent", base.setting(text(0x00181040, "IV", .LO)), .failed, tag: 0x00180010),
            .init("us-ivus-motor", ivus("MOTOR_PULLBACK")),
            .init("us-ivus-gated", ivus("GATED_PULLBACK")),
            .init("us-ivus-missing-acquisition-time", ivus("MOTOR_PULLBACK").removing(0x0008002A), .failed, tag: 0x0008002A),
            .init("us-ivus-missing-rate", ivus("MOTOR_PULLBACK").removing(0x00183101), .failed, tag: 0x00183101),
            .init("us-voi", base.setting(text(0x00281050, "127", .DS)).setting(text(0x00281051, "256", .DS))),
            .init("us-voi-missing-width", base.setting(text(0x00281050, "127", .DS)), .failed, tag: 0x00281051),
            .init("us-palette-8", palette(bits: 8)),
            .init("us-palette-16", palette(bits: 16)),
            .init("us-segmented-palette", palette(bits: 16, segmented: true)),
            .init("us-palette-missing-green", palette(bits: 8).removing(0x00281202), .failed, tag: 0x00281202),
            .init("us-palette-short-data", palette(bits: 8).setting(bytes(0x00281203, Data())), .failed, tag: 0x00281203),
            .init("us-overlay", overlay()),
            .init("us-overlay-missing-subtype", overlay().removing(0x60000045), .failed, tag: 0x60000045),
            .init("us-overlay-offset", overlay().setting(.init(tag: 0x60000050, vr: .SS, value: .signedIntegers([2, 1]))), .failed, tag: 0x60000050),
            .init("us-overlay-missing-target", base.setting(sequence(0x00186011, [region().setting(number(0x00186070, 0x6000))])), .failed, tag: 0x60000010),
            .init("us-unknown-acquisition-facts", base, .incomplete, facts: .init())
        ]
        for organization in 0...3 {
            let calibrated = componentRegion(organization)
            cases.append(.init("us-components-\(organization)", base.setting(sequence(0x00186011, [calibrated]))))
            let required = organization == 0 ? 0x00186046 : organization == 1 ? 0x00186048 : organization == 2 ? 0x0018605A : 0x00409098
            cases.append(.init("us-components-\(organization)-missing-required", base.setting(sequence(0x00186011, [calibrated.removing(required)])), .failed, tag: required))
        }
        cases.append(.init("us-components-table-count", base.setting(sequence(0x00186011, [componentRegion(2)
            .setting(number(0x00186056, 3, .UL))])), .failed, tag: 0x00186058))
        for test in cases {
            let bytes = try DicomDataSetWriter.part10Data(from: test.dataSet)
            let report = try DicomInstanceValidator.validate(bytes, imageConditions: test.facts ?? facts)
            XCTAssertEqual(report.outcome(requiring: layers), test.outcome, "\(test.name): \(report.diagnostics)")
            if let tag = test.tag {
                XCTAssertTrue(report.diagnostics.contains { $0.severity == .error && $0.path.last == .tag(tag) }, "\(test.name): \(report.diagnostics)")
            }
            XCTAssertFalse(report.diagnostics.contains { $0.code == .moduleRuleUnavailable && $0.path == [.tag(0x00080016)] }, test.name)
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes, imageConditions: test.facts ?? facts), report)
            if let folder = ProcessInfo.processInfo.environment["DICOM_US_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(test.name + ".dcm"))
                let external = test.name == "us-unknown-acquisition-facts" ? [] : [
                    "animal=no", "non-bipedal=no", "paired-body-part=no", "temporally-related-series=no", "non-square-pixels=no",
                    "us-staged-protocol=\(test.name.hasPrefix("us-staged") ? "yes" : "no")",
                    "contrast-media-used=\(test.name == "us-contrast" || test.name == "us-contrast-missing-module" ? "yes" : "no")"
                ]
                try JSONSerialization.data(withJSONObject: ["outcome": test.outcome.rawValue, "sopClass": sop,
                    "exit": test.outcome == .passed ? 0 : test.outcome == .failed ? 1 : 2, "facts": external], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(test.name + ".json"))
            }
        }
    }

    func test_ultrasoundRegions_reusesParserAndKeepsLimitsIncomplete() throws {
        let dataSet = fixture().setting(sequence(0x00186011, [region()]))
        let decoder = try DCMDecoder(data: DicomDataSetWriter.part10Data(from: dataSet))
        XCTAssertEqual(decoder.ultrasoundRegions().count, 1)
        XCTAssertEqual(decoder.ultrasoundRegions().first?.physicalUnitX, .centimeters)
        let limited = DicomUltrasoundModules.validate(dataSet, transferSyntax: .explicitVRLittleEndian,
            pixelData: .integer, conditions: facts, limits: .init(maximumRuleEvaluations: 1))
        XCTAssertEqual(limited.outcome(requiring: [.attributes]), .incomplete)
        XCTAssertTrue(limited.diagnostics.contains { $0.code == .evaluationLimitReached })
        let multi = fixture().setting(text(0x00080016, "1.2.840.10008.5.1.4.1.1.3.1", .UI))
        let unqualified = try DicomInstanceValidator.validate(DicomDataSetWriter.part10Data(from: multi), imageConditions: facts)
        XCTAssertTrue(unqualified.diagnostics.contains { $0.code == .moduleRuleUnavailable })
    }

    func test_referenceTargets_resolveIdentityAndKeepContradictionsVisible() throws {
        let source = try DicomDataSetWriter.part10Data(from: referenced(fixture()))
        let target = fixture().setting(text(0x00080018, "2.25.23690004", .UI))
        let resolved = try DicomInstanceValidator.validate(source, targets: ["2.25.23690004": target], imageConditions: facts)
        XCTAssertEqual(resolved.outcome(requiring: layers), .passed, "\(resolved.diagnostics)")
        let contradiction = try DicomInstanceValidator.validate(source, targets: ["2.25.23690004": fixture()], imageConditions: facts)
        XCTAssertEqual(contradiction[.references], .failed)
        XCTAssertTrue(contradiction.diagnostics.contains { $0.code == .referenceIdentityContradiction })
    }

    func test_nativeSyntaxes_preserveRegionMetadataAndOriginalPixelEvidence() throws {
        let dataSet = fixture().setting(sequence(0x00186011, [region()]))
        for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .implicitVRLittleEndian,
                       .explicitVRBigEndian, .deflatedExplicitVRLittleEndian] {
            let bytes = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: syntax))
            let report = try DicomInstanceValidator.validate(bytes, imageConditions: facts)
            XCTAssertEqual(report.outcome(requiring: layers), .passed, "\(syntax): \(report.diagnostics)")
            XCTAssertEqual(try DCMDecoder(data: bytes).ultrasoundRegions().first?.physicalDeltaX, 0.1)
        }
    }

    private func referenced(_ base: DicomDataSet) -> DicomDataSet {
        let reference = DicomDataSet(elements: [text(0x00081150, sop, .UI), text(0x00081155, "2.25.23690004", .UI)])
        return base.setting(sequence(0x00082112, [reference]))
            .setting(sequence(0x00081115, [.init(elements: [text(0x0020000E, "2.25.23690003", .UI),
                sequence(0x0008114A, [reference])])]))
    }

    private func fixture() -> DicomDataSet {
        .init(elements: [
            text(0x00080016, sop, .UI), text(0x00080018, "2.25.23690001", .UI), text(0x00080060, "US", .CS),
            text(0x00080008, "ORIGINAL\\PRIMARY", .CS), text(0x00282110, "00", .CS),
            text(0x00100010, "", .PN), text(0x00100020, "", .LO), text(0x00100030, "", .DA), text(0x00100040, "", .CS),
            text(0x00080020, "", .DA), text(0x00080030, "", .TM), text(0x00080090, "", .PN), text(0x00080050, "", .SH),
            text(0x00200010, "", .SH), text(0x00200011, "", .IS), text(0x00200013, "", .IS), text(0x00080070, "", .LO),
            text(0x0020000D, "2.25.23690002", .UI), text(0x0020000E, "2.25.23690003", .UI),
            number(0x00280002, 1), text(0x00280004, "MONOCHROME2", .CS), number(0x00280010, 2), number(0x00280011, 2),
            number(0x00280100, 8), number(0x00280101, 8), number(0x00280102, 7), number(0x00280103, 0),
            bytes(0x7FE00010, Data([0, 1, 1, 0]), .OB)
        ])
    }

    private func region() -> DicomDataSet {
        .init(elements: [number(0x00186018, 0, .UL), number(0x0018601A, 0, .UL), number(0x0018601C, 1, .UL),
            number(0x0018601E, 1, .UL), number(0x00186024, 3), number(0x00186026, 3), float(0x0018602C, 0.1),
            float(0x0018602E, 0.1), number(0x00186012, 1), number(0x00186014, 1), number(0x00186016, 2, .UL)])
    }

    private func componentRegion(_ organization: Int) -> DicomDataSet {
        var value = region().setting(number(0x00186044, UInt(organization)))
            .setting(number(0x0018604C, organization == 3 ? 0 : 7)).setting(number(0x0018604E, 1))
        if organization < 2 {
            value = value.setting(number(0x00186050, 2, .UL))
                .setting(.init(tag: 0x00186052, vr: .UL, value: .unsignedIntegers([0, 1])))
                .setting(.init(tag: 0x00186054, vr: .FD, value: .floats([0, 0.1])))
            if organization == 0 { value.set(number(0x00186046, 255, .UL)) }
            else { value.set(number(0x00186048, 0, .UL)); value.set(number(0x0018604A, 255, .UL)) }
        } else {
            value = value.setting(number(0x00186056, 2, .UL))
                .setting(.init(tag: 0x00186058, vr: .UL, value: .unsignedIntegers([0, 1])))
            if organization == 2 { value.set(.init(tag: 0x0018605A, vr: .FL, value: .floats([0, 0.1]))) }
            else { value.set(sequence(0x00409098, [code("T-28000", "SRT", "Lung"), code("T-04000", "SRT", "Breast")])) }
        }
        return value
    }

    private func ivus(_ acquisition: String) -> DicomDataSet {
        fixture().setting(text(0x00080060, "IVUS", .CS)).setting(text(0x0008002A, "20260912120000", .DT))
            .setting(text(0x00183100, acquisition, .CS)).setting(text(acquisition == "MOTOR_PULLBACK" ? 0x00183101 : 0x00183102, "0.5", .DS))
            .setting(text(0x00183103, "1", .IS)).setting(text(0x00183104, "1", .IS))
    }

    private func palette(bits: Int, segmented: Bool = false) -> DicomDataSet {
        var value = fixture().setting(text(0x00280004, "PALETTE COLOR", .CS))
            .setting(number(0x00280100, UInt(bits))).setting(number(0x00280101, UInt(bits)))
            .setting(number(0x00280102, UInt(bits - 1)))
            .setting(bytes(0x7FE00010, bits == 8 ? Data([0, 1, 1, 0]) : Data([0, 0, 1, 0, 1, 0, 0, 0]), bits == 8 ? .OB : .OW))
        for channel in 1...3 {
            value.set(.init(tag: 0x00281100 + channel, vr: .US, value: .unsignedIntegers([2, 0, UInt(bits)])))
            value.set(bytes((segmented ? 0x00281220 : 0x00281200) + channel,
                segmented ? Data([0, 0, 2, 0, 0, 0, 255, 255]) : bits == 8 ? Data([0, 255]) : Data([0, 0, 255, 255])))
        }
        return value
    }

    private func overlay() -> DicomDataSet {
        fixture().setting(sequence(0x00186011, [region().setting(number(0x00186070, 0x6000))]))
            .setting(number(0x60000010, 2)).setting(number(0x60000011, 2)).setting(text(0x60000040, "R", .CS))
            .setting(text(0x60000045, "ACTIVE 2D/BMODE IMAGE AREA", .LO))
            .setting(.init(tag: 0x60000050, vr: .SS, value: .signedIntegers([1, 1])))
            .setting(number(0x60000100, 1)).setting(number(0x60000102, 0)).setting(bytes(0x60003000, Data([15, 0])))
    }

    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings(value.components(separatedBy: "\\"))) }
    private func number(_ tag: Int, _ value: UInt, _ vr: DicomVR = .US) -> DicomDataElement { .init(tag: tag, vr: vr, value: .unsignedIntegers([value])) }
    private func signed(_ tag: Int, _ value: Int) -> DicomDataElement { .init(tag: tag, vr: .SL, value: .signedIntegers([value])) }
    private func float(_ tag: Int, _ value: Double) -> DicomDataElement { .init(tag: tag, vr: .FD, value: .floats([value])) }
    private func bytes(_ tag: Int, _ value: Data, _ vr: DicomVR = .OW) -> DicomDataElement { .init(tag: tag, vr: vr, value: .bytes(value)) }
    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement { .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) })) }
    private func code(_ value: String, _ scheme: String, _ meaning: String) -> DicomDataSet {
        .init(elements: [text(0x00080100, value, .SH), text(0x00080102, scheme, .SH), text(0x00080104, meaning, .LO)])
    }
}
