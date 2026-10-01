import ArgumentParser
import DicomCore
import FHIR
import Foundation
import HL7v3Transport
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct FHIRCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fhir", abstract: "Parse, validate, evaluate FHIRPath, map DICOM studies and query FHIR servers.",
                                                    subcommands: [Parse.self, Validate.self, Path.self, ImagingStudy.self, Client.self])

    struct Parse: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "parse", abstract: "Read JSON or XML and write JSON (default) or XML.")
        @Argument var file: String
        @Flag var xml = false
        @Flag var pretty = false

        mutating func run() throws {
            let resource = try readFHIR(file)
            if xml {
                FileHandle.standardOutput.write(try resource.xmlData(indentation: pretty ? 2 : nil))
            } else {
                FileHandle.standardOutput.write(resource.jsonData(pretty: pretty))
            }
        }
    }

    struct Validate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "validate", abstract: "Structural, binding, invariant and profile validation; exit 2 on errors.")
        @Argument var file: String
        @Option(name: .customLong("profile"), help: "StructureDefinition JSON/XML files to register and apply.") var profiles: [String] = []
        @Flag var lenient = false

        mutating func run() async throws {
            let resource = try readFHIR(file)
            var registry = FHIRProfileRegistry()
            var requested: [String] = []
            for path in profiles {
                let profile = try FHIRProfile(structureDefinition: try readFHIR(path))
                registry.register(profile)
                requested.append(profile.url)
            }
            let validator = FHIRValidator(options: .init(allowUnknownElements: lenient), profiles: registry)
            let report = await validator.validate(resource, profiles: requested)
            for issue in report.issues { print("\(issue.severity.rawValue) \(issue.code) \(issue.path): \(issue.detail)") }
            print("profiles=\(report.appliedProfiles.count) invariants=\(report.evaluatedInvariants.count) errors=\(report.errors.count) warnings=\(report.warnings.count)")
            if !report.isValid { throw ExitCode(2) }
        }
    }

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "path", abstract: "Evaluate a FHIRPath expression; prints a JSON array of results.")
        @Argument var expression: String
        @Argument var file: String

        mutating func run() throws {
            let results = try FHIRPathEvaluator().evaluate(expression, on: try readFHIR(file))
            FileHandle.standardOutput.write(FHIRJSONWriter().write(.array(results.map(\.json))))
            print()
        }
    }

    struct ImagingStudy: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "imagingstudy", abstract: "Build an ImagingStudy (and optionally a Patient) from DICOM files of one study.")
        @Argument var files: [String]
        @Option var patient: String?
        @Option var endpoint: String?
        @Flag(name: .customLong("with-patient")) var withPatient = false
        @Flag var pretty = false

        mutating func run() throws {
            let datasets = try files.map { try DCMDecoder(data: Data(contentsOf: URL(fileURLWithPath: $0))).dataSet }
            let study = try FHIRImagingMapper.imagingStudy(from: datasets, options: .init(patientReference: patient, endpointReference: endpoint))
            if withPatient {
                var bundle = FHIRBundle(type: "collection")
                bundle.entries = [FHIRBundleEntry(resource: FHIRImagingMapper.patient(from: datasets[0]).resource), FHIRBundleEntry(resource: study.resource)]
                FileHandle.standardOutput.write(bundle.resource.jsonData(pretty: pretty))
            } else {
                FileHandle.standardOutput.write(study.resource.jsonData(pretty: pretty))
            }
        }
    }

    struct Client: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "client", subcommands: [Get.self, Search.self])

        struct Get: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "get", abstract: "Read Type/id from a FHIR server (https unless --intranet-lab).")
            @Argument var base: String
            @Argument var reference: String
            @Option(name: .customLong("bearer")) var bearer: String?
            @Option(name: .customLong("intranet-lab"), help: "Loopback/lab host allowed over plain http.") var intranetLab: String?

            mutating func run() async throws {
                let client = try fhirClient(base: base, bearer: bearer, intranetLab: intranetLab)
                let parts = reference.split(separator: "/").map(String.init)
                guard parts.count == 2 else { throw ValidationError("Use Type/id") }
                let result = try await client.read(parts[0], id: parts[1])
                switch result {
                case .success(let resource, let metadata):
                    if let resource { FileHandle.standardOutput.write(resource.jsonData(pretty: true)) }
                    FileHandle.standardError.write(Data("status=\(metadata.status) etag=\(metadata.etag ?? "-")\n".utf8))
                case .failure(let failure):
                    FileHandle.standardError.write(Data("failure \(failure.reason) status=\(failure.status.map(String.init) ?? "-") uncertain=\(failure.uncertain)\n".utf8))
                    throw ExitCode(2)
                }
            }
        }

        struct Search: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "search", abstract: "Search one resource type; prints the first page as a Bundle.")
            @Argument var base: String
            @Argument var type: String
            @Option(name: .customLong("param"), help: "name=value, repeatable.") var params: [String] = []
            @Option(name: .customLong("bearer")) var bearer: String?
            @Option(name: .customLong("intranet-lab")) var intranetLab: String?

            mutating func run() async throws {
                let client = try fhirClient(base: base, bearer: bearer, intranetLab: intranetLab)
                var query = FHIRSearchQuery(resourceType: type)
                for param in params {
                    guard let separator = param.firstIndex(of: "=") else { throw ValidationError("Parameters are name=value") }
                    query = query.where(.init(name: String(param[..<separator]), values: [String(param[param.index(after: separator)...])]))
                }
                switch try await client.search(query) {
                case .success(let page, _):
                    FileHandle.standardOutput.write(page.bundle.resource.jsonData(pretty: true))
                    FileHandle.standardError.write(Data("matches=\(page.matches.count) included=\(page.included.count) total=\(page.total.map(String.init) ?? "-")\n".utf8))
                case .failure(let failure):
                    FileHandle.standardError.write(Data("failure \(failure.reason) status=\(failure.status.map(String.init) ?? "-")\n".utf8))
                    throw ExitCode(2)
                }
            }
        }
    }
}

private func readFHIR(_ file: String) throws -> FHIRResource {
    let data = try Data(contentsOf: URL(fileURLWithPath: file))
    if data.first == UInt8(ascii: "<") { return try FHIRResource(xmlData: data) }
    return try FHIRResource(jsonData: data)
}

private func fhirClient(base: String, bearer: String?, intranetLab: String?) throws -> FHIRClient {
    guard let url = URL(string: base) else { throw ValidationError("Invalid base URL") }
    var policy = HL7v3TransportPolicy(timeout: 20)
    if let intranetLab {
        var address = in_addr()
        guard intranetLab.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            throw ValidationError("--intranet-lab requires an IPv4 address")
        }
        let value = UInt32(bigEndian: address.s_addr)
        guard value >> 24 == 127 || value >> 24 == 10 || value >> 20 == 0xAC1 || value >> 16 == 0xC0A8 else {
            throw ValidationError("--intranet-lab accepts loopback or private hosts only")
        }
        policy.allowInsecureForHosts = [intranetLab]
    }
    let token = bearer
    return FHIRClient(configuration: .init(baseURL: url, policy: policy), additionalHeaders: { token.map { ["Authorization": "Bearer " + $0] } ?? [:] })
}
