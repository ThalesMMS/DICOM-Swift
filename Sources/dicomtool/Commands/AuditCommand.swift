import ArgumentParser
import Foundation
import DicomCore

struct AuditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "audit", abstract: "DICOM audit diagnostics",
        subcommands: [Emit.self, Receive.self, Validate.self])
    struct Emit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "emit")
        @Option(name: .long) var syslog: String?
        @Flag(name: .long) var tls = false
        @Option(name: .long) var tlsCa: String?
        @Option(name: .long) var event: String = "dicomInstancesAccessed"
        @Option(name: .long) var studyUid: String?
        func makeEvent() throws -> DicomAuditEvent {
            let context = DicomAccessContext(protocol: .cli)
            let resources = studyUid.map { [DicomResourceRef(kind: .study, id: $0)] } ?? []
            switch event {
            case "start": return DicomAuditMessages.applicationActivity(.start, principal: nil, context: context)
            case "stop": return DicomAuditMessages.applicationActivity(.stop, principal: nil, context: context)
            case "login": return DicomAuditMessages.userAuthentication(.login, principal: nil, context: context)
            case "logout": return DicomAuditMessages.userAuthentication(.logout, principal: nil, context: context)
            case "failure": return DicomAuditMessages.userAuthentication(.failure, principal: nil, context: context)
            case "queryPerformed": return DicomAuditMessages.queryPerformed(principal: nil, context: context, resources: resources)
            case "dicomInstancesAccessed": return DicomAuditMessages.dicomInstancesAccessed(principal: nil, context: context, resources: resources)
            case "beginTransferringInstances": return DicomAuditMessages.beginTransferringInstances(principal: nil, context: context, resources: resources)
            case "instancesTransferred": return DicomAuditMessages.instancesTransferred(principal: nil, context: context, resources: resources)
            case "dataExport": return DicomAuditMessages.dataExport(principal: nil, context: context, resources: resources)
            case "dataImport": return DicomAuditMessages.dataImport(principal: nil, context: context, resources: resources)
            case "securityAlert": return DicomAuditMessages.securityAlert(typeCode: .nodeAuthentication, principal: nil, context: context, resources: resources)
            case "patientRecord": return DicomAuditMessages.patientRecord(action: .read, principal: nil, context: context, resources: resources)
            case "configurationChanged": return DicomAuditMessages.configurationChanged(principal: nil, context: context, resources: resources)
            default: throw ValidationError("Unknown audit event kind")
            }
        }
        mutating func run() async throws {
            guard tls || tlsCa == nil else { throw ValidationError("--tls-ca requires --tls") }
            guard syslog != nil || !tls else { throw ValidationError("--tls requires --syslog") }
            let message = try makeEvent()
            print(DicomAuditMessageXML.serialize(message), terminator: "")
            if let syslog {
                guard let parts = URLComponents(string: "tcp://" + syslog), let host = parts.host,
                      let port = parts.port, (1...65535).contains(port), parts.user == nil, parts.password == nil,
                      parts.path.isEmpty, parts.query == nil, parts.fragment == nil else { throw ValidationError("Expected host:port") }
                let sink = try DicomAuditSyslogSink(host: host, port: UInt16(port),
                    tls: .init(mode: tls ? .enabled : .disabled, serverName: host,
                               material: tlsCa.map { .init(trustStorePath: $0) }))
                try await sink.record(message)
            }
        }
    }
    struct Receive: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "receive")
        @Option(name: .long) var port: UInt16 = 6514
        @Option(name: .long) var tlsCertificate: String?
        @Option(name: .long) var tlsKey: String?
        @Option(name: .long) var count: Int = 1
        mutating func run() async throws {
            guard count > 0, count <= 10000, (tlsCertificate == nil) == (tlsKey == nil) else {
                throw ValidationError("Positive --count and paired TLS certificate/key required")
            }
            let receiver = DicomAuditSyslogReceiver(port: port,
                tls: .init(mode: tlsCertificate == nil ? .disabled : .enabled,
                           material: .init(certificatePath: tlsCertificate, privateKeyPath: tlsKey)))
            _ = try await receiver.start(); defer { receiver.stop() }
            var printed = 0
            while printed < count {
                try Task.checkCancellation()
                let received = receiver.received
                for message in received.dropFirst(printed).prefix(count - printed) {
                    print(String(decoding: try DicomWebhookCanonicalJSON.encode(message), as: UTF8.self)); printed += 1
                }
                if printed < count { try await Task.sleep(for: .milliseconds(20)) }
            }
        }
    }
    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "validate")
        @Option(name: .long) var file: String
        mutating func run() throws {
            do { try DicomAuditMessageXML.validate(Data(contentsOf: URL(fileURLWithPath: file))) }
            catch { throw ExitCode(2) }
        }
    }
}
