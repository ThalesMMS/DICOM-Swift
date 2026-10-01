import Foundation

extension DicomDIMSEServer {
    /// Issue #2817: the C-STORE sub-operations of one C-MOVE, sent on one association to its destination, each
    /// carrying Move Originator AE Title and Message ID (0000,1030/1031). Every SOP class is proposed with all the
    /// transfer syntaxes its objects are available in, and each object is fetched in the first one accepted; the
    /// encoded bytes are never reinterpreted. `outcome` receives each object's C-STORE status as its response
    /// arrives, or nil when the object failed before or without one; objects it never reports failed with the
    /// association.
    func moveInstances(_ instances: [DicomRetrievableInstance], destination: DicomMoveDestination,
                       destinationAETitle: String, originator: (aeTitle: String, messageID: UInt16)?,
                       access: DicomEnforcement?,
                       outcome: @escaping @Sendable (_ index: Int, _ status: UInt16?) throws -> Void) async throws {
        var proposals: [(sopClassUID: String, transferSyntaxes: [DicomTransferSyntax])] = []
        for instance in instances {
            if let index = proposals.firstIndex(where: { $0.sopClassUID == instance.sopClassUID }) {
                for syntax in instance.transferSyntaxes where !proposals[index].transferSyntaxes.contains(syntax) {
                    proposals[index].transferSyntaxes.append(syntax)
                }
            } else {
                proposals.append((instance.sopClassUID, instance.transferSyntaxes))
            }
        }
        let config = DicomDIMSEConnectionConfiguration(host: destination.host, port: destination.port,
            calledAETitle: destinationAETitle, callingAETitle: configuration.storage.aeTitle,
            timeout: configuration.storage.timeout, transferSyntaxes: proposals.flatMap(\.transferSyntaxes),
            tls: destination.tls)
        let handle = DicomDIMSEOperationHandle()
        let proposed = proposals
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try DicomDIMSEServiceSCU(configuration: config, operationHandle: handle).storeSubOperations(
                            count: instances.count,
                            proposals: proposed,
                            moveOriginator: originator,
                            request: { index, accepted in
                                let instance = instances[index]
                                let available = accepted(instance.sopClassUID)
                                guard let syntax = instance.transferSyntaxes.first(where: available.contains) else {
                                    try outcome(index, nil)
                                    return nil
                                }
                                do {
                                    return try DicomIngestBlockingResult.run {
                                        try await Self.subOperationRequest(instance, syntax: syntax, access: access)
                                    }
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch let error as DicomWebServerFailure {
                                    throw error  // A revoked route ends the C-MOVE, as it did per object.
                                } catch let error as DicomAuditError {
                                    throw error
                                } catch {
                                    try outcome(index, nil)
                                    return nil
                                }
                            },
                            completion: { index, result in
                                guard let result else { return }
                                switch result {
                                case .success(let response):
                                    if response.status == 0, let resource = instances[index].resource {
                                        try DicomIngestBlockingResult.run { try await access?.transferred(resource) }
                                    }
                                    try outcome(index, response.status)
                                case .failure:
                                    try outcome(index, nil)
                                }
                            })
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { handle.cancel() }
    }

    private static func subOperationRequest(_ instance: DicomRetrievableInstance, syntax: DicomTransferSyntax,
                                            access: DicomEnforcement?) async throws -> DicomStoreRequest {
        if let resource = instance.resource {
            try await access?.recheck(.readBytes, resource)
            _ = try await access?.check(.route, resource)
        }
        let bytes = try await instance.byteSource(syntax)
        try Task.checkCancellation()
        if let resource = instance.resource {
            try await access?.recheck(.readBytes, resource)
            try await access?.recheck(.route, resource)
        }
        return try DicomStoreRequest(sopClassUID: instance.sopClassUID, sopInstanceUID: instance.sopInstanceUID,
                                     transferSyntax: syntax, dataSetData: bytes)
    }
}
