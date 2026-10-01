//
//  DicomTranscoder.swift
//  DicomCore
//
//  Executable transfer syntax transcoding routes (issue #1237). The
//  registry supplies route topology; shared prepared routes qualify
//  the active adapters for preflight and async execution:
//
//  - passThrough / rewriteNative: a safe Part 10 rewrite carrying every
//    element and the Pixel Data bytes unchanged (encapsulated payloads
//    byte-for-byte) into the destination syntax's writer path.
//  - decompress: compressed sources whose decode backend is active are
//    decoded frame-by-frame through DicomDecodedFrameReader and written
//    as Explicit VR Little Endian with stored-value pixel fidelity.
//  - compress / recompress: JPEG-LS Lossless remains available through
//    CharLS; the async overloads add explicit-intent CPU routes for
//    JPEG-LS, JPEG 2000, HTJ2K, and feature-gated JPEG XL.
//

import Foundation

public struct DicomTranscoder: Sendable {
    public enum TranscodeError: Error, Equatable, LocalizedError, Sendable {
        /// The planner rejected the route; diagnostics carry the reasons.
        case routeUnsupported(sourceUID: String, destinationUID: String, diagnostics: [String])
        /// The source's frames could not be decoded.
        case decodeFailed(sourceUID: String, reason: String)
        /// The source's pixel shape cannot be converted with fidelity.
        case unsupportedPixelShape(reason: String)
        /// A frame failed during destination encoding.
        case encodeFailed(destinationUID: String, frameIndex: Int, reason: String)

        public var errorDescription: String? {
            switch self {
            case .routeUnsupported(let source, let destination, let diagnostics):
                return "Transcoding \(source) to \(destination) is unsupported: \(diagnostics.joined(separator: " "))"
            case .decodeFailed(let source, let reason):
                return "Decoding \(source) frames failed: \(reason)"
            case .unsupportedPixelShape(let reason):
                return "The pixel shape cannot be transcoded with fidelity: \(reason)"
            case .encodeFailed(let destination, let frameIndex, let reason):
                return "Encoding frame \(frameIndex) for \(destination) failed: \(reason)"
            }
        }
    }

    public init() {}

    /// Transcodes a Part 10 file on disk into the destination syntax.
    public func transcode(contentsOf url: URL, to destination: DicomTransferSyntax) throws -> Data {
        try transcode(decoder: DCMDecoder(contentsOf: url), to: destination)
    }

    /// Transcodes in-memory Part 10 bytes into the destination syntax.
    public func transcode(_ data: Data, to destination: DicomTransferSyntax) throws -> Data {
        try transcode(decoder: DCMDecoder(data: data), to: destination)
    }

    /// Transcodes a Part 10 file using an explicit JPEG 2000/HTJ2K encoding intent.
    public func transcode(
        contentsOf url: URL,
        to destination: DicomTransferSyntax,
        intent: DicomEncodingIntent,
        jpeg2000Options: DicomJPEG2000EncodingOptions? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> Data {
        try await transcode(
            decoder: DCMDecoder(contentsOf: url),
            to: destination,
            intent: intent,
            jpeg2000Options: jpeg2000Options,
            environment: environment
        )
    }

    /// Transcodes in-memory Part 10 bytes using an explicit JPEG 2000/HTJ2K encoding intent.
    public func transcode(
        _ data: Data,
        to destination: DicomTransferSyntax,
        intent: DicomEncodingIntent,
        jpeg2000Options: DicomJPEG2000EncodingOptions? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> Data {
        try await transcode(
            decoder: DCMDecoder(data: data),
            to: destination,
            intent: intent,
            jpeg2000Options: jpeg2000Options,
            environment: environment
        )
    }

    /// Qualifies the async explicit-intent API, declared metadata, and optional output-decoder
    /// availability without producing a destination codestream.
    public func preflight(
        _ data: Data,
        to destination: DicomTransferSyntax,
        intent: DicomEncodingIntent = .reversible,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        verifyDecodedPixels: Bool = true
    ) throws -> DicomTranscodePreflightResult {
        try preflight(
            decoder: DCMDecoder(data: data),
            to: destination,
            intent: intent,
            environment: environment,
            verifyDecodedPixels: verifyDecodedPixels
        )
    }

    /// Qualifies a destination while reusing an already parsed source object.
    public func preflight(
        decoder: DCMDecoder,
        to destination: DicomTransferSyntax,
        intent: DicomEncodingIntent = .reversible,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        verifyDecodedPixels: Bool = true
    ) throws -> DicomTranscodePreflightResult {
        try preflightDecodedSource(
            decoder: decoder,
            to: destination,
            intent: intent,
            environment: environment,
            verifyDecodedPixels: verifyDecodedPixels
        )
    }

    func transcode(decoder: DCMDecoder, to destination: DicomTransferSyntax) throws -> Data {
        let source = DicomTransferSyntax(uid: decoder.info(for: .transferSyntaxUID)) ?? .explicitVRLittleEndian
        let plan = DicomTransferSyntaxRegistry.standard.transcodePlan(from: source, to: destination)

        switch plan.route {
        case .passThrough, .rewriteNative:
            return try writeCarryingDataset(decoder: decoder, destination: destination)

        case .decompress:
            try validateDecompressionDestination(source: source, destination: destination)
            if source == .deflatedImageFrameCompression {
                return try inflateDeflatedFramesToNative(decoder: decoder, destination: destination)
            }
            return try decompressToNative(decoder: decoder, source: source, destination: destination)

        case .compress:
            if destination == .rleLossless {
                let descriptor = try prepareRLEDescriptor(decoder: decoder, source: source, intent: .reversible)
                return try compressToRLESynchronously(decoder: decoder, source: source, descriptor: descriptor)
            }
            if destination == .deflatedImageFrameCompression {
                let descriptor = try prepareDeflatedFramesDescriptor(decoder: decoder, source: source, intent: .reversible)
                return try compressToDeflatedFramesSynchronously(decoder: decoder, source: source, descriptor: descriptor)
            }
            guard destination == .jpegLSLossless else {
                throw TranscodeError.routeUnsupported(
                    sourceUID: source.rawValue,
                    destinationUID: destination.rawValue,
                    diagnostics: plan.diagnostics.map(\.message)
                        + ["JPEG-LS Lossless, RLE Lossless and Deflated Image Frame Compression are the executable synchronous encoder routes."]
                )
            }
            return try compressToJPEGLSLossless(decoder: decoder, source: source)

        case .reference, .recompress:
            throw TranscodeError.routeUnsupported(
                sourceUID: source.rawValue,
                destinationUID: destination.rawValue,
                diagnostics: plan.diagnostics.map(\.message)
            )
        }
    }

    func transcode(
        decoder: DCMDecoder,
        to destination: DicomTransferSyntax,
        intent: DicomEncodingIntent,
        jpeg2000Options: DicomJPEG2000EncodingOptions? = nil,
        environment: [String: String]
    ) async throws -> Data {
        try Task.checkCancellation()
        let source = DicomTransferSyntax(uid: decoder.info(for: .transferSyntaxUID)) ?? .explicitVRLittleEndian
        let route = try resolveExecutionRoute(
            decoder: decoder, source: source, destination: destination, intent: intent, environment: environment,
            jpeg2000Options: jpeg2000Options
        )
        switch route {
        case .carryDataset:
            let output = try writeCarryingDataset(decoder: decoder, destination: destination)
            try Task.checkCancellation()
            return output
        case .decompress:
            if source == .deflatedImageFrameCompression {
                return try inflateDeflatedFramesToNative(decoder: decoder, destination: destination)
            }
            return try await decompressToNative(decoder: decoder, source: source, destination: destination, environment: environment)
        case .jpegLS(let descriptor):
            return try await compressToJPEGLS(
                decoder: decoder, source: source, destination: destination,
                intent: intent, descriptor: descriptor, environment: environment
            )
        case .jpeg2000(let descriptor):
            return try await compressToJ2K(
                decoder: decoder, source: source, destination: destination,
                intent: intent, descriptor: descriptor, environment: environment, jpeg2000Options: jpeg2000Options
            )
        case .jpeg2000Part2(let descriptor):
            return try await compressToJ2KPart2(
                decoder: decoder, source: source, destination: destination,
                intent: intent, descriptor: descriptor, environment: environment
            )
        case .jpegXL(let descriptor):
            return try await compressToJPEGXL(
                decoder: decoder, source: source, destination: destination,
                intent: intent, descriptor: descriptor, environment: environment
            )
        case .jpegRecompression:
            return try await recompressJPEGToJPEGXL(decoder: decoder, source: source)
        case .jpegReconstruction:
            return try await reconstructJPEGFromJPEGXL(decoder: decoder, destination: destination)
        case .rle(let descriptor):
            return try await compressToRLE(decoder: decoder, source: source, descriptor: descriptor, environment: environment)
        case .deflatedFrames(let descriptor):
            return try await compressToDeflatedFrames(decoder: decoder, source: source, descriptor: descriptor, environment: environment)
        case .jpeg(let descriptor):
            return try await compressToJPEG(decoder: decoder, source: source, destination: destination, intent: intent,
                                            descriptor: descriptor, environment: environment)
        }
    }
}
