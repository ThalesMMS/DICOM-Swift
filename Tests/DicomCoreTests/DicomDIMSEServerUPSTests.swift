import Foundation
import XCTest
@testable import DicomCore

final class DicomDIMSEServerUPSTests: XCTestCase {
    func test_allFiveClassesNegotiateAndEnforceOperations() throws {
        for uid in DicomNetworkUID.unifiedProcedureStepSOPClasses {
            let command = DicomDIMSECommandSet(affectedSOPClassUID: DicomNetworkUID.unifiedProcedureStepPushSOPClass,
                commandField: DicomDIMSECommandField.nCreateRQ, messageID: 1,
                commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet, affectedSOPInstanceUID: "2.25.2352")
            let transport = try A2Transport(uid: uid, commands: [(command, upsFixture())])
            try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"),
                unifiedProcedureSteps: .init(store: DicomInMemoryUnifiedProcedureStepStore())).handleAssociation(using: transport)
            XCTAssertEqual(try transport.commands().last?.status, uid == DicomNetworkUID.unifiedProcedureStepPushSOPClass ? 0 : 0x0211)
        }
    }
    func test_pushClassUnderPull_claimAndGet() throws {
        let store = DicomInMemoryUnifiedProcedureStepStore()
        try store.transaction(sopInstanceUID: "2.25.2352") { $0 = upsRecord(.scheduled) }
        let command = DicomDIMSECommandSet(requestedSOPClassUID: DicomNetworkUID.unifiedProcedureStepPushSOPClass,
            commandField: DicomDIMSECommandField.nActionRQ, messageID: 1,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet, requestedSOPInstanceUID: "2.25.2352", actionTypeID: 1)
        let attributes = DicomDataSet(elements: [upsString(0x00741000, "IN PROGRESS"), upsString(0x00081195, "2.25.1", .UI)])
        let transport = try A2Transport(uid: DicomNetworkUID.unifiedProcedureStepPullSOPClass, commands: [(command, attributes)])
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), unifiedProcedureSteps: .init(store: store)).handleAssociation(using: transport)
        let response = try XCTUnwrap(transport.commands().last)
        XCTAssertEqual(response.status, 0); XCTAssertEqual(response.actionTypeID, 1)
        XCTAssertEqual(response.affectedSOPClassUID, DicomNetworkUID.unifiedProcedureStepPushSOPClass)
        XCTAssertEqual(store.all()[0].state, .inProgress)
    }
    func test_findReturnKeysAndNoMatchingKeys() throws {
        let store = DicomInMemoryUnifiedProcedureStepStore()
        try store.transaction(sopInstanceUID: "2.25.2352") { $0 = upsRecord(.scheduled) }
        let service = DicomUnifiedProcedureStepService(store: store)
        let identifier = DicomDataSet(elements: [upsString(0x00741000, "SCHEDULED"), upsString(0x00080016, "", .UI),
                                                upsString(0x00080018, "", .UI)])
        let matches = try service.search(identifier: identifier)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].dataSet.string(for: 0x00080016), DicomNetworkUID.unifiedProcedureStepPushSOPClass)
        XCTAssertNil(matches[0].dataSet[0x00081195])
        XCTAssertTrue(try service.search(identifier: .init(elements: [upsSequence(0x00741002, [])])).isEmpty)
        let uid = DicomNetworkUID.unifiedProcedureStepQuerySOPClass
        let transport = try A2Transport(uid: uid, commands: [(.init(affectedSOPClassUID: uid,
            commandField: DicomDIMSECommandField.cFindRQ, messageID: 1,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet), identifier)])
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), unifiedProcedureSteps: service).handleAssociation(using: transport)
        XCTAssertEqual(try transport.commands().compactMap(\.status), [0xFF00, 0])
    }
    func test_eventReceptionAndFailureAcknowledgement() throws {
        let service = DicomUnifiedProcedureStepService(store: DicomInMemoryUnifiedProcedureStepStore(), eventReceiver: { uid, type, ds in
            XCTAssertEqual(uid, "2.25.2352"); XCTAssertEqual(type, 1)
            XCTAssertEqual(ds.string(for: 0x00741000), "SCHEDULED")
        })
        let command = DicomDIMSECommandSet(affectedSOPClassUID: DicomNetworkUID.unifiedProcedureStepPushSOPClass,
            commandField: DicomDIMSECommandField.nEventReportRQ, messageID: 1,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet, affectedSOPInstanceUID: "2.25.2352", eventTypeID: 1)
        let transport = try A2Transport(uid: DicomNetworkUID.unifiedProcedureStepEventSOPClass,
                                       commands: [(command, DicomUnifiedProcedureStepEvent.stateReport(upsRecord(.scheduled)).dataSet)])
        try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), unifiedProcedureSteps: service).handleAssociation(using: transport)
        XCTAssertEqual(try transport.commands().last?.status, 0)
    }
    #if os(macOS)
    func test_notificationRequiresExplicitServerPrincipal() async throws {
        let principal = DicomPrincipal(id: "ups-service", kind: .serviceAccount, source: .local,
            scopes: ["phi:restricted"], sessionID: "server-session", authenticatedAt: .distantPast, policyVersion: 1)
        for configured in [false, true] {
            let received = expectation(description: "Authorized UPS notification")
            received.isInverted = !configured
            let callback = DicomDIMSEServer(configuration: .init(aeTitle: "WATCH", port: 0),
                unifiedProcedureSteps: .init(store: DicomInMemoryUnifiedProcedureStepStore(),
                    eventReceiver: { _, _, _ in received.fulfill() }))
            try callback.start()
            let resolver = A2DestinationResolver()
            await resolver.set("WATCH", port: try XCTUnwrap(callback.listeningPort))
            let journal = UPSJournal()
            let service = DicomUnifiedProcedureStepService(store: DicomInMemoryUnifiedProcedureStepStore(), observer: journal)
            let sink = DicomInMemoryAuditSink()
            let primary = DicomDIMSEServer(configuration: .init(aeTitle: "ISIS", port: 0),
                moveDestinations: resolver, unifiedProcedureSteps: service,
                peerPrincipalResolver: { _, _, _ in
                    XCTFail("An outbound notification must not use the receiving peer's identity")
                    return principal
                }, notificationPrincipalProvider: { configured ? principal : nil },
                authorizer: DicomProtectionAuthorizer(policyVersion: 1) { resource in
                    [resource.id: .init(privacyFlags: [.restricted])]
                }, audit: DicomAuditRecorder(sinks: [sink], policy: .failClosed))
            do {
                _ = try await service.create(sopInstanceUID: "2.25.2352", attributes: upsFixture())
                _ = try await service.subscribe(sopInstanceUID: "2.25.2352", receivingAE: "WATCH", deletionLock: true)
                await fulfillment(of: [received], timeout: configured ? 3 : 0.1)
                let outcomes = await journal.outcomes
                XCTAssertEqual(outcomes, [configured ? .succeeded : .failed])
            } catch { await primary.stop(); await callback.stop(); throw error }
            await primary.stop(); await callback.stop()
        }
    }

    func test_eventDeliveredToSecondServer_peerResponseDeterminesObserverOutcome() async throws {
        for status: UInt16 in [0, 0x0110] {
            let received = expectation(description: "Event received before acknowledgement")
            let callback = DicomDIMSEServer(configuration: .init(aeTitle: "WATCH", port: 0),
                unifiedProcedureSteps: .init(store: DicomInMemoryUnifiedProcedureStepStore(), eventReceiver: { _, type, ds in
                    XCTAssertEqual(type, 1)
                    XCTAssertEqual(ds.string(for: 0x00741000), "SCHEDULED")
                    received.fulfill()
                    if status != 0 { throw DicomDIMSEProviderError(status: status) }
                }))
            try callback.start()
            let resolver = A2DestinationResolver()
            await resolver.set("WATCH", port: try XCTUnwrap(callback.listeningPort))
            let journal = UPSJournal()
            let service = DicomUnifiedProcedureStepService(store: DicomInMemoryUnifiedProcedureStepStore(), observer: journal)
            let primary = DicomDIMSEServer(configuration: .init(aeTitle: "ISIS", port: 0),
                moveDestinations: resolver, unifiedProcedureSteps: service)
            do {
                _ = try await service.create(sopInstanceUID: "2.25.2352", attributes: upsFixture())
                let result = try await service.subscribe(sopInstanceUID: "2.25.2352", receivingAE: "WATCH", deletionLock: true)
                XCTAssertEqual(result.status, 0)
                await fulfillment(of: [received], timeout: 3)
                let outcomes = await journal.outcomes
                let statuses = await journal.statuses
                XCTAssertEqual(outcomes, [status == 0 ? .succeeded : .failed])
                XCTAssertEqual(statuses, [status])
            } catch { await primary.stop(); await callback.stop(); throw error }
            await primary.stop(); await callback.stop()
        }
    }
    #endif

    func test_ianNCreateAcceptsValidRejectsExtra() async throws {
        let receiver = IANReceiver()
        let uid = DicomNetworkUID.instanceAvailabilityNotificationSOPClass
        let valid = try DicomInstanceAvailabilityNotificationBuilder.build(ianFixture())
        for invalid in [false, true] {
            let ds = invalid ? valid.setting(upsString(0x00100010, "FORBIDDEN", .PN)) : valid
            let transport = try A2Transport(uid: uid, commands: [(.init(affectedSOPClassUID: uid,
                commandField: DicomDIMSECommandField.nCreateRQ, messageID: 1,
                commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet, affectedSOPInstanceUID: "2.25.9"), ds)])
            try DicomDIMSEServer(configuration: .init(aeTitle: "ISIS"), instanceAvailability: receiver).handleAssociation(using: transport)
            XCTAssertEqual(try transport.commands().last?.status, invalid ? 0x0106 : 0)
        }
        let received = await receiver.received
        XCTAssertEqual(received.count, 1)
    }
}
