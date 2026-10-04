import Foundation

/// The members of an OpenID Provider discovery document the sign-in uses.
struct DicomWebOIDCProviderMetadata: Decodable, Sendable {
    let issuer: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let jwksURI: URL
    let codeChallengeMethodsSupported: [String]
    let idTokenSigningAlgValuesSupported: [String]

    private enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case jwksURI = "jwks_uri"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case idTokenSigningAlgValuesSupported = "id_token_signing_alg_values_supported"
    }
}
