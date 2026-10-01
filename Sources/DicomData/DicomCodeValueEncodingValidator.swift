import Foundation

/// Checks selection of coded-entry value attributes. Lexical VR validation and
/// existence of the referenced terminology concept remain separate checks.
enum DicomCodeValueEncodingValidator {
    static func validate(_ element: DicomDataElement, encoding: DicomAttributeRule.CodeEncoding)
        -> (code: DicomValidationReport.Code, severity: DicomValidationReport.Severity)? {
        guard case .strings(let values) = element.value, values.count == 1 else {
            return (.attributeValueNotAllowed, .error)
        }
        let value = values[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
        let count = value.unicodeScalars.count
        let absoluteURI = value.range(of: "\\A[A-Za-z][A-Za-z0-9+.-]*:[^\\s]+\\z", options: .regularExpression) != nil
        switch encoding {
        case .shortCode:
            guard element.vr == .SH, count <= 16 else { return (.attributeValueNotAllowed, .error) }
            // PS3.3 8.1's size rule and Table 8.8-1a's URI exception disagree for short URIs.
            return absoluteURI ? (.conditionUndetermined, .limitation) : nil
        case .longCode:
            return element.vr == .UC && count > 16 && !absoluteURI ? nil : (.attributeValueNotAllowed, .error)
        case .urn:
            guard element.vr == .UR, absoluteURI else { return (.attributeValueNotAllowed, .error) }
            return count <= 16 ? (.conditionUndetermined, .limitation) : nil
        }
    }
}
