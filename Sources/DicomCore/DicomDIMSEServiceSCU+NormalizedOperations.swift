import Foundation

extension DicomDIMSEServiceSCU {
    public func createMPPS(_ request: DicomMPPSCreateRequest,
                           progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        try performWithResilience(operation: .mppsCreate, progress: progress) { transport in
            try createMPPS(request, using: transport, progress: progress)
        }
    }

    public func createMPPS(_ request: DicomMPPSCreateRequest,
                           using transport: DicomAssociationTransport,
                           progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        let operation = DicomDIMSEOperation.mppsCreate
        let association = try openAssociation(
            for: operation,
            abstractSyntaxUIDs: [DicomNetworkUID.modalityPerformedProcedureStepSOPClass],
            using: transport,
            progress: progress
        )
        defer { try? release(operation: operation, using: transport, progress: progress) }

        let context = try acceptedContext(DicomNetworkUID.modalityPerformedProcedureStepSOPClass, in: association)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        let messageID: UInt16 = 1
        let command = DicomDIMSECommandSet(
            affectedSOPClassUID: DicomNetworkUID.modalityPerformedProcedureStepSOPClass,
            commandField: DicomDIMSECommandField.nCreateRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            affectedSOPInstanceUID: request.sopInstanceUID
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        try sendDataSet(request.dataSet,
                        transferSyntax: transferSyntax,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))

        let reader = DicomDIMSEMessageReader()
        let response = try readCommand(using: transport, association: association, reader: reader)
        try expect(response, commandField: DicomDIMSECommandField.nCreateRSP)
        try validateSuccessStatus(response)
        let result = operationResult(from: response)
        progress?(.completed(operation: operation, status: result.status))
        return result
    }

    public func updateMPPS(_ request: DicomMPPSUpdateRequest,
                           progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        try performWithResilience(operation: .mppsUpdate, progress: progress) { transport in
            try updateMPPS(request, using: transport, progress: progress)
        }
    }

    public func updateMPPS(_ request: DicomMPPSUpdateRequest,
                           using transport: DicomAssociationTransport,
                           progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        let operation = DicomDIMSEOperation.mppsUpdate
        let association = try openAssociation(
            for: operation,
            abstractSyntaxUIDs: [DicomNetworkUID.modalityPerformedProcedureStepSOPClass],
            using: transport,
            progress: progress
        )
        defer { try? release(operation: operation, using: transport, progress: progress) }

        let context = try acceptedContext(DicomNetworkUID.modalityPerformedProcedureStepSOPClass, in: association)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        let messageID: UInt16 = 1
        let command = DicomDIMSECommandSet(
            requestedSOPClassUID: DicomNetworkUID.modalityPerformedProcedureStepSOPClass,
            commandField: DicomDIMSECommandField.nSetRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            requestedSOPInstanceUID: request.sopInstanceUID
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        try sendDataSet(request.dataSet,
                        transferSyntax: transferSyntax,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))

        let reader = DicomDIMSEMessageReader()
        let response = try readCommand(using: transport, association: association, reader: reader)
        try expect(response, commandField: DicomDIMSECommandField.nSetRSP)
        try validateSuccessStatus(response)
        let result = operationResult(from: response)
        progress?(.completed(operation: operation, status: result.status))
        return result
    }

    public func reportStorageCommitment(
        _ report: DicomStorageCommitmentReport,
        progress: ((DicomDIMSEProgress) -> Void)? = nil
    ) throws -> DicomDIMSEOperationResult {
        try performWithResilience(operation: .storageCommitmentReport, progress: progress) { transport in
            try reportStorageCommitment(report, using: transport, progress: progress)
        }
    }

    public func reportStorageCommitment(
        _ report: DicomStorageCommitmentReport,
        using transport: DicomAssociationTransport,
        progress: ((DicomDIMSEProgress) -> Void)? = nil
    ) throws -> DicomDIMSEOperationResult {
        let operation = DicomDIMSEOperation.storageCommitmentReport
        let sopClassUID = DicomNetworkUID.storageCommitmentPushModelSOPClass
        let association = try openAssociation(
            for: operation,
            abstractSyntaxUIDs: [sopClassUID],
            roleSelections: [
                DicomSCPSCURoleSelection(sopClassUID: sopClassUID, scuRole: false, scpRole: true)
            ],
            using: transport,
            progress: progress
        )
        defer { try? release(operation: operation, using: transport, progress: progress) }

        guard association.negotiatedRoleSelection(for: sopClassUID)?.scpRole == true else {
            throw DicomNetworkError.storageCommitmentRoleNotNegotiated
        }
        let context = try acceptedContext(sopClassUID, in: association)
        let transferSyntax = context.transferSyntax ?? .explicitVRLittleEndian
        let messageID: UInt16 = 1
        let command = DicomDIMSECommandSet(
            affectedSOPClassUID: sopClassUID,
            commandField: DicomDIMSECommandField.nEventReportRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            affectedSOPInstanceUID: DicomNetworkUID.storageCommitmentPushModelSOPInstance,
            eventTypeID: report.status == .committed ? 1 : 2
        )
        try sendCommand(
            command,
            presentationContextID: context.id,
            association: association,
            transport: transport
        )
        try sendDataSet(
            DicomStorageCommitmentTracker.eventReportDataSet(for: report),
            transferSyntax: transferSyntax,
            presentationContextID: context.id,
            association: association,
            transport: transport
        )
        progress?(.requestSent(operation: operation, messageID: messageID))

        let response = try readCommand(using: transport, association: association, reader: DicomDIMSEMessageReader())
        try expect(response, commandField: DicomDIMSECommandField.nEventReportRSP)
        try validateSuccessStatus(response)
        let result = operationResult(from: response)
        progress?(.completed(operation: operation, status: result.status))
        return result
    }

    public func sendPrintJob(_ job: DicomPrintJob,
                             progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomPrintJobResult {
        try job.limits.validate(films: job.effectiveFilms)
        var service = self
        if case .untilDone(let timeout) = job.monitor {
            guard timeout.isFinite, timeout > 0 else { throw DicomPrintManagementError.monitoringTimedOut }
            service.configuration.dimseResponseTimeout = min(configuration.dimseResponseTimeout, timeout)
        }
        return try service.performWithResilience(operation: .printManagement, progress: progress) { transport in
            try service.sendPrintJob(job, using: transport, progress: progress)
        }
    }

    public func sendPrintJob(_ job: DicomPrintJob,
                             using transport: DicomAssociationTransport,
                             progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomPrintJobResult {
        try executePrintJob(job, using: transport, progress: progress, captureFailures: false)
    }

    private func executePrintJob(_ job: DicomPrintJob, using transport: DicomAssociationTransport,
                                 progress: ((DicomDIMSEProgress) -> Void)?,
                                 captureFailures: Bool) throws -> DicomPrintJobResult {
        try job.limits.validate(films: job.effectiveFilms)
        let films = job.effectiveFilms
        if let lut = job.presentationLUT, lut.shape == nil, lut.descriptor.first != 256 {
            // DicomRenderedBitmap currently supplies 8-bit samples (H.4.9.2.1.1.1).
            throw DicomPrintManagementError.invalidPresentationLUT
        }
        var result = DicomPrintJobResult(operation: .init(status: 0), filmSessionSOPInstanceUID: "",
                                         filmBoxSOPInstanceUID: "", imageBoxSOPInstanceUIDs: [])
        result.filmResults = films.map { DicomPrintFilmResult(id: $0.id) }
        if job.cancellationToken.isCancelled {
            result.state = .cancelled
            result.filmResults = result.filmResults.map { var film = $0; film.state = .cancelled; return film }
            return result
        }
        var syntaxes = [DicomNetworkUID.basicFilmSessionSOPClass, DicomNetworkUID.basicFilmBoxSOPClass,
                        DicomNetworkUID.printerSOPClass, DicomNetworkUID.printerConfigurationRetrievalSOPClass,
                        DicomNetworkUID.printJobSOPClass]
        switch job.printMode {
        case .automatic:
            syntaxes += [DicomNetworkUID.basicColorPrintManagementMetaSOPClass,
                         DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass,
                         DicomNetworkUID.basicColorImageBoxSOPClass, DicomNetworkUID.basicGrayscaleImageBoxSOPClass]
        case .grayscale:
            syntaxes += [DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass, DicomNetworkUID.basicGrayscaleImageBoxSOPClass]
        case .color:
            syntaxes += [DicomNetworkUID.basicColorPrintManagementMetaSOPClass, DicomNetworkUID.basicColorImageBoxSOPClass]
        }
        if films.contains(where: { !$0.annotations.isEmpty }) { syntaxes.append(DicomNetworkUID.basicAnnotationBoxSOPClass) }
        if job.presentationLUT != nil { syntaxes.append(DicomNetworkUID.presentationLUTSOPClass) }
        let association = try openAssociation(for: .printManagement, abstractSyntaxUIDs: syntaxes,
                                               using: transport, progress: progress)
        defer { try? release(operation: .printManagement, using: transport, progress: progress) }
        let contexts = try DicomPrintPresentationContexts.resolve(requestedMode: job.printMode, association: association)
        let exchange = DicomPrintExchange(scu: self, association: association, transport: transport, progress: progress)
        var capabilities = DicomPrintPeerCapabilities(acceptedSOPClassUIDs: Set(association.acceptedPresentationContexts.map(\.abstractSyntaxUID)))
        let annotationContext = association.acceptedPresentationContext(for: DicomNetworkUID.basicAnnotationBoxSOPClass)
        if films.contains(where: { !$0.annotations.isEmpty }) && annotationContext == nil {
            throw DicomPrintManagementError.annotationBoxNotNegotiated
        }
        let lutContext = association.acceptedPresentationContext(for: DicomNetworkUID.presentationLUTSOPClass)
        if job.presentationLUT != nil && lutContext == nil {
            throw DicomPrintManagementError.unsupportedService("Presentation LUT was not negotiated")
        }
        let meta = contexts.resolvedMode == .color ? DicomNetworkUID.basicColorPrintManagementMetaSOPClass
                                                  : DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass
        var createdBoxes: [String] = []
        func checkpoint() throws {
            if job.cancellationToken.isCancelled { throw DicomPrintManagementError.cancelled }
            try exchange.checkPrinter()
        }
        func printerQuery() throws {
            guard let context = contexts.printer else { return }
            do {
                _ = try exchange.request(.get, sop: DicomNetworkUID.printerSOPClass,
                                         uid: DicomNetworkUID.printerSOPInstance, context: context)
            } catch DicomNetworkError.dimseStatusFailure { }
        }
        func cleanup() {
            let objects = createdBoxes.reversed().map { (DicomNetworkUID.basicFilmBoxSOPClass, $0, contexts.filmBox) }
                + (result.filmSessionSOPInstanceUID.isEmpty ? [] : [(DicomNetworkUID.basicFilmSessionSOPClass,
                     result.filmSessionSOPInstanceUID, contexts.filmSession)])
                + (result.presentationLUTSOPInstanceUID.flatMap { uid in lutContext.map { [(DicomNetworkUID.presentationLUTSOPClass, uid, $0)] } } ?? [])
            for (sop, uid, context) in objects {
                do { _ = try exchange.request(.delete, sop: sop, uid: uid, context: context) }
                catch {
                    let warning = "Cleanup failed: \(error.localizedDescription)"
                    if let last = exchange.records.indices.last, exchange.records[last].kind == .delete,
                       exchange.records[last].sopInstanceUID == uid {
                        exchange.records[last].warningMeaning = warning
                    } else {
                        exchange.records.append(.init(kind: .delete, sopClassUID: sop, sopInstanceUID: uid,
                                                       status: nil, warningMeaning: warning))
                    }
                }
            }
        }
        func accept(sop: String, uid: String, context: DicomAcceptedPresentationContext, indices: [Int]) throws {
            try checkpoint()
            let action = try exchange.request(.action, sop: sop, uid: uid, context: context)
            result.operation = .init(status: action.status)
            for index in indices { result.filmResults[index].state = .accepted }
            result.state = .accepted
            let references = action.dataSet?.sequenceItems(for: 0x2100_0500).map(\.dataSet) ?? []
            for reference in references {
                guard reference.string(for: .referencedSOPClassUID) == DicomNetworkUID.printJobSOPClass else {
                    throw DicomPrintManagementError.sopClassMismatch(expected: DicomNetworkUID.printJobSOPClass,
                                                                    received: reference.string(for: .referencedSOPClassUID))
                }
                guard let jobUID = reference.string(for: .referencedSOPInstanceUID), !jobUID.isEmpty else {
                    throw DicomPrintManagementError.missingCreatedUID(DicomNetworkUID.printJobSOPClass)
                }
                result.printJobSOPInstanceUIDs.append(jobUID)
                for index in indices { result.filmResults[index].printJobSOPInstanceUIDs.append(jobUID) }
                if case .untilDone(let timeout) = job.monitor,
                   let jobContext = association.acceptedPresentationContext(for: DicomNetworkUID.printJobSOPClass) {
                    guard timeout.isFinite, timeout > 0 else { throw DicomPrintManagementError.monitoringTimedOut }
                    let monitoringDeadline = DicomPrintMonitoringDeadline(timeout: timeout, transport: transport)
                    defer { monitoringDeadline.finish() }
                    let deadline = Date().addingTimeInterval(timeout)
                    var queried = false
                    while true {
                        try checkpoint()
                        if let (status, info) = exchange.jobStatuses[jobUID] {
                            result.executionStatus = status; result.executionStatusInfo = info
                            if status == .failure {
                                for index in indices { result.filmResults[index].state = .failed }
                                throw DicomPrintManagementError.printJobFailure(statusInfo: info)
                            }
                            if status == .done {
                                for index in indices { result.filmResults[index].state = .done }
                                result.state = .done; break
                            }
                            if status == .printing { result.state = .printing }
                        }
                        guard Date() < deadline else { throw DicomPrintManagementError.monitoringTimedOut }
                        do {
                            if queried { try exchange.readEvent() }
                            else {
                                _ = try exchange.request(.get, sop: DicomNetworkUID.printJobSOPClass, uid: jobUID, context: jobContext)
                                queried = true
                            }
                        }
                        catch DicomNetworkError.dimseStatusFailure where exchange.jobStatuses[jobUID]?.0 == .done || exchange.jobStatuses[jobUID]?.0 == .failure { }
                        catch {
                            if monitoringDeadline.isExpired || Date() >= deadline {
                                throw DicomPrintManagementError.monitoringTimedOut
                            }
                            throw error
                        }
                    }
                }
            }
        }
        do {
            result.state = .preparing
            try checkpoint()
            try printerQuery()
            try checkpoint()
            if let configurationContext = association.acceptedPresentationContext(for: DicomNetworkUID.printerConfigurationRetrievalSOPClass) {
                let reply = try exchange.request(.get, sop: DicomNetworkUID.printerConfigurationRetrievalSOPClass,
                    uid: DicomNetworkUID.printerConfigurationRetrievalSOPInstance, context: configurationContext)
                if let data = reply.dataSet { capabilities.printerConfiguration = .init(dataSet: data, operationStatus: reply.status) }
            }
            if job.printScope == .filmSession,
               let config = capabilities.printerConfiguration?.configuration(for: meta),
               let maximum = config.int(for: 0x2010_0154), films.count > maximum {
                throw DicomPrintManagementError.limitExceeded("Maximum Collated Films")
            }
            try checkpoint()
            let session = try exchange.request(.create, sop: DicomNetworkUID.basicFilmSessionSOPClass,
                uid: job.filmSessionSOPInstanceUID, context: contexts.filmSession, dataSet: job.filmSession.dataSet)
            result.filmSessionSOPInstanceUID = session.uid
            if let updates = job.filmSession.updates {
                try checkpoint()
                _ = try exchange.request(.set, sop: DicomNetworkUID.basicFilmSessionSOPClass,
                                         uid: session.uid, context: contexts.filmSession, dataSet: updates)
            }
            if let lut = job.presentationLUT, let lutContext {
                try checkpoint()
                let created = try exchange.request(.create, sop: DicomNetworkUID.presentationLUTSOPClass,
                    uid: DicomDataSetWriter.makeUID(), context: lutContext, dataSet: lut.dataSet)
                result.presentationLUTSOPInstanceUID = created.uid
            }
            for (index, film) in films.enumerated() {
                try checkpoint()
                result.filmResults[index].state = .preparing
                var data = film.filmBox.dataSet(referencingFilmSessionUID: session.uid)
                if let lutUID = result.presentationLUTSOPInstanceUID {
                    data = DicomDataSet(elements: data.elements + [DicomDataElement(tag: 0x2050_0500, vr: .SQ,
                        value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: [
                            DicomDataElement(tag: DicomTag.referencedSOPClassUID.rawValue, vr: .UI, value: .strings([DicomNetworkUID.presentationLUTSOPClass])),
                            DicomDataElement(tag: DicomTag.referencedSOPInstanceUID.rawValue, vr: .UI, value: .strings([lutUID]))
                        ]))]))])
                    for (tag, value) in [(0x2010_015E, film.filmBox.illumination), (0x2010_0160, film.filmBox.reflectedAmbientLight)] {
                        if let value { data = DicomDataSet(elements: data.elements + [DicomDataElement(tag: tag, vr: .US, value: .unsignedIntegers([UInt(value)]))]) }
                    }
                }
                let box = try exchange.request(.create, sop: DicomNetworkUID.basicFilmBoxSOPClass,
                    uid: film.sopInstanceUID, context: contexts.filmBox, dataSet: data)
                createdBoxes.append(box.uid)
                result.filmResults[index].sopInstanceUID = box.uid
                if index == 0 { result.filmBoxSOPInstanceUID = box.uid }
                let imageUIDs = try exchange.references(box.dataSet, tag: DicomPrintTag.referencedImageBoxSequence,
                    sop: contexts.imageBoxSOPClassUID, count: film.imageBoxes.map(\.position).max() ?? 0)
                let annotationUIDs = try exchange.references(box.dataSet, tag: DicomPrintTag.referencedBasicAnnotationBoxSequence,
                    sop: DicomNetworkUID.basicAnnotationBoxSOPClass, count: film.annotations.map(\.position).max() ?? 0, annotation: true)
                let usedImageUIDs = film.imageBoxes.map { imageUIDs[$0.position - 1] }
                let usedAnnotationUIDs = film.annotations.map { annotationUIDs[$0.position - 1] }
                result.filmResults[index].imageBoxSOPInstanceUIDs = usedImageUIDs
                result.filmResults[index].annotationBoxSOPInstanceUIDs = usedAnnotationUIDs
                result.imageBoxSOPInstanceUIDs += usedImageUIDs; result.annotationBoxSOPInstanceUIDs += usedAnnotationUIDs
                if let updates = film.filmBox.updates {
                    try checkpoint()
                    _ = try exchange.request(.set, sop: DicomNetworkUID.basicFilmBoxSOPClass,
                                             uid: box.uid, context: contexts.filmBox, dataSet: updates)
                }
                result.state = .sending; result.filmResults[index].state = .sending
                for image in film.imageBoxes {
                    try checkpoint()
                    var data = image.dataSet(for: contexts.resolvedMode)
                    let allowedSize = capabilities.printerConfiguration?.requestedImageSizeAllowed(filmBox: film.filmBox, metaSOPClassUID: meta)
                    if let size = image.requestedImageSize, allowedSize == true || (allowedSize == nil && image.forceRequestedImageSize) {
                        data = DicomDataSet(elements: data.elements + [DicomDataElement(tag: 0x2020_0030, vr: .DS, value: .strings([String(size)]))])
                    }
                    if let behavior = image.requestedDecimateCropBehavior,
                       capabilities.printerConfiguration?.configuration(for: meta)?.string(for: 0x2020_00A2)?.hasPrefix("DEF ") == true {
                        data = DicomDataSet(elements: data.elements + [DicomDataElement(tag: 0x2020_0040, vr: .CS, value: .strings([behavior.rawValue]))])
                    }
                    if let original = image.originalImage {
                        data = DicomDataSet(elements: data.elements + [DicomDataElement(tag: 0x2130_00C0, vr: .SQ,
                            value: .sequence([DicomSequenceItem(dataSet: original)]))])
                    }
                    if image.polarity == .reverse { data = DicomDataSet(elements: data.elements + [DicomDataElement(tag: 0x2020_0020, vr: .CS, value: .strings(["REVERSE"]))]) }
                    _ = try exchange.request(.set, sop: contexts.imageBoxSOPClassUID, uid: imageUIDs[image.position - 1],
                                             context: contexts.imageBox, dataSet: data)
                }
                for annotation in film.annotations {
                    try checkpoint()
                    guard let annotationContext else { throw DicomPrintManagementError.annotationBoxNotNegotiated }
                    do {
                        let reply = try exchange.request(.set, sop: DicomNetworkUID.basicAnnotationBoxSOPClass,
                            uid: annotationUIDs[annotation.position - 1], context: annotationContext, dataSet: annotation.dataSet)
                        if reply.status == 0x0107 || reply.status == 0x0116 {
                            throw DicomPrintManagementError.annotationIgnored(position: annotation.position, status: reply.status)
                        }
                    } catch let DicomNetworkError.dimseStatusFailure(status) {
                        throw DicomPrintManagementError.annotationSetFailed(position: annotation.position, status: status)
                    }
                }
                if job.printScope == .filmBox {
                    try accept(sop: DicomNetworkUID.basicFilmBoxSOPClass, uid: box.uid, context: contexts.filmBox, indices: [index])
                }
            }
            if job.printScope == .filmSession {
                try accept(sop: DicomNetworkUID.basicFilmSessionSOPClass, uid: session.uid,
                           context: contexts.filmSession, indices: Array(films.indices))
            }
            try printerQuery()
            for uid in result.printJobSOPInstanceUIDs {
                if let (status, info) = exchange.jobStatuses[uid] {
                    result.executionStatus = status; result.executionStatusInfo = info
                    if status == .failure { throw DicomPrintManagementError.printJobFailure(statusInfo: info) }
                }
            }
            if job.cleanup { cleanup() }
        } catch DicomPrintManagementError.cancelled {
            cleanup()
            result.state = .cancelled
            for index in result.filmResults.indices where result.filmResults[index].state != .accepted && result.filmResults[index].state != .done {
                result.filmResults[index].state = .cancelled
            }
        } catch {
            if films.count == 1 && !captureFailures {
                if job.cleanup && exchange.records.contains(where: { $0.kind == .action }) { cleanup() }
                throw error
            }
            result.state = .failed
            for index in result.filmResults.indices where result.filmResults[index].state != .accepted && result.filmResults[index].state != .done {
                result.filmResults[index].state = .failed; result.filmResults[index].failureDescription = error.localizedDescription
            }
            if job.cleanup { cleanup() }
        }
        result.operations = exchange.records
        result.warnings = exchange.records.filter {
            $0.warningMeaning != nil || ($0.status ?? 0) & 0xF000 == 0xB000 || $0.status == 0x0107 || $0.status == 0x0116
                || (($0.kind == .get || $0.kind == .delete) && ($0.status ?? 0) != 0)
        }
        for index in result.filmResults.indices {
            let film = result.filmResults[index]
            let identities = Set(film.imageBoxSOPInstanceUIDs + film.annotationBoxSOPInstanceUIDs
                + film.printJobSOPInstanceUIDs + [film.sopInstanceUID, result.filmSessionSOPInstanceUID,
                                                 result.presentationLUTSOPInstanceUID].compactMap { $0 })
            result.filmResults[index].operations = exchange.records.filter {
                $0.sopInstanceUID.map(identities.contains) ?? false
            }
        }
        result.printerStatusReports = exchange.printerReports
        result.capabilities = capabilities
        if result.operation.status == 0, let warning = result.warnings.first(where: { $0.kind != .delete && $0.kind != .eventReport && $0.kind != .get })?.status {
            result.operation.status = warning
        }
        progress?(.completed(operation: .printManagement, status: result.operation.status))
        return result
    }
}

extension DicomDIMSEServiceSCU {
    public func requestStorageCommitment(transactionUID: String,
        references: [DicomStorageCommitmentReference]) throws -> DicomDIMSEOperationResult {
        try performWithResilience(operation: .storageCommitmentRequest, progress: nil) {
            try requestStorageCommitment(transactionUID: transactionUID, references: references, using: $0)
        }
    }

    public func requestStorageCommitment(transactionUID: String,
        references: [DicomStorageCommitmentReference], using transport: DicomAssociationTransport)
        throws -> DicomDIMSEOperationResult {
        let dataSet = DicomStorageCommitmentTracker.actionDataSet(transactionUID: transactionUID, references: references)
        _ = try DicomStorageCommitmentTracker.parseActionDataSet(dataSet)
        let uid = DicomNetworkUID.storageCommitmentPushModelSOPClass
        let association = try openAssociation(for: .storageCommitmentRequest, abstractSyntaxUIDs: [uid],
                                               using: transport, progress: nil)
        defer { try? release(operation: .storageCommitmentRequest, using: transport, progress: nil) }
        let context = try acceptedContext(uid, in: association)
        let command = DicomDIMSECommandSet(requestedSOPClassUID: uid,
            commandField: DicomDIMSECommandField.nActionRQ,
            messageID: try association.outstandingOperations.allocateMessageID(),
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            requestedSOPInstanceUID: DicomNetworkUID.storageCommitmentPushModelSOPInstance, actionTypeID: 1)
        try sendCommand(command, presentationContextID: context.id, association: association, transport: transport)
        try sendDataSet(dataSet, transferSyntax: context.transferSyntax ?? .explicitVRLittleEndian,
                        presentationContextID: context.id, association: association, transport: transport)
        let reader = DicomDIMSEMessageReader()
        let response = try readCommand(using: transport, association: association, reader: reader)
        try expect(response, commandField: DicomDIMSECommandField.nActionRSP)
        _ = try readOptionalDataSet(response: response, transferSyntax: context.transferSyntax ?? .explicitVRLittleEndian,
                                    transport: transport, reader: reader)
        try validateSuccessStatus(response)
        return operationResult(from: response)
    }
}

extension DicomDIMSEServiceSCU {
    public func sendPrintBatch(_ batch: DicomPrintBatch,
                               progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomPrintBatchResult {
        var result = DicomPrintBatchResult()
        for job in batch.jobs {
            do {
                let sent = try performWithResilience(operation: .printManagement, progress: progress) { transport in
                    try executePrintJob(job, using: transport, progress: progress, captureFailures: true)
                }
                result.results.append(sent); result.films += sent.filmResults
            } catch {
                result.films += job.effectiveFilms.map {
                    DicomPrintFilmResult(id: $0.id, state: .failed, failureDescription: error.localizedDescription)
                }
            }
        }
        return result
    }
    public func queryPrinter() throws -> DicomPrinterStatusReport? {
        let reply = try queryPrintObject(sop: DicomNetworkUID.printerSOPClass, uid: DicomNetworkUID.printerSOPInstance)
        guard let data = reply.dataSet else { return nil }
        return .init(state: DicomPrinterStatusState(rawValue: data.string(for: DicomPrintTag.printerStatus) ?? "UNKNOWN") ?? .unknown,
                     statusInfo: data.string(for: DicomPrintTag.printerStatusInfo),
                     printerName: data.string(for: DicomPrintTag.printerName), source: .nGet, operationStatus: reply.status)
    }
    public func queryPrinterConfiguration() throws -> DicomPrinterConfiguration? {
        let reply = try queryPrintObject(sop: DicomNetworkUID.printerConfigurationRetrievalSOPClass,
                                         uid: DicomNetworkUID.printerConfigurationRetrievalSOPInstance)
        return reply.dataSet.map { DicomPrinterConfiguration(dataSet: $0, operationStatus: reply.status) }
    }
    public func queryPrintJob(sopInstanceUID: String) throws -> (status: UInt16, dataSet: DicomDataSet?) {
        try queryPrintObject(sop: DicomNetworkUID.printJobSOPClass, uid: sopInstanceUID)
    }
    private func queryPrintObject(sop: String, uid: String) throws -> (status: UInt16, dataSet: DicomDataSet?) {
        try performWithResilience(operation: .printManagement, progress: nil) { transport in
            let association = try openAssociation(for: .printManagement,
                abstractSyntaxUIDs: [sop, DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass,
                                     DicomNetworkUID.basicColorPrintManagementMetaSOPClass], using: transport, progress: nil)
            defer { try? release(operation: .printManagement, using: transport, progress: nil) }
            let context = association.acceptedPresentationContext(for: sop)
                ?? (sop == DicomNetworkUID.printerSOPClass
                    ? association.acceptedPresentationContext(for: DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass)
                        ?? association.acceptedPresentationContext(for: DicomNetworkUID.basicColorPrintManagementMetaSOPClass) : nil)
            guard let context else { throw DicomPrintManagementError.unsupportedService(sop) }
            let reply = try DicomPrintExchange(scu: self, association: association, transport: transport, progress: nil)
                .request(.get, sop: sop, uid: uid, context: context)
            return (reply.status, reply.dataSet)
        }
    }
}
