//
//  WindowingControlView.swift
//
//  SwiftUI view for interactive window/level adjustment controls
//
//  This view provides a complete interface for adjusting window/level settings
//  in medical imaging applications. It includes preset buttons for common
//  anatomical views (lung, bone, brain, etc.), interactive sliders for precise
//  center and width adjustment, and drag gesture support for real-time windowing.
//
//  The view integrates with WindowingViewModel for state management and
//  DicomImageViewModel for applying windowing transformations to displayed images.
//  It automatically updates the UI when settings change and provides visual
//  feedback for the currently selected preset or custom values.
//
//  Platform Availability:
//
//  Available on the package's iOS, visionOS, and macOS 26+ targets.
//  Uses native SwiftUI components for optimal performance and platform integration.
//
//  Accessibility:
//
//  All interactive controls include proper accessibility labels, hints, and values
//  for VoiceOver support. Slider values are announced dynamically as they change.
//

import SwiftUI
import DicomCore

/// A SwiftUI view for interactive window/level adjustment controls.
///
/// ## Overview
///
/// ``WindowingControlView`` provides a comprehensive control panel for adjusting
/// window/level settings in medical imaging applications. It offers three interaction
/// modes: preset selection via buttons, precise adjustment via sliders, and real-time
/// drag gestures on the image itself.
///
/// The view is designed to work with ``WindowingViewModel`` for state management and
/// ``DicomImageViewModel`` for applying windowing transformations. When settings change,
/// you typically call `DicomImageViewModel.updateWindowing()` to re-render the image
/// with the new window/level values.
///
/// **Key Features:**
/// - 13 medical imaging presets (lung, bone, brain, liver, etc.)
/// - Interactive sliders for window center and width
/// - Real-time value display with formatted labels
/// - Visual indication of selected preset
/// - Customizable layout (compact or expanded)
/// - Dark mode support
/// - Full accessibility support for VoiceOver
///
/// **Control Layout:**
/// - Preset buttons in a scrollable row
/// - Window center slider (-1000 to +3000 Hounsfield units)
/// - Window width slider (1 to 4000 Hounsfield units)
/// - Current value labels with preset name
///
/// ## Usage
///
/// Basic usage with default layout:
///
/// ```swift
/// struct ContentView: View {
///     @StateObject private var windowingVM = WindowingViewModel()
///     @StateObject private var imageVM = DicomImageViewModel()
///
///     var body: some View {
///         VStack {
///             DicomImageView(viewModel: imageVM)
///
///             WindowingControlView(
///                 windowingViewModel: windowingVM,
///                 onWindowingChanged: { settings in
///                     Task {
///                         await imageVM.updateWindowing(
///                             windowingMode: .custom(
///                                 center: settings.center,
///                                 width: settings.width
///                             )
///                         )
///                     }
///                 }
///             )
///         }
///     }
/// }
/// ```
///
/// Compact layout for embedded use:
///
/// ```swift
/// WindowingControlView(
///     windowingViewModel: windowingVM,
///     layout: .compact,
///     onWindowingChanged: { settings in
///         Task {
///             await imageVM.updateWindowing(
///                 windowingMode: .custom(
///                     center: settings.center,
///                     width: settings.width
///                 )
///             )
///         }
///     }
/// )
/// .padding()
/// .background(Color.secondary.opacity(0.1))
/// .cornerRadius(8)
/// ```
///
/// Integration with preset selection:
///
/// ```swift
/// WindowingControlView(
///     windowingViewModel: windowingVM,
///     onPresetSelected: { preset in
///         Task {
///             await imageVM.updateWindowing(
///                 windowingMode: .preset(preset)
///             )
///         }
///     },
///     onWindowingChanged: { settings in
///         Task {
///             await imageVM.updateWindowing(
///                 windowingMode: .custom(
///                     center: settings.center,
///                     width: settings.width
///                 )
///             )
///         }
///     }
/// )
/// ```
///
/// ### Customization
///
/// Apply standard SwiftUI modifiers for styling:
/// - `.padding()` - Add padding around controls
/// - `.background()` - Add background color
/// - `.cornerRadius()` - Round corners
/// - `.disabled()` - Disable all controls
///
/// ## Topics
///
/// ### Creating a View
///
/// - ``init(windowingViewModel:layout:accessibilityUnit:onPresetSelected:onWindowingChanged:)``
///
/// ### Layout Options
///
/// - ``Layout``
///
public struct WindowingControlView: View {

    // MARK: - Layout Options

    /// Layout style for the windowing control panel.
    ///
    /// Controls the visual density and spacing of the windowing control interface.
    /// Use expanded layout for primary control panels and compact layout for embedded
    /// or secondary UI contexts.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Full layout for main control panel
    /// WindowingControlView(
    ///     windowingViewModel: viewModel,
    ///     layout: .expanded
    /// )
    ///
    /// // Compact layout for sidebar or toolbar
    /// WindowingControlView(
    ///     windowingViewModel: viewModel,
    ///     layout: .compact
    /// )
    /// ```
    public enum Layout {
        /// Full layout with all controls and labels.
        ///
        /// Provides standard spacing (16pt), full-size fonts (.headline, .footnote),
        /// and complete button labels. Best for primary control panels where space
        /// is not constrained.
        case expanded

        /// Compact layout for embedded use.
        ///
        /// Uses smaller spacing (12pt), reduced fonts (.caption, .caption2), and
        /// icon-only buttons. Ideal for toolbars, sidebars, or embedded contexts
        /// where space is limited.
        case compact
    }

    // MARK: - Properties

    /// View model managing windowing state
    @ObservedObject private var windowingViewModel: WindowingViewModel

    /// Layout style for the control panel
    private let layout: Layout

    /// Unit announced for slider accessibility values
    private let accessibilityUnit: String

    /// Callback when a preset is selected
    private let onPresetSelected: ((MedicalPreset) -> Void)?

    /// Callback when windowing values change
    private let onWindowingChanged: ((WindowSettings) -> Void)?

    // Local state for slider editing
    @State private var isEditingCenter = false
    @State private var isEditingWidth = false
    @State private var tempCenter: Double
    @State private var tempWidth: Double

    // MARK: - Initializers

    /// Creates a windowing control view.
    ///
    /// Provides a complete control panel for window/level adjustment with preset buttons,
    /// sliders, and value display. The view observes the provided view model for state
    /// changes and calls the appropriate callbacks when settings are modified.
    ///
    /// - Parameters:
    ///   - windowingViewModel: View model managing windowing state
    ///   - layout: Layout style (`.expanded` or `.compact`). Defaults to `.expanded`
    ///   - accessibilityUnit: Unit announced for slider values. Defaults to `"Hounsfield units"`
    ///   - onPresetSelected: Optional callback when a preset button is tapped
    ///   - onWindowingChanged: Optional callback when center or width values change
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var windowingVM = WindowingViewModel()
    /// @StateObject private var imageVM = DicomImageViewModel()
    ///
    /// WindowingControlView(
    ///     windowingViewModel: windowingVM,
    ///     onPresetSelected: { preset in
    ///         windowingVM.selectPreset(preset)
    ///         Task {
    ///             await imageVM.updateWindowing(windowingMode: .preset(preset))
    ///         }
    ///     },
    ///     onWindowingChanged: { settings in
    ///         Task {
    ///             await imageVM.updateWindowing(
    ///                 windowingMode: .custom(
    ///                     center: settings.center,
    ///                     width: settings.width
    ///                 )
    ///             )
    ///         }
    ///     }
    /// )
    /// ```
    ///
    public init(
        windowingViewModel: WindowingViewModel,
        layout: Layout = .expanded,
        accessibilityUnit: String = "Hounsfield units",
        onPresetSelected: ((MedicalPreset) -> Void)? = nil,
        onWindowingChanged: ((WindowSettings) -> Void)? = nil
    ) {
        self.windowingViewModel = windowingViewModel
        self.layout = layout
        self.accessibilityUnit = accessibilityUnit
        self.onPresetSelected = onPresetSelected
        self.onWindowingChanged = onWindowingChanged

        // Initialize temp values with current settings
        _tempCenter = State(initialValue: windowingViewModel.currentSettings.center)
        _tempWidth = State(initialValue: windowingViewModel.currentSettings.width)
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: layout == .compact ? 12 : 16) {
            // Header
            WindowingHeaderView(
                presetName: windowingViewModel.presetName,
                center: windowingViewModel.center,
                width: windowingViewModel.width,
                layout: layout
            )

            // Preset buttons
            WindowingPresetButtonsView(
                presets: windowingViewModel.availablePresets,
                selectedPreset: windowingViewModel.selectedPreset,
                layout: layout,
                onSelectPreset: { preset in
                    windowingViewModel.selectPreset(preset)
                    onPresetSelected?(preset)
                }
            )

            // Sliders
            WindowingSlidersView(
                layout: layout,
                accessibilityUnit: accessibilityUnit,
                tempCenter: $tempCenter,
                tempWidth: $tempWidth,
                isEditingCenter: $isEditingCenter,
                isEditingWidth: $isEditingWidth,
                onCommit: { applySliderChanges() }
            )
        }
        .padding(layout == .compact ? 12 : 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Window level controls")
        .onChangeCompat(
            of: windowingViewModel.currentSettings,
            fallback: windowingViewModel.$currentSettings
        ) { newSettings in
            // Sync temp values when view model changes externally
            if !isEditingCenter {
                tempCenter = newSettings.center
            }
            if !isEditingWidth {
                tempWidth = newSettings.width
            }
        }
    }


    // MARK: - Helper Methods

    /// Applies slider changes to view model and triggers callback.
    ///
    /// Called when the user finishes dragging a slider (center or width). Updates the
    /// view model with the new values and invokes the `onWindowingChanged` callback
    /// so the consumer can update the displayed image with the new windowing settings.
    ///
    /// This method ensures that windowing changes are only applied when the user
    /// Commits the currently edited center and width values to the view model and notifies listeners.
    /// 
    /// Apply the current temporary center and width values to the view model and notify listeners of the change.
    /// 
    /// Commits `tempCenter` and `tempWidth` to `windowingViewModel` and invokes `onWindowingChanged` with the view model's updated `currentSettings`. Intended to be called when slider edits are finalized.
    private func applySliderChanges() {
        windowingViewModel.setWindowLevel(center: tempCenter, width: tempWidth)
        onWindowingChanged?(windowingViewModel.currentSettings)
    }
}


// MARK: - SwiftUI Previews

#if DEBUG
struct WindowingControlView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // MARK: - Basic Layouts

            // Expanded layout with interactive callbacks
            InteractivePreview(
                title: "Expanded Layout - Interactive",
                layout: .expanded
            )
            .previewDisplayName("Expanded Layout")

            // Compact layout with interactive callbacks
            InteractivePreview(
                title: "Compact Layout - Interactive",
                layout: .compact
            )
            .previewDisplayName("Compact Layout")

            // MARK: - Preset Configurations

            // CT Lung preset
            PresetPreview(
                preset: .lung,
                title: "CT Lung Window"
            )
            .previewDisplayName("CT Lung Preset")

            // CT Bone preset
            PresetPreview(
                preset: .bone,
                title: "CT Bone Window"
            )
            .previewDisplayName("CT Bone Preset")

            // CT Brain preset
            PresetPreview(
                preset: .brain,
                title: "CT Brain Window"
            )
            .previewDisplayName("CT Brain Preset")

            // Abdomen preset with compact layout
            PresetPreview(
                preset: .abdomen,
                title: "CT Abdomen (Compact)",
                layout: .compact
            )
            .previewDisplayName("CT Abdomen Compact")

            // MARK: - Color Schemes

            // Dark mode
            InteractivePreview(
                title: "Dark Mode",
                layout: .expanded
            )
            .preferredColorScheme(.dark)
            .previewDisplayName("Dark Mode")

            // Light mode
            InteractivePreview(
                title: "Light Mode",
                layout: .expanded
            )
            .preferredColorScheme(.light)
            .previewDisplayName("Light Mode")

            // MARK: - Custom Settings

            // Custom windowing values
            CustomSettingsPreview()
            .previewDisplayName("Custom Settings")
        }
    }
}

// MARK: - Preview Helper Views

/// Interactive preview demonstrating callback functionality.
///
/// Shows how the control view responds to user interaction with preset selection
/// and slider adjustments. Displays callback events in a scrollable log.
private struct InteractivePreview: View {
    let title: String
    let layout: WindowingControlView.Layout

    @StateObject private var windowingViewModel = WindowingViewModel()
    @State private var eventLog: [String] = []
    @State private var eventCount = 0

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            WindowingControlView(
                windowingViewModel: windowingViewModel,
                layout: layout,
                onPresetSelected: { preset in
                    logEvent("Preset selected: \(preset.displayName)")
                },
                onWindowingChanged: { settings in
                    logEvent("Windowing changed: C=\(Int(settings.center)), W=\(Int(settings.width))")
                }
            )
            .frame(width: layout == .compact ? 350 : 400)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            // Event log
            VStack(alignment: .leading, spacing: 4) {
                Text("Event Log (\(eventCount) events):")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(eventLog.suffix(5), id: \.self) { event in
                            Text(event)
                                .font(.caption2)
                                .foregroundColor(.primary)
                                .padding(.vertical, 2)
                        }
                    }
                }
                .frame(height: 80)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(4)
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
    }

    private func logEvent(_ message: String) {
        eventCount += 1
        let timestamp = Date().formatted(.dateTime.hour().minute().second())
        eventLog.append("[\(timestamp)] \(message)")
    }
}

/// Preview demonstrating a specific medical preset.
///
/// Shows the control view initialized with a particular preset and demonstrates
/// how preset buttons appear when selected.
private struct PresetPreview: View {
    let preset: MedicalPreset
    let title: String
    var layout: WindowingControlView.Layout = .expanded

    @StateObject private var windowingViewModel: WindowingViewModel

    init(preset: MedicalPreset, title: String, layout: WindowingControlView.Layout = .expanded) {
        self.preset = preset
        self.title = title
        self.layout = layout
        _windowingViewModel = StateObject(wrappedValue: WindowingViewModel(preset: preset))
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            // Current settings display
            VStack(spacing: 4) {
                Text("Current Window Settings")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Center:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(Int(windowingViewModel.center))")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Width:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(Int(windowingViewModel.width))")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preset:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(windowingViewModel.presetName)
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(6)
            }
            .padding(.horizontal)

            WindowingControlView(
                windowingViewModel: windowingViewModel,
                layout: layout,
                onPresetSelected: { selectedPreset in
                    // Callback demonstration
                    print("User selected preset: \(selectedPreset.displayName)")
                },
                onWindowingChanged: { settings in
                    // Callback demonstration
                    print("Windowing changed to C=\(settings.center), W=\(settings.width)")
                }
            )
            .frame(width: layout == .compact ? 350 : 400)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
        .padding(.vertical)
    }
}

/// Preview demonstrating custom windowing settings.
///
/// Shows the control view with manually configured center and width values,
/// demonstrating the "Custom" preset state and slider positions.
private struct CustomSettingsPreview: View {
    @StateObject private var windowingViewModel: WindowingViewModel
    @State private var sliderAdjustments = 0

    init() {
        let vm = WindowingViewModel()
        vm.setWindowLevel(center: 500.0, width: 1500.0)
        _windowingViewModel = StateObject(wrappedValue: vm)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Custom Windowing Settings")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            VStack(spacing: 8) {
                HStack {
                    Text("Slider Adjustments:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("\(sliderAdjustments)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(4)

                    Spacer()
                }

                Text("Try adjusting the sliders to see live updates")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal)

            WindowingControlView(
                windowingViewModel: windowingViewModel,
                layout: .expanded,
                onPresetSelected: { preset in
                    print("Preset selected: \(preset.displayName)")
                },
                onWindowingChanged: { settings in
                    sliderAdjustments += 1
                    print("Custom windowing: C=\(Int(settings.center)), W=\(Int(settings.width))")
                }
            )
            .frame(width: 400)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            // Value display
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current Center")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(Int(windowingViewModel.center)) HU")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Current Width")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(Int(windowingViewModel.width)) HU")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Status")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(windowingViewModel.presetName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(windowingViewModel.presetName == "Custom" ? .orange : .green)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(6)
            .padding(.horizontal)
        }
        .padding(.vertical)
    }
}
#endif
