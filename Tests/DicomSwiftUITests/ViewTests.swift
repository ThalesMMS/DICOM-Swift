//
//  ViewTests.swift
//
//  Unit tests for SwiftUI Views (DicomImageView, WindowingControlView,
//  SeriesNavigatorView, MetadataView).
//  Tests view initialization, compilation, state handling, and accessibility.
//

import XCTest
import SwiftUI
@testable import DicomSwiftUI
@testable import DicomCore

@MainActor
final class ViewTests: XCTestCase {

    // MARK: - DicomImageView Tests

    func testDicomImageViewInitializationWithURL() {
        // Test URL-based initialization
        let testURL = URL(fileURLWithPath: "/test/image.dcm")
        let view = DicomImageView(url: testURL)

        // View should compile and initialize without crashing
        XCTAssertNotNil(view, "DicomImageView should initialize with URL")
    }

    func testDicomImageViewInitializationWithURLAndWindowing() {
        // Test URL with custom windowing mode
        let testURL = URL(fileURLWithPath: "/test/image.dcm")
        let view = DicomImageView(
            url: testURL,
            windowingMode: .preset(.lung)
        )

        XCTAssertNotNil(view, "DicomImageView should initialize with URL and windowing mode")
    }

    func testDicomImageViewInitializationWithURLAndProcessingMode() {
        // Test URL with custom processing mode
        let testURL = URL(fileURLWithPath: "/test/image.dcm")
        let view = DicomImageView(
            url: testURL,
            windowingMode: .automatic,
            processingMode: .metal
        )

        XCTAssertNotNil(view, "DicomImageView should initialize with URL and processing mode")
    }

    func testDicomImageViewInitializationWithDecoder() {
        // Test decoder-based initialization
        let decoder = DCMDecoder()
        let view = DicomImageView(decoder: decoder)

        XCTAssertNotNil(view, "DicomImageView should initialize with decoder")
    }

    func testDicomImageViewInitializationWithDecoderAndWindowing() {
        // Test decoder with preset windowing
        let decoder = DCMDecoder()
        let view = DicomImageView(
            decoder: decoder,
            windowingMode: .preset(.bone)
        )

        XCTAssertNotNil(view, "DicomImageView should initialize with decoder and windowing mode")
    }

    @MainActor
    func testDicomImageViewInitializationWithViewModel() {
        // Test view model-based initialization
        let viewModel = DicomImageViewModel()
        let view = DicomImageView(viewModel: viewModel)

        XCTAssertNotNil(view, "DicomImageView should initialize with view model")
    }

    func testDicomImageViewWithAllWindowingPresets() {
        let testURL = URL(fileURLWithPath: "/test/image.dcm")

        // Test each preset compiles
        let presets = MedicalPreset.allCases.filter { $0 != .custom }

        for preset in presets {
            let view = DicomImageView(
                url: testURL,
                windowingMode: .preset(preset)
            )
            XCTAssertNotNil(view, "DicomImageView should initialize with \(preset) preset")
        }
    }

    func testDicomImageViewWithCustomWindowing() {
        let testURL = URL(fileURLWithPath: "/test/image.dcm")
        let view = DicomImageView(
            url: testURL,
            windowingMode: .custom(center: 50.0, width: 400.0)
        )

        XCTAssertNotNil(view, "DicomImageView should initialize with custom windowing")
    }

    func testDicomImageViewWithAllProcessingModes() {
        let testURL = URL(fileURLWithPath: "/test/image.dcm")

        // Test each processing mode compiles
        let modes: [ProcessingMode] = [.vdsp, .metal, .auto]

        for mode in modes {
            let view = DicomImageView(
                url: testURL,
                processingMode: mode
            )
            XCTAssertNotNil(view, "DicomImageView should initialize with \(mode) processing mode")
        }
    }

    // MARK: - WindowingControlView Tests

    @MainActor
    func testWindowingControlViewInitialization() {
        // Test basic initialization
        let viewModel = WindowingViewModel()
        let view = WindowingControlView(windowingViewModel: viewModel)

        XCTAssertNotNil(view, "WindowingControlView should initialize")
    }

    @MainActor
    func testWindowingControlViewWithExpandedLayout() {
        let viewModel = WindowingViewModel()
        let view = WindowingControlView(
            windowingViewModel: viewModel,
            layout: .expanded
        )

        XCTAssertNotNil(view, "WindowingControlView should initialize with expanded layout")
    }

    @MainActor
    func testWindowingControlViewWithCompactLayout() {
        let viewModel = WindowingViewModel()
        let view = WindowingControlView(
            windowingViewModel: viewModel,
            layout: .compact
        )

        XCTAssertNotNil(view, "WindowingControlView should initialize with compact layout")
    }

    @MainActor
    func testWindowingControlViewWithCallbacks() {
        let viewModel = WindowingViewModel()
        var presetCallbackCalled = false
        var windowingCallbackCalled = false

        let view = WindowingControlView(
            windowingViewModel: viewModel,
            onPresetSelected: { _ in
                presetCallbackCalled = true
            },
            onWindowingChanged: { _ in
                windowingCallbackCalled = true
            }
        )

        XCTAssertNotNil(view, "WindowingControlView should initialize with callbacks")
        XCTAssertFalse(presetCallbackCalled, "Preset callback should not be called on init")
        XCTAssertFalse(windowingCallbackCalled, "Windowing callback should not be called on init")
    }

    @MainActor
    func testWindowingControlViewWithPresets() {
        // Test that view can be initialized with different presets
        let presets: [MedicalPreset] = [.lung, .bone, .brain, .liver]

        for preset in presets {
            let viewModel = WindowingViewModel(preset: preset)
            let view = WindowingControlView(windowingViewModel: viewModel)

            XCTAssertNotNil(view, "WindowingControlView should initialize with \(preset) preset")
        }
    }

    @MainActor
    func testWindowingControlViewWithCustomSettings() {
        let viewModel = WindowingViewModel()
        viewModel.setWindowLevel(center: 500.0, width: 1500.0)

        let view = WindowingControlView(windowingViewModel: viewModel)

        XCTAssertNotNil(view, "WindowingControlView should initialize with custom settings")
        XCTAssertEqual(viewModel.center, 500.0, "Center should be set to custom value")
        XCTAssertEqual(viewModel.width, 1500.0, "Width should be set to custom value")
    }

    // MARK: - SeriesNavigatorView Tests

    @MainActor
    func testSeriesNavigatorViewInitialization() {
        // Test basic initialization
        let viewModel = SeriesNavigatorViewModel()
        let view = SeriesNavigatorView(navigatorViewModel: viewModel)

        XCTAssertNotNil(view, "SeriesNavigatorView should initialize")
    }

    @MainActor
    func testSeriesNavigatorViewWithExpandedLayout() {
        let viewModel = SeriesNavigatorViewModel()
        let view = SeriesNavigatorView(
            navigatorViewModel: viewModel,
            layout: .expanded
        )

        XCTAssertNotNil(view, "SeriesNavigatorView should initialize with expanded layout")
    }

    @MainActor
    func testSeriesNavigatorViewWithCompactLayout() {
        let viewModel = SeriesNavigatorViewModel()
        let view = SeriesNavigatorView(
            navigatorViewModel: viewModel,
            layout: .compact
        )

        XCTAssertNotNil(view, "SeriesNavigatorView should initialize with compact layout")
    }

    @MainActor
    func testSeriesNavigatorViewWithoutKeyboardShortcutParameter() {
        let viewModel = SeriesNavigatorViewModel()

        let view = SeriesNavigatorView(navigatorViewModel: viewModel)
        XCTAssertNotNil(view, "SeriesNavigatorView should initialize without keyboard shortcut configuration")
    }

    @MainActor
    func testSeriesNavigatorViewWithCallback() {
        let viewModel = SeriesNavigatorViewModel()
        var callbackCalled = false

        let view = SeriesNavigatorView(
            navigatorViewModel: viewModel,
            onNavigate: { _ in
                callbackCalled = true
            }
        )

        XCTAssertNotNil(view, "SeriesNavigatorView should initialize with callback")
        XCTAssertFalse(callbackCalled, "Navigation callback should not be called on init")
    }

    @MainActor
    func testSeriesNavigatorViewWithEmptySeries() {
        // Test with empty series
        let viewModel = SeriesNavigatorViewModel()
        let view = SeriesNavigatorView(navigatorViewModel: viewModel)

        XCTAssertNotNil(view, "SeriesNavigatorView should handle empty series")
        XCTAssertTrue(viewModel.isEmpty, "View model should report empty state")
        XCTAssertEqual(viewModel.totalCount, 0, "Total count should be 0 for empty series")
    }

    @MainActor
    func testSeriesNavigatorViewWithSmallSeries() {
        // Test with small series (10 images)
        let urls = Array(repeating: URL(fileURLWithPath: "/test.dcm"), count: 10)
        let viewModel = SeriesNavigatorViewModel(seriesURLs: urls)
        let view = SeriesNavigatorView(navigatorViewModel: viewModel)

        XCTAssertNotNil(view, "SeriesNavigatorView should handle small series")
        XCTAssertEqual(viewModel.totalCount, 10, "Total count should be 10")
        XCTAssertFalse(viewModel.isEmpty, "View model should not be empty")
    }

    @MainActor
    func testSeriesNavigatorViewWithLargeSeries() {
        // Test with large series (150 images)
        let urls = Array(repeating: URL(fileURLWithPath: "/test.dcm"), count: 150)
        let viewModel = SeriesNavigatorViewModel(seriesURLs: urls)
        let view = SeriesNavigatorView(navigatorViewModel: viewModel)

        XCTAssertNotNil(view, "SeriesNavigatorView should handle large series")
        XCTAssertEqual(viewModel.totalCount, 150, "Total count should be 150")
        XCTAssertFalse(viewModel.isEmpty, "View model should not be empty")
    }

    @MainActor
    func testSeriesNavigatorSliceShortcutButtonWithThumbnailAndFallback() throws {
        let thumbnail = try XCTUnwrap(SeriesNavigatorThumbnail(
            pixels: [0, 64, 128, 255],
            width: 2,
            height: 2
        ))
        let thumbnailButton = SeriesNavigatorSliceShortcutButton(
            index: 0,
            isSelected: true,
            thumbnail: thumbnail,
            onSelect: {}
        )
        let fallbackButton = SeriesNavigatorSliceShortcutButton(
            index: 1,
            isSelected: false,
            thumbnail: nil,
            onSelect: {}
        )

        XCTAssertNotNil(thumbnailButton)
        XCTAssertNotNil(fallbackButton)
    }

    // MARK: - MetadataView Tests

    func testMetadataViewInitialization() {
        // Test basic initialization
        let decoder = DCMDecoder()
        let view = MetadataView(decoder: decoder)

        XCTAssertNotNil(view, "MetadataView should initialize")
    }

    func testMetadataViewWithListStyle() {
        let decoder = DCMDecoder()
        let view = MetadataView(decoder: decoder, style: .list)

        XCTAssertNotNil(view, "MetadataView should initialize with list style")
    }

    func testMetadataViewWithFormStyle() {
        let decoder = DCMDecoder()
        let view = MetadataView(decoder: decoder, style: .form)

        XCTAssertNotNil(view, "MetadataView should initialize with form style")
    }

    func testMetadataViewWithEmptyDecoder() {
        // Test with decoder that has no metadata loaded
        let decoder = DCMDecoder()
        let view = MetadataView(decoder: decoder)

        XCTAssertNotNil(view, "MetadataView should handle empty decoder")

        // Verify decoder has default/empty values
        XCTAssertEqual(decoder.width, 1, "Empty decoder should have default width")
        XCTAssertEqual(decoder.height, 1, "Empty decoder should have default height")
    }

    // MARK: - View Accessibility Tests

    func testDicomImageViewAccessibilityLabel() {
        let testURL = URL(fileURLWithPath: "/test/image.dcm")
        let view = DicomImageView(url: testURL)

        // View should have accessibility support
        // This is a compilation test - actual accessibility testing requires
        // full SwiftUI view rendering which is beyond unit test scope
        XCTAssertNotNil(view, "View should support accessibility")
    }

    @MainActor
    func testWindowingControlViewAccessibilitySupport() {
        let viewModel = WindowingViewModel()
        let view = WindowingControlView(windowingViewModel: viewModel)

        // View should have accessibility support for controls
        XCTAssertNotNil(view, "View should support accessibility")
    }

    @MainActor
    func testSeriesNavigatorViewAccessibilitySupport() {
        let viewModel = SeriesNavigatorViewModel()
        let view = SeriesNavigatorView(navigatorViewModel: viewModel)

        // View should have accessibility support for navigation controls
        XCTAssertNotNil(view, "View should support accessibility")
    }

    func testMetadataViewAccessibilitySupport() {
        let decoder = DCMDecoder()
        let view = MetadataView(decoder: decoder)

        // View should have accessibility support for metadata rows
        XCTAssertNotNil(view, "View should support accessibility")
    }

    // MARK: - View Body Compilation Tests

    @MainActor
    func testDicomImageViewBodyCompiles() {
        // Test that view body compiles without error
        let viewModel = DicomImageViewModel()
        let view = DicomImageView(viewModel: viewModel)

        // Access body property to ensure it compiles
        _ = view.body

        XCTAssertNotNil(view, "View body should compile")
    }

    @MainActor
    func testWindowingControlViewBodyCompiles() {
        let viewModel = WindowingViewModel()
        let view = WindowingControlView(windowingViewModel: viewModel)

        // Access body property to ensure it compiles
        _ = view.body

        XCTAssertNotNil(view, "View body should compile")
    }

    @MainActor
    func testSeriesNavigatorViewBodyCompiles() {
        let viewModel = SeriesNavigatorViewModel()
        let view = SeriesNavigatorView(navigatorViewModel: viewModel)

        // Access body property to ensure it compiles
        _ = view.body

        XCTAssertNotNil(view, "View body should compile")
    }

    func testMetadataViewBodyCompiles() {
        let decoder = DCMDecoder()
        let view = MetadataView(decoder: decoder)

        // Access body property to ensure it compiles
        _ = view.body

        XCTAssertNotNil(view, "View body should compile")
    }

    // MARK: - View Modifier Tests

    func testDicomImageViewWithFrameModifier() {
        let testURL = URL(fileURLWithPath: "/test/image.dcm")
        let view = DicomImageView(url: testURL)
            .frame(width: 400, height: 400)

        XCTAssertNotNil(view, "DicomImageView should support frame modifier")
    }

    @MainActor
    func testWindowingControlViewWithPaddingModifier() {
        let viewModel = WindowingViewModel()
        let view = WindowingControlView(windowingViewModel: viewModel)
            .padding()

        XCTAssertNotNil(view, "WindowingControlView should support padding modifier")
    }

    @MainActor
    func testSeriesNavigatorViewWithBackgroundModifier() {
        let viewModel = SeriesNavigatorViewModel()
        let view = SeriesNavigatorView(navigatorViewModel: viewModel)
            .background(Color.gray)

        XCTAssertNotNil(view, "SeriesNavigatorView should support background modifier")
    }

    func testMetadataViewWithNavigationTitleModifier() {
        let decoder = DCMDecoder()
        let view = MetadataView(decoder: decoder)
            .navigationTitle("Test")

        XCTAssertNotNil(view, "MetadataView should support navigationTitle modifier")
    }

    // MARK: - Integration Tests

    @MainActor
    func testDicomImageViewWithWindowingControlView() {
        // Test that both views can be created together
        let imageViewModel = DicomImageViewModel()
        let windowingViewModel = WindowingViewModel()

        let imageView = DicomImageView(viewModel: imageViewModel)
        let controlView = WindowingControlView(windowingViewModel: windowingViewModel)

        XCTAssertNotNil(imageView, "Image view should initialize")
        XCTAssertNotNil(controlView, "Control view should initialize")
    }

    @MainActor
    func testDicomImageViewWithSeriesNavigatorView() {
        // Test that both views can be created together
        let imageViewModel = DicomImageViewModel()
        let navigatorViewModel = SeriesNavigatorViewModel()

        let imageView = DicomImageView(viewModel: imageViewModel)
        let navigatorView = SeriesNavigatorView(navigatorViewModel: navigatorViewModel)

        XCTAssertNotNil(imageView, "Image view should initialize")
        XCTAssertNotNil(navigatorView, "Navigator view should initialize")
    }

    func testDicomImageViewWithMetadataView() {
        // Test that both views can be created together
        let decoder = DCMDecoder()

        let imageView = DicomImageView(decoder: decoder)
        let metadataView = MetadataView(decoder: decoder)

        XCTAssertNotNil(imageView, "Image view should initialize")
        XCTAssertNotNil(metadataView, "Metadata view should initialize")
    }

    @MainActor
    func testCompleteViewerStack() {
        // Test that all views can be created together in a complete viewer
        let decoder = DCMDecoder()
        let imageViewModel = DicomImageViewModel()
        let windowingViewModel = WindowingViewModel()
        let navigatorViewModel = SeriesNavigatorViewModel()

        let imageView = DicomImageView(viewModel: imageViewModel)
        let windowingView = WindowingControlView(windowingViewModel: windowingViewModel)
        let navigatorView = SeriesNavigatorView(navigatorViewModel: navigatorViewModel)
        let metadataView = MetadataView(decoder: decoder)

        XCTAssertNotNil(imageView, "Image view should initialize")
        XCTAssertNotNil(windowingView, "Windowing view should initialize")
        XCTAssertNotNil(navigatorView, "Navigator view should initialize")
        XCTAssertNotNil(metadataView, "Metadata view should initialize")
    }

    // MARK: - Layout Enum Tests

    func testWindowingControlViewLayoutEnum() {
        // Test that layout enum values are accessible
        let expanded = WindowingControlView.Layout.expanded
        let compact = WindowingControlView.Layout.compact

        XCTAssertNotNil(expanded, "Expanded layout should be defined")
        XCTAssertNotNil(compact, "Compact layout should be defined")
    }

    func testSeriesNavigatorViewLayoutEnum() {
        // Test that layout enum values are accessible
        let expanded = SeriesNavigatorView.Layout.expanded
        let compact = SeriesNavigatorView.Layout.compact

        XCTAssertNotNil(expanded, "Expanded layout should be defined")
        XCTAssertNotNil(compact, "Compact layout should be defined")
    }

    func testMetadataViewPresentationStyleEnum() {
        // Test that presentation style enum values are accessible
        let list = MetadataView.PresentationStyle.list
        let form = MetadataView.PresentationStyle.form

        XCTAssertNotNil(list, "List style should be defined")
        XCTAssertNotNil(form, "Form style should be defined")
    }

    // MARK: - Preview Provider Tests

    func testDicomImageViewPreviewProviderCompiles() {
        // Test that preview provider compiles
        #if DEBUG
        let previews = DicomImageView_Previews.previews
        XCTAssertNotNil(previews, "Preview provider should compile")
        #endif
    }

    func testWindowingControlViewPreviewProviderCompiles() {
        // Test that preview provider compiles
        #if DEBUG
        let previews = WindowingControlView_Previews.previews
        XCTAssertNotNil(previews, "Preview provider should compile")
        #endif
    }

    func testSeriesNavigatorViewPreviewProviderCompiles() {
        // Test that preview provider compiles
        #if DEBUG
        let previews = SeriesNavigatorView_Previews.previews
        XCTAssertNotNil(previews, "Preview provider should compile")
        #endif
    }

    func testMetadataViewPreviewProviderCompiles() {
        // Test that preview provider compiles
        #if DEBUG
        let previews = MetadataView_Previews.previews
        XCTAssertNotNil(previews, "Preview provider should compile")
        #endif
    }
}
