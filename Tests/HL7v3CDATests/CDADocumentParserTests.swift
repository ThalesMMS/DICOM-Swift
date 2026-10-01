import Foundation
import XCTest
@testable import HL7v3CDA

final class CDADocumentParserTests: CDATestCase {
    func test_everyFixture_parsesFromDataAndURL() throws {
        for name in CDAFixtures.all {
            XCTAssertEqual(try CDADocumentParser().parse(CDAFixtures.data(name)), try CDAFixtures.document(name))
        }
    }
    func test_headerParticipantsAndSections_exposeTypedValues() throws {
        let doc = try CDAFixtures.document()
        XCTAssertEqual(doc.typeId?.extension, "POCD_HD000040")
        XCTAssertEqual(doc.id?.root, "2.25.2362")
        XCTAssertEqual(doc.code?.code, "34133-9")
        XCTAssertEqual(doc.effectiveTime?.value, "20260912120000-0300")
        XCTAssertEqual(doc.versionNumber?.value, "1")
        let patient = try XCTUnwrap(doc.recordTargets.first?.patientRole?.patient)
        XCTAssertEqual(patient.names.first?.parts.map(\.text), ["Test", "Testsson"])
        XCTAssertEqual(patient.administrativeGenderCode?.nullFlavor, .UNK)
        XCTAssertEqual(patient.birthTime?.value, "20000101")
        XCTAssertEqual(doc.authors.first?.assignedAuthor?.assignedPerson?.names.first?.parts.last?.text, "Author")
        XCTAssertEqual(doc.custodian?.assignedCustodian?.representedCustodianOrganization?.names.first?.node.textContent, "Test Organization")
        XCTAssertEqual(try CDAFixtures.sections(doc).map { $0.title?.text }, ["Problems", "Medications", "Results"])
    }
    func test_entryVariantsAndRelationships_areAccessible() throws {
        let entries = try CDAFixtures.sections(CDAFixtures.document("entry-variants"))[0].entries
        XCTAssertEqual(entries.count, 7)
        guard case .observation(let observation) = entries[0].statement,
              case .substanceAdministration = entries[1].statement,
              case .organizer(let organizer) = entries[2].statement,
              case .supply = entries[3].statement,
              case .procedure = entries[4].statement,
              case .encounter = entries[5].statement,
              case .act = entries[6].statement else { return XCTFail("Missing statement variant") }
        XCTAssertEqual(observation.performers.count, 1)
        XCTAssertEqual(observation.authors.count, 1)
        XCTAssertEqual(observation.participants.count, 1)
        XCTAssertEqual(observation.entryRelationships.first?.typeCode, "REFR")
        XCTAssertEqual(observation.entryRelationships.first?.inversionInd, true)
        XCTAssertNotNil(observation.entryRelationships.first?.statement)
        XCTAssertEqual(observation.references.count, 1)
        XCTAssertEqual(observation.referenceRanges.count, 1)
        XCTAssertEqual(organizer.components.count, 1)
    }
    func test_nonXMLBody_preservesED() throws {
        guard case .nonXML(let body) = try CDAFixtures.document("discharge-summary").body else { return XCTFail("Missing body") }
        XCTAssertEqual(body.text?.mediaType, "text/plain")
        XCTAssertEqual(body.text?.text, "Synthetic discharge summary.")
    }
    func test_unknownContent_isPreservedAndReported() throws {
        let doc = try CDAFixtures.document("unknown-content")
        let section = try CDAFixtures.sections(doc)[0]
        XCTAssertEqual(section.unknownChildren.first?.name.namespaceURI, "urn:example:cda:test")
        XCTAssertTrue(doc.diagnostics.contains { $0.kind == .unknownNamespace })
        XCTAssertTrue(doc.diagnostics.contains { $0.kind == .unknownAttribute })
        XCTAssertEqual(try CDADocumentParser().parse(CDADocumentSerializer().serialize(doc)), doc)
        XCTAssertFalse(doc.diagnostics.contains { $0.path.contains("Preserve me") })
    }
    func test_sdtcExtensions_arePresentOnlyInExtensionFixture() throws {
        let doc = try CDAFixtures.document("sdtc-extensions")
        XCTAssertEqual(doc.node.descendants().filter { $0.name.namespaceURI == CDANamespace.sdtc }.map { $0.name.localName }, ["raceCode", "id", "id"])
        XCTAssertFalse(try CDAFixtures.document().node.descendants().contains { $0.name.namespaceURI == CDANamespace.sdtc })
    }
    func test_ANYValues_keepConcreteTypes() throws {
        let entries = try CDAFixtures.sections(CDAFixtures.document("datatypes"))[0].entries
        guard case .observation(let observation) = entries[0].statement else { return XCTFail("Missing observation") }
        XCTAssertEqual(observation.values.count, 20)
        for value in observation.values { if case .unknown = value { XCTFail("Known ANY type was not decoded") } }
    }
    func test_invalidRootAndNullConflict_areRejected() throws {
        XCTAssertThrowsError(try CDADocumentParser().parse(Data("<ClinicalDocument/>".utf8)))
        let data = try CDAFixtures.data("ccd-minimal")
        let invalid = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<birthTime value=", with: "<birthTime nullFlavor=\"UNK\" value=")
        XCTAssertThrowsError(try CDADocumentParser().parse(Data(invalid.utf8)))
    }
    func test_nestedSections_andGenericROI_preserveUnknownShapes() throws {
        var section = Section()
        section.title = ST("Outer")
        var nested = Section(); nested.title = ST("Inner")
        nested.entries = [Entry(.generic(Node("regionOfInterest", attributes: ["classCode": "ROIOVL", "moodCode": "EVN"], children: [Node("code", attributes: ["code": "POINT"]), Node("value", attributes: ["value": "1"])])))]
        section.sections = [nested]
        XCTAssertEqual(section.sections.first?.title?.text, "Inner")
        guard case .generic(let roi) = section.sections.first?.entries.first?.statement else { return XCTFail("Missing ROI") }
        XCTAssertEqual(roi.name.localName, "regionOfInterest")
    }
}

extension CDADocumentParserTests {
    func test_ancestorQNamePrefix_resolvesANYAndSurvivesDetachment() throws {
        let data = Data("<observation xmlns='urn:hl7-org:v3' xmlns:h='urn:hl7-org:v3' xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance'><value xsi:type='h:PQ' value='1' unit='mg'/></observation>".utf8)
        let node = try SafeXMLParser().parse(data)
        guard case .pq(let value) = Observation(node: node).values.first else { return XCTFail("QName not resolved") }
        XCTAssertEqual(value.unit, "mg")
        let detached = try SafeXMLParser().parse(XMLSerializer().serialize(value.node))
        XCTAssertEqual(detached.schemaTypeName?.namespaceURI, CDANamespace.hl7)
    }
    func test_foreignANYTypeWithKnownLocalName_remainsUnknown() throws {
        let data = Data("<ClinicalDocument xmlns='urn:hl7-org:v3' xmlns:v='urn:example:types' xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance'><value xsi:type='v:CD' code='synthetic'/></ClinicalDocument>".utf8)
        let doc = try CDADocumentParser().parse(data)
        guard case .unknown = doc.values.first else { return XCTFail("Foreign QName interpreted as HL7 datatype") }
        XCTAssertTrue(doc.diagnostics.contains { $0.kind == .unknownDataType })
        XCTAssertEqual(try CDADocumentParser().parse(CDADocumentSerializer().serialize(doc)), doc)
    }
}

extension CDADocumentParserTests {
    func test_optionalHeaderParticipants_haveTypedAccessors() throws {
        let doc = try CDAFixtures.document("header-participants")
        XCTAssertEqual(doc.dataEnterer?.time?.value, "20260912")
        XCTAssertEqual(doc.informants.first?.assignedEntity?.ids.first?.root, "2.25.2362")
        XCTAssertEqual(doc.informationRecipients.first?.intendedRecipient?.informationRecipient?.names.first?.parts.last?.text, "Recipient")
        XCTAssertEqual(doc.legalAuthenticator?.signatureCode?.code, "S")
        XCTAssertEqual(doc.authenticators.first?.time?.value, "20260912")
        XCTAssertEqual(doc.participants.first?.typeCode, "IND")
        XCTAssertEqual(doc.inFulfillmentOf.first?.order?.ids.first?.root, "2.25.2362")
        XCTAssertEqual(doc.documentationOf.first?.serviceEvent?.effectiveTime?.low?.value, "20260912")
        XCTAssertEqual(doc.relatedDocuments.first?.parentDocument?.versionNumber?.value, "1")
        XCTAssertEqual(doc.authorizations.first?.consent?.statusCode?.code, "completed")
        XCTAssertEqual(doc.componentOf?.encompassingEncounter?.ids.first?.root, "2.25.2362")
    }
}
