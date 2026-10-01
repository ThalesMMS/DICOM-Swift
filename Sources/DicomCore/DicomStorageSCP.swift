import Foundation
#if canImport(Network)
import Network
#endif

public enum DicomStorageSCPError: Error, Equatable, Sendable {
    case associationRequestExpected
    case calledAETitleNotRecognized(String)
    case callingAETitleNotRecognized(String)
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
        case .callingAETitleNotRecognized(let value):
            return "Calling AE title \(value) is not allowed by this Storage SCP."
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

    public static let commonClinicalStorage: Set<String> = Set([
        computedRadiographyImageStorage,
        ctImageStorage,
        enhancedCTImageStorage,
        mrImageStorage,
        enhancedMRImageStorage,
        ultrasoundImageStorage,
        secondaryCaptureImageStorage,
        positronEmissionTomographyImageStorage,
        DicomSegmentationBuilder.segmentationStorageSOPClassUID,
        DicomSegmentationBuilder.labelMapSegmentationStorageSOPClassUID,
        DicomSurfaceSegmentation.storageSOPClassUID,
        DicomRTStructureSet.storageSOPClassUID,
        DicomRTDoseVolume.storageSOPClassUID,
        DicomRTPlan.storageSOPClassUID,
        DicomSpatialRegistrationDocument.storageSOPClassUID,
        DicomParametricMap.storageSOPClassUID,
        DicomSecondaryCaptureImage.storageSOPClassUID
    ])
    .union(DicomGrayscalePresentationState.supportedStorageSOPClassUIDs)
    .union(DicomSRDocument.structuredReportSOPClassUIDs)
    .union(DicomWaveform.supportedStorageSOPClassUIDs)

    /// Whether objects of `abstractSyntaxUID` may carry encapsulated Pixel Data: the Storage SOP Classes under
    /// `1.2.840.10008.5.1.4.1.1` and private SOP Classes. Query, retrieve, verification, print and workflow contexts
    /// carry commands and identifiers only.
    public static func mayCarryEncapsulatedPixelData(_ abstractSyntaxUID: String) -> Bool {
        abstractSyntaxUID.hasPrefix("1.2.840.10008.5.1.4.1.1.") || !abstractSyntaxUID.hasPrefix("1.2.840.10008.")
    }

    /// The syntaxes a context for `abstractSyntaxUID` may use: all of `syntaxes`, or, when its objects carry no
    /// encapsulated Pixel Data, the native ones among them (Explicit and Implicit VR Little Endian when none is).
    public static func transferSyntaxes(_ syntaxes: [DicomTransferSyntax],
                                        forAbstractSyntax abstractSyntaxUID: String) -> [DicomTransferSyntax] {
        guard !mayCarryEncapsulatedPixelData(abstractSyntaxUID) else { return syntaxes }
        let native = syntaxes.filter { !$0.registryEntry.isEncapsulated }
        return native.isEmpty ? [.explicitVRLittleEndian, .implicitVRLittleEndian] : native
    }
}

public struct DicomStorageSCPConfiguration: Equatable, Sendable {
    public var aeTitle: String
    public var port: UInt16
    public var supportedStorageSOPClassUIDs: Set<String>
    public var transferSyntaxes: [DicomTransferSyntax]
    public var maximumPDULength: UInt32
    public var timeout: TimeInterval
    public var acceptAnyCalledAETitle: Bool
    public var acceptOnlyIntranet: Bool
    public var allowedCallingAETitles: Set<String>
    public var enableStorageCommitment: Bool
    public var tls: DicomTLSConfiguration
    public var maximumConcurrentAssociations: Int
    public var maximumInFlightStoreRequests: Int
    public var maximumStagedBytes: Int64
    public var maximumObjectsPerAssociation: Int
    public var maximumBytesPerAssociation: Int64
    public var maximumConnectionsPerPeer: Int
    public var dataSetParseLimits: DicomDataSetParseLimits

    public init(aeTitle: String,
                port: UInt16 = 11112,
                supportedStorageSOPClassUIDs: Set<String> = DicomStorageSOPClassUIDs.commonClinicalStorage,
                transferSyntaxes: [DicomTransferSyntax] = [.explicitVRLittleEndian, .implicitVRLittleEndian],
                maximumPDULength: UInt32 = 16_384,
                timeout: TimeInterval = 10,
                acceptAnyCalledAETitle: Bool = false,
                acceptOnlyIntranet: Bool = false,
                allowedCallingAETitles: Set<String> = [],
                enableStorageCommitment: Bool = true,
                tls: DicomTLSConfiguration = .disabled,
                maximumConcurrentAssociations: Int = 4,
                maximumInFlightStoreRequests: Int = 4,
                maximumStagedBytes: Int64 = 512 * 1_024 * 1_024,
                maximumObjectsPerAssociation: Int = 1_000,
                maximumBytesPerAssociation: Int64 = 2 * 1_024 * 1_024 * 1_024,
                maximumConnectionsPerPeer: Int = 2,
                dataSetParseLimits: DicomDataSetParseLimits = .default) {
        self.aeTitle = aeTitle
        self.port = port
        self.supportedStorageSOPClassUIDs = supportedStorageSOPClassUIDs
        self.transferSyntaxes = transferSyntaxes
        self.maximumPDULength = maximumPDULength
        self.timeout = timeout
        self.acceptAnyCalledAETitle = acceptAnyCalledAETitle
        self.acceptOnlyIntranet = acceptOnlyIntranet
        self.allowedCallingAETitles = allowedCallingAETitles
        self.enableStorageCommitment = enableStorageCommitment
        self.tls = tls
        self.maximumConcurrentAssociations = max(1, maximumConcurrentAssociations)
        self.maximumInFlightStoreRequests = max(1, maximumInFlightStoreRequests)
        self.maximumStagedBytes = max(1, maximumStagedBytes)
        self.maximumObjectsPerAssociation = max(1, maximumObjectsPerAssociation)
        self.maximumBytesPerAssociation = max(1, maximumBytesPerAssociation)
        self.maximumConnectionsPerPeer = max(1, maximumConnectionsPerPeer)
        self.dataSetParseLimits = dataSetParseLimits
    }
}

enum DicomStorageSCPPeerAccess {
    #if canImport(Network)
    static func allows(_ endpoint: NWEndpoint, acceptOnlyIntranet: Bool) -> Bool {
        guard acceptOnlyIntranet else { return true }
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            guard address.interface == nil else { return false }
            return isIntranetIPv4([UInt8](address.rawValue))
        case .ipv6(let address):
            guard address.interface == nil else { return false }
            return isIntranetIPv6([UInt8](address.rawValue))
        case .name:
            return false
        @unknown default:
            return false
        }
    }
    #endif

    static func isIntranetAddress(_ address: String) -> Bool {
        let components = address.split(separator: ".", omittingEmptySubsequences: false)
        if components.count == 4, !address.contains(":") {
            let octets = components.compactMap { component -> UInt8? in
                guard !component.isEmpty,
                      component.allSatisfy({ $0.isASCII && $0.isNumber }),
                      component.count == 1 || component.first != "0" else {
                    return nil
                }
                return UInt8(component)
            }
            return octets.count == 4 && isIntranetIPv4(octets)
        }

        #if canImport(Network)
        guard !address.contains("%") else { return false }
        guard let ipv6 = IPv6Address(address) else { return false }
        return isIntranetIPv6([UInt8](ipv6.rawValue))
        #else
        return false
        #endif
    }

    private static func isIntranetIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 {
            return true
        }
        if bytes[0] & 0xFE == 0xFC {
            return true
        }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return isIntranetIPv4(Array(bytes.suffix(4)))
        }
        return false
    }

    private static func isIntranetIPv4(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (172, 16...31), (192, 168):
            return true
        default:
            return false
        }
    }
}

public struct DicomStorageReceivedInstance: Equatable, Sendable {
    public var sopClassUID: String
    public var sopInstanceUID: String
    public var transferSyntax: DicomTransferSyntax
    /// Metadata-only parsed dataset. Pixel Data remains available in `rawDataSetData`.
    public var dataSet: DicomDataSet {
        didSet { rawDataSetData = nil; part10FileURL = nil }
    }
    public var rawDataSetData: Data?
    /// The object as received, already written as a Part 10 file (preamble, File Meta, then the dataset bytes as
    /// they arrived), when the receiver wrote it to disk instead of holding it (issue #2793); `rawDataSetData` is
    /// then a mapped view of that file. A store may move the file; the receiver removes what is left of it.
    public var part10FileURL: URL?
    public var receivedAt: Date
    /// The C-MOVE this object answers, from Move Originator AE Title and Message ID (0000,1030/1031), when it
    /// arrived as a C-MOVE sub-operation (issue #2817).
    public var moveOriginatorAETitle: String?
    public var moveOriginatorMessageID: UInt16?

    public init(sopClassUID: String,
                sopInstanceUID: String,
                transferSyntax: DicomTransferSyntax,
                dataSet: DicomDataSet,
                rawDataSetData: Data? = nil,
                part10FileURL: URL? = nil,
                receivedAt: Date = Date()) {
        self.sopClassUID = sopClassUID
        self.sopInstanceUID = sopInstanceUID
        self.transferSyntax = transferSyntax
        self.dataSet = dataSet
        self.rawDataSetData = rawDataSetData
        self.part10FileURL = part10FileURL
        self.receivedAt = receivedAt
    }
}

public struct DicomStoredInstance: Equatable, Sendable {
    public var sopClassUID: String
    public var sopInstanceUID: String
    public var transferSyntax: DicomTransferSyntax
    public var fileURL: URL
    public var storedAt: Date
    public var isConflict: Bool

    public init(sopClassUID: String,
                sopInstanceUID: String,
                transferSyntax: DicomTransferSyntax,
                fileURL: URL,
                storedAt: Date = Date(),
                isConflict: Bool = false) {
        self.sopClassUID = sopClassUID
        self.sopInstanceUID = sopInstanceUID
        self.transferSyntax = transferSyntax
        self.fileURL = fileURL
        self.storedAt = storedAt
        self.isConflict = isConflict
    }
}

/// Implementations may be invoked concurrently by independent associations.
public protocol DicomStorageInstanceStoring: AnyObject, Sendable {
    func store(_ instance: DicomStorageReceivedInstance) throws -> DicomStoredInstance
    /// Where the receiver writes each incoming object as a Part 10 file, handed over in `part10FileURL`, instead of
    /// holding it in memory (issue #2793); nil keeps objects in memory.
    var receivedFileDirectory: URL? { get }
}

public extension DicomStorageInstanceStoring {
    var receivedFileDirectory: URL? { nil }
}

public final class DicomFileStorageCache: DicomStorageInstanceStoring {
    public let directoryURL: URL

    public let ingest: DicomIngestCoordinator

    public init(directoryURL: URL) throws {
        self.directoryURL = directoryURL
        let fs = DicomLocalIngestFileSystem()
        try fs.createDirectory(directoryURL)
        let journal = try DicomJSONLIngestJournal(path: directoryURL.appendingPathComponent(".ingest/journal.jsonl"))
        let registrar = try DicomJSONLIngestRegistrar(path: directoryURL.appendingPathComponent(".ingest/registry.jsonl"))
        ingest = DicomIngestCoordinator(root: directoryURL, journal: journal, registrar: registrar,
                                        capacity: DicomFileStoragePreflight(directoryURL: directoryURL, reserveBytes: 0))
    }

    public func store(_ instance: DicomStorageReceivedInstance) throws -> DicomStoredInstance {
        let result = try DicomIngestBlockingResult.run { [ingest] in try await ingest.ingest(instance) }
        return DicomStoredInstance(sopClassUID: instance.sopClassUID, sopInstanceUID: instance.sopInstanceUID,
                                   transferSyntax: instance.transferSyntax, fileURL: result.record.path,
                                   isConflict: result.record.isConflict)
    }

    public var receivedFileDirectory: URL? { ingest.receivedFileDirectory }

    public func recoverPendingIngests() async throws -> DicomIngestRecoveryReport {
        try await DicomIngestRecovery.replay(journal: ingest.journal, fileSystem: ingest.fileSystem, registrar: ingest.registrar)
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
    public var failureReasonCode: UInt16?

    public init(sopClassUID: String,
                sopInstanceUID: String,
                status: DicomStorageCommitmentReferenceStatus = .committed,
                failureReason: String? = nil,
                failureReasonCode: UInt16? = nil) {
        self.sopClassUID = sopClassUID
        self.sopInstanceUID = sopInstanceUID
        self.status = status
        self.failureReason = failureReason
        self.failureReasonCode = failureReasonCode
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

/// Mutable tracking state is serialized by `lock`.
public final class DicomStorageCommitmentTracker: @unchecked Sendable {
    private static let referencedSOPNotStoredReason = "Referenced SOP instance is not stored."
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
                                                       failureReason: Self.referencedSOPNotStoredReason,
                                                       failureReasonCode: 0x0112)
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
        let identities = references.map { "\($0.sopClassUID)|\($0.sopInstanceUID)" }
        guard !references.isEmpty, Set(identities).count == identities.count else {
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
        var elements = [
            string(DicomTag.referencedSOPClassUID.rawValue, vr: .UI, reference.sopClassUID),
            string(DicomTag.referencedSOPInstanceUID.rawValue, vr: .UI, reference.sopInstanceUID)
        ]
        let failureReasonCode = reference.failureReasonCode ?? (reference.status == .failed ? 0x0110 : nil)
        if let failureReasonCode {
            elements.append(
                DicomDataElement(
                    tag: StorageCommitmentTags.failureReason,
                    vr: .US,
                    value: .unsignedIntegers([UInt(failureReasonCode)])
                )
            )
        }
        return DicomSequenceItem(dataSet: DicomDataSet(elements: elements))
    }

    private static func reference(from dataSet: DicomDataSet,
                                  status: DicomStorageCommitmentReferenceStatus) -> DicomStorageCommitmentReference? {
        guard let sopClassUID = dataSet.string(for: .referencedSOPClassUID),
              let sopInstanceUID = dataSet.string(for: .referencedSOPInstanceUID) else {
            return nil
        }
        let failureReasonCode = dataSet
            .element(for: StorageCommitmentTags.failureReason)?
            .intValue
            .flatMap(UInt16.init(exactly:))
        return DicomStorageCommitmentReference(sopClassUID: sopClassUID,
                                               sopInstanceUID: sopInstanceUID,
                                               status: status,
                                               failureReason: failureReasonCode == 0x0112
                                                   ? referencedSOPNotStoredReason
                                                   : nil,
                                               failureReasonCode: failureReasonCode)
    }
}

public struct DicomStorageCommitmentPersistence: Sendable {
    public typealias StoredInstanceRecorder = @Sendable (DicomStoredInstance) throws -> Void
    public typealias ReportPreparer = @Sendable (
        _ transactionUID: String,
        _ requestingAETitle: String,
        _ respondingAETitle: String,
        _ references: [DicomStorageCommitmentReference]
    ) throws -> DicomStorageCommitmentReport

    public let recordStoredInstance: StoredInstanceRecorder
    public let prepareReport: ReportPreparer

    public init(
        recordStoredInstance: @escaping StoredInstanceRecorder,
        prepareReport: @escaping ReportPreparer
    ) {
        self.recordStoredInstance = recordStoredInstance
        self.prepareReport = prepareReport
    }
}

public enum DicomStorageSCPProgress: Equatable, Sendable {
    case associationAccepted(callingAETitle: String)
    case instanceReceived(sopClassUID: String, sopInstanceUID: String)
    case instanceStored(DicomStoredInstance)
    case storeFailed(sopInstanceUID: String?, errorDescription: String)
    case storageCommitmentPending(
        report: DicomStorageCommitmentReport,
        requestingAETitle: String,
        respondingAETitle: String
    )
    case released
    case pressure(DicomStorageSCPPressureReason)
    case metrics(DicomStorageSCPMetrics)
    case listenerFault(DicomStorageSCPListenerFault)
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

public final class DicomStorageSCPService: Sendable {
    public let configuration: DicomStorageSCPConfiguration
    public let storage: DicomStorageInstanceStoring
    public let ingest: DicomIngestCoordinator?
    public let durabilityPolicy: DicomDurabilityPolicy
    public let commitmentTracker: DicomStorageCommitmentTracker
    private let storagePreflight: any DicomStoragePreflightChecking
    private let commitmentPersistence: DicomStorageCommitmentPersistence?
    private let commitmentResultHandler: (@Sendable (DicomStorageCommitmentReport) throws -> Void)?
    private let userIdentityAuthenticator: (any DicomUserIdentityAuthenticating)?
    let resourceGovernor: DicomStorageSCPResourceGovernor

    public init(configuration: DicomStorageSCPConfiguration,
                storage: DicomStorageInstanceStoring,
                ingest: DicomIngestCoordinator? = nil,
                durabilityPolicy: DicomDurabilityPolicy = .init(),
                commitmentTracker: DicomStorageCommitmentTracker = DicomStorageCommitmentTracker(),
                commitmentPersistence: DicomStorageCommitmentPersistence? = nil,
                storagePreflight: any DicomStoragePreflightChecking = NoopDicomStoragePreflight(),
                resourceGovernor: DicomStorageSCPResourceGovernor? = nil,
                userIdentityAuthenticator: (any DicomUserIdentityAuthenticating)? = nil,
                commitmentResultHandler: (@Sendable (DicomStorageCommitmentReport) throws -> Void)? = nil) {
        self.commitmentResultHandler = commitmentResultHandler
        self.userIdentityAuthenticator = userIdentityAuthenticator
        self.configuration = configuration
        self.storage = storage
        self.ingest = ingest
        self.durabilityPolicy = durabilityPolicy
        self.commitmentTracker = commitmentTracker
        self.commitmentPersistence = commitmentPersistence
        self.storagePreflight = storagePreflight
        self.resourceGovernor = resourceGovernor ?? DicomStorageSCPResourceGovernor(configuration: configuration)
    }

    func withIngest(_ ingest: DicomIngestCoordinator, policy: DicomDurabilityPolicy,
                    resourceGovernor: DicomStorageSCPResourceGovernor? = nil) -> DicomStorageSCPService {
        DicomStorageSCPService(configuration: configuration, storage: storage, ingest: ingest, durabilityPolicy: policy,
            commitmentTracker: commitmentTracker, commitmentPersistence: commitmentPersistence,
            storagePreflight: storagePreflight, resourceGovernor: resourceGovernor ?? self.resourceGovernor,
            userIdentityAuthenticator: userIdentityAuthenticator, commitmentResultHandler: commitmentResultHandler)
    }

    public func handleAssociation(using transport: DicomAssociationTransport,
                                  progress: (@Sendable (DicomStorageSCPProgress) -> Void)? = nil) throws -> DicomStorageSCPAssociationResult {
        let requestPDU = try DicomPDUCodec.decode(try transport.readPDU())
        guard case .associationRequest(let request) = requestPDU else {
            throw DicomStorageSCPError.associationRequestExpected
        }
        try validateCalledAETitle(request.calledAETitle, transport: transport)
        try validateCallingAETitle(request.callingAETitle, transport: transport)

        var accept = DicomAssociationNegotiator.accept(
            request,
            supportedAbstractSyntaxUIDs: supportedAbstractSyntaxUIDs,
            preferredTransferSyntaxes: configuration.transferSyntaxes,
            maximumPDULength: configuration.maximumPDULength,
            supportedSCUAbstractSyntaxUIDs: commitmentResultHandler == nil ? []
                : [DicomNetworkUID.storageCommitmentPushModelSOPClass]
        )
        if let authenticator = userIdentityAuthenticator {
            do {
                guard let identity = request.userIdentity else { throw CocoaError(.fileReadNoPermission) }
                let response = try authenticator.authenticate(identity)
                if identity.positiveResponseRequested {
                    accept.userIdentityServerResponse = response ?? DicomUserIdentityServerResponse(data: Data())
                }
            } catch {
                let rejection = DicomAssociationReject(result: .rejectedPermanent,
                                                       source: .serviceUser, reason: .noReason)
                try transport.writePDU(DicomPDUCodec.encode(.associationReject(rejection)))
                throw DicomNetworkError.associationRejected(rejection)
            }
        }
        let encodedAccept: Data
        do {
            encodedAccept = try DicomPDUCodec.encode(.associationAccept(accept))
        } catch {
            let rejection = DicomAssociationReject(result: .rejectedPermanent, source: .serviceUser, reason: .noReason)
            try transport.writePDU(DicomPDUCodec.encode(.associationReject(rejection)))
            throw DicomNetworkError.associationRejected(rejection)
        }
        try transport.writePDU(encodedAccept)
        let association = DicomAssociation(request: request, accept: accept)
        progress?(.associationAccepted(callingAETitle: request.callingAETitle))

        let reader = DicomDIMSEMessageReader()
        var storedInstances: [DicomStoredInstance] = []
        var commitmentReports: [DicomStorageCommitmentReport] = []
        var receivedObjectCount = 0
        var receivedByteCount: Int64 = 0

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
                case DicomDIMSECommandField.cEchoRQ:
                    try handleEcho(command: command,
                                   commandContextID: message.presentationContextID,
                                   association: association,
                                   transport: transport)
                case DicomDIMSECommandField.cStoreRQ:
                    if let stored = try handleStore(command: command,
                                                    commandContextID: message.presentationContextID,
                                                    association: association,
                                                    transport: transport,
                                                    reader: reader,
                                                    receivedObjectCount: &receivedObjectCount,
                                                    receivedByteCount: &receivedByteCount,
                                                    progress: progress) {
                        storedInstances.append(stored)
                    }
                case DicomDIMSECommandField.nEventReportRQ:
                    try handleCommitmentResult(command: command, contextID: message.presentationContextID,
                                               association: association, transport: transport, reader: reader)
                case DicomDIMSECommandField.nActionRQ:
                    if let report = try handleStorageCommitment(command: command,
                                                                requestingAETitle: request.callingAETitle,
                                                                respondingAETitle: request.calledAETitle,
                                                                commandContextID: message.presentationContextID,
                                                                association: association,
                                                                transport: transport,
                                                                reader: reader) {
                        commitmentReports.append(report)
                        progress?(.storageCommitmentPending(
                            report: report,
                            requestingAETitle: request.callingAETitle,
                            respondingAETitle: request.calledAETitle
                        ))
                    }
                default:
                    throw DicomNetworkError.unexpectedDIMSECommand(expected: DicomDIMSECommandField.cStoreRQ,
                                                                   actual: command.commandField)
                }
            }
        }
    }

    private var supportedAbstractSyntaxUIDs: Set<String> {
        var supported = configuration.supportedStorageSOPClassUIDs
        supported.insert(DicomNetworkUID.verificationSOPClass)
        if configuration.enableStorageCommitment || commitmentResultHandler != nil {
            supported.insert(DicomNetworkUID.storageCommitmentPushModelSOPClass)
        }
        return supported
    }

    private func handleEcho(command: DicomDIMSECommandSet,
                            commandContextID: UInt8,
                            association: DicomAssociation,
                            transport: DicomAssociationTransport) throws {
        _ = try acceptedContext(id: commandContextID, association: association)
        let response = DicomDIMSECommandSet(
            affectedSOPClassUID: DicomNetworkUID.verificationSOPClass,
            commandField: DicomDIMSECommandField.cEchoRSP,
            messageIDBeingRespondedTo: command.messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
            status: 0
        )
        try sendCommand(response,
                        presentationContextID: commandContextID,
                        association: association,
                        transport: transport)
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

    private func validateCallingAETitle(_ callingAETitle: String,
                                        transport: DicomAssociationTransport) throws {
        let normalized = callingAETitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuration.allowedCallingAETitles.isEmpty ||
                configuration.allowedCallingAETitles.contains(normalized) else {
            let reject = DicomAssociationReject(result: .rejectedPermanent,
                                                source: .serviceUser,
                                                reason: .callingAENotRecognized)
            try transport.writePDU(DicomPDUCodec.encode(.associationReject(reject)))
            throw DicomStorageSCPError.callingAETitleNotRecognized(callingAETitle)
        }
    }

    // The composable acceptor delegates to the unchanged storage admission/persistence path.
    func handleDelegatedStore(command: DicomDIMSECommandSet, contextID: UInt8,
                              association: DicomAssociation, transport: DicomAssociationTransport,
                              reader: DicomDIMSEMessageReader, receivedObjectCount: inout Int,
                              receivedByteCount: inout Int64,
                              progress: (@Sendable (DicomStorageSCPProgress) -> Void)? = nil,
                              authorize: (@Sendable (DicomDataSet) throws -> Void)? = nil) throws {
        _ = try handleStore(command: command, commandContextID: contextID, association: association,
            transport: transport, reader: reader, receivedObjectCount: &receivedObjectCount,
            receivedByteCount: &receivedByteCount, progress: progress, authorize: authorize)
    }

    private func handleStore(command: DicomDIMSECommandSet,
                             commandContextID: UInt8,
                             association: DicomAssociation,
                             transport: DicomAssociationTransport,
                             reader: DicomDIMSEMessageReader,
                             receivedObjectCount: inout Int,
                             receivedByteCount: inout Int64,
                             progress: (@Sendable (DicomStorageSCPProgress) -> Void)?,
                             authorize: (@Sendable (DicomDataSet) throws -> Void)? = nil) throws -> DicomStoredInstance? {
        guard receivedObjectCount < configuration.maximumObjectsPerAssociation else {
            try discardStorePayload(reader: reader, transport: transport)
            try refuseStore(command: command, reason: .associationObjectLimit,
                            error: DicomStorageSCPAdmissionError.refused(.associationObjectLimit),
                            presentationContextID: commandContextID, association: association,
                            transport: transport, progress: progress)
            return nil
        }
        guard receivedByteCount < configuration.maximumBytesPerAssociation else {
            try discardStorePayload(reader: reader, transport: transport)
            try refuseStore(command: command, reason: .associationByteLimit,
                            error: DicomStorageSCPAdmissionError.refused(.associationByteLimit),
                            presentationContextID: commandContextID, association: association,
                            transport: transport, progress: progress)
            return nil
        }
        guard resourceGovernor.beginStore() == nil else {
            try discardStorePayload(reader: reader, transport: transport)
            try refuseStore(command: command, reason: .storeRequestLimit,
                            error: DicomStorageSCPAdmissionError.refused(.storeRequestLimit),
                            presentationContextID: commandContextID, association: association,
                            transport: transport, progress: progress)
            return nil
        }
        var stagedBytes: Int64 = 0
        defer {
            resourceGovernor.releaseStagedBytes(stagedBytes)
            resourceGovernor.endStore()
            progress?(.metrics(resourceGovernor.snapshot()))
        }
        let remainingBytes = configuration.maximumBytesPerAssociation - receivedByteCount
        // Issue #2793: with a directory to receive into, the dataset goes to disk as it arrives and no memory is
        // staged for it; the object's budget is then the disk's.
        let receivedFile = receivedPart10File(command: command, contextID: commandContextID, association: association)
        defer { receivedFile?.remove() }
        let payload: DicomDIMSEMessage
        let payloadBytes: Int64
        do {
            if let receivedFile {
                var received: Int64 = 0
                payload = try reader.readMessage(from: transport, maximumDataLength: remainingBytes, sink: { fragment in
                    do {
                        try self.resourceGovernor.appendReceivedFragment(fragment, to: receivedFile,
                                                                         preflight: self.storagePreflight)
                    } catch {
                        throw DicomStorageSCPAdmissionError.insufficientStorage(requiredBytes: received + Int64(fragment.count))
                    }
                    received += Int64(fragment.count)
                })
                payloadBytes = received
            } else {
                payload = try reader.readMessage(
                    from: transport,
                    maximumDataLength: remainingBytes,
                    reserveData: resourceGovernor.reserveStagedBytes,
                    releaseData: resourceGovernor.releaseStagedBytes
                )
                stagedBytes = Int64(payload.data.count)
                payloadBytes = stagedBytes
            }
        } catch let error as DicomStorageSCPAdmissionError {
            let reason: DicomStorageSCPPressureReason
            switch error {
            case .messageTooLarge:
                reason = .associationByteLimit
            case .refused(let pressureReason):
                reason = pressureReason
            case .insufficientStorage:
                reason = .insufficientStorage
            }
            try refuseStore(command: command, reason: reason, error: error,
                            presentationContextID: commandContextID, association: association,
                            transport: transport, progress: progress)
            return nil
        }
        guard !payload.isCommand else {
            throw DicomStorageSCPError.missingCommandDataSet(command.commandField)
        }
        progress?(.metrics(resourceGovernor.snapshot()))
        do {
            // Disk-backed fragments already consumed their capacity; only the reserve remains to be checked.
            try storagePreflight.checkStorageAvailability(requiredBytes: receivedFile == nil ? payloadBytes : 0)
        } catch {
            try refuseStore(command: command, reason: .insufficientStorage, error: error,
                            presentationContextID: commandContextID, association: association,
                            transport: transport, progress: progress)
            return nil
        }
        receivedObjectCount += 1
        receivedByteCount += payloadBytes
        let context = try acceptedContext(id: payload.presentationContextID, association: association)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        // The File Meta was written for the command's context: the dataset must have come on it.
        guard receivedFile == nil || payload.presentationContextID == commandContextID else {
            throw DicomStorageSCPError.missingPresentationContext(payload.presentationContextID)
        }
        let dataSetData = try receivedFile?.finish() ?? payload.data
        let dataSet: DicomDataSet
        do {
            dataSet = try DicomDataSetParser.dataSet(
                from: dataSetData,
                transferSyntax: transferSyntax,
                limits: configuration.dataSetParseLimits
            )
        } catch let error as DicomDataSetParseError {
            resourceGovernor.recordFailure()
            try sendStoreResponse(
                command: command,
                status: 0xC000,
                errorComment: error.localizedDescription,
                presentationContextID: commandContextID,
                association: association,
                transport: transport
            )
            progress?(.storeFailed(
                sopInstanceUID: command.affectedSOPInstanceUID,
                errorDescription: error.localizedDescription
            ))
            return nil
        }
        let sopClassUID = command.affectedSOPClassUID ??
            dataSet.string(for: .sopClassUID) ??
            DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        let sopInstanceUID = command.affectedSOPInstanceUID ??
            dataSet.string(for: .sopInstanceUID) ??
            DicomDataSetWriter.makeUID()
        progress?(.instanceReceived(sopClassUID: sopClassUID, sopInstanceUID: sopInstanceUID))

        var receiving = DicomStorageReceivedInstance(sopClassUID: sopClassUID,
                                                    sopInstanceUID: sopInstanceUID,
                                                    transferSyntax: transferSyntax,
                                                    dataSet: dataSet,
                                                    rawDataSetData: dataSetData,
                                                    part10FileURL: receivedFile?.url)
        receiving.moveOriginatorAETitle = command.moveOriginatorAETitle
        receiving.moveOriginatorMessageID = command.moveOriginatorMessageID
        let received = receiving
        let stored: DicomStoredInstance
        do {
            try authorize?(dataSet)
            if let ingest {
                let result = try DicomIngestBlockingResult.run { try await ingest.ingest(received) }
                try durabilityPolicy.validate(result.durability)
                stored = .init(sopClassUID: sopClassUID, sopInstanceUID: sopInstanceUID,
                               transferSyntax: transferSyntax, fileURL: result.record.path,
                               isConflict: result.record.isConflict)
            } else { stored = try storage.store(received) }
        } catch {
            resourceGovernor.recordFailure()
            try sendStoreResponse(command: command,
                                  status: (error as? DicomIngestError)?.storageStatus ?? 0xC000,
                                  errorComment: error.localizedDescription,
                                  presentationContextID: commandContextID,
                                  association: association,
                                  transport: transport)
            progress?(.storeFailed(sopInstanceUID: sopInstanceUID,
                                   errorDescription: error.localizedDescription))
            return nil
        }
        do {
            try commitmentPersistence?.recordStoredInstance(stored)
        } catch {
            resourceGovernor.recordFailure()
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
        // A retained conflict must tell the peer that its bytes did not replace the original (issue #2529).
        try sendStoreResponse(command: command,
                              status: stored.isConflict ? 0xB000 : 0,
                              errorComment: nil,
                              presentationContextID: commandContextID,
                              association: association,
                              transport: transport)
        progress?(.instanceStored(stored))
        return stored
    }

    /// The file to receive the command's dataset into, when the storage offers a directory and the command names
    /// the object it carries. An object whose File Meta cannot be written, such as one with a malformed UID, is
    /// received in memory as before.
    private func receivedPart10File(command: DicomDIMSECommandSet, contextID: UInt8,
                                    association: DicomAssociation) -> DicomReceivedPart10File? {
        guard let directory = ingest?.receivedFileDirectory ?? storage.receivedFileDirectory,
              let sopClassUID = command.affectedSOPClassUID, !sopClassUID.isEmpty,
              let sopInstanceUID = command.affectedSOPInstanceUID, !sopInstanceUID.isEmpty,
              let context = try? acceptedContext(id: contextID, association: association) else { return nil }
        return try? DicomReceivedPart10File(directory: directory, sopClassUID: sopClassUID,
                                            sopInstanceUID: sopInstanceUID,
                                            transferSyntax: context.transferSyntax ?? .explicitVRLittleEndian)
    }

    private func discardStorePayload(
        reader: DicomDIMSEMessageReader,
        transport: DicomAssociationTransport
    ) throws {
        do {
            _ = try reader.readMessage(from: transport, maximumDataLength: 0)
        } catch DicomStorageSCPAdmissionError.messageTooLarge {
            return
        }
    }

    private func refuseStore(
        command: DicomDIMSECommandSet,
        reason: DicomStorageSCPPressureReason,
        error: any Error,
        presentationContextID: UInt8,
        association: DicomAssociation,
        transport: DicomAssociationTransport,
        progress: (@Sendable (DicomStorageSCPProgress) -> Void)?
    ) throws {
        resourceGovernor.recordFailure()
        try sendStoreResponse(command: command, status: 0xA700,
                              errorComment: error.localizedDescription,
                              presentationContextID: presentationContextID,
                              association: association, transport: transport)
        progress?(.pressure(reason))
        progress?(.storeFailed(sopInstanceUID: command.affectedSOPInstanceUID,
                               errorDescription: error.localizedDescription))
        progress?(.metrics(resourceGovernor.snapshot()))
    }

    private func handleCommitmentResult(command: DicomDIMSECommandSet, contextID: UInt8,
                                        association: DicomAssociation, transport: DicomAssociationTransport,
                                        reader: DicomDIMSEMessageReader) throws {
        let context = try acceptedContext(id: contextID, association: association)
        guard command.commandDataSetType != DicomDIMSECommandDataSetType.noDataSet else {
            throw DicomStorageSCPError.missingCommandDataSet(command.commandField)
        }
        let payload = try reader.readMessage(from: transport)
        guard !payload.isCommand, payload.presentationContextID == contextID else {
            throw DicomNetworkError.malformedCommandSet("Invalid commitment report dataset framing.")
        }
        var status: UInt16 = 0
        do {
            guard let handler = commitmentResultHandler,
                  context.abstractSyntaxUID == DicomNetworkUID.storageCommitmentPushModelSOPClass,
                  command.affectedSOPClassUID == context.abstractSyntaxUID,
                  command.affectedSOPInstanceUID == DicomNetworkUID.storageCommitmentPushModelSOPInstance,
                  command.eventTypeID == 1 || command.eventTypeID == 2 else {
                throw DicomStorageSCPError.malformedStorageCommitmentRequest
            }
            let dataSet = try DicomDataSetParser.dataSet(from: payload.data,
                transferSyntax: context.transferSyntax ?? .explicitVRLittleEndian, limits: configuration.dataSetParseLimits)
            let report = try DicomStorageCommitmentTracker.parseEventReportDataSet(dataSet)
            guard command.eventTypeID == 2 || report.references.allSatisfy({ $0.status == .committed }) else {
                throw DicomStorageSCPError.malformedStorageCommitmentRequest
            }
            try handler(report)
        } catch { status = 0x0110 }
        let response = DicomDIMSECommandSet(affectedSOPClassUID: command.affectedSOPClassUID,
            commandField: DicomDIMSECommandField.nEventReportRSP, messageIDBeingRespondedTo: command.messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.noDataSet, status: status,
            affectedSOPInstanceUID: command.affectedSOPInstanceUID, eventTypeID: command.eventTypeID)
        try sendCommand(response, presentationContextID: contextID, association: association, transport: transport)
    }

    private func handleStorageCommitment(command: DicomDIMSECommandSet,
                                         requestingAETitle: String,
                                         respondingAETitle: String,
                                         commandContextID: UInt8,
                                         association: DicomAssociation,
                                         transport: DicomAssociationTransport,
                                         reader: DicomDIMSEMessageReader) throws -> DicomStorageCommitmentReport? {
        let payload = try reader.readMessage(from: transport)
        guard !payload.isCommand else {
            throw DicomStorageSCPError.missingCommandDataSet(command.commandField)
        }
        let context = try acceptedContext(id: payload.presentationContextID, association: association)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        let dataSet: DicomDataSet
        do {
            dataSet = try DicomDataSetParser.dataSet(
                from: payload.data,
                transferSyntax: transferSyntax,
                limits: configuration.dataSetParseLimits
            )
        } catch is DicomDataSetParseError {
            resourceGovernor.recordFailure()
            try sendStorageCommitmentActionResponse(
                command: command,
                status: 0x0110,
                presentationContextID: commandContextID,
                association: association,
                transport: transport
            )
            return nil
        }
        let (transactionUID, references) = try DicomStorageCommitmentTracker.parseActionDataSet(dataSet)
        let report: DicomStorageCommitmentReport
        do {
            if let commitmentPersistence {
                report = try commitmentPersistence.prepareReport(
                    transactionUID,
                    requestingAETitle,
                    respondingAETitle,
                    references
                )
            } else {
                report = commitmentTracker.evaluate(transactionUID: transactionUID, references: references)
            }
        } catch {
            try sendStorageCommitmentActionResponse(
                command: command,
                status: 0x0110,
                presentationContextID: commandContextID,
                association: association,
                transport: transport
            )
            throw error
        }
        try sendStorageCommitmentActionResponse(
            command: command,
            status: 0,
            presentationContextID: commandContextID,
            association: association,
            transport: transport
        )
        return report
    }

    private func sendStorageCommitmentActionResponse(
        command: DicomDIMSECommandSet,
        status: UInt16,
        presentationContextID: UInt8,
        association: DicomAssociation,
        transport: DicomAssociationTransport
    ) throws {
        let response = DicomDIMSECommandSet(
            affectedSOPClassUID: DicomNetworkUID.storageCommitmentPushModelSOPClass,
            commandField: DicomDIMSECommandField.nActionRSP,
            messageIDBeingRespondedTo: command.messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
            status: status,
            affectedSOPInstanceUID: DicomNetworkUID.storageCommitmentPushModelSOPInstance,
            actionTypeID: command.actionTypeID
        )
        try sendCommand(response,
                        presentationContextID: presentationContextID,
                        association: association,
                        transport: transport)
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
public final class DicomStorageSCPServer: @unchecked Sendable {
    public let service: DicomStorageSCPService
    private let server: DicomDIMSEServer

    public init(service: DicomStorageSCPService) throws {
        self.service = service
        self.server = DicomDIMSEServer(legacyStorageService: service)
        try server.prepareListener()
    }

    public var listeningPort: UInt16? { server.listeningPort }
    public var metrics: DicomStorageSCPMetrics { server.metrics }

    public func start(progress: (@Sendable (DicomStorageSCPProgress) -> Void)? = nil) throws {
        try server.start(progress: progress)
    }

    public func stop() async { await server.stop() }
}

#endif

private enum StorageCommitmentTags {
    static let transactionUID = 0x0008_1195
    static let failureReason = 0x0008_1197
    static let failedSOPSequence = 0x0008_1198
    static let referencedSOPSequence = DicomTag.referencedSOPSequence.rawValue
}

private func string(_ tag: Int, vr: DicomVR, _ value: String) -> DicomDataElement {
    DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
}

private func sequence(_ tag: Int, _ items: [DicomSequenceItem]) -> DicomDataElement {
    DicomDataElement(tag: tag, vr: .SQ, value: .sequence(items))
}
