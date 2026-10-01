import XCTest
@testable import DicomCore

final class DicomAuthorizationBoundaryTests: XCTestCase, @unchecked Sendable {
    func test_completedTransfer_recordsCompletionTime() async throws {
        let sink = DicomInMemoryAuditSink()
        let access = DicomEnforcement(principal: nil, authorizer: nil,
            audit: .init(sinks: [sink], policy: .failClosed),
            context: .init(protocol: .dimse, at: Date(timeIntervalSince1970: 0)))
        let started = Date()
        try await access.transferred(.init(kind: .study, id: "synthetic"))
        let events = await sink.events
        let event = try XCTUnwrap(events.first)
        XCTAssertGreaterThanOrEqual(event.eventIdentification.eventDateTime, started)
        XCTAssertLessThanOrEqual(event.eventIdentification.eventDateTime, Date())
    }

    func test_moveRouteRevokedDuringByteSource_refusesBeforeStore() async throws {
        let policy = BoundaryAuthorizationPolicy()
        let access = DicomEnforcement(principal: authorizationPrincipal(), authorizer: policy,
            audit: nil, context: .init(protocol: .dimse))
        let instance = instance { await policy.setRouteDenied() }
        var configuration = DicomDIMSEServerConfiguration(aeTitle: "ISIS")
        configuration.storage.timeout = 5
        let server = DicomDIMSEServer(configuration: configuration)
        // A listening destination (issue #2817): the sub-association opens, and the route is refused before any
        // C-STORE is sent.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("route-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try DicomStorageSCPServer(service: DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(aeTitle: "DESTINATION", port: 0),
            storage: try DicomFileStorageCache(directoryURL: directory)))
        try destination.start()
        let port = try XCTUnwrap(destination.listeningPort)
        do {
            try await server.moveInstances([instance], destination: .init(host: "127.0.0.1", port: port),
                destinationAETitle: "DESTINATION", originator: nil, access: access) { _, _ in }
            XCTFail("Revoked route was accepted")
        } catch { XCTAssertEqual((error as? DicomWebServerFailure)?.status, 403) }
        await destination.stop()
        let stored = (try? FileManager.default.subpathsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(stored.contains { $0.hasSuffix(".dcm") }, "nothing was stored")
    }

    func test_moveStoreFailure_doesNotAuditSuccessfulTransfer() async throws {
        let sink = DicomInMemoryAuditSink()
        let access = DicomEnforcement(principal: authorizationPrincipal(), authorizer: BoundaryAuthorizationPolicy(),
            audit: .init(sinks: [sink], policy: .failClosed), context: .init(protocol: .dimse))
        var configuration = DicomDIMSEServerConfiguration(aeTitle: "ISIS")
        configuration.storage.timeout = 0.1
        let server = DicomDIMSEServer(configuration: configuration)
        do {
            try await server.moveInstances([instance {}], destination: .init(host: "127.0.0.1", port: 0),
                destinationAETitle: "DESTINATION", originator: nil, access: access) { _, _ in }
            XCTFail("Invalid destination accepted the store")
        } catch { XCTAssertFalse(error is DicomWebServerFailure) }
        let events = await sink.events
        XCTAssertFalse(events.contains { $0.eventIdentification.eventID.code == "110104" })
    }

    func test_deliveryAuthorizationUnavailable_retriesAfterRecovery() async throws {
        let clock = DeliveryTestClock()
        let outbox = DicomInMemoryDeliveryOutbox()
        let peer = DeliveryFake(results: [.delivered(.init(status: "stored"))])
        let policy = BoundaryAuthorizationPolicy()
        await policy.setUnavailable(true)
        var item = deliveryItem("authorization-unavailable")
        item.resource = .init(kind: .study, id: "study")
        let engine = DicomDeliveryEngine(outbox: outbox, destinations: ["peer": peer], owner: "test",
            clock: clock.now, authorizer: policy, principalProvider: { _ in authorizationPrincipal() })
        try await engine.enqueue([item])
        _ = await engine.runOnce(now: clock.now())
        let pending = try await outbox.fetch(states: [.retryWait])
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.lastErrorClass, .transient)
        let before = await peer.keys
        XCTAssertTrue(before.isEmpty)
        await policy.setUnavailable(false)
        clock.advance(3600)
        let recovered = await engine.runOnce(now: clock.now())
        XCTAssertEqual(recovered.delivered, 1)
        let sent = await peer.keys
        XCTAssertEqual(sent.count, 1)
    }

    private func instance(_ prepare: @escaping @Sendable () async -> Void) -> DicomRetrievableInstance {
        .init(sopClassUID: DicomStorageSOPClassUIDs.secondaryCaptureImageStorage,
            sopInstanceUID: "2.25.3", transferSyntaxes: [.explicitVRLittleEndian],
            resource: .instance(study: "2.25.1", series: "2.25.2", instance: "2.25.3")) { syntax in
                await prepare()
                return try DicomDataSetWriter.dataSetData(from: DicomWebServerAuthorizationTests.dataSet(),
                    transferSyntax: syntax)
            }
    }
}

private actor BoundaryAuthorizationPolicy: DicomAuthorizing {
    let policyVersion: Int64 = 0
    private var routeDenied = false
    private var unavailable = false
    func setRouteDenied() { routeDenied = true }
    func setUnavailable(_ value: Bool) { unavailable = value }
    func decide(principal: DicomPrincipal?, operation: DicomAccessOperation, resource: DicomResourceRef,
                context: DicomAccessContext) -> DicomAuthorizationDecision {
        let reason: DicomAuthorizationDecision.Reason = unavailable ? .policyUnavailable
            : routeDenied && operation == .route ? .scopeMissing : .allowed
        return .init(outcome: reason == .allowed ? .allow : .deny, reason: reason,
            policyVersion: policyVersion, evaluatedAt: context.at)
    }
}
