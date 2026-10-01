// J2KQstepCache.swift
// v5.19.1 — qstep cache for `.constantBitrateViaQstep` batch workflows.
//
// Many real-world workflows encode hundreds or thousands of similar
// images: a DICOMKit pipeline encoding a CT scan series (same width
// × height × bit-depth × target bpp), an archive run on a directory
// of pathology slides, etc. v5.19.0's binary-search-on-qstep takes
// 4–6 encode iterations per image — wasted work when the converged
// qstep is virtually identical across the batch.
//
// J2KQstepCache stores (image-class → converged qstep) pairs.
// `J2KEncoder.encodeViaQstepSearch` consults the cache for its
// initial guess and stores the converged qstep back. With a warm
// cache, subsequent images converge in 1–2 iterations instead of
// 4–6, cutting `.constantBitrateViaQstep`'s overhead by ~70%.
//
// Image class key: (bitDepth, componentCount, targetBpp). Width and
// height are intentionally excluded — qstep at convergence depends
// primarily on coefficient distribution per pixel, which is more
// strongly correlated with bit-depth + bpp than with image size.
// (For pathological workflows where width/height should partition
// the cache, the user can use multiple `J2KQstepCache` instances
// sharded by their own key.)

import Foundation

/// Thread-safe cache mapping image-class keys to converged qstep
/// values for `.constantBitrateViaQstep` workflows.
///
/// Use one cache per logical batch of similar images. Pass via
/// `J2KEncodingConfiguration.qstepCache`. Cache hits skip 2–4
/// binary-search iterations on average.
public actor J2KQstepCache {

    /// Cache key — combines the image properties that primarily
    /// determine the converged qstep at a given target bpp.
    public struct Key: Hashable, Sendable {
        public let bitDepth: Int
        public let componentCount: Int
        /// Target bpp rounded to 0.01 to allow modest variation
        /// (e.g. 1.99 vs 2.00) to share a cache entry.
        public let targetBppBucket: Int

        public init(bitDepth: Int, componentCount: Int, targetBpp: Double) {
            self.bitDepth = bitDepth
            self.componentCount = componentCount
            self.targetBppBucket = Int((targetBpp * 100.0).rounded())
        }
    }

    private var cache: [Key: Double] = [:]

    public init() {}

    /// Look up a cached qstep. Returns `nil` on miss.
    public func lookup(_ key: Key) -> Double? {
        return cache[key]
    }

    /// Store a converged qstep for future lookups. Overwrites any
    /// existing entry — the most recent successful convergence is
    /// always the best initial guess.
    public func store(_ key: Key, qstep: Double) {
        cache[key] = qstep
    }

    /// Clear all cached entries. Useful when starting a new logical
    /// batch with different content characteristics.
    public func clear() {
        cache.removeAll(keepingCapacity: true)
    }

    /// Current cache size, for diagnostics.
    public var count: Int {
        return cache.count
    }

    /// v9.6 — process-default shared cache. Used as a fallback by
    /// `J2KEncoder.encodeViaStrictBoundedQstep` (and the other qstep-
    /// search paths) when the caller's encoding configuration does not
    /// specify an explicit `qstepCache`.
    ///
    /// **Rationale**: cold-cache encodes of medical 16-bit content
    /// converge in 2–3 qstep-search iterations (~99 ms on DX
    /// 2800×2288 / M4), whereas a single cache-hit encode converges
    /// in 1 iteration (~30 ms). Sharing one cache across the process
    /// lets the second and later encodes of similar-shape content
    /// (same bit-depth + components + bpp bucket) skip the search
    /// entirely. For batch DICOM workflows — the primary use case —
    /// this drops the per-image wall ~3× without any user opt-in.
    ///
    /// **v9.7 research note**: a pre-seeded variant was prototyped to
    /// also accelerate the cold-shot first encode, but the converged
    /// qstep range across real medical content is too wide (mr_001
    /// converges at ~0.6, dx_002 at ~1961) for any single seed to
    /// be safe. A seed sized for dx-class content puts the
    /// `.constantBitrateViaQstep` search bracket above mr-class
    /// content's optimum, producing significant PSNR regressions
    /// (~27 dB vs ~33 dB expected). The pre-seed was reverted —
    /// see `V9_7_COLD_SHOT_RESEARCH.md` for the methodology and the
    /// image-statistics-based prediction path forward.
    ///
    /// Users who need cold-cache behaviour can opt out by setting the
    /// environment variable `J2K_DISABLE_PROCESS_QSTEP_CACHE=1`, or
    /// by passing a fresh `J2KQstepCache()` per encode via the
    /// configuration.
    public static let shared: J2KQstepCache = J2KQstepCache()

    /// Whether the process-default `shared` cache should be used as a
    /// fallback when `J2KEncodingConfiguration.qstepCache` is `nil`.
    /// Defaults to `true`; opt out via `J2K_DISABLE_PROCESS_QSTEP_CACHE`.
    public static let useProcessDefault: Bool = {
        if let v = ProcessInfo.processInfo.environment["J2K_DISABLE_PROCESS_QSTEP_CACHE"] {
            switch v.lowercased() {
            case "1", "true", "yes": return false
            case "0", "false", "no": return true
            default: break
            }
        }
        return true
    }()
}

/// Diagnostic stats from a `.constantBitrateViaQstep` search loop.
/// Returned alongside encoded data by
/// `J2KEncoder.encodeWithQstepStats(_:)`.
///
/// Useful for batch workflows to measure cache effectiveness, average
/// iterations, and convergence quality.
public struct J2KEncodeQstepStats: Sendable {
    /// Number of encode iterations the search loop performed.
    /// 1 means the very first iteration converged within tolerance
    /// (typically only happens with a hot cache hit on identical content).
    public let iterations: Int

    /// The qstep used for the first iteration. Either from the
    /// `J2KQstepCache` (if `cacheHit == true`) or from the calibration
    /// table fallback.
    public let initialQstep: Double

    /// The qstep at which the search converged (or the closest-
    /// achieved iteration if convergence didn't reach tolerance).
    public let convergedQstep: Double

    /// Bits per pixel actually achieved by the converged encode.
    public let achievedBpp: Double

    /// The user-requested target bpp.
    public let targetBpp: Double

    /// Whether the initial qstep came from the cache (vs the
    /// calibration table fallback). True for warm cache, false for
    /// cold cache or no cache.
    public let cacheHit: Bool

    /// Whether the search reached the user-specified tolerance. False
    /// if the encoder fell back to the closest-achieved iteration
    /// because `maxIterations` was exhausted or the bracket narrowed
    /// below the tolerance limit (16-bit content with low α).
    public let convergedWithinTolerance: Bool

    /// v5.35.0 — fraction of the byte cap that the final output uses,
    /// for strict bounded-rate mode. Defined as `achievedBytes /
    /// (maxOvershootRatio × targetBytes)`. 1.0 means "exactly at cap";
    /// 0.5 means "used half the cap, the rest could in principle have
    /// been spent on quality".
    ///
    /// `nil` for non-strict modes (the metric is only meaningful when
    /// there's a hard cap to fill against).
    ///
    /// On flat-curve high-bit-depth content (large fixtures at low
    /// bpp) v5.34's strict mode lands at 0.3-0.6 because LRCP packet
    /// truncation is coarse — large highest-resolution packets either
    /// fit whole or get dropped. v5.35's multi-layer truncation
    /// targets 0.85+ on the same workloads. Track this metric to
    /// monitor the recovery.
    public let budgetFillRatio: Double?

    public init(
        iterations: Int,
        initialQstep: Double,
        convergedQstep: Double,
        achievedBpp: Double,
        targetBpp: Double,
        cacheHit: Bool,
        convergedWithinTolerance: Bool,
        budgetFillRatio: Double? = nil
    ) {
        self.iterations = iterations
        self.initialQstep = initialQstep
        self.convergedQstep = convergedQstep
        self.achievedBpp = achievedBpp
        self.targetBpp = targetBpp
        self.cacheHit = cacheHit
        self.convergedWithinTolerance = convergedWithinTolerance
        self.budgetFillRatio = budgetFillRatio
    }
}
