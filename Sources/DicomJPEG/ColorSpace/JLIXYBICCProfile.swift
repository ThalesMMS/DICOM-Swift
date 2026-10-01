// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation
import CryptoKit

/// Generates the ICC profile that lets a *standard* (ICC-aware) decoder display
/// an XYB JPEG. Faithful port of libjxl v0.11.2 `MaybeCreateProfileImpl` for the
/// `XYB` color space (`lib/jxl/cms/jxl_cms_internal.h`): an `scnr`/XYZ profile
/// whose `A2B0` tag (`mAB`) maps the *scaled* XYB samples (as produced by
/// ``ColorConversion/rgbToXYBSample(r:g:b:)`` → `ScaleXYB`) to PCS D50, via
/// identity B-curves, a 2×2×2 CLUT, cube-root M-curves, and a 3×3 matrix.
///
/// The profile is constant (XYB is a fixed color space), so it's built once.
enum XYBICCProfile {

    /// The complete XYB ICC profile bytes. Embedded as APP2 in XYB JPEGs.
    static let data: [UInt8] = build()

    // MARK: Big-endian append writers (mirror libjxl's WriteICC*)

    private static func u32(_ v: UInt32, into a: inout [UInt8]) {
        a.append(UInt8((v >> 24) & 0xFF)); a.append(UInt8((v >> 16) & 0xFF))
        a.append(UInt8((v >> 8) & 0xFF)); a.append(UInt8(v & 0xFF))
    }
    private static func u16(_ v: UInt16, into a: inout [UInt8]) {
        a.append(UInt8((v >> 8) & 0xFF)); a.append(UInt8(v & 0xFF))
    }
    private static func tag(_ s: String, into a: inout [UInt8]) {
        a.append(contentsOf: Array(s.utf8.prefix(4)))
    }
    /// s15Fixed16: round(value · 65536) as int32, two's complement big-endian.
    private static func s15f16(_ v: Double, into a: inout [UInt8]) {
        u32(UInt32(bitPattern: Int32((v * 65536.0).rounded())), into: &a)
    }
    /// Overwrite a big-endian UInt32 at a fixed position (for back-patching).
    private static func patchU32(_ v: UInt32, at p: Int, in a: inout [UInt8]) {
        a[p] = UInt8((v >> 24) & 0xFF); a[p + 1] = UInt8((v >> 16) & 0xFF)
        a[p + 2] = UInt8((v >> 8) & 0xFF); a[p + 3] = UInt8(v & 0xFF)
    }

    // MARK: Tag bodies

    private static func mlucTag(_ text: String) -> [UInt8] {
        var a = [UInt8](); tag("mluc", into: &a); u32(0, into: &a)
        u32(1, into: &a); u32(12, into: &a); tag("enUS", into: &a)
        u32(UInt32(text.utf8.count * 2), into: &a); u32(28, into: &a)
        for c in text.utf8 { a.append(0); a.append(c) }    // ASCII → UTF-16BE
        return a
    }
    private static func xyzTag(_ xyz: [Double]) -> [UInt8] {
        var a = [UInt8](); tag("XYZ ", into: &a); u32(0, into: &a)
        for v in xyz { s15f16(v, into: &a) }
        return a
    }
    private static func chadTag(_ m: [Double]) -> [UInt8] {   // 9 row-major
        var a = [UInt8](); tag("sf32", into: &a); u32(0, into: &a)
        for v in m { s15f16(v, into: &a) }
        return a
    }
    /// 'para' curve: type, then params as s15Fixed16.
    private static func paraTag(_ params: [Double], type: UInt16, into a: inout [UInt8]) {
        tag("para", into: &a); u32(0, into: &a); u16(type, into: &a); u16(0, into: &a)
        for p in params { s15f16(p, into: &a) }
    }

    /// The XYB `A2B0` (`mAB `) tag — the heart of the profile.
    private static func xybA2BTag() -> [UInt8] {
        var a = [UInt8]()
        tag("mAB ", into: &a); u32(0, into: &a)
        a.append(3); a.append(3); u16(0, into: &a)   // 3→3 channels
        u32(32, into: &a)    // B curves
        u32(244, into: &a)   // matrix
        u32(148, into: &a)   // M curves
        u32(80, into: &a)    // CLUT
        u32(32, into: &a)    // A curves (reuse B)
        // offset 32: identity B (and A) curves
        for _ in 0..<3 { paraTag([1.0], type: 0, into: &a) }
        // offset 80: CLUT — 2 grid points on each of 3 input channels, 16-bit
        for i in 0..<16 { a.append(i < 3 ? 2 : 0) }
        a.append(2); a.append(0); u16(0, into: &a)   // precision 2, 3 pad bytes
        // 2×2×2×3 corners (libjxl UnscaledA2BCube), as uint16
        let cube: [[UInt16]] = [
            [0, 3206, 0], [0, 3206, 28873], [62329, 65535, 36662], [62329, 65535, 65535],
            [3206, 0, 0], [3206, 0, 28873], [65535, 62329, 36662], [65535, 62329, 65535],
        ]
        for corner in cube { for v in corner { u16(v, into: &a) } }
        // offset 148: M curves — cube-root (type-3 parametric), per channel
        let mCurves: [[Double]] = [
            [3.0, 0.8887947055965143, 0.14056806654924864, 0.0, 0.0],
            [3.0, 0.8887947055965143, 0.1278541115488854, 0.0, 0.0],
            [3.0, 1.5110248023800232, -0.12175038945075134, 0.0, 0.08057471277703825],
        ]
        for c in mCurves { paraTag(c, type: 3, into: &a) }
        // offset 244: 3×3 matrix + 3 offsets (libjxl constants)
        let matrix: [Double] = [
            1.5170095, -1.1065225, 0.071623, -0.050022, 0.5683655, -0.018344,
            -1.387676, 1.1145555, 0.6857255,
        ]
        for v in matrix { s15f16(v, into: &a) }
        for v in [-0.0018286785471008466, -0.0018965347311010966, -0.0015650409904929279] {
            s15f16(v, into: &a)
        }
        return a
    }

    /// No-op `B2A0` (`mBA `) tag — identity, required for a complete profile.
    private static func noOpB2ATag() -> [UInt8] {
        var a = [UInt8]()
        tag("mBA ", into: &a); u32(0, into: &a)
        a.append(3); a.append(3); u16(0, into: &a)
        u32(32, into: &a); u32(0, into: &a); u32(0, into: &a); u32(0, into: &a); u32(0, into: &a)
        for _ in 0..<3 { paraTag([1.0], type: 0, into: &a) }
        return a
    }

    // MARK: Assembly

    private static func build() -> [UInt8] {
        // --- header (128 bytes) ---
        var header = [UInt8](repeating: 0, count: 128)
        patchU32(0, at: 0, in: &header)                       // size (filled later)
        for (i, c) in "jxl ".utf8.enumerated() { header[4 + i] = c }
        patchU32(0x04400000, at: 8, in: &header)
        for (i, c) in "scnr".utf8.enumerated() { header[12 + i] = c }   // XYB → input/scanner class (libjxl)
        for (i, c) in "RGB ".utf8.enumerated() { header[16 + i] = c }
        for (i, c) in "XYZ ".utf8.enumerated() { header[20 + i] = c }
        // date/time placeholder (2019-12-01) — matches libjxl
        header[24] = 0x07; header[25] = 0xE3; header[26] = 0x00; header[27] = 0x0C
        header[28] = 0x00; header[29] = 0x01
        for (i, c) in "acsp".utf8.enumerated() { header[36 + i] = c }
        for (i, c) in "APPL".utf8.enumerated() { header[40 + i] = c }
        patchU32(0, at: 64, in: &header)                      // rendering intent = perceptual
        patchU32(0x0000f6d6, at: 68, in: &header)             // PCS D50 white
        patchU32(0x00010000, at: 72, in: &header)
        patchU32(0x0000d32d, at: 76, in: &header)
        for (i, c) in "jxl ".utf8.enumerated() { header[80 + i] = c }

        // --- tags (appended) with offset/size tracking ---
        var tags = [UInt8]()
        var offsets = [Int]()          // each tag's start within `tags`
        var sizes = [Int]()
        var names = [String]()
        var tagOffset = 0, tagSize = 0
        func add(_ name: String, _ body: [UInt8]) {
            tags.append(contentsOf: body)
            while tags.count % 4 != 0 { tags.append(0) }      // FinalizeICCTag pad
            tagOffset += tagSize
            tagSize = tags.count - tagOffset
            offsets.append(tagOffset); sizes.append(tagSize); names.append(name)
        }
        add("desc", mlucTag("JLISwift XYB"))
        add("cprt", mlucTag("CC0"))
        add("wtpt", xyzTag([0.964203, 1.0, 0.824905]))         // PCS D50
        add("chad", chadTag([
            1.0478572906, 0.0229074518, -0.0501622841,
            0.0295704931, 0.9904754999, -0.0170614922,
            -0.0092404545, 0.0150529681, 0.7519708445,
        ]))
        add("A2B0", xybA2BTag())
        add("B2A0", noOpB2ATag())

        // --- tag table ---
        var tagtable = [UInt8]()
        u32(UInt32(names.count), into: &tagtable)
        let tableSize = 4 + 12 * names.count
        for i in 0..<names.count {
            tag(names[i], into: &tagtable)
            u32(UInt32(128 + tableSize + offsets[i]), into: &tagtable)   // absolute offset
            u32(UInt32(sizes[i]), into: &tagtable)
        }

        // --- assemble + back-patch size + MD5 profile id ---
        var icc = header + tagtable + tags
        patchU32(UInt32(icc.count), at: 0, in: &icc)
        var forSum = icc
        for p in 44..<48 { forSum[p] = 0 }      // flags
        for p in 64..<68 { forSum[p] = 0 }      // rendering intent
        for p in 84..<100 { forSum[p] = 0 }     // profile id region
        let digest = Insecure.MD5.hash(data: Data(forSum))
        for (i, byte) in digest.enumerated() { icc[84 + i] = byte }
        return icc
    }
}
