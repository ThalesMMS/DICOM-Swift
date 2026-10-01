import Foundation

extension DicomDIMSEServer {
    func unifiedProcedureStep(_ command: DicomDIMSECommandSet, context: DicomAcceptedPresentationContext,
                              identifier: DicomDataSet?, session: DicomDIMSEServerSession, commandBytes: Data?) async throws {
        let uid = command.affectedSOPInstanceUID ?? command.requestedSOPInstanceUID ?? ""
        if context.abstractSyntaxUID == DicomNetworkUID.instanceAvailabilityNotificationSOPClass {
            guard command.commandField == DicomDIMSECommandField.nCreateRQ, let instanceAvailability,
                  let identifier, !uid.isEmpty else { throw DicomDIMSEProviderError(status: 0x0211) }
            try DicomInstanceAvailabilityNotification.validate(dataSet: identifier)
            for series in identifier.sequenceItems(for: 0x00081115) {
                for instance in series.dataSet.sequenceItems(for: 0x00081199) {
                    guard let studyUID = identifier.string(for: .studyInstanceUID),
                          let seriesUID = series.dataSet.string(for: .seriesInstanceUID),
                          let instanceUID = instance.dataSet.string(for: 0x00081155) else {
                        throw DicomDIMSEProviderError(status: 0x0106)
                    }
                    _ = try await enforcement(session).check(.notify,
                        .instance(study: studyUID, series: seriesUID, instance: instanceUID))
                }
            }
            try await instanceAvailability.receive(sopInstanceUID: uid, dataSet: identifier)
            try session.reply(command, contextID: context.id, status: 0)
            return
        }
        guard let service = unifiedProcedureSteps else { throw DicomDIMSEProviderError(status: 0x0122) }
        let push = DicomNetworkUID.unifiedProcedureStepPushSOPClass
        let pull = DicomNetworkUID.unifiedProcedureStepPullSOPClass
        let watch = DicomNetworkUID.unifiedProcedureStepWatchSOPClass
        let query = DicomNetworkUID.unifiedProcedureStepQuerySOPClass
        let syntax = context.abstractSyntaxUID
        let action = command.actionTypeID ?? 0
        let allowed: Bool
        switch command.commandField {
        case DicomDIMSECommandField.nCreateRQ: allowed = syntax == push
        case DicomDIMSECommandField.nGetRQ: allowed = [push, pull, watch].contains(syntax)
        case DicomDIMSECommandField.nSetRQ: allowed = syntax == pull
        case DicomDIMSECommandField.cFindRQ: allowed = [pull, watch, query].contains(syntax)
        case DicomDIMSECommandField.nActionRQ:
            allowed = (syntax == pull && action == 1) || (syntax == push && action == 2)
                || (syntax == watch && [2, 3, 4, 5].contains(action))
        case DicomDIMSECommandField.nEventReportRQ: allowed = syntax == DicomNetworkUID.unifiedProcedureStepEventSOPClass
        default: allowed = false
        }
        guard allowed else { throw DicomDIMSEProviderError(status: 0x0211) }
        if command.commandField != DicomDIMSECommandField.cFindRQ {
            guard command.affectedSOPClassUID ?? command.requestedSOPClassUID == push else {
                throw DicomDIMSEProviderError(status: 0x0122)
            }
        }
        let dataSet = identifier ?? .init()
        var result: DicomUnifiedProcedureStepTransition
        switch command.commandField {
        case DicomDIMSECommandField.nEventReportRQ:
            guard let eventType = command.eventTypeID, let identifier else { throw DicomDIMSEProviderError(status: 0x0106) }
            try await service.receiveEvent(sopInstanceUID: uid, typeID: eventType, dataSet: identifier)
            result = .init(status: 0)
        case DicomDIMSECommandField.nCreateRQ:
            guard !uid.isEmpty else { throw DicomDIMSEProviderError(status: 0x0120) }
            result = try await service.create(sopInstanceUID: uid, attributes: dataSet)
        case DicomDIMSECommandField.nGetRQ:
            let selection = try commandBytes.flatMap { try upsAttributeIdentifiers($0) }
            let response = try service.get(sopInstanceUID: uid, attributes: selection)
            try session.reply(command, contextID: context.id, status: response.status, identifier: response.dataSet)
            return
        case DicomDIMSECommandField.nSetRQ:
            result = try await service.set(sopInstanceUID: uid, attributes: dataSet)
        case DicomDIMSECommandField.cFindRQ:
            for match in try service.search(identifier: dataSet) {
                try Task.checkCancellation()
                if let uid = match.dataSet.string(for: .sopInstanceUID) {
                    guard try await enforcement(session).check(.query, .init(kind: .workitem, id: uid), filtering: true) else { continue }
                } else if authorizer != nil { continue }
                try session.reply(command, contextID: context.id, status: match.status, identifier: match.dataSet)
                await Task.yield()
            }
            try Task.checkCancellation()
            result = .init(status: 0)
        default:
            switch action {
            case 1:
                guard let state = DicomUnifiedProcedureStepState(rawValue: dataSet.string(for: 0x00741000) ?? "") else {
                    throw DicomDIMSEProviderError(status: 0x0106)
                }
                result = try await service.changeState(sopInstanceUID: uid, to: state,
                    transactionUID: dataSet.string(for: 0x00081195))
            case 2:
                result = try await service.requestCancel(sopInstanceUID: uid,
                    requestingAE: session.association.request.callingAETitle, information: dataSet)
            case 3, 4, 5:
                guard let ae = dataSet.string(for: 0x00741234), !ae.isEmpty else { throw DicomDIMSEProviderError(status: 0x0120) }
                _ = try await enforcement(session).check(.subscribe, .init(kind: .workitem, id: uid))
                if action == 3 {
                    guard let deletionLock = dataSet.string(for: 0x00741230), ["TRUE", "FALSE"].contains(deletionLock) else {
                        throw DicomDIMSEProviderError(status: 0x0106)
                    }
                    result = try await service.subscribe(sopInstanceUID: uid, receivingAE: ae, deletionLock: deletionLock == "TRUE",
                        matchingKeys: .init(elements: dataSet.elements.filter { ![0x00741234, 0x00741230].contains($0.tag) }))
                } else if action == 4 {
                    result = try await service.unsubscribe(sopInstanceUID: uid, receivingAE: ae)
                } else {
                    guard [DicomUnifiedProcedureStepService.globalUID, DicomUnifiedProcedureStepService.filteredUID].contains(uid) else {
                        throw DicomDIMSEProviderError(status: 0xC314)
                    }
                    result = try await service.suspend(receivingAE: ae)
                }
            default: throw DicomDIMSEProviderError(status: 0x0211)
            }
        }
        try session.reply(command, contextID: context.id, status: result.status)
    }
}

/// Read the standard command AT list without changing the existing normalized-command public API.
func upsAttributeIdentifiers(_ bytes: Data) throws -> [Int]? {
    let ds = try DicomDataSetParser.dataSet(from: bytes, transferSyntax: .implicitVRLittleEndian)
    guard let element = ds[0x00001005] else { return nil }
    if case .unsignedIntegers(let values) = element.value { return values.map { Int($0) } }
    if case .bytes(let raw) = element.value {
        guard raw.count % 4 == 0 else { throw DicomDIMSEProviderError(status: 0x0106) }
        return stride(from: 0, to: raw.count, by: 4).map {
            let group = Int(raw[$0]) + Int(raw[$0 + 1]) * 256
            let element = Int(raw[$0 + 2]) + Int(raw[$0 + 3]) * 256
            return group * 65536 + element
        }
    }
    return nil
}

public struct DicomDIMSEUnifiedProcedureStepEventSink: DicomUnifiedProcedureStepEventSink {
    public let resolver: any DicomMoveDestinationResolving
    public let callingAETitle: String
    public let timeout: TimeInterval
    private let authorizer: (any DicomAuthorizing)?
    private let audit: DicomAuditRecorder?
    private let principalProvider: (@Sendable (DicomUnifiedProcedureStepEvent, String) async -> DicomPrincipal?)?
    public init(resolver: any DicomMoveDestinationResolving, callingAETitle: String, timeout: TimeInterval = 10,
                authorizer: (any DicomAuthorizing)? = nil, audit: DicomAuditRecorder? = nil,
                principalProvider: (@Sendable (DicomUnifiedProcedureStepEvent, String) async -> DicomPrincipal?)? = nil) {
        self.authorizer = authorizer; self.audit = audit; self.principalProvider = principalProvider
        self.resolver = resolver; self.callingAETitle = callingAETitle; self.timeout = timeout
    }
    public func canDeliver(to receivingAETitle: String) async throws -> Bool {
        try await resolver.resolve(aeTitle: receivingAETitle) != nil
    }
    public func deliver(_ event: DicomUnifiedProcedureStepEvent, to receivingAETitle: String) async throws {
        guard let destination = try await resolver.resolve(aeTitle: receivingAETitle) else {
            throw DicomUnifiedProcedureStepDeliveryError(status: 0xC308)
        }
        let access = DicomEnforcement(principal: await principalProvider?(event, receivingAETitle),
            authorizer: authorizer, audit: audit, context: .init(protocol: .dimse))
        try await access.recheck(.readMetadata, .init(kind: .workitem, id: event.sopInstanceUID))
        let configuration = DicomDIMSEConnectionConfiguration(host: destination.host, port: destination.port,
            calledAETitle: receivingAETitle, callingAETitle: callingAETitle, timeout: timeout, tls: destination.tls)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                do {
                    let response = try DicomDIMSEServiceSCU(configuration: configuration).reportUnifiedProcedureStepEvent(event)
                    guard response.status == 0 else { throw DicomUnifiedProcedureStepDeliveryError(status: response.status) }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
