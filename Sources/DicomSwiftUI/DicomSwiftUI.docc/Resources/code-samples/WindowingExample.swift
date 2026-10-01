import SwiftUI
import DicomSwiftUI
import DicomCore
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

private var platformSystemBackground: Color {
#if os(iOS) || os(tvOS) || os(visionOS)
    return Color(UIColor.systemBackground)
#elseif os(macOS)
    return Color(NSColor.windowBackgroundColor)
#else
    return Color.secondary
#endif
}

// MARK: - Basic Windowing Controls

/// Provides a SwiftUI view demonstrating basic image windowing controls for a DICOM image.
/// 
/// The returned view displays a DICOM image and a windowing control. Adjusting the control applies a custom window center and width to the displayed image, and the view loads a hardcoded DICOM file on appearance.
/// Sample SwiftUI view demonstrating a DICOM windowing control tied to an image view.
/// 
/// The view loads a DICOM file from a hardcoded path when it appears and displays it using a `DicomImageView`. A `WindowingControlView` is bound to an internal `WindowingViewModel`; changes in the control apply a custom window center and width to the displayed image.
/// - Returns: A view that displays a DICOM image with an interactive window/level control.
func basicWindowingControl() -> some View {
    struct BasicWindowingView: View {
        @StateObject private var windowingVM = WindowingViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        let dicomURL: URL

        var body: some View {
            VStack {
                DicomImageView(viewModel: imageVM)

                WindowingControlView(
                    windowingViewModel: windowingVM,
                    onWindowingChanged: { settings in
                        Task {
                            await imageVM.updateWindowing(
                                windowingMode: .custom(
                                    center: settings.center,
                                    width: settings.width
                                )
                            )
                        }
                    }
                )
            }
            .task {
                await imageVM.loadImage(from: dicomURL)
            }
        }
    }

    return BasicWindowingView(dicomURL: URL(fileURLWithPath: "/path/to/ct_scan.dcm"))
}

/// A compact example view that displays a DICOM image alongside a compact windowing control.
/// 
/// The control updates the image view model's windowing to the selected custom center/width when adjusted.
/// Displays a DICOM image alongside a compact windowing control.
/// 
/// The view loads a hardcoded DICOM file when it appears. Adjusting the compact control applies a custom window center and width to the displayed image.
/// - Returns: A view containing the DICOM image and a compact windowing control; control changes update the image using the selected center and width.
func compactWindowingControl() -> some View {
    struct CompactWindowingView: View {
        @StateObject private var windowingVM = WindowingViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        let dicomURL: URL

        var body: some View {
            VStack(spacing: 8) {
                DicomImageView(viewModel: imageVM)
                    .frame(height: 400)

                WindowingControlView(
                    windowingViewModel: windowingVM,
                    layout: .compact,
                    onWindowingChanged: { settings in
                        Task {
                            await imageVM.updateWindowing(
                                windowingMode: .custom(
                                    center: settings.center,
                                    width: settings.width
                                )
                            )
                        }
                    }
                )
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            }
            .task {
                await imageVM.loadImage(from: dicomURL)
            }
        }
    }

    return CompactWindowingView(dicomURL: URL(fileURLWithPath: "/path/to/image.dcm"))
}

// MARK: - Medical Presets

/// Presents a SwiftUI example demonstrating preset-based windowing for a CT image.
/// 
/// The view displays a DICOM image and a windowing control with medical presets. Selecting a preset applies that preset to the displayed image. The CT image is loaded from an embedded file URL when the view appears.
/// Displays a CT DICOM image alongside a windowing control populated with medical presets.
/// 
/// The view loads a CT image from a hard-coded file URL on appearance and applies a selected preset to the displayed image when a preset button is chosen.
/// - Returns: A SwiftUI view containing the image display and a preset-capable windowing control.
func medicalPresets() -> some View {
    struct PresetWindowingView: View {
        @StateObject private var windowingVM = WindowingViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        let ctURL: URL

        var body: some View {
            VStack {
                DicomImageView(viewModel: imageVM)

                WindowingControlView(
                    windowingViewModel: windowingVM,
                    onPresetSelected: { preset in
                        Task {
                            await imageVM.updateWindowing(
                                windowingMode: .preset(preset)
                            )
                        }
                    }
                )
            }
            .task {
                await imageVM.loadImage(from: ctURL)
            }
        }
    }

    return PresetWindowingView(ctURL: URL(fileURLWithPath: "/path/to/ct_scan.dcm"))
}

/// Creates a SwiftUI view that demonstrates initializing windowing with a preset.
/// The view displays a DICOM image loaded using the `.lung` preset and a windowing control; user adjustments from the control are applied to the displayed image as custom center/width values.
/// Creates a view that initializes windowing to the lung preset and presents a CT DICOM image with an interactive windowing control.
/// The view loads a hardcoded CT image using the `.lung` preset and applies user adjustments from the control as custom center/width windowing to the displayed image.
/// - Returns: A SwiftUI view containing a DICOM image view and a WindowingControlView initialized with the lung preset.
func initializeWithPreset() -> some View {
    struct InitialPresetView: View {
        @StateObject private var windowingVM = WindowingViewModel(preset: .lung)
        @StateObject private var imageVM = DicomImageViewModel()
        let ctURL: URL

        var body: some View {
            VStack {
                DicomImageView(viewModel: imageVM)

                WindowingControlView(
                    windowingViewModel: windowingVM,
                    onWindowingChanged: { settings in
                        Task {
                            await imageVM.updateWindowing(
                                windowingMode: .custom(
                                    center: settings.center,
                                    width: settings.width
                                )
                            )
                        }
                    }
                )
            }
            .task {
                // Load image with lung preset
                await imageVM.loadImage(
                    from: ctURL,
                    windowingMode: .preset(.lung)
                )
            }
        }
    }

    return InitialPresetView(ctURL: URL(fileURLWithPath: "/path/to/ct_chest.dcm"))
}

// MARK: - Custom Window Values

/// Presents a custom windowing example with a DICOM image, controls, and preset buttons.
///
/// The view updates the displayed image whenever the control changes and applies preset window center/width values when the "Contrast Enhanced" or "High Contrast" buttons are tapped.
/// - Returns: A SwiftUI `View` containing a `DicomImageView`, a `WindowingControlView` wired to the image view model, and two buttons that set and apply specific custom windowing values.
func customWindowValues() -> some View {
    struct CustomWindowView: View {
        @StateObject private var windowingVM = WindowingViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        let dicomURL: URL

        var body: some View {
            VStack {
                DicomImageView(viewModel: imageVM)

                WindowingControlView(
                    windowingViewModel: windowingVM,
                    onWindowingChanged: { settings in
                        Task {
                            await imageVM.updateWindowing(
                                windowingMode: .custom(
                                    center: settings.center,
                                    width: settings.width
                                )
                            )
                        }
                    }
                )

                // Custom preset buttons
                HStack(spacing: 12) {
                    Button("Contrast Enhanced") {
                        windowingVM.setWindowLevel(center: 300.0, width: 600.0)
                        Task {
                            await imageVM.updateWindowing(
                                windowingMode: .custom(center: 300.0, width: 600.0)
                            )
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("High Contrast") {
                        windowingVM.setWindowLevel(center: 50.0, width: 200.0)
                        Task {
                            await imageVM.updateWindowing(
                                windowingMode: .custom(center: 50.0, width: 200.0)
                            )
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            .task {
                await imageVM.loadImage(from: dicomURL)
            }
        }
    }

    return CustomWindowView(dicomURL: URL(fileURLWithPath: "/path/to/image.dcm"))
}

// MARK: - Windowing State Management

/// Example view that displays a DICOM image and tracks user windowing adjustments.
/// 
/// Increments a visible counter each time the windowing control is changed and applies the selected center/width to the displayed image.
/// Presents a view showing a DICOM image with a windowing control and a live count of adjustments.
/// The view loads a hardcoded DICOM file, increments an on-screen counter each time the windowing control changes, logs the new center and width to the console, and applies the selected center/width to the displayed image.
/// - Returns: A SwiftUI view containing the DICOM image, a caption with the number of window adjustments, and a WindowingControlView that updates the image's windowing when changed.
func observeWindowingChanges() -> some View {
    struct ObserverView: View {
        @StateObject private var windowingVM = WindowingViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        @State private var changeCount = 0
        let dicomURL: URL

        var body: some View {
            VStack {
                DicomImageView(viewModel: imageVM)

                Text("Window adjustments: \(changeCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                WindowingControlView(
                    windowingViewModel: windowingVM,
                    onWindowingChanged: { settings in
                        changeCount += 1

                        print("Window changed to C:\(settings.center) W:\(settings.width)")

                        Task {
                            await imageVM.updateWindowing(
                                windowingMode: .custom(
                                    center: settings.center,
                                    width: settings.width
                                )
                            )
                        }
                    }
                )
            }
            .task {
                await imageVM.loadImage(from: dicomURL)
            }
        }
    }

    return ObserverView(dicomURL: URL(fileURLWithPath: "/path/to/image.dcm"))
}

/// Demonstrates synchronizing an external windowing state with the windowing controls and applying those settings to a DICOM image view.
/// 
/// The returned view displays a DICOM image, shows the current external window center/width, updates that external state when the user adjusts controls, and provides a Reset to Default action that restores and applies default window settings.
/// Presents a view that synchronizes an external windowing state with a DICOM image and provides a reset action.
/// 
/// The view displays a DICOM image alongside the current external window center/width, updates that external state when the user changes windowing controls, and applies those settings to the displayed image. It also offers a "Reset to Default" button that restores default center and width and reapplies them to the image.
/// - Returns: A SwiftUI view containing a DICOM image, windowing controls that propagate changes to an external state, and a reset button.
func syncExternalState() -> some View {
    struct SyncedWindowingView: View {
        @StateObject private var windowingVM = WindowingViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        @State private var currentSettings = WindowSettings(center: 50.0, width: 400.0)
        let dicomURL: URL

        var body: some View {
            VStack {
                DicomImageView(viewModel: imageVM)

                // Display current settings
                VStack(spacing: 4) {
                    Text("Current Window Settings")
                        .font(.headline)
                    Text("Center: \(Int(currentSettings.center)), Width: \(Int(currentSettings.width))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()

                WindowingControlView(
                    windowingViewModel: windowingVM,
                    onWindowingChanged: { settings in
                        // Update external state
                        currentSettings = settings

                        Task {
                            await imageVM.updateWindowing(
                                windowingMode: .custom(
                                    center: settings.center,
                                    width: settings.width
                                )
                            )
                        }
                    }
                )

                // Reset button
                Button("Reset to Default") {
                    let defaultSettings = WindowSettings(center: 50.0, width: 400.0)
                    windowingVM.setWindowLevel(
                        center: defaultSettings.center,
                        width: defaultSettings.width
                    )
                    currentSettings = defaultSettings

                    Task {
                        await imageVM.updateWindowing(
                            windowingMode: .custom(
                                center: defaultSettings.center,
                                width: defaultSettings.width
                            )
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .task {
                await imageVM.loadImage(from: dicomURL)
            }
        }
    }

    return SyncedWindowingView(dicomURL: URL(fileURLWithPath: "/path/to/image.dcm"))
}

// MARK: - Preset Suggestions

/// Presents a view that displays a DICOM image alongside suggested medical windowing presets and interactive windowing controls.
/// 
/// The view loads the DICOM file, derives suggested presets from the image modality and body part, and offers preset buttons (when available) that apply the selected preset to the image. It also provides a windowing control for custom center/width adjustments.
/// Presents a SwiftUI example that displays a DICOM image alongside suggested medical windowing presets and a windowing control.
///
/// Displays a DICOM image loaded from a fixed URL, derives suggested presets from the image's modality and body part, and renders buttons to apply those presets. Custom adjustments made with the windowing control are applied to the image as custom center/width values.
/// - Returns: A view containing the decoded DICOM image, a list of suggested preset buttons (when available) that apply the selected preset, and a windowing control that updates the image with custom window center/width.
func presetSuggestions() -> some View {
    struct PresetSuggestionsView: View {
        @StateObject private var windowingVM = WindowingViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        @State private var suggestedPresets: [MedicalPreset] = []
        let dicomURL: URL

        var body: some View {
            VStack {
                DicomImageView(viewModel: imageVM)

                if !suggestedPresets.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Suggested Presets")
                            .font(.headline)

                        HStack(spacing: 8) {
                            ForEach(suggestedPresets, id: \.self) { preset in
                                Button(preset.displayName) {
                                    windowingVM.selectPreset(preset)
                                    Task {
                                        await imageVM.updateWindowing(
                                            windowingMode: .preset(preset)
                                        )
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                }

                WindowingControlView(
                    windowingViewModel: windowingVM,
                    onWindowingChanged: { settings in
                        Task {
                            await imageVM.updateWindowing(
                                windowingMode: .custom(
                                    center: settings.center,
                                    width: settings.width
                                )
                            )
                        }
                    }
                )
            }
            .task {
                await loadImageWithSuggestions()
            }
        }

        /// Loads the DICOM at `dicomURL`, updates `suggestedPresets` from the image's modality and body part, and sets `imageVM` with the decoded image.
        /// 
        /// Loads the DICOM at `dicomURL`, derives modality and body part to populate `suggestedPresets`, and instructs `imageVM` to load the decoded image.
        /// - Note: If decoding or loading fails the function prints the error.
        private func loadImageWithSuggestions() async {
            do {
                let decoder = try await DCMDecoder(contentsOfFile: dicomURL.path)

                // Get suggested presets based on modality and body part
                let metadata = DicomMetadataAccessor(decoder: decoder)
                let modality = metadata.string(.modality)
                let bodyPart = metadata.string(.bodyPartExamined)
                suggestedPresets = DCMWindowingProcessor.suggestPresets(
                    for: modality,
                    bodyPart: bodyPart
                )

                await imageVM.loadImage(decoder: decoder)
            } catch {
                print("Failed to load image: \(error)")
            }
        }
    }

    return PresetSuggestionsView(dicomURL: URL(fileURLWithPath: "/path/to/ct_scan.dcm"))
}

// MARK: - Advanced Windowing Techniques

/// Presents a SwiftUI example that loads a DICOM image and computes an optimal window center/width, applying the result to the windowing controls and the displayed image.
/// The view displays the DICOM image, provides interactive windowing controls, and includes a button which calculates an optimal window/level and updates both the WindowingViewModel and the image view model.
/// - Returns: A view demonstrating loading a DICOM file, calculating an optimal window level, and applying those settings to the UI and image.
func optimalWindowCalculation() -> some View {
    struct OptimalWindowView: View {
        @StateObject private var windowingVM = WindowingViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        let dicomURL: URL

        var body: some View {
            VStack {
                DicomImageView(viewModel: imageVM)

                WindowingControlView(
                    windowingViewModel: windowingVM,
                    onWindowingChanged: { settings in
                        Task {
                            await imageVM.updateWindowing(
                                windowingMode: .custom(
                                    center: settings.center,
                                    width: settings.width
                                )
                            )
                        }
                    }
                )

                Button("Calculate Optimal Window") {
                    Task {
                        await calculateOptimalWindow()
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .task {
                await imageVM.loadImage(from: dicomURL)
            }
        }

        /// Calculates an optimal window center and width for the current DICOM image and applies those values to the windowing view model and image view model.
        /// 
        /// Calculates an optimal window center and width from the current DICOM pixel data and applies those values to the windowing view model and the displayed image.
        /// - Note: If pixel data is unavailable the function returns early. Errors encountered while decoding or processing the DICOM are logged.
        private func calculateOptimalWindow() async {
            do {
                let decoder = try await DCMDecoder(contentsOfFile: dicomURL.path)

                guard let pixels16 = decoder.getPixels16() else {
                    print("No pixel data available")
                    return
                }

                // Calculate optimal window/level using V2 API
                let optimalSettings = DCMWindowingProcessor.calculateOptimalWindowLevelV2(
                    pixels16: pixels16
                )

                // Update view model and image
                windowingVM.setWindowLevel(
                    center: optimalSettings.center,
                    width: optimalSettings.width
                )

                await imageVM.updateWindowing(
                    windowingMode: .custom(
                        center: optimalSettings.center,
                        width: optimalSettings.width
                    )
                )

                print("Applied optimal window: C=\(optimalSettings.center) W=\(optimalSettings.width)")
            } catch {
                print("Error calculating optimal window: \(error)")
            }
        }
    }

    return OptimalWindowView(dicomURL: URL(fileURLWithPath: "/path/to/image.dcm"))
}

/// Displays a scrollable comparison of medical windowing presets, showing each preset's name, a preview image rendered with that preset, and the numeric window center and width.
/// 
/// The view iterates over a fixed set of presets (lung, bone, soft tissue, liver), rendering a DICOM image for each using the corresponding preset windowing and showing the preset's calculated center and width below the image.
/// Renders a scrollable comparison of common medical windowing presets applied to a single DICOM image.
/// 
/// Each preset (lung, bone, soft tissue, liver) is shown with a preview image rendered using that preset
/// and a caption displaying the preset's computed window center (C) and width (W).
/// - Returns: A SwiftUI view containing vertically stacked preset previews and their C/W values.
func comparePresets() -> some View {
    struct ComparePresetsView: View {
        @StateObject private var imageVM = DicomImageViewModel()
        let dicomURL: URL

        var body: some View {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach([MedicalPreset.lung, .bone, .softTissue, .liver], id: \.self) { preset in
                        VStack(spacing: 8) {
                            Text(preset.displayName)
                                .font(.headline)

                            DicomImageView(
                                url: dicomURL,
                                windowingMode: .preset(preset)
                            )
                            .frame(height: 200)
                            .cornerRadius(8)
                            .shadow(radius: 4)

                            let settings = DCMWindowingProcessor.getPresetValuesV2(preset: preset)
                            Text("C: \(Int(settings.center)), W: \(Int(settings.width))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
            }
        }
    }

    return ComparePresetsView(dicomURL: URL(fileURLWithPath: "/path/to/ct_scan.dcm"))
}

// MARK: - Complete Windowing Application

/// Creates a complete DICOM windowing sample with interactive controls and optional image-quality metrics.
///
/// The returned view presents a large DICOM image area, a `WindowingControlView` that applies presets or custom center/width values, and a toggleable metrics panel that shows contrast and SNR when available.
/// - Returns: A SwiftUI view demonstrating a full windowing app with image display, windowing controls (preset and custom), and optional quality metrics.
func fullWindowingApp() -> some View {
    struct WindowingApp: View {
        @StateObject private var windowingVM = WindowingViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        @State private var showingQualityMetrics = false
        @State private var qualityMetrics: (contrast: Double, snr: Double)?
        let dicomURL: URL

        var body: some View {
            NavigationView {
                VStack(spacing: 0) {
                    // Main image display
                    DicomImageView(viewModel: imageVM)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)

                    // Quality metrics (if available)
                    if let metrics = qualityMetrics, showingQualityMetrics {
                        HStack(spacing: 16) {
                            VStack {
                                Text("Contrast")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.2f", metrics.contrast))
                                    .font(.headline)
                            }

                            Divider()

                            VStack {
                                Text("SNR")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.2f", metrics.snr))
                                    .font(.headline)
                            }
                        }
                        .padding()
                        .background(Color.secondary.opacity(0.1))
                    }

                    // Windowing controls
                    WindowingControlView(
                        windowingViewModel: windowingVM,
                        onPresetSelected: { preset in
                            Task {
                                await applyWindowingAndCalculateMetrics(
                                    windowingMode: .preset(preset)
                                )
                            }
                        },
                        onWindowingChanged: { settings in
                            Task {
                                await applyWindowingAndCalculateMetrics(
                                    windowingMode: .custom(
                                        center: settings.center,
                                        width: settings.width
                                    )
                                )
                            }
                        }
                    )
                    .background(platformSystemBackground)
                }
                .navigationTitle("DICOM Windowing")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: {
                            showingQualityMetrics.toggle()
                        }) {
                            Image(systemName: showingQualityMetrics ? "chart.bar.fill" : "chart.bar")
                        }
                    }
                }
            }
            .task {
                await imageVM.loadImage(from: dicomURL)
                await calculateQualityMetrics()
            }
        }

        /// Applies the specified windowing mode to the image view model and updates the stored image quality metrics.
        /// - Parameters:
        /// Apply a windowing mode to the current DICOM image and recompute image quality metrics.
        /// - Parameters:
        ///   - windowingMode: The windowing mode to apply (preset or custom center/width).
        private func applyWindowingAndCalculateMetrics(
            windowingMode: DicomImageRenderer.WindowingMode
        ) async {
            await imageVM.updateWindowing(windowingMode: windowingMode)
            await calculateQualityMetrics()
        }

        /// Calculates image quality metrics (contrast and SNR) for the DICOM at `dicomURL` and stores the results in `qualityMetrics`.
        /// 
        /// Computes image quality metrics (contrast and SNR) for the DICOM at `dicomURL` and stores the results in `qualityMetrics`.
        /// 
        /// If decoding or metric calculation fails, `qualityMetrics` is not modified and the error is logged.
        private func calculateQualityMetrics() async {
            do {
                let decoder = try await DCMDecoder(contentsOfFile: dicomURL.path)

                guard let pixels16 = decoder.getPixels16() else { return }

                // Calculate quality metrics
                let contrast = DCMWindowingProcessor.calculateContrast(pixels16: pixels16)
                let snr = DCMWindowingProcessor.calculateSNR(pixels16: pixels16)

                qualityMetrics = (contrast: contrast, snr: snr)
            } catch {
                print("Error calculating metrics: \(error)")
            }
        }
    }

    return WindowingApp(dicomURL: URL(fileURLWithPath: "/path/to/ct_scan.dcm"))
}

// MARK: - Persistence and State Restoration

/// Demonstrates persisting and restoring window center and width for a DICOM image.
/// 
/// The view displays a DICOM image and a windowing control; it saves the last-used window center and width to `AppStorage` when changed and restores those values when the view appears.
/// Presents a DICOM image with a windowing control that persists and restores the last-used window center and width.
/// 
/// The view saves window center and width to AppStorage whenever the control changes and restores those values when the view appears, applying them to the displayed image.
/// - Returns: A SwiftUI view containing a DICOM image and a windowing control that persists the last window center and width.
func persistWindowingSettings() -> some View {
    struct PersistentWindowingView: View {
        @StateObject private var windowingVM = WindowingViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        @AppStorage("lastWindowCenter") private var savedCenter: Double = 50.0
        @AppStorage("lastWindowWidth") private var savedWidth: Double = 400.0
        let dicomURL: URL

        var body: some View {
            VStack {
                DicomImageView(viewModel: imageVM)

                WindowingControlView(
                    windowingViewModel: windowingVM,
                    onWindowingChanged: { settings in
                        // Save settings
                        savedCenter = settings.center
                        savedWidth = settings.width

                        Task {
                            await imageVM.updateWindowing(
                                windowingMode: .custom(
                                    center: settings.center,
                                    width: settings.width
                                )
                            )
                        }
                    }
                )
            }
            .task {
                // Restore last settings
                windowingVM.setWindowLevel(center: savedCenter, width: savedWidth)

                await imageVM.loadImage(
                    from: dicomURL,
                    windowingMode: .custom(center: savedCenter, width: savedWidth)
                )
            }
        }
    }

    return PersistentWindowingView(dicomURL: URL(fileURLWithPath: "/path/to/image.dcm"))
}
