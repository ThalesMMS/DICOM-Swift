import DicomCore
import Foundation

func inspect(_ data: Data) throws -> DicomCodecStructuredReport {
    let report = try DicomCodecWorkflowEngine().inspect(data)
    print(DicomCodecCanonicalRenderer.text(report))
    return report
}
