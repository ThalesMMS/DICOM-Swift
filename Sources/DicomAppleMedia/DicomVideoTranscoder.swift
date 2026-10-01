import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Foundation
import DicomCore

public enum DicomVideoTranscoder {
    public enum Profile: Sendable {
        case h264High, hevcMain
    }

    /// Apple-backed constant-cadence transcode. No audio or software encoder is provided.
    public static func transcode(_ video: DicomVideo, to profile: Profile,
                                 options: DicomVideoBuildOptions = .init(),
                                 maximumOutputBytes: Int = 256 * 1024 * 1024) async throws -> Data {
        try Task.checkCancellation()
        var options = options
        options.anatomicRegion = options.anatomicRegion ?? video.anatomicRegion
        guard options.anatomicRegion != nil else { throw DicomVideoAppleError.unsupportedProfile("missing-anatomic-region") }
        let timeline = try DicomVideoTimeline(video: video)
        try DicomVideoFrameDecoder.qualify(timeline)
        guard video.cine.multiplexedAudioChannels?.isEmpty != false,
              let duration = timeline.accessUnits.first?.duration,
              timeline.accessUnits.allSatisfy({ $0.duration == duration }) else {
            throw DicomVideoAppleError.unsupportedProfile("constant-cadence-no-audio")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dicom-video-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.mp4")
        let outputURL = directory.appendingPathComponent("output.mp4")
        let rate = Double(timeline.timescale!) / Double(duration)
        try await DicomVideoRemuxer.writePlayableContainer(for: video, frameRate: rate, to: inputURL)
        let asset = AVURLAsset(url: inputURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw DicomVideoAppleError.incompleteOutput }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let codec: AVVideoCodecType = profile == .h264High ? .h264 : .hevc
        let level = profile == .h264High ? AVVideoProfileLevelH264HighAutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel as String
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: codec,
            AVVideoWidthKey: video.columns, AVVideoHeightKey: video.rows,
            AVVideoPixelAspectRatioKey: [AVVideoPixelAspectRatioHorizontalSpacingKey: 1, AVVideoPixelAspectRatioVerticalSpacingKey: 1],
            AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: level, AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalKey: 48, AVVideoAverageBitRateKey: 1_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else { throw DicomVideoAppleError.incompleteOutput }
        writer.startSession(atSourceTime: .zero)
        var completed = false
        defer { if !completed { reader.cancelReading(); writer.cancelWriting() } }
        let scale = CMTimeScale(timeline.timescale!)
        var frameCount = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw DicomVideoAppleError.incompleteOutput }
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw DicomVideoAppleError.incompleteOutput }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frameCount) * duration, timescale: scale)) else {
                throw DicomVideoAppleError.incompleteOutput
            }
            frameCount += 1
            if let size = try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumOutputBytes {
                throw DicomVideoAppleError.outputLimitExceeded
            }
        }
        guard reader.status == .completed, frameCount == timeline.accessUnits.count else { throw DicomVideoAppleError.incompleteOutput }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw DicomVideoAppleError.incompleteOutput }
        completed = true
        try Task.checkCancellation()
        let encoded = try await elementaryStream(outputURL, hevc: profile == .hevcMain, maximumBytes: maximumOutputBytes)
        let syntax: DicomTransferSyntax = profile == .h264High ? .mpeg4AVCH264HighProfileLevel41 : .hevcH265MainProfileLevel51
        let pixels = try DicomVideoPixelData(streamData: encoded, transferSyntax: syntax, columns: video.columns,
            rows: video.rows, numberOfFrames: frameCount, frameTimeMilliseconds: 1000 / rate)
        var cine = video.cine
        cine.frameTimeMilliseconds = 1000 / rate
        cine.frameTimeVectorMilliseconds = []
        cine.multiplexedAudioChannels = nil
        var data = try DicomVideoBuilder.dataSet(video: pixels, options: options, cine: cine)
        // Required common envelope attributes that are not supplied in build options.
        for (tag, vr) in [(0x00100030, DicomVR.DA), (0x00100040, .CS), (0x00080050, .SH),
                          (0x00080090, .PN), (0x00080070, .LO), (0x00200020, .CS),
                          (0x00100010, .PN), (0x00100020, .LO), (0x00080020, .DA), (0x00080030, .TM),
                          (0x00200010, .SH), (0x00200011, .IS), (0x00200013, .IS)] where !data.contains(tag) {
            data = data.setting(.init(tag: tag, vr: vr, value: .strings([])))
        }
        data = data.setting(.init(tag: 0x00280034, vr: .IS, value: .strings(["1", "1"])))
        data = data.setting(.init(tag: 0x00400555, vr: .SQ, value: .sequence([])))
        return try DicomDataSetWriter.part10Data(from: data, options: .init(transferSyntax: syntax,
            mediaStorageSOPClassUID: options.kind.storageSOPClassUID, mediaStorageSOPInstanceUID: data.string(for: 0x00080018)))
    }

    private static func elementaryStream(_ url: URL, hevc: Bool, maximumBytes: Int) async throws -> Data {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw DicomVideoAppleError.incompleteOutput }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw DicomVideoAppleError.incompleteOutput }
        defer { reader.cancelReading() }
        var stream = Data()
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else {
                throw DicomVideoAppleError.incompleteOutput
            }
            var header: Int32 = 0
            if stream.isEmpty {
                var count = 0
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                func parameter(_ index: Int) -> OSStatus {
                    if hevc {
                        return CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                            parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &header)
                    }
                    return CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                        parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                        parameterSetCountOut: &count, nalUnitHeaderLengthOut: &header)
                }
                guard parameter(0) == noErr, count > 0 else { throw DicomVideoAppleError.incompleteOutput }
                for index in 0..<count {
                    guard parameter(index) == noErr, let pointer else { throw DicomVideoAppleError.incompleteOutput }
                    stream.append(contentsOf: [0, 0, 0, 1]); stream.append(pointer, count: size)
                }
            } else { header = 4 }
            guard header == 4 else { throw DicomVideoAppleError.unsupportedProfile("four-byte-NAL-lengths") }
            let length = CMBlockBufferGetDataLength(block)
            guard length <= maximumBytes - stream.count else { throw DicomVideoAppleError.outputLimitExceeded }
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == noErr else { throw DicomVideoAppleError.codecFailure(status) }
            var cursor = 0
            while cursor < bytes.count {
                guard cursor + 4 <= bytes.count else { throw DicomVideoAppleError.incompleteOutput }
                let count = bytes[cursor..<cursor + 4].reduce(0) { $0 << 8 | Int($1) }
                cursor += 4
                guard count > 0, count <= bytes.count - cursor else { throw DicomVideoAppleError.incompleteOutput }
                stream.append(contentsOf: [0, 0, 0, 1]); stream.append(bytes[cursor..<cursor + count]); cursor += count
            }
        }
        guard reader.status == .completed else { throw DicomVideoAppleError.incompleteOutput }
        return stream
    }
}
