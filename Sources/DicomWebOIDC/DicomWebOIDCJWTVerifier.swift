import CryptoKit
import Foundation
import Security

/// Verifies an OpenID Connect ID token: an RS256 or ES256 signature by a key of the provider's JWKS, the issuer,
/// audience and authorized party, expiry and issue time, the nonce and, when present, the access-token hash.
enum DicomWebOIDCJWTVerifier {
    /// The token names a `kid` the key set does not have: the provider may have rotated its keys.
    struct UnknownKeyID: Error {}

    private struct Header: Decodable {
        let alg: String
        let kid: String?
    }

    private struct Claims: Decodable {
        let issuer: String
        let audience: Audience
        let subject: String
        let expiration: TimeInterval
        let issuedAt: TimeInterval?
        let nonce: String?
        let accessTokenHash: String?
        let authorizedParty: String?

        private enum CodingKeys: String, CodingKey {
            case issuer = "iss"
            case audience = "aud"
            case subject = "sub"
            case expiration = "exp"
            case issuedAt = "iat"
            case nonce
            case accessTokenHash = "at_hash"
            case authorizedParty = "azp"
        }
    }

    private enum Audience: Decodable {
        case one(String)
        case many([String])

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .one(value)
            } else {
                self = .many(try container.decode([String].self))
            }
        }

        func contains(_ value: String) -> Bool {
            switch self {
            case .one(let audience): return audience == value
            case .many(let audiences): return audiences.contains(value)
            }
        }

        var count: Int {
            switch self {
            case .one: return 1
            case .many(let audiences): return audiences.count
            }
        }
    }

    private struct JWKSet: Decodable {
        let keys: [JWK]
    }

    private struct JWK: Decodable {
        let keyType: String
        let keyID: String?
        let use: String?
        let algorithm: String?
        let modulus: String?
        let exponent: String?
        let curve: String?
        let x: String?
        let y: String?

        private enum CodingKeys: String, CodingKey {
            case keyType = "kty"
            case keyID = "kid"
            case use
            case algorithm = "alg"
            case modulus = "n"
            case exponent = "e"
            case curve = "crv"
            case x
            case y
        }
    }

    static func verify(
        idToken: String,
        accessToken: String,
        jwksData: Data,
        configuration: DicomWebOIDCConfiguration,
        nonce: String,
        now: Date = Date()
    ) throws {
        let segments = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let headerData = Data(dicomWebBase64URLEncoded: String(segments[0])),
              let claimsData = Data(dicomWebBase64URLEncoded: String(segments[1])),
              let signature = Data(dicomWebBase64URLEncoded: String(segments[2])),
              let header = try? JSONDecoder().decode(Header.self, from: headerData),
              let claims = try? JSONDecoder().decode(Claims.self, from: claimsData),
              let jwks = try? JSONDecoder().decode(JWKSet.self, from: jwksData) else {
            throw DicomWebOIDCError.invalidIDToken
        }

        guard ["RS256", "ES256"].contains(header.alg),
              claims.issuer == configuration.issuerURL,
              claims.audience.contains(configuration.clientID),
              !claims.subject.isEmpty,
              claims.expiration > now.timeIntervalSince1970,
              let issuedAt = claims.issuedAt,
              issuedAt <= now.timeIntervalSince1970 + 60,
              claims.authorizedParty == nil || claims.authorizedParty == configuration.clientID,
              claims.audience.count == 1 || claims.authorizedParty == configuration.clientID,
              Data.dicomWebConstantTimeEqual(claims.nonce ?? "", nonce) else {
            throw DicomWebOIDCError.invalidIDToken
        }

        if let accessTokenHash = claims.accessTokenHash {
            let digest = SHA256.hash(data: Data(accessToken.utf8))
            let digestBytes = Array(digest)
            let expected = Data(digestBytes.prefix(digestBytes.count / 2))
                .dicomWebBase64URLEncodedString()
            guard Data.dicomWebConstantTimeEqual(accessTokenHash, expected) else {
                throw DicomWebOIDCError.invalidIDToken
            }
        }

        if let keyID = header.kid, !jwks.keys.contains(where: { $0.keyID == keyID }) {
            throw UnknownKeyID()
        }
        let candidates = jwks.keys.filter { key in
            (header.kid == nil || key.keyID == header.kid) &&
                (key.use == nil || key.use == "sig") &&
                (key.algorithm == nil || key.algorithm == header.alg)
        }
        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        guard candidates.contains(where: { key in
            verify(signature: signature, message: signingInput, header: header, key: key)
        }) else {
            throw DicomWebOIDCError.invalidIDToken
        }
    }

    private static func verify(signature: Data, message: Data, header: Header, key: JWK) -> Bool {
        switch (header.alg, key.keyType) {
        case ("RS256", "RSA"):
            return verifyRSA(signature: signature, message: message, key: key)
        case ("ES256", "EC"):
            return verifyP256(signature: signature, message: message, key: key)
        default:
            return false
        }
    }

    private static func verifyRSA(signature: Data, message: Data, key: JWK) -> Bool {
        guard let modulus = key.modulus.flatMap({ Data(dicomWebBase64URLEncoded: $0) }),
              let exponent = key.exponent.flatMap({ Data(dicomWebBase64URLEncoded: $0) }) else {
            return false
        }
        let publicKeyData = derSequence(derInteger(modulus) + derInteger(exponent))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: modulus.count * 8
        ]
        guard let publicKey = SecKeyCreateWithData(
            publicKeyData as CFData,
            attributes as CFDictionary,
            nil
        ) else {
            return false
        }
        return SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            message as CFData,
            signature as CFData,
            nil
        )
    }

    private static func verifyP256(signature: Data, message: Data, key: JWK) -> Bool {
        guard key.curve == "P-256",
              let x = key.x.flatMap({ Data(dicomWebBase64URLEncoded: $0) }),
              let y = key.y.flatMap({ Data(dicomWebBase64URLEncoded: $0) }),
              x.count == 32,
              y.count == 32,
              signature.count == 64 else {
            return false
        }
        let representation = Data([0x04]) + x + y
        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: representation),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: message)
    }

    private static func derInteger(_ bytes: Data) -> Data {
        var value = Data(bytes.drop(while: { $0 == 0 }))
        if value.isEmpty { value = Data([0]) }
        if value.first.map({ $0 & 0x80 != 0 }) == true { value.insert(0, at: 0) }
        return Data([0x02]) + derLength(value.count) + value
    }

    private static func derSequence(_ bytes: Data) -> Data {
        Data([0x30]) + derLength(bytes.count) + bytes
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 128 { return Data([UInt8(length)]) }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }
}
