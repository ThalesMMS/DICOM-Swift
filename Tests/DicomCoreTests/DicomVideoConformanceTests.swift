import Foundation
import XCTest
@testable import DicomCore

/// PS3.5 §8.2 profile, level and Blu-ray format of each video transfer syntax (issue #2905): one warning per
/// violation with the found and expected values, never a rejection.
final class DicomVideoConformanceTests: XCTestCase {
    private static func description(_ name: String) throws -> DicomVideoStreamDescription {
        let codec: DicomVideoCodec = name.hasSuffix(".m2v") ? .mpeg2 : name.hasSuffix(".hevc") ? .hevc : .h264
        return try DicomVideoStreamInspector.inspect(
            try DicomVideoStreamInspectorTests.fixture("Conformance/" + name), codec: codec)
    }

    func test_eachVideoSyntax_warnsOnlyOnStreamsOutsideItsProfileLevelAndFormat() throws {
        // (syntax, fixture, expected detail fragments; empty means conformant)
        let cases: [(DicomTransferSyntax, String, [String])] = [
            (.mpeg2MainProfileMainLevel, "mpeg2-mp-ll.m2v", []),
            (.mpeg2MainProfileMainLevel, "mpeg2-mp-ml.m2v", []),
            (.mpeg2MainProfileMainLevel, "mpeg2-mp-hl.m2v", ["MPEG-2 level High, expected at most Main Level"]),
            (.mpeg2MainProfileMainLevelFragmentable, "mpeg2-hp-hl.m2v",
             ["MPEG-2 profile High, expected Main", "MPEG-2 level High, expected at most Main Level"]),
            (.mpeg2MainProfileHighLevel, "mpeg2-mp-ll.m2v", []),
            (.mpeg2MainProfileHighLevel, "mpeg2-mp-ml.m2v", []),
            (.mpeg2MainProfileHighLevel, "mpeg2-mp-hl.m2v", []),
            (.mpeg2MainProfileHighLevelFragmentable, "mpeg2-hp-hl.m2v", ["MPEG-2 profile High, expected Main"]),
            (.mpeg4AVCH264HighProfileLevel41, "h264-high-41.h264", []),
            (.mpeg4AVCH264HighProfileLevel41, "h264-high-42.h264",
             ["H.264 level 4.2 (level_idc 42), expected at most 4.1"]),
            (.mpeg4AVCH264HighProfileLevel41Fragmentable, "h264-main-41.h264",
             ["H.264 profile Main (77), expected High (100)"]),
            (.mpeg4AVCH264BDCompatibleHighProfileLevel41, "h264-bd-720p50.h264", []),
            (.mpeg4AVCH264BDCompatibleHighProfileLevel41Fragmentable, "h264-high-41.h264",
             ["Blu-ray format 128x64 at 25.000 frames/s progressive, expected 1920x1080"]),
            (.mpeg4AVCH264HighProfileLevel42For2DVideo, "h264-high-42.h264", []),
            (.mpeg4AVCH264HighProfileLevel42For2DVideo, "h264-high-51.h264",
             ["H.264 level 5.1 (level_idc 51), expected at most 4.2"]),
            (.mpeg4AVCH264HighProfileLevel42For3DVideoFragmentable, "h264-high-42.h264", []),
            (.mpeg4AVCH264HighProfileLevel42For3DVideo, "h264-high-51.h264",
             ["H.264 level 5.1 (level_idc 51), expected at most 4.2"]),
            (.mpeg4AVCH264StereoHighProfileLevel42, "h264-high-42.h264", []),
            (.mpeg4AVCH264StereoHighProfileLevel42Fragmentable, "h264-main-41.h264",
             ["H.264 profile Main (77), expected High (100) or Stereo High (128)"]),
            (.hevcH265MainProfileLevel51, "hevc-main-51.hevc", []),
            (.hevcH265MainProfileLevel51, "hevc-main-62.hevc", ["HEVC level 6.2 (level_idc 186), expected at most 5.1"]),
            (.hevcH265MainProfileLevel51, "hevc-main10-51.hevc", ["HEVC profile Main 10 (2), expected Main (1)"]),
            (.hevcH265Main10ProfileLevel51, "hevc-main10-51.hevc", []),
            (.hevcH265Main10ProfileLevel51, "hevc-main-51.hevc", []),
            (.hevcH265Main10ProfileLevel51, "hevc-main-62.hevc", ["HEVC level 6.2 (level_idc 186), expected at most 5.1"])
        ]
        for (syntax, name, expected) in cases {
            let details = DicomVideoConformance.violations(of: syntax, in: try Self.description(name)).map(\.detail)
            XCTAssertEqual(details.count, expected.count, "\(syntax.rawValue) \(name): \(details)")
            for (detail, fragment) in zip(details, expected) {
                XCTAssertTrue(detail.hasPrefix(fragment), "\(syntax.rawValue) \(name): \(detail)")
            }
        }
    }

    func test_validator_reportsViolationsAsWarningsWithoutFailingTheCodestream() throws {
        let stream = try DicomVideoStreamInspectorTests.fixture("Conformance/h264-high-51.h264")
        let pixels = try DicomVideoPixelData(fragments: [stream], transferSyntax: .mpeg4AVCH264HighProfileLevel41,
                                             columns: 128, rows: 64, numberOfFrames: 4, frameTimeMilliseconds: 40)
        let report = try DicomInstanceValidator.validate(try DicomVideoBuilder.part10Data(video: pixels))
        let warnings = report.diagnostics.filter { $0.code == .videoBitstreamConstraintViolation }
        XCTAssertEqual(warnings.map(\.severity), [.warning])
        XCTAssertEqual(warnings.first?.detail, "H.264 level 5.1 (level_idc 51), expected at most 4.1")
        XCTAssertEqual(report[.codestream], .passed, "\(report.diagnostics)")
    }
}
