import Foundation

/// Supplies the credential headers of every request a `DicomWebClient` sends to its configured origin.
///
/// The client asks for the headers before each request, so a provider can hand out a token that changes over time.
/// When the server answers 401, the client calls `renewAuthorization(afterRejecting:)` with the headers the refused
/// request carried. If that returns true, the client sends the request once more with fresh headers; a second 401, or
/// a provider that cannot renew, ends the request with the 401 `DicomWebError`. Headers never go to a BulkDataURI
/// origin other than the configured one.
///
/// `DicomWebAuthentication` is the provider of a fixed credential, which never renews.
public protocol DicomWebAuthorizationProvider: Sendable {
    /// The headers for the next request; empty sends none.
    func authorizationHeaders() async throws -> [String: String]

    /// Called once after a 401 to a request that carried `rejected`. True asks the client to repeat the request with
    /// `authorizationHeaders()`; false leaves the 401 as the request's outcome.
    func renewAuthorization(afterRejecting rejected: [String: String]) async throws -> Bool
}

extension DicomWebAuthentication: DicomWebAuthorizationProvider {
    /// The validated header of this mode, or none for `.none`.
    public func authorizationHeaders() throws -> [String: String] {
        guard let header = try header() else { return [:] }
        return [header.name: header.value]
    }

    /// A fixed credential cannot be renewed.
    public func renewAuthorization(afterRejecting _: [String: String]) -> Bool { false }
}
