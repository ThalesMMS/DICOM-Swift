import Foundation
@testable import DicomCore
import XCTest

final class DocumentationReconciliationTests: XCTestCase {
    func testSupportMatrixReferencesStayVisibleInDocs() throws {
        let conformance = try Self.packageText("Sources/DicomCore/DicomCore.docc/Articles/ConformanceStatement.md")
        let readme = try Self.packageText("README.md")

        assert(conformance, contains: [
            "DicomTransferSyntaxRegistry.standard.compressedPixelSupportMatrix",
            "DicomTransferSyntaxRegistry.standard.writeSupportMatrix",
            "DicomWebConformanceMatrix/packageDefault",
            "DicomExportSupportMatrix/packageDefault",
            "DicomSeriesLoaderSupportMatrix",
            "DicomSRSupportMatrix",
            "DicomSRSemanticValidator",
            "DicomPrintManagementSupport",
            "DicomWaveformStorageKind",
            "DicomVideoCodec",
            "Current Scope",
            "Presentation and interaction policy is caller-owned",
            "decoded values, frames, series, and explicit exports"
        ])

        assert(readme, contains: [
            "DicomTransferSyntaxRegistry.standard.compressedPixelSupportMatrix",
            "DicomTransferSyntaxRegistry.standard.writeSupportMatrix",
            "DicomWebConformanceMatrix.packageDefault",
            "DIMSE scope",
            "DicomCodecRuntimePreflight.status(for: .charLS)",
            "DicomCodecRuntimePreflight.status(for: .openJPEG)"
        ])
    }

    func testDIMSEAndDICOMwebDocsDeclareHelperScope() throws {
        let conformance = try Self.packageText("Sources/DicomCore/DicomCore.docc/Articles/ConformanceStatement.md")
        let readme = try Self.packageText("README.md")
        let gaps = try Self.packageText("IMPLEMENTATION_GAPS.md")

        assert(conformance, contains: [
            "C-ECHO",
            "C-FIND",
            "C-GET",
            "C-MOVE",
            "C-STORE",
            "Storage SCP",
            "Storage Commitment",
            "MPPS",
            "Basic Grayscale Print",
            "User identity",
            "Pooling/retry/cancellation",
            "not a full managed PACS service",
            "not a complete production PACS"
        ])
        XCTAssertFalse(conformance.contains("network service classes are not implemented"))
        XCTAssertFalse(conformance.contains("does not implement SCU/SCP"))

        XCTAssertTrue(readme.contains("DIMSE helpers for tested C-ECHO"))
        XCTAssertTrue(readme.contains("They are not a managed PACS service"))

        XCTAssertTrue(gaps.contains("DIMSE and Network Scope Is Reconciled to Tested Helpers"))
        XCTAssertTrue(gaps.contains("Status: scoped and guarded"))
        XCTAssertFalse(gaps.contains("DIMSE and Network Documentation/Parity Need Reconciliation"))
    }

    func testRegistryDiagnosticsDoNotClaimUnsupportedFeaturesAreSupported() {
        let registry = DicomTransferSyntaxRegistry.standard

        for row in registry.compressedPixelSupportMatrix where row.status == .unsupported {
            let diagnostic = row.diagnostic.lowercased()
            XCTAssertTrue(diagnostic.contains("unsupported") || diagnostic.contains("requires an explicit"),
                          "\(row.name) should explain why native decode is unsupported.")
            XCTAssertFalse(diagnostic.contains("decoded natively"),
                           "\(row.name) should not claim native decode in unsupported diagnostics.")
        }

        for row in registry.compressedPixelSupportMatrix where row.status == .streamedOnly {
            let diagnostic = row.diagnostic.lowercased()
            XCTAssertTrue(diagnostic.contains("stream") || diagnostic.contains("encoded video payload"),
                          "\(row.name) should describe streamed-only behavior.")
            XCTAssertFalse(diagnostic.contains("decoded natively"),
                           "\(row.name) should not claim native decode in streamed-only diagnostics.")
        }

        for row in registry.writeSupportMatrix where row.status == .encapsulatedPassThrough {
            XCTAssertTrue(row.diagnostic.contains("does not encode compressed frames"), row.name)
        }
    }

    func testMigrationGuideHasNoStaleUncheckedChecklistItems() throws {
        let migration = try Self.packageText("Sources/DicomCore/DicomCore.docc/Articles/MigrationGuide.md")

        XCTAssertTrue(migration.contains("Migration Status Before v2.0.0"))
        XCTAssertTrue(migration.contains("project checklist; current package documentation reconciliation"))
        XCTAssertFalse(migration.contains("- [ ]"))
    }

    func testDocumentationGapIsMarkedReconciledAndGuarded() throws {
        let gaps = try Self.packageText("IMPLEMENTATION_GAPS.md")

        XCTAssertTrue(gaps.contains("Documentation Drift and Migration Checklist Reconciled"))
        XCTAssertTrue(gaps.contains("Status: reconciled and guarded by documentation tests."))
        XCTAssertTrue(gaps.contains("DocumentationReconciliationTests.swift"))
        XCTAssertTrue(gaps.contains("No application-facing module is tracked by this package audit."))
    }

    private func assert(
        _ document: String,
        contains snippets: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for snippet in snippets {
            XCTAssertTrue(
                document.contains(snippet),
                "Missing documentation snippet: \(snippet)",
                file: file,
                line: line
            )
        }
    }

    private static func packageText(_ path: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(path), encoding: .utf8)
    }

    private static func packageRoot(callerFile: String = #filePath) throws -> URL {
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
            domain: "DocumentationReconciliationTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate package root from \(callerFile)."]
        )
    }
}
