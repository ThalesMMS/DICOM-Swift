import XCTest
@testable import DicomCore

final class DicomRoutingAuthorizationTests: XCTestCase, @unchecked Sendable {
    func test_evaluateRefusesUnauthorizedStudy() async throws {
        let policy = AuthorizationTestPolicy()
        await policy.deny("2.25.3")
        let evaluator = DicomRoutingEvaluator(rules: [DicomRoutingEvaluatorTests.rule()],
            destinations: DicomRoutingDestinationCatalog(destinations: [DicomRoutingEvaluatorTests.destination()]))
        let plan = try await evaluator.evaluate(DicomRoutingEvaluatorTests.subject(), authorizer: policy,
                                                principal: authorizationPrincipal())
        XCTAssertEqual(plan.decisions.first?.outcome, .refused)
        XCTAssertEqual(plan.decisions.first?.reasons, [.phiNotAuthorized])
    }
    func test_publishRevokedPrincipalCreatesNoObligations() async throws {
        let outbox = DicomInMemoryDeliveryOutbox()
        let policy = AuthorizationTestPolicy()
        await policy.deny("2.25.3")
        let destination = DicomRoutingEvaluatorTests.destination()
        let evaluator = DicomRoutingEvaluator(rules: [DicomRoutingEvaluatorTests.rule()],
            destinations: DicomRoutingDestinationCatalog(destinations: [destination]))
        let publisher = DicomLifecyclePublisher(sink: DicomInMemoryLifecycleEventSink(outbox: outbox),
            evaluator: evaluator, destinations: [destination.id: destination],
            subjectProvider: { _ in DicomRoutingEvaluatorTests.subject() },
            authorizer: policy, principal: authorizationPrincipal())
        _ = try await publisher.publish(.init(kind: .received, sourceKind: "synthetic", sourceRef: "synthetic"))
        let rows = try await outbox.fetch(states: [.pending])
        XCTAssertTrue(rows.isEmpty)
    }
    func test_attemptThenRetryRechecksAndCancels() async throws {
        let clock = DeliveryTestClock()
        let outbox = DicomInMemoryDeliveryOutbox()
        let peer = DeliveryFake(results: [.failed(.transient, "retry", retryAfter: nil)])
        let policy = AuthorizationTestPolicy()
        var item = deliveryItem("authorization")
        item.resource = .init(kind: .study, id: "study")
        let engine = DicomDeliveryEngine(outbox: outbox, destinations: ["peer": peer], owner: "test",
            clock: clock.now, authorizer: policy, principalProvider: { _ in authorizationPrincipal() })
        try await engine.enqueue([item])
        _ = await engine.runOnce(now: clock.now())
        await policy.deny("study")
        clock.advance(100)
        _ = await engine.runOnce(now: clock.now())
        let rows = try await outbox.fetch(states: [.cancelled])
        XCTAssertEqual(rows.first?.lastError, "authorizationRevoked")
        let sent = await peer.keys
        XCTAssertEqual(sent.count, 1)
    }
    func test_requeuedDeadLetterRechecks() async throws {
        let clock = DeliveryTestClock()
        let outbox = DicomInMemoryDeliveryOutbox()
        let peer = DeliveryFake(results: [.failed(.permanent, "stop", retryAfter: nil)])
        let policy = AuthorizationTestPolicy()
        var item = deliveryItem("requeue")
        item.resource = .init(kind: .study, id: "study")
        let engine = DicomDeliveryEngine(outbox: outbox, destinations: ["peer": peer], owner: "test",
            clock: clock.now, authorizer: policy, principalProvider: { _ in authorizationPrincipal() })
        try await engine.enqueue([item])
        _ = await engine.runOnce(now: clock.now())
        await policy.deny("study")
        try await outbox.requeueDeadLetter(deliveryID: item.deliveryID, now: clock.now())
        _ = await engine.runOnce(now: clock.now())
        let rows = try await outbox.fetch(states: [.cancelled])
        XCTAssertEqual(rows.first?.lastError, "authorizationRevoked")
        let sent = await peer.keys
        XCTAssertEqual(sent.count, 1)
    }
    func test_webhookPHIRequiresBothAuthorizations() async throws {
        let policy = AuthorizationTestPolicy()
        let legacy = try DicomWebhookPHIAuthorization(token: "synthetic", reason: "test")
        for authorization in [nil, legacy] {
            await policy.deny("study")
            do {
                _ = try await DicomWebhookEvent(eventID: "test", kind: "received", occurredAt: Date(),
                    subject: .init(studyInstanceUID: "study"), phi: .init(patientID: "SYNTHETIC"),
                    authorization: authorization, source: "test", authorizer: policy, principal: authorizationPrincipal())
                XCTFail("Unauthorized PHI accepted")
            } catch { XCTAssertEqual(error as? DicomWebhookEventError, .phiNotAuthorized) }
        }
        let allowed = try await DicomWebhookEvent(eventID: "test", kind: "received", occurredAt: Date(),
            subject: .init(studyInstanceUID: "allowed"), phi: .init(patientID: "SYNTHETIC"),
            authorization: legacy, source: "test", authorizer: policy, principal: authorizationPrincipal())
        XCTAssertTrue(allowed.phiIncluded)
    }
}
