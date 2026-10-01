import Foundation
import XCTest
import DicomTestSupport
@testable import DicomCore

#if os(macOS)
final class DicomDIMSEServerPynetdicomTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        let python = ProcessInfo.processInfo.environment["DICOM_SWIFT_PYNETDICOM_PYTHON"]
        guard let python, FileManager.default.isExecutableFile(atPath: python) else {
            if ProcessInfo.processInfo.environment["DICOM_REQUIRE_PYNETDICOM"] == "1" {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey:
                    "Required peer absent: set DICOM_SWIFT_PYNETDICOM_PYTHON to a provisioned interpreter."])
            }
            throw XCTSkip("Set DICOM_SWIFT_PYNETDICOM_PYTHON to run the independent peer tests.")
        }
    }

    func test_receivedCommitmentReport_dispatchesSharedServerHandler_realPeer() async throws {
        let received = expectation(description: "N-EVENT-REPORT")
        let server = DicomDIMSEServer(configuration: .init(aeTitle: "ISIS", port: 0),
            commitmentResultHandler: { report in
                XCTAssertEqual(report.transactionUID, "2.25.235091")
                received.fulfill()
            })
        try server.start()
        let peer = try PynetdicomPeer(configuration: ["commitment_port": try XCTUnwrap(server.listeningPort)])
        do {
            _ = try DicomDIMSEServiceSCU(configuration: .init(host: "127.0.0.1", port: peer.port,
                calledAETitle: "PYNETDICOM", callingAETitle: "ISIS", timeout: 3))
                .requestStorageCommitment(transactionUID: "2.25.235091", references: [
                    .init(sopClassUID: DicomStorageSOPClassUIDs.secondaryCaptureImageStorage, sopInstanceUID: "2.25.2350001")])
            await fulfillment(of: [received], timeout: 5)
        } catch { _ = try? peer.stop(); await server.stop(); throw error }
        _ = try peer.stop()
        await server.stop()
    }

    func test_echo_realSCU() async throws {
        let server = DicomDIMSEServer(configuration: .init(aeTitle: "ISIS", port: 0))
        try server.start()
        let result = try await runPeer(server, operation: "echo")
        await server.stop()
        XCTAssertEqual(result["statuses"] as? [Int], [0])
    }

    func test_find_modelsWildcardRangeAndCancel_realSCU() async throws {
        let server = DicomDIMSEServer(configuration: .init(aeTitle: "ISIS", port: 0),
            query: A2QueryProvider(delay: 50_000_000, paddingLength: 4096), worklist: A2QueryProvider(delay: 50_000_000))
        try server.start()
        for operation in ["find", "patient_find", "mwl"] {
            var identifier: [String: Any] = ["PatientName": "SYN*^?2", "StudyDate": "20260901-20260930"]
            if operation != "mwl" { identifier["QueryRetrieveLevel"] = operation == "patient_find" ? "PATIENT" : "STUDY" }
            if operation == "mwl" {
                identifier.removeValue(forKey: "StudyDate")
                identifier["ScheduledProcedureStepSequence"] = [["ScheduledStationAETitle": "ISIS",
                    "ScheduledProcedureStepStartDate": "20260901-20260930"]]
            }
            let result = try await runPeer(server, operation: operation, extras: ["identifier": identifier, "max_pdu": 1024])
            XCTAssertEqual(result["statuses"] as? [Int], [0xFF00, 0xFF00, 0xFF00, 0], "\(result)")
        }
        let hierarchical = try await runPeer(server, operation: "find", extras: ["identifier": [
            "QueryRetrieveLevel": "SERIES", "StudyInstanceUID": "2.25.23500", "PatientName": "SYN*"]])
        XCTAssertEqual(hierarchical["statuses"] as? [Int], [0xFF00, 0])
        let cancelled = try await runPeer(server, operation: "find", extras: [
            "identifier": ["QueryRetrieveLevel": "STUDY"], "cancel_after": 1])
        XCTAssertEqual((cancelled["statuses"] as? [Int])?.last, 0xFE00)
        await server.stop()
    }

    func test_get_oneFailureCounted_realSCU() async throws {
        let server = DicomDIMSEServer(configuration: .init(aeTitle: "ISIS", port: 0), retrieve: A2RetrieveProvider())
        try server.start()
        let result = try await runPeer(server, operation: "get", extras: ["fail_store_uid": "2.25.2350002"])
        await server.stop()
        XCTAssertEqual((result["stores"] as? [[String: Any]])?.count, 2, "\(result)")
        XCTAssertEqual((result["statuses"] as? [Int])?.last, 0xB000)
        let final = (result["responses"] as? [[String: Int]])?.last
        XCTAssertEqual(final?["NumberOfCompletedSuboperations"], 1)
        XCTAssertEqual(final?["NumberOfFailedSuboperations"], 1)
    }

    func test_move_destinationAndUnknownAndCancel_realSCU() async throws {
        let destination = try PynetdicomPeer(configuration: ["aet": "DEST", "store_delay": 0.08, "syntaxes": ["1.2.840.10008.1.2"]])
        let resolver = A2DestinationResolver()
        await resolver.set("DEST", port: destination.port)
        let server = DicomDIMSEServer(configuration: .init(aeTitle: "ISIS", port: 0),
            retrieve: A2RetrieveProvider(count: 4), moveDestinations: resolver)
        try server.start()
        let success = try await runPeer(server, operation: "move", extras: ["destination_aet": "DEST"])
        XCTAssertEqual((success["statuses"] as? [Int])?.last, 0)
        let unknown = try await runPeer(server, operation: "move", extras: ["destination_aet": "UNKNOWN"])
        XCTAssertEqual(unknown["statuses"] as? [Int], [0xA801])
        let cancel = try await runPeer(server, operation: "move", extras: ["destination_aet": "DEST", "cancel_after": 1])
        XCTAssertEqual((cancel["statuses"] as? [Int])?.last, 0xFE00)
        await server.stop()
        _ = try destination.stop()
    }

    func test_mpps_finalStateCannotBeUpdated_realSCU() async throws {
        let server = DicomDIMSEServer(configuration: .init(aeTitle: "ISIS", port: 0), mpps: A2MPPSProvider())
        try server.start()
        let result = try await runPeer(server, operation: "mpps")
        await server.stop()
        XCTAssertEqual(result["statuses"] as? [Int], [0, 0, 0x0110], "\(result)")
        XCTAssertEqual(result["error_id"] as? Int, 0xA710)
        XCTAssertEqual(result["error_comment"] as? String, "Performed Procedure Step Object may no longer be updated")
    }

    func test_commitment_sameAssociationAndNewAssociation_realSCU() async throws {
        let resolver = A2DestinationResolver()
        let audit = DicomInMemoryNetworkAuditLog()
        let server = DicomDIMSEServer(configuration: .init(aeTitle: "ISIS", port: 0),
            moveDestinations: resolver, commitment: A2CommitmentProvider(delay: 300_000_000), auditLogger: audit)
        try server.start()
        let same = try await runPeer(server, operation: "action", extras: ["same_association_role": true])
        XCTAssertEqual(same["statuses"] as? [Int], [0], "\(same)")
        XCTAssertEqual(same["event_type"] as? Int, 1, "\(same)")
        let separate = try await runPeer(server, operation: "action", extras: ["callback_listener": true, "release_after_action": true, "transaction_uid": "2.25.235089"], resolver: resolver)
        XCTAssertEqual(separate["released_before_event"] as? Bool, true)
        XCTAssertEqual(separate["statuses"] as? [Int], [0], "\(separate)")
        XCTAssertEqual(separate["event_type"] as? Int, 1, "\(separate)")
        await server.stop()
        XCTAssertEqual(audit.events.filter { $0.operation == .storageCommitmentReport && $0.outcome == .succeeded }.count, 2)
        let failedServer = DicomDIMSEServer(configuration: .init(aeTitle: "ISIS", port: 0),
            commitment: A2CommitmentProvider(failAll: true))
        try failedServer.start()
        let failed = try await runPeer(failedServer, operation: "action")
        await failedServer.stop()
        XCTAssertEqual(failed["event_type"] as? Int, 2)
        XCTAssertEqual(failed["failed_references"] as? [Int], [0x0112])
    }

    func test_identityRejected_realSCU() async throws {
        let server = DicomDIMSEServer(configuration: .init(aeTitle: "ISIS", port: 0), identity: A2RejectIdentity())
        try server.start()
        let result = try await runPeer(server, operation: "echo", extras: ["user_identity": "rejected"])
        await server.stop()
        XCTAssertEqual(result["established"] as? Bool, false)
    }

    func test_asyncWindowFour_findAndEcho_realSCU() async throws {
        let window = DicomAsynchronousOperationsWindow(maximumInvoked: 4, maximumPerformed: 4)
        let server = DicomDIMSEServer(configuration: .init(aeTitle: "ISIS", port: 0,
            asynchronousOperationsWindow: window), query: A2QueryProvider(delay: 100_000_000))
        try server.start()
        let result = try await runPeer(server, operation: "concurrent", extras: ["async_window": [4, 4]])
        await server.stop()
        XCTAssertEqual(result["async_accepted"] as? [Int], [4, 4])
        let responses = try XCTUnwrap(result["concurrent_responses"] as? [[Int]])
        XCTAssertEqual(responses.filter { $0[1] == 0 }.count, 4)
        XCTAssertLessThan(try XCTUnwrap(responses.firstIndex { $0[0] == 4 }),
                          try XCTUnwrap(responses.firstIndex { $0[0] != 4 && $0[1] == 0 }))
    }

    private func runPeer(_ server: DicomDIMSEServer, operation: String, extras: [String: Any] = [:],
                         resolver: A2DestinationResolver? = nil) async throws -> [String: Any] {
        let python = try XCTUnwrap(ProcessInfo.processInfo.environment["DICOM_SWIFT_PYNETDICOM_PYTHON"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("isis-a2-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resultURL = directory.appendingPathComponent("result.json")
        let readyURL = directory.appendingPathComponent("ready.json")
        let startURL = directory.appendingPathComponent("start")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/interop/pynetdicom_peer.py")
        var config = extras
        config["role"] = "scu"
        config["operation"] = operation
        config["port"] = try XCTUnwrap(server.listeningPort)
        config["result_path"] = resultURL.path
        config["ready_path"] = readyURL.path
        if resolver != nil { config["start_path"] = startURL.path }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script.path, String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)]
        let log = directory.appendingPathComponent("peer.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(25)
        if let resolver {
            while !FileManager.default.fileExists(atPath: readyURL.path) && process.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let ready = try JSONSerialization.jsonObject(with: Data(contentsOf: readyURL)) as? [String: Int]
            await resolver.set("PYNETSCU", port: UInt16(try XCTUnwrap(ready?["port"])))
            try Data().write(to: startURL)
        }
        while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard !process.isRunning, process.terminationStatus == 0 else {
            throw NSError(domain: "A2Peer", code: 1, userInfo: [NSLocalizedDescriptionKey:
                (try? String(contentsOf: log, encoding: .utf8)) ?? "timeout"])
        }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: Any] ?? [:]
    }
}
struct A2RejectIdentity: DicomUserIdentityAuthenticating {
    func authenticate(_ identity: DicomUserIdentity) throws -> DicomUserIdentityServerResponse? {
        throw DicomDIMSEProviderError(status: 0x0124)
    }
}
#endif
