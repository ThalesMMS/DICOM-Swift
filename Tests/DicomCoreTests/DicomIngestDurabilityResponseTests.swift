import Foundation
import XCTest
import DicomTestSupport
@testable import DicomCore

final class DicomIngestDurabilityResponseTests: XCTestCase {
    func test_STOW_conflictingUIDWarnsAndKeepsOriginal() async throws {
        let storage = DicomWebInMemoryStorage()
        let server = DicomWebServer(store: storage)
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://ingest.test/dicom-web")!), transport: server)
        _ = try await client.store(dataSet: ingestDataSet())
        let original = try XCTUnwrap(storage.allInstances().first)
        let conflict = try await client.store(dataSet: ingestDataSet(pixel: 7))
        XCTAssertEqual(conflict.statusCode, 202)
        XCTAssertNil(conflict.storeResponse?.instances.first?.failureReason)
        XCTAssertEqual(conflict.storeResponse?.instances.first?.warningReason, 0xB000)
        XCTAssertEqual(conflict.acceptedInstanceCount, 1)
        XCTAssertEqual(storage.allInstances().first?.part10Data, original.part10Data)
        XCTAssertEqual(storage.conflictingInstances().count, 1)
        XCTAssertEqual(storage.conflictingInstances().first?.part10Data, try ingestBytes(pixel: 7))
        let results = try await storage.store(instances: [original])
        XCTAssertNil(results.first?.warningReason)
        XCTAssertNil(results.first?.failureReason)
        XCTAssertEqual(storage.conflictingInstances().count, 1)
        XCTAssertEqual(storage.count, 1)
    }

    func test_STOW_explicitMemoryDurability_surfacesHTTPWarning() async throws {
        let storage = DicomWebInMemoryStorage(reportsDurability: true)
        let server = DicomWebServer(store: storage)
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://ingest.test/dicom-web")!), transport: server)
        let response = try await client.store(dataSet: ingestDataSet())
        XCTAssertEqual(response.statusCode, 202)
        let original = try XCTUnwrap(storage.allInstances().first)
        let results = try await storage.store(instances: [original])
        XCTAssertEqual(results.first?.durability, .receivedInMemory)
    }

    func test_STOW_declaredLowDurabilityIsWarning() {
        for level in [DicomDurabilityLevel.receivedInMemory, .fileSynced, .publishedAndRegistered, .retentionConfirmed] {
            let result = DicomWebStorageResult(sopClassUID: "1", sopInstanceUID: "2", durability: level)
            XCTAssertEqual(result.effectiveWarningReason, level < .publishedAndRegistered ? 0xB000 : nil)
        }
        XCTAssertNil(DicomWebStorageResult(sopClassUID: "1", sopInstanceUID: "2").effectiveWarningReason)
    }

    #if os(macOS)
    func test_CSTORE_hermeticSCU_waitsForRegistration() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let registrar = IngestHeldRegistrar(base: fixture.registrar)
        let coordinator = DicomIngestCoordinator(root: fixture.root, journal: fixture.journal, registrar: registrar)
        let server = DicomDIMSEServer(configuration: .init(aeTitle: "INGEST", port: 0), ingest: coordinator)
        try server.start()
        let port = try XCTUnwrap(server.listeningPort)
        let request = try DicomStoreRequest(part10Data: ingestBytes())
        let completed = IngestResponseFlag()
        let task = Task.detached {
            let response = try DicomDIMSEServiceSCU(configuration: .init(host: "127.0.0.1", port: port,
                calledAETitle: "INGEST", callingAETitle: "SCU", timeout: 5)).store(request: request)
            completed.set()
            return response
        }
        do {
            try await waitForRegistration(registrar)
            XCTAssertFalse(completed.value)
            await registrar.release()
            let response = try await task.value
            XCTAssertEqual(response.status, 0)
            let records = try await fixture.registrar.records()
            XCTAssertEqual(records.count, 1)
        } catch { await registrar.release(); await server.stop(); throw error }
        await server.stop()
    }

    func test_CSTORE_pynetdicomSCU_waitsForRegistrationAndFailsOnRegistrarFailure() async throws {
        guard let python = PynetdicomPeer.pythonPath else {
            if ProcessInfo.processInfo.environment["DICOM_REQUIRE_PYNETDICOM"] == "1" {
                XCTFail("Required pynetdicom is unavailable"); return
            }
            throw XCTSkip("pynetdicom is unavailable")
        }
        for fail in [false, true] {
            let fixture = try IngestFixture()
            defer { fixture.clean() }
            let registrar = IngestHeldRegistrar(base: fixture.registrar, fail: fail)
            let coordinator = DicomIngestCoordinator(root: fixture.root, journal: fixture.journal, registrar: registrar)
            let server = DicomDIMSEServer(configuration: .init(aeTitle: "INGEST", port: 0), ingest: coordinator)
            try server.start()
            let input = fixture.root.appendingPathComponent("input.part10")
            try ingestBytes().write(to: input)
            let output = fixture.root.appendingPathComponent("response.json")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-c", """
            import json, sys
            import pydicom
            from pynetdicom import AE
            ds = pydicom.dcmread(sys.argv[1])
            ae = AE(ae_title='PYNETSCU')
            ae.add_requested_context(ds.SOPClassUID, ds.file_meta.TransferSyntaxUID)
            assoc = ae.associate('127.0.0.1', int(sys.argv[2]), ae_title='INGEST')
            assert assoc.is_established
            status = assoc.send_c_store(ds)
            with open(sys.argv[3], 'w') as f: json.dump({'status': int(status.Status)}, f)
            assoc.release()
            """, input.path, String(try XCTUnwrap(server.listeningPort)), output.path]
            try process.run()
            do {
                try await waitForRegistration(registrar)
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "Response preceded registration")
                await registrar.release()
                let deadline = Date().addingTimeInterval(10)
                while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
                XCTAssertFalse(process.isRunning)
                if process.isRunning { process.terminate() }
                let response = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Int]
                XCTAssertEqual(response?["status"], fail ? 0xC000 : 0)
                let records = try await fixture.registrar.records()
                XCTAssertEqual(records.count, fail ? 0 : 1)
                if fail {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("2.25.2356001.dcm").path))
                }
            } catch {
                await registrar.release()
                if process.isRunning { process.terminate() }
                await server.stop()
                throw error
            }
            await server.stop()
        }
    }

    func test_CSTORE_diskFullAndUnsatisfiedRetention_returnFailureStatus() async throws {
        for diskFull in [false, true] {
            let fixture = try IngestFixture()
            defer { fixture.clean() }
            // The SCP receives into a file that staging renames rather than writes (issue #2793).
            let fs: any DicomIngestFileSystem = diskFull
                ? DicomFaultInjectingFileSystem(operation: .rename, fault: .fail(ENOSPC)) : DicomLocalIngestFileSystem()
            let coordinator = DicomIngestCoordinator(root: fixture.root, fileSystem: fs,
                journal: fixture.journal, registrar: fixture.registrar)
            let server = DicomDIMSEServer(configuration: .init(aeTitle: "INGEST", port: 0), ingest: coordinator,
                                         durabilityPolicy: .init(required: .retentionConfirmed))
            try server.start()
            let port = try XCTUnwrap(server.listeningPort)
            let request = try DicomStoreRequest(part10Data: ingestBytes())
            do {
                let response = try await Task.detached {
                    try DicomDIMSEServiceSCU(configuration: .init(host: "127.0.0.1", port: port,
                        calledAETitle: "INGEST", callingAETitle: "SCU", timeout: 5)).store(request: request)
                }.value
                XCTFail("Unexpected success status: \(response.status)")
            } catch DicomNetworkError.dimseStatusFailure(let status) {
                XCTAssertEqual(status, diskFull ? 0xA700 : 0xC000)
            } catch { await server.stop(); throw error }
            await server.stop()
        }
    }

    private func waitForRegistration(_ registrar: IngestHeldRegistrar) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !(await registrar.entered) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let entered = await registrar.entered
        XCTAssertTrue(entered, "Registrar was not reached")
        if !entered { throw POSIXError(.ETIMEDOUT) }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #endif
}

private final class IngestResponseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var value: Bool { lock.withLock { done } }
    func set() { lock.withLock { done = true } }
}

private actor IngestHeldRegistrar: DicomIngestRegistrar {
    nonisolated let gate = DicomIngestGate()
    nonisolated let durability = DicomDurabilityLevel.publishedAndRegistered
    let base: any DicomIngestRegistrar
    let fail: Bool
    var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(base: any DicomIngestRegistrar, fail: Bool = false) { self.base = base; self.fail = fail }
    func classify(sopInstanceUID: String, contentSHA256: String) async throws -> DicomIngestClassification {
        try await base.classify(sopInstanceUID: sopInstanceUID, contentSHA256: contentSHA256)
    }
    func records() async throws -> [DicomIngestRecord] { try await base.records() }
    func register(_ record: DicomIngestRecord) async throws -> DicomIngestClassification {
        entered = true
        await withCheckedContinuation { waiter = $0 }
        if fail { throw POSIXError(.EIO) }
        return try await base.register(record)
    }
    func release() { waiter?.resume(); waiter = nil }
}

extension DicomIngestDurabilityResponseTests {
    func test_ingestStorageUsesServerResourceGovernor() throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let ingest = DicomIngestCoordinator(root: fixture.root, journal: fixture.journal, registrar: fixture.registrar)
        let config = DicomDIMSEServerConfiguration(aeTitle: "INGEST", port: 0)
        let governor = DicomStorageSCPResourceGovernor(configuration: config.storage)
        let server = DicomDIMSEServer(configuration: config, ingest: ingest, resourceGovernor: governor)
        XCTAssertTrue(server.storageService?.resourceGovernor === governor)
        let existing = try XCTUnwrap(server.storageService)
        let replacement = DicomStorageSCPResourceGovernor(configuration: config.storage)
        let configured = DicomDIMSEServer(configuration: config, storage: existing, ingest: ingest, resourceGovernor: replacement)
        XCTAssertTrue(configured.storageService?.resourceGovernor === replacement)
    }
}
