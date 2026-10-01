import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import DicomCore

public enum DicomVideoAppleError: Error, Equatable, Sendable {
    case unsupportedProfile(String)
    case codecFailure(Int32)
    case incompleteOutput
    case outputLimitExceeded
}

public struct DicomVideoDecodedFrame: @unchecked Sendable {
    /// Immutable after publication. BGRA bytes omit CoreVideo row padding.
    public let pixelBuffer: CVPixelBuffer
    public let bgra: Data
    public let width: Int
    public let height: Int
    public let presentationIndex: Int
    public let presentationTime: CMTime
}

public enum DicomVideoFrameDecoder {
    /// Progressive 8-bit 4:2:0 H.264 Main/High POC-0 and HEVC Main closed IDR streams.
    /// Compressed samples are submitted in decode order; output is returned in presentation order.
    public static func decode(_ video: DicomVideo, maximumOutputBytes: Int = 256 * 1024 * 1024) async throws -> [DicomVideoDecodedFrame] {
        try Task.checkCancellation()
        let timeline = try DicomVideoTimeline(video: video)
        try qualify(timeline)
        let description = timeline.description
        let width = description.width!, height = description.height!
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (frameBytes, frameOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        let (totalBytes, totalOverflow) = frameBytes.multipliedReportingOverflow(by: timeline.accessUnits.count)
        guard !rowOverflow, !frameOverflow, !totalOverflow, totalBytes <= maximumOutputBytes else {
            throw DicomVideoAppleError.outputLimitExceeded
        }
        let format = try formatDescription(description)
        let collector = Collector(maximumBytes: maximumOutputBytes)
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref, _, status, _, image, pts, _ in
            guard let ref else { return }
            Unmanaged<Collector>.fromOpaque(ref).takeUnretainedValue().receive(status, image, pts)
        }, decompressionOutputRefCon: Unmanaged.passUnretained(collector).toOpaque())
        var created: VTDecompressionSession?
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height]
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &created)
        guard status == noErr, let session = created else { throw DicomVideoAppleError.codecFailure(status) }
        defer { VTDecompressionSessionInvalidate(session) }
        let scale = CMTimeScale(timeline.timescale!)
        for unit in timeline.accessUnits {
            try Task.checkCancellation()
            var payload = Data()
            for nal in description.nalUnits where unit.byteRange.contains(nal.byteRange.lowerBound) {
                if video.codec == .h264 && [7, 8, 9].contains(nal.type) { continue }
                if video.codec == .hevc && [32, 33, 34, 35].contains(nal.type) { continue }
                var length = UInt32(nal.payload.count).bigEndian
                withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
                payload.append(nal.payload)
            }
            let sample = try DicomVideoRemuxer.makeSampleBuffer(accessUnit: .init(data: payload, isKeyFrame: unit.isKeyFrame),
                formatDescription: format, duration: CMTime(value: unit.duration!, timescale: scale),
                presentationTime: CMTime(value: unit.pts!, timescale: scale),
                decodingTime: CMTime(value: unit.dts!, timescale: scale))
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression], frameRefcon: nil, infoFlagsOut: nil)
            guard status == noErr else { throw DicomVideoAppleError.codecFailure(status) }
        }
        var finish = VTDecompressionSessionFinishDelayedFrames(session)
        if finish == noErr { finish = VTDecompressionSessionWaitForAsynchronousFrames(session) }
        guard finish == noErr else { throw DicomVideoAppleError.codecFailure(finish) }
        try Task.checkCancellation()
        let output = try collector.result()
        guard output.count == timeline.accessUnits.count else { throw DicomVideoAppleError.incompleteOutput }
        return output.enumerated().map { index, value in
            DicomVideoDecodedFrame(pixelBuffer: value.0, bgra: value.1, width: width, height: height,
                presentationIndex: index, presentationTime: value.2)
        }
    }

    static func qualify(_ timeline: DicomVideoTimeline) throws {
        let d = timeline.description
        guard d.codec == .h264 || d.codec == .hevc, d.bitDepth == 8, d.chromaBitDepth == 8, d.chromaFormat == 1,
              d.frameMbsOnly == true, d.closedGOP == true,
              let scale = timeline.timescale, scale > 0, scale <= Int32.max,
              timeline.accessUnits.allSatisfy({ $0.pts != nil && $0.dts != nil && ($0.duration ?? 0) > 0 }),
              !timeline.diagnostics.contains(where: { $0.code == .frameCountMismatch }),
              !d.limitations.contains("multi-slice"), !d.limitations.contains("HEVC-multilayer") else {
            throw DicomVideoAppleError.unsupportedProfile("progressive-8bit-420-closed-IDR-known-timing")
        }
        if d.codec == .h264, ![77, 100].contains(d.profileIDC ?? -1) {
            throw DicomVideoAppleError.unsupportedProfile("H264-Main-High-POC0")
        }
        if d.codec == .hevc, d.profileIDC != 1 || d.accessUnits.contains(where: { $0.sliceType == "B" }) {
            throw DicomVideoAppleError.unsupportedProfile("HEVC-Main-IP-only")
        }
    }

    static func formatDescription(_ d: DicomVideoStreamDescription) throws -> CMVideoFormatDescription {
        func parameter(_ type: Int) throws -> Data {
            guard let value = d.nalUnits.first(where: { $0.type == type }) else { throw DicomVideoAppleError.incompleteOutput }
            return value.payload
        }
        if d.codec == .h264 {
            return try DicomVideoRemuxer.h264FormatDescription(sps: parameter(7), pps: parameter(8))
        }
        return try DicomVideoRemuxer.hevcFormatDescription(vps: parameter(32), sps: parameter(33), pps: parameter(34))
    }

    private final class Collector: @unchecked Sendable {
        let lock = NSLock()
        let maximumBytes: Int
        var frames: [(CVPixelBuffer, Data, CMTime)] = []
        var error: DicomVideoAppleError?
        var byteCount = 0

        init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

        func receive(_ status: OSStatus, _ image: CVPixelBuffer?, _ pts: CMTime) {
            lock.lock(); defer { lock.unlock() }
            guard error == nil else { return }
            guard status == noErr, let image else { error = .codecFailure(status); return }
            guard CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA else {
                error = .unsupportedProfile("BGRA-output"); return
            }
            let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
            let count = width * height * 4
            guard count <= maximumBytes - byteCount else { error = .outputLimitExceeded; return }
            guard CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else {
                error = .incompleteOutput; return
            }
            defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(image) else { error = .incompleteOutput; return }
            var data = Data(capacity: count)
            for row in 0..<height {
                data.append(base.advanced(by: row * CVPixelBufferGetBytesPerRow(image)).assumingMemoryBound(to: UInt8.self), count: width * 4)
            }
            byteCount += count
            frames.append((image, data, pts))
        }

        func result() throws -> [(CVPixelBuffer, Data, CMTime)] {
            lock.lock(); defer { lock.unlock() }
            if let error { throw error }
            return frames.sorted { CMTimeCompare($0.2, $1.2) < 0 }
        }
    }
}
