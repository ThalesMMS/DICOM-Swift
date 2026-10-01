import ArgumentParser
import CryptoKit
import DicomCore
import Foundation

struct DeliveryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delivery", abstract: "Durable at-least-once delivery",
        subcommands: [Enqueue.self, Run.self, Status.self, Cancel.self, Requeue.self])

    struct Enqueue: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "enqueue")
        @Option(name: .long) var outbox: String
        @Option(name: .long) var destination: String
        @Option(name: .long) var kind: String
        @Option(name: .long) var priority: String = "routine"
        @Option(name: .long) var eventJson: String?
        @Argument var files: [String] = []
        mutating func run() async throws {
            let destinationKind: DicomDeliveryDestinationKind
            switch kind {
            case "webhook": destinationKind = .webhook
            case "stow": destinationKind = .stowRS
            case "cstore": destinationKind = .dimseStore
            default: throw ValidationError("Kind must be webhook, stow, or cstore")
            }
            guard let priority = DicomDeliveryPriority(rawValue: priority) else {
                throw ValidationError("Priority must be stat or routine")
            }
            let payload: DicomDeliveryItem.Payload
            let eventID: String
            let bytes: Int64
            if let eventJson {
                guard files.isEmpty, destinationKind == .webhook else {
                    throw ValidationError("--event-json requires webhook and no object files")
                }
                let data = try Data(contentsOf: URL(fileURLWithPath: eventJson))
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let event = try decoder.decode(DicomWebhookEvent.self, from: data)
                payload = .event(event)
                eventID = event.eventID
                bytes = Int64(data.count)
            } else {
                guard !files.isEmpty, destinationKind != .webhook else {
                    throw ValidationError("Object delivery requires Part 10 files; webhook requires --event-json")
                }
                let urls = files.map { URL(fileURLWithPath: $0).standardizedFileURL }
                for url in urls { _ = try DicomStoreRequest(part10FileAt: url) }
                payload = .objects(urls)
                eventID = UUID().uuidString
                bytes = try urls.reduce(0) { total, url in
                    total + Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                }
            }
            let item = DicomDeliveryItem(eventID: eventID, destinationID: destination, destinationKind: destinationKind,
                idempotencyKey: eventID, priority: priority, payload: payload, byteCount: bytes)
            let store = try DicomJSONLDeliveryOutbox(directory: URL(fileURLWithPath: outbox))
            try await store.enqueue([item])
            print(item.deliveryID)
        }
    }
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "run")
        @Option(name: .long) var outbox: String
        @Flag(name: .long) var once = false
        @Option(name: .long) var seconds: Double?
        @Option(name: .long) var webhook: [String] = []
        @Option(name: .long) var stow: [String] = []
        @Option(name: .long) var cstore: [String] = []
        @Option(name: .long) var keyId: String?
        @Option(name: .long, help: "Diagnostics only; prefer --secret-file") var secret: String?
        @Option(name: .long, help: "UTF-8 secret file; otherwise use DICOMTOOL_WEBHOOK_SECRET") var secretFile: String?
        @Flag(name: .long) var allowLoopback = false
        mutating func run() async throws {
            guard once != (seconds != nil), seconds.map({ $0.isFinite && $0 > 0 }) ?? true else {
                throw ValidationError("Choose --once or --seconds with a positive duration")
            }
            var destinations: [String: any DicomDeliveryDestination] = [:]
            for specification in webhook {
                let (id, value) = try Self.split(specification)
                guard let url = URL(string: value), let host = url.host, let keyId else {
                    throw ValidationError("Webhook requires a URL and --key-id")
                }
                let secret = try WebhookCommand.KeyOptions.resolveSecret(secret: secret, file: secretFile)
                let keys = DicomWebhookInMemoryKeyProvider(activeKeyID: keyId,
                    keys: [keyId: SymmetricKey(data: Data(secret.utf8))])
                let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
                destinations[id] = DicomWebhookDestination(id: id, url: url,
                    policy: .init(allowLoopback: allowLoopback,
                                  allowInsecureForHosts: allowLoopback && loopback ? [host] : []),
                    signer: .init(keys: keys))
            }
            for specification in stow {
                let (id, value) = try Self.split(specification)
                guard let url = URL(string: value), url.host != nil else { throw ValidationError("Invalid STOW URL") }
                destinations[id] = DicomSTOWDestination(id: id, configuration: .init(baseURL: url))
            }
            for specification in cstore {
                let (id, value) = try Self.split(specification)
                let components = value.split(separator: ":").map(String.init)
                guard components.count == 3, let port = UInt16(components[1]), port > 0 else {
                    throw ValidationError("C-STORE destination must be id=host:port:aet")
                }
                destinations[id] = DicomDIMSEStoreDestination(id: id) {
                    .init(configuration: .init(host: components[0], port: port, calledAETitle: components[2],
                                               callingAETitle: "DICOMTOOL", retryPolicy: .disabled))
                }
            }
            guard !destinations.isEmpty else { throw ValidationError("Configure at least one destination") }
            let store = try DicomJSONLDeliveryOutbox(directory: URL(fileURLWithPath: outbox))
            let engine = DicomDeliveryEngine(outbox: store, destinations: destinations, owner: "dicomtool")
            try await engine.resume(now: Date())
            if once {
                let report = await engine.runOnce(now: Date())
                print("attempted=\(report.attempted) delivered=\(report.delivered) paused=\(report.paused)")
                if !report.errors.isEmpty { throw ValidationError(report.errors.joined(separator: "; ")) }
            } else {
                let deadline = Date().addingTimeInterval(seconds!)
                await engine.run(until: { Date() >= deadline })
                await engine.drain()
            }
        }
        static func split(_ value: String) throws -> (String, String) {
            let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw ValidationError("Expected id=value") }
            return (parts[0], parts[1])
        }
    }
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status")
        @Option(name: .long) var outbox: String
        mutating func run() async throws {
            let store = try DicomJSONLDeliveryOutbox(directory: URL(fileURLWithPath: outbox))
            let counts = try await store.counts()
            for state in DicomDeliveryState.allCases { print("\(state.rawValue): \(counts[state, default: 0])") }
            for item in try await store.fetch(states: [.deadLetter]) {
                print("\(item.deliveryID) \(item.lastErrorClass?.rawValue ?? "") \(item.lastError ?? "")")
            }
        }
    }
    struct Cancel: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "cancel")
        @Option(name: .long) var outbox: String
        @Argument var deliveryID: String
        mutating func run() async throws {
            try await DicomJSONLDeliveryOutbox(directory: URL(fileURLWithPath: outbox)).cancel(deliveryID: deliveryID)
        }
    }
    struct Requeue: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "requeue")
        @Option(name: .long) var outbox: String
        @Argument var deliveryID: String
        mutating func run() async throws {
            try await DicomJSONLDeliveryOutbox(directory: URL(fileURLWithPath: outbox))
                .requeueDeadLetter(deliveryID: deliveryID, now: Date())
        }
    }
}
