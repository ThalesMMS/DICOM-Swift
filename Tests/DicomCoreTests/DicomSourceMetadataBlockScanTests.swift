import Foundation
import XCTest
@testable import DicomCore

/// Issue #3111: memory and buffered-file sources scan the header out of blocks, parsed in place; a remote source keeps
/// the per-element reads. Both scans must yield the same metadata and the same frame index.
final class DicomSourceMetadataBlockScanTests: XCTestCase {
    func test_blockScan_matchesThePerElementScanAndItsFrameIndex() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("block-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures: [(String, Data)] = [
            ("explicit LE, long header, undefined-length and private sequences", try Self.native(.explicitVRLittleEndian)),
            ("implicit LE, long header, undefined-length and private sequences", try Self.native(.implicitVRLittleEndian)),
            ("explicit BE, long header, defined-length sequence", try Self.native(.explicitVRBigEndian)),
            ("encapsulated, undefined-length sequence, two fragments", try Self.encapsulated())
        ]
        for (name, part10) in fixtures {
            let file = directory.appendingPathComponent("\(fixtures.firstIndex { $0.0 == name } ?? 0).dcm")
            try part10.write(to: file)
            let reference = try await Self.scan(Self.remote(part10))
            let memory = DicomByteSource(data: part10)
            let disk = try await DicomByteSource.openFile(file)
            for (label, source) in [("memory", memory), ("file", disk)] {
                let scanned = try await Self.scan(source)
                XCTAssertEqual(scanned.dataSet, reference.dataSet, "\(name), \(label)")
                XCTAssertEqual(scanned.fileMeta, reference.fileMeta, "\(name), \(label)")
                XCTAssertEqual(scanned.syntax, reference.syntax, "\(name), \(label)")
                XCTAssertEqual(scanned.pixelDataRange, reference.pixelDataRange, "\(name), \(label)")
                XCTAssertEqual(scanned.pixelDataTag, reference.pixelDataTag, "\(name), \(label)")
                XCTAssertEqual(scanned.pixelDataVR, reference.pixelDataVR, "\(name), \(label)")
                XCTAssertEqual(scanned.encapsulated, reference.encapsulated, "\(name), \(label)")
                XCTAssertEqual(scanned.copiedBytes, reference.copiedBytes, "\(name), \(label)")
                XCTAssertEqual(scanned.recovered, reference.recovered, "\(name), \(label): recovery mode")
                XCTAssertEqual(scanned.index, reference.index, "\(name), \(label): frame index")
                let metrics = await source.metrics
                // Native Pixel Data is never requested (the frame index reads none). Encapsulated fragments are
                // skipped by the scan, as `DicomSourceMetadataTests` checks; the index reads their item headers.
                let pixels = try XCTUnwrap(scanned.pixelDataRange)
                if !scanned.encapsulated {
                    XCTAssertFalse(metrics.ranges.contains { $0.overlaps(pixels) }, "\(name), \(label): no pixel requested")
                }
                XCTAssertGreaterThan(metrics.receivedBytes, 0, "\(name), \(label)")
                await source.close()
            }
        }
    }

    func test_blockScan_reportsAChangedFileAndTheReadBudget() async throws {
        let part10 = try Self.native(.explicitVRLittleEndian)
        let limited = DicomByteSource(data: part10, limits: .init(maximumTotalReadBytes: 1024))
        do {
            _ = try await DicomSourceMetadata.readPart10(from: limited)
            XCTFail("the scan exceeded the read budget")
        } catch {
            XCTAssertEqual(error as? DicomByteSource.Failure, .totalReadLimit)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("block-scan-\(UUID().uuidString).dcm")
        try part10.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let source = try await DicomByteSource.openFile(file)
        try (part10 + Data([0])).write(to: file)
        do {
            _ = try await DicomSourceMetadata.readPart10(from: source)
            XCTFail("a file replaced after it was opened was scanned")
        } catch {
            XCTAssertEqual(error as? DicomByteSource.Failure, .changed)
        }
    }

    // MARK: - Scans

    private struct Scan: Equatable {
        let dataSet: DicomDataSet
        let fileMeta: DicomDataSet
        let syntax: DicomTransferSyntax
        let pixelDataRange: Range<Int>?
        let pixelDataTag: Int?
        let pixelDataVR: DicomVR?
        let encapsulated: Bool
        let copiedBytes: Int
        let recovered: DicomDataSet
        let index: String
    }

    private static func scan(_ source: DicomByteSource) async throws -> Scan {
        let metadata = try await DicomSourceMetadata.readPart10(from: source)
        let recovered = try await DicomSourceMetadata.readPart10(from: source, mode: .recover)
        let index: String
        do {
            let built = try await DicomSourceFrameIndex.build(from: source, metadata: metadata)
            index = "\(built.frameCount) \(String(describing: built.nativeLayout)) \(String(describing: built.encapsulatedLayout))"
        } catch {
            index = "refused: \(error)"
        }
        return Scan(dataSet: metadata.dataSet, fileMeta: metadata.fileMetaInformation, syntax: metadata.transferSyntax,
                    pixelDataRange: metadata.pixelDataRange, pixelDataTag: metadata.pixelDataTag,
                    pixelDataVR: metadata.pixelDataVR, encapsulated: metadata.pixelDataIsEncapsulated,
                    copiedBytes: metadata.metadataCopiedBytes, recovered: recovered.dataSet, index: index)
    }

    /// A range-capable remote source over `data`: it serves no block, so its scan reads element by element.
    private static func remote(_ data: Data) throws -> DicomByteSource {
        let entityTag = "\"block-scan\""
        return try DicomByteSource(remote: DicomByteRangeTransport { request in
            let range = request.range
            return .init(status: 206, contentRange: "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)",
                         entityTag: entityTag, body: data.subdata(in: range))
        }, count: data.count, entityTag: entityTag)
    }

    // MARK: - Fixtures

    /// Three 4 × 4 16-bit frames behind a header longer than one scan block (a 40 000-byte private value), with a
    /// private creator, non-ASCII text under ISO_IR 192 and, for the little-endian syntaxes, an undefined-length
    /// sequence with a nested item and an undefined-length private sequence spliced in as read from disk.
    private static func native(_ syntax: DicomTransferSyntax) throws -> Data {
        let words = (0..<48).map { UInt16(truncatingIfNeeded: $0 &* 1031 &+ 7) }
        let pixels = Data(words.flatMap { syntax == .explicitVRBigEndian
            ? [UInt8($0 >> 8), UInt8($0 & 0xFF)] : [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        var elements: [DicomDataElement] = [
            .init(tag: DicomTag.specificCharacterSet.rawValue, vr: .CS, value: .strings(["ISO_IR 192"])),
            .init(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.2"])),
            .init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.311101"])),
            .init(tag: DicomTag.studyDescription.rawValue, vr: .LO, value: .strings(["Sintético Δ"])),
            .init(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["SYNTHETIC^BLOCK"])),
            .init(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            .init(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["MONOCHROME2"])),
            .init(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["3"])),
            .init(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([4])),
            .init(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([4])),
            .init(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([16])),
            .init(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([12])),
            .init(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([11])),
            .init(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([1])),
            .init(tag: 0x0029_0010, vr: .LO, value: .strings(["ISIS BLOCK"])),
            .init(tag: 0x0029_1001, vr: .OB, value: .bytes(Data((0..<40_000).map { UInt8($0 % 251) }))),
            .init(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(pixels))
        ]
        if syntax == .explicitVRBigEndian {
            elements.append(.init(tag: 0x0008_1115, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [
                .init(tag: DicomTag.seriesDescription.rawValue, vr: .LO, value: .strings(["NESTED"]))
            ]))])))
        }
        var part10 = try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: elements),
                                                       options: .init(transferSyntax: syntax))
        guard syntax != .explicitVRBigEndian else { return part10 }
        let explicit = syntax == .explicitVRLittleEndian
        // In tag order: (0008,1115) goes before Patient Name (0010,0010), the private sequence before Pixel Data.
        let patient = try XCTUnwrap(part10.range(of: Data([0x10, 0x00, 0x10, 0x00]) + (explicit ? Data("PN".utf8) : Data())))
        let nested = try DicomDataSetWriter.dataSetData(from: .init(elements: [
            .init(tag: DicomTag.seriesDescription.rawValue, vr: .LO, value: .strings(["NESTED"]))
        ]), transferSyntax: syntax)
        part10.insert(contentsOf: undefinedSequence(group: 0x0008, element: 0x1115, explicit: explicit, item: nested),
                      at: patient.lowerBound)
        let privateItem = Data([0x29, 0x00, 0x20, 0x10]) + (explicit ? Data("US".utf8) + Data([2, 0]) : Data([2, 0, 0, 0]))
            + Data([42, 0])
        let pixelHeader = try XCTUnwrap(part10.range(of: Data([0xE0, 0x7F, 0x10, 0x00])))
        part10.insert(contentsOf: undefinedSequence(group: 0x0029, element: 0x1010, explicit: explicit, item: privateItem),
                      at: pixelHeader.lowerBound)
        return part10
    }

    private static func undefinedSequence(group: UInt16, element: UInt16, explicit: Bool, item: Data) -> Data {
        var bytes = Data([UInt8(group & 0xFF), UInt8(group >> 8), UInt8(element & 0xFF), UInt8(element >> 8)])
        bytes += explicit ? Data("SQ".utf8) + Data([0, 0, 0xFF, 0xFF, 0xFF, 0xFF]) : Data([0xFF, 0xFF, 0xFF, 0xFF])
        bytes += Data([0xFE, 0xFF, 0x00, 0xE0, 0xFF, 0xFF, 0xFF, 0xFF]) + item
        bytes += Data([0xFE, 0xFF, 0x0D, 0xE0, 0, 0, 0, 0])
        return bytes + Data([0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0])
    }

    /// RLE Lossless with an undefined-length sequence, an empty Basic Offset Table and two fragments.
    private static func encapsulated() throws -> Data {
        var encoded = try DicomDataSetWriter.dataSetData(from: .init(elements: [
            .init(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            .init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.311102"]))
        ]))
        let nested = try DicomDataSetWriter.dataSetData(from: .init(elements: [
            .init(tag: DicomTag.seriesDescription.rawValue, vr: .LO, value: .strings(["NESTED"]))
        ]))
        encoded += undefinedSequence(group: 0x0008, element: 0x1115, explicit: true, item: nested)
        encoded += try DicomDataSetWriter.dataSetData(from: .init(elements: [
            .init(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            .init(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["MONOCHROME2"])),
            .init(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["2"])),
            .init(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([2])),
            .init(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([2])),
            .init(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([8])),
            .init(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([8])),
            .init(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([7])),
            .init(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0]))
        ]))
        encoded += Data([0xE0, 0x7F, 0x10, 0, 0x4F, 0x42, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
        encoded += Data([0xFE, 0xFF, 0, 0xE0, 0, 0, 0, 0])
        for fill in [UInt8(0xA5), 0x5A] {
            encoded += Data([0xFE, 0xFF, 0, 0xE0, 0x00, 0x60, 0, 0]) + Data(repeating: fill, count: 0x6000)
        }
        encoded += Data([0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0])
        return try DicomDataSetWriter.part10Data(fromEncodedDataSet: encoded, transferSyntax: .rleLossless,
                                                 mediaStorageSOPClassUID: "1.2.840.10008.5.1.4.1.1.7",
                                                 mediaStorageSOPInstanceUID: "2.25.311102")
    }
}
