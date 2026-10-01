//
// J2KBitPlaneCoder.swift
// J2KSwift
//
/// # Bit-Plane Coder
///
/// Implementation of the EBCOT bit-plane coding algorithm for JPEG 2000.
///
/// The EBCOT (Embedded Block Coding with Optimised Truncation) algorithm encodes
/// wavelet coefficients using three coding passes per bit-plane:
/// 1. Significance Propagation Pass (SPP)
/// 2. Magnitude Refinement Pass (MRP)
/// 3. Cleanup Pass (CP)
///
/// ## Topics
///
/// ### Encoding
/// - ``BitPlaneCoder``
///
/// ### Decoding
/// - ``BitPlaneDecoder``

import Foundation

// MARK: - Debug Tracing

/// EBCOT tracing is present only when the `EBCOT_DEBUG_TRACE` compilation
/// condition is explicitly enabled. Conditional compilation is intentional:
/// a runtime-false flag still executes in `-Onone` builds and turns real-image
/// diagnostic tests into hours of tracing checks.
/// Temporary debug tracing for RLC investigation
final class EBCOTDebugTrace: @unchecked Sendable {
    static let shared = EBCOTDebugTrace()
    var enabled = false
    var encodeOps: [(String, Int, Int)] = []
    var decodeOps: [(String, Int, Int)] = []
    var encodeMQStates: [(UInt32, UInt32)] = []
    var decodeMQStates: [(UInt32, UInt32)] = []

    // Per-pass MQ state snapshots
    var encoderPassStates: [(pass: Int, a: UInt32, c: UInt32, opCount: Int)] = []
    var decoderPassStates: [(pass: Int, a: UInt32, c: UInt32, opCount: Int)] = []

    // States snapshots keyed by "pass_N"
    var encoderStatesSnapshots: [String: [UInt8]] = [:]  // key -> significant flags
    var decoderStatesSnapshots: [String: [UInt8]] = [:]

    // Per-symbol MQ trace: (opCount, ctxState, symbol, A, outputOrPos, C)
    var encoderSymbols: [(Int, Int, Bool, UInt32, UInt32, UInt32)] = []
    var decoderSymbols: [(Int, Int, Bool, UInt32, UInt32, UInt32)] = []

    // Current context label being encoded/decoded
    var currentContextLabel: Int = -1

    func reset() {
        encodeOps = []
        decodeOps = []
        encodeMQStates = []
        decodeMQStates = []
        encoderPassStates = []
        decoderPassStates = []
        encoderStatesSnapshots = [:]
        decoderStatesSnapshots = [:]
        encoderSymbols = []
        decoderSymbols = []
        encoderContextStates = [:]
        decoderContextStates = [:]
    }

    func logEncode(_ op: String, x: Int, y: Int, a: UInt32 = 0, c: UInt32 = 0) {
        guard enabled else { return }
        encodeOps.append((op, x, y))
        encodeMQStates.append((a, c))
    }

    func logDecode(_ op: String, x: Int, y: Int, a: UInt32 = 0, c: UInt32 = 0) {
        guard enabled else { return }
        decodeOps.append((op, x, y))
        decodeMQStates.append((a, c))
    }

    func logEncoderPassEnd(pass: Int, a: UInt32, c: UInt32, opCount: Int) {
        guard enabled else { return }
        encoderPassStates.append((pass, a, c, opCount))
    }

    func logDecoderPassEnd(pass: Int, a: UInt32, c: UInt32, opCount: Int) {
        guard enabled else { return }
        decoderPassStates.append((pass, a, c, opCount))
    }

    // Context state snapshots at pass boundaries
    var encoderContextStates: [Int: [(Int, Bool)]] = [:]  // pass -> [(stateIndex, mps)]
    var decoderContextStates: [Int: [(Int, Bool)]] = [:]

    func saveEncoderContexts(_ pass: Int, _ contexts: ContextStateArray) {
        guard enabled else { return }
        encoderContextStates[pass] = contexts.toArray().map { (Int($0.stateIndex), $0.mps) }
    }

    func saveDecoderContexts(_ pass: Int, _ contexts: ContextStateArray) {
        guard enabled else { return }
        decoderContextStates[pass] = contexts.toArray().map { (Int($0.stateIndex), $0.mps) }
    }

    func saveEncoderStates(_ key: String, _ states: [CoefficientState]) {
        guard enabled else { return }
        encoderStatesSnapshots[key] = states.map { s in
            var v: UInt8 = 0
            if s.contains(.significant) { v |= 1 }
            if s.contains(.signBit) { v |= 2 }
            return v
        }
    }

    func saveDecoderStates(_ key: String, _ states: [CoefficientState]) {
        guard enabled else { return }
        decoderStatesSnapshots[key] = states.map { s in
            var v: UInt8 = 0
            if s.contains(.significant) { v |= 1 }
            if s.contains(.signBit) { v |= 2 }
            return v
        }
    }
}

// MARK: - Coding Pass Type

/// The type of coding pass in EBCOT bit-plane coding.
enum CodingPassType: Sendable {
    /// Significance propagation pass.
    case significancePropagation

    /// Magnitude refinement pass.
    case magnitudeRefinement

    /// Cleanup pass.
    case cleanup
}

// MARK: - Coding Options

/// Configuration options for bit-plane coding.
///
/// These options control the encoding behavior, including bypass mode and termination.
struct CodingOptions: Sendable {
    /// Enable selective arithmetic coding bypass mode.
    ///
    /// When enabled, magnitude refinement passes after a certain bit-plane
    /// use raw (bypass) mode instead of context-adaptive arithmetic coding.
    let bypassEnabled: Bool

    /// The bit-plane index at which to start using bypass mode.
    ///
    /// Only applies when `bypassEnabled` is true. Bypass mode is used for
    /// magnitude refinement passes in bit-planes less than this threshold.
    /// A value of 0 disables bypass mode effectively.
    let bypassThreshold: Int

    /// The termination mode for arithmetic coding.
    ///
    /// Controls how the MQ-coder terminates its encoded output. Different
    /// modes offer trade-offs between compression efficiency and error resilience.
    let terminationMode: TerminationMode

    /// Use ISO/IEC 15444-1 compliant RLC position encoding.
    ///
    /// When true, uses 2-bit UNIFORM context to encode the position of the first
    /// significant coefficient in an RLC-eligible stripe column. When false, uses
    /// the legacy fallthrough approach where each coefficient is individually tested.
    let useISOPositionEncoding: Bool

    /// Whether to accumulate per-pass distortion reduction for PCRD.
    ///
    /// Set to false for lossless encoding where all passes are always retained
    /// and distortion is always zero. Skipping this eliminates Int64 multiplications
    /// and Double accumulation from every processed coefficient in all three passes.
    let trackDistortion: Bool

    /// Reset context probabilities at every coding pass boundary (code-block style bit 1, decode side).
    let resetContextOnEachPass: Bool

    /// Terminate the codeword segment at every coding pass (bit 2, RESTART, decode side). Separate from
    /// `terminationMode`: RESET, RESTART and PTERM are independent bits of Table A.19.
    let terminateOnEachPass: Bool

    /// Form contexts without the stripe below (bit 3, decode side).
    let verticallyCausalContext: Bool

    /// Expect the four-symbol `0xA` sentinel after each cleanup pass (bit 5, decode side).
    let segmentationSymbols: Bool

    /// Compare the bytes each EBCOT block consumes with the bytes its packet header declared, and throw
    /// `J2KError.corruptedEntropyData` past the thresholds (#2899). Off for layer-truncated decodes, which leave
    /// declared bytes unread by design.
    let checksEntropyIntegrity: Bool

    /// Whether to reset the encoder after each coding pass (predictable termination).
    ///
    /// When enabled, the encoder state is reset after each coding pass,
    /// allowing independent decoding of each pass. This is automatically
    /// enabled when `terminationMode` is `.predictable`.
    var resetOnEachPass: Bool {
        terminationMode == .predictable
    }

    /// Creates new coding options.
    ///
    /// - Parameters:
    ///   - bypassEnabled: Enable bypass mode (default: false).
    ///   - bypassThreshold: Bit-plane threshold for bypass (default: 0).
    ///   - terminationMode: The termination mode (default: `.default`).
    ///   - useISOPositionEncoding: Use ISO RLC position encoding (default: false).
    ///   - trackDistortion: Accumulate per-pass distortion for PCRD (default: true).
    init(
        bypassEnabled: Bool = false,
        bypassThreshold: Int = 0,
        terminationMode: TerminationMode = .default,
        useISOPositionEncoding: Bool = true,
        trackDistortion: Bool = true,
        resetContextOnEachPass: Bool = false,
        terminateOnEachPass: Bool = false,
        verticallyCausalContext: Bool = false,
        segmentationSymbols: Bool = false,
        checksEntropyIntegrity: Bool = false
    ) {
        self.checksEntropyIntegrity = checksEntropyIntegrity
        self.resetContextOnEachPass = resetContextOnEachPass
        self.terminateOnEachPass = terminateOnEachPass
        self.verticallyCausalContext = verticallyCausalContext
        self.segmentationSymbols = segmentationSymbols
        self.bypassEnabled = bypassEnabled
        self.bypassThreshold = max(0, bypassThreshold)
        self.terminationMode = terminationMode
        self.useISOPositionEncoding = useISOPositionEncoding
        self.trackDistortion = trackDistortion
    }

    /// Default coding options (no bypass, default termination).
    static let `default` = CodingOptions()

    /// Typical bypass configuration for improved speed.
    ///
    /// Enables bypass mode for magnitude refinement passes in the lower 4 bit-planes.
    static let fastEncoding = CodingOptions(bypassEnabled: true, bypassThreshold: 4)

    /// Predictable termination for error resilience.
    ///
    /// Each coding pass can be independently decoded, enabling error resilience
    /// and parallel decoding at the cost of compression efficiency.
    static let errorResilient = CodingOptions(terminationMode: .predictable)

    /// Near-optimal termination for better compression.
    ///
    /// Uses a tighter termination sequence to minimise wasted bits.
    static let optimalCompression = CodingOptions(terminationMode: .nearOptimal)
}

// MARK: - Bit-Plane Coder

// MARK: - EBCOT Scratch Buffers

/// Pre-allocated reusable buffers for EBCOT bit-plane coding.
///
/// Eliminates per-block heap allocations for the state, magnitude, sign,
/// refinement, and reconstruction arrays. Created once per parallel chunk
/// and reused across all code blocks in that chunk.
///
/// Not `Sendable` — must be used only within a single task/thread.
final class EBCOTScratchBuffers {
    private let maxSize: Int
    var magnitudes: [UInt32]
    var signs: [Bool]
    var states: [CoefficientState]
    var recon: [UInt32]
    private var mqEncoder: MQEncoder

    init(maxSize: Int = 4096) {
        self.maxSize = maxSize
        magnitudes = [UInt32](repeating: 0, count: maxSize)
        signs = [Bool](repeating: false, count: maxSize)
        states = [CoefficientState](repeating: [], count: maxSize)
        recon = [UInt32](repeating: 0, count: maxSize)
        mqEncoder = MQEncoder(estimatedSize: max(256, maxSize))
    }

    @inline(__always)
    func makeMQEncoder() -> MQEncoder {
        mqEncoder.reset()
        return mqEncoder
    }

    /// Prepares the state/refine/recon scratch buffers for a new code block.
    ///
    /// Does NOT zero magnitudes/signs — those are fully overwritten by
    /// `separateMagnitudesAndSigns()` which must be called separately.
    @inline(__always)
    func prepareStateBuffers(count: Int) {
        let _: Void = states.withUnsafeMutableBufferPointer { buf in
            _ = memset(buf.baseAddress!, 0, count &* MemoryLayout<CoefficientState>.size)
        }
        let _: Void = recon.withUnsafeMutableBufferPointer { buf in
            _ = memset(buf.baseAddress!, 0, count &* MemoryLayout<UInt32>.size)
        }
    }

    /// Fills magnitudes and signs from Int32 coefficients.
    @discardableResult
    @inline(__always)
    func separateMagnitudesAndSigns(_ coefficients: [Int32], count: Int) -> UInt32 {
        var maxMagnitude: UInt32 = 0
        let simdCount = count / 4
        let remainderStart = simdCount * 4

        coefficients.withUnsafeBufferPointer { coeffPtr in
            magnitudes.withUnsafeMutableBufferPointer { magPtr in
                signs.withUnsafeMutableBufferPointer { signPtr in
                    guard
                        let coeffBase = coeffPtr.baseAddress,
                        let magBase = magPtr.baseAddress,
                        let signBase = signPtr.baseAddress
                    else { return }

                    var maxVec = SIMD4<UInt32>.zero

                    for i in 0..<simdCount {
                        let offset = i &* 4
                        let values = SIMD4<Int32>(
                            coeffBase[offset],
                            coeffBase[offset &+ 1],
                            coeffBase[offset &+ 2],
                            coeffBase[offset &+ 3]
                        )
                        let negative = values .< SIMD4<Int32>.zero
                        let absValues = values.replacing(with: SIMD4<Int32>.zero &- values, where: negative)
                        // Reinterpret as UInt32 in-register — avoids 4 extract+reinsert for max.
                        let absU32 = unsafeBitCast(absValues, to: SIMD4<UInt32>.self)

                        magBase[offset]       = absU32[0]
                        magBase[offset &+ 1]  = absU32[1]
                        magBase[offset &+ 2]  = absU32[2]
                        magBase[offset &+ 3]  = absU32[3]

                        signBase[offset]      = negative[0]
                        signBase[offset &+ 1] = negative[1]
                        signBase[offset &+ 2] = negative[2]
                        signBase[offset &+ 3] = negative[3]

                        maxVec = pointwiseMax(maxVec, absU32)
                    }
                    // Reduce SIMD max → scalar
                    maxMagnitude = max(max(maxVec[0], maxVec[1]), max(maxVec[2], maxVec[3]))

                    for i in remainderStart..<count {
                        let coeff = coeffBase[i]
                        let magnitude: UInt32
                        if coeff < 0 {
                            magnitude = UInt32(-coeff)
                            signBase[i] = true
                        } else {
                            magnitude = UInt32(coeff)
                            signBase[i] = false
                        }
                        magBase[i] = magnitude
                        if magnitude > maxMagnitude { maxMagnitude = magnitude }
                    }
                }
            }
        }
        return maxMagnitude
    }

    /// Fills magnitudes/signs while also collecting PCRD metrics for lossy coding.
    @inline(__always)
    func separateAndAnalyze(
        _ coefficients: [Int32],
        count: Int,
        totalBitPlanes: Int,
        collectRateControlMetrics: Bool
    ) -> (maxMagnitude: UInt32, squaredSum: Double, bitPlanePopulation: [Int]) {
        var maxMagnitude: UInt32 = 0
        var squaredSum: Double = 0
        var bitPlanePopulation = collectRateControlMetrics
            ? [Int](repeating: 0, count: totalBitPlanes)
            : []
        let simdCount = count / 4
        let remainderStart = simdCount * 4

        coefficients.withUnsafeBufferPointer { coeffPtr in
            magnitudes.withUnsafeMutableBufferPointer { magPtr in
                signs.withUnsafeMutableBufferPointer { signPtr in
                    guard
                        let coeffBase = coeffPtr.baseAddress,
                        let magBase = magPtr.baseAddress,
                        let signBase = signPtr.baseAddress
                    else { return }

                    if collectRateControlMetrics {
                        var maxVec = SIMD4<UInt32>.zero
                        for i in 0..<simdCount {
                            let offset = i &* 4
                            let values = SIMD4<Int32>(
                                coeffBase[offset],
                                coeffBase[offset &+ 1],
                                coeffBase[offset &+ 2],
                                coeffBase[offset &+ 3]
                            )
                            let negative = values .< SIMD4<Int32>.zero
                            let absValues = values.replacing(with: SIMD4<Int32>.zero &- values, where: negative)
                            let absU32 = unsafeBitCast(absValues, to: SIMD4<UInt32>.self)

                            magBase[offset]       = absU32[0]
                            magBase[offset &+ 1]  = absU32[1]
                            magBase[offset &+ 2]  = absU32[2]
                            magBase[offset &+ 3]  = absU32[3]

                            signBase[offset]      = negative[0]
                            signBase[offset &+ 1] = negative[1]
                            signBase[offset &+ 2] = negative[2]
                            signBase[offset &+ 3] = negative[3]

                            maxVec = pointwiseMax(maxVec, absU32)

                            let m0 = absU32[0]; let m1 = absU32[1]
                            let m2 = absU32[2]; let m3 = absU32[3]
                            squaredSum += Double(m0) * Double(m0)
                            squaredSum += Double(m1) * Double(m1)
                            squaredSum += Double(m2) * Double(m2)
                            squaredSum += Double(m3) * Double(m3)

                            if m0 > 0 {
                                let msb = 31 &- m0.leadingZeroBitCount
                                if msb < totalBitPlanes { bitPlanePopulation[msb] &+= 1 }
                            }
                            if m1 > 0 {
                                let msb = 31 &- m1.leadingZeroBitCount
                                if msb < totalBitPlanes { bitPlanePopulation[msb] &+= 1 }
                            }
                            if m2 > 0 {
                                let msb = 31 &- m2.leadingZeroBitCount
                                if msb < totalBitPlanes { bitPlanePopulation[msb] &+= 1 }
                            }
                            if m3 > 0 {
                                let msb = 31 &- m3.leadingZeroBitCount
                                if msb < totalBitPlanes { bitPlanePopulation[msb] &+= 1 }
                            }
                        }
                        maxMagnitude = max(max(maxVec[0], maxVec[1]), max(maxVec[2], maxVec[3]))

                        for i in remainderStart..<count {
                            let coeff = coeffBase[i]
                            let magnitude: UInt32
                            if coeff < 0 {
                                magnitude = UInt32(-coeff)
                                signBase[i] = true
                            } else {
                                magnitude = UInt32(coeff)
                                signBase[i] = false
                            }
                            magBase[i] = magnitude
                            if magnitude > maxMagnitude { maxMagnitude = magnitude }
                            squaredSum += Double(magnitude) * Double(magnitude)
                            if magnitude > 0 {
                                let msb = 31 &- magnitude.leadingZeroBitCount
                                if msb < totalBitPlanes { bitPlanePopulation[msb] &+= 1 }
                            }
                        }
                    } else {
                        var maxVec2 = SIMD4<UInt32>.zero
                        for i in 0..<simdCount {
                            let offset = i &* 4
                            let values = SIMD4<Int32>(
                                coeffBase[offset],
                                coeffBase[offset &+ 1],
                                coeffBase[offset &+ 2],
                                coeffBase[offset &+ 3]
                            )
                            let negative = values .< SIMD4<Int32>.zero
                            let absValues = values.replacing(with: SIMD4<Int32>.zero &- values, where: negative)
                            let absU32 = unsafeBitCast(absValues, to: SIMD4<UInt32>.self)

                            magBase[offset]       = absU32[0]
                            magBase[offset &+ 1]  = absU32[1]
                            magBase[offset &+ 2]  = absU32[2]
                            magBase[offset &+ 3]  = absU32[3]

                            signBase[offset]      = negative[0]
                            signBase[offset &+ 1] = negative[1]
                            signBase[offset &+ 2] = negative[2]
                            signBase[offset &+ 3] = negative[3]

                            maxVec2 = pointwiseMax(maxVec2, absU32)
                        }
                        maxMagnitude = max(max(maxVec2[0], maxVec2[1]), max(maxVec2[2], maxVec2[3]))

                        for i in remainderStart..<count {
                            let coeff = coeffBase[i]
                            let magnitude: UInt32
                            if coeff < 0 {
                                magnitude = UInt32(-coeff)
                                signBase[i] = true
                            } else {
                                magnitude = UInt32(coeff)
                                signBase[i] = false
                            }
                            magBase[i] = magnitude
                            if magnitude > maxMagnitude { maxMagnitude = magnitude }
                        }
                    }
                }
            }
        }

        return (maxMagnitude, squaredSum, bitPlanePopulation)
    }
}

/// Encodes wavelet coefficients using EBCOT bit-plane coding.
///
/// The bit-plane coder processes coefficients from most significant to least
/// significant bit-plane. Each bit-plane is coded in three passes that handle
/// different coefficient states efficiently.
///
/// ## Example
///
/// ```swift
/// var coder = BitPlaneCoder(width: 32, height: 32, subband: .ll)
/// let coefficients: [Int32] = ... // Wavelet coefficients
/// let encoded = try coder.encode(coefficients: coefficients, bitDepth: 12)
/// ```
struct BitPlaneCoder: Sendable {
    /// The width of the code-block.
    let width: Int

    /// The height of the code-block.
    let height: Int

    /// The subband type for context formation.
    let subband: J2KSubband

    /// The context modeler for this subband.
    private let contextModeler: ContextModeler

    /// The neighbor calculator.
    private let neighborCalculator: NeighborCalculator

    /// Coding options for this encoder.
    private let options: CodingOptions

    /// Creates a new bit-plane coder for the specified dimensions and subband.
    ///
    /// - Parameters:
    ///   - width: The width of the code-block in samples.
    ///   - height: The height of the code-block in samples.
    ///   - subband: The wavelet subband type.
    ///   - options: Coding options (default: `.default`).
    init(width: Int, height: Int, subband: J2KSubband, options: CodingOptions = .default) {
        self.width = width
        self.height = height
        self.subband = subband
        self.contextModeler = ContextModeler(subband: subband)
        self.neighborCalculator = NeighborCalculator(width: width, height: height)
        self.options = options
    }

    /// Encodes wavelet coefficients using EBCOT bit-plane coding.
    ///
    /// - Parameters:
    ///   - coefficients: The wavelet coefficients to encode.
    ///   - bitDepth: The bit depth of the coefficients.
    ///   - maxPasses: Maximum number of coding passes to generate (optional).
    ///   - scratch: Pre-allocated scratch buffers for reuse across blocks (optional).
    /// - Returns: A tuple containing the encoded data, the number of coding passes,
    ///   the number of zero bit-planes, per-pass segment lengths, cumulative per-pass byte counts,
    ///   and cumulative per-pass distortion decrements.
    /// - Throws: ``J2KError`` if encoding fails.
    func encode(
        coefficients: [Int32],
        bitDepth: Int,
        coefficientCount: Int? = nil,
        maxPasses: Int? = nil,
        scratch: EBCOTScratchBuffers? = nil
    ) throws -> (data: Data, passCount: Int, zeroBitPlanes: Int, passSegmentLengths: [Int], cumulativePassBytes: [Int], cumulativePassDistortion: [Double], perPassSnapshotData: [Data], mqCheckpoints: [MQCheckpointData], rawMQOutput: [UInt8]) {
        let result = try encodeDetailed(
            coefficients: coefficients,
            bitDepth: bitDepth,
            coefficientCount: coefficientCount,
            maxPasses: maxPasses,
            scratch: scratch,
            collectRateControlMetrics: false
        )
        return (
            result.data,
            result.passCount,
            result.zeroBitPlanes,
            result.passSegmentLengths,
            result.cumulativePassBytes,
            result.cumulativePassDistortion,
            result.perPassSnapshotData,
            result.mqCheckpoints,
            result.rawMQOutput
        )
    }

    /// Internal fast path that also returns precomputed PCRD metrics.
    func encodeDetailed(
        coefficients: [Int32],
        bitDepth: Int,
        coefficientCount: Int? = nil,
        maxPasses: Int? = nil,
        scratch: EBCOTScratchBuffers? = nil,
        collectRateControlMetrics: Bool = true,
        precomputedAnalysis: (maxMagnitude: UInt32, squaredSum: Double, bitPlanePopulation: [Int])? = nil
    ) throws -> (data: Data, passCount: Int, zeroBitPlanes: Int, passSegmentLengths: [Int], cumulativePassBytes: [Int], cumulativePassDistortion: [Double], coefficientSquaredSum: Double, bitPlanePopulation: [Int], perPassSnapshotData: [Data], mqCheckpoints: [MQCheckpointData], rawMQOutput: [UInt8]) {
        let count = coefficientCount ?? (width * height)
        guard count == width * height, coefficients.count >= count else {
            throw J2KError.invalidParameter("Coefficient count mismatch")
        }

        // Find the number of zero bit-planes (MSBs that are all zero) and,
        // when needed for PCRD, collect distortion metrics in the same pass.
        let magnitudes: [UInt32]
        let signs: [Bool]
        let maxMagnitude: UInt32
        let coefficientSquaredSum: Double
        let bitPlanePopulation: [Int]
        if let precomputedAnalysis, let scratch = scratch {
            maxMagnitude = precomputedAnalysis.maxMagnitude
            coefficientSquaredSum = precomputedAnalysis.squaredSum
            bitPlanePopulation = precomputedAnalysis.bitPlanePopulation
            magnitudes = scratch.magnitudes
            signs = scratch.signs
        } else if let scratch = scratch {
            let analysis = scratch.separateAndAnalyze(
                coefficients,
                count: count,
                totalBitPlanes: bitDepth,
                collectRateControlMetrics: collectRateControlMetrics
            )
            maxMagnitude = analysis.maxMagnitude
            coefficientSquaredSum = analysis.squaredSum
            bitPlanePopulation = analysis.bitPlanePopulation
            magnitudes = scratch.magnitudes
            signs = scratch.signs
        } else {
            let separated = separateMagnitudesAndAnalyze(
                coefficients,
                count: count,
                totalBitPlanes: bitDepth,
                collectRateControlMetrics: collectRateControlMetrics
            )
            magnitudes = separated.magnitudes
            signs = separated.signs
            maxMagnitude = separated.maxMagnitude
            coefficientSquaredSum = separated.squaredSum
            bitPlanePopulation = separated.bitPlanePopulation
        }
        let activeBitPlanes = maxMagnitude > 0 ? (UInt32.bitWidth - maxMagnitude.leadingZeroBitCount) : 0
        let zeroBitPlanes = max(0, bitDepth - activeBitPlanes)

        if ProcessInfo.processInfo.environment["J2K_DUMP_PASSES"] != nil {
            print("EBCOT: w=\(width) h=\(height) bitDepth=\(bitDepth) maxMag=\(maxMagnitude) active=\(activeBitPlanes) zbp=\(zeroBitPlanes) maxPassLimit=\(maxPasses ?? (3 * activeBitPlanes))")
        }

        let signArray = signs

        func encodeWithBuffers(
            states: inout [CoefficientState],
            recon: inout [UInt32]
        ) throws -> (data: Data, passCount: Int, zeroBitPlanes: Int, passSegmentLengths: [Int], cumulativePassBytes: [Int], cumulativePassDistortion: [Double], coefficientSquaredSum: Double, bitPlanePopulation: [Int], perPassSnapshotData: [Data], mqCheckpoints: [MQCheckpointData], rawMQOutput: [UInt8]) {
            // Initialise MQ encoder and contexts
            var encoder = scratch?.makeMQEncoder() ?? MQEncoder(estimatedSize: max(256, count))
            var contextStates = ContextStateArray()

            // When bypass mode is enabled, per-pass segments are required for bypass
            // bit-planes to separate MQ-coded and raw-coded data per JPEG 2000 standard.
            let usePerPassSegments = options.resetOnEachPass || options.bypassEnabled

            // Track cumulative byte count after each pass for rate control truncation.
            // In non-per-pass mode, we use the MQ encoder's approximate byte position.
            var cumulativePassBytes: [Int] = []

            // Lightweight MQ encoder checkpoints for correct truncation.
            var perPassCheckpoints: [MQEncoder.Checkpoint] = []

            // Per-pass actual distortion tracking for accurate PCRD.
            var cumulativePassDistortion: [Double] = []
            var cumulativeDistReduction: Double = 0.0

            // For per-pass termination, we collect pass data separately
            var passDataSegments: [Data] = []
            var runningSegmentTotal = 0

            var passCount = 0
            let maxPassLimit = maxPasses ?? (3 * activeBitPlanes)
            cumulativePassBytes.reserveCapacity(maxPassLimit)
            perPassCheckpoints.reserveCapacity(maxPassLimit)
            cumulativePassDistortion.reserveCapacity(maxPassLimit)
            if usePerPassSegments {
                passDataSegments.reserveCapacity(maxPassLimit)
            }

            for bitPlane in stride(from: activeBitPlanes - 1, through: 0, by: -1) {
                let bitMask: UInt32 = 1 << bitPlane
                let useBypass = options.bypassEnabled && bitPlane < options.bypassThreshold
                let isFirstBitPlane = (bitPlane == activeBitPlanes - 1)

                if !isFirstBitPlane && passCount < maxPassLimit {
                    #if EBCOT_DEBUG_TRACE
                    EBCOTDebugTrace.shared.logEncode("=== SIGPROP bitPlane=\(bitPlane) pass=\(passCount) ===", x: -1, y: -1)
                    #endif
                    let sppDelta = encodeSignificancePropagationPass(
                        magnitudes: magnitudes,
                        signs: signArray,
                        states: &states,
                        bitMask: bitMask,
                        encoder: &encoder,
                        contexts: &contextStates,
                        recon: &recon,
                        bitPlane: bitPlane
                    )
                    #if EBCOT_DEBUG_TRACE
                    if EBCOTDebugTrace.shared.enabled {
                        let sigCount = states.filter { $0.contains(.significant) }.count
                        var sigHash: UInt64 = 0
                        for (i, s) in states.enumerated() {
                            if s.contains(.significant) {
                                sigHash = sigHash &+ UInt64(i &* 2654435761)
                            }
                        }
                        EBCOTDebugTrace.shared.logEncode("POST_SIGPROP sig=\(sigCount) hash=\(sigHash)", x: -1, y: -1)
                        EBCOTDebugTrace.shared.saveEncoderStates("sigprop_bp\(bitPlane)", states)
                    }
                    if EBCOTDebugTrace.shared.enabled {
                        EBCOTDebugTrace.shared.logEncoderPassEnd(pass: passCount, a: encoder.debugA, c: encoder.debugC, opCount: encoder.operationCount)
                        EBCOTDebugTrace.shared.saveEncoderContexts(passCount, contextStates)
                    }
                    #endif
                    passCount += 1

                    if usePerPassSegments {
                        let passData = encoder.finish(mode: options.terminationMode)
                        passDataSegments.append(passData)
                        encoder.reset()
                        contextStates.reset()
                        runningSegmentTotal += passData.count
                        cumulativePassBytes.append(runningSegmentTotal)
                    } else {
                        let cp = encoder.checkpoint()
                        cumulativePassBytes.append(cp.outputCount + (cp.buffer >= 0 ? 1 : 0) + 2)
                        perPassCheckpoints.append(cp)
                    }
                    cumulativeDistReduction += sppDelta
                    cumulativePassDistortion.append(cumulativeDistReduction)
                }

                if !isFirstBitPlane && passCount < maxPassLimit {
                    #if EBCOT_DEBUG_TRACE
                    EBCOTDebugTrace.shared.logEncode("=== MAGREF bitPlane=\(bitPlane) pass=\(passCount) ===", x: -1, y: -1)
                    #endif
                    if useBypass {
                        var bypassEncoder = RawBypassEncoder()
                        let mrpDelta = encodeMagnitudeRefinementPassBypass(
                            magnitudes: magnitudes,
                            states: &states,
                            bitMask: bitMask,
                            bypassEncoder: &bypassEncoder,
                            recon: &recon,
                            bitPlane: bitPlane
                        )
                        passCount += 1
                        let passData = bypassEncoder.finish()
                        passDataSegments.append(passData)
                        runningSegmentTotal += passData.count
                        cumulativePassBytes.append(runningSegmentTotal)
                        cumulativeDistReduction += mrpDelta
                        cumulativePassDistortion.append(cumulativeDistReduction)
                    } else {
                        let mrpDelta = encodeMagnitudeRefinementPass(
                            magnitudes: magnitudes,
                            states: &states,
                            bitMask: bitMask,
                            encoder: &encoder,
                            contexts: &contextStates,
                            useBypass: false,
                            recon: &recon,
                            bitPlane: bitPlane
                        )
                        #if EBCOT_DEBUG_TRACE
                        if EBCOTDebugTrace.shared.enabled {
                            let sigCount = states.filter { $0.contains(.significant) }.count
                            EBCOTDebugTrace.shared.logEncode("POST_MAGREF sig=\(sigCount)", x: -1, y: -1)
                        }
                        if EBCOTDebugTrace.shared.enabled {
                            EBCOTDebugTrace.shared.logEncoderPassEnd(pass: passCount, a: encoder.debugA, c: encoder.debugC, opCount: encoder.operationCount)
                            EBCOTDebugTrace.shared.saveEncoderContexts(passCount, contextStates)
                        }
                        #endif
                        passCount += 1

                        if usePerPassSegments {
                            let passData = encoder.finish(mode: options.terminationMode)
                            passDataSegments.append(passData)
                            encoder.reset()
                            contextStates.reset()
                            runningSegmentTotal += passData.count
                            cumulativePassBytes.append(runningSegmentTotal)
                        } else {
                            let cp = encoder.checkpoint()
                            cumulativePassBytes.append(cp.outputCount + (cp.buffer >= 0 ? 1 : 0) + 2)
                            perPassCheckpoints.append(cp)
                        }
                        cumulativeDistReduction += mrpDelta
                        cumulativePassDistortion.append(cumulativeDistReduction)
                    }
                }

                if passCount < maxPassLimit {
                    #if EBCOT_DEBUG_TRACE
                    EBCOTDebugTrace.shared.logEncode("=== CLEANUP bitPlane=\(bitPlane) pass=\(passCount) ===", x: -1, y: -1)
                    #endif
                    let cupDelta = encodeCleanupPass(
                        magnitudes: magnitudes,
                        signs: signArray,
                        states: &states,
                        bitMask: bitMask,
                        encoder: &encoder,
                        contexts: &contextStates,
                        recon: &recon,
                        bitPlane: bitPlane
                    )
                    #if EBCOT_DEBUG_TRACE
                    if EBCOTDebugTrace.shared.enabled {
                        let sigCount = states.filter { $0.contains(.significant) }.count
                        let sbitCount = states.filter { $0.contains(.signBit) }.count
                        var sigHash: UInt64 = 0
                        for (i, s) in states.enumerated() {
                            if s.contains(.significant) {
                                sigHash = sigHash &+ UInt64(i &* 2654435761)
                            }
                        }
                        EBCOTDebugTrace.shared.logEncode("POST_CLEANUP sig=\(sigCount) sbit=\(sbitCount) hash=\(sigHash)", x: -1, y: -1)
                        EBCOTDebugTrace.shared.saveEncoderStates("cleanup_bp\(bitPlane)", states)
                    }
                    if EBCOTDebugTrace.shared.enabled {
                        EBCOTDebugTrace.shared.logEncoderPassEnd(pass: passCount, a: encoder.debugA, c: encoder.debugC, opCount: encoder.operationCount)
                        EBCOTDebugTrace.shared.saveEncoderContexts(passCount, contextStates)
                    }
                    #endif
                    passCount += 1

                    if usePerPassSegments {
                        let passData = encoder.finish(mode: options.terminationMode)
                        passDataSegments.append(passData)
                        encoder.reset()
                        contextStates.reset()
                        runningSegmentTotal += passData.count
                        cumulativePassBytes.append(runningSegmentTotal)
                    } else {
                        let cp = encoder.checkpoint()
                        cumulativePassBytes.append(cp.outputCount + (cp.buffer >= 0 ? 1 : 0) + 2)
                        perPassCheckpoints.append(cp)
                    }
                    cumulativeDistReduction += cupDelta
                    cumulativePassDistortion.append(cumulativeDistReduction)
                }

                let clearMask = ~CoefficientState.codedThisPass.rawValue
                states.withUnsafeMutableBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    let n = buf.count
                    // Broadcast byte mask to all 8 positions: 0xFD→0xFDFDFDFDFDFDFDFD
                    let mask64 = UInt64(clearMask) &* 0x0101010101010101
                    let wordCount = n / 8
                    base.withMemoryRebound(to: UInt64.self, capacity: wordCount) { wordPtr in
                        for i in 0..<wordCount { wordPtr[i] &= mask64 }
                    }
                    base.withMemoryRebound(to: UInt8.self, capacity: n) { rawPtr in
                        for i in (wordCount &* 8)..<n { rawPtr[i] &= clearMask }
                    }
                }
            }

            let encodedData: Data
            var segmentLengths: [Int] = []
            let rawOutput: [UInt8]
            if usePerPassSegments {
                var combinedData = Data()
                for segment in passDataSegments {
                    segmentLengths.append(segment.count)
                    combinedData.append(segment)
                }
                encodedData = combinedData
                rawOutput = []
            } else {
                rawOutput = encoder.currentOutput
                encodedData = encoder.finish(mode: options.terminationMode)
                if let last = cumulativePassBytes.indices.last {
                    cumulativePassBytes[last] = encodedData.count
                }
            }

            let checkpointData = perPassCheckpoints.map { cp in
                MQCheckpointData(outputCount: cp.outputCount, a: cp.a, c: cp.c, ct: cp.ct, buffer: cp.buffer)
            }

            if ProcessInfo.processInfo.environment["J2K_DUMP_PASSES"] != nil {
                print("EBCOT_RESULT: passCount=\(passCount) dataBytes=\(encodedData.count) zbp=\(zeroBitPlanes)")
            }

            return (
                encodedData,
                passCount,
                zeroBitPlanes,
                segmentLengths,
                cumulativePassBytes,
                cumulativePassDistortion,
                coefficientSquaredSum,
                bitPlanePopulation,
                [],
                checkpointData,
                rawOutput
            )
        }

        if let scratch = scratch {
            scratch.prepareStateBuffers(count: count)
            return try encodeWithBuffers(
                states: &scratch.states,
                recon: &scratch.recon
            )
        } else {
            var states = [CoefficientState](repeating: [], count: count)
            var recon = [UInt32](repeating: 0, count: count)
            return try encodeWithBuffers(
                states: &states,
                recon: &recon
            )
        }    }

    /// Separates coefficients into magnitudes and signs.
    private func separateMagnitudesAndSigns(_ coefficients: [Int32], count: Int? = nil) -> (magnitudes: [UInt32], signs: [Bool], maxMagnitude: UInt32) {
        let analyzed = separateMagnitudesAndAnalyze(
            coefficients,
            count: count,
            totalBitPlanes: 0,
            collectRateControlMetrics: false
        )
        return (analyzed.magnitudes, analyzed.signs, analyzed.maxMagnitude)
    }

    /// Separates coefficients into magnitudes and signs while optionally collecting
    /// squared-energy and bit-plane population metrics for rate control.
    private func separateMagnitudesAndAnalyze(
        _ coefficients: [Int32],
        count: Int? = nil,
        totalBitPlanes: Int,
        collectRateControlMetrics: Bool
    ) -> (magnitudes: [UInt32], signs: [Bool], maxMagnitude: UInt32, squaredSum: Double, bitPlanePopulation: [Int]) {
        let count = count ?? coefficients.count
        var magnitudes = [UInt32](repeating: 0, count: count)
        var signs = [Bool](repeating: false, count: count)
        var maxMagnitude: UInt32 = 0
        var squaredSum: Double = 0
        var bitPlanePopulation = collectRateControlMetrics
            ? [Int](repeating: 0, count: totalBitPlanes)
            : []

        // SIMD-optimised path: process 4 coefficients at a time using SIMD4
        let simdCount = count / 4
        let remainder = count % 4

        coefficients.withUnsafeBufferPointer { coeffPtr in
            magnitudes.withUnsafeMutableBufferPointer { magPtr in
                signs.withUnsafeMutableBufferPointer { signPtr in
                    let coeffBase = coeffPtr.baseAddress!
                    let magBase = magPtr.baseAddress!
                    let signBase = signPtr.baseAddress!

                    for i in 0..<simdCount {
                        let offset = i * 4
                        // Load 4 coefficients into SIMD vector
                        let v = SIMD4<Int32>(
                            coeffBase[offset],
                            coeffBase[offset + 1],
                            coeffBase[offset + 2],
                            coeffBase[offset + 3]
                        )

                        // Compute absolute values using SIMD
                        let negative = v .< SIMD4<Int32>.zero
                        let absV = v.replacing(with: SIMD4<Int32>.zero &- v, where: negative)

                        // Store magnitudes
                        let m0 = UInt32(bitPattern: absV[0])
                        let m1 = UInt32(bitPattern: absV[1])
                        let m2 = UInt32(bitPattern: absV[2])
                        let m3 = UInt32(bitPattern: absV[3])
                        magBase[offset] = m0
                        magBase[offset + 1] = m1
                        magBase[offset + 2] = m2
                        magBase[offset + 3] = m3
                        if m0 > maxMagnitude { maxMagnitude = m0 }
                        if m1 > maxMagnitude { maxMagnitude = m1 }
                        if m2 > maxMagnitude { maxMagnitude = m2 }
                        if m3 > maxMagnitude { maxMagnitude = m3 }
                        if collectRateControlMetrics {
                            squaredSum += Double(m0) * Double(m0)
                            squaredSum += Double(m1) * Double(m1)
                            squaredSum += Double(m2) * Double(m2)
                            squaredSum += Double(m3) * Double(m3)
                            if m0 > 0 {
                                let msb = 31 &- m0.leadingZeroBitCount
                                if msb < totalBitPlanes { bitPlanePopulation[msb] &+= 1 }
                            }
                            if m1 > 0 {
                                let msb = 31 &- m1.leadingZeroBitCount
                                if msb < totalBitPlanes { bitPlanePopulation[msb] &+= 1 }
                            }
                            if m2 > 0 {
                                let msb = 31 &- m2.leadingZeroBitCount
                                if msb < totalBitPlanes { bitPlanePopulation[msb] &+= 1 }
                            }
                            if m3 > 0 {
                                let msb = 31 &- m3.leadingZeroBitCount
                                if msb < totalBitPlanes { bitPlanePopulation[msb] &+= 1 }
                            }
                        }

                        // Store signs
                        signBase[offset] = negative[0]
                        signBase[offset + 1] = negative[1]
                        signBase[offset + 2] = negative[2]
                        signBase[offset + 3] = negative[3]
                    }

                    // Handle remainder
                    let remStart = simdCount * 4
                    for i in 0..<remainder {
                        let idx = remStart + i
                        let coeff = coeffBase[idx]
                        let magnitude: UInt32
                        if coeff < 0 {
                            magnitude = UInt32(-coeff)
                            signBase[idx] = true
                        } else {
                            magnitude = UInt32(coeff)
                            signBase[idx] = false
                        }
                        magBase[idx] = magnitude
                        if magnitude > maxMagnitude { maxMagnitude = magnitude }
                        if collectRateControlMetrics {
                            squaredSum += Double(magnitude) * Double(magnitude)
                            if magnitude > 0 {
                                let msb = 31 &- magnitude.leadingZeroBitCount
                                if msb < totalBitPlanes {
                                    bitPlanePopulation[msb] &+= 1
                                }
                            }
                        }
                    }
                }
            }
        }

        return (magnitudes, signs, maxMagnitude, squaredSum, bitPlanePopulation)
    }

    // MARK: - Significance Propagation Pass

    /// Encodes the significance propagation pass.
    ///
    /// This pass codes coefficients that are not yet significant but have at least
    /// one significant neighbor. It exploits the spatial correlation between
    /// neighboring coefficients.
    private func encodeSignificancePropagationPass(
        magnitudes: [UInt32],
        signs: [Bool],
        states: inout [CoefficientState],
        bitMask: UInt32,
        encoder: inout MQEncoder,
        contexts: inout ContextStateArray,
        recon: inout [UInt32],
        bitPlane: Int
    ) -> Double {
        let stripeHeight = 4
        let w = width
        let h = height
        let halfBit: UInt32 = bitPlane > 0 ? UInt32(1 << (bitPlane - 1)) : 0
        let reconVal = UInt32(1 << bitPlane) | halfBit
        var passDistortion: Double = 0

        magnitudes.withUnsafeBufferPointer { magBuf in
            signs.withUnsafeBufferPointer { signBuf in
                states.withUnsafeMutableBufferPointer { stateBuf in
                    recon.withUnsafeMutableBufferPointer { reconBuf in
                    let magPtr = magBuf.baseAddress!
                    let signPtr = signBuf.baseAddress!
                    let statePtr = stateBuf.baseAddress!
                    let reconPtr = reconBuf.baseAddress!
                    let sigMask = CoefficientState.significant.rawValue
                    let codedMask = CoefficientState.codedThisPass.rawValue
                    let signStateMask = CoefficientState.signBit.rawValue

                    // Direct pointer access to context array — eliminates 19-case switch per encode call.
                    contexts.withUnsafeMutableContextArray { ctxPtr in
                    for stripeY in stride(from: 0, to: h, by: stripeHeight) {
                        let stripeEnd = min(stripeY + stripeHeight, h)

                        for x in 0..<w {
                            for y in stripeY..<stripeEnd {
                                let idx = y &* w &+ x

                                // sppSigContextOrSkip folds in the sig/coded check via
                                // mid byte 1 of its 3-word load — no separate state read.
                                let rawCtx = contextModeler.sppSigContextOrSkip(
                                    x: x, y: y, width: w, height: h, states: statePtr)
                                guard rawCtx != 0xFF else { continue }

                                let isSignificant = (magPtr[idx] & bitMask) != 0

                                encoder.encode(symbol: isSignificant, context: &ctxPtr[Int(rawCtx)])

                                if isSignificant {
                                    let (hSign, vSign) = neighborCalculator.computeCardinalSignsUnsafe(
                                        x: x, y: y,
                                        states: statePtr
                                    )
                                    let signEntry = ContextModeler.signContextLUT[(hSign + 2) * 5 + (vSign + 2)]
                                    let signBit = signPtr[idx]
                                    let codedSign = signBit != ((signEntry & 1) != 0)
                                    encoder.encode(symbol: codedSign, context: &ctxPtr[Int(signEntry >> 1)])

                                    // rawState is proven 0 here (sig/coded checked above)
                                    var newState = sigMask | codedMask
                                    if signBit { newState |= signStateMask }
                                    statePtr[idx] = CoefficientState(rawValue: newState)

                                    if options.trackDistortion {
                                        reconPtr[idx] = reconVal
                                        let m = Int64(magPtr[idx])
                                        let e = m &- Int64(reconVal)
                                        passDistortion += Double(m &* m &- e &* e)
                                    }
                                } else {
                                    statePtr[idx] = CoefficientState(rawValue: codedMask)
                                }
                            }
                        }
                    }
                    } // ctxPtr
                    } // reconBuf
                }
            }
        }
        return passDistortion
    }

    // MARK: - Magnitude Refinement Pass

    /// Encodes the magnitude refinement pass.
    ///
    /// This pass refines the magnitude of coefficients that are already significant
    /// by coding additional bits from subsequent bit-planes. Can use bypass mode
    /// for improved encoding speed.
    ///
    private func encodeMagnitudeRefinementPass(
        magnitudes: [UInt32],
        states: inout [CoefficientState],
        bitMask: UInt32,
        encoder: inout MQEncoder,
        contexts: inout ContextStateArray,
        useBypass: Bool = false,
        recon: inout [UInt32],
        bitPlane: Int
    ) -> Double {
        let stripeHeight = 4
        let w = width
        let h = height
        let halfBit: UInt32 = bitPlane > 0 ? UInt32(1 << (bitPlane - 1)) : 0
        let clearMask = ~UInt32((1 << (bitPlane + 1)) - 1)
        let bitVal = UInt32(1 << bitPlane)
        var passDistortion: Double = 0

        magnitudes.withUnsafeBufferPointer { magBuf in
            states.withUnsafeMutableBufferPointer { stateBuf in
                recon.withUnsafeMutableBufferPointer { reconBuf in
                    let magPtr = magBuf.baseAddress!
                    let statePtr = stateBuf.baseAddress!
                    let reconPtr = reconBuf.baseAddress!

                    contexts.withUnsafeMutableContextArray { ctxPtr in
                    for stripeY in stride(from: 0, to: h, by: stripeHeight) {
                        let stripeEnd = min(stripeY + stripeHeight, h)

                        for x in 0..<w {
                            for y in stripeY..<stripeEnd {
                                let idx = y &* w &+ x

                                let stRaw = statePtr[idx].rawValue
                                guard (stRaw & 0x03) == 0x01 else { continue }  // significant, not coded

                                let bitValue = (magPtr[idx] & bitMask) != 0

                                if useBypass {
                                    encoder.encodeBypass(symbol: bitValue)
                                } else {
                                    // bit 3 = refinementVisited: 0 = first refinement, 1 = subsequent
                                    let isFirstRefinement = (stRaw & 0x08) == 0
                                    let hasSignificantNeighbors = isFirstRefinement &&
                                        neighborCalculator.hasAnySignificantNeighborUnsafe(
                                            x: x, y: y, states: statePtr)
                                    // magRef1=14, magRef2noSig=15, magRef2sig=16
                                    let magCtxIdx = isFirstRefinement ? (hasSignificantNeighbors ? 15 : 14) : 16
                                    encoder.encode(symbol: bitValue, context: &ctxPtr[magCtxIdx])
                                }

                                // Set codedThisPass (0x02) and refinementVisited (0x08) in one write.
                                statePtr[idx] = CoefficientState(rawValue: stRaw | 0x0A)

                                if options.trackDistortion {
                                    let oldErr = Int64(magPtr[idx]) &- Int64(reconPtr[idx])
                                    let high = reconPtr[idx] & clearMask
                                    reconPtr[idx] = high | (magPtr[idx] & bitVal) | halfBit
                                    let newErr = Int64(magPtr[idx]) &- Int64(reconPtr[idx])
                                    passDistortion += Double(oldErr &* oldErr &- newErr &* newErr)
                                }
                            }
                        }
                    }
                    } // ctxPtr
                }
            }
        }
        return passDistortion
    }

    /// Encodes the magnitude refinement pass using raw bypass coding.
    ///
    /// This method uses a separate `RawBypassEncoder` to write raw bits directly
    /// without context-adaptive arithmetic coding, providing faster encoding.
    ///
    private func encodeMagnitudeRefinementPassBypass(
        magnitudes: [UInt32],
        states: inout [CoefficientState],
        bitMask: UInt32,
        bypassEncoder: inout RawBypassEncoder,
        recon: inout [UInt32],
        bitPlane: Int
    ) -> Double {
        // JPEG 2000 requires stripe-based column-major scan order
        let stripeHeight = 4
        let halfBit: UInt32 = bitPlane > 0 ? UInt32(1 << (bitPlane - 1)) : 0
        let clearMask = ~UInt32((1 << (bitPlane + 1)) - 1)
        let bitVal = UInt32(1 << bitPlane)
        var passDistortion: Double = 0

        for stripeY in stride(from: 0, to: height, by: stripeHeight) {
            let stripeEnd = min(stripeY + stripeHeight, height)

            for x in 0..<width {
                for y in stripeY..<stripeEnd {
                    let idx = y * width + x

                    let stRawBp = states[idx].rawValue
                    guard (stRawBp & 0x03) == 0x01 else { continue }  // significant, not coded

                    let bitValue = (magnitudes[idx] & bitMask) != 0
                    bypassEncoder.encode(symbol: bitValue)

                    if options.trackDistortion {
                        let oldErr = Int64(magnitudes[idx]) &- Int64(recon[idx])
                        let high = recon[idx] & clearMask
                        recon[idx] = high | (magnitudes[idx] & bitVal) | halfBit
                        let newErr = Int64(magnitudes[idx]) &- Int64(recon[idx])
                        passDistortion += Double(oldErr &* oldErr &- newErr &* newErr)
                    }

                    states[idx] = CoefficientState(rawValue: stRawBp | 0x0A)  // codedThisPass | refinementVisited
                }
            }
        }
        return passDistortion
    }

    // MARK: - Cleanup Pass

    /// Encodes the cleanup pass.
    ///
    /// This pass codes all remaining coefficients that were not coded in the
    /// significance propagation or magnitude refinement passes. It uses run-length
    /// coding for efficiency when processing stripes of 4 rows.
    private func encodeCleanupPass(
        magnitudes: [UInt32],
        signs: [Bool],
        states: inout [CoefficientState],
        bitMask: UInt32,
        encoder: inout MQEncoder,
        contexts: inout ContextStateArray,
        recon: inout [UInt32],
        bitPlane: Int
    ) -> Double {
        let stripeHeight = 4
        let w = width
        let h = height
        let halfBit: UInt32 = bitPlane > 0 ? UInt32(1 << (bitPlane - 1)) : 0
        let reconVal = UInt32(1 << bitPlane) | halfBit
        var passDistortion: Double = 0

        magnitudes.withUnsafeBufferPointer { magBuf in
            signs.withUnsafeBufferPointer { signBuf in
                states.withUnsafeMutableBufferPointer { stateBuf in
                    recon.withUnsafeMutableBufferPointer { reconBuf in
                    let magPtr = magBuf.baseAddress!
                    let signPtr = signBuf.baseAddress!
                    let statePtr = stateBuf.baseAddress!
                    let reconPtr = reconBuf.baseAddress!

                    // Direct pointer to context array — eliminates 19-case switch per encode call.
                    contexts.withUnsafeMutableContextArray { ctxPtr in
        for stripeY in stride(from: 0, to: h, by: stripeHeight) {
            let stripeEnd = min(stripeY + stripeHeight, h)

            for x in 0..<w {
                let eligible = isEligibleForRunLengthCodingUnsafe(
                    x: x,
                    stripeStart: stripeY,
                    stripeEnd: stripeEnd,
                    states: statePtr
                )

                #if EBCOT_DEBUG_TRACE
                EBCOTDebugTrace.shared.logEncode("elig=\(eligible)", x: x, y: stripeY)
                #endif

                if eligible {
                    let hasSignificant = anyBecomeSignificantUnsafe(
                        x: x,
                        stripeStart: stripeY,
                        stripeEnd: stripeEnd,
                        magnitudes: magPtr,
                        bitMask: bitMask
                    )

                    encoder.encode(symbol: hasSignificant, context: &ctxPtr[17])  // .runLength

                    if !hasSignificant {
                        // All 4 states guaranteed rawValue==0 (eligibility check), direct assign.
                        for y in stripeY..<stripeEnd {
                            let idx = y &* w &+ x
                            statePtr[idx] = CoefficientState(rawValue: 0x02)
                        }
                        continue
                    }

                    if options.useISOPositionEncoding {
                        var firstSigPos = 0
                        for i in 0..<(stripeEnd - stripeY) {
                            let idx = (stripeY &+ i) &* w &+ x
                            if (magPtr[idx] & bitMask) != 0 {
                                firstSigPos = i
                                break
                            }
                        }

                        encoder.encode(symbol: (firstSigPos & 0x02) != 0, context: &ctxPtr[18])  // .uniform
                        encoder.encode(symbol: (firstSigPos & 0x01) != 0, context: &ctxPtr[18])  // .uniform

                        // States before firstSigPos: rawValue==0, direct assign.
                        for i in 0..<firstSigPos {
                            let idx = (stripeY &+ i) &* w &+ x
                            statePtr[idx] = CoefficientState(rawValue: 0x02)
                        }

                        let firstIdx = (stripeY &+ firstSigPos) &* w &+ x
                        let (firstHSign, firstVSign) = neighborCalculator.computeCardinalSignsUnsafe(
                            x: x, y: stripeY + firstSigPos,
                            states: statePtr
                        )
                        let firstSignEntry = ContextModeler.signContextLUT[(firstHSign + 2) * 5 + (firstVSign + 2)]
                        let firstSignBit = signPtr[firstIdx]
                        let firstCodedSign = firstSignBit != ((firstSignEntry & 1) != 0)
                        encoder.encode(symbol: firstCodedSign, context: &ctxPtr[Int(firstSignEntry >> 1)])

                        // RLC eligibility guarantees state==0 for firstIdx: single write
                        var firstNewRaw: UInt8 = 0x03  // significant | codedThisPass
                        if firstSignBit { firstNewRaw |= 0x04 }  // signBit
                        statePtr[firstIdx] = CoefficientState(rawValue: firstNewRaw)

                        if options.trackDistortion {
                            reconPtr[firstIdx] = reconVal
                            let fm = Int64(magPtr[firstIdx])
                            let fe = fm &- Int64(reconVal)
                            passDistortion += Double(fm &* fm &- fe &* fe)
                        }

                        // Positions > firstSigPos: state==0 (RLC eligibility + no prior coding)
                        for y in (stripeY + firstSigPos + 1)..<stripeEnd {
                            let idx = y &* w &+ x

                            // State is 0 here (proven by RLC eligibility): skip the state check.
                            let rawCtxRLC = contextModeler.cleanupSigContext(
                                x: x, y: y, width: w, height: h, states: statePtr)
                            let isSignificant = (magPtr[idx] & bitMask) != 0
                            encoder.encode(symbol: isSignificant, context: &ctxPtr[Int(rawCtxRLC)])

                            if isSignificant {
                                let (hSign, vSign) = neighborCalculator.computeCardinalSignsUnsafe(
                                    x: x, y: y,
                                    states: statePtr
                                )
                                let signEntry = ContextModeler.signContextLUT[(hSign + 2) * 5 + (vSign + 2)]
                                let signBit = signPtr[idx]
                                let codedSign = signBit != ((signEntry & 1) != 0)
                                encoder.encode(symbol: codedSign, context: &ctxPtr[Int(signEntry >> 1)])

                                var newRawRLC: UInt8 = 0x03  // significant | codedThisPass
                                if signBit { newRawRLC |= 0x04 }  // signBit
                                statePtr[idx] = CoefficientState(rawValue: newRawRLC)

                                if options.trackDistortion {
                                    reconPtr[idx] = reconVal
                                    let m = Int64(magPtr[idx])
                                    let e = m &- Int64(reconVal)
                                    passDistortion += Double(m &* m &- e &* e)
                                }
                            } else {
                                statePtr[idx] = CoefficientState(rawValue: 0x02)  // codedThisPass
                            }
                        }
                        continue
                    }
                }

                for y in stripeY..<stripeEnd {
                    let idx = y &* w &+ x

                    // cleanupSigContextOrSkip folds sig/coded check via mid byte 1
                    let rawCtxCUP = contextModeler.cleanupSigContextOrSkip(
                        x: x, y: y, width: w, height: h, states: statePtr)
                    if rawCtxCUP == 0xFF {
                        #if EBCOT_DEBUG_TRACE
                        EBCOTDebugTrace.shared.logEncode("skip(coded/sig)", x: x, y: y)
                        #endif
                        continue
                    }

                    let isSignificant = (magPtr[idx] & bitMask) != 0

                    encoder.encode(symbol: isSignificant, context: &ctxPtr[Int(rawCtxCUP)])
                    #if EBCOT_DEBUG_TRACE
                    EBCOTDebugTrace.shared.logEncode("sig(\(isSignificant),ctx=\(rawCtxCUP))", x: x, y: y)
                    #endif

                    if isSignificant {
                        let (hSign, vSign) = neighborCalculator.computeCardinalSignsUnsafe(
                            x: x, y: y,
                            states: statePtr
                        )
                        let signEntry = ContextModeler.signContextLUT[(hSign + 2) * 5 + (vSign + 2)]
                        let signBit = signPtr[idx]
                        let codedSign = signBit != ((signEntry & 1) != 0)
                        encoder.encode(symbol: codedSign, context: &ctxPtr[Int(signEntry >> 1)])
                        #if EBCOT_DEBUG_TRACE
                        EBCOTDebugTrace.shared.logEncode("sign(s=\(signBit),mq=\(codedSign),xor=\((signEntry & 1) != 0),ctx=\(signEntry >> 1))", x: x, y: y)
                        #endif

                        // rawState is proven 0 here (sig/coded checked above)
                        var newRaw: UInt8 = 0x03  // significant | codedThisPass
                        if signBit { newRaw |= 0x04 }  // signBit
                        statePtr[idx] = CoefficientState(rawValue: newRaw)

                        if options.trackDistortion {
                            reconPtr[idx] = reconVal
                            let m = Int64(magPtr[idx])
                            let e = m &- Int64(reconVal)
                            passDistortion += Double(m &* m &- e &* e)
                        }
                    } else {
                        statePtr[idx] = CoefficientState(rawValue: 0x02)  // codedThisPass
                    }
                }
            }
        }
                    } // ctxPtr
                    } // reconBuf
                } // stateBuf
            } // signBuf
        } // magBuf
        return passDistortion
    }

    /// Checks if a column is eligible for run-length coding.
    ///
    /// A column is eligible if all coefficients are not yet significant,
    /// not already coded, and have no significant neighbors.
    private func isEligibleForRunLengthCoding(
        x: Int,
        stripeStart: Int,
        stripeEnd: Int,
        states: [CoefficientState]
    ) -> Bool {
        // RLC only applies to full 4-row stripes per ISO 15444-1 D.3.7
        guard stripeEnd - stripeStart == 4 else { return false }

        for y in stripeStart..<stripeEnd {
            let idx = y * width + x

            // Can't use RLC if any coefficient is already significant or coded
            if states[idx].contains(.significant) || states[idx].contains(.codedThisPass) {
                return false
            }

            // Can't use RLC if any neighbor is significant
            let neighbors = neighborCalculator.calculate(x: x, y: y, states: states)
            if neighbors.hasAny {
                return false
            }
        }

        return true
    }

    /// Unsafe version of RLC eligibility check for use within withUnsafeMutableBufferPointer.
    @inline(__always)
    private func isEligibleForRunLengthCodingUnsafe(
        x: Int,
        stripeStart: Int,
        stripeEnd: Int,
        states: UnsafeMutablePointer<CoefficientState>
    ) -> Bool {
        guard stripeEnd - stripeStart == 4 else { return false }
        let w = width
        // Batch all 4 sig/coded checks in one OR — only then check neighbors.
        let i0 = stripeStart &* w &+ x
        let i1 = i0 &+ w; let i2 = i1 &+ w; let i3 = i2 &+ w
        if (states[i0].rawValue | states[i1].rawValue | states[i2].rawValue | states[i3].rawValue) & 0x03 != 0 {
            return false
        }
        // Batch 4 rows of hasAnySignificantNeighbor into 6 word loads (vs 4×3=12).
        // Interior fast path: all 4 rows AND their border rows are fully interior.
        // Prior sig/coded check guarantees states[i0..i3] have sig=0, so byte 1 of
        // r1..r4 is safe to include nakedly in the combined OR — no false positives.
        if x > 0 && x < w &- 1 && stripeStart > 0 && stripeEnd < height {
            let xm1 = x &- 1
            let rawPtr = UnsafeRawPointer(states)
            // 6 row words covering rows (stripeStart-1) through (stripeEnd)
            let r0 = rawPtr.loadUnaligned(fromByteOffset: (stripeStart &- 1) &* w &+ xm1, as: UInt32.self)
            let r1 = rawPtr.loadUnaligned(fromByteOffset:  stripeStart      &* w &+ xm1, as: UInt32.self)
            let r2 = rawPtr.loadUnaligned(fromByteOffset: (stripeStart &+ 1) &* w &+ xm1, as: UInt32.self)
            let r3 = rawPtr.loadUnaligned(fromByteOffset: (stripeStart &+ 2) &* w &+ xm1, as: UInt32.self)
            let r4 = rawPtr.loadUnaligned(fromByteOffset: (stripeStart &+ 3) &* w &+ xm1, as: UInt32.self)
            let r5 = rawPtr.loadUnaligned(fromByteOffset:  stripeEnd         &* w &+ xm1, as: UInt32.self)
            // OR of 4 per-row checks (top | mid_masked | bot) & 0x00010101.
            // Simplifies to (r0|r1|r2|r3|r4|r5) because sig=0 in r1..r4 byte 1.
            return (r0 | r1 | r2 | r3 | r4 | r5) & 0x00010101 == 0
        }
        // Border/partial stripe fallback
        for y in stripeStart..<stripeEnd {
            if neighborCalculator.hasAnySignificantNeighborUnsafe(x: x, y: y, states: states) {
                return false
            }
        }
        return true
    }

    /// Unsafe version of significance check for use within withUnsafeBufferPointer.
    @inline(__always)
    private func anyBecomeSignificantUnsafe(
        x: Int,
        stripeStart: Int,
        stripeEnd: Int,
        magnitudes: UnsafePointer<UInt32>,
        bitMask: UInt32
    ) -> Bool {
        let w = width
        for y in stripeStart..<stripeEnd {
            let idx = y &* w &+ x
            if (magnitudes[idx] & bitMask) != 0 {
                return true
            }
        }
        return false
    }

    /// Checks if any coefficient in a column becomes significant at this bit-plane.
    private func anyBecomeSignificant(
        x: Int,
        stripeStart: Int,
        stripeEnd: Int,
        magnitudes: [UInt32],
        bitMask: UInt32
    ) -> Bool {
        for y in stripeStart..<stripeEnd {
            let idx = y * width + x
            if (magnitudes[idx] & bitMask) != 0 {
                return true
            }
        }
        return false
    }

    /// Checks if run-length coding can be used for a column in a stripe (legacy method for encoder).
    ///
    /// This checks both eligibility AND that no coefficients become significant.
    /// Kept for backwards compatibility but prefer using isEligibleForRunLengthCoding + anyBecomeSignificant.
    private func canUseRunLengthCoding(
        x: Int,
        stripeStart: Int,
        stripeEnd: Int,
        states: [CoefficientState],
        magnitudes: [UInt32],
        bitMask: UInt32
    ) -> Bool {
        isEligibleForRunLengthCoding(
            x: x, stripeStart: stripeStart,
            stripeEnd: stripeEnd, states: states) &&
        !anyBecomeSignificant(
            x: x, stripeStart: stripeStart,
            stripeEnd: stripeEnd,
            magnitudes: magnitudes, bitMask: bitMask)
    }

    // MARK: - Distortion Helpers

    /// Computes distortion reduction for newly significant coefficients coded in this pass.
    ///
    /// Updates reconstruction values for coefficients that became significant.
    /// Used after SPP and Cleanup passes.
    @inline(__always)
    private func computeNewSignificanceDistortion(
        states: inout [CoefficientState],
        magnitudes: [UInt32],
        recon: inout [UInt32],
        bitPlane: Int
    ) -> Double {
        let count = states.count
        let halfBit: UInt32 = bitPlane > 0 ? UInt32(1 << (bitPlane - 1)) : 0
        let reconVal = UInt32(1 << bitPlane) | halfBit
        let codedAndSig = CoefficientState.codedThisPass.rawValue | CoefficientState.significant.rawValue
        return states.withUnsafeMutableBufferPointer { statesBuf in
            magnitudes.withUnsafeBufferPointer { magBuf in
                recon.withUnsafeMutableBufferPointer { reconBuf in
                    var delta: Double = 0
                    for i in 0..<count {
                        let raw = statesBuf[i].rawValue
                        if (raw & codedAndSig) == codedAndSig && reconBuf[i] == 0 {
                            reconBuf[i] = reconVal
                            let m = Int64(magBuf[i])
                            let e = m - Int64(reconVal)
                            delta += Double(m &* m &- e &* e)
                        }
                    }
                    return delta
                }
            }
        }
    }

    /// Computes distortion reduction for refined coefficients coded in this pass.
    ///
    /// Updates reconstruction values for coefficients that were already significant
    /// and got their magnitude refined. Used after MRP passes.
    @inline(__always)
    private func computeRefinementDistortion(
        states: inout [CoefficientState],
        magnitudes: [UInt32],
        recon: inout [UInt32],
        bitPlane: Int
    ) -> Double {
        let count = states.count
        let halfBit: UInt32 = bitPlane > 0 ? UInt32(1 << (bitPlane - 1)) : 0
        let clearMask = ~UInt32((1 << (bitPlane + 1)) - 1)
        let bitVal = UInt32(1 << bitPlane)
        let codedAndSig = CoefficientState.codedThisPass.rawValue | CoefficientState.significant.rawValue
        return states.withUnsafeMutableBufferPointer { statesBuf in
            magnitudes.withUnsafeBufferPointer { magBuf in
                recon.withUnsafeMutableBufferPointer { reconBuf in
                    var delta: Double = 0
                    for i in 0..<count {
                        let raw = statesBuf[i].rawValue
                        if (raw & codedAndSig) == codedAndSig && reconBuf[i] > 0 {
                            let oldErr = Int64(magBuf[i]) - Int64(reconBuf[i])
                            let high = reconBuf[i] & clearMask
                            reconBuf[i] = high | (magBuf[i] & bitVal) | halfBit
                            let newErr = Int64(magBuf[i]) - Int64(reconBuf[i])
                            delta += Double(oldErr &* oldErr &- newErr &* newErr)
                        }
                    }
                    return delta
                }
            }
        }
    }
}

// MARK: - Bit-Plane Decoder

/// Pre-allocated scratch buffers for EBCOT bit-plane decoding.
///
/// One instance per decode worker task. Reused across all code blocks
/// in a sequential chunk, eliminating 5 heap allocations per block.
final class DecoderScratchBuffers {
    private(set) var capacity: Int
    var magnitudes: [UInt32]
    var states: [CoefficientState]
    var halfBits: [UInt32]

    init(capacity: Int = 4096) {
        self.capacity = capacity
        magnitudes = [UInt32](repeating: 0, count: capacity)
        states = [CoefficientState](repeating: [], count: capacity)
        halfBits = [UInt32](repeating: 0, count: capacity)
    }

    /// Ensures the buffers can hold `count` elements and zeros them all.
    @inline(__always)
    func prepare(count: Int) {
        if count > capacity {
            capacity = count &* 2
            magnitudes = [UInt32](repeating: 0, count: capacity)
            states = [CoefficientState](repeating: [], count: capacity)
            halfBits = [UInt32](repeating: 0, count: capacity)
            return
        }
        // Zero only the used region via memset (faster than array init)
        magnitudes.withUnsafeMutableBufferPointer { p in
            _ = memset(p.baseAddress!, 0, count &* MemoryLayout<UInt32>.size) }
        states.withUnsafeMutableBufferPointer { p in
            _ = memset(p.baseAddress!, 0, count &* MemoryLayout<CoefficientState>.size) }
        halfBits.withUnsafeMutableBufferPointer { p in
            _ = memset(p.baseAddress!, 0, count &* MemoryLayout<UInt32>.size) }
    }
}

/// Decodes wavelet coefficients using EBCOT bit-plane decoding.
///
/// The bit-plane decoder reverses the encoding process, reconstructing
/// wavelet coefficients from the compressed bitstream.
struct BitPlaneDecoder: Sendable {
    /// The width of the code-block.
    let width: Int

    /// The height of the code-block.
    let height: Int

    /// The subband type for context formation.
    let subband: J2KSubband

    /// The context modeler for this subband.
    private let contextModeler: ContextModeler

    /// The neighbor calculator.
    private let neighborCalculator: NeighborCalculator

    /// Coding options for this decoder.
    private let options: CodingOptions

    /// Creates a new bit-plane decoder for the specified dimensions and subband.
    ///
    /// - Parameters:
    ///   - width: The width of the code-block in samples.
    ///   - height: The height of the code-block in samples.
    ///   - subband: The wavelet subband type.
    ///   - options: Coding options (default: `.default`).
    init(width: Int, height: Int, subband: J2KSubband, options: CodingOptions = .default) {
        self.width = width
        self.height = height
        self.subband = subband
        self.contextModeler = ContextModeler(subband: subband)
        self.neighborCalculator = NeighborCalculator(width: width, height: height)
        self.options = options
    }

    /// Decodes wavelet coefficients from EBCOT encoded data.
    ///
    /// - Parameters:
    ///   - data: The encoded data.
    ///   - passCount: The number of coding passes to decode.
    ///   - bitDepth: The bit depth of the coefficients.
    ///   - zeroBitPlanes: The number of zero bit-planes.
    ///   - passSegmentLengths: Per-pass segment byte lengths for predictable termination (empty for default).
    ///   - irreversible: Whether this uses irreversible (9/7) transform. When true, coefficients
    ///     use bpno_plus_one scale (shifted left by 1) matching OPJ's approach, and the caller
    ///     must apply ×0.5 during dequantization.
    /// - Returns: The decoded wavelet coefficients.
    /// - Throws: ``J2KError`` if decoding fails.
    func decode(
        data: Data,
        passCount: Int,
        bitDepth: Int,
        zeroBitPlanes: Int,
        passSegmentLengths: [Int] = [],
        irreversible: Bool = false,
        scratch: DecoderScratchBuffers? = nil
    ) throws -> [Int32] {
        let count = width * height

        // A code-block with no coding passes is the JPEG 2000 representation
        // of an all-zero block. Do not enter the bit-plane loop in this case:
        // the old path still walked every active bit-plane and cleared the
        // scratch state even though it had no entropy symbols to consume.
        // Large sparse medical images contain many such blocks, so this is a
        // correctness-preserving fast path for both fresh and reused scratch.
        guard passCount > 0 else {
            return [Int32](repeating: 0, count: count)
        }

        // Use scratch buffers when provided.
        // "Steal" the arrays out of scratch so local vars have exclusive ownership
        // (refcount=1) — this prevents COW copies on every write into the arrays.
        // A defer block returns them to scratch for the next block.
        var magnitudes: [UInt32]
        var states: [CoefficientState]
        var halfBits: [UInt32]

        if let sc = scratch {
            sc.prepare(count: count)
            magnitudes = sc.magnitudes;     sc.magnitudes = []
            states = sc.states;             sc.states = []
            halfBits = sc.halfBits;         sc.halfBits = []
        } else {
            // Per-coefficient half-bit for midpoint reconstruction (OPJ "oneplushalf").
            magnitudes = [UInt32](repeating: 0, count: count)
            states = [CoefficientState](repeating: [], count: count)
            halfBits = [UInt32](repeating: 0, count: count)
        }

        defer {
            if let sc = scratch {
                sc.magnitudes = magnitudes
                sc.states = states
                sc.halfBits = halfBits
            }
        }

        // Determine if we need per-pass segment decoding
        let usePerPassSegments = !passSegmentLengths.isEmpty

        // Borrow the codestream bytes via Data.withUnsafeBytes for the
        // entire decode — no per-block `[UInt8](data)` copy, no
        // per-MQDecoder `withUnsafeBufferPointer` closure invocation.
        // Each MQDecoder / RawBypassDecoder instance constructed below
        // receives a raw `UnsafePointer<UInt8>` valid for the lifetime
        // of this scope.
        return try data.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) -> [Int32] in
        let dataPtr = rawBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let dataCount = rawBuf.count

        // Pre-compute per-pass segment slices (offset + count into the
        // borrowed buffer). Replaces the old [Data] approach which
        // created a Data copy per segment.
        var passSlices: [(offset: Int, count: Int)] = []
        if usePerPassSegments {
            passSlices.reserveCapacity(passSegmentLengths.count)
            let totalSegmentLength = passSegmentLengths.reduce(0, +)
            guard totalSegmentLength <= dataCount else {
                throw J2KError.invalidParameter(
                    "Pass segment lengths total (\(totalSegmentLength)) exceeds data size (\(dataCount))"
                )
            }
            var offset = 0
            for length in passSegmentLengths {
                passSlices.append((offset: offset, count: length))
                offset += length
            }
        }

        // Initialise MQ decoder and contexts
        var decoder = MQDecoder(unsafePtr: dataPtr, offset: 0, count: usePerPassSegments ? 0 : dataCount)
        var rawDecoder = RawBypassDecoder(unsafePtr: dataPtr, offset: 0, count: 0)
        var contextStates = ContextStateArray()
        // RESET (style bit 1) and the encoder's `.predictable` mode reset the contexts at every pass boundary.
        let resetContextsEachPass = options.resetContextOnEachPass || options.resetOnEachPass

        // The codeword segment each pass belongs to (Annex D): one per pass under RESTART or `.predictable`, and
        // 10, 2, 1, 2, 1, ... passes under selective bypass. Contexts survive a segment boundary unless RESET asks.
        var segmentOfPass: [Int] = []
        if usePerPassSegments {
            var counts = DecoderPipeline.segmentPassCounts(
                numPasses: passCount,
                terminateOnEachPass: options.terminateOnEachPass || options.terminationMode == .predictable,
                bypass: options.bypassEnabled)
            if counts.count != passSlices.count {
                // A direct code-block caller that terminates every pass hands over one segment per pass; with the
                // lengths in hand there is no packet header whose shape they must follow.
                counts = [Int](repeating: 1, count: min(passCount, passSlices.count))
            }
            for (segment, passes) in counts.enumerated() {
                segmentOfPass.append(contentsOf: repeatElement(segment, count: passes))
            }
        }
        var currentSegment = -1
        // Integrity accounting (#2899): which decoder holds the open segment, and the totals of closed ones.
        var liveDecoder: EntropySegmentKind = usePerPassSegments ? .none : .arithmetic
        var integrity = EntropyIntegrity()
        func closeSegment() {
            switch liveDecoder {
            case .arithmetic: integrity.absorb(decoder)
            case .raw: integrity.absorb(rawDecoder)
            case .none: break
            }
        }

        let activeBitPlanes = bitDepth - zeroBitPlanes
        var passesDecoded = 0

        /// Prepares the next pass: resets contexts under RESET and opens the pass's codeword segment, raw or
        /// arithmetic. Returns false when the block has no segment left for it.
        func beginPass(raw: Bool) -> Bool {
            if resetContextsEachPass && passesDecoded > 0 { contextStates.reset() }
            guard usePerPassSegments else { return true }
            guard passesDecoded < segmentOfPass.count else { return false }
            let segment = segmentOfPass[passesDecoded]
            if segment != currentSegment {
                closeSegment()
                let slice = passSlices[segment]
                if raw {
                    rawDecoder = RawBypassDecoder(unsafePtr: dataPtr, offset: slice.offset, count: slice.count)
                } else {
                    decoder = MQDecoder(unsafePtr: dataPtr, offset: slice.offset, count: slice.count)
                }
                liveDecoder = raw ? .raw : .arithmetic
                currentSegment = segment
            }
            return true
        }

        // Process each bit-plane from MSB to LSB.
        // For irreversible (9/7) transform, use bpno_plus_one (= bitPlane + 1) for
        // bit masks, matching OPJ's approach. This ensures that at bitPlane=0,
        // halfBitMask=1 (not 0), so the midpoint reconstruction correctly adds 0.5
        // after the ×0.5 dequantization factor applied by the caller.
        // For reversible (5/3) transform, use standard bit plane indexing.
        let bpnoShift = irreversible ? 1 : 0
        for bitPlane in stride(from: activeBitPlanes - 1, through: 0, by: -1) {
            let bitMask: UInt32 = 1 << (bitPlane + bpnoShift)
            let halfBitMask: UInt32
            if irreversible {
                halfBitMask = 1 << bitPlane
            } else {
                halfBitMask = bitPlane > 0 ? (1 << (bitPlane - 1)) : 0
            }

            // Per ISO 15444-1 Annex D, the MSB (first) bit plane starts with
            // Cleanup only — SigProp and MagRef are skipped.
            let isFirstBitPlane = (bitPlane == activeBitPlanes - 1)

            // Pass 1: Significance Propagation Pass (skip for MSB bit plane). Under selective bypass the
            // significance-propagation and magnitude-refinement passes after the first ten are raw (D.6).
            if !isFirstBitPlane && passesDecoded < passCount {
                let raw = options.bypassEnabled && passesDecoded >= 10
                guard beginPass(raw: raw) else { break }

                #if EBCOT_DEBUG_TRACE
                EBCOTDebugTrace.shared.logDecode("=== SIGPROP bitPlane=\(bitPlane) pass=\(passesDecoded) ===", x: -1, y: -1)
                #endif
                if raw {
                    decodeSignificancePropagationPassBypass(
                        magnitudes: &magnitudes,
                        states: &states,
                        halfBits: &halfBits,
                        bitMask: bitMask,
                        halfBitMask: halfBitMask,
                        bypassDecoder: &rawDecoder
                    )
                } else {
                    decodeSignificancePropagationPass(
                        magnitudes: &magnitudes,
                        states: &states,
                        halfBits: &halfBits,
                        bitMask: bitMask,
                        halfBitMask: halfBitMask,
                        decoder: &decoder,
                        contexts: &contextStates
                    )
                }
                #if EBCOT_DEBUG_TRACE
                if EBCOTDebugTrace.shared.enabled {
                    let sigCount = states.filter { $0.contains(.significant) }.count
                    var sigHash: UInt64 = 0
                    for (i, s) in states.enumerated() {
                        if s.contains(.significant) {
                            sigHash = sigHash &+ UInt64(i &* 2654435761)
                        }
                    }
                    EBCOTDebugTrace.shared.logDecode("POST_SIGPROP sig=\(sigCount) hash=\(sigHash)", x: -1, y: -1)
                    EBCOTDebugTrace.shared.saveDecoderStates("sigprop_bp\(bitPlane)", states)
                }
                if EBCOTDebugTrace.shared.enabled {
                    EBCOTDebugTrace.shared.logDecoderPassEnd(pass: passesDecoded, a: decoder.debugA, c: decoder.debugC, opCount: decoder.operationCount)
                    EBCOTDebugTrace.shared.saveDecoderContexts(passesDecoded, contextStates)
                }
                #endif
                passesDecoded += 1
            }

            // Pass 2: Magnitude Refinement Pass (skip for MSB bit plane)
            if !isFirstBitPlane && passesDecoded < passCount {
                let raw = options.bypassEnabled && passesDecoded >= 10
                guard beginPass(raw: raw) else { break }
                #if EBCOT_DEBUG_TRACE
                EBCOTDebugTrace.shared.logDecode("=== MAGREF bitPlane=\(bitPlane) pass=\(passesDecoded) ===", x: -1, y: -1)
                #endif
                if raw {
                    decodeMagnitudeRefinementPassBypass(
                        magnitudes: &magnitudes,
                        states: &states,
                        halfBits: &halfBits,
                        bitMask: bitMask,
                        halfBitMask: halfBitMask,
                        bypassDecoder: &rawDecoder
                    )
                } else {
                    decodeMagnitudeRefinementPass(
                        magnitudes: &magnitudes,
                        states: &states,
                        halfBits: &halfBits,
                        bitMask: bitMask,
                        halfBitMask: halfBitMask,
                        decoder: &decoder,
                        contexts: &contextStates,
                        useBypass: false
                    )
                }
                #if EBCOT_DEBUG_TRACE
                if EBCOTDebugTrace.shared.enabled {
                    EBCOTDebugTrace.shared.logDecoderPassEnd(pass: passesDecoded, a: decoder.debugA, c: decoder.debugC, opCount: decoder.operationCount)
                    EBCOTDebugTrace.shared.saveDecoderContexts(passesDecoded, contextStates)
                }
                #endif
                passesDecoded += 1
            }

            // Pass 3: Cleanup Pass (always arithmetic)
            if passesDecoded < passCount {
                guard beginPass(raw: false) else { break }

                #if EBCOT_DEBUG_TRACE
                EBCOTDebugTrace.shared.logDecode("=== CLEANUP bitPlane=\(bitPlane) pass=\(passesDecoded) ===", x: -1, y: -1)
                #endif
                decodeCleanupPass(
                    magnitudes: &magnitudes,
                    states: &states,
                    halfBits: &halfBits,
                    bitMask: bitMask,
                    halfBitMask: halfBitMask,
                    decoder: &decoder,
                    contexts: &contextStates
                )
                // Segmentation symbols (style bit 5): the encoder codes 0b1010 with the uniform context after
                // every cleanup pass. They are part of the codeword, so they must be consumed, and a different
                // value means the segment is corrupt.
                if options.segmentationSymbols {
                    var symbol = 0
                    contextStates.withUnsafeMutableContextArray { ctxPtr in
                        for _ in 0..<4 { symbol = symbol << 1 | (decoder.decode(context: &ctxPtr[18]) ? 1 : 0) }
                    }
                    guard symbol == 0b1010 else {
                        throw J2KError.decodingError(
                            "Segmentation symbol 0x\(String(symbol, radix: 16)) after cleanup pass \(passesDecoded); "
                            + "expected 0xA")
                    }
                }
                // Count significant coefficients after cleanup
                #if EBCOT_DEBUG_TRACE
                if EBCOTDebugTrace.shared.enabled {
                    let sigCount = states.filter { $0.contains(.significant) }.count
                    let sbitCount = states.filter { $0.contains(.signBit) }.count
                    var sigHash: UInt64 = 0
                    for (i, s) in states.enumerated() {
                        if s.contains(.significant) {
                            sigHash = sigHash &+ UInt64(i &* 2654435761)
                        }
                    }
                    EBCOTDebugTrace.shared.logDecode("POST_CLEANUP sig=\(sigCount) sbit=\(sbitCount) hash=\(sigHash)", x: -1, y: -1)
                    EBCOTDebugTrace.shared.saveDecoderStates("cleanup_bp\(bitPlane)", states)
                }
                if EBCOTDebugTrace.shared.enabled {
                    EBCOTDebugTrace.shared.logDecoderPassEnd(pass: passesDecoded, a: decoder.debugA, c: decoder.debugC, opCount: decoder.operationCount)
                    EBCOTDebugTrace.shared.saveDecoderContexts(passesDecoded, contextStates)
                }
                #endif
                passesDecoded += 1
            }

            // Once the requested contribution has been consumed there is no
            // next bit-plane that can observe `codedThisPass`.  Returning to
            // the loop used to clear the whole scratch capacity for every
            // remaining bit-plane after a truncated quality-layer prefix, and
            // also performed one useless final clear for complete blocks.
            // Stop at the exact pass boundary instead.
            if passesDecoded >= passCount {
                break
            }

            // Clear coded-this-pass flags for next bit-plane (batch bitwise, 8 bytes at a time)
            let decoderClearMask = ~CoefficientState.codedThisPass.rawValue
            states.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                // Scratch arrays retain worker capacity (normally 4096) even
                // for narrow/right/bottom edge blocks.  Only the logical
                // coefficient region participates in this decode.
                let n = count
                let mask64 = UInt64(decoderClearMask) &* 0x0101010101010101
                let wordCount = n / 8
                base.withMemoryRebound(to: UInt64.self, capacity: wordCount) { wordPtr in
                    for i in 0..<wordCount { wordPtr[i] &= mask64 }
                }
                base.withMemoryRebound(to: UInt8.self, capacity: n) { rawPtr in
                    for i in (wordCount &* 8)..<n { rawPtr[i] &= decoderClearMask }
                }
            }
        }

        if options.checksEntropyIntegrity {
            closeSegment()
            if let anomaly = integrity.anomaly {
                throw J2KError.corruptedEntropyData(anomaly)
            }
        }

        // Reconstruct signed coefficients with per-coefficient midpoint reconstruction.
        // Each significant coefficient has a half-bit set at the bit plane below the
        // lowest decoded plane, centering the value in the unresolved range.
        // The halfBits array tracks this per the OPJ "oneplushalf" approach.
        // CoefficientState.signBit is the canonical sign store; keeping a second
        // Bool array here doubled the per-block state traffic without adding data.
        var coefficients = [Int32](repeating: 0, count: width * height)
        magnitudes.withUnsafeBufferPointer { magBuf in
            halfBits.withUnsafeBufferPointer { halfBuf in
                states.withUnsafeBufferPointer { stateBuf in
                    coefficients.withUnsafeMutableBufferPointer { coeffBuf in
                        let mp = magBuf.baseAddress!
                        let hp = halfBuf.baseAddress!
                        let statePtr = stateBuf.baseAddress!
                        let cp = coeffBuf.baseAddress!
                        let stateRaw = UnsafeRawPointer(statePtr).assumingMemoryBound(to: UInt8.self)
                        let simdCount = count / 4
                        let remStart = simdCount &* 4
                        for i in 0..<simdCount {
                            let base = i &* 4
                            let sb = SIMD4<UInt32>(
                                UInt32((stateRaw[base] & 0x04) >> 2),
                                UInt32((stateRaw[base &+ 1] & 0x04) >> 2),
                                UInt32((stateRaw[base &+ 2] & 0x04) >> 2),
                                UInt32((stateRaw[base &+ 3] & 0x04) >> 2)
                            )
                            let signMask = SIMD4<UInt32>.zero &- sb
                            let finalMag =
                                SIMD4<UInt32>(mp[base], mp[base &+ 1], mp[base &+ 2], mp[base &+ 3]) |
                                SIMD4<UInt32>(hp[base], hp[base &+ 1], hp[base &+ 2], hp[base &+ 3])
                            let result = (finalMag ^ signMask) &- signMask
                            cp[base]       = Int32(bitPattern: result[0])
                            cp[base &+ 1] = Int32(bitPattern: result[1])
                            cp[base &+ 2] = Int32(bitPattern: result[2])
                            cp[base &+ 3] = Int32(bitPattern: result[3])
                        }
                        for i in remStart..<count {
                            let finalMag = mp[i] | hp[i]
                            cp[i] = (statePtr[i].rawValue & 0x04) != 0
                                ? -Int32(bitPattern: finalMag)
                                : Int32(bitPattern: finalMag)
                        }
                    }
                }
            }
        }

        return coefficients
        }  // end data.withUnsafeBytes
    }

    // MARK: - Significance Propagation Pass (Decode)

    /// Decodes the significance propagation pass.
    private func decodeSignificancePropagationPass(
        magnitudes: inout [UInt32],
        states: inout [CoefficientState],
        halfBits: inout [UInt32],
        bitMask: UInt32,
        halfBitMask: UInt32,
        decoder: inout MQDecoder,
        contexts: inout ContextStateArray
    ) {
        let stripeHeight = 4
        let w = width
        let h = height
        var causal = VerticallyCausalStripeMask(enabled: options.verticallyCausalContext, width: w)

        magnitudes.withUnsafeMutableBufferPointer { magBuf in
            states.withUnsafeMutableBufferPointer { stateBuf in
                halfBits.withUnsafeMutableBufferPointer { halfBuf in
                    let magPtr = magBuf.baseAddress!
                    let statePtr = stateBuf.baseAddress!
                    let halfPtr = halfBuf.baseAddress!

                    contexts.withUnsafeMutableContextArray { ctxPtr in
                        for stripeY in stride(from: 0, to: h, by: stripeHeight) {
                            let stripeEnd = min(stripeY + stripeHeight, h)
                            causal.hideRow(stripeEnd, width: w, height: h, states: statePtr)
                            defer { causal.restore(width: w, states: statePtr) }

                            for x in 0..<w {
                                for y in stripeY..<stripeEnd {
                                        let idx = y &* w &+ x

                                        // sppSigContextOrSkip folds in the sig/coded check via
                                        // mid byte 1 of its 3-word load — no separate state read.
                                        let ctxRaw = contextModeler.sppSigContextOrSkip(
                                            x: x, y: y, width: w, height: h, states: statePtr)
                                        guard ctxRaw != 0xFF else { continue }

                                        let isSignificant = decoder.decode(context: &ctxPtr[Int(ctxRaw)])

                                        if isSignificant {
                                            let (hSign, vSign) = neighborCalculator.computeCardinalSignsUnsafe(
                                                x: x, y: y,
                                                states: statePtr
                                            )
                                            let signEntry = ContextModeler.signContextLUT[(hSign + 2) * 5 + (vSign + 2)]
                                            let codedSign = decoder.decode(context: &ctxPtr[Int(signEntry >> 1)])
                                            let signBit = codedSign != ((signEntry & 1) != 0)

                                            magPtr[idx] = magPtr[idx] | bitMask
                                            halfPtr[idx] = halfBitMask
                                            // rawState is proven 0 here (sig/coded checked above)
                                            var newRaw: UInt8 = 0x03  // significant | codedThisPass
                                            if signBit { newRaw |= 0x04 }  // signBit
                                            statePtr[idx] = CoefficientState(rawValue: newRaw)
                                        } else {
                                            statePtr[idx] = CoefficientState(rawValue: 0x02)  // codedThisPass
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

    /// Decodes a significance-propagation pass coded raw under selective bypass (D.6): the same coefficients as
    /// the arithmetic pass, but significance and sign are single raw bits with no context and no sign prediction.
    private func decodeSignificancePropagationPassBypass(
        magnitudes: inout [UInt32],
        states: inout [CoefficientState],
        halfBits: inout [UInt32],
        bitMask: UInt32,
        halfBitMask: UInt32,
        bypassDecoder: inout RawBypassDecoder
    ) {
        let stripeHeight = 4
        let w = width
        let h = height
        var causal = VerticallyCausalStripeMask(enabled: options.verticallyCausalContext, width: w)

        magnitudes.withUnsafeMutableBufferPointer { magBuf in
            states.withUnsafeMutableBufferPointer { stateBuf in
                halfBits.withUnsafeMutableBufferPointer { halfBuf in
                    let magPtr = magBuf.baseAddress!
                    let statePtr = stateBuf.baseAddress!
                    let halfPtr = halfBuf.baseAddress!

                    for stripeY in stride(from: 0, to: h, by: stripeHeight) {
                        let stripeEnd = min(stripeY + stripeHeight, h)
                        causal.hideRow(stripeEnd, width: w, height: h, states: statePtr)
                        defer { causal.restore(width: w, states: statePtr) }

                        for x in 0..<w {
                            for y in stripeY..<stripeEnd {
                                let idx = y &* w &+ x
                                // Eligibility only: not yet significant or coded, with a significant neighbour.
                                guard contextModeler.sppSigContextOrSkip(
                                    x: x, y: y, width: w, height: h, states: statePtr) != 0xFF else { continue }

                                if bypassDecoder.decode() {
                                    let negative = bypassDecoder.decode()
                                    magPtr[idx] = magPtr[idx] | bitMask
                                    halfPtr[idx] = halfBitMask
                                    statePtr[idx] = CoefficientState(rawValue: negative ? 0x07 : 0x03)
                                } else {
                                    statePtr[idx] = CoefficientState(rawValue: 0x02)  // codedThisPass
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Magnitude Refinement Pass (Decode)

    private func decodeMagnitudeRefinementPass(
        magnitudes: inout [UInt32],
        states: inout [CoefficientState],
        halfBits: inout [UInt32],
        bitMask: UInt32,
        halfBitMask: UInt32,
        decoder: inout MQDecoder,
        contexts: inout ContextStateArray,
        useBypass: Bool = false
    ) {
        let stripeHeight = 4
        let w = width
        let h = height
        var causal = VerticallyCausalStripeMask(enabled: options.verticallyCausalContext, width: w)

        magnitudes.withUnsafeMutableBufferPointer { magBuf in
            states.withUnsafeMutableBufferPointer { stateBuf in
                halfBits.withUnsafeMutableBufferPointer { halfBuf in
                    let magPtr = magBuf.baseAddress!
                    let statePtr = stateBuf.baseAddress!
                    let halfPtr = halfBuf.baseAddress!

                    contexts.withUnsafeMutableContextArray { ctxPtr in
                        for stripeY in stride(from: 0, to: h, by: stripeHeight) {
                            let stripeEnd = min(stripeY + stripeHeight, h)
                            causal.hideRow(stripeEnd, width: w, height: h, states: statePtr)
                            defer { causal.restore(width: w, states: statePtr) }

                            for x in 0..<w {
                                for y in stripeY..<stripeEnd {
                                    let idx = y &* w &+ x

                                    let stRaw = statePtr[idx].rawValue
                                    guard (stRaw & 0x03) == 0x01 else { continue }

                                    let bitValue: Bool
                                    if useBypass {
                                        bitValue = decoder.decodeBypass()
                                    } else {
                                        // bit 3 = refinementVisited: 0 = first refinement, 1 = subsequent
                                        let isFirstRefinement = (stRaw & 0x08) == 0
                                        let hasSignificantNeighbors = isFirstRefinement &&
                                            neighborCalculator.hasAnySignificantNeighborUnsafe(
                                                x: x, y: y, states: statePtr)
                                        // magRef1=14, magRef2noSig=15, magRef2sig=16
                                        let magCtxIdx = isFirstRefinement ? (hasSignificantNeighbors ? 15 : 14) : 16
                                        bitValue = decoder.decode(context: &ctxPtr[magCtxIdx])
                                    }

                                    if bitValue {
                                        magPtr[idx] = magPtr[idx] | bitMask
                                    }
                                    halfPtr[idx] = halfBitMask

                                    // Set codedThisPass (0x02) and refinementVisited (0x08) in one write.
                                    statePtr[idx] = CoefficientState(rawValue: stRaw | 0x0A)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func decodeMagnitudeRefinementPassBypass(
        magnitudes: inout [UInt32],
        states: inout [CoefficientState],
        halfBits: inout [UInt32],
        bitMask: UInt32,
        halfBitMask: UInt32,
        bypassDecoder: inout RawBypassDecoder
    ) {
        let stripeHeight = 4
        let w = width
        let h = height
        var causal = VerticallyCausalStripeMask(enabled: options.verticallyCausalContext, width: w)

        magnitudes.withUnsafeMutableBufferPointer { magBuf in
            states.withUnsafeMutableBufferPointer { stateBuf in
                halfBits.withUnsafeMutableBufferPointer { halfBuf in
                    let magPtr = magBuf.baseAddress!
                    let statePtr = stateBuf.baseAddress!
                    let halfPtr = halfBuf.baseAddress!

                    for stripeY in stride(from: 0, to: h, by: stripeHeight) {
                        let stripeEnd = min(stripeY + stripeHeight, h)
                        causal.hideRow(stripeEnd, width: w, height: h, states: statePtr)
                        defer { causal.restore(width: w, states: statePtr) }

                        for x in 0..<w {
                            for y in stripeY..<stripeEnd {
                                let idx = y &* w &+ x

                                let stRaw = statePtr[idx].rawValue
                                guard (stRaw & 0x03) == 0x01 else { continue }

                                let bitValue = bypassDecoder.decode()

                                if bitValue {
                                    magPtr[idx] = magPtr[idx] | bitMask
                                }
                                halfPtr[idx] = halfBitMask

                                statePtr[idx] = CoefficientState(rawValue: stRaw | 0x0A)  // codedThisPass | refinementVisited
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Cleanup Pass (Decode)

    /// Decodes the cleanup pass.
    private func decodeCleanupPass(
        magnitudes: inout [UInt32],
        states: inout [CoefficientState],
        halfBits: inout [UInt32],
        bitMask: UInt32,
        halfBitMask: UInt32,
        decoder: inout MQDecoder,
        contexts: inout ContextStateArray
    ) {
        let stripeHeight = 4
        let w = width
        let h = height
        var causal = VerticallyCausalStripeMask(enabled: options.verticallyCausalContext, width: w)

        magnitudes.withUnsafeMutableBufferPointer { magBuf in
            states.withUnsafeMutableBufferPointer { stateBuf in
                halfBits.withUnsafeMutableBufferPointer { halfBuf in
                    let magPtr = magBuf.baseAddress!
                    let statePtr = stateBuf.baseAddress!
                    let halfPtr = halfBuf.baseAddress!

                    contexts.withUnsafeMutableContextArray { ctxPtr in
                        for stripeY in stride(from: 0, to: h, by: stripeHeight) {
                            let stripeEnd = min(stripeY + stripeHeight, h)
                            causal.hideRow(stripeEnd, width: w, height: h, states: statePtr)
                            defer { causal.restore(width: w, states: statePtr) }

                            for x in 0..<w {
                                    let eligible = canUseRunLengthDecodingUnsafe(
                                        x: x,
                                        stripeStart: stripeY,
                                        stripeEnd: stripeEnd,
                                        states: statePtr
                                    )

                                    #if EBCOT_DEBUG_TRACE
                                    EBCOTDebugTrace.shared.logDecode("elig=\(eligible)", x: x, y: stripeY)
                                    #endif

                                    if eligible {
                                        let hasSignificant = decoder.decode(context: &ctxPtr[17]) // .runLength

                                        if !hasSignificant {
                                            // All 4 states guaranteed rawValue==0 (eligibility check), direct assign.
                                            for y in stripeY..<stripeEnd {
                                                statePtr[y &* w &+ x] = CoefficientState(rawValue: 0x02)
                                            }
                                            continue
                                        }

                                        if options.useISOPositionEncoding {
                                            let bit1 = decoder.decode(context: &ctxPtr[18]) // .uniform
                                            let bit0 = decoder.decode(context: &ctxPtr[18]) // .uniform
                                            let firstSigPos = (bit1 ? 2 : 0) + (bit0 ? 1 : 0)

                                            // States before firstSigPos: rawValue==0, direct assign.
                                            for i in 0..<firstSigPos {
                                                statePtr[(stripeY + i) &* w &+ x] = CoefficientState(rawValue: 0x02)
                                            }

                                            let firstIdx = (stripeY + firstSigPos) &* w &+ x
                                            let (firstHSign, firstVSign) = neighborCalculator.computeCardinalSignsUnsafe(
                                                x: x, y: stripeY + firstSigPos,
                                                states: statePtr
                                            )
                                            let firstEntry = ContextModeler.signContextLUT[(firstHSign + 2) * 5 + (firstVSign + 2)]
                                            let firstCodedSign = decoder.decode(context: &ctxPtr[Int(firstEntry >> 1)])
                                            let firstSignBit = firstCodedSign != ((firstEntry & 1) != 0)

                                            magPtr[firstIdx] = magPtr[firstIdx] | bitMask
                                            halfPtr[firstIdx] = halfBitMask
                                            // RLC eligibility guarantees state==0 for firstIdx
                                            var firstNewRaw: UInt8 = 0x03  // significant | codedThisPass
                                            if firstSignBit { firstNewRaw |= 0x04 }  // signBit
                                            statePtr[firstIdx] = CoefficientState(rawValue: firstNewRaw)

                                            // Positions > firstSigPos are still state==0 (RLC eligibility + no prior coding)
                                            for y in (stripeY + firstSigPos + 1)..<stripeEnd {
                                                let idx = y &* w &+ x

                                                // State is 0 here (proven by RLC eligibility): skip the state check.
                                                let ctxRaw = contextModeler.cleanupSigContext(
                                                    x: x, y: y, width: w, height: h, states: statePtr)
                                                let isSignificant = decoder.decode(context: &ctxPtr[Int(ctxRaw)])

                                                if isSignificant {
                                                    let (hSign, vSign) = neighborCalculator.computeCardinalSignsUnsafe(
                                                        x: x, y: y,
                                                        states: statePtr
                                                    )
                                                    let signEntry = ContextModeler.signContextLUT[(hSign + 2) * 5 + (vSign + 2)]
                                                    let codedSign = decoder.decode(context: &ctxPtr[Int(signEntry >> 1)])
                                                    let signBit = codedSign != ((signEntry & 1) != 0)

                                                    magPtr[idx] = magPtr[idx] | bitMask
                                                    halfPtr[idx] = halfBitMask
                                                    var newRaw2: UInt8 = 0x03  // significant | codedThisPass
                                                    if signBit { newRaw2 |= 0x04 }  // signBit
                                                    statePtr[idx] = CoefficientState(rawValue: newRaw2)
                                                } else {
                                                    statePtr[idx] = CoefficientState(rawValue: 0x02)  // codedThisPass
                                                }
                                            }
                                            continue
                                        }
                                    }

                                    for y in stripeY..<stripeEnd {
                                        let idx = y &* w &+ x

                                        // cleanupSigContextOrSkip folds sig/coded check via mid byte 1
                                        let ctxRaw = contextModeler.cleanupSigContextOrSkip(
                                            x: x, y: y, width: w, height: h, states: statePtr)
                                        guard ctxRaw != 0xFF else { continue }

                                        let isSignificant = decoder.decode(context: &ctxPtr[Int(ctxRaw)])

                                        if isSignificant {
                                            let (hSign, vSign) = neighborCalculator.computeCardinalSignsUnsafe(
                                                x: x, y: y,
                                                states: statePtr
                                            )
                                            let signEntry = ContextModeler.signContextLUT[(hSign + 2) * 5 + (vSign + 2)]
                                            let codedSign = decoder.decode(context: &ctxPtr[Int(signEntry >> 1)])
                                            let signBit = codedSign != ((signEntry & 1) != 0)

                                            magPtr[idx] = magPtr[idx] | bitMask
                                            halfPtr[idx] = halfBitMask
                                            // rawState is proven 0 here (sig/coded checked above)
                                            var newRaw: UInt8 = 0x03  // significant | codedThisPass
                                            if signBit { newRaw |= 0x04 }  // signBit
                                            statePtr[idx] = CoefficientState(rawValue: newRaw)
                                        } else {
                                            statePtr[idx] = CoefficientState(rawValue: 0x02)  // codedThisPass
                            }
                        }
                    }
                }
            }
                }
            }
        }
    }

    /// Run-length eligibility check using unsafe state pointer.
    @inline(__always)
    private func canUseRunLengthDecodingUnsafe(
        x: Int,
        stripeStart: Int,
        stripeEnd: Int,
        states: UnsafePointer<CoefficientState>
    ) -> Bool {
        guard stripeEnd - stripeStart == 4 else { return false }
        let w = width
        // Batch all 4 sig/coded checks in one OR — only then check neighbors.
        let i0 = stripeStart &* w &+ x
        let i1 = i0 &+ w; let i2 = i1 &+ w; let i3 = i2 &+ w
        if (states[i0].rawValue | states[i1].rawValue | states[i2].rawValue | states[i3].rawValue) & 0x03 != 0 {
            return false
        }
        // Batch 4 rows of hasAnySignificantNeighbor into 6 word loads (vs 4×3=12).
        // Same proof as encoder: sig=0 in r1..r4 byte 1 (prior check guarantees it).
        if x > 0 && x < w &- 1 && stripeStart > 0 && stripeEnd < height {
            let xm1 = x &- 1
            let rawPtr = UnsafeRawPointer(states)
            let r0 = rawPtr.loadUnaligned(fromByteOffset: (stripeStart &- 1) &* w &+ xm1, as: UInt32.self)
            let r1 = rawPtr.loadUnaligned(fromByteOffset:  stripeStart      &* w &+ xm1, as: UInt32.self)
            let r2 = rawPtr.loadUnaligned(fromByteOffset: (stripeStart &+ 1) &* w &+ xm1, as: UInt32.self)
            let r3 = rawPtr.loadUnaligned(fromByteOffset: (stripeStart &+ 2) &* w &+ xm1, as: UInt32.self)
            let r4 = rawPtr.loadUnaligned(fromByteOffset: (stripeStart &+ 3) &* w &+ xm1, as: UInt32.self)
            let r5 = rawPtr.loadUnaligned(fromByteOffset:  stripeEnd         &* w &+ xm1, as: UInt32.self)
            return (r0 | r1 | r2 | r3 | r4 | r5) & 0x00010101 == 0
        }
        // Border/partial stripe fallback
        for y in stripeStart..<stripeEnd {
            if neighborCalculator.hasAnySignificantNeighborUnsafe(x: x, y: y, states: states) {
                return false
            }
        }
        return true
    }

     /// Checks if run-length decoding can be used for a column in a stripe.
    ///
    /// This is the decoder equivalent of `isEligibleForRunLengthCoding` in the encoder.
    /// It checks eligibility based on coefficient and neighbor states.
    ///
    /// NOTE: This function must be kept in sync with BitPlaneCoder.isEligibleForRunLengthCoding
    private func canUseRunLengthDecoding(
        x: Int,
        stripeStart: Int,
        stripeEnd: Int,
        states: [CoefficientState]
    ) -> Bool {
        // This must match isEligibleForRunLengthCoding in the encoder
        // RLC only applies to full 4-row stripes per ISO 15444-1 D.3.7
        guard stripeEnd - stripeStart == 4 else { return false }

        for y in stripeStart..<stripeEnd {
            let idx = y * width + x

            // Can't use RLC if any coefficient is already significant or coded
            if states[idx].contains(.significant) || states[idx].contains(.codedThisPass) {
                return false
            }

            // Can't use RLC if any neighbor is significant
            let neighbors = neighborCalculator.calculate(x: x, y: y, states: states)
            if neighbors.hasAny {
                return false
            }
        }

        return true
    }
}

// MARK: - Code-Block Encoder

/// Encodes a complete code-block using EBCOT.
///
/// This is a high-level wrapper around the bit-plane coder that handles
/// the complete encoding of a JPEG 2000 code-block.
struct CodeBlockEncoder: Sendable {
    /// The maximum code-block width.
    static let maxWidth = 64

    /// The maximum code-block height.
    static let maxHeight = 64

    /// The default code-block width.
    static let defaultWidth = 64

    /// The default code-block height.
    static let defaultHeight = 64

    /// Encodes a code-block with default options.
    ///
    /// - Parameters:
    ///   - coefficients: The wavelet coefficients in the code-block.
    ///   - width: The width of the code-block.
    ///   - height: The height of the code-block.
    ///   - subband: The subband type.
    ///   - bitDepth: The bit depth of the coefficients.
    ///   - maxPasses: Maximum coding passes (optional).
    ///   - scratch: Pre-allocated scratch buffers for reuse (optional).
    /// - Returns: The encoded code-block data with metadata.
    /// - Throws: ``J2KError`` if encoding fails.
    func encode(
        coefficients: [Int32],
        width: Int,
        height: Int,
        subband: J2KSubband,
        bitDepth: Int,
        coefficientCount: Int? = nil,
        maxPasses: Int? = nil,
        scratch: EBCOTScratchBuffers? = nil,
        collectRateControlMetrics: Bool = true
    ) throws -> J2KCodeBlock {
        try encode(
            coefficients: coefficients,
            width: width,
            height: height,
            subband: subband,
            bitDepth: bitDepth,
            options: .default,
            coefficientCount: coefficientCount,
            maxPasses: maxPasses,
            scratch: scratch,
            collectRateControlMetrics: collectRateControlMetrics
        )
    }

    /// Encodes a code-block with custom coding options.
    ///
    /// - Parameters:
    ///   - coefficients: The wavelet coefficients in the code-block.
    ///   - width: The width of the code-block.
    ///   - height: The height of the code-block.
    ///   - subband: The subband type.
    ///   - bitDepth: The bit depth of the coefficients.
    ///   - options: Coding options (bypass mode, termination, etc.).
    ///   - maxPasses: Maximum coding passes (optional).
    ///   - scratch: Pre-allocated scratch buffers for reuse (optional).
    /// - Returns: The encoded code-block data with metadata.
    /// - Throws: ``J2KError`` if encoding fails.
    func encode(
        coefficients: [Int32],
        width: Int,
        height: Int,
        subband: J2KSubband,
        bitDepth: Int,
        options: CodingOptions,
        coefficientCount: Int? = nil,
        maxPasses: Int? = nil,
        scratch: EBCOTScratchBuffers? = nil,
        collectRateControlMetrics: Bool = true,
        precomputedAnalysis: (maxMagnitude: UInt32, squaredSum: Double, bitPlanePopulation: [Int])? = nil
    ) throws -> J2KCodeBlock {
        let coder = BitPlaneCoder(width: width, height: height, subband: subband, options: options)
        let (data, passCount, zeroBitPlanes, passSegmentLengths, cumulativePassBytes, cumulativePassDistortion, coefficientSquaredSum, bitPlanePopulation, perPassSnapshotData, mqCheckpoints, rawMQOutput) = try coder.encodeDetailed(
            coefficients: coefficients,
            bitDepth: bitDepth,
            coefficientCount: coefficientCount,
            maxPasses: maxPasses,
            scratch: scratch,
            collectRateControlMetrics: collectRateControlMetrics,
            precomputedAnalysis: precomputedAnalysis
        )

        return J2KCodeBlock(
            index: 0,
            x: 0,
            y: 0,
            width: width,
            height: height,
            subband: subband,
            data: data,
            passeCount: passCount,
            zeroBitPlanes: zeroBitPlanes,
            passSegmentLengths: passSegmentLengths,
            cumulativePassBytes: cumulativePassBytes,
            coefficientSquaredSum: coefficientSquaredSum,
            bitPlanePopulation: bitPlanePopulation,
            cumulativePassDistortion: cumulativePassDistortion,
            perPassSnapshotData: perPassSnapshotData,
            mqCheckpoints: mqCheckpoints,
            rawMQOutput: rawMQOutput
        )
    }
}

// MARK: - Code-Block Decoder

/// Decodes a complete code-block using EBCOT.
///
/// This is a high-level wrapper around the bit-plane decoder that handles
/// the complete decoding of a JPEG 2000 code-block.
struct CodeBlockDecoder: Sendable {
    /// Decodes a code-block with default options.
    ///
    /// - Parameters:
    ///   - codeBlock: The encoded code-block.
    ///   - bitDepth: The bit depth of the coefficients.
    /// - Returns: The decoded wavelet coefficients.
    /// - Throws: ``J2KError`` if decoding fails.
    func decode(
        codeBlock: J2KCodeBlock,
        bitDepth: Int
    ) throws -> [Int32] {
        try decode(codeBlock: codeBlock, bitDepth: bitDepth, options: .default, irreversible: false)
    }

    /// Decodes a code-block, specifying whether the transform is irreversible.
    ///
    /// - Parameters:
    ///   - codeBlock: The encoded code-block.
    ///   - bitDepth: The bit depth of the coefficients.
    ///   - irreversible: Whether this uses irreversible (9/7) transform.
    /// - Returns: The decoded wavelet coefficients.
    /// - Throws: ``J2KError`` if decoding fails.
    func decode(
        codeBlock: J2KCodeBlock,
        bitDepth: Int,
        irreversible: Bool
    ) throws -> [Int32] {
        try decode(codeBlock: codeBlock, bitDepth: bitDepth, options: .default, irreversible: irreversible)
    }

    /// Decodes a code-block with custom coding options.
    ///
    /// - Parameters:
    ///   - codeBlock: The encoded code-block.
    ///   - bitDepth: The bit depth of the coefficients.
    ///   - options: Coding options that were used during encoding.
    ///   - irreversible: Whether this uses irreversible (9/7) transform.
    /// - Returns: The decoded wavelet coefficients.
    /// - Throws: ``J2KError`` if decoding fails.
    func decode(
        codeBlock: J2KCodeBlock,
        bitDepth: Int,
        options: CodingOptions,
        irreversible: Bool = false,
        scratch: DecoderScratchBuffers? = nil
    ) throws -> [Int32] {
        let decoder = BitPlaneDecoder(
            width: codeBlock.width,
            height: codeBlock.height,
            subband: codeBlock.subband,
            options: options
        )

        return try decoder.decode(
            data: codeBlock.data,
            passCount: codeBlock.passeCount,
            bitDepth: bitDepth,
            zeroBitPlanes: codeBlock.zeroBitPlanes,
            passSegmentLengths: codeBlock.passSegmentLengths,
            irreversible: irreversible,
            scratch: scratch
        )
    }
}

// MARK: - Vertically Causal Context

/// Vertically causal context formation (ISO/IEC 15444-1 D.7, code-block style bit 3): while a stripe is coded, the
/// stripe below counts as insignificant. Hiding the first row of the next stripe gives every context function —
/// significance, sign, magnitude refinement and run-length eligibility — that view, and the row is restored before
/// the next stripe is coded.
struct VerticallyCausalStripeMask {
    private let enabled: Bool
    private var saved: [CoefficientState]
    private var hiddenRow = -1

    init(enabled: Bool, width: Int) {
        self.enabled = enabled
        saved = enabled ? [CoefficientState](repeating: [], count: width) : []
    }

    @inline(__always)
    mutating func hideRow(_ row: Int, width: Int, height: Int, states: UnsafeMutablePointer<CoefficientState>) {
        guard enabled, row < height else { return }
        let base = row &* width
        for x in 0..<width {
            saved[x] = states[base &+ x]
            states[base &+ x] = []
        }
        hiddenRow = row
    }

    @inline(__always)
    mutating func restore(width: Int, states: UnsafeMutablePointer<CoefficientState>) {
        guard hiddenRow >= 0 else { return }
        let base = hiddenRow &* width
        for x in 0..<width { states[base &+ x] = saved[x] }
        hiddenRow = -1
    }
}

// MARK: - Entropy Integrity

/// The decoder that holds a code-block's open codeword segment.
enum EntropySegmentKind {
    case none, arithmetic, raw
}

/// Declared and consumed bytes of one EBCOT code-block (#2899). The MQ decoder cannot fail: once desynchronised it
/// decodes plausible garbage, and stops short of the bytes its packet header declared or reads far past them.
/// Thresholds follow the J2KSwift calibration (commit 11ab594: 0 bytes under-read and at most 8 over-read over
/// verified-correct Kakadu, OpenJPEG, OpenJPH and Grok streams). HT code-blocks are not covered.
struct EntropyIntegrity {
    static let maximumUnderRead = 4
    static let maximumOverRead = 16

    private(set) var declaredBytes = 0
    private(set) var consumedBytes = 0
    /// The largest over-read of one segment: every terminated segment reads a few bytes of flush tail, so a sum
    /// over the one-pass segments of RESTART would grow with the pass count.
    private(set) var overReadCount = 0

    mutating func absorb(_ decoder: MQDecoder) {
        declaredBytes += decoder.segmentBytes
        consumedBytes += min(decoder.consumedBytes, decoder.segmentBytes)
        overReadCount = max(overReadCount, decoder.overReadCount)
    }

    mutating func absorb(_ decoder: RawBypassDecoder) {
        declaredBytes += decoder.segmentBytes
        consumedBytes += min(decoder.consumedBytes, decoder.segmentBytes)
    }

    var anomaly: String? {
        let underRead = declaredBytes - consumedBytes
        if underRead > Self.maximumUnderRead {
            return "a code-block left \(underRead) of \(declaredBytes) declared bytes unread"
        }
        if overReadCount > Self.maximumOverRead {
            return "a codeword segment read \(overReadCount) bytes past the \(declaredBytes) its code-block declared"
        }
        return nil
    }
}
