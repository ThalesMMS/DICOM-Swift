//
//  DicomRepresentationGenerator.swift
//  DicomCore
//
//  One registry per injected sink/configuration. A cancelled waiter leaves other waiters running.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

/// Internal resource limits of representation generation (issue #3230). They are not user settings.
public struct DicomRepresentationGenerationLimits: Equatable, Sendable {
    /// Derivatives kept per instance in the persistent cache. A need beyond it is still served: the
    /// verified output is delivered once as a temporary representation and not published.
    public var persistentBudget: Int
    /// Largest planned memory one generation may hold (source, output and the two decoded copies the
    /// equivalence check compares). Beyond it the generation is refused as `.workspaceExhausted`.
    public var maximumWorkingSetBytes: Int
    /// Generations that execute at once; further ones wait for a slot.
    public var maximumConcurrentGenerations: Int

    public init(persistentBudget: Int, maximumWorkingSetBytes: Int, maximumConcurrentGenerations: Int) {
        self.persistentBudget = max(0, persistentBudget)
        self.maximumWorkingSetBytes = max(0, maximumWorkingSetBytes)
        self.maximumConcurrentGenerations = max(1, maximumConcurrentGenerations)
    }

    public static let standard = Self(persistentBudget: 2, maximumWorkingSetBytes: 2 << 30,
                                      maximumConcurrentGenerations: 2)

    /// Memory one generation holds at once: the source, the output (at most the decoded size) and the
    /// two decoded copies compared by the equivalence check.
    static func estimatedWorkingSetBytes(_ plan: DicomTranscodeExecutionPlan) -> Int {
        let decoded = plan.cost.decodedFrameBytes.multipliedReportingOverflow(by: max(1, plan.cost.frameCount))
        guard !decoded.overflow else { return .max }
        let copies = decoded.partialValue.multipliedReportingOverflow(by: 3)
        guard !copies.overflow else { return .max }
        let total = plan.cost.inputBytes.addingReportingOverflow(copies.partialValue)
        return total.overflow ? .max : max(total.partialValue, plan.cost.workingSetBytes)
    }
}

/// One registry per injected sink/configuration. A cancelled waiter leaves other waiters running.
public actor DicomRepresentationGenerator {
    public struct Output: Sendable {
        public let bytes: Data
        public let descriptor: DicomArchiveRepresentation
        /// False when the persistent budget was full: `bytes` are a temporary representation for this
        /// delivery only, `descriptor.availability` is `.generatable`, and nothing was published.
        /// The caller owns the bytes; releasing them is the clean-up.
        public let persisted: Bool
    }
    private struct Key: Hashable {
        let source: String
        let syntax: String
        let parameters: String
    }
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Output, any Error>]
    }
    private var flights: [Key: Flight] = [:]
    private let store: any DicomRepresentationStoring
    private let creatorIdentifier: String
    private let configurationHash: String
    private let toolkitVersion: String
    private let environment: [String: String]
    private let limits: DicomRepresentationGenerationLimits
    private var runningGenerations = 0
    private var slotWaiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
    // Internal execution seam exercises failures and cancellation without substituting public codec qualification.
    var execute: @Sendable (DicomTranscodeExecutionPlan, Data, [String: String]) async throws -> Data = { plan, bytes, env in
        guard let output = try await DicomTranscoder().execute(plan, source: bytes, environment: env).data else {
            throw DicomRepresentationRefusal.generationFailed
        }
        return output
    }

    public init(store: any DicomRepresentationStoring, creatorIdentifier: String, configurationHash: String,
                toolkitVersion: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                limits: DicomRepresentationGenerationLimits = .standard) {
        self.store = store; self.creatorIdentifier = creatorIdentifier; self.configurationHash = configurationHash
        self.toolkitVersion = toolkitVersion; self.environment = environment; self.limits = limits
    }

    func setExecutor(_ executor: @escaping @Sendable (DicomTranscodeExecutionPlan, Data, [String: String]) async throws -> Data) {
        execute = executor
    }

    public func generate(set: DicomRepresentationSet, to syntax: DicomTransferSyntax,
                         parameters: DicomArchiveRepresentation.Parameters = .init(),
                         policy: DicomRepresentationLossPolicy = .losslessEquivalents) async throws -> Output {
        if Task.isCancelled { throw DicomRepresentationRefusal.cancelled }
        guard policy != .originalOnly, !parameters.intent.isLossy || policy.allowsLossy else {
            throw DicomRepresentationRefusal.noEligibleRepresentation([])
        }
        guard parameters.intent.isLossy || syntax.registryEntry.isLossless else {
            throw DicomRepresentationValidationError.invalidParameters
        }
        let original = set.original
        let revision = try await store.generationRevision(for: original.sourceSOPInstanceUID)
        let bytes = try await store.bytes(for: original)
        guard DicomArchiveRepresentation.hash(bytes) == original.contentSHA256,
              let current = try await store.representations(for: original.sourceSOPInstanceUID),
              current.original.contentSHA256 == original.contentSHA256 else {
            throw DicomRepresentationRefusal.sourceChanged
        }
        // A full persistent budget no longer refuses the delivery (issue #3230): the output below is
        // then served once as a temporary representation.
        let limits = self.limits
        let key = Key(source: original.contentSHA256, syntax: syntax.rawValue, parameters: parameters.hash)
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: DicomRepresentationRefusal.cancelled); return }
                if flights[key] != nil {
                    flights[key]!.waiters[waiter] = continuation
                    return
                }
                let id = UUID()
                let store = self.store
                let config = configurationHash
                let creator = creatorIdentifier
                let version = toolkitVersion
                let env = environment
                let executor = execute
                let task = Task {
                    let result: Result<Output, any Error>
                    var holdsSlot = false
                    do {
                        try await self.acquireGenerationSlot()
                        holdsSlot = true
                        let transcoder = DicomTranscoder()
                        let preflight = try transcoder.preflight(bytes, to: syntax, intent: parameters.intent,
                                                                environment: env, verifyDecodedPixels: false)
                        guard preflight.canExecute else { throw DicomRepresentationRefusal.codecUnavailable }
                        let plan = try transcoder.plan(bytes, to: syntax, intent: parameters.intent, environment: env)
                        let codec = try Self.codec(bytes, syntax: syntax, parameters: parameters, environment: env,
                                                   toolkitVersion: version)
                        if let cached = current.representations.first(where: {
                            item in
                            guard case .stored = item.availability else { return false }
                            return item.kind != .original && item.transferSyntax == syntax && item.parameters == parameters
                                && item.codec == codec && item.provenance.configurationHash == config
                        }) {
                            result = .success(.init(bytes: try await store.bytes(for: cached), descriptor: cached,
                                                    persisted: true))
                        } else {
                            guard DicomRepresentationGenerationLimits.estimatedWorkingSetBytes(plan)
                                    <= limits.maximumWorkingSetBytes else {
                                throw DicomRepresentationRefusal.workspaceExhausted
                            }
                            let output = try await executor(plan, bytes, env)
                            try Task.checkCancellation()
                            let source = try DCMDecoder(data: bytes)
                            let decoded = try DCMDecoder(data: output)
                            let request = try DicomStoreRequest(part10Data: output)
                            guard request.transferSyntax == syntax,
                                  request.sopClassUID == source.dataSet.string(for: .sopClassUID) else {
                                throw DicomRepresentationRefusal.invalidOutput
                            }
                            if parameters.intent.isLossy {
                                guard request.sopInstanceUID != original.sourceSOPInstanceUID,
                                      decoded.dataSet.string(for: .imageType)?.hasPrefix("DERIVED") == true,
                                      decoded.dataSet.string(for: 0x00082111)?.isEmpty == false,
                                      decoded.dataSet.element(for: .sourceImageSequence)?.sequenceItems.contains(where: {
                                          $0.dataSet.string(for: .referencedSOPInstanceUID) == original.sourceSOPInstanceUID
                                      }) == true else { throw DicomRepresentationRefusal.invalidOutput }
                            } else {
                                guard request.sopInstanceUID == original.sourceSOPInstanceUID,
                                      decoded.dataSet.element(for: .imageType) == source.dataSet.element(for: .imageType),
                                      decoded.dataSet.element(for: 0x04000561) == source.dataSet.element(for: 0x04000561) else {
                                    throw DicomRepresentationRefusal.invalidOutput
                                }
                            }
                            let verification = try transcoder.preflight(bytes, to: syntax, intent: parameters.intent,
                                                                       environment: env, verifyDecodedPixels: true)
                            if verification.canExecute && plan.cost.frameCount > 0 {
                                let engine = DicomCodecWorkflowEngine()
                                let a = try await engine.decode(bytes, environment: env)
                                let b = try await engine.decode(output, environment: env)
                                let equal = parameters.intent.isLossy
                                    ? a.report.frames.map { [$0.width, $0.height, $0.componentCount] }
                                        == b.report.frames.map { [$0.width, $0.height, $0.componentCount] }
                                    : a.data == b.data
                                guard equal else { throw DicomRepresentationRefusal.invalidOutput }
                            }
                            let descriptor = DicomArchiveRepresentation(
                                kind: parameters.intent.isLossy ? .lossyDerived : .losslessEquivalent,
                                sourceSOPInstanceUID: original.sourceSOPInstanceUID,
                                representationSOPInstanceUID: request.sopInstanceUID, transferSyntax: syntax,
                                contentSHA256: DicomArchiveRepresentation.hash(output), sourceContentSHA256: original.contentSHA256,
                                codec: codec, parameters: parameters, quality: DicomArchiveRepresentation.quality(decoded.dataSet),
                                geometry: .init(decoded.dataSet), provenance: .init(createdAt: Date(), creatorIdentifier: creator,
                                    sourceFingerprint: original.contentSHA256, configurationHash: config, toolkitVersion: version),
                                availability: .generatable)
                            _ = try DicomRepresentationSet([original, descriptor])
                            try Task.checkCancellation()
                            let derivatives = current.representations.filter { $0.kind != .original }.count
                            if derivatives < limits.persistentBudget {
                                do {
                                    let stored = try await store.store(bytes: output, representation: descriptor,
                                        derivativeLimit: limits.persistentBudget, expectedRevision: revision)
                                    result = .success(.init(bytes: output, descriptor: stored, persisted: true))
                                } catch DicomRepresentationRefusal.limitReached {
                                    // Another publication filled the budget meanwhile; deliver temporarily, but only
                                    // while the source is still the one this output was verified against.
                                    guard try await store.generationRevision(for: original.sourceSOPInstanceUID) == revision else {
                                        throw DicomRepresentationRefusal.sourceChanged
                                    }
                                    result = .success(.init(bytes: output, descriptor: descriptor, persisted: false))
                                }
                            } else {
                                // The source must still be the one this output was verified against.
                                guard try await store.generationRevision(for: original.sourceSOPInstanceUID) == revision else {
                                    throw DicomRepresentationRefusal.sourceChanged
                                }
                                result = .success(.init(bytes: output, descriptor: descriptor, persisted: false))
                            }
                        }
                    } catch is CancellationError { result = .failure(DicomRepresentationRefusal.cancelled) }
                    catch let error as DicomRepresentationRefusal { result = .failure(error) }
                    catch { result = .failure(DicomRepresentationRefusal.generationFailed) }
                    if holdsSlot { releaseGenerationSlot() }
                    finish(key, id: id, result: result)
                }
                flights[key] = Flight(id: id, task: task, waiters: [waiter: continuation])
            }
        } onCancel: { Task { await self.cancel(key, waiter: waiter) } }
    }

    /// Waits for one of `limits.maximumConcurrentGenerations` slots; cancellation leaves the queue.
    private func acquireGenerationSlot() async throws {
        if runningGenerations < limits.maximumConcurrentGenerations {
            runningGenerations += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                slotWaiters.append((id, continuation))
            }
        } onCancel: { Task { await self.leaveSlotQueue(id) } }
    }

    private func leaveSlotQueue(_ id: UUID) {
        guard let index = slotWaiters.firstIndex(where: { $0.id == id }) else { return }
        slotWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// The slot passes to the next waiter, or is freed.
    private func releaseGenerationSlot() {
        if slotWaiters.isEmpty { runningGenerations -= 1 } else { slotWaiters.removeFirst().continuation.resume() }
    }

    var generationSlotsInUse: Int { runningGenerations }

    private func cancel(_ key: Key, waiter: UUID) {
        guard let continuation = flights[key]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: DicomRepresentationRefusal.cancelled)
        if flights[key]?.waiters.isEmpty == true { flights.removeValue(forKey: key)?.task.cancel() }
    }

    private func finish(_ key: Key, id: UUID, result: Result<Output, any Error>) {
        guard flights[key]?.id == id, let flight = flights.removeValue(forKey: key) else { return }
        for waiter in flight.waiters.values { waiter.resume(with: result) }
    }

    private static func codec(_ bytes: Data, syntax: DicomTransferSyntax,
                              parameters: DicomArchiveRepresentation.Parameters, environment: [String: String],
                              toolkitVersion: String) throws -> DicomArchiveRepresentation.Codec {
        guard let family = DicomCodecFamily.family(for: syntax) else {
            return .init(family: "dataset", identifier: "DicomDataSetWriter", version: toolkitVersion)
        }
        let decoder = try DCMDecoder(data: bytes)
        let decision = DicomCodecCapabilities.resolve(.init(operation: .encode,
            descriptor: DicomTranscoder.compressedFrameDescriptor(decoder: decoder, syntax: syntax), intent: parameters.intent),
            environment: environment)
        guard decision.canExecute, let identifier = decision.backendIdentifier,
              let backend = DicomCodecCapabilities.backendStatuses(environment: environment).first(where: {
                  $0.identifier == identifier
              }) else { throw DicomRepresentationRefusal.codecUnavailable }
        return .init(family: family.rawValue, identifier: identifier, version: backend.version ?? toolkitVersion)
    }
}
