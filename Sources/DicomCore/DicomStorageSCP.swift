import Foundation
#if canImport(Network)
import Network
#endif

public enum DicomStorageSCPError: Error, Equatable, Sendable {
    case associationRequestExpected
    case calledAETitleNotRecognized(String)
    case missingCommandDataSet(UInt16)
    case missingPresentationContext(UInt8)
    case malformedStorageCommitmentRequest
}

extension DicomStorageSCPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .associationRequestExpected:
            return "Expected an A-ASSOCIATE-RQ PDU before Storage SCP commands."
        case .calledAETitleNotRecognized(let value):
            return "Called AE title \(value) is not recognized by this Storage SCP."
        case .missingCommandDataSet(let command):
            return String(format: "DIMSE command 0x%04X requires a dataset.", command)
        case .missingPresentationContext(let id):
            return "No accepted presentation context for ID \(id)."
        case .malformedStorageCommitmentRequest:
            return "Storage Commitment request does not include a transaction UID and referenced SOP sequence."
        }
    }
}

public enum DicomStorageSOPClassUIDs {
    public static let computedRadiographyImageStorage = "1.2.840.10008.5.1.4.1.1.1"
    public static let ctImageStorage = "1.2.840.10008.5.1.4.1.1.2"
    public static let enhancedCTImageStorage = "1.2.840.10008.5.1.4.1.1.2.1"
    public static let mrImageStorage = "1.2.840.10008.5.1.4.1.1.4"
    public static let enhancedMRImageStorage = "1.2.840.10008.5.1.4.1.1.4.1"
    public static let ultrasoundImageStorage = "1.2.840.10008.5.1.4.1.1.6.1"
    public static let secondaryCaptureImageStorage = DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
    public static let positronEmissionTomographyImageStorage = "1.2.840.10008.5.1.4.1.1.128"

    public static let commonClinicalStorage: Set<String> = [
        computedRadiographyImageStorage,
        ctImageStorage,
        enhancedCTImageStorage,
        mrImageStorage,
        enhancedMRImageStorage,
        ultrasoundImageStorage,
        secondaryCaptureImageStorage,
        positronEmissionTomographyImageStorage,
        DicomSegmentationBuilder.segmentationStorageSOPClassUID,
        DicomRTStructureSet.storageSOPClassUID,
        DicomRTDoseVolume.storageSOPClassUID,
        DicomRTPlan.storageSOPClassUID,
        DicomParametricMap.storageSOPClassUID,
        DicomSecondaryCaptureImage.storageSOPClassUID,
        DicomGrayscalePresentationState.storageSOPClassUID
    ]
}

public struct DicomStorageSCPConfiguration: Equatable, Sendable {
    public var aeTitle: String
    public var port: UInt16
    public var supportedStorageSOPClassUIDs: Set<String>
    public var transferSyntaxes: [DicomTransferSyntax]
    public var maximumPDULength: UInt32
    public var timeout: TimeInterval
    public var acceptAnyCalledAETitle: Bool
    public var enableStorageCommitment: Bool
    public var tls: DicomTLSConfiguration

    public init(aeTitle: String,
                port: UInt16 = 11112,
                supportedStorageSOPClassUIDs: Set<String> = DicomStorageSOPClassUIDs.commonClinicalStorage,
                transferSyntaxes: [DicomTransferSyntax] = [.explicitVRLittleEndian, .implicitVRLittleEndian],
                maximumPDULength: UInt32 = 16_384,
                timeout: TimeInterval = 10,
                acceptAnyCalledAETitle: Bool = false,
                enableStorageCommitment: Bool = true,
                tls: DicomTLSConfiguration = .disabled) {
        self.aeTitle = aeTitle
        self.port = port
        self.supportedStorageSOPClassUIDs = supportedStorageSOPClassUIDs
        self.transferSyntaxes = transferSyntaxes
        self.maximumPDULength = maximumPDULength
        self.timeout = timeout
        self.acceptAnyCalledAETitle = acceptAnyCalledAETitle
        self.enableStorageCommitment = enableStorageCommitment
        self.tls = tls
    }
}

public struct DicomStorageReceivedInstance: Equatable, Sendable {
    public var sopClassUID: String
    public var sopInstanceUID: String
    public var transferSyntax: DicomTransferSyntax
    /// Metadata-only parsed dataset. Pixel Data remains available in `rawDataSetData`.
    public var dataSet: DicomDataSet {
        didSet { rawDataSetData = nil }
    }
    public var rawDataSetData: Data?
    public var receivedAt: Date

    public init(sopClassUID: String,
                sopInstanceUID: String,
                transferSyntax: DicomTransferSyntax,
                dataSet: DicomDataSet,
                rawDataSetData: Data? = nil,
                receivedAt: Date = Date()) {
        self.sopClassUID = sopClassUID
        self.sopInstanceUID = sopInstanceUID
        self.transferSyntax = transferSyntax
        self.dataSet = dataSet
        self.rawDataSetData = rawDataSetData
        self.receivedAt = receivedAt
    }
}

public struct DicomStoredInstance: Equatable, Sendable {
    public var sopClassUID: String
    public var sopInstanceUID: String
    public var transferSyntax: DicomTransferSyntax
    public var fileURL: URL
    public var storedAt: Date

    public init(sopClassUID: String,
                sopInstanceUID: String,
                transferSyntax: DicomTransferSyntax,
                fileURL: URL,
                storedAt: Date = Date()) {
        self.sopClassUID = sopClassUID
        self.sopInstanceUID = sopInstanceUID
        self.transferSyntax = transferSyntax
        self.fileURL = fileURL
        self.storedAt = storedAt
    }
}

public protocol DicomStorageInstanceStoring: AnyObject {
    func store(_ instance: DicomStorageReceivedInstance) throws -> DicomStoredInstance
}

public final class DicomFileStorageCache: DicomStorageInstanceStoring {
    public let directoryURL: URL

    public init(directoryURL: URL) throws {
        self.directoryURL = directoryURL
        try FileManager.default.createDirectory(at: directoryURL,
                                                withIntermediateDirectories: true)
    }

    public func store(_ instance: DicomStorageReceivedInstance) throws -> DicomStoredInstance {
        let fileURL = directoryURL.appendingPathComponent(Self.fileName(for: instance.sopInstanceUID))
        if let rawDataSetData = instance.rawDataSetData {
            try DicomDataSetWriter.validateWriteSupport(
                for: instance.dataSet,
                transferSyntax: instance.transferSyntax
            )
            let part10Data = try DicomDataSetWriter.part10Data(
                fromEncodedDataSet: rawDataSetData,
                transferSyntax: instance.transferSyntax,
                mediaStorageSOPClassUID: instance.sopClassUID,
                mediaStorageSOPInstanceUID: instance.sopInstanceUID
            )
            try part10Data.write(to: fileURL, options: [.atomic])
        } else {
            try DicomDataSetWriter.write(
                instance.dataSet,
                to: fileURL,
                options: DicomPart10WriterOptions(
                    transferSyntax: instance.transferSyntax,
                    mediaStorageSOPClassUID: instance.sopClassUID,
                    mediaStorageSOPInstanceUID: instance.sopInstanceUID
                )
            )
        }
        return DicomStoredInstance(sopClassUID: instance.sopClassUID,
                                   sopInstanceUID: instance.sopInstanceUID,
                                   transferSyntax: instance.transferSyntax,
                                   fileURL: fileURL)
    }

    public static func fileName(for sopInstanceUID: String) -> String {
        let safe = sopInstanceUID.map { character -> Character in
            character.isLetter || character.isNumber || character == "." ? character : "_"
        }
        return "\(String(safe)).dcm"
    }
}

public enum DicomStorageCommitmentReferenceStatus: String, Codable, Equatable, Sendable {
    case committed
    case failed
}

public enum DicomStorageCommitmentReportStatus: String, Codable, Equatable, Sendable {
    case committed
    case partial
    case failed
}

public struct DicomStorageCommitmentReference: Codable, Equatable, Sendable {
    public var sopClassUID: String
    public var sopInstanceUID: String
    public var status: DicomStorageCommitmentReferenceStatus
    public var failureReason: String?

    public init(sopClassUID: String,
                sopInstanceUID: String,
                status: DicomStorageCommitmentReferenceStatus = .committed,
                failureReason: String? = nil) {
        self.sopClassUID = sopClassUID
        self.sopInstanceUID = sopInstanceUID
        self.status = status
        self.failureReason = failureReason
    }
}

public struct DicomStorageCommitmentReport: Codable, Equatable, Sendable {
    public var transactionUID: String
    public var status: DicomStorageCommitmentReportStatus
    public var references: [DicomStorageCommitmentReference]

    public init(transactionUID: String,
                status: DicomStorageCommitmentReportStatus,
                references: [DicomStorageCommitmentReference]) {
        self.transactionUID = transactionUID
        self.status = status
        self.references = references
    }
}

public final class DicomStorageCommitmentTracker {
    private var storedKeys: Set<String> = []
    private var reportsByTransactionUID: [String: DicomStorageCommitmentReport] = [:]
    private let lock = NSLock()

    public init(storedInstances: [DicomStoredInstance] = []) {
        storedKeys = Set(storedInstances.map(Self.key))
    }

    public func recordStoredInstance(_ instance: DicomStoredInstance) {
        lock.lock()
        storedKeys.insert(Self.key(instance.sopClassUID, instance.sopInstanceUID))
        lock.unlock()
    }

    public func evaluate(transactionUID: String,
                         references: [DicomStorageCommitmentReference]) -> DicomStorageCommitmentReport {
        let evaluated = references.map { reference -> DicomStorageCommitmentReference in
            lock.lock()
            let isStored = storedKeys.contains(Self.key(reference.sopClassUID, reference.sopInstanceUID))
            lock.unlock()
            guard isStored else {
                return DicomStorageCommitmentReference(sopClassUID: reference.sopClassUID,
                                                       sopInstanceUID: reference.sopInstanceUID,
                                                       status: .failed,
                                                       failureReason: "Referenced SOP instance is not stored.")
            }
            return DicomStorageCommitmentReference(sopClassUID: reference.sopClassUID,
                                                   sopInstanceUID: reference.sopInstanceUID,
                                                   status: .committed)
        }
        let report = DicomStorageCommitmentReport(transactionUID: transactionUID,
                                                  status: Self.reportStatus(for: evaluated),
                                                  references: evaluated)
        lock.lock()
        reportsByTransactionUID[transactionUID] = report
        lock.unlock()
        return report
    }

    public func report(for transactionUID: String) -> DicomStorageCommitmentReport? {
        lock.lock()
        let report = reportsByTransactionUID[transactionUID]
        lock.unlock()
        return report
    }

    public static func actionDataSet(transactionUID: String,
                                     references: [DicomStorageCommitmentReference]) -> DicomDataSet {
        DicomDataSet(elements: [
            string(StorageCommitmentTags.transactionUID, vr: .UI, transactionUID),
            sequence(StorageCommitmentTags.referencedSOPSequence, references.map(referenceItem))
        ])
    }

    public static func parseActionDataSet(_ dataSet: DicomDataSet) throws -> (String, [DicomStorageCommitmentReference]) {
        guard let transactionUID = dataSet.string(for: StorageCommitmentTags.transactionUID),
              !transactionUID.isEmpty else {
            throw DicomStorageSCPError.malformedStorageCommitmentRequest
        }
        let references = dataSet.sequenceItems(for: StorageCommitmentTags.referencedSOPSequence).compactMap { item in
            reference(from: item.dataSet, status: .committed)
        }
        guard !references.isEmpty else {
            throw DicomStorageSCPError.malformedStorageCommitmentRequest
        }
        return (transactionUID, references)
    }

    public static func eventReportDataSet(for report: DicomStorageCommitmentReport) -> DicomDataSet {
        let committed = report.references.filter { $0.status == .committed }
        let failed = report.references.filter { $0.status == .failed }
        var elements = [
            string(StorageCommitmentTags.transactionUID, vr: .UI, report.transactionUID),
            sequence(StorageCommitmentTags.referencedSOPSequence, committed.map(referenceItem))
        ]
        if !failed.isEmpty {
            elements.append(sequence(StorageCommitmentTags.failedSOPSequence, failed.map(referenceItem)))
        }
        return DicomDataSet(elements: elements)
    }

    public static func parseEventReportDataSet(_ dataSet: DicomDataSet) throws -> DicomStorageCommitmentReport {
        guard let transactionUID = dataSet.string(for: StorageCommitmentTags.transactionUID),
              !transactionUID.isEmpty else {
            throw DicomStorageSCPError.malformedStorageCommitmentRequest
        }
        let committed = dataSet.sequenceItems(for: StorageCommitmentTags.referencedSOPSequence).compactMap {
            reference(from: $0.dataSet, status: .committed)
        }
        let failed = dataSet.sequenceItems(for: StorageCommitmentTags.failedSOPSequence).compactMap {
            reference(from: $0.dataSet, status: .failed)
        }
        let references = committed + failed
        guard !references.isEmpty else {
            throw DicomStorageSCPError.malformedStorageCommitmentRequest
        }
        return DicomStorageCommitmentReport(transactionUID: transactionUID,
                                            status: reportStatus(for: references),
                                            references: references)
    }

    private static func key(_ instance: DicomStoredInstance) -> String {
        key(instance.sopClassUID, instance.sopInstanceUID)
    }

    private static func key(_ sopClassUID: String, _ sopInstanceUID: String) -> String {
        "\(sopClassUID)|\(sopInstanceUID)"
    }

    private static func reportStatus(for references: [DicomStorageCommitmentReference]) -> DicomStorageCommitmentReportStatus {
        let failedCount = references.filter { $0.status == .failed }.count
        if failedCount == 0 { return .committed }
        if failedCount == references.count { return .failed }
        return .partial
    }

    private static func referenceItem(_ reference: DicomStorageCommitmentReference) -> DicomSequenceItem {
        DicomSequenceItem(dataSet: DicomDataSet(elements: [
            string(DicomTag.referencedSOPClassUID.rawValue, vr: .UI, reference.sopClassUID),
            string(DicomTag.referencedSOPInstanceUID.rawValue, vr: .UI, reference.sopInstanceUID)
        ]))
    }

    private static func reference(from dataSet: DicomDataSet,
                                  status: DicomStorageCommitmentReferenceStatus) -> DicomStorageCommitmentReference? {
        guard let sopClassUID = dataSet.string(for: .referencedSOPClassUID),
              let sopInstanceUID = dataSet.string(for: .referencedSOPInstanceUID) else {
            return nil
        }
        return DicomStorageCommitmentReference(sopClassUID: sopClassUID,
                                               sopInstanceUID: sopInstanceUID,
                                               status: status)
    }
}

public enum DicomStorageSCPProgress: Equatable, Sendable {
    case associationAccepted(callingAETitle: String)
    case instanceReceived(sopClassUID: String, sopInstanceUID: String)
    case instanceStored(DicomStoredInstance)
    case storeFailed(sopInstanceUID: String?, errorDescription: String)
    case storageCommitmentReported(DicomStorageCommitmentReport)
    case released
}

public struct DicomStorageSCPAssociationResult: Equatable, Sendable {
    public var storedInstances: [DicomStoredInstance]
    public var commitmentReports: [DicomStorageCommitmentReport]

    public init(storedInstances: [DicomStoredInstance],
                commitmentReports: [DicomStorageCommitmentReport]) {
        self.storedInstances = storedInstances
        self.commitmentReports = commitmentReports
    }
}

public final class DicomStorageSCPService {
    public let configuration: DicomStorageSCPConfiguration
    public let storage: DicomStorageInstanceStoring
    public let commitmentTracker: DicomStorageCommitmentTracker

    public init(configuration: DicomStorageSCPConfiguration,
                storage: DicomStorageInstanceStoring,
                commitmentTracker: DicomStorageCommitmentTracker = DicomStorageCommitmentTracker()) {
        self.configuration = configuration
        self.storage = storage
        self.commitmentTracker = commitmentTracker
    }

    public func handleAssociation(using transport: DicomAssociationTransport,
                                  progress: (@Sendable (DicomStorageSCPProgress) -> Void)? = nil) throws -> DicomStorageSCPAssociationResult {
        let requestPDU = try DicomPDUCodec.decode(try transport.readPDU())
        guard case .associationRequest(let request) = requestPDU else {
            throw DicomStorageSCPError.associationRequestExpected
        }
        try validateCalledAETitle(request.calledAETitle, transport: transport)

        let accept = DicomAssociationNegotiator.accept(
            request,
            supportedAbstractSyntaxUIDs: supportedAbstractSyntaxUIDs,
            preferredTransferSyntaxes: configuration.transferSyntaxes
        )
        try transport.writePDU(DicomPDUCodec.encode(.associationAccept(accept)))
        let association = DicomAssociation(request: request, accept: accept)
        progress?(.associationAccepted(callingAETitle: request.callingAETitle))

        let reader = DicomDIMSEMessageReader()
        var storedInstances: [DicomStoredInstance] = []
        var commitmentReports: [DicomStorageCommitmentReport] = []

        while true {
            switch try reader.readNext(from: transport) {
            case .releaseRequest:
                try transport.writePDU(DicomPDUCodec.encode(.releaseResponse))
                progress?(.released)
                return DicomStorageSCPAssociationResult(storedInstances: storedInstances,
                                                        commitmentReports: commitmentReports)
            case .message(let message):
                guard message.isCommand else {
                    throw DicomNetworkError.malformedCommandSet("Expected DIMSE command PDV.")
                }
                let command = try DicomDIMSECommandSet.decode(message.data)
                switch command.commandField {
                case DicomDIMSECommandField.cStoreRQ:
                    if let stored = try handleStore(command: command,
                                                    commandContextID: message.presentationContextID,
                                                    association: association,
                                                    transport: transport,
                                                    reader: reader,
                                                    progress: progress) {
                        storedInstances.append(stored)
                    }
                case DicomDIMSECommandField.nActionRQ:
                    let report = try handleStorageCommitment(command: command,
                                                             commandContextID: message.presentationContextID,
                                                             association: association,
                                                             transport: transport,
                                                             reader: reader)
                    commitmentReports.append(report)
                    progress?(.storageCommitmentReported(report))
                default:
                    throw DicomNetworkError.unexpectedDIMSECommand(expected: DicomDIMSECommandField.cStoreRQ,
                                                                   actual: command.commandField)
                }
            }
        }
    }

    private var supportedAbstractSyntaxUIDs: Set<String> {
        var supported = configuration.supportedStorageSOPClassUIDs
        if configuration.enableStorageCommitment {
            supported.insert(DicomNetworkUID.storageCommitmentPushModelSOPClass)
        }
        return supported
    }

    private func validateCalledAETitle(_ calledAETitle: String,
                                       transport: DicomAssociationTransport) throws {
        guard configuration.acceptAnyCalledAETitle ||
                calledAETitle.trimmingCharacters(in: .whitespacesAndNewlines) == configuration.aeTitle else {
            let reject = DicomAssociationReject(result: .rejectedPermanent,
                                                source: .serviceUser,
                                                reason: .calledAENotRecognized)
            try transport.writePDU(DicomPDUCodec.encode(.associationReject(reject)))
            throw DicomStorageSCPError.calledAETitleNotRecognized(calledAETitle)
        }
    }

    private func handleStore(command: DicomDIMSECommandSet,
                             commandContextID: UInt8,
                             association: DicomAssociation,
                             transport: DicomAssociationTransport,
                             reader: DicomDIMSEMessageReader,
                             progress: (@Sendable (DicomStorageSCPProgress) -> Void)?) throws -> DicomStoredInstance? {
        let payload = try reader.readMessage(from: transport)
        guard !payload.isCommand else {
            throw DicomStorageSCPError.missingCommandDataSet(command.commandField)
        }
        let context = try acceptedContext(id: payload.presentationContextID, association: association)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        let dataSet = try DicomDataSetParser.dataSet(from: payload.data, transferSyntax: transferSyntax)
        let sopClassUID = command.affectedSOPClassUID ??
            dataSet.string(for: .sopClassUID) ??
            DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        let sopInstanceUID = command.affectedSOPInstanceUID ??
            dataSet.string(for: .sopInstanceUID) ??
            DicomDataSetWriter.makeUID()
        progress?(.instanceReceived(sopClassUID: sopClassUID, sopInstanceUID: sopInstanceUID))

        let received = DicomStorageReceivedInstance(sopClassUID: sopClassUID,
                                                    sopInstanceUID: sopInstanceUID,
                                                    transferSyntax: transferSyntax,
                                                    dataSet: dataSet,
                                                    rawDataSetData: payload.data)
        let stored: DicomStoredInstance
        do {
            stored = try storage.store(received)
        } catch {
            try sendStoreResponse(command: command,
                                  status: 0xC000,
                                  errorComment: error.localizedDescription,
                                  presentationContextID: commandContextID,
                                  association: association,
                                  transport: transport)
            progress?(.storeFailed(sopInstanceUID: sopInstanceUID,
                                   errorDescription: error.localizedDescription))
            return nil
        }
        commitmentTracker.recordStoredInstance(stored)
        try sendStoreResponse(command: command,
                              status: 0,
                              errorComment: nil,
                              presentationContextID: commandContextID,
                              association: association,
                              transport: transport)
        progress?(.instanceStored(stored))
        return stored
    }

    private func handleStorageCommitment(command: DicomDIMSECommandSet,
                                         commandContextID: UInt8,
                                         association: DicomAssociation,
                                         transport: DicomAssociationTransport,
                                         reader: DicomDIMSEMessageReader) throws -> DicomStorageCommitmentReport {
        let payload = try reader.readMessage(from: transport)
        guard !payload.isCommand else {
            throw DicomStorageSCPError.missingCommandDataSet(command.commandField)
        }
        let context = try acceptedContext(id: payload.presentationContextID, association: association)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        let dataSet = try DicomDataSetParser.dataSet(from: payload.data, transferSyntax: transferSyntax)
        let (transactionUID, references) = try DicomStorageCommitmentTracker.parseActionDataSet(dataSet)
        let report = commitmentTracker.evaluate(transactionUID: transactionUID, references: references)
        let response = DicomDIMSECommandSet(
            affectedSOPClassUID: DicomNetworkUID.storageCommitmentPushModelSOPClass,
            commandField: DicomDIMSECommandField.nActionRSP,
            messageIDBeingRespondedTo: command.messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
            status: 0,
            affectedSOPInstanceUID: DicomNetworkUID.storageCommitmentPushModelSOPInstance,
            actionTypeID: command.actionTypeID
        )
        try sendCommand(response,
                        presentationContextID: commandContextID,
                        association: association,
                        transport: transport)
        return report
    }

    private func sendStoreResponse(command: DicomDIMSECommandSet,
                                   status: UInt16,
                                   errorComment: String?,
                                   presentationContextID: UInt8,
                                   association: DicomAssociation,
                                   transport: DicomAssociationTransport) throws {
        let response = DicomDIMSECommandSet(
            affectedSOPClassUID: command.affectedSOPClassUID,
            commandField: DicomDIMSECommandField.cStoreRSP,
            messageIDBeingRespondedTo: command.messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
            status: status,
            errorComment: errorComment,
            affectedSOPInstanceUID: command.affectedSOPInstanceUID
        )
        try sendCommand(response,
                        presentationContextID: presentationContextID,
                        association: association,
                        transport: transport)
    }

    private func sendCommand(_ command: DicomDIMSECommandSet,
                             presentationContextID: UInt8,
                             association: DicomAssociation,
                             transport: DicomAssociationTransport) throws {
        try transport.writePDU(DicomPDUCodec.encode(association.commandPData(command,
                                                                             presentationContextID: presentationContextID)))
    }

    private func acceptedContext(id: UInt8, association: DicomAssociation) throws -> DicomAcceptedPresentationContext {
        guard let context = association.acceptedPresentationContexts.first(where: { $0.id == id }) else {
            throw DicomStorageSCPError.missingPresentationContext(id)
        }
        return context
    }
}

public enum DicomStoreAndForwardState: String, Codable, Equatable, Sendable {
    case pending
    case delivered
    case failed
}

public struct DicomStoreAndForwardEntry: Codable, Equatable, Sendable {
    public var id: String
    public var sopClassUID: String
    public var sopInstanceUID: String
    public var fileName: String
    public var attempts: Int
    public var maxAttempts: Int
    public var state: DicomStoreAndForwardState
    public var lastError: String?
    public var createdAt: Date
    public var updatedAt: Date
}

public struct DicomStoreAndForwardResult: Equatable, Sendable {
    public var entry: DicomStoreAndForwardEntry
    public var success: Bool
    public var errorDescription: String?
}

public final class DicomStoreAndForwardQueue {
    public let directoryURL: URL
    private let manifestURL: URL
    private var entries: [DicomStoreAndForwardEntry]
    private let lock = NSLock()

    public init(directoryURL: URL) throws {
        self.directoryURL = directoryURL
        self.manifestURL = directoryURL.appendingPathComponent("store-and-forward.json")
        try FileManager.default.createDirectory(at: directoryURL,
                                                withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: manifestURL) {
            entries = try JSONDecoder().decode([DicomStoreAndForwardEntry].self, from: data)
        } else {
            entries = []
        }
    }

    public func enqueue(dataSet: DicomDataSet,
                        sopClassUID: String? = nil,
                        sopInstanceUID: String? = nil,
                        transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian,
                        maxAttempts: Int = 3) throws -> DicomStoreAndForwardEntry {
        let resolvedClassUID = sopClassUID ??
            dataSet.string(for: .sopClassUID) ??
            DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        let resolvedInstanceUID = sopInstanceUID ??
            dataSet.string(for: .sopInstanceUID) ??
            DicomDataSetWriter.makeUID()
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(transferSyntax: transferSyntax,
                                              mediaStorageSOPClassUID: resolvedClassUID,
                                              mediaStorageSOPInstanceUID: resolvedInstanceUID)
        )
        return try enqueue(part10Data: data,
                           sopClassUID: resolvedClassUID,
                           sopInstanceUID: resolvedInstanceUID,
                           maxAttempts: maxAttempts)
    }

    public func enqueue(part10Data: Data,
                        sopClassUID: String,
                        sopInstanceUID: String,
                        maxAttempts: Int = 3) throws -> DicomStoreAndForwardEntry {
        let id = UUID().uuidString
        let fileName = "\(id).dcm"
        try part10Data.write(to: directoryURL.appendingPathComponent(fileName), options: [.atomic])
        var entry = DicomStoreAndForwardEntry(id: id,
                                              sopClassUID: sopClassUID,
                                              sopInstanceUID: sopInstanceUID,
                                              fileName: fileName,
                                              attempts: 0,
                                              maxAttempts: max(1, maxAttempts),
                                              state: .pending,
                                              lastError: nil,
                                              createdAt: Date(),
                                              updatedAt: Date())
        try lockedUpdate {
            entries.append(entry)
            try persistLocked()
            entry = entries.first { $0.id == id } ?? entry
        }
        return entry
    }

    public func allEntries() -> [DicomStoreAndForwardEntry] {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return snapshot
    }

    public func pendingEntries() -> [DicomStoreAndForwardEntry] {
        allEntries().filter { $0.state == .pending && $0.attempts < $0.maxAttempts }
    }

    public func failedEntries() -> [DicomStoreAndForwardEntry] {
        allEntries().filter { $0.state == .failed }
    }

    public func fileURL(for entry: DicomStoreAndForwardEntry) -> URL {
        directoryURL.appendingPathComponent(entry.fileName)
    }

    public func processAll(send: (DicomStoreAndForwardEntry, Data) throws -> Void) -> [DicomStoreAndForwardResult] {
        pendingEntries().map { entry in
            process(entry: entry, send: send)
        }
    }

    public func resetFailedEntry(id: String) throws {
        try lockedUpdate {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].state = .pending
            entries[index].attempts = 0
            entries[index].lastError = nil
            entries[index].updatedAt = Date()
            try persistLocked()
        }
    }

    @discardableResult
    private func process(entry: DicomStoreAndForwardEntry,
                         send: (DicomStoreAndForwardEntry, Data) throws -> Void) -> DicomStoreAndForwardResult {
        do {
            let data = try Data(contentsOf: fileURL(for: entry))
            try send(entry, data)
            let updated = updateEntry(id: entry.id) { current in
                current.state = .delivered
                current.lastError = nil
                current.updatedAt = Date()
            }
            return DicomStoreAndForwardResult(entry: updated ?? entry,
                                              success: true,
                                              errorDescription: nil)
        } catch {
            let updated = updateEntry(id: entry.id) { current in
                current.attempts += 1
                current.lastError = error.localizedDescription
                current.updatedAt = Date()
                if current.attempts >= current.maxAttempts {
                    current.state = .failed
                }
            }
            return DicomStoreAndForwardResult(entry: updated ?? entry,
                                              success: false,
                                              errorDescription: error.localizedDescription)
        }
    }

    private func updateEntry(id: String,
                             mutate: (inout DicomStoreAndForwardEntry) -> Void) -> DicomStoreAndForwardEntry? {
        var updated: DicomStoreAndForwardEntry?
        try? lockedUpdate {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            mutate(&entries[index])
            updated = entries[index]
            try persistLocked()
        }
        return updated
    }

    private func lockedUpdate(_ update: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try update()
    }

    private func persistLocked() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: manifestURL, options: [.atomic])
    }
}

#if canImport(Network)
public final class DicomStorageSCPServer {
    public let service: DicomStorageSCPService
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DicomStorageSCPServer")
    private let tlsContext: DicomAppliedTLSContext?

    public init(service: DicomStorageSCPService) throws {
        self.service = service
        guard let port = NWEndpoint.Port(rawValue: service.configuration.port) else {
            throw DicomNetworkError.networkUnavailable("Invalid Storage SCP port \(service.configuration.port).")
        }
        let prepared = try DicomTLSOptionsFactory.preparedParameters(for: service.configuration.tls, role: .server)
        self.tlsContext = prepared.tlsContext
        self.listener = try NWListener(using: prepared.parameters, on: port)
    }

    public func start(progress: (@Sendable (DicomStorageSCPProgress) -> Void)? = nil) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var startupError: Error?
        listener.newConnectionHandler = { [service] connection in
            let transport = DicomTCPAssociationTransport(acceptedConnection: connection,
                                                         timeout: service.configuration.timeout,
                                                         maximumIncomingPDUSize: service.configuration.maximumPDULength)
            transport.startAcceptedConnection()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = try? service.handleAssociation(using: transport, progress: progress)
                transport.close()
            }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                semaphore.signal()
            case .failed(let error):
                startupError = error
                semaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        guard semaphore.wait(timeout: .now() + service.configuration.timeout) == .success else {
            throw DicomNetworkError.networkTimeout("starting Storage SCP listener")
        }
        if let startupError {
            throw startupError
        }
    }

    public func stop() {
        listener.cancel()
    }
}
#endif

private enum StorageCommitmentTags {
    static let transactionUID = 0x0008_1195
    static let failedSOPSequence = 0x0008_1198
    static let referencedSOPSequence = DicomTag.referencedSOPSequence.rawValue
}

private func string(_ tag: Int, vr: DicomVR, _ value: String) -> DicomDataElement {
    DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
}

private func sequence(_ tag: Int, _ items: [DicomSequenceItem]) -> DicomDataElement {
    DicomDataElement(tag: tag, vr: .SQ, value: .sequence(items))
}
