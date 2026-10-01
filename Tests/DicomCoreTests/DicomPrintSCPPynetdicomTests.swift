import Foundation
import XCTest
@testable import DicomCore

#if os(macOS)
final class DicomPrintSCPPynetdicomTests: XCTestCase {
    func test_independentSCU_unknownAttributesInsufficientBoxesAndFaults() async throws {
        for scenario in ["unknown", "insufficient", "create", "set", "action", "referenced_lut"] {
            let output = DicomRasterPrintOutputProvider()
            var configuration = DicomPrintSCPConfiguration(capabilities: .init(acceptedSOPClassUIDs: [
                DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass, DicomNetworkUID.printJobSOPClass,
                DicomNetworkUID.presentationLUTSOPClass, DicomNetworkUID.printerConfigurationRetrievalSOPClass]))
            if scenario == "create" { configuration.failCreate = 0x0110 }
            if scenario == "set" { configuration.failSet = 0xC605 }
            if scenario == "action" { configuration.failAction = 0xC602 }
            let server = DicomDIMSEServer(configuration: .init(aeTitle: "ISIS", port: 0), print: configuration,
                printProvider: DicomPrintSCPProvider(outputProvider: output))
            try server.start()
            do {
                var options: [String: Any] = [:]
                if scenario == "unknown" { options["unknown_attribute"] = true }
                if scenario == "referenced_lut" { options["lut"] = true; options["delete_referenced_lut"] = true }
                if scenario == "insufficient" {
                    options["images"] = Array(repeating: ["rows": 1, "columns": 1, "pixels": "00"] as [String: Any], count: 2)
                }
                let result = try await peer(server, options: options)
                let operations = try XCTUnwrap(result["print_operations"] as? [[String: Any]])
                let statuses = operations.compactMap { $0["status"] as? Int }
                switch scenario {
                case "unknown":
                    XCTAssertTrue(statuses.contains(0x0107))
                    XCTAssertTrue(operations.contains { ($0["attribute_identifier_list"] as? String)?.contains("2020") == true })
                case "insufficient": XCTAssertEqual(result["error"] as? String, "Insufficient image boxes")
                case "create": XCTAssertTrue(statuses.contains(0x0110))
                case "set": XCTAssertTrue(statuses.contains(0xC605))
                case "action": XCTAssertTrue(statuses.contains(0xC602))
                default: XCTAssertTrue(statuses.contains(0x0110))
                }
                let records = await output.records
                XCTAssertEqual(records.count, ["unknown", "referenced_lut"].contains(scenario) ? 1 : 0)
            } catch { await server.stop(); throw error }
            await server.stop()
        }
    }

    func test_providerFailureAndCancellation_reportFailureWithoutDone() async throws {
        for cancel in [false, true] {
            let output = FailedOutput()
            let configuration = DicomPrintSCPConfiguration(capabilities: .init(acceptedSOPClassUIDs: [
                DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass, DicomNetworkUID.printJobSOPClass,
                DicomNetworkUID.printerConfigurationRetrievalSOPClass
            ]))
            let server = DicomDIMSEServer(configuration: .init(aeTitle: "ISIS", port: 0), print: configuration,
                printProvider: DicomPrintSCPProvider(outputProvider: output, onJob: { control in
                    if cancel { control.cancel() }
                }))
            try server.start()
            do {
                let result = try await peer(server, options: [:])
                XCTAssertNil(result["error"], "\(result)")
                let events = try XCTUnwrap(result["job_events"] as? [[String: Any]])
                XCTAssertEqual(events.compactMap { $0["type"] as? Int }, cancel ? [1, 4] : [1, 2, 4])
                XCTAssertEqual(events.last?["info"] as? String, cancel ? "CANCELLED" : "FILM JAM")
                let calls = await output.calls
                XCTAssertEqual(calls, cancel ? 0 : 1)
            } catch { await server.stop(); throw error }
            await server.stop()
        }
    }

    private actor FailedOutput: DicomPrintOutputProviding {
        var calls = 0
        func output(_ film: DicomComposedFilm, metadata: DicomPrintOutputMetadata,
                    control: DicomPrintJobControl) async -> DicomPrintOutputResult {
            calls += 1
            return .failure(statusInfo: "FILM JAM")
        }
    }

    func test_independentSCU_grayColorLayoutsAnnotationsLUTAndEvents() async throws {
        for color in [false, true] {
            for layout in ["STANDARD\\1,1", "ROW\\1,2", "COL\\1,2"] {
                let output = DicomRasterPrintOutputProvider()
                var configuration = DicomPrintSCPConfiguration(capabilities: .init(acceptedSOPClassUIDs: [
                    color ? DicomNetworkUID.basicColorPrintManagementMetaSOPClass : DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass,
                    DicomNetworkUID.basicAnnotationBoxSOPClass, DicomNetworkUID.presentationLUTSOPClass,
                    DicomNetworkUID.printJobSOPClass, DicomNetworkUID.printerConfigurationRetrievalSOPClass
                ]))
                configuration.annotationFormats = ["LABEL": 1]
                configuration.outputWidth = 128
                let server = DicomDIMSEServer(configuration: .init(aeTitle: "ISIS", port: 0), print: configuration,
                    printProvider: DicomPrintSCPProvider(outputProvider: output))
                try server.start()
                do {
                    let result = try await peer(server, options: ["color": color, "layout": layout,
                        "annotations": ["SYNTHETIC"], "lut": true])
                    XCTAssertNil(result["error"], "\(result)")
                    XCTAssertEqual(result["established"] as? Bool, true)
                    let operations = try XCTUnwrap(result["print_operations"] as? [[String: Any]])
                    XCTAssertTrue(operations.allSatisfy { $0["status"] as? Int == 0 }, "\(operations)")
                    XCTAssertEqual((result["job_events"] as? [[String: Any]])?.compactMap { $0["type"] as? Int }, [1, 2, 3])
                    let records = await output.records
                    XCTAssertEqual(records.count, 1)
                    XCTAssertEqual(records.first?.film.samplesPerPixel, color ? 3 : 1)
                    XCTAssertEqual(records.first?.film.slotRectangles.count, layout.hasPrefix("STANDARD") ? 1 : 3)
                    let sent = try XCTUnwrap(result["sent_images"] as? [[String: Any]])
                    XCTAssertEqual(records.first?.metadata.imagePixelFingerprints[1], sent.first?["sha256"] as? String)
                } catch { await server.stop(); throw error }
                await server.stop()
            }
        }
    }

    private func peer(_ server: DicomDIMSEServer, options: [String: Any]) async throws -> [String: Any] {
        guard let python = ProcessInfo.processInfo.environment["DICOM_SWIFT_PYNETDICOM_PYTHON"] else {
            throw NSError(domain: "RequiredPynetdicomMissing", code: 1)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("print-a2-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = directory.appendingPathComponent("result.json")
        let log = directory.appendingPathComponent("peer.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let config: [String: Any] = ["role": "print_scu", "print": options,
            "port": try XCTUnwrap(server.listeningPort), "result_path": result.path]
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/interop/pynetdicom_peer.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script.path, String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)]
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(25)
        while process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard !process.isRunning else { throw NSError(domain: "PrintPeerTimeout", code: 1) }
        let diagnostic = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: Any])
    }
}
#endif
