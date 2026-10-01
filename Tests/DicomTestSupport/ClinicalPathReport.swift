import CryptoKit
import Foundation

// Clinical-path benchmark contract shared by DicomCoreTests, DicomWebHTTPTests and the gate scripts (#2367).
// Every workload records fixture provenance (generator/hash/geometry/format/parameters), the expected and observed
// result, the maximum error, timing percentiles, work/resource counters and a verdict. Missing measurements are
// recorded as `notExecuted` with a reason; they never become estimates.

public enum ClinicalPathMode: String, Codable, CaseIterable, Sendable {
    case coldSDKFirstCall = "cold-sdk-first-call"
    case prewarmedFirstClinicalCall = "prewarmed-first-clinical-call"
    case warmIsolated = "warm-isolated"
    case warmSustained = "warm-sustained"
    case concurrentClinicalWorkload = "concurrent-clinical-workload"
    case fallbackPath = "fallback-path"
}

public enum ClinicalPathVerdict: String, Codable, Comparable, Sendable {
    case pass, warning, failure
    public static func < (lhs: Self, rhs: Self) -> Bool { rank(lhs) < rank(rhs) }
    private static func rank(_ verdict: Self) -> Int {
        switch verdict {
        case .pass: return 0
        case .warning: return 1
        case .failure: return 2
        }
    }
}

public enum ClinicalPathStatus: String, Codable, Sendable {
    case measured
    case notExecuted = "not-executed"
}

public struct ClinicalPathStatistics: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let meanSeconds: Double
    public let standardDeviationSeconds: Double
    public let coefficientOfVariationPercent: Double
    public let p50Seconds: Double
    public let p95Seconds: Double
    public let p99Seconds: Double
    public let minimumSeconds: Double
    public let maximumSeconds: Double
    public let throughputUnitsPerSecond: Double?
    public let throughputUnit: String?

    public init(samples: [Double], workUnitsPerSample: Double? = nil, throughputUnit: String? = nil) throws {
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw ClinicalPathError.invalidSamples }
        sampleCount = samples.count
        let mean = samples.reduce(0, +) / Double(samples.count)
        meanSeconds = mean
        let variance = samples.count > 1 ? samples.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(samples.count - 1) : 0
        standardDeviationSeconds = variance.squareRoot()
        coefficientOfVariationPercent = mean > 0 ? standardDeviationSeconds / mean * 100 : 0
        let sorted = samples.sorted()
        func percentile(_ value: Double) -> Double {
            let index = Int((value / 100 * Double(sorted.count)).rounded(.up)) - 1
            return sorted[max(0, min(index, sorted.count - 1))]
        }
        p50Seconds = percentile(50); p95Seconds = percentile(95); p99Seconds = percentile(99)
        minimumSeconds = sorted[0]; maximumSeconds = sorted[sorted.count - 1]
        if let workUnitsPerSample, mean > 0 { throughputUnitsPerSecond = workUnitsPerSample / mean } else { throughputUnitsPerSecond = nil }
        self.throughputUnit = throughputUnit
    }
}

public struct ClinicalPathFixture: Codable, Equatable, Sendable {
    public var id: String
    /// `synthetic:<generator>` or `external:<corpus id>`; never a path that could carry identity.
    public var source: String
    public var sha256: String
    public var bytes: Int
    public var geometry: String
    public var format: String
    public var parameters: [String: String]
    public init(id: String, source: String, sha256: String, bytes: Int, geometry: String, format: String, parameters: [String: String] = [:]) {
        self.id = id; self.source = source; self.sha256 = sha256; self.bytes = bytes; self.geometry = geometry; self.format = format; self.parameters = parameters
    }
}

public struct ClinicalPathCorrectness: Codable, Equatable, Sendable {
    public var expected: String
    public var observed: String
    public var maximumError: Double
    public var tolerance: Double
    public var comparison: String
    public var passed: Bool
    public init(expected: String, observed: String, maximumError: Double = 0, tolerance: Double = 0, comparison: String) {
        self.expected = expected; self.observed = observed; self.maximumError = maximumError; self.tolerance = tolerance; self.comparison = comparison
        passed = expected == observed && maximumError <= tolerance
    }
    public static func exact(expected: String, observed: String, comparison: String = "sha256 of the produced bytes") -> Self {
        .init(expected: expected, observed: observed, comparison: comparison)
    }
    public static func numeric(expected: Double, observed: Double, tolerance: Double, comparison: String) -> Self {
        var value = Self(expected: String(expected), observed: String(observed), maximumError: abs(expected - observed), tolerance: tolerance, comparison: comparison)
        value.passed = abs(expected - observed) <= tolerance
        return value
    }
}

public struct ClinicalPathWork: Codable, Equatable, Sendable {
    public var bytesRead: UInt64?
    public var bytesWritten: UInt64?
    public var networkBytesReceived: UInt64?
    public var networkBytesSent: UInt64?
    public var pixelsProcessed: UInt64?
    public var frames: Int?
    public init(bytesRead: UInt64? = nil, bytesWritten: UInt64? = nil, networkBytesReceived: UInt64? = nil, networkBytesSent: UInt64? = nil, pixelsProcessed: UInt64? = nil, frames: Int? = nil) {
        self.bytesRead = bytesRead; self.bytesWritten = bytesWritten; self.networkBytesReceived = networkBytesReceived
        self.networkBytesSent = networkBytesSent; self.pixelsProcessed = pixelsProcessed; self.frames = frames
    }
}

public struct ClinicalPathResources: Codable, Equatable, Sendable {
    public var processCPUSeconds: Double?
    public var peakRSSBytes: UInt64?
    public var residentDeltaBytes: Int64?
    public var heapBlocksDelta: Int64?
    public var allocationsCounted: Bool
    public var copies: Int?
    public var gpuUsed: Bool
    public var energyImpact: Double?
    public var thermalState: String?
    public init(processCPUSeconds: Double? = nil, peakRSSBytes: UInt64? = nil, residentDeltaBytes: Int64? = nil, heapBlocksDelta: Int64? = nil,
                allocationsCounted: Bool = false, copies: Int? = nil, gpuUsed: Bool = false, energyImpact: Double? = nil, thermalState: String? = nil) {
        self.processCPUSeconds = processCPUSeconds; self.peakRSSBytes = peakRSSBytes; self.residentDeltaBytes = residentDeltaBytes
        self.heapBlocksDelta = heapBlocksDelta; self.allocationsCounted = allocationsCounted; self.copies = copies; self.gpuUsed = gpuUsed
        self.energyImpact = energyImpact; self.thermalState = thermalState
    }
}

public struct ClinicalPathBudget: Codable, Equatable, Sendable {
    public var warningSeconds: Double
    public var failureSeconds: Double
    public var peakRSSWarningBytes: UInt64?
    public var peakRSSFailureBytes: UInt64?
    public init(warningSeconds: Double, failureSeconds: Double, peakRSSWarningBytes: UInt64? = nil, peakRSSFailureBytes: UInt64? = nil) {
        self.warningSeconds = warningSeconds; self.failureSeconds = failureSeconds
        self.peakRSSWarningBytes = peakRSSWarningBytes; self.peakRSSFailureBytes = peakRSSFailureBytes
    }
}

public struct ClinicalPathWorkloadResult: Codable, Equatable, Sendable {
    public var id: String
    public var stage: String
    public var mode: ClinicalPathMode
    public var status: ClinicalPathStatus
    public var notExecutedReason: String?
    public var fixture: ClinicalPathFixture?
    public var parameters: [String: String]
    public var warmupIterations: Int
    public var iterations: Int
    public var correctness: ClinicalPathCorrectness?
    public var statistics: ClinicalPathStatistics?
    public var work: ClinicalPathWork?
    public var resources: ClinicalPathResources?
    public var budget: ClinicalPathBudget?
    public var verdict: ClinicalPathVerdict
    public var verdictReason: String

    public init(id: String, stage: String, mode: ClinicalPathMode, fixture: ClinicalPathFixture?, parameters: [String: String] = [:],
                warmupIterations: Int, iterations: Int, correctness: ClinicalPathCorrectness?, statistics: ClinicalPathStatistics,
                work: ClinicalPathWork? = nil, resources: ClinicalPathResources? = nil, budget: ClinicalPathBudget?) {
        self.id = id; self.stage = stage; self.mode = mode; status = .measured; notExecutedReason = nil; self.fixture = fixture
        self.parameters = parameters; self.warmupIterations = warmupIterations; self.iterations = iterations; self.correctness = correctness
        self.statistics = statistics; self.work = work; self.resources = resources; self.budget = budget
        let evaluated = ClinicalPathEvaluator.verdict(correctness: correctness, statistics: statistics, resources: resources, budget: budget)
        verdict = evaluated.verdict; verdictReason = evaluated.reason
    }

    public static func notExecuted(id: String, stage: String, mode: ClinicalPathMode, reason: String, fixture: ClinicalPathFixture? = nil) -> Self {
        var result = Self(id: id, stage: stage, mode: mode, fixture: fixture, warmupIterations: 0, iterations: 0, correctness: nil,
                          statistics: try! ClinicalPathStatistics(samples: [0]), budget: nil)
        result.status = .notExecuted; result.notExecutedReason = reason; result.statistics = nil
        result.verdict = .warning; result.verdictReason = "not executed: " + reason
        return result
    }
}

public enum ClinicalPathEvaluator {
    /// Correctness first: a wrong result is a failure regardless of speed. Then absolute time and RSS budgets.
    public static func verdict(correctness: ClinicalPathCorrectness?, statistics: ClinicalPathStatistics, resources: ClinicalPathResources?,
                               budget: ClinicalPathBudget?) -> (verdict: ClinicalPathVerdict, reason: String) {
        if let correctness, !correctness.passed {
            return (.failure, "correctness failed (\(correctness.comparison)): expected \(correctness.expected), observed \(correctness.observed), max error \(correctness.maximumError) > \(correctness.tolerance)")
        }
        guard let budget else { return (.pass, correctness == nil ? "no correctness check declared; no budget" : "correct; no budget declared") }
        var verdict = ClinicalPathVerdict.pass
        var reasons: [String] = []
        if statistics.p95Seconds > budget.failureSeconds { verdict = .failure; reasons.append("p95 \(format(statistics.p95Seconds)) s > failure \(format(budget.failureSeconds)) s") }
        else if statistics.p95Seconds > budget.warningSeconds { verdict = .warning; reasons.append("p95 \(format(statistics.p95Seconds)) s > warning \(format(budget.warningSeconds)) s") }
        else { reasons.append("p95 \(format(statistics.p95Seconds)) s within budget \(format(budget.warningSeconds)) s") }
        if let rss = resources?.peakRSSBytes {
            if let failure = budget.peakRSSFailureBytes, rss > failure { verdict = .failure; reasons.append("peak RSS \(rss) > \(failure)") }
            else if let warning = budget.peakRSSWarningBytes, rss > warning { verdict = max(verdict, .warning); reasons.append("peak RSS \(rss) > \(warning)") }
        }
        return (verdict, reasons.joined(separator: "; "))
    }
    static func format(_ value: Double) -> String { String(format: "%.4f", value) }
}

public struct ClinicalPathEnvironment: Codable, Equatable, Sendable {
    public var modelIdentifier: String
    public var osVersion: String
    public var architecture: String
    public var processorCount: Int
    public var physicalMemoryBytes: UInt64
    public var buildConfiguration: String
    public var tier: String
    public var commandLineStartupIncluded: Bool
    public var toolkitVersion: String
    public var manifestSHA256: String
    public var corpusSHA256: String

    public init(modelIdentifier: String, osVersion: String, architecture: String, processorCount: Int, physicalMemoryBytes: UInt64, buildConfiguration: String,
                tier: String, commandLineStartupIncluded: Bool, toolkitVersion: String, manifestSHA256: String, corpusSHA256: String) {
        self.modelIdentifier = modelIdentifier; self.osVersion = osVersion; self.architecture = architecture; self.processorCount = processorCount
        self.physicalMemoryBytes = physicalMemoryBytes; self.buildConfiguration = buildConfiguration; self.tier = tier
        self.commandLineStartupIncluded = commandLineStartupIncluded; self.toolkitVersion = toolkitVersion; self.manifestSHA256 = manifestSHA256; self.corpusSHA256 = corpusSHA256
    }

    /// Keys that must match before two reports may be compared.
    public var comparisonFingerprint: [String: String] {
        ["modelIdentifier": modelIdentifier, "osVersion": osVersion, "architecture": architecture, "processorCount": String(processorCount),
         "buildConfiguration": buildConfiguration, "tier": tier, "commandLineStartupIncluded": String(commandLineStartupIncluded),
         "manifestSHA256": manifestSHA256, "corpusSHA256": corpusSHA256]
    }

    public static func current(tier: String, buildConfiguration: String, toolkitVersion: String, manifestSHA256: String, corpusSHA256: String,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let modelIdentifier = String(cString: model)
        var uname = utsname()
        _ = Foundation.uname(&uname)
        let architecture = withUnsafePointer(to: &uname.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        let info = ProcessInfo.processInfo
        return Self(modelIdentifier: modelIdentifier.isEmpty ? "unknown" : modelIdentifier, osVersion: info.operatingSystemVersionString,
                    architecture: architecture, processorCount: info.activeProcessorCount, physicalMemoryBytes: info.physicalMemory,
                    buildConfiguration: buildConfiguration, tier: environment["CLINICAL_PERFORMANCE_TIER"] ?? tier,
                    commandLineStartupIncluded: environment["CLINICAL_PERFORMANCE_CLI_STARTUP"] == "true", toolkitVersion: toolkitVersion,
                    manifestSHA256: manifestSHA256, corpusSHA256: corpusSHA256)
    }
}

public struct ClinicalPathExternalCollector: Codable, Equatable, Sendable {
    public var stem: String
    public var package: String
    public var stages: [String]
    public var status: String
    public var note: String
    public init(stem: String, package: String, stages: [String], status: String, note: String) {
        self.stem = stem; self.package = package; self.stages = stages; self.status = status; self.note = note
    }
}

public struct ClinicalPathReport: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schemaVersion: Int
    public var generatedAt: Date
    public var issue: Int
    public var collector: String
    public var environment: ClinicalPathEnvironment
    public var noisePolicy: ClinicalPathNoisePolicy
    public var workloads: [ClinicalPathWorkloadResult]
    public var externalCollectors: [ClinicalPathExternalCollector]
    public var verdict: ClinicalPathVerdict
    public var privacy: String

    public init(collector: String, environment: ClinicalPathEnvironment, noisePolicy: ClinicalPathNoisePolicy = .default,
                workloads: [ClinicalPathWorkloadResult], externalCollectors: [ClinicalPathExternalCollector] = []) {
        schemaVersion = Self.schemaVersion; generatedAt = Date(); issue = 2367; self.collector = collector; self.environment = environment
        self.noisePolicy = noisePolicy; self.workloads = workloads; self.externalCollectors = externalCollectors
        verdict = workloads.map(\.verdict).max() ?? .warning
        privacy = "Fixture identifiers, digests, geometry and aggregate measurements only; no paths, patient metadata or pixel payloads."
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func load(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: data)
    }

    public static let csvHeaders = ["id", "stage", "mode", "status", "fixtureID", "fixtureSHA256", "geometry", "format", "iterations", "correctnessPassed",
                                    "maximumError", "meanSeconds", "p50Seconds", "p95Seconds", "p99Seconds", "cvPercent", "throughput", "bytesRead",
                                    "networkBytesReceived", "peakRSSBytes", "heapBlocksDelta", "gpuUsed", "verdict", "verdictReason"]

    public func csvString() -> String {
        var lines = [Self.csvHeaders.joined(separator: ",")]
        for workload in workloads {
            let stats = workload.statistics
            let fields: [String] = [
                workload.id, workload.stage, workload.mode.rawValue, workload.status.rawValue, workload.fixture?.id ?? "", workload.fixture?.sha256 ?? "",
                workload.fixture?.geometry ?? "", workload.fixture?.format ?? "", String(workload.iterations),
                workload.correctness.map { String($0.passed) } ?? "", workload.correctness.map { String($0.maximumError) } ?? "",
                stats.map { String($0.meanSeconds) } ?? "", stats.map { String($0.p50Seconds) } ?? "", stats.map { String($0.p95Seconds) } ?? "",
                stats.map { String($0.p99Seconds) } ?? "", stats.map { String($0.coefficientOfVariationPercent) } ?? "",
                stats?.throughputUnitsPerSecond.map { String($0) } ?? "", workload.work?.bytesRead.map(String.init) ?? "",
                workload.work?.networkBytesReceived.map(String.init) ?? "", workload.resources?.peakRSSBytes.map(String.init) ?? "",
                workload.resources?.heapBlocksDelta.map(String.init) ?? "", String(workload.resources?.gpuUsed ?? false),
                workload.verdict.rawValue, workload.verdictReason,
            ]
            lines.append(fields.map { field in field.contains(",") || field.contains("\"") ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field }.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func markdownString() -> String {
        var lines = ["# Clinical path workloads (\(collector))", "",
                     "- Verdict: **\(verdict.rawValue)**", "- Host: \(environment.modelIdentifier), \(environment.osVersion), \(environment.architecture), \(environment.processorCount) cores",
                     "- Build: \(environment.buildConfiguration); tier: \(environment.tier); CLI startup included: \(environment.commandLineStartupIncluded)",
                     "- Manifest SHA-256: `\(environment.manifestSHA256)`; corpus SHA-256: `\(environment.corpusSHA256)`",
                     "- Noise policy: CV above \(noisePolicy.maximumCoefficientOfVariationPercent)% marks a comparison inconclusive; deltas below \(noisePolicy.minimumMeaningfulDeltaPercent)% are noise", "",
                     "| Workload | Stage | Mode | Status | Fixture | Correct | p50 s | p95 s | p99 s | CV % | Peak RSS | Verdict |", "| --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |"]
        for workload in workloads {
            let stats = workload.statistics
            func f(_ value: Double?) -> String { value.map { String(format: "%.5f", $0) } ?? "-" }
            lines.append("| \(workload.id) | \(workload.stage) | \(workload.mode.rawValue) | \(workload.status.rawValue) | \(workload.fixture?.id ?? "-") | \(workload.correctness.map { $0.passed ? "yes" : "NO" } ?? "n/a") | \(f(stats?.p50Seconds)) | \(f(stats?.p95Seconds)) | \(f(stats?.p99Seconds)) | \(stats.map { String(format: "%.1f", $0.coefficientOfVariationPercent) } ?? "-") | \(workload.resources?.peakRSSBytes.map(String.init) ?? "-") | \(workload.verdict.rawValue): \(workload.verdictReason) |")
        }
        if !externalCollectors.isEmpty {
            lines += ["", "## External collectors", "", "| Report | Package | Stages | Status | Note |", "| --- | --- | --- | --- | --- |"]
            for collector in externalCollectors {
                lines.append("| \(collector.stem) | \(collector.package) | \(collector.stages.joined(separator: ", ")) | \(collector.status) | \(collector.note) |")
            }
        }
        lines += ["", privacy, ""]
        return lines.joined(separator: "\n")
    }

    public func write(stem: String, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try jsonData().write(to: directory.appendingPathComponent(stem + ".json"))
        try Data(csvString().utf8).write(to: directory.appendingPathComponent(stem + ".csv"))
        try Data(markdownString().utf8).write(to: directory.appendingPathComponent(stem + ".md"))
    }
}

public struct ClinicalPathNoisePolicy: Codable, Equatable, Sendable {
    public var maximumCoefficientOfVariationPercent: Double
    public var minimumMeaningfulDeltaPercent: Double
    public var minimumIterationsForComparison: Int
    public init(maximumCoefficientOfVariationPercent: Double, minimumMeaningfulDeltaPercent: Double, minimumIterationsForComparison: Int) {
        self.maximumCoefficientOfVariationPercent = maximumCoefficientOfVariationPercent
        self.minimumMeaningfulDeltaPercent = minimumMeaningfulDeltaPercent
        self.minimumIterationsForComparison = minimumIterationsForComparison
    }
    public static let `default` = Self(maximumCoefficientOfVariationPercent: 25, minimumMeaningfulDeltaPercent: 5, minimumIterationsForComparison: 5)
}

public enum ClinicalPathError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidSamples
    case invalidIterations(String)
    case missingWorkloads([String])
    case incompatibleEnvironments([String])
    case unknownProfile(String)
    case correctnessFailed([String])
    public var description: String {
        switch self {
        case .invalidSamples: return "samples must be finite, non-negative and non-empty"
        case .invalidIterations(let id): return "workload \(id) requires positive iterations and non-negative warmup iterations"
        case .missingWorkloads(let ids): return "required workloads missing or not executed: " + ids.joined(separator: ", ")
        case .incompatibleEnvironments(let keys): return "reports are not comparable; differing keys: " + keys.joined(separator: ", ")
        case .unknownProfile(let id): return "unknown promotion profile " + id
        case .correctnessFailed(let ids): return "correctness failed for " + ids.joined(separator: ", ")
        }
    }
}

// MARK: - Validation and comparison

public struct ClinicalPathRequirement: Codable, Equatable, Sendable {
    public var workloadID: String
    public var modes: [ClinicalPathMode]
    public init(workloadID: String, modes: [ClinicalPathMode]) { self.workloadID = workloadID; self.modes = modes }
}

public enum ClinicalPathReportValidator {
    /// Every required (workload, mode) pair must be present and measured; correctness must be evaluated for measured workloads.
    public static func validate(_ report: ClinicalPathReport, requirements: [ClinicalPathRequirement]) throws {
        var missing: [String] = []
        for requirement in requirements {
            for mode in requirement.modes {
                let found = report.workloads.first { $0.id == requirement.workloadID && $0.mode == mode }
                if found == nil || found?.status != .measured || found?.statistics == nil { missing.append("\(requirement.workloadID)@\(mode.rawValue)") }
            }
        }
        guard missing.isEmpty else { throw ClinicalPathError.missingWorkloads(missing) }
        let incorrect = report.workloads.filter { $0.status == .measured && $0.correctness?.passed != true }.map(\.id)
        guard incorrect.isEmpty else { throw ClinicalPathError.correctnessFailed(incorrect) }
    }
}

public struct ClinicalPathComparisonEntry: Codable, Equatable, Sendable {
    public var id: String
    public var mode: ClinicalPathMode
    public var baselineP95Seconds: Double?
    public var candidateP95Seconds: Double?
    public var deltaPercent: Double?
    public var baselineCVPercent: Double?
    public var candidateCVPercent: Double?
    public var outcome: String
    public var reason: String
}

public struct ClinicalPathPromotionProfile: Codable, Equatable, Sendable {
    public var id: String
    public var description: String
    public var requiredWorkloads: [ClinicalPathRequirement]
    public var maximumRegressionPercent: Double
    public var rollbackRegressionPercent: Double
    public var minimumIterations: Int
    public init(id: String, description: String, requiredWorkloads: [ClinicalPathRequirement], maximumRegressionPercent: Double, rollbackRegressionPercent: Double, minimumIterations: Int) {
        self.id = id; self.description = description; self.requiredWorkloads = requiredWorkloads; self.maximumRegressionPercent = maximumRegressionPercent
        self.rollbackRegressionPercent = rollbackRegressionPercent; self.minimumIterations = minimumIterations
    }
}

public struct ClinicalPathComparison: Codable, Equatable, Sendable {
    public var profile: String
    public var comparable: Bool
    public var differingKeys: [String]
    public var entries: [ClinicalPathComparisonEntry]
    public var decision: String
    public var reason: String

    public func markdownString() -> String {
        var lines = ["# Clinical path comparison (\(profile))", "", "- Comparable: \(comparable)" + (differingKeys.isEmpty ? "" : " (differs: \(differingKeys.joined(separator: ", ")))"),
                     "- Decision: **\(decision)** — \(reason)", "", "| Workload | Mode | Baseline p95 s | Candidate p95 s | Delta % | Baseline CV % | Candidate CV % | Outcome |", "| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |"]
        func f(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "-" }
        for entry in entries {
            lines.append("| \(entry.id) | \(entry.mode.rawValue) | \(f(entry.baselineP95Seconds)) | \(f(entry.candidateP95Seconds)) | \(entry.deltaPercent.map { String(format: "%+.1f", $0) } ?? "-") | \(f(entry.baselineCVPercent)) | \(f(entry.candidateCVPercent)) | \(entry.outcome): \(entry.reason) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public enum ClinicalPathComparator {
    /// Same host/build/corpus/manifest/config only; correctness first; noise-aware relative deltas on p95; promotion/rollback per profile.
    public static func compare(baseline: ClinicalPathReport, candidate: ClinicalPathReport, profile: ClinicalPathPromotionProfile) -> ClinicalPathComparison {
        let differing = baseline.environment.comparisonFingerprint.filter { candidate.environment.comparisonFingerprint[$0.key] != $0.value }.map(\.key).sorted()
        guard differing.isEmpty else {
            return ClinicalPathComparison(profile: profile.id, comparable: false, differingKeys: differing, entries: [], decision: "not-comparable",
                                          reason: "host, build, corpus, manifest or configuration differ; metrics are incompatible and were not compared")
        }
        do {
            try ClinicalPathReportValidator.validate(candidate, requirements: profile.requiredWorkloads)
        } catch {
            return ClinicalPathComparison(profile: profile.id, comparable: true, differingKeys: [], entries: [], decision: "rollback", reason: String(describing: error))
        }
        var entries: [ClinicalPathComparisonEntry] = []
        var worst = "promote"
        var reasons: [String] = []
        let noise = candidate.noisePolicy
        for requirement in profile.requiredWorkloads {
            for mode in requirement.modes {
                let base = baseline.workloads.first { $0.id == requirement.workloadID && $0.mode == mode }
                let cand = candidate.workloads.first { $0.id == requirement.workloadID && $0.mode == mode }!
                guard let baseStats = base?.statistics, let candStats = cand.statistics else {
                    entries.append(.init(id: requirement.workloadID, mode: mode, baselineP95Seconds: nil, candidateP95Seconds: cand.statistics?.p95Seconds, deltaPercent: nil,
                                         baselineCVPercent: nil, candidateCVPercent: cand.statistics?.coefficientOfVariationPercent, outcome: "no-baseline", reason: "baseline has no measured sample for this workload/mode"))
                    if worst == "promote" { worst = "hold" }
                    reasons.append("\(requirement.workloadID)@\(mode.rawValue) has no baseline")
                    continue
                }
                let delta = baseStats.p95Seconds > 0 ? (candStats.p95Seconds - baseStats.p95Seconds) / baseStats.p95Seconds * 100 : 0
                let sustainedMode = mode == .warmSustained || mode == .warmIsolated || mode == .concurrentClinicalWorkload
                let enoughIterations = candStats.sampleCount >= profile.minimumIterations && baseStats.sampleCount >= profile.minimumIterations
                var outcome: String
                var reason: String
                if sustainedMode, !enoughIterations {
                    outcome = "inconclusive"; reason = "fewer than \(profile.minimumIterations) iterations"
                } else if sustainedMode, max(baseStats.coefficientOfVariationPercent, candStats.coefficientOfVariationPercent) > noise.maximumCoefficientOfVariationPercent {
                    outcome = "inconclusive"; reason = "coefficient of variation above \(noise.maximumCoefficientOfVariationPercent)%; rerun on a quiet host"
                } else if delta > profile.rollbackRegressionPercent {
                    outcome = "regression"; reason = "p95 slower by \(String(format: "%.1f", delta))% > rollback \(profile.rollbackRegressionPercent)%"
                } else if delta > profile.maximumRegressionPercent {
                    outcome = "warning"; reason = "p95 slower by \(String(format: "%.1f", delta))% > \(profile.maximumRegressionPercent)%"
                } else if abs(delta) < noise.minimumMeaningfulDeltaPercent {
                    outcome = "unchanged"; reason = "delta within noise floor"
                } else if delta < 0 {
                    outcome = "improvement"; reason = "p95 faster by \(String(format: "%.1f", -delta))%"
                } else {
                    outcome = "acceptable"; reason = "p95 slower by \(String(format: "%.1f", delta))% within \(profile.maximumRegressionPercent)%"
                }
                entries.append(.init(id: requirement.workloadID, mode: mode, baselineP95Seconds: baseStats.p95Seconds, candidateP95Seconds: candStats.p95Seconds, deltaPercent: delta,
                                     baselineCVPercent: baseStats.coefficientOfVariationPercent, candidateCVPercent: candStats.coefficientOfVariationPercent, outcome: outcome, reason: reason))
                switch outcome {
                case "regression": worst = "rollback"; reasons.append("\(requirement.workloadID)@\(mode.rawValue): \(reason)")
                case "warning", "inconclusive": if worst == "promote" { worst = "hold" }; reasons.append("\(requirement.workloadID)@\(mode.rawValue): \(reason)")
                default: break
                }
            }
        }
        return ClinicalPathComparison(profile: profile.id, comparable: true, differingKeys: [], entries: entries, decision: worst,
                                      reason: reasons.isEmpty ? "every required workload is correct and within \(profile.maximumRegressionPercent)% of the baseline" : reasons.joined(separator: "; "))
    }
}

// MARK: - Measurement helpers

public enum ClinicalPathMeasurer {
    public static func peakRSSBytes() -> UInt64? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 else { return nil }
        return UInt64(usage.ru_maxrss)
    }

    public static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }

    public static func processCPUSeconds() -> Double {
        var spec = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &spec)
        return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9
    }

    public static func liveHeapBlocks() -> Int64? {
        #if os(macOS)
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &statistics)
        return Int64(statistics.blocks_in_use)
        #else
        return nil
        #endif
    }

    public struct Sample: Sendable {
        public let seconds: Double
        public let cpuSeconds: Double
        public let residentDeltaBytes: Int64?
        public let heapBlocksDelta: Int64?
    }

    /// Times one synchronous operation with CPU time, resident delta and live-heap-block delta.
    public static func measure<T>(_ operation: () throws -> T) rethrows -> (value: T, sample: Sample) {
        let residentBefore = residentBytes(), blocksBefore = liveHeapBlocks(), cpuBefore = processCPUSeconds()
        let clock = ContinuousClock()
        let start = clock.now
        let value = try operation()
        let elapsed = clock.now - start
        let cpu = processCPUSeconds() - cpuBefore
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let residentDelta = zip(residentBefore, residentBytes()).map { Int64($1) - Int64($0) }
        let blocksDelta = zip(blocksBefore, liveHeapBlocks()).map { $1 - $0 }
        return (value, Sample(seconds: seconds, cpuSeconds: cpu, residentDeltaBytes: residentDelta, heapBlocksDelta: blocksDelta))
    }

    public static func measureAsync<T>(_ operation: () async throws -> T) async rethrows -> (value: T, sample: Sample) {
        let residentBefore = residentBytes(), blocksBefore = liveHeapBlocks(), cpuBefore = processCPUSeconds()
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await operation()
        let elapsed = clock.now - start
        let cpu = processCPUSeconds() - cpuBefore
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let residentDelta = zip(residentBefore, residentBytes()).map { Int64($1) - Int64($0) }
        let blocksDelta = zip(blocksBefore, liveHeapBlocks()).map { $1 - $0 }
        return (value, Sample(seconds: seconds, cpuSeconds: cpu, residentDeltaBytes: residentDelta, heapBlocksDelta: blocksDelta))
    }

    private static func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? { if let a, let b { return (a, b) }; return nil }

    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public static func resources(samples: [Sample], gpuUsed: Bool = false) -> ClinicalPathResources {
        ClinicalPathResources(processCPUSeconds: samples.map(\.cpuSeconds).reduce(0, +), peakRSSBytes: peakRSSBytes(),
                              residentDeltaBytes: samples.compactMap(\.residentDeltaBytes).max(), heapBlocksDelta: samples.compactMap(\.heapBlocksDelta).max(),
                              allocationsCounted: samples.contains { $0.heapBlocksDelta != nil }, gpuUsed: gpuUsed)
    }
}
