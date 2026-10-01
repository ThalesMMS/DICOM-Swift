import Dispatch
import os
import XCTest
import DicomTestSupport
@testable import DicomCore

// Compatibility coverage: this suite intentionally exercises deprecated
// public APIs that remain available (issue #1221); the annotation keeps
// the deliberate legacy usage warning-free without hiding new ones.
@available(*, deprecated)
final class DCMDecoderAsyncTests: XCTestCase {

    func testThrowingOperationCancelledDuringSynchronousWorkDoesNotPublishLateResult() async {
        let started = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try await DCMDecoderAsyncOperation.perform(priority: .userInitiated) {
                started.withLock { $0 = true }
                release.wait()
                return 42
            }
        }
        let didStart = await waitForOperationToStart(started)
        guard didStart else {
            task.cancel()
            release.signal()
            XCTFail("The synchronous operation did not start")
            return
        }

        task.cancel()
        release.signal()

        do {
            _ = try await task.value
            XCTFail("A cancelled operation should not publish its completed value")
        } catch is CancellationError {
            // Expected cooperative cancellation after synchronous work.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testNonThrowingOperationCancelledDuringSynchronousWorkReturnsCancellationValue() async {
        let started = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            await DCMDecoderAsyncOperation.perform(priority: .userInitiated, cancellationValue: -1) {
                started.withLock { $0 = true }
                release.wait()
                return 42
            }
        }
        let didStart = await waitForOperationToStart(started)
        guard didStart else {
            task.cancel()
            release.signal()
            XCTFail("The synchronous operation did not start")
            return
        }

        task.cancel()
        release.signal()

        let value = await task.value
        XCTAssertEqual(value, -1)
    }

    private func waitForOperationToStart(_ started: OSAllocatedUnfairLock<Bool>) async -> Bool {
        for _ in 0..<200 {
            if started.withLock({ $0 }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return started.withLock { $0 }
    }

    // MARK: - Test Setup

    /// Get path to fixtures directory
    private func getFixturesPath() -> URL {
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    /// Helper to get a single test file URL
    private func getSingleTestFileURL() throws -> URL {
        try DicomTestRuntimePreflight.require(.bundledSyntheticFixtures)
        let fixturesPath = getFixturesPath()
        let ctPath = fixturesPath.appendingPathComponent("CT/ct_synthetic.dcm")

        guard FileManager.default.fileExists(atPath: ctPath.path) else {
            throw DicomRuntimeRequirementError(status: DicomRuntimeStatus(
                capability: .bundledSyntheticFixtures,
                kind: .regression,
                message: "Required fixture CT/ct_synthetic.dcm is missing."
            ))
        }

        return ctPath
    }

    /// Helper to get multiple test file URLs
    private func getTestFileURLs(minimumCount: Int, purpose: String) throws -> [URL] {
        try DicomTestRuntimePreflight.require(.bundledSyntheticFixtures)
        let fixturesPath = getFixturesPath()

        let paths = [
            fixturesPath.appendingPathComponent("CT/ct_synthetic.dcm"),
            fixturesPath.appendingPathComponent("MR/mr_synthetic.dcm"),
            fixturesPath.appendingPathComponent("US/us_synthetic.dcm")
        ]

        return try paths.filter { url in
            FileManager.default.fileExists(atPath: url.path)
        }
        .ifCount(atLeast: minimumCount, capability: .bundledSyntheticFixtures, purpose: purpose)
    }

    // MARK: - Async Initializer Tests

    func testAsyncInitWithURL() async throws {
        let url = try getSingleTestFileURL()

        let decoder = try await DCMDecoder(contentsOf: url)

        XCTAssertTrue(decoder.dicomFileReadSuccess, "Async init should load file successfully")
        XCTAssertTrue(decoder.dicomFound, "Should find DICM marker")
        XCTAssertGreaterThan(decoder.width, 0, "Width should be valid")
        XCTAssertGreaterThan(decoder.height, 0, "Height should be valid")
    }

    func testAsyncInitWithPath() async throws {
        let url = try getSingleTestFileURL()
        let path = url.path

        let decoder = try await DCMDecoder(contentsOfFile: path)

        XCTAssertTrue(decoder.dicomFileReadSuccess, "Async init should load file successfully")
        XCTAssertTrue(decoder.dicomFound, "Should find DICM marker")
        XCTAssertGreaterThan(decoder.width, 0, "Width should be valid")
        XCTAssertGreaterThan(decoder.height, 0, "Height should be valid")
    }

    func testAsyncInitWithNonExistentFile() async {
        let url = URL(fileURLWithPath: "/nonexistent/file.dcm")

        do {
            _ = try await DCMDecoder(contentsOf: url)
            XCTFail("Should throw fileNotFound error")
        } catch DICOMError.fileNotFound {
            // Expected error
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Static Factory Method Tests

    func testAsyncLoadFromURL() async throws {
        let url = try getSingleTestFileURL()

        let decoder = try await DCMDecoder.load(from: url)

        XCTAssertTrue(decoder.dicomFileReadSuccess, "Load from URL should succeed")
        XCTAssertGreaterThan(decoder.width, 0, "Width should be valid")
    }

    func testAsyncLoadFromPath() async throws {
        let url = try getSingleTestFileURL()
        let path = url.path

        let decoder = try await DCMDecoder.load(fromFile: path)

        XCTAssertTrue(decoder.dicomFileReadSuccess, "Load from path should succeed")
        XCTAssertGreaterThan(decoder.width, 0, "Width should be valid")
    }

    // MARK: - Async Pixel Retrieval Tests

    func testGetPixels16Async() async throws {
        let url = try getSingleTestFileURL()
        let decoder = try await DCMDecoder(contentsOf: url)

        let pixels = await decoder.getPixels16Async()

        XCTAssertNotNil(pixels, "Should retrieve 16-bit pixels")
        if let pixels = pixels {
            let expectedCount = decoder.width * decoder.height
            XCTAssertEqual(pixels.count, expectedCount, "Pixel count should match dimensions")
        }
    }

    func testGetPixels8Async() async throws {
        let url = try getSingleTestFileURL()
        let decoder = try await DCMDecoder(contentsOf: url)

        let pixels = await decoder.getPixels8Async()

        // 8-bit pixels may be nil for 16-bit images - that's OK
        if let pixels = pixels {
            let expectedCount = decoder.width * decoder.height
            XCTAssertEqual(pixels.count, expectedCount, "Pixel count should match dimensions")
        }
    }

    // MARK: - Batch Loading Tests

    func testLoadBatchBasic() async throws {
        let urls = try getTestFileURLs(minimumCount: 2, purpose: "batch loading")

        let results = await DCMDecoder.loadBatch(urls: urls)

        XCTAssertEqual(results.count, urls.count, "Should return result for each URL")

        for (index, result) in results.enumerated() {
            XCTAssertEqual(result.url, urls[index], "URL ordering should be preserved")

            if result.isSuccess {
                XCTAssertNotNil(result.decoder, "Successful result should have decoder")
                XCTAssertNil(result.error, "Successful result should not have error")
            } else {
                XCTAssertNil(result.decoder, "Failed result should not have decoder")
                XCTAssertNotNil(result.error, "Failed result should have error")
            }
        }
    }

    func testLoadBatchEmptyArray() async {
        let results = await DCMDecoder.loadBatch(urls: [])

        XCTAssertTrue(results.isEmpty, "Empty input should return empty results")
    }

    func testLoadBatchWithErrors() async throws {
        let validURL = try getSingleTestFileURL()
        let invalidURL = URL(fileURLWithPath: "/nonexistent/file.dcm")

        let urls = [validURL, invalidURL]
        let results = await DCMDecoder.loadBatch(urls: urls)

        XCTAssertEqual(results.count, 2, "Should return result for each URL")

        // First result should succeed
        XCTAssertTrue(results[0].isSuccess, "Valid file should load successfully")
        XCTAssertNotNil(results[0].decoder, "Valid file should have decoder")

        // Second result should fail
        XCTAssertTrue(results[1].isFailure, "Invalid file should fail")
        XCTAssertNil(results[1].decoder, "Invalid file should not have decoder")
        XCTAssertNotNil(results[1].error, "Invalid file should have error")
        if case .fileNotFound(let path)? = results[1].error {
            XCTAssertTrue(path.contains("/nonexistent/file.dcm"), "Error path should include missing file path")
        } else {
            XCTFail("Expected DICOMError.fileNotFound for missing file")
        }
    }

    func testLoadBatchConcurrencyLimit() async throws {
        let urls = try getTestFileURLs(minimumCount: 2, purpose: "concurrency")

        // Test with different concurrency limits
        let results1 = await DCMDecoder.loadBatch(urls: urls, maxConcurrency: 1)
        let results2 = await DCMDecoder.loadBatch(urls: urls, maxConcurrency: 4)

        // Both should produce same results regardless of concurrency
        XCTAssertEqual(results1.count, urls.count, "Sequential loading should process all files")
        XCTAssertEqual(results2.count, urls.count, "Concurrent loading should process all files")

        // Verify ordering is preserved
        for (result1, result2) in zip(results1, results2) {
            XCTAssertEqual(result1.url, result2.url, "URL ordering should match")
            XCTAssertEqual(result1.isSuccess, result2.isSuccess, "Success status should match")
        }
    }

    func testLoadBatchOrdering() async throws {
        let urls = try getTestFileURLs(minimumCount: 3, purpose: "ordering")

        let results = await DCMDecoder.loadBatch(urls: urls)

        // Verify results are in same order as input URLs
        for (index, result) in results.enumerated() {
            XCTAssertEqual(result.url, urls[index], "Result at index \(index) should match input URL")
        }
    }

    func testBatchResultProperties() async throws {
        let validURL = try getSingleTestFileURL()
        let invalidURL = URL(fileURLWithPath: "/nonexistent/file.dcm")

        let urls = [validURL, invalidURL]
        let results = await DCMDecoder.loadBatch(urls: urls)

        // Test success result properties
        let successResult = results[0]
        XCTAssertTrue(successResult.isSuccess, "Success result should have isSuccess true")
        XCTAssertFalse(successResult.isFailure, "Success result should have isFailure false")
        XCTAssertNotNil(successResult.decoder, "Success result should have decoder")
        XCTAssertNil(successResult.error, "Success result should not have error")

        // Test failure result properties
        let failureResult = results[1]
        XCTAssertFalse(failureResult.isSuccess, "Failure result should have isSuccess false")
        XCTAssertTrue(failureResult.isFailure, "Failure result should have isFailure true")
        XCTAssertNil(failureResult.decoder, "Failure result should not have decoder")
        XCTAssertNotNil(failureResult.error, "Failure result should have error")
    }

    // MARK: - Legacy Async Methods Tests

    func testLoadDICOMFileAsync() async throws {
        let url = try getSingleTestFileURL()
        let decoder = DCMDecoder()

        let success = await decoder.loadDICOMFileAsync(url.path)

        XCTAssertTrue(success, "Async file loading should succeed")
        XCTAssertTrue(decoder.dicomFileReadSuccess, "Decoder should have file read success")
    }

    func testLoadDICOMFileAsyncReturnsFalseWhenCallerIsAlreadyCancelled() async throws {
        let url = try getSingleTestFileURL()
        let decoder = DCMDecoder()
        let task = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            return await decoder.loadDICOMFileAsync(url.path)
        }

        let success = await task.value

        XCTAssertFalse(success)
        XCTAssertFalse(decoder.dicomFileReadSuccess)
    }

    func testGetDownsampledPixels16Async() async throws {
        let url = try getSingleTestFileURL()
        let decoder = try await DCMDecoder(contentsOf: url)

        let result = await decoder.getDownsampledPixels16Async(maxDimension: 150)

        XCTAssertNotNil(result, "Should retrieve downsampled pixels")
        if let (pixels, width, height) = result {
            XCTAssertGreaterThan(pixels.count, 0, "Should have pixels")
            XCTAssertLessThanOrEqual(width, 150, "Width should respect max dimension")
            XCTAssertLessThanOrEqual(height, 150, "Height should respect max dimension")
            XCTAssertEqual(pixels.count, width * height, "Pixel count should match dimensions")
        }
    }

    func testGetDownsampledPixels8Async() async throws {
        let url = try getSingleTestFileURL()
        let decoder = try await DCMDecoder(contentsOf: url)

        let result = await decoder.getDownsampledPixels8Async(maxDimension: 150)

        // Downsampled 8-bit pixels may be nil for 16-bit images - that's OK
        if let (pixels, width, height) = result {
            XCTAssertGreaterThan(pixels.count, 0, "Should have pixels")
            XCTAssertLessThanOrEqual(width, 150, "Width should respect max dimension")
            XCTAssertLessThanOrEqual(height, 150, "Height should respect max dimension")
            XCTAssertEqual(pixels.count, width * height, "Pixel count should match dimensions")
        }
    }
}

private extension Array where Element == URL {
    func ifCount(atLeast minimumCount: Int, capability: DicomRuntimeCapability, purpose: String) throws -> [URL] {
        guard count >= minimumCount else {
            throw DicomRuntimeRequirementError(status: DicomRuntimeStatus(
                capability: capability,
                kind: .regression,
                message: "Need at least \(minimumCount) bundled synthetic fixture files for \(purpose); found \(count)."
            ))
        }
        return self
    }
}
