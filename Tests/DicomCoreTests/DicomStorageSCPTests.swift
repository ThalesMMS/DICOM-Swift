import Foundation
import DicomTestSupport
@testable import DicomCore
import XCTest

final class DicomStorageSCPTests: XCTestCase {
    func testStorageSCPContinuesAfterOneStoreFailure() throws {
        let storage = FailFirstStorage()
        let service = DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(
                aeTitle: "MTKDEMO",
                supportedStorageSOPClassUIDs: [storageSOPClassUID],
                transferSyntaxes: [.explicitVRLittleEndian]
            ),
            storage: storage
        )
        let secondSOPInstanceUID = "2.25.1001"
        let transport = try StorageSCUTransport(inboundPDUs: [
            associationRequestPDU(contexts: [
                DicomPresentationContextRequest(
                    id: 1,
                    abstractSyntaxUID: storageSOPClassUID,
                    transferSyntaxes: [.explicitVRLittleEndian]
                )
            ]),
            commandPDU(cStoreRequest(messageID: 1, sopInstanceUID: sopInstanceUID), contextID: 1),
            dataSetPDU(storageDataSet(sopInstanceUID: sopInstanceUID), contextID: 1),
            commandPDU(cStoreRequest(messageID: 2, sopInstanceUID: secondSOPInstanceUID), contextID: 1),
            dataSetPDU(
                storageDataSet(
                    sopInstanceUID: secondSOPInstanceUID,
                    patientName: "Иванов^Иван",
                    characterSet: "ISO_IR 144"
                ),
                contextID: 1
            ),
            try DicomPDUCodec.encode(.releaseRequest)
        ])
        let progressRecorder = DicomStorageSCPProgressRecorder()

        let result = try service.handleAssociation(using: transport) { progressRecorder.append($0) }

        XCTAssertEqual(result.storedInstances.map(\.sopInstanceUID), [secondSOPInstanceUID])
        XCTAssertEqual(storage.receivedInstances.last?.dataSet.string(for: .patientName), "Иванов^Иван")
        XCTAssertEqual(transport.writtenCommands.map(\.status), [0xC000, 0])
        XCTAssertTrue(progressRecorder.snapshot().contains {
            guard case .storeFailed(let failedUID, _) = $0 else { return false }
            return failedUID == sopInstanceUID
        })
        XCTAssertTrue(progressRecorder.snapshot().contains(.released))
    }

    func test_fileStorageCache_whenDataSetIsMutated_doesNotReuseStaleRawBytes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try DicomFileStorageCache(directoryURL: directory)
        var dataSet = storageDataSet()
        let rawData = try DicomDataSetWriter.dataSetData(from: dataSet)
        var received = DicomStorageReceivedInstance(
            sopClassUID: storageSOPClassUID,
            sopInstanceUID: sopInstanceUID,
            transferSyntax: .explicitVRLittleEndian,
            dataSet: dataSet,
            rawDataSetData: rawData
        )
        dataSet.set(DicomDataElement(
            tag: DicomTag.patientName.rawValue,
            vr: .PN,
            value: .strings(["Updated^Patient"])
        ))
        received.dataSet = dataSet

        let stored = try storage.store(received)
        let decoded = try DCMDecoder(contentsOf: stored.fileURL)

        XCTAssertNil(received.rawDataSetData)
        XCTAssertEqual(decoded.dataSet.string(for: .patientName), "Updated^Patient")
    }

    func testStorageSCPReceivesStoreWritesCacheAndReportsCommitment() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let storage = try DicomFileStorageCache(directoryURL: directory)
        let service = DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(
                aeTitle: "MTKDEMO",
                supportedStorageSOPClassUIDs: [storageSOPClassUID],
                transferSyntaxes: [.explicitVRLittleEndian]
            ),
            storage: storage
        )
        let transport = try StorageSCUTransport(inboundPDUs: [
            associationRequestPDU(contexts: [
                DicomPresentationContextRequest(id: 1,
                                                abstractSyntaxUID: storageSOPClassUID,
                                                transferSyntaxes: [.explicitVRLittleEndian]),
                DicomPresentationContextRequest(id: 3,
                                                abstractSyntaxUID: DicomNetworkUID.storageCommitmentPushModelSOPClass,
                                                transferSyntaxes: [.explicitVRLittleEndian])
            ]),
            commandPDU(cStoreRequest(), contextID: 1),
            dataSetPDU(storageDataSet(), contextID: 1),
            commandPDU(storageCommitmentAction(), contextID: 3),
            dataSetPDU(DicomStorageCommitmentTracker.actionDataSet(
                transactionUID: "2.25.999",
                references: [
                    DicomStorageCommitmentReference(sopClassUID: storageSOPClassUID,
                                                    sopInstanceUID: sopInstanceUID),
                    DicomStorageCommitmentReference(sopClassUID: storageSOPClassUID,
                                                    sopInstanceUID: "2.25.missing")
                ]
            ), contextID: 3),
            try DicomPDUCodec.encode(.releaseRequest)
        ])
        let progressRecorder = DicomStorageSCPProgressRecorder()

        let result = try service.handleAssociation(using: transport) { progressRecorder.append($0) }
        let progress = progressRecorder.snapshot()

        XCTAssertEqual(result.storedInstances.count, 1)
        XCTAssertEqual(result.storedInstances[0].sopInstanceUID, sopInstanceUID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.storedInstances[0].fileURL.path))
        let expectedDataSetData = try DicomDataSetWriter.dataSetData(from: storageDataSet())
        let storedData = try Data(contentsOf: result.storedInstances[0].fileURL)
        XCTAssertTrue(storedData.suffix(expectedDataSetData.count).elementsEqual(expectedDataSetData))
        let storedDecoder = try DCMDecoder(contentsOf: result.storedInstances[0].fileURL)
        XCTAssertNotNil(storedDecoder.pixelDataDescriptor)
        XCTAssertEqual(storedDecoder.getFrame(0)?.data, Data([0x7F]))
        XCTAssertEqual(result.commitmentReports.count, 1)
        XCTAssertEqual(result.commitmentReports[0].status, .partial)
        XCTAssertEqual(result.commitmentReports[0].references.filter { $0.status == .committed }.count, 1)
        XCTAssertEqual(result.commitmentReports[0].references.filter { $0.status == .failed }.count, 1)
        XCTAssertTrue(progress.contains(.instanceReceived(sopClassUID: storageSOPClassUID,
                                                          sopInstanceUID: sopInstanceUID)))
        XCTAssertTrue(progress.contains(.released))
        XCTAssertEqual(transport.writtenCommands.map(\.commandField), [
            DicomDIMSECommandField.cStoreRSP,
            DicomDIMSECommandField.nActionRSP
        ])
        XCTAssertEqual(transport.writtenCommands.first?.status, 0)
        XCTAssertEqual(transport.writtenCommands.last?.status, 0)
    }

    func testStorageSCPRejectsUnknownCalledAETitle() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(aeTitle: "MTKDEMO"),
            storage: try DicomFileStorageCache(directoryURL: directory)
        )
        let transport = try StorageSCUTransport(inboundPDUs: [
            associationRequestPDU(calledAETitle: "OTHER", contexts: [
                DicomPresentationContextRequest(id: 1,
                                                abstractSyntaxUID: storageSOPClassUID,
                                                transferSyntaxes: [.explicitVRLittleEndian])
            ])
        ])

        XCTAssertThrowsError(try service.handleAssociation(using: transport)) { error in
            XCTAssertEqual(error as? DicomStorageSCPError, .calledAETitleNotRecognized("OTHER"))
        }
        XCTAssertEqual(transport.writtenPDUTypes, [.associationReject])
    }

    func testStoreAndForwardQueueRetriesRecordsFailuresAndReloadsManifest() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try DicomStoreAndForwardQueue(directoryURL: directory)

        let entry = try queue.enqueue(dataSet: storageDataSet(),
                                      sopClassUID: storageSOPClassUID,
                                      sopInstanceUID: sopInstanceUID,
                                      maxAttempts: 2)

        let first = queue.processAll { _, _ in throw QueueFailure.offline }
        XCTAssertEqual(first.count, 1)
        XCTAssertFalse(first[0].success)
        XCTAssertEqual(queue.pendingEntries().first?.attempts, 1)
        XCTAssertEqual(queue.pendingEntries().first?.id, entry.id)

        let second = queue.processAll { _, _ in throw QueueFailure.offline }
        XCTAssertEqual(second.count, 1)
        XCTAssertFalse(second[0].success)
        XCTAssertEqual(queue.failedEntries().first?.attempts, 2)
        XCTAssertEqual(queue.failedEntries().first?.lastError, "offline")

        let reloaded = try DicomStoreAndForwardQueue(directoryURL: directory)
        XCTAssertEqual(reloaded.failedEntries().first?.id, entry.id)

        try reloaded.resetFailedEntry(id: entry.id)
        let delivered = reloaded.processAll { _, data in
            XCTAssertFalse(data.isEmpty)
        }
        XCTAssertEqual(delivered.first?.success, true)
        XCTAssertEqual(reloaded.allEntries().first?.state, .delivered)
    }

    func testStorageCommitmentEventReportRoundTripsDataset() throws {
        let report = DicomStorageCommitmentReport(
            transactionUID: "2.25.123",
            status: .partial,
            references: [
                DicomStorageCommitmentReference(sopClassUID: storageSOPClassUID,
                                                sopInstanceUID: sopInstanceUID,
                                                status: .committed),
                DicomStorageCommitmentReference(sopClassUID: storageSOPClassUID,
                                                sopInstanceUID: "2.25.failed",
                                                status: .failed)
            ]
        )

        let dataSet = DicomStorageCommitmentTracker.eventReportDataSet(for: report)
        let parsed = try DicomStorageCommitmentTracker.parseEventReportDataSet(dataSet)

        XCTAssertEqual(parsed, report)
    }

    func testStorageSCPServerAcceptsListenerTLSMaterial() throws {
        #if canImport(Network) && canImport(Security) && os(macOS)
        let fixture = try DicomTLSTestMaterial.write()
        defer { fixture.remove() }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(
                aeTitle: "MTKDEMO",
                port: 0,
                tls: DicomTLSConfiguration(
                    mode: .enabled,
                    material: DicomTLSMaterial(
                        certificatePath: fixture.serverCertificatePath,
                        privateKeyPath: fixture.serverPrivateKeyPath,
                        trustStorePath: fixture.caCertificatePath
                    ),
                    securityProfile: .bcp195
                )
            ),
            storage: try DicomFileStorageCache(directoryURL: directory)
        )

        _ = try DicomStorageSCPServer(service: service)
        #else
        throw skipNetworkSecurityTLS("Network/Security TLS listener tests run only on macOS.")
        #endif
    }

    func testStorageSCPTLSOptionsRequirePeerAuthenticationForTrustStore() throws {
        #if canImport(Network) && canImport(Security) && os(macOS)
        let fixture = try DicomTLSTestMaterial.write()
        defer { fixture.remove() }
        let tls = DicomTLSConfiguration(
            mode: .enabled,
            material: DicomTLSMaterial(
                certificatePath: fixture.serverCertificatePath,
                privateKeyPath: fixture.serverPrivateKeyPath,
                trustStorePath: fixture.caCertificatePath
            ),
            securityProfile: .extendedBCP195
        )

        let prepared = try DicomTLSOptionsFactory.preparedParameters(for: tls, role: .server)

        XCTAssertEqual(prepared.tlsContext?.role, .server)
        XCTAssertEqual(prepared.tlsContext?.hasLocalIdentity, true)
        XCTAssertEqual(prepared.tlsContext?.trustedCertificateCount, 1)
        XCTAssertEqual(prepared.tlsContext?.securityProfile, .extendedBCP195)
        XCTAssertEqual(prepared.tlsContext?.peerAuthenticationRequired, true)
        #else
        throw skipNetworkSecurityTLS("Network/Security TLS listener tests run only on macOS.")
        #endif
    }

    func testStorageSCPServerRejectsMissingListenerPrivateKey() throws {
        #if canImport(Network) && canImport(Security) && os(macOS)
        let fixture = try DicomTLSTestMaterial.write()
        defer { fixture.remove() }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(
                aeTitle: "MTKDEMO",
                port: 0,
                tls: DicomTLSConfiguration(
                    mode: .enabled,
                    material: DicomTLSMaterial(certificatePath: fixture.serverCertificatePath),
                    securityProfile: .bcp195
                )
            ),
            storage: try DicomFileStorageCache(directoryURL: directory)
        )

        XCTAssertThrowsError(try DicomStorageSCPServer(service: service)) { error in
            guard case .tlsConfigurationInvalid(let reason) = error as? DicomNetworkError else {
                return XCTFail("Expected TLS configuration error, got \(error)")
            }
            XCTAssertTrue(reason.contains("private key"))
        }
        #else
        throw skipNetworkSecurityTLS("Network/Security TLS listener tests run only on macOS.")
        #endif
    }
}

private func skipNetworkSecurityTLS(_ message: String) -> XCTSkip {
    XCTSkip(DicomTestRuntimePreflight.skipMessage(for: DicomRuntimeStatus(
        capability: .networkSecurityTLS,
        kind: .unsupportedFeature,
        message: message
    )))
}

private let storageSOPClassUID = DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
private let sopInstanceUID = "2.25.1000"

private enum QueueFailure: LocalizedError {
    case offline

    var errorDescription: String? { "offline" }
}

private final class DicomStorageSCPProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: [DicomStorageSCPProgress] = []

    func append(_ value: DicomStorageSCPProgress) {
        lock.lock()
        defer { lock.unlock() }
        progress.append(value)
    }

    func snapshot() -> [DicomStorageSCPProgress] {
        lock.lock()
        defer { lock.unlock() }
        return progress
    }
}

private final class StorageSCUTransport: DicomAssociationTransport {
    private var inboundPDUs: [Data]
    private(set) var writtenCommands: [DicomDIMSECommandSet] = []
    private(set) var writtenPDUTypes: [DicomPDUType] = []

    init(inboundPDUs: [Data]) {
        self.inboundPDUs = inboundPDUs
    }

    func writePDU(_ data: Data) throws {
        let pdu = try DicomPDUCodec.decode(data)
        writtenPDUTypes.append(pdu.type)
        if case .pData(let pdvs) = pdu {
            for pdv in pdvs where pdv.isCommand {
                writtenCommands.append(try DicomDIMSECommandSet.decode(pdv.data))
            }
        }
    }

    func readPDU() throws -> Data {
        guard !inboundPDUs.isEmpty else {
            throw DicomNetworkError.networkTimeout("test Storage SCP read")
        }
        return inboundPDUs.removeFirst()
    }
}

private func associationRequestPDU(calledAETitle: String = "MTKDEMO",
                                   contexts: [DicomPresentationContextRequest]) throws -> Data {
    try DicomPDUCodec.encode(.associationRequest(DicomAssociationRequest(
        calledAETitle: calledAETitle,
        callingAETitle: "ARCHIVE",
        presentationContexts: contexts
    )))
}

private func commandPDU(_ command: DicomDIMSECommandSet, contextID: UInt8) throws -> Data {
    try DicomPDUCodec.encode(.pData([
        DicomPDV(presentationContextID: contextID,
                isCommand: true,
                isLastFragment: true,
                data: try command.encoded())
    ]))
}

private func dataSetPDU(_ dataSet: DicomDataSet, contextID: UInt8) throws -> Data {
    try DicomPDUCodec.encode(.pData([
        DicomPDV(presentationContextID: contextID,
                isCommand: false,
                isLastFragment: true,
                data: try DicomDataSetWriter.dataSetData(from: dataSet,
                                                         transferSyntax: .explicitVRLittleEndian))
    ]))
}

private func cStoreRequest(
    messageID: UInt16 = 1,
    sopInstanceUID: String = sopInstanceUID
) -> DicomDIMSECommandSet {
    DicomDIMSECommandSet(
        affectedSOPClassUID: storageSOPClassUID,
        commandField: DicomDIMSECommandField.cStoreRQ,
        messageID: messageID,
        commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
        priority: 0,
        affectedSOPInstanceUID: sopInstanceUID
    )
}

private func storageCommitmentAction() -> DicomDIMSECommandSet {
    DicomDIMSECommandSet(
        affectedSOPClassUID: DicomNetworkUID.storageCommitmentPushModelSOPClass,
        commandField: DicomDIMSECommandField.nActionRQ,
        messageID: 2,
        commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
        affectedSOPInstanceUID: DicomNetworkUID.storageCommitmentPushModelSOPInstance,
        actionTypeID: 1
    )
}

private func storageDataSet(
    sopInstanceUID: String = sopInstanceUID,
    patientName: String = "DOE^JANE",
    characterSet: String? = nil
) -> DicomDataSet {
    var elements = [
        element(DicomTag.sopClassUID.rawValue, .UI, storageSOPClassUID),
        element(DicomTag.sopInstanceUID.rawValue, .UI, sopInstanceUID),
        element(DicomTag.patientName.rawValue, .PN, patientName),
        element(DicomTag.studyInstanceUID.rawValue, .UI, "2.25.2000"),
        element(DicomTag.seriesInstanceUID.rawValue, .UI, "2.25.3000"),
        DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
        element(DicomTag.photometricInterpretation.rawValue, .CS, "MONOCHROME2"),
        DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([1])),
        DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([1])),
        DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([8])),
        DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([8])),
        DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([7])),
        DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
        DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(Data([0x7F])))
    ]
    if let characterSet {
        elements.append(element(DicomTag.specificCharacterSet.rawValue, .CS, characterSet))
    }
    return DicomDataSet(elements: elements)
}

private func element(_ tag: Int, _ vr: DicomVR, _ value: String) -> DicomDataElement {
    DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("DicomStorageSCPTests-\(UUID().uuidString)",
                                isDirectory: true)
}

private final class FailFirstStorage: DicomStorageInstanceStoring {
    private(set) var receivedInstances: [DicomStorageReceivedInstance] = []

    func store(_ instance: DicomStorageReceivedInstance) throws -> DicomStoredInstance {
        receivedInstances.append(instance)
        if receivedInstances.count == 1 {
            throw QueueFailure.offline
        }
        return DicomStoredInstance(
            sopClassUID: instance.sopClassUID,
            sopInstanceUID: instance.sopInstanceUID,
            transferSyntax: instance.transferSyntax,
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(instance.sopInstanceUID)
        )
    }
}
