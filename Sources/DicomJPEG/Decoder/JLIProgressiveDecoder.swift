// SPDX-License-Identifier: Apache-2.0 AND IJG
// Copyright 2024 Raster Lab. All rights reserved.
// Portions based on the Independent JPEG Group progressive entropy routines.
// Copyright (C) 1995-1997, Thomas G. Lane.
// Swift adaptation and subsequent Isis modifications are recorded in Git.
// See ThirdPartyLicenses/libjpeg/README.ijg and the retained source notices.

/// Decodes progressive (SOF2) JPEG into per-component coefficient buffers.
///
/// Progressive JPEG codes the DCT coefficients across multiple scans:
/// - **DC scans** are interleaved (all components, MCU order); the first pass
///   (Ah=0) DPCM-codes the DC value shifted left by Al, refinement passes
///   (Ah>0) send one more bit per block.
/// - **AC scans** are non-interleaved (one component, block raster order) and
///   cover a spectral band [Ss, Se]; the first pass run-length-codes the band
///   with end-of-band runs (EOBRUN), refinement passes (Ah>0) send correction
///   bits for existing coefficients plus newly-significant ones.
///
/// This is a faithful port of libjpeg's `jdphuff.c` routines. Coefficients are
/// stored in **zigzag** order (so the natural-order indirection libjpeg needs
/// is unnecessary — Ss/Se and `k` are zigzag indices directly). The caller
/// inverse-zigzags, dequantizes, and runs the IDCT on the result.
struct ProgressiveDecoder {
    let components: [JPEGComponentInfo]
    let mcuCountH: Int
    let mcuCountV: Int
    /// Per component: MCU-padded blocks per row/col. This is the coefficient
    /// storage stride and the grid interleaved (DC) scans address.
    let blocksPerRow: [Int]
    let blocksPerCol: [Int]
    /// Per component: the component's own data-unit grid, ceil(compW/8) ×
    /// ceil(compH/8). Non-interleaved (AC) scans address *this* grid, which is
    /// smaller than the MCU-padded grid when the image isn't a whole number of
    /// MCUs — the padded edge blocks exist only to complete interleaved MCUs and
    /// carry no AC data.
    let realBlocksW: [Int]
    let realBlocksH: [Int]
    let restartInterval: Int

    /// Per-component flat coefficient buffers, zigzag order, block `b` at `b*64`.
    var coeffs: [[Int32]]

    init(
        components: [JPEGComponentInfo],
        mcuCountH: Int, mcuCountV: Int,
        blocksPerRow: [Int], blocksPerCol: [Int],
        realBlocksW: [Int], realBlocksH: [Int],
        restartInterval: Int
    ) {
        self.components = components
        self.mcuCountH = mcuCountH
        self.mcuCountV = mcuCountV
        self.blocksPerRow = blocksPerRow
        self.blocksPerCol = blocksPerCol
        self.realBlocksW = realBlocksW
        self.realBlocksH = realBlocksH
        self.restartInterval = restartInterval
        self.coeffs = (0..<components.count).map { c in
            [Int32](repeating: 0, count: blocksPerRow[c] * blocksPerCol[c] * 64)
        }
    }

    mutating func decode(scans: [JPEGScanData]) throws {
        for scan in scans {
            try decodeScan(scan)
        }
    }

    private func componentIndex(forSelector id: UInt8) -> Int? {
        components.firstIndex { $0.id == id }
    }

    /// Signed value from `s` magnitude bits (JPEG EXTEND).
    private func receiveExtend(_ reader: inout BitReader, _ s: Int) throws -> Int32 {
        if s == 0 { return 0 }
        let bits = try reader.readBits(s)
        if bits < (1 << (s - 1)) {
            return Int32(bits) - Int32((1 << s) - 1)
        }
        return Int32(bits)
    }

    private mutating func decodeScan(_ scan: JPEGScanData) throws {
        let h = scan.header
        var reader = BitReader(data: scan.entropyData)
        if h.spectralStart == 0 {
            if h.successiveApproxHigh == 0 {
                try decodeDCFirst(&reader, scan: scan, al: h.successiveApproxLow)
            } else {
                try decodeDCRefine(&reader, scan: scan, al: h.successiveApproxLow)
            }
        } else {
            guard let sel = h.components.first,
                  let c = componentIndex(forSelector: sel.componentSelector) else {
                throw JLIError.decodingFailed("Progressive AC scan missing component")
            }
            guard let acTable = scan.acTables[sel.acTableId] else {
                throw JLIError.decodingFailed("Progressive AC scan missing Huffman table")
            }
            if h.successiveApproxHigh == 0 {
                try decodeACFirst(&reader, comp: c, table: acTable,
                                  ss: h.spectralStart, se: h.spectralEnd, al: h.successiveApproxLow)
            } else {
                try decodeACRefine(&reader, comp: c, table: acTable,
                                   ss: h.spectralStart, se: h.spectralEnd, al: h.successiveApproxLow)
            }
        }
    }

    // MARK: - DC scans (interleaved, MCU order)

    private mutating func decodeDCFirst(
        _ reader: inout BitReader, scan: JPEGScanData, al: Int
    ) throws {
        var pred = [Int32](repeating: 0, count: components.count)
        var mcu = 0
        var rstIndex = 0
        for mcuY in 0..<mcuCountV {
            for mcuX in 0..<mcuCountH {
                if restartInterval > 0 && mcu > 0 && mcu % restartInterval == 0 {
                    try reader.skipRestartMarker(expectedIndex: rstIndex)
                    rstIndex = (rstIndex + 1) & 7
                    for i in pred.indices { pred[i] = 0 }
                }
                mcu += 1
                for c in 0..<components.count {
                    let comp = components[c]
                    guard let sel = scan.header.components.first(where: { $0.componentSelector == comp.id }),
                          let dcTable = scan.dcTables[sel.dcTableId] else {
                        throw JLIError.decodingFailed("Progressive DC scan missing Huffman table")
                    }
                    for by in 0..<comp.verticalSampling {
                        for bx in 0..<comp.horizontalSampling {
                            let blockX = mcuX * comp.horizontalSampling + bx
                            let blockY = mcuY * comp.verticalSampling + by
                            let bidx = blockY * blocksPerRow[c] + blockX
                            let s = Int(try HuffmanDecoder.decodeSymbol(from: &reader, table: dcTable))
                            pred[c] += try receiveExtend(&reader, s)
                            coeffs[c][bidx * 64] = pred[c] << al
                        }
                    }
                }
            }
        }
    }

    private mutating func decodeDCRefine(
        _ reader: inout BitReader, scan: JPEGScanData, al: Int
    ) throws {
        let p1: Int32 = 1 << al
        var mcu = 0
        var rstIndex = 0
        for mcuY in 0..<mcuCountV {
            for mcuX in 0..<mcuCountH {
                if restartInterval > 0 && mcu > 0 && mcu % restartInterval == 0 {
                    try reader.skipRestartMarker(expectedIndex: rstIndex)
                    rstIndex = (rstIndex + 1) & 7
                }
                mcu += 1
                for c in 0..<components.count {
                    let comp = components[c]
                    for by in 0..<comp.verticalSampling {
                        for bx in 0..<comp.horizontalSampling {
                            let blockX = mcuX * comp.horizontalSampling + bx
                            let blockY = mcuY * comp.verticalSampling + by
                            let bidx = blockY * blocksPerRow[c] + blockX
                            if try reader.readBit() == 1 {
                                coeffs[c][bidx * 64] |= p1
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - AC scans (non-interleaved, single component, block raster order)

    private mutating func decodeACFirst(
        _ reader: inout BitReader, comp c: Int, table: HuffmanTable,
        ss: Int, se: Int, al: Int
    ) throws {
        // Steal the component buffer for the pass (leaving a placeholder) so
        // per-coefficient access is a direct subscript on a uniquely-referenced
        // local — no outer-array traffic or COW uniqueness checks per touch.
        var comp = coeffs[c]
        coeffs[c] = []
        defer { coeffs[c] = comp }
        var eobrun = 0
        var unit = 0
        var rstIndex = 0
        let stride = blocksPerRow[c]
        for blockY in 0..<realBlocksH[c] {
            for blockX in 0..<realBlocksW[c] {
                if restartInterval > 0 && unit > 0 && unit % restartInterval == 0 {
                    try reader.skipRestartMarker(expectedIndex: rstIndex)
                    rstIndex = (rstIndex + 1) & 7
                    eobrun = 0
                }
                unit += 1
                let bidx = blockY * stride + blockX
                if eobrun > 0 { eobrun -= 1; continue }

                var k = ss
                while k <= se {
                    let rs = Int(try HuffmanDecoder.decodeSymbol(from: &reader, table: table))
                    let r = rs >> 4
                    let s = rs & 15
                    if s == 0 {
                        if r != 15 {
                            eobrun = (1 << r) - 1
                            if r > 0 { eobrun += Int(try reader.readBits(r)) }
                            break
                        }
                        k += 16  // ZRL: 16 zeros
                    } else {
                        k += r
                        if k > se { break }
                        comp[bidx * 64 + k] = try receiveExtend(&reader, s) << al
                        k += 1
                    }
                }
            }
        }
    }

    /// AC refinement — the subtle one (port of libjpeg `decode_mcu_AC_refine`).
    /// `p1 = 1<<Al`, `m1 = (−1)<<Al`. A correction bit of 1 nudges a nonzero
    /// coefficient's magnitude up by one step at bit position Al.
    private mutating func decodeACRefine(
        _ reader: inout BitReader, comp c: Int, table: HuffmanTable,
        ss: Int, se: Int, al: Int
    ) throws {
        // Steal the component buffer for the pass (leaving a placeholder) so
        // per-coefficient access is a direct subscript on a uniquely-referenced
        // local — no outer-array traffic or COW uniqueness checks per touch.
        var comp = coeffs[c]
        coeffs[c] = []
        defer { coeffs[c] = comp }
        let p1: Int32 = 1 << al
        let m1: Int32 = (-1) << al
        var eobrun = 0
        var unit = 0
        var rstIndex = 0
        let stride = blocksPerRow[c]

        for blockY in 0..<realBlocksH[c] {
            for blockX in 0..<realBlocksW[c] {
                if restartInterval > 0 && unit > 0 && unit % restartInterval == 0 {
                    try reader.skipRestartMarker(expectedIndex: rstIndex)
                    rstIndex = (rstIndex + 1) & 7
                    eobrun = 0
                }
                unit += 1
                let blockBase = (blockY * stride + blockX) * 64

                var k = ss
                if eobrun == 0 {
                    while k <= se {
                        let rs = Int(try HuffmanDecoder.decodeSymbol(from: &reader, table: table))
                        var r = rs >> 4
                        let s = rs & 15
                        var newVal: Int32 = 0
                        if s != 0 {
                            // s is always 1 in a refinement scan; the bit is the sign.
                            newVal = try reader.readBit() == 1 ? p1 : m1
                        } else {
                            if r != 15 {
                                eobrun = 1 << r
                                if r > 0 { eobrun += Int(try reader.readBits(r)) }
                                break
                            }
                            // r == 15: ZRL — advance over 16 zero-history coefficients.
                        }
                        // Advance over r still-zero coefficients, applying correction
                        // bits to nonzeros encountered along the way.
                        while k <= se {
                            let idx = blockBase + k
                            if comp[idx] != 0 {
                                if try reader.readBit() == 1 && (comp[idx] & p1) == 0 {
                                    comp[idx] += comp[idx] >= 0 ? p1 : m1
                                }
                            } else {
                                if r == 0 { break }
                                r -= 1
                            }
                            k += 1
                        }
                        if s != 0 && k <= se {
                            comp[blockBase + k] = newVal  // place newly-nonzero coef
                        }
                        k += 1
                    }
                }
                if eobrun > 0 {
                    // Apply correction bits to all remaining nonzeros in the band.
                    while k <= se {
                        let idx = blockBase + k
                        if comp[idx] != 0 {
                            if try reader.readBit() == 1 && (comp[idx] & p1) == 0 {
                                comp[idx] += comp[idx] >= 0 ? p1 : m1
                            }
                        }
                        k += 1
                    }
                    eobrun -= 1
                }
            }
        }
    }
}
