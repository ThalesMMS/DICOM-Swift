import Foundation
@testable import DicomCore
import XCTest

final class DicomDIMSENetworkTests: XCTestCase {
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
