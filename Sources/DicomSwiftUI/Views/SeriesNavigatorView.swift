//
//  SeriesNavigatorView.swift
//
//  SwiftUI view for navigating through DICOM series slices
//
//  This view provides a complete interface for navigating through a series of
//  DICOM images (slices) with multiple interaction modes: sequential navigation
//  via buttons, direct navigation via slider, and jump to first/last.
//
//  The view integrates with SeriesNavigatorViewModel for state management and
//  provides callbacks for navigation events so you can update the displayed
//  image accordingly. It supports both compact and expanded layouts for
//  different UI contexts.
//
//  Platform Availability:
//
//  Available on the package's iOS, visionOS, and macOS 26+ targets.
//  Uses native SwiftUI components for optimal performance and platform integration.
//
//  Accessibility:
//
//  All interactive controls include proper accessibility labels, hints, and values
//  for VoiceOver support. Navigation state is announced dynamically.
//

import SwiftUI
import DicomCore

/// A SwiftUI view for navigating through DICOM series slices.
///
/// ## Overview
///
/// ``SeriesNavigatorView`` provides a comprehensive control panel for navigating through
/// a series of DICOM images (slices). It offers multiple interaction modes including
/// sequential navigation buttons, direct navigation via slider, jump-to-first/last
/// buttons.
///
/// The view is designed to work with ``SeriesNavigatorViewModel`` for state management
/// and provides callbacks when navigation occurs so you can update the displayed image.
/// It supports both compact and expanded layouts for different UI contexts.
///
/// **Key Features:**
/// - Previous/Next navigation buttons
/// - Slice counter display (e.g., "3 / 150")
/// - Interactive slider for direct navigation
/// - First/Last jump buttons
/// - Thumbnail-backed slice shortcut strip in expanded layout
/// - Customizable layout (compact or expanded)
/// - Dark mode support
/// - Full accessibility support for VoiceOver
///
/// **Control Layout:**
/// - First/Previous/Next/Last buttons
/// - Current position indicator (e.g., "25 / 150")
/// - Slider for direct slice selection
/// - Progress percentage display
///
/// ## Usage
///
/// Basic usage with default layout:
///
/// ```swift
/// struct SeriesViewer: View {
///     @StateObject private var navigatorVM = SeriesNavigatorViewModel()
///     @StateObject private var imageVM = DicomImageViewModel()
///     let seriesURLs: [URL]
///
///     var body: some View {
///         VStack {
///             // Display current image
///             DicomImageView(viewModel: imageVM)
///
///             // Navigation controls
///             SeriesNavigatorView(
///                 navigatorViewModel: navigatorVM,
///                 onNavigate: { url in
///                     Task {
///                         await imageVM.loadImage(from: url)
///                     }
///                 }
///             )
///         }
///         .onAppear {
///             navigatorVM.setSeriesURLs(seriesURLs)
///             if let firstURL = navigatorVM.currentURL {
///                 Task {
///                     await imageVM.loadImage(from: firstURL)
///                 }
///             }
///         }
///     }
/// }
/// ```
///
/// Compact layout for embedded use:
///
/// ```swift
/// SeriesNavigatorView(
///     navigatorViewModel: navigatorVM,
///     layout: .compact,
///     onNavigate: { url in
///         Task {
///             await imageVM.loadImage(from: url)
///         }
///     }
/// )
/// .padding()
/// .background(Color.secondary.opacity(0.1))
/// .cornerRadius(8)
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
/// - ``init(navigatorViewModel:layout:onNavigate:)``
///
/// ### Layout Options
///
/// - ``Layout``
///
public struct SeriesNavigatorView: View {

    // MARK: - Layout Options

    /// Layout style for the series navigator control panel.
    ///
    /// Controls the visual density and spacing of the navigation interface. Use
    /// expanded layout for primary navigation controls and compact layout for
    /// embedded or space-constrained contexts.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Full layout for main navigator
    /// SeriesNavigatorView(
    ///     navigatorViewModel: viewModel,
    ///     layout: .expanded
    /// )
    ///
    /// // Compact layout for embedded control
    /// SeriesNavigatorView(
    ///     navigatorViewModel: viewModel,
    ///     layout: .compact
    /// )
    /// ```
    public enum Layout {
        /// Full layout with all controls and labels.
        ///
        /// Provides standard spacing (16pt), full-size fonts (.title2, .headline),
        /// labeled buttons, progress percentage, and a thumbnail-backed slice
        /// shortcut strip. Best for primary navigation contexts where space is
        /// not constrained.
        case expanded

        /// Compact layout for embedded use.
        ///
        /// Uses smaller spacing (12pt), reduced fonts (.title3, .body), icon-only
        /// buttons, and no slice shortcut strip. Ideal for toolbars, sidebars, or embedded
        /// contexts where space is limited.
        case compact
    }

    // MARK: - Properties

    /// View model managing navigation state
    @ObservedObject private var navigatorViewModel: SeriesNavigatorViewModel

    /// Layout style for the control panel
    private let layout: Layout

    /// Callback when navigation occurs (provides new current URL)
    private let onNavigate: ((URL) -> Void)?

    // Local state for slider editing
    @State private var isEditingSlider = false
    @State private var tempSliderValue: Double

    // MARK: - Initializers

    /// Creates a series navigator view.
    ///
    /// Provides a complete control panel for navigating through DICOM series with buttons
    /// and slider. The view observes the provided view model
    /// for state changes and calls the navigation callback when the current image changes.
    ///
    /// - Parameters:
    ///   - navigatorViewModel: View model managing navigation state
    ///   - layout: Layout style (`.expanded` or `.compact`). Defaults to `.expanded`
    ///   - onNavigate: Optional callback when navigation occurs, provides current URL
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var navigatorVM = SeriesNavigatorViewModel()
    /// @StateObject private var imageVM = DicomImageViewModel()
    ///
    /// SeriesNavigatorView(
    ///     navigatorViewModel: navigatorVM,
    ///     onNavigate: { url in
    ///         Task {
    ///             await imageVM.loadImage(from: url)
    ///         }
    ///     }
    /// )
    /// ```
    ///
    public init(
        navigatorViewModel: SeriesNavigatorViewModel,
        layout: Layout = .expanded,
        onNavigate: ((URL) -> Void)? = nil
    ) {
        self.navigatorViewModel = navigatorViewModel
        self.layout = layout
        self.onNavigate = onNavigate

        // Initialize temp slider value with current index
        _tempSliderValue = State(initialValue: Double(navigatorViewModel.currentIndex))
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: layout == .compact ? 12 : 16) {
            SeriesNavigatorPositionIndicatorView(
                navigatorViewModel: navigatorViewModel,
                layout: layout
            )

            SeriesNavigatorNavigationButtonsView(
                navigatorViewModel: navigatorViewModel,
                layout: layout
            )

            if !navigatorViewModel.isEmpty {
                SeriesNavigatorSliderView(
                    navigatorViewModel: navigatorViewModel,
                    layout: layout,
                    tempSliderValue: $tempSliderValue,
                    isEditingSlider: $isEditingSlider
                )
            }

            if layout == .expanded && !navigatorViewModel.isEmpty {
                SeriesNavigatorSliceShortcutStripView(
                    navigatorViewModel: navigatorViewModel
                )
            }
        }
        .padding(layout == .compact ? 12 : 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Series navigation controls")
        .onChangeCompat(
            of: navigatorViewModel.currentIndex,
            fallback: navigatorViewModel.$currentIndex
        ) { newIndex in
            // Sync temp slider value when view model changes externally
            if !isEditingSlider {
                tempSliderValue = Double(newIndex)
            }

            // Notify callback of navigation
            if let currentURL = navigatorViewModel.currentURL {
                onNavigate?(currentURL)
            }
        }
    }


}

// MARK: - SwiftUI Previews

#if DEBUG
struct SeriesNavigatorView_Previews: PreviewProvider {

    /// Creates sample series URLs for preview with realistic DICOM naming.
    /// - Parameters:
    ///   - count: Number of slices in the series
    ///   - modality: DICOM modality prefix (e.g., "CT", "MRI")
    ///   - studyName: Study description for file naming
    /// - Returns: Array of file URLs representing a DICOM series
    private static func createSampleSeriesURLs(count: Int, modality: String = "CT", studyName: String = "CHEST") -> [URL] {
        return (1...count).map { index in
            URL(fileURLWithPath: "/sample/series/\(modality)_\(studyName)_\(String(format: "%03d", index)).dcm")
        }
    }

    static var previews: some View {
        Group {
            // Expanded layout (default) with CT chest series
            SeriesNavigatorView(
                navigatorViewModel: {
                    let urls = createSampleSeriesURLs(count: 150, modality: "CT", studyName: "CHEST")
                    let vm = SeriesNavigatorViewModel(seriesURLs: urls)
                    vm.goToIndex(24) // Start at slice 25
                    return vm
                }()
            )
            .previewDisplayName("Expanded Layout - CT (25/150)")
            .frame(width: 500)
            .padding()

            // Compact layout with MRI series
            SeriesNavigatorView(
                navigatorViewModel: {
                    let urls = createSampleSeriesURLs(count: 50, modality: "MRI", studyName: "BRAIN")
                    let vm = SeriesNavigatorViewModel(seriesURLs: urls)
                    vm.goToIndex(9) // Start at slice 10
                    return vm
                }(),
                layout: .compact
            )
            .previewDisplayName("Compact Layout - MRI (10/50)")
            .frame(width: 400)
            .padding()

            // Empty state
            SeriesNavigatorView(
                navigatorViewModel: SeriesNavigatorViewModel()
            )
            .previewDisplayName("Empty State")
            .frame(width: 400)
            .padding()

            // First slice - CT series
            SeriesNavigatorView(
                navigatorViewModel: {
                    let urls = createSampleSeriesURLs(count: 100, modality: "CT", studyName: "ABDOMEN")
                    let vm = SeriesNavigatorViewModel(seriesURLs: urls)
                    return vm
                }()
            )
            .previewDisplayName("First Slice - CT (1/100)")
            .frame(width: 500)
            .padding()

            // Last slice - CT series
            SeriesNavigatorView(
                navigatorViewModel: {
                    let urls = createSampleSeriesURLs(count: 100, modality: "CT", studyName: "ABDOMEN")
                    let vm = SeriesNavigatorViewModel(seriesURLs: urls)
                    vm.goToLast()
                    return vm
                }()
            )
            .previewDisplayName("Last Slice - CT (100/100)")
            .frame(width: 500)
            .padding()

            // Dark mode with MRI series
            SeriesNavigatorView(
                navigatorViewModel: {
                    let urls = createSampleSeriesURLs(count: 75, modality: "MRI", studyName: "SPINE")
                    let vm = SeriesNavigatorViewModel(seriesURLs: urls)
                    vm.goToIndex(37)
                    return vm
                }()
            )
            .preferredColorScheme(.dark)
            .previewDisplayName("Dark Mode - MRI (38/75)")
            .frame(width: 500)
            .padding()

            // Light mode with MRI series
            SeriesNavigatorView(
                navigatorViewModel: {
                    let urls = createSampleSeriesURLs(count: 75, modality: "MRI", studyName: "SPINE")
                    let vm = SeriesNavigatorViewModel(seriesURLs: urls)
                    vm.goToIndex(37)
                    return vm
                }()
            )
            .preferredColorScheme(.light)
            .previewDisplayName("Light Mode - MRI (38/75)")
            .frame(width: 500)
            .padding()

            // Small series (10 images) - X-ray
            SeriesNavigatorView(
                navigatorViewModel: {
                    let urls = createSampleSeriesURLs(count: 10, modality: "XR", studyName: "CHEST")
                    let vm = SeriesNavigatorViewModel(seriesURLs: urls)
                    vm.goToIndex(4)
                    return vm
                }()
            )
            .previewDisplayName("Small Series - XR (5/10)")
            .frame(width: 500)
            .padding()
        }
    }
}
#endif
