import Foundation

extension DicomDIMSEServiceSCU {
    public func store(dataSet: DicomDataSet,
                      sopClassUID: String? = nil,
                      sopInstanceUID: String? = nil,
                      progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        let stable = storageDataSet(dataSet, sopClassUID: sopClassUID, sopInstanceUID: sopInstanceUID)
        return try performWithResilience(operation: .store, progress: progress) { transport in
            try store(dataSet: stable.dataSet,
                      sopClassUID: stable.sopClassUID,
                      sopInstanceUID: stable.sopInstanceUID,
                      using: transport,
                      progress: progress)
        }
    }

    public func store(dataSet: DicomDataSet,
                      sopClassUID: String? = nil,
                      sopInstanceUID: String? = nil,
                      using transport: DicomAssociationTransport,
                      progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        let operation = DicomDIMSEOperation.store
        let storage = storageDataSet(dataSet,
                                     sopClassUID: sopClassUID,
                                     sopInstanceUID: sopInstanceUID)
        let association = try openAssociation(
            for: operation,
            abstractSyntaxUIDs: [storage.sopClassUID],
            using: transport,
            progress: progress
        )
        defer { try? release(operation: operation, using: transport, progress: progress) }

        let context = try acceptedContext(storage.sopClassUID, in: association)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        let messageID: UInt16 = 1
        let command = DicomDIMSECommandSet(
            affectedSOPClassUID: storage.sopClassUID,
            commandField: DicomDIMSECommandField.cStoreRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            priority: 0,
            affectedSOPInstanceUID: storage.sopInstanceUID
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        try sendDataSet(storage.dataSet,
                        transferSyntax: transferSyntax,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))

        let reader = DicomDIMSEMessageReader()
        let response = try readCommand(using: transport, association: association, reader: reader)
        try expect(response, commandField: DicomDIMSECommandField.cStoreRSP)
        try validateSuccessStatus(response)
        let result = operationResult(from: response)
        progress?(.completed(operation: operation, status: result.status))
        return result
    }

    public func store(request: DicomStoreRequest,
                      progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        try performWithResilience(operation: .store, progress: progress) { transport in
            try store(request: request, using: transport, progress: progress)
        }
    }

    public func store(request: DicomStoreRequest,
                      using transport: DicomAssociationTransport,
                      progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        let operation = DicomDIMSEOperation.store
        let proposedSyntaxes = Array(orderedUniqueStoreTransferSyntaxes(request).prefix(128))
        let requestedContexts = proposedSyntaxes.enumerated().map { index, syntax in
            DicomPresentationContextRequest(
                id: UInt8(index * 2 + 1),
                abstractSyntaxUID: request.sopClassUID,
                transferSyntaxes: [syntax]
            )
        }
        let association = try openAssociation(
            for: operation,
            presentationContexts: requestedContexts,
            using: transport,
            progress: progress
        )
        defer { try? release(operation: operation, using: transport, progress: progress) }

        let acceptedContexts = association.acceptedPresentationContexts.filter {
            $0.abstractSyntaxUID == request.sopClassUID
        }
        guard let context = acceptedContexts.first(where: {
            $0.transferSyntaxUID == request.transferSyntax.rawValue
        }) else {
            if let alternative = proposedSyntaxes.dropFirst().compactMap({ syntax in
                acceptedContexts.first { $0.transferSyntaxUID == syntax.rawValue }
            }).first {
                throw DicomNetworkError.transferSyntaxMismatch(
                    expected: request.transferSyntax.rawValue,
                    actual: alternative.transferSyntaxUID
                )
            }
            let rejected = association.accept.presentationContexts.compactMap { accepted -> DicomPresentationContextResult? in
                guard requestedContexts.contains(where: { $0.id == accepted.id }) else { return nil }
                return accepted.result == .acceptance ? nil : accepted.result
            }
            throw DicomNetworkError.presentationContextRejected(
                abstractSyntaxUID: request.sopClassUID,
                result: rejected.contains(.abstractSyntaxNotSupported)
                    ? .abstractSyntaxNotSupported
                    : (rejected.contains(.transferSyntaxNotSupported)
                        ? .transferSyntaxNotSupported
                        : (rejected.first ?? .noReason)),
                proposedTransferSyntaxUIDs: proposedSyntaxes.map(\.rawValue)
            )
        }
        guard context.transferSyntaxUID == request.transferSyntax.rawValue else {
            throw DicomNetworkError.transferSyntaxMismatch(
                expected: request.transferSyntax.rawValue,
                actual: context.transferSyntaxUID
            )
        }

        let messageID: UInt16 = 1
        let command = DicomDIMSECommandSet(
            affectedSOPClassUID: request.sopClassUID,
            commandField: DicomDIMSECommandField.cStoreRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            priority: 0,
            affectedSOPInstanceUID: request.sopInstanceUID
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        try sendDataSetData(request.dataSetData,
                            presentationContextID: context.id,
                            association: association,
                            transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))

        let reader = DicomDIMSEMessageReader()
        let response = try readCommand(using: transport, association: association, reader: reader)
        try expect(response, commandField: DicomDIMSECommandField.cStoreRSP)
        try validateSuccessStatus(response)
        let result = operationResult(from: response)
        progress?(.completed(operation: operation, status: result.status))
        return result
    }

    private func orderedUniqueStoreTransferSyntaxes(_ request: DicomStoreRequest) -> [DicomTransferSyntax] {
        var seen: Set<String> = []
        return ([request.transferSyntax] + request.proposedTransferSyntaxes).filter {
            seen.insert($0.rawValue).inserted
        }
    }

}

extension DicomDIMSEServiceSCU {
    /// Sends a batch on one association. Responses may arrive out of order; results retain input order.
    /// A refused context or failed status affects only that object. No transcoding is performed.
    public func store(requests: [DicomStoreRequest]) throws -> [Result<DicomDIMSEOperationResult, DicomNetworkError>] {
        try performWithResilience(operation: .store, progress: nil) {
            try store(requests: requests, using: $0)
        }
    }

    public func store(requests: [DicomStoreRequest], using transport: DicomAssociationTransport)
        throws -> [Result<DicomDIMSEOperationResult, DicomNetworkError>] {
        guard !requests.isEmpty else { return [] }
        var contexts: [DicomPresentationContextRequest] = []
        for request in requests where !contexts.contains(where: {
            $0.abstractSyntaxUID == request.sopClassUID && $0.transferSyntaxUIDs == [request.transferSyntax.rawValue]
        }) {
            guard contexts.count < 128 else { throw DicomNetworkError.missingPresentationContext }
            contexts.append(.init(id: UInt8(contexts.count * 2 + 1), abstractSyntaxUID: request.sopClassUID,
                                  transferSyntaxes: [request.transferSyntax]))
        }
        let association = try openAssociation(for: .store, presentationContexts: contexts,
                                               using: transport, progress: nil)
        defer { try? release(operation: .store, using: transport, progress: nil) }
        let window = association.accept.asynchronousOperationsWindow?.maximumInvoked ?? 1
        let limit = window == 0 ? requests.count : Int(window)
        var results = Array<Result<DicomDIMSEOperationResult, DicomNetworkError>?>(repeating: nil, count: requests.count)
        var pending: [UInt16: Int] = [:]
        var next = 0
        let reader = DicomDIMSEMessageReader()
        while next < requests.count || !pending.isEmpty {
            while next < requests.count && pending.count < limit {
                let index = next
                next += 1
                let request = requests[index]
                guard let context = association.acceptedPresentationContexts.first(where: {
                    $0.abstractSyntaxUID == request.sopClassUID && $0.transferSyntaxUID == request.transferSyntax.rawValue
                }) else {
                    results[index] = .failure(.presentationContextRejected(
                        abstractSyntaxUID: request.sopClassUID, result: .transferSyntaxNotSupported,
                        proposedTransferSyntaxUIDs: [request.transferSyntax.rawValue]))
                    continue
                }
                let id = try association.outstandingOperations.allocateMessageID()
                let command = DicomDIMSECommandSet(affectedSOPClassUID: request.sopClassUID,
                    commandField: DicomDIMSECommandField.cStoreRQ, messageID: id,
                    commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet, priority: 0,
                    affectedSOPInstanceUID: request.sopInstanceUID)
                // Complete command and dataset before starting another message (PS3.8 E.1).
                try sendCommand(command, presentationContextID: context.id, association: association, transport: transport)
                try sendDataSetData(request.dataSetData, presentationContextID: context.id,
                                    association: association, transport: transport)
                pending[id] = index
            }
            guard !pending.isEmpty else { continue }
            let response = try readCommand(using: transport, association: association, reader: reader)
            try expect(response, commandField: DicomDIMSECommandField.cStoreRSP)
            guard let id = response.messageIDBeingRespondedTo, let index = pending.removeValue(forKey: id) else {
                throw DicomNetworkError.malformedCommandSet("Unexpected batch response Message ID.")
            }
            do {
                try validateSuccessOrWarningStatus(response)
                results[index] = .success(operationResult(from: response))
            } catch let error as DicomNetworkError {
                results[index] = .failure(error)
            }
        }
        return try results.map {
            guard let result = $0 else { throw DicomNetworkError.malformedCommandSet("Missing batch result.") }
            return result
        }
    }
}

extension DicomDIMSEServiceSCU {
    /// Each object has an independent association attempt. Even local I/O, codec, cancellation,
    /// and transport errors produce an outcome; cancellation stops the batch after recording the current object.
    /// No accepted object is replayed with the batch.
    public func store(batch: [URL], policy: DicomStoreRepresentationPolicy,
                      transcoder: (any DicomStoreTranscoding)? = nil) async -> [DicomStoreObjectOutcome] {
        await Self.store(batch: batch, policy: policy, transcoder: transcoder) { request in
            try self.store(request: request)
        }
    }

    /// Injection seam shared by asynchronous application transports and the synchronous SCU.
    public static func store(batch: [URL], policy: DicomStoreRepresentationPolicy,
                             transcoder: (any DicomStoreTranscoding)? = nil,
                             isolation: isolated (any Actor)? = #isolation,
                             send: (DicomStoreRequest) async throws -> DicomDIMSEOperationResult)
        async -> [DicomStoreObjectOutcome] {
        var outcomes: [DicomStoreObjectOutcome] = []
        for file in batch {
            var uid: String?
            var diagnostics: [String] = []
            var attempts: [DicomStoreObjectOutcome.Attempt] = []
            let result: Result<DicomDIMSEOperationResult, any Error>
            do {
                try Task.checkCancellation()
                var request = try DicomStoreRequest(part10FileAt: file)
                uid = request.sopInstanceUID
                // Failed qualification must not prevent sending the original representation.
                let qualified: [DicomTransferSyntax]
                do { qualified = try await transcoder?.qualifiedTransferSyntaxes(for: file) ?? [] }
                catch is CancellationError { throw CancellationError() }
                catch { qualified = []; diagnostics.append(error.localizedDescription) }
                request.proposedTransferSyntaxes = [request.transferSyntax]
                    + policy.alternatives(stored: request.transferSyntax, qualified: qualified)
                do {
                    try Task.checkCancellation()
                    let response = try await send(request)
                    guard response.status == 0 || response.status & 0xFF00 == 0xB000 else {
                        throw DicomNetworkError.dimseStatusFailure(response.status)
                    }
                    attempts.append(.init(transferSyntax: request.transferSyntax, result: .success(response)))
                    result = .success(response)
                } catch {
                    attempts.append(.init(transferSyntax: request.transferSyntax, result: .failure(error)))
                    if let network = error as? DicomNetworkError,
                       case .presentationContextRejected(_, .transferSyntaxNotSupported, _) = network {
                        throw DicomStoreRepresentationRefusal.noQualifiedRepresentation
                    }
                    guard let networkError = error as? DicomNetworkError,
                          case .transferSyntaxMismatch(let expected, let accepted) = networkError,
                          expected == request.transferSyntax.rawValue,
                          let acceptedSyntax = DicomTransferSyntax(rawValue: accepted) else { throw error }
                    guard let transcoder else { throw DicomStoreRepresentationRefusal.noQualifiedRepresentation }
                    let target = try policy.select(stored: request.transferSyntax, qualified: qualified,
                                                   accepted: [acceptedSyntax])
                    do {
                        try Task.checkCancellation()
                        let data = try await transcoder.transcode(file, to: target)
                        let converted = try DicomStoreRequest(part10Data: data)
                        guard converted.sopInstanceUID == request.sopInstanceUID,
                              converted.sopClassUID == request.sopClassUID, converted.transferSyntax == target else {
                            throw DicomStoreRepresentationRefusal.invalidTranscodedIdentityOrSyntax
                        }
                        try Task.checkCancellation()
                        let response = try await send(converted)
                        guard response.status == 0 || response.status & 0xFF00 == 0xB000 else {
                            throw DicomNetworkError.dimseStatusFailure(response.status)
                        }
                        attempts.append(.init(transferSyntax: target, result: .success(response)))
                        result = .success(response)
                    } catch {
                        attempts.append(.init(transferSyntax: target, result: .failure(error)))
                        throw error
                    }
                }
            } catch {
                diagnostics.append(error.localizedDescription)
                result = .failure(error)
            }
            outcomes.append(.init(fileURL: file, sopInstanceUID: uid, attempts: attempts, diagnostics: diagnostics, result: result))
            if Task.isCancelled { break }
            if case .failure(let error) = result, error is CancellationError { break }
        }
        return outcomes
    }
}

/// Additive outcome keeps the legacy batch API and its memberwise construction unchanged.
public struct DicomRepresentationStoreOutcome: Sendable {
    public let outcome: DicomStoreObjectOutcome
    public let decision: DicomRepresentationDecision?
}

public extension DicomDIMSEServiceSCU {
    func store(batch: [URL], policy: DicomRepresentationLossPolicy,
               transcoder: (any DicomStoreTranscoding)? = nil, resolver: any DicomRepresentationResolving)
        async -> [DicomRepresentationStoreOutcome] {
        await Self.store(batch: batch, policy: policy, transcoder: transcoder, resolver: resolver) {
            try self.store(request: $0)
        }
    }

    static func store(batch: [URL], policy: DicomRepresentationLossPolicy,
                      transcoder: (any DicomStoreTranscoding)? = nil, resolver: any DicomRepresentationResolving,
                      isolation: isolated (any Actor)? = #isolation,
                      send: (DicomStoreRequest) async throws -> DicomDIMSEOperationResult)
        async -> [DicomRepresentationStoreOutcome] {
        var outcomes: [DicomRepresentationStoreOutcome] = []
        for file in batch {
            var uid: String?
            var decision: DicomRepresentationDecision?
            var attempts: [DicomStoreObjectOutcome.Attempt] = []
            var diagnostics: [String] = []
            let result: Result<DicomDIMSEOperationResult, any Error>
            do {
                try Task.checkCancellation()
                var request = try DicomStoreRequest(part10FileAt: file)
                uid = request.sopInstanceUID
                guard let set = try await resolver.representations(for: file) else {
                    throw DicomRepresentationRefusal.missingBytes
                }
                guard try DicomArchiveRepresentation.hash(fileAt: file) == set.original.contentSHA256,
                      request.sopInstanceUID == set.original.sourceSOPInstanceUID else {
                    throw DicomRepresentationRefusal.sourceChanged
                }
                let qualified: [DicomTransferSyntax]
                do { qualified = try await transcoder?.qualifiedTransferSyntaxes(for: file) ?? [] }
                catch is CancellationError { throw CancellationError() }
                catch { qualified = []; diagnostics.append(error.localizedDescription) }
                let stored = set.representations.filter {
                    guard case .stored = $0.availability else { return false }
                    return $0.kind == .original || (policy != .originalOnly && $0.kind == .losslessEquivalent)
                        || ($0.kind == .lossyDerived && policy.allowsLossy)
                }
                let targets = policy == .originalOnly ? [] : qualified.filter { $0.registryEntry.isLossless }
                request.proposedTransferSyntaxes = stored.map(\.transferSyntax) + targets
                do {
                    try Task.checkCancellation()
                    let response = try await send(request)
                    guard response.status == 0 || response.status & 0xFF00 == 0xB000 else {
                        throw DicomNetworkError.dimseStatusFailure(response.status)
                    }
                    attempts.append(.init(transferSyntax: request.transferSyntax, result: .success(response)))
                    decision = try DicomRepresentationSelector.select(set: set,
                        peer: .init(acceptedTransferSyntaxes: [request.transferSyntax]), policy: policy)
                    result = .success(response)
                } catch {
                    attempts.append(.init(transferSyntax: request.transferSyntax, result: .failure(error)))
                    guard let network = error as? DicomNetworkError,
                          case .transferSyntaxMismatch(let expected, let actual) = network,
                          expected == request.transferSyntax.rawValue,
                          let syntax = DicomTransferSyntax(rawValue: actual) else { throw error }
                    let converted: DicomStoreRequest
                    if stored.contains(where: { $0.transferSyntax == syntax }) {
                        let selected = try DicomRepresentationSelector.select(set: set,
                            peer: .init(acceptedTransferSyntaxes: [syntax]), policy: policy)
                        decision = selected
                        guard let representation = stored.first(where: {
                            $0.contentSHA256 == selected.chosenRepresentation.contentSHA256
                        }) else { throw DicomRepresentationRefusal.missingBytes }
                        converted = try await resolver.storeRequest(for: representation)
                        guard converted.sopInstanceUID == representation.representationSOPInstanceUID else {
                            throw DicomRepresentationRefusal.invalidOutput
                        }
                    } else {
                        guard targets.contains(syntax), let transcoder else {
                            throw DicomRepresentationRefusal.noEligibleRepresentation([])
                        }
                        try Task.checkCancellation()
                        let bytes = try await transcoder.transcode(file, to: syntax)
                        converted = try DicomStoreRequest(part10Data: bytes)
                        guard converted.sopInstanceUID == request.sopInstanceUID else {
                            throw DicomRepresentationRefusal.invalidOutput
                        }
                        let original = set.original
                        let candidate = DicomArchiveRepresentation(kind: .losslessEquivalent,
                            sourceSOPInstanceUID: original.sourceSOPInstanceUID,
                            representationSOPInstanceUID: converted.sopInstanceUID, transferSyntax: syntax,
                            contentSHA256: DicomArchiveRepresentation.hash(bytes), sourceContentSHA256: original.contentSHA256,
                            codec: original.codec, parameters: .init(), quality: original.quality, geometry: original.geometry,
                            provenance: original.provenance, availability: .generatable)
                        decision = try DicomRepresentationSelector.select(set: .init([original, candidate]),
                            peer: .init(acceptedTransferSyntaxes: [syntax]), policy: policy,
                            cost: .init(generationAllowed: true, estimate: { _ in .init(bytesToSend: bytes.count, codecAvailable: true) }))
                    }
                    guard converted.transferSyntax == syntax, converted.sopClassUID == request.sopClassUID else {
                        throw DicomRepresentationRefusal.invalidOutput
                    }
                    do {
                        try Task.checkCancellation()
                        let response = try await send(converted)
                        guard response.status == 0 || response.status & 0xFF00 == 0xB000 else {
                            throw DicomNetworkError.dimseStatusFailure(response.status)
                        }
                        attempts.append(.init(transferSyntax: syntax, result: .success(response)))
                        result = .success(response)
                    } catch {
                        attempts.append(.init(transferSyntax: syntax, result: .failure(error)))
                        throw error
                    }
                }
            } catch {
                diagnostics.append(error.localizedDescription)
                result = .failure(error)
            }
            outcomes.append(.init(outcome: .init(fileURL: file, sopInstanceUID: uid, attempts: attempts,
                                                 diagnostics: diagnostics, result: result), decision: decision))
            if Task.isCancelled { break }
            if case .failure(let error) = result, error is CancellationError { break }
        }
        return outcomes
    }
}

public extension DicomDIMSEServiceSCU {
    /// Legacy policy bridge. `any` is not an explicit clinical authorization for a new lossy object.
    func store(batch: [URL], policy: DicomStoreRepresentationPolicy,
               transcoder: (any DicomStoreTranscoding)? = nil, resolver: any DicomRepresentationResolving)
        async -> [DicomRepresentationStoreOutcome] {
        await store(batch: batch,
                    policy: policy == .asReceived ? DicomRepresentationLossPolicy.originalOnly : .losslessEquivalents,
                    transcoder: transcoder, resolver: resolver)
    }

    static func store(batch: [URL], policy: DicomStoreRepresentationPolicy,
                      transcoder: (any DicomStoreTranscoding)? = nil, resolver: any DicomRepresentationResolving,
                      isolation: isolated (any Actor)? = #isolation,
                      send: (DicomStoreRequest) async throws -> DicomDIMSEOperationResult)
        async -> [DicomRepresentationStoreOutcome] {
        await store(batch: batch,
                    policy: policy == .asReceived ? DicomRepresentationLossPolicy.originalOnly : .losslessEquivalents,
                    transcoder: transcoder, resolver: resolver, send: send)
    }
}
