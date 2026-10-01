// MDFrameDecoder — decodes one Modular frame of a JPEG XL codestream
// (ISO/IEC 18181-1 Annex C and the frame/section layout of Annex E):
// the global section (dequant DC bit, global MA tree, small channels),
// the DC-group sections (channels with shift >= 3), the AC-group sections
// per pass with the downsampling brackets, the group rect stitching and
// the global inverse transforms, following the reference decoder
// (`ModularFrameDecoder::{DecodeGlobalInfo,DecodeGroup}` and
// `FrameDecoder::Process*` in libjxl). Issue #2332.

import Foundation

/// The decoded integer planes of a Modular frame.
package struct MDModularFrame: Sendable {
    package let width: Int
    package let height: Int
    /// 1 (grey) or 3 (colour) integer planes followed by the extra channels.
    package let planes: [[Int32]]
    package let colourChannels: Int
    package let metadata: ImageMetadata
    package let iccProfile: Data?
    package let frameHeader: FrameHeader
    /// `DequantMatrices::DCQuants()` of the frame (F16/128 when coded,
    /// else 1/4096, 1/512, 1/256); the XYB factors of lossy frames.
    package let dcQuant: (Float, Float, Float)
}

enum MDFrameError: Error, Sendable, CustomStringConvertible {
    case container(String)
    case missingSignature
    case header(String)
    case unsupported(String)
    case toc(String)
    case truncated(String)
    case stream(MDStreamError)
    case malformed(String)

    var description: String {
        switch self {
        case .container(let s): return "container: \(s)"
        case .missingSignature: return "missing JPEG XL codestream signature"
        case .header(let s): return "header: \(s)"
        case .unsupported(let s): return "unsupported: \(s)"
        case .toc(let s): return "table of contents: \(s)"
        case .truncated(let s): return "truncated codestream: \(s)"
        case .stream(let e): return "modular stream: \(e)"
        case .malformed(let s): return "malformed codestream: \(s)"
        }
    }
}

struct MDRect {
    let x0: Int
    let y0: Int
    let xsize: Int
    let ysize: Int

    /// `Rect(x0, y0, xsize, ysize, xend, yend)` of the reference decoder:
    /// the size is clamped so that the rect ends inside `xend`/`yend`.
    init(x0: Int, y0: Int, xsize: Int, ysize: Int, xend: Int, yend: Int) {
        self.x0 = x0
        self.y0 = y0
        self.xsize = x0 + xsize <= xend ? xsize : (xend > x0 ? xend - x0 : 0)
        self.ysize = y0 + ysize <= yend ? ysize : (yend > y0 ? yend - y0 : 0)
    }
}

enum MDFrameDecoder {
    static let numQuantTables = 17
    /// Bound on `width * height * channels` before any plane is allocated
    /// (512 Mi samples, 2 GiB of Int32 planes); callers may tighten it.
    static let defaultMaximumSamples = 1 << 29

    /// Decodes the first frame of a raw codestream (no container).
    /// `expectedSize` refuses a header whose dimensions differ from the
    /// caller's expectation before anything is allocated (decompression
    /// bombs); `maximumSamples` bounds the planes.
    static func decodeCodestream(
        _ codestream: Data, expectedSize: (width: Int, height: Int)? = nil,
        maximumSamples: Int = defaultMaximumSamples
    ) throws -> MDModularFrame {
        guard codestream.count >= 2, codestream[codestream.startIndex] == 0xFF,
              codestream[codestream.startIndex + 1] == 0x0A else {
            throw MDFrameError.missingSignature
        }
        var reader = BitReader(codestream, startingAt: 16)
        let size: SizeHeader
        let metadata: ImageMetadata
        var icc: Data?
        do {
            size = try SizeHeader.read(from: &reader)
            metadata = try ImageMetadata.read(from: &reader)
            try reader.readCustomTransformData(xybEncoded: metadata.xybEncoded)
            if metadata.colorEncoding.useICC {
                icc = try ICCStream.decode(from: &reader)
            }
            try reader.alignToByte()
        } catch {
            throw MDFrameError.header("\(error)")
        }
        if let expected = expectedSize, expected.width != Int(size.xsize) || expected.height != Int(size.ysize) {
            throw MDFrameError.malformed(
                "codestream dimensions \(size.xsize)x\(size.ysize) differ from the expected \(expected.width)x\(expected.height)")
        }
        // Bound the planes on the image header alone, before any frame parsing.
        let headerPixels = Int(size.xsize).multipliedReportingOverflow(by: Int(size.ysize))
        let headerChannels = max(1, metadata.colorEncoding.colorSpace == .grayscale ? 1 : 3) + metadata.extraChannels.count
        let headerSamples = headerPixels.partialValue.multipliedReportingOverflow(by: headerChannels)
        guard !headerPixels.overflow, !headerSamples.overflow, headerSamples.partialValue <= maximumSamples else {
            throw MDFrameError.unsupported(
                "\(size.xsize)x\(size.ysize) with \(headerChannels) channels exceeds the \(maximumSamples)-sample bound")
        }
        if metadata.preview != nil {
            throw MDFrameError.unsupported("preview frames")
        }
        let context = FrameHeaderContext(
            xybEncoded: metadata.xybEncoded,
            numExtraChannels: metadata.extraChannels.count,
            haveAnimation: metadata.animation != nil,
            haveTimecodes: metadata.animation?.haveTimecodes ?? false
        )
        let frameHeader: FrameHeader
        do { frameHeader = try FrameHeader.read(from: &reader, context: context) } catch {
            throw MDFrameError.header("frame header: \(error)")
        }
        return try decodeFrame(
            reader: &reader, frameHeader: frameHeader, metadata: metadata,
            xsize: Int(size.xsize), ysize: Int(size.ysize), iccProfile: icc, maximumSamples: maximumSamples
        )
    }

    /// Decodes the Modular frame whose header has just been read from
    /// `reader`.
    static func decodeFrame(
        reader: inout BitReader, frameHeader fh: FrameHeader, metadata: ImageMetadata,
        xsize: Int, ysize: Int, iccProfile: Data?, maximumSamples: Int = defaultMaximumSamples
    ) throws -> MDModularFrame {
        guard fh.encoding == .modular else { throw MDFrameError.unsupported("VarDCT frame") }
        guard fh.frameType == .regular || fh.frameType == .dcFrame else {
            throw MDFrameError.unsupported("frame type \(fh.frameType)")
        }
        if fh.frameType == .dcFrame {
            guard fh.dcLevel >= 1, fh.dcLevel <= 4 else { throw MDFrameError.malformed("dc_level \(fh.dcLevel)") }
        } else {
            guard fh.dcLevel == 0 else { throw MDFrameError.malformed("dc_level \(fh.dcLevel) on a regular frame") }
        }
        let refusedFlags: UInt64 = FrameFlag.noise.rawValue | FrameFlag.patches.rawValue
            | FrameFlag.splines.rawValue | FrameFlag.useDcFrame.rawValue
        guard fh.flags & refusedFlags == 0 else {
            throw MDFrameError.unsupported("frame features (flags 0x\(String(fh.flags, radix: 16)))")
        }
        guard fh.upsampling == 1, fh.extraChannelUpsampling.allSatisfy({ $0 == 1 }) else {
            throw MDFrameError.unsupported("upsampled frames")
        }
        guard !fh.customSizeOrOrigin else { throw MDFrameError.unsupported("frames with a custom size or origin") }
        switch fh.colorTransform {
        case .none, .xyb: break
        case .yCbCr: throw MDFrameError.unsupported("YCbCr modular frames")
        }
        if fh.colorTransform == .xyb {
            guard fh.loopFilter.epfIters == 0 else { throw MDFrameError.unsupported("XYB frame with EPF") }
            guard fh.blendingInfo.mode == .replace,
                  fh.extraChannelBlendingInfo.allSatisfy({ $0.mode == .replace }) else {
                throw MDFrameError.unsupported("XYB frame blending")
            }
        }
        let bits = Int(metadata.bitDepth.bitsPerSample)
        guard !metadata.bitDepth.floatingPoint else { throw MDFrameError.unsupported("floating-point samples") }
        guard bits >= 1, bits <= 31 else { throw MDFrameError.unsupported("\(bits)-bit samples") }
        guard xsize > 0, ysize > 0 else { throw MDFrameError.malformed("empty frame") }

        let isGray: Bool
        if metadata.colorEncoding.useICC, let icc = iccProfile {
            isGray = icc.count >= 20 && icc[icc.startIndex + 16] == 0x47 && icc[icc.startIndex + 17] == 0x52
                && icc[icc.startIndex + 18] == 0x41 && icc[icc.startIndex + 19] == 0x59
        } else {
            isGray = metadata.colorEncoding.colorSpace == .grayscale
        }
        // `DecodeGlobalInfo`: one colour channel only for grey images
        // without a colour transform; XYB frames always carry three.
        let nbChans = (isGray && fh.colorTransform == .none) ? 1 : 3
        let nbExtra = metadata.extraChannels.count
        let pixelCount = xsize.multipliedReportingOverflow(by: ysize)
        let sampleCount = pixelCount.partialValue.multipliedReportingOverflow(by: nbChans + nbExtra)
        guard !pixelCount.overflow, !sampleCount.overflow, sampleCount.partialValue <= maximumSamples else {
            throw MDFrameError.unsupported(
                "\(xsize)x\(ysize) with \(nbChans + nbExtra) channels exceeds the \(maximumSamples)-sample bound")
        }

        let groupDim = 128 << Int(fh.groupSizeShift)
        let dcGroupDim = groupDim << 3
        let numGroupsX = (xsize + groupDim - 1) / groupDim
        let numGroupsY = (ysize + groupDim - 1) / groupDim
        let numGroups = numGroupsX * numGroupsY
        let numDcGroupsX = (xsize + dcGroupDim - 1) / dcGroupDim
        let numDcGroupsY = (ysize + dcGroupDim - 1) / dcGroupDim
        let numDcGroups = numDcGroupsX * numDcGroupsY
        let numPasses = Int(fh.passes.numPasses)
        guard numPasses >= 1 else { throw MDFrameError.malformed("zero passes") }
        let tocEntries = TOC.numEntries(numGroups: numGroups, numDcGroups: numDcGroups, numPasses: numPasses)
        let toc: TOC
        do { toc = try TOC.read(from: &reader, numEntries: tocEntries) } catch {
            throw MDFrameError.toc("\(error)")
        }
        let singleSection = tocEntries == 1
        let sectionBase = reader.position / 8
        let totalBytes = reader.totalBits / 8
        var sectionStarts: [Int] = []
        var sectionEnds: [Int] = []
        for i in 0..<tocEntries {
            guard i < toc.offsets.count, i < toc.entrySizes.count,
                  let offset = Int(exactly: toc.offsets[i]), offset <= totalBytes,
                  let size = Int(exactly: toc.entrySizes[i]) else {
                throw MDFrameError.toc("section \(i) offset is out of range")
            }
            let start = sectionBase + offset
            let end = start + size
            guard end <= totalBytes else {
                throw MDFrameError.truncated("section \(i) ends at byte \(end) of \(totalBytes)")
            }
            sectionStarts.append(start)
            sectionEnds.append(end)
        }

        // Global section.
        var global = reader
        if !singleSection { global.seek(toBitPosition: sectionStarts[0] * 8) }
        let globalCode: MDGlobalCode?
        var full: ModularImage
        let globalHeader: GroupHeader
        let globalTransforms: [ModularTransform]
        var dcQuant: (Float, Float, Float) = (1.0 / 4096.0, 1.0 / 512.0, 1.0 / 256.0)
        do {
            // `DequantMatrices::DecodeDC`: F16 × 1/128 per channel.
            let dcDefault = try global.readBit()
            if !dcDefault {
                var values: [Float] = []
                for c in 0..<3 {
                    let v = halfToFloat(UInt16(try global.read(bits: 16))) * (1.0 / 128.0)
                    guard v >= 1e-8 else { throw MDFrameError.malformed("dc_quant[\(c)] is \(v)") }
                    values.append(v)
                }
                dcQuant = (values[0], values[1], values[2])
            }
            let hasTree = try global.readBit()
            if hasTree {
                let limit = min(1 << 22, 1024 + sampleCount.partialValue / 16)
                globalCode = try mdDecodeTreeAndCode(reader: &global, sizeLimit: limit)
            } else {
                globalCode = nil
            }
            full = ModularImage.fresh(xsize: xsize, ysize: ysize, nbColor: nbChans, nbExtra: nbExtra)
            var options = MDOptions()
            options.maxChanSize = groupDim
            options.groupDim = groupDim
            (globalHeader, globalTransforms) = try mdModularDecode(
                reader: &global, image: &full, groupId: 0, options: options,
                global: globalCode, bitDepth: bits, undoTransforms: false
            )
        } catch let e as MDStreamError {
            throw MDFrameError.stream(e)
        } catch let e as BitstreamError {
            throw MDFrameError.truncated("global section: \(e)")
        }
        var current = global

        // DC groups (channels with shift >= 3 that are larger than a group).
        for dcG in 0..<numDcGroups {
            var sectionReader = current
            if !singleSection { sectionReader.seek(toBitPosition: sectionStarts[1 + dcG] * 8) }
            let gx = dcG % numDcGroupsX
            let gy = dcG / numDcGroupsX
            let rect = (x0: gx * dcGroupDim, y0: gy * dcGroupDim, xsize: dcGroupDim, ysize: dcGroupDim)
            try decodeGroup(
                full: &full, rect: rect, reader: &sectionReader, minShift: 3, maxShift: 1000,
                streamId: 1 + numDcGroups + dcG, groupDim: groupDim, global: globalCode, bitDepth: bits
            )
            if singleSection { current = sectionReader }
        }

        // AC groups per pass.
        for pass in 0..<numPasses {
            let (minShift, maxShift) = downsamplingBracket(fh.passes, pass: pass)
            for g in 0..<numGroups {
                var sectionReader = current
                if !singleSection {
                    sectionReader.seek(toBitPosition: sectionStarts[2 + numDcGroups + pass * numGroups + g] * 8)
                }
                let gx = g % numGroupsX
                let gy = g / numGroupsX
                let rect = (x0: gx * groupDim, y0: gy * groupDim, xsize: groupDim, ysize: groupDim)
                try decodeGroup(
                    full: &full, rect: rect, reader: &sectionReader, minShift: minShift, maxShift: maxShift,
                    streamId: 1 + 3 * numDcGroups + numQuantTables + numGroups * pass + g,
                    groupDim: groupDim, global: globalCode, bitDepth: bits
                )
                if singleSection { current = sectionReader }
            }
        }

        do {
            try mdUndoTransforms(globalTransforms, image: &full, wpHeader: globalHeader.wpHeader, bitDepth: bits)
        } catch let e as MDTransformError {
            throw MDFrameError.stream(.transform(e))
        }
        guard full.channels.count == nbChans + nbExtra else {
            throw MDFrameError.malformed("\(full.channels.count) channels after the inverse transforms, expected \(nbChans + nbExtra)")
        }
        for (i, ch) in full.channels.enumerated() where ch.width != xsize || ch.height != ysize {
            throw MDFrameError.malformed("channel \(i) is \(ch.width)x\(ch.height) after the inverse transforms")
        }
        // Leave the reader at the end of the frame (the next frame header
        // starts at the byte after the last section).
        if let frameEnd = sectionEnds.max() { reader.seek(toBitPosition: frameEnd * 8) }
        return MDModularFrame(
            width: xsize, height: ysize, planes: full.channels.map(\.pixels), colourChannels: nbChans,
            metadata: metadata, iccProfile: iccProfile, frameHeader: fh, dcQuant: dcQuant
        )
    }

    /// `ModularImageToDecodedRect` for XYB frames: X = ch1·q0, Y = ch0·q1,
    /// B = (ch2 + ch0)·q2 ("XYB is encoded as YX(B−Y)").
    static func xybPlanes(_ frame: MDModularFrame) -> [[Float]] {
        precondition(frame.colourChannels == 3 && frame.planes.count >= 3)
        let count = frame.width * frame.height
        var x = [Float](repeating: 0, count: count)
        var y = [Float](repeating: 0, count: count)
        var b = [Float](repeating: 0, count: count)
        let q = frame.dcQuant
        let ch0 = frame.planes[0], ch1 = frame.planes[1], ch2 = frame.planes[2]
        for i in 0..<count {
            x[i] = Float(ch1[i]) * q.0
            y[i] = Float(ch0[i]) * q.1
            b[i] = (Float(ch2[i]) + Float(ch0[i])) * q.2
        }
        return [x, y, b]
    }

    /// `Passes::GetDownsamplingBracket`.
    static func downsamplingBracket(_ passes: Passes, pass: Int) -> (minShift: Int, maxShift: Int) {
        var maxShift = 2
        var minShift = 3
        let numPasses = Int(passes.numPasses)
        var i = 0
        while true {
            for j in 0..<Int(passes.numDownsample) where j < passes.lastPasses.count && j < passes.downsamples.count {
                if i == Int(passes.lastPasses[j]) {
                    switch passes.downsamples[j] {
                    case 8: minShift = 3
                    case 4: minShift = 2
                    case 2: minShift = 1
                    case 1: minShift = 0
                    default: break
                    }
                }
            }
            if i == numPasses - 1 { minShift = 0 }
            if i == pass { return (minShift, maxShift) }
            maxShift = minShift - 1
            i += 1
        }
    }

    /// `ModularFrameDecoder::DecodeGroup`.
    static func decodeGroup(
        full: inout ModularImage, rect: (x0: Int, y0: Int, xsize: Int, ysize: Int),
        reader: inout BitReader, minShift: Int, maxShift: Int, streamId: Int,
        groupDim: Int, global: MDGlobalCode?, bitDepth: Int
    ) throws {
        var gi = ModularImage(channels: [], nbMetaChannels: 0)
        var mapping: [(channel: Int, rect: MDRect)] = []
        var c = full.nbMetaChannels
        while c < full.channels.count {
            let fc = full.channels[c]
            if fc.width > groupDim || fc.height > groupDim { break }
            c += 1
        }
        while c < full.channels.count {
            let fc = full.channels[c]
            defer { c += 1 }
            let shift = min(fc.hshift, fc.vshift)
            if shift > maxShift || shift < minShift { continue }
            let r = MDRect(
                x0: rect.x0 >> fc.hshift, y0: rect.y0 >> fc.vshift,
                xsize: rect.xsize >> fc.hshift, ysize: rect.ysize >> fc.vshift,
                xend: fc.width, yend: fc.height
            )
            if r.xsize == 0 || r.ysize == 0 { continue }
            gi.channels.append(ModularChannel(width: r.xsize, height: r.ysize, hshift: fc.hshift, vshift: fc.vshift))
            mapping.append((c, r))
        }
        if gi.channels.isEmpty { return }
        do {
            try mdModularDecode(
                reader: &reader, image: &gi, groupId: streamId, options: MDOptions(),
                global: global, bitDepth: bitDepth, undoTransforms: true
            )
        } catch let e as MDStreamError {
            throw MDFrameError.stream(e)
        } catch let e as BitstreamError {
            throw MDFrameError.truncated("group section \(streamId): \(e)")
        }
        guard gi.channels.count == mapping.count else {
            throw MDFrameError.malformed("group section \(streamId) changed its channel count")
        }
        for (gic, entry) in mapping.enumerated() {
            let src = gi.channels[gic]
            guard src.width == entry.rect.xsize, src.height == entry.rect.ysize else {
                throw MDFrameError.malformed("group section \(streamId) changed a channel geometry")
            }
            let parentWidth = full.channels[entry.channel].width
            full.channels[entry.channel].pixels.withUnsafeMutableBufferPointer { dst in
                src.pixels.withUnsafeBufferPointer { s in
                    for ry in 0..<entry.rect.ysize {
                        let d = dst.baseAddress! + (entry.rect.y0 + ry) * parentWidth + entry.rect.x0
                        d.update(from: s.baseAddress! + ry * entry.rect.xsize, count: entry.rect.xsize)
                    }
                }
            }
        }
    }
}
