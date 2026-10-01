//
//  DicomImageRenderer.swift
//
//  High-level API for rendering DICOM images to CGImage
//
//  This utility coordinates DCMDecoder and DCMWindowingProcessor to provide
//  a simplified API for loading DICOM files and converting them to displayable
//  images. The renderer handles the complete pipeline: file loading → pixel
//  extraction → windowing transformation → CGImage creation.
//
//  The API supports both synchronous and asynchronous loading, automatic and
//  manual windowing, medical imaging presets, and GPU acceleration. Error
//  handling is integrated throughout the pipeline with detailed diagnostics.
//
//  Thread Safety:
//
//  All methods are thread-safe and can be called from any queue. Async methods
//  use structured concurrency and respect task cancellation. For batch rendering,
//  consider using TaskGroup to process multiple files concurrently.
//
//  Performance Characteristics:
//
//  Total rendering time includes: file loading (5-50ms) + windowing (1-10ms) +
//  CGImage creation (1-50ms). For 512×512 images, expect ~10-25ms total.
//  For 1024×1024 images with GPU acceleration, expect ~20-70ms total.
//
//  GPU acceleration via Metal provides significant speedups for large images
//  (≥800×800 pixels). Use ProcessingMode.auto for automatic backend selection.
//

import Foundation
import CoreGraphics
import DicomCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Minimal decoder surface required by ``DicomImageRenderer``.
///
/// This protocol enables dependency injection for unit tests so renderer behavior
/// can be validated without file-system fixtures or concrete `DCMDecoder` loading.
public protocol DicomImageRendererDecoderProtocol: Sendable {
    /// Image width in pixels.
    var width: Int { get }

    /// Image height in pixels.
    var height: Int { get }

    /// Default window settings from DICOM metadata.
    var windowSettingsV2: WindowSettings { get }

    /// Returns 16-bit grayscale pixels in row-major order.
    func getPixels16() -> [UInt16]?
}

extension DCMDecoder: DicomImageRendererDecoderProtocol {}

/// High-level renderer for converting DICOM files to displayable images.
///
/// ## Overview
///
/// ``DicomImageRenderer`` provides a simplified, high-level API for the complete DICOM image
/// rendering pipeline. It coordinates `DCMDecoder` (for file loading and pixel extraction)
/// and `DCMWindowingProcessor` (for window/level transformations) to produce `CGImage`
/// objects ready for display in SwiftUI or UIKit views.
///
/// The renderer eliminates boilerplate by handling:
/// - DICOM file loading with error handling
/// - Pixel data extraction and validation
/// - Window/level transformation with medical presets
/// - CPU (vDSP) and GPU (Metal) acceleration
/// - CGImage creation with appropriate color space
///
/// **Key Features:**
/// - One-call rendering from URL to CGImage
/// - Automatic optimal windowing calculation
/// - 13 medical imaging presets (lung, bone, brain, etc.)
/// - Async/await support for non-blocking operations
/// - GPU acceleration for large images
/// - Comprehensive error diagnostics
///
/// ## Usage
///
/// Render with automatic windowing:
///
/// ```swift
/// do {
///     let cgImage = try DicomImageRenderer.render(
///         contentsOf: url,
///         windowingMode: .automatic
///     )
///     let uiImage = UIImage(cgImage: cgImage)
///     imageView.image = uiImage
/// } catch {
///     print("Rendering failed: \(error)")
/// }
/// ```
///
/// Render with medical preset:
///
/// ```swift
/// let cgImage = try DicomImageRenderer.render(
///     contentsOf: url,
///     windowingMode: .preset(.lung),
///     processingMode: .auto  // Auto-select CPU or GPU
/// )
/// ```
///
/// Render asynchronously:
///
/// ```swift
/// Task {
///     do {
///         let cgImage = try await DicomImageRenderer.renderAsync(
///             contentsOf: url,
///             windowingMode: .custom(center: 50, width: 400)
///         )
///         // Update UI on main actor
///         await MainActor.run {
///             imageView.image = UIImage(cgImage: cgImage)
///         }
///     } catch {
///         print("Error: \(error)")
///     }
/// }
/// ```
///
/// Render from existing decoder:
///
/// ```swift
/// let decoder = try DCMDecoder(contentsOf: url)
/// let cgImage = try DicomImageRenderer.render(
///     decoder: decoder,
///     windowingMode: .fromDecoder  // Use decoder's window/level
/// )
/// ```
///
/// ## Topics
///
/// ### Rendering from URL
///
/// - ``render(contentsOf:windowingMode:processingMode:)``
/// - ``renderAsync(contentsOf:windowingMode:processingMode:)``
///
/// ### Rendering from Decoder
///
/// - ``render(decoder:windowingMode:processingMode:)``
/// - ``renderAsync(decoder:windowingMode:processingMode:)``
///
/// ### Windowing Modes
///
/// - ``WindowingMode``
///
/// ## Thread Safety
///
/// All methods are thread-safe and can be called from any queue. Async methods respect
/// task cancellation and use structured concurrency for safe concurrent operations.
///
public enum DicomImageRenderer {

    // MARK: - Windowing Mode Configuration

    /// Windowing mode for image rendering.
    ///
    /// Determines how window/level values are chosen for the grayscale transformation:
    ///
    /// - **automatic**: Calculates optimal window/level from pixel histogram
    /// - **preset**: Uses medical imaging preset (lung, bone, brain, etc.)
    /// - **custom**: Uses user-specified center and width values
    /// - **fromDecoder**: Uses window/level values from DICOM metadata
    ///
    public enum WindowingMode: Sendable {
        /// Calculate optimal window/level automatically from pixel histogram
        case automatic

        /// Use medical imaging preset (e.g., .lung, .bone, .brain)
        case preset(MedicalPreset)

        /// Use custom window center and width values
        case custom(center: Double, width: Double)

        /// Use window/level values from DICOM file metadata (Window Center/Width tags)
        case fromDecoder
    }

    // MARK: - Synchronous Rendering from URL

    /// Renders a DICOM file from URL to CGImage (synchronous).
    ///
    /// Loads the DICOM file, extracts pixel data, applies windowing transformation,
    /// and creates a CGImage suitable for display. This method blocks until rendering
    /// completes (~10-70ms depending on image size).
    ///
    /// **Processing Pipeline:**
    /// 1. Load DICOM file with `DCMDecoder`
    /// 2. Extract 16-bit pixel data
    /// 3. Determine window/level values based on `windowingMode`
    /// 4. Apply windowing transformation (8-bit conversion)
    /// 5. Create `CGImage` with grayscale color space
    ///
    /// For non-blocking rendering, use ``renderAsync(contentsOf:windowingMode:processingMode:)``
    /// instead.
    ///
    /// - Parameters:
    ///   - url: URL to the DICOM file (.dcm, .dicom)
    ///   - windowingMode: How to determine window/level values. Defaults to `.automatic`
    ///   - processingMode: CPU (vDSP) or GPU (Metal) acceleration. Defaults to `.auto`
    ///
    /// - Returns: A grayscale `CGImage` ready for display
    ///
    /// - Throws:
    ///   - `DICOMError/fileNotFound(path:)`: File doesn't exist at URL
    ///   - `DICOMError/invalidDICOMFormat(reason:)`: File is not valid DICOM
    ///   - `DICOMError/invalidPixelData(reason:)`: Missing or invalid pixel data
    ///   - `DICOMError/imageProcessingFailed(operation:reason:)`: CGImage creation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Automatic windowing (recommended for unknown images)
    /// let cgImage = try DicomImageRenderer.render(
    ///     contentsOf: url,
    ///     windowingMode: .automatic
    /// )
    ///
    /// // Lung preset for CT chest images
    /// let cgImage = try DicomImageRenderer.render(
    ///     contentsOf: url,
    ///     windowingMode: .preset(.lung),
    ///     processingMode: .metal  // Force GPU acceleration
    /// )
    /// ```
    public static func render(
        contentsOf url: URL,
        windowingMode: WindowingMode = .automatic,
        processingMode: ProcessingMode = .auto
    ) throws -> CGImage {
        // Load DICOM file
        let decoder = try DCMDecoder(contentsOf: url)

        // Render using the decoder
        return try render(
            decoder: decoder,
            windowingMode: windowingMode,
            processingMode: processingMode
        )
    }

    // MARK: - Synchronous Rendering from Decoder

    /// Renders a DICOM image from an existing decoder to CGImage (synchronous).
    ///
    /// Extracts pixel data from the decoder, applies windowing transformation,
    /// and creates a CGImage suitable for display. This method is useful when you
    /// already have a decoder instance (e.g., for metadata access) and want to
    /// render multiple times with different windowing settings.
    ///
    /// This method blocks until rendering completes (~5-50ms depending on image size
    /// and processing mode).
    ///
    /// - Parameters:
    ///   - decoder: An initialized decoder conforming to `DicomImageRendererDecoderProtocol`
    ///   - windowingMode: How to determine window/level values. Defaults to `.automatic`
    ///   - processingMode: CPU (vDSP) or GPU (Metal) acceleration. Defaults to `.auto`
    ///
    /// - Returns: A grayscale `CGImage` ready for display
    ///
    /// - Throws:
    ///   - `DICOMError/invalidPixelData(reason:)`: Missing or invalid pixel data
    ///   - `DICOMError/invalidWindowLevel(window:level:reason:)`: Invalid windowing values
    ///   - `DICOMError/imageProcessingFailed(operation:reason:)`: CGImage creation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// let decoder = try DCMDecoder(contentsOf: url)
    ///
    /// // Render with different windowing modes
    /// let autoImage = try DicomImageRenderer.render(
    ///     decoder: decoder,
    ///     windowingMode: .automatic
    /// )
    ///
    /// let lungImage = try DicomImageRenderer.render(
    ///     decoder: decoder,
    ///     windowingMode: .preset(.lung)
    /// )
    /// ```
    public static func render(
        decoder: any DicomImageRendererDecoderProtocol,
        windowingMode: WindowingMode = .automatic,
        processingMode: ProcessingMode = .auto
    ) throws -> CGImage {
        // Extract pixel data
        guard let pixels16 = decoder.getPixels16() else {
            throw DICOMError.invalidPixelData(reason: "Missing or invalid 16-bit pixel data")
        }

        // Validate dimensions
        guard decoder.width > 0, decoder.height > 0 else {
            throw DICOMError.invalidPixelData(reason: "Invalid image dimensions: \(decoder.width)×\(decoder.height)")
        }

        // Determine window/level values
        let windowSettings = try resolveWindowSettings(
            mode: windowingMode,
            decoder: decoder,
            pixels16: pixels16
        )

        // Validate window settings
        guard windowSettings.isValid else {
            throw DICOMError.invalidWindowLevel(
                window: windowSettings.width,
                level: windowSettings.center,
                reason: "Window width must be positive"
            )
        }

        // Apply windowing transformation
        guard let pixels8Data = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: windowSettings.center,
            width: windowSettings.width,
            processingMode: processingMode
        ) else {
            throw DICOMError.imageProcessingFailed(
                operation: "windowing",
                reason: "Failed to apply window/level transformation"
            )
        }

        // Convert Data to [UInt8] for CGImageFactory
        let pixels8 = Array(pixels8Data)

        // Create CGImage
        guard let cgImage = CGImageFactory.createImage(
            from: pixels8,
            width: decoder.width,
            height: decoder.height
        ) else {
            throw DICOMError.imageProcessingFailed(
                operation: "CGImage creation",
                reason: "Failed to create CGImage from windowed pixels"
            )
        }

        return cgImage
    }

    // MARK: - Asynchronous Rendering from URL

    /// Renders a DICOM file from URL to CGImage asynchronously.
    ///
    /// Loads the DICOM file on a background queue, applies windowing, and creates
    /// a CGImage without blocking the caller. Use this method for responsive UIs
    /// that need to remain interactive during file loading.
    ///
    /// The method respects task cancellation - if the parent task is cancelled,
    /// the operation will terminate early.
    ///
    /// - Parameters:
    ///   - url: URL to the DICOM file (.dcm, .dicom)
    ///   - windowingMode: How to determine window/level values. Defaults to `.automatic`
    ///   - processingMode: CPU (vDSP) or GPU (Metal) acceleration. Defaults to `.auto`
    ///
    /// - Returns: A grayscale `CGImage` ready for display
    ///
    /// - Throws: Same errors as ``render(contentsOf:windowingMode:processingMode:)``
    ///
    /// ## Example
    ///
    /// ```swift
    /// Task {
    ///     do {
    ///         let cgImage = try await DicomImageRenderer.renderAsync(
    ///             contentsOf: url,
    ///             windowingMode: .preset(.bone)
    ///         )
    ///
    ///         // Update UI on main actor
    ///         await MainActor.run {
    ///             imageView.image = UIImage(cgImage: cgImage)
    ///         }
    ///     } catch {
    ///         print("Rendering failed: \(error)")
    ///     }
    /// }
    /// ```
    public static func renderAsync(
        contentsOf url: URL,
        windowingMode: WindowingMode = .automatic,
        processingMode: ProcessingMode = .auto
    ) async throws -> CGImage {
        // Load DICOM file asynchronously
        let decoder = try await DCMDecoder(contentsOf: url)

        // Render using the decoder (on background queue)
        return try await renderAsync(
            decoder: decoder,
            windowingMode: windowingMode,
            processingMode: processingMode
        )
    }

    // MARK: - Asynchronous Rendering from Decoder

    /// Renders a DICOM image from an existing decoder to CGImage asynchronously.
    ///
    /// Extracts pixel data, applies windowing, and creates a CGImage on a background
    /// queue without blocking the caller. Useful for rendering multiple images
    /// concurrently or keeping the UI responsive during batch processing.
    ///
    /// The method respects task cancellation - if the parent task is cancelled,
    /// the operation will terminate early.
    ///
    /// - Parameters:
    ///   - decoder: An initialized decoder conforming to `DicomImageRendererDecoderProtocol`
    ///   - windowingMode: How to determine window/level values. Defaults to `.automatic`
    ///   - processingMode: CPU (vDSP) or GPU (Metal) acceleration. Defaults to `.auto`
    ///
    /// - Returns: A grayscale `CGImage` ready for display
    ///
    /// - Throws: Same errors as ``render(decoder:windowingMode:processingMode:)``
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Render multiple windowing modes concurrently
    /// async let autoImage = DicomImageRenderer.renderAsync(
    ///     decoder: decoder,
    ///     windowingMode: .automatic
    /// )
    /// async let lungImage = DicomImageRenderer.renderAsync(
    ///     decoder: decoder,
    ///     windowingMode: .preset(.lung)
    /// )
    /// async let boneImage = DicomImageRenderer.renderAsync(
    ///     decoder: decoder,
    ///     windowingMode: .preset(.bone)
    /// )
    ///
    /// let images = try await [autoImage, lungImage, boneImage]
    /// ```
    public static func renderAsync(
        decoder: any DicomImageRendererDecoderProtocol,
        windowingMode: WindowingMode = .automatic,
        processingMode: ProcessingMode = .auto
    ) async throws -> CGImage {
        // Capture decoder explicitly before spawning child work.
        let localDecoder = decoder
        try Task.checkCancellation()

        // Use structured concurrency so caller cancellation propagates.
        return try await withThrowingTaskGroup(of: CGImage.self) { group in
            group.addTask(priority: .userInitiated) {
                try Task.checkCancellation()
                return try render(
                    decoder: localDecoder,
                    windowingMode: windowingMode,
                    processingMode: processingMode
                )
            }

            guard let image = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return image
        }
    }

    // MARK: - Private Helpers

    /// Resolves window/level values based on the specified mode.
    ///
    /// - Parameters:
    ///   - mode: The windowing mode to use
    ///   - decoder: DICOM decoder (used for .fromDecoder mode)
    ///   - pixels16: 16-bit pixel data (used for .automatic mode)
    ///
    /// - Returns: Window settings with center and width values
    ///
    /// - Throws: `DICOMError/invalidWindowLevel(window:level:reason:)` if settings are invalid
    /// Resolve window center and width according to the selected windowing mode.
    /// - Parameters:
    ///   - mode: The windowing mode to apply (automatic, preset, custom, or fromDecoder).
    ///   - decoder: The DCMDecoder whose stored window/level metadata is consulted when `mode` is `.fromDecoder`.
    ///   - pixels16: 16-bit grayscale pixel samples used when calculating an automatic window/level from the pixel histogram.
    /// Resolve window center and width according to the specified windowing mode.
    /// - Parameters:
    ///   - mode: The windowing mode to use (automatic, preset, custom, or fromDecoder).
    ///   - decoder: Decoder providing DICOM metadata when `mode` is `.fromDecoder`.
    ///   - pixels16: 16-bit pixel samples used for automatic histogram-based calculation.
    /// - Returns: A `WindowSettings` containing the resolved `center` and `width`.
    /// - Throws: Errors propagated from the underlying window-level calculation or preset lookup.
    private static func resolveWindowSettings(
        mode: WindowingMode,
        decoder: any DicomImageRendererDecoderProtocol,
        pixels16: [UInt16]
    ) throws -> WindowSettings {
        switch mode {
        case .automatic:
            // Calculate optimal window/level from histogram
            return DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels16)

        case .preset(let medicalPreset):
            // Use medical imaging preset
            return DCMWindowingProcessor.getPresetValuesV2(preset: medicalPreset)

        case .custom(let center, let width):
            // Use user-specified values
            return WindowSettings(center: center, width: width)

        case .fromDecoder:
            // Use values from DICOM metadata
            let settings = decoder.windowSettingsV2
            guard settings.isValid else {
                // Fallback to automatic if metadata values are invalid
                return DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels16)
            }
            return settings
        }
    }
}

// MARK: - Convenience Extensions

#if canImport(SwiftUI)
import SwiftUI

extension Image {
    /// Creates a SwiftUI Image by rendering a DICOM file.
    ///
    /// Convenience initializer that combines DICOM loading, windowing, and image
    /// creation into a single call. This is particularly useful for simple display
    /// use cases in SwiftUI views.
    ///
    /// **Deprecated:** This initializer blocks until rendering completes and
    /// internally triggers blocking `DCMDecoder(contentsOf:)` work.
    ///
    /// Use ``Image/makeDicomImage(contentsOf:windowingMode:processingMode:)``
    /// in async contexts to keep UI responsive.
    ///
    /// ## Migration
    ///
    /// Use `Task {}` or structured concurrency to load the image asynchronously:
    ///
    /// ```swift
    /// Task {
    ///     if let image = try? await Image.makeDicomImage(contentsOf: url) {
    ///         await MainActor.run { self.image = image }
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - url: URL to the DICOM file
    ///   - windowingMode: How to determine window/level values. Defaults to `.automatic`
    ///   - processingMode: CPU (vDSP) or GPU (Metal) acceleration. Defaults to `.auto`
    ///
    /// - Returns: A SwiftUI Image, or nil if rendering fails
    ///
    /// ## Example
    ///
    /// ```swift
    /// struct DicomImageView: View {
    ///     let url: URL
    ///
    ///     var body: some View {
    ///         if let image = Image(dicomURL: url, windowingMode: .preset(.lung)) {
    ///             image
    ///                 .resizable()
    ///                 .aspectRatio(contentMode: .fit)
    ///         } else {
    ///             Text("Failed to load DICOM")
    ///         }
    ///     }
    /// }
    /// ```
    ///
    @available(
        *,
        deprecated,
        message: "This initializer performs blocking DCMDecoder(contentsOf:) work. Use await Image.makeDicomImage(contentsOf:windowingMode:processingMode:) instead."
    )
    public init?(
        dicomURL url: URL,
        windowingMode: DicomImageRenderer.WindowingMode = .automatic,
        processingMode: ProcessingMode = .auto
    ) {
        guard let cgImage = try? DicomImageRenderer.render(
            contentsOf: url,
            windowingMode: windowingMode,
            processingMode: processingMode
        ) else {
            return nil
        }

        self.init(decorative: cgImage, scale: 1.0)
    }

    /// Asynchronously creates a SwiftUI Image by rendering a DICOM file.
    ///
    /// Uses ``DicomImageRenderer/renderAsync(contentsOf:windowingMode:processingMode:)``
    /// to avoid blocking the caller while decoding and rendering.
    ///
    /// - Parameters:
    ///   - url: URL to the DICOM file.
    ///   - windowingMode: How to determine window/level values. Defaults to `.automatic`.
    ///   - processingMode: CPU (vDSP) or GPU (Metal) acceleration. Defaults to `.auto`.
    /// - Returns: A rendered SwiftUI `Image`.
    /// - Throws: Any decoding or rendering error thrown by `DicomImageRenderer`.
    public static func makeDicomImage(
        contentsOf url: URL,
        windowingMode: DicomImageRenderer.WindowingMode = .automatic,
        processingMode: ProcessingMode = .auto
    ) async throws -> Image {
        let cgImage = try await DicomImageRenderer.renderAsync(
            contentsOf: url,
            windowingMode: windowingMode,
            processingMode: processingMode
        )
        return Image(decorative: cgImage, scale: 1.0)
    }
}
#endif
