//
//  WindowingViewModel.swift
//
//  ViewModel for managing window/level settings and interactive adjustments
//
//  This view model provides a SwiftUI-friendly interface for window/level
//  operations in medical imaging. It manages window center and width values,
//  provides access to 13 medical presets (lung, bone, brain, etc.), and
//  supports interactive drag gestures for real-time windowing adjustments.
//
//  The view model uses DCMWindowingProcessor internally for all windowing
//  calculations and preset management. It maintains reactive state via
//  @Published properties, enabling automatic UI updates when settings change.
//
//  Thread Safety:
//
//  All methods marked with @MainActor run on the main thread, ensuring UI
//  updates are safe. The view model is designed for single-threaded access
//  from SwiftUI views.
//
//  Usage Patterns:
//
//  Use this view model in conjunction with DicomImageViewModel to provide
//  interactive windowing controls. When settings change, call
//  DicomImageViewModel.updateWindowing() to re-render the image with new
//  window/level values.
//

import Foundation
import SwiftUI
import Combine
import OSLog
import DicomCore

// MARK: - View Model

/// View model for managing window/level settings and interactive adjustments.
///
/// ## Overview
///
/// ``WindowingViewModel`` provides reactive state management for window/level operations
/// in medical imaging applications. It manages window center and width settings, provides
/// access to medical presets, and supports interactive drag gestures for real-time
/// windowing adjustments.
///
/// The view model is designed to work seamlessly with ``DicomImageViewModel``, providing
/// the windowing parameters while the image view model handles rendering. This separation
/// of concerns enables flexible UI architectures where windowing controls are decoupled
/// from image display.
///
/// **Key Features:**
/// - Reactive state with `@Published` properties
/// - 13 medical imaging presets (lung, bone, brain, etc.)
/// - Custom window/level values with validation
/// - Interactive drag gesture support for real-time adjustment
/// - Automatic preset detection from window values
/// - Thread-safe operations with main actor isolation
///
/// ## Usage
///
/// Basic usage with preset selection:
///
/// ```swift
/// struct WindowingControlView: View {
///     @StateObject private var windowingVM = WindowingViewModel()
///     @StateObject private var imageVM = DicomImageViewModel()
///
///     var body: some View {
///         VStack {
///             // Preset buttons
///             HStack {
///                 ForEach(MedicalPreset.allCases, id: \.self) { preset in
///                     Button(preset.displayName) {
///                         windowingVM.selectPreset(preset)
///                         Task {
///                             await imageVM.updateWindowing(
///                                 windowingMode: .preset(preset)
///                             )
///                         }
///                     }
///                 }
///             }
///
///             // Current values
///             Text("Center: \(windowingVM.currentSettings.center, specifier: "%.1f")")
///             Text("Width: \(windowingVM.currentSettings.width, specifier: "%.1f")")
///         }
///     }
/// }
/// ```
///
/// Custom window/level with sliders:
///
/// ```swift
/// @StateObject private var windowingVM = WindowingViewModel()
/// @StateObject private var imageVM = DicomImageViewModel()
///
/// var body: some View {
///     VStack {
///         // Center slider
///         Slider(value: $centerValue, in: -1000...1000) { editing in
///             if !editing {
///                 windowingVM.setWindowLevel(center: centerValue, width: windowingVM.currentSettings.width)
///                 Task {
///                     await imageVM.updateWindowing(
///                         windowingMode: .custom(center: centerValue, width: windowingVM.currentSettings.width)
///                     )
///                 }
///             }
///         }
///
///         // Width slider
///         Slider(value: $widthValue, in: 1...2000) { editing in
///             if !editing {
///                 windowingVM.setWindowLevel(center: windowingVM.currentSettings.center, width: widthValue)
///                 Task {
///                     await imageVM.updateWindowing(
///                         windowingMode: .custom(center: windowingVM.currentSettings.center, width: widthValue)
///                     )
///                 }
///             }
///         }
///     }
/// }
/// ```
///
/// Interactive drag gesture for real-time adjustment:
///
/// ```swift
/// @StateObject private var windowingVM = WindowingViewModel()
/// @StateObject private var imageVM = DicomImageViewModel()
///
/// var body: some View {
///     if let image = imageVM.image {
///         Image(decorative: image, scale: 1.0)
///             .resizable()
///             .aspectRatio(contentMode: .fit)
///             .gesture(
///                 DragGesture()
///                     .onChanged { value in
///                         // Horizontal drag = center, vertical drag = width
///                         let centerDelta = value.translation.width * 2.0
///                         let widthDelta = -value.translation.height * 4.0
///                         windowingVM.adjustWindowLevel(
///                             centerDelta: centerDelta,
///                             widthDelta: widthDelta
///                         )
///                     }
///                     .onEnded { _ in
///                         windowingVM.endDragging()
///                         Task {
///                             await imageVM.updateWindowing(
///                                 windowingMode: .custom(
///                                     center: windowingVM.currentSettings.center,
///                                     width: windowingVM.currentSettings.width
///                                 )
///                             )
///                         }
///                     }
///             )
///     }
/// }
/// ```
///
/// ## Topics
///
/// ### Creating a View Model
///
/// - ``init(initialSettings:)``
/// - ``init(preset:)``
///
/// ### Applying Settings
///
/// - ``setWindowLevel(center:width:)``
/// - ``selectPreset(_:)``
/// - ``applySettings(_:)``
/// - ``reset()``
///
/// ### Interactive Adjustment
///
/// - ``adjustWindowLevel(centerDelta:widthDelta:)``
/// - ``startDragging()``
/// - ``endDragging()``
///
/// ### State Properties
///
/// - ``currentSettings``
/// - ``selectedPreset``
/// - ``isDragging``
/// - ``availablePresets``
///
/// ### Computed Properties
///
/// - ``isCustom``
/// - ``presetName``
/// - ``center``
/// - ``width``
///
@MainActor
public final class WindowingViewModel: ObservableObject {

    // MARK: - Published Properties

    /// Current window/level settings (center and width)
    @Published public private(set) var currentSettings: WindowSettings

    /// Currently selected medical preset (nil for custom settings)
    @Published public private(set) var selectedPreset: MedicalPreset?

    /// Whether the user is currently dragging to adjust windowing
    @Published public private(set) var isDragging: Bool = false

    // MARK: - Public Properties

    /// All available medical presets (excludes .custom)
    public let availablePresets: [MedicalPreset] = MedicalPreset.allCases.filter { $0 != .custom }

    // MARK: - Private Properties

    private let logger: Logger
    private var dragStartSettings: WindowSettings?

    // MARK: - Initialization

    /// Creates a new windowing view model with default soft tissue preset.
    ///
    /// Initializes the view model with soft tissue window/level values (center: 50, width: 350),
    /// which provide good general-purpose visualization for CT images. The view model is ready
    /// to use immediately after initialization.
    ///
    /// ## Example
    ///
    /// ```swift
    /// struct MyView: View {
    ///     @StateObject private var windowingVM = WindowingViewModel()
    ///
    ///     var body: some View {
    ///         // Use windowingVM here
    ///     }
    /// }
    /// ```
    ///
    public init() {
        // Default to soft tissue preset (good general-purpose starting point)
        let defaultPreset = MedicalPreset.softTissue
        self.currentSettings = DCMWindowingProcessor.getPresetValuesV2(preset: defaultPreset)
        self.selectedPreset = defaultPreset
        self.logger = Logger(subsystem: "com.dicomswiftui", category: "WindowingViewModel")
        logger.info("📊 WindowingViewModel initialized with preset: \(defaultPreset.displayName)")
    }

    /// Creates a new windowing view model with custom initial settings.
    ///
    /// Initializes the view model with specific window/level values. If the settings match
    /// a known medical preset (within tolerance), that preset is automatically selected.
    /// Otherwise, the settings are treated as custom.
    ///
    /// - Parameter initialSettings: The initial window center and width values
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Start with custom values
    /// let settings = WindowSettings(center: 100.0, width: 500.0)
    /// let windowingVM = WindowingViewModel(initialSettings: settings)
    ///
    /// // Or from decoder
    /// let decoder = try DCMDecoder(contentsOf: url)
    /// let windowingVM = WindowingViewModel(initialSettings: decoder.windowSettingsV2)
    /// ```
    ///
    public init(initialSettings: WindowSettings) {
        self.currentSettings = initialSettings
        self.selectedPreset = DCMWindowingProcessor.getPresetName(settings: initialSettings)
            .flatMap { name in
                MedicalPreset.allCases.first { $0.displayName.lowercased() == name.lowercased() }
            }
        self.logger = Logger(subsystem: "com.dicomswiftui", category: "WindowingViewModel")
        logger.info("📊 WindowingViewModel initialized with custom settings: center=\(initialSettings.center), width=\(initialSettings.width)")
    }

    /// Creates a new windowing view model with a specific medical preset.
    ///
    /// Initializes the view model with window/level values from the specified medical preset.
    /// This is a convenience initializer for starting with a known preset rather than
    /// numeric values.
    ///
    /// - Parameter preset: The medical preset to use (e.g., .lung, .bone, .brain)
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Start with lung preset
    /// let windowingVM = WindowingViewModel(preset: .lung)
    ///
    /// // Or bone preset for orthopedic imaging
    /// let windowingVM = WindowingViewModel(preset: .bone)
    /// ```
    ///
    public init(preset: MedicalPreset) {
        self.currentSettings = DCMWindowingProcessor.getPresetValuesV2(preset: preset)
        self.selectedPreset = preset
        self.logger = Logger(subsystem: "com.dicomswiftui", category: "WindowingViewModel")
        logger.info("📊 WindowingViewModel initialized with preset: \(preset.displayName)")
    }

    // MARK: - Public Interface - Applying Settings

    /// Sets custom window center and width values.
    ///
    /// Updates the current window/level settings to the specified values. The settings
    /// are validated (width must be positive), and if they match a known medical preset,
    /// that preset is automatically selected. Otherwise, the preset is cleared (custom mode).
    ///
    /// This method only updates the view model state. To apply the settings to a displayed
    /// image, call ``DicomImageViewModel/updateWindowing(windowingMode:processingMode:)``
    /// with the new values.
    ///
    /// - Parameters:
    ///   - center: The new window center (level) value
    ///   - width: The new window width value (must be positive)
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var windowingVM = WindowingViewModel()
    /// @StateObject private var imageVM = DicomImageViewModel()
    ///
    /// // Set custom values
    /// windowingVM.setWindowLevel(center: 50.0, width: 400.0)
    ///
    /// // Apply to image
    /// await imageVM.updateWindowing(
    ///     windowingMode: .custom(center: 50.0, width: 400.0)
    /// )
    /// ```
    public func setWindowLevel(center: Double, width: Double) {
        let newSettings = WindowSettings(center: center, width: width)

        guard newSettings.isValid else {
            logger.warning("⚠️ Invalid window settings: width must be positive (got \(width))")
            return
        }

        logger.debug("🔧 Setting window level: center=\(center), width=\(width)")

        currentSettings = newSettings

        // Check if these values match a known preset
        selectedPreset = DCMWindowingProcessor.getPresetName(settings: newSettings)
            .flatMap { name in
                MedicalPreset.allCases.first { $0.displayName.lowercased() == name.lowercased() }
            }

        if let preset = selectedPreset {
            logger.debug("✅ Settings match preset: \(preset.displayName)")
        } else {
            logger.debug("✅ Using custom settings")
        }
    }

    /// Selects a medical preset and applies its window/level values.
    ///
    /// Updates the current settings to match the specified medical preset (e.g., lung, bone,
    /// brain). The preset values are retrieved from `DCMWindowingProcessor` and applied
    /// immediately.
    ///
    /// This method only updates the view model state. To apply the preset to a displayed
    /// image, call ``DicomImageViewModel/updateWindowing(windowingMode:processingMode:)``
    /// with `.preset(selectedPreset)`.
    ///
    /// - Parameter preset: The medical preset to apply
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var windowingVM = WindowingViewModel()
    /// @StateObject private var imageVM = DicomImageViewModel()
    ///
    /// // Select lung preset
    /// windowingVM.selectPreset(.lung)
    ///
    /// // Apply to image
    /// await imageVM.updateWindowing(windowingMode: .preset(.lung))
    /// ```
    public func selectPreset(_ preset: MedicalPreset) {
        logger.info("🎯 Selecting preset: \(preset.displayName)")

        currentSettings = DCMWindowingProcessor.getPresetValuesV2(preset: preset)
        selectedPreset = preset

        logger.debug("✅ Preset applied: center=\(self.currentSettings.center), width=\(self.currentSettings.width)")
    }

    /// Applies window settings directly.
    ///
    /// Updates the current settings to match the provided `WindowSettings` instance. If the
    /// settings match a known medical preset, that preset is automatically selected. Otherwise,
    /// the settings are treated as custom.
    ///
    /// This is a convenience method for applying settings obtained from a decoder or
    /// other source without manually extracting center and width values.
    ///
    /// - Parameter settings: The window settings to apply
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var windowingVM = WindowingViewModel()
    ///
    /// // Apply settings from decoder
    /// let decoder = try DCMDecoder(contentsOf: url)
    /// windowingVM.applySettings(decoder.windowSettingsV2)
    ///
    /// // Or apply custom settings
    /// let settings = WindowSettings(center: 50.0, width: 400.0)
    /// windowingVM.applySettings(settings)
    /// ```
    public func applySettings(_ settings: WindowSettings) {
        guard settings.isValid else {
            logger.warning("⚠️ Cannot apply invalid window settings")
            return
        }

        logger.debug("🔧 Applying settings: center=\(settings.center), width=\(settings.width)")

        currentSettings = settings

        // Check if these values match a known preset
        selectedPreset = DCMWindowingProcessor.getPresetName(settings: settings)
            .flatMap { name in
                MedicalPreset.allCases.first { $0.displayName.lowercased() == name.lowercased() }
            }
    }

    /// Resets to default soft tissue preset.
    ///
    /// Resets the view model to the default soft tissue window/level values (center: 50,
    /// width: 350). This is useful for providing a "reset" button in the UI.
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var windowingVM = WindowingViewModel()
    /// @StateObject private var imageVM = DicomImageViewModel()
    ///
    /// // Reset button
    /// Button("Reset") {
    ///     windowingVM.reset()
    ///     Task {
    ///         await imageVM.updateWindowing(windowingMode: .preset(.softTissue))
    ///     }
    /// }
    /// ```
    /// Reset the windowing state to the default soft tissue preset.
    /// 
    /// Resets the view model to the default soft tissue preset and clears any active drag state.
    /// 
    /// Sets `currentSettings` to the soft tissue preset values, sets `selectedPreset` to `.softTissue`,
    /// sets `isDragging` to `false`, and clears `dragStartSettings`.
    public func reset() {
        logger.info("🔄 Resetting to default preset")

        let defaultPreset = MedicalPreset.softTissue
        currentSettings = DCMWindowingProcessor.getPresetValuesV2(preset: defaultPreset)
        selectedPreset = defaultPreset
        isDragging = false
        dragStartSettings = nil
    }

    // MARK: - Public Interface - Interactive Adjustment

    /// Adjusts window/level by delta values (for drag gestures).
    ///
    /// Incrementally adjusts the current window center and width by the specified delta
    /// values. This method is designed for interactive drag gestures where the user drags
    /// on the image to adjust windowing in real-time.
    ///
    /// The deltas are applied relative to the drag start position (captured by
    /// ``startDragging()``). If dragging hasn't been started, this method automatically
    /// calls ``startDragging()`` to initialize the baseline.
    ///
    /// **Convention:**
    /// - Horizontal drag (X-axis) adjusts center (window level)
    /// - Vertical drag (Y-axis) adjusts width (window width)
    /// - Typical sensitivity: `centerDelta = translation.width * 2.0`, `widthDelta = -translation.height * 4.0`
    ///
    /// - Parameters:
    ///   - centerDelta: Change in window center (positive = increase, negative = decrease)
    ///   - widthDelta: Change in window width (positive = increase, negative = decrease)
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var windowingVM = WindowingViewModel()
    /// @StateObject private var imageVM = DicomImageViewModel()
    ///
    /// var body: some View {
    ///     if let image = imageVM.image {
    ///         Image(decorative: image, scale: 1.0)
    ///             .resizable()
    ///             .gesture(
    ///                 DragGesture()
    ///                     .onChanged { value in
    ///                         // Adjust during drag
    ///                         let centerDelta = value.translation.width * 2.0
    ///                         let widthDelta = -value.translation.height * 4.0
    ///                         windowingVM.adjustWindowLevel(
    ///                             centerDelta: centerDelta,
    ///                             widthDelta: widthDelta
    ///                         )
    ///                     }
    ///                     .onEnded { _ in
    ///                         // Finalize on drag end
    ///                         windowingVM.endDragging()
    ///                         Task {
    ///                             await imageVM.updateWindowing(
    ///                                 windowingMode: .custom(
    ///                                     center: windowingVM.currentSettings.center,
    ///                                     width: windowingVM.currentSettings.width
    ///                                 )
    ///                             )
    ///                         }
    ///                     }
    ///             )
    ///     }
    /// }
    /// ```
    public func adjustWindowLevel(centerDelta: Double, widthDelta: Double) {
        // Auto-start dragging if not already started
        if !isDragging {
            startDragging()
        }

        guard let baseSettings = dragStartSettings else {
            logger.warning("⚠️ Cannot adjust window level: no drag start settings")
            return
        }

        // Calculate new values relative to drag start
        let newCenter = baseSettings.center + centerDelta
        let newWidth = max(1.0, baseSettings.width + widthDelta)  // Clamp width to minimum 1.0

        let newSettings = WindowSettings(center: newCenter, width: newWidth)

        logger.debug("🎯 Adjusting window level: center=\(newCenter), width=\(newWidth)")

        currentSettings = newSettings

        // Clear preset when using custom adjustment
        selectedPreset = nil
    }

    /// Marks the start of a drag gesture for windowing adjustment.
    ///
    /// Captures the current window settings as the baseline for delta calculations in
    /// ``adjustWindowLevel(centerDelta:widthDelta:)``. Call this when the drag gesture
    /// begins (e.g., in `.onChanged` or at the start of an interactive session).
    ///
    /// This method is automatically called by ``adjustWindowLevel(centerDelta:widthDelta:)``
    /// if not already dragging, so manual calls are optional but recommended for clarity.
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var windowingVM = WindowingViewModel()
    ///
    /// var body: some View {
    ///     Image(...)
    ///         .gesture(
    ///             DragGesture()
    ///                 .onChanged { value in
    ///                     if !windowingVM.isDragging {
    ///                         windowingVM.startDragging()
    ///                     }
    ///                     // ... adjust windowing
    ///                 }
    ///                 .onEnded { _ in
    ///                     windowingVM.endDragging()
    ///                 }
    ///         )
    /// }
    /// ```
    /// Begins a drag gesture for interactive window/level adjustment.
    /// Begins an interactive drag session by marking the view model as dragging and storing the current window settings as the drag baseline.
    /// - Important: If a drag is already active, calling this method has no effect.
    public func startDragging() {
        guard !isDragging else { return }

        logger.debug("👆 Starting drag gesture")

        isDragging = true
        dragStartSettings = currentSettings
    }

    /// Marks the end of a drag gesture for windowing adjustment.
    ///
    /// Finalizes the drag session and clears the baseline settings. Call this when the
    /// drag gesture ends (e.g., in `.onEnded`).
    ///
    /// After calling this method, you should typically trigger an image re-render with
    /// the final window settings using ``DicomImageViewModel/updateWindowing(windowingMode:processingMode:)``.
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var windowingVM = WindowingViewModel()
    /// @StateObject private var imageVM = DicomImageViewModel()
    ///
    /// var body: some View {
    ///     Image(...)
    ///         .gesture(
    ///             DragGesture()
    ///                 .onChanged { value in
    ///                     // ... adjust windowing
    ///                 }
    ///                 .onEnded { _ in
    ///                     windowingVM.endDragging()
    ///                     Task {
    ///                         await imageVM.updateWindowing(
    ///                             windowingMode: .custom(
    ///                                 center: windowingVM.currentSettings.center,
    ///                                 width: windowingVM.currentSettings.width
    ///                             )
    ///                         )
    ///                     }
    ///                 }
    ///         )
    /// }
    /// ```
    /// Ends the active drag interaction and clears the drag baseline.
    /// If no drag is active this method is a no-op.
    /// Ends the current interactive drag gesture and clears the drag baseline.
    /// - Discussion: If a drag is active, sets `isDragging` to `false` and clears the captured `dragStartSettings`. If no drag is active, this method does nothing.
    public func endDragging() {
        guard isDragging else { return }

        logger.debug("✋ Ending drag gesture")

        isDragging = false
        dragStartSettings = nil
    }
}

// MARK: - Convenience Computed Properties

extension WindowingViewModel {

    /// Returns true if using custom settings (not a known preset)
    public var isCustom: Bool {
        return selectedPreset == nil
    }

    /// Returns the display name of the current preset, or "Custom" if using custom settings
    public var presetName: String {
        return selectedPreset?.displayName ?? "Custom"
    }

    /// Convenience accessor for window center (level)
    public var center: Double {
        return currentSettings.center
    }

    /// Convenience accessor for window width
    public var width: Double {
        return currentSettings.width
    }
}
