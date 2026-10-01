import XCTest
import simd
@testable import DicomCore
import DicomTestSupport

/// Child tasks only call stateless fixture helpers; the test case stores no shared mutable state.
final class DicomSeriesLoaderAsyncTests: XCTestCase, @unchecked Sendable {

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func createFiles(in directory: URL, count: Int, prefix: String = "slice") throws -> [URL] {
        var urls: [URL] = []
        for index in 0..<count {
            let url = directory.appendingPathComponent("\(prefix)_\(index).dcm")
            try Data().write(to: url)
            urls.append(url)
        }
        return urls
    }

    private func makeLoader(
        width: Int = 512,
        height: Int = 512,
        pixelValue: UInt16 = 100,
        seriesDescription: String = "Test Series"
    ) -> DicomSeriesLoader {
        DicomSeriesLoader(
            decoderFactory: MockDecoderBuilder.makePathFactory(
                width: width,
                height: height,
                pixelValue: pixelValue,
                seriesDescription: seriesDescription,
                positionProvider: Self.slicePosition(for:)
            )
        )
    }

    private func makeDelayedLoader(
        width: Int = 512,
        height: Int = 512,
        pixelValue: UInt16 = 100,
        delay: TimeInterval = 0.02
    ) -> DicomSeriesLoader {
        DicomSeriesLoader(
            decoderFactory: { path in
                Thread.sleep(forTimeInterval: delay)
                if Task.isCancelled {
                    throw CancellationError()
                }
                return try MockDecoderBuilder.makePathFactory(
                    width: width,
                    height: height,
                    pixelValue: pixelValue,
                    positionProvider: Self.slicePosition(for:)
                )(path)
            }
        )
    }

    private func makeInconsistentDimensionLoader() -> DicomSeriesLoader {
        DicomSeriesLoader(
            decoderFactory: MockDecoderBuilder.makePathFactory(
                width: 128,
                height: 128,
                pixelValue: 50,
                positionProvider: Self.slicePosition(for:),
                sizeProvider: { path in
                    path.contains("slice_0") ? (128, 128) : (256, 256)
                }
            )
        )
    }

    private static func slicePosition(for path: String) -> SIMD3<Double> {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let index = stem.split(separator: "_").last.flatMap { Double($0) } ?? 0
        return SIMD3<Double>(0, 0, index)
    }

    private func collectProgress(
        from stream: AsyncThrowingStream<SeriesLoadProgress, Error>
    ) async throws -> [SeriesLoadProgress] {
        var progressUpdates: [SeriesLoadProgress] = []
        for try await progress in stream {
            try Task.checkCancellation()
            progressUpdates.append(progress)
        }
        try Task.checkCancellation()
        return progressUpdates
    }

    func testAsyncLoadSeriesWithNonexistentDirectory() async {
        let loader = DicomSeriesLoader()
        let nonexistentURL = URL(fileURLWithPath: "/nonexistent/path/to/dicom/files")

        do {
            _ = try await loader.loadSeries(in: nonexistentURL, progress: nil)
            XCTFail("Should throw error for nonexistent directory")
        } catch {
            XCTAssertTrue(error is DicomSeriesLoaderError || error is CocoaError)
        }
    }

    func testAsyncLoadSeriesWithEmptyDirectory() async throws {
        let loader = DicomSeriesLoader()
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncTests_Empty")
        defer { try? FileManager.default.removeItem(at: directory) }

        await XCTAssertThrowsNoDicomFiles {
            try await loader.loadSeries(in: directory, progress: nil)
        }
    }

    func testAsyncLoadSeriesWithProgressCallback() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncTests_Progress")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sliceCount = 3
        try createFiles(in: directory, count: sliceCount)

        let loader = makeLoader(width: 256, height: 256, pixelValue: 100)
        let progress = DicomTestLockedValue((callCount: 0, lastFraction: 0.0))

        let volume = try await loader.loadSeries(in: directory) { fraction, slicesCopied, _, volumeInfo in
            progress.withValue { state in
                state.callCount += 1
                state.lastFraction = fraction
            }
            XCTAssertGreaterThanOrEqual(fraction, 0.0)
            XCTAssertLessThanOrEqual(fraction, 1.0)
            XCTAssertGreaterThan(slicesCopied, 0)
            XCTAssertNotNil(volumeInfo)
        }

        let finalProgress = progress.value
        XCTAssertGreaterThan(finalProgress.callCount, 0)
        XCTAssertEqual(volume.depth, sliceCount)
        XCTAssertEqual(finalProgress.lastFraction, 1.0, accuracy: 0.01)
    }

    func testAsyncLoadSeriesMatchesSyncVersion() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncTests_MatchesSync")
        defer { try? FileManager.default.removeItem(at: directory) }
        try createFiles(in: directory, count: 2)

        let syncLoader = makeLoader(width: 128, height: 128, pixelValue: 50)
        let asyncLoader = makeLoader(width: 128, height: 128, pixelValue: 50)

        let syncVolume = try await Task.detached {
            try syncLoader.loadSeries(in: directory, progress: nil)
        }.value
        let asyncVolume = try await asyncLoader.loadSeries(in: directory, progress: nil)

        XCTAssertEqual(syncVolume.width, asyncVolume.width)
        XCTAssertEqual(syncVolume.height, asyncVolume.height)
        XCTAssertEqual(syncVolume.depth, asyncVolume.depth)
        XCTAssertEqual(syncVolume.bitsAllocated, asyncVolume.bitsAllocated)
        XCTAssertEqual(syncVolume.spacing.x, asyncVolume.spacing.x)
        XCTAssertEqual(syncVolume.spacing.y, asyncVolume.spacing.y)
        XCTAssertEqual(syncVolume.spacing.z, asyncVolume.spacing.z)
    }

    func testConcurrentAsyncLoadOperations() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncTests_ConcurrentLoads")
        defer { try? FileManager.default.removeItem(at: directory) }
        try createFiles(in: directory, count: 1)

        let iterations = 5
        try await withThrowingTaskGroup(of: DicomSeriesVolume.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    try await self.makeLoader(width: 64, height: 64, pixelValue: 25)
                        .loadSeries(in: directory, progress: nil)
                }
            }

            var completedCount = 0
            for try await volume in group {
                XCTAssertEqual(volume.width, 64)
                XCTAssertEqual(volume.height, 64)
                completedCount += 1
            }

            XCTAssertEqual(completedCount, iterations)
        }
    }

    func testAsyncLoadSeriesErrorHandling() async throws {
        let loader = DicomSeriesLoader()
        let nonexistent = URL(fileURLWithPath: "/nonexistent/async/test/\(UUID().uuidString)")

        do {
            _ = try await loader.loadSeries(in: nonexistent, progress: nil)
            XCTFail("Should throw error for nonexistent directory")
        } catch {
            XCTAssertNotNil(error)
        }

        let emptyDirectory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncTests_ErrorEmpty")
        defer { try? FileManager.default.removeItem(at: emptyDirectory) }
        await XCTAssertThrowsNoDicomFiles {
            try await loader.loadSeries(in: emptyDirectory, progress: nil)
        }
    }

    func testAsyncLoadSeriesWithoutProgressCallback() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncTests_NoProgress")
        defer { try? FileManager.default.removeItem(at: directory) }
        try createFiles(in: directory, count: 1)

        let volume = try await makeLoader(width: 32, height: 32, pixelValue: 10)
            .loadSeries(in: directory, progress: nil)

        XCTAssertEqual(volume.width, 32)
        XCTAssertEqual(volume.height, 32)
        XCTAssertEqual(volume.depth, 1)
    }

    func testAsyncLoadSeriesCancellation() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncTests_Cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        try createFiles(in: directory, count: 10)
        let loader = makeDelayedLoader(width: 512, height: 512, pixelValue: 100)

        let task = Task {
            try await loader.loadSeries(in: directory, progress: nil)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected loadSeries task to be cancelled")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testMultipleLoadersWithAsyncOperations() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncTests_MultiLoader")
        defer { try? FileManager.default.removeItem(at: directory) }
        try createFiles(in: directory, count: 1)

        async let volume1 = makeLoader(width: 128, height: 128, pixelValue: 75).loadSeries(in: directory, progress: nil)
        async let volume2 = makeLoader(width: 128, height: 128, pixelValue: 75).loadSeries(in: directory, progress: nil)
        async let volume3 = makeLoader(width: 128, height: 128, pixelValue: 75).loadSeries(in: directory, progress: nil)

        let (v1, v2, v3) = try await (volume1, volume2, volume3)
        XCTAssertEqual(v1.width, 128)
        XCTAssertEqual(v2.width, 128)
        XCTAssertEqual(v3.width, 128)
    }

    func testAsyncLoadSeriesProgressMonitoring() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncTests_ProgressMonitoring")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sliceCount = 5
        try createFiles(in: directory, count: sliceCount)

        let progressUpdates = DicomTestLockedValue<[(fraction: Double, slicesCopied: Int)]>([])

        let volume = try await makeLoader(width: 64, height: 64, pixelValue: 33).loadSeries(in: directory) { fraction, slicesCopied, _, _ in
            progressUpdates.withValue { $0.append((fraction, slicesCopied)) }
        }

        let updates = progressUpdates.value
        let progressFractions = updates.map(\.fraction)
        let slicesCopiedValues = updates.map(\.slicesCopied)
        XCTAssertEqual(volume.depth, sliceCount)
        XCTAssertFalse(progressFractions.isEmpty)
        XCTAssertEqual(progressFractions.count, slicesCopiedValues.count)
        for index in 1..<progressFractions.count {
            XCTAssertGreaterThanOrEqual(progressFractions[index], progressFractions[index - 1])
            XCTAssertGreaterThanOrEqual(slicesCopiedValues[index], slicesCopiedValues[index - 1])
        }
        let finalFraction = try XCTUnwrap(progressFractions.last)
        XCTAssertEqual(finalFraction, 1.0, accuracy: 0.01)
        XCTAssertEqual(slicesCopiedValues.last, sliceCount)
    }

    func testConcurrentLoaderInstancesWithAsyncAccess() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncTests_ConcurrentInstances")
        defer { try? FileManager.default.removeItem(at: directory) }
        try createFiles(in: directory, count: 2)

        let iterations = 4
        try await withThrowingTaskGroup(of: DicomSeriesVolume.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    try await self.makeLoader(width: 96, height: 96, pixelValue: 20)
                        .loadSeries(in: directory, progress: nil)
                }
            }

            var completedCount = 0
            for try await volume in group {
                XCTAssertEqual(volume.depth, 2)
                completedCount += 1
            }
            XCTAssertEqual(completedCount, iterations)
        }
    }

    func testLoadSeriesWithProgressBasicStream() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncStreamTests_Basic")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sliceCount = 3
        try createFiles(in: directory, count: sliceCount)

        let updates = try await collectProgress(
            from: makeLoader(width: 64, height: 64, pixelValue: 50).loadSeriesWithProgress(in: directory)
        )

        XCTAssertFalse(updates.isEmpty)
        XCTAssertEqual(updates.last?.fractionComplete, 1.0)
        XCTAssertEqual(updates.last?.slicesCopied, sliceCount)
        XCTAssertEqual(updates.last?.volumeInfo.depth, sliceCount)
    }

    func testLoadSeriesWithProgressStreamErrorHandling() async throws {
        let loader = DicomSeriesLoader()
        let stream = loader.loadSeriesWithProgress(in: URL(fileURLWithPath: "/nonexistent/path/to/dicom/files"))

        do {
            _ = try await collectProgress(from: stream)
            XCTFail("Expected stream to throw")
        } catch {
            XCTAssertTrue(error is DicomSeriesLoaderError || error is CocoaError)
        }
    }

    func testLoadSeriesWithProgressStreamEmptyDirectory() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncStreamTests_Empty")
        defer { try? FileManager.default.removeItem(at: directory) }

        await XCTAssertThrowsNoDicomFiles {
            try await self.collectProgress(
                from: DicomSeriesLoader().loadSeriesWithProgress(in: directory)
            )
        }
    }

    func testLoadSeriesWithProgressStreamProgressValues() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncStreamTests_Values")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sliceCount = 4
        try createFiles(in: directory, count: sliceCount)

        let updates = try await collectProgress(
            from: makeLoader(width: 32, height: 32, pixelValue: 25).loadSeriesWithProgress(in: directory)
        )

        let progressFractions = updates.map(\.fractionComplete)
        let slicesCopiedValues = updates.map(\.slicesCopied)
        XCTAssertFalse(progressFractions.isEmpty)
        for index in 1..<progressFractions.count {
            XCTAssertGreaterThanOrEqual(progressFractions[index], progressFractions[index - 1])
            XCTAssertGreaterThanOrEqual(slicesCopiedValues[index], slicesCopiedValues[index - 1])
        }
        XCTAssertEqual(progressFractions.last, 1.0)
        XCTAssertEqual(slicesCopiedValues.last, sliceCount)
    }

    func testLoadSeriesWithProgressStreamCancellation() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncStreamTests_Cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        try createFiles(in: directory, count: 20)
        let loader = makeDelayedLoader(width: 256, height: 256, pixelValue: 100)

        let task = Task {
            try await self.collectProgress(
                from: loader.loadSeriesWithProgress(in: directory)
            )
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected loadSeriesWithProgress task to be cancelled")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testAsyncStreamCancellationMidProgress() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncStreamTests_CancelMid")
        defer { try? FileManager.default.removeItem(at: directory) }
        try createFiles(in: directory, count: 25)
        let loader = makeDelayedLoader(width: 256, height: 256, pixelValue: 100)

        let task = Task {
            var updates: [SeriesLoadProgress] = []
            for try await progress in loader.loadSeriesWithProgress(in: directory) {
                try Task.checkCancellation()
                updates.append(progress)
            }
            try Task.checkCancellation()
            return updates
        }

        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected async stream task to be cancelled")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testConcurrentAsyncStreamIterations() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncStreamTests_Concurrent")
        defer { try? FileManager.default.removeItem(at: directory) }
        try createFiles(in: directory, count: 4)

        let iterations = 4
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    var updateCount = 0
                    for try await progress in self.makeLoader(width: 128, height: 128, pixelValue: 50).loadSeriesWithProgress(in: directory) {
                        XCTAssertGreaterThan(progress.fractionComplete, 0.0)
                        XCTAssertLessThanOrEqual(progress.fractionComplete, 1.0)
                        updateCount += 1
                    }
                    return updateCount
                }
            }

            var completedCount = 0
            for try await updateCount in group {
                XCTAssertGreaterThan(updateCount, 0)
                completedCount += 1
            }
            XCTAssertEqual(completedCount, iterations)
        }
    }

    func testAsyncStreamConcurrentAccessWithDifferentDirectories() async throws {
        let directory1 = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncStreamTests_Concurrent1")
        let directory2 = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncStreamTests_Concurrent2")
        defer {
            try? FileManager.default.removeItem(at: directory1)
            try? FileManager.default.removeItem(at: directory2)
        }

        try createFiles(in: directory1, count: 3)
        try createFiles(in: directory2, count: 5)

        async let depth1: Int = {
            let updates = try await self.collectProgress(
                from: self.makeLoader(width: 64, height: 64, pixelValue: 30).loadSeriesWithProgress(in: directory1)
            )
            return updates.last?.volumeInfo.depth ?? 0
        }()

        async let depth2: Int = {
            let updates = try await self.collectProgress(
                from: self.makeLoader(width: 64, height: 64, pixelValue: 30).loadSeriesWithProgress(in: directory2)
            )
            return updates.last?.volumeInfo.depth ?? 0
        }()

        let loadedDepth1 = try await depth1
        let loadedDepth2 = try await depth2

        XCTAssertEqual(loadedDepth1, 3)
        XCTAssertEqual(loadedDepth2, 5)
    }

    func testAsyncStreamErrorPropagation() async throws {
        let stream = DicomSeriesLoader().loadSeriesWithProgress(in: URL(fileURLWithPath: "/nonexistent/asyncstream/\(UUID().uuidString)"))
        var progressCount = 0
        var didThrowError = false

        do {
            for try await _ in stream {
                progressCount += 1
            }
        } catch {
            didThrowError = true
            XCTAssertTrue(error is DicomSeriesLoaderError || error is CocoaError)
        }

        XCTAssertTrue(didThrowError)
        XCTAssertEqual(progressCount, 0)
    }

    func testAsyncStreamMultipleIterations() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncStreamTests_MultiIter")
        defer { try? FileManager.default.removeItem(at: directory) }
        try createFiles(in: directory, count: 3)

        let loader = makeLoader(width: 128, height: 128, pixelValue: 60)
        let count1 = try await collectProgress(from: loader.loadSeriesWithProgress(in: directory)).count
        let count2 = try await collectProgress(from: loader.loadSeriesWithProgress(in: directory)).count

        XCTAssertGreaterThan(count1, 0)
        XCTAssertGreaterThan(count2, 0)
        XCTAssertEqual(count1, count2)
    }

    func testAsyncStreamBreakEarly() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncStreamTests_BreakEarly")
        defer { try? FileManager.default.removeItem(at: directory) }
        try createFiles(in: directory, count: 10)

        let maxUpdates = 2
        var progressUpdates: [SeriesLoadProgress] = []

        for try await progress in makeLoader(width: 128, height: 128, pixelValue: 60).loadSeriesWithProgress(in: directory) {
            progressUpdates.append(progress)
            if progressUpdates.count >= maxUpdates {
                break
            }
        }

        XCTAssertLessThanOrEqual(progressUpdates.count, maxUpdates)
        XCTAssertGreaterThan(progressUpdates.count, 0)
        XCTAssertLessThan(progressUpdates.last?.fractionComplete ?? 1.0, 1.0)
    }

    func testAsyncStreamAndCallbackProduceSameVolume() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncStreamTests_SameVolume")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sliceCount = 4
        try createFiles(in: directory, count: sliceCount)

        let callbackLoader = makeLoader(width: 256, height: 256, pixelValue: 100)
        let callbackVolume = try await callbackLoader.loadSeries(in: directory, progress: nil)

        let streamLoader = makeLoader(width: 256, height: 256, pixelValue: 100)
        let streamUpdates = try await collectProgress(from: streamLoader.loadSeriesWithProgress(in: directory))
        let streamVolume = try XCTUnwrap(streamUpdates.last?.volumeInfo)

        XCTAssertEqual(callbackVolume.width, streamVolume.width)
        XCTAssertEqual(callbackVolume.height, streamVolume.height)
        XCTAssertEqual(callbackVolume.depth, streamVolume.depth)
        XCTAssertEqual(callbackVolume.bitsAllocated, streamVolume.bitsAllocated)
        XCTAssertEqual(callbackVolume.isSignedPixel, streamVolume.isSignedPixel)
        XCTAssertEqual(callbackVolume.rescaleSlope, streamVolume.rescaleSlope)
        XCTAssertEqual(callbackVolume.rescaleIntercept, streamVolume.rescaleIntercept)
        XCTAssertEqual(callbackVolume.spacing.x, streamVolume.spacing.x)
        XCTAssertEqual(callbackVolume.spacing.y, streamVolume.spacing.y)
        XCTAssertEqual(callbackVolume.spacing.z, streamVolume.spacing.z)
        XCTAssertEqual(callbackVolume.voxels, streamVolume.voxels)
    }

    func testAsyncStreamAndCallbackProduceSameProgressUpdates() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncStreamTests_SameProgress")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sliceCount = 4
        try createFiles(in: directory, count: sliceCount)

        let callbackProgressUpdates = DicomTestLockedValue<[(fraction: Double, slicesCopied: Int)]>([])
        let callbackLoader = makeLoader(width: 128, height: 128, pixelValue: 75)
        _ = try await callbackLoader.loadSeries(in: directory) { fraction, slicesCopied, _, _ in
            callbackProgressUpdates.withValue { $0.append((fraction, slicesCopied)) }
        }

        let streamLoader = makeLoader(width: 128, height: 128, pixelValue: 75)
        let streamProgressUpdates = try await collectProgress(from: streamLoader.loadSeriesWithProgress(in: directory))
            .map { (fraction: $0.fractionComplete, slicesCopied: $0.slicesCopied) }

        let callbackUpdates = callbackProgressUpdates.value
        XCTAssertFalse(callbackUpdates.isEmpty)
        XCTAssertFalse(streamProgressUpdates.isEmpty)

        if let callbackFinal = callbackUpdates.last,
           let streamFinal = streamProgressUpdates.last {
            XCTAssertEqual(callbackFinal.fraction, streamFinal.fraction, accuracy: 0.01)
            XCTAssertEqual(callbackFinal.slicesCopied, streamFinal.slicesCopied)
            XCTAssertEqual(callbackFinal.slicesCopied, sliceCount)
        }
    }

    func testAsyncStreamAndCallbackHandleErrorsEquivalently() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncStreamTests_ErrorEquivalence")
        defer { try? FileManager.default.removeItem(at: directory) }
        try createFiles(in: directory, count: 2)

        let callbackLoader = makeInconsistentDimensionLoader()
        let streamLoader = makeInconsistentDimensionLoader()

        let callbackError: Error?
        do {
            _ = try await callbackLoader.loadSeries(in: directory, progress: nil)
            callbackError = nil
        } catch {
            callbackError = error
        }

        let streamError: Error?
        do {
            _ = try await collectProgress(from: streamLoader.loadSeriesWithProgress(in: directory))
            streamError = nil
        } catch {
            streamError = error
        }

        XCTAssertNotNil(callbackError)
        XCTAssertNotNil(streamError)

        if let callbackErr = callbackError as? DicomSeriesLoaderError,
           let streamErr = streamError as? DicomSeriesLoaderError {
            XCTAssertEqual(String(describing: callbackErr), String(describing: streamErr))
        }
    }

    func testAsyncStreamAndCallbackPerformanceEquivalence() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DicomSeriesLoaderAsyncStreamTests_Performance")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sliceCount = 10
        try createFiles(in: directory, count: sliceCount)

        let callbackStart = Date()
        let callbackVolume = try await makeLoader(width: 512, height: 512, pixelValue: 100)
            .loadSeries(in: directory, progress: nil)
        let callbackDuration = Date().timeIntervalSince(callbackStart)

        let streamStart = Date()
        let streamUpdates = try await collectProgress(
            from: makeLoader(width: 512, height: 512, pixelValue: 100).loadSeriesWithProgress(in: directory)
        )
        let streamDuration = Date().timeIntervalSince(streamStart)
        let streamVolume = streamUpdates.last?.volumeInfo

        XCTAssertNotNil(streamVolume)
        XCTAssertEqual(callbackVolume.depth, sliceCount)
        XCTAssertEqual(streamVolume?.depth, sliceCount)

        let minDuration = min(callbackDuration, streamDuration)
        if minDuration <= 0.001 {
            throw XCTSkip("Skipping performance ratio: duration too small to measure reliably.")
        }

        let ratio = max(callbackDuration, streamDuration) / minDuration
        XCTAssertLessThan(ratio, 2.0, "Performance should be comparable between APIs (ratio: \(ratio))")
    }
}
