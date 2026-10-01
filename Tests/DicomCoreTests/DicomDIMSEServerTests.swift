import Foundation
import XCTest
@testable import DicomCore

func a2String(_ tag: Int, _ vr: DicomVR, _ value: String) -> DicomDataElement {
    DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
}

struct A2QueryProvider: DicomQueryProviding {
    var count = 3
    var delay: UInt64 = 0
    var failure: UInt16?
    var paddingLength = 0
    var unsupportedOptionalKeys: Set<Int> = []
    func matches(for request: DicomQueryRequest) -> AsyncThrowingStream<DicomDataSet, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let failure { throw DicomDIMSEProviderError(status: failure) }
                    for index in 0..<count {
                        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                        try Task.checkCancellation()
                        var row = DicomDataSet(elements: [
                            a2String(0x00080052, .CS, request.level?.rawValue ?? "STUDY"),
                            a2String(0x00100010, .PN, "SYNTHETIC^A2"),
                            a2String(0x00100020, .LO, "A2"),
                            a2String(0x0020000D, .UI, "2.25.2350\(index)"),
                            a2String(0x00080020, .DA, "20260911"),
                            a2String(0x00400001, .AE, "ISIS")
                        ])
                        row.set(DicomDataElement(tag: 0x00400100, vr: .SQ, value: .sequence([
                            DicomSequenceItem(dataSet: DicomDataSet(elements: [
                                a2String(0x00400001, .AE, "ISIS"), a2String(0x00400002, .DA, "20260911")
                            ]))
                        ])))
                        if request.model == .modalityWorklist { row.remove(0x00080052) }
                        if paddingLength > 0 {
                            row.set(a2String(0x00104000, .LT, String(repeating: "A", count: paddingLength)))
                        }
                        if try DicomQueryMatcher(dateTimeMatching: request.dateTimeMatching)
                            .matches(row, identifier: request.identifier) { continuation.yield(row) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct A2RetrieveProvider: DicomRetrieveProviding {
    var count = 2
    func instances(for request: DicomRetrieveRequest) -> AsyncThrowingStream<DicomRetrievableInstance, Error> {
        AsyncThrowingStream { continuation in
            for index in 0..<count {
                let uid = "2.25.235000\(index + 1)"
                continuation.yield(DicomRetrievableInstance(
                    sopClassUID: DicomStorageSOPClassUIDs.secondaryCaptureImageStorage,
                    sopInstanceUID: uid, transferSyntaxes: [.explicitVRLittleEndian, .implicitVRLittleEndian]) { syntax in
                        try Task.checkCancellation()
                        return try DicomDataSetWriter.dataSetData(from: DicomDataSet(elements: [
                            a2String(0x00080016, .UI, DicomStorageSOPClassUIDs.secondaryCaptureImageStorage),
                            a2String(0x00080018, .UI, uid), a2String(0x00100010, .PN, "SYNTHETIC^A2")
                        ]), transferSyntax: syntax)
                    })
            }
            continuation.finish()
        }
    }
}

actor A2MPPSProvider: DicomModalityPerformedProcedureStepProviding {
    var objects: [String: DicomDataSet] = [:]
    private func update(_ uid: String, mutation: DicomModalityPerformedProcedureStepProvider.Mutation) throws -> DicomDataSet {
        let result = try mutation(objects[uid])
        objects[uid] = result
        return result
    }
    private var provider: DicomModalityPerformedProcedureStepProvider {
        DicomModalityPerformedProcedureStepProvider { [self] uid, mutation in
            try await update(uid, mutation: mutation)
        }
    }
    func create(sopInstanceUID: String, attributes: DicomDataSet) async throws -> DicomPerformedProcedureStepState {
        try await provider.create(sopInstanceUID: sopInstanceUID, attributes: attributes)
    }
    func set(sopInstanceUID: String, attributes: DicomDataSet) async throws -> DicomPerformedProcedureStepState {
        try await provider.set(sopInstanceUID: sopInstanceUID, attributes: attributes)
    }
}

actor A2DestinationResolver: DicomMoveDestinationResolving {
    var destinations: [String: DicomMoveDestination] = [:]
    func set(_ ae: String, port: UInt16) { destinations[ae] = DicomMoveDestination(host: "127.0.0.1", port: port) }
    func resolve(aeTitle: String) -> DicomMoveDestination? { destinations[aeTitle] }
}

struct A2CommitmentProvider: DicomStorageCommitmentProviding {
    var failAll = false
    var delay: UInt64 = 0
    func verify(transactionUID: String, references: [DicomStorageCommitmentReference]) async -> DicomStorageCommitmentResult {
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return DicomStorageCommitmentReport(transactionUID: transactionUID, status: failAll ? .failed : .committed,
            references: references.map { reference in
                var reference = reference
                if failAll { reference.status = .failed; reference.failureReasonCode = 0x0112 }
                return reference
            })
    }
}

final class DicomDIMSEServerTests: XCTestCase {
    func test_receivedCommitmentReport_handlerFailureReturnsFailure() throws {
        let uid = DicomNetworkUID.storageCommitmentPushModelSOPClass
        let report = DicomStorageCommitmentReport(transactionUID: "2.25.235090", status: .committed,
            references: [.init(sopClassUID: DicomStorageSOPClassUIDs.secondaryCaptureImageStorage, sopInstanceUID: "2.25.1")])
        let transport = try A2Transport(uid: uid, commands: [(.init(affectedSOPClassUID: uid,
            commandField: DicomDIMSECommandField.nEventReportRQ, messageID: 1,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            affectedSOPInstanceUID: DicomNetworkUID.storageCommitmentPushModelSOPInstance, eventTypeID: 1),
            DicomStorageCommitmentTracker.eventReportDataSet(for: report))])
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), commitmentResultHandler: { _ in
            throw DicomDIMSEProviderError(status: 0x0110)
        }).handleAssociation(using: transport)
        XCTAssertEqual(try transport.commands().last?.status, 0x0110)
    }

    func test_echo_recordsOperationAudit() throws {
        let uid = DicomNetworkUID.verificationSOPClass
        let transport = try A2Transport(uid: uid, commands: [(.init(affectedSOPClassUID: uid,
            commandField: DicomDIMSECommandField.cEchoRQ, messageID: 1), nil)])
        let audit = DicomInMemoryNetworkAuditLog()
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), auditLogger: audit).handleAssociation(using: transport)
        XCTAssertEqual(try transport.commands().last?.status, 0)
        XCTAssertEqual(audit.events.map(\.outcome), [.started, .succeeded])
    }

    func test_store_delegatesToExistingPersistencePath() throws {
        let uid = DicomStorageSOPClassUIDs.secondaryCaptureImageStorage
        let identifier = DicomDataSet(elements: [a2String(0x00080016, .UI, uid), a2String(0x00080018, .UI, "2.25.1")])
        let transport = try A2Transport(uid: uid, commands: [(.init(affectedSOPClassUID: uid,
            commandField: DicomDIMSECommandField.cStoreRQ, messageID: 1,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet, affectedSOPInstanceUID: "2.25.1"), identifier)])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("a2-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try DicomFileStorageCache(directoryURL: directory)
        let config = DicomDIMSEServerConfiguration(aeTitle: "ISIS")
        try DicomDIMSEServer(configuration: config,
            storage: DicomStorageSCPService(configuration: config.storage, storage: storage)).handleAssociation(using: transport)
        XCTAssertEqual(try transport.commands().last?.status, 0)
        let storedFiles = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles
        ).filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
        XCTAssertEqual(storedFiles.count, 1)
    }

    func test_commitment_invalidActionIsRefused() throws {
        let uid = DicomNetworkUID.storageCommitmentPushModelSOPClass
        let transport = try A2Transport(uid: uid, commands: [(.init(requestedSOPClassUID: uid,
            commandField: DicomDIMSECommandField.nActionRQ, messageID: 1,
            requestedSOPInstanceUID: DicomNetworkUID.storageCommitmentPushModelSOPInstance, actionTypeID: 2), nil)])
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), commitment: A2CommitmentProvider())
            .handleAssociation(using: transport)
        XCTAssertEqual(try transport.commands().last?.status, 0x0106)
    }

    func test_mwl_unsupportedOptionalKeyUsesFF01() throws {
        let uid = DicomNetworkUID.modalityWorklistInformationModelFind
        let transport = try A2Transport(uid: uid, commands: [(.init(affectedSOPClassUID: uid,
            commandField: DicomDIMSECommandField.cFindRQ, messageID: 1,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet),
            DicomDataSet(elements: [a2String(0x00101000, .LO, "")]))])
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"),
            worklist: A2QueryProvider(count: 1, unsupportedOptionalKeys: [0x00101000])).handleAssociation(using: transport)
        XCTAssertEqual(try transport.commands().compactMap(\.status), [0xFF01, 0])
    }

    func test_find_streamsPendingAndFinalWithFragmentation() throws {
        let uid = DicomNetworkUID.studyRootQueryRetrieveFind
        let transport = try A2Transport(uid: uid, commands: [(.init(affectedSOPClassUID: uid,
            commandField: DicomDIMSECommandField.cFindRQ, messageID: 1,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet),
            DicomDataSet(elements: [a2String(0x00080052, .CS, "STUDY")]))])
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), query: A2QueryProvider(paddingLength: 4096))
            .handleAssociation(using: transport)
        XCTAssertEqual(try transport.commands().compactMap(\.status), [0xFF00, 0xFF00, 0xFF00, 0])
    }

    func test_store_sharedOperationLimitRepliesAndKeepsAssociationUsable() throws {
        var configuration = DicomDIMSEServerConfiguration(aeTitle: "ISIS")
        configuration.maximumOutstandingOperations = 1
        let governor = DicomStorageSCPResourceGovernor(configuration: configuration.storage)
        XCTAssertTrue(governor.beginOperation(limit: 1))
        let uid = DicomStorageSOPClassUIDs.secondaryCaptureImageStorage
        let commands: [(DicomDIMSECommandSet, DicomDataSet?)] = [UInt16(1), 2].map { id in
            let instance = "2.25.\(id)"
            return (.init(affectedSOPClassUID: uid, commandField: DicomDIMSECommandField.cStoreRQ,
                          messageID: id, commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
                          affectedSOPInstanceUID: instance),
                    DicomDataSet(elements: [a2String(0x00080016, .UI, uid), a2String(0x00080018, .UI, instance)]))
        }
        let transport = try A2Transport(uid: uid, commands: commands, onWrite: { data in
            guard case .pData(let pdvs) = try? DicomPDUCodec.decode(data),
                  let pdv = pdvs.first, pdv.isCommand,
                  let response = try? DicomDIMSECommandSet.decode(pdv.data),
                  response.status == 0xA700 else { return }
            governor.endOperation()
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("a2-admission-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try DicomFileStorageCache(directoryURL: directory)
        try DicomDIMSEServer(configuration: configuration,
            storage: DicomStorageSCPService(configuration: configuration.storage, storage: storage),
            resourceGovernor: governor).handleAssociation(using: transport)
        let responses = try transport.commands()
        XCTAssertEqual(responses.map(\.commandField), Array(repeating: DicomDIMSECommandField.cStoreRSP, count: 2))
        XCTAssertEqual(responses.compactMap(\.messageIDBeingRespondedTo), [1, 2])
        XCTAssertEqual(responses.compactMap(\.status), [0xA700, 0])
        let storedFiles = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles
        ).filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
        XCTAssertEqual(storedFiles.count, 1)
        let storedFile = try XCTUnwrap(storedFiles.first)
        XCTAssertEqual(try DicomPart10FileMetaParser.parse(Data(contentsOf: storedFile)).mediaStorageSOPInstanceUID, "2.25.2")
    }

    func test_store_malformedIDsAndNegotiatedWindowRemainProtocolErrors() throws {
        let configuration = DicomDIMSEServerConfiguration(aeTitle: "ISIS")
        let request = DicomAssociationRequest(calledAETitle: "ISIS", callingAETitle: "PEER", presentationContexts: [])
        let accept = DicomAssociationAccept(calledAETitle: "ISIS", callingAETitle: "PEER", presentationContexts: [])
        let transport = try A2Transport(uid: DicomNetworkUID.verificationSOPClass, commands: [])
        let session = DicomDIMSEServerSession(transport: transport,
            association: DicomAssociation(request: request, accept: accept), timeout: 1,
            governor: DicomStorageSCPResourceGovernor(configuration: configuration.storage),
            maximumOutstanding: 1, auditLogger: nil)
        try session.begin(command: .init(commandField: DicomDIMSECommandField.cFindRQ, messageID: 1), contextID: 1) {
            try? await Task.sleep(for: .seconds(60))
        }
        defer { session.cancelAll(); session.waitForOperations() }
        for id: UInt16? in [nil, 1, 2] {
            XCTAssertThrowsError(try session.performSynchronousOperation(
                .init(commandField: DicomDIMSECommandField.cStoreRQ, messageID: id)
            ) { XCTFail("Malformed requests must not reach storage") }) { error in
                guard case DicomNetworkError.malformedCommandSet = error else {
                    return XCTFail("Expected a protocol error, got \(error)")
                }
            }
        }
    }

    func test_find_providerFailureRetainsStatusClass() throws {
        for status: UInt16 in [0xA700, 0xA900, 0xC001] {
            let uid = DicomNetworkUID.patientRootQueryRetrieveFind
            let transport = try A2Transport(uid: uid, commands: [(.init(affectedSOPClassUID: uid,
                commandField: DicomDIMSECommandField.cFindRQ, messageID: 1,
                commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet),
                DicomDataSet(elements: [a2String(0x00080052, .CS, "PATIENT")]))])
            try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), query: A2QueryProvider(failure: status))
                .handleAssociation(using: transport)
            XCTAssertEqual(try transport.commands().compactMap(\.status), [status])
        }
    }

    func test_find_sharedOperationLimitRepliesAndKeepsAssociationUsable() throws {
        var configuration = DicomDIMSEServerConfiguration(aeTitle: "ISIS")
        configuration.maximumOutstandingOperations = 1
        let governor = DicomStorageSCPResourceGovernor(configuration: configuration.storage)
        XCTAssertTrue(governor.beginOperation(limit: 1))
        let uid = DicomNetworkUID.studyRootQueryRetrieveFind
        let commands: [(DicomDIMSECommandSet, DicomDataSet?)] = [UInt16(1), 2].map { id in
            (.init(affectedSOPClassUID: uid, commandField: DicomDIMSECommandField.cFindRQ,
                   messageID: id, commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet),
             DicomDataSet(elements: [a2String(0x00080052, .CS, "STUDY")]))
        }
        let transport = try A2Transport(uid: uid, commands: commands, onWrite: { data in
            guard case .pData(let pdvs) = try? DicomPDUCodec.decode(data),
                  let pdv = pdvs.first, pdv.isCommand,
                  let response = try? DicomDIMSECommandSet.decode(pdv.data),
                  response.status == 0xA700 else { return }
            governor.endOperation()
        })
        try DicomDIMSEServer(configuration: configuration, query: A2QueryProvider(count: 0),
                             resourceGovernor: governor).handleAssociation(using: transport)
        let responses = try transport.commands()
        XCTAssertEqual(responses.compactMap(\.messageIDBeingRespondedTo), [1, 2])
        XCTAssertEqual(responses.compactMap(\.status), [0xA700, 0])
    }

    func test_findCancel_correlatesMessageID() throws {
        let uid = DicomNetworkUID.studyRootQueryRetrieveFind
        let transport = try A2Transport(uid: uid, commands: [(.init(affectedSOPClassUID: uid,
            commandField: DicomDIMSECommandField.cFindRQ, messageID: 7,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet),
            DicomDataSet(elements: [a2String(0x00080052, .CS, "STUDY")])),
            (.init(commandField: DicomDIMSECommandField.cCancelRQ, messageIDBeingRespondedTo: 7), nil)])
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), query: A2QueryProvider(delay: 100_000_000))
            .handleAssociation(using: transport)
        XCTAssertEqual(try transport.commands().compactMap(\.status), [0xFE00])
    }

    func test_get_isolatesFailureAndPreservesCounters() throws {
        let uid = DicomNetworkUID.studyRootQueryRetrieveGet
        let transport = try A2Transport(uid: uid, commands: [(.init(affectedSOPClassUID: uid,
            commandField: DicomDIMSECommandField.cGetRQ, messageID: 1,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet),
            DicomDataSet(elements: [a2String(0x00080052, .CS, "STUDY"), a2String(0x0020000D, .UI, "2.25.2350")]))])
        // No returned-storage SCP role was proposed: every object is counted as failed.
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), retrieve: A2RetrieveProvider())
            .handleAssociation(using: transport)
        let final = try XCTUnwrap(transport.commands().last)
        XCTAssertEqual(final.status, 0xB000)
        XCTAssertEqual(final.failedSuboperations, 2)
        XCTAssertEqual(final.completedSuboperations, 0)
        XCTAssertNil(final.remainingSuboperations)
    }

    func test_move_unknownDestinationUsesA801() throws {
        let uid = DicomNetworkUID.studyRootQueryRetrieveMove
        let transport = try A2Transport(uid: uid, commands: [(.init(affectedSOPClassUID: uid,
            commandField: DicomDIMSECommandField.cMoveRQ, messageID: 1,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet, moveDestination: "UNKNOWN"),
            DicomDataSet(elements: [a2String(0x00080052, .CS, "STUDY")]))])
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), retrieve: A2RetrieveProvider(),
            moveDestinations: A2DestinationResolver()).handleAssociation(using: transport)
        XCTAssertEqual(try transport.commands().last?.status, 0xA801)
    }

    func test_mpps_invalidCreateUses0106() throws {
        let uid = DicomNetworkUID.modalityPerformedProcedureStepSOPClass
        let transport = try A2Transport(uid: uid, commands: [(.init(affectedSOPClassUID: uid,
            commandField: DicomDIMSECommandField.nCreateRQ, messageID: 1,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet, affectedSOPInstanceUID: "2.25.1"),
            DicomDataSet(elements: [a2String(0x00400252, .CS, "COMPLETED")]))])
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), mpps: A2MPPSProvider())
            .handleAssociation(using: transport)
        XCTAssertEqual(try transport.commands().last?.status, 0x0106)
    }

    func test_find_hierarchyRequiresUniqueAncestorKey() throws {
        let uid = DicomNetworkUID.studyRootQueryRetrieveFind
        let transport = try A2Transport(uid: uid, commands: [(.init(affectedSOPClassUID: uid,
            commandField: DicomDIMSECommandField.cFindRQ, messageID: 1,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet),
            DicomDataSet(elements: [a2String(0x00080052, .CS, "SERIES")]))])
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), query: A2QueryProvider())
            .handleAssociation(using: transport)
        XCTAssertEqual(try transport.commands().last?.status, 0xA900)
    }

    func test_asyncWindow_fourFindsRunConcurrently() throws {
        let uid = DicomNetworkUID.studyRootQueryRetrieveFind
        let commands: [(DicomDIMSECommandSet, DicomDataSet?)] = (1...4).map { id in
            (.init(affectedSOPClassUID: uid, commandField: DicomDIMSECommandField.cFindRQ,
                   messageID: UInt16(id), commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet),
             DicomDataSet(elements: [a2String(0x00080052, .CS, "STUDY")]))
        }
        let window = DicomAsynchronousOperationsWindow(maximumInvoked: 4, maximumPerformed: 4)
        let transport = try A2Transport(uid: uid, commands: commands, window: window)
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS", asynchronousOperationsWindow: window),
            query: A2QueryProvider(count: 1, delay: 50_000_000)).handleAssociation(using: transport)
        XCTAssertEqual(try transport.commands().filter { $0.status == 0 }.count, 4)
    }
}

final class A2Transport: DicomAssociationTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var input: [Data]
    private var output: [Data] = []
    private let onWrite: (@Sendable (Data) -> Void)?
    init(uid: String, commands: [(DicomDIMSECommandSet, DicomDataSet?)],
         window: DicomAsynchronousOperationsWindow? = nil,
         onWrite: (@Sendable (Data) -> Void)? = nil) throws {
        self.onWrite = onWrite
        let request = DicomAssociationRequest(calledAETitle: "ISIS", callingAETitle: "PEER",
            presentationContexts: [.init(id: 1, abstractSyntaxUID: uid, transferSyntaxes: [.explicitVRLittleEndian])],
            maximumPDULength: 1024, asynchronousOperationsWindow: window)
        input = [try DicomPDUCodec.encode(.associationRequest(request))]
        for (command, identifier) in commands {
            input.append(try DicomPDUCodec.encode(.pData([DicomPDV(presentationContextID: 1, isCommand: true,
                isLastFragment: true, data: command.encoded())])))
            if let identifier {
                input.append(try DicomPDUCodec.encode(.pData([DicomPDV(presentationContextID: 1, isCommand: false,
                    isLastFragment: true, data: DicomDataSetWriter.dataSetData(from: identifier))])))
            }
        }
        input.append(try DicomPDUCodec.encode(.releaseRequest))
    }
    func readPDU() throws -> Data { lock.withLock { input.removeFirst() } }
    func writePDU(_ data: Data) {
        lock.withLock { output.append(data) }
        onWrite?(data)
    }
    func commands() throws -> [DicomDIMSECommandSet] {
        var bytes = Data(), result: [DicomDIMSECommandSet] = []
        for data in output {
            if case .pData(let pdvs) = try DicomPDUCodec.decode(data) {
                XCTAssertLessThanOrEqual(data.count - 6, 1024)
                for pdv in pdvs where pdv.isCommand {
                    bytes.append(pdv.data)
                    if pdv.isLastFragment { result.append(try DicomDIMSECommandSet.decode(bytes)); bytes.removeAll() }
                }
            }
        }
        return result
    }
}
