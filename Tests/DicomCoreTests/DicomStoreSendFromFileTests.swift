import CryptoKit
import Foundation
import DicomTestUtilities
@testable import DicomCore
import XCTest

/// Issue #2834: a C-STORE is sent straight from its Part 10 file. The dataset stays a mapped view of the file and
/// is cut into PDVs as it goes out, so sending an object larger than the memory budget grows the process footprint
/// by little more than a PDU, and the peer receives the dataset in the file byte for byte.
final class DicomStoreSendFromFileTests: XCTestCase {
    func test_objectAboveTheMemoryBudget_isSentFromItsFileBitForBit() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("isis-2834-\(UUID().uuidString).dcm")
        defer { try? FileManager.default.removeItem(at: file) }
        let budget = 64 * 1_048_576
        let pixelBytes = 4 * budget
        let (dataSetBytes, fileDigest) = try Self.writePart10(to: file, pixelBytes: pixelBytes)
        let peer = HashingStorePeer()
        let service = DicomDIMSEServiceSCU(configuration: DicomDIMSEConnectionConfiguration(
            host: "127.0.0.1", port: 104, calledAETitle: "PEER", callingAETitle: "ISIS", timeout: 10,
            maximumPDULength: 16_384, transferSyntaxes: [.explicitVRLittleEndian]))

        let meter = FootprintMeter()
        let request = try DicomStoreRequest(part10FileAt: file)
        let result = try service.store(request: request, using: peer)
        let growth = meter.stop()

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(peer.receivedByteCount, dataSetBytes)
        XCTAssertEqual(peer.receivedDigest.map { $0 }, fileDigest.map { $0 })
        XCTAssertGreaterThan(peer.dataPDVCount, pixelBytes / 16_384, "the dataset went out PDU by PDU")
        print("ISIS_2834 object \(dataSetBytes) bytes, footprint growth \(growth) bytes")
        XCTAssertLessThan(growth, budget / 2, "the object was held in memory")
    }

    /// Writes a Secondary Capture whose Pixel Data is streamed to disk; returns the dataset length and digest.
    private static func writePart10(to url: URL, pixelBytes: Int) throws -> (Int, SHA256.Digest) {
        let metadata = DicomDataSet(elements: [
            .init(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings([sopClass])),
            .init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([sopInstance]))
        ])
        var head = try DicomDataSetWriter.dataSetData(from: metadata, transferSyntax: .explicitVRLittleEndian)
        head.append(contentsOf: [0xE0, 0x7F, 0x10, 0x00, 0x4F, 0x42, 0x00, 0x00])
        withUnsafeBytes(of: UInt32(pixelBytes).littleEndian) { head.append(contentsOf: $0) }
        let part10Head = try DicomDataSetWriter.part10Data(fromEncodedDataSet: head, transferSyntax: .explicitVRLittleEndian,
                                                           mediaStorageSOPClassUID: sopClass,
                                                           mediaStorageSOPInstanceUID: sopInstance)
        FileManager.default.createFile(atPath: url.path, contents: part10Head)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var digest = SHA256()
        digest.update(data: head)
        let chunk = 1_048_576
        var written = 0
        while written < pixelBytes {
            try autoreleasepool {
                let count = min(chunk, pixelBytes - written)
                let seed = written / chunk
                let bytes = Data((0 ..< count).map { UInt8(truncatingIfNeeded: ($0 &* 31 &+ seed &* 7) >> 2 ^ seed) })
                digest.update(data: bytes)
                try handle.write(contentsOf: bytes)
                written += count
            }
        }
        return (head.count + pixelBytes, digest.finalize())
    }
}

private let sopClass = DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
private let sopInstance = "2.25.2834"

/// A storage SCP that accepts the association and keeps only a running digest of the dataset it receives.
private final class HashingStorePeer: DicomAssociationTransport {
    private var responses: [Data] = []
    private var command: DicomDIMSECommandSet?
    private var contextID: UInt8 = 0
    private var digest = SHA256()
    private(set) var receivedByteCount = 0
    private(set) var receivedDigest = SHA256().finalize()
    private(set) var dataPDVCount = 0

    func writePDU(_ data: Data) throws {
        switch try DicomPDUCodec.decode(data) {
        case .associationRequest(let request):
            let accept = DicomAssociationNegotiator.accept(request, supportedAbstractSyntaxUIDs: [sopClass],
                                                           preferredTransferSyntaxes: [.explicitVRLittleEndian],
                                                           maximumPDULength: 16_384)
            responses.append(try DicomPDUCodec.encode(.associationAccept(accept)))
        case .pData(let pdvs):
            for pdv in pdvs {
                contextID = pdv.presentationContextID
                if pdv.isCommand {
                    command = try DicomDIMSECommandSet.decode(pdv.data)
                    continue
                }
                dataPDVCount += 1
                digest.update(data: pdv.data)
                receivedByteCount += pdv.data.count
                guard pdv.isLastFragment, let command else { continue }
                receivedDigest = digest.finalize()
                let response = DicomDIMSECommandSet(
                    affectedSOPClassUID: command.affectedSOPClassUID, commandField: DicomDIMSECommandField.cStoreRSP,
                    messageIDBeingRespondedTo: command.messageID, commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
                    status: 0, affectedSOPInstanceUID: command.affectedSOPInstanceUID)
                responses.append(try DicomPDUCodec.encode(.pData([
                    DicomPDV(presentationContextID: contextID, isCommand: true, isLastFragment: true,
                             data: try response.encoded())
                ])))
            }
        case .releaseRequest:
            responses.append(try DicomPDUCodec.encode(.releaseResponse))
        default:
            break
        }
    }

    func readPDU() throws -> Data {
        guard !responses.isEmpty else { throw DicomNetworkError.invalidPDULength(expected: 1, actual: 0) }
        return responses.removeFirst()
    }
}
