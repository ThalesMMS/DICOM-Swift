import DicomCore
import DicomTestSupport
import XCTest

/// Issue #2836: error metrics between two DICOM images, checked by hand and against DCMTK's dcmicmp.
final class DicomImageComparisonTests: XCTestCase {
    func test_differenceCollection_isOptInAndKeepsMetricsUnchanged() throws {
        let urls = try pair()
        let reference = try DCMDecoder(contentsOf: urls.reference)
        let test = try DCMDecoder(contentsOf: urls.test)
        let metricsOnly = try DicomImageComparison.compare(reference: reference, test: test)
        let collected = try DicomImageComparison.compare(reference: reference, test: test, collectDifferences: true)
        XCTAssertTrue(metricsOnly.absoluteDifferences.isEmpty)
        XCTAssertEqual(collected.absoluteDifferences.map(\.count), [48, 48])
        XCTAssertEqual(collected.absoluteDifferences[0][0], 3)
        XCTAssertEqual(metricsOnly.frames, collected.frames)
        XCTAssertEqual(metricsOnly.total, collected.total)
    }

    func test_incompleteDecodedFrame_isRejectedEvenWhenPrefixesMatch() throws {
        var encoded = try ClinicalParityCuratedFixtureTests.makeJPEGLosslessFixtureData()
        for (tag, value) in [(UInt8(0x10), UInt8(1)), (UInt8(0x11), UInt8(8))] {
            let range = try XCTUnwrap(encoded.range(of: Data([0x28, 0, tag, 0, 0x55, 0x53, 2, 0, 2, 0])))
            encoded[range.lowerBound + 8] = value
        }
        let url = directory.appendingPathComponent("incomplete.dcm")
        try encoded.write(to: url)
        let incomplete = try DCMDecoder(contentsOf: url)
        let samples = try DicomDecodedFrameReader(decoder: incomplete).frame(at: 0).storedSampleData()
        let prefix = stride(from: 0, to: samples.count, by: 2).map {
            Int16(bitPattern: UInt16(samples[$0]) | UInt16(samples[$0 + 1]) << 8)
        }
        XCTAssertEqual(prefix.count, 4)
        let complete = try DCMDecoder(contentsOf: write("complete", values: prefix + prefix, rows: 1, signed: false))
        for reference in [complete, incomplete] {
            for collect in [false, true] {
                XCTAssertThrowsError(try DicomImageComparison.compare(reference: reference, test: incomplete,
                    stage: .stored, collectDifferences: collect)) { error in
                    guard case let DicomImageComparison.ComparisonError.undecodableFrame(index, reason) = error else {
                        return XCTFail("Expected undecodableFrame, got \(error)")
                    }
                    XCTAssertEqual(index, 0)
                    XCTAssertTrue(reason.contains("Expected 8 samples"), reason)
                }
            }
        }
    }

    func test_monochrome1_comparesStoredValuesBeforeRescaleOrWindow() throws {
        for bits in [8, 16] {
            for signed in [false, true] {
                let values: [Int16] = signed ? [-3, 0, 1, 5, 9, 15, 20, 30] : [0, 2, 3, 5, 9, 15, 20, 30]
                let name = "\(bits)-\(signed)"
                let reference = try DCMDecoder(contentsOf: write("mono1-\(name)", values: values, rows: 1,
                    bits: bits, signed: signed, photometric: "MONOCHROME1", slope: 2, intercept: -10))
                let test = try DCMDecoder(contentsOf: write("mono2-\(name)", values: values, rows: 1,
                    bits: bits, signed: signed, slope: 1, intercept: -5))
                XCTAssertEqual(try DicomImageComparison.compare(reference: reference, test: test, stage: .stored)
                    .total.maximumAbsoluteError, 0)
                let expected = DicomImageComparison.metrics(reference: values.map { Double($0) * 2 - 10 },
                                                             test: values.map { Double($0) - 5 })
                XCTAssertEqual(try DicomImageComparison.compare(reference: reference, test: test).total, expected)
                let control = try DCMDecoder(contentsOf: write("control-\(name)", values: values, rows: 1,
                    bits: bits, signed: signed, photometric: "MONOCHROME1", slope: 2, intercept: -10))
                XCTAssertEqual(try DicomImageComparison.compare(reference: reference, test: control,
                    stage: .window(center: 10, width: 30)).total.maximumAbsoluteError, 0)
            }
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("icmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Two frames of 8 × 6 signed 16-bit values with Rescale Intercept −1024; the test copy adds a deterministic
    /// error of −3...3 to every third sample.
    private func pair(photometric: String = "MONOCHROME2") throws -> (reference: URL, test: URL) {
        func stored(_ index: Int, noisy: Bool) -> Int16 {
            let base = Int16(index * 37 % 1500 - 200)
            return noisy && index % 3 == 0 ? base + Int16(index % 7 - 3) : base
        }
        return (try write("reference", values: (0..<96).map { stored($0, noisy: false) }, photometric: photometric),
                try write("test", values: (0..<96).map { stored($0, noisy: true) }, photometric: photometric))
    }

    private func write(_ name: String, values: [Int16], rows: Int = 6, bits: Int = 16, signed: Bool = true,
                       photometric: String = "MONOCHROME2", slope: Double = 1, intercept: Double = -1024) throws -> URL {
        var pixels = Data()
        for value in values {
            let word = UInt16(bitPattern: value)
            pixels.append(UInt8(word & 0xFF))
            if bits == 16 { pixels.append(UInt8(word >> 8)) }
        }
        func text(_ tag: DicomTag, _ vr: DicomVR, _ value: String) -> DicomDataElement {
            DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings([value]))
        }
        func short(_ tag: DicomTag, _ value: UInt) -> DicomDataElement {
            DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([value]))
        }
        let sopClassUID = "1.2.840.10008.5.1.4.1.1.7.3"
        let uid = "2.25.2836\(name.count)"
        let data = try DicomDataSetWriter.part10Data(
            from: DicomDataSet(elements: [
                text(.sopClassUID, .UI, sopClassUID), text(.sopInstanceUID, .UI, uid), text(.modality, .CS, "OT"),
                text(.numberOfFrames, .IS, "\(values.count / (8 * rows))"),
                DicomDataElement(tag: 0x0028_0009, vr: .AT, value: .unsignedIntegers([0x0018_2002])),
                short(.samplesPerPixel, 1), text(.photometricInterpretation, .CS, photometric),
                short(.rows, UInt(rows)), short(.columns, 8), short(.bitsAllocated, UInt(bits)), short(.bitsStored, UInt(bits)),
                short(.highBit, UInt(bits - 1)), short(.pixelRepresentation, signed ? 1 : 0),
                text(.rescaleIntercept, .DS, "\(intercept)"), text(.rescaleSlope, .DS, "\(slope)"),
                DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: bits == 16 ? .OW : .OB, value: .bytes(pixels))
            ]),
            options: DicomPart10WriterOptions(transferSyntax: .explicitVRLittleEndian,
                                              mediaStorageSOPClassUID: sopClassUID, mediaStorageSOPInstanceUID: uid)
        )
        let url = directory.appendingPathComponent("\(name).dcm")
        try data.write(to: url)
        return url
    }

    func test_metrics_matchTheirDefinitions() throws {
        let (referenceURL, testURL) = try pair()
        let reference = try DCMDecoder(contentsOf: referenceURL)
        let result = try DicomImageComparison.compare(reference: reference, test: try DCMDecoder(contentsOf: testURL))
        XCTAssertEqual(result.frames.count, 2)
        var differences: [Double] = []
        var references: [Double] = []
        for index in 0..<96 {
            let error: Int = index % 3 == 0 ? abs(index % 7 - 3) : 0
            let value: Int = index * 37 % 1500 - 1224
            differences.append(Double(error))
            references.append(Double(value))
        }
        let squareErrors = differences.map { $0 * $0 }.reduce(0, +)
        XCTAssertEqual(result.total.maximumAbsoluteError, 3)
        XCTAssertEqual(result.total.meanAbsoluteError, differences.reduce(0, +) / 96, accuracy: 1e-12)
        XCTAssertEqual(result.total.rootMeanSquareError, (squareErrors / 96).squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(result.total.peakSignalToNoiseRatio,
                       -10 * log10(squareErrors / 96 / references.map { $0 * $0 }.max()!), accuracy: 1e-9)
        XCTAssertEqual(result.total.signalToNoiseRatio,
                       10 * log10(references.map { $0 * $0 }.reduce(0, +) / squareErrors), accuracy: 1e-9)
        XCTAssertEqual(try DicomImageComparison.compare(reference: reference, test: reference).total.peakSignalToNoiseRatio,
                       .infinity)
    }

    func test_differentGeometry_isRefusedTyped() throws {
        let (referenceURL, _) = try pair()
        let smaller = try write("smaller", values: [Int16](repeating: 0, count: 40), rows: 5)
        XCTAssertThrowsError(try DicomImageComparison.compare(reference: try DCMDecoder(contentsOf: referenceURL),
                                                              test: try DCMDecoder(contentsOf: smaller))) { error in
            guard case DicomImageComparison.ComparisonError.geometryMismatch = error else {
                return XCTFail("expected geometryMismatch, got \(error)")
            }
        }
    }

    /// dcmicmp's own report (opt-in `DCMTK_BIN_DIR`/`DCMTK_DATA_DIR`): stored, modality and windowed values.
    func test_metrics_matchDCMTKDcmicmp() throws {
        let toolchain = try DCMTKToolchain.required()
        for (stage, arguments, photometric) in [
            (DicomImageComparison.Stage.modality, [String](), "MONOCHROME2"),
            (.window(center: -600, width: 800), ["+Ww", "-600", "800"], "MONOCHROME2"),
            (.stored, ["-M"], "MONOCHROME1"), (.modality, [], "MONOCHROME1"),
            (.window(center: -600, width: 800), ["+Ww", "-600", "800"], "MONOCHROME1")
        ] {
            let (referenceURL, testURL) = try pair(photometric: photometric)
            let reference = try DCMDecoder(contentsOf: referenceURL)
            let test = try DCMDecoder(contentsOf: testURL)
            let report = try toolchain.run("dcmicmp", arguments + [referenceURL.path, testURL.path])
            func value(_ label: String) throws -> Double {
                let line = try XCTUnwrap(report.split(separator: "\n").first { $0.hasPrefix(label) }, report)
                return try XCTUnwrap(Double(line.split(separator: "=").last!.trimmingCharacters(in: .whitespaces)))
            }
            let total = try DicomImageComparison.compare(reference: reference, test: test, stage: stage).total
            XCTAssertEqual(total.maximumAbsoluteError, try value("Max Absolute Error"), "\(stage)")
            XCTAssertEqual(total.meanAbsoluteError, try value("Mean Absolute Error"), accuracy: 1e-4, "\(stage)")
            XCTAssertEqual(total.rootMeanSquareError, try value("Root Mean Square Error"), accuracy: 1e-4, "\(stage)")
            XCTAssertEqual(total.peakSignalToNoiseRatio, try value("Peak Signal to Noise Ratio"), accuracy: 1e-3,
                           "\(stage)")
            XCTAssertEqual(total.signalToNoiseRatio, try value("Signal to Noise Ratio"), accuracy: 1e-3, "\(stage)")
        }
    }
}
