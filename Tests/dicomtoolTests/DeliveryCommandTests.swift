import ArgumentParser
import DicomCore
import Foundation
import XCTest
@testable import dicomtool

@MainActor
final class DeliveryCommandTests: XCTestCase {
    func test_enqueueRunLoopbackStatus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = try DicomWebhookEvent(eventID: "delivery-cli", kind: "complete", occurredAt: Date(),
                                          subject: .init(), source: "test")
        let secretFile = directory.appendingPathComponent("key.txt")
        try Data("fixture".utf8).write(to: secretFile)
        let file = directory.appendingPathComponent("event.json")
        try DicomWebhookCanonicalJSON.encode(event).write(to: file)
        var enqueue = try DeliveryCommand.Enqueue.parse(["--outbox", directory.path, "--destination", "peer",
            "--kind", "webhook", "--event-json", file.path])
        try await enqueue.run()
        let receive = try WebhookCommand.Receive.parse(["--port", "0", "--key-id", "test", "--secret", "fixture", "--count", "1"])
        let ready = AsyncThrowingStream<URL, any Error>.makeStream()
        let task = Task {
            do { try await receive.receive { ready.continuation.yield($0); ready.continuation.finish() } }
            catch { ready.continuation.finish(throwing: error); throw error }
        }
        var iterator = ready.stream.makeAsyncIterator()
        let address = try await iterator.next()
        let url = try XCTUnwrap(address)
        do {
            var run = try DeliveryCommand.Run.parse(["--outbox", directory.path, "--once", "--webhook", "peer=\(url)",
                "--key-id", "test", "--secret-file", secretFile.path, "--allow-loopback"])
            try await run.run()
            try await task.value
        } catch { task.cancel(); _ = await task.result; throw error }
        let store = try DicomJSONLDeliveryOutbox(directory: directory)
        let counts = try await store.counts()
        XCTAssertEqual(counts[.delivered], 1)
        var status = try DeliveryCommand.Status.parse(["--outbox", directory.path])
        try await status.run()
    }
    func test_registrationAndRequeue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DicomJSONLDeliveryOutbox(directory: directory)
        let item = DicomDeliveryItem(deliveryID: "a", eventID: "a", destinationID: "peer",
            destinationKind: .webhook, idempotencyKey: "a", payload: .objects([]))
        try await store.enqueue([item])
        try await store.fail(deliveryID: "a", errorClass: .permanent, message: "refused", retryAt: nil)
        var requeue = try DeliveryCommand.Requeue.parse(["--outbox", directory.path, "a"])
        try await requeue.run()
        let reopened = try DicomJSONLDeliveryOutbox(directory: directory)
        let pending = try await reopened.fetch(states: [.pending])
        XCTAssertEqual(pending.first?.attempts, 0)
        let command = try DicomTool.parseAsRoot(["delivery", "status", "--outbox", directory.path])
        XCTAssertTrue(command is DeliveryCommand.Status)
    }
}

extension DeliveryCommandTests {
    func test_loopback503PersistsRetryWait() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DicomJSONLDeliveryOutbox(directory: directory)
        let event = try DicomWebhookEvent(eventID: "busy", kind: "complete", occurredAt: Date(),
                                          subject: .init(), source: "test")
        try await store.enqueue([.init(eventID: "busy", destinationID: "peer", destinationKind: .webhook,
                                       idempotencyKey: "busy", payload: .event(event))])
        let receive = try WebhookCommand.Receive.parse(["--port", "0", "--key-id", "test", "--secret", "fixture",
                                                       "--count", "1", "--script", "respond:503"])
        let ready = AsyncThrowingStream<URL, any Error>.makeStream()
        let task = Task {
            do { try await receive.receive { ready.continuation.yield($0); ready.continuation.finish() } }
            catch { ready.continuation.finish(throwing: error); throw error }
        }
        var iterator = ready.stream.makeAsyncIterator()
        let address = try await iterator.next()
        let url = try XCTUnwrap(address)
        do {
            var run = try DeliveryCommand.Run.parse(["--outbox", directory.path, "--once", "--webhook", "peer=\(url)",
                "--key-id", "test", "--secret", "fixture", "--allow-loopback"])
            try await run.run()
            try await task.value
        } catch { task.cancel(); _ = await task.result; throw error }
        let reopened = try DicomJSONLDeliveryOutbox(directory: directory)
        let waiting = try await reopened.fetch(states: [.retryWait])
        XCTAssertEqual(waiting.first?.lastErrorClass, .transient)
    }
}
