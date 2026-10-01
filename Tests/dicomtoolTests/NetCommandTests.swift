import ArgumentParser
import DicomCore
import DicomTestSupport
import XCTest
@testable import dicomtool

#if os(macOS)
final class NetCommandTests: XCTestCase {
    func test_directoryRetrieve_requiresCompleteResourceHierarchy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for includeSeries in [false, true] {
            var data = DicomDataSet(elements: [
                .init(tag: 0x00080016, vr: .UI, value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
                .init(tag: 0x00080018, vr: .UI, value: .strings(["2.25.3"])),
                .init(tag: 0x0020000D, vr: .UI, value: .strings(["2.25.1"]))
            ])
            if includeSeries { data.set(.init(tag: 0x0020000E, vr: .UI, value: .strings(["2.25.2"]))) }
            try DicomDataSetWriter.part10Data(from: data).write(to: directory.appendingPathComponent("synthetic.dcm"))
            let request = DicomRetrieveRequest(model: .studyRoot, level: .study, identifier: .init(), requestingAETitle: "ISIS")
            var resources: [DicomResourceRef?] = []
            for try await instance in NetCommand.DirectoryProvider(directory: directory).instances(for: request) {
                resources.append(instance.resource)
            }
            XCTAssertEqual(resources.count, 1)
            if includeSeries {
                XCTAssertEqual(resources.first!, .init(kind: .instance, id: "2.25.3",
                    parent: .init(kind: .series, id: "2.25.2", parent: .init(kind: .study, id: "2.25.1"))))
            } else { XCTAssertNil(resources.first!) }
        }
    }
    func test_commit_independentPeerReportsToTemporarySharedServer() async throws {
        let probe = DicomDIMSEServer(configuration: .init(aeTitle: "DICOMTOOL", port: 0))
        try probe.start()
        let port = try XCTUnwrap(probe.listeningPort)
        await probe.stop()
        let peer = try PynetdicomPeer(configuration: ["commitment_port": port, "commitment_aet": "DICOMTOOL", "generate_rle": true])
        defer { _ = try? peer.stop() }
        var command = try NetCommand.Commit.parse(["--port", String(peer.port), "--called-aet", "PYNETDICOM",
            "--listen-port", String(port), "--wait", "5", peer.fixtureURL.path])
        try await command.run()
    }

    func test_echoAndFind_independentPeer() throws {
        let peer = try PynetdicomPeer()
        defer { _ = try? peer.stop() }
        let options = ["--port", String(peer.port), "--called-aet", "PYNETDICOM", "--timeout", "3"]
        var echo = try NetCommand.Echo.parse(options)
        try echo.run()
        var find = try NetCommand.Find.parse(options + ["--key", "0020000D=2.25.2350", "--json"])
        try find.run()
    }

    func test_mwlAndMPPS_independentPeer() throws {
        let peer = try PynetdicomPeer()
        defer { _ = try? peer.stop() }
        let options = ["--port", String(peer.port), "--called-aet", "PYNETDICOM", "--timeout", "3"]
        var mwl = try NetCommand.MWL.parse(options + ["--json"])
        try mwl.run()
        var create = try NetCommand.MPPS.Create.parse(options + ["--uid", "2.25.235099"])
        try create.run()
        var set = try NetCommand.MPPS.Set.parse(options + ["--uid", "2.25.235099"])
        try set.run()
    }

    func test_storeAndGet_independentPeer() async throws {
        let peer = try PynetdicomPeer(configuration: ["generate_rle": true, "syntaxes": ["1.2.840.10008.1.2.1", "1.2.840.10008.1.2", "1.2.840.10008.1.2.5"]])
        defer { _ = try? peer.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let options = ["--port", String(peer.port), "--called-aet", "PYNETDICOM", "--timeout", "3"]
        var store = try NetCommand.Store.parse(options + [peer.fixtureURL.path])
        try await store.run()
        var get = try NetCommand.Get.parse(options + ["--output", directory.path, "--key", "0020000D=2.25.2350"])
        try get.run()
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func test_move_independentPeerDeliversToCLIListener() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let listener = try NetCommand.Listen.parse([directory.path, "--port", "0", "--aet", "DICOMTOOL"])
        let server = try listener.start()
        let peer = try PynetdicomPeer(configuration: ["move_port": try XCTUnwrap(server.listeningPort)])
        defer { _ = try? peer.stop() }
        do {
            var move = try NetCommand.Move.parse(["--port", String(peer.port), "--called-aet", "PYNETDICOM",
                "--destination-ae", "DICOMTOOL", "--key", "0020000D=2.25.2350"])
            try move.run()
            XCTAssertFalse(try NetCommand.files([directory.path]).isEmpty)
        } catch { await server.stop(); throw error }
        _ = try peer.stop()
        await server.stop()
    }

    func test_listen_directoryQueriesAndRetrieve_independentSCU() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = DicomDataSet(elements: [
            .init(tag: 0x00080016, vr: .UI, value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
            .init(tag: 0x00080018, vr: .UI, value: .strings(["2.25.2350001"])),
            .init(tag: 0x0020000D, vr: .UI, value: .strings(["2.25.2350"])),
            .init(tag: 0x0020000E, vr: .UI, value: .strings(["2.25.23501"])),
            .init(tag: 0x00100020, vr: .LO, value: .strings(["SYNTHETIC-B"]))
        ])
        try DicomDataSetWriter.part10Data(from: data).write(to: directory.appendingPathComponent("synthetic.dcm"))
        let listener = try NetCommand.Listen.parse([directory.path, "--port", "0", "--aet", "ISIS", "--query-retrieve"])
        let server = try listener.start()
        do {
            for operation in ["find", "get"] {
                let result = try await independentSCU(port: XCTUnwrap(server.listeningPort), operation: operation)
                XCTAssertEqual((result["statuses"] as? [Int])?.last, 0, "\(result)")
                if operation == "get" { XCTAssertEqual((result["stores"] as? [[String: Any]])?.count, 1) }
                else { XCTAssertEqual(result["statuses"] as? [Int], [0xFF00, 0]) }
            }
        } catch { await server.stop(); throw error }
        await server.stop()
    }

    private func independentSCU(port: UInt16, operation: String, extras: [String: Any] = [:]) async throws -> [String: Any] {
        let python = try XCTUnwrap(PynetdicomPeer.pythonPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = directory.appendingPathComponent("result.json")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/interop/pynetdicom_peer.py")
        var configuration: [String: Any] = ["role": "scu", "operation": operation, "port": Int(port),
            "result_path": result.path,
            "identifier": ["QueryRetrieveLevel": "STUDY", "StudyInstanceUID": "2.25.2350"]]
        configuration.merge(extras) { _, new in new }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script.path, String(decoding: try JSONSerialization.data(withJSONObject: configuration), as: UTF8.self)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard !process.isRunning else { throw NSError(domain: "IndependentPeerTimeout", code: 1) }
        XCTAssertEqual(process.terminationStatus, 0)
        return try JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: Any] ?? [:]
    }


    func test_upsAndIAN_commandsAgainstIndependentSCP() async throws {
        let peer = try PynetdicomPeer()
        defer { _ = try? peer.stop() }
        let options = ["--port", String(peer.port), "--called-aet", "PYNETDICOM", "--timeout", "3"]
        let uid = "2.25.235201"
        func command(_ operation: String, _ args: [String]) async throws -> String {
            try await B2CLI.run(["net", "ups", operation] + options + args)
        }
        try B2CLI.status(await command("create", ["--uid", uid]), 0)
        for sopClass in ["pull", "watch", "query"] {
            let text = try await command("find", ["--class", sopClass, "--key", "00741000=SCHEDULED",
                                                "--key", "00080018="])
            try B2CLI.status(text, 0)
            XCTAssertTrue(text.contains(uid))
        }
        try B2CLI.status(await command("state", ["--uid", uid, "--transaction", "2.25.1", "--state", "IN PROGRESS"]), 0)
        try B2CLI.status(await command("set", ["--uid", uid, "--transaction", "2.25.1",
                                              "--key", "00741204=SECRET-LABEL"]), 0)
        let got = try await command("get", ["--uid", uid])
        try B2CLI.status(got, 0)
        XCTAssertTrue(got.contains("IN PROGRESS"))
        try B2CLI.status(await command("get", ["--uid", uid, "--attribute", "00741000"]), 0)
        try B2CLI.status(await command("state", ["--uid", uid, "--transaction", "2.25.1", "--state", "CANCELED"]), 0)
        try B2CLI.status(await command("create", ["--uid", "2.25.235202"]), 0)
        try B2CLI.status(await command("cancel", ["--uid", "2.25.235202", "--reason", "SECRET-REASON",
                                                 "--contact-name", "SECRET-NAME", "--contact-uri", "https://example.test"]), 0)
        let sent = try await B2CLI.run(["net", "ian", "send"] + options + ["--study", "2.25.100",
            "--retrieve-ae", "ARCHIVE", "--instance", "1.2.840.10008.5.1.4.1.1.7:2.25.102:2.25.101:ONLINE"])
        try B2CLI.status(sent, 0)
        let result = try peer.stop()
        XCTAssertEqual((result["ian"] as? [Any])?.count, 1)
        XCTAssertEqual(result["pynetdicom"] as? String, "3.0.4")
    }

    func test_upsListenAndWatch_subscriptionsAndIndependentSCU() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = DicomDIMSEServer(configuration: .init(aeTitle: "WATCH", port: 0))
        try probe.start()
        let watchPort = try XCTUnwrap(probe.listeningPort)
        await probe.stop()
        let watch = try B2CLI.Running(["net", "ups", "watch", "--receiving-ae", "WATCH",
                                      "--port", String(watchPort), "--duration", "12"])
        let listener = try NetCommand.Listen.parse([directory.path, "--port", "0", "--aet", "ISIS",
            "--ups", "--ian", "--fallback-ae", "WATCH", "--move-destination", "WATCH=127.0.0.1:\(watchPort)"])
        let server = try listener.start()
        do {
            try await Task.sleep(for: .milliseconds(600))
            let port = try XCTUnwrap(server.listeningPort)
            let options = ["--port", String(port), "--called-aet", "ISIS", "--timeout", "3"]
            func command(_ operation: String, _ args: [String]) async throws -> String {
                try await B2CLI.run(["net", "ups", operation] + options + args)
            }
            let creation: [String: Any] = ["ProcedureStepState": "SCHEDULED",
                "ScheduledProcedureStepPriority": "MEDIUM", "ProcedureStepLabel": "SECRET-LABEL",
                "ScheduledProcedureStepStartDateTime": "20260911090000", "InputReadinessState": "READY",
                "ProcedureStepProgressInformationSequence": [], "UnifiedProcedureStepPerformedProcedureSequence": [],
                "PatientName": "SECRET^PATIENT"]
            let steps: [[String: Any]] = [
                ["operation": "ups_create", "attributes": creation],
                ["operation": "ups_find", "attributes": ["ProcedureStepState": "SCHEDULED", "SOPInstanceUID": ""]],
                ["operation": "ups_get", "attribute_ids": [0x00741000]],
                ["operation": "ups_action", "attributes": ["ProcedureStepState": "IN PROGRESS", "TransactionUID": "2.25.1"]],
                ["operation": "ups_set", "attributes": ["TransactionUID": "2.25.1", "ProcedureStepLabel": "SECRET"]],
                ["operation": "ian_create", "uid": "2.25.999", "attributes": [
                    "StudyInstanceUID": "2.25.100", "ReferencedPerformedProcedureStepSequence": [],
                    "ReferencedSeriesSequence": [["SeriesInstanceUID": "2.25.101", "ReferencedSOPSequence": [[
                        "ReferencedSOPClassUID": "1.2.840.10008.5.1.4.1.1.7", "ReferencedSOPInstanceUID": "2.25.102",
                        "InstanceAvailability": "ONLINE", "RetrieveAETitle": "ARCHIVE"]]]]]]]
            let result = try await independentSCU(port: port, operation: "sequence", extras: ["steps": steps])
            XCTAssertEqual(result["statuses"] as? [Int], [0, 0xFF00, 0, 0, 0, 0, 0], "\(result)")
            let uid = "2.25.2352"
            for sopClass in ["pull", "watch", "query"] {
                try B2CLI.status(await command("find", ["--class", sopClass, "--key", "00080018="]), 0)
            }
            let got = try await command("get", ["--uid", uid])
            try B2CLI.status(got, 0)
            XCTAssertFalse(got.contains("PATIENT"))
            try B2CLI.status(await command("subscribe", ["--uid", uid, "--receiving-ae", "WATCH", "--deletion-lock"]), 0)
            try B2CLI.status(await command("unsubscribe", ["--uid", uid, "--receiving-ae", "WATCH"]), 0)
            try B2CLI.status(await command("subscribe", ["--uid", "global", "--receiving-ae", "WATCH"]), 0)
            try B2CLI.status(await command("suspend", ["--receiving-ae", "WATCH"]), 0)
            try B2CLI.status(await command("unsubscribe", ["--uid", "global", "--receiving-ae", "WATCH"]), 0)
            try B2CLI.status(await command("subscribe", ["--uid", "filtered", "--receiving-ae", "WATCH",
                                                       "--key", "00741000=SCHEDULED"]), 0)
            let events = try B2CLI.rows(await watch.finish())
            XCTAssertTrue(events.contains { $0["uid"] as? String == uid && $0["type"] as? Int == 1
                && $0["state"] as? String == "IN PROGRESS" })
        } catch { await server.stop(); throw error }
        await server.stop()
    }

    func test_invalidKeysAndPolicy_rejectedBeforeNetwork() throws {
        XCTAssertThrowsError(try NetCommand.identifier(["not-a-tag=x"]))
        XCTAssertEqual(try NetCommand.identifier(["00100020="]).string(for: 0x00100020), "")
    }
}
#endif

// Runs the actual executable, including the root ArgumentParser command tree.
enum B2CLI {
    static var package: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    final class Running: @unchecked Sendable {
        let process = Process()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("b2-cli-\(UUID()).log")
        let handle: FileHandle
        init(_ arguments: [String]) throws {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            handle = try FileHandle(forWritingTo: output)
            process.executableURL = package.appendingPathComponent(".build/debug/dicomtool")
            process.arguments = arguments
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
        }
        deinit {
            if process.isRunning { process.terminate() }
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
        }
        func finish() async throws -> String {
            let deadline = Date().addingTimeInterval(30)
            while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            guard !process.isRunning else { throw NSError(domain: "B2CLITimeout", code: 1) }
            let text = try String(contentsOf: output, encoding: .utf8)
            XCTAssertEqual(process.terminationStatus, 0, text)
            return text
        }
    }

    @discardableResult
    static func run(_ arguments: [String]) async throws -> String {
        try await Running(arguments).finish()
    }

    static func rows(_ text: String) throws -> [[String: Any]] {
        try text.split(separator: "\n").map {
            guard let row = (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] else {
                XCTFail("Non-JSON CLI output: " + text)
                throw NSError(domain: "B2CLIOutput", code: 1)
            }
            XCTAssertTrue(Set(row.keys).isSubset(of: ["uid", "state", "status", "type", "gap",
                                                     "study", "series", "class", "instance"]), "\(row)")
            return row
        }
    }

    static func status(_ text: String, _ expected: Int) throws {
        let rows = try rows(text)
        XCTAssertEqual(rows.last?["status"] as? Int, expected, text)
        XCTAssertFalse(text.contains("SECRET"))
    }
}
