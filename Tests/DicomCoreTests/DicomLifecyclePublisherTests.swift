import XCTest
@testable import DicomCore

@MainActor
final class DicomLifecyclePublisherTests: XCTestCase {
    private func event() throws -> DicomLifecycleEvent {
        try .init(kind: .received, sourceKind: "ingest", sourceRef: "test")
    }
    private func publisher(sink: any DicomLifecycleEventSink, dryRun: Bool = false,
                           files: [URL]? = nil, rulePriority: DicomRoutingPriority = .routine,
                           subjectPriority: DicomRoutingPriority = .routine,
                           additionalRules: [DicomRoutingRule] = []) throws -> DicomLifecyclePublisher {
        let objectFiles: [URL]
        if let supplied = files {
            objectFiles = supplied
        } else {
            let file = try deliveryPart10("2.25.2358001")
            addTeardownBlock { try FileManager.default.removeItem(at: file) }
            objectFiles = [file]
        }
        let kinds: [DicomRoutingDestination.Kind] = [.dimseStore, .stowRS, .webhook]
        let destinations = kinds.enumerated().map {
            DicomRoutingDestination(id: "d\($0.offset)", kind: $0.element, displayName: "test", acceptsLossy: false)
        }
        let rules = destinations.map {
            DicomRoutingRule(id: $0.id, name: "test", criteria: [.modality(in: ["CT"])], destinationID: $0.id,
                priority: rulePriority, requiresPHIAuthorization: false,
                createdAt: .distantPast, updatedAt: .distantPast)
        }
        return .init(sink: sink, evaluator: .init(rules: rules + additionalRules,
            destinations: DicomRoutingDestinationCatalog(destinations: destinations)),
            destinations: Dictionary(uniqueKeysWithValues: destinations.map { ($0.id, $0) }),
            subjectProvider: { _ in
                .init(sopInstanceUID: "1", sopClassUID: "2", studyInstanceUID: "3", seriesInstanceUID: "4",
                    modality: "CT", priority: subjectPriority, transferSyntaxUID: "1.2.840.10008.1.2.1",
                    contentReferences: ["https://untrusted.invalid", "EVIL_AE"])
            }, dryRun: dryRun, objectURLs: { _, _ in objectFiles })
    }

    func test_routes_recordAllObligationsAndIgnoreContentDestinations() async throws {
        let outbox = DicomInMemoryDeliveryOutbox()
        let sink = DicomInMemoryLifecycleEventSink(outbox: outbox)
        let publication = try await publisher(sink: sink).publish(event())
        XCTAssertEqual(publication.plan?.routed.count, 3)
        XCTAssertEqual(publication.outcome, .recorded)
        let items = try await outbox.fetch(states: [.pending])
        XCTAssertEqual(Set(items.map(\.destinationID)), ["d0", "d1", "d2"])
        XCTAssertEqual(items.count, 3)
        for item in items {
            XCTAssertEqual(item.resource?.kind, .study)
            XCTAssertEqual(item.resource?.id, "3")
            if item.destinationKind == .webhook {
                guard case .event(let payload) = item.payload else { return XCTFail("Expected event") }
                XCTAssertNil(payload.phi)
            } else {
                guard case .objects(let files) = item.payload else { return XCTFail("Expected objects") }
                XCTAssertEqual(files.count, 1)
                XCTAssertEqual(try DicomStoreRequest(part10FileAt: XCTUnwrap(files.first)).sopInstanceUID,
                               "2.25.2358001")
            }
        }
    }

    func test_republishConcurrently_isAlreadyRecordedWithoutNewObligations() async throws {
        let outbox = DicomInMemoryDeliveryOutbox()
        let sink = DicomInMemoryLifecycleEventSink(outbox: outbox)
        let publisher = try publisher(sink: sink)
        let event = try event()
        async let a = publisher.publish(event)
        async let b = publisher.publish(event)
        let results = try await [a, b]
        XCTAssertEqual(results.filter { $0.outcome == .recorded }.count, 1)
        XCTAssertEqual(results.filter { $0.outcome == .alreadyRecorded }.count, 1)
        let rows = try await outbox.fetch(states: [.pending])
        let events = await sink.events()
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(events.count, 1)
    }

    func test_failingOutbox_recordsNoEvent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = DicomFaultInjectingFileSystem(operation: .write, nth: 2, fault: .fail(5))
        let outbox = try DicomJSONLDeliveryOutbox(directory: root, fileSystem: fs)
        let sink = DicomInMemoryLifecycleEventSink(outbox: outbox)
        do { _ = try await publisher(sink: sink).publish(event()); XCTFail("Expected enqueue failure") }
        catch {}
        let events = await sink.events()
        XCTAssertTrue(events.isEmpty)
    }

    func test_dryRun_recordsRoutingDecisionsWithoutObligations() async throws {
        let outbox = DicomInMemoryDeliveryOutbox()
        let sink = DicomInMemoryLifecycleEventSink(outbox: outbox)
        let publication = try await publisher(sink: sink, dryRun: true, files: []).publish(event())
        XCTAssertTrue(publication.dryRun)
        XCTAssertEqual(publication.plan?.routed.count, 3)
        let events = await sink.events()
        let rows = try await outbox.fetch(states: [.pending])
        XCTAssertEqual(events.first?.routingDecisions, publication.plan?.decisions)
        XCTAssertTrue(rows.isEmpty)
    }

    func test_missingFiles_refusesWholePublication() async throws {
        let sink = DicomInMemoryLifecycleEventSink()
        do { _ = try await publisher(sink: sink, files: []).publish(event()); XCTFail("Expected missing objects") }
        catch DicomLifecyclePublisher.PublicationError.missingObjects {}
        let events = await sink.events()
        XCTAssertTrue(events.isEmpty)
    }

    func test_rulePriority_controlsDeliveryPriority() async throws {
        for (rulePriority, subjectPriority) in [(DicomRoutingPriority.stat, DicomRoutingPriority.routine),
                                                (.routine, .stat)] {
            let outbox = DicomInMemoryDeliveryOutbox()
            let sink = DicomInMemoryLifecycleEventSink(outbox: outbox)
            _ = try await publisher(sink: sink, rulePriority: rulePriority, subjectPriority: subjectPriority)
                .publish(event())
            let items = try await outbox.fetch(states: [.pending])
            XCTAssertEqual(items.count, 3)
            XCTAssertTrue(items.allSatisfy { $0.priority.rawValue == rulePriority.rawValue })
        }
    }

    func test_duplicateDestination_enqueuesOneStatObligation() async throws {
        let outbox = DicomInMemoryDeliveryOutbox()
        let sink = DicomInMemoryLifecycleEventSink(outbox: outbox)
        let stat = DicomRoutingRule(id: "urgent", name: "STAT", criteria: [.modality(in: ["CT"])],
            destinationID: "d0", priority: .stat, requiresPHIAuthorization: false,
            createdAt: .distantPast, updatedAt: .distantPast)
        let publication = try await publisher(sink: sink, additionalRules: [stat]).publish(event())
        XCTAssertEqual(publication.plan?.routed.first { $0.destinationID == "d0" }?.ruleID, stat.id)
        let items = try await outbox.fetch(states: [.pending])
        XCTAssertEqual(items.count, 3)
        let urgent = items.filter { $0.destinationID == "d0" }
        XCTAssertEqual(urgent.count, 1)
        XCTAssertEqual(urgent.first?.priority, .stat)
        XCTAssertTrue(items.filter { $0.destinationID != "d0" }.allSatisfy { $0.priority == .routine })
    }

    func test_publication_accountsForPayloadBytesBeforeLimitedDelivery() async throws {
        let files = try ["2.25.2358002", "2.25.2358003"].map(deliveryPart10)
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }
        let expectedObjectBytes = try files.reduce(Int64(0)) { $0 + Int64(try Data(contentsOf: $1).count) }
        let outbox = DicomInMemoryDeliveryOutbox()
        let clock = DeliveryTestClock()
        let sink = DicomInMemoryLifecycleEventSink(outbox: outbox)
        _ = try await publisher(sink: sink, files: files).publish(.init(kind: .received, sourceKind: "ingest",
            sourceRef: "bandwidth", occurredAt: clock.now()))
        let items = try await outbox.fetch(states: [.pending])
        XCTAssertEqual(items.count, 3)
        for item in items {
            switch item.payload {
            case .objects: XCTAssertEqual(item.byteCount, expectedObjectBytes)
            case .event(let event):
                XCTAssertEqual(item.byteCount, Int64(try DicomWebhookCanonicalJSON.encode(event).count))
            }
        }
        let started = clock.now()
        let engine = DicomDeliveryEngine(outbox: outbox, destinations: ["d0": DeliveryFake(id: "d0")],
            limits: .init(globalBytesPerSecond: 100), owner: "limited", clock: clock.now,
            sleep: { clock.advance($0) })
        let report = await engine.runOnce(now: started)
        XCTAssertEqual(report.delivered, 1)
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertEqual(clock.now().timeIntervalSince(started), Double(expectedObjectBytes - 100) / 100,
                       accuracy: 0.000_001)
    }
}
