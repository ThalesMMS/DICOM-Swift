import Foundation

public struct DicomEncapsulatedDocumentDiagnostic: Equatable, Sendable {
    public enum Code: String, Sendable {
        case mimeMismatch, lengthMismatch, missingMIMEList, missingHL7Identifier, missingModelUnits
        case missingFrameOfReference, missingEquipment, modalityMismatch, invalidRelativeURI
    }
    public let code: Code
    public let reason: String

    public init(code: Code, reason: String) {
        self.code = code
        self.reason = reason
    }
}
