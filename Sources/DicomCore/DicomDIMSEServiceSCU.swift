import Foundation
#if canImport(Network)
import Network
#if canImport(Security)
import Security
#endif
#endif

public struct DicomDIMSEConnectionConfiguration: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var calledAETitle: String
    public var callingAETitle: String
    public var timeout: TimeInterval
    public var maximumPDULength: UInt32
    public var transferSyntaxes: [DicomTransferSyntax]
    public var tls: DicomTLSConfiguration
    public var userIdentity: DicomUserIdentity?
    public var retryPolicy: DicomNetworkRetryPolicy
    public var circuitBreakerPolicy: DicomCircuitBreakerPolicy?
    public var bandwidthLimitBytesPerSecond: Int?

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
                bandwidthLimitBytesPerSecond: Int? = nil) {
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
    case printManagement = "Print Management"
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

    public init(status: UInt16,
                remainingSuboperations: UInt16? = nil,
                completedSuboperations: UInt16? = nil,
                failedSuboperations: UInt16? = nil,
                warningSuboperations: UInt16? = nil) {
        self.status = status
        self.remainingSuboperations = remainingSuboperations
        self.completedSuboperations = completedSuboperations
        self.failedSuboperations = failedSuboperations
        self.warningSuboperations = warningSuboperations
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
        self.dataSetData = dataSetData
    }

    public init(part10FileAt url: URL) throws {
        try self.init(part10Data: Data(contentsOf: url))
    }

    public init(part10Data: Data) throws {
        let extracted = try Self.extractPart10StorePayload(from: part10Data)
        try self.init(
            sopClassUID: extracted.sopClassUID,
            sopInstanceUID: extracted.sopInstanceUID,
            transferSyntax: extracted.transferSyntax,
            dataSetData: extracted.dataSetData
        )
    }

    private static func extractPart10StorePayload(
        from data: Data
    ) throws -> (sopClassUID: String, sopInstanceUID: String, transferSyntax: DicomTransferSyntax, dataSetData: Data) {
        guard data.count >= 132 else {
            throw DicomStoreRequestError.invalidPart10File("file is shorter than the DICOM preamble")
        }
        guard data[128] == 0x44, data[129] == 0x49, data[130] == 0x43, data[131] == 0x4D else {
            throw DicomStoreRequestError.invalidPart10File("missing DICM prefix")
        }

        var offset = 132
        var sopClassUID: String?
        var sopInstanceUID: String?
        var transferSyntaxUID: String?

        while offset + 8 <= data.count {
            let elementOffset = offset
            let group = try readUInt16(from: data, at: offset)
            let element = try readUInt16(from: data, at: offset + 2)
            guard group == 0x0002 else {
                offset = elementOffset
                break
            }

            let vr = String(bytes: data[(offset + 4)..<(offset + 6)], encoding: .ascii) ?? ""
            let valueOffset: Int
            let length: Int
            if uses32BitLength(vr) {
                guard offset + 12 <= data.count else {
                    throw DicomStoreRequestError.invalidPart10File("truncated file meta element")
                }
                valueOffset = offset + 12
                length = Int(try readUInt32(from: data, at: offset + 8))
            } else {
                valueOffset = offset + 8
                length = Int(try readUInt16(from: data, at: offset + 6))
            }

            guard length >= 0, valueOffset + length <= data.count else {
                throw DicomStoreRequestError.invalidPart10File("file meta element length exceeds file size")
            }

            let value = dicomStringValue(data[valueOffset..<(valueOffset + length)])
            let tag = (Int(group) << 16) | Int(element)
            switch tag {
            case 0x0002_0002:
                sopClassUID = value
            case 0x0002_0003:
                sopInstanceUID = value
            case DicomTag.transferSyntaxUID.rawValue:
                transferSyntaxUID = value
            default:
                break
            }
            offset = valueOffset + length
        }

        guard offset < data.count else {
            throw DicomStoreRequestError.emptyDataSet
        }
        guard let transferSyntaxUID, !transferSyntaxUID.isEmpty else {
            throw DicomStoreRequestError.missingTransferSyntaxUID
        }
        guard let transferSyntax = DicomTransferSyntax(uid: transferSyntaxUID) else {
            throw DicomStoreRequestError.unsupportedTransferSyntaxUID(transferSyntaxUID)
        }
        guard let sopClassUID, !sopClassUID.isEmpty else {
            throw DicomStoreRequestError.missingSOPClassUID
        }
        guard let sopInstanceUID, !sopInstanceUID.isEmpty else {
            throw DicomStoreRequestError.missingSOPInstanceUID
        }

        return (
            sopClassUID,
            sopInstanceUID,
            transferSyntax,
            Data(data[offset..<data.count])
        )
    }

    private static func uses32BitLength(_ vr: String) -> Bool {
        switch vr {
        case "OB", "OD", "OF", "OL", "OW", "SQ", "UC", "UN", "UR", "UT":
            return true
        default:
            return false
        }
    }

    private static func readUInt16(from data: Data, at offset: Int) throws -> UInt16 {
        guard let value = data.dicomIntegerIfPresent(
            at: offset,
            as: UInt16.self,
            littleEndian: true
        ) else {
            throw DicomStoreRequestError.invalidPart10File("truncated UInt16 value")
        }
        return value
    }

    private static func readUInt32(from data: Data, at offset: Int) throws -> UInt32 {
        guard let value = data.dicomIntegerIfPresent(
            at: offset,
            as: UInt32.self,
            littleEndian: true
        ) else {
            throw DicomStoreRequestError.invalidPart10File("truncated UInt32 value")
        }
        return value
    }

    private static func dicomStringValue(_ data: Data.SubSequence) -> String {
        String(data: Data(data), encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ").union(.whitespacesAndNewlines)) ?? ""
    }

    private static func dicomTrimmedValue(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
    }
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
        didSet { dataSetCache.reset() }
    }
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

/// Synchronous DIMSE SCU implementation.
///
/// Network I/O, retry backoff, and bandwidth pacing block the calling thread. Callers that bridge
/// this API to Swift concurrency must run it on a dedicated blocking executor rather than a
/// cooperative executor thread.
public struct DicomDIMSEServiceSCU {
    public var configuration: DicomDIMSEConnectionConfiguration
    public var auditLogger: DicomNetworkAuditLogging?
    private let circuitBreaker: DicomNetworkCircuitBreaker?
    private let transportFactory: (() throws -> DicomAssociationTransport)?
    private let operationHandle: DicomDIMSEOperationHandle?
    private let associationPool: DicomDIMSEAssociationPool?

    public init(configuration: DicomDIMSEConnectionConfiguration,
                auditLogger: DicomNetworkAuditLogging? = nil,
                circuitBreaker: DicomNetworkCircuitBreaker? = nil,
                operationHandle: DicomDIMSEOperationHandle? = nil) {
        self.init(configuration: configuration,
                  auditLogger: auditLogger,
                  circuitBreaker: circuitBreaker,
                  operationHandle: operationHandle,
                  transportFactory: nil,
                  associationPool: nil)
    }

    init(configuration: DicomDIMSEConnectionConfiguration,
         auditLogger: DicomNetworkAuditLogging? = nil,
         circuitBreaker: DicomNetworkCircuitBreaker? = nil,
         operationHandle: DicomDIMSEOperationHandle? = nil,
         transportFactory: (() throws -> DicomAssociationTransport)? = nil,
         associationPool: DicomDIMSEAssociationPool? = nil) {
        self.configuration = configuration
        self.auditLogger = auditLogger
        self.transportFactory = transportFactory
        self.operationHandle = operationHandle
        self.associationPool = associationPool
        if let circuitBreaker {
            self.circuitBreaker = circuitBreaker
        } else if let policy = configuration.circuitBreakerPolicy {
            self.circuitBreaker = DicomNetworkCircuitBreaker(policy: policy)
        } else {
            self.circuitBreaker = nil
        }
    }

    func replacingRuntimeDependencies(
        auditLogger: DicomNetworkAuditLogging?,
        circuitBreaker: DicomNetworkCircuitBreaker?,
        operationHandle: DicomDIMSEOperationHandle?
    ) -> DicomDIMSEServiceSCU {
        DicomDIMSEServiceSCU(
            configuration: configuration,
            auditLogger: auditLogger,
            circuitBreaker: circuitBreaker,
            operationHandle: operationHandle,
            transportFactory: transportFactory,
            associationPool: associationPool
        )
    }

    public func verify(progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        try performWithResilience(operation: .verification, progress: progress) { transport in
            try verify(using: transport, progress: progress)
        }
    }

    public func verify(using transport: DicomAssociationTransport,
                       progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        let operation = DicomDIMSEOperation.verification
        let association = try openAssociation(
            for: operation,
            abstractSyntaxUIDs: [DicomNetworkUID.verificationSOPClass],
            using: transport,
            progress: progress
        )
        defer { try? release(operation: operation, using: transport, progress: progress) }

        let context = try acceptedContext(DicomNetworkUID.verificationSOPClass, in: association)
        let messageID: UInt16 = 1
        let command = DicomDIMSECommandSet(
            affectedSOPClassUID: DicomNetworkUID.verificationSOPClass,
            commandField: DicomDIMSECommandField.cEchoRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.noDataSet
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))

        let reader = DicomDIMSEMessageReader()
        let response = try readCommand(using: transport, reader: reader)
        try expect(response, commandField: DicomDIMSECommandField.cEchoRSP)
        try validateSuccessStatus(response)
        let result = operationResult(from: response)
        progress?(.completed(operation: operation, status: result.status))
        return result
    }

    public func find(identifier: DicomDataSet,
                     queryModelUID: String = DicomNetworkUID.studyRootQueryRetrieveFind,
                     progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomCFindResult {
        try performWithResilience(operation: .query, progress: progress) { transport in
            try find(identifier: identifier,
                     queryModelUID: queryModelUID,
                     operation: .query,
                     using: transport,
                     progress: progress)
        }
    }

    public func find(identifier: DicomDataSet,
                     queryModelUID: String = DicomNetworkUID.studyRootQueryRetrieveFind,
                     using transport: DicomAssociationTransport,
                     progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomCFindResult {
        try find(identifier: identifier,
                 queryModelUID: queryModelUID,
                 operation: .query,
                 using: transport,
                 progress: progress)
    }

    func find(identifier: DicomDataSet,
              queryModelUID: String,
              operation: DicomDIMSEOperation,
              using transport: DicomAssociationTransport,
              progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomCFindResult {
        let association = try openAssociation(
            for: operation,
            abstractSyntaxUIDs: [queryModelUID],
            using: transport,
            progress: progress
        )
        defer { try? release(operation: operation, using: transport, progress: progress) }

        let context = try acceptedContext(queryModelUID, in: association)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        let messageID: UInt16 = 1
        let command = DicomDIMSECommandSet(
            affectedSOPClassUID: queryModelUID,
            commandField: DicomDIMSECommandField.cFindRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            priority: 0
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        try sendDataSet(identifier,
                        transferSyntax: transferSyntax,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))
        installCancelRequestAction(messageID: messageID,
                                   presentationContextID: context.id,
                                   association: association,
                                   transport: transport)

        let reader = DicomDIMSEMessageReader()
        var matches: [DicomDataSet] = []
        while true {
            let response = try readCommand(using: transport, reader: reader)
            try expect(response, commandField: DicomDIMSECommandField.cFindRSP)
            let status = response.status ?? 0
            if isPending(status) {
                if response.commandDataSetType != DicomDIMSECommandDataSetType.noDataSet {
                    let payload = try reader.readMessage(from: transport)
                    guard !payload.isCommand else {
                        throw DicomNetworkError.malformedCommandSet("Expected C-FIND identifier dataset.")
                    }
                    matches.append(try DicomDataSetParser.dataSet(from: payload.data,
                                                                  transferSyntax: transferSyntax))
                }
                progressPending(operation: operation, response: response, progress: progress)
                try operationHandle?.checkCancellation(operation: operation)
                continue
            }
            try validateSuccessStatus(response)
            let result = operationResult(from: response)
            progress?(.completed(operation: operation, status: result.status))
            return DicomCFindResult(operation: result, matches: matches)
        }
    }

    public func findModalityWorklist(query: DicomModalityWorklistQuery,
                                     progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomModalityWorklistResult {
        let result = try performWithResilience(operation: .modalityWorklist, progress: progress) { transport in
            try find(identifier: query.identifier,
                     queryModelUID: DicomNetworkUID.modalityWorklistInformationModelFind,
                     operation: .modalityWorklist,
                     using: transport,
                     progress: progress)
        }
        return DicomModalityWorklistResult(
            operation: result.operation,
            items: result.matches.map(DicomModalityWorklistItem.init(dataSet:))
        )
    }

    public func findModalityWorklist(query: DicomModalityWorklistQuery,
                                     using transport: DicomAssociationTransport,
                                     progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomModalityWorklistResult {
        let result = try find(identifier: query.identifier,
                              queryModelUID: DicomNetworkUID.modalityWorklistInformationModelFind,
                              operation: .modalityWorklist,
                              using: transport,
                              progress: progress)
        return DicomModalityWorklistResult(
            operation: result.operation,
            items: result.matches.map(DicomModalityWorklistItem.init(dataSet:))
        )
    }

    public func move(identifier: DicomDataSet,
                     moveDestinationAETitle: String,
                     queryModelUID: String = DicomNetworkUID.studyRootQueryRetrieveMove,
                     progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        try performWithResilience(operation: .moveRetrieve, progress: progress) { transport in
            try move(identifier: identifier,
                     moveDestinationAETitle: moveDestinationAETitle,
                     queryModelUID: queryModelUID,
                     using: transport,
                     progress: progress)
        }
    }

    public func move(identifier: DicomDataSet,
                     moveDestinationAETitle: String,
                     queryModelUID: String = DicomNetworkUID.studyRootQueryRetrieveMove,
                     using transport: DicomAssociationTransport,
                     progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        let operation = DicomDIMSEOperation.moveRetrieve
        let association = try openAssociation(
            for: operation,
            abstractSyntaxUIDs: [queryModelUID],
            using: transport,
            progress: progress
        )
        defer { try? release(operation: operation, using: transport, progress: progress) }

        let context = try acceptedContext(queryModelUID, in: association)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        let messageID: UInt16 = 1
        let command = DicomDIMSECommandSet(
            affectedSOPClassUID: queryModelUID,
            commandField: DicomDIMSECommandField.cMoveRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            moveDestination: moveDestinationAETitle,
            priority: 0
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        try sendDataSet(identifier,
                        transferSyntax: transferSyntax,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))
        installCancelRequestAction(messageID: messageID,
                                   presentationContextID: context.id,
                                   association: association,
                                   transport: transport)

        let reader = DicomDIMSEMessageReader()
        while true {
            let response = try readCommand(using: transport, reader: reader)
            try expect(response, commandField: DicomDIMSECommandField.cMoveRSP)
            let status = response.status ?? 0
            if isPending(status) {
                progressPending(operation: operation, response: response, progress: progress)
                try operationHandle?.checkCancellation(operation: operation)
                continue
            }
            try validateRetrieveStatus(response)
            let result = operationResult(from: response)
            progress?(.completed(operation: operation, status: result.status))
            return result
        }
    }

    public func get(identifier: DicomDataSet,
                    storageSOPClassUIDs: [String] = [DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID],
                    queryModelUID: String = DicomNetworkUID.studyRootQueryRetrieveGet,
                    progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomCGetResult {
        try performWithResilience(operation: .getRetrieve, progress: progress) { transport in
            try get(identifier: identifier,
                    storageSOPClassUIDs: storageSOPClassUIDs,
                    queryModelUID: queryModelUID,
                    using: transport,
                    progress: progress)
        }
    }

    public func get(identifier: DicomDataSet,
                    storageSOPClassUIDs: [String] = [DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID],
                    queryModelUID: String = DicomNetworkUID.studyRootQueryRetrieveGet,
                    onInstance: (DicomRetrievedInstance) throws -> Void,
                    progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        return try performWithResilience(operation: .getRetrieve, progress: progress) { transport in
            var deliveredSOPInstanceUIDs = Set<String>()
            return try get(identifier: identifier,
                    storageSOPClassUIDs: storageSOPClassUIDs,
                    queryModelUID: queryModelUID,
                    using: transport,
                    onInstance: { instance in
                        if let sopInstanceUID = instance.sopInstanceUID,
                           !sopInstanceUID.isEmpty,
                           !deliveredSOPInstanceUIDs.insert(sopInstanceUID).inserted {
                            return
                        }
                        try onInstance(instance)
                    },
                    progress: progress)
        }
    }

    public func get(identifier: DicomDataSet,
                    storageSOPClassUIDs: [String] = [DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID],
                    queryModelUID: String = DicomNetworkUID.studyRootQueryRetrieveGet,
                    using transport: DicomAssociationTransport,
                    progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomCGetResult {
        var retrieved: [DicomRetrievedInstance] = []
        let operation = try get(identifier: identifier,
                                storageSOPClassUIDs: storageSOPClassUIDs,
                                queryModelUID: queryModelUID,
                                using: transport,
                                onInstance: { retrieved.append($0) },
                                progress: progress)
        return DicomCGetResult(operation: operation, retrievedInstances: retrieved)
    }

    public func get(identifier: DicomDataSet,
                    storageSOPClassUIDs: [String] = [DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID],
                    queryModelUID: String = DicomNetworkUID.studyRootQueryRetrieveGet,
                    using transport: DicomAssociationTransport,
                    onInstance: (DicomRetrievedInstance) throws -> Void,
                    progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        let operation = DicomDIMSEOperation.getRetrieve
        let association = try openAssociation(
            for: operation,
            abstractSyntaxUIDs: [queryModelUID] + storageSOPClassUIDs,
            using: transport,
            progress: progress
        )
        defer { try? release(operation: operation, using: transport, progress: progress) }

        let context = try acceptedContext(queryModelUID, in: association)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        let messageID: UInt16 = 1
        let command = DicomDIMSECommandSet(
            affectedSOPClassUID: queryModelUID,
            commandField: DicomDIMSECommandField.cGetRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            priority: 0
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        try sendDataSet(identifier,
                        transferSyntax: transferSyntax,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))
        installCancelRequestAction(messageID: messageID,
                                   presentationContextID: context.id,
                                   association: association,
                                   transport: transport)

        let reader = DicomDIMSEMessageReader()
        while true {
            let response = try readCommand(using: transport, reader: reader)
            switch response.commandField {
            case DicomDIMSECommandField.cStoreRQ:
                let stored = try receiveStoreRequest(response,
                                                     association: association,
                                                     transport: transport,
                                                     reader: reader)
                try onInstance(stored)
                progress?(.storeReceived(sopInstanceUID: stored.sopInstanceUID))
                try operationHandle?.checkCancellation(operation: operation)
            case DicomDIMSECommandField.cGetRSP:
                let status = response.status ?? 0
                if isPending(status) {
                    progressPending(operation: operation, response: response, progress: progress)
                    try operationHandle?.checkCancellation(operation: operation)
                    continue
                }
                try validateRetrieveStatus(response)
                let result = operationResult(from: response)
                progress?(.completed(operation: operation, status: result.status))
                return result
            default:
                throw DicomNetworkError.unexpectedDIMSECommand(expected: DicomDIMSECommandField.cGetRSP,
                                                               actual: response.commandField)
            }
        }
    }

    public func store(dataSet: DicomDataSet,
                      sopClassUID: String? = nil,
                      sopInstanceUID: String? = nil,
                      progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        try performWithResilience(operation: .store, progress: progress) { transport in
            try store(dataSet: dataSet,
                      sopClassUID: sopClassUID,
                      sopInstanceUID: sopInstanceUID,
                      using: transport,
                      progress: progress)
        }
    }

    public func store(dataSet: DicomDataSet,
                      sopClassUID: String? = nil,
                      sopInstanceUID: String? = nil,
                      using transport: DicomAssociationTransport,
                      progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        let operation = DicomDIMSEOperation.store
        let storage = storageDataSet(dataSet,
                                     sopClassUID: sopClassUID,
                                     sopInstanceUID: sopInstanceUID)
        let association = try openAssociation(
            for: operation,
            abstractSyntaxUIDs: [storage.sopClassUID],
            using: transport,
            progress: progress
        )
        defer { try? release(operation: operation, using: transport, progress: progress) }

        let context = try acceptedContext(storage.sopClassUID, in: association)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        let messageID: UInt16 = 1
        let command = DicomDIMSECommandSet(
            affectedSOPClassUID: storage.sopClassUID,
            commandField: DicomDIMSECommandField.cStoreRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            priority: 0,
            affectedSOPInstanceUID: storage.sopInstanceUID
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        try sendDataSet(storage.dataSet,
                        transferSyntax: transferSyntax,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))

        let reader = DicomDIMSEMessageReader()
        let response = try readCommand(using: transport, reader: reader)
        try expect(response, commandField: DicomDIMSECommandField.cStoreRSP)
        try validateSuccessStatus(response)
        let result = operationResult(from: response)
        progress?(.completed(operation: operation, status: result.status))
        return result
    }

    public func store(request: DicomStoreRequest,
                      progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        try performWithResilience(operation: .store, progress: progress) { transport in
            try store(request: request, using: transport, progress: progress)
        }
    }

    public func store(request: DicomStoreRequest,
                      using transport: DicomAssociationTransport,
                      progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        let operation = DicomDIMSEOperation.store
        let association = try openAssociation(
            for: operation,
            abstractSyntaxUIDs: [request.sopClassUID],
            transferSyntaxes: [request.transferSyntax],
            using: transport,
            progress: progress
        )
        defer { try? release(operation: operation, using: transport, progress: progress) }

        let context = try acceptedContext(request.sopClassUID, in: association)
        guard context.transferSyntaxUID == request.transferSyntax.rawValue else {
            throw DicomNetworkError.transferSyntaxMismatch(
                expected: request.transferSyntax.rawValue,
                actual: context.transferSyntaxUID
            )
        }

        let messageID: UInt16 = 1
        let command = DicomDIMSECommandSet(
            affectedSOPClassUID: request.sopClassUID,
            commandField: DicomDIMSECommandField.cStoreRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            priority: 0,
            affectedSOPInstanceUID: request.sopInstanceUID
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        try sendDataSetData(request.dataSetData,
                            presentationContextID: context.id,
                            association: association,
                            transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))

        let reader = DicomDIMSEMessageReader()
        let response = try readCommand(using: transport, reader: reader)
        try expect(response, commandField: DicomDIMSECommandField.cStoreRSP)
        try validateSuccessStatus(response)
        let result = operationResult(from: response)
        progress?(.completed(operation: operation, status: result.status))
        return result
    }

    public func createMPPS(_ request: DicomMPPSCreateRequest,
                           progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        try performWithResilience(operation: .mppsCreate, progress: progress) { transport in
            try createMPPS(request, using: transport, progress: progress)
        }
    }

    public func createMPPS(_ request: DicomMPPSCreateRequest,
                           using transport: DicomAssociationTransport,
                           progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        let operation = DicomDIMSEOperation.mppsCreate
        let association = try openAssociation(
            for: operation,
            abstractSyntaxUIDs: [DicomNetworkUID.modalityPerformedProcedureStepSOPClass],
            using: transport,
            progress: progress
        )
        defer { try? release(operation: operation, using: transport, progress: progress) }

        let context = try acceptedContext(DicomNetworkUID.modalityPerformedProcedureStepSOPClass, in: association)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        let messageID: UInt16 = 1
        let command = DicomDIMSECommandSet(
            affectedSOPClassUID: DicomNetworkUID.modalityPerformedProcedureStepSOPClass,
            commandField: DicomDIMSECommandField.nCreateRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            affectedSOPInstanceUID: request.sopInstanceUID
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        try sendDataSet(request.dataSet,
                        transferSyntax: transferSyntax,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))

        let reader = DicomDIMSEMessageReader()
        let response = try readCommand(using: transport, reader: reader)
        try expect(response, commandField: DicomDIMSECommandField.nCreateRSP)
        try validateSuccessStatus(response)
        let result = operationResult(from: response)
        progress?(.completed(operation: operation, status: result.status))
        return result
    }

    public func updateMPPS(_ request: DicomMPPSUpdateRequest,
                           progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        try performWithResilience(operation: .mppsUpdate, progress: progress) { transport in
            try updateMPPS(request, using: transport, progress: progress)
        }
    }

    public func updateMPPS(_ request: DicomMPPSUpdateRequest,
                           using transport: DicomAssociationTransport,
                           progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        let operation = DicomDIMSEOperation.mppsUpdate
        let association = try openAssociation(
            for: operation,
            abstractSyntaxUIDs: [DicomNetworkUID.modalityPerformedProcedureStepSOPClass],
            using: transport,
            progress: progress
        )
        defer { try? release(operation: operation, using: transport, progress: progress) }

        let context = try acceptedContext(DicomNetworkUID.modalityPerformedProcedureStepSOPClass, in: association)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        let messageID: UInt16 = 1
        let command = DicomDIMSECommandSet(
            requestedSOPClassUID: DicomNetworkUID.modalityPerformedProcedureStepSOPClass,
            commandField: DicomDIMSECommandField.nSetRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            requestedSOPInstanceUID: request.sopInstanceUID
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        try sendDataSet(request.dataSet,
                        transferSyntax: transferSyntax,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))

        let reader = DicomDIMSEMessageReader()
        let response = try readCommand(using: transport, reader: reader)
        try expect(response, commandField: DicomDIMSECommandField.nSetRSP)
        try validateSuccessStatus(response)
        let result = operationResult(from: response)
        progress?(.completed(operation: operation, status: result.status))
        return result
    }

    public func sendPrintJob(_ job: DicomPrintJob,
                             progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomPrintJobResult {
        try performWithResilience(operation: .printManagement, progress: progress) { transport in
            try sendPrintJob(job, using: transport, progress: progress)
        }
    }

    public func sendPrintJob(_ job: DicomPrintJob,
                             using transport: DicomAssociationTransport,
                             progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomPrintJobResult {
        let operation = DicomDIMSEOperation.printManagement
        let association = try openAssociation(
            for: operation,
            abstractSyntaxUIDs: [
                DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass,
                DicomNetworkUID.basicFilmSessionSOPClass,
                DicomNetworkUID.basicFilmBoxSOPClass,
                DicomNetworkUID.basicGrayscaleImageBoxSOPClass
            ],
            using: transport,
            progress: progress
        )
        defer { try? release(operation: operation, using: transport, progress: progress) }

        let context = try acceptedPrintContext(in: association)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        let reader = DicomDIMSEMessageReader()

        _ = try sendNormalizedCreate(
            operation: operation,
            affectedSOPClassUID: DicomNetworkUID.basicFilmSessionSOPClass,
            affectedSOPInstanceUID: job.filmSessionSOPInstanceUID,
            dataSet: job.filmSession.dataSet,
            responseCommandField: DicomDIMSECommandField.nCreateRSP,
            messageID: 1,
            context: context,
            transferSyntax: transferSyntax,
            association: association,
            transport: transport,
            reader: reader,
            progress: progress
        )

        let filmBoxCreate = try sendNormalizedCreate(
            operation: operation,
            affectedSOPClassUID: DicomNetworkUID.basicFilmBoxSOPClass,
            affectedSOPInstanceUID: job.filmBoxSOPInstanceUID,
            dataSet: job.filmBox.dataSet(referencingFilmSessionUID: job.filmSessionSOPInstanceUID),
            responseCommandField: DicomDIMSECommandField.nCreateRSP,
            messageID: 2,
            context: context,
            transferSyntax: transferSyntax,
            association: association,
            transport: transport,
            reader: reader,
            progress: progress
        )

        let imageBoxUIDs = imageBoxUIDs(from: filmBoxCreate.dataSet,
                                       expectedCount: job.imageBoxes.count)
        for (index, imageBox) in job.imageBoxes.enumerated() {
            let imageBoxUID = imageBoxUIDs[index]
            _ = try sendNormalizedSet(
                operation: operation,
                requestedSOPClassUID: DicomNetworkUID.basicGrayscaleImageBoxSOPClass,
                requestedSOPInstanceUID: imageBoxUID,
                dataSet: imageBox.dataSet,
                messageID: UInt16(index + 3),
                context: context,
                transferSyntax: transferSyntax,
                association: association,
                transport: transport,
                reader: reader,
                progress: progress
            )
        }

        let printResult = try sendNormalizedAction(
            operation: operation,
            requestedSOPClassUID: DicomNetworkUID.basicFilmBoxSOPClass,
            requestedSOPInstanceUID: job.filmBoxSOPInstanceUID,
            actionTypeID: 1,
            messageID: UInt16(job.imageBoxes.count + 3),
            context: context,
            association: association,
            transport: transport,
            reader: reader,
            progress: progress
        )
        progress?(.completed(operation: operation, status: printResult.status))
        return DicomPrintJobResult(operation: printResult,
                                   filmSessionSOPInstanceUID: job.filmSessionSOPInstanceUID,
                                   filmBoxSOPInstanceUID: job.filmBoxSOPInstanceUID,
                                   imageBoxSOPInstanceUIDs: imageBoxUIDs)
    }
}

private extension DicomDIMSEServiceSCU {
    func performWithResilience<Result>(
        operation: DicomDIMSEOperation,
        progress: ((DicomDIMSEProgress) -> Void)?,
        _ body: (DicomAssociationTransport) throws -> Result
    ) throws -> Result {
        try validateSecureUserIdentityTransport()
        try operationHandle?.checkCancellation(operation: operation)

        let retryPolicy = configuration.retryPolicy
        var lastError: Error?

        for attempt in 1...retryPolicy.maxAttempts {
            if let circuitBreaker, !circuitBreaker.allowRequest() {
                let error = DicomNetworkError.circuitBreakerOpen(operation.rawValue)
                recordAudit(operation: operation,
                            outcome: .blocked,
                            attempt: attempt,
                            error: error)
                throw error
            }

            recordAudit(operation: operation,
                        outcome: .started,
                        attempt: attempt)
            do {
                let transport = try makeTransport()
                var shouldRecycleAssociation = false
                var transportError: Error?
                if let cancellable = transport as? DicomCancellableAssociationTransport {
                    operationHandle?.setCancelAction {
                        cancellable.close()
                    }
                }
                defer {
                    operationHandle?.clearCancelAction()
                    finishTransport(
                        transport,
                        reusable: shouldRecycleAssociation,
                        error: transportError
                    )
                }
                do {
                    try operationHandle?.checkCancellation(operation: operation)
                    let result = try body(transport)
                    try operationHandle?.checkCancellation(operation: operation)
                    shouldRecycleAssociation = true
                    circuitBreaker?.recordSuccess()
                    recordAudit(operation: operation,
                                outcome: .succeeded,
                                attempt: attempt,
                                status: statusCode(from: result))
                    return result
                } catch {
                    transportError = error
                    throw error
                }
            } catch {
                if let cancelled = cancellationError(for: error, operation: operation) {
                    recordAudit(operation: operation,
                                outcome: .failed,
                                attempt: attempt,
                                error: cancelled)
                    throw cancelled
                }
                circuitBreaker?.recordFailure()
                lastError = error
                let shouldRetry = attempt < retryPolicy.maxAttempts
                recordAudit(operation: operation,
                            outcome: shouldRetry ? .retrying : .failed,
                            attempt: attempt,
                            error: error)
                if shouldRetry, retryPolicy.retryDelay > 0 {
                    Thread.sleep(forTimeInterval: retryPolicy.retryDelay)
                }
            }
        }

        throw lastError ?? DicomNetworkError.networkUnavailable("DIMSE operation failed without an underlying error.")
    }

    func cancellationError(for error: Error, operation: DicomDIMSEOperation) -> Error? {
        if operationHandle?.isCancelled == true {
            return DicomNetworkError.operationCancelled(operation.rawValue)
        }
        if error is CancellationError {
            return error
        }
        if let networkError = error as? DicomNetworkError,
           case .operationCancelled = networkError {
            return networkError
        }
        return nil
    }

    func makeTransport() throws -> DicomAssociationTransport {
        if let associationPool {
            return associationPool.makeLease(for: configuration) {
                try makeStandaloneTransport()
            }
        }
        return try makeStandaloneTransport()
    }

    func makeStandaloneTransport() throws -> DicomAssociationTransport {
        if let transportFactory {
            return try transportFactory()
        }
        #if canImport(Network)
        let transport = DicomTCPAssociationTransport(host: configuration.host,
                                                     port: configuration.port,
                                                     timeout: configuration.timeout,
                                                     tls: configuration.tls,
                                                     maximumIncomingPDUSize: configuration.maximumPDULength)
        try transport.open()
        if let bytesPerSecond = configuration.bandwidthLimitBytesPerSecond {
            return DicomBandwidthLimitedTransport(wrapping: transport,
                                                 bytesPerSecond: bytesPerSecond)
        }
        return transport
        #else
        throw DicomNetworkError.networkUnavailable("Network.framework is not available on this platform.")
        #endif
    }

    func finishTransport(
        _ transport: DicomAssociationTransport,
        reusable: Bool,
        error: Error?
    ) {
        if let lease = transport as? DicomDIMSEAssociationLease {
            lease.finish(reusable: reusable, error: error)
        } else {
            (transport as? DicomCancellableAssociationTransport)?.close()
        }
    }

    func openAssociation(for operation: DicomDIMSEOperation,
                         abstractSyntaxUIDs: [String],
                         transferSyntaxes: [DicomTransferSyntax]? = nil,
                         using transport: DicomAssociationTransport,
                         progress: ((DicomDIMSEProgress) -> Void)?) throws -> DicomAssociation {
        try validateSecureUserIdentityTransport()

        progress?(.associationRequested(operation: operation,
                                        calledAETitle: configuration.calledAETitle))
        let request = DicomAssociationRequest(
            calledAETitle: configuration.calledAETitle,
            callingAETitle: configuration.callingAETitle,
            presentationContexts: presentationContexts(
                for: abstractSyntaxUIDs,
                transferSyntaxes: transferSyntaxes ?? configuration.transferSyntaxes
            ),
            maximumPDULength: configuration.maximumPDULength,
            userIdentity: configuration.userIdentity
        )
        let association: DicomAssociation
        if let lease = transport as? DicomDIMSEAssociationLease {
            association = try lease.association(for: request)
        } else {
            association = try DicomAssociationSCU(request: request).open(using: transport)
        }
        progress?(.associationAccepted(operation: operation))
        return association
    }

    func recordAudit(operation: DicomDIMSEOperation,
                     outcome: DicomNetworkAuditEvent.Outcome,
                     attempt: Int,
                     status: UInt16? = nil,
                     error: Error? = nil) {
        auditLogger?.record(DicomNetworkAuditEvent(
            operation: operation,
            outcome: outcome,
            host: configuration.host,
            port: configuration.port,
            calledAETitle: configuration.calledAETitle,
            attempt: attempt,
            status: status,
            errorDescription: error.map { auditDescription(for: $0) }
        ))
    }

    func statusCode<Result>(from result: Result) -> UInt16? {
        switch result {
        case let value as DicomDIMSEOperationResult:
            return value.status
        case let value as DicomCFindResult:
            return value.operation.status
        case let value as DicomCGetResult:
            return value.operation.status
        case let value as DicomPrintJobResult:
            return value.operation.status
        default:
            return nil
        }
    }

    func validateSecureUserIdentityTransport() throws {
        guard configuration.userIdentity == nil || configuration.tls.mode == .enabled else {
            throw DicomNetworkError.insecureUserIdentityTransport
        }
    }

    func auditDescription(for error: Error) -> String {
        guard let networkError = error as? DicomNetworkError else {
            return String(describing: type(of: error))
        }
        switch networkError {
        case .invalidAEString:
            return "Invalid AE title."
        case .invalidPDUType:
            return "Unsupported PDU type."
        case .invalidPDULength:
            return "Invalid PDU length."
        case .invalidItemType:
            return "Unsupported association item type."
        case .invalidPresentationContextID:
            return "Invalid presentation context ID."
        case .missingApplicationContext:
            return "Missing application context."
        case .missingPresentationContext:
            return "Missing presentation context."
        case .missingTransferSyntax:
            return "Missing transfer syntax."
        case .associationRejected:
            return "Association rejected by peer."
        case .associationAborted:
            return "Association aborted by peer."
        case .invalidAssociationState:
            return "Invalid association state."
        case .unsupportedPDU:
            return "Unsupported PDU."
        case .malformedCommandSet:
            return "Malformed DIMSE command set."
        case .missingAcceptedPresentationContext:
            return "Missing accepted presentation context."
        case .transferSyntaxMismatch:
            return "Transfer syntax mismatch."
        case .unexpectedDIMSECommand:
            return "Unexpected DIMSE command."
        case .dimseStatusFailure(let status):
            return String(format: "DIMSE status failure 0x%04X.", status)
        case .networkTimeout(let operation):
            return "Network timeout while \(operation)."
        case .networkUnavailable:
            return "Network transport unavailable."
        case .tlsConfigurationInvalid:
            return "TLS configuration invalid."
        case .tlsTrustEvaluationFailed:
            return "TLS trust evaluation failed."
        case .circuitBreakerOpen:
            return "Circuit breaker open."
        case .insecureUserIdentityTransport:
            return "User identity requires TLS."
        case .operationCancelled(let operation):
            return "DIMSE operation cancelled: \(operation)."
        }
    }

    func presentationContexts(for abstractSyntaxUIDs: [String],
                              transferSyntaxes: [DicomTransferSyntax]) -> [DicomPresentationContextRequest] {
        var nextID: UInt8 = 1
        var seen: Set<String> = []
        var contexts: [DicomPresentationContextRequest] = []
        for uid in abstractSyntaxUIDs where !seen.contains(uid) {
            seen.insert(uid)
            contexts.append(DicomPresentationContextRequest(
                id: nextID,
                abstractSyntaxUID: uid,
                transferSyntaxes: transferSyntaxes
            ))
            nextID += 2
        }
        return contexts
    }

    func acceptedContext(_ abstractSyntaxUID: String,
                         in association: DicomAssociation) throws -> DicomAcceptedPresentationContext {
        guard let context = association.acceptedPresentationContext(for: abstractSyntaxUID) else {
            throw DicomNetworkError.missingAcceptedPresentationContext(abstractSyntaxUID)
        }
        return context
    }

    func acceptedPrintContext(in association: DicomAssociation) throws -> DicomAcceptedPresentationContext {
        let supported = [
            DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass,
            DicomNetworkUID.basicFilmSessionSOPClass,
            DicomNetworkUID.basicFilmBoxSOPClass,
            DicomNetworkUID.basicGrayscaleImageBoxSOPClass
        ]
        for uid in supported {
            if let context = association.acceptedPresentationContext(for: uid) {
                return context
            }
        }
        throw DicomNetworkError.missingAcceptedPresentationContext(DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass)
    }

    func sendCommand(_ command: DicomDIMSECommandSet,
                     presentationContextID: UInt8,
                     association: DicomAssociation,
                     transport: DicomAssociationTransport) throws {
        let pdu = try association.commandPData(command,
                                               presentationContextID: presentationContextID)
        try transport.writePDU(DicomPDUCodec.encode(pdu))
    }

    func installCancelRequestAction(messageID: UInt16,
                                    presentationContextID: UInt8,
                                    association: DicomAssociation,
                                    transport: DicomAssociationTransport) {
        operationHandle?.setCancelAction {
            let command = DicomDIMSECommandSet(
                commandField: DicomDIMSECommandField.cCancelRQ,
                messageIDBeingRespondedTo: messageID,
                commandDataSetType: DicomDIMSECommandDataSetType.noDataSet
            )
            if let pdu = try? association.commandPData(command, presentationContextID: presentationContextID) {
                try? transport.writePDU(DicomPDUCodec.encode(pdu))
            }
            (transport as? DicomCancellableAssociationTransport)?.close()
        }
    }

    func sendDataSet(_ dataSet: DicomDataSet,
                     transferSyntax: DicomTransferSyntax,
                     presentationContextID: UInt8,
                     association: DicomAssociation,
                     transport: DicomAssociationTransport) throws {
        let data = try DicomDataSetWriter.dataSetData(from: dataSet,
                                                      transferSyntax: transferSyntax)
        try sendDataSetData(data,
                            presentationContextID: presentationContextID,
                            association: association,
                            transport: transport)
    }

    func sendDataSetData(_ data: Data,
                         presentationContextID: UInt8,
                         association: DicomAssociation,
                         transport: DicomAssociationTransport) throws {
        let pdvOverhead = 6
        let maximumPDULength = association.accept.maximumPDULength
        let maximumFragmentLength: Int
        if maximumPDULength == 0 {
            maximumFragmentLength = max(1, data.count)
        } else {
            guard maximumPDULength > pdvOverhead else {
                throw DicomNetworkError.invalidPDULength(
                    expected: pdvOverhead + 1,
                    actual: Int(maximumPDULength)
                )
            }
            maximumFragmentLength = Int(maximumPDULength) - pdvOverhead
        }

        if data.isEmpty {
            let pdu = try association.dataSetPData(
                data,
                presentationContextID: presentationContextID
            )
            try transport.writePDU(DicomPDUCodec.encode(pdu))
            return
        }

        var offset = data.startIndex
        while offset < data.endIndex {
            let fragmentLength = min(maximumFragmentLength, data.distance(from: offset, to: data.endIndex))
            let end = data.index(offset, offsetBy: fragmentLength)
            let fragment = data.subdata(in: offset..<end)
            let pdu = try association.dataSetPData(
                fragment,
                presentationContextID: presentationContextID,
                isLastFragment: end == data.endIndex
            )
            try transport.writePDU(DicomPDUCodec.encode(pdu))
            offset = end
        }
    }

    func readCommand(using transport: DicomAssociationTransport,
                     reader: DicomDIMSEMessageReader) throws -> DicomDIMSECommandSet {
        let message = try reader.readMessage(from: transport)
        guard message.isCommand else {
            throw DicomNetworkError.malformedCommandSet("Expected DIMSE command PDV.")
        }
        return try DicomDIMSECommandSet.decode(message.data)
    }

    func release(operation: DicomDIMSEOperation,
                 using transport: DicomAssociationTransport,
                 progress: ((DicomDIMSEProgress) -> Void)?) throws {
        if transport is DicomDIMSEAssociationLease {
            return
        }
        try transport.writePDU(DicomPDUCodec.encode(.releaseRequest))
        let response = try DicomPDUCodec.decode(try transport.readPDU())
        switch response {
        case .releaseResponse:
            progress?(.released(operation: operation))
        case .abort(let abort):
            throw DicomNetworkError.associationAborted(abort)
        default:
            throw DicomNetworkError.unsupportedPDU(response.type)
        }
    }

    func expect(_ command: DicomDIMSECommandSet, commandField: UInt16) throws {
        guard command.commandField == commandField else {
            throw DicomNetworkError.unexpectedDIMSECommand(expected: commandField,
                                                           actual: command.commandField)
        }
    }

    func validateSuccessStatus(_ command: DicomDIMSECommandSet) throws {
        let status = command.status ?? 0
        guard status == 0 else {
            throw DicomNetworkError.dimseStatusFailure(status)
        }
    }

    func validateRetrieveStatus(_ command: DicomDIMSECommandSet) throws {
        let status = command.status ?? 0
        guard status == 0 || status & 0xFF00 == 0xB000 else {
            throw DicomNetworkError.dimseStatusFailure(status)
        }
    }

    func isPending(_ status: UInt16) -> Bool {
        status == 0xFF00 || status == 0xFF01
    }

    func operationResult(from command: DicomDIMSECommandSet) -> DicomDIMSEOperationResult {
        DicomDIMSEOperationResult(status: command.status ?? 0,
                                  remainingSuboperations: command.remainingSuboperations,
                                  completedSuboperations: command.completedSuboperations,
                                  failedSuboperations: command.failedSuboperations,
                                  warningSuboperations: command.warningSuboperations)
    }

    func sendNormalizedCreate(operation: DicomDIMSEOperation,
                              affectedSOPClassUID: String,
                              affectedSOPInstanceUID: String,
                              dataSet: DicomDataSet,
                              responseCommandField: UInt16,
                              messageID: UInt16,
                              context: DicomAcceptedPresentationContext,
                              transferSyntax: DicomTransferSyntax,
                              association: DicomAssociation,
                              transport: DicomAssociationTransport,
                              reader: DicomDIMSEMessageReader,
                              progress: ((DicomDIMSEProgress) -> Void)?) throws -> (result: DicomDIMSEOperationResult, dataSet: DicomDataSet?) {
        let command = DicomDIMSECommandSet(
            affectedSOPClassUID: affectedSOPClassUID,
            commandField: DicomDIMSECommandField.nCreateRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            affectedSOPInstanceUID: affectedSOPInstanceUID
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        try sendDataSet(dataSet,
                        transferSyntax: transferSyntax,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))
        let response = try readCommand(using: transport, reader: reader)
        try expect(response, commandField: responseCommandField)
        try validateSuccessStatus(response)
        return (operationResult(from: response),
                try readOptionalDataSet(response: response,
                                        transferSyntax: transferSyntax,
                                        transport: transport,
                                        reader: reader))
    }

    func sendNormalizedSet(operation: DicomDIMSEOperation,
                           requestedSOPClassUID: String,
                           requestedSOPInstanceUID: String,
                           dataSet: DicomDataSet,
                           messageID: UInt16,
                           context: DicomAcceptedPresentationContext,
                           transferSyntax: DicomTransferSyntax,
                           association: DicomAssociation,
                           transport: DicomAssociationTransport,
                           reader: DicomDIMSEMessageReader,
                           progress: ((DicomDIMSEProgress) -> Void)?) throws -> DicomDIMSEOperationResult {
        let command = DicomDIMSECommandSet(
            requestedSOPClassUID: requestedSOPClassUID,
            commandField: DicomDIMSECommandField.nSetRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            requestedSOPInstanceUID: requestedSOPInstanceUID
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        try sendDataSet(dataSet,
                        transferSyntax: transferSyntax,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))
        let response = try readCommand(using: transport, reader: reader)
        try expect(response, commandField: DicomDIMSECommandField.nSetRSP)
        try validateSuccessStatus(response)
        return operationResult(from: response)
    }

    func sendNormalizedAction(operation: DicomDIMSEOperation,
                              requestedSOPClassUID: String,
                              requestedSOPInstanceUID: String,
                              actionTypeID: UInt16,
                              messageID: UInt16,
                              context: DicomAcceptedPresentationContext,
                              association: DicomAssociation,
                              transport: DicomAssociationTransport,
                              reader: DicomDIMSEMessageReader,
                              progress: ((DicomDIMSEProgress) -> Void)?) throws -> DicomDIMSEOperationResult {
        let command = DicomDIMSECommandSet(
            requestedSOPClassUID: requestedSOPClassUID,
            commandField: DicomDIMSECommandField.nActionRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
            requestedSOPInstanceUID: requestedSOPInstanceUID,
            actionTypeID: actionTypeID
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))
        let response = try readCommand(using: transport, reader: reader)
        try expect(response, commandField: DicomDIMSECommandField.nActionRSP)
        try validateSuccessStatus(response)
        return operationResult(from: response)
    }

    func readOptionalDataSet(response: DicomDIMSECommandSet,
                             transferSyntax: DicomTransferSyntax,
                             transport: DicomAssociationTransport,
                             reader: DicomDIMSEMessageReader) throws -> DicomDataSet? {
        guard response.commandDataSetType != DicomDIMSECommandDataSetType.noDataSet else {
            return nil
        }
        let payload = try reader.readMessage(from: transport)
        guard !payload.isCommand else {
            throw DicomNetworkError.malformedCommandSet("Expected DIMSE response dataset.")
        }
        return try DicomDataSetParser.dataSet(from: payload.data,
                                              transferSyntax: transferSyntax)
    }

    func imageBoxUIDs(from dataSet: DicomDataSet?, expectedCount: Int) -> [String] {
        let referenced = dataSet?
            .sequenceItems(for: DicomPrintTag.referencedImageBoxSequence)
            .compactMap { $0.dataSet.string(for: .referencedSOPInstanceUID) } ?? []
        guard referenced.count >= expectedCount else {
            return (0..<expectedCount).map { _ in DicomDataSetWriter.makeUID() }
        }
        return Array(referenced.prefix(expectedCount))
    }

    func progressPending(operation: DicomDIMSEOperation,
                         response: DicomDIMSECommandSet,
                         progress: ((DicomDIMSEProgress) -> Void)?) {
        progress?(.pending(operation: operation,
                           remaining: response.remainingSuboperations,
                           completed: response.completedSuboperations,
                           failed: response.failedSuboperations,
                           warning: response.warningSuboperations))
    }

    func receiveStoreRequest(_ command: DicomDIMSECommandSet,
                             association: DicomAssociation,
                             transport: DicomAssociationTransport,
                             reader: DicomDIMSEMessageReader) throws -> DicomRetrievedInstance {
        let sopClassUID = command.affectedSOPClassUID
        let context = try acceptedContext(sopClassUID ?? DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                                          in: association)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        let payload = try reader.readMessage(from: transport)
        guard !payload.isCommand else {
            throw DicomNetworkError.malformedCommandSet("Expected C-STORE dataset.")
        }
        let response = DicomDIMSECommandSet(
            affectedSOPClassUID: sopClassUID,
            commandField: DicomDIMSECommandField.cStoreRSP,
            messageIDBeingRespondedTo: command.messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
            status: 0,
            affectedSOPInstanceUID: command.affectedSOPInstanceUID
        )
        try sendCommand(response,
                        presentationContextID: payload.presentationContextID,
                        association: association,
                        transport: transport)
        return DicomRetrievedInstance(sopClassUID: sopClassUID,
                                      sopInstanceUID: command.affectedSOPInstanceUID,
                                      transferSyntax: transferSyntax,
                                      data: payload.data,
                                      dataSet: nil)
    }

    func storageDataSet(_ dataSet: DicomDataSet,
                        sopClassUID: String?,
                        sopInstanceUID: String?) -> (dataSet: DicomDataSet, sopClassUID: String, sopInstanceUID: String) {
        let resolvedClassUID = sopClassUID ??
            dataSet.string(for: .sopClassUID) ??
            DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        let resolvedInstanceUID = sopInstanceUID ??
            dataSet.string(for: .sopInstanceUID) ??
            DicomDataSetWriter.makeUID()
        var updated = dataSet
        if updated.string(for: .sopClassUID) == nil {
            updated.set(DicomDataElement(tag: DicomTag.sopClassUID.rawValue,
                                         vr: .UI,
                                         value: .strings([resolvedClassUID])))
        }
        if updated.string(for: .sopInstanceUID) == nil {
            updated.set(DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue,
                                         vr: .UI,
                                         value: .strings([resolvedInstanceUID])))
        }
        return (updated, resolvedClassUID, resolvedInstanceUID)
    }
}

enum DicomDIMSEReadResult {
    case message(DicomDIMSEMessage)
    case releaseRequest
}

struct DicomDIMSEMessage {
    var presentationContextID: UInt8
    var isCommand: Bool
    var data: Data
}

final class DicomDIMSEMessageReader {
    private var pendingPDVs: [DicomPDV] = []
    private var pendingPDVIndex = 0

    func readMessage(from transport: DicomAssociationTransport) throws -> DicomDIMSEMessage {
        switch try readNext(from: transport) {
        case .message(let message):
            return message
        case .releaseRequest:
            throw DicomNetworkError.unsupportedPDU(DicomPDUType.releaseRequest)
        }
    }

    func readNext(from transport: DicomAssociationTransport) throws -> DicomDIMSEReadResult {
        var contextID: UInt8?
        var isCommand: Bool?
        var data = Data()

        while true {
            while pendingPDVIndex == pendingPDVs.count {
                pendingPDVs.removeAll(keepingCapacity: true)
                pendingPDVIndex = 0
                let pdu = try DicomPDUCodec.decode(try transport.readPDU())
                switch pdu {
                case .pData(let pdvs):
                    pendingPDVs.append(contentsOf: pdvs)
                case .releaseRequest:
                    return .releaseRequest
                case .abort(let abort):
                    throw DicomNetworkError.associationAborted(abort)
                default:
                    throw DicomNetworkError.unsupportedPDU(pdu.type)
                }
            }

            let pdv = pendingPDVs[pendingPDVIndex]
            pendingPDVIndex += 1
            if contextID == nil {
                contextID = pdv.presentationContextID
                isCommand = pdv.isCommand
            }
            guard contextID == pdv.presentationContextID,
                  isCommand == pdv.isCommand else {
                throw DicomNetworkError.malformedCommandSet("Mixed PDV fragments in one DIMSE message.")
            }
            data.append(pdv.data)
            if pdv.isLastFragment {
                return .message(DicomDIMSEMessage(presentationContextID: contextID ?? pdv.presentationContextID,
                                                  isCommand: isCommand ?? pdv.isCommand,
                                                  data: data))
            }
        }
    }
}

#if canImport(Network)
public final class DicomTCPAssociationTransport: DicomCancellableAssociationTransport {
    private static let hardMaximumIncomingPDUSize: UInt32 = 64 * 1_024 * 1_024

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "DicomTCPAssociationTransport")
    private let timeout: TimeInterval
    private let maximumIncomingPDUSize: Int
    private let tlsContext: DicomAppliedTLSContext?
    private let tlsSetupError: Error?
    private let stateLock = NSLock()
    private var isOpenStorage = false

    public var isOpen: Bool {
        stateLock.lock()
        let value = isOpenStorage
        stateLock.unlock()
        return value
    }

    public init(host: String,
                port: UInt16,
                timeout: TimeInterval = 10,
                tls: DicomTLSConfiguration = .disabled,
                maximumIncomingPDUSize: UInt32 = 16_384) {
        let nwPort = NWEndpoint.Port(rawValue: port) ?? 104
        let prepared: DicomPreparedNetworkParameters
        do {
            prepared = try DicomTLSOptionsFactory.preparedParameters(for: tls, role: .client)
            tlsSetupError = nil
        } catch {
            prepared = DicomPreparedNetworkParameters(parameters: .tcp, tlsContext: nil)
            tlsSetupError = error
        }
        self.connection = NWConnection(host: NWEndpoint.Host(host),
                                       port: nwPort,
                                       using: prepared.parameters)
        self.timeout = timeout
        self.maximumIncomingPDUSize = Self.resolvedIncomingPDUSize(maximumIncomingPDUSize)
        self.tlsContext = prepared.tlsContext
    }

    public init(acceptedConnection: NWConnection,
                timeout: TimeInterval = 10,
                maximumIncomingPDUSize: UInt32 = 16_384) {
        self.connection = acceptedConnection
        self.timeout = timeout
        self.maximumIncomingPDUSize = Self.resolvedIncomingPDUSize(maximumIncomingPDUSize)
        self.tlsContext = nil
        self.tlsSetupError = nil
    }

    public func open() throws {
        if let tlsSetupError {
            throw tlsSetupError
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>?
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.setIsOpen(true)
                result = .success(())
                semaphore.signal()
            case .failed(let error):
                self?.setIsOpen(false)
                result = .failure(error)
                semaphore.signal()
            case .cancelled:
                self?.setIsOpen(false)
            default:
                break
            }
        }
        connection.start(queue: queue)
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw DicomNetworkError.networkTimeout("opening TCP connection")
        }
        try result?.get()
    }

    public func startAcceptedConnection() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.setIsOpen(true)
            case .failed, .cancelled:
                self?.setIsOpen(false)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func writePDU(_ data: Data) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>?
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                result = .failure(error)
            } else {
                result = .success(())
            }
            semaphore.signal()
        })
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw DicomNetworkError.networkTimeout("writing PDU")
        }
        try result?.get()
    }

    public func readPDU() throws -> Data {
        let header = try readExact(count: 6)
        let length = try Self.validatedPDUBodyLength(
            from: header,
            maximumIncomingPDUSize: maximumIncomingPDUSize
        )
        var data = header
        data.append(try readExact(count: length))
        return data
    }

    static func validatedPDUBodyLength(
        from header: Data,
        maximumIncomingPDUSize: Int
    ) throws -> Int {
        guard header.count == 6 else {
            throw DicomNetworkError.invalidPDULength(expected: 6, actual: header.count)
        }
        let length = Int(header.dicomInteger(at: 2, as: UInt32.self, littleEndian: false))
        guard length <= maximumIncomingPDUSize else {
            throw DicomNetworkError.invalidPDULength(expected: maximumIncomingPDUSize, actual: length)
        }
        return length
    }

    private static func resolvedIncomingPDUSize(_ configuredSize: UInt32) -> Int {
        if configuredSize == 0 {
            return Int(hardMaximumIncomingPDUSize)
        }
        return Int(min(configuredSize, hardMaximumIncomingPDUSize))
    }

    public func close() {
        setIsOpen(false)
        connection.cancel()
    }

    deinit {
        connection.cancel()
    }

    private func setIsOpen(_ value: Bool) {
        stateLock.lock()
        isOpenStorage = value
        stateLock.unlock()
    }

    private func readExact(count: Int) throws -> Data {
        try Self.readExact(count: count) { minimumIncompleteLength, maximumLength in
            try receive(
                minimumIncompleteLength: minimumIncompleteLength,
                maximumLength: maximumLength
            )
        }
    }

    static func readExact(
        count: Int,
        receive: (_ minimumIncompleteLength: Int, _ maximumLength: Int) throws -> Data
    ) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            let remaining = count - data.count
            let chunk = try receive(remaining, remaining)
            guard !chunk.isEmpty else {
                throw DicomNetworkError.networkUnavailable("Peer closed the TCP connection.")
            }
            if data.isEmpty, chunk.count == count {
                return chunk
            }
            data.append(chunk)
        }
        return data
    }

    private func receive(minimumIncompleteLength: Int, maximumLength: Int) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        connection.receive(minimumIncompleteLength: minimumIncompleteLength,
                           maximumLength: maximumLength) { content, _, isComplete, error in
            if let error {
                result = .failure(error)
            } else if let content, !content.isEmpty {
                result = .success(content)
            } else if isComplete {
                result = .success(Data())
            } else {
                result = .success(Data())
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw DicomNetworkError.networkTimeout("reading PDU")
        }
        return try result?.get() ?? Data()
    }
}
#endif
