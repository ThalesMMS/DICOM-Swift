import ArgumentParser
import DicomCore
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct LDAPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ldap",
        abstract: "Authenticate through optional LDAP and evaluate an operation with explicit group grants.",
        discussion: "Reads a password line from a pipe on stdin; if searchBindDN is configured, its password is the first line. Terminal input is refused. Never put passwords in arguments or the JSON configuration. No directory is contacted by other commands.")

    struct Document: Codable {
        let directory: DicomLDAPConfiguration
        let policy: DicomLDAPGroupPolicy
    }
    struct Report: Encodable {
        let outcome: String
        let scopes: [String]
        let roles: [String]
        let expiresAt: Date?
        let policyVersion: Int64
    }
    @Option(name: .long, help: "JSON directory configuration and group policy, without credentials.") var config: String
    @Option(name: .long, help: "Exact value of the configured user attribute.") var username: String
    @Option(name: .long, help: "Operation to authorize; for example query, export, configure.") var operation = "query"
    @Option(name: .long, help: "Opaque archive resource identifier for this authorization check.") var resource = "ldap-diagnostic"

    func document() throws -> Document {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: config))
            guard data.count <= 1_048_576 else { throw DicomLDAPError.invalidConfiguration }
            let document = try JSONDecoder().decode(Document.self, from: data)
            try document.directory.validate()
            guard !document.policy.groups.isEmpty, document.policy.sessionLifetime.isFinite,
                  document.policy.sessionLifetime > 0, document.policy.sessionLifetime <= 3600 else {
                throw DicomLDAPError.invalidConfiguration
            }
            return document
        } catch { throw ValidationError("Invalid LDAP directory or group policy configuration") }
    }

    mutating func run() async throws {
        let document = try document()
        guard let operation = DicomAccessOperation(rawValue: operation), !resource.isEmpty, !username.isEmpty else {
            throw ValidationError("Invalid LDAP operation, resource or username")
        }
        guard isatty(STDIN_FILENO) == 0 else { throw ValidationError("Provide transient passwords through a pipe on stdin") }
        let searchPassword = document.directory.searchBindDN == nil ? nil : try Self.readPassword(.standardInput)
        let password = try Self.readPassword(.standardInput)
        let sink = DicomInMemoryAuditSink()
        let audit = DicomAuditRecorder(sinks: [sink], policy: .failClosed)
        let authorizer = DicomProtectionAuthorizer(policyVersion: document.policy.policyVersion) { _ in [:] }
        let policy = document.policy
        let service = try DicomLDAPAuthenticationService(configuration: document.directory,
            mapIdentity: { policy.principal(for: $0, at: $1) }, authorizer: authorizer, audit: audit)
        let principal: DicomPrincipal
        do {
            principal = try await service.authenticateAndAuthorize(username: username, password: password,
                searchPassword: searchPassword, operation: operation, resource: .init(kind: .archive, id: resource),
                context: .init(protocol: .cli))
        } catch let error as DicomLDAPError {
            guard let report = Self.denialReport(for: error) else { throw error }
            let data = try JSONEncoder().encode(report)
            FileHandle.standardError.write(data + Data([10]))
            throw ExitCode.failure
        }
        let report = Report(outcome: "allow", scopes: principal.scopes.sorted(), roles: principal.roles.sorted(),
            expiresAt: principal.expiresAt, policyVersion: principal.policyVersion)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }

    /// Only a verified authentication or authorization denial uses this contract; operational errors stay errors.
    static func denialReport(for error: DicomLDAPError) -> [String: String]? {
        switch error {
        case .invalidCredentials, .unmappedIdentity, .authorizationDenied:
            return ["outcome": "deny", "reason": String(describing: error)]
        default:
            return nil
        }
    }

    /// Bounded, transient input. Do not trim spaces: they can be part of a valid password.
    static func readPassword(_ input: FileHandle) throws -> Data {
        var bytes = Data()
        while let byte = try input.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 10 { break }
            guard bytes.count < 4096 else { throw ValidationError("LDAP password input exceeds its limit") }
            bytes.append(byte)
        }
        guard !bytes.isEmpty else { throw ValidationError("LDAP requires a nonempty password") }
        return bytes
    }
}
