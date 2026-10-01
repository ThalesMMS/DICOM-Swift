import DicomCore
import Foundation

func compareFirstFrame(_ compressedData: Data) async throws -> DicomCodecStructuredReport {
    let report = try await DicomCodecWorkflowEngine().compare(compressedData, frameIndex: 0)
    if !report.success {
        print(DicomCodecCanonicalRenderer.text(report))
    }
    return report
}
