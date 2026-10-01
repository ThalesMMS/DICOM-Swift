import ArgumentParser
import DicomCore
import DicomDocumentContent
import Foundation

struct DocumentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "document",
        abstract: "Inspect document envelopes and extract original payloads.", subcommands: [Info.self, Extract.self])

    static func load(_ file: String) async throws -> DicomEncapsulatedDocument {
        let decoder = try await DCMDecoder(contentsOf: URL(fileURLWithPath: file))
        guard let document = decoder.encapsulatedDocument else { throw ValidationError("No encapsulated document.") }
        return document
    }

    static func informationJSON(_ document: DicomEncapsulatedDocument) throws -> String {
        let verdict = DicomEncapsulatedDocumentEnvelopeValidator.validate(document)
        return try WaveformCommand.json([
            "kind": document.kind?.preferredFileExtension as Any? ?? NSNull(),
            "title": document.documentTitle as Any? ?? NSNull(), "mimeType": document.mimeType,
            "payloadBytes": document.documentData.count,
            "envelopeValid": verdict.isValid, "plausibility": verdict.contentPlausibility.verdict.rawValue,
            "plausibilityReason": verdict.contentPlausibility.reason,
            "diagnostics": verdict.diagnostics.map { ["code": $0.code.rawValue, "reason": $0.reason] },
            "limitations": verdict.limitations,
            "references": (document.sourceInstances + document.referencedImages + document.referencedInstances).map {
                ["sopClassUID": $0.referencedSOPClassUID as Any? ?? NSNull(),
                 "sopInstanceUID": $0.referencedSOPInstanceUID as Any? ?? NSNull(),
                 "relativeURI": $0.relativeURIReference as Any? ?? NSNull()]
            }
        ])
    }

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "info")
        @Argument var file: String
        mutating func run() async throws { print(try DocumentCommand.informationJSON(await DocumentCommand.load(file))) }
    }

    struct Extract: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "extract")
        @Argument var file: String
        @Argument var out: String
        mutating func run() async throws {
            try await DocumentCommand.load(file).writeDocument(to: URL(fileURLWithPath: out))
        }
    }
}
