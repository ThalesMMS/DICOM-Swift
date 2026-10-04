import ArgumentParser
import DicomCore
import DicomWebHTTP
import Foundation

struct WebCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "web", abstract: "DICOMweb networking",
        subcommands: [Qido.self, Wado.self, Stow.self, Serve.self, Capabilities.self, UPS.self])

    struct Options: ParsableArguments {
        @Option var url: String
        @Option var bearer: String?
        @Option var basic: String?
        @Option var timeout: Double = 30

        func client() throws -> DicomWebClient {
            guard let base = URL(string: url), ["http", "https"].contains(base.scheme?.lowercased() ?? ""),
                  base.host != nil, base.user == nil, base.password == nil, timeout > 0,
                  bearer == nil || basic == nil else { throw ValidationError("Invalid endpoint or authentication options") }
            var headers: [String: String] = [:]
            if let bearer { headers["Authorization"] = "Bearer \(bearer)" }
            if let basic {
                guard basic.contains(":") else { throw ValidationError("Basic credentials must be username:password") }
                headers["Authorization"] = "Basic \(Data(basic.utf8).base64EncodedString())"
            }
            return DicomWebClient(configuration: .init(baseURL: base, headers: headers, timeout: timeout))
        }
    }

    struct Qido: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Search studies, series or instances; output DICOM JSON")
        @OptionGroup var options: Options
        @Option var level = "study"
        @Option var study: String?
        @Option var series: String?
        @Option(name: .customLong("key")) var keys: [String] = []
        @Option(name: .customLong("includefield")) var includeFields: [String] = []
        @Flag var fuzzy = false
        @Option var limit: Int?
        @Option var offset: Int?
        @Flag var allPages = false

        func parameters() throws -> DicomWebSearchParameters {
            guard let level = DicomWebSearchParameters.Level(rawValue: level.lowercased()) else {
                throw ValidationError("Level must be study, series or instance")
            }
            let matches = try keys.map { key -> DicomWebSearchParameters.Match in
                let pair = key.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, !pair[0].isEmpty else { throw ValidationError("Keys must be attribute=value") }
                let attribute = String(pair[0])
                let vr = Int(attribute, radix: 16).flatMap { DCMDictionary().vrCode(forTag: $0) }
                    .flatMap(DicomVR.init(code:)) ?? (attribute.hasSuffix("UID") ? .UI : .LO)
                return .init(attribute, vr: vr,
                             values: vr == .UI ? String(pair[1]).components(separatedBy: ",") : [String(pair[1])])
            }
            let parameters = DicomWebSearchParameters(level: level, studyInstanceUID: study, seriesInstanceUID: series,
                matches: matches, fuzzyMatching: fuzzy ? true : nil,
                includeFields: includeFields.isEmpty ? ["all"] : includeFields, limit: limit, offset: offset)
            _ = try parameters.queryItems()
            return parameters
        }

        mutating func run() async throws {
            let client = try options.client()
            let parameters = try parameters()
            var results: [DicomDataSet] = []
            if allPages {
                for try await page in client.searchPages(parameters: parameters) {
                    guard page.dataSets.count <= 100_000 - results.count else {
                        throw ValidationError("QIDO result safety limit exceeded (100000)")
                    }
                    results += page.dataSets
                }
            } else {
                results = try await client.search(parameters: parameters).dataSets
            }
            print(String(decoding: try DicomJSONCodec.encode(results), as: UTF8.self))
        }
    }

    struct Capabilities: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print Annex H resources and media types")
        @OptionGroup var options: Options
        mutating func run() async throws {
            let result = try await options.client().retrieveCapabilities()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
        }
    }

    struct Wado: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stream WADO resources to an output directory")
        @OptionGroup var options: Options
        @Option var resource = "instance"
        @Option var study: String?
        @Option var series: String?
        @Option var instance: String?
        @Option var frames: String?
        @Option var uri: String?
        @Option var accept: String?
        @Option var transferSyntax: String?
        @Option var outputDirectory: String

        mutating func run() async throws {
            let client = try options.client()
            let output = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            let staging = output.appendingPathComponent(".wado-" + UUID().uuidString)
            let sink = try DicomWebFileRetrieveSink(directory: staging)
            defer { try? FileManager.default.removeItem(at: staging) }
            let defaultAccept: String
            switch resource {
            case "metadata": defaultAccept = "application/dicom+json"
            case "rendered", "thumbnail": defaultAccept = "image/jpeg"
            case "frames": defaultAccept = "multipart/related; type=\"application/octet-stream\""
            case "bulkdata": defaultAccept = "application/octet-stream"
            default: defaultAccept = "multipart/related; type=\"application/dicom\""
            }
            let media = try DicomWebMediaType((accept ?? defaultAccept)
                + (transferSyntax.map { "; transfer-syntax=\($0)" } ?? ""))
            func required(_ value: String?, _ name: String) throws -> String {
                guard let value, !value.isEmpty else { throw ValidationError("Missing --" + name) }
                return value
            }
            let status: Int
            switch resource {
            case "study":
                status = try await client.retrieveStudy(studyInstanceUID: required(study, "study"), accept: media, sink: sink)
            case "series":
                status = try await client.retrieveSeries(studyInstanceUID: required(study, "study"),
                    seriesInstanceUID: required(series, "series"), accept: media, sink: sink)
            case "instance":
                status = try await client.retrieveInstance(studyInstanceUID: required(study, "study"),
                    seriesInstanceUID: required(series, "series"), sopInstanceUID: required(instance, "instance"),
                    accept: media, sink: sink)
            case "frames":
                status = try await client.retrieveFrames(studyInstanceUID: required(study, "study"),
                    seriesInstanceUID: required(series, "series"), sopInstanceUID: required(instance, "instance"),
                    frames: DicomWebFrameList(try required(frames, "frames").split(separator: ",", omittingEmptySubsequences: false).map { value in
                        guard let number = Int(value) else { throw ValidationError("Invalid frame number") }
                        return number
                    }), accept: media, sink: sink)
            case "bulkdata":
                status = try await client.retrieveBulkData(uri: required(uri, "uri"), accept: media, sink: sink)
            case "metadata", "rendered", "thumbnail":
                status = try await client.retrieveRepresentation(studyInstanceUID: required(study, "study"),
                    seriesInstanceUID: series, sopInstanceUID: instance,
                    resource: resource == "metadata" ? .metadata : resource == "rendered" ? .rendered : .thumbnail,
                    accept: media, sink: sink)
            default: throw ValidationError("Unknown WADO resource")
            }
            guard status == 200 else { throw ValidationError("Incomplete WADO response: HTTP \(status)") }
            let parts = await sink.result()
            guard !parts.isEmpty else { throw ValidationError("Empty WADO response") }
            for part in parts {
                let destination = output.appendingPathComponent(part.url.lastPathComponent)
                try FileManager.default.moveItem(at: part.url, to: destination)
                print("\(destination.path)\t\(part.contentLocation ?? "")")
            }
        }
    }

    struct Stow: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Store files or directories; report Annex I outcomes")
        @OptionGroup var options: Options
        @Option var study: String?
        @Argument var paths: [String]

        mutating func run() async throws {
            let result = try await options.client().storeInstances(files: NetCommand.files(paths), studyInstanceUID: study)
            print("SOP Instance UID\tOutcome\tWarning\tFailure")
            for item in result.storeResponse?.instances ?? [] {
                print("\(item.sopInstanceUID ?? "?")\t\(item.outcome.rawValue)\t\(item.warningReason.map(String.init) ?? "")\t\(item.failureReason.map(String.init) ?? "")")
            }
            guard [200, 202].contains(result.statusCode), result.acceptedInstanceCount > 0,
                  let response = result.storeResponse else { throw ExitCode.failure }
            // HTTP 202 also covers fully accepted batches with warnings, not just partial storage (issue #2529).
            if response.instances.contains(where: { $0.outcome == .failed || $0.outcome == .unknown })
                || !response.otherFailureReasons.isEmpty { throw ExitCode(2) }
        }
    }


    struct UPS: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ups",
            subcommands: [Create.self, Get.self, Update.self, State.self, Cancel.self,
                          Search.self, Subscribe.self, Unsubscribe.self, Suspend.self, Watch.self])

        static func output(_ result: DicomWebWorkitemResponse, uid: String? = nil) throws {
            for data in result.workitems { try NetCommand.UPS.line(data: data, status: result.statusCode) }
            if result.workitems.isEmpty { try NetCommand.UPS.line(uid: uid, status: result.statusCode) }
        }

        static func output(_ result: DicomWebSubscriptionResponse, uid: String) throws {
            try NetCommand.UPS.line(uid: uid, status: result.statusCode)
        }

        struct Create: AsyncParsableCommand {
            @OptionGroup var options: Options
            @Option var uid: String
            @Option var file: String?
            mutating func run() async throws {
                try await UPS.output(options.client().createWorkitem(NetCommand.UPS.attributes(file: file), workitemUID: uid), uid: uid)
            }
        }

        struct Get: AsyncParsableCommand {
            @OptionGroup var options: Options
            @Option var uid: String
            mutating func run() async throws {
                try await UPS.output(options.client().retrieveWorkitem(uid), uid: uid)
            }
        }

        struct Update: AsyncParsableCommand {
            @OptionGroup var options: Options
            @Option var uid: String
            @Option var transaction: String?
            @Option var file: String?
            @Option(name: .customLong("key")) var keys: [String] = []
            func attributes() throws -> DicomDataSet {
                var data = try file.map { try NetCommand.UPS.attributes(file: $0) } ?? DicomDataSet()
                for element in try NetCommand.identifier(keys).elements { data.set(element) }
                return data
            }
            mutating func run() async throws {
                try await UPS.output(options.client().updateWorkitem(uid, attributes: attributes(), transactionUID: transaction), uid: uid)
            }
        }

        struct State: AsyncParsableCommand {
            @OptionGroup var options: Options
            @Option var uid: String
            @Option var transaction: String
            @Option var state: String
            @Option var requester: String?
            mutating func run() async throws {
                try await UPS.output(options.client().changeWorkitemState(uid, to: NetCommand.UPS.state(state), transactionUID: transaction, requester: requester), uid: uid)
            }
        }

        struct Cancel: AsyncParsableCommand {
            @OptionGroup var options: Options
            @Option var uid: String
            @Option var requester: String?
            @OptionGroup var cancellation: NetCommand.UPS.Cancellation
            mutating func run() async throws {
                try await UPS.output(options.client().requestWorkitemCancellation(uid, information: cancellation.attributes(), requester: requester), uid: uid)
            }
        }

        struct Search: AsyncParsableCommand {
            @OptionGroup var options: Options
            @Option(name: .customLong("key")) var keys: [String] = []
            @Option var limit: Int?
            @Option var offset: Int?
            func parameters() throws -> DicomWebSearchParameters {
                let data = try NetCommand.identifier(keys)
                return .init(matches: data.elements.map {
                    .init(String(format: "%08X", $0.tag), vr: $0.vr, values: $0.stringValues)
                }, limit: limit, offset: offset)
            }
            mutating func run() async throws {
                try await UPS.output(options.client().searchWorkitems(parameters()), uid: nil)
            }
        }

        struct Subscribe: AsyncParsableCommand {
            @OptionGroup var options: Options
            @Option var uid: String
            @Option var subscriber: String
            @Flag var deletionLock = false
            @Option var filter: String?
            mutating func run() async throws {
                try await UPS.output(options.client().subscribe(NetCommand.UPS.uid(uid), subscriber: subscriber, deletionLock: deletionLock, filter: filter), uid: NetCommand.UPS.uid(uid))
            }
        }

        struct Unsubscribe: AsyncParsableCommand {
            @OptionGroup var options: Options
            @Option var uid: String
            @Option var subscriber: String
            mutating func run() async throws {
                try await UPS.output(options.client().unsubscribe(NetCommand.UPS.uid(uid), subscriber: subscriber), uid: NetCommand.UPS.uid(uid))
            }
        }

        struct Suspend: AsyncParsableCommand {
            @OptionGroup var options: Options
            @Option var subscriber: String
            @Flag var filtered = false
            mutating func run() async throws {
                try await UPS.output(options.client().suspendWorklistSubscription(subscriber: subscriber, filtered: filtered), uid: filtered ? DicomNetworkUID.unifiedProcedureStepFilteredGlobalSubscriptionInstance : DicomNetworkUID.unifiedProcedureStepGlobalSubscriptionInstance)
            }
        }

        struct Watch: AsyncParsableCommand {
            @OptionGroup var options: Options
            @Option var subscriber: String
            @Option var duration: Double = 3600
            mutating func run() async throws {
                guard duration.isFinite, duration > 0 else { throw ValidationError("Duration must be positive and finite") }
                let client = try options.client()
                var parts = URLComponents(url: client.configuration.baseURL.appendingPathComponent("subscribers")
                    .appendingPathComponent(subscriber), resolvingAgainstBaseURL: false)!
                parts.scheme = parts.scheme == "https" ? "wss" : "ws"
                let url = parts.url!
                let headers = client.configuration.headers
                let seconds = duration
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await signal in DicomWebNotificationClient().connect(to: url, headers: headers) {
                            switch signal {
                            case .connected: break
                            case .gap: print("{\"gap\":true}")
                            case .event(let event):
                                try NetCommand.UPS.line(uid: event.sopInstanceUID, data: event.dataSet, type: event.typeID)
                            }
                        }
                    }
                    group.addTask { try await Task.sleep(for: .seconds(seconds)) }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
            }
        }
    }

    struct Serve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Serve a directory through the shared DICOMweb listener")
        @Argument var directory: String
        @Flag var ups = false
        @Option(name: [.customLong("bind"), .customLong("host")]) var bind = "127.0.0.1"
        @Flag(name: [.customLong("allow-insecure-lab"), .customLong("intranet-lab")]) var allowInsecureLab = false
        @OptionGroup var security: ServerSecurityOptions
        @Option var port: UInt16 = 8080
        @Option var bearer: String?
        @Option var basic: String?
        @Option var tlsCertificate: String?
        @Option var tlsKey: String?
        @Option var tlsCa: String?

        func start() async throws -> (DicomWebHTTPListener, URL) {
            guard bearer == nil || basic == nil else { throw ValidationError("Choose bearer or basic authentication") }
            guard (tlsCertificate == nil) == (tlsKey == nil), tlsCa == nil || tlsCertificate != nil else {
                throw ValidationError("TLS requires certificate and key together")
            }
            let exposure = try ServerSecurityOptions.exposure(host: bind, tls: tlsCertificate != nil,
                authentication: bearer != nil || basic != nil, lab: allowInsecureLab)
            let audit = try security.recorder()
            if allowInsecureLab { print("AUDIT exposure=labOptIn: insecure laboratory access explicitly enabled") }
            let storage = try WebDirectoryStorage(directory: URL(fileURLWithPath: directory))
            var authentication: (any DicomWebAuthenticating)?
            if let bearer { authentication = DicomWebBearerAuthentication(token: bearer) }
            if let basic {
                let pair = basic.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { throw ValidationError("Basic credentials must be username:password") }
                authentication = DicomWebBasicAuthentication(username: String(pair[0]), password: String(pair[1]))
            }
            var configuration = DicomWebHTTPListenerConfiguration()
            configuration.port = port
            configuration.bindAddress = bind
            configuration.loopbackOnly = ServerSecurityOptions.isLoopback(bind)
            if let tlsCertificate, let tlsKey {
                configuration.tls = .init(mode: .enabled,
                    material: .init(certificatePath: tlsCertificate, privateKeyPath: tlsKey, trustStorePath: tlsCa),
                    securityProfile: .bcp195RFC8996)
            }
            let listener = DicomWebHTTPListener(server: .init(storage: storage, authentication: authentication,
                // Instances stored in a syntax DICOMweb cannot send, or that a client
                // asks for as Explicit VR Little Endian, go out rewritten or decoded.
                transcoding: DicomWebServerNativeTranscoding(),
                unifiedProcedureSteps: ups ? DicomUnifiedProcedureStepService(store: DicomInMemoryUnifiedProcedureStepStore()) : nil,
                notifications: ups ? DicomWebNotificationHub() : nil,
                principals: CommandWebPrincipals(authentication: authentication as? any DicomWebPrincipalResolving,
                    local: ServerSecurityOptions.isLoopback(bind) && !security.principalScopes.isEmpty ? security.principal() : nil,
                    scopes: Set(security.principalScopes)),
                authorizer: authentication != nil || !security.principalScopes.isEmpty
                    ? DicomProtectionAuthorizer(policyVersion: 0, protectionLookup: { _ in [:] }) : nil,
                audit: audit, exposure: exposure),
                                               configuration: configuration)
            return (listener, try await listener.start())
        }

        mutating func run() async throws {
            let (listener, root) = try await start()
            print(root.appendingPathComponent("dicom-web").absoluteString)
            do {
                while !Task.isCancelled { try await Task.sleep(for: .seconds(1)) }
            } catch {
                await listener.stop()
                throw error
            }
            await listener.stop()
        }
    }
}
