// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.
// Isis modifications are recorded in Git.

import Accelerate
import Foundation

/// The jpegli-compatible JPEG decoder.
///
/// `JLIDecoder` decompresses JPEG data, automatically detecting advanced features
/// such as jpegli 10+ bit precision and XYB color space encoding.
///
/// Supports baseline sequential JPEG (SOF0) with standard Huffman coding and all
/// chroma subsampling modes. Progressive JPEG (SOF2) parsing is supported but
/// full progressive decoding is planned for a future milestone.
///
/// ## Usage
///
/// ```swift
/// let decoder = JLIDecoder()
/// let info = try decoder.inspect(data: jpegBytes)
/// let image = try decoder.decode(from: jpegBytes)
/// ```
public struct JLIDecoder: Sendable {
    /// Creates a new decoder instance.
    public init() {}

    /// Inspects JPEG data and returns metadata without fully decoding the image.
    ///
    /// Use this to detect whether a JPEG uses advanced jpegli features (10+ bit,
    /// XYB color space) before deciding on a decode configuration.
    ///
    /// - Parameter data: The JPEG bitstream bytes.
    /// - Returns: A ``JLIJPEGInfo`` describing the JPEG's properties.
    /// - Throws: ``JLIError`` if the data is not valid JPEG.
    public func inspect(data: [UInt8]) throws -> JLIJPEGInfo {
        guard data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 else {
            throw JLIError.invalidJPEGData
        }
        var reader = MarkerReader(data: data)
        return try reader.readInfo()
    }

    /// Decodes JPEG data into a ``JLIImage``.
    ///
    /// The decoder automatically detects jpegli-specific features:
    /// - **10+ bit precision**: Outputs to a 16-bit buffer unless overridden.
    /// - **XYB color space**: Applies the correct inverse transform.
    ///
    /// - Parameters:
    ///   - data: The JPEG bitstream bytes.
    ///   - configuration: Decoder settings controlling output format.
    /// - Returns: The decoded image.
    /// - Throws: ``JLIError`` if decoding fails.
    public func decode(
        from data: [UInt8],
        configuration: JLIDecoderConfiguration = .default
    ) throws -> JLIImage {
        guard data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 else {
            throw JLIError.invalidJPEGData
        }

        // Step 1: Parse JPEG markers
        var markerReader = MarkerReader(data: data)
        let parsed = try markerReader.parse()
        let frame = parsed.frameInfo

        guard !parsed.scans.isEmpty else {
            throw JLIError.decodingFailed("No scan data found in JPEG")
        }

        // Lossless (SOF3) is predictive, not DCT — fully separate path.
        if frame.isLossless {
            return try decodeLossless(frame: frame, scans: parsed.scans, configuration: configuration,
                                      restartInterval: parsed.restartInterval,
                                      iccProfile: parsed.iccProfile, exif: parsed.exif)
        }

        // Step 2: Prepare quantization tables (convert from zigzag to natural order)
        let quantTables = parsed.quantTables.map { zigzagTable -> [Int] in
            var natural = [Int](repeating: 0, count: 64)
            for i in 0..<64 {
                natural[Quantization.zigzagOrder[i]] = zigzagTable[i]
            }
            return natural
        }

        // Reject structurally-invalid frames before any size math or indexing.
        try validateDecodable(frame, quantTableCount: quantTables.count)

        // Reduced-scale (thumbnail) decode. 1 = full; 2/4 = low-freq box average;
        // 8 = 1/8 (DC-only). Each output sample is the exact mean of its
        // scale×scale source box, formed directly from the DCT coefficients.
        let scale = configuration.scale
        guard scale == 1 || scale == 2 || scale == 4 || scale == 8 else {
            throw JLIError.unsupportedJPEGFeature("decode scale \(scale) (only 1, 2, 4, 8 supported)")
        }

        // Step 4: Determine MCU structure
        let components = frame.components
        let numComponents = components.count
        let hMaxSampling = components.map(\.horizontalSampling).max() ?? 1
        let vMaxSampling = components.map(\.verticalSampling).max() ?? 1
        let mcuW = hMaxSampling * 8
        let mcuH = vMaxSampling * 8
        let mcuCountH = (frame.width + mcuW - 1) / mcuW
        let mcuCountV = (frame.height + mcuH - 1) / mcuH

        // Step 5: Allocate one flat zigzag-coefficient buffer per component.
        // Block `b` of component `c` lives at `componentZigzag[c][b*64 ..< (b+1)*64]`.
        var componentZigzag = [[Int32]]()
        var componentBlocksPerRow = [Int]()
        var componentDimensions = [(blocksH: Int, blocksV: Int)]()
        for comp in components {
            let blocksH = mcuCountH * comp.horizontalSampling
            let blocksV = mcuCountV * comp.verticalSampling
            componentBlocksPerRow.append(blocksH)
            componentDimensions.append((blocksH, blocksV))
            componentZigzag.append([Int32](repeating: 0, count: blocksH * blocksV * 64))
        }

        // Step 6: Decode entropy data into the flat per-component buffers.
        // Progressive (SOF2) uses multiple scans with spectral selection and
        // successive approximation; sequential scans each carry complete components.
        if frame.isProgressive {
            // Non-interleaved (AC) scans address each component's own data-unit
            // grid: ceil(compW/8) × ceil(compH/8), where compW/H = the component's
            // dimensions after subsampling. Smaller than the MCU-padded grid for
            // images that aren't a whole number of MCUs.
            let realW = components.map { comp -> Int in
                let compW = (frame.width * comp.horizontalSampling + hMaxSampling - 1) / hMaxSampling
                return (compW + 7) / 8
            }
            let realH = components.map { comp -> Int in
                let compH = (frame.height * comp.verticalSampling + vMaxSampling - 1) / vMaxSampling
                return (compH + 7) / 8
            }
            var prog = ProgressiveDecoder(
                components: components,
                mcuCountH: mcuCountH, mcuCountV: mcuCountV,
                blocksPerRow: componentBlocksPerRow,
                blocksPerCol: componentDimensions.map { $0.blocksV },
                realBlocksW: realW, realBlocksH: realH,
                restartInterval: parsed.restartInterval
            )
            try prog.decode(scans: parsed.scans)
            componentZigzag = prog.coeffs
        } else {
            var decodedComponents = Set<Int>()
            for scan in parsed.scans {
                let header = scan.header
                // Some encoders write all zeroes in Ss, Se, Ah and Al; libjpeg decodes those scans over every
                // coefficient with a warning, and so does this decoder (issue #2852).
                guard !header.components.isEmpty, header.spectralStart == 0, [0, 63].contains(header.spectralEnd),
                      header.successiveApproxHigh == 0, header.successiveApproxLow == 0 else {
                    throw JLIError.decodingFailed("Invalid sequential scan header")
                }
                let scanIndices = try header.components.map { selector -> Int in
                    guard let index = components.firstIndex(where: { $0.id == selector.componentSelector }),
                          decodedComponents.insert(index).inserted else {
                        throw JLIError.decodingFailed("Unknown or repeated sequential scan component")
                    }
                    return index
                }
                let nonInterleaved = scanIndices.count == 1
                let first = components[scanIndices[0]]
                // A single-component MCU is one real block, without the dummy blocks
                // that complete the frame's interleaved MCU at the right/bottom edge.
                let scanMCUsH = nonInterleaved
                    ? ((frame.width * first.horizontalSampling + hMaxSampling - 1) / hMaxSampling + 7) / 8
                    : mcuCountH
                let scanMCUsV = nonInterleaved
                    ? ((frame.height * first.verticalSampling + vMaxSampling - 1) / vMaxSampling + 7) / 8
                    : mcuCountV
                var bitReader = BitReader(data: scan.entropyData)
                var prevDC = [Int32](repeating: 0, count: numComponents)
                var acBuf = [Int32](repeating: 0, count: 64)

                let restartInterval = scan.restartInterval
                var mcuCount = 0
                var restartIndex = 0

                // Tables are fixed per scan — resolve them once per component
                // instead of re-running a closure search + two Dictionary lookups
                // (and the resulting HuffmanTable struct copies) on every MCU.
                let dcTables = prepareDCTables(scan.dcTables)
                let acTables = prepareACTables(scan.acTables)
                let compDCTables: [HuffmanTable] = header.components.map { selector in
                    dcTables[selector.dcTableId] ?? StandardHuffmanTables.dcLuminance
                }
                let compACTables: [HuffmanTable] = header.components.map { selector in
                    acTables[selector.acTableId] ?? StandardHuffmanTables.acLuminance
                }

                for mcuY in 0..<scanMCUsV {
                    for mcuX in 0..<scanMCUsH {
                        // Every `restartInterval` MCUs, skip the RST0–RST7 marker
                        // (cycled) and reset DC predictors.
                        if restartInterval > 0 && mcuCount > 0
                            && mcuCount % restartInterval == 0 {
                            try bitReader.skipRestartMarker(expectedIndex: restartIndex)
                            restartIndex = (restartIndex + 1) & 7
                            for i in 0..<numComponents { prevDC[i] = 0 }
                        }
                        mcuCount += 1

                        for (scanIndex, compIdx) in scanIndices.enumerated() {
                            let comp = components[compIdx]
                            let dcTable = compDCTables[scanIndex]
                            let acTable = compACTables[scanIndex]
                            let blocksPerRow = componentBlocksPerRow[compIdx]
                            let blocksH = nonInterleaved ? 1 : comp.horizontalSampling
                            let blocksV = nonInterleaved ? 1 : comp.verticalSampling

                            for by in 0..<blocksV {
                                for bx in 0..<blocksH {
                                    let blockX = mcuX * blocksH + bx
                                    let blockY = mcuY * blocksV + by
                                    let blockIndex = blockY * blocksPerRow + blockX
                                    let dst = blockIndex * 64

                                    let dcDiff = try HuffmanDecoder.decodeDC(
                                        from: &bitReader, table: dcTable
                                    )
                                    prevDC[compIdx] += dcDiff

                                    try HuffmanDecoder.decodeAC(
                                        from: &bitReader, table: acTable, into: &acBuf
                                    )
                                    acBuf[0] = prevDC[compIdx]

                                    // One uniqueness check per block via the buffer
                                    // pointer, instead of 64 from nested-array
                                    // subscript writes (the COW-check cost in the
                                    // decode profile).
                                    componentZigzag[compIdx].withUnsafeMutableBufferPointer { zz in
                                        let d = zz.baseAddress! + dst
                                        for i in 0..<64 { d[i] = acBuf[i] }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            guard decodedComponents.count == numComponents else {
                throw JLIError.decodingFailed("Sequential scans do not cover every frame component")
            }
        }

        // Step 7: Per component — fused dequantize+IDCT straight from the
        // entropy-order coefficients, level-shift, then write each block into
        // its (exactly component-sized) plane — in parallel across block ranges
        // for large images (every 8×8 block writes a disjoint plane tile, so
        // any block partition is race-free and the result is bit-identical to
        // a serial pass; gated by ``reconstructMinBlocksPerChunk`` and proven
        // by `parallelDecodeDeterministic`).
        var componentPlanes = [(data: [Float], width: Int, height: Int)]()
        let maxBlockCount = componentDimensions.map { $0.blocksH * $0.blocksV }.max() ?? 0
        // Reused per-component scratch; each component fully writes its used
        // region before reading it, so skip the zero-fill (a per-decode bzero).
        let scratchN = maxBlockCount * 64
        var pixelsBuf = [Float](unsafeUninitializedCapacity: scratchN) { _, c in c = scratchN }
        var idctScratch = [Float](unsafeUninitializedCapacity: scratchN) { _, c in c = scratchN }
        // The separate inverse-zigzag + dequantize buffers are only needed by
        // the 1/2 & 1/4 box-average preview path; the full-resolution path
        // fuses both into the IDCT pack pass.
        let needsNatural = scale == 2 || scale == 4
        var natural = [Int32](unsafeUninitializedCapacity: needsNatural ? scratchN : 0) {
            _, c in c = needsNatural ? scratchN : 0
        }
        var dctBuf = [Float](unsafeUninitializedCapacity: needsNatural ? scratchN : 0) {
            _, c in c = needsNatural ? scratchN : 0
        }

        for compIdx in 0..<numComponents {
            let comp = components[compIdx]
            let blocksH = componentDimensions[compIdx].blocksH
            let blocksV = componentDimensions[compIdx].blocksV
            let blockCount = blocksH * blocksV
            let qtF = quantTables[comp.quantTableIndex].map { Float($0) }

            let compWidth = (frame.width * comp.horizontalSampling + hMaxSampling - 1) / hMaxSampling
            let compHeight = (frame.height * comp.verticalSampling + vMaxSampling - 1) / vMaxSampling

            // 1/8 DC-only path: each 8×8 block reduces to one pixel — its average,
            // which for the normalized DCT is (1/8)·dequant(DC) + level shift. No
            // inverse DCT; output plane is the block grid, trimmed to ceil(comp/8).
            if scale == 8 {
                let center = Float(1 << (frame.precision - 1))
                let maxV = Float((1 << frame.precision) - 1)
                let dcStep = Float(quantTables[comp.quantTableIndex][0])  // DC quant (natural order)
                var small = [Float](repeating: 0, count: blocksH * blocksV)
                componentZigzag[compIdx].withUnsafeBufferPointer { src in
                    for b in 0..<blockCount {
                        let dc = Float(src[b * 64]) * dcStep
                        small[b] = min(max(dc * (1.0 / 8.0) + center, 0), maxV)
                    }
                }
                let cwS = (compWidth + 7) / 8
                let chS = (compHeight + 7) / 8
                if blocksH != cwS || blocksV != chS {
                    var trimmed = [Float](repeating: 0, count: cwS * chS)
                    for y in 0..<chS {
                        for x in 0..<cwS { trimmed[y * cwS + x] = small[y * blocksH + x] }
                    }
                    componentPlanes.append((trimmed, cwS, chS))
                } else {
                    componentPlanes.append((small, blocksH, blocksV))
                }
                continue
            }

            // 1/2 & 1/4 box-average path: each 8×8 block reduces to a bs×bs tile
            // (bs = 8/scale) whose samples are the exact means of the scale×scale
            // source-pixel boxes, formed straight from the coefficients via the
            // separable A·F·Aᵀ contraction (A = ``boxAverageMatrix``). No IDCT.
            // This preview path keeps the separate inverse-zigzag + dequantize
            // passes (the contraction reads natural-order coefficients).
            if scale == 2 || scale == 4 {
                let zigzag = Quantization.zigzagOrder
                componentZigzag[compIdx].withUnsafeBufferPointer { srcBuf in
                    natural.withUnsafeMutableBufferPointer { dstBuf in
                        let src = srcBuf.baseAddress!
                        let dst = dstBuf.baseAddress!
                        for b in 0..<blockCount {
                            let base = b * 64
                            for i in 0..<64 { dst[base + zigzag[i]] = src[base + i] }
                        }
                    }
                }
                AccelerateDSP.dequantizeBatch(
                    natural, table: qtF, into: &dctBuf, blockCount: blockCount
                )
                let bs = 8 / scale
                let a = Self.boxAverageMatrix(scale: scale)        // bs×8, row-major
                let pw = blocksH * bs, ph = blocksV * bs
                var plane = [Float](repeating: 0, count: pw * ph)
                let center = Float(1 << (frame.precision - 1))
                let maxV = Float((1 << frame.precision) - 1)
                dctBuf.withUnsafeBufferPointer { fb in
                    plane.withUnsafeMutableBufferPointer { pb in
                        let f = fb.baseAddress!
                        var tmp = [Float](repeating: 0, count: bs * 8)   // tmp[J*8+u]
                        for b in 0..<blockCount {
                            let base = b * 64
                            // tmp[J,u] = Σ_v A[J,v]·F[v*8+u]
                            for j in 0..<bs {
                                for u in 0..<8 {
                                    var acc: Float = 0
                                    for v in 0..<8 { acc += a[j * 8 + v] * f[base + v * 8 + u] }
                                    tmp[j * 8 + u] = acc
                                }
                            }
                            let blockX = (b % blocksH) * bs
                            let blockY = (b / blocksH) * bs
                            for j in 0..<bs {
                                let py = blockY + j
                                if py >= ph { break }
                                let rowBase = py * pw
                                for i in 0..<bs {
                                    let px = blockX + i
                                    if px >= pw { break }
                                    // out[i,j] = Σ_u A[i,u]·tmp[J,u]
                                    var acc: Float = 0
                                    for u in 0..<8 { acc += a[i * 8 + u] * tmp[j * 8 + u] }
                                    pb[rowBase + px] = min(max(acc + center, 0), maxV)
                                }
                            }
                        }
                    }
                }
                let cwS = (compWidth + scale - 1) / scale
                let chS = (compHeight + scale - 1) / scale
                if pw != cwS || ph != chS {
                    var trimmed = [Float](repeating: 0, count: cwS * chS)
                    for y in 0..<chS {
                        for x in 0..<cwS { trimmed[y * cwS + x] = plane[y * pw + x] }
                    }
                    componentPlanes.append((trimmed, cwS, chS))
                } else {
                    componentPlanes.append((plane, pw, ph))
                }
                continue
            }

            // Full-resolution path: fused dequant+IDCT per block range, scattered
            // straight into an exactly component-sized plane (no padded plane,
            // no trim copy — edge blocks write only their in-bounds rows/columns,
            // and every in-bounds pixel belongs to some block, so the
            // uninitialized plane is fully covered). All scratch is block-indexed,
            // so parallel workers slice disjoint subranges of the SAME buffers.
            var plane = [Float](unsafeUninitializedCapacity: compWidth * compHeight) {
                _, c in c = compWidth * compHeight
            }
            let chunks = min(ProcessInfo.processInfo.activeProcessorCount,
                             max(1, blockCount / JLIDecoder.reconstructMinBlocksPerChunk))
            componentZigzag[compIdx].withUnsafeBufferPointer { zzb in
                qtF.withUnsafeBufferPointer { qtb in
                    pixelsBuf.withUnsafeMutableBufferPointer { pxb in
                        idctScratch.withUnsafeMutableBufferPointer { scb in
                            plane.withUnsafeMutableBufferPointer { plb in
                                let ptrs = ReconstructPtrs(
                                    zz: zzb.baseAddress!, qt: qtb.baseAddress!,
                                    px: pxb.baseAddress!, scratch: scb.baseAddress!,
                                    plane: plb.baseAddress!)
                                if chunks <= 1 {
                                    JLIDecoder.reconstructBlocks(
                                        0..<blockCount, ptrs: ptrs, blocksH: blocksH,
                                        compWidth: compWidth, compHeight: compHeight,
                                        precision: frame.precision)
                                } else {
                                    let span = (blockCount + chunks - 1) / chunks
                                    DispatchQueue.concurrentPerform(iterations: chunks) { c in
                                        let lo = c * span, hi = min(lo + span, blockCount)
                                        if lo < hi {
                                            JLIDecoder.reconstructBlocks(
                                                lo..<hi, ptrs: ptrs, blocksH: blocksH,
                                                compWidth: compWidth, compHeight: compHeight,
                                                precision: frame.precision)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            componentPlanes.append((plane, compWidth, compHeight))
        }

        // Step 8: Chroma upsample and color convert. Output dimensions are the
        // image dimensions reduced by `scale` (= full dims when scale == 1).
        let outW = (frame.width + scale - 1) / scale
        let outH = (frame.height + scale - 1) / scale
        let outputData: [UInt8]
        let outputColorModel: JLIColorModel
        // 12-bit (grayscale or color) decodes to a uint16 buffer (little-endian
        // samples); 8-bit stays uint8.
        let isExtendedPrecision = frame.precision > 8

        // Float32 output: emit the reconstructed sample planes as 32-bit
        // little-endian floats — the RAW sample values (e.g. 0…4095 for 12-bit),
        // NOT normalized to [0,1] (that asymmetry vs the encoder's float32 *input*
        // is intentional; see JLIDecoderConfiguration.outputPixelFormat). This is
        // a zero-rounding passthrough of the same float planes the integer path
        // rounds, so it never loses precision. Grayscale and XYB are supported;
        // the YCbCr→RGB path is not (its integer helper does not expose floats).
        let wantsFloat32 = configuration.outputPixelFormat == .float32

        if numComponents == 1 {
            // Grayscale
            let plane = componentPlanes[0]
            if wantsFloat32 {
                outputData = Self.floatsToLE(plane.data)
            } else if isExtendedPrecision {
                var bytes = [UInt8](repeating: 0, count: plane.data.count * 2)
                for i in 0..<plane.data.count {
                    let v = UInt16(clamping: Int(plane.data[i].rounded()))
                    bytes[i * 2] = UInt8(v & 0xFF)
                    bytes[i * 2 + 1] = UInt8(v >> 8)
                }
                outputData = bytes
            } else {
                outputData = plane.data.map { UInt8(clamping: Int($0.rounded())) }
            }
            outputColorModel = configuration.outputColorModel ?? .grayscale
        } else if numComponents == 3 && !isExtendedPrecision
                    && parsed.iccProfile == XYBICCProfile.data {
            // XYB color: the three full-resolution planes are scaled-XYB samples
            // (4:4:4). Invert the XYB transform per pixel to recover sRGB. (The
            // embedded ICC also lets non-XYB-aware decoders display it.)
            func trim(_ p: (data: [Float], width: Int, height: Int)) -> [Float] {
                if p.width == outW && p.height == outH { return p.data }
                var t = [Float](repeating: 0, count: outW * outH)
                for y in 0..<outH { for x in 0..<outW { t[y * outW + x] = p.data[y * p.width + x] } }
                return t
            }
            let xs = trim(componentPlanes[0]), ys = trim(componentPlanes[1]), bs = trim(componentPlanes[2])
            if wantsFloat32 {
                var rgbF = [Float](repeating: 0, count: outW * outH * 3)
                for i in 0..<(outW * outH) {
                    let (r, g, b) = ColorConversion.xybSampleToRGB(x: xs[i], y: ys[i], bChannel: bs[i])
                    rgbF[i * 3] = r; rgbF[i * 3 + 1] = g; rgbF[i * 3 + 2] = b
                }
                outputData = Self.floatsToLE(rgbF)
            } else {
                var rgb = [UInt8](repeating: 0, count: outW * outH * 3)
                for i in 0..<(outW * outH) {
                    let (r, g, b) = ColorConversion.xybSampleToRGB(x: xs[i], y: ys[i], bChannel: bs[i])
                    rgb[i * 3] = UInt8(clamping: Int(r.rounded()))
                    rgb[i * 3 + 1] = UInt8(clamping: Int(g.rounded()))
                    rgb[i * 3 + 2] = UInt8(clamping: Int(b.rounded()))
                }
                outputData = rgb
            }
            outputColorModel = configuration.outputColorModel ?? .rgb
        } else {
            // YCbCr → RGB
            guard !wantsFloat32 else {
                // The YCbCr→RGB conversion runs through an integer-output vDSP
                // helper; a float path here would duplicate that math and risk
                // diverging from the integer path's rounding. Float32 decode is
                // supported for grayscale and XYB only for now.
                throw JLIError.unsupportedJPEGFeature(
                    "float32 output for YCbCr color (supported for grayscale and XYB)")
            }
            let yPlane = componentPlanes[0]

            // Upsample Cb and Cr to full resolution
            let cbUp = ChromaSampling.upsample(
                componentPlanes[1].data,
                width: componentPlanes[1].width,
                height: componentPlanes[1].height,
                targetWidth: outW, targetHeight: outH
            )
            let crUp = ChromaSampling.upsample(
                componentPlanes[2].data,
                width: componentPlanes[2].width,
                height: componentPlanes[2].height,
                targetWidth: outW, targetHeight: outH
            )

            // Trim Y plane if padded
            let yTrimmed: [Float]
            if yPlane.width != outW || yPlane.height != outH {
                var trimmed = [Float](repeating: 0, count: outW * outH)
                for y in 0..<outH {
                    for x in 0..<outW {
                        trimmed[y * outW + x] = yPlane.data[y * yPlane.width + x]
                    }
                }
                yTrimmed = trimmed
            } else {
                yTrimmed = yPlane.data
            }

            if isExtendedPrecision {
                // 12-bit color → little-endian UInt16 RGB. Planes are already
                // reconstructed in 0...2^P-1 with chroma centered at 2^(P-1).
                outputData = ColorConversion.imageYCbCr16ToRGB(
                    y: yTrimmed, cb: cbUp, cr: crUp,
                    width: outW, height: outH,
                    center: Float(1 << (frame.precision - 1)),
                    maxValue: Float((1 << frame.precision) - 1)
                )
            } else {
                outputData = ColorConversion.imageYCbCrToRGB(
                    y: yTrimmed, cb: cbUp, cr: crUp,
                    width: outW, height: outH
                )
            }
            outputColorModel = configuration.outputColorModel ?? .rgb
        }

        let outputPixelFormat = configuration.outputPixelFormat
            ?? (isExtendedPrecision ? .uint16 : .uint8)

        return try JLIImage(
            width: outW,
            height: outH,
            pixelFormat: outputPixelFormat,
            colorModel: outputColorModel,
            data: outputData,
            iccProfile: parsed.iccProfile,
            exif: parsed.exif
        )
    }

    // MARK: - Lossless (SOF3) decode

    /// Decodes a lossless (SOF3) JPEG by spatial prediction (ITU-T T.81 Annex H):
    /// each sample is predicted from already-decoded neighbours (selector 1–7 in
    /// the SOS `spectralStart`), and the Huffman-coded difference (DC mechanism,
    /// SSSS=16 ⇒ −32768 special case) is added back. Grayscale (1) or RGB (3,
    /// stored directly — no color transform, like libjpeg-turbo's lossless).
    private func decodeLossless(
        frame: JPEGFrameInfo, scans: [JPEGScanData], configuration: JLIDecoderConfiguration,
        restartInterval: Int = 0, iccProfile: [UInt8]? = nil, exif: [UInt8]? = nil
    ) throws -> JLIImage {
        let precision = frame.precision
        guard (2...16).contains(precision) else {
            throw JLIError.unsupportedJPEGFeature("lossless precision \(precision)")
        }
        // Lossless reconstructs exact integer samples; a float32 request here would
        // only be a lossy-looking convenience cast and is rejected so callers get
        // the bit-exact uint path (which already preserves every value exactly).
        guard configuration.outputPixelFormat != .float32 else {
            throw JLIError.unsupportedJPEGFeature(
                "float32 output for lossless (use the bit-exact .uint8/.uint16 output)")
        }
        let w = frame.width, h = frame.height
        guard w >= 1, h >= 1, w <= 65535, h <= 65535 else {
            throw JLIError.decodingFailed("invalid lossless dimensions \(w)×\(h)")
        }
        // Decompression-bomb guard: a tiny SOF can declare dimensions whose product
        // would force a multi-gigabyte plane allocation (an uncatchable OOM trap).
        // Cap total samples before allocating. See `maxDecodablePixels`.
        guard w * h <= JLIDecoder.maxDecodablePixels else {
            throw JLIError.decodingFailed(
                "lossless image too large: \(w)×\(h) exceeds \(JLIDecoder.maxDecodablePixels)-pixel limit")
        }
        let nc = frame.components.count
        guard nc == 1 || nc == 3 else {
            throw JLIError.unsupportedJPEGFeature("lossless \(nc)-component (only 1 or 3)")
        }
        for c in frame.components where c.horizontalSampling != 1 || c.verticalSampling != 1 {
            throw JLIError.unsupportedJPEGFeature("subsampled lossless")
        }
        guard let scan = scans.first else { throw JLIError.decodingFailed("no lossless scan") }
        let predictor = scan.header.spectralStart       // 1–7
        let pt = scan.header.successiveApproxLow         // point transform
        guard (1...7).contains(predictor) else {
            throw JLIError.decodingFailed("invalid lossless predictor \(predictor)")
        }
        // The point transform shifts the initial predictor by `precision-1-pt`; a
        // pt ≥ precision yields a negative shift count, which traps at runtime.
        // T.81 also constrains Pt < P for lossless. Reject out-of-range values
        // (a 4-bit Al field can carry 0–15) with a thrown error, never a trap.
        guard pt >= 0, pt < precision else {
            throw JLIError.decodingFailed("invalid lossless point transform \(pt) for precision \(precision)")
        }
        let dcTables = prepareDCTables(scan.dcTables)
        let tables = frame.components.map { fc -> HuffmanTable in
            let sc = scan.header.components.first { $0.componentSelector == fc.id }
            return dcTables[sc?.dcTableId ?? 0] ?? StandardHuffmanTables.dcLuminance
        }

        var reader = BitReader(data: scan.entropyData)
        let half = Int32(1 << (precision - 1 - pt))   // predictor for the very first sample
        let count = w * h

        // One flat raw buffer holds all component planes (plane c at offset
        // c·w·h): the previous nested-array form paid a retain/release plus an
        // outer-array _modify and inner-buffer uniqueness check on EVERY sample
        // — the dominant non-entropy cost of the clinical lossless path (and
        // `let p = planes[c]` aliased the buffer being written, a latent
        // full-plane-COW trap that only optimizer lifetime-shortening kept
        // benign). Uninitialized is safe: prediction reads only previously
        // written positions.
        let store = UnsafeMutableBufferPointer<Int32>.allocate(capacity: count * nc)
        defer { store.deallocate() }
        let base = store.baseAddress!

        // The scan workers are dedicated static functions (the same pattern as
        // the encoder's `trellisBlocks`): a compact hot loop is its own
        // optimization unit, so the entropy-decode chain stays within inlining
        // range, and `reader` is passed `inout` end-to-end — never captured by
        // a closure (a captured inout-mutated struct gets boxed with dynamic
        // exclusivity checks on every access).
        // Restart segmentation: row-aligned only (the constraint libjpeg-turbo
        // also enforces for lossless), so each segment's first row predicts with
        // scan-start semantics and segments are independently decodable. The
        // scan workers need no restart awareness: a worker invoked on a
        // segment's rows treats its first row as the \"first row\" (y == 0),
        // which IS the post-restart prediction state.
        var segRows = 0
        if restartInterval > 0 {
            guard restartInterval % w == 0 else {
                throw JLIError.unsupportedJPEGFeature(
                    "lossless restart interval \(restartInterval) not a multiple of "
                    + "samples-per-row (\(w))")
            }
            segRows = restartInterval / w
        }
        let numSegments = segRows > 0 ? (h + segRows - 1) / segRows : 1

        if numSegments <= 1 {
            if nc == 1 {
                try Self.losslessScanGray(base, width: w, height: h, predictor: predictor,
                                          half: half, table: tables[0], reader: &reader)
            } else {
                try Self.losslessScanRGB(base, width: w, height: h, count: count,
                                         predictor: predictor, half: half,
                                         tables: tables, reader: &reader)
            }
        } else {
            // Parallel fast path (the clinical grayscale case): locate the RST
            // markers up front (in entropy data a 0xFF is always followed by
            // 0x00 stuffing, 0xFF fill, or a real RST byte) and decode every
            // segment concurrently — each from its own reader and into its own
            // disjoint row range. Falls back to the serial segment loop when
            // the marker layout is anything but the expected one.
            var rstOffsets = [Int]()
            let ed = scan.entropyData
            var si = 0
            scanLoop: while si + 1 < ed.count {
                if ed[si] != 0xFF { si += 1; continue }
                switch ed[si + 1] {
                case 0x00: si += 2                                  // stuffed data byte
                case 0xFF: si += 1                                  // fill byte
                case 0xD0...0xD7: rstOffsets.append(si); si += 2    // restart marker
                default: break scanLoop                             // foreign marker — bail
                }
            }
            let parallelOK = nc == 1 && rstOffsets.count == numSegments - 1
                && count >= JLIDecoder.losslessSegmentParallelMinSamples
            if parallelOK {
                let table = tables[0]
                // Immutable snapshots for the @Sendable workers (the vars above
                // are never mutated past this point; the lets make that a
                // compiler-checked fact).
                let segRowsFinal = segRows
                let markers = rstOffsets
                var errors = [Error?](repeating: nil, count: numSegments)
                errors.withUnsafeMutableBufferPointer { eb in
                    let slots = LosslessSegmentSlots(errors: eb.baseAddress!, plane: base)
                    DispatchQueue.concurrentPerform(iterations: numSegments) { k in
                        let startRow = k * segRowsFinal
                        let rows = min(segRowsFinal, h - startRow)
                        var segReader = k == 0
                            ? BitReader(data: ed)
                            : BitReader(data: ed, startingAt: markers[k - 1] + 2)
                        do {
                            try Self.losslessScanGray(
                                slots.plane + startRow * w, width: w, height: rows,
                                predictor: predictor, half: half, table: table,
                                reader: &segReader)
                            // Behavioral equivalence with the serial path on
                            // CORRUPT input: serial's skipRestartMarker throws
                            // unless each segment ends exactly at its marker
                            // (modulo 0xFF fill). An under-consuming corrupt
                            // segment would otherwise be silently accepted here
                            // — wrong pixels returned as success on exactly the
                            // large clinical images this path targets.
                            if k < numSegments - 1 {
                                segReader.alignToByte()
                                var pos = segReader.byteOffset
                                while pos < markers[k], ed[pos] == 0xFF { pos += 1 }
                                guard pos == markers[k] else {
                                    throw JLIError.decodingFailed(
                                        "lossless restart segment \(k) ended at byte "
                                        + "\(segReader.byteOffset), expected RST at \(markers[k])")
                                }
                            }
                        } catch {
                            slots.errors[k] = error
                        }
                    }
                }
                if let e = errors.compactMap({ $0 }).first { throw e }
            } else {
                for k in 0..<numSegments {
                    if k > 0 { try reader.skipRestartMarker(expectedIndex: (k - 1) & 7) }
                    let startRow = k * segRows
                    let rows = min(segRows, h - startRow)
                    if nc == 1 {
                        try Self.losslessScanGray(
                            base + startRow * w, width: w, height: rows,
                            predictor: predictor, half: half, table: tables[0],
                            reader: &reader)
                    } else {
                        try Self.losslessScanRGB(
                            base + startRow * w, width: w, height: rows, count: count,
                            predictor: predictor, half: half, tables: tables,
                            reader: &reader)
                    }
                }
            }
        }

        // Interleave planes → output. 1 component = grayscale; 3 = RGB (direct).
        // Pointer loops over an uninitialized output buffer (every byte is
        // written); the inverse point-transform shift and clamping semantics
        // are unchanged.
        let model = configuration.outputColorModel ?? (nc == 1 ? .grayscale : .rgb)
        if precision <= 8 {
            var bytes = [UInt8](unsafeUninitializedCapacity: count * nc) { _, n in n = count * nc }
            bytes.withUnsafeMutableBufferPointer { bp in
                for c in 0..<nc {
                    let src = base + c * count
                    let dst = bp.baseAddress! + c
                    for i in 0..<count { dst[i * nc] = UInt8(clamping: Int(src[i]) << pt) }
                }
            }
            return try JLIImage(width: w, height: h,
                                pixelFormat: configuration.outputPixelFormat ?? .uint8,
                                colorModel: model, data: bytes,
                                iccProfile: iccProfile, exif: exif)
        }
        var bytes = [UInt8](unsafeUninitializedCapacity: count * nc * 2) { _, n in n = count * nc * 2 }
        bytes.withUnsafeMutableBufferPointer { bp in
            for c in 0..<nc {
                let src = base + c * count
                let dst = bp.baseAddress! + c * 2
                for i in 0..<count {
                    let v = UInt16(clamping: Int(src[i]) << pt)
                    dst[i * nc * 2] = UInt8(v & 0xFF)
                    dst[i * nc * 2 + 1] = UInt8(v >> 8)
                }
            }
        }
        return try JLIImage(width: w, height: h,
                            pixelFormat: configuration.outputPixelFormat ?? .uint16,
                            colorModel: model, data: bytes,
                            iccProfile: iccProfile, exif: exif)
    }

    /// Minimum block count before Step-7 reconstruction fans out across cores;
    /// below a few thousand blocks the dispatch overhead wins. Lock-protected
    /// because the serial/parallel equality tests mutate it while other tests
    /// may decode concurrently — both gate values are behaviorally equivalent
    /// (that's what the tests prove), but the access must not be a data race.
    /// No production code mutates it.
    static var reconstructMinBlocksPerChunk: Int {
        get { gateLock.lock(); defer { gateLock.unlock() }; return _reconstructMinBlocksPerChunk }
        set { gateLock.lock(); defer { gateLock.unlock() }; _reconstructMinBlocksPerChunk = newValue }
    }

    /// Minimum pixel count before a restart-segmented lossless scan decodes its
    /// segments concurrently. Same locking rationale as
    /// ``reconstructMinBlocksPerChunk``.
    static var losslessSegmentParallelMinSamples: Int {
        get { gateLock.lock(); defer { gateLock.unlock() }; return _losslessSegmentParallelMinSamples }
        set { gateLock.lock(); defer { gateLock.unlock() }; _losslessSegmentParallelMinSamples = newValue }
    }
    private static let gateLock = NSLock()
    nonisolated(unsafe) private static var _reconstructMinBlocksPerChunk = 2048
    nonisolated(unsafe) private static var _losslessSegmentParallelMinSamples = 1 << 16

    /// `@unchecked Sendable` carrier for segment-parallel lossless decode:
    /// worker `k` writes only its segment's disjoint row range of `plane` and
    /// its own `errors` slot.
    private struct LosslessSegmentSlots: @unchecked Sendable {
        let errors: UnsafeMutablePointer<Error?>
        let plane: UnsafeMutablePointer<Int32>
    }

    /// `@unchecked Sendable` carrier for parallel Step-7 reconstruction: each
    /// worker reads the shared `zz`/`qt` and writes only its own block range's
    /// subranges of `px`/`scratch` plus the disjoint plane tiles of its blocks.
    private struct ReconstructPtrs: @unchecked Sendable {
        let zz: UnsafePointer<Int32>
        let qt: UnsafePointer<Float>
        let px: UnsafeMutablePointer<Float>
        let scratch: UnsafeMutablePointer<Float>
        let plane: UnsafeMutablePointer<Float>
    }

    /// Reconstructs `blocks` of one component: fused dequant+IDCT (bit-identical
    /// to the separate passes — same convert and multiply per element), level
    /// shift + clamp, then a per-row memcpy scatter of each block's in-bounds
    /// region into the component-sized plane. Callable on any disjoint block
    /// range; block tiles never overlap, so partitioning is race-free.
    private static func reconstructBlocks(
        _ blocks: Range<Int>, ptrs: ReconstructPtrs, blocksH: Int,
        compWidth: Int, compHeight: Int, precision: Int
    ) {
        let m = blocks.count
        guard m > 0 else { return }
        let base = blocks.lowerBound
        let px = ptrs.px + base * 64
        AccelerateDSP.inverseDCTBatchDequantized(
            zigzag: ptrs.zz + base * 64, quantTable: ptrs.qt,
            output: px, scratch: ptrs.scratch + base * 64, blockCount: m)

        // Level shift +2^(P-1) + clamp [0, 2^P-1] — 128/255 for 8-bit,
        // 2048/4095 for 12-bit; per-element ops, so chunking changes nothing.
        var center = Float(1 << (precision - 1))
        var lo: Float = 0.0, hi = Float((1 << precision) - 1)
        let n = vDSP_Length(m * 64)
        vDSP_vsadd(px, 1, &center, px, 1, n)
        vDSP_vclip(px, 1, &lo, &hi, px, 1, n)

        for bi in 0..<m {
            let b = base + bi
            let startX = (b % blocksH) * 8
            let startY = (b / blocksH) * 8
            // MCU geometry can pad subsampled components past the component's
            // actual extent (e.g. a 4:2:0 luma grid rounded up to even blocks on
            // a tiny image) — such blocks decode but land entirely outside the
            // exact-size plane and must be skipped, never clamped negative.
            guard startX < compWidth, startY < compHeight else { continue }
            let blockBase = bi * 64
            let runW = min(8, compWidth - startX)
            for y in 0..<8 {
                let py = startY + y
                if py >= compHeight { break }
                memcpy(ptrs.plane + py * compWidth + startX,
                       px + blockBase + y * 8,
                       runW * MemoryLayout<Float>.size)
            }
        }
    }

    /// Grayscale (single-component) lossless scan — the clinical hot loop.
    /// Straight-line per-sample body: predict (edge cases first, then the
    /// fixed-per-scan selector switch, which the branch predictor learns),
    /// Huffman category + magnitude bits, accumulate modulo 2^16 (T.81) in the
    /// point-transformed domain, write through the raw plane pointer.
    private static func losslessScanGray(
        _ p: UnsafeMutablePointer<Int32>, width w: Int, height h: Int,
        predictor: Int, half: Int32, table: HuffmanTable, reader: inout BitReader
    ) throws {
        for y in 0..<h {
            let row = y * w, prevRow = row - w
            for x in 0..<w {
                let px: Int32
                if x == 0 {
                    px = y == 0 ? half : p[prevRow]                    // Rb (or initial)
                } else if y == 0 {
                    px = p[row + x - 1]                                // Ra
                } else {
                    let ra = p[row + x - 1], rb = p[prevRow + x], rc = p[prevRow + x - 1]
                    switch predictor {
                    case 1: px = ra
                    case 2: px = rb
                    case 3: px = rc
                    case 4: px = ra + rb - rc
                    case 5: px = ra + ((rb - rc) >> 1)
                    case 6: px = rb + ((ra - rc) >> 1)
                    default: px = (ra + rb) >> 1                       // 7
                    }
                }
                let cat = Int(try HuffmanDecoder.decodeSymbol(from: &reader, table: table))
                let diff: Int32
                if cat == 0 { diff = 0 }
                else if cat == 16 { diff = -32768 }                    // T.81 special case
                else { diff = try HuffmanDecoder.decodeValue(from: &reader, category: cat) }
                p[row + x] = (px + diff) & 0xFFFF
            }
        }
    }

    /// One interleaved-component lossless sample: predict, decode, accumulate.
    /// Static (capture-free) so the three per-pixel calls in the RGB scan carry
    /// no closure context.
    @inline(__always)
    private static func losslessSample(
        _ p: UnsafeMutablePointer<Int32>, _ t: HuffmanTable,
        _ x: Int, _ y: Int, _ row: Int, _ prevRow: Int,
        _ predictor: Int, _ half: Int32, _ reader: inout BitReader
    ) throws {
        let px: Int32
        if x == 0 {
            px = y == 0 ? half : p[prevRow]
        } else if y == 0 {
            px = p[row + x - 1]
        } else {
            let ra = p[row + x - 1], rb = p[prevRow + x], rc = p[prevRow + x - 1]
            switch predictor {
            case 1: px = ra
            case 2: px = rb
            case 3: px = rc
            case 4: px = ra + rb - rc
            case 5: px = ra + ((rb - rc) >> 1)
            case 6: px = rb + ((ra - rc) >> 1)
            default: px = (ra + rb) >> 1
            }
        }
        let cat = Int(try HuffmanDecoder.decodeSymbol(from: &reader, table: t))
        let diff: Int32
        if cat == 0 { diff = 0 }
        else if cat == 16 { diff = -32768 }
        else { diff = try HuffmanDecoder.decodeValue(from: &reader, category: cat) }
        p[row + x] = (px + diff) & 0xFFFF
    }

    /// Three-component (RGB) lossless scan: components interleaved per sample
    /// (1×1 sampling), each with its own plane pointer and Huffman table.
    private static func losslessScanRGB(
        _ base: UnsafeMutablePointer<Int32>, width w: Int, height h: Int, count: Int,
        predictor: Int, half: Int32, tables: [HuffmanTable], reader: inout BitReader
    ) throws {
        let t0 = tables[0], t1 = tables[1], t2 = tables[2]
        let p0 = base, p1 = base + count, p2 = base + 2 * count
        for y in 0..<h {
            let row = y * w, prevRow = row - w
            for x in 0..<w {
                try losslessSample(p0, t0, x, y, row, prevRow, predictor, half, &reader)
                try losslessSample(p1, t1, x, y, row, prevRow, predictor, half, &reader)
                try losslessSample(p2, t2, x, y, row, prevRow, predictor, half, &reader)
            }
        }
    }

    // MARK: - Private Helpers

    /// Separable contraction matrix `A` (size `bs × 8`, `bs = 8/scale`, row-major)
    /// that turns an 8×8 block of dequantized DCT coefficients `F` into its
    /// `bs × bs` box-averaged tile via `out = A · F · Aᵀ`. Row `I` averages the
    /// 8-point inverse-DCT basis over the `scale` source positions of output `I`:
    /// `A[I,u] = ½·C(u)·(1/scale)·Σ_{x∈box_I} cos((2x+1)uπ/16)`, `C(0)=1/√2`.
    /// This is an exact (not approximate) mean of the full-IDCT output over each
    /// `scale × scale` box, matching the DC-only `scale == 8` case when `bs == 1`.
    private static func boxAverageMatrix(scale: Int) -> [Float] {
        let bs = 8 / scale
        var a = [Float](repeating: 0, count: bs * 8)
        for capI in 0..<bs {
            for u in 0..<8 {
                let cu = u == 0 ? (1.0 / 2.0.squareRoot()) : 1.0
                var s = 0.0
                for x in (capI * scale)..<(capI * scale + scale) {
                    s += cos((Double(2 * x + 1) * Double(u) * Double.pi) / 16.0)
                }
                a[capI * 8 + u] = Float(0.5 * cu * (s / Double(scale)))
            }
        }
        return a
    }

    /// DC Huffman tables keyed by table id, with standard tables filled in for
    /// ids 0/1. Keyed (not positional) so a scan referencing any 4-bit table id
    /// (0–15) resolves with a fallback instead of indexing past a fixed array.
    private func prepareDCTables(_ parsed: [Int: HuffmanTable]) -> [Int: HuffmanTable] {
        var tables = parsed
        if tables[0] == nil { tables[0] = StandardHuffmanTables.dcLuminance }
        if tables[1] == nil { tables[1] = StandardHuffmanTables.dcChrominance }
        return tables
    }

    /// Serializes a sample plane (already interleaved if multi-component) to a
    /// 32-bit **little-endian** float byte buffer for `.float32` output — the raw
    /// reconstructed sample values, with no rounding or normalization.
    static func floatsToLE(_ values: [Float]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: values.count * 4)
        out.withUnsafeMutableBytes { dst in
            for (i, v) in values.enumerated() {
                let bits = v.bitPattern   // IEEE-754; store little-endian
                dst[i * 4]     = UInt8(bits & 0xFF)
                dst[i * 4 + 1] = UInt8((bits >> 8) & 0xFF)
                dst[i * 4 + 2] = UInt8((bits >> 16) & 0xFF)
                dst[i * 4 + 3] = UInt8((bits >> 24) & 0xFF)
            }
        }
        return out
    }

    /// AC Huffman tables keyed by table id, with standard tables filled in for
    /// ids 0/1. See ``prepareDCTables(_:)``.
    private func prepareACTables(_ parsed: [Int: HuffmanTable]) -> [Int: HuffmanTable] {
        var tables = parsed
        if tables[0] == nil { tables[0] = StandardHuffmanTables.acLuminance }
        if tables[1] == nil { tables[1] = StandardHuffmanTables.acChrominance }
        return tables
    }

    /// Absolute upper bound on the number of samples (width × height) the decoder
    /// will allocate planes for, regardless of the per-dimension 65535 cap. This is
    /// a decompression-bomb / denial-of-service guard: a tiny crafted header must
    /// not be able to force a multi-gigabyte allocation (an uncatchable OOM trap).
    /// 268,435,456 (2^28 ≈ 268 MP) comfortably exceeds any diagnostic radiology
    /// image (mammography ~24 MP, large DX ~16 MP) while blocking the 4.29e9-pixel
    /// worst case the SOF fields would otherwise permit.
    static let maxDecodablePixels = 1 << 28

    /// Rejects structurally-invalid frames that the decode pipeline cannot
    /// handle without trapping — malformed input (e.g. JPEG-in-DICOM from an
    /// untrusted source) must fail with a thrown ``JLIError``, never a crash.
    private func validateDecodable(_ frame: JPEGFrameInfo, quantTableCount: Int) throws {
        // Precision drives the level shift `1 << (precision-1)`, which traps for
        // precision 0; we only decode 8-bit (color/gray) and 12-bit (gray).
        guard frame.precision == 8 || frame.precision == 12 else {
            throw JLIError.unsupportedJPEGFeature(
                "sample precision \(frame.precision) (only 8 and 12 supported)")
        }
        // Dimensions: positive and within the 16-bit SOF field range. Zero width
        // or height would divide by zero when computing the MCU grid.
        guard frame.width >= 1, frame.height >= 1,
              frame.width <= 65535, frame.height <= 65535 else {
            throw JLIError.decodingFailed("invalid image dimensions \(frame.width)×\(frame.height)")
        }
        // Decompression-bomb guard: the 16-bit SOF fields permit up to ~4.29e9
        // pixels, whose coefficient/scratch planes would OOM-trap from a ~20-byte
        // header. Reject anything beyond `maxDecodablePixels` before allocating.
        guard frame.width * frame.height <= JLIDecoder.maxDecodablePixels else {
            throw JLIError.decodingFailed(
                "image too large: \(frame.width)×\(frame.height) exceeds \(JLIDecoder.maxDecodablePixels)-pixel limit")
        }
        // Only grayscale (1) and YCbCr (3) layouts are decodable; the color path
        // assumes exactly three planes (Y, Cb, Cr).
        guard frame.components.count == 1 || frame.components.count == 3 else {
            throw JLIError.unsupportedJPEGFeature(
                "\(frame.components.count)-component JPEG (only 1 or 3 supported)")
        }
        for comp in frame.components {
            // Sampling factors are 1–4 per T.81; a zero factor zeroes the max and
            // divides by zero in the MCU-grid math.
            guard (1...4).contains(comp.horizontalSampling),
                  (1...4).contains(comp.verticalSampling) else {
                throw JLIError.decodingFailed("invalid sampling factor for component \(comp.id)")
            }
            // The component must reference a quant table that was actually defined.
            guard comp.quantTableIndex >= 0, comp.quantTableIndex < quantTableCount else {
                throw JLIError.decodingFailed(
                    "component \(comp.id) references undefined quant table \(comp.quantTableIndex)")
            }
        }
    }
}
