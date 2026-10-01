//
// J2KMCTDependency.swift
// J2KSwift
//
// J2KMCTDependency.swift
// J2KSwift
//
// Component dependency transforms for ISO/IEC 15444-2 Part 2
//

import Foundation

/// Represents a dependency relationship between image components.
///
/// Dependency transforms allow efficient decorrelation by defining relationships
/// between components (e.g., "component 1 depends on component 0").
///
/// ## Mathematical Representation
///
/// For components X₀, X₁, X₂, a dependency transform can be:
/// ```
/// Y₀ = X₀
/// Y₁ = X₁ - α·X₀
/// Y₂ = X₂ - β·X₀ - γ·X₁
/// ```
///
/// This creates a hierarchical decorrelation chain where each component
/// is predicted from its predecessors.
public struct J2KComponentDependency: Sendable, Equatable {
    /// The index of the output (dependent) component.
    public let outputComponent: Int

    /// The input components this depends on (index, weight pairs).
    ///
    /// For example: `[(0, 0.5), (1, 0.3)]` means:
    /// `output = input - 0.5*component[0] - 0.3*component[1]`
    public let dependencies: [(component: Int, weight: Double)]

    /// Creates a new component dependency.
    ///
    /// - Parameters:
    ///   - outputComponent: The index of the dependent component.
    ///   - dependencies: The input components and their weights.
    public init(outputComponent: Int, dependencies: [(component: Int, weight: Double)]) {
        self.outputComponent = outputComponent
        self.dependencies = dependencies
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.outputComponent == rhs.outputComponent &&
            lhs.dependencies.elementsEqual(rhs.dependencies) {
                $0.component == $1.component && $0.weight == $1.weight
            }
    }
}

/// A chain of component dependencies forming a dependency graph.
///
/// The dependency graph defines the order and relationships for
/// transforming multiple components hierarchically.
///
/// ## Example
///
/// ```swift
/// // Create a simple decorrelation chain for RGB
/// let chain = J2KDependencyChain(
///     componentCount: 3,
///     dependencies: [
///         J2KComponentDependency(
///             outputComponent: 1,
///             dependencies: [(0, 0.5)]  // G' = G - 0.5*R
///         ),
///         J2KComponentDependency(
///             outputComponent: 2,
///             dependencies: [(0, 0.5), (1, 0.5)]  // B' = B - 0.5*R - 0.5*G'
///         )
///     ]
/// )
/// ```
public struct J2KDependencyChain: Sendable, Equatable {
    /// Total number of components.
    public let componentCount: Int

    /// The dependency relationships in evaluation order.
    public let dependencies: [J2KComponentDependency]

    /// Creates a new dependency chain.
    ///
    /// - Parameters:
    ///   - componentCount: Total number of components.
    ///   - dependencies: The dependency relationships.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if the chain is invalid.
    public init(componentCount: Int, dependencies: [J2KComponentDependency]) throws {
        guard componentCount > 0 else {
            throw J2KError.invalidParameter("Component count must be positive")
        }

        // Validate dependencies
        for dep in dependencies {
            guard dep.outputComponent >= 0 && dep.outputComponent < componentCount else {
                throw J2KError.invalidParameter(
                    "Output component \(dep.outputComponent) out of range [0, \(componentCount))"
                )
            }

            for (inputIdx, _) in dep.dependencies {
                guard inputIdx >= 0 && inputIdx < componentCount else {
                    throw J2KError.invalidParameter(
                        "Input component \(inputIdx) out of range [0, \(componentCount))"
                    )
                }

                // Ensure no circular dependencies (input must be evaluated before output)
                guard inputIdx < dep.outputComponent else {
                    throw J2KError.invalidParameter(
                        "Circular dependency: component \(inputIdx) cannot depend on component \(dep.outputComponent)"
                    )
                }
            }
        }

        self.componentCount = componentCount
        self.dependencies = dependencies
    }
}

/// Hierarchical component transform using multiple stages.
///
/// Allows complex multi-stage transforms where components are processed
/// in groups, with later groups depending on earlier groups.
public struct J2KHierarchicalTransform: Sendable, Equatable {
    /// The transform stages in order.
    ///
    /// Each stage is a dependency chain that operates on a subset of components.
    public let stages: [J2KDependencyChain]

    /// Total number of components across all stages.
    public let totalComponents: Int

    /// Creates a new hierarchical transform.
    ///
    /// - Parameters:
    ///   - stages: The transform stages in evaluation order.
    ///   - totalComponents: Total number of components.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if the configuration is invalid.
    public init(stages: [J2KDependencyChain], totalComponents: Int) throws {
        guard !stages.isEmpty else {
            throw J2KError.invalidParameter("Must have at least one stage")
        }

        self.stages = stages
        self.totalComponents = totalComponents
    }
}

/// Performs component dependency transforms for JPEG 2000 Part 2.
///
/// Dependency transforms provide an efficient way to decorrelate components
/// using hierarchical prediction relationships rather than full matrix transforms.
///
/// ## Performance
///
/// Dependency transforms are typically more efficient than array-based MCT for:
/// - Large numbers of components (>4)
/// - Sparse decorrelation patterns
/// - Low-latency streaming applications
///
/// ## Example Usage
///
/// ```swift
/// let transformer = J2KMCTDependencyTransform()
///
/// // Define a simple 3-component dependency chain
/// let chain = try J2KDependencyChain(
///     componentCount: 3,
///     dependencies: [
///         J2KComponentDependency(outputComponent: 1, dependencies: [(0, 0.5)]),
///         J2KComponentDependency(outputComponent: 2, dependencies: [(0, 0.25), (1, 0.25)])
///     ]
/// )
///
/// // Apply forward transform
/// let transformed = try transformer.forwardTransform(
///     components: inputComponents,
///     chain: chain
/// )
/// ```
public struct J2KMCTDependencyTransform: Sendable {
    /// Creates a new dependency transform.
    public init() {}

    // MARK: - Forward Transform

    /// Applies a forward dependency transform.
    ///
    /// Transforms components according to the dependency chain:
    /// Each component is decorrelated from its predecessors.
    ///
    /// - Parameters:
    ///   - components: The input component data arrays.
    ///   - chain: The dependency chain defining the transform.
    /// - Returns: The transformed component data arrays.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if inputs are invalid.
    public func forwardTransform(
        components: [[Double]],
        chain: J2KDependencyChain
    ) throws -> [[Double]] {
        guard components.count == chain.componentCount else {
            throw J2KError.invalidParameter(
                "Component count (\(components.count)) must match chain component count (\(chain.componentCount))"
            )
        }

        guard !components.isEmpty else {
            throw J2KError.invalidParameter("Components cannot be empty")
        }

        let sampleCount = components[0].count
        guard components.allSatisfy({ $0.count == sampleCount }) else {
            throw J2KError.invalidParameter("All components must have the same sample count")
        }

        // Initialise output with input (identity for non-dependent components)
        var output = components

        // Apply each dependency in order
        for dependency in chain.dependencies {
            let outputIdx = dependency.outputComponent

            // Start with original component values
            var transformedValues = components[outputIdx]

            // Subtract weighted predictions from dependent components
            for (inputIdx, weight) in dependency.dependencies {
                let inputValues = output[inputIdx]
                for i in 0..<sampleCount {
                    transformedValues[i] -= weight * inputValues[i]
                }
            }

            output[outputIdx] = transformedValues
        }

        return output
    }

    // MARK: - Inverse Transform

    /// Applies an inverse dependency transform.
    ///
    /// Reconstructs original components from dependency-transformed data.
    ///
    /// - Parameters:
    ///   - components: The transformed component data arrays.
    ///   - chain: The dependency chain used for the forward transform.
    /// - Returns: The reconstructed component data arrays.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if inputs are invalid.
    public func inverseTransform(
        components: [[Double]],
        chain: J2KDependencyChain
    ) throws -> [[Double]] {
        guard components.count == chain.componentCount else {
            throw J2KError.invalidParameter(
                "Component count (\(components.count)) must match chain component count (\(chain.componentCount))"
            )
        }

        guard !components.isEmpty else {
            throw J2KError.invalidParameter("Components cannot be empty")
        }

        let sampleCount = components[0].count
        guard components.allSatisfy({ $0.count == sampleCount }) else {
            throw J2KError.invalidParameter("All components must have the same sample count")
        }

        // Initialise output with input
        var output = components

        // Apply dependencies in order (forward through the chain)
        // Inverse is additive reconstruction, but uses the transformed (input) values for dependencies
        for dependency in chain.dependencies {
            let outputIdx = dependency.outputComponent

            // Start with transformed values from output (accumulated state)
            var reconstructedValues = output[outputIdx]

            // Add back weighted predictions from dependent components
            // IMPORTANT: Use the original transformed (input) values, not accumulated reconstructions
            for (inputIdx, weight) in dependency.dependencies {
                let inputValues = components[inputIdx]  // Use original transformed values!
                for i in 0..<sampleCount {
                    reconstructedValues[i] += weight * inputValues[i]
                }
            }

            output[outputIdx] = reconstructedValues
        }

        return output
    }

    // MARK: - Hierarchical Transform

    /// Applies a forward hierarchical transform with multiple stages.
    ///
    /// - Parameters:
    ///   - components: The input component data arrays.
    ///   - transform: The hierarchical transform definition.
    /// - Returns: The transformed component data arrays.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if inputs are invalid.
    public func forwardHierarchicalTransform(
        components: [[Double]],
        transform: J2KHierarchicalTransform
    ) throws -> [[Double]] {
        var output = components

        // Apply each stage in order
        for stage in transform.stages {
            output = try forwardTransform(components: output, chain: stage)
        }

        return output
    }

    /// Applies an inverse hierarchical transform with multiple stages.
    ///
    /// - Parameters:
    ///   - components: The transformed component data arrays.
    ///   - transform: The hierarchical transform definition.
    /// - Returns: The reconstructed component data arrays.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if inputs are invalid.
    public func inverseHierarchicalTransform(
        components: [[Double]],
        transform: J2KHierarchicalTransform
    ) throws -> [[Double]] {
        var output = components

        // Apply stages in reverse order for inverse
        for stage in transform.stages.reversed() {
            output = try inverseTransform(components: output, chain: stage)
        }

        return output
    }
}

// MARK: - Predefined Dependency Chains

extension J2KDependencyChain {
    /// RGB decorrelation using dependency transform.
    ///
    /// Equivalent to:
    /// - Y₀ = R
    /// - Y₁ = G - 0.5·R
    /// - Y₂ = B - 0.5·R - 0.5·(G - 0.5·R)
    public static let rgbDecorrelation = try! J2KDependencyChain(
        componentCount: 3,
        dependencies: [
            J2KComponentDependency(
                outputComponent: 1,
                dependencies: [(0, 0.5)]
            ),
            J2KComponentDependency(
                outputComponent: 2,
                dependencies: [(0, 0.5), (1, 0.5)]
            )
        ]
    )

    /// Simple averaging decorrelation for 4 components.
    ///
    /// Each component is decorrelated from the immediately previous component only:
    /// - Y₀ = C₀
    /// - Y₁ = C₁ - 0.5·Y₀
    /// - Y₂ = C₂ - 0.5·Y₁
    /// - Y₃ = C₃ - 0.5·Y₂
    public static let averaging4 = try! J2KDependencyChain(
        componentCount: 4,
        dependencies: [
            J2KComponentDependency(
                outputComponent: 1,
                dependencies: [(0, 0.5)]
            ),
            J2KComponentDependency(
                outputComponent: 2,
                dependencies: [(1, 0.5)]
            ),
            J2KComponentDependency(
                outputComponent: 3,
                dependencies: [(2, 0.5)]
            )
        ]
    )
}

/// Configuration for dependency-based MCT.
public struct J2KMCTDependencyConfiguration: Sendable, Equatable {
    /// The dependency chain or hierarchical transform to use.
    public enum TransformType: Sendable, Equatable {
        /// Single-stage dependency chain
        case chain(J2KDependencyChain)

        /// Multi-stage hierarchical transform
        case hierarchical(J2KHierarchicalTransform)
    }

    /// The transform type.
    public let transform: TransformType

    /// Whether to optimise dependency graph evaluation order.
    public let optimizeEvaluation: Bool

    /// Creates a new dependency configuration.
    ///
    /// - Parameters:
    ///   - transform: The transform type.
    ///   - optimizeEvaluation: Whether to optimise evaluation order (default: true).
    public init(transform: TransformType, optimizeEvaluation: Bool = true) {
        self.transform = transform
        self.optimizeEvaluation = optimizeEvaluation
    }
}
