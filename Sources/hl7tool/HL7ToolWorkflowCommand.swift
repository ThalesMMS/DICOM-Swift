import ArgumentParser
import ClinicalMapping
import DicomCore
import FHIR
import Foundation
import HL7v2
import HL7v3Transport
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Clinical mapping and workflow commands. Nothing here modifies a catalog or a server: outputs are
/// files and JSON reports for the operator to review.
struct WorkflowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "workflow", abstract: "Map HL7 v2, DICOM and FHIR clinical entities with provenance and run the order→study→result flow.",
                                                    subcommands: [Map.self, Demo.self])

    struct Map: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "map", abstract: "Map one source to the requested target and print the entity plus the mapping report.")
        @Argument(help: "hl7 (ORM/ORU/ADT), dicom (files of one study) or fhir (Patient/ServiceRequest/DiagnosticReport JSON)") var source: String
        @Argument var files: [String]
        @Option(help: "fhir | hl7 | mwl | sr | model") var target = "model"
        @Option(help: "Patient reference for FHIR targets, e.g. Patient/123") var patient: String = "Patient/unknown"
        @Flag var strict = false

        mutating func run() throws {
            let options = MappingOptions(strict: strict)
            switch source {
            case "hl7":
                let message = try HL7Parser().parse(Data(contentsOf: URL(fileURLWithPath: try single(files))))
                switch message.messageType.code {
                case "ORM":
                    let order = try HL7v2ClinicalMapper.order(from: message, options: options)
                    switch target {
                    case "fhir": try emitResource(try FHIRClinicalMapper.serviceRequest(from: order.value, subject: patient, options: options).value.resource, report: order.report)
                    case "mwl":
                        let item = try DICOMClinicalMapper.worklistItem(from: order.value, studyInstanceUID: DicomDataSetWriter.makeUID(), options: options)
                        try emitJSON(["worklistItem": ["patientID": item.value.patientID ?? "", "accessionNumber": item.value.accessionNumber ?? "", "modality": item.value.modality ?? "",
                                                        "scheduledStart": (item.value.scheduledProcedureStepStartDate ?? "") + (item.value.scheduledProcedureStepStartTime ?? ""),
                                                        "requestedProcedureDescription": item.value.requestedProcedureDescription ?? ""]], report: item.report)
                    default: try emitCodable(order.value, report: order.report)
                    }
                case "ORU":
                    let result = try HL7v2ClinicalMapper.result(from: message, options: options)
                    switch target {
                    case "fhir":
                        let bundle = try FHIRClinicalMapper.diagnosticReport(from: result.value, subject: patient, options: options).value
                        var collection = FHIRBundle(type: "collection")
                        collection.entries = ([bundle.report.resource] + bundle.observations.map(\.resource) + [bundle.provenance]).map { FHIRBundleEntry(resource: $0) }
                        try emitResource(collection.resource, report: result.report)
                    case "sr":
                        let document = try DICOMClinicalMapper.structuredReport(from: result.value, options: options)
                        let dataset = DicomStructuredReportBuilder.dataSet(from: document.value, studyInstanceUID: result.value.studyInstanceUID ?? DicomDataSetWriter.makeUID(), seriesInstanceUID: DicomDataSetWriter.makeUID())
                        try emitJSON(["structuredReport": ["sopClassUID": document.value.sopClassUID ?? "", "contentItems": String(document.value.root.children.count), "modality": dataset.string(for: .modality) ?? ""]], report: document.report)
                    default: try emitCodable(result.value, report: result.report)
                    }
                case "ADT":
                    let identity = try HL7v2ClinicalMapper.identity(from: message, options: options)
                    if target == "fhir" { try emitResource(FHIRClinicalMapper.patient(from: identity.value).value.resource, report: identity.report) }
                    else { try emitCodable(identity.value, report: identity.report) }
                default: throw ValidationError("Unsupported HL7 message type")
                }
            case "dicom":
                let datasets = try files.map { try DCMDecoder(data: Data(contentsOf: URL(fileURLWithPath: $0))).dataSet }
                let study = try DICOMClinicalMapper.study(from: datasets)
                if target == "fhir" { try emitResource(FHIRClinicalMapper.imagingStudy(from: study.value, subject: patient).value.resource, report: study.report) }
                else { try emitCodable(study.value, report: study.report) }
            case "fhir":
                let resource = try FHIRResource(jsonData: Data(contentsOf: URL(fileURLWithPath: try single(files))))
                switch resource.resourceType {
                case "Patient":
                    let identity = FHIRClinicalMapper.identity(from: resource.as(FHIRPatient.self)!)
                    if target == "hl7" { FileHandle.standardOutput.write(try HL7Serializer().serialize(try HL7v2ClinicalMapper.adtMessage(from: identity.value).value)) }
                    else { try emitCodable(identity.value, report: identity.report) }
                case "ServiceRequest":
                    let order = FHIRClinicalMapper.order(from: resource.as(FHIRServiceRequest.self)!, patient: ClinicalPatientIdentity())
                    if target == "hl7" { FileHandle.standardOutput.write(try HL7Serializer().serialize(try HL7v2ClinicalMapper.ormMessage(from: order.value).value)) }
                    else { try emitCodable(order.value, report: order.report) }
                case "DiagnosticReport":
                    let result = FHIRClinicalMapper.result(from: resource.as(FHIRDiagnosticReport.self)!, observations: [], patient: ClinicalPatientIdentity())
                    if target == "hl7" { FileHandle.standardOutput.write(try HL7Serializer().serialize(try HL7v2ClinicalMapper.oruMessage(from: result.value).value)) }
                    else { try emitCodable(result.value, report: result.report) }
                default: throw ValidationError("Unsupported FHIR resource type")
                }
            default: throw ValidationError("source must be hl7, dicom or fhir")
            }
        }

        private func single(_ files: [String]) throws -> String {
            guard files.count == 1 else { throw ValidationError("Exactly one file expected") }
            return files[0]
        }
        private func emitCodable<T: Encodable>(_ value: T, report: MappingReport) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(value))
            print()
            emitReport(report)
        }
        private func emitResource(_ resource: FHIRResource, report: MappingReport) throws {
            FileHandle.standardOutput.write(resource.jsonData(pretty: true))
            emitReport(report)
        }
        private func emitJSON(_ object: [String: Any], report: MappingReport) throws {
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            print()
            emitReport(report)
        }
        private func emitReport(_ report: MappingReport) {
            FileHandle.standardError.write(Data("report mapped=\(report.count(.mapped)) absent=\(report.count(.absent)) changed=\(report.count(.changed)) lost=\(report.count(.lost))\n".utf8))
            for entry in report.lost { FileHandle.standardError.write(Data("lost \(entry.source ?? "?") \(entry.reason ?? "")\n".utf8)) }
        }
    }

    struct Demo: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "demo", abstract: "Run order→study→result through the workflow engine; repeats show idempotency.")
        @Option var order: String
        @Option var study: [String] = []
        @Option var result: [String] = []
        @Option(help: "How many times each input is replayed (retries).") var repeatCount: Int = 2
        @Flag(name: .customLong("accept-results-without-order")) var acceptResultsWithoutOrder = false
        @Flag(name: .customLong("allow-identity-conflicts")) var allowIdentityConflicts = false

        mutating func run() async throws {
            let policy = ClinicalWorkflowPolicy(acceptResultsWithoutOrder: acceptResultsWithoutOrder, refuseIdentityConflicts: !allowIdentityConflicts)
            let store = ClinicalInMemoryWorkflowStore()
            let engine = ClinicalWorkflowEngine(store: store, policy: policy)
            var lines: [String] = []
            for attempt in 1...max(1, repeatCount) {
                let mappedOrder = try HL7v2ClinicalMapper.order(from: try HL7Parser().parse(Data(contentsOf: URL(fileURLWithPath: order))))
                let outcome = await engine.ingest(order: mappedOrder)
                lines.append("attempt \(attempt) order \(outcome.key) -> \(outcome.disposition.rawValue) identity=\(describe(outcome.identity))")
                if !study.isEmpty {
                    let datasets = try study.map { try DCMDecoder(data: Data(contentsOf: URL(fileURLWithPath: $0))).dataSet }
                    let mappedStudy = try DICOMClinicalMapper.study(from: datasets)
                    let studyOutcome = await engine.ingest(study: mappedStudy)
                    lines.append("attempt \(attempt) study \(studyOutcome.key) -> \(studyOutcome.disposition.rawValue) order=\(studyOutcome.linkedOrderKey ?? "-") identity=\(describe(studyOutcome.identity))")
                }
                for file in result {
                    let mappedResult = try HL7v2ClinicalMapper.result(from: try HL7Parser().parse(Data(contentsOf: URL(fileURLWithPath: file))))
                    let resultOutcome = await engine.ingest(result: mappedResult)
                    lines.append("attempt \(attempt) result \(resultOutcome.key) -> \(resultOutcome.disposition.rawValue) order=\(resultOutcome.linkedOrderKey ?? "-") study=\(resultOutcome.linkedStudyKey ?? "-") supersedes=\(resultOutcome.supersededResultKey ?? "-")" + (resultOutcome.reasons.isEmpty ? "" : " reasons=" + resultOutcome.reasons.joined(separator: ";")))
                }
            }
            let counts = await store.counts
            lines.append("stored orders=\(counts.orders) studies=\(counts.studies) results=\(counts.results) patients=\(counts.patients)")
            for line in lines { print(line) }
        }

        private func describe(_ decision: ClinicalIdentityDecision) -> String {
            switch decision {
            case .new: return "new"
            case .matched(let key): return "matched(" + key + ")"
            case .conflict(let key, let fields): return "conflict(" + key + ":" + fields.joined(separator: ",") + ")"
            }
        }
    }
}

/// SMART App Launch helpers for operators: discovery and the two halves of the code flow. Tokens are
/// written only to the file the operator names; the Keychain belongs to the app, not to this tool.
struct SMARTCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "smart", abstract: "SMART on FHIR discovery and authorization-code flow (public client, PKCE).",
                                                    subcommands: [Discover.self, AuthorizeURL.self, Exchange.self])

    /// The temporary inode is private before any secret is written; rename replaces the destination atomically.
    static func writePrivate(_ data: Data, to path: String) throws {
        let destination = URL(fileURLWithPath: path)
        var template = Array(destination.deletingLastPathComponent().appendingPathComponent(".smart-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let temporaryPath = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            unlink(temporaryPath)
        }
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(temporaryPath, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func policy(intranetLab: String?) throws -> HL7v3TransportPolicy {
        var policy = HL7v3TransportPolicy(timeout: 20)
        if let intranetLab {
            guard intranetLab == "127.0.0.1" || intranetLab == "localhost" else { throw ValidationError("--intranet-lab accepts loopback only") }
            policy.allowInsecureForHosts = [intranetLab]
        }
        return policy
    }

    struct Discover: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "discover", abstract: "Fetch and validate .well-known/smart-configuration.")
        @Argument var issuer: String
        @Option(name: .customLong("intranet-lab")) var intranetLab: String?
        mutating func run() async throws {
            guard let url = URL(string: issuer) else { throw ValidationError("Invalid issuer URL") }
            let configuration = try await SMARTDiscovery(policy: try SMARTCommand.policy(intranetLab: intranetLab)).discover(issuer: url)
            print("authorization_endpoint=\(configuration.authorizationEndpoint.absoluteString)")
            print("token_endpoint=\(configuration.tokenEndpoint.absoluteString)")
            print("revocation_endpoint=\(configuration.revocationEndpoint?.absoluteString ?? "-")")
            print("capabilities=\(configuration.capabilities.joined(separator: ","))")
            print("pkce=\(configuration.codeChallengeMethodsSupported.joined(separator: ","))")
        }
    }

    struct AuthorizeURL: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "authorize-url", abstract: "Print the authorization URL and save the pending state (verifier/nonce) to a file.")
        @Argument var issuer: String
        @Option(name: .customLong("client-id")) var clientID: String
        @Option(name: .customLong("redirect-uri")) var redirectURI: String
        @Option var scope: [String] = ["openid", "fhirUser", "launch/patient", "patient/*.rs"]
        @Option(name: .customLong("state-file")) var stateFile: String
        @Option(name: .customLong("intranet-lab")) var intranetLab: String?
        mutating func run() async throws {
            guard let url = URL(string: issuer), let redirect = URL(string: redirectURI) else { throw ValidationError("Invalid URL") }
            let server = try await SMARTDiscovery(policy: try SMARTCommand.policy(intranetLab: intranetLab)).discover(issuer: url)
            let client = SMARTClientConfiguration(clientID: clientID, redirectURI: redirect, scopes: scope.map(SMARTScope.init), audience: url, allowedRedirectSchemes: ["isis"])
            let (authorizeURL, pending) = try SMARTAuthorizationRequest.make(client: client, server: server)
            let state: [String: String] = ["state": pending.state, "codeVerifier": pending.codeVerifier, "nonce": pending.nonce ?? "", "issuer": url.absoluteString,
                                           "createdAt": String(pending.createdAt.timeIntervalSince1970), "clientID": clientID, "redirectURI": redirectURI, "scope": scope.joined(separator: " ")]
            try SMARTCommand.writePrivate(JSONSerialization.data(withJSONObject: state), to: stateFile)
            print(authorizeURL.absoluteString)
        }
    }

    struct Exchange: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "exchange", abstract: "Validate the redirect URL and exchange the code; writes the token JSON to --token-file.")
        @Argument var redirectURL: String
        @Option(name: .customLong("state-file")) var stateFile: String
        @Option(name: .customLong("token-file")) var tokenFile: String
        @Option(name: .customLong("intranet-lab")) var intranetLab: String?
        mutating func run() async throws {
            let state = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: stateFile))) as? [String: String] ?? [:]
            guard let issuer = state["issuer"].flatMap(URL.init(string:)), let redirectURI = state["redirectURI"].flatMap(URL.init(string:)), let clientID = state["clientID"],
                  let stateValue = state["state"], let verifier = state["codeVerifier"], let createdAt = state["createdAt"].flatMap(Double.init),
                  let redirect = URL(string: redirectURL) else { throw ValidationError("Incomplete state file or redirect URL") }
            let pending = SMARTPendingAuthorization(state: stateValue, codeVerifier: verifier, nonce: (state["nonce"] ?? "").isEmpty ? nil : state["nonce"],
                                                    createdAt: Date(timeIntervalSince1970: createdAt), lifetime: 600, issuer: issuer)
            let policy = try SMARTCommand.policy(intranetLab: intranetLab)
            let server = try await SMARTDiscovery(policy: policy).discover(issuer: issuer)
            let client = SMARTClientConfiguration(clientID: clientID, redirectURI: redirectURI, scopes: (state["scope"] ?? "").split(separator: " ").map { SMARTScope(String($0)) }, audience: issuer, allowedRedirectSchemes: ["isis"])
            let code = try SMARTAuthorizationRequest.parseRedirect(redirect, client: client, pending: pending)
            let token = try await SMARTTokenClient(server: server, client: client, policy: policy).exchange(code: code, pending: pending)
            let output: [String: Any] = ["access_token": token.accessToken, "refresh_token": token.refreshToken ?? "", "scope": token.scopes.map { $0.raw }.joined(separator: " "),
                                         "patient": token.patient ?? "", "expires_at": token.expiresAt.map { String($0.timeIntervalSince1970) } ?? ""]
            try SMARTCommand.writePrivate(JSONSerialization.data(withJSONObject: output), to: tokenFile)
            print("token written to \(tokenFile) (scope: \(token.scopes.map { $0.raw }.joined(separator: " ")))")
        }
    }
}
