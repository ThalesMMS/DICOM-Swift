import Foundation
import XCTest
@testable import DicomCore

/// Issue #2792: the upper layer follows PS3.8 Table 9-10 where it diverged.
/// An unexpected or malformed PDU is answered with A-ABORT before the
/// connection closes (AA-1, AA-8), data in flight and a release collision are
/// taken while releasing (AR-6, AR-8), and a second User Identity is refused.
/// The association-parsing cases of DCMTK's `dcmnet/tests/tparseassoc.cc`
/// close the file, rewritten for this codec.
final class DicomDULStateMachineTests: XCTestCase {
    // MARK: - SCP: A-ABORT on a protocol error

    func test_scp_firstPDUIsNotAnAssociateRequest_abortsWithUnexpectedPDU() throws {
        let transport = DULQueueTransport(input: [try DicomPDUCodec.encode(.releaseRequest)])
        XCTAssertThrowsError(try server().handleAssociation(using: transport))
        XCTAssertEqual(try transport.lastAbort(), DicomAbort(source: .serviceProvider, reason: .unexpectedPDU))
    }

    func test_scp_unknownPDUTypeInTheAssociation_abortsWithUnrecognizedPDU() throws {
        let transport = DULQueueTransport(input: [try Self.echoAssociationRequest(), Data([0x09, 0, 0, 0, 0, 0])])
        XCTAssertThrowsError(try server().handleAssociation(using: transport))
        XCTAssertEqual(try transport.lastAbort(), DicomAbort(source: .serviceProvider, reason: .unrecognizedPDU))
    }

    func test_scp_secondAssociateRequestInTheAssociation_abortsWithUnexpectedPDU() throws {
        let transport = DULQueueTransport(input: [try Self.echoAssociationRequest(), try Self.echoAssociationRequest()])
        XCTAssertThrowsError(try server().handleAssociation(using: transport))
        XCTAssertEqual(try transport.lastAbort(), DicomAbort(source: .serviceProvider, reason: .unexpectedPDU))
    }

    func test_scp_malformedAssociateRequest_abortsWithInvalidParameterValue() throws {
        let transport = DULQueueTransport(input: [Self.associateRequest(items: Self.presentationContextWithTruncatedSyntax())])
        XCTAssertThrowsError(try server().handleAssociation(using: transport))
        XCTAssertEqual(try transport.lastAbort(),
                       DicomAbort(source: .serviceProvider, reason: .invalidPDUParameterValue))
    }

    func test_scp_duplicateUserIdentity_isRefusedWithAnAbort() throws {
        let identity = Self.userIdentity(primary: "A", secondary: "")
        let request = Self.associateRequest(items: Self.applicationContext() + Self.echoPresentationContext()
            + Self.userInformation(Self.maximumLength() + identity + identity))
        let transport = DULQueueTransport(input: [request])
        XCTAssertThrowsError(try server().handleAssociation(using: transport))
        XCTAssertEqual(try transport.lastAbort(),
                       DicomAbort(source: .serviceProvider, reason: .unexpectedPDUParameter))
        XCTAssertFalse(transport.written.contains { $0.first == DicomPDUType.associationAccept.rawValue },
                       "no association is accepted")
    }

    func test_scp_peerAbort_isNotAnsweredWithAnotherAbort() throws {
        let transport = DULQueueTransport(input: [
            try Self.echoAssociationRequest(),
            try DicomPDUCodec.encode(.abort(DicomAbort(source: .serviceUser, reason: .reasonNotSpecified)))
        ])
        XCTAssertThrowsError(try server().handleAssociation(using: transport))
        XCTAssertNil(try transport.lastAbort())
    }

    // MARK: - SCU: A-ABORT, and the release

    func test_scu_unknownPDUTypeInsteadOfTheResponse_abortsWithUnrecognizedPDU() throws {
        let peer = DULEchoPeer(responseToEcho: [Data([0x09, 0, 0, 0, 0, 0])])
        XCTAssertThrowsError(try scu(peer).verify())
        XCTAssertEqual(try peer.lastAbort(), DicomAbort(source: .serviceProvider, reason: .unrecognizedPDU))
    }

    func test_scu_dataBetweenReleaseRequestAndResponse_isTakenAndTheReleaseCompletes() throws {
        let stray = try DicomPDUCodec.encode(.pData([DicomPDV(presentationContextID: 1, isCommand: false,
                                                               isLastFragment: true, data: Data([0, 0]))]))
        let peer = DULEchoPeer(responseToRelease: [stray, try DicomPDUCodec.encode(.releaseResponse)])
        XCTAssertEqual(try scu(peer).verify().status, 0)
        XCTAssertNil(try peer.lastAbort())
    }

    func test_scu_releaseCollision_answersThePeerThenTakesItsResponse() throws {
        let peer = DULEchoPeer(responseToRelease: [try DicomPDUCodec.encode(.releaseRequest)],
                               responseToReleaseResponse: [try DicomPDUCodec.encode(.releaseResponse)])
        XCTAssertEqual(try scu(peer).verify().status, 0)
        XCTAssertEqual(peer.releaseResponsesReceived, 1, "the requestor answered the colliding release (AR-9)")
    }

    // MARK: - tparseassoc.cc

    /// `dcmnet_parseAssociate_extNeg_truncated`: ten extended negotiations, then one a byte short.
    func test_parse_truncatedExtendedNegotiation_isRefused() {
        let valid = Data(repeating: 0, count: 0) + (0 ..< 10).reduce(Data()) { data, _ in
            data + Self.item(0x56, Data([0, 0]))
        }
        let truncated = Data([0x56, 0, 0, 2, 0])
        XCTAssertThrowsError(try DicomPDUCodec.decode(Self.associateRequest(
            items: Self.applicationContext() + Self.echoPresentationContext()
                + Self.userInformation(Self.maximumLength() + valid + truncated)
        )))
    }

    /// `dcmnet_parseAssociate_extNeg_malformed_itemLength`: an extended negotiation of length 1.
    func test_parse_extendedNegotiationShorterThanItsUIDLength_isRefused() {
        XCTAssertThrowsError(try DicomPDUCodec.decode(Self.associateRequest(
            items: Self.applicationContext() + Self.echoPresentationContext()
                + Self.userInformation(Self.maximumLength() + Data([0x56, 0, 0, 1, 0, 0]))
        )))
    }

    /// `dcmnet_parseAssociate_duplicate_userIdentity`.
    func test_parse_duplicateUserIdentity_isRefused() {
        let identity = Self.userIdentity(primary: "A", secondary: "")
        XCTAssertThrowsError(try DicomPDUCodec.decode(Self.associateRequest(
            items: Self.applicationContext() + Self.echoPresentationContext()
                + Self.userInformation(Self.maximumLength() + identity + identity)
        ))) { error in
            XCTAssertEqual(error as? DicomNetworkError, .duplicatePDUParameter(0x58))
        }
    }

    /// `dcmnet_parseAssociate_presCtx_malformed_transferSyntax`: five transfer syntaxes, then one
    /// whose length runs past its presentation context.
    func test_parse_transferSyntaxPastItsPresentationContext_isRefused() {
        XCTAssertThrowsError(try DicomPDUCodec.decode(Self.associateRequest(
            items: Self.applicationContext() + Self.presentationContextWithTruncatedSyntax()
        )))
    }

    /// `dcmnet_parseUserIdentity_secondaryField_bytesRead`: a User Identity with both fields is read
    /// whole, so the sub-item after it is read as itself.
    func test_parse_userIdentityWithSecondaryField_isReadWhole() throws {
        let identity = Self.userIdentity(primary: "ABC", secondary: "abcde")
        let decoded = try DicomPDUCodec.decode(Self.associateRequest(
            items: Self.applicationContext() + Self.echoPresentationContext()
                + Self.userInformation(identity + Self.maximumLength())
        ))
        guard case .associationRequest(let request) = decoded else { return XCTFail("\(decoded)") }
        XCTAssertEqual(request.userIdentity?.primaryField, Data("ABC".utf8))
        XCTAssertEqual(request.userIdentity?.secondaryField, Data("abcde".utf8))
        XCTAssertEqual(request.maximumPDULength, 16_384, "the item after the identity was read as itself")
    }

    // MARK: - Helpers

    private func server() -> DicomDIMSEServer {
        DicomDIMSEServer(configuration: .init(aeTitle: "ISIS", port: 0))
    }

    private func scu(_ peer: DULEchoPeer) -> DicomDIMSEServiceSCU {
        DicomDIMSEServiceSCU(configuration: .init(host: "127.0.0.1", port: 104, calledAETitle: "PEER",
                                                  callingAETitle: "ISIS", timeout: 2),
                             transportFactory: { peer })
    }

    static func echoAssociationRequest() throws -> Data {
        try DicomPDUCodec.encode(.associationRequest(DicomAssociationRequest(
            calledAETitle: "ISIS", callingAETitle: "PEER",
            presentationContexts: [.init(id: 1, abstractSyntaxUID: DicomNetworkUID.verificationSOPClass,
                                         transferSyntaxes: [.implicitVRLittleEndian])]
        )))
    }

    static func item(_ type: UInt8, _ value: Data) -> Data {
        Data([type, 0]) + bigEndian16(value.count) + value
    }

    static func bigEndian16(_ value: Int) -> Data { Data([UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }

    static func associateRequest(items: Data) -> Data {
        let title = { (text: String) in Data(text.padding(toLength: 16, withPad: " ", startingAt: 0).utf8) }
        let body = Data([0, 1, 0, 0]) + title("ISIS") + title("PEER") + Data(count: 32) + items
        let length = UInt32(body.count)
        return Data([0x01, 0, UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF),
                     UInt8(length & 0xFF)]) + body
    }

    static func applicationContext() -> Data { item(0x10, Data("1.2.840.10008.3.1.1.1".utf8)) }

    static func echoPresentationContext() -> Data {
        item(0x20, Data([1, 0, 0, 0]) + item(0x30, Data(DicomNetworkUID.verificationSOPClass.utf8))
            + item(0x40, Data("1.2.840.10008.1.2".utf8)))
    }

    static func presentationContextWithTruncatedSyntax() -> Data {
        let syntax = "1.2.840.10008.1.2"
        let valid = (0 ..< 5).reduce(Data()) { data, _ in data + item(0x40, Data(syntax.utf8)) }
        let truncated = Data([0x40, 0]) + bigEndian16(syntax.utf8.count)
        return item(0x20, Data([1, 0, 0, 0]) + item(0x30, Data(DicomNetworkUID.verificationSOPClass.utf8))
            + valid + truncated)
    }

    static func maximumLength() -> Data { item(0x51, Data([0, 0, 0x40, 0])) }

    static func userInformation(_ subItems: Data) -> Data { item(0x50, subItems) }

    static func userIdentity(primary: String, secondary: String) -> Data {
        let type: UInt8 = secondary.isEmpty ? 1 : 2
        return item(0x58, Data([type, 0]) + bigEndian16(primary.utf8.count) + Data(primary.utf8)
            + bigEndian16(secondary.utf8.count) + Data(secondary.utf8))
    }
}

/// Hands the scripted PDUs in order and records what the other side writes.
private final class DULQueueTransport: DicomAssociationTransport {
    private var input: [Data]
    private(set) var written: [Data] = []
    var isOpen: Bool { true }

    init(input: [Data]) { self.input = input }

    func readPDU() throws -> Data {
        guard !input.isEmpty else { throw DicomNetworkError.networkUnavailable("closed") }
        return input.removeFirst()
    }

    func writePDU(_ data: Data) throws { written.append(data) }

    func lastAbort() throws -> DicomAbort? {
        guard let data = written.last(where: { $0.first == DicomPDUType.abort.rawValue }),
              case .abort(let abort) = try DicomPDUCodec.decode(data) else { return nil }
        return abort
    }
}

/// A Verification SCP that answers each request PDU with its script.
private final class DULEchoPeer: DicomCancellableAssociationTransport {
    private var pending: [Data] = []
    private let responseToEcho: [Data]?
    private let responseToRelease: [Data]
    private let responseToReleaseResponse: [Data]
    private(set) var written: [Data] = []
    private(set) var releaseResponsesReceived = 0
    private var closed = false
    var isOpen: Bool { !closed }

    init(responseToEcho: [Data]? = nil, responseToRelease: [Data] = [],
         responseToReleaseResponse: [Data] = []) {
        self.responseToEcho = responseToEcho
        self.responseToRelease = responseToRelease.isEmpty
            ? [(try? DicomPDUCodec.encode(.releaseResponse)) ?? Data()] : responseToRelease
        self.responseToReleaseResponse = responseToReleaseResponse
    }

    func close() { closed = true }

    func readPDU() throws -> Data {
        guard !pending.isEmpty else { throw DicomNetworkError.networkUnavailable("closed") }
        return pending.removeFirst()
    }

    func writePDU(_ data: Data) throws {
        written.append(data)
        switch try DicomPDUCodec.decode(data) {
        case .associationRequest(let request):
            let accept = DicomAssociationNegotiator.accept(
                request, supportedAbstractSyntaxUIDs: [DicomNetworkUID.verificationSOPClass],
                preferredTransferSyntaxes: [.implicitVRLittleEndian, .explicitVRLittleEndian],
                maximumPDULength: 16_384
            )
            pending.append(try DicomPDUCodec.encode(.associationAccept(accept)))
        case .pData(let pdvs):
            guard let pdv = pdvs.first, pdv.isCommand, pdv.isLastFragment else { return }
            if let responseToEcho { pending += responseToEcho; return }
            let request = try DicomDIMSECommandSet.decode(pdv.data)
            let response = DicomDIMSECommandSet(
                affectedSOPClassUID: DicomNetworkUID.verificationSOPClass,
                commandField: DicomDIMSECommandField.cEchoRSP,
                messageIDBeingRespondedTo: request.messageID,
                commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
                status: 0
            )
            pending.append(try DicomPDUCodec.encode(.pData([DicomPDV(
                presentationContextID: pdv.presentationContextID, isCommand: true, isLastFragment: true,
                data: response.encoded()
            )])))
        case .releaseRequest:
            pending += responseToRelease
        case .releaseResponse:
            releaseResponsesReceived += 1
            pending += responseToReleaseResponse
        default:
            break
        }
    }

    func lastAbort() throws -> DicomAbort? {
        guard let data = written.last(where: { $0.first == DicomPDUType.abort.rawValue }),
              case .abort(let abort) = try DicomPDUCodec.decode(data) else { return nil }
        return abort
    }
}
