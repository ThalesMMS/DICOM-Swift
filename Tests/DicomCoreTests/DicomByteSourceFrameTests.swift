import Foundation
import XCTest
@testable import DicomCore

@MainActor
final class DicomByteSourceFrameTests: XCTestCase {
    func test_selectiveNativeFrames_matchAllIndependentSamplesAndExistingMetadata() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/IndependentDifferential")
        for name in ["gray8", "gray12-signed", "gray16", "gray8-inverted", "rgb-interleaved", "rgb-planar"] {
            let url = directory.appendingPathComponent(name + ".dcm")
            let reference = try DicomDecodedFrameReader(contentsOf: url)
            for mode in [DicomByteSource.FileStorage.buffer, .mappedSnapshot] {
                let source = try await DicomByteSource.openFile(url, storage: mode)
                let metadata = try await DicomSourceMetadata.readPart10(from: source)
                let pixelRange = try XCTUnwrap(metadata.pixelDataRange)
                let before = await source.metrics
                XCTAssertFalse(before.ranges.contains { $0.overlaps(pixelRange) }, name)
                for index in 0..<3 {
                    let actual = try await DicomDecodedFrameReader.frame(at: index, from: source, metadata: metadata)
                    let expected = try await reference.frame(at: index)
                    XCTAssertEqual(actual, expected, "\(name) frame \(index)")
                }
                let after = await source.metrics
                // Six gray/color profiles have either 45 or 135 bytes, or 90 for 16-bit.
                let allocated = metadata.dataSet.int(for: .bitsAllocated) ?? 0
                let components = metadata.dataSet.int(for: .samplesPerPixel) ?? 0
                XCTAssertEqual(after.receivedBytes - before.receivedBytes, 45 * components * allocated / 8)
                XCTAssertGreaterThan(after.compatibilityCopiedBytes, 0)
                await source.close()
            }
        }
    }

    func test_metadataFromAnotherRevision_cannotAddressSourceFrames() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/IndependentDifferential/gray8.dcm")
        let source = try await DicomByteSource.openFile(url)
        let other = try await DicomByteSource.openFile(url)
        let metadata = try await DicomSourceMetadata.readPart10(from: source)
        do {
            _ = try await DicomDecodedFrameReader.frame(at: 0, from: other, metadata: metadata)
            XCTFail("Mismatched source identity was accepted")
        } catch { XCTAssertEqual(error as? DicomByteSource.Failure, .changed) }
        await source.close()
        await other.close()
    }
}
