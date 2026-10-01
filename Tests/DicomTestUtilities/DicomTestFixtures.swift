import Foundation

/// Shared synthetic fixtures are read in place; they are not compiled or copied with Core.
package enum DicomTestFixtures {
    package static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DicomCoreTests/Fixtures", isDirectory: true)
    }
}
