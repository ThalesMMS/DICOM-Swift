import CryptoKit
import Foundation
import XCTest
@testable import DicomCore

#if os(macOS)
import Darwin
#endif

#if canImport(DicomJPEG)
import DicomJPEG
#endif

/// Opt-in Release qualification for issue #2094.
///
/// The first-call report is meaningful only when the script launches this test in a fresh process.
/// Native and GDCM encode baselines do not exist in the current architecture, so the report records
/// them as N/A instead of manufacturing a comparison. The same JLISwift codestream is decoded by
/// JLISwift and DicomCore's native JPEG Lossless decoder.
final class DicomJLISwiftQualificationBenchmarkTests: XCTestCase {
    func test_releaseGray16SV1_reportsFirstCallWarmTimingCopiesAndMemory() throws {
        guard ProcessInfo.processInfo.environment["DICOM_JLISWIFT_BENCHMARK"] == "1" else {
            throw XCTSkip("Set DICOM_JLISWIFT_BENCHMARK=1 and use the isolated Release benchmark script.")
        }
#if DEBUG
        throw XCTSkip("JLISwift qualification measurements require a Release build.")
#elseif canImport(DicomJPEG)
        try runGray16SV1Benchmark()
#else
        throw XCTSkip("The vendored DicomJPEG codec is unavailable on this platform.")
#endif
    }
}

#if canImport(DicomJPEG) && !DEBUG
private extension DicomJLISwiftQualificationBenchmarkTests {
    struct Timed<Value> {
        let value: Value
        let seconds: Double
    }

    func runGray16SV1Benchmark() throws {
        let processEnvironment = ProcessInfo.processInfo.environment
        let size = max(1, Int(processEnvironment["DICOM_JLISWIFT_BENCHMARK_SIZE"] ?? "") ?? 512)
        let warmupIterations = max(0, Int(processEnvironment["DICOM_JLISWIFT_BENCHMARK_WARMUPS"] ?? "") ?? 3)
        let iterations = max(1, Int(processEnvironment["DICOM_JLISWIFT_BENCHMARK_ITERATIONS"] ?? "") ?? 20)
        let source = Self.gray16Fixture(width: size, height: size)
        let fixtureHash = SHA256.hash(data: source.data).map { String(format: "%02x", $0) }.joined()
        let fixtureID = "synthetic-jpeg-lossless-sv1-gray16-\(size)x\(size)-\(fixtureHash.prefix(12))"
        let initialResident = Self.currentResidentMemoryBytes()

        // These are the first calls to each measured API in this isolated XCTest process.
        let firstSourceArray = Self.measure { [UInt8](source.data) }
        let image = try JLIImage(
            width: size,
            height: size,
            pixelFormat: .uint16,
            colorModel: .grayscale,
            data: firstSourceArray.value
        )
        var configuration = JLIEncoderConfiguration.diagnosticLossless
        configuration.losslessPrecision = 16
        configuration.losslessPredictor = 1
        configuration.losslessPointTransform = 0
        configuration.restartInterval = 0

        let firstEncode = try Self.measure { try JLIEncoder().encode(image, configuration: configuration) }
        let firstEncodedData = Self.measure { Data(firstEncode.value) }
        let firstEncodedArray = Self.measure { [UInt8](firstEncodedData.value) }
        let firstJLIDecode = try Self.measure { try JLIDecoder().decode(from: firstEncodedArray.value) }
        let firstNativeDecode = try Self.measure {
            try JPEGLosslessDecoder().decode(data: firstEncodedData.value)
        }
        let firstDecodedData = Self.measure { Data(firstJLIDecode.value.data) }
        try Self.assertCorrectness(
            source: source,
            jliImage: firstJLIDecode.value,
            nativePixels: firstNativeDecode.value.pixels,
            width: size,
            height: size
        )
        XCTAssertEqual(firstDecodedData.value, source.data)
        let firstResident = Self.currentResidentMemoryBytes()
        let firstResources = ClinicalPerformanceResourceMetrics(
            peakRSSBytes: BenchmarkMemorySampler.currentPeakResidentMemoryBytes(),
            residentDeltaBytes: Self.signedDifference(firstResident, initialResident)
        )

        for _ in 0..<warmupIterations {
            let encoded = try JLIEncoder().encode(image, configuration: configuration)
            let encodedData = Data(encoded)
            XCTAssertEqual(try JLIDecoder().decode(from: [UInt8](encodedData)).data, source.dataBytes)
            XCTAssertEqual(try JPEGLosslessDecoder().decode(data: encodedData).pixels, source.samples)
        }

        let warmInitialResident = Self.currentResidentMemoryBytes()
        let encodeBatch = 5
        let copyBatch = 100
        let jliDecodeBatch = 5
        var encodeSeconds = [Double]()
        var sourceDataToArraySeconds = [Double]()
        var arrayToDataSeconds = [Double]()
        var dataToArraySeconds = [Double]()
        var jliDecodeSeconds = [Double]()
        var decodedArrayToDataSeconds = [Double]()
        var nativeDecodeSeconds = [Double]()
        var encodedSizes = [Double]()
        encodeSeconds.reserveCapacity(iterations)
        sourceDataToArraySeconds.reserveCapacity(iterations)
        arrayToDataSeconds.reserveCapacity(iterations)
        dataToArraySeconds.reserveCapacity(iterations)
        jliDecodeSeconds.reserveCapacity(iterations)
        decodedArrayToDataSeconds.reserveCapacity(iterations)
        nativeDecodeSeconds.reserveCapacity(iterations)
        encodedSizes.reserveCapacity(iterations)

        for _ in 0..<iterations {
            let sourceArray = Self.measureRepeated(count: copyBatch) { [UInt8](source.data) }
            sourceDataToArraySeconds.append(sourceArray.seconds)
            XCTAssertEqual(sourceArray.value, source.dataBytes)

            let encoded = try Self.measureRepeated(count: encodeBatch) {
                try JLIEncoder().encode(image, configuration: configuration)
            }
            encodeSeconds.append(encoded.seconds)
            encodedSizes.append(Double(encoded.value.count))

            let encodedData = Self.measureRepeated(count: copyBatch) { Data(encoded.value) }
            arrayToDataSeconds.append(encodedData.seconds)
            let encodedArray = Self.measureRepeated(count: copyBatch) { [UInt8](encodedData.value) }
            dataToArraySeconds.append(encodedArray.seconds)

            let jliDecoded = try Self.measureRepeated(count: jliDecodeBatch) {
                try JLIDecoder().decode(from: encodedArray.value)
            }
            jliDecodeSeconds.append(jliDecoded.seconds)
            let decodedData = Self.measureRepeated(count: copyBatch) { Data(jliDecoded.value.data) }
            decodedArrayToDataSeconds.append(decodedData.seconds)
            let nativeDecoded = try Self.measure { try JPEGLosslessDecoder().decode(data: encodedData.value) }
            nativeDecodeSeconds.append(nativeDecoded.seconds)
            try Self.assertCorrectness(
                source: source,
                jliImage: jliDecoded.value,
                nativePixels: nativeDecoded.value.pixels,
                width: size,
                height: size
            )
            XCTAssertEqual(decodedData.value, source.data)
            benchmarkBlackHole(encoded.value)
            benchmarkBlackHole(jliDecoded.value)
            benchmarkBlackHole(nativeDecoded.value)
        }

        let finalResident = Self.currentResidentMemoryBytes()
        let residentDelta = Self.signedDifference(finalResident, warmInitialResident)
        let resources = ClinicalPerformanceResourceMetrics(
            peakRSSBytes: BenchmarkMemorySampler.currentPeakResidentMemoryBytes(),
            residentDeltaBytes: residentDelta
        )
        let sourceBytes = source.data.count
        let encodedBytes = firstEncode.value.count
        let safetyGate = ClinicalPerformanceGate(
            warningLimit: 30,
            failureLimit: 60,
            relativeWarningPercent: 10,
            relativeFailurePercent: 25,
            lowerIsBetter: true
        )
        let sizeSafetyGate = ClinicalPerformanceGate(
            warningLimit: Double(max(sourceBytes * 16, 1)),
            failureLimit: Double(max(sourceBytes * 32, 2)),
            relativeWarningPercent: 10,
            relativeFailurePercent: 25,
            lowerIsBetter: true
        )

        let firstEnvironment = Self.performanceEnvironment(fixtureID: fixtureID, mode: .coldSDKFirstCall)
        let firstMeasurements = try [
            Self.measurement(
                id: "jliswift-first-encode",
                stage: "encode-first-api-call",
                samples: [firstEncode.seconds],
                workBytes: sourceBytes,
                environment: firstEnvironment,
                gate: safetyGate,
                resources: firstResources
            ),
            Self.copyMeasurement(
                id: "jliswift-first-source-data-to-array-copy",
                direction: "source-dicom-data-to-jliswift-array",
                samples: [firstSourceArray.seconds],
                copiedBytes: sourceBytes,
                environment: firstEnvironment,
                gate: safetyGate,
                resources: firstResources
            ),
            Self.copyMeasurement(
                id: "jliswift-first-array-to-data-copy",
                direction: "encoded-array-to-dicom-data",
                samples: [firstEncodedData.seconds],
                copiedBytes: encodedBytes,
                environment: firstEnvironment,
                gate: safetyGate,
                resources: firstResources
            ),
            Self.copyMeasurement(
                id: "jliswift-first-data-to-array-copy",
                direction: "dicom-data-to-jliswift-array",
                samples: [firstEncodedArray.seconds],
                copiedBytes: encodedBytes,
                environment: firstEnvironment,
                gate: safetyGate,
                resources: firstResources
            ),
            Self.measurement(
                id: "jliswift-first-decode",
                stage: "decode-first-api-call",
                samples: [firstJLIDecode.seconds],
                workBytes: sourceBytes,
                environment: firstEnvironment,
                gate: safetyGate,
                resources: firstResources
            ),
            Self.copyMeasurement(
                id: "jliswift-first-decoded-array-to-data-copy",
                direction: "jliswift-decoded-array-to-dicom-data",
                samples: [firstDecodedData.seconds],
                copiedBytes: sourceBytes,
                environment: firstEnvironment,
                gate: safetyGate,
                resources: firstResources
            ),
            Self.measurement(
                id: "dicom-native-first-decode",
                stage: "decode-first-api-call",
                samples: [firstNativeDecode.seconds],
                workBytes: sourceBytes,
                environment: firstEnvironment,
                gate: safetyGate,
                resources: firstResources
            ),
            Self.encodedSizeMeasurement(
                samples: [Double(encodedBytes)],
                sourceBytes: sourceBytes,
                environment: firstEnvironment,
                gate: sizeSafetyGate,
                resources: firstResources
            )
        ]
        let firstReport = Self.report(
            environment: firstEnvironment,
            warmups: 0,
            iterations: 1,
            measurements: firstMeasurements
        )
        try Self.write(firstReport, stem: "dicom-jliswift-qualification-first")

        let warmEnvironment = Self.performanceEnvironment(fixtureID: fixtureID, mode: .warmSustained)
        let warmMeasurements = try [
            Self.measurement(
                id: "jliswift-warm-encode",
                stage: "encode",
                samples: encodeSeconds,
                workBytes: sourceBytes,
                environment: warmEnvironment,
                gate: safetyGate,
                resources: resources
            ),
            Self.copyMeasurement(
                id: "jliswift-warm-source-data-to-array-copy",
                direction: "source-dicom-data-to-jliswift-array",
                samples: sourceDataToArraySeconds,
                copiedBytes: sourceBytes,
                environment: warmEnvironment,
                gate: safetyGate,
                resources: resources
            ),
            Self.copyMeasurement(
                id: "jliswift-warm-array-to-data-copy",
                direction: "encoded-array-to-dicom-data",
                samples: arrayToDataSeconds,
                copiedBytes: encodedBytes,
                environment: warmEnvironment,
                gate: safetyGate,
                resources: resources
            ),
            Self.copyMeasurement(
                id: "jliswift-warm-data-to-array-copy",
                direction: "dicom-data-to-jliswift-array",
                samples: dataToArraySeconds,
                copiedBytes: encodedBytes,
                environment: warmEnvironment,
                gate: safetyGate,
                resources: resources
            ),
            Self.measurement(
                id: "jliswift-warm-decode",
                stage: "decode",
                samples: jliDecodeSeconds,
                workBytes: sourceBytes,
                environment: warmEnvironment,
                gate: safetyGate,
                resources: resources
            ),
            Self.copyMeasurement(
                id: "jliswift-warm-decoded-array-to-data-copy",
                direction: "jliswift-decoded-array-to-dicom-data",
                samples: decodedArrayToDataSeconds,
                copiedBytes: sourceBytes,
                environment: warmEnvironment,
                gate: safetyGate,
                resources: resources
            ),
            Self.measurement(
                id: "dicom-native-warm-decode",
                stage: "decode",
                samples: nativeDecodeSeconds,
                workBytes: sourceBytes,
                environment: warmEnvironment,
                gate: safetyGate,
                resources: resources
            ),
            Self.encodedSizeMeasurement(
                samples: encodedSizes,
                sourceBytes: sourceBytes,
                environment: warmEnvironment,
                gate: sizeSafetyGate,
                resources: resources
            )
        ]
        let warmReport = Self.report(
            environment: warmEnvironment,
            warmups: warmupIterations,
            iterations: iterations,
            measurements: warmMeasurements,
            measurementBatches: [
                "encode": encodeBatch,
                "sourceDataToArray": copyBatch,
                "encodedArrayToData": copyBatch,
                "encodedDataToArray": copyBatch,
                "decodedArrayToData": copyBatch,
                "jliDecode": jliDecodeBatch,
                "nativeDecode": 1
            ]
        )
        try Self.write(warmReport, stem: "dicom-jliswift-qualification-warm")
    }

    static func measurement(
        id: String,
        stage: String,
        samples: [Double],
        workBytes: Int,
        environment: ClinicalPerformanceEnvironment,
        gate: ClinicalPerformanceGate,
        resources: ClinicalPerformanceResourceMetrics
    ) throws -> ClinicalPerformanceMeasurement {
        ClinicalPerformanceEvaluator.evaluate(
            metricID: id,
            stage: stage,
            unit: "seconds",
            statistics: try ClinicalPerformanceStatistics(
                samples: samples,
                workUnitsPerSample: Double(workBytes)
            ),
            correctnessPassed: true,
            gate: gate,
            environment: environment,
            work: ClinicalPerformanceWorkMetrics(usefulBytes: UInt64(workBytes)),
            resources: resources
        )
    }

    static func copyMeasurement(
        id: String,
        direction: String,
        samples: [Double],
        copiedBytes: Int,
        environment: ClinicalPerformanceEnvironment,
        gate: ClinicalPerformanceGate,
        resources: ClinicalPerformanceResourceMetrics
    ) throws -> ClinicalPerformanceMeasurement {
        ClinicalPerformanceEvaluator.evaluate(
            metricID: id,
            stage: direction,
            unit: "seconds",
            statistics: try ClinicalPerformanceStatistics(
                samples: samples,
                workUnitsPerSample: Double(copiedBytes)
            ),
            correctnessPassed: true,
            gate: gate,
            environment: environment,
            work: ClinicalPerformanceWorkMetrics(
                usefulBytes: UInt64(copiedBytes),
                duplicatedBytes: UInt64(copiedBytes)
            ),
            resources: ClinicalPerformanceResourceMetrics(
                peakRSSBytes: resources.peakRSSBytes,
                residentDeltaBytes: resources.residentDeltaBytes,
                cpuCopyCount: 1
            )
        )
    }

    static func encodedSizeMeasurement(
        samples: [Double],
        sourceBytes: Int,
        environment: ClinicalPerformanceEnvironment,
        gate: ClinicalPerformanceGate,
        resources: ClinicalPerformanceResourceMetrics
    ) throws -> ClinicalPerformanceMeasurement {
        ClinicalPerformanceEvaluator.evaluate(
            metricID: "jliswift-encoded-size",
            stage: "encoded-codestream",
            unit: "bytes",
            statistics: try ClinicalPerformanceStatistics(samples: samples),
            correctnessPassed: true,
            gate: gate,
            environment: environment,
            work: ClinicalPerformanceWorkMetrics(usefulBytes: UInt64(sourceBytes)),
            resources: resources
        )
    }

    static func report(
        environment: ClinicalPerformanceEnvironment,
        warmups: Int,
        iterations: Int,
        measurements: [ClinicalPerformanceMeasurement],
        measurementBatches: [String: Int] = [:]
    ) -> ClinicalPerformanceReport {
        let processEnvironment = ProcessInfo.processInfo.environment
        let batchDescription = measurementBatches.keys.sorted().map {
            "\($0)=\(measurementBatches[$0] ?? 1)"
        }.joined(separator: ";")
        return ClinicalPerformanceReport(
            schemaVersion: 1,
            generatedAt: Date(),
            environment: environment,
            warmupIterations: warmups,
            benchmarkIterations: iterations,
            backendFlags: [
                "candidate": "jliswift-sof3",
                "decision": "defer-no-production-backend",
                "dependencyScope": "DicomCoreTests-only",
                "oracle": "dicom-native-jpeg-lossless",
                "firstMeasurementSemantics": "first-call-per-api-after-fixture-and-encoder-setup",
                "decoderColdStartClaim": "not-claimed-encoder-runs-first",
                "nativeEncodeComparator": "n/a-not-implemented",
                "gdcmEncodeComparator": "n/a-not-exposed",
                "dicomSwiftRevision": processEnvironment["DICOM_SWIFT_REVISION"] ?? "unknown",
                "jliSwiftRevision": processEnvironment["JLISWIFT_REVISION"] ?? "unknown",
                "isolatedRun": processEnvironment["DICOM_JLISWIFT_ISOLATED_RUN"] ?? "unknown",
                "measurementBatches": batchDescription.isEmpty ? "one-operation-per-sample" : batchDescription
            ],
            conformanceManifest: "Resources/Qualification/JLISwiftSV1FixtureManifest.json",
            measurements: measurements
        )
    }

    static func performanceEnvironment(
        fixtureID: String,
        mode: ClinicalPerformanceBenchmarkMode
    ) -> ClinicalPerformanceEnvironment {
        let platform = PlatformInfo()
        let processEnvironment = ProcessInfo.processInfo.environment
        return ClinicalPerformanceEnvironment(
            deviceName: platform.modelIdentifier,
            osVersion: platform.osVersion,
            architecture: platform.architecture,
            modelIdentifier: platform.modelIdentifier,
            buildConfiguration: "release",
            benchmarkMode: mode,
            fixtureID: fixtureID,
            tier: processEnvironment["CLINICAL_PERFORMANCE_TIER"]
                .flatMap(ClinicalPerformanceTier.init(rawValue:)) ?? .release,
            commandLineStartupIncluded: false
        )
    }

    static func write(_ report: ClinicalPerformanceReport, stem: String) throws {
        guard let outputPath = ProcessInfo.processInfo.environment["CLINICAL_PERFORMANCE_OUTPUT_DIR"] else {
            throw XCTSkip("CLINICAL_PERFORMANCE_OUTPUT_DIR is required for auditable qualification artifacts.")
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let reporter = ClinicalPerformanceReporter(report: report)
        try Data(reporter.jsonString().utf8).write(to: output.appendingPathComponent("\(stem).json"))
        try Data(reporter.csvString().utf8).write(to: output.appendingPathComponent("\(stem).csv"))
        try Data(reporter.markdownString().utf8).write(to: output.appendingPathComponent("\(stem).md"))
    }

    static func gray16Fixture(width: Int, height: Int) -> (data: Data, dataBytes: [UInt8], samples: [UInt16]) {
        let count = width * height
        var samples = [UInt16](repeating: 0, count: count)
        var state: UInt32 = 0x2094_BEEF
        for index in 0..<count {
            state = state &* 1_664_525 &+ 1_013_904_223
            let x = index % width
            let y = index / width
            let ramp = UInt32((x + y) * 65_535 / max(1, width + height - 2))
            samples[index] = UInt16(truncatingIfNeeded: ramp &+ (state >> 27))
        }
        var bytes = [UInt8](repeating: 0, count: count * 2)
        for (index, sample) in samples.enumerated() {
            bytes[index * 2] = UInt8(truncatingIfNeeded: sample)
            bytes[index * 2 + 1] = UInt8(truncatingIfNeeded: sample >> 8)
        }
        return (Data(bytes), bytes, samples)
    }

    static func assertCorrectness(
        source: (data: Data, dataBytes: [UInt8], samples: [UInt16]),
        jliImage: JLIImage,
        nativePixels: [UInt16],
        width: Int,
        height: Int
    ) throws {
        XCTAssertEqual(jliImage.width, width)
        XCTAssertEqual(jliImage.height, height)
        XCTAssertEqual(jliImage.data, source.dataBytes)
        XCTAssertEqual(nativePixels, source.samples)
    }

    @inline(never)
    static func measure<Value>(_ body: () throws -> Value) rethrows -> Timed<Value> {
        let start = BenchmarkClock.now()
        let value = try body()
        return Timed(value: value, seconds: BenchmarkClock.secondsElapsed(since: start))
    }

    @inline(never)
    static func measureRepeated<Value>(count: Int, _ body: () throws -> Value) rethrows -> Timed<Value> {
        precondition(count > 0)
        let start = BenchmarkClock.now()
        var value = try body()
        benchmarkBlackHole(value)
        if count > 1 {
            for _ in 1..<count {
                value = try body()
                benchmarkBlackHole(value)
            }
        }
        return Timed(
            value: value,
            seconds: BenchmarkClock.secondsElapsed(since: start) / Double(count)
        )
    }

    static func signedDifference(_ value: UInt64?, _ baseline: UInt64?) -> Int64? {
        guard let value, let baseline else { return nil }
        if value >= baseline {
            return Int64(clamping: value - baseline)
        }
        return -Int64(clamping: baseline - value)
    }

    static func currentResidentMemoryBytes() -> UInt64? {
#if os(macOS)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
#else
        return nil
#endif
    }
}
#endif
