import Foundation

public struct DicomJPIPDatabinID: Hashable, Sendable {
    public let codestream: Int
    public let classID: Int
    public let binID: Int

    public init(codestream: Int, classID: Int, binID: Int) {
        self.codestream = codestream
        self.classID = classID & ~1
        self.binID = binID
    }
}

public enum DicomJPIPCacheError: Error, Sendable, Equatable {
    case invalidMessage
    case conflictingOverlap
    case conflictingCompletion
    case mixedStreamModes
    case budgetExceeded
}

public struct DicomJPIPDatabin: Sendable {
    public struct Segment: Sendable {
        public let offset: Int
        public let data: Data
        public var range: Range<Int> { offset..<offset + data.count }
    }
    public fileprivate(set) var segments: [Segment] = []
    public fileprivate(set) var finalLength: Int?
    /// End offsets indexed by the number of complete packets at that offset.
    public fileprivate(set) var packetEnds: [Int: Int] = [:]
    fileprivate var access: UInt64 = 0
    public var byteCount: Int { segments.reduce(0) { $0 + $1.data.count } }
    public var contiguousData: Data { segments.first.flatMap { $0.offset == 0 ? $0.data : nil } ?? Data() }
    public var isComplete: Bool { finalLength.map { contiguousData.count == $0 } ?? false }
    public var completePackets: Int { packetEnds.filter { $0.value <= contiguousData.count }.keys.max() ?? 0 }
    public var gaps: [Range<Int>] {
        var result: [Range<Int>] = []
        var end = 0
        for segment in segments {
            if end < segment.offset { result.append(end..<segment.offset) }
            end = segment.range.upperBound
        }
        if let finalLength, end < finalLength { result.append(end..<finalLength) }
        return result
    }
}

/// Sparse, bounded cache. Headers of the active codestream are pinned even if its window is empty.
public struct DicomJPIPDatabinCache: Sendable {
    /// Negotiation claims are separate from received bytes; imports never manufacture cached data.
    public private(set) var importedModel: [DicomJPIPCacheModel.Descriptor] = []
    public private(set) var importedNeed: [DicomJPIPCacheModel.Descriptor] = []
    public mutating func importCacheModel(_ model: DicomJPIPCacheModel) throws {
        let descriptors = try model.modelDescriptors
        let needs = try model.needDescriptors
        importedModel = descriptors
        importedNeed = needs
    }

    public private(set) var bins: [DicomJPIPDatabinID: DicomJPIPDatabin] = [:]
    public private(set) var usefulBytes = 0
    public private(set) var redundantBytes = 0
    public private(set) var peakBytes = 0
    public private(set) var byteCount = 0
    public var activeCodestream = 0
    public var activeWindowBins: Set<DicomJPIPDatabinID> = []
    public let maximumBytes: Int
    public let maximumBins: Int
    private var activeWindow: DicomJPIPWindow?
    private var protectsWindow = false
    private var modes: [Int: Bool] = [:]
    private var clock: UInt64 = 0

    public init(maximumBytes: Int = 64 * 1_024 * 1_024, maximumBins: Int = 65_536) {
        self.maximumBytes = max(0, maximumBytes)
        self.maximumBins = max(0, maximumBins)
    }

    public mutating func activate(window: DicomJPIPWindow?, codestream: Int = 0) throws {
        activeCodestream = codestream
        activeWindow = window
        protectsWindow = true
        if let header = bin(codestream: codestream, classID: 6, binID: 0), header.isComplete {
            activeWindowBins = try DicomJPIPCodestreamReconstructor.windowBins(
                header: header.contiguousData, codestream: codestream, window: window)
        } else { activeWindowBins = [] }
    }

    public mutating func insert(_ message: DicomJPIPMessage) throws {
        guard [0, 1, 2, 4, 5, 6, 8].contains(message.classID), message.offset >= 0,
              message.codestream >= 0, message.binID >= 0,
              message.offset <= Int.max - message.body.count,
              message.auxiliary.map({ $0 >= 0 }) ?? true else { throw DicomJPIPCacheError.invalidMessage }
        let mode: Bool? = message.classID <= 2 ? true : ([4, 5].contains(message.classID) ? false : nil)
        if let mode, let previous = modes[message.codestream], mode != previous {
            throw DicomJPIPCacheError.mixedStreamModes
        }
        let key = DicomJPIPDatabinID(codestream: message.codestream, classID: message.classID, binID: message.binID)
        var bin = bins[key] ?? DicomJPIPDatabin()
        let end = message.offset + message.body.count
        if let final = bin.finalLength, end > final || (message.isComplete && end != final) {
            throw DicomJPIPCacheError.conflictingCompletion
        }
        if message.isComplete {
            guard bin.segments.last?.range.upperBound ?? 0 <= end else { throw DicomJPIPCacheError.conflictingCompletion }
            bin.finalLength = end
        }
        var overlap = 0
        for segment in bin.segments {
            let lower = max(segment.offset, message.offset)
            let upper = min(segment.range.upperBound, end)
            if lower < upper {
                let old = segment.data.subdata(in: lower - segment.offset..<upper - segment.offset)
                let new = message.body.subdata(in: lower - message.offset..<upper - message.offset)
                guard old == new else { throw DicomJPIPCacheError.conflictingOverlap }
                overlap += upper - lower
            }
        }
        let useful = message.body.count - overlap
        guard useful <= maximumBytes else { throw DicomJPIPCacheError.budgetExceeded }
        var victims: [DicomJPIPDatabinID] = []
        var remaining = byteCount
        var count = bins.count + (bins[key] == nil ? 1 : 0)
        if remaining > maximumBytes - useful || count > maximumBins {
            for (candidate, value) in bins.sorted(by: { $0.value.access < $1.value.access }) {
                if remaining <= maximumBytes - useful && count <= maximumBins { break }
                guard candidate != key, !activeWindowBins.contains(candidate),
                      !(candidate.codestream == activeCodestream && [2, 6].contains(candidate.classID)) else { continue }
                victims.append(candidate)
                remaining -= value.byteCount
                count -= 1
            }
        }
        guard remaining <= maximumBytes - useful, count <= maximumBins else { throw DicomJPIPCacheError.budgetExceeded }
        if !message.body.isEmpty { bin.segments.append(.init(offset: message.offset, data: message.body)) }
        var merged: [DicomJPIPDatabin.Segment] = []
        for segment in bin.segments.sorted(by: { $0.offset < $1.offset }) {
            if let last = merged.last, segment.offset <= last.range.upperBound {
                var data = last.data
                let skip = last.range.upperBound - segment.offset
                if skip < segment.data.count { data.append(segment.data.dropFirst(skip)) }
                merged[merged.count - 1] = .init(offset: last.offset, data: data)
            } else { merged.append(segment) }
        }
        bin.segments = merged
        if let packets = message.auxiliary, message.classID == 1 { bin.packetEnds[packets] = end }
        clock &+= 1
        bin.access = clock
        for victim in victims { bins.removeValue(forKey: victim) }
        bins[key] = bin
        if let mode { modes[message.codestream] = mode }
        byteCount = remaining + useful
        usefulBytes += useful
        redundantBytes += overlap
        peakBytes = max(peakBytes, byteCount)
        if protectsWindow, key.codestream == activeCodestream, key.classID == 6, bin.isComplete {
            try activate(window: activeWindow, codestream: activeCodestream)
        }
    }

    public func bin(codestream: Int, classID: Int, binID: Int) -> DicomJPIPDatabin? {
        bins[DicomJPIPDatabinID(codestream: codestream, classID: classID, binID: binID)]
    }

    public func isJPP(codestream: Int) -> Bool? { modes[codestream] }
}
