//
//  DicomSwiftUI.swift
//
//  SwiftUI Components for DICOM Medical Imaging
//
//  This module provides production‑ready SwiftUI components for
//  displaying and interacting with DICOM medical images.  Built on
//  top of DicomCore, it offers high‑level views that handle common
//  tasks like image display with automatic scaling, interactive
//  windowing controls, series navigation, and metadata presentation.
//  All components support dark mode, accessibility features, and
//  follow SwiftUI best practices.
//
//  Thread Safety:
//
//  All components are designed for SwiftUI's concurrency model.
//  ViewModels use @Published properties on @MainActor and are safe
//  to use with async/await.  Image rendering utilities handle
//  background processing automatically while ensuring UI updates
//  occur on the main thread.
//
//  Usage:
//
//    import SwiftUI
//    import DicomSwiftUI
//
//    struct ContentView: View {
//        let dicomURL: URL
//
//        var body: some View {
//            DicomImageView(url: dicomURL)
//                .frame(maxWidth: .infinity, maxHeight: .infinity)
//        }
//    }
//

import Foundation
import SwiftUI
import DicomCore

/// SwiftUI Components for DICOM Medical Imaging
///
/// ## Overview
///
/// ``DicomSwiftUI`` provides production‑ready SwiftUI components for displaying and
/// interacting with DICOM medical images. Built on top of `DicomCore`, it offers
/// high‑level views that handle common tasks while following SwiftUI best practices.
///
/// The module includes four main components:
///
/// - **DicomImageView**: Displays DICOM images with automatic scaling and windowing
/// - **WindowingControlView**: Interactive controls for window/level adjustment with medical presets
/// - **SeriesNavigatorView**: Navigate through DICOM series with thumbnails and keyboard shortcuts
/// - **MetadataView**: Display formatted DICOM metadata (patient info, study details, image properties)
///
/// All components support:
/// - Dark mode with automatic color adaptation
/// - VoiceOver and accessibility features
/// - iOS, visionOS, and macOS 26+ deployment targets
/// - Async/await for non‑blocking image loading
///
/// ## Usage
///
/// Display a DICOM image with automatic windowing:
///
/// ```swift
/// import SwiftUI
/// import DicomSwiftUI
///
/// struct ContentView: View {
///     let dicomURL: URL
///
///     var body: some View {
///         DicomImageView(url: dicomURL)
///             .frame(maxWidth: .infinity, maxHeight: .infinity)
///     }
/// }
/// ```
///
/// Combine multiple components for a complete viewer:
///
/// ```swift
/// struct DicomViewerView: View {
///     let seriesURLs: [URL]
///     @State private var currentIndex = 0
///
///     var body: some View {
///         VStack {
///             DicomImageView(url: seriesURLs[currentIndex])
///
///             SeriesNavigatorView(
///                 currentIndex: $currentIndex,
///                 totalCount: seriesURLs.count
///             )
///
///             WindowingControlView(decoder: /* ... */)
///         }
///     }
/// }
/// ```
///
/// ## Topics
///
/// ### Essentials
///
/// - <doc:GettingStarted>
/// - <doc:PreviewSupport>
///
/// ### Views
///
/// - ``DicomImageView``
/// - ``WindowingControlView``
/// - ``SeriesNavigatorView``
/// - ``MetadataView``
///
/// ### ViewModels
///
/// - ``DicomImageViewModel``
/// - ``WindowingViewModel``
/// - ``SeriesNavigatorViewModel``
///
/// ### Preview Support
///
/// - ``PreviewSize``
/// - ``PreviewConfiguration``
/// - ``PreviewHelpers``
/// - ``DicomSampleData``
/// - ``MockDicomDecoderForPreviews``
///
/// ### Utilities
///
/// - ``CGImageFactory``
/// - ``DicomImageRenderer``
///
/// ## See Also
///
/// The lower-level `DicomCore` module provides decoding and DICOM data structures.
public struct DicomSwiftUI {
    /// Library version number
    public static let version = "1.0.0"

    /// Initialize the DicomSwiftUI module
    public init() {}
}
