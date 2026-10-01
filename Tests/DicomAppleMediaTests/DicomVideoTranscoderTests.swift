import Foundation
import XCTest
import DicomCore
@testable import DicomAppleMedia

final class DicomVideoTranscoderTests: XCTestCase {
    func test_transcode_roundTripsEnvelopeAndIndependentFrameCount() async throws {
        for profile in [DicomVideoTranscoder.Profile.h264High, .hevcMain] {
            let video = try DicomVideoFrameDecoderTests.video("known-bframes.h264")
            let bytes = try await DicomVideoTranscoder.transcode(video, to: profile,
                options: .init(patientName: "Video^Synthetic", patientID: "VIDEO", studyID: "2349",
                    studyDate: "20260910", studyTime: "120000", seriesNumber: 1, instanceNumber: 1))
            let decoded = try XCTUnwrap(DCMDecoder(data: bytes).video)
            XCTAssertEqual(decoded.numberOfFrames, 96)
            XCTAssertEqual(decoded.lossyImageCompression, "01")
            let facts = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied, nonBipedalAnatomy: .unsatisfied,
                pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied, calibratedImage: .unsatisfied,
                imagingSubjectIsSpecimen: .unsatisfied, frameLevelRetrieveResponse: .unsatisfied)
            let report = try DicomInstanceValidator.validate(bytes, imageConditions: facts)
            XCTAssertEqual(report.outcome(requiring: Set(DicomValidationReport.Layer.allCases.filter { $0 != .operation })),
                .passed, "\(report.diagnostics)")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + (profile == .h264High ? ".h264" : ".hevc"))
            defer { try? FileManager.default.removeItem(at: url) }
            try decoded.streamData.write(to: url)
            guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffprobe") else {
                throw XCTSkip("ffprobe absent; native round-trip completed")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
            process.arguments = ["-v", "error", "-count_frames", "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", url.path]
            let pipe = Pipe(); process.standardOutput = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "96")
        }
    }
}
