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
            "Backlog Alignment",
            "issue #1064",
            "issue #1077",
            "#1078 through",
            "#1090"
        ])

        assert(readme, contains: [
            "DicomTransferSyntaxRegistry.standard.compressedPixelSupportMatrix",
            "DicomTransferSyntaxRegistry.standard.writeSupportMatrix",
            "DicomWebConformanceMatrix.packageDefault",
            "DIMSE scope",
            "MockDicomDecoderForPreviews",
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
            "Basic Grayscale/Color Print",
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
            XCTAssertTrue(diagnostic.contains("unsupported") || diagnostic.contains("requires an explicit")
                          || diagnostic.contains("no local multi-component frame decoder is qualified"),
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

        XCTAssertTrue(migration.contains("Migration Status in 2.0.x"))
        XCTAssertTrue(migration.contains("project checklist; current package documentation reconciliation"))
        XCTAssertFalse(migration.contains("- [ ]"))
    }

    func testMigrationGuideDescribesReleasedTwoZeroLine() throws {
        let migration = try Self.packageText("Sources/DicomCore/DicomCore.docc/Articles/MigrationGuide.md")

        // 2.0.0 shipped without removing the v1 decoder APIs, so the guide
        // must not present that release as future or promise those removals.
        for stale in ["Planned for removal in v2.0.0", "planned for removal in v2.0.0",
                      "v2.0.0** (planned)", "planned v2.0.0", "Version 2.0.0 is planned"] {
            XCTAssertFalse(migration.contains(stale), stale)
        }
        assert(migration, contains: [
            "## v1 APIs in 2.0.x",
            "### Removed Before 2.0.0",
            "### Still Present in 2.0.x, Deprecated",
            "### Still Present in 2.0.x, Not Deprecated",
            "### Removal Plan"
        ])
    }

    func testDocumentationGapIsMarkedReconciledAndGuarded() throws {
        let gaps = try Self.packageText("IMPLEMENTATION_GAPS.md")

        XCTAssertTrue(gaps.contains("Documentation Drift and Migration Checklist Reconciled"))
        XCTAssertTrue(gaps.contains("Status: reconciled and guarded by #1077."))
        XCTAssertTrue(gaps.contains("DocumentationReconciliationTests.swift"))
        XCTAssertTrue(gaps.contains("None currently tracked in the package audit after #1074."))
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
