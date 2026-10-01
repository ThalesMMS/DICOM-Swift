import XCTest
@testable import HL7v2

final class HL7InspectorDiffTests: XCTestCase {
    func test_tree_hasPathsTypesLengthsAndNoValuesByDefault() throws {
        let message = try HL7Parser().parse(hl7Header() + "PID|||SECRET^^^AUTH||Family^Given\r")
        let description = HL7Inspector.describe(message)
        XCTAssertTrue(description.contains("PID[1]-3 type=CX"))
        XCTAssertTrue(description.contains("PID[1]-3[1].1.1 length=6 state=text"))
        XCTAssertFalse(description.contains("SECRET"))
        XCTAssertFalse(description.contains("Family"))
        XCTAssertTrue(HL7Inspector.describe(message, includeValues: true).contains("SECRET"))
        let json = try JSONEncoder().encode(HL7Inspector.tree(message))
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("SECRET"))
    }
    func test_unknownDynamicType_doesNotExposeFieldValue() throws {
        let message = try HL7Parser().parse(hl7Header() + "OBX|1|SECRET|CODE||VALUE\r")
        let description = HL7Inspector.describe(message)
        XCTAssertFalse(description.contains("SECRET"))
        XCTAssertFalse(description.contains("VALUE"))
    }
    func test_diff_detectsFieldRepetitionComponentAndSubcomponentChanges() throws {
        let a = try HL7Parser().parse(hl7Header() + "ZZZ|SECRET^B&C~D|REMOVE\r")
        let b = try HL7Parser().parse(hl7Header() + "ZZZ|OTHER^B&E~D~ADD\r")
        let changes = HL7Diff.compare(a, b)
        XCTAssertTrue(changes.contains { $0.path == "ZZZ[1]-1[1].1.1" && $0.change == .changed })
        XCTAssertTrue(changes.contains { $0.path == "ZZZ[1]-1[1].2.2" && $0.change == .changed })
        XCTAssertTrue(changes.contains { $0.path == "ZZZ[1]-1[3].1.1" && $0.change == .added })
        XCTAssertTrue(changes.contains { $0.path == "ZZZ[1]-2[1].1.1" && $0.change == .removed })
        XCTAssertFalse(String(describing: changes).contains("SECRET"))
        XCTAssertTrue(HL7Diff.compare(a, a).isEmpty)
    }
    func test_repeatedSegmentsAndNullEmpty_areDistinct() throws {
        let a = try HL7Parser().parse(hl7Header() + "OBX|\"\"\rOBX|A\r")
        let b = try HL7Parser().parse(hl7Header() + "OBX|\rOBX|B\r")
        XCTAssertEqual(HL7Diff.compare(a, b).map(\.path), ["OBX[1]-1[1].1.1", "OBX[2]-1[1].1.1"])
    }
}
