import Foundation

extension DicomDIMSEServiceSCU {
    public func find(identifier: DicomDataSet,
                     queryModelUIDs: [String] = DicomQueryRetrieveModelPreference.find,
                     progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomCFindResult {
        try performWithResilience(operation: .query, progress: progress) { transport in
            try find(identifier: identifier,
                     queryModelUIDs: queryModelUIDs,
                     operation: .query,
                     using: transport,
                     progress: progress)
        }
    }

    public func find(identifier: DicomDataSet,
                     queryModelUIDs: [String] = DicomQueryRetrieveModelPreference.find,
                     using transport: DicomAssociationTransport,
                     progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomCFindResult {
        try find(identifier: identifier,
                 queryModelUIDs: queryModelUIDs,
                 operation: .query,
                 using: transport,
                 progress: progress)
    }

    func find(identifier: DicomDataSet,
              queryModelUIDs: [String],
              operation: DicomDIMSEOperation,
              using transport: DicomAssociationTransport,
              progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomCFindResult {
        let association = try openAssociation(
            for: operation,
            abstractSyntaxUIDs: queryModelUIDs,
            using: transport,
            progress: progress
        )
        defer { try? release(operation: operation, using: transport, progress: progress) }

        let (queryModelUID, context) = try selectedQueryModelContext(from: queryModelUIDs,
                                                                     in: association)
        let identifier = identifierAdapted(identifier, forQueryModel: queryModelUID)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        let messageID: UInt16 = 1
        let command = DicomDIMSECommandSet(
            affectedSOPClassUID: queryModelUID,
            commandField: DicomDIMSECommandField.cFindRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            priority: 0
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        try sendDataSet(identifier,
                        transferSyntax: transferSyntax,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))
        installCancelRequestAction(messageID: messageID,
                                   presentationContextID: context.id,
                                   association: association,
                                   transport: transport)

        let reader = DicomDIMSEMessageReader()
        var matches: [DicomDataSet] = []
        while true {
            let response = try readCommand(using: transport, association: association, reader: reader)
            try expect(response, commandField: DicomDIMSECommandField.cFindRSP)
            let status = response.status ?? 0
            if isPending(status) {
                if response.commandDataSetType != DicomDIMSECommandDataSetType.noDataSet {
                    let payload = try reader.readMessage(from: transport)
                    guard !payload.isCommand else {
                        throw DicomNetworkError.malformedCommandSet("Expected C-FIND identifier dataset.")
                    }
                    matches.append(try DicomDataSetParser.dataSet(from: payload.data,
                                                                  transferSyntax: transferSyntax))
                }
                progressPending(operation: operation, response: response, progress: progress)
                continue
            }
            try operationHandle?.checkCancellation(operation: operation)
            try validateSuccessStatus(response)
            var result = operationResult(from: response)
            result.negotiatedQueryModelUID = queryModelUID
            progress?(.completed(operation: operation, status: result.status))
            return DicomCFindResult(operation: result, matches: matches)
        }
    }

    public func findModalityWorklist(query: DicomModalityWorklistQuery,
                                     progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomModalityWorklistResult {
        let result = try performWithResilience(operation: .modalityWorklist, progress: progress) { transport in
            try find(identifier: query.identifier,
                     queryModelUIDs: [DicomNetworkUID.modalityWorklistInformationModelFind],
                     operation: .modalityWorklist,
                     using: transport,
                     progress: progress)
        }
        return DicomModalityWorklistResult(
            operation: result.operation,
            items: result.matches.map(DicomModalityWorklistItem.init(dataSet:))
        )
    }

    public func findModalityWorklist(query: DicomModalityWorklistQuery,
                                     using transport: DicomAssociationTransport,
                                     progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomModalityWorklistResult {
        let result = try find(identifier: query.identifier,
                              queryModelUIDs: [DicomNetworkUID.modalityWorklistInformationModelFind],
                              operation: .modalityWorklist,
                              using: transport,
                              progress: progress)
        return DicomModalityWorklistResult(
            operation: result.operation,
            items: result.matches.map(DicomModalityWorklistItem.init(dataSet:))
        )
    }

    public func move(identifier: DicomDataSet,
                     moveDestinationAETitle: String,
                     queryModelUIDs: [String] = DicomQueryRetrieveModelPreference.move,
                     progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        try performWithResilience(operation: .moveRetrieve, progress: progress) { transport in
            try move(identifier: identifier,
                     moveDestinationAETitle: moveDestinationAETitle,
                     queryModelUIDs: queryModelUIDs,
                     using: transport,
                     progress: progress)
        }
    }

    public func move(identifier: DicomDataSet,
                     moveDestinationAETitle: String,
                     queryModelUIDs: [String] = DicomQueryRetrieveModelPreference.move,
                     using transport: DicomAssociationTransport,
                     progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        let operation = DicomDIMSEOperation.moveRetrieve
        let association = try openAssociation(
            for: operation,
            abstractSyntaxUIDs: queryModelUIDs,
            using: transport,
            progress: progress
        )
        var didRelease = false
        defer {
            if !didRelease { try? release(operation: operation, using: transport, progress: progress) }
        }

        let (queryModelUID, context) = try selectedQueryModelContext(from: queryModelUIDs,
                                                                     in: association)
        let identifier = identifierAdapted(identifier, forQueryModel: queryModelUID)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        let messageID: UInt16 = 1
        let command = DicomDIMSECommandSet(
            affectedSOPClassUID: queryModelUID,
            commandField: DicomDIMSECommandField.cMoveRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            moveDestination: moveDestinationAETitle,
            priority: 0
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        try sendDataSet(identifier,
                        transferSyntax: transferSyntax,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))
        installCancelRequestAction(messageID: messageID,
                                   presentationContextID: context.id,
                                   association: association,
                                   transport: transport)

        let reader = DicomDIMSEMessageReader()
        while true {
            let response = try readCommand(using: transport, association: association, reader: reader)
            try expect(response, commandField: DicomDIMSECommandField.cMoveRSP)
            let status = response.status ?? 0
            if isPending(status) {
                progressPending(operation: operation, response: response, progress: progress)
                continue
            }
            _ = try readOptionalDataSet(response: response, transferSyntax: transferSyntax,
                                        transport: transport, reader: reader)
            try operationHandle?.checkCancellation(operation: operation)
            try validateRetrieveStatus(response)
            var result = operationResult(from: response)
            result.negotiatedQueryModelUID = queryModelUID
            didRelease = true
            do {
                try release(operation: operation, using: transport, progress: progress, completingRetrieve: true)
            } catch {
                // The final retrieve result is known; failed cleanup must not cause redelivery.
                (transport as? DicomCancellableAssociationTransport)?.close()
            }
            progress?(.completed(operation: operation, status: result.status))
            return result
        }
    }

    public func get(identifier: DicomDataSet,
                    storageSOPClassUIDs: [String] = [DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID],
                    queryModelUIDs: [String] = DicomQueryRetrieveModelPreference.get,
                    progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomCGetResult {
        try performWithResilience(operation: .getRetrieve, progress: progress) { transport in
            try get(identifier: identifier,
                    storageSOPClassUIDs: storageSOPClassUIDs,
                    queryModelUIDs: queryModelUIDs,
                    using: transport,
                    progress: progress)
        }
    }

    public func get(identifier: DicomDataSet,
                    storageSOPClassUIDs: [String] = [DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID],
                    queryModelUIDs: [String] = DicomQueryRetrieveModelPreference.get,
                    onInstance: (DicomRetrievedInstance) throws -> Void,
                    progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        return try performWithResilience(operation: .getRetrieve, progress: progress) { transport in
            var deliveredSOPInstanceUIDs = Set<String>()
            return try get(identifier: identifier,
                    storageSOPClassUIDs: storageSOPClassUIDs,
                    queryModelUIDs: queryModelUIDs,
                    using: transport,
                    onInstance: { instance in
                        if let sopInstanceUID = instance.sopInstanceUID,
                           !sopInstanceUID.isEmpty,
                           !deliveredSOPInstanceUIDs.insert(sopInstanceUID).inserted {
                            return
                        }
                        try onInstance(instance)
                    },
                    progress: progress)
        }
    }

    public func get(identifier: DicomDataSet,
                    storageSOPClassUIDs: [String] = [DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID],
                    queryModelUIDs: [String] = DicomQueryRetrieveModelPreference.get,
                    using transport: DicomAssociationTransport,
                    progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomCGetResult {
        var retrieved: [DicomRetrievedInstance] = []
        let operation = try get(identifier: identifier,
                                storageSOPClassUIDs: storageSOPClassUIDs,
                                queryModelUIDs: queryModelUIDs,
                                using: transport,
                                onInstance: { retrieved.append($0) },
                                progress: progress)
        return DicomCGetResult(operation: operation, retrievedInstances: retrieved)
    }

    public func get(identifier: DicomDataSet,
                    storageSOPClassUIDs: [String] = [DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID],
                    queryModelUIDs: [String] = DicomQueryRetrieveModelPreference.get,
                    using transport: DicomAssociationTransport,
                    onInstance: (DicomRetrievedInstance) throws -> Void,
                    progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        let operation = DicomDIMSEOperation.getRetrieve
        // Issue #1868: C-GET's instances come back as C-STORE sub-operations
        // on this same association, so each storage SOP Class is proposed
        // with an SCP/SCU Role Selection item declaring this side as SCP for
        // the returned stores while it stays SCU for the C-GET itself.
        let association = try openAssociation(
            for: operation,
            abstractSyntaxUIDs: queryModelUIDs + storageSOPClassUIDs,
            roleSelections: storageSOPClassUIDs.map {
                DicomSCPSCURoleSelection.returnedStorage(sopClassUID: $0)
            },
            using: transport,
            progress: progress
        )
        var didRelease = false
        defer {
            if !didRelease { try? release(operation: operation, using: transport, progress: progress) }
        }

        // Refuse before the C-GET request when nothing can come back: every
        // returned-storage class either lost its presentation context or had
        // its SCP role explicitly denied. Sending the C-GET anyway is how a
        // retrieve fails later with an opaque store error — or hangs.
        let usableStorageClasses = storageSOPClassUIDs.filter {
            association.supportsReturnedStorage(for: $0)
        }
        if usableStorageClasses.isEmpty {
            let rejected = storageSOPClassUIDs.count
            throw DicomNetworkError.returnedStorageNotNegotiated(
                "All \(rejected) proposed storage SOP Class(es) were rejected or denied the SCP role."
            )
        }

        let (queryModelUID, context) = try selectedQueryModelContext(from: queryModelUIDs,
                                                                     in: association)
        let identifier = identifierAdapted(identifier, forQueryModel: queryModelUID)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        let messageID: UInt16 = 1
        let command = DicomDIMSECommandSet(
            affectedSOPClassUID: queryModelUID,
            commandField: DicomDIMSECommandField.cGetRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            priority: 0
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        try sendDataSet(identifier,
                        transferSyntax: transferSyntax,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))
        installCancelRequestAction(messageID: messageID,
                                   presentationContextID: context.id,
                                   association: association,
                                   transport: transport)

        let reader = DicomDIMSEMessageReader()
        while true {
            let response = try readCommand(using: transport, association: association, reader: reader)
            switch response.commandField {
            case DicomDIMSECommandField.cStoreRQ:
                let stored = try receiveStoreRequest(response,
                                                     association: association,
                                                     transport: transport,
                                                     reader: reader,
                                                     onInstance: onInstance)
                progress?(.storeReceived(sopInstanceUID: stored.sopInstanceUID))
            case DicomDIMSECommandField.cGetRSP:
                let status = response.status ?? 0
                if isPending(status) {
                    progressPending(operation: operation, response: response, progress: progress)
                    continue
                }
                _ = try readOptionalDataSet(response: response, transferSyntax: transferSyntax,
                                            transport: transport, reader: reader)
                try operationHandle?.checkCancellation(operation: operation)
                try validateRetrieveStatus(response)
                var result = operationResult(from: response)
                result.negotiatedQueryModelUID = queryModelUID
                didRelease = true
                do {
                    try release(operation: operation, using: transport, progress: progress, completingRetrieve: true)
                } catch {
                    // Preserve the completed retrieve and retire its failed association.
                    (transport as? DicomCancellableAssociationTransport)?.close()
                }
                progress?(.completed(operation: operation, status: result.status))
                return result
            default:
                throw DicomNetworkError.unexpectedDIMSECommand(expected: DicomDIMSECommandField.cGetRSP,
                                                               actual: response.commandField)
            }
        }
    }

}

extension DicomDIMSEServiceSCU {
    /// Concurrent FIND operations, optionally followed by C-ECHO on the same association.
    /// Each message is sent whole; the negotiated invoked window bounds outstanding requests.
    public func find(identifiers: [DicomDataSet], verifyOnAssociation: Bool = false) throws -> [DicomCFindResult] {
        try performWithResilience(operation: .query, progress: nil) {
            try find(identifiers: identifiers, verifyOnAssociation: verifyOnAssociation, using: $0)
        }
    }

    public func find(identifiers: [DicomDataSet], verifyOnAssociation: Bool = false,
                     using transport: DicomAssociationTransport) throws -> [DicomCFindResult] {
        guard !identifiers.isEmpty else { return [] }
        let models = DicomQueryRetrieveModelPreference.find
        let association = try openAssociation(for: .query,
            abstractSyntaxUIDs: models + (verifyOnAssociation ? [DicomNetworkUID.verificationSOPClass] : []),
            using: transport, progress: nil)
        defer { try? release(operation: .query, using: transport, progress: nil) }
        let (model, context) = try selectedQueryModelContext(from: models, in: association)
        let echoContext = verifyOnAssociation ? try acceptedContext(DicomNetworkUID.verificationSOPClass, in: association) : nil
        let total = identifiers.count + (verifyOnAssociation ? 1 : 0)
        let window = association.accept.asynchronousOperationsWindow?.maximumInvoked ?? 1
        let limit = window == 0 ? total : Int(window)
        var pending: [UInt16: Int] = [:]
        var matches = Array(repeating: [DicomDataSet](), count: identifiers.count)
        var results = Array<DicomCFindResult?>(repeating: nil, count: identifiers.count)
        var next = 0
        let reader = DicomDIMSEMessageReader()
        while next < total || !pending.isEmpty {
            // Cancellation is installed only between complete message groups, never between fragments.
            operationHandle?.clearCancelAction()
            while next < total && pending.count < limit && operationHandle?.isCancelled != true {
                let index = next
                next += 1
                let id = try association.outstandingOperations.allocateMessageID()
                let echo = index == identifiers.count
                let command = DicomDIMSECommandSet(
                    affectedSOPClassUID: echo ? DicomNetworkUID.verificationSOPClass : model,
                    commandField: echo ? DicomDIMSECommandField.cEchoRQ : DicomDIMSECommandField.cFindRQ,
                    messageID: id,
                    commandDataSetType: echo ? DicomDIMSECommandDataSetType.noDataSet : DicomDIMSECommandDataSetType.hasDataSet,
                    priority: echo ? nil : 0)
                try sendCommand(command, presentationContextID: echo ? echoContext!.id : context.id,
                                association: association, transport: transport)
                if !echo {
                    try sendDataSet(identifierAdapted(identifiers[index], forQueryModel: model),
                                    transferSyntax: context.transferSyntax ?? .explicitVRLittleEndian,
                                    presentationContextID: context.id, association: association, transport: transport)
                }
                pending[id] = index
            }
            let cancellableIDs = pending.filter { $0.value < identifiers.count }.map(\.key)
            installCancelRequestActions(messageIDs: cancellableIDs, presentationContextID: context.id,
                                        association: association, transport: transport)
            if pending.isEmpty { try operationHandle?.checkCancellation(operation: .query) }
            let response = try readCommand(using: transport, association: association, reader: reader)
            guard let id = response.messageIDBeingRespondedTo, let index = pending[id] else {
                throw DicomNetworkError.malformedCommandSet("Unexpected FIND response Message ID.")
            }
            if index == identifiers.count {
                try validateSuccessStatus(response)
                pending.removeValue(forKey: id)
                continue
            }
            if let dataSet = try readOptionalDataSet(response: response,
                transferSyntax: context.transferSyntax ?? .explicitVRLittleEndian, transport: transport, reader: reader) {
                matches[index].append(dataSet)
            }
            if isPending(response.status!) { continue }
            if operationHandle?.isCancelled != true { try validateSuccessStatus(response) }
            var result = operationResult(from: response)
            result.negotiatedQueryModelUID = model
            results[index] = DicomCFindResult(operation: result, matches: matches[index])
            pending.removeValue(forKey: id)
        }
        try operationHandle?.checkCancellation(operation: .query)
        return try results.map {
            guard let result = $0 else { throw DicomNetworkError.malformedCommandSet("Missing FIND result.") }
            return result
        }
    }
}
