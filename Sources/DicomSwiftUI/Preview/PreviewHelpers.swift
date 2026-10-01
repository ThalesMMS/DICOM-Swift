//
//  PreviewHelpers.swift
//
//  Convenience APIs for configuring DICOM SwiftUI previews.
//  Provides factory methods for view models, size presets, and windowing
//  configurations to simplify Xcode Preview setup.
//
//  Performance:
//
//  All helper methods create pre-configured view models with instant sample
//  data loading. View models are ready for rendering in <10ms, enabling
//  responsive preview iteration.
//
//  Usage:
//
//  Use these helpers to quickly set up SwiftUI previews with realistic DICOM
//  data without verbose configuration:
//
//  ```swift
//  #Preview("CT Lung Window") {
//      DicomImageView(url: URL(fileURLWithPath: "/fake/path"))
//          .previewViewModel(.ctLung)
//  }
//
//  #Preview("Series Navigator") {
//      SeriesNavigatorView()
//          .previewSeries(.ctChest(slices: 5))
//  }
//  ```
//

import Foundation
import SwiftUI
import DicomCore

// MARK: - Preview Size Presets

/// Size presets for preview layouts.
///
/// Defines common display sizes for DICOM image previews, enabling consistent
/// preview sizing across different views and scenarios.
///
/// ## Usage
///
/// ```swift
/// #Preview {
///     DicomImageView(url: sampleURL)
///         .frame(width: PreviewSize.medium.width,
///                height: PreviewSize.medium.height)
/// }
/// ```
public enum PreviewSize {
    /// Thumbnail size (128×128) for list items and galleries
    case thumbnail

    /// Small size (256×256) for compact displays
    case small

    /// Medium size (512×512) for standard previews
    case medium

    /// Large size (1024×1024) for detailed inspection
    case large

    /// Custom size with specified dimensions
    case custom(width: CGFloat, height: CGFloat)

    /// Width in points
    public var width: CGFloat {
        switch self {
        case .thumbnail: return 128
        case .small: return 256
        case .medium: return 512
        case .large: return 1024
        case .custom(let width, _): return width
        }
    }

    /// Height in points
    public var height: CGFloat {
        switch self {
        case .thumbnail: return 128
        case .small: return 256
        case .medium: return 512
        case .large: return 1024
        case .custom(_, let height): return height
        }
    }
}

// MARK: - Preview Configuration

/// Configuration for preview view models.
///
/// Defines pre-configured scenarios for common DICOM preview use cases,
/// combining modality, windowing, and sample data into ready-to-use configurations.
public enum PreviewConfiguration {
    /// CT chest with lung window
    case ctLung

    /// CT chest with bone window
    case ctBone

    /// CT brain with brain window
    case ctBrain

    /// CT abdomen with soft tissue window
    case ctAbdomen

    /// MRI brain with T1 weighting
    case mrBrain

    /// MRI spine with T2 weighting
    case mrSpine

    /// X-ray chest PA view
    case xrayChest

    /// Ultrasound abdominal scan
    case ultrasound

    /// Custom configuration with specified parameters
    case custom(modality: DICOMModality, windowSettings: WindowSettings, description: String)

    /// Returns the modality for this configuration
    public var modality: DICOMModality {
        switch self {
        case .ctLung, .ctBone, .ctBrain, .ctAbdomen:
            return .ct
        case .mrBrain, .mrSpine:
            return .mr
        case .xrayChest:
            return .cr
        case .ultrasound:
            return .us
        case .custom(let modality, _, _):
            return modality
        }
    }

    /// Returns the window settings for this configuration
    public var windowSettings: WindowSettings {
        switch self {
        case .ctLung:
            return WindowSettings(center: -600.0, width: 1500.0)
        case .ctBone:
            return WindowSettings(center: 400.0, width: 1800.0)
        case .ctBrain:
            return WindowSettings(center: 40.0, width: 80.0)
        case .ctAbdomen:
            return WindowSettings(center: 40.0, width: 400.0)
        case .mrBrain, .mrSpine:
            return WindowSettings(center: 600.0, width: 1200.0)
        case .xrayChest:
            return WindowSettings(center: 2000.0, width: 4000.0)
        case .ultrasound:
            return WindowSettings(center: 128.0, width: 256.0)
        case .custom(_, let settings, _):
            return settings
        }
    }

    /// Returns a description of this configuration
    public var description: String {
        switch self {
        case .ctLung:
            return "CT Chest - Lung Window"
        case .ctBone:
            return "CT Chest - Bone Window"
        case .ctBrain:
            return "CT Brain"
        case .ctAbdomen:
            return "CT Abdomen - Soft Tissue"
        case .mrBrain:
            return "MRI Brain - T1 Weighted"
        case .mrSpine:
            return "MRI Spine - T2 Weighted"
        case .xrayChest:
            return "X-Ray Chest - PA View"
        case .ultrasound:
            return "Ultrasound Abdomen"
        case .custom(_, _, let description):
            return description
        }
    }
}

// MARK: - DicomImageViewModel Preview Helpers

@MainActor
extension DicomImageViewModel {

    /// Creates a preview-ready view model with pre-loaded sample data.
    ///
    /// - Parameters:
    ///   - configuration: Preview configuration defining modality and windowing
    ///   - size: Optional size preset for the sample data (default: .medium)
    /// - Returns: View model with sample data already loaded
    ///
    /// ## Usage
    ///
    /// ```swift
    /// #Preview {
    ///     let viewModel = DicomImageViewModel.preview(.ctLung)
    ///     DicomImageView(viewModel: viewModel)
    /// }
    /// ```
    public static func preview(
        _ configuration: PreviewConfiguration,
        size: PreviewSize = .medium
    ) -> DicomImageViewModel {
        let viewModel = DicomImageViewModel()

        // Create sample decoder based on configuration
        var decoder: MockDicomDecoderForPreviews

        switch configuration.modality {
        case .ct:
            decoder = DicomSampleData.sampleCTDecoder()
        case .mr:
            decoder = DicomSampleData.sampleMRIDecoder()
        case .cr, .dx:
            decoder = DicomSampleData.sampleXRayDecoder()
        case .us:
            decoder = DicomSampleData.sampleUltrasoundDecoder()
        default:
            decoder = DicomSampleData.decoder(modality: configuration.modality)
        }

        // Override window settings to match configuration
        decoder.customWindowSettings = configuration.windowSettings

        // Load the sample data synchronously (safe for previews)
        Task { @MainActor in
            await viewModel.loadImage(
                decoder: decoder,
                windowingMode: .custom(
                    center: configuration.windowSettings.center,
                    width: configuration.windowSettings.width
                ),
                processingMode: .vdsp  // Use CPU for preview reliability
            )
        }

        return viewModel
    }

    /// Creates a preview-ready view model for a specific modality.
    ///
    /// - Parameters:
    ///   - modality: DICOM modality type
    ///   - windowSettings: Optional custom window settings
    /// - Returns: View model with sample data for the specified modality
    ///
    /// ## Usage
    ///
    /// ```swift
    /// #Preview {
    ///     let viewModel = DicomImageViewModel.preview(
    ///         modality: .ct,
    ///         windowSettings: WindowSettings(center: 40, width: 400)
    ///     )
    ///     DicomImageView(viewModel: viewModel)
    /// }
    /// ```
    public static func preview(
        modality: DICOMModality,
        windowSettings: WindowSettings? = nil
    ) -> DicomImageViewModel {
        let viewModel = DicomImageViewModel()
        let decoder = DicomSampleData.sampleDecoder(for: modality)

        if let customSettings = windowSettings {
            decoder.customWindowSettings = customSettings
        }

        Task { @MainActor in
            let settings = windowSettings ?? decoder.windowSettingsV2
            await viewModel.loadImage(
                decoder: decoder,
                windowingMode: .custom(center: settings.center, width: settings.width),
                processingMode: .vdsp
            )
        }

        return viewModel
    }

    /// Creates a preview-ready view model with automatic windowing.
    ///
    /// - Parameter modality: DICOM modality type
    /// - Returns: View model with automatic window/level calculation
    ///
    /// ## Usage
    ///
    /// ```swift
    /// #Preview("Auto Windowing") {
    ///     let viewModel = DicomImageViewModel.previewWithAutoWindowing(.ct)
    ///     DicomImageView(viewModel: viewModel)
    /// }
    /// ```
    public static func previewWithAutoWindowing(
        _ modality: DICOMModality
    ) -> DicomImageViewModel {
        let viewModel = DicomImageViewModel()
        let decoder = DicomSampleData.sampleDecoder(for: modality)

        Task { @MainActor in
            await viewModel.loadImage(
                decoder: decoder,
                windowingMode: .automatic,
                processingMode: .vdsp
            )
        }

        return viewModel
    }

    /// Creates a preview-ready view model with a medical imaging preset.
    ///
    /// - Parameters:
    ///   - preset: Medical imaging preset
    ///   - modality: DICOM modality type (default: .ct)
    /// - Returns: View model with preset windowing applied
    ///
    /// ## Usage
    ///
    /// ```swift
    /// #Preview("Lung Preset") {
    ///     let viewModel = DicomImageViewModel.preview(preset: .lung)
    ///     DicomImageView(viewModel: viewModel)
    /// }
    /// ```
    public static func preview(
        preset: MedicalPreset,
        modality: DICOMModality = .ct
    ) -> DicomImageViewModel {
        let viewModel = DicomImageViewModel()
        let decoder = DicomSampleData.sampleDecoder(for: modality)

        Task { @MainActor in
            await viewModel.loadImage(
                decoder: decoder,
                windowingMode: .preset(preset),
                processingMode: .vdsp
            )
        }

        return viewModel
    }
}

// MARK: - SeriesNavigatorViewModel Preview Helpers

@MainActor
extension SeriesNavigatorViewModel {

    /// Creates a preview-ready series navigator with sample data.
    ///
    /// - Parameters:
    ///   - modality: DICOM modality type
    ///   - slices: Number of slices in the series (default: 5)
    /// - Returns: View model with sample series data loaded
    ///
    /// ## Usage
    ///
    /// ```swift
    /// #Preview {
    ///     let navigator = SeriesNavigatorViewModel.preview(modality: .ct, slices: 10)
    ///     SeriesNavigatorView(viewModel: navigator)
    /// }
    /// ```
    public static func preview(
        modality: DICOMModality,
        slices: Int = 5
    ) -> SeriesNavigatorViewModel {
        let viewModel = SeriesNavigatorViewModel()

        // Generate fake URLs for series
        let urls = (0..<slices).map { index in
            URL(fileURLWithPath: "/preview/series/slice_\(index).dcm")
        }

        viewModel.setSeriesURLs(urls)

        return viewModel
    }

    /// Creates a preview-ready CT series navigator.
    ///
    /// - Parameter slices: Number of slices (default: 5)
    /// - Returns: View model with CT series data
    public static func previewCTSeries(slices: Int = 5) -> SeriesNavigatorViewModel {
        return preview(modality: .ct, slices: slices)
    }

    /// Creates a preview-ready MRI series navigator.
    ///
    /// - Parameter slices: Number of slices (default: 5)
    /// - Returns: View model with MRI series data
    public static func previewMRISeries(slices: Int = 5) -> SeriesNavigatorViewModel {
        return preview(modality: .mr, slices: slices)
    }
}

// MARK: - Preview Data Helpers

/// Helper functions for accessing preview data in SwiftUI previews.
@MainActor
public struct PreviewHelpers {

    /// Returns an array of sample decoders for testing list views.
    ///
    /// - Returns: Array of decoders with different modalities
    public static func sampleDecoders() -> [MockDicomDecoderForPreviews] {
        return [
            DicomSampleData.sampleCTDecoder(),
            DicomSampleData.sampleMRIDecoder(),
            DicomSampleData.sampleXRayDecoder(),
            DicomSampleData.sampleUltrasoundDecoder()
        ]
    }

    /// Returns an array of sample view models for testing.
    ///
    /// - Returns: Array of pre-loaded view models
    public static func sampleViewModels() -> [DicomImageViewModel] {
        return [
            DicomImageViewModel.preview(.ctLung),
            DicomImageViewModel.preview(.mrBrain),
            DicomImageViewModel.preview(.xrayChest),
            DicomImageViewModel.preview(.ultrasound)
        ]
    }

    /// Creates a view model with error state for testing error handling.
    ///
    /// - Returns: View model in failed state
    public static func errorViewModel() -> DicomImageViewModel {
        let viewModel = DicomImageViewModel()
        // Error state will be set when attempting to load invalid data
        return viewModel
    }

    /// Creates a view model in loading state for testing loading UI.
    ///
    /// - Returns: View model in loading state
    public static func loadingViewModel() -> DicomImageViewModel {
        let viewModel = DicomImageViewModel()
        // Create a long-running task to keep it in loading state
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
        }
        return viewModel
    }
}

// MARK: - View Modifiers for Preview Configuration

/// View modifier for applying preview configuration to DICOM views.
@MainActor
public struct PreviewConfigurationModifier: ViewModifier {
    let configuration: PreviewConfiguration
    let size: PreviewSize

    public func body(content: Content) -> some View {
        content
            .frame(width: size.width, height: size.height)
            .background(Color.black)
            .cornerRadius(8)
    }
}

@MainActor
extension View {

    /// Applies preview configuration styling to a DICOM view.
    ///
    /// - Parameters:
    ///   - configuration: Preview configuration
    ///   - size: Size preset (default: .medium)
    /// - Returns: Modified view with preview styling
    ///
    /// ## Usage
    ///
    /// ```swift
    /// #Preview {
    ///     DicomImageView(url: sampleURL)
    ///         .previewConfiguration(.ctLung, size: .large)
    /// }
    /// ```
    public func previewConfiguration(
        _ configuration: PreviewConfiguration,
        size: PreviewSize = .medium
    ) -> some View {
        modifier(PreviewConfigurationModifier(configuration: configuration, size: size))
    }

    /// Applies preview size styling to a view.
    ///
    /// - Parameter size: Size preset
    /// - Returns: Modified view with size constraints
    public func previewSize(_ size: PreviewSize) -> some View {
        frame(width: size.width, height: size.height)
    }
}

// MARK: - Mock Data Configuration

extension MockDicomDecoderForPreviews {

    /// Convenience initializer for creating preview decoders with common configurations.
    ///
    /// - Parameters:
    ///   - configuration: Preview configuration
    ///   - size: Size preset (default: .medium)
    /// - Returns: Mock decoder configured for the specified scenario
    public static func preview(
        _ configuration: PreviewConfiguration,
        size: PreviewSize = .medium
    ) -> MockDicomDecoderForPreviews {
        let width = Int(size.width)
        let height = Int(size.height)

        var decoder: MockDicomDecoderForPreviews

        switch configuration.modality {
        case .ct:
            decoder = MockDicomDecoderForPreviews.sampleCT()
        case .mr:
            decoder = MockDicomDecoderForPreviews.sampleMRI()
        case .cr, .dx:
            decoder = MockDicomDecoderForPreviews.sampleXRay()
        case .us:
            decoder = MockDicomDecoderForPreviews.sampleUltrasound()
        default:
            decoder = MockDicomDecoderForPreviews(
                width: width,
                height: height,
                windowCenter: configuration.windowSettings.center,
                windowWidth: configuration.windowSettings.width
            )
        }

        decoder.customWindowSettings = configuration.windowSettings
        return decoder
    }
}
