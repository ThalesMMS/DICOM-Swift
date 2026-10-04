import Foundation
import Security

/// The certificate and private key a DICOMweb client presents to a server that asks for a client certificate (mutual
/// TLS). It is presented only to the client's configured origin.
///
/// Identities and certificates are immutable, so sharing them between tasks is safe.
public struct DicomWebClientIdentity: Hashable, @unchecked Sendable {
    public let identity: SecIdentity
    /// Intermediate certificates sent after the identity's own, without it.
    public let certificates: [SecCertificate]

    public init(identity: SecIdentity, certificates: [SecCertificate] = []) {
        self.identity = identity
        self.certificates = certificates
    }

    var credential: URLCredential {
        URLCredential(identity: identity, certificates: certificates.isEmpty ? nil : certificates, persistence: .none)
    }
}
