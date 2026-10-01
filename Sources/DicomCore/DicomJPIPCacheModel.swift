import Foundation

/// T.808 C.8 explicit cache descriptors. A sparse bin advertises only its contiguous prefix.
public struct DicomJPIPCacheModel: Sendable, Equatable {
    public enum Extent: Sendable, Equatable { case complete, bytes(Int), layers(Int) }
    public struct Descriptor: Sendable, Equatable {
        public let codestreams: [ClosedRange<Int>]
        public let subtractive: Bool
        public let classID: Int?
        /// nil denotes the wildcard. Implicit descriptors instead use selectors t/c/r/p.
        public let binID: Int?
        public let selectors: [String: ClosedRange<Int>]
        public let extent: Extent
    }
    public var modelDescriptors: [Descriptor] { get throws { try Self.parse(model) } }
    public var needDescriptors: [Descriptor] { get throws { try Self.parse(need ?? "") } }

    public let model: String
    public let tpmodel: String?
    public let need: String?

    public init(cache: DicomJPIPDatabinCache, codestream: Int = 0) {
        let descriptors = cache.bins.filter { $0.key.codestream == codestream }
            .sorted { ($0.key.classID, $0.key.binID) < ($1.key.classID, $1.key.binID) }
            .compactMap { key, bin -> String? in
                let prefix: String
                switch key.classID {
                case 0: prefix = "P\(key.binID)"
                case 2: prefix = "H\(key.binID)"
                case 4: prefix = "T\(key.binID)"
                case 6: prefix = "Hm"
                case 8: prefix = "M\(key.binID)"
                default: return nil
                }
                guard bin.isComplete || !bin.contiguousData.isEmpty else { return nil }
                return prefix + (bin.isComplete ? "" : ":\(bin.contiguousData.count)")
            }
        model = descriptors.isEmpty ? "" : "[\(codestream)]," + descriptors.joined(separator: ",")
        tpmodel = nil
        need = nil
    }

    /// Supplies explicit cache-management grammar for peers supporting model negotiation.
    /// Query serialization performs percent encoding; no text is appended to a URL verbatim.
    public init(model: String = "", tpmodel: String? = nil, need: String? = nil) throws {
        guard [model, tpmodel, need].compactMap({ $0 }).allSatisfy({
            $0.utf8.count <= 65_536 && !$0.contains(where: \.isNewline)
        }) else { throw DicomJPIPTransportError.invalidWindow }
        guard need == nil || (model.isEmpty && tpmodel == nil) else {
            throw DicomJPIPTransportError.invalidWindow
        }
        try Self.validate(model, tileParts: false, subtractive: true)
        if let tpmodel { try Self.validate(tpmodel, tileParts: true, subtractive: true) }
        if let need { try Self.validate(need, tileParts: false, subtractive: false) }
        _ = try Self.parse(model)
        _ = try Self.parse(need ?? "")
        self.model = model
        self.tpmodel = tpmodel
        self.need = need
    }

    private static func validate(_ value: String, tileParts: Bool, subtractive: Bool) throws {
        if value.isEmpty { return }
        let unsigned = "[0-9]+"
        let qualifier = "\\[(?:[0-9]+(?:-[0-9]*)?)(?:;[0-9]+(?:-[0-9]*)?)*\\]"
        let explicit = "(?:Hm|[MTHP](?:[0-9]+|\\*))(?::(?:L)?[0-9]+)?"
        let implicit = "(?:[tcrp](?:[0-9]+(?:-[0-9]+)?|\\*))+(?::L[0-9]+)?"
        let part = "\(unsigned)\\.\(unsigned)(?:-\(unsigned)\\.\(unsigned))?"
        let descriptor = tileParts ? part : "(?:\(explicit)|\(implicit))"
        let element = (subtractive ? "-?" : "") + descriptor
        let pattern = "^(?:(?:\(qualifier),)?\(element))(?:,(?:\(qualifier),)?\(element))*$"
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw DicomJPIPTransportError.invalidWindow
        }
    }

    private static func parse(_ value: String) throws -> [Descriptor] {
        func number(_ text: Substring) throws -> Int {
            guard let value = Int(text), value >= 0 else { throw DicomJPIPTransportError.invalidWindow }
            return value
        }
        func range(_ text: Substring) throws -> ClosedRange<Int> {
            if text == "*" { return 0...Int.max }
            let ends = text.split(separator: "-", omittingEmptySubsequences: false)
            let lower = try number(ends[0])
            let upper = ends.count == 1 ? lower : (ends[1].isEmpty ? Int.max : try number(ends[1]))
            guard lower <= upper else { throw DicomJPIPTransportError.invalidWindow }
            return lower...upper
        }
        var codestreams = [0...Int.max]
        var result: [Descriptor] = []
        for element in value.split(separator: ",") {
            if element.first == "[" {
                codestreams = try element.dropFirst().dropLast().split(separator: ";").map(range)
                continue
            }
            let subtractive = element.first == "-"
            let fields = (subtractive ? element.dropFirst() : element).split(separator: ":")
            let selector = fields[0]
            var extent = Extent.complete
            if fields.count == 2 {
                extent = fields[1].first == "L" ? .layers(try number(fields[1].dropFirst())) : .bytes(try number(fields[1]))
            }
            var classID: Int?
            var binID: Int?
            var selectors: [String: ClosedRange<Int>] = [:]
            if selector == "Hm" { classID = 6; binID = 0 }
            else if let kind = selector.first, let id = ["M": 8, "H": 2, "T": 4, "P": 0][String(kind)] {
                classID = id
                binID = selector.dropFirst() == "*" ? nil : try number(selector.dropFirst())
            } else {
                var remaining = selector
                var previous = -1
                while let kind = remaining.first {
                    guard let order = ["t", "c", "r", "p"].firstIndex(of: String(kind)), order > previous else {
                        throw DicomJPIPTransportError.invalidWindow
                    }
                    previous = order
                    remaining = remaining.dropFirst()
                    let digits = remaining.prefix { $0.isNumber || $0 == "-" || $0 == "*" }
                    selectors[String(kind)] = try range(digits)
                    remaining = remaining.dropFirst(digits.count)
                }
            }
            if case .layers = extent, let classID, classID != 0 { throw DicomJPIPTransportError.invalidWindow }
            result.append(.init(codestreams: codestreams, subtractive: subtractive, classID: classID,
                binID: binID, selectors: selectors, extent: extent))
        }
        return result
    }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if !model.isEmpty { items.append(.init(name: "model", value: model)) }
        if let tpmodel { items.append(.init(name: "tpmodel", value: tpmodel)) }
        if let need { items.append(.init(name: "need", value: need)) }
        return items
    }
}
