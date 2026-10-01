import DicomCore
import Foundation
import XCTest

final class CodecWorkflowDocumentationExamplesTests: XCTestCase {
    func test_publicWorkflowExamples_compileAndExerciseSupportedOperations() async throws {
        let data = try Data(contentsOf: Self.nativeFixture)
        let engine = DicomCodecWorkflowEngine()

        let capabilityReport = engine.capabilities(environment: [:])
        let availableBackends = capabilityReport.backends.filter(\.available)
        XCTAssertFalse(availableBackends.isEmpty)
        XCTAssertFalse(try DicomCodecCanonicalRenderer.jsonString(capabilityReport).isEmpty)

        let inspection = try engine.inspect(data, environment: [:])
        XCTAssertTrue(inspection.success)
        XCTAssertFalse(DicomCodecCanonicalRenderer.text(inspection).isEmpty)

        let validation = try engine.validate(data, environment: [:])
        XCTAssertTrue(validation.success)

        let decoded = try await engine.decode(data, frameIndexes: [0], environment: [:])
        XCTAssertFalse(decoded.data.isEmpty)
        XCTAssertEqual(decoded.report.frames.map(\.index), [0])

        let transcoded = try await engine.transcode(
            data,
            to: .implicitVRLittleEndian,
            intent: .reversible,
            environment: [:],
            verifyDecodedPixels: true
        )
        XCTAssertTrue(transcoded.report.success)
        XCTAssertEqual(transcoded.report.artifact?.validationPassed, true)
        XCTAssertEqual(transcoded.report.artifact?.comparisonPassed, true)
    }

    // This mirrors the tutorial's comparison snippet. Execution needs a qualified compressed fixture and oracle
    // runtime; keeping the helper in the test target makes the public call compile without weakening that requirement.
    private func compareFirstFrame(_ compressedData: Data) async throws -> DicomCodecStructuredReport {
        try await DicomCodecWorkflowEngine().compare(compressedData, frameIndex: 0)
    }

    private static let nativeFixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/DecoderParity/ct_explicit_vr_le_rescale.dcm")
}
