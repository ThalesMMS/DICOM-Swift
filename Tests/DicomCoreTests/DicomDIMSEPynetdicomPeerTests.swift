import Foundation
import XCTest
import CryptoKit
import DicomTestSupport
@testable import DicomCore

#if os(macOS)
final class DicomDIMSEPynetdicomPeerTests: XCTestCase {
    private func service(_ peer: PynetdicomPeer, window: UInt16? = nil) -> DicomDIMSEServiceSCU {
        DicomDIMSEServiceSCU(configuration: .init(host: "127.0.0.1", port: peer.port,
            calledAETitle: "PYNETDICOM", callingAETitle: "ISIS", timeout: 3,
            asynchronousOperationsWindow: window.map { .init(maximumInvoked: $0) }))
    }

    private func identifier() -> DicomDataSet {
        DicomDataSet(elements: [
            DicomDataElement(tag: 0x00080052, vr: .CS, value: .strings(["STUDY"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.2350"]))
        ])
    }

    private func request(_ index: Int) throws -> DicomStoreRequest {
        let uid = "2.25.2350\(index)"
        let ds = DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI,
                         value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([uid])),
            DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings(["SYNTHETIC-A1"]))
        ])
        return try DicomStoreRequest(sopClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
            sopInstanceUID: uid, transferSyntax: .explicitVRLittleEndian,
            dataSetData: DicomDataSetWriter.dataSetData(from: ds, transferSyntax: .explicitVRLittleEndian))
    }

    func test_echo_independentPeerSucceeds() throws {
        let peer = try PynetdicomPeer()
        XCTAssertEqual(try service(peer).verify().status, 0)
        let result = try peer.stop()
        XCTAssertEqual(result["pynetdicom"] as? String, "3.0.4")
    }

    func test_storeBatch_proposesFourAndHonoursNegotiatedOne() throws {
        let peer = try PynetdicomPeer(configuration: ["store_delay": 0.03])
        let results = try service(peer, window: 4).store(requests: (1...4).map(request))
        for result in results { XCTAssertEqual(try result.get().status, 0) }
        let evidence = try peer.stop()
        XCTAssertEqual((evidence["stores"] as? [[String: Any]])?.count, 4)
        XCTAssertEqual(evidence["async_proposals"] as? [[Int]], [[4, 1]])
        XCTAssertTrue((evidence["rq_items"] as? [Int] ?? []).contains(0x53))
        XCTAssertEqual(evidence["max_outstanding"] as? Int, 1)
    }

    func test_storeFailure_batchContinues() throws {
        let peer = try PynetdicomPeer(configuration: ["fail_store_uid": "2.25.23502"])
        let results = try service(peer).store(requests: (1...3).map(request))
        XCTAssertEqual(try results[0].get().status, 0)
        XCTAssertThrowsError(try results[1].get())
        XCTAssertEqual(try results[2].get().status, 0)
        XCTAssertEqual((try peer.stop()["stores"] as? [[String: Any]])?.count, 3)
    }

    func test_find_pendingResponsesAreCollected() throws {
        let peer = try PynetdicomPeer(configuration: ["pending_count": 3])
        let result = try service(peer).find(identifier: identifier())
        XCTAssertEqual(result.operation.status, 0)
        XCTAssertEqual(result.matches.count, 3)
        _ = try peer.stop()
    }

    func test_get_affirmativeStorageRoleDeliversBeforeAcknowledgement() throws {
        let peer = try PynetdicomPeer()
        var received = 0
        let result = try service(peer).get(identifier: identifier(), onInstance: { instance in
            XCTAssertFalse(instance.data.isEmpty)
            received += 1
        })
        XCTAssertEqual(received, 1)
        XCTAssertEqual(result.completedSuboperations, 1)
        _ = try peer.stop()
    }
    func test_findCancel_observesPeerFinalFE00() throws {
        let peer = try PynetdicomPeer(configuration: ["pending_count": 20, "pending_delay": 0.03])
        let handle = DicomDIMSEOperationHandle()
        let scu = DicomDIMSEServiceSCU(configuration: .init(host: "127.0.0.1", port: peer.port,
            calledAETitle: "PYNETDICOM", callingAETitle: "ISIS", timeout: 3, cancelTimeout: 1), operationHandle: handle)
        XCTAssertThrowsError(try scu.find(identifier: identifier(), progress: { event in
            if case .pending = event { handle.cancel() }
        })) { error in
            XCTAssertEqual(error as? DicomNetworkError, .operationCancelled("C-FIND"))
        }
        let evidence = try peer.stop()
        XCTAssertEqual(evidence["cancelled"] as? Bool, true)
        let responses = try XCTUnwrap(evidence["responses"] as? [[String: Int]])
        XCTAssertEqual(responses.last?["status"], 0xFE00)
    }

    func test_mwl_andMPPS_succeed() throws {
        let peer = try PynetdicomPeer()
        let scu = service(peer)
        XCTAssertEqual(try scu.findModalityWorklist(query: .init()).items.count, 3)
        XCTAssertEqual(try scu.createMPPS(.init(sopInstanceUID: "2.25.23509")).status, 0)
        XCTAssertEqual(try scu.updateMPPS(.init(sopInstanceUID: "2.25.23509", status: .completed)).status, 0)
        _ = try peer.stop()
    }

    func test_storageCommitmentRequest_peerAcceptsAction() throws {
        let peer = try PynetdicomPeer()
        XCTAssertEqual(try service(peer).requestStorageCommitment(transactionUID: "2.25.235099",
            references: [.init(sopClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                               sopInstanceUID: "2.25.23501", status: .committed)]).status, 0)
        _ = try peer.stop()
    }

    func test_wrongResponseID_isDiagnostic() throws {
        let peer = try PynetdicomPeer(configuration: ["wrong_response_id": 77])
        XCTAssertThrowsError(try service(peer).verify()) { error in
            guard case DicomNetworkError.malformedCommandSet(let reason) = error else {
                return XCTFail("Expected correlation diagnostic, got \(error)")
            }
            XCTAssertTrue(reason.contains("Message ID"))
        }
        _ = try peer.stop()
    }

    func test_untrustedTLSCertificate_handshakeFails() throws {
        let peer = try PynetdicomPeer(configuration: ["generate_tls": true])
        let scu = DicomDIMSEServiceSCU(configuration: .init(host: "127.0.0.1", port: peer.port,
            calledAETitle: "PYNETDICOM", callingAETitle: "ISIS", timeout: 2,
            tls: .init(mode: .enabled, serverName: "localhost")))
        XCTAssertThrowsError(try scu.verify())
        _ = try peer.stop()
    }

    func test_extendedAndIdentityNegotiation_independentPeerAnswers() throws {
        let peer = try PynetdicomPeer()
        let transport = DicomTCPAssociationTransport(host: "127.0.0.1", port: peer.port, timeout: 3)
        try transport.open()
        defer { transport.close() }
        let uid = DicomNetworkUID.studyRootQueryRetrieveFind
        let request = DicomAssociationRequest(calledAETitle: "PYNETDICOM", callingAETitle: "ISIS",
            presentationContexts: [.init(id: 1, abstractSyntaxUID: uid, transferSyntaxes: [.explicitVRLittleEndian])],
            userIdentity: .init(type: .jwt, primaryField: Data("operator".utf8), positiveResponseRequested: true),
            extendedNegotiations: [.init(sopClassUID: uid, relationalQueries: true, fuzzyPersonNameMatching: true)])
        let association = try DicomAssociationSCU(request: request).open(using: transport)
        XCTAssertEqual(association.accept.userIdentityServerResponse?.data, Data("accepted".utf8))
        XCTAssertEqual(association.accept.extendedNegotiations.first?.serviceClassApplicationInformation, Data([1, 0, 0, 0, 0]))
        try transport.writePDU(DicomPDUCodec.encode(.releaseRequest))
        XCTAssertEqual(try DicomPDUCodec.decode(transport.readPDU()), .releaseResponse)
        _ = try peer.stop()
    }

    func test_rejectedIdentity_peerRejectsAssociation() throws {
        let peer = try PynetdicomPeer()
        let transport = DicomTCPAssociationTransport(host: "127.0.0.1", port: peer.port, timeout: 3)
        try transport.open()
        defer { transport.close() }
        let request = DicomAssociationRequest(calledAETitle: "PYNETDICOM", callingAETitle: "ISIS",
            presentationContexts: [.init(id: 1, abstractSyntaxUID: DicomNetworkUID.verificationSOPClass,
                                        transferSyntaxes: [.explicitVRLittleEndian])],
            userIdentity: .usernameAndPasscode("operator", passcode: "wrong"))
        XCTAssertThrowsError(try DicomAssociationSCU(request: request).open(using: transport)) { error in
            guard case DicomNetworkError.associationRejected = error else {
                return XCTFail("Expected rejection, got \(error)")
            }
        }
        _ = try peer.stop()
    }

    func test_storeCompressedAsReceived_preservesEncodedPayload() throws {
        let peer = try PynetdicomPeer(configuration: ["generate_rle": true,
            "syntaxes": ["1.2.840.10008.1.2.5", "1.2.840.10008.1.2.1"]])
        let object = try DicomStoreRequest(part10FileAt: peer.fixtureURL)
        XCTAssertEqual(try service(peer).store(request: object).status, 0)
        let evidence = try peer.stop()
        let stored = try XCTUnwrap((evidence["stores"] as? [[String: Any]])?.first)
        XCTAssertEqual(stored["syntax"] as? String, "1.2.840.10008.1.2.5")
        let digest = SHA256.hash(data: object.dataSetData).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(stored["sha256"] as? String, digest)
    }

    func test_refusedSyntax_batchContinuesWithAcceptedObject() throws {
        let peer = try PynetdicomPeer(configuration: ["generate_rle": true,
            "syntaxes": ["1.2.840.10008.1.2.1"]])
        let compressed = try DicomStoreRequest(part10FileAt: peer.fixtureURL)
        let results = try service(peer).store(requests: [compressed, request(1)])
        XCTAssertThrowsError(try results[0].get())
        XCTAssertEqual(try results[1].get().status, 0)
        XCTAssertEqual((try peer.stop()["stores"] as? [[String: Any]])?.count, 1)
    }

    func test_rejectedContext_isReported() throws {
        let peer = try PynetdicomPeer(configuration: ["services": [DicomNetworkUID.studyRootQueryRetrieveFind]])
        XCTAssertThrowsError(try service(peer).verify())
        _ = try peer.stop()
    }

    func test_commandAndDatasetFragmentation_peerReassembles() throws {
        let peer = try PynetdicomPeer(configuration: ["max_pdu": 1024])
        let transport = DicomTCPAssociationTransport(host: "127.0.0.1", port: peer.port, timeout: 3)
        try transport.open()
        defer { transport.close() }
        let scu = service(peer)
        let object = try request(1)
        let association = try scu.openAssociation(for: .store, abstractSyntaxUIDs: [object.sopClassUID],
                                                  using: transport, progress: nil)
        let command = DicomDIMSECommandSet(affectedSOPClassUID: object.sopClassUID,
            commandField: DicomDIMSECommandField.cStoreRQ, messageID: 1,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            errorComment: String(repeating: "A", count: 2048), priority: 0,
            affectedSOPInstanceUID: object.sopInstanceUID)
        try scu.sendCommand(command, presentationContextID: 1, association: association, transport: transport)
        let padding = DicomDataSet(elements: [DicomDataElement(tag: 0x00104000, vr: .LT,
                                                              value: .strings([String(repeating: "X", count: 5000)]))])
        let payload = object.dataSetData + (try DicomDataSetWriter.dataSetData(from: padding, transferSyntax: .explicitVRLittleEndian))
        try scu.sendDataSetData(payload, presentationContextID: 1, association: association, transport: transport)
        let response = try scu.readCommand(using: transport, association: association, reader: DicomDIMSEMessageReader())
        XCTAssertEqual(response.status, 0)
        try scu.release(operation: .store, using: transport, progress: nil)
        XCTAssertEqual((try peer.stop()["stores"] as? [[String: Any]])?.count, 1)
    }

    func test_move_deliversToOwnListener() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("isis-a1-move-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try DicomFileStorageCache(directoryURL: directory)
        let server = try DicomStorageSCPServer(service: .init(configuration: .init(aeTitle: "ISIS", port: 0), storage: cache))
        try server.start()
        let peer = try PynetdicomPeer(configuration: ["move_port": try XCTUnwrap(server.listeningPort)])
        let result = try service(peer).move(identifier: identifier(), moveDestinationAETitle: "ISIS")
        XCTAssertEqual(result.completedSuboperations, 1)
        let storedFiles = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles
        ).filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
        XCTAssertEqual(storedFiles.count, 1)
        _ = try peer.stop()
        await server.stop()
    }

    func test_commitmentResult_listenerPersistsBeforeReply() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("isis-a1-commit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try DicomFileStorageCache(directoryURL: directory)
        let received = expectation(description: "Persisted commitment report")
        let listener = DicomStorageSCPService(configuration: .init(aeTitle: "ISIS", port: 0), storage: cache,
            commitmentResultHandler: { report in
                XCTAssertEqual(report.transactionUID, "2.25.235099")
                XCTAssertEqual(report.references.count, 2)
                XCTAssertEqual(report.references.last?.failureReasonCode, 0x0112)
                let data = try JSONEncoder().encode(report)
                try data.write(to: directory.appendingPathComponent("commitment.json"), options: .atomic)
                received.fulfill()
            })
        let server = try DicomStorageSCPServer(service: listener)
        try server.start()
        let peer = try PynetdicomPeer(configuration: ["commitment_port": try XCTUnwrap(server.listeningPort),
                                                     "fail_commitment_uid": "2.25.23502"])
        XCTAssertEqual(try service(peer).requestStorageCommitment(transactionUID: "2.25.235099",
            references: [.init(sopClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                               sopInstanceUID: "2.25.23501"),
                         .init(sopClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                               sopInstanceUID: "2.25.23502")]).status, 0)
        await fulfillment(of: [received], timeout: 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("commitment.json").path))
        let evidence = try peer.stop()
        XCTAssertEqual(evidence["commitment_status"] as? Int, 0)
        await server.stop()
    }

    func test_getPersistenceFailure_peerCountsFailedSuboperation() throws {
        let peer = try PynetdicomPeer()
        XCTAssertThrowsError(try service(peer).get(identifier: identifier(), onInstance: { _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })) { error in
            XCTAssertEqual(error as? DicomNetworkError, .dimseStatusFailure(0xA702))
        }
        let responses = try XCTUnwrap(try peer.stop()["responses"] as? [[String: Int]])
        let final = try XCTUnwrap(responses.last { $0["field"] == Int(DicomDIMSECommandField.cGetRSP) })
        XCTAssertEqual(final["failed"], 1)
        XCTAssertEqual(final["completed"], 0)
    }

    func test_dimseResponseTimeout_usesResponseOverride() throws {
        let peer = try PynetdicomPeer(configuration: ["echo_delay": 0.5])
        let scu = DicomDIMSEServiceSCU(configuration: .init(host: "127.0.0.1", port: peer.port,
            calledAETitle: "PYNETDICOM", callingAETitle: "ISIS", timeout: 3,
            dimseResponseTimeout: 0.05, releaseTimeout: 0.05))
        let started = Date()
        XCTAssertThrowsError(try scu.verify()) { error in
            guard case DicomNetworkError.networkTimeout = error else { return XCTFail("Expected response timeout") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        _ = try peer.stop()
    }

    /// Issue #2774: pooled associations end with A-RELEASE — a finished C-MOVE right away, an idle C-FIND one
    /// once the pool's idle timeout passes — rather than a dropped connection.
    func test_pooledAssociations_endWithARelease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("isis-2774-move-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try DicomStorageSCPServer(service: .init(configuration: .init(aeTitle: "ISIS", port: 0),
                                                              storage: try DicomFileStorageCache(directoryURL: directory)))
        try server.start()
        let peer = try PynetdicomPeer(configuration: ["move_port": try XCTUnwrap(server.listeningPort)])
        let pool = DicomDIMSEAssociationPool(policy: .init(maximumIdleServicesPerKey: 1, idleTimeout: 0.3))
        let configuration = DicomDIMSEConnectionConfiguration(host: "127.0.0.1", port: peer.port,
            calledAETitle: "PYNETDICOM", callingAETitle: "ISIS", timeout: 3)

        XCTAssertEqual(try pool.service(for: configuration).move(identifier: identifier(),
                                                                 moveDestinationAETitle: "ISIS").completedSuboperations, 1)
        XCTAssertEqual(try pool.service(for: configuration).find(identifier: identifier()).operation.status, 0)
        XCTAssertEqual(try pool.service(for: configuration).find(identifier: identifier()).operation.status, 0)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let evidence = try peer.stop()
        XCTAssertEqual(evidence["release_requests"] as? Int, 2, "the C-MOVE and the idle C-FIND association")
        XCTAssertNil(evidence["abort_received"])
        await server.stop()
    }

    func test_cancelTimeout_abortsPeerThatIgnoresCancel() throws {
        let peer = try PynetdicomPeer(configuration: ["pending_count": 100, "ignore_cancel": true])
        let handle = DicomDIMSEOperationHandle()
        let scu = DicomDIMSEServiceSCU(configuration: .init(host: "127.0.0.1", port: peer.port,
            calledAETitle: "PYNETDICOM", callingAETitle: "ISIS", timeout: 3, cancelTimeout: 0.1), operationHandle: handle)
        let started = Date()
        XCTAssertThrowsError(try scu.find(identifier: identifier(), progress: { event in
            if case .pending = event { handle.cancel() }
        }))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(try peer.stop()["abort_received"] as? Bool, true)
    }

}
#endif
