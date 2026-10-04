import Foundation

/// Where `DicomWebOIDCProvider` keeps tokens, one set per key (a node or account identifier the host chooses). The
/// host supplies it, for example over the Keychain; the provider never writes tokens anywhere else.
public protocol DicomWebOIDCTokenStore: Sendable {
    func tokens(forKey key: String) throws -> DicomWebOIDCTokenSet?
    func store(_ tokens: DicomWebOIDCTokenSet, forKey key: String) throws
    func deleteTokens(forKey key: String) throws
}
