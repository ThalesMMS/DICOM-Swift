#if canImport(Network)
import Foundation
import XCTest
@testable import DicomCore

/// Isis issue #2514: a Label Map Segmentation moves between two DICOM-Swift peers. A Storage SCP keeps it, C-GET
/// brings it back voxel for voxel, and a DICOMDIR lists it as an image; a receiver without Label Map Segmentation
/// Storage refuses the presentation context and takes the BINARY copy.
final class DicomLabelmapSegmentationInteropTests: XCTestCase {
    func test_labelmap_roundTripsThroughAStorageSCPAndCGet() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = labelmap()
        for encoding in [DicomSegmentationPixelEncoding.native, .rleLossless] {
            let bytes = try part10(original, encoding: encoding)
            let storage = directory.appendingPathComponent(encoding.rawValue, isDirectory: true)
            // A retrieving peer serves what it stores, so its preference leads with that syntax.
            let server = try startServer(storageDirectory: storage, retrieving: storage, preferring: encoding.transferSyntax)
            do {
                let port = try XCTUnwrap(server.listeningPort)
                let stored = try await Task.detached {
                    try Self.client(port: port).store(request: DicomStoreRequest(part10Data: bytes))
                }.value
                XCTAssertEqual(stored.status, 0, encoding.rawValue)

                let identifier = DicomDataSet(elements: [
                    DicomDataElement(tag: 0x00080052, vr: .CS, value: .strings(["STUDY"])),
                    DicomDataElement(tag: 0x0020000D, vr: .UI, value: .strings(["2.25.2514.1"]))
                ])
                let retrieved = try await Task.detached {
                    try Self.client(port: port).get(identifier: identifier,
                                                    storageSOPClassUIDs: Array(DicomStorageSOPClassUIDs.commonClinicalStorage))
                }.value
                let instance = try XCTUnwrap(retrieved.retrievedInstances.first, encoding.rawValue)
                XCTAssertEqual(instance.sopClassUID, DicomSegmentationBuilder.labelMapSegmentationStorageSOPClassUID)
                XCTAssertEqual(instance.transferSyntax, encoding.transferSyntax, "stored and returned as sent")
                let returned = try DicomDataSetWriter.part10Data(fromEncodedDataSet: instance.data,
                    transferSyntax: instance.transferSyntax,
                    mediaStorageSOPClassUID: DicomSegmentationBuilder.labelMapSegmentationStorageSOPClassUID,
                    mediaStorageSOPInstanceUID: "2.25.2514.3")
                let parsed = try XCTUnwrap(DCMDecoder(data: returned).segmentation)
                XCTAssertEqual(parsed.frames.map(\.pixelData), original.frames.map(\.pixelData), encoding.rawValue)
                XCTAssertEqual(parsed.segments, original.segments)
            } catch {
                await server.stop()
                throw error
            }
            await server.stop()
        }
    }

    func test_receiverWithoutLabelMapStorage_refusesItAndStoresTheBinaryCopy() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = labelmap()
        let server = try startServer(storageDirectory: directory, retrieving: nil,
            storageSOPClassUIDs: DicomStorageSOPClassUIDs.commonClinicalStorage
                .subtracting([DicomSegmentationBuilder.labelMapSegmentationStorageSOPClassUID]))
        do {
            let port = try XCTUnwrap(server.listeningPort)
            let labelmapBytes = try part10(original, encoding: .rleLossless)
            do {
                _ = try await Task.detached {
                    try Self.client(port: port).store(request: DicomStoreRequest(part10Data: labelmapBytes))
                }.value
                XCTFail("A receiver without Label Map Segmentation Storage accepted one")
            } catch DicomNetworkError.presentationContextRejected(let abstractSyntax, let result, _) {
                XCTAssertEqual(abstractSyntax, DicomSegmentationBuilder.labelMapSegmentationStorageSOPClassUID)
                XCTAssertNotEqual(result, .transferSyntaxNotSupported)
            }

            let plan = try XCTUnwrap(DicomSegmentationBuilder.binaryPlan(forLabelmap: original))
            let binaryBytes = try DicomDataSetWriter.part10Data(
                from: DicomSegmentationBuilder.binaryDataSet(convertingLabelmap: original, plan: plan,
                    studyInstanceUID: "2.25.2514.1", seriesInstanceUID: "2.25.2514.4", sopInstanceUID: "2.25.2514.5"),
                options: DicomPart10WriterOptions(mediaStorageSOPClassUID: DicomSegmentationBuilder.segmentationStorageSOPClassUID,
                                                  mediaStorageSOPInstanceUID: "2.25.2514.5"))
            let stored = try await Task.detached {
                try Self.client(port: port).store(request: DicomStoreRequest(part10Data: binaryBytes))
            }.value
            XCTAssertEqual(stored.status, 0)
            let files = try storedFiles(in: directory)
            XCTAssertEqual(files.count, 1)
            let received = try XCTUnwrap(DCMDecoder(data: Data(contentsOf: files[0])).segmentation)
            XCTAssertEqual(received.segmentationType, .binary)
            XCTAssertEqual(received.segments.map(\.label), ["Liver", "Spleen"])
            XCTAssertEqual(received.frames.count, plan.frameCount)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    /// With `DICOM_LABELMAP_DICOMDIR_OUTPUT=<directory>` the file-set stays there for an independent reader.
    func test_labelmap_isAnImageRecordOfADICOMDIRThatReadsBack() async throws {
        let labelMap = DicomSegmentationBuilder.labelMapSegmentationStorageSOPClassUID
        XCTAssertEqual(DicomFileSet.recordProfile(forSOPClassUID: labelMap)?.recordType, "IMAGE")
        XCTAssertTrue(DicomFileSetExporter.supportedSOPClassUIDs.contains(labelMap))

        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("seg.dcm")
        let original = labelmap()
        try part10(original, encoding: .rleLossless, options: DicomSegmentationBuildOptions(
            patientName: "Doe^Jane", patientID: "PID2514", studyDate: "20260918", studyTime: "120000",
            studyID: "S2514", accessionNumber: "A2514")).write(to: source)
        let output = ProcessInfo.processInfo.environment["DICOM_LABELMAP_DICOMDIR_OUTPUT"].map { URL(fileURLWithPath: $0) }
        let destination = (output ?? directory).appendingPathComponent("LABELMAP-\(UUID().uuidString.prefix(8))")
        let built = try await DicomFileSet.build(files: [source], destination: destination, fileSetID: "LABELMAP")
        XCTAssertEqual(built.recordTypes, ["IMAGE": 1])
        XCTAssertTrue(try DicomFileSet.validate(directoryFileURL: built.directoryFileURL).isConsistent)

        let image = try XCTUnwrap(DicomDirectoryReader.read(from: built.directoryFileURL)
            .patients.first?.studies.first?.series.first?.images.first)
        XCTAssertEqual(image.recordType, "IMAGE")
        XCTAssertEqual(image.referencedSOPClassUID, labelMap)
        XCTAssertEqual(image.referencedTransferSyntaxUID, DicomTransferSyntax.rleLossless.rawValue)
        let file = image.referencedFileID.reduce(built.rootURL) { $0.appendingPathComponent($1) }
        let reread = try XCTUnwrap(DCMDecoder(data: Data(contentsOf: file)).segmentation)
        XCTAssertEqual(reread.frames.map(\.pixelData), original.frames.map(\.pixelData))
    }

    /// A context that carries identifiers only takes a native syntax, even when the storage preference and the
    /// proposal both lead with an encapsulated one; a storage context keeps the preference.
    func test_queryRetrieveContext_isNegotiatedInANativeSyntax() throws {
        let syntaxes: [DicomTransferSyntax] = [.rleLossless, .jpeg2000Lossless, .explicitVRLittleEndian]
        let labelMap = DicomSegmentationBuilder.labelMapSegmentationStorageSOPClassUID
        XCTAssertEqual(DicomStorageSOPClassUIDs.transferSyntaxes(syntaxes, forAbstractSyntax: labelMap), syntaxes)
        XCTAssertEqual(DicomStorageSOPClassUIDs.transferSyntaxes(syntaxes, forAbstractSyntax: DicomNetworkUID.studyRootQueryRetrieveGet),
                       [.explicitVRLittleEndian])
        XCTAssertEqual(DicomStorageSOPClassUIDs.transferSyntaxes([.jpeg2000], forAbstractSyntax: DicomNetworkUID.verificationSOPClass),
                       [.explicitVRLittleEndian, .implicitVRLittleEndian])

        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = DicomDIMSEServerConfiguration(aeTitle: "ISIS", port: 0)
        configuration.storage.transferSyntaxes = [.rleLossless, .explicitVRLittleEndian]
        let server = DicomDIMSEServer(configuration: configuration,
            storage: DicomStorageSCPService(configuration: configuration.storage,
                                            storage: try DicomFileStorageCache(directoryURL: directory)),
            retrieve: StoredFilesRetrieveProvider(directory: directory))
        let transport = try ProposalTransport(contexts: [
            .init(id: 1, abstractSyntaxUID: DicomNetworkUID.studyRootQueryRetrieveGet,
                  transferSyntaxes: [.rleLossless, .explicitVRLittleEndian]),
            .init(id: 3, abstractSyntaxUID: labelMap, transferSyntaxes: [.rleLossless, .explicitVRLittleEndian])
        ])
        try server.handleAssociation(using: transport)
        let accepted = try transport.acceptedContexts()
        XCTAssertEqual(accepted[1], DicomTransferSyntax.explicitVRLittleEndian.rawValue)
        XCTAssertEqual(accepted[3], DicomTransferSyntax.rleLossless.rawValue)
    }

    // MARK: - Peers

    /// Proposes `contexts`, then releases the association; keeps what the acceptor wrote.
    private final class ProposalTransport: DicomAssociationTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var input: [Data]
        private var output: [Data] = []

        init(contexts: [DicomPresentationContextRequest]) throws {
            let request = DicomAssociationRequest(calledAETitle: "ISIS", callingAETitle: "PEER",
                                                  presentationContexts: contexts, maximumPDULength: 16_384)
            input = [try DicomPDUCodec.encode(.associationRequest(request)), try DicomPDUCodec.encode(.releaseRequest)]
        }

        func readPDU() throws -> Data { lock.withLock { input.removeFirst() } }
        func writePDU(_ data: Data) { lock.withLock { output.append(data) } }

        /// The accepted transfer syntax of each presentation context, by context ID.
        func acceptedContexts() throws -> [UInt8: String] {
            for data in lock.withLock({ output }) {
                if case .associationAccept(let accept) = try DicomPDUCodec.decode(data) {
                    return Dictionary(uniqueKeysWithValues: accept.presentationContexts.compactMap { context in
                        context.result == .acceptance ? context.transferSyntaxUID.map { (context.id, $0) } : nil
                    })
                }
            }
            return [:]
        }
    }

    private func startServer(storageDirectory: URL, retrieving: URL?, preferring preferred: DicomTransferSyntax = .rleLossless,
                             storageSOPClassUIDs: Set<String> = DicomStorageSOPClassUIDs.commonClinicalStorage) throws -> DicomDIMSEServer {
        var configuration = DicomDIMSEServerConfiguration(aeTitle: "ISIS", port: 0)
        configuration.bindAddress = "127.0.0.1"
        configuration.storage.supportedStorageSOPClassUIDs = storageSOPClassUIDs
        configuration.storage.transferSyntaxes = [preferred] + [DicomTransferSyntax.rleLossless, .explicitVRLittleEndian,
                                                                .implicitVRLittleEndian].filter { $0 != preferred }
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let storage = DicomStorageSCPService(configuration: configuration.storage,
                                             storage: try DicomFileStorageCache(directoryURL: storageDirectory))
        let server = DicomDIMSEServer(configuration: configuration, storage: storage,
                                      retrieve: retrieving.map { StoredFilesRetrieveProvider(directory: $0) })
        try server.start()
        return server
    }

    private static func client(port: UInt16) -> DicomDIMSEServiceSCU {
        DicomDIMSEServiceSCU(configuration: .init(host: "127.0.0.1", port: port, calledAETitle: "ISIS",
                                                  callingAETitle: "PEER", timeout: 10,
                                                  transferSyntaxes: [.rleLossless, .explicitVRLittleEndian]))
    }

    /// Serves the files a Storage SCP kept, in the syntax each was stored in.
    private struct StoredFilesRetrieveProvider: DicomRetrieveProviding {
        let directory: URL

        func instances(for request: DicomRetrieveRequest) -> AsyncThrowingStream<DicomRetrievableInstance, Error> {
            AsyncThrowingStream { continuation in
                do {
                    for file in try DicomLabelmapSegmentationInteropTests.storedFiles(in: directory) {
                        let bytes = try Data(contentsOf: file)
                        guard let meta = try? DicomPart10FileMetaParser.parse(bytes),
                              let syntax = meta.transferSyntaxUID.flatMap(DicomTransferSyntax.init(rawValue:)) else { continue }
                        let dataSet = Data(bytes.dropFirst(meta.dataSetOffset))
                        continuation.yield(DicomRetrievableInstance(
                            sopClassUID: meta.mediaStorageSOPClassUID ?? "", sopInstanceUID: meta.mediaStorageSOPInstanceUID ?? "",
                            transferSyntaxes: [syntax]) { _ in dataSet })
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }

    // MARK: - Fixtures

    /// A 16 × 16 label map over three slices: background 0, liver 1 and spleen 2.
    private func labelmap() -> DicomSegmentation {
        let segments = [DicomSegment(number: 0, label: "Background", algorithmType: "AUTOMATIC", algorithmName: "Model"),
                        DicomSegment(number: 1, label: "Liver", algorithmType: "AUTOMATIC", algorithmName: "Model"),
                        DicomSegment(number: 2, label: "Spleen", algorithmType: "AUTOMATIC", algorithmName: "Model")]
        let frames = (0..<3).map { index in
            DicomSegmentationFrame(
                index: index, segmentNumber: 0,
                geometry: DicomFrameGeometry(frameIndex: index, functionalGroups: DicomFrameFunctionalGroups(
                    frameContent: nil,
                    pixelMeasures: DicomPixelMeasures(pixelSpacing: SIMD2<Double>(1, 1), sliceThickness: 1, spacingBetweenSlices: 1),
                    planePosition: DicomPlanePosition(imagePositionPatient: SIMD3<Double>(0, 0, Double(index))),
                    planeOrientation: DicomPlaneOrientation(row: SIMD3<Double>(1, 0, 0), column: SIMD3<Double>(0, 1, 0)),
                    derivationImage: nil))!,
                sourceImageReferences: [DicomSourceImageReference(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
                                                                  referencedSOPInstanceUID: "2.25.2514.2\(index)")],
                pixelData: .labelmap(.uint8((0..<256).map { pixel in
                    pixel % 16 < 8 ? (index < 2 ? 1 : 0) : (pixel / 16 < 4 + index ? 2 : 0)
                })))
        }
        return DicomSegmentation(sopInstanceUID: "2.25.2514.3", frameOfReferenceUID: "2.25.2514.9",
                                 segmentationType: .labelmap, rows: 16, columns: 16,
                                 referencedSeriesInstanceUIDs: ["2.25.2514.8"], segments: segments, frames: frames,
                                 pixelPaddingValue: 0)
    }

    private func part10(_ model: DicomSegmentation, encoding: DicomSegmentationPixelEncoding,
                        options: DicomSegmentationBuildOptions = DicomSegmentationBuildOptions()) throws -> Data {
        let encoded = try DicomSegmentationBuilder.encodedDataSet(from: model, studyInstanceUID: "2.25.2514.1",
            seriesInstanceUID: "2.25.2514.2", sopInstanceUID: "2.25.2514.3", encoding: encoding, options: options)
        return try DicomDataSetWriter.part10Data(from: encoded.dataSet, options: DicomPart10WriterOptions(
            transferSyntax: encoded.transferSyntax,
            mediaStorageSOPClassUID: DicomSegmentationBuilder.labelMapSegmentationStorageSOPClassUID,
            mediaStorageSOPInstanceUID: "2.25.2514.3"))
    }

    fileprivate static func storedFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: .skipsHiddenFiles) else { return [] }
        return try enumerator.compactMap { $0 as? URL }.filter {
            try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }.sorted { $0.path < $1.path }
    }

    private func storedFiles(in directory: URL) throws -> [URL] {
        try Self.storedFiles(in: directory)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("labelmap-interop-\(UUID().uuidString)", isDirectory: true)
    }
}
#endif
