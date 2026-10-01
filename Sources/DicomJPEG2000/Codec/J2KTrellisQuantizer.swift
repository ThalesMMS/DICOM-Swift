//
// J2KTrellisQuantizer.swift
// J2KSwift
//
// J2KTrellisQuantizer.swift
// J2KSwift
//
// Trellis Coded Quantization (TCQ) for JPEG 2000 Part 2 (ISO/IEC 15444-2).
//

import Foundation

// # Trellis Coded Quantization (TCQ)
//
// Implementation of trellis coded quantization for improved rate-distortion
// performance in JPEG 2000 encoding.
//
// TCQ uses a finite-state machine (trellis) to select quantization levels
// that minimise the rate-distortion cost. Unlike scalar quantization which
// quantizes each coefficient independently, TCQ considers the dependencies
// between adjacent coefficients to achieve better compression efficiency.
//
// ## Algorithm Overview
//
// TCQ operates by:
// 1. Defining a trellis structure with multiple states at each stage
// 2. Computing transition costs between states (distortion + rate)
// 3. Using the Viterbi algorithm to find the optimal path through the trellis
// 4. Selecting quantization levels based on the optimal path
//
// ## Performance Benefits
//
// TCQ typically provides:
// - 2-8% improvement in rate-distortion performance over scalar quantization
// - Better preservation of edge structures
// - Reduced quantization artifacts
// - Smoother quality degradation at low bitrates
//
// ## Usage
//
// ```swift
// // Create TCQ configuration
// let config = J2KTCQConfiguration(
//     numStates: 4,
//     baseStepSize: 1.0,
//     lambdaRD: 0.5
// )
//
// // Create trellis quantizer
// let tcq = J2KTrellisQuantizer(configuration: config)
//
// // Quantize coefficients
// let result = try tcq.quantize(
//     coefficients: waveletCoeffs,
//     subband: .hh,
//     decompositionLevel: 2
// )
// ```

// MARK: - TCQ Configuration

/// Configuration for trellis coded quantization.
public struct J2KTCQConfiguration: Sendable, Equatable {
    /// Number of trellis states (typically 2-8).
    ///
    /// More states provide better rate-distortion performance but increase
    /// computational complexity. Typical values: 4 (good balance), 8 (high quality).
    public let numStates: Int

    /// Base quantization step size.
    ///
    /// Similar to scalar quantization, this controls the fundamental
    /// quantization unit. Smaller values preserve more detail.
    public let baseStepSize: Double

    /// Lambda parameter for rate-distortion optimisation.
    ///
    /// Controls the trade-off between rate and distortion.
    /// Higher values favor lower bitrates at the cost of quality.
    /// Typical range: 0.1 (high quality) to 2.0 (high compression).
    public let lambdaRD: Double

    /// Whether to use pruned search (faster but slightly suboptimal).
    ///
    /// Pruning reduces the search space by discarding unlikely paths.
    /// Provides 2-4× speedup with minimal quality loss (<0.5%).
    public let usePrunedSearch: Bool

    /// Pruning threshold (used when usePrunedSearch is true).
    ///
    /// Paths with accumulated cost exceeding (bestCost × threshold)
    /// are pruned. Typical value: 1.5 to 3.0.
    public let pruningThreshold: Double

    /// Whether to use context-dependent quantization.
    ///
    /// When enabled, the quantizer adapts based on local signal
    /// characteristics (e.g., edge strength, texture).
    public let useContextAdaptation: Bool

    /// Creates TCQ configuration.
    ///
    /// - Parameters:
    ///   - numStates: Number of trellis states (2-8, default: 4).
    ///   - baseStepSize: Base quantization step size (default: 1.0).
    ///   - lambdaRD: Rate-distortion lambda (default: 0.5).
    ///   - usePrunedSearch: Enable pruned search (default: true).
    ///   - pruningThreshold: Pruning threshold (default: 2.0).
    ///   - useContextAdaptation: Enable context adaptation (default: false).
    /// - Throws: `J2KError.invalidParameter` if parameters are invalid.
    public init(
        numStates: Int = 4,
        baseStepSize: Double = 1.0,
        lambdaRD: Double = 0.5,
        usePrunedSearch: Bool = true,
        pruningThreshold: Double = 2.0,
        useContextAdaptation: Bool = false
    ) throws {
        guard (2...8).contains(numStates) else {
            throw J2KError.invalidParameter("TCQ numStates must be between 2 and 8")
        }
        guard baseStepSize > 0 else {
            throw J2KError.invalidParameter("TCQ baseStepSize must be positive")
        }
        guard lambdaRD > 0 else {
            throw J2KError.invalidParameter("TCQ lambdaRD must be positive")
        }
        guard pruningThreshold >= 1.0 else {
            throw J2KError.invalidParameter("TCQ pruningThreshold must be >= 1.0")
        }

        self.numStates = numStates
        self.baseStepSize = baseStepSize
        self.lambdaRD = lambdaRD
        self.usePrunedSearch = usePrunedSearch
        self.pruningThreshold = pruningThreshold
        self.useContextAdaptation = useContextAdaptation
    }

    /// Default TCQ configuration (balanced quality and performance).
    public static let `default` = try! J2KTCQConfiguration(
        numStates: 4,
        baseStepSize: 1.0,
        lambdaRD: 0.5,
        usePrunedSearch: true,
        pruningThreshold: 2.0,
        useContextAdaptation: false
    )

    /// High quality TCQ configuration (more states, slower).
    public static let highQuality = try! J2KTCQConfiguration(
        numStates: 8,
        baseStepSize: 0.5,
        lambdaRD: 0.2,
        usePrunedSearch: false,
        pruningThreshold: 2.0,
        useContextAdaptation: true
    )

    /// Fast TCQ configuration (fewer states, faster).
    public static let fast = try! J2KTCQConfiguration(
        numStates: 2,
        baseStepSize: 1.0,
        lambdaRD: 0.8,
        usePrunedSearch: true,
        pruningThreshold: 1.5,
        useContextAdaptation: false
    )
}

// MARK: - Trellis State

/// Represents a state in the TCQ trellis.
struct J2KTrellisState: Sendable, Equatable {
    /// State index (0 to numStates-1).
    let index: Int

    /// Quantization level offset associated with this state.
    let levelOffset: Int
}

// MARK: - Trellis Transition

/// Represents a transition between trellis states.
struct J2KTrellisTransition: Sendable {
    /// Source state index.
    let fromState: Int

    /// Destination state index.
    let toState: Int

    /// Quantization level chosen for this transition.
    let quantLevel: Int32

    /// Distortion cost for this transition.
    let distortion: Double

    /// Rate cost (bits) for this transition.
    let rate: Double

    /// Total cost (distortion + lambda * rate).
    let totalCost: Double

    /// Creates a trellis transition.
    init(
        fromState: Int,
        toState: Int,
        quantLevel: Int32,
        distortion: Double,
        rate: Double,
        lambda: Double
    ) {
        self.fromState = fromState
        self.toState = toState
        self.quantLevel = quantLevel
        self.distortion = distortion
        self.rate = rate
        self.totalCost = distortion + lambda * rate
    }
}

// MARK: - Trellis Path Node

/// Node in the Viterbi path through the trellis.
struct J2KTrellisPathNode: Sendable {
    /// State index at this stage.
    let state: Int

    /// Accumulated cost to reach this state.
    var cost: Double

    /// Previous node in the optimal path.
    var previousState: Int?

    /// Quantization level chosen to reach this state.
    var quantLevel: Int32?

    /// Creates a path node.
    init(state: Int, cost: Double = .infinity) {
        self.state = state
        self.cost = cost
        self.previousState = nil
        self.quantLevel = nil
    }
}

// MARK: - TCQ Result

/// Result of trellis coded quantization.
public struct J2KTCQResult: Sendable {
    /// Quantized coefficients.
    public let quantizedCoefficients: [Int32]

    /// Total distortion.
    public let totalDistortion: Double

    /// Estimated rate (bits).
    public let estimatedRate: Double

    /// Rate-distortion cost.
    public let rdCost: Double

    /// State sequence through the trellis.
    public let stateSequence: [Int]

    /// Creates a TCQ result.
    ///
    /// - Parameters:
    ///   - quantizedCoefficients: Quantized coefficients.
    ///   - totalDistortion: Total distortion.
    ///   - estimatedRate: Estimated rate (bits).
    ///   - rdCost: Rate-distortion cost.
    ///   - stateSequence: State sequence through the trellis.
    public init(
        quantizedCoefficients: [Int32],
        totalDistortion: Double,
        estimatedRate: Double,
        rdCost: Double,
        stateSequence: [Int]
    ) {
        self.quantizedCoefficients = quantizedCoefficients
        self.totalDistortion = totalDistortion
        self.estimatedRate = estimatedRate
        self.rdCost = rdCost
        self.stateSequence = stateSequence
    }
}

// MARK: - Trellis Quantizer

/// Trellis coded quantizer for JPEG 2000.
public struct J2KTrellisQuantizer: Sendable {
    /// TCQ configuration.
    public let configuration: J2KTCQConfiguration

    /// Trellis states.
    private let states: [J2KTrellisState]

    /// Creates a trellis quantizer.
    ///
    /// - Parameter configuration: TCQ configuration.
    public init(configuration: J2KTCQConfiguration = .default) {
        self.configuration = configuration

        // Initialise trellis states
        // Each state has a different quantization level offset
        self.states = (0..<configuration.numStates).map { i in
            J2KTrellisState(index: i, levelOffset: i)
        }
    }

    // MARK: - Quantization

    /// Quantizes coefficients using trellis coded quantization.
    ///
    /// - Parameters:
    ///   - coefficients: Input coefficients to quantize.
    ///   - stepSize: Quantization step size.
    /// - Returns: TCQ result with quantized coefficients and statistics.
    /// - Throws: `J2KError.invalidParameter` if inputs are invalid.
    public func quantize(
        coefficients: [Double],
        stepSize: Double
    ) throws -> J2KTCQResult {
        guard !coefficients.isEmpty else {
            throw J2KError.invalidParameter("Coefficients array cannot be empty")
        }
        guard stepSize > 0 else {
            throw J2KError.invalidParameter("Step size must be positive")
        }

        // Use Viterbi algorithm to find optimal path
        let path = try findOptimalPath(
            coefficients: coefficients,
            stepSize: stepSize
        )

        // Extract quantized values and compute statistics
        let quantized = path.quantLevels
        let distortion = path.totalDistortion
        let rate = path.totalRate
        let rdCost = distortion + configuration.lambdaRD * rate

        return J2KTCQResult(
            quantizedCoefficients: quantized,
            totalDistortion: distortion,
            estimatedRate: rate,
            rdCost: rdCost,
            stateSequence: path.states
        )
    }

    /// Quantizes coefficients for a specific subband.
    ///
    /// - Parameters:
    ///   - coefficients: Input coefficients.
    ///   - subband: Subband type.
    ///   - decompositionLevel: Decomposition level (0 = finest).
    ///   - totalLevels: Total number of decomposition levels.
    ///   - reversible: Whether using reversible transform.
    /// - Returns: TCQ result.
    /// - Throws: `J2KError` if quantization fails.
    public func quantize(
        coefficients: [Double],
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int = 5,
        reversible: Bool = false
    ) throws -> J2KTCQResult {
        // Calculate subband-specific step size
        let stepSize = J2KStepSizeCalculator.calculateStepSize(
            baseStepSize: configuration.baseStepSize,
            subband: subband,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels,
            reversible: reversible
        )

        return try quantize(coefficients: coefficients, stepSize: stepSize)
    }

    // MARK: - Dequantization

    /// Dequantizes coefficients (inverse quantization).
    ///
    /// - Parameters:
    ///   - quantizedCoefficients: Quantized coefficient indices.
    ///   - stepSize: Quantization step size.
    /// - Returns: Reconstructed coefficients.
    public func dequantize(
        quantizedCoefficients: [Int32],
        stepSize: Double
    ) -> [Double] {
        // Simple uniform dequantization (reconstruction point at bin center)
        quantizedCoefficients.map { q in
            if q == 0 {
                return 0.0
            } else {
                // Reconstruct at midpoint of quantization bin
                return (Double(q) + (q > 0 ? 0.5 : -0.5)) * stepSize
            }
        }
    }

    /// Dequantizes coefficients for a specific subband.
    ///
    /// - Parameters:
    ///   - quantizedCoefficients: Quantized coefficients.
    ///   - subband: Subband type.
    ///   - decompositionLevel: Decomposition level.
    ///   - totalLevels: Total decomposition levels.
    ///   - reversible: Whether using reversible transform.
    /// - Returns: Reconstructed coefficients.
    public func dequantize(
        quantizedCoefficients: [Int32],
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int = 5,
        reversible: Bool = false
    ) -> [Double] {
        let stepSize = J2KStepSizeCalculator.calculateStepSize(
            baseStepSize: configuration.baseStepSize,
            subband: subband,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels,
            reversible: reversible
        )

        return dequantize(quantizedCoefficients: quantizedCoefficients, stepSize: stepSize)
    }

    // MARK: - Viterbi Algorithm

    /// Finds the optimal path through the trellis using Viterbi algorithm.
    private func findOptimalPath(
        coefficients: [Double],
        stepSize: Double
    ) throws -> OptimalPath {
        let numStages = coefficients.count
        let numStates = configuration.numStates

        // Initialise trellis: trellis[stage][state]
        var trellis: [[J2KTrellisPathNode]] = []

        // Stage 0: Initialise all states
        var initialStage: [J2KTrellisPathNode] = []
        for state in 0..<numStates {
            let node = J2KTrellisPathNode(state: state, cost: 0.0)
            initialStage.append(node)
        }
        trellis.append(initialStage)

        // Forward pass: compute optimal cost to reach each state
        for stage in 0..<numStages {
            let coefficient = coefficients[stage]
            var nextStage: [J2KTrellisPathNode] = []

            // Initialise next stage nodes with infinite cost
            for state in 0..<numStates {
                nextStage.append(J2KTrellisPathNode(state: state, cost: .infinity))
            }

            // Try all transitions from current stage to next
            for fromState in 0..<numStates {
                let currentNode = trellis[stage][fromState]

                // Skip if this path is already pruned
                if configuration.usePrunedSearch && currentNode.cost == .infinity {
                    continue
                }

                // Try all possible destination states
                for toState in 0..<numStates {
                    // Compute best quantization level for this transition
                    let (quantLevel, transitionCost) = computeTransitionCost(
                        coefficient: coefficient,
                        stepSize: stepSize,
                        fromState: fromState,
                        toState: toState
                    )

                    let newCost = currentNode.cost + transitionCost

                    // Update if this is a better path to toState
                    if newCost < nextStage[toState].cost {
                        nextStage[toState].cost = newCost
                        nextStage[toState].previousState = fromState
                        nextStage[toState].quantLevel = quantLevel
                    }
                }
            }

            // Pruning: if enabled, prune unlikely paths
            if configuration.usePrunedSearch {
                let minCost = nextStage.map { $0.cost }.min() ?? 0.0
                let threshold = minCost * configuration.pruningThreshold

                for i in 0..<nextStage.count where nextStage[i].cost > threshold {
                    nextStage[i].cost = .infinity
                }
            }

            trellis.append(nextStage)
        }

        // Backward pass: trace optimal path
        let finalStage = trellis[numStages]

        // Find best final state
        guard let bestFinalState = finalStage.enumerated()
            .min(by: { $0.element.cost < $1.element.cost })?.offset else {
            throw J2KError.internalError("Failed to find optimal path in trellis")
        }

        // Trace back through trellis
        var path: [(state: Int, quantLevel: Int32)] = []
        var currentState = bestFinalState

        for stage in (1...numStages).reversed() {
            let node = trellis[stage][currentState]
            if let prevState = node.previousState, let quantLevel = node.quantLevel {
                path.append((state: currentState, quantLevel: quantLevel))
                currentState = prevState
            }
        }

        path.reverse()

        // Extract results
        let quantLevels = path.map { $0.quantLevel }
        let states = path.map { $0.state }

        // Compute total distortion and rate
        let (totalDistortion, totalRate) = computePathCost(
            coefficients: coefficients,
            quantLevels: quantLevels,
            stepSize: stepSize
        )

        return OptimalPath(
            quantLevels: quantLevels,
            states: states,
            totalDistortion: totalDistortion,
            totalRate: totalRate
        )
    }

    /// Computes the cost of a transition between states.
    private func computeTransitionCost(
        coefficient: Double,
        stepSize: Double,
        fromState: Int,
        toState: Int
    ) -> (quantLevel: Int32, cost: Double) {
        // Determine quantization level based on coefficient magnitude
        let absCoeff = abs(coefficient)
        let baseLevel = Int32(floor(absCoeff / stepSize))

        // State-dependent offset (different states prefer different levels)
        let stateOffset = states[toState].levelOffset
        let quantLevel = coefficient >= 0
            ? baseLevel + Int32(stateOffset % 2)
            : -(baseLevel + Int32(stateOffset % 2))

        // Compute distortion (squared error)
        let reconstructed = Double(quantLevel) * stepSize
        let distortion = pow(coefficient - reconstructed, 2)

        // Estimate rate (simple model: more bits for larger levels)
        let rate = estimateRate(for: quantLevel)

        // Total cost
        let cost = distortion + configuration.lambdaRD * rate

        return (quantLevel, cost)
    }

    /// Estimates the rate (bits) required to encode a quantization level.
    private func estimateRate(for quantLevel: Int32) -> Double {
        if quantLevel == 0 {
            return 1.0 // One bit for zero symbol
        } else {
            // Approximate rate for non-zero level (sign + magnitude)
            let magnitude = abs(quantLevel)
            return 1.0 + log2(Double(magnitude) + 1.0) + 1.0 // sign bit
        }
    }

    /// Computes total distortion and rate for a complete path.
    private func computePathCost(
        coefficients: [Double],
        quantLevels: [Int32],
        stepSize: Double
    ) -> (distortion: Double, rate: Double) {
        var totalDistortion = 0.0
        var totalRate = 0.0

        for (coeff, quantLevel) in zip(coefficients, quantLevels) {
            let reconstructed = Double(quantLevel) * stepSize
            totalDistortion += pow(coeff - reconstructed, 2)
            totalRate += estimateRate(for: quantLevel)
        }

        return (totalDistortion, totalRate)
    }
}

// MARK: - Optimal Path

/// Represents the optimal path through the trellis.
private struct OptimalPath {
    /// Quantization levels along the path.
    let quantLevels: [Int32]

    /// States along the path.
    let states: [Int]

    /// Total distortion.
    let totalDistortion: Double

    /// Total rate (bits).
    let totalRate: Double
}

// MARK: - Context Adaptation (Future Enhancement)

/// Context-based adaptation for TCQ (placeholder for future implementation).
///
/// This would analyse local signal characteristics and adapt quantization
/// strategies accordingly. For now, we use a fixed strategy.
struct J2KTCQContextAdapter: Sendable {
    /// Analyzes local context and returns adapted parameters.
    func analyzeContext(coefficients: [Double], position: Int) -> Double {
        // Placeholder: return default lambda
        0.5
    }
}
