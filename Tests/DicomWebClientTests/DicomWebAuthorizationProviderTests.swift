import DicomWebClient
import Foundation
import XCTest

/// A per-request authorization provider: headers asked for before each request, one renewal and one repetition
/// after a 401, and a second 401 that ends the request as an authentication failure.
final class DicomWebAuthorizationProviderTests: XCTestCase {
    func test_providerHeadersReplaceConfiguredOnesAndA401IsRepeatedOnceWithRenewedHeaders() async throws {
        let provider = RotatingProvider(tokens: ["old", "new"])
        let transport = AuthorizationRecordingTransport(accepted: "Bearer new")
        var configuration = DicomWebClientConfiguration(baseURL: URL(string: "https://pacs.example/dicom-web")!)
        configuration.headers = ["authorization": "Bearer configured", "X-Tenant": "synthetic"]
        let client = DicomWebClient(configuration: configuration, transport: transport, authorizationProvider: provider)

        let page = try await client.search(parameters: .init(level: .study, includeFields: [], limit: 1))

        XCTAssertEqual(page.statusCode, 200)
        XCTAssertEqual(transport.authorizations, ["Bearer old", "Bearer new"])
        XCTAssertEqual(transport.authorizationHeaderCounts, [1, 1], "the provider's header replaces the configured one")
        XCTAssertEqual(transport.tenants, ["synthetic", "synthetic"])
        XCTAssertEqual(provider.rejected, ["Bearer old"])
    }

    func test_aSecond401EndsTheRequestWithAnAuthenticationFailure() async throws {
        let provider = RotatingProvider(tokens: ["old", "new"])
        let transport = AuthorizationRecordingTransport(accepted: nil)
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://pacs.example/dicom-web")!),
                                    transport: transport, authorizationProvider: provider)

        do {
            _ = try await client.search(parameters: .init(level: .study, includeFields: [], limit: 1))
            XCTFail("a second 401 must fail")
        } catch {
            XCTAssertEqual((error as? DicomWebError)?.kind, .unauthorized)
            XCTAssertEqual(DicomWebConnectionFailure(classifying: error).kind, .authentication)
        }
        XCTAssertEqual(transport.authorizations, ["Bearer old", "Bearer new"])
        XCTAssertEqual(provider.rejected, ["Bearer old"], "the provider renews once per request")
    }

    func test_fixedAuthenticationIsAProviderThatNeverRenews() async throws {
        let transport = AuthorizationRecordingTransport(accepted: nil)
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://pacs.example/dicom-web")!),
                                    transport: transport,
                                    authorizationProvider: DicomWebAuthentication.bearer(token: "fixed"))

        do {
            _ = try await client.search(parameters: .init(level: .study, includeFields: [], limit: 1))
            XCTFail("a refused fixed token must fail")
        } catch {
            XCTAssertEqual((error as? DicomWebError)?.kind, .unauthorized)
        }
        XCTAssertEqual(transport.authorizations, ["Bearer fixed"], "a credential that cannot renew is sent once")
        XCTAssertEqual(try DicomWebAuthentication.apiKey(headerName: "X-API-Key", value: "k").authorizationHeaders(),
                       ["X-API-Key": "k"])
        XCTAssertEqual(try DicomWebAuthentication.none.authorizationHeaders(), [:])
    }
}

/// Hands out `tokens` in turn: the first before any renewal, the next after each one.
private final class RotatingProvider: DicomWebAuthorizationProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let tokens: [String]
    private var index = 0
    private var rejectedHeaders: [String] = []

    init(tokens: [String]) { self.tokens = tokens }

    var rejected: [String] { lock.withLock { rejectedHeaders } }

    func authorizationHeaders() async throws -> [String: String] {
        lock.withLock { ["Authorization": "Bearer \(tokens[index])"] }
    }

    func renewAuthorization(afterRejecting rejected: [String: String]) async throws -> Bool {
        lock.withLock {
            rejectedHeaders.append(rejected["Authorization"] ?? "")
            guard index + 1 < tokens.count else { return false }
            index += 1
            return true
        }
    }
}

/// Answers an empty QIDO result to `accepted` and 401 to anything else, recording what each request carried.
private final class AuthorizationRecordingTransport: DicomWebHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let accepted: String?
    private var received: [[String: String]] = []

    init(accepted: String?) { self.accepted = accepted }

    var authorizations: [String] {
        lock.withLock { received.map { headers in headers.first { $0.key.lowercased() == "authorization" }?.value ?? "" } }
    }
    var tenants: [String] { lock.withLock { received.map { $0["X-Tenant"] ?? "" } } }
    var authorizationHeaderCounts: [Int] {
        lock.withLock { received.map { headers in headers.keys.filter { $0.lowercased() == "authorization" }.count } }
    }

    func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        lock.withLock { received.append(request.headers) }
        let authorization = request.headers.first { $0.key.lowercased() == "authorization" }?.value
        guard authorization == accepted, accepted != nil else {
            return .init(statusCode: 401, headers: ["WWW-Authenticate": "Bearer error=\"invalid_token\""])
        }
        return .init(statusCode: 200, headers: ["Content-Type": "application/dicom+json"], body: Data("[]".utf8))
    }
}
