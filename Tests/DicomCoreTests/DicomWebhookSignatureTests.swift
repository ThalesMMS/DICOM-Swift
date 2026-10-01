import CryptoKit
import DicomCore
import Foundation
import XCTest

@MainActor
final class DicomWebhookSignatureTests: XCTestCase {
    private let key = SymmetricKey(data: Data("fixed-test-key".utf8))
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let body = Data(#"{"a":"x","b":1}"#.utf8)
    private var keys: DicomWebhookInMemoryKeyProvider { .init(activeKeyID: "k1", keys: ["k1": key]) }
    private func signed(at date: Date? = nil) throws -> DicomWebhookSignatureHeader {
        try DicomWebhookSigner(keys: keys).sign(body: body, now: date ?? now, nonce: Data(repeating: 0, count: 16))
    }
    private func verifyFailure(_ header: DicomWebhookSignatureHeader, body: Data? = nil, at date: Date? = nil,
                               expected: DicomWebhookSignatureError) async {
        do {
            try await DicomWebhookVerifier(keys: keys, nonceCache: .init()).verify(
                header: header, body: body ?? self.body, now: date ?? now)
            XCTFail("Expected \(expected)")
        } catch { XCTAssertEqual(error as? DicomWebhookSignatureError, expected) }
    }
    func test_knownAnswer_documentedInputAndRoundTrip() async throws {
        let header = try signed()
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let input = Data("v1\nk1\n1700000000\nAAAAAAAAAAAAAAAAAAAAAA\n\(digest)\n".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: input, using: key)
        XCTAssertEqual(header.signature, mac.map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try DicomWebhookSignatureHeader.parse(header.serialized), header)
        try await DicomWebhookVerifier(keys: keys, nonceCache: .init()).verify(header: header, body: body, now: now)
    }
    func test_tamperedBodyAndHeader_failAuthentication() async throws {
        let header = try signed()
        await verifyFailure(header, body: Data("tampered".utf8), expected: .signatureMismatch)
        await verifyFailure(.init(keyID: "k1", timestamp: header.timestamp + 1, nonce: header.nonce,
                                  signature: header.signature), expected: .signatureMismatch)
        await verifyFailure(.init(keyID: "k1", timestamp: header.timestamp, nonce: header.nonce,
                                  signature: String(repeating: "0", count: 64)), expected: .signatureMismatch)
    }
    func test_retiringAccepted_retiredAndUnknownRejected() async throws {
        let header = try signed()
        let rotating = DicomWebhookInMemoryKeyProvider(activeKeyID: "k2", retiringKeyIDs: ["k1"],
                                                       keys: ["k1": key, "k2": key])
        try await DicomWebhookVerifier(keys: rotating, nonceCache: .init()).verify(header: header, body: body, now: now)
        let retired = DicomWebhookInMemoryKeyProvider(activeKeyID: "k2", keys: ["k1": key, "k2": key])
        do {
            try await DicomWebhookVerifier(keys: retired, nonceCache: .init()).verify(header: header, body: body, now: now)
            XCTFail("retired")
        } catch { XCTAssertEqual(error as? DicomWebhookSignatureError, .keyRetired) }
        await verifyFailure(.init(keyID: "missing", timestamp: header.timestamp, nonce: header.nonce,
                                  signature: header.signature), expected: .unknownKey)
    }
    func test_replay_nonceConsumedOnlyAfterAuthentication() async throws {
        let header = try signed()
        let verifier = DicomWebhookVerifier(keys: keys, nonceCache: .init())
        do { try await verifier.verify(header: header, body: Data(), now: now); XCTFail("tamper") }
        catch { XCTAssertEqual(error as? DicomWebhookSignatureError, .signatureMismatch) }
        try await verifier.verify(header: header, body: body, now: now)
        do { try await verifier.verify(header: header, body: body, now: now); XCTFail("replay") }
        catch { XCTAssertEqual(error as? DicomWebhookSignatureError, .nonceReplayed) }
    }
    func test_window_inclusiveEdgesAndOutside() async throws {
        for offset in [-300.0, 300] {
            try await DicomWebhookVerifier(keys: keys, nonceCache: .init()).verify(
                header: signed(), body: body, now: now.addingTimeInterval(offset))
        }
        for offset in [-300.01, 300.01] {
            await verifyFailure(try signed(), at: now.addingTimeInterval(offset), expected: .timestampOutsideWindow)
        }
    }
    func test_futureNonce_retainedForEntireValidityWindow() async throws {
        let verifier = DicomWebhookVerifier(keys: keys, nonceCache: .init())
        let header = try signed(at: now.addingTimeInterval(300))
        try await verifier.verify(header: header, body: body, now: now)
        do { try await verifier.verify(header: header, body: body, now: now.addingTimeInterval(600)); XCTFail("replay") }
        catch { XCTAssertEqual(error as? DicomWebhookSignatureError, .nonceReplayed) }
    }
    func test_cacheCapacity_failsClosedAndExpires() async throws {
        let verifier = DicomWebhookVerifier(keys: keys, nonceCache: .init(maxEntries: 1))
        try await verifier.verify(header: signed(), body: body, now: now)
        let second = try DicomWebhookSigner(keys: keys).sign(body: body, now: now)
        do { try await verifier.verify(header: second, body: body, now: now); XCTFail("capacity") }
        catch { XCTAssertEqual(error as? DicomWebhookSignatureError, .nonceCacheFull) }
        let later = now.addingTimeInterval(301)
        try await verifier.verify(header: DicomWebhookSigner(keys: keys).sign(body: body, now: later), body: body, now: later)
    }
    func test_malformedAndUnsupportedHeaders_rejected() throws {
        let header = try signed().serialized
        for malformed in [header + ",kid=k1", header.replacingOccurrences(of: "t=170", with: "t=0170"),
                          header.replacingOccurrences(of: "kid=k1", with: "kid=k\n1"),
                          header.replacingOccurrences(of: "AAAAAAAAAAAAAAAAAAAAAA", with: "bad")] {
            XCTAssertThrowsError(try DicomWebhookSignatureHeader.parse(malformed))
        }
        XCTAssertThrowsError(try DicomWebhookSignatureHeader.parse(header.replacingOccurrences(of: "v1,", with: "v2,"))) {
            XCTAssertEqual($0 as? DicomWebhookSignatureError, .unsupportedVersion)
        }
    }
    func test_concurrentReplay_onlyOneAcceptance() async throws {
        let verifier = DicomWebhookVerifier(keys: keys, nonceCache: .init())
        let header = try signed()
        let body = body
        let now = now
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    do { try await verifier.verify(header: header, body: body, now: now); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        XCTAssertEqual(successes, 1)
    }
}
