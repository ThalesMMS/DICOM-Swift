import Foundation
import XCTest
@testable import DicomCore

struct PlacementFixture: Sendable {
    let root: URL
    let source: URL
    let destination: URL
    let journalURL: URL
    let fileSystem = DicomLocalIngestFileSystem()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        source = root.appendingPathComponent("source")
        destination = root.appendingPathComponent("destination")
        journalURL = root.appendingPathComponent("journal")
        try fileSystem.createDirectory(source)
        try fileSystem.createDirectory(destination)
    }
    func clean() { try? fileSystem.remove(root) }
    func item(_ key: String = "object", bytes: Data = Data("archive object".utf8)) throws -> DicomTransferManifest.Item {
        let url = source.appendingPathComponent(key)
        try fileSystem.write(bytes, to: url, append: false)
        return .init(objectKey: key, sourceLocator: key, destinationLocator: key,
                     byteCount: Int64(bytes.count), sha256: try fileSystem.checksum(url))
    }
    var journal: DicomTransferJournal { .init(directory: journalURL) }
    func coordinator(store: any DicomObjectStore, quotas: DicomRecallCoordinator.Quotas = .init()) -> DicomRecallCoordinator {
        .init(providers: ["source": DicomObjectStoreProvider(id: "source", store: store),
                          "destination": DicomLocalDiskProvider(id: "destination", root: destination)],
              journal: journal, quotas: quotas)
    }
}

@MainActor
func storageError(_ expected: DicomStorageProviderError,
                  _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await operation(); XCTFail("Expected error", file: file, line: line) }
    catch { XCTAssertEqual(error as? DicomStorageProviderError, expected, file: file, line: line) }
}

@MainActor
final class DicomStorageProviderTests: XCTestCase {
    func test_localRoundTripAndExplicitDeletion() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let item = try fixture.item()
        let provider = DicomLocalDiskProvider(id: "disk", root: fixture.destination)
        let result = try await provider.put(fixture.source.appendingPathComponent(item.sourceLocator),
                                            locator: "nested/object", expectedSHA256: item.sha256)
        XCTAssertEqual(result.sha256, item.sha256)
        let output = fixture.root.appendingPathComponent("output")
        _ = try await provider.get("nested/object", to: output, expectedSHA256: item.sha256)
        XCTAssertEqual(try fixture.fileSystem.checksum(output), item.sha256)
        let listed = try await provider.list(prefix: "nested/")
        XCTAssertEqual(listed.map(\.locator), ["nested/object"])
        await storageError(.destinationExists) {
            _ = try await provider.get("nested/object", to: output, expectedSHA256: item.sha256)
        }
        await storageError(.deleteNotAuthorized) {
            try await provider.delete("nested/object", authorization: .init(token: "", reason: "test"))
        }
        try await provider.delete("nested/object", authorization: .init(token: "approved", reason: "test"))
        let absent = try await provider.head("nested/object")
        XCTAssertNil(absent)
    }

    func test_containmentRefusesTraversalAbsoluteAndSymlink() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        try FileManager.default.createSymbolicLink(at: fixture.destination.appendingPathComponent("escape"),
                                                   withDestinationURL: fixture.source)
        for provider: any DicomStorageProvider in [DicomLocalDiskProvider(id: "local", root: fixture.destination),
                DicomNetworkVolumeProvider(id: "network", root: fixture.destination)] {
            for locator in ["../outside", "/absolute", "escape/object", "a/../b"] {
                do { _ = try await provider.head(locator); XCTFail("Accepted escaping locator") }
                catch { XCTAssertNotNil(error as? DicomStorageProviderError) }
            }
        }
    }

    func test_integrityRemovesPartialAndCancellationDoesNotPublish() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let item = try fixture.item()
        let provider = DicomLocalDiskProvider(id: "disk", root: fixture.source)
        let output = fixture.destination.appendingPathComponent("out")
        await storageError(.integrity(item.sourceLocator)) {
            _ = try await provider.get(item.sourceLocator, to: output, expectedSHA256: String(repeating: "0", count: 64))
        }
        XCTAssertFalse(try fixture.fileSystem.exists(output))
        XCTAssertFalse(try fixture.fileSystem.exists(URL(fileURLWithPath: output.path + ".partial")))
        await storageError(.cancelled) {
            _ = try await provider.get(item.sourceLocator, to: output, expectedSHA256: item.sha256, isCancelled: { true })
        }
        XCTAssertFalse(try fixture.fileSystem.exists(output))
        XCTAssertFalse(try fixture.fileSystem.exists(URL(fileURLWithPath: output.path + ".partial")))
    }

    func test_networkMissingRootAndProbeFailureAreUnreachable() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let missing = fixture.root.appendingPathComponent("unmounted")
        let provider = DicomNetworkVolumeProvider(id: "network", root: missing)
        XCTAssertEqual(provider.capabilities.latency, .network)
        XCTAssertTrue(provider.capabilities.removable)
        await storageError(.unreachable("network")) { _ = try await provider.head("object") }
        await storageError(.unreachable("network")) { _ = try await provider.list(prefix: "") }
        await storageError(.unreachable("network")) {
            _ = try await provider.get("object", to: fixture.destination.appendingPathComponent("x"),
                                       expectedSHA256: "hash", isCancelled: { false })
        }
        let failing = DicomNetworkVolumeProvider(id: "probe", root: fixture.source,
            fileSystem: DicomFaultInjectingFileSystem(operation: .contentsOf, fault: .fail(5)))
        let reachability = await failing.reachability()
        XCTAssertEqual(reachability, .unreachable("probe"))
        let local = DicomLocalDiskProvider(id: "local", root: missing)
        await storageError(.unreachable("local")) { _ = try await local.head("object") }
    }
}

extension DicomStorageProviderTests {
    func test_narrowPrefixSkipsUnrelatedSubtrees() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        try fixture.fileSystem.createDirectory(fixture.source.appendingPathComponent("wanted"))
        try fixture.fileSystem.createDirectory(fixture.source.appendingPathComponent("other"))
        _ = try fixture.item("wanted/object")
        try FileManager.default.createSymbolicLink(at: fixture.source.appendingPathComponent("other/escape"),
            withDestinationURL: fixture.destination)
        let provider = DicomLocalDiskProvider(id: "source", root: fixture.source)
        let results = try await provider.list(prefix: "wanted/")
        XCTAssertEqual(results.map(\.locator), ["wanted/object"])
    }
}
