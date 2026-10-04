import Foundation

/// The TLS choices of an origin policy that decide which connections a request may share.
struct DicomWebTLSChoice: Hashable, Sendable {
    var serverTrust: DicomWebServerTrust
    var clientIdentity: DicomWebClientIdentity?
}
