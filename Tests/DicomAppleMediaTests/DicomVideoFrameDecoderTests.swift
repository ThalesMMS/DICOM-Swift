import Foundation
import XCTest
import CoreVideo
@testable import DicomAppleMedia
import DicomCore

final class DicomVideoFrameDecoderTests: XCTestCase {
    static func video(_ name: String) throws -> DicomVideo {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DicomCoreTests/Fixtures/Video/" + name)
        let pixels = try DicomVideoPixelData(streamData: Data(contentsOf: url),
            transferSyntax: name.hasSuffix("hevc") ? .hevcH265MainProfileLevel51 : .mpeg4AVCH264HighProfileLevel41,
            columns: 128, rows: 64, numberOfFrames: 96, frameTimeMilliseconds: 1000 / 12)
        let region = DicomDataSet(elements: [
            .init(tag: 0x00080100, vr: .SH, value: .strings(["818981001"])),
            .init(tag: 0x00080102, vr: .SH, value: .strings(["SCT"])),
            .init(tag: 0x00080104, vr: .LO, value: .strings(["Abdomen"]))
        ])
        return try XCTUnwrap(DCMDecoder(data: DicomVideoBuilder.part10Data(video: pixels,
            options: .init(anatomicRegion: region))).video)
    }

    func test_barcodeFrames_matchTimelinePresentationOrder() async throws {
        for name in ["known-pframes.h264", "known-bframes.h264", "known-high-bframes.h264", "known-hevc.hevc"] {
            let video = try Self.video(name)
            let timeline = try DicomVideoTimeline(video: video)
            let frames = try await DicomVideoFrameDecoder.decode(video)
            XCTAssertEqual(frames.count, timeline.accessUnits.count)
            for frame in frames {
                let barcode = (0..<8).reduce(0) { value, bit in
                    value | (frame.bgra[(32 * 128 + bit * 16 + 8) * 4] > 128 ? 1 << bit : 0)
                }
                XCTAssertEqual(barcode, frame.presentationIndex, name)
                XCTAssertEqual(frame.width, 128)
                XCTAssertEqual(frame.height, 64)
                XCTAssertEqual(frame.bgra.count, 128 * 64 * 4)
            }
        }
    }

    func test_outputBudgetAndOpenGOP_refuseBeforeDecoding() async throws {
        do {
            _ = try await DicomVideoFrameDecoder.decode(Self.video("known-bframes.h264"), maximumOutputBytes: 1)
            XCTFail("Expected byte limit")
        } catch { XCTAssertEqual(error as? DicomVideoAppleError, .outputLimitExceeded) }
        do {
            _ = try await DicomVideoFrameDecoder.decode(Self.video("unsupported-open-gop.h264"))
            XCTFail("Expected profile refusal")
        } catch { XCTAssertNotNil(error as? DicomVideoAppleError) }
    }
}
