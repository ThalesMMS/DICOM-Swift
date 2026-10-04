import Foundation

/// A WADO-RS Accept that asks for Implicit VR Little Endian. PS3.18 does not list it among the transfer syntaxes of
/// `application/dicom`, and this package's server refuses it.
public struct DicomWebImplicitVRAcceptError: Error, Equatable, Sendable, LocalizedError {
    public init() {}

    public var errorDescription: String? {
        "WADO-RS does not offer Implicit VR Little Endian (1.2.840.10008.1.2). Ask for Explicit VR Little Endian "
            + "(1.2.840.10008.1.2.1) or for the objects as stored (*)."
    }
}
