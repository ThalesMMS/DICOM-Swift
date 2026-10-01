import ArgumentParser
import DicomCore
import DicomWebHTTP
import Foundation

struct JpipCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "jpip", abstract: "JPIP origin and client tools",
        subcommands: [Serve.self, Fetch.self, Index.self, Inspect.self])

    struct Serve: AsyncParsableCommand {
        @Option var dir: String
        @Option var port: UInt16 = 8080
        @Option var maxResponseBytes: Int = 32 * 1_024 * 1_024
        @Option var bearer: String?
        mutating func run() async throws {
            guard maxResponseBytes >= 3 else { throw ValidationError("Response budget must include the three-byte EOR") }
            var config = DicomJPIPServerConfiguration(); config.maximumResponseBytes = maxResponseBytes
            let server = DicomJPIPServer(provider: DicomJPIPDirectoryTargetProvider(directory: URL(fileURLWithPath: dir)),
                configuration: config, authentication: bearer.map { DicomWebBearerAuthentication(token: $0) })
            var listenerConfig = DicomWebHTTPListenerConfiguration(); listenerConfig.port = port
            let listener = DicomWebHTTPListener(configuration: listenerConfig) { request, _ in await server.handle(request) }
            let url = try await listener.start()
            print("JPIP listening at \(url.appendingPathComponent("jpip").absoluteString)")
            do { while !Task.isCancelled { try await Task.sleep(for: .seconds(1)) } }
            catch { await listener.stop(); throw error }
            await listener.stop()
        }
    }
    static func parsedWindow(_ text: String?, type: String) throws -> DicomJPIPWindow {
        guard ["jpp", "jpt"].contains(type) else { throw ValidationError("Type must be jpp or jpt") }
        var query = "type=\(type)-stream"
        if let text {
            // Only commas followed by another field name delimit fields; coordinate commas remain intact.
            let fields = text.replacingOccurrences(of: ",(?=[A-Za-z]+=)", with: "&", options: .regularExpression)
            query += "&" + fields
        }
        guard let url = URL(string: "http://localhost/jpip?" + query) else { throw ValidationError("Invalid window") }
        return try DicomJPIPRequestParser().parse(url).window
    }
    struct Fetch: AsyncParsableCommand {
        @Argument var url: String
        @Option var window: String?
        @Flag var session = false
        @Option var type = "jpp"
        @Option var out: String
        @Flag var dumpMessages = false
        mutating func run() async throws {
            guard let endpoint = URL(string: url), let origin = DicomJPIPOrigin(url: endpoint) else { throw ValidationError("Invalid endpoint") }
            let window = try JpipCommand.parsedWindow(window, type: type)
            let state = DicomJPIPSession(usesHTTPChannel: session, supportsCacheModel: true)
            let transport = try DicomJPIPHTTPTransport(configuration: .init(allowsInsecureHTTP: endpoint.scheme == "http",
                allowedResponseMediaTypes: ["image/jpp-stream", "image/jpt-stream"], allowedOrigins: [origin]))
            let layers = window.layers ?? 16
            let request = DicomJPIPRequest(pixelDataProviderURL: endpoint, resource: .volume,
                requestedLayerRange: (layers - 1)..<layers, window: window, session: state)
            do {
                var result: Data?
                for try await payload in transport.payloads(for: request) { result = payload.data }
                guard let result else { throw ValidationError("No codestream received") }
                try result.write(to: URL(fileURLWithPath: out), options: .atomic)
                if dumpMessages {
                    let cache = await state.cache
                    for (id, bin) in cache.bins.sorted(by: { ($0.key.classID, $0.key.binID) < ($1.key.classID, $1.key.binID) }) {
                        print("stream=\(id.codestream) class=\(id.classID) bin=\(id.binID) bytes=\(bin.byteCount) complete=\(bin.isComplete)")
                    }
                }
                try await state.end()
            } catch { try? await state.end(); throw error }
        }
    }
    struct Index: AsyncParsableCommand {
        @Argument var file: String
        mutating func run() async throws {
            let url = URL(fileURLWithPath: file).standardizedFileURL
            let target = try await DicomJPIPDirectoryTargetProvider(directory: url.deletingLastPathComponent())
                .target(named: url.lastPathComponent, maximumBytes: 128 * 1_024 * 1_024)
            let summaries = try target.codestreams.enumerated().map { n, data -> [String: Any] in
                let index = try DicomJPIPCodestreamIndexer().index(data)
                return ["stream": n + 1, "width": index.width, "height": index.height, "components": index.components,
                    "layers": index.layers, "progression": index.progression, "plt": index.usesPLT,
                    "jpp": index.supportsJPP, "htj2k": index.isHTJ2K, "tileParts": index.tileParts.count,
                    "precincts": index.precincts.count, "packets": index.precincts.reduce(0) { $0 + $1.packets.count }]
            }
            print(String(decoding: try JSONSerialization.data(withJSONObject: summaries, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        }
    }
    struct Inspect: AsyncParsableCommand {
        @Argument var file: String
        mutating func run() async throws {
            let url = URL(fileURLWithPath: file)
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64 * 1_024 * 1_024 else {
                throw ValidationError("Stream exceeds inspection budget")
            }
            let data = try Data(contentsOf: url)
            var parser = DicomJPIPMessageParser()
            for message in try parser.feed(data) {
                print("stream=\(message.codestream) class=\(message.classID) bin=\(message.binID) offset=\(message.offset) bytes=\(message.body.count) complete=\(message.isComplete) aux=\(message.auxiliary ?? 0)")
            }
            try parser.finish()
            if let eor = parser.endOfResponse { print("EOR=\(eor.reason)") }
        }
    }
}
