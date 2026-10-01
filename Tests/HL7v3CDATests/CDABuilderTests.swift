import Foundation
import XCTest
@testable import HL7v3CDA

final class CDABuilderTests: CDATestCase {
    func test_explicitNarrativeReference_isPreservedWithoutSyntheticText() throws {
        let entry = Entry(node: Node("entry", children: [Node("observation", attributes: ["classCode": "OBS", "moodCode": "EVN"],
            children: [Node("text", children: [Node("reference", attributes: ["value": "#provided"])])])]))
        let builder = CDADocumentBuilder(allowInvalid: true)
        builder.section(code: "30954-2", title: "Existing") { section in
            section.narrative("Caller narrative", id: "provided")
            section.narrative("Later narrative", id: "later")
            section.entry(entry)
        }
        builder.section(code: "30954-2", title: "Reference only") { $0.entry(entry) }
        guard case .structured(let body) = try builder.build().body else { return XCTFail("Missing structured body") }
        let sections = body.sections
        XCTAssertEqual(sections[0].entries, [entry])
        XCTAssertEqual(sections[1].entries, [entry])
        XCTAssertNil(sections[1].narrative)
    }

    func test_explicitParticipants_replaceSeedsThenAppend() throws {
        let fixture = try CDAFixtures.document("ccd-minimal")
        let target = try XCTUnwrap(fixture.recordTargets.first)
        let author = try XCTUnwrap(fixture.authors.first)
        let builder = CDADocumentBuilder(allowInvalid: true)
        builder.header(recordTarget: target, author: author)
        XCTAssertEqual(builder.document.recordTargets, [target])
        XCTAssertEqual(builder.document.authors, [author])
        builder.recordTarget(target).author(author)
        XCTAssertEqual(builder.document.recordTargets, [target, target])
        XCTAssertEqual(builder.document.authors, [author, author])

        let patientBuilder = CDADocumentBuilder(allowInvalid: true)
        patientBuilder.patient(Patient())
        let explicitPatient = try XCTUnwrap(patientBuilder.document.recordTargets.first)
        patientBuilder.recordTarget(target)
        XCTAssertEqual(patientBuilder.document.recordTargets, [explicitPatient, target])
    }

    func test_mutatingSectionClosure_reservesNarrativeIDsForLaterSections() throws {
        let builder = CDADocumentBuilder(allowInvalid: true)
        builder.section(code: "30954-2", title: "Existing", configure: { section in
            section.narrative = Node("text", children: [Node("paragraph", attributes: ["ID": "reserved"], text: "Existing")])
        })
        builder.section(code: "11450-4", title: "Later") { section in
            section.narrative("Later", id: "reserved")
        }
        let document = try builder.build()
        let ids = document.node.descendants().compactMap { $0[attribute: "ID"] }
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.contains("reserved"))
    }

    func test_entryBuilders_generateUniqueIDsAndNarrativeLinks() throws {
        let builder = CDADocumentBuilder()
        builder.section(template: CDATemplateLibrary.problemsSection, code: "11450-4", title: "Problems") { section in
            section.narrative("Synthetic problem")
            section.problemObservation(code: try! CD(code: "75323-6", codeSystem: "2.16.840.1.113883.6.1"),
                                      value: .cd(try! CD(code: "386661006", codeSystem: "2.16.840.1.113883.6.96")),
                                      narrative: "Synthetic problem")
        }
        let document = try builder.build()
        XCTAssertTrue(CDAValidator().validate(document).isValid)
        XCTAssertTrue(document.validateLinks().isEmpty)
        let ids = document.node.descendants().compactMap { $0[attribute: "ID"] }
        XCTAssertEqual(ids.count, Set(ids).count)
        try CDAFixtures.validateXSD(try CDADocumentSerializer().serialize(document))
    }

    func test_allEntryBuilders_emitSchemaValidNarrativeBearingEntries() throws {
        let builder = CDADocumentBuilder()
        builder.section(template: CDATemplateLibrary.medicationsSection, code: "10160-0", title: "Medications") { section in
            section.medicationActivity(narrative: "Synthetic medication")
        }
        builder.section(template: CDATemplateLibrary.allergiesSection, code: "48765-2", title: "Allergies") { section in
            section.allergyObservation(value: .cd(try! CD(code: "419199007", codeSystem: "2.16.840.1.113883.6.96")), narrative: "Synthetic allergy")
        }
        builder.section(template: CDATemplateLibrary.resultsSection, code: "30954-2", title: "Results") { section in
            section.resultOrganizer(narrative: "Synthetic result")
            section.resultObservation(value: .pq(try! PQ(value: "1", unit: "mg")), narrative: "Synthetic result observation")
        }
        builder.section(template: CDATemplateLibrary.vitalSignsSection, code: "8716-3", title: "Vital Signs") { section in
            section.vitalSignsOrganizer(narrative: "Synthetic vital")
            section.vitalSignsObservation(value: .pq(try! PQ(value: "120", unit: "mm[Hg]")), narrative: "Synthetic vital observation")
        }
        builder.section(template: CDATemplateLibrary.proceduresSection, code: "47519-4", title: "Procedures") { section in
            section.procedureActivity(narrative: "Synthetic procedure")
        }
        let document = try builder.build()
        XCTAssertTrue(document.validateLinks().isEmpty)
        XCTAssertTrue(CDAValidator().validate(document).isValid)
        try CDAFixtures.validateXSD(try CDADocumentSerializer().serialize(document))
    }
}
