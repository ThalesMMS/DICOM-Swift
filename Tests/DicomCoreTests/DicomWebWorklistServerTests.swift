import Foundation
import XCTest
@testable import DicomCore

final class DicomWebWorklistServerTests: XCTestCase {
    let base = "https://example.test/dicom-web"
    let uid = "2.25.2352"
    func test_client_acceptsMixedCaseMediaTypesWithoutChangingBoundary() async throws {
        let server = try server(.scheduled)
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: base)!),
                                    transport: MixedCaseWorklistTransport(server: server))
        for type in ["application/dicom+json", "multipart/related; type=\"application/dicom+xml\""] {
            let response = try await client.retrieveWorkitem(uid, accept: type)
            XCTAssertEqual(response.workitems.count, 1)
            XCTAssertEqual(response.workitems.first?.string(for: 0x00741000), "SCHEDULED")
        }
    }

    func request(_ server: DicomWebServer, _ method: DicomWebHTTPMethod, _ path: String,
                 _ data: DicomDataSet? = nil, headers: [String: String] = [:]) async throws -> DicomWebHTTPResponse {
        try await server.send(.init(method: method, url: URL(string: base + path)!,
            headers: ["Content-Type": "application/dicom+json"].merging(headers) { _, value in value },
            body: data.map { try DicomJSONCodec.encode([$0]) }))
    }
    func server(_ state: DicomUnifiedProcedureStepState? = nil, final: Bool = true,
                policy: DicomUnifiedProcedureStepPolicy = .init(), configuration: DicomWebServerConfiguration = .init()) throws -> DicomWebServer {
        let store = DicomInMemoryUnifiedProcedureStepStore()
        if let state { try store.transaction(sopInstanceUID: uid) { $0 = upsRecord(state, final: final) } }
        return .init(configuration: configuration, unifiedProcedureSteps: .init(store: store, policy: policy), notifications: .init())
    }
    func warning(_ response: DicomWebHTTPResponse, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response.headers["Warning"], "299 \(base): \(text)", file: file, line: line)
    }
    func test_create_retrieve_UIDGeneration_MediaTypesAndInvalidPayloads() async throws {
        let server = try server()
        let created = try await request(server, .post, "/workitems?workitem=\(uid)", webWorkitemFixture())
        XCTAssertEqual(created.statusCode, 201)
        XCTAssertEqual(created.headers["Location"], base + "/workitems/" + uid)
        warning(created, "The Workitem was created with modifications.")
        let duplicate = try await request(server, .post, "/workitems?workitem=\(uid)", webWorkitemFixture())
        XCTAssertEqual(duplicate.statusCode, 409)
        let generated = try await request(server, .post, "/workitems", webWorkitemFixture())
        XCTAssertEqual(generated.statusCode, 201)
        XCTAssertNotEqual(generated.headers["Location"], created.headers["Location"])
        for tag in [0x00080018, 0x00001000] {
            var invalid = webWorkitemFixture(); invalid.set(upsString(tag, "2.25.9", .UI))
            let response = try await request(server, .post, "/workitems", invalid)
            XCTAssertEqual(response.statusCode, 400)
        }
        for data in [DicomDataSet(), DicomDataSet(elements: [upsString(0x00741000, "COMPLETED")])] {
            let response = try await request(server, .post, "/workitems", data)
            XCTAssertEqual(response.statusCode, 400)
        }
        let unsupported = try await request(server, .post, "/workitems", webWorkitemFixture(), headers: ["Content-Type": "application/dicom"])
        XCTAssertEqual(unsupported.statusCode, 415)
        let xmlBytes = try DicomNativeXMLCodec.encode(webWorkitemFixture())
        var multipart = Data("--ups\r\nContent-Type: application/dicom+xml\r\n\r\n".utf8)
        multipart.append(xmlBytes); multipart.append(Data("\r\n--ups--\r\n".utf8))
        let xmlCreate = try await server.send(.init(method: .post, url: URL(string: base + "/workitems")!,
            headers: ["Content-Type": "multipart/related; type=\"application/dicom+xml\"; boundary=ups"], body: multipart))
        XCTAssertEqual(xmlCreate.statusCode, 201)
        for accept in ["application/dicom+json", "multipart/related; type=\"application/dicom+xml\""] {
            let retrieved = try await request(server, .get, "/workitems/\(uid)", headers: ["Accept": accept])
            XCTAssertEqual(retrieved.statusCode, 200)
            XCTAssertFalse(String(decoding: retrieved.body, as: UTF8.self).contains("00081195"))
        }
        let rejected = try await request(server, .get, "/workitems/\(uid)", headers: ["Accept": "image/jpeg"])
        XCTAssertEqual(rejected.statusCode, 406)
        let unknown = try await request(server, .get, "/workitems/2.25.999")
        XCTAssertEqual(unknown.statusCode, 404)
    }

    func test_update_statusAndWarnings() async throws {
        let label = DicomDataSet(elements: [upsString(0x00741204, "CHANGED", .LO)])
        for state in DicomUnifiedProcedureStepState.allCases {
            for transaction in ["", "?transaction-uid=2.25.1", "?transaction-uid=2.25.2"] {
                let server = try server(state)
                let response = try await request(server, .post, "/workitems/\(uid)" + transaction, label)
                let success = state == .scheduled && transaction.isEmpty || state == .inProgress && transaction == "?transaction-uid=2.25.1"
                XCTAssertEqual(response.statusCode, success ? 200 : 400, "\(state) \(transaction)")
                if state.isFinal { warning(response, "The submitted request is inconsistent with the current state of the Workitem.") }
                else if !success { warning(response, transaction.isEmpty ? "The Transaction UID is missing." : "The Transaction UID is incorrect.") }
            }
        }
        let server = try server(.scheduled)
        let conflict = try await request(server, .post, "/workitems/\(uid)", .init(elements: [upsString(0x00741000, "COMPLETED")]))
        XCTAssertEqual(conflict.statusCode, 409)
        warning(conflict, "The submitted request is inconsistent with the current state of the Workitem.")
        let invalid = try await request(server, .post, "/workitems/\(uid)", .init(elements: [upsString(0x00100010, "FORBIDDEN", .PN)]))
        XCTAssertEqual(invalid.statusCode, 400)
        let unknown = try await request(server, .post, "/workitems/2.25.999", label)
        XCTAssertEqual(unknown.statusCode, 404)
    }

    func test_changeState_allStateTableCells() async throws {
        for state in DicomUnifiedProcedureStepState.allCases {
            for target in DicomUnifiedProcedureStepState.allCases {
                for transaction in ["", "2.25.1", "2.25.2"] {
                    let server = try server(state)
                    var data = DicomDataSet(elements: [upsString(0x00741000, target.rawValue)])
                    if !transaction.isEmpty { data.set(upsString(0x00081195, transaction, .UI)) }
                    let expected = upsRecord(state).changingState(to: target, transactionUID: transaction.isEmpty ? nil : transaction).status
                    let response = try await request(server, .put, "/workitems/\(uid)/state?requester=TEST", data)
                    let code = expected == 0 || expected == 0xB304 || expected == 0xB306 ? 200 : expected == 0xC301 ? 400 : 409
                    XCTAssertEqual(response.statusCode, code, "\(state) -> \(target) \(transaction)")
                    if expected == 0xB304 { warning(response, "The UPS is already in the requested state of CANCELED.") }
                    if expected == 0xB306 { warning(response, "The UPS is already in the requested state of COMPLETED.") }
                    if expected == 0xC301 { warning(response, transaction.isEmpty ? "The Transaction UID is missing." : "The Transaction UID is incorrect.") }
                    if expected == 0xC310 { warning(response, "The Target URI did not reference a claimed Workitem.") }
                }
            }
        }
        let data = DicomDataSet(elements: [upsString(0x00741000, "COMPLETED"), upsString(0x00081195, "2.25.1", .UI)])
        let incomplete = try await request(server(.inProgress, final: false), .put, "/workitems/\(uid)/state", data)
        XCTAssertEqual(incomplete.statusCode, 409)
        let unknown = try await request(server(), .put, "/workitems/\(uid)/state", data)
        XCTAssertEqual(unknown.statusCode, 404)
        let invalid = try await request(server(.scheduled), .put, "/workitems/\(uid)/state", .init())
        XCTAssertEqual(invalid.statusCode, 400)
    }

    func test_cancellation_successAndConflictPolicyRows() async throws {
        for state in DicomUnifiedProcedureStepState.allCases {
            let response = try await request(server(state), .post, "/workitems/\(uid)/cancelrequest?requester=TEST", .init())
            XCTAssertEqual(response.statusCode, state == .completed ? 409 : 202)
            if state == .canceled { warning(response, "The UPS is already in the requested state of CANCELED.") }
        }
        for decision in [DicomUnifiedProcedureStepPolicy.CancelDecision.noSubscriber, .refused] {
            var policy = DicomUnifiedProcedureStepPolicy(); policy.cancelDecision = { _, _ in decision }
            let response = try await request(server(.inProgress, policy: policy), .post, "/workitems/\(uid)/cancelrequest", .init())
            XCTAssertEqual(response.statusCode, 409)
            warning(response, "The submitted request is inconsistent with the current state of the Workitem.")
        }
        let unknown = try await request(server(), .post, "/workitems/\(uid)/cancelrequest", .init())
        XCTAssertEqual(unknown.statusCode, 404)
    }

    func test_search_projection_matching_pagingAndLimits() async throws {
        let server = try server(.inProgress)
        let found = try await request(server, .get, "/workitems?ProcedureStepState=IN%20PROGRESS&includefield=00404010&fuzzymatching=true")
        XCTAssertEqual(found.statusCode, 200)
        warning(found, "The fuzzymatching parameter is not supported. Only literal matching has been performed.")
        let data = try XCTUnwrap(DicomJSONCodec.decode(found.body).first?.dataSet)
        XCTAssertEqual(data.string(for: 0x00080018), uid)
        XCTAssertNotNil(data[0x00404010]); XCTAssertNil(data[0x00081195])
        for row in DicomUnifiedProcedureStepAttribute.table where row.path.count == 1 && row.returned == "2" {
            XCTAssertNotNil(data[row.tag], row.name)
        }
        for query in ["ProcedureStepState=SCHEDULED", "offset=1", "limit=0"] {
            let response = try await request(server, .get, "/workitems?" + query)
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "[]")
        }
        for query in ["offset=-1", "limit=no", "fuzzymatching=yes", "unknown=x", "00081195=2.25.1", "limit=1&limit=2", "includefield=unknown"] {
            let response = try await request(server, .get, "/workitems?" + query)
            XCTAssertEqual(response.statusCode, 400, query)
        }
        var configuration = DicomWebServerConfiguration(); configuration.maximumSearchResults = 0
        let tooLarge = try await request(self.server(.scheduled, configuration: configuration), .get, "/workitems")
        XCTAssertEqual(tooLarge.statusCode, 413)
    }

    func test_subscription_allResources_unsubscribe_suspend_refusals() async throws {
        let server = try server(.scheduled)
        for target in [uid, DicomUnifiedProcedureStepService.globalUID, DicomUnifiedProcedureStepService.filteredUID] {
            let path = "/workitems/\(target)/subscribers/TEST"
            let filter = target == DicomUnifiedProcedureStepService.filteredUID ? "&filter=ProcedureStepState=SCHEDULED" : ""
            let created = try await request(server, .post, path + "?deletionlock=true" + filter)
            XCTAssertEqual(created.statusCode, 201)
            XCTAssertEqual(created.headers["Content-Location"], "wss://example.test/dicom-web/subscribers/TEST")
            if target != uid {
                let suspended = try await request(server, .post, path + "/suspend")
                XCTAssertEqual(suspended.statusCode, 200)
                let missing = try await request(server, .post, path + "/suspend")
                XCTAssertEqual(missing.statusCode, 404)
                _ = try await request(server, .post, path + "?deletionlock=true" + filter)
            }
            let removed = try await request(server, .delete, path)
            XCTAssertEqual(removed.statusCode, 200)
            let missing = try await request(server, .delete, path)
            XCTAssertEqual(missing.statusCode, 404)
        }
        var policy = DicomUnifiedProcedureStepPolicy(); policy.grantDeletionLock = { _ in false }
        let deniedLock = try await request(self.server(.scheduled, policy: policy), .post, "/workitems/\(uid)/subscribers/TEST?deletionlock=true")
        XCTAssertEqual(deniedLock.statusCode, 201); warning(deniedLock, "Deletion Lock not granted.")
        var configuration = DicomWebServerConfiguration(); configuration.supportsFilteredWorklistSubscriptions = false
        let refused = try await request(self.server(.scheduled, configuration: configuration), .post,
            "/workitems/\(DicomUnifiedProcedureStepService.filteredUID)/subscribers/TEST?filter=ProcedureStepState=SCHEDULED")
        XCTAssertEqual(refused.statusCode, 403); warning(refused, "Filtered Worklist Subscriptions are not supported.")
        let forbidden = DicomWebServer(unifiedProcedureSteps: server.unifiedProcedureSteps, notifications: server.notifications, authorizeWorklistSubscription: { _ in false })
        let denied = try await request(forbidden, .post, "/workitems/\(uid)/subscribers/TEST")
        XCTAssertEqual(denied.statusCode, 403)
        let unknown = try await request(server, .post, "/workitems/2.25.999/subscribers/TEST")
        XCTAssertEqual(unknown.statusCode, 404)
    }

    func test_updateWarnings_modifiedAndUnsupportedOptionalAttributes() async throws {
        let server = try server(.scheduled)
        let modified = try await request(server, .post, "/workitems/\(uid)", .init(elements: [upsString(0x00404010, "20000101000000", .DT)]))
        XCTAssertEqual(modified.statusCode, 200)
        warning(modified, "The Workitem was updated with modifications.")
        let optional = try await request(server, .post, "/workitems/\(uid)", .init(elements: [upsString(0x0008103E, "Optional series description", .LO)]))
        XCTAssertEqual(optional.statusCode, 200)
        warning(optional, "Requested optional Attributes are not supported.")
    }

    func test_handshake_headersAndAuthentication() async throws {
        let server = try server()
        let headers = ["Upgrade": "websocket", "Connection": "keep-alive, Upgrade", "Sec-WebSocket-Version": "13",
                       "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==", "Sec-WebSocket-Protocol": "dicom", "Origin": "https://example.test"]
        let response = try await request(server, .get, "/subscribers/TEST", headers: headers)
        XCTAssertEqual(response.statusCode, 101)
        XCTAssertEqual(response.headers["Sec-WebSocket-Accept"], "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        XCTAssertEqual(response.headers["Sec-WebSocket-Protocol"], "dicom")
        for name in ["Upgrade", "Connection", "Sec-WebSocket-Version", "Sec-WebSocket-Key"] {
            var invalid = headers; invalid[name] = "invalid"
            let rejected = try await request(server, .get, "/subscribers/TEST", headers: invalid)
            XCTAssertEqual(rejected.statusCode, 400)
        }
        let protected = DicomWebServer(configuration: .init(requiredBearerToken: "test"), unifiedProcedureSteps: server.unifiedProcedureSteps, notifications: server.notifications)
        for path in ["/workitems", "/subscribers/TEST"] {
            let denied = try await request(protected, .get, path, headers: headers)
            XCTAssertEqual(denied.statusCode, 401)
        }
        let restricted = DicomWebServer(unifiedProcedureSteps: server.unifiedProcedureSteps,
            notifications: server.notifications, authorizeWorklistSubscription: { $0 == "ALLOWED" })
        let denied = try await request(restricted, .get, "/subscribers/TEST", headers: headers)
        XCTAssertEqual(denied.statusCode, 403)
        XCTAssertNil(denied.headers["Sec-WebSocket-Accept"])
        let allowed = try await request(restricted, .get, "/subscribers/ALLOWED", headers: headers)
        XCTAssertEqual(allowed.statusCode, 101)
    }

    func test_capabilities_advertiseOnlyConfiguredWorklistServices() async throws {
        for hasWorklist in [false, true] {
            for hasNotifications in [false, true] {
                let server = DicomWebServer(
                    unifiedProcedureSteps: hasWorklist ? .init(store: DicomInMemoryUnifiedProcedureStepStore()) : nil,
                    notifications: hasNotifications ? .init() : nil)
                let supportsNotifications = hasWorklist && hasNotifications
                let json = try await request(server, .get, "", headers: ["Accept": "application/json"])
                XCTAssertEqual(json.statusCode, 200)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json.body) as? [String: Any])
                let application = try XCTUnwrap(object["application"] as? [String: Any])
                let resources = try XCTUnwrap(application["resources"] as? [String: Any])
                let routes = try XCTUnwrap(resources["resource"] as? [[String: Any]])
                let paths = routes.compactMap { $0["path"] as? String }
                XCTAssertTrue(paths.contains("studies"))
                XCTAssertEqual(paths.contains("workitems"), hasWorklist)
                XCTAssertEqual(paths.contains("subscribers/{requester}"), supportsNotifications)
                let subscriptionPaths = [
                    "workitems/{workitem}/subscribers/{subscriber}",
                    "workitems/1.2.840.10008.5.1.4.34.5/subscribers/{subscriber}/suspend",
                    "workitems/1.2.840.10008.5.1.4.34.5.1/subscribers/{subscriber}/suspend"
                ]
                for path in subscriptionPaths {
                    XCTAssertEqual(paths.contains(path), supportsNotifications, path)
                }
                for path in ["workitems/{workitem}", "workitems/{workitem}/state", "workitems/{workitem}/cancelrequest"] {
                    XCTAssertEqual(paths.contains(path), hasWorklist, path)
                }
                XCTAssertEqual(object["notificationConnection"] != nil, supportsNotifications)
                XCTAssertEqual(object["notificationEncoding"] != nil, supportsNotifications)

                let wadl = try await request(server, .get, "", headers: ["Accept": "application/vnd.sun.wadl+xml"])
                let xml = String(decoding: wadl.body, as: UTF8.self)
                XCTAssertEqual(xml.contains("path=\"workitems\""), hasWorklist)
                XCTAssertEqual(xml.contains("path=\"subscribers/{requester}\""), supportsNotifications)
                for path in subscriptionPaths {
                    XCTAssertEqual(xml.contains("path=\"\(path)\""), supportsNotifications, path)
                }

                let markdown = try await request(server, .get, "", headers: ["Accept": "text/markdown"])
                let text = String(decoding: markdown.body, as: UTF8.self)
                let support = !hasWorklist ? "not configured" :
                    (supportsNotifications ? "UPS-RS worklist and WebSocket notifications" : "UPS-RS worklist")
                XCTAssertEqual(server.conformanceStatement.upsSupport.rawValue, support)
                XCTAssertTrue(text.contains("- UPS: \(support)"))
                XCTAssertEqual(text.contains("/subscribers/{requester}"), supportsNotifications)
                XCTAssertEqual(server.conformanceStatement.matrix.rows.first { $0.feature == "UPS-RS" }?.server, support)
            }
        }
    }

    func test_client_operationsUseWorklistRoutes() async throws {
        let server = try server()
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: base)!), transport: server)
        let created = try await client.createWorkitem(webWorkitemFixture(), workitemUID: uid)
        XCTAssertEqual(created.statusCode, 201)
        let retrieved = try await client.retrieveWorkitem(uid)
        XCTAssertEqual(retrieved.workitems.first?.string(for: 0x00741000), "SCHEDULED")
        let updated = try await client.updateWorkitem(uid, attributes: .init(elements: [upsString(0x00741204, "NEW", .LO)]))
        XCTAssertEqual(updated.statusCode, 200)
        let claimed = try await client.changeWorkitemState(uid, to: .inProgress, transactionUID: "2.25.1")
        XCTAssertEqual(claimed.statusCode, 200)
        let subscription = try await client.subscribe(uid, subscriber: "TEST")
        XCTAssertEqual(subscription.notificationURL.absoluteString, "wss://example.test/dicom-web/subscribers/TEST")
        let found = try await client.searchWorkitems()
        XCTAssertEqual(found.workitems.count, 1)
        let cancellation = try await client.requestWorkitemCancellation(uid, requester: "TEST")
        XCTAssertEqual(cancellation.statusCode, 202)
        let removed = try await client.unsubscribe(uid, subscriber: "TEST")
        XCTAssertEqual(removed.statusCode, 200)
        _ = try await client.subscribe(DicomUnifiedProcedureStepService.globalUID, subscriber: "TEST")
        let suspended = try await client.suspendWorklistSubscription(subscriber: "TEST")
        XCTAssertEqual(suspended.statusCode, 200)
    }
}

extension DicomWebWorklistServerTests {
    func test_deletedStoreKnowledge_returns410ForRetrieveUpdateAndState() async throws {
        let server = DicomWebServer(unifiedProcedureSteps: .init(store: DeletedWorkitemStore()), notifications: .init())
        for (method, path, data) in [(DicomWebHTTPMethod.get, "/workitems/\(uid)", DicomDataSet()),
                                    (.post, "/workitems/\(uid)", .init()),
                                    (.put, "/workitems/\(uid)/state", .init(elements: [upsString(0x00741000, "IN PROGRESS"), upsString(0x00081195, "2.25.1", .UI)]))] {
            let response = try await request(server, method, path, method == .get ? nil : data)
            XCTAssertEqual(response.statusCode, 410)
            XCTAssertEqual(response.headers["X-DICOMweb-Error-Code"], DicomWebServerErrorCode.workitemDeleted.rawValue)
        }
    }
}
private struct MixedCaseWorklistTransport: DicomWebHTTPTransport {
    let server: DicomWebServer
    func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        var response = try await server.send(request)
        if let type = response.headers["Content-Type"] {
            let parts = type.split(separator: ";", maxSplits: 1)
            response.headers["Content-Type"] = parts[0].uppercased() + (parts.count > 1 ? ";" + parts[1] : "")
        }
        return response
    }
}

private final class DeletedWorkitemStore: DicomUnifiedProcedureStepDeletionReporting, Sendable {
    let store = DicomInMemoryUnifiedProcedureStepStore()
    func wasDeleted(sopInstanceUID: String) -> Bool { sopInstanceUID == "2.25.2352" }
    func transaction<T>(sopInstanceUID: String, _ body: (inout DicomUnifiedProcedureStepRecord?) throws -> T) throws -> T {
        try store.transaction(sopInstanceUID: sopInstanceUID, body)
    }
    func all() -> [DicomUnifiedProcedureStepRecord] { store.all() }
    func subscriptions(sopInstanceUID: String) -> [String: DicomUnifiedProcedureStepSubscriptionState] { store.subscriptions(sopInstanceUID: sopInstanceUID) }
    func setSubscription(sopInstanceUID: String, ae: String, state: DicomUnifiedProcedureStepSubscriptionState) { store.setSubscription(sopInstanceUID: sopInstanceUID, ae: ae, state: state) }
    func globalSubscriptions() -> [String: DicomUnifiedProcedureStepGlobalSubscription] { store.globalSubscriptions() }
    func setGlobalSubscription(ae: String, subscription: DicomUnifiedProcedureStepGlobalSubscription) { store.setGlobalSubscription(ae: ae, subscription: subscription) }
    var listStatus: (subscriptions: DicomUnifiedProcedureStepListStatus, instances: DicomUnifiedProcedureStepListStatus) { store.listStatus }
}

func webWorkitemFixture() -> DicomDataSet {
    var data = upsFixture()
    for row in DicomUnifiedProcedureStepAttribute.table where row.path.count == 1 && row.create.hasPrefix("2/2") && data[row.tag] == nil {
        let vr = DCMDictionary().vrCode(forTag: row.tag).flatMap(DicomVR.init(code:)) ?? .LO
        data.set(.init(tag: row.tag, vr: vr, value: .empty))
    }
    return data
}
