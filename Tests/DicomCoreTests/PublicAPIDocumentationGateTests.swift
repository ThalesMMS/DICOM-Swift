//
//  PublicAPIDocumentationGateTests.swift
//  DicomCoreTests
//
//  Checks acceptance of documented declarations and rejection of undocumented public APIs.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
import XCTest

final class PublicAPIDocumentationGateTests: XCTestCase {
    func testGateAcceptsDocumentedPublicDeclaration() throws {
        let source = """
        /// Loads a decoded series into a renderer-ready value.
        public struct DocumentedLoader {
            /// Creates a documented loader.
            public init() {}
        }
        """
        let file = try writeTemporarySwiftFile(source)
        let result = try runGate(paths: [file.path])

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("passed"))
    }

    func testGateRejectsUndocumentedPublicDeclaration() throws {
        let source = """
        public struct UndocumentedLoader {
            public init() {}
        }
        """
        let file = try writeTemporarySwiftFile(source)
        let result = try runGate(paths: [file.path])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("public API declaration needs a DocC comment"), result.output)
        XCTAssertTrue(result.output.contains("UndocumentedLoader"), result.output)
    }

    private func writeTemporarySwiftFile(_ source: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("public-api-doc-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Fixture.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func runGate(paths: [String]) throws -> GateResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repoRoot.appendingPathComponent("Tooling/check_public_api_docs.py").path, "--paths"] + paths

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return GateResult(status: process.terminationStatus, output: output)
    }

    private var repoRoot: URL {
        try! Self.packageRoot(callerFile: #filePath)
    }

    private static func packageRoot(callerFile: String) throws -> URL {
        var directory = URL(fileURLWithPath: callerFile).deletingLastPathComponent()
        let fileManager = FileManager.default

        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("Package.swift")
            if fileManager.fileExists(atPath: candidate.path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }

        throw NSError(
            domain: "PublicAPIDocumentationGateTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate package root from \(callerFile)."]
        )
    }
}

private struct GateResult {
    let status: Int32
    let output: String
}
