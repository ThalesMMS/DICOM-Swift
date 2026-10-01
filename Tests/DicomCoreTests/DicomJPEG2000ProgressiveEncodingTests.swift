import DicomCodecs
import DicomTestSupport
import Foundation
import XCTest
@testable import DicomCore

final class DicomJPEG2000ProgressiveEncodingTests: XCTestCase {
    private let width = 128
    private let height = 96

    private var samples: Data {
        Data((0..<(width * height)).map { i in
            let x = i % width, y = i / width
            return UInt8((x * 3 + y * 2 + (x / 7 % 2) * 35 + (y / 9 % 2) * 21) % 256)
        })
    }

    private func descriptor(_ syntax: DicomTransferSyntax = .jpeg2000Lossless) -> DicomCompressedFrameDescriptor {
        .init(transferSyntaxUID: syntax.rawValue, rows: height, columns: width, bitsAllocated: 8,
              bitsStored: 8, highBit: 7, pixelRepresentation: 0, samplesPerPixel: 1,
              photometricInterpretation: "MONOCHROME2", planarConfiguration: nil)
    }

    private func encode(_ syntax: DicomTransferSyntax = .jpeg2000Lossless,
                        options: DicomJPEG2000EncodingOptions? = nil,
                        intent: DicomEncodingIntent = .reversible) async throws -> Data {
        try await DicomJ2KSwiftBackend().encode(.init(
            frame: .init(buffer: .owned(samples), width: width, height: height, bitsPerSample: 8, componentCount: 1),
            descriptor: descriptor(syntax), targetTransferSyntaxUID: syntax.rawValue,
            intent: intent, jpeg2000Options: options))
    }

    private func nativeFile() throws -> Data {
        var dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .explicitVRLittleEndian, fragments: [], declaredFrames: 1,
            rows: height, columns: width, bitsAllocated: 8, bitsStored: 8, highBit: 7,
            samplesPerPixel: 1, photometricInterpretation: "MONOCHROME2")
        dataSet.set(.init(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(samples)))
        return try DicomDataSetWriter.part10Data(from: dataSet, options: .init(
            transferSyntax: .explicitVRLittleEndian,
            mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
            mediaStorageSOPInstanceUID: "2.25.23980001"))
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("isis-2398-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// CLI oracle: unavailable executables skip; a decoder failure is a test failure, never a skip.
    private func oracle(_ stream: Data, in directory: URL, layers: Int? = nil, reduce: Int = 0,
                        openJPH: Bool = false, precision: Int = 8, signed: Bool = false) throws -> Data {
        let executable = "/opt/homebrew/bin/\(openJPH ? "ojph_expand" : "opj_decompress")"
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("Missing independent decoder: \(executable)") }
        let input = directory.appendingPathComponent("input.j2k")
        let output = directory.appendingPathComponent(openJPH ? "output.pgm" : "output.rawl")
        try stream.write(to: input)
        try? FileManager.default.removeItem(at: output)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-i", input.path, "-o", output.path]
        if openJPH {
            process.arguments! += ["-skip_res", "\(reduce)"]
        } else {
            process.arguments! += ["-r", "\(reduce)"]
            if let layers { process.arguments! += ["-l", "\(layers)"] }
        }
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let diagnostic = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: diagnostic, as: UTF8.self))
        guard process.terminationStatus == 0 else { throw NSError(domain: "JPEG2000Oracle", code: Int(process.terminationStatus)) }
        let data = try Data(contentsOf: output)
        if openJPH {
            // PGM clips unsigned wavelet overshoot; OpenJPH's raw writer wraps it instead.
            var cursor = 0
            func token() -> String {
                while cursor < data.count {
                    if data[cursor] == 35 {
                        while cursor < data.count, data[cursor] != 10 { cursor += 1 }
                    } else if [9, 10, 13, 32].contains(data[cursor]) { cursor += 1 } else { break }
                }
                let start = cursor
                while cursor < data.count, ![9, 10, 13, 32].contains(data[cursor]) { cursor += 1 }
                return String(decoding: data[start..<cursor], as: UTF8.self)
            }
            XCTAssertEqual(token(), "P5")
            _ = token(); _ = token()
            XCTAssertEqual(token(), "255")
            return Data(data.dropFirst(cursor + 1))
        }
        if signed, precision > 8 {
            // RAWL contains precision-wide two's-complement codes, without 16-bit sign extension.
            var normalized = Data()
            let mask = (1 << precision) - 1, sign = 1 << (precision - 1)
            for i in stride(from: 0, to: data.count, by: 2) {
                let code = (Int(data[i]) | Int(data[i + 1]) << 8) & mask
                let value = UInt16(truncatingIfNeeded: code & sign == 0 ? code : code - (1 << precision))
                normalized.append(UInt8(truncatingIfNeeded: value)); normalized.append(UInt8(value >> 8))
            }
            return normalized
        }
        return data
    }

    private func mse(_ bytes: Data, reference: Data) -> Double {
        guard bytes.count == reference.count else { return .infinity }
        return zip(bytes, reference).reduce(0) { $0 + pow(Double(Int($1.0) - Int($1.1)), 2) } / Double(bytes.count)
    }

    func test_invalidOptions_areTypedAndDoNotPublishAnArtifact() async throws {
        let invalid: [DicomJPEG2000EncodingOptions] = [
            .init(qualityLayers: 0), .init(qualityLayers: -1), .init(qualityLayers: Int.max),
            .init(decompositionLevels: -1), .init(decompositionLevels: 6), .init(decompositionLevels: Int.max),
            .init(qualityLayers: 2, decompositionLevels: 0), .init(progression: .pcrl),
            .init(progression: .cprl), .init(progression: .rpcl)
        ]
        let data = try nativeFile(), root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("sentinel.dcm")
        let sentinel = Data("preserve-existing-file".utf8)
        try sentinel.write(to: destination)
        for options in invalid {
            XCTAssertThrowsError(try DicomTranscoder().plan(data, to: .jpeg2000Lossless, jpeg2000Options: options)) {
                XCTAssertTrue($0 is DicomJPEG2000EncodingError, "\($0)")
            }
            do {
                _ = try await DicomCodecWorkflowEngine().transcode(data, to: .jpeg2000Lossless,
                    jpeg2000Options: options, destinationURL: destination, progress: nil)
                XCTFail("Unsupported options were accepted: \(options)")
            } catch { XCTAssertTrue(error is DicomJPEG2000EncodingError, "\(error)") }
            XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        }
        for syntax in [DicomTransferSyntax.jpegLSLossless, .jpegBaseline, .rleLossless,
                       .deflatedExplicitVRLittleEndian, .deflatedImageFrameCompression,
                       .jpeg2000Part2MulticomponentLossless, .jpeg2000Part2Multicomponent] {
            XCTAssertThrowsError(try DicomTranscoder().plan(data, to: syntax, jpeg2000Options: .init())) {
                XCTAssertTrue($0 is DicomJPEG2000EncodingError)
            }
        }
        XCTAssertThrowsError(try DicomTranscoder().plan(data, to: .jpeg2000, intent: .jpegLSNearLossless(near: 1), jpeg2000Options: .init()))
        let withoutPixels = try DicomDataSetWriter.part10Data(from: DicomDataSet(), options: .init(transferSyntax: .explicitVRLittleEndian))
        XCTAssertThrowsError(try DicomTranscoder().plan(withoutPixels, to: .jpeg2000Lossless, jpeg2000Options: .init()))
        let oversized = DicomCompressedFrameDescriptor(transferSyntaxUID: DicomTransferSyntax.jpeg2000Lossless.rawValue,
            rows: 96, columns: 32_769, bitsAllocated: 8, bitsStored: 8, highBit: 7,
            pixelRepresentation: 0, samplesPerPixel: 1, photometricInterpretation: "MONOCHROME2", planarConfiguration: nil)
        XCTAssertThrowsError(try DicomJPEG2000EncodingOptions().resolved(descriptor: oversized, intent: .reversible))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["sentinel.dcm"])
    }

    func test_defaults_keepOneLayerAndIdenticalCodestreams() async throws {
        for (syntax, intent) in [(DicomTransferSyntax.jpeg2000Lossless, DicomEncodingIntent.reversible),
                                 (.jpeg2000, .irreversible(quality: 0.9)), (.htj2kLosslessRPCL, .reversible)] {
            let original = try await encode(syntax, intent: intent)
            let explicitDefault = try await encode(syntax, options: .init(), intent: intent)
            XCTAssertEqual(original, explicitDefault, syntax.rawValue)
            XCTAssertEqual(try DicomJ2KCodestreamInspector.inspect(original).layerCount, 1)
        }
    }

    func test_LRCPAndRLCP_writeRealLayersAndIndependentRefinement() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var streams: [Data] = []
        for order in [DicomJPEG2000Progression.lrcp, .rlcp] {
            let stream = try await encode(options: .init(qualityLayers: 3, decompositionLevels: 3, progression: order))
            streams.append(stream)
            let header = try DicomJ2KCodestreamInspector.inspect(stream)
            XCTAssertEqual(header.layerCount, 3); XCTAssertEqual(header.decompositionLevels, 3)
            XCTAssertEqual(header.progressionOrder, order == .lrcp ? 0 : 1)
            var priorError = Double.infinity
            for layer in 0..<3 {
                let reference = try oracle(stream, in: root, layers: layer + 1)
                let own = try await DicomJ2KSwiftBackend().decode(.init(frameData: stream, descriptor: descriptor(), frameIndex: 0,
                    partialRequest: .init(maximumQualityLayer: layer)))
                XCTAssertEqual(own.buffer.data, reference, "\(order) layer \(layer)")
                let error = mse(reference, reference: samples)
                XCTAssertLessThan(error, priorError, "each nonempty layer refines the synthetic image")
                priorError = error
                if layer == 2 { XCTAssertEqual(reference, samples) }
                for reduce in 1...3 {
                    let reducedReference = try oracle(stream, in: root, layers: layer + 1, reduce: reduce)
                    let reduced = try await DicomJ2KSwiftBackend().decode(.init(frameData: stream, descriptor: descriptor(), frameIndex: 0,
                        partialRequest: .init(resolutionLevel: 3 - reduce, maximumQualityLayer: layer)))
                    XCTAssertEqual(reduced.width, width >> reduce); XCTAssertEqual(reduced.height, height >> reduce)
                    XCTAssertEqual(reduced.buffer.data, reducedReference, "\(order), layer \(layer), reduce \(reduce)")
                }
            }
        }
        // COD differs by one byte; the different tile bodies prove the packet order was also changed.
        let bodies = streams.map { stream in Data(stream[stream.range(of: Data([0xFF, 0x93]))!.upperBound...]) }
        XCTAssertNotEqual(bodies[0], bodies[1])
    }

    func test_HTLayers_and202Profile_crossDecodeIndependently() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for syntax in [DicomTransferSyntax.htj2kLossless, .htj2k, .htj2kLosslessRPCL] {
            for order in (syntax == .htj2kLosslessRPCL ? [DicomJPEG2000Progression.rpcl] : [.lrcp, .rlcp]) {
                let options = DicomJPEG2000EncodingOptions(qualityLayers: syntax == .htj2kLosslessRPCL ? 1 : 3,
                                                          decompositionLevels: 3, progression: order)
                let stream = try await encode(syntax, options: options)
                XCTAssertNil(DicomHTJ2KProfile.violation(of: syntax.rawValue, in: stream))
                XCTAssertEqual(try oracle(stream, in: root), samples)
                // OpenJPH 0.31 only reads single-layer streams; OpenJPEG qualifies HT layer refinement.
                for layer in 0..<options.qualityLayers {
                    let reference = try oracle(stream, in: root, layers: layer + 1)
                    let own = try await DicomJ2KSwiftBackend().decode(.init(frameData: stream, descriptor: descriptor(syntax), frameIndex: 0,
                        partialRequest: .init(maximumQualityLayer: layer)))
                    XCTAssertEqual(own.buffer.data, reference)
                }
                let singleLayer = try await encode(syntax, options: .init(decompositionLevels: 3, progression: order))
                XCTAssertEqual(try oracle(singleLayer, in: root, openJPH: true), samples)
                for reduce in 1...3 {
                    XCTAssertEqual(try oracle(stream, in: root, reduce: reduce),
                                   try oracle(singleLayer, in: root, reduce: reduce, openJPH: true))
                }
            }
        }
        for options in [DicomJPEG2000EncodingOptions(qualityLayers: 2), .init(progression: .lrcp), .init(decompositionLevels: 0)] {
            XCTAssertThrowsError(try options.resolved(descriptor: descriptor(.htj2kLosslessRPCL), intent: .reversible))
        }
        // The default's actual DWT count is bounded by the shortest side, even when RPCL's preferred
        // thumbnail count comes from the longest side. PS3.5 permits either thumbnail side <= 64.
        let narrow = DicomCompressedFrameDescriptor(transferSyntaxUID: DicomTransferSyntax.htj2kLosslessRPCL.rawValue,
            rows: 9, columns: 1000, bitsAllocated: 8, bitsStored: 8, highBit: 7, pixelRepresentation: 0,
            samplesPerPixel: 1, photometricInterpretation: "MONOCHROME2", planarConfiguration: nil)
        XCTAssertEqual(try DicomJPEG2000EncodingOptions().resolved(descriptor: narrow, intent: .reversible).decompositionLevels, 2)
        XCTAssertThrowsError(try DicomJPEG2000EncodingOptions(decompositionLevels: 4).resolved(descriptor: narrow, intent: .reversible))
    }

    func test_publicTranscoderAndStreamingPlan_preserveOptionsAndLossHistory() async throws {
        let source = try nativeFile(), root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let options = DicomJPEG2000EncodingOptions(qualityLayers: 3, decompositionLevels: 3, progression: .rlcp)
        let first = try await DicomTranscoder().transcode(source, to: .jpeg2000Lossless, intent: .reversible)
        let plan = try DicomCodecWorkflowEngine().plan(first, to: .jpeg2000Lossless, jpeg2000Options: options)
        XCTAssertEqual(plan.kind, .transcode); XCTAssertEqual(plan.jpeg2000Options, options)
        let workflow = try await DicomCodecWorkflowEngine().transcode(first, to: .jpeg2000Lossless, jpeg2000Options: options)
        XCTAssertEqual(workflow.report.transcodeRoute, "recompress")
        let streamed = try await DicomTranscoder().execute(plan, source: first, destinationURL: root.appendingPathComponent("streamed.dcm"), retainEncodedFrames: true)
        let stream = try XCTUnwrap(streamed.encodedFrames?.codestreams.first)
        XCTAssertEqual(try DicomJ2KCodestreamInspector.inspect(stream).layerCount, 3)
        XCTAssertEqual(try oracle(stream, in: root), samples)
        for syntax in [DicomTransferSyntax.jpeg2000, .htj2k] {
            let output = try await DicomTranscoder().transcode(source, to: syntax, intent: .irreversible(quality: 0.9), jpeg2000Options: options)
            let decoder = try DCMDecoder(data: output)
            XCTAssertEqual(decoder.info(for: .lossyImageCompression), "01")
            XCTAssertNotEqual(decoder.info(for: .sopInstanceUID), try DCMDecoder(data: source).info(for: .sopInstanceUID))
            let reader = try XCTUnwrap(decoder.makeEncapsulatedPixelFrameReader())
            let codestream = try reader.frameData(at: 0)
            let decoded = try oracle(codestream, in: root)
            XCTAssertLessThan(mse(decoded, reference: samples), 205, "PSNR > 25 dB")
            var priorError = Double.infinity
            for layer in 1...3 {
                let error = mse(try oracle(codestream, in: root, layers: layer), reference: samples)
                XCTAssertLessThan(error, priorError)
                priorError = error
            }
            if syntax == .htj2k {
                let singleLayer = try await encode(syntax, options: .init(decompositionLevels: 3, progression: .rlcp), intent: .irreversible(quality: 0.9))
                XCTAssertEqual(try oracle(singleLayer, in: root, openJPH: true), decoded)
            }
        }
    }

    func test_cancelledExplicitEncode_doesNotPublish() async throws {
        let root = try directory(), source = try nativeFile()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("cancelled.dcm")
        let task = Task {
            try await DicomCodecWorkflowEngine().transcode(source, to: .jpeg2000Lossless,
                jpeg2000Options: .init(qualityLayers: 3, decompositionLevels: 3), destinationURL: output, progress: nil)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled encode completed") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func test_precisionColourAndLayerBounds_preserveFinalSamples() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (precision, signed, components) in [(12, true, 1), (16, false, 1), (8, false, 3)] {
            let bytesPerSample = precision > 8 ? 2 : 1
            var planes = [Data](repeating: Data(), count: components)
            var interleaved = Data()
            for pixel in 0..<(width * height) {
                for component in 0..<components {
                    let value = ((pixel * 17 + component * 43) % (1 << precision)) - (signed ? 1 << (precision - 1) : 0)
                    let word = UInt16(truncatingIfNeeded: value)
                    var sample = Data([UInt8(truncatingIfNeeded: word)])
                    if bytesPerSample == 2 { sample.append(UInt8(word >> 8)) }
                    planes[component].append(sample); interleaved.append(sample)
                }
            }
            let expected = planes.reduce(into: Data()) { $0.append($1) }
            for syntax in [DicomTransferSyntax.jpeg2000Lossless, .htj2kLossless] {
                let descriptor = DicomCompressedFrameDescriptor(transferSyntaxUID: syntax.rawValue, rows: height, columns: width,
                    bitsAllocated: bytesPerSample * 8, bitsStored: precision, highBit: precision - 1,
                    pixelRepresentation: signed ? 1 : 0, samplesPerPixel: components,
                    photometricInterpretation: components == 3 ? "RGB" : "MONOCHROME2", planarConfiguration: components == 3 ? 0 : nil)
                for levels in [0, 1, 3, 5] {
                    for order in [DicomJPEG2000Progression.lrcp, .rlcp] {
                        let stream = try await DicomJ2KSwiftBackend().encode(.init(
                            frame: .init(buffer: .owned(interleaved), width: width, height: height, bitsPerSample: precision, componentCount: components),
                            descriptor: descriptor, targetTransferSyntaxUID: syntax.rawValue,
                            jpeg2000Options: .init(qualityLayers: levels + 1, decompositionLevels: levels, progression: order)))
                        let header = try DicomJ2KCodestreamInspector.inspect(stream)
                        XCTAssertEqual(header.layerCount, levels + 1); XCTAssertEqual(header.decompositionLevels, levels)
                        XCTAssertEqual(try oracle(stream, in: root, precision: precision, signed: signed), expected, "\(syntax), \(precision)-bit, \(components) components, \(order), D=\(levels)")
                    }
                }
            }
        }
    }

    func test_regionResolutionAndLayer_matchIndependentCrop() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for syntax in [DicomTransferSyntax.jpeg2000Lossless, .htj2kLossless] {
            let stream = try await encode(syntax, options: .init(qualityLayers: 3, decompositionLevels: 3, progression: .rlcp))
            for layer in 0..<3 {
                let reference = try oracle(stream, in: root, layers: layer + 1, reduce: 1)
                let region = try await DicomJ2KSwiftBackend().decode(.init(frameData: stream, descriptor: descriptor(syntax), frameIndex: 0,
                    partialRequest: .init(region: .init(x: 16, y: 16, width: 32, height: 16), resolutionLevel: 2, maximumQualityLayer: layer)))
                var crop = Data()
                for y in 8..<16 { crop.append(reference[(y * 64 + 8)..<(y * 64 + 24)]) }
                XCTAssertEqual(region.width, 16); XCTAssertEqual(region.height, 8)
                XCTAssertEqual(region.buffer.data, crop)
            }
        }
    }
}
