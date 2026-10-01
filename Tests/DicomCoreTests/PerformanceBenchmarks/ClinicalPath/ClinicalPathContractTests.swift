import DicomTestSupport
import Foundation
import XCTest
@testable import DicomCore

/// Contract of the clinical-path harness (#2367): manifest completeness, corpus digests, missing-metric detection,
/// injected-regression detection, incompatible-host refusal, noise handling and correctness-first promotion.
final class ClinicalPathContractTests: XCTestCase {
    private func manifest() throws -> ClinicalPathWorkloadManifest { try ClinicalPathWorkloadManifest.load().manifest }

    private func environment(_ overrides: [String: String] = [:]) -> ClinicalPathEnvironment {
        ClinicalPathEnvironment(modelIdentifier: overrides["modelIdentifier"] ?? "Mac16,1", osVersion: overrides["osVersion"] ?? "26.6", architecture: "arm64", processorCount: 12,
                                physicalMemoryBytes: 64 << 30, buildConfiguration: overrides["buildConfiguration"] ?? "debug", tier: "pr-smoke", commandLineStartupIncluded: false,
                                toolkitVersion: "test", manifestSHA256: overrides["manifestSHA256"] ?? "m", corpusSHA256: overrides["corpusSHA256"] ?? "c")
    }

    private func fixture() -> ClinicalPathFixture { .init(id: "ct-512x512-16bit", source: "synthetic:xorshift-ct-v1", sha256: "abc", bytes: 1, geometry: "512x512x1", format: "CT") }

    private func result(_ id: String, mode: ClinicalPathMode = .warmSustained, seconds: [Double], correct: Bool = true) throws -> ClinicalPathWorkloadResult {
        ClinicalPathWorkloadResult(id: id, stage: "decode", mode: mode, fixture: fixture(), warmupIterations: 2, iterations: seconds.count,
                                   correctness: .exact(expected: "x", observed: correct ? "x" : "y"), statistics: try ClinicalPathStatistics(samples: seconds),
                                   budget: .init(warningSeconds: 1, failureSeconds: 2))
    }

    private func report(_ workloads: [ClinicalPathWorkloadResult], environment: ClinicalPathEnvironment? = nil) -> ClinicalPathReport {
        ClinicalPathReport(collector: "test", environment: environment ?? self.environment(), workloads: workloads)
    }

    func test_manifest_coversTheIssueStagesModesFixturesAndProfiles() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest.issue, 2367)
        for stage in ["open-metadata", "bytes-read", "decode", "normalize", "gpu-normalize", "first-frame", "final-refine", "mpr-3d", "measure", "export", "network-retrieve", "network-store", "storage", "concurrent", "mesh-metrics"] {
            XCTAssertTrue(manifest.stages.contains(stage), stage)
        }
        XCTAssertEqual(Set(manifest.modes), Set(ClinicalPathMode.allCases))
        for workload in manifest.workloads {
            XCTAssertNotNil(manifest.fixture(workload.fixtureID), "\(workload.id) references an unknown fixture")
            XCTAssertTrue(manifest.stages.contains(workload.stage), workload.id)
            XCTAssertNotNil(workload.budget, "\(workload.id) needs a budget")
            XCTAssertFalse(workload.correctness.isEmpty, workload.id)
            XCTAssertGreaterThanOrEqual(workload.iterations, manifest.noisePolicy.minimumIterationsForComparison, workload.id)
        }
        XCTAssertTrue(manifest.workloads.contains { $0.stage == "mpr-3d" } == false, "MPR/3D is measured by the MTK collector, registered as external")
        XCTAssertTrue(manifest.externalCollectors.contains { $0.stem == "mtk-clinical-performance" && $0.stages.contains("mpr-3d") })
        XCTAssertTrue(manifest.externalCollectors.contains { $0.stem == "packages-budgets" && $0.stages.contains("memory-pressure") })
        XCTAssertEqual(Set(manifest.voxeliaWorkloads.map(\.childIssue)), [2346, 2371, 2372, 2373, 2374, 2375])
        XCTAssertTrue(manifest.voxeliaWorkloads.filter { $0.status == "pending-child-issue" }.allSatisfy { $0.collector == nil }, "pending children never get an estimated collector")
        for profile in manifest.promotionProfiles {
            XCTAssertLessThan(profile.maximumRegressionPercent, profile.rollbackRegressionPercent, profile.id)
            for requirement in profile.requiredWorkloads { XCTAssertTrue(manifest.workloads.contains { $0.id == requirement.workloadID }, requirement.workloadID) }
        }
    }

    func test_syntheticCorpus_digestsArePinnedInTheManifest() async throws {
        let manifest = try manifest()
        let corpus = try await ClinicalPathSyntheticCorpus.generate()
        XCTAssertEqual(Set(corpus.objects.map(\.fixture.id)), Set(manifest.fixtures.map(\.id)))
        for object in corpus.objects {
            XCTAssertEqual(object.fixture.sha256, manifest.fixture(object.fixture.id)?.sha256, object.fixture.id)
            XCTAssertEqual(object.fixture.geometry, manifest.fixture(object.fixture.id)?.geometry)
            XCTAssertTrue(object.fixture.source.hasPrefix("synthetic:"), "no paths in fixture provenance")
        }
    }

    func test_manifest_invalidIterationCounts_areRejectedOnLoad() throws {
        var invalid = try manifest()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clinical-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        for (iterations, warmup) in [(0, 0), (-1, 0), (1, -1)] {
            invalid.workloads[0].iterations = iterations
            invalid.workloads[0].warmupIterations = warmup
            try JSONEncoder().encode(invalid).write(to: url)
            XCTAssertThrowsError(try ClinicalPathWorkloadManifest.load(url: url)) {
                XCTAssertEqual($0 as? ClinicalPathError, .invalidIterations(invalid.workloads[0].id))
            }
        }
        invalid.workloads[0].iterations = 1
        invalid.workloads[0].warmupIterations = 0
        try JSONEncoder().encode(invalid).write(to: url)
        XCTAssertEqual(try ClinicalPathWorkloadManifest.load(url: url).manifest, invalid)
    }

    func test_validator_detectsMissingAndNotExecutedMetrics() throws {
        let requirements = [ClinicalPathRequirement(workloadID: "decode-native-ct", modes: [.warmSustained, .coldSDKFirstCall])]
        let complete = report([try result("decode-native-ct", mode: .warmSustained, seconds: [0.1, 0.1]), try result("decode-native-ct", mode: .coldSDKFirstCall, seconds: [0.3])])
        XCTAssertNoThrow(try ClinicalPathReportValidator.validate(complete, requirements: requirements))
        let missing = report([try result("decode-native-ct", mode: .warmSustained, seconds: [0.1])])
        XCTAssertThrowsError(try ClinicalPathReportValidator.validate(missing, requirements: requirements)) {
            XCTAssertEqual($0 as? ClinicalPathError, .missingWorkloads(["decode-native-ct@cold-sdk-first-call"]))
        }
        let notExecuted = report([try result("decode-native-ct", mode: .warmSustained, seconds: [0.1]),
                                  .notExecuted(id: "decode-native-ct", stage: "decode", mode: .coldSDKFirstCall, reason: "no Metal device")])
        XCTAssertThrowsError(try ClinicalPathReportValidator.validate(notExecuted, requirements: requirements)) {
            XCTAssertEqual($0 as? ClinicalPathError, .missingWorkloads(["decode-native-ct@cold-sdk-first-call"]))
        }
        let entry = notExecuted.workloads[1]
        XCTAssertEqual(entry.status, .notExecuted); XCTAssertNil(entry.statistics); XCTAssertEqual(entry.verdict, .warning)
        XCTAssertTrue(notExecuted.csvString().contains("not-executed"))
        let wrong = report([try result("decode-native-ct", mode: .warmSustained, seconds: [0.1], correct: false), try result("decode-native-ct", mode: .coldSDKFirstCall, seconds: [0.3])])
        XCTAssertEqual(wrong.workloads[0].verdict, .failure)
        XCTAssertThrowsError(try ClinicalPathReportValidator.validate(wrong, requirements: requirements)) {
            XCTAssertEqual($0 as? ClinicalPathError, .correctnessFailed(["decode-native-ct"]))
        }
    }

    func test_missingCorrectness_failsValidationAndPreventsPromotion() throws {
        let requirements = [ClinicalPathRequirement(workloadID: "decode-native-ct", modes: [.warmSustained])]
        let baseline = report([try result("decode-native-ct", seconds: [0.1, 0.1, 0.1, 0.1, 0.1])])
        var unverified = try result("decode-native-ct", seconds: [0.05, 0.05, 0.05, 0.05, 0.05])
        unverified.correctness = nil
        let candidate = try ClinicalPathReport.load(report([unverified]).jsonData())
        XCTAssertThrowsError(try ClinicalPathReportValidator.validate(candidate, requirements: requirements)) {
            XCTAssertEqual($0 as? ClinicalPathError, .correctnessFailed(["decode-native-ct"]))
        }
        let profile = ClinicalPathPromotionProfile(id: "codec-default", description: "", requiredWorkloads: requirements,
                                                   maximumRegressionPercent: 10, rollbackRegressionPercent: 20, minimumIterations: 5)
        let comparison = ClinicalPathComparator.compare(baseline: baseline, candidate: candidate, profile: profile)
        XCTAssertEqual(comparison.decision, "rollback")
        XCTAssertTrue(comparison.entries.isEmpty)
    }

    func test_comparator_detectsInjectedRegressionRefusesIncompatibleHostsAndRespectsNoise() throws {
        let profile = ClinicalPathPromotionProfile(id: "codec-default", description: "", requiredWorkloads: [.init(workloadID: "decode-native-ct", modes: [.warmSustained])],
                                                   maximumRegressionPercent: 10, rollbackRegressionPercent: 20, minimumIterations: 5)
        let steady = [0.100, 0.101, 0.099, 0.100, 0.102, 0.100]
        let baseline = report([try result("decode-native-ct", seconds: steady)])
        let same = ClinicalPathComparator.compare(baseline: baseline, candidate: report([try result("decode-native-ct", seconds: steady)]), profile: profile)
        XCTAssertEqual(same.decision, "promote"); XCTAssertEqual(same.entries.first?.outcome, "unchanged")
        let injected = ClinicalPathComparator.compare(baseline: baseline, candidate: report([try result("decode-native-ct", seconds: steady.map { $0 * 1.3 })]), profile: profile)
        XCTAssertEqual(injected.decision, "rollback"); XCTAssertEqual(injected.entries.first?.outcome, "regression")
        XCTAssertEqual(try XCTUnwrap(injected.entries.first?.deltaPercent), 30, accuracy: 0.5)
        let warning = ClinicalPathComparator.compare(baseline: baseline, candidate: report([try result("decode-native-ct", seconds: steady.map { $0 * 1.12 })]), profile: profile)
        XCTAssertEqual(warning.decision, "hold"); XCTAssertEqual(warning.entries.first?.outcome, "warning")
        let faster = ClinicalPathComparator.compare(baseline: baseline, candidate: report([try result("decode-native-ct", seconds: steady.map { $0 * 0.8 })]), profile: profile)
        XCTAssertEqual(faster.decision, "promote"); XCTAssertEqual(faster.entries.first?.outcome, "improvement")
        let otherHost = ClinicalPathComparator.compare(baseline: baseline, candidate: report([try result("decode-native-ct", seconds: steady)], environment: environment(["modelIdentifier": "Mac15,3"])), profile: profile)
        XCTAssertFalse(otherHost.comparable); XCTAssertEqual(otherHost.decision, "not-comparable"); XCTAssertEqual(otherHost.differingKeys, ["modelIdentifier"])
        let otherCorpus = ClinicalPathComparator.compare(baseline: baseline, candidate: report([try result("decode-native-ct", seconds: steady)], environment: environment(["corpusSHA256": "d"])), profile: profile)
        XCTAssertEqual(otherCorpus.differingKeys, ["corpusSHA256"])
        let noisy = ClinicalPathComparator.compare(baseline: baseline, candidate: report([try result("decode-native-ct", seconds: [0.05, 0.2, 0.05, 0.2, 0.05, 0.2])]), profile: profile)
        XCTAssertEqual(noisy.entries.first?.outcome, "inconclusive"); XCTAssertEqual(noisy.decision, "hold")
        let tooFew = ClinicalPathComparator.compare(baseline: baseline, candidate: report([try result("decode-native-ct", seconds: [0.1, 0.1])]), profile: profile)
        XCTAssertEqual(tooFew.entries.first?.outcome, "inconclusive")
        let incorrect = ClinicalPathComparator.compare(baseline: baseline, candidate: report([try result("decode-native-ct", seconds: steady.map { $0 * 0.5 }, correct: false)]), profile: profile)
        XCTAssertEqual(incorrect.decision, "rollback", "a faster wrong result is never promoted")
        let missing = ClinicalPathComparator.compare(baseline: baseline, candidate: report([]), profile: profile)
        XCTAssertEqual(missing.decision, "rollback"); XCTAssertTrue(missing.reason.contains("missing"))
        XCTAssertTrue(injected.markdownString().contains("regression"))
    }

    func test_report_roundTripsJSONAndBudgetsEvaluateP95AndRSS() throws {
        let manifest = try manifest()
        let budget = ClinicalPathBudget(warningSeconds: 0.1, failureSeconds: 0.2, peakRSSWarningBytes: 100, peakRSSFailureBytes: 200)
        var workload = ClinicalPathWorkloadResult(id: "decode-native-ct", stage: "decode", mode: .warmSustained, fixture: fixture(), warmupIterations: 1, iterations: 3,
                                                  correctness: .exact(expected: "x", observed: "x"), statistics: try ClinicalPathStatistics(samples: [0.05, 0.15, 0.05]),
                                                  resources: .init(peakRSSBytes: 150), budget: budget)
        XCTAssertEqual(workload.verdict, .warning)
        workload = ClinicalPathWorkloadResult(id: "decode-native-ct", stage: "decode", mode: .warmSustained, fixture: fixture(), warmupIterations: 1, iterations: 3,
                                              correctness: .exact(expected: "x", observed: "x"), statistics: try ClinicalPathStatistics(samples: [0.05, 0.25, 0.05]),
                                              resources: .init(peakRSSBytes: 250), budget: budget)
        XCTAssertEqual(workload.verdict, .failure)
        let report = ClinicalPathReport(collector: "test", environment: environment(), noisePolicy: manifest.noisePolicy, workloads: [workload], externalCollectors: manifest.externalCollectors)
        let decoded = try ClinicalPathReport.load(try report.jsonData())
        XCTAssertEqual(decoded.workloads, report.workloads)
        XCTAssertEqual(decoded.environment, report.environment)
        XCTAssertEqual(decoded.verdict, .failure)
        XCTAssertTrue(report.markdownString().contains("packages-budgets"))
        XCTAssertTrue(report.csvString().hasPrefix("id,stage,mode,status"))
    }
}
