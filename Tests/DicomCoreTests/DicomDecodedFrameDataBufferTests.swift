import Foundation
import XCTest
@testable import DicomCore

final class DicomDecodedFrameDataBufferTests: XCTestCase {
    func test_singleBitNativeFrame_unpacksEightGrayscaleSamples() throws {
        let url = try Self.makeFile(
            frames: [Data([0b1010_0101])],
            rows: 1,
            columns: 8,
            bitsAllocated: 1
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DicomDecodedFrameReader(contentsOf: url)

        let frame = try reader.dataBackedFrame(at: 0)

        XCTAssertEqual(frame.pixels.data, Data([1, 0, 1, 0, 0, 1, 0, 1]))
        XCTAssertEqual(frame.pixels.pixelCount, 8)
        XCTAssertEqual(frame.pixels.componentSampleCount, 8)
        XCTAssertEqual(frame.pixels.bytesPerRow, 8)
        XCTAssertEqual(frame.pixels.format, .gray8NormalizedUnsigned)
    }

    func test_nonByteAlignedSingleBitFrames_unpackFromSharedSourceByte() async throws {
        let url = try Self.makeFile(
            frames: [Data(), Data()],
            rows: 1,
            columns: 3,
            bitsAllocated: 1,
            storedPixelData: Data([0b0011_0101])
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DicomDecodedFrameReader(contentsOf: url)

        let first = try await reader.dataBackedFrame(at: 0)
        let second = try await reader.dataBackedFrame(at: 1)

        XCTAssertEqual(first.pixels.data, Data([1, 0, 1]))
        XCTAssertEqual(second.pixels.data, Data([0, 1, 1]))
    }

    func test_gray8DataBackedFrame_matchesLegacyPixelsAndLayout() throws {
        let expected: [UInt8] = [0, 1, 127, 255]
        let url = try Self.makeFile(frames: [Data(expected)], rows: 2, columns: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DicomDecodedFrameReader(contentsOf: url)

        let dataBacked = try reader.dataBackedFrame(at: 0)
        let legacy = try reader.frame(at: 0)

        XCTAssertEqual(dataBacked.pixels.copyingToArrayBackedPixels(), legacy.pixels)
        XCTAssertEqual(dataBacked.pixels.data, Data(expected))
        XCTAssertEqual(dataBacked.pixels.format, .gray8NormalizedUnsigned)
        XCTAssertEqual(dataBacked.pixels.byteOrder, .notApplicable)
        XCTAssertEqual(dataBacked.pixels.ownership, .ownedData)
        XCTAssertEqual(dataBacked.pixels.pixelCount, 4)
        XCTAssertEqual(dataBacked.pixels.componentSampleCount, 4)
        XCTAssertEqual(dataBacked.pixels.data.count, 4)
        XCTAssertEqual(dataBacked.pixels.bytesPerRow, 2)
        XCTAssertNil(dataBacked.pixels.baseAddressAlignment)
    }

    func test_unsignedGray16DataBackedFrame_preservesLittleEndianValues() throws {
        let expected: [UInt16] = [0, 32_767, 32_768, 65_535]
        let expectedBytes = Self.littleEndianData(expected)
        let url = try Self.makeFile(
            frames: [expectedBytes],
            rows: 2,
            columns: 2,
            bitsAllocated: 16
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DicomDecodedFrameReader(contentsOf: url)

        let dataBacked = try reader.dataBackedFrame(at: 0)

        XCTAssertEqual(dataBacked.pixels.data, expectedBytes)
        XCTAssertEqual(dataBacked.pixels.format, .gray16NormalizedUnsigned)
        XCTAssertEqual(dataBacked.pixels.byteOrder, .littleEndian)
        XCTAssertEqual(dataBacked.pixels.ownership, .ownedData)
        XCTAssertEqual(dataBacked.pixels.pixelCount, 4)
        XCTAssertEqual(dataBacked.pixels.componentSampleCount, 4)
        XCTAssertEqual(dataBacked.pixels.data.count, 8)
        XCTAssertEqual(dataBacked.pixels.bytesPerRow, 4)
        XCTAssertNil(dataBacked.pixels.baseAddressAlignment)
        XCTAssertEqual(dataBacked.pixels.copyingToArrayBackedPixels(), .gray16(expected))
        XCTAssertEqual(try reader.frame(at: 0).pixels, .gray16(expected))
    }

    func test_bigEndianGray16DataBackedFrame_normalizesToLittleEndian() throws {
        let expected: [UInt16] = [0x0102, 0x7FFF, 0x8000, 0xFEDC]
        let url = try Self.makeFile(
            frames: [Self.bigEndianData(expected)],
            rows: 2,
            columns: 2,
            bitsAllocated: 16,
            transferSyntax: .explicitVRBigEndian
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DicomDecodedFrameReader(contentsOf: url)

        let dataBacked = try reader.dataBackedFrame(at: 0)

        XCTAssertEqual(dataBacked.pixels.data, Self.littleEndianData(expected))
        XCTAssertEqual(dataBacked.pixels.byteOrder, .littleEndian)
        XCTAssertEqual(dataBacked.pixels.ownership, .ownedData)
        XCTAssertEqual(dataBacked.pixels.copyingToArrayBackedPixels(), .gray16(expected))
        XCTAssertEqual(try reader.frame(at: 0).pixels, .gray16(expected))
    }

    func test_signedGray16DataBackedFrame_matchesLegacyNormalization() throws {
        let stored: [Int16] = [.min, -1_024, 0, .max]
        let url = try Self.makeFile(
            frames: [Self.littleEndianData(stored.map { UInt16(bitPattern: $0) })],
            rows: 2,
            columns: 2,
            bitsAllocated: 16,
            pixelRepresentation: 1
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DicomDecodedFrameReader(contentsOf: url)
        let expected: [UInt16] = [0, 31_744, 32_768, 65_535]

        let dataBacked = try reader.dataBackedFrame(at: 0)

        XCTAssertEqual(dataBacked.pixels.copyingToArrayBackedPixels(), .gray16(expected))
        XCTAssertEqual(try reader.frame(at: 0).pixels, .gray16(expected))
        XCTAssertEqual(dataBacked.pixels.format, .gray16NormalizedUnsigned)
        XCTAssertEqual(dataBacked.pixels.byteOrder, .littleEndian)
        XCTAssertEqual(dataBacked.pixels.pixelCount, expected.count)
        XCTAssertEqual(dataBacked.pixels.componentSampleCount, expected.count)
        XCTAssertEqual(dataBacked.pixels.data.count, expected.count * MemoryLayout<UInt16>.size)
    }

    func test_monochrome1DataBackedFrame_matchesLegacyInversion() throws {
        let url = try Self.makeFile(
            frames: [Data([0, 127, 255, 64])],
            rows: 2,
            columns: 2,
            photometricInterpretation: "MONOCHROME1"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DicomDecodedFrameReader(contentsOf: url)
        let expected: [UInt8] = [255, 128, 0, 191]

        let dataBacked = try reader.dataBackedFrame(at: 0)

        XCTAssertEqual(dataBacked.pixels.data, Data(expected))
        XCTAssertEqual(dataBacked.pixels.copyingToArrayBackedPixels(), .gray8(expected))
        XCTAssertEqual(try reader.frame(at: 0).pixels, .gray8(expected))
    }

    func test_rgb8DataBackedFrame_preservesInterleavedComponentOrder() throws {
        let expected: [UInt8] = [255, 0, 32, 0, 128, 64]
        let url = try Self.makeFile(
            frames: [Data(expected)],
            rows: 1,
            columns: 2,
            samplesPerPixel: 3,
            photometricInterpretation: "RGB",
            planarConfiguration: 0
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DicomDecodedFrameReader(contentsOf: url)

        let dataBacked = try reader.dataBackedFrame(at: 0)

        XCTAssertEqual(dataBacked.pixels.data, Data(expected))
        XCTAssertEqual(dataBacked.pixels.format, .rgb8Interleaved)
        XCTAssertEqual(dataBacked.pixels.byteOrder, .notApplicable)
        XCTAssertEqual(dataBacked.pixels.pixelCount, 2)
        XCTAssertEqual(dataBacked.pixels.componentSampleCount, 6)
        XCTAssertEqual(dataBacked.pixels.data.count, 6)
        XCTAssertEqual(dataBacked.pixels.bytesPerRow, 6)
        XCTAssertEqual(dataBacked.pixels.copyingToArrayBackedPixels(), .rgb8(interleaved: expected))
        XCTAssertEqual(try reader.frame(at: 0).pixels, .rgb8(interleaved: expected))
    }

    func test_jpeg2000DataBackedFrame_matchesForcedBackendArrayPixels() async throws {
        let width = 16
        let height = 16
        let values = (0..<(width * height)).map { UInt16(truncatingIfNeeded: $0 * 257 + 31) }
        let expectedBytes = Self.littleEndianData(values)
        let descriptor = DicomCompressedFrameDescriptor(
            transferSyntaxUID: DicomTransferSyntax.jpeg2000Lossless.rawValue,
            rows: height,
            columns: width,
            bitsAllocated: 16,
            bitsStored: 16,
            highBit: 15,
            pixelRepresentation: 0,
            samplesPerPixel: 1,
            photometricInterpretation: "MONOCHROME2",
            planarConfiguration: nil
        )
        let source = DicomCodecDecodedFrame(
            buffer: .owned(expectedBytes),
            width: width,
            height: height,
            bitsPerSample: 16,
            componentCount: 1
        )
        let encoded = try await DicomJ2KSwiftBackend().encode(DicomFrameEncodeRequest(
            frame: source,
            descriptor: descriptor,
            targetTransferSyntaxUID: descriptor.transferSyntaxUID
        ))
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpeg2000Lossless,
            fragments: [encoded],
            declaredFrames: 1,
            rows: height,
            columns: width,
            bitsAllocated: 16,
            bitsStored: 16,
            highBit: 15
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("data-backed-jpeg2000-\(UUID().uuidString).dcm")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DicomDecodedFrameReader(contentsOf: url)
        let environment = [
            DicomJ2KSwiftRolloutMode.environmentKey: DicomJ2KSwiftRolloutMode.forcedForTests.rawValue
        ]

        let dataBacked = try await reader.dataBackedFrame(at: 0, environment: environment)
        let legacy = try await reader.frameExecution(at: 0, environment: environment).frame

        XCTAssertEqual(dataBacked.pixels.data, expectedBytes)
        XCTAssertEqual(dataBacked.pixels.ownership, .ownedData)
        XCTAssertEqual(dataBacked.pixels.copyingToArrayBackedPixels(), legacy.pixels)
    }

    func test_jpegXLDataBackedFrame_preservesExperimentalAsyncRoute() async throws {
        let width = 16
        let height = 16
        let expected = Data((0..<(width * height)).map { UInt8(truncatingIfNeeded: $0 * 17 + 3) })
        let descriptor = DicomCompressedFrameDescriptor(
            transferSyntaxUID: DicomTransferSyntax.jpegXLLossless.rawValue,
            rows: height,
            columns: width,
            bitsAllocated: 8,
            bitsStored: 8,
            highBit: 7,
            pixelRepresentation: 0,
            samplesPerPixel: 1,
            photometricInterpretation: "MONOCHROME2",
            planarConfiguration: nil
        )
        let source = DicomCodecDecodedFrame(
            buffer: .owned(expected),
            width: width,
            height: height,
            bitsPerSample: 8,
            componentCount: 1
        )
        let encoded = try await DicomJXLSwiftBackend().encode(DicomFrameEncodeRequest(
            frame: source,
            descriptor: descriptor,
            targetTransferSyntaxUID: descriptor.transferSyntaxUID
        ))
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpegXLLossless,
            fragments: [encoded],
            declaredFrames: 1,
            rows: height,
            columns: width,
            bitsAllocated: 8,
            bitsStored: 8,
            highBit: 7
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("data-backed-jpegxl-\(UUID().uuidString).dcm")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DicomDecodedFrameReader(contentsOf: url)
        let environment = [
            DicomJXLSwiftRolloutMode.environmentKey: DicomJXLSwiftRolloutMode.forcedForTests.rawValue
        ]

        let dataBacked = try await reader.dataBackedFrame(at: 0, environment: environment)
        let legacy = try await reader.frameExecution(at: 0, environment: environment).frame

        XCTAssertEqual(dataBacked.pixels.data, expected)
        XCTAssertEqual(dataBacked.pixels.ownership, .ownedData)
        XCTAssertEqual(dataBacked.pixels.copyingToArrayBackedPixels(), legacy.pixels)
    }

    func test_dataBackedBuffer_outlivesReaderAndSourceFile() throws {
        let expected = Data([10, 20, 30, 40])
        let captured: DicomDataBackedDecodedFrame = try {
            let url = try Self.makeFile(frames: [expected], rows: 2, columns: 2)
            let reader = try DicomDecodedFrameReader(contentsOf: url)
            let frame = try reader.dataBackedFrame(at: 0)
            try FileManager.default.removeItem(at: url)
            return frame
        }()

        XCTAssertEqual(captured.pixels.data, expected)
        XCTAssertEqual(captured.pixels.copyingToArrayBackedPixels(), .gray8([10, 20, 30, 40]))
        XCTAssertEqual(try captured.copyingToArrayBackedFrame().pixels, .gray8([10, 20, 30, 40]))
    }

    func test_legacyPixelEnum_remainsExhaustiveAndUnchanged() throws {
        let cases: [DicomDecodedFramePixelBuffer] = [
            .gray8([1]),
            .gray16([2]),
            .rgb8(interleaved: [3, 4, 5])
        ]

        XCTAssertEqual(cases.map(Self.legacyCaseName), ["gray8", "gray16", "rgb8"])
        XCTAssertEqual(cases.map(\.sampleCount), [1, 1, 1])
    }

    func test_dataNormalizer_rejectsOverflowAndInconsistentLayouts() {
        XCTAssertNil(DicomDecodedFrameDataNormalizer.makeBuffer(
            data: Data(),
            width: Int.max,
            height: 2,
            bitsPerSample: 16,
            bitsStored: 16,
            highBit: 15,
            componentCount: 1,
            pixelRepresentation: 0,
            photometricInterpretation: "MONOCHROME2",
            sourceByteOrder: .littleEndian,
            ownership: .ownedData
        ))
        XCTAssertNil(DicomDecodedFrameDataNormalizer.makeBuffer(
            data: Data([1, 2, 3]),
            width: 2,
            height: 2,
            bitsPerSample: 8,
            bitsStored: 8,
            highBit: 7,
            componentCount: 1,
            pixelRepresentation: 0,
            photometricInterpretation: "MONOCHROME2",
            sourceByteOrder: .notApplicable,
            ownership: .ownedData
        ))
        XCTAssertNil(DicomDecodedFrameDataNormalizer.makeBuffer(
            data: Data(),
            width: 1,
            height: 1,
            bitsPerSample: 0,
            bitsStored: 0,
            highBit: 0,
            componentCount: 1,
            pixelRepresentation: 0,
            photometricInterpretation: "MONOCHROME2",
            sourceByteOrder: .notApplicable,
            ownership: .ownedData
        ))
    }

    func test_signed12BitMonochrome1_normalizesWithinStoredBitRange() throws {
        let input = Self.littleEndianData([0x0800, 0x0FFF, 0x0000, 0x07FF])

        let buffer = try XCTUnwrap(DicomDecodedFrameDataNormalizer.makeBuffer(
            data: input,
            width: 4,
            height: 1,
            bitsPerSample: 16,
            bitsStored: 12,
            highBit: 11,
            componentCount: 1,
            pixelRepresentation: 1,
            photometricInterpretation: "MONOCHROME1",
            sourceByteOrder: .littleEndian,
            ownership: .ownedData
        ))

        XCTAssertEqual(buffer.copyingToArrayBackedPixels(), .gray16([4_095, 2_048, 2_047, 0]))
    }

    func test_dataBackedFrames_deliversMultiframeInOrderOnePullAtATime() async throws {
        let expected = [
            Data([1, 2, 3, 4]),
            Data([5, 6, 7, 8]),
            Data([9, 10, 11, 12])
        ]
        let url = try Self.makeFile(frames: expected, rows: 2, columns: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DicomDecodedFrameReader(contentsOf: url)
        var iterator = reader.dataBackedFrames().makeAsyncIterator()

        let firstValue = try await iterator.next()
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.index, 0)
        XCTAssertEqual(first.pixels.data, expected[0])
        let secondValue = try await iterator.next()
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(second.index, 1)
        XCTAssertEqual(second.pixels.data, expected[1])
        let thirdValue = try await iterator.next()
        let third = try XCTUnwrap(thirdValue)
        XCTAssertEqual(third.index, 2)
        XCTAssertEqual(third.pixels.data, expected[2])
        let end = try await iterator.next()
        XCTAssertNil(end)
    }

    func test_asyncDataBackedFrame_honorsPreexistingCancellation() async throws {
        let url = try Self.makeFile(frames: [Data([1, 2, 3, 4])], rows: 2, columns: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DicomDecodedFrameReader(contentsOf: url)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.dataBackedFrame(at: 0)
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation before decode")
        } catch is CancellationError {
            // Expected.
        }
    }

    func test_cancellableDetachedFallback_cancelAfterDecodeBeginsReturnsPromptly() async {
        let decodeStarted = expectation(description: "synchronous fallback started")
        let cancellationReturned = expectation(description: "caller returned cancellation")
        let releaseDecode = DispatchSemaphore(value: 0)
        defer { releaseDecode.signal() }
        let task = Task {
            try await DicomCancellableDetachedOperation.run {
                decodeStarted.fulfill()
                releaseDecode.wait()
                return 1
            }
        }
        await fulfillment(of: [decodeStarted], timeout: 1)

        task.cancel()
        let cancellationObservation = Task {
            do {
                _ = try await task.value
            } catch is CancellationError {
                cancellationReturned.fulfill()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        await fulfillment(of: [cancellationReturned], timeout: 1)
        await cancellationObservation.value
    }

    func test_dataBackedFrames_honorsCancellationBeforeNextPull() async throws {
        let url = try Self.makeFile(
            frames: [Data([1, 2, 3, 4]), Data([5, 6, 7, 8])],
            rows: 2,
            columns: 2
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DicomDecodedFrameReader(contentsOf: url)
        let task = Task {
            var iterator = reader.dataBackedFrames().makeAsyncIterator()
            _ = try await iterator.next()
            withUnsafeCurrentTask { $0?.cancel() }
            return try await iterator.next()
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation before the second pull")
        } catch is CancellationError {
            // Expected.
        }
    }

    #if os(macOS)
    func test_dataBackedFrames_slowConsumerDoesNotMaterializeWholeMultiframe() async throws {
        let frameByteCount = 512 * 512
        let frameCount = 96
        let frames = (0..<frameCount).map { index in
            Data(repeating: UInt8(index % 251), count: frameByteCount)
        }
        let url = try Self.makeFile(frames: frames, rows: 512, columns: 512)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DicomDecodedFrameReader(contentsOf: url)
        var iterator = reader.dataBackedFrames().makeAsyncIterator()
        let firstValue = try await iterator.next()
        let first = try XCTUnwrap(firstValue)
        let secondValue = try await iterator.next()
        let second = try XCTUnwrap(secondValue)

        XCTAssertEqual(first.pixels.data.count, frameByteCount)
        XCTAssertEqual(second.pixels.data.count, frameByteCount)
        XCTAssertEqual(first.pixels.data.count + second.pixels.data.count, 2 * frameByteCount)
        XCTAssertEqual(first.index, 0)
        XCTAssertEqual(second.index, 1)
    }
    #endif

    private static func legacyCaseName(_ pixels: DicomDecodedFramePixelBuffer) -> String {
        switch pixels {
        case .gray8: return "gray8"
        case .gray16: return "gray16"
        case .rgb8: return "rgb8"
        }
    }

    private static func makeFile(
        frames: [Data],
        rows: Int,
        columns: Int,
        bitsAllocated: Int = 8,
        pixelRepresentation: Int = 0,
        samplesPerPixel: Int = 1,
        photometricInterpretation: String = "MONOCHROME2",
        planarConfiguration: Int? = nil,
        transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian,
        storedPixelData: Data? = nil
    ) throws -> URL {
        precondition(!frames.isEmpty)
        var pixelData = storedPixelData ?? frames.reduce(into: Data()) { $0.append($1) }
        if pixelData.count % 2 != 0 {
            pixelData.append(0)
        }
        var elements = [
            DicomDataElement(
                tag: DicomTag.sopClassUID.rawValue,
                vr: .UI,
                value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])
            ),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.20930001"])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US,
                             value: .unsignedIntegers([UInt(samplesPerPixel)])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS,
                             value: .strings([photometricInterpretation])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([UInt(rows)])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([UInt(columns)])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US,
                             value: .unsignedIntegers([UInt(bitsAllocated)])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US,
                             value: .unsignedIntegers([UInt(bitsAllocated)])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US,
                             value: .unsignedIntegers([UInt(bitsAllocated - 1)])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US,
                             value: .unsignedIntegers([UInt(pixelRepresentation)]))
        ]
        if let planarConfiguration {
            elements.append(DicomDataElement(
                tag: DicomTag.planarConfiguration.rawValue,
                vr: .US,
                value: .unsignedIntegers([UInt(planarConfiguration)])
            ))
        }
        if frames.count > 1 {
            elements.append(DicomDataElement(
                tag: DicomTag.numberOfFrames.rawValue,
                vr: .IS,
                value: .strings([String(frames.count)])
            ))
        }
        elements.append(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(pixelData)))

        let data = try DicomDataSetWriter.part10Data(
            from: DicomDataSet(elements: elements),
            options: DicomPart10WriterOptions(
                transferSyntax: transferSyntax,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.20930001"
            )
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("data-backed-decoded-frame-\(UUID().uuidString).dcm")
        try data.write(to: url)
        return url
    }

    private static func littleEndianData(_ values: [UInt16]) -> Data {
        values.reduce(into: Data()) { data, value in
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
    }

    private static func bigEndianData(_ values: [UInt16]) -> Data {
        values.reduce(into: Data()) { data, value in
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }
    }

}
