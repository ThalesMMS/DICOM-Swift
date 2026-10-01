import Foundation

/// Manifest of clinical-path workloads: stages, modes, budgets, external collectors, Voxelia registry and promotion profiles.
public struct ClinicalPathWorkloadManifest: Codable, Equatable, Sendable {
    public struct Workload: Codable, Equatable, Sendable {
        public var id: String
        public var stage: String
        public var fixtureID: String
        public var description: String
        public var modes: [ClinicalPathMode]
        public var warmupIterations: Int
        public var iterations: Int
        public var correctness: String
        public var budget: ClinicalPathBudget?
        public var requires: [String]
        public var collector: String
    }
    public struct Fixture: Codable, Equatable, Sendable {
        public var id: String
        public var generator: String
        public var geometry: String
        public var format: String
        public var parameters: [String: String]
        public var sha256: String
    }
    public struct VoxeliaWorkload: Codable, Equatable, Sendable {
        public var id: String
        public var childIssue: Int
        public var status: String
        public var tolerance: String
        public var collector: String?
        public var note: String
    }
    public var version: Int
    public var issue: Int
    public var policy: String
    public var stages: [String]
    public var modes: [ClinicalPathMode]
    public var fixtures: [Fixture]
    public var workloads: [Workload]
    public var externalCollectors: [ClinicalPathExternalCollector]
    public var voxeliaWorkloads: [VoxeliaWorkload]
    public var noisePolicy: ClinicalPathNoisePolicy
    public var promotionProfiles: [ClinicalPathPromotionProfile]
    /// Release budgets are multiplied by this factor when the collector runs a debug build.
    public var debugBudgetMultiplier: Double

    public static var repositoryURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DicomCoreTests/Resources/ReleaseGates/ClinicalPathWorkloadManifest.json")
    }

    public static func load(url: URL = repositoryURL) throws -> (manifest: Self, sha256: String) {
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        for workload in manifest.workloads {
            guard workload.iterations > 0, workload.warmupIterations >= 0 else {
                throw ClinicalPathError.invalidIterations(workload.id)
            }
        }
        return (manifest, ClinicalPathMeasurer.sha256(data))
    }

    public func profile(_ id: String) throws -> ClinicalPathPromotionProfile {
        guard let profile = promotionProfiles.first(where: { $0.id == id }) else { throw ClinicalPathError.unknownProfile(id) }
        return profile
    }

    public func fixture(_ id: String) -> Fixture? { fixtures.first { $0.id == id } }

    /// Budget for the running build configuration; debug builds scale the release budget and never compare with release runs.
    public func budget(for workload: Workload, buildConfiguration: String) -> ClinicalPathBudget? {
        guard var budget = workload.budget else { return nil }
        if buildConfiguration == "debug" {
            budget.warningSeconds *= debugBudgetMultiplier
            budget.failureSeconds *= debugBudgetMultiplier
        }
        return budget
    }
    public func requirements(for collector: String) -> [ClinicalPathRequirement] {
        workloads.filter { $0.collector == collector && $0.requires.isEmpty }.map { ClinicalPathRequirement(workloadID: $0.id, modes: $0.modes) }
    }
}
