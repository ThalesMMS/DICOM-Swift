import Foundation

/// PS3.3 C.7.6.5. Vector values are increments, beginning with zero.
public struct DicomVideoCine: Equatable, Sendable {
    public struct AudioChannel: Equatable, Sendable {
        public var identificationCode: Int
        public var mode: String
        public var source: DicomDataSet

        public init(identificationCode: Int, mode: String, source: DicomDataSet) {
            self.identificationCode = identificationCode
            self.mode = mode
            self.source = source
        }
    }
    public var preferredPlaybackSequencing: Int?
    public var frameTimeMilliseconds: Double?
    public var startTrim: Int?
    public var stopTrim: Int?
    public var recommendedDisplayFrameRate: Int?
    public var cineRate: Int?
    public var frameDelayMilliseconds: Double?
    public var imageTriggerDelayMilliseconds: Double?
    public var effectiveDurationSeconds: Double?
    public var actualFrameDurationMilliseconds: Int?
    public var frameTimeVectorMilliseconds: [Double] = []
    /// nil means absent; an empty array preserves a present Type 2C sequence.
    public var multiplexedAudioChannels: [AudioChannel]?

    public init() {}

    public init(dataSet: DicomDataSet) {
        preferredPlaybackSequencing = dataSet.int(for: .preferredPlaybackSequencing)
        frameTimeMilliseconds = dataSet.float(for: .frameTime)
        startTrim = dataSet.int(for: .startTrim)
        stopTrim = dataSet.int(for: .stopTrim)
        recommendedDisplayFrameRate = dataSet.int(for: .recommendedDisplayFrameRate)
        cineRate = dataSet.int(for: .cineRate)
        frameDelayMilliseconds = dataSet.float(for: .frameDelay)
        imageTriggerDelayMilliseconds = dataSet.float(for: .imageTriggerDelay)
        effectiveDurationSeconds = dataSet.float(for: .effectiveDuration)
        actualFrameDurationMilliseconds = dataSet.int(for: .actualFrameDuration)
        frameTimeVectorMilliseconds = dataSet.floats(for: .frameTimeVector)
        if dataSet.contains(.multiplexedAudioChannelsDescriptionCodeSequence) {
            multiplexedAudioChannels = dataSet.sequenceItems(for: .multiplexedAudioChannelsDescriptionCodeSequence).map {
                AudioChannel(identificationCode: $0.dataSet.int(for: .channelIdentificationCode) ?? 0,
                    mode: $0.dataSet.string(for: .channelMode) ?? "",
                    source: $0.dataSet.sequenceItems(for: .channelSourceSequence).first?.dataSet ?? .init(elements: []))
            }
        }
    }

    public func applying(to dataSet: DicomDataSet) throws -> DicomDataSet {
        let numberOfFrames = dataSet.int(for: .numberOfFrames)
        if !frameTimeVectorMilliseconds.isEmpty, let numberOfFrames,
           frameTimeVectorMilliseconds.count != numberOfFrames {
            throw DicomVideoError.invalidFrameTiming
        }
        guard frameTimeVectorMilliseconds.isEmpty ||
                (frameTimeVectorMilliseconds.first == 0 && frameTimeVectorMilliseconds.dropFirst().allSatisfy({ $0.isFinite && $0 > 0 })) else {
            throw DicomVideoError.invalidFrameTiming
        }
        let integerStrings = [startTrim, stopTrim, recommendedDisplayFrameRate, cineRate, actualFrameDurationMilliseconds]
        guard integerStrings.compactMap({ $0 }).allSatisfy({ Int32(exactly: $0) != nil }) else {
            throw DicomVideoError.invalidFrameTiming
        }
        var result = dataSet
        if let value = preferredPlaybackSequencing {
            guard let value = UInt16(exactly: value) else { throw DicomVideoError.invalidFrameTiming }
            result = result.setting(.init(tag: DicomTag.preferredPlaybackSequencing.rawValue, vr: .US, value: .unsignedIntegers([UInt(value)])))
        }
        if let value = frameTimeMilliseconds {
            guard value.isFinite, value > 0 || (value == 0 && numberOfFrames == 1) else {
                throw DicomVideoError.invalidFrameTiming
            }
            result = result.setting(.init(tag: DicomTag.frameTime.rawValue, vr: .DS, value: .strings([String(format: "%.12g", Double(value))])))
        }
        if let value = startTrim {
            result = result.setting(.init(tag: DicomTag.startTrim.rawValue, vr: .IS, value: .strings([String(value)])))
        }
        if let value = stopTrim {
            result = result.setting(.init(tag: DicomTag.stopTrim.rawValue, vr: .IS, value: .strings([String(value)])))
        }
        if let value = recommendedDisplayFrameRate {
            result = result.setting(.init(tag: DicomTag.recommendedDisplayFrameRate.rawValue, vr: .IS, value: .strings([String(value)])))
        }
        if let value = cineRate {
            result = result.setting(.init(tag: DicomTag.cineRate.rawValue, vr: .IS, value: .strings([String(value)])))
        }
        if let value = frameDelayMilliseconds {
            guard value.isFinite else { throw DicomVideoError.invalidFrameTiming }
            result = result.setting(.init(tag: DicomTag.frameDelay.rawValue, vr: .DS, value: .strings([String(format: "%.12g", Double(value))])))
        }
        if let value = imageTriggerDelayMilliseconds {
            guard value.isFinite else { throw DicomVideoError.invalidFrameTiming }
            result = result.setting(.init(tag: DicomTag.imageTriggerDelay.rawValue, vr: .DS, value: .strings([String(format: "%.12g", Double(value))])))
        }
        if let value = effectiveDurationSeconds {
            guard value.isFinite else { throw DicomVideoError.invalidFrameTiming }
            result = result.setting(.init(tag: DicomTag.effectiveDuration.rawValue, vr: .DS, value: .strings([String(format: "%.12g", Double(value))])))
        }
        if let value = actualFrameDurationMilliseconds {
            result = result.setting(.init(tag: DicomTag.actualFrameDuration.rawValue, vr: .IS, value: .strings([String(value)])))
        }
        if !frameTimeVectorMilliseconds.isEmpty {
            result = result.setting(.init(tag: DicomTag.frameTimeVector.rawValue, vr: .DS,
                value: .strings(frameTimeVectorMilliseconds.map { String(format: "%.12g", $0) })))
        }
        let pointer: DicomTag? = !frameTimeVectorMilliseconds.isEmpty ? .frameTimeVector :
            (frameTimeMilliseconds != nil ? .frameTime : nil)
        if let pointer {
            result = result.setting(.init(tag: DicomTag.frameIncrementPointer.rawValue, vr: .AT, value: .unsignedIntegers([UInt(pointer.rawValue)])))
        }
        if let channels = multiplexedAudioChannels {
            result = result.setting(.init(tag: DicomTag.multiplexedAudioChannelsDescriptionCodeSequence.rawValue, vr: .SQ, value: .sequence(try channels.map { channel in
                guard let code = UInt16(exactly: channel.identificationCode) else { throw DicomVideoError.invalidFrameTiming }
                return .init(dataSet: .init(elements: [
                    .init(tag: DicomTag.channelIdentificationCode.rawValue, vr: .US, value: .unsignedIntegers([UInt(code)])),
                    .init(tag: DicomTag.channelMode.rawValue, vr: .CS, value: .strings([channel.mode])),
                    .init(tag: DicomTag.channelSourceSequence.rawValue, vr: .SQ, value: .sequence([.init(dataSet: channel.source)]))
                ]))
            })))
        }
        return result
    }
}
