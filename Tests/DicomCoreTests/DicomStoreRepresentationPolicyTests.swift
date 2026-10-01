import XCTest
@testable import DicomCore

final class DicomStoreRepresentationPolicyTests: XCTestCase {
    func test_originalAccepted_preservesStoredSyntax() throws {
        XCTAssertEqual(try DicomStoreRepresentationPolicy.lossless.select(
            stored: .rleLossless, qualified: [.explicitVRLittleEndian],
            accepted: [.explicitVRLittleEndian, .rleLossless]), .rleLossless)
    }

    func test_unqualifiedOrLossyAlternative_refuses() {
        XCTAssertThrowsError(try DicomStoreRepresentationPolicy.lossless.select(
            stored: .rleLossless, qualified: [.jpegBaseline], accepted: [.jpegBaseline]))
        XCTAssertThrowsError(try DicomStoreRepresentationPolicy.asReceived.select(
            stored: .rleLossless, qualified: [.explicitVRLittleEndian], accepted: [.explicitVRLittleEndian]))
    }

    func test_qualifiedAlternative_selectsOne() throws {
        XCTAssertEqual(try DicomStoreRepresentationPolicy.lossless.select(
            stored: .rleLossless, qualified: [.explicitVRLittleEndian, .jpeg2000Lossless],
            accepted: [.jpeg2000Lossless]), .jpeg2000Lossless)
    }

    func test_errorInMiddle_continuesUnlessCancelledAndCountsOnlyAcceptedObjects() async throws {
        struct LocalFailure: Error {}
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try (1...3).map { index in
            let file = directory.appendingPathComponent("\(index).dcm")
            let data = DicomDataSet(elements: [
                .init(tag: 0x00080016, vr: .UI, value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
                .init(tag: 0x00080018, vr: .UI, value: .strings(["2.25.2350\(index)"]))
            ])
            try DicomDataSetWriter.part10Data(from: data).write(to: file)
            return file
        }
        var sends = 0
        let results = await DicomDIMSEServiceSCU.store(batch: files, policy: .asReceived) { _ in
            sends += 1
            if sends == 2 { throw LocalFailure() }
            return .init(status: 0)
        }
        XCTAssertEqual(sends, 3)
        XCTAssertEqual(results.map(\.accepted), [true, false, true])
        XCTAssertEqual(results.count, 3)
        guard case .failure(let error) = results[1].result else { return XCTFail("Missing object failure") }
        XCTAssertTrue(error is LocalFailure)
        sends = 0
        let cancelled = await DicomDIMSEServiceSCU.store(batch: files, policy: .asReceived) { _ in
            sends += 1
            if sends == 2 { throw CancellationError() }
            return .init(status: 0)
        }
        XCTAssertEqual(sends, 2)
        XCTAssertEqual(cancelled.map(\.accepted), [true, false])
        guard case .failure(let cancellation) = cancelled.last?.result else { return XCTFail("Missing cancellation") }
        XCTAssertTrue(cancellation is CancellationError)
    }

    func test_unreadableObjects_everyInputHasOutcome() async {
        let urls = (0..<3).map { URL(fileURLWithPath: "/nonexistent/\($0).dcm") }
        let results = await DicomDIMSEServiceSCU.store(batch: urls, policy: .asReceived) { _ in
            XCTFail("Unreadable input must not be sent")
            return .init(status: 0)
        }
        XCTAssertEqual(results.count, urls.count)
        XCTAssertEqual(results.filter(\.accepted).count, 0)
    }
}
