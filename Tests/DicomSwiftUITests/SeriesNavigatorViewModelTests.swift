//
//  SeriesNavigatorViewModelTests.swift
//
//  Unit tests for SeriesNavigatorViewModel.
//  Tests series management, navigation methods, boundary conditions,
//  and computed properties.
//

import XCTest
import SwiftUI
@testable import DicomSwiftUI
@testable import DicomCore

@MainActor
final class SeriesNavigatorViewModelTests: XCTestCase {

    // MARK: - Helper Methods

    /// Creates an array of test URLs
    private func createTestURLs(count: Int, seriesName: String = "series") -> [URL] {
        return (0..<count).map { index in
            URL(fileURLWithPath: "/test/\(seriesName)/image\(index).dcm")
        }
    }

    // MARK: - Initialization Tests

    func testDefaultInitialization() {
        let viewModel = SeriesNavigatorViewModel()

        // Test initial state
        XCTAssertEqual(viewModel.currentIndex, 0, "Initial index should be 0")
        XCTAssertEqual(viewModel.totalCount, 0, "Initial total count should be 0")
        XCTAssertTrue(viewModel.seriesURLs.isEmpty, "Initial series URLs should be empty")
        XCTAssertFalse(viewModel.isLoadingThumbnails, "Should not be loading thumbnails initially")
    }

    func testInitializationWithSeriesURLs() {
        let testURLs = createTestURLs(count: 10)
        let viewModel = SeriesNavigatorViewModel(seriesURLs: testURLs)

        XCTAssertEqual(viewModel.currentIndex, 0, "Initial index should be 0")
        XCTAssertEqual(viewModel.totalCount, 10, "Total count should match URL count")
        XCTAssertEqual(viewModel.seriesURLs.count, 10, "Series URLs should be stored")
        XCTAssertFalse(viewModel.isLoadingThumbnails, "Should not be loading thumbnails initially")
    }

    // MARK: - Set Series URLs Tests

    func testSetSeriesURLs() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 5)

        viewModel.setSeriesURLs(testURLs)

        XCTAssertEqual(viewModel.currentIndex, 0, "Index should start at 0")
        XCTAssertEqual(viewModel.totalCount, 5, "Total count should be 5")
        XCTAssertEqual(viewModel.seriesURLs.count, 5, "Should store 5 URLs")
    }

    func testSetSeriesURLsWithInitialIndex() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 10)

        viewModel.setSeriesURLs(testURLs, initialIndex: 5)

        XCTAssertEqual(viewModel.currentIndex, 5, "Index should be set to 5")
        XCTAssertEqual(viewModel.totalCount, 10, "Total count should be 10")
    }

    func testSetSeriesURLsWithOutOfBoundsInitialIndex() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 5)

        // Set with initial index beyond bounds
        viewModel.setSeriesURLs(testURLs, initialIndex: 100)

        // Should clamp to last valid index
        XCTAssertEqual(viewModel.currentIndex, 4, "Index should be clamped to 4 (last valid index)")
        XCTAssertEqual(viewModel.totalCount, 5, "Total count should be 5")
    }

    func testSetSeriesURLsWithNegativeInitialIndex() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 5)

        // Set with negative initial index
        viewModel.setSeriesURLs(testURLs, initialIndex: -10)

        // Should clamp to 0
        XCTAssertEqual(viewModel.currentIndex, 0, "Index should be clamped to 0")
        XCTAssertEqual(viewModel.totalCount, 5, "Total count should be 5")
    }

    func testSetSeriesURLsWithEmptyArray() {
        let viewModel = SeriesNavigatorViewModel()

        viewModel.setSeriesURLs([])

        XCTAssertEqual(viewModel.currentIndex, 0, "Index should be 0 for empty series")
        XCTAssertEqual(viewModel.totalCount, 0, "Total count should be 0")
        XCTAssertTrue(viewModel.seriesURLs.isEmpty, "Series URLs should be empty")
    }

    // MARK: - Reset Tests

    func testReset() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 10)

        // Set series and navigate
        viewModel.setSeriesURLs(testURLs)
        viewModel.goToIndex(5)
        viewModel.startThumbnailLoading()

        // Reset
        viewModel.reset()

        // Verify reset to initial state
        XCTAssertEqual(viewModel.currentIndex, 0, "Index should be reset to 0")
        XCTAssertEqual(viewModel.totalCount, 0, "Total count should be reset to 0")
        XCTAssertTrue(viewModel.seriesURLs.isEmpty, "Series URLs should be empty after reset")
        XCTAssertFalse(viewModel.isLoadingThumbnails, "Should not be loading thumbnails after reset")
    }

    // MARK: - Navigation - Next Tests

    func testGoToNext() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 5)
        viewModel.setSeriesURLs(testURLs)

        // Navigate next
        viewModel.goToNext()

        XCTAssertEqual(viewModel.currentIndex, 1, "Index should be 1 after goToNext")
    }

    func testGoToNextMultipleTimes() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 5)
        viewModel.setSeriesURLs(testURLs)

        // Navigate next 3 times
        viewModel.goToNext()
        viewModel.goToNext()
        viewModel.goToNext()

        XCTAssertEqual(viewModel.currentIndex, 3, "Index should be 3 after 3 goToNext calls")
    }

    func testGoToNextAtLastImage() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 5)
        viewModel.setSeriesURLs(testURLs)

        // Navigate to last image
        viewModel.goToIndex(4)
        XCTAssertEqual(viewModel.currentIndex, 4)

        // Attempt to go next (should do nothing)
        viewModel.goToNext()

        XCTAssertEqual(viewModel.currentIndex, 4, "Index should remain at 4 (last image)")
    }

    // MARK: - Navigation - Previous Tests

    func testGoToPrevious() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 5)
        viewModel.setSeriesURLs(testURLs, initialIndex: 3)

        // Navigate previous
        viewModel.goToPrevious()

        XCTAssertEqual(viewModel.currentIndex, 2, "Index should be 2 after goToPrevious")
    }

    func testGoToPreviousMultipleTimes() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 5)
        viewModel.setSeriesURLs(testURLs, initialIndex: 4)

        // Navigate previous 3 times
        viewModel.goToPrevious()
        viewModel.goToPrevious()
        viewModel.goToPrevious()

        XCTAssertEqual(viewModel.currentIndex, 1, "Index should be 1 after 3 goToPrevious calls")
    }

    func testGoToPreviousAtFirstImage() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 5)
        viewModel.setSeriesURLs(testURLs)

        // Already at first image (index 0)
        XCTAssertEqual(viewModel.currentIndex, 0)

        // Attempt to go previous (should do nothing)
        viewModel.goToPrevious()

        XCTAssertEqual(viewModel.currentIndex, 0, "Index should remain at 0 (first image)")
    }

    // MARK: - Navigation - Go To Index Tests

    func testGoToIndex() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 10)
        viewModel.setSeriesURLs(testURLs)

        // Navigate to specific index
        viewModel.goToIndex(7)

        XCTAssertEqual(viewModel.currentIndex, 7, "Index should be set to 7")
    }

    func testGoToIndexZero() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 10)
        viewModel.setSeriesURLs(testURLs, initialIndex: 5)

        // Navigate to index 0
        viewModel.goToIndex(0)

        XCTAssertEqual(viewModel.currentIndex, 0, "Index should be set to 0")
    }

    func testGoToIndexLastImage() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 10)
        viewModel.setSeriesURLs(testURLs)

        // Navigate to last index
        viewModel.goToIndex(9)

        XCTAssertEqual(viewModel.currentIndex, 9, "Index should be set to 9 (last image)")
    }

    func testGoToIndexOutOfBounds() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 5)
        viewModel.setSeriesURLs(testURLs)

        // Attempt to navigate beyond bounds
        viewModel.goToIndex(100)

        // Should clamp to last valid index
        XCTAssertEqual(viewModel.currentIndex, 4, "Index should be clamped to 4")
    }

    func testGoToIndexNegative() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 5)
        viewModel.setSeriesURLs(testURLs, initialIndex: 3)

        // Attempt to navigate to negative index
        viewModel.goToIndex(-10)

        // Should clamp to 0
        XCTAssertEqual(viewModel.currentIndex, 0, "Index should be clamped to 0")
    }

    func testGoToIndexOnEmptySeries() {
        let viewModel = SeriesNavigatorViewModel()

        // Attempt to navigate with no series loaded
        viewModel.goToIndex(5)

        // Index should remain at 0
        XCTAssertEqual(viewModel.currentIndex, 0, "Index should remain at 0 for empty series")
    }

    // MARK: - Navigation - Go To First/Last Tests

    func testGoToFirst() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 10)
        viewModel.setSeriesURLs(testURLs, initialIndex: 5)

        viewModel.goToFirst()

        XCTAssertEqual(viewModel.currentIndex, 0, "Index should be 0 after goToFirst")
    }

    func testGoToLast() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 10)
        viewModel.setSeriesURLs(testURLs)

        viewModel.goToLast()

        XCTAssertEqual(viewModel.currentIndex, 9, "Index should be 9 (last) after goToLast")
    }

    func testGoToLastWithEmptySeries() {
        let viewModel = SeriesNavigatorViewModel()

        viewModel.goToLast()

        XCTAssertEqual(viewModel.currentIndex, 0, "Index should be 0 for empty series")
    }

    // MARK: - Computed Properties - Can Navigate Tests

    func testCanGoNext() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 5)
        viewModel.setSeriesURLs(testURLs)

        // At first image (index 0)
        XCTAssertTrue(viewModel.canGoNext, "Should be able to go next from first image")

        // Navigate to second-to-last image
        viewModel.goToIndex(3)
        XCTAssertTrue(viewModel.canGoNext, "Should be able to go next from second-to-last image")

        // Navigate to last image
        viewModel.goToIndex(4)
        XCTAssertFalse(viewModel.canGoNext, "Should not be able to go next from last image")
    }

    func testCanGoPrevious() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 5)
        viewModel.setSeriesURLs(testURLs)

        // At first image (index 0)
        XCTAssertFalse(viewModel.canGoPrevious, "Should not be able to go previous from first image")

        // Navigate to second image
        viewModel.goToIndex(1)
        XCTAssertTrue(viewModel.canGoPrevious, "Should be able to go previous from second image")

        // Navigate to last image
        viewModel.goToIndex(4)
        XCTAssertTrue(viewModel.canGoPrevious, "Should be able to go previous from last image")
    }

    func testCanGoNextWithEmptySeries() {
        let viewModel = SeriesNavigatorViewModel()

        XCTAssertFalse(viewModel.canGoNext, "Should not be able to go next with empty series")
    }

    func testCanGoPreviousWithEmptySeries() {
        let viewModel = SeriesNavigatorViewModel()

        XCTAssertFalse(viewModel.canGoPrevious, "Should not be able to go previous with empty series")
    }

    // MARK: - Computed Properties - Current URL Tests

    func testCurrentURL() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 5)
        viewModel.setSeriesURLs(testURLs)

        // Get current URL
        let currentURL = viewModel.currentURL

        XCTAssertNotNil(currentURL, "Current URL should not be nil")
        XCTAssertEqual(currentURL?.path, "/test/series/image0.dcm", "Should return first image URL")
    }

    func testCurrentURLAfterNavigation() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 5)
        viewModel.setSeriesURLs(testURLs)

        // Navigate to index 3
        viewModel.goToIndex(3)

        let currentURL = viewModel.currentURL
        XCTAssertNotNil(currentURL, "Current URL should not be nil")
        XCTAssertEqual(currentURL?.path, "/test/series/image3.dcm", "Should return image at index 3")
    }

    func testCurrentURLWithEmptySeries() {
        let viewModel = SeriesNavigatorViewModel()

        let currentURL = viewModel.currentURL

        XCTAssertNil(currentURL, "Current URL should be nil for empty series")
    }

    // MARK: - Computed Properties - isEmpty Tests

    func testIsEmpty() {
        let viewModel = SeriesNavigatorViewModel()

        XCTAssertTrue(viewModel.isEmpty, "Should be empty initially")

        let testURLs = createTestURLs(count: 5)
        viewModel.setSeriesURLs(testURLs)

        XCTAssertFalse(viewModel.isEmpty, "Should not be empty after loading series")

        viewModel.reset()

        XCTAssertTrue(viewModel.isEmpty, "Should be empty after reset")
    }

    // MARK: - Computed Properties - Progress Tests

    func testProgressPercentage() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 10)
        viewModel.setSeriesURLs(testURLs)

        // At index 0 (first image)
        XCTAssertEqual(viewModel.progressPercentage, 0.1, accuracy: 0.01, "Progress should be 10% (1/10)")

        // Navigate to middle
        viewModel.goToIndex(4)
        XCTAssertEqual(viewModel.progressPercentage, 0.5, accuracy: 0.01, "Progress should be 50% (5/10)")

        // Navigate to last
        viewModel.goToIndex(9)
        XCTAssertEqual(viewModel.progressPercentage, 1.0, accuracy: 0.01, "Progress should be 100% (10/10)")
    }

    func testProgressPercentageWithEmptySeries() {
        let viewModel = SeriesNavigatorViewModel()

        XCTAssertEqual(viewModel.progressPercentage, 0.0, accuracy: 0.01, "Progress should be 0% for empty series")
    }

    func testPositionString() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 10)
        viewModel.setSeriesURLs(testURLs)

        // At index 0
        XCTAssertEqual(viewModel.positionString, "1 / 10", "Position string should show 1 / 10")

        // Navigate to index 5
        viewModel.goToIndex(5)
        XCTAssertEqual(viewModel.positionString, "6 / 10", "Position string should show 6 / 10")

        // Navigate to last
        viewModel.goToIndex(9)
        XCTAssertEqual(viewModel.positionString, "10 / 10", "Position string should show 10 / 10")
    }

    func testPositionStringWithEmptySeries() {
        let viewModel = SeriesNavigatorViewModel()

        XCTAssertEqual(viewModel.positionString, "0 / 0", "Position string should show 0 / 0 for empty series")
    }

    // MARK: - Computed Properties - At First/Last Tests

    func testIsAtFirst() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 5)
        viewModel.setSeriesURLs(testURLs)

        XCTAssertTrue(viewModel.isAtFirst, "Should be at first initially")

        viewModel.goToNext()
        XCTAssertFalse(viewModel.isAtFirst, "Should not be at first after navigation")

        viewModel.goToFirst()
        XCTAssertTrue(viewModel.isAtFirst, "Should be at first after goToFirst")
    }

    func testIsAtLast() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 5)
        viewModel.setSeriesURLs(testURLs)

        XCTAssertFalse(viewModel.isAtLast, "Should not be at last initially")

        viewModel.goToLast()
        XCTAssertTrue(viewModel.isAtLast, "Should be at last after goToLast")

        viewModel.goToPrevious()
        XCTAssertFalse(viewModel.isAtLast, "Should not be at last after going previous")
    }

    // MARK: - Thumbnail Loading Tests

    func testStartThumbnailLoading() {
        let viewModel = SeriesNavigatorViewModel()

        XCTAssertFalse(viewModel.isLoadingThumbnails, "Should not be loading initially")

        viewModel.startThumbnailLoading()

        XCTAssertTrue(viewModel.isLoadingThumbnails, "Should be loading after startThumbnailLoading")
    }

    func testCompleteThumbnailLoading() {
        let viewModel = SeriesNavigatorViewModel()

        viewModel.startThumbnailLoading()
        XCTAssertTrue(viewModel.isLoadingThumbnails, "Should be loading")

        viewModel.completeThumbnailLoading()
        XCTAssertFalse(viewModel.isLoadingThumbnails, "Should not be loading after completeThumbnailLoading")
    }

    func testThumbnailLoadingWorkflow() {
        let viewModel = SeriesNavigatorViewModel()

        // Simulate thumbnail loading workflow
        viewModel.startThumbnailLoading()
        XCTAssertTrue(viewModel.isLoadingThumbnails)

        // Simulate loading completion
        viewModel.completeThumbnailLoading()
        XCTAssertFalse(viewModel.isLoadingThumbnails)
    }

    func testSeriesNavigatorThumbnailRejectsInvalidDimensions() {
        XCTAssertNil(SeriesNavigatorThumbnail(pixels: [], width: 0, height: 1))
        XCTAssertNil(SeriesNavigatorThumbnail(pixels: [0, 1], width: 2, height: 2))
    }

    func testSetThumbnailStoresAndClearsValidIndex() throws {
        let viewModel = SeriesNavigatorViewModel(seriesURLs: createTestURLs(count: 2))
        let thumbnail = try XCTUnwrap(SeriesNavigatorThumbnail(
            pixels: [0, 64, 128, 255],
            width: 2,
            height: 2
        ))

        viewModel.setThumbnail(thumbnail, for: 1)

        XCTAssertEqual(viewModel.thumbnail(at: 1), thumbnail)
        XCTAssertNil(viewModel.thumbnail(at: 0))

        viewModel.setThumbnail(nil, for: 1)

        XCTAssertNil(viewModel.thumbnail(at: 1))
    }

    func testSeriesReplacementClearsThumbnails() throws {
        let viewModel = SeriesNavigatorViewModel(seriesURLs: createTestURLs(count: 2))
        let thumbnail = try XCTUnwrap(SeriesNavigatorThumbnail(
            pixels: [0, 64, 128, 255],
            width: 2,
            height: 2
        ))
        viewModel.setThumbnail(thumbnail, for: 0)

        viewModel.setSeriesURLs(createTestURLs(count: 1, seriesName: "replacement"))

        XCTAssertNil(viewModel.thumbnail(at: 0))
        XCTAssertTrue(viewModel.thumbnails.isEmpty)
    }

    func testLoadThumbnailsGeneratesImageFromFixture() async throws {
        let fixtureURL = try Self.packageRoot()
            .appendingPathComponent("Tests/DicomCoreTests/Fixtures/CT/ct_synthetic.dcm")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureURL.path))
        let viewModel = SeriesNavigatorViewModel(seriesURLs: [fixtureURL])

        await viewModel.loadThumbnails(for: [0], maxDimension: 32)

        let thumbnail = try XCTUnwrap(viewModel.thumbnail(at: 0))
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 32)
        XCTAssertEqual(thumbnail.pixels.count, thumbnail.width * thumbnail.height)
        XCTAssertFalse(viewModel.isLoadingThumbnails)
    }

    func testLoadThumbnailsDiscardsResultsAfterSeriesReplacement() async throws {
        let fixtureURL = try Self.packageRoot()
            .appendingPathComponent("Tests/DicomCoreTests/Fixtures/CT/ct_synthetic.dcm")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureURL.path))
        let viewModel = SeriesNavigatorViewModel(seriesURLs: Array(repeating: fixtureURL, count: 3))

        let loadingTask = Task {
            await viewModel.loadThumbnails(for: [0, 1, 2], maxDimension: 32)
        }
        await Task.yield()

        viewModel.setSeriesURLs([fixtureURL])
        await loadingTask.value

        XCTAssertEqual(viewModel.totalCount, 1)
        XCTAssertTrue(viewModel.thumbnails.isEmpty)
        XCTAssertFalse(viewModel.isLoadingThumbnails)
    }

    // MARK: - Sequential Navigation Tests

    func testNavigateFromFirstToLast() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 5)
        viewModel.setSeriesURLs(testURLs)

        // Start at index 0
        XCTAssertEqual(viewModel.currentIndex, 0)

        // Navigate to last using goToNext
        viewModel.goToNext() // index 1
        viewModel.goToNext() // index 2
        viewModel.goToNext() // index 3
        viewModel.goToNext() // index 4

        XCTAssertEqual(viewModel.currentIndex, 4, "Should be at last image")
        XCTAssertTrue(viewModel.isAtLast, "Should be at last")
        XCTAssertFalse(viewModel.canGoNext, "Should not be able to go next")
    }

    func testNavigateFromLastToFirst() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 5)
        viewModel.setSeriesURLs(testURLs, initialIndex: 4)

        // Start at last index
        XCTAssertEqual(viewModel.currentIndex, 4)

        // Navigate to first using goToPrevious
        viewModel.goToPrevious() // index 3
        viewModel.goToPrevious() // index 2
        viewModel.goToPrevious() // index 1
        viewModel.goToPrevious() // index 0

        XCTAssertEqual(viewModel.currentIndex, 0, "Should be at first image")
        XCTAssertTrue(viewModel.isAtFirst, "Should be at first")
        XCTAssertFalse(viewModel.canGoPrevious, "Should not be able to go previous")
    }

    // MARK: - Thread Safety Tests

    func testMainActorIsolation() async {
        // This test verifies that the view model is properly marked with @MainActor
        let viewModel = SeriesNavigatorViewModel()

        // Access properties on main actor
        _ = viewModel.currentIndex
        _ = viewModel.totalCount
        _ = viewModel.seriesURLs
        _ = viewModel.isLoadingThumbnails

        // This confirms @MainActor isolation is working
        XCTAssertTrue(Thread.isMainThread, "Should be on main thread")
    }

    // MARK: - ObservableObject Conformance Tests

    func testPublishedPropertiesArePublished() {
        let viewModel = SeriesNavigatorViewModel()

        // Verify that view model conforms to ObservableObject
        let observable: any ObservableObject = viewModel
        XCTAssertNotNil(observable, "Should conform to ObservableObject")

        // @Published properties should trigger objectWillChange
        let mirror = Mirror(reflecting: viewModel)
        let publishedCount = mirror.children.filter { child in
            String(describing: type(of: child.value)).contains("Published")
        }.count

        XCTAssertGreaterThan(publishedCount, 0, "Should have @Published properties")
    }

    // MARK: - Edge Cases Tests

    func testSingleImageSeries() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 1)
        viewModel.setSeriesURLs(testURLs)

        XCTAssertEqual(viewModel.currentIndex, 0)
        XCTAssertEqual(viewModel.totalCount, 1)
        XCTAssertTrue(viewModel.isAtFirst, "Should be at first with single image")
        XCTAssertTrue(viewModel.isAtLast, "Should be at last with single image")
        XCTAssertFalse(viewModel.canGoNext, "Cannot go next with single image")
        XCTAssertFalse(viewModel.canGoPrevious, "Cannot go previous with single image")
        XCTAssertEqual(viewModel.progressPercentage, 1.0, accuracy: 0.01, "Progress should be 100%")
    }

    func testLargeSeries() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 1000)
        viewModel.setSeriesURLs(testURLs)

        XCTAssertEqual(viewModel.totalCount, 1000)

        // Navigate to middle
        viewModel.goToIndex(500)
        XCTAssertEqual(viewModel.currentIndex, 500)
        XCTAssertTrue(viewModel.canGoNext)
        XCTAssertTrue(viewModel.canGoPrevious)

        // Navigate to last
        viewModel.goToLast()
        XCTAssertEqual(viewModel.currentIndex, 999)
    }

    func testResetAndReload() {
        let viewModel = SeriesNavigatorViewModel()
        let firstSeries = createTestURLs(count: 5)
        let secondSeries = createTestURLs(count: 10)

        // Load first series
        viewModel.setSeriesURLs(firstSeries)
        viewModel.goToIndex(3)

        // Reset
        viewModel.reset()

        // Load second series
        viewModel.setSeriesURLs(secondSeries)

        XCTAssertEqual(viewModel.currentIndex, 0, "Should start at 0 after reload")
        XCTAssertEqual(viewModel.totalCount, 10, "Should have new series count")
    }

    // MARK: - Boundary Condition Tests

    func testRapidNavigationChanges() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 100)
        viewModel.setSeriesURLs(testURLs)

        // Rapidly change navigation in quick succession
        for _ in 0..<20 {
            viewModel.goToNext()
        }

        XCTAssertEqual(viewModel.currentIndex, 20, "Should handle rapid next navigation")

        for _ in 0..<10 {
            viewModel.goToPrevious()
        }

        XCTAssertEqual(viewModel.currentIndex, 10, "Should handle rapid previous navigation")
    }

    func testNavigationWithIntMaxIndex() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 100)
        viewModel.setSeriesURLs(testURLs)

        // Try to navigate to Int.max
        viewModel.goToIndex(Int.max)

        // Should clamp to last valid index
        XCTAssertEqual(viewModel.currentIndex, 99, "Should clamp to last valid index")
    }

    func testNavigationWithIntMinIndex() {
        let viewModel = SeriesNavigatorViewModel()
        let testURLs = createTestURLs(count: 100)
        viewModel.setSeriesURLs(testURLs, initialIndex: 50)

        // Try to navigate to Int.min
        viewModel.goToIndex(Int.min)

        // Should clamp to 0
        XCTAssertEqual(viewModel.currentIndex, 0, "Should clamp to 0")
    }

    func testReplacingSeriesWhileNavigating() {
        let viewModel = SeriesNavigatorViewModel()
        let firstSeries = createTestURLs(count: 10)
        viewModel.setSeriesURLs(firstSeries)

        // Navigate to middle
        viewModel.goToIndex(5)
        XCTAssertEqual(viewModel.currentIndex, 5)

        // Replace with smaller series
        let secondSeries = createTestURLs(count: 3)
        viewModel.setSeriesURLs(secondSeries)

        // Index should reset to 0 (within bounds of new series)
        XCTAssertEqual(viewModel.currentIndex, 0, "Should reset to valid index in new series")
        XCTAssertEqual(viewModel.totalCount, 3, "Should have new series count")
    }

    func testProgressPercentageEdgeCases() {
        let viewModel = SeriesNavigatorViewModel()

        // Test with 1 image
        let singleImage = createTestURLs(count: 1)
        viewModel.setSeriesURLs(singleImage)
        XCTAssertEqual(viewModel.progressPercentage, 1.0, accuracy: 0.01, "Single image should be 100%")

        // Test with 2 images at first
        let twoImages = createTestURLs(count: 2)
        viewModel.setSeriesURLs(twoImages)
        XCTAssertEqual(viewModel.progressPercentage, 0.5, accuracy: 0.01, "First of 2 should be 50%")

        // Navigate to last
        viewModel.goToLast()
        XCTAssertEqual(viewModel.progressPercentage, 1.0, accuracy: 0.01, "Last of 2 should be 100%")
    }

    func testCurrentURLAfterSeriesReplacement() {
        let viewModel = SeriesNavigatorViewModel()
        let firstSeries = createTestURLs(count: 5, seriesName: "series1")
        viewModel.setSeriesURLs(firstSeries)

        let firstURL = viewModel.currentURL
        XCTAssertNotNil(firstURL, "Should have current URL")

        // Replace series
        let secondSeries = createTestURLs(count: 3, seriesName: "series2")
        viewModel.setSeriesURLs(secondSeries)

        let newURL = viewModel.currentURL
        XCTAssertNotNil(newURL, "Should have new current URL")

        // URLs should be different (different series)
        XCTAssertNotEqual(firstURL?.path, newURL?.path, "URL should change with new series")
    }

    func testMultipleThumbnailLoadingCycles() {
        let viewModel = SeriesNavigatorViewModel()

        // Perform multiple loading cycles
        for _ in 0..<5 {
            viewModel.startThumbnailLoading()
            XCTAssertTrue(viewModel.isLoadingThumbnails)

            viewModel.completeThumbnailLoading()
            XCTAssertFalse(viewModel.isLoadingThumbnails)
        }
    }

    func testPositionStringBoundaries() {
        let viewModel = SeriesNavigatorViewModel()

        // Empty series
        XCTAssertEqual(viewModel.positionString, "0 / 0")

        // Single image
        let singleImage = createTestURLs(count: 1)
        viewModel.setSeriesURLs(singleImage)
        XCTAssertEqual(viewModel.positionString, "1 / 1")

        // Large series
        let largeSeries = createTestURLs(count: 9999)
        viewModel.setSeriesURLs(largeSeries)
        XCTAssertEqual(viewModel.positionString, "1 / 9999")

        viewModel.goToLast()
        XCTAssertEqual(viewModel.positionString, "9999 / 9999")
    }

    private static func packageRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default

        while directory.path != "/" {
            if fileManager.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }

        throw NSError(
            domain: "SeriesNavigatorViewModelTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate package root."]
        )
    }
}
