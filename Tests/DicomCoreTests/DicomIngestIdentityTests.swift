import Foundation
import XCTest
@testable import DicomCore

final class DicomIngestIdentityTests: XCTestCase {
    func test_unreadableDatasetIdentity_isRejectedBeforeStagingOrRegistration() async throws {
        for tag in [DicomTag.sopClassUID, .sopInstanceUID] {
            let fixture = try IngestFixture()
            defer { fixture.clean() }
            let set = ingestDataSet().setting(.init(tag: tag.rawValue, vr: .UN, value: .bytes(Data())))
            let bytes = try part10Data(set)
            let request = try DicomStoreRequest(part10Data: bytes)
            let parsed = try DicomDataSetParser.dataSet(
                from: request.dataSetData, transferSyntax: request.transferSyntax)
            XCTAssertTrue(parsed.contains(tag))
            XCTAssertNil(parsed.string(for: tag))

            do {
                _ = try await fixture.coordinator.ingest(part10Data: bytes)
                XCTFail("An unreadable \(tag) must not inherit the file-meta identity")
            } catch {
                XCTAssertEqual(error as? DicomIngestError, .invalidIdentity)
            }
            let records = try await fixture.registrar.records()
            let entries = try await fixture.journal.entries()
            XCTAssertTrue(records.isEmpty)
            XCTAssertEqual(entries.last?.stage, .validated)
            XCTAssertEqual(entries.last?.phase, .intent)
            XCTAssertFalse(FileManager.default.fileExists(atPath: entries[0].temporaryPath.path))
        }
    }

    /// An explicit UN on a public tag is read back through the dictionary's VR (issue #2835): its identity is the
    /// dataset's own, checked against the file meta like any other.
    func test_datasetIdentityWrittenAsUN_isReadBackAndCheckedAgainstFileMeta() async throws {
        for tag in [DicomTag.sopClassUID, .sopInstanceUID] {
            let matchingUID = try XCTUnwrap(ingestDataSet().string(for: tag))
            for (value, accepted) in [("2.25.999", false), (matchingUID, true)] {
                let fixture = try IngestFixture()
                defer { fixture.clean() }
                let set = ingestDataSet().setting(.init(tag: tag.rawValue, vr: .UN, value: .bytes(Data(value.utf8))))
                let bytes = try part10Data(set)
                let request = try DicomStoreRequest(part10Data: bytes)
                let parsed = try DicomDataSetParser.dataSet(
                    from: request.dataSetData, transferSyntax: request.transferSyntax)
                XCTAssertEqual(parsed.string(for: tag), value)

                do {
                    _ = try await fixture.coordinator.ingest(part10Data: bytes)
                    XCTAssertTrue(accepted, "\(tag) \(value) differs from the file meta")
                } catch {
                    XCTAssertFalse(accepted, "\(tag) \(value): \(error)")
                    XCTAssertEqual(error as? DicomIngestError, .invalidIdentity)
                }
                let records = try await fixture.registrar.records()
                XCTAssertEqual(records.count, accepted ? 1 : 0, "\(tag) \(value)")
            }
        }
    }

    func test_absentDatasetIdentity_usesFileMetaIdentity() throws {
        let missingTags: [[DicomTag]] = [[.sopClassUID], [.sopInstanceUID], [.sopClassUID, .sopInstanceUID]]
        for tags in missingTags {
            var set = ingestDataSet()
            for tag in tags { set.remove(tag) }
            let request = try dicomIngestValidatedRequest(part10Data(set))
            XCTAssertEqual(request.sopClassUID, DicomStorageSOPClassUIDs.secondaryCaptureImageStorage)
            XCTAssertEqual(request.sopInstanceUID, "2.25.2356001")
        }
    }

    func test_readableDatasetIdentity_mustMatchFileMeta() throws {
        XCTAssertNoThrow(try dicomIngestValidatedRequest(part10Data(ingestDataSet())))
        for tag in [DicomTag.sopClassUID, .sopInstanceUID] {
            let set = ingestDataSet().setting(.init(tag: tag.rawValue, vr: .UI, value: .strings(["2.25.999"])))
            XCTAssertThrowsError(try dicomIngestValidatedRequest(part10Data(set))) { error in
                XCTAssertEqual(error as? DicomIngestError, .invalidIdentity)
            }
        }
    }

    private func part10Data(_ set: DicomDataSet) throws -> Data {
        try DicomDataSetWriter.part10Data(from: set, options: .init(
            transferSyntax: .explicitVRLittleEndian,
            mediaStorageSOPClassUID: DicomStorageSOPClassUIDs.secondaryCaptureImageStorage,
            mediaStorageSOPInstanceUID: "2.25.2356001"))
    }
}
