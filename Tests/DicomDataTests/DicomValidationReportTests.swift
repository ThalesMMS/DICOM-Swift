import XCTest
@testable import DicomData

final class DicomValidationReportTests: XCTestCase {
    func test_truncation_neverPassesLayersWhoseLimitMarkersWereDiscarded() {
        let layers: [DicomValidationReport.Layer] = [.attributes, .references, .codestream]
        let report = DicomValidationReport(evaluatedLayers: [.structure], diagnostics: [
            .init(code: .valueUnavailable, severity: .warning, layer: .references)
        ] + layers.map { .init(code: .evaluationLimitReached, severity: .limitation, layer: $0) })
        for limit in 0...4 {
            let bounded = report.limitingDiagnostics(to: limit)
            XCTAssertLessThanOrEqual(bounded.diagnostics.count, limit)
            XCTAssertEqual(bounded[.structure], .passed)
            for layer in layers {
                XCTAssertTrue([.incomplete, .notEvaluated].contains(bounded[layer]), "\(layer), limit \(limit)")
            }
        }
    }
}
