//
//  DicomJLSwiftBackend.swift
//  DicomCore
//
//  Own JPEG-LS backend on the vendored DicomJPEGLS target (Raster-Lab JLSwift 0.9.1 core, #2328). JLSwift types
//  stay behind the neutral compressed-frame contract; interleave, NEAR, restart intervals and the DICOM
//  constraints of PS3.5 8.2.3 (no colour transformation, no mapping tables, Planar Configuration 0) are decided here.
//

import Foundation
import DicomJPEGLS
import Synchronization

extension DicomCodecBackendIdentifier {
    static let jlSwift: Self = "jlswift"
    static let charLSCPU: Self = "charls-jpeg-ls"
}

enum DicomJLSwiftBackendError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedShape(transferSyntaxUID: String, reason: String)
    case metadataMismatch(transferSyntaxUID: String, reason: String)
    case invalidEncodingIntent(transferSyntaxUID: String, reason: String)
    case codestreamRejected(transferSyntaxUID: String, reason: String)
    case nearLosslessBoundExceeded(transferSyntaxUID: String, near: Int, observed: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedShape(let uid, let reason):
            return "JLSwift does not support JPEG-LS transfer syntax \(uid): \(reason)"
        case .metadataMismatch(let uid, let reason):
            return "JLSwift output does not match DICOM metadata for transfer syntax \(uid): \(reason)"
        case .invalidEncodingIntent(let uid, let reason):
            return "Invalid JPEG-LS encoding intent for transfer syntax \(uid): \(reason)"
        case .codestreamRejected(let uid, let reason):
            return "JPEG-LS codestream rejected for transfer syntax \(uid): \(reason)"
        case .nearLosslessBoundExceeded(let uid, let near, let observed):
            return "JPEG-LS near-lossless output for transfer syntax \(uid) exceeds NEAR=\(near) after signed normalisation "
                + "(observed error \(observed)): the two's-complement codes wrap at the sign boundary, so signed near-lossless "
                + "encoding is refused for this frame"
        }
    }
}

struct DicomJLSwiftBackend: DicomFrameCodecBackend {
    static let version = "0.9.1-vendored"
    static let transferSyntaxes: Set<String> = [
        DicomTransferSyntax.jpegLSLossless.rawValue,
        DicomTransferSyntax.jpegLSNearLossless.rawValue
    ]

    let capabilities = DicomFrameCodecCapabilities(
        identifier: .jlSwift,
        families: [.jpegLS],
        transferSyntaxUIDs: transferSyntaxes,
        encodeTransferSyntaxUIDs: transferSyntaxes,
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
            throw DicomJLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: request.descriptor.transferSyntaxUID,
                reason: reason
            )
        }
        let cancelled = Mutex(false)
        return try await withTaskCancellationHandler {
            let frame = try Self.decodeSynchronously(request.frameData, descriptor: request.descriptor) {
                if cancelled.withLock({ $0 }) { throw CancellationError() }
                try Task.checkCancellation()
            }
            try Task.checkCancellation()
            return frame
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// Full decode through the vendored core; used by the asynchronous frame reader and the synchronous pixel reader.
    static func decodeSynchronously(
        _ frameData: Data, descriptor: DicomCompressedFrameDescriptor,
        checkCancellation: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DicomCodecDecodedFrame {
        try checkCancellation()
        try validateDescriptor(descriptor)
        let uid = descriptor.transferSyntaxUID
        let parseResult: JPEGLSParseResult
        do { parseResult = try JPEGLSParser(data: frameData).parse() } catch {
            throw DicomJLSwiftBackendError.codestreamRejected(transferSyntaxUID: uid, reason: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        let near = parseResult.scanHeaders.first?.near ?? 0
        try validateNear(near, transferSyntaxUID: uid)
        // PS3.5 8.2.3: no JPEG-LS colour transformation (ISO/IEC 14495-2) is defined in DICOM and mapping tables have
        // no photometric counterpart; both are refused rather than silently applied.
        guard parseResult.colorTransformation == .none else {
            throw DicomJLSwiftBackendError.codestreamRejected(transferSyntaxUID: uid, reason: "an ISO/IEC 14495-2 colour transformation (\(parseResult.colorTransformation)) is not defined for DICOM JPEG-LS")
        }
        guard parseResult.mappingTables.isEmpty else {
            throw DicomJLSwiftBackendError.codestreamRejected(transferSyntaxUID: uid, reason: "JPEG-LS mapping tables have no DICOM photometric counterpart")
        }
        let header = parseResult.frameHeader
        let effective = try effectiveDescriptor(for: header, componentCount: header.componentCount, descriptor: descriptor)
        let decoder = JPEGLSDecoder(checkCancellation: checkCancellation)
        do {
            guard descriptor.samplesPerPixel == 1 else {
                return try normalizedFrame(from: try decoder.decode(frameData), descriptor: descriptor)
            }
            // Grey frames decode straight into the frame buffer, sign-extended row by row (#2903).
            _ = try checkedPixelCount(effective)
            let samples: Data
            if effective.bitsAllocated == 8 {
                samples = try decoder.decodeSingleComponent(frameData, as: UInt8.self).samples
            } else {
                samples = try decoder.decodeSingleComponent(frameData, as: UInt16.self,
                                                            finishRow: signExtension(for: effective)).samples
            }
            return DicomCodecDecodedFrame(buffer: .owned(samples), width: header.width, height: header.height,
                                          bitsPerSample: header.bitsPerSample, componentCount: 1)
        } catch is CancellationError { throw CancellationError() }
        catch let error as DicomJLSwiftBackendError { throw error }
        catch {
            throw DicomJLSwiftBackendError.codestreamRejected(transferSyntaxUID: uid, reason: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// Two's-complement extension of Bits Stored < 16 signed samples, as `normalizedSignedData` does to a buffer.
    private static func signExtension(
        for descriptor: DicomCompressedFrameDescriptor
    ) -> (@Sendable (UnsafeMutableBufferPointer<UInt16>) -> Void)? {
        guard descriptor.pixelRepresentation == 1, descriptor.bitsStored < 16 else { return nil }
        let valueMask = UInt16((1 << descriptor.bitsStored) - 1)
        let signBit = UInt16(1 << (descriptor.bitsStored - 1))
        return { row in
            for index in row.indices {
                let value = row[index] & valueMask
                row[index] = value & signBit != 0 ? value | ~valueMask : value
            }
        }
    }

    func encode(_ request: DicomFrameEncodeRequest) async throws -> Data {
        try Task.checkCancellation()
        if let reason = capabilities.unsupportedReason(for: request.descriptor, operation: .encode) {
            throw DicomJLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: request.targetTransferSyntaxUID,
                reason: reason
            )
        }
        let parameters = try Self.validateEncoding(
            descriptor: request.descriptor,
            targetTransferSyntaxUID: request.targetTransferSyntaxUID,
            intent: request.intent
        )
        let image = try Self.image(from: request)
        let encoded: Data
        do {
            let configuration = try JPEGLSEncoder.Configuration(
                near: parameters.near, interleaveMode: parameters.interleave, restartInterval: parameters.restartIntervalLines)
            encoded = try JPEGLSEncoder().encode(image, configuration: configuration)
        } catch {
            throw DicomJLSwiftBackendError.codestreamRejected(transferSyntaxUID: request.targetTransferSyntaxUID,
                                                              reason: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        try Task.checkCancellation()
        if parameters.near > 0, request.descriptor.pixelRepresentation == 1 {
            // NEAR bounds the error of the stored codes, not of the signed values: codes near the sign boundary can
            // wrap (e.g. 2047 → −2048 at 12 bits). The bound is therefore verified after signed normalisation.
            try Self.verifySignedNearBound(encoded, source: request.frame.buffer.data, descriptor: request.descriptor, near: parameters.near)
        }
        return encoded
    }

    /// Encoder parameters resolved from the intent and the transfer syntax.
    struct EncodingParameters: Equatable {
        let near: Int
        let interleave: JPEGLSInterleaveMode
        let restartIntervalLines: Int
    }

    static func verifySignedNearBound(_ encoded: Data, source: Data, descriptor: DicomCompressedFrameDescriptor, near: Int) throws {
        let decoded = try decodeSynchronously(encoded, descriptor: descriptor).buffer.data
        let normalizedSource = normalizedSignedData(source, descriptor: descriptor)
        guard descriptor.bitsAllocated == 16 else {
            var worst = 0
            for (a, b) in zip(decoded, normalizedSource) { worst = max(worst, abs(Int(Int8(bitPattern: a)) - Int(Int8(bitPattern: b)))) }
            if worst > near { throw DicomJLSwiftBackendError.nearLosslessBoundExceeded(transferSyntaxUID: descriptor.transferSyntaxUID, near: near, observed: worst) }
            return
        }
        var worst = 0
        decoded.withUnsafeBytes { (a: UnsafeRawBufferPointer) in
            normalizedSource.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                let x = a.bindMemory(to: UInt16.self), y = b.bindMemory(to: UInt16.self)
                for index in 0..<min(x.count, y.count) {
                    worst = max(worst, abs(Int(Int16(bitPattern: UInt16(littleEndian: x[index]))) - Int(Int16(bitPattern: UInt16(littleEndian: y[index])))))
                }
            }
        }
        if worst > near {
            throw DicomJLSwiftBackendError.nearLosslessBoundExceeded(transferSyntaxUID: descriptor.transferSyntaxUID, near: near, observed: worst)
        }
    }

    static func validateEncoding(
        descriptor: DicomCompressedFrameDescriptor,
        targetTransferSyntaxUID: String,
        intent: DicomEncodingIntent
    ) throws -> EncodingParameters {
        guard targetTransferSyntaxUID == descriptor.transferSyntaxUID else {
            throw DicomJLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: targetTransferSyntaxUID,
                reason: "the request descriptor names transfer syntax \(descriptor.transferSyntaxUID)"
            )
        }
        try validateDescriptor(descriptor)
        let near = try nearParameter(for: intent, transferSyntaxUID: targetTransferSyntaxUID)
        var interleave: JPEGLSInterleaveMode = descriptor.samplesPerPixel == 1 ? .none : .sample
        var restartLines = 0
        if case .jpegLS(let options) = intent {
            if let requested = options.interleave {
                guard descriptor.samplesPerPixel == 3 || requested == .perComponent else {
                    throw DicomJLSwiftBackendError.invalidEncodingIntent(transferSyntaxUID: targetTransferSyntaxUID,
                                                                         reason: "single-component JPEG-LS scans are never interleaved (requested \(requested.rawValue))")
                }
                switch requested {
                case .perComponent: interleave = .none
                case .line: interleave = .line
                case .sample: interleave = .sample
                }
            }
            restartLines = options.restartIntervalLines
            guard (0...65535).contains(restartLines) else {
                throw DicomJLSwiftBackendError.invalidEncodingIntent(transferSyntaxUID: targetTransferSyntaxUID,
                                                                     reason: "restart interval \(restartLines) lines does not fit the DRI field")
            }
            if restartLines > 0 {
                // The vendored core writes restart intervals for lossless non-interleaved scans; other combinations are
                // refused instead of being generalised.
                guard near == 0 else {
                    throw DicomJLSwiftBackendError.invalidEncodingIntent(transferSyntaxUID: targetTransferSyntaxUID,
                                                                         reason: "restart intervals are qualified for lossless (NEAR=0) scans only")
                }
                guard interleave == .none else {
                    throw DicomJLSwiftBackendError.invalidEncodingIntent(transferSyntaxUID: targetTransferSyntaxUID,
                                                                         reason: "restart intervals are qualified for non-interleaved scans only (requested \(interleave))")
                }
            }
        }
        return EncodingParameters(near: near, interleave: interleave, restartIntervalLines: restartLines)
    }

    static func validateDescriptor(_ descriptor: DicomCompressedFrameDescriptor) throws {
        let uid = descriptor.transferSyntaxUID
        guard descriptor.rows > 0, descriptor.columns > 0 else {
            throw DicomJLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: uid,
                reason: "Rows and Columns must both be positive"
            )
        }
        guard descriptor.bitsAllocated == 8 || descriptor.bitsAllocated == 16,
              descriptor.bitsStored <= descriptor.bitsAllocated,
              descriptor.highBit == descriptor.bitsStored - 1 else {
            throw DicomJLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: uid,
                reason: "Bits Allocated/Stored/High Bit must be an aligned 8- or 16-bit integer layout"
            )
        }
        let photometric = descriptor.photometricInterpretation.uppercased()
        if descriptor.samplesPerPixel == 1 {
            guard photometric.isEmpty || photometric == "MONOCHROME1" || photometric == "MONOCHROME2" else {
                throw DicomJLSwiftBackendError.unsupportedShape(
                    transferSyntaxUID: uid,
                    reason: "single-component JPEG-LS does not accept \(descriptor.photometricInterpretation)"
                )
            }
        } else {
            guard descriptor.samplesPerPixel == 3,
                  descriptor.bitsAllocated == 8,
                  descriptor.bitsStored <= 8,
                  descriptor.pixelRepresentation == 0,
                  photometric == "RGB",
                  descriptor.planarConfiguration == 0 || descriptor.planarConfiguration == 1 else {
                throw DicomJLSwiftBackendError.unsupportedShape(
                    transferSyntaxUID: uid,
                    reason: "multi-component JPEG-LS is qualified only for unsigned RGB8 with Planar Configuration 0 or 1"
                )
            }
        }
    }

    private static func validateNear(_ near: Int, transferSyntaxUID: String) throws {
        if transferSyntaxUID == DicomTransferSyntax.jpegLSLossless.rawValue, near != 0 {
            throw DicomJLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: transferSyntaxUID,
                reason: "the lossless transfer syntax contains NEAR=\(near)"
            )
        }
        if transferSyntaxUID == DicomTransferSyntax.jpegLSNearLossless.rawValue, near == 0 {
            throw DicomJLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: transferSyntaxUID,
                reason: "the near-lossless transfer syntax contains NEAR=0"
            )
        }
    }

    private static func nearParameter(
        for intent: DicomEncodingIntent,
        transferSyntaxUID: String
    ) throws -> Int {
        switch (transferSyntaxUID, intent) {
        case (DicomTransferSyntax.jpegLSLossless.rawValue, .reversible):
            return 0
        case (DicomTransferSyntax.jpegLSNearLossless.rawValue, .jpegLSNearLossless(let near))
            where (1...255).contains(near):
            return near
        case (DicomTransferSyntax.jpegLSNearLossless.rawValue, .jpegLSNearLossless(let near)):
            throw DicomJLSwiftBackendError.invalidEncodingIntent(
                transferSyntaxUID: transferSyntaxUID,
                reason: "NEAR must be in 1...255, got \(near)"
            )
        case (DicomTransferSyntax.jpegLSLossless.rawValue, .jpegLS(let options)) where options.near == 0:
            return 0
        case (DicomTransferSyntax.jpegLSLossless.rawValue, .jpegLS(let options)):
            throw DicomJLSwiftBackendError.invalidEncodingIntent(
                transferSyntaxUID: transferSyntaxUID,
                reason: "the lossless syntax requires NEAR=0, got \(options.near); use 1.2.840.10008.1.2.4.81 for near-lossless"
            )
        case (DicomTransferSyntax.jpegLSNearLossless.rawValue, .jpegLS(let options)) where (1...255).contains(options.near):
            return options.near
        case (DicomTransferSyntax.jpegLSNearLossless.rawValue, .jpegLS(let options)):
            throw DicomJLSwiftBackendError.invalidEncodingIntent(
                transferSyntaxUID: transferSyntaxUID,
                reason: "the near-lossless syntax requires NEAR in 1...255, got \(options.near)"
            )
        case (DicomTransferSyntax.jpegLSLossless.rawValue, _):
            throw DicomJLSwiftBackendError.invalidEncodingIntent(
                transferSyntaxUID: transferSyntaxUID,
                reason: "the lossless syntax requires reversible intent"
            )
        case (DicomTransferSyntax.jpegLSNearLossless.rawValue, _):
            throw DicomJLSwiftBackendError.invalidEncodingIntent(
                transferSyntaxUID: transferSyntaxUID,
                reason: "the near-lossless syntax requires an explicit JPEG-LS NEAR value"
            )
        default:
            throw DicomJLSwiftBackendError.invalidEncodingIntent(
                transferSyntaxUID: transferSyntaxUID,
                reason: "the target is not a qualified JPEG-LS transfer syntax"
            )
        }
    }

    private static func normalizedFrame(
        from image: MultiComponentImageData,
        descriptor: DicomCompressedFrameDescriptor
    ) throws -> DicomCodecDecodedFrame {
        let header = image.frameHeader
        let effectiveDescriptor = try effectiveDescriptor(for: header, componentCount: image.components.count,
                                                          descriptor: descriptor)
        let data = try packedData(from: image, descriptor: effectiveDescriptor)
        return DicomCodecDecodedFrame(
            buffer: .owned(data),
            width: header.width,
            height: header.height,
            bitsPerSample: header.bitsPerSample,
            componentCount: header.componentCount
        )
    }

    /// Checks the frame header against the descriptor and returns the descriptor the samples follow: a codestream
    /// more precise than Bits Stored that still fits Bits Allocated keeps its own precision.
    private static func effectiveDescriptor(
        for header: JPEGLSFrameHeader,
        componentCount: Int,
        descriptor: DicomCompressedFrameDescriptor
    ) throws -> DicomCompressedFrameDescriptor {
        let uid = descriptor.transferSyntaxUID
        guard header.width == descriptor.columns, header.height == descriptor.rows else {
            throw DicomJLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "codestream is \(header.width)x\(header.height), expected "
                    + "\(descriptor.columns)x\(descriptor.rows)"
            )
        }
        // A codestream more precise than Bits Stored that still fits Bits Allocated keeps its own precision, as GDCM
        // reads it (`MEDILABValidCP246_EVRLESQasOB`: P = 16 under Bits Stored 12, issue #2868; J2K does the same, #2854).
        let exceedsBitsStoredWithinAllocation = header.bitsPerSample > descriptor.bitsStored
            && header.bitsPerSample <= descriptor.bitsAllocated
        guard header.bitsPerSample == descriptor.bitsStored || exceedsBitsStoredWithinAllocation else {
            throw DicomJLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "codestream has \(header.bitsPerSample) bits, expected \(descriptor.bitsStored)"
            )
        }
        guard header.componentCount == descriptor.samplesPerPixel,
              componentCount == descriptor.samplesPerPixel else {
            throw DicomJLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "codestream component count does not match Samples Per Pixel"
            )
        }
        return exceedsBitsStoredWithinAllocation ? DicomCompressedFrameDescriptor(
            transferSyntaxUID: descriptor.transferSyntaxUID, rows: descriptor.rows, columns: descriptor.columns,
            bitsAllocated: descriptor.bitsAllocated, bitsStored: header.bitsPerSample, highBit: header.bitsPerSample - 1,
            pixelRepresentation: descriptor.pixelRepresentation, samplesPerPixel: descriptor.samplesPerPixel,
            photometricInterpretation: descriptor.photometricInterpretation,
            planarConfiguration: descriptor.planarConfiguration) : descriptor
    }

    private static func packedData(
        from image: MultiComponentImageData,
        descriptor: DicomCompressedFrameDescriptor
    ) throws -> Data {
        let pixelCount = try checkedPixelCount(descriptor)
        if descriptor.samplesPerPixel == 1 {
            let samples = image.components[0].pixels.flatMap { $0 }
            guard samples.count == pixelCount else {
                throw DicomJLSwiftBackendError.metadataMismatch(
                    transferSyntaxUID: descriptor.transferSyntaxUID,
                    reason: "decoded grayscale sample count does not match Rows and Columns"
                )
            }
            return normalizedSignedData(
                data(from: samples, bitsAllocated: descriptor.bitsAllocated),
                descriptor: descriptor
            )
        }

        let planes = image.components.map { $0.pixels.flatMap { $0 } }
        guard planes.count == 3, planes.allSatisfy({ $0.count == pixelCount }) else {
            throw DicomJLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: descriptor.transferSyntaxUID,
                reason: "decoded RGB component dimensions do not match Rows and Columns"
            )
        }
        var bytes = [UInt8](repeating: 0, count: pixelCount * 3)
        bytes.withUnsafeMutableBufferPointer { target in
            for component in 0..<3 {
                planes[component].withUnsafeBufferPointer { plane in
                    var offset = component
                    for index in 0..<pixelCount {
                        target[offset] = UInt8(truncatingIfNeeded: plane[index])
                        offset += 3
                    }
                }
            }
        }
        return Data(bytes)
    }

    private static func image(from request: DicomFrameEncodeRequest) throws -> MultiComponentImageData {
        let descriptor = request.descriptor
        let frame = request.frame
        let uid = request.targetTransferSyntaxUID
        guard frame.width == descriptor.columns, frame.height == descriptor.rows,
              frame.bitsPerSample == descriptor.bitsStored,
              frame.componentCount == descriptor.samplesPerPixel else {
            throw DicomJLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "the input frame shape does not match the DICOM descriptor"
            )
        }
        let pixelCount = try checkedPixelCount(descriptor)
        let expectedBytes = pixelCount * descriptor.samplesPerPixel * (descriptor.bitsAllocated / 8)
        let bytes = frame.buffer.data
        guard bytes.count == expectedBytes else {
            throw DicomJLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "input frame contains \(bytes.count) bytes, expected \(expectedBytes)"
            )
        }
        let mask = descriptor.bitsStored == 16 ? 0xFFFF : (1 << descriptor.bitsStored) - 1
        if descriptor.samplesPerPixel == 1 {
            let samples = samples(from: bytes, bitsAllocated: descriptor.bitsAllocated, mask: mask)
            return try MultiComponentImageData.grayscale(
                pixels: rows(from: samples, width: descriptor.columns),
                bitsPerSample: descriptor.bitsStored
            )
        }

        var planes = [[Int]](repeating: [Int](repeating: 0, count: pixelCount), count: 3)
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for component in 0..<3 {
                planes[component].withUnsafeMutableBufferPointer { plane in
                    var offset = component
                    for index in 0..<pixelCount {
                        plane[index] = Int(raw[offset]) & mask
                        offset += 3
                    }
                }
            }
        }
        return try MultiComponentImageData.rgb(
            redPixels: rows(from: planes[0], width: descriptor.columns),
            greenPixels: rows(from: planes[1], width: descriptor.columns),
            bluePixels: rows(from: planes[2], width: descriptor.columns),
            bitsPerSample: descriptor.bitsStored
        )
    }

    private static func checkedPixelCount(_ descriptor: DicomCompressedFrameDescriptor) throws -> Int {
        let result = descriptor.rows.multipliedReportingOverflow(by: descriptor.columns)
        guard !result.overflow else {
            throw DicomJLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: descriptor.transferSyntaxUID,
                reason: "Rows and Columns exceed the addressable frame range"
            )
        }
        return result.partialValue
    }

    private static func samples(from data: Data, bitsAllocated: Int, mask: Int) -> [Int] {
        if bitsAllocated == 8 {
            return data.map { Int($0) & mask }
        }
        var result = [Int](repeating: 0, count: data.count / 2)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            result.withUnsafeMutableBufferPointer { target in
                for index in 0..<target.count {
                    target[index] = (Int(raw[index * 2]) | (Int(raw[index * 2 + 1]) << 8)) & mask
                }
            }
        }
        return result
    }

    private static func rows(from samples: [Int], width: Int) -> [[Int]] {
        stride(from: 0, to: samples.count, by: width).map {
            Array(samples[$0..<min($0 + width, samples.count)])
        }
    }

    private static func data(from samples: [Int], bitsAllocated: Int) -> Data {
        if bitsAllocated == 8 {
            return Data(samples.map { UInt8(truncatingIfNeeded: $0) })
        }
        var result = [UInt8](repeating: 0, count: samples.count * 2)
        result.withUnsafeMutableBufferPointer { target in
            samples.withUnsafeBufferPointer { source in
                for index in 0..<source.count {
                    let value = UInt16(truncatingIfNeeded: source[index])
                    target[index * 2] = UInt8(truncatingIfNeeded: value)
                    target[index * 2 + 1] = UInt8(truncatingIfNeeded: value >> 8)
                }
            }
        }
        return Data(result)
    }

    static func normalizedSignedData(
        _ data: Data,
        descriptor: DicomCompressedFrameDescriptor
    ) -> Data {
        guard descriptor.pixelRepresentation == 1,
              descriptor.bitsAllocated == 16,
              descriptor.bitsStored < 16 else {
            return data
        }
        let valueMask = UInt16((1 << descriptor.bitsStored) - 1)
        let signBit = UInt16(1 << (descriptor.bitsStored - 1))
        var result = Data(capacity: data.count)
        for index in stride(from: 0, to: data.count, by: 2) {
            var value = (UInt16(data[index]) | (UInt16(data[index + 1]) << 8)) & valueMask
            if value & signBit != 0 {
                value |= ~valueMask
            }
            result.append(UInt8(truncatingIfNeeded: value))
            result.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return result
    }
}
