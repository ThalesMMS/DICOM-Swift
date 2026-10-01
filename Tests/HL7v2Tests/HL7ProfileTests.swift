import XCTest
@testable import HL7v2

final class HL7ProfileTests: XCTestCase {
    func test_JSON_roundTripPreservesAllOverridesAndPlacement() throws {
        let p = HL7Profile(id: "local", baseVersion: .v2_5_1,
            overrides: [.init(segment: "PID", field: 8, optionality: .R, length: 3, valueSetID: "LOCAL")],
            zSegments: [.init(definition: .init(name: "ZAB", fields: [.init(index: 1, name: "Site", dataType: .ST)]),
                             structure: "ADT_A01", afterSegment: "PID", min: 0, max: nil)],
            valueSets: ["LOCAL": ["X"]], unknownSegmentPolicy: .warn, unknownFieldPolicy: .allow)
        XCTAssertEqual(try JSONDecoder().decode(HL7Profile.self, from: JSONEncoder().encode(p)), p)
        let minimal = Data(#"{"id":"minimal","baseVersion":"2.5.1"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(HL7Profile.self, from: minimal).unknownFieldPolicy, .error)
    }
    func test_overrides_changeRequiredLengthAndValueSetWithoutChangingBase() {
        let schema = HL7SchemaRegistry.shared.schema(for: .v2_5_1)!
        let profile = HL7Profile(id: "local", baseVersion: .v2_5_1,
            overrides: [.init(segment: "PID", field: 8, optionality: .R, length: 3, valueSetID: "LOCAL")],
            valueSets: ["LOCAL": ["XYZ"]])
        let validator = HL7Validator(schema: schema, profile: profile)
        var message = lotBAdmission()
        XCTAssertTrue(validator.validate(message).findings.contains { $0.path == HL7Path("PID-8") && $0.code == .requiredMissing })
        message["PID"]?[8] = HL7Field(.text("XYZ"))
        XCTAssertTrue(validator.validate(message).isValid)
        XCTAssertFalse(HL7Validator(schema: schema).validate(message).isValid)
        XCTAssertEqual(schema.segments["PID"]?[8]?.length, 1)
    }
    func test_registry_loadsHostJSON() async throws {
        let registry = HL7ProfileRegistry()
        let p = HL7Profile(id: "host", baseVersion: .v2_4)
        _ = try await registry.load(JSONEncoder().encode(p))
        let loaded = await registry.profile(id: "host")
        XCTAssertEqual(loaded, p)
    }
    func test_invalidProfileAndVersion_areReported() {
        let p = HL7Profile(id: "bad", baseVersion: .v2_4, overrides: [.init(segment: "PID", field: 999)],
            zSegments: [.init(definition: .init(name: "ZAB", fields: []), structure: "UNKNOWN", afterSegment: "PID")])
        let report = HL7Validator(schema: HL7SchemaRegistry.shared.schema(for: .v2_5_1)!, profile: p).validate(lotBAdmission())
        XCTAssertTrue(report.findings.contains { $0.code == .profileInvalid })
        XCTAssertTrue(report.findings.contains { $0.code == .versionMismatch })
    }
    func test_builder_appliesProfileOnBuild() {
        let profile = HL7Profile(id: "local", baseVersion: .v2_5_1,
            overrides: [.init(segment: "PID", field: 8, optionality: .R)])
        var b = HL7MessageBuilder(version: .v2_5_1, profile: profile)
        b.adt(event: .A01, pid: lotBPatient(), pv1: lotBVisit())
        XCTAssertThrowsError(try b.build())
        b.set(HL7Path("PID-8")!, .text("U"))
        XCTAssertNoThrow(try b.build())
    }
}
