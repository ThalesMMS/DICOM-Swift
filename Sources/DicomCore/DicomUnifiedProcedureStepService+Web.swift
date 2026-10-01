import Foundation

/// Optional persistence knowledge: absence alone must never be reported as deletion.
public protocol DicomUnifiedProcedureStepDeletionReporting: DicomUnifiedProcedureStepStoring {
    func wasDeleted(sopInstanceUID: String) throws -> Bool
}

extension DicomUnifiedProcedureStepService {
    func webWasDeleted(_ uid: String) throws -> Bool {
        try (store as? any DicomUnifiedProcedureStepDeletionReporting)?.wasDeleted(sopInstanceUID: uid) ?? false
    }

    func webHasSubscription(_ uid: String, ae: String) -> Bool {
        if uid == Self.globalUID || uid == Self.filteredUID {
            guard let subscription = store.globalSubscriptions()[ae], subscription.state != .notSubscribed else { return false }
            return (subscription.matchingKeys != nil) == (uid == Self.filteredUID)
        }
        return store.subscriptions(sopInstanceUID: uid)[ae, default: .notSubscribed] != .notSubscribed
    }
}

extension DicomUnifiedProcedureStepService {
    /// A1 checks valued Type 1 fields; HTTP also requires the explicit empty Type 2 elements.
    func webCreateViolations(_ attributes: DicomDataSet, parent: [Int] = []) -> [Int] {
        var missing: [Int] = []
        for row in DicomUnifiedProcedureStepAttribute.table where Array(row.path.dropLast()) == parent {
            if row.create.hasPrefix("2/2") && attributes[row.tag] == nil { missing.append(row.tag) }
            for item in attributes.sequenceItems(for: row.tag) {
                missing += webCreateViolations(item.dataSet, parent: row.path)
            }
        }
        return missing
    }
}
