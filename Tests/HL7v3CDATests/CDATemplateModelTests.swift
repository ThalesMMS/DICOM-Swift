import Foundation
import XCTest
@testable import HL7v3CDA

final class CDATemplateModelTests: CDATestCase {
    func test_jsonRoundTrip_preservesProfileData() throws {
        let constraint = CDAConstraint(
            id: "gender",
            path: "recordTarget/patientRole/patient/administrativeGenderCode/@code",
            valueSet: CDAValueSet(binding: .required, codes: ["F", "M"], codeSystem: "2.16.840.1.113883.5.1"))
        let template = CDATemplate(root: "2.25.2362.1", extension: "synthetic", versionDate: "2026-09-12",
                                   name: "Synthetic profile", kind: .document, constraints: [constraint])
        let data = try JSONEncoder().encode(template)
        XCTAssertEqual(try JSONDecoder().decode(CDATemplate.self, from: data), template)
    }

    func test_inheritance_composesAndChildOverridesByConstraintID() throws {
        let parent = CDATemplate(root: "2.25.2362.10", name: "Parent", kind: .document,
                                 constraints: [.cardinality(id: "same", path: "code", min: 1, max: 1)])
        let child = CDATemplate(root: "2.25.2362.11", name: "Child", kind: .document,
                                inherits: [parent.id], constraints: [.cardinality(id: "same", path: "code", min: 0, max: nil)])
        let registry = try CDATemplateRegistry(validating: [parent, child])
        let constraints = try registry.composedConstraints(for: child.id)
        XCTAssertEqual(constraints.count, 1)
        XCTAssertEqual(constraints[0].cardinality?.minimum, 0)
    }

    func test_inheritanceCycle_isRejected() {
        let a = CDATemplate(root: "2.25.2362.20", name: "A", kind: .document, inherits: [.init(root: "2.25.2362.21")])
        let b = CDATemplate(root: "2.25.2362.21", name: "B", kind: .document, inherits: [a.id])
        XCTAssertThrowsError(try CDATemplateRegistry(validating: [a, b])) { error in
            guard case CDATemplateRegistryError.inheritanceCycle = error else { return XCTFail("wrong error") }
        }
    }

    func test_jsonCycleFixture_isRejected() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cyclic-inheritance", withExtension: "json",
                                                  subdirectory: "Fixtures/templates"))
        let templates = try JSONDecoder().decode([CDATemplate].self, from: Data(contentsOf: url))
        XCTAssertThrowsError(try CDATemplateRegistry(validating: templates)) { error in
            guard case CDATemplateRegistryError.inheritanceCycle = error else { return XCTFail("wrong error") }
        }
    }
}
