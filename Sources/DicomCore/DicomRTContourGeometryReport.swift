public struct DicomRTContourGeometryReport: Equatable, Sendable {
    public let diagnostics: [DicomRTContourGeometryDiagnostic]
    public let limitations: [DicomRTContourGeometryDiagnostic]
    public var isConsistent: Bool { diagnostics.isEmpty && limitations.isEmpty }

    public init(diagnostics: [DicomRTContourGeometryDiagnostic], limitations: [DicomRTContourGeometryDiagnostic]) {
        self.diagnostics = diagnostics
        self.limitations = limitations
    }
}
