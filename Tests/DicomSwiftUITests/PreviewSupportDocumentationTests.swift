import Foundation
import XCTest

final class PreviewSupportDocumentationTests: XCTestCase {
    func testPreviewMockIsDocumentedAsPreviewOnly() throws {
        let packageRoot = try Self.packageRoot()
        let mockSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/DicomSwiftUI/Preview/MockDicomDecoderForPreviews.swift"),
            encoding: .utf8
        )
        let previewSupport = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/DicomSwiftUI/DicomSwiftUI.docc/PreviewSupport.md"),
            encoding: .utf8
        )

        XCTAssertTrue(mockSource.contains("supported public preview API only"))
        XCTAssertTrue(mockSource.contains("not a clinical or runtime decoder"))
        XCTAssertTrue(previewSupport.contains("supported public preview APIs"))
        XCTAssertTrue(previewSupport.contains("not clinical/runtime decoders"))
        XCTAssertTrue(previewSupport.contains("must not be used for production"))
    }

    private static func packageRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default

        while directory.path != "/" {
            if fileManager.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }

        throw NSError(
            domain: "PreviewSupportDocumentationTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate package root."]
        )
    }
}
