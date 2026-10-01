import Foundation

extension DicomDIMSEServiceSCU {
    public func verify(progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        try performWithResilience(operation: .verification, progress: progress) { transport in
            try verify(using: transport, progress: progress)
        }
    }

    public func verify(using transport: DicomAssociationTransport,
                       progress: ((DicomDIMSEProgress) -> Void)? = nil) throws -> DicomDIMSEOperationResult {
        let operation = DicomDIMSEOperation.verification
        let association = try openAssociation(
            for: operation,
            abstractSyntaxUIDs: [DicomNetworkUID.verificationSOPClass],
            using: transport,
            progress: progress
        )
        defer { try? release(operation: operation, using: transport, progress: progress) }

        let context = try acceptedContext(DicomNetworkUID.verificationSOPClass, in: association)
        let messageID: UInt16 = 1
        let command = DicomDIMSECommandSet(
            affectedSOPClassUID: DicomNetworkUID.verificationSOPClass,
            commandField: DicomDIMSECommandField.cEchoRQ,
            messageID: messageID,
            commandDataSetType: DicomDIMSECommandDataSetType.noDataSet
        )
        try sendCommand(command,
                        presentationContextID: context.id,
                        association: association,
                        transport: transport)
        progress?(.requestSent(operation: operation, messageID: messageID))

        let reader = DicomDIMSEMessageReader()
        let response = try readCommand(using: transport, association: association, reader: reader)
        try expect(response, commandField: DicomDIMSECommandField.cEchoRSP)
        try validateSuccessStatus(response)
        let result = operationResult(from: response)
        progress?(.completed(operation: operation, status: result.status))
        return result
    }
}
