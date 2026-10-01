import CryptoKit
import DicomCore
import DicomWebHTTP
import Foundation
import XCTest

/// The listener uses plain HTTP here; HTTPS enforcement is exercised in DicomWebhookTargetPolicyTests.
@MainActor
final class DicomWebhookDeliveryLoopbackTests: XCTestCase {
    private var keys: DicomWebhookInMemoryKeyProvider {
        .init(activeKeyID: "test", keys: ["test": SymmetricKey(data: Data("loopback-test".utf8))])
    }
    private func event() throws -> DicomWebhookEvent {
        try .init(eventID: "stable", kind: "available", occurredAt: Date(), subject: .init(), source: "test")
    }
    private func client(timeout: TimeInterval = 3) -> DicomWebhookDeliveryClient {
        .init(transport: DicomWebhookURLSessionTransport(),
              policy: .init(allowLoopback: true, allowInsecureForHosts: ["127.0.0.1"], timeout: timeout),
              signer: .init(keys: keys))
    }
    func test_validatedAddressIsUsedWithoutResolvingOriginalHostAgain() async throws {
        let receiver = DicomWebhookReceiver(verifier: .init(keys: keys, nonceCache: .init()))
        let bound = try await receiver.start()
        let url = try XCTUnwrap(URL(string: "http://rebind.invalid:\(try XCTUnwrap(bound.port))/hook"))
        let pinned = DicomWebhookDeliveryClient(transport: DicomWebhookURLSessionTransport(),
            policy: .init(allowLoopback: true, allowInsecureForHosts: ["rebind.invalid"], timeout: 2,
                          resolve: { _ in ["127.0.0.1"] }), signer: .init(keys: keys))
        do {
            let result = try await pinned.deliver(event: event(), to: url, idempotencyKey: "pinned")
            XCTAssertEqual(result, .delivered(status: 200))
            let receipt = try XCTUnwrap(receiver.received.first)
            XCTAssertTrue(receipt.verified)
            XCTAssertEqual(receipt.headers["host"], "rebind.invalid:\(try XCTUnwrap(bound.port))")
        } catch { await receiver.stop(); throw error }
        await receiver.stop()
    }

    func test_realDelivery_verifiedReceipt() async throws {
        let receiver = DicomWebhookReceiver(verifier: .init(keys: keys, nonceCache: .init()))
        let url = try await receiver.start()
        do {
            let result = try await client().deliver(event: event(), to: url, idempotencyKey: "same")
            XCTAssertEqual(result, .delivered(status: 200))
            XCTAssertEqual(receiver.received.count, 1)
            XCTAssertTrue(receiver.received[0].verified)
        } catch { await receiver.stop(); throw error }
        await receiver.stop()
    }
    func test_realRedirect_doesNotReachDestination() async throws {
        let destination = DicomWebhookReceiver(verifier: .init(keys: keys, nonceCache: .init()))
        let destinationURL = try await destination.start()
        let source = DicomWebhookReceiver(verifier: .init(keys: keys, nonceCache: .init()),
                                         behaviors: [.redirect(to: destinationURL)])
        let url = try await source.start()
        do {
            let result = try await client().deliver(event: event(), to: url, idempotencyKey: "same")
            XCTAssertEqual(result, .rejected(.redirectNotAllowed))
            XCTAssertEqual(source.received.count, 1)
            XCTAssertTrue(destination.received.isEmpty)
        } catch { await source.stop(); await destination.stop(); throw error }
        await source.stop()
        await destination.stop()
    }
    func test_delayedAcknowledgement_uncertainAfterReceipt() async throws {
        let receiver = DicomWebhookReceiver(verifier: .init(keys: keys, nonceCache: .init()),
                                           behaviors: [.delay(3, thenStatus: 200)])
        let url = try await receiver.start()
        do {
            let result = try await client(timeout: 0.3).deliver(event: event(), to: url, idempotencyKey: "same")
            guard case .uncertain = result else { XCTFail("Expected uncertain, got \(result)"); await receiver.stop(); return }
            XCTAssertEqual(receiver.received.count, 1)
        } catch { await receiver.stop(); throw error }
        await receiver.stop()
    }
    func test_connectionDropped_uncertainNoAutomaticRetry() async throws {
        let receiver = DicomWebhookReceiver(verifier: .init(keys: keys, nonceCache: .init()), behaviors: [.dropConnection])
        let url = try await receiver.start()
        do {
            let result = try await client().deliver(event: event(), to: url, idempotencyKey: "same")
            guard case .uncertain = result else { XCTFail("Expected uncertain, got \(result)"); await receiver.stop(); return }
            XCTAssertEqual(receiver.received.count, 1)
        } catch { await receiver.stop(); throw error }
        await receiver.stop()
    }
    func test_duplicateOK_twoAttemptsRemainVisible() async throws {
        let receiver = DicomWebhookReceiver(verifier: .init(keys: keys, nonceCache: .init()),
                                           behaviors: [.respondThenDuplicateOK])
        let url = try await receiver.start()
        do {
            for _ in 0..<2 {
                let result = try await client().deliver(event: event(), to: url, idempotencyKey: "same")
                XCTAssertEqual(result, .delivered(status: 200))
            }
            XCTAssertEqual(receiver.received.count, 2)
        } catch { await receiver.stop(); throw error }
        await receiver.stop()
    }
}
