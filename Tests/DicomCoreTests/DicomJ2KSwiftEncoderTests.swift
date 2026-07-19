import Foundation
import DicomTestSupport
import XCTest
@testable import DicomCore

final class DicomJ2KSwiftEncoderTests: XCTestCase {
    func test_capabilitiesAdvertiseExactEncodeUIDsWithoutQualifyingHTDecode() {
        let capabilities = DicomJ2KSwiftBackend().capabilities
        XCTAssertEqual(capabilities.operations, [.decode, .encode])
        XCTAssertEqual(capabilities.transferSyntaxUIDs, DicomJ2KSwiftBackend.qualifiedTransferSyntaxes)
        XCTAssertEqual(capabilities.encodeTransferSyntaxUIDs, DicomJ2KSwiftBackend.allFrameTransferSyntaxes)
        XCTAssertFalse(capabilities.transferSyntaxUIDs.contains(DicomTransferSyntax.htj2kLossless.rawValue))
        XCTAssertTrue(capabilities.encodeTransferSyntaxUIDs.contains(DicomTransferSyntax.htj2kLossless.rawValue))
    }

    func test_losslessGrayscalePrecisionSignednessAndTilingRoundTripThroughOpenJPEG() async throws {
        try DicomTestRuntimePreflight.require(.openJPEG)
        for bitDepth in [8, 10, 12, 14, 16] {
            for signed in [false, true] {
                for tileSize: (width: Int, height: Int)? in [nil, (19, 17)] {
                    let bytes = Self.grayscaleBytes(
                        width: 37,
                        height: 29,
                        bitDepth: bitDepth,
                        signed: signed,
                        seed: bitDepth
                    )
                    let request = Self.encodeRequest(
                        bytes: bytes,
                        width: 37,
                        height: 29,
                        bitsStored: bitDepth,
                        signed: signed,
                        destination: .jpeg2000Lossless,
                        intent: .reversible,
                        tileSize: tileSize
                    )

                    let encoded = try await DicomJ2KSwiftBackend().encode(request)
                    let decoded = try await Self.decodeWithOpenJPEG(encoded, descriptor: request.descriptor)
                    XCTAssertEqual(
                        decoded.buffer.data,
                        bytes,
                        "bitDepth=\(bitDepth), signed=\(signed), tiled=\(tileSize != nil)"
                    )
                }
            }
        }
    }

    func test_losslessHTJ2KUIDsCrossDecodeExactlyThroughOpenJPEG() async throws {
        try HTJ2KDecodeTests.skipUnlessHTJ2KSupported()
        let bytes = Self.grayscaleBytes(width: 37, height: 29, bitDepth: 12, signed: true, seed: 91)
        for destination in [
            DicomTransferSyntax.htj2kLossless,
            .htj2kLosslessRPCL,
            .htj2k
        ] {
            let request = Self.encodeRequest(
                bytes: bytes,
                width: 37,
                height: 29,
                bitsStored: 12,
                signed: true,
                destination: destination,
                intent: .reversible,
                tileSize: (19, 17)
            )
            let encoded = try await DicomJ2KSwiftBackend().encode(request)
            XCTAssertEqual(
                try Self.codestreamProgressionOrder(encoded),
                destination == .htj2kLosslessRPCL ? 2 : 0,
                destination.rawValue
            )
            let decoded = try await Self.decodeWithOpenJPEG(encoded, descriptor: request.descriptor)
            XCTAssertEqual(decoded.buffer.data, bytes, destination.rawValue)
        }
    }

    func test_everyQualifiedDestinationWritesItsExactTransferSyntaxUID() async throws {
        try DicomTestRuntimePreflight.require(.openJPEG)
        let bytes = Self.grayscaleBytes(width: 7, height: 5, bitDepth: 12, signed: false, seed: 23)
        let source = try Self.makeNativeFile(
            frames: [bytes],
            rows: 5,
            columns: 7,
            bitsAllocated: 16,
            bitsStored: 12
        )
        for destination in [
            DicomTransferSyntax.jpeg2000Lossless,
            .jpeg2000,
            .htj2kLossless,
            .htj2kLosslessRPCL,
            .htj2k
        ] {
            let output = try await DicomTranscoder().transcode(
                source,
                to: destination,
                intent: .reversible
            )
            let decoder = try DCMDecoder(data: output)
            XCTAssertEqual(decoder.info(for: .transferSyntaxUID), destination.rawValue)
            XCTAssertNotNil(try decoder.makeEncapsulatedPixelFrameReader())
        }
    }

    func test_irreversibleHTJ2KGeneralUIDCrossDecodesWithBoundedError() async throws {
        try HTJ2KDecodeTests.skipUnlessHTJ2KSupported()
        let source = Self.grayscaleBytes(width: 37, height: 29, bitDepth: 8, signed: false, seed: 63)
        let request = Self.encodeRequest(
            bytes: source,
            width: 37,
            height: 29,
            bitsStored: 8,
            signed: false,
            destination: .htj2k,
            intent: .irreversible(quality: 0.9),
            tileSize: nil
        )
        let encoded = try await DicomJ2KSwiftBackend().encode(request)
        let decoded = try await Self.decodeWithOpenJPEG(encoded, descriptor: request.descriptor)
        XCTAssertEqual(decoded.width, 37)
        XCTAssertEqual(decoded.height, 29)
        XCTAssertEqual(decoded.bitsPerSample, 8)
        XCTAssertGreaterThan(Self.psnr(reference: source, candidate: decoded.buffer.data), 25)
    }

    func test_losslessRGBPlanarAndInterleavedSourcesPreserveComponentOrder() async throws {
        try DicomTestRuntimePreflight.require(.openJPEG)
        let width = 11
        let height = 7
        let pixelCount = width * height
        var planes: [Data] = []
        for component in 0..<3 {
            var plane = Data(capacity: pixelCount)
            for pixel in 0..<pixelCount {
                plane.append(UInt8((pixel * (component + 3) + component * 29) % 251))
            }
            planes.append(plane)
        }
        var interleaved = Data(capacity: pixelCount * 3)
        for pixel in 0..<pixelCount {
            for component in 0..<3 {
                interleaved.append(planes[component][pixel])
            }
        }
        let planar = planes.reduce(into: Data()) { $0.append($1) }

        for (bytes, configuration) in [(interleaved, 0), (planar, 1)] {
            let source = try Self.makeNativeFile(
                frames: [bytes],
                rows: height,
                columns: width,
                bitsAllocated: 8,
                bitsStored: 8,
                samplesPerPixel: 3,
                photometricInterpretation: "RGB",
                planarConfiguration: configuration
            )
            let compressed = try await DicomTranscoder().transcode(
                source,
                to: .jpeg2000Lossless,
                intent: .reversible
            )
            let frame = try await DicomDecodedFrameReader(decoder: DCMDecoder(data: compressed)).frame(at: 0)
            guard case .rgb8(let decoded) = frame.pixels else {
                return XCTFail("Expected RGB output for planar configuration \(configuration)")
            }
            XCTAssertEqual(Data(decoded), interleaved, "planarConfiguration=\(configuration)")
        }
    }

    func test_losslessRGBOutputCanRecompressThroughAnotherJ2KSyntax() async throws {
        try HTJ2KDecodeTests.skipUnlessHTJ2KSupported()
        let width = 11
        let height = 7
        var bytes = Data(capacity: width * height * 3)
        for index in 0..<(width * height) {
            bytes.append(UInt8((index * 3) % 251))
            bytes.append(UInt8((index * 5 + 17) % 251))
            bytes.append(UInt8((index * 7 + 43) % 251))
        }
        let source = try Self.makeNativeFile(
            frames: [bytes],
            rows: height,
            columns: width,
            bitsAllocated: 8,
            bitsStored: 8,
            samplesPerPixel: 3,
            photometricInterpretation: "RGB"
        )
        let jpeg2000 = try await DicomTranscoder().transcode(
            source,
            to: .jpeg2000Lossless,
            intent: .reversible
        )
        let htj2k = try await DicomTranscoder().transcode(
            jpeg2000,
            to: .htj2kLosslessRPCL,
            intent: .reversible
        )
        let decoder = try DCMDecoder(data: htj2k)
        let encapsulated = try decoder.makeEncapsulatedPixelFrameReader()
        XCTAssertEqual(try Self.codestreamProgressionOrder(encapsulated.frame(at: 0).data), 2)
        let frame = try await DicomDecodedFrameReader(decoder: decoder).frame(at: 0)
        guard case .rgb8(let decoded) = frame.pixels else {
            return XCTFail("Expected RGB output")
        }
        XCTAssertEqual(Data(decoded), bytes)
    }

    func test_multiframeTranscodeWritesBOTAndRoundTripsStoredPixels() async throws {
        try DicomTestRuntimePreflight.require(.openJPEG)
        let frames = [17, 31].map {
            Self.grayscaleBytes(width: 5, height: 3, bitDepth: 16, signed: true, seed: $0)
        }
        let source = try Self.makeNativeFile(
            frames: frames,
            rows: 3,
            columns: 5,
            bitsAllocated: 16,
            bitsStored: 16,
            signed: true
        )

        let compressed = try await DicomTranscoder().transcode(
            source,
            to: .jpeg2000Lossless,
            intent: .reversible
        )
        let compressedDecoder = try DCMDecoder(data: compressed)
        XCTAssertEqual(
            compressedDecoder.info(for: .transferSyntaxUID),
            DicomTransferSyntax.jpeg2000Lossless.rawValue
        )
        XCTAssertEqual(compressedDecoder.info(for: .patientName), "ENCODE^PARITY")
        let encapsulated = try compressedDecoder.makeEncapsulatedPixelFrameReader()
        XCTAssertEqual(encapsulated.frameCount, 2)
        XCTAssertEqual(encapsulated.descriptor.basicOffsetTable.offsets.count, 2)
        XCTAssertNil(encapsulated.descriptor.extendedOffsetTable)
        XCTAssertTrue(encapsulated.descriptor.fragments.allSatisfy { $0.length.isMultiple(of: 2) })

        let roundTrip = try DicomTranscoder().transcode(compressed, to: .explicitVRLittleEndian)
        let roundTripDecoder = try DCMDecoder(data: roundTrip)
        XCTAssertEqual(roundTripDecoder.getAllFrames()?.map(\.data), frames)
    }

    func test_encapsulationPadsOddFragmentsAndCanEmitExtendedOffsets() throws {
        let encapsulation = try DicomTranscoder.encapsulate(
            fragments: [Data([0x01]), Data([0x02, 0x03, 0x04])],
            forceExtendedOffsets: true
        )
        let descriptor = try DicomEncapsulatedPixelDataParser().parse(
            data: encapsulation.pixelData,
            pixelDataOffset: 0,
            numberOfFrames: 2,
            extendedOffsetTableData: encapsulation.extendedOffsetTable,
            extendedOffsetTableLengthsData: encapsulation.extendedOffsetTableLengths
        )

        XCTAssertEqual(descriptor.basicOffsetTable.offsets, [])
        XCTAssertEqual(descriptor.extendedOffsetTable?.offsets, [0, 10])
        XCTAssertEqual(descriptor.extendedOffsetTable?.lengths, [2, 4])
        XCTAssertEqual(descriptor.fragments.map(\.length), [2, 4])
        XCTAssertEqual(descriptor.frameFragmentIndexes.map(\.count), [1, 1])
    }

    func test_compressedSourceRecompressesThroughSharedJ2KTranscoder() async throws {
        try DicomTestRuntimePreflight.require(.openJPEG)
        let stored = (0..<16).map { ($0 * 101 + 7) % 4096 }
        let codestream = makeJPEGLosslessStream(
            planes: [stored],
            width: 4,
            height: 4,
            precision: 12
        )
        let source = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpegLosslessFirstOrder,
            fragments: [codestream],
            declaredFrames: 1,
            rows: 4,
            columns: 4,
            bitsAllocated: 16,
            bitsStored: 12,
            highBit: 11
        )

        let compressed = try await DicomTranscoder().transcode(
            source,
            to: .jpeg2000Lossless,
            intent: .reversible
        )
        let native = try DicomTranscoder().transcode(compressed, to: .explicitVRLittleEndian)
        let decoder = try DCMDecoder(data: native)
        XCTAssertEqual(decoder.getAllFrames()?.first?.data, Self.littleEndianBytes(stored.map(UInt16.init)))
    }

    func test_irreversibleRGBTranscodeSetsDeterministicLossyMetadata() async throws {
        try DicomTestRuntimePreflight.require(.openJPEG)
        let width = 31
        let height = 23
        var bytes = Data(capacity: width * height * 3)
        for index in 0..<(width * height) {
            bytes.append(UInt8((index * 3) % 251))
            bytes.append(UInt8((index * 5 + 17) % 251))
            bytes.append(UInt8((index * 7 + 43) % 251))
        }
        let source = try Self.makeNativeFile(
            frames: [bytes],
            rows: height,
            columns: width,
            bitsAllocated: 8,
            bitsStored: 8,
            samplesPerPixel: 3,
            photometricInterpretation: "RGB",
            imageType: ["ORIGINAL", "PRIMARY"],
            derivationDescription: "Prior processing"
        )

        let compressed = try await DicomTranscoder().transcode(
            source,
            to: .jpeg2000,
            intent: .irreversible(quality: 0.85)
        )
        let decoder = try DCMDecoder(data: compressed)
        let derivedSOPInstanceUID = decoder.info(for: DicomTag.sopInstanceUID)
        XCTAssertTrue(derivedSOPInstanceUID.hasPrefix("2.25."))
        XCTAssertNotEqual(derivedSOPInstanceUID, "2.25.12260001")
        XCTAssertEqual(decoder.info(for: 0x00020003), derivedSOPInstanceUID)
        XCTAssertEqual(decoder.photometricInterpretation, "YBR_ICT")
        XCTAssertEqual(decoder.intValue(for: DicomTag.planarConfiguration), 0)
        XCTAssertEqual(decoder.dataSet.strings(for: DicomTag.imageType), ["DERIVED", "PRIMARY"])
        XCTAssertEqual(decoder.info(for: DicomTag.lossyImageCompression), "01")
        XCTAssertEqual(
            decoder.dataSet.strings(for: DicomTag.lossyImageCompressionMethod),
            ["ISO_15444_1"]
        )
        XCTAssertGreaterThan(
            Double(try XCTUnwrap(decoder.info(for: DicomTag.lossyImageCompressionRatio))) ?? 0,
            0
        )
        XCTAssertTrue(
            decoder.info(for: DicomTag.derivationDescription).contains("Prior processing")
        )
        XCTAssertTrue(
            decoder.info(for: DicomTag.derivationDescription).contains("Irreversible JPEG 2000")
        )

        let frame = try await DicomDecodedFrameReader(decoder: decoder).frame(at: 0)
        guard case .rgb8(let decoded) = frame.pixels else {
            return XCTFail("Expected decoded RGB pixels")
        }
        XCTAssertEqual(decoded.count, bytes.count)
    }

    func test_reversibleTranscodePreservesExistingLossyHistory() async throws {
        try DicomTestRuntimePreflight.require(.openJPEG)
        let bytes = Self.grayscaleBytes(width: 7, height: 5, bitDepth: 8, signed: false, seed: 12)
        let source = try Self.makeNativeFile(
            frames: [bytes],
            rows: 5,
            columns: 7,
            bitsAllocated: 8,
            bitsStored: 8,
            lossyRatio: "2.5",
            lossyMethod: "ISO_10918_1"
        )

        let compressed = try await DicomTranscoder().transcode(
            source,
            to: .jpeg2000Lossless,
            intent: .reversible
        )
        let decoder = try DCMDecoder(data: compressed)
        XCTAssertEqual(decoder.info(for: .lossyImageCompression), "01")
        XCTAssertEqual(decoder.dataSet.strings(for: .lossyImageCompressionRatio), ["2.5"])
        XCTAssertEqual(decoder.dataSet.strings(for: .lossyImageCompressionMethod), ["ISO_10918_1"])
    }

    func test_unsupportedIntentAndPixelShapeFailTypedBeforeOutputExists() async throws {
        let grayscale = Self.grayscaleBytes(width: 3, height: 3, bitDepth: 8, signed: false, seed: 4)
        let source = try Self.makeNativeFile(
            frames: [grayscale],
            rows: 3,
            columns: 3,
            bitsAllocated: 8,
            bitsStored: 8
        )
        do {
            _ = try await DicomTranscoder().transcode(
                source,
                to: .jpeg2000Lossless,
                intent: .irreversible(quality: 0.8)
            )
            XCTFail("Expected lossless-only destination rejection")
        } catch let error as DicomTranscoder.TranscodeError {
            guard case .unsupportedPixelShape(let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("lossless-only"))
        }

        do {
            _ = try await DicomTranscoder().transcode(
                source,
                to: .jpeg2000,
                intent: .irreversible(quality: .nan)
            )
            XCTFail("Expected invalid quality rejection")
        } catch let error as DicomTranscoder.TranscodeError {
            guard case .unsupportedPixelShape(let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("finite"))
        }

        let emptyShapeRequest = Self.encodeRequest(
            bytes: Data(),
            width: 0,
            height: 3,
            bitsStored: 8,
            signed: false,
            destination: .jpeg2000Lossless,
            intent: .reversible,
            tileSize: nil
        )
        do {
            _ = try await DicomJ2KSwiftBackend().encode(emptyShapeRequest)
            XCTFail("Expected empty shape rejection")
        } catch let error as DicomJ2KSwiftBackendError {
            guard case .unsupportedShape(_, let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("positive"))
        }

        let highBitSource = try Self.makeNativeFile(
            frames: [Self.grayscaleBytes(width: 3, height: 3, bitDepth: 12, signed: false, seed: 8)],
            rows: 3,
            columns: 3,
            bitsAllocated: 16,
            bitsStored: 12,
            highBit: 15
        )
        do {
            _ = try await DicomTranscoder().transcode(
                highBitSource,
                to: .jpeg2000Lossless,
                intent: .reversible
            )
            XCTFail("Expected unaligned High Bit rejection")
        } catch let error as DicomTranscoder.TranscodeError {
            guard case .unsupportedPixelShape(let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("aligned"))
        }
    }

    private static func encodeRequest(
        bytes: Data,
        width: Int,
        height: Int,
        bitsStored: Int,
        signed: Bool,
        destination: DicomTransferSyntax,
        intent: DicomEncodingIntent,
        tileSize: (width: Int, height: Int)?
    ) -> DicomFrameEncodeRequest {
        let descriptor = DicomCompressedFrameDescriptor(
            transferSyntaxUID: destination.rawValue,
            rows: height,
            columns: width,
            bitsAllocated: bitsStored <= 8 ? 8 : 16,
            bitsStored: bitsStored,
            highBit: bitsStored - 1,
            pixelRepresentation: signed ? 1 : 0,
            samplesPerPixel: 1,
            photometricInterpretation: "MONOCHROME2",
            planarConfiguration: nil
        )
        return DicomFrameEncodeRequest(
            frame: DicomCodecDecodedFrame(
                buffer: .owned(bytes),
                width: width,
                height: height,
                bitsPerSample: bitsStored,
                componentCount: 1
            ),
            descriptor: descriptor,
            targetTransferSyntaxUID: destination.rawValue,
            intent: intent,
            tileSize: tileSize
        )
    }

    private static func decodeWithOpenJPEG(
        _ codestream: Data,
        descriptor: DicomCompressedFrameDescriptor
    ) async throws -> DicomCodecDecodedFrame {
        try await DicomOpenJPEGFrameBackend().decode(DicomFrameDecodeRequest(
            frameData: codestream,
            descriptor: descriptor,
            frameIndex: 0
        ))
    }

    private static func codestreamProgressionOrder(_ codestream: Data) throws -> UInt8 {
        guard codestream.count >= 6, codestream[0] == 0xFF, codestream[1] == 0x4F else {
            throw DicomJ2KSwiftBackendError.metadataMismatch(
                transferSyntaxUID: "test",
                reason: "missing SOC"
            )
        }
        var offset = 2
        while offset + 4 <= codestream.count {
            guard codestream[offset] == 0xFF else { break }
            if codestream[offset + 1] == 0x52 {
                return codestream[offset + 5]
            }
            let length = Int(codestream[offset + 2]) << 8 | Int(codestream[offset + 3])
            guard length >= 2, offset + 2 + length <= codestream.count else { break }
            offset += 2 + length
        }
        throw DicomJ2KSwiftBackendError.metadataMismatch(
            transferSyntaxUID: "test",
            reason: "missing COD"
        )
    }

    private static func grayscaleBytes(
        width: Int,
        height: Int,
        bitDepth: Int,
        signed: Bool,
        seed: Int
    ) -> Data {
        let count = width * height
        if bitDepth <= 8 {
            let offset = signed ? 1 << (bitDepth - 1) : 0
            return Data((0..<count).map {
                let sample = (($0 * 17 + seed) % (1 << bitDepth)) - offset
                return signed
                    ? UInt8(bitPattern: Int8(clamping: sample))
                    : UInt8(sample)
            })
        }

        let offset = signed ? 1 << (bitDepth - 1) : 0
        let values = (0..<count).map { index -> UInt16 in
            let sample = ((index * 37 + seed) % (1 << bitDepth)) - offset
            return signed
                ? UInt16(bitPattern: Int16(clamping: sample))
                : UInt16(sample)
        }
        return littleEndianBytes(values)
    }

    private static func littleEndianBytes(_ values: [UInt16]) -> Data {
        var data = Data(capacity: values.count * 2)
        for value in values {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8(value >> 8))
        }
        return data
    }

    private static func psnr(reference: Data, candidate: Data) -> Double {
        guard reference.count == candidate.count, !reference.isEmpty else { return 0 }
        let squaredError = zip(reference, candidate).reduce(0.0) { partial, pair in
            let delta = Double(Int(pair.0) - Int(pair.1))
            return partial + delta * delta
        }
        let meanSquaredError = squaredError / Double(reference.count)
        guard meanSquaredError > 0 else { return .infinity }
        return 10 * log10((255 * 255) / meanSquaredError)
    }

    private static func makeNativeFile(
        frames: [Data],
        rows: Int,
        columns: Int,
        bitsAllocated: Int,
        bitsStored: Int,
        highBit: Int? = nil,
        signed: Bool = false,
        samplesPerPixel: Int = 1,
        photometricInterpretation: String = "MONOCHROME2",
        planarConfiguration: Int = 0,
        imageType: [String] = ["ORIGINAL", "PRIMARY"],
        derivationDescription: String? = nil,
        lossyRatio: String? = nil,
        lossyMethod: String? = nil
    ) throws -> Data {
        var dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .explicitVRLittleEndian,
            fragments: [],
            declaredFrames: frames.count,
            rows: rows,
            columns: columns,
            bitsAllocated: bitsAllocated,
            bitsStored: bitsStored,
            highBit: highBit ?? bitsStored - 1,
            samplesPerPixel: samplesPerPixel,
            photometricInterpretation: photometricInterpretation,
            pixelRepresentation: signed ? 1 : 0
        )
        dataSet.set(DicomDataElement(
            tag: DicomTag.patientName.rawValue,
            vr: .PN,
            value: .strings(["ENCODE^PARITY"])
        ))
        dataSet.set(DicomDataElement(
            tag: DicomTag.imageType.rawValue,
            vr: .CS,
            value: .strings(imageType)
        ))
        if samplesPerPixel == 3 {
            dataSet.set(DicomDataElement(
                tag: DicomTag.planarConfiguration.rawValue,
                vr: .US,
                value: .unsignedIntegers([UInt(planarConfiguration)])
            ))
        }
        if let derivationDescription {
            dataSet.set(DicomDataElement(
                tag: DicomTag.derivationDescription.rawValue,
                vr: .ST,
                value: .strings([derivationDescription])
            ))
        }
        if let lossyRatio, let lossyMethod {
            dataSet.set(DicomDataElement(
                tag: DicomTag.lossyImageCompression.rawValue,
                vr: .CS,
                value: .strings(["01"])
            ))
            dataSet.set(DicomDataElement(
                tag: DicomTag.lossyImageCompressionRatio.rawValue,
                vr: .DS,
                value: .strings([lossyRatio])
            ))
            dataSet.set(DicomDataElement(
                tag: DicomTag.lossyImageCompressionMethod.rawValue,
                vr: .CS,
                value: .strings([lossyMethod])
            ))
        }
        dataSet.set(DicomDataElement(
            tag: DicomTag.pixelData.rawValue,
            vr: bitsAllocated > 8 ? .OW : .OB,
            value: .bytes(frames.reduce(into: Data()) { $0.append($1) })
        ))
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .explicitVRLittleEndian,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.14260001"
            )
        )
    }
}
