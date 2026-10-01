#if canImport(Darwin)
import CryptoKit
import Darwin
import Foundation
import DicomTestUtilities
@testable import DicomCore
import XCTest

/// Issue #2793: a C-STORE is received straight into a Part 10 file. The object is larger than the default memory
/// budget (`maximumStagedBytes`, 512 MiB), which an in-memory receive refuses; here it is stored while the process
/// footprint grows by little more than a PDU, and the dataset in the stored file is the one sent, byte for byte.
final class DicomStorageSCPReceiveToFileTests: XCTestCase {
    func test_concurrentAssociations_serializeFragmentCapacityChecks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("receive-concurrent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = DicomStorageSCPConfiguration(aeTitle: "ISIS", supportedStorageSOPClassUIDs: [sopClass],
                                                         transferSyntaxes: [.explicitVRLittleEndian])
        let preflight = ConcurrentReceivePreflight()
        let service = DicomStorageSCPService(configuration: configuration,
            storage: try DicomFileStorageCache(directoryURL: directory), storagePreflight: preflight)
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            do {
                let transport = try StreamedStoreTransport(pixelBytes: 48_000)
                let result = try service.handleAssociation(using: transport)
                XCTAssertEqual(transport.statuses, [0])
                XCTAssertEqual(result.storedInstances.count, 1)
            } catch { XCTFail("Concurrent receive failed: \(error)") }
        }
        XCTAssertEqual(preflight.maximumConcurrentChecks, 1)
        XCTAssertEqual(preflight.completedChecks, 8)
    }

    func test_capacityRefusal_precedesFragmentWritesAndDrainsTheDataset() throws {
        for refusedCheck in [1, 2] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("receive-capacity-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let storage = try DicomFileStorageCache(directoryURL: directory)
            let preflight = ReceiveCapacityRecorder(directory: storage.receivedFileDirectory!, refusedCheck: refusedCheck)
            let configuration = DicomStorageSCPConfiguration(aeTitle: "ISIS", supportedStorageSOPClassUIDs: [sopClass],
                                                             transferSyntaxes: [.explicitVRLittleEndian])
            let service = DicomStorageSCPService(configuration: configuration, storage: storage, storagePreflight: preflight)
            let transport = try StreamedStoreTransport(pixelBytes: 48_000)
            let result = try service.handleAssociation(using: transport)
            XCTAssertTrue(result.storedInstances.isEmpty)
            XCTAssertEqual(transport.statuses, [0xA700])
            let checks = preflight.checks
            XCTAssertEqual(checks.count, refusedCheck)
            let header = try DicomDataSetWriter.part10Data(fromEncodedDataSet: Data(), transferSyntax: .explicitVRLittleEndian,
                mediaStorageSOPClassUID: sopClass, mediaStorageSOPInstanceUID: sopInstance)
            XCTAssertEqual(checks[0].fileBytes, header.count, "first dataset fragment must not be written before admission")
            if refusedCheck == 2 {
                XCTAssertEqual(checks[1].fileBytes, header.count + Int(checks[0].requiredBytes))
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.receivedFileDirectory!.path)
                .filter { $0.hasSuffix(".received") }, [])
            XCTAssertGreaterThan(transport.sentByteCount, checks.reduce(0) { $0 + Int($1.requiredBytes) },
                                 "remaining fragments were drained without further capacity checks or writes")
        }
    }

    func test_objectAboveTheMemoryBudget_isReceivedIntoAFileBitForBit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("isis-2793-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = DicomStorageSCPConfiguration(aeTitle: "ISIS", supportedStorageSOPClassUIDs: [sopClass],
                                                         transferSyntaxes: [.explicitVRLittleEndian])
        let pixelBytes = Int(configuration.maximumStagedBytes) + 16 * 1_048_576
        let service = DicomStorageSCPService(configuration: configuration,
                                             storage: try DicomFileStorageCache(directoryURL: directory))
        let transport = try StreamedStoreTransport(pixelBytes: pixelBytes)

        let meter = FootprintMeter()
        let result = try service.handleAssociation(using: transport)
        let growth = meter.stop()

        XCTAssertEqual(transport.statuses, [0])
        let stored = try XCTUnwrap(result.storedInstances.first)
        let request = try DicomStoreRequest(part10FileAt: stored.fileURL)
        XCTAssertEqual(request.dataSetData.count, transport.sentByteCount)
        XCTAssertEqual(SHA256.hash(data: request.dataSetData).map { $0 }, transport.sentDigest.map { $0 })
        let header = try DicomDataSetWriter.part10Data(fromEncodedDataSet: Data(),
                                                       transferSyntax: .explicitVRLittleEndian,
                                                       mediaStorageSOPClassUID: sopClass,
                                                       mediaStorageSOPInstanceUID: sopInstance)
        let handle = try FileHandle(forReadingFrom: stored.fileURL)
        defer { try? handle.close() }
        XCTAssertEqual(try handle.read(upToCount: header.count), header, "preamble and File Meta, then the dataset")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(".ingest").path)
            .filter { $0.hasSuffix(".received") }, [], "the received file was moved, not copied")
        print("ISIS_2793 object \(transport.sentByteCount) bytes, footprint growth \(growth) bytes")
        XCTAssertLessThan(growth, 64 * 1_048_576, "the object was held in memory")
    }
}

// All mutable counters are accessed under lock; each positive check covers a fragment write.
private final class ConcurrentReceivePreflight: DicomStoragePreflightChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0
    private var completed = 0
    var maximumConcurrentChecks: Int { lock.withLock { maximum } }
    var completedChecks: Int { lock.withLock { completed } }

    func checkStorageAvailability(requiredBytes: Int64) throws {
        guard requiredBytes > 0 else { return }
        lock.withLock { active += 1; maximum = max(maximum, active) }
        Thread.sleep(forTimeInterval: 0.005)
        lock.withLock { active -= 1; completed += 1 }
    }
}

private final class ReceiveCapacityRecorder: DicomStoragePreflightChecking, @unchecked Sendable {
    private let directory: URL
    private let refusedCheck: Int
    private let lock = NSLock()
    private var recorded: [(requiredBytes: Int64, fileBytes: Int)] = []

    init(directory: URL, refusedCheck: Int) { self.directory = directory; self.refusedCheck = refusedCheck }
    var checks: [(requiredBytes: Int64, fileBytes: Int)] { lock.withLock { recorded } }

    func checkStorageAvailability(requiredBytes: Int64) throws {
        try lock.withLock {
            let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil).first { $0.pathExtension == "received" })
            let size = try XCTUnwrap(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            recorded.append((requiredBytes, size))
            if recorded.count == refusedCheck {
                throw DicomStorageSCPAdmissionError.insufficientStorage(requiredBytes: requiredBytes)
            }
        }
    }
}

private let sopClass = DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
private let sopInstance = "2.25.2793"

/// A peer sending one C-STORE whose Pixel Data is made up fragment by fragment as the SCP reads it, so that the
/// sender holds no more of the object than the receiver should.
private final class StreamedStoreTransport: DicomAssociationTransport {
    private static let fragmentBytes = 16_000
    /// Distinct fragments, repeated with a prime period so that a fragment out of place changes the digest.
    private static let patterns = (0 ..< 17).map { seed in
        Data((0 ..< fragmentBytes).map { UInt8(truncatingIfNeeded: ($0 &* 31 &+ seed &* 7) >> 2 ^ seed) })
    }
    private var pending: [Data]
    private let pixelBytes: Int
    private var pixelOffset = 0
    private var finished = false
    private var digest = SHA256()
    private(set) var sentByteCount = 0
    private(set) var sentDigest = SHA256().finalize()
    private(set) var statuses: [UInt16] = []

    init(pixelBytes: Int) throws {
        self.pixelBytes = pixelBytes
        let association = DicomAssociationRequest(calledAETitle: "ISIS", callingAETitle: "PEER", presentationContexts: [
            DicomPresentationContextRequest(id: 1, abstractSyntaxUID: sopClass, transferSyntaxes: [.explicitVRLittleEndian])
        ])
        let command = DicomDIMSECommandSet(affectedSOPClassUID: sopClass, commandField: DicomDIMSECommandField.cStoreRQ,
                                           messageID: 1, commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
                                           priority: 0, affectedSOPInstanceUID: sopInstance)
        let metadata = DicomDataSet(elements: [
            .init(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings([sopClass])),
            .init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([sopInstance]))
        ])
        // Pixel Data (7FE0,0010) OB, its value streamed after this header.
        var head = try DicomDataSetWriter.dataSetData(from: metadata, transferSyntax: .explicitVRLittleEndian)
        head.append(contentsOf: [0xE0, 0x7F, 0x10, 0x00, 0x4F, 0x42, 0x00, 0x00])
        withUnsafeBytes(of: UInt32(pixelBytes).littleEndian) { head.append(contentsOf: $0) }
        pending = [
            try DicomPDUCodec.encode(.associationRequest(association)),
            try DicomPDUCodec.encode(.pData([.init(presentationContextID: 1, isCommand: true, isLastFragment: true,
                                                   data: try command.encoded())]))
        ]
        pending.append(try dataPDU(head, last: false))
    }

    func readPDU() throws -> Data {
        if !pending.isEmpty { return pending.removeFirst() }
        if pixelOffset < pixelBytes {
            let count = min(Self.fragmentBytes, pixelBytes - pixelOffset)
            let fragment = Self.patterns[pixelOffset / Self.fragmentBytes % Self.patterns.count].prefix(count)
            pixelOffset += count
            return try dataPDU(fragment, last: pixelOffset == pixelBytes)
        }
        guard !finished else { throw DicomNetworkError.networkTimeout("streamed store read past release") }
        finished = true
        return try DicomPDUCodec.encode(.releaseRequest)
    }

    func writePDU(_ data: Data) throws {
        guard case .pData(let pdvs) = try DicomPDUCodec.decode(data) else { return }
        for pdv in pdvs where pdv.isCommand {
            statuses.append(try DicomDIMSECommandSet.decode(pdv.data).status ?? 0xFFFF)
        }
    }

    private func dataPDU(_ fragment: Data, last: Bool) throws -> Data {
        digest.update(data: fragment)
        sentByteCount += fragment.count
        if last { sentDigest = digest.finalize() }
        return try DicomPDUCodec.encode(.pData([.init(presentationContextID: 1, isCommand: false,
                                                      isLastFragment: last, data: fragment)]))
    }
}

#endif
