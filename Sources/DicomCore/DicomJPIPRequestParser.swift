import Foundation

public enum DicomJPIPServerError: Error, Sendable, Equatable {
    case malformedRequest
    case unsupportedMediaType
    case targetNotFound
    case invalidChannel
    case limitExceeded
    case malformedCodestream
    case unsupportedCodestream

    public var statusCode: Int {
        switch self {
        case .malformedRequest, .invalidChannel: 400
        case .unsupportedMediaType: 415
        case .targetNotFound: 404
        case .limitExceeded: 413
        case .malformedCodestream, .unsupportedCodestream: 422
        }
    }
}

public struct DicomJPIPServerRequest: Sendable {
    public let target: String?
    public let subtarget: ClosedRange<Int>?
    public let window: DicomJPIPWindow
    public let streams: [ClosedRange<Int>]
    public let cacheModel: DicomJPIPCacheModel
    public let newChannel: Bool
    public let channelID: String?
    public let closeChannels: [String]
    public let align: Bool
    let tilePartModel: [TilePartDescriptor]

    struct TilePartDescriptor: Sendable {
        let streams: [ClosedRange<Int>]
        let subtractive: Bool
        let firstTile: Int
        let firstPart: Int
        let lastTile: Int
        let lastPart: Int
    }
}

/// Bounded Annex C query parsing; unknown optional fields are ignored.
/// `wait` and `srate` are accepted hints and do not affect delivery scheduling.
public struct DicomJPIPRequestParser: Sendable {
    public let maximumRequestBytes: Int
    public let maximumParameters: Int

    public init(maximumRequestBytes: Int = 16_384, maximumParameters: Int = 64) {
        self.maximumRequestBytes = max(0, maximumRequestBytes)
        self.maximumParameters = max(0, maximumParameters)
    }

    public func parse(_ url: URL) throws -> DicomJPIPServerRequest {
        guard url.absoluteString.utf8.count <= maximumRequestBytes,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DicomJPIPServerError.malformedRequest
        }
        let query = components.percentEncodedQuery ?? ""
        guard query.utf8.filter({ $0 == 38 }).count < maximumParameters || query.isEmpty else {
            throw DicomJPIPServerError.malformedRequest
        }
        let known: Set<String> = ["target", "subtarget", "tid", "fsiz", "rsiz", "roff", "comps", "stream",
            "layers", "srate", "type", "len", "cnew", "cid", "cclose", "model", "tpmodel", "need", "metareq",
            "align", "wait"]
        var values: [String: String] = [:]
        for field in query.split(separator: "&", omittingEmptySubsequences: false) where !query.isEmpty {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, let name = String(pair[0]).removingPercentEncoding,
                  let value = String(pair[1]).removingPercentEncoding,
                  !name.isEmpty, !name.hasPrefix("!"),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw DicomJPIPServerError.malformedRequest
            }
            guard known.contains(name) else { continue }
            guard values[name] == nil, !value.isEmpty else { throw DicomJPIPServerError.malformedRequest }
            values[name] = value
        }
        func number(_ text: String, minimum: Int = 0) throws -> Int {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(text), number >= minimum else { throw DicomJPIPServerError.malformedRequest }
            return number
        }
        func ranges(_ text: String?, minimum: Int) throws -> [ClosedRange<Int>] {
            guard let text else { return [] }
            return try text.split(separator: ",", omittingEmptySubsequences: false).map { element in
                let ends = element.split(separator: "-", omittingEmptySubsequences: false)
                guard (1...2).contains(ends.count) else { throw DicomJPIPServerError.malformedRequest }
                let first = try number(String(ends[0]), minimum: minimum)
                let last = try ends.count == 1 ? first : number(String(ends[1]), minimum: first)
                return first...last
            }
        }
        func size(_ key: String) throws -> DicomJPIPWindow.Size? {
            guard let text = values[key] else { return nil }
            let fields = text.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 2 || (key == "fsiz" && fields.count == 3) else {
                throw DicomJPIPServerError.malformedRequest
            }
            return try .init(number(String(fields[0]), minimum: key == "roff" ? 0 : 1),
                             number(String(fields[1]), minimum: key == "roff" ? 0 : 1))
        }
        let fsiz = try size("fsiz")
        var rounding: DicomJPIPWindow.Rounding?
        if let fields = values["fsiz"]?.split(separator: ","), fields.count == 3 {
            guard let parsed = DicomJPIPWindow.Rounding(rawValue: String(fields[2])) else {
                throw DicomJPIPServerError.malformedRequest
            }
            rounding = parsed
        }
        let streams = try ranges(values["stream"], minimum: 1)
        let comps = try ranges(values["comps"], minimum: 0)
        var type = DicomJPIPStreamMode.jppStream
        if let accept = values["type"] {
            let options = accept.split(separator: ",", omittingEmptySubsequences: false)
            guard !options.contains(where: { $0.isEmpty }) else { throw DicomJPIPServerError.malformedRequest }
            guard let supported = options.first(where: { $0 == "jpp-stream" || $0 == "jpt-stream" }) else {
                throw DicomJPIPServerError.unsupportedMediaType
            }
            type = supported == "jpt-stream" ? .jptStream : .jppStream
        }
        if let cnew = values["cnew"], cnew != "http" { throw DicomJPIPServerError.malformedRequest }
        func identifier(_ text: String) -> Bool {
            !text.isEmpty && text.utf8.count <= 128 && text.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
        }
        if let cid = values["cid"], !identifier(cid) { throw DicomJPIPServerError.malformedRequest }
        let close = values["cclose"]?.split(separator: ",", omittingEmptySubsequences: false).map(String.init) ?? []
        guard close == ["*"] || close.allSatisfy(identifier),
              values["cnew"] == nil || values["cid"] == nil else { throw DicomJPIPServerError.malformedRequest }
        for key in ["align", "wait"] {
            if let value = values[key], value != "yes" && value != "no" { throw DicomJPIPServerError.malformedRequest }
        }
        if let srate = values["srate"] {
            guard let rate = Double(srate), rate.isFinite, rate > 0 else { throw DicomJPIPServerError.malformedRequest }
        }
        let subtarget = try ranges(values["subtarget"], minimum: 0)
        guard subtarget.count <= 1 else { throw DicomJPIPServerError.malformedRequest }
        // Metadata requests select an empty metadata set. Validate balanced box selectors first.
        if let metadata = values["metareq"] {
            var depth = 0
            for byte in metadata.utf8 {
                if byte == 91 { depth += 1; if depth > 1 { throw DicomJPIPServerError.malformedRequest } }
                if byte == 93 { depth -= 1; if depth < 0 { throw DicomJPIPServerError.malformedRequest } }
            }
            guard depth == 0, metadata.first == "[", metadata.contains("]") else {
                throw DicomJPIPServerError.malformedRequest
            }
        }
        do {
            let cache = try DicomJPIPCacheModel(model: values["model"] ?? "", tpmodel: values["tpmodel"], need: values["need"])
            var tilePartModel: [DicomJPIPServerRequest.TilePartDescriptor] = []
            var modelStreams = [0...Int.max]
            if let tpmodel = values["tpmodel"] {
                for element in tpmodel.split(separator: ",") {
                    if element.first == "[" {
                        modelStreams = try element.dropFirst().dropLast().split(separator: ";").map { item in
                            let parts = item.split(separator: "-", omittingEmptySubsequences: false)
                            let first = try number(String(parts[0]))
                            let last = try parts.count == 1 ? first : (parts[1].isEmpty ? Int.max : number(String(parts[1]), minimum: first))
                            return first...last
                        }
                        continue
                    }
                    let subtractive = element.first == "-"
                    let text = subtractive ? element.dropFirst() : element
                    let ends = text.split(separator: "-")
                    guard let start = ends.first, let end = ends.last else {
                        throw DicomJPIPServerError.malformedRequest
                    }
                    func pair(_ text: Substring) throws -> (Int, Int) {
                        let fields = text.split(separator: ".")
                        guard fields.count == 2 else { throw DicomJPIPServerError.malformedRequest }
                        return try (number(String(fields[0])), number(String(fields[1])))
                    }
                    let first = try pair(start), last = try pair(end)
                    guard first <= last else { throw DicomJPIPServerError.malformedRequest }
                    tilePartModel.append(.init(streams: modelStreams, subtractive: subtractive,
                        firstTile: first.0, firstPart: first.1, lastTile: last.0, lastPart: last.1))
                }
            }
            let window = try DicomJPIPWindow(fsiz: fsiz, rounding: rounding, rsiz: size("rsiz"), roff: size("roff"),
                stream: streams.first?.lowerBound, layers: values["layers"].map { try number($0, minimum: 1) },
                comps: comps, type: type, len: values["len"].map { try number($0, minimum: 3) },
                tid: values["tid"], metareq: values["metareq"])
            return .init(target: values["target"], subtarget: subtarget.first, window: window,
                         streams: streams, cacheModel: cache, newChannel: values["cnew"] != nil,
                         channelID: values["cid"], closeChannels: close, align: values["align"] == "yes", tilePartModel: tilePartModel)
        } catch { throw DicomJPIPServerError.malformedRequest }
    }
}
