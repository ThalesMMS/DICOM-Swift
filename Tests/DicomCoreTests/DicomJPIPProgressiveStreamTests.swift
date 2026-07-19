import Foundation
import XCTest
@testable import DicomCore
import simd

final class DicomJPIPProgressiveStreamTests: XCTestCase {
    func testReferencedPixelDataObjectLoadsWithoutLocalPixelData() throws {
        let url = try makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try makeJPIPReferencedDICOM(providerURL: "https://pacs.example.test/jpip?target=volume.jp2")
            .write(to: url)

        let decoder = try DCMDecoder(contentsOf: url)
        let reference = try DicomJPIPReferencedPixelData(decoder: decoder)

        XCTAssertEqual(reference.transferSyntax, .jpipReferenced)
        XCTAssertEqual(reference.pixelDataProviderURL.absoluteString, "https://pacs.example.test/jpip?target=volume.jp2")
        XCTAssertEqual(reference.makeVolumeRequest().resource, .volume)
    }

    func testJPIPClientYieldsProgressiveVolumeUpdatesInOrder() async throws {
        let request = DicomJPIPRequest(
            pixelDataProviderURL: try XCTUnwrap(URL(string: "https://pacs.example.test/jpip?target=volume.jp2")),
            resource: .volume
        )
        let payloads = [
            makePayload(index: 0, quality: .preview, fraction: 0.25, final: false, voxelValue: 10),
            makePayload(index: 1, quality: .refinement, fraction: 0.75, final: false, voxelValue: 20),
            makePayload(index: 2, quality: .final, fraction: 1.0, final: true, voxelValue: 30)
        ]
        let client = DicomJPIPClient(
            transport: FakeJPIPTransport(payloads: payloads),
            bufferingPolicy: .unbounded
        )

        var received: [DicomProgressiveVolumeUpdate] = []
        for try await update in client.volumeUpdates(for: request, decode: { payload in
            try await Self.decodeSyntheticVolume(payload)
        }) {
            received.append(update)
        }

        XCTAssertEqual(received.map(\.layer.index), [0, 1, 2])
        XCTAssertEqual(received.map(\.layer.quality), [.preview, .refinement, .final])
        XCTAssertEqual(received.last?.layer.isFinal, true)
        XCTAssertEqual(try firstVoxelValue(in: try XCTUnwrap(received.last?.volume)), 30)
    }

    func testJPIPClientCancelsTransportWhenConsumerIsCancelled() async throws {
        let request = DicomJPIPRequest(
            pixelDataProviderURL: try XCTUnwrap(URL(string: "https://pacs.example.test/jpip?target=volume.jp2")),
            resource: .volume
        )
        let probe = TerminationProbe()
        var payloads: [DicomJPIPLayerPayload] = []
        for index in 0..<20 {
            let isFinal = index == 19
            payloads.append(
                makePayload(index: index,
                            quality: isFinal ? .final : .refinement,
                            fraction: Double(index + 1) / 20.0,
                            final: isFinal,
                            voxelValue: UInt8(index))
            )
        }
        let client = DicomJPIPClient(
            transport: FakeJPIPTransport(payloads: payloads, delayNanoseconds: 5_000_000, probe: probe)
        )
        let stream = client.volumeUpdates(for: request, decode: { payload in
            try await Self.decodeSyntheticVolume(payload)
        })

        let task = Task {
            for try await _ in stream {
                try Task.checkCancellation()
            }
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        _ = try? await task.value

        let didTerminate = await probe.waitUntilTerminated()
        XCTAssertTrue(didTerminate)
    }

    func testJPIPPerformanceReportSeparatesPreviewFinalAndByteAccounting() async throws {
        let layerCount = 12
        let bytesPerLayer = 256
        let request = DicomJPIPRequest(
            pixelDataProviderURL: try XCTUnwrap(URL(string: "https://pacs.example.test/jpip?target=volume.jp2")),
            resource: .volume
        )
        let payloads = (0..<layerCount).map { index in
            let isFinal = index == layerCount - 1
            return makePayload(
                index: index,
                quality: index == 0 ? .preview : (isFinal ? .final : .refinement),
                fraction: Double(index + 1) / Double(layerCount),
                final: isFinal,
                voxelValue: UInt8(index),
                byteCount: bytesPerLayer
            )
        }
        let decodeProbe = JPIPTimingProbe()
        let client = DicomJPIPClient(
            transport: FakeJPIPTransport(payloads: payloads, delayNanoseconds: 250_000),
            bufferingPolicy: .unbounded
        )

        let start = DispatchTime.now().uptimeNanoseconds
        var previous = start
        var layerSeconds = [Double]()
        var received = [DicomProgressiveVolumeUpdate]()
        var firstVisibleSeconds: Double?
        for try await update in client.volumeUpdates(for: request, decode: { payload in
            let decodeStart = DispatchTime.now().uptimeNanoseconds
            let volume = try await Self.decodeSyntheticVolume(payload)
            await decodeProbe.append(Double(DispatchTime.now().uptimeNanoseconds - decodeStart) / 1_000_000_000)
            return volume
        }) {
            let now = DispatchTime.now().uptimeNanoseconds
            layerSeconds.append(Double(now - previous) / 1_000_000_000)
            previous = now
            if firstVisibleSeconds == nil {
                firstVisibleSeconds = Double(now - start) / 1_000_000_000
            }
            received.append(update)
        }
        let finalSeconds = Double(previous - start) / 1_000_000_000
        let decodeSeconds = await decodeProbe.values
        let receiveSeconds = zip(layerSeconds, decodeSeconds).map { pair in max(0, pair.0 - pair.1) }

        XCTAssertEqual(received.map(\.layer.index), Array(0..<layerCount))
        XCTAssertEqual(received.first?.layer.quality, .preview)
        XCTAssertEqual(received.last?.layer.quality, .final)
        XCTAssertEqual(received.last?.layer.isFinal, true)

        let environment = Self.performanceEnvironment()
        let gate = ClinicalPerformanceGate(
            warningLimit: 0.050,
            failureLimit: 0.100,
            relativeWarningPercent: 10,
            relativeFailurePercent: 20,
            lowerIsBetter: true
        )
        let work = ClinicalPerformanceWorkMetrics(
            usefulBytes: UInt64(layerCount * bytesPerLayer),
            discardedBytes: UInt64((layerCount - 1) * bytesPerLayer),
            provisionalToFinalTransitions: 1
        )
        let resources = ClinicalPerformanceResourceMetrics(
            peakRSSBytes: BenchmarkMemorySampler.currentPeakResidentMemoryBytes(),
            temporaryFileIOBytes: 0
        )
        let statistics: [(String, String, ClinicalPerformanceStatistics)] = [
            ("jpip-layer-receive", "jpip-layer-receive", try ClinicalPerformanceStatistics(samples: receiveSeconds)),
            ("jpip-layer-decode", "jpip-layer-decode", try ClinicalPerformanceStatistics(samples: decodeSeconds)),
            ("jpip-first-visible-frame", "preview-frame", try ClinicalPerformanceStatistics(samples: [try XCTUnwrap(firstVisibleSeconds)])),
            ("jpip-final-frame", "final-frame", try ClinicalPerformanceStatistics(samples: [finalSeconds]))
        ]
        let measurements = statistics.map { metric in
            ClinicalPerformanceEvaluator.evaluate(
                metricID: metric.0,
                stage: metric.1,
                unit: "seconds",
                statistics: metric.2,
                correctnessPassed: true,
                gate: gate,
                environment: environment,
                work: work,
                resources: resources
            )
        }
        XCTAssertFalse(measurements.contains { $0.verdict == .failure })

        let report = ClinicalPerformanceReport(
            schemaVersion: 1,
            generatedAt: Date(),
            environment: environment,
            warmupIterations: 1,
            benchmarkIterations: layerCount,
            backendFlags: ["transport": "injected-jpip", "decoder": "synthetic-volume"],
            conformanceManifest: "ClinicalCodecConformanceManifest.json",
            measurements: measurements
        )
        try Self.writePerformanceReportIfRequested(report)
        print(
            String(
                format: "JPIP_PERF receive_p95_ms=%.3f decode_p95_ms=%.3f "
                    + "first_visible_ms=%.3f final_ms=%.3f useful_bytes=%llu "
                    + "discarded_bytes=%llu preview_final=1",
                try ClinicalPerformanceStatistics(samples: receiveSeconds).p95 * 1_000,
                try ClinicalPerformanceStatistics(samples: decodeSeconds).p95 * 1_000,
                try XCTUnwrap(firstVisibleSeconds) * 1_000,
                finalSeconds * 1_000,
                work.usefulBytes,
                work.discardedBytes
            )
        )
    }

    private func makePayload(index: Int,
                             quality: DicomProgressiveUpdateQuality,
                             fraction: Double,
                             final: Bool,
                             voxelValue: UInt8,
                             byteCount: Int = 1) -> DicomJPIPLayerPayload {
        DicomJPIPLayerPayload(
            layer: DicomProgressiveLayer(
                index: index,
                totalLayerCount: 3,
                quality: quality,
                byteRange: index..<(index + 1),
                fractionComplete: fraction,
                isFinal: final
            ),
            data: Data(repeating: voxelValue, count: byteCount)
        )
    }

    private static func performanceEnvironment() -> ClinicalPerformanceEnvironment {
        let platform = PlatformInfo()
        let processEnvironment = ProcessInfo.processInfo.environment
        return ClinicalPerformanceEnvironment(
            deviceName: platform.modelIdentifier,
            osVersion: platform.osVersion,
            architecture: platform.architecture,
            modelIdentifier: platform.modelIdentifier,
            buildConfiguration: {
#if DEBUG
                "debug"
#else
                "release"
#endif
            }(),
            benchmarkMode: .prewarmedFirstClinicalCall,
            fixtureID: "ct-explicit-vr-le-rescale",
            tier: processEnvironment["CLINICAL_PERFORMANCE_TIER"]
                .flatMap(ClinicalPerformanceTier.init(rawValue:)) ?? .pullRequestSmoke,
            commandLineStartupIncluded: processEnvironment["CLINICAL_PERFORMANCE_CLI_STARTUP"] == "true"
        )
    }

    private static func writePerformanceReportIfRequested(_ report: ClinicalPerformanceReport) throws {
        guard let outputPath = ProcessInfo.processInfo.environment["CLINICAL_PERFORMANCE_OUTPUT_DIR"] else {
            return
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let reporter = ClinicalPerformanceReporter(report: report)
        try Data(reporter.jsonString().utf8).write(to: output.appendingPathComponent("dicom-jpip-performance.json"))
        try Data(reporter.csvString().utf8).write(to: output.appendingPathComponent("dicom-jpip-performance.csv"))
        try Data(reporter.markdownString().utf8).write(to: output.appendingPathComponent("dicom-jpip-performance.md"))
    }

    private static func decodeSyntheticVolume(_ payload: DicomJPIPLayerPayload) async throws -> DicomSeriesVolume {
        await Task.yield()
        let voxel = UInt16(payload.data.first ?? 0)
        let voxels = [voxel, voxel, voxel, voxel].withUnsafeBytes { Data($0) }
        return DicomSeriesVolume(
            voxels: voxels,
            width: 2,
            height: 2,
            depth: 1,
            spacing: SIMD3<Double>(1, 1, 1),
            orientation: matrix_identity_double3x3,
            origin: SIMD3<Double>(0, 0, 0),
            rescaleSlope: 1,
            rescaleIntercept: 0,
            bitsAllocated: 16,
            isSignedPixel: false,
            seriesDescription: "Progressive JPIP fixture",
            modality: "CT"
        )
    }

    private func firstVoxelValue(in volume: DicomSeriesVolume) throws -> UInt16 {
        try XCTUnwrap(volume.voxels.withUnsafeBytes { buffer in
            buffer.bindMemory(to: UInt16.self).first
        })
    }

    private func makeTemporaryFileURL() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DicomJPIPProgressiveStreamTests-\(UUID().uuidString).dcm")
    }

    private func makeJPIPReferencedDICOM(providerURL: String) -> Data {
        var data = Data(repeating: 0, count: 128)
        data.append(contentsOf: "DICM".utf8)
        appendTag(&data, group: 0x0002, element: 0x0010, vr: "UI", value: DicomTransferSyntax.jpipReferenced.rawValue)
        appendTag(&data, group: 0x0028, element: 0x0002, vr: "US", value: UInt16(1))
        appendTag(&data, group: 0x0028, element: 0x0004, vr: "CS", value: "MONOCHROME2")
        appendTag(&data, group: 0x0028, element: 0x0010, vr: "US", value: UInt16(2))
        appendTag(&data, group: 0x0028, element: 0x0011, vr: "US", value: UInt16(2))
        appendTag(&data, group: 0x0028, element: 0x0100, vr: "US", value: UInt16(16))
        appendTag(&data, group: 0x0028, element: 0x0101, vr: "US", value: UInt16(16))
        appendTag(&data, group: 0x0028, element: 0x0102, vr: "US", value: UInt16(15))
        appendTag(&data, group: 0x0028, element: 0x0103, vr: "US", value: UInt16(0))
        appendTag(&data, group: 0x0028, element: 0x7FE0, vr: "UR", value: providerURL)
        return data
    }

    private func appendTag(_ data: inout Data, group: UInt16, element: UInt16, vr: String, value: String) {
        var bytes = Data(value.utf8)
        if bytes.count % 2 != 0 {
            bytes.append(0x20)
        }
        appendTagHeader(&data, group: group, element: element, vr: vr, length: UInt32(bytes.count))
        data.append(bytes)
    }

    private func appendTag(_ data: inout Data, group: UInt16, element: UInt16, vr: String, value: UInt16) {
        var value = value.littleEndian
        appendTagHeader(&data, group: group, element: element, vr: vr, length: 2)
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private func appendTagHeader(_ data: inout Data,
                                 group: UInt16,
                                 element: UInt16,
                                 vr: String,
                                 length: UInt32) {
        var littleGroup = group.littleEndian
        var littleElement = element.littleEndian
        data.append(Data(bytes: &littleGroup, count: 2))
        data.append(Data(bytes: &littleElement, count: 2))
        data.append(contentsOf: vr.utf8)
        if ["OB", "OW", "OV", "SQ", "UN", "UR", "UT"].contains(vr) {
            data.append(contentsOf: [0x00, 0x00])
            var littleLength = length.littleEndian
            data.append(Data(bytes: &littleLength, count: 4))
        } else {
            var shortLength = UInt16(length).littleEndian
            data.append(Data(bytes: &shortLength, count: 2))
        }
    }
}

private actor JPIPTimingProbe {
    private(set) var values = [Double]()

    func append(_ value: Double) {
        values.append(value)
    }
}

private struct FakeJPIPTransport: DicomJPIPTransport {
    let payloads: [DicomJPIPLayerPayload]
    var delayNanoseconds: UInt64 = 0
    var probe: TerminationProbe?

    func payloads(for request: DicomJPIPRequest) -> AsyncThrowingStream<DicomJPIPLayerPayload, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for payload in self.payloads {
                        try Task.checkCancellation()
                        if delayNanoseconds > 0 {
                            try await Task.sleep(nanoseconds: delayNanoseconds)
                        }
                        continuation.yield(payload)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                if let probe {
                    Task {
                        await probe.markTerminated()
                    }
                }
            }
        }
    }
}

private actor TerminationProbe {
    private var terminated = false

    func markTerminated() {
        terminated = true
    }

    func waitUntilTerminated() async -> Bool {
        for _ in 0..<100 {
            if terminated {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return terminated
    }
}
