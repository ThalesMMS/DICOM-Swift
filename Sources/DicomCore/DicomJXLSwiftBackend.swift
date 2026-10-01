//
//  DicomJXLSwiftBackend.swift
//  DicomCore
//
//  JPEG XL frame backend on the vendored DicomJPEGXL codec (issue #2332).
//  The Modular lossless subset (.110 and the reversible route of .112) is
//  coded by the own reference-exact Modular core: Bits Stored 1...16 in 8-
//  or 16-bit containers, signed samples through a reversible level shift
//  driven by Pixel Representation (never inferred from the codestream),
//  MONOCHROME1/2 and interleaved RGB, and the DICOM ICC Profile carried
//  inside the codestream as a passthrough (no colorimetric application).
//  The irreversible .112 VarDCT route and the .111 JPEG recompression
//  bridge keep the vendored JXLSwift paths.
//

import DicomJPEGXL
import Foundation

extension DicomCodecBackendIdentifier {
    static let jxlSwift: Self = "jxlswift"
}

struct DicomJXLSwiftBackend: DicomFrameCodecBackend {
    static let version = "1.4.0-vendored"
    static let maximumDimension = 16_384
    static let maximumVarDCTDimension = 8_192
    static let maximumCompressedFrameBytes = 512 * 1_024 * 1_024
    /// Decoded samples per frame (1 GiB of 16-bit containers).
    static let maximumDecodedSamples = 512 * 1_024 * 1_024
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
        supportedGrayscaleBitDepths: 1...16,
        // The codec codes RGB up to 16 bits, but the decoded-frame contract of
        // DicomDecodedFrameReader carries interleaved RGB8 only (as for the
        // other own backends); colour above 8 bits stays a typed refusal.
        supportedColorBitDepths: 8...8,
        maximumComponents: 3,
        supportsSignedSamples: true,
        executionClass: .cpu,
        source: .packageLinked,
        version: version
    )

    // MARK: - Decode

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
        let frameData: Data
        do {
            frameData = try Self.decodingInput(request.frameData) { data in
                _ = try decoder.inspect(data)
            }
        } catch let error as DecoderError {
            throw Self.mapDecoderError(error, transferSyntaxUID: request.descriptor.transferSyntaxUID)
        } catch {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: request.descriptor.transferSyntaxUID,
                reason: "the frame is not a JPEG XL codestream or container: \(error)"
            )
        }
        let structure = decoder.inspectFrameStructure(frameData)
        let general = structure.encoding == .varDCT || decoder.requiresGeneralDecode(frameData)
        if request.descriptor.transferSyntaxUID == DicomTransferSyntax.jpegXLLossless.rawValue, general {
            throw DicomJXLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: request.descriptor.transferSyntaxUID,
                reason: "the lossless-only transfer syntax does not contain a reversible Modular frame"
            )
        }
        if general {
            // VarDCT, progressive DC sequences and XYB Modular frames take the
            // general decoder; the image header must agree with the descriptor
            // before anything is allocated.
            let header = try decoder.inspect(frameData)
            guard Int(header.xsize) == request.descriptor.columns, Int(header.ysize) == request.descriptor.rows else {
                throw DicomJXLSwiftBackendError.metadataMismatch(
                    transferSyntaxUID: request.descriptor.transferSyntaxUID,
                    reason: "codestream dimensions \(header.xsize)x\(header.ysize) do not match the DICOM descriptor "
                        + "\(request.descriptor.columns)x\(request.descriptor.rows)"
                )
            }
            let image: ImageFrame
            do {
                image = try await decoder.decode(frameData)
            } catch let error as DecoderError {
                throw Self.mapDecoderError(error, transferSyntaxUID: request.descriptor.transferSyntaxUID)
            }
            try Task.checkCancellation()
            return try Self.decodedFrame(
                from: image, descriptor: request.descriptor,
                codedBits: Int(header.metadata?.bitDepth.bitsPerSample ?? 0))
        }
        let frame: MDModularFrame
        do {
            frame = try decoder.decodeModularFrame(
                frameData,
                expectedSize: (request.descriptor.columns, request.descriptor.rows),
                maximumSamples: Self.maximumDecodedSamples
            )
        } catch let error as DecoderError {
            throw Self.mapDecoderError(error, transferSyntaxUID: request.descriptor.transferSyntaxUID)
        }
        try Task.checkCancellation()
        return try Self.decodedFrame(from: frame, descriptor: request.descriptor)
    }

    /// Facts about a JPEG XL frame that validators and reports use.
    struct ModularInspection: Equatable, Sendable {
        let width: Int
        let height: Int
        let bitsPerSample: Int
        let colourChannels: Int
        let extraChannels: Int
        let isModular: Bool
        let hasEmbeddedICCProfile: Bool
        let embeddedICCProfileByteCount: Int
    }

    /// Inspects a JPEG XL frame (headers only for VarDCT; full decode of
    /// the header layer for Modular) without producing pixels.
    static func inspectFrame(_ data: Data) throws -> ModularInspection {
        let decoder = JXLDecoder()
        let input = try decodingInput(data) { candidate in _ = try decoder.inspect(candidate) }
        let inspection = try decoder.inspect(input)
        guard let metadata = inspection.metadata else {
            throw DicomJXLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: "", reason: "the JPEG XL image metadata could not be parsed"
            )
        }
        let structure = decoder.inspectFrameStructure(input)
        var colour = metadata.colorEncoding.colorSpace == .grayscale ? 1 : 3
        var iccBytes = 0
        if metadata.colorEncoding.useICC, structure.encoding == .modular,
           let frame = try? decoder.decodeModularFrame(input) {
            colour = frame.colourChannels
            iccBytes = frame.iccProfile?.count ?? 0
        }
        return ModularInspection(
            width: Int(inspection.xsize),
            height: Int(inspection.ysize),
            bitsPerSample: Int(metadata.bitDepth.bitsPerSample),
            colourChannels: colour,
            extraChannels: metadata.extraChannels.count,
            isModular: structure.encoding == .modular,
            hasEmbeddedICCProfile: metadata.colorEncoding.useICC,
            embeddedICCProfileByteCount: iccBytes
        )
    }

    // MARK: - Encode

    func encode(_ request: DicomFrameEncodeRequest) async throws -> Data {
        try Task.checkCancellation()
        if let reason = capabilities.unsupportedReason(for: request.descriptor, operation: .encode) {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: request.targetTransferSyntaxUID,
                reason: reason
            )
        }
        let route = try Self.validateEncoding(
            descriptor: request.descriptor,
            targetTransferSyntaxUID: request.targetTransferSyntaxUID,
            intent: request.intent
        )
        switch route {
        case .modularLossless(let effort):
            if let icc = request.iccProfile {
                try Self.validateICCProfile(icc, samplesPerPixel: request.descriptor.samplesPerPixel,
                                            transferSyntaxUID: request.targetTransferSyntaxUID)
            }
            let planes = try Self.planes(from: request)
            do {
                let encoded = try SpecModularEncoder.encodePlanes(
                    width: request.descriptor.columns,
                    height: request.descriptor.rows,
                    planes: planes,
                    bitsPerSample: UInt32(request.descriptor.bitsStored),
                    iccProfile: request.iccProfile,
                    applyRCT: true,
                    effort: effort
                )
                try Task.checkCancellation()
                return encoded.codestream
            } catch let error as SpecModularEncoderError {
                throw DicomJXLSwiftBackendError.unsupportedShape(
                    transferSyntaxUID: request.targetTransferSyntaxUID,
                    reason: "\(error)"
                )
            }
        case .varDCT(let options):
            guard request.iccProfile == nil else {
                throw DicomJXLSwiftBackendError.unsupportedShape(
                    transferSyntaxUID: request.targetTransferSyntaxUID,
                    reason: "the irreversible route does not carry an ICC profile"
                )
            }
            let sourceImage = try Self.image(from: request)
            let image = sourceImage.pixelType == .int16 ? sourceImage.levelShiftedToUnsigned16() : sourceImage
            let encoded = try VarDCTBitstreamWriter.encode(frame: image, distance: options.distance,
                gaborish: options.gaborish, adaptiveQF: options.adaptiveQF, bitsPerSample: request.descriptor.bitsStored,
                effort: options.effort.rawValue)
            try Task.checkCancellation()
            return encoded
        }
    }

    enum EncodeRoute: Equatable {
        case modularLossless(effort: Int)
        case varDCT(EncodingOptions)

        static func == (lhs: EncodeRoute, rhs: EncodeRoute) -> Bool {
            switch (lhs, rhs) {
            case (.modularLossless(let a), .modularLossless(let b)): return a == b
            case (.varDCT(let a), .varDCT(let b)):
                return a.distance == b.distance && a.gaborish == b.gaborish && a.adaptiveQF == b.adaptiveQF
                    && a.effort == b.effort
            default: return false
            }
        }
    }

    /// The Modular encoder's effort scale (libjxl 1...9).
    static let modularEffortRange = 1...9

    /// `DicomEncodingIntent.jpegXL(options:)` → route, with the PS3.5
    /// shape rules of `validateDescriptor` already applied.
    private static func route(
        for options: DicomJPEGXLEncodingOptions,
        descriptor: DicomCompressedFrameDescriptor,
        targetTransferSyntaxUID: String
    ) throws -> EncodeRoute {
        guard options.distance.isFinite, options.distance >= 0,
              options.distance <= DicomJPEGXLEncodingOptions.maximumDistance else {
            throw DicomJXLSwiftBackendError.invalidEncodingIntent(
                transferSyntaxUID: targetTransferSyntaxUID,
                reason: "the JPEG XL distance must be finite and within 0...\(DicomJPEGXLEncodingOptions.maximumDistance); got \(options.distance)"
            )
        }
        guard modularEffortRange.contains(options.effort) else {
            throw DicomJXLSwiftBackendError.invalidEncodingIntent(
                transferSyntaxUID: targetTransferSyntaxUID,
                reason: "the JPEG XL effort must be within 1...9; got \(options.effort)"
            )
        }
        if options.distance == 0 {
            return .modularLossless(effort: options.effort)
        }
        guard targetTransferSyntaxUID == DicomTransferSyntax.jpegXL.rawValue else {
            throw DicomJXLSwiftBackendError.invalidEncodingIntent(
                transferSyntaxUID: targetTransferSyntaxUID,
                reason: "a non-zero distance is irreversible; JPEG XL Lossless (.110) requires distance 0"
            )
        }
        try validateVarDCTShape(descriptor, targetTransferSyntaxUID: targetTransferSyntaxUID)
        return .varDCT(EncodingOptions(
            mode: .distance(Float(options.distance)),
            effort: EncodingEffort(rawValue: options.effort) ?? .squirrel,
            containerWrap: false,
            gaborish: options.gaborish,
            adaptiveQF: options.adaptiveQuantization
        ))
    }

    /// Dimension and memory limits of the VarDCT route.
    private static func validateVarDCTShape(
        _ descriptor: DicomCompressedFrameDescriptor, targetTransferSyntaxUID: String
    ) throws {
        guard descriptor.rows <= maximumVarDCTDimension, descriptor.columns <= maximumVarDCTDimension else {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: targetTransferSyntaxUID,
                reason: "irreversible VarDCT encoding is limited to \(maximumVarDCTDimension) pixels per dimension"
            )
        }
        let samples = descriptor.rows.multipliedReportingOverflow(by: descriptor.columns)
        let total = samples.partialValue.multipliedReportingOverflow(by: descriptor.samplesPerPixel)
        guard !samples.overflow, !total.overflow, total.partialValue <= maximumDecodedSamples else {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: targetTransferSyntaxUID,
                reason: "irreversible VarDCT encoding is limited to \(maximumDecodedSamples) samples per frame"
            )
        }
        guard descriptor.bitsStored == descriptor.bitsAllocated || (descriptor.bitsStored == 12 && descriptor.bitsAllocated == 16),
              descriptor.bitsAllocated == 8 || descriptor.bitsAllocated == 16,
              descriptor.pixelRepresentation == 0 || descriptor.bitsAllocated == 16,
              descriptor.samplesPerPixel == 1 || descriptor.bitsAllocated == 8 else {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: targetTransferSyntaxUID,
                reason: "the irreversible VarDCT route accepts 8/12/16-bit grayscale and RGB8 only"
            )
        }
    }

    static func validateEncoding(
        descriptor: DicomCompressedFrameDescriptor,
        targetTransferSyntaxUID: String,
        intent: DicomEncodingIntent
    ) throws -> EncodeRoute {
        guard targetTransferSyntaxUID == descriptor.transferSyntaxUID else {
            throw DicomJXLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: targetTransferSyntaxUID,
                reason: "the request descriptor names transfer syntax \(descriptor.transferSyntaxUID)"
            )
        }
        try validateDescriptor(descriptor)
        switch (targetTransferSyntaxUID, intent) {
        case (DicomTransferSyntax.jpegXLLossless.rawValue, .reversible),
             (DicomTransferSyntax.jpegXL.rawValue, .reversible):
            return .modularLossless(effort: 7)
        case (DicomTransferSyntax.jpegXLLossless.rawValue, .jpegXL(let options)),
             (DicomTransferSyntax.jpegXL.rawValue, .jpegXL(let options)):
            return try route(for: options, descriptor: descriptor, targetTransferSyntaxUID: targetTransferSyntaxUID)
        case (DicomTransferSyntax.jpegXL.rawValue, .irreversible(let quality))
            where quality > 0 && quality < 1 && quality.isFinite:
            try validateVarDCTShape(descriptor, targetTransferSyntaxUID: targetTransferSyntaxUID)
            return .varDCT(EncodingOptions(mode: .lossy(quality: Float(quality * 100)), containerWrap: false))
        case (DicomTransferSyntax.jpegXL.rawValue, .irreversible(let quality)):
            throw DicomJXLSwiftBackendError.invalidEncodingIntent(
                transferSyntaxUID: targetTransferSyntaxUID,
                reason: "irreversible quality must be finite and strictly between zero and one; got \(quality)"
            )
        case (DicomTransferSyntax.jpegXLLossless.rawValue, _):
            throw DicomJXLSwiftBackendError.invalidEncodingIntent(
                transferSyntaxUID: targetTransferSyntaxUID,
                reason: "the lossless-only syntax requires reversible intent"
            )
        default:
            throw DicomJXLSwiftBackendError.invalidEncodingIntent(
                transferSyntaxUID: targetTransferSyntaxUID,
                reason: "the raster adapter supports only JPEG XL Lossless and JPEG XL"
            )
        }
    }

    // MARK: - JPEG recompression bridge

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
        try Task.checkCancellation()
        // The reconstructed JPEG decodes through the same own JPEG backend
        // as a `.50`/`.51` object, so `.111` and its source agree pixel
        // for pixel.
        let process = Self.jpegProcess(of: jpeg)
        let syntax: DicomTransferSyntax
        switch process {
        case 0xC0, 0xC2: syntax = .jpegBaseline
        case 0xC1: syntax = .jpegExtended
        default:
            throw DicomJXLSwiftBackendError.jpegRecompressionFailed(
                reason: "the reconstructed JPEG uses process 0x\(String(process, radix: 16)); only SOF0/SOF1/SOF2 decode")
        }
        var descriptor = request.descriptor
        descriptor = DicomCompressedFrameDescriptor(
            transferSyntaxUID: syntax.rawValue, rows: descriptor.rows, columns: descriptor.columns,
            bitsAllocated: 8, bitsStored: 8, highBit: 7, pixelRepresentation: 0,
            samplesPerPixel: descriptor.samplesPerPixel,
            photometricInterpretation: descriptor.photometricInterpretation,
            planarConfiguration: descriptor.planarConfiguration)
        do {
            return try DicomJPEGSwiftBackend.decodeSynchronously(jpeg, descriptor: descriptor)
        } catch {
            throw DicomJXLSwiftBackendError.jpegRecompressionFailed(
                reason: "the reconstructed JPEG frame could not be decoded: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            )
        }
    }

    /// The SOFn marker byte of a JPEG interchange stream (0 when absent).
    static func jpegProcess(of jpeg: Data) -> UInt8 {
        var i = jpeg.startIndex + 2
        while i + 3 < jpeg.endIndex {
            guard jpeg[i] == 0xFF else { i += 1; continue }
            let marker = jpeg[i + 1]
            if marker == 0xFF { i += 1; continue }
            if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC { return marker }
            if marker == 0xDA || marker == 0xD9 { return 0 }
            if (0xD0...0xD8).contains(marker) || marker == 0x01 { i += 2; continue }
            let length = Int(jpeg[i + 2]) << 8 | Int(jpeg[i + 3])
            i += 2 + length
        }
        return 0
    }

    // MARK: - Descriptor rules (PS3.5 Table 8.2.15-1)

    static func validateDescriptor(_ descriptor: DicomCompressedFrameDescriptor) throws {
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
        let photometric = descriptor.photometricInterpretation.uppercased()
        if uid == DicomTransferSyntax.jpegXLJPEGRecompression.rawValue {
            let monochrome = descriptor.samplesPerPixel == 1 && photometric == "MONOCHROME2"
            let color = descriptor.samplesPerPixel == 3
                && ["RGB", "YBR_FULL_422"].contains(photometric)
                && descriptor.planarConfiguration == 0
            guard descriptor.bitsAllocated == 8,
                  descriptor.bitsStored == 8,
                  descriptor.highBit == 7,
                  descriptor.pixelRepresentation == 0,
                  monochrome || color else {
                throw DicomJXLSwiftBackendError.unsupportedShape(
                    transferSyntaxUID: uid,
                    reason: "JPEG recompression is qualified only for unsigned JPEG Baseline 8-bit MONOCHROME2 or RGB/YBR_FULL_422"
                )
            }
            return
        }
        guard descriptor.bitsAllocated == 8 || descriptor.bitsAllocated == 16 else {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: uid,
                reason: "Bits Allocated must be 8 or 16 (1-bit and 24-bit containers are outside the own frame model)"
            )
        }
        guard descriptor.bitsStored >= 1,
              descriptor.bitsStored <= descriptor.bitsAllocated,
              descriptor.highBit == descriptor.bitsStored - 1 else {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: uid,
                reason: "Bits Stored must be 1...Bits Allocated with High Bit = Bits Stored - 1"
            )
        }
        guard descriptor.pixelRepresentation == 0 || descriptor.pixelRepresentation == 1 else {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: uid,
                reason: "Pixel Representation must be 0 or 1"
            )
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
                  descriptor.bitsStored == 8,
                  descriptor.bitsAllocated == 8,
                  descriptor.pixelRepresentation == 0,
                  photometric == "RGB",
                  descriptor.planarConfiguration == 0 else {
                throw DicomJXLSwiftBackendError.unsupportedShape(
                    transferSyntaxUID: uid,
                    reason: "multi-component JPEG XL is qualified for unsigned interleaved RGB8 (Planar Configuration 0); the frame reader carries no colour above 8 bits"
                )
            }
        }
    }

    /// An embedded profile decides the codestream's channel count (ISO/IEC
    /// 18181-1 C.3.4: a GRAY profile means one colour channel), so its
    /// colour space must agree with Samples per Pixel.
    static func validateICCProfile(_ icc: Data, samplesPerPixel: Int, transferSyntaxUID: String) throws {
        guard icc.count >= 128 else {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: transferSyntaxUID,
                reason: "ICC Profile (0028,2000) is shorter than the 128-byte ICC header"
            )
        }
        let space = String(decoding: icc[(icc.startIndex + 16)..<(icc.startIndex + 20)], as: UTF8.self)
        switch (space, samplesPerPixel) {
        case ("GRAY", 1), ("RGB ", 3):
            return
        default:
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: transferSyntaxUID,
                reason: "ICC Profile colour space '\(space)' does not match Samples per Pixel \(samplesPerPixel) (GRAY expects 1, RGB expects 3)"
            )
        }
    }

    // MARK: - Sample packing

    /// Unpacks the stored-pixel container into integer planes coded as
    /// unsigned `bitsStored`-bit samples (signed samples are level-shifted
    /// by `2^(bitsStored - 1)`, which the decoder reverses from Pixel
    /// Representation alone).
    private static func planes(from request: DicomFrameEncodeRequest) throws -> [[Int32]] {
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
        let bytes = frame.buffer.data
        guard bytes.count == expectedBytes else {
            throw DicomJXLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: request.targetTransferSyntaxUID,
                reason: "the input frame contains \(bytes.count) bytes, expected \(expectedBytes)"
            )
        }
        let count = descriptor.rows * descriptor.columns
        let components = descriptor.samplesPerPixel
        let bits = descriptor.bitsStored
        let signed = descriptor.pixelRepresentation == 1
        let shift: Int32 = signed ? Int32(1) << Int32(bits - 1) : 0
        let low: Int32 = signed ? -shift : 0
        let high: Int32 = signed ? shift - 1 : (Int32(1) << Int32(bits)) - 1
        var planes = [[Int32]](repeating: [Int32](repeating: 0, count: count), count: components)
        var outOfRange = 0
        try bytes.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<count {
                for c in 0..<components {
                    let index = i * components + c
                    var value: Int32
                    if descriptor.bitsAllocated == 8 {
                        let v = p[index]
                        value = signed ? Int32(Int8(bitPattern: v)) : Int32(v)
                    } else {
                        let v = UInt16(p[index * 2]) | (UInt16(p[index * 2 + 1]) << 8)
                        value = signed ? Int32(Int16(bitPattern: v)) : Int32(v)
                    }
                    if value < low || value > high {
                        outOfRange += 1
                        if outOfRange == 1 {
                            throw DicomJXLSwiftBackendError.metadataMismatch(
                                transferSyntaxUID: request.targetTransferSyntaxUID,
                                reason: "sample \(value) at index \(i) exceeds the \(bits)-bit Bits Stored range \(low)...\(high)"
                            )
                        }
                    }
                    planes[c][i] = value &+ shift
                }
            }
        }
        return planes
    }

    private static func decodedFrame(
        from frame: MDModularFrame,
        descriptor: DicomCompressedFrameDescriptor
    ) throws -> DicomCodecDecodedFrame {
        let uid = descriptor.transferSyntaxUID
        guard frame.width == descriptor.columns, frame.height == descriptor.rows else {
            throw DicomJXLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "codestream dimensions \(frame.width)x\(frame.height) do not match Rows/Columns \(descriptor.rows)x\(descriptor.columns)"
            )
        }
        guard frame.colourChannels == descriptor.samplesPerPixel else {
            throw DicomJXLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "codestream carries \(frame.colourChannels) colour channel(s) but Samples per Pixel is \(descriptor.samplesPerPixel)"
            )
        }
        guard frame.metadata.extraChannels.isEmpty else {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: uid,
                reason: "extra channels (alpha, depth, spot colours) are not admissible in the DICOM profile"
            )
        }
        let bits = Int(frame.metadata.bitDepth.bitsPerSample)
        guard bits == descriptor.bitsStored else {
            throw DicomJXLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "codestream declares \(bits)-bit samples but Bits Stored is \(descriptor.bitsStored)"
            )
        }
        let expectedBytes = try checkedByteCount(descriptor)
        let count = frame.width * frame.height
        let components = descriptor.samplesPerPixel
        let signed = descriptor.pixelRepresentation == 1
        let shift: Int32 = signed ? Int32(1) << Int32(bits - 1) : 0
        let maxCoded: Int32 = (Int32(1) << Int32(bits)) - 1
        var out = Data(count: expectedBytes)
        try out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for c in 0..<components {
                try frame.planes[c].withUnsafeBufferPointer { plane in
                    for i in 0..<count {
                        let coded = plane[i]
                        guard coded >= 0, coded <= maxCoded else {
                            throw DicomJXLSwiftBackendError.metadataMismatch(
                                transferSyntaxUID: uid,
                                reason: "decoded sample \(coded) exceeds the declared \(bits)-bit range"
                            )
                        }
                        let value = coded &- shift
                        let index = i * components + c
                        if descriptor.bitsAllocated == 8 {
                            p[index] = UInt8(truncatingIfNeeded: value)
                        } else {
                            let v = UInt16(truncatingIfNeeded: value)
                            p[index * 2] = UInt8(v & 0xFF)
                            p[index * 2 + 1] = UInt8(v >> 8)
                        }
                    }
                }
            }
        }
        return DicomCodecDecodedFrame(
            buffer: .owned(out),
            width: frame.width,
            height: frame.height,
            bitsPerSample: descriptor.bitsStored,
            componentCount: components
        )
    }

    // MARK: - VarDCT legacy paths

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
        if descriptor.bitsStored == 12 {
            let samples = try planes(from: request)[0]
            var image = ImageFrame(width: descriptor.columns, height: descriptor.rows, channels: 1,
                                   pixelType: .uint16, colorSpace: .grayscale)
            for (index, value) in samples.enumerated() {
                image.data[index * 2] = UInt8(truncatingIfNeeded: value)
                image.data[index * 2 + 1] = UInt8(truncatingIfNeeded: value >> 8)
            }
            return image
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

    /// VarDCT / XYB output (`ImageFrame` at the codestream bit depth) into the
    /// frame contract: Bits Stored equals the coded depth, samples stay within
    /// the declared range, signed samples take the same reversible
    /// `2^(Bits Stored − 1)` level shift as the Modular route.
    private static func decodedFrame(
        from image: ImageFrame,
        descriptor: DicomCompressedFrameDescriptor,
        codedBits: Int
    ) throws -> DicomCodecDecodedFrame {
        let uid = descriptor.transferSyntaxUID
        guard image.width == descriptor.columns,
              image.height == descriptor.rows,
              image.channels == descriptor.samplesPerPixel else {
            throw DicomJXLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "codestream dimensions or component count do not match the DICOM descriptor"
            )
        }
        guard codedBits == descriptor.bitsStored else {
            throw DicomJXLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "codestream declares \(codedBits)-bit samples but Bits Stored is \(descriptor.bitsStored)"
            )
        }
        let expectedType: PixelType = descriptor.bitsAllocated == 8 ? .uint8 : .uint16
        guard image.pixelType == expectedType else {
            throw DicomJXLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "codestream pixel type \(image.pixelType) does not match the DICOM sample representation"
            )
        }
        let expectedBytes = try checkedByteCount(descriptor)
        guard image.data.count == expectedBytes else {
            throw DicomJXLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "decoded byte count is \(image.data.count), expected \(expectedBytes)"
            )
        }
        let bits = descriptor.bitsStored
        let signed = descriptor.pixelRepresentation == 1
        let maxCoded = (1 << bits) - 1
        let shift = signed ? (1 << (bits - 1)) : 0
        var data = Data(image.data)
        try data.withUnsafeMutableBytes { raw in
            if descriptor.bitsAllocated == 8 {
                let p = raw.bindMemory(to: UInt8.self)
                for i in 0..<p.count {
                    guard Int(p[i]) <= maxCoded else {
                        throw DicomJXLSwiftBackendError.metadataMismatch(
                            transferSyntaxUID: uid, reason: "decoded sample \(p[i]) exceeds the declared \(bits)-bit range")
                    }
                    p[i] = p[i] &- UInt8(truncatingIfNeeded: shift)
                }
            } else {
                let p = raw.bindMemory(to: UInt16.self)
                for i in 0..<p.count {
                    let v = UInt16(littleEndian: p[i])
                    guard Int(v) <= maxCoded else {
                        throw DicomJXLSwiftBackendError.metadataMismatch(
                            transferSyntaxUID: uid, reason: "decoded sample \(v) exceeds the declared \(bits)-bit range")
                    }
                    p[i] = (v &- UInt16(truncatingIfNeeded: shift)).littleEndian
                }
            }
        }
        return DicomCodecDecodedFrame(
            buffer: .owned(data),
            width: image.width,
            height: image.height,
            bitsPerSample: descriptor.bitsStored,
            componentCount: image.channels
        )
    }

    private static func mapDecoderError(_ error: DecoderError, transferSyntaxUID: String) -> Error {
        DicomJXLSwiftBackendError.unsupportedShape(
            transferSyntaxUID: transferSyntaxUID,
            reason: error.errorDescription ?? "\(error)"
        )
    }

    private static func checkedByteCount(_ descriptor: DicomCompressedFrameDescriptor) throws -> Int {
        let pixels = descriptor.rows.multipliedReportingOverflow(by: descriptor.columns)
        let samples = pixels.partialValue.multipliedReportingOverflow(by: descriptor.samplesPerPixel)
        let bytes = samples.partialValue.multipliedReportingOverflow(by: descriptor.bitsAllocated / 8)
        guard !pixels.overflow, !samples.overflow, !bytes.overflow,
              samples.partialValue <= maximumDecodedSamples else {
            throw DicomJXLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: descriptor.transferSyntaxUID,
                reason: "the frame dimensions exceed the addressable sample range"
            )
        }
        return bytes.partialValue
    }

    static func decodingInput(
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
