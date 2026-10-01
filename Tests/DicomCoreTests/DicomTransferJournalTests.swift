import Foundation
import XCTest
@testable import DicomCore

final class DicomTransferJournalTests: XCTestCase {
    func test_deterministicRoundTripAndPendingFilter() throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let item = try fixture.item()
        var manifest = DicomTransferManifest(sourceProviderID: "source", destinationProviderID: "destination", items: [item])
        XCTAssertEqual(try manifest.encode(), try manifest.encode())
        try fixture.journal.save(manifest)
        XCTAssertEqual(try fixture.journal.load(transferID: manifest.transferID), manifest)
        XCTAssertEqual(try fixture.journal.pending(), [manifest])
        manifest.items[0].state = .inFlight
        try fixture.journal.save(manifest)
        XCTAssertEqual(try fixture.journal.load(transferID: manifest.transferID).items[0].state, .inFlight)
        manifest.items[0].state = .verified
        try fixture.journal.save(manifest)
        XCTAssertEqual(try fixture.journal.load(transferID: manifest.transferID).totals.verifiedBytes, item.byteCount)
        XCTAssertTrue(try fixture.journal.pending().isEmpty)
        XCTAssertEqual(try fixture.fileSystem.contentsOf(fixture.journalURL).count, 1)
    }

    func test_failedReplacementKeepsPriorCompleteManifest() throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        var manifest = DicomTransferManifest(sourceProviderID: "source", destinationProviderID: "destination",
                                             items: [try fixture.item()])
        try fixture.journal.save(manifest)
        let previous = try fixture.journal.load(transferID: manifest.transferID)
        manifest.items[0].state = .verified
        let failing = DicomTransferJournal(directory: fixture.journalURL,
            fileSystem: DicomFaultInjectingFileSystem(operation: .fsyncFile, fault: .fail(5)))
        XCTAssertThrowsError(try failing.save(manifest))
        XCTAssertEqual(try fixture.journal.load(transferID: manifest.transferID), previous)
    }

    func test_invalidIDAndMismatchedFileAreRejected() throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        XCTAssertThrowsError(try fixture.journal.load(transferID: "../escape"))
        let manifest = DicomTransferManifest(sourceProviderID: "source", destinationProviderID: "destination", items: [])
        try fixture.journal.save(manifest)
        let differentID = UUID().uuidString
        try manifest.encode().write(to: fixture.journalURL.appendingPathComponent(differentID + ".json"))
        XCTAssertThrowsError(try fixture.journal.load(transferID: differentID))
    }
}

extension DicomTransferJournalTests {
    func test_decodedUppercaseChecksumIsNormalized() throws {
        let item = DicomTransferManifest.Item(objectKey: "a", sourceLocator: "a", destinationLocator: "a",
            byteCount: 1, sha256: String(repeating: "ab", count: 32))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        json["sha256"] = item.sha256.uppercased()
        let decoded = try JSONDecoder().decode(DicomTransferManifest.Item.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, item)
    }
}
