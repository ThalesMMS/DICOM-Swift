import Foundation
import XCTest
@testable import DicomCore

/// Issue #2817: a C-MOVE serves all its objects over one sub-association to the destination, each C-STORE-RQ carries
/// Move Originator (0000,1030/1031), and the retrieve limit is its own, apart from C-STORE admission.
final class DicomDIMSEServerMoveSubAssociationTests: XCTestCase {
    func test_move_sendsEveryObjectOnOneAssociationWithMoveOriginator() async throws {
        #if canImport(Network)
        let recorder = MoveDestinationRecorder()
        let destination = try DicomStorageSCPServer(service: DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(aeTitle: "DEST", port: 0), storage: recorder))
        try destination.start { event in
            if case .associationAccepted = event { recorder.countAssociation() }
        }
        let destinationPort = try XCTUnwrap(destination.listeningPort)
        let resolver = A2DestinationResolver()
        await resolver.set("DEST", port: destinationPort)

        // An admission limit far below the retrieve: C-STORE admission no longer caps C-MOVE.
        var configuration = DicomDIMSEServerConfiguration(aeTitle: "ISIS", port: 0)
        configuration.storage.maximumObjectsPerAssociation = 3
        let server = DicomDIMSEServer(configuration: configuration, retrieve: A2RetrieveProvider(count: 12),
                                      moveDestinations: resolver)
        try server.start()
        let serverPort = try XCTUnwrap(server.listeningPort)

        let scu = DicomDIMSEServiceSCU(configuration: DicomDIMSEConnectionConfiguration(
            host: "127.0.0.1", port: serverPort, calledAETitle: "ISIS", callingAETitle: "VIEWER", timeout: 10))
        let identifier = DicomDataSet(elements: [a2String(0x00080052, .CS, "STUDY"), a2String(0x0020000D, .UI, "2.25.2817")])
        let pending = MovePendingCounter()
        let result = try await Task.detached {
            try scu.move(identifier: identifier, moveDestinationAETitle: "DEST") { event in
                if case .pending = event { pending.increment() }
            }
        }.value
        await server.stop()
        await destination.stop()

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.completedSuboperations, 12)
        XCTAssertEqual(pending.value, 12)
        XCTAssertEqual(recorder.associations, 1, "one sub-association for the whole C-MOVE")
        XCTAssertEqual(recorder.received.count, 12)
        XCTAssertTrue(recorder.received.allSatisfy { $0.aeTitle == "VIEWER" && $0.messageID == 1 },
                      "every C-STORE-RQ names the C-MOVE it serves")
        #else
        throw XCTSkip("Network framework is unavailable on this platform.")
        #endif
    }

    func test_moveOriginator_roundTripsThroughTheCommandSet() throws {
        var command = DicomDIMSECommandSet(affectedSOPClassUID: "1.2.840.10008.5.1.4.1.1.7",
            commandField: DicomDIMSECommandField.cStoreRQ, messageID: 7,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet, priority: 0,
            affectedSOPInstanceUID: "2.25.1")
        command.moveOriginatorAETitle = "VIEWER"
        command.moveOriginatorMessageID = 42
        let decoded = try DicomDIMSECommandSet.decode(try command.encoded())
        XCTAssertEqual(decoded.moveOriginatorAETitle, "VIEWER")
        XCTAssertEqual(decoded.moveOriginatorMessageID, 42)
    }
}

/// Records the Move Originator of every object a destination receives, and its associations.
private final class MoveDestinationRecorder: DicomStorageInstanceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(aeTitle: String?, messageID: UInt16?)] = []
    private var associationCount = 0

    var received: [(aeTitle: String?, messageID: UInt16?)] { lock.withLock { records } }
    var associations: Int { lock.withLock { associationCount } }

    func countAssociation() { lock.withLock { associationCount += 1 } }

    func store(_ instance: DicomStorageReceivedInstance) throws -> DicomStoredInstance {
        lock.withLock { records.append((instance.moveOriginatorAETitle, instance.moveOriginatorMessageID)) }
        return DicomStoredInstance(sopClassUID: instance.sopClassUID, sopInstanceUID: instance.sopInstanceUID,
                                   transferSyntax: instance.transferSyntax,
                                   fileURL: URL(fileURLWithPath: "/dev/null"))
    }
}

// All counter access is protected by the lock, including the detached callback.
private final class MovePendingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
