import DicomData
import Foundation
import XCTest
@testable import DicomCore

/// Issue #3036: the YBR profiles of the current GDCM → IsiX envelope (matrix in
/// `Docs/QA/OwnPixelProviderQualification.md`, "Residual YBR profiles"). Expected values never come from the code under
/// test: stored samples are made from RGB patches with the PS3.3 C.7.6.3.1.2 forward equations, and the expected RGB is
/// the numerical inverse of that matrix, rounded half away from zero and clamped once at the end. The own conversion
/// uses the JFIF constants (1.402, 0.344136, 0.714136, 1.772); over every 8-bit input the two differ by at most 1, at
/// rounding ties, which is the documented rounding.
final class DicomYBRResidualProfileTests: XCTestCase {
    typealias Shape = DicomDeepColorTypedFrameTests.Shape

    // MARK: - Mandatory profiles

    /// 8-bit YBR_FULL, Planar Configuration 0 and 1, in every native storage form: little endian (explicit and
    /// implicit), big endian in OB and in OW (word-swapped bytes, PS3.5 7.6.1.1.1). Three frames each.
    func test_nativeYBRFull_everyStorageFormAndPlanarity_decodesToTheIndependentReference() async throws {
        for planar in [0, 1] {
            for form in StorageForm.allCases {
                let shape = Shape(rows: 5, columns: 7, frames: 3, samples: 3, bitsAllocated: 8, bitsStored: 8,
                                  photometric: "YBR_FULL", planar: planar)
                let frames = (0..<shape.frames).map { Self.ybrFullFrame(pixels: shape.rows * shape.columns, frame: $0) }
                let stored = frames.map { planar == 1 ? Self.planes($0) : $0 }
                let data = try form.part10(shape: shape, frames: stored)
                try await assertDecodes(data, shape: shape, triplets: frames, label: "YBR_FULL pc\(planar) \(form)")
            }
        }
    }

    /// 8-bit YBR_FULL_422: packed Y1 Y2 Cb Cr pairs whose chroma jumps between extremes at every pair, so a chroma
    /// sample that bled into the neighbouring pair, or a pair read across a row end, would show. Odd row count, so the
    /// last row is a block border too; three frames, each storage form.
    func test_nativeYBRFull422_pairsRowEndsAndSuccessiveFrames_decodeToTheIndependentReference() async throws {
        for form in StorageForm.allCases {
            let shape = Shape(rows: 5, columns: 8, frames: 3, samples: 3, bitsAllocated: 8, bitsStored: 8,
                              photometric: "YBR_FULL_422", planar: 0)
            let packed = (0..<shape.frames).map { Self.packed422Frame(rows: shape.rows, columns: shape.columns, frame: $0) }
            let triplets = packed.map(Self.expanded422)
            let data = try form.part10(shape: shape, frames: packed)
            try await assertDecodes(data, shape: shape, triplets: triplets, label: "YBR_FULL_422 \(form)")
        }
        // PS3.3 requires Planar Configuration 0 for YBR_FULL_422. A file declaring 1 is read in the only defined
        // layout, the packed pairs, as GDCM and pydicom read it (optional profile, outside the acceptance); the legacy
        // native display buffer keeps refusing it, as its conversion matrix says.
        let labelled = Shape(rows: 3, columns: 4, frames: 1, samples: 3, bitsAllocated: 8, bitsStored: 8, photometric: "YBR_FULL_422", planar: 1)
        let packed = Self.packed422Frame(rows: 3, columns: 4, frame: 0)
        try await assertDecodes(try StorageForm.explicitLittle.part10(shape: labelled, frames: [packed]), shape: labelled,
                                triplets: [Self.expanded422(packed)], label: "YBR_FULL_422 labelled Planar Configuration 1",
                                nativeDisplay: false)
    }

    /// RLE Lossless YBR_FULL (PS3.5 G.2: one segment per component), written by an independent PackBits writer.
    func test_rleYBRFull_decodesToTheIndependentReference() async throws {
        let shape = Shape(rows: 6, columns: 5, frames: 2, samples: 3, bitsAllocated: 8, bitsStored: 8, photometric: "YBR_FULL", planar: 0)
        let frames = (0..<shape.frames).map { Self.ybrFullFrame(pixels: shape.rows * shape.columns, frame: $0) }
        let data = try DicomDeepColorTypedFrameTests.part10(
            shape: shape, fragments: frames.map { Self.rleFrame($0, pixelCount: shape.rows * shape.columns) }, syntax: .rleLossless)
        try await assertDecodes(data, shape: shape, triplets: frames, label: "YBR_FULL RLE", nativeDisplay: false)
    }

    /// The patches the reference covers, checked on their own: neutrals and black/white convert exactly, saturated
    /// colours round-trip within the quantization of the forward transform, and stored extremes whose intermediate
    /// terms leave the range are clipped once, at the end.
    func test_conversion_neutralsExtremesAndSaturationFollowThePS33Equations() throws {
        for value in [0, 1, 16, 128, 235, 254, 255] {
            XCTAssertEqual(Self.convertedByToolkit([UInt8(value), 128, 128]), [UInt8(value), UInt8(value), UInt8(value)], "neutral \(value)")
        }
        for rgb in Self.saturatedPatches {
            let converted = Self.convertedByToolkit(Self.forward(rgb))
            for (component, original) in rgb.enumerated() {
                XCTAssertLessThanOrEqual(abs(Int(converted[component]) - Int(original)), 2,
                                         "\(rgb) round trip: forward quantization (≤ 0.5 per component) times the inverse gains")
            }
        }
        // Intermediate terms far outside 0...255; a premature clip of Y + chroma terms would change G here.
        XCTAssertEqual(Self.convertedByToolkit([128, 255, 0]), [0, 176, 255])
        XCTAssertEqual(Self.convertedByToolkit([255, 0, 255]), [255, 208, 28])
        XCTAssertEqual(Self.convertedByToolkit([0, 0, 0]), [0, 135, 0])
        XCTAssertEqual(Self.convertedByToolkit([255, 255, 255]), [255, 121, 255])
        var largest = 0
        for y in stride(from: 0, through: 255, by: 5) {
            for cb in stride(from: 0, through: 255, by: 3) {
                for cr in stride(from: 0, through: 255, by: 7) {
                    let triplet = [UInt8(y), UInt8(cb), UInt8(cr)]
                    largest = max(largest, zip(Self.convertedByToolkit(triplet), Self.reference(triplet)).map { abs(Int($0) - Int($1)) }.max() ?? 0)
                }
            }
        }
        XCTAssertLessThanOrEqual(largest, 1, "within the documented rounding of the independent inverse")
    }

    // MARK: - Truncation and typed refusals

    func test_truncatedPayloads_failTyped() async throws {
        let cases: [(Shape, Data)] = [
            (Shape(rows: 4, columns: 6, frames: 2, samples: 3, bitsAllocated: 8, bitsStored: 8, photometric: "YBR_FULL_422", planar: 0),
             Data(Self.packed422Frame(rows: 4, columns: 6, frame: 0) + Self.packed422Frame(rows: 4, columns: 6, frame: 1).dropLast(6))),
            (Shape(rows: 4, columns: 6, frames: 2, samples: 3, bitsAllocated: 8, bitsStored: 8, photometric: "YBR_FULL", planar: 1),
             Data(Self.planes(Self.ybrFullFrame(pixels: 24, frame: 0)) + Self.planes(Self.ybrFullFrame(pixels: 24, frame: 1)).dropLast(10))),
            (Shape(rows: 4, columns: 6, frames: 1, samples: 3, bitsAllocated: 8, bitsStored: 8, photometric: "YBR_FULL", planar: 0),
             Data(Self.ybrFullFrame(pixels: 24, frame: 0).dropLast(4)))
        ]
        for (shape, payload) in cases {
            let label = "\(shape.photometric) pc\(shape.planar ?? 0)"
            let data = try DicomDeepColorTypedFrameTests.part10(shape: shape, pixelData: payload, syntax: .explicitVRLittleEndian)
            let reader = try await DicomDecodedFrameReader(decoder: DCMDecoder(data: data))
            for index in 0..<shape.frames {
                XCTAssertThrowsError(try DicomDeepColorTypedFrameTests.syncFrame(reader, index), label) { error in
                    XCTAssertTrue(error is DicomDecodedFrameReader.ReadError, "\(label): \(error)")
                }
                XCTAssertThrowsError(try Self.syncDataBacked(reader, index), label) { error in
                    XCTAssertTrue(error is DicomDecodedFrameReader.ReadError, "\(label): \(error)")
                }
            }
            do {
                _ = try await DicomSourceFrameSession.open(source: DicomByteSource(data: data))
                XCTFail("\(label): the selective session opened a truncated payload")
            } catch {
                XCTAssertTrue(error is DicomSourceFrameIndex.Failure, "\(label): \(error)")
            }
        }
    }

    /// Labels with no conversion are refused typed, by the reader and by the selective session, instead of reaching a
    /// consumer under a label that does not describe the samples or through the full-range equations.
    func test_nativeLabelsWithoutAConversion_areRefusedTyped() async throws {
        let full = Self.ybrFullFrame(pixels: 4 * 6, frame: 0)
        let cases: [(String, Int, Data, String)] = [
            // Same payload size as their RGB twins, so the layout itself does not stop them.
            ("YBR_PARTIAL_422", 6, Data(full), "partial-range"),
            ("YBR_PARTIAL_420", 6, Data(full), "partial-range"),
            ("YBR_RCT", 6, Data(full), "JPEG 2000"),
            ("YBR_ICT", 6, Data(full), "JPEG 2000"),
            ("YBR_FULL_422", 5, Data(count: 4 * 3 * 4), "odd number of columns")
        ]
        for (photometric, columns, payload, reason) in cases {
            let shape = Shape(rows: 4, columns: columns, frames: 1, samples: 3, bitsAllocated: 8, bitsStored: 8, photometric: photometric, planar: 0)
            let data = try DicomDeepColorTypedFrameTests.part10(shape: shape, pixelData: payload, syntax: .explicitVRLittleEndian)
            let reader = try await DicomDecodedFrameReader(decoder: DCMDecoder(data: data))
            for attempt in [{ _ = try DicomDeepColorTypedFrameTests.syncFrame(reader, 0) }, { _ = try Self.syncDataBacked(reader, 0) }] {
                XCTAssertThrowsError(try attempt(), photometric) { error in
                    guard case DicomDecodedFrameReader.ReadError.decodeFailed(_, let message) = error else {
                        return XCTFail("\(photometric): \(error)")
                    }
                    XCTAssertTrue(message.contains(reason), "\(photometric): \(message)")
                }
            }
            do {
                let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: data))
                _ = try await session.frame(at: 0)
                XCTFail("\(photometric): the session delivered a frame")
            } catch DicomDecodedFrameReader.ReadError.decodeFailed(_, let message) {
                XCTAssertTrue(message.contains(reason), "\(photometric): \(message)")
            } catch {
                XCTAssertTrue(error is DicomSourceFrameIndex.Failure, "\(photometric): \(error)")
            }
        }
    }

    /// The DCT decoders apply the full-range JFIF transform, so a partial-range label over a JPEG codestream is refused
    /// by the capability resolution and by the reader; the full-range labels still decode.
    func test_jpegBaselineUnderAPartialRangeLabel_isRefusedTyped() async throws {
        let rgbShape = Shape(rows: 16, columns: 16, frames: 1, samples: 3, bitsAllocated: 8, bitsStored: 8, photometric: "RGB", planar: 0)
        let rgb = Data((0..<(16 * 16 * 3)).map { UInt8(($0 * 37) % 256) })
        let native = try DicomDeepColorTypedFrameTests.part10(shape: rgbShape, pixelData: rgb, syntax: .explicitVRLittleEndian)
        let jpeg = try await DicomCodecWorkflowEngine().transcode(native, to: .jpegBaseline, intent: .irreversible(quality: 0.9),
                                                                  verifyDecodedPixels: false).data
        let fragment = try await DCMDecoder(data: jpeg).makeEncapsulatedPixelFrameReader().frameData(at: 0)
        for (photometric, refused) in [("YBR_PARTIAL_422", true), ("YBR_PARTIAL_420", true), ("YBR_FULL_422", false)] {
            var shape = rgbShape
            shape.photometric = photometric
            let descriptor = DicomCompressedFrameDescriptor(
                transferSyntaxUID: DicomTransferSyntax.jpegBaseline.rawValue, rows: 16, columns: 16, bitsAllocated: 8, bitsStored: 8,
                highBit: 7, pixelRepresentation: 0, samplesPerPixel: 3, photometricInterpretation: photometric, planarConfiguration: 0)
            let decision = DicomCodecCapabilities.resolve(DicomCodecCapabilityRequest(operation: .decode, descriptor: descriptor))
            XCTAssertEqual(decision.canExecute, !refused, photometric)
            if refused { XCTAssertTrue(decision.reason?.contains("partial-range") == true, "\(photometric): \(decision.reason ?? "")") }
            let data = try DicomDeepColorTypedFrameTests.part10(shape: shape, fragments: [fragment], syntax: .jpegBaseline)
            let reader = try await DicomDecodedFrameReader(decoder: DCMDecoder(data: data))
            if refused {
                XCTAssertThrowsError(try DicomDeepColorTypedFrameTests.syncFrame(reader, 0), photometric) { error in
                    guard case DicomDecodedFrameReader.ReadError.unsupportedTransferSyntax(_, let diagnostics) = error else {
                        return XCTFail("\(photometric): \(error)")
                    }
                    XCTAssertTrue(diagnostics.joined().contains("partial-range"), "\(photometric): \(diagnostics)")
                }
                do {
                    _ = try await reader.frame(at: 0)
                    XCTFail("\(photometric): the async decode delivered a frame")
                } catch let error as DicomDecodedFrameReader.ReadError {
                    guard case .unsupportedTransferSyntax = error else { return XCTFail("\(photometric): \(error)") }
                }
            } else {
                XCTAssertEqual(try DicomDeepColorTypedFrameTests.syncFrame(reader, 0).metadata.width, 16, photometric)
            }
        }
    }

    // MARK: - Opt-in cost report

    /// Time, peak footprint and copies of the changed native paths, one frame at a time through the selective session
    /// (the route of the IsiX adapter), then the display conversion. Planar Configuration 0 is the unchanged reference.
    /// Opt-in (`DICOM_YBR_COST=1`); run with `-c release` for representative times.
    func test_costReport_measuresTheChangedNativeYBRPaths() async throws {
        guard ProcessInfo.processInfo.environment["DICOM_YBR_COST"] == "1" else {
            throw XCTSkip("Set DICOM_YBR_COST=1 to measure the native YBR paths.")
        }
        let rows = 512, columns = 512, frameCount = 8
        let full = Shape(rows: rows, columns: columns, frames: frameCount, samples: 3, bitsAllocated: 8, bitsStored: 8, photometric: "YBR_FULL", planar: 0)
        var planar = full
        planar.planar = 1
        var packed = full
        packed.photometric = "YBR_FULL_422"
        let frames = (0..<frameCount).map { Self.ybrFullFrame(pixels: rows * columns, frame: $0) }
        let cases: [(String, Data)] = [
            ("YBR_FULL pc0, LE (unchanged reference)", try StorageForm.explicitLittle.part10(shape: full, frames: frames)),
            ("YBR_FULL pc1, LE", try StorageForm.explicitLittle.part10(shape: planar, frames: frames.map(Self.planes))),
            ("YBR_FULL pc1, BE OW", try StorageForm.bigEndianOW.part10(shape: planar, frames: frames.map(Self.planes))),
            ("YBR_FULL_422, LE", try StorageForm.explicitLittle.part10(shape: packed, frames: (0..<frameCount).map {
                Self.packed422Frame(rows: rows, columns: columns, frame: $0) })),
            ("YBR_FULL_422, BE OW", try StorageForm.bigEndianOW.part10(shape: packed, frames: (0..<frameCount).map {
                Self.packed422Frame(rows: rows, columns: columns, frame: $0) }))
        ]
        var report = ["| Profile | Decode ms/frame | Display ms/frame | Peak footprint growth (MiB) | Decoded bytes/frame | Source bytes read | Compatibility copies |",
                      "| --- | --- | --- | --- | --- | --- | --- |"]
        for (label, data) in cases {
            let decoder = try await DCMDecoder(data: data)
            let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: data))
            let baseline = DicomDeepColorTypedFrameTests.physicalFootprint()
            var peak = baseline, decodedBytes = 0
            var decode = Duration.zero, display = Duration.zero
            let clock = ContinuousClock()
            for index in 0..<frameCount {
                var frame: DicomDecodedFrame?
                decode += try await clock.measure { frame = try await session.frame(at: index) }
                let decoded = try XCTUnwrap(frame)
                decodedBytes = decoded.storedSampleData().count
                display += try clock.measure { _ = try decoder.displayRGB8(decodedFrame: decoded) }
                peak = max(peak, DicomDeepColorTypedFrameTests.physicalFootprint())
            }
            let metrics = await session.metrics
            func perFrame(_ duration: Duration) -> String {
                String(format: "%.2f", (Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15) / Double(frameCount))
            }
            report.append("| \(label) | \(perFrame(decode)) | \(perFrame(display)) | \(String(format: "%.1f", Double(peak - baseline) / 1_048_576)) | "
                + "\(decodedBytes) | \(metrics.source.receivedBytes) | \(metrics.source.compatibilityCopiedBytes) |")
            XCTAssertEqual(metrics.retainedCompletedBytes, 0)
            await session.close()
        }
        print(report.joined(separator: "\n"))
    }

    // MARK: - Assertions

    /// Each decode route the toolkit offers: the whole-object reader (array- and Data-backed), the selective session
    /// the IsiX adapter uses, the stored-sample contract (Y Cb Cr triplets, label kept), the display conversion of a
    /// decoded frame and, for native objects, the legacy native display buffer.
    private func assertDecodes(_ data: Data, shape: Shape, triplets: [[UInt8]], label: String, nativeDisplay: Bool = true,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let decoder = try await DCMDecoder(data: data)
        let reader = try DicomDecodedFrameReader(decoder: decoder)
        let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: data))
        defer { Task { await session.close() } }
        for index in 0..<shape.frames {
            let expectedRGB = Data(triplets[index].chunked(3).flatMap { Self.reference($0) })
            let frame = try DicomDeepColorTypedFrameTests.syncFrame(reader, index)
            XCTAssertEqual(frame.pixels, .rgb8(interleaved: triplets[index]), "\(label) frame \(index): stored triplets", file: file, line: line)
            XCTAssertEqual(frame.metadata.photometricInterpretation, shape.photometric, "\(label): label kept", file: file, line: line)
            XCTAssertEqual(try Self.syncDataBacked(reader, index).pixels.data, Data(triplets[index]), "\(label) frame \(index): data-backed",
                           file: file, line: line)
            let selective = try await session.frame(at: index)
            XCTAssertEqual(selective.pixels, frame.pixels, "\(label) frame \(index): selective session", file: file, line: line)
            let display = try decoder.displayRGB8(decodedFrame: selective)
            XCTAssertEqual(display.count, expectedRGB.count, label, file: file, line: line)
            let difference = zip(display, expectedRGB).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(difference, 1, "\(label) frame \(index): display within the documented rounding", file: file, line: line)
            if nativeDisplay {
                XCTAssertEqual(try decoder.displayRGBPixelBuffer(frame: index).rgbData, display, "\(label) frame \(index): native display",
                               file: file, line: line)
            }
        }
    }

    // MARK: - Fixtures and the independent reference

    static func syncDataBacked(_ reader: DicomDecodedFrameReader, _ index: Int) throws -> DicomDataBackedDecodedFrame {
        try reader.dataBackedFrame(at: index)
    }

    enum StorageForm: CaseIterable, CustomStringConvertible {
        case explicitLittle, implicitLittle, bigEndianOB, bigEndianOW

        var description: String {
            switch self {
            case .explicitLittle: "explicit VR LE"
            case .implicitLittle: "implicit VR LE"
            case .bigEndianOB: "explicit VR BE, OB"
            case .bigEndianOW: "explicit VR BE, OW"
            }
        }

        func part10(shape: Shape, frames: [[UInt8]]) throws -> Data {
            var bytes = frames.flatMap { $0 }
            let syntax: DicomTransferSyntax
            switch self {
            case .explicitLittle: syntax = .explicitVRLittleEndian
            case .implicitLittle: syntax = .implicitVRLittleEndian
            case .bigEndianOB, .bigEndianOW: syntax = .explicitVRBigEndian
            }
            guard self == .bigEndianOW else {
                return try DicomDeepColorTypedFrameTests.part10(shape: shape, pixelData: Data(bytes), syntax: syntax)
            }
            // OW under Explicit VR Big Endian is a stream of 16-bit words, each stored most significant byte first, so
            // every byte pair of the 8-bit stream is swapped on disk; the writer copies the value verbatim.
            if !bytes.count.isMultiple(of: 2) { bytes.append(0) }
            for pair in stride(from: 0, to: bytes.count, by: 2) { bytes.swapAt(pair, pair + 1) }
            let set = DicomDeepColorTypedFrameTests.dataSet(shape: shape)
                .setting(.init(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(Data(bytes))))
            return try DicomDataSetWriter.part10Data(from: set, options: .init(transferSyntax: syntax))
        }
    }

    /// Black, white, mid grey, saturated primaries and secondaries.
    static let saturatedPatches: [[UInt8]] = [[0, 0, 0], [255, 255, 255], [128, 128, 128], [255, 0, 0], [0, 255, 0], [0, 0, 255],
                                              [0, 255, 255], [255, 0, 255], [255, 255, 0]]

    /// Interleaved Y Cb Cr triplets: the patches above through the forward equations, neutrals, every stored extreme
    /// combination, then a frame-dependent ramp with noise.
    static func ybrFullFrame(pixels: Int, frame: Int) -> [UInt8] {
        let fixed: [[UInt8]] = saturatedPatches.map(forward) + [[16, 128, 128], [235, 128, 128]]
            + [0, 255].flatMap { y in [0, 255].flatMap { cb in [0, 255].map { cr in [UInt8(y), UInt8(cb), UInt8(cr)] } } }
        var state = UInt32(17 + frame)
        return (0..<pixels).flatMap { pixel -> [UInt8] in
            if pixel < fixed.count, frame == 0 { return fixed[pixel] }
            state = state &* 1_664_525 &+ 1_013_904_223
            return [UInt8((pixel * 13 + frame * 29) % 256), UInt8(state >> 24), UInt8((state >> 8) & 0xFF)]
        }
    }

    /// Packed YBR_FULL_422 pairs: two different lumas, chroma alternating between extremes from pair to pair (and
    /// shifted per frame and per row).
    static func packed422Frame(rows: Int, columns: Int, frame: Int) -> [UInt8] {
        (0..<rows).flatMap { row in
            (0..<(columns / 2)).flatMap { pair -> [UInt8] in
                let odd = (pair + row + frame) % 2 == 1
                return [UInt8((pair * 40 + row * 7 + frame) % 256), UInt8(255 - (pair * 31 + frame * 3) % 256),
                        odd ? 255 : 0, odd ? 16 : 240]
            }
        }
    }

    /// Both pixels of a pair take the pair's chroma.
    static func expanded422(_ packed: [UInt8]) -> [UInt8] {
        packed.chunked(4).flatMap { quad in [quad[0], quad[2], quad[3], quad[1], quad[2], quad[3]] }
    }

    static func planes(_ interleaved: [UInt8]) -> [UInt8] {
        (0..<3).flatMap { component in stride(from: component, to: interleaved.count, by: 3).map { interleaved[$0] } }
    }

    /// PS3.3 C.7.6.3.1.2 YBR_FULL: Y = .2990R + .5870G + .1140B, CB = −.1687R − .3313G + .5000B + 128,
    /// CR = .5000R − .4187G − .0813B + 128, rounded and kept in 0...255.
    static let forwardMatrix: [[Double]] = [[0.2990, 0.5870, 0.1140], [-0.1687, -0.3313, 0.5000], [0.5000, -0.4187, -0.0813]]

    static func forward(_ rgb: [UInt8]) -> [UInt8] {
        let offsets = [0.0, 128.0, 128.0]
        return (0..<3).map { row in
            clamped(offsets[row] + (0..<3).reduce(0.0) { $0 + forwardMatrix[row][$1] * Double(rgb[$1]) })
        }
    }

    /// The inverse of `forwardMatrix`, by cofactors: not the constants of the code under test.
    static let inverseMatrix: [[Double]] = {
        let m = forwardMatrix
        let cofactor: (Int, Int) -> Double = { row, column in
            let rows = (0..<3).filter { $0 != row }, columns = (0..<3).filter { $0 != column }
            let minor = m[rows[0]][columns[0]] * m[rows[1]][columns[1]] - m[rows[0]][columns[1]] * m[rows[1]][columns[0]]
            return (row + column).isMultiple(of: 2) ? minor : -minor
        }
        let determinant = (0..<3).reduce(0.0) { $0 + m[0][$1] * cofactor(0, $1) }
        return (0..<3).map { row in (0..<3).map { column in cofactor(column, row) / determinant } }
    }()

    static func reference(_ triplet: [UInt8]) -> [UInt8] {
        let centred = [Double(triplet[0]), Double(triplet[1]) - 128, Double(triplet[2]) - 128]
        return (0..<3).map { row in clamped((0..<3).reduce(0.0) { $0 + inverseMatrix[row][$1] * centred[$1] }) }
    }

    static func clamped(_ value: Double) -> UInt8 { UInt8(max(0, min(255, value.rounded(.toNearestOrAwayFromZero)))) }

    /// The toolkit's conversion of one stored triplet (internal helper shared by every YBR display path).
    static func convertedByToolkit(_ triplet: [UInt8]) -> [UInt8] {
        let rgb = DCMDecoder.ybrToRgb(y: triplet[0], cb: triplet[1], cr: triplet[2])
        return [rgb.0, rgb.1, rgb.2]
    }

    /// PS3.5 G.2 for 8-bit three-sample frames, written independently of the codec: one segment per component, each
    /// a sequence of literal PackBits runs.
    static func rleFrame(_ interleaved: [UInt8], pixelCount: Int) -> Data {
        let segments: [[UInt8]] = (0..<3).map { component in
            let bytes = (0..<pixelCount).map { interleaved[$0 * 3 + component] }
            var packed: [UInt8] = []
            var start = 0
            while start < bytes.count {
                let run = min(128, bytes.count - start)
                packed.append(UInt8(run - 1))
                packed.append(contentsOf: bytes[start..<(start + run)])
                start += run
            }
            if !packed.count.isMultiple(of: 2) { packed.append(0) }
            return packed
        }
        var header = [UInt32](repeating: 0, count: 16)
        header[0] = UInt32(segments.count)
        var offset = 64
        for (index, segment) in segments.enumerated() {
            header[index + 1] = UInt32(offset)
            offset += segment.count
        }
        var data = Data()
        for word in header { withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) } }
        for segment in segments { data.append(contentsOf: segment) }
        return data
    }
}

private extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
