//
//  DicomAnyStorageSOPClassNegotiationTests.swift
//  DicomCoreTests
//
//  Issue #3218: a Storage SCP that accepts any Storage SOP Class and the compressed syntaxes its
//  owner decodes, and the C-GET roster of every class the toolkit reads.
//
//  Thales Matheus Mendonça Santos — November 2026
//

import Foundation
@testable import DicomCore
import XCTest

/// Issue #3218: a Storage SCP that accepts any Storage SOP Class and the compressed syntaxes its owner decodes, and
/// the C-GET roster of every class the toolkit reads.
final class DicomAnyStorageSOPClassNegotiationTests: XCTestCase {
    private let ultrasoundMultiframe = "1.2.840.10008.5.1.4.1.1.3.1"
    private let digitalXRayForPresentation = "1.2.840.10008.5.1.4.1.1.1.1"
    private let encapsulatedPDF = "1.2.840.10008.5.1.4.1.1.104.1"

    func test_anyStorageSOPClass_acceptsUnlistedStorageClassesButNotOtherServices() {
        let request = associationRequest(contexts: [
            (ultrasoundMultiframe, [.explicitVRLittleEndian]),
            (digitalXRayForPresentation, [.explicitVRLittleEndian]),
            (encapsulatedPDF, [.explicitVRLittleEndian]),
            (DicomNetworkUID.modalityWorklistInformationModelFind, [.explicitVRLittleEndian]),
            (DicomNetworkUID.studyRootQueryRetrieveGet, [.explicitVRLittleEndian]),
            (DicomNetworkUID.verificationSOPClass, [.explicitVRLittleEndian])
        ])
        let supported: Set<String> = [DicomNetworkUID.verificationSOPClass,
                                      DicomStorageSOPClassUIDs.ctImageStorage]

        let open = DicomAssociationNegotiator.accept(request, supportedAbstractSyntaxUIDs: supported,
                                                     acceptsAnyStorageSOPClass: true,
                                                     preferredTransferSyntaxes: [.explicitVRLittleEndian])
        XCTAssertEqual(open.presentationContexts.map(\.result), [
            .acceptance, .acceptance, .acceptance, .abstractSyntaxNotSupported, .abstractSyntaxNotSupported, .acceptance
        ])

        let listed = DicomAssociationNegotiator.accept(request, supportedAbstractSyntaxUIDs: supported,
                                                       preferredTransferSyntaxes: [.explicitVRLittleEndian])
        XCTAssertEqual(listed.presentationContexts.map(\.result), [
            .abstractSyntaxNotSupported, .abstractSyntaxNotSupported, .abstractSyntaxNotSupported,
            .abstractSyntaxNotSupported, .abstractSyntaxNotSupported, .acceptance
        ])
    }

    func test_compressedSyntaxes_areAcceptedAndTheConfiguredPreferenceStaysFirst() {
        let preferred: [DicomTransferSyntax] = [.explicitVRLittleEndian, .implicitVRLittleEndian, .rleLossless,
                                                .jpegBaseline, .jpeg2000, .mpeg4AVCH264HighProfileLevel41]
        let request = associationRequest(contexts: [
            (ultrasoundMultiframe, [.jpegBaseline]),
            (ultrasoundMultiframe, [.rleLossless]),
            (ultrasoundMultiframe, [.jpegBaseline, .explicitVRLittleEndian]),
            (DicomVideo.videoEndoscopicImageStorageSOPClassUID, [.mpeg4AVCH264HighProfileLevel41]),
            (ultrasoundMultiframe, [.jpegXLLossless])
        ])

        let accept = DicomAssociationNegotiator.accept(request, supportedAbstractSyntaxUIDs: [],
                                                       acceptsAnyStorageSOPClass: true,
                                                       preferredTransferSyntaxes: preferred)

        XCTAssertEqual(accept.presentationContexts.map(\.result),
                       [.acceptance, .acceptance, .acceptance, .acceptance, .transferSyntaxNotSupported])
        XCTAssertEqual(accept.presentationContexts.map(\.transferSyntaxUID), [
            DicomTransferSyntax.jpegBaseline.rawValue,
            DicomTransferSyntax.rleLossless.rawValue,
            DicomTransferSyntax.explicitVRLittleEndian.rawValue,
            DicomTransferSyntax.mpeg4AVCH264HighProfileLevel41.rawValue,
            nil
        ])
    }

    func test_anyStorageSOPClass_rolesFollowEachSideSeparately() {
        let roles = [DicomSCPSCURoleSelection.returnedStorage(sopClassUID: ultrasoundMultiframe)]
        var request = associationRequest(contexts: [(ultrasoundMultiframe, [.explicitVRLittleEndian])])
        request.roleSelections = roles

        let receiving = DicomAssociationNegotiator.accept(request, supportedAbstractSyntaxUIDs: [],
                                                          acceptsAnyStorageSOPClass: true,
                                                          preferredTransferSyntaxes: [.explicitVRLittleEndian])
        XCTAssertEqual(receiving.roleSelections.map(\.scpRole), [false],
                       "accepting stores does not make this side a sender of C-GET sub-operations")

        let sending = DicomAssociationNegotiator.accept(request, supportedAbstractSyntaxUIDs: [],
                                                        acceptsAnyStorageSOPClass: true,
                                                        preferredTransferSyntaxes: [.explicitVRLittleEndian],
                                                        sendsAnyStorageSOPClass: true)
        XCTAssertEqual(sending.roleSelections.map(\.scpRole), [true])
    }

    func test_storageSCP_storesAnUnlistedClassInJPEGBaselineAsReceived() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("any-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(aeTitle: "LISTENER", acceptsAnyStorageSOPClass: true,
                                                        transferSyntaxes: [.explicitVRLittleEndian, .jpegBaseline],
                                                        enableStorageCommitment: false),
            storage: try DicomFileStorageCache(directoryURL: directory))
        let sopInstanceUID = "2.25.32180001"
        let dataSetData = try encapsulatedDataSetData(sopInstanceUID: sopInstanceUID)
        let command = DicomDIMSECommandSet(affectedSOPClassUID: ultrasoundMultiframe,
                                           commandField: DicomDIMSECommandField.cStoreRQ, messageID: 1,
                                           commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet, priority: 0,
                                           affectedSOPInstanceUID: sopInstanceUID)
        let transport = InboundPDUTransport(inbound: [
            try DicomPDUCodec.encode(.associationRequest(associationRequest(contexts: [
                (ultrasoundMultiframe, [.jpegBaseline])
            ]))),
            try DicomPDUCodec.encode(.pData([.init(presentationContextID: 1, isCommand: true, isLastFragment: true,
                                                   data: try command.encoded())])),
            try DicomPDUCodec.encode(.pData([.init(presentationContextID: 1, isCommand: false, isLastFragment: true,
                                                   data: dataSetData)])),
            try DicomPDUCodec.encode(.releaseRequest)
        ])

        let result = try service.handleAssociation(using: transport)

        XCTAssertEqual(transport.storeStatuses, [0])
        let stored = try XCTUnwrap(result.storedInstances.first)
        XCTAssertEqual(stored.sopClassUID, ultrasoundMultiframe)
        XCTAssertEqual(stored.transferSyntax, .jpegBaseline)
        let file = try DicomStoreRequest(part10Data: Data(contentsOf: stored.fileURL))
        XCTAssertEqual(file.transferSyntax, .jpegBaseline)
        XCTAssertEqual(file.dataSetData, dataSetData, "the object is stored as received, not transcoded")
    }

    func test_readableStorage_namesEveryClassTheViewerReadsWithinOneAssociation() {
        let roster = DicomStorageSOPClassUIDs.readableStorage
        // The classes a listener probe found refused before issue #3218.
        let previouslyRefused: Set<String> = [
            "1.2.840.10008.5.1.4.1.1.1.1", "1.2.840.10008.5.1.4.1.1.1.1.1", "1.2.840.10008.5.1.4.1.1.1.2",
            "1.2.840.10008.5.1.4.1.1.1.2.1", "1.2.840.10008.5.1.4.1.1.1.3", "1.2.840.10008.5.1.4.1.1.12.1",
            "1.2.840.10008.5.1.4.1.1.12.1.1", "1.2.840.10008.5.1.4.1.1.12.2", "1.2.840.10008.5.1.4.1.1.3.1",
            "1.2.840.10008.5.1.4.1.1.6.2", "1.2.840.10008.5.1.4.1.1.20", "1.2.840.10008.5.1.4.1.1.13.1.3",
            "1.2.840.10008.5.1.4.1.1.2.2", "1.2.840.10008.5.1.4.1.1.4.4", "1.2.840.10008.5.1.4.1.1.128.1",
            "1.2.840.10008.5.1.4.1.1.130", "1.2.840.10008.5.1.4.1.1.7.1", "1.2.840.10008.5.1.4.1.1.7.2",
            "1.2.840.10008.5.1.4.1.1.7.3", "1.2.840.10008.5.1.4.1.1.7.4", "1.2.840.10008.5.1.4.1.1.77.1.1",
            "1.2.840.10008.5.1.4.1.1.77.1.4", "1.2.840.10008.5.1.4.1.1.77.1.5.1", "1.2.840.10008.5.1.4.1.1.77.1.5.2",
            "1.2.840.10008.5.1.4.1.1.77.1.5.4", "1.2.840.10008.5.1.4.1.1.77.1.1.1", "1.2.840.10008.5.1.4.1.1.77.1.2.1",
            "1.2.840.10008.5.1.4.1.1.77.1.4.1", "1.2.840.10008.5.1.4.1.1.77.1.6", "1.2.840.10008.5.1.4.1.1.104.1",
            "1.2.840.10008.5.1.4.1.1.104.2", "1.2.840.10008.5.1.4.1.1.104.3", "1.2.840.10008.5.1.4.1.1.104.4",
            "1.2.840.10008.5.1.4.1.1.104.5", "1.2.840.10008.5.1.4.1.1.66.3"
        ]
        XCTAssertEqual(previouslyRefused.count, 35)
        XCTAssertEqual(previouslyRefused.subtracting(roster), [])
        XCTAssertTrue(roster.isSuperset(of: DicomStorageSOPClassUIDs.commonClinicalStorage))
        XCTAssertTrue(roster.isSuperset(of: DicomQualifiedProfileCatalog.profiles.map(\.sopClassUID)))
        XCTAssertTrue(roster.allSatisfy(DicomStorageSOPClassUIDs.isStorageSOPClass))
        XCTAssertLessThanOrEqual(roster.count + DicomQueryRetrieveModelPreference.get.count, 128,
                                 "a C-GET proposes every class plus its models in one association")
    }

    /// A C-GET proposes each image class twice, native then encapsulated, so a peer that picks one syntax per
    /// context can return both forms as stored; the identifier-only models stay native, and so do role items.
    func test_cGetContexts_proposeImageClassesAgainInTheEncapsulatedSyntaxes() throws {
        let syntaxes: [DicomTransferSyntax] = [.explicitVRLittleEndian, .implicitVRLittleEndian, .jpegBaseline,
                                               .jpeg2000Lossless]
        let service = DicomDIMSEServiceSCU(configuration: .init(host: "127.0.0.1", port: 104, calledAETitle: "PACS",
                                                                callingAETitle: "VIEWER", transferSyntaxes: syntaxes))
        let models = DicomQueryRetrieveModelPreference.get
        let roster = DicomStorageSOPClassUIDs.readableStorage.sorted()
        let images = DicomStorageSOPClassUIDs.readableImageStorage

        let contexts = service.presentationContexts(for: models + roster, transferSyntaxes: syntaxes,
                                                    encapsulatedContextSOPClassUIDs: images)

        XCTAssertEqual(contexts.count, models.count + roster.count + images.count)
        XCTAssertEqual(contexts.count, 122, "the count the conformance statement gives")
        XCTAssertEqual(contexts.map(\.id), contexts.indices.map { UInt8($0 * 2 + 1) })
        XCTAssertEqual(contexts.filter { $0.abstractSyntaxUID == ultrasoundMultiframe }.map(\.transferSyntaxUIDs), [
            [DicomTransferSyntax.explicitVRLittleEndian.rawValue, DicomTransferSyntax.implicitVRLittleEndian.rawValue],
            [DicomTransferSyntax.jpegBaseline.rawValue, DicomTransferSyntax.jpeg2000Lossless.rawValue]
        ])
        XCTAssertEqual(contexts.filter { $0.abstractSyntaxUID == encapsulatedPDF }.map(\.transferSyntaxUIDs),
                       [syntaxes.map(\.rawValue)])
        XCTAssertEqual(Set(contexts.filter { models.contains($0.abstractSyntaxUID) }.map(\.transferSyntaxUIDs)),
                       [[DicomTransferSyntax.explicitVRLittleEndian.rawValue,
                         DicomTransferSyntax.implicitVRLittleEndian.rawValue]])
        XCTAssertTrue(images.contains(ultrasoundMultiframe))
        XCTAssertTrue(images.contains(digitalXRayForPresentation))
        XCTAssertFalse(images.contains(encapsulatedPDF))
    }

    private func associationRequest(
        contexts: [(abstractSyntaxUID: String, syntaxes: [DicomTransferSyntax])]
    ) -> DicomAssociationRequest {
        DicomAssociationRequest(calledAETitle: "LISTENER", callingAETitle: "MODALITY",
                                presentationContexts: contexts.enumerated().map { index, context in
                                    .init(id: UInt8(index * 2 + 1), abstractSyntaxUID: context.abstractSyntaxUID,
                                          transferSyntaxes: context.syntaxes)
                                })
    }

    /// An Ultrasound Multi-frame header in Explicit VR Little Endian followed by one encapsulated JPEG fragment.
    private func encapsulatedDataSetData(sopInstanceUID: String) throws -> Data {
        let header = DicomDataSet(elements: [
            .init(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings([ultrasoundMultiframe])),
            .init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([sopInstanceUID])),
            .init(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.32180002"])),
            .init(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.32180003"]))
        ])
        var data = try DicomDataSetWriter.dataSetData(from: header, transferSyntax: .explicitVRLittleEndian)
        func tag(_ group: UInt16, _ element: UInt16) { data.append(littleEndian(group)); data.append(littleEndian(element)) }
        tag(0x7FE0, 0x0010)
        data.append(contentsOf: Array("OB".utf8) + [0, 0])
        data.append(littleEndian(UInt32.max))
        tag(0xFFFE, 0xE000)
        data.append(littleEndian(UInt32(0)))
        tag(0xFFFE, 0xE000)
        data.append(littleEndian(UInt32(4)))
        data.append(contentsOf: [0xFF, 0xD8, 0xFF, 0xD9])
        tag(0xFFFE, 0xE0DD)
        data.append(littleEndian(UInt32(0)))
        return data
    }

    private func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

private final class InboundPDUTransport: DicomAssociationTransport {
    private var inbound: [Data]
    private(set) var storeStatuses: [UInt16] = []

    init(inbound: [Data]) { self.inbound = inbound }

    func writePDU(_ data: Data) throws {
        guard case .pData(let pdvs) = try DicomPDUCodec.decode(data) else { return }
        for pdv in pdvs where pdv.isCommand {
            let command = try DicomDIMSECommandSet.decode(pdv.data)
            if command.commandField == DicomDIMSECommandField.cStoreRSP { storeStatuses.append(command.status ?? 0xFFFF) }
        }
    }

    func readPDU() throws -> Data {
        guard !inbound.isEmpty else { throw DicomNetworkError.networkTimeout("test Storage SCP read") }
        return inbound.removeFirst()
    }
}
