//
//  PerformanceBudget.swift
//  DicomCore
//
//  Cross-component clinical performance budget manifest support.
//

import Foundation

enum PerformanceBudgetStage: String, CaseIterable, Codable {
    case decode
    case gpuUpload
    case progressiveFrame
    case snapshot
    case peakMemory
}

enum PerformanceBudgetMetric: String, Codable {
    case meanTimeMilliseconds
    case p95TimeMilliseconds
    case peakMemoryMegabytes
}

enum PerformanceBudgetBuildConfiguration: String, CaseIterable, Codable {
    case debug
    case release
}

enum PerformanceBudgetStatus: String, Equatable {
    case pass
    case warning
    case failure
}

struct PerformanceBudgetComparisonProfile: Codable {
    let referenceDeviceClass: String
    let comparisonRule: String
    let relativeWarningPercent: Double
    let relativeFailurePercent: Double
    let requiredResultEnvironmentFields: [String]
}

struct PerformanceBudgetTier: Codable {
    let id: ClinicalPerformanceTier
    let purpose: String
    let hostPolicy: String
}

struct PerformanceBudgetDatasetSize: Codable {
    let rows: Int
    let columns: Int
    let frames: Int
    let bytesPerVoxel: Int

    var voxelCount: Int {
        rows * columns * frames
    }
}

struct PerformanceBudgetEntry: Codable {
    let stage: PerformanceBudgetStage
    let metric: PerformanceBudgetMetric
    let releaseLimit: Double
    let debugLimit: Double

    func limit(for buildConfiguration: PerformanceBudgetBuildConfiguration) -> Double {
        switch buildConfiguration {
        case .debug:
            return debugLimit
        case .release:
            return releaseLimit
        }
    }
}

struct PerformanceBudgetScenario: Codable {
    let id: String
    let component: String
    let fixtureID: String
    let fixtureIDs: [String]
    let conformanceCaseIDs: [String]
    let fixturePolicy: String
    let benchmarkMode: String
    let benchmarkModes: [ClinicalPerformanceBenchmarkMode]
    let tiers: [ClinicalPerformanceTier]
    let backends: [String]
    let datasetSize: PerformanceBudgetDatasetSize
    let warmupIterations: Int
    let benchmarkIterations: Int
    let benchmarkCommand: String
    let correctnessGate: String
    let workflowMetrics: [String]
    let budgets: [PerformanceBudgetEntry]
}

struct PerformanceBudgetManifest: Codable {
    let version: Int
    let issue: Int
    let conformanceManifest: String
    let privacyPolicy: String
    let requiredStages: [PerformanceBudgetStage]
    let requiredWorkflowMetrics: [String]
    let benchmarkModes: [ClinicalPerformanceBenchmarkMode]
    let tiers: [PerformanceBudgetTier]
    let reportFormats: [String]
    let buildConfigurations: [PerformanceBudgetBuildConfiguration]
    let warningRatio: Double
    let comparisonProfile: PerformanceBudgetComparisonProfile
    let scenarios: [PerformanceBudgetScenario]

    func budget(stage: PerformanceBudgetStage,
                metric: PerformanceBudgetMetric,
                scenarioID: String) -> PerformanceBudgetEntry? {
        scenarios
            .first { $0.id == scenarioID }?
            .budgets
            .first { $0.stage == stage && $0.metric == metric }
    }
}

struct PerformanceBudgetSample: Equatable {
    let scenarioID: String
    let stage: PerformanceBudgetStage
    let metric: PerformanceBudgetMetric
    let buildConfiguration: PerformanceBudgetBuildConfiguration
    let value: Double
}

struct PerformanceBudgetEvaluation: Equatable {
    let sample: PerformanceBudgetSample
    let limit: Double
    let warningLimit: Double
    let status: PerformanceBudgetStatus

    var isVisibleRegression: Bool {
        status != .pass
    }
}

enum PerformanceBudgetEvaluator {
    static func evaluate(_ sample: PerformanceBudgetSample,
                         manifest: PerformanceBudgetManifest) -> PerformanceBudgetEvaluation? {
        guard let budget = manifest.budget(stage: sample.stage,
                                           metric: sample.metric,
                                           scenarioID: sample.scenarioID) else {
            return nil
        }

        let limit = budget.limit(for: sample.buildConfiguration)
        let warningLimit = limit * manifest.warningRatio
        let status: PerformanceBudgetStatus
        if sample.value > limit {
            status = .failure
        } else if sample.value >= warningLimit {
            status = .warning
        } else {
            status = .pass
        }

        return PerformanceBudgetEvaluation(sample: sample,
                                           limit: limit,
                                           warningLimit: warningLimit,
                                           status: status)
    }
}

enum PerformanceBudgetManifestLoader {
    static func loadRepositoryManifest(callerFile: String = #filePath) throws -> PerformanceBudgetManifest {
        let manifestURL = try findRepositoryRoot(callerFile: callerFile)
            .appendingPathComponent("Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalPerformanceBudgetManifest.json")
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(PerformanceBudgetManifest.self, from: data)
    }

    private static func findRepositoryRoot(callerFile: String) throws -> URL {
        var directory = URL(fileURLWithPath: callerFile).deletingLastPathComponent()
        let fileManager = FileManager.default

        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("Package.swift")
            if fileManager.fileExists(atPath: candidate.path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }

        throw BenchmarkError.benchmarkFailed("Could not locate repository root from \(callerFile)")
    }
}
