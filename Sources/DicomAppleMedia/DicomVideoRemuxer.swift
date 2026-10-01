//
//  DicomVideoRemuxer.swift
//  DicomAppleMedia
//
//  Remuxes encapsulated DICOM video streams into AVFoundation-readable
//  containers without re-encoding the compressed video payload.
//

@preconcurrency import AVFoundation
import CoreMedia
import DicomCore
import Foundation
import UniformTypeIdentifiers

/// Remuxes compressed DICOM video into containers supported by Apple media frameworks.
public enum DicomVideoRemuxer {
    struct AccessUnit {
        let data: Data
        let isKeyFrame: Bool
    }

    private struct ParsedStream {
        let formatDescription: CMVideoFormatDescription
        let accessUnits: [AccessUnit]
        var presentationIndices: [Int]? = nil
    }

    private struct NALUnit {
        let data: Data
        let type: Int
    }

    /// Writes a playable container for an encapsulated DICOM video without re-encoding its frames.
    ///
    /// MPEG-2 elementary streams are wrapped in MPEG-2 transport stream containers. H.264 and HEVC
    /// Annex-B streams are written to ISO base media containers. Streams that already use an ISO base
    /// media container are copied byte-for-byte.
    ///
    /// - Parameters:
    ///   - video: The decoded DICOM video metadata and compressed elementary stream.
    ///   - frameRate: The positive, finite playback frame rate to use for sample timing.
    ///   - outputURL: The destination file URL. Any existing file must be removed by the caller.
    ///   - maximumOutputBytes: Maximum container size, checked before every output write.
    ///   - reserveOutputBytes: Reserves each block before writing, for a caller-owned aggregate budget.
    ///     May run on AVFoundation's callback thread. Throw to abort; retain reservations until the caller
    ///     removes or admits the output, including reservations made before a failed filesystem write.
    /// - Throws: ``DicomVideoRemuxError`` when the codec or elementary stream cannot be remuxed, or a file-system
    ///   error when the output cannot be written.
    public static func writePlayableContainer(
        for video: DicomVideo,
        frameRate: Double,
        to outputURL: URL,
        maximumOutputBytes: Int64 = 512 * 1024 * 1024,
        reserveOutputBytes: @escaping @Sendable (Int64) throws -> Void = { _ in }
    ) async throws {
        let roundedMPEGFrameDuration = (90_000 / frameRate).rounded()
        guard frameRate.isFinite, frameRate > 0,
              roundedMPEGFrameDuration.isFinite,
              roundedMPEGFrameDuration >= 1,
              roundedMPEGFrameDuration <= Double(0x1_FFFF_FFFF) else {
            throw DicomVideoRemuxError.invalidFrameRate
        }
        try Task.checkCancellation()
        let mpegFrameDuration = UInt64(roundedMPEGFrameDuration)
        let stream = video.streamData
        let codec = video.codec
        let fileManager = FileManager.default
        let outputExisted = fileManager.fileExists(atPath: outputURL.path)
        var activeWriter: AVAssetWriter?
        var activeOutput: DicomVideoRemuxOutput?
        do {
            let output = try DicomVideoRemuxOutput(url: outputURL, maximumBytes: maximumOutputBytes,
                                                   reserveBytes: reserveOutputBytes)
            activeOutput = output
            if isISOBaseMediaFile(stream) {
                try output.append(stream)
                try output.close()
                return
            }
            if codec == .mpeg2 {
                let parsed = try parseMPEG2(stream, width: video.columns, height: video.rows)
                try writeMPEG2TransportStream(accessUnits: parsed.accessUnits,
                                             frameDuration: mpegFrameDuration, output: output)
                try output.close()
                return
            }

            let parsed: ParsedStream
            switch codec {
            case .h264:
                parsed = try parseH264(stream)
            case .hevc:
                parsed = try parseHEVC(stream)
            case .mpeg2, .unknown:
                throw DicomVideoRemuxError.unsupportedCodec(codec)
            }
            guard !parsed.accessUnits.isEmpty else {
                throw DicomVideoRemuxError.noVideoFrames(codec: codec)
            }

            // Segment delivery suppresses AVAssetWriter's unbounded file/sidecar writes.
            let writer = AVAssetWriter(contentType: .mpeg4Movie)
            activeWriter = writer
            writer.delegate = output
            // CMAF preserves the zero-based presentation timeline when B-frame DTS starts before zero.
            writer.outputFileTypeProfile = .mpeg4CMAFCompliant
            writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
            writer.initialSegmentStartTime = .zero

            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: nil,
                sourceFormatHint: parsed.formatDescription
            )
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw DicomVideoRemuxError.writerFailed("compressed video input is not supported")
            }
            writer.add(input)

            guard writer.startWriting() else {
                throw writerError(writer)
            }
            writer.startSession(atSourceTime: .zero)

            let timescale: CMTimeScale = 60_000
            let frameDuration = CMTime(seconds: 1 / frameRate, preferredTimescale: timescale)
            let reorderDelay = parsed.presentationIndices?.enumerated().map { $0.offset - $0.element }.max() ?? 0

            for (index, accessUnit) in parsed.accessUnits.enumerated() {
                try Task.checkCancellation()
                try output.checkError()
                try await waitUntilReady(input: input, writer: writer, output: output)
                let presentationIndex = parsed.presentationIndices?[index] ?? index
                let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(clamping: presentationIndex))
                let decodingTime = parsed.presentationIndices == nil ? CMTime.invalid :
                    CMTimeMultiply(frameDuration, multiplier: Int32(clamping: index - reorderDelay))
                let sample = try makeSampleBuffer(
                    accessUnit: accessUnit,
                    formatDescription: parsed.formatDescription,
                    duration: frameDuration,
                    presentationTime: presentationTime,
                    decodingTime: decodingTime
                )
                guard input.append(sample) else {
                    try output.checkError()
                    throw writerError(writer)
                }
            }

            input.markAsFinished()
            await writer.finishWriting()
            try output.checkError()
            try Task.checkCancellation()
            guard writer.status == .completed else {
                throw writerError(writer)
            }
            try output.close()
        } catch {
            if activeWriter?.status == .writing {
                activeWriter?.cancelWriting()
            }
            try? activeOutput?.close()
            if !outputExisted {
                try? fileManager.removeItem(at: outputURL)
            }
            throw error
        }
    }

    private static func isISOBaseMediaFile(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        return data.subdata(in: 4..<8) == Data("ftyp".utf8)
    }

    private static func parseH264(_ stream: Data) throws -> ParsedStream {
        let units = try annexBNALUnits(stream, codec: .h264) { Int($0[0] & 0x1F) }
        guard let sps = units.first(where: { $0.type == 7 })?.data,
              let pps = units.first(where: { $0.type == 8 })?.data else {
            throw DicomVideoRemuxError.missingParameterSets(codec: .h264)
        }
        let accessUnits = groupH264AccessUnits(units)
        let presentationIndices = try h264ContainsBFrames(units) ? DicomH264PictureOrder.presentationIndices(
            nalUnits: units.map(\.data), accessUnitCount: accessUnits.count
        ) : nil
        let formatDescription = try h264FormatDescription(sps: sps, pps: pps)
        guard !accessUnits.isEmpty else {
            throw DicomVideoRemuxError.noVideoFrames(codec: .h264)
        }
        return ParsedStream(
            formatDescription: formatDescription, accessUnits: accessUnits, presentationIndices: presentationIndices
        )
    }

    private static func parseHEVC(_ stream: Data) throws -> ParsedStream {
        let units = try annexBNALUnits(stream, codec: .hevc) { bytes in
            guard bytes.count >= 2 else { return -1 }
            return Int((bytes[0] >> 1) & 0x3F)
        }
        guard let vps = units.first(where: { $0.type == 32 })?.data,
              let sps = units.first(where: { $0.type == 33 })?.data,
              let pps = units.first(where: { $0.type == 34 })?.data else {
            throw DicomVideoRemuxError.missingParameterSets(codec: .hevc)
        }
        guard !hevcContainsBFrames(units, pps: pps) else {
            throw DicomVideoRemuxError.frameReorderingUnsupported(codec: .hevc)
        }

        let formatDescription = try hevcFormatDescription(vps: vps, sps: sps, pps: pps)
        let accessUnits = groupHEVCAccessUnits(units)
        guard !accessUnits.isEmpty else {
            throw DicomVideoRemuxError.noVideoFrames(codec: .hevc)
        }
        return ParsedStream(formatDescription: formatDescription, accessUnits: accessUnits)
    }

    private static func parseMPEG2(_ stream: Data, width: Int, height: Int) throws -> ParsedStream {
        let bytes = [UInt8](stream)
        let pictureStarts = startCodeOffsets(in: bytes, code: 0x00)
        guard !pictureStarts.isEmpty else {
            throw DicomVideoRemuxError.noVideoFrames(codec: .mpeg2)
        }

        let sequenceAndGroupStarts = (
            startCodeOffsets(in: bytes, code: 0xB3) +
                startCodeOffsets(in: bytes, code: 0xB8)
        ).sorted()
        var accessUnitStarts = [0]
        if pictureStarts.count > 1 {
            for index in 1..<pictureStarts.count {
                let previousPictureStart = pictureStarts[index - 1]
                let pictureStart = pictureStarts[index]
                let leadingHeader = sequenceAndGroupStarts.first {
                    $0 > previousPictureStart && $0 < pictureStart
                }
                accessUnitStarts.append(leadingHeader ?? pictureStart)
            }
        }

        var accessUnits: [AccessUnit] = []
        for index in accessUnitStarts.indices {
            let start = accessUnitStarts[index]
            let end = index + 1 < accessUnitStarts.count ? accessUnitStarts[index + 1] : bytes.count
            guard end > start else { continue }
            let data = Data(bytes[start..<end])
            accessUnits.append(AccessUnit(data: data, isKeyFrame: mpeg2PictureIsKeyFrame(data)))
        }
        guard !accessUnits.contains(where: { mpeg2PictureCodingType($0.data) == 3 }) else {
            throw DicomVideoRemuxError.frameReorderingUnsupported(codec: .mpeg2)
        }

        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_MPEG2Video,
            width: Int32(clamping: width),
            height: Int32(clamping: height),
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw DicomVideoRemuxError.formatDescriptionFailed(status: status)
        }
        return ParsedStream(formatDescription: formatDescription, accessUnits: accessUnits)
    }

    private static func annexBNALUnits(
        _ stream: Data,
        codec: DicomVideoCodec,
        type: ([UInt8]) -> Int
    ) throws -> [NALUnit] {
        let bytes = [UInt8](stream)
        let starts = annexBStartCodes(in: bytes)
        guard !starts.isEmpty else {
            throw DicomVideoRemuxError.malformedElementaryStream(codec: codec)
        }

        var units: [NALUnit] = []
        for index in starts.indices {
            let payloadStart = starts[index].offset + starts[index].length
            var payloadEnd = index + 1 < starts.count ? starts[index + 1].offset : bytes.count
            while payloadEnd > payloadStart, bytes[payloadEnd - 1] == 0 {
                payloadEnd -= 1
            }
            guard payloadEnd > payloadStart else { continue }
            let payload = Array(bytes[payloadStart..<payloadEnd])
            units.append(NALUnit(data: Data(payload), type: type(payload)))
        }
        return units
    }

    private static func annexBStartCodes(in bytes: [UInt8]) -> [(offset: Int, length: Int)] {
        guard bytes.count >= 3 else { return [] }
        var result: [(offset: Int, length: Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if index + 3 < bytes.count,
               bytes[index] == 0,
               bytes[index + 1] == 0,
               bytes[index + 2] == 0,
               bytes[index + 3] == 1 {
                result.append((index, 4))
                index += 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                result.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }
        return result
    }

    private static func groupH264AccessUnits(_ units: [NALUnit]) -> [AccessUnit] {
        var result: [AccessUnit] = []
        var current: [NALUnit] = []
        var pending: [NALUnit] = []
        var hasVCL = false

        func flushCurrent() {
            guard hasVCL else { return }
            result.append(makeLengthPrefixedAccessUnit(current, keyFrameTypes: [5]))
            current.removeAll(keepingCapacity: true)
            hasVCL = false
        }

        for unit in units {
            switch unit.type {
            case 7, 8:
                continue
            case 9:
                flushCurrent()
                pending.removeAll(keepingCapacity: true)
            case 1...5:
                if hasVCL, h264FirstMacroblock(in: unit.data) == 0 {
                    flushCurrent()
                }
                if !hasVCL, !pending.isEmpty {
                    current.append(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                }
                current.append(unit)
                hasVCL = true
            default:
                if hasVCL {
                    current.append(unit)
                } else {
                    pending.append(unit)
                }
            }
        }
        flushCurrent()
        return result
    }

    private static func groupHEVCAccessUnits(_ units: [NALUnit]) -> [AccessUnit] {
        var result: [AccessUnit] = []
        var current: [NALUnit] = []
        var pending: [NALUnit] = []
        var hasVCL = false

        func flushCurrent() {
            guard hasVCL else { return }
            result.append(makeLengthPrefixedAccessUnit(current, keyFrameTypes: Set(16...23)))
            current.removeAll(keepingCapacity: true)
            hasVCL = false
        }

        for unit in units {
            switch unit.type {
            case 32, 33, 34:
                continue
            case 35:
                flushCurrent()
                pending.removeAll(keepingCapacity: true)
            case 0...31:
                if hasVCL, hevcIsFirstSlice(unit.data) {
                    flushCurrent()
                }
                if !hasVCL, !pending.isEmpty {
                    current.append(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                }
                current.append(unit)
                hasVCL = true
            default:
                if hasVCL {
                    current.append(unit)
                } else {
                    pending.append(unit)
                }
            }
        }
        flushCurrent()
        return result
    }

    private static func makeLengthPrefixedAccessUnit(
        _ units: [NALUnit],
        keyFrameTypes: Set<Int>
    ) -> AccessUnit {
        var data = Data()
        for unit in units {
            var length = UInt32(unit.data.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(unit.data)
        }
        return AccessUnit(data: data, isKeyFrame: units.contains { keyFrameTypes.contains($0.type) })
    }

    private static func h264FirstMacroblock(in data: Data) -> UInt64? {
        h264SliceHeader(in: data)?.firstMacroblock
    }

    private static func h264ContainsBFrames(_ units: [NALUnit]) -> Bool {
        units.contains { unit in
            guard (1...5).contains(unit.type), let header = h264SliceHeader(in: unit.data) else {
                return false
            }
            return header.sliceType % 5 == 1
        }
    }

    private static func h264SliceHeader(in data: Data) -> (firstMacroblock: UInt64, sliceType: UInt64)? {
        guard data.count > 1 else { return nil }
        let payload = removeEmulationPreventionBytes(Array(data.dropFirst()))
        var reader = ExpGolombBitReader(bytes: payload)
        guard let firstMacroblock = reader.readUnsignedExpGolomb(),
              let sliceType = reader.readUnsignedExpGolomb() else {
            return nil
        }
        return (firstMacroblock, sliceType)
    }

    private static func hevcIsFirstSlice(_ data: Data) -> Bool {
        guard data.count > 2 else { return false }
        let payload = removeEmulationPreventionBytes(Array(data.dropFirst(2)))
        return payload.first.map { ($0 & 0x80) != 0 } ?? false
    }

    private static func hevcContainsBFrames(_ units: [NALUnit], pps: Data) -> Bool {
        guard let extraHeaderBits = hevcExtraSliceHeaderBits(in: pps) else { return false }
        return units.contains { unit in
            guard (0...31).contains(unit.type),
                  let sliceType = hevcSliceType(
                    in: unit.data,
                    nalUnitType: unit.type,
                    extraHeaderBits: extraHeaderBits
                  ) else {
                return false
            }
            return sliceType == 0
        }
    }

    private static func hevcExtraSliceHeaderBits(in pps: Data) -> Int? {
        guard pps.count > 2 else { return nil }
        let payload = removeEmulationPreventionBytes(Array(pps.dropFirst(2)))
        var reader = ExpGolombBitReader(bytes: payload)
        guard reader.readUnsignedExpGolomb() != nil,
              reader.readUnsignedExpGolomb() != nil,
              reader.readBit() != nil,
              reader.readBit() != nil else {
            return nil
        }
        var result = 0
        for _ in 0..<3 {
            guard let bit = reader.readBit() else { return nil }
            result = (result << 1) | Int(bit)
        }
        return result
    }

    private static func hevcSliceType(
        in data: Data,
        nalUnitType: Int,
        extraHeaderBits: Int
    ) -> UInt64? {
        guard data.count > 2 else { return nil }
        let payload = removeEmulationPreventionBytes(Array(data.dropFirst(2)))
        var reader = ExpGolombBitReader(bytes: payload)
        guard reader.readBit() == 1 else { return nil }
        if (16...23).contains(nalUnitType), reader.readBit() == nil {
            return nil
        }
        guard reader.readUnsignedExpGolomb() != nil else { return nil }
        for _ in 0..<extraHeaderBits {
            guard reader.readBit() != nil else { return nil }
        }
        return reader.readUnsignedExpGolomb()
    }

    private static func removeEmulationPreventionBytes(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var zeroCount = 0
        for byte in bytes {
            if zeroCount >= 2, byte == 3 {
                zeroCount = 0
                continue
            }
            result.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
        }
        return result
    }

    static func h264FormatDescription(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsBase = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                var pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else {
            throw DicomVideoRemuxError.formatDescriptionFailed(status: status)
        }
        return description
    }

    static func hevcFormatDescription(vps: Data, sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var description: CMFormatDescription?
        let status = vps.withUnsafeBytes { vpsBytes in
            sps.withUnsafeBytes { spsBytes in
                pps.withUnsafeBytes { ppsBytes in
                    guard let vpsBase = vpsBytes.bindMemory(to: UInt8.self).baseAddress,
                          let spsBase = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                          let ppsBase = ppsBytes.bindMemory(to: UInt8.self).baseAddress else {
                        return kCMFormatDescriptionError_InvalidParameter
                    }
                    var pointers: [UnsafePointer<UInt8>] = [vpsBase, spsBase, ppsBase]
                    var sizes = [vps.count, sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointers.count,
                        parameterSetPointers: &pointers,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &description
                    )
                }
            }
        }
        guard status == noErr, let description else {
            throw DicomVideoRemuxError.formatDescriptionFailed(status: status)
        }
        return description
    }

    static func makeSampleBuffer(
        accessUnit: AccessUnit,
        formatDescription: CMVideoFormatDescription,
        duration: CMTime,
        presentationTime: CMTime,
        decodingTime: CMTime = .invalid
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: accessUnit.data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: accessUnit.data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw DicomVideoRemuxError.sampleBufferFailed(status: status)
        }

        status = accessUnit.data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: accessUnit.data.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw DicomVideoRemuxError.sampleBufferFailed(status: status)
        }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: decodingTime
        )
        var sampleSize = accessUnit.data.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw DicomVideoRemuxError.sampleBufferFailed(status: status)
        }
        if !accessUnit.isKeyFrame {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: true
            ) as? [NSMutableDictionary], let sampleAttachments = attachments.first else {
                throw DicomVideoRemuxError.sampleBufferFailed(status: kCMSampleBufferError_AllocationFailed)
            }
            sampleAttachments[kCMSampleAttachmentKey_NotSync as String] = true
        }
        return sampleBuffer
    }

    private static func waitUntilReady(
        input: AVAssetWriterInput, writer: AVAssetWriter, output: DicomVideoRemuxOutput
    ) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !input.isReadyForMoreMediaData {
            try output.checkError()
            if writer.status == .failed || writer.status == .cancelled {
                throw writerError(writer)
            }
            guard Date() < deadline else {
                throw DicomVideoRemuxError.writerFailed("timed out while writing video samples")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func writerError(_ writer: AVAssetWriter) -> DicomVideoRemuxError {
        .writerFailed(writer.error?.localizedDescription ?? "unknown writer error")
    }

    private static func startCodeOffsets(in bytes: [UInt8], code: UInt8) -> [Int] {
        guard bytes.count >= 4 else { return [] }
        var result: [Int] = []
        for index in 0...(bytes.count - 4) where
            bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1 && bytes[index + 3] == code {
            result.append(index)
        }
        return result
    }

    private static func mpeg2PictureIsKeyFrame(_ data: Data) -> Bool {
        mpeg2PictureCodingType(data) == 1
    }

    private static func mpeg2PictureCodingType(_ data: Data) -> UInt8? {
        let bytes = [UInt8](data)
        guard bytes.count >= 6 else { return nil }
        for index in 0...(bytes.count - 6) where
            bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1 && bytes[index + 3] == 0 {
            return (bytes[index + 5] >> 3) & 0x07
        }
        return nil
    }

    private static func writeMPEG2TransportStream(
        accessUnits: [AccessUnit],
        frameDuration: UInt64,
        output: DicomVideoRemuxOutput
    ) throws {
        let programMapPID = 0x1000
        let videoPID = 0x0100
        var continuityCounters: [Int: UInt8] = [:]

        try appendSDTPacket(continuityCounters: &continuityCounters, output: output)
        try appendPSIPacket(
            section: makePATSection(programMapPID: programMapPID),
            pid: 0,
            continuityCounters: &continuityCounters,
            output: output
        )
        try appendPSIPacket(
            section: makePMTSection(videoPID: videoPID),
            pid: programMapPID,
            continuityCounters: &continuityCounters,
            output: output
        )

        let timestampMask: UInt64 = 0x1_FFFF_FFFF
        for (index, accessUnit) in accessUnits.enumerated() {
            try Task.checkCancellation()
            let decodingTimestamp = (UInt64(index) &* frameDuration) & timestampMask
            let presentationTimestamp = (decodingTimestamp &+ frameDuration) & timestampMask
            let pes = makePESPacket(
                payload: accessUnit.data,
                presentationTimestamp: presentationTimestamp,
                decodingTimestamp: decodingTimestamp
            )
            try appendTransportPackets(
                payload: pes,
                pid: videoPID,
                presentationTimestamp: decodingTimestamp,
                isKeyFrame: accessUnit.isKeyFrame,
                continuityCounters: &continuityCounters,
                output: output
            )
        }
        try appendPSIPacket(
            section: makePATSection(programMapPID: programMapPID),
            pid: 0,
            continuityCounters: &continuityCounters,
            output: output
        )
        try appendPSIPacket(
            section: makePMTSection(videoPID: videoPID),
            pid: programMapPID,
            continuityCounters: &continuityCounters,
            output: output
        )
        while output.count < 188 * 32 {
            try output.append(nullTransportPacket())
        }
    }

    private static func makePATSection(programMapPID: Int) -> Data {
        var section = Data([
            0x00,
            0xB0, 0x0D,
            0x00, 0x01,
            0xC1,
            0x00,
            0x00,
            0x00, 0x01,
            UInt8(0xE0 | ((programMapPID >> 8) & 0x1F)),
            UInt8(programMapPID & 0xFF)
        ])
        appendMPEGCRC(to: &section)
        return section
    }

    private static func makePMTSection(videoPID: Int) -> Data {
        var section = Data([
            0x02,
            0xB0, 0x12,
            0x00, 0x01,
            0xC1,
            0x00,
            0x00,
            UInt8(0xE0 | ((videoPID >> 8) & 0x1F)),
            UInt8(videoPID & 0xFF),
            0xF0, 0x00,
            0x02,
            UInt8(0xE0 | ((videoPID >> 8) & 0x1F)),
            UInt8(videoPID & 0xFF),
            0xF0, 0x00
        ])
        appendMPEGCRC(to: &section)
        return section
    }

    private static func appendMPEGCRC(to data: inout Data) {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        data.append(UInt8((crc >> 24) & 0xFF))
        data.append(UInt8((crc >> 16) & 0xFF))
        data.append(UInt8((crc >> 8) & 0xFF))
        data.append(UInt8(crc & 0xFF))
    }

    private static func appendPSIPacket(
        section: Data,
        pid: Int,
        continuityCounters: inout [Int: UInt8],
        output: DicomVideoRemuxOutput
    ) throws {
        let continuityCounter = nextContinuityCounter(for: pid, counters: &continuityCounters)
        var packet = Data([
            0x47,
            UInt8(0x40 | ((pid >> 8) & 0x1F)),
            UInt8(pid & 0xFF),
            UInt8(0x10 | continuityCounter),
            0x00
        ])
        packet.append(section)
        if packet.count < 188 {
            packet.append(Data(repeating: 0xFF, count: 188 - packet.count))
        }
        try output.append(packet.prefix(188))
    }

    private static func appendSDTPacket(
        continuityCounters: inout [Int: UInt8],
        output: DicomVideoRemuxOutput
    ) throws {
        var section = Data([
            0x42,
            0xF0, 0x25,
            0x00, 0x01,
            0xC1,
            0x00,
            0x00,
            0xFF, 0x01,
            0xFF,
            0x00, 0x01,
            0xFC,
            0x80, 0x14,
            0x48, 0x12,
            0x01,
            0x06,
            0x46, 0x46, 0x6D, 0x70, 0x65, 0x67,
            0x09,
            0x53, 0x65, 0x72, 0x76, 0x69, 0x63, 0x65, 0x30, 0x31
        ])
        appendMPEGCRC(to: &section)
        try appendPSIPacket(
            section: section,
            pid: 0x0011,
            continuityCounters: &continuityCounters,
            output: output
        )
    }

    private static func makePESPacket(
        payload: Data,
        presentationTimestamp: UInt64,
        decodingTimestamp: UInt64
    ) -> Data {
        let pts = presentationTimestamp & 0x1_FFFF_FFFF
        let dts = decodingTimestamp & 0x1_FFFF_FFFF
        var packet = Data([
            0x00, 0x00, 0x01, 0xE0,
            0x00, 0x00,
            0x80,
            0xC0,
            0x0A
        ])
        packet.append(contentsOf: encodedPESClock(pts, prefix: 0x30))
        packet.append(contentsOf: encodedPESClock(dts, prefix: 0x10))
        packet.append(payload)
        return packet
    }

    private static func encodedPESClock(_ timestamp: UInt64, prefix: UInt8) -> [UInt8] {
        [
            UInt8(UInt64(prefix) | ((timestamp >> 29) & 0x0E) | 0x01),
            UInt8((timestamp >> 22) & 0xFF),
            UInt8(((timestamp >> 14) & 0xFE) | 0x01),
            UInt8((timestamp >> 7) & 0xFF),
            UInt8(((timestamp << 1) & 0xFE) | 0x01)
        ]
    }

    private static func appendTransportPackets(
        payload: Data,
        pid: Int,
        presentationTimestamp: UInt64,
        isKeyFrame: Bool,
        continuityCounters: inout [Int: UInt8],
        output: DicomVideoRemuxOutput
    ) throws {
        var offset = 0
        var isFirstPacket = true
        while offset < payload.count {
            try Task.checkCancellation()
            let includePCR = isFirstPacket
            let maximumPayload = includePCR ? 176 : 184
            let payloadCount = min(maximumPayload, payload.count - offset)
            let continuityCounter = nextContinuityCounter(for: pid, counters: &continuityCounters)
            let needsAdaptation = includePCR || payloadCount < 184
            let secondHeaderByte = UInt8((isFirstPacket ? 0x40 : 0x00) | ((pid >> 8) & 0x1F))
            var packet = Data([
                0x47,
                secondHeaderByte,
                UInt8(pid & 0xFF),
                UInt8((needsAdaptation ? 0x30 : 0x10) | continuityCounter)
            ])

            if needsAdaptation {
                let adaptationLength = 183 - payloadCount
                packet.append(UInt8(adaptationLength))
                if adaptationLength > 0 {
                    packet.append(includePCR ? (isKeyFrame ? 0x50 : 0x10) : 0x00)
                    if includePCR {
                        packet.append(contentsOf: pcrBytes(base: presentationTimestamp))
                    }
                    let usedAdaptationBytes = includePCR ? 7 : 1
                    if adaptationLength > usedAdaptationBytes {
                        packet.append(Data(repeating: 0xFF, count: adaptationLength - usedAdaptationBytes))
                    }
                }
            }

            packet.append(payload[offset..<(offset + payloadCount)])
            if packet.count < 188 {
                packet.append(Data(repeating: 0xFF, count: 188 - packet.count))
            }
            try output.append(packet.prefix(188))
            offset += payloadCount
            isFirstPacket = false
        }
    }

    private static func pcrBytes(base: UInt64) -> [UInt8] {
        let value = base & 0x1_FFFF_FFFF
        return [
            UInt8((value >> 25) & 0xFF),
            UInt8((value >> 17) & 0xFF),
            UInt8((value >> 9) & 0xFF),
            UInt8((value >> 1) & 0xFF),
            UInt8(((value & 0x01) << 7) | 0x7E),
            0x00
        ]
    }

    private static func nextContinuityCounter(for pid: Int, counters: inout [Int: UInt8]) -> UInt8 {
        let current = counters[pid, default: 0]
        counters[pid] = (current + 1) & 0x0F
        return current
    }

    private static func nullTransportPacket() -> Data {
        var packet = Data([0x47, 0x1F, 0xFF, 0x10])
        packet.append(Data(repeating: 0xFF, count: 184))
        return packet
    }

    private struct ExpGolombBitReader {
        let bytes: [UInt8]
        var bitIndex = 0

        mutating func readUnsignedExpGolomb() -> UInt64? {
            var leadingZeroes = 0
            while let bit = readBit(), bit == 0 {
                leadingZeroes += 1
                guard leadingZeroes < 64 else { return nil }
            }
            guard bitIndex > 0 else { return nil }

            var suffix: UInt64 = 0
            for _ in 0..<leadingZeroes {
                guard let bit = readBit() else { return nil }
                suffix = (suffix << 1) | UInt64(bit)
            }
            return ((UInt64(1) << UInt64(leadingZeroes)) - 1) + suffix
        }

        mutating func readBit() -> UInt8? {
            guard bitIndex < bytes.count * 8 else { return nil }
            let byte = bytes[bitIndex / 8]
            let shift = 7 - (bitIndex % 8)
            bitIndex += 1
            return (byte >> shift) & 1
        }
    }
}
