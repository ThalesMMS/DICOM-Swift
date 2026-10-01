import Foundation

extension DicomDIMSEServiceSCU {
    /// The print refusals a retry cannot change (issues #1690, #1908): the
    /// same peer will negotiate, grant and refuse the same way, and each
    /// attempt would leave another orphaned film session on the printer.
    /// Other failures pass through the replay classifier, which refuses to
    /// repeat normalized requests after possible socket submission.
    static func isNonRetryablePrintRefusal(_ error: DicomPrintManagementError) -> Bool {
        switch error {
        case .insufficientImageBoxes,
             .annotationBoxNotNegotiated,
             .insufficientAnnotationBoxes,
             .annotationSetFailed,
             .printModeNotNegotiated, .limitExceeded, .expectedImageBoxCountRequired,
             .invalidPresentationLUT, .sopClassMismatch, .missingCreatedUID, .printerFailure,
             .printJobFailure, .monitoringTimedOut, .annotationIgnored, .cancelled, .unsupportedService:
            return true
        case .emptyImageList,
             .invalidImagePosition,
             .unsupportedSnapshotData,
             .imageCountExceedsLayout,
             .invalidAnnotation:
            return false
        }
    }

    func performWithResilience<Result>(
        operation: DicomDIMSEOperation,
        progress: ((DicomDIMSEProgress) -> Void)?,
        _ body: (DicomAssociationTransport) throws -> Result
    ) throws -> Result {
        try validateSecureUserIdentityTransport()
        try operationHandle?.checkCancellation(operation: operation)

        let retryPolicy = configuration.retryPolicy
        var lastError: Error?

        for attempt in 1...retryPolicy.maxAttempts {
            if let circuitBreaker, !circuitBreaker.allowRequest() {
                let error = DicomNetworkError.circuitBreakerOpen(operation.rawValue)
                recordAudit(operation: operation,
                            outcome: .blocked,
                            attempt: attempt,
                            error: error)
                throw error
            }

            recordAudit(operation: operation,
                        outcome: .started,
                        attempt: attempt)
            var tracker: DicomDIMSEReplayTrackingTransport?
            do {
                let transport = DicomDIMSEReplayTrackingTransport(try makeTransport())
                tracker = transport
                var shouldRecycleAssociation = false
                var transportError: Error?
                operationHandle?.setCancelAction {
                    transport.close()
                }
                defer {
                    operationHandle?.clearCancelAction()
                    finishTransport(
                        transport,
                        reusable: shouldRecycleAssociation,
                        error: transportError
                    )
                }
                do {
                    try operationHandle?.checkCancellation(operation: operation)
                    let result = try body(transport)
                    try operationHandle?.checkCancellation(operation: operation)
                    shouldRecycleAssociation = operation.allowsAssociationRecycling
                    circuitBreaker?.recordSuccess()
                    recordAudit(operation: operation,
                                outcome: .succeeded,
                                attempt: attempt,
                                status: statusCode(from: result))
                    return result
                } catch {
                    transportError = error
                    // A PDU the DUL could not accept is answered with A-ABORT
                    // before the connection closes (PS3.8 AA-1/AA-8, issue #2792).
                    if let abort = DicomAbort.forProtocolError(error) {
                        try? transport.writePDU(DicomPDUCodec.encode(.abort(abort)))
                    }
                    throw error
                }
            } catch {
                if let cancelled = cancellationError(for: error, operation: operation) {
                    recordAudit(operation: operation,
                                outcome: .failed,
                                attempt: attempt,
                                error: cancelled)
                    throw cancelled
                }
                if let printError = error as? DicomPrintManagementError,
                   Self.isNonRetryablePrintRefusal(printError) {
                    recordAudit(operation: operation,
                                outcome: .failed,
                                attempt: attempt,
                                error: printError)
                    throw printError
                }
                circuitBreaker?.recordFailure()
                lastError = error
                let safety = DicomDIMSEReplaySafety.classify(operation: operation,
                                                            requestWasSent: tracker?.requestWasSent ?? false)
                if !retryPolicy.allowsReplay(safety) {
                    if case DicomNetworkError.dimseStatusFailure = error { throw error }
                    let uncertain = DicomNetworkError.outcomeUncertain(operation.rawValue)
                    recordAudit(operation: operation, outcome: .failed, attempt: attempt, error: uncertain)
                    throw uncertain
                }
                let shouldRetry = attempt < retryPolicy.maxAttempts
                recordAudit(operation: operation,
                            outcome: shouldRetry ? .retrying : .failed,
                            attempt: attempt,
                            error: error)
                if shouldRetry, retryPolicy.retryDelay > 0 {
                    Thread.sleep(forTimeInterval: retryPolicy.retryDelay)
                }
            }
        }

        throw lastError ?? DicomNetworkError.networkUnavailable("DIMSE operation failed without an underlying error.")
    }

    func cancellationError(for error: Error, operation: DicomDIMSEOperation) -> Error? {
        if operationHandle?.isCancelled == true {
            return DicomNetworkError.operationCancelled(operation.rawValue)
        }
        if error is CancellationError {
            return error
        }
        if let networkError = error as? DicomNetworkError,
           case .operationCancelled = networkError {
            return networkError
        }
        return nil
    }

    func makeTransport() throws -> DicomAssociationTransport {
        if let associationPool {
            return associationPool.makeLease(for: configuration) {
                try makeStandaloneTransport()
            }
        }
        return try makeStandaloneTransport()
    }

    func makeStandaloneTransport() throws -> DicomAssociationTransport {
        if let transportFactory {
            return try transportFactory()
        }
        #if canImport(Network)
        let transport = DicomTCPAssociationTransport(host: configuration.host,
                                                     port: configuration.port,
                                                     timeout: configuration.connectTimeout,
                                                     tls: configuration.tls,
                                                     maximumIncomingPDUSize: configuration.maximumPDULength,
                                                     associationTimeout: configuration.associationTimeout,
                                                     dimseResponseTimeout: configuration.dimseResponseTimeout,
                                                     releaseTimeout: configuration.releaseTimeout)
        try transport.open()
        if let bytesPerSecond = configuration.bandwidthLimitBytesPerSecond {
            return DicomBandwidthLimitedTransport(wrapping: transport,
                                                 bytesPerSecond: bytesPerSecond)
        }
        return transport
        #else
        throw DicomNetworkError.networkUnavailable("Network.framework is not available on this platform.")
        #endif
    }

    func finishTransport(
        _ transport: DicomAssociationTransport,
        reusable: Bool,
        error: Error?
    ) {
        if let lease = ((transport as? DicomDIMSEReplayTrackingTransport)?.underlying ?? transport) as? DicomDIMSEAssociationLease {
            try? lease.finish(reusable: reusable, error: error)
        } else {
            (transport as? DicomCancellableAssociationTransport)?.close()
        }
    }

    private var proposedAsynchronousOperationsWindow: DicomAsynchronousOperationsWindow? {
        configuration.asynchronousOperationsWindow.map {
            // This SCU multiplexes invoked operations; returned-storage C-GET remains serial.
            DicomAsynchronousOperationsWindow(maximumInvoked: $0.maximumInvoked, maximumPerformed: 1)
        }
    }

    func openAssociation(for operation: DicomDIMSEOperation,
                         abstractSyntaxUIDs: [String],
                         transferSyntaxes: [DicomTransferSyntax]? = nil,
                         roleSelections: [DicomSCPSCURoleSelection] = [],
                         using transport: DicomAssociationTransport,
                         progress: ((DicomDIMSEProgress) -> Void)?) throws -> DicomAssociation {
        try validateSecureUserIdentityTransport()

        progress?(.associationRequested(operation: operation,
                                        calledAETitle: configuration.calledAETitle))
        let request = DicomAssociationRequest(
            calledAETitle: configuration.calledAETitle,
            callingAETitle: configuration.callingAETitle,
            presentationContexts: presentationContexts(
                for: abstractSyntaxUIDs,
                transferSyntaxes: transferSyntaxes ?? configuration.transferSyntaxes
            ),
            maximumPDULength: configuration.maximumPDULength,
            userIdentity: configuration.userIdentity,
            roleSelections: roleSelections,
            asynchronousOperationsWindow: operation == .getRetrieve || operation == .moveRetrieve
                ? nil : proposedAsynchronousOperationsWindow,
            extendedNegotiations: configuration.extendedNegotiations
        )
        let association: DicomAssociation
        if let lease = ((transport as? DicomDIMSEReplayTrackingTransport)?.underlying ?? transport) as? DicomDIMSEAssociationLease {
            association = try lease.association(for: request)
        } else {
            association = try DicomAssociationSCU(request: request).open(using: transport)
        }
        progress?(.associationAccepted(operation: operation))
        return association
    }

    func openAssociation(
        for operation: DicomDIMSEOperation,
        presentationContexts: [DicomPresentationContextRequest],
        using transport: DicomAssociationTransport,
        progress: ((DicomDIMSEProgress) -> Void)?
    ) throws -> DicomAssociation {
        try validateSecureUserIdentityTransport()

        progress?(.associationRequested(operation: operation, calledAETitle: configuration.calledAETitle))
        let request = DicomAssociationRequest(
            calledAETitle: configuration.calledAETitle,
            callingAETitle: configuration.callingAETitle,
            presentationContexts: presentationContexts,
            maximumPDULength: configuration.maximumPDULength,
            userIdentity: configuration.userIdentity,
            asynchronousOperationsWindow: proposedAsynchronousOperationsWindow,
            extendedNegotiations: configuration.extendedNegotiations
        )
        let association: DicomAssociation
        if let lease = ((transport as? DicomDIMSEReplayTrackingTransport)?.underlying ?? transport) as? DicomDIMSEAssociationLease {
            association = try lease.association(for: request)
        } else {
            association = try DicomAssociationSCU(request: request).open(using: transport)
        }
        progress?(.associationAccepted(operation: operation))
        return association
    }

    func recordAudit(operation: DicomDIMSEOperation,
                     outcome: DicomNetworkAuditEvent.Outcome,
                     attempt: Int,
                     status: UInt16? = nil,
                     error: Error? = nil) {
        auditLogger?.record(DicomNetworkAuditEvent(
            operation: operation,
            outcome: outcome,
            host: configuration.host,
            port: configuration.port,
            calledAETitle: configuration.calledAETitle,
            attempt: attempt,
            status: status,
            errorDescription: error.map { auditDescription(for: $0) }
        ))
    }

    func statusCode<Result>(from result: Result) -> UInt16? {
        switch result {
        case let value as DicomDIMSEOperationResult:
            return value.status
        case let value as DicomCFindResult:
            return value.operation.status
        case let value as DicomCGetResult:
            return value.operation.status
        case let value as DicomPrintJobResult:
            return value.operation.status
        default:
            return nil
        }
    }

    func validateSecureUserIdentityTransport() throws {
        guard configuration.userIdentity == nil || configuration.tls.mode == .enabled else {
            throw DicomNetworkError.insecureUserIdentityTransport
        }
    }

    func auditDescription(for error: Error) -> String {
        guard let networkError = error as? DicomNetworkError else {
            return String(describing: type(of: error))
        }
        switch networkError {
        case .invalidAEString:
            return "Invalid AE title."
        case .invalidPDUType:
            return "Unsupported PDU type."
        case .invalidPDULength:
            return "Invalid PDU length."
        case .invalidItemType:
            return "Unsupported association item type."
        case .invalidPresentationContextID:
            return "Invalid presentation context ID."
        case .missingApplicationContext:
            return "Missing application context."
        case .missingPresentationContext:
            return "Missing presentation context."
        case .missingTransferSyntax:
            return "Missing transfer syntax."
        case .associationRejected:
            return "Association rejected by peer."
        case .associationAborted:
            return "Association aborted by peer."
        case .invalidAssociationState:
            return "Invalid association state."
        case .unsupportedPDU:
            return "Unsupported PDU."
        case .malformedCommandSet:
            return "Malformed DIMSE command set."
        case .missingAcceptedPresentationContext:
            return "Missing accepted presentation context."
        case .presentationContextRejected:
            return "Presentation context rejected by peer."
        case .transferSyntaxMismatch:
            return "Transfer syntax mismatch."
        case .unexpectedDIMSECommand:
            return "Unexpected DIMSE command."
        case .dimseStatusFailure(let status):
            return String(format: "DIMSE status failure 0x%04X.", status)
        case .networkTimeout(let operation):
            return "Network timeout while \(operation)."
        case .networkUnavailable:
            return "Network transport unavailable."
        case .tlsConfigurationInvalid:
            return "TLS configuration invalid."
        case .tlsTrustEvaluationFailed:
            return "TLS trust evaluation failed."
        case .circuitBreakerOpen:
            return "Circuit breaker open."
        case .insecureUserIdentityTransport:
            return "User identity requires TLS."
        case .returnedStorageNotNegotiated:
            return "No returned-storage capability negotiated for C-GET."
        case .outcomeUncertain:
            return "DIMSE outcome uncertain; request was not replayed."
        case .storageCommitmentRoleNotNegotiated:
            return "Storage Commitment SCP role was not negotiated."
        case .duplicatePDUParameter:
            return "Association PDU repeats a sub-item."
        case .operationCancelled(let operation):
            return "DIMSE operation cancelled: \(operation)."
        }
    }

    func presentationContexts(for abstractSyntaxUIDs: [String],
                              transferSyntaxes: [DicomTransferSyntax]) -> [DicomPresentationContextRequest] {
        var nextID: UInt8 = 1
        var seen: Set<String> = []
        var contexts: [DicomPresentationContextRequest] = []
        for uid in abstractSyntaxUIDs where !seen.contains(uid) {
            seen.insert(uid)
            contexts.append(DicomPresentationContextRequest(
                id: nextID,
                abstractSyntaxUID: uid,
                transferSyntaxes: DicomStorageSOPClassUIDs.transferSyntaxes(transferSyntaxes, forAbstractSyntax: uid)
            ))
            nextID += 2
        }
        return contexts
    }

    func acceptedContext(_ abstractSyntaxUID: String,
                         in association: DicomAssociation) throws -> DicomAcceptedPresentationContext {
        guard let context = association.acceptedPresentationContext(for: abstractSyntaxUID) else {
            throw DicomNetworkError.missingAcceptedPresentationContext(abstractSyntaxUID)
        }
        return context
    }

    /// The first proposed Query/Retrieve model the peer accepted, in
    /// preference order (issue #1867). The choice is driven purely by
    /// association negotiation: a model the peer rejected has no accepted
    /// presentation context, so a Study-Root-capable archive always runs
    /// Study Root and a Patient-Root-only archive falls through to Patient
    /// Root — within the one association, with no retry.
    func selectedQueryModelContext(
        from queryModelUIDs: [String],
        in association: DicomAssociation
    ) throws -> (queryModelUID: String, context: DicomAcceptedPresentationContext) {
        for queryModelUID in queryModelUIDs {
            if let context = association.acceptedPresentationContext(for: queryModelUID) {
                return (queryModelUID, context)
            }
        }
        throw DicomNetworkError.missingAcceptedPresentationContext(
            queryModelUIDs.joined(separator: ", ")
        )
    }

    /// Patient Root drives its hierarchy from Patient ID (0010,0020), which a
    /// Study-Root-shaped identifier legitimately omits. Falling back appends
    /// the universal-match (empty) key so the identifier stays valid under
    /// PS3.4 C.6.1 without changing what it matches; identifiers that already
    /// carry a Patient ID — and every non-Patient-Root model — pass through
    /// untouched.
    func identifierAdapted(_ identifier: DicomDataSet,
                           forQueryModel queryModelUID: String) -> DicomDataSet {
        let patientRootModels = [
            DicomNetworkUID.patientRootQueryRetrieveFind,
            DicomNetworkUID.patientRootQueryRetrieveMove,
            DicomNetworkUID.patientRootQueryRetrieveGet
        ]
        guard patientRootModels.contains(queryModelUID),
              !identifier.contains(DicomTag.patientID) else {
            return identifier
        }
        var adapted = identifier
        adapted.set(DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO, value: .empty))
        return adapted
    }

    func sendCommand(_ command: DicomDIMSECommandSet,
                     presentationContextID: UInt8,
                     association: DicomAssociation,
                     transport: DicomAssociationTransport) throws {
        try association.outstandingOperations.register(command)
        let pdu = try association.commandPData(command,
                                               presentationContextID: presentationContextID)
        guard case .pData(let pdvs) = pdu, let commandPDV = pdvs.first else { return }
        let maximum = association.accept.maximumPDULength
        guard maximum == 0 || maximum > 6 else {
            throw DicomNetworkError.invalidPDULength(expected: 7, actual: Int(maximum))
        }
        let bytes = commandPDV.data
        let fragmentLength = maximum == 0 ? max(1, bytes.count) : Int(maximum) - 6
        for offset in stride(from: 0, to: bytes.count, by: fragmentLength) {
            let end = min(offset + fragmentLength, bytes.count)
            let fragment = DicomPDV(presentationContextID: presentationContextID, isCommand: true,
                                    isLastFragment: end == bytes.count, data: bytes.subdata(in: offset..<end))
            try transport.writePDU(DicomPDUCodec.encode(.pData([fragment])))
        }
    }

    func installCancelRequestAction(messageID: UInt16,
                                    presentationContextID: UInt8,
                                    association: DicomAssociation,
                                    transport: DicomAssociationTransport) {
        installCancelRequestActions(messageIDs: [messageID], presentationContextID: presentationContextID,
                                    association: association, transport: transport)
    }

    func installCancelRequestActions(messageIDs: [UInt16], presentationContextID: UInt8,
                                     association: DicomAssociation, transport: DicomAssociationTransport) {
        let cancelTimeout = configuration.cancelTimeout
        operationHandle?.setCancelAction {
            for id in messageIDs where association.outstandingOperations.state(for: id) == .pending {
                let command = DicomDIMSECommandSet(commandField: DicomDIMSECommandField.cCancelRQ,
                    messageIDBeingRespondedTo: id, commandDataSetType: DicomDIMSECommandDataSetType.noDataSet)
                if let pdu = try? association.commandPData(command, presentationContextID: presentationContextID) {
                    try? transport.writePDU(DicomPDUCodec.encode(pdu))
                }
            }
            let timeout = DispatchWorkItem {
                guard messageIDs.contains(where: { association.outstandingOperations.state(for: $0) == .pending }) else { return }
                try? transport.writePDU(DicomPDUCodec.encode(.abort(.init(source: .serviceUser,
                                                                        reason: .reasonNotSpecified))))
                (transport as? DicomCancellableAssociationTransport)?.close()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + cancelTimeout, execute: timeout)
        }
    }

    func sendDataSet(_ dataSet: DicomDataSet,
                     transferSyntax: DicomTransferSyntax,
                     presentationContextID: UInt8,
                     association: DicomAssociation,
                     transport: DicomAssociationTransport) throws {
        let data = try DicomDataSetWriter.dataSetData(from: dataSet,
                                                      transferSyntax: transferSyntax)
        try sendDataSetData(data,
                            presentationContextID: presentationContextID,
                            association: association,
                            transport: transport)
    }

    func sendDataSetData(_ data: Data,
                         presentationContextID: UInt8,
                         association: DicomAssociation,
                         transport: DicomAssociationTransport) throws {
        let pdvOverhead = 6
        let maximumPDULength = association.accept.maximumPDULength
        let maximumFragmentLength: Int
        if maximumPDULength == 0 {
            maximumFragmentLength = max(1, data.count)
        } else {
            guard maximumPDULength > pdvOverhead else {
                throw DicomNetworkError.invalidPDULength(
                    expected: pdvOverhead + 1,
                    actual: Int(maximumPDULength)
                )
            }
            maximumFragmentLength = Int(maximumPDULength) - pdvOverhead
        }

        if data.isEmpty {
            let pdu = try association.dataSetPData(
                data,
                presentationContextID: presentationContextID
            )
            try transport.writePDU(DicomPDUCodec.encode(pdu))
            return
        }

        var offset = data.startIndex
        while offset < data.endIndex {
            let fragmentLength = min(maximumFragmentLength, data.distance(from: offset, to: data.endIndex))
            let end = data.index(offset, offsetBy: fragmentLength)
            let fragment = data.subdata(in: offset..<end)
            let pdu = try association.dataSetPData(
                fragment,
                presentationContextID: presentationContextID,
                isLastFragment: end == data.endIndex
            )
            try transport.writePDU(DicomPDUCodec.encode(pdu))
            offset = end
        }
    }

    func readCommand(using transport: DicomAssociationTransport,
                     association: DicomAssociation,
                     reader: DicomDIMSEMessageReader) throws -> DicomDIMSECommandSet {
        let message = try reader.readMessage(from: transport)
        guard message.isCommand else {
            throw DicomNetworkError.malformedCommandSet("Expected DIMSE command PDV.")
        }
        let command = try DicomDIMSECommandSet.decode(message.data)
        try association.outstandingOperations.correlate(command)
        return command
    }

    func release(operation: DicomDIMSEOperation,
                 using transport: DicomAssociationTransport,
                 progress: ((DicomDIMSEProgress) -> Void)?,
                 completingRetrieve: Bool = false) throws {
        if let lease = ((transport as? DicomDIMSEReplayTrackingTransport)?.underlying ?? transport) as? DicomDIMSEAssociationLease {
            if completingRetrieve {
                try lease.finish(reusable: false, error: nil)
                progress?(.released(operation: operation))
            }
            return
        }
        try transport.writePDU(DicomPDUCodec.encode(.releaseRequest))
        // PS3.8 Table 9-10, state Sta7: data still in flight arrives before the
        // A-RELEASE-RP (AR-6), and a peer that asked to release at the same time
        // is answered, as the requestor, before its own answer (AR-8, AR-9).
        for _ in 0..<64 {
            let response = try DicomPDUCodec.decode(try transport.readPDU())
            switch response {
            case .releaseResponse:
                progress?(.released(operation: operation))
                return
            case .pData:
                continue
            case .releaseRequest:
                try transport.writePDU(DicomPDUCodec.encode(.releaseResponse))
            case .abort(let abort):
                throw DicomNetworkError.associationAborted(abort)
            default:
                throw DicomNetworkError.unsupportedPDU(response.type)
            }
        }
        throw DicomNetworkError.networkTimeout("releasing association")
    }

    func expect(_ command: DicomDIMSECommandSet, commandField: UInt16) throws {
        guard command.commandField == commandField else {
            throw DicomNetworkError.unexpectedDIMSECommand(expected: commandField,
                                                           actual: command.commandField)
        }
    }

    func validateSuccessStatus(_ command: DicomDIMSECommandSet) throws {
        guard let status = command.status else {
            throw DicomNetworkError.malformedCommandSet("Response is missing Status (0000,0900).")
        }
        guard status == 0 else {
            throw DicomNetworkError.dimseStatusFailure(status)
        }
    }

    func validateSuccessOrWarningStatus(_ command: DicomDIMSECommandSet) throws {
        guard let status = command.status else {
            throw DicomNetworkError.malformedCommandSet("Response is missing Status (0000,0900).")
        }
        guard status == 0 || status & 0xF000 == 0xB000 else {
            throw DicomNetworkError.dimseStatusFailure(status)
        }
    }

    func validateRetrieveStatus(_ command: DicomDIMSECommandSet) throws {
        guard let status = command.status else {
            throw DicomNetworkError.malformedCommandSet("Response is missing Status (0000,0900).")
        }
        guard status == 0 || status & 0xFF00 == 0xB000 else {
            throw DicomNetworkError.dimseStatusFailure(status)
        }
    }

    func isPending(_ status: UInt16) -> Bool {
        status == 0xFF00 || status == 0xFF01
    }

    func operationResult(from command: DicomDIMSECommandSet) -> DicomDIMSEOperationResult {
        DicomDIMSEOperationResult(status: command.status ?? 0,
                                  remainingSuboperations: command.remainingSuboperations,
                                  completedSuboperations: command.completedSuboperations,
                                  failedSuboperations: command.failedSuboperations,
                                  warningSuboperations: command.warningSuboperations)
    }

    func sendNormalizedCreate(operation: DicomDIMSEOperation,
                              affectedSOPClassUID: String,
                              affectedSOPInstanceUID: String,
                              dataSet: DicomDataSet,
                              responseCommandField: UInt16,
                              messageID: UInt16,
                              context: DicomAcceptedPresentationContext,
                              transferSyntax: DicomTransferSyntax,
                              association: DicomAssociation,
                              transport: DicomAssociationTransport,
                              reader: DicomDIMSEMessageReader,
                              printerStatusReports: inout [DicomPrinterStatusReport],
                              progress: ((DicomDIMSEProgress) -> Void)?) throws -> (result: DicomDIMSEOperationResult, dataSet: DicomDataSet?) {
        let command = DicomDIMSECommandSet(
            affectedSOPClassUID: affectedSOPClassUID,
            commandField: DicomDIMSECommandField.nCreateRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            affectedSOPInstanceUID: affectedSOPInstanceUID
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        try sendDataSet(dataSet,
                        transferSyntax: transferSyntax,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))
        let response = try readPrintResponse(
            commandField: responseCommandField,
            association: association,
            transport: transport,
            reader: reader,
            reports: &printerStatusReports
        )
        try validateSuccessOrWarningStatus(response)
        return (operationResult(from: response),
                try readOptionalDataSet(response: response,
                                        transferSyntax: transferSyntax,
                                        transport: transport,
                                        reader: reader))
    }

    func sendNormalizedSet(operation: DicomDIMSEOperation,
                           requestedSOPClassUID: String,
                           requestedSOPInstanceUID: String,
                           dataSet: DicomDataSet,
                           messageID: UInt16,
                           context: DicomAcceptedPresentationContext,
                           transferSyntax: DicomTransferSyntax,
                           association: DicomAssociation,
                           transport: DicomAssociationTransport,
                           reader: DicomDIMSEMessageReader,
                           printerStatusReports: inout [DicomPrinterStatusReport],
                           progress: ((DicomDIMSEProgress) -> Void)?) throws -> DicomDIMSEOperationResult {
        let command = DicomDIMSECommandSet(
            requestedSOPClassUID: requestedSOPClassUID,
            commandField: DicomDIMSECommandField.nSetRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            requestedSOPInstanceUID: requestedSOPInstanceUID
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        try sendDataSet(dataSet,
                        transferSyntax: transferSyntax,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))
        let response = try readPrintResponse(
            commandField: DicomDIMSECommandField.nSetRSP,
            association: association,
            transport: transport,
            reader: reader,
            reports: &printerStatusReports
        )
        try validateSuccessOrWarningStatus(response)
        return operationResult(from: response)
    }

    func sendNormalizedAction(operation: DicomDIMSEOperation,
                              requestedSOPClassUID: String,
                              requestedSOPInstanceUID: String,
                              actionTypeID: UInt16,
                              messageID: UInt16,
                              context: DicomAcceptedPresentationContext,
                              association: DicomAssociation,
                              transport: DicomAssociationTransport,
                              reader: DicomDIMSEMessageReader,
                              printerStatusReports: inout [DicomPrinterStatusReport],
                              progress: ((DicomDIMSEProgress) -> Void)?) throws -> DicomDIMSEOperationResult {
        let command = DicomDIMSECommandSet(
            requestedSOPClassUID: requestedSOPClassUID,
            commandField: DicomDIMSECommandField.nActionRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
            requestedSOPInstanceUID: requestedSOPInstanceUID,
            actionTypeID: actionTypeID
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))
        let response = try readPrintResponse(
            commandField: DicomDIMSECommandField.nActionRSP,
            association: association,
            transport: transport,
            reader: reader,
            reports: &printerStatusReports
        )
        try validateSuccessOrWarningStatus(response)
        return operationResult(from: response)
    }

    /// Queries the well-known Printer SOP Instance and consumes any
    /// asynchronous N-EVENT-REPORTs that arrive before its N-GET response.
    /// Every event is confirmed on the presentation context that delivered it.
    func collectPrinterStatus(
        messageID: UInt16,
        context: DicomAcceptedPresentationContext,
        association: DicomAssociation,
        transport: DicomAssociationTransport,
        reader: DicomDIMSEMessageReader,
        reports: inout [DicomPrinterStatusReport]
    ) throws {
        let command = DicomDIMSECommandSet(
            requestedSOPClassUID: DicomNetworkUID.printerSOPClass,
            commandField: DicomDIMSECommandField.nGetRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
            requestedSOPInstanceUID: DicomNetworkUID.printerSOPInstance
        )
        try sendCommand(
            command,
            presentationContextID: context.id,
            association: association,
            transport: transport
        )

        let response = try readPrintResponse(
            commandField: DicomDIMSECommandField.nGetRSP,
            association: association,
            transport: transport,
            reader: reader,
            reports: &reports
        )
        try validateSuccessOrWarningStatus(response)
        let dataSet = try readOptionalDataSet(
            response: response,
            transferSyntax: context.transferSyntax ?? .explicitVRLittleEndian,
            transport: transport,
            reader: reader
        )
        if let report = printerStatusReport(from: dataSet, source: .nGet) {
            reports.append(report)
        }
    }

    private func readPrintResponse(
        commandField: UInt16,
        association: DicomAssociation,
        transport: DicomAssociationTransport,
        reader: DicomDIMSEMessageReader,
        reports: inout [DicomPrinterStatusReport]
    ) throws -> DicomDIMSECommandSet {
        while true {
            let message = try reader.readMessage(from: transport)
            guard message.isCommand else {
                throw DicomNetworkError.malformedCommandSet("Expected DIMSE command PDV.")
            }
            let response = try DicomDIMSECommandSet.decode(message.data)
            if response.commandField == DicomDIMSECommandField.nEventReportRQ {
                try acknowledgePrintEvent(
                    response,
                    presentationContextID: message.presentationContextID,
                    association: association,
                    transport: transport,
                    reader: reader,
                    reports: &reports
                )
                continue
            }
            try association.outstandingOperations.correlate(response)
            try expect(response, commandField: commandField)
            return response
        }
    }

    private func acknowledgePrintEvent(
        _ command: DicomDIMSECommandSet,
        presentationContextID: UInt8,
        association: DicomAssociation,
        transport: DicomAssociationTransport,
        reader: DicomDIMSEMessageReader,
        reports: inout [DicomPrinterStatusReport]
    ) throws {
        guard let context = association.acceptedPresentationContexts.first(where: {
            $0.id == presentationContextID
        }) else {
            throw DicomNetworkError.invalidPresentationContextID(presentationContextID)
        }
        let dataSet = try readOptionalDataSet(
            response: command,
            transferSyntax: context.transferSyntax ?? .explicitVRLittleEndian,
            transport: transport,
            reader: reader
        )
        let acknowledgement = DicomDIMSECommandSet(
            affectedSOPClassUID: command.affectedSOPClassUID,
            commandField: DicomDIMSECommandField.nEventReportRSP,
            messageIDBeingRespondedTo: command.messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
            status: 0,
            affectedSOPInstanceUID: command.affectedSOPInstanceUID,
            eventTypeID: command.eventTypeID
        )
        try sendCommand(
            acknowledgement,
            presentationContextID: presentationContextID,
            association: association,
            transport: transport
        )

        guard command.affectedSOPClassUID == DicomNetworkUID.printerSOPClass else { return }
        let source = DicomPrinterStatusSource.nEventReport(eventTypeID: command.eventTypeID ?? 0)
        if let report = printerStatusReport(from: dataSet, source: source) {
            reports.append(report)
        }
    }

    private func printerStatusReport(
        from dataSet: DicomDataSet?,
        source: DicomPrinterStatusSource
    ) -> DicomPrinterStatusReport? {
        let state: DicomPrinterStatusState
        switch source {
        case .nGet:
            guard let dataSet else { return nil }
            let rawValue = dataSet.string(for: DicomPrintTag.printerStatus)?.uppercased() ?? "UNKNOWN"
            state = DicomPrinterStatusState(rawValue: rawValue) ?? .unknown
        case .nEventReport(let eventTypeID):
            switch eventTypeID {
            case 1: state = .normal
            case 2: state = .warning
            case 3: state = .failure
            default: state = .unknown
            }
        }
        return DicomPrinterStatusReport(
            state: state,
            statusInfo: dataSet?.string(for: DicomPrintTag.printerStatusInfo),
            printerName: dataSet?.string(for: DicomPrintTag.printerName),
            source: source
        )
    }

    func readOptionalDataSet(response: DicomDIMSECommandSet,
                             transferSyntax: DicomTransferSyntax,
                             transport: DicomAssociationTransport,
                             reader: DicomDIMSEMessageReader) throws -> DicomDataSet? {
        guard response.commandDataSetType != DicomDIMSECommandDataSetType.noDataSet else {
            return nil
        }
        let payload = try reader.readMessage(from: transport)
        guard !payload.isCommand else {
            throw DicomNetworkError.malformedCommandSet("Expected DIMSE response dataset.")
        }
        return try DicomDataSetParser.dataSet(from: payload.data,
                                              transferSyntax: transferSyntax)
    }

    /// The image box SOP Instance UIDs the printer created, taken from the film
    /// box N-CREATE response.
    ///
    /// The printer may create *more* image boxes than the job fills — a layout
    /// has as many slots as it has, and the extra ones simply stay empty. It may
    /// also create *fewer*, which is its conformant answer to a film box asking
    /// for more images than the layout holds. Fewer is not a programming error
    /// and it is not this method's to paper over: an image box that was not
    /// created has no SOP Instance UID, and an N-SET addressed to a UID the SCU
    /// made up either fails opaquely or, on a lenient printer, prints a film
    /// short of images with nothing saying which were dropped. Both counts are
    /// thrown back to the caller, who decides whether to repaginate or stop.
    func imageBoxUIDs(from dataSet: DicomDataSet?, expectedCount: Int) throws -> [String] {
        let referenced = dataSet?
            .sequenceItems(for: DicomPrintTag.referencedImageBoxSequence)
            .compactMap { $0.dataSet.string(for: .referencedSOPInstanceUID) } ?? []
        guard referenced.count >= expectedCount else {
            throw DicomPrintManagementError.insufficientImageBoxes(requested: expectedCount,
                                                                   granted: referenced.count)
        }
        return Array(referenced.prefix(expectedCount))
    }

    /// The Basic Annotation Box SOP Instance UIDs the printer created, from
    /// the film box N-CREATE response (issue #1908). Same contract as
    /// `imageBoxUIDs(from:expectedCount:)`: an absent or short Referenced
    /// Basic Annotation Box Sequence is thrown with both counts — never
    /// papered over with invented UIDs, never quietly printed without the
    /// texts the film was approved with.
    func annotationBoxUIDs(from dataSet: DicomDataSet?, expectedCount: Int) throws -> [String] {
        guard expectedCount > 0 else { return [] }
        let referenced = dataSet?
            .sequenceItems(for: DicomPrintTag.referencedBasicAnnotationBoxSequence)
            .compactMap { $0.dataSet.string(for: .referencedSOPInstanceUID) } ?? []
        guard referenced.count >= expectedCount else {
            throw DicomPrintManagementError.insufficientAnnotationBoxes(requested: expectedCount,
                                                                        granted: referenced.count)
        }
        return Array(referenced.prefix(expectedCount))
    }

    func progressPending(operation: DicomDIMSEOperation,
                         response: DicomDIMSECommandSet,
                         progress: ((DicomDIMSEProgress) -> Void)?) {
        progress?(.pending(operation: operation,
                           remaining: response.remainingSuboperations,
                           completed: response.completedSuboperations,
                           failed: response.failedSuboperations,
                           warning: response.warningSuboperations))
    }

    func receiveStoreRequest(_ command: DicomDIMSECommandSet,
                             association: DicomAssociation,
                             transport: DicomAssociationTransport,
                             reader: DicomDIMSEMessageReader,
                             onInstance: (DicomRetrievedInstance) throws -> Void) throws -> DicomRetrievedInstance {
        let sopClassUID = command.affectedSOPClassUID
        let context = try acceptedContext(sopClassUID ?? DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                                          in: association)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        // Issue #2793: into a file as it arrives, one PDU in memory at a time. A disk failure fails this store only;
        // an object whose File Meta cannot be written, such as one with a malformed UID, is received in memory.
        var persistenceError: Error?
        var receivedFile: DicomReceivedPart10File?
        if let directory = configuration.receivedFileDirectory, let sopClassUID, !sopClassUID.isEmpty,
           let sopInstanceUID = command.affectedSOPInstanceUID, !sopInstanceUID.isEmpty {
            receivedFile = try? DicomReceivedPart10File(directory: directory, sopClassUID: sopClassUID,
                                                        sopInstanceUID: sopInstanceUID, transferSyntax: transferSyntax)
        }
        defer { receivedFile?.remove() }
        let sink: ((Data) -> Void)? = receivedFile.map { file in
            { fragment in
                guard persistenceError == nil else { return }
                do { try file.append(fragment) } catch { persistenceError = error }
            }
        }
        let payload = try reader.readMessage(from: transport, sink: sink)
        guard !payload.isCommand else {
            throw DicomNetworkError.malformedCommandSet("Expected C-STORE dataset.")
        }
        var data = payload.data
        if persistenceError == nil, let receivedFile {
            do { data = try receivedFile.finish() } catch { persistenceError = error }
        }
        var instance = DicomRetrievedInstance(sopClassUID: sopClassUID,
                                              sopInstanceUID: command.affectedSOPInstanceUID,
                                              transferSyntax: transferSyntax,
                                              data: data,
                                              dataSet: nil)
        instance.part10FileURL = persistenceError == nil ? receivedFile?.url : nil
        if persistenceError == nil {
            do { try onInstance(instance) } catch { persistenceError = error }
        }
        let response = DicomDIMSECommandSet(
            affectedSOPClassUID: sopClassUID,
            commandField: DicomDIMSECommandField.cStoreRSP,
            messageIDBeingRespondedTo: command.messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
            status: persistenceError == nil ? 0 : 0xA700,
            affectedSOPInstanceUID: command.affectedSOPInstanceUID
        )
        try sendCommand(response,
                        presentationContextID: payload.presentationContextID,
                        association: association,
                        transport: transport)
        return instance
    }

    func storageDataSet(_ dataSet: DicomDataSet,
                        sopClassUID: String?,
                        sopInstanceUID: String?) -> (dataSet: DicomDataSet, sopClassUID: String, sopInstanceUID: String) {
        let resolvedClassUID = sopClassUID ??
            dataSet.string(for: .sopClassUID) ??
            DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        let resolvedInstanceUID = sopInstanceUID ??
            dataSet.string(for: .sopInstanceUID) ??
            DicomDataSetWriter.makeUID()
        var updated = dataSet
        if updated.string(for: .sopClassUID) == nil {
            updated.set(DicomDataElement(tag: DicomTag.sopClassUID.rawValue,
                                         vr: .UI,
                                         value: .strings([resolvedClassUID])))
        }
        if updated.string(for: .sopInstanceUID) == nil {
            updated.set(DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue,
                                         vr: .UI,
                                         value: .strings([resolvedInstanceUID])))
        }
        return (updated, resolvedClassUID, resolvedInstanceUID)
    }
}

/// Association-local print exchange state. All response datasets are consumed,
/// including failure replies, before cleanup can issue another operation.
final class DicomPrintExchange {
    let scu: DicomDIMSEServiceSCU
    let association: DicomAssociation
    let transport: DicomAssociationTransport
    let reader = DicomDIMSEMessageReader()
    var records: [DicomPrintOperationRecord] = []
    var printerReports: [DicomPrinterStatusReport] = []
    var jobStatuses: [String: (DicomPrintExecutionStatus, DicomPrintExecutionStatusInfo?)] = [:]
    var nextMessageID: UInt16 = 1
    var progress: ((DicomDIMSEProgress) -> Void)?

    init(scu: DicomDIMSEServiceSCU, association: DicomAssociation, transport: DicomAssociationTransport,
         progress: ((DicomDIMSEProgress) -> Void)?) {
        self.scu = scu; self.association = association; self.transport = transport; self.progress = progress
    }

    func request(_ kind: DicomPrintOperationRecord.Kind, sop: String, uid: String,
                 context: DicomAcceptedPresentationContext, dataSet: DicomDataSet? = nil)
        throws -> (uid: String, status: UInt16, dataSet: DicomDataSet?) {
        let fields: [DicomPrintOperationRecord.Kind: UInt16] = [
            .create: DicomDIMSECommandField.nCreateRQ, .set: DicomDIMSECommandField.nSetRQ,
            .action: DicomDIMSECommandField.nActionRQ, .get: DicomDIMSECommandField.nGetRQ,
            .delete: DicomDIMSECommandField.nDeleteRQ
        ]
        guard let field = fields[kind] else { throw DicomPrintManagementError.unsupportedService(kind.rawValue) }
        let messageID = nextMessageID
        nextMessageID = nextMessageID == UInt16.max ? 1 : nextMessageID + 1
        let command = DicomDIMSECommandSet(
            affectedSOPClassUID: kind == .create ? sop : nil,
            requestedSOPClassUID: kind == .create ? nil : sop,
            commandField: field, messageID: messageID,
            commandDataSetType: dataSet == nil ? DicomDIMSECommandDataSetType.noDataSet : DicomDIMSECommandDataSetType.hasDataSet,
            affectedSOPInstanceUID: kind == .create ? uid : nil,
            requestedSOPInstanceUID: kind == .create ? nil : uid,
            actionTypeID: kind == .action ? 1 : nil)
        try scu.sendCommand(command, presentationContextID: context.id, association: association, transport: transport)
        if let dataSet {
            try scu.sendDataSet(dataSet, transferSyntax: context.transferSyntax ?? .explicitVRLittleEndian,
                                presentationContextID: context.id, association: association, transport: transport)
        }
        progress?(.requestSent(operation: .printManagement, messageID: messageID))
        let response: DicomDIMSECommandSet
        while true {
            let message = try reader.readMessage(from: transport)
            guard message.isCommand else { throw DicomNetworkError.malformedCommandSet("Expected print command.") }
            let candidate = try DicomDIMSECommandSet.decode(message.data)
            if candidate.commandField == DicomDIMSECommandField.nEventReportRQ {
                try event(candidate, contextID: message.presentationContextID)
                continue
            }
            try association.outstandingOperations.correlate(candidate)
            try scu.expect(candidate, commandField: field | 0x8000)
            response = candidate; break
        }
        let reply = try scu.readOptionalDataSet(response: response,
            transferSyntax: context.transferSyntax ?? .explicitVRLittleEndian, transport: transport, reader: reader)
        let actualUID = kind == .create ? (response.affectedSOPInstanceUID ?? uid) : uid
        guard let status = response.status else { throw DicomNetworkError.malformedCommandSet("Missing print status.") }
        records.append(.init(kind: kind, sopClassUID: sop, sopInstanceUID: actualUID, status: status))
        guard status == 0 || status & 0xF000 == 0xB000 || status == 0x0107 || status == 0x0116 else {
            throw DicomNetworkError.dimseStatusFailure(status)
        }
        guard !actualUID.isEmpty else { throw DicomPrintManagementError.missingCreatedUID(sop) }
        if kind == .get, sop == DicomNetworkUID.printerSOPClass, let reply {
            printerReports.append(.init(state: .init(rawValue: reply.string(for: DicomPrintTag.printerStatus) ?? "UNKNOWN") ?? .unknown,
                statusInfo: reply.string(for: DicomPrintTag.printerStatusInfo),
                printerName: reply.string(for: DicomPrintTag.printerName), source: .nGet, operationStatus: status))
            if let report = printerReports.last, report.state == .warning || report.state == .failure {
                records[records.count - 1].warningMeaning = "Printer \(report.state.rawValue): \(report.statusInfo ?? "UNKNOWN")"
            }
        }
        if kind == .get, sop == DicomNetworkUID.printJobSOPClass, let reply,
           let status = DicomPrintExecutionStatus(rawValue: reply.string(for: 0x2100_0020) ?? "") {
            // A terminal event can precede this reply and must not be overwritten by stale PENDING.
            if jobStatuses[uid]?.0 != .done && jobStatuses[uid]?.0 != .failure {
                jobStatuses[uid] = (status, reply.string(for: 0x2100_0030).map(DicomPrintExecutionStatusInfo.init(rawValue:)))
            }
        }
        return (actualUID, status, reply)
    }

    func event(_ command: DicomDIMSECommandSet, contextID: UInt8) throws {
        guard let context = association.acceptedPresentationContexts.first(where: { $0.id == contextID }) else {
            throw DicomNetworkError.invalidPresentationContextID(contextID)
        }
        let data = try scu.readOptionalDataSet(response: command,
            transferSyntax: context.transferSyntax ?? .explicitVRLittleEndian, transport: transport, reader: reader)
        let acknowledgement = DicomDIMSECommandSet(affectedSOPClassUID: command.affectedSOPClassUID,
            commandField: DicomDIMSECommandField.nEventReportRSP, messageIDBeingRespondedTo: command.messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.noDataSet, status: 0,
            affectedSOPInstanceUID: command.affectedSOPInstanceUID, eventTypeID: command.eventTypeID)
        try scu.sendCommand(acknowledgement, presentationContextID: contextID, association: association, transport: transport)
        let sop = command.affectedSOPClassUID ?? ""
        let eventID = command.eventTypeID ?? 0
        if sop == DicomNetworkUID.printerSOPClass {
            let state: DicomPrinterStatusState = eventID == 1 ? .normal : eventID == 2 ? .warning : eventID == 3 ? .failure : .unknown
            printerReports.append(.init(state: state, statusInfo: data?.string(for: DicomPrintTag.printerStatusInfo),
                printerName: data?.string(for: DicomPrintTag.printerName), source: .nEventReport(eventTypeID: eventID)))
        } else if sop == DicomNetworkUID.printJobSOPClass, let uid = command.affectedSOPInstanceUID,
                  let status = [1: DicomPrintExecutionStatus.pending, 2: .printing, 3: .done, 4: .failure][Int(eventID)] {
            jobStatuses[uid] = (status, data?.string(for: 0x2100_0030).map(DicomPrintExecutionStatusInfo.init(rawValue:)))
        }
        records.append(.init(kind: .eventReport, sopClassUID: sop, sopInstanceUID: command.affectedSOPInstanceUID,
                             status: 0, warningMeaning: eventID > 1 && sop == DicomNetworkUID.printerSOPClass
                                ? data?.string(for: DicomPrintTag.printerStatusInfo) : nil))
        records[records.count - 1].eventTypeID = eventID
        if sop == DicomNetworkUID.printJobSOPClass, let uid = command.affectedSOPInstanceUID {
            records[records.count - 1].executionStatus = jobStatuses[uid]?.0
            records[records.count - 1].executionStatusInfo = jobStatuses[uid]?.1
        }
    }

    func readEvent() throws {
        let message = try reader.readMessage(from: transport)
        guard message.isCommand else { throw DicomNetworkError.malformedCommandSet("Expected print event command.") }
        let command = try DicomDIMSECommandSet.decode(message.data)
        try scu.expect(command, commandField: DicomDIMSECommandField.nEventReportRQ)
        try event(command, contextID: message.presentationContextID)
    }

    func checkPrinter() throws {
        if let report = printerReports.last(where: { $0.state == .failure }) {
            throw DicomPrintManagementError.printerFailure(statusInfo: report.statusInfo)
        }
    }

    func references(_ dataSet: DicomDataSet?, tag: Int, sop: String, count: Int, annotation: Bool = false) throws -> [String] {
        let items = dataSet?.sequenceItems(for: tag).map(\.dataSet) ?? []
        let uids = items.compactMap { $0.string(for: .referencedSOPInstanceUID) }.filter { !$0.isEmpty }
        guard uids.count >= count else {
            if annotation { throw DicomPrintManagementError.insufficientAnnotationBoxes(requested: count, granted: uids.count) }
            throw DicomPrintManagementError.insufficientImageBoxes(requested: count, granted: uids.count)
        }
        for item in items {
            guard item.string(for: .referencedSOPClassUID) == sop else {
                throw DicomPrintManagementError.sopClassMismatch(expected: sop, received: item.string(for: .referencedSOPClassUID))
            }
        }
        return Array(uids.prefix(count))
    }
}

/// Bounds the complete monitoring interval, including a blocked socket read.
/// A caller-supplied transport must support cancellation to interrupt a blocked read.
final class DicomPrintMonitoringDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var expired = false
    private var work: DispatchWorkItem?
    init(timeout: TimeInterval, transport: DicomAssociationTransport) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.finished else { return }
            self.expired = true
            (transport as? DicomCancellableAssociationTransport)?.close()
        }
        self.work = work
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
    }
    var isExpired: Bool { lock.lock(); defer { lock.unlock() }; return expired }
    func finish() { lock.lock(); defer { lock.unlock() }; finished = true; work?.cancel(); work = nil }
}
