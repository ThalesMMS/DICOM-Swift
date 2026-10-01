import Foundation

public struct DicomSRTemplateValidationResult: Equatable, Sendable {
    public var errors: [DicomSRTemplateDiagnostic] = []
    public var limitations: [DicomSRTemplateDiagnostic] = []
    public var informational: [DicomSRTemplateDiagnostic] = []
    public var isValid: Bool { errors.isEmpty }

    public init() {}
}
