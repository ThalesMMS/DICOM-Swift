import Foundation
import XCTest
@testable import DicomCore

final class DicomIngestCoordinatorTests: XCTestCase {
    func test_originalBytesAndStages_arePreservedAndDurable() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let bytes = try ingestBytes()
        let result = try await fixture.coordinator.ingest(part10Data: bytes)
        XCTAssertEqual(result.durability, .publishedAndRegistered)
        XCTAssertEqual(result.classification, .new)
        try assertIngestObject(result.record, bytes: bytes)
        let entries = try await fixture.journal.entries()
        XCTAssertEqual(entries.map(\.stage), DicomIngestStage.allCases.flatMap { [$0, $0] })
        XCTAssertEqual(entries.map(\.phase), DicomIngestStage.allCases.flatMap { _ in [.intent, .done] })
        let log = try String(contentsOf: fixture.root.appendingPathComponent(".ingest/journal.jsonl"), encoding: .utf8)
        XCTAssertFalse(log.contains("SYNTHETIC"))
        XCTAssertEqual(result.record.path.lastPathComponent, "2.25.2356001.dcm")
    }

    func test_sameUID_duplicateAndConflict_neverOverwrite() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let firstBytes = try ingestBytes()
        let changed = try ingestBytes(pixel: 2)
        let first = try await fixture.coordinator.ingest(part10Data: firstBytes)
        let duplicate = try await fixture.coordinator.ingest(part10Data: firstBytes)
        let conflict = try await fixture.coordinator.ingest(part10Data: changed)
        XCTAssertEqual(duplicate.classification, .duplicate(identicalContent: first.record.contentSHA256))
        XCTAssertEqual(duplicate.record.path, first.record.path)
        XCTAssertEqual(conflict.classification.representationConflict, .conflictingContent)
        XCTAssertTrue(conflict.record.path.pathComponents.contains(".conflicts"))
        XCTAssertTrue(conflict.record.isConflict)
        try assertIngestObject(first.record, bytes: firstBytes)
        try assertIngestObject(conflict.record, bytes: changed)
        let records = try await fixture.registrar.records()
        XCTAssertEqual(records.count, 2)
    }

    func test_existingUnregisteredName_isPreserved() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let old = fixture.root.appendingPathComponent("2.25.2356001.dcm")
        let oldBytes = try ingestBytes(pixel: 8)
        try oldBytes.write(to: old)
        let incoming = try ingestBytes()
        let result = try await fixture.coordinator.ingest(part10Data: incoming)
        XCTAssertNotEqual(result.record.path, old)
        XCTAssertEqual(try Data(contentsOf: old), oldBytes)
        try assertIngestObject(result.record, bytes: incoming)
    }

    func test_memoryRegistrar_cannotClaimDurableRegistration() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let coordinator = DicomIngestCoordinator(root: fixture.root, journal: fixture.journal,
                                                registrar: DicomInMemoryIngestRegistrar())
        let result = try await coordinator.ingest(part10Data: ingestBytes())
        XCTAssertEqual(result.durability, .fileSynced)
        XCTAssertThrowsError(try DicomDurabilityPolicy().validate(result.durability))
        XCTAssertThrowsError(try DicomDurabilityPolicy(required: .retentionConfirmed).validate(.publishedAndRegistered))
    }

    func test_rawDatasetWrap_preservesEncodedBytesAndSyntax() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let set = ingestDataSet()
        let syntax = DicomTransferSyntax.implicitVRLittleEndian
        let raw = try DicomDataSetWriter.dataSetData(from: set, transferSyntax: syntax)
        let received = DicomStorageReceivedInstance(sopClassUID: DicomStorageSOPClassUIDs.secondaryCaptureImageStorage,
            sopInstanceUID: "2.25.2356001", transferSyntax: syntax, dataSet: set, rawDataSetData: raw)
        let result = try await fixture.coordinator.ingest(received)
        let stored = try Data(contentsOf: result.record.path)
        let meta = try DicomPart10FileMetaParser.parse(stored)
        XCTAssertEqual(Data(stored.dropFirst(meta.dataSetOffset)), raw)
        XCTAssertEqual(meta.transferSyntaxUID, syntax.rawValue)
    }
}

struct IngestFixture: Sendable {
    let root: URL
    let journal: DicomJSONLIngestJournal
    let registrar: DicomJSONLIngestRegistrar
    var coordinator: DicomIngestCoordinator { .init(root: root, journal: journal, registrar: registrar) }
    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("isis-ingest-\(UUID())")) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        journal = try .init(path: root.appendingPathComponent(".ingest/journal.jsonl"))
        registrar = try .init(path: root.appendingPathComponent(".ingest/registry.jsonl"))
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

func ingestDataSet(uid: String = "2.25.2356001", pixel: UInt8 = 1) -> DicomDataSet {
    DicomDataSet(elements: [
        .init(tag: 0x00080016, vr: .UI, value: .strings([DicomStorageSOPClassUIDs.secondaryCaptureImageStorage])),
        .init(tag: 0x00080018, vr: .UI, value: .strings([uid])),
        .init(tag: 0x00100010, vr: .PN, value: .strings(["SYNTHETIC^INGEST"])),
        .init(tag: 0x0020000D, vr: .UI, value: .strings(["2.25.2356002"])),
        .init(tag: 0x0020000E, vr: .UI, value: .strings(["2.25.2356003"])),
        .init(tag: 0x00280002, vr: .US, value: .unsignedIntegers([1])),
        .init(tag: 0x00280004, vr: .CS, value: .strings(["MONOCHROME2"])),
        .init(tag: 0x00280010, vr: .US, value: .unsignedIntegers([1])),
        .init(tag: 0x00280011, vr: .US, value: .unsignedIntegers([2])),
        .init(tag: 0x00280100, vr: .US, value: .unsignedIntegers([8])),
        .init(tag: 0x00280101, vr: .US, value: .unsignedIntegers([8])),
        .init(tag: 0x00280102, vr: .US, value: .unsignedIntegers([7])),
        .init(tag: 0x00280103, vr: .US, value: .unsignedIntegers([0])),
        .init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data([pixel, pixel])))
    ])
}

func ingestBytes(uid: String = "2.25.2356001", pixel: UInt8 = 1) throws -> Data {
    try DicomDataSetWriter.part10Data(from: ingestDataSet(uid: uid, pixel: pixel))
}

func assertIngestObject(_ record: DicomIngestRecord, bytes: Data, file: StaticString = #filePath, line: UInt = #line) throws {
    let recovered = try Data(contentsOf: record.path)
    XCTAssertEqual(recovered, bytes, file: file, line: line)
    XCTAssertEqual(DicomArchiveRepresentation.hash(recovered), record.contentSHA256, file: file, line: line)
    let request = try DicomStoreRequest(part10Data: recovered)
    XCTAssertEqual(request.sopInstanceUID, record.sopInstanceUID, file: file, line: line)
    XCTAssertEqual(request.sopClassUID, record.sopClassUID, file: file, line: line)
    XCTAssertEqual(request.transferSyntax.rawValue, record.transferSyntaxUID, file: file, line: line)
}

actor IngestFaultJournal: DicomIngestJournaling {
    nonisolated let isDurable = true
    let base: any DicomIngestJournaling
    let nth: Int
    let after: Bool
    let crash: Bool
    var count = 0
    init(base: any DicomIngestJournaling, nth: Int, after: Bool, crash: Bool = true) {
        self.base = base; self.nth = nth; self.after = after; self.crash = crash
    }
    func append(_ entry: DicomIngestJournalEntry) async throws {
        count += 1
        if count == nth, !after { try fail() }
        try await base.append(entry)
        if count == nth, after { try fail() }
    }
    func fail() throws {
        if crash { throw DicomIngestCrash() }
        throw POSIXError(.EIO)
    }
    func entries() async throws -> [DicomIngestJournalEntry] { try await base.entries() }
}

actor IngestFaultRegistrar: DicomIngestRegistrar {
    nonisolated let gate = DicomIngestGate()
    nonisolated let durability = DicomDurabilityLevel.publishedAndRegistered
    let base: any DicomIngestRegistrar
    let after: Bool
    let crash: Bool
    init(base: any DicomIngestRegistrar, after: Bool = false, crash: Bool = false) {
        self.base = base; self.after = after; self.crash = crash
    }
    func classify(sopInstanceUID: String, contentSHA256: String) async throws -> DicomIngestClassification {
        try await base.classify(sopInstanceUID: sopInstanceUID, contentSHA256: contentSHA256)
    }
    func records() async throws -> [DicomIngestRecord] { try await base.records() }
    func register(_ record: DicomIngestRecord) async throws -> DicomIngestClassification {
        if after { _ = try await base.register(record) }
        if crash { throw DicomIngestCrash() }
        throw POSIXError(.EIO)
    }
}
