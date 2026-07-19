import Foundation
@testable import DicomCore

final class DicomJ2KSwiftTelemetryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DicomJ2KSwiftDecodeTelemetry] = []

    var values: [DicomJ2KSwiftDecodeTelemetry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ telemetry: DicomJ2KSwiftDecodeTelemetry) {
        lock.lock()
        storage.append(telemetry)
        lock.unlock()
    }

    func waitFor(
        _ predicate: (DicomJ2KSwiftDecodeTelemetry) -> Bool
    ) async -> DicomJ2KSwiftDecodeTelemetry? {
        for _ in 0..<200 {
            if let telemetry = values.first(where: predicate) {
                return telemetry
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }
}
