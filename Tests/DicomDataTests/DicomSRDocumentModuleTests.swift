import Foundation
import XCTest
@testable import DicomData

final class DicomSRDocumentModuleTests: XCTestCase {
    func test_srBaseline_requiresDocumentAttributesAndAllowsEmptyType2Procedure() {
        XCTAssertEqual(validate(baseline())[.attributes], .passed)
        for tag in [0x00200013, 0x00080023, 0x00080033, 0x0040A491, 0x0040A493, 0x0040A372] {
            let report = validate(baseline().removing(tag))
            XCTAssertTrue(report.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path == [.tag(tag)] })
        }
        XCTAssertEqual(validate(baseline().setting(text(0x00080023, "", .DA)))[.attributes], .failed)
        XCTAssertEqual(validate(baseline())[.references], .notEvaluated)
    }

    func test_unknownExternalConditions_areNotPresumedFalse() {
        let report = DicomSRDocumentModule.validate(baseline(), kind: .structuredReport)
        XCTAssertEqual(report[.attributes], .incomplete)
        let paths = report.diagnostics.filter { $0.code == .conditionUndetermined }.map(\.path)
        XCTAssertEqual(paths.count, 6)
        for tag in [0x0040A370, 0x0040A525, 0x0040A360, 0x0040A375, 0x0040A385, 0x0008114A] {
            XCTAssertTrue(paths.contains([.tag(tag)]))
        }
    }

    func test_verifiedReport_requiresCompleteAndEveryObserverField() {
        let verified = baseline().setting(text(0x0040A493, "VERIFIED", .CS))
        XCTAssertEqual(validate(verified)[.attributes], .failed)
        let complete = verified.setting(sequence(0x0040A073, [observer()]))
        XCTAssertEqual(validate(complete)[.attributes], .passed)
        XCTAssertTrue(validate(complete.setting(text(0x0040A491, "PARTIAL", .CS))).diagnostics.contains {
            $0.code == .attributeValueContradiction && $0.path == [.tag(0x0040A493)]
        })
        XCTAssertTrue(validate(complete.removing(0x0040A491)).diagnostics.contains {
            $0.code == .conditionUndetermined && $0.path == [.tag(0x0040A493)]
        })
        for tag in [0x0040A075, 0x0040A027, 0x0040A030, 0x0040A088] {
            let report = validate(verified.setting(sequence(0x0040A073, [observer(), observer().removing(tag)])))
            XCTAssertTrue(report.diagnostics.contains {
                $0.code == .requiredAttributeMissing && $0.path == [.tag(0x0040A073), .item(1), .tag(tag)]
            })
        }
        XCTAssertEqual(validate(baseline().setting(sequence(0x0040A073, [observer()])))[.attributes], .failed)
    }

    func test_verifierCodeSequence_checksCardinalityAndIncludedCodeMacro() {
        let verified = baseline().setting(text(0x0040A493, "VERIFIED", .CS))
        for items in [[DicomDataSet()], [code(), code()]] {
            let withCode = observer().setting(sequence(0x0040A088, items))
            XCTAssertEqual(validate(verified.setting(sequence(0x0040A073, [withCode])))[.attributes], .failed)
        }
        let coded = verified.setting(sequence(0x0040A073, [observer().setting(sequence(0x0040A088, [code()]))]))
        XCTAssertEqual(validate(coded)[.attributes], .incomplete) // Scheme-version evidence is unavailable.
        XCTAssertEqual(DicomSRDocumentModule.validate(coded, kind: .structuredReport, conditions: noExternalRequirements(),
            versionRequirements: ["99LOCAL": .unsatisfied])[.attributes], .passed)
    }

    func test_conditionalEvidence_checksEachHierarchyLevelAndPreservesItemPaths() {
        var context = noExternalRequirements()
        context.currentProcedureEvidenceRequired = .satisfied
        XCTAssertEqual(validate(baseline(), conditions: context)[.attributes], .failed)
        let valid = baseline().setting(sequence(0x0040A375, [evidence()]))
        XCTAssertEqual(validate(valid, conditions: context)[.attributes], .passed)
        let broken = evidence().setting(sequence(0x00081115, [
            .init(elements: [text(0x0020000E, "2.25.23212002", .UI), sequence(0x00081199, [sop(), sop().removing(0x00081155)])])
        ]))
        let report = validate(baseline().setting(sequence(0x0040A375, [evidence(), broken])), conditions: context)
        XCTAssertTrue(report.diagnostics.contains {
            $0.code == .requiredAttributeMissing && $0.path == [.tag(0x0040A375), .item(1), .tag(0x00081115),
                .item(0), .tag(0x00081199), .item(1), .tag(0x00081155)]
        })
        for invalid in [DicomDataSet(), evidence().setting(sequence(0x00081115, []))] {
            XCTAssertEqual(validate(baseline().setting(sequence(0x0040A375, [invalid])), conditions: context)[.attributes], .failed)
        }
    }

    func test_keyObject_requiresEvidenceWithoutSRFlagsAndHasDistinctRequestCondition() {
        let ko = baseline().removing(0x0040A491).removing(0x0040A493).removing(0x0040A372)
        let context = noExternalRequirements()
        XCTAssertEqual(DicomSRDocumentModule.validate(ko, kind: .keyObjectSelection, conditions: context)[.attributes], .failed)
        let valid = ko.setting(sequence(0x0040A375, [evidence()]))
        XCTAssertEqual(DicomSRDocumentModule.validate(valid, kind: .keyObjectSelection, conditions: context)[.attributes], .passed)
        let withRequest = valid.setting(sequence(0x0040A370, [request()]))
        XCTAssertTrue(DicomSRDocumentModule.validate(withRequest, kind: .keyObjectSelection, conditions: context).diagnostics.contains {
            $0.code == .conditionalAttributeForbidden && $0.path == [.tag(0x0040A370)]
        })
        XCTAssertEqual(validate(baseline().setting(sequence(0x0040A370, [request()])))[.attributes], .passed)
    }

    func test_requestMacro_requiresEmptyType2FieldsAndIssuerAlternatives() {
        let withRequest = baseline().setting(sequence(0x0040A370, [request()]))
        XCTAssertEqual(validate(withRequest)[.attributes], .passed)
        for tag in [0x0020000D, 0x00081110, 0x00080050, 0x00402016, 0x00402017, 0x00401001, 0x00321060, 0x00321064] {
            XCTAssertEqual(validate(baseline().setting(sequence(0x0040A370, [request().removing(tag)])))[.attributes], .failed)
        }
        let issuer = DicomDataSet(elements: [text(0x00400032, "2.25.23212004", .UT), text(0x00400033, "ISO", .CS)])
        for (item, expected) in [(issuer, DicomValidationReport.Outcome.passed), (DicomDataSet(), .failed),
                                  (issuer.removing(0x00400033), .failed), (issuer.setting(text(0x00400033, "UNKNOWN", .CS)), .failed)] {
            let requested = request().setting(sequence(0x00080051, [item]))
            XCTAssertEqual(validate(baseline().setting(sequence(0x0040A370, [requested])))[.attributes], expected)
        }
    }

    func test_authorObserver_distinguishesPersonAndDeviceRequirements() {
        let institution: [DicomDataElement] = [text(0x00080080, "", .LO), sequence(0x00080082, [])]
        let person = DicomDataSet(elements: institution + [text(0x0040A084, "PSN", .CS),
            text(0x0040A123, "SYNTHETIC^AUTHOR", .PN), sequence(0x00401101, [])])
        let device = DicomDataSet(elements: institution + [text(0x0040A084, "DEV", .CS), text(0x00081010, "", .SH),
            text(0x00181002, "2.25.23212005", .UI), text(0x00080070, "SYNTHETIC", .LO), text(0x00081090, "TEST", .LO)])
        for item in [person, device] {
            XCTAssertEqual(validate(baseline().setting(sequence(0x0040A078, [item])))[.attributes], .passed)
        }
        for item in [person.removing(0x00401101), device.removing(0x00081010), device.removing(0x00181002),
                     person.setting(text(0x00181002, "2.25.23212005", .UI))] {
            XCTAssertEqual(validate(baseline().setting(sequence(0x0040A078, [item])))[.attributes], .failed)
        }
    }

    func test_predecessorAndEquivalentReferences_requireFullNestedAttributes() {
        var context = noExternalRequirements()
        context.includesOtherDocumentContent = .satisfied
        context.equivalentCDAKnown = .satisfied
        let valid = baseline().setting(sequence(0x0040A360, [evidence()]))
            .setting(sequence(0x0008114A, [sop().setting(sequence(0x0040A170, [code()]))]))
        XCTAssertEqual(validate(valid, conditions: context)[.attributes], .incomplete)
        for missing in [valid.removing(0x0040A360), valid.removing(0x0008114A),
                        valid.setting(sequence(0x0008114A, [sop()]))] {
            XCTAssertEqual(validate(missing, conditions: context)[.attributes], .failed)
        }
    }

    func test_limitsAndDiagnostics_remainBoundedAndValueFree() throws {
        let dataSet = baseline().setting(text(0x0040A493, "PRIVATE SENTINEL", .CS))
            .setting(sequence(0x0040A375, Array(repeating: evidence(), count: 100)))
        let report = DicomSRDocumentModule.validate(dataSet, kind: .structuredReport,
            limits: .init(maximumRuleEvaluations: 12, maximumDiagnostics: 2))
        XCTAssertLessThanOrEqual(report.diagnostics.count, 3)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .evaluationLimitReached })
        let json = String(decoding: try JSONEncoder().encode(report.diagnostics), as: UTF8.self)
        XCTAssertFalse(json.contains("PRIVATE SENTINEL"))
        XCTAssertFalse(json.contains("2.25.232120"))
    }

    func test_participantAndCustodian_preserveType2AndExtensibleRoleRules() {
        let participant = DicomDataSet(elements: [text(0x0040A084, "PSN", .CS), text(0x0040A123, "SYNTHETIC", .PN),
            sequence(0x00401101, []), text(0x00080080, "", .LO), sequence(0x00080082, []),
            text(0x0040A080, "LOCAL_ROLE", .CS), text(0x0040A082, "", .DT)])
        XCTAssertEqual(validate(baseline().setting(sequence(0x0040A07A, [participant])))[.attributes], .passed)
        for tag in [0x0040A080, 0x0040A082] {
            XCTAssertEqual(validate(baseline().setting(sequence(0x0040A07A, [participant.removing(tag)])))[.attributes], .failed)
        }
        let custodian = DicomDataSet(elements: [text(0x00080080, "", .LO), sequence(0x00080082, [])])
        XCTAssertEqual(validate(baseline().setting(sequence(0x0040A07C, [custodian])))[.attributes], .passed)
        for items in [[], [custodian, custodian], [custodian.removing(0x00080082)]] {
            XCTAssertEqual(validate(baseline().setting(sequence(0x0040A07C, items)))[.attributes], .failed)
        }
    }

    func test_signatureReferences_requireTheirValuesWithoutClaimingCryptographicVerification() {
        let signature = DicomDataSet(elements: [text(0x04000100, "2.25.23212006", .UI),
            .init(tag: 0x04000120, vr: .OB, value: .bytes(Data([1, 2])))])
        let mac = DicomDataSet(elements: [text(0x04000010, "1.2.840.10008.1.2.1", .UI), text(0x04000015, "SHA256", .CS),
            .init(tag: 0x04000020, vr: .AT, value: .unsignedIntegers([0x00081155])),
            .init(tag: 0x04000404, vr: .OB, value: .bytes(Data([1, 2])))])
        for (tag, valid, required) in [(0x04000402, signature, [0x04000100, 0x04000120]),
                                        (0x04000403, mac, [0x04000010, 0x04000015, 0x04000020, 0x04000404])] {
            for missing in [nil] + required.map(Optional.some) {
                let item = missing.map { valid.removing($0) } ?? valid
                let reference = sop().setting(sequence(tag, [item]))
                let study = evidence().setting(sequence(0x00081115, [.init(elements: [text(0x0020000E, "2.25.23212002", .UI),
                    sequence(0x00081199, [reference])])]))
                let report = validate(baseline().setting(sequence(0x0040A375, [study])))
                XCTAssertEqual(report[.attributes], missing == nil ? .passed : .failed)
                XCTAssertEqual(report[.references], .notEvaluated)
            }
        }
    }

    private func validate(_ dataSet: DicomDataSet, conditions: DicomSRDocumentModule.Conditions? = nil) -> DicomValidationReport {
        DicomSRDocumentModule.validate(dataSet, kind: .structuredReport, conditions: conditions ?? noExternalRequirements())
    }

    private func noExternalRequirements() -> DicomSRDocumentModule.Conditions {
        var conditions = DicomSRDocumentModule.Conditions()
        conditions.includesOtherDocumentContent = .unsatisfied
        conditions.identicalDocumentsRequired = .unsatisfied
        conditions.requestedProcedureApplies = .unsatisfied
        conditions.currentProcedureEvidenceRequired = .unsatisfied
        conditions.pertinentOtherEvidenceRequired = .unsatisfied
        conditions.equivalentCDAKnown = .unsatisfied
        return conditions
    }

    private func baseline() -> DicomDataSet {
        .init(elements: [text(0x00200013, "1", .IS), text(0x00080023, "20260908", .DA), text(0x00080033, "120000", .TM),
            text(0x0040A491, "COMPLETE", .CS), text(0x0040A493, "UNVERIFIED", .CS), sequence(0x0040A372, [])])
    }

    private func observer() -> DicomDataSet {
        .init(elements: [text(0x0040A075, "SYNTHETIC^VERIFIER", .PN), text(0x0040A027, "TEST", .LO),
            text(0x0040A030, "20260908120000", .DT), sequence(0x0040A088, [])])
    }

    private func request() -> DicomDataSet {
        .init(elements: [text(0x0020000D, "2.25.23212001", .UI), sequence(0x00081110, []), text(0x00080050, "", .SH),
            text(0x00402016, "", .LO), text(0x00402017, "", .LO), text(0x00401001, "", .SH),
            text(0x00321060, "", .LO), sequence(0x00321064, [])])
    }

    private func code() -> DicomDataSet {
        .init(elements: [text(0x00080100, "TEST", .SH), text(0x00080102, "99LOCAL", .SH), text(0x00080104, "Synthetic", .LO)])
    }

    private func evidence() -> DicomDataSet {
        .init(elements: [text(0x0020000D, "2.25.23212001", .UI), sequence(0x00081115, [
            .init(elements: [text(0x0020000E, "2.25.23212002", .UI), sequence(0x00081199, [sop()])])
        ])])
    }

    private func sop() -> DicomDataSet {
        .init(elements: [text(0x00081150, "1.2.840.10008.5.1.4.1.1.2.1", .UI), text(0x00081155, "2.25.23212003", .UI)])
    }

    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings([value]))
    }

    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
