import Foundation

/// One registry per injected sink/configuration. A cancelled waiter leaves other waiters running.
public actor DicomRepresentationGenerator {
    public struct Output: Sendable {
        public let bytes: Data
        public let descriptor: DicomArchiveRepresentation
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
    // Internal execution seam exercises failures and cancellation without substituting public codec qualification.
    var execute: @Sendable (DicomTranscodeExecutionPlan, Data, [String: String]) async throws -> Data = { plan, bytes, env in
        guard let output = try await DicomTranscoder().execute(plan, source: bytes, environment: env).data else {
            throw DicomRepresentationRefusal.generationFailed
        }
        return output
    }

    public init(store: any DicomRepresentationStoring, creatorIdentifier: String, configurationHash: String,
                toolkitVersion: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.store = store; self.creatorIdentifier = creatorIdentifier; self.configurationHash = configurationHash
        self.toolkitVersion = toolkitVersion; self.environment = environment
    }

    func setExecutor(_ executor: @escaping @Sendable (DicomTranscodeExecutionPlan, Data, [String: String]) async throws -> Data) {
        execute = executor
    }

    public func generate(set: DicomRepresentationSet, to syntax: DicomTransferSyntax,
                         parameters: DicomArchiveRepresentation.Parameters = .init(),
                         policy: DicomRepresentationLossPolicy = .losslessEquivalents,
                         derivativeLimit: Int) async throws -> Output {
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
        let reusable = current.representations.contains { item in
            guard case .stored = item.availability else { return false }
            return item.kind != .original && item.transferSyntax == syntax && item.parameters == parameters
                && item.provenance.configurationHash == configurationHash
        }
        guard reusable || current.representations.filter({ $0.kind != .original }).count < derivativeLimit else {
            throw DicomRepresentationRefusal.limitReached
        }
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
                    do {
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
                            result = .success(.init(bytes: try await store.bytes(for: cached), descriptor: cached))
                        } else {
                            guard current.representations.filter({ $0.kind != .original }).count < derivativeLimit else {
                                throw DicomRepresentationRefusal.limitReached
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
                            let stored = try await store.store(bytes: output, representation: descriptor, derivativeLimit: derivativeLimit, expectedRevision: revision)
                            result = .success(.init(bytes: output, descriptor: stored))
                        }
                    } catch is CancellationError { result = .failure(DicomRepresentationRefusal.cancelled) }
                    catch let error as DicomRepresentationRefusal { result = .failure(error) }
                    catch { result = .failure(DicomRepresentationRefusal.generationFailed) }
                    finish(key, id: id, result: result)
                }
                flights[key] = Flight(id: id, task: task, waiters: [waiter: continuation])
            }
        } onCancel: { Task { await self.cancel(key, waiter: waiter) } }
    }

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
