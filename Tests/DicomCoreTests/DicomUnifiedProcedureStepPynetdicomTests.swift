import Foundation
import XCTest
import DicomTestSupport
@testable import DicomCore

#if os(macOS)
final class DicomUnifiedProcedureStepPynetdicomTests: XCTestCase, @unchecked Sendable {
    private func requirePeer() throws -> String {
        if let python = PynetdicomPeer.pythonPath { return python }
        if ProcessInfo.processInfo.environment["DICOM_REQUIRE_PYNETDICOM"] == "1" {
            XCTFail("Required pynetdicom 3.0.4 is unavailable")
            throw NSError(domain: "UPSPeer", code: 1)
        }
        throw XCTSkip("pynetdicom unavailable")
    }
    private var creation: [String: Any] {
        ["ProcedureStepState": "SCHEDULED", "ScheduledProcedureStepPriority": "MEDIUM",
         "ProcedureStepLabel": "SYNTHETIC", "ScheduledProcedureStepStartDateTime": "20260911090000",
         "InputReadinessState": "READY", "ProcedureStepProgressInformationSequence": [],
         "UnifiedProcedureStepPerformedProcedureSequence": []]
    }
    private var completion: [String: Any] {
        let code = [["CodeValue": "TEST", "CodingSchemeDesignator": "99TEST", "CodeMeaning": "Synthetic"]]
        return ["TransactionUID": "2.25.1", "UnifiedProcedureStepPerformedProcedureSequence": [[
            "PerformedStationNameCodeSequence": code, "PerformedProcedureStepStartDateTime": "20260911090000",
            "PerformedProcedureStepEndDateTime": "20260911100000", "PerformedWorkitemCodeSequence": code,
            "OutputInformationSequence": []]]]
    }
    private var ian: [String: Any] {
        ["StudyInstanceUID": "2.25.100", "ReferencedPerformedProcedureStepSequence": [],
         "ReferencedSeriesSequence": [["SeriesInstanceUID": "2.25.101", "ReferencedSOPSequence": [[
            "ReferencedSOPClassUID": DicomStorageSOPClassUIDs.secondaryCaptureImageStorage,
            "ReferencedSOPInstanceUID": "2.25.102", "InstanceAvailability": "ONLINE", "RetrieveAETitle": "ARCHIVE"]]]]]
    }
    func test_pynetdicomSCU_fullWorkflowWithCallbacksAndIAN() async throws {
        _ = try requirePeer()
        let resolver = A2DestinationResolver()
        let store = DicomInMemoryUnifiedProcedureStepStore()
        let journal = UPSJournal()
        let receiver = IANReceiver()
        let service = DicomUnifiedProcedureStepService(store: store, observer: journal)
        let server = DicomDIMSEServer(configuration: .init(aeTitle: "ISIS", port: 0), moveDestinations: resolver,
                                     unifiedProcedureSteps: service, instanceAvailability: receiver)
        try server.start()
        do {
            let steps: [[String: Any]] = [
                ["operation": "ups_create", "attributes": creation],
                ["operation": "ups_action", "action": 3, "context": DicomNetworkUID.unifiedProcedureStepWatchSOPClass,
                 "attributes": ["ReceivingAE": "PYNETSCU", "DeletionLock": "TRUE"]],
                ["operation": "ups_find", "attributes": ["ProcedureStepState": "SCHEDULED", "SOPClassUID": "", "SOPInstanceUID": ""]],
                ["operation": "ups_action", "attributes": ["ProcedureStepState": "IN PROGRESS", "TransactionUID": "2.25.1"]],
                ["operation": "ups_set", "attributes": ["TransactionUID": "2.25.1",
                    "ProcedureStepProgressInformationSequence": [["ProcedureStepProgress": "50"]]]],
                ["operation": "ups_get"],
                ["operation": "ups_get", "attribute_ids": [0x00741000]],
                ["operation": "ups_set", "attributes": completion],
                ["operation": "ups_action", "attributes": ["ProcedureStepState": "COMPLETED", "TransactionUID": "2.25.1"]],
                ["operation": "ups_create", "uid": "2.25.2353", "attributes": creation],
                ["operation": "ups_action", "uid": "2.25.2353", "action": 3, "context": DicomNetworkUID.unifiedProcedureStepWatchSOPClass,
                 "attributes": ["ReceivingAE": "PYNETSCU", "DeletionLock": "TRUE"]],
                ["operation": "ups_action", "uid": "2.25.2353", "action": 2, "context": DicomNetworkUID.unifiedProcedureStepPushSOPClass],
                ["operation": "ian_create", "uid": "2.25.999", "attributes": ian]]
            let result = try await peer(server: server, extras: ["operation": "sequence", "steps": steps, "callback_listener": true, "ups_debug": true], resolver: resolver)
            XCTAssertEqual(result["pynetdicom"] as? String, "3.0.4")
            XCTAssertEqual(result["statuses"] as? [Int], [0, 0, 0xFF00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], "\(result)")
            let events = try XCTUnwrap(result["events"] as? [[String: Any]])
            XCTAssertEqual(events.compactMap { $0["type"] as? Int }, [1, 1, 3, 1, 1, 1, 1])
            XCTAssertEqual(events.compactMap { $0["state"] as? String }, ["SCHEDULED", "IN PROGRESS", "", "COMPLETED", "SCHEDULED", "IN PROGRESS", "CANCELED"])
            let results = try XCTUnwrap(result["ups_results"] as? [Any])
            let get = try XCTUnwrap(results[6] as? [String: Any])
            XCTAssertNil(get["00081195"])
            let selected = try XCTUnwrap(results[7] as? [String: Any])
            XCTAssertEqual(Set(selected.keys), ["00741000"])
            XCTAssertEqual(store.all().map(\.state), [.completed, .canceled])
            let notifications = await receiver.received
            XCTAssertEqual(notifications.count, 1)
            let outcomes = await journal.outcomes
            XCTAssertEqual(outcomes, Array(repeating: .succeeded, count: 7))
        } catch { await server.stop(); throw error }
        await server.stop()
    }
    func test_swiftSCU_againstIndependentPythonSCP() throws {
        _ = try requirePeer()
        let peer = try PynetdicomPeer()
        defer { _ = try? peer.stop() }
        let scu = DicomDIMSEServiceSCU(configuration: .init(host: "127.0.0.1", port: peer.port,
                                                          calledAETitle: "PYNETDICOM", callingAETitle: "ISIS", timeout: 5))
        XCTAssertEqual(try scu.createUnifiedProcedureStep(sopInstanceUID: "2.25.2352", attributes: upsFixture()).status, 0)
        let found = try scu.findUnifiedProcedureSteps(identifier: .init(elements: [upsString(0x00741000, "SCHEDULED"),
            upsString(0x00080016, "", .UI), upsString(0x00080018, "", .UI)]))
        XCTAssertEqual(found.status, 0); XCTAssertEqual(found.matches.count, 1)
        XCTAssertEqual(found.matches.first?.string(for: 0x00080016), DicomNetworkUID.unifiedProcedureStepPushSOPClass)
        XCTAssertEqual(try scu.changeUnifiedProcedureStepState(sopInstanceUID: "2.25.2352", to: .inProgress, transactionUID: "2.25.1").status, 0)
        let attributes = upsFinalAttributes().setting(upsString(0x00081195, "2.25.1", .UI))
        XCTAssertEqual(try scu.setUnifiedProcedureStep(sopInstanceUID: "2.25.2352", attributes: attributes).status, 0)
        let get = try scu.getUnifiedProcedureStep(sopInstanceUID: "2.25.2352")
        XCTAssertEqual(get.status, 0); XCTAssertNil(get.dataSet?[0x00081195])
        XCTAssertEqual(try scu.getUnifiedProcedureStep(sopInstanceUID: "2.25.2352", attributes: [0x00741000]).dataSet?.count, 1)
        XCTAssertEqual(try scu.changeUnifiedProcedureStepState(sopInstanceUID: "2.25.2352", to: .completed, transactionUID: "2.25.1").status, 0)
        XCTAssertEqual(try scu.sendInstanceAvailabilityNotification(ianFixture(), sopInstanceUID: "2.25.999").status, 0)
        let result = try peer.stop()
        XCTAssertEqual(result["pynetdicom"] as? String, "3.0.4")
        XCTAssertEqual((result["ian"] as? [Any])?.count, 1)
    }
    func test_twoPynetdicomSCUs_racingClaimExactlyOneSuccess() async throws {
        _ = try requirePeer()
        let service = DicomUnifiedProcedureStepService(store: DicomInMemoryUnifiedProcedureStepStore())
        _ = try await service.create(sopInstanceUID: "2.25.2352", attributes: upsFixture())
        let server = DicomDIMSEServer(configuration: .init(aeTitle: "ISIS", port: 0), unifiedProcedureSteps: service)
        try server.start()
        do {
            async let first = peer(server: server, extras: ["operation": "ups_action", "attributes": [
                "ProcedureStepState": "IN PROGRESS", "TransactionUID": "2.25.1"]])
            async let second = peer(server: server, extras: ["operation": "ups_action", "attributes": [
                "ProcedureStepState": "IN PROGRESS", "TransactionUID": "2.25.2"]])
            let results = try await [first, second]
            XCTAssertEqual(results.flatMap { $0["statuses"] as? [Int] ?? [] }.sorted(), [0, 0xC301])
        } catch { await server.stop(); throw error }
        await server.stop()
    }
    private func peer(server: DicomDIMSEServer, extras: [String: Any], resolver: A2DestinationResolver? = nil) async throws -> [String: Any] {
        let python = try requirePeer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("isis-ups-peer-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready.json"), result = directory.appendingPathComponent("result.json")
        let start = directory.appendingPathComponent("start")
        var config = extras
        config["role"] = "scu"; config["port"] = try XCTUnwrap(server.listeningPort)
        config["ready_path"] = ready.path; config["result_path"] = result.path
        if resolver != nil { config["start_path"] = start.path }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/interop/pynetdicom_peer.py")
        process.arguments = [script.path, String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)]
        let log = directory.appendingPathComponent("peer.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.standardOutput = output; process.standardError = output
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(40)
        if let resolver {
            while !FileManager.default.fileExists(atPath: ready.path) && process.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let data = try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: Any]
            await resolver.set("PYNETSCU", port: UInt16(try XCTUnwrap(data?["port"] as? Int)))
            try Data().write(to: start)
        }
        while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard !process.isRunning, process.terminationStatus == 0 else {
            throw NSError(domain: "UPSPeer", code: 2, userInfo: [NSLocalizedDescriptionKey:
                (try? String(contentsOf: log, encoding: .utf8)) ?? "Timeout"])
        }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: Any] ?? [:]
    }
}
#endif
