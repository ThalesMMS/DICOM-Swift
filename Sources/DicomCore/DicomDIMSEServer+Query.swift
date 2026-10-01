import Foundation

extension DicomDIMSEServer {
    func queryRequest(context: DicomAcceptedPresentationContext, identifier: DicomDataSet?,
                      session: DicomDIMSEServerSession) throws -> DicomQueryRequest {
        guard let identifier else { throw DicomDIMSEProviderError(status: 0xA900) }
        let model: DicomQueryInformationModel
        if context.abstractSyntaxUID == DicomNetworkUID.modalityWorklistInformationModelFind {
            model = .modalityWorklist
        } else if context.abstractSyntaxUID.hasPrefix("1.2.840.10008.5.1.4.1.2.1.") {
            model = .patientRoot
        } else if context.abstractSyntaxUID.hasPrefix("1.2.840.10008.5.1.4.1.2.2.") {
            model = .studyRoot
        } else { throw DicomDIMSEProviderError(status: 0xA900) }
        let level = identifier.string(for: 0x00080052).flatMap(DicomQueryLevel.init(rawValue:))
        if model != .modalityWorklist && (level == nil || (model == .studyRoot && level == .patient)) {
            throw DicomDIMSEProviderError(status: 0xA900, errorComment: "Invalid Query/Retrieve Level")
        }
        let flags = session.association.accept.extendedNegotiations.first { $0.sopClassUID == context.abstractSyntaxUID }
        if model != .modalityWorklist, flags?.relationalQueries != true, let level {
            var ancestors: [Int] = []
            if model == .patientRoot && level != .patient { ancestors.append(0x00100020) }
            if level == .series || level == .image { ancestors.append(0x0020000D) }
            if level == .image { ancestors.append(0x0020000E) }
            for tag in ancestors {
                guard let value = identifier.string(for: tag), !value.isEmpty,
                      !value.contains("*"), !value.contains("?"), !value.contains("\\") else {
                    throw DicomDIMSEProviderError(status: 0xA900, errorComment: "Missing hierarchical unique key")
                }
            }
        }
        return DicomQueryRequest(model: model, level: level, identifier: identifier,
            relationalQueries: flags?.relationalQueries ?? false, dateTimeMatching: flags?.dateTimeMatching ?? false,
            requestingAETitle: session.association.request.callingAETitle, associationContext: session.authorizationContext)
    }

    func find(_ command: DicomDIMSECommandSet, context: DicomAcceptedPresentationContext,
              identifier: DicomDataSet?, session: DicomDIMSEServerSession) async throws {
        let request = try queryRequest(context: context, identifier: identifier, session: session)
        guard let provider = request.model == .modalityWorklist ? worklist : query else {
            throw DicomDIMSEProviderError(status: 0xA900)
        }
        let warning = request.identifier.elements.contains { provider.unsupportedOptionalKeys.contains($0.tag) }
        for try await match in provider.matches(for: request) {
            try Task.checkCancellation()
            if let resource = DicomResourceRef.dataSet(match) {
                guard try await enforcement(session).check(.query, resource, filtering: true) else { continue }
            } else if authorizer != nil { continue }
            try session.reply(command, contextID: context.id, status: warning ? 0xFF01 : 0xFF00, identifier: match)
        }
        try Task.checkCancellation()
        try session.reply(command, contextID: context.id, status: 0)
    }
}
