// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation

/// Color space conversion utilities for JPEG encoding and decoding.
///
/// Uses floating-point precision throughout the pipeline, converting to integers
/// only at the final stage — matching the jpegli approach.
enum ColorConversion {

    // MARK: - RGB ↔ YCbCr (BT.601)

    /// Converts an RGB pixel to YCbCr.
    ///
    /// Uses BT.601 coefficients as specified by JFIF/JPEG:
    /// ```
    /// Y  =  0.299 * R + 0.587 * G + 0.114 * B
    /// Cb = -0.168736 * R - 0.331264 * G + 0.5 * B + 128
    /// Cr =  0.5 * R - 0.418688 * G - 0.081312 * B + 128
    /// ```
    @inlinable
    static func rgbToYCbCr(r: Float, g: Float, b: Float) -> (y: Float, cb: Float, cr: Float) {
        let y  =  0.299 * r + 0.587 * g + 0.114 * b
        let cb = -0.168736 * r - 0.331264 * g + 0.5 * b + 128.0
        let cr =  0.5 * r - 0.418688 * g - 0.081312 * b + 128.0
        return (y, cb, cr)
    }

    /// Converts a YCbCr pixel to RGB.
    @inlinable
    static func ycbcrToRGB(y: Float, cb: Float, cr: Float) -> (r: Float, g: Float, b: Float) {
        let cbShifted = cb - 128.0
        let crShifted = cr - 128.0
        let r = y + 1.402 * crShifted
        let g = y - 0.344136 * cbShifted - 0.714136 * crShifted
        let b = y + 1.772 * cbShifted
        return (r, g, b)
    }

    /// Converts an entire image from RGB to YCbCr component planes.
    /// Delegates to ``AccelerateDSP/imageRGBToYCbCr(data:pixelCount:componentCount:)``.
    static func imageRGBToYCbCr(data: [UInt8], width: Int, height: Int,
                                 componentCount: Int) -> (y: [Float], cb: [Float], cr: [Float]) {
        return AccelerateDSP.imageRGBToYCbCr(
            data: data, pixelCount: width * height, componentCount: componentCount
        )
    }

    /// Converts YCbCr component planes back to interleaved RGB bytes.
    /// Delegates to ``AccelerateDSP/imageYCbCrToRGB(y:cb:cr:pixelCount:)``.
    static func imageYCbCrToRGB(y: [Float], cb: [Float], cr: [Float],
                                 width: Int, height: Int) -> [UInt8] {
        return AccelerateDSP.imageYCbCrToRGB(
            y: y, cb: cb, cr: cr, pixelCount: width * height
        )
    }

    /// 12-bit color: converts interleaved little-endian UInt16 RGB(A) to Y/Cb/Cr
    /// planes, with chroma centered at `center` (2^(P-1)).
    static func imageRGB16ToYCbCr(data: [UInt8], width: Int, height: Int,
                                  componentCount: Int, center: Float)
        -> (y: [Float], cb: [Float], cr: [Float]) {
        return AccelerateDSP.imageRGB16ToYCbCr(
            data: data, pixelCount: width * height, componentCount: componentCount, center: center
        )
    }

    /// 12-bit color: converts Y/Cb/Cr planes back to interleaved little-endian
    /// UInt16 RGB, de-centering chroma at `center` and clamping to `0...maxValue`.
    static func imageYCbCr16ToRGB(y: [Float], cb: [Float], cr: [Float],
                                  width: Int, height: Int, center: Float, maxValue: Float) -> [UInt8] {
        return AccelerateDSP.imageYCbCr16ToRGB(
            y: y, cb: cb, cr: cr, pixelCount: width * height, center: center, maxValue: maxValue
        )
    }

    /// Converts a grayscale image buffer to a luminance plane.
    static func imageGrayscaleToY(data: [UInt8], width: Int, height: Int) -> [Float] {
        return data.map { Float($0) }
    }

    /// Converts a luminance plane back to grayscale bytes.
    static func imageYToGrayscale(y: [Float], width: Int, height: Int) -> [UInt8] {
        return y.map { UInt8(clamping: Int($0.rounded())) }
    }

    // MARK: - RGB ↔ XYB (JPEG XL Perceptual Color Space)
    //
    // Faithful port of libjxl v0.11.2 (`lib/jxl/enc_xyb.cc` +
    // `lib/jxl/cms/opsin_params.h`, BSD/Apache-compatible). The pipeline is:
    //   sRGB byte → [0,1] → linear (sRGB EOTF) → opsin absorbance (matrix + bias)
    //   → cube-root − cbrt(bias) → XYB rotation (X=½(L−M), Y=½(L+M), B=S)
    //   → ScaleXYB (per-channel scale/offset, B carries B−Y) → ×255 sample.
    // For the standard SDR sRGB case jpegli uses intensity_target = 255, i.e.
    // opsin `mul = 1`, so the absorbance matrix is used unscaled.

    /// Opsin absorbance matrix (linear RGB → LMS-ish mixed signal), rows sum to 1.
    private static let opsinM: [[Float]] = [
        [0.30, 0.622, 0.078],
        [0.23, 0.692, 0.078],
        [0.24342268924547819, 0.20476744424496821, 0.5518098665095536],
    ]
    /// Inverse of `opsinM` (libjxl `kDefaultInverseOpsinAbsorbanceMatrix`).
    private static let opsinInvM: [[Float]] = [
        [11.031566901960783, -9.866943921568629, -0.16462299647058826],
        [-3.254147380392157, 4.418770392156863, -0.16462299647058826],
        [-3.6588512862745097, 2.7129230470588235, 1.9459282392156863],
    ]
    private static let opsinBias: Float = 0.0037930732552754493
    private static let opsinBiasCbrt: Float = cbrt(0.0037930732552754493)
    /// `kScaledXYBOffset` / `kScaledXYBScale` — map XYB to the [0,1] sample range.
    private static let xybOffset: [Float] = [0.015386134, 0.0, 0.27770459]
    private static let xybScale: [Float] = [22.995788804, 1.183000077, 1.502141333]

    /// sRGB encoded [0,1] → linear [0,1] (IEC 61966-2-1 EOTF).
    @inline(__always) static func srgbToLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    /// linear [0,1] → sRGB encoded [0,1] (OETF).
    @inline(__always) static func linearToSRGB(_ c: Float) -> Float {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055
    }

    /// Converts an sRGB pixel (0–255) to its three scaled-XYB samples (0–255,
    /// unclamped). These are the values the encoder level-shifts and DCT-codes.
    static func rgbToXYBSample(r: Float, g: Float, b: Float) -> (x: Float, y: Float, bOut: Float) {
        let rl = srgbToLinear(r / 255.0), gl = srgbToLinear(g / 255.0), bl = srgbToLinear(b / 255.0)
        let m0 = max(0, opsinM[0][0] * rl + opsinM[0][1] * gl + opsinM[0][2] * bl + opsinBias)
        let m1 = max(0, opsinM[1][0] * rl + opsinM[1][1] * gl + opsinM[1][2] * bl + opsinBias)
        let m2 = max(0, opsinM[2][0] * rl + opsinM[2][1] * gl + opsinM[2][2] * bl + opsinBias)
        let lc = cbrt(m0) - opsinBiasCbrt
        let mc = cbrt(m1) - opsinBiasCbrt
        let sc = cbrt(m2) - opsinBiasCbrt
        let capX = 0.5 * (lc - mc)
        let capY = 0.5 * (lc + mc)
        let capB = sc
        let sX = (capX + xybOffset[0]) * xybScale[0]
        let sY = (capY + xybOffset[1]) * xybScale[1]
        let sB = (capB - capY + xybOffset[2]) * xybScale[2]   // B sample carries B−Y
        return (sX * 255.0, sY * 255.0, sB * 255.0)
    }

    /// Inverts ``rgbToXYBSample`` — scaled-XYB samples (0–255) back to sRGB (0–255).
    static func xybSampleToRGB(x sX: Float, y sY: Float, bChannel sB: Float) -> (r: Float, g: Float, b: Float) {
        let capX = (sX / 255.0) / xybScale[0] - xybOffset[0]
        let capY = (sY / 255.0) / xybScale[1] - xybOffset[1]
        let capB = (sB / 255.0) / xybScale[2] - xybOffset[2] + capY
        let lc = capY + capX, mc = capY - capX, sc = capB
        let e0 = lc + opsinBiasCbrt, e1 = mc + opsinBiasCbrt, e2 = sc + opsinBiasCbrt
        let m0 = e0 * e0 * e0 - opsinBias       // undo cube-root, then subtract bias
        let m1 = e1 * e1 * e1 - opsinBias
        let m2 = e2 * e2 * e2 - opsinBias
        let rl = opsinInvM[0][0] * m0 + opsinInvM[0][1] * m1 + opsinInvM[0][2] * m2
        let gl = opsinInvM[1][0] * m0 + opsinInvM[1][1] * m1 + opsinInvM[1][2] * m2
        let bl = opsinInvM[2][0] * m0 + opsinInvM[2][1] * m1 + opsinInvM[2][2] * m2
        return (
            max(0, min(255, linearToSRGB(rl) * 255.0)),
            max(0, min(255, linearToSRGB(gl) * 255.0)),
            max(0, min(255, linearToSRGB(bl) * 255.0))
        )
    }
}
