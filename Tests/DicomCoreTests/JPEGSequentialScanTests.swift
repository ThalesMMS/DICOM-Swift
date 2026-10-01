import Foundation
import XCTest
@testable import DicomCore
@testable import DicomJPEG

final class JPEGSequentialScanTests: XCTestCase {
    func test_separateAndMixedScansMatchInterleavedAtEveryScale() throws {
        let manifest = try fixture("JPEGSequentialScans", extension: "json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 12)
        for entry in cases {
            let name = try XCTUnwrap(entry["name"] as? String)
            let reference = try XCTUnwrap(entry["reference"] as? String)
            if name == reference { continue }
            for scale in [1, 2, 4, 8] {
                let config = JLIDecoderConfiguration(outputPixelFormat: .uint8, outputColorModel: .rgb, scale: scale)
                let expected = try JLIDecoder().decode(from: Array(fixture(reference)), configuration: config)
                XCTAssertNoThrow(try {
                    let actual = try JLIDecoder().decode(from: Array(fixture(name)), configuration: config)
                    XCTAssertEqual(actual.width, expected.width)
                    XCTAssertEqual(actual.height, expected.height)
                    XCTAssertEqual(actual.data, expected.data, "\(name), scale \(scale)")
                }(), "\(name), scale \(scale)")
            }
        }
    }

    func test_DICOMBaselineAndEightBitExtendedDecodeEverySequentialLayout() throws {
        for suffix in ["separate", "mixed_y", "mixed_ycb"] {
            for syntax in [DicomTransferSyntax.jpegBaseline, .jpegExtended] {
                var jpeg = try fixture("sequential_2x2_\(suffix)")
                if syntax == .jpegExtended {
                    let sof = try XCTUnwrap(jpeg.range(of: Data([0xFF, 0xC0])))
                    jpeg[sof.lowerBound + 1] = 0xC1
                }
                let descriptor = DicomCompressedFrameDescriptor(
                    transferSyntaxUID: syntax.rawValue, rows: 19, columns: 17,
                    bitsAllocated: 8, bitsStored: 8, highBit: 7, pixelRepresentation: 0,
                    samplesPerPixel: 3, photometricInterpretation: "YBR_FULL_422", planarConfiguration: 0)
                let expected = try JLIDecoder().decode(from: Array(fixture("sequential_2x2_interleaved")))
                let actual = try DicomJPEGSwiftBackend.decodeSynchronously(jpeg, descriptor: descriptor)
                XCTAssertEqual(actual.buffer.data, Data(expected.data), "\(suffix), \(syntax)")
            }
        }
    }

    func test_incompleteDuplicateUnknownAndInvalidSequentialScansFailTyped() throws {
        let jpeg = try fixture("sequential_2x2_separate")
        let offsets = (0..<(jpeg.count - 1)).filter { jpeg[$0] == 0xFF && jpeg[$0 + 1] == 0xDA }
        XCTAssertEqual(offsets.count, 3)
        let last = try XCTUnwrap(offsets.last)
        let incomplete = Data(jpeg.prefix(last)) + Data([0xFF, 0xD9])
        var duplicate = jpeg
        duplicate[offsets[1] + 5] = jpeg[offsets[0] + 5]
        var unknown = jpeg
        unknown[offsets[0] + 5] = 99
        var invalid = jpeg
        invalid[offsets[0] + 7] = 1 // Sequential scans must start at DC (Ss=0).
        for (name, bytes) in [("incomplete", incomplete), ("duplicate", duplicate),
                              ("unknown", unknown), ("spectral selection", invalid)] {
            XCTAssertThrowsError(try JLIDecoder().decode(from: Array(bytes)), name) { error in
                guard case JLIError.decodingFailed = error else { return XCTFail("\(name): \(error)") }
            }
        }
    }

    private func fixture(_ name: String, extension ext: String = "jpg") throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext)))
    }
}
