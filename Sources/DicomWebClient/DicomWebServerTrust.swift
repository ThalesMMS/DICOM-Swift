import CryptoKit
import Foundation
import Security

/// How a DICOMweb client decides to trust an HTTPS server's certificate.
///
/// `system` keeps the platform's evaluation. The other choices only add trust: a certificate the system already
/// trusts is still accepted, and the server's host name and the certificates' validity dates are always checked.
/// The added trust covers the origins the client's origin policy lets it reach, never another host.
///
/// Certificates are immutable, so sharing them between tasks is safe.
public struct DicomWebServerTrust: Hashable, @unchecked Sendable {
    enum Rule: Hashable {
        case system
        case anchors([SecCertificate])
        case leafCertificateSHA256(Data)
    }

    let rule: Rule

    /// The platform's evaluation only.
    public static let system = DicomWebServerTrust(rule: .system)

    /// Also trusts a chain that ends at one of `certificates`, such as a private CA's or a self-signed server's.
    public static func anchors(_ certificates: [SecCertificate]) -> DicomWebServerTrust {
        .init(rule: .anchors(certificates))
    }

    /// Also trusts the server whose leaf certificate has this SHA-256 digest of its DER encoding, with that
    /// certificate as the only anchor of its chain. A digest of any other length never matches.
    public static func leafCertificateSHA256(_ digest: Data) -> DicomWebServerTrust {
        .init(rule: .leafCertificateSHA256(digest))
    }

    /// `trust` evaluated again with the added anchors for `host`, when they make it trusted; nil when this choice
    /// adds nothing, and the system's own evaluation decides.
    func evaluated(_ trust: SecTrust, host: String) -> SecTrust? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return nil
        }
        let anchors: [SecCertificate], anchorsOnly: Bool
        switch rule {
        case .system:
            return nil
        case .anchors(let certificates):
            guard !certificates.isEmpty else { return nil }
            (anchors, anchorsOnly) = (certificates, false)
        case .leafCertificateSHA256(let digest):
            guard Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)) == digest else { return nil }
            (anchors, anchorsOnly) = ([leaf], true)
        }
        var evaluated: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, host as CFString),
                                             &evaluated) == errSecSuccess,
              let evaluated, SecTrustSetAnchorCertificates(evaluated, anchors as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(evaluated, anchorsOnly) == errSecSuccess,
              SecTrustEvaluateWithError(evaluated, nil) else { return nil }
        return evaluated
    }
}
