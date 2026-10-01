public struct DicomSurfaceSegmentationReport: Equatable, Sendable {
    public let diagnostics: [DicomSurfaceSegmentationDiagnostic]
    public var isConsistent: Bool { diagnostics.isEmpty }
}
