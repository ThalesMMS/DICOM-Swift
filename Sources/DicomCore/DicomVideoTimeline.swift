import Foundation

public struct DicomVideoTimeline: Sendable {
    public struct AccessUnit: Equatable, Sendable {
        public let decodeIndex: Int
        public let presentationIndex: Int?
        public let dts: Int64?
        public let pts: Int64?
        public let duration: Int64?
        public let fragmentIndexes: [Int]
        public let isKeyFrame: Bool
        public let byteRange: Range<Int>
    }

    public struct TemporalUnit: Equatable, Sendable {
        public let accessUnit: AccessUnit
        public let encodedData: Data
        public let leadIn: Bool
    }

    public let description: DicomVideoStreamDescription
    public let timescale: Int64?
    public let accessUnits: [AccessUnit]
    public let diagnostics: [DicomVideoDiagnostic]
    private let stream: Data

    public init(video: DicomVideo) throws {
        let inspected = try DicomVideoStreamInspector.inspect(video.streamData, codec: video.codec)
        description = inspected
        stream = video.streamData
        var diagnostics: [DicomVideoDiagnostic] = []
        let count = inspected.accessUnits.count
        if count != video.numberOfFrames {
            diagnostics.append(.init(code: .frameCountMismatch, message: "Number of Frames differs from codec access-unit count."))
        }
        var scale: Int64?
        var cadence: Int64?
        var starts: [Int64] = []
        let cine = video.cine
        if let tick = inspected.numUnitsInTick, let clock = inspected.timeScale, tick > 0, clock > 0 {
            scale = Int64(clock)
            cadence = Int64(tick) * (video.codec == .h264 ? 2 : 1)
        } else if let time = cine.frameTimeMilliseconds, time.isFinite, time > 0, time < 1e9 {
            scale = 1_000_000
            cadence = Int64((time * 1000).rounded())
        } else if !cine.frameTimeVectorMilliseconds.isEmpty {
            let vector = cine.frameTimeVectorMilliseconds
            if vector.count == count, vector.first == 0,
               vector.dropFirst().allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1e9 }) {
                scale = 1_000_000
                var current: Int64 = 0
                for delta in vector { current += Int64((delta * 1000).rounded()); starts.append(current) }
            } else { diagnostics.append(.init(code: .cineTimingMismatch, message: "Invalid Frame Time Vector increments or count.")) }
        } else if let rate = cine.cineRate, rate > 0 {
            scale = Int64(rate); cadence = 1
        }
        if let cadence { starts = (0..<count).map { Int64($0) * cadence } }
        if let scale, let cadence, let frameTime = cine.frameTimeMilliseconds,
           abs(Double(cadence) / Double(scale) - frameTime / 1000) > 0.000001 {
            diagnostics.append(.init(code: .cineTimingMismatch, message: "Codec cadence differs from Frame Time."))
        }
        if !cine.frameTimeVectorMilliseconds.isEmpty, cine.frameTimeVectorMilliseconds.count != count {
            diagnostics.append(.init(code: .cineTimingMismatch, message: "Frame Time Vector count differs from codec count."))
        }
        if scale == nil { diagnostics.append(.init(code: .unknownTiming, message: "No codec or Cine timing is available.")) }
        let order = inspected.accessUnits.compactMap(\.presentationIndex)
        let knownOrder = order.count == count && order.sorted() == Array(0..<count)
        if !knownOrder { diagnostics.append(.init(code: .unsupportedOrdering, message: "Presentation order is outside the qualified subset.")) }
        let preroll = knownOrder ? zip(0..<count, order).map { $0 - $1 }.max() ?? 0 : 0
        var fragmentRanges: [(Int, Range<Int>)] = []
        var cursor = 0
        for fragment in video.encapsulatedPixelDataDescriptor.fragments {
            fragmentRanges.append((fragment.index, cursor..<cursor + fragment.length)); cursor += fragment.length
        }
        accessUnits = inspected.accessUnits.map { unit in
            let p = unit.presentationIndex
            let pts = knownOrder && p != nil && starts.indices.contains(p!) ? starts[p!] : nil
            let duration: Int64?
            if let cadence { duration = cadence }
            else if let p, starts.indices.contains(p + 1) { duration = starts[p + 1] - starts[p] }
            else { duration = nil } // A Frame Time Vector does not specify the last picture's duration.
            let dts = knownOrder && cadence != nil ? Int64(unit.decodeIndex - preroll) * cadence! : nil
            return AccessUnit(decodeIndex: unit.decodeIndex, presentationIndex: p, dts: dts, pts: pts,
                duration: duration, fragmentIndexes: fragmentRanges.filter { $0.1.overlaps(unit.byteRange) }.map(\.0),
                isKeyFrame: unit.isKeyFrame, byteRange: unit.byteRange)
        }
        timescale = scale
        self.diagnostics = diagnostics
    }

    /// Presentation frame indexes and time ranges are zero-based and half-open; times use `timescale` ticks.
    public func timeRange(forFrames frames: Range<Int>) throws -> Range<Int64> {
        guard !frames.isEmpty, frames.lowerBound >= 0, frames.upperBound <= accessUnits.count else {
            throw DicomVideoInspectionError.invalidTimeRange
        }
        let selected = accessUnits.filter { $0.presentationIndex.map(frames.contains) ?? false }
        guard selected.count == frames.count, let start = selected.compactMap(\.pts).min(),
              let last = selected.max(by: { $0.presentationIndex! < $1.presentationIndex! }),
              let pts = last.pts, let duration = last.duration else { throw DicomVideoInspectionError.unknownTiming }
        return start..<(pts + duration)
    }

    public func accessUnits(forTime range: Range<Int64>) throws -> [AccessUnit] {
        guard !range.isEmpty else { throw DicomVideoInspectionError.invalidTimeRange }
        guard timescale != nil, accessUnits.allSatisfy({ $0.pts != nil && $0.duration != nil }) else {
            throw DicomVideoInspectionError.unknownTiming
        }
        return accessUnits.filter { ($0.pts!..<($0.pts! + $0.duration!)).overlaps(range) }
    }

    public func temporalRead(range: Range<Int64>) throws -> [TemporalUnit] {
        guard description.closedGOP == true else { throw DicomVideoInspectionError.openGOPDependencies }
        let selected = try accessUnits(forTime: range)
        guard let first = selected.map(\.decodeIndex).min(), let last = selected.map(\.decodeIndex).max() else { return [] }
        guard let key = accessUnits[...first].last(where: \.isKeyFrame) else {
            throw DicomVideoInspectionError.openGOPDependencies
        }
        let indexes = Set(selected.map(\.decodeIndex))
        return accessUnits[key.decodeIndex...last].map {
            TemporalUnit(accessUnit: $0, encodedData: stream.subdata(in: $0.byteRange), leadIn: !indexes.contains($0.decodeIndex))
        }
    }
}
