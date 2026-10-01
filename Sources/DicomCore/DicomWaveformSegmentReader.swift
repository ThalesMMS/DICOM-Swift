import Foundation
import DicomObjects

public struct DicomWaveformSegmentReader: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case unknownGroup, unknownChannel, invalidRange, sampleLimit, byteLimit, invalidTimeRange
    }
    public struct ChannelSamples: Equatable, Sendable {
        /// One-based Channel Definition Sequence ordinal, not equipment channel number.
        public let channel: Int
        public let rawValues: [Int]
        public let timeSeries: DicomWaveformTimeSeries
    }
    public let index: DicomWaveformSourceIndex
    public let maximumSampleCount: Int
    public let maximumReadBytes: Int
    private let source: DicomByteSource

    public init(source: DicomByteSource, index: DicomWaveformSourceIndex,
                maximumSampleCount: Int = 1_000_000, maximumReadBytes: Int = 16 * 1024 * 1024) throws {
        guard source.revision == index.sourceRevision else { throw DicomByteSource.Failure.changed }
        self.source = source; self.index = index
        self.maximumSampleCount = max(0, maximumSampleCount); self.maximumReadBytes = max(0, maximumReadBytes)
    }

    public static func open(source: DicomByteSource, maximumSampleCount: Int = 1_000_000,
                            maximumReadBytes: Int = 16 * 1024 * 1024) async throws -> Self {
        let index = try await DicomWaveformSourceIndex.build(from: source)
        return try .init(source: source, index: index, maximumSampleCount: maximumSampleCount, maximumReadBytes: maximumReadBytes)
    }

    /// Group/channel selectors are one-based; sampleRange is zero-based and half-open.
    /// One read covers exactly the requested interleaved sample points, including the
    /// other channels at those points. No bytes outside that window are requested.
    public func samples(group: Int, channels: [Int], sampleRange: Range<Int>) async throws -> [ChannelSamples] {
        try await source.checkOpen()
        let indexed = try indexedGroup(group)
        let metadata = indexed.metadata
        guard !channels.isEmpty, Set(channels).count == channels.count,
              channels.allSatisfy({ $0 > 0 && $0 <= metadata.numberOfChannels }) else { throw Failure.unknownChannel }
        guard sampleRange.lowerBound >= 0, sampleRange.upperBound <= indexed.numberOfSamples else { throw Failure.invalidRange }
        guard sampleRange.count <= maximumSampleCount / channels.count else { throw Failure.sampleLimit }
        let stride = metadata.numberOfChannels * metadata.sampleInterpretation.bytesPerSample
        guard sampleRange.count <= maximumReadBytes / stride else { throw Failure.byteLimit }
        let start = indexed.dataRange.lowerBound + sampleRange.lowerBound * stride
        let end = indexed.dataRange.lowerBound + sampleRange.upperBound * stride
        let data = sampleRange.isEmpty ? Data() : Data(try await source.read(start..<end).retainedData())
        var results: [ChannelSamples] = []
        for ordinal in channels {
            try Task.checkCancellation()
            let channel = metadata.channels[ordinal - 1]
            var raw: [Int] = []
            raw.reserveCapacity(sampleRange.count)
            for sample in 0..<sampleRange.count {
                raw.append(DicomWaveformParser.sample(at: sample * stride + (ordinal - 1) * metadata.sampleInterpretation.bytesPerSample,
                    in: data, interpretation: metadata.sampleInterpretation))
            }
            let time = (metadata.timeOffsetMilliseconds ?? 0) / 1000
                + (channel.timeSkew ?? (channel.sampleSkew ?? 0) / metadata.samplingFrequency)
                + (channel.offset ?? 0) + Double(sampleRange.lowerBound) / metadata.samplingFrequency
            results.append(.init(channel: ordinal, rawValues: raw,
                timeSeries: .init(startTime: time, samplingFrequency: metadata.samplingFrequency,
                    physicalSamples: raw.map { channel.physicalValue(for: $0) }, units: channel.sensitivityUnits?.codeValue)))
        }
        try await source.checkOpen()
        return results
    }

    /// Seconds on the multiplex group's common time axis, including its time offset.
    /// Selects sample points t with lowerBound <= t < upperBound. Channel skews and
    /// alignment offsets are retained in each returned channel's start time.
    public func samples(group: Int, channels: [Int], timeRange: Range<Double>) async throws -> [ChannelSamples] {
        let indexed = try indexedGroup(group)
        let frequency = indexed.metadata.samplingFrequency
        let origin = (indexed.metadata.timeOffsetMilliseconds ?? 0) / 1000
        let lower = (timeRange.lowerBound - origin) * frequency
        let upper = (timeRange.upperBound - origin) * frequency
        guard lower.isFinite, upper.isFinite, lower >= 0, upper <= Double(indexed.numberOfSamples),
              lower <= upper else { throw Failure.invalidTimeRange }
        return try await samples(group: group, channels: channels, sampleRange: Int(ceil(lower))..<Int(ceil(upper)))
    }

    private func indexedGroup(_ group: Int) throws -> DicomWaveformSourceIndex.Group {
        guard group > 0, group <= index.groups.count else { throw Failure.unknownGroup }
        return index.groups[group - 1]
    }
}
