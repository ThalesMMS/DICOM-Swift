//
//  DicomJLSwiftBackend.swift
//  DicomCore
//
//  Package-linked JLSwift adapter. JLSwift types stay behind the neutral
//  compressed-frame contract.
//

import Foundation
import JPEGLS

extension DicomCodecBackendIdentifier {
    static let jlSwift: Self = "jlswift"
    static let charLSCPU: Self = "charls-jpeg-ls"
}

enum DicomJLSwiftBackendError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedShape(transferSyntaxUID: String, reason: String)
    case metadataMismatch(transferSyntaxUID: String, reason: String)
    case invalidEncodingIntent(transferSyntaxUID: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedShape(let uid, let reason):
            return "JLSwift does not support JPEG-LS transfer syntax \(uid): \(reason)"
        case .metadataMismatch(let uid, let reason):
            return "JLSwift output does not match DICOM metadata for transfer syntax \(uid): \(reason)"
        case .invalidEncodingIntent(let uid, let reason):
            return "Invalid JPEG-LS encoding intent for transfer syntax \(uid): \(reason)"
        }
    }
}

struct DicomJLSwiftBackend: DicomFrameCodecBackend {
    static let version = "0.9.0"
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
        try Self.validateDescriptor(request.descriptor)

        let parseResult = try JPEGLSParser(data: request.frameData).parse()
        let near = parseResult.scanHeaders.first?.near ?? 0
        try Self.validateNear(near, transferSyntaxUID: request.descriptor.transferSyntaxUID)
        let image = try JPEGLSDecoder().decode(request.frameData)
        try Task.checkCancellation()
        return try Self.normalizedFrame(from: image, descriptor: request.descriptor)
    }

    func encode(_ request: DicomFrameEncodeRequest) async throws -> Data {
        try Task.checkCancellation()
        guard request.targetTransferSyntaxUID == request.descriptor.transferSyntaxUID else {
            throw DicomJLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: request.targetTransferSyntaxUID,
                reason: "the request descriptor names transfer syntax \(request.descriptor.transferSyntaxUID)"
            )
        }
        if let reason = capabilities.unsupportedReason(for: request.descriptor, operation: .encode) {
            throw DicomJLSwiftBackendError.unsupportedShape(
                transferSyntaxUID: request.targetTransferSyntaxUID,
                reason: reason
            )
        }
        try Self.validateDescriptor(request.descriptor)
        let near = try Self.nearParameter(
            for: request.intent,
            transferSyntaxUID: request.targetTransferSyntaxUID
        )
        let image = try Self.image(from: request)
        let interleave: JPEGLSInterleaveMode = request.descriptor.samplesPerPixel == 1 ? .none : .sample
        let encoded = try JPEGLSEncoder().encode(image, near: near, interleaveMode: interleave)
        try Task.checkCancellation()
        return encoded
    }

    private static func validateDescriptor(_ descriptor: DicomCompressedFrameDescriptor) throws {
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
        let uid = descriptor.transferSyntaxUID
        guard header.width == descriptor.columns, header.height == descriptor.rows else {
            throw DicomJLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "codestream is \(header.width)x\(header.height), expected "
                    + "\(descriptor.columns)x\(descriptor.rows)"
            )
        }
        guard header.bitsPerSample == descriptor.bitsStored else {
            throw DicomJLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "codestream has \(header.bitsPerSample) bits, expected \(descriptor.bitsStored)"
            )
        }
        guard header.componentCount == descriptor.samplesPerPixel,
              image.components.count == descriptor.samplesPerPixel else {
            throw DicomJLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "codestream component count does not match Samples Per Pixel"
            )
        }
        let data = try packedData(from: image, descriptor: descriptor)
        return DicomCodecDecodedFrame(
            buffer: .owned(data),
            width: header.width,
            height: header.height,
            bitsPerSample: header.bitsPerSample,
            componentCount: header.componentCount
        )
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
        var bytes = Data(capacity: pixelCount * 3)
        for index in 0..<pixelCount {
            bytes.append(UInt8(planes[0][index]))
            bytes.append(UInt8(planes[1][index]))
            bytes.append(UInt8(planes[2][index]))
        }
        return bytes
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

        var planes = Array(repeating: [Int](), count: 3)
        planes.indices.forEach { planes[$0].reserveCapacity(pixelCount) }
        for index in 0..<pixelCount {
            for component in 0..<3 {
                planes[component].append(Int(bytes[index * 3 + component]) & mask)
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
        var result: [Int] = []
        result.reserveCapacity(data.count / 2)
        for index in stride(from: 0, to: data.count, by: 2) {
            let value = Int(data[index]) | (Int(data[index + 1]) << 8)
            result.append(value & mask)
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
            return Data(samples.map(UInt8.init))
        }
        var result = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = UInt16(sample)
            result.append(UInt8(truncatingIfNeeded: value))
            result.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return result
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
