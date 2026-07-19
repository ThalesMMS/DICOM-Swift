import XCTest
@testable import DicomCore

final class ClinicalPerformanceReporterTests: XCTestCase {
    func testBenchmarkModesAndTiersAreExplicitAndComplete() {
        XCTAssertEqual(Set(ClinicalPerformanceBenchmarkMode.allCases.map(\.rawValue)), [
            "cold-sdk-first-call",
            "prewarmed-first-clinical-call",
            "warm-isolated",
            "warm-sustained",
            "concurrent-clinical-workload",
            "fallback-path"
        ])
        XCTAssertEqual(Set(ClinicalPerformanceTier.allCases.map(\.rawValue)), [
            "pr-smoke", "nightly", "release", "manual-device"
        ])
    }

    func testStatisticsReportRequiredPercentilesVariationAndThroughput() throws {
        let statistics = try ClinicalPerformanceStatistics(
            samples: [0.010, 0.020, 0.030, 0.040],
            workUnitsPerSample: 1_000
        )

        XCTAssertEqual(statistics.sampleCount, 4)
        XCTAssertEqual(statistics.mean, 0.025, accuracy: 0.000_001)
        XCTAssertEqual(statistics.p50, 0.020, accuracy: 0.000_001)
        XCTAssertEqual(statistics.p95, 0.040, accuracy: 0.000_001)
        XCTAssertEqual(statistics.p99, 0.040, accuracy: 0.000_001)
        XCTAssertGreaterThan(statistics.standardDeviation, 0)
        XCTAssertGreaterThan(statistics.coefficientOfVariationPercent, 0)
        XCTAssertEqual(try XCTUnwrap(statistics.throughputPerSecond), 40_000, accuracy: 0.001)
    }

    func testEvaluatorUsesAbsoluteAndComparableRelativeGates() throws {
        let environment = makeEnvironment(mode: .warmSustained)
        let baselineStatistics = try ClinicalPerformanceStatistics(samples: [8, 10, 12])
        let currentStatistics = try ClinicalPerformanceStatistics(samples: [11, 12, 13])
        let gate = ClinicalPerformanceGate(
            warningLimit: 15,
            failureLimit: 20,
            relativeWarningPercent: 10,
            relativeFailurePercent: 25,
            lowerIsBetter: true
        )

        let measurement = ClinicalPerformanceEvaluator.evaluate(
            metricID: "cine-frame-latency",
            stage: "final-frame",
            unit: "ms",
            statistics: currentStatistics,
            correctnessPassed: true,
            gate: gate,
            environment: environment,
            baseline: (environment, baselineStatistics)
        )

        XCTAssertEqual(measurement.verdict, .warning)
        XCTAssertEqual(try XCTUnwrap(measurement.baselineMean), 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(measurement.baselineDeltaPercent), 20, accuracy: 0.001)
        XCTAssertTrue(measurement.eligibleForDefaultBackend)
        XCTAssertTrue(measurement.verdictReason.contains("same-host baseline"))
    }

    func testEvaluatorRejectsMismatchedBaselineAndFailsIncorrectFastResult() throws {
        let environment = makeEnvironment(mode: .warmIsolated)
        let otherMode = makeEnvironment(mode: .coldSDKFirstCall)
        let otherTier = makeEnvironment(mode: .warmIsolated, tier: .nightly)
        let statistics = try ClinicalPerformanceStatistics(samples: [1])
        let gate = ClinicalPerformanceGate(
            warningLimit: 10,
            failureLimit: 20,
            relativeWarningPercent: 10,
            relativeFailurePercent: 20,
            lowerIsBetter: true
        )

        let mismatched = ClinicalPerformanceEvaluator.evaluate(
            metricID: "decode",
            stage: "decode",
            unit: "ms",
            statistics: statistics,
            correctnessPassed: true,
            gate: gate,
            environment: environment,
            baseline: (otherMode, try ClinicalPerformanceStatistics(samples: [0.1]))
        )
        XCTAssertNil(mismatched.baselineDeltaPercent)
        XCTAssertTrue(mismatched.verdictReason.contains("baseline ignored"))

        let mismatchedTier = ClinicalPerformanceEvaluator.evaluate(
            metricID: "decode",
            stage: "decode",
            unit: "ms",
            statistics: statistics,
            correctnessPassed: true,
            gate: gate,
            environment: environment,
            baseline: (otherTier, try ClinicalPerformanceStatistics(samples: [0.1]))
        )
        XCTAssertNil(mismatchedTier.baselineDeltaPercent)
        XCTAssertTrue(mismatchedTier.verdictReason.contains("baseline ignored"))

        let incorrect = ClinicalPerformanceEvaluator.evaluate(
            metricID: "decode",
            stage: "decode",
            unit: "ms",
            statistics: statistics,
            correctnessPassed: false,
            gate: gate,
            environment: environment
        )
        XCTAssertEqual(incorrect.verdict, .failure)
        XCTAssertFalse(incorrect.eligibleForDefaultBackend)
        XCTAssertTrue(incorrect.verdictReason.contains("correctness gate failed"))
    }

    func testReporterExportsJSONCSVAndMarkdownWithClinicalContext() throws {
        let environment = makeEnvironment(mode: .prewarmedFirstClinicalCall)
        let statistics = try ClinicalPerformanceStatistics(samples: [7, 8, 9], workUnitsPerSample: 512 * 512)
        let gate = ClinicalPerformanceGate(
            warningLimit: 12,
            failureLimit: 16,
            relativeWarningPercent: 10,
            relativeFailurePercent: 20,
            lowerIsBetter: true
        )
        let work = ClinicalPerformanceWorkMetrics(
            usefulBytes: 2_048,
            cachedBytes: 1_024,
            duplicatedBytes: 0,
            staleBytes: 0,
            discardedBytes: 128,
            bytesAvoided: 8_192,
            pixelsAvoided: 65_536,
            cacheHits: 3,
            cacheMisses: 1,
            provisionalToFinalTransitions: 1
        )
        let resources = ClinicalPerformanceResourceMetrics(
            processCPUTimeMilliseconds: 6,
            peakRSSBytes: 64 * 1_024 * 1_024,
            residentDeltaBytes: 1_024,
            metalAllocatedBytes: 4_096,
            metalLeasedBytes: 2_048,
            metalReclaimableBytes: 1_024,
            metalPeakBytes: 8_192,
            newBufferCount: 1,
            reusedBufferCount: 2,
            newTextureCount: 1,
            reusedTextureCount: 3,
            cpuCopyCount: 1,
            gpuCopyCount: 1,
            temporaryFileIOBytes: 0,
            commandBufferDurationMilliseconds: 2,
            commandBufferFailureCount: 0,
            energyImpact: nil,
            thermalState: "nominal"
        )
        let measurement = ClinicalPerformanceEvaluator.evaluate(
            metricID: "first-visible-frame",
            stage: "preview-frame",
            unit: "ms",
            statistics: statistics,
            correctnessPassed: true,
            gate: gate,
            environment: environment,
            work: work,
            resources: resources
        )
        let report = ClinicalPerformanceReport(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            environment: environment,
            warmupIterations: 3,
            benchmarkIterations: 10,
            backendFlags: ["decoder": "j2kswift", "fallback": "openjpeg"],
            conformanceManifest: "ClinicalCodecConformanceManifest.json",
            measurements: [measurement]
        )
        let reporter = ClinicalPerformanceReporter(report: report)

        let json = try reporter.jsonString()
        let csv = reporter.csvString()
        let markdown = reporter.markdownString()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ClinicalPerformanceReport.self, from: Data(json.utf8)), report)
        for header in ClinicalPerformanceReporter.csvHeaders {
            XCTAssertTrue(csv.contains(header), header)
        }
        XCTAssertTrue(json.contains("pixelsAvoided"))
        XCTAssertTrue(json.contains("commandBufferFailureCount"))
        XCTAssertTrue(json.contains("\"verdict\" : \"pass\""))
        XCTAssertTrue(csv.contains("decoder=j2kswift"))
        XCTAssertTrue(csv.contains("pixelsAvoided"))
        XCTAssertTrue(markdown.contains("prewarmed-first-clinical-call"))
        XCTAssertTrue(markdown.contains("Backend flags"))
        XCTAssertTrue(markdown.contains("Work and resources"))
        XCTAssertTrue(markdown.contains("Correctness is evaluated before performance"))
        XCTAssertFalse(json.lowercased().contains("patientname"))
    }

    private func makeEnvironment(mode: ClinicalPerformanceBenchmarkMode,
                                 tier: ClinicalPerformanceTier = .pullRequestSmoke) -> ClinicalPerformanceEnvironment {
        ClinicalPerformanceEnvironment(
            deviceName: "Test Mac",
            osVersion: "Test OS",
            architecture: "arm64",
            modelIdentifier: "TestMac1,1",
            buildConfiguration: "release",
            benchmarkMode: mode,
            fixtureID: "ct-explicit-vr-le-rescale",
            tier: tier,
            commandLineStartupIncluded: false
        )
    }
}
