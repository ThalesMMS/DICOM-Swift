import Foundation
import XCTest

final class SourcePolicyTests: XCTestCase {
    func testCoreSourcesDoNotImportUIFrameworksOrDeclareRemovedProducts() throws {
        let package = try packageText("Package.swift")
        XCTAssertFalse(package.contains("DicomSwiftUI"))
        XCTAssertFalse(package.contains("DicomSwiftUIExample"))
        XCTAssertFalse(package.contains("DicomSwiftUITests"))

        let sources = try scanSources(in: "Sources")
        for (path, source) in sources {
            XCTAssertFalse(source.contains("import SwiftUI"), path)
            XCTAssertFalse(source.contains("import UIKit"), path)
            XCTAssertFalse(source.contains("import AppKit"), path)
        }
    }

    private func scanSources(in relativePath: String) throws -> [String: String] {
        let root = try packageRoot()
        let base = root.appendingPathComponent(relativePath)
        var result: [String: String] = [:]

        guard let enumerator = FileManager.default.enumerator(at: base,
                                                             includingPropertiesForKeys: nil) else {
            return result
        }

        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            result[url.path.replacingOccurrences(of: root.path + "/", with: "")] = try String(contentsOf: url, encoding: .utf8)
        }

        return result
    }

    private func packageRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default

        while directory.path != "/" {
            if fileManager.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }

        throw NSError(domain: "SourcePolicyTests",
                      code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not locate package root."])
    }

    private func packageText(_ relativePath: String) throws -> String {
        let root = try packageRoot()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
