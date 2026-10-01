import Foundation

public struct DicomUnifiedProcedureStepResponse: Sendable {
    public let status: UInt16
    public let dataSet: DicomDataSet?
    public let matches: [DicomDataSet]
    public let pendingStatuses: [UInt16]
    public var warning: Bool { status & 0xF000 == 0xB000 || status == 1 }
}

extension DicomDIMSEServiceSCU {
    public func createUnifiedProcedureStep(sopInstanceUID: String, attributes: DicomDataSet,
        using transport: DicomAssociationTransport? = nil) throws -> DicomUnifiedProcedureStepResponse {
        try upsRequest(context: DicomNetworkUID.unifiedProcedureStepPushSOPClass, field: DicomDIMSECommandField.nCreateRQ,
                       uid: sopInstanceUID, dataSet: attributes, transport: transport)
    }
    public func findUnifiedProcedureSteps(identifier: DicomDataSet,
        sopClassUID: String = DicomNetworkUID.unifiedProcedureStepPullSOPClass,
        using transport: DicomAssociationTransport? = nil) throws -> DicomUnifiedProcedureStepResponse {
        guard [DicomNetworkUID.unifiedProcedureStepPullSOPClass, DicomNetworkUID.unifiedProcedureStepWatchSOPClass,
               DicomNetworkUID.unifiedProcedureStepQuerySOPClass].contains(sopClassUID) else {
            throw DicomDIMSEProviderError(status: 0x0122)
        }
        return try upsRequest(context: sopClassUID, field: DicomDIMSECommandField.cFindRQ,
                              uid: "", dataSet: identifier, transport: transport)
    }
    public func getUnifiedProcedureStep(sopInstanceUID: String, attributes: [Int]? = nil,
        using transport: DicomAssociationTransport? = nil) throws -> DicomUnifiedProcedureStepResponse {
        try upsRequest(context: DicomNetworkUID.unifiedProcedureStepPullSOPClass, field: DicomDIMSECommandField.nGetRQ,
                       uid: sopInstanceUID, attributeIDs: attributes, transport: transport)
    }
    public func setUnifiedProcedureStep(sopInstanceUID: String, attributes: DicomDataSet,
        using transport: DicomAssociationTransport? = nil) throws -> DicomUnifiedProcedureStepResponse {
        try upsRequest(context: DicomNetworkUID.unifiedProcedureStepPullSOPClass, field: DicomDIMSECommandField.nSetRQ,
                       uid: sopInstanceUID, dataSet: attributes, transport: transport)
    }
    public func changeUnifiedProcedureStepState(sopInstanceUID: String, to state: DicomUnifiedProcedureStepState,
        transactionUID: String, using transport: DicomAssociationTransport? = nil) throws -> DicomUnifiedProcedureStepResponse {
        try upsRequest(context: DicomNetworkUID.unifiedProcedureStepPullSOPClass, field: DicomDIMSECommandField.nActionRQ,
                       uid: sopInstanceUID, dataSet: .init(elements: [upsString(0x00741000, state.rawValue),
                        upsString(0x00081195, transactionUID, .UI)]), action: 1, transport: transport)
    }
    public func requestUnifiedProcedureStepCancel(sopInstanceUID: String, information: DicomDataSet = .init(),
        using transport: DicomAssociationTransport? = nil) throws -> DicomUnifiedProcedureStepResponse {
        try upsRequest(context: DicomNetworkUID.unifiedProcedureStepWatchSOPClass, field: DicomDIMSECommandField.nActionRQ,
                       uid: sopInstanceUID, dataSet: information.isEmpty ? nil : information, action: 2, transport: transport)
    }
    public func subscribeUnifiedProcedureStep(sopInstanceUID: String, receivingAE: String, deletionLock: Bool,
        matchingKeys: DicomDataSet = .init(), using transport: DicomAssociationTransport? = nil) throws -> DicomUnifiedProcedureStepResponse {
        let ds = matchingKeys.setting(upsString(0x00741234, receivingAE, .AE))
            .setting(upsString(0x00741230, deletionLock ? "TRUE" : "FALSE"))
        return try upsRequest(context: DicomNetworkUID.unifiedProcedureStepWatchSOPClass, field: DicomDIMSECommandField.nActionRQ,
                              uid: sopInstanceUID, dataSet: ds, action: 3, transport: transport)
    }
    public func unsubscribeUnifiedProcedureStep(sopInstanceUID: String, receivingAE: String,
        using transport: DicomAssociationTransport? = nil) throws -> DicomUnifiedProcedureStepResponse {
        try upsRequest(context: DicomNetworkUID.unifiedProcedureStepWatchSOPClass, field: DicomDIMSECommandField.nActionRQ,
                       uid: sopInstanceUID, dataSet: .init(elements: [upsString(0x00741234, receivingAE, .AE)]),
                       action: 4, transport: transport)
    }
    public func suspendGlobalSubscription(receivingAE: String,
        using transport: DicomAssociationTransport? = nil) throws -> DicomUnifiedProcedureStepResponse {
        try upsRequest(context: DicomNetworkUID.unifiedProcedureStepWatchSOPClass, field: DicomDIMSECommandField.nActionRQ,
                       uid: DicomNetworkUID.unifiedProcedureStepGlobalSubscriptionInstance,
                       dataSet: .init(elements: [upsString(0x00741234, receivingAE, .AE)]), action: 5, transport: transport)
    }
    public func sendInstanceAvailabilityNotification(_ notification: DicomInstanceAvailabilityNotification,
        sopInstanceUID: String, using transport: DicomAssociationTransport? = nil) throws -> DicomUnifiedProcedureStepResponse {
        try upsRequest(context: DicomNetworkUID.instanceAvailabilityNotificationSOPClass, field: DicomDIMSECommandField.nCreateRQ,
                       uid: sopInstanceUID, dataSet: DicomInstanceAvailabilityNotificationBuilder.build(notification), transport: transport)
    }
    public func reportUnifiedProcedureStepEvent(_ event: DicomUnifiedProcedureStepEvent,
        using transport: DicomAssociationTransport? = nil) throws -> DicomUnifiedProcedureStepResponse {
        try upsRequest(context: DicomNetworkUID.unifiedProcedureStepEventSOPClass, field: DicomDIMSECommandField.nEventReportRQ,
                       uid: event.sopInstanceUID, dataSet: event.dataSet, event: event.typeID, transport: transport)
    }

    private func upsRequest(context syntax: String, field: UInt16, uid: String, dataSet: DicomDataSet? = nil,
        action: UInt16? = nil, event: UInt16? = nil, attributeIDs: [Int]? = nil,
        transport: DicomAssociationTransport?) throws -> DicomUnifiedProcedureStepResponse {
        let operation: DicomDIMSEOperation = [DicomDIMSECommandField.nGetRQ, DicomDIMSECommandField.cFindRQ].contains(field)
            ? .query : .workflowWrite
        guard let transport else {
            return try performWithResilience(operation: operation, progress: nil) {
                try upsRequest(context: syntax, field: field, uid: uid, dataSet: dataSet, action: action,
                               event: event, attributeIDs: attributeIDs, transport: $0)
            }
        }
        let association = try openAssociation(for: operation, abstractSyntaxUIDs: [syntax], using: transport, progress: nil)
        defer { try? release(operation: operation, using: transport, progress: nil) }
        let context = try acceptedContext(syntax, in: association)
        let affected = [DicomDIMSECommandField.nCreateRQ, DicomDIMSECommandField.nEventReportRQ,
                        DicomDIMSECommandField.cFindRQ].contains(field)
        let sopClass = field == DicomDIMSECommandField.cFindRQ || syntax == DicomNetworkUID.instanceAvailabilityNotificationSOPClass
            ? syntax : DicomNetworkUID.unifiedProcedureStepPushSOPClass
        let command = DicomDIMSECommandSet(affectedSOPClassUID: affected ? sopClass : nil,
            requestedSOPClassUID: affected ? nil : sopClass, commandField: field,
            messageID: try association.outstandingOperations.allocateMessageID(),
            commandDataSetType: dataSet == nil ? DicomDIMSECommandDataSetType.noDataSet : DicomDIMSECommandDataSetType.hasDataSet,
            priority: field == DicomDIMSECommandField.cFindRQ ? 0 : nil,
            affectedSOPInstanceUID: affected && !uid.isEmpty ? uid : nil,
            requestedSOPInstanceUID: affected ? nil : uid, eventTypeID: event, actionTypeID: action)
        if let attributeIDs, !attributeIDs.isEmpty {
            try association.outstandingOperations.register(command)
            var bytes = try command.encoded()
            var values = Data()
            func word(_ value: Int, into data: inout Data) { data.append(UInt8(value & 255)); data.append(UInt8((value >> 8) & 255)) }
            for tag in attributeIDs { word(tag >> 16, into: &values); word(tag, into: &values) }
            word(0, into: &bytes); word(0x1005, into: &bytes)
            var length = UInt32(values.count).littleEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(values)
            // Command Group Length excludes its own twelve bytes.
            var groupLength = UInt32(bytes.count - 12).littleEndian
            withUnsafeBytes(of: &groupLength) { bytes.replaceSubrange(8..<12, with: $0) }
            let maximum = association.accept.maximumPDULength
            guard maximum == 0 || maximum > 6 else { throw DicomDIMSEProviderError(status: 0x0110) }
            let size = maximum == 0 ? bytes.count : Int(maximum) - 6
            for offset in stride(from: 0, to: bytes.count, by: size) {
                let end = min(bytes.count, offset + size)
                try transport.writePDU(DicomPDUCodec.encode(.pData([.init(presentationContextID: context.id,
                    isCommand: true, isLastFragment: end == bytes.count, data: bytes.subdata(in: offset..<end))])))
            }
        } else {
            try sendCommand(command, presentationContextID: context.id, association: association, transport: transport)
        }
        let transferSyntax = context.transferSyntax ?? .implicitVRLittleEndian
        if let dataSet {
            try sendDataSet(dataSet, transferSyntax: transferSyntax, presentationContextID: context.id,
                            association: association, transport: transport)
        }
        let reader = DicomDIMSEMessageReader()
        var matches: [DicomDataSet] = []
        var pending: [UInt16] = []
        while true {
            let response = try readCommand(using: transport, association: association, reader: reader)
            try expect(response, commandField: field | 0x8000)
            let attributes = try readOptionalDataSet(response: response, transferSyntax: transferSyntax, transport: transport, reader: reader)
            guard let status = response.status else { throw DicomNetworkError.malformedCommandSet("Missing UPS status") }
            if field == DicomDIMSECommandField.cFindRQ && [0xFF00, 0xFF01].contains(status) {
                pending.append(status)
                if let attributes { matches.append(attributes) }
                continue
            }
            return .init(status: status, dataSet: attributes, matches: matches, pendingStatuses: pending)
        }
    }
}
