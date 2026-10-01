import Foundation
import XCTest
@testable import HL7v3CDA

final class CDARoundTripTests: CDATestCase {
    func test_validCorpus_andSerializedOutput_passIndependentXSD() throws {
        for name in CDAFixtures.valid {
            let data = try CDAFixtures.data(name)
            try CDAFixtures.validateXSD(data)
            let first = try CDADocumentParser().parse(data)
            let output = try CDADocumentSerializer().serialize(first)
            try CDAFixtures.validateXSD(output)
            XCTAssertEqual(try CDADocumentParser().parse(output), first, name)
        }
    }
    func test_foreignExtensions_roundTripButAreRejectedByClosedXSD() throws {
        let doc = try CDAFixtures.document("unknown-content")
        let output = try CDADocumentSerializer().serialize(doc)
        XCTAssertEqual(try CDADocumentParser().parse(output), doc)
        try CDAFixtures.validateXSD(output, expectValid: false)
    }
    func test_typedMutations_updateSerializedDocumentInSchemaOrder() throws {
        var doc = try CDAFixtures.document()
        doc.versionNumber = try INT("2")
        doc.title = ST("Edited synthetic document")
        var targets = doc.recordTargets
        var role = try XCTUnwrap(targets[0].patientRole)
        var patient = try XCTUnwrap(role.patient)
        patient.names = [try PN(parts: [.init(part: "given", text: "Test"), .init(part: "family", text: "Edited")])]
        role.patient = patient; targets[0].patientRole = role; doc.recordTargets = targets
        let data = try CDADocumentSerializer().serialize(doc)
        try CDAFixtures.validateXSD(data)
        let parsed = try CDADocumentParser().parse(data)
        XCTAssertEqual(parsed.versionNumber?.value, "2")
        XCTAssertEqual(parsed.title?.text, "Edited synthetic document")
        XCTAssertEqual(parsed.recordTargets[0].patientRole?.patient?.names.first?.parts.last?.text, "Edited")
    }
    func test_constructedANYValues_emitXSITypeAndValidate() throws {
        var doc = try CDAFixtures.document()
        var observation = Observation(); observation.classCode = "OBS"; observation.moodCode = "EVN"
        observation.code = CD(nullFlavor: .NI)
        observation.values = [.pq(try PQ(value: "1.250", unit: "mg/dL")), .bl(BL(true)),
            .ivl_pq(try IVL_PQ(width: PQ(value: "1", unit: "mg"), center: PQ(value: "2", unit: "mg")))]
        var section = Section(); section.title = ST("Constructed values")
        section.entries = [Entry(.observation(observation))]
        var body = StructuredBody(); body.sections = [section]; doc.body = .structured(body)
        let data = try CDADocumentSerializer().serialize(doc)
        try CDAFixtures.validateXSD(data)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("xsi:type=\"PQ\""))
    }
}
