// Modified for Isis from JLSwift 299b9a2 (Apache-2.0); the modifications are recorded in Git.

/// Colour transformation types for JPEG-LS multi-component images
///
/// JPEG-LS supports colour space transformations to improve compression of
/// correlated colour components (e.g., RGB images).

import Foundation

/// Colour transformation type
///
/// Defines the transformation applied to multi-component images before encoding.
/// The decoder must apply the inverse transformation to recover the original colours.
public enum JPEGLSColorTransformation: UInt8, Sendable, Equatable {
    /// No colour transformation (components encoded independently)
    case none = 0

    /// HP1 transformation: For RGB images
    /// - G' = G
    /// - R' = R - G
    /// - B' = B - G
    case hp1 = 1

    /// HP2 transformation: For RGB images with better correlation
    /// - G' = G
    /// - R' = R - G
    /// - B' = B - ((R + G) >> 1)
    case hp2 = 2

    /// HP3 transformation: For RGB images (alternative)
    /// - B' = B
    /// - R' = R - B
    /// - G' = G - ((R + B) >> 1)
    case hp3 = 3

    /// Returns true if this transformation is applicable for the given component count
    ///
    /// - Parameter componentCount: Number of image components
    /// - Returns: True if transformation can be applied
    public func isValid(forComponentCount componentCount: Int) -> Bool {
        switch self {
        case .none:
            // No transformation is always valid
            return true
        case .hp1, .hp2, .hp3:
            // HP transformations require exactly 3 components (RGB)
            return componentCount == 3
        }
    }

    /// Apply the forward colour transformation to a pixel
    ///
    /// Transforms RGB components before encoding. The transformation is lossless
    /// and reversible. When `maxValue` is provided, modular arithmetic is applied
    /// so that all output values remain in [0, maxValue].
    ///
    /// ```swift
    /// // HP1 forward transform of an RGB pixel (0…255 range)
    /// let encoded = try JPEGLSColorTransformation.hp1.transformForward([200, 100, 50], maxValue: 255)
    /// // encoded = [100, 100, -50 mod 256] = [100, 100, 206]
    ///
    /// // HP2 forward transform
    /// let hp2 = try JPEGLSColorTransformation.hp2.transformForward([200, 100, 50], maxValue: 255)
    /// ```
    ///
    /// - Parameters:
    ///   - components: Original component values [R, G, B] or single component
    ///   - maxValue: Maximum sample value for modular reduction (nil = no reduction)
    /// - Returns: Transformed component values
    /// - Throws: `JPEGLSError.invalidComponentCount` if component count doesn't match transformation
    public func transformForward(_ components: [Int], maxValue: Int? = nil) throws -> [Int] {
        guard isValid(forComponentCount: components.count) else {
            throw JPEGLSError.invalidComponentCount(count: components.count)
        }

        switch self {
        case .none:
            return components

        case .hp1:
            let r = components[0]
            let g = components[1]
            let b = components[2]
            return [wrap(r - g, maxValue: maxValue), g, wrap(b - g, maxValue: maxValue)]

        case .hp2:
            let r = components[0]
            let g = components[1]
            let b = components[2]
            return [wrap(r - g, maxValue: maxValue), g, wrap(b - ((r + g) >> 1), maxValue: maxValue)]

        case .hp3:
            let r = components[0]
            let g = components[1]
            let b = components[2]
            return [wrap(r - b, maxValue: maxValue), wrap(g - ((r + b) >> 1), maxValue: maxValue), b]
        }
    }

    /// Apply the inverse colour transformation to recover original colours
    ///
    /// Transforms encoded components back to original colour space during decoding.
    /// When `maxValue` is provided, modular arithmetic is applied so that all output
    /// values remain in [0, maxValue].
    ///
    /// ```swift
    /// // Inverse HP1 transform (round-trip)
    /// let original = [200, 100, 50]
    /// let encoded  = try JPEGLSColorTransformation.hp1.transformForward(original, maxValue: 255)
    /// let decoded  = try JPEGLSColorTransformation.hp1.transformInverse(encoded, maxValue: 255)
    /// assert(decoded == original)
    /// ```
    ///
    /// - Parameters:
    ///   - components: Transformed component values
    ///   - maxValue: Maximum sample value for modular reduction (nil = no reduction)
    /// - Returns: Original component values [R, G, B] or single component
    /// - Throws: `JPEGLSError.invalidComponentCount` if component count doesn't match transformation
    public func transformInverse(_ components: [Int], maxValue: Int? = nil) throws -> [Int] {
        guard isValid(forComponentCount: components.count) else {
            throw JPEGLSError.invalidComponentCount(count: components.count)
        }

        switch self {
        case .none:
            return components

        case .hp1:
            let rPrime = components[0]
            let gPrime = components[1]
            let bPrime = components[2]
            return [wrap(rPrime + gPrime, maxValue: maxValue), gPrime, wrap(bPrime + gPrime, maxValue: maxValue)]

        case .hp2:
            let rPrime = components[0]
            let gPrime = components[1]
            let bPrime = components[2]
            let r = wrap(rPrime + gPrime, maxValue: maxValue)
            let g = gPrime
            let b = wrap(bPrime + ((r + g) >> 1), maxValue: maxValue)
            return [r, g, b]

        case .hp3:
            let rPrime = components[0]
            let gPrime = components[1]
            let bPrime = components[2]
            let b = bPrime
            let r = wrap(rPrime + b, maxValue: maxValue)
            let g = wrap(gPrime + ((r + b) >> 1), maxValue: maxValue)
            return [r, g, b]
        }
    }

    // MARK: - Private Helpers

    /// Apply modular reduction to keep value in [0, maxValue].
    ///
    /// When `maxValue` is nil the raw value is returned unchanged (backward-compatible).
    private func wrap(_ value: Int, maxValue: Int?) -> Int {
        guard let maxValue else { return value }
        let modulus = maxValue + 1
        return ((value % modulus) + modulus) % modulus
    }
}

extension JPEGLSColorTransformation: CustomStringConvertible {
    /// Human-readable name of the colour transformation
    public var description: String {
        switch self {
        case .none:
            return "None"
        case .hp1:
            return "HP1"
        case .hp2:
            return "HP2"
        case .hp3:
            return "HP3"
        }
    }
}
