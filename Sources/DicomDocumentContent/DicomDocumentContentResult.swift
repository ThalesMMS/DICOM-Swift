import Foundation

public struct DicomDocumentContentDiagnostic: Equatable, Sendable {
    public let code: String
    public let reason: String
    public let line: Int?

    public init(code: String, reason: String, line: Int? = nil) {
        self.code = code
        self.reason = reason
        self.line = line
    }
}

public struct DicomDocumentContentResult<Value: Sendable>: Sendable {
    public let value: Value?
    public let diagnostics: [DicomDocumentContentDiagnostic]
    public let limitations: [String]

    public init(value: Value?, diagnostics: [DicomDocumentContentDiagnostic] = [], limitations: [String]) {
        self.value = value
        self.diagnostics = diagnostics
        self.limitations = limitations
    }
}
