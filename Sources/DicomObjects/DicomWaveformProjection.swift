import Foundation
import DicomData

/// Pure envelope reduction. Output storage is O(min(bucketCount, samples.count));
/// each input is visited once. Padding does not contribute to extrema.
public struct DicomWaveformProjection: Equatable, Sendable {
    public struct Bucket: Equatable, Sendable {
        public let sampleRange: Range<Int>
        public let startTime: Double
        public let endTime: Double
        public let min: Double?
        public let max: Double?
        public let first: Double?
        public let last: Double?
    }
    public enum Failure: Error, Equatable, Sendable { case invalidTimeBase, invalidBucketCount, invalidRange }
    public let buckets: [Bucket]
    public let units: String?
    public let sensitivity: Double?

    public init(series: DicomWaveformTimeSeries, bucketCount: Int, sensitivity: Double? = nil) throws {
        try self.init(sampleCount: series.physicalSamples.count, valueAt: { series.physicalSamples[$0] },
                      startTime: series.startTime, samplingFrequency: series.samplingFrequency,
                      units: series.units, bucketCount: bucketCount, sensitivity: sensitivity)
    }

    private init(sampleCount: Int, valueAt: (Int) -> Double?, startTime: Double,
                 samplingFrequency: Double, units: String?, bucketCount: Int, sensitivity: Double?) throws {
        guard bucketCount > 0 else { throw Failure.invalidBucketCount }
        guard startTime.isFinite, samplingFrequency.isFinite, samplingFrequency > 0 else {
            throw Failure.invalidTimeBase
        }
        self.units = units
        self.sensitivity = sensitivity
        let count = Swift.min(bucketCount, sampleCount)
        var result: [Bucket] = []
        result.reserveCapacity(count)
        // Quotient/remainder avoids count * sampleCount overflow and floating-point partitions.
        let width = count == 0 ? 0 : sampleCount / count
        let remainder = count == 0 ? 0 : sampleCount % count
        var start = 0
        for index in 0..<count {
            let end = start + width + (index < remainder ? 1 : 0)
            var low: Double?, high: Double?
            for offset in start..<end {
                if let value = valueAt(offset), value.isFinite {
                    low = low.map { Swift.min($0, value) } ?? value
                    high = high.map { Swift.max($0, value) } ?? value
                }
            }
            result.append(.init(sampleRange: start..<end,
                startTime: startTime + Double(start) / samplingFrequency,
                endTime: startTime + Double(end) / samplingFrequency,
                min: low, max: high, first: valueAt(start), last: valueAt(end - 1)))
            start = end
        }
        self.buckets = result
    }

    public init(channel: DicomWaveformChannel, sampleRange: Range<Int>, samplingFrequency: Double,
                startTime: Double = 0, bucketCount: Int) throws {
        guard sampleRange.lowerBound >= 0, sampleRange.upperBound <= channel.samples.count else { throw Failure.invalidRange }
        let start = startTime + (channel.timeSkew ?? (channel.sampleSkew ?? 0) / samplingFrequency)
            + (channel.offset ?? 0) + Double(sampleRange.lowerBound) / samplingFrequency
        try self.init(sampleCount: sampleRange.count,
            valueAt: { channel.physicalValue(for: channel.samples[sampleRange.lowerBound + $0]) },
            startTime: start, samplingFrequency: samplingFrequency, units: channel.sensitivityUnits?.codeValue,
            bucketCount: bucketCount, sensitivity: channel.sensitivity)
    }
}

/// C.10.9 presentation attributes belong to the waveform dataset, not multiplex items.
public struct DicomWaveformDisplayScale: Equatable, Sendable {
    public struct CIELab: Equatable, Sendable {
        public let l: UInt16, a: UInt16, b: UInt16
        public init(l: UInt16, a: UInt16, b: UInt16) { self.l = l; self.a = a; self.b = b }
        fileprivate var values: [UInt] { [UInt(l), UInt(a), UInt(b)] }
        fileprivate init?(_ values: [Int]) {
            guard values.count == 3, values.allSatisfy({ (0...65535).contains($0) }) else { return nil }
            self.init(l: UInt16(values[0]), a: UInt16(values[1]), b: UInt16(values[2]))
        }
    }
    public struct Channel: Equatable, Sendable {
        public enum Shading: String, Sendable { case none = "NONE", baseline = "BASELINE", absolute = "ABSOLUTE", difference = "DIFFERENCE" }
        public let reference: DicomWaveformChannelReference
        public let offset: Double?
        public let color: CIELab
        public let position: Double
        public let shading: Shading?
        public let fractionalScale: Double?
        public let absoluteScale: Double?
        public init(reference: DicomWaveformChannelReference, offset: Double? = nil, color: CIELab,
                    position: Double, shading: Shading? = nil, fractionalScale: Double? = nil, absoluteScale: Double? = nil) {
            self.reference = reference; self.offset = offset; self.color = color; self.position = position
            self.shading = shading; self.fractionalScale = fractionalScale; self.absoluteScale = absoluteScale
        }
    }
    public struct PresentationGroup: Equatable, Sendable {
        public let number: Int
        public let channels: [Channel]
        public init(number: Int, channels: [Channel]) { self.number = number; self.channels = channels }
    }
    public let millimetersPerSecond: Double?
    public let background: CIELab?
    public let presentationGroups: [PresentationGroup]
    public init(millimetersPerSecond: Double? = nil, background: CIELab? = nil, presentationGroups: [PresentationGroup] = []) {
        self.millimetersPerSecond = millimetersPerSecond; self.background = background; self.presentationGroups = presentationGroups
    }

    package var elements: [DicomDataElement] {
        var e: [DicomDataElement] = []
        if let millimetersPerSecond { e.append(.init(tag: 0x003A0230, vr: .FL, value: .floats([millimetersPerSecond]))) }
        if let background { e.append(.init(tag: 0x003A0231, vr: .US, value: .unsignedIntegers(background.values))) }
        if !presentationGroups.isEmpty {
            e.append(waveformSequence(0x003A0240, presentationGroups.map { group in
                .init(elements: [.init(tag: 0x003A0241, vr: .US, value: .unsignedIntegers([UInt(clamping: group.number)])),
                    waveformSequence(0x003A0242, group.channels.map { channel in
                        var c = [waveformReferenceElement([channel.reference]),
                            DicomDataElement(tag: 0x003A0244, vr: .US, value: .unsignedIntegers(channel.color.values)),
                            DicomDataElement(tag: 0x003A0245, vr: .FL, value: .floats([channel.position]))]
                        for (tag, value) in [(0x003A0247, channel.fractionalScale), (0x003A0248, channel.absoluteScale)] {
                            if let value { c.append(.init(tag: tag, vr: .FL, value: .floats([value]))) }
                        }
                        if let offset = channel.offset, offset.isFinite {
                            c.append(.init(tag: 0x003A0218, vr: .DS, value: .strings([waveformDecimalString(offset)])))
                        }
                        if let shading = channel.shading { c.append(.init(tag: 0x003A0246, vr: .CS, value: .strings([shading.rawValue]))) }
                        return .init(elements: c)
                    })])
            }))
        }
        return e
    }

    package init?(dataSet ds: DicomDataSet) {
        guard [0x003A0230, 0x003A0231, 0x003A0240].contains(where: { ds.contains($0) }) else { return nil }
        self.init(millimetersPerSecond: ds.float(for: 0x003A0230), background: CIELab(ds.ints(for: 0x003A0231)),
            presentationGroups: ds.sequenceItems(for: 0x003A0240).map { item in
                .init(number: item.dataSet.int(for: 0x003A0241) ?? 0,
                    channels: item.dataSet.sequenceItems(for: 0x003A0242).compactMap { item in
                        let d = item.dataSet
                        guard let reference = waveformReferences(d.ints(for: 0x0040A0B0)).first,
                              let color = CIELab(d.ints(for: 0x003A0244)), let position = d.float(for: 0x003A0245) else { return nil }
                        return .init(reference: reference, offset: d.float(for: 0x003A0218), color: color,
                            position: position, shading: d.string(for: 0x003A0246).flatMap(Channel.Shading.init(rawValue:)),
                            fractionalScale: d.float(for: 0x003A0247), absoluteScale: d.float(for: 0x003A0248))
                    })
            })
    }
}
