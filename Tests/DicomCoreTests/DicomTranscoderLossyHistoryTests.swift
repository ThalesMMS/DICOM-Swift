import XCTest
@testable import DicomCore

final class DicomTranscoderLossyHistoryTests: XCTestCase {
    func test_existingHistory_streamingAppendsAndMatchesInMemory() async throws {
        try await assertLossyHistory(priorRatios: ["4.0"], priorMethods: ["ISO_10918_1"])
    }

    func test_multiplePriorValues_streamingPreservesHistoryAndMatchesInMemory() async throws {
        try await assertLossyHistory(priorRatios: ["4.0", "2.50"], priorMethods: ["ISO_10918_1", "ISO_15444_1"])
    }

    func test_noHistory_streamingWritesSingleValuesAndMatchesInMemory() async throws {
        try await assertLossyHistory(priorRatios: [], priorMethods: [])
    }

    private func assertLossyHistory(priorRatios: [String], priorMethods: [String]) async throws {
        var source = RepresentationFixture.dataSet()
        if !priorRatios.isEmpty {
            source.set(.init(tag: 0x00282110, vr: .CS, value: .strings(["01"])))
            source.set(.init(tag: 0x00282112, vr: .DS, value: .strings(priorRatios)))
            source.set(.init(tag: 0x00282114, vr: .CS, value: .strings(priorMethods)))
        }
        let bytes = try DicomDataSetWriter.part10Data(from: source)
        let transcoder = DicomTranscoder()
        let intent = DicomEncodingIntent.irreversible(quality: 0.8)
        let plan = try transcoder.plan(bytes, to: .jpegBaseline, intent: intent)
        XCTAssertTrue(plan.isStreamable)
        XCTAssertEqual(plan.kind, .encode)
        let result = try await transcoder.execute(plan, source: bytes)
        let streamed = try DCMDecoder(data: XCTUnwrap(result.data)).dataSet
        let bufferedBytes = try await transcoder.transcode(bytes, to: .jpegBaseline, intent: intent)
        let buffered = try DCMDecoder(data: bufferedBytes).dataSet
        let ratios = streamed.strings(for: 0x00282112)
        let methods = streamed.strings(for: 0x00282114)
        XCTAssertEqual(streamed.string(for: 0x00282110), "01")
        XCTAssertEqual(ratios.count, priorRatios.count + 1)
        XCTAssertEqual(Array(ratios.prefix(priorRatios.count)), priorRatios)
        XCTAssertEqual(methods, priorMethods + ["ISO_10918_1"])
        XCTAssertEqual(ratios.count, methods.count)
        XCTAssertGreaterThan(try XCTUnwrap(Double(try XCTUnwrap(ratios.last))), 0)
        XCTAssertEqual(ratios, buffered.strings(for: 0x00282112))
        XCTAssertEqual(methods, buffered.strings(for: 0x00282114))
    }
}
