import Foundation
import XCTest
@testable import DicomCore

func upsFixture() -> DicomDataSet {
    .init(elements: [upsString(0x00741000, "SCHEDULED"), upsString(0x00741200, "MEDIUM"),
        upsString(0x00741204, "SYNTHETIC", .LO), upsString(0x00404005, "20260911090000", .DT),
        upsString(0x00404041, "READY"), upsSequence(0x00741002, []), upsSequence(0x00741216, [])])
}
func upsFinalAttributes() -> DicomDataSet {
    let code = DicomDataSet(elements: [upsString(0x00080100, "TEST", .SH), upsString(0x00080102, "99TEST", .SH),
                                      upsString(0x00080104, "Synthetic", .LO)])
    return .init(elements: [upsSequence(0x00741216, [.init(elements: [upsSequence(0x00404028, [code]),
        upsString(0x00404050, "20260911090000", .DT), upsString(0x00404051, "20260911100000", .DT),
        upsSequence(0x00404019, [code]), upsSequence(0x00404033, [])])]),
        upsSequence(0x00741002, [.init(elements: [upsString(0x00404052, "20260911100000", .DT), upsSequence(0x0074100E, [code])])])])
}
func upsRecord(_ state: DicomUnifiedProcedureStepState, final: Bool = true) -> DicomUnifiedProcedureStepRecord {
    var record = DicomUnifiedProcedureStepRecord(sopInstanceUID: "2.25.2352", attributes: upsFixture())
    record.state = state
    record.attributes.set(upsString(0x00741000, state.rawValue))
    record.transactionUID = state == .scheduled ? nil : "2.25.1"
    if final { for element in upsFinalAttributes().elements { record.attributes.set(element) } }
    return record
}
actor UPSJournal: DicomUnifiedProcedureStepEventSink, DicomUnifiedProcedureStepEventObserving {
    var events: [DicomUnifiedProcedureStepEvent] = []
    var outcomes: [DicomUnifiedProcedureStepDeliveryOutcome] = []
    var statuses: [UInt16?] = []
    var fail = false
    var store: DicomInMemoryUnifiedProcedureStepStore?
    var observedCommitted: [Bool] = []
    func configure(fail: Bool, store: DicomInMemoryUnifiedProcedureStepStore? = nil) { self.fail = fail; self.store = store }
    func deliver(_ event: DicomUnifiedProcedureStepEvent, to receivingAETitle: String) async throws {
        events.append(event)
        if let store { observedCommitted.append(store.all().contains { $0.sopInstanceUID == event.sopInstanceUID }) }
        if fail { throw DicomUnifiedProcedureStepDeliveryError(status: 0x0110) }
    }
    func attempted(event: DicomUnifiedProcedureStepEvent, receivingAE: String,
                   outcome: DicomUnifiedProcedureStepDeliveryOutcome, status: UInt16?, errorDescription: String?) {
        outcomes.append(outcome); statuses.append(status)
    }
    func reset() { events = []; outcomes = []; statuses = []; observedCommitted = [] }
}

final class DicomUnifiedProcedureStepTests: XCTestCase {
    func test_persistedRecord_roundTripPreservesLockStateAndDates() async throws {
        let scheduled = DicomUnifiedProcedureStepRecord(sopInstanceUID: "2.25.2352", attributes: upsFixture(),
                                                       now: Date(timeIntervalSince1970: 1_789_113_600))
        let claim = scheduled.changingState(to: .inProgress, transactionUID: "2.25.1",
                                           now: scheduled.created.addingTimeInterval(60))
        XCTAssertEqual(claim.status, 0)
        var record = try XCTUnwrap(claim.record)
        record.knownFinalStateTags = [0x00404035, 0x00080005]
        let persisted = try record.persisted
        XCTAssertEqual(persisted.knownFinalStateTags, [0x00080005, 0x00404035])
        let decoded = try JSONDecoder().decode(DicomUnifiedProcedureStepPersistedRecord.self,
                                              from: JSONEncoder().encode(persisted))
        XCTAssertEqual(decoded, persisted)
        let restored = try DicomUnifiedProcedureStepRecord(persisted: decoded)
        XCTAssertEqual(restored.sopInstanceUID, record.sopInstanceUID)
        XCTAssertEqual(restored.state, .inProgress)
        XCTAssertEqual(restored.state, record.state)
        XCTAssertEqual(restored.transactionUID, "2.25.1")
        XCTAssertEqual(restored.transactionUID, record.transactionUID)
        XCTAssertEqual(try DicomDataSetWriter.dataSetData(from: restored.attributes), persisted.attributes)
        XCTAssertEqual(restored.created, record.created)
        XCTAssertEqual(restored.modified, record.modified)
        XCTAssertEqual(restored.knownFinalStateTags, record.knownFinalStateTags)
        XCTAssertEqual(try restored.persisted, persisted)

        let store = DicomInMemoryUnifiedProcedureStepStore()
        try store.transaction(sopInstanceUID: restored.sopInstanceUID) { $0 = restored }
        let result = try await DicomUnifiedProcedureStepService(store: store).set(
            sopInstanceUID: restored.sopInstanceUID,
            attributes: .init(elements: [upsString(0x00081195, "2.25.2", .UI),
                                         upsString(0x00404041, "NOT READY")]))
        XCTAssertEqual(result.status, 0xC301)
    }

    func test_stateTable_everyCell() async throws {
        // Columns: absent, scheduled, in progress, completed, canceled (CC.1.1).
        let rows: [(DicomUnifiedProcedureStepState, Bool, [UInt16])] = [
            (.inProgress, true, [0xC307, 0, 0xC302, 0xC300, 0xC300]),
            (.inProgress, false, [0xC307, 0xC301, 0xC301, 0xC301, 0xC301]),
            (.scheduled, true, [0xC307, 0xC303, 0xC303, 0xC303, 0xC303]),
            (.completed, true, [0xC307, 0xC310, 0, 0xB306, 0xC300]),
            (.completed, false, [0xC307, 0xC301, 0xC301, 0xC301, 0xC301]),
            (.canceled, true, [0xC307, 0xC310, 0, 0xC300, 0xB304]),
            (.canceled, false, [0xC307, 0xC301, 0xC301, 0xC301, 0xC301])]
        let states: [DicomUnifiedProcedureStepState?] = [nil, .scheduled, .inProgress, .completed, .canceled]
        for (target, correct, expected) in rows {
            for (column, initial) in states.enumerated() {
                let store = DicomInMemoryUnifiedProcedureStepStore()
                if let initial { try store.transaction(sopInstanceUID: "2.25.2352") { $0 = upsRecord(initial) } }
                let result = try await DicomUnifiedProcedureStepService(store: store).changeState(sopInstanceUID: "2.25.2352",
                    to: target, transactionUID: correct ? "2.25.1" : nil)
                XCTAssertEqual(result.status, expected[column], "\(initial as Any) -> \(target), correct=\(correct)")
            }
        }
        for (index, state) in states.enumerated() {
            let store = DicomInMemoryUnifiedProcedureStepStore()
            if let state { try store.transaction(sopInstanceUID: "2.25.2352") { $0 = upsRecord(state) } }
            let service = DicomUnifiedProcedureStepService(store: store)
            let canceled = try await service.requestCancel(sopInstanceUID: "2.25.2352", requestingAE: "REQUESTOR")
            XCTAssertEqual(canceled.status, [0xC307, 0, 0, 0xC311, 0xB304][index])
            let created = try await service.create(sopInstanceUID: "2.25.2352", attributes: upsFixture())
            XCTAssertEqual(created.status, state == nil ? 0 : 0x0111)
        }
    }
    func test_finalStateRequirements_transcriptionAndNestedValidation() {
        let rows = DicomUnifiedProcedureStepAttribute.table
        XCTAssertEqual(Set(rows.filter { $0.finalState == "R" }.map(\.tag)),
            [0x00080016, 0x00080018, 0x00741200, 0x00404010, 0x00404005, 0x00404041, 0x00741000])
        XCTAssertEqual(Set(rows.filter { $0.finalState == "P" }.map(\.tag)),
            [0x00741216, 0x00404028, 0x00404050, 0x00404019, 0x00404051, 0x00404033])
        XCTAssertEqual(Set(rows.filter { $0.finalState == "X" }.map(\.tag)), [0x00741002, 0x00404052, 0x0074100E])
        for target in [DicomUnifiedProcedureStepState.completed, .canceled] {
            XCTAssertTrue(upsRecord(.inProgress).finalStateViolations(for: target).isEmpty)
            for row in rows where row.finalState == "R" || (target == .completed && row.finalState == "P")
                || (target == .canceled && row.finalState == "X") {
                var record = upsRecord(.inProgress)
                if row.path.count == 1 { record.attributes.remove(row.tag) }
                else {
                    let parent = row.path[0]
                    var nested = record.attributes.sequenceItems(for: parent)[0].dataSet
                    nested.remove(row.tag)
                    record.attributes.set(upsSequence(parent, [nested]))
                }
                XCTAssertTrue(record.finalStateViolations(for: target).contains(row.tag), row.name)
            }
            XCTAssertEqual(upsRecord(.inProgress, final: false).changingState(to: target, transactionUID: "2.25.1").status, 0xC304)
        }
        var record = upsRecord(.inProgress)
        record.knownFinalStateTags = [0x00404035]
        XCTAssertTrue(record.finalStateViolations(for: .completed).contains(0x00404035))
    }
    func test_createValidation_defaultsAndTransactionSecrecy() async throws {
        let store = DicomInMemoryUnifiedProcedureStepStore()
        let service = DicomUnifiedProcedureStepService(store: store)
        for row in DicomUnifiedProcedureStepAttribute.table where row.path.count == 1 && row.create.hasPrefix("1/1") {
            var attributes = upsFixture(); attributes.remove(row.tag)
            let result = try await service.create(sopInstanceUID: "2.25.2352", attributes: attributes)
            XCTAssertNotEqual(result.status, 0, row.name)
        }
        let wrong = try await service.create(sopInstanceUID: "2.25.2352", attributes: upsFixture().setting(upsString(0x00741000, "COMPLETED")))
        XCTAssertEqual(wrong.status, 0xC309)
        let created = try await service.create(sopInstanceUID: "2.25.2352", attributes: upsFixture())
        XCTAssertEqual(created.status, 0)
        XCTAssertEqual(created.record?.attributes.string(for: 0x00741202), "DEFAULT")
        _ = try await service.changeState(sopInstanceUID: "2.25.2352", to: .inProgress, transactionUID: "2.25.1")
        XCTAssertNil(try service.get(sopInstanceUID: "2.25.2352").dataSet?[0x00081195])
        XCTAssertEqual(try service.get(sopInstanceUID: "2.25.2352", attributes: [0x00741000]).dataSet?.count, 1)
        XCTAssertTrue(try service.get(sopInstanceUID: "2.25.2352", attributes: [0x00081195]).dataSet!.isEmpty)
    }
    func test_twoConcurrentClaims_exactlyOneSuccess() async throws {
        let service = DicomUnifiedProcedureStepService(store: DicomInMemoryUnifiedProcedureStepStore())
        _ = try await service.create(sopInstanceUID: "2.25.2352", attributes: upsFixture())
        async let first = service.changeState(sopInstanceUID: "2.25.2352", to: .inProgress, transactionUID: "2.25.1")
        async let second = service.changeState(sopInstanceUID: "2.25.2352", to: .inProgress, transactionUID: "2.25.2")
        let statuses = try await [first.status, second.status]
        XCTAssertEqual(statuses.sorted(), [0, 0xC301])
    }
    func test_setAtomicIdempotentAndOwnership() async throws {
        let store = DicomInMemoryUnifiedProcedureStepStore()
        let journal = UPSJournal()
        let service = DicomUnifiedProcedureStepService(store: store, eventSink: journal)
        _ = try await service.create(sopInstanceUID: "2.25.2352", attributes: upsFixture())
        _ = try await service.subscribe(sopInstanceUID: "2.25.2352", receivingAE: "WATCH", deletionLock: false)
        let forbidden = try await service.set(sopInstanceUID: "2.25.2352", attributes: .init(elements: [upsString(0x00081195, "", .UI)]))
        XCTAssertEqual(forbidden.status, 0xC301)
        _ = try await service.changeState(sopInstanceUID: "2.25.2352", to: .inProgress, transactionUID: "2.25.1")
        let change = DicomDataSet(elements: [upsSequence(0x00741002, [.init(elements: [upsString(0x00741004, "50", .DS)])])])
        for uid in [nil, "2.25.2"] as [String?] {
            let ds = uid.map { change.setting(upsString(0x00081195, $0, .UI)) } ?? change
            let result = try await service.set(sopInstanceUID: "2.25.2352", attributes: ds)
            XCTAssertEqual(result.status, 0xC301)
        }
        await journal.reset()
        let valid = change.setting(upsString(0x00081195, "2.25.1", .UI))
        for _ in 0..<2 { let result = try await service.set(sopInstanceUID: "2.25.2352", attributes: valid); XCTAssertEqual(result.status, 0) }
        let events = await journal.events
        XCTAssertEqual(events.map(\.typeID), [3])
        let before = store.all()[0].attributes
        let invalid = try await service.set(sopInstanceUID: "2.25.2352", attributes: valid.setting(upsString(0x00100010, "CHANGE", .PN)))
        XCTAssertEqual(invalid.status, 0x0106)
        XCTAssertEqual(store.all()[0].attributes, before)
        for state in [DicomUnifiedProcedureStepState.completed, .canceled] {
            try store.transaction(sopInstanceUID: "2.25.2352") { $0 = upsRecord(state) }
            let result = try await service.set(sopInstanceUID: "2.25.2352", attributes: valid)
            XCTAssertEqual(result.status, 0xC300)
        }
    }
    func test_subscriptionTable_everyRowAndInitialState() async throws {
        let global = DicomUnifiedProcedureStepService.globalUID
        for initial in DicomUnifiedProcedureStepSubscriptionState.allCases {
            for action in 0..<7 {
                let store = DicomInMemoryUnifiedProcedureStepStore()
                try store.transaction(sopInstanceUID: "2.25.2352") { $0 = upsRecord(.scheduled) }
                store.setSubscription(sopInstanceUID: "2.25.2352", ae: "WATCH", state: initial)
                let journal = UPSJournal()
                let service = DicomUnifiedProcedureStepService(store: store, eventSink: journal)
                switch action {
                case 0, 1: _ = try await service.subscribe(sopInstanceUID: global, receivingAE: "WATCH", deletionLock: action == 0)
                case 2, 3: _ = try await service.subscribe(sopInstanceUID: "2.25.2352", receivingAE: "WATCH", deletionLock: action == 2)
                case 4: _ = try await service.unsubscribe(sopInstanceUID: "2.25.2352", receivingAE: "WATCH")
                case 5: _ = try await service.unsubscribe(sopInstanceUID: global, receivingAE: "WATCH")
                default: _ = try await service.suspend(receivingAE: "WATCH")
                }
                let expected: DicomUnifiedProcedureStepSubscriptionState
                switch action {
                case 0, 1: expected = initial == .notSubscribed ? (action == 0 ? .withLock : .withoutLock) : initial
                case 2: expected = .withLock
                case 3: expected = .withoutLock
                case 4, 5: expected = .notSubscribed
                default: expected = initial
                }
                XCTAssertEqual(store.subscriptions(sopInstanceUID: "2.25.2352")["WATCH"], expected)
                let events = await journal.events
                XCTAssertEqual(events.count, [0, 2, 3].contains(action) ? 1 : 0)
                if [0, 1, 5, 6].contains(action) {
                    XCTAssertEqual(store.globalSubscriptions()["WATCH"]?.state,
                        action == 0 ? .withLock : action == 1 ? .withoutLock : .notSubscribed)
                }
            }
        }
        for state in DicomUnifiedProcedureStepSubscriptionState.allCases {
            let store = DicomInMemoryUnifiedProcedureStepStore()
            store.setGlobalSubscription(ae: "WATCH", subscription: .init(state: state))
            let journal = UPSJournal()
            _ = try await DicomUnifiedProcedureStepService(store: store, eventSink: journal)
                .create(sopInstanceUID: "2.25.2352", attributes: upsFixture())
            XCTAssertEqual(store.subscriptions(sopInstanceUID: "2.25.2352")["WATCH", default: .notSubscribed], state)
            let events = await journal.events
            XCTAssertEqual(events.count, state == .notSubscribed ? 0 : 1)
        }
    }
    func test_deletionRetentionFilteredSubscriptionAndRefusal() async throws {
        let store = DicomInMemoryUnifiedProcedureStepStore()
        let journal = UPSJournal()
        let service = DicomUnifiedProcedureStepService(store: store, eventSink: journal)
        _ = try await service.subscribe(sopInstanceUID: DicomUnifiedProcedureStepService.filteredUID,
            receivingAE: "WATCH", deletionLock: true, matchingKeys: .init(elements: [upsString(0x00741204, "SYN*", .LO)]))
        _ = try await service.create(sopInstanceUID: "2.25.2352", attributes: upsFixture())
        _ = try await service.requestCancel(sopInstanceUID: "2.25.2352", requestingAE: "REQUESTOR")
        XCTAssertEqual(store.deletionLockHolders(sopInstanceUID: "2.25.2352"), ["WATCH"])
        XCTAssertFalse(try store.purgeEligible(sopInstanceUID: "2.25.2352"))
        _ = try await service.suspend(receivingAE: "WATCH")
        XCTAssertFalse(try store.purgeEligible(sopInstanceUID: "2.25.2352"))
        _ = try await service.unsubscribe(sopInstanceUID: DicomUnifiedProcedureStepService.globalUID, receivingAE: "WATCH")
        XCTAssertTrue(try store.purgeEligible(sopInstanceUID: "2.25.2352"))
        var policy = DicomUnifiedProcedureStepPolicy(); policy.grantDeletionLock = { _ in false }
        let refused = try await DicomUnifiedProcedureStepService(store: store, policy: policy, eventSink: journal)
            .subscribe(sopInstanceUID: "2.25.2352", receivingAE: "WATCH", deletionLock: true)
        XCTAssertEqual(refused.status, 0xB301)
        XCTAssertTrue(store.deletionLockHolders(sopInstanceUID: "2.25.2352").isEmpty)
    }
    func test_commitBeforeEvent_failureObservedAndCancellationTwoStates() async throws {
        let store = DicomInMemoryUnifiedProcedureStepStore()
        let journal = UPSJournal()
        await journal.configure(fail: true, store: store)
        let service = DicomUnifiedProcedureStepService(store: store, eventSink: journal, observer: journal)
        _ = try await service.subscribe(sopInstanceUID: DicomUnifiedProcedureStepService.globalUID, receivingAE: "WATCH", deletionLock: true)
        _ = try await service.create(sopInstanceUID: "2.25.2352", attributes: upsFixture())
        let canceled = try await service.requestCancel(sopInstanceUID: "2.25.2352", requestingAE: "REQUESTOR")
        XCTAssertEqual(canceled.status, 0)
        XCTAssertEqual(store.all()[0].state, .canceled)
        XCTAssertTrue(store.all()[0].finalStateViolations(for: .canceled).isEmpty)
        let events = await journal.events
        XCTAssertEqual(events.map { $0.dataSet.string(for: 0x00741000) }, ["SCHEDULED", "IN PROGRESS", "CANCELED"])
        let outcomes = await journal.outcomes
        let committed = await journal.observedCommitted
        XCTAssertEqual(outcomes, [.failed, .failed, .failed])
        XCTAssertEqual(committed, [true, true, true])
    }
    func test_cancelPolicyAndTypedEvents() async throws {
        let store = DicomInMemoryUnifiedProcedureStepStore()
        try store.transaction(sopInstanceUID: "2.25.2352") { $0 = upsRecord(.inProgress) }
        for (decision, expected): (DicomUnifiedProcedureStepPolicy.CancelDecision, UInt16) in [(.noSubscriber, 0xC312), (.refused, 0xC313)] {
            var policy = DicomUnifiedProcedureStepPolicy(); policy.cancelDecision = { _, _ in decision }
            let result = try await DicomUnifiedProcedureStepService(store: store, policy: policy)
                .requestCancel(sopInstanceUID: "2.25.2352", requestingAE: "CALLING")
            XCTAssertEqual(result.status, expected)
            XCTAssertEqual(store.all()[0].state, .inProgress)
        }
        let journal = UPSJournal()
        let service = DicomUnifiedProcedureStepService(store: store, eventSink: journal)
        _ = try await service.subscribe(sopInstanceUID: "2.25.2352", receivingAE: "WATCH", deletionLock: false)
        await journal.reset()
        _ = try await service.requestCancel(sopInstanceUID: "2.25.2352", requestingAE: "CALLING",
            information: .init(elements: [upsString(0x00741238, "Stop", .LT), upsString(0x0074100A, "mailto:test@example.invalid", .UR)]))
        let cancelEvents = await journal.events
        XCTAssertEqual(cancelEvents[0].typeID, 2)
        XCTAssertEqual(cancelEvents[0].dataSet.string(for: 0x00741236), "CALLING")
        XCTAssertEqual(cancelEvents[0].dataSet.string(for: 0x0074100A), "mailto:test@example.invalid")
        XCTAssertEqual(store.all()[0].state, .inProgress)
        await journal.reset()
        let code = DicomDataSet(elements: [upsString(0x00080100, "TEST", .SH)])
        let set = try await service.set(sopInstanceUID: "2.25.2352", attributes: .init(elements: [
            upsString(0x00081195, "2.25.1", .UI), upsString(0x00404041, "NOT READY"), upsSequence(0x00404025, [code])]))
        XCTAssertEqual(set.status, 0)
        let events = await journal.events
        XCTAssertEqual(events.map(\.typeID), [1, 5])
        let noEvents = try await DicomUnifiedProcedureStepService(store: store)
            .subscribe(sopInstanceUID: "2.25.2352", receivingAE: "WATCH", deletionLock: false)
        XCTAssertEqual(noEvents.status, 0xC315)
    }

    func test_restartWarmAndColdLists() async throws {
        let saved = DicomInMemoryUnifiedProcedureStepStore()
        try saved.transaction(sopInstanceUID: "2.25.2352") { $0 = upsRecord(.inProgress) }
        saved.setSubscription(sopInstanceUID: "2.25.2352", ae: "WATCH", state: .withLock)
        for warm in [false, true] {
            let restored = DicomInMemoryUnifiedProcedureStepStore()
            if warm { restored.restore(snapshot: saved.snapshot()) }
            var policy = DicomUnifiedProcedureStepPolicy(); policy.fallbackAETitles = ["WATCH"]
            let journal = UPSJournal()
            try await DicomUnifiedProcedureStepService(store: restored, policy: policy, eventSink: journal).scpStatusChanged(status: .restarted)
            let events = await journal.events
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events[0].typeID, 4)
            XCTAssertEqual(events[0].dataSet.string(for: 0x00741244), warm ? "WARM START" : "COLD START")
            XCTAssertEqual(events[0].dataSet.string(for: 0x00741246), warm ? "WARM START" : "COLD START")
            if warm { XCTAssertEqual(restored.all()[0].transactionUID, "2.25.1") }
        }
    }
}
