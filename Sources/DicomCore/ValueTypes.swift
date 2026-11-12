//
//  ValueTypes.swift
//  DicomCore
//
//  Dedicated value types for DICOM windowing and spacing parameters Provides type-safe alternatives
//  to tuple-based APIs with Codable support.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

// MARK: - Window Settings

/// Window/level settings for DICOM image display.
///
/// ## Overview
///
/// ``WindowSettings`` represents the window center and width values used for grayscale
/// display adjustment in medical imaging. Window settings control the mapping of pixel
/// values to display brightness, a critical operation in medical image viewing that allows
/// radiologists to emphasize different tissue densities.
///
/// This type provides a type-safe alternative to tuple-based window settings APIs, offering
/// better discoverability, Codable conformance, and validation through the ``isValid`` property.
///
/// **Key Benefits:**
/// - Type-safe value type replacing tuple-based APIs
/// - Codable for JSON persistence
/// - Sendable for Swift concurrency
/// - Validation via ``isValid`` property
///
/// ## Usage
///
/// Create and use window settings:
///
/// ```swift
/// // Create window settings
/// let settings = WindowSettings(center: 50.0, width: 400.0)
/// if settings.isValid {
///     let pixels = DCMWindowingProcessor.applyWindowLevel(
///         pixels16: rawPixels,
///         center: settings.center,
///         width: settings.width
///     )
/// }
///
/// // Get preset values
/// let lungSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)
/// print("Lung window: center=\(lungSettings.center), width=\(lungSettings.width)")
/// ```
///
/// ## Topics
///
/// ### Creating Window Settings
///
/// - ``init(center:width:)``
///
/// ### Properties
///
/// - ``center``
/// - ``width``
/// - ``isValid``
///
public struct WindowSettings: Codable, Equatable, Hashable, Sendable {

    // MARK: - Properties

    /// Window center (level) - the midpoint of the displayed grayscale range
    public let center: Double

    /// Window width - the range of pixel values to display
    public let width: Double

    // MARK: - Computed Properties

    /// Returns true if the window settings are valid for display
    ///
    /// Valid window settings must have a positive width. A width of zero or negative
    /// would result in invalid display mapping.
    public var isValid: Bool {
        return width > 0
    }

    // MARK: - Initialization

    /// Creates window settings with the specified center and width
    ///
    /// - Parameters:
    ///   - center: The window center (level) value
    ///   - width: The window width value
    public init(center: Double, width: Double) {
        self.center = center
        self.width = width
    }
}

// MARK: - Pixel Spacing

/// Physical spacing between pixels in a DICOM image.
///
/// ## Overview
///
/// ``PixelSpacing`` represents the physical distance (in mm) between pixel centers in three
/// dimensions. This is critical for accurate measurement and 3D reconstruction of medical images,
/// enabling precise calculations of anatomical dimensions, volumes, and distances.
///
/// The spacing values correspond to DICOM tags:
/// - X: Pixel Spacing [0] - column spacing (Tag 0028,0030)
/// - Y: Pixel Spacing [1] - row spacing (Tag 0028,0030)
/// - Z: Slice Thickness or Spacing Between Slices (Tags 0018,0050 / 0018,0088)
///
/// **Key Benefits:**
/// - Type-safe value type replacing tuple-based APIs
/// - Physical units (millimeters) for real-world measurements
/// - Codable for JSON persistence
/// - Sendable for Swift concurrency
/// - Validation via ``isValid`` property
///
/// ## Usage
///
/// Access pixel spacing from decoder:
///
/// ```swift
/// let decoder = try DCMDecoder(contentsOf: url)
/// let spacing = decoder.pixelSpacingV2
/// if spacing.isValid {
///     print("Spacing: \(spacing.x) × \(spacing.y) × \(spacing.z) mm")
///     let pixelArea = spacing.x * spacing.y  // mm²
///     let voxelVolume = spacing.x * spacing.y * spacing.z  // mm³
/// }
/// ```
///
/// Use for volume calculations:
///
/// ```swift
/// let volume = DicomSeriesVolume(...)
/// let voxelVolume = volume.spacing.x * volume.spacing.y * volume.spacing.z
/// print("Voxel volume: \(voxelVolume) mm³")
/// ```
///
/// ## Topics
///
/// ### Creating Pixel Spacing
///
/// - ``init(x:y:z:)``
///
/// ### Properties
///
/// - ``x``
/// - ``y``
/// - ``z``
/// - ``isValid``
///
public struct PixelSpacing: Codable, Equatable, Hashable, Sendable {

    // MARK: - Properties

    /// Horizontal pixel spacing (column spacing) in millimeters
    public let x: Double

    /// Vertical pixel spacing (row spacing) in millimeters
    public let y: Double

    /// Slice spacing (spacing between slices) in millimeters
    public let z: Double

    // MARK: - Computed Properties

    /// Returns true if all spacing values are positive
    ///
    /// Valid pixel spacing must have positive values in all dimensions.
    /// Zero or negative spacing would be physically meaningless.
    public var isValid: Bool {
        return x > 0 && y > 0 && z > 0
    }

    // MARK: - Initialization

    /// Creates pixel spacing with the specified dimensions
    ///
    /// - Parameters:
    ///   - x: Horizontal pixel spacing in millimeters
    ///   - y: Vertical pixel spacing in millimeters
    ///   - z: Slice spacing in millimeters
    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

// MARK: - Rescale Parameters

/// Rescale parameters for converting stored pixel values to modality units.
///
/// ## Overview
///
/// ``RescaleParameters`` represents the rescale slope and intercept used to convert raw
/// pixel values to meaningful physical units (e.g., Hounsfield Units in CT imaging).
/// The conversion formula is: **output = slope × stored_value + intercept**
///
/// These parameters correspond to DICOM tags:
/// - Slope: Rescale Slope (Tag 0028,1053)
/// - Intercept: Rescale Intercept (Tag 0028,1052)
///
/// **Common Use Cases:**
/// - CT images: Convert to Hounsfield Units (HU)
/// - PET images: Convert to Standardized Uptake Values (SUV)
/// - MR images: Often identity transform (slope=1, intercept=0)
///
/// **Key Benefits:**
/// - Type-safe value type replacing tuple-based APIs
/// - Built-in ``apply(to:)`` method for transformations
/// - Codable for JSON persistence
/// - Sendable for Swift concurrency
/// - Identity check via ``isIdentity`` property
///
/// ## Usage
///
/// Access rescale parameters from decoder:
///
/// ```swift
/// let decoder = try DCMDecoder(contentsOf: url)
/// let rescale = decoder.rescaleParametersV2
/// if !rescale.isIdentity {
///     let hounsfieldValue = rescale.apply(to: pixelValue)
///     print("Pixel value \(pixelValue) = \(hounsfieldValue) HU")
/// }
/// ```
///
/// Convert pixel arrays:
///
/// ```swift
/// let pixels: [Int16] = decoder.getPixels16() ?? []
/// let rescale = decoder.rescaleParametersV2
/// let hounsfieldUnits = pixels.map { rescale.apply(to: Double($0)) }
/// ```
///
/// ## Topics
///
/// ### Creating Rescale Parameters
///
/// - ``init(intercept:slope:)``
///
/// ### Properties
///
/// - ``intercept``
/// - ``slope``
/// - ``isIdentity``
///
/// ### Methods
///
/// - ``apply(to:)``
///
public struct RescaleParameters: Codable, Equatable, Hashable, Sendable {

    // MARK: - Properties

    /// Rescale intercept - the value added after multiplication by slope
    public let intercept: Double

    /// Rescale slope - the multiplier applied to stored pixel values
    public let slope: Double

    // MARK: - Computed Properties

    /// Returns true if the rescale parameters represent an identity transformation
    ///
    /// Identity transformation occurs when slope is 1.0 and intercept is 0.0,
    /// meaning the output equals the input without modification.
    public var isIdentity: Bool {
        return slope == 1.0 && intercept == 0.0
    }

    // MARK: - Initialization

    /// Creates rescale parameters with the specified slope and intercept
    ///
    /// - Parameters:
    ///   - intercept: The rescale intercept value
    ///   - slope: The rescale slope value
    public init(intercept: Double, slope: Double) {
        self.intercept = intercept
        self.slope = slope
    }

    // MARK: - Methods

    /// Applies the rescale transformation to a stored pixel value
    ///
    /// - Parameter storedValue: The raw pixel value from the DICOM file
    /// - Returns: The rescaled value in modality units
    ///
    /// ## Example
    /// ```swift
    /// let rescale = RescaleParameters(intercept: -1024.0, slope: 1.0)
    /// let hounsfield = rescale.apply(to: 0.0)  // Returns -1024.0
    /// ```
    public func apply(to storedValue: Double) -> Double {
        return slope * storedValue + intercept
    }
}
