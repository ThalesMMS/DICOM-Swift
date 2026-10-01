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

// MARK: - Platform And Migration Notes

/// Platform compatibility for these examples:
/// - iOS, visionOS, or macOS 26.0 or later
///
/// Recommended vs legacy DICOM loading:
///
/// Recommended (new):
/// ```swift
/// Task {
///     do {
///         let decoder = try await DCMDecoder(contentsOfFile: url.path)
///         // Use decoder
///     } catch {
///         // Handle DICOMError
///     }
/// }
/// ```
///
/// Legacy (deprecated):
/// ```swift
/// let decoder = DCMDecoder()
/// decoder.setDicomFilename(url.path)
/// guard decoder.dicomFileReadSuccess else { return }
/// // Use decoder
/// ```
///
/// Migration note:
/// Replace `setDicomFilename(_:)` + `dicomFileReadSuccess` checks with
/// throwing initializers (`init(contentsOf:)` or `init(contentsOfFile:)`) and
/// standard `do`/`catch` error handling.
private enum ImageViewLoadingMigrationNotes {}

// MARK: - Basic DICOM Image Display

/// Displays a DICOM image loaded from a local file in a 400×400 framed view.
/// Create a 400×400 view that displays a DICOM image from a local file with a 1-point gray border.
/// - Returns: A SwiftUI view rendering the DICOM image loaded from `/path/to/ct_scan.dcm`, constrained to 400×400 points and framed with a 1‑point gray border.
func simpleImageDisplay() -> some View {
    let dicomURL = URL(fileURLWithPath: "/path/to/ct_scan.dcm")

    return DicomImageView(url: dicomURL)
        .frame(width: 400, height: 400)
        .border(Color.gray, width: 1)
}

/// Displays a DICOM image using automatic windowing.
/// Create a view that renders a DICOM MR scan using automatic windowing.
/// - Returns: A view that displays the DICOM file at "/path/to/mr_scan.dcm" with automatic windowing, fills the available space, and uses a black background.
func automaticWindowing() -> some View {
    let dicomURL = URL(fileURLWithPath: "/path/to/mr_scan.dcm")

    return DicomImageView(
        url: dicomURL,
        windowingMode: .automatic
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
}

// MARK: - Medical Imaging Presets

/// Displays a CT chest DICOM image using a lung window preset.
/// 
/// The returned view loads a DICOM file from a file URL, applies the lung windowing preset, fixes the view to 512×512 points, and sets an accessibility label describing the content.
/// Show a CT chest DICOM image using the lung window preset.
/// - Returns: A view that displays the DICOM image with the lung window preset, constrained to a 512×512 frame and annotated with an accessibility label describing it as a CT chest scan with lung window.
func lungPresetDisplay() -> some View {
    let ctURL = URL(fileURLWithPath: "/path/to/ct_chest.dcm")

    return DicomImageView(
        url: ctURL,
        windowingMode: .preset(.lung)
    )
    .frame(width: 512, height: 512)
    .accessibilityLabel("CT chest scan with lung window")
}

/// Displays a CT DICOM image using the bone windowing preset.
/// Creates a SwiftUI view that renders a CT DICOM using the bone windowing preset.
/// The view loads the image from the local file URL "/path/to/ct_spine.dcm" and preserves aspect ratio.
/// - Returns: A view that displays the DICOM image using the bone windowing preset with an aspect-fit content mode.
func bonePresetDisplay() -> some View {
    let ctURL = URL(fileURLWithPath: "/path/to/ct_spine.dcm")

    return DicomImageView(
        url: ctURL,
        windowingMode: .preset(.bone)
    )
    .aspectRatio(contentMode: .fit)
}

// MARK: - Custom Windowing

/// Displays a DICOM image using an explicitly specified window center and width.
/// Display a DICOM image using an explicit window center and width.
/// - Returns: A view that renders the DICOM file at "/path/to/image.dcm" using a custom windowing mode (center = 50.0, width = 400.0) constrained to a 600×600 frame.
func customWindowing() -> some View {
    let dicomURL = URL(fileURLWithPath: "/path/to/image.dcm")

    return DicomImageView(
        url: dicomURL,
        windowingMode: .custom(center: 50.0, width: 400.0)
    )
    .frame(width: 600, height: 600)
}

/// Demonstrates using a WindowSettings value to apply custom window/level parameters to a DICOM image view.
/// Demonstrates rendering a DICOM image with explicit window center and width using a WindowSettings value.
/// - Returns: A SwiftUI view that displays the DICOM image at "/path/to/image.dcm" using a custom window center of 500.0 and width of 1500.0.
func windowSettingsV2Example() -> some View {
    struct ContentView: View {
        let dicomURL: URL
        let settings = WindowSettings(center: 500.0, width: 1500.0)

        var body: some View {
            DicomImageView(
                url: dicomURL,
                windowingMode: .custom(
                    center: settings.center,
                    width: settings.width
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    return ContentView(dicomURL: URL(fileURLWithPath: "/path/to/image.dcm"))
}

// MARK: - GPU Acceleration

/// Displays a large CT DICOM image using GPU-accelerated processing and a soft-tissue window preset.
/// Displays a large CT DICOM image using GPU-accelerated processing with a soft-tissue window preset.
/// - Returns: A view that renders the DICOM at 1024×1024 using the soft-tissue windowing preset and Metal processing.
func gpuAcceleration() -> some View {
    let largeImageURL = URL(fileURLWithPath: "/path/to/large_ct.dcm")

    return DicomImageView(
        url: largeImageURL,
        windowingMode: .preset(.softTissue),
        processingMode: .metal
    )
    .frame(width: 1024, height: 1024)
}

/// Displays a DICOM image while automatically selecting the optimal processing backend.
///
/// The view renders a DICOM file using automatic windowing and lets the library choose the processing mode (e.g., Metal for large images, vDSP for smaller ones).
/// - Returns: A SwiftUI view that presents the DICOM image from the bundled file URL with automatic windowing and automatic processing mode.
func autoProcessingMode() -> some View {
    let dicomURL = URL(fileURLWithPath: "/path/to/image.dcm")

    // Automatically uses Metal for images ≥800x800, vDSP for smaller
    return DicomImageView(
        url: dicomURL,
        windowingMode: .automatic,
        processingMode: .auto
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

// MARK: - Advanced View Model Control

/// Presents a SwiftUI DICOM viewer that exposes view-model-driven windowing controls and reload functionality.
/// Presents an interactive DICOM viewer backed by a view model with windowing controls and reload support.
///
/**
 Displays a view that loads a DICOM file, renders it using `DicomImageView` and a `DicomImageViewModel`, shows loading status or the loaded image dimensions, and provides buttons to apply lung/bone windowing presets or reload the image.
 
 - Returns: A SwiftUI view containing the DICOM viewer with status and control buttons.
 */
func advancedViewModelControl() -> some View {
    struct AdvancedDicomViewer: View {
        @StateObject private var viewModel = DicomImageViewModel()
        let dicomURL: URL

        var body: some View {
            VStack {
                // Display image
                DicomImageView(viewModel: viewModel)
                    .frame(height: 400)

                // Status information
                if viewModel.state == .loading {
                    ProgressView("Loading DICOM image...")
                } else if case .loaded = viewModel.state {
                    Text("Image: \(viewModel.imageWidth) × \(viewModel.imageHeight)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Control buttons
                HStack(spacing: 12) {
                    Button("Lung") {
                        Task {
                            await viewModel.updateWindowing(
                                windowingMode: .preset(.lung)
                            )
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("Bone") {
                        Task {
                            await viewModel.updateWindowing(
                                windowingMode: .preset(.bone)
                            )
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("Reload") {
                        Task {
                            await viewModel.loadImage(from: dicomURL)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
            .onAppear {
                Task {
                    await viewModel.loadImage(from: dicomURL)
                }
            }
        }
    }

    return AdvancedDicomViewer(dicomURL: URL(fileURLWithPath: "/path/to/image.dcm"))
}

// MARK: - Pre-loaded Decoder

/// Displays a DICOM image using a preloaded `DCMDecoder`, exposing decoded metadata before rendering.
///
/// The returned view attempts to initialize a `DCMDecoder` from a bundled file URL, reads the `patientName` and `modality` metadata (and prints a brief log), and then renders a `DicomImageView` driven by that decoder with automatic windowing. If decoder initialization fails, the view instead presents a simple error message.
/// Creates a view that preloads a `DCMDecoder`, logs basic metadata, and displays the decoded image with automatic windowing.
/// 
/// The function attempts to initialize a `DCMDecoder` from a local file URL, reads and logs patient and modality metadata before rendering, and returns either the image view or a textual error view if decoder initialization fails.
/// - Returns: A view that renders the DICOM image using a preloaded `DCMDecoder` with automatic windowing, or a `Text` view describing the load error.
func preloadedDecoder() -> some View {
    struct PreloadedView: View {
        let url: URL
        @State private var decoder: DCMDecoder?
        @State private var loadError: String?

        var body: some View {
            Group {
                if let decoder = decoder {
                    DicomImageView(
                        decoder: decoder,
                        windowingMode: .automatic
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError = loadError {
                    Text("Failed to load: \(loadError)")
                        .foregroundColor(.red)
                        .padding()
                } else {
                    ProgressView("Loading DICOM image...")
                }
            }
            .onAppear {
                Task {
                    await loadDecoder()
                }
            }
        }

        private func loadDecoder() async {
            await MainActor.run {
                decoder = nil
                loadError = nil
            }

            do {
                let loadedDecoder = try await DCMDecoder(contentsOfFile: url.path)

                // Access metadata after async load
                let patientName = loadedDecoder.info(for: .patientName)
                let modality = loadedDecoder.info(for: .modality)
                print("Loading \(modality) scan for \(patientName)")

                await MainActor.run {
                    decoder = loadedDecoder
                }
            } catch {
                await MainActor.run {
                    decoder = nil
                    loadError = error.localizedDescription
                }
            }
        }
    }

    return PreloadedView(url: URL(fileURLWithPath: "/path/to/image.dcm"))
}

// MARK: - Complete Integration Example

/// Builds and returns a complete DICOM viewer SwiftUI view with image display, interactive windowing controls, and a metadata sheet.
/// Creates a complete DICOM viewer sample UI.
/// 
/// The view displays a DICOM image with interactive windowing controls, a toolbar button that presents a metadata sheet (built from a decoder initialized from the same DICOM file), and loads the sample DICOM at `/path/to/ct_scan.dcm` when presented.
/// - Returns: A SwiftUI view that presents the full-featured DICOM viewer configured to load the sample DICOM file.
func completeDicomViewer() -> some View {
    struct CompleteDicomViewer: View {
        @StateObject private var imageVM = DicomImageViewModel()
        @StateObject private var windowingVM = WindowingViewModel()
        @State private var showingMetadata = false

        let dicomURL: URL

        struct MetadataSheetContent: View {
            let dicomURL: URL
            let onDone: () -> Void
            @State private var decoder: DCMDecoder?
            @State private var loadError: String?

            var body: some View {
                NavigationView {
                    Group {
                        if let decoder = decoder {
                            MetadataView(decoder: decoder)
                        } else if let loadError = loadError {
                            Text("Failed to load metadata: \(loadError)")
                                .foregroundColor(.red)
                                .padding()
                        } else {
                            ProgressView("Loading metadata...")
                        }
                    }
                    .navigationTitle("Metadata")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                onDone()
                            }
                        }
                    }
                }
                .onAppear {
                    Task {
                        await loadMetadataDecoder()
                    }
                }
            }

            private func loadMetadataDecoder() async {
                await MainActor.run {
                    decoder = nil
                    loadError = nil
                }

                do {
                    let loadedDecoder = try await DCMDecoder(contentsOfFile: dicomURL.path)
                    await MainActor.run {
                        decoder = loadedDecoder
                    }
                } catch {
                    await MainActor.run {
                        decoder = nil
                        loadError = error.localizedDescription
                    }
                }
            }
        }

        var body: some View {
            NavigationView {
                VStack(spacing: 0) {
                    // Image display
                    DicomImageView(viewModel: imageVM)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)

                    // Windowing controls
                    WindowingControlView(
                        windowingViewModel: windowingVM,
                        onPresetSelected: { preset in
                            Task {
                                await imageVM.updateWindowing(
                                    windowingMode: .preset(preset)
                                )
                            }
                        },
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
                    .background(platformSystemBackground)
                }
                .navigationTitle("DICOM Viewer")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Metadata") {
                            showingMetadata = true
                        }
                    }
                }
                .sheet(isPresented: $showingMetadata) {
                    MetadataSheetContent(dicomURL: dicomURL) {
                        showingMetadata = false
                    }
                }
            }
            .onAppear {
                Task {
                    await imageVM.loadImage(from: dicomURL)
                }
            }
        }
    }

    return CompleteDicomViewer(dicomURL: URL(fileURLWithPath: "/path/to/ct_scan.dcm"))
}

// MARK: - Error Handling

/// Example SwiftUI view that displays a DICOM image and presents a retryable error UI when loading fails.
/// 
/// The view uses a `DicomImageViewModel` to load the image from a fixed sample URL, shows an error banner with the failure message and a Retry button when loading fails, and starts an initial load when the view appears.
/// Demonstrates a DICOM image view with a retryable error UI.
/// 
/// The returned view loads a DICOM file into a `DicomImageViewModel`, displays the image via `DicomImageView`, and, if loading fails, presents an error banner containing the failure message and a "Retry" button.
/// - Returns: A SwiftUI view that displays the DICOM image and a retryable error UI when loading fails.
func errorHandling() -> some View {
    struct ErrorHandlingView: View {
        @StateObject private var viewModel = DicomImageViewModel()
        @State private var errorMessage: String?
        let dicomURL: URL

        var body: some View {
            VStack {
                DicomImageView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let error = errorMessage {
                    VStack(spacing: 8) {
                        Text("Error Loading Image")
                            .font(.headline)
                            .foregroundColor(.red)

                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Button("Retry") {
                            Task {
                                await loadImage()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
            }
            .onAppear {
                Task {
                    await loadImage()
                }
            }
        }

        /// Loads the DICOM image into the view model and updates the local error message state.
        /// Loads the DICOM image from `dicomURL` into `viewModel` and updates `errorMessage` to reflect the result.
        /// 
        /// On failure, `errorMessage` is set to the failure's `localizedDescription`. On success, `errorMessage` is cleared.
        private func loadImage() async {
            await viewModel.loadImage(from: dicomURL)

            // Check if loading succeeded
            if case .failed(let error) = viewModel.state {
                errorMessage = error.localizedDescription
            } else {
                errorMessage = nil
            }
        }
    }

    return ErrorHandlingView(dicomURL: URL(fileURLWithPath: "/path/to/image.dcm"))
}

// MARK: - Async Loading

/// A SwiftUI example view demonstrating asynchronous DICOM image loading with a progress overlay.
/// 
/// The view loads a DICOM file in the background using a `DicomImageViewModel` and displays a centered progress indicator and message while the image is being loaded.
/// Displays a DICOM image and shows an in-view progress overlay while the image is loading.
/// - Returns: A SwiftUI view that renders the DICOM image and overlays a progress indicator and status text while the image is being loaded.
func asyncLoading() -> some View {
    struct AsyncLoadingView: View {
        @StateObject private var viewModel = DicomImageViewModel()
        @State private var isLoading = false
        @State private var loadTask: Task<Void, Never>?
        let dicomURL: URL

        var body: some View {
            ZStack {
                DicomImageView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Loading DICOM image...")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .padding(24)
                    .background(platformSystemBackground.opacity(0.9))
                    .cornerRadius(12)
                }
            }
            .onAppear {
                loadTask?.cancel()
                loadTask = Task {
                    isLoading = true
                    defer { isLoading = false }

                    await viewModel.loadImage(from: dicomURL)
                }
            }
            .onDisappear {
                loadTask?.cancel()
                loadTask = nil
                isLoading = false
            }
        }
    }

    return AsyncLoadingView(dicomURL: URL(fileURLWithPath: "/path/to/large_image.dcm"))
}

// MARK: - Multi-Image Display

/// Displays multiple DICOM images in a responsive, scrollable grid.
/// 
/// Each item in the grid shows a DICOM image using automatic windowing and a consistent thumbnail height, arranged in adaptive columns that fit the available width.
/// Display multiple DICOM images in a responsive grid of thumbnails.
/// 
/// The returned view arranges the supplied DICOM file URLs into an adaptive grid of thumbnail image views, each using automatic windowing and a fixed thumbnail height with rounded corners and a shadow.
/// - Returns: A view presenting the DICOM images as an adaptive, scrollable thumbnail grid.
func multiImageGrid() -> some View {
    struct MultiImageGrid: View {
        let imageURLs: [URL]

        var body: some View {
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 200), spacing: 16)
                ], spacing: 16) {
                    ForEach(imageURLs, id: \.self) { url in
                        DicomImageView(
                            url: url,
                            windowingMode: .automatic
                        )
                        .frame(height: 200)
                        .cornerRadius(8)
                        .shadow(radius: 4)
                    }
                }
                .padding()
            }
        }
    }

    let urls = [
        URL(fileURLWithPath: "/path/to/image1.dcm"),
        URL(fileURLWithPath: "/path/to/image2.dcm"),
        URL(fileURLWithPath: "/path/to/image3.dcm"),
        URL(fileURLWithPath: "/path/to/image4.dcm")
    ]

    return MultiImageGrid(imageURLs: urls)
}

// MARK: - Platform-Specific Adaptations

/// Provides a cross-platform SwiftUI DICOM viewer that adapts its layout for iOS and macOS.
/// 
/// On iOS the view presents the image full‑screen with a compact bottom toolbar; on macOS it presents an HSplitView with the image and a sidebar of controls.
/// A cross-platform SwiftUI DICOM viewer that adapts its layout for iOS and macOS.
///
/// On iOS the view presents the image full-screen with a compact bottom toolbar. On macOS it presents a split view with the image on the left and a control sidebar on the right.
/// - Returns: A SwiftUI view that displays a DICOM image using an internal `DicomImageViewModel`, with platform-specific controls and layout.
func crossPlatformViewer() -> some View {
    struct CrossPlatformViewer: View {
        @StateObject private var viewModel = DicomImageViewModel()
        let dicomURL: URL

        var body: some View {
            #if os(iOS)
            // iOS-specific layout with compact controls
            VStack(spacing: 0) {
                DicomImageView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .edgesIgnoringSafeArea(.all)

                // Compact toolbar at bottom
                HStack {
                    Button(action: { /* ... */ }) {
                        Image(systemName: "slider.horizontal.3")
                    }
                    Spacer()
                    Button(action: { /* ... */ }) {
                        Image(systemName: "info.circle")
                    }
                }
                .padding()
                .background(platformSystemBackground)
            }
            #elseif os(macOS)
            // macOS-specific layout with sidebar
            HSplitView {
                // Main image view
                DicomImageView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)

                // Sidebar with controls
                VStack {
                    Text("Controls")
                        .font(.headline)
                    // Additional controls here
                    Spacer()
                }
                .frame(width: 250)
                .padding()
            }
            #endif
            .onAppear {
                Task {
                    await viewModel.loadImage(from: dicomURL)
                }
            }
        }
    }

    return CrossPlatformViewer(dicomURL: URL(fileURLWithPath: "/path/to/image.dcm"))
}
