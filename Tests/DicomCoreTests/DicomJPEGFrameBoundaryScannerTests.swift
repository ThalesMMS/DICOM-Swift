import Foundation
import XCTest
@testable import DicomCore

@MainActor
final class DicomJPEGFrameBoundaryScannerTests: XCTestCase {
    func test_jpegLSMarkers_splitAtEveryWordRespectStuffBitsAndAPPValues() async throws {
        let frame = markerFrame(sof: 0xF7, entropy: [0xFF, 0x7F, 0xD9, 0xFF, 0, 1])
        let bytes = encapsulate([frame, frame])
        let source = DicomByteSource(data: bytes, limits: .init(maximumReadBytes: 8))
        let descriptor = try await DicomEncapsulatedPixelDataParser().parse(
            source: source, pixelDataRange: 0..<bytes.count, numberOfFrames: 2, transferSyntax: .jpegLSLossless
        )
        XCTAssertEqual(descriptor.frameFragmentIndexes.map(\.count), [frame.count / 2, frame.count / 2])
        XCTAssertEqual(descriptor.frame(0, in: bytes)?.data, frame)
        XCTAssertEqual(descriptor.frame(1, in: bytes)?.data, frame)
    }

    func test_jpegDoesNotTreatJPEG_LSStuffBitsAsValidEntropy() async throws {
        let frame = markerFrame(sof: 0xC0, entropy: [0xFF, 0x7F, 0xD9, 0xFF, 0, 1])
        let bytes = encapsulate([frame, frame])
        let source = DicomByteSource(data: bytes)
        do {
            _ = try await DicomEncapsulatedPixelDataParser().parse(
                source: source, pixelDataRange: 0..<bytes.count, numberOfFrames: 2, transferSyntax: .jpegBaseline
            )
            XCTFail("JPEG-LS stuffing accepted as JPEG entropy")
        } catch { XCTAssertEqual(error as? DicomSourceFrameIndex.Failure, .ambiguousFrameBoundaries) }
    }

    func test_boundaryScanBudget_rejectsWithoutReadingAnyFragmentPayload() async throws {
        let frame = markerFrame(sof: 0xC0, entropy: [0xFF, 0, 0xD9, 1])
        let bytes = encapsulate([frame, frame])
        let source = DicomByteSource(data: bytes)
        do {
            _ = try await DicomEncapsulatedPixelDataParser().parse(
                source: source, pixelDataRange: 0..<bytes.count, numberOfFrames: 2, transferSyntax: .jpegBaseline,
                maximumBoundaryScanBytes: 0
            )
            XCTFail("Boundary scan budget ignored")
        } catch { XCTAssertEqual(error as? DicomSourceFrameIndex.Failure, .boundaryScanLimit) }
        let metrics = await source.metrics
        XCTAssertEqual(metrics.receivedBytes, 16 + frame.count * 8)
    }

    private func markerFrame(sof: UInt8, entropy: [UInt8]) -> Data {
        var data = Data([0xFF, 0xD8, 0xFF, 0xEF, 0, 6, 0xFF, 0xD9, 0xFF, 0xD8])
        data.append(contentsOf: [0xFF, sof, 0, 11, 8, 0, 1, 0, 1, 1, 1, 0x11, 0])
        data.append(contentsOf: [0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 0, 0])
        data.append(contentsOf: entropy)
        data.append(contentsOf: [0xFF, 0xD9])
        if data.count % 2 != 0 { data.append(0) }
        return data
    }

    private func encapsulate(_ frames: [Data]) -> Data {
        var data = Data([0xFE, 0xFF, 0, 0xE0, 0, 0, 0, 0])
        for frame in frames {
            for offset in stride(from: 0, to: frame.count, by: 2) {
                data.append(contentsOf: [0xFE, 0xFF, 0, 0xE0, 2, 0, 0, 0])
                data.append(frame.subdata(in: offset..<(offset + 2)))
            }
        }
        data.append(contentsOf: [0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0])
        return data
    }
}
