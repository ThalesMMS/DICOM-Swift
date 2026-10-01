import ArgumentParser
import DicomCore
import Foundation

struct NetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "net", abstract: "DIMSE networking",
        subcommands: [Echo.self, Find.self, Get.self, Move.self, Store.self, MWL.self, MPPS.self, Commit.self, UPS.self, IAN.self, Listen.self])

    struct Options: ParsableArguments {
        @Option var aet = "DICOMTOOL"
        @Option var calledAet = "ANY-SCP"
        @Option var host = "127.0.0.1"
        @Option var port: UInt16 = 11112
        @Option var timeout: Double = 30
        @Option var asyncWindow: UInt16 = 1
        @Flag var tls = false
        @Option var tlsCa: String?
        @Option var tlsCertificate: String?
        @Option var tlsKey: String?
        @Option var user: String?
        @Option var passcode: String?

        func connection() throws -> DicomDIMSEConnectionConfiguration {
            guard timeout > 0 else { throw ValidationError("Timeout must be positive") }
            guard user == nil || tls else { throw ValidationError("User identity requires TLS") }
            return .init(host: host, port: port, calledAETitle: calledAet, callingAETitle: aet, timeout: timeout,
                tls: tls ? .init(mode: .enabled, serverName: host,
                    material: .init(certificatePath: tlsCertificate, privateKeyPath: tlsKey, trustStorePath: tlsCa),
                    securityProfile: .bcp195RFC8996) : .disabled,
                userIdentity: user.map { .usernameAndPasscode($0, passcode: passcode ?? "") },
                asynchronousOperationsWindow: .init(maximumInvoked: asyncWindow, maximumPerformed: 1))
        }
        func service() throws -> DicomDIMSEServiceSCU { .init(configuration: try connection()) }
    }

    struct Query: ParsableArguments {
        @Option var model = "study"
        @Option var level = "STUDY"
        @Option(name: .customLong("key")) var keys: [String] = []
        @Flag var json = false

        func identifier() throws -> DicomDataSet {
            guard DicomQueryLevel(rawValue: level.uppercased()) != nil else { throw ValidationError("Invalid level") }
            var data = try NetCommand.identifier(keys)
            data.set(.init(tag: 0x00080052, vr: .CS, value: .strings([level.uppercased()])))
            return data
        }
        func models(_ operation: String) throws -> [String] {
            guard model == "study" || model == "patient" else { throw ValidationError("Model must be study or patient") }
            switch (model, operation) {
            case ("patient", "find"): return [DicomNetworkUID.patientRootQueryRetrieveFind]
            case ("patient", "get"): return [DicomNetworkUID.patientRootQueryRetrieveGet]
            case ("patient", "move"): return [DicomNetworkUID.patientRootQueryRetrieveMove]
            case (_, "get"): return [DicomNetworkUID.studyRootQueryRetrieveGet]
            case (_, "move"): return [DicomNetworkUID.studyRootQueryRetrieveMove]
            default: return [DicomNetworkUID.studyRootQueryRetrieveFind]
            }
        }
    }

    static func identifier(_ keys: [String]) throws -> DicomDataSet {
        var data = DicomDataSet()
        for key in keys {
            let parts = key.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let tag = Int(parts[0].filter { $0 != "," && $0 != "(" && $0 != ")" }, radix: 16),
                  let code = DCMDictionary().vrCode(forTag: tag), let vr = DicomVR(code: code), vr != .SQ else {
                throw ValidationError("Keys must use a known scalar tag: ggggeeee=value")
            }
            data.set(.init(tag: tag, vr: vr, value: .strings([String(parts[1])])))
        }
        return data
    }

    static func output(_ data: [DicomDataSet], json: Bool) throws {
        let rows = data.map { data in
            Dictionary(uniqueKeysWithValues: data.elements.map {
                (String(format: "%08X", $0.tag), $0.stringValue ?? "")
            })
        }
        if json {
            print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), as: UTF8.self))
        } else {
            for row in rows { for key in row.keys.sorted() { print("\(key)=\(row[key] ?? "")") }; print("") }
        }
    }

    static func files(_ paths: [String]) throws -> [URL] {
        var result: [URL] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else {
                throw ValidationError("Input does not exist: \(path)")
            }
            if directory.boolValue {
                guard let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else {
                    throw ValidationError("Cannot enumerate input directory")
                }
                for case let entry as URL in entries {
                    if try entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { result.append(entry) }
                }
            } else { result.append(url) }
        }
        return result.sorted { $0.path < $1.path }
    }

    struct Commit: AsyncParsableCommand {
        @OptionGroup var options: Options
        @Option var listenPort: UInt16 = 11113
        @Option var wait: Double = 30
        @Option var transactionUID: String = "2.25." + String(UInt64.random(in: 1...UInt64.max))
        @Argument var paths: [String]

        mutating func run() async throws {
            guard wait > 0, wait.isFinite else { throw ValidationError("Wait must be positive and finite") }
            let references = try NetCommand.files(paths).map { url in
                let source = try DicomStoreRequest(part10FileAt: url)
                return DicomStorageCommitmentReference(sopClassUID: source.sopClassUID, sopInstanceUID: source.sopInstanceUID)
            }
            guard !references.isEmpty else { throw ValidationError("Provide at least one DICOM file") }
            let received = CommitmentReceipt()
            let uid = transactionUID
            let server = DicomDIMSEServer(configuration: .init(aeTitle: options.aet, port: listenPort),
                commitmentResultHandler: { report in
                    guard report.transactionUID == uid else { throw ValidationError("Unexpected transaction UID") }
                    received.set(report)
                })
            try server.start()
            do {
                _ = try options.service().requestStorageCommitment(transactionUID: uid, references: references)
                let deadline = ContinuousClock.now.advanced(by: .seconds(wait))
                while received.report == nil, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard let report = received.report else { throw ValidationError("Storage Commitment report timed out") }
                print(report.transactionUID)
                guard report.references.allSatisfy({ $0.status == .committed }) else {
                    throw ValidationError("Storage Commitment reported failed references")
                }
            } catch { await server.stop(); throw error }
            await server.stop()
        }
    }

    private final class CommitmentReceipt: @unchecked Sendable {
        private let lock = NSLock()
        private var value: DicomStorageCommitmentReport?
        var report: DicomStorageCommitmentReport? { lock.withLock { value } }
        func set(_ report: DicomStorageCommitmentReport) { lock.withLock { value = report } }
    }

    struct Echo: ParsableCommand {
        @OptionGroup var options: Options
        mutating func run() throws { print(try options.service().verify().status) }
    }
    struct Find: ParsableCommand {
        @OptionGroup var options: Options
        @OptionGroup var query: Query
        mutating func run() throws {
            let result = try options.service().find(identifier: query.identifier(), queryModelUIDs: query.models("find"))
            try NetCommand.output(result.matches, json: query.json)
        }
    }
    struct Get: ParsableCommand {
        @OptionGroup var options: Options
        @OptionGroup var query: Query
        @Option var output: String
        mutating func run() throws {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let result = try options.service().get(identifier: query.identifier(),
                storageSOPClassUIDs: Array(DicomStorageSOPClassUIDs.commonClinicalStorage),
                queryModelUIDs: query.models("get"), onInstance: { instance in
                    guard let sopClass = instance.sopClassUID, let uid = instance.sopInstanceUID else {
                        throw ValidationError("Received object has no SOP identity")
                    }
                    let data = try DicomDataSetWriter.part10Data(fromEncodedDataSet: instance.data,
                        transferSyntax: instance.transferSyntax, mediaStorageSOPClassUID: sopClass,
                        mediaStorageSOPInstanceUID: uid)
                    let file = directory.appendingPathComponent(UUID().uuidString + ".dcm")
                    try data.write(to: file, options: .atomic)
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.synchronize()
                })
            print(result.status)
        }
    }
    struct Move: ParsableCommand {
        @OptionGroup var options: Options
        @OptionGroup var query: Query
        @Option var destinationAe: String
        mutating func run() throws {
            print(try options.service().move(identifier: query.identifier(), moveDestinationAETitle: destinationAe,
                queryModelUIDs: query.models("move")).status)
        }
    }
    struct Store: AsyncParsableCommand {
        @OptionGroup var options: Options
        @Option var policy = "as-received"
        @Argument var paths: [String]
        mutating func run() async throws {
            guard let policy = DicomStoreRepresentationPolicy(rawValue: policy) else {
                throw ValidationError("Policy must be as-received, lossless, or any")
            }
            let results = await (try options.service()).store(batch: try NetCommand.files(paths), policy: policy, transcoder: Transcoder())
            for (index, result) in results.enumerated() { print("\(index + 1): \(result.accepted ? "accepted" : "failed")") }
            print("\(results.filter(\.accepted).count)/\(results.count) accepted")
            if results.contains(where: { !$0.accepted }) { throw ExitCode.failure }
        }
    }
    struct MWL: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "mwl")
        @OptionGroup var options: Options
        @OptionGroup var query: Query
        mutating func run() throws {
            let result = try options.service().find(identifier: NetCommand.identifier(query.keys),
                queryModelUIDs: [DicomNetworkUID.modalityWorklistInformationModelFind])
            try NetCommand.output(result.matches, json: query.json)
        }
    }
    struct MPPS: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "mpps", subcommands: [Create.self, Set.self])
        struct Create: ParsableCommand {
            @OptionGroup var options: Options
            @Option var uid: String
            mutating func run() throws { print(try options.service().createMPPS(.init(sopInstanceUID: uid)).status) }
        }
        struct Set: ParsableCommand {
            @OptionGroup var options: Options
            @Option var uid: String
            @Option var status = "COMPLETED"
            mutating func run() throws {
                guard let state = DicomMPPSStatus(rawValue: status) else { throw ValidationError("Invalid MPPS status") }
                print(try options.service().updateMPPS(.init(sopInstanceUID: uid, status: state)).status)
            }
        }
    }

    struct UPS: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ups",
            subcommands: [Create.self, Find.self, Get.self, Set.self, State.self, Cancel.self,
                          Subscribe.self, Unsubscribe.self, Suspend.self, Watch.self])

        static func uid(_ value: String) -> String {
            switch value {
            case "global": return DicomNetworkUID.unifiedProcedureStepGlobalSubscriptionInstance
            case "filtered": return DicomNetworkUID.unifiedProcedureStepFilteredGlobalSubscriptionInstance
            default: return value
            }
        }

        static func state(_ value: String) throws -> DicomUnifiedProcedureStepState {
            guard let state = DicomUnifiedProcedureStepState(rawValue: value), state != .scheduled else {
                throw ValidationError("State must be IN PROGRESS, COMPLETED or CANCELED")
            }
            return state
        }

        static func attributes(file: String?) throws -> DicomDataSet {
            if let file {
                let url = URL(fileURLWithPath: file)
                if url.pathExtension.lowercased() == "json" {
                    let sets = try DicomJSONCodec.decode(Data(contentsOf: url))
                    guard sets.count == 1 else { throw ValidationError("Provide one JSON dataset") }
                    return sets[0].dataSet
                }
                let stored = try DicomStoreRequest(part10FileAt: url)
                return try DicomDataSetParser.dataSet(from: stored.dataSetData, transferSyntax: stored.transferSyntax)
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMddHHmmss"
            var data = try NetCommand.identifier(["00741000=SCHEDULED", "00741200=MEDIUM",
                "00741204=DICOMTOOL", "00404005=" + formatter.string(from: Date()) + "+0000", "00404041=READY"])
            for row in DicomUnifiedProcedureStepAttribute.table where row.path.count == 1
                && row.create.hasPrefix("2/") {
                if let code = DCMDictionary().vrCode(forTag: row.tag), let vr = DicomVR(code: code) {
                    data.set(.init(tag: row.tag, vr: vr, value: vr == .SQ ? .sequence([]) : .strings([])))
                }
            }
            return data
        }

        static func line(uid: String? = nil, data: DicomDataSet? = nil,
                         status: Int? = nil, type: UInt16? = nil) throws {
            var row: [String: Any] = [:]
            if let uid = uid ?? data?.string(for: 0x00080018) { row["uid"] = uid }
            if let state = data?.string(for: 0x00741000),
               DicomUnifiedProcedureStepState(rawValue: state) != nil { row["state"] = state }
            if let status { row["status"] = status }
            if let type { row["type"] = Int(type) }
            print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
        }

        static func output(_ result: DicomUnifiedProcedureStepResponse, uid: String? = nil) throws {
            for (index, data) in result.matches.enumerated() {
                try line(data: data, status: Int(result.pendingStatuses[index]))
            }
            try line(uid: uid, data: result.dataSet, status: Int(result.status))
            guard result.status == 0 || result.warning else { throw ExitCode.failure }
        }

        struct Cancellation: ParsableArguments {
            @Option var reason: String?
            @Option var contactName: String?
            @Option var contactUri: String?
            func attributes() throws -> DicomDataSet {
                try NetCommand.identifier([(reason.map { "00741238=" + $0 }),
                    contactName.map { "0074100C=" + $0 }, contactUri.map { "0074100A=" + $0 }].compactMap { $0 })
            }
        }

        struct Create: ParsableCommand {
            @OptionGroup var options: Options
            @Option var uid: String
            @Option var file: String?
            mutating func run() throws {
                try UPS.output(options.service().createUnifiedProcedureStep(sopInstanceUID: uid, attributes: UPS.attributes(file: file)), uid: uid)
            }
        }

        struct Find: ParsableCommand {
            @OptionGroup var options: Options
            @Option(name: .customLong("key")) var keys: [String] = []
            @Option(name: .customLong("class")) var sopClass = "pull"
            func classUID() throws -> String {
                switch sopClass {
                case "pull": return DicomNetworkUID.unifiedProcedureStepPullSOPClass
                case "watch": return DicomNetworkUID.unifiedProcedureStepWatchSOPClass
                case "query": return DicomNetworkUID.unifiedProcedureStepQuerySOPClass
                default: throw ValidationError("Class must be pull, watch or query")
                }
            }
            mutating func run() throws {
                try UPS.output(options.service().findUnifiedProcedureSteps(identifier: NetCommand.identifier(keys), sopClassUID: classUID()), uid: nil)
            }
        }

        struct Get: ParsableCommand {
            @OptionGroup var options: Options
            @Option var uid: String
            @Option var attribute: [String] = []
            mutating func run() throws {
                try UPS.output(options.service().getUnifiedProcedureStep(sopInstanceUID: uid, attributes: attribute.isEmpty ? nil : attribute.map { value in
                    guard value.count == 8, let tag = Int(value, radix: 16) else { throw ValidationError("Attribute must be ggggeeee") }
                    return tag
                }), uid: uid)
            }
        }

        struct Set: ParsableCommand {
            @OptionGroup var options: Options
            @Option var uid: String
            @Option var transaction: String
            @Option(name: .customLong("key")) var keys: [String] = []
            mutating func run() throws {
                try UPS.output(options.service().setUnifiedProcedureStep(sopInstanceUID: uid, attributes: NetCommand.identifier(keys + ["00081195=" + transaction])), uid: uid)
            }
        }

        struct State: ParsableCommand {
            @OptionGroup var options: Options
            @Option var uid: String
            @Option var transaction: String
            @Option var state: String
            mutating func run() throws {
                try UPS.output(options.service().changeUnifiedProcedureStepState(sopInstanceUID: uid, to: UPS.state(state), transactionUID: transaction), uid: uid)
            }
        }

        struct Cancel: ParsableCommand {
            @OptionGroup var options: Options
            @Option var uid: String
            @OptionGroup var cancellation: Cancellation
            mutating func run() throws {
                try UPS.output(options.service().requestUnifiedProcedureStepCancel(sopInstanceUID: uid, information: cancellation.attributes()), uid: uid)
            }
        }

        struct Subscribe: ParsableCommand {
            @OptionGroup var options: Options
            @Option var uid: String
            @Option var receivingAe: String
            @Flag var deletionLock = false
            @Option(name: .customLong("key")) var keys: [String] = []
            mutating func run() throws {
                try UPS.output(options.service().subscribeUnifiedProcedureStep(sopInstanceUID: UPS.uid(uid), receivingAE: receivingAe, deletionLock: deletionLock, matchingKeys: NetCommand.identifier(keys)), uid: UPS.uid(uid))
            }
        }

        struct Unsubscribe: ParsableCommand {
            @OptionGroup var options: Options
            @Option var uid: String
            @Option var receivingAe: String
            mutating func run() throws {
                try UPS.output(options.service().unsubscribeUnifiedProcedureStep(sopInstanceUID: UPS.uid(uid), receivingAE: receivingAe), uid: UPS.uid(uid))
            }
        }

        struct Suspend: ParsableCommand {
            @OptionGroup var options: Options
            @Option var receivingAe: String
            mutating func run() throws {
                try UPS.output(options.service().suspendGlobalSubscription(receivingAE: receivingAe), uid: DicomNetworkUID.unifiedProcedureStepGlobalSubscriptionInstance)
            }
        }

        struct Watch: AsyncParsableCommand {
            @OptionGroup var options: Options
            @Option var receivingAe: String
            @Option var duration: Double = 3600
            func start() throws -> DicomDIMSEServer {
                guard duration.isFinite, duration > 0 else { throw ValidationError("Duration must be positive and finite") }
                let connection = try options.connection()
                let service = DicomUnifiedProcedureStepService(store: DicomInMemoryUnifiedProcedureStepStore(),
                    eventReceiver: { uid, type, data in try UPS.line(uid: uid, data: data, type: type) })
                let server = DicomDIMSEServer(configuration: .init(aeTitle: receivingAe, port: options.port,
                    tls: connection.tls), unifiedProcedureSteps: service)
                try server.start()
                return server
            }
            mutating func run() async throws {
                let server = try start()
                do { try await Task.sleep(for: .seconds(duration)) }
                catch { await server.stop(); throw error }
                await server.stop()
            }
        }
    }

    struct IAN: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ian", subcommands: [Send.self])
        struct Send: ParsableCommand {
            @OptionGroup var options: Options
            @Option var study: String
            @Option var retrieveAe: String
            @Option var instance: [String] = []
            mutating func run() throws {
                guard !instance.isEmpty else { throw ValidationError("Provide at least one --instance") }
                var series: [String: [DicomInstanceAvailabilityNotification.Instance]] = [:]
                for value in instance {
                    let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                    guard (3...4).contains(parts.count), parts.prefix(3).allSatisfy({ !$0.isEmpty }),
                          let availability = DicomInstanceAvailability(rawValue: parts.count == 4 ? parts[3] : "ONLINE")
                    else { throw ValidationError("Instance must be CLASS:INSTANCE:SERIES[:availability]") }
                    series[parts[2], default: []].append(.init(sopClassUID: parts[0], sopInstanceUID: parts[1],
                        availability: availability, retrieveAETitle: retrieveAe))
                }
                let notification = DicomInstanceAvailabilityNotification(studyInstanceUID: study,
                    series: series.keys.sorted().map { .init(seriesInstanceUID: $0, instances: series[$0]!) })
                let uid = "2.25." + String(UInt64.random(in: 1...UInt64.max))
                try UPS.output(options.service().sendInstanceAvailabilityNotification(notification, sopInstanceUID: uid), uid: uid)
            }
        }
    }

    struct IANReceiver: DicomInstanceAvailabilityNotificationReceiving {
        func receive(sopInstanceUID: String, dataSet: DicomDataSet) async throws {
            for series in dataSet.sequenceItems(for: 0x00081115) {
                for instance in series.dataSet.sequenceItems(for: 0x00081199) {
                    let row = ["uid": sopInstanceUID, "study": dataSet.string(for: 0x0020000D) ?? "",
                        "series": series.dataSet.string(for: 0x0020000E) ?? "",
                        "class": instance.dataSet.string(for: 0x00081150) ?? "",
                        "instance": instance.dataSet.string(for: 0x00081155) ?? ""]
                    print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
                }
            }
        }
    }

    struct Listen: AsyncParsableCommand {
        @OptionGroup var options: Options
        @OptionGroup var security: ServerSecurityOptions
        @Flag var intranetLab = false
        @Argument var directory: String
        @Flag var queryRetrieve = false
        @Flag var ups = false
        @Flag var ian = false
        @Option var fallbackAe: [String] = []
        @Option var duration: Double = 3600
        @Option(help: "C-MOVE destination AE=host:port; repeat for multiple destinations.")
        var moveDestination: [String] = []
        func start() throws -> DicomDIMSEServer {
            let exposure = try ServerSecurityOptions.exposure(host: options.host, tls: options.tls,
                authentication: options.user != nil, lab: intranetLab)
            let audit = try security.recorder()
            if intranetLab { print("AUDIT exposure=labOptIn: insecure laboratory access explicitly enabled") }
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let connection = try options.connection()
            var configuration = DicomDIMSEServerConfiguration(aeTitle: options.aet, port: options.port,
                tls: connection.tls, asynchronousOperationsWindow: .init(maximumInvoked: options.asyncWindow, maximumPerformed: 1))
            configuration.bindAddress = options.host
            configuration.storage.timeout = options.timeout
            for file in try NetCommand.files([directory]) {
                if let stored = try? DicomStoreRequest(part10FileAt: file),
                   !configuration.storage.transferSyntaxes.contains(stored.transferSyntax) {
                    configuration.storage.transferSyntaxes.append(stored.transferSyntax)
                }
            }
            let provider = DirectoryProvider(directory: root)
            let destinations = try Destinations(values: moveDestination)
            let storage = DicomStorageSCPService(configuration: configuration.storage,
                storage: try DicomFileStorageCache(directoryURL: root))
            var upsPolicy = DicomUnifiedProcedureStepPolicy()
            upsPolicy.fallbackAETitles = fallbackAe
            let server = DicomDIMSEServer(configuration: configuration, storage: storage,
                query: queryRetrieve ? provider : nil, retrieve: queryRetrieve ? provider : nil,
                moveDestinations: destinations,
                unifiedProcedureSteps: ups ? DicomUnifiedProcedureStepService(
                    store: DicomInMemoryUnifiedProcedureStepStore(), policy: upsPolicy) : nil,
                instanceAvailability: ian ? IANReceiver() : nil,
                identity: options.user.map { Identity(username: $0, passcode: options.passcode ?? "") },
                peerPrincipalResolver: ServerSecurityOptions.isLoopback(options.host) && !security.principalScopes.isEmpty
                    ? { @Sendable [principal = security.principal()] _, _, _ in principal } : nil,
                authorizer: options.user != nil || !security.principalScopes.isEmpty
                    ? DicomProtectionAuthorizer(policyVersion: 0, protectionLookup: { _ in [:] }) : nil,
                audit: audit, exposure: exposure)
            try server.start()
            return server
        }
        mutating func run() async throws {
            let server = try start()
            print("Listening on \(server.listeningPort ?? options.port)")
            do { try await Task.sleep(for: .seconds(duration)) }
            catch { await server.stop(); throw error }
            await server.stop()
        }
    }


    struct Identity: DicomUserIdentityAuthenticating {
        let username: String
        let passcode: String
        func authenticate(_ identity: DicomUserIdentity) throws -> DicomUserIdentityServerResponse? {
            guard identity.type == .usernameAndPasscode, !username.isEmpty, !passcode.isEmpty,
                  identity.primaryField == Data(username.utf8), identity.secondaryField == Data(passcode.utf8) else {
                throw DicomDIMSEProviderError(status: 0x0124)
            }
            return nil
        }
    }

    struct Destinations: DicomMoveDestinationResolving {
        let entries: [String: DicomMoveDestination]
        init(values: [String]) throws {
            var entries: [String: DicomMoveDestination] = [:]
            for value in values {
                let parts = value.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, let separator = parts[1].lastIndex(of: ":"),
                      let port = UInt16(parts[1][parts[1].index(after: separator)...]), port > 0,
                      entries[String(parts[0])] == nil else {
                    throw ValidationError("Destination must be a unique AE=host:port")
                }
                let host = String(parts[1][..<separator])
                guard !host.isEmpty else { throw ValidationError("Destination host is empty") }
                entries[String(parts[0])] = .init(host: host, port: port)
            }
            self.entries = entries
        }
        func resolve(aeTitle: String) async throws -> DicomMoveDestination? { entries[aeTitle] }
    }

    struct Transcoder: DicomStoreTranscoding {
        func qualifiedTransferSyntaxes(for file: URL) async throws -> [DicomTransferSyntax] {
            let data = try Data(contentsOf: file)
            return try [DicomTransferSyntax.explicitVRLittleEndian, .jpeg2000Lossless].filter {
                try DicomTranscoder().preflight(data, to: $0, intent: .reversible).canExecute
            }
        }
        func transcode(_ file: URL, to syntax: DicomTransferSyntax) async throws -> Data {
            try await DicomTranscoder().transcode(contentsOf: file, to: syntax, intent: .reversible)
        }
    }

    struct DirectoryProvider: DicomQueryProviding, DicomRetrieveProviding {
        let directory: URL
        func matches(for request: DicomQueryRequest) -> AsyncThrowingStream<DicomDataSet, Error> {
            AsyncThrowingStream { continuation in
                do {
                    var seen: Set<String> = []
                    for url in try NetCommand.files([directory.path]) {
                        let stored = try DicomStoreRequest(part10FileAt: url)
                        var data = try DicomDataSetParser.dataSet(from: stored.dataSetData, transferSyntax: stored.transferSyntax)
                        guard try DicomQueryMatcher().matches(data, identifier: request.identifier) else { continue }
                        let tag = request.level == .patient ? 0x00100020 : request.level == .study ? 0x0020000D
                            : request.level == .series ? 0x0020000E : 0x00080018
                        guard seen.insert(data.string(for: tag) ?? stored.sopInstanceUID).inserted else { continue }
                        data = DicomDataSet(elements: data.elements.filter { $0.tag != 0x7FE00010 })
                        if let level = request.level { data.set(.init(tag: 0x00080052, vr: .CS, value: .strings([level.rawValue]))) }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
        func instances(for request: DicomRetrieveRequest) -> AsyncThrowingStream<DicomRetrievableInstance, Error> {
            AsyncThrowingStream { continuation in
                do {
                    for url in try NetCommand.files([directory.path]) {
                        let stored = try DicomStoreRequest(part10FileAt: url)
                        let data = try DicomDataSetParser.dataSet(from: stored.dataSetData, transferSyntax: stored.transferSyntax)
                        guard try DicomQueryMatcher().matches(data, identifier: request.identifier) else { continue }
                        continuation.yield(.init(sopClassUID: stored.sopClassUID, sopInstanceUID: stored.sopInstanceUID,
                            transferSyntaxes: [stored.transferSyntax],
                            resource: data.string(for: .studyInstanceUID).flatMap { study in
                                guard !study.isEmpty, let series = data.string(for: .seriesInstanceUID),
                                      !series.isEmpty else { return nil }
                                return .init(kind: .instance, id: stored.sopInstanceUID,
                                    parent: .init(kind: .series, id: series, parent: .init(kind: .study, id: study)))
                            }) { syntax in
                            guard syntax == stored.transferSyntax else { throw DicomStoreRepresentationRefusal.noQualifiedRepresentation }
                            return stored.dataSetData
                        })
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
}
