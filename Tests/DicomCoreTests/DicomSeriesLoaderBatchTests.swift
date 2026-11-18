//
//  DicomSeriesLoaderBatchTests.swift
//  DicomCoreTests
//
//  Checks batch series loading with invalid files, empty input, and bounded concurrent work.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
import simd
@testable import DicomCore

// Compatibility coverage: this suite intentionally exercises deprecated
// public APIs that remain available (issue #1221); the annotation keeps
// the deliberate legacy usage warning-free without hiding new ones.
@available(*, deprecated)
final class DicomSeriesLoaderBatchTests: XCTestCase {

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func createFiles(in directory: URL, count: Int, prefix: String = "file") throws -> [URL] {
        var urls: [URL] = []
        for index in 0..<count {
            let url = directory.appendingPathComponent("\(prefix)_\(index).dcm")
            try Data().write(to: url)
            urls.append(url)
        }
        return urls
    }

    private func makeLoader(
        width: Int,
        height: Int,
        pixelValue: UInt16
    ) -> DicomSeriesLoader {
        DicomSeriesLoader(
            decoderFactory: MockDecoderBuilder.makeFactory(
                width: width,
                height: height,
                pixelValue: pixelValue
            )
        )
    }

    func testBatchLoadFiles() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderBatchTests_LoadFiles")
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURLs = try createFiles(in: directory, count: 10)
        let loader = makeLoader(width: 256, height: 256, pixelValue: 100)
        let results = await loader.batchLoadFiles(urls: fileURLs, maxConcurrency: 4)

        XCTAssertEqual(results.count, fileURLs.count)

        let successCount = results.reduce(into: 0) { count, result in
            if result.success, let decoder = result.decoder {
                XCTAssertEqual(decoder.width, 256)
                XCTAssertEqual(decoder.height, 256)
                count += 1
            }
        }

        XCTAssertEqual(successCount, fileURLs.count)
        for (index, result) in results.enumerated() {
            XCTAssertEqual(result.url, fileURLs[index])
        }
    }

    func testBatchLoadFilesWithErrors() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderBatchTests_LoadFilesWithErrors")
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURLs = try createFiles(in: directory, count: 3)
        let loader = DicomSeriesLoader(
            decoderFactory: MockDecoderBuilder.makeSequencedFactory(
                successPattern: [true, false, true],
                width: 128,
                height: 128,
                pixelValue: 50
            )
        )

        let results = await loader.batchLoadFiles(urls: fileURLs, maxConcurrency: 3)

        XCTAssertEqual(results.count, fileURLs.count)
        XCTAssertGreaterThan(results.filter(\.success).count, 0)
        XCTAssertGreaterThan(results.filter { !$0.success }.count, 0)
        for result in results where !result.success {
            XCTAssertNotNil(result.error)
        }

        for (index, result) in results.enumerated() {
            XCTAssertEqual(result.url, fileURLs[index])
        }
    }

    func testBatchLoadFilesEmptyArray() async {
        let results = await DicomSeriesLoader().batchLoadFiles(urls: [], maxConcurrency: 4)
        XCTAssertTrue(results.isEmpty)
    }

    func testBatchLoadFilesConcurrencyLimit() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderBatchTests_Concurrency")
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURLs = try createFiles(in: directory, count: 20)
        let loader = makeLoader(width: 64, height: 64, pixelValue: 25)

        let results1 = await loader.batchLoadFiles(urls: fileURLs, maxConcurrency: 1)
        let results4 = await loader.batchLoadFiles(urls: fileURLs, maxConcurrency: 4)
        let results10 = await loader.batchLoadFiles(urls: fileURLs, maxConcurrency: 10)

        XCTAssertEqual(results1.count, fileURLs.count)
        XCTAssertEqual(results4.count, fileURLs.count)
        XCTAssertEqual(results10.count, fileURLs.count)
    }

    func testBatchLoadFilesResultOrdering() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderBatchTests_ResultOrdering")
        defer { try? FileManager.default.removeItem(at: directory) }

        var fileURLs: [URL] = []
        for index in 0..<5 {
            let url = directory.appendingPathComponent("slice_\(String(format: "%03d", index)).dcm")
            try Data().write(to: url)
            fileURLs.append(url)
        }

        let results = await makeLoader(width: 32, height: 32, pixelValue: 10)
            .batchLoadFiles(urls: fileURLs, maxConcurrency: 3)

        for (index, result) in results.enumerated() {
            XCTAssertEqual(result.url, fileURLs[index])
        }
    }

    func testBatchLoadSeries() async throws {
        let baseDirectory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderBatchTests_LoadSeries")
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let seriesCounts = [3, 5, 4]
        var seriesDirectories: [URL] = []

        for (index, sliceCount) in seriesCounts.enumerated() {
            let seriesDirectory = baseDirectory.appendingPathComponent("series_\(index)")
            try FileManager.default.createDirectory(at: seriesDirectory, withIntermediateDirectories: true)
            try createFiles(in: seriesDirectory, count: sliceCount, prefix: "slice")
            seriesDirectories.append(seriesDirectory)
        }

        let loader = DicomSeriesLoader(
            decoderFactory: MockDecoderBuilder.makePathFactory(
                width: 128,
                height: 128,
                pixelValue: 100,
                positionProvider: Self.slicePosition(for:)
            )
        )

        final class ProgressCollector: @unchecked Sendable {
            private let queue = DispatchQueue(label: "DicomSeriesLoaderBatchTests.progress")
            private var updates: [(fraction: Double, completed: Int)] = []

            func append(fraction: Double, completed: Int) {
                queue.sync {
                    updates.append((fraction, completed))
                }
            }

            func snapshot() -> [(fraction: Double, completed: Int)] {
                queue.sync { updates }
            }
        }

        let progressCollector = ProgressCollector()
        let volumes = try await loader.batchLoadSeries(
            seriesDirectories: seriesDirectories,
            maxConcurrency: 2
        ) { fraction, completed in
            progressCollector.append(fraction: fraction, completed: completed)
        }

        let progressUpdates = progressCollector.snapshot()
        XCTAssertEqual(volumes.count, seriesCounts.count)
        for (index, volume) in volumes.enumerated() {
            XCTAssertEqual(volume.depth, seriesCounts[index])
            XCTAssertEqual(volume.width, 128)
            XCTAssertEqual(volume.height, 128)
        }

        XCTAssertFalse(progressUpdates.isEmpty)
        if let finalProgress = progressUpdates.last {
            XCTAssertEqual(finalProgress.fraction, 1.0, accuracy: 0.01)
            XCTAssertEqual(finalProgress.completed, seriesCounts.count)
        }

        for index in 1..<progressUpdates.count {
            XCTAssertGreaterThanOrEqual(progressUpdates[index].fraction, progressUpdates[index - 1].fraction)
        }
    }

    private static func slicePosition(for path: String) -> SIMD3<Double> {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let index = stem.split(separator: "_").last.flatMap { Double($0) } ?? 0
        return SIMD3<Double>(0, 0, index)
    }
}
