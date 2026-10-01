import DicomCore
import Foundation

func renderCapabilities() throws -> String {
    let capabilityReport = DicomCodecWorkflowEngine().capabilities()
    return try DicomCodecCanonicalRenderer.jsonString(capabilityReport)
}
