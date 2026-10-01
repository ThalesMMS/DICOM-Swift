import Foundation
import XCTest
@testable import DicomCore

#if os(macOS)
import Darwin
#endif

final class DicomDecodedFrameMaterializationBenchmarkTests: XCTestCase {
    private static let enabledKey = "DICOM_DECODED_FRAME_MATERIALIZATION_BENCHMARK"
    private static let scenarioKey = "DICOM_DECODED_FRAME_SCENARIO"
    private static let runKey = "DICOM_DECODED_FRAME_RUN"

    /// Release-only characterization for issue #2093. This benchmark does not enforce a
    /// device-independent budget. The decision rule is evaluated from two isolated runs:
    /// at least two of materialization >= 1 ms/frame, materialization >= 10% of end-to-end,
    /// and one complete duplicated payload with multiframe impact must be present.
    func test_releaseDecodedFrameMaterialization_reportsColdWarmDecodeAndMaterializationStages() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment[Self.enabledKey] == "1" else {
            throw XCTSkip("Set \(Self.enabledKey)=1 to run the decoded-frame benchmark.")
        }
        #if DEBUG
        XCTFail("The decoded-frame materialization benchmark must run with -c release.")
        #else
        let scenario = environment[Self.scenarioKey] ?? Scenario.jpegLSGray16Signed.rawValue
        guard let selected = Scenario(rawValue: scenario) else {
            XCTFail("Unknown decoded-frame benchmark scenario: \(scenario)")
            return
        }

        switch selected {
        case .nativeGray8:
            try benchmarkNative(
                scenario: selected,
                width: 512,
                height: 512,
                bitsPerSample: 8,
                componentCount: 1,
                pixelRepresentation: 0,
                photometricInterpretation: "MONOCHROME2"
            )
        case .nativeGray16Signed:
            try benchmarkNative(
                scenario: selected,
                width: 512,
                height: 512,
                bitsPerSample: 16,
                componentCount: 1,
                pixelRepresentation: 1,
                photometricInterpretation: "MONOCHROME2"
            )
        case .nativeRGB8:
            try benchmarkNative(
                scenario: selected,
                width: 512,
                height: 512,
                bitsPerSample: 8,
                componentCount: 3,
                pixelRepresentation: 0,
                photometricInterpretation: "RGB"
            )
        case .rleGray8:
            try benchmarkCuratedFixture(
                scenario: selected,
                relativePath: "DecoderParity/rle_parity.dcm"
            )
        case .jpegLosslessGray16:
            try benchmarkCuratedFixture(
                scenario: selected,
                relativePath: "DecoderParity/jpeg_lossless_sv1_parity.dcm"
            )
        case .jpegLSGray16Signed:
            try await benchmarkCodec(
                scenario: selected,
                descriptor: Self.descriptor(
                    syntax: .jpegLSLossless,
                    width: 512,
                    height: 512,
                    bitsPerSample: 16,
                    componentCount: 1,
                    signed: true
                ),
                backendIdentifier: "jlswift",
                encode: { try await DicomJLSwiftBackend().encode($0) },
                decode: { try await DicomJLSwiftBackend().decode($0) }
            )
        case .jpeg2000Gray16:
            try await benchmarkCodec(
                scenario: selected,
                descriptor: Self.descriptor(
                    syntax: .jpeg2000Lossless,
                    width: 512,
                    height: 512,
                    bitsPerSample: 16,
                    componentCount: 1,
                    signed: false
                ),
                backendIdentifier: "j2kswift-cpu",
                encode: { try await DicomJ2KSwiftBackend().encode($0) },
                decode: { try await DicomJ2KSwiftBackend().decode($0) }
            )
        case .jpeg2000RGB8:
            try await benchmarkCodec(
                scenario: selected,
                descriptor: Self.descriptor(
                    syntax: .jpeg2000Lossless,
                    width: 512,
                    height: 512,
                    bitsPerSample: 8,
                    componentCount: 3,
                    signed: false
                ),
                backendIdentifier: "j2kswift-cpu",
                encode: { try await DicomJ2KSwiftBackend().encode($0) },
                decode: { try await DicomJ2KSwiftBackend().decode($0) }
            )
        case .nativeGray8Multiframe:
            try await benchmarkNativeMultiframe(scenario: selected)
        }
        #endif
    }

    private enum Scenario: String, CaseIterable {
        case nativeGray8 = "native-gray8"
        case nativeGray16Signed = "native-gray16-signed"
        case nativeRGB8 = "native-rgb8"
        case rleGray8 = "rle-gray8"
        case jpegLosslessGray16 = "jpeg-lossless-gray16"
        case jpegLSGray16Signed = "jpeg-ls-gray16-signed"
        case jpeg2000Gray16 = "jpeg2000-gray16"
        case jpeg2000RGB8 = "jpeg2000-rgb8"
        case nativeGray8Multiframe = "native-gray8-multiframe"
    }

    private typealias Encode = (DicomFrameEncodeRequest) async throws -> Data
    private typealias Decode = (DicomFrameDecodeRequest) async throws -> DicomCodecDecodedFrame

    private func benchmarkCodec(
        scenario: Scenario,
        descriptor: DicomCompressedFrameDescriptor,
        backendIdentifier: String,
        encode: Encode,
        decode: Decode
    ) async throws {
        let source = Self.sourceBytes(
            width: descriptor.columns,
            height: descriptor.rows,
            bitsPerSample: descriptor.bitsAllocated,
            componentCount: descriptor.samplesPerPixel
        )
        let sourceFrame = DicomCodecDecodedFrame(
            buffer: .owned(source),
            width: descriptor.columns,
            height: descriptor.rows,
            bitsPerSample: descriptor.bitsAllocated,
            componentCount: descriptor.samplesPerPixel
        )
        let encoded = try await encode(DicomFrameEncodeRequest(
            frame: sourceFrame,
            descriptor: descriptor,
            targetTransferSyntaxUID: descriptor.transferSyntaxUID
        ))
        let request = DicomFrameDecodeRequest(
            frameData: encoded,
            descriptor: descriptor,
            frameIndex: 0
        )

        let residentBefore = Self.currentResidentMemoryBytes()
        let coldDecode = try await Self.timed { try await decode(request) }
        let coldMaterialization = try Self.timed {
            try XCTUnwrap(DCMPixelReader.makeCompressedResult(
                from: coldDecode.value,
                pixelRepresentation: descriptor.pixelRepresentation,
                photometricInterpretation: descriptor.photometricInterpretation
            ))
        }
        let expectedHash = Self.pixelHash(coldMaterialization.value)
        let coldTotal = coldDecode.seconds + coldMaterialization.seconds

        for _ in 0..<2 {
            let frame = try await decode(request)
            benchmarkBlackHole(try Self.materializedResult(frame, descriptor: descriptor))
        }

        let iterations = 12
        var decodeSamples = [Double]()
        var materializationSamples = [Double]()
        var endToEndSamples = [Double]()
        for _ in 0..<iterations {
            let decoded = try await Self.timed { try await decode(request) }
            decodeSamples.append(decoded.seconds)
            benchmarkBlackHole(decoded.value.buffer.data)

            let materialized = try Self.timed {
                try Self.materializedResult(decoded.value, descriptor: descriptor)
            }
            materializationSamples.append(materialized.seconds)
            XCTAssertEqual(Self.pixelHash(materialized.value), expectedHash)

            let endToEnd = try await Self.timed {
                let frame = try await decode(request)
                return try Self.materializedResult(frame, descriptor: descriptor)
            }
            endToEndSamples.append(endToEnd.seconds)
            XCTAssertEqual(Self.pixelHash(endToEnd.value), expectedHash)
        }
        let residentAfter = Self.currentResidentMemoryBytes()
        let payloadBytes = UInt64(coldDecode.value.buffer.data.count)
        let resources = ClinicalPerformanceResourceMetrics(
            peakRSSBytes: BenchmarkMemorySampler.currentPeakResidentMemoryBytes(),
            residentDeltaBytes: Self.signedDifference(residentAfter, residentBefore),
            cpuCopyCount: 1
        )
        let work = ClinicalPerformanceWorkMetrics(
            usefulBytes: payloadBytes,
            duplicatedBytes: payloadBytes
        )
        try writeReports(
            scenario: scenario,
            backendIdentifier: backendIdentifier,
            correctnessHash: expectedHash,
            coldMeasurements: [
                try measurement(
                    id: "cold-codec-decode",
                    stage: "codec-decode",
                    samples: [coldDecode.seconds],
                    work: ClinicalPerformanceWorkMetrics(usefulBytes: payloadBytes),
                    resources: resources
                ),
                try measurement(
                    id: "cold-data-to-array",
                    stage: "data-to-array",
                    samples: [coldMaterialization.seconds],
                    work: work,
                    resources: resources
                ),
                try measurement(
                    id: "cold-end-to-end",
                    stage: "codec-decode-and-materialize",
                    samples: [coldTotal],
                    work: work,
                    resources: resources
                )
            ],
            warmMeasurements: [
                try measurement(
                    id: "warm-codec-decode",
                    stage: "codec-decode",
                    samples: decodeSamples,
                    work: ClinicalPerformanceWorkMetrics(usefulBytes: payloadBytes),
                    resources: resources
                ),
                try measurement(
                    id: "warm-data-to-array",
                    stage: "data-to-array",
                    samples: materializationSamples,
                    work: work,
                    resources: resources
                ),
                try measurement(
                    id: "warm-end-to-end",
                    stage: "codec-decode-and-materialize",
                    samples: endToEndSamples,
                    work: work,
                    resources: resources
                )
            ],
            warmups: 2,
            iterations: iterations
        )
    }

    private func benchmarkNative(
        scenario: Scenario,
        width: Int,
        height: Int,
        bitsPerSample: Int,
        componentCount: Int,
        pixelRepresentation: Int,
        photometricInterpretation: String
    ) throws {
        let source = Self.sourceBytes(
            width: width,
            height: height,
            bitsPerSample: bitsPerSample,
            componentCount: componentCount
        )
        var fileBytes = Data([0])
        fileBytes.append(source)
        let decode = {
            DCMPixelReader.readPixels(
                data: fileBytes,
                width: width,
                height: height,
                bitDepth: bitsPerSample,
                samplesPerPixel: componentCount,
                offset: 1,
                pixelRepresentation: pixelRepresentation,
                littleEndian: true,
                photometricInterpretation: photometricInterpretation
            )
        }
        let residentBefore = Self.currentResidentMemoryBytes()
        let cold = Self.timed(decode)
        let expectedHash = Self.pixelHash(cold.value)
        for _ in 0..<2 { benchmarkBlackHole(decode()) }
        let iterations = 20
        var samples = [Double]()
        for _ in 0..<iterations {
            let result = Self.timed(decode)
            samples.append(result.seconds)
            XCTAssertEqual(Self.pixelHash(result.value), expectedHash)
        }
        let payloadBytes = UInt64(source.count)
        let resources = ClinicalPerformanceResourceMetrics(
            peakRSSBytes: BenchmarkMemorySampler.currentPeakResidentMemoryBytes(),
            residentDeltaBytes: Self.signedDifference(Self.currentResidentMemoryBytes(), residentBefore),
            cpuCopyCount: 1
        )
        let work = ClinicalPerformanceWorkMetrics(usefulBytes: payloadBytes, duplicatedBytes: payloadBytes)
        try writeReports(
            scenario: scenario,
            backendIdentifier: "native-uncompressed",
            correctnessHash: expectedHash,
            coldMeasurements: [try measurement(
                id: "cold-native-decode-and-materialize",
                stage: "decode-and-materialize-fused",
                samples: [cold.seconds],
                work: work,
                resources: resources
            )],
            warmMeasurements: [try measurement(
                id: "warm-native-decode-and-materialize",
                stage: "decode-and-materialize-fused",
                samples: samples,
                work: work,
                resources: resources
            )],
            warmups: 2,
            iterations: iterations
        )
    }

    private func benchmarkCuratedFixture(scenario: Scenario, relativePath: String) throws {
        let reader = try DicomDecodedFrameReader(
            contentsOf: Self.fixturesDirectory.appendingPathComponent(relativePath)
        )
        let residentBefore = Self.currentResidentMemoryBytes()
        let cold = try Self.timed { try reader.frame(at: 0) }
        let expectedHash = Self.pixelHash(cold.value.pixels)
        for _ in 0..<2 { benchmarkBlackHole(try reader.frame(at: 0)) }
        let iterations = 20
        var samples = [Double]()
        for _ in 0..<iterations {
            let result = try Self.timed { try reader.frame(at: 0) }
            samples.append(result.seconds)
            XCTAssertEqual(Self.pixelHash(result.value.pixels), expectedHash)
        }
        let payloadBytes = UInt64(Self.byteCount(cold.value.pixels))
        let resources = ClinicalPerformanceResourceMetrics(
            peakRSSBytes: BenchmarkMemorySampler.currentPeakResidentMemoryBytes(),
            residentDeltaBytes: Self.signedDifference(Self.currentResidentMemoryBytes(), residentBefore),
            cpuCopyCount: 1
        )
        let work = ClinicalPerformanceWorkMetrics(usefulBytes: payloadBytes, duplicatedBytes: payloadBytes)
        try writeReports(
            scenario: scenario,
            backendIdentifier: cold.value.metadata.transferSyntaxUID,
            correctnessHash: expectedHash,
            coldMeasurements: [try measurement(
                id: "cold-public-decode-and-materialize",
                stage: "decode-and-materialize-fused",
                samples: [cold.seconds],
                work: work,
                resources: resources
            )],
            warmMeasurements: [try measurement(
                id: "warm-public-decode-and-materialize",
                stage: "decode-and-materialize-fused",
                samples: samples,
                work: work,
                resources: resources
            )],
            warmups: 2,
            iterations: iterations
        )
    }

    private func benchmarkNativeMultiframe(scenario: Scenario) async throws {
        let frameCount = 32
        let width = 512
        let height = 512
        let frames = (0..<frameCount).map { frameIndex in
            Data((0..<(width * height)).map { UInt8(truncatingIfNeeded: $0 + frameIndex) })
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dicom-materialization-\(UUID().uuidString).dcm")
        try Self.nativeMultiframeFile(frames: frames, width: width, height: height).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DicomDecodedFrameReader(contentsOf: url)
        let residentBefore = Self.currentResidentMemoryBytes()
        let cold = try await Self.timed {
            var hashes = [UInt64]()
            for try await frame in reader.frames() {
                hashes.append(Self.pixelHash(frame.pixels))
            }
            return hashes
        }
        XCTAssertEqual(cold.value.count, frameCount)
        let iterations = 4
        var samples = [Double]()
        for _ in 0..<iterations {
            let result = try await Self.timed {
                var hashes = [UInt64]()
                for try await frame in reader.frames() {
                    hashes.append(Self.pixelHash(frame.pixels))
                }
                return hashes
            }
            samples.append(result.seconds / Double(frameCount))
            XCTAssertEqual(result.value, cold.value)
        }
        let payloadBytes = UInt64(width * height)
        let resources = ClinicalPerformanceResourceMetrics(
            peakRSSBytes: BenchmarkMemorySampler.currentPeakResidentMemoryBytes(),
            residentDeltaBytes: Self.signedDifference(Self.currentResidentMemoryBytes(), residentBefore),
            cpuCopyCount: frameCount
        )
        let work = ClinicalPerformanceWorkMetrics(
            usefulBytes: payloadBytes * UInt64(frameCount),
            duplicatedBytes: payloadBytes * UInt64(frameCount)
        )
        try writeReports(
            scenario: scenario,
            backendIdentifier: "native-uncompressed",
            correctnessHash: cold.value.reduce(14_695_981_039_346_656_037) { ($0 ^ $1) &* 1_099_511_628_211 },
            coldMeasurements: [try measurement(
                id: "cold-multiframe-per-frame",
                stage: "multiframe-decode-and-materialize",
                samples: [cold.seconds / Double(frameCount)],
                work: work,
                resources: resources
            )],
            warmMeasurements: [try measurement(
                id: "warm-multiframe-per-frame",
                stage: "multiframe-decode-and-materialize",
                samples: samples,
                work: work,
                resources: resources
            )],
            warmups: 0,
            iterations: iterations
        )
    }

    private func measurement(
        id: String,
        stage: String,
        samples: [Double],
        work: ClinicalPerformanceWorkMetrics,
        resources: ClinicalPerformanceResourceMetrics
    ) throws -> ClinicalPerformanceMeasurement {
        let environment = performanceEnvironment(mode: id.hasPrefix("cold") ? .coldSDKFirstCall : .warmIsolated)
        return ClinicalPerformanceEvaluator.evaluate(
            metricID: id,
            stage: stage,
            unit: "seconds-per-frame",
            statistics: try ClinicalPerformanceStatistics(samples: samples),
            correctnessPassed: true,
            gate: ClinicalPerformanceGate(
                warningLimit: 60,
                failureLimit: 120,
                relativeWarningPercent: 100,
                relativeFailurePercent: 200,
                lowerIsBetter: true
            ),
            environment: environment,
            work: work,
            resources: resources
        )
    }

    private func writeReports(
        scenario: Scenario,
        backendIdentifier: String,
        correctnessHash: UInt64,
        coldMeasurements: [ClinicalPerformanceMeasurement],
        warmMeasurements: [ClinicalPerformanceMeasurement],
        warmups: Int,
        iterations: Int
    ) throws {
        let run = ProcessInfo.processInfo.environment[Self.runKey] ?? "unspecified"
        let reports = [
            ("cold", ClinicalPerformanceBenchmarkMode.coldSDKFirstCall, coldMeasurements),
            ("warm", ClinicalPerformanceBenchmarkMode.warmIsolated, warmMeasurements)
        ]
        for (stem, mode, measurements) in reports {
            let report = ClinicalPerformanceReport(
                schemaVersion: 1,
                generatedAt: Date(),
                environment: performanceEnvironment(mode: mode),
                warmupIterations: stem == "cold" ? 0 : warmups,
                benchmarkIterations: stem == "cold" ? 1 : iterations,
                backendFlags: [
                    "backend": backendIdentifier,
                    "coldMeasurementSemantics": "first-decode-after-fixture-and-backend-preparation",
                    "correctnessHashFNV1a64": String(correctnessHash, radix: 16),
                    "scenario": scenario.rawValue,
                    "isolatedRun": run,
                    "materialityRule": "two-of-three:1ms,10percent,one-payload-multiframe"
                ],
                conformanceManifest: "ClinicalCodecConformanceManifest.json",
                measurements: measurements
            )
            try Self.write(report, stem: "decoded-frame-\(scenario.rawValue)-\(stem)-run-\(run)")
        }
    }

    private func performanceEnvironment(mode: ClinicalPerformanceBenchmarkMode) -> ClinicalPerformanceEnvironment {
        let platform = PlatformInfo()
        return ClinicalPerformanceEnvironment(
            deviceName: platform.modelIdentifier,
            osVersion: platform.osVersion,
            architecture: platform.architecture,
            modelIdentifier: platform.modelIdentifier,
            buildConfiguration: "release",
            benchmarkMode: mode,
            fixtureID: ProcessInfo.processInfo.environment[Self.scenarioKey] ?? "unknown",
            tier: .release,
            commandLineStartupIncluded: false
        )
    }

    private static func write(_ report: ClinicalPerformanceReport, stem: String) throws {
        guard let outputPath = ProcessInfo.processInfo.environment["CLINICAL_PERFORMANCE_OUTPUT_DIR"] else {
            print(try ClinicalPerformanceReporter(report: report).jsonString())
            return
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let reporter = ClinicalPerformanceReporter(report: report)
        try Data(reporter.jsonString().utf8).write(to: output.appendingPathComponent("\(stem).json"))
        try Data(reporter.csvString().utf8).write(to: output.appendingPathComponent("\(stem).csv"))
        try Data(reporter.markdownString().utf8).write(to: output.appendingPathComponent("\(stem).md"))
    }

    private static func descriptor(
        syntax: DicomTransferSyntax,
        width: Int,
        height: Int,
        bitsPerSample: Int,
        componentCount: Int,
        signed: Bool
    ) -> DicomCompressedFrameDescriptor {
        DicomCompressedFrameDescriptor(
            transferSyntaxUID: syntax.rawValue,
            rows: height,
            columns: width,
            bitsAllocated: bitsPerSample,
            bitsStored: bitsPerSample,
            highBit: bitsPerSample - 1,
            pixelRepresentation: signed ? 1 : 0,
            samplesPerPixel: componentCount,
            photometricInterpretation: componentCount == 1 ? "MONOCHROME2" : "RGB",
            planarConfiguration: componentCount == 1 ? nil : 0
        )
    }

    private static func sourceBytes(
        width: Int,
        height: Int,
        bitsPerSample: Int,
        componentCount: Int
    ) -> Data {
        let scalarCount = width * height * componentCount
        if bitsPerSample <= 8 {
            return Data((0..<scalarCount).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) })
        }
        var result = Data(capacity: scalarCount * 2)
        for index in 0..<scalarCount {
            let sample = UInt16(truncatingIfNeeded: index * 257 + 123)
            result.append(UInt8(truncatingIfNeeded: sample))
            result.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return result
    }

    private static func materializedResult(
        _ frame: DicomCodecDecodedFrame,
        descriptor: DicomCompressedFrameDescriptor
    ) throws -> DCMPixelReadResult {
        try XCTUnwrap(DCMPixelReader.makeCompressedResult(
            from: frame,
            pixelRepresentation: descriptor.pixelRepresentation,
            photometricInterpretation: descriptor.photometricInterpretation
        ))
    }

    private static func timed<T>(_ operation: () throws -> T) rethrows -> (value: T, seconds: Double) {
        let start = BenchmarkClock.now()
        let value = try operation()
        return (value, BenchmarkClock.secondsElapsed(since: start))
    }

    private static func timed<T>(_ operation: () async throws -> T) async rethrows -> (value: T, seconds: Double) {
        let start = BenchmarkClock.now()
        let value = try await operation()
        return (value, BenchmarkClock.secondsElapsed(since: start))
    }

    private static func pixelHash(_ result: DCMPixelReadResult) -> UInt64 {
        if let pixels = result.pixels24 { return hash(Data(pixels)) }
        if let pixels = result.pixels16 {
            return pixels.withUnsafeBytes { hash(Data($0)) }
        }
        return hash(Data(result.pixels8 ?? []))
    }

    private static func pixelHash(_ pixels: DicomDecodedFramePixelBuffer) -> UInt64 {
        switch pixels {
        case .gray8(let values), .rgb8(let values): return hash(Data(values))
        case .gray16(let values): return values.withUnsafeBytes { hash(Data($0)) }
        }
    }

    private static func byteCount(_ pixels: DicomDecodedFramePixelBuffer) -> Int {
        switch pixels {
        case .gray8(let values), .rgb8(let values): return values.count
        case .gray16(let values): return values.count * MemoryLayout<UInt16>.size
        }
    }

    private static func hash(_ data: Data) -> UInt64 {
        data.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    private static func nativeMultiframeFile(frames: [Data], width: Int, height: Int) throws -> Data {
        var pixelData = Data()
        frames.forEach { pixelData.append($0) }
        let dataSet = DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI,
                             value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI,
                             value: .strings(["2.25.20930001"])),
            DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN,
                             value: .strings(["BENCHMARK^NONPHI"])),
            DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO,
                             value: .strings(["BENCHMARK-2093"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI,
                             value: .strings(["2.25.20930002"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI,
                             value: .strings(["2.25.20930003"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS,
                             value: .strings(["MONOCHROME2"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([UInt(height)])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([UInt(width)])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([8])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([8])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([7])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS,
                             value: .strings(["\(frames.count)"])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(pixelData))
        ])
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .explicitVRLittleEndian,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.20930001"
            )
        )
    }

    private static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    private static func currentResidentMemoryBytes() -> UInt64? {
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

    private static func signedDifference(_ value: UInt64?, _ baseline: UInt64?) -> Int64? {
        guard let value, let baseline else { return nil }
        if value >= baseline {
            return Int64(clamping: value - baseline)
        }
        return -Int64(clamping: baseline - value)
    }
}
