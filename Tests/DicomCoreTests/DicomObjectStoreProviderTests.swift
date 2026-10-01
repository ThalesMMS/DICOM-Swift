import Foundation
import XCTest
@testable import DicomCore

actor FlakyObjectStore: DicomObjectStore {
    let base: any DicomObjectStore
    var remaining: Int
    let failure: DicomStorageProviderError
    private(set) var calls = 0
    init(base: any DicomObjectStore, failures: Int, failure: DicomStorageProviderError = .unreachable("retry")) {
        self.base = base
        self.remaining = failures
        self.failure = failure
    }
    func check() throws {
        calls += 1
        if remaining > 0 { remaining -= 1; throw failure }
    }
    func putObject(key: String, from source: URL, sha256: String) async throws -> DicomStorageObjectInfo {
        try check(); return try await base.putObject(key: key, from: source, sha256: sha256)
    }
    func getObject(key: String, to destination: URL) async throws -> DicomStorageObjectInfo {
        try check(); return try await base.getObject(key: key, to: destination)
    }
    func headObject(key: String) async throws -> DicomStorageObjectInfo? { try check(); return try await base.headObject(key: key) }
    func listObjects(prefix: String) async throws -> [DicomStorageObjectInfo] { try check(); return try await base.listObjects(prefix: prefix) }
    func deleteObject(key: String) async throws { try check(); try await base.deleteObject(key: key) }
}

actor CorruptingObjectStore: DicomObjectStore {
    let base: any DicomObjectStore
    private(set) var gets = 0
    init(base: any DicomObjectStore) { self.base = base }
    func putObject(key: String, from source: URL, sha256: String) async throws -> DicomStorageObjectInfo {
        try await base.putObject(key: key, from: source, sha256: sha256)
    }
    func getObject(key: String, to destination: URL) async throws -> DicomStorageObjectInfo {
        gets += 1
        let info = try await base.getObject(key: key, to: destination)
        var data = try Data(contentsOf: destination)
        data[0] ^= 1
        try data.write(to: destination)
        return info
    }
    func headObject(key: String) async throws -> DicomStorageObjectInfo? { try await base.headObject(key: key) }
    func listObjects(prefix: String) async throws -> [DicomStorageObjectInfo] { try await base.listObjects(prefix: prefix) }
    func deleteObject(key: String) async throws { try await base.deleteObject(key: key) }
}

@MainActor
final class DicomObjectStoreProviderTests: XCTestCase {
    func test_retryBudgetAndExponentialBackoff() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let item = try fixture.item()
        let store = FlakyObjectStore(base: DicomDirectoryObjectStore(root: fixture.source), failures: 2)
        let provider = DicomObjectStoreProvider(id: "remote", store: store,
            policy: .init(maxAttempts: 3, baseDelay: 0.02, maxDelay: 0.1))
        let start = ContinuousClock.now
        let info = try await provider.head(item.sourceLocator)
        XCTAssertEqual(info?.sha256, item.sha256)
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(55))
        let count = await store.calls
        XCTAssertEqual(count, 3)
        let exhausted = FlakyObjectStore(base: DicomDirectoryObjectStore(root: fixture.source), failures: 10)
        let bounded = DicomObjectStoreProvider(id: "remote", store: exhausted,
            policy: .init(maxAttempts: 2, baseDelay: 0, maxDelay: 0))
        await storageError(.unreachable("retry")) { _ = try await bounded.head(item.sourceLocator) }
        let boundedCount = await exhausted.calls
        XCTAssertEqual(boundedCount, 2)
    }

    func test_integrityAndCancellationNeverRetry() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        for failure: DicomStorageProviderError in [.integrity("bad"), .cancelled] {
            let store = FlakyObjectStore(base: DicomDirectoryObjectStore(root: fixture.source), failures: 10, failure: failure)
            let provider = DicomObjectStoreProvider(id: "remote", store: store,
                policy: .init(baseDelay: 0, retryable: { _ in true }))
            await storageError(failure) { _ = try await provider.head("key") }
            let count = await store.calls
            XCTAssertEqual(count, 1)
        }
    }

    func test_corruptDownloadIsRehashedAndLeavesNoFiles() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let item = try fixture.item()
        let store = CorruptingObjectStore(base: DicomDirectoryObjectStore(root: fixture.source))
        let provider = DicomObjectStoreProvider(id: "remote", store: store,
            policy: .init(baseDelay: 0, retryable: { _ in true }))
        await storageError(.integrity(item.sourceLocator)) {
            _ = try await provider.get(item.sourceLocator, to: fixture.destination.appendingPathComponent("out"), expectedSHA256: item.sha256)
        }
        XCTAssertTrue(try fixture.fileSystem.contentsOf(fixture.destination).isEmpty)
        let gets = await store.gets
        XCTAssertEqual(gets, 1)
        XCTAssertEqual(try fixture.fileSystem.checksum(fixture.source.appendingPathComponent(item.sourceLocator)), item.sha256)
    }

    func test_putGetListHeadDeleteAndUploadIntegrity() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let item = try fixture.item()
        let provider = DicomObjectStoreProvider(id: "remote", store: DicomDirectoryObjectStore(root: fixture.destination))
        _ = try await provider.put(fixture.source.appendingPathComponent(item.sourceLocator), locator: "key", expectedSHA256: item.sha256)
        let listed = try await provider.list(prefix: "k")
        XCTAssertEqual(listed.map(\.locator), ["key"])
        let output = fixture.root.appendingPathComponent("get")
        _ = try await provider.get("key", to: output, expectedSHA256: item.sha256)
        XCTAssertEqual(try fixture.fileSystem.checksum(output), item.sha256)
        await storageError(.destinationExists) { _ = try await provider.get("key", to: output, expectedSHA256: item.sha256) }
        await storageError(.deleteNotAuthorized) { try await provider.delete("key", authorization: .init(token: "", reason: "")) }
        await storageError(.integrity("bad")) {
            _ = try await provider.put(output, locator: "bad", expectedSHA256: String(repeating: "0", count: 64))
        }
        try await provider.delete("key", authorization: .init(token: "approved", reason: "test"))
        let absent = try await provider.head("key")
        XCTAssertNil(absent)
    }

    func test_directoryStoreRejectsEscapingKeys() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let store = DicomDirectoryObjectStore(root: fixture.source)
        do { _ = try await store.headObject(key: "../escape"); XCTFail("Accepted escape") }
        catch { XCTAssertNotNil(error as? DicomStorageProviderError) }
    }
}
