import XCTest
@testable import ClinicalMapping

final class ClinicalPatientIdentityTests: XCTestCase {
    func test_demographicMatches_requireIdentifyingEvidence() {
        for patient in [ClinicalPatientIdentity(sex: "F"), .init(familyName: "Synthetic"), .init(givenName: "Ana")] {
            XCTAssertEqual(patient.compare(with: patient), .unrelated)
        }
        for patient in [ClinicalPatientIdentity(birthDate: "1980-01-02"), .init(identifier: .init(value: "1")),
                        .init(familyName: "Synthetic", givenName: "Ana"), .init(givenName: "Ana", sex: "F")] {
            XCTAssertEqual(patient.compare(with: patient), .same)
        }
        XCTAssertEqual(ClinicalPatientIdentity(sex: "F").compare(with: .init(sex: "M")), .conflict(["sex"]))
        XCTAssertEqual(ClinicalPatientIdentity(givenName: "Ana", sex: "F").compare(with: .init(givenName: "Eva", sex: "F")),
                       .conflict(["givenName"]))
    }
}
