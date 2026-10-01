// MDTransforms — meta-application and inverse of the three Modular
// transforms (RCT, Palette, Squeeze; ISO/IEC 18181-1 Annex H) on a
// `ModularImage`, with the channel bookkeeping and integer semantics of
// the reference decoder (libjxl `modular/transform/{rct,palette,squeeze,
// transform}.cc`, BSD-3-Clause, see ThirdPartyLicenses/libjxl).
// Issue #2332.

import Foundation

enum MDTransformError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidChannelRange(String)
    case metaNonMetaMix(String)
    case squeeze(String)
    case palette(String)
    case rct(String)

    var description: String {
        switch self {
        case .invalidChannelRange(let s): return "invalid channel range: \(s)"
        case .metaNonMetaMix(let s): return "transform mixes meta and non-meta channels: \(s)"
        case .squeeze(let s): return "squeeze: \(s)"
        case .palette(let s): return "palette: \(s)"
        case .rct(let s): return "rct: \(s)"
        }
    }
}

extension ModularImage {
    /// `CheckEqualChannels` of the reference decoder.
    func mdCheckEqualChannels(_ c1: Int, _ c2: Int) throws {
        guard c1 <= channels.count, c2 < channels.count, c2 >= c1 else {
            throw MDTransformError.invalidChannelRange("\(c1)..\(c2) of \(channels.count)")
        }
        if c1 < nbMetaChannels && c2 >= nbMetaChannels {
            throw MDTransformError.metaNonMetaMix("\(c1)..\(c2), \(nbMetaChannels) meta")
        }
        let a = channels[c1]
        var c = c1 + 1
        while c <= c2 {
            let b = channels[c]
            if a.width != b.width || a.height != b.height || a.hshift != b.hshift || a.vshift != b.vshift {
                throw MDTransformError.invalidChannelRange("channels \(c1) and \(c) differ in geometry")
            }
            c += 1
        }
    }
}

// MARK: - Meta application

/// Applies the meta step of every transform in order and returns the
/// transforms with default squeeze parameter lists resolved (the inverse
/// must use the same lists).
func mdMetaApply(_ transforms: [ModularTransform], image: inout ModularImage) throws -> [ModularTransform] {
    var resolved: [ModularTransform] = []
    resolved.reserveCapacity(transforms.count)
    for t in transforms {
        switch t.id {
        case .rct:
            try image.mdCheckEqualChannels(Int(t.beginC), Int(t.beginC) + 2)
            resolved.append(t)
        case .palette:
            try mdMetaPalette(image: &image, beginC: Int(t.beginC), endC: Int(t.beginC) + Int(t.numC) - 1,
                              nbColors: Int(t.nbColors), nbDeltas: Int(t.nbDeltas))
            resolved.append(t)
        case .squeeze:
            var params = t.squeezes
            if params.isEmpty { params = defaultSqueezeParameters(image: image) }
            try mdMetaSqueeze(image: &image, params: params)
            resolved.append(ModularTransform(id: .squeeze, squeezes: params))
        }
    }
    return resolved
}

private func mdMetaPalette(image: inout ModularImage, beginC: Int, endC: Int, nbColors: Int, nbDeltas: Int) throws {
    try image.mdCheckEqualChannels(beginC, endC)
    let nb = endC - beginC + 1
    if beginC >= image.nbMetaChannels {
        image.nbMetaChannels += 1
    } else {
        guard endC < image.nbMetaChannels else {
            throw MDTransformError.palette("meta palette range exceeds meta channels")
        }
        image.nbMetaChannels += 2 - nb
    }
    if nb > 1 {
        image.channels.removeSubrange((beginC + 1)...(endC))
    }
    image.channels.insert(
        ModularChannel(width: nbColors + nbDeltas, height: nb, hshift: -1, vshift: -1), at: 0
    )
}

private func mdCheckSqueezeParams(_ p: ModularTransform.SqueezeParams, channelCount: Int) throws {
    let c1 = Int(p.beginC)
    let c2 = Int(p.beginC) + Int(p.numC) - 1
    if c1 < 0 || c1 >= channelCount || c2 < 0 || c2 >= channelCount || c2 < c1 {
        throw MDTransformError.squeeze("invalid channel range \(c1)..\(c2) of \(channelCount)")
    }
}

private func mdMetaSqueeze(image: inout ModularImage, params: [ModularTransform.SqueezeParams]) throws {
    for p in params {
        try mdCheckSqueezeParams(p, channelCount: image.channels.count)
        let beginC = Int(p.beginC)
        let endC = beginC + Int(p.numC) - 1
        if beginC < image.nbMetaChannels {
            guard endC < image.nbMetaChannels else {
                throw MDTransformError.metaNonMetaMix("squeeze \(beginC)..\(endC)")
            }
            guard p.inPlace else {
                throw MDTransformError.squeeze("meta channels require in-place residuals")
            }
            image.nbMetaChannels += Int(p.numC)
        }
        let offset = p.inPlace ? endC + 1 : image.channels.count
        for c in beginC...endC {
            var ch = image.channels[c]
            if ch.hshift > 30 || ch.vshift > 30 {
                throw MDTransformError.squeeze("too many squeezes: shift > 30")
            }
            var w = ch.width
            var h = ch.height
            if w == 0 || h == 0 {
                throw MDTransformError.squeeze("squeezing empty channel")
            }
            if p.horizontal {
                ch.width = (w + 1) / 2
                if ch.hshift >= 0 { ch.hshift += 1 }
                w = w - (w + 1) / 2
            } else {
                ch.height = (h + 1) / 2
                if ch.vshift >= 0 { ch.vshift += 1 }
                h = h - (h + 1) / 2
            }
            ch.pixels = [Int32](repeating: 0, count: ch.width * ch.height)
            image.channels[c] = ch
            let placeholder = ModularChannel(width: w, height: h, hshift: ch.hshift, vshift: ch.vshift)
            image.channels.insert(placeholder, at: offset + (c - beginC))
        }
    }
}

// MARK: - Inverse

/// Undoes `transforms` in reverse order (`Image::undo_transforms`).
func mdUndoTransforms(
    _ transforms: [ModularTransform], image: inout ModularImage,
    wpHeader: WeightedPredictorHeader, bitDepth: Int
) throws {
    for t in transforms.reversed() {
        switch t.id {
        case .rct:
            try mdInverseRCT(image: &image, beginC: Int(t.beginC), rctType: Int(t.rctType))
        case .squeeze:
            try mdInverseSqueeze(image: &image, params: t.squeezes)
        case .palette:
            try mdInversePalette(image: &image, beginC: Int(t.beginC), nbColors: Int(t.nbColors),
                                 nbDeltas: Int(t.nbDeltas), predictor: t.palettePredictor,
                                 wpHeader: wpHeader, bitDepth: bitDepth)
        }
    }
}

// MARK: RCT

private func mdInverseRCT(image: inout ModularImage, beginC m: Int, rctType: Int) throws {
    try image.mdCheckEqualChannels(m, m + 2)
    if rctType == 0 { return }
    guard rctType < 42 else { throw MDTransformError.rct("invalid RCT type \(rctType)") }
    let permutation = rctType / 7
    let custom = rctType % 7
    let out0 = m + (permutation % 3)
    let out1 = m + ((permutation + 1 + permutation / 3) % 3)
    let out2 = m + ((permutation + 2 - permutation / 3) % 3)
    let ch0 = image.channels[m]
    let ch1 = image.channels[m + 1]
    let ch2 = image.channels[m + 2]
    if custom == 0 {
        image.channels[out0] = ch0
        image.channels[out1] = ch1
        image.channels[out2] = ch2
        return
    }
    let count = ch0.width * ch0.height
    var r0 = [Int32](repeating: 0, count: count)
    var r1 = [Int32](repeating: 0, count: count)
    var r2 = [Int32](repeating: 0, count: count)
    let second = custom >> 1
    let third = custom & 1
    ch0.pixels.withUnsafeBufferPointer { in0 in
        ch1.pixels.withUnsafeBufferPointer { in1 in
            ch2.pixels.withUnsafeBufferPointer { in2 in
                r0.withUnsafeMutableBufferPointer { o0 in
                    r1.withUnsafeMutableBufferPointer { o1 in
                        r2.withUnsafeMutableBufferPointer { o2 in
                            if custom == 6 {
                                for i in 0..<count {
                                    let y = in0[i]
                                    let co = in1[i]
                                    let cg = in2[i]
                                    let tmp = y &- (cg >> 1)
                                    let g = cg &+ tmp
                                    let b = tmp &- (co >> 1)
                                    let r = b &+ co
                                    o0[i] = r; o1[i] = g; o2[i] = b
                                }
                            } else {
                                for i in 0..<count {
                                    let first = in0[i]
                                    var sec = in1[i]
                                    var thi = in2[i]
                                    if third != 0 { thi = thi &+ first }
                                    if second == 1 {
                                        sec = sec &+ first
                                    } else if second == 2 {
                                        sec = sec &+ ((first &+ thi) >> 1)
                                    }
                                    o0[i] = first; o1[i] = sec; o2[i] = thi
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    var c0 = ch0; c0.pixels = r0
    var c1 = ch1; c1.pixels = r1
    var c2 = ch2; c2.pixels = r2
    image.channels[out0] = c0
    image.channels[out1] = c1
    image.channels[out2] = c2
}

// MARK: Squeeze

@inline(__always)
private func mdSmoothTendency(_ B: Int64, _ a: Int64, _ n: Int64) -> Int64 {
    var diff: Int64 = 0
    if B >= a && a >= n {
        diff = (4 &* B &- 3 &* n &- a &+ 6) / 12
        if diff &- (diff & 1) > 2 &* (B &- a) { diff = 2 &* (B &- a) &+ 1 }
        if diff &+ (diff & 1) > 2 &* (a &- n) { diff = 2 &* (a &- n) }
    } else if B <= a && a <= n {
        diff = (4 &* B &- 3 &* n &- a &- 6) / 12
        if diff &+ (diff & 1) < 2 &* (B &- a) { diff = 2 &* (B &- a) &- 1 }
        if diff &- (diff & 1) < 2 &* (a &- n) { diff = 2 &* (a &- n) }
    }
    return diff
}

private func mdInverseHSqueeze(image: inout ModularImage, c: Int, rc: Int) throws {
    let chin = image.channels[c]
    let res = image.channels[rc]
    guard chin.width == (chin.width + res.width + 1) / 2, chin.height == res.height else {
        throw MDTransformError.squeeze("horizontal residual geometry mismatch")
    }
    if res.width == 0 {
        image.channels[c].hshift -= 1
        return
    }
    var chout = ModularChannel(width: chin.width + res.width, height: chin.height,
                               hshift: chin.hshift - 1, vshift: chin.vshift)
    if res.height == 0 {
        image.channels[c] = chout
        return
    }
    let w = chin.width
    let rw = res.width
    let ow = chout.width
    chout.pixels.withUnsafeMutableBufferPointer { out in
        chin.pixels.withUnsafeBufferPointer { avgRows in
            res.pixels.withUnsafeBufferPointer { resRows in
                for y in 0..<chin.height {
                    let pAvg = avgRows.baseAddress! + y * w
                    let pRes = resRows.baseAddress! + y * rw
                    let pOut = out.baseAddress! + y * ow
                    for x in 0..<rw {
                        let dmt = Int64(pRes[x])
                        let avg = Int64(pAvg[x])
                        let nextAvg = x + 1 < w ? Int64(pAvg[x + 1]) : avg
                        let left = x > 0 ? Int64(pOut[(x << 1) - 1]) : avg
                        let tendency = mdSmoothTendency(left, avg, nextAvg)
                        let diff = dmt &+ tendency
                        let A = avg &+ (diff / 2)
                        pOut[x << 1] = Int32(truncatingIfNeeded: A)
                        pOut[(x << 1) + 1] = Int32(truncatingIfNeeded: A &- diff)
                    }
                    if ow & 1 != 0 { pOut[ow - 1] = pAvg[w - 1] }
                }
            }
        }
    }
    image.channels[c] = chout
}

private func mdInverseVSqueeze(image: inout ModularImage, c: Int, rc: Int) throws {
    let chin = image.channels[c]
    let res = image.channels[rc]
    guard chin.height == (chin.height + res.height + 1) / 2, chin.width == res.width else {
        throw MDTransformError.squeeze("vertical residual geometry mismatch")
    }
    if res.height == 0 {
        image.channels[c].vshift -= 1
        return
    }
    var chout = ModularChannel(width: chin.width, height: chin.height + res.height,
                               hshift: chin.hshift, vshift: chin.vshift - 1)
    if res.width == 0 {
        image.channels[c] = chout
        return
    }
    let w = chin.width
    let oh = chout.height
    chout.pixels.withUnsafeMutableBufferPointer { out in
        chin.pixels.withUnsafeBufferPointer { avgRows in
            res.pixels.withUnsafeBufferPointer { resRows in
                for y in 0..<res.height {
                    let pRes = resRows.baseAddress! + y * w
                    let pAvg = avgRows.baseAddress! + y * w
                    let pNAvg = avgRows.baseAddress! + (y + 1 < chin.height ? y + 1 : y) * w
                    let pOut = out.baseAddress! + (y << 1) * w
                    let pNOut = out.baseAddress! + ((y << 1) + 1) * w
                    for x in 0..<w {
                        let avg = Int64(pAvg[x])
                        let nextAvg = Int64(pNAvg[x])
                        let top: Int64 = y > 0 ? Int64(out[((y << 1) - 1) * w + x]) : avg
                        let tendency = mdSmoothTendency(top, avg, nextAvg)
                        let diff = Int64(pRes[x]) &+ tendency
                        let o = avg &+ (diff / 2)
                        pOut[x] = Int32(truncatingIfNeeded: o)
                        pNOut[x] = Int32(truncatingIfNeeded: o &- diff)
                    }
                }
                if oh & 1 != 0 {
                    let y = chin.height - 1
                    let pAvg = avgRows.baseAddress! + y * w
                    let pOut = out.baseAddress! + (y << 1) * w
                    for x in 0..<w { pOut[x] = pAvg[x] }
                }
            }
        }
    }
    image.channels[c] = chout
}

private func mdInverseSqueeze(image: inout ModularImage, params: [ModularTransform.SqueezeParams]) throws {
    for p in params.reversed() {
        try mdCheckSqueezeParams(p, channelCount: image.channels.count)
        let beginC = Int(p.beginC)
        let endC = beginC + Int(p.numC) - 1
        let offset: Int
        if p.inPlace {
            offset = endC + 1
        } else {
            offset = image.channels.count + beginC - endC - 1
        }
        if beginC < image.nbMetaChannels {
            guard image.nbMetaChannels > Int(p.numC) else {
                throw MDTransformError.squeeze("meta channel count underflow")
            }
            image.nbMetaChannels -= Int(p.numC)
        }
        for c in beginC...endC {
            let rc = offset + c - beginC
            guard rc < image.channels.count else {
                throw MDTransformError.squeeze("residual channel \(rc) out of range")
            }
            if image.channels[c].width < image.channels[rc].width
                || image.channels[c].height < image.channels[rc].height {
                throw MDTransformError.squeeze("corrupted squeeze transform")
            }
            if p.horizontal {
                try mdInverseHSqueeze(image: &image, c: c, rc: rc)
            } else {
                try mdInverseVSqueeze(image: &image, c: c, rc: rc)
            }
        }
        image.channels.removeSubrange(offset..<(offset + (endC - beginC + 1)))
    }
}

// MARK: Palette

private let mdDeltaPalette: [(Int32, Int32, Int32)] = [
    (0, 0, 0), (4, 4, 4), (11, 0, 0), (0, 0, -13), (0, -12, 0), (-10, -10, -10),
    (-18, -18, -18), (-27, -27, -27), (-18, -18, 0), (0, 0, -32), (-32, 0, 0), (-37, -37, -37),
    (0, -32, -32), (24, 24, 45), (50, 50, 50), (-45, -24, -24), (-24, -45, -45), (0, -24, -24),
    (-34, -34, 0), (-24, 0, -24), (-45, -45, -24), (64, 64, 64), (-32, 0, -32), (0, -32, 0),
    (-32, 0, 32), (-24, -45, -24), (45, 24, 45), (24, -24, -45), (-45, -24, 24), (80, 80, 80),
    (64, 0, 0), (0, 0, -64), (0, -64, -64), (-24, -24, 45), (96, 96, 96), (64, 64, 0),
    (45, -24, -24), (34, -34, 0), (112, 112, 112), (24, -45, -45), (45, 45, -24), (0, -32, 32),
    (24, -24, 45), (0, 96, 96), (45, -24, 24), (24, -45, -24), (-24, -45, 24), (0, -64, 0),
    (96, 0, 0), (128, 128, 128), (64, 0, 64), (144, 144, 144), (96, 96, 0), (-36, -36, 36),
    (45, -24, -45), (45, -45, -24), (0, 0, -96), (0, 128, 128), (0, 96, 0), (45, 24, -45),
    (-128, 0, 0), (24, -45, 24), (-45, 24, -45), (64, 0, -64), (64, -64, -64), (96, 0, 96),
    (45, -45, 24), (24, 45, -45), (64, 64, -64), (128, 128, 0), (0, 0, -128), (-24, 45, -45)
]

private let mdLargeCube = 5
private let mdSmallCube = 4
private let mdSmallCubeBits = 2
private let mdLargeCubeOffset = 4 * 4 * 4

@inline(__always)
private func mdScale4(_ value: Int, _ bitDepth: Int) -> Int32 {
    Int32(truncatingIfNeeded: (UInt64(value) &* ((UInt64(1) << UInt64(bitDepth)) &- 1)) >> 2)
}

/// `GetPaletteValue` of the reference decoder.
@inline(__always)
private func mdPaletteValue(
    _ palette: UnsafeBufferPointer<Int32>, index indexIn: Int, c: Int, paletteSize: Int, bitDepth: Int
) -> Int32 {
    var index = indexIn
    if index < 0 {
        if c >= 3 { return 0 }
        index = -(index + 1)
        index %= 1 + 2 * (mdDeltaPalette.count - 1)
        let entry = mdDeltaPalette[(index + 1) >> 1]
        let base: Int32 = c == 0 ? entry.0 : (c == 1 ? entry.1 : entry.2)
        var result = base &* ((index & 1) != 0 ? 1 : -1)
        if bitDepth > 8 {
            result = result &* (Int32(1) << Int32(bitDepth - 8))
        }
        return result
    } else if paletteSize <= index && index < paletteSize + mdLargeCubeOffset {
        if c >= 3 { return 0 }
        index -= paletteSize
        index >>= c * mdSmallCubeBits
        return mdScale4(index % mdSmallCube, bitDepth) &+ (Int32(1) << Int32(max(0, bitDepth - 3)))
    } else if paletteSize + mdLargeCubeOffset <= index {
        if c >= 3 { return 0 }
        index -= paletteSize + mdLargeCubeOffset
        switch c {
        case 1: index /= mdLargeCube
        case 2: index /= mdLargeCube * mdLargeCube
        default: break
        }
        return mdScale4(index % mdLargeCube, bitDepth)
    }
    return palette[c * paletteSize + index]
}

private func mdInversePalette(
    image: inout ModularImage, beginC: Int, nbColors: Int, nbDeltas: Int, predictor: UInt32,
    wpHeader: WeightedPredictorHeader, bitDepth bitDepthIn: Int
) throws {
    guard image.nbMetaChannels >= 1 else {
        throw MDTransformError.palette("palette transform without palette channel")
    }
    let nb = image.channels[0].height
    let c0 = beginC + 1
    guard c0 < image.channels.count else {
        throw MDTransformError.palette("channel \(c0) is out of range")
    }
    let w = image.channels[c0].width
    let h = image.channels[c0].height
    guard nb >= 1 else { throw MDTransformError.palette("corrupted transforms") }
    if nb > 1 {
        let template = image.channels[c0]
        for _ in 1..<nb {
            image.channels.insert(
                ModularChannel(width: w, height: h, hshift: template.hshift, vshift: template.vshift),
                at: c0 + 1
            )
        }
    }
    let palette = image.channels[0]
    let paletteSize = palette.width
    let bitDepth = min(bitDepthIn, 24)
    if w == 0 {
        // nothing to reconstruct
    } else if nbDeltas == 0 && predictor == 0 {
        palette.pixels.withUnsafeBufferPointer { pal in
            if nb == 1 {
                var out = image.channels[c0].pixels
                for i in 0..<(w * h) {
                    let index = min(max(Int(out[i]), 0), paletteSize - 1)
                    out[i] = mdPaletteValue(pal, index: index, c: 0, paletteSize: paletteSize, bitDepth: bitDepth)
                }
                image.channels[c0].pixels = out
            } else {
                let indices = image.channels[c0].pixels
                for c in 0..<nb {
                    var out = [Int32](repeating: 0, count: w * h)
                    for i in 0..<(w * h) {
                        out[i] = mdPaletteValue(pal, index: Int(indices[i]), c: c, paletteSize: paletteSize, bitDepth: bitDepth)
                    }
                    image.channels[c0 + c].pixels = out
                }
            }
        }
    } else {
        let indices = image.channels[c0].pixels
        guard predictor < 14 else {
            throw MDTransformError.palette("invalid palette predictor \(predictor)")
        }
        palette.pixels.withUnsafeBufferPointer { pal in
            for c in 0..<nb {
                var out = [Int32](repeating: 0, count: w * h)
                var wp = predictor == 6 ? MDWeightedPredictor(header: wpHeader, xsize: w) : nil
                out.withUnsafeMutableBufferPointer { p in
                    let base = p.baseAddress!
                    for y in 0..<h {
                        let row = base + y * w
                        let prev = y > 0 ? UnsafePointer(base + (y - 1) * w) : nil
                        let prev2 = y > 1 ? UnsafePointer(base + (y - 2) * w) : nil
                        for x in 0..<w {
                            let index = Int(indices[y * w + x])
                            let entry = mdPaletteValue(pal, index: index, c: c, paletteSize: paletteSize, bitDepth: bitDepth)
                            var val: Int64
                            var property15: Int32 = 0
                            let nbh = MDNeighbourhood(x: x, y: y, width: w, row: UnsafePointer(row), prevRow: prev, prevPrevRow: prev2)
                            var weighted: Int64 = 0
                            if wp != nil {
                                weighted = wp!.predict(x: x, y: y, n: nbh.top, w: nbh.left, ne: nbh.topRight,
                                                       nw: nbh.topLeft, nn: nbh.topTop, property15: &property15)
                            }
                            if index < nbDeltas {
                                val = mdPredictOne(predictor, nbh, weighted: weighted) &+ Int64(entry)
                            } else {
                                val = Int64(entry)
                            }
                            let stored = Int32(truncatingIfNeeded: val)
                            row[x] = stored
                            if wp != nil {
                                wp!.updateErrors(actual: Int64(stored), x: x, y: y)
                            }
                        }
                    }
                }
                image.channels[c0 + c].pixels = out
            }
        }
    }
    if c0 >= image.nbMetaChannels {
        image.nbMetaChannels -= 1
    } else {
        guard image.nbMetaChannels >= 2 - nb else {
            throw MDTransformError.palette("meta channel bookkeeping underflow")
        }
        image.nbMetaChannels -= 2 - nb
        guard beginC + nb - 1 < image.nbMetaChannels else {
            throw MDTransformError.palette("meta palette range exceeds meta channels")
        }
    }
    image.channels.removeFirst()
}
