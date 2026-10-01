import CryptoKit
import Foundation

public enum DicomWebhookSignatureError: Error, Equatable {
    case malformedHeader, unknownKey, keyRetired, signatureMismatch, timestampOutsideWindow
    case nonceReplayed, unsupportedVersion, nonceCacheFull
}

public struct DicomWebhookSignatureHeader: Equatable, Sendable {
    public static let headerName = "X-Isis-Signature"
    public let version: String
    public let keyID: String
    public let timestamp: Int64
    public let nonce: String
    public let signature: String

    public init(version: String = "v1", keyID: String, timestamp: Int64, nonce: String, signature: String) {
        self.version = version
        self.keyID = keyID
        self.timestamp = timestamp
        self.nonce = nonce
        self.signature = signature
    }

    public var serialized: String { "\(version),kid=\(keyID),t=\(timestamp),n=\(nonce),sig=\(signature)" }

    public static func parse(_ value: String) throws -> Self {
        guard value.utf8.count <= 1024 else { throw DicomWebhookSignatureError.malformedHeader }
        let fields = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5 else { throw DicomWebhookSignatureError.malformedHeader }
        guard fields[0] == "v1" else { throw DicomWebhookSignatureError.unsupportedVersion }
        let prefixes = ["kid=", "t=", "n=", "sig="]
        guard zip(fields.dropFirst(), prefixes).allSatisfy({ $0.hasPrefix($1) }) else {
            throw DicomWebhookSignatureError.malformedHeader
        }
        let keyID = String(fields[1].dropFirst(4))
        let time = String(fields[2].dropFirst(2))
        let nonce = String(fields[3].dropFirst(2))
        let signature = String(fields[4].dropFirst(4))
        guard validKeyID(keyID), let timestamp = Int64(time), String(timestamp) == time,
              nonce.count == 22, nonce.utf8.allSatisfy({ alphabet.contains($0) }),
              let nonceBytes = Data(base64Encoded: nonce.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + "=="), nonceBytes.count == 16,
              base64URL(nonceBytes) == nonce,
              signature.utf8.count == 64, signature.utf8.allSatisfy({ "0123456789abcdef".utf8.contains($0) }) else {
            throw DicomWebhookSignatureError.malformedHeader
        }
        return .init(keyID: keyID, timestamp: timestamp, nonce: nonce, signature: signature)
    }

    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".utf8)
    fileprivate static func validKeyID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy { alphabet.contains($0) || $0 == 46 }
    }
    fileprivate static func base64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    fileprivate var inputPrefix: String { "\(version)\n\(keyID)\n\(timestamp)\n\(nonce)\n" }
    fileprivate func input(body: Data) -> Data {
        Data((inputPrefix + SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined() + "\n").utf8)
    }
}

public protocol DicomWebhookKeyProviding: Sendable {
    func key(id: String) -> SymmetricKey?
    var activeKeyID: String { get }
    var retiringKeyIDs: [String] { get }
}

public struct DicomWebhookInMemoryKeyProvider: DicomWebhookKeyProviding {
    public let activeKeyID: String
    public let retiringKeyIDs: [String]
    private let keys: [String: SymmetricKey]

    /// Keys present in the map but outside the active/retiring set are retired.
    public init(activeKeyID: String, retiringKeyIDs: [String] = [], keys: [String: SymmetricKey]) {
        self.activeKeyID = activeKeyID
        self.retiringKeyIDs = retiringKeyIDs
        self.keys = keys
    }
    public func key(id: String) -> SymmetricKey? { keys[id] }
}

public struct DicomWebhookSigner: Sendable {
    private let keys: any DicomWebhookKeyProviding
    public init(keys: any DicomWebhookKeyProviding) { self.keys = keys }

    public func sign(body: Data, now: Date, nonce: Data? = nil) throws -> DicomWebhookSignatureHeader {
        guard DicomWebhookSignatureHeader.validKeyID(keys.activeKeyID),
              now.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970 >= Double(Int64.min),
              now.timeIntervalSince1970 < Double(Int64.max) else { throw DicomWebhookSignatureError.malformedHeader }
        guard let key = keys.key(id: keys.activeKeyID) else { throw DicomWebhookSignatureError.unknownKey }
        var generator = SystemRandomNumberGenerator()
        let bytes = nonce ?? Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        guard bytes.count == 16 else { throw DicomWebhookSignatureError.malformedHeader }
        let header = DicomWebhookSignatureHeader(keyID: keys.activeKeyID,
            timestamp: Int64(floor(now.timeIntervalSince1970)), nonce: DicomWebhookSignatureHeader.base64URL(bytes),
            signature: "")
        let mac = HMAC<SHA256>.authenticationCode(for: header.input(body: body), using: key)
        return .init(keyID: header.keyID, timestamp: header.timestamp, nonce: header.nonce,
                     signature: mac.map { String(format: "%02x", $0) }.joined())
    }
}

public actor DicomWebhookNonceCache {
    private let maxEntries: Int
    private var entries: [String: TimeInterval] = [:]
    public init(maxEntries: Int = 10_000) { self.maxEntries = maxEntries }

    /// Never evict a live nonce to admit another: capacity exhaustion fails closed.
    /// Keep future-dated signatures until their signed timestamp + replay window,
    /// otherwise a nonce could become replayable while its signature is still valid.
    fileprivate func consume(_ nonce: String, now: TimeInterval, expiresAt: TimeInterval) throws {
        entries = entries.filter { $0.value >= now }
        guard entries[nonce] == nil else { throw DicomWebhookSignatureError.nonceReplayed }
        guard entries.count < maxEntries else { throw DicomWebhookSignatureError.nonceCacheFull }
        entries[nonce] = expiresAt
    }
}

public struct DicomWebhookVerifier: Sendable {
    private let keys: any DicomWebhookKeyProviding
    private let replayWindow: TimeInterval
    private let nonceCache: DicomWebhookNonceCache

    public init(keys: any DicomWebhookKeyProviding, replayWindow: TimeInterval = 300,
                nonceCache: DicomWebhookNonceCache) {
        self.keys = keys
        self.replayWindow = replayWindow
        self.nonceCache = nonceCache
    }

    public func verify(header: String, body: Data, now: Date = Date()) async throws {
        try await verify(header: DicomWebhookSignatureHeader.parse(header), body: body, now: now)
    }

    public func verify(header: DicomWebhookSignatureHeader, body: Data, now: Date = Date()) async throws {
        let header = try DicomWebhookSignatureHeader.parse(header.serialized)
        guard let key = keys.key(id: header.keyID) else { throw DicomWebhookSignatureError.unknownKey }
        guard header.keyID == keys.activeKeyID || keys.retiringKeyIDs.contains(header.keyID) else {
            throw DicomWebhookSignatureError.keyRetired
        }
        guard replayWindow.isFinite, replayWindow >= 0, now.timeIntervalSince1970.isFinite,
              abs(now.timeIntervalSince1970 - Double(header.timestamp)) <= replayWindow else {
            throw DicomWebhookSignatureError.timestampOutsideWindow
        }
        let chars = Array(header.signature.utf8)
        let signature = Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(decoding: chars[$0..<$0 + 2], as: UTF8.self), radix: 16)!
        })
        // CryptoKit's authentication-code validator performs the constant-time comparison.
        guard HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: header.input(body: body), using: key) else {
            throw DicomWebhookSignatureError.signatureMismatch
        }
        try await nonceCache.consume(header.keyID + ":" + header.nonce, now: now.timeIntervalSince1970,
                                     expiresAt: Double(header.timestamp) + replayWindow)
    }
}
