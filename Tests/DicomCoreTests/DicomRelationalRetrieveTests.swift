import Foundation
import XCTest
@testable import DicomCore

/// A relational C-GET against the toolkit SCP (issue #3014): with relational retrieval negotiated, a series named
/// without its Study Instance UID is retrieved, and the SCU reads the acceptor's answer; without it, the SCP refuses.
final class DicomRelationalRetrieveTests: XCTestCase {
    func test_relationalGet_succeedsOnlyWhenNegotiated() async throws {
        #if canImport(Network)
        let uid = DicomNetworkUID.studyRootQueryRetrieveGet
        let server = DicomDIMSEServer(configuration: DicomDIMSEServerConfiguration(aeTitle: "ISIS", port: 0,
            extendedNegotiations: [.init(sopClassUID: uid, relationalRetrieval: true)]), retrieve: A2RetrieveProvider(count: 2))
        try server.start()
        let port = try XCTUnwrap(server.listeningPort)
        func scu(_ negotiations: [DicomSOPClassExtendedNegotiation]) -> DicomDIMSEServiceSCU {
            DicomDIMSEServiceSCU(configuration: DicomDIMSEConnectionConfiguration(host: "127.0.0.1", port: port, calledAETitle: "ISIS",
                callingAETitle: "VIEWER", timeout: 10, extendedNegotiations: negotiations))
        }
        let series = DicomDataSet(elements: [a2String(0x00080052, .CS, "SERIES"), a2String(0x0020000E, .UI, "2.25.3014.2")])
        let relational = scu([.init(sopClassUID: uid, relationalRetrieval: true)])
        let plain = scu([])
        let negotiated = try await Task.detached {
            try relational.get(identifier: series, storageSOPClassUIDs: [DicomStorageSOPClassUIDs.secondaryCaptureImageStorage],
                               priority: .high)
        }.value
        let refused = await Task.detached { () -> Error? in
            do {
                _ = try plain.get(identifier: series, storageSOPClassUIDs: [DicomStorageSOPClassUIDs.secondaryCaptureImageStorage])
                return nil
            } catch { return error }
        }.value
        await server.stop()

        XCTAssertEqual(negotiated.operation.status, 0)
        XCTAssertEqual(negotiated.retrievedInstances.count, 2)
        XCTAssertEqual(negotiated.operation.acceptedExtendedNegotiation?.relationalRetrieval, true)
        let failure = try XCTUnwrap(refused as? DicomRetrieveFailure, "without the negotiation the hierarchical key is required")
        XCTAssertEqual(failure.result.status, 0xA900)
        XCTAssertNil(failure.result.acceptedExtendedNegotiation)
        #else
        throw XCTSkip("Network framework is unavailable on this platform.")
        #endif
    }
}
