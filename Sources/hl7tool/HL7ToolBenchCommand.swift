import ArgumentParser
import Foundation
import HL7v2

/// `hl7tool bench <corpus>`: parse/serialize timings over an explicit corpus (`.hl7` files) with digests.
struct BenchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bench", abstract: "Parse/serialize timings over an explicit corpus with digests and versions (not a conformance claim)")
    @Argument(help: "Corpus directory or .hl7 file") var corpus: String
    @Option(name: .long, help: "Iterations per file") var iterations: Int = 3
    @Option(name: .long, help: "Maximum files") var maxFiles: Int = 1000
    @Option(name: [.short, .long], help: "JSON result file (stdout when omitted)") var output: String?

    mutating func run() throws {
        let result: HL7BenchmarkResult
        do {
            result = try HL7Benchmark.run(corpus: URL(fileURLWithPath: corpus), iterations: iterations, maximumFiles: maxFiles,
                                          toolkitVersion: "hl7tool " + (HL7Tool.configuration.version.isEmpty ? "dev" : HL7Tool.configuration.version))
        } catch let error as HL7Benchmark.Failure { throw ValidationError(error.localizedDescription) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(result) + Data("\n".utf8)
        if let output {
            guard !FileManager.default.fileExists(atPath: output) else { throw ValidationError("\(output) exists") }
            try json.write(to: URL(fileURLWithPath: output), options: .atomic)
            FileHandle.standardError.write(Data("\(result.files.count) file(s); \(result.disclaimer)\n".utf8))
        } else { writeHL7(json) }
    }
}
