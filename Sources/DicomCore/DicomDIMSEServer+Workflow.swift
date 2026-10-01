import Foundation

extension DicomDIMSEServer {
    func workflow(_ command: DicomDIMSECommandSet, context: DicomAcceptedPresentationContext,
                  identifier: DicomDataSet?, session: DicomDIMSEServerSession) async throws {
        guard context.abstractSyntaxUID == DicomNetworkUID.modalityPerformedProcedureStepSOPClass,
              let mpps, let identifier,
              let uid = command.affectedSOPInstanceUID ?? command.requestedSOPInstanceUID else {
            throw DicomDIMSEProviderError(status: 0x0106)
        }
        try Task.checkCancellation()
        _ = try await enforcement(session).check(.store, .init(kind: .instance, id: uid))
        if command.commandField == DicomDIMSECommandField.nCreateRQ {
            _ = try DicomPerformedProcedureStepState.creating(attributes: identifier)
            _ = try await mpps.create(sopInstanceUID: uid, attributes: identifier)
        } else {
            _ = try await mpps.set(sopInstanceUID: uid, attributes: identifier)
        }
        try session.reply(command, contextID: context.id, status: 0)
    }
}
