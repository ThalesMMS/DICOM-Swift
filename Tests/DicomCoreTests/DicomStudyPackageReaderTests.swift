import XCTest
@testable import DicomCore

final class DicomStudyPackageReaderTests: StudyPackageTestCase {
    func test_manifestSecond_rejected() throws {
        let data = Data([1])
        let url = try zip(manifest([entry("A", data: data)]), payloads: [("A", data)], first: false)
        assertError(.manifestNotFirst) { try DicomStudyPackageReader(url: url) }
    }
    func test_selectiveRead_ignoresOtherCorruptionAndVerifyListsIt() throws {
        let data = Data(repeating: 12, count: 150_000)
        let url = try zip(manifest([entry("GOOD", data: data), entry("BAD", data: data)]), payloads: [("GOOD", data), ("BAD", Data(repeating: 13, count: data.count))])
        let reader = try DicomStudyPackageReader(url: url)
        XCTAssertEqual(try reader.data(for: "GOOD"), data)
        assertError(.checksumMismatch("BAD")) { try reader.data(for: "BAD") }
        let report = try reader.verify()
        XCTAssertEqual(report.verifiedEntries, 1)
        XCTAssertEqual(report.failures.map(\.relativePath), ["BAD"])
        XCTAssertEqual(report.status, .failed)
    }
    func test_forgedManifestSize_rejectedBeforeConsumption() throws {
        let data = Data(repeating: 1, count: 150_000)
        let url = try zip(manifest([entry("A", data: data, count: 1)]), payloads: [("A", data)])
        var consumed = 0
        assertError(.sizeMismatch("A")) {
            let reader = try DicomStudyPackageReader(url: url)
            try reader.read(member: "A") { consumed += $0.count }
        }
        XCTAssertLessThanOrEqual(consumed, 1 + DicomStudyPackageReader.bufferSize)
    }
    func test_deflateExceedsForgedCentralSize_abortsStreaming() throws {
        let data = Data(repeating: 7, count: 400_000)
        let url = try zip(manifest([entry("A", data: data, count: 1)]), payloads: [("A", data)], compression: .deflate)
        var bytes = try Data(contentsOf: url)
        let signature = Data([0x50, 0x4b, 1, 2])
        let first = try XCTUnwrap(bytes.range(of: signature))
        let second = try XCTUnwrap(bytes.range(of: signature, in: first.upperBound..<bytes.count))
        bytes.replaceSubrange((second.lowerBound + 24)..<(second.lowerBound + 28), with: [1, 0, 0, 0])
        try bytes.write(to: url)
        let reader = try DicomStudyPackageReader(url: url)
        var consumed = 0
        assertError(.sizeMismatch("A")) {
            try reader.read(member: "A") { consumed += $0.count }
        }
        XCTAssertLessThanOrEqual(consumed, 1 + DicomStudyPackageReader.bufferSize)
        XCTAssertEqual(try reader.verify().failures.map(\.reason), [.sizeMismatch("A")])
    }

    func test_manifestLimit_refusedAtOpen() throws {
        let url = try zip(manifest([]), payloads: [])
        assertError(.limitExceeded(.manifestBytes)) { try DicomStudyPackageReader(url: url, limits: .init(maxManifestBytes: 2)) }
    }
    func test_truncatedArchive_corrupt() throws {
        let data = Data(repeating: 1, count: 200)
        let url = try zip(manifest([entry("A", data: data)]), payloads: [("A", data)])
        var bytes = try Data(contentsOf: url)
        bytes.removeLast(100)
        try bytes.write(to: url)
        XCTAssertThrowsError(try DicomStudyPackageReader(url: url).verify()) {
            guard case DicomStudyPackageError.corruptArchive = $0 else { return XCTFail("\($0)") }
        }
    }
    func test_verificationCancellation_propagates() throws {
        let data = Data([1])
        let reader = try DicomStudyPackageReader(url: zip(manifest([entry("A", data: data)]), payloads: [("A", data)]))
        assertError(.cancelled) { try reader.verify(isCancelled: { true }) }
    }
}
