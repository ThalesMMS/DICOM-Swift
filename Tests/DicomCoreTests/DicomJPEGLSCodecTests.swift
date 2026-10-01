import DicomJPEGLS
import Foundation
import XCTest
@testable import DicomCore

/// Own JPEG-LS codec on the vendored DicomJPEGLS core (#2328): interleave none/line/sample cross-checked with CharLS in
/// both directions, restart intervals, NEAR bounds verified after signed normalisation, DICOM-forbidden features
/// (colour transformation, mapping tables) refused, truncated input, invalid configurations, transcoder options,
/// the synchronous pixel-reader path and a release timing comparison.
final class DicomJPEGLSCodecTests: XCTestCase {
    // MARK: - Fixtures

    private static func samples(width: Int, height: Int, precision: Int, components: Int, seed: UInt32 = 5) -> [UInt16] {
        var state = seed
        let limit = 1 << precision
        return (0..<(width * height * components)).map { index in
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = Int(state >> 8) % max(1, limit / 8)
            let x = (index / components) % width, y = (index / components) / width
            return UInt16((x * limit / max(1, width) / 2 + y * limit / max(1, height) / 4 + noise + (index % components) * (limit / 16)) % limit)
        }
    }

    private static func littleEndian(_ samples: [UInt16], bitsAllocated: Int) -> Data {
        var data = Data(capacity: samples.count * (bitsAllocated > 8 ? 2 : 1))
        for value in samples {
            data.append(UInt8(value & 0xFF))
            if bitsAllocated > 8 { data.append(UInt8(value >> 8)) }
        }
        return data
    }

    private static func descriptor(_ syntax: DicomTransferSyntax = .jpegLSLossless, width: Int, height: Int, bitsStored: Int, samples: Int = 1,
                                   signed: Bool = false) -> DicomCompressedFrameDescriptor {
        DicomCompressedFrameDescriptor(transferSyntaxUID: syntax.rawValue, rows: height, columns: width, bitsAllocated: bitsStored > 8 ? 16 : 8,
                                       bitsStored: bitsStored, highBit: bitsStored - 1, pixelRepresentation: signed ? 1 : 0, samplesPerPixel: samples,
                                       photometricInterpretation: samples == 3 ? "RGB" : "MONOCHROME2", planarConfiguration: samples == 3 ? 0 : nil)
    }

    private static func frame(_ bytes: Data, descriptor: DicomCompressedFrameDescriptor) -> DicomCodecDecodedFrame {
        DicomCodecDecodedFrame(buffer: .owned(bytes), width: descriptor.columns, height: descriptor.rows,
                               bitsPerSample: descriptor.bitsStored, componentCount: descriptor.samplesPerPixel)
    }

    private static func nativeFile(samples: [UInt16], width: Int, height: Int, bitsStored: Int, frames: Int = 1, samplesPerPixel: Int = 1,
                                   signed: Bool = false) throws -> Data {
        let bitsAllocated: UInt = bitsStored > 8 ? 16 : 8
        var elements: [DicomDataElement] = [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23280001"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23280002"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23280003"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([UInt(height)])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([UInt(width)])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([UInt(samplesPerPixel)])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings([samplesPerPixel == 3 ? "RGB" : "MONOCHROME2"])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([bitsAllocated])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([UInt(bitsStored)])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([UInt(bitsStored - 1)])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([signed ? 1 : 0])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: bitsAllocated > 8 ? .OW : .OB,
                             value: .bytes(littleEndian(samples, bitsAllocated: Int(bitsAllocated))))
        ]
        if frames > 1 { elements.append(DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["\(frames)"]))) }
        if samplesPerPixel == 3 { elements.append(DicomDataElement(tag: DicomTag.planarConfiguration.rawValue, vr: .US, value: .unsignedIntegers([0]))) }
        return try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: elements))
    }

    private func requireCharLS() throws {
        guard DicomJPEGLSCodec.isAvailable else { throw XCTSkip("CharLS runtime is not available on this host") }
    }

    /// RGBRGB samples reordered for CharLS's input expectations: planes for ILV none, pixel-interleaved otherwise
    /// (CharLS takes and returns RGBRGB for line and sample interleave; only the codestream layout differs).
    private static func reorder(_ rgb: [UInt16], width: Int, height: Int, interleave: Int) -> [UInt16] {
        guard interleave == 0 else { return rgb }
        return (0..<3).flatMap { component in (0..<(width * height)).map { rgb[$0 * 3 + component] } }
    }

    private static func interleaveScanMode(_ codestream: Data) throws -> JPEGLSInterleaveMode {
        try XCTUnwrap(JPEGLSParser(data: codestream).parse().scanHeaders.first?.interleaveMode)
    }

    // MARK: - Interleave modes across CharLS and the own codec

    func test_colourInterleaveModesCrossEncodeAndDecodeWithCharLS() async throws {
        try requireCharLS()
        let width = 11, height = 7
        let rgb = Self.samples(width: width, height: height, precision: 8, components: 3)
        let descriptor = Self.descriptor(width: width, height: height, bitsStored: 8, samples: 3)
        let expected = Self.littleEndian(rgb, bitsAllocated: 8)
        let backend = DicomJLSwiftBackend()
        for (interleave, charlsMode) in [(DicomJPEGLSInterleave.perComponent, 0), (.line, 1), (.sample, 2)] {
            // Own encoder → CharLS decoder (normalised to RGBRGB) and back through the own decoder.
            let own = try await backend.encode(DicomFrameEncodeRequest(frame: Self.frame(expected, descriptor: descriptor), descriptor: descriptor,
                                                                        targetTransferSyntaxUID: descriptor.transferSyntaxUID,
                                                                        intent: .jpegLS(options: DicomJPEGLSEncodingOptions(interleave: interleave))))
            XCTAssertEqual(try Self.interleaveScanMode(own).rawValue, UInt8(charlsMode), "scan header carries \(interleave)")
            XCTAssertEqual(try DicomJPEGLSCodec.decode(own).bytes, expected, "CharLS decodes own \(interleave)")
            XCTAssertEqual(try DicomJLSwiftBackend.decodeSynchronously(own, descriptor: descriptor).buffer.data, expected, "own decodes own \(interleave)")
            // CharLS encoder in the same interleave → own decoder.
            let charls = try DicomJPEGLSCodec.encodeForTesting(bytes: Self.littleEndian(Self.reorder(rgb, width: width, height: height, interleave: charlsMode), bitsAllocated: 8),
                                                              width: width, height: height, bitsPerSample: 8, componentCount: 3, interleaveMode: charlsMode)
            XCTAssertEqual(try Self.interleaveScanMode(charls).rawValue, UInt8(charlsMode))
            XCTAssertEqual(try DicomJLSwiftBackend.decodeSynchronously(charls, descriptor: descriptor).buffer.data, expected, "own decodes CharLS \(interleave)")
        }
        // Grayscale never interleaves; asking for it is a typed refusal.
        let gray = Self.descriptor(width: width, height: height, bitsStored: 12)
        XCTAssertThrowsError(try DicomJLSwiftBackend.validateEncoding(descriptor: gray, targetTransferSyntaxUID: gray.transferSyntaxUID,
                                                                       intent: .jpegLS(options: DicomJPEGLSEncodingOptions(interleave: .line)))) { error in
            XCTAssertTrue("\(error)".contains("never interleaved"), "\(error)")
        }
        XCTAssertEqual(try DicomJLSwiftBackend.validateEncoding(descriptor: gray, targetTransferSyntaxUID: gray.transferSyntaxUID, intent: .reversible),
                       DicomJLSwiftBackend.EncodingParameters(near: 0, interleave: .none, restartIntervalLines: 0))
        XCTAssertEqual(try DicomJLSwiftBackend.validateEncoding(descriptor: descriptor, targetTransferSyntaxUID: descriptor.transferSyntaxUID, intent: .reversible).interleave, .sample)
    }

    func test_restartIntervalsAreQualifiedForLosslessNonInterleavedScansOnly() async throws {
        try requireCharLS()
        let width = 9, height = 12
        let gray = Self.samples(width: width, height: height, precision: 12, components: 1)
        let descriptor = Self.descriptor(width: width, height: height, bitsStored: 12)
        let source = Self.littleEndian(gray, bitsAllocated: 16)
        let backend = DicomJLSwiftBackend()
        let restarted = try await backend.encode(DicomFrameEncodeRequest(frame: Self.frame(source, descriptor: descriptor), descriptor: descriptor,
                                                                          targetTransferSyntaxUID: descriptor.transferSyntaxUID,
                                                                          intent: .jpegLS(options: DicomJPEGLSEncodingOptions(restartIntervalLines: 3))))
        XCTAssertEqual(try JPEGLSParser(data: restarted).parse().restartInterval, 3)
        XCTAssertEqual(try DicomJLSwiftBackend.decodeSynchronously(restarted, descriptor: descriptor).buffer.data, source)
        XCTAssertEqual(try DicomJPEGLSCodec.decode(restarted).bytes, source, "CharLS decodes the restart-interval stream")
        // Colour planes (interleave none) with restarts also work; other combinations are refused, not generalised.
        let colour = Self.descriptor(width: width, height: height, bitsStored: 8, samples: 3)
        XCTAssertNoThrow(try DicomJLSwiftBackend.validateEncoding(descriptor: colour, targetTransferSyntaxUID: colour.transferSyntaxUID,
                                                                   intent: .jpegLS(options: DicomJPEGLSEncodingOptions(interleave: .perComponent, restartIntervalLines: 2))))
        for options in [DicomJPEGLSEncodingOptions(interleave: .sample, restartIntervalLines: 2), DicomJPEGLSEncodingOptions(interleave: .line, restartIntervalLines: 2)] {
            XCTAssertThrowsError(try DicomJLSwiftBackend.validateEncoding(descriptor: colour, targetTransferSyntaxUID: colour.transferSyntaxUID, intent: .jpegLS(options: options))) { error in
                XCTAssertTrue("\(error)".contains("non-interleaved"), "\(error)")
            }
        }
        let near = Self.descriptor(.jpegLSNearLossless, width: width, height: height, bitsStored: 12)
        XCTAssertThrowsError(try DicomJLSwiftBackend.validateEncoding(descriptor: near, targetTransferSyntaxUID: near.transferSyntaxUID,
                                                                       intent: .jpegLS(options: DicomJPEGLSEncodingOptions(near: 2, restartIntervalLines: 2)))) { error in
            XCTAssertTrue("\(error)".contains("NEAR=0"), "\(error)")
        }
        XCTAssertThrowsError(try DicomJLSwiftBackend.validateEncoding(descriptor: descriptor, targetTransferSyntaxUID: descriptor.transferSyntaxUID,
                                                                       intent: .jpegLS(options: DicomJPEGLSEncodingOptions(restartIntervalLines: 70000))))
        // NEAR must match the syntax.
        XCTAssertThrowsError(try DicomJLSwiftBackend.validateEncoding(descriptor: descriptor, targetTransferSyntaxUID: descriptor.transferSyntaxUID,
                                                                       intent: .jpegLS(options: DicomJPEGLSEncodingOptions(near: 1))))
        XCTAssertThrowsError(try DicomJLSwiftBackend.validateEncoding(descriptor: near, targetTransferSyntaxUID: near.transferSyntaxUID,
                                                                       intent: .jpegLS(options: DicomJPEGLSEncodingOptions(near: 0))))
        XCTAssertEqual(try DicomJLSwiftBackend.validateEncoding(descriptor: near, targetTransferSyntaxUID: near.transferSyntaxUID,
                                                                 intent: .jpegLS(options: DicomJPEGLSEncodingOptions(near: 4))).near, 4)
    }

    // MARK: - NEAR after signed normalisation

    func test_nearLosslessBoundHoldsForUnsignedAndIsVerifiedAtSignedExtremes() async throws {
        try requireCharLS()
        let width = 16, height = 10
        let backend = DicomJLSwiftBackend()
        // Unsigned 12-bit: CharLS and the own decoder both land within NEAR of the source.
        let unsigned = Self.samples(width: width, height: height, precision: 12, components: 1, seed: 8)
        let unsignedDescriptor = Self.descriptor(.jpegLSNearLossless, width: width, height: height, bitsStored: 12)
        let unsignedSource = Self.littleEndian(unsigned, bitsAllocated: 16)
        let near = 3
        let encoded = try await backend.encode(DicomFrameEncodeRequest(frame: Self.frame(unsignedSource, descriptor: unsignedDescriptor), descriptor: unsignedDescriptor,
                                                                        targetTransferSyntaxUID: unsignedDescriptor.transferSyntaxUID,
                                                                        intent: .jpegLS(options: DicomJPEGLSEncodingOptions(near: near))))
        for decoded in [try DicomJLSwiftBackend.decodeSynchronously(encoded, descriptor: unsignedDescriptor).buffer.data, try DicomJPEGLSCodec.decode(encoded).bytes] {
            let values: [Int] = decoded.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)).map { Int(UInt16(littleEndian: $0)) } }
            let errors: [Int] = zip(values, unsigned).map { abs($0 - Int($1)) }
            XCTAssertLessThanOrEqual(errors.max() ?? Int.max, near)
            XCTAssertGreaterThan(errors.max() ?? 0, 0, "NEAR quantisation is applied")
        }
        // Signed 12-bit away from the sign boundary: accepted, error bound holds on the signed values.
        let signedDescriptor = Self.descriptor(.jpegLSNearLossless, width: width, height: height, bitsStored: 12, signed: true)
        let mild: [Int16] = (0..<(width * height)).map { Int16(($0 * 29) % 1500 - 750) }
        let mildSource = Self.littleEndian(mild.map { UInt16(bitPattern: $0) & 0x0FFF }, bitsAllocated: 16)
        let mildEncoded = try await backend.encode(DicomFrameEncodeRequest(frame: Self.frame(mildSource, descriptor: signedDescriptor), descriptor: signedDescriptor,
                                                                            targetTransferSyntaxUID: signedDescriptor.transferSyntaxUID,
                                                                            intent: .jpegLS(options: DicomJPEGLSEncodingOptions(near: near))))
        let mildDecoded = try DicomJLSwiftBackend.decodeSynchronously(mildEncoded, descriptor: signedDescriptor).buffer.data
            .withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)).map { Int(Int16(bitPattern: UInt16(littleEndian: $0))) } }
        XCTAssertLessThanOrEqual(zip(mildDecoded, mild).map { abs($0 - Int($1)) }.max() ?? Int.max, near)
        // Signed extremes: codes 2047 and −2048 are adjacent in the stored-code space, so NEAR quantisation can wrap.
        // The backend verifies the bound after signed normalisation and refuses instead of returning a wrong frame.
        let extreme: [Int16] = (0..<(width * height)).map { $0 % 2 == 0 ? 2047 : -2048 }
        let extremeSource = Self.littleEndian(extreme.map { UInt16(bitPattern: $0) & 0x0FFF }, bitsAllocated: 16)
        do {
            _ = try await backend.encode(DicomFrameEncodeRequest(frame: Self.frame(extremeSource, descriptor: signedDescriptor), descriptor: signedDescriptor,
                                                                  targetTransferSyntaxUID: signedDescriptor.transferSyntaxUID,
                                                                  intent: .jpegLS(options: DicomJPEGLSEncodingOptions(near: near))))
            // If the quantiser happened not to cross the boundary the encode is legitimately accepted; verify the bound then.
            let decoded = try await backend.decode(DicomFrameDecodeRequest(frameData: try await backend.encode(DicomFrameEncodeRequest(
                frame: Self.frame(extremeSource, descriptor: signedDescriptor), descriptor: signedDescriptor,
                targetTransferSyntaxUID: signedDescriptor.transferSyntaxUID, intent: .jpegLS(options: DicomJPEGLSEncodingOptions(near: near)))),
                descriptor: signedDescriptor, frameIndex: 0)).buffer.data
                .withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)).map { Int(Int16(bitPattern: UInt16(littleEndian: $0))) } }
            XCTAssertLessThanOrEqual(zip(decoded, extreme).map { abs($0 - Int($1)) }.max() ?? Int.max, near)
        } catch let error as DicomJLSwiftBackendError {
            guard case .nearLosslessBoundExceeded(_, let boundNear, let observed) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(boundNear, near)
            XCTAssertGreaterThan(observed, near)
        }
        // A direct check of the verifier with a codestream whose signed error is known to wrap.
        let wrapped = try DicomJPEGLSCodec.encodeForTesting(bytes: extremeSource, width: width, height: height, bitsPerSample: 12, nearLossless: near)
        let wrappedDecoded = try DicomJLSwiftBackend.decodeSynchronously(wrapped, descriptor: signedDescriptor).buffer.data
            .withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)).map { Int(Int16(bitPattern: UInt16(littleEndian: $0))) } }
        let worst = zip(wrappedDecoded, extreme).map { abs($0 - Int($1)) }.max() ?? 0
        if worst > near {
            XCTAssertThrowsError(try DicomJLSwiftBackend.verifySignedNearBound(wrapped, source: extremeSource, descriptor: signedDescriptor, near: near))
        } else {
            XCTAssertNoThrow(try DicomJLSwiftBackend.verifySignedNearBound(wrapped, source: extremeSource, descriptor: signedDescriptor, near: near))
        }
    }

    /// Issue #2868 (`MEDILABValidCP246_EVRLESQasOB`): the encoder writes a 0xFF fill byte between the scan and EOI
    /// (T.81 B.1.1.2); the stream decodes as CharLS reads it.
    func test_fillBytesBeforeEOI_decodeAsTheUnpaddedStream() async throws {
        let width = 23, height = 9
        let source = Self.samples(width: width, height: height, precision: 12, components: 1, seed: 11)
        let descriptor = Self.descriptor(width: width, height: height, bitsStored: 12)
        let bytes = Self.littleEndian(source, bitsAllocated: 16)
        let encoded = try await DicomJLSwiftBackend().encode(DicomFrameEncodeRequest(
            frame: Self.frame(bytes, descriptor: descriptor), descriptor: descriptor,
            targetTransferSyntaxUID: descriptor.transferSyntaxUID, intent: .jpegLS(options: DicomJPEGLSEncodingOptions(near: 0))))
        XCTAssertEqual([UInt8](encoded.suffix(2)), [0xFF, 0xD9])
        for fill in 1...3 {
            let padded = encoded.dropLast(2) + Data(repeating: 0xFF, count: fill) + Data([0xFF, 0xD9])
            XCTAssertEqual(try DicomJLSwiftBackend.decodeSynchronously(Data(padded), descriptor: descriptor).buffer.data, bytes, "\(fill)")
        }
        // Its codestream declares P = 16 under Bits Stored 12: the samples keep the codestream precision, as GDCM reads
        // them; a precision beyond Bits Allocated is still refused.
        let sixteen = Self.descriptor(width: width, height: height, bitsStored: 16)
        let wide = try await DicomJLSwiftBackend().encode(DicomFrameEncodeRequest(
            frame: Self.frame(bytes, descriptor: sixteen), descriptor: sixteen,
            targetTransferSyntaxUID: sixteen.transferSyntaxUID, intent: .jpegLS(options: DicomJPEGLSEncodingOptions(near: 0))))
        let decoded = try DicomJLSwiftBackend.decodeSynchronously(wide, descriptor: descriptor)
        XCTAssertEqual(decoded.bitsPerSample, 16)
        XCTAssertEqual(decoded.buffer.data, bytes)
        let eightBit = Self.descriptor(width: width, height: height, bitsStored: 8)
        XCTAssertThrowsError(try DicomJLSwiftBackend.decodeSynchronously(wide, descriptor: eightBit))
    }

    /// Issue #2903: the direct plane decode equals the general decoder sample for sample — 8, 12 and 16 bits, signed,
    /// NEAR > 0 and restart intervals — and the backend's row-by-row sign extension equals `normalizedSignedData`.
    func test_directPlaneDecode_matchesTheGeneralDecoder() async throws {
        let width = 37, height = 29
        for (precision, signed, near, restart) in [(8, false, 0, 0), (12, false, 0, 0), (12, true, 0, 5), (16, false, 0, 7),
                                                  (12, false, 2, 0), (8, false, 3, 0), (16, true, 0, 0), (8, true, 0, 3)] {
            let name = "P\(precision) signed \(signed) NEAR \(near) restart \(restart)"
            let descriptor = Self.descriptor(near > 0 ? .jpegLSNearLossless : .jpegLSLossless, width: width, height: height,
                                             bitsStored: precision, signed: signed)
            let bytes = Self.littleEndian(Self.samples(width: width, height: height, precision: precision, components: 1),
                                          bitsAllocated: descriptor.bitsAllocated)
            let encoded = try await DicomJLSwiftBackend().encode(DicomFrameEncodeRequest(
                frame: Self.frame(bytes, descriptor: descriptor), descriptor: descriptor,
                targetTransferSyntaxUID: descriptor.transferSyntaxUID,
                intent: .jpegLS(options: DicomJPEGLSEncodingOptions(near: near, restartIntervalLines: restart))))
            let general = try JPEGLSDecoder().decode(encoded).components[0].pixels.flatMap { $0 }
            let plane: [Int]
            if precision > 8 {
                let samples = try JPEGLSDecoder().decodeSingleComponent(encoded, as: UInt16.self).samples
                plane = samples.withUnsafeBytes { $0.bindMemory(to: UInt16.self).map(Int.init) }
            } else {
                plane = try JPEGLSDecoder().decodeSingleComponent(encoded, as: UInt8.self).samples.map(Int.init)
            }
            XCTAssertEqual(plane, general, name)
            let unextended = Self.littleEndian(general.map { UInt16($0) }, bitsAllocated: descriptor.bitsAllocated)
            let frame = try DicomJLSwiftBackend.decodeSynchronously(encoded, descriptor: descriptor)
            XCTAssertEqual(frame.buffer.data, DicomJLSwiftBackend.normalizedSignedData(unextended, descriptor: descriptor), name)
        }
        // More than one component is refused rather than flattened.
        let rgb = Self.descriptor(width: 8, height: 4, bitsStored: 8, samples: 3)
        let rgbEncoded = try await DicomJLSwiftBackend().encode(DicomFrameEncodeRequest(
            frame: Self.frame(Self.littleEndian(Self.samples(width: 8, height: 4, precision: 8, components: 3), bitsAllocated: 8),
                              descriptor: rgb),
            descriptor: rgb, targetTransferSyntaxUID: rgb.transferSyntaxUID, intent: .jpegLS(options: .init())))
        XCTAssertThrowsError(try JPEGLSDecoder().decodeSingleComponent(rgbEncoded, as: UInt8.self))
    }

    /// Issue #2904: real CharLS streams (DCMTK 3.7.0 `dcmcjpls`, 1×3 8-bit lossless) that end their entropy data in
    /// 0xFF and write a fill byte before EOI, plus a stream whose last entropy byte is ≥ 0x80. The byte arrays come
    /// from JLSwift `Tests/JPEGLSTests/JPEGLSFillByteTests.swift` (commit 803b279, Apache-2.0).
    func test_charLSStreamsWithFillBytes_decodeToTheEncodedSamples() throws {
        let head: [UInt8] = [0xFF, 0xD8, 0xFF, 0xF7, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x03, 0x01, 0x01, 0x11, 0x00,
                             0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00]
        let oneRow = head + [0xAA, 0x00, 0xFF, 0xFF, 0xD9]
        let alternate = head + [0x54, 0xA0, 0xFF, 0xFF, 0xD9]
        XCTAssertEqual(try JPEGLSDecoder().decode(Data(oneRow)).components[0].pixels, [[0, 1, 255]])
        XCTAssertEqual(try JPEGLSDecoder().decode(Data(alternate)).components[0].pixels, [[1, 255, 0]])
        // More fill bytes, or none, leave the scan body at `AA 00`.
        var padded = oneRow
        padded.insert(contentsOf: [0xFF, 0xFF, 0xFF], at: padded.count - 2)
        var unpadded = oneRow
        unpadded.remove(at: unpadded.count - 3)
        for stream in [padded, unpadded] {
            XCTAssertEqual(try JPEGLSParser(data: Data(stream)).parse().scanDataRanges, [25..<27])
            XCTAssertEqual(try JPEGLSDecoder().decode(Data(stream)).components[0].pixels, [[0, 1, 255]])
        }
        // 2×3: entropy data `AA 6F 80` ends in a byte ≥ 0x80 that is still data, not a marker.
        var twoRows = head + [0xAA, 0x6F, 0x80, 0xFF, 0xD9]
        twoRows[8] = 0x02
        XCTAssertEqual(try JPEGLSDecoder().decode(Data(twoRows)).components[0].pixels, [[0, 1, 255], [1, 255, 0]])
        // The byte-level marker reader skips fill bytes too.
        let reader = JPEGLSBitstreamReader(data: Data([0xFF, 0xFF, 0xFF, 0xD9]))
        XCTAssertEqual(try reader.readMarker(), .endOfImage)
        XCTAssertTrue(reader.isAtEnd)
    }

    func test_encoder_rejectsSubsampledPlanesBeforeColorTransformation() throws {
        let frame = try JPEGLSFrameHeader(bitsPerSample: 8, height: 4, width: 4, componentCount: 3, components: [
            .init(id: 1, horizontalSamplingFactor: 2, verticalSamplingFactor: 2), .init(id: 2), .init(id: 3)
        ])
        let image = try MultiComponentImageData(components: [
            .init(id: 1, pixels: Array(repeating: Array(repeating: 10, count: 4), count: 4)),
            .init(id: 2, pixels: Array(repeating: Array(repeating: 20, count: 2), count: 2)),
            .init(id: 3, pixels: Array(repeating: Array(repeating: 30, count: 2), count: 2))
        ], frameHeader: frame)
        for transform: JPEGLSColorTransformation in [.hp1, .hp2, .hp3] {
            let configuration = try JPEGLSEncoder.Configuration(interleaveMode: .line, colorTransformation: transform)
            XCTAssertThrowsError(try JPEGLSEncoder().encode(image, configuration: configuration)) { error in
                guard let error = error as? JPEGLSError, case .encodingFailed(let reason) = error else {
                    return XCTFail("Expected typed geometry rejection, got \(error)")
                }
                XCTAssertTrue(reason.contains("Sub-sampled component planes"))
            }
        }
    }

    func test_decoder_rejectsTransformedSubsampledHeaderBeforeDecoding() throws {
        let pixels = Array(repeating: Array(repeating: 20, count: 4), count: 4)
        let image = try MultiComponentImageData.rgb(redPixels: pixels, greenPixels: pixels, bluePixels: pixels, bitsPerSample: 8)
        for transform: JPEGLSColorTransformation in [.hp1, .hp2, .hp3] {
            for mode: JPEGLSInterleaveMode in [.line, .sample] {
                let encoded = try JPEGLSEncoder().encode(image, configuration: .init(interleaveMode: mode, colorTransformation: transform))
                let sof = try XCTUnwrap(encoded.range(of: Data([0xFF, 0xF7]))).lowerBound
                for sampling: UInt8 in [0x22, 0] {
                    var stream = encoded
                    stream[sof + 11] = sampling // First component's packed horizontal/vertical sampling factors.
                    if sampling == 0 { stream[sof + 14] = 0; stream[sof + 17] = 0 }
                    let parsed = try JPEGLSParser(data: stream).parse()
                    XCTAssertEqual(parsed.frameHeader.components[0].horizontalSamplingFactor, sampling >> 4)
                    XCTAssertEqual(parsed.colorTransformation, transform)
                    XCTAssertThrowsError(try JPEGLSDecoder().decode(stream)) { error in
                        guard let error = error as? JPEGLSError, case .invalidBitstreamStructure(let reason) = error else {
                            return XCTFail("Expected typed transformed-geometry rejection, got \(error)")
                        }
                        XCTAssertTrue(reason.contains("full-resolution component planes"))
                    }
                }
            }
        }
    }

    func test_decoder_rejectsColorTransformsWithIncompatibleComponentCounts() throws {
        let pixels = Array(repeating: [3, 17, 55, 120], count: 4)
        for count in [1, 2, 4] {
            let frame = try JPEGLSFrameHeader(bitsPerSample: 8, height: 4, width: 4, componentCount: count,
                                             components: (1...count).map { .init(id: UInt8($0)) })
            let image = try MultiComponentImageData(components: frame.components.map {
                .init(id: $0.id, pixels: pixels)
            }, frameHeader: frame)
            let plain = try JPEGLSEncoder().encode(image, configuration: .init(interleaveMode: .none))
            XCTAssertEqual(try JPEGLSDecoder().decode(plain).components.count, count)
            for transform: JPEGLSColorTransformation in [.hp1, .hp2, .hp3] {
                // APP8: length 7, "mrfx", transformation selector.
                var stream = plain
                stream.insert(contentsOf: [0xFF, 0xE8, 0, 7, 0x6D, 0x72, 0x66, 0x78, transform.rawValue], at: 2)
                XCTAssertEqual(try JPEGLSParser(data: stream).parse().colorTransformation, transform)
                XCTAssertThrowsError(try JPEGLSDecoder().decode(stream)) { error in
                    guard let error = error as? JPEGLSError, case .invalidBitstreamStructure(let reason) = error else {
                        return XCTFail("Expected typed component-count rejection, got \(error)")
                    }
                    XCTAssertTrue(reason.contains("component count"))
                }
            }
        }
    }

    func test_decoder_rejectsUndefinedMappingSelectorsAcrossAllInterleaveModes() throws {
        let pixels = Array(repeating: [3, 17, 55, 120], count: 4)
        let image = try MultiComponentImageData.rgb(redPixels: pixels, greenPixels: pixels, bluePixels: pixels, bitsPerSample: 8)
        let table = try JPEGLSMappingTable(id: 7, entryWidth: 1, entries: (0..<256).map { 255 - $0 })
        for mode: JPEGLSInterleaveMode in [.none, .line, .sample] {
            for mapping: JPEGLSMappingTable? in [nil, table] {
                let encoded = try JPEGLSEncoder().encode(image, configuration: .init(interleaveMode: mode, mappingTable: mapping))
                let expected = mapping == nil ? pixels : pixels.map { $0.map { 255 - $0 } }
                for component in try JPEGLSDecoder().decode(encoded).components {
                    XCTAssertEqual(component.pixels, expected)
                }
                let parsed = try JPEGLSParser(data: encoded).parse()
                let scanIndex = parsed.scanHeaders.count - 1
                let componentCount = parsed.scanHeaders[scanIndex].components.count
                let sos = parsed.scanDataRanges[scanIndex].lowerBound - (8 + 2 * componentCount)
                var undefined = encoded
                undefined[sos + 6 + 2 * (componentCount - 1)] = 9
                XCTAssertEqual(try JPEGLSParser(data: undefined).parse().scanHeaders[scanIndex].components.last?.mappingTableID, 9)
                XCTAssertThrowsError(try JPEGLSDecoder().decode(undefined)) { error in
                    guard let error = error as? JPEGLSError, case .invalidBitstreamStructure(let reason) = error else {
                        return XCTFail("Expected typed mapping-selector rejection, got \(error)")
                    }
                    XCTAssertTrue(reason.contains("undefined mapping table 9"))
                }
            }
        }
    }

    // MARK: - DICOM-forbidden features, truncation and malformed input

    func test_colourTransformationMappingTablesTruncationAndGarbageAreRefusedTyped() throws {
        let width = 8, height = 6
        let rgb = Self.samples(width: width, height: height, precision: 8, components: 3)
        let descriptor = Self.descriptor(width: width, height: height, bitsStored: 8, samples: 3)
        var planes = [[Int]](repeating: [], count: 3)
        for index in 0..<(width * height) { for component in 0..<3 { planes[component].append(Int(rgb[index * 3 + component])) } }
        func rows(_ plane: [Int]) -> [[Int]] { stride(from: 0, to: plane.count, by: width).map { Array(plane[$0..<($0 + width)]) } }
        let image = try MultiComponentImageData.rgb(redPixels: rows(planes[0]), greenPixels: rows(planes[1]), bluePixels: rows(planes[2]), bitsPerSample: 8)
        // ISO/IEC 14495-2 colour transformation: not defined for DICOM (PS3.5 8.2.3).
        let transformed = try JPEGLSEncoder().encode(image, configuration: JPEGLSEncoder.Configuration(interleaveMode: .sample, colorTransformation: .hp1))
        XCTAssertThrowsError(try DicomJLSwiftBackend.decodeSynchronously(transformed, descriptor: descriptor)) { error in
            XCTAssertTrue("\(error)".contains("colour transformation"), "\(error)")
        }
        // The same image without the transformation decodes exactly.
        let plain = try JPEGLSEncoder().encode(image, configuration: JPEGLSEncoder.Configuration(interleaveMode: .sample))
        XCTAssertEqual(try DicomJLSwiftBackend.decodeSynchronously(plain, descriptor: descriptor).buffer.data, Self.littleEndian(rgb, bitsAllocated: 8))
        // Mapping tables (palettes) have no DICOM counterpart.
        let gray = Self.samples(width: width, height: height, precision: 8, components: 1)
        let grayImage = try MultiComponentImageData.grayscale(pixels: rows(gray.map(Int.init)), bitsPerSample: 8)
        let table = try JPEGLSMappingTable(id: 1, entryWidth: 1, entries: (0..<256).map { 255 - $0 })
        let mapped = try JPEGLSEncoder().encode(grayImage, configuration: JPEGLSEncoder.Configuration(mappingTable: table))
        let grayDescriptor = Self.descriptor(width: width, height: height, bitsStored: 8)
        XCTAssertThrowsError(try DicomJLSwiftBackend.decodeSynchronously(mapped, descriptor: grayDescriptor)) { error in
            XCTAssertTrue("\(error)".contains("mapping tables"), "\(error)")
        }
        // Truncated input is never padded with zeros: every cut fails.
        for cut in [1, 4, 17, plain.count / 2] {
            XCTAssertThrowsError(try DicomJLSwiftBackend.decodeSynchronously(plain.prefix(plain.count - cut), descriptor: descriptor), "cut \(cut)")
        }
        XCTAssertThrowsError(try DicomJLSwiftBackend.decodeSynchronously(Data([0xFF, 0xD8, 0xFF]), descriptor: descriptor))
        XCTAssertThrowsError(try DicomJLSwiftBackend.decodeSynchronously(Data(), descriptor: descriptor))
        // Random corruption after SOS never crashes; a successful decode keeps the declared shape.
        let sos = try XCTUnwrap(plain.firstRange(of: Data([0xFF, 0xDA])))
        var state: UInt32 = 3
        for _ in 0..<40 {
            var garbage = plain
            for index in sos.upperBound..<garbage.count {
                state = state &* 1_664_525 &+ 1_013_904_223
                if state % 6 == 0 { garbage[index] = UInt8(truncatingIfNeeded: state >> 16) }
            }
            if let decoded = try? DicomJLSwiftBackend.decodeSynchronously(garbage, descriptor: descriptor) {
                XCTAssertEqual(decoded.buffer.data.count, width * height * 3)
            }
        }
        // Wrong syntax for the NEAR value is a metadata mismatch.
        let nearStream = try JPEGLSEncoder().encode(grayImage, near: 2)
        XCTAssertThrowsError(try DicomJLSwiftBackend.decodeSynchronously(nearStream, descriptor: grayDescriptor)) { error in
            XCTAssertTrue("\(error)".contains("NEAR=2"), "\(error)")
        }
    }

    // MARK: - Transcoder, pixel reader and other families

    func test_transcoderAppliesOptionsAcrossMultiframeAndBothDecodePathsUseTheOwnCodec() async throws {
        let width = 14, height = 9, frames = 3
        let rgb = Self.samples(width: width, height: height * frames, precision: 8, components: 3, seed: 21)
        let file = try Self.nativeFile(samples: rgb, width: width, height: height, bitsStored: 8, frames: frames, samplesPerPixel: 3)
        let engine = DicomCodecWorkflowEngine()
        for interleave in [DicomJPEGLSInterleave.perComponent, .line, .sample] {
            let result = try await engine.transcode(file, to: .jpegLSLossless, intent: .jpegLS(options: DicomJPEGLSEncodingOptions(interleave: interleave)))
            let decoder = try DCMDecoder(data: result.data)
            XCTAssertEqual(decoder.info(for: .sopInstanceUID), "2.25.23280001")
            XCTAssertEqual(decoder.info(for: .planarConfiguration), "0")
            let reader = try DicomEncapsulatedPixelFrameReader(descriptor: try XCTUnwrap(decoder.encapsulatedPixelDataDescriptor), fileData: result.data)
            XCTAssertEqual(reader.frameCount, frames)
            let frameReader = DicomDecodedFrameReader(decoder: decoder)
            for index in 0..<frames {
                XCTAssertEqual(try Self.interleaveScanMode(try reader.frame(at: index).data).rawValue, UInt8(interleave == .perComponent ? 0 : interleave == .line ? 1 : 2))
                let execution = try await frameReader.frameExecution(at: index, environment: [:])
                XCTAssertEqual(execution.backendIdentifier, "jlswift", "own codec is preferred by default")
                guard case .rgb8(let pixels) = execution.frame.pixels else { return XCTFail("rgb8 expected") }
                XCTAssertEqual(pixels, Array(Self.littleEndian(Array(rgb[(index * width * height * 3)..<((index + 1) * width * height * 3)]), bitsAllocated: 8)), "\(interleave) frame \(index)")
            }
            // Synchronous pixel reader (first frame) goes through the own decoder as well.
            XCTAssertEqual(try XCTUnwrap(decoder.getPixels24()), Array(rgb.prefix(width * height * 3)).map { UInt8($0) })
        }
        // Near-lossless keeps the loss policy: new SOP Instance UID, ISO_14495_1, and the NEAR bound on every frame.
        let gray = Self.samples(width: width, height: height * frames, precision: 12, components: 1, seed: 4)
        let grayFile = try Self.nativeFile(samples: gray, width: width, height: height, bitsStored: 12, frames: frames)
        let near = try await engine.transcode(grayFile, to: .jpegLSNearLossless, intent: .jpegLS(options: DicomJPEGLSEncodingOptions(near: 2)))
        let nearDecoder = try DCMDecoder(data: near.data)
        XCTAssertNotEqual(nearDecoder.info(for: .sopInstanceUID), "2.25.23280001")
        XCTAssertEqual(nearDecoder.dataSet.strings(for: .lossyImageCompressionMethod), ["ISO_14495_1"])
        let nearReader = DicomDecodedFrameReader(decoder: nearDecoder)
        for index in 0..<frames {
            guard case .gray16(let pixels) = try await nearReader.frame(at: index).pixels else { return XCTFail("gray16 expected") }
            XCTAssertLessThanOrEqual(zip(pixels, gray[(index * width * height)..<((index + 1) * width * height)]).map { abs(Int($0) - Int($1)) }.max() ?? Int.max, 2)
        }
        // Lossless round trip back to native is exact; the plan reports the options.
        let lossless = try await engine.transcode(grayFile, to: .jpegLSLossless, intent: .jpegLS(options: DicomJPEGLSEncodingOptions(restartIntervalLines: 4)))
        let back = try await engine.transcode(lossless.data, to: .explicitVRLittleEndian)
        let backReader = DicomDecodedFrameReader(decoder: try DCMDecoder(data: back.data))
        for index in 0..<frames {
            guard case .gray16(let pixels) = try await backReader.frame(at: index).pixels else { return XCTFail("gray16 expected") }
            XCTAssertEqual(pixels, Array(gray[(index * width * height)..<((index + 1) * width * height)]))
        }
        let decision = DicomCodecCapabilities.resolve(DicomCodecCapabilityRequest(operation: .encode, descriptor: Self.descriptor(width: width, height: height, bitsStored: 12),
                                                                                    intent: .jpegLS(options: DicomJPEGLSEncodingOptions(restartIntervalLines: 4))))
        XCTAssertTrue(decision.canExecute, decision.reason ?? "")
        XCTAssertEqual(decision.encodingIntent, "jpeg-ls(near: 0, interleave: default, restartIntervalLines: 4)")
        // Other families refuse the JPEG-LS options.
        for syntax in [DicomTransferSyntax.jpeg2000Lossless, .jpegLossless, .jpegXLLossless, .rleLossless] {
            let other = Self.descriptor(syntax, width: width, height: height, bitsStored: 12)
            XCTAssertFalse(DicomCodecCapabilities.resolve(DicomCodecCapabilityRequest(operation: .encode, descriptor: other,
                                                                                        intent: .jpegLS(options: DicomJPEGLSEncodingOptions(near: 0)))).canExecute, syntax.rawValue)
        }
        // Disabled rollout keeps the established CharLS path when it is present.
        if DicomJPEGLSCodec.isAvailable {
            let disabled = try await DicomDecodedFrameReader(decoder: try DCMDecoder(data: lossless.data)).frameExecution(at: 0, environment: ["DICOM_JLSWIFT_MODE": "disabled"])
            XCTAssertNotEqual(disabled.backendIdentifier, "jlswift")
        }
    }

    // MARK: - Release timing

    func test_releaseTimingOfTheOwnCodecAgainstCharLS() async throws {
        #if DEBUG
        throw XCTSkip("JPEG-LS timing is measured in Release only (swift test -c release -Xswiftc -enable-testing).")
        #else
        try requireCharLS()
        let width = 512, height = 512
        let source = Self.samples(width: width, height: height, precision: 16, components: 1, seed: 31)
        let descriptor = Self.descriptor(width: width, height: height, bitsStored: 16)
        let bytes = Self.littleEndian(source, bitsAllocated: 16)
        func time(_ iterations: Int, _ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { try body() }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations) / 1_000_000
        }
        let request = DicomFrameEncodeRequest(frame: Self.frame(bytes, descriptor: descriptor), descriptor: descriptor, targetTransferSyntaxUID: descriptor.transferSyntaxUID)
        let backend = DicomJLSwiftBackend()
        let encoded = try await backend.encode(request)
        let encodeStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<10 { _ = try await backend.encode(request) }
        let ownEncode = Double(DispatchTime.now().uptimeNanoseconds - encodeStart) / 10 / 1_000_000
        let ownDecode = try time(10) { _ = try DicomJLSwiftBackend.decodeSynchronously(encoded, descriptor: descriptor) }
        let charlsEncode = try time(10) { _ = try DicomJPEGLSCodec.encodeForTesting(bytes: bytes, width: width, height: height, bitsPerSample: 16) }
        let charlsDecode = try time(10) { _ = try DicomJPEGLSCodec.decode(encoded) }
        print("JPEG-LS-BENCH 512x512 gray16 lossless: own encode \(String(format: "%.2f", ownEncode)) ms, CharLS encode \(String(format: "%.2f", charlsEncode)) ms, own decode \(String(format: "%.2f", ownDecode)) ms, CharLS decode \(String(format: "%.2f", charlsDecode)) ms, codestream \(encoded.count) bytes")
        #endif
    }
}
