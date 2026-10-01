// JXLDecoder — pure-Swift JPEG XL decoder.
//
// Own Modular and VarDCT decoding, including progressive DC sequences.
// Unsupported feature profiles are refused explicitly; see the repository's
// Docs/QA/JPEGXLVarDCTCodec.md for qualified profiles and exclusions (#2378).
// `inspect(_:)` exposes metadata without decoding pixels.

import Foundation

public enum DecoderError: Error, LocalizedError, Sendable {
    case notImplemented(String)
    case container(ContainerError)
    case bitstream(BitstreamError)
    case missingSignature

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let p):
            return "JXLDecoder: \(p) is not yet implemented in pure Swift. " +
                   "See ROADMAP.md."
        case .container(let e):  return "JXLDecoder container error: \(e)"
        case .bitstream(let e):  return "JXLDecoder bitstream error: \(e)"
        case .missingSignature:  return "JXLDecoder: input is not a JPEG XL file"
        }
    }
}

/// A best-effort summary of a JXL file produced from header inspection
/// alone — does not require the full codec.
public struct JXLInspection: Sendable {
    public enum Form: Sendable, Equatable {
        case naked
        case container
    }
    public let form: Form
    public let xsize: UInt32
    public let ysize: UInt32
    /// Box types found in container form (empty for naked codestreams).
    public let boxTypes: [String]
    /// Parsed image metadata. Nil if inspection failed before this point
    /// (e.g. SizeHeader-only inspection on truncated files).
    public let metadata: ImageMetadata?
}

/// Deeper inspection that walks past the image headers into the
/// frame structure. Reports what we can pull from the first frame —
/// the FrameHeader fields, the TOC entry sizes, and (for Modular
/// frames) the MA-tree structure if one is present. Fields are
/// nil-able so a caller can use this even on files where our
/// reader stops at an unsupported branch.
public struct JXLFrameInspection: Sendable {
    /// Encoding mode of the first frame.
    public let encoding: FrameEncoding?
    /// True if `is_last` was set on the first frame.
    public let isLast: Bool?
    /// Frame `flags` U64.
    public let flags: UInt64?
    /// Number of progressive passes.
    public let numPasses: UInt32?
    /// TOC entry sizes (one per group, plus DC if present).
    public let tocSizes: [UInt32]?
    /// True if the Modular global has a non-trivial MA-tree.
    public let hasModularTree: Bool?
    /// Number of leaves in the MA-tree (when `hasModularTree`).
    public let modularTreeLeafCount: Int?
    /// Whether the post-tree pixel-data section uses prefix codes
    /// (true) or rANS (false).
    public let usePrefixCode: Bool?
}

/// Floor of base-2 log for positive integers. `log2Floor(1) = 0`,
/// `log2Floor(2) = 1`, `log2Floor(8) = 3`.
@inline(__always)
private func log2Floor(_ x: Int) -> Int {
    precondition(x > 0, "log2Floor requires positive input")
    return 63 - UInt64(x).leadingZeroBitCount
}

/// JPEG XL decoder. `Sendable`-by-default value type. Mirrors
/// J2KSwift's `J2KDecoder` shape (Phase B.6 family-parity
/// migration; see
/// [Documentation/FAMILY-API-PARITY.md](../../../Documentation/FAMILY-API-PARITY.md)).
public struct JXLDecoder: Sendable {
    /// Internal checkpoint for deterministic cancellation tests during AC group decoding.
    var beforeVarDCTGroup: (@Sendable (Int) -> Void)?

    public init() {}

    /// Decode a JPEG XL byte stream into an `ImageFrame`. Detection
    /// order:
    ///   1. The project-internal `0x4D30` 'M0' marker — routes
    ///      through `MinimalLosslessCodec.decode(_:)` for the
    ///      legacy vertical-slice format.
    ///   2. Spec Modular/VarDCT frames and progressive DC sequences.
    /// Unsupported features throw a typed error. For animations only
    /// the first image with replacement blending is qualified.
    public func decode(_ data: Data) throws -> ImageFrame {
        try Task.checkCancellation()
        do {
            return try decodeAnyFrame(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DecoderError {
            throw error
        } catch let error as BitstreamError {
            throw DecoderError.bitstream(error)
        } catch {
            throw DecoderError.notImplemented("decode failed: \(error)")
        }
    }

    /// True when the first frame needs the general (multi-frame, lossy)
    /// decode path rather than the reversible Modular core: VarDCT
    /// frames, DC frames of a progressive sequence, XYB (lossy) Modular
    /// frames and frames that are not the last one.
    package func requiresGeneralDecode(_ data: Data) -> Bool {
        guard let codestream = unwrapCodestream(data) else { return false }
        var r = BitReader(codestream, startingAt: 16)
        guard let _ = try? SizeHeader.read(from: &r),
              let meta = try? ImageMetadata.read(from: &r),
              (try? CustomTransformData.read(from: &r, xybEncoded: meta.xybEncoded)) != nil else { return false }
        if meta.colorEncoding.useICC {
            guard (try? ICCStream.decode(from: &r)) != nil else { return false }
        }
        guard (try? r.alignToByte()) != nil else { return false }
        let ctx = FrameHeaderContext(
            xybEncoded: meta.xybEncoded,
            numExtraChannels: meta.extraChannels.count,
            haveAnimation: meta.animation != nil,
            haveTimecodes: meta.animation?.haveTimecodes ?? false)
        guard let fh = try? FrameHeader.read(from: &r, context: ctx) else { return false }
        return fh.encoding == .varDCT || fh.frameType != .regular || fh.colorTransform == .xyb || !fh.isLast
    }

    private func decodeAnyFrame(_ data: Data) throws -> ImageFrame {
        if MinimalLosslessCodec.isM0(data) {
            do { return try MinimalLosslessCodec.decode(data) }
            catch { throw DecoderError.notImplemented("M0 decode failed: \(error)") }
        }
        // Inspect the frame to determine encoding (Modular vs VarDCT).
        let inspection = try inspect(data)
        guard let metadata = inspection.metadata else {
            throw DecoderError.notImplemented(
                "frame metadata could not be parsed"
            )
        }
        // Branch on encoding. The probe routes Modular frames
        // through `decodeModular`; VarDCT frames go through
        // `decodeVarDCTPartial` which currently parses headers +
        // `QuantizerParams` and throws structured `notImplemented`
        // for the layers we haven't built yet (DequantMatrices,
        // BlockCtxMap parser, AC global, etc.). The error message
        // names the next layer so callers and tests can pin
        // progress.
        if let progressive = try decodeDCFrameSequence(data, inspection: inspection) {
            return progressive
        }
        let frameInspection = inspectFrameStructure(data)
        if frameInspection.encoding == FrameEncoding.varDCT {
            return try decodeVarDCTPartial(
                data: data, inspection: inspection,
                frame: frameInspection
            )
        }
        let frame = try decodeModularFrame(data)
        if frame.frameHeader.colorTransform == .xyb {
            return try renderModularXYBFrame(frame)
        }
        let modular = ModularImage(
            channels: frame.planes.map {
                ModularChannel(width: frame.width, height: frame.height, pixels: $0)
            },
            nbMetaChannels: 0
        )
        return try assembleImageFrame(
            modular: modular, metadata: metadata,
            xsize: Int(inspection.xsize),
            ysize: Int(inspection.ysize)
        )
    }

    /// `FrameHeader::ToFrameDimensions`: the coded size of a frame —
    /// the frame size (or the image size), divided by `8^dc_level` for
    /// DC frames and by the frame upsampling factor.
    static func codedFrameSize(
        _ fh: FrameHeader, imageWidth: Int, imageHeight: Int
    ) -> (width: Int, height: Int) {
        var xs = imageWidth
        var ys = imageHeight
        if fh.customSizeOrOrigin, let fs = fh.frameSize {
            if fs.xsize > 0 { xs = Int(fs.xsize) }
            if fs.ysize > 0 { ys = Int(fs.ysize) }
        }
        if fh.dcLevel > 0 {
            let div = 1 << (3 * Int(fh.dcLevel))
            xs = (xs + div - 1) / div
            ys = (ys + div - 1) / div
        }
        let ups = max(1, Int(fh.upsampling))
        return ((xs + ups - 1) / ups, (ys + ups - 1) / ups)
    }

    /// A lossy (XYB) Modular frame: the integer planes become XYB
    /// samples through the frame's DC quantisation factors
    /// (`ModularImageToDecodedRect`), then the output stage renders them.
    private func renderModularXYBFrame(_ frame: MDModularFrame) throws -> ImageFrame {
        let fh = frame.frameHeader
        guard fh.loopFilter.epfIters == 0 else {
            throw DecoderError.notImplemented(
                "Modular decode: XYB frame with EPF (epf_iters \(fh.loopFilter.epfIters))")
        }
        var planes = MDFrameDecoder.xybPlanes(frame)
        if fh.loopFilter.gab {
            let gw = fh.loopFilter.gabWeights
            for c in 0..<3 {
                Gaborish.apply(to: &planes[c], width: frame.width, height: frame.height,
                               weight1: gw[2 * c], weight2: gw[2 * c + 1])
            }
        }
        let extra = frame.planes.count > frame.colourChannels
            ? Array(frame.planes[frame.colourChannels...]) : []
        return try renderXYBFrame(
            planeX: planes[0], planeY: planes[1], planeB: planes[2],
            width: frame.width, height: frame.height, metadata: frame.metadata,
            extraChannelPlanes: extra, label: "Modular XYB decode")
    }

    /// Progressive DC (`cjxl -p`): one or more Modular XYB DC frames
    /// (`frame_type == kDCFrame`, `dc_level ≥ 1`) precede the VarDCT
    /// frame that references them through `kUseDcFrame`. Returns `nil`
    /// when the first frame is not a DC frame.
    private func decodeDCFrameSequence(
        _ data: Data, inspection: JXLInspection
    ) throws -> ImageFrame? {
        guard let codestream = unwrapCodestream(data),
              let metadata = inspection.metadata else { return nil }
        var r = BitReader(codestream, startingAt: 16)
        _ = try SizeHeader.read(from: &r)
        let meta = try ImageMetadata.read(from: &r)
        guard (try? CustomTransformData.read(from: &r, xybEncoded: meta.xybEncoded)) != nil
        else { return nil }
        if meta.colorEncoding.useICC {
            guard (try? ICCStream.decode(from: &r)) != nil else { return nil }
        }
        try r.alignToByte()
        let ctx = FrameHeaderContext(
            xybEncoded: meta.xybEncoded,
            numExtraChannels: meta.extraChannels.count,
            haveAnimation: meta.animation != nil,
            haveTimecodes: meta.animation?.haveTimecodes ?? false)
        let firstHeaderBit = r.position
        guard let first = try? FrameHeader.read(from: &r, context: ctx),
              first.frameType == .dcFrame else { return nil }
        r.seek(toBitPosition: firstHeaderBit)
        let xs = Int(inspection.xsize)
        let ys = Int(inspection.ysize)
        // `dec_frame.cc::InitFrame` frame counters: they seed the noise.
        var visible = 0
        var nonvisible = 0
        var dcFrames: [Int: [[Float]]] = [:]
        for _ in 0...8 {
            try Task.checkCancellation()
            let frameStartByte = r.position / 8
            let fh = try FrameHeader.read(from: &r, context: ctx)
            let visibleFrame = (fh.isLast || fh.animationFrame.duration > 0)
                && (fh.frameType == .regular || fh.frameType == .skipProgressive)
            if visibleFrame {
                visible += 1
                nonvisible = 0
            } else {
                nonvisible += 1
            }
            if fh.frameType == .dcFrame && fh.encoding == .varDCT {
                // A VarDCT DC frame (progressive DC level ≥ 2): decoded like
                // the image frame, its XYB planes kept for the next level.
                let sink = XYBFrameSink()
                _ = try decodeVarDCTPartial(
                    data: data, inspection: inspection,
                    frame: inspectFrameStructure(data),
                    frameStartByte: frameStartByte,
                    dcFrame: dcFrames[Int(fh.dcLevel)],
                    frameIndices: (visible, nonvisible), xybSink: sink)
                dcFrames[Int(fh.dcLevel) - 1] = sink.planes
                r.seek(toBitPosition: sink.frameEndByte * 8)
                continue
            }
            if fh.frameType == .dcFrame {
                guard fh.colorTransform == .xyb else {
                    throw DecoderError.notImplemented(
                        "Modular decode: DC frame without the XYB colour transform")
                }
                let size = Self.codedFrameSize(fh, imageWidth: xs, imageHeight: ys)
                let dcFrame: MDModularFrame
                do {
                    dcFrame = try MDFrameDecoder.decodeFrame(
                        reader: &r, frameHeader: fh, metadata: metadata,
                        xsize: size.width, ysize: size.height, iccProfile: nil)
                } catch let e as MDFrameError {
                    throw DecoderError.notImplemented("Modular decode (DC frame): \(e)")
                }
                guard fh.loopFilter.epfIters == 0, !fh.loopFilter.gab else {
                    throw DecoderError.notImplemented(
                        "Modular decode: DC frame with restoration filters")
                }
                dcFrames[Int(fh.dcLevel) - 1] = MDFrameDecoder.xybPlanes(dcFrame)
                continue
            }
            guard fh.frameType == .regular, fh.encoding == .varDCT else {
                throw DecoderError.notImplemented(
                    "decode: \(fh.encoding) \(fh.frameType) frame after a DC frame")
            }
            return try decodeVarDCTPartial(
                data: data, inspection: inspection,
                frame: inspectFrameStructure(data),
                frameStartByte: frameStartByte,
                dcFrame: dcFrames[Int(fh.dcLevel)],
                frameIndices: (visible, nonvisible))
        }
        throw DecoderError.notImplemented("decode: more than 8 frames before the image frame")
    }

    /// Decode, optionally reinterpreting a 16-bit result as signed
    /// ``PixelType/int16``.
    ///
    /// JPEG XL codestreams have no native signed-sample type, so a
    /// signed 16-bit image is stored as unsigned offset-binary
    /// (sample + 32768 — the level shift the encoder applies when
    /// handed an ``PixelType/int16`` frame). Passing
    /// `signedOutput: true` un-shifts a 16-bit decode back to a
    /// signed ``PixelType/int16`` frame, giving a full int16 → int16
    /// round-trip within JXLSwift. `djxl` (and any other decoder)
    /// still sees a standard unsigned-16 codestream.
    ///
    /// The flag only affects 16-bit results; 8-bit / already-signed
    /// frames are returned unchanged, so this is a strict superset of
    /// ``decode(_:)`` — existing unsigned behaviour is untouched.
    public func decode(
        _ data: Data, signedOutput: Bool
    ) throws -> ImageFrame {
        let frame = try decode(data)
        guard signedOutput, frame.pixelType == .uint16 else {
            return frame
        }
        return frame.reinterpretedAsSignedInt16()
    }

    /// Extract the **quantised** AC coefficient state from a JXL
    /// VarDCT frame, returning a `JXLCoefficientPlanes` suitable for
    /// the reverse-bridge (`JXLToJPEGAdapter.reconstruct`). This is
    /// the API that, once implemented, removes the CLI's
    /// `--source <jpg>` requirement for `jxl transcode --mode reverse`.
    ///
    /// **Status (v0.12.0gr scaffold).** Throws `notImplemented`.
    /// The implementation will refactor `decodeVarDCTPartial` to
    /// optionally stop after the AC group decode (line ~1320 today)
    /// and return `(dcValues, acBlocks, frameDims, frameComponents)`
    /// packaged into `JXLCoefficientPlanes` instead of running IDCT
    /// + color conversion to pixels. The bitstream walk is already
    /// complete through that point in the existing decoder; the
    /// refactor is "factor out shared inner function + add a new
    /// public entry that calls it with `stopAtCoefficients=true`".
    ///
    /// The bridge-specific case (single group, NBLTYPES=1, DCT8x8
    /// strategy, JPEG quant matrices) is the immediate target — that
    /// covers what our forward bridge produces and what the matrix
    /// test (`testEndToEnd_ByteIdenticalMatrix_BaselineJPEGs`) exercises.
    ///
    /// - Parameter data: the JXL bytes (codestream or container).
    /// - Returns: `JXLCoefficientPlanes` in JXL channel order
    ///   ([X=Cb, Y, B=Cr] for kYCbCr 3-channel frames).
    /// - Throws: `DecoderError.notImplemented` until the refactor
    ///   above lands.
    package func decodeToCoefficients(
        _ data: Data
    ) throws -> JXLCoefficientPlanes {
        // Use a sentinel-error escape hatch: run the full
        // `decodeVarDCTPartial` but signal capture-and-stop right
        // after the AC group loop completes (i.e. when dcValues +
        // acBlocks are fully populated). The sentinel throws an
        // `EarlyCoefficientCapture` carrying the packaged planes;
        // we catch it here and return.
        //
        // **Status (v0.12.0gu)** — depends on the early-capture
        // hook being added inside `decodeVarDCTPartial` at the
        // post-AC-decode point. Until that lands, the inner
        // function runs to completion (producing pixels) and we
        // never see the sentinel. The fallback re-throws a clear
        // notImplemented.
        let inspection = try inspect(data)
        let frameInspection = inspectFrameStructure(data)
        guard frameInspection.encoding == FrameEncoding.varDCT else {
            throw DecoderError.notImplemented(
                "decodeToCoefficients: frame is not VarDCT-encoded "
                + "(got \(frameInspection.encoding ?? .modular))")
        }
        do {
            _ = try decodeVarDCTPartial(
                data: data, inspection: inspection,
                frame: frameInspection,
                capturingCoefficients: true)
        } catch let capture as EarlyCoefficientCapture {
            return capture.planes
        }
        throw DecoderError.notImplemented(
            "decodeToCoefficients: decoder reached pixel output "
            + "without firing the EarlyCoefficientCapture sentinel. "
            + "Hook may not be installed in decodeVarDCTPartial.")
    }

    /// Decode everything the autonomous JPEG-reverse path needs from
    /// a cjxl `--lossless_jpeg=1` codestream: the DCT coefficient
    /// planes, the RAW slot 0 quant table, and the frame's chroma
    /// subsampling + colour transform. Combined with the container's
    /// jbrd box (marker order, Huffman tables, scan structure) this
    /// is enough to reconstruct the source JPEG byte-for-byte with
    /// no reference to the original — see
    /// `JXLToJPEGAdapter.reconstruct(bridgeData:jbrd:)`.
    ///
    /// - Parameter data: JXL bytes (codestream or container).
    /// - Returns: a `JXLJPEGBridgeData` bundle.
    /// - Throws: `DecoderError.notImplemented` for non-VarDCT frames
    ///   or if the early-capture hook doesn't fire.
    package func decodeJPEGBridgeData(
        _ data: Data
    ) throws -> JXLJPEGBridgeData {
        let inspection = try inspect(data)
        let frameInspection = inspectFrameStructure(data)
        guard frameInspection.encoding == FrameEncoding.varDCT else {
            throw DecoderError.notImplemented(
                "decodeJPEGBridgeData: frame is not VarDCT-encoded "
                + "(got \(frameInspection.encoding ?? .modular))")
        }
        do {
            _ = try decodeVarDCTPartial(
                data: data, inspection: inspection,
                frame: frameInspection,
                capturingCoefficients: true)
        } catch let capture as EarlyCoefficientCapture {
            return JXLJPEGBridgeData(
                planes: capture.planes,
                rawQuantTable: capture.rawQuantTable,
                chromaSubsampling: capture.chromaSubsampling,
                colorTransform: capture.bridgeColorTransform,
                width: Int(inspection.xsize),
                height: Int(inspection.ysize),
                icc: capture.icc)
        }
        throw DecoderError.notImplemented(
            "decodeJPEGBridgeData: decoder reached pixel output "
            + "without firing the capture sentinel.")
    }
}

/// Sentinel error used by `decodeToCoefficients` to stop the
/// `decodeVarDCTPartial` walk at the post-AC-decode point and
/// return the packaged coefficient planes (plus the data the
/// autonomous JPEG-reverse path needs: the RAW slot 0 quant table
/// and the frame's chroma-subsampling / colour-transform).
fileprivate struct EarlyCoefficientCapture: Error {
    let planes: JXLCoefficientPlanes
    /// RAW slot 0 quant table (3×64 Int32, channel-major,
    /// JXL-transposed layout) when slot 0 is the JPEG-compatible
    /// RAW table; `nil` otherwise. Inverse of
    /// `buildJXLBridgeRAWQuantPayload`.
    let rawQuantTable: [Int32]?
    let chromaSubsampling: YCbCrChromaSubsampling
    /// The frame's colour transform mapped to the bridge enum.
    let bridgeColorTransform: JXLBridgeColorTransform
    /// Reconstructed codestream ICC profile (§C.3.4) when the frame
    /// carries one; `nil` otherwise.
    let icc: Data?
}

/// Everything `decodeJPEGBridgeData` recovers from a cjxl
/// `--lossless_jpeg=1` codestream — enough (combined with the jbrd
/// box's marker / Huffman structure) to reconstruct the source JPEG
/// byte-for-byte with no reference to the original.
package struct JXLJPEGBridgeData: Sendable {
    /// Decoded DCT coefficients in JXL channel order [X, Y, B].
    package let planes: JXLCoefficientPlanes
    /// RAW slot 0 quant table (3×64, channel-major, JXL-transposed),
    /// or `nil` when the frame's slot 0 isn't a JPEG-compatible RAW
    /// table.
    package let rawQuantTable: [Int32]?
    /// Frame chroma subsampling — drives JPEG sampling-factor
    /// recovery.
    package let chromaSubsampling: YCbCrChromaSubsampling
    /// Frame colour transform (`.ycbcr` / `.none`).
    package let colorTransform: JXLBridgeColorTransform
    /// Reconstructed codestream ICC profile (§C.3.4), or `nil` when
    /// the frame's colour encoding is enumerated rather than ICC.
    /// The reverse transcode splices this into the APP2
    /// `ICC_PROFILE` marker.
    package let icc: Data?
    /// True image pixel dimensions from the JXL `SizeHeader` — the
    /// source JPEG's SOFn `width`/`height`. These are the *exact*
    /// dimensions (e.g. 17×23), not the block-rounded grid
    /// (`blocksX*8`), so odd-sized JPEGs reconstruct byte-identically.
    package let width: Int
    package let height: Int

    package init(
        planes: JXLCoefficientPlanes,
        rawQuantTable: [Int32]?,
        chromaSubsampling: YCbCrChromaSubsampling,
        colorTransform: JXLBridgeColorTransform,
        width: Int,
        height: Int,
        icc: Data? = nil
    ) {
        self.planes = planes
        self.rawQuantTable = rawQuantTable
        self.chromaSubsampling = chromaSubsampling
        self.colorTransform = colorTransform
        self.width = width
        self.height = height
        self.icc = icc
    }
}

extension JXLDecoder {

    /// Skeleton VarDCT decoder. Parses what's tractable today and
    /// throws a structured `notImplemented` naming the first
    /// bitstream layer we can't yet read. As parsers for each
    /// layer land, the throw point moves further into the section.
    ///
    /// Section 0 layout (libjxl `dec_frame.cc::DecodeGlobalDCInfo`
    /// + `modular_frame_decoder::DecodeGlobalInfo`):
    ///
    ///   1. ✓ `QuantizerParams` — global_scale + quant_dc
    ///   2. ✓ `BlockCtxMap` all_default flag (1 bit; only the
    ///        default branch is parsed today)
    ///   3. ✓ `ColorCorrelationMap.DecodeDC` all_default flag
    ///        (1 bit; only the default branch)
    ///   4. ✗ `DequantMatrices.DecodeDC` — first unimplemented
    ///        layer; throws here.
    ///
    /// Layers 5+ (DequantMatrices full decode, DC group, AC global,
    /// AC group, Gaborish, OpsinXYB inverse) all have their math
    /// layer in `Sources/JXLSwift/VarDCT/` already; what's missing
    /// is the bitstream parsers + orchestration.
    private func decodeVarDCTPartial(
        data: Data, inspection: JXLInspection,
        frame: JXLFrameInspection,
        capturingCoefficients: Bool = false,
        frameStartByte: Int? = nil,
        dcFrame: [[Float]]? = nil,
        frameIndices: (visible: Int, nonvisible: Int) = (1, 0),
        xybSink: XYBFrameSink? = nil
    ) throws -> ImageFrame {
        guard let codestream = unwrapCodestream(data) else {
            throw DecoderError.notImplemented(
                "VarDCT frame in unsupported container layout"
            )
        }
        guard let metadata = inspection.metadata else {
            throw DecoderError.notImplemented(
                "VarDCT frame: no parseable metadata"
            )
        }
        // Re-parse outer headers to position the cursor at section 0.
        // Same prep `decodeModular` runs.
        var r = BitReader(codestream, startingAt: 16)
        _ = try SizeHeader.read(from: &r)
        let reparsedMeta = try ImageMetadata.read(from: &r)
        let transformData: CustomTransformData
        do {
            transformData = try CustomTransformData.read(
                from: &r, xybEncoded: metadata.xybEncoded)
        } catch {
            throw DecoderError.notImplemented(
                "VarDCT decode: custom transform data: \(error)")
        }
        // Codestream ICC stream (§C.3.4) sits between the metadata
        // and the byte boundary when `useICC` is set. Decode it both
        // to keep the bit position aligned for the FrameHeader/TOC
        // and to recover the profile for the JPEG reverse path.
        var frameICC: Data? = nil
        if reparsedMeta.colorEncoding.useICC {
            do { frameICC = try ICCStream.decode(from: &r) }
            catch {
                throw DecoderError.notImplemented(
                    "VarDCT decode: codestream ICC stream decode "
                    + "failed: \(error)")
            }
        }
        try r.alignToByte()
        if let start = frameStartByte {
            r.seek(toBitPosition: start * 8)
        }
        let ctx = FrameHeaderContext(
            xybEncoded: metadata.xybEncoded,
            numExtraChannels: metadata.extraChannels.count,
            haveAnimation: metadata.animation != nil,
            haveTimecodes: metadata.animation?.haveTimecodes ?? false
        )
        let fh = try FrameHeader.read(from: &r, context: ctx)
        guard fh.encoding == .varDCT else {
            throw DecoderError.notImplemented(
                "decodeVarDCTPartial routed wrong-encoded frame: "
                + "got \(fh.encoding)"
            )
        }
        guard fh.blendingInfo.mode == .replace,
              fh.extraChannelBlendingInfo.allSatisfy({ $0.mode == .replace }) else {
            throw DecoderError.notImplemented("VarDCT decode: frame blending")
        }
        // TOC + section-0 BitReader.
        let groupDim = 128 << Int(fh.groupSizeShift)
        // libjxl `FrameDimensions::Set`: the coded frame is the image
        // divided by the frame upsampling factor; the render pipeline
        // upsamples back to `xsizeUp × ysizeUp` at the end.
        guard !fh.customSizeOrOrigin else {
            throw DecoderError.notImplemented(
                "VarDCT decode: frames with a custom size or origin")
        }
        if fh.dcLevel > 0 {
            guard xybSink != nil else {
                throw DecoderError.notImplemented(
                    "VarDCT decode: DC frame (dc_level \(fh.dcLevel)) outside a frame sequence")
            }
        }
        let upsampling = max(1, Int(fh.upsampling))
        guard [1, 2, 4, 8].contains(upsampling) else {
            throw DecoderError.notImplemented(
                "VarDCT decode: upsampling factor \(upsampling)")
        }
        var xsizeUp = Int(inspection.xsize)
        var ysizeUp = Int(inspection.ysize)
        if fh.dcLevel > 0 {
            let div = 1 << (3 * Int(fh.dcLevel))
            xsizeUp = (xsizeUp + div - 1) / div
            ysizeUp = (ysizeUp + div - 1) / div
        }
        let xsize = (xsizeUp + upsampling - 1) / upsampling
        let ysize = (ysizeUp + upsampling - 1) / upsampling
        if upsampling > 1 && !metadata.extraChannels.isEmpty {
            throw DecoderError.notImplemented(
                "VarDCT decode: extra channels in an upsampled frame")
        }
        let numGroupsX = (xsize + groupDim - 1) / groupDim
        let numGroupsY = (ysize + groupDim - 1) / groupDim
        let numGroups = numGroupsX * numGroupsY
        let dcGroupDim = groupDim << 3
        let numDcGroupsX = (xsize + dcGroupDim - 1) / dcGroupDim
        let numDcGroupsY = (ysize + dcGroupDim - 1) / dcGroupDim
        let numDcGroups = numDcGroupsX * numDcGroupsY
        let numPasses = Int(fh.passes.numPasses)
        let tocEntries = TOC.numEntries(
            numGroups: numGroups, numDcGroups: numDcGroups,
            numPasses: numPasses
        )
        let toc = try TOC.read(from: &r, numEntries: tocEntries)
        // After TOC, the codestream is byte-aligned. Capture this byte
        // position — every TOC entry's offset is relative to it.
        let postTocBytePos = r.position / 8
        if let sink = xybSink {
            var end = 0
            for i in 0..<tocEntries where i < toc.offsets.count && i < toc.entrySizes.count {
                end = max(end, Int(toc.offsets[i]) + Int(toc.entrySizes[i]))
            }
            sink.frameEndByte = postTocBytePos + end
        }
        // Helper: section i starts at this bit position in the file.
        @inline(__always)
        func sectionBitStart(_ i: Int) -> Int {
            return postTocBytePos * 8 + Int(toc.offsets[i]) * 8
        }
        _ = sectionBitStart  // silence unused-warning when single-section

        // libjxl `dec_frame.cc::ProcessDCGlobal` order:
        //   1. (Splines, if frame.flags has Splines bit) — typical
        //      cjxl output doesn't set this.
        //   2. (Noise, if Noise bit) — also rare.
        //   3. `matrices.DecodeDC(br)` — DequantMatrices.DecodeDC
        //      (DC quant scalars). Read for ALL frame types.
        //   4. (VarDCT only) `DecodeGlobalDCInfo`: QuantizerParams +
        //      BlockCtxMap + cmap.DecodeDC.
        //   5. `modular_frame_decoder.DecodeGlobalInfo`: has_tree
        //      + (if true) tree + codebook + ModularGenericDecompress
        //      (gi).
        //   6. (VarDCT only) DequantMatrices.Decode (the AC matrices).
        // libjxl `frame_header.h::FrameFlag`: noise 0x01, patches 0x02,
        // splines 0x10, use-DC-frame 0x20, skip-DC-smoothing 0x80.
        if fh.flags & FrameFlag.patches.rawValue != 0 {
            throw DecoderError.notImplemented(
                "VarDCT decode: patch dictionary (frame flag 0x02) not supported")
        }
        if fh.flags & FrameFlag.splines.rawValue != 0 {
            throw DecoderError.notImplemented(
                "VarDCT decode: splines (frame flag 0x10) not supported")
        }
        let useDcFrame = fh.flags & FrameFlag.useDcFrame.rawValue != 0
        if useDcFrame {
            guard let dc = dcFrame, dc.count == 3 else {
                throw DecoderError.notImplemented(
                    "VarDCT decode: frame uses a DC frame that was not decoded")
            }
        } else if dcFrame != nil {
            throw DecoderError.notImplemented(
                "VarDCT decode: a DC frame precedes a frame that does not use it")
        }
        var noiseParams: NoiseParams? = nil
        if fh.flags & FrameFlag.noise.rawValue != 0 {
            do { noiseParams = try NoiseParams.read(from: &r) }
            catch {
                throw DecoderError.notImplemented(
                    "VarDCT decode: noise parameters: \(error)")
            }
        }

        let trace = ProcessInfo.processInfo.environment["JXL_TRACE"] != nil
        @inline(__always)
        func traceLayer(_ name: String, before: Int, after: Int) {
            if trace {
                FileHandle.standardError.write(Data(
                    "TRACE \(name) bits=\(after - before) pos=\(after)\n".utf8
                ))
            }
        }
        // (1) DequantMatrices.DecodeDC.
        let dcStart = r.position
        let dcQuant = try DequantMatricesDC.read(from: &r)
        traceLayer("DequantMatricesDC", before: dcStart, after: r.position)

        // (2) QuantizerParams.
        let qpStart = r.position
        let qp = try QuantizerParams.read(from: &r)
        traceLayer("QuantizerParams", before: qpStart, after: r.position)
        _ = qp

        // (3) BlockCtxMap.
        let bctxStart = r.position
        let bctx: BlockCtxMap
        do { bctx = try BlockCtxMap.read(from: &r) }
        catch let e as BlockCtxMapError {
            throw DecoderError.notImplemented(
                "VarDCT decode: BlockCtxMap.read failed: \(e)"
            )
        }
        traceLayer("BlockCtxMap", before: bctxStart, after: r.position)

        // (4) ColorCorrelationMap.DecodeDC.
        let cmapStart = r.position
        let cmapDC: ColorCorrelation
        do { cmapDC = try ColorCorrelation.readDC(from: &r) }
        catch ColorCorrelationError.notDefault {
            throw DecoderError.notImplemented(
                "VarDCT decode: ColorCorrelationMap.DecodeDC "
                + "non-default branch (color_factor + base "
                + "correlations + DC offsets)"
            )
        }
        traceLayer("cmap.DecodeDC", before: cmapStart, after: r.position)
        _ = cmapDC

        // (5) Modular global info — has_tree flag + (if true)
        // global tree section + post-tree codebook + GroupHeader.
        // The VarDCT path uses this tree/codebook for the DC-plane
        // modular sub-image AND for any RAW-mode quant tables.
        // `DecodeGlobalInfo`: `has_tree`, then the tree and its code with
        // `tree_size_limit = min(1 << 22, 1024 + xsize·ysize·(nb_chans +
        // nb_extra) / 16)` (nb_chans counts the colour channels here).
        var globalCode: MDGlobalCode? = nil
        let hasTree = try r.readBit()
        if hasTree {
            let colourChannels = metadata.colorEncoding.colorSpace == .grayscale ? 1 : 3
            let treeLimit = min(1 << 22, 1024 + xsize * ysize * (colourChannels + metadata.extraChannels.count) / 16)
            do { globalCode = try mdDecodeTreeAndCode(reader: &r, sizeLimit: treeLimit) }
            catch {
                throw DecoderError.notImplemented("VarDCT decode: global modular tree: \(error)")
            }
        }
        let globalTree = globalCode?.tree
        let globalPostHeader = globalCode?.header
        let globalPostCodebook = globalCode?.codebook
        let modularBitDepth = Int(metadata.bitDepth.bitsPerSample)
        // (6) Meta-channels modular sub-image. libjxl
        // `dec_modular.cc::DecodeGlobalInfo`:
        //
        //     do_color = (frame.encoding == kModular)
        //     nb_chans = do_color ? (gray ? 1 : 3) : 0
        //     gi = Image::Create(... nb_chans + nb_extra)
        //     ModularGenericDecompress(reader, gi, ...)
        //
        // For VarDCT (do_color=false) with no extra channels, `gi`
        // has zero channels, so `ModularDecode` early-returns with
        // `image.channel.empty()` BEFORE reading GroupHeader. No
        // bits are consumed here in that case. Verified against
        // libjxl with `JXL_BYTEPOS_TRACE`: section-0 pos 296
        // (= end of post-tree codebook) flows directly into
        // `DecodeVarDCTDC`'s `ReadFixedBits<2>()` for
        // `extra_precision`.
        // VarDCT: do_color = false, so `gi` carries only the extra
        // channels (alpha / depth / …). When there are none, `gi` is
        // empty and `ModularDecode` returns before reading anything.
        // When there are extra channels, decode them here: each is a
        // modular channel of the global sub-image, sized
        // `DivCeil(xsize, ecups) × DivCeil(ysize, ecups)`.
        let nbExtraChannels = metadata.extraChannels.count
        // Decoded extra-channel planes (one `xsize × ysize` Int32
        // array per channel); empty until populated below (small
        // frames) or after the AC-group loop (large frames).
        var extraChannelPlanes: [[Int32]] = []
        // When the extra-channel modular image has channels too large
        // for the global pass, those channels decode per AC group.
        // The partially-filled image + its header survive to the AC
        // loop; `extraFirstBig` is the boundary channel index.
        var extraGiImage: ModularImage? = nil
        var extraGiGH: GroupHeader? = nil
        var extraFirstBig = 0
        var extraGiTransforms: [ModularTransform] = []
        if nbExtraChannels > 0 {
            // `DecodeGlobalInfo`: the extra channels form the global
            // modular image (no colour channels for VarDCT); each is sized
            // `DivCeil(xsize_upsampled, ecups)` with shift
            // `log2(ecups) − log2(upsampling)`. Channels larger than a
            // group are deferred to the DC/AC group sections.
            var giImage = ModularImage.fresh(
                xsize: xsize, ysize: ysize, nbColor: 0, nbExtra: nbExtraChannels)
            let frameUpsLog = log2Floor(upsampling)
            for ec in 0..<nbExtraChannels {
                let ecUps = ec < fh.extraChannelUpsampling.count
                    ? max(1, Int(fh.extraChannelUpsampling[ec])) : 1
                let ecW = (xsizeUp + ecUps - 1) / ecUps
                let ecH = (ysizeUp + ecUps - 1) / ecUps
                let shift = log2Floor(ecUps) - frameUpsLog
                giImage.channels[ec] = ModularChannel(
                    width: ecW, height: ecH,
                    hshift: max(0, shift), vshift: max(0, shift))
            }
            var giOptions = MDOptions()
            giOptions.maxChanSize = groupDim
            giOptions.groupDim = groupDim
            let giResult: (header: GroupHeader, transforms: [ModularTransform])
            do {
                giResult = try mdModularDecode(
                    reader: &r, image: &giImage, groupId: 0, options: giOptions,
                    global: globalCode, bitDepth: modularBitDepth, undoTransforms: false)
            } catch {
                throw DecoderError.notImplemented(
                    "VarDCT decode: extra-channel global section: \(error)")
            }
            var firstBig = giImage.channels.count
            for c in 0..<giImage.channels.count where c >= giImage.nbMetaChannels {
                let ch = giImage.channels[c]
                if ch.width > groupDim || ch.height > groupDim {
                    firstBig = c
                    break
                }
            }
            if firstBig == giImage.channels.count {
                do {
                    try mdUndoTransforms(
                        giResult.transforms, image: &giImage,
                        wpHeader: giResult.header.wpHeader, bitDepth: modularBitDepth)
                } catch {
                    throw DecoderError.notImplemented(
                        "VarDCT decode: extra-channel inverse transform: \(error)")
                }
                guard giImage.channels.count == nbExtraChannels else {
                    throw DecoderError.notImplemented(
                        "VarDCT decode: extra-channel image has \(giImage.channels.count) "
                        + "channels after the inverse transforms")
                }
                extraChannelPlanes = giImage.channels.map(\.pixels)
            } else {
                extraGiImage = giImage
                extraGiGH = giResult.header
                extraGiTransforms = giResult.transforms
                extraFirstBig = firstBig
            }
        }
        _ = extraFirstBig
        let _ = (kRequiredSizeX, kRequiredSizeY, DequantMatricesAC.self)

        // (7-11) DC groups. libjxl decodes each DC group as an
        // independent pair of modular sub-images — `DecodeVarDCTDC`
        // (3 DC channels) and `DecodeAcMetadata` (4 channels: YToX,
        // YToB, ACS+QF, EPF sharpness). A DC group covers a
        // `groupDim`-block square region of the frame, clipped at the
        // edges (libjxl `frame_dimensions.h::DCGroupRect`). For frames
        // ≤ one DC group this loop runs once; larger frames (> ~2048
        // px) stitch each group's sub-region into the full-frame DC /
        // cmap / EPF / strategy planes. DC group `dcG` lives at TOC
        // section `1 + dcG`.
        // Block-grid dimensions with chroma-subsampling-aware padding,
        // mirroring libjxl `FrameDimensions::Set`:
        //   xsize_blocks = DivCeil(xsize, 8 << maxHShift) << maxHShift
        // For 4:4:4 this is the plain `ceil(xsize/8)`. For subsampled
        // frames the luma grid is padded up to a multiple of the
        // subsampling factor so the chroma block grid aligns — e.g. a
        // 30×18 4:2:0 frame is 4×4 blocks, not 4×3. (The old
        // `(xsize+7)/8` only matched for dims already a multiple of
        // `8 << shift`, which is why odd-sized 4:2:0/4:2:2 frames
        // tripped `acsCountMismatch`.)
        let blkCS = fh.chromaSubsampling
        let xsizeBlocks =
            ((xsize + (8 << blkCS.maxHShift) - 1) / (8 << blkCS.maxHShift))
            << blkCS.maxHShift
        let ysizeBlocks =
            ((ysize + (8 << blkCS.maxVShift) - 1) / (8 << blkCS.maxVShift))
            << blkCS.maxVShift
        let dcWidth = xsizeBlocks
        let dcHeight = ysizeBlocks
        // Colour-tile map dimensions — one entry per 64-px tile.
        let acCmapWidth = max(1, (dcWidth + 7) / 8)
        let acCmapHeight = max(1, (dcHeight + 7) / 8)
        // Per-STORAGE-channel DC plane shifts + dimensions. Storage
        // order is [Y, X, B]; the colour-channel HShift/VShift map
        // to it as Y=colour 1, X=colour 0, B=colour 2 (libjxl
        // `dec_modular.cc::DecodeVarDCTDC`). For 4:4:4 all shifts
        // are 0 and the chroma planes equal the full DC grid.
        let dcCS = fh.chromaSubsampling
        let dcChanHShift = [dcCS.hShift(1), dcCS.hShift(0), dcCS.hShift(2)]
        let dcChanVShift = [dcCS.vShift(1), dcCS.vShift(0), dcCS.vShift(2)]
        let dcChanWidth = (0..<3).map { dcWidth >> dcChanHShift[$0] }
        let dcChanHeight = (0..<3).map { dcHeight >> dcChanVShift[$0] }
        // Full-frame accumulators stitched from each DC group. Each
        // channel sized at its (possibly subsampled) DC resolution.
        var dcValues: [[Int32]] = (0..<3).map {
            [Int32](repeating: 0,
                    count: dcChanWidth[$0] * dcChanHeight[$0])
        }
        var ytoxMapFull = [Int32](
            repeating: 0, count: acCmapWidth * acCmapHeight)
        var ytobMapFull = [Int32](
            repeating: 0, count: acCmapWidth * acCmapHeight)
        var epfSharpnessFull = [Int32](
            repeating: 0, count: dcWidth * dcHeight)
        var acsSegments: [ACStrategyImage.Segment] = []
        var dcExtraPrecision: UInt32 = 0

        // Resolve the modular tree + post-tree codebook a sub-image's
        // GroupHeader points at. `use_global_tree=true` reuses the
        // global tree decoded in DC-global; `false` reads a local
        // tree inline (the same EntropySectionHeader → codebook →
        // ModularTree → post-tree header → post-tree codebook
        // sequence libjxl `ModularDecode` runs). Frames with multiple
        // DC groups commonly set `has_tree=false`, so every DC group /
        // ACMeta sub-image then carries its own local tree.
        func placeRegion(_ src: [Int32], into dst: inout [Int32],
                         offX: Int, offY: Int, w: Int, h: Int,
                         dstWidth: Int) {
            for ly in 0..<h {
                let srcRow = ly * w
                let dstRow = (offY + ly) * dstWidth + offX
                for lx in 0..<w {
                    dst[dstRow + lx] = src[srcRow + lx]
                }
            }
        }

        for dcG in 0..<numDcGroups {
            try Task.checkCancellation()
            let gx = dcG % numDcGroupsX
            let gy = dcG / numDcGroupsX
            let gOffX = gx * groupDim          // top-left block offset
            let gOffY = gy * groupDim
            let gW = min(groupDim, dcWidth - gOffX)
            let gH = min(groupDim, dcHeight - gOffY)
            // Seek to DC group dcG's TOC section. Single-section
            // frames share the cursor (no seek).
            if tocEntries > 1 {
                r.seek(toBitPosition: sectionBitStart(1 + dcG))
            }
            // extra_precision — ReadFixedBits<2>. cjxl emits a
            // uniform value across DC groups, which we require (a
            // per-group value would need per-group DC dequant).
            if !useDcFrame {
            let extra: UInt32
            do { extra = try r.read(bits: 2) }
            catch let e as BitstreamError {
                throw DecoderError.notImplemented(
                    "VarDCT decode: DC group \(dcG) extra_precision "
                    + "read failed: \(e)")
            }
            if dcG == 0 {
                dcExtraPrecision = extra
            } else if extra != dcExtraPrecision {
                throw DecoderError.notImplemented(
                    "VarDCT decode: DC groups disagree on "
                    + "extra_precision (\(dcExtraPrecision) vs "
                    + "\(extra)) — per-group DC scaling not "
                    + "implemented")
            }
            // DC group GroupHeader + tree.
            // `DecodeVarDCTDC`: three channels (Y, X, B) at the chroma-
            // shifted DC resolution, `ModularGenericDecompress` with the
            // default options.
            var dcImage = ModularImage(channels: (0..<3).map { s in
                ModularChannel(width: gW >> dcChanHShift[s], height: gH >> dcChanVShift[s])
            }, nbMetaChannels: 0)
            do {
                _ = try mdModularDecode(
                    reader: &r, image: &dcImage, groupId: 1 + dcG, options: MDOptions(),
                    global: globalCode, bitDepth: modularBitDepth, undoTransforms: true)
            } catch {
                throw DecoderError.notImplemented(
                    "VarDCT decode: DC group \(dcG) channel decode failed: \(error)")
            }
            guard dcImage.channels.count == 3, (0..<3).allSatisfy({ s in
                dcImage.channels[s].width == gW >> dcChanHShift[s]
                    && dcImage.channels[s].height == gH >> dcChanVShift[s]
            }) else {
                throw DecoderError.notImplemented(
                    "VarDCT decode: DC group \(dcG) modular image changed shape")
            }
            let dcVals = dcImage.channels.map(\.pixels)
            for c in 0..<3 {
                placeRegion(dcVals[c], into: &dcValues[c],
                            offX: gOffX >> dcChanHShift[c],
                            offY: gOffY >> dcChanVShift[c],
                            w: gW >> dcChanHShift[c],
                            h: gH >> dcChanVShift[c],
                            dstWidth: dcChanWidth[c])
            }
            } // !useDcFrame
            // `DecodeGroup(ModularDC)`: the deferred extra channels with
            // shift ≥ 3 decode here, from the same section.
            if var giImage = extraGiImage {
                extraGiImage = nil
                do {
                    try MDFrameDecoder.decodeGroup(
                        full: &giImage,
                        rect: (x0: gx * dcGroupDim, y0: gy * dcGroupDim, xsize: dcGroupDim, ysize: dcGroupDim),
                        reader: &r, minShift: 3, maxShift: 1000, streamId: 1 + numDcGroups + dcG,
                        groupDim: groupDim, global: globalCode, bitDepth: modularBitDepth)
                } catch {
                    throw DecoderError.notImplemented(
                        "VarDCT decode: DC group \(dcG) extra-channel decode failed: \(error)")
                }
                extraGiImage = giImage
            }

            // ACMetadata for this DC group. count is read with
            // `CeilLog2Nonzero(DCGroupRect area)` bits.
            let acMetaUpper = gW * gH
            let acMetaBits = Int(ceilLog2(UInt32(max(1, acMetaUpper))))
            let acMetaCount: Int
            do {
                acMetaCount = Int(try r.read(bits: acMetaBits)) + 1
            } catch let e as BitstreamError {
                throw DecoderError.notImplemented(
                    "VarDCT decode: DC group \(dcG) ACMeta count "
                    + "read failed: \(e)")
            }
            // `DecodeAcMetadata`: YToX and YToB at colour-tile resolution
            // (shift 3), the (strategy, quant field) pairs, the EPF
            // sharpness field.
            let cW = max(1, (gW + 7) / 8)
            let cH = max(1, (gH + 7) / 8)
            var acMetaImage = ModularImage(channels: [
                ModularChannel(width: cW, height: cH, hshift: 3, vshift: 3),
                ModularChannel(width: cW, height: cH, hshift: 3, vshift: 3),
                ModularChannel(width: acMetaCount, height: 2),
                ModularChannel(width: gW, height: gH),
            ], nbMetaChannels: 0)
            do {
                _ = try mdModularDecode(
                    reader: &r, image: &acMetaImage, groupId: 1 + 2 * numDcGroups + dcG,
                    options: MDOptions(), global: globalCode, bitDepth: modularBitDepth,
                    undoTransforms: true)
            } catch {
                throw DecoderError.notImplemented(
                    "VarDCT decode: DC group \(dcG) ACMeta channel decode failed: \(error)")
            }
            guard acMetaImage.channels.count == 4,
                  acMetaImage.channels[0].width == cW, acMetaImage.channels[0].height == cH,
                  acMetaImage.channels[1].width == cW, acMetaImage.channels[1].height == cH,
                  acMetaImage.channels[2].width == acMetaCount, acMetaImage.channels[2].height == 2,
                  acMetaImage.channels[3].width == gW, acMetaImage.channels[3].height == gH else {
                throw DecoderError.notImplemented(
                    "VarDCT decode: DC group \(dcG) ACMeta image changed shape")
            }
            let acMetaVals = acMetaImage.channels.map(\.pixels)
            placeRegion(acMetaVals[0], into: &ytoxMapFull,
                        offX: gOffX / 8, offY: gOffY / 8,
                        w: cW, h: cH, dstWidth: acCmapWidth)
            placeRegion(acMetaVals[1], into: &ytobMapFull,
                        offX: gOffX / 8, offY: gOffY / 8,
                        w: cW, h: cH, dstWidth: acCmapWidth)
            placeRegion(acMetaVals[3], into: &epfSharpnessFull,
                        offX: gOffX, offY: gOffY, w: gW, h: gH,
                        dstWidth: dcWidth)
            acsSegments.append(ACStrategyImage.Segment(
                offsetX: gOffX, offsetY: gOffY, width: gW, height: gH,
                channel2: acMetaVals[2], count: acMetaCount))
            if trace {
                FileHandle.standardError.write(Data((
                    "TRACE DCgroup \(dcG) @(\(gOffX),\(gOffY)) "
                    + "\(gW)×\(gH) blk: acMetaCount="
                    + "\(acMetaCount)\n").utf8))
            }
        }

        // Build the full-frame AC strategy plane from every DC
        // group's channel-2 segment.
        let acsImage: ACStrategyImage
        do {
            acsImage = try ACStrategyImage.buildMultiGroup(
                fullWidth: xsizeBlocks, fullHeight: ysizeBlocks,
                segments: acsSegments)
        } catch let e as ACStrategyImageError {
            throw DecoderError.notImplemented(
                "VarDCT decode: AC strategy plane build failed: \(e)")
        }
        if trace {
            var counts = [Int: Int]()
            for fb in acsImage.firstBlocks {
                let s = acsImage.at(x: fb.x, y: fb.y).strategy
                counts[Int(s.rawValue), default: 0] += 1
            }
            FileHandle.standardError.write(Data((
                "TRACE ACStrategyImage: \(acsImage.firstBlocks.count) "
                + "first-blocks, strategies=\(counts)\n").utf8))
            // JXL_TRACE_BLK="bx,by" → dump the strategy + first-block
            // of one block (debug aid for localised pixel residuals).
            if let q = ProcessInfo.processInfo
                .environment["JXL_TRACE_BLK"] {
                let parts = q.split(separator: ",").compactMap { Int($0) }
                if parts.count == 2,
                   parts[0] >= 0, parts[0] < xsizeBlocks,
                   parts[1] >= 0, parts[1] < ysizeBlocks {
                    let e = acsImage.at(x: parts[0], y: parts[1])
                    FileHandle.standardError.write(Data((
                        "TRACE_BLK (\(parts[0]),\(parts[1])): "
                        + "strategy=\(e.strategy) raw="
                        + "\(e.strategy.rawValue) firstBlock="
                        + "(\(e.firstBlockX),\(e.firstBlockY)) "
                        + "isFirst=\(e.isFirstBlock) qf=\(e.qf)\n"
                    ).utf8))
                }
            }
        }
        // Per-cell QF — every cell inherits its first-block's QF.
        var perBlockQF = [Int32](
            repeating: 5, count: xsizeBlocks * ysizeBlocks)
        for cy in 0..<ysizeBlocks {
            for cx in 0..<xsizeBlocks {
                let entry = acsImage.at(x: cx, y: cy)
                perBlockQF[cy * xsizeBlocks + cx] = acsImage.at(
                    x: entry.firstBlockX, y: entry.firstBlockY).qf
            }
        }
        let qfRow = perBlockQF.first ?? 5

        // For multi-section frames, AC global lives at section
        // `1 + num_dc_groups`.
        if tocEntries > 1 {
            r.seek(toBitPosition: sectionBitStart(1 + numDcGroups))
        }

        // (12) ProcessACGlobal — DequantMatrices.Decode (all-default
        // shortcut). libjxl `dec_frame.cc::ProcessACGlobal`:
        //
        //     matrices.Decode(br)  // 1 bit all_default + (per-table reads)
        //     EnsureComputed(...)  // no bits
        //     num_histograms = 1 + ReadBits(CeilLog2Nonzero(num_groups))
        //     for each pass:
        //         used_orders = U32(kOrderEnc, br)
        //         DecodeCoeffOrders(...)      // permutation if used_orders > 0
        //         DecodeHistograms(...)       // AC histograms
        let _ = DequantMatricesAC.self
        let acGStart = r.position
        let acDequantInfo: (allDefault: Bool, encodings: [QuantEncoding])
        do {
            acDequantInfo = try DequantMatricesAC.read(
                from: &r,
                globalTree: globalTree,
                globalPostHeader: globalPostHeader,
                globalPostCodebook: globalPostCodebook,
                numDcGroups: numDcGroups)
        } catch DequantMatricesACError.perSlotRead(let slot, let e) {
            throw DecoderError.notImplemented(
                "VarDCT decode: DequantMatrices slot \(slot) "
                + "QuantEncoding read failed: \(e)")
        } catch let e as DequantMatricesACError {
            throw DecoderError.notImplemented(
                "VarDCT decode: DequantMatrices.Decode read failed: \(e)"
            )
        }
        _ = acDequantInfo
        traceLayer("DequantMatricesAC.\(acDequantInfo.allDefault ? "allDefault" : "perSlot(\(acDequantInfo.encodings.count))")",
                   before: acGStart, after: r.position)
        // Custom quantisation tables (`DequantMatrices::Decode` +
        // `ComputeQuantTable`): every slot may carry its own encoding.
        // `nil` means the library default for that slot.
        func quantEncoding(slot: Int) -> QuantEncoding? {
            guard !acDequantInfo.allDefault, slot < acDequantInfo.encodings.count else { return nil }
            let enc = acDequantInfo.encodings[slot]
            return enc.mode == .library ? nil : enc
        }
        func bandsTuple(_ p: DctParams) -> (x: [Float], y: [Float], b: [Float]) {
            (x: p.distanceBands[0], y: p.distanceBands[1], b: p.distanceBands[2])
        }
        // Full table for a slot whose default is computed by `defaultTable`
        // (RAW tables and the 8×8 special modes).
        func quantTable(slot: Int, defaultTable: () throws -> [Float]) throws -> [Float] {
            guard let enc = quantEncoding(slot: slot) else { return try defaultTable() }
            do {
                switch enc.mode {
                case .library:
                    return try defaultTable()
                case .raw:
                    guard let q = enc.rawQtable, let den = enc.rawQtableDen else { return try defaultTable() }
                    return try QuantWeights.getRAWQuantWeights(qtable: q, qtableDen: den)
                case .dct:
                    guard let p = enc.dctParams else { return try defaultTable() }
                    return try QuantWeights.getQuantWeights(
                        rows: 8 * kRequiredSizeX[slot], cols: 8 * kRequiredSizeY[slot], bands: bandsTuple(p))
                case .id:
                    guard let w = enc.idWeights, w.count == 3 else { return try defaultTable() }
                    return QuantWeights.getIdentityQuantWeights((x: w[0], y: w[1], b: w[2]))
                case .dct2:
                    guard let w = enc.dct2Weights, w.count == 3 else { return try defaultTable() }
                    return QuantWeights.getDCT2QuantWeights((x: w[0], y: w[1], b: w[2]))
                case .dct4:
                    guard let p = enc.dctParams, let m = enc.dct4Multipliers, m.count == 3 else {
                        return try defaultTable()
                    }
                    var t = try QuantWeights.getDCT4QuantWeights(bands: bandsTuple(p))
                    for c in 0..<3 where m[c].count >= 2 {
                        t[c * 64 + 1] /= m[c][0]
                        t[c * 64 + 8] /= m[c][0]
                        t[c * 64 + 9] /= m[c][1]
                    }
                    return t
                case .dct4x8:
                    guard let p = enc.dctParams, let m = enc.dct4x8Multipliers, m.count == 3 else {
                        return try defaultTable()
                    }
                    var t = try QuantWeights.getDCT4X8QuantWeights(bands: bandsTuple(p))
                    for c in 0..<3 { t[c * 64 + 8] /= m[c] }
                    return t
                case .afv:
                    guard let p = enc.dctParams, let p4 = enc.dctParamsAfv4x4,
                          let w = enc.afvWeights, w.count == 3 else { return try defaultTable() }
                    return try QuantWeights.getAFVQuantWeights(
                        dct4x8Bands: bandsTuple(p), dct4x4Bands: bandsTuple(p4),
                        afvWeights: (x: w[0], y: w[1], b: w[2]))
                }
            } catch let e as QuantWeightsError {
                throw DecoderError.notImplemented(
                    "VarDCT decode: quant table slot \(slot) (\(enc.mode)): \(e)")
            }
        }

        // num_histograms = 1 + ReadBits(CeilLog2Nonzero(num_groups))
        // For num_groups=1 this is 0 bits; for larger groups it scales.
        let nhBits = Int(ceilLog2(UInt32(max(1, numGroups))))
        let nhStart = r.position
        let acNumHistograms: UInt32
        do {
            acNumHistograms = 1 + (nhBits == 0 ? 0 : try r.read(bits: nhBits))
        } catch let e as BitstreamError {
            throw DecoderError.notImplemented(
                "VarDCT decode: ProcessACGlobal num_histograms read "
                + "failed: \(e)"
            )
        }
        traceLayer("ACGlobal.num_histograms=\(acNumHistograms)",
                   before: nhStart, after: r.position)

        // used_orders U32 per pass. kOrderEnc = U32(Val(0x5F), Val(0x13),
        // Val(0), Bits(13)) per `frame_header.h:503`. For `cjxl -d 1`
        // typical fixtures, used_orders=0 (selector=2 → no orders
        // permuted, default zigzag-style order). 1 pass on a single
        // group is the usual cjxl shape.
        let numPassesActual = max(1, Int(fh.passes.numPasses))
        // libjxl `ProcessACGlobal` reads, per pass, the coefficient
        // orders and then that pass's AC histograms.
        let acContexts = Int(acNumHistograms) * bctx.numACContexts
        var acHistsPerPass: [(EntropySectionHeader, MultiClusterCodebook)] = []
        acHistsPerPass.reserveCapacity(numPassesActual)
        func readACHistograms(_ passIdx: Int) throws {
            let acHdrStart = r.position
            let acHdr: EntropySectionHeader
            do {
                acHdr = try EntropySectionHeader.read(
                    from: &r, numContexts: acContexts
                )
            } catch let e as EntropySectionHeaderError {
                throw DecoderError.notImplemented(
                    "VarDCT decode: AC histograms[\(passIdx)] header "
                    + "read failed: \(e). num_contexts=\(acContexts)"
                )
            }
            traceLayer("ACHist[\(passIdx)].header", before: acHdrStart,
                       after: r.position)
            let acCBStart = r.position
            let acCB: MultiClusterCodebook
            do {
                acCB = try MultiClusterCodebook.read(from: &r, header: acHdr)
            } catch let e as MultiClusterCodebookError {
                throw DecoderError.notImplemented(
                    "VarDCT decode: AC histograms[\(passIdx)] codebook "
                    + "read failed: \(e). numHistograms=\(acHdr.numHistograms)"
                )
            }
            traceLayer("ACHist[\(passIdx)].codebook", before: acCBStart,
                       after: r.position)
            if trace {
                FileHandle.standardError.write(Data(
                    "TRACE ACHist[\(passIdx)]: numClusters=\(acHdr.contextMap.numClusters), usePrefix=\(acHdr.usePrefixCode), logAlpha=\(acHdr.logAlphaSize)\n".utf8
                ))
            }
            acHistsPerPass.append((acHdr, acCB))
        }
        var usedOrdersPerPass: [UInt32] = []
        usedOrdersPerPass.reserveCapacity(numPassesActual)
        // Per-pass per-ord per-channel coeff orders. Empty when
        // `used_orders` bit is unset (caller falls back to natural).
        var coeffOrdersPerPass: [[Int: [[Int]]]] = []
        coeffOrdersPerPass.reserveCapacity(numPassesActual)
        for passIdx in 0..<numPassesActual {
            let uoStart = r.position
            let used: UInt32
            do {
                used = try r.readU32((
                    .literal(0x5F), .literal(0x13), .literal(0),
                    .bits(13)
                ))
            } catch let e as BitstreamError {
                throw DecoderError.notImplemented(
                    "VarDCT decode: ACGlobal used_orders[\(passIdx)] "
                    + "read failed: \(e)"
                )
            }
            usedOrdersPerPass.append(used)
            traceLayer("ACGlobal.used_orders[\(passIdx)]=\(used)",
                       before: uoStart, after: r.position)
            // For non-zero used_orders, libjxl reads a permutation
            // entropy section here (kPermutationContexts contexts),
            // then per (ord, channel) reads a Lehmer-coded permutation.
            // We currently DISCARD the permutation (no AC strategy
            // beyond DCT8 fires per block in our fixtures yet) but
            // must still consume the bits.
            if used != 0 {
                let pHdrStart = r.position
                let pHdr: EntropySectionHeader
                do {
                    pHdr = try EntropySectionHeader.read(
                        from: &r, numContexts: CoeffOrders.kPermutationContexts
                    )
                } catch let e as EntropySectionHeaderError {
                    throw DecoderError.notImplemented(
                        "VarDCT decode: ACGlobal permutation header "
                        + "read failed: \(e)"
                    )
                }
                let pCB: MultiClusterCodebook
                do {
                    pCB = try MultiClusterCodebook.read(from: &r, header: pHdr)
                } catch let e as MultiClusterCodebookError {
                    throw DecoderError.notImplemented(
                        "VarDCT decode: ACGlobal permutation codebook "
                        + "read failed: \(e)"
                    )
                }
                traceLayer(
                    "ACGlobal.permHist[\(passIdx)]",
                    before: pHdrStart, after: r.position
                )
                var pStream = TokenStreamReader(header: pHdr, codebook: pCB)
                let decoded: [Int: [[Int]]]
                do {
                    decoded = try CoeffOrders.decodePermutations(
                        usedOrders: UInt16(used & 0xFFFF),
                        from: &r, stream: &pStream
                    )
                } catch let e as CoeffOrdersError {
                    throw DecoderError.notImplemented(
                        "VarDCT decode: ACGlobal permutation read "
                        + "failed: \(e)"
                    )
                }
                coeffOrdersPerPass.append(decoded)
                if trace {
                    FileHandle.standardError.write(Data(
                        "TRACE ACGlobal.perms[\(passIdx)]: usedOrders=\(used), decoded ords=\(decoded.keys.sorted()), bits consumed at pos=\(r.position)\n".utf8
                    ))
                }
            } else {
                coeffOrdersPerPass.append([:])
            }
            try readACHistograms(passIdx)
        }

        // (13) Per-pass AC DecodeHistograms. libjxl
        // `dec_frame.cc::ProcessACGlobal` (line 393-410):
        //
        //     for (size_t i = 0; i < num_passes; i++) {
        //         used_orders = U32(kOrderEnc, br);   // already read above
        //         DecodeCoeffOrders(...);             // skipped (used_orders=0)
        //         num_contexts = num_histograms × block_ctx_map.NumACContexts()
        //         DecodeHistograms(br, num_contexts, &code[i], &context_map[i])
        //     }
        //
        // `NumACContexts() = num_ctxs × (kNonZeroBuckets +
        // kZeroDensityContextCount) = num_ctxs × (37 + 458)`. For the
        // default kDefaultBlockCtxMap (15 clusters): 15 × 495 = 7425.
        // With num_histograms=1 → 7425 AC contexts.

        // (14) Per-block AC coefficient stream — Bites 1+2. libjxl
        // `dec_group.cc::DecodeACVarBlock` reads, for each (block, channel):
        //
        //     block_ctx = block_ctx_map.Context(qdc, qf, ord, c)
        //     nzero_ctx = NonZeroContext(predicted_nnz, block_ctx) + ctx_offset
        //     nzeros = readToken(nzero_ctx)
        //     histo_offset = ctx_offset + ZeroDensityContextsOffset(block_ctx)
        //     for k in coveredBlocks..<size while nzeros != 0:
        //         ctx = histo_offset + ZeroDensityContext(nzeros, k, ...)
        //         u = readToken(ctx)
        //         coeff = UnpackSigned(u)        // ZigZag.unpack
        //         block[order[k]] += coeff << shift
        //         if u != 0: nzeros--
        //
        // `ANSSymbolReader::Create` reads a 32-bit rANS state on first
        // token. Our `TokenStreamReader` triggers that lazily inside
        // `readToken` via `ANSStreamDecoder`.
        //
        // For `cjxl -d 1` 8×8 fixture: 1 AC block (1×1 grid) × 3
        // channels (X/Y/B). AC strategy = DCT8 (covered_blocks=1,
        // size=64). All 7425 contexts route to cluster 0 (single
        // histogram), so block_ctx specifics don't change bit positions
        // — order does, but we use `Array(0..<64)` here since the
        // block-position payload is consumed by Bite 3 (Dequant + IDCT).
        // Multi-AC-group AC token decode. For multi-section frames,
        // each AC group lives at its own TOC entry — we seek the
        // BitReader to that section's byte boundary, create a fresh
        // `TokenStreamReader` (the rANS state initialises lazily on
        // first read), and decode the per-block AC tokens for that
        // group's block grid. Each AC group covers a `groupDim` x
        // `groupDim` pixel region (cropped at frame edges).
        // Bits read per AC group to select its histogram set (0 when
        // num_histograms == 1). libjxl `CeilLog2Nonzero(num_histograms)`.
        let histoSelectorBits = Int(ceilLog2(acNumHistograms))
        // Per-ord natural-order cache. Lazily populated during the AC
        // decode loop — most fixtures only touch DCT8 (ord 0) but
        // textured cjxl-d=1 frames mix in DCT16x16 (ord 2),
        // DCT32x16/16x32 (ord 6), etc.
        var naturalOrderCache: [Int: [Int]] = [:]
        // Use the chroma-subsampling-aware padded block grid (same as
        // `xsizeBlocks`/`ysizeBlocks`) so the AC grid matches the DC
        // plane — for subsampled frames the luma grid is padded up to a
        // multiple of the subsampling factor (libjxl `FrameDimensions`).
        let totalBlocksX = xsizeBlocks
        let totalBlocksY = ysizeBlocks
        // acBlocks[totalBlockIdx][iterC] is the 64-coef block for the
        // i-th decoded (block, channel) pair, indexed by GLOBAL block
        // position (totalBlocksX × totalBlocksY).
        var acBlocks: [[[Int32]]] = Array(
            repeating: Array(repeating: [Int32](repeating: 0, count: 64),
                             count: 3),
            count: totalBlocksX * totalBlocksY
        )
        let blocksPerGroup = groupDim / 8
        let acDecodeStart = r.position
        // Immutable alias tables are shared; each copied value starts with fresh ANS/LZ77 state.
        let acStreamTemplates = acHistsPerPass.map { TokenStreamReader(header: $0.0, codebook: $0.1) }
        for groupIdx in 0..<numGroups {
            beforeVarDCTGroup?(groupIdx)
            try Task.checkCancellation()
            // Per-group block range (cropped at frame edges).
            let gx = groupIdx % numGroupsX
            let gy = groupIdx / numGroupsX
            let bxStart = gx * blocksPerGroup
            let byStart = gy * blocksPerGroup
            let bxEnd = min(bxStart + blocksPerGroup, totalBlocksX)
            let byEnd = min(byStart + blocksPerGroup, totalBlocksY)
            let groupBlocksX = bxEnd - bxStart
            // libjxl `GetBlockFromBitstream::LoadBlock`: every pass has
            // its own section, reader, ANS state, histogram selector,
            // coefficient orders and nzeros plane; the coefficients of
            // all passes are summed into the block (`<< shift_for_pass`).
            for passIdx in 0..<numPassesActual {
            let passShift = passIdx < fh.passes.shifts.count
                ? Int(fh.passes.shifts[passIdx]) : 0
            // Seek to this group's section. AC group g of pass p lives
            // at TOC entry `2 + numDcGroups + numGroups * p + g` for
            // multi-section frames; single-section reuses the cursor.
            if tocEntries > 1 {
                let acGroupSecIdx = 2 + numDcGroups + numGroups * passIdx + groupIdx
                r.seek(toBitPosition: sectionBitStart(acGroupSecIdx))
            }
            // Per-group histogram selector. libjxl `dec_group.cc:656`
            // — when `num_histograms > 1`, each AC group's token
            // stream opens with `CeilLog2Nonzero(num_histograms)` bits
            // picking which histogram set it uses; that selection
            // shifts every AC context by `cur_histogram ×
            // NumACContexts`. For `num_histograms == 1` no bits are
            // read and the offset is 0.
            let acCtxOffset: Int
            if histoSelectorBits > 0 {
                let curHistogram: UInt32
                do { curHistogram = try r.read(bits: histoSelectorBits) }
                catch let e as BitstreamError {
                    throw DecoderError.notImplemented(
                        "VarDCT decode: AC group \(groupIdx) histogram "
                        + "selector read failed: \(e)")
                }
                guard curHistogram < acNumHistograms else {
                    throw DecoderError.notImplemented(
                        "VarDCT decode: AC group \(groupIdx) invalid "
                        + "histogram selector \(curHistogram) "
                        + "(num_histograms=\(acNumHistograms))")
                }
                acCtxOffset = Int(curHistogram) * bctx.numACContexts
            } else {
                acCtxOffset = 0
            }
            // Fresh ANS state per AC group (lazy init on first read).
            var acTokenStream = acStreamTemplates[passIdx]
            // Per-group, per-channel nzeros plane. Indexed by XYB
            // channel (0=X, 1=Y, 2=B) at that channel's (possibly
            // chroma-subsampled) resolution — libjxl keeps a separate
            // `num_nzeroes` plane per channel and indexes it by the
            // chroma block coordinate `(sbx, sby)`. For multi-block
            // strategies (DCT16x16 etc.) we stamp the first-block's
            // nzeros to ALL covered cells so subsequent first-blocks
            // see the right neighbour values (mirrors libjxl
            // `dec_group.cc`'s `nzeros_pos[...] = nzeros` loop). For
            // 4:4:4 the three planes are identical full-res grids,
            // matching the previous single-plane behaviour.
            let groupBlocksY = byEnd - byStart
            // XYB-channel shifts (0=X, 1=Y, 2=B). Y is always 0.
            let acHShift = [dcCS.hShift(0), dcCS.hShift(1), dcCS.hShift(2)]
            let acVShift = [dcCS.vShift(0), dcCS.vShift(1), dcCS.vShift(2)]
            let gbXc = (0..<3).map {
                (groupBlocksX + (1 << acHShift[$0]) - 1) >> acHShift[$0]
            }
            let gbYc = (0..<3).map {
                (groupBlocksY + (1 << acVShift[$0]) - 1) >> acVShift[$0]
            }
            // Within-group chroma origin per channel (group start
            // block, shifted to chroma resolution).
            let chromaOrgX = (0..<3).map { bxStart >> acHShift[$0] }
            let chromaOrgY = (0..<3).map { byStart >> acVShift[$0] }
            var nzPlaneC: [[Int32]] = (0..<3).map {
                [Int32](repeating: 0, count: gbXc[$0] * gbYc[$0])
            }
            // `cgx`/`cgy` are within-group chroma cell coordinates.
            @inline(__always) func nzPredict(
                xybC: Int, cgx: Int, cgy: Int
            ) -> UInt32 {
                let stride = gbXc[xybC]
                if cgy == 0 && cgx == 0 { return 32 }
                if cgy == 0 {
                    return UInt32(nzPlaneC[xybC][cgx - 1])
                }
                if cgx == 0 {
                    return UInt32(nzPlaneC[xybC][(cgy - 1) * stride + cgx])
                }
                let above = nzPlaneC[xybC][(cgy - 1) * stride + cgx]
                let left  = nzPlaneC[xybC][cgy * stride + (cgx - 1)]
                return UInt32((above + left + 1) >> 1)
            }
            for by in byStart..<byEnd {
                for bx in bxStart..<bxEnd {
                    // Per-cell strategy lookup. Skip non-first-block
                    // cells (covered by a multi-block transform whose
                    // first-block we already decoded).
                    let entry = acsImage.at(x: bx, y: by)
                    if !entry.isFirstBlock { continue }
                    let strategy = entry.strategy
                    let strategySize = strategy.coveredBlocks * 64
                    let ord = strategy.orderBucket
                    // Default natural order for this ord (cached). Used
                    // when used_orders bit is unset; otherwise replaced
                    // by the per-channel decoded permutation below.
                    let naturalOrder: [Int] = {
                        if let cached = naturalOrderCache[ord] { return cached }
                        let computed = CoeffOrders.naturalCoeffOrder(for: strategy)
                        naturalOrderCache[ord] = computed
                        return computed
                    }()
                    let acBlockQF = UInt32(entry.qf)
                    // Per-block DC context index (libjxl
                    // `compressed_dc.cc::DequantDC`). When the
                    // BlockCtxMap carries DC thresholds
                    // (`numDcCtxs > 1`), the block context depends on
                    // which DC buckets the three channels' quantised
                    // DC values fall into — NOT just `dc_idx = 0`.
                    // cjxl emits a non-default BlockCtxMap with DC
                    // thresholds for larger / higher-DC-variance
                    // frames; using a hard-coded 0 routes high-DC
                    // blocks (e.g. the bottom of a vertical gradient,
                    // group rows gy ≥ 2) to the wrong histogram
                    // cluster, corrupting `nzeros` and over-reading
                    // the AC token stream. dcValues is in storage
                    // order [Y, X, B]; the DC plane is full-res for
                    // 4:4:4 so it indexes by global block position.
                    // Per-channel DC plane index at this block,
                    // accounting for chroma subsampling (storage
                    // order [Y, X, B] = dcValues[0/1/2]).
                    let yDcIdx = (by >> dcChanVShift[0]) * dcChanWidth[0]
                        + (bx >> dcChanHShift[0])
                    let xDcIdx = (by >> dcChanVShift[1]) * dcChanWidth[1]
                        + (bx >> dcChanHShift[1])
                    let bDcIdx = (by >> dcChanVShift[2]) * dcChanWidth[2]
                        + (bx >> dcChanHShift[2])
                    let blockDcIdx: Int
                    if !useDcFrame, bctx.numDcCtxs > 1,
                       yDcIdx < dcValues[0].count,
                       xDcIdx < dcValues[1].count,
                       bDcIdx < dcValues[2].count {
                        blockDcIdx = bctx.dcContextIndex(
                            dcX: dcValues[1][xDcIdx],
                            dcY: dcValues[0][yDcIdx],
                            dcB: dcValues[2][bDcIdx])
                    } else {
                        blockDcIdx = 0
                    }
                    // `blockChannels` is XYB-indexed: slot 0 = X,
                    // 1 = Y, 2 = B. libjxl decodes channels in stream
                    // order {1, 0, 2} (Y, X, B), so the i-th decoded
                    // block is stored at its XYB slot `storageC`, not
                    // at iteration index `i`. (Verified against an
                    // instrumented djxl 0.11.2 `dec_group.cc` trace.)
                    // Pre-fill all three channels with zero blocks so
                    // chroma positions that carry no block (subsampled
                    // X/B at odd block coordinates) stay well-formed.
                    var blockChannels: [[Int32]] = [
                        [Int32](repeating: 0, count: strategySize),
                        [Int32](repeating: 0, count: strategySize),
                        [Int32](repeating: 0, count: strategySize),
                    ]
                    let cellsX = strategy.blockCells.cellsX
                    let cellsY = strategy.blockCells.cellsY
                    // libjxl `dec_group.cc:554` iterates channels in
                    // STORAGE order `{1, 0, 2}` (X, then Y, then B —
                    // libjxl stores Y at slot 0 and X at slot 1, so
                    // storage 1 == X, storage 0 == Y, storage 2 == B).
                    // Iteration index `iterIdx` is also the XYB channel
                    // index after this mapping (0=X, 1=Y, 2=B).
                    for iterIdx in 0..<3 {
                        // `storageC` is the XYB channel index of the
                        // i-th decoded block: iter 0 → 1 (Y), iter 1 →
                        // 0 (X), iter 2 → 2 (B).
                        let storageC = [1, 0, 2][iterIdx]
                        let xybC = storageC                 // 0=X, 1=Y, 2=B
                        // Chroma-subsampling block-existence test
                        // (libjxl `GetBlockFromBitstream::LoadBlock`):
                        // a channel's block exists at (bx,by) only when
                        // the chroma coordinate maps back exactly. For
                        // 4:2:0, X/B blocks exist only at even (bx,by).
                        let hs = acHShift[xybC]
                        let vs = acVShift[xybC]
                        let sbx = bx >> hs
                        let sby = by >> vs
                        if (sbx << hs != bx) || (sby << vs != by) {
                            continue
                        }
                        let cgx = sbx - chromaOrgX[xybC]
                        let cgy = sby - chromaOrgY[xybC]
                        var blk = [Int32](repeating: 0, count: strategySize)
                        let predNnz = nzPredict(
                            xybC: xybC, cgx: cgx, cgy: cgy
                        )
                        // BlockCtxMap.Context takes libjxl STORAGE c
                        // (it does the `c^1 if c<2` swap internally
                        // to map storage→ctx_map row).
                        let blockCtx = bctx.context(
                            dcIdx: blockDcIdx, qf: acBlockQF,
                            ord: strategy.orderBucket, c: storageC
                        )
                        // Per-channel coeff order. When the bitstream
                        // emitted a Lehmer-coded permutation for this
                        // (pass, ord, storage_c), use it; otherwise fall
                        // back to the default natural order.
                        let strategyOrder: [Int] = {
                            if passIdx < coeffOrdersPerPass.count,
                               let perOrd = coeffOrdersPerPass[passIdx][ord],
                               storageC < perOrd.count {
                                return perOrd[storageC]
                            }
                            return naturalOrder
                        }()
                        do {
                            try ACDecoder.decodeBlock(
                                block: &blk,
                                order: strategyOrder,
                                coveredBlocks: strategy.coveredBlocks,
                                log2CoveredBlocks: strategy.log2CoveredBlocks,
                                blockCtx: blockCtx,
                                predictedNnz: predNnz,
                                ctxOffset: acCtxOffset,
                                ctxMap: bctx,
                                shift: passShift,
                                stream: &acTokenStream,
                                from: &r
                            )
                        } catch let e as ACDecoderError {
                            throw DecoderError.notImplemented(
                                "VarDCT decode: AC group \(groupIdx) block "
                                + "(\(bx),\(by)) strategy=\(strategy) "
                                + "iter \(iterIdx) (xybC=\(xybC), "
                                + "storageC=\(storageC), blockCtx=\(blockCtx)) "
                                + "decode failed: \(e)"
                            )
                        }
                        // libjxl divides nz by coveredBlocks before
                        // stamping (so all covered cells share an
                        // "average" nnz). Round-up division matches
                        // `dec_group.cc::DecodeACVarBlock` post-stamp.
                        let nzTotal = blk.withUnsafeBufferPointer { values in
                            var count: Int32 = 0
                            for value in values { count += value == 0 ? 0 : 1 }
                            return count
                        }
                        let nzPerCell =
                            (nzTotal + Int32(strategy.coveredBlocks) - 1)
                                / Int32(strategy.coveredBlocks)
                        // Stamp the per-channel chroma-resolution
                        // nzeros plane at this block's covered cells.
                        // For DCT8 (the only strategy in the JPEG
                        // bridge) cellsX = cellsY = 1, so this writes
                        // a single cell at (cgx, cgy).
                        let stride = gbXc[xybC]
                        for cy in 0..<cellsY {
                            for cx in 0..<cellsX {
                                let px = cgx + cx
                                let py = cgy + cy
                                if px < gbXc[xybC] && py < gbYc[xybC] {
                                    nzPlaneC[xybC][py * stride + px] =
                                        nzPerCell
                                }
                            }
                        }
                        blockChannels[storageC] = blk
                    }
                    // Per-strategy IDCT support frontier: DCT8x8 is
                    // primary, DCT16x16 ships in v0.8.0d. Other multi-
                    // cell strategies still rely on the per-cell DC
                    // fallback (which gives the correct result only
                    // for all-zero AC — typical of solid-colour
                    // content). Throw early when the bitstream needs
                    // a path we don't ship yet.
                    try Self.requireInverseTransform(strategy, coefficients: blockChannels)
                    if passIdx == 0 {
                        acBlocks[by * totalBlocksX + bx] = blockChannels
                    } else {
                        let idx = by * totalBlocksX + bx
                        for c in 0..<3 {
                            let n = min(acBlocks[idx][c].count, blockChannels[c].count)
                            acBlocks[idx][c].withUnsafeMutableBufferPointer { destination in
                                blockChannels[c].withUnsafeBufferPointer { source in
                                    for k in 0..<n { destination[k] &+= source[k] }
                                }
                            }
                        }
                    }
                }
            }
            // Per-AC-group modular decode of the deferred (large)
            // extra channels. libjxl `ProcessACGroup` runs the
            // VarDCT AC decode and then `ModularFrameDecoder::
            // DecodeGroup` from the *same* section cursor; the
            // modular data follows the VarDCT AC tokens. Each AC
            // group decodes its `groupDim`-pixel sub-rect of every
            // deferred channel and copies it into the full image.
            // `ProcessACGroup`: after the VarDCT tokens of this pass, the
            // deferred extra channels of the pass's downsampling bracket
            // decode from the same section (`DecodeGroup(ModularAC)`).
            if var giImage = extraGiImage {
                extraGiImage = nil
                let bracket = MDFrameDecoder.downsamplingBracket(fh.passes, pass: passIdx)
                do {
                    try MDFrameDecoder.decodeGroup(
                        full: &giImage,
                        rect: (x0: gx * groupDim, y0: gy * groupDim, xsize: groupDim, ysize: groupDim),
                        reader: &r, minShift: bracket.minShift, maxShift: bracket.maxShift,
                        streamId: 1 + 3 * numDcGroups + 17 + numGroups * passIdx + groupIdx,
                        groupDim: groupDim, global: globalCode, bitDepth: modularBitDepth)
                } catch {
                    throw DecoderError.notImplemented(
                        "VarDCT decode: AC group \(groupIdx) pass \(passIdx) "
                        + "extra-channel decode failed: \(error)")
                }
                extraGiImage = giImage
            }
            } // pass loop
        }
        // Finish the deferred extra channels: every AC group has
        // filled its sub-rect, so undo the meta-transforms once on
        // the assembled full-frame image.
        if var giImage = extraGiImage, let giGH = extraGiGH {
            do {
                try mdUndoTransforms(
                    extraGiTransforms, image: &giImage,
                    wpHeader: giGH.wpHeader, bitDepth: modularBitDepth)
            } catch {
                throw DecoderError.notImplemented(
                    "VarDCT decode: deferred extra-channel inverse "
                    + "transform failed: \(error)")
            }
            extraChannelPlanes = (0..<nbExtraChannels).map {
                giImage.channels[$0].pixels
            }
        }
        let numBlocksXAC = totalBlocksX
        let numBlocksYAC = totalBlocksY
        traceLayer("AC \(numGroups) group(s) "
                   + "(\(numBlocksXAC)×\(numBlocksYAC) blocks total)",
                   before: acDecodeStart, after: r.position)

        // v0.12.0gu — early-capture hook for `decodeToCoefficients`.
        // At this point dcValues + acBlocks are fully populated; we
        // can package them as `JXLCoefficientPlanes` and throw the
        // sentinel error to escape the rest of the pixel pipeline.
        if capturingCoefficients {
            // Per-channel block dimensions from `fh.chromaSubsampling`.
            // libjxl HShift(c) = maxhs - kHShift[channel_mode_[c]].
            let kH: [Int] = [0, 1, 1, 0]
            let kV: [Int] = [0, 1, 0, 1]
            let cm = [
                Int(fh.chromaSubsampling.channelModes.0),
                Int(fh.chromaSubsampling.channelModes.1),
                Int(fh.chromaSubsampling.channelModes.2),
            ]
            let maxhs = max(kH[cm[0]], kH[cm[1]], kH[cm[2]])
            let maxvs = max(kV[cm[0]], kV[cm[1]], kV[cm[2]])
            // Per-channel block dims (in JXL XYB / channel order).
            // channelModes is stored in libjxl image-channel order
            // (after the XOR remap): channelModes[0]=Cb, [1]=Y, [2]=Cr.
            // We want JXL channel order [X=Cb, Y, B=Cr] which matches
            // — `channelModes[c]` indexed directly by JXL channel.
            var bpc: [(blocksX: Int, blocksY: Int)] = []
            for c in 0..<3 {
                let hs = maxhs - kH[cm[c]]
                let vs = maxvs - kV[cm[c]]
                bpc.append((
                    blocksX: totalBlocksX >> hs,
                    blocksY: totalBlocksY >> vs))
            }
            // dcValues is in storage order [Y, X, B] (per the XOR
            // remap inside the modular sub-image decode). Convert
            // to JXL channel order [X=Cb, Y, B=Cr].
            let dcInXYBOrder: [[Int32]] = [
                dcValues[1],   // X (Cb)
                dcValues[0],   // Y
                dcValues[2],   // B (Cr)
            ]
            // acBlocks[blkIdx][c] is indexed by XYB channel c
            // directly (per the `acIterToXYB = [0, 1, 2]` mapping).
            // For chroma-subsampled frames the X/B channels carry
            // their block only at full positions `(cbx<<hs, cby<<vs)`;
            // sample at the chroma grid so each channel's plane has
            // exactly `bpc[c]` blocks. For 4:4:4 (hs=vs=0) this
            // collapses to the full-grid enumeration.
            var acInXYBOrder: [[[Int32]]] = [[], [], []]
            for c in 0..<3 {
                let hs = maxhs - kH[cm[c]]
                let vs = maxvs - kV[cm[c]]
                let cbX = totalBlocksX >> hs
                let cbY = totalBlocksY >> vs
                acInXYBOrder[c].reserveCapacity(cbX * cbY)
                for cby in 0..<cbY {
                    for cbx in 0..<cbX {
                        let fullIdx =
                            (cby << vs) * totalBlocksX + (cbx << hs)
                        acInXYBOrder[c].append(acBlocks[fullIdx][c])
                    }
                }
            }

            // **CFL inverse for JPEG-bridge frames.** libjxl's
            // `--lossless_jpeg=1` encoder applies chroma-from-luma
            // (CFL) decorrelation on the X (Cb) and B (Cr) AC
            // coefficients when `force_cfl_jpeg_recompression` is
            // true (default). The forward transform (libjxl
            // `enc_frame.cc:973-991`) is:
            //
            //   scale       = RatioJPEG(cmap[tx, ty])
            //                = cmap * 2048 / 84
            //   coeff_scale = (qt × scale + 1024) >> 11
            //   cfl_factor  = (Y_coef × coeff_scale + 1024) >> 11
            //   stored_chroma = original_chroma − cfl_factor
            //
            // where `qt = (1<<11) × qtable_Y[i] / qtable_C[i]` is
            // the per-position luma-to-chroma quant ratio, and
            // `Y_coef` is the Y-channel AC coefficient at the same
            // transposed position. The decoder mirrors this
            // (`dec_group.cc:386-400`) to recover the original
            // chroma. We do the same below at the
            // `decodeToCoefficients` boundary: if slot 0 of the
            // DequantMatrices is a JPEG-compatible RAW table
            // (`abs(qtable_den - 1/(8·255)) < 1e-8` —
            // `dec_group.cc:223-227`) and the frame is 4:4:4 YCbCr,
            // add `cfl_factor` back to each X / B AC coefficient.
            let kCFLFixedPointPrecision = 11
            let kDefaultColorFactor: Int32 = 84
            let halfRound: Int32 = 1 << (kCFLFixedPointPrecision - 1)
            let isJPEGCompatibleRAW: Bool = {
                guard !acDequantInfo.allDefault,
                      !acDequantInfo.encodings.isEmpty else {
                    return false
                }
                let enc = acDequantInfo.encodings[0]
                guard enc.mode == .raw,
                      let qden = enc.rawQtableDen,
                      let qtab = enc.rawQtable,
                      qtab.count == 3 * 64
                else { return false }
                // libjxl `dec_group.cc:223-227` JPEG fingerprint.
                return abs(qden - Float(1.0 / (8.0 * 255.0))) < 1e-8
            }()
            let isYCbCr444 = (fh.colorTransform == .yCbCr)
                && maxhs == 0 && maxvs == 0
            if isJPEGCompatibleRAW && isYCbCr444,
               let qtab = acDequantInfo.encodings[0].rawQtable {
                // Precompute `scaled_qtable[c*64 + s] = (1<<11) ×
                // qtab[64 + s] / qtab[64*c + s]` for `s` in JXL
                // transposed order. libjxl iterates `i` in JPEG
                // natural order and stores at transposed position
                // `(i%8)*8 + (i/8)` (`dec_group.cc:234-243`).
                // Substituting `s = (i%8)*8 + (i/8)` and using
                // the fact that our `qtab` is already stored in
                // JXL transposed order
                // (`qtab[c*64 + s] = qtable_libjxl[c*64 + transpose(s)]`),
                // the equation simplifies — both reads and writes
                // are at the same `s`, no extra transpose needed.
                //
                // **v0.12.0gz fix.** A previous draft kept the
                // extra transpose, which produced subtly-wrong
                // scaled_qtable entries. Invisible for small
                // fixtures where the JPEG Y AC is concentrated
                // at low frequencies, but pinned down at 128×128
                // (16 AC mismatches all on channel 2 at k=16 of
                // tile column 1).
                var scaledQtable = [Int32](repeating: 0, count: 3 * 64)
                for c in 0..<3 {
                    for s in 0..<64 {
                        let nVal = qtab[64 + s]       // Y channel
                        let dVal = qtab[64 * c + s]   // C channel
                        guard nVal > 0, dVal > 0 else { continue }
                        scaledQtable[64 * c + s] =
                            Int32(1 << kCFLFixedPointPrecision)
                            * nVal / dVal
                    }
                }
                // Look up the cmap entry for each block's color
                // tile (one tile = 8 blocks per side). For chroma
                // X (JXL channel 0) we use `ytoxMapFull`; for B
                // (JXL channel 2) we use `ytobMapFull`. Layout:
                // row-major over `acCmapWidth × acCmapHeight`.
                let kColorTileDimInBlocks = 8
                for c in [0, 2] {
                    let mapArr = (c == 0) ? ytoxMapFull : ytobMapFull
                    for by in 0..<totalBlocksY {
                        for bx in 0..<totalBlocksX {
                            let tx = bx / kColorTileDimInBlocks
                            let ty = by / kColorTileDimInBlocks
                            let tIdx = ty * acCmapWidth + tx
                            guard tIdx < mapArr.count else { continue }
                            let cmapEntry = mapArr[tIdx]
                            // libjxl `chroma_from_luma.h:68-70`:
                            //   RatioJPEG(f) = f * (1<<11) /
                            //                  kDefaultColorFactor
                            let scale = cmapEntry
                                * Int32(1 << kCFLFixedPointPrecision)
                                / kDefaultColorFactor
                            let blkIdx = by * totalBlocksX + bx
                            // Loop the 64 transposed positions
                            // 0..63 — same indexing as the C
                            // channel's slot in scaledQtable.
                            for i in 0..<64 {
                                let qt = scaledQtable[64 * c + i]
                                // coeff_scale = (qt·scale + round) >> 11
                                let coeffScale = (qt &* scale &+ halfRound)
                                    >> kCFLFixedPointPrecision
                                let yCoef = acInXYBOrder[1][blkIdx][i]
                                // cfl_factor =
                                //   (Y·coeff_scale + round) >> 11
                                let cflFactor = (yCoef &* coeffScale
                                    &+ halfRound)
                                    >> kCFLFixedPointPrecision
                                acInXYBOrder[c][blkIdx][i] &+= cflFactor
                            }
                        }
                    }
                }
            }
            // `blocksPerChannel` (bpc) carries the correct
            // per-channel dims; `acInXYBOrder[c]` was sampled at the
            // chroma grid above (v0.12.0hb), so each channel's plane
            // already has exactly `bpc[c]` blocks for subsampled
            // frames.
            let planes = JXLCoefficientPlanes(
                blocksX: totalBlocksX, blocksY: totalBlocksY,
                channelCount: 3,
                dcPerChannel: dcInXYBOrder,
                acPerChannel: acInXYBOrder,
                blocksPerChannel: bpc)
            // Capture the RAW slot 0 quant table + chroma / colour
            // info for the autonomous JPEG-reverse path. The qtable
            // is present whenever slot 0 is the JPEG-compatible RAW
            // table (independent of subsampling — CFL above is the
            // only 4:4:4-only part).
            let capturedQTable: [Int32]? =
                isJPEGCompatibleRAW
                ? acDequantInfo.encodings[0].rawQtable
                : nil
            let bridgeCT: JXLBridgeColorTransform =
                (fh.colorTransform == .yCbCr) ? .ycbcr : .none
            throw EarlyCoefficientCapture(
                planes: planes,
                rawQuantTable: capturedQTable,
                chromaSubsampling: fh.chromaSubsampling,
                bridgeColorTransform: bridgeCT,
                icc: frameICC)
        }
        if trace {
            for (bIdx, blockChannels) in acBlocks.enumerated() {
                let nzCounts = blockChannels.map {
                    $0.filter { $0 != 0 }.count
                }
                FileHandle.standardError.write(Data(
                    "TRACE ACBlock[block=\(bIdx)]: nz per iter = \(nzCounts)\n".utf8
                ))
            }
        }

        // (15) Bite 3 — Dequant + IDCT. libjxl
        // `dec_xyb.cc::DequantDC` + per-block AC dequant in
        // `dec_group.cc` + `IDCT2DInPlace`.
        //
        //     // Quantizer derived values:
        //     inv_global_scale = (1 << 16) / global_scale
        //     inv_quant_dc = inv_global_scale / quant_dc
        //     mul_dc[c] = inv_quant_dc * (1 / kInvDCQuant[c])    // per channel
        //     // DC apply:
        //     dc_amp[c] = quantized_dc[c] * mul_dc[c] * (1 / (1 << extra_precision))
        //     // AC apply (per coefficient k in natural order):
        //     ac_amp[c][k] = quantized_ac[c][k] * dequant_matrix[c][k] * inv_quant_ac(qf)
        //         where dequant_matrix[c][k] = 1 / quant_weights[c][k]
        //         and inv_quant_ac(qf) = inv_global_scale / qf
        //     // 8x8 IDCT per channel block.
        //
        // For our fixture: extra_precision=1, qf=5, ord=DCT8,
        // global_scale=5111, quant_dc=17. Three (8x8) pixel-domain
        // blocks emerge, still in XYB-encoded space (color correlation
        // and inverse XYB lands in Bite 4).
        let kGlobalScaleDenomF: Float = Float(1 << 16)
        let invGlobalScale: Float = kGlobalScaleDenomF / Float(qp.globalScale)
        let invQuantDC: Float = invGlobalScale / Float(qp.quantDC)
        // libjxl `quant_weights.h::kInvDCQuant`. Indexed by **XYB
        // channel** (X=0, Y=1, B=2).
        // `Quantizer::GetDcStep`: `inv_quant_dc * dequant.DCQuant(c)`, the
        // latter read by `DequantMatrices::DecodeDC` (default 1/4096,
        // 1/512, 1/256).
        let mulDC: [Float] = [
            invQuantDC * dcQuant.dcQuant.0,
            invQuantDC * dcQuant.dcQuant.1,
            invQuantDC * dcQuant.dcQuant.2,
        ]
        let dcExtraFactor: Float = 1.0 / Float(1 << dcExtraPrecision)

        // libjxl `dec_cache.h:161-162` — per-channel AC-dequant
        // multiplier driven by frame-header qm_scale. Y is unscaled;
        // X and B get `pow(1/1.25, qm_scale - 2.0)`. Default
        // qm_scale=3 → multiplier = 0.8.
        let xDmMultiplier: Float = powf(
            1.0 / 1.25, Float(fh.xQmScale) - 2.0
        )
        let bDmMultiplier: Float = powf(
            1.0 / 1.25, Float(fh.bQmScale) - 2.0
        )
        if trace {
            FileHandle.standardError.write(Data(
                "TRACE qm_scale: x=\(fh.xQmScale) (mul=\(xDmMultiplier)) b=\(fh.bQmScale) (mul=\(bDmMultiplier))\n".utf8
            ))
        }

        // Channel layout — libjxl swaps storage:
        //
        //   image.channel[c < 2 ? c ^ 1 : c]  for XYB c ∈ {0=X, 1=Y, 2=B}
        //
        // ⇒ storage slot 0 holds Y, slot 1 holds X, slot 2 holds B.
        //
        //   storageToXYB[storage_slot] = XYB channel index
        //
        // For DC, channels were decoded in storage order (slot 0 → 2),
        // so `dcValues[i]` lives at `storageToXYB[i]` in the XYB tables.
        //
        // For AC, libjxl's `LoadBlock` iterates STORAGE c ∈ {1, 0, 2}
        // (i.e., storage X, then Y, then B — the storage swap puts
        // X at slot 1, Y at slot 0). The AC decode loop above adopts
        // this iteration order via the same `[1, 0, 2]` table so that
        // `iterIdx` lines up directly with the XYB channel index
        // (iter 0 = X, iter 1 = Y, iter 2 = B). `acBlocks[blkIdx][i]`
        // is therefore indexed by XYB channel directly.
        // `dcFloat` is built directly from this storage swap
        // (`dcValues[1]`=X, `[0]`=Y, `[2]`=B).
        let acIterToXYB: [Int] = [0, 1, 2]

        // ACMeta channel 2 shape = `count × 2` (row 0 = ACS values,
        // row 1 = QF values). Flat indices: [ACS_0..ACS_{n-1},
        // QF_0..QF_{n-1}]. Per-block `qf` per libjxl
        // `dec_modular.cc::DecodeAcMetadata`:
        //
        //     row_qf[ix] = 1 + clamp(row_in_2[num], 0, kQuantMax - 1)
        //
        // For our 8×8 fixture: count=1, ACS=[0], QF=[4] → qfPerBlock=[5].
        // For 16×16: count=4, QF=[5,5,6,5] → qfPerBlock=[6,6,7,6].
        // (perBlockQF + qfRow extracted earlier so the AC decode loop
        // can compute proper block_ctx routing for multi-cluster
        // fixtures.)
        _ = perBlockQF.count    // explicit reference, keeps tooling happy
        _ = qfRow               // ditto

        // DCT8 default quant weights: 3 × 64 floats. `qweights[c*64+k]`
        // is the QUANT weight (libjxl stores its inverse in `Matrix()`,
        // so `dequant_matrix = 1 / qweights`). Indexed by XYB channel.
        // libjxl's LIBRARY-default quant matrices use the raw band
        // seeds directly (no ×64). The ×64 in `DecodeDctParams`
        // applies only to *bitstream-decoded* custom DCT params, not
        // the library defaults — verified against an instrumented
        // djxl 0.11.2 (`dequant_matrix[Y][0] = 1/560`, not 1/35840).
        let dct8Bands = DefaultQuantBands.dct8x8
        let qweights: [Float]
        do {
            qweights = try quantTable(slot: 0) {
                try QuantWeights.getQuantWeights(rows: 8, cols: 8, bands: dct8Bands)
            }
        } catch let e as QuantWeightsError {
            throw DecoderError.notImplemented(
                "VarDCT decode: DCT8 quant weights computation failed: \(e)"
            )
        }

        // Multi-block dequant + IDCT + plane assembly. libjxl applies
        // CFL **at the coefficient level**, with DIFFERENT factors for
        // DC vs AC:
        //   • DC pixel: `cfl_dc_b = ytoBRatio(cmap.ytobDC)` (typically
        //     1.0 + 0/84 = 1 for default ColorCorrelation).
        //   • AC coefs: `cfl_ac_b = ytoBRatio(ytob_map[tile])` (depends
        //     on the per-color-tile slope from ACMeta channel 1).
        // We mirror that: DC pixel gets DC-CFL baked in, AC coefs get
        // AC-CFL baked in BEFORE the IDCT. After IDCT no further CFL
        // is applied.
        let dcCflX = cmapDC.ytoXRatio(slope: cmapDC.ytoxDC)
        let dcCflB = cmapDC.ytoBRatio(slope: cmapDC.ytobDC)
        // AC CFL slopes are stored **per 64×64-pixel colour tile** in
        // ACMeta channels 0 (YToX) and 1 (YToB), assembled across all
        // DC groups into `ytoxMapFull` / `ytobMapFull`. A colour tile
        // spans `kColorTileDimInBlocks` (= 8) blocks each way, so the
        // 8×8 block at (bx,by) belongs to tile (bx/8, by/8). libjxl
        // `dec_group.cc:273-301` indexes the map row-major by tile.
        let ytoxMapAC = ytoxMapFull
        let ytobMapAC = ytobMapFull
        // Per-block AC CFL multipliers — looked up at the block's
        // colour tile. Replaces the earlier single-tile `.first`
        // shortcut, which only held for frames ≤ 64 px (one tile).
        @inline(__always)
        func acCFLMul(bx: Int, by: Int) -> (x: Float, b: Float) {
            let tileX = min(bx / kColorTileDimInBlocks, acCmapWidth - 1)
            let tileY = min(by / kColorTileDimInBlocks, acCmapHeight - 1)
            let idx = tileY * acCmapWidth + tileX
            let xSlope = idx < ytoxMapAC.count ? ytoxMapAC[idx] : 0
            let bSlope = idx < ytobMapAC.count ? ytobMapAC[idx] : 0
            return (cmapDC.ytoXRatio(slope: xSlope),
                    cmapDC.ytoBRatio(slope: bSlope))
        }
        if trace {
            let cflMsg = "TRACE CFL: dc=(x=\(dcCflX), b=\(dcCflB)) "
                + "ac maps \(acCmapWidth)×\(acCmapHeight) "
                + "ytox=\(ytoxMapAC) ytob=\(ytobMapAC) "
                + "(dc slopes=(\(cmapDC.ytoxDC),\(cmapDC.ytobDC)))\n"
            FileHandle.standardError.write(Data(cflMsg.utf8))
        }

        // Full-frame dequantised + DC-CfL DC plane (libjxl
        // `compressed_dc.cc::DequantDC`). `dcValues` is in storage
        // order {Y, X, B}; `dcFloat` is XYB-indexed. Then — unless
        // the frame opts out — adaptive DC smoothing runs here, which
        // libjxl does in `FinalizeDC` between DC-group and AC-group
        // decode. Skipping it leaves a low-frequency drift that
        // shifts every multi-block transform's `LowestFrequenciesFromDC`.
        var dcFloat: [[Float]] = (0..<3).map { _ in
            [Float](repeating: 0, count: dcWidth * dcHeight)
        }
        if let dc = dcFrame {
            // `PassesSharedState::dc` points at `dc_frames[dc_level]`:
            // the DC frame's XYB samples are the DC values as decoded,
            // no CfL and no adaptive smoothing.
            guard dc[0].count == dcWidth * dcHeight, dc[1].count == dc[0].count,
                  dc[2].count == dc[0].count else {
                throw DecoderError.notImplemented(
                    "VarDCT decode: DC frame is \(dc[0].count) samples, the frame "
                    + "needs \(dcWidth)x\(dcHeight)")
            }
            dcFloat = dc
        }
        // Read each channel's quantised DC at its (possibly
        // subsampled) plane resolution and nearest-neighbour
        // upsample into the full-resolution `dcFloat`. dcValues is
        // storage order [Y, X, B]; for 4:4:4 the per-channel index
        // collapses to `idx`. (The full pixel path's chroma
        // upsampling is nearest-neighbour only — proper subsampled
        // pixel reconstruction is out of scope; the in-scope
        // `decodeToCoefficients` path returns before reaching here.)
        for y in 0..<dcHeight where dcFrame == nil {
            for x in 0..<dcWidth {
                let idx = y * dcWidth + x
                let yIdx = (y >> dcChanVShift[0]) * dcChanWidth[0]
                    + (x >> dcChanHShift[0])
                let xIdx = (y >> dcChanVShift[1]) * dcChanWidth[1]
                    + (x >> dcChanHShift[1])
                let bIdx = (y >> dcChanVShift[2]) * dcChanWidth[2]
                    + (x >> dcChanHShift[2])
                let inX = Float(dcValues[1][xIdx]) * mulDC[0] * dcExtraFactor
                let inY = Float(dcValues[0][yIdx]) * mulDC[1] * dcExtraFactor
                let inB = Float(dcValues[2][bIdx]) * mulDC[2] * dcExtraFactor
                dcFloat[1][idx] = inY
                dcFloat[0][idx] = inX + dcCflX * inY
                dcFloat[2][idx] = inB + dcCflB * inY
            }
        }
        // `kSkipAdaptiveDCSmoothing` is frame-flag bit 7 (128);
        // `kUseDcFrame` is bit 5 (32) and also implies skip.
        if (fh.flags & 128) == 0 && (fh.flags & 32) == 0 {
            AdaptiveDCSmoothing.apply(
                dc: &dcFloat, width: dcWidth, height: dcHeight,
                dcFactors: mulDC)
        }

        let planeWidth = numBlocksXAC * 8
        let planeHeight = numBlocksYAC * 8
        var inverseDCT8 = AccelerateDCT.InverseTransform(size: 8)
        // Separate planes avoid nested Array mutation/uniqueness checks for every output sample.
        var paddedX = [Float](repeating: 0, count: planeWidth * planeHeight)
        var paddedY = [Float](repeating: 0, count: planeWidth * planeHeight)
        var paddedB = [Float](repeating: 0, count: planeWidth * planeHeight)

        for by in 0..<numBlocksYAC {
            for bx in 0..<numBlocksXAC {
                let blockIdx = by * numBlocksXAC + bx
                // AC CFL multipliers for this cell's colour tile.
                let (xCCMul, bCCMul) = acCFLMul(bx: bx, by: by)
                // v0.9.0h: dump first block's quantised AC values for
                // diagnostic vs djxl. Triggered by JXL_TRACE_AC env var.
                if blockIdx == 0,
                   ProcessInfo.processInfo.environment["JXL_TRACE_AC"] != nil {
                    let labels = ["X", "Y", "B"]
                    for c in 0..<3 {
                        let xybC = c
                        let storageSlot = [1, 0, 2][xybC]
                        _ = storageSlot
                        // Print first row (flat 0..7 = vanilla [0, 0..7]) and
                        // first column (flat 0, 8, 16, ..., 56 = vanilla
                        // [0..7, 0]).
                        let row0 = (0..<8).map {
                            "\(acBlocks[0][c][$0])"
                        }.joined(separator: ",")
                        let col0 = (0..<8).map {
                            "\(acBlocks[0][c][$0 * 8])"
                        }.joined(separator: ",")
                        FileHandle.standardError.write(Data(
                            "TRACE_AC blk0 c=\(c) (\(labels[c])) row0=[\(row0)] col0=[\(col0)]\n".utf8
                        ))
                    }
                    FileHandle.standardError.write(Data(
                        "TRACE_AC blk0 dc=(\(dcValues[0][0]), \(dcValues[1][0]), \(dcValues[2][0])) qf=\(blockIdx < perBlockQF.count ? perBlockQF[blockIdx] : qfRow) globalScale=\(qp.globalScale)\n".utf8
                    ))
                }
                // Other implemented strategies write their complete regions below. Do not first
                // reconstruct DCT8 pixels that would immediately be overwritten by those regions.
                // Keep the existing DC-only fallback for the unsupported large strategies.
                switch acsImage.at(x: bx, y: by).strategy {
                case .dct8x8, .dct128x128, .dct128x64, .dct64x128, .dct256x256, .dct256x128, .dct128x256:
                    break
                default:
                    continue
                }
                // Per-block invQuantAC from this block's QF.
                let blockQF = blockIdx < perBlockQF.count
                    ? perBlockQF[blockIdx] : qfRow
                let blockInvQuantAC = invGlobalScale / Float(blockQF)
                // 1-2) DC pixel — dequantised + DC-CfL + smoothed,
                // read straight from the prepared `dcFloat` plane.
                let dcY = dcFloat[1][by * dcWidth + bx]
                let dcCorrectedX = dcFloat[0][by * dcWidth + bx]
                let dcCorrectedB = dcFloat[2][by * dcWidth + bx]

                // 3) Locate iteration indices for each XYB channel.
                guard
                    let iterX = acIterToXYB.firstIndex(of: 0),
                    let iterY = acIterToXYB.firstIndex(of: 1),
                    let iterB = acIterToXYB.firstIndex(of: 2)
                else {
                    throw DecoderError.notImplemented(
                        "VarDCT decode: AC iter mapping incomplete"
                    )
                }
                let acYBlock = acBlocks[blockIdx][iterY]
                let acXBlock = acBlocks[blockIdx][iterX]
                let acBBlock = acBlocks[blockIdx][iterB]

                // 4) Build coefBlocks with DC at position 0, AC-CFL'd
                //    AC coefs at positions 1..63.
                var coefY = [Float](repeating: 0, count: 64)
                var coefX = [Float](repeating: 0, count: 64)
                var coefB = [Float](repeating: 0, count: 64)
                coefY[0] = dcY
                coefX[0] = dcCorrectedX
                coefB[0] = dcCorrectedB
                VarDCTReconstruction.dequantizeAC(
                    x: acXBlock, y: acYBlock, b: acBBlock, weights: qweights, scale: blockInvQuantAC,
                    xScale: xDmMultiplier, bScale: bDmMultiplier, xFromY: xCCMul, bFromY: bCCMul,
                    columns: 8, llfRows: 1, llfColumns: 1,
                    outputX: &coefX, outputY: &coefY, outputB: &coefB)
                // v0.9.0i: dump dequantised first-block AC values
                // (post-formula, pre-IDCT) for diagnostic.
                if blockIdx == 0,
                   ProcessInfo.processInfo.environment["JXL_TRACE_AC"] != nil {
                    let labels = ["X", "Y", "B"]
                    for (label, buf) in zip(labels, [coefX, coefY, coefB]) {
                        let preview = (0..<8).map {
                            String(format: "%.5f", buf[$0])
                        }.joined(separator: ",")
                        FileHandle.standardError.write(Data(
                            "TRACE_AC blk0 \(label) DEQUANT first8=[\(preview)]\n".utf8
                        ))
                    }
                    let qwy = qweights[1 * 64 + 1]
                    let qwx = qweights[0 * 64 + 1]
                    let qwb = qweights[2 * 64 + 1]
                    FileHandle.standardError.write(Data(
                        "TRACE_AC qweights[0,1] (X,Y,B)=(\(qwx), \(qwy), \(qwb)) blockInvQuantAC=\(blockInvQuantAC) xDmMul=\(xDmMultiplier) bDmMul=\(bDmMultiplier)\n".utf8
                    ))
                }
                // 5) libjxl-convention IDCT. libjxl's encoder
                //    `ComputeScaledDCT<8,8>` emits coefficients in
                //    TRANSPOSED layout (it omits the final transpose
                //    for ROWS≥COLS strategies). Our `idct2D` is the
                //    untransposed `IDCTSlow`, so undo the transpose
                //    on the coefficient block first —
                //    `ComputeScaledIDCT(C) = IDCTSlow(Cᵀ)`.
                JXLDecoder.transposeSquareInPlace(&coefY, size: 8)
                JXLDecoder.transposeSquareInPlace(&coefX, size: 8)
                JXLDecoder.transposeSquareInPlace(&coefB, size: 8)
                inverseDCT8.apply(&coefY)
                inverseDCT8.apply(&coefX)
                inverseDCT8.apply(&coefB)
                // 6) Place 8×8 patches at (bx*8, by*8) in each plane.
                let xOrigin = bx * 8
                let yOrigin = by * 8
                VarDCTReconstruction.writeBlock(coefX, to: &paddedX, width: 8, height: 8,
                    sourceStride: 8, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                VarDCTReconstruction.writeBlock(coefY, to: &paddedY, width: 8, height: 8,
                    sourceStride: 8, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                VarDCTReconstruction.writeBlock(coefB, to: &paddedB, width: 8, height: 8,
                    sourceStride: 8, outputStride: planeWidth, x: xOrigin, y: yOrigin)
            }
        }

        // Single-8×8-cell special-strategy overlay — IDENTITY
        // ("hornuss"), DCT2X2, DCT4X4. Each dequantises the 8×8
        // block with its own LIBRARY-default quant matrix, then
        // applies its spatial transform. None involves an 8×8 DCT,
        // so no top-level transpose (DCT4X4 transposes its 4×4
        // quadrants internally).
        let identityQweights = try quantTable(slot: 1) {
            QuantWeights.getIdentityQuantWeights(DefaultQuantBands.identity)
        }
        let dct2Qweights = try quantTable(slot: 2) {
            QuantWeights.getDCT2QuantWeights(DefaultQuantBands.dct2x2)
        }
        let dct4Qweights: [Float]
        let dct4x8Qweights: [Float]
        do {
            dct4Qweights = try quantTable(slot: 3) {
                try QuantWeights.getDCT4QuantWeights(bands: DefaultQuantBands.dct4x4)
            }
            dct4x8Qweights = try quantTable(slot: 9) {
                try QuantWeights.getDCT4X8QuantWeights(bands: DefaultQuantBands.dct4x8)
            }
        } catch {
            throw DecoderError.notImplemented(
                "VarDCT decode: DCT4X4/DCT4X8 quant weights failed: \(error)"
            )
        }
        for by in 0..<numBlocksYAC {
            for bx in 0..<numBlocksXAC {
                let entry = acsImage.at(x: bx, y: by)
                guard entry.isFirstBlock else { continue }
                let qw: [Float]
                let transform: ([Float]) -> [Float]
                switch entry.strategy {
                case .hornuss:
                    qw = identityQweights
                    transform = IdentityTransform.transformToPixels
                case .dct2x2:
                    qw = dct2Qweights
                    transform = DCT2x2Transform.transformToPixels
                case .dct4x4:
                    qw = dct4Qweights
                    transform = DCT4x4Transform.transformToPixels
                case .dct4x8:
                    qw = dct4x8Qweights
                    transform = DCT4x8Transform.transformToPixels
                case .dct8x4:
                    qw = dct4x8Qweights
                    transform = DCT8x4Transform.transformToPixels
                default:
                    continue
                }
                let blockIdx = by * totalBlocksX + bx
                let blockQF = blockIdx < perBlockQF.count
                    ? perBlockQF[blockIdx] : qfRow
                let blockInvQuantAC = invGlobalScale / Float(blockQF)
                let (xCCMul, bCCMul) = acCFLMul(bx: bx, by: by)
                // DC pixel — dequantised + DC-CfL + smoothed.
                let dcY = dcFloat[1][by * dcWidth + bx]
                let dcX = dcFloat[0][by * dcWidth + bx]
                let dcB = dcFloat[2][by * dcWidth + bx]
                // `acBlocks` is XYB-indexed (slot 0=X, 1=Y, 2=B).
                let acXBlock = acBlocks[blockIdx][0]
                let acYBlock = acBlocks[blockIdx][1]
                let acBBlock = acBlocks[blockIdx][2]
                var coefY = [Float](repeating: 0, count: 64)
                var coefX = [Float](repeating: 0, count: 64)
                var coefB = [Float](repeating: 0, count: 64)
                coefY[0] = dcY; coefX[0] = dcX; coefB[0] = dcB
                for np in 1..<64 {
                    let acYDeq = AdjustQuantBias.adjust(
                        channel: 1, quant: acYBlock[np]
                    ) / qw[1 * 64 + np] * blockInvQuantAC
                    let acXDeq = AdjustQuantBias.adjust(
                        channel: 0, quant: acXBlock[np]
                    ) / qw[0 * 64 + np] * blockInvQuantAC
                        * xDmMultiplier
                    let acBDeq = AdjustQuantBias.adjust(
                        channel: 2, quant: acBBlock[np]
                    ) / qw[2 * 64 + np] * blockInvQuantAC
                        * bDmMultiplier
                    coefY[np] = acYDeq
                    coefX[np] = acXDeq + xCCMul * acYDeq
                    coefB[np] = acBDeq + bCCMul * acYDeq
                }
                let pixX = transform(coefX)
                let pixY = transform(coefY)
                let pixB = transform(coefB)
                let xOrigin = bx * 8
                let yOrigin = by * 8
                VarDCTReconstruction.writeBlock(pixX, to: &paddedX, width: 8, height: 8,
                    sourceStride: 8, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                VarDCTReconstruction.writeBlock(pixY, to: &paddedY, width: 8, height: 8,
                    sourceStride: 8, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                VarDCTReconstruction.writeBlock(pixB, to: &paddedB, width: 8, height: 8,
                    sourceStride: 8, outputStride: planeWidth, x: xOrigin, y: yOrigin)
            }
        }

        // Per-strategy IDCT overlay pass. Iterates over first-blocks
        // and OVERWRITES the per-cell-DCT8 fallback output with the
        // proper per-strategy IDCT for the strategies we now ship
        // natively (currently DCT16x16; next bites add 32x32, 4x8/8x4,
        // 16x8/8x16, etc.). Solid-colour content (all-zero AC) was
        // already correct from the per-cell pass; the overlay just
        // handles textured content.
        let dct16Bands = DefaultQuantBands.dct16x16
        let qweights16: [Float]
        do {
            qweights16 = try quantTable(slot: 4) {
                try QuantWeights.getQuantWeights(rows: 16, cols: 16, bands: dct16Bands)
            }
        } catch {
            throw DecoderError.notImplemented(
                "VarDCT decode: DCT16x16 quant weights computation failed: \(error)"
            )
        }
        guard
            let iterX16 = acIterToXYB.firstIndex(of: 0),
            let iterY16 = acIterToXYB.firstIndex(of: 1),
            let iterB16 = acIterToXYB.firstIndex(of: 2)
        else {
            throw DecoderError.notImplemented(
                "VarDCT decode: AC iter mapping incomplete (DCT16x16 pass)"
            )
        }
        for by in 0..<numBlocksYAC {
            for bx in 0..<numBlocksXAC {
                let entry = acsImage.at(x: bx, y: by)
                if !entry.isFirstBlock { continue }
                if entry.strategy != .dct16x16 { continue }
                guard bx + 1 < numBlocksXAC, by + 1 < numBlocksYAC else {
                    continue  // safety net; ACStrategyImage.build already
                              // rejects overflowing strategies.
                }
                // Per-block QF (every covered cell shares the
                // first-block's QF — the per-cell perBlockQF entry
                // was set when ACMeta was decoded).
                let blockIdxFirst = by * totalBlocksX + bx
                let blockQF = blockIdxFirst < perBlockQF.count
                    ? perBlockQF[blockIdxFirst] : qfRow
                let blockInvQuantAC = invGlobalScale / Float(blockQF)
                let (xCCMul, bCCMul) = acCFLMul(bx: bx, by: by)
                // Per channel: build the 256-entry coefficient block,
                // dequant + bridge + IDCT, then place into the plane.
                var coefX = [Float](repeating: 0, count: 256)
                var coefY = [Float](repeating: 0, count: 256)
                var coefB = [Float](repeating: 0, count: 256)
                // Cell DC values (4 cells × 3 channels in pixel space,
                // already DC-CFL'd later — here we apply DC-CFL
                // ourselves since the per-cell loop handled CFL on
                // its 8×8 patches but we need it on the LLF coefs).
                let cellOffsets = [
                    (0, 0), (1, 0), (0, 1), (1, 1)
                ]
                var dcX = [Float](repeating: 0, count: 4)
                var dcY = [Float](repeating: 0, count: 4)
                var dcB = [Float](repeating: 0, count: 4)
                for (i, off) in cellOffsets.enumerated() {
                    let (dx, dy) = off
                    let cIdx = (by + dy) * dcWidth + (bx + dx)
                    dcX[i] = dcFloat[0][cIdx]
                    dcY[i] = dcFloat[1][cIdx]
                    dcB[i] = dcFloat[2][cIdx]
                }
                // LLF coefficients per channel via 2×2 forward DCT +
                // resample scaling. Map to natural-order positions
                // 0, 1, 16, 17 of the 16×16 coef grid.
                let llfX = LowestFrequenciesFromDC.dct16x16(dc: dcX)
                let llfY = LowestFrequenciesFromDC.dct16x16(dc: dcY)
                let llfB = LowestFrequenciesFromDC.dct16x16(dc: dcB)
                let llfPositions = [0, 1, 16, 17]
                for (i, pos) in llfPositions.enumerated() {
                    coefX[pos] = llfX[i]
                    coefY[pos] = llfY[i]
                    coefB[pos] = llfB[i]
                }
                // AC coefficients per channel: dequant via DCT16x16
                // quant matrix + AC-CFL. AC tokens were stored in
                // natural-order layout already (decodeBlock writes
                // to block[order[k]]) so we iterate natural positions
                // directly — only the LLF positions (filled above)
                // are skipped.
                let acYBlock = acBlocks[blockIdxFirst][iterY16]
                let acXBlock = acBlocks[blockIdxFirst][iterX16]
                let acBBlock = acBlocks[blockIdxFirst][iterB16]
                VarDCTReconstruction.dequantizeAC(
                    x: acXBlock, y: acYBlock, b: acBBlock, weights: qweights16, scale: blockInvQuantAC,
                    xScale: xDmMultiplier, bScale: bDmMultiplier, xFromY: xCCMul, bFromY: bCCMul,
                    columns: 16, llfRows: 2, llfColumns: 2,
                    outputX: &coefX, outputY: &coefY, outputB: &coefB)
                // libjxl-convention IDCT — `ComputeScaledIDCT<16,16>`
                // = `IDCTSlow(coefᵀ)` for the ROWS≥COLS (square) case.
                JXLDecoder.transposeSquareInPlace(&coefX, size: 16)
                JXLDecoder.transposeSquareInPlace(&coefY, size: 16)
                JXLDecoder.transposeSquareInPlace(&coefB, size: 16)
                AccelerateDCT.idct2D(&coefX, size: 16)
                AccelerateDCT.idct2D(&coefY, size: 16)
                AccelerateDCT.idct2D(&coefB, size: 16)
                // Place 16×16 patch at (bx*8, by*8).
                let xOrigin = bx * 8
                let yOrigin = by * 8
                VarDCTReconstruction.writeBlock(coefX, to: &paddedX, width: 16, height: 16,
                    sourceStride: 16, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                VarDCTReconstruction.writeBlock(coefY, to: &paddedY, width: 16, height: 16,
                    sourceStride: 16, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                VarDCTReconstruction.writeBlock(coefB, to: &paddedB, width: 16, height: 16,
                    sourceStride: 16, outputStride: planeWidth, x: xOrigin, y: yOrigin)
            }
        }

        // DCT16x8 / DCT8x16 IDCT overlay (libjxl ord 4). Both share
        // the same 16×8 coefficient layout (after `CoefficientLayout`
        // swap), the same `dct8x16` quant matrix, the same √128
        // bridge factor, and the same 2-coef LLF region. The only
        // difference is pixel placement: DCT8x16 outputs 16w × 8h
        // pixels (matches coef layout), DCT16x8 outputs 8w × 16h
        // pixels (transposed from coef layout).
        let dct8x16Bands = DefaultQuantBands.dct8x16
        let qweights8x16: [Float]
        do {
            qweights8x16 = try quantTable(slot: 6) {
                try QuantWeights.getQuantWeights(rows: 8, cols: 16, bands: dct8x16Bands)
            }
        } catch {
            throw DecoderError.notImplemented(
                "VarDCT decode: DCT8x16 quant weights computation failed: \(error)"
            )
        }
        for by in 0..<numBlocksYAC {
            for bx in 0..<numBlocksXAC {
                let entry = acsImage.at(x: bx, y: by)
                if !entry.isFirstBlock { continue }
                if entry.strategy != .dct8x16 && entry.strategy != .dct16x8 {
                    continue
                }
                let isVerticalStack = entry.strategy == .dct16x8  // 8w×16h
                let cellsX = isVerticalStack ? 1 : 2
                let cellsY = isVerticalStack ? 2 : 1
                guard bx + cellsX <= numBlocksXAC,
                      by + cellsY <= numBlocksYAC
                else { continue }
                let blockIdxFirst = by * totalBlocksX + bx
                let blockQF = blockIdxFirst < perBlockQF.count
                    ? perBlockQF[blockIdxFirst] : qfRow
                let blockInvQuantAC = invGlobalScale / Float(blockQF)
                let (xCCMul, bCCMul) = acCFLMul(bx: bx, by: by)
                // Per-channel coef block (128 entries in 8-row × 16-col
                // layout).
                var coefX = [Float](repeating: 0, count: 128)
                var coefY = [Float](repeating: 0, count: 128)
                var coefB = [Float](repeating: 0, count: 128)
                // Cell DC values + DC-CFL.
                let cellOffsets: [(Int, Int)] = isVerticalStack
                    ? [(0, 0), (0, 1)]   // DCT16x8: cells (bx,by), (bx,by+1)
                    : [(0, 0), (1, 0)]   // DCT8x16: cells (bx,by), (bx+1,by)
                var dcX = [Float](repeating: 0, count: 2)
                var dcY = [Float](repeating: 0, count: 2)
                var dcB = [Float](repeating: 0, count: 2)
                for (i, off) in cellOffsets.enumerated() {
                    let (dx, dy) = off
                    let cIdx = (by + dy) * dcWidth + (bx + dx)
                    dcX[i] = dcFloat[0][cIdx]
                    dcY[i] = dcFloat[1][cIdx]
                    dcB[i] = dcFloat[2][cIdx]
                }
                // 2 LLF coefficients per channel at natural-order
                // positions 0 and 1.
                let llfX = LowestFrequenciesFromDC.ord4Pair(dc: dcX)
                let llfY = LowestFrequenciesFromDC.ord4Pair(dc: dcY)
                let llfB = LowestFrequenciesFromDC.ord4Pair(dc: dcB)
                coefX[0] = llfX[0]; coefX[1] = llfX[1]
                coefY[0] = llfY[0]; coefY[1] = llfY[1]
                coefB[0] = llfB[0]; coefB[1] = llfB[1]
                // AC coefficients: dequant via DCT8x16 quant matrix
                // (8 rows × 16 cols layout) + AC-CFL.
                // iter index = XYB index (post v0.8.0e fix).
                let acYBlock = acBlocks[blockIdxFirst][1]
                let acXBlock = acBlocks[blockIdxFirst][0]
                let acBBlock = acBlocks[blockIdxFirst][2]
                for np in 2..<128 {
                    let acYDeq = AdjustQuantBias.adjust(
                        channel: 1, quant: acYBlock[np]
                    ) / qweights8x16[1 * 128 + np] * blockInvQuantAC
                    let acXDeq = AdjustQuantBias.adjust(
                        channel: 0, quant: acXBlock[np]
                    ) / qweights8x16[0 * 128 + np] * blockInvQuantAC
                        * xDmMultiplier
                    let acBDeq = AdjustQuantBias.adjust(
                        channel: 2, quant: acBBlock[np]
                    ) / qweights8x16[2 * 128 + np] * blockInvQuantAC
                        * bDmMultiplier
                    coefY[np] = acYDeq
                    coefX[np] = acXDeq + xCCMul * acYDeq
                    coefB[np] = acBDeq + bCCMul * acYDeq
                }
                // libjxl-convention IDCT (replaces bridge×√128 + ortho IDCT).
                // Coef layout is 8 rows × 16 cols (after CoefficientLayout swap).
                AccelerateDCT.idct2D(&coefX, rows: 8, cols: 16)
                AccelerateDCT.idct2D(&coefY, rows: 8, cols: 16)
                AccelerateDCT.idct2D(&coefB, rows: 8, cols: 16)
                // Place pixels. DCT8x16: 16w × 8h direct.
                // DCT16x8: 8w × 16h, transposed from the 16w × 8h
                // IDCT output (pixel[y][x] = coef_pix[x][y]).
                let xOrigin = bx * 8
                let yOrigin = by * 8
                if isVerticalStack {
                    // DCT16x8: 8 wide × 16 tall pixels.
                    for py in 0..<16 {
                        let dstRow = (yOrigin + py) * planeWidth + xOrigin
                        for px in 0..<8 {
                            // Transpose: coef layout (px=col, py=row)
                            // becomes pixel layout (py, px).
                            let srcIdx = px * 16 + py
                            paddedX[dstRow + px] = coefX[srcIdx]
                            paddedY[dstRow + px] = coefY[srcIdx]
                            paddedB[dstRow + px] = coefB[srcIdx]
                        }
                    }
                } else {
                    // DCT8x16: 16 wide × 8 tall pixels.
                    VarDCTReconstruction.writeBlock(coefX, to: &paddedX, width: 16, height: 8,
                        sourceStride: 16, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                    VarDCTReconstruction.writeBlock(coefY, to: &paddedY, width: 16, height: 8,
                        sourceStride: 16, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                    VarDCTReconstruction.writeBlock(coefB, to: &paddedB, width: 16, height: 8,
                        sourceStride: 16, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                }
            }
        }

        // DCT32x16 / DCT16x32 IDCT overlay (libjxl ord 6). Same
        // template as DCT16x8/DCT8x16 but on a 32×16 coef layout
        // with 8 LLF coefficients (4 cols × 2 rows in coef space).
        let dct16x32Bands = DefaultQuantBands.dct16x32
        let qweights16x32: [Float]
        do {
            qweights16x32 = try quantTable(slot: 8) {
                try QuantWeights.getQuantWeights(rows: 16, cols: 32, bands: dct16x32Bands)
            }
        } catch {
            throw DecoderError.notImplemented(
                "VarDCT decode: DCT16x32 quant weights computation failed: \(error)"
            )
        }
        for by in 0..<numBlocksYAC {
            for bx in 0..<numBlocksXAC {
                let entry = acsImage.at(x: bx, y: by)
                if !entry.isFirstBlock { continue }
                if entry.strategy != .dct32x16 && entry.strategy != .dct16x32 {
                    continue
                }
                let isVerticalStack = entry.strategy == .dct32x16  // 16w×32h
                let cellsX = isVerticalStack ? 2 : 4
                let cellsY = isVerticalStack ? 4 : 2
                guard bx + cellsX <= numBlocksXAC,
                      by + cellsY <= numBlocksYAC
                else { continue }
                let blockIdxFirst = by * totalBlocksX + bx
                let blockQF = blockIdxFirst < perBlockQF.count
                    ? perBlockQF[blockIdxFirst] : qfRow
                let blockInvQuantAC = invGlobalScale / Float(blockQF)
                let (xCCMul, bCCMul) = acCFLMul(bx: bx, by: by)
                // Per-channel coef block (32 cols × 16 rows = 512).
                var coefX = [Float](repeating: 0, count: 512)
                var coefY = [Float](repeating: 0, count: 512)
                var coefB = [Float](repeating: 0, count: 512)
                // 8 cell DC values + DC-CFL. Coef-layout order is
                // 4 cols × 2 rows (cx=4, cy=2 after CoefficientLayout).
                // For DCT32x16 (cellsX=2, cellsY=4): the coef layout
                // (4 cols × 2 rows) is the TRANSPOSE of the 2-col × 4-
                // row pixel-cell layout. We want dc[r * 4 + c] in
                // coef-layout = cell at pixel-cell (c'=r, r'=c) where
                // (c', r') indexes into the original 2×4 grid. So:
                //     dc[0..3] = (0,0), (1,0), (0,1), (1,1) of pix
                //     wait that's wrong. Let me think again.
                // Actually, libjxl's `dc_stride` is the DC plane
                // stride. For DCT32x16, the DC values it reads are:
                //   dc(bx + cx, by + cy) for cx in 0..covered_x=2,
                //                            cy in 0..covered_y=4.
                // In libjxl's input to ComputeScaledDCT<4, 2>, this
                // is laid out as 4 ROWS (cy=0..4) × 2 COLS (cx=0..2),
                // with stride dc_stride. So input[row, col] =
                // dc(bx+col, by+row).
                // Our `ord6Block` expects 4 cols × 2 rows row-major
                // (which is the COEF-layout transpose of input).
                // So we need: out[r * 4 + c] = input[c, r] = dc(bx+r, by+c).
                // For DCT32x16: out[r * 4 + c] = dc(bx + r, by + c)
                //   r in 0..2 (coef rows), c in 0..4 (coef cols).
                // Wait, ord6Block expects out[2 rows × 4 cols], so
                // r in 0..2, c in 0..4. And out[r * 4 + c] = ?
                // For DCT32x16 (cellsX=2, cellsY=4 in pix; covered_x=2,
                // covered_y=4): cells at (bx+cx, by+cy) for cx ∈ [0,2),
                // cy ∈ [0,4). After CoefficientLayout (cx_coef >=
                // cy_coef), the coef layout is cx_coef=4, cy_coef=2,
                // and the coef rows correspond to PIXEL cell rows
                // SWAPPED. The input to ord6Block is row-major in
                // COEF layout; for DCT32x16, that means:
                //   coef_row r ↔ pixel cell column r (cx=r)
                //   coef_col c ↔ pixel cell row c   (cy=c)
                //   ord6Block input[r * 4 + c] = dc(bx + r, by + c)
                // For DCT16x32 (cellsX=4, cellsY=2): coef layout is
                // ALREADY the same as pixel layout (cx_coef=4, cy_coef=2).
                //   ord6Block input[r * 4 + c] = dc(bx + c, by + r)
                var dcX = [Float](repeating: 0, count: 8)
                var dcY = [Float](repeating: 0, count: 8)
                var dcB = [Float](repeating: 0, count: 8)
                for r in 0..<2 {
                    for c in 0..<4 {
                        let cellBX: Int
                        let cellBY: Int
                        if isVerticalStack {
                            // DCT32x16: input[r * 4 + c] = dc(bx+r, by+c)
                            cellBX = bx + r
                            cellBY = by + c
                        } else {
                            // DCT16x32: input[r * 4 + c] = dc(bx+c, by+r)
                            cellBX = bx + c
                            cellBY = by + r
                        }
                        let cIdx = cellBY * dcWidth + cellBX
                        let idx = r * 4 + c
                        dcX[idx] = dcFloat[0][cIdx]
                        dcY[idx] = dcFloat[1][cIdx]
                        dcB[idx] = dcFloat[2][cIdx]
                    }
                }
                // 8 LLF coefficients per channel.
                let llfX = LowestFrequenciesFromDC.ord6Block(dc: dcX)
                let llfY = LowestFrequenciesFromDC.ord6Block(dc: dcY)
                let llfB = LowestFrequenciesFromDC.ord6Block(dc: dcB)
                // Place at top-left 4 cols × 2 rows of the 32-wide
                // coef block (natural-order positions 0..3, 32..35).
                for r in 0..<2 {
                    for c in 0..<4 {
                        let pos = r * 32 + c
                        coefX[pos] = llfX[r * 4 + c]
                        coefY[pos] = llfY[r * 4 + c]
                        coefB[pos] = llfB[r * 4 + c]
                    }
                }
                // AC coefficients (skip the 8 LLF positions).
                let acYBlock = acBlocks[blockIdxFirst][1]
                let acXBlock = acBlocks[blockIdxFirst][0]
                let acBBlock = acBlocks[blockIdxFirst][2]
                VarDCTReconstruction.dequantizeAC(
                    x: acXBlock, y: acYBlock, b: acBBlock, weights: qweights16x32, scale: blockInvQuantAC,
                    xScale: xDmMultiplier, bScale: bDmMultiplier, xFromY: xCCMul, bFromY: bCCMul,
                    columns: 32, llfRows: 2, llfColumns: 4,
                    outputX: &coefX, outputY: &coefY, outputB: &coefB)
                // libjxl-convention IDCT (replaces bridge×√512 + ortho IDCT).
                // Coef layout 16 rows × 32 cols (after CoefficientLayout swap).
                AccelerateDCT.idct2D(&coefX, rows: 16, cols: 32)
                AccelerateDCT.idct2D(&coefY, rows: 16, cols: 32)
                AccelerateDCT.idct2D(&coefB, rows: 16, cols: 32)
                // Place pixels.
                let xOrigin = bx * 8
                let yOrigin = by * 8
                if isVerticalStack {
                    // DCT32x16: 16 wide × 32 tall (transposed from coef).
                    VarDCTReconstruction.writeBlock(coefX, to: &paddedX, width: 16, height: 32,
                        sourceStride: 32, outputStride: planeWidth, x: xOrigin, y: yOrigin, transposed: true)
                    VarDCTReconstruction.writeBlock(coefY, to: &paddedY, width: 16, height: 32,
                        sourceStride: 32, outputStride: planeWidth, x: xOrigin, y: yOrigin, transposed: true)
                    VarDCTReconstruction.writeBlock(coefB, to: &paddedB, width: 16, height: 32,
                        sourceStride: 32, outputStride: planeWidth, x: xOrigin, y: yOrigin, transposed: true)
                } else {
                    // DCT16x32: 32 wide × 16 tall (matches coef layout).
                    VarDCTReconstruction.writeBlock(coefX, to: &paddedX, width: 32, height: 16,
                        sourceStride: 32, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                    VarDCTReconstruction.writeBlock(coefY, to: &paddedY, width: 32, height: 16,
                        sourceStride: 32, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                    VarDCTReconstruction.writeBlock(coefB, to: &paddedB, width: 32, height: 16,
                        sourceStride: 32, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                }
            }
        }

        // DCT32x8 / DCT8x32 IDCT overlay (libjxl ord 5). Asymmetric
        // 4-cell strategy with cellsX = 1, cellsY = 4 (DCT32×8 —
        // 32-tall, 8-wide pixel region, single column of cells) or
        // cellsX = 4, cellsY = 1 (DCT8×32 — 8-tall, 32-wide, single
        // row). After CoefficientLayout swap both share a 32 cols ×
        // 8 rows coef block (256 entries). LLF region is the 4×1
        // corner of the 32×8 coef block (4 LLF positions).
        let dct8x32Bands = DefaultQuantBands.dct8x32
        let qweights8x32: [Float]
        do {
            qweights8x32 = try quantTable(slot: 7) {
                try QuantWeights.getQuantWeights(rows: 8, cols: 32, bands: dct8x32Bands)
            }
        } catch {
            throw DecoderError.notImplemented(
                "VarDCT decode: DCT8x32 quant weights computation failed: \(error)"
            )
        }
        for by in 0..<numBlocksYAC {
            for bx in 0..<numBlocksXAC {
                let entry = acsImage.at(x: bx, y: by)
                if !entry.isFirstBlock { continue }
                if entry.strategy != .dct32x8 && entry.strategy != .dct8x32 {
                    continue
                }
                let isVerticalStack = entry.strategy == .dct32x8   // 8w × 32h
                let cellsX = isVerticalStack ? 1 : 4
                let cellsY = isVerticalStack ? 4 : 1
                guard bx + cellsX <= numBlocksXAC,
                      by + cellsY <= numBlocksYAC
                else { continue }
                let blockIdxFirst = by * totalBlocksX + bx
                let blockQF = blockIdxFirst < perBlockQF.count
                    ? perBlockQF[blockIdxFirst] : qfRow
                let blockInvQuantAC = invGlobalScale / Float(blockQF)
                let (xCCMul, bCCMul) = acCFLMul(bx: bx, by: by)
                // Per-channel coef block (32 cols × 8 rows = 256).
                var coefX = [Float](repeating: 0, count: 256)
                var coefY = [Float](repeating: 0, count: 256)
                var coefB = [Float](repeating: 0, count: 256)
                // 4 cell DC values. The coef layout is 4 cols × 1 row
                // (after CoefficientLayout swap pushes rows≤cols).
                // For DCT32×8 (cellsX=1, cellsY=4): the 4 DC values
                // come from a vertical run; in coef layout the index
                // c (0..4) corresponds to pixel-cell row c.
                // For DCT8×32 (cellsX=4, cellsY=1): the 4 DC values
                // come from a horizontal run; in coef layout the index
                // c (0..4) corresponds to pixel-cell column c.
                var dcX = [Float](repeating: 0, count: 4)
                var dcY = [Float](repeating: 0, count: 4)
                var dcB = [Float](repeating: 0, count: 4)
                for c in 0..<4 {
                    let cellBX: Int
                    let cellBY: Int
                    if isVerticalStack {
                        cellBX = bx        // single column
                        cellBY = by + c
                    } else {
                        cellBX = bx + c    // single row
                        cellBY = by
                    }
                    let cIdx = cellBY * dcWidth + cellBX
                    dcX[c] = dcFloat[0][cIdx]
                    dcY[c] = dcFloat[1][cIdx]
                    dcB[c] = dcFloat[2][cIdx]
                }
                // 4 LLF coefficients per channel via the existing
                // ord5Block helper.
                let llfX = LowestFrequenciesFromDC.ord5Block(dc: dcX)
                let llfY = LowestFrequenciesFromDC.ord5Block(dc: dcY)
                let llfB = LowestFrequenciesFromDC.ord5Block(dc: dcB)
                // Place at top-left 4 cols × 1 row of the 32-wide
                // coef block (natural-order positions 0..3).
                for c in 0..<4 {
                    coefX[c] = llfX[c]
                    coefY[c] = llfY[c]
                    coefB[c] = llfB[c]
                }
                // AC coefficients (skip the 4 LLF positions).
                let acYBlock = acBlocks[blockIdxFirst][1]
                let acXBlock = acBlocks[blockIdxFirst][0]
                let acBBlock = acBlocks[blockIdxFirst][2]
                VarDCTReconstruction.dequantizeAC(
                    x: acXBlock, y: acYBlock, b: acBBlock, weights: qweights8x32, scale: blockInvQuantAC,
                    xScale: xDmMultiplier, bScale: bDmMultiplier, xFromY: xCCMul, bFromY: bCCMul,
                    columns: 32, llfRows: 1, llfColumns: 4,
                    outputX: &coefX, outputY: &coefY, outputB: &coefB)
                // libjxl-convention IDCT. Coef layout 8 rows × 32 cols.
                AccelerateDCT.idct2D(&coefX, rows: 8, cols: 32)
                AccelerateDCT.idct2D(&coefY, rows: 8, cols: 32)
                AccelerateDCT.idct2D(&coefB, rows: 8, cols: 32)
                // Place pixels.
                let xOrigin = bx * 8
                let yOrigin = by * 8
                if isVerticalStack {
                    // DCT32×8: 8 wide × 32 tall (transposed from coef).
                    VarDCTReconstruction.writeBlock(coefX, to: &paddedX, width: 8, height: 32,
                        sourceStride: 32, outputStride: planeWidth, x: xOrigin, y: yOrigin, transposed: true)
                    VarDCTReconstruction.writeBlock(coefY, to: &paddedY, width: 8, height: 32,
                        sourceStride: 32, outputStride: planeWidth, x: xOrigin, y: yOrigin, transposed: true)
                    VarDCTReconstruction.writeBlock(coefB, to: &paddedB, width: 8, height: 32,
                        sourceStride: 32, outputStride: planeWidth, x: xOrigin, y: yOrigin, transposed: true)
                } else {
                    // DCT8×32: 32 wide × 8 tall (matches coef layout).
                    VarDCTReconstruction.writeBlock(coefX, to: &paddedX, width: 32, height: 8,
                        sourceStride: 32, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                    VarDCTReconstruction.writeBlock(coefY, to: &paddedY, width: 32, height: 8,
                        sourceStride: 32, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                    VarDCTReconstruction.writeBlock(coefB, to: &paddedB, width: 32, height: 8,
                        sourceStride: 32, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                }
            }
        }

        // DCT32x32 IDCT overlay (libjxl ord 3). Square 32×32 strategy
        // with cellsX = cellsY = 4. LLF region is the 4×4 corner of
        // the 32×32 coef block (16 LLF positions). Bridge factor is
        // the square root of the area = √(32×32) = 32 (uniform).
        let dct32Bands = DefaultQuantBands.dct32x32
        let qweights32: [Float]
        do {
            qweights32 = try quantTable(slot: 5) {
                try QuantWeights.getQuantWeights(rows: 32, cols: 32, bands: dct32Bands)
            }
        } catch {
            throw DecoderError.notImplemented(
                "VarDCT decode: DCT32x32 quant weights computation failed: \(error)"
            )
        }
        // 16 LLF natural-order positions in a 32-wide grid (top-left
        // 4 cols × 4 rows): (0..3, 0..3) → flat 0..3, 32..35, 64..67,
        // 96..99.
        for by in 0..<numBlocksYAC {
            for bx in 0..<numBlocksXAC {
                let entry = acsImage.at(x: bx, y: by)
                if !entry.isFirstBlock { continue }
                if entry.strategy != .dct32x32 { continue }
                guard bx + 4 <= numBlocksXAC,
                      by + 4 <= numBlocksYAC
                else { continue }
                let blockIdxFirst = by * totalBlocksX + bx
                let blockQF = blockIdxFirst < perBlockQF.count
                    ? perBlockQF[blockIdxFirst] : qfRow
                let blockInvQuantAC = invGlobalScale / Float(blockQF)
                let (xCCMul, bCCMul) = acCFLMul(bx: bx, by: by)
                // Per-channel coef block (32 cols × 32 rows = 1024).
                var coefX = [Float](repeating: 0, count: 1024)
                var coefY = [Float](repeating: 0, count: 1024)
                var coefB = [Float](repeating: 0, count: 1024)
                // 16 cell DC values + DC-CFL.
                var dcX = [Float](repeating: 0, count: 16)
                var dcY = [Float](repeating: 0, count: 16)
                var dcB = [Float](repeating: 0, count: 16)
                for r in 0..<4 {
                    for c in 0..<4 {
                        let cIdx = (by + r) * dcWidth + (bx + c)
                        let idx = r * 4 + c
                        dcX[idx] = dcFloat[0][cIdx]
                        dcY[idx] = dcFloat[1][cIdx]
                        dcB[idx] = dcFloat[2][cIdx]
                    }
                }
                let llfX = LowestFrequenciesFromDC.dct32x32(dc: dcX)
                let llfY = LowestFrequenciesFromDC.dct32x32(dc: dcY)
                let llfB = LowestFrequenciesFromDC.dct32x32(dc: dcB)
                for r in 0..<4 {
                    for c in 0..<4 {
                        let pos = r * 32 + c
                        coefX[pos] = llfX[r * 4 + c]
                        coefY[pos] = llfY[r * 4 + c]
                        coefB[pos] = llfB[r * 4 + c]
                    }
                }
                // AC coefficients (skip 16 LLF positions).
                let acYBlock = acBlocks[blockIdxFirst][1]
                let acXBlock = acBlocks[blockIdxFirst][0]
                let acBBlock = acBlocks[blockIdxFirst][2]
                VarDCTReconstruction.dequantizeAC(
                    x: acXBlock, y: acYBlock, b: acBBlock, weights: qweights32, scale: blockInvQuantAC,
                    xScale: xDmMultiplier, bScale: bDmMultiplier, xFromY: xCCMul, bFromY: bCCMul,
                    columns: 32, llfRows: 4, llfColumns: 4,
                    outputX: &coefX, outputY: &coefY, outputB: &coefB)
                // libjxl-convention IDCT — `ComputeScaledIDCT<32,32>`
                // = `IDCTSlow(coefᵀ)` for the square case.
                JXLDecoder.transposeSquareInPlace(&coefX, size: 32)
                JXLDecoder.transposeSquareInPlace(&coefY, size: 32)
                JXLDecoder.transposeSquareInPlace(&coefB, size: 32)
                AccelerateDCT.idct2D(&coefX, size: 32)
                AccelerateDCT.idct2D(&coefY, size: 32)
                AccelerateDCT.idct2D(&coefB, size: 32)
                // Place 32×32 patch at (bx*8, by*8).
                let xOrigin = bx * 8
                let yOrigin = by * 8
                VarDCTReconstruction.writeBlock(coefX, to: &paddedX, width: 32, height: 32,
                    sourceStride: 32, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                VarDCTReconstruction.writeBlock(coefY, to: &paddedY, width: 32, height: 32,
                    sourceStride: 32, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                VarDCTReconstruction.writeBlock(coefB, to: &paddedB, width: 32, height: 32,
                    sourceStride: 32, outputStride: planeWidth, x: xOrigin, y: yOrigin)
            }
        }

        // DCT64x32 / DCT32x64 IDCT overlay (libjxl ord 8). Asymmetric
        // 64×32 coef layout (after CoefficientLayout swap). LLF is
        // the top-left 8×4 corner of that grid (32 LLF positions).
        // Pattern mirrors DCT32x16/16x32.
        let dct32x64Bands = DefaultQuantBands.dct32x64
        let qweights32x64: [Float]
        do {
            qweights32x64 = try quantTable(slot: 12) {
                try QuantWeights.getQuantWeights(rows: 32, cols: 64, bands: dct32x64Bands)
            }
        } catch {
            throw DecoderError.notImplemented(
                "VarDCT decode: DCT32x64 quant weights computation failed: \(error)"
            )
        }
        for by in 0..<numBlocksYAC {
            for bx in 0..<numBlocksXAC {
                let entry = acsImage.at(x: bx, y: by)
                if !entry.isFirstBlock { continue }
                if entry.strategy != .dct64x32 && entry.strategy != .dct32x64 {
                    continue
                }
                let isVerticalStack = entry.strategy == .dct64x32  // 32w×64h px
                let cellsX = isVerticalStack ? 4 : 8
                let cellsY = isVerticalStack ? 8 : 4
                guard bx + cellsX <= numBlocksXAC,
                      by + cellsY <= numBlocksYAC
                else { continue }
                let blockIdxFirst = by * totalBlocksX + bx
                let blockQF = blockIdxFirst < perBlockQF.count
                    ? perBlockQF[blockIdxFirst] : qfRow
                let blockInvQuantAC = invGlobalScale / Float(blockQF)
                let (xCCMul, bCCMul) = acCFLMul(bx: bx, by: by)
                // Per-channel coef block (64 cols × 32 rows = 2048).
                var coefX = [Float](repeating: 0, count: 2048)
                var coefY = [Float](repeating: 0, count: 2048)
                var coefB = [Float](repeating: 0, count: 2048)
                // 32 cell DC values + DC-CFL. Coef-layout order is
                // 8 cols × 4 rows (cx=8, cy=4 after CoefficientLayout).
                var dcX = [Float](repeating: 0, count: 32)
                var dcY = [Float](repeating: 0, count: 32)
                var dcB = [Float](repeating: 0, count: 32)
                for r in 0..<4 {
                    for c in 0..<8 {
                        let cellBX: Int
                        let cellBY: Int
                        if isVerticalStack {
                            // DCT64x32 (cellsX=4, cellsY=8): coef row r
                            // ↔ pixel-cell column r; coef col c ↔ cell row c.
                            cellBX = bx + r
                            cellBY = by + c
                        } else {
                            // DCT32x64 (cellsX=8, cellsY=4): coef row r
                            // ↔ cell row r; coef col c ↔ cell col c.
                            cellBX = bx + c
                            cellBY = by + r
                        }
                        let cIdx = cellBY * dcWidth + cellBX
                        let idx = r * 8 + c
                        dcX[idx] = dcFloat[0][cIdx]
                        dcY[idx] = dcFloat[1][cIdx]
                        dcB[idx] = dcFloat[2][cIdx]
                    }
                }
                let llfX = LowestFrequenciesFromDC.ord8Block(dc: dcX)
                let llfY = LowestFrequenciesFromDC.ord8Block(dc: dcY)
                let llfB = LowestFrequenciesFromDC.ord8Block(dc: dcB)
                for r in 0..<4 {
                    for c in 0..<8 {
                        let pos = r * 64 + c
                        coefX[pos] = llfX[r * 8 + c]
                        coefY[pos] = llfY[r * 8 + c]
                        coefB[pos] = llfB[r * 8 + c]
                    }
                }
                let acYBlock = acBlocks[blockIdxFirst][1]
                let acXBlock = acBlocks[blockIdxFirst][0]
                let acBBlock = acBlocks[blockIdxFirst][2]
                VarDCTReconstruction.dequantizeAC(
                    x: acXBlock, y: acYBlock, b: acBBlock, weights: qweights32x64, scale: blockInvQuantAC,
                    xScale: xDmMultiplier, bScale: bDmMultiplier, xFromY: xCCMul, bFromY: bCCMul,
                    columns: 64, llfRows: 4, llfColumns: 8,
                    outputX: &coefX, outputY: &coefY, outputB: &coefB)
                // 64×32 IDCT per channel (libjxl-convention).
                AccelerateDCT.idct2D(&coefX, rows: 32, cols: 64)
                AccelerateDCT.idct2D(&coefY, rows: 32, cols: 64)
                AccelerateDCT.idct2D(&coefB, rows: 32, cols: 64)
                // Place pixels.
                let xOrigin = bx * 8
                let yOrigin = by * 8
                if isVerticalStack {
                    // DCT64x32: 32 wide × 64 tall (transposed from coef).
                    VarDCTReconstruction.writeBlock(coefX, to: &paddedX, width: 32, height: 64,
                        sourceStride: 64, outputStride: planeWidth, x: xOrigin, y: yOrigin, transposed: true)
                    VarDCTReconstruction.writeBlock(coefY, to: &paddedY, width: 32, height: 64,
                        sourceStride: 64, outputStride: planeWidth, x: xOrigin, y: yOrigin, transposed: true)
                    VarDCTReconstruction.writeBlock(coefB, to: &paddedB, width: 32, height: 64,
                        sourceStride: 64, outputStride: planeWidth, x: xOrigin, y: yOrigin, transposed: true)
                } else {
                    // DCT32x64: 64 wide × 32 tall (matches coef layout).
                    VarDCTReconstruction.writeBlock(coefX, to: &paddedX, width: 64, height: 32,
                        sourceStride: 64, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                    VarDCTReconstruction.writeBlock(coefY, to: &paddedY, width: 64, height: 32,
                        sourceStride: 64, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                    VarDCTReconstruction.writeBlock(coefB, to: &paddedB, width: 64, height: 32,
                        sourceStride: 64, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                }
            }
        }

        // DCT64x64 IDCT overlay (libjxl ord 7). Square 64×64 strategy
        // with cellsX = cellsY = 8 (covers 8×8 = 64 cells = 64×64 px).
        // LLF region is the 8×8 corner of the 64×64 coef block (64
        // LLF positions). Pattern mirrors DCT32x32.
        let dct64Bands = DefaultQuantBands.dct64x64
        let qweights64: [Float]
        do {
            qweights64 = try quantTable(slot: 11) {
                try QuantWeights.getQuantWeights(rows: 64, cols: 64, bands: dct64Bands)
            }
        } catch {
            throw DecoderError.notImplemented(
                "VarDCT decode: DCT64x64 quant weights computation failed: \(error)"
            )
        }
        for by in 0..<numBlocksYAC {
            for bx in 0..<numBlocksXAC {
                let entry = acsImage.at(x: bx, y: by)
                if !entry.isFirstBlock { continue }
                if entry.strategy != .dct64x64 { continue }
                guard bx + 8 <= numBlocksXAC,
                      by + 8 <= numBlocksYAC
                else { continue }
                let blockIdxFirst = by * totalBlocksX + bx
                let blockQF = blockIdxFirst < perBlockQF.count
                    ? perBlockQF[blockIdxFirst] : qfRow
                let blockInvQuantAC = invGlobalScale / Float(blockQF)
                let (xCCMul, bCCMul) = acCFLMul(bx: bx, by: by)
                // Per-channel coef block (64 cols × 64 rows = 4096).
                var coefX = [Float](repeating: 0, count: 4096)
                var coefY = [Float](repeating: 0, count: 4096)
                var coefB = [Float](repeating: 0, count: 4096)
                // 64 cell DC values + DC-CFL.
                var dcX = [Float](repeating: 0, count: 64)
                var dcY = [Float](repeating: 0, count: 64)
                var dcB = [Float](repeating: 0, count: 64)
                for r in 0..<8 {
                    for c in 0..<8 {
                        let cellBX = bx + c
                        let cellBY = by + r
                        let cIdx = cellBY * dcWidth + cellBX
                        let idx = r * 8 + c
                        dcX[idx] = dcFloat[0][cIdx]
                        dcY[idx] = dcFloat[1][cIdx]
                        dcB[idx] = dcFloat[2][cIdx]
                    }
                }
                let llfX = LowestFrequenciesFromDC.dct64x64(dc: dcX)
                let llfY = LowestFrequenciesFromDC.dct64x64(dc: dcY)
                let llfB = LowestFrequenciesFromDC.dct64x64(dc: dcB)
                for r in 0..<8 {
                    for c in 0..<8 {
                        let pos = r * 64 + c
                        coefX[pos] = llfX[r * 8 + c]
                        coefY[pos] = llfY[r * 8 + c]
                        coefB[pos] = llfB[r * 8 + c]
                    }
                }
                // AC coefficients (skip 64 LLF positions).
                let acYBlock = acBlocks[blockIdxFirst][1]
                let acXBlock = acBlocks[blockIdxFirst][0]
                let acBBlock = acBlocks[blockIdxFirst][2]
                VarDCTReconstruction.dequantizeAC(
                    x: acXBlock, y: acYBlock, b: acBBlock, weights: qweights64, scale: blockInvQuantAC,
                    xScale: xDmMultiplier, bScale: bDmMultiplier, xFromY: xCCMul, bFromY: bCCMul,
                    columns: 64, llfRows: 8, llfColumns: 8,
                    outputX: &coefX, outputY: &coefY, outputB: &coefB)
                // 64×64 IDCT per channel — `ComputeScaledIDCT<64,64>`
                // = `IDCTSlow(coefᵀ)` for the square case.
                JXLDecoder.transposeSquareInPlace(&coefX, size: 64)
                JXLDecoder.transposeSquareInPlace(&coefY, size: 64)
                JXLDecoder.transposeSquareInPlace(&coefB, size: 64)
                AccelerateDCT.idct2D(&coefX, size: 64)
                AccelerateDCT.idct2D(&coefY, size: 64)
                AccelerateDCT.idct2D(&coefB, size: 64)
                // Place 64×64 patch at (bx*8, by*8).
                let xOrigin = bx * 8
                let yOrigin = by * 8
                VarDCTReconstruction.writeBlock(coefX, to: &paddedX, width: 64, height: 64,
                    sourceStride: 64, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                VarDCTReconstruction.writeBlock(coefY, to: &paddedY, width: 64, height: 64,
                    sourceStride: 64, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                VarDCTReconstruction.writeBlock(coefB, to: &paddedB, width: 64, height: 64,
                    sourceStride: 64, outputStride: planeWidth, x: xOrigin, y: yOrigin)
            }
        }

        // AFV overlay (v0.10.0f). 4 variants (afv0..afv3); each
        // covers a single 8×8 cell. Quant matrix is the libjxl
        // `kQuantModeAFV` LIBRARY-default port from
        // `QuantWeights.getAFVQuantWeights`. Shares the v0.9.0
        // residual byte-diff (the 2.286× factor) — until the
        // libjxl-trace close-out lands, AFV decode is approximate.
        let afvWeights: [Float]
        do {
            // LIBRARY-default bands are used raw (no ×64) — see the
            // DCT8 note above.
            afvWeights = try quantTable(slot: 10) {
                try QuantWeights.getAFVQuantWeights(
                    dct4x8Bands: DefaultQuantBands.dct4x8,
                    dct4x4Bands: DefaultQuantBands.dct4x4,
                    afvWeights: DefaultQuantBands.afv)
            }
        } catch {
            throw DecoderError.notImplemented(
                "VarDCT decode: AFV quant weights computation failed: \(error)"
            )
        }
        for by in 0..<numBlocksYAC {
            for bx in 0..<numBlocksXAC {
                let entry = acsImage.at(x: bx, y: by)
                if !entry.isFirstBlock { continue }
                let strategy = entry.strategy
                let afvKind: Int
                switch strategy {
                case .afv0: afvKind = 0
                case .afv1: afvKind = 1
                case .afv2: afvKind = 2
                case .afv3: afvKind = 3
                default: continue
                }

                let blockIdxFirst = by * totalBlocksX + bx
                let blockQF = blockIdxFirst < perBlockQF.count
                    ? perBlockQF[blockIdxFirst] : qfRow
                let blockInvQuantAC = invGlobalScale / Float(blockQF)
                let (xCCMul, bCCMul) = acCFLMul(bx: bx, by: by)
                let acYBlock = acBlocks[blockIdxFirst][1]
                let acXBlock = acBlocks[blockIdxFirst][0]
                let acBBlock = acBlocks[blockIdxFirst][2]

                // 1) DC pixel — dequantised + DC-CfL + smoothed (AFV
                //    is a 1×1 cell strategy, single DC value).
                let dcY = dcFloat[1][by * dcWidth + bx]
                let dcCorrectedX = dcFloat[0][by * dcWidth + bx]
                let dcCorrectedB = dcFloat[2][by * dcWidth + bx]

                // 2) AC dequant for all 64 positions (AFV uses a
                //    single 64-coef block, not multi-block). DC at
                //    flat 0 is overwritten with the dequantized DC
                //    after the loop.
                var coefY = [Float](repeating: 0, count: 64)
                var coefX = [Float](repeating: 0, count: 64)
                var coefB = [Float](repeating: 0, count: 64)
                VarDCTReconstruction.dequantizeAC(
                    x: acXBlock, y: acYBlock, b: acBBlock, weights: afvWeights, scale: blockInvQuantAC,
                    xScale: xDmMultiplier, bScale: bDmMultiplier, xFromY: xCCMul, bFromY: bCCMul,
                    columns: 8, llfRows: 1, llfColumns: 1,
                    outputX: &coefX, outputY: &coefY, outputB: &coefB)
                coefY[0] = dcY
                coefX[0] = dcCorrectedX
                coefB[0] = dcCorrectedB

                // 3) AFV transform → 8×8 pixels via the 3-sub-block
                //    decomposition (AFV 4×4 + IDCT 4×4 + IDCT 4×8).
                // The IDCT4×4 sub-block is SQUARE, so libjxl's
                // `ComputeScaledIDCT<4,4>` emits the transposed
                // layout (ROWS≥COLS) — the coefficient block must be
                // transposed before the un-transposed `idct2D`, same
                // as the DCT8/16/32/64 square overlays. The 4×8
                // sub-block (ROWS<COLS) needs no transpose.
                let idct4x4Backend: (inout [Float]) -> Void = { block in
                    JXLDecoder.transposeSquareInPlace(&block, size: 4)
                    AccelerateDCT.idct2D(&block, size: 4)
                }
                let idct4x8Backend: (inout [Float]) -> Void = { block in
                    AccelerateDCT.idct2D(&block, rows: 4, cols: 8)
                }
                var pixY = [Float](repeating: 0, count: 64)
                var pixX = [Float](repeating: 0, count: 64)
                var pixB = [Float](repeating: 0, count: 64)
                AFV.transformToPixels(
                    afvKind: afvKind, coefficients: coefY, pixels: &pixY,
                    idct4x4Backend: idct4x4Backend,
                    idct4x8Backend: idct4x8Backend)
                AFV.transformToPixels(
                    afvKind: afvKind, coefficients: coefX, pixels: &pixX,
                    idct4x4Backend: idct4x4Backend,
                    idct4x8Backend: idct4x8Backend)
                AFV.transformToPixels(
                    afvKind: afvKind, coefficients: coefB, pixels: &pixB,
                    idct4x4Backend: idct4x4Backend,
                    idct4x8Backend: idct4x8Backend)

                // 4) Place 8×8 pixels at (bx*8, by*8).
                let xOrigin = bx * 8
                let yOrigin = by * 8
                VarDCTReconstruction.writeBlock(pixX, to: &paddedX, width: 8, height: 8,
                    sourceStride: 8, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                VarDCTReconstruction.writeBlock(pixY, to: &paddedY, width: 8, height: 8,
                    sourceStride: 8, outputStride: planeWidth, x: xOrigin, y: yOrigin)
                VarDCTReconstruction.writeBlock(pixB, to: &paddedB, width: 8, height: 8,
                    sourceStride: 8, outputStride: planeWidth, x: xOrigin, y: yOrigin)
            }
        }

        if trace {
            let labels = ["X", "Y", "B"]
            for c in 0..<3 {
                let block = [paddedX, paddedY, paddedB][c]
                let mean = block.reduce(0.0, +) / Float(block.count)
                let minVal = block.min() ?? 0
                let maxVal = block.max() ?? 0
                FileHandle.standardError.write(Data(
                    "TRACE plane[\(labels[c])]: dim=\(planeWidth)×\(planeHeight) mean=\(mean) range=[\(minVal), \(maxVal)]\n".utf8
                ))
            }
        }

        // (16) Bite 4 — Color correlation + inverse OpsinXYB +
        // sRGB OETF + 8-bit RGB output. libjxl applies color
        // correlation per-coefficient inside `DequantLane`:
        //
        //     dequant_x = x_cc_mul * dequant_y + dequant_x_cc
        //     dequant_b = b_cc_mul * dequant_y + dequant_b_cc
        //
        // Since IDCT is linear and `cc_mul` is constant per tile,
        // applying the same MulAdd in pixel domain is mathematically
        // equivalent. For our 1-tile fixture:
        //     x_cc_mul = base_correlation_x + ytox_map[0] / color_factor
        //              = 0 + 0/84 = 0
        //     b_cc_mul = base_correlation_b + ytob_map[0] / color_factor
        //              = 1 + 0/84 = 1
        // So X stays, B becomes Y + B.
        // CFL slopes are computed above (before the dequant loop).

        // CFL is already baked into the planes at the coefficient
        // level (DC-CFL on F[0,0], AC-CFL on F[k>0]). Just hand the
        // planes off to Gaborish + EPF + the inverse XYB stage.
        // libjxl's render pipeline works on the unpadded frame
        // (`xsize × ysize`) and mirrors at its edges; the padded block
        // grid is only the IDCT's domain.
        @inline(__always) func cropToFrame(_ p: [Float]) -> [Float] {
            if planeWidth == xsize && planeHeight == ysize { return p }
            var c = [Float](repeating: 0, count: xsize * ysize)
            for y in 0..<ysize {
                for x in 0..<xsize { c[y * xsize + x] = p[y * planeWidth + x] }
            }
            return c
        }
        var planeX = cropToFrame(paddedX)
        var planeY = cropToFrame(paddedY)
        var planeB = cropToFrame(paddedB)

        // EXPERIMENT v0.9.0k: skip Gaborish + EPF to isolate raw IDCT pixels.
        let skipPhaseR = ProcessInfo.processInfo.environment["JXL_SKIP_PHASE_R"] != nil

        // Phase R restoration filters. libjxl pipeline order
        // (`dec_cache.cc::PreparePipeline`):
        //
        //     ChromaUpsampling → Gaborish (if lf.gab) → EPF (epf_iters
        //     stages) → ... → XYB (inverse OpsinXYB) → sRGB OETF
        //
        // Gaborish is a 3×3 separable-style smoothing convolution
        // applied per-channel. Default weights from libjxl
        // `loop_filter.cc::LoopFilter::SetDefault`:
        //   gab_x_weight1 = 0.115169424
        //   gab_x_weight2 = 0.061248592
        //   (same for Y and B; identical to our `Gaborish.defaultWeight*`)
        //
        // EPF is deferred until later in v0.6.0.
        if fh.loopFilter.gab && !skipPhaseR {
            let gw = fh.loopFilter.gabWeights
            Gaborish.apply(to: &planeX, width: xsize, height: ysize, weight1: gw[0], weight2: gw[1])
            Gaborish.apply(to: &planeY, width: xsize, height: ysize, weight1: gw[2], weight2: gw[3])
            Gaborish.apply(to: &planeB, width: xsize, height: ysize, weight1: gw[4], weight2: gw[5])
            if trace {
                FileHandle.standardError.write(Data(
                    "TRACE Gaborish applied to all 3 channels (\(planeWidth)×\(planeHeight))\n".utf8
                ))
            }
        }

        // EPF — edge-preserving filter, up to 3 iterations gated by
        // `lf.epfIters`. The per-block sharpness field is ACMeta
        // channel 3, assembled across DC groups into `epfSharpnessFull`.
        if fh.loopFilter.epfIters > 0 && !skipPhaseR {
            // Sharpness field per block (ACMeta channel 3).
            let totalBlocks = numBlocksXAC * numBlocksYAC
            let sharpField: [UInt8] = epfSharpnessFull.count >= totalBlocks
                ? epfSharpnessFull.prefix(totalBlocks).map { UInt8(clamping: $0) }
                : [UInt8](repeating: 0, count: totalBlocks)
            // Wire the per-block QF (already extracted above).
            let perBlockQFForEPF: [Int32] = (perBlockQF.count >= totalBlocks)
                ? Array(perBlockQF.prefix(totalBlocks))
                : [Int32](repeating: qfRow, count: totalBlocks)
            // Override params.epfIters with the loopFilter's value
            // since the default EPFParams uses 2.
            let lf = fh.loopFilter
            let epfParams = EPFParams(
                epfIters: Int(lf.epfIters),
                quantMul: lf.epfQuantMul,
                sharpLut: lf.epfSharpLut,
                channelScale: (lf.epfChannelScale[0], lf.epfChannelScale[1], lf.epfChannelScale[2]),
                pass1ZeroFlush: lf.epfPass1ZeroFlush,
                pass2ZeroFlush: lf.epfPass2ZeroFlush,
                pass0SigmaScale: lf.epfPass0SigmaScale,
                pass2SigmaScale: lf.epfPass2SigmaScale,
                borderSadMul: lf.epfBorderSadMul
            )
            do {
                try EPF.applyAllStages(
                    planeX: &planeX, planeY: &planeY, planeB: &planeB,
                    width: xsize, height: ysize,
                    sharpnessField: sharpField,
                    perBlockQF: perBlockQFForEPF,
                    quantScale: Float(qp.globalScale)
                        / Float(1 << 16),
                    params: epfParams
                )
                if trace {
                    FileHandle.standardError.write(Data(
                        "TRACE EPF: \(fh.loopFilter.epfIters) iter(s); sharpness=\(sharpField); per-block QF=\(perBlockQFForEPF)\n".utf8
                    ))
                }
            } catch let e as EPFError {
                throw DecoderError.notImplemented(
                    "VarDCT decode: EPF stage failed: \(e)"
                )
            }
        }

        let planeCropped = (planeWidth != xsize || planeHeight != ysize)
        _ = planeCropped
        // Upsampling (`stage_upsampling.cc`): the render pipeline runs on
        // the coded frame with mirrored edges, then the output is cropped
        // to the image size.
        var outWidth = xsize
        var outHeight = ysize
        if upsampling > 1 {
            let shift = upsampling == 2 ? 1 : (upsampling == 4 ? 2 : 3)
            let ups = Upsampler(weights: transformData.weights(forShift: shift), shift: shift)
            let full = xsize * upsampling
            let fullH = ysize * upsampling
            @inline(__always) func upsampleCrop(_ p: [Float]) -> [Float] {
                let u = ups.apply(p, width: xsize, height: ysize)
                if full == xsizeUp && fullH == ysizeUp { return u }
                var c = [Float](repeating: 0, count: xsizeUp * ysizeUp)
                for y in 0..<ysizeUp {
                    for x in 0..<xsizeUp { c[y * xsizeUp + x] = u[y * full + x] }
                }
                return c
            }
            planeX = upsampleCrop(planeX)
            planeY = upsampleCrop(planeY)
            planeB = upsampleCrop(planeB)
            outWidth = xsizeUp
            outHeight = ysizeUp
        }
        // Noise (`dec_noise.cc` random planes per group, `stage_noise.cc`
        // convolution and additive stage) in the upsampled domain.
        if let params = noiseParams, params.hasAny {
            let random = NoiseSynthesis.randomPlanes(
                width: outWidth, height: outHeight, groupDim: groupDim,
                upsampling: upsampling, numGroupsX: numGroupsX, numGroupsY: numGroupsY,
                visibleFrameIndex: frameIndices.visible,
                nonvisibleFrameIndex: frameIndices.nonvisible)
            let convolved = random.map {
                NoiseSynthesis.convolve($0, width: outWidth, height: outHeight)
            }
            NoiseSynthesis.add(
                x: &planeX, y: &planeY, b: &planeB, noise: convolved, params: params,
                ytox: cmapDC.baseCorrelationX, ytob: cmapDC.baseCorrelationB)
        }
        if let sink = xybSink {
            // `GetWriteToImage3FStage`: a DC frame's XYB samples are kept
            // for the frame that references it; nothing is rendered.
            sink.planes = [planeX, planeY, planeB]
            sink.width = outWidth
            sink.height = outHeight
            return ImageFrame(width: outWidth, height: outHeight, channels: 1)
        }
        return try renderXYBFrame(
            planeX: planeX, planeY: planeY, planeB: planeB,
            width: outWidth, height: outHeight, metadata: metadata,
            extraChannelPlanes: extraChannelPlanes, label: "VarDCT decode")
    }

    /// Six large transforms have only a DC-only reconstruction path. Reject AC in any channel.
    static func requireInverseTransform(_ strategy: ACStrategy, coefficients: [[Int32]]) throws {
        switch strategy {
        case .dct128x128, .dct128x64, .dct64x128, .dct256x256, .dct256x128, .dct128x256:
            guard !coefficients.contains(where: { $0.contains(where: { $0 != 0 }) }) else {
                throw DecoderError.notImplemented("VarDCT decode: AC strategy \(strategy) with non-zero AC; per-strategy IDCT")
            }
        default: break
        }
    }

    /// Receives the XYB planes of a VarDCT DC frame (`dc_level ≥ 1`).
    final class XYBFrameSink {
        var planes: [[Float]] = []
        var width = 0
        var height = 0
        var frameEndByte = 0
    }

    /// The libjxl output stage for XYB planes (`stage_xyb.cc` inverse
    /// opsin, `stage_from_linear.cc` sRGB transfer, `stage_write.cc`
    /// dither and rounding): `width × height` planes, tightly packed,
    /// into an ``ImageFrame`` of the metadata's bit depth. A single alpha
    /// extra channel is interleaved; other extra channels are refused.
    private func renderXYBFrame(
        planeX: [Float], planeY: [Float], planeB: [Float],
        width: Int, height: Int, metadata: ImageMetadata,
        extraChannelPlanes: [[Int32]], label: String
    ) throws -> ImageFrame {
        let bps = metadata.bitDepth.bitsPerSample
        guard !metadata.bitDepth.floatingPoint else {
            throw DecoderError.notImplemented(
                "\(label): float-sample bit depth not supported")
        }
        guard bps >= 1 && bps <= 16 else {
            throw DecoderError.notImplemented(
                "\(label) of \(bps)-bit samples (only 1..16 supported today)")
        }
        let nbExtraChannels = metadata.extraChannels.count
        if nbExtraChannels > 0 {
            guard nbExtraChannels == 1, metadata.extraChannels[0].type == .alpha,
                  extraChannelPlanes.count == 1 else {
                throw DecoderError.notImplemented(
                    "\(label): \(nbExtraChannels) extra channel(s) of types "
                    + "\(metadata.extraChannels.map { $0.type }) — only a single "
                    + "alpha channel is wired to output")
            }
        }
        let isGray = metadata.colorEncoding.colorSpace == .grayscale
        let opsinInverse = LibjxlOutput.OpsinInverse(
            intensityTarget: metadata.intensityTarget, gray: isGray)
        let pixels = width * height
        let colourChannels = isGray ? 1 : 3
        let channels = colourChannels + nbExtraChannels
        let alpha: [Int32]? = nbExtraChannels == 1 ? extraChannelPlanes[0] : nil
        if bps <= 8 {
            var out = [UInt8](repeating: 0, count: pixels * channels)
            planeX.withUnsafeBufferPointer { px in
                planeY.withUnsafeBufferPointer { py in
                    planeB.withUnsafeBufferPointer { pb in
                        out.withUnsafeMutableBufferPointer { output in
                            @inline(__always) func load(_ p: UnsafeBufferPointer<Float>, _ i: Int) -> SIMD4<Float> {
                                UnsafeRawPointer(p.baseAddress! + i).loadUnaligned(as: SIMD4<Float>.self)
                            }
                            for y in 0..<height {
                                var x = 0
                                while x + 4 <= width {
                                    let pi = y * width + x
                                    let lin = LibjxlOutput.xybToLinear(
                                        x: load(px, pi), y: load(py, pi), b: load(pb, pi), inverse: opsinInverse)
                                    let red = LibjxlOutput.sample8(LibjxlOutput.srgbFromLinear(lin.R), x: x, y: y, channel: 0)
                                    let green = isGray ? SIMD4<UInt8>.zero
                                        : LibjxlOutput.sample8(LibjxlOutput.srgbFromLinear(lin.G), x: x, y: y, channel: 1)
                                    let blue = isGray ? SIMD4<UInt8>.zero
                                        : LibjxlOutput.sample8(LibjxlOutput.srgbFromLinear(lin.B), x: x, y: y, channel: 2)
                                    for lane in 0..<4 {
                                        let oi = (pi + lane) * channels
                                        output[oi] = red[lane]
                                        if !isGray {
                                            output[oi + 1] = green[lane]
                                            output[oi + 2] = blue[lane]
                                        }
                                        if let a = alpha {
                                            output[oi + colourChannels] = pi + lane < a.count ? UInt8(clamping: a[pi + lane]) : 255
                                        }
                                    }
                                    x += 4
                                }
                                while x < width {
                                    let pi = y * width + x
                                    let lin = LibjxlOutput.xybToLinear(x: px[pi], y: py[pi], b: pb[pi], inverse: opsinInverse)
                                    let oi = pi * channels
                                    output[oi] = LibjxlOutput.sample8(LibjxlOutput.srgbFromLinear(lin.R), x: x, y: y, channel: 0)
                                    if !isGray {
                                        output[oi + 1] = LibjxlOutput.sample8(LibjxlOutput.srgbFromLinear(lin.G), x: x, y: y, channel: 1)
                                        output[oi + 2] = LibjxlOutput.sample8(LibjxlOutput.srgbFromLinear(lin.B), x: x, y: y, channel: 2)
                                    }
                                    if let a = alpha { output[oi + colourChannels] = pi < a.count ? UInt8(clamping: a[pi]) : 255 }
                                    x += 1
                                }
                            }
                        }
                    }
                }
            }
            return ImageFrame(width: width, height: height, channels: channels,
                              alphaChannels: nbExtraChannels, data: out)
        }
        let sampleMax = UInt32((1 << bps) - 1)
        let maxValueF = Float(sampleMax)
        var out = [UInt8](repeating: 0, count: pixels * channels * 2)
        for y in 0..<height {
            for x in 0..<width {
                let pi = y * width + x
                let lin = LibjxlOutput.xybToLinear(
                    x: planeX[pi], y: planeY[pi], b: planeB[pi], inverse: opsinInverse)
                var oi = pi * channels * 2
                @inline(__always) func put(_ v: UInt32) {
                    out[oi] = UInt8(v & 0xff)
                    out[oi + 1] = UInt8((v >> 8) & 0xff)
                    oi += 2
                }
                put(LibjxlOutput.sample(LibjxlOutput.srgbFromLinear(lin.R), maxValue: maxValueF))
                if !isGray {
                    put(LibjxlOutput.sample(LibjxlOutput.srgbFromLinear(lin.G), maxValue: maxValueF))
                    put(LibjxlOutput.sample(LibjxlOutput.srgbFromLinear(lin.B), maxValue: maxValueF))
                }
                if let a = alpha {
                    put(pi < a.count ? min(UInt32(max(0, a[pi])), sampleMax) : sampleMax)
                }
            }
        }
        return ImageFrame(width: width, height: height, channels: channels,
                          pixelType: .uint16, alphaChannels: nbExtraChannels, data: out)
    }

    /// Transpose an N×N square coefficient block in place. Used to
    /// convert from libjxl's bitstream coefficient layout (which
    /// `ComputeScaledDCT` produces in transposed-vanilla form for
    /// ROWS≥COLS strategies) to the layout our vanilla IDCT expects.
    @inline(__always)
    static func transposeSquareInPlace(_ b: inout [Float], size N: Int) {
        precondition(b.count == N * N)
        b.withUnsafeMutableBufferPointer { values in
            for r in 0..<N {
                for c in (r + 1)..<N {
                    let value = values[r * N + c]
                    values[r * N + c] = values[c * N + r]
                    values[c * N + r] = value
                }
            }
        }
    }

    /// Per-IEC 61966-2-1 sRGB OETF: linear-light [0,1] → code value,
    /// generalised over bit depth via `maxValue` (`255` for 8-bit,
    /// `65535`/`(2^bps - 1)` for wider depths). Clamps to
    /// `[0, maxValue]`.
    @inline(__always)
    private func linearToSRGBCode(_ linear: Float, maxValue: Float) -> UInt32 {
        let clamped = max(0, min(linear, 1))
        let encoded: Float
        if clamped <= 0.0031308 {
            encoded = 12.92 * clamped
        } else {
            encoded = 1.055 * powf(clamped, 1.0 / 2.4) - 0.055
        }
        let rounded = (encoded * maxValue).rounded()
        return UInt32(max(0, min(rounded, maxValue)))
    }

    /// Per-IEC 61966-2-1 sRGB OETF: linear-light [0,1] → 8-bit code
    /// value. Clamps to [0, 255].
    @inline(__always)
    private func linearToSRGB8(_ linear: Float) -> UInt8 {
        UInt8(linearToSRGBCode(linear, maxValue: 255.0))
    }

    /// Best-effort container unwrap: returns the naked codestream
    /// bytes for either form (signature-prefix or ISOBMFF).
    private func unwrapCodestream(_ data: Data) -> Data? {
        guard let form = try? parseJXLContainer(data) else { return nil }
        switch form {
        case .naked:
            return data
        case .iso(let boxes):
            return try? extractCodestream(from: boxes, in: data)
        }
    }

    /// Repack a successfully decoded `ModularImage` into an
    /// `ImageFrame` with the conventions the rest of the toolchain
    /// (CLI, PNM writer) expects: row-major channel-interleaved,
    /// 8-bit samples in `UInt8`, 9..16-bit samples packed as
    /// little-endian `UInt16` pairs.
    private func assembleImageFrame(
        modular: ModularImage, metadata m: ImageMetadata,
        xsize: Int, ysize: Int
    ) throws -> ImageFrame {
        let bps = m.bitDepth.bitsPerSample
        guard !m.bitDepth.floatingPoint else {
            throw DecoderError.notImplemented(
                "float-sample decode (bitsPerSample=\(bps), floating)"
            )
        }
        guard bps >= 1 && bps <= 16 else {
            throw DecoderError.notImplemented(
                "decode of \(bps)-bit samples (only 1..16 supported today)"
            )
        }
        let pixelType: PixelType = (bps <= 8) ? .uint8 : .uint16
        let isGray = (m.colorEncoding.colorSpace == .grayscale)
        let nbColor = isGray ? 1 : 3
        let nbExtra = m.extraChannels.count
        let totalChannels = nbColor + nbExtra
        guard modular.channels.count >= totalChannels else {
            throw DecoderError.notImplemented(
                "ModularImage has \(modular.channels.count) channels; "
                + "metadata declares \(totalChannels)"
            )
        }
        // We surface up to 1 extra channel as alpha. Spec allows
        // more (depth, spot colour, …) but `ImageFrame.alphaChannels`
        // is 0 or 1; everything else gets dropped here.
        let alphaIdx: Int? = (0..<nbExtra).first(where: {
            m.extraChannels[$0].type == .alpha
        }).map { nbColor + $0 }
        let outChannels: Int
        let alphaChannels: Int
        if alphaIdx != nil {
            outChannels = nbColor + 1
            alphaChannels = 1
        } else {
            outChannels = nbColor
            alphaChannels = 0
        }
        var frame = ImageFrame(
            width: xsize, height: ysize, channels: outChannels,
            pixelType: pixelType,
            colorSpace: isGray ? .grayscale : .sRGB,
            alphaChannels: alphaChannels
        )
        let bytesPerSample = pixelType.bytesPerSample
        let stride = outChannels * bytesPerSample
        // Decoded samples are clamped to the declared sample range
        // [0, 2^bps − 1] on output, matching libjxl. For a valid in-range
        // lossless stream this is a no-op; it only bites when an inverse
        // transform (e.g. YCoCg-R RCT) reconstructs an out-of-gamut value
        // for a sub-container bit depth — e.g. a 9-bit image stored in a
        // 16-bit container must clamp to 511, not merely mask to 16 bits.
        let sampleMax = UInt32((1 << bps) - 1)
        let pixelCount = xsize * ysize
        // Colour channels 0..<nbColor; alpha (if present) follows.
        // Source channel index paired with the interleaved byte offset.
        var planes: [(channel: Int, byteOffset: Int)] = []
        planes.reserveCapacity(nbColor + 1)
        for ci in 0..<nbColor {
            planes.append((ci, ci * bytesPerSample))
        }
        if let aIdx = alphaIdx {
            planes.append((aIdx, nbColor * bytesPerSample))
        }
        // Whole-buffer per-channel loops (split per byte width) —
        // each sample clamps to [0, sampleMax] and lands LSB-first.
        frame.data.withUnsafeMutableBufferPointer { dst in
            for (channel, byteOffset) in planes {
                modular.channels[channel].pixels
                    .withUnsafeBufferPointer { src in
                        if bytesPerSample == 1 {
                            var d = byteOffset
                            for i in 0..<pixelCount {
                                let clamped = min(
                                    UInt32(max(0, src[i])), sampleMax)
                                dst[d] = UInt8(clamped)
                                d &+= stride
                            }
                        } else {
                            var d = byteOffset
                            for i in 0..<pixelCount {
                                let clamped = min(
                                    UInt32(max(0, src[i])), sampleMax)
                                dst[d] = UInt8(clamped & 0xff)
                                dst[d + 1] = UInt8((clamped >> 8) & 0xff)
                                d &+= stride
                            }
                        }
                    }
            }
        }
        return frame
    }

    /// Decode every frame in a JPEG XL codestream — single frame
    /// or multi-frame animation. For single-frame inputs returns
    /// `[decode(data)]`. For multi-frame: scans the codestream's
    /// per-frame byte ranges, then for each frame constructs a
    /// synthetic single-frame codestream (shared prelude + that
    /// frame's bytes) and runs the existing `decode(_:)` on it.
    /// The shared prelude correctly declares animation, so the
    /// per-frame `FrameHeader` round-trips through the existing
    /// reader without any rewriting needed. `isLast` flag in the
    /// per-frame header does not change the outcome — `decode(_:)`
    /// always returns the first frame it reads. Lossy animation beyond
    /// the first image is outside the qualified profile and is refused.
    public func decodeAll(_ data: Data) throws -> [ImageFrame] {
        if MinimalLosslessCodec.isM0(data) {
            return [try MinimalLosslessCodec.decode(data)]
        }
        let codestream: Data
        do {
            switch try parseJXLContainer(data) {
            case .naked:
                codestream = data
            case .iso(let boxes):
                codestream = try extractCodestream(
                    from: boxes, in: data)
            }
        } catch let e as ContainerError {
            throw DecoderError.container(e)
        }
        guard hasCodestreamSignature(codestream) else {
            throw DecoderError.missingSignature
        }
        // Walk the codestream's prelude (signature + SizeHeader +
        // ImageMetadata + CustomTransformData) to find the byte
        // position where the first FrameHeader starts.
        var r = BitReader(codestream, startingAt: 16)
        let _ = try SizeHeader.read(from: &r)
        let metadata = try ImageMetadata.read(from: &r)
        try r.readCustomTransformData(
            xybEncoded: metadata.xybEncoded)
        try r.alignToByte()
        let preludeEndByte = r.position / 8
        // Walk per-frame: read FrameHeader + TOC, sum entry sizes
        // to find the frame's end byte. Stop after the frame whose
        // `isLast` flag is set.
        let ctx = FrameHeaderContext(
            xybEncoded: metadata.xybEncoded,
            numExtraChannels: metadata.extraChannels.count,
            haveAnimation: metadata.animation != nil,
            haveTimecodes:
                metadata.animation?.haveTimecodes ?? false)
        var frameRanges: [(start: Int, end: Int)] = []
        while true {
            let frameStartByte = r.position / 8
            let fh = try FrameHeader.read(from: &r, context: ctx)
            if metadata.animation != nil, fh.encoding == .varDCT || fh.colorTransform == .xyb,
               !fh.isLast || !frameRanges.isEmpty {
                throw DecoderError.notImplemented("decodeAll: lossy animation beyond the first image")
            }
            let (xs, ys) = Self.codedFrameSize(
                fh, imageWidth: Int(codestreamXSize(codestream)),
                imageHeight: Int(codestreamYSize(codestream)))
            let groupDim = 128 << Int(fh.groupSizeShift)
            let dcGroupDim = groupDim << 3
            let numG = ((xs + groupDim - 1) / groupDim)
                * ((ys + groupDim - 1) / groupDim)
            let numDG = ((xs + dcGroupDim - 1) / dcGroupDim)
                * ((ys + dcGroupDim - 1) / dcGroupDim)
            let entries = TOC.numEntries(
                numGroups: numG, numDcGroups: numDG,
                numPasses: Int(fh.passes.numPasses))
            let toc = try TOC.read(from: &r, numEntries: entries)
            // TOC.read aligns to byte; sections that follow are
            // byte-aligned chunks of sizes toc.entrySizes.
            let afterTocByte = r.position / 8
            let totalSectionBytes = toc.entrySizes.reduce(0) {
                $0 + Int($1)
            }
            let frameEndByte = afterTocByte + totalSectionBytes
            guard frameEndByte <= codestream.count else {
                throw DecoderError.notImplemented(
                    "decodeAll: frame \(frameRanges.count) "
                    + "extends past codestream end "
                    + "(\(frameEndByte) > \(codestream.count))")
            }
            frameRanges.append(
                (start: frameStartByte, end: frameEndByte))
            if fh.isLast { break }
            // Advance reader past the sections to the next
            // FrameHeader byte position.
            try r.skip(bits: totalSectionBytes * 8)
        }
        // For each frame, build a synthetic single-frame
        // codestream (shared prelude + that frame's bytes) and
        // decode it via the existing single-frame path.
        let prelude = codestream.subdata(in: 0..<preludeEndByte)
        var out: [ImageFrame] = []
        out.reserveCapacity(frameRanges.count)
        for range in frameRanges {
            var synth = prelude
            synth.append(codestream.subdata(
                in: range.start..<range.end))
            out.append(try decode(synth))
        }
        return out
    }

    /// Decode a single frame at `index` from a JPEG XL codestream.
    /// For single-frame inputs only `index == 0` is valid;
    /// lossless multi-frame animations support any `index` in
    /// `0 ..< countFrames(data)`. Lossy animations only support index 0;
    /// progressive DC frames require `decode(_:)` on the complete sequence.
    /// Use this when you only need one
    /// frame of an animation (e.g. a thumbnail or a specific
    /// keyframe) — much cheaper than `decodeAll(_:)` then picking
    /// the desired frame, since only that one frame's pixels are
    /// decoded.
    public func decodeFrame(
        _ data: Data, at index: Int
    ) throws -> ImageFrame {
        guard index >= 0 else {
            throw DecoderError.notImplemented(
                "decodeFrame: index must be ≥ 0 (got \(index))")
        }
        if MinimalLosslessCodec.isM0(data) {
            guard index == 0 else {
                throw DecoderError.notImplemented(
                    "decodeFrame: M0 codestream has 1 frame, "
                    + "index \(index) out of range")
            }
            return try MinimalLosslessCodec.decode(data)
        }
        let codestream: Data
        do {
            switch try parseJXLContainer(data) {
            case .naked:
                codestream = data
            case .iso(let boxes):
                codestream = try extractCodestream(
                    from: boxes, in: data)
            }
        } catch let e as ContainerError {
            throw DecoderError.container(e)
        }
        guard hasCodestreamSignature(codestream) else {
            throw DecoderError.missingSignature
        }
        // Walk the prelude + per-frame FrameHeader+TOC sequence
        // looking for the frame at `index`. Same per-frame parse
        // as `decodeAll`, but bails out once the target frame's
        // byte range is found.
        var r = BitReader(codestream, startingAt: 16)
        let _ = try SizeHeader.read(from: &r)
        let metadata = try ImageMetadata.read(from: &r)
        try r.readCustomTransformData(
            xybEncoded: metadata.xybEncoded)
        try r.alignToByte()
        let preludeEndByte = r.position / 8
        let ctx = FrameHeaderContext(
            xybEncoded: metadata.xybEncoded,
            numExtraChannels: metadata.extraChannels.count,
            haveAnimation: metadata.animation != nil,
            haveTimecodes:
                metadata.animation?.haveTimecodes ?? false)
        var current = 0
        while true {
            let frameStartByte = r.position / 8
            let fh = try FrameHeader.read(from: &r, context: ctx)
            let (xs, ys) = Self.codedFrameSize(
                fh, imageWidth: Int(codestreamXSize(codestream)),
                imageHeight: Int(codestreamYSize(codestream)))
            let groupDim = 128 << Int(fh.groupSizeShift)
            let dcGroupDim = groupDim << 3
            let numG = ((xs + groupDim - 1) / groupDim)
                * ((ys + groupDim - 1) / groupDim)
            let numDG = ((xs + dcGroupDim - 1) / dcGroupDim)
                * ((ys + dcGroupDim - 1) / dcGroupDim)
            let entries = TOC.numEntries(
                numGroups: numG, numDcGroups: numDG,
                numPasses: Int(fh.passes.numPasses))
            let toc = try TOC.read(from: &r, numEntries: entries)
            let afterTocByte = r.position / 8
            let totalSectionBytes = toc.entrySizes.reduce(0) {
                $0 + Int($1)
            }
            let frameEndByte = afterTocByte + totalSectionBytes
            guard frameEndByte <= codestream.count else {
                throw DecoderError.notImplemented("decodeFrame: frame sections extend beyond the codestream")
            }
            if current == index {
                if fh.frameType == .dcFrame {
                    throw DecoderError.notImplemented("decodeFrame: DC frame outside a frame sequence; use decode for the complete image")
                }
                if index > 0, metadata.animation != nil, fh.encoding == .varDCT || fh.colorTransform == .xyb {
                    throw DecoderError.notImplemented("decodeFrame: lossy animation beyond the first image")
                }
                guard frameEndByte <= codestream.count else {
                    throw DecoderError.notImplemented("decodeFrame: frame extends past codestream end")
                }
                // Construct synthetic single-frame codestream:
                // prelude bytes + this frame's bytes.
                var synth = codestream.subdata(
                    in: 0..<preludeEndByte)
                synth.append(codestream.subdata(
                    in: frameStartByte..<frameEndByte))
                return try decode(synth)
            }
            if fh.isLast {
                throw DecoderError.notImplemented(
                    "decodeFrame: index \(index) out of range "
                    + "(codestream has \(current + 1) frames)")
            }
            try r.skip(bits: totalSectionBytes * 8)
            current += 1
        }
    }

    /// Helper for `decodeAll` — read just the SizeHeader's xsize /
    /// ysize from a codestream that's already passed signature.
    private func codestreamXSize(_ codestream: Data) -> UInt32 {
        var r = BitReader(codestream, startingAt: 16)
        return (try? SizeHeader.read(from: &r).xsize) ?? 0
    }
    private func codestreamYSize(_ codestream: Data) -> UInt32 {
        var r = BitReader(codestream, startingAt: 16)
        return (try? SizeHeader.read(from: &r).ysize) ?? 0
    }

    /// One-line summary of an animation frame. Returned by
    /// `inspectFrames(_:)`. Cheap to compute — no pixel decode.
    public struct FrameSummary: Sendable, Equatable {
        /// 0-based frame index.
        public let index: Int
        /// Frame duration in tps units (libjxl-default 100 tps,
        /// so 1 unit = 10 ms). Multi-frame codestreams carry this
        /// in each FrameHeader's animation block; single-frame
        /// codestreams return 0.
        public let duration: UInt32
        /// True only on the last frame; signals end of animation.
        public let isLast: Bool
        /// VarDCT (lossy) or Modular (lossless) per-frame encoding.
        public let encoding: FrameEncoding
        /// Number of TOC sections in this frame.
        public let sectionCount: Int
        /// Total byte size of this frame's section payloads
        /// (header + TOC + sections). Useful for estimating
        /// per-frame bitrate.
        public let totalSectionBytes: Int
    }

    /// Walk every frame's FrameHeader + TOC and return a per-frame
    /// summary. Same cost order as `countFrames(_:)` — no pixel
    /// decode. Useful for `jxl info --frames` and any caller that
    /// wants to inspect an animation's per-frame structure
    /// (durations, encoding, sizes) without paying for the full
    /// decode.
    public func inspectFrames(_ data: Data) throws -> [FrameSummary] {
        if MinimalLosslessCodec.isM0(data) {
            return [FrameSummary(
                index: 0, duration: 0, isLast: true,
                encoding: .modular, sectionCount: 0,
                totalSectionBytes: 0)]
        }
        let codestream: Data
        do {
            switch try parseJXLContainer(data) {
            case .naked:
                codestream = data
            case .iso(let boxes):
                codestream = try extractCodestream(
                    from: boxes, in: data)
            }
        } catch let e as ContainerError {
            throw DecoderError.container(e)
        }
        guard hasCodestreamSignature(codestream) else {
            throw DecoderError.missingSignature
        }
        var r = BitReader(codestream, startingAt: 16)
        let _ = try SizeHeader.read(from: &r)
        let metadata = try ImageMetadata.read(from: &r)
        try r.readCustomTransformData(
            xybEncoded: metadata.xybEncoded)
        try r.alignToByte()
        let ctx = FrameHeaderContext(
            xybEncoded: metadata.xybEncoded,
            numExtraChannels: metadata.extraChannels.count,
            haveAnimation: metadata.animation != nil,
            haveTimecodes:
                metadata.animation?.haveTimecodes ?? false)
        var out: [FrameSummary] = []
        while true {
            let fh = try FrameHeader.read(from: &r, context: ctx)
            let (xs, ys) = Self.codedFrameSize(
                fh, imageWidth: Int(codestreamXSize(codestream)),
                imageHeight: Int(codestreamYSize(codestream)))
            let groupDim = 128 << Int(fh.groupSizeShift)
            let dcGroupDim = groupDim << 3
            let numG = ((xs + groupDim - 1) / groupDim)
                * ((ys + groupDim - 1) / groupDim)
            let numDG = ((xs + dcGroupDim - 1) / dcGroupDim)
                * ((ys + dcGroupDim - 1) / dcGroupDim)
            let entries = TOC.numEntries(
                numGroups: numG, numDcGroups: numDG,
                numPasses: Int(fh.passes.numPasses))
            let toc = try TOC.read(from: &r, numEntries: entries)
            let total = toc.entrySizes.reduce(0) { $0 + Int($1) }
            out.append(FrameSummary(
                index: out.count,
                duration: fh.animationFrame.duration,
                isLast: fh.isLast,
                encoding: fh.encoding,
                sectionCount: toc.entrySizes.count,
                totalSectionBytes: total))
            try r.skip(bits: total * 8)
            if fh.isLast { break }
        }
        return out
    }

    /// Count the number of frames in a JPEG XL codestream without
    /// decoding any pixels — walks each frame's FrameHeader + TOC
    /// + skips the section bytes, stopping at the frame whose
    /// `isLast` flag is set. Returns `1` for any single-frame
    /// codestream (the usual case); returns the actual frame count
    /// for multi-frame animations.
    ///
    /// Cheap relative to `decode(_:)` or `decodeAll(_:)` —
    /// FrameHeader parsing is bits-only, TOC parsing is a few
    /// hundred bits, and section bytes are skipped without
    /// processing.
    public func countFrames(_ data: Data) throws -> Int {
        if MinimalLosslessCodec.isM0(data) { return 1 }
        let codestream: Data
        do {
            switch try parseJXLContainer(data) {
            case .naked:
                codestream = data
            case .iso(let boxes):
                codestream = try extractCodestream(
                    from: boxes, in: data)
            }
        } catch let e as ContainerError {
            throw DecoderError.container(e)
        }
        guard hasCodestreamSignature(codestream) else {
            throw DecoderError.missingSignature
        }
        var r = BitReader(codestream, startingAt: 16)
        let _ = try SizeHeader.read(from: &r)
        let metadata = try ImageMetadata.read(from: &r)
        try r.readCustomTransformData(
            xybEncoded: metadata.xybEncoded)
        try r.alignToByte()
        let ctx = FrameHeaderContext(
            xybEncoded: metadata.xybEncoded,
            numExtraChannels: metadata.extraChannels.count,
            haveAnimation: metadata.animation != nil,
            haveTimecodes:
                metadata.animation?.haveTimecodes ?? false)
        var count = 0
        while true {
            let fh = try FrameHeader.read(from: &r, context: ctx)
            let (xs, ys) = Self.codedFrameSize(
                fh, imageWidth: Int(codestreamXSize(codestream)),
                imageHeight: Int(codestreamYSize(codestream)))
            let groupDim = 128 << Int(fh.groupSizeShift)
            let dcGroupDim = groupDim << 3
            let numG = ((xs + groupDim - 1) / groupDim)
                * ((ys + groupDim - 1) / groupDim)
            let numDG = ((xs + dcGroupDim - 1) / dcGroupDim)
                * ((ys + dcGroupDim - 1) / dcGroupDim)
            let entries = TOC.numEntries(
                numGroups: numG, numDcGroups: numDG,
                numPasses: Int(fh.passes.numPasses))
            let toc = try TOC.read(from: &r, numEntries: entries)
            let total = toc.entrySizes.reduce(0) { $0 + Int($1) }
            try r.skip(bits: total * 8)
            count += 1
            if fh.isLast { break }
        }
        return count
    }

    /// End-to-end Modular pixel decode. Walks the container + headers,
    /// decodes the MA-tree + post-tree codebook, reads the
    /// GroupHeader(s), applies meta-transforms, decodes every
    /// wire-level channel rect, then runs the inverse transform chain
    /// via `applyInverseTransforms`.
    ///
    /// **Validated against cjxl/djxl** with exact pixel match for
    /// 32×32 RGB and 256×256 grayscale tests (single-group), plus
    /// 512×512 grayscale (multi-group): every pixel of every channel
    /// after inverse transforms equals the original input image —
    /// healthcare-grade byte equality.
    ///
    /// **Scope** of cjxl-emitted files this currently handles:
    ///   • Single-group OR multi-group Modular lossless frames
    ///     (`numPasses == 1`).
    ///   • RCT (any of the 42 spec types, full coverage in `SpecRCT`).
    ///   • Squeeze (with libjxl's `SmoothTendency` predictor).
    ///   • Tree-decode predictors 0..5 + 6 (Weighted via
    ///     `WeightedPredictor`) + 7..13 (Average / TopRight / etc.).
    ///   • rANS or prefix-coded entropy sections.
    ///
    /// **Out of scope** (yet): multi-pass progressive frames,
    /// Palette transform, LZ77 length-token expansion, TOC
    /// permutation, VarDCT frames. These will throw structured errors.
    ///
    package func decodeModular(_ data: Data) throws -> ModularImage {
        let frame = try decodeModularFrame(data)
        return ModularImage(
            channels: frame.planes.map {
                ModularChannel(width: frame.width, height: frame.height, pixels: $0)
            },
            nbMetaChannels: 0
        )
    }

    /// Decodes the first Modular frame of `data` (naked codestream or
    /// container) into integer planes through the reference-exact Modular
    /// core (issue #2332): palette/squeeze/RCT transforms, DC and AC group
    /// sections, passes, weighted predictor and reference properties.
    package func decodeModularFrame(
        _ data: Data, expectedSize: (width: Int, height: Int)? = nil,
        maximumSamples: Int = MDFrameDecoder.defaultMaximumSamples
    ) throws -> MDModularFrame {
        let codestream: Data
        do {
            switch try parseJXLContainer(data) {
            case .naked:
                codestream = data
            case .iso(let boxes):
                codestream = try extractCodestream(from: boxes, in: data)
            }
        } catch let e as ContainerError {
            throw DecoderError.container(e)
        }
        do {
            return try MDFrameDecoder.decodeCodestream(
                codestream, expectedSize: expectedSize, maximumSamples: maximumSamples)
        } catch let e as MDFrameError {
            switch e {
            case .missingSignature:
                throw DecoderError.missingSignature
            case .unsupported(let what):
                throw DecoderError.notImplemented("Modular decode: \(what)")
            default:
                throw DecoderError.notImplemented("Modular decode failed: \(e)")
            }
        }
    }

    /// Inspect frame-level structure of a JXL byte stream — the
    /// FrameHeader, TOC, and (for Modular frames) the MA-tree
    /// statistics. Best-effort: each field is `nil` if our reader
    /// hit an unsupported pattern at that layer or earlier. The
    /// fields-up-to-the-error path always works through whatever
    /// it could read.
    ///
    /// Useful as `jxl-tool info` material, and for diagnostics
    /// without running the full pixel decoder.
    public func inspectFrameStructure(_ data: Data) -> JXLFrameInspection {
        // Walk the headers we already know how to read.
        guard let inspection = try? inspect(data),
              let m = inspection.metadata else {
            return JXLFrameInspection(
                encoding: nil, isLast: nil, flags: nil,
                numPasses: nil, tocSizes: nil,
                hasModularTree: nil, modularTreeLeafCount: nil,
                usePrefixCode: nil
            )
        }
        // Re-position a reader at the start of the codestream and
        // walk past the headers.
        let codestream: Data
        if case .naked = inspection.form {
            codestream = data
        } else {
            // Container form — re-extract the codestream slice.
            guard let parsed = try? parseJXLContainer(data),
                  case let .iso(boxes) = parsed,
                  let cs = try? extractCodestream(from: boxes, in: data) else {
                return JXLFrameInspection(
                    encoding: nil, isLast: nil, flags: nil,
                    numPasses: nil, tocSizes: nil,
                    hasModularTree: nil, modularTreeLeafCount: nil,
                    usePrefixCode: nil
                )
            }
            codestream = cs
        }
        var r = BitReader(codestream, startingAt: 16)
        // Re-read SizeHeader + ImageMetadata to sync the reader.
        guard let _ = try? SizeHeader.read(from: &r),
              let _ = try? ImageMetadata.read(from: &r) else {
            return JXLFrameInspection(
                encoding: nil, isLast: nil, flags: nil,
                numPasses: nil, tocSizes: nil,
                hasModularTree: nil, modularTreeLeafCount: nil,
                usePrefixCode: nil
            )
        }
        _ = try? r.readCustomTransformData(xybEncoded: m.xybEncoded)
        // Consume the codestream ICC stream (§C.3.4) so the
        // FrameHeader/TOC read stays bit-aligned.
        if m.colorEncoding.useICC {
            _ = try? ICCStream.decode(from: &r)
        }
        try? r.alignToByte()
        let ctx = FrameHeaderContext(
            xybEncoded: m.xybEncoded,
            numExtraChannels: m.extraChannels.count,
            haveAnimation: m.animation != nil,
            haveTimecodes: m.animation?.haveTimecodes ?? false
        )
        guard let fh = try? FrameHeader.read(from: &r, context: ctx) else {
            return JXLFrameInspection(
                encoding: nil, isLast: nil, flags: nil,
                numPasses: nil, tocSizes: nil,
                hasModularTree: nil, modularTreeLeafCount: nil,
                usePrefixCode: nil
            )
        }
        // TOC entry count derives from FrameHeader.groupSizeShift +
        // image dims. libjxl `frame_dimensions.h::FrameDimensions::Set`:
        //   group_dim = 128 << group_size_shift
        //   dc_group_dim = group_dim * 8
        let (xs, ys) = Self.codedFrameSize(
            fh, imageWidth: Int(inspection.xsize), imageHeight: Int(inspection.ysize))
        let groupDim = 128 << Int(fh.groupSizeShift)
        let dcGroupDim = groupDim << 3
        let numG = ((xs + groupDim - 1) / groupDim)
                 * ((ys + groupDim - 1) / groupDim)
        let numDG = ((xs + dcGroupDim - 1) / dcGroupDim)
                  * ((ys + dcGroupDim - 1) / dcGroupDim)
        let entries = TOC.numEntries(
            numGroups: numG, numDcGroups: numDG,
            numPasses: Int(fh.passes.numPasses)
        )
        let toc = try? TOC.read(from: &r, numEntries: entries)
        let tocSizes = toc?.entrySizes

        // For Modular frames, try to walk into the MA-tree section.
        // Position the reader at section 0 (first TOC entry's start).
        // For multi-section frames the reader is already there;
        // alignment was performed by TOC.read.
        var hasTree: Bool? = nil
        var leafCount: Int? = nil
        var usePrefix: Bool? = nil
        if fh.encoding == .modular {
            // Skip matrices.DecodeDC bit (1 if default).
            guard let matrixDcDefault = try? r.readBit() else {
                return JXLFrameInspection(
                    encoding: fh.encoding, isLast: fh.isLast,
                    flags: fh.flags, numPasses: fh.passes.numPasses,
                    tocSizes: tocSizes,
                    hasModularTree: nil, modularTreeLeafCount: nil,
                    usePrefixCode: nil
                )
            }
            if !matrixDcDefault {
                // Skip 3 × F16.
                for _ in 0..<3 {
                    guard let _ = try? r.read(bits: 16) else { break }
                }
            }
            if let ht = try? r.readBit() {
                hasTree = ht
                if ht {
                    if let treeHdr = try? EntropySectionHeader.read(
                        from: &r, numContexts: 6
                    ),
                    let treeCB = try? MultiClusterCodebook.read(
                        from: &r, header: treeHdr
                    ) {
                        var treeStream = TokenStreamReader(
                            header: treeHdr, codebook: treeCB
                        )
                        if let tree = try? ModularTree.decode(
                            from: &r, stream: &treeStream
                        ) {
                            leafCount = tree.leafCount
                            // Try the post-tree section for usePrefix info.
                            if let postHdr = try? EntropySectionHeader.read(
                                from: &r, numContexts: tree.leafCount
                            ) {
                                usePrefix = postHdr.usePrefixCode
                            }
                        }
                    }
                }
            }
        }

        return JXLFrameInspection(
            encoding: fh.encoding, isLast: fh.isLast,
            flags: fh.flags, numPasses: fh.passes.numPasses,
            tocSizes: tocSizes,
            hasModularTree: hasTree, modularTreeLeafCount: leafCount,
            usePrefixCode: usePrefix
        )
    }

    /// Inspect a JXL byte stream's container and codestream-header
    /// metadata without decoding any pixels. This *is* implemented.
    public func inspect(_ data: Data) throws -> JXLInspection {
        let form: JXLInspection.Form
        var codestream: Data
        var boxTypes: [String] = []
        do {
            switch try parseJXLContainer(data) {
            case .naked:
                form = .naked
                codestream = data
            case .iso(let boxes):
                form = .container
                boxTypes = boxes.map { $0.type }
                codestream = try extractCodestream(from: boxes, in: data)
            }
        } catch let e as ContainerError {
            throw DecoderError.container(e)
        }

        guard hasCodestreamSignature(codestream) else {
            throw DecoderError.missingSignature
        }
        var reader = BitReader(codestream, startingAt: 16) // skip 2-byte signature
        do {
            let size = try SizeHeader.read(from: &reader)
            // Best-effort: try to read ImageMetadata. If the spec branches
            // we don't yet handle (e.g. exotic extensions) trip us up,
            // fall back to size-only inspection — that's still useful.
            let metadata: ImageMetadata?
            do {
                metadata = try ImageMetadata.read(from: &reader)
            } catch {
                metadata = nil
            }
            return JXLInspection(form: form, xsize: size.xsize, ysize: size.ysize,
                                 boxTypes: boxTypes, metadata: metadata)
        } catch let e as BitstreamError {
            throw DecoderError.bitstream(e)
        }
    }
}

extension BitReader {
    /// libjxl `image_metadata.cc::CustomTransformData::VisitFields` —
    /// read between `ImageMetadata` and the JumpToByteBoundary that
    /// precedes the FrameHeader. For non-XYB images with all defaults
    /// (the common case), the body is a single `all_default = 1` bit.
    /// We don't yet support custom upsampling weights, so anything but
    /// all_default trips us up and is rejected by the surrounding
    /// `try?` — but no reader-side regression for the common case.
    mutating func readCustomTransformData(xybEncoded: Bool) throws {
        _ = try CustomTransformData.read(from: &self, xybEncoded: xybEncoded)
    }
}
