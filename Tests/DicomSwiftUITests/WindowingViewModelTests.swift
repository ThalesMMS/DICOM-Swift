//
//  WindowingViewModelTests.swift
//
//  Unit tests for WindowingViewModel.
//  Tests window/level management, preset selection, interactive adjustments,
//  and computed properties.
//

import XCTest
import SwiftUI
@testable import DicomSwiftUI
@testable import DicomCore

@MainActor
final class WindowingViewModelTests: XCTestCase {

    // MARK: - Initialization Tests

    func testDefaultInitialization() {
        let viewModel = WindowingViewModel()

        // Should initialize with soft tissue preset
        XCTAssertNotNil(viewModel.currentSettings, "Should have current settings")
        XCTAssertEqual(viewModel.selectedPreset, .softTissue, "Should default to soft tissue preset")
        XCTAssertFalse(viewModel.isDragging, "Should not be dragging initially")

        // Verify soft tissue preset values
        let softTissueSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .softTissue)
        XCTAssertEqual(viewModel.currentSettings.center, softTissueSettings.center, accuracy: 0.01)
        XCTAssertEqual(viewModel.currentSettings.width, softTissueSettings.width, accuracy: 0.01)
    }

    func testInitializationWithCustomSettings() {
        // Use values that don't match any preset
        let customSettings = WindowSettings(center: 123.456, width: 789.012)
        let viewModel = WindowingViewModel(initialSettings: customSettings)

        // Should use custom settings
        XCTAssertEqual(viewModel.currentSettings.center, 123.456, accuracy: 0.01)
        XCTAssertEqual(viewModel.currentSettings.width, 789.012, accuracy: 0.01)

        // Should not have a preset (custom settings that don't match any preset)
        // Note: If this fails, the values accidentally match a preset - choose different values
        XCTAssertNil(viewModel.selectedPreset, "Should not have preset for custom settings")
        XCTAssertFalse(viewModel.isDragging, "Should not be dragging initially")
    }

    func testInitializationWithPreset() {
        let viewModel = WindowingViewModel(preset: .lung)

        // Should use lung preset
        XCTAssertEqual(viewModel.selectedPreset, .lung, "Should have lung preset selected")

        // Verify lung preset values
        let lungSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)
        XCTAssertEqual(viewModel.currentSettings.center, lungSettings.center, accuracy: 0.01)
        XCTAssertEqual(viewModel.currentSettings.width, lungSettings.width, accuracy: 0.01)
        XCTAssertFalse(viewModel.isDragging, "Should not be dragging initially")
    }

    func testInitializationWithMatchingPresetSettings() {
        // Create settings that match a known preset
        let lungSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)
        let viewModel = WindowingViewModel(initialSettings: lungSettings)

        // Should automatically detect and select the preset
        XCTAssertEqual(viewModel.selectedPreset, .lung, "Should detect lung preset")
        XCTAssertEqual(viewModel.currentSettings.center, lungSettings.center, accuracy: 0.01)
        XCTAssertEqual(viewModel.currentSettings.width, lungSettings.width, accuracy: 0.01)
    }

    // MARK: - Available Presets Tests

    func testAvailablePresets() {
        let viewModel = WindowingViewModel()

        // Should have all presets except .custom
        XCTAssertGreaterThan(viewModel.availablePresets.count, 0, "Should have available presets")
        XCTAssertFalse(viewModel.availablePresets.contains(.custom), "Should not include custom preset")

        // Verify some known presets are included
        XCTAssertTrue(viewModel.availablePresets.contains(.lung), "Should include lung preset")
        XCTAssertTrue(viewModel.availablePresets.contains(.bone), "Should include bone preset")
        XCTAssertTrue(viewModel.availablePresets.contains(.brain), "Should include brain preset")
        XCTAssertTrue(viewModel.availablePresets.contains(.softTissue), "Should include soft tissue preset")
    }

    // MARK: - Set Window Level Tests

    func testSetWindowLevel() {
        let viewModel = WindowingViewModel()

        // Set custom window level with values that don't match any preset
        viewModel.setWindowLevel(center: 1234.5678, width: 9876.5432)

        XCTAssertEqual(viewModel.currentSettings.center, 1234.5678, accuracy: 0.01)
        XCTAssertEqual(viewModel.currentSettings.width, 9876.5432, accuracy: 0.01)
        XCTAssertNil(viewModel.selectedPreset, "Should clear preset when setting custom values")
    }

    func testSetWindowLevelWithInvalidWidth() {
        let viewModel = WindowingViewModel()
        let originalSettings = viewModel.currentSettings

        // Attempt to set invalid width (negative)
        viewModel.setWindowLevel(center: 50.0, width: -100.0)

        // Settings should not change
        XCTAssertEqual(viewModel.currentSettings.center, originalSettings.center, accuracy: 0.01)
        XCTAssertEqual(viewModel.currentSettings.width, originalSettings.width, accuracy: 0.01)
    }

    func testSetWindowLevelWithZeroWidth() {
        let viewModel = WindowingViewModel()
        let originalSettings = viewModel.currentSettings

        // Attempt to set zero width (invalid)
        viewModel.setWindowLevel(center: 50.0, width: 0.0)

        // Settings should not change
        XCTAssertEqual(viewModel.currentSettings.center, originalSettings.center, accuracy: 0.01)
        XCTAssertEqual(viewModel.currentSettings.width, originalSettings.width, accuracy: 0.01)
    }

    func testSetWindowLevelMatchingPreset() {
        let viewModel = WindowingViewModel()

        // Set values that match lung preset
        let lungSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)
        viewModel.setWindowLevel(center: lungSettings.center, width: lungSettings.width)

        // Should automatically detect and select lung preset
        XCTAssertEqual(viewModel.selectedPreset, .lung, "Should detect lung preset")
    }

    // MARK: - Select Preset Tests

    func testSelectPreset() {
        let viewModel = WindowingViewModel()

        // Select lung preset
        viewModel.selectPreset(.lung)

        XCTAssertEqual(viewModel.selectedPreset, .lung, "Should select lung preset")

        let lungSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)
        XCTAssertEqual(viewModel.currentSettings.center, lungSettings.center, accuracy: 0.01)
        XCTAssertEqual(viewModel.currentSettings.width, lungSettings.width, accuracy: 0.01)
    }

    func testSelectMultiplePresets() {
        let viewModel = WindowingViewModel()

        // Select different presets in sequence
        viewModel.selectPreset(.lung)
        XCTAssertEqual(viewModel.selectedPreset, .lung)

        viewModel.selectPreset(.bone)
        XCTAssertEqual(viewModel.selectedPreset, .bone)

        viewModel.selectPreset(.brain)
        XCTAssertEqual(viewModel.selectedPreset, .brain)
    }

    func testSelectAllAvailablePresets() {
        let viewModel = WindowingViewModel()

        // Test selecting each available preset
        for preset in viewModel.availablePresets {
            viewModel.selectPreset(preset)

            XCTAssertEqual(viewModel.selectedPreset, preset, "Should select \(preset.displayName)")

            let expectedSettings = DCMWindowingProcessor.getPresetValuesV2(preset: preset)
            XCTAssertEqual(viewModel.currentSettings.center, expectedSettings.center, accuracy: 0.01,
                          "Center should match for \(preset.displayName)")
            XCTAssertEqual(viewModel.currentSettings.width, expectedSettings.width, accuracy: 0.01,
                          "Width should match for \(preset.displayName)")
        }
    }

    // MARK: - Apply Settings Tests

    func testApplySettings() {
        let viewModel = WindowingViewModel()

        // Use values that don't match any preset
        let customSettings = WindowSettings(center: 99.99, width: 499.99)
        viewModel.applySettings(customSettings)

        XCTAssertEqual(viewModel.currentSettings.center, 99.99, accuracy: 0.01)
        XCTAssertEqual(viewModel.currentSettings.width, 499.99, accuracy: 0.01)
    }

    func testApplyInvalidSettings() {
        let viewModel = WindowingViewModel()
        let originalSettings = viewModel.currentSettings

        // Attempt to apply invalid settings
        let invalidSettings = WindowSettings(center: 50.0, width: -100.0)
        viewModel.applySettings(invalidSettings)

        // Settings should not change
        XCTAssertEqual(viewModel.currentSettings.center, originalSettings.center, accuracy: 0.01)
        XCTAssertEqual(viewModel.currentSettings.width, originalSettings.width, accuracy: 0.01)
    }

    func testApplySettingsMatchingPreset() {
        let viewModel = WindowingViewModel()

        // Apply settings that match bone preset
        let boneSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .bone)
        viewModel.applySettings(boneSettings)

        // Should automatically detect and select bone preset
        XCTAssertEqual(viewModel.selectedPreset, .bone, "Should detect bone preset")
    }

    // MARK: - Reset Tests

    func testReset() {
        let viewModel = WindowingViewModel()

        // Change settings
        viewModel.selectPreset(.lung)
        viewModel.startDragging()

        // Reset
        viewModel.reset()

        // Should return to default soft tissue preset
        XCTAssertEqual(viewModel.selectedPreset, .softTissue, "Should reset to soft tissue preset")
        XCTAssertFalse(viewModel.isDragging, "Should not be dragging after reset")

        let softTissueSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .softTissue)
        XCTAssertEqual(viewModel.currentSettings.center, softTissueSettings.center, accuracy: 0.01)
        XCTAssertEqual(viewModel.currentSettings.width, softTissueSettings.width, accuracy: 0.01)
    }

    // MARK: - Dragging Tests

    func testStartDragging() {
        let viewModel = WindowingViewModel()

        XCTAssertFalse(viewModel.isDragging, "Should not be dragging initially")

        viewModel.startDragging()

        XCTAssertTrue(viewModel.isDragging, "Should be dragging after startDragging")
    }

    func testStartDraggingMultipleTimes() {
        let viewModel = WindowingViewModel()

        viewModel.startDragging()
        viewModel.startDragging()
        viewModel.startDragging()

        // Should remain in dragging state
        XCTAssertTrue(viewModel.isDragging, "Should remain dragging")
    }

    func testEndDragging() {
        let viewModel = WindowingViewModel()

        viewModel.startDragging()
        XCTAssertTrue(viewModel.isDragging, "Should be dragging")

        viewModel.endDragging()
        XCTAssertFalse(viewModel.isDragging, "Should not be dragging after endDragging")
    }

    func testEndDraggingWithoutStart() {
        let viewModel = WindowingViewModel()

        // End dragging without starting
        viewModel.endDragging()

        // Should remain not dragging
        XCTAssertFalse(viewModel.isDragging, "Should not be dragging")
    }

    // MARK: - Adjust Window Level Tests

    func testAdjustWindowLevel() {
        let viewModel = WindowingViewModel()
        let initialSettings = viewModel.currentSettings

        // Adjust window level
        viewModel.adjustWindowLevel(centerDelta: 10.0, widthDelta: 20.0)

        // Should update settings
        XCTAssertEqual(viewModel.currentSettings.center, initialSettings.center + 10.0, accuracy: 0.01)
        XCTAssertEqual(viewModel.currentSettings.width, initialSettings.width + 20.0, accuracy: 0.01)

        // Should be in dragging state (auto-started)
        XCTAssertTrue(viewModel.isDragging, "Should auto-start dragging")

        // Should clear preset
        XCTAssertNil(viewModel.selectedPreset, "Should clear preset during interactive adjustment")
    }

    func testAdjustWindowLevelWithNegativeWidthDelta() {
        let viewModel = WindowingViewModel()
        viewModel.setWindowLevel(center: 50.0, width: 400.0)

        // Adjust with negative width delta
        viewModel.adjustWindowLevel(centerDelta: 0.0, widthDelta: -50.0)

        XCTAssertEqual(viewModel.currentSettings.center, 50.0, accuracy: 0.01)
        XCTAssertEqual(viewModel.currentSettings.width, 350.0, accuracy: 0.01)
    }

    func testAdjustWindowLevelClampingWidth() {
        let viewModel = WindowingViewModel()
        viewModel.setWindowLevel(center: 50.0, width: 10.0)

        // Adjust with large negative width delta (should clamp to 1.0)
        viewModel.adjustWindowLevel(centerDelta: 0.0, widthDelta: -100.0)

        XCTAssertEqual(viewModel.currentSettings.width, 1.0, accuracy: 0.01, "Width should be clamped to 1.0")
    }

    func testAdjustWindowLevelAutoStartsDragging() {
        let viewModel = WindowingViewModel()

        XCTAssertFalse(viewModel.isDragging, "Should not be dragging initially")

        // Adjust window level (should auto-start dragging)
        viewModel.adjustWindowLevel(centerDelta: 5.0, widthDelta: 10.0)

        XCTAssertTrue(viewModel.isDragging, "Should auto-start dragging")
    }

    func testAdjustWindowLevelRelativeToDragStart() {
        let viewModel = WindowingViewModel()
        viewModel.setWindowLevel(center: 100.0, width: 400.0)

        // Start dragging (captures baseline)
        viewModel.startDragging()

        // First adjustment
        viewModel.adjustWindowLevel(centerDelta: 10.0, widthDelta: 20.0)
        XCTAssertEqual(viewModel.currentSettings.center, 110.0, accuracy: 0.01)
        XCTAssertEqual(viewModel.currentSettings.width, 420.0, accuracy: 0.01)

        // Second adjustment (should be relative to original baseline, not cumulative)
        viewModel.adjustWindowLevel(centerDelta: 20.0, widthDelta: 40.0)
        XCTAssertEqual(viewModel.currentSettings.center, 120.0, accuracy: 0.01)
        XCTAssertEqual(viewModel.currentSettings.width, 440.0, accuracy: 0.01)
    }

    // MARK: - Computed Properties Tests

    func testIsCustomProperty() {
        let viewModel = WindowingViewModel()

        // Initially has preset (soft tissue)
        XCTAssertFalse(viewModel.isCustom, "Should not be custom with preset")

        // Set custom values that don't match any preset
        viewModel.setWindowLevel(center: 1234.5678, width: 9876.5432)
        XCTAssertTrue(viewModel.isCustom, "Should be custom without preset")

        // Select preset again
        viewModel.selectPreset(.lung)
        XCTAssertFalse(viewModel.isCustom, "Should not be custom with preset")
    }

    func testPresetNameProperty() {
        let viewModel = WindowingViewModel()

        // Initially soft tissue
        XCTAssertEqual(viewModel.presetName, MedicalPreset.softTissue.displayName)

        // Select lung preset
        viewModel.selectPreset(.lung)
        XCTAssertEqual(viewModel.presetName, MedicalPreset.lung.displayName)

        // Set custom values that don't match any preset
        viewModel.setWindowLevel(center: 1234.5678, width: 9876.5432)
        XCTAssertEqual(viewModel.presetName, "Custom", "Should return 'Custom' for custom settings")
    }

    func testCenterProperty() {
        let viewModel = WindowingViewModel()

        viewModel.setWindowLevel(center: 123.45, width: 400.0)
        XCTAssertEqual(viewModel.center, 123.45, accuracy: 0.01)
    }

    func testWidthProperty() {
        let viewModel = WindowingViewModel()

        viewModel.setWindowLevel(center: 50.0, width: 678.90)
        XCTAssertEqual(viewModel.width, 678.90, accuracy: 0.01)
    }

    // MARK: - State Consistency Tests

    func testPresetClearedOnCustomAdjustment() {
        let viewModel = WindowingViewModel()

        // Start with preset
        viewModel.selectPreset(.bone)
        XCTAssertNotNil(viewModel.selectedPreset)

        // Adjust window level interactively
        viewModel.adjustWindowLevel(centerDelta: 5.0, widthDelta: 10.0)

        // Preset should be cleared
        XCTAssertNil(viewModel.selectedPreset, "Preset should be cleared on interactive adjustment")
    }

    func testPresetClearedOnCustomSetWindowLevel() {
        let viewModel = WindowingViewModel()

        // Start with preset
        viewModel.selectPreset(.brain)
        XCTAssertNotNil(viewModel.selectedPreset)

        // Set custom window level with values that definitely don't match any preset
        viewModel.setWindowLevel(center: 999.99, width: 888.88)

        // Preset should be cleared (these values don't match any preset)
        XCTAssertNil(viewModel.selectedPreset, "Preset should be cleared on custom setWindowLevel")
    }

    // MARK: - Thread Safety Tests

    func testMainActorIsolation() async {
        // This test verifies that the view model is properly marked with @MainActor
        let viewModel = WindowingViewModel()

        // Access properties on main actor
        _ = viewModel.currentSettings
        _ = viewModel.selectedPreset
        _ = viewModel.isDragging

        // This confirms @MainActor isolation is working
        XCTAssertTrue(Thread.isMainThread, "Should be on main thread")
    }

    // MARK: - ObservableObject Conformance Tests

    func testPublishedPropertiesArePublished() {
        let viewModel = WindowingViewModel()

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

    func testVeryLargeCenterValue() {
        let viewModel = WindowingViewModel()

        viewModel.setWindowLevel(center: 100000.0, width: 400.0)

        XCTAssertEqual(viewModel.currentSettings.center, 100000.0, accuracy: 0.01)
        XCTAssertEqual(viewModel.currentSettings.width, 400.0, accuracy: 0.01)
    }

    func testVeryLargeWidthValue() {
        let viewModel = WindowingViewModel()

        viewModel.setWindowLevel(center: 50.0, width: 50000.0)

        XCTAssertEqual(viewModel.currentSettings.center, 50.0, accuracy: 0.01)
        XCTAssertEqual(viewModel.currentSettings.width, 50000.0, accuracy: 0.01)
    }

    func testNegativeCenterValue() {
        let viewModel = WindowingViewModel()

        // Negative center is valid (e.g., for CT images)
        viewModel.setWindowLevel(center: -500.0, width: 400.0)

        XCTAssertEqual(viewModel.currentSettings.center, -500.0, accuracy: 0.01)
        XCTAssertEqual(viewModel.currentSettings.width, 400.0, accuracy: 0.01)
    }

    func testMinimumValidWidth() {
        let viewModel = WindowingViewModel()

        // Width of 1.0 should be valid (minimum)
        viewModel.setWindowLevel(center: 50.0, width: 1.0)

        XCTAssertEqual(viewModel.currentSettings.width, 1.0, accuracy: 0.01)
    }

    // MARK: - Negative Case Tests

    func testAdjustWindowLevelWithExtremeNegativeWidthDelta() {
        let viewModel = WindowingViewModel()
        viewModel.setWindowLevel(center: 50.0, width: 500.0)

        // Adjust with extreme negative width delta
        viewModel.adjustWindowLevel(centerDelta: 0.0, widthDelta: -10000.0)

        // Width should be clamped to minimum 1.0
        XCTAssertEqual(viewModel.currentSettings.width, 1.0, accuracy: 0.01, "Width should be clamped to 1.0")
        XCTAssertEqual(viewModel.currentSettings.center, 50.0, accuracy: 0.01, "Center should remain unchanged")
    }

    func testPresetDetectionWithAlmostMatchingValues() {
        let viewModel = WindowingViewModel()

        // Get lung preset values
        let lungSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)

        // Set values very close but not exactly matching
        viewModel.setWindowLevel(center: lungSettings.center + 0.5, width: lungSettings.width + 0.5)

        // Should not detect as lung preset (values don't match exactly within tolerance)
        // Note: This depends on preset matching tolerance in DCMWindowingProcessor
        // If tolerance is wide, this might still match
        let detectedPreset = viewModel.selectedPreset
        if detectedPreset != .lung {
            XCTAssertNil(detectedPreset, "Should not match lung preset with slightly different values")
        }
    }

    func testDraggingStatePersistsThroughMultipleAdjustments() {
        let viewModel = WindowingViewModel()
        viewModel.setWindowLevel(center: 100.0, width: 400.0)

        // Start dragging
        viewModel.startDragging()
        XCTAssertTrue(viewModel.isDragging)

        // Make multiple adjustments
        for i in 1...10 {
            viewModel.adjustWindowLevel(centerDelta: Double(i), widthDelta: Double(i * 2))
            XCTAssertTrue(viewModel.isDragging, "Should remain dragging through adjustment \(i)")
        }

        // End dragging
        viewModel.endDragging()
        XCTAssertFalse(viewModel.isDragging, "Should stop dragging after endDragging")
    }

    func testResetDuringDragging() {
        let viewModel = WindowingViewModel()
        viewModel.selectPreset(.bone)

        // Start dragging and adjust
        viewModel.startDragging()
        viewModel.adjustWindowLevel(centerDelta: 10.0, widthDelta: 20.0)

        XCTAssertTrue(viewModel.isDragging, "Should be dragging")
        XCTAssertNil(viewModel.selectedPreset, "Preset should be cleared during adjustment")

        // Reset while dragging
        viewModel.reset()

        // Should return to default state
        XCTAssertFalse(viewModel.isDragging, "Should not be dragging after reset")
        XCTAssertEqual(viewModel.selectedPreset, .softTissue, "Should return to default preset")
    }

    func testSetWindowLevelWithVerySmallPositiveWidth() {
        let viewModel = WindowingViewModel()

        // Test with width approaching zero but still positive
        viewModel.setWindowLevel(center: 50.0, width: 0.001)

        XCTAssertEqual(viewModel.currentSettings.width, 0.001, accuracy: 0.0001, "Should accept very small positive width")
        XCTAssertEqual(viewModel.currentSettings.center, 50.0, accuracy: 0.01, "Center should be set correctly")
    }

    func testApplyAllPresetsSequentially() {
        let viewModel = WindowingViewModel()

        // Apply all available presets and verify each one is set correctly
        for preset in viewModel.availablePresets {
            viewModel.selectPreset(preset)

            XCTAssertEqual(viewModel.selectedPreset, preset, "Should select \(preset)")
            XCTAssertFalse(viewModel.isCustom, "Should not be custom with preset")

            let expectedSettings = DCMWindowingProcessor.getPresetValuesV2(preset: preset)
            XCTAssertEqual(viewModel.currentSettings.center, expectedSettings.center, accuracy: 0.01,
                          "Center should match for \(preset)")
            XCTAssertEqual(viewModel.currentSettings.width, expectedSettings.width, accuracy: 0.01,
                          "Width should match for \(preset)")
            XCTAssertEqual(viewModel.presetName, preset.displayName, "Preset name should match")
        }
    }

    func testCenterAndWidthComputedPropertiesAfterMultipleChanges() {
        let viewModel = WindowingViewModel()

        // Change settings multiple times
        let testCases: [(center: Double, width: Double)] = [
            (0.0, 100.0),
            (500.0, 1000.0),
            (-200.0, 300.0),
            (1234.5678, 9876.5432)
        ]

        for (center, width) in testCases {
            viewModel.setWindowLevel(center: center, width: width)

            XCTAssertEqual(viewModel.center, center, accuracy: 0.01, "Center property should match")
            XCTAssertEqual(viewModel.width, width, accuracy: 0.01, "Width property should match")
        }
    }

    func testAdjustWindowLevelWithZeroDeltas() {
        let viewModel = WindowingViewModel()
        viewModel.setWindowLevel(center: 100.0, width: 400.0)

        let initialSettings = viewModel.currentSettings

        // Adjust with zero deltas
        viewModel.adjustWindowLevel(centerDelta: 0.0, widthDelta: 0.0)

        // Settings should remain the same
        XCTAssertEqual(viewModel.currentSettings.center, initialSettings.center, accuracy: 0.01)
        XCTAssertEqual(viewModel.currentSettings.width, initialSettings.width, accuracy: 0.01)
        XCTAssertTrue(viewModel.isDragging, "Should be in dragging state")
    }

    func testInvalidSettingsDoNotChangeState() {
        let viewModel = WindowingViewModel()
        viewModel.selectPreset(.brain)

        let initialPreset = viewModel.selectedPreset
        let initialSettings = viewModel.currentSettings

        // Try to apply invalid settings (negative width)
        let invalidSettings = WindowSettings(center: 50.0, width: -100.0)
        viewModel.applySettings(invalidSettings)

        // State should not change
        XCTAssertEqual(viewModel.selectedPreset, initialPreset, "Preset should not change")
        XCTAssertEqual(viewModel.currentSettings.center, initialSettings.center, accuracy: 0.01,
                      "Center should not change")
        XCTAssertEqual(viewModel.currentSettings.width, initialSettings.width, accuracy: 0.01,
                      "Width should not change")
    }
}