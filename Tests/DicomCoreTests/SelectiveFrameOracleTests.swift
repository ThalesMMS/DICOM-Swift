import CryptoKit
import Foundation
import XCTest
@testable import DicomCore

@MainActor
final class SelectiveFrameOracleTests: XCTestCase {
    private struct Manifest: Decodable {
        let fixtures: [Fixture]
    }

    private struct Fixture: Decodable {
        let id: String
        let path: String
        let sha256: String
        let bitsAllocated: Int
        let kind: String
        let pixelDataTag: Int
        let rows: Int
        let columns: Int
        let frames: Int
        let transferSyntaxUID: String
        let samples: [[String]]
    }

    func test_pydicomCorpus_everySampleAndFrameIdentitySurvivesSelectiveReads() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SelectiveFrames")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.fixtures.count, 9)
        for fixture in manifest.fixtures {
            let url = directory.appendingPathComponent(fixture.path)
            let original = try Data(contentsOf: url)
            XCTAssertEqual(SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined(), fixture.sha256)
            for mode in [DicomByteSource.FileStorage.buffer, .mappedSnapshot] {
                let source = try await DicomByteSource.openFile(url, storage: mode)
                let session = try await DicomSourceFrameSession.open(source: source)
                let index = session.index
                XCTAssertEqual(index.metadata.pixelDataTag, fixture.pixelDataTag)
                XCTAssertEqual(index.metadata.transferSyntax.rawValue, fixture.transferSyntaxUID)
                XCTAssertEqual(index.frameCount, fixture.frames)
                XCTAssertEqual(index.metadata.dataSet.int(for: .rows), fixture.rows)
                XCTAssertEqual(index.metadata.dataSet.int(for: .columns), fixture.columns)
                for frame in [2, 0, 1] {
                    let bytes = try await session.frameData(at: frame)
                    let bitOffset = try index.packedBitOffset(forFrame: frame)
                    let actual = try samples(bytes, fixture: fixture, packedBitOffset: bitOffset)
                    XCTAssertEqual(actual, fixture.samples[frame], "\(fixture.id), frame \(frame), \(mode)")
                }
                let metrics = await session.metrics
                XCTAssertEqual(metrics.retainedCompletedBytes, 0)
                XCTAssertEqual(metrics.inFlightReservedBytes, 0)
                await session.close()
            }
        }
    }

    func test_selectedCompatibilityArtifacts_preservePackedAndWideNativeSamples() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SelectiveFrames")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        for fixture in manifest.fixtures {
            let source = try await DicomByteSource.openFile(directory.appendingPathComponent(fixture.path))
            let session = try await DicomSourceFrameSession.open(source: source)
            for frame in [2, 0, 1] {
                let artifact = try await session.part10Data(at: frame)
                let artifactSource = DicomByteSource(data: artifact)
                let selected = try await DicomSourceFrameSession.open(source: artifactSource)
                XCTAssertEqual(selected.index.frameCount, 1)
                XCTAssertEqual(selected.index.metadata.pixelDataTag, fixture.pixelDataTag)
                let raw = try await selected.frameData(at: 0)
                XCTAssertEqual(try samples(raw, fixture: fixture, packedBitOffset: 0), fixture.samples[frame])
                await selected.close()
            }
            if fixture.bitsAllocated <= 16 && fixture.kind != "jpeg" {
                let reference = try DicomDecodedFrameReader(contentsOf: directory.appendingPathComponent(fixture.path))
                for frame in [2, 0, 1] {
                    let actual = try await session.dataBackedFrame(at: frame)
                    let expected = try await reference.dataBackedFrame(at: frame)
                    XCTAssertEqual(actual, expected, "\(fixture.id), frame \(frame)")
                }
            } else if fixture.kind == "jpeg" {
                for frame in [2, 0, 1] {
                    let actual = try await session.dataBackedFrame(at: frame)
                    XCTAssertEqual(actual.index, frame)
                    XCTAssertEqual(actual.metadata.frameCount, 3)
                    XCTAssertEqual(Array(actual.pixels.data).map(String.init), fixture.samples[frame])
                }
            } else {
                do { _ = try await session.dataBackedFrame(at: 0); XCTFail("Wide display decode silently narrowed") }
                catch { guard case DicomSourceFrameIndex.Failure.unsupportedLayout = error else { return XCTFail("\(error)") } }
            }
            await session.close()
        }
    }

    func test_decoderCompatibilityArtifacts_preserveNativeStoredSamples() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SelectiveFrames")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        let nativeSyntaxes = [DicomTransferSyntax.implicitVRLittleEndian, .explicitVRLittleEndian, .explicitVRBigEndian]
            .map(\.rawValue)
        for fixture in manifest.fixtures where nativeSyntaxes.contains(fixture.transferSyntaxUID) {
            let decoder = try DCMDecoder(data: Data(contentsOf: directory.appendingPathComponent(fixture.path)))
            for frame in [2, 0, 1] {
                let artifact = try decoder.singleFramePart10Data(at: frame)
                let selected = try await DicomSourceFrameSession.open(source: DicomByteSource(data: artifact))
                XCTAssertEqual(selected.index.frameCount, 1, fixture.id)
                XCTAssertEqual(selected.index.metadata.pixelDataTag, fixture.pixelDataTag, fixture.id)
                let raw = try await selected.frameData(at: 0)
                XCTAssertEqual(try samples(raw, fixture: fixture, packedBitOffset: 0), fixture.samples[frame],
                               "\(fixture.id), frame \(frame)")
                await selected.close()
            }
        }
    }

    private func samples(_ bytes: Data, fixture: Fixture, packedBitOffset: Int) throws -> [String] {
        let count = fixture.rows * fixture.columns
        if fixture.kind == "jpeg" {
            let decoded = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
                data: bytes, transferSyntax: .jpegBaseline, width: fixture.columns, height: fixture.rows,
                bitDepth: 8, samplesPerPixel: 1, bitsStored: 8
            ))
            return try XCTUnwrap(decoded.pixels8).map(String.init)
        }
        if fixture.id == "rle8" {
            let decoded = try DicomRLELosslessDecoder.decode(frame: bytes, width: fixture.columns, height: fixture.rows,
                                                            bitsAllocated: 8, samplesPerPixel: 1, pixelRepresentation: 0,
                                                            photometricInterpretation: "MONOCHROME2")
            return try XCTUnwrap(decoded.pixels8).map(String.init)
        }
        if fixture.kind == "bits" {
            return (0..<count).map { index in
                let bit = packedBitOffset + index
                return String((bytes[bytes.startIndex + bit / 8] >> (bit % 8)) & 1)
            }
        }
        let little = fixture.transferSyntaxUID != DicomTransferSyntax.explicitVRBigEndian.rawValue
        return try (0..<count).map { index in
            let offset = index * fixture.bitsAllocated / 8
            switch (fixture.kind, fixture.bitsAllocated) {
            case ("float", 32):
                let bits = try XCTUnwrap(bytes.dicomIntegerIfPresent(at: offset, as: UInt32.self, littleEndian: little))
                return String(Float(bitPattern: bits))
            case ("float", 64):
                let bits = try XCTUnwrap(bytes.dicomIntegerIfPresent(at: offset, as: UInt64.self, littleEndian: little))
                return String(Double(bitPattern: bits))
            case ("signed", 32):
                return String(try XCTUnwrap(bytes.dicomIntegerIfPresent(at: offset, as: Int32.self, littleEndian: little)))
            case (_, 16):
                return String(try XCTUnwrap(bytes.dicomIntegerIfPresent(at: offset, as: UInt16.self, littleEndian: little)))
            case (_, 32):
                return String(try XCTUnwrap(bytes.dicomIntegerIfPresent(at: offset, as: UInt32.self, littleEndian: little)))
            case (_, 64):
                return String(try XCTUnwrap(bytes.dicomIntegerIfPresent(at: offset, as: UInt64.self, littleEndian: little)))
            default:
                XCTFail("Missing sample oracle binding for \(fixture.id)")
                throw DicomSourceFrameIndex.Failure.unsupportedLayout(fixture.id)
            }
        }
    }
}
