//
//  DicomImageView.swift
//
//  SwiftUI view for displaying DICOM medical images
//
//  This view provides a complete DICOM image viewing experience with automatic
//  image loading, windowing transformations, loading indicators, and error
//  handling. It wraps DicomImageViewModel to provide reactive state management
//  and integrates seamlessly with SwiftUI's declarative view hierarchy.
//
//  The view automatically handles image scaling and aspect ratio preservation,
//  making it suitable for both embedded and full-screen display scenarios. It
//  supports both URL-based loading and pre-loaded DCMDecoder instances.
//
//  Platform Availability:
//
//  Available on the package's iOS, visionOS, and macOS 26+ targets.
//  Uses native SwiftUI components for optimal performance and platform integration.
//
//  Accessibility:
//
//  The view includes proper accessibility labels and hints for VoiceOver support.
//  Loading states and error messages are announced to assistive technologies.
//

import SwiftUI
import DicomCore

/// A SwiftUI view for displaying DICOM medical images.
///
/// ## Overview
///
/// ``DicomImageView`` provides a complete DICOM image viewing experience in SwiftUI.
/// It handles the entire image lifecycle: loading, windowing transformations, error
/// handling, and display. The view automatically adapts to different loading states
/// with progress indicators and error messages.
///
/// **Key Features:**
/// - Automatic image loading and rendering
/// - Loading state with progress indicator
/// - Error handling with descriptive messages
/// - Automatic aspect ratio preservation
/// - Resizable image with .fit content mode
/// - Accessibility support for VoiceOver
/// - Reactive updates via ``DicomImageViewModel``
///
/// **Display Characteristics:**
/// - Automatically scales to fit container
/// - Preserves original aspect ratio
/// - Uses grayscale color space for medical imaging
/// - Supports GPU-accelerated windowing
///
/// ## Usage
///
/// Load and display a DICOM file from URL:
///
/// ```swift
/// struct ContentView: View {
///     let dicomURL: URL
///
///     var body: some View {
///         DicomImageView(url: dicomURL)
///             .frame(width: 400, height: 400)
///             .border(Color.gray, width: 1)
///     }
/// }
/// ```
///
/// Display with custom windowing preset:
///
/// ```swift
/// DicomImageView(
///     url: dicomURL,
///     windowingMode: .preset(.lung)
/// )
/// .frame(maxWidth: .infinity, maxHeight: .infinity)
/// ```
///
/// Use pre-loaded decoder:
///
/// ```swift
/// Task {
///     do {
///         let decoder = try await DCMDecoder(contentsOfFile: url.path)
///
///         DicomImageView(decoder: decoder)
///             .aspectRatio(contentMode: .fit)
///     } catch {
///         // Handle DICOMError
///     }
/// }
/// ```
///
/// Access view model for custom interactions:
///
/// ```swift
/// struct CustomDicomViewer: View {
///     @StateObject private var viewModel = DicomImageViewModel()
///     let url: URL
///
///     var body: some View {
///         VStack {
///             DicomImageView(viewModel: viewModel)
///
///             // Custom controls
///             HStack {
///                 Button("Lung") {
///                     Task {
///                         await viewModel.updateWindowing(
///                             windowingMode: .preset(.lung)
///                         )
///                     }
///                 }
///                 Button("Bone") {
///                     Task {
///                         await viewModel.updateWindowing(
///                             windowingMode: .preset(.bone)
///                         )
///                     }
///                 }
///             }
///         }
///         .task {
///             await viewModel.loadImage(from: url)
///         }
///     }
/// }
/// ```
///
/// ### View Modifiers
///
/// Apply standard SwiftUI modifiers for layout and styling:
/// - `.frame()` - Set container dimensions
/// - `.aspectRatio(contentMode:)` - Override default `.fit` mode
/// - `.background()` - Add background color
/// - `.border()` - Add border for debugging
///
/// ## Topics
///
/// ### Creating a View
///
/// - ``init(url:windowingMode:processingMode:)``
/// - ``init(decoder:windowingMode:processingMode:)``
/// - ``init(viewModel:)``
///
public struct DicomImageView: View {

    // MARK: - Properties

    /// View model owned by this view (used by URL/decoder initializers).
    @StateObject private var ownedViewModel: DicomImageViewModel

    /// View model observed from outside this view (used by init(viewModel:)).
    @ObservedObject private var observedViewModel: DicomImageViewModel

    /// Indicates whether this instance is using an externally-managed observed model.
    private let usesObservedViewModel: Bool

    /// URL to load (if provided)
    private let url: URL?

    /// Decoder to load (if provided)
    private let decoder: DCMDecoder?

    /// Windowing mode to use
    private let windowingMode: DicomImageRenderer.WindowingMode

    /// Processing mode (CPU/GPU)
    private let processingMode: ProcessingMode

    /// Active view model for rendering and state access.
    private var viewModel: DicomImageViewModel {
        usesObservedViewModel ? observedViewModel : ownedViewModel
    }

    /// Stable key describing what should be auto-loaded by this view.
    private var loadTriggerKey: String {
        if let url {
            return "url:\(url.absoluteString)"
        }
        if let decoder {
            return "decoder:\(ObjectIdentifier(decoder).hashValue)"
        }
        return "none"
    }

    // MARK: - Initializers

    /// Creates a DICOM image view from a file URL.
    ///
    /// Loads and displays a DICOM image from the specified URL. The view automatically
    /// handles loading states, applies windowing transformations, and displays the
    /// resulting image with proper scaling.
    ///
    /// The view uses a ``DicomImageViewModel`` internally and triggers loading via
    /// SwiftUI's `.task()` modifier when the view appears.
    ///
    /// - Parameters:
    ///   - url: URL to the DICOM file (.dcm, .dicom)
    ///   - windowingMode: How to determine window/level values. Defaults to `.automatic`
    ///   - processingMode: CPU (vDSP) or GPU (Metal) acceleration. Defaults to `.auto`
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Simple usage with automatic windowing
    /// DicomImageView(url: fileURL)
    ///
    /// // With CT lung preset
    /// DicomImageView(
    ///     url: ctURL,
    ///     windowingMode: .preset(.lung)
    /// )
    ///
    /// // Force GPU acceleration
    /// DicomImageView(
    ///     url: largeImageURL,
    ///     processingMode: .metal
    /// )
    /// ```
    ///
    public init(
        url: URL,
        windowingMode: DicomImageRenderer.WindowingMode = .automatic,
        processingMode: ProcessingMode = .auto
    ) {
        let viewModel = DicomImageViewModel()
        _ownedViewModel = StateObject(wrappedValue: viewModel)
        _observedViewModel = ObservedObject(wrappedValue: viewModel)
        self.usesObservedViewModel = false
        self.url = url
        self.decoder = nil
        self.windowingMode = windowingMode
        self.processingMode = processingMode
    }

    /// Creates a DICOM image view from a pre-loaded decoder.
    ///
    /// Displays a DICOM image from an existing `DCMDecoder` instance. This is useful
    /// when you already have a decoder (e.g., for metadata inspection) and want to
    /// display it with specific windowing settings.
    ///
    /// - Parameters:
    ///   - decoder: An initialized `DCMDecoder` with loaded DICOM file
    ///   - windowingMode: How to determine window/level values. Defaults to `.automatic`
    ///   - processingMode: CPU (vDSP) or GPU (Metal) acceleration. Defaults to `.auto`
    ///
    /// ## Example
    ///
    /// ```swift
    /// Task {
    ///     do {
    ///         // Load decoder first for metadata access
    ///         let decoder = try await DCMDecoder(contentsOfFile: url.path)
    ///         let patientName = decoder.info(for: .patientName)
    ///
    ///         // Display with preset
    ///         DicomImageView(
    ///             decoder: decoder,
    ///             windowingMode: .preset(.brain)
    ///         )
    ///     } catch {
    ///         // Handle DICOMError
    ///     }
    /// }
    /// ```
    ///
    public init(
        decoder: DCMDecoder,
        windowingMode: DicomImageRenderer.WindowingMode = .automatic,
        processingMode: ProcessingMode = .auto
    ) {
        let viewModel = DicomImageViewModel()
        _ownedViewModel = StateObject(wrappedValue: viewModel)
        _observedViewModel = ObservedObject(wrappedValue: viewModel)
        self.usesObservedViewModel = false
        self.url = nil
        self.decoder = decoder
        self.windowingMode = windowingMode
        self.processingMode = processingMode
    }

    /// Creates a DICOM image view with a custom view model.
    ///
    /// Allows you to provide your own ``DicomImageViewModel`` instance for advanced
    /// scenarios where you need to control loading or share state between views. You
    /// are responsible for calling ``DicomImageViewModel/loadImage(from:windowingMode:processingMode:)``
    /// on the view model. The view *observes* this external model and does not own it.
    ///
    /// - Parameter viewModel: A ``DicomImageViewModel`` instance to manage state
    ///
    /// ## Example
    ///
    /// ```swift
    /// struct CustomViewer: View {
    ///     @StateObject private var viewModel = DicomImageViewModel()
    ///
    ///     var body: some View {
    ///         VStack {
    ///             DicomImageView(viewModel: viewModel)
    ///
    ///             Button("Reload") {
    ///                 Task {
    ///                     await viewModel.loadImage(from: url)
    ///                 }
    ///             }
    ///         }
    ///         .task {
    ///             await viewModel.loadImage(from: url)
    ///         }
    ///     }
    /// }
    /// ```
    ///
    public init(viewModel: DicomImageViewModel) {
        _ownedViewModel = StateObject(wrappedValue: DicomImageViewModel())
        _observedViewModel = ObservedObject(wrappedValue: viewModel)
        self.usesObservedViewModel = true
        self.url = nil
        self.decoder = nil
        self.windowingMode = .automatic
        self.processingMode = .auto
    }

    // MARK: - Body

    public var body: some View {
        autoLoadingContent
            .accessibilityElement(children: .contain)
            .accessibilityLabel("DICOM Image Viewer")
    }

    private var autoLoadingContent: some View {
        baseContent
            .task(id: loadTriggerKey) {
                await performAutoLoad()
            }
    }

    private var baseContent: some View {
        DicomImageViewerContainer(state: viewModel.state)
            .environmentObject(viewModel)
    }

    private func performAutoLoad() async {
        // Auto-load if URL provided
        if let url = url {
            await viewModel.loadImage(
                from: url,
                windowingMode: windowingMode,
                processingMode: processingMode
            )
        } else if let decoder = decoder {
            await viewModel.loadImage(
                decoder: decoder,
                windowingMode: windowingMode,
                processingMode: processingMode
            )
        }
    }
}

// MARK: - SwiftUI Previews

#if DEBUG
struct DicomImageView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // CT with different windowing presets
            DicomImageView(viewModel: DicomImageViewModel.preview(.ctLung))
                .previewDisplayName("CT - Lung Window")
                .previewSize(.medium)

            DicomImageView(viewModel: DicomImageViewModel.preview(.ctBone))
                .previewDisplayName("CT - Bone Window")
                .previewSize(.medium)

            DicomImageView(viewModel: DicomImageViewModel.preview(.ctBrain))
                .previewDisplayName("CT - Brain Window")
                .previewSize(.medium)

            DicomImageView(viewModel: DicomImageViewModel.preview(.ctAbdomen))
                .previewDisplayName("CT - Abdomen Soft Tissue")
                .previewSize(.medium)

            // MRI examples
            DicomImageView(viewModel: DicomImageViewModel.preview(.mrBrain))
                .previewDisplayName("MRI - Brain T1")
                .previewSize(.medium)

            DicomImageView(viewModel: DicomImageViewModel.preview(.mrSpine))
                .previewDisplayName("MRI - Spine T2")
                .previewSize(.medium)

            // X-Ray example
            DicomImageView(viewModel: DicomImageViewModel.preview(.xrayChest))
                .previewDisplayName("X-Ray - Chest PA")
                .previewSize(.medium)

            // Ultrasound example
            DicomImageView(viewModel: DicomImageViewModel.preview(.ultrasound))
                .previewDisplayName("Ultrasound - Abdomen")
                .previewSize(.medium)

            // Different sizes
            DicomImageView(viewModel: DicomImageViewModel.preview(.ctLung))
                .previewDisplayName("Small Size")
                .previewSize(.small)

            DicomImageView(viewModel: DicomImageViewModel.preview(.ctLung))
                .previewDisplayName("Large Size")
                .previewSize(.large)

            // Dark/Light mode comparison
            DicomImageView(viewModel: DicomImageViewModel.preview(.ctBrain))
                .preferredColorScheme(.dark)
                .previewDisplayName("CT Brain - Dark Mode")
                .previewSize(.medium)

            DicomImageView(viewModel: DicomImageViewModel.preview(.ctBrain))
                .preferredColorScheme(.light)
                .previewDisplayName("CT Brain - Light Mode")
                .previewSize(.medium)

            // State examples
            DicomImageView(viewModel: DicomImageViewModel())
                .previewDisplayName("Idle State")
                .previewSize(.medium)

            DicomImageView(viewModel: PreviewHelpers.loadingViewModel())
                .previewDisplayName("Loading State")
                .previewSize(.medium)
        }
    }
}
#endif
