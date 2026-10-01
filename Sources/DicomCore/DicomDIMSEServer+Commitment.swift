import Foundation

extension DicomDIMSEServer {
    func receiveCommitmentReport(_ command: DicomDIMSECommandSet, context: DicomAcceptedPresentationContext,
                                 identifier: DicomDataSet?, session: DicomDIMSEServerSession) async throws {
        guard let commitmentResultHandler, let identifier,
              context.abstractSyntaxUID == DicomNetworkUID.storageCommitmentPushModelSOPClass,
              command.affectedSOPInstanceUID == DicomNetworkUID.storageCommitmentPushModelSOPInstance,
              command.eventTypeID == 1 || command.eventTypeID == 2 else {
            throw DicomDIMSEProviderError(status: 0x0110)
        }
        let report = try DicomStorageCommitmentTracker.parseEventReportDataSet(identifier)
        guard command.eventTypeID == 2 || report.references.allSatisfy({ $0.status == .committed }) else {
            throw DicomDIMSEProviderError(status: 0x0110)
        }
        for reference in report.references {
            _ = try await enforcement(session).check(.notify, try await sourceResource(reference.sopInstanceUID))
        }
        try commitmentResultHandler(report)
        try session.reply(command, contextID: context.id, status: 0)
    }

    func storageCommitment(_ command: DicomDIMSECommandSet, context: DicomAcceptedPresentationContext,
                           identifier: DicomDataSet?, session: DicomDIMSEServerSession) async throws {
        guard context.abstractSyntaxUID == DicomNetworkUID.storageCommitmentPushModelSOPClass,
              command.actionTypeID == 1,
              command.requestedSOPInstanceUID == DicomNetworkUID.storageCommitmentPushModelSOPInstance,
              let identifier, let commitment else { throw DicomDIMSEProviderError(status: 0x0106) }
        let (transaction, references) = try DicomStorageCommitmentTracker.parseActionDataSet(identifier)
        let request = session.association.request
        let requestContext = DicomStorageCommitmentRequestContext(requestingAETitle: request.callingAETitle,
            calledAETitle: request.calledAETitle, associationIdentifier: session.identifier,
            associationContext: session.authorizationContext)
        for reference in references {
            _ = try await enforcement(session).check(.readMetadata, try await sourceResource(reference.sopInstanceUID))
        }
        try await commitment.prepare(transactionUID: transaction, references: references, context: requestContext)
        try session.reply(command, contextID: context.id, status: 0)
        scheduleNotification { [self] in
            do {
                guard try await commitment.shouldDeliverReport(transactionUID: transaction) else { return }
                let verified = try await commitment.verify(transactionUID: transaction, references: references,
                                                           context: requestContext)
                let report = await applyingCommitmentEvidence(to: verified)
                commitmentDeliveryLock.withLock { commitmentReports[transaction] = report }
                try await deliverCommitment(transactionUID: transaction) {
                    for reference in references {
                        try await self.enforcement(session).recheck(.readMetadata,
                            try await self.sourceResource(reference.sopInstanceUID))
                    }
                    if let destination = try await self.moveDestinations?.resolve(aeTitle: request.callingAETitle) {
                        try await self.sendCommitment(report, to: destination, aeTitle: request.callingAETitle)
                    } else {
                        let role = session.association.negotiatedRoleSelection(for: context.abstractSyntaxUID)
                        guard role == nil || role?.scuRole == true else {
                            throw DicomNetworkError.storageCommitmentRoleNotNegotiated
                        }
                        let bytes = try DicomDataSetWriter.dataSetData(
                            from: DicomStorageCommitmentTracker.eventReportDataSet(for: report),
                            transferSyntax: context.transferSyntax ?? .implicitVRLittleEndian)
                        let event = DicomDIMSECommandSet(affectedSOPClassUID: context.abstractSyntaxUID,
                            commandField: DicomDIMSECommandField.nEventReportRQ,
                            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
                            affectedSOPInstanceUID: DicomNetworkUID.storageCommitmentPushModelSOPInstance,
                            eventTypeID: report.references.contains(where: { $0.status == .failed }) ? 2 : 1)
                        let response = try await session.suboperation(event, contextID: context.id, bytes: bytes)
                        guard response.status == 0 else {
                            throw DicomDIMSEProviderError(status: response.status ?? 0x0110)
                        }
                    }
                }
            } catch { resourceGovernor.recordFailure() }
        }
    }

    /// Uses the configured AE resolver and the same serialized transaction delivery as N-ACTION.
    /// An acknowledged report is never sent twice during this server lifetime; durable hosts
    /// restore pending reports through the provider and persist the completion hook.
    /// Supply the original authenticated principal restored from the trusted transaction store.
    public func deliverPendingCommitmentReport(transactionUID: String, to requestingAETitle: String,
                                               principal: DicomPrincipal? = nil) async throws {
        if let commitment, try await !commitment.shouldDeliverReport(transactionUID: transactionUID) { return }
        let cached = commitmentDeliveryLock.withLock { commitmentReports[transactionUID] }
        let report: DicomStorageCommitmentReport
        if let cached { report = cached }
        else if let pending = try await commitment?.pendingReport(transactionUID: transactionUID) { report = pending }
        else { return }
        try await deliverCommitment(transactionUID: transactionUID) {
            let access = DicomEnforcement(principal: principal, authorizer: self.authorizer, audit: self.audit,
                                          context: .init(protocol: .dimse))
            for reference in report.references {
                try await access.recheck(.readMetadata, try await self.sourceResource(reference.sopInstanceUID))
            }
            guard let destination = try await self.moveDestinations?.resolve(aeTitle: requestingAETitle) else {
                throw DicomDIMSEProviderError(status: 0xA801)
            }
            let checked = await self.applyingCommitmentEvidence(to: report)
            try await self.sendCommitment(checked, to: destination, aeTitle: requestingAETitle)
        }
    }

    func applyingCommitmentEvidence(to report: DicomStorageCommitmentReport) async -> DicomStorageCommitmentReport {
        guard let commitmentEvidence else { return report }
        var checked = report
        for index in checked.references.indices where checked.references[index].status == .committed {
            let reason: Int?
            do { reason = try await commitmentEvidence.evidence(for: checked.references[index]).failureReason(policy: commitmentPolicy) }
            catch { reason = 0x0110 }
            if let reason {
                checked.references[index].status = .failed
                checked.references[index].failureReasonCode = UInt16(reason)
                checked.references[index].failureReason = "Durability evidence does not establish safekeeping."
            }
        }
        let successes = checked.references.filter { $0.status == .committed }.count
        checked.status = successes == checked.references.count ? .committed : successes == 0 ? .failed : .partial
        return checked
    }

    private func deliverCommitment(transactionUID: String,
                                   send: @Sendable () async throws -> Void) async throws {
        let admitted = commitmentDeliveryLock.withLock { commitmentDelivering.insert(transactionUID).inserted }
        guard admitted else { throw DicomDIMSEProviderError(status: 0x0210) }
        defer { _ = commitmentDeliveryLock.withLock { commitmentDelivering.remove(transactionUID) } }
        do {
            if !commitmentDeliveryLock.withLock({ commitmentDelivered.contains(transactionUID) }) {
                auditLogger?.record(DicomNetworkAuditEvent(operation: .storageCommitmentReport, outcome: .started,
                    host: "", port: configuration.storage.port, calledAETitle: configuration.storage.aeTitle, attempt: 1))
                try await send()
                auditLogger?.record(DicomNetworkAuditEvent(operation: .storageCommitmentReport, outcome: .succeeded,
                    host: "", port: configuration.storage.port, calledAETitle: configuration.storage.aeTitle, attempt: 1, status: 0))
                _ = commitmentDeliveryLock.withLock { commitmentDelivered.insert(transactionUID) }
            }
            try await onCommitmentReportDelivered?(transactionUID, .succeeded)
        } catch {
            auditLogger?.record(DicomNetworkAuditEvent(operation: .storageCommitmentReport, outcome: .failed,
                host: "", port: configuration.storage.port, calledAETitle: configuration.storage.aeTitle,
                attempt: 1, errorDescription: "Storage Commitment notification failed"))
            try? await onCommitmentReportDelivered?(transactionUID, .failed)
            throw error
        }
    }

    private func sendCommitment(_ report: DicomStorageCommitmentReport, to destination: DicomMoveDestination,
                                aeTitle: String) async throws {
        let config = DicomDIMSEConnectionConfiguration(host: destination.host, port: destination.port,
            calledAETitle: aeTitle, callingAETitle: configuration.storage.aeTitle,
            timeout: configuration.storage.timeout, tls: destination.tls)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try DicomDIMSEServiceSCU(configuration: config).reportStorageCommitment(report)
                    guard response.status == 0 else { throw DicomDIMSEProviderError(status: response.status) }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
