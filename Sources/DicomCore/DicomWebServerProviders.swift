import Foundation

/// Storage owns persistence, matching and bounded provider pages; routing owns authorization and HTTP representation.
/// Search methods must apply offset and limit after matching and deduplication, in stable order while storage is unchanged.
/// A finite limit must bound materialized results. The server pages through these candidates before applying authorized offsets.
public protocol DicomWebStorageProviding: Sendable {
    func searchStudies(parameters: DicomWebSearchParameters) async throws -> [DicomDataSet]
    func searchSeries(parameters: DicomWebSearchParameters) async throws -> [DicomDataSet]
    func searchInstances(parameters: DicomWebSearchParameters) async throws -> [DicomDataSet]
    func metadata(study: String, series: String?, instance: String?) async throws -> [DicomDataSet]
    func instance(study: String, series: String, instance: String) async throws -> DicomWebStoredInstance
    func frames(study: String, series: String, instance: String) async throws -> DicomWebStoredInstance
    func bulkData(uri: String) async throws -> Data
    func store(instances: [DicomWebStoredInstance]) async throws -> [DicomWebStorageResult]
}

public extension DicomWebStorageProviding {
    func frames(study: String, series: String, instance: String) async throws -> DicomWebStoredInstance {
        try await self.instance(study: study, series: series, instance: instance)
    }
}

public struct DicomWebStorageResult: Sendable {
    public var sopClassUID: String
    public var sopInstanceUID: String
    public var warningReason: Int?
    public var failureReason: Int?
    public var durability: DicomDurabilityLevel?
    public var effectiveWarningReason: Int? {
        warningReason ?? durability.flatMap { $0 < .publishedAndRegistered ? 0xB000 : nil }
    }
    public init(sopClassUID: String, sopInstanceUID: String, warningReason: Int? = nil, failureReason: Int? = nil,
                durability: DicomDurabilityLevel? = nil) {
        self.sopClassUID = sopClassUID
        self.sopInstanceUID = sopInstanceUID
        self.warningReason = warningReason
        self.failureReason = failureReason
        self.durability = durability
    }
}

public enum DicomWebAuthenticationResult: Sendable {
    case allow
    case deny(statusCode: Int, challenge: String?)
}

public protocol DicomWebAuthenticating: Sendable {
    func authenticate(_ request: DicomWebHTTPRequest) async -> DicomWebAuthenticationResult
}

public struct DicomWebBearerAuthentication: DicomWebAuthenticating, DicomWebPrincipalResolving {
    public let token: String
    public init(token: String) { self.token = token }
    public func authenticate(_ request: DicomWebHTTPRequest) async -> DicomWebAuthenticationResult {
        request.headers.dicomWebHeaderValue("Authorization") == "Bearer \(token)" ? .allow
            : .deny(statusCode: 401, challenge: "Bearer realm=\"DICOMweb\"")
    }
}

public struct DicomWebBasicAuthentication: DicomWebAuthenticating, DicomWebPrincipalResolving {
    private let username: String
    private let credentials: String
    public init(username: String, password: String) {
        self.username = username
        credentials = Data("\(username):\(password)".utf8).base64EncodedString()
    }
    public func authenticate(_ request: DicomWebHTTPRequest) async -> DicomWebAuthenticationResult {
        request.headers.dicomWebHeaderValue("Authorization") == "Basic \(credentials)" ? .allow
            : .deny(statusCode: 401, challenge: "Basic realm=\"DICOMweb\", charset=\"UTF-8\"")
    }
}

/// The injected verifier validates JWT signatures, claims and authorization policy.
public struct DicomWebJWTAuthentication: DicomWebAuthenticating {
    private let verify: @Sendable (String) async -> DicomWebAuthenticationResult
    public init(verify: @escaping @Sendable (String) async -> DicomWebAuthenticationResult) { self.verify = verify }
    public func authenticate(_ request: DicomWebHTTPRequest) async -> DicomWebAuthenticationResult {
        guard let header = request.headers.dicomWebHeaderValue("Authorization"), header.hasPrefix("Bearer ") else {
            return .deny(statusCode: 401, challenge: "Bearer realm=\"DICOMweb\"")
        }
        return await verify(String(header.dropFirst(7)))
    }
}

public protocol DicomWebPrincipalResolving: Sendable {
    func principal(for request: DicomWebHTTPRequest) async -> DicomPrincipal?
}

extension DicomWebBearerAuthentication {
    public func principal(for request: DicomWebHTTPRequest) async -> DicomPrincipal? {
        guard case .allow = await authenticate(request) else { return nil }
        return .init(id: "dicomweb-service", kind: .serviceAccount, source: .bearer,
            sessionID: UUID().uuidString, authenticatedAt: Date(), policyVersion: 0)
    }
}

extension DicomWebBasicAuthentication {
    public func principal(for request: DicomWebHTTPRequest) async -> DicomPrincipal? {
        guard case .allow = await authenticate(request) else { return nil }
        return .init(id: username, kind: .localUser, source: .basic,
            sessionID: UUID().uuidString, authenticatedAt: Date(), policyVersion: 0)
    }
}

extension DicomWebJWTAuthentication: DicomWebPrincipalResolving {
    public func principal(for request: DicomWebHTTPRequest) async -> DicomPrincipal? {
        // Claims are read only after the host verifier has accepted the signature and claims.
        guard case .allow = await authenticate(request),
              let header = request.headers.dicomWebHeaderValue("Authorization") else { return nil }
        let fields = header.dropFirst(7).split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        var payload = String(fields[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let bytes = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let subject = claims["sub"] as? String, !subject.isEmpty else { return nil }
        let scopes = (claims["scope"] as? String)?.split(separator: " ").map(String.init)
            ?? claims["scopes"] as? [String] ?? []
        return .init(id: subject, kind: .serviceAccount, source: .oidc, scopes: Set(scopes),
            sessionID: UUID().uuidString, authenticatedAt: Date(),
            expiresAt: (claims["exp"] as? Double).map(Date.init(timeIntervalSince1970:)), policyVersion: 0)
    }
}

/// A1 declares capability only. Server execution is an additive refinement of that contract.
public protocol DicomWebServerTranscoding: DicomWebTranscoding {
    var transferSyntaxUIDs: [String] { get }
    func transcode(_ instance: DicomWebStoredInstance, to transferSyntaxUID: String) async throws -> Data
}

struct DicomWebServerFailure: Error {
    let status: Int
    let message: String
    init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}
