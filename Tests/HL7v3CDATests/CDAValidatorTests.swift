import Foundation
import XCTest
@testable import HL7v3CDA

final class CDAValidatorTests: CDATestCase {
    func test_baseDocument_multipleTargetsAndOptionalVersionIdentifiers_areValid() throws {
        for name in ["cda-r2-base-multiple-targets-valid", "cda-r2-base-unversioned-valid"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures/templates"))
            try CDAFixtures.validateXSD(Data(contentsOf: url))
            let report = CDAValidator().validate(try CDADocumentParser().parse(url))
            XCTAssertTrue(report.isValid, "\(name): \(report.findings)")
        }
    }

    func test_baseDocument_unpairedVersionIdentifiers_areRejected() throws {
        for removeSetID in [false, true] {
            var document = try CDAFixtures.document("ccd-minimal")
            if removeSetID { document.setId = nil } else { document.versionNumber = nil }
            let report = CDAValidator().validate(document)
            XCTAssertTrue(report.findings.contains { $0.constraintID == "cda.base.versionIdentifiers.paired" })
        }
    }

    func test_templateValidFixtures_parseValidateAndPassXSD() throws {
        let names = [
            "cda-r2-base-valid", "us-realm-header-valid", "ccd-valid", "discharge-summary-valid",
            "problems-valid", "medications-valid", "allergies-valid", "results-valid", "vital-signs-valid",
            "procedures-valid", "encounters-valid", "plan-valid", "problem-concern-act-valid",
            "problem-observation-valid", "medication-activity-valid", "allergy-concern-act-valid",
            "allergy-observation-valid", "result-organizer-valid", "result-observation-valid",
            "vital-signs-organizer-valid", "vital-signs-observation-valid", "procedure-activity-valid"
        ]
        for name in names {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures/templates"))
            let document = try CDADocumentParser().parse(url)
            XCTAssertTrue(CDAValidator().validate(document).isValid, name)
            try CDAFixtures.validateXSD(Data(contentsOf: url))
        }
    }

    func test_templateInvalidFixtures_haveStructuralFindings() throws {
        let names = [
            "cda-r2-base-missing-custodian", "us-realm-header-missing-custodian", "ccd-wrong-code",
            "discharge-summary-dangling-link", "problems-wrong-code", "medications-missing-text",
            "allergies-wrong-code", "results-missing-text", "vital-signs-wrong-code", "procedures-wrong-code",
            "encounters-wrong-code", "plan-wrong-code", "problem-concern-act-missing-id",
            "problem-observation-missing-code", "medication-activity-missing-status",
            "allergy-concern-act-missing-id", "allergy-observation-missing-code",
            "result-organizer-missing-status", "result-observation-missing-code",
            "vital-signs-organizer-missing-status", "vital-signs-observation-missing-code",
            "procedure-activity-missing-id"
        ]
        let expectedPathFragments: [String: String] = [
            "cda-r2-base-missing-custodian": "/custodian",
            "us-realm-header-missing-custodian": "/custodian",
            "ccd-wrong-code": "/code",
            "discharge-summary-dangling-link": "/text",
            "problems-wrong-code": "/code",
            "medications-missing-text": "/text",
            "allergies-wrong-code": "/code",
            "results-missing-text": "/text",
            "vital-signs-wrong-code": "/code",
            "procedures-wrong-code": "/code",
            "encounters-wrong-code": "/code",
            "plan-wrong-code": "/code",
            "problem-concern-act-missing-id": "/id",
            "problem-observation-missing-code": "/code",
            "medication-activity-missing-status": "/statusCode",
            "allergy-concern-act-missing-id": "/id",
            "allergy-observation-missing-code": "/code",
            "result-organizer-missing-status": "/statusCode",
            "result-observation-missing-code": "/code",
            "vital-signs-organizer-missing-status": "/statusCode",
            "vital-signs-observation-missing-code": "/code",
            "procedure-activity-missing-id": "/id"
        ]
        for name in names {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures/templates"))
            let document = try CDADocumentParser().parse(url)
            let report = CDAValidator().validate(document)
            XCTAssertFalse(report.isValid, name)
            XCTAssertTrue(report.findings.contains { $0.path.contains(expectedPathFragments[name] ?? "/") }, name)
        }
    }

    func test_specialInvalidFixtures_reportExpectedCodes() throws {
        let cases = [
            ("forbidden-null-flavor", "nullFlavorForbidden"),
            ("cardinality-violation", "cardinalityViolation"),
            ("unknown-template-id", "unknownTemplate")
        ]
        for (name, code) in cases {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures/templates"))
            let report = CDAValidator().validate(try CDADocumentParser().parse(url))
            XCTAssertTrue(report.findings.contains { $0.code == code && $0.path.hasPrefix("/") }, name)
            XCTAssertTrue(report.findings.allSatisfy { !$0.detail.contains("Fixture") }, name)
        }
    }

    func test_validCDAFixture_hasNoErrorsAndReportsCoverage() throws {
        let report = CDAValidator().validate(try CDAFixtures.document())
        XCTAssertTrue(report.isValid, report.findings.map(\.code).joined(separator: ","))
        XCTAssertGreaterThan(report.coverage.evaluated, 0)
        XCTAssertEqual(report.findings.filter { $0.detail.contains("Test") }.count, 0)
    }

    func test_unknownTemplateAndDanglingNarrative_areContentFree() throws {
        let source = try String(decoding: CDAFixtures.data("narrative-links"), as: UTF8.self)
            .replacingOccurrences(of: "<templateId root=\"2.16.840.1.113883.10.20.22.1.1\"/>",
                                  with: "<templateId root=\"2.25.2362.999\"/><templateId root=\"2.16.840.1.113883.10.20.22.1.1\"/>")
        let report = CDAValidator().validate(try CDADocumentParser().parse(Data(source.utf8)))
        XCTAssertTrue(report.findings.contains { $0.code == "unknownTemplate" })
        XCTAssertTrue(report.findings.contains { $0.code == "danglingNarrativeLink" })
        for finding in report.findings { XCTAssertFalse(finding.detail.contains("missing"), finding.detail) }
    }

    func test_explicitPathPredicatesAndIndex_areEvaluated() throws {
        let template = CDATemplate(root: "2.25.2362.30", name: "Predicate", kind: .document, constraints: [
            .cardinality(id: "first", path: "recordTarget[1]", min: 1, max: 1),
            .fixedValue(id: "code", path: "code/@code", value: "34133-9")
        ])
        var registry = CDATemplateRegistry.builtIn
        try registry.register(template)
        let report = CDAValidator(templates: registry).validate(try CDAFixtures.document(), against: [template.id])
        XCTAssertTrue(report.isValid, report.findings.map(\.code).joined(separator: ","))
        XCTAssertEqual(report.coverage.evaluated, 2)
    }

    func test_conditionalAndCustomRules_reportCoverageIDs() throws {
        let template = CDATemplate(root: "2.25.2362.31", name: "Conditional", kind: .document, constraints: [
            .conditional(id: "branch", when: "code[@code='34133-9']",
                         then: [.fixedValue(id: "branch.code", path: "code/@code", value: "34133-9")]),
            .custom(id: "custom", closure: { $0.name.localName == "ClinicalDocument" })
        ])
        var registry = CDATemplateRegistry.builtIn
        try registry.register(template)
        let report = CDAValidator(templates: registry).validate(try CDAFixtures.document(), against: [template.id])
        XCTAssertTrue(report.isValid, report.findings.map(\.code).joined(separator: ","))
        XCTAssertTrue(report.evaluatedConstraintIDs.contains("branch"))
        XCTAssertTrue(report.evaluatedConstraintIDs.contains("branch.code"))
        XCTAssertTrue(report.evaluatedConstraintIDs.contains("custom"))
    }
}
