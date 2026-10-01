import DicomCore
import Foundation

func reportCapabilities() throws {
    let engine = DicomCodecWorkflowEngine()
    let capabilityReport = engine.capabilities()
    let availableBackends = capabilityReport.backends.filter(\.available)
    print(availableBackends.map(\.identifier))
}
