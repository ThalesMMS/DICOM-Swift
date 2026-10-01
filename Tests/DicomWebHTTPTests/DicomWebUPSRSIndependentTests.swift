import Foundation
import XCTest
import DicomCore
import DicomWebHTTP

final class DicomWebUPSRSIndependentTests: XCTestCase {
    func test_requestsAndWebsockets_allTransactionsEventsAndDisconnectedGap() async throws {
        guard let interpreter = ProcessInfo.processInfo.environment["DICOM_SWIFT_PYNETDICOM_PYTHON"],
              FileManager.default.isExecutableFile(atPath: interpreter) else {
            if ProcessInfo.processInfo.environment["DICOM_REQUIRE_PYNETDICOM"] == "1" {
                XCTFail("Required independent Python interpreter absent"); return
            }
            throw XCTSkip("Independent Python interpreter absent")
        }
        let observer = UPSRSObserver()
        let service = DicomUnifiedProcedureStepService(store: DicomInMemoryUnifiedProcedureStepStore(), observer: observer)
        let listener = DicomWebHTTPListener(server: .init(unifiedProcedureSteps: service, notifications: .init()))
        let root = try await listener.start()
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/interop/ups_rs_probe.py")
        do {
            let result = try await Task.detached {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: interpreter)
                process.arguments = [script.path, root.appendingPathComponent("dicom-web").absoluteString]
                process.standardOutput = pipe; process.standardError = pipe
                try process.run()
                let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, bytes)
            }.value
            XCTAssertEqual(result.0, 0, String(decoding: result.1, as: UTF8.self))
            if result.0 == 0 {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result.1) as? [String: Any])
                XCTAssertEqual(json["events"] as? [String], ["SCHEDULED", "IN PROGRESS", "progress", "COMPLETED"])
                XCTAssertEqual(json["fresh_state"] as? String, "IN PROGRESS")
                XCTAssertEqual(json["websockets"] as? String, "17.1")
                XCTAssertEqual(json["gap"] as? Bool, true)
                let statuses = try XCTUnwrap(json["statuses"] as? [String: Int])
                XCTAssertEqual(statuses["create"], 201); XCTAssertEqual(statuses["claim"], 200)
                XCTAssertEqual(statuses["cancelrequest"], 202); XCTAssertEqual(statuses["unsubscribe"], 200)
                XCTAssertGreaterThanOrEqual(statuses.count, 25)
                let gaps = await observer.disconnected
                XCTAssertGreaterThanOrEqual(gaps, 2)
            }
        } catch { await listener.stop(); throw error }
        await listener.stop()
    }
}
private actor UPSRSObserver: DicomUnifiedProcedureStepEventObserving {
    var disconnected = 0
    func attempted(event: DicomUnifiedProcedureStepEvent, receivingAE: String,
                   outcome: DicomUnifiedProcedureStepDeliveryOutcome, status: UInt16?, errorDescription: String?) {
        if errorDescription?.contains("noConnection") == true { disconnected += 1 }
    }
}
