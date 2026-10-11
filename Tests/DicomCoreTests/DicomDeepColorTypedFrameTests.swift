//
//  DicomDeepColorTypedFrameTests.swift
//  DicomCoreTests
//
//  Issue #3034: 16-bit RGB, 16-bit palette indices and 1-bit frames cross the typed reader, the selective
//  session and the codec backends with their stored samples, component order, effective Bits Allocated/Stored/
//  High Bit and buffer ownership. Every expected value is computed here from the synthetic input, never from
//  the decoder under test; compressed fixtures come from independent encoders (a PackBits writer in this file,
//  CharLS, a hand-written SOF3 stream) or are cross-checked by an independent decoder (OpenJPEG, CharLS, JLISwift).
//

import DicomJPEG
import DicomJPEG2000
import Foundation
import XCTest
@testable import DicomCore

final class DicomDeepColorTypedFrameTests: XCTestCase {
    // MARK: - Native 16-bit RGB

    func test_nativeRGB16_littleAndBigEndianInterleavedAndPlanar_preserveStoredSamples() async throws {
        for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .implicitVRLittleEndian, .explicitVRBigEndian] {
            for planar in [0, 1] {
                let shape = Shape(rows: 5, columns: 7, frames: 3, samples: 3, bitsAllocated: 16, bitsStored: 16,
                                  photometric: "RGB", planar: planar)
                let frames = Self.rgbFrames(shape, seed: 3)
                let data = try Self.part10(shape: shape, pixelData: Self.nativeWords(frames, shape: shape, syntax: syntax),
                                           syntax: syntax)
                let reader = try DicomDecodedFrameReader(decoder: DCMDecoder(data: data))
                let label = "\(syntax.rawValue) planar \(planar)"
                XCTAssertEqual(reader.frameCount, 3, label)
                for index in 0..<3 {
                    let frame = try Self.syncFrame(reader, index)
                    XCTAssertEqual(frame.pixels, .rgb16(interleaved: frames[index]), "\(label) frame \(index)")
                    XCTAssertEqual(frame.metadata.bitsAllocated, 16, label)
                    XCTAssertEqual(frame.metadata.bitsStored, 16, label)
                    XCTAssertEqual(frame.metadata.highBit, 15, label)
                    XCTAssertEqual(frame.metadata.samplesPerPixel, 3, label)
                    XCTAssertEqual(frame.storedSampleData(), Self.littleEndian(frames[index]), label)
                    let asynchronous = try await reader.frame(at: index)
                    XCTAssertEqual(asynchronous.pixels, frame.pixels, "\(label): async reader")
                    let backed = try await reader.dataBackedFrame(at: index)
                    XCTAssertEqual(backed.pixels.format, .rgb16Interleaved, label)
                    XCTAssertEqual(backed.pixels.byteOrder, .littleEndian, label)
                    XCTAssertEqual(backed.pixels.componentSampleCount, shape.rows * shape.columns * 3, label)
                    XCTAssertEqual(backed.pixels.bytesPerRow, shape.columns * 6, label)
                    XCTAssertEqual(backed.pixels.data, Self.littleEndian(frames[index]), label)
                    XCTAssertEqual(try backed.copyingToArrayBackedFrame().pixels, frame.pixels, label)
                }
            }
        }
    }

    func test_nativeRGB16_precisionBelowTheContainer_isRightAlignedAndMasked() async throws {
        // Bits Stored 12 at High Bit 11 with noise above it, and Bits Stored 10 at High Bit 15 (shifted samples).
        // Planar Configuration 1 and big-endian words go through the same masking.
        let variants: [(Int, Int, Int, DicomTransferSyntax)] = [
            (12, 11, 0, .explicitVRLittleEndian), (10, 15, 0, .explicitVRLittleEndian),
            (12, 11, 1, .explicitVRLittleEndian), (10, 15, 1, .explicitVRBigEndian)
        ]
        for (bitsStored, highBit, planar, syntax) in variants {
            let shape = Shape(rows: 4, columns: 6, frames: 2, samples: 3, bitsAllocated: 16, bitsStored: bitsStored,
                              highBit: highBit, photometric: "RGB", planar: planar)
            let frames = Self.rgbFrames(shape, seed: 11)
            let shift = highBit - bitsStored + 1
            let noise: UInt16 = shift == 0 ? 0xA000 : 0x0015
            let words = frames.map { $0.map { ($0 << UInt16(shift)) | noise } }
            let data = try Self.part10(shape: shape, pixelData: Self.nativeWords(words, shape: shape, syntax: syntax), syntax: syntax)
            let reader = try DicomDecodedFrameReader(decoder: DCMDecoder(data: data))
            for index in 0..<2 {
                let frame = try Self.syncFrame(reader, index)
                XCTAssertEqual(frame.pixels, .rgb16(interleaved: frames[index]), "\(bitsStored)/\(highBit) planar \(planar) frame \(index)")
                XCTAssertEqual(frame.metadata.bitsStored, bitsStored)
                XCTAssertEqual(frame.metadata.highBit, bitsStored - 1, "samples are right-aligned")
                let backed = try await reader.dataBackedFrame(at: index)
                XCTAssertEqual(backed.pixels.data, Self.littleEndian(frames[index]))
                XCTAssertEqual(backed.metadata.highBit, bitsStored - 1)
            }
        }
    }

    // MARK: - Selective session

    func test_selectiveSession_deliversRGB16PaletteAndOneBitFramesOneAtATime() async throws {
        let shape = Shape(rows: 9, columns: 11, frames: 4, samples: 3, bitsAllocated: 16, bitsStored: 16, photometric: "RGB", planar: 1)
        let frames = Self.rgbFrames(shape, seed: 5)
        let data = try Self.part10(shape: shape, pixelData: Self.nativeWords(frames, shape: shape, syntax: .explicitVRLittleEndian),
                                   syntax: .explicitVRLittleEndian)
        let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: data))
        let frameBytes = shape.rows * shape.columns * 6
        for index in [2, 0] {
            let before = await session.metrics
            let frame = try await session.frame(at: index)
            XCTAssertEqual(frame.index, index)
            XCTAssertEqual(frame.pixels, .rgb16(interleaved: frames[index]))
            let backed = try await session.dataBackedFrame(at: index)
            XCTAssertEqual(backed.pixels.data, Self.littleEndian(frames[index]))
            XCTAssertEqual(backed.pixels.ownership, .ownedData, "planar samples are interleaved into owned storage")
            let after = await session.metrics
            XCTAssertEqual(after.source.receivedBytes - before.source.receivedBytes, frameBytes * 2,
                           "two requests read exactly the selected frame twice, never a sibling frame")
            XCTAssertEqual(after.retainedCompletedBytes, 0)
            XCTAssertEqual(after.inFlightReservedBytes, 0)
        }
        var iterator = try session.frames(in: 1..<3).makeAsyncIterator()
        while let raw = try await iterator.next() {
            XCTAssertEqual(raw.data.count, frameBytes, "the pull sequence returns one stored frame per step")
        }
        await session.close()

        let palette = try PaletteFixture(syntax: .explicitVRLittleEndian, frames: 2)
        let paletteSession = try await DicomSourceFrameSession.open(source: DicomByteSource(data: palette.data))
        let paletteFrame = try await paletteSession.frame(at: 1)
        XCTAssertEqual(paletteFrame.storedSampleData(), Self.littleEndian(palette.indices[1]), "indices keep their precision")
        await paletteSession.close()

        let oneBit = try OneBitFixture(photometric: "MONOCHROME2")
        let bitSession = try await DicomSourceFrameSession.open(source: DicomByteSource(data: oneBit.data))
        for index in 0..<oneBit.frames.count {
            let frame = try await bitSession.frame(at: index)
            XCTAssertEqual(frame.pixels, .gray8(oneBit.frames[index]), "frame \(index) starts at bit \(index * oneBit.pixels)")
        }
        await bitSession.close()
    }

    func test_selectiveSession_refusesAnOversizedRGB16FrameBeforeDecodingAndHonoursCancellation() async throws {
        let shape = Shape(rows: 32, columns: 32, frames: 2, samples: 3, bitsAllocated: 16, bitsStored: 16, photometric: "RGB", planar: 0)
        let data = try Self.part10(shape: shape, pixelData: Self.nativeWords(Self.rgbFrames(shape, seed: 1), shape: shape,
                                                                              syntax: .explicitVRLittleEndian),
                                   syntax: .explicitVRLittleEndian)
        // 32 × 32 × 3 × 2 = 6 144 decoded bytes: a 4 KiB frame limit refuses it before any pixel byte is read.
        let limited = try await DicomSourceFrameSession.open(
            source: DicomByteSource(data: data), limits: .init(maximumFrameBytes: 4096))
        let before = await limited.metrics
        do {
            _ = try await limited.frame(at: 0)
            XCTFail("expected the frame limit")
        } catch {
            XCTAssertEqual(error as? DicomSourceFrameIndex.Failure, .frameLimit)
        }
        let after = await limited.metrics
        XCTAssertEqual(after.source.receivedBytes, before.source.receivedBytes, "no pixel byte was read")
        XCTAssertEqual(after.materializedBytes, 0)
        await limited.close()

        let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: data))
        let task = Task { try await session.frame(at: 1) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let metrics = await session.metrics
        XCTAssertEqual(metrics.retainedCompletedBytes, 0)
        await session.close()
    }

    // MARK: - Compressed 16-bit RGB

    func test_rleRGB16_independentSegments_decodeToTheStoredSamples() async throws {
        let shape = Shape(rows: 6, columns: 5, frames: 2, samples: 3, bitsAllocated: 16, bitsStored: 16, photometric: "RGB", planar: 0)
        let frames = Self.rgbFrames(shape, seed: 7)
        let fragments = frames.map { Self.rleFrame(interleaved: $0, pixelCount: shape.rows * shape.columns) }
        let data = try Self.part10(shape: shape, fragments: fragments, syntax: .rleLossless)
        let reader = try DicomDecodedFrameReader(decoder: DCMDecoder(data: data))
        for index in 0..<2 {
            XCTAssertEqual(try Self.syncFrame(reader, index).pixels, .rgb16(interleaved: frames[index]), "frame \(index)")
            let backed = try await reader.dataBackedFrame(at: index)
            XCTAssertEqual(backed.pixels.format, .rgb16Interleaved)
            XCTAssertEqual(backed.pixels.data, Self.littleEndian(frames[index]))
        }
        let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: data))
        let sessionFrame = try await session.frame(at: 1)
        XCTAssertEqual(sessionFrame.pixels, .rgb16(interleaved: frames[1]))
        await session.close()

        // Bits Stored 12: the RLE words keep noise above the High Bit, which the typed frame drops.
        let narrow = Shape(rows: 3, columns: 4, frames: 1, samples: 3, bitsAllocated: 16, bitsStored: 12, photometric: "RGB", planar: 0)
        let narrowFrame = Self.rgbFrames(narrow, seed: 2)[0]
        let noisy = Self.rleFrame(interleaved: narrowFrame.map { $0 | 0xF000 }, pixelCount: 12)
        let narrowReader = try DicomDecodedFrameReader(decoder: DCMDecoder(data: Self.part10(shape: narrow, fragments: [noisy], syntax: .rleLossless)))
        let decoded = try Self.syncFrame(narrowReader, 0)
        XCTAssertEqual(decoded.pixels, .rgb16(interleaved: narrowFrame))
        XCTAssertEqual(decoded.metadata.highBit, 11)
    }

    func test_jpegLosslessRGB16_independentSOF3Stream_decodesExactly() async throws {
        for (precision, syntax) in [(16, DicomTransferSyntax.jpegLosslessFirstOrder), (12, .jpegLossless)] {
            let shape = Shape(rows: 6, columns: 8, frames: 1, samples: 3, bitsAllocated: 16, bitsStored: precision, photometric: "RGB", planar: 0)
            let frame = Self.rgbFrames(shape, seed: 13)[0]
            let pixelCount = shape.rows * shape.columns
            let planes = (0..<3).map { component in (0..<pixelCount).map { Int(frame[$0 * 3 + component]) } }
            let stream = makeJPEGLosslessStream(planes: planes, width: shape.columns, height: shape.rows, precision: precision)
            // JLISwift is an independent SOF3 decoder (a different code base from the own lossless decoder); its
            // 16-bit output holds full-precision samples only for P=16, so the 12-bit stream is checked against the
            // samples it was written from.
            if precision == 16 {
                let independent = try JLIDecoder().decode(from: [UInt8](stream), configuration: JLIDecoderConfiguration(
                    outputPixelFormat: .uint16, outputColorModel: .rgb))
                XCTAssertEqual(Data(independent.data), Self.littleEndian(frame), "JLISwift reads the stream as written")
            }

            let data = try Self.part10(shape: shape, fragments: [stream], syntax: syntax)
            let reader = try DicomDecodedFrameReader(decoder: DCMDecoder(data: data))
            let execution = try await reader.frameExecution(at: 0)
            XCTAssertEqual(execution.frame.pixels, .rgb16(interleaved: frame), "P=\(precision)")
            XCTAssertEqual(execution.frame.metadata.bitsStored, precision)
            XCTAssertEqual(try Self.syncFrame(reader, 0).pixels, .rgb16(interleaved: frame), "synchronous legacy path, P=\(precision)")
            let backed = try await reader.dataBackedFrame(at: 0)
            XCTAssertEqual(backed.pixels.data, Self.littleEndian(frame))
        }
    }

    func test_jpegLSRGB16_charLSEncoded_decodesThroughTheOwnBackend() async throws {
        try XCTSkipUnless(DicomJPEGLSCodec.isAvailable, "CharLS is not installed on this host")
        for (precision, near, syntax) in [(16, 0, DicomTransferSyntax.jpegLSLossless), (12, 0, .jpegLSLossless), (12, 2, .jpegLSNearLossless)] {
            let shape = Shape(rows: 7, columns: 9, frames: 1, samples: 3, bitsAllocated: 16, bitsStored: precision, photometric: "RGB", planar: 0)
            let frame = Self.rgbFrames(shape, seed: 17)[0]
            let stream = try DicomJPEGLSCodec.encodeForTesting(bytes: Self.littleEndian(frame), width: shape.columns,
                                                               height: shape.rows, bitsPerSample: precision, componentCount: 3,
                                                               nearLossless: near)
            let data = try Self.part10(shape: shape, fragments: [stream], syntax: syntax)
            let reader = try DicomDecodedFrameReader(decoder: DCMDecoder(data: data))
            let execution = try await reader.frameExecution(at: 0, environment: [:])
            XCTAssertEqual(execution.backendIdentifier, DicomCodecBackendIdentifier.jlSwift.rawValue)
            guard case .rgb16(let decoded) = execution.frame.pixels else { return XCTFail("P=\(precision) NEAR=\(near): not rgb16") }
            // CharLS decodes the same codestream independently: the own result must be identical, lossless or not.
            let independent = try DicomJPEGLSCodec.decode(stream)
            XCTAssertEqual(Self.littleEndian(decoded), independent.bytes, "P=\(precision) NEAR=\(near)")
            let largest = zip(decoded, frame).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(largest, near, "the NEAR bound holds against the source samples")
            if near == 0 { XCTAssertEqual(decoded, frame) }
            let backed = try await reader.dataBackedFrame(at: 0, environment: [:])
            XCTAssertEqual(backed.pixels.data, Self.littleEndian(decoded))
        }
    }

    func test_jpeg2000AndHTJ2KRGB16_ownDecodeMatchesTheSourceAndOpenJPEG() async throws {
        for (precision, syntax) in [(16, DicomTransferSyntax.jpeg2000Lossless), (12, .jpeg2000Lossless), (16, .htj2kLossless)] {
            let shape = Shape(rows: 8, columns: 10, frames: 1, samples: 3, bitsAllocated: 16, bitsStored: precision,
                              photometric: "YBR_RCT", planar: 0)
            let frame = Self.rgbFrames(shape, seed: 19)[0]
            let stream = try await Self.j2kStream(frame, shape: shape, htj2k: syntax == .htj2kLossless)
            let data = try Self.part10(shape: shape, fragments: [stream], syntax: syntax)
            let reader = try DicomDecodedFrameReader(decoder: DCMDecoder(data: data))
            let execution = try await reader.frameExecution(at: 0, environment: [:])
            XCTAssertEqual(execution.frame.pixels, .rgb16(interleaved: frame), "\(syntax.rawValue) P=\(precision)")
            XCTAssertEqual(execution.backendIdentifier, DicomCodecBackendIdentifier.j2kSwiftCPU.rawValue)
            let backed = try await reader.dataBackedFrame(at: 0, environment: [:])
            XCTAssertEqual(backed.pixels.format, .rgb16Interleaved)
            XCTAssertEqual(backed.pixels.data, Self.littleEndian(frame))
            let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: data))
            let sessionFrame = try await session.frame(at: 0)
            XCTAssertEqual(sessionFrame.pixels, .rgb16(interleaved: frame))
            await session.close()
            // OpenJPEG is an independent JPEG 2000 decoder; it undoes the same RCT into the same samples.
            if DicomCodecCapabilities.capability(for: .openJPEG).isAvailable,
               syntax != .htj2kLossless || DicomJPEG2000Codec.supportsHTJ2K {
                let independent = try DicomJPEG2000Codec.decode(stream)
                XCTAssertEqual(independent.componentCount, 3)
                XCTAssertEqual(independent.bytes, Self.littleEndian(frame), "OpenJPEG, \(syntax.rawValue) P=\(precision)")
            }
        }
    }

    // MARK: - 16-bit palette indices

    func test_palette16_indicesStayIndicesAndTheDisplayConversionUsesTheClampedSegmentedLUT() async throws {
        for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .explicitVRBigEndian] {
            for segmented in [false, true] {
                for (bitsStored, highBit) in [(16, 15), (12, 11)] {
                    let fixture = try PaletteFixture(syntax: syntax, frames: 2, segmented: segmented, bitsStored: bitsStored, highBit: highBit)
                    let decoder = try DCMDecoder(data: fixture.data)
                    let reader = DicomDecodedFrameReader(decoder: decoder)
                    let label = "\(syntax.rawValue) segmented \(segmented) bits \(bitsStored)"
                    for index in 0..<2 {
                        let frame = try Self.syncFrame(reader, index)
                        guard case .gray16 = frame.pixels else { return XCTFail("\(label): palette indices are a 16-bit index buffer") }
                        XCTAssertEqual(frame.metadata.photometricInterpretation, "PALETTE COLOR", label)
                        XCTAssertEqual(frame.storedSampleData(), Self.littleEndian(fixture.indices[index]),
                                       "\(label): the stored indices come back exactly, never windowed or rescaled")
                        XCTAssertEqual(try decoder.displayRGB8(decodedFrame: frame), fixture.expectedRGB8(frame: index), label)
                    }
                }
            }
        }
    }

    // MARK: - 1-bit

    func test_oneBit_monochromeFramesAreTypedThroughTheReaderAtTheirBitOffsets() async throws {
        for photometric in ["MONOCHROME2", "MONOCHROME1"] {
            let fixture = try OneBitFixture(photometric: photometric)
            let reader = try DicomDecodedFrameReader(decoder: DCMDecoder(data: fixture.data))
            XCTAssertEqual(reader.frameCount, fixture.frames.count)
            for index in 0..<fixture.frames.count {
                let frame = try Self.syncFrame(reader, index)
                let expected = photometric == "MONOCHROME1" ? fixture.frames[index].map { 1 - $0 } : fixture.frames[index]
                XCTAssertEqual(frame.pixels, .gray8(expected), "\(photometric) frame \(index)")
                XCTAssertEqual(frame.metadata.bitsAllocated, 1)
                XCTAssertEqual(frame.metadata.bitsStored, 1)
                XCTAssertEqual(frame.storedSampleData(), Data(fixture.frames[index]), "stored bits as written, \(photometric)")
                let backed = try await reader.dataBackedFrame(at: index)
                XCTAssertEqual(backed.pixels.ownership, .ownedData)
                XCTAssertEqual(Array(backed.pixels.data), expected)
            }
        }
    }

    // MARK: - Capabilities and refusals

    func test_capabilities_reportDeepColorDecodeAsExecutableAndKeepEncodingAndOtherShapesRefused() {
        func decision(_ syntax: DicomTransferSyntax, bits: Int = 16, stored: Int = 16, signed: Int = 0, photometric: String = "RGB",
                      samples: Int = 3, operation: DicomCodecOperation = .decode) -> DicomCodecDecision {
            DicomCodecCapabilities.resolve(DicomCodecCapabilityRequest(operation: operation, descriptor: DicomCompressedFrameDescriptor(
                transferSyntaxUID: syntax.rawValue, rows: 8, columns: 8, bitsAllocated: bits, bitsStored: stored,
                highBit: stored - 1, pixelRepresentation: signed, samplesPerPixel: samples,
                photometricInterpretation: photometric, planarConfiguration: samples == 3 ? 0 : nil)), environment: [:])
        }
        let executable: [(DicomTransferSyntax, String)] = [
            (.explicitVRLittleEndian, "RGB"), (.explicitVRBigEndian, "RGB"), (.rleLossless, "RGB"), (.jpegLossless, "RGB"),
            (.jpegLosslessFirstOrder, "RGB"), (.jpegLSLossless, "RGB"), (.jpegLSNearLossless, "RGB"),
            (.jpeg2000Lossless, "YBR_RCT"), (.jpeg2000Lossless, "RGB"), (.htj2kLossless, "YBR_RCT"), (.htj2kLosslessRPCL, "YBR_RCT")
        ]
        for (syntax, photometric) in executable {
            let result = decision(syntax, photometric: photometric)
            XCTAssertTrue(result.canExecute, "\(syntax.rawValue) \(photometric): \(result.reason ?? "")")
            XCTAssertEqual(result.qualification, .qualified, syntax.rawValue)
        }
        // Deeper YBR has no typed conversion; signed colour has no meaning; 32-bit samples stay outside the model.
        for (syntax, photometric) in [(DicomTransferSyntax.jpegLSLossless, "YBR_FULL"), (.jpeg2000Lossless, "YBR_FULL"),
                                      (.htj2kLossless, "YBR_FULL")] {
            XCTAssertFalse(decision(syntax, photometric: photometric).canExecute, "\(syntax.rawValue) \(photometric)")
        }
        XCTAssertFalse(decision(.jpeg2000Lossless, signed: 1, photometric: "YBR_RCT").canExecute, "signed J2K colour")
        XCTAssertFalse(decision(.explicitVRLittleEndian, bits: 32, stored: 32).canExecute, "32-bit colour")
        // Deep colour is a decode capability: no own encoder writes it.
        for syntax in [DicomTransferSyntax.rleLossless, .jpegLossless, .jpegLSLossless, .jpeg2000Lossless, .htj2kLossless] {
            XCTAssertFalse(decision(syntax, operation: .encode).canExecute, "encode \(syntax.rawValue)")
        }
    }

    func test_refusals_areTypedForColourShapesOutsideTheTypedPipeline() async throws {
        func readError(_ shape: Shape, pixelData: Data? = nil, fragments: [Data]? = nil, syntax: DicomTransferSyntax) throws -> String? {
            let data = fragments.map { try? Self.part10(shape: shape, fragments: $0, syntax: syntax) }
                ?? (try? Self.part10(shape: shape, pixelData: pixelData ?? Data(), syntax: syntax))
            let reader = try DicomDecodedFrameReader(decoder: DCMDecoder(data: XCTUnwrap(data)))
            do {
                _ = try Self.syncFrame(reader, 0)
                return nil
            } catch let error as DicomDecodedFrameReader.ReadError {
                return error.localizedDescription
            }
        }
        var ybr = Shape(rows: 4, columns: 4, frames: 1, samples: 3, bitsAllocated: 16, bitsStored: 16, photometric: "YBR_FULL", planar: 0)
        let words = Self.nativeWords(Self.rgbFrames(ybr, seed: 1), shape: ybr, syntax: .explicitVRLittleEndian)
        XCTAssertTrue(try readError(ybr, pixelData: words, syntax: .explicitVRLittleEndian)?.contains("YBR_FULL") == true)
        XCTAssertTrue(try readError(ybr, fragments: [Self.rleFrame(interleaved: Self.rgbFrames(ybr, seed: 1)[0], pixelCount: 16)],
                                    syntax: .rleLossless)?.contains("YBR_FULL") == true)
        ybr.photometric = "RGB"
        ybr.pixelRepresentation = 1
        XCTAssertTrue(try readError(ybr, pixelData: words, syntax: .explicitVRLittleEndian)?.contains("signed") == true)
        let deep = Shape(rows: 2, columns: 2, frames: 1, samples: 3, bitsAllocated: 32, bitsStored: 32, photometric: "RGB", planar: 0)
        XCTAssertNotNil(try readError(deep, pixelData: Data(count: 48), syntax: .explicitVRLittleEndian), "32-bit colour")
    }

    // MARK: - Opt-in cost report

    /// Time, peak footprint and copies of the modified path, one frame at a time through the selective session.
    /// Opt-in (`DICOM_DEEP_COLOR_COST=1`); run with `-c release` for representative times.
    func test_costReport_measuresTimeMemoryAndCopiesPerProfile() async throws {
        guard ProcessInfo.processInfo.environment["DICOM_DEEP_COLOR_COST"] == "1" else {
            throw XCTSkip("Set DICOM_DEEP_COLOR_COST=1 to measure the deep-colour path.")
        }
        let shape = Shape(rows: 512, columns: 512, frames: 8, samples: 3, bitsAllocated: 16, bitsStored: 16, photometric: "RGB", planar: 0)
        let frames = Self.rgbFrames(shape, seed: 23)
        var planarShape = shape
        planarShape.planar = 1
        var cases: [(String, Data)] = [
            ("native RGB16 LE planar 0", try Self.part10(shape: shape, pixelData: Self.nativeWords(frames, shape: shape, syntax: .explicitVRLittleEndian), syntax: .explicitVRLittleEndian)),
            ("native RGB16 LE planar 1", try Self.part10(shape: planarShape, pixelData: Self.nativeWords(frames, shape: planarShape, syntax: .explicitVRLittleEndian), syntax: .explicitVRLittleEndian)),
            ("native RGB16 BE planar 0", try Self.part10(shape: shape, pixelData: Self.nativeWords(frames, shape: shape, syntax: .explicitVRBigEndian), syntax: .explicitVRBigEndian)),
            ("RLE RGB16", try Self.part10(shape: shape, fragments: frames.map { Self.rleFrame(interleaved: $0, pixelCount: 512 * 512) }, syntax: .rleLossless))
        ]
        var j2kShape = shape
        j2kShape.photometric = "YBR_RCT"
        j2kShape.frames = 1
        cases.append(("JPEG 2000 lossless RGB16", try Self.part10(shape: j2kShape, fragments: [try await Self.j2kStream(frames[0], shape: j2kShape, htj2k: false)], syntax: .jpeg2000Lossless)))
        let palette = try PaletteFixture(syntax: .explicitVRLittleEndian, frames: 8, rows: 512, columns: 512)
        cases.append(("native palette16", palette.data))
        var report = ["| Profile | Frames | ms/frame | Peak footprint growth (MiB) | Decoded bytes/frame | Source bytes read | Compatibility copies |",
                      "| --- | --- | --- | --- | --- | --- | --- |"]
        for (label, data) in cases {
            let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: data))
            let count = session.index.frameCount
            let baseline = Self.physicalFootprint()
            var peak = baseline
            let clock = ContinuousClock()
            var decodedBytes = 0
            let elapsed = try await clock.measure {
                for index in 0..<count {
                    let frame = try await session.frame(at: index)
                    decodedBytes = frame.storedSampleData().count
                    peak = max(peak, Self.physicalFootprint())
                }
            }
            let metrics = await session.metrics
            let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            report.append("| \(label) | \(count) | \(String(format: "%.2f", milliseconds / Double(count))) | "
                + "\(String(format: "%.1f", Double(peak - baseline) / 1_048_576)) | \(decodedBytes) | "
                + "\(metrics.source.receivedBytes) | \(metrics.source.compatibilityCopiedBytes) |")
            XCTAssertEqual(metrics.retainedCompletedBytes, 0)
            await session.close()
        }
        print(report.joined(separator: "\n"))
    }

    // MARK: - Fixtures

    /// The synchronous reader path (async tests would otherwise pick the async overload).
    static func syncFrame(_ reader: DicomDecodedFrameReader, _ index: Int) throws -> DicomDecodedFrame {
        try reader.frame(at: index)
    }

    struct Shape {
        var rows: Int
        var columns: Int
        var frames: Int
        var samples: Int
        var bitsAllocated: Int
        var bitsStored: Int
        var highBit: Int? = nil
        var pixelRepresentation = 0
        var photometric: String
        var planar: Int?
    }

    /// Deterministic interleaved RGB samples inside Bits Stored, with the extremes 0 and the maximum present and the
    /// three components of a pixel always distinct (a swapped component order cannot go unnoticed).
    static func rgbFrames(_ shape: Shape, seed: UInt32) -> [[UInt16]] {
        let maximum = (1 << shape.bitsStored) - 1
        var state = seed
        return (0..<shape.frames).map { frame in
            let pixels = shape.rows * shape.columns
            return (0..<(pixels * 3)).map { index in
                state = state &* 1_664_525 &+ 1_013_904_223
                let pixel = index / 3, component = index % 3
                if pixel == 0 { return UInt16([0, maximum, maximum / 2][component]) }
                if pixel == 1 { return UInt16([maximum, 0, 1][component]) }
                let base = (Int(state >> 8) + frame * 7_919) % (maximum + 1)
                return UInt16((base + component * (maximum / 3 + 1)) % (maximum + 1))
            }
        }
    }

    static func littleEndian(_ words: [UInt16]) -> Data {
        var data = Data(capacity: words.count * 2)
        for word in words { data.append(UInt8(word & 0xFF)); data.append(UInt8(word >> 8)) }
        return data
    }

    /// Native Pixel Data in the syntax's byte order, planes per frame when Planar Configuration is 1.
    static func nativeWords(_ frames: [[UInt16]], shape: Shape, syntax: DicomTransferSyntax) -> Data {
        var data = Data()
        let pixels = shape.rows * shape.columns
        for frame in frames {
            let ordered = shape.planar == 1
                ? (0..<3).flatMap { component in (0..<pixels).map { frame[$0 * 3 + component] } }
                : frame
            for word in ordered {
                if syntax == .explicitVRBigEndian { data.append(UInt8(word >> 8)); data.append(UInt8(word & 0xFF)) }
                else { data.append(UInt8(word & 0xFF)); data.append(UInt8(word >> 8)) }
            }
        }
        return data
    }

    static func dataSet(shape: Shape, extra: [DicomDataElement] = []) -> DicomDataSet {
        func us(_ tag: DicomTag, _ value: Int) -> DicomDataElement { .init(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([UInt(value)])) }
        func str(_ tag: DicomTag, _ vr: DicomVR, _ value: String) -> DicomDataElement { .init(tag: tag.rawValue, vr: vr, value: .strings([value])) }
        var elements: [DicomDataElement] = [
            str(.sopClassUID, .UI, "1.2.840.10008.5.1.4.1.1.7"), str(.sopInstanceUID, .UI, "2.25.30340001"),
            str(.studyInstanceUID, .UI, "2.25.30340002"), str(.seriesInstanceUID, .UI, "2.25.30340003"), str(.modality, .CS, "OT"),
            us(.rows, shape.rows), us(.columns, shape.columns), us(.samplesPerPixel, shape.samples),
            str(.photometricInterpretation, .CS, shape.photometric), us(.bitsAllocated, shape.bitsAllocated),
            us(.bitsStored, shape.bitsStored), us(.highBit, shape.highBit ?? shape.bitsStored - 1),
            us(.pixelRepresentation, shape.pixelRepresentation)
        ]
        if shape.frames > 1 { elements.append(str(.numberOfFrames, .IS, String(shape.frames))) }
        if let planar = shape.planar { elements.append(us(.planarConfiguration, planar)) }
        return DicomDataSet(elements: elements + extra)
    }

    static func part10(shape: Shape, pixelData: Data, syntax: DicomTransferSyntax, extra: [DicomDataElement] = []) throws -> Data {
        var bytes = pixelData
        if !bytes.count.isMultiple(of: 2) { bytes.append(0) }
        let set = dataSet(shape: shape, extra: extra).setting(.init(tag: DicomTag.pixelData.rawValue,
                                                                    vr: shape.bitsAllocated > 8 ? .OW : .OB, value: .bytes(bytes)))
        return try DicomDataSetWriter.part10Data(from: set, options: .init(transferSyntax: syntax))
    }

    static func part10(shape: Shape, fragments: [Data], syntax: DicomTransferSyntax) throws -> Data {
        let encapsulation = try DicomTranscoder.encapsulate(fragments: fragments)
        let set = dataSet(shape: shape).setting(.init(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(encapsulation.pixelData)))
        return try DicomDataSetWriter.part10Data(from: set, options: .init(transferSyntax: syntax))
    }

    /// PS3.5 Annex G written independently of the codec under test: one segment per byte of each sample (R high,
    /// R low, G high, G low, B high, B low), each a sequence of literal PackBits runs.
    static func rleFrame(interleaved: [UInt16], pixelCount: Int) -> Data {
        let segments: [[UInt8]] = (0..<6).map { segment in
            let component = segment / 2, high = segment % 2 == 0
            let bytes = (0..<pixelCount).map { pixel -> UInt8 in
                let word = interleaved[pixel * 3 + component]
                return high ? UInt8(word >> 8) : UInt8(word & 0xFF)
            }
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
        for value in header { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        for segment in segments { data.append(contentsOf: segment) }
        return data
    }

    /// Reversible JPEG 2000 (or HTJ2K) codestream of the vendored J2KSwift encoder with the reversible colour
    /// transform; the frame is labelled YBR_RCT, as PS3.5 8.2.4 requires for an MCT stream.
    static func j2kStream(_ frame: [UInt16], shape: Shape, htj2k: Bool) async throws -> Data {
        let pixels = shape.rows * shape.columns
        let components = (0..<3).map { component in
            J2KComponent(index: component, bitDepth: shape.bitsStored, signed: false, width: shape.columns, height: shape.rows,
                         data: littleEndian((0..<pixels).map { frame[$0 * 3 + component] }), sampleByteOrder: .littleEndian)
        }
        let configuration = J2KEncodingConfiguration(
            quality: 1, lossless: true, decompositionLevels: 2, qualityLayers: 1, progressionOrder: .lrcp,
            bitrateMode: .lossless, useHTJ2K: htj2k, useReversibleFilter: true)
        return try await J2KEncoder(encodingConfiguration: configuration)
            .encode(J2KImage(width: shape.columns, height: shape.rows, components: components, colorSpace: .sRGB))
    }

    /// 16-bit PALETTE COLOR object: indices below the first mapped value and above the last entry (clamping), a
    /// non-zero first mapped value, 16-bit LUT entries in the syntax's byte order, standard or segmented LUTs.
    struct PaletteFixture {
        static let entryCount = 64
        static let firstMapped = 100
        let data: Data
        let indices: [[UInt16]]
        let red: [UInt16], green: [UInt16], blue: [UInt16]

        init(syntax: DicomTransferSyntax, frames: Int, segmented: Bool = false, bitsStored: Int = 16, highBit: Int = 15,
             rows: Int = 5, columns: Int = 6) throws {
            let count = Self.entryCount
            // Linear ramps whose steps divide exactly, so the segmented expansion has one unambiguous value per entry.
            red = (0..<count).map { UInt16($0 * 1024) }
            green = (0..<count).map { UInt16(65_535 - $0 * 1024) }
            blue = (0..<count).map { UInt16($0 < 32 ? 0x1234 : 0xFEDC) }
            let pixels = rows * columns
            let maximum = (1 << bitsStored) - 1
            indices = (0..<frames).map { frame in
                (0..<pixels).map { pixel in
                    switch pixel {
                    case 0: return 0                          // below the first mapped value
                    case 1: return UInt16(Self.firstMapped - 1)
                    case 2: return UInt16(Self.firstMapped)    // first entry
                    case 3: return UInt16(Self.firstMapped + count - 1)
                    case 4: return UInt16(maximum)             // above the last entry
                    default: return UInt16((Self.firstMapped + (pixel * 7 + frame * 13) % (count + 10)) & maximum)
                    }
                }
            }
            let shape = Shape(rows: rows, columns: columns, frames: frames, samples: 1, bitsAllocated: 16, bitsStored: bitsStored,
                              highBit: highBit, photometric: "PALETTE COLOR", planar: nil)
            func ow(_ words: [UInt16]) -> Data {
                syntax == .explicitVRBigEndian ? Data(words.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }) : littleEndian(words)
            }
            func descriptor(_ tag: Int) -> DicomDataElement {
                .init(tag: tag, vr: .US, value: .unsignedIntegers([UInt(count), UInt(Self.firstMapped), 16]))
            }
            // Segmented (PS3.3 C.7.9.2): the ramps are a one-entry discrete segment followed by one linear segment
            // to the last entry; the step table is two discrete segments.
            func ramp(_ table: [UInt16]) -> [UInt16] { [0, 1, table[0], 1, UInt16(count - 1), table[count - 1]] }
            let segmentedTables = [ramp(red), ramp(green), [0, 32] + Array(blue[0..<32]) + [0, 32] + Array(blue[32...])]
            var extra = [descriptor(0x0028_1101), descriptor(0x0028_1102), descriptor(0x0028_1103)]
            for (offset, table) in [red, green, blue].enumerated() {
                extra.append(segmented
                    ? .init(tag: 0x0028_1221 + offset, vr: .OW, value: .bytes(ow(segmentedTables[offset])))
                    : .init(tag: 0x0028_1201 + offset, vr: .OW, value: .bytes(ow(table))))
            }
            // Noise above the High Bit when Bits Stored is narrower than the container.
            let noise: UInt16 = bitsStored < 16 ? 0xF000 : 0
            let stored = indices.map { $0.map { $0 | noise } }
            data = try DicomDeepColorTypedFrameTests.part10(
                shape: shape, pixelData: Self.nativeWords16(stored, syntax: syntax), syntax: syntax, extra: extra)
        }

        /// PS3.3 C.7.6.3.1.5/C.7.9: index − first mapped, clamped to the table, entry high byte for 8-bit display.
        func expectedRGB8(frame: Int) -> Data {
            var output = Data()
            for index in indices[frame] {
                let entry = min(max(Int(index) - Self.firstMapped, 0), Self.entryCount - 1)
                output.append(contentsOf: [UInt8(red[entry] >> 8), UInt8(green[entry] >> 8), UInt8(blue[entry] >> 8)])
            }
            return output
        }

        private static func nativeWords16(_ frames: [[UInt16]], syntax: DicomTransferSyntax) -> Data {
            Data(frames.joined().flatMap { word -> [UInt8] in
                syntax == .explicitVRBigEndian ? [UInt8(word >> 8), UInt8(word & 0xFF)] : [UInt8(word & 0xFF), UInt8(word >> 8)]
            })
        }
    }

    /// Bits Allocated 1, 3 × 5 pixels per frame (15 bits: every frame after the first starts inside a byte), three
    /// frames, bits packed least significant first (PS3.5 8.1.1).
    struct OneBitFixture {
        let data: Data
        let frames: [[UInt8]]
        let pixels = 15

        init(photometric: String) throws {
            frames = (0..<3).map { frame in (0..<15).map { UInt8(($0 * 3 + frame) % 4 == 0 || $0 == 14 ? 1 : 0) } }
            let bits = frames.joined().map { $0 }
            var packed = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
            for (index, bit) in bits.enumerated() where bit == 1 { packed[index / 8] |= 1 << UInt8(index % 8) }
            let shape = Shape(rows: 3, columns: 5, frames: 3, samples: 1, bitsAllocated: 1, bitsStored: 1, photometric: photometric, planar: nil)
            data = try DicomDeepColorTypedFrameTests.part10(shape: shape, pixelData: Data(packed), syntax: .explicitVRLittleEndian)
        }
    }

    static func physicalFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
