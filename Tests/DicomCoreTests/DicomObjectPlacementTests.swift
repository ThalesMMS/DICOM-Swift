import Foundation
import XCTest
@testable import DicomCore

struct UnreachableProvider: DicomStorageProvider {
    let id = "source"
    let tier = DicomStorageTier.offline
    let capabilities = DicomStorageCapabilities(randomAccess: false, atomicRename: false,
        checksumOnHead: false, latency: .archive, removable: false)
    func head(_ locator: String) async throws -> DicomStorageObjectInfo? { throw DicomStorageProviderError.unreachable(id) }
    func put(_ source: URL, locator: String, expectedSHA256: String,
             isCancelled: @Sendable () -> Bool) async throws -> DicomStorageObjectInfo { throw DicomStorageProviderError.unreachable(id) }
    func get(_ locator: String, to destination: URL, expectedSHA256: String,
             isCancelled: @Sendable () -> Bool) async throws -> DicomStorageObjectInfo { throw DicomStorageProviderError.unreachable(id) }
    func list(prefix: String) async throws -> [DicomStorageObjectInfo] { throw DicomStorageProviderError.unreachable(id) }
    func delete(_ locator: String, authorization: DicomDeleteAuthorization) async throws { throw DicomStorageProviderError.unreachable(id) }
    func reachability() async -> DicomProviderReachability { .unreachable(id) }
}

@MainActor
final class DicomObjectPlacementTests: XCTestCase {
    func test_stateTransitionsRequireVerifiedAbsence() throws {
        let placement = DicomObjectPlacement(objectKey: "key", tier: .offline, providerID: "source",
                                              locator: "locator", byteCount: 1, sha256: "hash")
        XCTAssertThrowsError(try placement.transition(to: .missing)) {
            XCTAssertEqual($0 as? DicomPlacementError, .invalidTransition(from: .available, to: .missing))
        }
        XCTAssertEqual(try placement.transition(to: .missing, verifiedAbsent: true).state, .missing)
        let unreachable = try placement.transition(to: .unreachable)
        XCTAssertThrowsError(try unreachable.transition(to: .missing, verifiedAbsent: true))
        XCTAssertEqual(try unreachable.transition(to: .recalling).state, .recalling)
        XCTAssertEqual(try placement.transition(to: .recalling).transition(to: .available).state, .available)
        XCTAssertEqual(DicomStorageTier.allCases.map(\.instanceAvailability), [.online, .nearline, .offline])
        XCTAssertEqual(try JSONDecoder().decode(DicomObjectPlacement.self, from: JSONEncoder().encode(placement)), placement)
    }

    func test_headAbsenceAndOutagePreservePlacementIdentity() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let placement = DicomObjectPlacement(objectKey: "key", tier: .offline, providerID: "source",
                                              locator: "locator", byteCount: 1, sha256: "hash")
        let absent = try await placement.refreshed(using: DicomLocalDiskProvider(id: "source", root: fixture.source))
        XCTAssertEqual(absent.state, .missing)
        let outage = try await placement.refreshed(using: UnreachableProvider())
        XCTAssertEqual(outage.state, .unreachable)
        XCTAssertEqual(outage.locator, placement.locator)
        XCTAssertEqual(outage.sha256, placement.sha256)
    }
}
