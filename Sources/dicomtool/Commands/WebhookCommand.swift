import ArgumentParser
import CryptoKit
import DicomCore
import DicomWebHTTP
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct WebhookCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "webhook", abstract: "Signed webhook diagnostics",
        subcommands: [Send.self, Receive.self, Verify.self])

    struct KeyOptions: ParsableArguments {
        @Option(name: .long) var keyId: String
        @Option(name: .long, help: "Shared secret as UTF-8 text (diagnostics only; prefer --secret-file)") var secret: String?
        @Option(name: .long, help: "UTF-8 secret file; otherwise use DICOMTOOL_WEBHOOK_SECRET") var secretFile: String?
        func provider() throws -> DicomWebhookInMemoryKeyProvider {
            let secret = try Self.resolveSecret(secret: secret, file: secretFile)
            return .init(activeKeyID: keyId, keys: [keyId: SymmetricKey(data: Data(secret.utf8))])
        }
        static func resolveSecret(secret: String?, file: String?,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
            let resolved = try file.map {
                try String(contentsOfFile: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? secret ?? environment["DICOMTOOL_WEBHOOK_SECRET"]
            guard let resolved, !resolved.isEmpty else {
                throw ValidationError("Supply --secret-file or DICOMTOOL_WEBHOOK_SECRET (or --secret for diagnostics)")
            }
            return resolved
        }
    }

    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "send")
        @OptionGroup var key: KeyOptions
        @Option(name: .long) var url: String
        @Option(name: .long) var eventKind: String
        @Option(name: .long) var studyUid: String
        @Flag(name: .long) var allowLoopback = false
        @Flag(name: .long) var allowInsecure = false
        mutating func run() async throws {
            guard let target = URL(string: url), let host = target.host else { throw ValidationError("Invalid URL") }
            let event = try DicomWebhookEvent(eventID: UUID().uuidString, kind: eventKind, occurredAt: Date(),
                subject: .init(studyInstanceUID: studyUid), source: "dicomtool")
            let client = DicomWebhookDeliveryClient(transport: DicomWebhookURLSessionTransport(),
                policy: .init(allowLoopback: allowLoopback, allowInsecureForHosts: allowInsecure ? [host] : []),
                signer: .init(keys: try key.provider()))
            let outcome = try await client.deliver(event: event, to: target, idempotencyKey: event.eventID)
            struct Report: Encodable {
                let eventID: String
                let outcome: String
                let phiIncluded: Bool
            }
            print(String(decoding: try DicomWebhookCanonicalJSON.encode(Report(eventID: event.eventID,
                outcome: String(describing: outcome), phiIncluded: event.phiIncluded)), as: UTF8.self))
            if case .delivered = outcome {} else { throw ExitCode(2) }
        }
    }

    struct Receive: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "receive")
        @OptionGroup var key: KeyOptions
        @Option(name: .long) var port: UInt16 = 8080
        @Option(name: .long) var count: Int?
        @Option(name: .long, help: "Comma-separated: respond:200, delay:1:200, redirect:URL, drop, duplicate")
        var script: String?
        mutating func run() async throws { try await receive() }

        func receive(onStart: @Sendable (URL) -> Void = { _ in }) async throws {
            if let count, count <= 0 { throw ValidationError("Count must be positive") }
            let stop = StopFlag()
            let oldSignal = signal(SIGINT, SIG_IGN)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            interrupt.setEventHandler { stop.set() }
            interrupt.resume()
            defer { interrupt.cancel(); signal(SIGINT, oldSignal) }
            let receiver = DicomWebhookReceiver(verifier: .init(keys: try key.provider(), nonceCache: .init()),
                port: port, behaviors: try Self.behaviors(script)) { receipt in
                    struct Line: Encodable {
                        let verified: Bool
                        let error: String?
                        let phiIncluded: Bool
                    }
                    if let bytes = try? DicomWebhookCanonicalJSON.encode(Line(verified: receipt.verified,
                        error: receipt.error, phiIncluded: receipt.phiIncluded)) {
                        print(String(decoding: bytes, as: UTF8.self))
                        fflush(stdout)
                    }
                }
            onStart(try await receiver.start())
            do {
                while !stop.isSet {
                    if let count, receiver.received.count >= count { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                await receiver.stop()
                throw error
            }
            // Permit the last handler to flush its response before closing accepted connections.
            try? await Task.sleep(for: .milliseconds(100))
            await receiver.stop()
        }

        static func behaviors(_ script: String?) throws -> [DicomWebhookReceiver.Behavior] {
            guard let script else { return [] }
            return try script.split(separator: ",").map { rawItem in
                let item = rawItem.trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
                if item == "drop" { return .dropConnection }
                if item == "duplicate" { return .respondThenDuplicateOK }
                if parts.count == 2 && parts[0] == "respond", let status = Int(parts[1]), (200...599).contains(status) {
                    return .respond(status)
                }
                if parts.count == 2 && parts[0] == "redirect", let url = URL(string: parts[1]), url.host != nil {
                    return .redirect(to: url)
                }
                if parts.count == 2 && parts[0] == "delay" {
                    let values = parts[1].split(separator: ":")
                    if values.count == 2, let seconds = Double(values[0]), seconds.isFinite, seconds >= 0,
                       let status = Int(values[1]), (200...599).contains(status) { return .delay(seconds, thenStatus: status) }
                }
                throw ValidationError("Invalid webhook script behavior")
            }
        }
    }

    struct Verify: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "verify")
        @OptionGroup var key: KeyOptions
        @Option(name: .long) var header: String
        @Option(name: .long) var bodyFile: String
        mutating func run() async throws {
            do {
                let body = try Data(contentsOf: URL(fileURLWithPath: bodyFile))
                try await DicomWebhookVerifier(keys: key.provider(), nonceCache: .init())
                    .verify(header: header, body: body)
                print("{\"verified\":true}")
            } catch { throw ExitCode(2) }
        }
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var isSet: Bool { lock.withLock { stopped } }
        func set() { lock.withLock { stopped = true } }
    }
}
