import Foundation
import XCTest
@testable import DicomCore

/// Issue #2850: a frame decodes whatever the metadata beside its pixels holds. The objects are built by hand, as
/// read from disk, because the writer refuses exactly the values under test: an empty SOP Instance UID, a name
/// outside the declared character set, and a private DS longer than 16 bytes.
final class DicomSingleFrameMetadataToleranceTests: XCTestCase {
    func test_nativeFrame_decodesDespiteMetadataTheWriterRefuses() async throws {
        let samples: [UInt16] = [1, 2, 300, 40_000]
        let pixels = samples.reduce(into: Data()) { data, value in
            data.append(UInt8(value & 0xFF)); data.append(UInt8(value >> 8))
        }
        let decoder = try DCMDecoder(data: Self.part10(pixelData: Self.element(0x7FE0, 0x0010, "OW", pixels)))
        let artifact = try decoder.singleFramePart10Data(at: 0)
        let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: artifact))
        let raw = try await session.frameData(at: 0)
        await session.close()
        XCTAssertEqual(raw, pixels, "the stored samples reach the frame unchanged")
    }

    func test_functionalGroupsThatDoNotEncode_refuseTheFrame() throws {
        // A per-frame rescale intercept longer than a DS allows: the frame's rescale cannot be carried over.
        let item = Self.element(0x0028, 0x1052, "DS", Data("1.23456789012345678 ".utf8))
        let groups = Self.sequence(0x5200, 0x9230, items: [item])
        let decoder = try DCMDecoder(data: Self.part10(pixelData: Self.element(0x7FE0, 0x0010, "OW", Data(count: 8)),
                                                       extra: groups))
        XCTAssertThrowsError(try decoder.singleFramePart10Data(at: 0))
    }

    /// Issue #3043 (DICOM_Example corpus): text that encodes alone but not under the declared ISO 2022 character set,
    /// and a 64-digit hexadecimal SOP Instance UID the File Meta of an encapsulated frame cannot carry. GDCM displays
    /// both objects, so the frame must still decode.
    func test_textRefusedUnderTheCharacterSetAndAHexadecimalUID_stillYieldTheFrame() async throws {
        let charset = Self.element(0x0008, 0x0005, "CS", Data("ISO 2022 IR 58".utf8))
        let accession = Self.element(0x0008, 0x0050, "SH", Data([0x30, 0x00]))
        let native = try DCMDecoder(data: Self.part10(pixelData: Self.element(0x7FE0, 0x0010, "OW", Data(count: 8)),
                                                      leading: charset, accession: accession))
        XCTAssertNoThrow(try native.singleFramePart10Data(at: 0))

        let fragment = Data((0..<16).map { UInt8($0) })
        let encapsulated = Self.encapsulated(fragment: fragment)
        let hexUID = Data(String(repeating: "a1", count: 32).utf8)
        let decoder = try DCMDecoder(data: Self.part10(pixelData: encapsulated, syntax: "1.2.840.10008.1.2.5",
                                                       instanceUID: hexUID))
        let artifact = try decoder.singleFramePart10Data(at: 0)
        let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: artifact))
        let frame = try await session.frameData(at: 0)
        await session.close()
        XCTAssertEqual(frame, fragment, "the frame's codestream reaches the codec input unchanged")
    }

    /// Issue #3097 (Merge CR, DICOM_Example): `ISO_2022_IR_6` is no defined term, so no SH/LO/PN/LT/ST/UC/UT
    /// encodes under it. The ASCII text beside the pixels, the Rescale Type (LO) among it, must reach the frame.
    func test_unsupportedCharacterSet_keepsTheAsciiRescaleType() async throws {
        let charset = Self.element(0x0008, 0x0005, "CS", Data("ISO_2022_IR_6\0".utf8))
        let rescale = Self.element(0x0028, 0x1052, "DS", Data("0 ".utf8)) + Self.element(0x0028, 0x1053, "DS", Data("1 ".utf8))
            + Self.element(0x0028, 0x1054, "LO", Data("US".utf8))
        let decoder = try DCMDecoder(data: Self.part10(pixelData: Self.element(0x7FE0, 0x0010, "OW", Data(count: 8)),
                                                       extra: rescale, leading: charset))
        let artifact = try decoder.singleFramePart10Data(at: 0)
        let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: artifact))
        let frame = try await session.frame(at: 0)
        await session.close()
        XCTAssertEqual(frame.metadata.rescaleType, "US")
    }

    // MARK: - Explicit VR Little Endian by hand

    private static func part10(pixelData: Data, extra: Data = Data(), syntax: String = "1.2.840.10008.1.2.1",
                               instanceUID: Data = Data(), leading: Data = Data(),
                               accession: Data = Data()) -> Data {
        let syntax = Data((syntax + (syntax.utf8.count % 2 == 0 ? "" : "\0")).utf8)
        let sopClass = Data("1.2.840.10008.5.1.4.1.1.7\0".utf8)
        var metaBody = element(0x0002, 0x0002, "UI", sopClass)
        metaBody += element(0x0002, 0x0003, "UI", Data("2.25.1".utf8))
        metaBody += element(0x0002, 0x0010, "UI", syntax)
        var groupLength = UInt32(metaBody.count).littleEndian
        let meta = element(0x0002, 0x0000, "UL", Data(bytes: &groupLength, count: 4)) + metaBody
        var body = leading + element(0x0008, 0x0016, "UI", sopClass)
        body += element(0x0008, 0x0018, "UI", instanceUID)                           // empty by default
        body += accession
        body += element(0x0010, 0x0010, "PN", Data([0x4A, 0xE9, 0x5E, 0x42]))        // é, no Specific Character Set
        body += element(0x0011, 0x0010, "LO", Data("ISIS TEST ".utf8))
        body += element(0x0011, 0x1033, "DS", Data("1.23456789012345678 ".utf8))    // 20 bytes
        body += element(0x0028, 0x0002, "US", uint16(1))
        body += element(0x0028, 0x0004, "CS", Data("MONOCHROME2 ".utf8))
        body += element(0x0028, 0x0010, "US", uint16(2))
        body += element(0x0028, 0x0011, "US", uint16(2))
        body += element(0x0028, 0x0100, "US", uint16(16))
        body += element(0x0028, 0x0101, "US", uint16(16))
        body += element(0x0028, 0x0102, "US", uint16(15))
        body += element(0x0028, 0x0103, "US", uint16(0))
        body += extra
        body += pixelData
        return Data(count: 128) + Data("DICM".utf8) + meta + body
    }

    private static func uint16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }

    static func element(_ group: UInt16, _ number: UInt16, _ vr: String, _ value: Data) -> Data {
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

    /// Encapsulated Pixel Data: an empty Basic Offset Table, one fragment and the sequence delimiter.
    private static func encapsulated(fragment: Data) -> Data {
        var data = uint16(0x7FE0) + uint16(0x0010) + Data("OB".utf8) + Data(count: 2) + Data([0xFF, 0xFF, 0xFF, 0xFF])
        data += Data([0xFE, 0xFF, 0x00, 0xE0, 0, 0, 0, 0])
        var length = UInt32(fragment.count).littleEndian
        data += Data([0xFE, 0xFF, 0x00, 0xE0]) + Data(bytes: &length, count: 4) + fragment
        return data + Data([0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0])
    }

    private static func sequence(_ group: UInt16, _ number: UInt16, items: [Data]) -> Data {
        let content = items.reduce(into: Data()) { data, item in
            var length = UInt32(item.count).littleEndian
            data += Data([0xFE, 0xFF, 0x00, 0xE0]) + Data(bytes: &length, count: 4) + item
        }
        return element(group, number, "SQ", content)
    }
}
