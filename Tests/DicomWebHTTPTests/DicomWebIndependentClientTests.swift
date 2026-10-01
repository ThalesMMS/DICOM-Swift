import Foundation
import XCTest
import DicomCore
import DicomWebHTTP

final class DicomWebIndependentClientTests: XCTestCase {
    func test_python0612_studiesServicesAndExactStoredBytes() async throws {
        guard let interpreter = ProcessInfo.processInfo.environment["DICOM_SWIFT_PYNETDICOM_PYTHON"],
              FileManager.default.isExecutableFile(atPath: interpreter) else {
            if ProcessInfo.processInfo.environment["DICOM_REQUIRE_PYNETDICOM"] == "1" {
                XCTFail("Required independent Python interpreter absent"); return
            }
            throw XCTSkip("Set DICOM_SWIFT_PYNETDICOM_PYTHON to run the independent client.")
        }
        let store = DicomWebInMemoryStorage()
        let listener = DicomWebHTTPListener(server: .init(store: store))
        let root = try await listener.start()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("dicomweb-probe-\(UUID().uuidString).dcm")
        defer { try? FileManager.default.removeItem(at: output) }
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/interop/dicomweb_client_probe.py")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = [script.path, root.appendingPathComponent("dicom-web").absoluteString, output.path]
        process.standardOutput = pipe; process.standardError = pipe
        do {
            try process.run()
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: bytes, as: UTF8.self))
            if process.terminationStatus == 0 {
                let expected = try Data(contentsOf: output)
                XCTAssertEqual(store.allInstances().first?.part10Data, expected)
                var request = URLRequest(url: root.appendingPathComponent("dicom-web/studies/2.25.2351001/series/2.25.2351002/instances/2.25.2351003"))
                request.setValue("multipart/related; type=\"application/dicom\"; transfer-syntax=*", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                let type = try XCTUnwrap((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"))
                let parts = try DicomWebMultipartStreamParser.parts(from: data, contentType: type)
                XCTAssertEqual(parts.first?.body, expected)
            }
        } catch { await listener.stop(); throw error }
        await listener.stop()
    }
}
