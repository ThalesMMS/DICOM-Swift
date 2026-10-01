//
//  DicomJPEGSwiftBackend.swift
//  DicomCore
//
//  Own JPEG backend: ITU-T T.81 SOF0 baseline, SOF1 extended sequential 8/12-bit and SOF2 progressive on the
//  vendored DicomJPEG target; SOF3 lossless on the own `JPEGLosslessDecoder`/`JPEGLosslessEncoder` (#2327).
//  DicomJPEG types stay behind the neutral frame contract; photometric conversion, precision and signedness
//  are decided here and never silently reduced.
//

import DicomJPEG
import Foundation

extension DicomCodecBackendIdentifier {
    static let jpegSwift: Self = "jpegswift"
}

enum DicomJPEGSwiftBackendError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedShape(transferSyntaxUID: String, reason: String)
    case metadataMismatch(transferSyntaxUID: String, reason: String)
    case invalidEncodingIntent(transferSyntaxUID: String, reason: String)
    case codestreamRejected(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedShape(let uid, let reason):
            return "The JPEG backend does not support transfer syntax \(uid) for this frame: \(reason)"
        case .metadataMismatch(let uid, let reason):
            return "JPEG codestream does not match DICOM metadata for transfer syntax \(uid): \(reason)"
        case .invalidEncodingIntent(let uid, let reason):
            return "Invalid JPEG encoding intent for transfer syntax \(uid): \(reason)"
        case .codestreamRejected(let reason):
            return "JPEG codestream rejected: \(reason)"
        }
    }
}

struct DicomJPEGSwiftBackend: DicomFrameCodecBackend {
    static let version = "0.5.0-vendored"
    static let dctTransferSyntaxes: Set<String> = [
        DicomTransferSyntax.jpegBaseline.rawValue, DicomTransferSyntax.jpegExtended.rawValue
    ]
    static let losslessTransferSyntaxes: Set<String> = [
        DicomTransferSyntax.jpegLossless.rawValue, DicomTransferSyntax.jpegLosslessFirstOrder.rawValue
    ]
    static let transferSyntaxes = dctTransferSyntaxes.union(losslessTransferSyntaxes)
    /// Reduced decode takes 1/2, 1/4 and 1/8 from the DCT coefficients (exact box averages of the source block).
    static let maximumResolutionLevel = 3

    let capabilities = DicomFrameCodecCapabilities(
        identifier: .jpegSwift,
        families: [.jpeg],
        transferSyntaxUIDs: transferSyntaxes,
        encodeTransferSyntaxUIDs: transferSyntaxes,
        operations: [.decode, .encode],
        supportedGrayscaleBitDepths: 2...16,
        supportedColorBitDepths: 8...8,
        maximumComponents: 3,
        supportsSignedSamples: true,
        partialDecode: DicomPartialDecodeCapabilities(supportsResolutionLevels: true),
        executionClass: .cpu,
        source: .packageLinked,
        version: version
    )

    // MARK: - Decode

    func decode(_ request: DicomFrameDecodeRequest) async throws -> DicomCodecDecodedFrame {
        try Task.checkCancellation()
        if let reason = capabilities.unsupportedReason(for: request) {
            throw DicomJPEGSwiftBackendError.unsupportedShape(transferSyntaxUID: request.descriptor.transferSyntaxUID, reason: reason)
        }
        try Self.validateDescriptor(request.descriptor, operation: .decode)
        let scale: Int
        if let level = request.partialRequest?.resolutionLevel, level > 0 {
            guard level <= Self.maximumResolutionLevel, request.partialRequest?.region == nil else {
                throw DicomJPEGSwiftBackendError.unsupportedShape(
                    transferSyntaxUID: request.descriptor.transferSyntaxUID,
                    reason: "reduced JPEG decode offers resolution levels 1...\(Self.maximumResolutionLevel) without a region"
                )
            }
            scale = 1 << level
        } else {
            scale = 1
        }
        return try Self.decodeSynchronously(request.frameData, descriptor: request.descriptor, scale: scale)
    }

    /// The synchronous decode shared by the async backend and the legacy pixel reader.
    static func decodeSynchronously(_ frameData: Data, descriptor: DicomCompressedFrameDescriptor, scale: Int = 1) throws -> DicomCodecDecodedFrame {
        let uid = descriptor.transferSyntaxUID
        let lossless = losslessTransferSyntaxes.contains(uid)
        let inspection: DicomJPEGFrameInspector.Inspection?
        do {
            inspection = try DicomJPEGFrameInspector.inspect(frameData, maximumEncodedBytes: Int.max)
        } catch DicomJPEGFrameInspector.Failure.unsupportedProcess {
            throw DicomJPEGSwiftBackendError.codestreamRejected("arithmetic, hierarchical or differential JPEG processes are not decoded")
        } catch DicomJPEGFrameInspector.Failure.limitExceeded {
            inspection = nil
        } catch {
            throw DicomJPEGSwiftBackendError.codestreamRejected("marker structure is invalid: \(error)")
        }
        if let inspection {
            // A progressive or lossless codestream must not travel under a sequential DCT transfer syntax and vice versa.
            switch (inspection.process, lossless) {
            case (.lossless, false): throw DicomJPEGSwiftBackendError.metadataMismatch(transferSyntaxUID: uid, reason: "lossless (SOF3) codestream under a DCT transfer syntax")
            case (.baseline, true), (.extendedSequential, true), (.progressive, true):
                throw DicomJPEGSwiftBackendError.metadataMismatch(transferSyntaxUID: uid, reason: "DCT codestream under a lossless transfer syntax")
            case (.lossless, true):
                return try decodeLossless(frameData, descriptor: descriptor, inspection: inspection, scale: scale)
            default: break
            }
        }
        if lossless {
            // The inspector gave up on a very large codestream; the own decoder parses the markers itself.
            return try decodeLossless(frameData, descriptor: descriptor, inspection: nil, scale: scale)
        }
        let bytes = [UInt8](frameData)
        let info: JLIJPEGInfo
        do { info = try JLIDecoder().inspect(data: bytes) } catch {
            throw DicomJPEGSwiftBackendError.codestreamRejected((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        guard info.width == descriptor.columns, info.height == descriptor.rows else {
            throw DicomJPEGSwiftBackendError.metadataMismatch(transferSyntaxUID: uid, reason: "codestream is \(info.width)x\(info.height), expected \(descriptor.columns)x\(descriptor.rows)")
        }
        guard info.componentCount == descriptor.samplesPerPixel else {
            throw DicomJPEGSwiftBackendError.metadataMismatch(transferSyntaxUID: uid, reason: "codestream has \(info.componentCount) components, expected \(descriptor.samplesPerPixel)")
        }
        let expectedBits = descriptor.bitsStored
        guard info.bitsPerComponent == expectedBits || (lossless && info.bitsPerComponent <= descriptor.bitsAllocated) else {
            throw DicomJPEGSwiftBackendError.metadataMismatch(transferSyntaxUID: uid, reason: "codestream precision is \(info.bitsPerComponent) bits, expected \(expectedBits)")
        }
        let pixelFormat: JLIPixelFormat = descriptor.bitsAllocated > 8 ? .uint16 : .uint8
        let colorModel: JLIColorModel = descriptor.samplesPerPixel == 3 ? .rgb : .grayscale
        let image: JLIImage
        do {
            image = try JLIDecoder().decode(from: bytes, configuration: JLIDecoderConfiguration(
                outputPixelFormat: pixelFormat, outputColorModel: colorModel, scale: scale))
        } catch {
            throw DicomJPEGSwiftBackendError.codestreamRejected((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        let expectedWidth = (descriptor.columns + scale - 1) / scale, expectedHeight = (descriptor.rows + scale - 1) / scale
        guard image.width == expectedWidth, image.height == expectedHeight else {
            throw DicomJPEGSwiftBackendError.metadataMismatch(transferSyntaxUID: uid, reason: "decoded \(image.width)x\(image.height), expected \(expectedWidth)x\(expectedHeight)")
        }
        let expectedBytes = expectedWidth * expectedHeight * descriptor.samplesPerPixel * (descriptor.bitsAllocated > 8 ? 2 : 1)
        guard image.data.count == expectedBytes else {
            throw DicomJPEGSwiftBackendError.metadataMismatch(transferSyntaxUID: uid, reason: "decoded \(image.data.count) bytes, expected \(expectedBytes)")
        }
        return DicomCodecDecodedFrame(buffer: .owned(Data(image.data)), width: image.width, height: image.height,
                                      bitsPerSample: descriptor.bitsAllocated, componentCount: descriptor.samplesPerPixel)
    }

    /// SOF3 through the own lossless decoder: full resolution only, samples packed to Bits Allocated, signed samples
    /// below 16 bits sign-extended from Bits Stored (the codestream carries the stored two's-complement codes).
    static func decodeLossless(_ frameData: Data, descriptor: DicomCompressedFrameDescriptor,
                               inspection: DicomJPEGFrameInspector.Inspection?, scale: Int) throws -> DicomCodecDecodedFrame {
        let uid = descriptor.transferSyntaxUID
        guard scale == 1 else {
            throw DicomJPEGSwiftBackendError.unsupportedShape(transferSyntaxUID: uid, reason: "reduced decode applies to DCT codestreams; lossless frames decode at full resolution")
        }
        if let inspection {
            guard inspection.width == descriptor.columns, inspection.height == descriptor.rows else {
                throw DicomJPEGSwiftBackendError.metadataMismatch(transferSyntaxUID: uid, reason: "codestream is \(inspection.width)x\(inspection.height), expected \(descriptor.columns)x\(descriptor.rows)")
            }
            guard inspection.components.count == descriptor.samplesPerPixel else {
                throw DicomJPEGSwiftBackendError.metadataMismatch(transferSyntaxUID: uid, reason: "codestream has \(inspection.components.count) components, expected \(descriptor.samplesPerPixel)")
            }
            guard inspection.precision == descriptor.bitsStored || inspection.precision <= descriptor.bitsAllocated else {
                throw DicomJPEGSwiftBackendError.metadataMismatch(transferSyntaxUID: uid, reason: "codestream precision is \(inspection.precision) bits, expected \(descriptor.bitsStored)")
            }
        }
        let result: JPEGLosslessDecodeResult
        do { result = try JPEGLosslessDecoder().decode(data: frameData) } catch {
            throw DicomJPEGSwiftBackendError.codestreamRejected((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        guard result.width == descriptor.columns, result.height == descriptor.rows, result.componentCount == descriptor.samplesPerPixel else {
            throw DicomJPEGSwiftBackendError.metadataMismatch(transferSyntaxUID: uid, reason: "decoded \(result.width)x\(result.height)x\(result.componentCount), expected \(descriptor.columns)x\(descriptor.rows)x\(descriptor.samplesPerPixel)")
        }
        guard result.bitDepth <= descriptor.bitsAllocated else {
            throw DicomJPEGSwiftBackendError.metadataMismatch(transferSyntaxUID: uid, reason: "codestream precision is \(result.bitDepth) bits, above Bits Allocated \(descriptor.bitsAllocated)")
        }
        let effectiveDescriptor = result.bitDepth > descriptor.bitsStored ? DicomCompressedFrameDescriptor(
            transferSyntaxUID: descriptor.transferSyntaxUID, rows: descriptor.rows, columns: descriptor.columns,
            bitsAllocated: descriptor.bitsAllocated, bitsStored: result.bitDepth, highBit: result.bitDepth - 1,
            pixelRepresentation: descriptor.pixelRepresentation, samplesPerPixel: descriptor.samplesPerPixel,
            photometricInterpretation: descriptor.photometricInterpretation,
            planarConfiguration: descriptor.planarConfiguration) : descriptor
        var bytes: Data
        // The samples are laid out at the codestream's precision, which the frame reports: an 8-bit codestream under
        // Bits Allocated 16 yields 8-bit samples, as GDCM delivers them (issue #2856).
        if result.bitDepth > 8 {
            bytes = Data(count: result.pixels.count * 2)
            bytes.withUnsafeMutableBytes { raw in
                let target = raw.bindMemory(to: UInt16.self)
                result.pixels.withUnsafeBufferPointer { source in
                    for index in 0..<source.count { target[index] = source[index].littleEndian }
                }
            }
            bytes = DicomJLSwiftBackend.normalizedSignedData(bytes, descriptor: effectiveDescriptor)
        } else {
            bytes = Data(count: result.pixels.count)
            bytes.withUnsafeMutableBytes { raw in
                let target = raw.bindMemory(to: UInt8.self)
                result.pixels.withUnsafeBufferPointer { source in
                    for index in 0..<source.count { target[index] = UInt8(truncatingIfNeeded: source[index]) }
                }
            }
            if effectiveDescriptor.pixelRepresentation == 1, effectiveDescriptor.bitsStored < 8 {
                let mask = UInt8(truncatingIfNeeded: (1 << effectiveDescriptor.bitsStored) - 1)
                let sign = UInt8(1 << (effectiveDescriptor.bitsStored - 1))
                bytes = Data(bytes.map { ($0 & sign) != 0 ? $0 | ~mask : $0 & mask })
            }
        }
        return DicomCodecDecodedFrame(buffer: .owned(bytes), width: result.width, height: result.height,
                                      bitsPerSample: result.bitDepth, componentCount: descriptor.samplesPerPixel)
    }

    // MARK: - Encode

    func encode(_ request: DicomFrameEncodeRequest) async throws -> Data {
        try Task.checkCancellation()
        if let reason = capabilities.unsupportedReason(for: request.descriptor, operation: .encode) {
            throw DicomJPEGSwiftBackendError.unsupportedShape(transferSyntaxUID: request.targetTransferSyntaxUID, reason: reason)
        }
        let configuration = try Self.validateEncoding(descriptor: request.descriptor, targetTransferSyntaxUID: request.targetTransferSyntaxUID, intent: request.intent)
        let encoded: Data
        switch configuration {
        case .lossless(let parameters):
            encoded = try Self.encodeLossless(request.frame, descriptor: request.descriptor, parameters: parameters)
        case .dct(let jli):
            let image = try Self.image(from: request.frame, descriptor: request.descriptor)
            do { encoded = Data(try JLIEncoder().encode(image, configuration: jli)) } catch {
                throw DicomJPEGSwiftBackendError.codestreamRejected((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
        try Task.checkCancellation()
        return encoded
    }

    enum EncodingConfiguration {
        case lossless(JPEGLosslessEncodingParameters)
        case dct(JLIEncoderConfiguration)
    }

    /// Own SOF3 encoder over the stored codes (signed samples are encoded as their Bits Stored two's-complement codes).
    static func encodeLossless(_ frame: DicomCodecDecodedFrame, descriptor: DicomCompressedFrameDescriptor,
                               parameters: JPEGLosslessEncodingParameters) throws -> Data {
        let uid = descriptor.transferSyntaxUID
        let bytesPerSample = descriptor.bitsAllocated > 8 ? 2 : 1
        let count = descriptor.rows * descriptor.columns * descriptor.samplesPerPixel
        let data = frame.buffer.data
        guard data.count == count * bytesPerSample else {
            throw DicomJPEGSwiftBackendError.unsupportedShape(transferSyntaxUID: uid, reason: "frame carries \(data.count) bytes, expected \(count * bytesPerSample)")
        }
        let mask = UInt16(truncatingIfNeeded: (1 << descriptor.bitsStored) - 1)
        var samples = [UInt16](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            if bytesPerSample == 2 {
                let source = raw.bindMemory(to: UInt16.self)
                for index in 0..<count { samples[index] = UInt16(littleEndian: source[index]) & mask }
            } else {
                for index in 0..<count { samples[index] = UInt16(raw[index]) & mask }
            }
        }
        do {
            return try JPEGLosslessEncoder.encode(samples: samples, width: descriptor.columns, height: descriptor.rows,
                                                  precision: descriptor.bitsStored, componentCount: descriptor.samplesPerPixel,
                                                  parameters: parameters)
        } catch {
            throw DicomJPEGSwiftBackendError.codestreamRejected((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// Intent and shape rules per transfer syntax: baseline is 8-bit lossy, extended is 8/12-bit lossy, the lossless
    /// syntaxes are reversible predictive coding (predictor 1 for the First-Order syntax). Lossy output needs an
    /// explicit `irreversible(quality:)`; chroma is never subsampled and the colour transform is the standard YCbCr.
    static func validateEncoding(descriptor: DicomCompressedFrameDescriptor, targetTransferSyntaxUID: String,
                                 intent: DicomEncodingIntent) throws -> EncodingConfiguration {
        guard targetTransferSyntaxUID == descriptor.transferSyntaxUID else {
            throw DicomJPEGSwiftBackendError.metadataMismatch(transferSyntaxUID: targetTransferSyntaxUID,
                                                              reason: "the request descriptor names transfer syntax \(descriptor.transferSyntaxUID)")
        }
        try validateDescriptor(descriptor, operation: .encode)
        let uid = targetTransferSyntaxUID
        if losslessTransferSyntaxes.contains(uid) {
            let options: DicomJPEGLosslessEncodingOptions
            switch intent {
            case .reversible:
                options = DicomJPEGLosslessEncodingOptions()
            case .jpegLossless(let requested):
                options = requested
            case .irreversible, .jpegLSNearLossless, .jpegLS, .jpegXL:
                throw DicomJPEGSwiftBackendError.invalidEncodingIntent(transferSyntaxUID: uid, reason: "the lossless syntaxes take reversible intent or JPEG lossless predictor options")
            }
            guard (1...7).contains(options.predictor) else {
                throw DicomJPEGSwiftBackendError.invalidEncodingIntent(transferSyntaxUID: uid, reason: "predictor \(options.predictor) is outside 1...7")
            }
            if uid == DicomTransferSyntax.jpegLosslessFirstOrder.rawValue, options.predictor != 1 {
                throw DicomJPEGSwiftBackendError.invalidEncodingIntent(transferSyntaxUID: uid, reason: "JPEG Lossless SV1 (1.2.840.10008.1.2.4.70) carries predictor 1 only; use 1.2.840.10008.1.2.4.57 for predictor \(options.predictor)")
            }
            guard (0..<descriptor.bitsStored).contains(options.pointTransform) else {
                throw DicomJPEGSwiftBackendError.invalidEncodingIntent(transferSyntaxUID: uid, reason: "point transform \(options.pointTransform) must be below Bits Stored \(descriptor.bitsStored)")
            }
            guard options.restartIntervalRows >= 0, options.restartIntervalRows * descriptor.columns <= 65535 else {
                throw DicomJPEGSwiftBackendError.invalidEncodingIntent(transferSyntaxUID: uid, reason: "restart interval of \(options.restartIntervalRows) rows does not fit the DRI field for \(descriptor.columns) columns")
            }
            return .lossless(JPEGLosslessEncodingParameters(predictor: options.predictor, pointTransform: options.pointTransform,
                                                           restartIntervalRows: options.restartIntervalRows))
        }
        guard case .irreversible(let quality) = intent, quality > 0, quality <= 1 else {
            throw DicomJPEGSwiftBackendError.invalidEncodingIntent(transferSyntaxUID: uid, reason: "DCT JPEG is lossy; an explicit irreversible quality in (0, 1] is required")
        }
        if uid == DicomTransferSyntax.jpegBaseline.rawValue, descriptor.bitsStored != 8 {
            throw DicomJPEGSwiftBackendError.unsupportedShape(transferSyntaxUID: uid, reason: "JPEG Baseline (Process 1) carries 8-bit samples only")
        }
        guard descriptor.pixelRepresentation == 0 else {
            throw DicomJPEGSwiftBackendError.unsupportedShape(transferSyntaxUID: uid, reason: "DCT JPEG encoding is qualified for unsigned samples only")
        }
        var configuration = JLIEncoderConfiguration(quality: max(1, min(100, (quality * 100).rounded())), chromaSubsampling: .yuv444, colorSpace: .yCbCr,
                                                    progressive: false, restartInterval: 0, optimiseHuffman: true, adaptiveQuantization: false,
                                                    perceptualQuantTables: false)
        // PS3.5 A.4.1: the Extended syntax is Process 2 & 4, so an 8-bit frame under .51 is written as SOF1, not as a
        // Process 1 baseline frame the validator rightly refuses (issue #2487).
        configuration.extendedSequential = uid == DicomTransferSyntax.jpegExtended.rawValue
        return .dct(configuration)
    }

    static func validateDescriptor(_ descriptor: DicomCompressedFrameDescriptor, operation: DicomCodecOperation) throws {
        let uid = descriptor.transferSyntaxUID
        guard descriptor.rows > 0, descriptor.columns > 0 else {
            throw DicomJPEGSwiftBackendError.unsupportedShape(transferSyntaxUID: uid, reason: "Rows and Columns must both be positive")
        }
        guard descriptor.bitsAllocated == 8 || descriptor.bitsAllocated == 16, descriptor.bitsStored <= descriptor.bitsAllocated,
              descriptor.highBit == descriptor.bitsStored - 1 else {
            throw DicomJPEGSwiftBackendError.unsupportedShape(transferSyntaxUID: uid, reason: "Bits Allocated/Stored/High Bit must be an aligned 8- or 16-bit integer layout")
        }
        let lossless = losslessTransferSyntaxes.contains(uid)
        if !lossless {
            guard descriptor.bitsStored == 8 || descriptor.bitsStored == 12 else {
                throw DicomJPEGSwiftBackendError.unsupportedShape(transferSyntaxUID: uid, reason: "DCT JPEG carries 8- or 12-bit samples; \(descriptor.bitsStored) bits stored is not representable")
            }
            if uid == DicomTransferSyntax.jpegBaseline.rawValue, descriptor.bitsStored != 8 {
                throw DicomJPEGSwiftBackendError.unsupportedShape(transferSyntaxUID: uid, reason: "JPEG Baseline (Process 1) carries 8-bit samples only")
            }
        } else {
            guard (2...16).contains(descriptor.bitsStored) else {
                throw DicomJPEGSwiftBackendError.unsupportedShape(transferSyntaxUID: uid, reason: "lossless JPEG carries 2...16-bit samples")
            }
        }
        let photometric = descriptor.photometricInterpretation.uppercased()
        if descriptor.samplesPerPixel == 1 {
            guard photometric.isEmpty || photometric == "MONOCHROME1" || photometric == "MONOCHROME2" || photometric == "PALETTE COLOR" else {
                throw DicomJPEGSwiftBackendError.unsupportedShape(transferSyntaxUID: uid, reason: "single-component JPEG does not accept \(descriptor.photometricInterpretation)")
            }
        } else {
            guard descriptor.samplesPerPixel == 3, descriptor.bitsAllocated == 8, descriptor.pixelRepresentation == 0 else {
                throw DicomJPEGSwiftBackendError.unsupportedShape(transferSyntaxUID: uid, reason: "three-component JPEG is qualified for unsigned 8-bit samples only")
            }
            if lossless {
                guard photometric == "RGB" else {
                    throw DicomJPEGSwiftBackendError.unsupportedShape(transferSyntaxUID: uid, reason: "lossless colour JPEG is qualified for RGB only (no colour transform)")
                }
            } else {
                // DCT colour carries YCbCr (PS3.5 8.2.1); output is converted to RGB explicitly by the decoder.
                let accepted: Set<String> = operation == .decode ? ["YBR_FULL", "YBR_FULL_422"] : ["YBR_FULL", "YBR_FULL_422", "RGB"]
                guard accepted.contains(photometric) else {
                    throw DicomJPEGSwiftBackendError.unsupportedShape(transferSyntaxUID: uid, reason: "DCT colour JPEG is qualified for YBR_FULL/YBR_FULL_422 (\(descriptor.photometricInterpretation) has no unambiguous transform)")
                }
            }
        }
    }

    private static func image(from frame: DicomCodecDecodedFrame, descriptor: DicomCompressedFrameDescriptor) throws -> JLIImage {
        let uid = descriptor.transferSyntaxUID
        let bytesPerSample = descriptor.bitsAllocated > 8 ? 2 : 1
        let expected = descriptor.rows * descriptor.columns * descriptor.samplesPerPixel * bytesPerSample
        let data = frame.buffer.data
        guard data.count == expected else {
            throw DicomJPEGSwiftBackendError.unsupportedShape(transferSyntaxUID: uid, reason: "frame carries \(data.count) bytes, expected \(expected)")
        }
        var bytes = [UInt8](data)
        if bytesPerSample == 2, descriptor.bitsStored < 16 {
            // Mask unused high bits so the codestream carries exactly Bits Stored.
            let mask = UInt16((1 << descriptor.bitsStored) - 1)
            for index in stride(from: 0, to: bytes.count, by: 2) {
                let value = (UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8) & mask
                bytes[index] = UInt8(value & 0xFF); bytes[index + 1] = UInt8(value >> 8)
            }
        }
        return try JLIImage(width: descriptor.columns, height: descriptor.rows, pixelFormat: bytesPerSample == 2 ? .uint16 : .uint8,
                            colorModel: descriptor.samplesPerPixel == 3 ? .rgb : .grayscale, data: bytes, isSigned: false)
    }
}
