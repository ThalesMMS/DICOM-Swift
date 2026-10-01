import Foundation

/// What a TLS server asks of a caller's certificate.
///
/// There is no "verify if presented": Network.framework cannot request a
/// certificate without requiring one on Apple platforms
/// (`sec_protocol_options_set_peer_authentication_optional` is unavailable
/// there), and a server that does not request one never receives one.
public enum DicomTLSClientCertificatePolicy: String, Codable, Sendable, CaseIterable {
    /// No certificate is asked for; the caller is not authenticated by TLS.
    case notRequested
    /// A certificate is asked for and must chain to the server's trust anchors;
    /// a caller that presents none is refused.
    case required
}
