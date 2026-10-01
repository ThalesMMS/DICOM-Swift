import ArgumentParser
import CryptoKit
import Foundation
import DicomCore
import HL7v2
import HL7MLLP

struct MLLPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mllp",
        subcommands: [MLLPSendCommand.self, MLLPListenCommand.self])
}

struct MLLPSendCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "send")
    @Option var host: String
    @Option var port: UInt16
    @Flag var tls = false
    @Option var tlsCa: String?
    @Option var serverName: String?
    @Argument var files: [String]
    @Option var ackTimeout: Double = 30
    @Flag var allowResendIdempotent = false

    mutating func run() async throws {
        guard port > 0, !files.isEmpty, ackTimeout.isFinite, ackTimeout > 0,
              tls || (tlsCa == nil && serverName == nil) else { throw ExitCode(2) }
        let security: DicomTLSConfiguration? = tls ? .init(mode: .enabled,
            material: .init(trustStorePath: tlsCa)) : nil
        var failed = false
        for (index, file) in files.enumerated() {
            // A fresh correlation scope also permits explicitly supplied duplicate files to exercise replay.
            let client = MLLPClient(host: host, port: port, tls: security, serverName: serverName)
            var summary = "failed"
            do {
                let message = try readHL7(file)
                let result = try await MLLPOutbound.send(message, client: client,
                    policy: .init(resend: allowResendIdempotent ? .idempotentOnly : .never, ackTimeout: ackTimeout))
                switch result {
                case .completed(let ack):
                    summary = ack.description
                    if case .acknowledged = ack {} else { failed = true }
                case .unknown(let decision): summary = decision.description; failed = true
                }
            } catch { failed = true }
            await client.disconnect()
            print("file[\(index + 1)]: \(summary)")
        }
        if failed { throw ExitCode(2) }
    }
}

private actor MLLPCLIProcessor: MLLPMessageProcessing {
    func process(_ message: HL7Message, raw: Data, context: MLLPInboundContext) -> MLLPProcessingOutcome { .accepted }
}

actor MLLPCLIOutput {
    var received = 0
    func record(_ message: HL7Message, outcome: MLLPProcessingOutcome, ack: String?) {
        let type = message.messageType.code ?? ""
        let object: [String: String] = [
            "type": ["ADT", "ACK", "QBP", "ORM", "ORU", "RSP", "QRY"].contains(type) ? type : "other",
            "version": message.version?.rawValue ?? "unknown",
            "controlIDHash": SHA256.hash(data: Data((message.controlID ?? "").utf8))
                .map { String(format: "%02x", $0) }.joined(),
            "outcome": outcome.description, "ackCode": ack ?? "none"
        ]
        if var bytes = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) {
            bytes.append(10); writeHL7(bytes)
        }
        received += 1
    }
}

struct MLLPListenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "listen")
    @Option var port: UInt16
    @Option var bind = "127.0.0.1"
    @Option var tlsCertificate: String?
    @Option var tlsKey: String?
    @Flag var intranetLab = false
    @Option var count: Int?
    @Option var ackMode = "AL"
    @Flag var rejectInvalid = false
    @Option var ledger: String?

    /// Shared with tests so the actual command setup is exercised with an ephemeral listener.
    func makeListener(output: MLLPCLIOutput) throws -> MLLPListener {
        guard count == nil || count! > 0, let mode = HL7AckMode(rawValue: ackMode), mode != .original,
              (tlsCertificate == nil) == (tlsKey == nil) else { throw ExitCode(2) }
        let security: DicomTLSConfiguration? = tlsCertificate.map {
            .init(mode: .enabled, material: .init(certificatePath: $0, privateKeyPath: tlsKey))
        }
        let store: (any MLLPInboundLedger)? = try ledger.map { try MLLPJSONLLedger(directory: URL(fileURLWithPath: $0)) }
        var configuration = MLLPListenerConfiguration(bindAddress: bind, port: port, tls: security,
            ackPolicy: .init(mode: mode), exposure: .init(mode: intranetLab ? .intranetLab : .localOnly,
                requireTLS: false, requireAuthentication: false, allowUnauthorizedIntranetLab: intranetLab))
        configuration.rejectInvalid = rejectInvalid
        return MLLPListener(configuration: configuration, processor: MLLPCLIProcessor(), ledger: store,
            observer: { message, outcome, ack in await output.record(message, outcome: outcome, ack: ack) })
    }
    mutating func run() async throws {
        let output = MLLPCLIOutput()
        do {
            let listener = try makeListener(output: output)
            _ = try await listener.start()
            do {
                while !Task.isCancelled {
                    if let count, await output.received >= count { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
            } catch { await listener.stop(); throw error }
            await listener.stop()
        } catch { throw ExitCode(2) }
    }
}
