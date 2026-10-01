import Foundation

public enum DicomQueryInformationModel: String, Sendable {
    case patientRoot, studyRoot, modalityWorklist
}

public enum DicomQueryLevel: String, Sendable {
    case patient = "PATIENT", study = "STUDY", series = "SERIES", image = "IMAGE"
}

public struct DicomQueryRequest: Sendable {
    public var model: DicomQueryInformationModel
    public var level: DicomQueryLevel?
    public var identifier: DicomDataSet
    public var relationalQueries: Bool
    public var dateTimeMatching: Bool
    public var associationContext: DicomAssociationContext?
    public var requestingAETitle: String

    public init(model: DicomQueryInformationModel, level: DicomQueryLevel?, identifier: DicomDataSet,
                relationalQueries: Bool = false, dateTimeMatching: Bool = false, requestingAETitle: String, associationContext: DicomAssociationContext? = nil) {
        self.model = model
        self.level = level
        self.identifier = identifier
        self.relationalQueries = relationalQueries
        self.dateTimeMatching = dateTimeMatching
        self.associationContext = associationContext
        self.requestingAETitle = requestingAETitle
    }
}

/// The backend owns model/key support and response projection. Stop production on stream termination.
public protocol DicomQueryProviding: Sendable {
    var unsupportedOptionalKeys: Set<Int> { get }
    func matches(for request: DicomQueryRequest) -> AsyncThrowingStream<DicomDataSet, Error>
}

public extension DicomQueryProviding {
    var unsupportedOptionalKeys: Set<Int> { [] }
}

public struct DicomRetrieveRequest: Sendable {
    public var model: DicomQueryInformationModel
    public var level: DicomQueryLevel
    public var identifier: DicomDataSet
    public var associationContext: DicomAssociationContext?
    public var requestingAETitle: String

    public init(model: DicomQueryInformationModel, level: DicomQueryLevel,
                identifier: DicomDataSet, requestingAETitle: String, associationContext: DicomAssociationContext? = nil) {
        self.model = model
        self.level = level
        self.identifier = identifier
        self.associationContext = associationContext
        self.requestingAETitle = requestingAETitle
    }
}

public struct DicomRetrievableInstance: Sendable {
    public var resource: DicomResourceRef?
    public var sopClassUID: String
    public var sopInstanceUID: String
    public var transferSyntaxes: [DicomTransferSyntax]
    /// Returns DIMSE dataset bytes (without a Part 10 header) in the requested available syntax.
    public var byteSource: @Sendable (DicomTransferSyntax) async throws -> Data

    public init(sopClassUID: String, sopInstanceUID: String, transferSyntaxes: [DicomTransferSyntax],
                resource: DicomResourceRef? = nil,
                byteSource: @escaping @Sendable (DicomTransferSyntax) async throws -> Data) {
        self.sopClassUID = sopClassUID
        self.sopInstanceUID = sopInstanceUID
        self.transferSyntaxes = transferSyntaxes
        self.resource = resource
        self.byteSource = byteSource
    }
}

public protocol DicomRetrieveProviding: Sendable {
    func instances(for request: DicomRetrieveRequest) -> AsyncThrowingStream<DicomRetrievableInstance, Error>
}

public struct DicomMoveDestination: Sendable {
    public var host: String
    public var port: UInt16
    public var tls: DicomTLSConfiguration

    public init(host: String, port: UInt16, tls: DicomTLSConfiguration = .disabled) {
        self.host = host
        self.port = port
        self.tls = tls
    }
}

public protocol DicomMoveDestinationResolving: Sendable {
    func resolve(aeTitle: String) async throws -> DicomMoveDestination?
}

public enum DicomPerformedProcedureStepState: String, Sendable {
    case inProgress = "IN PROGRESS", completed = "COMPLETED", discontinued = "DISCONTINUED"

    public static func creating(attributes: DicomDataSet) throws -> Self {
        guard attributes.string(for: 0x00400252) == Self.inProgress.rawValue else {
            throw DicomDIMSEProviderError(status: 0x0106, errorComment: "Invalid Performed Procedure Step Status")
        }
        return .inProgress
    }

    public func setting(attributes: DicomDataSet) throws -> Self {
        guard self == .inProgress else {
            throw DicomDIMSEProviderError(status: 0x0110,
                errorComment: "Performed Procedure Step Object may no longer be updated", errorID: 0xA710)
        }
        guard let value = attributes.string(for: 0x00400252) else { return self }
        guard let state = Self(rawValue: value) else {
            throw DicomDIMSEProviderError(status: 0x0106, errorComment: "Invalid Performed Procedure Step Status")
        }
        return state
    }
}

/// Implementations atomically validate the persisted state and save the update, using the state helpers above.
public protocol DicomModalityPerformedProcedureStepProviding: Sendable {
    func create(sopInstanceUID: String, attributes: DicomDataSet) async throws -> DicomPerformedProcedureStepState
    func set(sopInstanceUID: String, attributes: DicomDataSet) async throws -> DicomPerformedProcedureStepState
}

public typealias DicomStorageCommitmentResult = DicomStorageCommitmentReport

public struct DicomStorageCommitmentRequestContext: Sendable {
    public var associationContext: DicomAssociationContext?
    public var requestingAETitle: String
    public var calledAETitle: String
    public var associationIdentifier: UUID

    public init(requestingAETitle: String, calledAETitle: String, associationIdentifier: UUID,
                associationContext: DicomAssociationContext? = nil) {
        self.associationContext = associationContext
        self.requestingAETitle = requestingAETitle
        self.calledAETitle = calledAETitle
        self.associationIdentifier = associationIdentifier
    }
}

public protocol DicomStorageCommitmentProviding: Sendable {
    var evidenceProvider: (any DicomCommitmentEvidenceProviding)? { get }
    func verify(transactionUID: String, references: [DicomStorageCommitmentReference]) async
        -> DicomStorageCommitmentResult
    func verify(transactionUID: String, references: [DicomStorageCommitmentReference],
                context: DicomStorageCommitmentRequestContext) async throws -> DicomStorageCommitmentResult
    func prepare(transactionUID: String, references: [DicomStorageCommitmentReference],
                 context: DicomStorageCommitmentRequestContext) async throws
    func shouldDeliverReport(transactionUID: String) async throws -> Bool
    /// Durable hosts reload a pending report here after process restart.
    func pendingReport(transactionUID: String) async throws -> DicomStorageCommitmentResult?
}

public extension DicomStorageCommitmentProviding {
    var evidenceProvider: (any DicomCommitmentEvidenceProviding)? { nil }
    func shouldDeliverReport(transactionUID: String) async throws -> Bool { true }

    func prepare(transactionUID: String, references: [DicomStorageCommitmentReference],
                 context: DicomStorageCommitmentRequestContext) async throws {}

    func verify(transactionUID: String, references: [DicomStorageCommitmentReference],
                context: DicomStorageCommitmentRequestContext) async throws -> DicomStorageCommitmentResult {
        await verify(transactionUID: transactionUID, references: references)
    }

    func pendingReport(transactionUID: String) async throws -> DicomStorageCommitmentResult? { nil }
}


public struct DicomDIMSEProviderError: Error, Sendable {
    public var status: UInt16
    public var errorComment: String?
    public var errorID: UInt16?

    public init(status: UInt16, errorComment: String? = nil, errorID: UInt16? = nil) {
        self.status = status
        self.errorComment = errorComment
        self.errorID = errorID
    }
}

/// Applies the MPPS state rules within a backend-owned atomic transaction.
/// The backend calls the mutation with the current object and commits its result
/// atomically; a thrown mutation must leave persistence unchanged.
public struct DicomModalityPerformedProcedureStepProvider: DicomModalityPerformedProcedureStepProviding {
    public typealias Mutation = @Sendable (DicomDataSet?) throws -> DicomDataSet
    public typealias Transaction = @Sendable (String, Mutation) async throws -> DicomDataSet
    private let transaction: Transaction

    public init(transaction: @escaping Transaction) { self.transaction = transaction }

    public func create(sopInstanceUID: String, attributes: DicomDataSet) async throws -> DicomPerformedProcedureStepState {
        try Task.checkCancellation()
        _ = try await transaction(sopInstanceUID) { current in
            guard current == nil else { throw DicomDIMSEProviderError(status: 0x0111) }
            _ = try DicomPerformedProcedureStepState.creating(attributes: attributes)
            return attributes
        }
        return .inProgress
    }

    public func set(sopInstanceUID: String, attributes: DicomDataSet) async throws -> DicomPerformedProcedureStepState {
        try Task.checkCancellation()
        let result = try await transaction(sopInstanceUID) { current in
            guard var current else { throw DicomDIMSEProviderError(status: 0x0112) }
            guard let value = current.string(for: 0x00400252),
                  let state = DicomPerformedProcedureStepState(rawValue: value) else {
                throw DicomDIMSEProviderError(status: 0x0110)
            }
            _ = try state.setting(attributes: attributes)
            for element in attributes.elements { current.set(element) }
            return current
        }
        guard let value = result.string(for: 0x00400252), let state = DicomPerformedProcedureStepState(rawValue: value) else {
            throw DicomDIMSEProviderError(status: 0x0110)
        }
        return state
    }
}

public extension DicomRetrievableInstance {
    /// A single DIMSE instance can advertise only encodings retaining its SOP identity.
    init(sopClassUID: String, representations set: DicomRepresentationSet,
         store: any DicomRepresentationResolving, resource: DicomResourceRef? = nil) {
        let stored = set.representations.filter {
            guard case .stored = $0.availability else { return false }
            return $0.kind != .lossyDerived
        }
        self.init(sopClassUID: sopClassUID, sopInstanceUID: set.original.sourceSOPInstanceUID,
                  transferSyntaxes: stored.map(\.transferSyntax).reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
                  resource: resource) { syntax in
            guard let current = try await store.representations(for: set.original.sourceSOPInstanceUID),
                  current.original.contentSHA256 == set.original.contentSHA256 else {
                throw DicomRepresentationRefusal.sourceChanged
            }
            let decision = try DicomRepresentationSelector.select(set: current,
                peer: .init(acceptedTransferSyntaxes: [syntax]), policy: .losslessEquivalents)
            guard let representation = current.representations.first(where: {
                $0.contentSHA256 == decision.chosenRepresentation.contentSHA256
            }) else { throw DicomRepresentationRefusal.missingBytes }
            let request = try await store.storeRequest(for: representation)
            guard request.sopClassUID == sopClassUID, request.sopInstanceUID == set.original.sourceSOPInstanceUID,
                  request.transferSyntax == syntax else { throw DicomRepresentationRefusal.invalidOutput }
            return request.dataSetData
        }
    }
}

/// Authentication is supplied by the verified user-identity exchange or an explicit host resolver.
/// Calling/called AE titles and peer addresses are context, never proof of identity.
public struct DicomAssociationContext: Sendable {
    public let principal: DicomPrincipal
    public let access: DicomAccessContext
    public init(principal: DicomPrincipal = .anonymous, access: DicomAccessContext = .init(protocol: .dimse)) {
        self.principal = principal; self.access = access
    }
}
