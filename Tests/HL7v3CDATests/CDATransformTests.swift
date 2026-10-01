import Foundation
import HL7v2
import XCTest
@testable import HL7v3CDA

/// v2 → CDA and CDA → v2 transformations for the assigned profiles, with structured loss reports.
final class CDATransformV2ToCDATests: CDATestCase {
    static func v2(_ name: String) throws -> HL7Message {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "hl7", subdirectory: "Fixtures/v2"))
        return try HL7Parser().parse(Data(contentsOf: url))
    }
    private func node(_ document: ClinicalDocument, _ localName: String) -> [HL7v3CDA.XMLNode] {
        document.node.descendants().filter { $0.name.localName == localName }
    }

    func test_adt_toCDA_mapsHeaderPatientAndEncounterAndValidates() throws {
        let result = try CDATransformer.v2ToCDA(try Self.v2("ADT_A01_admission"))
        let document = result.document
        let patient = try XCTUnwrap(document.recordTargets.first?.patientRole?.patient)
        XCTAssertEqual(patient.administrativeGenderCode?.code, "M")
        XCTAssertEqual(patient.birthTime?.value, "19800115")
        XCTAssertEqual(document.recordTargets.first?.patientRole?.ids.first?.extension, "123456")
        XCTAssertTrue(node(document, "encompassingEncounter").count == 1)
        XCTAssertEqual(node(document, "section").count, 1)
        XCTAssertTrue(document.validateLinks().isEmpty)
        XCTAssertTrue(CDAValidator().validate(document).isValid, CDAValidator().validate(document).findings.map(\.code).joined(separator: ","))
        try CDAFixtures.validateXSD(try CDADocumentSerializer().serialize(document))
        let report = result.report
        XCTAssertGreaterThan(report.mappedCount, 5)
        XCTAssertTrue(report.entries.contains { $0.kind == .mapped && ($0.source ?? "").hasPrefix("PID") })
        XCTAssertTrue(report.entries.contains { $0.kind == .lost && ($0.source ?? "").hasPrefix("NK1") }, "NK1 has no target in the profile")
        for entry in report.entries { XCTAssertFalse(((entry.source ?? "") + (entry.target ?? "") + (entry.reason ?? "")).isEmpty, "empty entry") }
        XCTAssertFalse(report.entries.contains { ($0.reason ?? "").contains("Doe") }, "reports carry paths, never values")
    }

    func test_strictMode_refusesLossAndNonStrictReturnsReport() throws {
        let message = try Self.v2("ADT_A01_admission")
        XCTAssertThrowsError(try CDATransformer.v2ToCDA(message, options: .init(strict: true))) { error in
            guard case CDATransformError.lossNotAllowed(let report) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertTrue(report.hasLoss)
            XCTAssertGreaterThan(report.lostCount, 0)
        }
        XCTAssertNoThrow(try CDATransformer.v2ToCDA(message))
    }

    func test_absentSourceFields_produceNullFlavorAndAbsentEntries_nothingFabricated() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ADT_A01_admission", withExtension: "hl7", subdirectory: "Fixtures/v2"))
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self).replacingOccurrences(of: "||19800115|M||", with: "||||")
        let result = try CDATransformer.v2ToCDA(try HL7Parser().parse(Data(text.utf8)))
        let patient = try XCTUnwrap(result.document.recordTargets.first?.patientRole?.patient)
        XCTAssertNil(patient.birthTime?.value)
        XCTAssertNotNil(patient.birthTime?.nullFlavor ?? patient.node.first("birthTime")?[attribute: "nullFlavor"])
        XCTAssertNil(patient.administrativeGenderCode?.code)
        XCTAssertTrue(result.report.entries.contains { $0.kind == .absent && ($0.target ?? "").contains("birthTime") })
        XCTAssertTrue(result.report.entries.contains { $0.kind == .absent && ($0.target ?? "").contains("administrativeGenderCode") })
        try CDAFixtures.validateXSD(try CDADocumentSerializer().serialize(result.document))
    }

    func test_oru_toCDA_resultsSectionTypedValuesInterpretationAndNarrative() throws {
        let result = try CDATransformer.v2ToCDA(try Self.v2("ORU_R01_lab_results"))
        let document = result.document
        let organizers = node(document, "organizer")
        XCTAssertEqual(organizers.count, 3)
        let observations = node(document, "observation")
        XCTAssertEqual(observations.count, 3)
        let potassium = try XCTUnwrap(observations.first { $0.first("code")?[attribute: "code"] == "2823-3" })
        XCTAssertEqual(potassium.first("value")?[attribute: "value"], "5.8")
        XCTAssertEqual(potassium.first("value")?[attribute: "unit"], "mmol/L")
        XCTAssertEqual(potassium.first("interpretationCode")?[attribute: "code"], "H")
        XCTAssertNotNil(potassium.first("referenceRange"))
        XCTAssertTrue(document.node.descendants().contains { $0.name.localName == "text" && $0.textContent.contains("Slightly elevated potassium") })
        XCTAssertTrue(document.validateLinks().isEmpty)
        XCTAssertTrue(CDAValidator().validate(document).isValid, CDAValidator().validate(document).findings.map(\.code).joined(separator: ","))
        try CDAFixtures.validateXSD(try CDADocumentSerializer().serialize(document))
        XCTAssertTrue(result.report.entries.contains { $0.kind == .changed && ($0.transformation ?? "").contains("0078") || $0.kind == .mapped && ($0.source ?? "").contains("OBX-8") })
    }

    func test_orm_toCDA_planOfTreatmentWithRequestMood() throws {
        let result = try CDATransformer.v2ToCDA(try Self.v2("ORM_O01_lab_order"))
        let document = result.document
        let planned = node(document, "entry").flatMap { $0.children }
        XCTAssertEqual(planned.count, 3)
        XCTAssertTrue(planned.allSatisfy { $0[attribute: "moodCode"] == "RQO" })
        XCTAssertTrue(CDAValidator().validate(document).isValid, CDAValidator().validate(document).findings.map(\.code).joined(separator: ","))
        try CDAFixtures.validateXSD(try CDADocumentSerializer().serialize(document))
    }

    func test_structuredNumericWithoutComparison_orWithEquality_emitsQuantity() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ORU_R01_lab_results", withExtension: "hl7", subdirectory: "Fixtures/v2"))
        let source = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        for value in ["^7.5", "=^7.5"] {
            let input = source.replacingOccurrences(of: "|NM|2951-2^Sodium^LN||142|", with: "|SN|2951-2^Sodium^LN||\(value)|")
            let result = try CDATransformer.v2ToCDA(try HL7Parser().parse(Data(input.utf8)))
            let observation = try XCTUnwrap(node(result.document, "observation").first)
            let quantity = try XCTUnwrap(observation.first("value"), value)
            XCTAssertEqual(quantity.schemaTypeName?.localName, "PQ", value)
            XCTAssertEqual(quantity[attribute: "value"], "7.5", value)
            XCTAssertEqual(quantity[attribute: "unit"], "mmol/L", value)
            XCTAssertFalse(result.report.entries.contains { $0.kind == .absent && $0.target == "Results/observation/value" })
        }
    }

    func test_unsupportedMessageType_throwsWithoutFabricating() throws {
        var message = try Self.v2("ADT_A01_admission")
        message["MSH"]?[9] = HL7Field(.text("QRY^A19^QRY_A19"))
        XCTAssertThrowsError(try CDATransformer.v2ToCDA(message)) { error in
            guard case CDATransformError.unsupportedMessageType = error else { return XCTFail("wrong error \(error)") }
        }
    }
}

final class CDATransformCDAToV2Tests: CDATestCase {
    private func schema() throws -> HL7SchemaVersion { try XCTUnwrap(HL7SchemaRegistry.shared.schema(for: .v2_5_1)) }

    func test_unknownAdministrativeGender_roundTripsWithoutReportedLoss() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ADT_A01_admission", withExtension: "hl7", subdirectory: "Fixtures/v2"))
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            .replacingOccurrences(of: "||19800115|M||", with: "||19800115|U||")
        let forward = try CDATransformer.v2ToCDA(try HL7Parser().parse(Data(text.utf8)))
        XCTAssertEqual(forward.document.recordTargets.first?.patientRole?.patient?.administrativeGenderCode?.code, "UN")
        let reverse = try CDATransformer.cdaToV2(forward.document, profile: .adt)
        XCTAssertEqual(reverse.message["PID"]?[8][1][1][1].text, "U")
        XCTAssertFalse(reverse.report.entries.contains { $0.kind == .lost && $0.source == "administrativeGenderCode" })
    }

    func test_resultsSection_toORU_roundTripsValuesAndValidates() throws {
        let forward = try CDATransformer.v2ToCDA(try CDATransformV2ToCDATests.v2("ORU_R01_lab_results"))
        let reverse = try CDATransformer.cdaToV2(forward.document, profile: .oru)
        let message = reverse.message
        XCTAssertEqual(message.messageType.code, "ORU")
        XCTAssertEqual(message.messageType.triggerEvent, "R01")
        let obx = message.segments.filter { $0.name == "OBX" }
        XCTAssertEqual(obx.count, 3)
        XCTAssertEqual(message.segments.filter { $0.name == "OBR" }.count, 3)
        let values = obx.map { $0[5][1][1][1].text ?? "" }
        XCTAssertEqual(Set(values), ["142", "5.8", "102"])
        XCTAssertEqual(obx.first?[6][1][1][1].text, "mmol/L")
        XCTAssertEqual(obx.first?[2][1][1][1].text, "NM")
        let report = HL7Validator(schema: try schema()).validate(message)
        XCTAssertTrue(report.isValid, report.findings.map { "\($0.code)" }.joined(separator: ","))
        XCTAssertGreaterThan(reverse.report.mappedCount, 0)
        XCTAssertFalse(reverse.report.entries.contains { ($0.reason ?? "").contains("Sodium") })
        let wire = try HL7Serializer().serialize(message)
        XCTAssertEqual(try HL7Parser().parse(wire).segments.count, message.segments.count)
    }

    func test_header_toADTA08_reportsAbsentPatientForHeaderOnlyDocuments() throws {
        var document = try CDAFixtures.document("ccd-minimal")
        document.recordTargets = []
        let reverse = try CDATransformer.cdaToV2(document, profile: .adt)
        XCTAssertEqual(reverse.message.messageType.code, "ADT")
        XCTAssertEqual(reverse.message.messageType.triggerEvent, "A08")
        XCTAssertNotNil(reverse.message["PID"])
        XCTAssertTrue(reverse.report.entries.contains { $0.kind == .absent && $0.target == "PID" && $0.reason == "sourceNotPresent" })
        XCTAssertFalse(reverse.report.hasLoss)
        XCTAssertNoThrow(try CDATransformer.cdaToV2(document, profile: .adt, options: .init(strict: true)))
    }

    func test_adtReverse_strictModeRejectsUnmappableGender() throws {
        var document = try CDAFixtures.document("ccd-minimal")
        document.recordTargets[0].patientRole?.patient?.administrativeGenderCode = try CE(code: "unsupported")
        let reverse = try CDATransformer.cdaToV2(document, profile: .adt)
        XCTAssertTrue(reverse.report.hasLoss)
        XCTAssertTrue(reverse.report.entries.contains { $0.kind == .lost && $0.source == "administrativeGenderCode" })
        XCTAssertThrowsError(try CDATransformer.cdaToV2(document, profile: .adt, options: .init(strict: true))) { error in
            guard case CDATransformError.lossNotAllowed = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func test_ormReverse_isExplicitlyUnsupported() throws {
        XCTAssertThrowsError(try CDATransformer.cdaToV2(try CDAFixtures.document("ccd-minimal"), profile: .orm)) { error in
            guard case CDATransformError.unsupportedProfile = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func test_codeSystemTranslator_reportsUnknownCodesInsteadOfGuessing() {
        XCTAssertEqual(CodeSystemTranslator.gender("F").value, "F")
        XCTAssertEqual(CodeSystemTranslator.gender("U").value, "UN")
        XCTAssertNil(CodeSystemTranslator.gender("Q").value)
        XCTAssertNotNil(CodeSystemTranslator.gender("Q").reason)
        XCTAssertEqual(CodeSystemTranslator.resultStatus("F").value, "completed")
        XCTAssertEqual(CodeSystemTranslator.abnormalFlag("H").value, "H")
        XCTAssertEqual(CodeSystemTranslator.valueType("NM").value, "PQ")
        XCTAssertTrue(CodeSystemTranslator.valueType("NM").changed)
        XCTAssertEqual(CodeSystemTranslator.valueType("NM").reason, "valueTypeTranslation")
        XCTAssertNil(CodeSystemTranslator.valueType("ED").value)
    }
}
