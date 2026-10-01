//
// J2KCodec.swift
// J2KSwift
//
/// # J2KCodec
///
/// Codec module for JPEG 2000 encoding and decoding.
///
/// This module provides the core encoding and decoding functionality for JPEG 2000 images,
/// including support for various compression modes and quality settings.
///
/// ## Topics
///
/// ### Encoding
/// - ``J2KEncoder``
///
/// ### Decoding
/// - ``J2KDecoder``

import Foundation

/// Encodes images to JPEG 2000 format.
///
/// `J2KEncoder` provides a high-level API for encoding images to JPEG 2000 codestreams.
/// It connects all encoding components — colour transform, wavelet transform, quantization,
/// entropy coding, and rate control — into a complete encoding pipeline.
///
/// ## Basic Usage
///
/// ```swift
/// let encoder = J2KEncoder()
/// let image = J2KImage(width: 256, height: 256, components: 3, bitDepth: 8)
/// let data = try encoder.encode(image)
/// ```
///
/// ## Custom Configuration
///
/// ```swift
/// let config = J2KEncodingPreset.quality.configuration(quality: 0.95)
/// let encoder = J2KEncoder(encodingConfiguration: config)
/// let data = try encoder.encode(image)
/// ```
///
/// ## Progress Reporting
///
/// ```swift
/// let data = try encoder.encode(image) { update in
///     print("\(update.stage): \(Int(update.overallProgress * 100))%")
/// }
/// ```
public struct J2KEncoder: Sendable {
    /// The configuration to use for encoding.
    public let configuration: J2KConfiguration

    /// The detailed encoding configuration.
    public let encodingConfiguration: J2KEncodingConfiguration

    /// Creates a new encoder with the specified configuration.
    ///
    /// - Parameter configuration: The encoding configuration.
    public init(configuration: J2KConfiguration = J2KConfiguration()) {
        self.configuration = configuration
        self.encodingConfiguration = J2KEncodingConfiguration(
            quality: configuration.quality,
            lossless: configuration.lossless
        )
    }

    /// Creates a new encoder with a detailed encoding configuration.
    ///
    /// - Parameter encodingConfiguration: The detailed encoding configuration.
    public init(encodingConfiguration: J2KEncodingConfiguration) {
        self.configuration = J2KConfiguration(
            quality: encodingConfiguration.quality,
            lossless: encodingConfiguration.lossless
        )
        self.encodingConfiguration = encodingConfiguration
    }

    /// Encodes an image to JPEG 2000 format.
    ///
    /// This method processes the image through the complete JPEG 2000 encoding pipeline:
    /// 1. Preprocessing and input validation
    /// 2. Colour transform (RCT for lossless, ICT for lossy)
    /// 3. Multi-level wavelet transform
    /// 4. Quantization
    /// 5. EBCOT entropy coding
    /// 6. Rate control and layer formation
    /// 7. Codestream generation
    ///
    /// - Parameter image: The image to encode. Must have valid dimensions and components.
    /// - Returns: The encoded JPEG 2000 codestream data.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if the image is invalid.
    /// - Throws: ``J2KError/encodingError(_:)`` if encoding fails.
    public func encode(_ image: J2KImage) async throws -> Data {
        // v5.19.0 — `.constantBitrateViaQstep` runs an outer loop that
        // binary-searches qstep until achieved bpp matches target.
        // Bypasses PCRD-opt entirely; each iteration uses `.fixedQstep`.
        //
        // v5.32.0 note: explicit `.constantBitrateViaQstep` users
        // opted in for quality, so the bounded-rate refinement is
        // disabled here (`maxOvershootRatio: .infinity`). They get
        // v5.31.0 behaviour (no overshoot cap, max-quality).
        if case .constantBitrateViaQstep(let bpp, let tol, let maxIter) = encodingConfiguration.bitrateMode {
            let (data, _) = try await encodeViaQstepSearch(
                image,
                targetBpp: bpp,
                tolerance: tol,
                maxIterations: maxIter,
                maxOvershootRatio: .infinity)
            return data
        }

        // v5.33.0 — `.constantBitrateBounded`: production-grade
        // quality-preserving bounded-rate mode with predictable
        // latency. At most `maxPasses` encodes (default 2). One
        // pass uses the calibration prior / cache; if the result
        // overshoots `maxOvershootRatio × target`, one corrective
        // pass at scaled qstep. No 8-iteration binary search.
        if case .constantBitrateBounded(let bpp, let maxOver, let maxPasses) =
            encodingConfiguration.bitrateMode {
            let (data, _) = try await encodeViaBoundedQstep(
                image,
                targetBpp: bpp,
                maxOvershootRatio: maxOver,
                maxPasses: maxPasses)
            return data
        }

        // v5.34.0 — `.constantBitrateStrict`: hard byte-cap mode.
        // Runs the v5.33.0 quality-first bounded Qstep search, then
        // truncates the codestream at the largest LRCP packet
        // boundary that still fits the cap. Because JPEG 2000 is
        // structurally truncatable, the result is a valid
        // (premature-EOC) codestream with a guaranteed byte budget.
        if case .constantBitrateStrict(let bpp, let maxOver, let maxPasses) =
            encodingConfiguration.bitrateMode {
            let (data, _) = try await encodeViaStrictBoundedQstep(
                image,
                targetBpp: bpp,
                maxOvershootRatio: maxOver,
                maxPasses: maxPasses)
            return data
        }

        // v5.31.0 — auto-promote `.constantBitrate` → Qstep-search
        // for HT-conformant lossy when the image bit-depth is ≥ 12
        // (medical workloads). PCRD-opt selects entire blocks at
        // once on conformant cleanup-only (single-pass, no mid-block
        // truncation), so block-level include/exclude decisions
        // become discrete and produce wildly scale-dependent quality
        // on high-bit-depth content (13–43 dB across the medical
        // corpus at 2 bpp). Qstep-search uses uniform quantisation
        // tuned to the byte target and produces consistent quality
        // across scale (~45–65 dB on the same corpus). This is the
        // correct λ formulation for this block format on
        // high-bit-depth content.
        //
        // The `≥ 12` gate avoids changing 8-bit (typically RGB
        // photographic) content where:
        //   1. PCRD-opt's block selection works fine — coefficient
        //      magnitudes are smaller, so cross-block R-D ranking
        //      doesn't collapse.
        //   2. The Qstep-search 8-iteration loop noticeably slows
        //      encoding, which matters for interactive workflows.
        //
        // Callers can opt out at any bit-depth by configuring
        // `.constantBitrateViaQstep` explicitly (no behaviour change
        // for them), `.fixedQstep` for strict-rate guarantees, or by
        // using a non-conformant HT block format / EBCOT / lossless
        // mode.
        // v5.34.0 — auto-promote .constantBitrate now uses the
        // **strict** bounded-rate path: same v5.33.0 quality-first
        // 3-pass Qstep search, followed by post-encode truncation
        // at packet boundaries to enforce the byte budget. This
        // restores the literal "constant bitrate" contract the
        // caller asked for: a hard upper bound on output size.
        //
        // Pre-v5.34, the auto-promote used `.constantBitrateBounded`
        // (best-effort 2.0× cap), which on flat-curve content (large
        // medical fixtures at low bpp) could overshoot by 3–4×. The
        // post-encode truncation step closes that gap structurally:
        // JPEG 2000 codestreams are LRCP-truncatable by design, so
        // dropping tail packets yields a valid smaller codestream
        // (and decodes to a progressively-degraded image, not a
        // corrupted one).
        //
        // For callers who want the v5.33.0 quality-first behaviour
        // (no truncation, may exceed target), use
        // `.constantBitrateBounded(bpp:)` explicitly.
        let maxBitDepth = image.components.map { $0.bitDepth }.max() ?? 8
        if case .constantBitrate(let bpp) = encodingConfiguration.bitrateMode,
           encodingConfiguration.useHTJ2K,
           !encodingConfiguration.lossless,
           !encodingConfiguration.useReversibleFilter,
           maxBitDepth >= 12 {
            let (data, _) = try await encodeViaStrictBoundedQstep(
                image, targetBpp: bpp,
                maxOvershootRatio: 1.0, maxPasses: 3)
            return data
        }

        // v5.39 M4 / v6-alpha1: experimental multi-tile HT lossless
        // path. Off by default. When the env-var `J2K_HT_TILE_MODE`
        // selects a multi-tile mode AND the encode is HT-conformant
        // lossless (the M4 scope), the planner picks a tile grid
        // and `J2KMultiTileEncoder` runs N per-tile encodes in
        // parallel, then stitches the codestreams. Each per-tile
        // encode uses the existing single-tile pipeline unchanged
        // so all M5/M7/M8/M9 wins persist inside each tile.
        if encodingConfiguration.lossless,
           encodingConfiguration.useHTJ2K,
           encodingConfiguration.useReversibleFilter,
           J2KEncodeTilePlanner.envMode != .single
        {
            let layout = J2KEncodeTilePlanner.plan(
                imageWidth: image.width,
                imageHeight: image.height,
                decompositionLevels: encodingConfiguration.decompositionLevels,
                mode: J2KEncodeTilePlanner.envMode)
            if layout.isMultiTile {
                let result = try await J2KMultiTileEncoder.encode(
                    image: image, layout: layout, configuration: encodingConfiguration)
                return result.codestream
            }
            // Layout fell back to single (small image / decomp floor) — proceed below.
        }

        // An explicit `tileSize` (SIZ XTsiz/YTsiz) goes through the native
        // multi-tile writer (#2330); every tile shares the decomposition depth
        // the smallest tile supports so the single COD stays valid.
        let tile = encodingConfiguration.tileSize
        if tile.width > 0, tile.height > 0, tile.width < image.width || tile.height < image.height {
            let cols = (image.width + tile.width - 1) / tile.width
            let rows = (image.height + tile.height - 1) / tile.height
            let layout = J2KTileLayout(
                cols: cols, rows: rows, tileWidth: tile.width, tileHeight: tile.height,
                imageWidth: image.width, imageHeight: image.height)
            var levels = encodingConfiguration.decompositionLevels
            for k in 0..<layout.tileCount {
                let rect = layout.rect(forTile: k)
                levels = min(levels, max(0, Int(log2(Double(min(rect.w, rect.h)))) - 1))
            }
            var configuration = encodingConfiguration
            configuration.decompositionLevels = levels
            let result = try await J2KMultiTileEncoder.encode(
                image: image, layout: layout, configuration: configuration)
            return result.codestream
        }

        return try await _singleTileEncode(image)
    }

    /// Single-tile pipeline entry point — what `encode(_:)` falls
    /// through to when the planner doesn't request multi-tile, and
    /// what `J2KMultiTileEncoder` calls to encode each per-tile
    /// sub-image. Bypasses the planner so multi-tile recursion is
    /// impossible.
    func _singleTileEncode(_ image: J2KImage) async throws -> Data {
        let pipeline = EncoderPipeline(config: encodingConfiguration)
        return try await pipeline.encode(image)
    }

    /// v6-alpha3 step 3: origin-aware per-tile entry point used
    /// by `J2KMultiTileEncoder` so each tile's DWT can apply
    /// parity-correct lifting at the tile's true image-coordinate
    /// origin. When (tileOriginX, tileOriginY) == (0, 0) the
    /// behaviour is byte-identical to `_singleTileEncode(_:)` —
    /// the parity-aware DWT routes to the no-origin fast path on
    /// every level. The wrap-and-stitch codestream assembler
    /// remains in place (v6-alpha3 step 5+ replaces it).
    func _singleTileEncode(
        _ image: J2KImage,
        tileOriginX: Int, tileOriginY: Int
    ) async throws -> Data {
        let pipeline = EncoderPipeline(config: encodingConfiguration)
        return try await pipeline.encode(
            image, tileOriginX: tileOriginX, tileOriginY: tileOriginY)
    }

    /// Encode with `.constantBitrateViaQstep` and return both the
    /// encoded data and diagnostic stats about the search loop.
    /// Useful for batch workflows to measure cache-hit rate, average
    /// iterations per encode, etc.
    ///
    /// The encoder configuration MUST have
    /// `bitrateMode == .constantBitrateViaQstep(...)` for this to be
    /// meaningful — other modes throw `J2KError.invalidParameter`.
    public func encodeWithQstepStats(_ image: J2KImage)
        async throws -> (data: Data, stats: J2KEncodeQstepStats)
    {
        guard case .constantBitrateViaQstep(let bpp, let tol, let maxIter) = encodingConfiguration.bitrateMode else {
            throw J2KError.invalidParameter(
                "encodeWithQstepStats requires .constantBitrateViaQstep mode")
        }
        return try await encodeViaQstepSearch(
            image,
            targetBpp: bpp,
            tolerance: tol,
            maxIterations: maxIter,
            maxOvershootRatio: .infinity)
    }

    /// Binary search on qstep until achieved bpp matches `targetBpp`
    /// within `tolerance`.
    ///
    /// v5.19.1 improvements over v5.19.0:
    /// 1. **Probe-based refinement**: the first iteration acts as a
    ///    probe — its result is used to scale the initial guess
    ///    (multiplicatively in log space) before binary search begins.
    ///    Empirical bpp/qstep relationship is content-dependent
    ///    (see V5_19_1_CALIBRATION.md), so a single probe outperforms
    ///    any static calibration table for non-typical content.
    /// 2. **Tighter initial bracket**: starts at [guess/16, guess*16]
    ///    instead of v5.19.0's [guess/64, guess*64]. Saves ~1
    ///    iteration on average.
    /// 3. **Cache lookup**: if a `J2KQstepCache` was set on the encoder
    ///    config, query it first using (bitDepth, components, target).
    ///    On cache hit, the cached qstep replaces the calibration
    ///    guess. After convergence, the result is stored back.
    /// 4. **Early-exit on bracket narrowing**: if [lower, upper] ratio
    ///    falls below 1.05 AND we've done ≥3 iterations, return the
    ///    closest achieved (within reach of tolerance, no point in
    ///    further narrowing).
    /// v5.33.0 production-grade quality-preserving bounded-rate
    /// encode with **predictable latency**.
    ///
    /// Runs **at most `maxPasses` encode passes**, total. Hard cap.
    /// Quality, rate, and latency are documented trade-offs:
    ///
    ///   - **Quality** is uniform-quantisation (same approach as
    ///     `.constantBitrateViaQstep`) — the search picks the qstep
    ///     and every coefficient is quantised by it. PSNR matches
    ///     the unbounded path on convergent content; on flat-curve
    ///     content it tracks the search's best-effort qstep within
    ///     the pass budget.
    ///
    ///   - **Rate** is best-effort capped at `maxOvershootRatio ×
    ///     target`. On typical content (small/medium fixtures, or
    ///     large fixtures at high bpp) the cap is met. On
    ///     pathological flat-curve content (large fixtures at very
    ///     low bpp) the search budget may run out before the cap
    ///     is hit; the closest-achieved encoding is returned. The
    ///     `J2KEncodeQstepStats.convergedWithinTolerance` flag
    ///     reports whether the cap was met.
    ///
    ///   - **Latency** is bounded: at most `maxPasses × single-
    ///     encode-time`. No flat-curve worst case (which v5.32.0's
    ///     11-pass refinement loop suffered from). For batch use
    ///     pass a `J2KQstepCache` so subsequent encodes hit cache
    ///     and converge in 1-2 passes.
    ///
    /// Algorithm: log-binary-search with adaptive bracket extension.
    /// Pass 1 uses the calibration prior or cached qstep. Pass 2
    /// scales by observed ratio (linear, since flat-curve content
    /// has α ≈ 0.13 — sub-linear under-corrects). Pass 3+ does
    /// log-binary-search; if achievement is still over cap and
    /// upper bound is hit, the bracket extends ×4.
    private func encodeViaBoundedQstep(
        _ image: J2KImage,
        targetBpp: Double,
        maxOvershootRatio: Double,
        maxPasses: Int
    ) async throws -> (Data, J2KEncodeQstepStats) {
        let totalSamples = image.width * image.height * image.componentCount
        guard totalSamples > 0 else {
            throw J2KError.invalidParameter("image has zero pixel area")
        }
        let targetBytes = Double(totalSamples) * targetBpp / 8.0
        let bitDepth = image.components.first?.bitDepth ?? 8
        let componentCount = image.components.count

        let cacheKey = J2KQstepCache.Key(
            bitDepth: bitDepth,
            componentCount: componentCount,
            targetBpp: targetBpp)
        // v9.6 — process-default fallback (see V9_6 research doc).
        let activeCache: J2KQstepCache? =
            encodingConfiguration.qstepCache
            ?? (J2KQstepCache.useProcessDefault ? J2KQstepCache.shared : nil)
        let cachedGuess = await activeCache?.lookup(cacheKey)
        let cacheHit = cachedGuess != nil
        let initialQstep = cachedGuess ?? Self.initialQstepGuess(
            targetBpp: targetBpp, bitDepth: bitDepth)

        var qstep = initialQstep
        var lower = qstep / 8.0
        var upper = qstep * 8.0
        var bestEncoded: Data = Data()
        var bestQstep: Double = qstep
        var bestRatio: Double = .infinity
        var passes = 0

        // Encode at qstep, return ratio. Updates `bestEncoded` with
        // the closest-to-1.0× ratio that's >= 0.9 (preferring valid
        // overshoot to undershoot).
        func encodeAt(_ q: Double) async throws -> (Data, Double) {
            var iterConfig = encodingConfiguration
            iterConfig.bitrateMode = .fixedQstep(qstep: q)
            iterConfig.lossless = false
            let pipeline = EncoderPipeline(config: iterConfig)
            let encoded = try await pipeline.encode(image)
            let ratio = Double(encoded.count) / targetBytes
            // Update best — prefer in-range over out-of-range, then
            // smaller overshoot, then larger undershoot.
            let valid = ratio >= 0.9
            let currentValid = bestRatio >= 0.9
            let shouldReplace: Bool
            if bestEncoded.isEmpty {
                shouldReplace = true
            } else if valid && !currentValid {
                shouldReplace = true
            } else if valid && currentValid {
                shouldReplace = ratio < bestRatio
            } else if !valid && !currentValid {
                shouldReplace = ratio > bestRatio
            } else {
                shouldReplace = false
            }
            if shouldReplace {
                bestEncoded = encoded
                bestQstep = q
                bestRatio = ratio
            }
            return (encoded, ratio)
        }

        let maxP = max(1, maxPasses)
        while passes < maxP {
            passes += 1
            let (_, ratio) = try await encodeAt(qstep)

            // Acceptable: within cap and not undershooting badly.
            if ratio <= maxOvershootRatio && ratio >= 0.9 {
                break
            }

            if passes >= maxP { break }

            if passes == 1 {
                // First refinement: ratio-scaled qstep + bracket
                // re-centred. Linear scaling matches the LL-band-
                // dominated bytes-vs-qstep relationship for high-
                // bit-depth medical (α ≈ 0.13 means doubling qstep
                // ≈ halves bytes only on high-α content; for low-α
                // we still scale by ratio as a first-order step).
                let refined = qstep * ratio
                let prior = Self.initialQstepGuess(targetBpp: targetBpp, bitDepth: bitDepth)
                qstep = max(prior / 32.0, min(prior * 32.0, refined))
                let bracketFactor = max(8.0, abs(log2(ratio)) * 8.0)
                lower = qstep / bracketFactor
                upper = qstep * bracketFactor
            } else {
                // Log-binary-search with dynamic bracket extension —
                // each step grows upper × 4 if we're still over at
                // the ceiling, so the search escapes flat curves.
                if ratio > 1.0 {
                    if qstep >= upper * 0.95 {
                        upper = upper * 4.0
                    }
                    lower = qstep
                    qstep = (qstep * upper).squareRoot()
                } else {
                    if qstep <= lower * 1.05 {
                        lower = lower / 4.0
                    }
                    upper = qstep
                    qstep = (qstep * lower).squareRoot()
                }
            }
        }

        if !bestEncoded.isEmpty {
            await activeCache?.store(cacheKey, qstep: bestQstep)
        }

        let achievedBpp = Double(bestEncoded.count * 8) / Double(totalSamples)
        let stats = J2KEncodeQstepStats(
            iterations: passes,
            initialQstep: initialQstep,
            convergedQstep: bestQstep,
            achievedBpp: achievedBpp,
            targetBpp: targetBpp,
            cacheHit: cacheHit,
            convergedWithinTolerance:
                bestRatio <= maxOvershootRatio && bestRatio >= 0.9)
        return (bestEncoded, stats)
    }

    /// v5.34.0 — strict bounded-rate encode with a HARD byte cap.
    ///
    /// Runs the v5.33.0 quality-first bounded Qstep search to find
    /// the best achievable quality, then — if and only if the result
    /// exceeds the cap — truncates the codestream at the largest LRCP
    /// packet boundary that still fits the cap.
    ///
    /// The truncation is structurally safe: JPEG 2000 codestreams
    /// are LRCP-progressive, so a packet-aligned truncation produces
    /// a valid smaller codestream that decodes (with conformant
    /// premature-EOC handling) to a progressively-degraded image.
    /// The retained packets keep the bounded mode's quality; the
    /// dropped tail packets cost detail in their corresponding
    /// resolution/component, typically the highest-frequency
    /// sub-bands at the highest resolution (LRCP visits these last).
    ///
    /// Output is byte-exact ≤ `maxOvershootRatio × target`. With the
    /// default `maxOvershootRatio: 1.0`, this means "never exceed
    /// target." Callers who want a relaxed cap can pass a larger
    /// value (e.g. 1.2× or 1.5×) — the search is only allowed to
    /// trigger truncation when the bounded result exceeds the cap,
    /// so a relaxed cap means strictly higher quality.
    ///
    /// Latency: at most `maxPasses` encode passes (default 3) plus
    /// a single O(packets) truncation pass (~µs).
    private func encodeViaStrictBoundedQstep(
        _ image: J2KImage,
        targetBpp: Double,
        maxOvershootRatio: Double,
        maxPasses: Int
    ) async throws -> (Data, J2KEncodeQstepStats) {
        let totalSamples = image.width * image.height * image.componentCount
        guard totalSamples > 0 else {
            throw J2KError.invalidParameter("image has zero pixel area")
        }
        let targetBytes = Double(totalSamples) * targetBpp / 8.0
        let cap = max(targetBytes * maxOvershootRatio, 1.0)
        let bitDepth = image.components.first?.bitDepth ?? 8
        let componentCount = image.components.count

        let cacheKey = J2KQstepCache.Key(
            bitDepth: bitDepth,
            componentCount: componentCount,
            targetBpp: targetBpp)
        // v9.6 — process-default fallback: when the caller's
        // configuration does not specify an explicit qstepCache,
        // consult the process-wide shared cache (gated by
        // `J2K_DISABLE_PROCESS_QSTEP_CACHE`). Batch workflows of
        // similar-shape content now skip 2–3 qstep-search passes on
        // every encode after the first. Explicit caller-supplied
        // caches still take precedence.
        let activeCache: J2KQstepCache? =
            encodingConfiguration.qstepCache
            ?? (J2KQstepCache.useProcessDefault ? J2KQstepCache.shared : nil)
        let cachedGuess = await activeCache?.lookup(cacheKey)
        let cacheHit = cachedGuess != nil
        let initialQstep = cachedGuess ?? Self.initialQstepGuess(
            targetBpp: targetBpp, bitDepth: bitDepth)

        var qstep = initialQstep
        var lower = qstep / 8.0
        var upper = qstep * 8.0
        var bestIndexed: EncodedCodestreamWithIndex? = nil
        var bestQstep: Double = qstep
        var bestRatio: Double = .infinity
        var passes = 0

        func encodeAt(_ q: Double) async throws -> (EncodedCodestreamWithIndex, Double) {
            var iterConfig = encodingConfiguration
            iterConfig.bitrateMode = .fixedQstep(qstep: q)
            iterConfig.lossless = false
            let pipeline = EncoderPipeline(config: iterConfig)
            // v5.36-tuning: multi-precinct strict mode with PPx=PPy=8
            // → 256 LL precinct, 128 sub-band precincts at r > 0.
            // For px_001-class fixtures this produces ~85 packets
            // total (vs PPx=10's 12); the additional truncation
            // boundaries push budget-fill on the highest-resolution
            // band closer to the cap. The previously-suspected SIGTRAP
            // at PPx<10 was a stale symptom of the single-precinct
            // decoder bug fixed in this same release; with the decoder
            // fix in place, PPx 5-10 all round-trip cleanly through
            // CPU `decode`, `decodeGPU`, `decodeWithGPUHT`, OpenJPEG,
            // OpenJPH, and Grok on px_001 / dx_002 / synthetic.
            let pps = Array(
                repeating: EncoderPipeline.PrecinctExponents(widthExp: 8, heightExp: 8),
                count: encodingConfiguration.decompositionLevels + 1)
            let indexed = try await pipeline.encodeMultiPrecinctWithPacketIndex(
                image, qstep: q, precinctExponents: pps)
            let ratio = Double(indexed.data.count) / targetBytes
            // STRICT-MODE preference: overshoot is recoverable via
            // packet-boundary truncation (caps the bytes at target).
            // Undershoot wastes the budget — fewer bytes than the
            // user paid for, no truncation can recover from it. So
            // prefer ANY overshoot over ANY undershoot, and among
            // overshoots prefer smaller ones (less truncation loss).
            // Among undershoots, prefer larger ratios (closer to
            // filling the budget).
            let isOvershoot = ratio >= 1.0
            let isCurrentOvershoot = bestRatio >= 1.0
            let shouldReplace: Bool
            if bestIndexed == nil {
                shouldReplace = true
            } else if isOvershoot && !isCurrentOvershoot {
                shouldReplace = true  // overshoot recoverable via truncation
            } else if isOvershoot && isCurrentOvershoot {
                shouldReplace = ratio < bestRatio  // smaller overshoot wastes less encode work
            } else if !isOvershoot && !isCurrentOvershoot {
                shouldReplace = ratio > bestRatio  // larger undershoot fills more budget
            } else {
                shouldReplace = false  // current is overshoot, new is undershoot — keep current
            }
            if shouldReplace {
                bestIndexed = indexed
                bestQstep = q
                bestRatio = ratio
            }
            return (indexed, ratio)
        }

        let maxP = max(1, maxPasses)
        while passes < maxP {
            passes += 1
            let (_, ratio) = try await encodeAt(qstep)

            // Stop when we have an overshoot in [1.0, 4.0] — truncation
            // will trim it to exactly the cap. No need to refine
            // further; the retained packets keep the search's quality.
            // Also stop on a near-target undershoot (≥ 0.95×) where
            // further refinement is unlikely to gain meaningful budget.
            if ratio >= 1.0 && ratio <= 4.0 { break }
            if ratio >= 0.95 && ratio < 1.0 { break }
            if passes >= maxP { break }

            if passes == 1 {
                let refined = qstep * ratio
                let prior = Self.initialQstepGuess(targetBpp: targetBpp, bitDepth: bitDepth)
                qstep = max(prior / 32.0, min(prior * 32.0, refined))
                let bracketFactor = max(8.0, abs(log2(ratio)) * 8.0)
                lower = qstep / bracketFactor
                upper = qstep * bracketFactor
            } else {
                if ratio > 1.0 {
                    if qstep >= upper * 0.95 {
                        upper = upper * 4.0
                    }
                    lower = qstep
                    qstep = (qstep * upper).squareRoot()
                } else {
                    // STRICT-MODE: persistent undershoot on flat-curve
                    // content needs aggressive descent. Extend the
                    // lower bracket if we're stuck near it AND the
                    // current ratio is well under 1.0 (suggesting the
                    // saturation point is below).
                    if qstep <= lower * 1.05 || ratio < 0.5 {
                        lower = lower / 4.0
                    }
                    upper = qstep
                    qstep = (qstep * lower).squareRoot()
                }
            }
        }

        guard let indexed = bestIndexed else {
            throw J2KError.encodingError("strict bounded-rate search produced no result")
        }

        // v9.6 — store converged qstep into whichever cache was used
        // for the lookup (caller's explicit cache, else the process-
        // default). Storing back to the explicit cache when one is
        // present preserves the prior caller-isolated batching semantics.
        await activeCache?.store(cacheKey, qstep: bestQstep)

        // Apply the strict cap via packet-boundary truncation.
        let capBytes = Int(cap.rounded(.down))
        // v5.37 R-D evolution — current state: TWO infrastructures
        // exist, neither yet wired into the default.
        //
        //   1. `truncateByRDOptimized` (NEGATIVE) — ranks non-LL
        //      packets by per-byte L2-norm² weight (resolution-only
        //      heuristic, no coefficient data). Regressed PSNR 1-2
        //      dB across the corpus by greedily favouring highest-
        //      resolution detail and dropping intermediate resolutions,
        //      breaking the wavelet synthesis chain.
        //
        //   2. `truncateByConstrainedRD` (NEW) — keeps the LRCP
        //      dependency floor (LL + every intermediate resolution)
        //      intact, runs greedy R-D selection on highest-resolution
        //      precincts only using the ACTUAL `coefficientSquaredSum
        //      × L2norm²` populated per packet at emission time.
        //      Standalone benchmark on raw multi-precinct codestreams:
        //      px_001 @ 4 bpp +0.11 dB, dx_002 @ 4 bpp +0.39 dB. But:
        //      under the FULL strict-mode flow (which uses qstep
        //      search to land within or marginally over the cap), the
        //      truncator sees no overshoot at low bpp on 16-bit
        //      medical fixtures, so R-D falls back identically to
        //      LRCP-prefix. Net under strict-mode flow: +0 dB at 2
        //      bpp, +0.08 dB at px_001 4 bpp, +0.19 dB at dx_002 4
        //      bpp. Doesn't satisfy the "improve at 2 bpp AND 4 bpp"
        //      gate — keep LRCP-prefix as the strict-mode default.
        //
        // Both infrastructures stay in-source for future work pairing
        // R-D selection with deliberately-overshooting qstep choice
        // (so the truncator has real selection power even at low bpp).
        // See MEDICAL_BENCHMARK.md "v5.37 constrained-R-D".
        let finalData = EncoderPipeline.truncateAtPacketBoundary(
            indexed, targetBytes: capBytes
        )

        let achievedBpp = Double(finalData.count * 8) / Double(totalSamples)
        let achievedRatio = Double(finalData.count) / targetBytes
        // budgetFillRatio = achievedBytes / cap. 1.0 = at cap; 0.5 =
        // half the budget left unused. v5.34 lands at 0.3-0.6 on flat-
        // curve; v5.35's multi-layer strict mode targets 0.85+.
        let fillRatio = cap > 0 ? Double(finalData.count) / cap : nil
        let stats = J2KEncodeQstepStats(
            iterations: passes,
            initialQstep: initialQstep,
            convergedQstep: bestQstep,
            achievedBpp: achievedBpp,
            targetBpp: targetBpp,
            cacheHit: cacheHit,
            convergedWithinTolerance:
                achievedRatio <= maxOvershootRatio && achievedRatio >= 0.5,
            budgetFillRatio: fillRatio)
        return (finalData, stats)
    }

    private func encodeViaQstepSearch(
        _ image: J2KImage,
        targetBpp: Double,
        tolerance: Double,
        maxIterations: Int,
        maxOvershootRatio: Double = 2.0
    ) async throws -> (Data, J2KEncodeQstepStats) {
        let totalSamples = image.width * image.height * image.componentCount
        guard totalSamples > 0 else {
            throw J2KError.invalidParameter("image has zero pixel area")
        }
        let targetBytes = Double(totalSamples) * targetBpp / 8.0
        let bitDepth = image.components.first?.bitDepth ?? 8
        let componentCount = image.components.count

        // 1. Initial guess: cache > calibration table.
        let cacheKey = J2KQstepCache.Key(
            bitDepth: bitDepth,
            componentCount: componentCount,
            targetBpp: targetBpp)
        // v9.6 — process-default fallback (see V9_6 research doc).
        let activeCache: J2KQstepCache? =
            encodingConfiguration.qstepCache
            ?? (J2KQstepCache.useProcessDefault ? J2KQstepCache.shared : nil)
        let cachedGuess = await activeCache?.lookup(cacheKey)
        let cacheHit = cachedGuess != nil
        let initialQstep = cachedGuess ?? Self.initialQstepGuess(
            targetBpp: targetBpp, bitDepth: bitDepth)
        var qstep = initialQstep

        // 2. Tighter initial bracket. v5.19.0 used 64×; halve the log
        //    span. Probe-refinement below adapts further.
        var lower = qstep / 16.0
        var upper = qstep * 16.0

        var bestEncoded: Data = Data()
        var bestRatioErr = Double.infinity
        var bestQstep = qstep
        var iterationCount = 0

        while iterationCount < max(1, maxIterations) {
            iterationCount += 1
            // Encode with current qstep candidate.
            var iterConfig = encodingConfiguration
            iterConfig.bitrateMode = .fixedQstep(qstep: qstep)
            iterConfig.lossless = false
            let pipeline = EncoderPipeline(config: iterConfig)
            let encoded = try await pipeline.encode(image)
            let achievedBytes = Double(encoded.count)
            let ratio = achievedBytes / targetBytes
            let ratioErr = abs(ratio - 1.0)
            if ratioErr < bestRatioErr {
                bestRatioErr = ratioErr
                bestEncoded = encoded
                bestQstep = qstep
            }
            if ratioErr < tolerance {
                // Cache the successful qstep for future similar images.
                await activeCache?.store(cacheKey, qstep: qstep)
                let stats = J2KEncodeQstepStats(
                    iterations: iterationCount,
                    initialQstep: initialQstep,
                    convergedQstep: qstep,
                    achievedBpp: Double(encoded.count * 8) / Double(totalSamples),
                    targetBpp: targetBpp,
                    cacheHit: cacheHit,
                    convergedWithinTolerance: true)
                return (encoded, stats)
            }

            // 3. After the first iteration acts as a probe, scale the
            //    qstep based on observed bytes-vs-target ratio. This is
            //    the v5.19.1 probe-based refinement: works in log space
            //    so multiplicative errors compose. Past empirical data:
            //    bpp ≈ k * qstep^-α with α∈[0.13, 1.03] depending on
            //    bit-depth and content. Using α=1.0 as a first-order
            //    correction; the residual error is what subsequent
            //    binary-search steps clean up.
            if iterationCount == 1 {
                // Refine: multiply qstep by the achieved/target ratio.
                // Higher achieved bytes → need higher qstep (coarser
                // quantization → smaller output).
                let scaleHint = ratio
                let refined = qstep * scaleHint
                // Clamp to within an order of magnitude of the
                // calibration prior (avoids runaway on outliers).
                let priorGuess = Self.initialQstepGuess(
                    targetBpp: targetBpp, bitDepth: bitDepth)
                qstep = max(priorGuess / 32, min(priorGuess * 32, refined))
                // v5.31.0 — widen the bracket when iter-1 ratio is
                // far from 1.0. The previous fixed `±8×` bracket was
                // too narrow for HT-conformant high-bitdepth content
                // (16-bit medical) where the bytes-vs-qstep curve is
                // very flat; iter-2..8 converge to upper-cap without
                // hitting target. Scale the upper bracket by the
                // observed ratio so we always have headroom to grow.
                let bracketFactor = max(8.0, abs(log2(scaleHint)) * 8.0)
                lower = qstep / bracketFactor
                upper = qstep * bracketFactor
                continue
            }

            // 4. Standard log-binary-search narrowing for iter ≥ 2.
            //    v5.31.0 — extend the upper bound dynamically when
            //    the search keeps hitting the ceiling (bytes still
            //    over target at qstep ≈ upper). Without this, very-
            //    flat curves produce a terminated-but-not-converged
            //    result with bytes far above target.
            if achievedBytes > targetBytes {
                if qstep >= upper * 0.95 {
                    upper = upper * 4.0  // widen ceiling
                }
                lower = qstep
                qstep = (qstep * upper).squareRoot()
            } else {
                if qstep <= lower * 1.05 {
                    lower = lower / 4.0  // widen floor
                }
                upper = qstep
                qstep = (qstep * lower).squareRoot()
            }

            // 5. Early-exit when bracket has narrowed but tolerance not
            //    reached — further iterations won't help meaningfully.
            //    This kicks in when the bytes/qstep curve is nearly
            //    flat at the target (16-bit medical content can have
            //    α as low as 0.13 — qstep changes hardly move bpp).
            if iterationCount >= 3 && (upper / lower) < 1.05 {
                break
            }
        }

        // v5.32.0 — bounded-rate refinement.
        //
        // The main search may terminate without hitting tolerance on
        // flat-curve content (16-bit medical at low bpp can have
        // bytes-vs-qstep slope as low as α=0.13, so even at upper
        // bracket the bytes stay over target). When that happens
        // the closest-achieved encoding can overshoot the target
        // significantly — the v5.31.0 cross-scale probe showed
        // 1.6–3× overshoot at 2 bpp on large fixtures.
        //
        // Bounded-rate refinement: after the main search, if
        // achieved bytes still exceed `maxOvershootRatio × target`,
        // run up to 3 additional iterations that aggressively scale
        // qstep up to push bytes down. Each iteration multiplies
        // qstep by `ratio^0.7` (sub-linear so we don't overshoot
        // the other direction; works for α≈0.13–1.0 curves). Stop
        // when within bound, when no further byte reduction is
        // achieved, or when the iteration cap is hit.
        //
        // Trade-off: caps the rate overshoot at the cost of some
        // PSNR (typically 5–10 dB) on the worst-overshoot cases.
        // The user spec is "bounded rate, keep most of the quality" —
        // this delivers both within the realistic bounds of the
        // conformant cleanup-only block format.
        var refinementIters = 0
        let maxRefinementIters = 3
        // v9.8 — pre-existing bug fix: when `maxOvershootRatio` is
        // `.infinity` (the path taken by `encodeWithQstepStats`),
        // `Int(targetBytes * .infinity)` traps with SIGTRAP. Comparing
        // in Double space lets `infinity` short-circuit cleanly:
        // `Double(count) > .infinity` is always false, so the
        // refinement loop is correctly disabled in the infinite-cap
        // case.
        while Double(bestEncoded.count) > targetBytes * maxOvershootRatio,
              refinementIters < maxRefinementIters {
            refinementIters += 1
            let currentRatio = Double(bestEncoded.count) / targetBytes
            // Aggressive but stable: ratio^0.7 advances faster than
            // a pure log step but doesn't overshoot the other direction.
            let scaleFactor = pow(currentRatio, 0.7)
            let newQstep = bestQstep * scaleFactor

            var iterConfig = encodingConfiguration
            iterConfig.bitrateMode = .fixedQstep(qstep: newQstep)
            iterConfig.lossless = false
            let pipeline = EncoderPipeline(config: iterConfig)
            let refined = try await pipeline.encode(image)

            // Accept only if it makes progress AND doesn't push under
            // target (don't trade overshoot for undershoot — the
            // user wants bounded above-target, not strict-below).
            if refined.count >= bestEncoded.count {
                // No progress (qstep increase didn't reduce bytes —
                // we may be hitting a structural floor like LL
                // overhead). Stop.
                break
            }
            if Double(refined.count) < targetBytes * 0.9 {
                // Undershoot — qstep was too aggressive. Don't
                // accept; keep the previous over-target encoding
                // since over-target is better than undershoot for
                // bounded mode.
                break
            }
            bestEncoded = refined
            bestQstep = newQstep
            iterationCount += 1
        }

        // Convergence either succeeded above or fell back to closest-
        // achieved. Cache the best qstep regardless — even if we
        // didn't hit tolerance, this is the encoder's best estimate.
        await activeCache?.store(cacheKey, qstep: bestQstep)
        let achievedBpp = Double(bestEncoded.count * 8) / Double(totalSamples)
        let stats = J2KEncodeQstepStats(
            iterations: iterationCount,
            initialQstep: initialQstep,
            convergedQstep: bestQstep,
            achievedBpp: achievedBpp,
            targetBpp: targetBpp,
            cacheHit: cacheHit,
            convergedWithinTolerance:
                abs(achievedBpp / targetBpp - 1.0) < tolerance)
        return (bestEncoded, stats)
    }

    /// Calibrated initial qstep for a (targetBpp, bitDepth) pair.
    /// Empirically derived from J2KSwift's HT conformant lossy path
    /// on natural-image content. The binary search refines from here.
    /// Values targeted at within ~50% of the converged qstep on a
    /// typical natural image; the search burns 2–3 iterations beyond
    /// that to converge to within 5% tolerance.
    private static func initialQstepGuess(targetBpp: Double, bitDepth: Int) -> Double {
        // J2KSwift's qstep semantics differ from OpenJPH's — see
        // V5_18_0_DESIGN.md and v5.18.0 release notes. These
        // calibrations match J2KSwift's `J2KStepSizeCalculator`.
        // Empirically: bytes ≈ k / qstep on natural images, so for
        // a target bpp B we estimate qstep ≈ k / B where k depends
        // on bit-depth.
        let bd = max(8, bitDepth)
        let k: Double
        switch bd {
        case 8:    k = 80.0
        case 9...12:  k = 50.0
        default:   k = 30.0   // 16-bit and beyond
        }
        return k / max(0.05, targetBpp)
    }

    /// Encodes an image to JPEG 2000 format with progress reporting.
    ///
    /// - Parameters:
    ///   - image: The image to encode.
    ///   - progress: A callback invoked with progress updates during encoding.
    /// - Returns: The encoded JPEG 2000 codestream data.
    /// - Throws: ``J2KError`` if encoding fails.
    public func encode(
        _ image: J2KImage,
        progress: ((EncoderProgressUpdate) -> Void)?
    ) async throws -> Data {
        let pipeline = EncoderPipeline(config: encodingConfiguration)
        return try await pipeline.encode(image, progress: progress)
    }

    /// True when the active bitrate mode triggers J2KEncoder.encode's
    /// CPU-side interception (Qstep search, bounded, strict, or
    /// `.constantBitrate` auto-promote on bitDepth ≥ 12 HT-conformant
    /// lossy). Used to keep the GPU entry points consistent with the
    /// CPU entry point's codestream output.
    private func shouldRouteThroughInterceptedEncode(image: J2KImage) -> Bool {
        switch encodingConfiguration.bitrateMode {
        case .constantBitrateViaQstep, .constantBitrateBounded, .constantBitrateStrict:
            return true
        case .constantBitrate:
            // Auto-promote condition mirrors `encode(_:)`. Includes
            // the bitDepth ≥ 12 gate so 8-bit content (which goes
            // straight to PCRD on `encode()`) also stays on the GPU
            // PCRD path here.
            let maxBitDepth = image.components.map { $0.bitDepth }.max() ?? 8
            return encodingConfiguration.useHTJ2K
                && !encodingConfiguration.lossless
                && !encodingConfiguration.useReversibleFilter
                && maxBitDepth >= 12
        default:
            return false
        }
    }
}

/// Decodes JPEG 2000 images.
///
/// `J2KDecoder` provides a high-level API for decoding JPEG 2000 codestreams to images.
/// It connects all decoding components — codestream parsing, entropy decoding, dequantization,
/// inverse wavelet transform, and inverse colour transform — into a complete decoding pipeline.
///
/// ## Basic Usage
///
/// ```swift
/// let decoder = J2KDecoder()
/// let codestreamData = // ... load from file
/// let image = try decoder.decode(codestreamData)
/// ```
///
/// ## Progress Reporting
///
public struct J2KDecoder: Sendable {
    /// Byte order of 16-bit output samples; each component's `sampleByteOrder` states it.
    public var sampleByteOrder: J2KComponent.ByteOrder

    /// Creates a new decoder.
    public init(sampleByteOrder: J2KComponent.ByteOrder = .bigEndian) {
        self.sampleByteOrder = sampleByteOrder
    }

    /// A pipeline that writes this decoder's sample byte order.
    func makePipeline() -> DecoderPipeline {
        var pipeline = DecoderPipeline()
        pipeline.outputByteOrder = sampleByteOrder
        return pipeline
    }


    /// Decodes JPEG 2000 data into an image.
    ///
    /// This method processes the codestream through the complete JPEG 2000 decoding pipeline:
    /// 1. Codestream parsing and marker validation
    /// 2. Tile data extraction from packets
    /// 3. EBCOT entropy decoding
    /// 4. Dequantization
    /// 5. Inverse wavelet transform
    /// 6. Inverse colour transform (YCbCr → RGB)
    /// 7. Image reconstruction
    ///
    /// - Parameter data: The JPEG 2000 codestream data to decode.
    /// - Returns: The decoded image.
    /// - Throws: ``J2KError/decodingError(_:)`` if decoding fails.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if the codestream is malformed.
    public func decode(_ data: Data) async throws -> J2KImage {
        // v6.2.0 D3 — pre-set the process-shared Metal session so the
        // GPU paths gated by `DecoderPipeline._gpuInverse53Enabled` /
        // `_gpuHTEntropyEnabled` (D1 #314 / D2 #315) actually
        // amortise their cold-start cost across decodes. Without
        // this, every fresh `J2KDecoder().decode()` paid ~25-30 ms
        // Metal init per call (the v5.28.0 preWarm finding) which
        // dominated the GPU paths' wall time. Setting it here is
        // safe even when the gates are off — CPU paths don't
        // consult `metalSession`.
        let pipeline = makePipeline()
        return try await pipeline.decode(data)
    }

    /// v10.5.0 Stage B.1+B.2 — internal entry point that sets up
    /// the pipeline for partial-resolution decode:
    ///   - `partialResolutionLevel = level` (B.1) — extract filters
    ///     code-blocks to skip entropy decode for higher-resolution
    ///     bands
    ///   - `outputDimensions = (W, H) >> (N - level)` (B.2) —
    ///     downstream stages allocate reduced buffers; the inverse
    ///     DWT truncates to `level` steps and outputs reduced data
    ///     directly
    ///
    /// Returns an image already at the requested resolution; no
    /// downsample step needed. For level = N (full resolution), the
    /// pipeline behaves exactly as `decode()` (byte-identical).
    func decodePartialResolution(data: Data, level: Int, maxLayer: Int? = nil, session: J2KDecodeSessionState? = nil) async throws -> J2KImage {
        var pipeline = makePipeline()
        pipeline.partialResolutionLevel = level
        pipeline.maxQualityLayer = maxLayer
        pipeline.partialAccounting = session?.accounting
        pipeline.layeredBlockCache = session?.cache

        // Compute reduced output dimensions from a metadata peek.
        // The peek pays one extra codestream parse (~2-5 ms) — small
        // relative to the partial-decode savings on large fixtures.
        // For level == N (full resolution) outputDimensions stays
        // nil and the decode behaves identically to `decode()`.
        let metadata = try DecoderPipeline.peekMetadata(data)
        let N = metadata.configuration.decompositionLevels

        // v10.25 — multi-tile codestreams take the same truncated-
        // iDWT path as single-tile: each tile's per-tile iDWT stops
        // at the requested level (with parity origins anchored to
        // the true canvas depth via `outputDepthOffset`) and
        // `compositeTile` maps the reduced-dimension tile outputs
        // into the reduced canvas with ceil-div offsets per
        // ISO/IEC 15444-1. The earlier decode-then-downsample
        // fallback (correct pixels, full-decode cost) is gone.
        if level >= 0 && level < N {
            let halvings = N - level
            let factor = 1 << halvings
            let outW = (metadata.width + factor - 1) / factor
            let outH = (metadata.height + factor - 1) / factor
            pipeline.outputDimensions = (width: outW, height: outH)
        }
        return try await pipeline.decode(data)
    }

    /// v10.6.0 ROI decode — internal entry point for true region-of-
    /// interest decode. Sets `pipeline.regionOfInterest` so that
    /// `extractTileData` skips entropy decode for every code-block
    /// whose inverse-DWT spatial footprint does not overlap the
    /// region. The inverse DWT still runs full-tile, so the returned
    /// image carries the full codestream dimensions — the caller
    /// (`decodeRegion`) crops it to the region. Because every block
    /// influencing an in-region pixel is retained, the cropped result
    /// is bit-identical to a full `decode()` followed by the same crop.
    func decodeRegionDirect(data: Data, region: J2KRegion, maxLayer: Int? = nil, session: J2KDecodeSessionState? = nil) async throws -> J2KImage {
        var pipeline = makePipeline()
        pipeline.regionOfInterest = region
        pipeline.maxQualityLayer = maxLayer
        pipeline.partialAccounting = session?.accounting
        pipeline.layeredBlockCache = session?.cache
        return try await pipeline.decode(data)
    }

    /// v10.9.0 quality-layer decode — internal entry point for
    /// `decodeQuality`. Sets `pipeline.maxQualityLayer` so the
    /// multi-layer packet decode (`extractTileDataMultiLayer`)
    /// processes only quality layers `0...maxLayer`. On a single-layer
    /// codestream `maxQualityLayer` is ignored and this is a plain
    /// `decode()`.
    func decodeQualityLayers(data: Data, maxLayer: Int, session: J2KDecodeSessionState? = nil) async throws -> J2KImage {
        var pipeline = makePipeline()
        pipeline.maxQualityLayer = maxLayer
        pipeline.partialAccounting = session?.accounting
        pipeline.layeredBlockCache = session?.cache
        return try await pipeline.decode(data)
    }

    /// Accounting and tier-2 cache handed to the pipeline by the reporting APIs and refinement sessions (issue #2382).
    struct J2KDecodeSessionState {
        let accounting: J2KPartialDecodeAccounting
        let cache: J2KLayeredBlockCache?
    }

    /// Decodes JPEG 2000 data into an image with progress reporting.
    ///
    /// - Parameters:
    ///   - data: The JPEG 2000 codestream data to decode.
    ///   - progress: A callback invoked with progress updates during decoding.
    /// - Returns: The decoded image.
    /// - Throws: ``J2KError`` if decoding fails.
    public func decode(
        _ data: Data,
        progress: ((DecoderProgressUpdate) -> Void)?
    ) async throws -> J2KImage {
        // v6.2.0 D3 — see no-progress overload above.
        let pipeline = makePipeline()
        return try await pipeline.decode(data, progress: progress)
    }

}
