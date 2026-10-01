import DicomNetwork
import Foundation

extension DicomDIMSEServiceSCU {
    /// Issue #2817: the C-STORE sub-operations of one C-MOVE, sent on one association.
    ///
    /// `proposals` names every SOP class with the transfer syntaxes its objects may be sent in; each pair is one
    /// proposed presentation context (at most 128). `request` builds object `index` in one of the syntaxes accepted
    /// for its SOP class, fetching its bytes only then, or returns nil when the object cannot be sent (the caller
    /// records that). `completion` receives each object's outcome as its response arrives, in order, so the caller
    /// can answer the C-MOVE with a pending response per object. Every C-STORE-RQ carries `moveOriginator`.
    public func storeSubOperations(
        count: Int,
        proposals: [(sopClassUID: String, transferSyntaxes: [DicomTransferSyntax])],
        moveOriginator: (aeTitle: String, messageID: UInt16)?,
        request: (_ index: Int, _ accepted: (String) -> [DicomTransferSyntax]) throws -> DicomStoreRequest?,
        completion: (_ index: Int, _ result: Result<DicomDIMSEOperationResult, DicomNetworkError>?) throws -> Void
    ) throws {
        guard count > 0 else { return }
        var contexts: [DicomPresentationContextRequest] = []
        for proposal in proposals {
            for syntax in proposal.transferSyntaxes where !contexts.contains(where: {
                $0.abstractSyntaxUID == proposal.sopClassUID && $0.transferSyntaxUIDs == [syntax.rawValue]
            }) {
                guard contexts.count < 128 else { throw DicomNetworkError.missingPresentationContext }
                contexts.append(.init(id: UInt8(contexts.count * 2 + 1), abstractSyntaxUID: proposal.sopClassUID,
                                      transferSyntaxes: [syntax]))
            }
        }
        try performWithResilience(operation: .store, progress: nil) { transport in
            let association = try openAssociation(for: .store, presentationContexts: contexts,
                                                   using: transport, progress: nil)
            defer { try? release(operation: .store, using: transport, progress: nil) }
            let accepted = association.acceptedPresentationContexts
            func acceptedSyntaxes(_ sopClassUID: String) -> [DicomTransferSyntax] {
                accepted.filter { $0.abstractSyntaxUID == sopClassUID }
                    .compactMap { DicomTransferSyntax(uid: $0.transferSyntaxUID) }
            }
            let reader = DicomDIMSEMessageReader()
            for index in 0 ..< count {
                try operationHandle?.checkCancellation(operation: .store)
                guard let outbound = try request(index, acceptedSyntaxes),
                      let context = accepted.first(where: {
                          $0.abstractSyntaxUID == outbound.sopClassUID
                              && $0.transferSyntaxUID == outbound.transferSyntax.rawValue
                      }) else {
                    try completion(index, nil)
                    continue
                }
                let id = try association.outstandingOperations.allocateMessageID()
                var command = DicomDIMSECommandSet(affectedSOPClassUID: outbound.sopClassUID,
                    commandField: DicomDIMSECommandField.cStoreRQ, messageID: id,
                    commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet, priority: 0,
                    affectedSOPInstanceUID: outbound.sopInstanceUID)
                command.moveOriginatorAETitle = moveOriginator?.aeTitle
                command.moveOriginatorMessageID = moveOriginator?.messageID
                try sendCommand(command, presentationContextID: context.id, association: association, transport: transport)
                try sendDataSetData(outbound.dataSetData, presentationContextID: context.id,
                                    association: association, transport: transport)
                let response = try readCommand(using: transport, association: association, reader: reader)
                try expect(response, commandField: DicomDIMSECommandField.cStoreRSP)
                guard response.messageIDBeingRespondedTo == id else {
                    throw DicomNetworkError.malformedCommandSet("Unexpected sub-operation response Message ID.")
                }
                do {
                    try validateSuccessOrWarningStatus(response)
                    try completion(index, .success(operationResult(from: response)))
                } catch let error as DicomNetworkError {
                    try completion(index, .failure(error))
                }
            }
        }
    }
}
