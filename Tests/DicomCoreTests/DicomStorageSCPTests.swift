import Foundation
import DicomTestSupport
@testable import DicomCore
import XCTest
#if canImport(Network)
import Network
#endif

final class DicomStorageSCPTests: XCTestCase {
    func test_sameUID_injectedCoordinator_warnsForConflictAndAcceptsIdenticalBytes() throws {
        try assertConflictResponses(injectCoordinator: true)
    }

    func test_sameUID_fileCache_warnsForConflictAndAcceptsIdenticalBytes() throws {
        try assertConflictResponses(injectCoordinator: false)
    }

    private func assertConflictResponses(injectCoordinator: Bool) throws {
        // Exercise both storage entry points so neither can silently accept a conflict (issue #2529).
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try DicomFileStorageCache(directoryURL: directory)
        let coordinator = DicomIngestCoordinator(root: directory, journal: cache.ingest.journal,
                                                 registrar: cache.ingest.registrar)
        let service = DicomStorageSCPService(configuration: .init(aeTitle: "MTKDEMO",
            supportedStorageSOPClassUIDs: [storageSOPClassUID], transferSyntaxes: [.explicitVRLittleEndian]),
            storage: cache, ingest: injectCoordinator ? coordinator : nil)
        let original = storageDataSet()
        var conflicting = original
        conflicting.set(.init(tag: 0x00100020, vr: .LO, value: .strings(["CONFLICT"])))
        var pdus = [try associationRequestPDU(contexts: [
            .init(id: 1, abstractSyntaxUID: storageSOPClassUID, transferSyntaxes: [.explicitVRLittleEndian])
        ])]
        for (offset, dataSet) in [original, original, conflicting, conflicting, original].enumerated() {
            pdus.append(try commandPDU(cStoreRequest(messageID: UInt16(offset + 1),
                                                    sopInstanceUID: sopInstanceUID), contextID: 1))
            pdus.append(try dataSetPDU(dataSet, contextID: 1))
        }
        pdus.append(try DicomPDUCodec.encode(.releaseRequest))
        let transport = StorageSCUTransport(inboundPDUs: pdus)
        let result = try service.handleAssociation(using: transport)
        XCTAssertEqual(transport.writtenCommands.map(\.status), [0, 0, 0xB000, 0xB000, 0])
        XCTAssertEqual(result.storedInstances.map(\.isConflict), [false, false, true, true, false])
        XCTAssertEqual(result.storedInstances.count, 5)
        let storedOriginal = try XCTUnwrap(result.storedInstances.first)
        let storedConflict = try XCTUnwrap(result.storedInstances.first(where: \.isConflict))
        XCTAssertEqual(storedOriginal.fileURL, result.storedInstances.last?.fileURL)
        XCTAssertTrue(storedConflict.fileURL.pathComponents.contains(".conflicts"))
        let originalBytes = try Data(contentsOf: storedOriginal.fileURL)
        let conflictBytes = try Data(contentsOf: storedConflict.fileURL)
        XCTAssertEqual(try DicomStoreRequest(part10Data: originalBytes).dataSetData,
                       try DicomDataSetWriter.dataSetData(from: original, transferSyntax: .explicitVRLittleEndian))
        XCTAssertEqual(try DicomStoreRequest(part10Data: conflictBytes).dataSetData,
                       try DicomDataSetWriter.dataSetData(from: conflicting, transferSyntax: .explicitVRLittleEndian))
    }

    func test_intranetPeerAccess_acceptsOnlyLoopbackAndPrivateIPv4Addresses() {
        let accepted = [
            "127.0.0.1",
            "127.255.255.254",
            "10.0.0.1",
            "10.255.255.254",
            "172.16.0.1",
            "172.31.255.254",
            "192.168.0.1",
            "192.168.255.254"
        ]
        let rejected = [
            "8.8.8.8",
            "172.15.255.255",
            "172.32.0.0",
            "169.254.1.1",
            "224.0.0.1",
            "010.0.0.1",
            "192.168.001.1",
            "１２７.0.0.1",
            "pacs.example.com"
        ]

        for address in accepted {
            XCTAssertTrue(DicomStorageSCPPeerAccess.isIntranetAddress(address), address)
        }
        for address in rejected {
            XCTAssertFalse(DicomStorageSCPPeerAccess.isIntranetAddress(address), address)
        }
    }

    func test_intranetPeerAccess_acceptsOnlyLoopbackAndPrivateIPv6Addresses() {
        let accepted = [
            "::1",
            "fc00::1",
            "fd12:3456:789a::1",
            "::ffff:127.0.0.1",
            "::ffff:192.168.1.10"
        ]
        let rejected = [
            "::",
            "fe80::1",
            "fe80::1%en0",
            "fd12:3456:789a::1%en0",
            "2001:db8::1",
            "2001:4860:4860::8888",
            "ff02::1"
        ]

        for address in accepted {
            XCTAssertTrue(DicomStorageSCPPeerAccess.isIntranetAddress(address), address)
        }
        for address in rejected {
            XCTAssertFalse(DicomStorageSCPPeerAccess.isIntranetAddress(address), address)
        }
    }

    func test_storageSCPConfiguration_intranetRestrictionIsOptIn() {
        let unrestricted = DicomStorageSCPConfiguration(aeTitle: "MTKDEMO")
        let restricted = DicomStorageSCPConfiguration(
            aeTitle: "MTKDEMO",
            acceptOnlyIntranet: true
        )

        XCTAssertFalse(unrestricted.acceptOnlyIntranet)
        XCTAssertTrue(restricted.acceptOnlyIntranet)
    }

    func test_resourceGovernor_enforcesGlobalAndPerPeerAssociationLimits() {
        let configuration = DicomStorageSCPConfiguration(
            aeTitle: "MTKDEMO",
            maximumConcurrentAssociations: 2,
            maximumConnectionsPerPeer: 1
        )
        let governor = DicomStorageSCPResourceGovernor(configuration: configuration)

        XCTAssertNil(governor.admitAssociation(peer: "10.0.0.1"))
        XCTAssertEqual(governor.admitAssociation(peer: "10.0.0.1"), .peerConnectionLimit)
        XCTAssertNil(governor.admitAssociation(peer: "10.0.0.2"))
        XCTAssertEqual(governor.admitAssociation(peer: "10.0.0.3"), .associationLimit)
        XCTAssertEqual(governor.snapshot().activeAssociations, 2)
        XCTAssertEqual(governor.snapshot().rejectedAssociations, 2)

        governor.releaseAssociation(peer: "10.0.0.1")
        XCTAssertNil(governor.admitAssociation(peer: "10.0.0.3"))
    }

    func test_resourceGovernor_boundsStoreRequestsAndStagedBytes() {
        let configuration = DicomStorageSCPConfiguration(
            aeTitle: "MTKDEMO",
            maximumInFlightStoreRequests: 1,
            maximumStagedBytes: 10
        )
        let governor = DicomStorageSCPResourceGovernor(configuration: configuration)

        XCTAssertNil(governor.beginStore())
        XCTAssertEqual(governor.beginStore(), .storeRequestLimit)
        XCTAssertTrue(governor.reserveStagedBytes(8))
        XCTAssertFalse(governor.reserveStagedBytes(3))
        XCTAssertEqual(governor.snapshot().stagedBytes, 8)

        governor.releaseStagedBytes(8)
        governor.endStore()
        XCTAssertEqual(governor.snapshot().inFlightStoreRequests, 0)
        XCTAssertEqual(governor.snapshot().stagedBytes, 0)
    }

    func test_resourceGovernor_concurrentBurstNeverAdmitsBeyondConfiguredWorkers() async {
        let configuration = DicomStorageSCPConfiguration(
            aeTitle: "MTKDEMO",
            maximumConcurrentAssociations: 4,
            maximumConnectionsPerPeer: 4
        )
        let governor = DicomStorageSCPResourceGovernor(configuration: configuration)

        await withTaskGroup(of: Void.self) { group in
            for peerIndex in 0..<100 {
                group.addTask {
                    _ = governor.admitAssociation(peer: "10.0.0.\(peerIndex)")
                }
            }
        }

        XCTAssertEqual(governor.snapshot().activeAssociations, 4)
        XCTAssertEqual(governor.snapshot().admittedAssociations, 4)
        XCTAssertEqual(governor.snapshot().rejectedAssociations, 96)
    }

    func test_DIMSEReader_releasesIncrementalReservationWhenFragmentedPayloadExceedsBudget() throws {
        let transport = StorageSCUTransport(inboundPDUs: [
            try DicomPDUCodec.encode(.pData([
                DicomPDV(presentationContextID: 1, isCommand: false, isLastFragment: false, data: Data([1, 2, 3])),
                DicomPDV(presentationContextID: 1, isCommand: false, isLastFragment: true, data: Data([4, 5, 6]))
            ]))
        ])
        var reservedBytes: Int64 = 0
        var maximumReservedBytes: Int64 = 0
        let reader = DicomDIMSEMessageReader()

        XCTAssertThrowsError(try reader.readMessage(
            from: transport,
            reserveData: { bytes in
                guard reservedBytes <= 4 - bytes else { return false }
                reservedBytes += bytes
                maximumReservedBytes = max(maximumReservedBytes, reservedBytes)
                return true
            },
            releaseData: { reservedBytes -= $0 }
        )) { error in
            XCTAssertEqual(error as? DicomStorageSCPAdmissionError, .refused(.stagedByteLimit))
        }
        XCTAssertEqual(maximumReservedBytes, 3)
        XCTAssertEqual(reservedBytes, 0)
    }

    #if canImport(Network)
    func test_intranetPeerAccess_rejectsPublicEndpointOnlyWhenRestrictionIsEnabled() {
        let privateEndpoint = NWEndpoint.hostPort(host: "192.168.1.20", port: 11112)
        let publicEndpoint = NWEndpoint.hostPort(host: "8.8.8.8", port: 11112)
        let hostnameEndpoint = NWEndpoint.hostPort(host: "localhost", port: 11112)
        let scopedEndpoint = NWEndpoint.hostPort(host: "fd12:3456:789a::1%en0", port: 11112)

        XCTAssertTrue(DicomStorageSCPPeerAccess.allows(privateEndpoint, acceptOnlyIntranet: true))
        XCTAssertFalse(DicomStorageSCPPeerAccess.allows(publicEndpoint, acceptOnlyIntranet: true))
        XCTAssertFalse(DicomStorageSCPPeerAccess.allows(hostnameEndpoint, acceptOnlyIntranet: true))
        XCTAssertFalse(DicomStorageSCPPeerAccess.allows(scopedEndpoint, acceptOnlyIntranet: true))
        XCTAssertTrue(DicomStorageSCPPeerAccess.allows(publicEndpoint, acceptOnlyIntranet: false))
    }
    #endif

    func testStorageSCPAcceptsVerification() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(
                aeTitle: "MTKDEMO",
                transferSyntaxes: [.explicitVRLittleEndian],
                enableStorageCommitment: false
            ),
            storage: try DicomFileStorageCache(directoryURL: directory)
        )
        let transport = try StorageSCUTransport(inboundPDUs: [
            associationRequestPDU(contexts: [
                DicomPresentationContextRequest(
                    id: 1,
                    abstractSyntaxUID: DicomNetworkUID.verificationSOPClass,
                    transferSyntaxes: [.explicitVRLittleEndian]
                )
            ]),
            commandPDU(cEchoRequest(), contextID: 1),
            try DicomPDUCodec.encode(.releaseRequest)
        ])

        let result = try service.handleAssociation(using: transport)

        XCTAssertTrue(result.storedInstances.isEmpty)
        XCTAssertEqual(transport.writtenCommands.count, 1)
        XCTAssertEqual(transport.writtenCommands.first?.commandField, DicomDIMSECommandField.cEchoRSP)
        XCTAssertEqual(transport.writtenCommands.first?.status, 0)
    }

    func testStorageSCPAcceptsAllowedCallingAETitle() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(
                aeTitle: "MTKDEMO",
                transferSyntaxes: [.explicitVRLittleEndian],
                allowedCallingAETitles: ["ARCHIVE"],
                enableStorageCommitment: false
            ),
            storage: try DicomFileStorageCache(directoryURL: directory)
        )
        let transport = try StorageSCUTransport(inboundPDUs: [
            associationRequestPDU(callingAETitle: "ARCHIVE", contexts: [
                DicomPresentationContextRequest(
                    id: 1,
                    abstractSyntaxUID: DicomNetworkUID.verificationSOPClass,
                    transferSyntaxes: [.explicitVRLittleEndian]
                )
            ]),
            commandPDU(cEchoRequest(), contextID: 1),
            try DicomPDUCodec.encode(.releaseRequest)
        ])

        _ = try service.handleAssociation(using: transport)

        XCTAssertEqual(transport.writtenPDUTypes.first, .associationAccept)
    }

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
        XCTAssertTrue(progressRecorder.snapshot().contains {
            guard case .metrics(let metrics) = $0 else { return false }
            return metrics.inFlightStoreRequests == 1 && metrics.stagedBytes > 0
        })
        XCTAssertTrue(progressRecorder.snapshot().contains {
            guard case .metrics(let metrics) = $0 else { return false }
            return metrics.inFlightStoreRequests == 0 && metrics.stagedBytes == 0 && metrics.recentFailureCount == 1
        })
        XCTAssertTrue(progressRecorder.snapshot().contains(.released))
    }

    func test_storageSCP_definedSequenceDepthLimit_rejectsInstanceAndContinuesAssociation() throws {
        let innerSequence = explicitSequenceData(
            tag: 0x0008_0110,
            items: [explicitItemData(Data())]
        )
        let payload = explicitSequenceData(
            tag: 0x0008_1032,
            items: [explicitItemData(innerSequence)]
        )

        try assertStorageSCPRejectsStructuralPayloadAndContinues(
            payload,
            limits: DicomDataSetParseLimits(
                maximumSequenceDepth: 1,
                maximumElementCount: 10,
                maximumItemCount: 10
            ),
            maliciousSOPInstanceUID: "2.25.2127.1",
            validSOPInstanceUID: "2.25.2127.2"
        )
    }

    func test_storageSCP_undefinedSequenceItemLimit_rejectsInstanceAndContinuesAssociation() throws {
        let payload = undefinedSequenceData(
            tag: 0x0008_1032,
            items: [explicitItemData(Data()), explicitItemData(Data())]
        )

        try assertStorageSCPRejectsStructuralPayloadAndContinues(
            payload,
            limits: DicomDataSetParseLimits(
                maximumSequenceDepth: 1,
                maximumElementCount: 10,
                maximumItemCount: 1
            ),
            maliciousSOPInstanceUID: "2.25.2127.3",
            validSOPInstanceUID: "2.25.2127.4"
        )
    }

    func test_storageSCP_elementLimit_rejectsInstanceAndContinuesAssociation() throws {
        let payload = explicitStringElementData(tag: 0x0010_0010, vr: "PN", value: "A ")
            + explicitStringElementData(tag: 0x0008_1030, vr: "LO", value: "B ")

        try assertStorageSCPRejectsStructuralPayloadAndContinues(
            payload,
            limits: DicomDataSetParseLimits(
                maximumSequenceDepth: 1,
                maximumElementCount: 1,
                maximumItemCount: 1
            ),
            maliciousSOPInstanceUID: "2.25.2127.5",
            validSOPInstanceUID: "2.25.2127.6"
        )
    }

    func test_storageCommitment_structuralLimit_returnsProcessingFailureAndReleasesAssociation() throws {
        let storage = FailFirstStorage(failFirst: false)
        let service = DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(
                aeTitle: "MTKDEMO",
                supportedStorageSOPClassUIDs: [storageSOPClassUID],
                transferSyntaxes: [.explicitVRLittleEndian],
                dataSetParseLimits: DicomDataSetParseLimits(
                    maximumSequenceDepth: 1,
                    maximumElementCount: 1,
                    maximumItemCount: 1
                )
            ),
            storage: storage
        )
        let malformedActionDataSet = explicitStringElementData(tag: 0x0008_1195, vr: "UI", value: "1 ")
            + explicitStringElementData(tag: 0x0010_0010, vr: "PN", value: "A ")
        let transport = try StorageSCUTransport(inboundPDUs: [
            associationRequestPDU(contexts: [
                DicomPresentationContextRequest(
                    id: 3,
                    abstractSyntaxUID: DicomNetworkUID.storageCommitmentPushModelSOPClass,
                    transferSyntaxes: [.explicitVRLittleEndian]
                )
            ]),
            commandPDU(storageCommitmentAction(), contextID: 3),
            rawDataSetPDU(malformedActionDataSet, contextID: 3),
            try DicomPDUCodec.encode(.releaseRequest)
        ])
        let progressRecorder = DicomStorageSCPProgressRecorder()

        let result = try service.handleAssociation(using: transport) { progressRecorder.append($0) }

        XCTAssertTrue(result.commitmentReports.isEmpty)
        XCTAssertTrue(storage.receivedInstances.isEmpty)
        XCTAssertEqual(transport.writtenCommands.map(\.status), [0x0110])
        XCTAssertEqual(transport.writtenPDUTypes.last, .releaseResponse)
        XCTAssertTrue(progressRecorder.snapshot().contains(.released))
    }

    private func assertStorageSCPRejectsStructuralPayloadAndContinues(
        _ maliciousPayload: Data,
        limits: DicomDataSetParseLimits,
        maliciousSOPInstanceUID: String,
        validSOPInstanceUID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let storage = FailFirstStorage(failFirst: false)
        let service = DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(
                aeTitle: "MTKDEMO",
                supportedStorageSOPClassUIDs: [storageSOPClassUID],
                transferSyntaxes: [.explicitVRLittleEndian],
                dataSetParseLimits: limits
            ),
            storage: storage
        )
        let validPayload = explicitStringElementData(tag: 0x0010_0010, vr: "PN", value: "OK")
        let transport = try StorageSCUTransport(inboundPDUs: [
            associationRequestPDU(contexts: [
                DicomPresentationContextRequest(
                    id: 1,
                    abstractSyntaxUID: storageSOPClassUID,
                    transferSyntaxes: [.explicitVRLittleEndian]
                )
            ]),
            commandPDU(
                cStoreRequest(messageID: 1, sopInstanceUID: maliciousSOPInstanceUID),
                contextID: 1
            ),
            rawDataSetPDU(maliciousPayload, contextID: 1),
            commandPDU(cStoreRequest(messageID: 2, sopInstanceUID: validSOPInstanceUID), contextID: 1),
            rawDataSetPDU(validPayload, contextID: 1),
            try DicomPDUCodec.encode(.releaseRequest)
        ])
        let progressRecorder = DicomStorageSCPProgressRecorder()

        let result = try service.handleAssociation(using: transport) { progressRecorder.append($0) }
        let progress = progressRecorder.snapshot()

        XCTAssertEqual(transport.writtenCommands.map(\.status), [0xC000, 0], file: file, line: line)
        XCTAssertEqual(result.storedInstances.map(\.sopInstanceUID), [validSOPInstanceUID], file: file, line: line)
        XCTAssertEqual(
            storage.receivedInstances.map(\.sopInstanceUID),
            [validSOPInstanceUID],
            file: file,
            line: line
        )
        XCTAssertTrue(progress.contains {
            guard case .storeFailed(let failedUID, _) = $0 else { return false }
            return failedUID == maliciousSOPInstanceUID
        }, file: file, line: line)
        XCTAssertTrue(progress.contains(.released), file: file, line: line)
        XCTAssertEqual(transport.writtenPDUTypes.last, .releaseResponse, file: file, line: line)
    }

    func test_storageSCP_refusesObjectAboveAssociationCountAndContinuesToRelease() throws {
        let storage = FailFirstStorage(failFirst: false)
        let service = DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(
                aeTitle: "MTKDEMO",
                supportedStorageSOPClassUIDs: [storageSOPClassUID],
                transferSyntaxes: [.explicitVRLittleEndian],
                maximumObjectsPerAssociation: 1
            ),
            storage: storage
        )
        let transport = try StorageSCUTransport(inboundPDUs: [
            associationRequestPDU(contexts: [
                DicomPresentationContextRequest(id: 1, abstractSyntaxUID: storageSOPClassUID,
                                                transferSyntaxes: [.explicitVRLittleEndian])
            ]),
            commandPDU(cStoreRequest(messageID: 1), contextID: 1),
            dataSetPDU(storageDataSet(), contextID: 1),
            commandPDU(cStoreRequest(messageID: 2, sopInstanceUID: "2.25.1002"), contextID: 1),
            dataSetPDU(storageDataSet(sopInstanceUID: "2.25.1002"), contextID: 1),
            try DicomPDUCodec.encode(.releaseRequest)
        ])

        let result = try service.handleAssociation(using: transport)

        XCTAssertEqual(result.storedInstances.count, 1)
        XCTAssertEqual(transport.writtenCommands.map(\.status), [0, 0xA700])
        XCTAssertEqual(transport.writtenPDUTypes.last, .releaseResponse)
    }

    func test_storageSCP_discardsOversizedPayloadWithoutRetainingItAndReleases() throws {
        let storage = FailFirstStorage(failFirst: false)
        let service = DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(
                aeTitle: "MTKDEMO",
                supportedStorageSOPClassUIDs: [storageSOPClassUID],
                transferSyntaxes: [.explicitVRLittleEndian],
                maximumStagedBytes: 1
            ),
            storage: storage
        )
        let transport = try StorageSCUTransport(inboundPDUs: [
            associationRequestPDU(contexts: [
                DicomPresentationContextRequest(id: 1, abstractSyntaxUID: storageSOPClassUID,
                                                transferSyntaxes: [.explicitVRLittleEndian])
            ]),
            commandPDU(cStoreRequest(), contextID: 1),
            dataSetPDU(storageDataSet(), contextID: 1),
            try DicomPDUCodec.encode(.releaseRequest)
        ])

        let result = try service.handleAssociation(using: transport)

        XCTAssertTrue(result.storedInstances.isEmpty)
        XCTAssertTrue(storage.receivedInstances.isEmpty)
        XCTAssertEqual(transport.writtenCommands.first?.status, 0xA700)
        XCTAssertEqual(transport.writtenPDUTypes.last, .releaseResponse)
    }

    func test_storageSCP_lowStorageRefusesInstanceButKeepsAssociationHealthy() throws {
        let storage = FailFirstStorage(failFirst: false)
        let service = DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(
                aeTitle: "MTKDEMO",
                supportedStorageSOPClassUIDs: [storageSOPClassUID],
                transferSyntaxes: [.explicitVRLittleEndian]
            ),
            storage: storage,
            storagePreflight: RefusingStoragePreflight()
        )
        let transport = try StorageSCUTransport(inboundPDUs: [
            associationRequestPDU(contexts: [
                DicomPresentationContextRequest(id: 1, abstractSyntaxUID: storageSOPClassUID,
                                                transferSyntaxes: [.explicitVRLittleEndian])
            ]),
            commandPDU(cStoreRequest(), contextID: 1),
            dataSetPDU(storageDataSet(), contextID: 1),
            try DicomPDUCodec.encode(.releaseRequest)
        ])

        let result = try service.handleAssociation(using: transport)

        XCTAssertTrue(result.storedInstances.isEmpty)
        XCTAssertEqual(transport.writtenCommands.first?.status, 0xA700)
        XCTAssertEqual(transport.writtenPDUTypes.last, .releaseResponse)
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

    func test_fileStorageCache_preservesValidatedCompressedRawPixelData() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/DecoderParity/jpeg_lossless_sv1_parity.dcm")
        let sourceDecoder = try DCMDecoder(contentsOf: sourceURL)
        let request = try DicomStoreRequest(part10FileAt: sourceURL)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try DicomFileStorageCache(directoryURL: directory)
        let received = DicomStorageReceivedInstance(
            sopClassUID: request.sopClassUID,
            sopInstanceUID: request.sopInstanceUID,
            transferSyntax: request.transferSyntax,
            dataSet: try DicomDataSetParser.dataSet(
                from: request.dataSetData,
                transferSyntax: request.transferSyntax
            ),
            rawDataSetData: request.dataSetData
        )

        let stored = try storage.store(received)
        let storedDecoder = try DCMDecoder(contentsOf: stored.fileURL)

        XCTAssertEqual(stored.transferSyntax, .jpegLosslessFirstOrder)
        XCTAssertEqual(storedDecoder.info(for: .sopInstanceUID), request.sopInstanceUID)
        XCTAssertEqual(storedDecoder.getPixels16(), sourceDecoder.getPixels16())
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
        XCTAssertEqual(
            result.commitmentReports[0].references.first { $0.status == .failed }?.failureReasonCode,
            0x0112
        )
        let eventDataSet = DicomStorageCommitmentTracker.eventReportDataSet(for: result.commitmentReports[0])
        let parsedEvent = try DicomStorageCommitmentTracker.parseEventReportDataSet(eventDataSet)
        XCTAssertEqual(parsedEvent, result.commitmentReports[0])
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

    func testStorageCommitmentPersistenceRunsBeforeSuccessfulDIMSEResponses() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = StorageCommitmentPersistenceRecorder()
        let service = DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(
                aeTitle: "MTKDEMO",
                supportedStorageSOPClassUIDs: [storageSOPClassUID],
                transferSyntaxes: [.explicitVRLittleEndian]
            ),
            storage: try DicomFileStorageCache(directoryURL: directory),
            commitmentPersistence: DicomStorageCommitmentPersistence(
                recordStoredInstance: recorder.record,
                prepareReport: recorder.prepare
            )
        )
        let transport = try StorageSCUTransport(inboundPDUs: [
            associationRequestPDU(contexts: [
                DicomPresentationContextRequest(
                    id: 1,
                    abstractSyntaxUID: storageSOPClassUID,
                    transferSyntaxes: [.explicitVRLittleEndian]
                ),
                DicomPresentationContextRequest(
                    id: 3,
                    abstractSyntaxUID: DicomNetworkUID.storageCommitmentPushModelSOPClass,
                    transferSyntaxes: [.explicitVRLittleEndian]
                )
            ]),
            commandPDU(cStoreRequest(), contextID: 1),
            dataSetPDU(storageDataSet(), contextID: 1),
            commandPDU(storageCommitmentAction(), contextID: 3),
            dataSetPDU(DicomStorageCommitmentTracker.actionDataSet(
                transactionUID: "2.25.durable",
                references: [
                    DicomStorageCommitmentReference(
                        sopClassUID: storageSOPClassUID,
                        sopInstanceUID: sopInstanceUID
                    )
                ]
            ), contextID: 3),
            try DicomPDUCodec.encode(.releaseRequest)
        ])

        let result = try service.handleAssociation(using: transport)

        XCTAssertEqual(recorder.events, ["stored", "prepared"])
        XCTAssertEqual(result.commitmentReports.first?.transactionUID, "2.25.durable")
        XCTAssertEqual(transport.writtenCommands.map(\.status), [0, 0])
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

    func testStorageSCPRejectsUnknownCallingAETitleBeforeStore() throws {
        let storage = FailFirstStorage()
        let service = DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(
                aeTitle: "MTKDEMO",
                supportedStorageSOPClassUIDs: [storageSOPClassUID],
                transferSyntaxes: [.explicitVRLittleEndian],
                allowedCallingAETitles: ["TRUSTED"]
            ),
            storage: storage
        )
        let transport = try StorageSCUTransport(inboundPDUs: [
            associationRequestPDU(callingAETitle: "UNTRUSTED", contexts: [
                DicomPresentationContextRequest(
                    id: 1,
                    abstractSyntaxUID: storageSOPClassUID,
                    transferSyntaxes: [.explicitVRLittleEndian]
                )
            ]),
            commandPDU(cStoreRequest(), contextID: 1),
            dataSetPDU(storageDataSet(), contextID: 1)
        ])

        XCTAssertThrowsError(try service.handleAssociation(using: transport)) { error in
            XCTAssertEqual(error as? DicomStorageSCPError, .callingAETitleNotRecognized("UNTRUSTED"))
        }
        XCTAssertEqual(transport.writtenPDUTypes, [.associationReject])
        XCTAssertEqual(transport.writtenAssociationRejects.first?.result, .rejectedPermanent)
        XCTAssertEqual(transport.writtenAssociationRejects.first?.source, .serviceUser)
        XCTAssertEqual(transport.writtenAssociationRejects.first?.reason, .callingAENotRecognized)
        XCTAssertTrue(storage.receivedInstances.isEmpty)
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
                                                status: .failed,
                                                failureReasonCode: 0x0110)
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
                    securityProfile: .bcp195RFC8996
                )
            ),
            storage: try DicomFileStorageCache(directoryURL: directory)
        )

        _ = try DicomStorageSCPServer(service: service)
        #else
        throw skipNetworkSecurityTLS("Network/Security TLS listener tests run only on macOS.")
        #endif
    }

    @MainActor
    func test_storageSCPServerStop_releasesPortBeforeReturning() async throws {
        #if canImport(Network)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstService = DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(aeTitle: "MTKDEMO", port: 0),
            storage: try DicomFileStorageCache(directoryURL: directory)
        )
        let firstServer = try DicomStorageSCPServer(service: firstService)
        try firstServer.start()
        let port = try XCTUnwrap(firstServer.listeningPort)

        await firstServer.stop()

        let replacementService = DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(aeTitle: "MTKDEMO", port: port),
            storage: try DicomFileStorageCache(directoryURL: directory)
        )
        let replacementServer = try DicomStorageSCPServer(service: replacementService)
        XCTAssertNoThrow(try replacementServer.start())
        await replacementServer.stop()
        #else
        throw XCTSkip("Network framework is unavailable on this platform.")
        #endif
    }

    func test_storageSCPServerStop_withoutStart_returnsImmediately() async throws {
        #if canImport(Network)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(aeTitle: "MTKDEMO", port: 0, timeout: 2),
            storage: try DicomFileStorageCache(directoryURL: directory)
        )
        let server = try DicomStorageSCPServer(service: service)
        let startedAt = Date()

        await server.stop()

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        #else
        throw XCTSkip("Network framework is unavailable on this platform.")
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
            securityProfile: .bcp195RFC8996
        )

        let prepared = try DicomTLSOptionsFactory.preparedParameters(for: tls, role: .server)

        XCTAssertEqual(prepared.tlsContext?.role, .server)
        XCTAssertEqual(prepared.tlsContext?.hasLocalIdentity, true)
        XCTAssertEqual(prepared.tlsContext?.trustedCertificateCount, 1)
        XCTAssertEqual(prepared.tlsContext?.securityProfile, .bcp195RFC8996)
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
                    securityProfile: .bcp195RFC8996
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

private enum StorageCommitmentPersistenceTestError: Error {
    case preparedBeforeStored
}

private final class StorageCommitmentPersistenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    func record(_ instance: DicomStoredInstance) throws {
        lock.lock()
        storedEvents.append("stored")
        lock.unlock()
    }

    func prepare(
        _ transactionUID: String,
        _ requestingAETitle: String,
        _ respondingAETitle: String,
        _ references: [DicomStorageCommitmentReference]
    ) throws -> DicomStorageCommitmentReport {
        lock.lock()
        defer { lock.unlock() }
        guard storedEvents.last == "stored" else {
            throw StorageCommitmentPersistenceTestError.preparedBeforeStored
        }
        storedEvents.append("prepared")
        return DicomStorageCommitmentReport(
            transactionUID: transactionUID,
            status: .committed,
            references: references.map {
                DicomStorageCommitmentReference(
                    sopClassUID: $0.sopClassUID,
                    sopInstanceUID: $0.sopInstanceUID,
                    status: .committed
                )
            }
        )
    }
}

private struct RefusingStoragePreflight: DicomStoragePreflightChecking {
    func checkStorageAvailability(requiredBytes: Int64) throws {
        throw DicomStorageSCPAdmissionError.insufficientStorage(requiredBytes: requiredBytes)
    }
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
    private(set) var writtenAssociationAccepts: [DicomAssociationAccept] = []
    private(set) var writtenAssociationRejects: [DicomAssociationReject] = []

    init(inboundPDUs: [Data]) {
        self.inboundPDUs = inboundPDUs
    }

    func writePDU(_ data: Data) throws {
        let pdu = try DicomPDUCodec.decode(data)
        writtenPDUTypes.append(pdu.type)
        if case .associationAccept(let accept) = pdu { writtenAssociationAccepts.append(accept) }
        if case .associationReject(let reject) = pdu {
            writtenAssociationRejects.append(reject)
        }
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
                                   callingAETitle: String = "ARCHIVE",
                                   contexts: [DicomPresentationContextRequest]) throws -> Data {
    try DicomPDUCodec.encode(.associationRequest(DicomAssociationRequest(
        calledAETitle: calledAETitle,
        callingAETitle: callingAETitle,
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

private func rawDataSetPDU(_ dataSetData: Data, contextID: UInt8) throws -> Data {
    try DicomPDUCodec.encode(.pData([
        DicomPDV(
            presentationContextID: contextID,
            isCommand: false,
            isLastFragment: true,
            data: dataSetData
        )
    ]))
}

private func explicitSequenceData(tag: Int, items: [Data]) -> Data {
    let value = items.reduce(into: Data()) { $0.append($1) }
    return explicitLongValueElementData(tag: tag, vr: "SQ", value: value, length: UInt32(value.count))
}

private func undefinedSequenceData(tag: Int, items: [Data]) -> Data {
    var data = explicitLongValueElementData(tag: tag, vr: "SQ", value: Data(), length: .max)
    items.forEach { data.append($0) }
    data.append(rawTagAndLengthData(tag: 0xFFFE_E0DD, length: 0))
    return data
}

private func explicitItemData(_ value: Data) -> Data {
    rawTagAndLengthData(tag: 0xFFFE_E000, length: UInt32(value.count)) + value
}

private func explicitStringElementData(tag: Int, vr: String, value: String) -> Data {
    let valueData = Data(value.utf8)
    var data = rawTagData(tag)
    data.append(contentsOf: vr.utf8)
    data.append(littleEndianData(UInt16(valueData.count)))
    data.append(valueData)
    return data
}

private func explicitLongValueElementData(
    tag: Int,
    vr: String,
    value: Data,
    length: UInt32
) -> Data {
    var data = rawTagData(tag)
    data.append(contentsOf: vr.utf8)
    data.append(contentsOf: [0, 0])
    data.append(littleEndianData(length))
    data.append(value)
    return data
}

private func rawTagAndLengthData(tag: Int, length: UInt32) -> Data {
    var data = rawTagData(tag)
    data.append(littleEndianData(length))
    return data
}

private func rawTagData(_ tag: Int) -> Data {
    littleEndianData(UInt16((tag >> 16) & 0xFFFF)) + littleEndianData(UInt16(tag & 0xFFFF))
}

private func littleEndianData<T: FixedWidthInteger>(_ value: T) -> Data {
    var littleEndian = value.littleEndian
    return withUnsafeBytes(of: &littleEndian) { Data($0) }
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

private func cEchoRequest(messageID: UInt16 = 1) -> DicomDIMSECommandSet {
    DicomDIMSECommandSet(
        affectedSOPClassUID: DicomNetworkUID.verificationSOPClass,
        commandField: DicomDIMSECommandField.cEchoRQ,
        messageID: messageID,
        commandDataSetType: DicomDIMSECommandDataSetType.noDataSet
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
    private let receivedInstancesStorage = DicomTestLockedValue<[DicomStorageReceivedInstance]>([])
    private let failFirst: Bool

    private(set) var receivedInstances: [DicomStorageReceivedInstance] {
        get { receivedInstancesStorage.value }
        set { receivedInstancesStorage.replace(with: newValue) }
    }

    init(failFirst: Bool = true) {
        self.failFirst = failFirst
    }

    func store(_ instance: DicomStorageReceivedInstance) throws -> DicomStoredInstance {
        let receivedCount = receivedInstancesStorage.withValue { instances in
            instances.append(instance)
            return instances.count
        }
        if failFirst, receivedCount == 1 {
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


extension DicomStorageSCPTests {
    func test_identityProvider_allTypesReturnPositiveResponseAndLocalMaximum() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DicomStorageSCPService(configuration: .init(aeTitle: "SCP", maximumPDULength: 1024),
            storage: try DicomFileStorageCache(directoryURL: directory), userIdentityAuthenticator: A1IdentityProvider())
        for type in [DicomUserIdentityType.username, .usernameAndPasscode, .kerberos, .saml, .jwt] {
            let request = DicomAssociationRequest(calledAETitle: "SCP", callingAETitle: "SCU",
                presentationContexts: [.init(id: 1, abstractSyntaxUID: DicomNetworkUID.verificationSOPClass,
                                            transferSyntaxes: [.explicitVRLittleEndian])], maximumPDULength: 65536,
                userIdentity: .init(type: type, primaryField: Data([0, 255, 1]), positiveResponseRequested: true))
            let transport = try StorageSCUTransport(inboundPDUs: [DicomPDUCodec.encode(.associationRequest(request)),
                                                                 DicomPDUCodec.encode(.releaseRequest)])
            _ = try service.handleAssociation(using: transport)
            let accept = try XCTUnwrap(transport.writtenAssociationAccepts.first)
            XCTAssertEqual(accept.maximumPDULength, 1024)
            XCTAssertEqual(accept.userIdentityServerResponse?.data, Data([1, 255, 0]))
        }
    }

    func test_identityProvider_rejectionPrecedesAssociationAccept() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DicomStorageSCPService(configuration: .init(aeTitle: "SCP"),
            storage: try DicomFileStorageCache(directoryURL: directory), userIdentityAuthenticator: A1IdentityProvider())
        let request = DicomAssociationRequest(calledAETitle: "SCP", callingAETitle: "SCU",
            presentationContexts: [.init(id: 1, abstractSyntaxUID: DicomNetworkUID.verificationSOPClass,
                                        transferSyntaxes: [.explicitVRLittleEndian])], userIdentity: .username("wrong"))
        let transport = try StorageSCUTransport(inboundPDUs: [DicomPDUCodec.encode(.associationRequest(request))])
        XCTAssertThrowsError(try service.handleAssociation(using: transport))
        XCTAssertEqual(transport.writtenPDUTypes, [.associationReject])
        XCTAssertEqual(transport.writtenAssociationRejects.first?.source, .serviceUser)
    }

    func test_identityProvider_missingIdentityRejectsAssociation() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DicomStorageSCPService(configuration: .init(aeTitle: "SCP"),
            storage: try DicomFileStorageCache(directoryURL: directory), userIdentityAuthenticator: A1IdentityProvider())
        let request = DicomAssociationRequest(calledAETitle: "SCP", callingAETitle: "SCU",
            presentationContexts: [.init(id: 1, abstractSyntaxUID: DicomNetworkUID.verificationSOPClass,
                                        transferSyntaxes: [.explicitVRLittleEndian])])
        let transport = try StorageSCUTransport(inboundPDUs: [DicomPDUCodec.encode(.associationRequest(request))])
        XCTAssertThrowsError(try service.handleAssociation(using: transport))
        XCTAssertEqual(transport.writtenPDUTypes, [.associationReject])
        XCTAssertEqual(transport.writtenAssociationRejects.first?.source, .serviceUser)
    }

    func test_identityProvider_oversizedResponseRejectsAssociation() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DicomStorageSCPService(configuration: .init(aeTitle: "SCP"),
            storage: try DicomFileStorageCache(directoryURL: directory),
            userIdentityAuthenticator: A1IdentityProvider(response: Data(repeating: 1, count: 65_536)))
        let request = DicomAssociationRequest(calledAETitle: "SCP", callingAETitle: "SCU",
            presentationContexts: [.init(id: 1, abstractSyntaxUID: DicomNetworkUID.verificationSOPClass,
                                        transferSyntaxes: [.explicitVRLittleEndian])],
            userIdentity: .init(type: .username, primaryField: Data([0, 255, 1]), positiveResponseRequested: true))
        let transport = try StorageSCUTransport(inboundPDUs: [DicomPDUCodec.encode(.associationRequest(request))])
        XCTAssertThrowsError(try service.handleAssociation(using: transport))
        XCTAssertEqual(transport.writtenPDUTypes, [.associationReject])
    }
}

private struct A1IdentityProvider: DicomUserIdentityAuthenticating {
    var response: Data?
    func authenticate(_ identity: DicomUserIdentity) throws -> DicomUserIdentityServerResponse? {
        guard identity.primaryField == Data([0, 255, 1]) else { throw CocoaError(.fileReadNoPermission) }
        return .init(data: response ?? Data(identity.primaryField.reversed()))
    }
}
