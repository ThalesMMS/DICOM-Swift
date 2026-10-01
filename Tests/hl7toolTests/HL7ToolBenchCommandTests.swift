import ArgumentParser
import Darwin
import Foundation
import HL7v2
import XCTest
@testable import hl7tool

final class HL7ToolBenchCommandTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hl7tool-bench-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func capture(_ action: () throws -> Void) throws -> Data {
        let file = try temporaryDirectory().appendingPathComponent("stdout")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        dup2(handle.fileDescriptor, STDOUT_FILENO)
        defer { fflush(stdout); dup2(saved, STDOUT_FILENO); close(saved); try? handle.close() }
        try action()
        fflush(stdout)
        return try Data(contentsOf: file)
    }

    func test_bench_matchesLibraryAndFailsWithoutCorpus() throws {
        let corpus = try temporaryDirectory()
        let message = "MSH|^~\\&|APP|FAC|RCV|RFAC|20260912120000||ADT^A01^ADT_A01|MSG1|P|2.5.1\rPID|1||P1^^^HOSP^MR||Bench^Case||19800101|F\rPV1|1|I\r"
        try Data(message.utf8).write(to: corpus.appendingPathComponent("a.hl7"))
        try Data("MSH|garbage".utf8).write(to: corpus.appendingPathComponent("b.hl7"))
        try Data("ignored".utf8).write(to: corpus.appendingPathComponent("notes.txt"))
        var command = try HL7Tool.parseAsRoot(["bench", corpus.path, "--iterations", "2"])
        let stdout = try capture { try command.run() }
        let cli = try JSONDecoder().decode(HL7BenchmarkResult.self, from: stdout)
        let api = try HL7Benchmark.run(corpus: corpus, iterations: 2, toolkitVersion: cli.toolkitVersion)
        XCTAssertEqual(cli.files.map(\.path), api.files.map(\.path))
        XCTAssertEqual(cli.files.map(\.sha256), api.files.map(\.sha256))
        XCTAssertEqual(cli.files.count, 2, "only .hl7 files are part of the corpus")
        XCTAssertEqual(cli.files[0].messageType, "ADT^A01"); XCTAssertEqual(cli.files[0].segments, 3); XCTAssertNotNil(cli.files[0].parseMedianSeconds)
        XCTAssertNotNil(cli.files[1].error); XCTAssertNil(cli.files[1].parseMedianSeconds)
        XCTAssertEqual(cli.disclaimer, HL7BenchmarkResult.disclaimer)
        let output = corpus.appendingPathComponent("../bench-\(UUID()).json").standardizedFileURL
        var toFile = try HL7Tool.parseAsRoot(["bench", corpus.appendingPathComponent("a.hl7").path, "--output", output.path])
        try toFile.run()
        XCTAssertEqual(try JSONDecoder().decode(HL7BenchmarkResult.self, from: try Data(contentsOf: output)).files.count, 1)
        try? FileManager.default.removeItem(at: output)
        var missing = try HL7Tool.parseAsRoot(["bench", corpus.appendingPathComponent("nowhere").path])
        XCTAssertThrowsError(try missing.run()) { XCTAssertTrue($0 is ValidationError) }
        XCTAssertTrue(try HL7Benchmark.run(corpus: corpus, toolkitVersion: "t", isCancelled: { true }).cancelled)
        XCTAssertThrowsError(try HL7Benchmark.run(corpus: corpus, maximumFiles: 1, toolkitVersion: "t"))
    }
}
