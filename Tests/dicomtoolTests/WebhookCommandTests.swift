import ArgumentParser
import CryptoKit
import DicomCore
import Foundation
import XCTest
@testable import dicomtool

@MainActor
final class WebhookCommandTests: XCTestCase {
    func test_sendReceiveCountOne_roundTrip() async throws {
        let receive = try WebhookCommand.Receive.parse(["--port", "0", "--key-id", "test", "--secret", "fixture",
                                                       "--count", "1"])
        let ready = AsyncThrowingStream<URL, any Error>.makeStream()
        let task = Task {
            do { try await receive.receive { ready.continuation.yield($0); ready.continuation.finish() } }
            catch { ready.continuation.finish(throwing: error); throw error }
        }
        var iterator = ready.stream.makeAsyncIterator()
        let startedURL = try await iterator.next()
        let url = try XCTUnwrap(startedURL)
        do {
            var send = try WebhookCommand.Send.parse(["--url", url.absoluteString, "--key-id", "test", "--secret", "fixture",
                "--event-kind", "received", "--study-uid", "1.2.3", "--allow-loopback", "--allow-insecure"])
            try await send.run()
            try await task.value
        } catch { task.cancel(); _ = await task.result; throw error }
    }
    func test_verifySuccessAndTampering_exitTwo() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let body = Data("{}".utf8)
        try body.write(to: file)
        let keys = DicomWebhookInMemoryKeyProvider(activeKeyID: "test", keys: ["test": SymmetricKey(data: Data("fixture".utf8))])
        let header = try DicomWebhookSigner(keys: keys).sign(body: body, now: Date()).serialized
        var verify = try WebhookCommand.Verify.parse(["--key-id", "test", "--secret", "fixture", "--header", header,
                                                      "--body-file", file.path])
        try await verify.run()
        try Data("tampered".utf8).write(to: file)
        do { try await verify.run(); XCTFail("Expected exit 2") }
        catch { XCTAssertEqual(error as? ExitCode, ExitCode(2)) }
    }
    func test_registrationAndScriptParsing() throws {
        let command = try DicomTool.parseAsRoot(["webhook", "verify", "--key-id", "test", "--secret", "fixture",
                                               "--header", "invalid", "--body-file", "/tmp/body"])
        XCTAssertTrue(command is WebhookCommand.Verify)
        XCTAssertEqual(try WebhookCommand.Receive.behaviors("respond:503, delay:0.1:200, redirect:https://example.test, drop, duplicate").count, 5)
        XCTAssertThrowsError(try WebhookCommand.Receive.behaviors("delay:nan:200"))
    }
}


extension WebhookCommandTests {
    func test_secretFileAndEnvironmentAvoidCommandLineSecret() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("fixture\n".utf8).write(to: file)
        let options = try WebhookCommand.KeyOptions.parse(["--key-id", "test", "--secret-file", file.path])
        _ = try options.provider()
        XCTAssertEqual(try WebhookCommand.KeyOptions.resolveSecret(secret: nil, file: nil,
            environment: ["DICOMTOOL_WEBHOOK_SECRET": "environment"]), "environment")
        XCTAssertEqual(try WebhookCommand.KeyOptions.resolveSecret(secret: "argument", file: file.path), "fixture")
        XCTAssertThrowsError(try WebhookCommand.KeyOptions.resolveSecret(secret: nil, file: nil, environment: [:]))
    }

    func test_receiverStartupFailureFinishesReadinessStream() async throws {
        let receive = try WebhookCommand.Receive.parse(["--port", "0", "--key-id", "test", "--secret", "fixture", "--count", "0"])
        let ready = AsyncThrowingStream<URL, any Error>.makeStream()
        let task = Task {
            do { try await receive.receive { ready.continuation.yield($0); ready.continuation.finish() } }
            catch { ready.continuation.finish(throwing: error); throw error }
        }
        var iterator = ready.stream.makeAsyncIterator()
        do { _ = try await iterator.next(); XCTFail("Expected startup failure") }
        catch { XCTAssertTrue(error is ValidationError) }
        _ = await task.result
    }
}
