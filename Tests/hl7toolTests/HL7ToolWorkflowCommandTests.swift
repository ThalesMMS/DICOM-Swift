import ArgumentParser
import Darwin
import DicomCore
import DicomTestSupport
import FHIR
import Foundation
import HL7v3Transport
import XCTest
@testable import hl7tool

final class HL7ToolWorkflowCommandTests: XCTestCase {
    func test_smartFiles_replaceExistingFilesWithPrivatePermissions() async throws {
        let server = try await FHIROracleServerProxy.start()
        defer { server.stop() }
        let directory = try temporaryDirectory()
        let state = directory.appendingPathComponent("state.json")
        let token = directory.appendingPathComponent("token.json")
        for file in [state, token] {
            try Data("old".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        }
        let output = try await run(["smart", "authorize-url", server.baseURL.absoluteString, "--client-id", "isis-app",
                                    "--redirect-uri", "http://127.0.0.1/callback", "--state-file", state.path, "--intranet-lab", "127.0.0.1"])
        let authorizationURL = try XCTUnwrap(URL(string: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let response = try await HL7v3URLSessionTransport().send(DicomWebHTTPRequest(method: .get, url: authorizationURL, timeout: 5))
        XCTAssertEqual(response.statusCode, 302)
        let redirect = try XCTUnwrap(response.headers.first { $0.key.lowercased() == "location" }?.value)
        _ = try await run(["smart", "exchange", redirect, "--state-file", state.path, "--token-file", token.path, "--intranet-lab", "127.0.0.1"])
        for file in [state, token] {
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600, file.lastPathComponent)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            XCTAssertFalse(object.isEmpty)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["state.json", "token.json"])
    }

    func test_smartWriteFailure_preservesDestinationAndRemovesTemporaryFile() async throws {
        let server = try await FHIROracleServerProxy.start()
        defer { server.stop() }
        let directory = try temporaryDirectory()
        let existing = directory.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let marker = existing.appendingPathComponent("preserve")
        try Data("unchanged".utf8).write(to: marker)
        for destination in [existing, directory.appendingPathComponent("missing/state.json")] {
            do {
                _ = try await run(["smart", "authorize-url", server.baseURL.absoluteString, "--client-id", "isis-app",
                                   "--redirect-uri", "http://127.0.0.1/callback", "--state-file", destination.path, "--intranet-lab", "127.0.0.1"])
                XCTFail("state creation or replacement failure must propagate")
            } catch { XCTAssertTrue(error is POSIXError, "\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: marker), Data("unchanged".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing"])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hl7tool-workflow-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func capture(_ action: () async throws -> Void) async throws -> Data {
        let file = try temporaryDirectory().appendingPathComponent("stdout")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        dup2(handle.fileDescriptor, STDOUT_FILENO)
        defer { fflush(stdout); dup2(saved, STDOUT_FILENO); close(saved); try? handle.close() }
        try await action()
        fflush(stdout)
        return try Data(contentsOf: file)
    }
    private func run(_ args: [String]) async throws -> Data {
        var command = try HL7Tool.parseAsRoot(args)
        return try await capture {
            if var asyncCommand = command as? AsyncParsableCommand { try await asyncCommand.run() } else { try command.run() }
        }
    }
    private func fixture(_ name: String) -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ClinicalMappingTests/Fixtures/" + name).path
    }

    func test_map_hl7ToFHIRAndModel_andDicomToFHIR() async throws {
        let request = try await run(["workflow", "map", "hl7", fixture("order.hl7"), "--target", "fhir", "--patient", "Patient/p1"])
        let resource = try FHIRResource(jsonData: request)
        XCTAssertEqual(resource.resourceType, "ServiceRequest")
        XCTAssertEqual(resource.as(FHIRServiceRequest.self)?.identifiers.count, 3)
        let model = try await run(["workflow", "map", "hl7", fixture("result.hl7")])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: model) as? [String: Any])
        XCTAssertEqual(object["studyInstanceUID"] as? String, "2.25.23269902")
        let reportBundle = try await run(["workflow", "map", "hl7", fixture("result.hl7"), "--target", "fhir", "--patient", "Patient/p1"])
        let bundle = try XCTUnwrap(FHIRResource(jsonData: reportBundle).as(FHIRBundle.self))
        XCTAssertEqual(bundle.entries.map { $0.resource?.resourceType }, ["DiagnosticReport", "Observation", "Observation", "Observation", "Provenance"])
        let mwl = try await run(["workflow", "map", "hl7", fixture("order.hl7"), "--target", "mwl"])
        XCTAssertTrue(String(decoding: mwl, as: UTF8.self).contains("\"accessionNumber\" : \"ACC-42\""))
        let dir = try temporaryDirectory()
        let dicom = dir.appendingPathComponent("ct1.dcm")
        try DicomStructuralFixtures.ctSlice(index: 1).write(to: dicom)
        let study = try await run(["workflow", "map", "dicom", dicom.path, "--target", "fhir", "--patient", "Patient/p1"])
        XCTAssertEqual(try FHIRResource(jsonData: study).as(FHIRImagingStudy.self)?.studyInstanceUID, "2.25.23269902")
        let patient = dir.appendingPathComponent("patient.json")
        try FHIRResource(jsonData: request).jsonData().write(to: patient)
        let hl7 = try await run(["workflow", "map", "fhir", patient.path, "--target", "hl7"])
        XCTAssertTrue(String(decoding: hl7, as: UTF8.self).hasPrefix("MSH|"))
    }

    func test_demo_reportsIdempotentFlowAndRefusals() async throws {
        let dir = try temporaryDirectory()
        let study = dir.appendingPathComponent("ct1.dcm")
        try DicomStructuralFixtures.ctSlice(index: 1, extra: [
            DicomStructuralFixtures.string(.patientName, .PN, ["Synthetic^Ana Maria"]), DicomStructuralFixtures.string(.patientSex, .CS, ["F"]),
            DicomDataElement(tag: 0x0010_0030, vr: .DA, value: .strings(["19800102"])),
            DicomStructuralFixtures.string(.patientID, .LO, ["MRN-1001"]), DicomDataElement(tag: 0x0010_0021, vr: .LO, value: .strings(["HOSP-A"])),
            DicomStructuralFixtures.string(.accessionNumber, .SH, ["ACC-42"]),
            DicomDataElement(tag: 0x0008_0051, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: [DicomDataElement(tag: 0x0040_0031, vr: .UT, value: .strings(["HOSP-A"]))]))]))
        ]).write(to: study)
        let output = String(decoding: try await run(["workflow", "demo", "--order", fixture("order.hl7"), "--study", study.path, "--result", fixture("result.hl7"), "--repeat-count", "2"]), as: UTF8.self)
        XCTAssertTrue(output.contains("attempt 1 order order:PLC-500@RIS-A -> created identity=new"), output)
        XCTAssertTrue(output.contains("attempt 1 study study:2.25.23269902 -> linked order=order:PLC-500@RIS-A"), output)
        XCTAssertTrue(output.contains("attempt 1 result result:FIL-900@PACS-A:v1 -> created order=order:PLC-500@RIS-A study=study:2.25.23269902"), output)
        XCTAssertTrue(output.contains("attempt 2 order order:PLC-500@RIS-A -> duplicate"), output)
        XCTAssertTrue(output.contains("attempt 2 result result:FIL-900@PACS-A:v1 -> duplicate"), output)
        XCTAssertTrue(output.contains("stored orders=1 studies=1 results=1 patients=1"), output)
        let orphan = String(decoding: try await run(["workflow", "demo", "--order", fixture("order.hl7"), "--result", fixture("result-corrected.hl7"), "--repeat-count", "1"]), as: UTF8.self)
        XCTAssertTrue(orphan.contains("result result:FIL-900@PACS-A:v1 -> created"), orphan)
        do {
            _ = try await run(["workflow", "demo", "--order", fixture("adt.hl7")])
            XCTFail("an ADT is not an order")
        } catch { XCTAssertTrue("\(error)".contains("unsupportedMessage"), "\(error)") }
    }
}
