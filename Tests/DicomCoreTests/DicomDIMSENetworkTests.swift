import Foundation
@testable import DicomCore
import XCTest

final class DicomDIMSENetworkTests: XCTestCase {
    func test_moveCommand_encodesElementsInTagOrder() throws {
        let command = DicomDIMSECommandSet(commandField: 0x0021, messageID: 1,
                                           moveDestination: "VIEWER", priority: 0)
        let data = try command.encoded()
        var tags: [UInt32] = []
        var offset = 0
        while offset < data.count {
            let element = data.dicomInteger(at: offset + 2, as: UInt16.self, littleEndian: true)
            tags.append(UInt32(element))
            let length = data.dicomInteger(at: offset + 4, as: UInt32.self, littleEndian: true)
            offset += 8 + Int(length)
        }
        XCTAssertEqual(tags, [0, 0x0100, 0x0110, 0x0600, 0x0700, 0x0800])
        XCTAssertEqual(try DicomDIMSECommandSet.decode(data), command)
    }

    func testAssociationRequestRoundTripPreservesPresentationContexts() throws {
        let request = DicomAssociationRequest(
            calledAETitle: "SERVER_AE",
            callingAETitle: "CLIENT_AE",
            presentationContexts: [
                DicomPresentationContextRequest(
                    id: 1,
                    abstractSyntaxUID: DicomNetworkUID.verificationSOPClass,
                    transferSyntaxes: [.implicitVRLittleEndian, .explicitVRLittleEndian]
                ),
                DicomPresentationContextRequest(
                    id: 3,
                    abstractSyntaxUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                    transferSyntaxes: [.explicitVRLittleEndian]
                )
            ],
            maximumPDULength: 32_768
        )

        let decoded = try DicomPDUCodec.decode(DicomPDUCodec.encode(.associationRequest(request)))

        guard case .associationRequest(let roundTrip) = decoded else {
            return XCTFail("Expected association request PDU.")
        }
        XCTAssertEqual(roundTrip.calledAETitle, "SERVER_AE")
        XCTAssertEqual(roundTrip.callingAETitle, "CLIENT_AE")
        XCTAssertEqual(roundTrip.applicationContextUID, DicomNetworkUID.applicationContext)
        XCTAssertEqual(roundTrip.maximumPDULength, 32_768)
        XCTAssertEqual(roundTrip.presentationContexts, request.presentationContexts)
    }

    func testAssociationRequestRoundTripPreservesUserIdentity() throws {
        let identity = DicomUserIdentity.usernameAndPasscode(
            "operator",
            passcode: "secret",
            positiveResponseRequested: true
        )
        let request = DicomAssociationRequest(
            calledAETitle: "SERVER_AE",
            callingAETitle: "CLIENT_AE",
            presentationContexts: [
                DicomPresentationContextRequest(
                    id: 1,
                    abstractSyntaxUID: DicomNetworkUID.verificationSOPClass,
                    transferSyntaxes: [.explicitVRLittleEndian]
                )
            ],
            userIdentity: identity
        )

        let decoded = try DicomPDUCodec.decode(DicomPDUCodec.encode(.associationRequest(request)))

        guard case .associationRequest(let roundTrip) = decoded else {
            return XCTFail("Expected association request PDU.")
        }
        XCTAssertEqual(roundTrip.userIdentity, identity)
    }

    func testSCUNegotiatesAcceptedPresentationContextWithFakeEndpoint() throws {
        let request = DicomAssociationRequest(
            calledAETitle: "ARCHIVE",
            callingAETitle: "VIEWER",
            presentationContexts: [
                DicomPresentationContextRequest(
                    id: 1,
                    abstractSyntaxUID: DicomNetworkUID.verificationSOPClass,
                    transferSyntaxes: [.implicitVRLittleEndian, .explicitVRLittleEndian]
                ),
                DicomPresentationContextRequest(
                    id: 3,
                    abstractSyntaxUID: "1.2.840.10008.5.1.4.1.1.999",
                    transferSyntaxes: [.explicitVRLittleEndian]
                )
            ]
        )
        let transport = NegotiatingTransport(
            supportedAbstractSyntaxUIDs: [DicomNetworkUID.verificationSOPClass],
            preferredTransferSyntaxes: [.explicitVRLittleEndian]
        )

        let association = try DicomAssociationSCU(request: request).open(using: transport)

        XCTAssertEqual(transport.writtenPDUs.count, 1)
        XCTAssertEqual(association.stateMachine.state, .associated)
        let accepted = try XCTUnwrap(
            association.acceptedPresentationContext(for: DicomNetworkUID.verificationSOPClass)
        )
        XCTAssertEqual(accepted.id, 1)
        XCTAssertEqual(accepted.transferSyntax, .explicitVRLittleEndian)
        XCTAssertEqual(association.accept.presentationContexts.first { $0.id == 3 }?.result,
                       .abstractSyntaxNotSupported)
    }

    func testPDataCommandSetRoundTrip() throws {
        let commandSet = DicomDIMSECommandSet(
            affectedSOPClassUID: DicomNetworkUID.verificationSOPClass,
            commandField: 0x0030,
            messageID: 7,
            commandDataSetType: DicomDIMSECommandDataSetType.noDataSet
        )
        let decodedCommand = try DicomDIMSECommandSet.decode(commandSet.encoded())

        XCTAssertEqual(decodedCommand, commandSet)

        let association = DicomAssociation(
            request: DicomAssociationRequest(
                calledAETitle: "ARCHIVE",
                callingAETitle: "VIEWER",
                presentationContexts: [
                    DicomPresentationContextRequest(
                        id: 1,
                        abstractSyntaxUID: DicomNetworkUID.verificationSOPClass,
                        transferSyntaxes: [.explicitVRLittleEndian]
                    )
                ]
            ),
            accept: DicomAssociationAccept(
                calledAETitle: "ARCHIVE",
                callingAETitle: "VIEWER",
                presentationContexts: [
                    DicomPresentationContextAccept(id: 1,
                                                   result: .acceptance,
                                                   transferSyntax: .explicitVRLittleEndian)
                ]
            )
        )
        let pdu = try association.commandPData(commandSet, presentationContextID: 1)
        let decodedPDU = try DicomPDUCodec.decode(DicomPDUCodec.encode(pdu))

        guard case .pData(let pdvs) = decodedPDU else {
            return XCTFail("Expected P-DATA PDU.")
        }
        XCTAssertEqual(pdvs.count, 1)
        XCTAssertEqual(pdvs[0].presentationContextID, 1)
        XCTAssertTrue(pdvs[0].isCommand)
        XCTAssertTrue(pdvs[0].isLastFragment)
        XCTAssertEqual(try DicomDIMSECommandSet.decode(pdvs[0].data), commandSet)

        XCTAssertThrowsError(try association.commandPData(commandSet, presentationContextID: 3)) { error in
            XCTAssertEqual(error as? DicomNetworkError, .invalidPresentationContextID(3))
        }
    }

    func testPDataMessageControlHeaderUsesDicomBitLayout() throws {
        let pdu = DicomPDU.pData([
            DicomPDV(presentationContextID: 1,
                    isCommand: true,
                    isLastFragment: false,
                    data: Data([0xAA])),
            DicomPDV(presentationContextID: 3,
                    isCommand: false,
                    isLastFragment: true,
                    data: Data([0xBB]))
        ])

        let encoded = try DicomPDUCodec.encode(pdu)

        XCTAssertEqual(encoded[11], 0x01, "Bit 0 marks Command fragments.")
        XCTAssertEqual(encoded[18], 0x02, "Bit 1 marks the last fragment.")

        let rawPData = Data([
            0x04, 0x00, 0x00, 0x00, 0x00, 0x07,
            0x00, 0x00, 0x00, 0x03, 0x05, 0x02, 0xCC
        ])
        guard case .pData(let pdvs) = try DicomPDUCodec.decode(rawPData) else {
            return XCTFail("Expected P-DATA PDU.")
        }

        XCTAssertEqual(pdvs, [
            DicomPDV(presentationContextID: 5,
                    isCommand: false,
                    isLastFragment: true,
                    data: Data([0xCC]))
        ])
    }

    func test_pDataDecode_retainsPayloadAsSliceOfInputBuffer() throws {
        let payload = Data(repeating: 0x5A, count: 64 * 1_024)
        let encoded = try DicomPDUCodec.encode(.pData([
            DicomPDV(
                presentationContextID: 1,
                isCommand: false,
                isLastFragment: true,
                data: payload
            )
        ]))

        guard case .pData(let pdvs) = try DicomPDUCodec.decode(encoded),
              let decodedPayload = pdvs.first?.data else {
            return XCTFail("Expected one P-DATA payload.")
        }

        XCTAssertEqual(decodedPayload, payload)
    }

    func testStateMachineCoversReleaseAbortAndPDataErrors() throws {
        var stateMachine = DicomAssociationStateMachine()
        XCTAssertThrowsError(try stateMachine.validatePDataAllowed())

        try stateMachine.sendAssociationRequest()
        try stateMachine.receiveAssociationAccept()
        XCTAssertNoThrow(try stateMachine.validatePDataAllowed())

        try stateMachine.sendReleaseRequest()
        XCTAssertEqual(stateMachine.state, .releaseRequested)
        try stateMachine.receiveReleaseResponse()
        XCTAssertEqual(stateMachine.state, .released)

        let abort = DicomAbort(source: .serviceProvider, reason: .unexpectedPDU)
        var abortStateMachine = DicomAssociationStateMachine(state: .associated)
        abortStateMachine.receiveAbort(abort)
        XCTAssertEqual(abortStateMachine.state, .aborted(abort))

        XCTAssertEqual(try DicomPDUCodec.decode(DicomPDUCodec.encode(.releaseRequest)), .releaseRequest)
        XCTAssertEqual(try DicomPDUCodec.decode(DicomPDUCodec.encode(.releaseResponse)), .releaseResponse)
        XCTAssertEqual(try DicomPDUCodec.decode(DicomPDUCodec.encode(.abort(abort))), .abort(abort))
    }

    func testSCUReportsAssociationReject() throws {
        let reject = DicomAssociationReject(result: .rejectedPermanent,
                                            source: .serviceUser,
                                            reason: .calledAENotRecognized)
        let transport = StaticResponseTransport(response: try DicomPDUCodec.encode(.associationReject(reject)))
        let request = DicomAssociationRequest(
            calledAETitle: "MISSING",
            callingAETitle: "VIEWER",
            presentationContexts: [
                DicomPresentationContextRequest(
                    id: 1,
                    abstractSyntaxUID: DicomNetworkUID.verificationSOPClass,
                    transferSyntaxes: [.explicitVRLittleEndian]
                )
            ]
        )

        XCTAssertThrowsError(try DicomAssociationSCU(request: request).open(using: transport)) { error in
            XCTAssertEqual(error as? DicomNetworkError, .associationRejected(reject))
        }
    }

    func testSCUReportsAssociationAbort() throws {
        let abort = DicomAbort(source: .serviceProvider, reason: .unexpectedPDU)
        let transport = StaticResponseTransport(response: try DicomPDUCodec.encode(.abort(abort)))
        let request = DicomAssociationRequest(
            calledAETitle: "ARCHIVE",
            callingAETitle: "VIEWER",
            presentationContexts: [
                DicomPresentationContextRequest(
                    id: 1,
                    abstractSyntaxUID: DicomNetworkUID.verificationSOPClass,
                    transferSyntaxes: [.explicitVRLittleEndian]
                )
            ]
        )

        XCTAssertThrowsError(try DicomAssociationSCU(request: request).open(using: transport)) { error in
            XCTAssertEqual(error as? DicomNetworkError, .associationAborted(abort))
        }
    }
}

private final class NegotiatingTransport: DicomAssociationTransport {
    private let supportedAbstractSyntaxUIDs: Set<String>
    private let preferredTransferSyntaxes: [DicomTransferSyntax]
    private var responses: [Data] = []
    private(set) var writtenPDUs: [Data] = []

    init(supportedAbstractSyntaxUIDs: Set<String>,
         preferredTransferSyntaxes: [DicomTransferSyntax]) {
        self.supportedAbstractSyntaxUIDs = supportedAbstractSyntaxUIDs
        self.preferredTransferSyntaxes = preferredTransferSyntaxes
    }

    func writePDU(_ data: Data) throws {
        writtenPDUs.append(data)
        guard case .associationRequest(let request) = try DicomPDUCodec.decode(data) else {
            throw DicomNetworkError.unsupportedPDU(.pData)
        }
        let accept = DicomAssociationNegotiator.accept(
            request,
            supportedAbstractSyntaxUIDs: supportedAbstractSyntaxUIDs,
            preferredTransferSyntaxes: preferredTransferSyntaxes
        )
        responses.append(try DicomPDUCodec.encode(.associationAccept(accept)))
    }

    func readPDU() throws -> Data {
        guard !responses.isEmpty else {
            throw DicomNetworkError.invalidPDULength(expected: 1, actual: 0)
        }
        return responses.removeFirst()
    }
}

private final class StaticResponseTransport: DicomAssociationTransport {
    private let response: Data
    private var didRead = false

    init(response: Data) {
        self.response = response
    }

    func writePDU(_ data: Data) throws {}

    func readPDU() throws -> Data {
        guard !didRead else {
            throw DicomNetworkError.invalidPDULength(expected: 1, actual: 0)
        }
        didRead = true
        return response
    }
}

extension DicomDIMSENetworkTests {
    func test_extendedNegotiation_roundTripsAndAcceptorLimitsCapabilities() throws {
        let uid = DicomNetworkUID.studyRootQueryRetrieveFind
        let extended = DicomSOPClassExtendedNegotiation(sopClassUID: uid, relationalQueries: true,
                                                        dateTimeMatching: true, fuzzyPersonNameMatching: true)
        let request = DicomAssociationRequest(calledAETitle: "SCP", callingAETitle: "SCU",
            presentationContexts: [.init(id: 1, abstractSyntaxUID: uid, transferSyntaxes: [.explicitVRLittleEndian])],
            maximumPDULength: 65536, roleSelections: [.init(sopClassUID: uid, scuRole: true, scpRole: true)],
            asynchronousOperationsWindow: .init(maximumInvoked: 0, maximumPerformed: 4),
            extendedNegotiations: [extended], commonExtendedNegotiations: [
                .init(sopClassUID: uid, serviceClassUID: "1.2.840.10008.4.2", relatedGeneralSOPClassUIDs: [uid])
            ])
        XCTAssertEqual(try DicomPDUCodec.decode(DicomPDUCodec.encode(.associationRequest(request))), .associationRequest(request))
        var accept = DicomAssociationNegotiator.accept(request, supportedAbstractSyntaxUIDs: [uid],
            preferredTransferSyntaxes: [.explicitVRLittleEndian], maximumPDULength: 1024,
            supportedAsynchronousOperationsWindow: .init(maximumInvoked: 4, maximumPerformed: 0),
            supportedExtendedNegotiations: [.init(sopClassUID: uid, relationalQueries: true)])
        XCTAssertEqual(accept.maximumPDULength, 1024)
        XCTAssertEqual(accept.asynchronousOperationsWindow, .init(maximumInvoked: 4, maximumPerformed: 4))
        XCTAssertEqual(accept.roleSelections, [.init(sopClassUID: uid, scuRole: true, scpRole: false)])
        XCTAssertEqual(accept.extendedNegotiations.first?.serviceClassApplicationInformation, Data([1, 0, 0, 0, 0]))
        accept.userIdentityServerResponse = .init(data: Data([0, 1, 255]))
        XCTAssertEqual(try DicomPDUCodec.decode(DicomPDUCodec.encode(.associationAccept(accept))), .associationAccept(accept))
    }

    func test_duplicatePresentationContextIDs_areRejected() throws {
        let context = DicomPresentationContextRequest(id: 1, abstractSyntaxUID: DicomNetworkUID.verificationSOPClass,
                                                      transferSyntaxes: [.explicitVRLittleEndian])
        let request = DicomAssociationRequest(calledAETitle: "SCP", callingAETitle: "SCU", presentationContexts: [context, context])
        XCTAssertThrowsError(try DicomPDUCodec.encode(.associationRequest(request)))
    }

    func test_identityResponse_rejectsPayloadAndEnclosingItemOverflow() throws {
        var accept = DicomAssociationAccept(calledAETitle: "SCP", callingAETitle: "SCU", presentationContexts: [
            .init(id: 1, result: .acceptance, transferSyntaxUID: DicomTransferSyntax.explicitVRLittleEndian.rawValue)
        ])
        for count in [65_529, 65_534, 65_536] {
            accept.userIdentityServerResponse = .init(data: Data(repeating: 1, count: count))
            XCTAssertThrowsError(try DicomPDUCodec.encode(.associationAccept(accept))) { error in
                XCTAssertEqual(error as? DicomNetworkError,
                    .malformedCommandSet("User Identity response exceeds the association item length."))
            }
        }
        accept.userIdentityServerResponse = .init(data: Data(repeating: 1, count: 60_000))
        XCTAssertEqual(try DicomPDUCodec.decode(DicomPDUCodec.encode(.associationAccept(accept))), .associationAccept(accept))
    }

    func test_outstandingRegistry_pendingCancelledAndReusedIDsKeepCount() throws {
        let registry = DicomDIMSEOutstandingOperations()
        let request = DicomDIMSECommandSet(commandField: DicomDIMSECommandField.cFindRQ, messageID: 1)
        try registry.register(request)
        try registry.correlate(.init(commandField: DicomDIMSECommandField.cFindRSP,
                                    messageIDBeingRespondedTo: 1, status: 0xFF00))
        XCTAssertEqual(registry.outstandingCount, 1)
        XCTAssertThrowsError(try registry.register(request))
        let cancelled = DicomDIMSECommandSet(commandField: DicomDIMSECommandField.cFindRSP,
                                            messageIDBeingRespondedTo: 1, status: 0xFE00)
        try registry.correlate(cancelled)
        XCTAssertEqual(registry.outstandingCount, 0)
        XCTAssertThrowsError(try registry.correlate(cancelled))
        XCTAssertEqual(registry.outstandingCount, 0)
        try registry.register(request)
        XCTAssertEqual(registry.outstandingCount, 1)
    }

    func test_outstandingRegistry_correlatesOutOfOrderAndRejectsMissingStatus() throws {
        let registry = DicomDIMSEOutstandingOperations(window: .init(maximumInvoked: 4))
        for id: UInt16 in 1...4 {
            try registry.register(.init(commandField: DicomDIMSECommandField.cStoreRQ, messageID: id))
        }
        XCTAssertEqual(registry.outstandingCount, 4)
        XCTAssertThrowsError(try registry.register(.init(commandField: DicomDIMSECommandField.cEchoRQ, messageID: 5)))
        XCTAssertThrowsError(try registry.correlate(.init(commandField: DicomDIMSECommandField.cStoreRSP,
                                                         messageIDBeingRespondedTo: 5, status: 0)))
        XCTAssertThrowsError(try registry.correlate(.init(commandField: DicomDIMSECommandField.cStoreRSP,
                                                         messageIDBeingRespondedTo: 4)))
        for id: UInt16 in [4, 2, 1, 3] {
            try registry.correlate(.init(commandField: DicomDIMSECommandField.cStoreRSP,
                                         messageIDBeingRespondedTo: id, status: 0))
        }
        XCTAssertEqual(registry.outstandingCount, 0)
        XCTAssertEqual(registry.state(for: 4), .final)
    }
}
