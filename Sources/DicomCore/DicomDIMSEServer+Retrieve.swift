import Foundation

extension DicomDIMSEServer {
    func retrieve(_ command: DicomDIMSECommandSet, context: DicomAcceptedPresentationContext,
                  identifier: DicomDataSet?, session: DicomDIMSEServerSession, move: Bool) async throws {
        let query = try queryRequest(context: context, identifier: identifier, session: session)
        guard let provider = retrieve, let level = query.level else { throw DicomDIMSEProviderError(status: 0xA900) }
        var destination: DicomMoveDestination?
        if move {
            destination = try await moveDestinations?.resolve(aeTitle: command.moveDestination ?? "")
            guard destination != nil else { throw DicomDIMSEProviderError(status: 0xA801) }
        }
        let request = DicomRetrieveRequest(model: query.model, level: level,
            identifier: query.identifier, requestingAETitle: query.requestingAETitle, associationContext: session.authorizationContext)
        var instances: [DicomRetrievableInstance] = []
        var authorizationFilteredInstances = false
        var completed: UInt16 = 0, failed: UInt16 = 0, warning: UInt16 = 0
        var failedUIDs: [String] = []
        var remaining: UInt16 = 0
        do {
            // Enumerate descriptors, never payloads, to provide the mandatory remaining count.
            for try await instance in provider.instances(for: request) {
                try Task.checkCancellation()
                guard instances.count < min(Int(UInt16.max), configuration.maximumRetrieveObjects) else {
                    throw DicomDIMSEProviderError(status: 0xA701)
                }
                if authorizer != nil {
                    guard let resource = instance.resource, resource.kind == .instance,
                          resource.id == instance.sopInstanceUID,
                          resource.ancestry.contains(where: { $0.kind == .study }),
                          try await enforcement(session).check(.readBytes, resource, filtering: true) else {
                        authorizationFilteredInstances = true
                        continue
                    }
                }
                instances.append(instance)
            }
            if instances.isEmpty, authorizationFilteredInstances { throw DicomDIMSEProviderError(status: 0xA702) }
            remaining = UInt16(instances.count)
            if let destination {
                // Issue #2817: one sub-association for the whole C-MOVE, a pending response per object.
                let tally = DicomRetrieveTally(remaining: remaining)
                let uids = instances.map(\.sopInstanceUID)
                let originator = command.messageID.map { (aeTitle: session.association.request.callingAETitle, messageID: $0) }
                do {
                    try await moveInstances(instances, destination: destination,
                                            destinationAETitle: command.moveDestination ?? "",
                                            originator: originator, access: enforcement(session)) { index, status in
                        let counts = tally.record(index: index, status: status,
                                                  sopInstanceUID: uids[index])
                        try session.retrieveReply(command, contextID: context.id, status: 0xFF00,
                            remaining: counts.remaining, completed: counts.completed, failed: counts.failed,
                            warning: counts.warning)
                    }
                } catch is CancellationError {
                    (remaining, completed, failed, warning, failedUIDs) = tally.snapshot
                    throw CancellationError()
                } catch is DicomWebServerFailure {
                    throw DicomDIMSEProviderError(status: 0xA702)
                } catch is DicomAuditError {
                    throw DicomDIMSEProviderError(status: 0xA702)
                } catch {
                    // The association failed: every object it did not answer failed with it.
                }
                tally.failUnreported(uids)
                (remaining, completed, failed, warning, failedUIDs) = tally.snapshot
                try Task.checkCancellation()
                try session.retrieveReply(command, contextID: context.id,
                    status: failed > 0 || warning > 0 ? 0xB000 : 0, remaining: nil,
                    completed: completed, failed: failed, warning: warning, failedUIDs: failedUIDs)
                return
            }
            for instance in instances {
                try Task.checkCancellation()
                let status: UInt16
                do {
                    if let resource = instance.resource { try await enforcement(session).recheck(.readBytes, resource) }
                    status = try await getInstance(instance, session: session)
                } catch is CancellationError { throw CancellationError() }
                catch is DicomWebServerFailure { throw DicomDIMSEProviderError(status: 0xA702) }
                catch is DicomAuditError { throw DicomDIMSEProviderError(status: 0xA702) }
                catch {
                    failed += 1
                    remaining -= 1
                    failedUIDs.append(instance.sopInstanceUID)
                    try session.retrieveReply(command, contextID: context.id, status: 0xFF00,
                        remaining: remaining, completed: completed, failed: failed, warning: warning)
                    continue
                }
                remaining -= 1
                if status == 0 { completed += 1 }
                else if status & 0xF000 == 0xB000 { warning += 1 }
                else { failed += 1; failedUIDs.append(instance.sopInstanceUID) }
                try session.retrieveReply(command, contextID: context.id, status: 0xFF00,
                    remaining: remaining, completed: completed, failed: failed, warning: warning)
            }
            try Task.checkCancellation()
            try session.retrieveReply(command, contextID: context.id,
                status: failed > 0 || warning > 0 ? 0xB000 : 0, remaining: nil,
                completed: completed, failed: failed, warning: warning, failedUIDs: failedUIDs)
        } catch is CancellationError {
            try session.retrieveReply(command, contextID: context.id, status: 0xFE00, remaining: remaining,
                completed: completed, failed: failed, warning: warning, failedUIDs: failedUIDs)
        }
    }

    private func getInstance(_ instance: DicomRetrievableInstance,
                             session: DicomDIMSEServerSession) async throws -> UInt16 {
        guard session.association.negotiatedRoleSelection(for: instance.sopClassUID)?.scpRole == true,
              let context = session.association.acceptedPresentationContexts.first(where: {
                  $0.abstractSyntaxUID == instance.sopClassUID && $0.transferSyntax.map(instance.transferSyntaxes.contains) == true
              }), let syntax = context.transferSyntax else { throw DicomDIMSEProviderError(status: 0xA702) }
        let bytes = try await instance.byteSource(syntax)
        try Task.checkCancellation()
        if let resource = instance.resource {
            try await enforcement(session).recheck(.readBytes, resource)
            try await enforcement(session).transferred(resource)
        }
        let command = DicomDIMSECommandSet(affectedSOPClassUID: instance.sopClassUID,
            commandField: DicomDIMSECommandField.cStoreRQ,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet, priority: 0,
            affectedSOPInstanceUID: instance.sopInstanceUID)
        return try await session.suboperation(command, contextID: context.id, bytes: bytes).status ?? 0xC000
    }
}

extension DicomDIMSEServerSession {
    func retrieveReply(_ request: DicomDIMSECommandSet, contextID: UInt8, status: UInt16,
                       remaining: UInt16?, completed: UInt16, failed: UInt16, warning: UInt16,
                       failedUIDs: [String] = []) throws {
        let bytes: Data?
        if !failedUIDs.isEmpty && status != 0xFF00 {
            bytes = try DicomDataSetWriter.dataSetData(from: DicomDataSet(elements: [
                DicomDataElement(tag: 0x00080058, vr: .UI, value: .strings(failedUIDs))
            ]), transferSyntax: try context(contextID).transferSyntax ?? .implicitVRLittleEndian)
        } else { bytes = nil }
        let response = DicomDIMSECommandSet(affectedSOPClassUID: request.affectedSOPClassUID,
            commandField: request.commandField | 0x8000, messageIDBeingRespondedTo: request.messageID,
            commandDataSetType: bytes == nil ? DicomDIMSECommandDataSetType.noDataSet : DicomDIMSECommandDataSetType.hasDataSet,
            status: status, remainingSuboperations: remaining, completedSuboperations: completed,
            failedSuboperations: failed, warningSuboperations: warning)
        try send(response, contextID: contextID, bytes: bytes)
    }
}
