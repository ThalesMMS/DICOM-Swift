import DicomCore
import Foundation

func transcodeAndPersist(_ part10Data: Data, to destinationURL: URL) async throws {
    let result = try await DicomCodecWorkflowEngine().transcode(
        part10Data,
        to: .implicitVRLittleEndian,
        intent: .reversible,
        verifyDecodedPixels: true
    )
    guard result.report.success,
          result.report.artifact?.validationPassed == true,
          result.report.artifact?.comparisonPassed == true else {
        throw DicomCodecWorkflowError.artifactValidation(
            reason: "The generated Part 10 artifact did not pass verification."
        )
    }
    try result.data.write(to: destinationURL, options: .atomic)
}
