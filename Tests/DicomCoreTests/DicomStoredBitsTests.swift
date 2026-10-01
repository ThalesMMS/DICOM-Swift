import Foundation
import XCTest
@testable import DicomCore

/// Issue #2851 (PS3.5 8.1.1): a stored sample is Bits Stored bits ending at High Bit; any other bits of the
/// allocated word are ignored, and a signed sample takes its sign from its own top bit. GDCM, DCMTK and the
/// Data-backed path already read samples so; the typed frames did not.
final class DicomStoredBitsTests: XCTestCase {
    func test_unsignedTwelveBits_ignoreTheBitsAboveHighBit() throws {
        let stored = try samples(words: [0x0123, 0xF123, 0x8FFF, 0x7000], bitsStored: 12, highBit: 11, signed: false)
        XCTAssertEqual(stored, [0x0123, 0x0123, 0x0FFF, 0x0000])
    }

    func test_signedTwelveBits_takeTheSignFromBitEleven() throws {
        let stored = try samples(words: [0x3800, 0x07FF, 0xFFFF, 0x0801], bitsStored: 12, highBit: 11, signed: true)
        XCTAssertEqual(stored.map { Int16(bitPattern: $0) }, [-2048, 2047, -1, -2047])
    }

    func test_highBitAboveBitsStored_shiftsTheSampleDown() throws {
        let stored = try samples(words: [0x0AB0, 0xFAB5], bitsStored: 8, highBit: 11, signed: false)
        XCTAssertEqual(stored, [0x00AB, 0x00AB])
    }

    func test_wholeWordSamples_areUntouched() throws {
        let stored = try samples(words: [0x0000, 0xFFFF, 0x8000], bitsStored: 16, highBit: 15, signed: false)
        XCTAssertEqual(stored, [0x0000, 0xFFFF, 0x8000])
    }

    private func samples(words: [UInt16], bitsStored: Int, highBit: Int, signed: Bool) throws -> [UInt16] {
        let us = { (tag: DicomTag, value: Int) in
            DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([UInt(value)]))
        }
        let pixels = words.reduce(into: Data()) { data, word in
            data.append(UInt8(word & 0xFF)); data.append(UInt8(word >> 8))
        }
        let dataSet = DicomDataSet(elements: [
            .init(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            .init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.2851"])),
            us(.samplesPerPixel, 1),
            .init(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["MONOCHROME2"])),
            us(.rows, 1), us(.columns, words.count), us(.bitsAllocated, 16), us(.bitsStored, bitsStored),
            us(.highBit, highBit), us(.pixelRepresentation, signed ? 1 : 0),
            .init(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(pixels))
        ])
        let reader = try DicomDecodedFrameReader(dataSet: dataSet, options: .init(transferSyntax: .explicitVRLittleEndian))
        let data = try reader.frame(at: 0).storedSampleData()
        return stride(from: 0, to: data.count, by: 2).map { UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8 }
    }
}
