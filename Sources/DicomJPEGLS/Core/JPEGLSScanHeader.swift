// Modified for Isis from JLSwift 299b9a2 (Apache-2.0); the modifications are recorded in Git.

/// JPEG-LS scan header per ITU-T.87
///
/// The scan header defines parameters for encoding/decoding a scan.
/// A scan contains one or more components encoded together.

import Foundation

/// JPEG-LS scan header
///
/// Encoded in the Start of Scan (SOS) marker segment.
public struct JPEGLSScanHeader: Sendable, Equatable {
    /// Number of components in this scan (1-4)
    public let componentCount: Int

    /// Component selectors for this scan
    public let components: [ComponentSelector]

    /// NEAR parameter for near-lossless mode (0 = lossless)
    public let near: Int

    /// Interleave mode for this scan
    public let interleaveMode: JPEGLSInterleaveMode

    /// Point transform (usually 0)
    public let pointTransform: Int

    /// Component selector within a scan
    public struct ComponentSelector: Sendable, Equatable {
        /// Component identifier (must match frame component ID)
        public let id: UInt8

        /// Mapping table ID referenced by this component (0 = no mapping table).
        ///
        /// When non-zero, decoded sample values for this component are treated as
        /// indices into the mapping table with this ID per ITU-T.87 §5.1.1.3.
        public let mappingTableID: UInt8

        /// Initialise a component selector.
        ///
        /// - Parameters:
        ///   - id: Component identifier.
        ///   - mappingTableID: Mapping table ID (0 = no mapping table).
        public init(id: UInt8, mappingTableID: UInt8 = 0) {
            self.id = id
            self.mappingTableID = mappingTableID
        }
    }

    /// Initialize scan header with validation
    ///
    /// - Parameters:
    ///   - componentCount: Number of components in scan
    ///   - components: Component selectors
    ///   - near: NEAR parameter (0 for lossless)
    ///   - interleaveMode: Component interleaving mode
    ///   - pointTransform: Point transform parameter
    /// - Throws: `JPEGLSError` if parameters are invalid
    public init(
        componentCount: Int,
        components: [ComponentSelector],
        near: Int,
        interleaveMode: JPEGLSInterleaveMode,
        pointTransform: Int = 0
    ) throws {
        // Validate component count
        guard componentCount >= 1 && componentCount <= 4 else {
            throw JPEGLSError.invalidComponentCount(count: componentCount)
        }

        // Validate components array matches count
        guard components.count == componentCount else {
            throw JPEGLSError.invalidScanHeader(
                reason: "Component count mismatch: expected \(componentCount), got \(components.count)"
            )
        }

        // Validate NEAR parameter
        guard near >= 0 && near <= 255 else {
            throw JPEGLSError.invalidNearParameter(near: near)
        }

        // Validate interleave mode for component count
        guard interleaveMode.isValid(forComponentCount: componentCount) else {
            throw JPEGLSError.invalidScanHeader(
                reason: "Interleave mode \(interleaveMode) invalid for \(componentCount) components"
            )
        }

        // Validate point transform
        guard pointTransform >= 0 && pointTransform <= 15 else {
            throw JPEGLSError.invalidScanHeader(
                reason: "Point transform must be in range [0, 15], got \(pointTransform)"
            )
        }

        self.componentCount = componentCount
        self.components = components
        self.near = near
        self.interleaveMode = interleaveMode
        self.pointTransform = pointTransform
    }

    /// Create a scan header for grayscale lossless encoding
    ///
    /// - Returns: Scan header for single component lossless
    /// - Throws: `JPEGLSError` if parameters are invalid
    public static func grayscaleLossless() throws -> JPEGLSScanHeader {
        return try JPEGLSScanHeader(
            componentCount: 1,
            components: [ComponentSelector(id: 1)],
            near: 0,
            interleaveMode: .none
        )
    }

    /// Create a scan header for RGB lossless encoding with sample interleaving
    ///
    /// - Returns: Scan header for RGB lossless with sample interleaving
    /// - Throws: `JPEGLSError` if parameters are invalid
    public static func rgbLossless() throws -> JPEGLSScanHeader {
        return try JPEGLSScanHeader(
            componentCount: 3,
            components: [
                ComponentSelector(id: 1),  // R
                ComponentSelector(id: 2),  // G
                ComponentSelector(id: 3)   // B
            ],
            near: 0,
            interleaveMode: .sample
        )
    }

    /// Returns true if this scan is lossless (NEAR = 0)
    public var isLossless: Bool {
        return near == 0
    }

    /// Returns true if this scan is near-lossless (NEAR > 0)
    public var isNearLossless: Bool {
        return near > 0
    }

    /// Validate that this scan header is compatible with a frame header
    ///
    /// - Parameter frameHeader: Frame header to validate against
    /// - Throws: `JPEGLSError.parameterMismatch` if incompatible
    public func validate(against frameHeader: JPEGLSFrameHeader) throws {
        // Check that all component IDs exist in frame
        let frameComponentIDs = Set(frameHeader.components.map { $0.id })
        for component in components {
            guard frameComponentIDs.contains(component.id) else {
                throw JPEGLSError.parameterMismatch(
                    reason: "Scan component ID \(component.id) not found in frame"
                )
            }
        }

        // For non-interleaved mode, scan must have exactly 1 component
        if interleaveMode == .none && componentCount != 1 {
            throw JPEGLSError.parameterMismatch(
                reason: "Non-interleaved scan must have exactly 1 component, got \(componentCount)"
            )
        }

        // For interleaved modes, all frame components should be in scan
        if interleaveMode != .none && componentCount != frameHeader.componentCount {
            throw JPEGLSError.parameterMismatch(
                reason: "Interleaved scan should include all \(frameHeader.componentCount) components, got \(componentCount)"
            )
        }
    }
}

extension JPEGLSScanHeader: CustomStringConvertible {
    /// Human-readable summary of scan header parameters
    public var description: String {
        let mode = isLossless ? "lossless" : "near-lossless(NEAR=\(near))"
        return "JPEGLSScanHeader(\(componentCount) components, \(interleaveMode), \(mode))"
    }
}
