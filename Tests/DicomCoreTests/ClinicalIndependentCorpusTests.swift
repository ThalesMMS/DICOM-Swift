import CryptoKit
import Foundation
import XCTest
@testable import DicomCore

final class ClinicalIndependentCorpusTests: XCTestCase {
    func test_independentFixtures_compareEveryFrameComponentAndGeometry() throws {
        for fixture in try manifest().fixtures {
            let url = Self.corpus.appendingPathComponent(fixture.path)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), fixture.sha256)
            let decoder = try DCMDecoder(contentsOf: url)
            let reader = try DicomDecodedFrameReader(contentsOf: url)
            XCTAssertEqual(reader.frameCount, fixture.frames, fixture.id)
            XCTAssertEqual(decoder.width, fixture.columns, fixture.id)
            XCTAssertEqual(decoder.height, fixture.rows, fixture.id)
            XCTAssertEqual(decoder.dataSet.decimalStrings(for: .pixelSpacing), [0.7, 1.3], fixture.id)
            XCTAssertEqual(decoder.dataSet.decimalStrings(for: .imagePositionPatient), [-3.5, 4.25, 6.75], fixture.id)
            XCTAssertEqual(decoder.dataSet.decimalStrings(for: .imageOrientationPatient), [1, 0, 0, 0, 1, 0], fixture.id)
            XCTAssertEqual(decoder.dataSet.string(for: .studyDescription), "Sintético Δ — nenhum paciente real", fixture.id)
            let actual = try samples(reader)
            let comparison = ClinicalDifferentialComparison.compare(
                expected: fixture.displaySamples, actual: actual, columns: fixture.columns, components: fixture.components
            )
            XCTAssertEqual(comparison.result, "passed", "\(fixture.id): \(String(describing: comparison.firstDifference))")
            XCTAssertEqual(comparison.samplesCompared, fixture.frames * fixture.rows * fixture.columns * fixture.components)
            XCTAssertEqual(comparison.maximumAbsoluteError, 0)
            for frame in 0..<reader.frameCount {
                let metadata = try reader.frame(at: frame).metadata
                XCTAssertEqual(metadata.bitsStored, fixture.bitsStored, fixture.id)
                XCTAssertEqual(metadata.bitsAllocated, fixture.bitsAllocated, fixture.id)
                XCTAssertEqual(metadata.samplesPerPixel, fixture.components, fixture.id)
            }
        }
    }

    func test_deliberatePixelAndFrameOrderMutations_reportExactFirstDifference() throws {
        let fixture = try XCTUnwrap(manifest().fixtures.first { $0.id == "rgb-interleaved" })
        let expected = fixture.displaySamples
        var mutated = expected
        mutated[2][43] += 1
        let pixel = ClinicalDifferentialComparison.compare(expected: expected, actual: mutated, columns: 5, components: 3)
        XCTAssertEqual(pixel.result, "mismatched")
        XCTAssertEqual(pixel.firstDifference?.path, "frame[2].row[2].column[4].component[1]")
        XCTAssertEqual(pixel.samplesCompared, 135, "Compare all components even after a difference")
        XCTAssertEqual(pixel.maximumAbsoluteError, 1)

        mutated = [expected[0], expected[2], expected[1]]
        let order = ClinicalDifferentialComparison.compare(expected: expected, actual: mutated, columns: 5, components: 3)
        XCTAssertEqual(order.result, "mismatched")
        XCTAssertEqual(order.firstDifference?.path, "frame[1].row[0].column[0].component[0]")
        let missing = ClinicalDifferentialComparison.compare(expected: expected, actual: Array(expected.prefix(2)),
                                                            columns: 5, components: 3)
        XCTAssertEqual(missing.firstDifference?.path, "frameCount")
    }

    func test_dataBackedRGB_comparesEveryPlanarAndInterleavedComponent() throws {
        for fixture in try manifest().fixtures where fixture.components == 3 {
            let reader = try DicomDecodedFrameReader(contentsOf: Self.corpus.appendingPathComponent(fixture.path))
            let actual = try (0..<reader.frameCount).map { index in
                try reader.dataBackedFrame(at: index).pixels.data.map(Int.init)
            }
            let result = ClinicalDifferentialComparison.compare(expected: fixture.displaySamples, actual: actual,
                                                               columns: fixture.columns, components: fixture.components)
            XCTAssertEqual(result.result, "passed", "\(fixture.id): \(String(describing: result.firstDifference))")
        }
    }

    func test_nearLosslessBound_isExplicitAndEvaluatedAcrossAllSamples() {
        let expected = [[-2048, 0, 2047], [100, 101, 102]]
        let actual = [[-2046, 1, 2046], [100, 99, 104]]
        let accepted = ClinicalDifferentialComparison.compare(expected: expected, actual: actual, columns: 3,
                                                             components: 1, maximumAbsoluteError: 2)
        XCTAssertEqual(accepted.result, "passed")
        XCTAssertEqual(accepted.samplesCompared, 6)
        XCTAssertEqual(accepted.maximumAbsoluteError, 2)
        XCTAssertEqual(accepted.rootMeanSquareError, sqrt(14.0 / 6.0), accuracy: 0.000_001)
        let rejected = ClinicalDifferentialComparison.compare(expected: expected, actual: actual, columns: 3, components: 1)
        XCTAssertEqual(rejected.result, "mismatched", "Reversible comparison must never inherit a lossy tolerance")
    }

    func test_swiftRewrites_preserveEveryFrameAndExportForIndependentReader() throws {
        let configured = ProcessInfo.processInfo.environment["DICOM_DIFFERENTIAL_REWRITE_DIR"]
        let output = configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("independent-rewrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { if configured == nil { try? FileManager.default.removeItem(at: output) } }
        for fixture in try manifest().fixtures {
            let decoder = try DCMDecoder(contentsOf: Self.corpus.appendingPathComponent(fixture.path))
            let destination = output.appendingPathComponent(fixture.path)
            var dataSet = decoder.dataSet
            // The metadata dataset intentionally omits bulk pixels; retain the native frame bytes explicitly.
            var pixelData = Data()
            for index in 0..<fixture.frames {
                pixelData.append(try XCTUnwrap(decoder.getFrame(index)).data)
            }
            dataSet.set(DicomDataElement(tag: DicomTag.pixelData.rawValue,
                                        vr: fixture.bitsAllocated == 8 ? .OB : .OW, value: .bytes(pixelData)))
            try DicomDataSetWriter.write(dataSet, to: destination)
            let actual = try samples(DicomDecodedFrameReader(contentsOf: destination))
            let result = ClinicalDifferentialComparison.compare(expected: fixture.displaySamples, actual: actual,
                                                               columns: fixture.columns, components: fixture.components)
            XCTAssertEqual(result.result, "passed", fixture.id)
        }
    }

    private func samples(_ reader: DicomDecodedFrameReader) throws -> [[Int]] {
        try (0..<reader.frameCount).map { index in
            switch try reader.frame(at: index).pixels {
            case .gray8(let values): return values.map(Int.init)
            case .gray16(let values): return values.map(Int.init)
            case .rgb8(let values): return values.map(Int.init)
            }
        }
    }

    private func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: Self.corpus.appendingPathComponent("manifest.json")))
    }

    private struct Manifest: Decodable {
        let fixtures: [Fixture]
    }

    private struct Fixture: Decodable {
        let id: String
        let path: String
        let sha256: String
        let rows: Int
        let columns: Int
        let frames: Int
        let components: Int
        let bitsStored: Int
        let bitsAllocated: Int
        let displaySamples: [[Int]]
    }

    private static var corpus: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/IndependentDifferential", isDirectory: true)
    }
}
