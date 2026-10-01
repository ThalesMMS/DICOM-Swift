import Foundation
#if canImport(Network)
import Network
#endif

/// A listener can be replaced without changing DICOMweb routing or its injected providers.
public protocol DicomWebServerTransport: Sendable {
    func start() async throws -> URL
    func stop() async
}

#if canImport(Network)
/// Keeps the DIMSE TLS factory internal while sharing its verified policy with the optional HTTP product.
public enum DicomWebServerTLS {
    public static func parameters(_ configuration: DicomTLSConfiguration) throws -> NWParameters {
        try DicomTLSOptionsFactory.preparedParameters(for: configuration, role: .server).parameters
    }
}
#endif

public enum DicomWebHTTPBodyError: Error, Sendable {
    case payloadTooLarge
    case malformed
}
