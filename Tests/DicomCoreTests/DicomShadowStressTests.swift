import Foundation
import XCTest
@testable import DicomCore

final class DicomShadowStressTests: XCTestCase {
    func test_localCompressedFrames_shadowPreservesProductionPixelsDuringSessionChurn() async throws {
        guard let manifest = ProcessInfo.processInfo.environment["DICOM_SHADOW_STRESS_MANIFEST"] else {
            throw XCTSkip("Set DICOM_SHADOW_STRESS_MANIFEST to a local JSON array of compressed DICOM paths")
        }
        let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        XCTAssertFalse(paths.isEmpty)
        let urls = paths.prefix(4).map { URL(fileURLWithPath: $0) }
        let disabled = ["DICOM_J2KSWIFT_MODE": "disabled", "DICOM_JLSWIFT_MODE": "disabled"]
        var references: [Data] = []
        for url in urls {
            let reader = try DicomDecodedFrameReader(contentsOf: url)
            references.append(try await reader.dataBackedFrame(at: 0, environment: disabled).pixels.data)
        }
        let baseline = try await run(urls: urls, references: references, environment: disabled)
        let before = await DicomShadowDecodeStatistics.current()
        let shadow = try await run(urls: urls, references: references, environment: [
            "DICOM_J2KSWIFT_MODE": "shadow", "DICOM_JLSWIFT_MODE": "shadow",
            "DICOM_SHADOW_SAMPLE_EVERY": "1"
        ])
        let after = await DicomShadowDecodeStatistics.current()
        XCTAssertEqual(after.running, 0)
        XCTAssertEqual(after.queued, 0)
        XCTAssertEqual(after.retainedPayloadBytes, 0)
        XCTAssertGreaterThan(after.completed + after.dropped, before.completed + before.dropped,
                             "Fixture must exercise shadow admission")
        XCTAssertGreaterThan(after.matched + after.mismatched + after.failed,
                             before.matched + before.mismatched + before.failed,
                             "Sustained batch must record a comparison or an explicit candidate failure")
        print(String(format:
            "SHADOW_STRESS frames=%d off_p95_ms=%.3f on_p95_ms=%.3f completed=%d dropped=%d max_queue_wait_ms=%.3f",
            shadow.count, percentile(baseline), percentile(shadow),
            after.completed - before.completed, after.dropped - before.dropped,
            Double(after.maximumQueueWaitNanoseconds) / 1_000_000))
        print("SHADOW_OUTCOMES matched=\(after.matched - before.matched) "
              + "mismatched=\(after.mismatched - before.mismatched) failed=\(after.failed - before.failed) "
              + "cancelled=\(after.cancelled - before.cancelled)")
    }

    private func run(urls: [URL], references: [Data], environment: [String: String]) async throws -> [Double] {
        var durations: [Double] = []
        for roundIndex in 0..<4 {
            let session = DicomShadowSession()
            let context = DicomDecodeWorkContext(memory: nil, shadowSession: session)
            do {
                let round = try await DicomDecodeWorkContext.$current.withValue(context) {
                    try await withThrowingTaskGroup(of: Double.self) { group in
                        for index in urls.indices {
                            let url = urls[index]
                            let reference = references[index]
                            group.addTask {
                                let start = DispatchTime.now().uptimeNanoseconds
                                let reader = try DicomDecodedFrameReader(contentsOf: url)
                                let frame = try await reader.dataBackedFrame(at: 0, environment: environment)
                                XCTAssertEqual(frame.pixels.data, reference, "Production pixels changed under shadow load")
                                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                            }
                        }
                        var round: [Double] = []
                        for try await duration in group { round.append(duration) }
                        return round
                    }
                }
                durations.append(contentsOf: round)
            } catch {
                await DicomShadowExecutor.shared.cancel(session: session)
                await DicomShadowExecutor.shared.drain(session: session)
                throw error
            }
            if roundIndex == 3 { await DicomShadowExecutor.shared.drain(session: session) }
            await DicomShadowExecutor.shared.cancel(session: session)
            await DicomShadowExecutor.shared.drain(session: session)
        }
        return durations
    }

    private func percentile(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }
}
