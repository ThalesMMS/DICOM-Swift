import Foundation
import JPEGLS
import XCTest
@testable import DicomCore

final class DicomJLSwiftBackendTests: XCTestCase {
    func test_rolloutModeParsesEveryPolicyAndDefaultsToShadow() {
        XCTAssertEqual(DicomJLSwiftRolloutMode(environment: [:]), .shadow)
        for mode in DicomJLSwiftRolloutMode.allCases {
            XCTAssertEqual(
                DicomJLSwiftRolloutMode(environment: [
                    DicomJLSwiftRolloutMode.environmentKey: mode.rawValue
                ]),
                mode
            )
        }
        XCTAssertEqual(
            DicomJLSwiftRolloutMode(environment: [
                DicomJLSwiftRolloutMode.environmentKey: "unknown"
            ]),
            .shadow
        )
    }

    func test_capabilitiesExposePackageLinkedDecodeAndEncodeQualification() {
        let capability = DicomJLSwiftBackend().capabilities

        XCTAssertEqual(capability.identifier, .jlSwift)
        XCTAssertEqual(capability.version, "0.9.0")
        XCTAssertEqual(capability.source, .packageLinked)
        XCTAssertEqual(capability.operations, [.decode, .encode])
        XCTAssertEqual(capability.supportedGrayscaleBitDepths, 8...16)
        XCTAssertEqual(capability.supportedColorBitDepths, 8...8)
        XCTAssertEqual(capability.transferSyntaxUIDs, DicomJLSwiftBackend.transferSyntaxes)
        XCTAssertEqual(capability.encodeTransferSyntaxUIDs, DicomJLSwiftBackend.transferSyntaxes)
    }

    func test_losslessGrayscaleCrossDecodesWithCharLSAcrossStoredDepths() async throws {
        try requireCharLS()
        for bitsStored in [8, 10, 12, 14, 16] {
            do {
                let descriptor = Self.descriptor(bitsStored: bitsStored)
                let source = Self.grayscaleBytes(width: 7, height: 5, bitsStored: bitsStored)
                let request = Self.encodeRequest(
                    bytes: source,
                    descriptor: descriptor,
                    intent: .reversible
                )

                let jlSwiftEncoded = try await DicomJLSwiftBackend().encode(request)
                let charLSDecoded = try DicomJPEGLSCodec.decode(jlSwiftEncoded)
                XCTAssertEqual(charLSDecoded.bytes, source, "JLSwift -> CharLS at \(bitsStored) bits")

                let charLSEncoded = try DicomJPEGLSCodec.encodeForTesting(
                    bytes: source,
                    width: descriptor.columns,
                    height: descriptor.rows,
                    bitsPerSample: bitsStored
                )
                let jlSwiftDecoded = try await DicomJLSwiftBackend().decode(
                    Self.decodeRequest(frameData: charLSEncoded, descriptor: descriptor)
                )
                XCTAssertEqual(jlSwiftDecoded.buffer.data, source, "CharLS -> JLSwift at \(bitsStored) bits")
            } catch {
                XCTFail("Cross-library qualification failed at \(bitsStored) stored bits: \(error)")
            }
        }
    }

    func test_nearLosslessCrossDecodeRespectsExplicitNearBound() async throws {
        try requireCharLS()
        let near = 3
        let descriptor = Self.descriptor(
            transferSyntax: .jpegLSNearLossless,
            width: 11,
            height: 7,
            bitsStored: 8
        )
        let source = Self.grayscaleBytes(width: 11, height: 7, bitsStored: 8)
        let request = Self.encodeRequest(
            bytes: source,
            descriptor: descriptor,
            intent: .jpegLSNearLossless(near: near)
        )

        let jlSwiftEncoded = try await DicomJLSwiftBackend().encode(request)
        let charLSDecoded = try DicomJPEGLSCodec.decode(jlSwiftEncoded)
        Self.assertNear(source, charLSDecoded.bytes, near: near)

        let charLSEncoded = try DicomJPEGLSCodec.encodeForTesting(
            bytes: source,
            width: descriptor.columns,
            height: descriptor.rows,
            bitsPerSample: 8,
            nearLossless: near
        )
        let jlSwiftDecoded = try await DicomJLSwiftBackend().decode(
            Self.decodeRequest(frameData: charLSEncoded, descriptor: descriptor)
        )
        Self.assertNear(source, jlSwiftDecoded.buffer.data, near: near)
    }

    func test_rgbInterleaveModesAndPlanarMetadataNormalizeWithCharLS() async throws {
        try requireCharLS()
        var source = Data(capacity: 5 * 3 * 3)
        var red: [Int] = []
        var green: [Int] = []
        var blue: [Int] = []
        for index in 0..<(5 * 3) {
            let samples = [index * 11, 255 - index * 7, index * 3]
            source.append(contentsOf: samples.map(UInt8.init))
            red.append(samples[0])
            green.append(samples[1])
            blue.append(samples[2])
        }
        let image = try MultiComponentImageData.rgb(
            redPixels: Self.rows(from: red, width: 5),
            greenPixels: Self.rows(from: green, width: 5),
            bluePixels: Self.rows(from: blue, width: 5),
            bitsPerSample: 8
        )

        for interleaveMode in [JPEGLSInterleaveMode.none, .line, .sample] {
            let encoded = try JPEGLSEncoder().encode(
                image,
                configuration: JPEGLSEncoder.Configuration(interleaveMode: interleaveMode)
            )
            let charLSDecoded = try DicomJPEGLSCodec.decode(encoded)
            XCTAssertEqual(
                Array(charLSDecoded.bytes),
                Array(source),
                "CharLS interleave mode \(interleaveMode)"
            )

            for planarConfiguration in [0, 1] {
                let descriptor = Self.descriptor(
                    width: 5,
                    height: 3,
                    bitsStored: 8,
                    samplesPerPixel: 3,
                    photometric: "RGB",
                    planarConfiguration: planarConfiguration
                )
                let jlSwiftDecoded = try await DicomJLSwiftBackend().decode(
                    Self.decodeRequest(frameData: encoded, descriptor: descriptor)
                )
                XCTAssertEqual(
                    jlSwiftDecoded.buffer.data,
                    source,
                    "JLSwift interleave mode \(interleaveMode), Planar Configuration \(planarConfiguration)"
                )
            }
        }

        let descriptor = Self.descriptor(
            width: 5,
            height: 3,
            bitsStored: 8,
            samplesPerPixel: 3,
            photometric: "RGB",
            planarConfiguration: 0
        )
        let jlSwiftEncoded = try await DicomJLSwiftBackend().encode(
            Self.encodeRequest(bytes: source, descriptor: descriptor, intent: .reversible)
        )
        XCTAssertEqual(try DicomJPEGLSCodec.decode(jlSwiftEncoded).bytes, source)
    }

    func test_signedGrayscalePreservesStoredBitPatterns() async throws {
        let descriptor = Self.descriptor(bitsStored: 12, signed: true)
        let stored: [UInt16] = [0x0800, 0x0FFF, 0x0000, 0x0001, 0x07FF]
            + Array(repeating: 0x0A55, count: 30)
        let source = Self.littleEndianData(stored)
        let encoded = try await DicomJLSwiftBackend().encode(
            Self.encodeRequest(bytes: source, descriptor: descriptor, intent: .reversible)
        )
        let decoded = try await DicomJLSwiftBackend().decode(
            Self.decodeRequest(frameData: encoded, descriptor: descriptor)
        )
        let signExtended: [UInt16] = [0xF800, 0xFFFF, 0x0000, 0x0001, 0x07FF]
            + Array(repeating: 0xFA55, count: 30)
        XCTAssertEqual(decoded.buffer.data, Self.littleEndianData(signExtended))

        let result = try XCTUnwrap(DCMPixelReader.makeCompressedResult(
            from: decoded,
            pixelRepresentation: 1,
            photometricInterpretation: "MONOCHROME2"
        ))
        XCTAssertEqual(Array(try XCTUnwrap(result.pixels16).prefix(5)), [30_720, 32_767, 32_768, 32_769, 34_815])
    }

    func test_restartMarkersOddDimensionsAndMalformedInputsAreHandled() async throws {
        let descriptor = Self.descriptor(width: 7, height: 5, bitsStored: 8)
        let source = Self.grayscaleBytes(width: 7, height: 5, bitsStored: 8)
        let pixels = stride(from: 0, to: source.count, by: 7).map {
            Array(source[$0..<min($0 + 7, source.count)]).map(Int.init)
        }
        let image = try MultiComponentImageData.grayscale(pixels: pixels, bitsPerSample: 8)
        let config = try JPEGLSEncoder.Configuration(
            near: 0,
            interleaveMode: .none,
            restartInterval: 2
        )
        let encoded = try JPEGLSEncoder().encode(image, configuration: config)
        let decoded = try await DicomJLSwiftBackend().decode(
            Self.decodeRequest(frameData: encoded, descriptor: descriptor)
        )
        XCTAssertEqual(decoded.buffer.data, source)

        await XCTAssertThrowsErrorAsync {
            _ = try await DicomJLSwiftBackend().decode(
                Self.decodeRequest(frameData: Data([0xFF, 0xD8, 0xFF]), descriptor: descriptor)
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await DicomJLSwiftBackend().decode(
                Self.decodeRequest(frameData: Data(encoded.dropLast(4)), descriptor: descriptor)
            )
        }
    }

    func test_shadowReturnsCharLSPixelsAndRecordsJLSwiftParity() async throws {
        try requireCharLS()
        let descriptor = Self.descriptor(bitsStored: 8)
        let source = Self.grayscaleBytes(width: 7, height: 5, bitsStored: 8)
        let encoded = try DicomJPEGLSCodec.encodeForTesting(
            bytes: source,
            width: 7,
            height: 5,
            bitsPerSample: 8
        )
        let recorder = DicomJLSwiftTelemetryRecorder()
        let frame = try await DicomJLSwiftFrameDecoder.decode(
            Self.decodeRequest(frameData: encoded, descriptor: descriptor),
            environment: [DicomJLSwiftRolloutMode.environmentKey: "shadow"]
        ) { recorder.record($0) }

        XCTAssertEqual(frame?.buffer.data, source)
        let parity = await recorder.waitFor {
            $0.backend == .jlSwift && $0.outcome == .matched
        }
        XCTAssertNotNil(parity)
    }

    func test_forcedModeRejectsAmbiguousHighBitDepthColorWithContext() async throws {
        let descriptor = Self.descriptor(
            bitsStored: 12,
            samplesPerPixel: 3,
            photometric: "RGB",
            planarConfiguration: 0
        )
        do {
            _ = try await DicomJLSwiftFrameDecoder.decode(
                Self.decodeRequest(frameData: Data([0xFF, 0xD8]), descriptor: descriptor),
                environment: [DicomJLSwiftRolloutMode.environmentKey: "forced-for-tests"]
            )
            XCTFail("Expected contextual unsupported-shape error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("12-bit output"))
        }
    }

    func test_invalidColorPlanarConfigurationReturnsContextualError() async throws {
        let descriptor = Self.descriptor(
            bitsStored: 8,
            samplesPerPixel: 3,
            photometric: "RGB",
            planarConfiguration: 2
        )
        do {
            _ = try await DicomJLSwiftBackend().decode(
                Self.decodeRequest(frameData: Data([0xFF, 0xD8]), descriptor: descriptor)
            )
            XCTFail("Expected invalid Planar Configuration to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Planar Configuration 0 or 1"))
        }
    }

    func test_performanceReportComparesColdWarmThroughputAndBufferFootprint() async throws {
        try requireCharLS()
        let width = 512
        let height = 512
        let iterations = 10
        let descriptor = Self.descriptor(width: width, height: height, bitsStored: 8)
        let source = Self.grayscaleBytes(width: width, height: height, bitsStored: 8)
        let encoded = try DicomJPEGLSCodec.encodeForTesting(
            bytes: source,
            width: width,
            height: height,
            bitsPerSample: 8
        )
        let request = Self.decodeRequest(frameData: encoded, descriptor: descriptor)

        let jlColdStart = DispatchTime.now().uptimeNanoseconds
        let jlCold = try await DicomJLSwiftBackend().decode(request)
        let jlColdNS = DispatchTime.now().uptimeNanoseconds - jlColdStart
        let charLSColdStart = DispatchTime.now().uptimeNanoseconds
        let charLSCold = try DicomJPEGLSCodec.decode(encoded)
        let charLSColdNS = DispatchTime.now().uptimeNanoseconds - charLSColdStart
        XCTAssertEqual(jlCold.buffer.data, charLSCold.bytes)

        var jlWarmSeconds = [Double]()
        var charLSWarmSeconds = [Double]()
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            let candidate = try await DicomJLSwiftBackend().decode(request)
            jlWarmSeconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000)
            XCTAssertEqual(candidate.buffer.data, source)
        }
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            let oracle = try DicomJPEGLSCodec.decode(encoded)
            charLSWarmSeconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000)
            XCTAssertEqual(oracle.bytes, source)
        }

        let jlStatistics = try ClinicalPerformanceStatistics(
            samples: jlWarmSeconds,
            workUnitsPerSample: Double(source.count)
        )
        let charLSStatistics = try ClinicalPerformanceStatistics(
            samples: charLSWarmSeconds,
            workUnitsPerSample: Double(source.count)
        )
        let jlThroughput = (jlStatistics.throughputPerSecond ?? 0) / 1_000_000
        let charLSThroughput = (charLSStatistics.throughputPerSecond ?? 0) / 1_000_000
        let jlMaterializedBytes = width * height * MemoryLayout<Int>.stride + source.count
        let charLSMaterializedBytes = source.count
        print(
            String(
                format: "JLSWIFT_PERF cold_ms=%.3f warm_ms=%.3f throughput_mb_s=%.1f buffer_floor_bytes=%d "
                    + "CHARLS cold_ms=%.3f warm_ms=%.3f throughput_mb_s=%.1f buffer_floor_bytes=%d",
                Double(jlColdNS) / 1_000_000,
                jlStatistics.mean * 1_000,
                jlThroughput,
                jlMaterializedBytes,
                Double(charLSColdNS) / 1_000_000,
                charLSStatistics.mean * 1_000,
                charLSThroughput,
                charLSMaterializedBytes
            )
        )

        let environment = Self.performanceEnvironment(mode: .warmIsolated)
        let gate = ClinicalPerformanceGate(
            warningLimit: 0.162,
            failureLimit: 0.180,
            relativeWarningPercent: 10,
            relativeFailurePercent: 20,
            lowerIsBetter: true
        )
        let resources = ClinicalPerformanceResourceMetrics(
            peakRSSBytes: BenchmarkMemorySampler.currentPeakResidentMemoryBytes()
        )
        let work = ClinicalPerformanceWorkMetrics(usefulBytes: UInt64(source.count))
        let measurements = [
            ClinicalPerformanceEvaluator.evaluate(
                metricID: "jlswift-warm-decode",
                stage: "decode",
                unit: "seconds",
                statistics: jlStatistics,
                correctnessPassed: jlCold.buffer.data == source,
                gate: gate,
                environment: environment,
                work: work,
                resources: resources
            ),
            ClinicalPerformanceEvaluator.evaluate(
                metricID: "charls-warm-decode",
                stage: "decode",
                unit: "seconds",
                statistics: charLSStatistics,
                correctnessPassed: charLSCold.bytes == source,
                gate: gate,
                environment: environment,
                work: work,
                resources: resources
            )
        ]
        XCTAssertFalse(measurements.contains { $0.verdict == .failure })
        let report = ClinicalPerformanceReport(
            schemaVersion: 1,
            generatedAt: Date(),
            environment: environment,
            warmupIterations: 1,
            benchmarkIterations: iterations,
            backendFlags: ["candidate": "jlswift-cpu", "oracle": "charls"],
            conformanceManifest: "ClinicalCodecConformanceManifest.json",
            measurements: measurements
        )
        try Self.writePerformanceReportIfRequested(report, stem: "dicom-jpegls-performance")

        let coldEnvironment = Self.performanceEnvironment(mode: .coldSDKFirstCall)
        let coldMeasurements = [
            ClinicalPerformanceEvaluator.evaluate(
                metricID: "jlswift-cold-decode",
                stage: "decode",
                unit: "seconds",
                statistics: try ClinicalPerformanceStatistics(
                    samples: [Double(jlColdNS) / 1_000_000_000],
                    workUnitsPerSample: Double(source.count)
                ),
                correctnessPassed: jlCold.buffer.data == source,
                gate: gate,
                environment: coldEnvironment,
                work: work,
                resources: resources
            ),
            ClinicalPerformanceEvaluator.evaluate(
                metricID: "charls-cold-decode",
                stage: "decode",
                unit: "seconds",
                statistics: try ClinicalPerformanceStatistics(
                    samples: [Double(charLSColdNS) / 1_000_000_000],
                    workUnitsPerSample: Double(source.count)
                ),
                correctnessPassed: charLSCold.bytes == source,
                gate: gate,
                environment: coldEnvironment,
                work: work,
                resources: resources
            )
        ]
        let coldReport = ClinicalPerformanceReport(
            schemaVersion: 1,
            generatedAt: Date(),
            environment: coldEnvironment,
            warmupIterations: 0,
            benchmarkIterations: 1,
            backendFlags: ["candidate": "jlswift-cpu", "oracle": "charls"],
            conformanceManifest: "ClinicalCodecConformanceManifest.json",
            measurements: coldMeasurements
        )
        try Self.writePerformanceReportIfRequested(coldReport, stem: "dicom-jpegls-cold-performance")
    }

    private static func performanceEnvironment(
        mode: ClinicalPerformanceBenchmarkMode
    ) -> ClinicalPerformanceEnvironment {
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
            benchmarkMode: mode,
            fixtureID: "ct-explicit-vr-le-rescale",
            tier: processEnvironment["CLINICAL_PERFORMANCE_TIER"]
                .flatMap(ClinicalPerformanceTier.init(rawValue:)) ?? .pullRequestSmoke,
            commandLineStartupIncluded: processEnvironment["CLINICAL_PERFORMANCE_CLI_STARTUP"] == "true"
        )
    }

    private static func writePerformanceReportIfRequested(_ report: ClinicalPerformanceReport,
                                                          stem: String) throws {
        guard let outputPath = ProcessInfo.processInfo.environment["CLINICAL_PERFORMANCE_OUTPUT_DIR"] else {
            return
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let reporter = ClinicalPerformanceReporter(report: report)
        try Data(reporter.jsonString().utf8).write(to: output.appendingPathComponent("\(stem).json"))
        try Data(reporter.csvString().utf8).write(to: output.appendingPathComponent("\(stem).csv"))
        try Data(reporter.markdownString().utf8).write(to: output.appendingPathComponent("\(stem).md"))
    }

    private func requireCharLS() throws {
        guard DicomJPEGLSCodec.isAvailable else {
            throw XCTSkip("CharLS runtime is unavailable; cross-library oracle tests are skipped.")
        }
    }

    private static func descriptor(
        transferSyntax: DicomTransferSyntax = .jpegLSLossless,
        width: Int = 7,
        height: Int = 5,
        bitsStored: Int,
        samplesPerPixel: Int = 1,
        photometric: String = "MONOCHROME2",
        planarConfiguration: Int? = nil,
        signed: Bool = false
    ) -> DicomCompressedFrameDescriptor {
        let bitsAllocated = bitsStored <= 8 ? 8 : 16
        return DicomCompressedFrameDescriptor(
            transferSyntaxUID: transferSyntax.rawValue,
            rows: height,
            columns: width,
            bitsAllocated: bitsAllocated,
            bitsStored: bitsStored,
            highBit: bitsStored - 1,
            pixelRepresentation: signed ? 1 : 0,
            samplesPerPixel: samplesPerPixel,
            photometricInterpretation: photometric,
            planarConfiguration: planarConfiguration
        )
    }

    private static func encodeRequest(
        bytes: Data,
        descriptor: DicomCompressedFrameDescriptor,
        intent: DicomEncodingIntent
    ) -> DicomFrameEncodeRequest {
        DicomFrameEncodeRequest(
            frame: DicomCodecDecodedFrame(
                buffer: .owned(bytes),
                width: descriptor.columns,
                height: descriptor.rows,
                bitsPerSample: descriptor.bitsStored,
                componentCount: descriptor.samplesPerPixel
            ),
            descriptor: descriptor,
            targetTransferSyntaxUID: descriptor.transferSyntaxUID,
            intent: intent
        )
    }

    private static func rows(from samples: [Int], width: Int) -> [[Int]] {
        stride(from: 0, to: samples.count, by: width).map {
            Array(samples[$0..<min($0 + width, samples.count)])
        }
    }

    private static func decodeRequest(
        frameData: Data,
        descriptor: DicomCompressedFrameDescriptor
    ) -> DicomFrameDecodeRequest {
        DicomFrameDecodeRequest(frameData: frameData, descriptor: descriptor, frameIndex: 0)
    }

    private static func grayscaleBytes(width: Int, height: Int, bitsStored: Int) -> Data {
        let mask = bitsStored == 16 ? 0xFFFF : (1 << bitsStored) - 1
        let values = (0..<(width * height)).map { ($0 * 37 + $0 / 3) & mask }
        if bitsStored <= 8 {
            return Data(values.map(UInt8.init))
        }
        return littleEndianData(values.map(UInt16.init))
    }

    private static func littleEndianData(_ values: [UInt16]) -> Data {
        var data = Data(capacity: values.count * 2)
        for value in values {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return data
    }

    private static func assertNear(_ expected: Data, _ actual: Data, near: Int) {
        XCTAssertEqual(actual.count, expected.count)
        for (expectedSample, actualSample) in zip(expected, actual) {
            XCTAssertLessThanOrEqual(abs(Int(expectedSample) - Int(actualSample)), near)
        }
    }
}

private final class DicomJLSwiftTelemetryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DicomJLSwiftDecodeTelemetry] = []

    func record(_ telemetry: DicomJLSwiftDecodeTelemetry) {
        lock.lock()
        storage.append(telemetry)
        lock.unlock()
    }

    private var values: [DicomJLSwiftDecodeTelemetry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func waitFor(
        _ predicate: (DicomJLSwiftDecodeTelemetry) -> Bool
    ) async -> DicomJLSwiftDecodeTelemetry? {
        for _ in 0..<200 {
            let value = values.first(where: predicate)
            if let value { return value }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
