//
// J2KColorTransform.swift
// J2KSwift
//
// J2KColorTransform.swift
// J2KSwift
//
// Created by J2KSwift on 2026-02-06.
//

import Foundation

#if canImport(Accelerate)
import Accelerate
#endif

/// Colour transform modes supported by JPEG 2000.
///
/// JPEG 2000 supports two types of colour transforms:
/// - **Reversible Colour Transform (RCT)**: Integer-to-integer transform for lossless compression
/// - **Irreversible Colour Transform (ICT)**: Floating-point transform for lossy compression
public enum J2KColorTransformMode: String, Sendable, CaseIterable {
    /// Reversible Colour Transform (RCT) - integer-to-integer, lossless
    case reversible = "RCT"

    /// Irreversible Colour Transform (ICT) - floating-point, lossy
    case irreversible = "ICT"

    /// No colour transform applied
    case none = "None"
}

/// Configuration for colour transform operations.
public struct J2KColorTransformConfiguration: Sendable {
    /// The colour transform mode to use.
    public let mode: J2KColorTransformMode

    /// Whether to validate reversibility (for RCT).
    public let validateReversibility: Bool

    /// Creates a new colour transform configuration.
    ///
    /// - Parameters:
    ///   - mode: The colour transform mode (default: .reversible).
    ///   - validateReversibility: Whether to validate reversibility for RCT (default: true in debug, false in release).
    public init(
        mode: J2KColorTransformMode = .reversible,
        validateReversibility: Bool = {
            #if DEBUG
            return true
            #else
            return false
            #endif
        }()
    ) {
        self.mode = mode
        self.validateReversibility = validateReversibility
    }

    /// Lossless configuration using RCT.
    public static let lossless = J2KColorTransformConfiguration(mode: .reversible)

    /// Lossy configuration using ICT.
    public static let lossy = J2KColorTransformConfiguration(mode: .irreversible)

    /// No transform configuration.
    public static let none = J2KColorTransformConfiguration(mode: .none)
}

/// Performs colour space transformations for JPEG 2000 encoding and decoding.
///
/// The `J2KColorTransform` class provides implementations of the Reversible Colour Transform (RCT)
/// and Irreversible Colour Transform (ICT) as defined in ISO/IEC 15444-1.
///
/// ## Reversible Colour Transform (RCT)
///
/// The RCT uses integer arithmetic to ensure perfect reversibility for lossless compression:
///
/// Forward transform (RGB → YCbCr):
/// ```
/// Y  = ⌊(R + 2G + B) / 4⌋
/// Cb = B - G
/// Cr = R - G
/// ```
///
/// Inverse transform (YCbCr → RGB):
/// ```
/// G = Y - ⌊(Cb + Cr) / 4⌋
/// R = Cr + G
/// B = Cb + G
/// ```
///
/// ## Usage Example
///
/// ```swift
/// let transform = J2KColorTransform()
///
/// // Forward transform (RGB → YCbCr)
/// let ycbcrComponents = try transform.forwardRCT(
///     red: redComponent,
///     green: greenComponent,
///     blue: blueComponent
/// )
///
/// // Inverse transform (YCbCr → RGB)
/// let rgbComponents = try transform.inverseRCT(
///     y: ycbcrComponents.0,
///     cb: ycbcrComponents.1,
///     cr: ycbcrComponents.2
/// )
/// ```
public struct J2KColorTransform: Sendable {
    /// Configuration for the colour transform.
    public let configuration: J2KColorTransformConfiguration

    /// Creates a new colour transform with the specified configuration.
    ///
    /// - Parameter configuration: The colour transform configuration (default: lossless).
    public init(configuration: J2KColorTransformConfiguration = .lossless) {
        self.configuration = configuration
    }

    // MARK: - Reversible Colour Transform (RCT)

    /// Applies the forward Reversible Colour Transform (RGB → YCbCr).
    ///
    /// Transforms RGB components to YCbCr using integer arithmetic for perfect reversibility.
    ///
    /// - Parameters:
    ///   - red: The red component data (signed integers).
    ///   - green: The green component data (signed integers).
    ///   - blue: The blue component data (signed integers).
    /// - Returns: A tuple containing (Y, Cb, Cr) component data.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if component sizes don't match or data is invalid.
    ///
    /// - Note: Input values should be signed integers. For unsigned input, subtract half the range
    ///         (e.g., subtract 128 for 8-bit data) before calling this method.
    public func forwardRCT(
        red: [Int32],
        green: [Int32],
        blue: [Int32]
    ) throws -> (y: [Int32], cb: [Int32], cr: [Int32]) {
        // Validate input
        guard red.count == green.count && green.count == blue.count else {
            throw J2KError.invalidParameter("Component sizes must match: R=\(red.count), G=\(green.count), B=\(blue.count)")
        }

        guard !red.isEmpty else {
            throw J2KError.invalidParameter("Components cannot be empty")
        }

        let count = red.count
        var y = [Int32](repeating: 0, count: count)
        var cb = [Int32](repeating: 0, count: count)
        var cr = [Int32](repeating: 0, count: count)

        // SIMD-optimized RCT transform: process 4 pixels at a time
        let simdCount = count & ~3
        var i = 0
        while i < simdCount {
            let r = SIMD4<Int32>(red[i], red[i+1], red[i+2], red[i+3])
            let g = SIMD4<Int32>(green[i], green[i+1], green[i+2], green[i+3])
            let b = SIMD4<Int32>(blue[i], blue[i+1], blue[i+2], blue[i+3])

            // Y = ⌊(R + 2G + B) / 4⌋
            let g2: SIMD4<Int32> = g &<< 1
            let yVal: SIMD4<Int32> = (r &+ g2 &+ b) &>> SIMD4<Int32>(repeating: 2)
            // Cb = B - G
            let cbVal: SIMD4<Int32> = b &- g
            // Cr = R - G
            let crVal: SIMD4<Int32> = r &- g

            y[i] = yVal[0]; y[i+1] = yVal[1]; y[i+2] = yVal[2]; y[i+3] = yVal[3]
            cb[i] = cbVal[0]; cb[i+1] = cbVal[1]; cb[i+2] = cbVal[2]; cb[i+3] = cbVal[3]
            cr[i] = crVal[0]; cr[i+1] = crVal[1]; cr[i+2] = crVal[2]; cr[i+3] = crVal[3]
            i += 4
        }
        // Handle remaining elements
        while i < count {
            let r = red[i]; let g = green[i]; let b = blue[i]
            y[i] = (r &+ (g &<< 1) &+ b) >> 2
            cb[i] = b &- g
            cr[i] = r &- g
            i += 1
        }

        return (y, cb, cr)
    }

    /// Applies the inverse Reversible Colour Transform (YCbCr → RGB).
    ///
    /// Transforms YCbCr components back to RGB using integer arithmetic for perfect reconstruction.
    ///
    /// - Parameters:
    ///   - y: The Y (luminance) component data.
    ///   - cb: The Cb (blue-difference) component data.
    ///   - cr: The Cr (red-difference) component data.
    /// - Returns: A tuple containing (R, G, B) component data.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if component sizes don't match or data is invalid.
    ///
    /// - Note: Output values are signed integers. For unsigned output, add half the range
    ///         (e.g., add 128 for 8-bit data) after calling this method.
    public func inverseRCT(
        y: [Int32],
        cb: [Int32],
        cr: [Int32]
    ) throws -> (red: [Int32], green: [Int32], blue: [Int32]) {
        // Validate input
        guard y.count == cb.count && cb.count == cr.count else {
            throw J2KError.invalidParameter("Component sizes must match: Y=\(y.count), Cb=\(cb.count), Cr=\(cr.count)")
        }

        guard !y.isEmpty else {
            throw J2KError.invalidParameter("Components cannot be empty")
        }

        let count = y.count
        var red = [Int32](repeating: 0, count: count)
        var green = [Int32](repeating: 0, count: count)
        var blue = [Int32](repeating: 0, count: count)

        // SIMD-optimized inverse RCT: process 4 pixels at a time
        let simdCount = count & ~3
        var i = 0
        while i < simdCount {
            let yV = SIMD4<Int32>(y[i], y[i+1], y[i+2], y[i+3])
            let cbV = SIMD4<Int32>(cb[i], cb[i+1], cb[i+2], cb[i+3])
            let crV = SIMD4<Int32>(cr[i], cr[i+1], cr[i+2], cr[i+3])

            // G = Y - ⌊(Cb + Cr) / 4⌋
            let cbcrSum: SIMD4<Int32> = cbV &+ crV
            let gVal: SIMD4<Int32> = yV &- (cbcrSum &>> SIMD4<Int32>(repeating: 2))
            // R = Cr + G
            let rVal: SIMD4<Int32> = crV &+ gVal
            // B = Cb + G
            let bVal: SIMD4<Int32> = cbV &+ gVal

            green[i] = gVal[0]; green[i+1] = gVal[1]; green[i+2] = gVal[2]; green[i+3] = gVal[3]
            red[i] = rVal[0]; red[i+1] = rVal[1]; red[i+2] = rVal[2]; red[i+3] = rVal[3]
            blue[i] = bVal[0]; blue[i+1] = bVal[1]; blue[i+2] = bVal[2]; blue[i+3] = bVal[3]
            i += 4
        }
        while i < count {
            let yVal = y[i]; let cbVal = cb[i]; let crVal = cr[i]
            green[i] = yVal &- ((cbVal &+ crVal) >> 2)
            red[i] = crVal &+ green[i]
            blue[i] = cbVal &+ green[i]
            i += 1
        }

        return (red, green, blue)
    }

    /// Applies the inverse RCT directly on Double arrays, avoiding Int32 conversion overhead.
    ///
    /// This overload is used by the decoder pipeline where data is already in `[Double]` form.
    /// The RCT integer arithmetic (floor division by 4) is replicated using `floor()` on Doubles.
    ///
    /// - Parameters:
    ///   - y: The Y (luminance) component data as Doubles (integer-valued).
    ///   - cb: The Cb (blue-difference) component data as Doubles (integer-valued).
    ///   - cr: The Cr (red-difference) component data as Doubles (integer-valued).
    /// - Returns: A tuple containing (R, G, B) component data as Doubles.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if component sizes don't match.
    public func inverseRCTDouble(
        y: [Double],
        cb: [Double],
        cr: [Double]
    ) throws -> (red: [Double], green: [Double], blue: [Double]) {
        guard y.count == cb.count && cb.count == cr.count else {
            throw J2KError.invalidParameter("Component sizes must match: Y=\(y.count), Cb=\(cb.count), Cr=\(cr.count)")
        }
        guard !y.isEmpty else {
            throw J2KError.invalidParameter("Components cannot be empty")
        }

        let count = y.count
        var red   = [Double](repeating: 0, count: count)
        var green = [Double](repeating: 0, count: count)
        var blue  = [Double](repeating: 0, count: count)

        #if canImport(Accelerate)
        if count >= 64 {
            // vDSP-accelerated inverse RCT
            var sum      = [Double](repeating: 0, count: count)
            var floorDiv = [Double](repeating: 0, count: count)
            let n = vDSP_Length(count)

            // sum = cb + cr
            vDSP_vaddD(cb, 1, cr, 1, &sum, 1, n)
            // floorDiv = sum * 0.25
            var quarter = 0.25
            vDSP_vsmulD(sum, 1, &quarter, &floorDiv, 1, n)
            // floorDiv = floor(floorDiv)
            vvfloor(&floorDiv, floorDiv, [Int32(count)])
            // green = y - floorDiv
            vDSP_vsubD(floorDiv, 1, y, 1, &green, 1, n)
            // red = cr + green
            vDSP_vaddD(cr, 1, green, 1, &red, 1, n)
            // blue = cb + green
            vDSP_vaddD(cb, 1, green, 1, &blue, 1, n)

            return (red, green, blue)
        }
        #endif

        // SIMD-optimized inverse RCT on Doubles
        let quarter = SIMD4<Double>(repeating: 0.25)
        let simdCount = count & ~3
        var i = 0
        while i < simdCount {
            let yV = SIMD4<Double>(y[i], y[i+1], y[i+2], y[i+3])
            let cbV = SIMD4<Double>(cb[i], cb[i+1], cb[i+2], cb[i+3])
            let crV = SIMD4<Double>(cr[i], cr[i+1], cr[i+2], cr[i+3])

            // G = Y - floor((Cb + Cr) / 4)
            let gVal = yV - ((cbV + crV) * quarter).rounded(.down)
            let rVal = crV + gVal
            let bVal = cbV + gVal

            green[i] = gVal[0]; green[i+1] = gVal[1]; green[i+2] = gVal[2]; green[i+3] = gVal[3]
            red[i] = rVal[0]; red[i+1] = rVal[1]; red[i+2] = rVal[2]; red[i+3] = rVal[3]
            blue[i] = bVal[0]; blue[i+1] = bVal[1]; blue[i+2] = bVal[2]; blue[i+3] = bVal[3]
            i += 4
        }
        while i < count {
            let yVal = y[i]; let cbVal = cb[i]; let crVal = cr[i]
            green[i] = yVal - Foundation.floor((cbVal + crVal) * 0.25)
            red[i] = crVal + green[i]
            blue[i] = cbVal + green[i]
            i += 1
        }

        return (red, green, blue)
    }

    /// Applies the forward RCT to multi-component image data.
    ///
    /// This is a convenience method that works with J2KComponent objects.
    ///
    /// - Parameters:
    ///   - redComponent: The red component.
    ///   - greenComponent: The green component.
    ///   - blueComponent: The blue component.
    /// - Returns: A tuple containing (Y, Cb, Cr) components.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if components are invalid or mismatched.
    public func forwardRCT(
        redComponent: J2KComponent,
        greenComponent: J2KComponent,
        blueComponent: J2KComponent
    ) throws -> (y: J2KComponent, cb: J2KComponent, cr: J2KComponent) {
        // Validate components
        guard redComponent.width == greenComponent.width &&
              greenComponent.width == blueComponent.width &&
              redComponent.height == greenComponent.height &&
              greenComponent.height == blueComponent.height else {
            throw J2KError.invalidComponentConfiguration("Component dimensions must match")
        }

        // Convert to signed Int32 arrays
        let red = try convertToInt32Array(redComponent)
        let green = try convertToInt32Array(greenComponent)
        let blue = try convertToInt32Array(blueComponent)

        // Apply transform
        let (y, cb, cr) = try forwardRCT(red: red, green: green, blue: blue)

        // Convert back to components
        let yComponent = try createComponent(
            from: y,
            template: redComponent,
            index: 0
        )
        let cbComponent = try createComponent(
            from: cb,
            template: greenComponent,
            index: 1
        )
        let crComponent = try createComponent(
            from: cr,
            template: blueComponent,
            index: 2
        )

        return (yComponent, cbComponent, crComponent)
    }

    /// Applies the inverse RCT to multi-component image data.
    ///
    /// This is a convenience method that works with J2KComponent objects.
    ///
    /// - Parameters:
    ///   - yComponent: The Y (luminance) component.
    ///   - cbComponent: The Cb (blue-difference) component.
    ///   - crComponent: The Cr (red-difference) component.
    /// - Returns: A tuple containing (R, G, B) components.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if components are invalid or mismatched.
    public func inverseRCT(
        yComponent: J2KComponent,
        cbComponent: J2KComponent,
        crComponent: J2KComponent
    ) throws -> (red: J2KComponent, green: J2KComponent, blue: J2KComponent) {
        // Validate components
        guard yComponent.width == cbComponent.width &&
              cbComponent.width == crComponent.width &&
              yComponent.height == cbComponent.height &&
              cbComponent.height == crComponent.height else {
            throw J2KError.invalidComponentConfiguration("Component dimensions must match")
        }

        // Convert to signed Int32 arrays
        let y = try convertToInt32Array(yComponent)
        let cb = try convertToInt32Array(cbComponent)
        let cr = try convertToInt32Array(crComponent)

        // Apply transform
        let (red, green, blue) = try inverseRCT(y: y, cb: cb, cr: cr)

        // Convert back to components
        let redComponent = try createComponent(
            from: red,
            template: yComponent,
            index: 0
        )
        let greenComponent = try createComponent(
            from: green,
            template: cbComponent,
            index: 1
        )
        let blueComponent = try createComponent(
            from: blue,
            template: crComponent,
            index: 2
        )

        return (redComponent, greenComponent, blueComponent)
    }

    // MARK: - Irreversible Colour Transform (ICT)

    /// Applies the forward Irreversible Colour Transform (RGB → YCbCr).
    ///
    /// Transforms RGB components to YCbCr using floating-point arithmetic for better decorrelation.
    /// This transform is not reversible due to floating-point rounding, but provides better
    /// compression for lossy encoding.
    ///
    /// Forward transform formulas (ISO/IEC 15444-1, Annex G.3):
    /// ```
    /// Y  = 0.299 × R + 0.587 × G + 0.114 × B
    /// Cb = -0.168736 × R - 0.331264 × G + 0.5 × B
    /// Cr = 0.5 × R - 0.418688 × G - 0.081312 × B
    /// ```
    ///
    /// - Parameters:
    ///   - red: The red component data (floating-point).
    ///   - green: The green component data (floating-point).
    ///   - blue: The blue component data (floating-point).
    /// - Returns: A tuple containing (Y, Cb, Cr) component data as floating-point values.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if component sizes don't match or data is invalid.
    ///
    /// - Note: For unsigned 8-bit input, subtract 128 from each component before calling this method.
    ///         The output will be in the range suitable for quantization.
    public func forwardICT(
        red: [Double],
        green: [Double],
        blue: [Double]
    ) throws -> (y: [Double], cb: [Double], cr: [Double]) {
        // Validate input
        guard red.count == green.count && green.count == blue.count else {
            throw J2KError.invalidParameter("Component sizes must match: R=\(red.count), G=\(green.count), B=\(blue.count)")
        }

        guard !red.isEmpty else {
            throw J2KError.invalidParameter("Components cannot be empty")
        }

        let count = red.count

        // ICT coefficients from ISO/IEC 15444-1 Annex G.3
        let coeffY_R: Double = 0.299
        let coeffY_G: Double = 0.587
        let coeffY_B: Double = 0.114

        let coeffCb_R: Double = -0.168736
        let coeffCb_G: Double = -0.331264
        let coeffCb_B: Double = 0.5

        let coeffCr_R: Double = 0.5
        let coeffCr_G: Double = -0.418688
        let coeffCr_B: Double = -0.081312

        #if canImport(Accelerate)
        if count >= 64 {
            // vDSP-accelerated ICT: Y/Cb/Cr = a*R + b*G + c*B via vector multiply-add
            // Skip zero-init: all elements written by vDSP before any read.
            var y    = [Double](unsafeUninitializedCapacity: count) { _, s in s = count }
            var cb   = [Double](unsafeUninitializedCapacity: count) { _, s in s = count }
            var cr   = [Double](unsafeUninitializedCapacity: count) { _, s in s = count }
            var temp = [Double](unsafeUninitializedCapacity: count) { _, s in s = count }
            let n = vDSP_Length(count)

            // Y = coeffY_R * R
            var cYR = coeffY_R
            vDSP_vsmulD(red, 1, &cYR, &y, 1, n)
            // Y += coeffY_G * G
            var cYG = coeffY_G
            vDSP_vsmulD(green, 1, &cYG, &temp, 1, n)
            vDSP_vaddD(y, 1, temp, 1, &y, 1, n)
            // Y += coeffY_B * B
            var cYB = coeffY_B
            vDSP_vsmulD(blue, 1, &cYB, &temp, 1, n)
            vDSP_vaddD(y, 1, temp, 1, &y, 1, n)

            // Cb = coeffCb_R * R
            var cCbR = coeffCb_R
            vDSP_vsmulD(red, 1, &cCbR, &cb, 1, n)
            // Cb += coeffCb_G * G
            var cCbG = coeffCb_G
            vDSP_vsmulD(green, 1, &cCbG, &temp, 1, n)
            vDSP_vaddD(cb, 1, temp, 1, &cb, 1, n)
            // Cb += coeffCb_B * B
            var cCbB = coeffCb_B
            vDSP_vsmulD(blue, 1, &cCbB, &temp, 1, n)
            vDSP_vaddD(cb, 1, temp, 1, &cb, 1, n)

            // Cr = coeffCr_R * R
            var cCrR = coeffCr_R
            vDSP_vsmulD(red, 1, &cCrR, &cr, 1, n)
            // Cr += coeffCr_G * G
            var cCrG = coeffCr_G
            vDSP_vsmulD(green, 1, &cCrG, &temp, 1, n)
            vDSP_vaddD(cr, 1, temp, 1, &cr, 1, n)
            // Cr += coeffCr_B * B
            var cCrB = coeffCr_B
            vDSP_vsmulD(blue, 1, &cCrB, &temp, 1, n)
            vDSP_vaddD(cr, 1, temp, 1, &cr, 1, n)

            return (y, cb, cr)
        }
        #endif

        var y  = [Double](unsafeUninitializedCapacity: count) { _, s in s = count }
        var cb = [Double](unsafeUninitializedCapacity: count) { _, s in s = count }
        var cr = [Double](unsafeUninitializedCapacity: count) { _, s in s = count }

        // SIMD-optimized ICT: process 4 pixels at a time using SIMD4<Double>
        let sYR = SIMD4<Double>(repeating: coeffY_R)
        let sYG = SIMD4<Double>(repeating: coeffY_G)
        let sYB = SIMD4<Double>(repeating: coeffY_B)
        let sCbR = SIMD4<Double>(repeating: coeffCb_R)
        let sCbG = SIMD4<Double>(repeating: coeffCb_G)
        let sCbB = SIMD4<Double>(repeating: coeffCb_B)
        let sCrR = SIMD4<Double>(repeating: coeffCr_R)
        let sCrG = SIMD4<Double>(repeating: coeffCr_G)
        let sCrB = SIMD4<Double>(repeating: coeffCr_B)

        let simdCount = count & ~3
        var i = 0
        while i < simdCount {
            let r = SIMD4<Double>(red[i], red[i+1], red[i+2], red[i+3])
            let g = SIMD4<Double>(green[i], green[i+1], green[i+2], green[i+3])
            let b = SIMD4<Double>(blue[i], blue[i+1], blue[i+2], blue[i+3])

            let yVal = sYR * r + sYG * g + sYB * b
            let cbVal = sCbR * r + sCbG * g + sCbB * b
            let crVal = sCrR * r + sCrG * g + sCrB * b

            y[i] = yVal[0]; y[i+1] = yVal[1]; y[i+2] = yVal[2]; y[i+3] = yVal[3]
            cb[i] = cbVal[0]; cb[i+1] = cbVal[1]; cb[i+2] = cbVal[2]; cb[i+3] = cbVal[3]
            cr[i] = crVal[0]; cr[i+1] = crVal[1]; cr[i+2] = crVal[2]; cr[i+3] = crVal[3]
            i += 4
        }
        while i < count {
            let r = red[i]; let g = green[i]; let b = blue[i]
            y[i] = coeffY_R * r + coeffY_G * g + coeffY_B * b
            cb[i] = coeffCb_R * r + coeffCb_G * g + coeffCb_B * b
            cr[i] = coeffCr_R * r + coeffCr_G * g + coeffCr_B * b
            i += 1
        }

        return (y, cb, cr)
    }

    /// Applies the inverse Irreversible Colour Transform (YCbCr → RGB).
    ///
    /// Transforms YCbCr components back to RGB using floating-point arithmetic.
    /// Due to floating-point rounding, the reconstruction is not perfect.
    ///
    /// Inverse transform formulas (ISO/IEC 15444-1, Annex G.3):
    /// ```
    /// R = Y + 1.402 × Cr
    /// G = Y - 0.344136 × Cb - 0.714136 × Cr
    /// B = Y + 1.772 × Cb
    /// ```
    ///
    /// - Parameters:
    ///   - y: The Y (luminance) component data (floating-point).
    ///   - cb: The Cb (blue-difference) component data (floating-point).
    ///   - cr: The Cr (red-difference) component data (floating-point).
    /// - Returns: A tuple containing (R, G, B) component data as floating-point values.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if component sizes don't match or data is invalid.
    ///
    /// - Note: For unsigned 8-bit output, add 128 to each component after calling this method
    ///         and clamp to [0, 255] range.
    public func inverseICT(
        y: [Double],
        cb: [Double],
        cr: [Double]
    ) throws -> (red: [Double], green: [Double], blue: [Double]) {
        // Validate input
        guard y.count == cb.count && cb.count == cr.count else {
            throw J2KError.invalidParameter("Component sizes must match: Y=\(y.count), Cb=\(cb.count), Cr=\(cr.count)")
        }

        guard !y.isEmpty else {
            throw J2KError.invalidParameter("Components cannot be empty")
        }

        let count = y.count
        var red   = [Double](repeating: 0, count: count)
        var green = [Double](repeating: 0, count: count)
        var blue  = [Double](repeating: 0, count: count)

        // Inverse ICT coefficients from ISO/IEC 15444-1 Annex G.3
        let coeffR_Cr: Double = 1.402
        let coeffG_Cb: Double = -0.344136
        let coeffG_Cr: Double = -0.714136
        let coeffB_Cb: Double = 1.772

        #if canImport(Accelerate)
        if count >= 64 {
            // vDSP_vsmaD: D = A*b + C  (no temp array needed — 4 calls vs 7)
            let n = vDSP_Length(count)
            var cRCr = coeffR_Cr; var cGCb = coeffG_Cb
            var cGCr = coeffG_Cr; var cBCb = coeffB_Cb

            vDSP_vsmaD(cr, 1, &cRCr, y,     1, &red,   1, n)  // R = Cr*1.402 + Y
            vDSP_vsmaD(cb, 1, &cGCb, y,     1, &green, 1, n)  // G = Cb*(-0.344136) + Y
            vDSP_vsmaD(cr, 1, &cGCr, green, 1, &green, 1, n)  // G += Cr*(-0.714136)
            vDSP_vsmaD(cb, 1, &cBCb, y,     1, &blue,  1, n)  // B = Cb*1.772 + Y

            return (red, green, blue)
        }
        #endif

        // SIMD-optimized inverse ICT: process 4 pixels at a time
        let sRCr = SIMD4<Double>(repeating: coeffR_Cr)
        let sGCb = SIMD4<Double>(repeating: coeffG_Cb)
        let sGCr = SIMD4<Double>(repeating: coeffG_Cr)
        let sBCb = SIMD4<Double>(repeating: coeffB_Cb)

        let simdCount = count & ~3
        var i = 0
        while i < simdCount {
            let yV = SIMD4<Double>(y[i], y[i+1], y[i+2], y[i+3])
            let cbV = SIMD4<Double>(cb[i], cb[i+1], cb[i+2], cb[i+3])
            let crV = SIMD4<Double>(cr[i], cr[i+1], cr[i+2], cr[i+3])

            let rVal = yV + sRCr * crV
            let gVal = yV + sGCb * cbV + sGCr * crV
            let bVal = yV + sBCb * cbV

            red[i] = rVal[0]; red[i+1] = rVal[1]; red[i+2] = rVal[2]; red[i+3] = rVal[3]
            green[i] = gVal[0]; green[i+1] = gVal[1]; green[i+2] = gVal[2]; green[i+3] = gVal[3]
            blue[i] = bVal[0]; blue[i+1] = bVal[1]; blue[i+2] = bVal[2]; blue[i+3] = bVal[3]
            i += 4
        }
        while i < count {
            let yVal = y[i]; let cbVal = cb[i]; let crVal = cr[i]
            red[i] = yVal + coeffR_Cr * crVal
            green[i] = yVal + coeffG_Cb * cbVal + coeffG_Cr * crVal
            blue[i] = yVal + coeffB_Cb * cbVal
            i += 1
        }

        return (red, green, blue)
    }

    /// Applies the forward ICT to multi-component image data.
    ///
    /// This is a convenience method that works with J2KComponent objects.
    ///
    /// - Parameters:
    ///   - redComponent: The red component.
    ///   - greenComponent: The green component.
    ///   - blueComponent: The blue component.
    /// - Returns: A tuple containing (Y, Cb, Cr) components.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if components are invalid or mismatched.
    public func forwardICT(
        redComponent: J2KComponent,
        greenComponent: J2KComponent,
        blueComponent: J2KComponent
    ) throws -> (y: J2KComponent, cb: J2KComponent, cr: J2KComponent) {
        // Validate components
        guard redComponent.width == greenComponent.width &&
              greenComponent.width == blueComponent.width &&
              redComponent.height == greenComponent.height &&
              greenComponent.height == blueComponent.height else {
            throw J2KError.invalidComponentConfiguration("Component dimensions must match")
        }

        // Convert to Double arrays
        let red = try convertToDoubleArray(redComponent)
        let green = try convertToDoubleArray(greenComponent)
        let blue = try convertToDoubleArray(blueComponent)

        // Apply transform
        let (y, cb, cr) = try forwardICT(red: red, green: green, blue: blue)

        // Convert back to components
        let yComponent = try createComponentFromDouble(
            from: y,
            template: redComponent,
            index: 0
        )
        let cbComponent = try createComponentFromDouble(
            from: cb,
            template: greenComponent,
            index: 1
        )
        let crComponent = try createComponentFromDouble(
            from: cr,
            template: blueComponent,
            index: 2
        )

        return (yComponent, cbComponent, crComponent)
    }

    /// Applies the inverse ICT to multi-component image data.
    ///
    /// This is a convenience method that works with J2KComponent objects.
    ///
    /// - Parameters:
    ///   - yComponent: The Y (luminance) component.
    ///   - cbComponent: The Cb (blue-difference) component.
    ///   - crComponent: The Cr (red-difference) component.
    /// - Returns: A tuple containing (R, G, B) components.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if components are invalid or mismatched.
    public func inverseICT(
        yComponent: J2KComponent,
        cbComponent: J2KComponent,
        crComponent: J2KComponent
    ) throws -> (red: J2KComponent, green: J2KComponent, blue: J2KComponent) {
        // Validate components
        guard yComponent.width == cbComponent.width &&
              cbComponent.width == crComponent.width &&
              yComponent.height == cbComponent.height &&
              cbComponent.height == crComponent.height else {
            throw J2KError.invalidComponentConfiguration("Component dimensions must match")
        }

        // Convert to Double arrays
        let y = try convertToDoubleArray(yComponent)
        let cb = try convertToDoubleArray(cbComponent)
        let cr = try convertToDoubleArray(crComponent)

        // Apply transform
        let (red, green, blue) = try inverseICT(y: y, cb: cb, cr: cr)

        // Convert back to components
        let redComponent = try createComponentFromDouble(
            from: red,
            template: yComponent,
            index: 0
        )
        let greenComponent = try createComponentFromDouble(
            from: green,
            template: cbComponent,
            index: 1
        )
        let blueComponent = try createComponentFromDouble(
            from: blue,
            template: crComponent,
            index: 2
        )

        return (redComponent, greenComponent, blueComponent)
    }

    // MARK: - Grayscale Support

    /// Converts RGB components to grayscale using standard luminance weights.
    ///
    /// Uses the standard ITU-R BT.601 luminance formula:
    /// ```
    /// Y = 0.299 × R + 0.587 × G + 0.114 × B
    /// ```
    ///
    /// - Parameters:
    ///   - red: The red component data.
    ///   - green: The green component data.
    ///   - blue: The blue component data.
    /// - Returns: The grayscale luminance values.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if component sizes don't match or data is invalid.
    public func rgbToGrayscale(
        red: [Int32],
        green: [Int32],
        blue: [Int32]
    ) throws -> [Int32] {
        // Validate input
        guard red.count == green.count && green.count == blue.count else {
            throw J2KError.invalidParameter("Component sizes must match: R=\(red.count), G=\(green.count), B=\(blue.count)")
        }

        guard !red.isEmpty else {
            throw J2KError.invalidParameter("Components cannot be empty")
        }

        let count = red.count
        var gray = [Int32](repeating: 0, count: count)

        // Apply luminance formula
        // Y = 0.299 × R + 0.587 × G + 0.114 × B
        // Using fixed-point arithmetic for precision: multiply by 1024, then divide
        let weightR: Int32 = 306  // 0.299 × 1024
        let weightG: Int32 = 601  // 0.587 × 1024
        let weightB: Int32 = 117  // 0.114 × 1024

        for i in 0..<count {
            let r = red[i]
            let g = green[i]
            let b = blue[i]

            // Use fixed-point arithmetic for better precision
            let weighted = (r * weightR + g * weightG + b * weightB + 512) >> 10
            gray[i] = weighted
        }

        return gray
    }

    /// Converts RGB components to grayscale using floating-point precision.
    ///
    /// - Parameters:
    ///   - red: The red component data.
    ///   - green: The green component data.
    ///   - blue: The blue component data.
    /// - Returns: The grayscale luminance values.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if component sizes don't match or data is invalid.
    public func rgbToGrayscale(
        red: [Double],
        green: [Double],
        blue: [Double]
    ) throws -> [Double] {
        // Validate input
        guard red.count == green.count && green.count == blue.count else {
            throw J2KError.invalidParameter("Component sizes must match: R=\(red.count), G=\(green.count), B=\(blue.count)")
        }

        guard !red.isEmpty else {
            throw J2KError.invalidParameter("Components cannot be empty")
        }

        let count = red.count
        var gray = [Double](repeating: 0, count: count)

        // Apply luminance formula
        let weightR: Double = 0.299
        let weightG: Double = 0.587
        let weightB: Double = 0.114

        for i in 0..<count {
            gray[i] = weightR * red[i] + weightG * green[i] + weightB * blue[i]
        }

        return gray
    }

    /// Converts grayscale to RGB by replicating the gray value across all channels.
    ///
    /// - Parameter gray: The grayscale component data.
    /// - Returns: A tuple containing (R, G, B) with replicated gray values.
    public func grayscaleToRGB(gray: [Int32]) -> (red: [Int32], green: [Int32], blue: [Int32]) {
        (red: gray, green: gray, blue: gray)
    }

    /// Converts grayscale to RGB by replicating the gray value across all channels.
    ///
    /// - Parameter gray: The grayscale component data.
    /// - Returns: A tuple containing (R, G, B) with replicated gray values.
    public func grayscaleToRGB(gray: [Double]) -> (red: [Double], green: [Double], blue: [Double]) {
        (red: gray, green: gray, blue: gray)
    }

    /// Converts RGB component to grayscale using standard luminance weights.
    ///
    /// - Parameters:
    ///   - redComponent: The red component.
    ///   - greenComponent: The green component.
    ///   - blueComponent: The blue component.
    /// - Returns: The grayscale component.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if components are invalid or mismatched.
    public func rgbToGrayscale(
        redComponent: J2KComponent,
        greenComponent: J2KComponent,
        blueComponent: J2KComponent
    ) throws -> J2KComponent {
        // Validate components
        guard redComponent.width == greenComponent.width &&
              greenComponent.width == blueComponent.width &&
              redComponent.height == greenComponent.height &&
              greenComponent.height == blueComponent.height else {
            throw J2KError.invalidComponentConfiguration("Component dimensions must match")
        }

        // Convert to arrays
        let red = try convertToInt32Array(redComponent)
        let green = try convertToInt32Array(greenComponent)
        let blue = try convertToInt32Array(blueComponent)

        // Apply transform
        let gray = try rgbToGrayscale(red: red, green: green, blue: blue)

        // Convert back to component
        return try createComponent(
            from: gray,
            template: redComponent,
            index: 0
        )
    }

    // MARK: - Palette Support

    /// Represents a colour palette for indexed colour images.
    public struct Palette: Sendable {
        /// The palette entries (RGB triplets).
        public let entries: [(red: UInt8, green: UInt8, blue: UInt8)]

        /// Creates a new palette.
        ///
        /// - Parameter entries: The palette entries.
        public init(entries: [(red: UInt8, green: UInt8, blue: UInt8)]) {
            self.entries = entries
        }

        /// The number of entries in the palette.
        public var count: Int {
            entries.count
        }
    }

    /// Expands indexed colour data using a palette to RGB components.
    ///
    /// - Parameters:
    ///   - indices: The palette indices (0 to palette.count-1).
    ///   - palette: The colour palette.
    /// - Returns: A tuple containing (R, G, B) component data.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if indices are out of range.
    public func expandPalette(
        indices: [UInt8],
        palette: Palette
    ) throws -> (red: [UInt8], green: [UInt8], blue: [UInt8]) {
        guard !indices.isEmpty else {
            throw J2KError.invalidParameter("Indices cannot be empty")
        }

        let count = indices.count
        var red = [UInt8](repeating: 0, count: count)
        var green = [UInt8](repeating: 0, count: count)
        var blue = [UInt8](repeating: 0, count: count)

        for i in 0..<count {
            let index = Int(indices[i])
            guard index < palette.count else {
                throw J2KError.invalidParameter("Palette index \(index) out of range [0, \(palette.count))")
            }

            let entry = palette.entries[index]
            red[i] = entry.red
            green[i] = entry.green
            blue[i] = entry.blue
        }

        return (red, green, blue)
    }

    /// A colour value used for palette operations.
    private struct RGBColor: Hashable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8

        func asTuple() -> (red: UInt8, green: UInt8, blue: UInt8) {
            (red: red, green: green, blue: blue)
        }
    }

    /// Creates a palette from RGB component data using colour quantization.
    ///
    /// This uses a simple median cut algorithm to reduce colours.
    ///
    /// - Parameters:
    ///   - red: The red component data.
    ///   - green: The green component data.
    ///   - blue: The blue component data.
    ///   - maxColors: The maximum number of palette entries (default: 256).
    /// - Returns: A tuple containing the palette and indices.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if component sizes don't match or data is invalid.
    public func createPalette(
        red: [UInt8],
        green: [UInt8],
        blue: [UInt8],
        maxColors: Int = 256
    ) throws -> (palette: Palette, indices: [UInt8]) {
        // Validate input
        guard red.count == green.count && green.count == blue.count else {
            throw J2KError.invalidParameter("Component sizes must match")
        }

        guard !red.isEmpty else {
            throw J2KError.invalidParameter("Components cannot be empty")
        }

        guard maxColors > 0 && maxColors <= 256 else {
            throw J2KError.invalidParameter("maxColors must be in range [1, 256]")
        }

        // Build colour histogram
        var colorMap: [RGBColor: Int] = [:]
        let count = red.count

        for i in 0..<count {
            let color = RGBColor(red: red[i], green: green[i], blue: blue[i])
            colorMap[color, default: 0] += 1
        }

        // If we already have few enough colours, use them directly
        if colorMap.count <= maxColors {
            let entries = colorMap.keys.map { $0.asTuple() }
            let palette = Palette(entries: entries)

            // Create index mapping
            let colorToIndex = Dictionary(uniqueKeysWithValues:
                colorMap.keys.enumerated().map { ($1, UInt8($0)) }
            )
            var indices = [UInt8](repeating: 0, count: count)

            for i in 0..<count {
                let color = RGBColor(red: red[i], green: green[i], blue: blue[i])
                indices[i] = colorToIndex[color] ?? 0
            }

            return (palette, indices)
        }

        // Otherwise, use simple colour quantization
        // For simplicity, we'll use a basic approach: take the most common colours
        let sortedColors = colorMap.sorted { $0.value > $1.value }
        let topColors = Array(sortedColors.prefix(maxColors).map { $0.key })
        let entries = topColors.map { $0.asTuple() }
        let palette = Palette(entries: entries)

        // Create index mapping
        let colorToIndex = Dictionary(uniqueKeysWithValues:
            topColors.enumerated().map { ($1, UInt8($0)) }
        )

        // Map each pixel to nearest palette entry
        var indices = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            let color = RGBColor(red: red[i], green: green[i], blue: blue[i])

            if let index = colorToIndex[color] {
                indices[i] = index
            } else {
                // Find nearest colour in palette
                var minDistance = Int.max
                var bestIndex: UInt8 = 0

                for (idx, entry) in entries.enumerated() {
                    let dr = Int(entry.red) - Int(color.red)
                    let dg = Int(entry.green) - Int(color.green)
                    let db = Int(entry.blue) - Int(color.blue)
                    let distance = dr * dr + dg * dg + db * db

                    if distance < minDistance {
                        minDistance = distance
                        bestIndex = UInt8(idx)
                    }
                }

                indices[i] = bestIndex
            }
        }

        return (palette, indices)
    }

    // MARK: - Colour Space Detection

    /// Detects the colour space based on the number and properties of components.
    ///
    /// - Parameter components: The image components.
    /// - Returns: The detected colour space.
    public static func detectColorSpace(components: [J2KComponent]) -> J2KColorSpace {
        guard !components.isEmpty else {
            return .unknown
        }

        let componentCount = components.count

        switch componentCount {
        case 1:
            return .grayscale
        case 3:
            // Assume RGB for 3-component images
            return .sRGB
        case 4:
            // Could be RGBA or CMYK, but default to sRGB for now
            return .sRGB
        default:
            return .unknown
        }
    }

    /// Validates that components are suitable for a given colour space.
    ///
    /// - Parameters:
    ///   - components: The image components.
    ///   - colorSpace: The expected colour space.
    /// - Throws: ``J2KError/invalidComponentConfiguration(_:)`` if components don't match the colour space.
    public static func validateColorSpace(
        components: [J2KComponent],
        colorSpace: J2KColorSpace
    ) throws {
        switch colorSpace {
        case .grayscale:
            guard components.count == 1 else {
                throw J2KError.invalidComponentConfiguration(
                    "Grayscale color space requires 1 component, got \(components.count)"
                )
            }

        case .sRGB, .yCbCr, .hdr, .hdrLinear:
            guard components.count >= 3 else {
                throw J2KError.invalidComponentConfiguration(
                    "RGB/YCbCr/HDR color space requires at least 3 components, got \(components.count)"
                )
            }

        case .iccProfile:
            // ICC profiles can support arbitrary component counts
            break

        case .unknown:
            // Unknown colour space, no validation
            break
        }
    }

    // MARK: - Component Subsampling Support

    /// Information about component subsampling.
    public struct SubsamplingInfo: Sendable, Equatable {
        /// Horizontal subsampling factor (e.g., 2 for 4:2:0).
        public let horizontalFactor: Int

        /// Vertical subsampling factor (e.g., 2 for 4:2:0).
        public let verticalFactor: Int

        /// Creates a new subsampling info.
        public init(horizontalFactor: Int, verticalFactor: Int) {
            self.horizontalFactor = horizontalFactor
            self.verticalFactor = verticalFactor
        }

        /// No subsampling (4:4:4).
        public static let none = SubsamplingInfo(horizontalFactor: 1, verticalFactor: 1)

        /// 4:2:2 subsampling (horizontal only).
        public static let yuv422 = SubsamplingInfo(horizontalFactor: 2, verticalFactor: 1)

        /// 4:2:0 subsampling (both horizontal and vertical).
        public static let yuv420 = SubsamplingInfo(horizontalFactor: 2, verticalFactor: 2)
    }

    /// Validates that all components have matching subsampling.
    ///
    /// - Parameters:
    ///   - components: The components to validate.
    /// - Throws: ``J2KError/invalidComponentConfiguration(_:)`` if subsampling doesn't match.
    public func validateSubsampling(_ components: [J2KComponent]) throws {
        guard components.count >= 3 else {
            throw J2KError.invalidComponentConfiguration("Need at least 3 components for color transform")
        }

        let refSubsamplingX = components[0].subsamplingX
        let refSubsamplingY = components[0].subsamplingY

        for (index, component) in components.enumerated() {
            if component.subsamplingX != refSubsamplingX ||
               component.subsamplingY != refSubsamplingY {
                throw J2KError.invalidComponentConfiguration(
                    "Component \(index) subsampling (\(component.subsamplingX)x\(component.subsamplingY)) " +
                    "doesn't match reference (\(refSubsamplingX)x\(refSubsamplingY))"
                )
            }
        }
    }

    // MARK: - Helper Methods

    /// Converts a J2KComponent to an Int32 array.
    private func convertToInt32Array(_ component: J2KComponent) throws -> [Int32] {
        let pixelCount = component.width * component.height
        var result = [Int32](repeating: 0, count: pixelCount)

        // For now, assume data is stored as Int32 in native byte order
        // In a real implementation, this would handle various bit depths and formats
        guard component.data.count >= pixelCount * MemoryLayout<Int32>.size else {
            throw J2KError.invalidData("Component data size insufficient")
        }

        component.data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            let int32Ptr = baseAddress.assumingMemoryBound(to: Int32.self)
            for i in 0..<pixelCount {
                result[i] = int32Ptr[i]
            }
        }

        return result
    }

    /// Converts a J2KComponent to a Double array.
    private func convertToDoubleArray(_ component: J2KComponent) throws -> [Double] {
        let pixelCount = component.width * component.height
        var result = [Double](repeating: 0, count: pixelCount)

        // For now, assume data is stored as Int32 in native byte order
        // In a real implementation, this would handle various bit depths and formats
        guard component.data.count >= pixelCount * MemoryLayout<Int32>.size else {
            throw J2KError.invalidData("Component data size insufficient")
        }

        component.data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            let int32Ptr = baseAddress.assumingMemoryBound(to: Int32.self)
            for i in 0..<pixelCount {
                result[i] = Double(int32Ptr[i])
            }
        }

        return result
    }

    /// Creates a J2KComponent from an Int32 array.
    private func createComponent(
        from data: [Int32],
        template: J2KComponent,
        index: Int
    ) throws -> J2KComponent {
        var componentData = Data(count: data.count * MemoryLayout<Int32>.size)

        componentData.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            let int32Ptr = baseAddress.assumingMemoryBound(to: Int32.self)
            for i in 0..<data.count {
                int32Ptr[i] = data[i]
            }
        }

        return J2KComponent(
            index: index,
            bitDepth: template.bitDepth,
            signed: template.signed,
            width: template.width,
            height: template.height,
            subsamplingX: template.subsamplingX,
            subsamplingY: template.subsamplingY,
            data: componentData
        )
    }

    /// Creates a J2KComponent from a Double array.
    private func createComponentFromDouble(
        from data: [Double],
        template: J2KComponent,
        index: Int
    ) throws -> J2KComponent {
        var componentData = Data(count: data.count * MemoryLayout<Int32>.size)

        componentData.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            let int32Ptr = baseAddress.assumingMemoryBound(to: Int32.self)
            for i in 0..<data.count {
                // Round to nearest integer with saturation
                int32Ptr[i] = j2kClampedInt32(data[i])
            }
        }

        return J2KComponent(
            index: index,
            bitDepth: template.bitDepth,
            signed: template.signed,
            width: template.width,
            height: template.height,
            subsamplingX: template.subsamplingX,
            subsamplingY: template.subsamplingY,
            data: componentData
        )
    }
}

// MARK: - Equatable Conformance

extension J2KColorTransformConfiguration: Equatable {
    public static func == (lhs: J2KColorTransformConfiguration, rhs: J2KColorTransformConfiguration) -> Bool {
        lhs.mode == rhs.mode && lhs.validateReversibility == rhs.validateReversibility
    }
}
