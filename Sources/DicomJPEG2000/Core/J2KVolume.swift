//
// J2KVolume.swift
// J2KSwift
//
/// # J2KVolume
///
/// Volumetric data types for ISO/IEC 15444-10 (JP3D) support.
///
/// This file provides foundational types for representing three-dimensional
/// image data used in volumetric JPEG 2000 encoding and decoding.
///
/// ## Topics
///
/// ### Volume Types
/// - ``J2KVolume``
/// - ``J2KVolumeComponent``

import Foundation

/// Represents a three-dimensional volumetric image for JP3D encoding/decoding.
///
/// A `J2KVolume` describes a 3D dataset with width, height, and depth dimensions,
/// along with component information and optional voxel spacing metadata. It supports
/// bit depths from 1 to 38 bits per sample, both signed and unsigned data, and
/// per-component subsampling.
///
/// Example:
/// ```swift
/// let volume = J2KVolume(width: 256, height: 256, depth: 128, componentCount: 1, bitDepth: 16)
/// print("Voxel count: \(volume.voxelCount)")
/// ```
public struct J2KVolume: Sendable, Equatable {
    /// The width of the volume in voxels (X-axis).
    public let width: Int

    /// The height of the volume in voxels (Y-axis).
    public let height: Int

    /// The depth of the volume in voxels (Z-axis / slices).
    public let depth: Int

    /// The volume components (channels).
    public let components: [J2KVolumeComponent]

    /// The voxel spacing along the X-axis in physical units (e.g., millimeters).
    /// A value of zero indicates unset/unknown spacing.
    public let spacingX: Double

    /// The voxel spacing along the Y-axis in physical units.
    /// A value of zero indicates unset/unknown spacing.
    public let spacingY: Double

    /// The voxel spacing along the Z-axis in physical units.
    /// A value of zero indicates unset/unknown spacing.
    public let spacingZ: Double

    /// The origin X coordinate in physical space.
    public let originX: Double

    /// The origin Y coordinate in physical space.
    public let originY: Double

    /// The origin Z coordinate in physical space.
    public let originZ: Double

    /// Creates a new volume with the specified parameters.
    ///
    /// - Parameters:
    ///   - width: The width of the volume in voxels. Must be positive.
    ///   - height: The height of the volume in voxels. Must be positive.
    ///   - depth: The depth of the volume in voxels. Must be positive.
    ///   - components: The volume components (channels).
    ///   - spacingX: Voxel spacing along X-axis (default: 0, unset).
    ///   - spacingY: Voxel spacing along Y-axis (default: 0, unset).
    ///   - spacingZ: Voxel spacing along Z-axis (default: 0, unset).
    ///   - originX: Origin X coordinate (default: 0).
    ///   - originY: Origin Y coordinate (default: 0).
    ///   - originZ: Origin Z coordinate (default: 0).
    public init(
        width: Int,
        height: Int,
        depth: Int,
        components: [J2KVolumeComponent],
        spacingX: Double = 0,
        spacingY: Double = 0,
        spacingZ: Double = 0,
        originX: Double = 0,
        originY: Double = 0,
        originZ: Double = 0
    ) {
        self.width = width
        self.height = height
        self.depth = depth
        self.components = components
        self.spacingX = spacingX
        self.spacingY = spacingY
        self.spacingZ = spacingZ
        self.originX = originX
        self.originY = originY
        self.originZ = originZ
    }

    /// Convenience initializer for simple volumes.
    ///
    /// Creates a volume with the specified number of identical components,
    /// each having the same bit depth, signedness, and full-resolution dimensions.
    ///
    /// - Parameters:
    ///   - width: The width of the volume in voxels.
    ///   - height: The height of the volume in voxels.
    ///   - depth: The depth of the volume in voxels.
    ///   - componentCount: The number of components (e.g., 1 for grayscale, 3 for RGB).
    ///   - bitDepth: The bit depth per component (default: 8). Clamped to 1...38.
    ///   - signed: Whether components use signed values (default: false).
    public init(
        width: Int,
        height: Int,
        depth: Int,
        componentCount: Int,
        bitDepth: Int = 8,
        signed: Bool = false
    ) {
        let validWidth = max(1, width)
        let validHeight = max(1, height)
        let validDepth = max(1, depth)
        let validComponents = max(1, componentCount)
        let validBitDepth = max(1, min(38, bitDepth))

        let volumeComponents = (0..<validComponents).map { index in
            J2KVolumeComponent(
                index: index,
                bitDepth: validBitDepth,
                signed: signed,
                width: validWidth,
                height: validHeight,
                depth: validDepth
            )
        }

        self.init(
            width: validWidth,
            height: validHeight,
            depth: validDepth,
            components: volumeComponents
        )
    }

    // MARK: - Convenience Properties

    /// The total number of voxels in the volume.
    public var voxelCount: Int {
        width * height * depth
    }

    /// The number of components in the volume.
    public var componentCount: Int {
        components.count
    }

    /// Returns true if the volume is a single slice (depth == 1), making it effectively 2D.
    public var isSingleSlice: Bool {
        depth == 1
    }

    /// Returns true if voxel spacing has been set for all axes.
    public var hasSpacing: Bool {
        spacingX > 0 && spacingY > 0 && spacingZ > 0
    }

    /// The estimated memory size in bytes for the entire volume data across all components.
    ///
    /// Calculated as width × height × depth × componentCount × bytesPerSample for
    /// the maximum bit depth component.
    public var estimatedMemorySize: Int {
        var total = 0
        for component in components {
            let bytesPerSample = (component.bitDepth + 7) / 8
            total += component.width * component.height * component.depth * bytesPerSample
        }
        return total
    }

    // MARK: - Validation

    /// Validates that the volume has valid dimensions, components, and metadata.
    ///
    /// - Throws: ``J2KError/invalidDimensions(_:)`` if dimensions are invalid.
    /// - Throws: ``J2KError/invalidComponentConfiguration(_:)`` if components are invalid.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if metadata is invalid.
    public func validate() throws {
        // Validate dimensions
        guard width > 0 && height > 0 && depth > 0 else {
            throw J2KError.invalidDimensions(
                "Volume dimensions must be positive: \(width)×\(height)×\(depth)"
            )
        }

        // Validate components
        guard !components.isEmpty else {
            throw J2KError.invalidComponentConfiguration(
                "Volume must have at least one component"
            )
        }

        // Validate individual components
        for component in components {
            guard component.bitDepth >= 1 && component.bitDepth <= 38 else {
                throw J2KError.invalidBitDepth(
                    "Component \(component.index) has invalid bit depth: \(component.bitDepth)"
                )
            }
            guard component.width > 0 && component.height > 0 && component.depth > 0 else {
                throw J2KError.invalidDimensions(
                    "Component \(component.index) dimensions must be positive: "
                    + "\(component.width)×\(component.height)×\(component.depth)"
                )
            }
            guard component.subsamplingX > 0 && component.subsamplingY > 0
                && component.subsamplingZ > 0
            else {
                throw J2KError.invalidComponentConfiguration(
                    "Component \(component.index) subsampling factors must be positive"
                )
            }
        }

        // Validate spacing (if set, must be positive)
        if spacingX < 0 || spacingY < 0 || spacingZ < 0 {
            throw J2KError.invalidParameter(
                "Voxel spacing must be non-negative: (\(spacingX), \(spacingY), \(spacingZ))"
            )
        }

        // Validate against integer overflow in size calculations
        let maxDimProduct = Int.max / max(1, components.count)
        let widthTimesHeight = width.multipliedReportingOverflow(by: height)
        if widthTimesHeight.overflow {
            throw J2KError.invalidDimensions(
                "Volume dimensions cause integer overflow: \(width)×\(height)×\(depth)"
            )
        }
        let totalVoxels = widthTimesHeight.partialValue.multipliedReportingOverflow(by: depth)
        if totalVoxels.overflow || totalVoxels.partialValue > maxDimProduct {
            throw J2KError.invalidDimensions(
                "Volume size exceeds maximum: \(width)×\(height)×\(depth)×\(components.count)"
            )
        }
    }
}

/// Represents a single component (channel) of a volumetric image.
///
/// Each component has its own bit depth, sign, dimensions, and subsampling factors.
/// Components may be subsampled relative to the full volume resolution in any axis.
public struct J2KVolumeComponent: Sendable, Equatable {
    /// The index of this component (0-based).
    public let index: Int

    /// The bit depth of this component (1-38 bits).
    public let bitDepth: Int

    /// Whether this component uses signed values.
    public let signed: Bool

    /// The width of this component in voxels.
    public let width: Int

    /// The height of this component in voxels.
    public let height: Int

    /// The depth of this component in voxels.
    public let depth: Int

    /// The horizontal subsampling factor relative to the reference grid.
    public let subsamplingX: Int

    /// The vertical subsampling factor relative to the reference grid.
    public let subsamplingY: Int

    /// The depth subsampling factor relative to the reference grid.
    public let subsamplingZ: Int

    /// The voxel data for this component.
    public var data: Data

    /// Creates a new volume component with the specified parameters.
    ///
    /// - Parameters:
    ///   - index: The component index (0-based).
    ///   - bitDepth: The bit depth (1-38 bits).
    ///   - signed: Whether the component uses signed values.
    ///   - width: The width in voxels.
    ///   - height: The height in voxels.
    ///   - depth: The depth in voxels.
    ///   - subsamplingX: Horizontal subsampling factor (default: 1).
    ///   - subsamplingY: Vertical subsampling factor (default: 1).
    ///   - subsamplingZ: Depth subsampling factor (default: 1).
    ///   - data: The voxel data (default: empty).
    public init(
        index: Int,
        bitDepth: Int,
        signed: Bool,
        width: Int,
        height: Int,
        depth: Int,
        subsamplingX: Int = 1,
        subsamplingY: Int = 1,
        subsamplingZ: Int = 1,
        data: Data = Data()
    ) {
        self.index = index
        self.bitDepth = bitDepth
        self.signed = signed
        self.width = width
        self.height = height
        self.depth = depth
        self.subsamplingX = subsamplingX
        self.subsamplingY = subsamplingY
        self.subsamplingZ = subsamplingZ
        self.data = data
    }

    // MARK: - Convenience Properties

    /// The total number of voxels in this component.
    public var voxelCount: Int {
        width * height * depth
    }

    /// Returns true if this component is subsampled in any axis.
    public var isSubsampled: Bool {
        subsamplingX > 1 || subsamplingY > 1 || subsamplingZ > 1
    }

    /// The maximum representable value for this component's bit depth.
    public var maxValue: Int {
        if signed {
            return (1 << (bitDepth - 1)) - 1
        }
        return (1 << bitDepth) - 1
    }

    /// The minimum representable value for this component's bit depth.
    public var minValue: Int {
        if signed {
            return -(1 << (bitDepth - 1))
        }
        return 0
    }

    /// The number of bytes per sample for this component.
    public var bytesPerSample: Int {
        (bitDepth + 7) / 8
    }
}
