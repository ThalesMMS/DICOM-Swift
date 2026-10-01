import Foundation

public actor DicomRecallCoordinator {
    public struct Quotas: Sendable {
        public let maxConcurrentTransfers: Int
        public let maxInFlightBytes: Int64
        public let maxQueuedItems: Int
        public init(maxConcurrentTransfers: Int = 2, maxInFlightBytes: Int64 = 1_073_741_824,
                    maxQueuedItems: Int = 10_000) {
            self.maxConcurrentTransfers = maxConcurrentTransfers
            self.maxInFlightBytes = maxInFlightBytes
            self.maxQueuedItems = maxQueuedItems
        }
    }
    public enum Priority: Int, Sendable { case interactive, prefetch }
    private struct Waiter: Hashable {
        let transferID: String
        let index: Int
    }
    private struct Request {
        var manifest: DicomTransferManifest
        var remaining: Set<Int>
        let continuation: CheckedContinuation<DicomTransferManifest, any Error>
    }
    private struct Flight {
        let id: UUID
        let item: DicomTransferManifest.Item
        let source: String
        let destination: String
        let order: Int
        var priority: Priority
        var waiters: Set<Waiter>
        var task: Task<Void, Never>?
    }
    private let lifecycle: (any DicomLifecycleEventEmitting)?
    private let providers: [String: any DicomStorageProvider]
    private let journal: DicomTransferJournal
    private let quotas: Quotas
    private let fileSystem: any DicomIngestFileSystem
    private var requests: [String: Request] = [:]
    private var flights: [UUID: Flight] = [:]
    private var byKey: [String: UUID] = [:]
    private var sequence = 0
    private var activeCount = 0
    private var activeBytes: Int64 = 0
    private var placements: [DicomTransferManifest.Item: DicomObjectPlacement] = [:]

    public init(providers: [String: any DicomStorageProvider], journal: DicomTransferJournal,
                quotas: Quotas = .init(), fileSystem: any DicomIngestFileSystem = DicomLocalIngestFileSystem(),
                lifecycle: (any DicomLifecycleEventEmitting)? = nil) {
        self.lifecycle = lifecycle
        self.providers = providers
        self.journal = journal
        self.quotas = quotas
        self.fileSystem = fileSystem
    }

    public func recall(items: [DicomTransferManifest.Item], from sourceProviderID: String,
                       to destinationProviderID: String, priority: Priority = .interactive) async throws -> DicomTransferManifest {
        let fresh = items.map { item in var item = item; item.state = .pending; return item }
        let manifest = DicomTransferManifest(kind: priority == .interactive ? .recall : .prefetch,
            sourceProviderID: sourceProviderID, destinationProviderID: destinationProviderID, items: fresh)
        return try await submit(manifest, priority: priority)
    }

    private func validate(_ manifest: DicomTransferManifest) throws {
        guard providers[manifest.sourceProviderID] != nil else {
            throw DicomPlacementError.unknownProvider(manifest.sourceProviderID)
        }
        guard let destination = providers[manifest.destinationProviderID] else {
            throw DicomPlacementError.unknownProvider(manifest.destinationProviderID)
        }
        guard destination.tier == .online else { throw DicomStorageProviderError.io("Recall destination must be online") }
        guard quotas.maxConcurrentTransfers > 0, quotas.maxInFlightBytes >= 0, quotas.maxQueuedItems >= 0 else {
            throw DicomPlacementError.quotaExceeded("Invalid quotas")
        }
        var newKeys: Set<String> = []
        var descriptions: [String: DicomTransferManifest.Item] = [:]
        for item in manifest.items where item.state == .pending || item.state == .inFlight {
            guard item.byteCount >= 0, item.byteCount <= quotas.maxInFlightBytes else {
                throw DicomPlacementError.quotaExceeded("Object exceeds byte quota")
            }
            guard !item.objectKey.isEmpty, item.sha256.count == 64,
                  item.sha256.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
                throw DicomStorageProviderError.integrity("Invalid object identity")
            }
            if let prior = descriptions[item.objectKey], !Self.matches(prior, item) {
                throw DicomStorageProviderError.integrity("Conflicting object key")
            }
            descriptions[item.objectKey] = item
            if let id = byKey[item.objectKey], let flight = flights[id] {
                guard flight.source == manifest.sourceProviderID, flight.destination == manifest.destinationProviderID,
                      Self.matches(flight.item, item) else {
                    throw DicomStorageProviderError.integrity("Conflicting in-flight object key")
                }
            } else { newKeys.insert(item.objectKey) }
        }
        guard flights.values.filter({ $0.task == nil }).count + newKeys.count <= quotas.maxQueuedItems else {
            throw DicomPlacementError.quotaExceeded("Queue is full")
        }
    }

    private static func matches(_ a: DicomTransferManifest.Item, _ b: DicomTransferManifest.Item) -> Bool {
        a.sourceLocator == b.sourceLocator && a.destinationLocator == b.destinationLocator
            && a.byteCount == b.byteCount && a.sha256 == b.sha256
    }

    private func submit(_ manifest: DicomTransferManifest, priority: Priority) async throws -> DicomTransferManifest {
        try StoragePath.checkCancellation { false }
        guard requests[manifest.transferID] == nil else { throw DicomPlacementError.journal("Transfer already active") }
        try validate(manifest)
        try journal.save(manifest)
        for item in manifest.items where item.state == .verified {
            placements[item] = .init(objectKey: item.objectKey, tier: .online,
                providerID: manifest.destinationProviderID, locator: item.destinationLocator,
                byteCount: item.byteCount, sha256: item.sha256, recordedAt: manifest.createdAt)
        }
        let pending = Set(manifest.items.indices.filter {
            manifest.items[$0].state == .pending || manifest.items[$0].state == .inFlight
        })
        if pending.isEmpty { return manifest }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: DicomStorageProviderError.cancelled); return }
                requests[manifest.transferID] = Request(manifest: manifest, remaining: pending, continuation: continuation)
                for index in pending.sorted() {
                    let item = manifest.items[index]
                    let waiter = Waiter(transferID: manifest.transferID, index: index)
                    if let id = byKey[item.objectKey], var flight = flights[id] {
                        flight.waiters.insert(waiter)
                        if priority.rawValue < flight.priority.rawValue { flight.priority = priority }
                        flights[id] = flight
                        if flight.task != nil {
                            do { try setState(waiter, .inFlight) }
                            catch { abort(manifest.transferID, error: error); break }
                        }
                    } else {
                        let id = UUID()
                        sequence += 1
                        flights[id] = Flight(id: id, item: item, source: manifest.sourceProviderID,
                            destination: manifest.destinationProviderID, order: sequence, priority: priority,
                            waiters: [waiter], task: nil)
                        byKey[item.objectKey] = id
                    }
                }
                pump()
            }
        } onCancel: { Task { await self.cancel(transferID: manifest.transferID) } }
    }

    private func setState(_ waiter: Waiter, _ state: DicomTransferManifest.RecallState) throws {
        guard var request = requests[waiter.transferID] else { return }
        request.manifest.items[waiter.index].state = state
        try journal.save(request.manifest)
        requests[waiter.transferID] = request
    }

    private func pump() {
        while activeCount < quotas.maxConcurrentTransfers {
            let queue = flights.values.filter { $0.task == nil && !$0.waiters.isEmpty }
                .sorted { ($0.priority.rawValue, $0.order) < ($1.priority.rawValue, $1.order) }
            guard let next = queue.first, next.item.byteCount <= quotas.maxInFlightBytes - activeBytes else { return }
            do { for waiter in next.waiters { try setState(waiter, .inFlight) } }
            catch {
                for waiter in next.waiters { abort(waiter.transferID, error: error) }
                continue
            }
            guard var flight = flights[next.id], !flight.waiters.isEmpty else { continue }
            let source = providers[flight.source]!
            let destination = providers[flight.destination]!
            let stage = journal.directory.appendingPathComponent("staging").appendingPathComponent(flight.id.uuidString)
            let fileSystem = self.fileSystem
            let item = flight.item
            let id = flight.id
            activeCount += 1
            activeBytes += item.byteCount
            flight.task = Task.detached {
                let result: Result<Void, any Error>
                do {
                    try await Self.transfer(item, source: source, destination: destination, stage: stage, fileSystem: fileSystem)
                    result = .success(())
                } catch { result = .failure(error) }
                await self.finish(id, result: result)
            }
            flights[id] = flight
        }
    }

    private static func transfer(_ item: DicomTransferManifest.Item, source: any DicomStorageProvider,
                                 destination: any DicomStorageProvider, stage: URL,
                                 fileSystem: any DicomIngestFileSystem) async throws {
        try StoragePath.checkCancellation { false }
        try fileSystem.createDirectory(stage)
        defer { try? fileSystem.remove(stage) }
        let download = stage.appendingPathComponent("object")
        if item.state == .inFlight, let cleaner = destination as? any StoragePartialCleaning {
            try await cleaner.discardPartial(item.destinationLocator)
        }
        if try await destination.head(item.destinationLocator) == nil {
            guard let sourceInfo = try await source.head(item.sourceLocator) else {
                throw DicomStorageProviderError.notFound(item.sourceLocator)
            }
            guard sourceInfo.byteCount == item.byteCount else { throw DicomStorageProviderError.integrity("Source size") }
            _ = try await source.get(item.sourceLocator, to: download, expectedSHA256: item.sha256, isCancelled: { Task.isCancelled })
            try verify(download, item: item, fileSystem: fileSystem)
            try StoragePath.checkCancellation { false }
            _ = try await destination.put(download, locator: item.destinationLocator, expectedSHA256: item.sha256,
                                          isCancelled: { Task.isCancelled })
        }
        // Also handles publication completed just before an interrupted journal update.
        let verification = stage.appendingPathComponent("verification")
        _ = try await destination.get(item.destinationLocator, to: verification, expectedSHA256: item.sha256,
                                      isCancelled: { Task.isCancelled })
        try verify(verification, item: item, fileSystem: fileSystem)
        try StoragePath.checkCancellation { false }
    }

    private static func verify(_ url: URL, item: DicomTransferManifest.Item,
                               fileSystem: any DicomIngestFileSystem) throws {
        let actual = try StoragePath.info(url, locator: item.destinationLocator, fileSystem: fileSystem)
        guard actual.sha256 == item.sha256, actual.byteCount == item.byteCount else {
            throw DicomStorageProviderError.integrity(item.objectKey)
        }
    }

    private func finish(_ id: UUID, result: Result<Void, any Error>) async {
        var events: [DicomLifecycleEvent] = []
        var completed: [Request] = []
        guard let flight = flights.removeValue(forKey: id) else { return }
        if byKey[flight.item.objectKey] == id { byKey.removeValue(forKey: flight.item.objectKey) }
        activeCount -= 1
        activeBytes -= flight.item.byteCount
        for waiter in flight.waiters {
            guard requests[waiter.transferID] != nil else { continue }
            let state: DicomTransferManifest.RecallState
            switch result {
            case .success: state = .verified
            case .failure(let error): state = .failed(String(describing: error))
            }
            do {
                try setState(waiter, state)
                guard var request = requests[waiter.transferID] else { continue }
                request.remaining.remove(waiter.index)
                if state == .verified {
                    let item = request.manifest.items[waiter.index]
                    events.append(try DicomLifecycleEvent(kind: .available, subject: .init(objectCount: 1),
                        sourceKind: "recall", sourceRef: waiter.transferID + ":" + item.objectKey,
                        durability: .fileSynced))
                    placements[item] = .init(objectKey: item.objectKey, tier: .online, providerID: flight.destination,
                        locator: item.destinationLocator, byteCount: item.byteCount, sha256: item.sha256)
                }
                requests[waiter.transferID] = request
                if request.remaining.isEmpty {
                    requests.removeValue(forKey: waiter.transferID)
                    completed.append(request)
                }
            } catch { abort(waiter.transferID, error: error) }
        }
        for event in events { await lifecycle?.emit(event) }
        for request in completed { request.continuation.resume(returning: request.manifest) }
        pump()
    }

    public func cancel(transferID: String) {
        abort(transferID, error: DicomStorageProviderError.cancelled)
        pump()
    }

    private func abort(_ transferID: String, error: any Error) {
        guard let request = requests.removeValue(forKey: transferID) else { return }
        for id in Array(flights.keys) {
            guard var flight = flights[id] else { continue }
            flight.waiters = flight.waiters.filter { $0.transferID != transferID }
            flights[id] = flight
            if flight.waiters.isEmpty {
                if let task = flight.task {
                    // Keep ownership until cooperative cancellation has finished all destination I/O.
                    task.cancel()
                } else {
                    if byKey[flight.item.objectKey] == id { byKey.removeValue(forKey: flight.item.objectKey) }
                    flights.removeValue(forKey: id)
                }
            }
        }
        // Leave pending/inFlight states durable for resume; cancellation is not object failure.
        request.continuation.resume(throwing: error)
    }

    public func resume() async throws -> [DicomTransferManifest] {
        guard requests.isEmpty, activeCount == 0 else { throw DicomPlacementError.journal("Coordinator is active") }
        // A new owner restarts incomplete downloads, never trusts leftover partial bytes.
        let stage = journal.directory.appendingPathComponent("staging")
        if try fileSystem.exists(stage) { try fileSystem.remove(stage) }
        let pending = try journal.pending()
        let results = await withTaskGroup(of: (Int, Result<DicomTransferManifest, any Error>).self) { group in
            for (index, manifest) in pending.enumerated() {
                group.addTask {
                    do {
                        let result = try await self.submit(manifest,
                            priority: manifest.kind == .prefetch ? .prefetch : .interactive)
                        return (index, .success(result))
                    } catch { return (index, .failure(error)) }
                }
            }
            var results: [(Int, Result<DicomTransferManifest, any Error>)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }
        return try results.map { try $0.1.get() }
    }

    public func placement(after item: DicomTransferManifest.Item) throws -> DicomObjectPlacement {
        guard item.state == .verified, let placement = placements[item] else {
            throw DicomStorageProviderError.integrity("Item has no verified placement in this coordinator")
        }
        return placement
    }
}
