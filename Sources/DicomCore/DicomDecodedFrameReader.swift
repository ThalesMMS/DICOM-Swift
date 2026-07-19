//
//  DicomDecodedFrameReader.swift
//  DicomCore
//
//  Production decoded-frame surface (issue #1227): opens a Part 10 file or
//  dataset, resolves the transfer syntax, extracts the requested frame
//  (native byte-range or encapsulated fragment assembly via
//  `DicomEncapsulatedPixelFrameReader`, #1226), decodes it when a backend
//  supports the syntax, and returns typed pixels plus the image metadata an
//  Isis-style renderer needs. Uncompressed, RLE, JPEG, JPEG-LS, JPEG 2000,
//  and unsupported transfer syntaxes all surface through one typed
//  `ReadError`.
//
//  How this differs from neighboring layers:
//  - Display rendering (`DCMWindowingProcessor`, `DicomDisplayTransform`)
//    maps decoded pixels to display gray/RGB using VOI windowing, LUTs, and
//    presentation state. This reader stops earlier: it returns the decoded
//    buffer in the same normalization the legacy `getPixels8/16/24`
//    surface uses (signed samples offset to unsigned, MONOCHROME1
//    inverted) plus the stored VOI/rescale attributes so renderers decide
//    how to window.
//  - Volume assembly (`DicomSeriesLoader`, #1233/#1234) orders many slices
//    or multiframe groups into a 3D volume. This reader addresses exactly
//    one frame of one object and never materializes sibling frames, which
//    keeps multiframe access memory-bounded.
//

import Foundation

/// Typed decoded pixel payload of a single frame.
public enum DicomDecodedFramePixelBuffer: Equatable, Sendable {
    /// 8-bit grayscale samples (MONOCHROME1 already inverted).
    case gray8([UInt8])
    /// 16-bit grayscale samples (signed values offset to unsigned,
    /// MONOCHROME1 already inverted) — same contract as `getPixels16()`.
    case gray16([UInt16])
    /// Interleaved 8-bit R,G,B triplets.
    case rgb8(interleaved: [UInt8])

    /// Number of addressable pixel samples in the buffer.
    public var sampleCount: Int {
        switch self {
        case .gray8(let pixels): return pixels.count
        case .gray16(let pixels): return pixels.count
        case .rgb8(let interleaved): return interleaved.count / 3
        }
    }
}

/// Image attributes a renderer needs alongside the decoded buffer. Values
/// come from the DICOM header; optional fields are nil when the dataset
/// does not carry the attribute.
public struct DicomDecodedFrameMetadata: Equatable, Sendable {
    /// Decoded frame width in pixels.
    public let width: Int
    /// Decoded frame height in pixels.
    public let height: Int
    /// Addressable frame count (mapped frames for encapsulated objects).
    public let frameCount: Int
    /// Storage allocation width of each sample.
    public let bitsAllocated: Int
    /// Significant precision of each stored sample.
    public let bitsStored: Int
    /// Index of the most significant stored bit.
    public let highBit: Int
    /// DICOM signedness flag, where one denotes signed samples.
    public let pixelRepresentation: Int
    /// Number of samples stored per pixel.
    public let samplesPerPixel: Int
    /// DICOM photometric interpretation of the frame.
    public let photometricInterpretation: String
    /// Planar layout flag for multi-sample frames, when present.
    public let planarConfiguration: Int?
    /// Transfer syntax used by the source object.
    public let transferSyntaxUID: String
    /// Stored VOI window, nil when the dataset has no usable window.
    public let windowSettings: WindowSettings?
    /// Modality rescale slope and intercept.
    public let rescaleParameters: RescaleParameters
    /// Smallest stored image pixel value declared by the object.
    public let smallestImagePixelValue: Int?
    /// Largest stored image pixel value declared by the object.
    public let largestImagePixelValue: Int?
}

/// One decoded frame: typed pixels plus renderer-facing metadata.
public struct DicomDecodedFrame: Equatable, Sendable {
    /// Zero-based source frame index.
    public let index: Int
    /// Typed grayscale or RGB pixel storage.
    public let pixels: DicomDecodedFramePixelBuffer
    /// Renderer-facing metadata for the decoded output.
    public let metadata: DicomDecodedFrameMetadata
}

/// Production frame reader over one DICOM object. Thread-safe (the wrapped
/// decoder synchronizes its state) and cheap to copy.
public struct DicomDecodedFrameReader: Sendable {
    /// Typed failures while locating, extracting, or decoding a frame.
    public enum ReadError: Error, Equatable, LocalizedError, Sendable {
        /// The object carries no decodable Pixel Data element.
        case noPixelData
        case frameIndexOutOfRange(index: Int, frameCount: Int)
        /// The transfer syntax has no decode backend in this build; the
        /// diagnostics carry the deterministic resolver reasons.
        case unsupportedTransferSyntax(uid: String, diagnostics: [String])
        /// Encapsulated fragments exist but no safe frame map could be
        /// derived (`DicomEncapsulatedPixelFrameReader` diagnostics).
        case unusableEncapsulation(diagnostics: [String])
        /// The selected backend failed to produce a typed pixel buffer.
        case decodeFailed(transferSyntaxUID: String, reason: String)

        /// Human-readable diagnostic suitable for logs or presentation.
        public var errorDescription: String? {
            switch self {
            case .noPixelData:
                return "The DICOM object carries no decodable Pixel Data."
            case .frameIndexOutOfRange(let index, let frameCount):
                return "Frame index \(index) is outside the addressable range of \(frameCount) frame(s)."
            case .unsupportedTransferSyntax(let uid, let diagnostics):
                return "Transfer syntax \(uid) has no decode backend: \(diagnostics.joined(separator: " "))"
            case .unusableEncapsulation(let diagnostics):
                return "Encapsulated Pixel Data has no usable frame mapping: \(diagnostics.joined(separator: " "))"
            case .decodeFailed(let uid, let reason):
                return "Decoding a \(uid) frame failed: \(reason)"
            }
        }
    }

    private let decoder: DCMDecoder

    /// Opens a Part 10 file.
    public init(contentsOf url: URL) throws {
        self.init(decoder: try DCMDecoder(contentsOf: url))
    }

    /// Reads frames of an in-memory dataset by encoding it as Part 10 bytes
    /// in memory (the options select the encoded transfer syntax).
    public init(dataSet: DicomDataSet, options: DicomPart10WriterOptions) throws {
        let fileData = try DicomDataSetWriter.part10Data(from: dataSet, options: options)
        self.init(decoder: try DCMDecoder(data: fileData))
    }

    /// Wraps an already-loaded decoder without re-parsing the file.
    public init(decoder: DCMDecoder) {
        self.decoder = decoder
    }

    /// Number of frames this reader can address: mapped frames for
    /// encapsulated objects, declared frames for native objects, and 1 for
    /// defined-length compressed payloads (which carry no frame map).
    public var frameCount: Int {
        if decoder.compressedImage {
            if let reader = try? decoder.makeEncapsulatedPixelFrameReader() {
                return reader.frameCount
            }
            return decoder.fileReadSucceeded ? 1 : 0
        }
        if let descriptor = decoder.pixelDataDescriptor {
            return descriptor.numberOfFrames
        }
        return decoder.fileReadSucceeded ? max(1, decoder.nImages) : 0
    }

    /// Header metadata shared by every frame of the object.
    public func metadata() throws -> DicomDecodedFrameMetadata {
        guard decoder.fileReadSucceeded else {
            throw ReadError.noPixelData
        }
        return makeMetadata(width: decoder.width, height: decoder.height)
    }

    /// Decodes one frame. Extraction and decode touch only the requested
    /// frame's bytes, so multiframe access stays memory-bounded.
    public func frame(at index: Int) throws -> DicomDecodedFrame {
        guard decoder.fileReadSucceeded else {
            throw ReadError.noPixelData
        }
        let count = frameCount
        guard index >= 0, index < count else {
            throw ReadError.frameIndexOutOfRange(index: index, frameCount: count)
        }
        if decoder.compressedImage {
            return try decodeCompressedFrame(at: index, frameCount: count)
        }
        return try decodeNativeFrame(at: index, frameCount: count)
    }

    /// Cancellation-aware variant: the decode runs off the caller's thread
    /// and honors `Task` cancellation before extraction starts.
    @available(macOS 10.15, iOS 13.0, *)
    /// Decodes one frame asynchronously while honoring task cancellation.
    public func frame(at index: Int) async throws -> DicomDecodedFrame {
        try await frameExecution(at: index).frame
    }

    @available(macOS 10.15, iOS 13.0, *)
    /// Decodes one frame and reports the backend/fallback decision that produced it.
    public func frameExecution(
        at index: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> DicomDecodedFrameExecution {
        guard decoder.fileReadSucceeded else {
            throw ReadError.noPixelData
        }
        let count = frameCount
        guard index >= 0, index < count else {
            throw ReadError.frameIndexOutOfRange(index: index, frameCount: count)
        }
        if decoder.compressedImage,
           let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID),
           let family = DicomCodecFamily.family(for: syntax),
           family == .jpeg2000 || family == .htj2k {
            return try await decodeJ2KFrame(at: index, frameCount: count, environment: environment)
        }
        if decoder.compressedImage,
           let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID),
           DicomCodecFamily.family(for: syntax) == .jpegLS {
            return try await decodeJPEGLSFrame(at: index, frameCount: count, environment: environment)
        }
        if decoder.compressedImage,
           let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID),
           DicomCodecFamily.family(for: syntax) == .jpegXL,
           DicomJXLSwiftRolloutMode(environment: environment) != .disabled {
            return try await decodeJPEGXLFrame(at: index, frameCount: count, environment: environment)
        }

        let reader = self
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let frame = try reader.frame(at: index)
            return reader.execution(
                frame: frame,
                environment: environment,
                rolloutMode: nil,
                fallbackReason: nil,
                shadowBackendIdentifier: nil
            )
        }.value
    }

    /// Reports codestream-qualified partial-decode capabilities for one frame.
    /// Unsupported transfer syntaxes return `.unavailable`; malformed frame
    /// mappings or codestream headers remain typed errors.
    @available(macOS 10.15, iOS 13.0, *)
    /// Reports direct partial-decode support and codestream limits for a frame.
    public func partialDecodeCapabilities(at index: Int = 0) async throws
        -> DicomPartialFrameDecodeCapabilities {
        guard decoder.fileReadSucceeded else {
            throw ReadError.noPixelData
        }
        let count = frameCount
        guard index >= 0, index < count else {
            throw ReadError.frameIndexOutOfRange(index: index, frameCount: count)
        }
        guard DicomJ2KSwiftBackend.qualifiedTransferSyntaxes.contains(decoder.transferSyntaxUID),
              DicomJ2KSwiftRolloutMode() != .disabled else {
            return .unavailable
        }

        let frameData = try compressedFrameData(at: index)
        let info = try DicomJ2KCodestreamInfo.parse(frameData)
        return DicomPartialFrameDecodeCapabilities(
            supportsRegion: true,
            supportsResolutionReduction: true,
            supportsQualityLayers: true,
            supportsCombinedRegionAndResolution: true,
            supportsQualityWithSpatialReduction: false,
            maximumResolutionReductionLevel: info.decompositionLevels,
            qualityLayerCount: info.qualityLayerCount
        )
    }

    /// Executes a qualified JPEG 2000 partial decode without materializing a
    /// full frame. Callers choose any non-JPEG-2000 fallback explicitly.
    @available(macOS 10.15, iOS 13.0, *)
    /// Decodes a spatial, resolution, or quality subset of one qualified frame.
    public func frame(
        at index: Int,
        partial request: DicomPartialFrameDecodeRequest
    ) async throws -> DicomPartialFrameDecodeResult {
        guard decoder.fileReadSucceeded else {
            throw ReadError.noPixelData
        }
        let count = frameCount
        guard index >= 0, index < count else {
            throw ReadError.frameIndexOutOfRange(index: index, frameCount: count)
        }
        guard DicomJ2KSwiftBackend.qualifiedTransferSyntaxes.contains(decoder.transferSyntaxUID) else {
            throw DicomPartialFrameDecodeError.unsupportedTransferSyntax(decoder.transferSyntaxUID)
        }
        guard DicomJ2KSwiftRolloutMode() != .disabled else {
            throw DicomPartialFrameDecodeError.backendDisabled
        }

        try Task.checkCancellation()
        let frameData = try compressedFrameData(at: index)
        let info = try DicomJ2KCodestreamInfo.parse(frameData)
        guard request.resolutionReductionLevel <= info.decompositionLevels else {
            throw DicomPartialFrameDecodeError.invalidResolutionReductionLevel(
                requested: request.resolutionReductionLevel,
                maximum: info.decompositionLevels
            )
        }
        if let layer = request.maximumQualityLayer {
            guard layer < info.qualityLayerCount else {
                throw DicomPartialFrameDecodeError.invalidQualityLayer(
                    requested: layer,
                    count: info.qualityLayerCount
                )
            }
            let finalLayer = info.qualityLayerCount - 1
            if request.requiresFinalQuality, layer < finalLayer {
                throw DicomPartialFrameDecodeError.finalQualityUnavailable(
                    requestedLayer: layer,
                    finalLayer: finalLayer
                )
            }
        }

        let sourceRegion = try clippedRegion(request.sourceRegion)
        let hasSpatialReduction = request.sourceRegion != nil || request.resolutionReductionLevel > 0
        if request.maximumQualityLayer != nil, hasSpatialReduction {
            throw DicomPartialFrameDecodeError.unsupportedCombination
        }

        let descriptor = compressedFrameDescriptor()
        let partialRequest = DicomPartialDecodeRequest(
            region: request.sourceRegion == nil ? nil : DicomPartialDecodeRequest.Region(
                x: sourceRegion.x,
                y: sourceRegion.y,
                width: sourceRegion.width,
                height: sourceRegion.height
            ),
            resolutionLevel: request.resolutionReductionLevel > 0
                ? info.decompositionLevels - request.resolutionReductionLevel
                : nil,
            maximumQualityLayer: request.maximumQualityLayer
        )
        let decodeRequest = DicomFrameDecodeRequest(
            frameData: frameData,
            descriptor: descriptor,
            frameIndex: index,
            partialRequest: partialRequest
        )

        let decoded: DicomCodecDecodedFrame
        do {
            guard let result = try await DicomJ2KSwiftFrameDecoder.decode(
                decodeRequest,
                report: { telemetry in
                    decoder.logger.info(Self.telemetryMessage(telemetry))
                }
            ) else {
                throw DicomPartialFrameDecodeError.backendDisabled
            }
            decoded = result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DicomPartialFrameDecodeError {
            throw error
        } catch {
            throw DicomPartialFrameDecodeError.decodeFailed(error.localizedDescription)
        }
        try Task.checkCancellation()

        guard let result = DCMPixelReader.makeCompressedResult(
            from: decoded,
            pixelRepresentation: decoder.pixelRepresentationTagValue,
            photometricInterpretation: decoder.photometricInterpretation
        ), let pixels = Self.typedPixels(from: result) else {
            throw DicomPartialFrameDecodeError.decodeFailed(
                "the backend did not produce a typed pixel buffer"
            )
        }
        let frame = DicomDecodedFrame(
            index: index,
            pixels: pixels,
            metadata: makeMetadata(width: result.width, height: result.height, frameCount: count)
        )
        let execution: DicomPartialFrameDecodeResult.Execution
        switch (request.sourceRegion != nil, request.resolutionReductionLevel > 0, request.maximumQualityLayer != nil) {
        case (false, false, false): execution = .fullFrame
        case (true, false, false): execution = .directRegion
        case (false, true, false): execution = .directResolution
        case (true, true, false): execution = .directRegionAndResolution
        case (false, false, true): execution = .directQualityLayer
        case (_, _, true): throw DicomPartialFrameDecodeError.unsupportedCombination
        }
        let qualityState: DicomPartialFrameDecodeResult.QualityState
        if let layer = request.maximumQualityLayer, layer < info.qualityLayerCount - 1 {
            qualityState = layer == 0 ? .preview : .refinement(layer: layer)
        } else {
            qualityState = .final
        }
        return DicomPartialFrameDecodeResult(
            frame: frame,
            decodedSourceRegion: sourceRegion,
            coordinateTransform: DicomPartialFrameDecodeResult.CoordinateTransform(
                sourceRegion: sourceRegion,
                outputWidth: result.width,
                outputHeight: result.height
            ),
            deliveredQualityLayer: request.maximumQualityLayer,
            qualityState: qualityState,
            execution: execution
        )
    }

    /// Streams decoded frames one at a time (memory-bounded: only the
    /// in-flight frame is materialized). Cancelling the consuming task
    /// stops decoding before the next frame.
    @available(macOS 10.15, iOS 13.0, *)
    /// Streams decoded frames and stops producing values when the task is cancelled.
    public func frames(in range: Range<Int>? = nil) -> AsyncThrowingStream<DicomDecodedFrame, Error> {
        let reader = self
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let resolvedRange = range ?? 0..<reader.frameCount
                    for index in resolvedRange {
                        try Task.checkCancellation()
                        continuation.yield(try await reader.frame(at: index))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Native path

    private func decodeNativeFrame(at index: Int, frameCount: Int) throws -> DicomDecodedFrame {
        guard let descriptor = decoder.pixelDataDescriptor,
              let byteRange = descriptor.byteRange(forFrame: index) else {
            throw ReadError.noPixelData
        }
        let result = DCMPixelReader.readPixels(
            data: decoder.dicomDataSnapshot(),
            width: descriptor.columns,
            height: descriptor.rows,
            bitDepth: descriptor.bitsAllocated,
            samplesPerPixel: descriptor.samplesPerPixel,
            offset: byteRange.lowerBound,
            pixelRepresentation: decoder.pixelRepresentationTagValue,
            littleEndian: decoder.currentLittleEndian(),
            photometricInterpretation: descriptor.photometricInterpretation
        )
        guard let pixels = Self.typedPixels(from: result) else {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: "native \(descriptor.bitsAllocated)-bit, \(descriptor.samplesPerPixel)-sample layout"
                    + " is not representable as gray8/gray16/rgb8"
            )
        }
        return DicomDecodedFrame(
            index: index,
            pixels: pixels,
            metadata: makeMetadata(width: descriptor.columns, height: descriptor.rows, frameCount: frameCount)
        )
    }

    // MARK: - Compressed path

    @available(macOS 10.15, iOS 13.0, *)
    private func decodeJ2KFrame(
        at index: Int,
        frameCount: Int,
        environment: [String: String]
    ) async throws -> DicomDecodedFrameExecution {
        let frameData = try compressedFrameData(at: index)
        let descriptor = compressedFrameDescriptor()
        let request = DicomFrameDecodeRequest(
            frameData: frameData,
            descriptor: descriptor,
            frameIndex: index
        )

        let telemetry = DicomJ2KTelemetryProbe()
        let decoded: DicomCodecDecodedFrame?
        do {
            decoded = try await DicomJ2KSwiftFrameDecoder.decode(request, environment: environment) { event in
                telemetry.append(event)
                decoder.logger.info(Self.telemetryMessage(event))
            }
        } catch {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: error.localizedDescription
            )
        }

        guard let decoded else {
            let reader = self
            return try await Task.detached(priority: .userInitiated) {
                let frame = try reader.decodeCompressedFrame(at: index, frameCount: frameCount)
                return reader.execution(
                    frame: frame,
                    environment: environment,
                    rolloutMode: DicomJ2KSwiftRolloutMode(environment: environment).rawValue,
                    fallbackReason: "The J2KSwift rollout backend is disabled or ineligible.",
                    shadowBackendIdentifier: nil
                )
            }.value
        }
        guard let result = DCMPixelReader.makeCompressedResult(
            from: decoded,
            pixelRepresentation: decoder.pixelRepresentationTagValue,
            photometricInterpretation: decoder.photometricInterpretation
        ), let pixels = Self.typedPixels(from: result) else {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: "the selected async codec backend did not produce a typed pixel buffer"
            )
        }
        let frame = DicomDecodedFrame(
            index: index,
            pixels: pixels,
            metadata: makeMetadata(width: result.width, height: result.height, frameCount: frameCount)
        )
        let snapshot = telemetry.snapshot()
        return execution(
            frame: frame,
            selectedBackendIdentifier: snapshot.selectedBackendIdentifier,
            environment: environment,
            rolloutMode: snapshot.mode,
            fallbackReason: snapshot.fallbackReason,
            shadowBackendIdentifier: snapshot.shadowBackendIdentifier
        )
    }

    @available(macOS 10.15, iOS 13.0, *)
    private func decodeJPEGLSFrame(
        at index: Int,
        frameCount: Int,
        environment: [String: String]
    ) async throws -> DicomDecodedFrameExecution {
        let request = DicomFrameDecodeRequest(
            frameData: try compressedFrameData(at: index),
            descriptor: compressedFrameDescriptor(),
            frameIndex: index
        )

        let telemetry = DicomJLSTelemetryProbe()
        let decoded: DicomCodecDecodedFrame?
        do {
            decoded = try await DicomJLSwiftFrameDecoder.decode(request, environment: environment) { event in
                telemetry.append(event)
                decoder.logger.info(Self.telemetryMessage(event))
            }
        } catch {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: error.localizedDescription
            )
        }
        guard let decoded else {
            let reader = self
            return try await Task.detached(priority: .userInitiated) {
                let frame = try reader.decodeCompressedFrame(at: index, frameCount: frameCount)
                return reader.execution(
                    frame: frame,
                    environment: environment,
                    rolloutMode: DicomJLSwiftRolloutMode(environment: environment).rawValue,
                    fallbackReason: "The JLSwift rollout backend is disabled or ineligible.",
                    shadowBackendIdentifier: nil
                )
            }.value
        }
        guard let result = DCMPixelReader.makeCompressedResult(
            from: decoded,
            pixelRepresentation: decoder.pixelRepresentationTagValue,
            photometricInterpretation: decoder.photometricInterpretation
        ), let pixels = Self.typedPixels(from: result) else {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: "the selected JPEG-LS backend did not produce a typed pixel buffer"
            )
        }
        let frame = DicomDecodedFrame(
            index: index,
            pixels: pixels,
            metadata: makeMetadata(width: result.width, height: result.height, frameCount: frameCount)
        )
        let snapshot = telemetry.snapshot()
        return execution(
            frame: frame,
            selectedBackendIdentifier: snapshot.selectedBackendIdentifier,
            environment: environment,
            rolloutMode: snapshot.mode,
            fallbackReason: snapshot.fallbackReason,
            shadowBackendIdentifier: snapshot.shadowBackendIdentifier
        )
    }

    @available(macOS 10.15, iOS 13.0, *)
    private func decodeJPEGXLFrame(
        at index: Int,
        frameCount: Int,
        environment: [String: String]
    ) async throws -> DicomDecodedFrameExecution {
        let request = DicomFrameDecodeRequest(
            frameData: try compressedFrameData(at: index),
            descriptor: compressedFrameDescriptor(),
            frameIndex: index
        )
        let decoded: DicomCodecDecodedFrame?
        do {
            decoded = try await DicomJXLSwiftFrameDecoder.decode(request, environment: environment) { telemetry in
                decoder.logger.info(
                    "JXLSwift frame=\(telemetry.frameIndex) compressed=\(telemetry.compressedBytes) "
                        + "decoded=\(telemetry.decodedBytes) duration=\(telemetry.duration) "
                        + "ratio=\(telemetry.compressionRatio) "
                        + "jpegBridge=\(telemetry.reconstructedJPEG) success=\(telemetry.succeeded)"
                )
            }
        } catch {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: error.localizedDescription
            )
        }
        guard let decoded,
              let result = DCMPixelReader.makeCompressedResult(
                from: decoded,
                pixelRepresentation: decoder.pixelRepresentationTagValue,
                photometricInterpretation: decoder.photometricInterpretation
              ),
              let pixels = Self.typedPixels(from: result) else {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: "the experimental JXLSwift backend did not produce a typed pixel buffer"
            )
        }
        let frame = DicomDecodedFrame(
            index: index,
            pixels: pixels,
            metadata: makeMetadata(width: result.width, height: result.height, frameCount: frameCount)
        )
        return execution(
            frame: frame,
            selectedBackendIdentifier: DicomCodecBackendIdentifier.jxlSwift.rawValue,
            environment: environment,
            rolloutMode: DicomJXLSwiftRolloutMode(environment: environment).rawValue,
            fallbackReason: nil,
            shadowBackendIdentifier: nil
        )
    }

    private func decodeCompressedFrame(at index: Int, frameCount: Int) throws -> DicomDecodedFrame {
        let transferSyntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID)
        let bitsStored = decoder.intValue(for: Int(DicomTag.bitsStored.rawValue))
        let decision = DicomCompressedPixelBackendResolver.resolve(
            transferSyntax: transferSyntax,
            requestedBitDepth: decoder.bitDepth,
            samplesPerPixel: decoder.samplesPerPixel,
            photometricInterpretation: decoder.photometricInterpretation,
            bitsStored: bitsStored
        )
        if decision.backend == .unsupported {
            throw ReadError.unsupportedTransferSyntax(
                uid: decoder.transferSyntaxUID,
                diagnostics: decision.diagnostics
            )
        }

        let result: DCMPixelReadResult?
        do {
            let encapsulated = try decoder.makeEncapsulatedPixelFrameReader()
            result = DCMPixelReader.decodeCompressedFrameData(
                data: try encapsulated.frameData(at: index),
                transferSyntax: transferSyntax,
                width: decoder.width,
                height: decoder.height,
                bitDepth: decoder.bitDepth,
                samplesPerPixel: decoder.samplesPerPixel,
                pixelRepresentation: decoder.pixelRepresentationTagValue,
                photometricInterpretation: decoder.photometricInterpretation,
                bitsStored: bitsStored
            )
        } catch let error as DicomEncapsulatedPixelFrameReader.ReaderError {
            switch error {
            case .notEncapsulated:
                // Defined-length compressed payload: one addressable frame
                // starting at the Pixel Data value offset.
                result = DCMPixelReader.decodeCompressedPixelData(
                    data: decoder.dicomDataSnapshot(),
                    offset: decoder.offset,
                    transferSyntax: transferSyntax,
                    width: decoder.width,
                    height: decoder.height,
                    bitDepth: decoder.bitDepth,
                    samplesPerPixel: decoder.samplesPerPixel,
                    pixelRepresentation: decoder.pixelRepresentationTagValue,
                    photometricInterpretation: decoder.photometricInterpretation,
                    bitsStored: bitsStored
                )
            case .unusableFrameMap(let diagnostics):
                throw ReadError.unusableEncapsulation(diagnostics: diagnostics.map(\.message))
            case .frameIndexOutOfRange(let index, let frameCount):
                throw ReadError.frameIndexOutOfRange(index: index, frameCount: frameCount)
            case .declaredFrameCountMismatch(let declared, let mapped):
                throw ReadError.unusableEncapsulation(
                    diagnostics: ["NumberOfFrames declares \(declared) frame(s) but \(mapped) were mapped."]
                )
            }
        }

        guard let result, let pixels = Self.typedPixels(from: result) else {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: "the \(decision.backend) backend did not produce a typed pixel buffer"
            )
        }
        return DicomDecodedFrame(
            index: index,
            pixels: pixels,
            metadata: makeMetadata(width: result.width, height: result.height, frameCount: frameCount)
        )
    }

    // MARK: - Shared helpers

    private func compressedFrameData(at index: Int) throws -> Data {
        do {
            let encapsulated = try decoder.makeEncapsulatedPixelFrameReader()
            return try encapsulated.frameData(at: index)
        } catch let error as DicomEncapsulatedPixelFrameReader.ReaderError {
            switch error {
            case .notEncapsulated:
                let data = decoder.dicomDataSnapshot()
                guard decoder.offset > 0, decoder.offset <= data.count else {
                    throw ReadError.decodeFailed(
                        transferSyntaxUID: decoder.transferSyntaxUID,
                        reason: "the defined-length compressed Pixel Data offset is invalid"
                    )
                }
                return data.subdata(in: decoder.offset..<data.count)
            case .unusableFrameMap(let diagnostics):
                throw ReadError.unusableEncapsulation(diagnostics: diagnostics.map(\.message))
            case .frameIndexOutOfRange(let index, let frameCount):
                throw ReadError.frameIndexOutOfRange(index: index, frameCount: frameCount)
            case .declaredFrameCountMismatch(let declared, let mapped):
                throw ReadError.unusableEncapsulation(
                    diagnostics: ["NumberOfFrames declares \(declared) frame(s) but \(mapped) were mapped."]
                )
            }
        }
    }

    private func compressedFrameDescriptor() -> DicomCompressedFrameDescriptor {
        let bitsStored = decoder.intValue(for: Int(DicomTag.bitsStored.rawValue)) ?? decoder.bitDepth
        return DicomCompressedFrameDescriptor(
            transferSyntaxUID: decoder.transferSyntaxUID,
            rows: decoder.height,
            columns: decoder.width,
            bitsAllocated: decoder.bitDepth,
            bitsStored: bitsStored,
            highBit: decoder.intValue(for: Int(DicomTag.highBit.rawValue)) ?? max(0, bitsStored - 1),
            pixelRepresentation: decoder.pixelRepresentationTagValue,
            samplesPerPixel: decoder.samplesPerPixel,
            photometricInterpretation: decoder.photometricInterpretation,
            planarConfiguration: decoder.intValue(for: Int(DicomTag.planarConfiguration.rawValue))
        )
    }

    private func clippedRegion(_ requested: DicomFrameRegion?) throws -> DicomFrameRegion {
        let full = DicomFrameRegion(x: 0, y: 0, width: decoder.width, height: decoder.height)
        guard let requested else { return full }
        guard requested.width > 0, requested.height > 0 else {
            throw DicomPartialFrameDecodeError.invalidRegion
        }
        let maximumXResult = requested.x.addingReportingOverflow(requested.width)
        let maximumYResult = requested.y.addingReportingOverflow(requested.height)
        let maximumX = maximumXResult.overflow ? Int.max : maximumXResult.partialValue
        let maximumY = maximumYResult.overflow ? Int.max : maximumYResult.partialValue
        let clippedX = max(0, requested.x)
        let clippedY = max(0, requested.y)
        let clippedMaximumX = min(decoder.width, maximumX)
        let clippedMaximumY = min(decoder.height, maximumY)
        guard clippedMaximumX > clippedX, clippedMaximumY > clippedY else {
            throw DicomPartialFrameDecodeError.invalidRegion
        }
        return DicomFrameRegion(
            x: clippedX,
            y: clippedY,
            width: clippedMaximumX - clippedX,
            height: clippedMaximumY - clippedY
        )
    }

    private func makeMetadata(width: Int, height: Int, frameCount: Int? = nil) -> DicomDecodedFrameMetadata {
        let bitsAllocated = decoder.bitDepth
        let bitsStored = decoder.intValue(for: Int(DicomTag.bitsStored.rawValue)) ?? bitsAllocated
        let window = decoder.windowSettingsV2
        return DicomDecodedFrameMetadata(
            width: width,
            height: height,
            frameCount: frameCount ?? self.frameCount,
            bitsAllocated: bitsAllocated,
            bitsStored: bitsStored,
            highBit: decoder.intValue(for: Int(DicomTag.highBit.rawValue)) ?? max(0, bitsStored - 1),
            pixelRepresentation: decoder.pixelRepresentationTagValue,
            samplesPerPixel: decoder.samplesPerPixel,
            photometricInterpretation: decoder.photometricInterpretation,
            planarConfiguration: decoder.intValue(for: Int(DicomTag.planarConfiguration.rawValue)),
            transferSyntaxUID: decoder.transferSyntaxUID,
            windowSettings: window.isValid ? window : nil,
            rescaleParameters: decoder.rescaleParametersV2,
            smallestImagePixelValue: decoder.intValue(for: 0x0028_0106),
            largestImagePixelValue: decoder.intValue(for: 0x0028_0107)
        )
    }

    private static func typedPixels(from result: DCMPixelReadResult) -> DicomDecodedFramePixelBuffer? {
        if let interleaved = result.pixels24 {
            return .rgb8(interleaved: interleaved)
        }
        if let pixels = result.pixels16 {
            return .gray16(pixels)
        }
        if let pixels = result.pixels8 {
            return .gray8(pixels)
        }
        return nil
    }

    private func execution(
        frame: DicomDecodedFrame,
        selectedBackendIdentifier: String? = nil,
        environment: [String: String],
        rolloutMode: String?,
        fallbackReason: String?,
        shadowBackendIdentifier: String?
    ) -> DicomDecodedFrameExecution {
        if !decoder.compressedImage {
            return DicomDecodedFrameExecution(
                frame: frame,
                backendIdentifier: "native-uncompressed",
                backendSource: .packageLinked,
                rolloutMode: rolloutMode,
                fallbackReason: fallbackReason,
                shadowBackendIdentifier: shadowBackendIdentifier
            )
        }

        let identifier = selectedBackendIdentifier ?? legacyBackendIdentifier()
        let status = DicomCodecCapabilities.backendStatuses(environment: environment)
            .first { $0.identifier == identifier }
        let directCapability = directCapability(identifier: identifier, environment: environment)
        return DicomDecodedFrameExecution(
            frame: frame,
            backendIdentifier: identifier,
            backendVersion: status?.version ?? directCapability?.version,
            backendSource: status?.source ?? directCapability?.source ?? legacyBackendSource(identifier: identifier),
            rolloutMode: rolloutMode,
            fallbackReason: fallbackReason,
            shadowBackendIdentifier: shadowBackendIdentifier
        )
    }

    private func directCapability(
        identifier: String,
        environment: [String: String]
    ) -> DicomFrameCodecCapabilities? {
        switch identifier {
        case DicomCodecBackendIdentifier.j2kSwiftCPU.rawValue:
            return DicomJ2KSwiftBackend().capabilities
        case DicomCodecBackendIdentifier.openJPEGCPU.rawValue:
            return DicomOpenJPEGFrameBackend().capabilities
        case DicomCodecBackendIdentifier.jlSwift.rawValue:
            return DicomJLSwiftBackend().capabilities
        case DicomCodecBackendIdentifier.charLSCPU.rawValue:
            return DicomCharLSFrameBackend(environment: environment).capabilities
        case DicomCodecBackendIdentifier.jxlSwift.rawValue:
            return DicomJXLSwiftBackend().capabilities
        default:
            return nil
        }
    }

    private func legacyBackendIdentifier() -> String {
        let decision = DicomCompressedPixelBackendResolver.resolve(
            transferSyntax: DicomTransferSyntax(uid: decoder.transferSyntaxUID),
            requestedBitDepth: decoder.bitDepth,
            samplesPerPixel: decoder.samplesPerPixel,
            photometricInterpretation: decoder.photometricInterpretation,
            bitsStored: decoder.intValue(for: Int(DicomTag.bitsStored.rawValue))
        )
        switch decision.backend {
        case .nativeJPEGLossless: return "native-jpeg-lossless"
        case .nativeRLELossless: return "native-rle-lossless"
        case .nativeJPEGLS: return DicomCodecBackendIdentifier.charLSCPU.rawValue
        case .nativeJPEGExtended: return "native-jpeg-extended"
        case .imageIOJPEGBaseline: return "imageio-jpeg-baseline"
        case .imageIOJPEGExtended: return "imageio-jpeg-extended"
        case .imageIOJPEG2000: return "imageio-jpeg-2000"
        case .openJPEG2000: return "openjpeg-jpeg-2000"
        case .openJPEGHTJ2K: return "openjpeg-htj2k"
        case .legacyImageIO: return "imageio-legacy"
        case .unsupported: return "unsupported"
        }
    }

    private func legacyBackendSource(identifier: String) -> DicomCodecBackendSource {
        if identifier.hasPrefix("imageio-") {
            return .systemFramework
        }
        if identifier == DicomCodecBackendIdentifier.openJPEGCPU.rawValue
            || identifier.hasPrefix("openjpeg-") {
            return DicomOpenJPEGFrameBackend().capabilities.source
        }
        if identifier == DicomCodecBackendIdentifier.charLSCPU.rawValue {
            return DicomCharLSFrameBackend().capabilities.source
        }
        return identifier == "unsupported" ? .unavailable : .packageLinked
    }

    private static func telemetryMessage(_ telemetry: DicomJ2KSwiftDecodeTelemetry) -> String {
        let dimensions = telemetry.width.flatMap { width in
            telemetry.height.map { "\(width)x\($0)" }
        } ?? "unknown"
        let durationMilliseconds = Double(telemetry.durationNanoseconds) / 1_000_000
        return "J2K rollout mode=\(telemetry.mode.rawValue) backend=\(telemetry.backend.rawValue)"
            + " duration_ms=\(String(format: "%.3f", durationMilliseconds)) dimensions=\(dimensions)"
            + " outcome=\(telemetry.outcome)"
    }

    private static func telemetryMessage(_ telemetry: DicomJLSwiftDecodeTelemetry) -> String {
        let dimensions = telemetry.width.flatMap { width in
            telemetry.height.map { "\(width)x\($0)" }
        } ?? "unknown"
        let durationMilliseconds = Double(telemetry.durationNanoseconds) / 1_000_000
        return "JPEG-LS rollout mode=\(telemetry.mode.rawValue) backend=\(telemetry.backend.rawValue)"
            + " duration_ms=\(String(format: "%.3f", durationMilliseconds)) dimensions=\(dimensions)"
            + " outcome=\(telemetry.outcome)"
    }
}

private struct DicomCodecTelemetrySnapshot {
    let selectedBackendIdentifier: String?
    let mode: String?
    let fallbackReason: String?
    let shadowBackendIdentifier: String?
}

private final class DicomJ2KTelemetryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DicomJ2KSwiftDecodeTelemetry] = []

    func append(_ event: DicomJ2KSwiftDecodeTelemetry) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> DicomCodecTelemetrySnapshot {
        lock.lock()
        let captured = events
        lock.unlock()
        let selected = captured.last { event in
            if case .succeeded = event.outcome { return true }
            return false
        }
        let fallback = captured.compactMap { event -> String? in
            if case .fellBack(let reason) = event.outcome { return reason }
            return nil
        }.last
        let mode = captured.first?.mode
        return DicomCodecTelemetrySnapshot(
            selectedBackendIdentifier: selected?.backend.rawValue,
            mode: mode?.rawValue,
            fallbackReason: fallback,
            shadowBackendIdentifier: mode == .shadow ? DicomCodecBackendIdentifier.j2kSwiftCPU.rawValue : nil
        )
    }
}

private final class DicomJLSTelemetryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DicomJLSwiftDecodeTelemetry] = []

    func append(_ event: DicomJLSwiftDecodeTelemetry) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> DicomCodecTelemetrySnapshot {
        lock.lock()
        let captured = events
        lock.unlock()
        let selected = captured.last { event in
            if case .succeeded = event.outcome { return true }
            return false
        }
        let fallback = captured.compactMap { event -> String? in
            if case .fellBack(let reason) = event.outcome { return reason }
            return nil
        }.last
        let mode = captured.first?.mode
        return DicomCodecTelemetrySnapshot(
            selectedBackendIdentifier: selected?.backend.rawValue,
            mode: mode?.rawValue,
            fallbackReason: fallback,
            shadowBackendIdentifier: mode == .shadow ? DicomCodecBackendIdentifier.jlSwift.rawValue : nil
        )
    }
}
