import Foundation
import XCTest

final class DicomTargetBoundaryTests: XCTestCase {
    func test_minimumGraph_preservesCompatibilityAndIndependentProducts() throws {
        let result = try evaluate("boundary.validate_graph(package)\nprint('valid')")
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "valid\n")
    }

    func test_reverseDependency_isRejected() throws {
        let result = try evaluate(#"""
        package['targets'][0]['dependencies'] = [{'byName': ['DicomCore', None]}]
        boundary.validate_graph(package)
        """#)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Forbidden minimum-target dependency"), result.output)
    }

    func test_compatibilityCycle_isRejected() throws {
        let result = try evaluate(#"""
        package['targets'][-1]['dependencies'].append({'byName': ['DicomSwiftUI', None]})
        package['targets'].append({'name': 'DicomSwiftUI', 'dependencies': [{'byName': ['DicomCore', None]}]})
        boundary.validate_graph(package)
        """#)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Target dependency cycle"), result.output)
    }

    func test_uiLinkage_isRejectedEvenWithoutAnImport() throws {
        let result = try evaluate(#"""
        package['targets'][0]['settings'] = [{'tool': 'linker', 'kind': {'linkedFramework': {'_0': 'SwiftUI'}}}]
        boundary.validate_graph(package)
        """#)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Forbidden minimum-target linkage"), result.output)
    }

    func test_forbiddenImport_isRejectedInMinimumImplementation() throws {
        let result = try evaluate(#"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in boundary.MINIMUM:
                source = root / 'Sources' / name / 'Operation.swift'
                source.parent.mkdir(parents=True)
                source.write_text('import Foundation\nstruct Operation {}')
            (root / 'Sources' / 'DicomData' / 'Operation.swift').write_text('@_exported import SwiftUI')
            boundary.validate_sources(root, boundary.validate_graph(package))
        """#)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Forbidden import in DicomData"), result.output)
    }

    func test_rasterImport_isRejectedInRenderer() throws {
        let result = try evaluate(#"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'Sources' / 'MTKCore' / 'Operation.swift'
            source.parent.mkdir(parents=True)
            source.write_text('import struct J2KCore.J2KImage')
            boundary.validate_mtk(root)
        """#)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("DICOM/PACS/codec dependency in MTK"), result.output)
    }

    func test_mtkPackage_preservesIndependentProducts() throws {
        let result = try evaluate("boundary.validate_mtk_graph(mtk)\nprint('valid')")
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "valid\n")
    }

    func test_mtkExternalDependency_isRejectedEvenWithoutAnImport() throws {
        let result = try evaluate(#"""
        mtk['targets'][0]['dependencies'] = [{'product': ['DicomData', 'DICOM-Swift', None, None]}]
        boundary.validate_mtk_graph(mtk)
        """#)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Forbidden MTK target dependency"), result.output)
    }

    private func evaluate(_ body: String) throws -> (status: Int32, output: String) {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let prelude = #"""
        import importlib.util, sys, tempfile
        from pathlib import Path
        spec = importlib.util.spec_from_file_location('boundary', sys.argv[1])
        boundary = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(boundary)
        targets = [{'name': name, 'dependencies': [{'byName': [d, None]} for d in allowed]}
                   for name, allowed in boundary.MINIMUM.items()]
        targets.append({'name': 'DicomCore', 'dependencies': [{'byName': [n, None]} for n in boundary.MINIMUM]})
        names = set(boundary.MINIMUM) | boundary.LEGACY_PRODUCTS
        package = {'targets': targets, 'products': [{'name': n, 'targets': [n]} for n in names]}
        mtk_targets = [{'name': n, 'dependencies': [] if n == 'MTKCore' else [{'byName': ['MTKCore', None]}]}
                       for n in ['MTKCore', 'MTKUI', 'MTKFixtures']]
        mtk = {'targets': mtk_targets, 'products': [{'name': t['name'], 'targets': [t['name']]} for t in mtk_targets]}

        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", prelude + "\n" + body,
                             packageRoot.appendingPathComponent("Scripts/validate_target_boundaries.py").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
