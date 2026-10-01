import Foundation
import XCTest
@testable import FHIR

final class FHIRSubscriptionTests: XCTestCase {
    func test_restHook_lifecycleAgainstOracleServer() async throws {
        let receiver = FHIRRestHookReceiver(configuration: .init(secretHeader: ("X-Isis-Hook", "synthetic-secret")))
        let endpoint = try await receiver.start()
        addTeardownBlock { await receiver.stop() }
        let server = try await FHIROracleServer.start(behaviors: ["webhook_origins": [endpoint.absoluteString]])
        defer { server.stop() }
        let manager = FHIRSubscriptionManager(client: server.client())
        let created = try await manager.create(criteria: "Observation?code=29463-7", endpoint: endpoint.absoluteString + "/hook",
                                               headers: ["X-Isis-Hook: synthetic-secret"]).get()
        let id = try XCTUnwrap(created.id)
        XCTAssertEqual(created.channelType, "rest-hook")
        let active = try await manager.waitUntilActive(id: id, maxPolls: 5).get()
        XCTAssertEqual(active.status, "active")

        var observation = FHIRObservation()
        observation.status = "final"
        observation.code = FHIRCodeableConcept(codings: [FHIRCoding(system: "http://loinc.org", code: "29463-7")])
        observation.setValue(string: "notify")
        _ = try await server.client().create(observation.resource).get()
        let notifications = await receiver.waitForNotifications(count: 1, timeout: .seconds(5))
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.method, "POST")
        XCTAssertEqual(notifications.first?.path, "/hook")
        XCTAssertEqual(notifications.first?.resource?.as(FHIRObservation.self)?.value?.string, "notify")
        XCTAssertEqual(receiver.rejectedCount, 0)

        let cancelled = try await manager.cancel(id: id)
        XCTAssertEqual(cancelled.metadata?.status, 204)
        _ = try await server.client().create(observation.resource).get()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(receiver.notifications.count, 1, "no delivery after cancellation")
        let afterCancel = try await manager.status(id: id)
        XCTAssertEqual(afterCancel.failure?.status, 410)
    }

    func test_receiver_rejectsMissingSecretOversizeAndMalformedBodies() async throws {
        let receiver = FHIRRestHookReceiver(configuration: .init(secretHeader: ("X-Isis-Hook", "secret"), maximumBodyBytes: 512))
        let endpoint = try await receiver.start()
        addTeardownBlock { await receiver.stop() }
        var configuration = FHIRClientConfiguration(baseURL: endpoint, policy: .init(timeout: 3, allowInsecureForHosts: ["127.0.0.1"]))
        configuration.preferReturn = nil
        let unauthenticated = FHIRClient(configuration: configuration)
        let refused = try await unauthenticated.create(FHIRPatient(id: "p").resource)
        XCTAssertEqual(refused.failure?.status, 401)
        let authenticated = FHIRClient(configuration: configuration) { ["X-Isis-Hook": "secret"] }
        let accepted = try await authenticated.create(FHIRPatient(id: "p").resource)
        XCTAssertEqual(accepted.metadata?.status, 200)
        var big = FHIRPatient(id: "big")
        big.names = (0..<40).map { FHIRHumanName(family: "Family\($0)", given: ["Given"]) }
        let oversized = try await authenticated.create(big.resource)
        XCTAssertEqual(oversized.failure?.status, 413)
        let malformed = try await authenticated.fetch(url: endpoint.appendingPathComponent("Patient"))
        XCTAssertEqual(malformed.failure?.status, 405, "GET is not a notification")
        XCTAssertEqual(receiver.notifications.count, 1)
        XCTAssertEqual(receiver.rejectedCount, 1)
    }
}
