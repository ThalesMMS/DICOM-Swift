import Foundation

/// HTTP channel and cache shared by successive pull-based window requests.
public actor DicomJPIPSession: Equatable {
    public nonisolated static func == (lhs: DicomJPIPSession, rhs: DicomJPIPSession) -> Bool { lhs === rhs }
    public private(set) var channelID: String?
    public let transport = "http"
    public let usesHTTPChannel: Bool
    public let supportsCacheModel: Bool
    public private(set) var cache: DicomJPIPDatabinCache
    public private(set) var lastWindow: DicomJPIPWindow?
    private(set) var needsRecovery = false
    private var firstPreviewTimestamp: Date?
    private var finalTimestamp: Date?
    private var closeOperation: (@Sendable (String) async throws -> Void)?

    public init(maximumCacheBytes: Int = 64 * 1_024 * 1_024, maximumBins: Int = 65_536,
                usesHTTPChannel: Bool = true, supportsCacheModel: Bool = true) {
        self.usesHTTPChannel = usesHTTPChannel
        self.supportsCacheModel = supportsCacheModel
        cache = DicomJPIPDatabinCache(maximumBytes: maximumCacheBytes, maximumBins: maximumBins)
    }

    func accept(channelHeader: String?, window: DicomJPIPWindow?, codestream: Int,
                close: @escaping @Sendable (String) async throws -> Void) throws {
        if let channelHeader {
            let fields = channelHeader.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let cid = fields.first(where: { $0.hasPrefix("cid=") }).map({ String($0.dropFirst(4)) }),
                  !cid.isEmpty, !cid.contains(where: { $0.isWhitespace || $0.isNewline }),
                  fields.first(where: { $0.hasPrefix("transport=") }).map({ $0 == "transport=http" }) ?? true else {
                throw DicomJPIPTransportError.invalidResponseHeader("JPIP-cnew")
            }
            channelID = cid
        }
        try cache.activate(window: window, codestream: codestream)
        lastWindow = window
        closeOperation = close
    }

    func receive(_ messages: [DicomJPIPMessage]) throws -> DicomJPIPDatabinCache {
        for message in messages { try cache.insert(message) }
        return cache
    }

    public func importCacheModel(_ model: DicomJPIPCacheModel) throws { try cache.importCacheModel(model) }

    func interrupted() { needsRecovery = true }
    func recovered() { needsRecovery = false }

    func record(isFinal: Bool) {
        if isFinal { finalTimestamp = Date() }
        else if firstPreviewTimestamp == nil { firstPreviewTimestamp = Date() }
    }

    public var performanceReport: DicomJPIPPerformanceReport {
        DicomJPIPPerformanceReport(cache: cache, firstPreviewTimestamp: firstPreviewTimestamp,
                                  finalTimestamp: finalTimestamp)
    }

    /// Sends cclose alone, compatible with OpenJPIP 1.5.2's channel lifetime rules.
    public func end() async throws {
        guard let channelID, let closeOperation else { return }
        try await closeOperation(channelID)
        self.channelID = nil
        self.closeOperation = nil
    }
}

/// Serializes Foundation callbacks and preserves parsed messages when the HTTP task is interrupted.
final class DicomJPIPResponseAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var parser: DicomJPIPMessageParser
    private var messages: [DicomJPIPMessage] = []
    private var metadata: DicomJPIPHTTPResponse?
    private var receivedBytes = 0
    private let acceptedMediaTypes: Set<String>

    init(configuration: DicomJPIPTransportConfiguration, acceptedMediaTypes: Set<String>) {
        parser = DicomJPIPMessageParser(maximumMessageLength: configuration.maximumMessageLength,
            maximumBins: configuration.maximumDatabins, maximumTotalBytes: configuration.maximumResponseBytes)
        self.acceptedMediaTypes = acceptedMediaTypes
    }

    func receive(_ response: DicomJPIPHTTPResponse, data: Data) throws {
        try lock.withLock {
            receivedBytes += data.count
            let type = response.header(named: "Content-Type")?.split(separator: ";").first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard (200..<300).contains(response.statusCode), let type, acceptedMediaTypes.contains(type),
                  type == "image/jpp-stream" || type == "image/jpt-stream" else { return }
            if let encoding = response.header(named: "Content-Encoding"),
               encoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "identity" { return }
            metadata = response
            messages += try parser.feed(data)
        }
    }

    func snapshot() -> (messages: [DicomJPIPMessage], metadata: DicomJPIPHTTPResponse?, receivedBytes: Int) {
        lock.withLock { (messages, metadata, receivedBytes) }
    }
}
