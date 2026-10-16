import Foundation
import XCTest
@testable import DicomCore

/// Issue #3111: native monochrome frames are read at their offset in the stored-sample convention. Every frame must be
/// byte-identical to the decoded path (`frame(at:)` then `storedSampleData()`), with the same metadata.
final class DicomStoredSampleFrameTests: XCTestCase {
    private struct Layout {
        let bitsAllocated: Int
        let bitsStored: Int
        let highBit: Int
        let signed: Bool
    }

    private static let layouts = [
        Layout(bitsAllocated: 16, bitsStored: 16, highBit: 15, signed: false),
        Layout(bitsAllocated: 16, bitsStored: 16, highBit: 15, signed: true),
        Layout(bitsAllocated: 16, bitsStored: 12, highBit: 11, signed: false),
        Layout(bitsAllocated: 16, bitsStored: 12, highBit: 11, signed: true),
        Layout(bitsAllocated: 16, bitsStored: 12, highBit: 13, signed: true),
        Layout(bitsAllocated: 8, bitsStored: 8, highBit: 7, signed: false),
        Layout(bitsAllocated: 8, bitsStored: 8, highBit: 7, signed: true),
        Layout(bitsAllocated: 8, bitsStored: 6, highBit: 5, signed: true)
    ]

    func test_nativeMonochromeFrames_matchTheDecodedPathByteForByte() async throws {
        let syntaxes: [DicomTransferSyntax] = [.implicitVRLittleEndian, .explicitVRLittleEndian, .explicitVRBigEndian]
        for syntax in syntaxes {
            for layout in Self.layouts {
                for photometric in ["MONOCHROME1", "MONOCHROME2"] {
                    for frames in [1, 3] {
                        let label = "\(syntax.rawValue) \(layout) \(photometric) frames=\(frames)"
                        // 3 × 5 frames: an odd sample count, so 8-bit frames have odd lengths and odd offsets.
                        let (part10, words) = try Self.object(syntax: syntax, layout: layout, photometric: photometric,
                                                              frames: frames, rows: 3, columns: 5)
                        let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: part10))
                        XCTAssertTrue(session.index.readsStoredSamplesDirectly, label)
                        for frame in 0..<frames {
                            let stored = try await session.storedSampleFrame(at: frame)
                            let decoded = try await session.frame(at: frame)
                            XCTAssertEqual(stored.index, frame, label)
                            // The header agrees with the index, so the samples came from the direct read.
                            XCTAssertEqual(stored.metadata.bitsAllocated, layout.bitsAllocated, label)
                            XCTAssertEqual(stored.metadata.pixelRepresentation, layout.signed ? 1 : 0, label)
                            XCTAssertEqual(stored.metadata.photometricInterpretation, photometric, label)
                            XCTAssertEqual(stored.data, decoded.storedSampleData(), "\(label) frame \(frame)")
                            XCTAssertEqual(stored.metadata, decoded.metadata, "\(label) frame \(frame)")
                            let expected = words[(frame * 15)..<((frame + 1) * 15)].map { Self.storedValue($0, layout) }
                            XCTAssertEqual(stored.data, Self.littleEndian(expected, bitsAllocated: layout.bitsAllocated),
                                           "\(label) frame \(frame): the samples as written, masked to Bits Stored")
                        }
                        await session.close()
                    }
                }
            }
        }
    }

    func test_directRead_copiesNoPixelsThroughPart10AndKeepsTheMetadata() async throws {
        let layout = Layout(bitsAllocated: 16, bitsStored: 12, highBit: 11, signed: true)
        let (part10, _) = try Self.object(syntax: .explicitVRLittleEndian, layout: layout, photometric: "MONOCHROME2",
                                          frames: 1, rows: 64, columns: 64)
        let direct = try await DicomSourceFrameSession.open(source: DicomByteSource(data: part10))
        let stored = try await direct.storedSampleFrame(at: 0)
        let directCopies = await direct.metrics.source.compatibilityCopiedBytes
        let decodedSession = try await DicomSourceFrameSession.open(source: DicomByteSource(data: part10))
        let decoded = try await decodedSession.frame(at: 0)
        let decodedCopies = await decodedSession.metrics.source.compatibilityCopiedBytes
        XCTAssertEqual(stored.data, decoded.storedSampleData())
        XCTAssertEqual(stored.metadata, decoded.metadata)
        XCTAssertEqual(stored.metadata.rescaleParameters.intercept, -1024)
        XCTAssertEqual(stored.metadata.rescaleParameters.slope, 1)
        XCTAssertEqual(stored.metadata.rescaleType, "HU")
        XCTAssertNotNil(stored.metadata.windowSettings)
        XCTAssertLessThan(directCopies, 64 * 64 * 2, "only the header is written, never the frame's pixels")
        XCTAssertGreaterThan(decodedCopies, 2 * 64 * 64 * 2)
        await direct.close()
        await decodedSession.close()
    }

    /// A series whose headers differ only in per-instance identity, time and position parses one header; another
    /// difference, or a per-instance value that does not encode, parses its own.
    func test_seriesHeaders_shareTheMetadataOnlyWhenTheyWriteTheSameWay() async throws {
        let layout = Layout(bitsAllocated: 16, bitsStored: 12, highBit: 11, signed: true)
        let (base, _) = Self.dataSet(syntax: .explicitVRLittleEndian, layout: layout, photometric: "MONOCHROME2",
                                     frames: 1, rows: 8, columns: 7)
        func slice(_ number: Int, extra: [DicomDataElement] = [],
                   longSliceLocation: Bool = false) async throws -> (DicomStoredSampleFrame, Int) {
            var dataSet = base
            dataSet.set(.init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.31117\(number)"])))
            dataSet.set(.init(tag: 0x0020_0013, vr: .IS, value: .strings(["\(number)"])))
            dataSet.set(.init(tag: 0x0020_0032, vr: .DS, value: .strings(["0", "0", "\(number * 2)"])))
            for element in extra { dataSet.set(element) }
            var part10 = try DicomDataSetWriter.part10Data(from: dataSet)
            if longSliceLocation {
                // Written by hand, as read from disk: the writer refuses a DS longer than 16 bytes. It goes before
                // Samples per Pixel (0028,0002), the next element in tag order.
                let next = try XCTUnwrap(part10.range(of: Data([0x28, 0x00, 0x02, 0x00, 0x55, 0x53])))
                let value = Data("1.23456789012345678 ".utf8)
                part10.insert(contentsOf: Data([0x20, 0x00, 0x41, 0x10, 0x44, 0x53, UInt8(value.count), 0]) + value,
                              at: next.lowerBound)
            }
            let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: part10))
            let stored = try await session.storedSampleFrame(at: 0)
            let copies = await session.metrics.source.compatibilityCopiedBytes
            let decoded = try await session.frame(at: 0)
            XCTAssertEqual(stored.metadata, decoded.metadata, "slice \(number)")
            XCTAssertEqual(stored.data, decoded.storedSampleData(), "slice \(number)")
            await session.close()
            return (stored, copies)
        }
        let first = try await slice(1)
        let second = try await slice(2)
        XCTAssertEqual(second.1, 0, "the second slice reuses the first slice's metadata without writing its header")
        XCTAssertEqual(first.0.metadata, second.0.metadata)
        let rescaled = try await slice(3, extra: [
            .init(tag: DicomTag.rescaleIntercept.rawValue, vr: .DS, value: .strings(["-1000"]))
        ])
        XCTAssertGreaterThan(rescaled.1, 0)
        XCTAssertEqual(rescaled.0.metadata.rescaleParameters.intercept, -1000)
        // A Slice Location longer than a DS allows does not encode: this header may write differently from its
        // neighbours' (the decoded path drops the value), so it is parsed on its own.
        let long = try await slice(4, longSliceLocation: true)
        XCTAssertGreaterThan(long.1, 0)
        let longAgain = try await slice(5, longSliceLocation: true)
        XCTAssertGreaterThan(longAgain.1, 0)
        XCTAssertEqual(longAgain.0.metadata, first.0.metadata)
    }

    /// Issue #3097: under `ISO_2022_IR_6` no SH/LO encodes; the header drops the declaration and the ASCII Rescale Type
    /// keeps its value, as on the decoded path.
    func test_unsupportedCharacterSet_keepsTheAsciiRescaleTypeAsTheDecodedPath() async throws {
        let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: Self.handBuiltCharsetObject()))
        XCTAssertTrue(session.index.readsStoredSamplesDirectly)
        let stored = try await session.storedSampleFrame(at: 0)
        let decoded = try await session.frame(at: 0)
        XCTAssertEqual(stored.data, decoded.storedSampleData())
        XCTAssertEqual(stored.metadata, decoded.metadata)
        XCTAssertEqual(stored.metadata.rescaleType, "US")
        XCTAssertEqual(stored.metadata.rescaleParameters.slope, 2)
        await session.close()
    }

    func test_layoutsOutsideTheDirectRead_keepTheDecodedPath() async throws {
        func session(_ elements: [DicomDataElement], syntax: DicomTransferSyntax = .explicitVRLittleEndian) async throws
            -> DicomSourceFrameSession {
            var dataSet = DicomDataSet(elements: Self.identity)
            for element in elements { dataSet.set(element) }
            return try await DicomSourceFrameSession.open(source: DicomByteSource(
                data: DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: syntax))))
        }
        func pixelElements(spp: Int = 1, photometric: String = "MONOCHROME2", bits: Int, vr: DicomVR, bytes: Int)
            -> [DicomDataElement] {
            [
                .init(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([2])),
                .init(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([2])),
                .init(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([UInt(spp)])),
                .init(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings([photometric])),
                .init(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([UInt(bits)])),
                .init(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([UInt(bits)])),
                .init(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([UInt(bits - 1)])),
                .init(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
                .init(tag: DicomTag.pixelData.rawValue, vr: vr, value: .bytes(Data(count: bytes)))
            ]
        }
        let colour = try await session(pixelElements(spp: 3, photometric: "RGB", bits: 8, vr: .OB, bytes: 12)
            + [.init(tag: DicomTag.planarConfiguration.rawValue, vr: .US, value: .unsignedIntegers([0]))])
        let wide = try await session(pixelElements(bits: 32, vr: .OW, bytes: 16))
        let bilevel = try await session(pixelElements(bits: 1, vr: .OW, bytes: 2))
        let wordSwapped = try await session(pixelElements(bits: 8, vr: .OW, bytes: 4), syntax: .explicitVRBigEndian)
        for (name, refused) in [("colour", colour), ("32-bit", wide), ("1-bit", bilevel), ("word-swapped 8-bit", wordSwapped)] {
            XCTAssertFalse(refused.index.readsStoredSamplesDirectly, name)
            do {
                _ = try await refused.storedSampleFrame(at: 0)
                XCTFail("\(name) was read directly")
            } catch {
                guard case .unsupportedLayout = error as? DicomSourceFrameIndex.Failure else {
                    return XCTFail("\(name): \(error)")
                }
            }
            await refused.close()
        }
    }

    // MARK: - Fixtures

    private static let identity: [DicomDataElement] = [
        .init(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.2"])),
        .init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.3111"]))
    ]

    /// A native object whose stored words carry bits outside Bits Stored, so the mask and the sign extension show.
    private static func object(syntax: DicomTransferSyntax, layout: Layout, photometric: String, frames: Int,
                               rows: Int, columns: Int) throws -> (Data, [UInt16]) {
        let (dataSet, words) = dataSet(syntax: syntax, layout: layout, photometric: photometric, frames: frames,
                                       rows: rows, columns: columns)
        return (try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: syntax)), words)
    }

    private static func dataSet(syntax: DicomTransferSyntax, layout: Layout, photometric: String, frames: Int,
                                rows: Int, columns: Int) -> (DicomDataSet, [UInt16]) {
        let count = frames * rows * columns
        let words = (0..<count).map { index -> UInt16 in
            let value = UInt16(truncatingIfNeeded: index &* 7919 &+ 40_503)
            return layout.bitsAllocated == 8 ? value & 0xFF : value
        }
        var pixels = Data()
        for word in words {
            if layout.bitsAllocated == 8 {
                pixels.append(UInt8(word))
            } else if syntax == .explicitVRBigEndian {
                pixels.append(contentsOf: [UInt8(word >> 8), UInt8(word & 0xFF)])
            } else {
                pixels.append(contentsOf: [UInt8(word & 0xFF), UInt8(word >> 8)])
            }
        }
        let dataSet = DicomDataSet(elements: identity + [
            .init(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            .init(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings([photometric])),
            .init(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["\(frames)"])),
            .init(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([UInt(rows)])),
            .init(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([UInt(columns)])),
            .init(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([UInt(layout.bitsAllocated)])),
            .init(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([UInt(layout.bitsStored)])),
            .init(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([UInt(layout.highBit)])),
            .init(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([layout.signed ? 1 : 0])),
            .init(tag: DicomTag.windowCenter.rawValue, vr: .DS, value: .strings(["40", "400"])),
            .init(tag: DicomTag.windowWidth.rawValue, vr: .DS, value: .strings(["400", "2000"])),
            .init(tag: DicomTag.rescaleIntercept.rawValue, vr: .DS, value: .strings(["-1024"])),
            .init(tag: DicomTag.rescaleSlope.rawValue, vr: .DS, value: .strings(["1"])),
            .init(tag: DicomTag.rescaleType.rawValue, vr: .LO, value: .strings(["HU"])),
            .init(tag: DicomTag.pixelData.rawValue, vr: layout.bitsAllocated == 8 ? .OB : .OW, value: .bytes(pixels))
        ])
        return (dataSet, words)
    }

    /// PS3.5 8.1.1: the Bits Stored bits ending at High Bit, sign-extended to the allocated word when signed.
    private static func storedValue(_ word: UInt16, _ layout: Layout) -> UInt16 {
        let shift = layout.highBit - layout.bitsStored + 1
        let mask = (1 << layout.bitsStored) - 1
        var value = (Int(word) >> shift) & mask
        if layout.signed, value & (1 << (layout.bitsStored - 1)) != 0 { value |= ~mask }
        return UInt16(truncatingIfNeeded: value) & (layout.bitsAllocated == 8 ? 0xFF : 0xFFFF)
    }

    private static func littleEndian(_ values: [UInt16], bitsAllocated: Int) -> Data {
        bitsAllocated == 8 ? Data(values.map { UInt8($0) })
            : Data(values.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
    }

    /// Explicit VR Little Endian by hand: the writer refuses this character set, which is the case under test.
    private static func handBuiltCharsetObject() -> Data {
        func uint16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
        func element(_ group: UInt16, _ number: UInt16, _ vr: String, _ value: Data) -> Data {
            var value = value
            if value.count % 2 != 0 { value.append(vr == "UI" ? 0 : 0x20) }
            var data = uint16(group) + uint16(number) + Data(vr.utf8)
            if ["OB", "OW", "SQ", "UN", "UT", "UC", "UR"].contains(vr) {
                var length = UInt32(value.count).littleEndian
                data += Data(count: 2) + Data(bytes: &length, count: 4)
            } else {
                data += uint16(UInt16(value.count))
            }
            return data + value
        }
        let sopClass = Data("1.2.840.10008.5.1.4.1.1.7\0".utf8)
        var metaBody = element(0x0002, 0x0002, "UI", sopClass)
        metaBody += element(0x0002, 0x0003, "UI", Data("2.25.3111".utf8))
        metaBody += element(0x0002, 0x0010, "UI", Data("1.2.840.10008.1.2.1\0".utf8))
        var groupLength = UInt32(metaBody.count).littleEndian
        let meta = element(0x0002, 0x0000, "UL", Data(bytes: &groupLength, count: 4)) + metaBody
        var body = element(0x0008, 0x0005, "CS", Data("ISO_2022_IR_6\0".utf8))
        body += element(0x0008, 0x0016, "UI", sopClass)
        body += element(0x0008, 0x0018, "UI", Data("2.25.3111".utf8))
        body += element(0x0028, 0x0002, "US", uint16(1))
        body += element(0x0028, 0x0004, "CS", Data("MONOCHROME2 ".utf8))
        body += element(0x0028, 0x0010, "US", uint16(2))
        body += element(0x0028, 0x0011, "US", uint16(2))
        body += element(0x0028, 0x0100, "US", uint16(16))
        body += element(0x0028, 0x0101, "US", uint16(12))
        body += element(0x0028, 0x0102, "US", uint16(11))
        body += element(0x0028, 0x0103, "US", uint16(1))
        body += element(0x0028, 0x1052, "DS", Data("-5 ".utf8))
        body += element(0x0028, 0x1053, "DS", Data("2 ".utf8))
        body += element(0x0028, 0x1054, "LO", Data("US".utf8))
        body += element(0x7FE0, 0x0010, "OW", Data([0x01, 0xF0, 0xFF, 0x0F, 0x00, 0x08, 0x34, 0x12]))
        return Data(count: 128) + Data("DICM".utf8) + meta + body
    }
}
