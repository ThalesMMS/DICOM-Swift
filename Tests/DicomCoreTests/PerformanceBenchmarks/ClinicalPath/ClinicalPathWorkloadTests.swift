import CoreGraphics
import DicomTestSupport
import Foundation
import ImageIO
import XCTest
@testable import DicomCore

/// Executes the clinical-path workload manifest (#2367) on the deterministic synthetic corpus: open/metadata, bytes read,
/// decode (native and own codecs), normalisation (CPU and Metal), first frame, final refinement, measurement, export,
/// storage and a concurrent decode/transcode workload, in cold, prewarmed, isolated, sustained and concurrent modes.
/// Correctness is checked on every sample; results are written as the `dicom-clinical-path-workloads` triplet plus the
/// standard `dicom-clinical-path-performance` triplet when `CLINICAL_PERFORMANCE_OUTPUT_DIR` is set.
final class ClinicalPathWorkloadTests: XCTestCase {
    nonisolated(unsafe) private static var coldStagesSeen: Set<String> = []
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("clinical-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    struct Outcome {
        var correctness: ClinicalPathCorrectness
        var work: ClinicalPathWork
    }

    private func loadManifest() throws -> (ClinicalPathWorkloadManifest, String) {
        let loaded = try ClinicalPathWorkloadManifest.load()
        return (loaded.manifest, loaded.sha256)
    }

    /// Runs one workload through the requested modes. The first call of a stage in this process is the cold sample;
    /// the next call is the prewarmed first clinical call; warm-isolated is one sample after warmups; sustained is N samples.
    private func run(_ workload: ClinicalPathWorkloadManifest.Workload, manifest: ClinicalPathWorkloadManifest, fixture: ClinicalPathFixture, gpu: Bool = false,
                     operation: () async throws -> Outcome) async throws -> [ClinicalPathWorkloadResult] {
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
            let outcome = last!
            let pixels = outcome.work.pixelsProcessed.map(Double.init)
            let statistics = try ClinicalPathStatistics(samples: samples.map(\.seconds), workUnitsPerSample: pixels, throughputUnit: pixels == nil ? nil : "pixels/s")
            return ClinicalPathWorkloadResult(id: workload.id, stage: workload.stage, mode: mode, fixture: fixture, parameters: ["description": workload.description, "budgetScale": Self.buildConfiguration == "debug" ? String(manifest.debugBudgetMultiplier) : "1"],
                                              warmupIterations: warmups, iterations: count, correctness: worst ?? outcome.correctness, statistics: statistics,
                                              work: outcome.work, resources: ClinicalPathMeasurer.resources(samples: samples, gpuUsed: gpu), budget: manifest.budget(for: workload, buildConfiguration: Self.buildConfiguration))
        }
        for mode in workload.modes {
            switch mode {
            case .coldSDKFirstCall:
                if Self.coldStagesSeen.insert(workload.stage).inserted {
                    results.append(try await single(mode: mode, warmups: 0, count: 1))
                } else {
                    results.append(.notExecuted(id: workload.id, stage: workload.stage, mode: mode, reason: "stage \(workload.stage) already ran in this process; cold sample belongs to the first workload of the stage", fixture: fixture))
                }
            case .prewarmedFirstClinicalCall: results.append(try await single(mode: mode, warmups: 0, count: 1))
            case .warmIsolated: results.append(try await single(mode: mode, warmups: workload.warmupIterations, count: 1))
            case .warmSustained: results.append(try await single(mode: mode, warmups: workload.warmupIterations, count: workload.iterations))
            case .concurrentClinicalWorkload: results.append(try await single(mode: mode, warmups: workload.warmupIterations, count: workload.iterations))
            case .fallbackPath:
                results.append(.notExecuted(id: workload.id, stage: workload.stage, mode: mode, reason: "fallback routes are measured by the dicom-j2k/dicom-jpegls collectors", fixture: fixture))
            }
        }
        return results
    }

    private static func decodedBytes(_ frame: DicomDecodedFrame) -> Data {
        switch frame.pixels {
        case .gray8(let pixels): return Data(pixels)
        case .gray16(let pixels): return pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        case .rgb8(let interleaved): return Data(interleaved)
        }
    }

    private static func pngSize(_ url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "undecodable" }
        return "\(image.width)x\(image.height)"
    }

    func test_clinicalPathWorkloads_measureEveryStageWithCorrectnessFirst() async throws {
        let (manifest, manifestSHA) = try loadManifest()
        let corpus = try await ClinicalPathSyntheticCorpus.generate()
        for object in corpus.objects {
            XCTAssertEqual(manifest.fixture(object.fixture.id)?.sha256, object.fixture.sha256, "corpus digest drift for \(object.fixture.id)")
        }
        func object(_ id: String) throws -> ClinicalPathSyntheticCorpus.Object { try XCTUnwrap(corpus.objects.first { $0.fixture.id == id }, id) }
        var results: [ClinicalPathWorkloadResult] = []
        let metalAvailable = MetalWindowingProcessor.isMetalAvailable
        var vdspDigest: String?

        for workload in manifest.workloads where workload.collector == "dicom-clinical-path-workloads" {
            let source = try object(workload.fixtureID)
            if workload.requires.contains("metalDevice"), !metalAvailable {
                for mode in workload.modes {
                    results.append(.notExecuted(id: workload.id, stage: workload.stage, mode: mode, reason: "no Metal device on this host; GPU stage not executed (no estimate)", fixture: source.fixture))
                }
                continue
            }
            let file = scratch.appendingPathComponent(workload.id + ".dcm")
            try source.part10.write(to: file)
            switch workload.stage {
            case "open-metadata":
                results += try await run(workload, manifest: manifest, fixture: source.fixture) {
                    let byteSource = try await DicomByteSource.openFile(file, storage: .buffer)
                    let metadata = try await DicomSourceMetadata.readPart10(from: byteSource, maximumMetadataBytes: 4 * 1024 * 1024)
                    let expected = "\(source.fixture.geometry) sop \(source.part10.count >= 0 ? "2.25.2367" : "")"
                    let observed = "\(metadata.dataSet.int(for: .columns) ?? 0)x\(metadata.dataSet.int(for: .rows) ?? 0)x\(max(1, metadata.dataSet.int(for: 0x0028_0008) ?? 1)) sop \(String((metadata.dataSet.string(for: .sopInstanceUID) ?? "").prefix(9)))"
                    var correctness = ClinicalPathCorrectness.exact(expected: expected, observed: observed, comparison: "geometry and SOP Instance UID root from the header")
                    if source.frames > 1, metadata.metadataCopiedBytes >= source.part10.count { correctness = .exact(expected: "bounded", observed: "unbounded", comparison: "metadata bytes copied must stay below the pixel payload") }
                    return Outcome(correctness: correctness, work: ClinicalPathWork(bytesRead: UInt64(metadata.metadataCopiedBytes), frames: source.frames))
                }
            case "decode":
                results += try await run(workload, manifest: manifest, fixture: source.fixture) {
                    let decoder = try await DCMDecoder(contentsOf: file)
                    let reader = DicomDecodedFrameReader(decoder: decoder)
                    var digest = Data()
                    for index in 0..<reader.frameCount {
                        let frame = try await reader.frame(at: index)
                        digest.append(Self.decodedBytes(frame))
                    }
                    return Outcome(correctness: .exact(expected: source.expectedPixelSHA256, observed: ClinicalPathMeasurer.sha256(digest), comparison: "SHA-256 of decoded samples versus the generator"),
                                   work: ClinicalPathWork(bytesRead: UInt64(source.part10.count), pixelsProcessed: UInt64(source.columns * source.rows * source.frames), frames: source.frames))
                }
            case "normalize":
                let normalizeDecoder = try await DCMDecoder(contentsOf: file)
                let pixels = try XCTUnwrap(normalizeDecoder.getPixels16())
                results += try await run(workload, manifest: manifest, fixture: source.fixture) {
                    let output = try XCTUnwrap(DCMWindowingProcessor.applyWindowLevel(pixels16: pixels, center: 40, width: 400, processingMode: .vdsp))
                    let digest = ClinicalPathMeasurer.sha256(output)
                    if vdspDigest == nil { vdspDigest = digest }
                    return Outcome(correctness: .exact(expected: "\(output.count) bytes " + (vdspDigest ?? digest), observed: "\(source.columns * source.rows) bytes " + digest, comparison: "stable 8-bit output of the same build"),
                                   work: ClinicalPathWork(pixelsProcessed: UInt64(pixels.count)))
                }
            case "gpu-normalize":
                let gpuDecoder = try await DCMDecoder(contentsOf: file)
                let pixels = try XCTUnwrap(gpuDecoder.getPixels16())
                let reference = try XCTUnwrap(DCMWindowingProcessor.applyWindowLevel(pixels16: pixels, center: 40, width: 400, processingMode: .vdsp))
                results += try await run(workload, manifest: manifest, fixture: source.fixture, gpu: true) {
                    let output = try XCTUnwrap(DCMWindowingProcessor.applyWindowLevel(pixels16: pixels, center: 40, width: 400, processingMode: .metal))
                    var maxError = 0.0
                    for index in 0..<min(output.count, reference.count) { maxError = max(maxError, abs(Double(output[index]) - Double(reference[index]))) }
                    return Outcome(correctness: .numeric(expected: 0, observed: maxError, tolerance: 1, comparison: "max |metal - vdsp| per pixel"), work: ClinicalPathWork(pixelsProcessed: UInt64(pixels.count)))
                }
            case "first-frame", "final-refine", "export":
                let size = workload.stage == "first-frame" ? 64 : source.columns
                let expected = "\(size)x\(size)"
                results += try await run(workload, manifest: manifest, fixture: source.fixture) {
                    let target = self.scratch.appendingPathComponent(workload.id + ".png")
                    let decoder = try await DCMDecoder(contentsOf: file)
                    let options = DicomImageExportOptions(format: .png, overwrite: true, outputSize: workload.stage == "first-frame" ? DicomImageSize(width: 64, height: 64) : nil)
                    let result = try DicomImageExporter().export(decoder: decoder, frame: 0, to: target, options: options)
                    let bytes = (try? Data(contentsOf: result.imageURL).count) ?? 0
                    return Outcome(correctness: .exact(expected: expected, observed: Self.pngSize(result.imageURL), comparison: "PNG decodes to the expected size"),
                                   work: ClinicalPathWork(bytesRead: UInt64(source.part10.count), bytesWritten: UInt64(bytes), pixelsProcessed: UInt64(source.columns * source.rows)))
                }
            case "measure":
                let decoder = try await DCMDecoder(contentsOf: file)
                let frame = try await DicomDecodedFrameReader(decoder: decoder).frame(at: 0)
                var sum = 0.0
                if case .gray16(let pixels) = frame.pixels { for value in pixels { sum += Double(value) } }
                let analyticMean = sum / Double(source.columns * source.rows)
                results += try await run(workload, manifest: manifest, fixture: source.fixture) {
                    let statistics = try DicomPixelMeasurement.statistics(frame: frame)
                    return Outcome(correctness: .numeric(expected: analyticMean, observed: statistics.mean, tolerance: 1e-6, comparison: "mean versus the direct sum of the generated samples"),
                                   work: ClinicalPathWork(pixelsProcessed: UInt64(statistics.sampleCount)))
                }
            case "storage":
                let sourceDecoder = try await DCMDecoder(data: source.part10)
                let expectedUID = sourceDecoder.dataSet.string(for: .sopInstanceUID) ?? ""
                results += try await run(workload, manifest: manifest, fixture: source.fixture) {
                    let target = self.scratch.appendingPathComponent(workload.id + "-" + UUID().uuidString + ".dcm")
                    try source.part10.write(to: target, options: .atomic)
                    let byteSource = try await DicomByteSource.openFile(target, storage: .buffer)
                    let metadata = try await DicomSourceMetadata.readPart10(from: byteSource, maximumMetadataBytes: 1024 * 1024)
                    try? FileManager.default.removeItem(at: target)
                    return Outcome(correctness: .exact(expected: expectedUID, observed: metadata.dataSet.string(for: .sopInstanceUID) ?? "", comparison: "SOP Instance UID after reopen"),
                                   work: ClinicalPathWork(bytesRead: UInt64(metadata.metadataCopiedBytes), bytesWritten: UInt64(source.part10.count)))
                }
            case "concurrent":
                let data = source.part10
                results += try await run(workload, manifest: manifest, fixture: source.fixture) {
                    try await withThrowingTaskGroup(of: String.self) { group in
                        for _ in 0..<4 {
                            group.addTask {
                                let decoder = try await DCMDecoder(data: data)
                                let frame = try await DicomDecodedFrameReader(decoder: decoder).frame(at: 0)
                                return ClinicalPathMeasurer.sha256(Self.decodedBytes(frame))
                            }
                        }
                        group.addTask {
                            let transcoded = try DicomTranscoder().transcode(data, to: .jpegLSLossless)
                            let transcodedDecoder = try await DCMDecoder(data: transcoded)
                            let frame = try await DicomDecodedFrameReader(decoder: transcodedDecoder).frame(at: 0)
                            return ClinicalPathMeasurer.sha256(Self.decodedBytes(frame))
                        }
                        var digests: [String] = []
                        for try await digest in group { digests.append(digest) }
                        let observed = Set(digests).count == 1 ? digests[0] : "divergent"
                        return Outcome(correctness: .exact(expected: source.expectedPixelSHA256, observed: observed, comparison: "all five concurrent results share the generator digest"),
                                       work: ClinicalPathWork(bytesRead: UInt64(data.count * 5), pixelsProcessed: UInt64(source.columns * source.rows * 5)))
                    }
                }
            default:
                XCTFail("unknown stage \(workload.stage) in the manifest")
            }
        }

        let environment = ClinicalPathEnvironment.current(tier: "pr-smoke", buildConfiguration: Self.buildConfiguration, toolkitVersion: "DICOM-Swift (in-process XCTest)",
                                                          manifestSHA256: manifestSHA, corpusSHA256: corpus.corpusSHA256)
        let report = ClinicalPathReport(collector: "dicom-clinical-path-workloads", environment: environment, noisePolicy: manifest.noisePolicy, workloads: results,
                                        externalCollectors: manifest.externalCollectors)
        try Self.writeIfRequested(report, manifest: manifest, corpusSHA: corpus.corpusSHA256)
        for workload in report.workloads where workload.mode == .warmSustained {
            guard let statistics = workload.statistics else { continue }
            print("clinical-path \(workload.id): p50 \(String(format: "%.4f", statistics.p50Seconds)) s p95 \(String(format: "%.4f", statistics.p95Seconds)) s cv \(String(format: "%.1f", statistics.coefficientOfVariationPercent))% \(workload.verdict.rawValue)")
        }
        let requirements = manifest.requirements(for: "dicom-clinical-path-workloads")
        try ClinicalPathReportValidator.validate(report, requirements: requirements)
        let failures = report.workloads.filter { $0.verdict == .failure }
        XCTAssertTrue(failures.isEmpty, failures.map { "\($0.id)@\($0.mode.rawValue): \($0.verdictReason)" }.joined(separator: "\n"))
        XCTAssertTrue(report.workloads.contains { $0.mode == .coldSDKFirstCall && $0.status == .measured })
        XCTAssertTrue(report.workloads.contains { $0.stage == "concurrent" && $0.status == .measured })
        XCTAssertFalse(report.markdownString().contains(scratch.path), "reports never carry local paths")
        XCTAssertFalse(report.csvString().contains(scratch.path))
    }

    static var buildConfiguration: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    /// Writes the extended triplet and the standard clinical performance triplet (warm-sustained measurements).
    static func writeIfRequested(_ report: ClinicalPathReport, manifest: ClinicalPathWorkloadManifest, corpusSHA: String) throws {
        guard let outputPath = ProcessInfo.processInfo.environment["CLINICAL_PERFORMANCE_OUTPUT_DIR"] else { return }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try report.write(stem: "dicom-clinical-path-workloads", to: output)
        let platform = PlatformInfo()
        let tier = ProcessInfo.processInfo.environment["CLINICAL_PERFORMANCE_TIER"].flatMap(ClinicalPerformanceTier.init(rawValue:)) ?? .pullRequestSmoke
        let environment = ClinicalPerformanceEnvironment(deviceName: platform.modelIdentifier, osVersion: platform.osVersion, architecture: platform.architecture,
                                                         modelIdentifier: platform.modelIdentifier, buildConfiguration: buildConfiguration, benchmarkMode: .warmSustained,
                                                         fixtureID: "clinical-path-synthetic-corpus-" + String(corpusSHA.prefix(12)), tier: tier,
                                                         commandLineStartupIncluded: ProcessInfo.processInfo.environment["CLINICAL_PERFORMANCE_CLI_STARTUP"] == "true")
        var measurements: [ClinicalPerformanceMeasurement] = []
        for workload in report.workloads where workload.mode == .warmSustained && workload.status == .measured {
            guard let statistics = workload.statistics, let budget = workload.budget else { continue }
            let gate = ClinicalPerformanceGate(warningLimit: budget.warningSeconds, failureLimit: budget.failureSeconds, relativeWarningPercent: 10, relativeFailurePercent: 20, lowerIsBetter: true)
            let stats = try ClinicalPerformanceStatistics(samples: [statistics.p50Seconds, statistics.p95Seconds, statistics.p99Seconds], workUnitsPerSample: workload.work?.pixelsProcessed.map(Double.init))
            measurements.append(ClinicalPerformanceEvaluator.evaluate(metricID: workload.id, stage: workload.stage, unit: "seconds", statistics: stats,
                                                                      correctnessPassed: workload.correctness?.passed ?? true, gate: gate, environment: environment,
                                                                      work: ClinicalPerformanceWorkMetrics(usefulBytes: workload.work?.bytesRead ?? 0),
                                                                      resources: ClinicalPerformanceResourceMetrics(processCPUTimeMilliseconds: workload.resources?.processCPUSeconds.map { $0 * 1000 }, peakRSSBytes: workload.resources?.peakRSSBytes)))
        }
        let standard = ClinicalPerformanceReport(schemaVersion: 1, generatedAt: Date(), environment: environment, warmupIterations: 2, benchmarkIterations: 10,
                                                 backendFlags: ["collector": "clinical-path", "manifest": String(report.environment.manifestSHA256.prefix(12))],
                                                 conformanceManifest: "ClinicalPathWorkloadManifest.json", measurements: measurements)
        let reporter = ClinicalPerformanceReporter(report: standard)
        try Data(reporter.jsonString().utf8).write(to: output.appendingPathComponent("dicom-clinical-path-performance.json"))
        try Data(reporter.csvString().utf8).write(to: output.appendingPathComponent("dicom-clinical-path-performance.csv"))
        try Data(reporter.markdownString().utf8).write(to: output.appendingPathComponent("dicom-clinical-path-performance.md"))
    }
}
