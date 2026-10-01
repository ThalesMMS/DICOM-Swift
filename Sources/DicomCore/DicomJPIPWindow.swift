import Foundation

public enum DicomJPIPStreamMode: Sendable, Equatable {
    case completeEntity
    case jppStream
    case jptStream
    case negotiated
}

/// Validated T.808 window. Frame/codestream selection uses one-based `stream` values.
public struct DicomJPIPWindow: Sendable, Equatable {
    public enum Rounding: String, Sendable { case roundUp = "round-up", roundDown = "round-down", closest = "closest" }
    public struct Size: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public init(_ width: Int, _ height: Int) { self.width = width; self.height = height }
    }
    public let fsiz: Size?
    public let rounding: Rounding?
    public let rsiz: Size?
    public let roff: Size?
    public let stream: Int?
    public let layers: Int?
    public let comps: [ClosedRange<Int>]
    public let quality: Int?
    public let type: DicomJPIPStreamMode
    public let len: Int?
    public let tid: String?
    public let metareq: String?

    public init(fsiz: Size? = nil, rounding: Rounding? = nil, rsiz: Size? = nil, roff: Size? = nil,
                stream: Int? = nil, layers: Int? = nil, comps: [ClosedRange<Int>] = [],
                quality: Int? = nil, type: DicomJPIPStreamMode = .jppStream, len: Int? = nil,
                tid: String? = nil, metareq: String? = nil) throws {
        func positive(_ size: Size?) -> Bool { size.map { $0.width > 0 && $0.height > 0 } ?? true }
        guard positive(fsiz), positive(rsiz), stream.map({ $0 >= 1 }) ?? true,
              layers.map({ $0 >= 1 }) ?? true, len.map({ $0 >= 1 }) ?? true,
              quality.map({ (0...100).contains($0) }) ?? true,
              comps.allSatisfy({ $0.lowerBound >= 0 }),
              roff.map({ $0.width >= 0 && $0.height >= 0 }) ?? true,
              (rounding == nil || fsiz != nil),
              [tid, metareq].compactMap({ $0 }).allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isNewline) }) else {
            throw DicomJPIPTransportError.invalidWindow
        }
        if let fsiz {
            let offset = roff ?? Size(0, 0)
            guard offset.width < fsiz.width, offset.height < fsiz.height,
                  rsiz.map({ $0.width <= fsiz.width - offset.width && $0.height <= fsiz.height - offset.height }) ?? true else {
                throw DicomJPIPTransportError.invalidWindow
            }
        } else if rsiz != nil || roff != nil { throw DicomJPIPTransportError.invalidWindow }
        self.fsiz = fsiz
        self.rounding = rounding
        self.rsiz = rsiz
        self.roff = roff
        self.stream = stream
        self.layers = layers
        self.comps = comps
        self.quality = quality
        self.type = type
        self.len = len
        self.tid = tid
        self.metareq = metareq
    }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let fsiz { items.append(.init(name: "fsiz", value: "\(fsiz.width),\(fsiz.height)" + (rounding.map { ",\($0.rawValue)" } ?? ""))) }
        if let rsiz { items.append(.init(name: "rsiz", value: "\(rsiz.width),\(rsiz.height)")) }
        if let roff { items.append(.init(name: "roff", value: "\(roff.width),\(roff.height)")) }
        if let stream { items.append(.init(name: "stream", value: String(stream))) }
        if let quality { items.append(.init(name: "quality", value: String(quality))) }
        if !comps.isEmpty {
            items.append(.init(name: "comps", value: comps.map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",")))
        }
        if let tid { items.append(.init(name: "tid", value: tid)) }
        if let metareq { items.append(.init(name: "metareq", value: metareq)) }
        return items
    }
}
