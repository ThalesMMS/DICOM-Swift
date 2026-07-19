//
//  ClinicalPerformanceReporter.swift
//  DicomCore
//
//  Cross-codec clinical performance result contract and exports.
//

import Foundation

enum ClinicalPerformanceBenchmarkMode: String, CaseIterable, Codable {
    case coldSDKFirstCall = "cold-sdk-first-call"
    case prewarmedFirstClinicalCall = "prewarmed-first-clinical-call"
    case warmIsolated = "warm-isolated"
    case warmSustained = "warm-sustained"
    case concurrentClinicalWorkload = "concurrent-clinical-workload"
    case fallbackPath = "fallback-path"
}

enum ClinicalPerformanceTier: String, CaseIterable, Codable {
    case pullRequestSmoke = "pr-smoke"
    case nightly
    case release
    case manualDevice = "manual-device"
}

enum ClinicalPerformanceVerdict: String, Codable, Comparable {
    case pass
    case warning
    case failure

    static func < (lhs: ClinicalPerformanceVerdict,
                   rhs: ClinicalPerformanceVerdict) -> Bool {
        rank(lhs) < rank(rhs)
    }

    private static func rank(_ verdict: ClinicalPerformanceVerdict) -> Int {
        switch verdict {
        case .pass: return 0
        case .warning: return 1
        case .failure: return 2
        }
    }
}

struct ClinicalPerformanceEnvironment: Codable, Equatable {
    let deviceName: String
    let osVersion: String
    let architecture: String
    let modelIdentifier: String
    let buildConfiguration: String
    let benchmarkMode: ClinicalPerformanceBenchmarkMode
    let fixtureID: String
    let tier: ClinicalPerformanceTier
    let commandLineStartupIncluded: Bool

    func isComparable(to other: ClinicalPerformanceEnvironment) -> Bool {
        deviceName == other.deviceName
            && osVersion == other.osVersion
            && architecture == other.architecture
            && modelIdentifier == other.modelIdentifier
            && buildConfiguration == other.buildConfiguration
            && benchmarkMode == other.benchmarkMode
            && fixtureID == other.fixtureID
            && tier == other.tier
            && commandLineStartupIncluded == other.commandLineStartupIncluded
    }
}

struct ClinicalPerformanceStatistics: Codable, Equatable {
    let sampleCount: Int
    let mean: Double
    let standardDeviation: Double
    let coefficientOfVariationPercent: Double
    let p50: Double
    let p95: Double
    let p99: Double
    let throughputPerSecond: Double?

    init(samples: [Double], workUnitsPerSample: Double? = nil) throws {
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw BenchmarkError.insufficientData("Clinical performance samples must be finite, non-negative, and non-empty")
        }

        sampleCount = samples.count
        let calculatedMean = samples.reduce(0, +) / Double(samples.count)
        mean = calculatedMean
        if samples.count > 1 {
            let variance = samples
                .map { pow($0 - calculatedMean, 2) }
                .reduce(0, +) / Double(samples.count - 1)
            standardDeviation = sqrt(variance)
        } else {
            standardDeviation = 0
        }
        coefficientOfVariationPercent = calculatedMean > 0 ? standardDeviation / calculatedMean * 100 : 0
        p50 = Self.percentile(50, samples: samples)
        p95 = Self.percentile(95, samples: samples)
        p99 = Self.percentile(99, samples: samples)
        if let workUnitsPerSample, calculatedMean > 0 {
            throughputPerSecond = workUnitsPerSample / calculatedMean
        } else {
            throughputPerSecond = nil
        }
    }

    private static func percentile(_ percentile: Double,
                                   samples: [Double]) -> Double {
        let sorted = samples.sorted()
        let index = Int(ceil(percentile / 100 * Double(sorted.count))) - 1
        return sorted[max(0, min(index, sorted.count - 1))]
    }
}

struct ClinicalPerformanceWorkMetrics: Codable, Equatable {
    var usefulBytes: UInt64 = 0
    var cachedBytes: UInt64 = 0
    var duplicatedBytes: UInt64 = 0
    var staleBytes: UInt64 = 0
    var discardedBytes: UInt64 = 0
    var bytesAvoided: UInt64 = 0
    var pixelsAvoided: UInt64 = 0
    var cacheHits: Int = 0
    var cacheMisses: Int = 0
    var provisionalToFinalTransitions: Int = 0
}

struct ClinicalPerformanceResourceMetrics: Codable, Equatable {
    var processCPUTimeMilliseconds: Double? = nil
    var peakRSSBytes: UInt64? = nil
    var residentDeltaBytes: Int64? = nil
    var metalAllocatedBytes: UInt64? = nil
    var metalLeasedBytes: UInt64? = nil
    var metalReclaimableBytes: UInt64? = nil
    var metalPeakBytes: UInt64? = nil
    var newBufferCount: Int? = nil
    var reusedBufferCount: Int? = nil
    var newTextureCount: Int? = nil
    var reusedTextureCount: Int? = nil
    var cpuCopyCount: Int? = nil
    var gpuCopyCount: Int? = nil
    var temporaryFileIOBytes: UInt64? = nil
    var commandBufferDurationMilliseconds: Double? = nil
    var commandBufferFailureCount: Int? = nil
    var energyImpact: Double? = nil
    var thermalState: String? = nil
}

struct ClinicalPerformanceGate: Codable, Equatable {
    let warningLimit: Double
    let failureLimit: Double
    let relativeWarningPercent: Double
    let relativeFailurePercent: Double
    let lowerIsBetter: Bool
}

struct ClinicalPerformanceMeasurement: Codable, Equatable {
    let metricID: String
    let stage: String
    let unit: String
    let statistics: ClinicalPerformanceStatistics
    let correctnessPassed: Bool
    let gate: ClinicalPerformanceGate
    let baselineMean: Double?
    let baselineDeltaPercent: Double?
    let verdict: ClinicalPerformanceVerdict
    let verdictReason: String
    let work: ClinicalPerformanceWorkMetrics?
    let resources: ClinicalPerformanceResourceMetrics?

    var eligibleForDefaultBackend: Bool {
        correctnessPassed && verdict != .failure
    }
}

enum ClinicalPerformanceEvaluator {
    static func evaluate(metricID: String,
                         stage: String,
                         unit: String,
                         statistics: ClinicalPerformanceStatistics,
                         correctnessPassed: Bool,
                         gate: ClinicalPerformanceGate,
                         environment: ClinicalPerformanceEnvironment,
                         baseline: (environment: ClinicalPerformanceEnvironment,
                                    statistics: ClinicalPerformanceStatistics)? = nil,
                         work: ClinicalPerformanceWorkMetrics? = nil,
                         resources: ClinicalPerformanceResourceMetrics? = nil) -> ClinicalPerformanceMeasurement {
        guard correctnessPassed else {
            return ClinicalPerformanceMeasurement(
                metricID: metricID,
                stage: stage,
                unit: unit,
                statistics: statistics,
                correctnessPassed: false,
                gate: gate,
                baselineMean: nil,
                baselineDeltaPercent: nil,
                verdict: .failure,
                verdictReason: "correctness gate failed; performance cannot qualify a backend",
                work: work,
                resources: resources
            )
        }

        var verdict = absoluteVerdict(value: statistics.mean, gate: gate)
        var reasons = [absoluteReason(value: statistics.mean, gate: gate, verdict: verdict)]
        var baselineMean: Double?
        var baselineDelta: Double?

        if let baseline, environment.isComparable(to: baseline.environment) {
            baselineMean = baseline.statistics.mean
            if baseline.statistics.mean > 0 {
                let rawDelta = (statistics.mean - baseline.statistics.mean) / baseline.statistics.mean * 100
                baselineDelta = gate.lowerIsBetter ? rawDelta : -rawDelta
                let relativeVerdict: ClinicalPerformanceVerdict
                if baselineDelta! > gate.relativeFailurePercent {
                    relativeVerdict = .failure
                } else if baselineDelta! >= gate.relativeWarningPercent {
                    relativeVerdict = .warning
                } else {
                    relativeVerdict = .pass
                }
                verdict = max(verdict, relativeVerdict)
                reasons.append("same-host baseline delta \(Self.format(baselineDelta!))%")
            }
        } else if baseline != nil {
            reasons.append("baseline ignored because host, mode, fixture, build, or startup scope differs")
        } else {
            reasons.append("no same-host baseline")
        }

        return ClinicalPerformanceMeasurement(
            metricID: metricID,
            stage: stage,
            unit: unit,
            statistics: statistics,
            correctnessPassed: true,
            gate: gate,
            baselineMean: baselineMean,
            baselineDeltaPercent: baselineDelta,
            verdict: verdict,
            verdictReason: reasons.joined(separator: "; "),
            work: work,
            resources: resources
        )
    }

    private static func absoluteVerdict(value: Double,
                                        gate: ClinicalPerformanceGate) -> ClinicalPerformanceVerdict {
        let failure = gate.lowerIsBetter ? value > gate.failureLimit : value < gate.failureLimit
        let warning = gate.lowerIsBetter ? value >= gate.warningLimit : value <= gate.warningLimit
        if failure { return .failure }
        if warning { return .warning }
        return .pass
    }

    private static func absoluteReason(value: Double,
                                       gate: ClinicalPerformanceGate,
                                       verdict: ClinicalPerformanceVerdict) -> String {
        "absolute \(verdict.rawValue): value \(format(value)), warning \(format(gate.warningLimit)), failure \(format(gate.failureLimit))"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

struct ClinicalPerformanceReport: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let environment: ClinicalPerformanceEnvironment
    let warmupIterations: Int
    let benchmarkIterations: Int
    let backendFlags: [String: String]
    let conformanceManifest: String
    let measurements: [ClinicalPerformanceMeasurement]
    let verdict: ClinicalPerformanceVerdict

    init(schemaVersion: Int,
         generatedAt: Date,
         environment: ClinicalPerformanceEnvironment,
         warmupIterations: Int,
         benchmarkIterations: Int,
         backendFlags: [String: String],
         conformanceManifest: String,
         measurements: [ClinicalPerformanceMeasurement]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.environment = environment
        self.warmupIterations = warmupIterations
        self.benchmarkIterations = benchmarkIterations
        self.backendFlags = backendFlags
        self.conformanceManifest = conformanceManifest
        self.measurements = measurements
        self.verdict = measurements.map(\.verdict).max() ?? .warning
    }
}

struct ClinicalPerformanceReporter {
    static let csvHeaders = [
        "fixtureID", "tier", "benchmarkMode", "buildConfiguration", "commandLineStartupIncluded",
        "backendFlags", "conformanceManifest", "metricID", "stage", "unit", "sampleCount", "mean",
        "standardDeviation", "coefficientOfVariationPercent",
        "p50", "p95", "p99", "throughputPerSecond", "baselineMean", "baselineDeltaPercent", "verdict",
        "correctnessPassed", "verdictReason", "workMetrics", "resourceMetrics", "deviceName", "osVersion", "architecture", "modelIdentifier"
    ]

    let report: ClinicalPerformanceReport

    func jsonString(prettyPrinted: Bool = true) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    func csvString() -> String {
        let rows = report.measurements.map { measurement in
            let statistics = measurement.statistics
            let values = [
                report.environment.fixtureID,
                report.environment.tier.rawValue,
                report.environment.benchmarkMode.rawValue,
                report.environment.buildConfiguration,
                String(report.environment.commandLineStartupIncluded),
                Self.format(report.backendFlags),
                report.conformanceManifest,
                measurement.metricID,
                measurement.stage,
                measurement.unit,
                String(statistics.sampleCount),
                Self.format(statistics.mean),
                Self.format(statistics.standardDeviation),
                Self.format(statistics.coefficientOfVariationPercent),
                Self.format(statistics.p50),
                Self.format(statistics.p95),
                Self.format(statistics.p99),
                statistics.throughputPerSecond.map(Self.format) ?? "",
                measurement.baselineMean.map(Self.format) ?? "",
                measurement.baselineDeltaPercent.map(Self.format) ?? "",
                measurement.verdict.rawValue,
                String(measurement.correctnessPassed),
                measurement.verdictReason,
                Self.jsonField(measurement.work),
                Self.jsonField(measurement.resources),
                report.environment.deviceName,
                report.environment.osVersion,
                report.environment.architecture,
                report.environment.modelIdentifier
            ]
            return values.map(Self.escapeCSV).joined(separator: ",")
        }
        return ([Self.csvHeaders.joined(separator: ",")] + rows).joined(separator: "\n")
    }

    func markdownString() -> String {
        var lines = [
            "# Clinical Performance Report",
            "",
            "- **Verdict**: \(report.verdict.rawValue)",
            "- **Fixture**: \(report.environment.fixtureID)",
            "- **Tier**: \(report.environment.tier.rawValue)",
            "- **Mode**: \(report.environment.benchmarkMode.rawValue)",
            "- **Build Configuration**: \(report.environment.buildConfiguration)",
            "- **CLI startup included**: \(report.environment.commandLineStartupIncluded)",
            "- **Warmups / iterations**: \(report.warmupIterations) / \(report.benchmarkIterations)",
            "- **Backend flags**: \(Self.format(report.backendFlags))",
            "- **Conformance evidence**: `\(report.conformanceManifest)`",
            "",
            "| Metric | Stage | Mean | P50 | P95 | P99 | CV | Baseline delta | Verdict |",
            "|---|---|---:|---:|---:|---:|---:|---:|---|"
        ]
        for measurement in report.measurements {
            let statistics = measurement.statistics
            let baselineDelta = measurement.baselineDeltaPercent.map { Self.format($0) + "%" } ?? "n/a"
            let row = "| \(measurement.metricID) | \(measurement.stage) | "
                + "\(Self.format(statistics.mean)) \(measurement.unit) | \(Self.format(statistics.p50)) | "
                + "\(Self.format(statistics.p95)) | \(Self.format(statistics.p99)) | "
                + "\(Self.format(statistics.coefficientOfVariationPercent))% | \(baselineDelta) | "
                + "\(measurement.verdict.rawValue) |"
            lines.append(row)
        }
        lines.append("")
        lines.append("## Work and resources")
        lines.append("")
        for measurement in report.measurements {
            let work = Self.jsonField(measurement.work)
            let resources = Self.jsonField(measurement.resources)
            lines.append("- **\(measurement.metricID)** work: `\(work)`; resources: `\(resources)`")
        }
        lines.append("")
        lines.append("Correctness is evaluated before performance; a faster incorrect backend is never eligible as the default.")
        return lines.joined(separator: "\n")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func format(_ values: [String: String]) -> String {
        values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: ";")
    }

    private static func jsonField<T: Encodable>(_ value: T?) -> String {
        guard let value,
              let data = try? JSONEncoder().encode(value) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func escapeCSV(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
