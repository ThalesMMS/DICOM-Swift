import XCTest
@testable import DicomCore

private struct RepresentationNoTranscode: DicomStoreTranscoding, DicomWebServerTranscoding {
    var transferSyntaxUIDs: [String] { [DicomTransferSyntax.rleLossless.rawValue] }
    func canTranscode(from: String, to: String) -> Bool { true }
    func qualifiedTransferSyntaxes(for file: URL) async throws -> [DicomTransferSyntax] { [.rleLossless] }
    func transcode(_ file: URL, to syntax: DicomTransferSyntax) async throws -> Data {
        XCTFail("Stored representation must prevent rescue transcode")
        throw DicomRepresentationRefusal.generationFailed
    }
    func transcode(_ instance: DicomWebStoredInstance, to transferSyntaxUID: String) async throws -> Data {
        XCTFail("Stored representation must prevent web transcode")
        throw DicomRepresentationRefusal.generationFailed
    }
}

private struct RepresentationCancelledQualification: DicomStoreTranscoding {
    func qualifiedTransferSyntaxes(for file: URL) async throws -> [DicomTransferSyntax] { throw CancellationError() }
    func transcode(_ file: URL, to syntax: DicomTransferSyntax) async throws -> Data {
        XCTFail("Cancelled qualification must not transcode")
        throw CancellationError()
    }
}

final class DicomRepresentationServingTests: XCTestCase {
    func test_representationBatch_cancellationPreservesFailureAndStopsLaterFiles() async throws {
        let (store, _, bytes) = try await RepresentationFixture.archive()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dcm")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        for duringQualification in [true, false] {
            var sends = 0
            let transcoder: (any DicomStoreTranscoding)? = duringQualification ? RepresentationCancelledQualification() : nil
            let outcomes = await DicomDIMSEServiceSCU.store(batch: [file, file], policy: .losslessEquivalents,
                transcoder: transcoder, resolver: store) { _ in
                    sends += 1
                    throw CancellationError()
                }
            XCTAssertEqual(sends, duringQualification ? 0 : 1)
            XCTAssertEqual(outcomes.count, 1)
            let outcome = try XCTUnwrap(outcomes.first?.outcome)
            guard case .failure(let error) = outcome.result else { return XCTFail("Expected cancellation outcome") }
            XCTAssertTrue(error is CancellationError)
            XCTAssertEqual(outcome.diagnostics.last, error.localizedDescription)
        }
    }

    func test_fileHash_matchesDataHashAcrossChunkBoundaries() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        for length in [0, 1, 2 * 1_024 * 1_024 + 17] {
            var bytes = Data(repeating: 42, count: length)
            if length > 1_024 * 1_024 { bytes[1_024 * 1_024] = 91 }
            try bytes.write(to: file)
            XCTAssertEqual(try DicomArchiveRepresentation.hash(fileAt: file), DicomArchiveRepresentation.hash(bytes))
        }
    }

    private func archive() async throws -> (DicomInMemoryRepresentationStore, DicomRepresentationSet, Data, Data) {
        let (store, set, bytes) = try await RepresentationFixture.archive()
        let output = try await DicomRepresentationGenerator(store: store, creatorIdentifier: "test",
            configurationHash: "config", toolkitVersion: "test").generate(set: set, to: .rleLossless, derivativeLimit: 3)
        let current = await store.representations(for: RepresentationFixture.uid)
        return (store, try XCTUnwrap(current), bytes, output.bytes)
    }

    func test_scuScriptedSend_prefersStoredAlternateWithoutTranscode() async throws {
        let (store, _, bytes, alternate) = try await archive()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dcm")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var sends = 0
        let result = await DicomDIMSEServiceSCU.store(batch: [file], policy: .losslessEquivalents,
            transcoder: RepresentationNoTranscode(), resolver: store) { request in
                sends += 1
                if sends == 1 {
                    XCTAssertTrue(request.proposedTransferSyntaxes.contains(.rleLossless))
                    throw DicomNetworkError.transferSyntaxMismatch(expected: request.transferSyntax.rawValue,
                                                                   actual: DicomTransferSyntax.rleLossless.rawValue)
                }
                XCTAssertEqual(request.transferSyntax, .rleLossless)
                XCTAssertEqual(request.dataSetData, try DicomStoreRequest(part10Data: alternate).dataSetData)
                return .init(status: 0)
            }
        XCTAssertEqual(sends, 2)
        XCTAssertEqual(result.first?.decision?.reasonCodes, [.storedEquivalent])
        XCTAssertTrue(result.first?.outcome.accepted == true)
        XCTAssertEqual(result.first?.outcome.attempts.count, 2)
    }

    func test_retrievableInstance_advertisesAndServesStoredEquivalent() async throws {
        let (store, set, bytes, alternate) = try await archive()
        let sopClass = try DicomStoreRequest(part10Data: bytes).sopClassUID
        let instance = DicomRetrievableInstance(sopClassUID: sopClass, representations: set, store: store)
        XCTAssertEqual(Set(instance.transferSyntaxes), Set([.explicitVRLittleEndian, .rleLossless]))
        let payload = try await instance.byteSource(.rleLossless)
        XCTAssertEqual(payload, try DicomStoreRequest(part10Data: alternate).dataSetData)
        do { _ = try await instance.byteSource(.jpegBaseline); XCTFail("Unaccepted syntax") } catch {}
        try await store.invalidate(sourceSOPInstanceUID: RepresentationFixture.uid, reason: .stale)
        do { _ = try await instance.byteSource(.rleLossless); XCTFail("Stale bytes") } catch {}
    }

    func test_webRetrieve_prefersStoredAlternateAndLegacyPathUnchanged() async throws {
        let (archive, _, bytes, alternate) = try await archive()
        let storage = DicomWebInMemoryStore()
        try storage.add(part10Data: bytes)
        let url = URL(string: "https://example.invalid/dicom-web/studies/2.25.23551/series/2.25.23552/instances/2.25.2355")!
        let request = DicomWebHTTPRequest(method: .get, url: url,
            headers: ["Accept": "multipart/related; type=\"application/dicom\"; transfer-syntax=1.2.840.10008.1.2.5"])
        let server = DicomWebServer(store: storage, transcoding: RepresentationNoTranscode(), representationResolver: archive)
        let response = try await server.send(request)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNotNil(response.body.range(of: alternate))
        let legacy = try await DicomWebServer(store: storage).send(request)
        XCTAssertEqual(legacy.statusCode, 406)
        var originalRequest = request
        originalRequest.headers["Accept"] = "multipart/related; type=\"application/dicom\"; transfer-syntax=1.2.840.10008.1.2.1"
        let original = try await DicomWebServer(store: storage).send(originalRequest)
        XCTAssertEqual(original.statusCode, 200)
        XCTAssertNotNil(original.body.range(of: bytes))
    }

    func test_webRetrieve_storedRepresentationsHonorAcceptQualityAndOrder() async throws {
        let (archive, _, bytes, alternate) = try await archive()
        let storage = DicomWebInMemoryStore()
        try storage.add(part10Data: bytes)
        let server = DicomWebServer(store: storage, representationResolver: archive)
        let url = URL(string: "https://example.invalid/dicom-web/studies/2.25.23551/series/2.25.23552/instances/2.25.2355")!
        let originalType = "multipart/related; type=\"application/dicom\"; transfer-syntax=1.2.840.10008.1.2.1"
        let alternateType = "multipart/related; type=\"application/dicom\"; transfer-syntax=1.2.840.10008.1.2.5"
        for (accept, expected) in [
            (originalType + "; q=0.5, " + alternateType + "; q=1", alternate),
            (alternateType + "; q=0.5, " + originalType + "; q=1", bytes),
            (alternateType + ", " + originalType, alternate),
            (originalType + ", " + alternateType, bytes),
            (alternateType + "; q=0, " + originalType, bytes),
            ("multipart/related; type=\"application/dicom\"; transfer-syntax=*", bytes)
        ] {
            let response = try await server.send(.init(method: .get, url: url, headers: ["Accept": accept]))
            XCTAssertEqual(response.statusCode, 200, accept)
            XCTAssertNotNil(response.body.range(of: expected), accept)
        }
    }

    func test_webRetrieve_preferredStoredRepresentationRequiresSourceAuthorization() async throws {
        let (archive, _, bytes, alternate) = try await archive()
        let storage = DicomWebInMemoryStore()
        try storage.add(part10Data: bytes)
        let policy = AuthorizationTestPolicy()
        let server = DicomWebServer(store: storage, representationResolver: archive,
            principals: AuthorizationTestPrincipals(), authorizer: policy)
        let url = URL(string: "https://example.invalid/dicom-web/studies/2.25.23551/series/2.25.23552/instances/2.25.2355")!
        let originalType = "multipart/related; type=\"application/dicom\"; transfer-syntax=1.2.840.10008.1.2.1"
        let alternateType = "multipart/related; type=\"application/dicom\"; transfer-syntax=1.2.840.10008.1.2.5"
        let request = DicomWebHTTPRequest(method: .get, url: url,
            headers: ["Accept": alternateType + "; q=1, " + originalType + "; q=0.5"])
        let allowed = try await server.send(request)
        XCTAssertEqual(allowed.statusCode, 200)
        XCTAssertNotNil(allowed.body.range(of: alternate))
        await policy.deny(RepresentationFixture.uid)
        let denied = try await server.send(request)
        XCTAssertEqual(denied.statusCode, 403)
        XCTAssertNil(denied.body.range(of: alternate))
        let original = try await server.send(.init(method: .get, url: url, headers: ["Accept": originalType]))
        XCTAssertEqual(original.statusCode, 403)
        XCTAssertNil(original.body.range(of: bytes))
    }
}

private final class RepresentationScriptedTransport: DicomAssociationTransport {
    var proposed: [DicomTransferSyntax] = []
    var payload = Data()
    private var responses: [Data] = []
    private var commandBytes = Data()
    private var command: DicomDIMSECommandSet?
    func writePDU(_ bytes: Data) throws {
        switch try DicomPDUCodec.decode(bytes) {
        case .associationRequest(let request):
            proposed = request.presentationContexts.flatMap(\.transferSyntaxUIDs).compactMap(DicomTransferSyntax.init(rawValue:))
            let accept = DicomAssociationNegotiator.accept(request,
                supportedAbstractSyntaxUIDs: Set(request.presentationContexts.map(\.abstractSyntaxUID)),
                preferredTransferSyntaxes: [.rleLossless])
            responses.append(try DicomPDUCodec.encode(.associationAccept(accept)))
        case .pData(let pdvs):
            for pdv in pdvs {
                if pdv.isCommand {
                    commandBytes.append(pdv.data)
                    if pdv.isLastFragment { command = try DicomDIMSECommandSet.decode(commandBytes) }
                } else {
                    payload.append(pdv.data)
                    if pdv.isLastFragment {
                        let response = DicomDIMSECommandSet(commandField: DicomDIMSECommandField.cStoreRSP,
                            messageIDBeingRespondedTo: command?.messageID, status: 0)
                        responses.append(try DicomPDUCodec.encode(.pData([.init(presentationContextID: pdv.presentationContextID,
                            isCommand: true, isLastFragment: true, data: response.encoded())])))
                    }
                }
            }
        case .releaseRequest: responses.append(try DicomPDUCodec.encode(.releaseResponse))
        default: break
        }
    }
    func readPDU() throws -> Data {
        guard !responses.isEmpty else { throw DicomNetworkError.networkUnavailable("Empty script") }
        return responses.removeFirst()
    }
}

extension DicomRepresentationServingTests {
    func test_scuNegotiation_scriptedPDUsIncludeAlternateAndCarryItsExactDataset() async throws {
        let (store, _, bytes, alternate) = try await archive()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dcm")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let service = DicomDIMSEServiceSCU(configuration: .init(host: "scripted", port: 1,
            calledAETitle: "SCP", callingAETitle: "SCU"))
        var peers: [RepresentationScriptedTransport] = []
        let outcomes = await DicomDIMSEServiceSCU.store(batch: [file], policy: .losslessEquivalents,
            transcoder: RepresentationNoTranscode(), resolver: store) { request in
                let peer = RepresentationScriptedTransport()
                peers.append(peer)
                return try service.store(request: request, using: peer)
            }
        XCTAssertEqual(peers.count, 2)
        XCTAssertTrue(peers.first?.proposed.contains(.rleLossless) == true)
        XCTAssertEqual(peers.last?.payload, try DicomStoreRequest(part10Data: alternate).dataSetData)
        XCTAssertEqual(outcomes.first?.decision?.reasonCodes, [.storedEquivalent])
        XCTAssertTrue(outcomes.first?.outcome.accepted == true)
    }
}
