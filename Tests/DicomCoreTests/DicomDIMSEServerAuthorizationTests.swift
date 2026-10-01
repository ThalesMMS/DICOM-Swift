import XCTest
@testable import DicomCore

final class DicomDIMSEServerAuthorizationTests: XCTestCase, @unchecked Sendable {
    func transport(get: Bool = false) throws -> A2Transport {
        let uid = get ? DicomNetworkUID.studyRootQueryRetrieveGet : DicomNetworkUID.studyRootQueryRetrieveFind
        return try A2Transport(uid: uid, commands: [(.init(affectedSOPClassUID: uid,
            commandField: get ? DicomDIMSECommandField.cGetRQ : DicomDIMSECommandField.cFindRQ,
            messageID: 1, commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet),
            .init(elements: [a2String(0x00080052, .CS, "STUDY")]))])
    }
    func test_findFiltersDeniedMatches() async throws {
        let policy = AuthorizationTestPolicy()
        await policy.deny("2.25.23500")
        let wire = try transport()
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), query: A2QueryProvider(count: 2),
            peerPrincipalResolver: { _, _, _ in authorizationPrincipal() }, authorizer: policy)
            .handleAssociation(using: wire)
        XCTAssertEqual(try wire.commands().compactMap(\.status), [0xFF00, 0])
    }
    func test_peerIdentityRequiresInjectedResolver() async throws {
        let policy = AuthorizationTestPolicy()
        let wire = try transport()
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), query: A2QueryProvider(count: 1),
            authorizer: policy).handleAssociation(using: wire, peerAddress: "127.0.0.1")
        XCTAssertEqual(try wire.commands().compactMap(\.status), [0])
        let principals = await policy.principals
        XCTAssertEqual(principals.first??.kind, .anonymous)
    }
    func test_anonymousRetrieveDeniesBeforeByteSource() throws {
        let wire = try transport(get: true)
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), retrieve: A2RetrieveProvider(),
            authorizer: DicomDenyAllAuthorizer()).handleAssociation(using: wire)
        XCTAssertEqual(try wire.commands().compactMap(\.status), [0xA702])
        XCTAssertFalse(try wire.commands().contains { $0.commandField == DicomDIMSECommandField.cStoreRQ })
    }
    func test_emptyAuthorizedRetrieve_returnsSuccessfulZeroCount() throws {
        let wire = try transport(get: true)
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), retrieve: A2RetrieveProvider(count: 0),
            peerPrincipalResolver: { _, _, _ in authorizationPrincipal() }, authorizer: AuthorizationTestPolicy())
            .handleAssociation(using: wire)
        let response = try XCTUnwrap(wire.commands().last)
        XCTAssertEqual(response.status, 0)
        XCTAssertEqual(response.completedSuboperations, 0)
        XCTAssertEqual(response.failedSuboperations, 0)
    }
    func test_mppsAuthorization_usesInstanceResource() async throws {
        let uid = DicomNetworkUID.modalityPerformedProcedureStepSOPClass
        let instanceUID = "2.25.2416.1"
        let wire = try A2Transport(uid: uid, commands: [(.init(affectedSOPClassUID: uid,
            commandField: DicomDIMSECommandField.nCreateRQ, messageID: 1,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet, affectedSOPInstanceUID: instanceUID),
            .init(elements: [a2String(0x00400252, .CS, "IN PROGRESS")]))])
        let policy = AuthorizationTestPolicy()
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), mpps: A2MPPSProvider(),
            peerPrincipalResolver: { _, _, _ in authorizationPrincipal() }, authorizer: policy)
            .handleAssociation(using: wire)
        XCTAssertEqual(try wire.commands().last?.status, 0)
        let calls = await policy.calls
        XCTAssertTrue(calls.contains { $0.kind == .instance && $0.id == instanceUID })
        XCTAssertFalse(calls.contains { $0.kind == .workitem })
    }
    func test_commitmentReportAuthorization_usesReferencedInstance() async throws {
        let uid = DicomNetworkUID.storageCommitmentPushModelSOPClass
        let instanceUID = "2.25.2416.2"
        let report = DicomStorageCommitmentReport(transactionUID: "2.25.2416.3", status: .committed,
            references: [.init(sopClassUID: DicomStorageSOPClassUIDs.secondaryCaptureImageStorage,
                sopInstanceUID: instanceUID)])
        let wire = try A2Transport(uid: uid, commands: [(.init(affectedSOPClassUID: uid,
            commandField: DicomDIMSECommandField.nEventReportRQ, messageID: 1,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            affectedSOPInstanceUID: DicomNetworkUID.storageCommitmentPushModelSOPInstance, eventTypeID: 1),
            DicomStorageCommitmentTracker.eventReportDataSet(for: report))])
        let policy = AuthorizationTestPolicy()
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), commitmentResultHandler: { _ in },
            peerPrincipalResolver: { _, _, _ in authorizationPrincipal() }, authorizer: policy,
            resourceResolver: { .instance(study: "2.25.2416.4", series: "2.25.2416.5", instance: $0) })
            .handleAssociation(using: wire)
        XCTAssertEqual(try wire.commands().last?.status, 0)
        let calls = await policy.calls
        XCTAssertTrue(calls.contains { $0.kind == .instance && $0.id == instanceUID })
        XCTAssertFalse(calls.contains { $0.kind == .workitem })
    }
    func test_recheckEveryInstanceDetectsRevocation() async throws {
        let policy = AuthorizationTestPolicy()
        let access = DicomEnforcement(principal: authorizationPrincipal(), authorizer: policy,
            audit: nil, context: .init(protocol: .dimse))
        let resource = DicomResourceRef.instance(study: "1", series: "2", instance: "3")
        try await access.recheck(.readBytes, resource)
        await policy.deny("1")
        do { try await access.recheck(.readBytes, resource); XCTFail("Revoked lease accepted") } catch {}
    }
    func test_nonLoopbackStartRefusesBeforeOpeningSocket() throws {
        var configuration = DicomDIMSEServerConfiguration(aeTitle: "ISIS", port: 0)
        configuration.bindAddress = "0.0.0.0"
        XCTAssertThrowsError(try DicomDIMSEServer(configuration: configuration, exposure: .defaults(for: .localOnly)).start()) {
            XCTAssertTrue($0 is DicomExposureValidationError)
        }
    }
}

private struct AuthorizedRetrieveProvider: DicomRetrieveProviding {
    let policy: AuthorizationTestPolicy
    var revokeSecond = false
    func instances(for request: DicomRetrieveRequest) -> AsyncThrowingStream<DicomRetrievableInstance, Error> {
        AsyncThrowingStream { continuation in
            for index in 1...2 {
                let uid = "2.25.\(index)"
                continuation.yield(.init(sopClassUID: DicomStorageSOPClassUIDs.secondaryCaptureImageStorage,
                    sopInstanceUID: uid, transferSyntaxes: [.explicitVRLittleEndian],
                    resource: .instance(study: "2.25.10", series: "2.25.20", instance: uid)) { syntax in
                    if revokeSecond && index == 1 { await policy.deny("2.25.2") }
                    return try DicomDataSetWriter.dataSetData(from: .init(elements: [
                        a2String(0x00080016, .UI, DicomStorageSOPClassUIDs.secondaryCaptureImageStorage),
                        a2String(0x00080018, .UI, uid)
                    ]), transferSyntax: syntax)
                })
            }
            continuation.finish()
        }
    }
}

/// Scripted peer that acknowledges real outgoing C-STORE suboperations on the C-GET association.
private final class AuthorizedGetWire: DicomAssociationTransport, @unchecked Sendable {
    private let condition = NSCondition()
    private var input: [Data]
    private var commands: [DicomDIMSECommandSet] = []
    private var commandBytes = Data()
    private var storeRequest: DicomDIMSECommandSet?
    init() throws {
        let get = DicomNetworkUID.studyRootQueryRetrieveGet
        let storage = DicomStorageSOPClassUIDs.secondaryCaptureImageStorage
        let request = DicomAssociationRequest(calledAETitle: "ISIS", callingAETitle: "UNTRUSTED-AE",
            presentationContexts: [.init(id: 1, abstractSyntaxUID: get, transferSyntaxes: [.explicitVRLittleEndian]),
                                   .init(id: 3, abstractSyntaxUID: storage, transferSyntaxes: [.explicitVRLittleEndian])],
            roleSelections: [.init(sopClassUID: storage, scuRole: false, scpRole: true)])
        let command = DicomDIMSECommandSet(affectedSOPClassUID: get, commandField: DicomDIMSECommandField.cGetRQ,
            messageID: 1, commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet)
        input = [try DicomPDUCodec.encode(.associationRequest(request)),
                 try DicomPDUCodec.encode(.pData([.init(presentationContextID: 1, isCommand: true,
                    isLastFragment: true, data: command.encoded())])),
                 try DicomPDUCodec.encode(.pData([.init(presentationContextID: 1, isCommand: false,
                    isLastFragment: true, data: DicomDataSetWriter.dataSetData(from: .init(elements: [
                        a2String(0x00080052, .CS, "STUDY")])))]))]
    }
    func readPDU() throws -> Data {
        condition.lock(); defer { condition.unlock() }
        while input.isEmpty {
            guard condition.wait(until: Date().addingTimeInterval(5)) else {
                throw DicomNetworkError.networkTimeout("scripted peer")
            }
        }
        return input.removeFirst()
    }
    func writePDU(_ bytes: Data) throws {
        condition.lock(); defer { condition.unlock() }
        guard case .pData(let pdvs) = try DicomPDUCodec.decode(bytes) else { return }
        for pdv in pdvs {
            if pdv.isCommand {
                commandBytes.append(pdv.data)
                if pdv.isLastFragment {
                    let command = try DicomDIMSECommandSet.decode(commandBytes)
                    commandBytes.removeAll(); commands.append(command)
                    if command.commandField == DicomDIMSECommandField.cStoreRQ { storeRequest = command }
                    if command.commandField == DicomDIMSECommandField.cGetRQ | 0x8000,
                       command.status != 0xFF00 {
                        input.append(try DicomPDUCodec.encode(.releaseRequest)); condition.signal()
                    }
                }
            } else if pdv.isLastFragment, let request = storeRequest {
                let reply = DicomDIMSECommandSet(affectedSOPClassUID: request.affectedSOPClassUID,
                    commandField: DicomDIMSECommandField.cStoreRQ | 0x8000,
                    messageIDBeingRespondedTo: request.messageID, status: 0,
                    affectedSOPInstanceUID: request.affectedSOPInstanceUID)
                input.append(try DicomPDUCodec.encode(.pData([.init(presentationContextID: 3, isCommand: true,
                    isLastFragment: true, data: reply.encoded())])))
                storeRequest = nil; condition.signal()
            }
        }
    }
    var sentInstances: [String] {
        condition.withLock { commands.filter { $0.commandField == DicomDIMSECommandField.cStoreRQ }.compactMap(\.affectedSOPInstanceUID) }
    }
    var finalStatus: UInt16? { condition.withLock { commands.last?.status } }
}

extension DicomDIMSEServerAuthorizationTests {
    func test_cGetDeniedInstanceIsNeverSent() async throws {
        let policy = AuthorizationTestPolicy()
        await policy.deny("2.25.2")
        let wire = try AuthorizedGetWire()
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"),
            retrieve: AuthorizedRetrieveProvider(policy: policy),
            peerPrincipalResolver: { _, _, _ in authorizationPrincipal() }, authorizer: policy)
            .handleAssociation(using: wire)
        XCTAssertEqual(wire.sentInstances, ["2.25.1"])
        XCTAssertEqual(wire.finalStatus, 0)
    }
    func test_cGetRevocationBetweenInstancesStopsNextStore() throws {
        let policy = AuthorizationTestPolicy()
        let wire = try AuthorizedGetWire()
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"),
            retrieve: AuthorizedRetrieveProvider(policy: policy, revokeSecond: true),
            peerPrincipalResolver: { _, _, _ in authorizationPrincipal() }, authorizer: policy)
            .handleAssociation(using: wire)
        XCTAssertEqual(wire.sentInstances, ["2.25.1"])
        XCTAssertEqual(wire.finalStatus, 0xA702)
    }
}
