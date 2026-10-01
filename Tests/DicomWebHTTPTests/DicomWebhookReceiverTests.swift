import CryptoKit
import DicomCore
import DicomWebHTTP
import Foundation
import XCTest

@MainActor
final class DicomWebhookReceiverTests: XCTestCase {
    func test_invalidAndReplay_signaturesRecordedAndRejected() async throws {
        let keys = DicomWebhookInMemoryKeyProvider(activeKeyID: "test", keys: ["test": SymmetricKey(size: .bits256)])
        let receiver = DicomWebhookReceiver(verifier: .init(keys: keys, nonceCache: .init()))
        let url = try await receiver.start()
        let transport = DicomWebhookURLSessionTransport()
        let body = Data("{}".utf8)
        let header = try DicomWebhookSigner(keys: keys).sign(body: body, now: Date()).serialized
        do {
            for (value, expected) in [("invalid", 401), (header, 200), (header, 401)] {
                let response = try await transport.send(.init(method: .post, url: url,
                    headers: ["X-Isis-Signature": value], body: body))
                XCTAssertEqual(response.statusCode, expected)
            }
            XCTAssertEqual(receiver.received.map(\.verified), [false, true, false])
            XCTAssertEqual(receiver.received.last?.error, "nonceReplayed")
        } catch { await receiver.stop(); throw error }
        await receiver.stop()
    }
    func test_authorizedPHI_receiptReportsInclusion() async throws {
        let keys = DicomWebhookInMemoryKeyProvider(activeKeyID: "test", keys: ["test": SymmetricKey(size: .bits256)])
        let receiver = DicomWebhookReceiver(verifier: .init(keys: keys, nonceCache: .init()), behaviors: [.respond(202)])
        let url = try await receiver.start()
        do {
            let event = try DicomWebhookEvent(eventID: "id", kind: "received", occurredAt: Date(), subject: .init(),
                phi: .init(patientName: "SYNTHETIC"), authorization: .init(token: "test", reason: "fixture"), source: "test")
            let client = DicomWebhookDeliveryClient(transport: DicomWebhookURLSessionTransport(),
                policy: .init(allowLoopback: true, allowInsecureForHosts: ["127.0.0.1"]), signer: .init(keys: keys))
            let result = try await client.deliver(event: event, to: url, idempotencyKey: "id")
            XCTAssertEqual(result, .delivered(status: 202))
            XCTAssertEqual(receiver.received.first?.phiIncluded, true)
        } catch { await receiver.stop(); throw error }
        await receiver.stop()
    }
}
