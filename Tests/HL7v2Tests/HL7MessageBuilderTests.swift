import XCTest
@testable import HL7v2

func lotBPatient() -> HL7Segment {
    var pid = HL7Segment(name: "PID")
    pid[3] = HL7Field(repetitions: [HL7ExtendedID(id: "SYNTHETIC", identifierType: "MR").hl7Value])
    pid[5] = HL7Field(repetitions: [HL7PersonName(family: "Example", given: "Test").hl7Value])
    return pid
}
func lotBVisit() -> HL7Segment {
    var pv1 = HL7Segment(name: "PV1"); pv1[2] = HL7Field(.text("I")); return pv1
}
func lotBAdmission() -> HL7Message {
    var builder = HL7MessageBuilder(version: .v2_5_1)
    builder.adt(event: .A01, pid: lotBPatient(), pv1: lotBVisit())
    return builder.message
}
func lotBValidator() -> HL7Validator { HL7Validator(schema: HL7SchemaRegistry.shared.schema(for: .v2_5_1)!) }

final class HL7MessageBuilderTests: XCTestCase {
    func roundTrip(_ builder: HL7MessageBuilder, file: StaticString = #filePath, line: UInt = #line) throws {
        let report = HL7Validator(schema: HL7SchemaRegistry.shared.schema(for: builder.version)!).validate(builder.message)
        XCTAssertTrue(report.isValid, "\(builder.version.rawValue) \(builder.message.messageType) \(report.findings)", file: file, line: line)
        let message = try builder.build()
        let bytes = try HL7Serializer().serialize(message)
        let parsed = try HL7Parser().parse(bytes)
        XCTAssertTrue(HL7Validator(schema: HL7SchemaRegistry.shared.schema(for: builder.version)!).validate(parsed).isValid, file: file, line: line)
        XCTAssertEqual(try HL7Serializer().serialize(parsed), bytes, file: file, line: line)
    }
    func test_ADT_buildsEverySupportedEventAndVersion() throws {
        for version in HL7SchemaRegistry.shared.versions {
            for event in HL7ADTEvent.allCases {
                var b = HL7MessageBuilder(version: version)
                b.adt(event: event, pid: lotBPatient(), pv1: lotBVisit())
                try roundTrip(b)
            }
        }
    }
    func test_orderAndResults_buildInEveryVersion() throws {
        for version in HL7SchemaRegistry.shared.versions {
            var order = HL7MessageBuilder(version: version)
            order.orm(order: .init(placerID: "ORDER1", service: .init(identifier: "TEST", system: "LOCAL")))
            try roundTrip(order)
            var result = HL7MessageBuilder(version: version)
            result.oru(results: [.init(identifier: .init(identifier: "TEST", system: "LOCAL"), dataType: .NM, value: hl7Repetition(["12.5"]))])
            try roundTrip(result)
        }
    }
    func test_ACK_swapsEndpointsAndMirrorsControlIDWithVersionedErrors() throws {
        for version in HL7SchemaRegistry.shared.versions {
            var source = HL7MessageBuilder(version: version)
            source.msh(sendingApp: "SENDER", sendingFacility: "SF", receivingApp: "RECEIVER", receivingFacility: "RF", messageType: "ADT^A01", controlID: "CONTROL")
            for code in HL7AcknowledgmentCode.allCases {
                var ack = HL7MessageBuilder(version: version)
                ack.ack(for: source.message, code: code, errors: [.init(code: .requiredMissing, path: HL7Path("PID-5")!)])
                try roundTrip(ack)
                XCTAssertEqual(ack.message["MSA"]?[2][1][1][1].text, "CONTROL")
                XCTAssertEqual(ack.message["MSH"]?[3][1][1][1].text, "RECEIVER")
                XCTAssertEqual(ack.message["MSH"]?[5][1][1][1].text, "SENDER")
                XCTAssertTrue(hl7HasValue(ack.message["ERR"]![version == .v2_3_1 || version == .v2_4 ? 1 : 3]))
            }
        }
    }
    func test_queriesAndResponses_coverVersionAvailability() throws {
        for version in HL7SchemaRegistry.shared.versions {
            var qry = HL7MessageBuilder(version: version)
            qry.qryA19(patientID: "SYNTHETIC"); try roundTrip(qry)
            var qbp = HL7MessageBuilder(version: version)
            qbp.qbpQ22(patientID: "SYNTHETIC")
            if version == .v2_3_1 { XCTAssertThrowsError(try qbp.build()); continue }
            try roundTrip(qbp)
            for patients in [[], [lotBPatient()], [lotBPatient(), lotBPatient()]] {
                var rsp = HL7MessageBuilder(version: version)
                rsp.rspK22(for: qbp.message, patients: patients)
                try roundTrip(rsp)
            }
        }
    }
    func test_invalidBuild_requiresExplicitOptOut() throws {
        var b = HL7MessageBuilder(version: .v2_5_1)
        b.msh(messageType: "ADT^A01")
        XCTAssertThrowsError(try b.build()) { error in
            guard case HL7BuildError.invalid(let report) = error else { return XCTFail("wrong error") }
            XCTAssertFalse(report.isValid)
        }
        XCTAssertEqual(try b.build(allowInvalid: true).segments.count, 1)
        b.allowInvalid = true
        XCTAssertNoThrow(try b.build())
    }
    func test_typedComponentSetter_writesSubcomponentsAndRejectsUnsupportedVersion() throws {
        var b = HL7MessageBuilder(version: .v2_5_1)
        b.adt(event: .A01, pid: lotBPatient(), pv1: lotBVisit())
        b.set(HL7Path("PID-3.4")!, HL7HierarchicDesignator(namespace: "LAB", universalID: "1.2.3", universalIDType: "ISO"))
        XCTAssertEqual(b.message["PID"]?[3][1][4][2].text, "1.2.3")
        try roundTrip(b)
        var unsupported = HL7MessageBuilder(version: .v2_7)
        unsupported.msh(messageType: "ACK")
        XCTAssertThrowsError(try unsupported.build(allowInvalid: true))
    }
    func test_DSL_andTypedSetters_preserveLiteralSeparators() throws {
        var b = HL7MessageBuilder(version: .v2_5_1)
        b.msh(messageType: "ACK", charset: .utf8)
        b.segment("MSA") { $0.set(1, .text("AA")); $0.set(2, .text("CONTROL")) }
        b.set(HL7Path("MSA-3")!, .text("literal | ^ ~ & \\ á"))
        let bytes = try HL7Serializer().serialize(b.build())
        let parsed = try HL7Parser().parse(bytes)
        XCTAssertEqual(parsed["MSA"]?[3][1][1][1].text, "literal | ^ ~ & \\ á")
    }
}
