import Foundation
import XCTest
@testable import DicomCore

final class DicomSRTemplateValidatorStackTests: XCTestCase {
    private struct Snapshot: Equatable, Sendable {
        let root: DicomSRContentItem
        let built: DicomSRTemplateValidationResult
        let fixture: DicomSRTemplateValidationResult
    }

    @inline(never)
    private static func snapshot() throws -> Snapshot {
        let document = try DicomSRMeasurementReportBuilder.build(DicomSRMeasurementReportBuilderTests.fullReport())
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/StructuredReports/sr_tid1500_roi_measurement_report.dcm")
        let decoder = try DCMDecoder(data: Data(contentsOf: url))
        let fixture = try XCTUnwrap(decoder.structuredReport)
        return Snapshot(root: document.root, built: DicomSRTemplateValidator.validate(document),
            fixture: DicomSRTemplateValidator.validate(fixture))
    }

    private static func snapshot(stackSize: Int) async throws -> Snapshot {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result { try snapshot() })
            }
            thread.stackSize = stackSize
            thread.start()
        }
    }

    func test_fullReportAndFixture_on512KBStackAndDetachedTask_matchLargeStack() async throws {
        let baseline = try await Self.snapshot(stackSize: 8 * 1024 * 1024)
        let smallStack = try await Self.snapshot(stackSize: 512 * 1024)
        let cooperative = try await Task.detached { try DicomSRTemplateValidatorStackTests.snapshot() }.value
        XCTAssertTrue(baseline.built.errors.isEmpty)
        XCTAssertTrue(baseline.fixture.errors.isEmpty)
        XCTAssertEqual(smallStack, baseline)
        XCTAssertEqual(cooperative, baseline)
    }
}
