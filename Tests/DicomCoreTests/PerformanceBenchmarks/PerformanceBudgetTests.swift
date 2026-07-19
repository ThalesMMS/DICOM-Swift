//
//  PerformanceBudgetTests.swift
//  DicomCore
//
//  Tests for the clinical performance budget manifest and gate logic.
//

import XCTest
@testable import DicomCore

final class PerformanceBudgetTests: XCTestCase {
    func testManifestCoversIssue1436ModesTiersStagesAndBuildConfigurations() throws {
        let manifest = try PerformanceBudgetManifestLoader.loadRepositoryManifest()

        XCTAssertEqual(manifest.version, 2)
        XCTAssertEqual(manifest.issue, 1436)
        XCTAssertEqual(manifest.conformanceManifest, "ClinicalCodecConformanceManifest.json")
        XCTAssertTrue(manifest.privacyPolicy.contains("never patient metadata or pixel payloads"))
        XCTAssertEqual(Set(manifest.requiredStages), Set(PerformanceBudgetStage.allCases))
        XCTAssertEqual(Set(manifest.buildConfigurations), Set(PerformanceBudgetBuildConfiguration.allCases))
        XCTAssertEqual(Set(manifest.benchmarkModes), Set(ClinicalPerformanceBenchmarkMode.allCases))
        XCTAssertEqual(Set(manifest.tiers.map(\.id)), Set(ClinicalPerformanceTier.allCases))
        XCTAssertEqual(Set(manifest.reportFormats), ["json", "csv", "markdown"])
        XCTAssertGreaterThan(manifest.warningRatio, 0)
        XCTAssertLessThan(manifest.warningRatio, 1)
        XCTAssertGreaterThan(manifest.comparisonProfile.relativeWarningPercent, 0)
        XCTAssertGreaterThan(manifest.comparisonProfile.relativeFailurePercent,
                             manifest.comparisonProfile.relativeWarningPercent)

        let allBudgetStages = Set(manifest.scenarios.flatMap { scenario in
            scenario.budgets.map(\.stage)
        })
        for stage in manifest.requiredStages {
            XCTAssertTrue(allBudgetStages.contains(stage), "Missing budget for \(stage.rawValue)")
        }

        let requiredEnvironmentFields: Set<String> = [
            "deviceName",
            "osVersion",
            "architecture",
            "modelIdentifier",
            "buildConfiguration",
            "benchmarkMode",
            "fixtureID",
            "tier",
            "commandLineStartupIncluded"
        ]
        XCTAssertEqual(Set(manifest.comparisonProfile.requiredResultEnvironmentFields),
                       requiredEnvironmentFields)
    }

    func testManifestUsesConformanceFixturesAndDeclaresCollectors() throws {
        let manifest = try PerformanceBudgetManifestLoader.loadRepositoryManifest()

        XCTAssertFalse(manifest.scenarios.isEmpty)
        for scenario in manifest.scenarios {
            XCTAssertFalse(scenario.id.isEmpty)
            XCTAssertFalse(scenario.component.isEmpty)
            XCTAssertFalse(scenario.fixtureID.isEmpty)
            XCTAssertTrue(scenario.fixtureIDs.contains(scenario.fixtureID), scenario.id)
            XCTAssertFalse(scenario.conformanceCaseIDs.isEmpty, scenario.id)
            XCTAssertTrue(scenario.fixturePolicy.contains("local"), scenario.id)
            XCTAssertLessThanOrEqual(scenario.datasetSize.voxelCount, 512 * 512 * 64, scenario.id)
            XCTAssertGreaterThan(scenario.datasetSize.bytesPerVoxel, 0, scenario.id)
            XCTAssertFalse(scenario.benchmarkModes.isEmpty, scenario.id)
            XCTAssertFalse(scenario.tiers.isEmpty, scenario.id)
            XCTAssertFalse(scenario.backends.isEmpty, scenario.id)
            XCTAssertGreaterThanOrEqual(scenario.warmupIterations, 0, scenario.id)
            XCTAssertGreaterThan(scenario.benchmarkIterations, 0, scenario.id)
            XCTAssertFalse(scenario.benchmarkCommand.isEmpty, scenario.id)
            XCTAssertFalse(scenario.correctnessGate.isEmpty, scenario.id)
            XCTAssertFalse(scenario.workflowMetrics.isEmpty, scenario.id)

            for budget in scenario.budgets {
                XCTAssertGreaterThan(budget.releaseLimit, 0, "\(scenario.id) \(budget.stage.rawValue)")
                XCTAssertGreaterThanOrEqual(budget.debugLimit,
                                            budget.releaseLimit,
                                            "\(scenario.id) \(budget.stage.rawValue)")
            }
        }

        let allMetrics = Set(manifest.scenarios.flatMap(\.workflowMetrics))
        for metric in manifest.requiredWorkflowMetrics {
            XCTAssertTrue(allMetrics.contains(metric), "Missing workflow metric \(metric)")
        }

        let backendPairs = manifest.scenarios.flatMap(\.backends)
        XCTAssertTrue(backendPairs.contains("j2kswift-cpu"))
        XCTAssertTrue(backendPairs.contains("openjpeg"))
        XCTAssertTrue(backendPairs.contains("jlswift-cpu"))
        XCTAssertTrue(backendPairs.contains("charls"))
        XCTAssertTrue(backendPairs.contains("vdsp-cpu"))
        XCTAssertTrue(backendPairs.contains("metal"))
    }

    func testBudgetEvaluatorMakesWarningsAndFailuresVisible() throws {
        let manifest = try PerformanceBudgetManifestLoader.loadRepositoryManifest()
        let budget = try XCTUnwrap(manifest.budget(stage: .decode,
                                                   metric: .meanTimeMilliseconds,
                                                   scenarioID: "dicom-j2k-codec-clinical"))
        let limit = budget.limit(for: .release)

        let passing = PerformanceBudgetSample(scenarioID: "dicom-j2k-codec-clinical",
                                              stage: .decode,
                                              metric: .meanTimeMilliseconds,
                                              buildConfiguration: .release,
                                              value: limit * 0.5)
        let warning = PerformanceBudgetSample(scenarioID: "dicom-j2k-codec-clinical",
                                              stage: .decode,
                                              metric: .meanTimeMilliseconds,
                                              buildConfiguration: .release,
                                              value: limit * 0.95)
        let failure = PerformanceBudgetSample(scenarioID: "dicom-j2k-codec-clinical",
                                              stage: .decode,
                                              metric: .meanTimeMilliseconds,
                                              buildConfiguration: .release,
                                              value: limit + 1)

        let passingEvaluation = try XCTUnwrap(PerformanceBudgetEvaluator.evaluate(passing, manifest: manifest))
        let warningEvaluation = try XCTUnwrap(PerformanceBudgetEvaluator.evaluate(warning, manifest: manifest))
        let failureEvaluation = try XCTUnwrap(PerformanceBudgetEvaluator.evaluate(failure, manifest: manifest))

        XCTAssertEqual(passingEvaluation.status, .pass)
        XCTAssertFalse(passingEvaluation.isVisibleRegression)
        XCTAssertEqual(warningEvaluation.status, .warning)
        XCTAssertTrue(warningEvaluation.isVisibleRegression)
        XCTAssertEqual(failureEvaluation.status, .failure)
        XCTAssertTrue(failureEvaluation.isVisibleRegression)
        XCTAssertEqual(failureEvaluation.limit, limit)
    }

    func testBenchmarkResultAndReporterRecordMemoryAndBuildConfiguration() throws {
        let result = try BenchmarkResult(timings: [0.010, 0.012, 0.011],
                                         peakMemoryBytes: 64 * 1024 * 1024)
        let summary = result.summary()
        XCTAssertTrue(summary.contains("Peak Memory"))
        XCTAssertTrue(summary.contains("64.00 MiB"))

        let suiteResult = BenchmarkSuiteResult(results: [.decoderInit: result],
                                               config: BenchmarkConfig(benchmarkIterations: 3))
        let reporter = BenchmarkReporter(suiteResult: suiteResult)
        let json = try reporter.generateJSON()
        let markdown = reporter.generateMarkdown()

        XCTAssertTrue(json.contains("peakMemoryBytes"))
        XCTAssertTrue(json.contains("buildConfiguration"))
        XCTAssertTrue(json.contains("physicalMemoryBytes"))
        XCTAssertTrue(markdown.contains("Peak Memory"))
        XCTAssertTrue(markdown.contains("Build Configuration"))
    }
}
