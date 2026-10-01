import CryptoKit
import Foundation
import XCTest
@testable import HL7v2

final class HL7OracleCrossParseTests: XCTestCase {
    private struct Oracle: Decodable {
        struct Entry: Decodable {
            struct Schema: Decodable {
                struct Validation: Decodable {
                    struct Finding: Decodable { let path: String; let code: String }
                    let valid: Bool?
                    let errors: [Finding]
                }
                let parsed: Bool
                let version: String?
                let message_type: String?
                let structure: String?
                let segments: [String]
                let validation: Validation
                let serialized_sha256: String?
            }
            struct Structural: Decodable { let segments: [String]; let field_counts: [Int] }
            let id: String
            let hl7apy: Schema
            let python_hl7: Structural
            let unsupported: [String]
        }
        let ready: Bool
        let dependencies: [String: String?]
        let messages: [Entry]
    }
    private struct Sample {
        let id: String
        let bytes: Data
    }
    private var package: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hl7-oracle-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func unavailable() throws -> Never {
        let message = "HL7 oracle unavailable: set HL7V2_ORACLE_PYTHON to Python with hl7apy 1.3.5 and python-hl7 0.4.5"
        if ProcessInfo.processInfo.environment["HL7V2_REQUIRE_ORACLE"] == "1" {
            XCTFail(message)
            throw NSError(domain: "HL7OracleRequired", code: 1)
        }
        throw XCTSkip(message)
    }
    private func oracle(_ samples: [Sample]) throws -> [Oracle.Entry] {
        guard let python = ProcessInfo.processInfo.environment["HL7V2_ORACLE_PYTHON"],
              FileManager.default.isExecutableFile(atPath: python) else { try unavailable() }
        let dir = try directory()
        let input = dir.appendingPathComponent("input.json")
        let result = dir.appendingPathComponent("result.json")
        let ready = dir.appendingPathComponent("ready.json")
        let config: [String: Any] = ["messages": samples.map { ["id": $0.id, "base64": $0.bytes.base64EncodedString()] },
                                    "checks": ["structure", "validate", "roundtrip"],
                                    "ready_path": ready.path, "result_path": result.path]
        try JSONSerialization.data(withJSONObject: config).write(to: input)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [package.appendingPathComponent("Scripts/interop/hl7v2_oracle.py").path]
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        process.standardInput = handle
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); XCTFail("HL7 oracle timeout"); throw NSError(domain: "HL7Oracle", code: 2) }
        guard process.terminationStatus == 0 else {
            XCTFail("HL7 oracle execution failed")
            throw NSError(domain: "HL7Oracle", code: 3)
        }
        let decoded = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: result))
        guard decoded.ready else { try unavailable() }
        XCTAssertTrue(decoded.dependencies["hl7apy"] == "1.3.5")
        XCTAssertTrue(decoded.dependencies["hl7"] == "0.4.5")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        XCTAssertEqual(decoded.messages.map(\.id), samples.map(\.id))
        return decoded.messages
    }
    private func corpus() throws -> [Sample] {
        try (hl7Fixtures("hl7kit") + hl7Fixtures("own") + hl7Fixtures("lotB")).map { url in
            let suffix = url.path.components(separatedBy: "/Fixtures/").last!
            let raw = try Data(contentsOf: url)
            // Corpus LF normalization is explicit and identical for both parsers and CLI.
            let wire = raw.replacingCRLFAndLF()
            return Sample(id: suffix, bytes: wire)
        }
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func compare(_ sample: Sample, _ result: Oracle.Entry) throws {
        let parsed = try? HL7Parser().parse(sample.bytes)
        if sample.id.hasSuffix("bad_segment_id.hl7") {
            XCTAssertNil(parsed, sample.id)
            XCTAssertFalse(result.hl7apy.parsed, sample.id)
            XCTAssertTrue(result.python_hl7.segments.isEmpty, sample.id)
            return
        }
        guard let message = parsed else { XCTFail(sample.id); return }
        XCTAssertTrue(try HL7Serializer().serialize(message) == sample.bytes, sample.id)
        XCTAssertEqual(message.segments.map(\.name), result.python_hl7.segments, sample.id)
        XCTAssertEqual(message.segments.map { $0.fields.count }, result.python_hl7.field_counts, sample.id)
        if result.hl7apy.parsed {
            XCTAssertEqual(message.segments.map(\.name), result.hl7apy.segments, sample.id)
            XCTAssertEqual(message.version?.rawValue, result.hl7apy.version, sample.id)
            let type = [message.messageType.code, message.messageType.triggerEvent, message.messageType.structure]
                .compactMap { $0 }.joined(separator: String(message.encoding.component))
            XCTAssertTrue(type == result.hl7apy.message_type, sample.id)
            if result.unsupported.isEmpty, let version = message.version,
               let schema = HL7SchemaRegistry.shared.schema(for: version) {
                let key = message.messageType.code == "ACK" ? "ACK" :
                    [message.messageType.code, message.messageType.triggerEvent].compactMap { $0 }.joined(separator: "^")
                XCTAssertEqual(message.messageType.structure ?? schema.messageTypeToStructure[key], result.hl7apy.structure, sample.id)
            }
            // hl7apy omits the final CR and trims empty trailing fields/components.
            var canonical = message
            canonical.hasTrailingTerminator = false
            var options = HL7SerializerOptions(); options.trimTrailingEmpty = true
            let canonicalHash = hash(try HL7Serializer(options: options).serialize(canonical))
            let fixtureID = sample.id.hasPrefix("batch/") ? String(sample.id.dropFirst(6)) : sample.id
            let differences = [
                "hl7kit/edge-cases/special_characters.hl7": "hl7apy re-escapes the delimiters around X hex escapes as E escapes",
                "hl7kit/valid/ADT_A01_admission.hl7": "hl7apy removes two internal empty components in malformed PV1-6 (IS)",
                "own/escapes.hl7": "hl7apy re-escapes X/Q/Z/formatting/charset escape delimiters; H/N/F/S/T/R/E remain intact",
                "own/structure.hl7": "hl7apy re-escapes delimiters around the X2222 literal-quotes escape",
                "own/truncation.hl7": "hl7apy emits L escape for the v2.7 truncation character"
            ]
            if let reason = differences[fixtureID] {
                XCTExpectFailure(reason) { XCTAssertTrue(canonicalHash == result.hl7apy.serialized_sha256, sample.id) }
            } else {
                XCTAssertTrue(canonicalHash == result.hl7apy.serialized_sha256, sample.id)
            }
        } else {
            XCTAssertFalse(result.unsupported.isEmpty, sample.id)
        }
        let fixtureID = sample.id.hasPrefix("batch/") ? String(sample.id.dropFirst(6)) : sample.id
        var expectedUnsupported: [String] = []
        if fixtureID == "hl7kit/valid/ACK_general.hl7" { expectedUnsupported = ["hl7apy:structureNotIdentified"] }
        if fixtureID == "hl7kit/valid/ADT_A08_update.hl7" { expectedUnsupported = ["hl7apy:structureUnavailable"] }
        if ["own/oversized.hl7", "own/structure.hl7", "own/truncation.hl7"].contains(fixtureID) {
            expectedUnsupported = ["hl7apy:groupingDropsSegments"]
        }
        if sample.id.hasPrefix("builder/") {
            let parts = sample.id.split(separator: "/").map(String.init)
            let old = ["2.3.1", "2.4"].contains(parts[1])
            if old && (["A04", "A08"].contains(parts[2]) || parts[2].hasPrefix("ACK-")) ||
                parts[1] == "2.4" && parts[2] == "QBP" ||
                ["2.5", "2.5.1", "2.6"].contains(parts[1]) && parts[2].hasPrefix("RSP-") {
                expectedUnsupported = ["hl7apy:structureUnavailable"]
            }
        }
        XCTAssertEqual(result.unsupported, expectedUnsupported, sample.id)
        for reason in result.unsupported { print("HL7 oracle unsupported: \(sample.id) \(reason)") }
    }
    private func validity(_ sample: Sample, _ result: Oracle.Entry, cli: Bool = false) throws {
        let parsed = try? HL7Parser().parse(sample.bytes)
        let actual = parsed.flatMap { message in
            message.version.flatMap { HL7SchemaRegistry.shared.schema(for: $0) }
                .map { HL7Validator(schema: $0).validate(message).isValid }
        } ?? false
        if cli {
            let dir = try directory()
            let file = dir.appendingPathComponent("fixture.hl7")
            try sample.bytes.write(to: file)
            let executable = package.appendingPathComponent(".build/debug/hl7tool")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                XCTFail("hl7tool executable missing"); return
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["validate", file.path, "--version", parsed?.version?.rawValue ?? "2.5.1"]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, actual ? 0 : 2, sample.id)
        }
        guard result.unsupported.isEmpty, let expected = result.hl7apy.validation.valid else { return }
        let originalDisagreements: Set<String> = [
            "hl7kit/edge-cases/long_field_values.hl7", "hl7kit/edge-cases/minimal_valid.hl7",
            "hl7kit/edge-cases/multiple_repeating.hl7", "hl7kit/edge-cases/special_characters.hl7",
            "hl7kit/edge-cases/unicode_characters.hl7", "hl7kit/invalid/invalid_coded_values.hl7",
            "hl7kit/invalid/invalid_datetime.hl7", "hl7kit/invalid/missing_required_evn.hl7"
        ]
        if originalDisagreements.contains(sample.id) {
            let message = try XCTUnwrap(parsed)
            let schema = try XCTUnwrap(message.version.flatMap { HL7SchemaRegistry.shared.schema(for: $0) })
            XCTAssertTrue(HL7Validator(schema: schema).validate(message).findings.contains {
                $0.path == HL7Path("MSH-9.3") && $0.severity == .error
            }, sample.id)
            XCTAssertTrue(expected, sample.id)
            XCTExpectFailure("Original corpus lacks required MSH-9.3; hl7apy infers the structure and accepts it. Table/length issues are warnings and tolerant date text is not revalidated.") {
                XCTAssertEqual(actual, expected, sample.id)
            }
        } else if sample.id == "lotB/valid/ORM_O01_lab_order.hl7" {
            XCTAssertTrue(actual, sample.id)
            XCTAssertEqual(result.hl7apy.validation.errors.first?.code, "cardinality", sample.id)
            XCTAssertEqual(result.hl7apy.validation.errors.first?.path,
                           "ORM_O01_ORDER_DETAIL.ORM_O01_OBRRQDRQ1RXOODSODT_SUPPGRP", sample.id)
            XCTExpectFailure("hl7apy splits the ORM order choice into repeated synthetic groups and rejects their cardinality") {
                XCTAssertEqual(actual, expected, sample.id)
            }
        } else if sample.id.hasPrefix("builder/"), sample.id.hasSuffix("/ORM") {
            XCTAssertTrue(actual, sample.id)
            XCTAssertEqual(result.hl7apy.validation.errors.first?.code, "requiredMissing", sample.id)
            XCTAssertTrue(result.hl7apy.validation.errors.first?.path.hasSuffix(".RQD") == true, sample.id)
            XCTExpectFailure("hl7apy Validator handles choice as sequence and requires RQD alongside the selected OBR alternative") {
                XCTAssertEqual(actual, expected, sample.id)
            }
        } else if sample.id == "builder/2.3.1/ORU" {
            XCTAssertTrue(actual, sample.id)
            XCTAssertEqual(result.hl7apy.validation.errors.first?.path, "OBX.OBX_4", sample.id)
            XCTExpectFailure("Pinned hl7apy 2.3.1 requires OBX-4; our subset permits a single observation without a sub-ID") {
                XCTAssertEqual(actual, expected, sample.id)
            }
        } else {
            XCTAssertEqual(actual, expected, sample.id)
        }
    }
    func test_corpus_crossParsesAndPreservesWire() throws {
        let samples = try corpus()
        for (sample, result) in zip(samples, try oracle(samples)) { try compare(sample, result) }
    }
    func test_correctedCorpus_validationAgrees() throws {
        let samples = try corpus().filter { $0.id.hasPrefix("lotB/") }
        for (sample, result) in zip(samples, try oracle(samples)) { try validity(sample, result) }
    }
    func test_corpus_cliExitCodesAgree() throws {
        let samples = try corpus()
        for (sample, result) in zip(samples, try oracle(samples)) { try validity(sample, result, cli: true) }
    }
    func test_batchMembers_crossParse() throws {
        let originals = try corpus().filter { !$0.id.hasSuffix("bad_segment_id.hl7") }
        let wire = try HL7BatchDocument.join(originals.map(\.bytes), fileEnvelope: true)
        let batch = try HL7BatchDocument.parse(wire)
        var samples = zip(originals, batch.messageRanges).map { Sample(id: "batch/" + $0.id, bytes: wire.subdata(in: $1)) }
        // Lot C's custom-envelope and recovery members are generated synthetic inputs.
        for (index, member) in [hl7Header() + "PID|1\r", hl7Header(),
                                hl7Header() + "PID|GOOD\r", hl7Header() + "PID|LAST\r"].enumerated() {
            samples.append(Sample(id: "batch/generated-\(index)", bytes: Data(member.utf8)))
        }
        for (sample, result) in zip(samples, try oracle(samples)) { try compare(sample, result) }
    }
    func test_builders_parseAndValidateAcrossVersions() throws {
        var samples: [Sample] = []
        func append(_ builder: HL7MessageBuilder, _ kind: String) throws {
            samples.append(Sample(id: "builder/\(builder.version.rawValue)/\(kind)",
                                  bytes: try HL7Serializer().serialize(builder.build())))
        }
        for version in HL7SchemaRegistry.shared.versions {
            for event in HL7ADTEvent.allCases {
                var builder = HL7MessageBuilder(version: version)
                builder.adt(event: event, pid: lotBPatient(), pv1: lotBVisit())
                try append(builder, event.rawValue)
            }
            var builder = HL7MessageBuilder(version: version)
            builder.orm(order: .init(placerID: "ORDER1", service: .init(identifier: "TEST", system: "LOCAL")))
            try append(builder, "ORM")
            builder = HL7MessageBuilder(version: version)
            builder.oru(results: [.init(identifier: .init(identifier: "TEST", system: "LOCAL"), dataType: .NM, value: hl7Repetition(["12.5"]))])
            try append(builder, "ORU")
            for code in HL7AcknowledgmentCode.allCases {
                builder = HL7MessageBuilder(version: version)
                builder.ack(for: lotBAdmission(), code: code)
                try append(builder, "ACK-" + code.rawValue)
            }
            builder = HL7MessageBuilder(version: version)
            builder.qryA19(patientID: "SYNTHETIC"); try append(builder, "QRY")
            if version != .v2_3_1 {
                builder = HL7MessageBuilder(version: version)
                builder.qbpQ22(patientID: "SYNTHETIC"); try append(builder, "QBP")
                let query = builder.message
                for count in 0...2 {
                    builder = HL7MessageBuilder(version: version)
                    builder.rspK22(for: query, patients: Array(repeating: lotBPatient(), count: count))
                    try append(builder, "RSP-\(count)")
                }
            }
        }
        for (sample, result) in zip(samples, try oracle(samples)) {
            try compare(sample, result)
            try validity(sample, result)
        }
    }
}

private extension Data {
    func replacingCRLFAndLF() -> Data {
        var output = Data()
        var previous: UInt8?
        for byte in self {
            if byte != 10 || previous != 13 { output.append(byte == 10 ? 13 : byte) }
            previous = byte
        }
        return output
    }
}
