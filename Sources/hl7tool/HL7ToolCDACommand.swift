import ArgumentParser
import DicomCore
import Foundation
import HL7v3CDA
import HL7v2

struct CDACommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cda", abstract: "Parse, validate, transform and encapsulate CDA documents.", subcommands: [
        Parse.self, Validate.self, Build.self, Diff.self, Merge.self, Version.self, Render.self, Transform.self,
        Encapsulate.self, Extract.self
    ])

    struct Parse: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "parse")
        @Argument var file: String
        @Flag var json = false

        mutating func run() throws {
            let document = try readCDA(file)
            if json {
                let sections = document.body.flatMap { body -> [Section]? in
                    guard case .structured(let structured) = body else { return nil }
                    return structured.sections
                } ?? []
                let object: [String: Any] = [
                    "root": document.node.name.localName,
                    "title": document.title?.text ?? "",
                    "templateIds": document.templateIds.compactMap(\.root),
                    "sections": sections.map { [
                        "code": $0.code?.code ?? "",
                        "title": $0.title?.text ?? "",
                        "entryCount": $0.entries.count
                    ] }
                ]
                writeCDA(try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            } else {
                writeCDA(try CDADocumentSerializer().serialize(document))
            }
        }
    }

    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "validate")
        @Argument var file: String
        @Option(name: .customLong("template")) var templates: [String] = []
        @Flag var strict = false

        mutating func run() throws {
            let document = try readCDA(file)
            let references = templates.isEmpty ? nil : templates.map { CDATemplateReference(root: $0) }
            let report = CDAValidator().validate(document, against: references)
            for finding in report.findings {
                print("\(finding.path) \(finding.severity.rawValue) \(finding.code)")
            }
            print("coverage evaluated=\(report.coverage.evaluated) notEvaluable=\(report.coverage.notEvaluable) errors=\(report.errors.count) warnings=\(report.warnings.count)")
            if !report.isValid || (strict && !report.warnings.isEmpty) { throw ExitCode(2) }
        }
    }

    struct Build: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "build")
        @Argument var template: String
        @Option(name: .customLong("from")) var specification: String

        mutating func run() throws {
            let specificationData = try Data(contentsOf: URL(fileURLWithPath: specification))
            let object = try JSONSerialization.jsonObject(with: specificationData) as? [String: Any] ?? [:]
            let title = object["title"] as? String ?? "CDA Document"
            let code = object["code"] as? String ?? "34133-9"
            let codeSystem = object["codeSystem"] as? String ?? "2.16.840.1.113883.6.1"
            let builder = CDADocumentBuilder(templateSet: CDATemplateLibrary.registry, allowInvalid: true)
            builder.header(idRoot: (object["idRoot"] as? String) ?? "2.25.2362",
                          idExtension: object["idExtension"] as? String,
                          code: code, codeSystem: codeSystem, title: title)
            let templateID = CDATemplateReference(root: template)
            let narrative = object["narrative"] as? String ?? "CDA narrative"
            builder.section(template: templateID, code: code, title: title) { section in
                section.narrative(narrative)
            }
            writeCDA(try CDADocumentSerializer().serialize(builder.build(allowInvalid: true)))
        }
    }

    struct Diff: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "diff")
        @Argument var a: String
        @Argument var b: String

        mutating func run() throws {
            let diff = CDADocumentComparator.compare(try readCDA(a), try readCDA(b))
            for change in diff.changes { print("\(change.kind.rawValue) \(change.path)") }
            for change in diff.narrativeChanges { print("changed \(change.path)") }
        }
    }

    struct Merge: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "merge")
        @Argument var base: String
        @Argument var incoming: String
        @Option var policy = CDAMergePolicy.preferIncoming.rawValue

        mutating func run() throws {
            guard let selected = CDAMergePolicy(rawValue: policy) else { throw ValidationError("Unsupported merge policy") }
            let result = CDADocumentMerger.merge(base: try readCDA(base), incoming: try readCDA(incoming), policy: selected)
            writeCDA(try CDADocumentSerializer().serialize(result.document))
            for conflict in result.conflicts { FileHandle.standardError.write(Data("conflict \(conflict.path)\n".utf8)) }
        }
    }

    struct Version: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "version")
        @Argument var kind: String
        @Argument var file: String

        mutating func run() throws {
            let document = try readCDA(file)
            let versioned: ClinicalDocument
            switch kind.lowercased() {
            case "new": versioned = try CDADocumentVersioning.newVersion(of: document)
            case "appendix": versioned = try CDADocumentVersioning.appendix(of: document)
            default: throw ValidationError("Use new or appendix")
            }
            writeCDA(try CDADocumentSerializer().serialize(versioned))
        }
    }

    struct Render: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "render")
        @Argument var file: String
        @Flag var text = false
        @Flag var html = false

        mutating func run() throws {
            guard text != html else { throw ValidationError("Specify exactly one of --text or --html") }
            let document = try readCDA(file)
            print(text ? CDARenderer.renderText(document) : CDARenderer.renderHTML(document), terminator: "\n")
        }
    }

    struct Transform: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "transform", subcommands: [V2ToCDA.self, CDAToV2.self])

        struct V2ToCDA: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "v2-to-cda")
            @Argument var file: String
            @Option var profile: String?
            @Flag var strict = false

            mutating func run() throws {
                let message = try HL7Parser().parse(Data(contentsOf: URL(fileURLWithPath: file)))
                let selected = try profile.map { value -> CDATransformProfile in
                    guard let profile = CDATransformProfile(rawValue: value.lowercased()) else { throw ValidationError("Unsupported CDA profile") }
                    return profile
                }
                let result = try CDATransformer.v2ToCDA(message, profile: selected, options: .init(strict: strict))
                writeCDA(try CDADocumentSerializer().serialize(result.document))
                emitReport(result.report)
            }
        }

        struct CDAToV2: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "cda-to-v2")
            @Argument var file: String
            @Option var profile: String
            @Flag var strict = false

            mutating func run() throws {
                guard let selected = CDATransformProfile(rawValue: profile.lowercased()) else { throw ValidationError("Unsupported CDA profile") }
                let result = try CDATransformer.cdaToV2(try readCDA(file), profile: selected, options: .init(strict: strict))
                writeCDA(try HL7Serializer().serialize(result.message))
                emitReport(result.report)
            }
        }
    }

    struct Encapsulate: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "encapsulate")
        @Argument var file: String
        @Option(name: .customLong("patient-json")) var patientJSON: String
        @Option(name: [.customShort("o"), .customLong("output")]) var output: String
        @Flag(name: .customLong("allow-mismatch"), help: "Accept a patient module that differs from the CDA recordTarget.") var allowMismatch = false

        mutating func run() throws {
            let patient = try JSONDecoder().decode(CDAEncapsulation.PatientModule.self,
                                                    from: Data(contentsOf: URL(fileURLWithPath: patientJSON)))
            let data = try CDAEncapsulation.export(document: readCDA(file), patientModule: patient,
                                                   options: .init(allowMismatch: allowMismatch))
            try data.write(to: URL(fileURLWithPath: output), options: [.atomic])
        }
    }

    struct Extract: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "extract")
        @Argument var file: String
        @Option(name: .customShort("o")) var output: String

        mutating func run() throws {
            let data = try Data(contentsOf: URL(fileURLWithPath: file))
            let (document, _) = try CDAEncapsulation.import(part10: data)
            try CDADocumentSerializer().serialize(document).write(to: URL(fileURLWithPath: output), options: [.atomic])
        }
    }
}

private func readCDA(_ file: String) throws -> ClinicalDocument {
    try CDADocumentParser().parse(Data(contentsOf: URL(fileURLWithPath: file)))
}

private func writeCDA(_ data: Data) { FileHandle.standardOutput.write(data) }

private func emitReport(_ report: CDATransformReport) {
    let line = "report mapped=\(report.mappedCount) absent=\(report.absentCount) changed=\(report.changedCount) lost=\(report.lostCount) warnings=\(report.warningCount)\n"
    FileHandle.standardError.write(Data(line.utf8))
}
