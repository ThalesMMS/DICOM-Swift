import XCTest
@testable import DicomCore

private actor RepresentationExecutionGate {
    var calls = 0
    var cancelled = false
    var opened = false
    func execute(_ plan: DicomTranscodeExecutionPlan, _ bytes: Data, _ env: [String: String]) async throws -> Data {
        calls += 1
        do {
            while !opened { try await Task.sleep(nanoseconds: 1_000_000) }
            return try await DicomTranscoder().execute(plan, source: bytes, environment: env).data!
        } catch { cancelled = true; throw error }
    }
    func open() { opened = true }
}

final class DicomRepresentationGeneratorTests: XCTestCase {
    func test_losslessEquivalent_bigEndian16Bit_refusesUnavailableGeneration() async throws {
        var dataSet = RepresentationFixture.dataSet()
        dataSet.set(.init(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([2])))
        dataSet.set(.init(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([2])))
        dataSet.set(.init(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([16])))
        dataSet.set(.init(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([16])))
        dataSet.set(.init(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([15])))
        dataSet.set(.init(tag: DicomTag.pixelData.rawValue, vr: .OW,
            value: .bytes(Data([0x02, 0x01, 0x34, 0x12, 0xCD, 0xAB, 0xFE, 0x00]))))
        let bytes = try DicomDataSetWriter.part10Data(from: dataSet,
            options: .init(transferSyntax: .explicitVRLittleEndian))
        let store = DicomInMemoryRepresentationStore()
        let original = try await store.store(bytes: bytes,
            representation: RepresentationFixture.descriptor(bytes), derivativeLimit: 1)
        let set = try DicomRepresentationSet([original])
        XCTAssertEqual(try DCMDecoder(data: bytes).getPixels16(), [0x0102, 0x1234, 0xABCD, 0x00FE])
        let transcoder = DicomTranscoder()
        let preflight = try transcoder.preflight(bytes, to: .explicitVRBigEndian, intent: .reversible,
            environment: [:], verifyDecodedPixels: false)
        XCTAssertFalse(preflight.canExecute)
        XCTAssertTrue(preflight.unavailableReason?.contains("byte-order conversion is not implemented") == true)
        XCTAssertThrowsError(try transcoder.plan(bytes, to: .explicitVRBigEndian, intent: .reversible,
            environment: [:])) { error in
            guard case .routeUnsupported = error as? DicomTranscoder.TranscodeError else {
                return XCTFail("Expected unavailable route, got \(error)")
            }
        }
        let candidate = RepresentationFixture.candidate(original, syntax: .explicitVRBigEndian,
            availability: .generatable)
        XCTAssertThrowsError(try DicomRepresentationSelector.select(set: .init([original, candidate]),
            peer: .init(acceptedTransferSyntaxes: [.explicitVRBigEndian]), policy: .losslessEquivalents,
            cost: .init(generationAllowed: true, estimate: { _ in .init(codecAvailable: preflight.canExecute) }))) { error in
            guard case .noEligibleRepresentation(let rejected) = error as? DicomRepresentationRefusal else {
                return XCTFail("Expected no eligible representation, got \(error)")
            }
            XCTAssertTrue(rejected.contains { $0.reasonCodes.contains(.codecUnavailable) })
        }
        let generator = DicomRepresentationGenerator(store: store, creatorIdentifier: "test",
            configurationHash: "config", toolkitVersion: "test", environment: [:])
        await generator.setExecutor { _, _, _ in
            XCTFail("Unavailable generation must not execute")
            throw DicomRepresentationRefusal.generationFailed
        }
        do {
            _ = try await generator.generate(set: set, to: .explicitVRBigEndian,
                policy: .losslessEquivalents, derivativeLimit: 1)
            XCTFail("Expected unavailable Big Endian generation")
        } catch { XCTAssertEqual(error as? DicomRepresentationRefusal, .codecUnavailable) }
        let final = await store.representations(for: original.sourceSOPInstanceUID)
        XCTAssertEqual(final?.representations.count, 1)
    }

    private func generator(_ store: any DicomRepresentationStoring) -> DicomRepresentationGenerator {
        .init(store: store, creatorIdentifier: "test", configurationHash: "config", toolkitVersion: "test")
    }

    func test_losslessEquivalent_sameUIDNoDerivationAndInheritedHistory() async throws {
        for history in [false, true] {
            let (store, set, _) = try await RepresentationFixture.archive(history: history)
            let output = try await generator(store).generate(set: set, to: .rleLossless, derivativeLimit: 3)
            XCTAssertEqual(output.descriptor.kind, .losslessEquivalent)
            XCTAssertEqual(output.descriptor.representationSOPInstanceUID, set.original.sourceSOPInstanceUID)
            XCTAssertEqual(output.descriptor.quality, set.original.quality)
            let dataSet = try DCMDecoder(data: output.bytes).dataSet
            XCTAssertEqual(dataSet.strings(for: .imageType), ["ORIGINAL", "PRIMARY"])
            XCTAssertNil(dataSet.element(for: .sourceImageSequence))
            XCTAssertNil(dataSet.element(for: 0x04000561))
            XCTAssertEqual(output.descriptor.contentSHA256, DicomArchiveRepresentation.hash(output.bytes))
        }
    }

    func test_lossyDerived_newIdentityAndAppendedHistory() async throws {
        let (store, set, _) = try await RepresentationFixture.archive(history: true)
        let output = try await generator(store).generate(set: set, to: .jpegBaseline,
            parameters: .init(intent: .irreversible(quality: 0.8)),
            policy: .lossyDerivedAllowed(authorization: "test-approval"), derivativeLimit: 2)
        let dataSet = try DCMDecoder(data: output.bytes).dataSet
        XCTAssertNotEqual(output.descriptor.representationSOPInstanceUID, set.original.sourceSOPInstanceUID)
        XCTAssertEqual(dataSet.string(for: 0x00282110), "01")
        XCTAssertEqual(dataSet.strings(for: 0x00282114).count, 2)
        XCTAssertEqual(dataSet.strings(for: 0x00282112).count, 2)
        XCTAssertTrue(dataSet.string(for: .imageType)?.hasPrefix("DERIVED") == true)
        XCTAssertNotNil(dataSet.element(for: 0x00082111))
        XCTAssertEqual(dataSet.element(for: .sourceImageSequence)?.sequenceItems.last?.dataSet.string(for: .referencedSOPInstanceUID),
                       set.original.sourceSOPInstanceUID)
    }

    func test_limitAndExecutionFailure_areTyped() async throws {
        let (store, set, _) = try await RepresentationFixture.archive()
        let generator = generator(store)
        do { _ = try await generator.generate(set: set, to: .rleLossless, derivativeLimit: 0); XCTFail("Limit") }
        catch { XCTAssertEqual(error as? DicomRepresentationRefusal, .limitReached) }
        await generator.setExecutor { _, _, _ in throw CocoaError(.fileReadCorruptFile) }
        do { _ = try await generator.generate(set: set, to: .rleLossless, derivativeLimit: 2); XCTFail("Failure") }
        catch { XCTAssertEqual(error as? DicomRepresentationRefusal, .generationFailed) }
    }

    func test_concurrentWaiters_shareExecutionAndOneCancellationDoesNotCancelOthers() async throws {
        let (store, set, _) = try await RepresentationFixture.archive()
        let generator = generator(store)
        let gate = RepresentationExecutionGate()
        await generator.setExecutor { try await gate.execute($0, $1, $2) }
        let tasks = (0..<8).map { _ in Task { try await generator.generate(set: set, to: .rleLossless, derivativeLimit: 1) } }
        while await gate.calls == 0 { await Task.yield() }
        // Let every waiter register before releasing the executable route.
        try await Task.sleep(nanoseconds: 30_000_000)
        tasks[0].cancel()
        do { _ = try await tasks[0].value; XCTFail("Cancelled waiter") }
        catch { XCTAssertEqual(error as? DicomRepresentationRefusal, .cancelled) }
        await gate.open()
        var hashes: Set<String> = []
        for task in tasks.dropFirst() { hashes.insert(try await task.value.descriptor.contentSHA256) }
        XCTAssertEqual(hashes.count, 1)
        let calls = await gate.calls
        let cancelled = await gate.cancelled
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(cancelled)
        let final = await store.representations(for: RepresentationFixture.uid)
        XCTAssertEqual(final?.representations.count, 2)
    }

    func test_lastWaiterCancellation_cancelsGenerationAndDoesNotPublish() async throws {
        let (store, set, _) = try await RepresentationFixture.archive()
        let generator = generator(store)
        let gate = RepresentationExecutionGate()
        await generator.setExecutor { try await gate.execute($0, $1, $2) }
        let task = Task { try await generator.generate(set: set, to: .rleLossless, derivativeLimit: 1) }
        while await gate.calls == 0 { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled") }
        catch { XCTAssertEqual(error as? DicomRepresentationRefusal, .cancelled) }
        for _ in 0..<100 where await !gate.cancelled { try await Task.sleep(nanoseconds: 1_000_000) }
        let cancelled = await gate.cancelled
        XCTAssertTrue(cancelled)
        let final = await store.representations(for: RepresentationFixture.uid)
        XCTAssertEqual(final?.representations.count, 1)
    }

    func test_invalidationDuringGeneration_refusesPublication() async throws {
        let (store, set, _) = try await RepresentationFixture.archive()
        let generator = generator(store)
        let gate = RepresentationExecutionGate()
        await generator.setExecutor { try await gate.execute($0, $1, $2) }
        let task = Task { try await generator.generate(set: set, to: .rleLossless, derivativeLimit: 1) }
        while await gate.calls == 0 { await Task.yield() }
        try await store.invalidate(sourceSOPInstanceUID: RepresentationFixture.uid, reason: .stale)
        await gate.open()
        do { _ = try await task.value; XCTFail("Invalidated generation") }
        catch { XCTAssertEqual(error as? DicomRepresentationRefusal, .sourceChanged) }
    }
}

private struct ChangedSourceRepresentationStore: DicomRepresentationStoring {
    let base: DicomInMemoryRepresentationStore
    func representations(for uid: String) async throws -> DicomRepresentationSet? { await base.representations(for: uid) }
    func bytes(for representation: DicomArchiveRepresentation) async throws -> Data {
        var bytes = try await base.bytes(for: representation)
        bytes[0] ^= 1
        return bytes
    }
    func generationRevision(for uid: String) async throws -> UInt64 { await base.generationRevision(for: uid) }
    func store(bytes: Data, representation: DicomArchiveRepresentation, derivativeLimit: Int, expectedRevision: UInt64?) async throws
        -> DicomArchiveRepresentation {
        try await base.store(bytes: bytes, representation: representation, derivativeLimit: derivativeLimit, expectedRevision: expectedRevision)
    }
    func invalidate(sourceSOPInstanceUID: String, reason: DicomArchiveRepresentation.UnavailableReason) async throws {
        try await base.invalidate(sourceSOPInstanceUID: sourceSOPInstanceUID, reason: reason)
    }
}

extension DicomRepresentationGeneratorTests {
    func test_changedSourceBytes_refusesBeforeExecution() async throws {
        let (store, set, _) = try await RepresentationFixture.archive()
        do {
            _ = try await generator(ChangedSourceRepresentationStore(base: store))
                .generate(set: set, to: .rleLossless, derivativeLimit: 2)
            XCTFail("Changed source")
        } catch { XCTAssertEqual(error as? DicomRepresentationRefusal, .sourceChanged) }
    }

    func test_unavailableCodec_refusesBeforeExecution() async throws {
        let (store, set, _) = try await RepresentationFixture.archive()
        let generator = DicomRepresentationGenerator(store: store, creatorIdentifier: "test", configurationHash: "config",
            toolkitVersion: "test", environment: ["DICOM_JXLSWIFT_MODE": "disabled"])
        do {
            _ = try await generator.generate(set: set, to: .jpegXLLossless, derivativeLimit: 2)
            XCTFail("Unavailable codec")
        } catch { XCTAssertEqual(error as? DicomRepresentationRefusal, .codecUnavailable) }
    }
}
