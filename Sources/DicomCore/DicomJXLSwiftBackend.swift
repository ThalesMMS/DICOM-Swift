//
//  DicomJXLSwiftBackend.swift
//  DicomCore
//
//  Experimental package-linked JXLSwift adapter. Concrete JPEG XL types
//  remain behind DicomFrameCodecBackend.
//

import Foundation
import JXLSwift

extension DicomCodecBackendIdentifier {
    static let jxlSwift: Self = "jxlswift"
}

struct DicomJXLSwiftBackend: DicomFrameCodecBackend {
    static let version = "1.4.0"
    static let maximumDimension = 16_384
    static let maximumVarDCTDimension = 8_192
    static let maximumCompressedFrameBytes = 512 * 1_024 * 1_024
    static let rasterTransferSyntaxes: Set<String> = [
        DicomTransferSyntax.jpegXLLossless.rawValue,
        DicomTransferSyntax.jpegXL.rawValue
    ]
    static let allTransferSyntaxes = rasterTransferSyntaxes.union([
        DicomTransferSyntax.jpegXLJPEGRecompression.rawValue
    ])

    let capabilities = DicomFrameCodecCapabilities(
        identifier: .jxlSwift,
        families: [.jpegXL],
        transferSyntaxUIDs: allTransferSyntaxes,
        encodeTransferSyntaxUIDs: rasterTransferSyntaxes,
        operations: [.decode, .encode],
        supportedGrayscaleBitDepths: 8...16,
        supportedColorBitDepths: 8...8,
        maximumComponents: 3,
        supportsSignedSamples: true,
        executionClass: .cpu,
        source: .packageLinked,
        version: version
    )

    func decode(_ request: DicomFrameDecodeRequest) async throws -> DicomCodecDecodedFrame {
        try Task.checkCancellation()
        if let reason = capabilities.unsupportedReason(for: request) {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: request.descriptor.transferSyntaxUID,
                reason: reason
            )
        }
        try Self.validateDescriptor(request.descriptor)
        guard request.frameData.count <= Self.maximumCompressedFrameBytes else {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: request.descriptor.transferSyntaxUID,
                reason: "the compressed frame exceeds the 512 MiB safety limit"
            )
        }

        if request.descriptor.transferSyntaxUID == DicomTransferSyntax.jpegXLJPEGRecompression.rawValue {
            return try await decodeJPEGRecompression(request)
        }

        let decoder = JXLDecoder()
        let frameData = try Self.decodingInput(request.frameData) { data in
            _ = try decoder.inspect(data)
        }
        if request.descriptor.transferSyntaxUID == DicomTransferSyntax.jpegXLLossless.rawValue,
           decoder.inspectFrameStructure(frameData).encoding != .modular {
            throw DicomJXLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: request.descriptor.transferSyntaxUID,
                reason: "the lossless-only transfer syntax does not contain a Modular frame"
            )
        }
        let image = try decoder.decode(
            frameData,
            signedOutput: request.descriptor.pixelRepresentation == 1
                && request.descriptor.bitsAllocated == 16
        )
        try Task.checkCancellation()
        return try Self.decodedFrame(from: image, descriptor: request.descriptor)
    }

    func encode(_ request: DicomFrameEncodeRequest) async throws -> Data {
        try Task.checkCancellation()
        guard request.targetTransferSyntaxUID == request.descriptor.transferSyntaxUID else {
            throw DicomJXLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: request.targetTransferSyntaxUID,
                reason: "the request descriptor names transfer syntax \(request.descriptor.transferSyntaxUID)"
            )
        }
        if let reason = capabilities.unsupportedReason(for: request.descriptor, operation: .encode) {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: request.targetTransferSyntaxUID,
                reason: reason
            )
        }
        try Self.validateDescriptor(request.descriptor)
        if case .irreversible = request.intent,
           request.descriptor.rows > Self.maximumVarDCTDimension
            || request.descriptor.columns > Self.maximumVarDCTDimension {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: request.targetTransferSyntaxUID,
                reason: "irreversible VarDCT encoding is limited to 8192 pixels per dimension"
            )
        }
        let options = try Self.encodingOptions(
            for: request.intent,
            transferSyntaxUID: request.targetTransferSyntaxUID
        )
        let image = try Self.image(from: request)
        let encoded = try await JXLEncoder(options: options).encode(image)
        try Task.checkCancellation()
        return encoded.data
    }

    func recompressJPEG(_ jpegData: Data) async throws -> Data {
        try Task.checkCancellation()
        do {
            let encoded = try await JXLEncoder().encodeLosslessJPEG(jpegData)
            try Task.checkCancellation()
            return encoded.data
        } catch {
            throw DicomJXLSwiftBackendError.jpegRecompressionFailed(
                reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }
    }

    func reconstructJPEG(_ jxlData: Data) async throws -> Data {
        try Task.checkCancellation()
        do {
            let decoder = JXLDecoder()
            let input = try Self.decodingInput(jxlData) { data in
                _ = try decoder.inspect(data)
            }
            let decoded = try await decoder.decodeLosslessJPEG(input)
            try Task.checkCancellation()
            return decoded
        } catch {
            throw DicomJXLSwiftBackendError.jpegRecompressionFailed(
                reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }
    }

    private func decodeJPEGRecompression(
        _ request: DicomFrameDecodeRequest
    ) async throws -> DicomCodecDecodedFrame {
        let jpeg = try await reconstructJPEG(request.frameData)
        guard let decoded = DCMPixelReader.decodeCompressedFrameData(
            data: jpeg,
            transferSyntax: .jpegBaseline,
            width: request.descriptor.columns,
            height: request.descriptor.rows,
            bitDepth: 8,
            samplesPerPixel: request.descriptor.samplesPerPixel,
            pixelRepresentation: 0,
            photometricInterpretation: request.descriptor.photometricInterpretation,
            bitsStored: 8
        ) else {
            throw DicomJXLSwiftBackendError.jpegRecompressionFailed(
                reason: "the reconstructed JPEG Baseline frame could not be decoded by ImageIO"
            )
        }
        let bytes: Data
        if let pixels = decoded.pixels8 {
            bytes = Data(pixels)
        } else if let pixels = decoded.pixels24 {
            bytes = Data(pixels)
        } else {
            throw DicomJXLSwiftBackendError.jpegRecompressionFailed(
                reason: "the reconstructed JPEG Baseline frame did not produce 8-bit grayscale or RGB pixels"
            )
        }
        return DicomCodecDecodedFrame(
            buffer: .owned(bytes),
            width: decoded.width,
            height: decoded.height,
            bitsPerSample: 8,
            componentCount: decoded.samplesPerPixel
        )
    }

    private static func validateDescriptor(_ descriptor: DicomCompressedFrameDescriptor) throws {
        let uid = descriptor.transferSyntaxUID
        guard descriptor.rows > 0,
              descriptor.columns > 0,
              descriptor.rows <= maximumDimension,
              descriptor.columns <= maximumDimension else {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: uid,
                reason: "Rows and Columns must be within 1...\(maximumDimension)"
            )
        }
        guard descriptor.bitsAllocated == 8 || descriptor.bitsAllocated == 16,
              descriptor.bitsStored == descriptor.bitsAllocated,
              descriptor.highBit == descriptor.bitsStored - 1 else {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: uid,
                reason: "the qualified adapter requires aligned 8- or 16-bit samples; 10/12-bit routes remain disabled"
            )
        }
        guard descriptor.pixelRepresentation == 0
                || descriptor.pixelRepresentation == 1 && descriptor.bitsAllocated == 16 else {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: uid,
                reason: "signed samples are qualified only for aligned 16-bit grayscale"
            )
        }
        let photometric = descriptor.photometricInterpretation.uppercased()
        if uid == DicomTransferSyntax.jpegXLJPEGRecompression.rawValue {
            let monochrome = descriptor.samplesPerPixel == 1 && photometric == "MONOCHROME2"
            let color = descriptor.samplesPerPixel == 3
                && ["RGB", "YBR_FULL_422"].contains(photometric)
                && descriptor.planarConfiguration == 0
            guard descriptor.bitsAllocated == 8,
                  descriptor.pixelRepresentation == 0,
                  monochrome || color else {
                throw DicomJXLSwiftBackendError.unsupportedShape(
                    transferSyntaxUID: uid,
                    reason: "JPEG recompression is qualified only for unsigned JPEG Baseline 8-bit MONOCHROME2 or RGB/YBR_FULL_422"
                )
            }
            return
        }
        if descriptor.samplesPerPixel == 1 {
            guard photometric.isEmpty || photometric == "MONOCHROME1" || photometric == "MONOCHROME2" else {
                throw DicomJXLSwiftBackendError.unsupportedShape(
                    transferSyntaxUID: uid,
                    reason: "single-component JPEG XL does not accept \(descriptor.photometricInterpretation)"
                )
            }
        } else {
            guard descriptor.samplesPerPixel == 3,
                  descriptor.bitsAllocated == 8,
                  descriptor.pixelRepresentation == 0,
                  photometric == "RGB",
                  descriptor.planarConfiguration == 0 else {
                throw DicomJXLSwiftBackendError.unsupportedShape(
                    transferSyntaxUID: uid,
                    reason: "multi-component JPEG XL is qualified only for unsigned interleaved RGB8"
                )
            }
        }
    }

    private static func encodingOptions(
        for intent: DicomEncodingIntent,
        transferSyntaxUID: String
    ) throws -> EncodingOptions {
        switch (transferSyntaxUID, intent) {
        case (DicomTransferSyntax.jpegXLLossless.rawValue, .reversible),
             (DicomTransferSyntax.jpegXL.rawValue, .reversible):
            return EncodingOptions(mode: .lossless, containerWrap: false)
        case (DicomTransferSyntax.jpegXL.rawValue, .irreversible(let quality))
            where quality > 0 && quality < 1 && quality.isFinite:
            return EncodingOptions(mode: .lossy(quality: Float(quality * 100)), containerWrap: false)
        case (DicomTransferSyntax.jpegXL.rawValue, .irreversible(let quality)):
            throw DicomJXLSwiftBackendError.invalidEncodingIntent(
                transferSyntaxUID: transferSyntaxUID,
                reason: "irreversible quality must be finite and strictly between zero and one; got \(quality)"
            )
        case (DicomTransferSyntax.jpegXLLossless.rawValue, _):
            throw DicomJXLSwiftBackendError.invalidEncodingIntent(
                transferSyntaxUID: transferSyntaxUID,
                reason: "the lossless-only syntax requires reversible intent"
            )
        default:
            throw DicomJXLSwiftBackendError.invalidEncodingIntent(
                transferSyntaxUID: transferSyntaxUID,
                reason: "the raster adapter supports only JPEG XL Lossless and JPEG XL"
            )
        }
    }

    private static func image(from request: DicomFrameEncodeRequest) throws -> ImageFrame {
        let descriptor = request.descriptor
        let frame = request.frame
        guard frame.width == descriptor.columns,
              frame.height == descriptor.rows,
              frame.bitsPerSample == descriptor.bitsStored,
              frame.componentCount == descriptor.samplesPerPixel else {
            throw DicomJXLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: request.targetTransferSyntaxUID,
                reason: "the input frame shape does not match the DICOM descriptor"
            )
        }
        let expectedBytes = try checkedByteCount(descriptor)
        guard frame.buffer.data.count == expectedBytes else {
            throw DicomJXLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: request.targetTransferSyntaxUID,
                reason: "the input frame contains \(frame.buffer.data.count) bytes, expected \(expectedBytes)"
            )
        }
        let pixelType: PixelType
        if descriptor.bitsAllocated == 8 {
            pixelType = .uint8
        } else if descriptor.pixelRepresentation == 1 {
            pixelType = .int16
        } else {
            pixelType = .uint16
        }
        var image = ImageFrame(
            width: descriptor.columns,
            height: descriptor.rows,
            channels: descriptor.samplesPerPixel,
            pixelType: pixelType,
            colorSpace: descriptor.samplesPerPixel == 1 ? .grayscale : .sRGB
        )
        image.data = Array(frame.buffer.data)
        return image
    }

    private static func decodedFrame(
        from image: ImageFrame,
        descriptor: DicomCompressedFrameDescriptor
    ) throws -> DicomCodecDecodedFrame {
        guard image.width == descriptor.columns,
              image.height == descriptor.rows,
              image.channels == descriptor.samplesPerPixel else {
            throw DicomJXLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: descriptor.transferSyntaxUID,
                reason: "codestream dimensions or component count do not match the DICOM descriptor"
            )
        }
        guard image.iccProfile == nil else {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: descriptor.transferSyntaxUID,
                reason: "embedded ICC profiles remain outside the qualified adapter"
            )
        }
        let expectedType: PixelType
        if descriptor.bitsAllocated == 8 {
            expectedType = .uint8
        } else if descriptor.pixelRepresentation == 1 {
            expectedType = .int16
        } else {
            expectedType = .uint16
        }
        guard image.pixelType == expectedType else {
            throw DicomJXLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: descriptor.transferSyntaxUID,
                reason: "codestream pixel type \(image.pixelType) does not match the DICOM sample representation"
            )
        }
        let expectedBytes = try checkedByteCount(descriptor)
        guard image.data.count == expectedBytes else {
            throw DicomJXLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: descriptor.transferSyntaxUID,
                reason: "decoded byte count is \(image.data.count), expected \(expectedBytes)"
            )
        }
        return DicomCodecDecodedFrame(
            buffer: .owned(Data(image.data)),
            width: image.width,
            height: image.height,
            bitsPerSample: image.pixelType.bitsPerSample,
            componentCount: image.channels
        )
    }

    private static func checkedByteCount(_ descriptor: DicomCompressedFrameDescriptor) throws -> Int {
        let pixels = descriptor.rows.multipliedReportingOverflow(by: descriptor.columns)
        let samples = pixels.partialValue.multipliedReportingOverflow(by: descriptor.samplesPerPixel)
        let bytes = samples.partialValue.multipliedReportingOverflow(by: descriptor.bitsAllocated / 8)
        guard !pixels.overflow, !samples.overflow, !bytes.overflow else {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: descriptor.transferSyntaxUID,
                reason: "the frame dimensions exceed the addressable byte range"
            )
        }
        return bytes.partialValue
    }

    private static func decodingInput(
        _ data: Data,
        validate: (Data) throws -> Void
    ) throws -> Data {
        do {
            try validate(data)
            return data
        } catch let originalError {
            guard data.last == 0, !data.isEmpty else {
                throw originalError
            }
            let withoutPadding = Data(data.dropLast())
            do {
                try validate(withoutPadding)
                return withoutPadding
            } catch {
                throw originalError
            }
        }
    }
}
