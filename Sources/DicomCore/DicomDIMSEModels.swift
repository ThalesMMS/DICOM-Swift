import Foundation

public struct DicomDIMSEConnectionConfiguration: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var calledAETitle: String
    public var callingAETitle: String
    public var asynchronousOperationsWindow: DicomAsynchronousOperationsWindow?
    public var extendedNegotiations: [DicomSOPClassExtendedNegotiation]
    public var connectTimeout: TimeInterval
    public var associationTimeout: TimeInterval
    public var dimseResponseTimeout: TimeInterval
    public var releaseTimeout: TimeInterval
    public var cancelTimeout: TimeInterval
    public var timeout: TimeInterval
    public var maximumPDULength: UInt32
    public var transferSyntaxes: [DicomTransferSyntax]
    public var tls: DicomTLSConfiguration
    public var userIdentity: DicomUserIdentity?
    public var retryPolicy: DicomNetworkRetryPolicy
    public var circuitBreakerPolicy: DicomCircuitBreakerPolicy?
    public var bandwidthLimitBytesPerSecond: Int?
    /// Where a C-GET writes each returned object as a Part 10 file as it arrives, handed over in
    /// `DicomRetrievedInstance.part10FileURL`, instead of holding it in memory (issue #2793); nil keeps objects in
    /// memory.
    public var receivedFileDirectory: URL?

    public init(host: String,
                port: UInt16,
                calledAETitle: String,
                callingAETitle: String,
                timeout: TimeInterval = 10,
                maximumPDULength: UInt32 = 16_384,
                transferSyntaxes: [DicomTransferSyntax] = [.explicitVRLittleEndian, .implicitVRLittleEndian],
                tls: DicomTLSConfiguration = .disabled,
                userIdentity: DicomUserIdentity? = nil,
                retryPolicy: DicomNetworkRetryPolicy = .disabled,
                circuitBreakerPolicy: DicomCircuitBreakerPolicy? = nil,
                bandwidthLimitBytesPerSecond: Int? = nil,
                asynchronousOperationsWindow: DicomAsynchronousOperationsWindow? = nil,
                extendedNegotiations: [DicomSOPClassExtendedNegotiation] = [],
                connectTimeout: TimeInterval? = nil,
                associationTimeout: TimeInterval? = nil,
                dimseResponseTimeout: TimeInterval? = nil,
                releaseTimeout: TimeInterval? = nil,
                cancelTimeout: TimeInterval? = nil) {
        self.connectTimeout = connectTimeout ?? timeout
        self.associationTimeout = associationTimeout ?? timeout
        self.dimseResponseTimeout = dimseResponseTimeout ?? timeout
        self.releaseTimeout = releaseTimeout ?? timeout
        self.cancelTimeout = cancelTimeout ?? timeout
        self.asynchronousOperationsWindow = asynchronousOperationsWindow
        self.extendedNegotiations = extendedNegotiations
        self.host = host
        self.port = port
        self.calledAETitle = calledAETitle
        self.callingAETitle = callingAETitle
        self.timeout = timeout
        self.maximumPDULength = maximumPDULength
        self.transferSyntaxes = transferSyntaxes
        self.tls = tls
        self.userIdentity = userIdentity
        self.retryPolicy = retryPolicy
        self.circuitBreakerPolicy = circuitBreakerPolicy
        self.bandwidthLimitBytesPerSecond = bandwidthLimitBytesPerSecond
    }
}

public enum DicomDIMSEOperation: String, Codable, Equatable, Sendable {
    case verification = "C-ECHO"
    case query = "C-FIND"
    case modalityWorklist = "MWL C-FIND"
    case moveRetrieve = "C-MOVE"
    case getRetrieve = "C-GET"
    case store = "C-STORE"
    case mppsCreate = "MPPS N-CREATE"
    case mppsUpdate = "MPPS N-SET"
    case storageCommitmentRequest = "Storage Commitment N-ACTION"
    case storageCommitmentReport = "Storage Commitment N-EVENT-REPORT"
    case printManagement = "Print Management"
    case workflowWrite = "Workflow write"

    /// Whether a successful operation may hand its association back to the idle pool.
    ///
    /// Retrieval is the one operation where peers routinely end the association themselves as soon
    /// as the final response is sent — some close the socket, others send A-RELEASE-RQ. Either way
    /// the recycled association is no longer usable, and because the local open flag cannot see it,
    /// the next request checked out against that entry fails on the leftover traffic.
    var allowsAssociationRecycling: Bool {
        switch self {
        case .moveRetrieve, .getRetrieve:
            return false
        case .verification, .query, .modalityWorklist, .store,
             .mppsCreate, .mppsUpdate, .storageCommitmentReport, .storageCommitmentRequest, .printManagement, .workflowWrite:
            return true
        }
    }
}

public enum DicomDIMSEProgress: Equatable, Sendable {
    case associationRequested(operation: DicomDIMSEOperation, calledAETitle: String)
    case associationAccepted(operation: DicomDIMSEOperation)
    case requestSent(operation: DicomDIMSEOperation, messageID: UInt16)
    case pending(operation: DicomDIMSEOperation,
                 remaining: UInt16?,
                 completed: UInt16?,
                 failed: UInt16?,
                 warning: UInt16?)
    case storeReceived(sopInstanceUID: String?)
    case completed(operation: DicomDIMSEOperation, status: UInt16)
    case released(operation: DicomDIMSEOperation)
}

public struct DicomDIMSEOperationResult: Equatable, Sendable {
    public var status: UInt16
    public var remainingSuboperations: UInt16?
    public var completedSuboperations: UInt16?
    public var failedSuboperations: UInt16?
    public var warningSuboperations: UInt16?
    /// The Query/Retrieve information model the operation actually ran under,
    /// when more than one was proposed on the association (issue #1867).
    /// `nil` for operations that are not model-negotiated (echo, store, print).
    public var negotiatedQueryModelUID: String?

    public init(status: UInt16,
                remainingSuboperations: UInt16? = nil,
                completedSuboperations: UInt16? = nil,
                failedSuboperations: UInt16? = nil,
                warningSuboperations: UInt16? = nil,
                negotiatedQueryModelUID: String? = nil) {
        self.status = status
        self.remainingSuboperations = remainingSuboperations
        self.completedSuboperations = completedSuboperations
        self.failedSuboperations = failedSuboperations
        self.warningSuboperations = warningSuboperations
        self.negotiatedQueryModelUID = negotiatedQueryModelUID
    }
}

public enum DicomStoreRequestError: Error, Equatable, Sendable {
    case invalidPart10File(String)
    case missingTransferSyntaxUID
    case unsupportedTransferSyntaxUID(String)
    case missingSOPClassUID
    case missingSOPInstanceUID
    case emptyDataSet
}

extension DicomStoreRequestError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPart10File(let reason):
            return "Invalid DICOM Part 10 file: \(reason)"
        case .missingTransferSyntaxUID:
            return "DICOM Part 10 file is missing Transfer Syntax UID."
        case .unsupportedTransferSyntaxUID(let uid):
            return "DICOM Part 10 file uses unsupported transfer syntax \(uid)."
        case .missingSOPClassUID:
            return "DICOM Part 10 file is missing Media Storage SOP Class UID."
        case .missingSOPInstanceUID:
            return "DICOM Part 10 file is missing Media Storage SOP Instance UID."
        case .emptyDataSet:
            return "DICOM Part 10 file does not contain a dataset payload."
        }
    }
}

public struct DicomStoreRequest: Equatable, Sendable {
    public var sopClassUID: String
    public var sopInstanceUID: String
    public var transferSyntax: DicomTransferSyntax
    /// Transfer syntaxes the SCU may negotiate for this SOP Class. The stored
    /// syntax stays first; alternatives are negotiation probes only and are
    /// never used to encode the original payload implicitly.
    public var proposedTransferSyntaxes: [DicomTransferSyntax]
    public var dataSetData: Data

    public init(
        sopClassUID: String,
        sopInstanceUID: String,
        transferSyntax: DicomTransferSyntax,
        dataSetData: Data
    ) throws {
        let trimmedSOPClassUID = Self.dicomTrimmedValue(sopClassUID)
        let trimmedSOPInstanceUID = Self.dicomTrimmedValue(sopInstanceUID)
        guard !trimmedSOPClassUID.isEmpty else {
            throw DicomStoreRequestError.missingSOPClassUID
        }
        guard !trimmedSOPInstanceUID.isEmpty else {
            throw DicomStoreRequestError.missingSOPInstanceUID
        }
        guard !dataSetData.isEmpty else {
            throw DicomStoreRequestError.emptyDataSet
        }
        self.sopClassUID = trimmedSOPClassUID
        self.sopInstanceUID = trimmedSOPInstanceUID
        self.transferSyntax = transferSyntax
        self.proposedTransferSyntaxes = [transferSyntax]
        self.dataSetData = dataSetData
    }

    /// The dataset stays a mapped view of the file (issue #2793): sending or validating a large object read from
    /// disk does not load it.
    public init(part10FileAt url: URL) throws {
        let header = try Self.part10Header(of: DicomMappedFileData.data(contentsOf: url))
        try self.init(
            sopClassUID: header.sopClassUID,
            sopInstanceUID: header.sopInstanceUID,
            transferSyntax: header.transferSyntax,
            dataSetData: DicomMappedFileData.data(contentsOf: url, from: header.dataSetOffset)
        )
    }

    /// Retains the verified mapping and a zero-based dataset view, without reopening or copying the file.
    public init(mappedPart10Data: Data) throws {
        let header = try Self.part10Header(of: mappedPart10Data)
        let dataSet = mappedPart10Data.withUnsafeBytes { raw in
            Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: raw.baseAddress!.advanced(by: header.dataSetOffset)),
                 count: mappedPart10Data.count - header.dataSetOffset,
                 deallocator: .custom { [mappedPart10Data] _, _ in withExtendedLifetime(mappedPart10Data) {} })
        }
        try self.init(sopClassUID: header.sopClassUID, sopInstanceUID: header.sopInstanceUID,
                      transferSyntax: header.transferSyntax, dataSetData: dataSet)
    }

    public init(part10Data: Data) throws {
        let header = try Self.part10Header(of: part10Data)
        try self.init(
            sopClassUID: header.sopClassUID,
            sopInstanceUID: header.sopInstanceUID,
            transferSyntax: header.transferSyntax,
            dataSetData: Data(part10Data.dropFirst(header.dataSetOffset))
        )
    }

    static func part10Header(
        of data: Data
    ) throws -> (sopClassUID: String, sopInstanceUID: String, transferSyntax: DicomTransferSyntax, dataSetOffset: Int) {
        guard data.count >= 132 else {
            throw DicomStoreRequestError.invalidPart10File("file is shorter than the DICOM preamble")
        }
        guard DicomPart10FileMetaParser.hasPart10Prefix(data) else {
            throw DicomStoreRequestError.invalidPart10File("missing DICM prefix")
        }

        let fileMeta: DicomPart10FileMetaParser.FileMeta
        do {
            fileMeta = try DicomPart10FileMetaParser.parse(data)
        } catch DicomPart10FileMetaParser.ParserError.invalid(let reason) {
            throw DicomStoreRequestError.invalidPart10File(reason)
        }

        guard fileMeta.dataSetOffset < data.count else {
            throw DicomStoreRequestError.emptyDataSet
        }
        guard let transferSyntaxUID = fileMeta.transferSyntaxUID, !transferSyntaxUID.isEmpty else {
            throw DicomStoreRequestError.missingTransferSyntaxUID
        }
        guard DicomCodecCapabilities.preservationDecision(for: transferSyntaxUID).canExecute,
              let transferSyntax = DicomTransferSyntax(uid: transferSyntaxUID) else {
            throw DicomStoreRequestError.unsupportedTransferSyntaxUID(transferSyntaxUID)
        }
        guard let sopClassUID = fileMeta.mediaStorageSOPClassUID, !sopClassUID.isEmpty else {
            throw DicomStoreRequestError.missingSOPClassUID
        }
        guard let sopInstanceUID = fileMeta.mediaStorageSOPInstanceUID, !sopInstanceUID.isEmpty else {
            throw DicomStoreRequestError.missingSOPInstanceUID
        }

        return (dicomTrimmedValue(sopClassUID), dicomTrimmedValue(sopInstanceUID), transferSyntax,
                fileMeta.dataSetOffset)
    }

    private static func dicomTrimmedValue(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
    }
}

/// Query/Retrieve information models proposed by default, in preference order
/// (issue #1867). Every listed model rides in the one association request; the
/// operation then runs under the first model the peer accepted. A
/// Patient-Root-only archive is reached this way without a second association,
/// a retry, or any guessing from post-negotiation failures — timeouts,
/// authentication refusals, and empty result sets all happen under the single
/// already-selected model.
public enum DicomQueryRetrieveModelPreference {
    public static let find = [
        DicomNetworkUID.studyRootQueryRetrieveFind,
        DicomNetworkUID.patientRootQueryRetrieveFind
    ]
    public static let move = [
        DicomNetworkUID.studyRootQueryRetrieveMove,
        DicomNetworkUID.patientRootQueryRetrieveMove
    ]
    public static let get = [
        DicomNetworkUID.studyRootQueryRetrieveGet,
        DicomNetworkUID.patientRootQueryRetrieveGet
    ]
}

public struct DicomCFindResult: Equatable, Sendable {
    public var operation: DicomDIMSEOperationResult
    public var matches: [DicomDataSet]

    public init(operation: DicomDIMSEOperationResult, matches: [DicomDataSet]) {
        self.operation = operation
        self.matches = matches
    }
}

public struct DicomRetrievedInstance: Equatable, Sendable {
    public var sopClassUID: String?
    public var sopInstanceUID: String?
    public var transferSyntax: DicomTransferSyntax {
        didSet { dataSetCache.reset() }
    }
    public var data: Data {
        didSet { dataSetCache.reset(); part10FileURL = nil }
    }
    /// The object as received, written as a Part 10 file (preamble, File Meta, then the dataset bytes as they
    /// arrived), when `DicomDIMSEConnectionConfiguration.receivedFileDirectory` is set (issue #2793); `data` is then a
    /// mapped view of that file. The file is removed once `onInstance` returns unless the handler moved it.
    public var part10FileURL: URL?
    private let dataSetCache: DicomRetrievedDataSetCache

    /// Lazily parsed metadata. Pixel Data is intentionally omitted; use `data` for the complete
    /// encoded dataset, including native or encapsulated pixel payloads.
    public var dataSet: DicomDataSet? {
        get {
            dataSetCache.value(data: data, transferSyntax: transferSyntax)
        }
        set {
            dataSetCache.set(newValue)
        }
    }

    public init(sopClassUID: String?,
                sopInstanceUID: String?,
                transferSyntax: DicomTransferSyntax,
                data: Data,
                dataSet: DicomDataSet?) {
        self.sopClassUID = sopClassUID
        self.sopInstanceUID = sopInstanceUID
        self.transferSyntax = transferSyntax
        self.data = data
        dataSetCache = DicomRetrievedDataSetCache(dataSet: dataSet)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sopClassUID == rhs.sopClassUID &&
            lhs.sopInstanceUID == rhs.sopInstanceUID &&
            lhs.transferSyntax == rhs.transferSyntax &&
            lhs.data == rhs.data
    }
}

public struct DicomCGetResult: Equatable, Sendable {
    public var operation: DicomDIMSEOperationResult
    public var retrievedInstances: [DicomRetrievedInstance]

    public init(operation: DicomDIMSEOperationResult,
                retrievedInstances: [DicomRetrievedInstance]) {
        self.operation = operation
        self.retrievedInstances = retrievedInstances
    }
}
