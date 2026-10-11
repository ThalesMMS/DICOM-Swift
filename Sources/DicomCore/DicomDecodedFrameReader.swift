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
import DicomJPEG2000

/// Typed decoded pixel payload of a single frame.
public enum DicomDecodedFramePixelBuffer: Equatable, Sendable {
    /// 8-bit grayscale samples (MONOCHROME1 already inverted).
    case gray8([UInt8])
    /// 16-bit grayscale samples (signed values offset to unsigned,
    /// MONOCHROME1 already inverted) — same contract as `getPixels16()`.
    case gray16([UInt16])
    /// Interleaved 8-bit R,G,B triplets.
    case rgb8(interleaved: [UInt8])
    /// Interleaved R,G,B triplets of 9 to 16 stored bits (issue #3034): the stored sample values, unscaled and
    /// right-aligned (bits above Bits Stored cleared), whatever the source byte order and Planar Configuration.
    /// The frame metadata reports the effective Bits Stored and a High Bit of Bits Stored - 1.
    case rgb16(interleaved: [UInt16])

    /// Number of addressable pixel samples in the buffer.
    public var sampleCount: Int {
        switch self {
        case .gray8(let pixels): return pixels.count
        case .gray16(let pixels): return pixels.count
        case .rgb8(let interleaved): return interleaved.count / 3
        case .rgb16(let interleaved): return interleaved.count / 3
        }
    }

    /// True for the three-sample layouts.
    var isColor: Bool {
        switch self {
        case .rgb8, .rgb16: return true
        case .gray8, .gray16: return false
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
    /// Shared Enhanced Frame VOI Functional Group, when present.
    public let sharedFrameVOI: DicomFrameVOI?
    /// Per-frame Enhanced Frame VOI Functional Group, when present.
    public let perFrameVOI: DicomFrameVOI?
    /// Modality rescale slope and intercept.
    public let rescaleParameters: RescaleParameters
    /// Smallest stored image pixel value declared by the object.
    public let smallestImagePixelValue: Int?
    /// Largest stored image pixel value declared by the object.
    public let largestImagePixelValue: Int?
    /// Valid VOI LUT Sequence items, in dataset order (issue #1865 phase A).
    /// Malformed items are dropped with a typed reason available through
    /// `DCMDecoder.validatedVOILookupTables()`; they never fail the decode.
    public let voiLUTs: [DicomLookupTable]
    /// DICOM VOI LUT Function applied to linear window settings, when present.
    public let voiLUTFunction: String?
    /// Pixel Padding Value in the stored pixel domain, when present.
    public let pixelPaddingValue: Double?
    /// Pixel Padding Range Limit in the stored pixel domain, when present.
    public let pixelPaddingRangeLimit: Double?
    /// Actual presentation unit declared by the object, such as BQML or CNTS.
    public let presentationUnits: String?
    /// Rescale Type (0028,1054), the unit of the rescaled values: an Enhanced frame's per-frame Pixel Value
    /// Transformation, else the shared one, else the top level (issue #3037).
    public let rescaleType: String?
    /// Valid Modality LUT Sequence (0028,3000) items; the first replaces the rescale (PS3.3 C.11.1.1.2, issue #3037).
    public let modalityLUTs: [DicomLookupTable]
    /// Pixel Spacing (0028,0030) as row then column spacing: an Enhanced frame's Pixel Measures, else the top level;
    /// empty when absent (issue #3037).
    public let pixelSpacing: [Double]
    /// Imager Pixel Spacing (0018,1164), row then column; empty when absent.
    public let imagerPixelSpacing: [Double]
    /// Nominal Scanned Pixel Spacing (0018,2010), row then column; empty when absent.
    public let nominalScannedPixelSpacing: [Double]
    /// Pixel Spacing Calibration Type (0028,0A02), when present.
    public let pixelSpacingCalibrationType: String?
}

/// One decoded frame: typed pixels plus renderer-facing metadata.
public struct DicomDecodedFrame: Equatable, Sendable {
    /// Zero-based source frame index.
    public let index: Int
    /// Typed grayscale or RGB pixel storage.
    public let pixels: DicomDecodedFramePixelBuffer
    /// Renderer-facing metadata for the decoded output.
    public let metadata: DicomDecodedFrameMetadata
    /// Host allocation accounting, shared by value copies of these same pixels.
    public let memoryOwner: (any DicomFrameMemoryOwner)?

    init(index: Int, pixels: DicomDecodedFramePixelBuffer, metadata: DicomDecodedFrameMetadata,
         memoryOwner: (any DicomFrameMemoryOwner)? = nil) {
        self.index = index
        self.pixels = pixels
        self.metadata = metadata
        self.memoryOwner = memoryOwner
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.index == rhs.index && lhs.pixels == rhs.pixels && lhs.metadata == rhs.metadata
    }
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
            // JPEG 2000 Part 2 objects carry their frames as codestream components (PS3.5 8.2.4): the fragments are
            // component collections, so the declared frame count is the authority (#2331).
            if DicomJ2KPart2Profile.isPart2(decoder.transferSyntaxUID) {
                return decoder.fileReadSucceeded ? max(1, decoder.nImages) : 0
            }
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
            if DicomJ2KPart2Profile.isPart2(decoder.transferSyntaxUID) {
                return try part2Frame(at: index, frameCount: count, environment: ProcessInfo.processInfo.environment)
            }
            return try decodeCompressedFrame(at: index, frameCount: count)
        }
        return try decodeNativeFrame(at: index, frameCount: count)
    }

    /// Cancellation-aware variant: the decode runs off the caller's thread
    /// and honors `Task` cancellation before extraction starts.
    /// Decodes one frame asynchronously while honoring task cancellation.
    public func frame(at index: Int) async throws -> DicomDecodedFrame {
        try await frameExecution(at: index).frame
    }

    /// Decodes one frame into an immutable Data-backed pixel buffer.
    ///
    /// Synchronous codec backends may copy their array result into canonical Data. Use the async overload to retain
    /// eligible JPEG-LS, JPEG 2000, and experimental JPEG XL backend Data without materializing the compatibility
    /// array. Signed or MONOCHROME1 samples still require canonical normalization storage.
    public func dataBackedFrame(at index: Int) throws -> DicomDataBackedDecodedFrame {
        try dataBackedFrameSynchronously(at: index)
    }

    /// Decodes one frame asynchronously, preserving eligible codec-owned Data without a compatibility-array copy.
    /// Canonical signedness, MONOCHROME1, or endian conversion can still allocate normalized Data.
    public func dataBackedFrame(at index: Int) async throws -> DicomDataBackedDecodedFrame {
        try await dataBackedFrame(at: index, environment: ProcessInfo.processInfo.environment)
    }

    func dataBackedFrame(
        at index: Int,
        environment: [String: String]
    ) async throws -> DicomDataBackedDecodedFrame {
        try Task.checkCancellation()
        guard decoder.fileReadSucceeded else {
            throw ReadError.noPixelData
        }
        let count = frameCount
        guard index >= 0, index < count else {
            throw ReadError.frameIndexOutOfRange(index: index, frameCount: count)
        }

        if decoder.compressedImage {
            let decision = DicomCodecCapabilities.resolve(
                DicomCodecCapabilityRequest(operation: .decode, descriptor: compressedFrameDescriptor()),
                environment: environment
            )
            guard decision.canExecute else {
                throw ReadError.unsupportedTransferSyntax(
                    uid: decoder.transferSyntaxUID, diagnostics: [decision.reason ?? "No qualified decoder is available."]
                )
            }
        }
        if decoder.compressedImage, DicomJ2KPart2Profile.isPart2(decoder.transferSyntaxUID) {
            let decoded = try await part2CodecFrame(at: index, frameCount: count, environment: environment).frame
            return try makeDataBackedFrame(from: decoded, index: index, frameCount: count)
        }
        if decoder.compressedImage,
           let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID),
           let family = DicomCodecFamily.family(for: syntax) {
            if family == .jpeg2000 || family == .htj2k {
                return try await decodeJ2KDataBackedFrame(
                    at: index,
                    frameCount: count,
                    environment: environment
                )
            }
            if family == .jpegLS {
                return try await decodeJLSDataBackedFrame(
                    at: index,
                    frameCount: count,
                    environment: environment
                )
            }
            if family == .jpegXL,
               DicomJXLSwiftRolloutMode(environment: environment) != .disabled {
                return try await decodeJXLDataBackedFrame(
                    at: index,
                    frameCount: count,
                    environment: environment
                )
            }
        }

        return try await detachedSynchronousDataBackedFrame(
            at: index,
            environment: environment
        )
    }

    /// Returns a pull-based frame sequence. Each `next()` decodes exactly one frame and no producer runs ahead.
    public func dataBackedFrames(
        in range: Range<Int>? = nil
    ) -> DicomDataBackedDecodedFrameSequence {
        DicomDataBackedDecodedFrameSequence(reader: self, range: range ?? 0..<frameCount)
    }

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
        try Task.checkCancellation()
        if decoder.compressedImage {
            let decision = DicomCodecCapabilities.resolve(
                DicomCodecCapabilityRequest(operation: .decode, descriptor: compressedFrameDescriptor()),
                environment: environment
            )
            guard decision.canExecute else {
                throw ReadError.unsupportedTransferSyntax(
                    uid: decoder.transferSyntaxUID, diagnostics: [decision.reason ?? "No qualified decoder is available."]
                )
            }
        }
        if decoder.compressedImage, DicomJ2KPart2Profile.isPart2(decoder.transferSyntaxUID) {
            let decoded = try await part2CodecFrame(at: index, frameCount: count, environment: environment)
            return try part2Execution(decoded.frame, index: index, frameCount: count, environment: environment, mode: decoded.mode)
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
        if decoder.compressedImage,
           let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID),
           DicomCodecFamily.family(for: syntax) == .jpeg,
           DicomJPEGSwiftRolloutMode(environment: environment) != .disabled,
           let execution = try await decodeJPEGFrame(at: index, frameCount: count, environment: environment) {
            return execution
        }

        let reader = self
        return try await DicomCancellableDetachedOperation.run {
            try Task.checkCancellation()
            let frame = try reader.frame(at: index)
            return reader.execution(
                frame: frame,
                environment: environment,
                rolloutMode: nil,
                fallbackReason: nil,
                shadowBackendIdentifier: nil
            )
        }
    }

    /// Reports codestream-qualified partial-decode capabilities for one frame.
    /// Unsupported transfer syntaxes return `.unavailable`; malformed frame
    /// mappings or codestream headers remain typed errors.
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
            supportsQualityWithSpatialReduction: true,
            maximumResolutionReductionLevel: info.decompositionLevels,
            qualityLayerCount: info.qualityLayerCount
        )
    }

    /// Capabilities plus the tier-2 packet index of the frame (bytes per quality layer, issue #2382). Costs one
    /// packet-header parse of the codestream (no entropy decode); use it only when the consumer needs the
    /// incremental cost of a low-layer preview.
    public func partialDecodeCapabilitiesWithQualityIndex(at index: Int) async throws -> DicomPartialFrameDecodeCapabilities {
        let base = try await partialDecodeCapabilities(at: index)
        guard base != .unavailable, let layers = base.qualityLayerCount, layers > 1 else { return base }
        let frameData = try compressedFrameData(at: index)
        let codestream = try DicomJ2KCodestreamInspector.unwrap(frameData).codestream
        let totals = try await J2KQualityRefinementSession(data: codestream).index()
        return DicomPartialFrameDecodeCapabilities(
            supportsRegion: base.supportsRegion, supportsResolutionReduction: base.supportsResolutionReduction,
            supportsQualityLayers: base.supportsQualityLayers, supportsCombinedRegionAndResolution: base.supportsCombinedRegionAndResolution,
            supportsQualityWithSpatialReduction: base.supportsQualityWithSpatialReduction,
            maximumResolutionReductionLevel: base.maximumResolutionReductionLevel, qualityLayerCount: base.qualityLayerCount,
            qualityLayerByteTotals: totals
        )
    }

    /// Executes a qualified JPEG 2000 partial decode without materializing a
    /// full frame. Callers choose any non-JPEG-2000 fallback explicitly.
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
            metadata: makeMetadata(
                width: result.width,
                height: result.height,
                frameCount: count,
                frameIndex: index,
                codestreamPrecision: decoded.bitsPerSample,
                decodedSampleBits: result.bitDepth
            )
        )
        // A quality limit combined with a spatial subset keeps the spatial execution; `qualityState`,
        // `deliveredQualityLayer` and `codecBytesAvoided` carry the layer side (issue #2382).
        let execution: DicomPartialFrameDecodeResult.Execution
        switch (request.sourceRegion != nil, request.resolutionReductionLevel > 0, request.maximumQualityLayer != nil) {
        case (false, false, false): execution = .fullFrame
        case (true, false, _): execution = .directRegion
        case (false, true, _): execution = .directResolution
        case (true, true, _): execution = .directRegionAndResolution
        case (false, false, true): execution = .directQualityLayer
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
            execution: execution,
            codecBytesAvoided: decoded.codecBytesAvoided
        )
    }

    /// Pulls one decoded frame per iterator advance, with no producer task or
    /// unbounded stream buffer. Cancellation is checked before each decode.
    public func frames(in range: Range<Int>? = nil) -> AsyncThrowingStream<DicomDecodedFrame, Error> {
        let cursor = DicomDecodedFrameStreamCursor(reader: self, range: range ?? 0..<frameCount)
        return AsyncThrowingStream(unfolding: { try await cursor.next() })
    }

    // MARK: - Native path

    private func decodeNativeFrame(at index: Int, frameCount: Int) throws -> DicomDecodedFrame {
        try refuseUndefinedNativeColour()
        guard let descriptor = decoder.pixelDataDescriptor,
              let byteRange = descriptor.byteRange(forFrame: index) else {
            throw ReadError.noPixelData
        }
        // The whole-buffer reader addresses the file directly; the data-backed path restores the word order of
        // word-swapped 8-bit samples, unpacks 1-bit samples at their bit offset and right-aligns 16-bit colour
        // (issue #3034).
        if descriptor.eightBitSamplesAreWordSwapped || descriptor.bitsAllocated == 1
            || (descriptor.samplesPerPixel == 3 && descriptor.bitsAllocated == 16) {
            return try decodeNativeDataBackedFrame(at: index, frameCount: frameCount).copyingToArrayBackedFrame()
        }
        let pixels: DicomDecodedFramePixelBuffer
        if let interleaved = try interleavedNativeRGB(at: index, descriptor: descriptor) {
            pixels = .rgb8(interleaved: Array(interleaved))
        } else if Self.needsYBRTriplets(descriptor), let frame = decoder.getFrame(index) {
            pixels = .rgb8(interleaved: Array(try nativeYBRTriplets(frame.data, descriptor: descriptor)))
        } else {
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
            guard let decoded = Self.typedPixels(from: result) else {
                throw ReadError.decodeFailed(
                    transferSyntaxUID: decoder.transferSyntaxUID,
                    reason: "native \(descriptor.bitsAllocated)-bit, \(descriptor.samplesPerPixel)-sample layout"
                        + " is not representable as gray8/gray16/rgb8/rgb16"
                )
            }
            pixels = decoded
        }
        return DicomDecodedFrame(
            index: index,
            pixels: pixels,
            metadata: makeMetadata(
                width: descriptor.columns,
                height: descriptor.rows,
                frameCount: frameCount,
                frameIndex: index
            )
        )
    }

    private func interleavedNativeRGB(at index: Int, descriptor: DicomPixelDataDescriptor) throws -> Data? {
        guard descriptor.samplesPerPixel == 3, descriptor.bitsAllocated == 8,
              descriptor.photometricInterpretation == "RGB", descriptor.planarConfiguration == 1 else {
            return nil
        }
        return try decoder.displayRGBPixelBuffer(frame: index).rgbData
    }

    /// Native 8-bit YBR frames whose stored layout is not one Y Cb Cr triplet per pixel: YBR_FULL_422 (packed pairs)
    /// and YBR_FULL with Planar Configuration 1 (three planes).
    static func needsYBRTriplets(_ descriptor: DicomPixelDataDescriptor) -> Bool {
        guard descriptor.samplesPerPixel == 3, descriptor.bitsAllocated == 8 else { return false }
        return descriptor.photometricInterpretation == "YBR_FULL_422"
            || (descriptor.photometricInterpretation == "YBR_FULL" && descriptor.planarConfiguration == 1)
    }

    /// The frame as one Y Cb Cr triplet per pixel, the stored-sample layout of decoded colour frames; the label is
    /// kept and the YBR→RGB conversion stays a display operation (`DCMDecoder.displayRGB8(decodedFrame:)`).
    /// * YBR_FULL_422 stores Y1 Y2 Cb Cr for each pair of horizontally adjacent pixels (PS3.3 C.7.6.3.1.2); both
    ///   pixels of a pair take its chroma, as GDCM and pydicom expand it (issue #2821).
    /// * YBR_FULL with Planar Configuration 1 stores the Y, Cb and Cr planes one after the other; they are
    ///   interleaved here, as for RGB (issue #3036).
    private func nativeYBRTriplets(_ bytes: Data, descriptor: DicomPixelDataDescriptor) throws -> Data {
        let pixelCount = descriptor.rows * descriptor.columns
        guard descriptor.photometricInterpretation == "YBR_FULL_422" else {
            guard bytes.count >= pixelCount * 3 else { throw truncatedNativeFrame(descriptor) }
            return Self.interleavedPlanes(bytes, pixelCount: pixelCount, bytesPerSample: 1)
        }
        let pairs = pixelCount / 2
        guard bytes.count >= pairs * 4 else { throw truncatedNativeFrame(descriptor) }
        var output = Data(count: pairs * 6)
        bytes.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                for pair in 0 ..< pairs {
                    let y1 = source[pair * 4], y2 = source[pair * 4 + 1], cb = source[pair * 4 + 2], cr = source[pair * 4 + 3]
                    target[pair * 6] = y1
                    target[pair * 6 + 1] = cb
                    target[pair * 6 + 2] = cr
                    target[pair * 6 + 3] = y2
                    target[pair * 6 + 4] = cb
                    target[pair * 6 + 5] = cr
                }
            }
        }
        return output
    }

    private func truncatedNativeFrame(_ descriptor: DicomPixelDataDescriptor) -> ReadError {
        .decodeFailed(transferSyntaxUID: decoder.transferSyntaxUID,
                      reason: "native \(descriptor.photometricInterpretation) frame is shorter than its declared layout")
    }

    /// Native colour labels with no conversion in the typed pipeline are refused typed rather than delivered under a
    /// label that does not describe the samples (issue #3036):
    /// * YBR_PARTIAL_422 (retired) and YBR_PARTIAL_420 are partial range and would need their own equations;
    ///   PS3.3 defines YBR_PARTIAL_420 for MPEG-2, H.264 and HEVC streams only;
    /// * YBR_RCT and YBR_ICT name the JPEG 2000 codestream colour transform (PS3.5 8.2.4) and say nothing of
    ///   native samples;
    /// * YBR_FULL_422 pairs horizontally adjacent pixels, which an odd number of columns leaves undefined.
    private func refuseUndefinedNativeColour() throws {
        guard decoder.samplesPerPixel == 3 else { return }
        let photometric = decoder.photometricInterpretation.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let reason: String
        switch photometric {
        case "YBR_PARTIAL_422", "YBR_PARTIAL_420":
            reason = "native \(photometric) is partial-range YBR and has no conversion; full-range equations are not applied to it"
        case "YBR_RCT", "YBR_ICT":
            reason = "\(photometric) names a JPEG 2000 codestream colour transform; native samples under it are not interpreted"
        case "YBR_FULL_422" where !decoder.width.isMultiple(of: 2):
            reason = "native YBR_FULL_422 with an odd number of columns has no defined chroma pairing"
        default:
            return
        }
        throw ReadError.decodeFailed(transferSyntaxUID: decoder.transferSyntaxUID, reason: reason)
    }

    private func dataBackedFrameSynchronously(
        at index: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DicomDataBackedDecodedFrame {
        guard decoder.fileReadSucceeded else {
            throw ReadError.noPixelData
        }
        let count = frameCount
        guard index >= 0, index < count else {
            throw ReadError.frameIndexOutOfRange(index: index, frameCount: count)
        }
        if !decoder.compressedImage {
            return try decodeNativeDataBackedFrame(at: index, frameCount: count)
        }
        return try copyDataBackedFrame(
            from: decodeCompressedFrame(at: index, frameCount: count, environment: environment)
        )
    }

    private func decodeNativeDataBackedFrame(
        at index: Int,
        frameCount: Int
    ) throws -> DicomDataBackedDecodedFrame {
        try refuseUndefinedNativeColour()
        guard let descriptor = decoder.pixelDataDescriptor,
              let byteRange = descriptor.byteRange(forFrame: index),
              let bitRange = descriptor.bitRange(forFrame: index) else {
            throw ReadError.noPixelData
        }
        let source = decoder.dicomDataSnapshot()
        guard byteRange.lowerBound >= source.startIndex,
              byteRange.upperBound <= source.endIndex else {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: "native frame byte range is outside the source data"
            )
        }
        // Word-swapped 8-bit samples (OW under Explicit VR Big Endian) are restored to raster order here.
        guard let nativeBytes = descriptor.nativeFrameData(in: source, frame: index) else {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: "native frame byte range is outside the source data"
            )
        }
        let deepColor = descriptor.samplesPerPixel == 3 && descriptor.bitsAllocated == 16
        if deepColor {
            try validateNativeDeepColor(descriptor)
        }
        // Planar 16-bit RGB: the three planes are interleaved word by word in the source byte order; the
        // normalizer then masks Bits Stored and restores host order as for interleaved frames. 8-bit YBR_FULL_422 and
        // planar YBR_FULL become Y Cb Cr triplets from the restored bytes (issue #3036).
        let bytes = deepColor && descriptor.planarConfiguration == 1
            ? Self.interleavedPlanes(nativeBytes, pixelCount: descriptor.rows * descriptor.columns, bytesPerSample: 2)
            : Self.needsYBRTriplets(descriptor) ? try nativeYBRTriplets(nativeBytes, descriptor: descriptor)
            : try interleavedNativeRGB(at: index, descriptor: descriptor) ?? nativeBytes
        let byteOrder: DicomDecodedFrameByteOrder = decoder.currentLittleEndian() ? .littleEndian : .bigEndian
        guard let pixels = DicomDecodedFrameDataNormalizer.makeBuffer(
            data: bytes,
            width: descriptor.columns,
            height: descriptor.rows,
            bitsPerSample: descriptor.bitsAllocated,
            bitsStored: descriptor.bitsStored,
            highBit: descriptor.highBit,
            componentCount: descriptor.samplesPerPixel,
            pixelRepresentation: decoder.pixelRepresentationTagValue,
            photometricInterpretation: descriptor.photometricInterpretation,
            sourceByteOrder: byteOrder,
            ownership: .ownedData,
            packedBitOffset: bitRange.lowerBound % 8
        ) else {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: "native decoded bytes do not match the declared frame layout"
            )
        }
        return DicomDataBackedDecodedFrame(
            index: index,
            pixels: pixels,
            metadata: makeMetadata(
                width: descriptor.columns,
                height: descriptor.rows,
                frameCount: frameCount,
                frameIndex: index,
                rightAlignsStoredBits: deepColor
            )
        )
    }

    /// 16-bit colour reaches the typed pipeline as RGB with unsigned samples only (issue #3034). YBR at 16 bits
    /// and signed colour have no conversion here and are refused typed rather than reduced or reinterpreted.
    private func validateNativeDeepColor(_ descriptor: DicomPixelDataDescriptor) throws {
        guard descriptor.photometricInterpretation == "RGB" else {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: "16-bit \(descriptor.photometricInterpretation) colour has no typed conversion; only RGB is delivered"
            )
        }
        guard decoder.pixelRepresentationTagValue == 0 else {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: "signed 16-bit colour samples are not delivered by the typed pipeline"
            )
        }
    }

    /// Three colour planes (Planar Configuration 1) as one interleaved buffer, sample bytes kept as stored.
    static func interleavedPlanes(_ planes: Data, pixelCount: Int, bytesPerSample: Int) -> Data {
        let planeBytes = pixelCount * bytesPerSample
        guard planes.count >= planeBytes * 3 else { return planes }
        var output = Data(count: planeBytes * 3)
        planes.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                for pixel in 0 ..< pixelCount {
                    for component in 0 ..< 3 {
                        let from = component * planeBytes + pixel * bytesPerSample
                        let to = (pixel * 3 + component) * bytesPerSample
                        for byte in 0 ..< bytesPerSample { target[to + byte] = source[from + byte] }
                    }
                }
            }
        }
        return output
    }

    /// Whether frames of this object decode through the JPEG 2000 / HTJ2K selection of `frameExecution(at:)`
    /// (JPEG 2000 Part 1 and HTJ2K; Part 2 collections already use the own codec on every path).
    var decodesThroughAsyncJPEG2000Selection: Bool {
        guard let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID), syntax.isCompressed,
              !DicomJ2KPart2Profile.isPart2(decoder.transferSyntaxUID),
              let family = DicomCodecFamily.family(for: syntax) else { return false }
        return family == .jpeg2000 || family == .htj2k
    }

    /// The decode decision `frameExecution(at:)` applies to this object's compressed frames before decoding.
    func compressedDecodeDecision(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DicomCodecDecision {
        DicomCodecCapabilities.resolve(
            DicomCodecCapabilityRequest(operation: .decode, descriptor: compressedFrameDescriptor()),
            environment: environment
        )
    }

    /// Synchronous volume decode (issue #3050). JPEG 2000 and HTJ2K frames take the backend selection of
    /// `frameExecution(at:)`, which the streaming slice decoder uses: the own DicomJPEG2000 codec by default, with
    /// OpenJPEG only as that path's fallback. A full volume build then decodes the values the stream decodes and needs
    /// no external runtime. Other syntaxes decode through `frame(at:)`.
    func volumeFrame(
        at index: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DicomDecodedFrame {
        guard decodesThroughAsyncJPEG2000Selection else { return try frame(at: index) }
        let reader = self
        return try DicomBlockingAsyncOperation.run {
            try await reader.frameExecution(at: index, environment: environment).frame
        }
    }

    // MARK: - Compressed path

    /// Own JPEG backend (DicomJPEG) when the resolver selects it; nil hands the frame to the legacy path
    /// (native extended/lossless decoders, ImageIO) so preferred mode keeps every previously decodable shape.
    private func decodeJPEGFrame(
        at index: Int,
        frameCount: Int,
        environment: [String: String]
    ) async throws -> DicomDecodedFrameExecution? {
        let request = DicomFrameDecodeRequest(
            frameData: try compressedFrameData(at: index),
            descriptor: compressedFrameDescriptor(),
            frameIndex: index
        )
        let mode = DicomJPEGSwiftRolloutMode(environment: environment)
        let decision = DicomCodecCapabilities.resolve(request.capabilityRequest, environment: environment)
        let own = DicomCodecBackendIdentifier.jpegSwift.rawValue
        guard mode == .forcedForTests || (decision.canExecute && decision.backendIdentifier == own) else { return nil }
        let decoded: DicomCodecDecodedFrame
        do {
            decoded = try await DicomJPEGSwiftBackend().decode(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard mode != .forcedForTests else {
                throw ReadError.decodeFailed(transferSyntaxUID: decoder.transferSyntaxUID, reason: error.localizedDescription)
            }
            decoder.logger.warning("Own JPEG decode declined frame \(index): \(error.localizedDescription); using the established path")
            return nil
        }
        guard let result = DCMPixelReader.makeCompressedResult(
            from: decoded,
            pixelRepresentation: decoder.pixelRepresentationTagValue,
            photometricInterpretation: decoder.photometricInterpretation
        ), let pixels = Self.typedPixels(from: result) else {
            throw ReadError.decodeFailed(transferSyntaxUID: decoder.transferSyntaxUID,
                                         reason: "the own JPEG backend did not produce a typed pixel buffer")
        }
        let frame = DicomDecodedFrame(
            index: index,
            pixels: pixels,
            metadata: makeMetadata(width: result.width, height: result.height, frameCount: frameCount,
                                   frameIndex: index, decodedSampleBits: result.bitDepth)
        )
        return execution(frame: frame, selectedBackendIdentifier: own, environment: environment,
                         rolloutMode: mode.rawValue, fallbackReason: nil, shadowBackendIdentifier: nil)
    }

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
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: error.localizedDescription
            )
        }

        guard let decoded else {
            let reader = self
            return try await DicomCancellableDetachedOperation.run {
                let frame = try reader.decodeCompressedFrame(
                    at: index,
                    frameCount: frameCount,
                    environment: environment
                )
                return reader.execution(
                    frame: frame,
                    environment: environment,
                    rolloutMode: DicomJ2KSwiftRolloutMode(environment: environment).rawValue,
                    fallbackReason: "The J2KSwift rollout backend is disabled or ineligible.",
                    shadowBackendIdentifier: nil
                )
            }
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
            metadata: makeMetadata(
                width: result.width,
                height: result.height,
                frameCount: frameCount,
                frameIndex: index,
                codestreamPrecision: decoded.bitsPerSample,
                decodedSampleBits: result.bitDepth
            )
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
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: error.localizedDescription
            )
        }
        guard let decoded else {
            let reader = self
            return try await DicomCancellableDetachedOperation.run {
                let frame = try reader.decodeCompressedFrame(
                    at: index,
                    frameCount: frameCount,
                    environment: environment
                )
                return reader.execution(
                    frame: frame,
                    environment: environment,
                    rolloutMode: DicomJLSwiftRolloutMode(environment: environment).rawValue,
                    fallbackReason: "The JLSwift rollout backend is disabled or ineligible.",
                    shadowBackendIdentifier: nil
                )
            }
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
            metadata: makeMetadata(
                width: result.width,
                height: result.height,
                frameCount: frameCount,
                frameIndex: index,
                codestreamPrecision: decoded.bitsPerSample,
                decodedSampleBits: result.bitDepth
            )
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

    private func decodeJ2KDataBackedFrame(
        at index: Int,
        frameCount: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> DicomDataBackedDecodedFrame {
        try await decodeDataBackedFrame(at: index, frameCount: frameCount, environment: environment) {
            request, environment in
            try await DicomJ2KSwiftFrameDecoder.decode(request, environment: environment) { telemetry in
                decoder.logger.info(Self.telemetryMessage(telemetry))
            }
        }
    }

    private func decodeJLSDataBackedFrame(
        at index: Int,
        frameCount: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> DicomDataBackedDecodedFrame {
        try await decodeDataBackedFrame(at: index, frameCount: frameCount, environment: environment) {
            request, environment in
            try await DicomJLSwiftFrameDecoder.decode(request, environment: environment) { telemetry in
                decoder.logger.info(Self.telemetryMessage(telemetry))
            }
        }
    }

    private typealias DataBackedCodecDecode = (
        DicomFrameDecodeRequest,
        [String: String]
    ) async throws -> DicomCodecDecodedFrame?

    private func decodeDataBackedFrame(
        at index: Int,
        frameCount: Int,
        environment: [String: String],
        using decode: DataBackedCodecDecode
    ) async throws -> DicomDataBackedDecodedFrame {
        let request = DicomFrameDecodeRequest(
            frameData: try compressedFrameData(at: index),
            descriptor: compressedFrameDescriptor(),
            frameIndex: index
        )
        let decoded: DicomCodecDecodedFrame?
        do {
            decoded = try await decode(request, environment)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: error.localizedDescription
            )
        }
        try Task.checkCancellation()
        guard let decoded else {
            return try await detachedSynchronousDataBackedFrame(
                at: index,
                environment: environment
            )
        }
        return try makeDataBackedFrame(from: decoded, index: index, frameCount: frameCount)
    }

    private func detachedSynchronousDataBackedFrame(
        at index: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> DicomDataBackedDecodedFrame {
        let reader = self
        return try await DicomCancellableDetachedOperation.run {
            try Task.checkCancellation()
            let frame = try reader.dataBackedFrameSynchronously(
                at: index,
                environment: environment
            )
            try Task.checkCancellation()
            return frame
        }
    }

    private func decodeJXLDataBackedFrame(
        at index: Int,
        frameCount: Int,
        environment: [String: String]
    ) async throws -> DicomDataBackedDecodedFrame {
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
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: error.localizedDescription
            )
        }
        try Task.checkCancellation()
        guard let decoded else {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: "the experimental JXLSwift backend did not produce a Data-backed frame"
            )
        }
        return try makeDataBackedFrame(from: decoded, index: index, frameCount: frameCount)
    }

    private func makeDataBackedFrame(
        from decoded: DicomCodecDecodedFrame,
        index: Int,
        frameCount: Int
    ) throws -> DicomDataBackedDecodedFrame {
        let ownership: DicomDecodedFrameDataOwnership
        switch decoded.buffer {
        case .owned:
            ownership = .ownedData
        case .shared:
            ownership = .retainedImmutableShared
        }
        guard let pixels = DicomDecodedFrameDataNormalizer.makeBuffer(
            data: decoded.buffer.data,
            width: decoded.width,
            height: decoded.height,
            bitsPerSample: decoded.bitsPerSample,
            bitsStored: decoded.bitsPerSample,
            highBit: decoded.bitsPerSample - 1,
            componentCount: decoded.componentCount,
            pixelRepresentation: decoder.pixelRepresentationTagValue,
            photometricInterpretation: decoder.photometricInterpretation,
            sourceByteOrder: decoded.bitsPerSample > 8 ? .littleEndian : .notApplicable,
            ownership: ownership
        ) else {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: "the selected codec backend produced an inconsistent Data-backed frame"
            )
        }
        return DicomDataBackedDecodedFrame(
            index: index,
            pixels: pixels,
            metadata: makeMetadata(
                width: decoded.width,
                height: decoded.height,
                frameCount: frameCount,
                frameIndex: index,
                codestreamPrecision: decoded.bitsPerSample
            )
        )
    }

    private func copyDataBackedFrame(from frame: DicomDecodedFrame) throws -> DicomDataBackedDecodedFrame {
        guard let pixels = DicomDecodedFrameDataNormalizer.copyBuffer(
            from: frame.pixels,
            width: frame.metadata.width,
            height: frame.metadata.height
        ) else {
            throw ReadError.decodeFailed(
                transferSyntaxUID: frame.metadata.transferSyntaxUID,
                reason: "the array-backed frame does not match its declared dimensions"
            )
        }
        return DicomDataBackedDecodedFrame(index: frame.index, pixels: pixels, metadata: frame.metadata)
    }

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
        } catch is CancellationError {
            throw CancellationError()
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
            metadata: makeMetadata(
                width: result.width,
                height: result.height,
                frameCount: frameCount,
                frameIndex: index,
                decodedSampleBits: result.bitDepth
            )
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

    private func decodeCompressedFrame(
        at index: Int,
        frameCount: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DicomDecodedFrame {
        let transferSyntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID)
        let bitsStored = decoder.intValue(for: Int(DicomTag.bitsStored.rawValue))
        let planarConfiguration = decoder.intValue(for: Int(DicomTag.planarConfiguration.rawValue)) ?? 0
        let decision = DicomCompressedPixelBackendResolver.resolve(
            transferSyntax: transferSyntax,
            requestedBitDepth: decoder.bitDepth,
            samplesPerPixel: decoder.samplesPerPixel,
            photometricInterpretation: decoder.photometricInterpretation,
            bitsStored: bitsStored,
            environment: environment
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
                bitsStored: bitsStored,
                planarConfiguration: planarConfiguration,
                environment: environment
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
                    bitsStored: bitsStored,
                    planarConfiguration: planarConfiguration,
                    environment: environment
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

        guard let result, var pixels = Self.typedPixels(from: result) else {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: "the \(decision.backend) backend did not produce a typed pixel buffer"
            )
        }
        var rightAligned = false
        if case .rgb16(let interleaved) = pixels {
            let photometric = decoder.photometricInterpretation.trimmingCharacters(in: .whitespaces).uppercased()
            guard ["RGB", "YBR_RCT", "YBR_ICT"].contains(photometric) else {
                throw ReadError.decodeFailed(
                    transferSyntaxUID: decoder.transferSyntaxUID,
                    reason: "16-bit \(photometric) colour has no typed conversion; only RGB is delivered"
                )
            }
            // RLE and other word-preserving backends return the stored words: keep only Bits Stored, at bit 0.
            pixels = .rgb16(interleaved: Self.rightAligned(interleaved, bitsStored: bitsStored ?? 16,
                                                           highBit: decoder.intValue(for: Int(DicomTag.highBit.rawValue))))
            rightAligned = true
        }
        return DicomDecodedFrame(
            index: index,
            pixels: pixels,
            metadata: makeMetadata(
                width: result.width,
                height: result.height,
                frameCount: frameCount,
                frameIndex: index,
                decodedSampleBits: result.bitDepth,
                rightAlignsStoredBits: rightAligned
            )
        )
    }

    /// PS3.5 8.1.1: only Bits Stored bits ending at High Bit belong to a sample.
    private static func rightAligned(_ samples: [UInt16], bitsStored: Int, highBit: Int?) -> [UInt16] {
        guard (1...16).contains(bitsStored) else { return samples }
        let shift = max(0, (highBit ?? bitsStored - 1) - bitsStored + 1)
        guard shift != 0 || bitsStored != 16 else { return samples }
        let mask = UInt16(truncatingIfNeeded: (1 << bitsStored) - 1)
        return samples.map { ($0 >> UInt16(shift)) & mask }
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
        // Bits Allocated comes from the data set: `decoder.bitDepth` becomes the decoded precision (for example 12)
        // once the synchronous pixel path has run, which is not a valid container width.
        let bitsAllocated = decoder.intValue(for: Int(DicomTag.bitsAllocated.rawValue)) ?? decoder.bitDepth
        let bitsStored = decoder.intValue(for: Int(DicomTag.bitsStored.rawValue)) ?? bitsAllocated
        return DicomCompressedFrameDescriptor(
            transferSyntaxUID: decoder.transferSyntaxUID,
            rows: decoder.height,
            columns: decoder.width,
            bitsAllocated: bitsAllocated,
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

    /// `codestreamPrecision` is the sample precision a codec decoded; when it exceeds Bits Stored and still fits
    /// Bits Allocated the samples keep it, as GDCM reads them (issue #2854), instead of being cut to Bits Stored.
    /// `decodedSampleBits` is the size of the samples a codec delivered: 8-bit samples under Bits Allocated 16
    /// (a codestream of 8-bit precision) are described as 8-bit words, which is how GDCM hands them over
    /// (issue #2856). `rightAlignsStoredBits` reports a High Bit of Bits Stored - 1 for samples the reader shifted
    /// down to bit 0 (16-bit colour, issue #3034).
    func makeMetadata(
        width: Int,
        height: Int,
        frameCount: Int? = nil,
        frameIndex: Int? = nil,
        codestreamPrecision: Int? = nil,
        decodedSampleBits: Int? = nil,
        rightAlignsStoredBits: Bool = false
    ) -> DicomDecodedFrameMetadata {
        let declaredBitsAllocated = decoder.bitDepth
        let declaredBitsStored = decoder.intValue(for: Int(DicomTag.bitsStored.rawValue)) ?? declaredBitsAllocated
        let sampleBits = decodedSampleBits ?? codestreamPrecision
        let narrowsToBytes = sampleBits.map { $0 <= 8 && declaredBitsAllocated > 8 } ?? false
        let widensBitsStored = !narrowsToBytes
            && (codestreamPrecision.map { $0 > declaredBitsStored && $0 <= declaredBitsAllocated } ?? false)
        let bitsAllocated = narrowsToBytes ? 8 : declaredBitsAllocated
        let bitsStored = narrowsToBytes ? min(codestreamPrecision ?? 8, 8, declaredBitsStored)
            : widensBitsStored ? codestreamPrecision ?? declaredBitsStored : declaredBitsStored
        let redefinesBits = narrowsToBytes || widensBitsStored
        let window = decoder.windowSettingsV2
        let voiLUTs = decoder.validatedVOILookupTables().accepted
        let enhanced = decoder.enhancedMultiframeFunctionalGroups
        let perFrameVOI = frameIndex.flatMap { index in
            enhanced?.perFrame.indices.contains(index) == true
                ? enhanced?.perFrame[index].frameVOI
                : nil
        }
        // Issue #3037: an Enhanced frame's rescale and spacing live in its functional groups (per frame, else
        // shared), which win over the top level, as the GDCM provider resolves them.
        let frameGroups = frameIndex.flatMap { index in
            enhanced?.frames.indices.contains(index) == true ? enhanced?.frames[index].functionalGroups : nil
        }
        let perFrameTransformation = frameIndex.flatMap { index in
            enhanced?.perFrame.indices.contains(index) == true ? enhanced?.perFrame[index].pixelValueTransformation : nil
        }
        let transformation = frameGroups?.pixelValueTransformation
        let frameSpacing = frameGroups?.pixelMeasures?.pixelSpacing.map { [$0.x, $0.y] }
        return DicomDecodedFrameMetadata(
            width: width,
            height: height,
            frameCount: frameCount ?? self.frameCount,
            bitsAllocated: bitsAllocated,
            bitsStored: bitsStored,
            highBit: redefinesBits || rightAlignsStoredBits ? bitsStored - 1
                : decoder.intValue(for: Int(DicomTag.highBit.rawValue)) ?? max(0, bitsStored - 1),
            pixelRepresentation: decoder.pixelRepresentationTagValue,
            samplesPerPixel: decoder.samplesPerPixel,
            photometricInterpretation: decoder.photometricInterpretation,
            planarConfiguration: decoder.intValue(for: Int(DicomTag.planarConfiguration.rawValue)),
            transferSyntaxUID: decoder.transferSyntaxUID,
            windowSettings: window.isValid ? window : nil,
            sharedFrameVOI: enhanced?.shared?.frameVOI,
            perFrameVOI: perFrameVOI,
            rescaleParameters: transformation.map {
                RescaleParameters(intercept: $0.rescaleIntercept, slope: $0.rescaleSlope)
            } ?? decoder.rescaleParametersV2,
            smallestImagePixelValue: decoder.intValue(for: 0x0028_0106),
            largestImagePixelValue: decoder.intValue(for: 0x0028_0107),
            voiLUTs: voiLUTs,
            voiLUTFunction: perFrameVOI?.lutFunction
                ?? enhanced?.shared?.frameVOI?.lutFunction
                ?? optionalString(for: .voiLUTFunction),
            pixelPaddingValue: decoder.doubleValue(for: .pixelPaddingValue),
            pixelPaddingRangeLimit: decoder.doubleValue(for: .pixelPaddingRangeLimit),
            presentationUnits: optionalString(for: .units),
            rescaleType: perFrameTransformation?.rescaleType ?? enhanced?.shared?.pixelValueTransformation?.rescaleType
                ?? optionalString(for: .rescaleType),
            modalityLUTs: decoder.modalityLookupTables,
            pixelSpacing: frameSpacing ?? decimals(for: DicomTag.pixelSpacing.rawValue),
            imagerPixelSpacing: decimals(for: 0x0018_1164),
            nominalScannedPixelSpacing: decimals(for: 0x0018_2010),
            pixelSpacingCalibrationType: optionalString(for: 0x0028_0A02)
        )
    }

    private func optionalString(for tag: Int) -> String? {
        let value = decoder.info(for: tag).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func decimals(for tag: Int) -> [Double] {
        let values = decoder.info(for: tag).split(separator: "\\").compactMap {
            Double($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return values.count >= 2 ? Array(values.prefix(2)) : []
    }

    private func optionalString(for tag: DicomTag) -> String? {
        let value = decoder.info(for: tag).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func typedPixels(from result: DCMPixelReadResult) -> DicomDecodedFramePixelBuffer? {
        if let interleaved = result.pixels24 {
            return .rgb8(interleaved: interleaved)
        }
        if let interleaved = result.pixels48 {
            return .rgb16(interleaved: interleaved)
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

        let identifier = selectedBackendIdentifier ?? legacyBackendIdentifier(environment: environment)
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
            return DicomOpenJPEGFrameBackend(environment: environment).capabilities
        case DicomCodecBackendIdentifier.jlSwift.rawValue:
            return DicomJLSwiftBackend().capabilities
        case DicomCodecBackendIdentifier.charLSCPU.rawValue:
            return DicomCharLSFrameBackend(environment: environment).capabilities
        case DicomCodecBackendIdentifier.jxlSwift.rawValue:
            return DicomJXLSwiftBackend().capabilities
        case DicomCodecBackendIdentifier.jpegSwift.rawValue:
            return DicomJPEGSwiftBackend().capabilities
        default:
            return nil
        }
    }

    private func legacyBackendIdentifier(environment: [String: String]) -> String {
        let decision = DicomCompressedPixelBackendResolver.resolve(
            transferSyntax: DicomTransferSyntax(uid: decoder.transferSyntaxUID),
            requestedBitDepth: decoder.bitDepth,
            samplesPerPixel: decoder.samplesPerPixel,
            photometricInterpretation: decoder.photometricInterpretation,
            bitsStored: decoder.intValue(for: Int(DicomTag.bitsStored.rawValue)),
            environment: environment
        )
        switch decision.backend {
        case .nativeJPEGLossless: return "native-jpeg-lossless"
        case .nativeRLELossless: return "native-rle-lossless"
        case .nativeDeflatedFrames: return "native-deflated-frames"
        case .nativeJPEGLS: return DicomCodecBackendIdentifier.charLSCPU.rawValue
        case .nativeJPEGExtended: return "native-jpeg-extended"
        case .nativeJPEG: return DicomCodecBackendIdentifier.jpegSwift.rawValue
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

// MARK: - JPEG 2000 Part 2 component collections (#2331)

extension DicomDecodedFrameReader {
    /// The fragments of the object, each one component collection (PS3.5 8.2.4).
    private func part2Fragments() throws -> [Range<Int>] {
        guard let descriptor = decoder.encapsulatedPixelDataDescriptor, !descriptor.fragments.isEmpty else {
            throw ReadError.unusableEncapsulation(diagnostics: ["The Part 2 object carries no encapsulated component collection."])
        }
        let data = decoder.dicomDataSnapshot()
        return try descriptor.fragments.map { fragment in
            guard fragment.valueRange.lowerBound >= 0, fragment.valueRange.upperBound <= data.count else {
                throw ReadError.unusableEncapsulation(diagnostics: ["A component collection fragment lies outside Pixel Data."])
            }
            return fragment.valueRange
        }
    }

    /// Decodes the collection that carries `index` (cached per object) and returns that component as a frame.
    private func part2CodecFrame(
        at index: Int,
        frameCount: Int,
        environment: [String: String]
    ) async throws -> (frame: DicomCodecDecodedFrame, mode: DicomJ2KSwiftRolloutMode) {
        let (fragments, layout, mode) = try part2Layout(frameCount: frameCount, environment: environment)
        guard let placement = layout.collection(containing: index) else {
            throw ReadError.frameIndexOutOfRange(index: index, frameCount: frameCount)
        }
        let cache = decoder.part2CollectionCache
        let collection: DicomJ2KDecodedCollection
        if let cached = cache.collection(fragmentIndex: placement.collection.fragmentIndex) {
            collection = cached
        } else {
            do {
                collection = try await DicomJ2KSwiftBackend().decodeCollection(
                    decoder.dicomDataSnapshot().subdata(in: fragments[placement.collection.fragmentIndex]),
                    transferSyntaxUID: decoder.transferSyntaxUID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ReadError.decodeFailed(transferSyntaxUID: decoder.transferSyntaxUID, reason: error.localizedDescription)
            }
            cache.store(collection, fragmentIndex: placement.collection.fragmentIndex)
        }
        return (try part2Frame(from: collection, component: placement.component), mode)
    }

    /// Synchronous variant for the synchronous reader API and the transcoder's stored-frame path.
    private func part2Frame(at index: Int, frameCount: Int, environment: [String: String]) throws -> DicomDecodedFrame {
        let (fragments, layout, _) = try part2Layout(frameCount: frameCount, environment: environment)
        guard let placement = layout.collection(containing: index) else {
            throw ReadError.frameIndexOutOfRange(index: index, frameCount: frameCount)
        }
        let cache = decoder.part2CollectionCache
        let collection: DicomJ2KDecodedCollection
        if let cached = cache.collection(fragmentIndex: placement.collection.fragmentIndex) {
            collection = cached
        } else {
            do {
                collection = try DicomJ2KSwiftBackend().decodeCollectionSynchronously(
                    decoder.dicomDataSnapshot().subdata(in: fragments[placement.collection.fragmentIndex]),
                    transferSyntaxUID: decoder.transferSyntaxUID)
            } catch {
                throw ReadError.decodeFailed(transferSyntaxUID: decoder.transferSyntaxUID, reason: error.localizedDescription)
            }
            cache.store(collection, fragmentIndex: placement.collection.fragmentIndex)
        }
        let codecFrame = try part2Frame(from: collection, component: placement.component)
        return try part2DecodedFrame(codecFrame, index: index, frameCount: frameCount)
    }

    private func part2Layout(
        frameCount: Int,
        environment: [String: String]
    ) throws -> ([Range<Int>], DicomJ2KPart2ObjectLayout, DicomJ2KSwiftRolloutMode) {
        let mode = DicomJ2KSwiftRolloutMode(environment: environment)
        guard mode != .disabled else {
            throw ReadError.unsupportedTransferSyntax(
                uid: decoder.transferSyntaxUID,
                diagnostics: ["The own JPEG 2000 Part 2 decoder is disabled (DICOM_J2KSWIFT_MODE=disabled) and no other Annex J decoder is available."]
            )
        }
        let fragments = try part2Fragments()
        let layout: DicomJ2KPart2ObjectLayout
        do {
            layout = try decoder.part2CollectionCache.layout {
                let data = decoder.dicomDataSnapshot()
                return try DicomJ2KPart2ObjectLayout.read(fragments: fragments.map { data[$0] }, declaredFrames: frameCount)
            }
        } catch let error as DicomJ2KPart2LayoutError {
            throw ReadError.unusableEncapsulation(diagnostics: [error.localizedDescription])
        }
        return (fragments, layout, mode)
    }

    private func part2Frame(from collection: DicomJ2KDecodedCollection, component: Int) throws -> DicomCodecDecodedFrame {
        guard collection.width == decoder.width, collection.height == decoder.height else {
            throw ReadError.decodeFailed(
                transferSyntaxUID: decoder.transferSyntaxUID,
                reason: "the component collection is \(collection.width)x\(collection.height), the data set declares \(decoder.width)x\(decoder.height)"
            )
        }
        guard component < collection.frames.count else {
            throw ReadError.decodeFailed(transferSyntaxUID: decoder.transferSyntaxUID, reason: "the collection holds fewer components than mapped")
        }
        return DicomCodecDecodedFrame(buffer: .owned(collection.frames[component]), width: collection.width, height: collection.height,
                                      bitsPerSample: collection.bitsPerSample, componentCount: 1)
    }

    private func part2DecodedFrame(_ decoded: DicomCodecDecodedFrame, index: Int, frameCount: Int) throws -> DicomDecodedFrame {
        guard let result = DCMPixelReader.makeCompressedResult(
            from: decoded, pixelRepresentation: decoder.pixelRepresentationTagValue, photometricInterpretation: decoder.photometricInterpretation
        ), let pixels = Self.typedPixels(from: result) else {
            throw ReadError.decodeFailed(transferSyntaxUID: decoder.transferSyntaxUID, reason: "the Part 2 collection did not produce a typed pixel buffer")
        }
        return DicomDecodedFrame(index: index, pixels: pixels,
                                 metadata: makeMetadata(width: result.width, height: result.height, frameCount: frameCount,
                                   frameIndex: index, decodedSampleBits: result.bitDepth))
    }

    private func part2Execution(
        _ decoded: DicomCodecDecodedFrame,
        index: Int,
        frameCount: Int,
        environment: [String: String],
        mode: DicomJ2KSwiftRolloutMode
    ) throws -> DicomDecodedFrameExecution {
        let frame = try part2DecodedFrame(decoded, index: index, frameCount: frameCount)
        return execution(frame: frame, selectedBackendIdentifier: DicomCodecBackendIdentifier.j2kSwiftCPU.rawValue,
                         environment: environment, rolloutMode: mode.rawValue, fallbackReason: nil, shadowBackendIdentifier: nil)
    }
}
