import Foundation
import XCTest
@testable import DicomCore

@MainActor
final class DicomSourceFrameIndexTests: XCTestCase {
    func test_nativeWordSamplesWithEightStoredBits_keepWordMetadata() async throws {
        let metadata = DicomDataSet(elements: [
            .init(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([1])),
            .init(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([2])),
            .init(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            .init(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([16])),
            .init(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([8])),
            .init(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([7])),
            .init(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
            .init(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["MONOCHROME2"])),
            .init(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            .init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.28561"])),
            .init(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(Data([1, 0, 255, 0])))
        ])
        let session = try await DicomSourceFrameSession.open(source: DicomByteSource(
            data: DicomDataSetWriter.part10Data(from: metadata)))
        let array = try await session.frame(at: 0)
        let backed = try await session.dataBackedFrame(at: 0)
        XCTAssertEqual(array.metadata.bitsAllocated, 16)
        XCTAssertEqual(backed.metadata.bitsAllocated, 16)
        XCTAssertEqual(array.metadata.bitsStored, 8)
        XCTAssertEqual(backed.metadata.bitsStored, 8)
    }

    func test_basicTable_readsRandomMultiFragmentFramesWithoutSiblingPayloads() async throws {
        let fragments = [Data([1, 2]), Data([3, 4]), Data([5, 6]), Data([7, 8])]
        let bytes = encapsulated(bot: [0, 20, 30], fragments: fragments)
        let source = DicomByteSource(data: bytes)
        let layout = try await parse(source, frames: 3)
        XCTAssertEqual(layout.frameFragmentIndexes, [[0, 1], [2], [3]])
        let indexed = await source.metrics
        XCTAssertEqual(indexed.receivedBytes, 60)
        XCTAssertFalse(indexed.ranges.contains { range in layout.fragments.contains { range.overlaps($0.valueRange) } })
        for frame in [2, 0, 1] {
            var actual = Data()
            for fragment in layout.frameFragmentIndexes[frame] {
                actual.append(try await source.read(layout.fragments[fragment].valueRange).copyData())
            }
            XCTAssertEqual(actual, [Data([1, 2, 3, 4]), Data([5, 6]), Data([7, 8])][frame])
        }
    }

    func test_badTables_neverFallBackToFragmentCount() async throws {
        for bot in [[UInt32(10), 20], [0, 999], [0], [10, 0]] {
            let source = DicomByteSource(data: encapsulated(bot: bot, fragments: [Data([1, 2]), Data([3, 4])]))
            do { _ = try await parse(source, frames: 2); XCTFail("Bad BOT accepted: \(bot)") }
            catch { XCTAssertEqual(error as? DicomSourceFrameIndex.Failure, .invalidOffsetTable) }
        }
    }

    func test_emptyBOT_requiresUnambiguousCodecSpecificFrameMapping() async throws {
        let source = DicomByteSource(data: encapsulated(bot: [], fragments: [Data([1, 2]), Data([3, 4]), Data([5, 6])]))
        do { _ = try await parse(source, frames: 2); XCTFail("Ambiguous fragments accepted") }
        catch { XCTAssertEqual(error as? DicomSourceFrameIndex.Failure, .ambiguousFrameBoundaries) }
        for syntax in [DicomTransferSyntax.htj2kLossless, .jpegXLLossless, .rleLossless] {
            do { _ = try await parse(source, frames: 1, syntax: syntax); XCTFail("Multiple fragments accepted") }
            catch { XCTAssertEqual(error as? DicomSourceFrameIndex.Failure, .invalidFragmentation(syntax.rawValue)) }
        }
    }

    func test_extendedTable_trimsOnlyVerifiedPadAndRejectsConflictingBOT() async throws {
        let encoded = encapsulated(bot: [], fragments: [Data([1, 2, 3, 0]), Data([4, 5])])
        let source = DicomByteSource(data: encoded)
        let layout = try await parse(source, frames: 2, offsets: [0, 12], lengths: [3, 2])
        XCTAssertEqual(layout.frameFragmentIndexes, [[0], [1]])
        for lengths in [[UInt64(1), 2], [5, 2], [4, 2, 2]] {
            do { _ = try await parse(source, frames: 2, offsets: [0, 12], lengths: lengths); XCTFail("Bad EOT length") }
            catch { XCTAssertEqual(error as? DicomSourceFrameIndex.Failure, .invalidOffsetTable) }
        }
        let conflicting = DicomByteSource(data: encapsulated(bot: [0, 12], fragments: [Data([1, 2, 3, 0]), Data([4, 5])]))
        do { _ = try await parse(conflicting, frames: 2, offsets: [0, 12], lengths: [3, 2]); XCTFail("BOT plus EOT") }
        catch { XCTAssertEqual(error as? DicomSourceFrameIndex.Failure, .invalidOffsetTable) }
    }

    func test_truncationOddFragmentsAndIndexBudget_failBeforeMaterialization() async throws {
        let valid = encapsulated(bot: [], fragments: [Data([1, 2])])
        for cut in 0..<valid.count {
            let source = DicomByteSource(data: Data(valid.prefix(cut)))
            do { _ = try await parse(source, frames: 1); XCTFail("Truncation \(cut) accepted") }
            catch { XCTAssertNotNil(error as? DicomSourceFrameIndex.Failure) }
        }
        let odd = DicomByteSource(data: encapsulated(bot: [], fragments: [Data([1])]))
        do { _ = try await parse(odd, frames: 1); XCTFail("Odd fragment accepted") }
        catch { XCTAssertEqual(error as? DicomSourceFrameIndex.Failure, .truncatedItems) }
        let many = DicomByteSource(data: encapsulated(bot: [], fragments: Array(repeating: Data([1, 2]), count: 3)))
        do { _ = try await parse(many, frames: 3, budget: 128); XCTFail("Index limit ignored") }
        catch { XCTAssertEqual(error as? DicomSourceFrameIndex.Failure, .indexLimit) }
    }

    func test_extendedOffsetsAboveFourGiB_readOnlyHeaders() async throws {
        let hugeLength = Int(UInt32.max) - 1
        let second = 16 + hugeLength
        let end = second + 10 + 8
        let headers = [0: item(Data()), 8: header(tag: 0xFFFEE000, length: UInt32(hugeLength)),
                       second: header(tag: 0xFFFEE000, length: 2), second + 10: header(tag: 0xFFFEE0DD, length: 0)]
        let transport = DicomByteRangeTransport { request in
            guard request.range.count == 8, let bytes = headers[request.range.lowerBound] else {
                throw DicomSourceFrameIndex.Failure.frameLimit
            }
            return .init(status: 206, contentRange: "bytes \(request.range.lowerBound)-\(request.range.upperBound - 1)/\(end)",
                         entityTag: "\"synthetic\"", body: bytes)
        }
        let source = try DicomByteSource(remote: transport, count: end, entityTag: "\"synthetic\"")
        let descriptor = try await parse(source, frames: 2, offsets: [0, UInt64(second - 8)], lengths: [UInt64(hugeLength), 2])
        XCTAssertGreaterThan(descriptor.fragments[1].itemRange.lowerBound, Int(UInt32.max))
        XCTAssertEqual(descriptor.frameFragmentIndexes, [[0], [1]])
        let metrics = await source.metrics
        XCTAssertEqual(metrics.receivedBytes, 32)
    }

    func test_part10ExtendedLengths_removeOnlyZeroPadFromSelectedFrame() async throws {
        for pad in [UInt8(0), 0xFF] {
            let metadata = DicomDataSet(elements: [
                .init(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["2"])),
                .init(tag: DicomTag.extendedOffsetTable.rawValue, vr: .OV, value: .bytes(integers([UInt64(0), 12]))),
                .init(tag: DicomTag.extendedOffsetTableLengths.rawValue, vr: .OV, value: .bytes(integers([UInt64(3), 2])))
            ])
            var encoded = try DicomDataSetWriter.dataSetData(from: metadata)
            encoded.append(contentsOf: [0xE0, 0x7F, 0x10, 0, 0x4F, 0x42, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
            encoded.append(encapsulated(bot: [], fragments: [Data([1, 2, 3, pad]), Data([4, 5])]))
            let part10 = try DicomDataSetWriter.part10Data(fromEncodedDataSet: encoded, transferSyntax: .jpegBaseline,
                                                          mediaStorageSOPClassUID: "1.2.840.10008.5.1.4.1.1.7",
                                                          mediaStorageSOPInstanceUID: "2.25.2319123")
            let source = DicomByteSource(data: part10)
            let session = try await DicomSourceFrameSession.open(source: source)
            do {
                let result = try await session.frameData(at: 0)
                XCTAssertEqual(pad, 0)
                XCTAssertEqual(result, Data([1, 2, 3]))
            } catch {
                XCTAssertEqual(pad, 0xFF)
                XCTAssertEqual(error as? DicomSourceFrameIndex.Failure, .invalidPadding)
            }
            let second = try await session.frameData(at: 1)
            XCTAssertEqual(second, Data([4, 5]))
            await session.close()
        }
    }

    func test_nativeIndex_preservesRandomAccessAndRevisionAcrossIndependentCorpus() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/IndependentDifferential")
        for name in ["gray8", "gray12-signed", "gray16", "gray8-inverted", "rgb-interleaved", "rgb-planar"] {
            let source = try await DicomByteSource.openFile(directory.appendingPathComponent(name + ".dcm"))
            let metadata = try await DicomSourceMetadata.readPart10(from: source)
            let index = try await DicomSourceFrameIndex.build(from: source, metadata: metadata)
            XCTAssertEqual(index.nativeLayout?.frameOffsets.count, 1)
            let original = try Data(contentsOf: directory.appendingPathComponent(name + ".dcm"))
            for frame in [2, 0, 1] {
                let range = try XCTUnwrap(index.ranges(forFrame: frame).first)
                let actual = try await index.frameData(at: frame, from: source)
                XCTAssertEqual(actual, original.subdata(in: range))
            }
            await source.close()
            do { _ = try await index.frameData(at: 0, from: source); XCTFail("Closed source read") }
            catch { XCTAssertEqual(error as? DicomByteSource.Failure, .closed) }
        }
    }

    private func parse(_ source: DicomByteSource, frames: Int, syntax: DicomTransferSyntax = .jpegBaseline,
                       offsets: [UInt64]? = nil, lengths: [UInt64]? = nil,
                       budget: Int = 32768) async throws -> DicomEncapsulatedPixelDataDescriptor {
        try await DicomEncapsulatedPixelDataParser().parse(
            source: source, pixelDataRange: 0..<source.count, numberOfFrames: frames, transferSyntax: syntax,
            extendedOffsetTableData: offsets.map { integers($0) },
            extendedOffsetTableLengthsData: lengths.map { integers($0) }, maximumIndexBytes: budget
        )
    }

    private func integers<T: FixedWidthInteger>(_ values: [T]) -> Data {
        values.reduce(into: Data()) { data, value in
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
    }

    private func header(tag: UInt32, length: UInt32) -> Data {
        integers([UInt16(truncatingIfNeeded: tag >> 16), UInt16(truncatingIfNeeded: tag)]) + integers([length])
    }

    private func item(_ data: Data) -> Data { header(tag: 0xFFFEE000, length: UInt32(data.count)) + data }

    private func encapsulated(bot: [UInt32], fragments: [Data]) -> Data {
        item(integers(bot)) + fragments.reduce(into: Data()) { $0.append(item($1)) }
            + header(tag: 0xFFFEE0DD, length: 0)
    }
}
