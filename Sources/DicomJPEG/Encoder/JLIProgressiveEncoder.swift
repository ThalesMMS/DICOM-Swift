// SPDX-License-Identifier: Apache-2.0 AND IJG
// Copyright 2024 Raster Lab. All rights reserved.
// Portions based on the Independent JPEG Group progressive entropy routines.
// Copyright (C) 1995-1997, Thomas G. Lane.
// Swift adaptation and subsequent Isis modifications are recorded in Git.
// See ThirdPartyLicenses/libjpeg/README.ijg and the retained source notices.

/// Encodes per-component quantized coefficients (natural order) into progressive
/// (SOF2) scans — the inverse of ``ProgressiveDecoder``. Faithful port of
/// libjpeg `jcphuff.c`. Two scan scripts are supported (see ``JLIProgressiveMode``):
///
/// **Spectral selection** (default, `jpeg_simple_progression` would call this
/// "no successive approximation") — one DC scan, then one full-band AC scan per
/// component (Ss=1 Se=63, Ah=Al=0) with end-of-band runs. A run of AC-empty
/// blocks collapses to one EOBn symbol, which is why flat / medical content
/// compresses best here.
///
/// **Successive approximation** — libjpeg's canonical YCbCr script (10 scans) /
/// all-purpose script (6 scans for grayscale): band-split luma, Al=2 luma /
/// Al=1 chroma in the first passes, refined down to Al=0. Smaller on textured
/// content, larger on flat content (extra scans fragment EOB runs).
///
/// Each Huffman-coded scan carries its own optimal DHT, built from a counting
/// pass over the exact walk its emit pass uses. DC refine emits raw bits only.
/// DC successive approximation uses an arithmetic (sign-extending) shift; AC
/// uses a magnitude-preserving point transform with a separate sign bit.
struct ProgressiveEncoder {
    let components: [JPEGComponentInfo]
    let isGrayscale: Bool
    let mcuCountH: Int
    let mcuCountV: Int
    let blocksPerRow: [Int]      // MCU-padded stride / interleaved DC grid
    let realBlocksW: [Int]       // component data-unit grid (non-interleaved AC)
    let realBlocksH: [Int]
    let quant: [[Int32]]         // natural order, block b at b*64
    /// Emit a restart marker every `restartInterval` MCUs (interleaved MCUs in the
    /// DC scan, data units in the non-interleaved AC scans). 0 disables restart.
    var restartInterval: Int = 0

    private let zz = Quantization.zigzagOrder
    private func tableId(_ c: Int) -> Int { c == 0 ? 0 : 1 }

    struct ScanPlan {
        let dht: [(tableClass: Int, tableId: Int, bits: [UInt8], values: [UInt8])]
        let sosComponents: [(selector: UInt8, dcTableId: Int, acTableId: Int)]
        let ss: Int, se: Int, ah: Int, al: Int
        let entropy: [UInt8]
    }

    /// Magnitude-preserving point transform for AC: |coef| >> al, sign kept.
    private func pt(_ c: Int32, _ al: Int) -> Int32 {
        if c >= 0 { return c >> al }
        return -((-c) >> al)
    }

    func build(mode: JLIProgressiveMode) -> [ScanPlan] {
        switch mode {
        case .spectralSelection: return buildSpectralSelection()
        case .successiveApproximation: return buildSuccessiveApproximation()
        }
    }

    /// One DC scan + one full-band AC scan per component, no successive
    /// approximation (Ah=Al=0 everywhere). The full-precision coefficients are
    /// sent once; EOBRUN over AC-empty blocks is the compression lever.
    private func buildSpectralSelection() -> [ScanPlan] {
        var scans = [ScanPlan]()
        scans.append(makeDCScan(ah: 0, al: 0))
        for c in 0..<components.count {
            scans.append(makeACScan(c: c, ss: 1, se: 63, ah: 0, al: 0))
        }
        return scans
    }

    /// libjpeg `jpeg_simple_progression`: 10-scan YCbCr / 6-scan grayscale,
    /// band-split luma with multi-level successive approximation.
    private func buildSuccessiveApproximation() -> [ScanPlan] {
        var scans = [ScanPlan]()
        if isGrayscale {
            scans.append(makeDCScan(ah: 0, al: 1))
            scans.append(makeACScan(c: 0, ss: 1, se: 5, ah: 0, al: 2))
            scans.append(makeACScan(c: 0, ss: 6, se: 63, ah: 0, al: 2))
            scans.append(makeACScan(c: 0, ss: 1, se: 63, ah: 2, al: 1))
            scans.append(makeDCScan(ah: 1, al: 0))
            scans.append(makeACScan(c: 0, ss: 1, se: 63, ah: 1, al: 0))
        } else {
            scans.append(makeDCScan(ah: 0, al: 1))
            scans.append(makeACScan(c: 0, ss: 1, se: 5, ah: 0, al: 2))
            scans.append(makeACScan(c: 2, ss: 1, se: 63, ah: 0, al: 1))
            scans.append(makeACScan(c: 1, ss: 1, se: 63, ah: 0, al: 1))
            scans.append(makeACScan(c: 0, ss: 6, se: 63, ah: 0, al: 2))
            scans.append(makeACScan(c: 0, ss: 1, se: 63, ah: 2, al: 1))
            scans.append(makeDCScan(ah: 1, al: 0))
            scans.append(makeACScan(c: 2, ss: 1, se: 63, ah: 1, al: 0))
            scans.append(makeACScan(c: 1, ss: 1, se: 63, ah: 1, al: 0))
            scans.append(makeACScan(c: 0, ss: 1, se: 63, ah: 1, al: 0))
        }
        return scans
    }

    // MARK: - DC scan (interleaved across all components)

    private func makeDCScan(ah: Int, al: Int) -> ScanPlan {
        var sos = [(selector: UInt8, dcTableId: Int, acTableId: Int)]()
        for c in 0..<components.count { sos.append((components[c].id, tableId(c), 0)) }

        if ah == 0 {
            // First pass: DPCM-coded magnitudes, optimal Huffman per table.
            var dcLumF = [Int](repeating: 0, count: 256)
            var dcChrF = [Int](repeating: 0, count: 256)
            dcFirstPass(al: al, onSymbol: { c, sym in
                if c == 0 { dcLumF[sym] += 1 } else { dcChrF[sym] += 1 }
            }, onBits: { _, _ in })
            let dcLum = HuffmanTableBuilder.build(frequencies: dcLumF, fallback: StandardHuffmanTables.dcLuminance)
            let dcChr = isGrayscale ? dcLum
                : HuffmanTableBuilder.build(frequencies: dcChrF, fallback: StandardHuffmanTables.dcChrominance)
            var dht: [(tableClass: Int, tableId: Int, bits: [UInt8], values: [UInt8])] =
                [(0, 0, dcLum.bits, dcLum.values)]
            if !isGrayscale { dht.append((0, 1, dcChr.bits, dcChr.values)) }

            var w = BitWriter(estimatedMaxSize: mcuCountH * mcuCountV * 8 + 1024)
            var rstIndex = 0
            dcFirstPass(al: al, onSymbol: { c, sym in
                let t = c == 0 ? dcLum : dcChr
                let e = t.encodingTable[sym]
                w.writeBits(UInt32(e.code), count: Int(e.length))
            }, onBits: { bits, n in w.writeBits(bits, count: n) },
               onRestart: { w.emitRestartMarker(rstIndex); rstIndex = (rstIndex + 1) & 7 })
            w.flush()
            return ScanPlan(dht: dht, sosComponents: sos, ss: 0, se: 0, ah: 0, al: al, entropy: w.data)
        }

        // Refine pass: one raw bit (bit `al`) per block, no Huffman.
        var w = BitWriter(estimatedMaxSize: mcuCountH * mcuCountV + 1024)
        var mcu = 0
        var rstIndex = 0
        for mcuY in 0..<mcuCountV {
            for mcuX in 0..<mcuCountH {
                if restartInterval > 0 && mcu > 0 && mcu % restartInterval == 0 {
                    w.emitRestartMarker(rstIndex); rstIndex = (rstIndex + 1) & 7
                }
                mcu += 1
                for c in 0..<components.count {
                    let comp = components[c]
                    for by in 0..<comp.verticalSampling {
                        for bx in 0..<comp.horizontalSampling {
                            let bidx = (mcuY * comp.verticalSampling + by) * blocksPerRow[c]
                                + (mcuX * comp.horizontalSampling + bx)
                            let bit = UInt32((quant[c][bidx * 64] >> al) & 1)
                            w.writeBits(bit, count: 1)
                        }
                    }
                }
            }
        }
        w.flush()
        return ScanPlan(dht: [], sosComponents: sos, ss: 0, se: 0, ah: ah, al: al, entropy: w.data)
    }

    /// Drives the interleaved DC-first walk. DC successive approximation uses an
    /// arithmetic (sign-extending) shift — the decoder reconstructs DC as
    /// `(accumulatedDiff << Al) | refineBit`, which only round-trips negatives
    /// under arithmetic shift (unlike AC's magnitude-preserving transform).
    private func dcFirstPass(
        al: Int, onSymbol: (Int, Int) -> Void, onBits: (UInt32, Int) -> Void,
        onRestart: () -> Void = {}
    ) {
        var pred = [Int32](repeating: 0, count: components.count)
        var mcu = 0
        for mcuY in 0..<mcuCountV {
            for mcuX in 0..<mcuCountH {
                if restartInterval > 0 && mcu > 0 && mcu % restartInterval == 0 {
                    for i in pred.indices { pred[i] = 0 }   // reset DC predictors at the boundary
                    onRestart()                              // (emit pass) flush + RSTn
                }
                mcu += 1
                for c in 0..<components.count {
                    let comp = components[c]
                    for by in 0..<comp.verticalSampling {
                        for bx in 0..<comp.horizontalSampling {
                            let bidx = (mcuY * comp.verticalSampling + by) * blocksPerRow[c]
                                + (mcuX * comp.horizontalSampling + bx)
                            let dc = quant[c][bidx * 64] >> al
                            let diff = dc - pred[c]
                            pred[c] = dc
                            let cat = HuffmanEncoder.category(for: diff)
                            onSymbol(c, cat)
                            if cat > 0 { onBits(HuffmanEncoder.additionalBits(for: diff, category: cat), cat) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - AC scan (single component, band [ss, se])

    private func makeACScan(c: Int, ss: Int, se: Int, ah: Int, al: Int) -> ScanPlan {
        let fallback = c == 0 ? StandardHuffmanTables.acLuminance : StandardHuffmanTables.acChrominance
        var f = [Int](repeating: 0, count: 256)
        if ah == 0 {
            acFirstPass(component: c, ss: ss, se: se, al: al, onSymbol: { f[$0] += 1 }, onBits: { _, _ in })
        } else {
            acRefinePass(component: c, ss: ss, se: se, al: al, onSymbol: { f[$0] += 1 }, onBit: { _ in })
        }
        let table = HuffmanTableBuilder.build(frequencies: f, fallback: fallback)
        let entropy = ah == 0
            ? emitACFirst(component: c, ss: ss, se: se, al: al, table: table)
            : emitACRefine(component: c, ss: ss, se: se, al: al, table: table)
        return ScanPlan(
            dht: [(1, tableId(c), table.bits, table.values)],
            sosComponents: [(components[c].id, 0, tableId(c))],
            ss: ss, se: se, ah: ah, al: al, entropy: entropy
        )
    }

    private func eobnSymbol(_ eobrun: Int) -> Int {
        var nbits = 0; var t = eobrun >> 1
        while t != 0 { nbits += 1; t >>= 1 }
        return nbits << 4
    }

    /// MSB-first bit positions for an n-bit value: [n-1, n-2, ..., 0].
    private func msbFirst(_ n: Int) -> StrideThrough<Int> { stride(from: n - 1, through: 0, by: -1) }

    // MARK: - AC first (band [ss, se], EOBRUN)

    private func acFirstPass(
        component c: Int, ss: Int, se: Int, al: Int,
        onSymbol: (Int) -> Void, onBits: (UInt32, Int) -> Void,
        onRestart: () -> Void = {}
    ) {
        let stride = blocksPerRow[c]
        var eobrun = 0
        var unit = 0
        func flushEOB() {
            guard eobrun > 0 else { return }
            let sym = eobnSymbol(eobrun); onSymbol(sym)
            let nbits = sym >> 4
            if nbits > 0 { onBits(UInt32(eobrun & ((1 << nbits) - 1)), nbits) }
            eobrun = 0
        }
        for blockY in 0..<realBlocksH[c] {
            for blockX in 0..<realBlocksW[c] {
                if restartInterval > 0 && unit > 0 && unit % restartInterval == 0 {
                    flushEOB()        // EOB run cannot span a restart boundary
                    onRestart()       // (emit pass) flush + RSTn
                }
                unit += 1
                let base = (blockY * stride + blockX) * 64
                var run = 0
                for k in ss...se {
                    let coef = pt(quant[c][base + zz[k]], al)
                    if coef == 0 { run += 1; continue }
                    flushEOB()
                    while run > 15 { onSymbol(0xF0); run -= 16 }
                    let size = HuffmanEncoder.category(for: coef)
                    onSymbol((run << 4) | size)
                    onBits(HuffmanEncoder.additionalBits(for: coef, category: size), size)
                    run = 0
                }
                if run > 0 {
                    eobrun += 1
                    if eobrun == 0x7FFF { flushEOB() }
                }
            }
        }
        flushEOB()
    }

    private func emitACFirst(component c: Int, ss: Int, se: Int, al: Int, table: HuffmanTable) -> [UInt8] {
        var w = BitWriter(estimatedMaxSize: realBlocksW[c] * realBlocksH[c] * 16 + 1024)
        var rstIndex = 0
        acFirstPass(component: c, ss: ss, se: se, al: al, onSymbol: { sym in
            let e = table.encodingTable[sym]
            w.writeBits(UInt32(e.code), count: Int(e.length))
        }, onBits: { bits, n in w.writeBits(bits, count: n) },
           onRestart: { w.emitRestartMarker(rstIndex); rstIndex = (rstIndex + 1) & 7 })
        w.flush()
        return w.data
    }

    // MARK: - AC refine (band [ss, se], correction bits + EOBRUN with buffered bits)

    /// Drives the AC-refinement walk. `onSymbol` receives Huffman symbols
    /// (`(run<<4)|1`, `0xF0` ZRL, EOBn); `onBit` receives raw 1-bit values
    /// (sign bits, correction bits). Correction bits for already-significant
    /// coefficients are buffered and flushed after the symbol they belong to
    /// (per libjpeg `encode_mcu_AC_refine`).
    private func acRefinePass(
        component c: Int, ss: Int, se: Int, al: Int,
        onSymbol: (Int) -> Void, onBit: (UInt32) -> Void,
        onRestart: () -> Void = {}
    ) {
        let stride = blocksPerRow[c]
        var eobrun = 0
        var eobBits = [UInt32]()      // correction bits accumulated for the pending EOB run
        var absv = [Int32](repeating: 0, count: 64)
        var unit = 0

        func flushEOB() {
            guard eobrun > 0 else { return }
            let sym = eobnSymbol(eobrun); onSymbol(sym)
            let nbits = sym >> 4
            // EOBn appended bits: low `nbits` of the run count, MSB-first.
            for i in msbFirst(nbits) { onBit(UInt32((eobrun >> i) & 1)) }
            for b in eobBits { onBit(b) }
            eobBits.removeAll(keepingCapacity: true)
            eobrun = 0
        }

        for blockY in 0..<realBlocksH[c] {
            for blockX in 0..<realBlocksW[c] {
                if restartInterval > 0 && unit > 0 && unit % restartInterval == 0 {
                    flushEOB()        // flush pending EOB run + its buffered correction bits
                    onRestart()       // (emit pass) flush + RSTn
                }
                unit += 1
                let base = (blockY * stride + blockX) * 64
                var eob = 0
                for k in ss...se {
                    let a = abs(quant[c][base + zz[k]]) >> al
                    absv[k] = a
                    if a == 1 { eob = k }   // last newly-significant position
                }
                var run = 0
                var blockBits = [UInt32]()   // correction bits for this block's run
                for k in ss...se {
                    let a = absv[k]
                    if a == 0 { run += 1; continue }
                    // significant coefficient (newly or already)
                    while run > 15 && k <= eob {
                        flushEOB()
                        onSymbol(0xF0)
                        for b in blockBits { onBit(b) }
                        blockBits.removeAll(keepingCapacity: true)
                        run -= 16
                    }
                    if a > 1 {
                        // already significant → buffer correction bit, run continues
                        blockBits.append(UInt32((abs(quant[c][base + zz[k]]) >> al) & 1))
                        continue
                    }
                    // newly significant (a == 1)
                    flushEOB()
                    onSymbol((run << 4) | 1)
                    onBit(quant[c][base + zz[k]] < 0 ? 0 : 1)   // sign bit
                    for b in blockBits { onBit(b) }
                    blockBits.removeAll(keepingCapacity: true)
                    run = 0
                }
                if run > 0 || !blockBits.isEmpty {
                    eobrun += 1
                    eobBits.append(contentsOf: blockBits)
                    if eobrun == 0x7FFF { flushEOB() }
                }
            }
        }
        flushEOB()
    }

    private func emitACRefine(component c: Int, ss: Int, se: Int, al: Int, table: HuffmanTable) -> [UInt8] {
        var w = BitWriter(estimatedMaxSize: realBlocksW[c] * realBlocksH[c] * 16 + 1024)
        var rstIndex = 0
        acRefinePass(component: c, ss: ss, se: se, al: al, onSymbol: { sym in
            let e = table.encodingTable[sym]
            w.writeBits(UInt32(e.code), count: Int(e.length))
        }, onBit: { bit in w.writeBits(bit, count: 1) },
           onRestart: { w.emitRestartMarker(rstIndex); rstIndex = (rstIndex + 1) & 7 })
        w.flush()
        return w.data
    }
}
