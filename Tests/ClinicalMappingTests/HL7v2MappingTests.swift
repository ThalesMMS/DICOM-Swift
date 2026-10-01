import Foundation
import HL7v2
import XCTest
@testable import ClinicalMapping

enum MappingFixtures {
    static func hl7(_ name: String) throws -> HL7Message {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "hl7", subdirectory: "Fixtures"))
        return try HL7Parser().parse(Data(contentsOf: url))
    }
    static var ana: ClinicalPatientIdentity {
        ClinicalPatientIdentity(familyName: "Synthetic", givenName: "Ana Maria", identifier: AssignedIdentifier(value: "MRN-1001", authority: "HOSP-A"), birthDate: "1980-01-02", sex: "F")
    }
}

final class HL7v2MappingTests: XCTestCase {
    func test_isoDateTimes_preserveTimezoneDuringHL7RoundTrip() throws {
        for (iso, hl7) in [("2026-09-13T08:00:00-03:00", "20260913080000-0300"),
                           ("2026-09-13T08:00:00+05:45", "20260913080000+0545"),
                           ("2026-09-13T08:00:00Z", "20260913080000+0000"),
                           ("2026-09-13", "20260913")] {
            XCTAssertEqual(HL7v2ClinicalMapper.hl7DateTime(iso), hl7)
            var order = try HL7v2ClinicalMapper.order(from: try MappingFixtures.hl7("order")).value
            order.scheduledStart = iso
            let message = try HL7v2ClinicalMapper.ormMessage(from: order, controlID: "TZ").value
            XCTAssertEqual(try HL7v2ClinicalMapper.order(from: message).value.scheduledStart,
                           iso.replacingOccurrences(of: "Z", with: "+00:00"))
        }
    }

    func test_identityWithOneSidedIdentifiers_stillReportsDemographicConflicts() {
        var identified = MappingFixtures.ana
        identified.otherIdentifiers = []
        var demographics = identified; demographics.identifier = nil; demographics.birthDate = "1981-01-02"
        XCTAssertEqual(identified.compare(with: demographics), .conflict(["birthDate"]))
        XCTAssertEqual(demographics.compare(with: identified), .conflict(["birthDate"]))
    }

    func test_orm_toOrder_keepsEveryIdentifierWithAuthority() throws {
        let mapped = try HL7v2ClinicalMapper.order(from: try MappingFixtures.hl7("order"))
        let order = mapped.value
        XCTAssertEqual(order.patient.identifier, AssignedIdentifier(value: "MRN-1001", authority: "HOSP-A"))
        XCTAssertEqual(order.patient.otherIdentifiers, [AssignedIdentifier(value: "NAT-77", authority: "NATIONAL")])
        XCTAssertEqual(order.patient.familyName, "Synthetic")
        XCTAssertEqual(order.patient.givenName, "Ana Maria")
        XCTAssertEqual(order.patient.birthDate, "1980-01-02")
        XCTAssertEqual(order.patient.sex, "F")
        XCTAssertEqual(order.placerOrderNumber, AssignedIdentifier(value: "PLC-500", authority: "RIS-A"))
        XCTAssertEqual(order.fillerOrderNumber, AssignedIdentifier(value: "FIL-900", authority: "PACS-A"))
        XCTAssertEqual(order.accessionNumber, AssignedIdentifier(value: "ACC-42", authority: "HOSP-A"))
        XCTAssertEqual(order.procedure, ClinicalCode(system: "LN", code: "71020", display: "CT Chest"))
        XCTAssertEqual(order.scheduledStart, "2026-09-13T08:00:00")
        XCTAssertEqual(order.referringPhysician?.familyName, "Referrer")
        XCTAssertEqual(order.status, .requested)
        XCTAssertEqual(order.priority, "R")
        XCTAssertEqual(order.idempotencyKey, "order:PLC-500@RIS-A")
        XCTAssertEqual(mapped.provenance.sourceIdentifier, "MSG-ORM-1")
        XCTAssertNotNil(mapped.provenance.sourceDigest)
        XCTAssertTrue(mapped.report.lost.contains { $0.source == "PV1" })
        XCTAssertFalse(mapped.report.entries.contains { ($0.reason ?? "").contains("Synthetic") }, "reports never carry values")
        XCTAssertThrowsError(try HL7v2ClinicalMapper.order(from: try MappingFixtures.hl7("order"), options: .init(strict: true))) {
            guard case MappingError.lossNotAllowed = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try HL7v2ClinicalMapper.order(from: try MappingFixtures.hl7("adt"))) {
            XCTAssertEqual($0 as? MappingError, .unsupportedMessage("ADT"))
        }
    }

    func test_oru_toResult_typedObservationsStudyUIDAndCorrection() throws {
        let result = try HL7v2ClinicalMapper.result(from: try MappingFixtures.hl7("result")).value
        XCTAssertEqual(result.identifier, AssignedIdentifier(value: "FIL-900", authority: "PACS-A"))
        XCTAssertEqual(result.accessionNumber, AssignedIdentifier(value: "ACC-42", authority: "HOSP-A"))
        XCTAssertEqual(result.studyInstanceUID, "2.25.23269902")
        XCTAssertEqual(result.status, .final)
        XCTAssertEqual(result.issued, "2026-09-13T11:30:00")
        XCTAssertEqual(result.author?.familyName, "Reader")
        XCTAssertEqual(result.observations.count, 3)
        XCTAssertEqual(result.observations[0].value, .numeric(value: "12.5", unit: "mm"))
        XCTAssertEqual(result.observations[0].interpretation, "H")
        XCTAssertEqual(result.observations[0].referenceRange, "<10")
        XCTAssertEqual(result.observations[1].value, .coded(ClinicalCode(system: "UMLS", code: "C0034067", display: "Pulmonary nodule")))
        XCTAssertEqual(result.observations[2].value, .text("Single 12.5 mm nodule in the right upper lobe."))
        XCTAssertEqual(result.reportText, ["Follow-up CT in 3 months."])
        XCTAssertEqual(result.idempotencyKey, "result:FIL-900@PACS-A:v1")
        let corrected = try HL7v2ClinicalMapper.result(from: try MappingFixtures.hl7("result-corrected")).value
        XCTAssertEqual(corrected.status, .corrected)
        XCTAssertEqual(corrected.observations.first?.value, .numeric(value: "13.0", unit: "mm"))
    }

    func test_adt_toIdentity_andReverseMessagesValidate() throws {
        let identity = try HL7v2ClinicalMapper.identity(from: try MappingFixtures.hl7("adt")).value
        XCTAssertEqual(identity, MappingFixtures.ana)
        let schema = try XCTUnwrap(HL7SchemaRegistry.shared.schema(for: .v2_5_1))
        let validator = HL7Validator(schema: schema)

        let orm = try HL7v2ClinicalMapper.ormMessage(from: try HL7v2ClinicalMapper.order(from: try MappingFixtures.hl7("order")).value, controlID: "OUT-1").value
        let ormReport = validator.validate(orm)
        XCTAssertTrue(ormReport.isValid, ormReport.findings.map { "\($0.code) \($0.path)" }.joined(separator: ","))
        let back = try HL7v2ClinicalMapper.order(from: orm).value
        XCTAssertEqual(back.placerOrderNumber, AssignedIdentifier(value: "PLC-500", authority: "RIS-A"))
        XCTAssertEqual(back.accessionNumber, AssignedIdentifier(value: "ACC-42", authority: "HOSP-A"))
        XCTAssertEqual(back.patient.identifier, MappingFixtures.ana.identifier)
        XCTAssertEqual(back.scheduledStart, "2026-09-13T08:00:00")

        let oru = try HL7v2ClinicalMapper.oruMessage(from: try HL7v2ClinicalMapper.result(from: try MappingFixtures.hl7("result")).value, controlID: "OUT-2").value
        let oruReport = validator.validate(oru)
        XCTAssertTrue(oruReport.isValid, oruReport.findings.map { "\($0.code) \($0.path)" }.joined(separator: ","))
        let resultBack = try HL7v2ClinicalMapper.result(from: oru).value
        XCTAssertEqual(resultBack.studyInstanceUID, "2.25.23269902")
        XCTAssertEqual(resultBack.observations.map(\.value), try HL7v2ClinicalMapper.result(from: try MappingFixtures.hl7("result")).value.observations.map(\.value))
        XCTAssertEqual(resultBack.reportText, ["Follow-up CT in 3 months."])
        XCTAssertEqual(oru["OBR"]?[25][1][1][1].text, "F")

        let adt = try HL7v2ClinicalMapper.adtMessage(from: identity, controlID: "OUT-3").value
        XCTAssertTrue(validator.validate(adt).isValid)
        XCTAssertEqual(try HL7v2ClinicalMapper.identity(from: adt).value, identity)
        XCTAssertEqual(adt["PID"]?[3][1][4][1].text, "HOSP-A", "assigning authority survives")
    }

    func test_identityComparison_authoritiesAndDemographics() {
        let ana = MappingFixtures.ana
        XCTAssertEqual(ana.compare(with: ana), .same)
        var otherAuthority = ana
        otherAuthority.identifier = AssignedIdentifier(value: "MRN-1001", authority: "HOSP-B")
        XCTAssertEqual(ana.compare(with: otherAuthority), .conflict(["identifier authority"]))
        var noAuthority = ana
        noAuthority.identifier = AssignedIdentifier(value: "MRN-1001")
        XCTAssertEqual(ana.compare(with: noAuthority), .conflict(["identifier authority"]), "absent authority never equals a known one")
        var differentBirth = ana
        differentBirth.birthDate = "1981-01-02"
        XCTAssertEqual(ana.compare(with: differentBirth), .conflict(["birthDate"]))
        var stranger = ana
        stranger.identifier = AssignedIdentifier(value: "MRN-2", authority: "HOSP-A")
        XCTAssertEqual(ana.compare(with: stranger), .unrelated)
        XCTAssertEqual(ClinicalPatientIdentity().compare(with: ana), .unrelated)
        XCTAssertTrue(AssignedIdentifier(value: " X ", authority: " ").sameEntity(as: AssignedIdentifier(value: "X")))
    }

    func test_identityComparison_requiresSharedEvidenceAndChecksGivenNames() {
        let familyOnly = ClinicalPatientIdentity(familyName: "Synthetic")
        XCTAssertEqual(familyOnly.compare(with: .init(birthDate: "1980-01-02")), .unrelated)
        XCTAssertEqual(ClinicalPatientIdentity(givenName: "Ana").compare(with: .init(givenName: "ana")), .unrelated)
        XCTAssertEqual(familyOnly.compare(with: .init(familyName: "synthetic")), .unrelated)
        XCTAssertEqual(ClinicalPatientIdentity(givenName: "Ana", sex: "F").compare(with: .init(givenName: "ana", sex: "F")), .same)
        XCTAssertEqual(ClinicalPatientIdentity(familyName: "").compare(with: .init(familyName: "")), .unrelated)
        var otherName = MappingFixtures.ana
        otherName.givenName = "Beatriz"
        XCTAssertEqual(MappingFixtures.ana.compare(with: otherName), .conflict(["givenName"]))
    }

    func test_identityComparison_considersAlternateIdentifiersAndTheirAuthorities() {
        let alternate = AssignedIdentifier(value: "NAT-77", authority: "NATIONAL")
        let identity = ClinicalPatientIdentity(otherIdentifiers: [alternate])
        XCTAssertFalse(identity.isEmpty)
        XCTAssertEqual(identity.compare(with: .init(otherIdentifiers: [alternate])), .same)
        XCTAssertEqual(identity.compare(with: .init(identifier: alternate)), .same)
        XCTAssertEqual(identity.compare(with: .init(otherIdentifiers: [.init(value: "NAT-77", authority: "OTHER")])), .conflict(["identifier authority"]))
        XCTAssertEqual(identity.compare(with: .init(otherIdentifiers: [.init(value: "NAT-88", authority: "NATIONAL")])), .unrelated)
    }

    func test_identityComparison_sharedAlternateMatchesDifferentPrimaryIdentifiers() {
        let alternate = AssignedIdentifier(value: "NAT-77", authority: "NATIONAL")
        let identity = ClinicalPatientIdentity(identifier: .init(value: "MRN-1", authority: "HOSP-A"),
                                               otherIdentifiers: [alternate])
        var other = ClinicalPatientIdentity(identifier: .init(value: "MRN-2", authority: "HOSP-B"),
                                            otherIdentifiers: [alternate])
        XCTAssertEqual(identity.compare(with: other), .same)
        XCTAssertEqual(other.compare(with: identity), .same)
        other.otherIdentifiers = []
        XCTAssertEqual(identity.compare(with: other), .unrelated)
        other.otherIdentifiers = [alternate]
        other.identifier = .init(value: "MRN-1", authority: "HOSP-B")
        XCTAssertEqual(identity.compare(with: other), .conflict(["identifier authority"]))
    }
}
