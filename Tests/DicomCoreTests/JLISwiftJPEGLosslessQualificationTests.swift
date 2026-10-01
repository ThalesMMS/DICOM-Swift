//
//  JLISwiftJPEGLosslessQualificationTests.swift
//  DicomCoreTests
//
//  Test-only qualification of Raster-Lab/JLISwift 0.5.0 for DICOM JPEG
//  Lossless encoding. JLIDICOM is intentionally not linked: DicomCore owns
//  Part 10 construction and encapsulated-frame mapping.
//

import CryptoKit
import Foundation
import DicomJPEG
import XCTest
@testable import DicomCore

final class JLISwiftJPEGLosslessQualificationTests: XCTestCase {
    private static let width = 8
    private static let height = 4

    func test_losslessMatrix8_12_16BitPredictors1Through7_crossDecodesExactly() throws {
        for bitDepth in [8, 12, 16] {
            let samples = Self.samples(bitDepth: bitDepth, variant: 0)
            let image = try Self.image(samples: samples, bitDepth: bitDepth)

            for predictor in 1...7 {
                let encoded = try Self.encode(
                    image: image,
                    bitDepth: bitDepth,
                    predictor: predictor
                )

                let jliDecoded = try JLIDecoder().decode(from: [UInt8](encoded))
                XCTAssertEqual(
                    jliDecoded.data,
                    image.data,
                    "JLISwift round-trip, P=\(bitDepth), predictor=\(predictor)"
                )

                let nativeDecoder = JPEGLosslessDecoder()
                let nativeDecoded = try nativeDecoder.decode(data: encoded)
                XCTAssertEqual(nativeDecoded.bitDepth, bitDepth)
                XCTAssertEqual(nativeDecoded.pixels.map(Int.init), samples)
                XCTAssertEqual(nativeDecoder.sof3Info?.precision, bitDepth)
                XCTAssertEqual(nativeDecoder.sosInfo?.selectionValue, predictor)
                XCTAssertEqual(nativeDecoder.sosInfo?.successiveApproximationHigh, 0)
                XCTAssertEqual(nativeDecoder.sosInfo?.successiveApproximationLow, 0)

                let nativeStream = makeJPEGLosslessStream(
                    planes: [samples],
                    width: Self.width,
                    height: Self.height,
                    precision: bitDepth,
                    selectionValue: predictor
                )
                let jliCrossDecoded = try JLIDecoder().decode(from: [UInt8](nativeStream))
                XCTAssertEqual(
                    jliCrossDecoded.data,
                    image.data,
                    "native-to-JLISwift cross-decode, P=\(bitDepth), predictor=\(predictor)"
                )
            }
        }
    }

    func test_signedStoredCodesAt8_12_16Bits_areBitExact() throws {
        for bitDepth in [8, 12, 16] {
            let samples = Self.signedStoredCodes(bitDepth: bitDepth)
            let image = try Self.image(samples: samples, bitDepth: bitDepth, isSigned: true)
            XCTAssertTrue(image.isSigned)

            let encoded = try Self.encode(image: image, bitDepth: bitDepth, predictor: 1)
            let jliDecoded = try JLIDecoder().decode(from: [UInt8](encoded))
            XCTAssertEqual(jliDecoded.data, image.data, "signed stored codes, P=\(bitDepth)")

            let nativeDecoded = try JPEGLosslessDecoder().decode(data: encoded)
            XCTAssertEqual(nativeDecoded.pixels.map(Int.init), samples)
        }
    }

    func test_signedLossyEncoding_isRejected() throws {
        let image = try Self.image(
            samples: Self.signedStoredCodes(bitDepth: 16),
            bitDepth: 16,
            isSigned: true
        )

        XCTAssertThrowsError(try JLIEncoder().encode(image, configuration: .default)) { error in
            guard case JLIError.unsupportedJPEGFeature(let reason) = error else {
                return XCTFail("expected unsupportedJPEGFeature, got \(error)")
            }
            XCTAssertTrue(reason.contains("signed pixel data"), reason)
        }
    }

    func test_rowAlignedRestart_crossDecodesAt8_12_16BitsAndCarriesDRI() throws {
        for bitDepth in [8, 12, 16] {
            let samples = Self.samples(bitDepth: bitDepth, variant: 1)
            let image = try Self.image(samples: samples, bitDepth: bitDepth)
            let restartInterval = Self.width
            let encoded = try Self.encode(
                image: image,
                bitDepth: bitDepth,
                predictor: 1,
                restartInterval: restartInterval
            )

            XCTAssertEqual(try JLIDecoder().decode(from: [UInt8](encoded)).data, image.data)
            let nativeDecoder = JPEGLosslessDecoder()
            XCTAssertEqual(try nativeDecoder.decode(data: encoded).pixels.map(Int.init), samples)
            XCTAssertEqual(nativeDecoder.restartInterval, restartInterval)

            let nativeStream = makeJPEGLosslessStream(
                planes: [samples],
                width: Self.width,
                height: Self.height,
                precision: bitDepth,
                restartInterval: restartInterval
            )
            XCTAssertEqual(try JLIDecoder().decode(from: [UInt8](nativeStream)).data, image.data)
        }
    }

    func test_nonConformantMidRowRestart_isRejectedByBothDecoders() throws {
        let bitDepth = 12
        let samples = Self.samples(bitDepth: bitDepth, variant: 2)
        let image = try Self.image(samples: samples, bitDepth: bitDepth)
        let midRowInterval = Self.width / 2

        var configuration = Self.configuration(
            bitDepth: bitDepth,
            predictor: 1,
            restartInterval: midRowInterval
        )
        configuration.losslessPointTransform = 0
        XCTAssertThrowsError(try JLIEncoder().encode(image, configuration: configuration)) { error in
            Self.assertKnownRowAlignmentError(error)
        }

        let nativeStream = makeJPEGLosslessStream(
            planes: [samples],
            width: Self.width,
            height: Self.height,
            precision: bitDepth,
            restartInterval: midRowInterval
        )
        XCTAssertThrowsError(try JPEGLosslessDecoder().decode(data: nativeStream)) { error in
            guard case DICOMError.invalidDICOMFormat(let reason) = error else {
                return XCTFail("expected invalidDICOMFormat, got \(error)")
            }
            XCTAssertTrue(reason.contains("multiple of the MCU row width"), reason)
        }
        XCTAssertThrowsError(try JLIDecoder().decode(from: [UInt8](nativeStream))) { error in
            Self.assertKnownRowAlignmentError(error)
        }
    }

    func test_invalidLosslessConfiguration_failsSafely() throws {
        let image = try Self.image(samples: Self.samples(bitDepth: 12, variant: 0), bitDepth: 12)

        for predictor in [0, 8] {
            let configuration = Self.configuration(bitDepth: 12, predictor: predictor)
            XCTAssertThrowsError(try JLIEncoder().encode(image, configuration: configuration))
        }
        for precision in [1, 17] {
            let configuration = Self.configuration(bitDepth: precision, predictor: 1)
            XCTAssertThrowsError(try JLIEncoder().encode(image, configuration: configuration))
        }
        var invalidPointTransform = Self.configuration(bitDepth: 12, predictor: 1)
        invalidPointTransform.losslessPointTransform = 12
        XCTAssertThrowsError(try JLIEncoder().encode(image, configuration: invalidPointTransform))

        for restartInterval in [-1, 65_536] {
            let configuration = Self.configuration(
                bitDepth: 12,
                predictor: 1,
                restartInterval: restartInterval
            )
            XCTAssertThrowsError(try JLIEncoder().encode(image, configuration: configuration))
        }
    }

    func test_malformedAndAdversarialSOF3Inputs_throw() throws {
        let image = try Self.image(samples: Self.samples(bitDepth: 12, variant: 0), bitDepth: 12)
        let valid = try Self.encode(image: image, bitDepth: 12, predictor: 1)

        XCTAssertThrowsError(try JLIDecoder().decode(from: []))
        XCTAssertThrowsError(try JLIDecoder().decode(from: [0x00, 0x00]))

        let sosEnd = try XCTUnwrap(Self.endOfSegment(marker: 0xDA, in: valid))
        for prefixLength in 0..<sosEnd {
            XCTAssertThrowsError(
                try JLIDecoder().decode(from: [UInt8](valid.prefix(prefixLength))),
                "truncated SOF3 prefix length \(prefixLength)"
            )
        }

        var invalidPrecision = valid
        let sof3 = try XCTUnwrap(Self.markerOffset(0xC3, in: invalidPrecision))
        invalidPrecision[sof3 + 4] = 1
        XCTAssertThrowsError(try JLIDecoder().decode(from: [UInt8](invalidPrecision)))

        var invalidPredictor = valid
        let sos = try XCTUnwrap(Self.markerOffset(0xDA, in: invalidPredictor))
        let componentCount = Int(invalidPredictor[sos + 4])
        invalidPredictor[sos + 5 + componentCount * 2] = 8
        XCTAssertThrowsError(try JLIDecoder().decode(from: [UInt8](invalidPredictor)))

        var truncatedEntropy = valid
        truncatedEntropy.removeLast(max(2, truncatedEntropy.count / 4))
        XCTAssertThrowsError(try JLIDecoder().decode(from: [UInt8](truncatedEntropy)))
    }

    func test_singleFrameBOT_usesDicomCoreAndNativeDecoder() throws {
        let bitDepth = 12
        let samples = Self.samples(bitDepth: bitDepth, variant: 0)
        let codestream = try Self.evenLengthCodestream(
            samples: samples,
            bitDepth: bitDepth
        )
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpegLosslessFirstOrder,
            fragments: [codestream],
            declaredFrames: 1,
            rows: Self.height,
            columns: Self.width,
            bitsAllocated: 16,
            bitsStored: bitDepth,
            highBit: bitDepth - 1
        )

        let decoder = try DCMDecoder(data: file)
        let encapsulated = try decoder.makeEncapsulatedPixelFrameReader()
        XCTAssertEqual(encapsulated.frameCount, 1)
        XCTAssertEqual(try encapsulated.frameData(at: 0), codestream)
        XCTAssertEqual(
            try Self.gray16Frame(DicomDecodedFrameReader(decoder: decoder), at: 0),
            samples.map(UInt16.init)
        )
    }

    func test_multiframeBOT_decodesEachJLISwiftFrame() throws {
        let bitDepth = 12
        let expected = [
            Self.samples(bitDepth: bitDepth, variant: 1),
            Self.samples(bitDepth: bitDepth, variant: 2)
        ]
        let codestreams = try expected.map {
            try Self.evenLengthCodestream(samples: $0, bitDepth: bitDepth)
        }
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpegLosslessFirstOrder,
            fragments: codestreams,
            declaredFrames: expected.count,
            rows: Self.height,
            columns: Self.width,
            bitsAllocated: 16,
            bitsStored: bitDepth,
            highBit: bitDepth - 1
        )

        let reader = DicomDecodedFrameReader(decoder: try DCMDecoder(data: file))
        XCTAssertEqual(reader.frameCount, expected.count)
        for index in expected.indices {
            XCTAssertEqual(try Self.gray16Frame(reader, at: index), expected[index].map(UInt16.init))
        }
    }

    func test_multiframeEOT_mapsMultipleFragmentsPerJLISwiftFrame() throws {
        let bitDepth = 12
        let expected = [
            Self.samples(bitDepth: bitDepth, variant: 3),
            Self.samples(bitDepth: bitDepth, variant: 4)
        ]
        let codestreams = try expected.map {
            try Self.evenLengthCodestream(samples: $0, bitDepth: bitDepth)
        }
        let fragments = codestreams.flatMap(Self.splitIntoEvenFragments)
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpegLosslessFirstOrder,
            fragments: fragments,
            declaredFrames: expected.count,
            includeBasicOffsetTable: false,
            extendedOffsetTableFrameStartFragmentIndexes: [0, 2],
            rows: Self.height,
            columns: Self.width,
            bitsAllocated: 16,
            bitsStored: bitDepth,
            highBit: bitDepth - 1
        )

        let decoder = try DCMDecoder(data: file)
        let encapsulated = try decoder.makeEncapsulatedPixelFrameReader()
        XCTAssertEqual(try encapsulated.frameData(at: 0), codestreams[0])
        XCTAssertEqual(try encapsulated.frameData(at: 1), codestreams[1])

        let reader = DicomDecodedFrameReader(decoder: decoder)
        for index in expected.indices {
            XCTAssertEqual(try Self.gray16Frame(reader, at: index), expected[index].map(UInt16.init))
        }
    }

    func test_committedGDCMOracleFixtures_matchPinnedHashes() throws {
        let expectedHashes = [
            "jliswift_sv1_gray12_bot": "b280fb64e889b744ff78cd8f6b4a7f596ca36211732dab3e223fdbbb656c8924",
            "jliswift_sv1_gray12_eot": "540cbfe02eaff2c2d6611566a9f6f27920e7c6196192dbfd29291d964b0c83e9"
        ]

        for (name, expectedHash) in expectedHashes {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "dcm"))
            let actualHash = SHA256.hash(data: try Data(contentsOf: url))
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(actualHash, expectedHash, name)
        }
    }

    func test_requestedFixtureGeneration_writesCommittedGDCMOracles() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["DICOM_JLISWIFT_FIXTURE_OUTPUT"] else {
            throw XCTSkip("Set DICOM_JLISWIFT_FIXTURE_OUTPUT only when regenerating the committed oracle fixtures.")
        }
        let bitDepth = 12
        let expected = [
            Self.samples(bitDepth: bitDepth, variant: 1),
            Self.samples(bitDepth: bitDepth, variant: 2)
        ]
        let codestreams = try expected.map {
            try Self.evenLengthCodestream(samples: $0, bitDepth: bitDepth)
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let bot = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpegLosslessFirstOrder,
            fragments: codestreams,
            declaredFrames: expected.count,
            rows: Self.height,
            columns: Self.width,
            bitsAllocated: 16,
            bitsStored: bitDepth,
            highBit: bitDepth - 1
        )
        try bot.write(to: output.appendingPathComponent("jliswift_sv1_gray12_bot.dcm"))

        let fragments = codestreams.flatMap(Self.splitIntoEvenFragments)
        let eot = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpegLosslessFirstOrder,
            fragments: fragments,
            declaredFrames: expected.count,
            includeBasicOffsetTable: false,
            extendedOffsetTableFrameStartFragmentIndexes: [0, 2],
            rows: Self.height,
            columns: Self.width,
            bitsAllocated: 16,
            bitsStored: bitDepth,
            highBit: bitDepth - 1
        )
        try eot.write(to: output.appendingPathComponent("jliswift_sv1_gray12_eot.dcm"))
    }

    // MARK: - Helpers

    private static func samples(bitDepth: Int, variant: Int) -> [Int] {
        let scale: Int
        switch bitDepth {
        case 8: scale = 1
        case 12: scale = 13
        default: scale = 257
        }
        return (0..<(width * height)).map { index in
            let x = index % width
            let y = index / width
            return (x * 11 + y * 17 + (x * y) % 7 + variant * 7) * scale
        }
    }

    private static func signedStoredCodes(bitDepth: Int) -> [Int] {
        let mask = bitDepth == 16 ? Int(UInt16.max) : (1 << bitDepth) - 1
        let signBit = 1 << (bitDepth - 1)
        let values = [signBit, mask - 16, mask, 0, 1, 17, signBit - 1, signBit + 1]
        return Array(repeating: values, count: height).flatMap { $0 }
    }

    private static func image(samples: [Int], bitDepth: Int, isSigned: Bool = false) throws -> JLIImage {
        if bitDepth <= 8 {
            return try JLIImage(
                width: width,
                height: height,
                pixelFormat: .uint8,
                colorModel: .grayscale,
                data: samples.map(UInt8.init),
                isSigned: isSigned
            )
        }
        return try JLIImage(
            width: width,
            height: height,
            pixelFormat: .uint16,
            colorModel: .grayscale,
            data: littleEndianBytes(samples),
            isSigned: isSigned
        )
    }

    private static func littleEndianBytes(_ samples: [Int]) -> [UInt8] {
        samples.flatMap { value in
            let sample = UInt16(value)
            return [UInt8(sample & 0xFF), UInt8(sample >> 8)]
        }
    }

    private static func configuration(
        bitDepth: Int,
        predictor: Int,
        restartInterval: Int = 0
    ) -> JLIEncoderConfiguration {
        var configuration = JLIEncoderConfiguration.diagnosticLossless
        configuration.losslessPrecision = bitDepth
        configuration.losslessPredictor = predictor
        configuration.losslessPointTransform = 0
        configuration.restartInterval = restartInterval
        return configuration
    }

    private static func encode(
        image: JLIImage,
        bitDepth: Int,
        predictor: Int,
        restartInterval: Int = 0
    ) throws -> Data {
        Data(try JLIEncoder().encode(
            image,
            configuration: configuration(
                bitDepth: bitDepth,
                predictor: predictor,
                restartInterval: restartInterval
            )
        ))
    }

    private static func evenLengthCodestream(samples: [Int], bitDepth: Int) throws -> Data {
        var data = try encode(
            image: image(samples: samples, bitDepth: bitDepth),
            bitDepth: bitDepth,
            predictor: 1
        )
        if data.count.isMultiple(of: 2) == false {
            data.append(0)
        }
        return data
    }

    private static func splitIntoEvenFragments(_ data: Data) -> [Data] {
        precondition(data.count >= 4 && data.count.isMultiple(of: 2))
        let split = max(2, (data.count / 4) * 2)
        return [Data(data[..<split]), Data(data[split...])]
    }

    private static func gray16Frame(_ reader: DicomDecodedFrameReader, at index: Int) throws -> [UInt16] {
        let frame = try reader.frame(at: index)
        guard case .gray16(let pixels) = frame.pixels else {
            XCTFail("expected gray16, got \(frame.pixels)")
            return []
        }
        XCTAssertEqual(
            frame.metadata.transferSyntaxUID,
            DicomTransferSyntax.jpegLosslessFirstOrder.rawValue
        )
        XCTAssertEqual(frame.metadata.pixelRepresentation, 0)
        return pixels
    }

    private static func markerOffset(_ marker: UInt8, in data: Data) -> Int? {
        data.range(of: Data([0xFF, marker]))?.lowerBound
    }

    private static func endOfSegment(marker: UInt8, in data: Data) -> Int? {
        guard let offset = markerOffset(marker, in: data), offset + 4 <= data.count else { return nil }
        let length = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
        let end = offset + 2 + length
        return end <= data.count ? end : nil
    }

    private static func assertKnownRowAlignmentError(_ error: Error) {
        guard case JLIError.unsupportedJPEGFeature(let reason) = error else {
            return XCTFail("expected unsupportedJPEGFeature, got \(error)")
        }
        XCTAssertTrue(reason.contains("multiple of"), reason)
        XCTAssertTrue(reason.contains("samples-per-row"), reason)
    }
}
