import Foundation
import XCTest
@testable import DicomCore

final class DicomWebNotificationClientTests: XCTestCase {
    func test_hostlessWebSocketURL_isRejectedBeforeConnecting() async throws {
        let client = DicomWebNotificationClient(factory: { _ in
            XCTFail("A hostless URL must never reach the connection factory")
            throw DicomWebError(kind: .server)
        })
        do {
            for try await _ in client.connect(to: URL(string: "ws:notify")!) {}
            XCTFail("A hostless URL must fail")
        } catch let error as DicomWebError {
            XCTAssertEqual(error.kind, .badRequest)
        }
    }

    func test_allEventTypes_objectEncodingAndDecode() throws {
        let record = upsRecord(.inProgress)
        let events: [DicomUnifiedProcedureStepEvent] = [.stateReport(record),
            .init(sopInstanceUID: record.sopInstanceUID, payload: .cancel(requestingAE: "TEST", information: .init())),
            .init(sopInstanceUID: record.sopInstanceUID, payload: .progress(.init(elements: [upsString(0x00741004, "50", .DS)]))),
            .init(sopInstanceUID: record.sopInstanceUID, payload: .scpStatus(.restarted, subscriptions: .warmStart, instances: .coldStart)),
            .init(sopInstanceUID: record.sopInstanceUID, payload: .assigned(.init(elements: [upsSequence(0x00404025, [])])))]
        for event in events {
            let text = try DicomWebNotificationEventSink.encode(event, messageID: 42)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual((object["00000110"] as? [String: Any])?["Value"] as? [Int], [42])
            let decoded = try DicomWebNotificationClient.decode(text)
            XCTAssertEqual(decoded.sopInstanceUID, event.sopInstanceUID)
            XCTAssertEqual(decoded.typeID, event.typeID)
            XCTAssertEqual(try DicomJSONCodec.encode(decoded.dataSet), try DicomJSONCodec.encode(event.dataSet))
        }
        XCTAssertThrowsError(try DicomWebNotificationClient.decode("[]"))
        XCTAssertThrowsError(try DicomWebNotificationClient.decode("{}"))
    }
    func test_reconnect_isBoundedAndEmitsGapBeforeFreshEvents() async throws {
        let text = try DicomWebNotificationEventSink.encode(.stateReport(upsRecord(.scheduled)))
        let factory = NotificationFakeFactory(text: text)
        var configuration = DicomWebNotificationClientConfiguration()
        configuration.maximumReconnects = 1; configuration.initialBackoff = 0; configuration.maximumBackoff = 0
        let client = DicomWebNotificationClient(configuration: configuration, factory: { _ in await factory.make() })
        var signals: [String] = []
        do {
            for try await signal in client.connect(to: URL(string: "ws://localhost/subscribers/TEST")!) {
                switch signal {
                case .connected: signals.append("connected")
                case .gap: signals.append("gap")
                case .event: signals.append("event")
                }
            }
            XCTFail("Expected terminal disconnection after the reconnect budget")
        } catch {}
        XCTAssertEqual(signals, ["connected", "event", "gap", "connected", "event"])
        let count = await factory.count
        XCTAssertEqual(count, 2)
    }
    func test_hub_allConnectionsAndObserverDisconnectedGap() async throws {
        let hub = DicomWebNotificationHub()
        let journal = NotificationObserver()
        let store = DicomInMemoryUnifiedProcedureStepStore()
        let service = DicomUnifiedProcedureStepService(store: store, eventSink: DicomWebNotificationEventSink(hub: hub), observer: journal)
        _ = try await service.create(sopInstanceUID: "2.25.2352", attributes: upsFixture())
        _ = try await service.subscribe(sopInstanceUID: "2.25.2352", receivingAE: "TEST", deletionLock: false)
        let errors = await journal.errors
        XCTAssertTrue(errors.contains { $0?.contains("noConnection") == true })
        let first = NotificationCapture(), second = NotificationCapture()
        let firstID = await hub.register(first, ae: "TEST")
        let secondID = await hub.register(second, ae: "TEST")
        _ = try await service.subscribe(sopInstanceUID: "2.25.2352", receivingAE: "TEST", deletionLock: false)
        let initial1 = await first.texts, initial2 = await second.texts
        XCTAssertEqual(initial1.count, 1); XCTAssertEqual(initial1, initial2)
        await hub.unregister(firstID, ae: "TEST"); await hub.unregister(secondID, ae: "TEST")
        _ = try await service.changeState(sopInstanceUID: "2.25.2352", to: .inProgress, transactionUID: "2.25.1")
        _ = await hub.register(first, ae: "TEST")
        _ = try await service.subscribe(sopInstanceUID: "2.25.2352", receivingAE: "TEST", deletionLock: false)
        let reconnected = await first.texts
        XCTAssertEqual(reconnected.count, 2)
        XCTAssertEqual(try DicomWebNotificationClient.decode(reconnected[1]).dataSet.string(for: 0x00741000), "IN PROGRESS")
        let failing = NotificationCapture(fail: true)
        _ = await hub.register(failing, ae: "TEST")
        _ = try await service.subscribe(sopInstanceUID: "2.25.2352", receivingAE: "TEST", deletionLock: false)
        let failures = await journal.errors
        XCTAssertTrue(failures.contains { $0?.contains("writeFailure") == true })
        await hub.close()
    }
}

private actor NotificationFakeFactory {
    let text: String
    var count = 0
    init(text: String) { self.text = text }
    func make() -> NotificationFakeConnection { count += 1; return .init(text: text) }
}
private actor NotificationFakeConnection: DicomWebNotificationReceiving {
    var text: String?
    init(text: String) { self.text = text }
    func receive() async throws -> String {
        guard let text else { throw URLError(.networkConnectionLost) }
        self.text = nil
        return text
    }
    func ping() async throws {}
    nonisolated func cancel() {}
}
private actor NotificationCapture: DicomWebNotificationConnection {
    var texts: [String] = []
    let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    func send(text: String) throws { if fail { throw URLError(.cannotWriteToFile) }; texts.append(text) }
    func close() {}
}
private actor NotificationObserver: DicomUnifiedProcedureStepEventObserving {
    var errors: [String?] = []
    func attempted(event: DicomUnifiedProcedureStepEvent, receivingAE: String,
                   outcome: DicomUnifiedProcedureStepDeliveryOutcome, status: UInt16?, errorDescription: String?) {
        errors.append(errorDescription)
    }
}
