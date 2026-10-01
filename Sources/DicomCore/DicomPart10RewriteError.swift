import Foundation

/// Failures raised when a Part 10 rewrite cannot prove its preservation guarantees.
public enum DicomPart10RewriteError: Error, Equatable, Sendable {
    /// The source has no recognized transfer syntax.
    case unsupportedTransferSyntax(String)
    /// The requested element is owned by Part 10 or the pixel structure.
    case disallowedElement(tag: Int)
    /// Pixel Data exists but its complete original value cannot be recovered.
    case pixelDataUnavailable
    /// One or more properties changed while the file was reserialized.
    case preservationFailed([DicomPart10PreservationFailure])
    /// UI values changed at one or more dataset paths after reopening.
    case uidRoundTripFailed
    /// An original UID requested for replacement remains after reopening.
    case replacedUIDRemains
    /// An edited element did not retain its exact requested VR and value.
    case editRoundTripFailed(tag: Int)
}

extension DicomPart10RewriteError: LocalizedError {
    /// A PHI-free description suitable for diagnostics.
    public var errorDescription: String? {
        switch self {
        case .unsupportedTransferSyntax(let uid):
            return uid.isEmpty
                ? "The source transfer syntax is missing or unsupported."
                : "The source transfer syntax \(uid) is unsupported."
        case .disallowedElement(let tag):
            return String(format: "Element %08X cannot be changed by a safe metadata rewrite.", tag)
        case .pixelDataUnavailable:
            return "The original Pixel Data value could not be recovered safely."
        case .preservationFailed(let fields):
            return "The rewritten file changed: \(fields.map(Self.failureDescription).joined(separator: ", "))."
        case .uidRoundTripFailed:
            return "Reopened Part 10 UID values differ from the requested exact map."
        case .replacedUIDRemains:
            return "A replaced UID remains in the reopened Part 10 dataset."
        case .editRoundTripFailed(let tag):
            return String(format: "Element %08X did not round-trip with its requested VR and value.", tag)
        }
    }

    private static func failureDescription(_ failure: DicomPart10PreservationFailure) -> String {
        switch failure {
        case .transferSyntax:
            return "TransferSyntaxUID"
        case .sopClassUID:
            return "SOPClassUID"
        case .mediaStorageSOPClassUID:
            return "MediaStorageSOPClassUID"
        case .mediaStorageSOPInstanceUID:
            return "MediaStorageSOPInstanceUID"
        case .pixelData(let beforeByteCount, let afterByteCount):
            return "PixelData length \(beforeByteCount ?? -1)->\(afterByteCount ?? -1)"
        }
    }
}
