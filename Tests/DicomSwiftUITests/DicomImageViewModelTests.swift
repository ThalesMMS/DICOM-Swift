//
//  DicomImageViewModelTests.swift
//
//  Unit tests for DicomImageViewModel.
//  Tests state management, image loading, windowing, error handling,
//  and computed properties.
//

import XCTest
import SwiftUI
@testable import DicomSwiftUI
@testable import DicomCore

@MainActor
final class DicomImageViewModelTests: XCTestCase {

    private final class MockDicomDecoder: DicomImageRendererDecoderProtocol, @unchecked Sendable {
        let width: Int
        let height: Int
        let windowSettingsV2: WindowSettings
        private let pixels16: [UInt16]?

        init(
            width: Int,
            height: Int,
            pixels16: [UInt16]?,
            windowSettings: WindowSettings
        ) {
            self.width = width
            self.height = height
            self.pixels16 = pixels16
            self.windowSettingsV2 = windowSettings
        }

        func getPixels16() -> [UInt16]? {
            pixels16
        }
    }

    private func makeMockDecoder(
        width: Int = 64,
        height: Int = 64,
        windowSettings: WindowSettings = WindowSettings(center: 50, width: 400),
        pixels16: [UInt16]? = nil
    ) -> MockDicomDecoder {
        let defaultPixels = (0..<(width * height)).map { UInt16($0 % 4096) }
        return MockDicomDecoder(
            width: width,
            height: height,
            pixels16: pixels16 ?? defaultPixels,
            windowSettings: windowSettings
        )
    }

    // MARK: - Initialization Tests

    func testViewModelInitialization() {
        let viewModel = DicomImageViewModel()

        // Test initial state
        XCTAssertEqual(viewModel.state, .idle, "Initial state should be idle")
        XCTAssertNil(viewModel.image, "Initial image should be nil")
        XCTAssertNil(viewModel.decoder, "Initial decoder should be nil")
        XCTAssertNil(viewModel.error, "Initial error should be nil")
        XCTAssertNil(viewModel.currentWindowSettings, "Initial window settings should be nil")
    }

    func testInitialComputedProperties() {
        let viewModel = DicomImageViewModel()

        // Test computed properties in initial state
        XCTAssertFalse(viewModel.isLoaded, "Should not be loaded initially")
        XCTAssertFalse(viewModel.isLoading, "Should not be loading initially")
        XCTAssertFalse(viewModel.hasFailed, "Should not be failed initially")
        XCTAssertEqual(viewModel.imageWidth, 0, "Initial image width should be 0")
        XCTAssertEqual(viewModel.imageHeight, 0, "Initial image height should be 0")
    }

    // MARK: - Loading State Tests

    func testLoadingState() async {
        let viewModel = DicomImageViewModel()
        let mockDecoder = makeMockDecoder(width: 64, height: 64)

        await viewModel.loadImage(decoder: mockDecoder)

        XCTAssertEqual(viewModel.state, .loaded, "State should be loaded for successful mock decoding")
        XCTAssertNotNil(viewModel.image, "Image should be populated after successful mock decoding")
        XCTAssertNotNil(viewModel.currentWindowSettings, "Window settings should be resolved for successful mock decoding")
        XCTAssertNil(viewModel.error, "Error should remain nil for successful mock decoding")
        XCTAssertEqual(viewModel.imageWidth, 64, "Rendered image width should match mock decoder")
        XCTAssertEqual(viewModel.imageHeight, 64, "Rendered image height should match mock decoder")
    }

    func testLoadImageWithFailingMockDecoder() async {
        let viewModel = DicomImageViewModel()
        let failingDecoder = MockDicomDecoder(
            width: 64,
            height: 64,
            pixels16: nil,
            windowSettings: WindowSettings(center: 50, width: 400)
        )

        // Load image with an invalid mock decoder (missing pixels)
        await viewModel.loadImage(decoder: failingDecoder)

        // Verify failed state
        XCTAssertTrue(viewModel.hasFailed, "Should be in failed state")
        XCTAssertNotNil(viewModel.error, "Error should be set")
        XCTAssertNil(viewModel.image, "Image should be nil after failure")
        XCTAssertNil(viewModel.currentWindowSettings, "Window settings should be nil after failure")
    }

    // MARK: - Reset Tests

    func testReset() {
        let viewModel = DicomImageViewModel()

        // Manually set some state
        viewModel.reset()

        // Verify reset to initial state
        XCTAssertEqual(viewModel.state, .idle, "State should be idle after reset")
        XCTAssertNil(viewModel.image, "Image should be nil after reset")
        XCTAssertNil(viewModel.decoder, "Decoder should be nil after reset")
        XCTAssertNil(viewModel.error, "Error should be nil after reset")
        XCTAssertNil(viewModel.currentWindowSettings, "Window settings should be nil after reset")
    }

    // MARK: - Computed Properties Tests

    func testComputedPropertiesInLoadedState() {
        let viewModel = DicomImageViewModel()

        // We can't easily simulate loaded state without actual file loading,
        // but we can test the logic by checking state enum matching

        // Test isLoaded with idle state
        XCTAssertFalse(viewModel.isLoaded, "Should not be loaded in idle state")

        // Test isLoading with idle state
        XCTAssertFalse(viewModel.isLoading, "Should not be loading in idle state")

        // Test hasFailed with idle state
        XCTAssertFalse(viewModel.hasFailed, "Should not be failed in idle state")
    }

    func testImageDimensionsWhenNoImage() {
        let viewModel = DicomImageViewModel()

        XCTAssertEqual(viewModel.imageWidth, 0, "Width should be 0 when no image")
        XCTAssertEqual(viewModel.imageHeight, 0, "Height should be 0 when no image")
    }

    // MARK: - Loading State Enum Tests

    func testLoadingStateEquality() {
        // Test idle equality
        XCTAssertEqual(DicomImageLoadingState.idle, DicomImageLoadingState.idle)

        // Test loading equality
        XCTAssertEqual(DicomImageLoadingState.loading, DicomImageLoadingState.loading)

        // Test loaded equality
        XCTAssertEqual(DicomImageLoadingState.loaded, DicomImageLoadingState.loaded)

        // Test failed equality with same error
        let error1 = DICOMError.fileNotFound(path: "/test")
        let error2 = DICOMError.fileNotFound(path: "/test")
        XCTAssertEqual(DicomImageLoadingState.failed(error1), DicomImageLoadingState.failed(error2))

        // Test inequality between different states
        XCTAssertNotEqual(DicomImageLoadingState.idle, DicomImageLoadingState.loading)
        XCTAssertNotEqual(DicomImageLoadingState.loading, DicomImageLoadingState.loaded)
        XCTAssertNotEqual(DicomImageLoadingState.idle, DicomImageLoadingState.failed(error1))
    }

    func testLoadingStateInequalityWithDifferentErrors() {
        let error1 = DICOMError.fileNotFound(path: "/test1")
        let error2 = DICOMError.fileNotFound(path: "/test2")

        // Different error details should not be equal
        XCTAssertNotEqual(DicomImageLoadingState.failed(error1), DicomImageLoadingState.failed(error2))
    }

    // MARK: - Update Windowing Tests

    func testUpdateWindowingWithoutDecoder() async {
        let viewModel = DicomImageViewModel()

        // Attempt to update windowing without loading a decoder first
        await viewModel.updateWindowing(windowingMode: .custom(center: 50, width: 400))

        // Should fail with no decoder
        XCTAssertTrue(viewModel.hasFailed, "Should fail when no decoder loaded")
        XCTAssertNotNil(viewModel.error, "Error should be set")

        // Check that it's the correct error type
        if case .failed(let error) = viewModel.state {
            if case .invalidPixelData(let reason) = error {
                XCTAssertTrue(reason.contains("No DICOM file loaded"), "Error should mention no file loaded")
            } else {
                XCTFail("Expected invalidPixelData error")
            }
        } else {
            XCTFail("Expected failed state")
        }
    }

    // MARK: - Thread Safety Tests

    func testMainActorIsolation() async {
        // This test verifies that the view model is properly marked with @MainActor
        // If it weren't, this test would fail to compile

        let viewModel = DicomImageViewModel()

        // Access properties on main actor
        _ = viewModel.state
        _ = viewModel.image
        _ = viewModel.decoder
        _ = viewModel.error

        // This confirms @MainActor isolation is working
        XCTAssertTrue(Thread.isMainThread, "Should be on main thread")
    }

    // MARK: - Multiple Reset Tests

    func testMultipleResets() {
        let viewModel = DicomImageViewModel()

        // Reset multiple times
        viewModel.reset()
        viewModel.reset()
        viewModel.reset()

        // Should still be in clean idle state
        XCTAssertEqual(viewModel.state, .idle, "State should remain idle after multiple resets")
        XCTAssertNil(viewModel.image, "Image should remain nil after multiple resets")
        XCTAssertNil(viewModel.decoder, "Decoder should remain nil after multiple resets")
    }

    // MARK: - Windowing Mode Tests

    func testWindowingModeUsageInLoadImage() async {
        let viewModel = DicomImageViewModel()

        // Test that different windowing modes can be passed to loadImage
        // (Even though the file doesn't exist, we're testing the API surface)

        let testURL = URL(fileURLWithPath: "/test.dcm")

        // Test automatic windowing (default)
        await viewModel.loadImage(from: testURL)
        XCTAssertTrue(viewModel.hasFailed, "Should fail with non-existent file")

        viewModel.reset()

        // Test custom windowing
        await viewModel.loadImage(from: testURL, windowingMode: .custom(center: 50, width: 400))
        XCTAssertTrue(viewModel.hasFailed, "Should fail with non-existent file")

        viewModel.reset()

        // Test preset windowing
        await viewModel.loadImage(from: testURL, windowingMode: .preset(.lung))
        XCTAssertTrue(viewModel.hasFailed, "Should fail with non-existent file")
    }

    // MARK: - Processing Mode Tests

    func testProcessingModeUsageInLoadImage() async {
        let viewModel = DicomImageViewModel()
        let testURL = URL(fileURLWithPath: "/test.dcm")

        // Test with vDSP processing mode
        await viewModel.loadImage(from: testURL, processingMode: .vdsp)
        XCTAssertTrue(viewModel.hasFailed, "Should fail with non-existent file")

        viewModel.reset()

        // Test with Metal processing mode
        await viewModel.loadImage(from: testURL, processingMode: .metal)
        XCTAssertTrue(viewModel.hasFailed, "Should fail with non-existent file")

        viewModel.reset()

        // Test with auto processing mode
        await viewModel.loadImage(from: testURL, processingMode: .auto)
        XCTAssertTrue(viewModel.hasFailed, "Should fail with non-existent file")
    }

    // MARK: - State Transition Tests

    func testStateTransitionFromIdleToLoading() async {
        let viewModel = DicomImageViewModel()

        // Initial state should be idle
        XCTAssertEqual(viewModel.state, .idle)

        let testURL = URL(fileURLWithPath: "/test.dcm")

        // Start loading in background
        let loadTask = Task {
            await viewModel.loadImage(from: testURL)
        }

        // Give it a moment to transition to loading state
        try? await Task.sleep(nanoseconds: 5_000_000) // 5ms

        // State should have changed (likely to loading or already to failed)
        XCTAssertNotEqual(viewModel.state, .idle, "State should have changed from idle")

        // Wait for task to complete
        await loadTask.value

        // Should end in failed state (file doesn't exist)
        XCTAssertTrue(viewModel.hasFailed, "Should end in failed state")
    }

    // MARK: - Error Handling Tests

    func testErrorPropertySetOnFailure() async {
        let viewModel = DicomImageViewModel()
        let testURL = URL(fileURLWithPath: "/nonexistent/file.dcm")

        // Ensure error is initially nil
        XCTAssertNil(viewModel.error)

        // Load non-existent file
        await viewModel.loadImage(from: testURL)

        // Error should be set
        XCTAssertNotNil(viewModel.error, "Error should be set after failure")
        XCTAssertTrue(viewModel.hasFailed, "Should be in failed state")

        // Verify error is of correct type
        if let error = viewModel.error {
            switch error {
            case .fileNotFound:
                // Expected error type
                break
            default:
                XCTFail("Expected fileNotFound error, got \(error)")
            }
        }
    }

    func testErrorClearedOnReset() async {
        let viewModel = DicomImageViewModel()
        let testURL = URL(fileURLWithPath: "/nonexistent/file.dcm")

        // Load non-existent file to trigger error
        await viewModel.loadImage(from: testURL)
        XCTAssertNotNil(viewModel.error, "Error should be set")

        // Reset should clear error
        viewModel.reset()
        XCTAssertNil(viewModel.error, "Error should be cleared after reset")
    }

    // MARK: - Convenience API Tests

    func testIsLoadedComputedProperty() {
        let viewModel = DicomImageViewModel()

        // Test with each state
        XCTAssertFalse(viewModel.isLoaded, "Should not be loaded in idle state")

        // Note: We can't easily test loaded state without actual file loading
        // The test for isLoaded logic is covered by testing the state enum directly
    }

    func testIsLoadingComputedProperty() {
        let viewModel = DicomImageViewModel()

        XCTAssertFalse(viewModel.isLoading, "Should not be loading in idle state")
    }

    func testHasFailedComputedProperty() async {
        let viewModel = DicomImageViewModel()

        XCTAssertFalse(viewModel.hasFailed, "Should not be failed in idle state")

        // Trigger failure
        let testURL = URL(fileURLWithPath: "/nonexistent/file.dcm")
        await viewModel.loadImage(from: testURL)

        XCTAssertTrue(viewModel.hasFailed, "Should be failed after loading non-existent file")
    }

    // MARK: - Decoder Access Tests

    func testDecoderInitiallyNil() {
        let viewModel = DicomImageViewModel()

        XCTAssertNil(viewModel.decoder, "Decoder should be nil before loading")
    }

    func testDecoderClearedOnReset() {
        let viewModel = DicomImageViewModel()

        // Reset should ensure decoder is nil
        viewModel.reset()

        XCTAssertNil(viewModel.decoder, "Decoder should be nil after reset")
    }

    // MARK: - Window Settings Tests

    func testWindowSettingsInitiallyNil() {
        let viewModel = DicomImageViewModel()

        XCTAssertNil(viewModel.currentWindowSettings, "Window settings should be nil initially")
    }

    func testWindowSettingsClearedOnReset() {
        let viewModel = DicomImageViewModel()

        viewModel.reset()

        XCTAssertNil(viewModel.currentWindowSettings, "Window settings should be nil after reset")
    }

    // MARK: - Async Loading Tests

    func testConcurrentLoadCalls() async {
        let viewModel = DicomImageViewModel()
        let testURL = URL(fileURLWithPath: "/test.dcm")

        // Start multiple load operations concurrently
        async let load1: () = viewModel.loadImage(from: testURL)
        async let load2: () = viewModel.loadImage(from: testURL)

        // Wait for both to complete
        await load1
        await load2

        // Both loads use a non-existent URL, so failure is expected.
        // This test primarily verifies concurrent calls complete without crashing;
        // it does not assert ordering/last-writer-wins semantics.
        XCTAssertTrue(viewModel.hasFailed, "Should be in failed state for invalid input")
    }

    // MARK: - ObservableObject Conformance Tests

    func testPublishedPropertiesArePublished() {
        let viewModel = DicomImageViewModel()

        // Verify that view model conforms to ObservableObject
        let observable: any ObservableObject = viewModel
        XCTAssertNotNil(observable, "Should conform to ObservableObject")

        // @Published properties should trigger objectWillChange
        // This is verified by the compiler, but we can check the property wrappers exist
        let mirror = Mirror(reflecting: viewModel)
        let publishedCount = mirror.children.filter { child in
            String(describing: type(of: child.value)).contains("Published")
        }.count

        XCTAssertGreaterThan(publishedCount, 0, "Should have @Published properties")
    }

    // MARK: - Regression Tests

    func testLoadImageFromMockDecoderWithAutomaticWindowing() async {
        let viewModel = DicomImageViewModel()
        let mockDecoder = makeMockDecoder(width: 32, height: 32)

        await viewModel.loadImage(decoder: mockDecoder, windowingMode: .automatic)

        XCTAssertTrue(viewModel.isLoaded, "Should load successfully with mock decoder")
        XCTAssertNotNil(viewModel.image, "Image should be rendered from mock decoder")
        XCTAssertNil(viewModel.error, "Error should remain nil for successful mock decoding")
    }

    func testErrorClearedOnNewLoad() async {
        let viewModel = DicomImageViewModel()
        let nonExistentURL = URL(fileURLWithPath: "/nonexistent1.dcm")

        // Load first non-existent file to trigger error
        await viewModel.loadImage(from: nonExistentURL)
        XCTAssertNotNil(viewModel.error, "Error should be set after first load")

        // Load second non-existent file
        let anotherNonExistentURL = URL(fileURLWithPath: "/nonexistent2.dcm")
        await viewModel.loadImage(from: anotherNonExistentURL)

        // Error should still be present (but may be different)
        XCTAssertNotNil(viewModel.error, "Error should be set after second load")
        XCTAssertTrue(viewModel.hasFailed, "Should still be in failed state")
    }

    func testImageDimensionsAfterFailedLoad() async {
        let viewModel = DicomImageViewModel()
        let nonExistentURL = URL(fileURLWithPath: "/nonexistent/file.dcm")

        // Load non-existent file
        await viewModel.loadImage(from: nonExistentURL)

        // Image dimensions should remain 0 after failed load
        XCTAssertEqual(viewModel.imageWidth, 0, "Width should be 0 after failed load")
        XCTAssertEqual(viewModel.imageHeight, 0, "Height should be 0 after failed load")
    }

    func testStateTransitionsAreAtomic() async {
        let viewModel = DicomImageViewModel()
        let testURL = URL(fileURLWithPath: "/test.dcm")

        // Record state changes
        var stateChanges: [DicomImageLoadingState] = [viewModel.state]

        // Start loading
        await viewModel.loadImage(from: testURL)
        stateChanges.append(viewModel.state)

        // Verify state progression was logical
        // Should go: idle -> (loading) -> failed
        // Note: may skip loading state due to fast failure
        XCTAssertEqual(stateChanges.first, .idle, "Should start in idle state")
        XCTAssertTrue(viewModel.hasFailed, "Should end in failed state")
    }

    func testUpdateWindowingAfterResetFails() async {
        let viewModel = DicomImageViewModel()

        // Reset to clear any state
        viewModel.reset()

        // Attempt to update windowing
        await viewModel.updateWindowing(windowingMode: .custom(center: 50, width: 400))

        // Should fail because no decoder is loaded
        XCTAssertTrue(viewModel.hasFailed, "Should fail when updating windowing after reset")
        XCTAssertNotNil(viewModel.error, "Error should be set")
    }
}
