import ArgumentParser
import DicomCore
import DicomWebHTTP
import Foundation
import XCTest
@testable import dicomtool

final class WebCommandTests: XCTestCase {
    func test_conflictingDuplicate_reportsWarningAndPreservesBothVersions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try WebDirectoryStorage(directory: directory)
        let dataset = DicomDataSet(elements: [
            .init(tag: 0x00080016, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            .init(tag: 0x00080018, vr: .UI, value: .strings(["1.2.3.4"])),
            .init(tag: 0x0020000D, vr: .UI, value: .strings(["1.2"])),
            .init(tag: 0x0020000E, vr: .UI, value: .strings(["1.2.3"]))
        ])
        let original = DicomWebStoredInstance(dataSet: dataset,
            part10Data: try DicomDataSetWriter.part10Data(from: dataset),
            studyInstanceUID: "1.2", seriesInstanceUID: "1.2.3", sopInstanceUID: "1.2.3.4",
            sopClassUID: "1.2.840.10008.5.1.4.1.1.7")
        _ = try await storage.store(instances: [original])
        var conflicting = original
        conflicting.dataSet.set(.init(tag: 0x00100020, vr: .LO, value: .strings(["CONFLICT"])))
        conflicting.part10Data = try DicomDataSetWriter.part10Data(from: conflicting.dataSet)
        XCTAssertNotEqual(conflicting.part10Data, original.part10Data)
        let results = try await storage.store(instances: [original, conflicting])
        XCTAssertNil(results[0].failureReason)
        XCTAssertNil(results[0].warningReason)
        XCTAssertNil(results[1].failureReason)
        XCTAssertEqual(results[1].warningReason, 0xB000)
        // Retained conflicts must report acceptance with a warning through HTTP too (issue #2529).
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://store.test/dicom-web")!),
                                    transport: DicomWebServer(storage: storage))
        let conflict = try await client.storeInstances([.init(data: conflicting.part10Data)])
        XCTAssertEqual(conflict.statusCode, 202)
        XCTAssertEqual(conflict.acceptedInstanceCount, 1)
        XCTAssertEqual(conflict.storeResponse?.instances.count, 1)
        XCTAssertNil(conflict.storeResponse?.instances.first?.failureReason)
        XCTAssertEqual(conflict.storeResponse?.instances.first?.warningReason, 0xB000)
        let retained = try await storage.instance(study: "1.2", series: "1.2.3", instance: "1.2.3.4")
        XCTAssertEqual(retained.part10Data, original.part10Data)
        let conflicts = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent(".conflicts"),
                                                                    includingPropertiesForKeys: nil)
        XCTAssertEqual(conflicts.count, 1)
        let archived = try XCTUnwrap(conflicts.first)
        let filename = original.sopInstanceUID.utf8.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(archived.lastPathComponent,
                       "\(filename)~\(DicomArchiveRepresentation.hash(conflicting.part10Data)).dcm")
        XCTAssertEqual(try Data(contentsOf: archived), conflicting.part10Data)
        let restarted = try WebDirectoryStorage(directory: directory)
        let recovered = try await restarted.instance(study: "1.2", series: "1.2.3", instance: "1.2.3.4")
        XCTAssertEqual(recovered.part10Data, original.part10Data)
    }

    func test_serve_mixedDirectoryKeepsValidInstancesAvailable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("web-mixed-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dataSet = DicomDataSet(elements: [
            .init(tag: 0x00080016, vr: .UI, value: .strings([DicomStorageSOPClassUIDs.secondaryCaptureImageStorage])),
            .init(tag: 0x00080018, vr: .UI, value: .strings(["2.25.9003"])),
            .init(tag: 0x0020000D, vr: .UI, value: .strings(["2.25.9001"])),
            .init(tag: 0x0020000E, vr: .UI, value: .strings(["2.25.9002"]))
        ])
        try DicomDataSetWriter.part10Data(from: dataSet).write(to: directory.appendingPathComponent("valid.dcm"))
        try Data("Unrelated directory notes".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        try Data([0, 1, 2]).write(to: directory.appendingPathComponent("broken.dcm"))
        let command = try WebCommand.Serve.parse([directory.path, "--port", "0"])
        let (listener, root) = try await command.start()
        do {
            let client = DicomWebClient(configuration: .init(baseURL: root.appendingPathComponent("dicom-web")))
            let studies = try await client.searchStudies()
            XCTAssertEqual(studies.map(\.studyInstanceUID), ["2.25.9001"])
            let retrieved = try await client.retrieveInstance(studyInstanceUID: "2.25.9001",
                seriesInstanceUID: "2.25.9002", sopInstanceUID: "2.25.9003")
            XCTAssertFalse(retrieved.parts.isEmpty)
        } catch { await listener.stop(); throw error }
        await listener.stop()
    }

    private func independentInterpreter() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["DICOM_SWIFT_PYNETDICOM_PYTHON"],
              FileManager.default.isExecutableFile(atPath: path) else {
            if ProcessInfo.processInfo.environment["DICOM_REQUIRE_PYNETDICOM"] == "1" {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey:
                    "Required peer absent: set DICOM_SWIFT_PYNETDICOM_PYTHON to a provisioned interpreter."])
            }
            throw XCTSkip("Set DICOM_SWIFT_PYNETDICOM_PYTHON to run the independent client.")
        }
        return path
    }

    func test_upsServe_independentRequestsAndWebsockets() async throws {
        let interpreter = try independentInterpreter()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = try WebCommand.Serve.parse([directory.path, "--port", "0", "--ups"])
        let (listener, root) = try await command.start()
        do {
            let endpoint = root.appendingPathComponent("dicom-web").absoluteString
            let result = try await Task.detached {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: interpreter)
                process.arguments = [B2CLI.package.appendingPathComponent("Scripts/interop/ups_rs_probe.py").path, endpoint]
                process.standardOutput = pipe
                process.standardError = pipe
                try process.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, output)
            }.value
            XCTAssertEqual(result.0, 0, String(decoding: result.1, as: UTF8.self))
            guard result.0 == 0 else { await listener.stop(); return }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result.1) as? [String: Any])
            XCTAssertEqual(json["events"] as? [String], ["SCHEDULED", "IN PROGRESS", "progress", "COMPLETED"])
            XCTAssertEqual(json["gap"] as? Bool, true)
            XCTAssertGreaterThanOrEqual((json["statuses"] as? [String: Int])?.count ?? 0, 25)
        } catch { await listener.stop(); throw error }
        await listener.stop()
    }

    func test_upsCommandsAndWatch_endToEndWithIdentityFreeOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let serve = try WebCommand.Serve.parse([directory.path, "--port", "0", "--ups", "--bearer", "test-token"])
        let (listener, root) = try await serve.start()
        do {
            let options = ["--url", root.appendingPathComponent("dicom-web").absoluteString, "--bearer", "test-token"]
            func command(_ operation: String, _ args: [String]) async throws -> String {
                try await B2CLI.run(["web", "ups", operation] + options + args)
            }
            let uid = "2.25.235210"
            var attributes = try NetCommand.UPS.attributes(file: nil)
            attributes.set(.init(tag: 0x00100010, vr: .PN, value: .strings(["SECRET^PATIENT"])))
            attributes.set(.init(tag: 0x00100020, vr: .LO, value: .strings(["SECRET-ID"])))
            let fixture = directory.appendingPathComponent("ups.json")
            try DicomJSONCodec.encode([attributes]).write(to: fixture)
            try B2CLI.status(await command("create", ["--uid", uid, "--file", fixture.path]), 201)
            try B2CLI.status(await command("get", ["--uid", uid]), 200)
            let search = try await command("search", ["--key", "00741000=SCHEDULED", "--limit", "10", "--offset", "0"])
            try B2CLI.status(search, 200)
            XCTAssertTrue(search.contains(uid))
            try B2CLI.status(await command("subscribe", ["--uid", uid, "--subscriber", "WATCH", "--deletion-lock"]), 201)
            let watch = try B2CLI.Running(["web", "ups", "watch"] + options + ["--subscriber", "WATCH", "--duration", "8"])
            try await Task.sleep(for: .milliseconds(700))
            try B2CLI.status(await command("state", ["--uid", uid, "--transaction", "2.25.1", "--state", "IN PROGRESS"]), 200)
            try B2CLI.status(await command("update", ["--uid", uid, "--transaction", "2.25.1",
                                                    "--key", "00741204=SECRET-LABEL"]), 200)
            let code = DicomDataSet(elements: [
                .init(tag: 0x00080100, vr: .SH, value: .strings(["TEST"])),
                .init(tag: 0x00080102, vr: .SH, value: .strings(["99TEST"])),
                .init(tag: 0x00080104, vr: .LO, value: .strings(["Synthetic"]))])
            let performed = DicomDataSet(elements: [
                .init(tag: 0x00404028, vr: .SQ, value: .sequence([.init(dataSet: code)])),
                .init(tag: 0x00404050, vr: .DT, value: .strings(["20260911090000"])),
                .init(tag: 0x00404051, vr: .DT, value: .strings(["20260911100000"])),
                .init(tag: 0x00404019, vr: .SQ, value: .sequence([.init(dataSet: code)])),
                .init(tag: 0x00404033, vr: .SQ, value: .sequence([]))])
            let final = DicomDataSet(elements: [
                .init(tag: 0x00741216, vr: .SQ, value: .sequence([.init(dataSet: performed)]))])
            try DicomJSONCodec.encode([final]).write(to: fixture)
            try B2CLI.status(await command("update", ["--uid", uid, "--transaction", "2.25.1", "--file", fixture.path]), 200)
            try B2CLI.status(await command("state", ["--uid", uid, "--transaction", "2.25.1", "--state", "COMPLETED"]), 200)
            let events = try B2CLI.rows(await watch.finish())
            XCTAssertTrue(events.contains { $0["uid"] as? String == uid && $0["state"] as? String == "IN PROGRESS" })
            XCTAssertTrue(events.contains { $0["uid"] as? String == uid && $0["state"] as? String == "COMPLETED" })
            try B2CLI.status(await command("unsubscribe", ["--uid", uid, "--subscriber", "WATCH"]), 200)
            try B2CLI.status(await command("subscribe", ["--uid", "global", "--subscriber", "GLOBAL"]), 201)
            try B2CLI.status(await command("suspend", ["--subscriber", "GLOBAL"]), 200)
            try B2CLI.status(await command("subscribe", ["--uid", "global", "--subscriber", "GLOBAL"]), 201)
            try B2CLI.status(await command("unsubscribe", ["--uid", "global", "--subscriber", "GLOBAL"]), 200)
            try B2CLI.status(await command("subscribe", ["--uid", "filtered", "--subscriber", "FILTERED",
                                                       "--filter", "00741000=SCHEDULED"]), 201)
            try B2CLI.status(await command("suspend", ["--subscriber", "FILTERED", "--filtered"]), 200)
            try B2CLI.status(await command("create", ["--uid", "2.25.235211"]), 201)
            try B2CLI.status(await command("cancel", ["--uid", "2.25.235211", "--reason", "SECRET-REASON"]), 202)
            let gapWatch = try B2CLI.Running(["web", "ups", "watch"] + options
                + ["--subscriber", "FILTERED", "--duration", "3"])
            try await Task.sleep(for: .milliseconds(600))
            await listener.stop()
            let gaps = try B2CLI.rows(await gapWatch.finish())
            XCTAssertTrue(gaps.contains { $0["gap"] as? Bool == true })
        } catch { await listener.stop(); throw error }
        await listener.stop()
    }

    func test_qido_scopeAndMatchingParameters() throws {
        let command = try WebCommand.Qido.parse(["--url", "https://pacs.example.com/dicom-web", "--level", "instance",
            "--study", "2.25.1", "--series", "2.25.2", "--key", "SOPInstanceUID=2.25.3,2.25.4",
            "--includefield", "PatientName", "--fuzzy", "--limit", "10", "--offset", "20", "--all-pages"])
        let parameters = try command.parameters()
        XCTAssertEqual(try parameters.pathComponents(), ["studies", "2.25.1", "series", "2.25.2", "instances"])
        XCTAssertEqual(parameters.matches.first?.values, ["2.25.3", "2.25.4"])
        XCTAssertEqual(parameters.includeFields, ["PatientName"])
        XCTAssertEqual(parameters.fuzzyMatching, true)
        XCTAssertEqual(parameters.offset, 20)
        XCTAssertTrue(command.allPages)
    }

    func test_serve_independentPythonClientAndDurableStore() async throws {
        let interpreter = try independentInterpreter()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("web-command-\(UUID().uuidString)")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("web-probe-\(UUID().uuidString).dcm")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: output)
        }
        let command = try WebCommand.Serve.parse([directory.path, "--port", "0"])
        let (listener, root) = try await command.start()
        do {
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Scripts/interop/dicomweb_client_probe.py")
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: interpreter)
            process.arguments = [script.path, root.appendingPathComponent("dicom-web").absoluteString, output.path]
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: bytes, as: UTF8.self))
            guard process.terminationStatus == 0 else { throw ExitCode.failure }
            let files = try NetCommand.files([directory.path])
            XCTAssertEqual(files.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), try Data(contentsOf: output))
            var qido = try WebCommand.Qido.parse(["--url", root.appendingPathComponent("dicom-web").absoluteString,
                                                "--all-pages", "--limit", "1"])
            try await qido.run()
            let endpoint = root.appendingPathComponent("dicom-web").absoluteString
            var capabilities = try WebCommand.Capabilities.parse(["--url", endpoint])
            try await capabilities.run()
            let downloads = directory.appendingPathComponent("downloads")
            defer { try? FileManager.default.removeItem(at: downloads) }
            for resource in ["study", "series", "instance", "metadata", "frames", "rendered", "thumbnail"] {
                let destination = downloads.appendingPathComponent(resource)
                var arguments = ["--url", endpoint, "--resource", resource, "--study", "2.25.2351001",
                                 "--output-directory", destination.path]
                if resource != "study" { arguments += ["--series", "2.25.2351002"] }
                if !["study", "series"].contains(resource) { arguments += ["--instance", "2.25.2351003"] }
                if resource == "frames" { arguments += ["--frames", "1"] }
                var wado = try WebCommand.Wado.parse(arguments)
                try await wado.run()
                let saved = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
                XCTAssertEqual(saved.count, 1)
                if ["study", "series", "instance"].contains(resource) {
                    XCTAssertEqual(try Data(contentsOf: saved[0]), try Data(contentsOf: output))
                }
            }
            // The independent probe intentionally preserves pydicom's original bytes, which omit
            // File Meta Information Group Length. The file-streaming CLI requires complete Part 10.
            let client = DicomWebClient(configuration: .init(baseURL: root.appendingPathComponent("dicom-web")))
            let metadata = try await client.retrieveStudyMetadata(studyInstanceUID: "2.25.2351001")
            let restored = try await client.resolveBulkData(in: XCTUnwrap(metadata.first))
            let originalBytes = try Data(contentsOf: XCTUnwrap(files.first))
            let reserializedBytes = try DicomDataSetWriter.part10Data(from: restored.dataSet)
            XCTAssertNotEqual(reserializedBytes, originalBytes)
            try reserializedBytes.write(to: output)
            var stow = try WebCommand.Stow.parse(["--url", root.appendingPathComponent("dicom-web").absoluteString,
                                                "--study", "2.25.2351001", output.path])
            // Fully accepted warnings must exit successfully and remain visible to the operator (issue #2529).
            try await stow.run()
            let warningOutput = try await B2CLI.run(["web", "stow", "--url", endpoint,
                                                    "--study", "2.25.2351001", output.path])
            XCTAssertTrue(warningOutput.contains("2.25.2351003\twarning\t\(0xB000)\t"), warningOutput)
            let conflict = try await client.storeInstances(files: [output], studyInstanceUID: "2.25.2351001")
            XCTAssertEqual(conflict.statusCode, 202)
            XCTAssertEqual(conflict.acceptedInstanceCount, 1)
            XCTAssertEqual(conflict.storeResponse?.instances.count, 1)
            let warning = try XCTUnwrap(conflict.storeResponse?.instances.first)
            XCTAssertEqual(warning.sopInstanceUID, "2.25.2351003")
            XCTAssertNil(warning.failureReason)
            XCTAssertEqual(warning.warningReason, 0xB000)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), originalBytes)
            let bulk = try XCTUnwrap(metadata.first?.bulkData.first)
            var bulkCommand = try WebCommand.Wado.parse(["--url", endpoint, "--resource", "bulkdata",
                "--uri", bulk.uri, "--output-directory", downloads.appendingPathComponent("bulk").path])
            try await bulkCommand.run()
            var mismatched = restored.dataSet
            mismatched.set(.init(tag: 0x0020000D, vr: .UI, value: .strings(["2.25.999"])))
            mismatched.set(.init(tag: 0x00080018, vr: .UI, value: .strings(["2.25.999.1"])))
            let refused = downloads.appendingPathComponent("refused.dcm")
            try DicomDataSetWriter.part10Data(from: mismatched).write(to: refused)
            // For issue #2527, a partial-success exit needs a genuinely accepted instance, not two failures.
            var fresh = restored.dataSet
            fresh.set(.init(tag: 0x00080018, vr: .UI, value: .strings(["2.25.2351004"])))
            let accepted = downloads.appendingPathComponent("accepted.dcm")
            try DicomDataSetWriter.part10Data(from: fresh).write(to: accepted)
            for (paths, expectedCode) in [([output.path, refused.path], Int32(2)),
                                          ([accepted.path, refused.path], Int32(2)), ([refused.path], Int32(1))] {
                var partial = try WebCommand.Stow.parse(["--url", endpoint, "--study", "2.25.2351001"] + paths)
                do { try await partial.run(); XCTFail("Expected partial/failed exit") }
                catch let code as ExitCode { XCTAssertEqual(code.rawValue, expectedCode) }
            }
        } catch {
            await listener.stop()
            throw error
        }
        await listener.stop()
        let (restarted, restartedRoot) = try await command.start()
        do {
            let client = DicomWebClient(configuration: .init(baseURL: restartedRoot.appendingPathComponent("dicom-web")))
            let results = try await client.search(parameters: .init())
            XCTAssertEqual(results.dataSets.count, 1)
        } catch {
            await restarted.stop()
            throw error
        }
        await restarted.stop()
    }
}
