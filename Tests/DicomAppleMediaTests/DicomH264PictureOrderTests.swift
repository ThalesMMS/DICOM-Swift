import Foundation
import XCTest
@testable import DicomAppleMedia

final class DicomH264PictureOrderTests: XCTestCase {
    func test_pocWrap_usesPreviousReferencePictureAcrossNonReferenceBFrames() throws {
        let pictures: [(Int, Bool)] = [
            (0, true), (6, true), (2, false), (4, false), (12, true), (8, false), (10, false),
            (2, true), (14, false), (0, false), (8, true), (4, false), (6, false)
        ]
        XCTAssertEqual(try order(pictures), [0, 3, 1, 2, 6, 4, 5, 9, 7, 8, 12, 10, 11])
    }

    func test_halfRangeBoundary_usesAsymmetricWrapComparisons() throws {
        XCTAssertEqual(try order([
            (0, true), (8, true), (2, false), (4, false), (6, false),
            (0, true), (10, false), (12, false), (14, false)
        ]), [0, 4, 1, 2, 3, 8, 5, 6, 7])
    }

    func test_secondIDR_resetsPictureOrderAndKeepsGlobalPresentationIndices() throws {
        let group = [slice(0, reference: true, idr: true), slice(4, reference: true), slice(2, reference: false)]
        XCTAssertEqual(try parse([sps(), pps()] + group + group, count: 6), [0, 2, 1, 3, 5, 4])
    }

    func test_invalidOrUnqualifiedHeaders_areRejected() throws {
        let idr = slice(0, reference: true, idr: true)
        let p = slice(4, reference: true)
        let b = slice(2, reference: false)
        let valid = [sps(), pps(), idr, p, b]
        let variants: [[Data]] = [
            [sps(), pps(), p, b], // Missing initial IDR.
            valid + [b], // Duplicate picture order.
            [sps(), pps(), idr, p], // Missing display picture.
            [sps(), pps(), idr, slice(4, reference: true, adaptiveMarking: true), b],
            [sps(), pps(), idr, slice(4, reference: true, firstMacroblock: 1), b],
            [sps(), pps(), idr, slice(4, reference: true, pictureID: 1), b],
            valid + [sps() + Data([1])], // Changing parameters midstream.
            valid + [pps() + Data([1])],
            [Data(sps().prefix(2)), pps(), idr, p, b],
            [sps(), Data(pps().prefix(1)), idr, p, b],
            [sps(), pps(), idr, Data([0x01, 0]), b], // Truncated Exp-Golomb code.
            valid + [Data([0x74, 0x80])] // Unqualified extension NAL.
        ]
        for (index, units) in variants.enumerated() {
            XCTAssertThrowsError(try parse(units, count: 3), "Variant \(index)") { error in
                XCTAssertEqual(error as? DicomVideoRemuxError, .frameReorderingUnsupported(codec: .h264))
            }
        }
        XCTAssertThrowsError(try parse(valid, count: 2))
    }

    private func order(_ pictures: [(Int, Bool)]) throws -> [Int] {
        let slices = pictures.enumerated().map { index, picture in
            slice(picture.0, reference: picture.1, idr: index == 0)
        }
        return try parse([sps(), pps()] + slices, count: slices.count)
    }

    private func parse(_ units: [Data], count: Int) throws -> [Int] {
        try DicomH264PictureOrder.presentationIndices(nalUnits: units, accessUnitCount: count)
    }

    private func sps() -> Data {
        var bits = HeaderBits()
        bits.put(77, width: 8)
        bits.put(0, width: 8)
        bits.put(41, width: 8)
        bits.ue(0) // SPS id
        bits.ue(0) // Four frame_num bits
        bits.ue(0) // POC type 0
        bits.ue(0) // Four POC LSB bits
        bits.ue(2) // Reference frames
        bits.put(0, width: 1) // No gaps
        bits.ue(7)
        bits.ue(3)
        bits.put(1, width: 1) // Progressive
        bits.put(1, width: 1) // Direct 8x8 inference
        bits.put(0, width: 2) // No cropping or VUI
        return bits.nal(header: 0x67)
    }

    private func pps() -> Data {
        var bits = HeaderBits()
        bits.ue(0)
        bits.ue(0)
        bits.put(0, width: 2) // CAVLC, no bottom-field POC delta
        bits.ue(0) // No slice groups
        bits.ue(0)
        bits.ue(0)
        bits.put(0, width: 3) // No weighted prediction
        bits.ue(0)
        bits.ue(0)
        bits.ue(0)
        bits.put(0, width: 3) // No deblocking, constrained intra, or redundant count
        return bits.nal(header: 0x68)
    }

    private func slice(
        _ lsb: Int, reference: Bool, idr: Bool = false,
        adaptiveMarking: Bool = false, firstMacroblock: Int = 0, pictureID: Int = 0
    ) -> Data {
        var bits = HeaderBits()
        bits.ue(firstMacroblock)
        bits.ue(idr ? 2 : reference ? 0 : 1)
        bits.ue(pictureID)
        bits.put(idr ? 0 : 1, width: 4)
        if idr { bits.ue(0) }
        bits.put(lsb, width: 4)
        if !reference { bits.put(1, width: 1) }
        if !idr {
            bits.put(0, width: 1) // No active reference override
            bits.put(0, width: reference ? 1 : 2) // No reference-list modification
        }
        if reference {
            bits.put(adaptiveMarking ? 1 : 0, width: idr ? 2 : 1)
        }
        bits.ue(0) // Slice QP delta; no encoded pixels in these header-only unit fixtures.
        return bits.nal(header: idr ? 0x65 : reference ? 0x41 : 0x01)
    }

    private struct HeaderBits {
        var values: [Int] = []

        mutating func put(_ value: Int, width: Int) {
            for bit in (0..<width).reversed() { values.append((value >> bit) & 1) }
        }

        mutating func ue(_ value: Int) {
            let width = Int.bitWidth - (value + 1).leadingZeroBitCount
            put(0, width: width - 1)
            put(value + 1, width: width)
        }

        func nal(header: UInt8) -> Data {
            var padded = values + [1]
            while padded.count % 8 != 0 { padded.append(0) }
            var bytes = [header]
            var zeros = 0
            for offset in stride(from: 0, to: padded.count, by: 8) {
                let byte = UInt8(padded[offset..<(offset + 8)].reduce(0) { ($0 << 1) | $1 })
                if zeros == 2, byte <= 3 { bytes.append(3); zeros = 0 }
                bytes.append(byte)
                zeros = byte == 0 ? zeros + 1 : 0
            }
            return Data(bytes)
        }
    }
}
