import DicomCore
import DicomTestSupport
import DicomWebHTTP
import Foundation
import XCTest

/// Network stages of the clinical path (#2367): WADO-RS retrieve and STOW-RS store against the shared loopback
/// listener, with bytes on the wire and correctness (retrieved/stored bytes equal the source object). Writes the
/// `dicom-clinical-path-network-workloads` triplet when `CLINICAL_PERFORMANCE_OUTPUT_DIR` is set.
final class ClinicalPathNetworkWorkloadTests: XCTestCase {
    struct Outcome { let correctness: ClinicalPathCorrectness; let work: ClinicalPathWork }

    private func run(_ workload: ClinicalPathWorkloadManifest.Workload, manifest: ClinicalPathWorkloadManifest, fixture: ClinicalPathFixture, operation: () async throws -> Outcome) async throws -> [ClinicalPathWorkloadResult] {
        var results: [ClinicalPathWorkloadResult] = []
        func single(mode: ClinicalPathMode, warmups: Int, count: Int) async throws -> ClinicalPathWorkloadResult {
            for _ in 0..<warmups { _ = try await operation() }
            var samples: [ClinicalPathMeasurer.Sample] = []
            var last: Outcome?
            var worst: ClinicalPathCorrectness?
            for _ in 0..<count {
                let (outcome, sample) = try await ClinicalPathMeasurer.measureAsync { try await operation() }
                samples.append(sample); last = outcome
                if !outcome.correctness.passed, worst == nil { worst = outcome.correctness }
            }
            let bytes = last!.work.networkBytesReceived ?? last!.work.networkBytesSent
            return ClinicalPathWorkloadResult(id: workload.id, stage: workload.stage, mode: mode, fixture: fixture, parameters: ["description": workload.description, "transport": "loopback TCP", "budgetScale": Self.buildConfiguration == "debug" ? String(manifest.debugBudgetMultiplier) : "1"],
                                              warmupIterations: warmups, iterations: count, correctness: worst ?? last!.correctness,
                                              statistics: try ClinicalPathStatistics(samples: samples.map(\.seconds), workUnitsPerSample: bytes.map(Double.init), throughputUnit: "bytes/s"),
                                              work: last!.work, resources: ClinicalPathMeasurer.resources(samples: samples), budget: manifest.budget(for: workload, buildConfiguration: Self.buildConfiguration))
        }
        for mode in workload.modes {
            switch mode {
            case .coldSDKFirstCall, .prewarmedFirstClinicalCall: results.append(try await single(mode: mode, warmups: 0, count: 1))
            case .warmIsolated: results.append(try await single(mode: mode, warmups: workload.warmupIterations, count: 1))
            case .warmSustained, .concurrentClinicalWorkload: results.append(try await single(mode: mode, warmups: workload.warmupIterations, count: workload.iterations))
            case .fallbackPath: results.append(.notExecuted(id: workload.id, stage: workload.stage, mode: mode, reason: "no fallback transport exists for DICOMweb", fixture: fixture))
            }
        }
        return results
    }

    func test_networkWorkloads_measureLoopbackRetrieveAndStore() async throws {
        let loaded = try ClinicalPathWorkloadManifest.load()
        let manifest = loaded.manifest
        let corpus = try await ClinicalPathSyntheticCorpus.generate()
        let source = try XCTUnwrap(corpus.objects.first { $0.fixture.id == "ct-512x512-16bit" })
        let sourceDecoder = try await DCMDecoder(data: source.part10)
        let dataSet = sourceDecoder.dataSet
        let study = try XCTUnwrap(dataSet.string(for: .studyInstanceUID)), series = try XCTUnwrap(dataSet.string(for: .seriesInstanceUID)), instance = try XCTUnwrap(dataSet.string(for: .sopInstanceUID))
        let store = DicomWebInMemoryStore()
        _ = try store.add(dataSet: DicomDataSet(elements: dataSet.elements.filter { $0.group != 0x0002 }), part10Data: source.part10)
        let listener = DicomWebHTTPListener(server: DicomWebServer(store: store))
        let root = try await listener.start()
        defer { Task { await listener.stop() } }
        let client = DicomWebClient(configuration: .init(baseURL: root.appendingPathComponent("dicom-web")))
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("clinical-path-net-\(UUID().uuidString).dcm")
        try source.part10.write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var results: [ClinicalPathWorkloadResult] = []
        for workload in manifest.workloads where workload.collector == "dicom-clinical-path-network-workloads" {
            switch workload.stage {
            case "network-retrieve":
                results += try await run(workload, manifest: manifest, fixture: source.fixture) {
                    let object = try await client.retrieveInstance(studyInstanceUID: study, seriesInstanceUID: series, sopInstanceUID: instance)
                    let payload = object.parts.first?.body ?? Data()
                    let observed = payload.isEmpty ? "empty" : (try await DCMDecoder(data: payload)).dataSet.string(for: .sopInstanceUID) ?? "no-uid"
                    return Outcome(correctness: .exact(expected: instance, observed: observed, comparison: "retrieved object SOP Instance UID (status \(object.statusCode))"),
                                   work: ClinicalPathWork(networkBytesReceived: UInt64(payload.count), pixelsProcessed: nil, frames: 1))
                }
            case "network-store":
                results += try await run(workload, manifest: manifest, fixture: source.fixture) {
                    let result = try await client.storeInstances(files: [scratch])
                    let stored = store.allInstances().first { $0.sopInstanceUID == instance }
                    return Outcome(correctness: .exact(expected: "1 accepted " + source.fixture.sha256, observed: "\(result.acceptedInstanceCount) accepted " + (stored.map { ClinicalPathMeasurer.sha256($0.part10Data) } ?? "missing"),
                                                       comparison: "STOW accepted count and stored bytes"),
                                   work: ClinicalPathWork(networkBytesSent: UInt64(source.part10.count), frames: 1))
                }
            default: XCTFail("unexpected network stage \(workload.stage)")
            }
        }
        let environment = ClinicalPathEnvironment.current(tier: "pr-smoke", buildConfiguration: Self.buildConfiguration, toolkitVersion: "DICOM-Swift (in-process XCTest)",
                                                          manifestSHA256: loaded.sha256, corpusSHA256: corpus.corpusSHA256)
        let report = ClinicalPathReport(collector: "dicom-clinical-path-network-workloads", environment: environment, noisePolicy: manifest.noisePolicy, workloads: results)
        if let outputPath = ProcessInfo.processInfo.environment["CLINICAL_PERFORMANCE_OUTPUT_DIR"] {
            try report.write(stem: "dicom-clinical-path-network-workloads", to: URL(fileURLWithPath: outputPath, isDirectory: true))
        }
        try ClinicalPathReportValidator.validate(report, requirements: manifest.requirements(for: "dicom-clinical-path-network-workloads"))
        let failures = report.workloads.filter { $0.verdict == .failure }
        XCTAssertTrue(failures.isEmpty, failures.map { "\($0.id)@\($0.mode.rawValue): \($0.verdictReason)" }.joined(separator: "\n"))
        XCTAssertTrue(report.workloads.contains { $0.stage == "network-retrieve" && ($0.work?.networkBytesReceived ?? 0) >= UInt64(source.part10.count) })
    }

    private static var buildConfiguration: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }
}
