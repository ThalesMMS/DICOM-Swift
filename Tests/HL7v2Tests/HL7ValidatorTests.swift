import XCTest
@testable import HL7v2

final class HL7ValidatorTests: XCTestCase {
    func test_withdrawnComponent_reportsExclusionWithoutTypeOrLengthCascades() throws {
        let schema = try XCTUnwrap(HL7SchemaRegistry.shared.schema(for: .v2_6))
        let findings = typeFindings(hl7Repetition(["5551234", "PRN"]), type: .XTN,
            definitions: schema.dataTypes, path: .init("PID-13")!)
        XCTAssertEqual(findings.map(\.code), [.unknownField])
        XCTAssertEqual(findings.map(\.path), [HL7Path("PID-13.1")!])
        XCTAssertTrue(typeFindings(hl7Repetition(["", "PRN"]), type: .XTN,
            definitions: schema.dataTypes, path: .init("PID-13")!).isEmpty)
    }
    func test_missingRequiredSegmentAndField_haveExactPaths() {
        var message = lotBAdmission()
        message.segments.removeAll { $0.name == "EVN" }
        message["PID"]?[5] = HL7Field(.null)
        let report = lotBValidator().validate(message)
        XCTAssertTrue(report.findings.contains { $0.code == .requiredMissing && $0.path == HL7Path("EVN") })
        XCTAssertTrue(report.findings.contains { $0.code == .requiredMissing && $0.path == HL7Path("PID-5") })
    }
    func test_cardinalityAndOrder_areErrors() {
        var message = lotBAdmission()
        message.segments.append(lotBVisit())
        XCTAssertTrue(lotBValidator().validate(message).findings.contains { $0.code == .cardinality && $0.path == HL7Path("PV1") })
        message = lotBAdmission()
        message.segments.swapAt(1, 2)
        XCTAssertTrue(lotBValidator().validate(message).findings.contains { $0.code == .segmentOrder })
        message = lotBAdmission()
        message["PV1"]?[2] = HL7Field(repetitions: [hl7Repetition(["I"]), hl7Repetition(["I"])])
        XCTAssertTrue(lotBValidator().validate(message).findings.contains { $0.code == .cardinality && $0.path == HL7Path("PV1-2") })
    }
    func test_unexpectedSegmentUnknownFieldAndZ_areControlledByProfile() {
        var message = lotBAdmission()
        message.segments.append(HL7Segment(name: "ABC"))
        message["PID"]?[99] = HL7Field(.text("SYNTHETIC"))
        let base = lotBValidator().validate(message)
        XCTAssertTrue(base.findings.contains { $0.code == .unexpectedSegment && $0.path == HL7Path("ABC") })
        XCTAssertTrue(base.findings.contains { $0.code == .unknownField && $0.path == HL7Path("PID-99") })
        let profile = HL7Profile(id: "allow", baseVersion: .v2_5_1, unknownSegmentPolicy: .allow, unknownFieldPolicy: .allow)
        XCTAssertTrue(HL7Validator(schema: lotBValidator().schema, profile: profile).validate(message).isValid)
    }
    func test_zSegmentPlacement_enforcesPositionAndFields() {
        var message = lotBAdmission()
        var z = HL7Segment(name: "ZAB"); z[1] = HL7Field(.text("SITE"))
        message.segments.insert(z, at: 3)
        XCTAssertTrue(lotBValidator().validate(message).findings.contains { $0.code == .zSegmentUnexpected })
        let p = HL7Profile(id: "z", baseVersion: .v2_5_1,
            zSegments: [.init(definition: .init(name: "ZAB", fields: [.init(index: 1, name: "Site", dataType: .ST, optionality: .R)]),
                             structure: "ADT_A01", afterSegment: "PID")])
        let validator = HL7Validator(schema: lotBValidator().schema, profile: p)
        XCTAssertTrue(validator.validate(message).isValid)
        message.segments.swapAt(3, 4)
        XCTAssertFalse(validator.validate(message).isValid)
    }
    func test_valueSetAndLength_doNotExposeContent() {
        var message = lotBAdmission()
        let secret = "PRIVATE-SYNTHETIC-SENTINEL"
        message["PID"]?[8] = HL7Field(.text(secret))
        let report = lotBValidator().validate(message)
        XCTAssertTrue(report.findings.contains { $0.code == .valueNotInSet && $0.path == HL7Path("PID-8") })
        XCTAssertTrue(report.findings.contains { $0.code == .lengthExceeded && $0.path == HL7Path("PID-8") })
        XCTAssertFalse(report.findings.contains { $0.detail.contains(secret) })
        var options = HL7ValidationOptions(); options.includeValues = true
        XCTAssertTrue(HL7Validator(schema: lotBValidator().schema, options: options).validate(message).findings.contains { $0.detail.contains(secret) })
    }
    func test_conditionalValueAndDynamicType_areValidated() {
        var b = HL7MessageBuilder(version: .v2_5_1)
        b.oru(results: [.init(identifier: .init(identifier: "TEST"), dataType: .NM, value: hl7Repetition([""]))])
        XCTAssertTrue(lotBValidator().validate(b.message).findings.contains { $0.code == .conditionalUnmet && $0.path == HL7Path("OBX-5") })
        b.set(HL7Path("OBX-5")!, .text("abc"))
        XCTAssertTrue(lotBValidator().validate(b.message).findings.contains { $0.code == .dataTypeInvalid && $0.path == HL7Path("OBX-5") })
        b.set(HL7Path("OBX-2")!, .text("ST"))
        XCTAssertTrue(lotBValidator().validate(b.message).isValid)
    }
    func test_matcherBacktracksAcrossNestedGroupsAndReportsBudgetExhaustion() {
        var schema = lotBValidator().schema
        schema.structures["ACK"] = .init(id: "ACK", children: [
            .init(segment: "MSH", min: 1),
            .init(group: "OPTIONAL", children: [.init(segment: "NTE", min: 1)], min: 0, max: nil),
            .init(segment: "NTE", min: 1), .init(segment: "MSA", min: 1)])
        var b = HL7MessageBuilder(version: .v2_5_1)
        b.msh(messageType: "ACK")
        b.segment("NTE") { $0.set(1, .text("1")) }
        b.segment("NTE") { $0.set(1, .text("2")) }
        b.segment("MSA") { $0.set(1, .text("AA")); $0.set(2, .text("C")) }
        XCTAssertTrue(HL7Validator(schema: schema).validate(b.message).isValid)
        var options = HL7ValidationOptions(); options.maxBacktrack = 0
        XCTAssertTrue(HL7Validator(schema: schema, options: options).validate(b.message).findings.contains { $0.code == .matchingLimitExceeded })
    }
    func test_repeatedSegments_reportOccurrenceAndFieldRepetition() {
        var b = HL7MessageBuilder(version: .v2_5_1)
        b.oru(results: [.init(identifier: .init(identifier: "TEST"), dataType: .NM, value: hl7Repetition(["1"])),
                        .init(identifier: .init(identifier: "TEST"), dataType: .NM, value: hl7Repetition(["bad"]))])
        let report = lotBValidator().validate(b.message)
        XCTAssertTrue(report.findings.contains { $0.code == .dataTypeInvalid && $0.path == HL7Path("OBX-5") && $0.segmentOccurrence == 2 })
    }
    func test_unknownStructureAndVersionMismatch_areExplicit() {
        var message = lotBAdmission()
        message["MSH"]?[12] = HL7Field(.text("2.7"))
        message["MSH"]?[9] = HL7Field(.text("UNKNOWN"))
        let report = lotBValidator().validate(message)
        XCTAssertTrue(report.findings.contains { $0.code == .versionMismatch })
        XCTAssertTrue(report.findings.contains { $0.code == .structureUnknown })
    }
    func test_invalidCorpus_reportsActualFileDefects() throws {
        let expected: [(String, HL7ValidationFinding.Code, String)] = [
            ("invalid_coded_values", .valueNotInSet, "PID-8"),
            ("missing_required_pv1", .requiredMissing, "PV1"),
            ("invalid_datetime", .dataTypeInvalid, "MSH-7")]
        for (file, code, path) in expected {
            let message = try hl7LenientParser().parse(hl7Fixture("hl7kit/invalid/" + file + ".hl7"))
            XCTAssertTrue(lotBValidator().validate(message).findings.contains { $0.code == code && $0.path == HL7Path(path) }, file)
        }
        XCTAssertThrowsError(try hl7LenientParser().parse(hl7Fixture("hl7kit/invalid/bad_segment_id.hl7"))) { error in
            guard case HL7ParseError.malformed(let path, _) = error else { return XCTFail("wrong parser error") }
            XCTAssertEqual(path, HL7Path("MSH"))
        }
        // Upstream's filename/README do not match these bytes: EVN, PID-5 and PV1 are all present.
        let mislabeled = try hl7LenientParser().parse(hl7Fixture("hl7kit/invalid/missing_required_evn.hl7"))
        XCTAssertEqual(lotBValidator().validate(mislabeled).findings.filter { $0.severity == .error }.map(\.path), [HL7Path("MSH-9.3")!])
    }
    func test_validCorpus_hasNoUndocumentedFindings() throws {
        // Original MIT corpus is preserved. These exact paths document its column/structure defects.
        let expected: [String: Set<String>] = [
            "ACK_general.hl7": ["MSH-9.2", "MSH-9.3"],
            "ADT_A01_admission.hl7": ["MSH-9.3", "PV1-6", "PV1-16", "PV1-18", "PV1-39", "PV1-41", "PV2-7", "DG1-2"],
            "ADT_A03_discharge.hl7": ["MSH-9.3", "PV1-16", "PV1-18", "PV1-39", "PV1-41", "PV2-28"],
            "ADT_A08_update.hl7": ["MSH-9.3", "PV1"],
            "ORM_O01_lab_order.hl7": ["MSH-9.3", "PV1-16", "PV1-18"],
            "ORU_R01_lab_results.hl7": ["MSH-9.3", "PV1-16", "PV1-18", "OBR-32.2.1", "OBR-32.3.1"]
        ]
        for file in hl7Fixtures("hl7kit/valid") {
            let message = try hl7LenientParser().parse(Data(contentsOf: file))
            let errors = lotBValidator().validate(message).findings.filter { $0.severity == .error }
            XCTAssertEqual(Set(errors.map { $0.path.description }), expected[file.lastPathComponent], file.lastPathComponent)
        }
        for file in hl7Fixtures("lotB/valid") {
            let message = try HL7Parser().parse(Data(contentsOf: file))
            let report = lotBValidator().validate(message)
            XCTAssertTrue(report.isValid, "\(file.lastPathComponent): \(report.findings)")
            XCTAssertTrue(report.findings.allSatisfy { $0.code == .deprecatedField })
        }
    }
}
