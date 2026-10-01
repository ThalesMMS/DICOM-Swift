@testable import DicomCore
import DicomTestSupport
import Foundation
import simd
import XCTest
import ZIPFoundation

final class DicomDecodedSeriesTests: XCTestCase {
    func testLoadDecodedSeriesConvertsUnsignedPixelsAndPreservesWindowMetadata() throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomDecodedSeriesUnsigned")
        defer { try? FileManager.default.removeItem(at: directory) }
        try createFiles(in: directory, count: 2)

        let loader = DicomSeriesLoader(decoderFactory: { path in
            let decoder = MockDecoderBuilder.makeDecoder(
                width: 2,
                height: 2,
                pixelValue: 100,
                position: path.contains("slice_1") ? SIMD3<Double>(0, 0, 1) : .zero,
                modality: "CT"
            )
            decoder.setTag(DicomTag.rescaleSlope.rawValue, value: "2")
            decoder.setTag(DicomTag.rescaleIntercept.rawValue, value: "-10")
            decoder.setTag(DicomTag.windowCenter.rawValue, value: "40")
            decoder.setTag(DicomTag.windowWidth.rawValue, value: "400")
            decoder.setTag(DicomTag.studyDescription.rawValue, value: "CT Chest")
            decoder.setTag(DicomTag.studyInstanceUID.rawValue, value: "1.2.3")
            decoder.setTag(DicomTag.seriesInstanceUID.rawValue, value: "1.2.3.4")
            decoder.setTag(0x0020_0052, value: "1.2.3.4.5")
            return decoder
        })

        let decoded = try loader.loadDecodedSeries(from: directory)

        XCTAssertEqual(decoded.sourcePixelRepresentation, .unsignedInt16)
        XCTAssertEqual(decoded.dimensions, DicomSeriesDimensions(width: 2, height: 2, depth: 2))
        XCTAssertEqual(decoded.modalityIntensityRange, 190...190)
        XCTAssertEqual(decoded.recommendedWindow, -160...239)
        XCTAssertEqual(decoded.studyDescription, "CT Chest")
        XCTAssertEqual(decoded.studyInstanceUID, "1.2.3")
        XCTAssertEqual(decoded.seriesInstanceUID, "1.2.3.4")
        XCTAssertEqual(decoded.frameOfReferenceUID, "1.2.3.4.5")
        XCTAssertEqual(int16Values(in: decoded.modalityVoxels), Array(repeating: Int16(190), count: 8))
        XCTAssertEqual(uint16Values(in: decoded.rawVoxels), Array(repeating: UInt16(100), count: 8))
    }

    func testLoadDecodedSeriesConvertsSignedPixels() throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomDecodedSeriesSigned")
        defer { try? FileManager.default.removeItem(at: directory) }
        try createFiles(in: directory, count: 1)

        let loader = DicomSeriesLoader(decoderFactory: { _ in
            let decoder = MockDecoderBuilder.makeDecoder(width: 2, height: 2, pixelValue: 32_768)
            decoder.setTag(DicomTag.pixelRepresentation.rawValue, value: "1")
            decoder.pixelRepresentationTagValue = 1
            decoder.setTag(DicomTag.rescaleIntercept.rawValue, value: "-1024")
            return decoder
        })

        let decoded = try loader.loadDecodedSeries(from: directory)

        XCTAssertEqual(decoded.sourcePixelRepresentation, .signedInt16)
        XCTAssertEqual(int16Values(in: decoded.rawVoxels), Array(repeating: Int16(0), count: 4))
        XCTAssertEqual(int16Values(in: decoded.modalityVoxels), Array(repeating: Int16(-1024), count: 4))
        XCTAssertEqual(decoded.modalityIntensityRange, -1024 ... -1024)
    }

    func testLoadDecodedSeriesDoesNotUseCTClampAndSaturatesToInt16() throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomDecodedSeriesSaturation")
        defer { try? FileManager.default.removeItem(at: directory) }
        try createFiles(in: directory, count: 1)

        let loader = DicomSeriesLoader(decoderFactory: { _ in
            let decoder = MockDecoderBuilder.makeDecoder(width: 2, height: 1, pixelValue: 0, modality: "CT")
            decoder.setPixels16([5_000, UInt16.max])
            return decoder
        })

        let decoded = try loader.loadDecodedSeries(from: directory)

        XCTAssertEqual(int16Values(in: decoded.modalityVoxels), [5_000, Int16.max])
        XCTAssertEqual(decoded.modalityIntensityRange, 5_000 ... Int32(Int16.max))
    }

    func testLoadDecodedSeriesUsesParentDirectoryForFileSource() throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomDecodedSeriesFile")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try createFiles(in: directory, count: 2)

        let loader = DicomSeriesLoader(
            decoderFactory: MockDecoderBuilder.makePathFactory(
                width: 1,
                height: 1,
                pixelValue: 7,
                positionProvider: { path in
                    path.contains("slice_1") ? SIMD3<Double>(0, 0, 1) : .zero
                }
            )
        )

        let decoded = try loader.loadDecodedSeries(from: files[0])

        XCTAssertEqual(decoded.dimensions.depth, 2)
        XCTAssertEqual(int16Values(in: decoded.modalityVoxels), [7, 7])
    }

    func testLoadDecodedSeriesUsesIPPDeltaForZSpacingWhenSliceThicknessDiffers() throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomDecodedSeriesIPPSpacing")
        defer { try? FileManager.default.removeItem(at: directory) }
        try createFiles(in: directory, count: 3)

        let loader = DicomSeriesLoader(
            decoderFactory: MockDecoderBuilder.makePathFactory(
                width: 1,
                height: 1,
                pixelValue: 7,
                pixelSpacing: SIMD3<Double>(1, 1, 2),
                positionProvider: { path in
                    if path.contains("slice_2") { return SIMD3<Double>(0, 0, 2) }
                    if path.contains("slice_1") { return SIMD3<Double>(0, 0, 1) }
                    return .zero
                }
            )
        )

        let decoded = try loader.loadDecodedSeries(from: directory)

        XCTAssertEqual(decoded.spacing.x, 1.0)
        XCTAssertEqual(decoded.spacing.y, 1.0)
        XCTAssertEqual(decoded.spacing.z, 1.0, accuracy: 1e-6)
    }

    func testLoadDecodedSeriesExtractsZipAndCleansTemporaryDirectory() throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomDecodedSeriesZip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let zipURL = directory.appendingPathComponent("series.zip")
        try makeZip(at: zipURL, entries: ["series/slice_0.dcm": Data("slice".utf8)])

        let decodedURL = DicomTestLockedValue<URL?>(nil)
        let loader = DicomSeriesLoader(decoderFactory: { path in
            decodedURL.replace(with: URL(fileURLWithPath: path))
            return MockDecoderBuilder.makeDecoder(width: 1, height: 1, pixelValue: 11)
        })

        let decoded = try loader.loadDecodedSeries(from: zipURL)

        XCTAssertEqual(int16Values(in: decoded.modalityVoxels), [11])
        let extractedRoot = try XCTUnwrap(decodedURL.value)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: extractedRoot.path))
    }

    func testLoadDecodedSeriesRejectsZipPathTraversal() throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomDecodedSeriesTraversal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let zipURL = directory.appendingPathComponent("malicious.zip")
        try makeZip(at: zipURL, entries: ["../evil.dcm": Data("evil".utf8)])

        let loader = DicomSeriesLoader(decoderFactory: { _ in
            XCTFail("Path traversal archives must be rejected before decoding")
            return MockDecoderBuilder.makeDecoder()
        })

        XCTAssertThrowsError(try loader.loadDecodedSeries(from: zipURL)) { error in
            guard case DicomSeriesSourceError.pathTraversal = error else {
                XCTFail("Expected pathTraversal, got \(error)")
                return
            }
        }
    }

    func testLoadDecodedSeriesUsesFallbackWindowForMR() throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomDecodedSeriesMR")
        defer { try? FileManager.default.removeItem(at: directory) }
        try createFiles(in: directory, count: 1)

        let loader = DicomSeriesLoader(decoderFactory: { _ in
            MockDecoderBuilder.makeDecoder(width: 1, height: 1, pixelValue: 42, modality: "MR")
        })

        let decoded = try loader.loadDecodedSeries(from: directory)

        XCTAssertEqual(decoded.recommendedWindow, 42...42)
        XCTAssertEqual(decoded.warnings.map(\.code), [.usedFallbackWindow])
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func createFiles(in directory: URL, count: Int) throws -> [URL] {
        try (0..<count).map { index in
            let url = directory.appendingPathComponent("slice_\(index).dcm")
            try Data("slice-\(index)".utf8).write(to: url)
            return url
        }
    }

    private func makeZip(at url: URL, entries: [String: Data]) throws {
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        for (path, data) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }

    private func int16Values(in data: Data) -> [Int16] {
        data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Int16.self))
        }
    }

    private func uint16Values(in data: Data) -> [UInt16] {
        data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: UInt16.self))
        }
    }
}
