// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.
// Isis modifications are recorded in Git.

import Accelerate
import Foundation

/// The jpegli-compatible JPEG encoder.
///
/// `JLIEncoder` compresses image data into JPEG format using the jpegli algorithm,
/// providing up to 35% better compression ratios compared to traditional JPEG encoders
/// while maintaining full backward compatibility.
///
/// The encoder supports baseline sequential JPEG with all standard chroma subsampling
/// modes (4:4:4, 4:2:2, 4:2:0, 4:0:0). Floating-point DCT precision is used throughout
/// the pipeline, matching the jpegli approach for higher fidelity.
///
/// ## Usage
///
/// ```swift
/// let encoder = JLIEncoder()
/// let jpegData = try encoder.encode(image, configuration: .default)
/// ```
public struct JLIEncoder: Sendable {
    /// Creates a new encoder instance.
    public init() {}

    /// Rate-distortion λ is `rdoLambdaK · meanACQuant²`. Tying λ to the
    /// quantization step (R-D theory: λ ∝ Q²) keeps truncation gentle at high
    /// quality (small Q, where surviving coefficients are perceptually real) and
    /// firmer at low quality (large Q). Tuned on the DICOM corpus so bytes drop
    /// without raising butteraugli at either end of the quality range.
    static let rdoLambdaK = 0.004

    /// Blocks with more than this many nonzero AC coefficients skip the O(m²)
    /// trellis DP (they're high-entropy — little to gain from dropping, and the
    /// runtime cost is steep). Bounds worst-case encode time on noisy content.
    static let trellisMaxNonzeros = 32

    /// Trellis magnitude reduction (q→q∓1) is only considered for zigzag
    /// positions ≥ this — reducing the lowest AC frequencies costs visible
    /// quality (butteraugli) for negligible rate; HF reduction is near-free.
    static let trellisReduceMinZigzag = 6

    /// Trellis blocks are partitioned across CPU cores only when each worker gets
    /// at least this many — below it, thread-dispatch overhead outweighs the
    /// per-block DP savings, so the pass runs serially. Each worker owns its
    /// scratch and writes a disjoint block range, so output is byte-identical
    /// regardless of how many threads run.
    static let trellisMinBlocksPerChunk = 2048

    /// Minimum blocks per worker for parallel AC-frequency counting. AC counting
    /// is order-independent (frequencies commute) and carries no cross-block
    /// state, so partitioning a flat block range and summing the partial
    /// histograms is bit-identical to the serial count; this just gates when the
    /// thread-dispatch cost is worth paying. (DC counting stays serial — its
    /// predictor chain is cheap and order-dependent.)
    static let acCountMinBlocksPerChunk = 8192

    /// Encodes an image to JPEG data using the jpegli algorithm.
    ///
    /// - Parameters:
    ///   - image: The source image. `.uint8` (8-bit), `.uint16` (12-bit), or
    ///     `.float32` (treated as normalised [0,1] and quantised to 8-bit).
    ///   - configuration: Encoder settings controlling quality, color space, and features.
    /// - Returns: The encoded JPEG data as a byte array.
    /// - Throws: ``JLIError`` if encoding fails or the input is invalid.
    public func encode(
        _ image: JLIImage,
        configuration: JLIEncoderConfiguration = .default
    ) throws -> [UInt8] {
        try validateConfiguration(configuration)

        // float32 input is treated as normalised [0,1] and quantised to 8-bit up
        // front (the DCT pipeline works in 8/12-bit integer samples), then encoded
        // by the normal path. Use `.uint16` for 12-bit precision.
        if image.pixelFormat == .float32 {
            return try encode(quantizeFloat32ToUInt8(image), configuration: configuration)
        }

        let width = image.width
        let height = image.height
        // The distance parameter (jpegli/JPEG-XL convention) overrides quality
        // when set: it's mapped to an effective IJG quality that scales the
        // standard quant tables.
        let effectiveQuality: Double
        if let distance = configuration.distance {
            effectiveQuality = Quantization.qualityForDistance(distance)
        } else {
            effectiveQuality = configuration.quality
        }
        let quality = max(1, min(100, Int(effectiveQuality.rounded())))

        // Sample precision: 8-bit for uint8, 12-bit for uint16 (JPEG supports 8
        // or 12). Level shift is 2^(P-1): 128 or 2048. (float32 was quantized to
        // uint8 above, so it never reaches here.)
        let precision: Int
        switch image.pixelFormat {
        case .uint8:
            precision = 8
        case .uint16:
            precision = 12
        case .float32:
            throw JLIError.unsupportedJPEGFeature("float32 must be quantized before encoding")
        }
        let levelShift = Float(1 << (precision - 1))

        // Determine if encoding as grayscale
        let isGrayscale = image.colorModel == .grayscale
            || configuration.chromaSubsampling == .yuv400

        // Lossless (SOF3) is a predictive mode — fully separate from the DCT path.
        if configuration.lossless {
            // Lossless supports up to 16-bit; precision 0 = derive from pixel format.
            let llPrecision = configuration.losslessPrecision > 0
                ? configuration.losslessPrecision : precision
            guard (2...16).contains(llPrecision) else {
                throw JLIError.unsupportedJPEGFeature("lossless precision \(llPrecision) (2–16)")
            }
            guard llPrecision <= 8 || image.pixelFormat == .uint16 else {
                throw JLIError.unsupportedColorSpaceConversion(
                    from: "\(image.pixelFormat) at \(llPrecision)-bit",
                    to: ">8-bit lossless (requires .uint16 input)")
            }
            return try encodeLossless(image, configuration: configuration,
                                      precision: llPrecision, isGrayscale: isGrayscale)
        }

        // Signed integer samples (e.g. signed CT Hounsfield, DICOM
        // PixelRepresentation == 1) are only well-defined on the lossless path,
        // which preserves the exact sample bytes. The DCT path level-shifts as if
        // unsigned and would silently corrupt negative values (or emit an
        // undecodable stream), so reject signed input here rather than guess.
        // Encode signed data losslessly, or offset it to unsigned before lossy
        // encoding.
        if image.isSigned {
            throw JLIError.unsupportedJPEGFeature(
                "signed pixel data on the lossy DCT path (encode losslessly, or offset to unsigned first)")
        }

        // XYB perceptual color (SOF0): RGB → XYB samples → perceptual quant, 4:4:4,
        // with an embedded ICC so standard ICC-aware decoders display correct
        // color. 8-bit color only (the XYB sample scaling is calibrated for 8-bit).
        if configuration.colorSpace == .xyb && !isGrayscale && precision == 8 {
            guard image.colorModel == .rgb || image.colorModel == .rgba else {
                throw JLIError.unsupportedColorSpaceConversion(
                    from: "\(image.colorModel)", to: "XYB JPEG (use RGB/RGBA input)")
            }
            let distance = configuration.distance
                ?? Quantization.distanceForQuality(configuration.quality)
            return try encodeXYB(image, configuration: configuration, distance: distance)
        }

        // 12-bit color is supported for RGB/RGBA input. Pre-converted 12-bit
        // YCbCr input isn't — the direct-extract path below assumes 8-bit samples.
        if precision > 8 && !isGrayscale && image.colorModel == .yCbCr {
            throw JLIError.unsupportedColorSpaceConversion(
                from: "12-bit pre-converted YCbCr", to: "JPEG (use RGB/RGBA input for 12-bit color)"
            )
        }

        // 12-bit DC/AC coefficients exceed the categories the fixed Annex K
        // Huffman tables define (0–11), so optimal per-image tables are required.
        let optimiseHuffman = configuration.optimiseHuffman || precision > 8

        // Reads a grayscale sample at pixel index `i`, honoring bit depth.
        // uint16 data is little-endian 2 bytes/sample.
        func graySample(_ data: [UInt8], _ i: Int) -> Float {
            if precision == 8 { return Float(data[i]) }
            return Float(UInt16(data[i * 2]) | (UInt16(data[i * 2 + 1]) << 8))
        }

        // Step 1: Extract component planes (Float, 0–maxSample range)
        let yPlane: [Float]
        var cbPlane: [Float]
        var crPlane: [Float]

        if isGrayscale {
            if image.colorModel == .grayscale {
                let pixelCount = width * height
                var y = [Float](repeating: 0, count: pixelCount)
                for i in 0..<pixelCount { y[i] = graySample(image.data, i) }
                yPlane = y
            } else {
                let planes = ColorConversion.imageRGBToYCbCr(
                    data: image.data, width: width, height: height,
                    componentCount: image.colorModel.componentCount
                )
                yPlane = planes.y
            }
            cbPlane = []
            crPlane = []
        } else {
            guard image.colorModel == .rgb || image.colorModel == .rgba
                || image.colorModel == .yCbCr
            else {
                throw JLIError.unsupportedColorSpaceConversion(
                    from: "\(image.colorModel)", to: "JPEG YCbCr"
                )
            }

            if image.colorModel == .yCbCr {
                // Already in YCbCr — extract planes directly
                let cc = image.colorModel.componentCount
                let pixelCount = width * height
                var y = [Float](repeating: 0, count: pixelCount)
                var cb = [Float](repeating: 0, count: pixelCount)
                var cr = [Float](repeating: 0, count: pixelCount)
                for i in 0..<pixelCount {
                    y[i] = Float(image.data[i * cc])
                    cb[i] = Float(image.data[i * cc + 1])
                    cr[i] = Float(image.data[i * cc + 2])
                }
                yPlane = y; cbPlane = cb; crPlane = cr
            } else if precision == 12 {
                // 12-bit color: little-endian UInt16 RGB(A), chroma centered at
                // the level-shift value (2^(P-1) = 2048).
                let planes = ColorConversion.imageRGB16ToYCbCr(
                    data: image.data, width: width, height: height,
                    componentCount: image.colorModel.componentCount, center: levelShift
                )
                yPlane = planes.y
                cbPlane = planes.cb
                crPlane = planes.cr
            } else {
                let planes = ColorConversion.imageRGBToYCbCr(
                    data: image.data, width: width, height: height,
                    componentCount: image.colorModel.componentCount
                )
                yPlane = planes.y
                cbPlane = planes.cb
                crPlane = planes.cr
            }
        }

        // Step 2: Chroma downsampling
        let subsampling = isGrayscale ? JLIChromaSubsampling.yuv400
            : configuration.chromaSubsampling
        let (hFactor, vFactor) = ChromaSampling.samplingFactors(for: subsampling)

        var cbWidth = width, cbHeight = height
        var crWidth = width, crHeight = height

        if !isGrayscale && (hFactor > 1 || vFactor > 1) {
            let cbDS = ChromaSampling.downsample(
                cbPlane, width: width, height: height,
                horizontally: hFactor > 1, vertically: vFactor > 1
            )
            cbPlane = cbDS.data; cbWidth = cbDS.width; cbHeight = cbDS.height

            let crDS = ChromaSampling.downsample(
                crPlane, width: width, height: height,
                horizontally: hFactor > 1, vertically: vFactor > 1
            )
            crPlane = crDS.data; crWidth = crDS.width; crHeight = crDS.height
        }

        // Step 3: Quantization tables (and reciprocals for vectorized quantization).
        // jpegli's perceptual model derives tables straight from the Butteraugli
        // distance (8-bit YCbCr only); otherwise scale the Annex K tables by the
        // IJG quality. 12-bit stays on the Annex K path (exact medical precision).
        let lumQT: [Int]
        let chromQT: [Int]
        if configuration.perceptualQuantTables && precision == 8 {
            let distance = configuration.distance
                ?? Quantization.distanceForQuality(configuration.quality)
            let is420 = !isGrayscale && configuration.chromaSubsampling == .yuv420
            lumQT = Quantization.perceptualQuantTable(distance: distance, chroma: false, isYUV420: is420)
            chromQT = Quantization.perceptualQuantTable(distance: distance, chroma: true, isYUV420: is420)
        } else {
            lumQT = Quantization.scaleTable(Quantization.standardLuminanceTable, quality: quality)
            chromQT = Quantization.scaleTable(Quantization.standardChrominanceTable, quality: quality)
        }
        let lumInv = lumQT.map { 1.0 / Float($0) }
        let chromInv = chromQT.map { 1.0 / Float($0) }

        // jpegli adaptive-quant (field + zero-bias) path — opt-in, replaces
        // trellis for the 8-bit YCbCr DCT components (WS-A / 0.3.0).
        let jpegliAQ = configuration.jpegliAdaptiveQuant && precision == 8
        let aqDistance = configuration.distance ?? Quantization.distanceForQuality(configuration.quality)
        let yQuant01 = lumQT.count > 1 ? lumQT[1] : 16

        // Rate-distortion (EOB) optimization, gated by `adaptiveQuantization`.
        // 8-bit only: 12-bit is the medical-precision path where we deliberately
        // keep exact round-to-nearest rather than trade detail for bytes.
        // λ trades DCT-domain squared error (= pixel² by Parseval) against bits,
        // scaled by the mean AC quant step² (see `rdoLambdaK`).
        let useRDO = configuration.adaptiveQuantization && precision == 8
        func meanACSq(_ table: [Int]) -> Double {
            var sum = 0.0
            for i in 1..<64 { sum += Double(table[i]) * Double(table[i]) }
            return sum / 63.0
        }
        let lumRDO = useRDO
            ? RDOContext(quantTable: lumQT, acTable: StandardHuffmanTables.acLuminance,
                         lambda: JLIEncoder.rdoLambdaK * meanACSq(lumQT))
            : nil
        let chrRDO = useRDO
            ? RDOContext(quantTable: chromQT, acTable: StandardHuffmanTables.acChrominance,
                         lambda: JLIEncoder.rdoLambdaK * meanACSq(chromQT))
            : nil

        // Step 4: MCU structure
        let hMax = isGrayscale ? 1 : hFactor
        let vMax = isGrayscale ? 1 : vFactor
        let mcuW = hMax * 8
        let mcuH = vMax * 8
        let mcuCountH = (width + mcuW - 1) / mcuW
        let mcuCountV = (height + mcuH - 1) / mcuH

        // Step 5: Extract → batch-DCT → batch-quantize for each component, then
        // walk MCUs sequentially to emit Huffman bits (DC DPCM forces sequential).
        let numComponents = isGrayscale ? 1 : 3
        let yBlocksPerRow = mcuCountH * hMax
        let yBlocksPerCol = mcuCountV * vMax
        let yBlockCount = yBlocksPerRow * yBlocksPerCol
        let cBlockCount = isGrayscale ? 0 : mcuCountH * mcuCountV

        // Scratch sized for the largest component batch — reused across Y/Cb/Cr.
        let maxBlockCount = max(yBlockCount, cBlockCount)
        var dctScratch = [Float](repeating: 0, count: maxBlockCount * 64)

        // jpegli's masking field is computed once on the luma plane and reused
        // (mapped) for every component.
        let lumaField: [Float] = jpegliAQ
            ? JLIAdaptiveQuant.computeField(
                plane: yPlane, planeWidth: width, planeHeight: height,
                blocksH: yBlocksPerRow, blocksV: yBlocksPerCol, yQuant01: yQuant01)
            : []
        func aqParams(_ c: Int) -> JpegliAQ? {
            jpegliAQ ? JpegliAQ(component: c, distance: aqDistance, lumaField: lumaField,
                                lumaBlocksH: yBlocksPerRow, lumaBlocksV: yBlocksPerCol) : nil
        }

        let yQuant = quantizePlane(
            yPlane, planeWidth: width, planeHeight: height,
            blocksH: yBlocksPerRow, blocksV: yBlocksPerCol,
            invQuant: lumInv, levelShift: levelShift, scratch: &dctScratch,
            rdo: jpegliAQ ? nil : lumRDO,
            adaptiveField: configuration.adaptiveQuantField,
            jpegli: aqParams(0)
        )
        let cbQuant: [Int32]
        let crQuant: [Int32]
        if isGrayscale {
            cbQuant = []; crQuant = []
        } else {
            cbQuant = quantizePlane(
                cbPlane, planeWidth: cbWidth, planeHeight: cbHeight,
                blocksH: mcuCountH, blocksV: mcuCountV,
                invQuant: chromInv, levelShift: levelShift, scratch: &dctScratch,
                rdo: jpegliAQ ? nil : chrRDO,
                jpegli: aqParams(1)
            )
            crQuant = quantizePlane(
                crPlane, planeWidth: crWidth, planeHeight: crHeight,
                blocksH: mcuCountH, blocksV: mcuCountV,
                invQuant: chromInv, levelShift: levelShift, scratch: &dctScratch,
                rdo: jpegliAQ ? nil : chrRDO,
                jpegli: aqParams(2)
            )
        }

        // Step 6: Assemble JPEG bitstream. Shared prefix: SOI, APP0, DQT.
        var mw = MarkerWriter()
        mw.writeSOI()
        mw.writeAPP0()
        if let exif = image.exif { mw.writeAPP1Exif(exif) }
        if let icc = image.iccProfile { mw.writeAPP2ICC(icc) }
        let lumZZ = zigzagQuantTable(lumQT)
        if isGrayscale {
            mw.writeDQT(tables: [(id: 0, values: lumZZ)])
        } else {
            mw.writeDQT(tables: [(id: 0, values: lumZZ),
                                 (id: 1, values: zigzagQuantTable(chromQT))])
        }

        let sofComponents: [(id: UInt8, hSampling: Int, vSampling: Int, quantTableId: Int)] =
            isGrayscale
            ? [(1, 1, 1, 0)]
            : [(1, hMax, vMax, 0), (2, 1, 1, 1), (3, 1, 1, 1)]

        if configuration.progressive {
            // Progressive (SOF2): DC scan + per-component AC scans, optimal tables.
            mw.writeSOF(progressive: true, precision: precision, width: width, height: height,
                        components: sofComponents)
            let compInfos: [JPEGComponentInfo] = isGrayscale
                ? [JPEGComponentInfo(id: 1, horizontalSampling: 1, verticalSampling: 1, quantTableIndex: 0)]
                : [JPEGComponentInfo(id: 1, horizontalSampling: hMax, verticalSampling: vMax, quantTableIndex: 0),
                   JPEGComponentInfo(id: 2, horizontalSampling: 1, verticalSampling: 1, quantTableIndex: 1),
                   JPEGComponentInfo(id: 3, horizontalSampling: 1, verticalSampling: 1, quantTableIndex: 1)]
            let quantArrays = isGrayscale ? [yQuant] : [yQuant, cbQuant, crQuant]
            let bpr = isGrayscale ? [yBlocksPerRow] : [yBlocksPerRow, mcuCountH, mcuCountH]
            let rW = compInfos.map { (width * $0.horizontalSampling + hMax - 1) / hMax }
                .map { ($0 + 7) / 8 }
            let rH = compInfos.map { (height * $0.verticalSampling + vMax - 1) / vMax }
                .map { ($0 + 7) / 8 }
            var prog = ProgressiveEncoder(
                components: compInfos, isGrayscale: isGrayscale,
                mcuCountH: mcuCountH, mcuCountV: mcuCountV,
                blocksPerRow: bpr, realBlocksW: rW, realBlocksH: rH,
                quant: quantArrays
            )
            prog.restartInterval = configuration.restartInterval
            // DRI applies to every subsequent scan; emit once before the first.
            if configuration.restartInterval > 0 {
                mw.writeDRI(interval: configuration.restartInterval)
            }
            for scan in prog.build(mode: configuration.progressiveMode) {
                if !scan.dht.isEmpty { mw.writeDHT(tables: scan.dht) }
                mw.writeSOS(components: scan.sosComponents,
                            spectralStart: scan.ss, spectralEnd: scan.se,
                            successiveApproxHigh: scan.ah, successiveApproxLow: scan.al)
                mw.writeEntropyData(scan.entropy)
            }
            mw.writeEOI()
            return mw.data
        }

        // Baseline path below.
        // Step 5b: Select Huffman tables. With `optimiseHuffman`, run a counting
        // pass over the exact MCU walk the emit pass uses (DC DPCM state must
        // match) to gather per-image symbol frequencies, then build optimal
        // tables. Otherwise use the fixed Annex K tables.
        let dcLumTable: HuffmanTable
        let acLumTable: HuffmanTable
        let dcChrTable: HuffmanTable
        let acChrTable: HuffmanTable

        if optimiseHuffman {
            var dcLumFreq = [Int](repeating: 0, count: 256)
            var dcChrFreq = [Int](repeating: 0, count: 256)
            var prevDC = [Int32](repeating: 0, count: numComponents)
            // DC counting: serial MCU walk — the DC predictor chain is
            // order-dependent and resets at restart boundaries, exactly as the
            // emit pass does (else the table lacks codes for post-reset diffs).
            // It's cheap (one diff/block); AC counting is the heavy part and is
            // parallelized separately below.
            var countMCU = 0
            for mcuY in 0..<mcuCountV {
                for mcuX in 0..<mcuCountH {
                    if configuration.restartInterval > 0 && countMCU > 0
                        && countMCU % configuration.restartInterval == 0 {
                        for i in 0..<numComponents { prevDC[i] = 0 }
                    }
                    countMCU += 1
                    for by in 0..<vMax {
                        for bx in 0..<hMax {
                            let yIdx = (mcuY * vMax + by) * yBlocksPerRow + (mcuX * hMax + bx)
                            let dc = yQuant[yIdx * 64]
                            HuffmanEncoder.countDC(dc - prevDC[0], freq: &dcLumFreq)
                            prevDC[0] = dc
                        }
                    }
                    if !isGrayscale {
                        let cIdx = mcuY * mcuCountH + mcuX
                        let cb = cbQuant[cIdx * 64]
                        HuffmanEncoder.countDC(cb - prevDC[1], freq: &dcChrFreq)
                        prevDC[1] = cb
                        let cr = crQuant[cIdx * 64]
                        HuffmanEncoder.countDC(cr - prevDC[2], freq: &dcChrFreq)
                        prevDC[2] = cr
                    }
                }
            }

            // AC counting: order-independent, so count over flat block ranges in
            // parallel and sum — the same multiset of blocks the emit walk visits.
            let acLumFreq = JLIEncoder.parallelACFreqs(yQuant, blockCount: yBlockCount)
            var acChrFreq = [Int](repeating: 0, count: 256)
            if !isGrayscale {
                let cbF = JLIEncoder.parallelACFreqs(cbQuant, blockCount: cBlockCount)
                let crF = JLIEncoder.parallelACFreqs(crQuant, blockCount: cBlockCount)
                for i in 0..<256 { acChrFreq[i] = cbF[i] + crF[i] }
            }

            dcLumTable = HuffmanTableBuilder.build(
                frequencies: dcLumFreq, fallback: StandardHuffmanTables.dcLuminance)
            acLumTable = HuffmanTableBuilder.build(
                frequencies: acLumFreq, fallback: StandardHuffmanTables.acLuminance)
            dcChrTable = HuffmanTableBuilder.build(
                frequencies: dcChrFreq, fallback: StandardHuffmanTables.dcChrominance)
            acChrTable = HuffmanTableBuilder.build(
                frequencies: acChrFreq, fallback: StandardHuffmanTables.acChrominance)
        } else {
            dcLumTable = StandardHuffmanTables.dcLuminance
            acLumTable = StandardHuffmanTables.acLuminance
            dcChrTable = StandardHuffmanTables.dcChrominance
            acChrTable = StandardHuffmanTables.acChrominance
        }

        // MCU walk → Huffman bitstream. Sequential because DC coefficients are
        // DPCM-coded against the previous block of the same component. Preallocate
        // the BitWriter buffer to the worst-case raw-RGB size so the inner loop
        // never reallocates.
        var bitWriter = BitWriter(estimatedMaxSize: width * height * 3 + 4096)
        var prevDC = [Int32](repeating: 0, count: numComponents)
        var zigzagBuf = [Int32](repeating: 0, count: 64)
        let restartInterval = configuration.restartInterval
        var mcuCount = 0
        var restartIndex = 0

        for mcuY in 0..<mcuCountV {
            for mcuX in 0..<mcuCountH {
                // Emit RSTn every `restartInterval` MCUs and reset DC predictors —
                // the exact inverse of the decoder's restart handling.
                if restartInterval > 0 && mcuCount > 0 && mcuCount % restartInterval == 0 {
                    bitWriter.emitRestartMarker(restartIndex)
                    restartIndex = (restartIndex + 1) & 7
                    for i in 0..<numComponents { prevDC[i] = 0 }
                }
                mcuCount += 1
                for by in 0..<vMax {
                    for bx in 0..<hMax {
                        let yIdx = (mcuY * vMax + by) * yBlocksPerRow + (mcuX * hMax + bx)
                        prevDC[0] = emitBlock(
                            quantized: yQuant, blockIndex: yIdx, prevDC: prevDC[0],
                            dcTable: dcLumTable, acTable: acLumTable,
                            zigzagBuf: &zigzagBuf, writer: &bitWriter
                        )
                    }
                }

                if !isGrayscale {
                    let cIdx = mcuY * mcuCountH + mcuX
                    prevDC[1] = emitBlock(
                        quantized: cbQuant, blockIndex: cIdx, prevDC: prevDC[1],
                        dcTable: dcChrTable, acTable: acChrTable,
                        zigzagBuf: &zigzagBuf, writer: &bitWriter
                    )
                    prevDC[2] = emitBlock(
                        quantized: crQuant, blockIndex: cIdx, prevDC: prevDC[2],
                        dcTable: dcChrTable, acTable: acChrTable,
                        zigzagBuf: &zigzagBuf, writer: &bitWriter
                    )
                }
            }
        }
        bitWriter.flush()

        // SOF0 (baseline) / SOF1 (12-bit, or 8-bit when the configuration asks for extended sequential).
        mw.writeSOF(progressive: false, precision: precision, width: width, height: height,
                    components: sofComponents, extendedSequential: configuration.extendedSequential)

        // DHT — embed whichever tables we actually encoded with (standard or
        // per-image optimal). The decoder reads these back from the DHT markers.
        var dhtTables: [(tableClass: Int, tableId: Int, bits: [UInt8], values: [UInt8])] = [
            (0, 0, dcLumTable.bits, dcLumTable.values),
            (1, 0, acLumTable.bits, acLumTable.values)
        ]
        if !isGrayscale {
            dhtTables.append((0, 1, dcChrTable.bits, dcChrTable.values))
            dhtTables.append((1, 1, acChrTable.bits, acChrTable.values))
        }
        mw.writeDHT(tables: dhtTables)

        // DRI (define restart interval) before the scan, when restart is enabled.
        if restartInterval > 0 {
            mw.writeDRI(interval: restartInterval)
        }

        // SOS + entropy data
        if isGrayscale {
            mw.writeSOS(components: [(selector: 1, dcTableId: 0, acTableId: 0)])
        } else {
            mw.writeSOS(components: [
                (selector: 1, dcTableId: 0, acTableId: 0),
                (selector: 2, dcTableId: 1, acTableId: 1),
                (selector: 3, dcTableId: 1, acTableId: 1)
            ])
        }
        mw.writeEntropyData(bitWriter.data)
        mw.writeEOI()

        return mw.data
    }

    // MARK: - Lossless (SOF3) encode

    /// Encodes a lossless (SOF3) JPEG by spatial prediction (ITU-T T.81 Annex H):
    /// each sample's difference from a neighbour-based predictor (selector 1–7) is
    /// Huffman-coded with the DC mechanism. Bit-for-bit lossless. Grayscale (1) or
    /// RGB (3, stored directly — no color transform, component ids 'R'/'G'/'B' so
    /// decoders treat it as RGB, matching libjpeg-turbo's lossless).
    private func encodeLossless(
        _ image: JLIImage, configuration: JLIEncoderConfiguration,
        precision: Int, isGrayscale: Bool
    ) throws -> [UInt8] {
        let predictor = configuration.losslessPredictor
        guard (1...7).contains(predictor) else {
            throw JLIError.unsupportedJPEGFeature("lossless predictor \(predictor) (1–7)")
        }
        let pt = configuration.losslessPointTransform           // 0 = true lossless
        guard (0..<precision).contains(pt) else {
            throw JLIError.unsupportedJPEGFeature("lossless point transform \(pt) (0–\(precision - 1))")
        }
        // Restart intervals (opt-in, previously silently ignored on SOF3):
        // row-aligned only, matching libjpeg-turbo's lossless constraint ("must
        // be an integer multiple of the number of MCUs in an MCU row") — which
        // also makes every restart segment independently decodable. Prediction
        // resets to scan-start state at each segment (first row of a segment
        // predicts like the first row of the scan).
        let restartInterval = configuration.restartInterval
        if restartInterval > 0, restartInterval % image.width != 0 {
            throw JLIError.unsupportedJPEGFeature(
                "lossless restart interval \(restartInterval) must be a multiple of "
                + "samples-per-row (\(image.width))")
        }
        if !isGrayscale {
            guard image.colorModel == .rgb || image.colorModel == .rgba else {
                throw JLIError.unsupportedColorSpaceConversion(
                    from: "\(image.colorModel)", to: "lossless JPEG (use RGB/RGBA for color)")
            }
        }
        let w = image.width, h = image.height
        let nc = isGrayscale ? 1 : 3
        let srcCC = image.colorModel.componentCount     // 1 / 3 / 4 (alpha ignored)
        // Bytes per stored sample comes from the ACTUAL pixel format, never the
        // requested precision: deriving it from `precision` made a `.uint8`
        // image with losslessPrecision 2–7 read 2·w·h·srcCC bytes from a
        // w·h·srcCC buffer — with raw pointers that was a silent heap over-read
        // straight into the encoded output (caught by the branch's adversarial
        // review; the old bounds-checked subscripts trapped instead).
        let bps = image.pixelFormat == .uint16 ? 2 : 1

        let count = w * h
        // De-interleave source into flat per-component planes (plane c at offset
        // c·count; raw + uninitialized — every element is written below). For
        // near-lossless (pt > 0) the point transform discards the low `pt` bits up
        // front; prediction, differencing and reconstruction then all operate in
        // this shifted domain, and the decoder shifts back by `pt` on output.
        let planeStore = UnsafeMutableBufferPointer<Int32>.allocate(capacity: count * nc)
        defer { planeStore.deallocate() }
        let planeBase = planeStore.baseAddress!
        image.data.withUnsafeBufferPointer { src in
            let s = src.baseAddress!
            for c in 0..<nc {
                let p = planeBase + c * count
                if bps == 1 {
                    for i in 0..<count { p[i] = Int32(s[i * srcCC + c]) >> pt }
                } else {
                    for i in 0..<count {
                        let o = (i * srcCC + c) * 2
                        p[i] = Int32(UInt16(s[o]) | (UInt16(s[o + 1]) << 8)) >> pt
                    }
                }
            }
        }

        let half = Int32(1 << (precision - 1 - pt))

        // Residuals are memoized once, in emit order (diffs[(y·w + x)·nc + c]),
        // instead of running the predictor sweep twice (counting pass + emit
        // pass). Each residual depends only on the *source plane* rows y/y−1 —
        // never on other residuals — so the sweep parallelizes across row
        // chunks with a per-worker histogram; integer addition commutes, so the
        // merged histogram (and therefore the Huffman table and the bitstream)
        // is identical to a serial pass.
        let diffStore = UnsafeMutableBufferPointer<Int32>.allocate(capacity: count * nc)
        defer { diffStore.deallocate() }
        let diffBase = diffStore.baseAddress!
        // Rows per restart segment (0 = no restarts). Row-aligned by the guard
        // above, so each segment's first row predicts like the scan's first row.
        let segRows = restartInterval > 0 ? restartInterval / w : 0

        let chunks = min(ProcessInfo.processInfo.activeProcessorCount,
                         max(1, (count * nc) / JLIEncoder.losslessParallelMinSamples))
        var dcFreq: [Int]
        if chunks <= 1 {
            dcFreq = JLIEncoder.losslessResiduals(
                rows: 0..<h, width: w, nc: nc, count: count,
                predictor: predictor, half: half, segRows: segRows,
                planes: planeBase, diffs: diffBase)
        } else {
            let span = (h + chunks - 1) / chunks
            var partials = [[Int]](repeating: [], count: chunks)
            partials.withUnsafeMutableBufferPointer { buf in
                let ptrs = LosslessPtrs(planes: planeBase, diffs: diffBase,
                                        partials: buf.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                    let lo = ci * span, hi = min(lo + span, h)
                    ptrs.partials[ci] = lo < hi
                        ? JLIEncoder.losslessResiduals(
                            rows: lo..<hi, width: w, nc: nc, count: count,
                            predictor: predictor, half: half, segRows: segRows,
                            planes: ptrs.planes, diffs: ptrs.diffs)
                        : [Int](repeating: 0, count: 256)
                }
            }
            dcFreq = [Int](repeating: 0, count: 256)
            for part in partials { for i in 0..<256 { dcFreq[i] += part[i] } }
        }
        let table = HuffmanTableBuilder.build(
            frequencies: dcFreq, fallback: StandardHuffmanTables.dcLuminance)

        // Emit pass. Grayscale id 1 + JFIF; RGB ids 'R','G','B' + Adobe APP14
        // transform=0 so decoders read it as direct RGB (not JFIF-implied YCbCr).
        var mw = MarkerWriter()
        mw.writeSOI()
        if isGrayscale { mw.writeAPP0() } else { mw.writeAPP14(transform: 0) }
        if let exif = image.exif { mw.writeAPP1Exif(exif) }
        if let icc = image.iccProfile { mw.writeAPP2ICC(icc) }
        let comps: [(id: UInt8, hSampling: Int, vSampling: Int, quantTableId: Int)] =
            isGrayscale ? [(1, 1, 1, 0)] : [(0x52, 1, 1, 0), (0x47, 1, 1, 0), (0x42, 1, 1, 0)]
        mw.writeSOF(progressive: false, precision: precision, width: w, height: h,
                    components: comps, lossless: true)
        mw.writeDHT(tables: [(0, 0, table.bits, table.values)])
        if restartInterval > 0 { mw.writeDRI(interval: restartInterval) }
        mw.writeSOS(components: comps.map { (selector: $0.id, dcTableId: 0, acTableId: 0) },
                    spectralStart: predictor, spectralEnd: 0,
                    successiveApproxHigh: 0, successiveApproxLow: pt)

        // Emit reads the memoized residuals (already in interleaved emit order)
        // — no predictor recompute. Large images emit in PARALLEL: the sample
        // sequence splits into ordered pieces (restart segments when restarts
        // are on, else even ranges — residuals carry no cross-sample state, so
        // any split is valid); each worker writes its piece's bit sequence into
        // a private *unstuffed* buffer, and a serial stitch feeds those bit
        // sequences through the main BitWriter, which applies stuffing and
        // alignment. The total bit sequence equals the serial walk by
        // construction, and stuffing/padding are pure functions of that
        // sequence — so the output bytes are identical (gated by the
        // forced-serial test and the identity-hash matrix, whose lossless-RGB
        // entries exercise this path).
        var bw = BitWriter(estimatedMaxSize: w * h * nc * 2 + 1024)
        let totalSamples = count * nc
        let segSamples = segRows > 0 ? segRows * w * nc : Int.max

        var pieces = [Range<Int>]()
        if segRows > 0 {
            var s = 0
            while s < totalSamples {
                pieces.append(s..<min(s + segSamples, totalSamples)); s += segSamples
            }
        } else {
            let n = min(ProcessInfo.processInfo.activeProcessorCount,
                        max(1, totalSamples / JLIEncoder.losslessParallelMinSamples))
            let span = (totalSamples + n - 1) / n
            var s = 0
            while s < totalSamples {
                pieces.append(s..<min(s + span, totalSamples)); s += span
            }
        }

        if pieces.count > 1, totalSamples >= JLIEncoder.losslessParallelMinSamples {
            let piecesFinal = pieces        // immutable snapshot for the @Sendable workers
            var emitted = [(bytes: [UInt8], bitCount: Int)](repeating: ([], 0), count: pieces.count)
            emitted.withUnsafeMutableBufferPointer { eb in
                let slots = EmitSlots(chunks: eb.baseAddress!, diffs: diffBase, table: table)
                DispatchQueue.concurrentPerform(iterations: piecesFinal.count) { k in
                    slots.chunks[k] = JLIEncoder.emitLosslessChunk(
                        diffs: slots.diffs, range: piecesFinal[k], table: slots.table)
                }
            }
            for (k, chunk) in emitted.enumerated() {
                if k > 0 && segRows > 0 { bw.emitRestartMarker((k - 1) & 7) }
                JLIEncoder.feedBits(chunk.bytes, bitCount: chunk.bitCount, into: &bw)
            }
        } else {
            var sinceRestart = 0
            var rstIdx = 0
            for i in 0..<totalSamples {
                if sinceRestart == segSamples {
                    bw.emitRestartMarker(rstIdx & 7)
                    rstIdx += 1
                    sinceRestart = 0
                }
                sinceRestart += 1
                let d = diffBase[i]
                let cat = d == -32768 ? 16 : HuffmanEncoder.category(for: d)
                let e = table.encodingTable[cat]
                if cat > 0 && cat < 16 {
                    // Code + magnitude bits in one call — identical bitstream
                    // (appending n then m bits == appending the n+m-bit
                    // concatenation), half the writer calls. ≤ 16+15 = 31 bits.
                    let fused = (UInt32(e.code) << cat)
                        | HuffmanEncoder.additionalBits(for: d, category: cat)
                    bw.writeBits(fused, count: Int(e.length) + cat)
                } else {
                    bw.writeBits(UInt32(e.code), count: Int(e.length))
                }
            }
        }
        bw.flush()
        mw.writeEntropyData(bw.data)
        mw.writeEOI()
        return mw.data
    }

    /// `@unchecked Sendable` carrier for the parallel lossless emit: worker `k`
    /// reads the shared residuals/table and writes only its own chunk slot.
    private struct EmitSlots: @unchecked Sendable {
        let chunks: UnsafeMutablePointer<(bytes: [UInt8], bitCount: Int)>
        let diffs: UnsafePointer<Int32>
        let table: HuffmanTable
    }

    /// Bit accumulator WITHOUT stuffing or markers — workers pack their piece's
    /// raw bit sequence here; the stitch replays it through the real BitWriter
    /// (which owns stuffing), so the final stream is byte-identical to a serial
    /// emit of the same bits.
    private struct RawBitChunkWriter {
        var bytes: [UInt8]
        private(set) var bitCount = 0
        private var acc: UInt64 = 0
        private var nbits = 0

        init(capacity: Int) {
            bytes = []
            bytes.reserveCapacity(capacity)
        }

        mutating func writeBits(_ value: UInt32, count: Int) {
            guard count > 0 else { return }
            acc = (acc << UInt64(count)) | UInt64(value & ((1 << UInt32(count)) &- 1))
            nbits += count
            bitCount += count
            while nbits >= 8 {
                nbits -= 8
                bytes.append(UInt8((acc >> UInt64(nbits)) & 0xFF))
            }
        }

        /// Packs any trailing partial bits into the HIGH bits of a final byte
        /// (matching how ``feedBits`` extracts them).
        mutating func finish() {
            if nbits > 0 {
                bytes.append(UInt8((acc << UInt64(8 - nbits)) & 0xFF))
                nbits = 0
            }
        }
    }

    /// Emits the Huffman bit sequence for `range` of memoized residuals into an
    /// unstuffed buffer — the exact same per-sample bits as the serial emit.
    private static func emitLosslessChunk(
        diffs: UnsafePointer<Int32>, range: Range<Int>, table: HuffmanTable
    ) -> (bytes: [UInt8], bitCount: Int) {
        var rw = RawBitChunkWriter(capacity: range.count * 3 + 16)
        for i in range {
            let d = diffs[i]
            let cat = d == -32768 ? 16 : HuffmanEncoder.category(for: d)
            let e = table.encodingTable[cat]
            if cat > 0 && cat < 16 {
                let fused = (UInt32(e.code) << cat)
                    | HuffmanEncoder.additionalBits(for: d, category: cat)
                rw.writeBits(fused, count: Int(e.length) + cat)
            } else {
                rw.writeBits(UInt32(e.code), count: Int(e.length))
            }
        }
        rw.finish()
        return (rw.bytes, rw.bitCount)
    }

    /// Replays an unstuffed bit sequence through the stuffing BitWriter, 24 bits
    /// per call (writeBits' value mask handles ≤ 31). Appending the same bits in
    /// different call granularity produces the same stream by the writer's
    /// MSB-first accumulation.
    private static func feedBits(_ bytes: [UInt8], bitCount: Int, into bw: inout BitWriter) {
        var remaining = bitCount
        bytes.withUnsafeBufferPointer { p in
            guard let b = p.baseAddress else { return }
            var i = 0
            while remaining >= 24 {
                let v = (UInt32(b[i]) << 16) | (UInt32(b[i + 1]) << 8) | UInt32(b[i + 2])
                bw.writeBits(v, count: 24)
                i += 3
                remaining -= 24
            }
            while remaining >= 8 {
                bw.writeBits(UInt32(b[i]), count: 8)
                i += 1
                remaining -= 8
            }
            if remaining > 0 {
                bw.writeBits(UInt32(b[i]) >> (8 - remaining), count: remaining)
            }
        }
    }

    /// Encodes 8-bit RGB(A) as an XYB-color JPEG: each pixel → scaled-XYB samples
    /// (``ColorConversion/rgbToXYBSample(r:g:b:)``), three full-resolution (4:4:4)
    /// components quantized with the jpegli XYB tables, plus an embedded ICC
    /// profile (``XYBICCProfile``) and Adobe APP14 transform=0 so ICC-aware
    /// decoders reconstruct correct color. Component order is X, Y, B to match the
    /// profile's input channels. Baseline allows only two Huffman tables, so the
    /// luma-like Y channel uses table set 0 and X/B share set 1.
    private func encodeXYB(
        _ image: JLIImage, configuration: JLIEncoderConfiguration, distance: Double
    ) throws -> [UInt8] {
        let w = image.width, h = image.height
        let srcCC = image.colorModel.componentCount
        let count = w * h
        var xP = [Float](repeating: 0, count: count)
        var yP = [Float](repeating: 0, count: count)
        var bP = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let s = i * srcCC
            let xyb = ColorConversion.rgbToXYBSample(
                r: Float(image.data[s]), g: Float(image.data[s + 1]), b: Float(image.data[s + 2]))
            xP[i] = xyb.x; yP[i] = xyb.y; bP[i] = xyb.bOut
        }

        let qt = [Quantization.perceptualQuantTableXYB(distance: distance, channel: 0),
                  Quantization.perceptualQuantTableXYB(distance: distance, channel: 1),
                  Quantization.perceptualQuantTableXYB(distance: distance, channel: 2)]
        let blocksH = (w + 7) / 8, blocksV = (h + 7) / 8
        let blockCount = blocksH * blocksV
        var scratch = [Float](repeating: 0, count: blockCount * 64)
        let levelShift: Float = 128
        // DCT + quantize each XYB plane. Trellis (RDO) is gated by
        // `adaptiveQuantization` like the YCbCr path — without it XYB competes
        // against trellis-on YCbCr one-handed. Per-channel λ scales with the
        // channel's own mean AC quant step²; the AC rate model uses the standard
        // table for the channel's Huffman set (Y→luma, X/B→chroma).
        func meanACSq(_ table: [Int]) -> Double {
            var sum = 0.0
            for i in 1..<64 { sum += Double(table[i]) * Double(table[i]) }
            return sum / 63.0
        }
        let useRDO = configuration.adaptiveQuantization
        func rdo(_ table: [Int], _ ac: HuffmanTable) -> RDOContext? {
            useRDO ? RDOContext(quantTable: table, acTable: ac, lambda: JLIEncoder.rdoLambdaK * meanACSq(table)) : nil
        }
        let qx = quantizePlane(xP, planeWidth: w, planeHeight: h, blocksH: blocksH, blocksV: blocksV,
                               invQuant: qt[0].map { 1.0 / Float($0) }, levelShift: levelShift,
                               scratch: &scratch, rdo: rdo(qt[0], StandardHuffmanTables.acChrominance))
        let qy = quantizePlane(yP, planeWidth: w, planeHeight: h, blocksH: blocksH, blocksV: blocksV,
                               invQuant: qt[1].map { 1.0 / Float($0) }, levelShift: levelShift,
                               scratch: &scratch, rdo: rdo(qt[1], StandardHuffmanTables.acLuminance),
                               adaptiveField: configuration.adaptiveQuantField)
        let qb = quantizePlane(bP, planeWidth: w, planeHeight: h, blocksH: blocksH, blocksV: blocksV,
                               invQuant: qt[2].map { 1.0 / Float($0) }, levelShift: levelShift,
                               scratch: &scratch, rdo: rdo(qt[2], StandardHuffmanTables.acChrominance))
        let planes = [qx, qy, qb]

        // Huffman: set 0 serves Y (the luma-like channel), set 1 serves X and B.
        // `huffSet[c]` is the table set for component c (order X, Y, B).
        let huffSet = [1, 0, 1]
        let dcTable: [HuffmanTable], acTable: [HuffmanTable]   // indexed by set (0,1)
        if configuration.optimiseHuffman {
            var dcF = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 2)
            var prev = [Int32](repeating: 0, count: 3)
            for i in 0..<blockCount {
                for c in 0..<3 {
                    let dc = planes[c][i * 64]
                    HuffmanEncoder.countDC(dc - prev[c], freq: &dcF[huffSet[c]])
                    prev[c] = dc
                }
            }
            var acF = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 2)
            for c in 0..<3 {
                let f = JLIEncoder.parallelACFreqs(planes[c], blockCount: blockCount)
                for k in 0..<256 { acF[huffSet[c]][k] += f[k] }
            }
            dcTable = [HuffmanTableBuilder.build(frequencies: dcF[0], fallback: StandardHuffmanTables.dcLuminance),
                       HuffmanTableBuilder.build(frequencies: dcF[1], fallback: StandardHuffmanTables.dcChrominance)]
            acTable = [HuffmanTableBuilder.build(frequencies: acF[0], fallback: StandardHuffmanTables.acLuminance),
                       HuffmanTableBuilder.build(frequencies: acF[1], fallback: StandardHuffmanTables.acChrominance)]
        } else {
            dcTable = [StandardHuffmanTables.dcLuminance, StandardHuffmanTables.dcChrominance]
            acTable = [StandardHuffmanTables.acLuminance, StandardHuffmanTables.acChrominance]
        }

        // Emit. Markers: SOI, APP14 transform=0 (direct components, not YCbCr),
        // APP2 XYB ICC, 3 DQT, SOF0, DHT (2 sets), SOS (X,Y,B), entropy, EOI.
        var mw = MarkerWriter()
        mw.writeSOI()
        mw.writeAPP14(transform: 0)
        mw.writeAPP2ICC(XYBICCProfile.data)
        if let exif = image.exif { mw.writeAPP1Exif(exif) }
        mw.writeDQT(tables: [(0, zigzagQuantTable(qt[0])), (1, zigzagQuantTable(qt[1])), (2, zigzagQuantTable(qt[2]))])
        mw.writeSOF(progressive: false, precision: 8, width: w, height: h,
                    components: [(1, 1, 1, 0), (2, 1, 1, 1), (3, 1, 1, 2)])
        mw.writeDHT(tables: [
            (0, 0, dcTable[0].bits, dcTable[0].values), (1, 0, acTable[0].bits, acTable[0].values),
            (0, 1, dcTable[1].bits, dcTable[1].values), (1, 1, acTable[1].bits, acTable[1].values),
        ])
        mw.writeSOS(components: [
            (selector: 1, dcTableId: huffSet[0], acTableId: huffSet[0]),
            (selector: 2, dcTableId: huffSet[1], acTableId: huffSet[1]),
            (selector: 3, dcTableId: huffSet[2], acTableId: huffSet[2]),
        ])

        var bw = BitWriter(estimatedMaxSize: w * h * 3 + 4096)
        var prev = [Int32](repeating: 0, count: 3)
        var zz = [Int32](repeating: 0, count: 64)
        for i in 0..<blockCount {
            for c in 0..<3 {
                prev[c] = emitBlock(quantized: planes[c], blockIndex: i, prevDC: prev[c],
                                    dcTable: dcTable[huffSet[c]], acTable: acTable[huffSet[c]],
                                    zigzagBuf: &zz, writer: &bw)
            }
        }
        bw.flush()
        mw.writeEntropyData(bw.data)
        mw.writeEOI()
        return mw.data
    }

    // MARK: - Private Helpers

    /// Validates the encoder configuration, throwing on invalid parameters.
    private func validateConfiguration(_ configuration: JLIEncoderConfiguration) throws {
        guard configuration.quality >= 0.0, configuration.quality <= 100.0 else {
            throw JLIError.invalidQuality(configuration.quality)
        }
        if let distance = configuration.distance {
            guard distance >= 0.0 else {
                throw JLIError.invalidDistance(distance)
            }
        }
        // The DRI restart interval is a 16-bit field; reject out-of-range values
        // cleanly rather than overflowing UInt16 when the marker is written.
        guard (0...65535).contains(configuration.restartInterval) else {
            throw JLIError.unsupportedJPEGFeature(
                "restartInterval \(configuration.restartInterval) (must be 0…65535)")
        }
    }

    /// Quantises a `.float32` image (normalised [0,1] per component, little-endian)
    /// to `.uint8` (clamp to [0,1], scale to 0–255, round-to-nearest), preserving
    /// dimensions, color model, and embedded ICC/Exif.
    private func quantizeFloat32ToUInt8(_ image: JLIImage) throws -> JLIImage {
        let n = image.width * image.height * image.colorModel.componentCount
        var out = [UInt8](repeating: 0, count: n)
        let src = image.data
        for i in 0..<n {
            let b = i * 4
            let bits = UInt32(src[b]) | (UInt32(src[b + 1]) << 8)
                | (UInt32(src[b + 2]) << 16) | (UInt32(src[b + 3]) << 24)
            let v = Float(bitPattern: bits)
            out[i] = UInt8(clamping: Int((min(max(v, 0), 1) * 255).rounded()))
        }
        return try JLIImage(width: image.width, height: image.height, pixelFormat: .uint8,
                            colorModel: image.colorModel, data: out,
                            iccProfile: image.iccProfile, exif: image.exif)
    }

    /// Extract every 8×8 block from a component plane → batched forward DCT +
    /// quantize. Returns an Int32 buffer of size `blocksH*blocksV*64` holding
    /// quantized coefficients in natural (non-zigzag) order, per-block-contiguous.
    ///
    /// Level-shift (-128) is folded into the extract pass so we don't pay a
    /// separate read+write sweep over the whole batched buffer. Edge pixels are
    /// replicated when the plane dimensions aren't a multiple of 8.
    private func quantizePlane(
        _ plane: [Float], planeWidth: Int, planeHeight: Int,
        blocksH: Int, blocksV: Int,
        invQuant: [Float], levelShift: Float, scratch: inout [Float],
        rdo: RDOContext? = nil, adaptiveField: Bool = false,
        jpegli: JpegliAQ? = nil
    ) -> [Int32] {
        let n = blocksH * blocksV
        // These three n·64 buffers are each fully overwritten downstream
        // (extract writes every block element edge-clamped; the DCT and quantize
        // batches process every coefficient), so allocate them *uninitialized* —
        // the zero-fill was the dominant `bzero` cost in the encode profile. The
        // round-trip + cross-codec suite verifies nothing is left unwritten.
        var blockBuf = [Float](unsafeUninitializedCapacity: n * 64) { _, c in c = n * 64 }
        extractAllBlocksLevelShifted(
            plane, planeWidth: planeWidth, planeHeight: planeHeight,
            blocksH: blocksH, blocksV: blocksV, levelShift: levelShift, into: &blockBuf
        )

        var dctBuf = [Float](unsafeUninitializedCapacity: n * 64) { _, c in c = n * 64 }
        AccelerateDSP.forwardDCTBatch(
            blockBuf, into: &dctBuf, scratch: &scratch, blockCount: n
        )

        // jpegli adaptive path: per-block masking field + per-coefficient
        // zero-bias (dead-zone) instead of trellis. Opt-in (WS-A / 0.3.0).
        if let j = jpegli {
            return quantizeZeroBias(
                dctBuf: dctBuf, blockCount: n, invQuant: invQuant,
                blocksH: blocksH, blocksV: blocksV, jpegli: j
            )
        }

        var quant = [Int32](unsafeUninitializedCapacity: n * 64) { _, c in c = n * 64 }
        AccelerateDSP.quantizeBatch(
            dctBuf, invTable: invQuant, into: &quant, blockCount: n
        )
        if var rdo = rdo {
            // Adaptive quant is luma-only (like jpegli) — modulating chroma λ
            // hurts subsampled (4:2:0) output. The caller gates `adaptiveField`.
            if adaptiveField {
                rdo.lambdaField = adaptiveLambdaField(dctBuf: dctBuf, blockCount: n)
            }
            applyTrellisQuantization(dctBuf: dctBuf, quant: &quant, blockCount: n, rdo: rdo)
        }
        return quant
    }

    /// Per-block λ multiplier from AC energy (visual-masking proxy): a block's
    /// `Σ AC²` relative to the plane mean, shaped sublinearly and clamped. Busy
    /// blocks (high energy) → multiplier > 1 (quantize harder, masked); flat
    /// blocks → < 1 (preserve smooth detail, where banding shows).
    /// Parameters for the jpegli adaptive (field + zero-bias) quant path. The
    /// masking field is computed once on luma (jpegli uses the luma-derived field
    /// for every channel) and carried here to be mapped onto each component grid.
    struct JpegliAQ {
        let component: Int
        let distance: Double
        let lumaField: [Float]
        let lumaBlocksH: Int
        let lumaBlocksV: Int
    }

    /// Quantizes via jpegli's masking field + per-coefficient zero-bias
    /// (dead-zone), no trellis: `qval = dct·invQuant`; an AC coefficient survives
    /// iff `|qval| ≥ offset[k] + aq_strength·mul[k]`, else snaps to 0. DC always
    /// kept (its threshold is 0).
    private func quantizeZeroBias(
        dctBuf: [Float], blockCount n: Int, invQuant: [Float],
        blocksH: Int, blocksV: Int, jpegli j: JpegliAQ
    ) -> [Int32] {
        // Map the luma-derived field onto this component's block grid: 1:1 for
        // luma / 4:4:4, box-average the covered luma blocks for subsampled chroma.
        let rH = max(1, j.lumaBlocksH / blocksH), rV = max(1, j.lumaBlocksV / blocksV)
        var field = [Float](repeating: 0, count: n)
        for yb in 0..<blocksV {
            for xb in 0..<blocksH {
                var s: Float = 0
                for dy in 0..<rV {
                    let ly = min(yb * rV + dy, j.lumaBlocksV - 1) * j.lumaBlocksH
                    for dx in 0..<rH { s += j.lumaField[ly + min(xb * rH + dx, j.lumaBlocksH - 1)] }
                }
                field[yb * blocksH + xb] = s / Float(rH * rV)
            }
        }
        let (zbOffset, zbMul) = JLIAdaptiveQuant.zeroBias(distance: j.distance, component: j.component)
        var quant = [Int32](unsafeUninitializedCapacity: n * 64) { _, c in c = n * 64 }
        dctBuf.withUnsafeBufferPointer { db in
            invQuant.withUnsafeBufferPointer { iq in
                zbOffset.withUnsafeBufferPointer { zo in
                    zbMul.withUnsafeBufferPointer { zm in
                        field.withUnsafeBufferPointer { fb in
                            quant.withUnsafeMutableBufferPointer { qb in
                                let d = db.baseAddress!, q = qb.baseAddress!
                                let inv = iq.baseAddress!, off = zo.baseAddress!, mul = zm.baseAddress!
                                for b in 0..<n {
                                    let base = b * 64
                                    let aq = fb[b]
                                    for k in 0..<64 {
                                        let qval = d[base + k] * inv[k]
                                        let thr = off[k] + mul[k] * aq
                                        q[base + k] = abs(qval) >= thr
                                            ? Int32(qval.rounded(.toNearestOrEven)) : 0
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return quant
    }

    private func adaptiveLambdaField(dctBuf: [Float], blockCount n: Int) -> [Float] {
        var energy = [Float](repeating: 0, count: n)
        var mean = 0.0
        dctBuf.withUnsafeBufferPointer { buf in
            let d = buf.baseAddress!
            for b in 0..<n {
                let base = b * 64
                var e: Float = 0
                for k in 1..<64 { let v = d[base + k]; e += v * v }
                energy[b] = e; mean += Double(e)
            }
        }
        mean = max(mean / Double(max(1, n)), 1e-6)
        var field = [Float](repeating: 1, count: n)
        for b in 0..<n {
            let r = Double(energy[b]) / mean
            field[b] = Float(min(max(pow(r, 0.4), 0.7), 1.8))
        }
        return field
    }

    /// Rate-distortion context for trellis-style quantization. `quantTable` is
    /// the forward quant table (natural order); `acTable` provides the bit-length
    /// rate model; `lambda` trades distortion (DCT coeff², = pixel² by Parseval)
    /// against rate (bits).
    struct RDOContext: Sendable {
        let quantTable: [Int]
        let acTable: HuffmanTable
        let lambda: Double
        /// Optional per-block λ multiplier (adaptive quantization): busier blocks
        /// get a larger multiplier (visual masking hides their quantization), flat
        /// blocks a smaller one (preserve smooth detail). `nil` ⇒ uniform λ.
        var lambdaField: [Float]? = nil
    }

    /// Trellis quantization: for each block, a Viterbi DP chooses, for every
    /// nonzero AC coefficient, whether to drop it (→0), reduce its magnitude by
    /// one step (q→q∓1 toward zero), or keep it — minimizing D + λ·R: DCT-domain
    /// squared error (= pixel² by Parseval) against the run-length-coded bits.
    ///
    /// Dropping interior coefficients merges the surrounding zero runs; magnitude
    /// reduction trims a coefficient's size category and additional bits. The EOB
    /// choice falls out as "which kept coefficient is last." Magnitudes are only
    /// ever reduced, never grown, so output stays standard baseline JPEG; the
    /// rate model uses the fixed Annex K table lengths, sidestepping the
    /// chicken-and-egg with optimized Huffman (built afterward).
    ///
    /// State = (candidate, variant ∈ {full q, reduced q∓1}); transitions account
    /// for the inter-coefficient run (incl. ZRL). O(m²) per block in the nonzero
    /// AC count m; high-entropy blocks (m large) skip the DP.
    private func applyTrellisQuantization(
        dctBuf: [Float], quant: inout [Int32], blockCount: Int, rdo: RDOContext
    ) {
        // Partition blocks across cores when there's enough work; each worker owns
        // its scratch and writes only its disjoint quant[base...] slice, so the
        // result is byte-identical to a serial run.
        let chunks = min(ProcessInfo.processInfo.activeProcessorCount,
                         max(1, blockCount / JLIEncoder.trellisMinBlocksPerChunk))
        dctBuf.withUnsafeBufferPointer { dbuf in
            quant.withUnsafeMutableBufferPointer { qbuf in
                let dct = dbuf.baseAddress!
                let qnt = qbuf.baseAddress!
                if chunks <= 1 {
                    JLIEncoder.trellisBlocks(0..<blockCount, dct: dct, quant: qnt, rdo: rdo)
                    return
                }
                let span = (blockCount + chunks - 1) / chunks
                let ptrs = TrellisPtrs(dct: dct, quant: qnt)
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    let lo = c * span, hi = min(lo + span, blockCount)
                    if lo < hi {
                        JLIEncoder.trellisBlocks(lo..<hi, dct: ptrs.dct, quant: ptrs.quant, rdo: rdo)
                    }
                }
            }
        }
    }

    /// `@unchecked Sendable` carrier for the two batched buffers so disjoint block
    /// ranges can be trellis-quantized on separate cores: each ``trellisBlocks``
    /// call reads `dct` and writes only the `quant[base...]` slice of its range.
    private struct TrellisPtrs: @unchecked Sendable {
        let dct: UnsafePointer<Float>
        let quant: UnsafeMutablePointer<Int32>
    }

    /// Minimum interleaved sample count (`w·h·nc`) before the lossless residual
    /// sweep and entropy emit fan out across cores; below this the dispatch
    /// overhead wins. Lock-protected because the serial/parallel byte-equality
    /// tests mutate it (`= .max` to force the serial path) while other tests
    /// may be encoding concurrently — both gate values are behaviorally
    /// equivalent (that's what the tests prove), but the access itself must not
    /// be a data race. No production code mutates it.
    static var losslessParallelMinSamples: Int {
        get { gateLock.lock(); defer { gateLock.unlock() }; return _losslessParallelMinSamples }
        set { gateLock.lock(); defer { gateLock.unlock() }; _losslessParallelMinSamples = newValue }
    }
    private static let gateLock = NSLock()
    nonisolated(unsafe) private static var _losslessParallelMinSamples = 1 << 16

    /// `@unchecked Sendable` carrier for the lossless residual sweep: workers
    /// read disjoint row ranges of `planes` (plus one shared read-only border
    /// row each) and write disjoint row ranges of `diffs` and their own
    /// `partials` slot.
    private struct LosslessPtrs: @unchecked Sendable {
        let planes: UnsafePointer<Int32>
        let diffs: UnsafeMutablePointer<Int32>
        let partials: UnsafeMutablePointer<[Int]>
    }

    /// Computes the T.81 Annex H residual for every sample of `rows` into
    /// `diffs` (interleaved emit order: `(y·w + x)·nc + c`) and returns the
    /// 256-bin category histogram for those rows. Residuals depend only on the
    /// source `planes` (prediction reads rows y and y−1), never on other
    /// residuals, so any row partition yields identical values — and category
    /// counts commute, so summed partial histograms equal a serial count.
    private static func losslessResiduals(
        rows: Range<Int>, width w: Int, nc: Int, count: Int,
        predictor: Int, half: Int32, segRows: Int,
        planes: UnsafePointer<Int32>, diffs: UnsafeMutablePointer<Int32>
    ) -> [Int] {
        var freq = [Int](repeating: 0, count: 256)
        freq.withUnsafeMutableBufferPointer { fb in
            let f = fb.baseAddress!
            for y in rows {
                let row = y * w, prevRow = row - w
                // The first row of the scan AND of each restart segment predicts
                // with scan-start semantics (default value, then Ra) per T.81 —
                // a pure function of (y, segRows), so the row-parallel sweep is
                // unaffected by restarts.
                let firstRow = y == 0 || (segRows > 0 && y % segRows == 0)
                for x in 0..<w {
                    for c in 0..<nc {
                        let p = planes + c * count
                        let px: Int32
                        if x == 0 {
                            px = firstRow ? half : p[prevRow]                  // initial / Rb
                        } else if firstRow {
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
                        // Difference modulo 2^16, mapped to signed 16-bit (T.81);
                        // −32768 ⇒ category 16.
                        var d = (p[row + x] - px) & 0xFFFF
                        if d >= 32768 { d -= 65536 }
                        diffs[(row + x) * nc + c] = d
                        f[d == -32768 ? 16 : HuffmanEncoder.category(for: d)] += 1
                    }
                }
            }
        }
        return freq
    }

    /// `@unchecked Sendable` carrier for the per-worker partial AC histograms;
    /// each concurrent worker writes one disjoint slot.
    private struct ACPartialsPtr: @unchecked Sendable {
        let p: UnsafeMutablePointer<[Int]>
    }

    /// AC symbol histogram for `quant`'s blocks in `blocks` (zigzag + run-length
    /// count). Order-independent, so callable on any disjoint block range.
    private static func countACFreqs(_ quant: [Int32], blocks: Range<Int>) -> [Int] {
        var freq = [Int](repeating: 0, count: 256)
        var zz = [Int32](repeating: 0, count: 64)
        for b in blocks {
            Quantization.zigzagScan(quant, offset: b * 64, into: &zz)
            HuffmanEncoder.countAC(zz, freq: &freq)
        }
        return freq
    }

    /// Parallel AC histogram over all `blockCount` blocks of `quant`, summing the
    /// per-worker partials — bit-identical to a serial `countACFreqs(quant,
    /// 0..<blockCount)` since AC frequencies are order-independent. Runs serially
    /// for small inputs (see ``acCountMinBlocksPerChunk``).
    private static func parallelACFreqs(_ quant: [Int32], blockCount: Int) -> [Int] {
        guard blockCount > 0 else { return [Int](repeating: 0, count: 256) }
        let chunks = min(ProcessInfo.processInfo.activeProcessorCount,
                         max(1, blockCount / acCountMinBlocksPerChunk))
        if chunks <= 1 { return countACFreqs(quant, blocks: 0..<blockCount) }
        let span = (blockCount + chunks - 1) / chunks
        var partials = [[Int]](repeating: [], count: chunks)
        partials.withUnsafeMutableBufferPointer { buf in
            let ptr = ACPartialsPtr(p: buf.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = c * span, hi = min(lo + span, blockCount)
                ptr.p[c] = lo < hi ? countACFreqs(quant, blocks: lo..<hi)
                                   : [Int](repeating: 0, count: 256)
            }
        }
        var total = [Int](repeating: 0, count: 256)
        for part in partials { for i in 0..<256 { total[i] += part[i] } }
        return total
    }

    /// Trellis-quantize the blocks in `blocks`. `static` with fully self-contained
    /// per-call scratch so it is safe to run concurrently over disjoint ranges of
    /// the same `dct`/`quant` buffers. See ``applyTrellisQuantization`` for the
    /// rate-distortion model.
    private static func trellisBlocks(
        _ blocks: Range<Int>, dct: UnsafePointer<Float>,
        quant: UnsafeMutablePointer<Int32>, rdo: RDOContext
    ) {
        let zz = Quantization.zigzagOrder
        let lambda = rdo.lambda
        let eobLen = Int(rdo.acTable.encodingTable[0x00].length)
        let zrlLen = Int(rdo.acTable.encodingTable[0xF0].length)

        // Flat (run ≤ 15) × size → bit-cost table, precomputed once per worker:
        // the O(m²) DP inner loop otherwise reloads the Huffman entry struct
        // per evaluation. rate[(r<<4)|s] = code length + s, exactly what the
        // expression below computed.
        var rateTable = [Int](repeating: 0, count: 256)
        for rs in 0..<256 { rateTable[rs] = Int(rdo.acTable.encodingTable[rs].length) + (rs & 15) }

        // Bits to emit a nonzero of category `size` after `run` preceding zeros.
        func symbolBits(run: Int, size: Int) -> Int {
            var bits = 0
            var r = run
            while r > 15 { bits += zrlLen; r -= 16 }
            return bits + rateTable[(r << 4) | size]
        }

        // Per-block scratch. Each nonzero candidate has up to two "kept" variants
        // (full, reduced); states are flattened as candidate*2 + variant.
        let maxN = JLIEncoder.trellisMaxNonzeros
        var nz = [Int](repeating: 0, count: 64)              // zigzag position
        var dropDist = [Double](repeating: 0, count: 64)     // distortion if zeroed
        var cumDrop = [Double](repeating: 0, count: 65)
        var vCount = [Int](repeating: 0, count: 64)          // 1 or 2 variants
        var vVal = [Int32](repeating: 0, count: 128)         // quantized value
        var vDist = [Double](repeating: 0, count: 128)       // distortion if kept at variant
        var vSize = [Int](repeating: 0, count: 128)          // category
        var dp = [Double](repeating: 0, count: 128)
        var prevState = [Int](repeating: -1, count: 128)     // previous (candidate*2+variant), or -1
        var chosen = [Int](repeating: -1, count: 64)         // backtracked variant per candidate, -1 = dropped

        for b in blocks {
            let base = b * 64
            // Per-block λ for adaptive quantization (uniform when no field).
            let blockLambda = lambda * Double(rdo.lambdaField?[b] ?? 1.0)
            var m = 0
            for z in 1..<64 {
                let q = quant[base + zz[z]]
                if q == 0 { continue }
                let nat = zz[z]
                let c = Double(dct[base + nat])
                let qf = Double(rdo.quantTable[nat])
                nz[m] = z
                dropDist[m] = c * c
                // Variant 0: full magnitude.
                let reconF = Double(q) * qf
                vVal[m * 2] = q
                vDist[m * 2] = (c - reconF) * (c - reconF)
                vSize[m * 2] = HuffmanEncoder.category(for: q)
                // Variant 1: magnitude reduced one step toward zero (if still
                // nonzero). Restricted to higher-frequency positions — reducing
                // the lowest AC frequencies trims perceptually-visible energy
                // (butteraugli regresses), while HF reduction is near-invisible.
                let qr = q > 0 ? q - 1 : q + 1
                if qr != 0 && z >= JLIEncoder.trellisReduceMinZigzag {
                    let reconR = Double(qr) * qf
                    vVal[m * 2 + 1] = qr
                    vDist[m * 2 + 1] = (c - reconR) * (c - reconR)
                    vSize[m * 2 + 1] = HuffmanEncoder.category(for: qr)
                    vCount[m] = 2
                } else {
                    vCount[m] = 1  // |q| == 1: reducing == dropping, already covered
                }
                m += 1
            }
            if m == 0 || m > maxN { continue }

            cumDrop[0] = 0
            for k in 0..<m { cumDrop[k + 1] = cumDrop[k] + dropDist[k] }

            // dp[state] = min (Σ distortion + λ·rate) ending with candidate i kept
            // at variant v as the last-kept-so-far.
            for i in 0..<m {
                for v in 0..<vCount[i] {
                    let s = i * 2 + v
                    let keepBits = blockLambda * Double(symbolBits(run: nz[i] - 1, size: vSize[s]))
                    var best = cumDrop[i] + keepBits + vDist[s]   // j = -1 (start)
                    var bestPrev = -1
                    for j in 0..<i {
                        let between = cumDrop[i] - cumDrop[j + 1]
                        let run = nz[i] - nz[j] - 1
                        let rate = blockLambda * Double(symbolBits(run: run, size: vSize[s]))
                        for vj in 0..<vCount[j] {
                            let cost = dp[j * 2 + vj] + between + rate + vDist[s]
                            if cost < best { best = cost; bestPrev = j * 2 + vj }
                        }
                    }
                    dp[s] = best
                    prevState[s] = bestPrev
                }
            }

            // Final: last-kept (i, v) + EOB (unless at position 63), or keep nothing.
            var bestCost = cumDrop[m] + blockLambda * Double(eobLen)
            var bestState = -1
            for i in 0..<m {
                let afterDrop = cumDrop[m] - cumDrop[i + 1]
                let eobCost = nz[i] < 63 ? blockLambda * Double(eobLen) : 0.0
                for v in 0..<vCount[i] {
                    let cost = dp[i * 2 + v] + afterDrop + eobCost
                    if cost < bestCost { bestCost = cost; bestState = i * 2 + v }
                }
            }

            // Backtrack chosen variant per candidate (-1 = dropped).
            for k in 0..<m { chosen[k] = -1 }
            var st = bestState
            while st >= 0 {
                chosen[st / 2] = st % 2
                st = prevState[st]
            }
            // Write decided values back (drop → 0, else the variant's value).
            for k in 0..<m {
                let nat = zz[nz[k]]
                quant[base + nat] = chosen[k] < 0 ? 0 : vVal[k * 2 + chosen[k]]
            }
        }
    }

    /// Extracts `blocksH × blocksV` 8×8 blocks from a plane into a per-block-contig
    /// Float buffer with the level shift (`-2^(P-1)`: 128 for 8-bit, 2048 for
    /// 12-bit) folded in. Block `i` at offset `64*i`, row-major within. Edge
    /// pixels are replicated past plane bounds.
    private func extractAllBlocksLevelShifted(
        _ plane: [Float], planeWidth: Int, planeHeight: Int,
        blocksH: Int, blocksV: Int, levelShift: Float, into out: inout [Float]
    ) {
        plane.withUnsafeBufferPointer { srcBuf in
            out.withUnsafeMutableBufferPointer { dstBuf in
                let src = srcBuf.baseAddress!
                let dst = dstBuf.baseAddress!
                // Interior blocks (fully inside the plane — all but the last
                // row/column of blocks on non-multiple-of-8 planes) skip the
                // per-pixel edge clamps, so the inner loop is a clean
                // load-subtract-store the compiler vectorizes. Same values:
                // min() was the identity for these pixels.
                let fullBX = planeWidth / 8, fullBY = planeHeight / 8
                for by in 0..<fullBY {
                    let startY = by * 8
                    for bx in 0..<fullBX {
                        let startX = bx * 8
                        let blockBase = (by * blocksH + bx) * 64
                        for r in 0..<8 {
                            let srcRow = (startY + r) * planeWidth + startX
                            let dstRow = blockBase + r * 8
                            for c in 0..<8 {
                                dst[dstRow + c] = src[srcRow + c] - levelShift
                            }
                        }
                    }
                }
                // Edge blocks: replicate the last row/column past plane bounds.
                guard fullBX < blocksH || fullBY < blocksV else { return }
                for by in 0..<blocksV {
                    let startY = by * 8
                    for bx in 0..<blocksH where by >= fullBY || bx >= fullBX {
                        let startX = bx * 8
                        let blockBase = (by * blocksH + bx) * 64
                        for r in 0..<8 {
                            let sy = min(startY + r, planeHeight - 1)
                            let srcRow = sy * planeWidth
                            let dstRow = blockBase + r * 8
                            for c in 0..<8 {
                                let sx = min(startX + c, planeWidth - 1)
                                dst[dstRow + c] = src[srcRow + sx] - levelShift
                            }
                        }
                    }
                }
            }
        }
    }

    /// Read one block's quantized coefficients out of the batched buffer, zigzag
    /// directly from there, and emit DC (DPCM against `prevDC`) + AC Huffman codes.
    /// Returns the new DC value for the next block's prediction.
    @inline(__always)
    private func emitBlock(
        quantized: [Int32], blockIndex: Int, prevDC: Int32,
        dcTable: HuffmanTable, acTable: HuffmanTable,
        zigzagBuf: inout [Int32],
        writer: inout BitWriter
    ) -> Int32 {
        Quantization.zigzagScan(quantized, offset: blockIndex * 64, into: &zigzagBuf)

        let dcDiff = zigzagBuf[0] - prevDC
        HuffmanEncoder.encodeDC(dcDiff, table: dcTable, writer: &writer)
        HuffmanEncoder.encodeAC(zigzagBuf, table: acTable, writer: &writer)
        return zigzagBuf[0]
    }

    /// Reorders a quantization table to zigzag order for the DQT marker.
    private func zigzagQuantTable(_ table: [Int]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 64)
        for i in 0..<64 {
            result[i] = UInt8(clamping: table[Quantization.zigzagOrder[i]])
        }
        return result
    }
}
