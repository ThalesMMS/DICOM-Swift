import XCTest
@testable import HL7v2

final class HL7SchemaTests: XCTestCase {
    func test_v24FamilyName_acceptsAllFiveComponents() throws {
        let schema = try XCTUnwrap(HL7SchemaRegistry.shared.schema(for: .v2_4))
        let name = hl7Repetition(["Surname", "Own prefix", "Own surname", "Partner prefix", "Partner surname"])
        XCTAssertEqual(schema.dataTypes[.FN]?.components.count, 5)
        XCTAssertTrue(typeFindings(name, type: .FN, definitions: schema.dataTypes,
            path: .init("PID-5")!).isEmpty)
    }

    func test_legacyCE_rejectsSeventhComponent() throws {
        for version: HL7Version in [.v2_3_1, .v2_4] {
            let schema = try XCTUnwrap(HL7SchemaRegistry.shared.schema(for: version))
            let value = hl7Repetition(["ID", "Text", "LN", "ALT", "Alt text", "LOCAL", "EXCESS"])
            let findings = typeFindings(value, type: .CE, definitions: schema.dataTypes, path: .init("OBX-5")!)
            XCTAssertTrue(findings.contains { $0.code == .dataTypeInvalid && $0.path == HL7Path("OBX-5") })
            XCTAssertEqual(schema.dataTypes[.CE]?.components.count, 6)
        }
    }

    func test_v24AllergySetID_requiresSequenceNumber() throws {
        let schema = try XCTUnwrap(HL7SchemaRegistry.shared.schema(for: .v2_4))
        let type = try XCTUnwrap(schema.segments["AL1"]?[1]?.dataType)
        XCTAssertEqual(type, .SI)
        let findings = typeFindings(hl7Repetition(["not-a-number"]), type: type,
            definitions: schema.dataTypes, path: .init("AL1-1")!)
        XCTAssertTrue(findings.contains { $0.code == .dataTypeInvalid })
    }
    func test_registry_hasOnlyCoveredVersions() throws {
        XCTAssertEqual(HL7SchemaRegistry.shared.versions.map(\.rawValue), ["2.3.1", "2.4", "2.5", "2.5.1", "2.6"])
        for version in HL7SchemaRegistry.shared.versions {
            let schema = try XCTUnwrap(HL7SchemaRegistry.shared.schema(for: version))
            XCTAssertEqual(schema.version, version)
            XCTAssertTrue(schema.diagnostics.isEmpty)
            XCTAssertEqual(schema.segments["PID"]?[3]?.dataType, .CX)
            XCTAssertEqual(schema.segments["PID"]?[3]?.optionality, .R)
            XCTAssertEqual(schema.segments["PID"]?[3]?.repeatable, true)
            XCTAssertEqual(schema.segments["OBX"]?[5]?.dataTypeField, 2)
            XCTAssertEqual(schema.messageTypeToStructure["ADT^A04"], "ADT_A01")
            XCTAssertEqual(schema.messageTypeToStructure["ADT^A08"], "ADT_A01")
            XCTAssertEqual(schema.messageTypeToStructure.count, version == .v2_3_1 ? 8 : 10)
        }
    }
    func test_fallback_isExplicitAndNeverRoundsUp() throws {
        let schema = try XCTUnwrap(HL7SchemaRegistry.shared.schema(for: .v2_7))
        XCTAssertEqual(schema.version, .v2_6)
        XCTAssertEqual(schema.diagnostics.first?.code, .versionMismatch)
        XCTAssertEqual(schema.diagnostics.first?.path, HL7Path("MSH-12"))
        XCTAssertNil(HL7SchemaRegistry.shared.schema(for: .v2_3))
        XCTAssertNil(HL7SchemaRegistry.shared.schema(for: .unknown("not-a-version")))
        XCTAssertEqual(HL7SchemaRegistry.shared.schema(for: .unknown("2.5.2"))?.version, .v2_5_1)
    }
    func test_versionTables_haveActualFieldEvolution() throws {
        let old = try XCTUnwrap(HL7SchemaRegistry.shared.schema(for: .v2_3_1))
        let v24 = try XCTUnwrap(HL7SchemaRegistry.shared.schema(for: .v2_4))
        let v25 = try XCTUnwrap(HL7SchemaRegistry.shared.schema(for: .v2_5))
        let v251 = try XCTUnwrap(HL7SchemaRegistry.shared.schema(for: .v2_5_1))
        let v26 = try XCTUnwrap(HL7SchemaRegistry.shared.schema(for: .v2_6))
        XCTAssertEqual(old.segments["ERR"]?.fields.count, 1)
        XCTAssertEqual(old.segments["ERR"]?[1]?.dataType, .ELD)
        XCTAssertNil(old.segments["QPD"])
        XCTAssertNotNil(v24.segments["QPD"])
        XCTAssertNil(old.segments["PID"]?[31])
        XCTAssertEqual(v24.segments["PID"]?[35]?.introducedIn, "2.4")
        XCTAssertEqual(v25.segments["ERR"]?[2]?.dataType, .ERL)
        XCTAssertEqual(v25.segments["ERR"]?[3]?.dataType, .CWE)
        XCTAssertEqual(v25.segments["ERR"]?[4]?.optionality, .R)
        XCTAssertEqual(v25.segments["ERR"]?[1]?.deprecatedIn, "2.5")
        XCTAssertNil(v25.segments["OBX"]?[20])
        XCTAssertEqual(v251.segments["OBX"]?[20]?.introducedIn, "2.5.1")
        XCTAssertEqual(v251.segments["PID"]?[7]?.dataType, .TS)
        XCTAssertEqual(v26.segments["PID"]?[7]?.dataType, .DTM)
        XCTAssertEqual(v26.segments["NTE"]?.fields.count, 8)
    }
    func test_allFieldTypes_resolveInTheirVersion() {
        for version in HL7SchemaRegistry.shared.versions {
            let schema = HL7SchemaRegistry.shared.schema(for: version)!
            for segment in schema.segments.values {
                for field in segment.fields where field.dataType != .varies && field.dataType != .withdrawn {
                    XCTAssertNotNil(schema.dataTypes[field.dataType], "\(version.rawValue) \(segment.name)-\(field.index) \(field.dataType)")
                }
            }
        }
    }
    func test_boundedRepetitions_preservePublishedMaximum() {
        let schema = HL7SchemaRegistry.shared.schema(for: .v2_5_1)!
        XCTAssertEqual(schema.segments["PID"]?[38]?.maxRepetitions, 2)
        XCTAssertEqual(schema.segments["ERR"]?[6]?.maxRepetitions, 10)
        XCTAssertEqual(schema.segments["ERR"]?[6]?.repeatable, true)
        XCTAssertNil(HL7SchemaRegistry.shared.schema(for: .v2_3_1)?.dataTypes[.CWE])
    }
    func test_path_hashAndEquality_preserveRepetition() {
        XCTAssertEqual(Set([HL7Path("PID-3[2]")!, HL7Path("PID-3[2]")!]).count, 1)
        XCTAssertNotEqual(HL7Path("PID-3[2]"), HL7Path("PID-3"))
    }
}
