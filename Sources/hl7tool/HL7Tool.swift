import ArgumentParser
import Foundation
import HL7v2
import ClinicalMapping
import FHIR
import HL7v3CDA

@main
struct HL7Tool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hl7tool",
        abstract: "Parse, validate, build and inspect HL7 v2 messages, CDA documents and FHIR resources.",
        subcommands: [Parse.self, Validate.self, Serialize.self, Build.self, Diff.self, Batch.self, Inspect.self, MLLPCommand.self, CDACommand.self, FHIRCommand.self, WorkflowCommand.self, SMARTCommand.self, BenchCommand.self])
}

func readHL7(_ file: String, charset: String? = nil, lenient: Bool = false) throws -> HL7Message {
    var options = HL7ParserOptions()
    options.lenientTerminators = lenient
    if let charset {
        let override = HL7Charset(declaration: charset)
        if case .unknown = override { throw ValidationError("Unsupported charset override") }
        options.charsetOverride = override
    }
    return try HL7Parser(options: options).parse(Data(contentsOf: URL(fileURLWithPath: file)))
}

func writeHL7(_ bytes: Data) { FileHandle.standardOutput.write(bytes) }

struct Parse: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "parse")
    @Argument var file: String
    @Flag var json = false
    @Option var charset: String?
    @Flag var lenient = false
    mutating func run() throws {
        let message = try readHL7(file, charset: charset, lenient: lenient)
        if json { writeHL7(try HL7JSON.encode(message)) }
        else { print(HL7Inspector.describe(message)) }
    }
}

struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect")
    @Argument var file: String
    @Flag var values = false
    mutating func run() throws { print(HL7Inspector.describe(try readHL7(file), includeValues: values)) }
}

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "validate")
    @Argument var file: String
    @Option var version: String?
    @Option var profile: String?
    @Flag var values = false
    mutating func run() throws {
        guard (version == nil) != (profile == nil) else { throw ValidationError("Specify exactly one of --version or --profile") }
        let selected = try profile.map { try JSONDecoder().decode(HL7Profile.self, from: Data(contentsOf: URL(fileURLWithPath: $0))) }
        let requested = selected?.baseVersion ?? HL7Version(rawValue: version!)
        guard let schema = HL7SchemaRegistry.shared.schema(for: requested) else { throw ValidationError("Unsupported version") }
        do {
            let message = try readHL7(file)
            var options = HL7ValidationOptions()
            options.includeValues = values
            let report = HL7Validator(schema: schema, profile: selected, options: options).validate(message)
            for finding in report.findings { print("\(finding.path) \(finding.severity.rawValue) \(finding.detail)") }
            if !report.isValid { throw ExitCode(2) }
        } catch is HL7ParseError {
            print("message error malformedContent")
            throw ExitCode(2)
        }
    }
}

struct Serialize: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serialize")
    @Argument var json: String
    mutating func run() throws {
        writeHL7(try HL7Serializer().serialize(HL7JSON.decode(Data(contentsOf: URL(fileURLWithPath: json)))))
    }
}

struct Diff: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "diff")
    @Argument var a: String
    @Argument var b: String
    mutating func run() throws {
        for change in try HL7Diff.compare(readHL7(a), readHL7(b)) { print("\(change.path) \(change.change.rawValue)") }
    }
}

struct Build: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "build")
    @Argument var kind: String
    @Option var version = "2.5.1"
    @Option var patientID = "SYNTHETIC"
    @Option var familyName = "Example"
    @Option var controlID = "CONTROL"
    @Option var service = "TEST"
    @Option var value = "1"
    @Option var original: String?
    func message() throws -> HL7Message {
        var builder = HL7MessageBuilder(version: HL7Version(rawValue: version))
        switch kind {
        case "adt-a01":
            var pid = HL7Segment(name: "PID")
            pid[3] = HL7Field(repetitions: [HL7ExtendedID(id: patientID, identifierType: "MR").hl7Value])
            pid[5] = HL7Field(repetitions: [HL7PersonName(family: familyName).hl7Value])
            var pv1 = HL7Segment(name: "PV1")
            pv1[2] = HL7Field(.text("I"))
            builder.adt(event: .A01, pid: pid, pv1: pv1)
        case "orm-o01":
            builder.orm(order: .init(placerID: controlID, service: .init(identifier: service, system: "LOCAL")))
        case "oru-r01":
            builder.oru(results: [.init(identifier: .init(identifier: service, system: "LOCAL"), dataType: .ST,
                                       value: HL7Field(.text(value))[1])])
        case "qbp-q22": builder.qbpQ22(patientID: patientID)
        case "ack":
            guard let original else { throw ValidationError("ack requires --original <file>") }
            builder.ack(for: try readHL7(original), code: .AA)
        default: throw ValidationError("Unknown build kind")
        }
        builder.set(HL7Path(segment: "MSH", field: 10), .text(controlID))
        return try builder.build()
    }
    mutating func run() throws { writeHL7(try HL7Serializer().serialize(message())) }
}

struct Batch: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "batch", subcommands: [Split.self, Join.self])
    struct Split: ParsableCommand {
        @Argument var file: String
        @Option var output: String
        mutating func run() throws {
            let wire = try Data(contentsOf: URL(fileURLWithPath: file))
            let document = try HL7BatchDocument.parse(wire)
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // The wire manifest retains custom envelope fields, counts and terminators for exact rejoining.
            try wire.write(to: directory.appendingPathComponent("envelope.hl7"), options: .withoutOverwriting)
            for (index, range) in document.messageRanges.enumerated() {
                try wire.subdata(in: range).write(to: directory.appendingPathComponent(String(format: "%06d.hl7", index)),
                                                  options: .withoutOverwriting)
            }
        }
    }
    struct Join: ParsableCommand {
        @Argument var files: [String]
        @Flag var fileEnvelope = false
        mutating func run() throws {
            guard !files.isEmpty else { throw ValidationError("Supply message files or one split directory") }
            var isDirectory: ObjCBool = false
            if files.count == 1, FileManager.default.fileExists(atPath: files[0], isDirectory: &isDirectory), isDirectory.boolValue {
                let directory = URL(fileURLWithPath: files[0], isDirectory: true)
                let wire = try Data(contentsOf: directory.appendingPathComponent("envelope.hl7"))
                let document = try HL7BatchDocument.parse(wire)
                for (index, range) in document.messageRanges.enumerated() {
                    let member = try Data(contentsOf: directory.appendingPathComponent(String(format: "%06d.hl7", index)))
                    guard member == wire.subdata(in: range) else { throw ValidationError("Split member differs from envelope manifest") }
                }
                writeHL7(wire)
            } else {
                writeHL7(try HL7BatchDocument.join(files.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }, fileEnvelope: fileEnvelope))
            }
        }
    }
}
