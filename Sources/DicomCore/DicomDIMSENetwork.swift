import Foundation

public enum DicomNetworkError: Error, Equatable, Sendable {
    case invalidAEString(String)
    case invalidPDUType(UInt8)
    case invalidPDULength(expected: Int, actual: Int)
    case invalidItemType(UInt8)
    case invalidPresentationContextID(UInt8)
    case missingApplicationContext
    case missingPresentationContext
    case missingTransferSyntax
    case associationRejected(DicomAssociationReject)
    case associationAborted(DicomAbort)
    case invalidAssociationState(expected: DicomAssociationState, actual: DicomAssociationState)
    case unsupportedPDU(DicomPDUType)
    case malformedCommandSet(String)
    case missingAcceptedPresentationContext(String)
    case transferSyntaxMismatch(expected: String, actual: String)
    case unexpectedDIMSECommand(expected: UInt16, actual: UInt16)
    case dimseStatusFailure(UInt16)
    case networkTimeout(String)
    case networkUnavailable(String)
    case tlsConfigurationInvalid(String)
    case tlsTrustEvaluationFailed(String)
    case circuitBreakerOpen(String)
    case operationCancelled(String)
    /// User identity negotiation was configured without TLS.
    case insecureUserIdentityTransport
}

extension DicomNetworkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidAEString(let value):
            return "Invalid AE title: \(value)"
        case .invalidPDUType(let type):
            return String(format: "Unsupported DIMSE PDU type 0x%02X.", type)
        case .invalidPDULength(let expected, let actual):
            return "Invalid DIMSE PDU length. Expected \(expected) bytes, got \(actual)."
        case .invalidItemType(let type):
            return String(format: "Unsupported DIMSE association item type 0x%02X.", type)
        case .invalidPresentationContextID(let id):
            return "Invalid presentation context ID \(id)."
        case .missingApplicationContext:
            return "A-ASSOCIATE PDU is missing an application context item."
        case .missingPresentationContext:
            return "A-ASSOCIATE PDU is missing a presentation context."
        case .missingTransferSyntax:
            return "Presentation context is missing a transfer syntax."
        case .associationRejected(let reject):
            return "Association rejected by peer: \(reject.reason)."
        case .associationAborted(let abort):
            return "Association aborted by peer: \(abort.reason)."
        case .invalidAssociationState(let expected, let actual):
            return "Invalid association state \(actual); expected \(expected)."
        case .unsupportedPDU(let type):
            return "PDU \(type) is not valid for this association operation."
        case .malformedCommandSet(let reason):
            return "Malformed DIMSE command set: \(reason)."
        case .missingAcceptedPresentationContext(let uid):
            return "No accepted presentation context for SOP Class \(uid)."
        case .transferSyntaxMismatch(let expected, let actual):
            return "Accepted transfer syntax \(actual) does not match required transfer syntax \(expected)."
        case .unexpectedDIMSECommand(let expected, let actual):
            return String(format: "Unexpected DIMSE command 0x%04X; expected 0x%04X.", actual, expected)
        case .dimseStatusFailure(let status):
            return String(format: "DIMSE operation failed with status 0x%04X.", status)
        case .networkTimeout(let operation):
            return "DIMSE network timeout while \(operation)."
        case .networkUnavailable(let reason):
            return "DIMSE network transport is unavailable: \(reason)."
        case .tlsConfigurationInvalid(let reason):
            return "DIMSE TLS configuration is invalid: \(reason)."
        case .tlsTrustEvaluationFailed(let reason):
            return "DIMSE TLS trust evaluation failed: \(reason)."
        case .circuitBreakerOpen(let operation):
            return "DIMSE circuit breaker is open for \(operation)."
        case .operationCancelled(let operation):
            return "DIMSE operation \(operation) was cancelled."
        case .insecureUserIdentityTransport:
            return "DIMSE user identity negotiation requires TLS."
        }
    }
}

public enum DicomPDUType: UInt8, Equatable, Sendable {
    case associationRequest = 0x01
    case associationAccept = 0x02
    case associationReject = 0x03
    case pData = 0x04
    case releaseRequest = 0x05
    case releaseResponse = 0x06
    case abort = 0x07
}

public enum DicomNetworkUID {
    public static let applicationContext = "1.2.840.10008.3.1.1.1"
    public static let verificationSOPClass = "1.2.840.10008.1.1"
    public static let studyRootQueryRetrieveFind = "1.2.840.10008.5.1.4.1.2.2.1"
    public static let studyRootQueryRetrieveMove = "1.2.840.10008.5.1.4.1.2.2.2"
    public static let studyRootQueryRetrieveGet = "1.2.840.10008.5.1.4.1.2.2.3"
    public static let modalityWorklistInformationModelFind = "1.2.840.10008.5.1.4.31"
    public static let modalityPerformedProcedureStepSOPClass = "1.2.840.10008.3.1.2.3.3"
    public static let basicGrayscalePrintManagementMetaSOPClass = "1.2.840.10008.5.1.1.9"
    public static let basicFilmSessionSOPClass = "1.2.840.10008.5.1.1.1"
    public static let basicFilmBoxSOPClass = "1.2.840.10008.5.1.1.2"
    public static let basicGrayscaleImageBoxSOPClass = "1.2.840.10008.5.1.1.4"
    public static let printerSOPClass = "1.2.840.10008.5.1.1.16"
    public static let printerSOPInstance = "1.2.840.10008.5.1.1.17"
    public static let storageCommitmentPushModelSOPClass = "1.2.840.10008.1.20.1"
    public static let storageCommitmentPushModelSOPInstance = "1.2.840.10008.1.20.1.1"
    public static let implementationClass = DicomDataSetWriter.defaultImplementationClassUID
    public static let implementationVersion = "DICOMCORE_1"
}

public struct DicomPresentationContextRequest: Equatable, Sendable {
    public var id: UInt8
    public var abstractSyntaxUID: String
    public var transferSyntaxUIDs: [String]

    public init(id: UInt8,
                abstractSyntaxUID: String,
                transferSyntaxUIDs: [String]) {
        self.id = id
        self.abstractSyntaxUID = abstractSyntaxUID
        self.transferSyntaxUIDs = transferSyntaxUIDs
    }

    public init(id: UInt8,
                abstractSyntaxUID: String,
                transferSyntaxes: [DicomTransferSyntax]) {
        self.init(id: id,
                  abstractSyntaxUID: abstractSyntaxUID,
                  transferSyntaxUIDs: transferSyntaxes.map(\.rawValue))
    }
}

public enum DicomPresentationContextResult: UInt8, Equatable, Sendable {
    case acceptance = 0x00
    case userRejection = 0x01
    case noReason = 0x02
    case abstractSyntaxNotSupported = 0x03
    case transferSyntaxNotSupported = 0x04
}

public struct DicomPresentationContextAccept: Equatable, Sendable {
    public var id: UInt8
    public var result: DicomPresentationContextResult
    public var transferSyntaxUID: String?

    public init(id: UInt8,
                result: DicomPresentationContextResult,
                transferSyntaxUID: String?) {
        self.id = id
        self.result = result
        self.transferSyntaxUID = transferSyntaxUID
    }

    public init(id: UInt8,
                result: DicomPresentationContextResult,
                transferSyntax: DicomTransferSyntax?) {
        self.init(id: id,
                  result: result,
                  transferSyntaxUID: transferSyntax?.rawValue)
    }

    public var transferSyntax: DicomTransferSyntax? {
        transferSyntaxUID.flatMap(DicomTransferSyntax.init(uid:))
    }
}

public struct DicomAssociationRequest: Equatable, Sendable {
    public var calledAETitle: String
    public var callingAETitle: String
    public var applicationContextUID: String
    public var presentationContexts: [DicomPresentationContextRequest]
    public var maximumPDULength: UInt32
    public var implementationClassUID: String
    public var implementationVersionName: String?
    public var userIdentity: DicomUserIdentity?

    public init(calledAETitle: String,
                callingAETitle: String,
                applicationContextUID: String = DicomNetworkUID.applicationContext,
                presentationContexts: [DicomPresentationContextRequest],
                maximumPDULength: UInt32 = 16_384,
                implementationClassUID: String = DicomNetworkUID.implementationClass,
                implementationVersionName: String? = DicomNetworkUID.implementationVersion,
                userIdentity: DicomUserIdentity? = nil) {
        self.calledAETitle = calledAETitle
        self.callingAETitle = callingAETitle
        self.applicationContextUID = applicationContextUID
        self.presentationContexts = presentationContexts
        self.maximumPDULength = maximumPDULength
        self.implementationClassUID = implementationClassUID
        self.implementationVersionName = implementationVersionName
        self.userIdentity = userIdentity
    }
}

public struct DicomAssociationAccept: Equatable, Sendable {
    public var calledAETitle: String
    public var callingAETitle: String
    public var applicationContextUID: String
    public var presentationContexts: [DicomPresentationContextAccept]
    public var maximumPDULength: UInt32
    public var implementationClassUID: String?
    public var implementationVersionName: String?

    public init(calledAETitle: String,
                callingAETitle: String,
                applicationContextUID: String = DicomNetworkUID.applicationContext,
                presentationContexts: [DicomPresentationContextAccept],
                maximumPDULength: UInt32 = 16_384,
                implementationClassUID: String? = DicomNetworkUID.implementationClass,
                implementationVersionName: String? = DicomNetworkUID.implementationVersion) {
        self.calledAETitle = calledAETitle
        self.callingAETitle = callingAETitle
        self.applicationContextUID = applicationContextUID
        self.presentationContexts = presentationContexts
        self.maximumPDULength = maximumPDULength
        self.implementationClassUID = implementationClassUID
        self.implementationVersionName = implementationVersionName
    }
}

public enum DicomAssociationRejectResult: UInt8, Equatable, Sendable {
    case rejectedPermanent = 0x01
    case rejectedTransient = 0x02
}

public enum DicomAssociationRejectSource: UInt8, Equatable, Sendable {
    case serviceUser = 0x01
    case serviceProviderACSE = 0x02
    case serviceProviderPresentation = 0x03
}

public enum DicomAssociationRejectReason: UInt8, Equatable, Sendable {
    case noReason = 0x01
    case applicationContextNotSupported = 0x02
    case callingAENotRecognized = 0x03
    case calledAENotRecognized = 0x07
}

public struct DicomAssociationReject: Equatable, Sendable {
    public var result: DicomAssociationRejectResult
    public var source: DicomAssociationRejectSource
    public var reason: DicomAssociationRejectReason

    public init(result: DicomAssociationRejectResult,
                source: DicomAssociationRejectSource,
                reason: DicomAssociationRejectReason) {
        self.result = result
        self.source = source
        self.reason = reason
    }
}

public enum DicomAbortSource: UInt8, Equatable, Sendable {
    case serviceUser = 0x00
    case serviceProvider = 0x02
}

public enum DicomAbortReason: UInt8, Equatable, Sendable {
    case reasonNotSpecified = 0x00
    case unrecognizedPDU = 0x01
    case unexpectedPDU = 0x02
    case reserved = 0x03
    case unrecognizedPDUParameter = 0x04
    case unexpectedPDUParameter = 0x05
    case invalidPDUParameterValue = 0x06
}

public struct DicomAbort: Equatable, Sendable {
    public var source: DicomAbortSource
    public var reason: DicomAbortReason

    public init(source: DicomAbortSource,
                reason: DicomAbortReason) {
        self.source = source
        self.reason = reason
    }
}

public struct DicomPDV: Equatable, Sendable {
    public var presentationContextID: UInt8
    public var isCommand: Bool
    public var isLastFragment: Bool
    public var data: Data

    public init(presentationContextID: UInt8,
                isCommand: Bool,
                isLastFragment: Bool,
                data: Data) {
        self.presentationContextID = presentationContextID
        self.isCommand = isCommand
        self.isLastFragment = isLastFragment
        self.data = data
    }
}

public enum DicomPDU: Equatable, Sendable {
    case associationRequest(DicomAssociationRequest)
    case associationAccept(DicomAssociationAccept)
    case associationReject(DicomAssociationReject)
    case pData([DicomPDV])
    case releaseRequest
    case releaseResponse
    case abort(DicomAbort)

    public var type: DicomPDUType {
        switch self {
        case .associationRequest:
            return .associationRequest
        case .associationAccept:
            return .associationAccept
        case .associationReject:
            return .associationReject
        case .pData:
            return .pData
        case .releaseRequest:
            return .releaseRequest
        case .releaseResponse:
            return .releaseResponse
        case .abort:
            return .abort
        }
    }
}

public enum DicomPDUCodec {
    public static func encode(_ pdu: DicomPDU) throws -> Data {
        let body: Data
        switch pdu {
        case .associationRequest(let request):
            body = try encodeAssociationRequest(request)
        case .associationAccept(let accept):
            body = try encodeAssociationAccept(accept)
        case .associationReject(let reject):
            body = encodeAssociationReject(reject)
        case .pData(let pdvs):
            return encodePData(pdvs)
        case .releaseRequest, .releaseResponse:
            body = Data(repeating: 0, count: 4)
        case .abort(let abort):
            body = encodeAbort(abort)
        }

        var data = Data()
        data.append(pdu.type.rawValue)
        data.append(0x00)
        appendUInt32BE(UInt32(body.count), to: &data)
        data.append(body)
        return data
    }

    public static func decode(_ data: Data) throws -> DicomPDU {
        var cursor = DicomNetworkCursor(data: data)
        let typeByte = try cursor.readUInt8()
        _ = try cursor.readUInt8()
        let length = Int(try cursor.readUInt32BE())
        guard cursor.remaining == length else {
            throw DicomNetworkError.invalidPDULength(expected: length, actual: cursor.remaining)
        }
        guard let type = DicomPDUType(rawValue: typeByte) else {
            throw DicomNetworkError.invalidPDUType(typeByte)
        }
        let body = try cursor.readData(count: length)
        var bodyCursor = DicomNetworkCursor(data: body)

        switch type {
        case .associationRequest:
            return .associationRequest(try decodeAssociationRequest(&bodyCursor))
        case .associationAccept:
            return .associationAccept(try decodeAssociationAccept(&bodyCursor))
        case .associationReject:
            return .associationReject(try decodeAssociationReject(&bodyCursor))
        case .pData:
            return .pData(try decodePData(&bodyCursor))
        case .releaseRequest:
            guard bodyCursor.remaining == 4 else {
                throw DicomNetworkError.invalidPDULength(expected: 4, actual: bodyCursor.remaining)
            }
            try bodyCursor.skip(count: 4)
            return .releaseRequest
        case .releaseResponse:
            guard bodyCursor.remaining == 4 else {
                throw DicomNetworkError.invalidPDULength(expected: 4, actual: bodyCursor.remaining)
            }
            try bodyCursor.skip(count: 4)
            return .releaseResponse
        case .abort:
            return .abort(try decodeAbort(&bodyCursor))
        }
    }
}

public enum DicomAssociationNegotiator {
    public static func accept(_ request: DicomAssociationRequest,
                              supportedAbstractSyntaxUIDs: Set<String>,
                              preferredTransferSyntaxes: [DicomTransferSyntax]) -> DicomAssociationAccept {
        let preferredUIDs = preferredTransferSyntaxes.map(\.rawValue)
        let contexts = request.presentationContexts.map { context -> DicomPresentationContextAccept in
            guard supportedAbstractSyntaxUIDs.contains(context.abstractSyntaxUID) else {
                return DicomPresentationContextAccept(id: context.id,
                                                      result: .abstractSyntaxNotSupported,
                                                      transferSyntaxUID: nil)
            }
            guard let selected = preferredUIDs.first(where: { context.transferSyntaxUIDs.contains($0) }) else {
                return DicomPresentationContextAccept(id: context.id,
                                                      result: .transferSyntaxNotSupported,
                                                      transferSyntaxUID: nil)
            }
            return DicomPresentationContextAccept(id: context.id,
                                                  result: .acceptance,
                                                  transferSyntaxUID: selected)
        }
        return DicomAssociationAccept(calledAETitle: request.calledAETitle,
                                      callingAETitle: request.callingAETitle,
                                      applicationContextUID: request.applicationContextUID,
                                      presentationContexts: contexts,
                                      maximumPDULength: request.maximumPDULength)
    }
}

public enum DicomAssociationState: Equatable, Sendable {
    case idle
    case associationRequested
    case associated
    case releaseRequested
    case released
    case rejected(DicomAssociationReject)
    case aborted(DicomAbort)
}

public struct DicomAssociationStateMachine: Equatable, Sendable {
    public private(set) var state: DicomAssociationState

    public init(state: DicomAssociationState = .idle) {
        self.state = state
    }

    public mutating func sendAssociationRequest() throws {
        guard state == .idle else {
            throw DicomNetworkError.invalidAssociationState(expected: .idle, actual: state)
        }
        state = .associationRequested
    }

    public mutating func receiveAssociationAccept() throws {
        guard state == .associationRequested else {
            throw DicomNetworkError.invalidAssociationState(expected: .associationRequested, actual: state)
        }
        state = .associated
    }

    public mutating func receiveAssociationReject(_ reject: DicomAssociationReject) throws {
        guard state == .associationRequested else {
            throw DicomNetworkError.invalidAssociationState(expected: .associationRequested, actual: state)
        }
        state = .rejected(reject)
    }

    public mutating func sendReleaseRequest() throws {
        guard state == .associated else {
            throw DicomNetworkError.invalidAssociationState(expected: .associated, actual: state)
        }
        state = .releaseRequested
    }

    public mutating func receiveReleaseRequest() throws {
        guard state == .associated else {
            throw DicomNetworkError.invalidAssociationState(expected: .associated, actual: state)
        }
        state = .released
    }

    public mutating func receiveReleaseResponse() throws {
        guard state == .releaseRequested else {
            throw DicomNetworkError.invalidAssociationState(expected: .releaseRequested, actual: state)
        }
        state = .released
    }

    public mutating func receiveAbort(_ abort: DicomAbort) {
        state = .aborted(abort)
    }

    public func validatePDataAllowed() throws {
        guard state == .associated else {
            throw DicomNetworkError.invalidAssociationState(expected: .associated, actual: state)
        }
    }
}

public protocol DicomAssociationTransport: AnyObject {
    var isOpen: Bool { get }
    func writePDU(_ data: Data) throws
    func readPDU() throws -> Data
}

public extension DicomAssociationTransport {
    var isOpen: Bool { true }
}

public protocol DicomCancellableAssociationTransport: DicomAssociationTransport {
    func close()
}

public struct DicomAssociationSCU: Sendable {
    public var request: DicomAssociationRequest

    public init(request: DicomAssociationRequest) {
        self.request = request
    }

    public func open(using transport: DicomAssociationTransport) throws -> DicomAssociation {
        var stateMachine = DicomAssociationStateMachine()
        try stateMachine.sendAssociationRequest()
        try transport.writePDU(DicomPDUCodec.encode(.associationRequest(request)))

        let response = try DicomPDUCodec.decode(try transport.readPDU())
        switch response {
        case .associationAccept(let accept):
            try stateMachine.receiveAssociationAccept()
            return DicomAssociation(request: request,
                                    accept: accept,
                                    stateMachine: stateMachine)
        case .associationReject(let reject):
            try stateMachine.receiveAssociationReject(reject)
            throw DicomNetworkError.associationRejected(reject)
        case .abort(let abort):
            stateMachine.receiveAbort(abort)
            throw DicomNetworkError.associationAborted(abort)
        default:
            throw DicomNetworkError.unsupportedPDU(response.type)
        }
    }
}

public struct DicomAcceptedPresentationContext: Equatable, Sendable {
    public var id: UInt8
    public var abstractSyntaxUID: String
    public var transferSyntaxUID: String

    public init(id: UInt8,
                abstractSyntaxUID: String,
                transferSyntaxUID: String) {
        self.id = id
        self.abstractSyntaxUID = abstractSyntaxUID
        self.transferSyntaxUID = transferSyntaxUID
    }

    public var transferSyntax: DicomTransferSyntax? {
        DicomTransferSyntax(uid: transferSyntaxUID)
    }
}

public struct DicomAssociation: Equatable, Sendable {
    public var request: DicomAssociationRequest
    public var accept: DicomAssociationAccept
    public var stateMachine: DicomAssociationStateMachine

    public init(request: DicomAssociationRequest,
                accept: DicomAssociationAccept,
                stateMachine: DicomAssociationStateMachine = DicomAssociationStateMachine(state: .associated)) {
        self.request = request
        self.accept = accept
        self.stateMachine = stateMachine
    }

    public var acceptedPresentationContexts: [DicomAcceptedPresentationContext] {
        accept.presentationContexts.compactMap { accepted in
            guard accepted.result == .acceptance,
                  let transferSyntaxUID = accepted.transferSyntaxUID,
                  let requested = request.presentationContexts.first(where: { $0.id == accepted.id }) else {
                return nil
            }
            return DicomAcceptedPresentationContext(id: accepted.id,
                                                   abstractSyntaxUID: requested.abstractSyntaxUID,
                                                   transferSyntaxUID: transferSyntaxUID)
        }
    }

    public func acceptedPresentationContext(for abstractSyntaxUID: String) -> DicomAcceptedPresentationContext? {
        acceptedPresentationContexts.first { $0.abstractSyntaxUID == abstractSyntaxUID }
    }

    public func commandPData(_ commandSet: DicomDIMSECommandSet,
                             presentationContextID: UInt8) throws -> DicomPDU {
        try stateMachine.validatePDataAllowed()
        guard acceptedPresentationContexts.contains(where: { $0.id == presentationContextID }) else {
            throw DicomNetworkError.invalidPresentationContextID(presentationContextID)
        }
        return .pData([
            DicomPDV(presentationContextID: presentationContextID,
                    isCommand: true,
                    isLastFragment: true,
                    data: try commandSet.encoded())
        ])
    }

    public func dataSetPData(_ data: Data,
                             presentationContextID: UInt8,
                             isLastFragment: Bool = true) throws -> DicomPDU {
        try stateMachine.validatePDataAllowed()
        guard acceptedPresentationContexts.contains(where: { $0.id == presentationContextID }) else {
            throw DicomNetworkError.invalidPresentationContextID(presentationContextID)
        }
        return .pData([
            DicomPDV(presentationContextID: presentationContextID,
                    isCommand: false,
                    isLastFragment: isLastFragment,
                    data: data)
        ])
    }
}

public enum DicomDIMSECommandDataSetType {
    public static let hasDataSet: UInt16 = 0x0000
    public static let noDataSet: UInt16 = 0x0101
}

public enum DicomDIMSECommandField {
    public static let cStoreRQ: UInt16 = 0x0001
    public static let cStoreRSP: UInt16 = 0x8001
    public static let cGetRQ: UInt16 = 0x0010
    public static let cGetRSP: UInt16 = 0x8010
    public static let cFindRQ: UInt16 = 0x0020
    public static let cFindRSP: UInt16 = 0x8020
    public static let cMoveRQ: UInt16 = 0x0021
    public static let cMoveRSP: UInt16 = 0x8021
    public static let cEchoRQ: UInt16 = 0x0030
    public static let cEchoRSP: UInt16 = 0x8030
    public static let nEventReportRQ: UInt16 = 0x0100
    public static let nEventReportRSP: UInt16 = 0x8100
    public static let nSetRQ: UInt16 = 0x0120
    public static let nSetRSP: UInt16 = 0x8120
    public static let nActionRQ: UInt16 = 0x0130
    public static let nActionRSP: UInt16 = 0x8130
    public static let nCreateRQ: UInt16 = 0x0140
    public static let nCreateRSP: UInt16 = 0x8140
    public static let cCancelRQ: UInt16 = 0x0FFF
}

public struct DicomDIMSECommandSet: Equatable, Sendable {
    public var affectedSOPClassUID: String?
    public var requestedSOPClassUID: String?
    public var commandField: UInt16
    public var messageID: UInt16?
    public var messageIDBeingRespondedTo: UInt16?
    public var commandDataSetType: UInt16
    public var status: UInt16?
    public var errorComment: String?
    public var moveDestination: String?
    public var priority: UInt16?
    public var affectedSOPInstanceUID: String?
    public var requestedSOPInstanceUID: String?
    public var eventTypeID: UInt16?
    public var actionTypeID: UInt16?
    public var remainingSuboperations: UInt16?
    public var completedSuboperations: UInt16?
    public var failedSuboperations: UInt16?
    public var warningSuboperations: UInt16?

    public init(affectedSOPClassUID: String? = nil,
                requestedSOPClassUID: String? = nil,
                commandField: UInt16,
                messageID: UInt16? = nil,
                messageIDBeingRespondedTo: UInt16? = nil,
                commandDataSetType: UInt16 = DicomDIMSECommandDataSetType.noDataSet,
                status: UInt16? = nil,
                errorComment: String? = nil,
                moveDestination: String? = nil,
                priority: UInt16? = nil,
                affectedSOPInstanceUID: String? = nil,
                requestedSOPInstanceUID: String? = nil,
                eventTypeID: UInt16? = nil,
                actionTypeID: UInt16? = nil,
                remainingSuboperations: UInt16? = nil,
                completedSuboperations: UInt16? = nil,
                failedSuboperations: UInt16? = nil,
                warningSuboperations: UInt16? = nil) {
        self.affectedSOPClassUID = affectedSOPClassUID
        self.requestedSOPClassUID = requestedSOPClassUID
        self.commandField = commandField
        self.messageID = messageID
        self.messageIDBeingRespondedTo = messageIDBeingRespondedTo
        self.commandDataSetType = commandDataSetType
        self.status = status
        self.errorComment = errorComment
        self.moveDestination = moveDestination
        self.priority = priority
        self.affectedSOPInstanceUID = affectedSOPInstanceUID
        self.requestedSOPInstanceUID = requestedSOPInstanceUID
        self.eventTypeID = eventTypeID
        self.actionTypeID = actionTypeID
        self.remainingSuboperations = remainingSuboperations
        self.completedSuboperations = completedSuboperations
        self.failedSuboperations = failedSuboperations
        self.warningSuboperations = warningSuboperations
    }

    public func encoded() throws -> Data {
        var payload = Data()
        if let affectedSOPClassUID {
            appendCommandElement(tag: 0x0000_0002,
                                 value: uiData(affectedSOPClassUID),
                                 to: &payload)
        }
        if let requestedSOPClassUID {
            appendCommandElement(tag: 0x0000_0003,
                                 value: uiData(requestedSOPClassUID),
                                 to: &payload)
        }
        if let moveDestination {
            appendCommandElement(tag: 0x0000_0600,
                                 value: commandStringData(moveDestination),
                                 to: &payload)
        }
        appendCommandElement(tag: 0x0000_0100,
                             value: uint16LEData(commandField),
                             to: &payload)
        if let messageID {
            appendCommandElement(tag: 0x0000_0110,
                                 value: uint16LEData(messageID),
                                 to: &payload)
        }
        if let messageIDBeingRespondedTo {
            appendCommandElement(tag: 0x0000_0120,
                                 value: uint16LEData(messageIDBeingRespondedTo),
                                 to: &payload)
        }
        if let priority {
            appendCommandElement(tag: 0x0000_0700,
                                 value: uint16LEData(priority),
                                 to: &payload)
        }
        appendCommandElement(tag: 0x0000_0800,
                             value: uint16LEData(commandDataSetType),
                             to: &payload)
        if let status {
            appendCommandElement(tag: 0x0000_0900,
                                 value: uint16LEData(status),
                                 to: &payload)
        }
        if let errorComment {
            appendCommandElement(tag: 0x0000_0902,
                                 value: commandStringData(errorComment),
                                 to: &payload)
        }
        if let affectedSOPInstanceUID {
            appendCommandElement(tag: 0x0000_1000,
                                 value: uiData(affectedSOPInstanceUID),
                                 to: &payload)
        }
        if let requestedSOPInstanceUID {
            appendCommandElement(tag: 0x0000_1001,
                                 value: uiData(requestedSOPInstanceUID),
                                 to: &payload)
        }
        if let eventTypeID {
            appendCommandElement(tag: 0x0000_1002,
                                 value: uint16LEData(eventTypeID),
                                 to: &payload)
        }
        if let actionTypeID {
            appendCommandElement(tag: 0x0000_1008,
                                 value: uint16LEData(actionTypeID),
                                 to: &payload)
        }
        if let remainingSuboperations {
            appendCommandElement(tag: 0x0000_1020,
                                 value: uint16LEData(remainingSuboperations),
                                 to: &payload)
        }
        if let completedSuboperations {
            appendCommandElement(tag: 0x0000_1021,
                                 value: uint16LEData(completedSuboperations),
                                 to: &payload)
        }
        if let failedSuboperations {
            appendCommandElement(tag: 0x0000_1022,
                                 value: uint16LEData(failedSuboperations),
                                 to: &payload)
        }
        if let warningSuboperations {
            appendCommandElement(tag: 0x0000_1023,
                                 value: uint16LEData(warningSuboperations),
                                 to: &payload)
        }

        var data = Data()
        appendCommandElement(tag: 0x0000_0000,
                             value: uint32LEData(UInt32(payload.count)),
                             to: &data)
        data.append(payload)
        return data
    }

    public static func decode(_ data: Data) throws -> DicomDIMSECommandSet {
        var cursor = DicomNetworkCursor(data: data)
        var affectedSOPClassUID: String?
        var requestedSOPClassUID: String?
        var commandField: UInt16?
        var messageID: UInt16?
        var messageIDBeingRespondedTo: UInt16?
        var commandDataSetType: UInt16?
        var status: UInt16?
        var errorComment: String?
        var moveDestination: String?
        var priority: UInt16?
        var affectedSOPInstanceUID: String?
        var requestedSOPInstanceUID: String?
        var eventTypeID: UInt16?
        var actionTypeID: UInt16?
        var remainingSuboperations: UInt16?
        var completedSuboperations: UInt16?
        var failedSuboperations: UInt16?
        var warningSuboperations: UInt16?

        while cursor.remaining > 0 {
            let tag = try cursor.readTagLE()
            let length = Int(try cursor.readUInt32LE())
            let value = try cursor.readData(count: length)
            switch tag {
            case 0x0000_0000:
                continue
            case 0x0000_0002:
                affectedSOPClassUID = value.dicomCommandStringValue
            case 0x0000_0003:
                requestedSOPClassUID = value.dicomCommandStringValue
            case 0x0000_0600:
                moveDestination = value.dicomCommandStringValue
            case 0x0000_0100:
                commandField = try commandUInt16(value, tag: tag)
            case 0x0000_0110:
                messageID = try commandUInt16(value, tag: tag)
            case 0x0000_0120:
                messageIDBeingRespondedTo = try commandUInt16(value, tag: tag)
            case 0x0000_0700:
                priority = try commandUInt16(value, tag: tag)
            case 0x0000_0800:
                commandDataSetType = try commandUInt16(value, tag: tag)
            case 0x0000_0900:
                status = try commandUInt16(value, tag: tag)
            case 0x0000_0902:
                errorComment = value.dicomCommandStringValue
            case 0x0000_1000:
                affectedSOPInstanceUID = value.dicomCommandStringValue
            case 0x0000_1001:
                requestedSOPInstanceUID = value.dicomCommandStringValue
            case 0x0000_1002:
                eventTypeID = try commandUInt16(value, tag: tag)
            case 0x0000_1008:
                actionTypeID = try commandUInt16(value, tag: tag)
            case 0x0000_1020:
                remainingSuboperations = try commandUInt16(value, tag: tag)
            case 0x0000_1021:
                completedSuboperations = try commandUInt16(value, tag: tag)
            case 0x0000_1022:
                failedSuboperations = try commandUInt16(value, tag: tag)
            case 0x0000_1023:
                warningSuboperations = try commandUInt16(value, tag: tag)
            default:
                continue
            }
        }

        guard let commandField else {
            throw DicomNetworkError.malformedCommandSet("Command Field (0000,0100) is missing.")
        }
        guard let commandDataSetType else {
            throw DicomNetworkError.malformedCommandSet("Command Data Set Type (0000,0800) is missing.")
        }
        return DicomDIMSECommandSet(affectedSOPClassUID: affectedSOPClassUID,
                                    requestedSOPClassUID: requestedSOPClassUID,
                                    commandField: commandField,
                                    messageID: messageID,
                                    messageIDBeingRespondedTo: messageIDBeingRespondedTo,
                                    commandDataSetType: commandDataSetType,
                                    status: status,
                                    errorComment: errorComment,
                                    moveDestination: moveDestination,
                                    priority: priority,
                                    affectedSOPInstanceUID: affectedSOPInstanceUID,
                                    requestedSOPInstanceUID: requestedSOPInstanceUID,
                                    eventTypeID: eventTypeID,
                                    actionTypeID: actionTypeID,
                                    remainingSuboperations: remainingSuboperations,
                                    completedSuboperations: completedSuboperations,
                                    failedSuboperations: failedSuboperations,
                                    warningSuboperations: warningSuboperations)
    }
}

private extension DicomPDUCodec {
    static let applicationContextItem: UInt8 = 0x10
    static let presentationContextRequestItem: UInt8 = 0x20
    static let presentationContextAcceptItem: UInt8 = 0x21
    static let abstractSyntaxItem: UInt8 = 0x30
    static let transferSyntaxItem: UInt8 = 0x40
    static let userInformationItem: UInt8 = 0x50
    static let maximumLengthItem: UInt8 = 0x51
    static let implementationClassUIDItem: UInt8 = 0x52
    static let implementationVersionNameItem: UInt8 = 0x55
    static let userIdentityNegotiationItem: UInt8 = 0x58

    static func encodeAssociationRequest(_ request: DicomAssociationRequest) throws -> Data {
        try validateAE(request.calledAETitle)
        try validateAE(request.callingAETitle)
        try validatePresentationContexts(request.presentationContexts)

        var data = Data()
        appendUInt16BE(0x0001, to: &data)
        appendUInt16BE(0x0000, to: &data)
        data.append(paddedAE(request.calledAETitle))
        data.append(paddedAE(request.callingAETitle))
        data.append(Data(repeating: 0, count: 32))
        appendVariableItems(for: request, to: &data)
        return data
    }

    static func encodeAssociationAccept(_ accept: DicomAssociationAccept) throws -> Data {
        try validateAE(accept.calledAETitle)
        try validateAE(accept.callingAETitle)

        var data = Data()
        appendUInt16BE(0x0001, to: &data)
        appendUInt16BE(0x0000, to: &data)
        data.append(paddedAE(accept.calledAETitle))
        data.append(paddedAE(accept.callingAETitle))
        data.append(Data(repeating: 0, count: 32))
        appendItem(type: applicationContextItem, value: uidItemData(accept.applicationContextUID), to: &data)
        for context in accept.presentationContexts {
            var item = Data()
            item.append(context.id)
            item.append(0x00)
            item.append(context.result.rawValue)
            item.append(0x00)
            if let transferSyntaxUID = context.transferSyntaxUID {
                appendItem(type: transferSyntaxItem, value: uidItemData(transferSyntaxUID), to: &item)
            }
            appendItem(type: presentationContextAcceptItem, value: item, to: &data)
        }
        appendUserInformation(maximumPDULength: accept.maximumPDULength,
                              implementationClassUID: accept.implementationClassUID,
                              implementationVersionName: accept.implementationVersionName,
                              to: &data)
        return data
    }

    static func encodeAssociationReject(_ reject: DicomAssociationReject) -> Data {
        Data([0x00, reject.result.rawValue, reject.source.rawValue, reject.reason.rawValue])
    }

    static func encodePData(_ pdvs: [DicomPDV]) -> Data {
        let bodyLength = pdvs.reduce(into: 0) { length, pdv in
            length += 6 + pdv.data.count
        }
        var data = Data()
        data.reserveCapacity(6 + bodyLength)
        data.append(DicomPDUType.pData.rawValue)
        data.append(0x00)
        appendUInt32BE(UInt32(bodyLength), to: &data)
        for pdv in pdvs {
            appendUInt32BE(UInt32(pdv.data.count + 2), to: &data)
            data.append(pdv.presentationContextID)
            var control: UInt8 = 0
            if pdv.isCommand { control |= 0x01 }
            if pdv.isLastFragment { control |= 0x02 }
            data.append(control)
            data.append(pdv.data)
        }
        return data
    }

    static func encodeAbort(_ abort: DicomAbort) -> Data {
        Data([0x00, 0x00, abort.source.rawValue, abort.reason.rawValue])
    }

    static func decodeAssociationRequest(_ cursor: inout DicomNetworkCursor) throws -> DicomAssociationRequest {
        _ = try cursor.readUInt16BE()
        _ = try cursor.readUInt16BE()
        let calledAE = try cursor.readASCII(count: 16).trimmingCharacters(in: .whitespaces)
        let callingAE = try cursor.readASCII(count: 16).trimmingCharacters(in: .whitespaces)
        try cursor.skip(count: 32)

        var applicationContext: String?
        var presentationContexts: [DicomPresentationContextRequest] = []
        var maximumLength: UInt32 = 16_384
        var implementationClassUID = DicomNetworkUID.implementationClass
        var implementationVersionName: String?
        var userIdentity: DicomUserIdentity?

        while cursor.remaining > 0 {
            let item = try cursor.readItem()
            switch item.type {
            case applicationContextItem:
                applicationContext = item.value.dicomUIDItemValue
            case presentationContextRequestItem:
                presentationContexts.append(try decodePresentationContextRequest(item.value))
            case userInformationItem:
                let userInfo = try decodeUserInformation(item.value)
                maximumLength = userInfo.maximumPDULength ?? maximumLength
                implementationClassUID = userInfo.implementationClassUID ?? implementationClassUID
                implementationVersionName = userInfo.implementationVersionName
                userIdentity = userInfo.userIdentity
            default:
                throw DicomNetworkError.invalidItemType(item.type)
            }
        }

        guard let applicationContext else { throw DicomNetworkError.missingApplicationContext }
        guard !presentationContexts.isEmpty else { throw DicomNetworkError.missingPresentationContext }
        return DicomAssociationRequest(calledAETitle: calledAE,
                                       callingAETitle: callingAE,
                                       applicationContextUID: applicationContext,
                                       presentationContexts: presentationContexts,
                                       maximumPDULength: maximumLength,
                                       implementationClassUID: implementationClassUID,
                                       implementationVersionName: implementationVersionName,
                                       userIdentity: userIdentity)
    }

    static func decodeAssociationAccept(_ cursor: inout DicomNetworkCursor) throws -> DicomAssociationAccept {
        _ = try cursor.readUInt16BE()
        _ = try cursor.readUInt16BE()
        let calledAE = try cursor.readASCII(count: 16).trimmingCharacters(in: .whitespaces)
        let callingAE = try cursor.readASCII(count: 16).trimmingCharacters(in: .whitespaces)
        try cursor.skip(count: 32)

        var applicationContext: String?
        var presentationContexts: [DicomPresentationContextAccept] = []
        var maximumLength: UInt32 = 16_384
        var implementationClassUID: String?
        var implementationVersionName: String?

        while cursor.remaining > 0 {
            let item = try cursor.readItem()
            switch item.type {
            case applicationContextItem:
                applicationContext = item.value.dicomUIDItemValue
            case presentationContextAcceptItem:
                presentationContexts.append(try decodePresentationContextAccept(item.value))
            case userInformationItem:
                let userInfo = try decodeUserInformation(item.value)
                maximumLength = userInfo.maximumPDULength ?? maximumLength
                implementationClassUID = userInfo.implementationClassUID
                implementationVersionName = userInfo.implementationVersionName
            default:
                throw DicomNetworkError.invalidItemType(item.type)
            }
        }

        guard let applicationContext else { throw DicomNetworkError.missingApplicationContext }
        guard !presentationContexts.isEmpty else { throw DicomNetworkError.missingPresentationContext }
        return DicomAssociationAccept(calledAETitle: calledAE,
                                      callingAETitle: callingAE,
                                      applicationContextUID: applicationContext,
                                      presentationContexts: presentationContexts,
                                      maximumPDULength: maximumLength,
                                      implementationClassUID: implementationClassUID,
                                      implementationVersionName: implementationVersionName)
    }

    static func decodeAssociationReject(_ cursor: inout DicomNetworkCursor) throws -> DicomAssociationReject {
        guard cursor.remaining == 4 else {
            throw DicomNetworkError.invalidPDULength(expected: 4, actual: cursor.remaining)
        }
        _ = try cursor.readUInt8()
        let result = DicomAssociationRejectResult(rawValue: try cursor.readUInt8()) ?? .rejectedPermanent
        let source = DicomAssociationRejectSource(rawValue: try cursor.readUInt8()) ?? .serviceProviderACSE
        let reason = DicomAssociationRejectReason(rawValue: try cursor.readUInt8()) ?? .noReason
        return DicomAssociationReject(result: result, source: source, reason: reason)
    }

    static func decodePData(_ cursor: inout DicomNetworkCursor) throws -> [DicomPDV] {
        var pdvs: [DicomPDV] = []
        while cursor.remaining > 0 {
            let itemLength = Int(try cursor.readUInt32BE())
            guard itemLength >= 2 else {
                throw DicomNetworkError.invalidPDULength(expected: 2, actual: itemLength)
            }
            let contextID = try cursor.readUInt8()
            let control = try cursor.readUInt8()
            let fragment = try cursor.readData(count: itemLength - 2)
            pdvs.append(DicomPDV(presentationContextID: contextID,
                                 isCommand: (control & 0x01) != 0,
                                 isLastFragment: (control & 0x02) != 0,
                                 data: fragment))
        }
        return pdvs
    }

    static func decodeAbort(_ cursor: inout DicomNetworkCursor) throws -> DicomAbort {
        guard cursor.remaining == 4 else {
            throw DicomNetworkError.invalidPDULength(expected: 4, actual: cursor.remaining)
        }
        _ = try cursor.readUInt8()
        _ = try cursor.readUInt8()
        let source = DicomAbortSource(rawValue: try cursor.readUInt8()) ?? .serviceProvider
        let reason = DicomAbortReason(rawValue: try cursor.readUInt8()) ?? .reasonNotSpecified
        return DicomAbort(source: source, reason: reason)
    }

    static func appendVariableItems(for request: DicomAssociationRequest, to data: inout Data) {
        appendItem(type: applicationContextItem, value: uidItemData(request.applicationContextUID), to: &data)
        for context in request.presentationContexts {
            var item = Data()
            item.append(context.id)
            item.append(contentsOf: [0x00, 0x00, 0x00])
            appendItem(type: abstractSyntaxItem, value: uidItemData(context.abstractSyntaxUID), to: &item)
            for transferSyntaxUID in context.transferSyntaxUIDs {
                appendItem(type: transferSyntaxItem, value: uidItemData(transferSyntaxUID), to: &item)
            }
            appendItem(type: presentationContextRequestItem, value: item, to: &data)
        }
        appendUserInformation(maximumPDULength: request.maximumPDULength,
                              implementationClassUID: request.implementationClassUID,
                              implementationVersionName: request.implementationVersionName,
                              userIdentity: request.userIdentity,
                              to: &data)
    }

    static func appendUserInformation(maximumPDULength: UInt32,
                                      implementationClassUID: String?,
                                      implementationVersionName: String?,
                                      userIdentity: DicomUserIdentity? = nil,
                                      to data: inout Data) {
        var userInfo = Data()
        var maximumLength = Data()
        appendUInt32BE(maximumPDULength, to: &maximumLength)
        appendItem(type: maximumLengthItem, value: maximumLength, to: &userInfo)
        if let implementationClassUID {
            appendItem(type: implementationClassUIDItem,
                       value: uidItemData(implementationClassUID),
                       to: &userInfo)
        }
        if let implementationVersionName {
            appendItem(type: implementationVersionNameItem,
                       value: Data(implementationVersionName.utf8),
                       to: &userInfo)
        }
        if let userIdentity {
            appendItem(type: userIdentityNegotiationItem,
                       value: userIdentityItemData(userIdentity),
                       to: &userInfo)
        }
        appendItem(type: userInformationItem, value: userInfo, to: &data)
    }

    static func decodePresentationContextRequest(_ data: Data) throws -> DicomPresentationContextRequest {
        var cursor = DicomNetworkCursor(data: data)
        let id = try cursor.readUInt8()
        try cursor.skip(count: 3)
        var abstractSyntax: String?
        var transferSyntaxes: [String] = []
        while cursor.remaining > 0 {
            let item = try cursor.readItem()
            switch item.type {
            case abstractSyntaxItem:
                abstractSyntax = item.value.dicomUIDItemValue
            case transferSyntaxItem:
                transferSyntaxes.append(item.value.dicomUIDItemValue)
            default:
                throw DicomNetworkError.invalidItemType(item.type)
            }
        }
        guard let abstractSyntax else { throw DicomNetworkError.missingPresentationContext }
        guard !transferSyntaxes.isEmpty else { throw DicomNetworkError.missingTransferSyntax }
        return DicomPresentationContextRequest(id: id,
                                               abstractSyntaxUID: abstractSyntax,
                                               transferSyntaxUIDs: transferSyntaxes)
    }

    static func decodePresentationContextAccept(_ data: Data) throws -> DicomPresentationContextAccept {
        var cursor = DicomNetworkCursor(data: data)
        let id = try cursor.readUInt8()
        _ = try cursor.readUInt8()
        let result = DicomPresentationContextResult(rawValue: try cursor.readUInt8()) ?? .noReason
        _ = try cursor.readUInt8()
        var transferSyntax: String?
        while cursor.remaining > 0 {
            let item = try cursor.readItem()
            guard item.type == transferSyntaxItem else {
                throw DicomNetworkError.invalidItemType(item.type)
            }
            transferSyntax = item.value.dicomUIDItemValue
        }
        return DicomPresentationContextAccept(id: id,
                                              result: result,
                                              transferSyntaxUID: transferSyntax)
    }

    static func decodeUserInformation(_ data: Data) throws -> DicomUserInformation {
        var cursor = DicomNetworkCursor(data: data)
        var info = DicomUserInformation()
        while cursor.remaining > 0 {
            let item = try cursor.readItem()
            switch item.type {
            case maximumLengthItem:
                var valueCursor = DicomNetworkCursor(data: item.value)
                info.maximumPDULength = try valueCursor.readUInt32BE()
            case implementationClassUIDItem:
                info.implementationClassUID = item.value.dicomUIDItemValue
            case implementationVersionNameItem:
                info.implementationVersionName = item.value.dicomUIDItemValue
            case userIdentityNegotiationItem:
                info.userIdentity = try decodeUserIdentity(item.value)
            default:
                continue
            }
        }
        return info
    }

    static func decodeUserIdentity(_ data: Data) throws -> DicomUserIdentity {
        var cursor = DicomNetworkCursor(data: data)
        guard let type = DicomUserIdentityType(rawValue: try cursor.readUInt8()) else {
            throw DicomNetworkError.invalidItemType(data.first ?? 0)
        }
        let positiveResponseRequested = try cursor.readUInt8() != 0
        let primaryLength = Int(try cursor.readUInt16BE())
        let primary = try cursor.readData(count: primaryLength)
        let secondaryLength = Int(try cursor.readUInt16BE())
        let secondary = try cursor.readData(count: secondaryLength)
        return DicomUserIdentity(type: type,
                                 primaryField: primary,
                                 secondaryField: secondary,
                                 positiveResponseRequested: positiveResponseRequested)
    }

    static func validatePresentationContexts(_ contexts: [DicomPresentationContextRequest]) throws {
        guard !contexts.isEmpty else { throw DicomNetworkError.missingPresentationContext }
        for context in contexts {
            guard context.id > 0, context.id % 2 == 1 else {
                throw DicomNetworkError.invalidPresentationContextID(context.id)
            }
            guard !context.transferSyntaxUIDs.isEmpty else {
                throw DicomNetworkError.missingTransferSyntax
            }
        }
    }
}

private struct DicomUserInformation {
    var maximumPDULength: UInt32?
    var implementationClassUID: String?
    var implementationVersionName: String?
    var userIdentity: DicomUserIdentity?
}

private struct DicomNetworkItem {
    var type: UInt8
    var value: Data
}

private struct DicomNetworkCursor {
    var data: Data
    var offset: Data.Index

    init(data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var remaining: Int {
        data.distance(from: offset, to: data.endIndex)
    }

    mutating func readUInt8() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16BE() throws -> UInt16 {
        try require(2)
        let byteOffset = data.distance(from: data.startIndex, to: offset)
        guard let value = data.dicomIntegerIfPresent(at: byteOffset, as: UInt16.self, littleEndian: false) else {
            throw DicomNetworkError.invalidPDULength(expected: 2, actual: remaining)
        }
        offset += 2
        return value
    }

    mutating func readUInt32BE() throws -> UInt32 {
        try require(4)
        let byteOffset = data.distance(from: data.startIndex, to: offset)
        guard let value = data.dicomIntegerIfPresent(at: byteOffset, as: UInt32.self, littleEndian: false) else {
            throw DicomNetworkError.invalidPDULength(expected: 4, actual: remaining)
        }
        offset += 4
        return value
    }

    mutating func readUInt32LE() throws -> UInt32 {
        try require(4)
        let byteOffset = data.distance(from: data.startIndex, to: offset)
        guard let value = data.dicomIntegerIfPresent(at: byteOffset, as: UInt32.self, littleEndian: true) else {
            throw DicomNetworkError.invalidPDULength(expected: 4, actual: remaining)
        }
        offset += 4
        return value
    }

    mutating func readTagLE() throws -> Int {
        let group = try readUInt16LE()
        let element = try readUInt16LE()
        return Int(UInt32(group) << 16 | UInt32(element))
    }

    private mutating func readUInt16LE() throws -> UInt16 {
        try require(2)
        let byteOffset = data.distance(from: data.startIndex, to: offset)
        guard let value = data.dicomIntegerIfPresent(at: byteOffset, as: UInt16.self, littleEndian: true) else {
            throw DicomNetworkError.invalidPDULength(expected: 2, actual: remaining)
        }
        offset += 2
        return value
    }

    mutating func readData(count: Int) throws -> Data {
        try require(count)
        let range = offset..<(offset + count)
        offset += count
        return data[range]
    }

    mutating func readASCII(count: Int) throws -> String {
        String(decoding: try readData(count: count), as: UTF8.self)
    }

    mutating func readItem() throws -> DicomNetworkItem {
        let type = try readUInt8()
        _ = try readUInt8()
        let length = Int(try readUInt16BE())
        return DicomNetworkItem(type: type, value: try readData(count: length))
    }

    mutating func skip(count: Int) throws {
        try require(count)
        offset += count
    }

    func require(_ count: Int) throws {
        guard count >= 0, remaining >= count else {
            throw DicomNetworkError.invalidPDULength(expected: count, actual: max(remaining, 0))
        }
    }
}

private func appendItem(type: UInt8, value: Data, to data: inout Data) {
    data.append(type)
    data.append(0x00)
    appendUInt16BE(UInt16(value.count), to: &data)
    data.append(value)
}

private func validateAE(_ value: String) throws {
    let bytes = Array(normalizedAE(value).utf8)
    guard !bytes.isEmpty, bytes.count <= 16, bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
        throw DicomNetworkError.invalidAEString(value)
    }
}

private func paddedAE(_ value: String) -> Data {
    var data = Data(normalizedAE(value).utf8.prefix(16))
    if data.count < 16 {
        data.append(Data(repeating: 0x20, count: 16 - data.count))
    }
    return data
}

private func normalizedAE(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func uidItemData(_ value: String) -> Data {
    Data(value.utf8)
}

private func userIdentityItemData(_ identity: DicomUserIdentity) -> Data {
    var data = Data()
    data.append(identity.type.rawValue)
    data.append(identity.positiveResponseRequested ? 1 : 0)
    appendUInt16BE(UInt16(identity.primaryField.count), to: &data)
    data.append(identity.primaryField)
    appendUInt16BE(UInt16(identity.secondaryField.count), to: &data)
    data.append(identity.secondaryField)
    return data
}

private func uiData(_ value: String) -> Data {
    var data = Data(value.utf8)
    if data.count % 2 != 0 {
        data.append(0x00)
    }
    return data
}

private func commandStringData(_ value: String) -> Data {
    var data = Data(value.utf8)
    if data.count % 2 != 0 {
        data.append(0x20)
    }
    return data
}

private func appendUInt16BE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
}

private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 24) & 0xFF))
}

private func uint16LEData(_ value: UInt16) -> Data {
    var data = Data()
    appendUInt16LE(value, to: &data)
    return data
}

private func uint32LEData(_ value: UInt32) -> Data {
    var data = Data()
    appendUInt32LE(value, to: &data)
    return data
}

private func appendCommandElement(tag: Int, value: Data, to data: inout Data) {
    appendUInt16LE(UInt16((tag >> 16) & 0xFFFF), to: &data)
    appendUInt16LE(UInt16(tag & 0xFFFF), to: &data)
    appendUInt32LE(UInt32(value.count), to: &data)
    data.append(value)
}

private func commandUInt16(_ data: Data, tag: Int) throws -> UInt16 {
    guard data.count == 2 else {
        throw DicomNetworkError.malformedCommandSet(
            String(format: "Expected 2 bytes for command element %08X.", tag)
        )
    }
    return UInt16(data[data.startIndex]) | UInt16(data[data.startIndex + 1]) << 8
}

private extension Data {
    var dicomUIDItemValue: String {
        String(decoding: self, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    var dicomCommandStringValue: String {
        dicomUIDItemValue
    }
}
