import Foundation

/// Qualifies concrete source objects, rather than assuming a codec registry entry is executable.
public protocol DicomStoreTranscoding: Sendable {
    func qualifiedTransferSyntaxes(for file: URL) async throws -> [DicomTransferSyntax]
    func transcode(_ file: URL, to syntax: DicomTransferSyntax) async throws -> Data
}

public enum DicomStoreRepresentationRefusal: LocalizedError, Equatable, Sendable {
    case noQualifiedRepresentation
    case invalidTranscodedIdentityOrSyntax

    public var errorDescription: String? {
        switch self {
        case .noQualifiedRepresentation: return "No qualified lossless or permitted representation was accepted."
        case .invalidTranscodedIdentityOrSyntax: return "Transcoded object changed SOP identity or transfer syntax."
        }
    }
}

public enum DicomStoreRepresentationPolicy: String, Sendable {
    case asReceived = "as-received"
    case lossless
    case any

    public func alternatives(stored: DicomTransferSyntax, qualified: [DicomTransferSyntax]) -> [DicomTransferSyntax] {
        guard self != .asReceived else { return [] }
        let losslessUIDs: Set<String> = [
            "1.2.840.10008.1.2", "1.2.840.10008.1.2.1", "1.2.840.10008.1.2.2",
            "1.2.840.10008.1.2.1.99", "1.2.840.10008.1.2.5", "1.2.840.10008.1.2.4.57",
            "1.2.840.10008.1.2.4.70", "1.2.840.10008.1.2.4.80", "1.2.840.10008.1.2.4.90",
            "1.2.840.10008.1.2.4.201", "1.2.840.10008.1.2.4.202"
        ]
        var seen: Set<String> = []
        return qualified.filter {
            $0 != stored && (self == .any || losslessUIDs.contains($0.rawValue)) && seen.insert($0.rawValue).inserted
        }
    }

    public func select(stored: DicomTransferSyntax, qualified: [DicomTransferSyntax],
                       accepted: [DicomTransferSyntax]) throws -> DicomTransferSyntax {
        if accepted.contains(stored) { return stored }
        guard let selected = alternatives(stored: stored, qualified: qualified).first(where: accepted.contains) else {
            throw DicomStoreRepresentationRefusal.noQualifiedRepresentation
        }
        return selected
    }
}

public struct DicomStoreObjectOutcome: Sendable {
    public struct Attempt: Sendable {
        public let transferSyntax: DicomTransferSyntax
        public let result: Result<DicomDIMSEOperationResult, any Error>
    }
    public let fileURL: URL
    public let sopInstanceUID: String?
    public let attempts: [Attempt]
    public let diagnostics: [String]
    public let result: Result<DicomDIMSEOperationResult, any Error>
    public var accepted: Bool {
        guard case .success(let response) = result else { return false }
        return response.status == 0 || response.status & 0xFF00 == 0xB000
    }
}
