import Foundation

/// Operator policy for what the workflow may link automatically. Nothing modifies patients or
/// studies in a catalog: the engine records links, proposals and conflicts for the host to act on.
public struct ClinicalWorkflowPolicy: Equatable, Sendable {
    /// Link an arriving study to an order when accession (with issuer) or placer/filler numbers match.
    public var autoLinkStudiesToOrders: Bool
    /// Accept results whose order is unknown (kept as unlinked results) instead of refusing them.
    public var acceptResultsWithoutOrder: Bool
    /// Treat an identity conflict (same identifier, other authority or divergent demographics) as a refusal.
    public var refuseIdentityConflicts: Bool
    public init(autoLinkStudiesToOrders: Bool = true, acceptResultsWithoutOrder: Bool = false, refuseIdentityConflicts: Bool = true) {
        self.autoLinkStudiesToOrders = autoLinkStudiesToOrders
        self.acceptResultsWithoutOrder = acceptResultsWithoutOrder
        self.refuseIdentityConflicts = refuseIdentityConflicts
    }
}

public enum ClinicalIdentityDecision: Equatable, Sendable {
    case new
    case matched(existingKey: String)
    case conflict(existingKey: String, fields: [String])
}

public struct ClinicalWorkflowOutcome: Equatable, Sendable {
    public enum Disposition: String, Sendable { case created, updated, duplicate, linked, refused, superseded }
    public var disposition: Disposition
    public var key: String
    public var identity: ClinicalIdentityDecision
    public var linkedOrderKey: String?
    public var linkedStudyKey: String?
    public var supersededResultKey: String?
    public var reasons: [String]
    public var provenance: ClinicalProvenance?
}

/// Injected persistence for workflow state; ships in memory. Hosts implement durable stores.
public protocol ClinicalWorkflowStore: Sendable {
    func order(key: String) async -> ClinicalOrder?
    func saveOrder(_ order: ClinicalOrder, key: String) async
    func study(key: String) async -> ClinicalStudy?
    func saveStudy(_ study: ClinicalStudy, key: String) async
    func result(key: String) async -> ClinicalResult?
    func saveResult(_ result: ClinicalResult, key: String) async
    func allOrders() async -> [(key: String, order: ClinicalOrder)]
    func allResults() async -> [(key: String, result: ClinicalResult)]
    func seenSource(_ digest: String) async -> String?
    func recordSource(_ digest: String, key: String) async
    func link(orderKey: String, studyKey: String) async
    func links(orderKey: String) async -> [String]
    func identities() async -> [(key: String, identity: ClinicalPatientIdentity)]
    func saveIdentity(_ identity: ClinicalPatientIdentity, key: String) async
    func provenance(key: String) async -> [ClinicalProvenance]
    func recordProvenance(_ provenance: ClinicalProvenance, key: String) async
}

public actor ClinicalInMemoryWorkflowStore: ClinicalWorkflowStore {
    private var orders: [String: ClinicalOrder] = [:]
    private var studies: [String: ClinicalStudy] = [:]
    private var results: [String: ClinicalResult] = [:]
    private var sources: [String: String] = [:]
    private var orderLinks: [String: [String]] = [:]
    private var patients: [String: ClinicalPatientIdentity] = [:]
    private var provenances: [String: [ClinicalProvenance]] = [:]
    public init() {}
    public func order(key: String) -> ClinicalOrder? { orders[key] }
    public func saveOrder(_ order: ClinicalOrder, key: String) { orders[key] = order }
    public func study(key: String) -> ClinicalStudy? { studies[key] }
    public func saveStudy(_ study: ClinicalStudy, key: String) { studies[key] = study }
    public func result(key: String) -> ClinicalResult? { results[key] }
    public func saveResult(_ result: ClinicalResult, key: String) { results[key] = result }
    public func allOrders() -> [(key: String, order: ClinicalOrder)] { orders.map { ($0.key, $0.value) } }
    public func allResults() -> [(key: String, result: ClinicalResult)] { results.map { ($0.key, $0.value) } }
    public func seenSource(_ digest: String) -> String? { sources[digest] }
    public func recordSource(_ digest: String, key: String) { sources[digest] = key }
    public func link(orderKey: String, studyKey: String) { if !(orderLinks[orderKey] ?? []).contains(studyKey) { orderLinks[orderKey, default: []].append(studyKey) } }
    public func links(orderKey: String) -> [String] { orderLinks[orderKey] ?? [] }
    public func identities() -> [(key: String, identity: ClinicalPatientIdentity)] { patients.map { ($0.key, $0.value) } }
    public func saveIdentity(_ identity: ClinicalPatientIdentity, key: String) { patients[key] = identity }
    public func provenance(key: String) -> [ClinicalProvenance] { provenances[key] ?? [] }
    public func recordProvenance(_ provenance: ClinicalProvenance, key: String) { provenances[key, default: []].append(provenance) }
    public var counts: (orders: Int, studies: Int, results: Int, patients: Int) { (orders.count, studies.count, results.count, patients.count) }
}

/// Order -> study -> result state machine with idempotent ingestion: identical sources (digest or
/// control ID), same keys and same versions are duplicates, corrections supersede, identity conflicts
/// are surfaced and never merged.
public actor ClinicalWorkflowEngine {
    public let store: any ClinicalWorkflowStore
    public let policy: ClinicalWorkflowPolicy

    public init(store: any ClinicalWorkflowStore = ClinicalInMemoryWorkflowStore(), policy: ClinicalWorkflowPolicy = .init()) {
        self.store = store
        self.policy = policy
    }

    static func patientKey(_ identity: ClinicalPatientIdentity) -> String? {
        if let identifier = identity.identifier ?? identity.otherIdentifiers.first { return "patient:" + identifier.description }
        guard !identity.isEmpty else { return nil }
        return "patient:demographics:" + [identity.familyName ?? "", identity.givenName ?? "", identity.birthDate ?? "", identity.sex ?? ""].joined(separator: "|").lowercased()
    }

    private func decideIdentity(_ identity: ClinicalPatientIdentity) async -> ClinicalIdentityDecision {
        var matched: ClinicalIdentityDecision = .new
        for (key, existing) in await store.identities() {
            switch identity.compare(with: existing) {
            case .same: if case .new = matched { matched = .matched(existingKey: key) }
            case .conflict(let fields): return .conflict(existingKey: key, fields: fields)
            case .unrelated: continue
            }
        }
        return matched
    }

    private func duplicate(of provenance: ClinicalProvenance) async -> String? {
        if let digest = provenance.sourceDigest, let key = await store.seenSource(digest) { return key }
        guard !provenance.sourceIdentifier.isEmpty else { return nil }
        return await store.seenSource(provenance.sourceKind.rawValue + ":" + provenance.sourceIdentifier)
    }

    private func remember(_ provenance: ClinicalProvenance, key: String) async {
        if let digest = provenance.sourceDigest { await store.recordSource(digest, key: key) }
        if !provenance.sourceIdentifier.isEmpty {
            await store.recordSource(provenance.sourceKind.rawValue + ":" + provenance.sourceIdentifier, key: key)
        }
        await store.recordProvenance(provenance, key: key)
    }

    private func refuse(_ key: String, identity: ClinicalIdentityDecision, reasons: [String]) -> ClinicalWorkflowOutcome {
        .init(disposition: .refused, key: key, identity: identity, linkedOrderKey: nil, linkedStudyKey: nil, supersededResultKey: nil, reasons: reasons, provenance: nil)
    }

    // MARK: orders

    public func ingest(order mapped: Mapped<ClinicalOrder>) async -> ClinicalWorkflowOutcome {
        guard let key = mapped.value.idempotencyKey else { return refuse("order:?", identity: .new, reasons: ["order without placer number, accession or filler number"]) }
        if let existingKey = await duplicate(of: mapped.provenance) {
            await store.recordProvenance(mapped.provenance, key: existingKey)
            return .init(disposition: .duplicate, key: existingKey, identity: .new, linkedOrderKey: existingKey, linkedStudyKey: nil, supersededResultKey: nil, reasons: ["same source already ingested"], provenance: mapped.provenance)
        }
        let identity = await decideIdentity(mapped.value.patient)
        if case .conflict(_, let fields) = identity, policy.refuseIdentityConflicts { return refuse(key, identity: identity, reasons: ["identity conflict: " + fields.joined(separator: ", ")]) }
        let existing = await store.order(key: key)
        if let existing, existing == mapped.value {
            await remember(mapped.provenance, key: key)
            return .init(disposition: .duplicate, key: key, identity: identity, linkedOrderKey: key, linkedStudyKey: nil, supersededResultKey: nil, reasons: ["identical order already stored"], provenance: mapped.provenance)
        }
        await store.saveOrder(mapped.value, key: key)
        if case .new = identity, let patientKey = Self.patientKey(mapped.value.patient) { await store.saveIdentity(mapped.value.patient, key: patientKey) }
        await remember(mapped.provenance, key: key)
        return .init(disposition: existing == nil ? .created : .updated, key: key, identity: identity, linkedOrderKey: key, linkedStudyKey: nil, supersededResultKey: nil, reasons: [], provenance: mapped.provenance)
    }

    // MARK: studies

    private func matchingOrder(for study: ClinicalStudy) async -> String? {
        for (key, order) in await store.allOrders() {
            guard study.patient.compare(with: order.patient) == .same else { continue }
            if let accession = study.accessionNumber, let orderAccession = order.accessionNumber {
                if accession.sameEntity(as: orderAccession) { return key }
                if accession.conflicts(with: orderAccession) { continue }
            }
            if let placer = study.placerOrderNumber, let orderPlacer = order.placerOrderNumber, placer.sameEntity(as: orderPlacer) { return key }
            if let filler = study.fillerOrderNumber, let orderFiller = order.fillerOrderNumber, filler.sameEntity(as: orderFiller) { return key }
        }
        return nil
    }

    public func ingest(study mapped: Mapped<ClinicalStudy>) async -> ClinicalWorkflowOutcome {
        let key = mapped.value.idempotencyKey
        let identity = await decideIdentity(mapped.value.patient)
        if case .conflict(_, let fields) = identity, policy.refuseIdentityConflicts { return refuse(key, identity: identity, reasons: ["identity conflict: " + fields.joined(separator: ", ")]) }
        let existing = await store.study(key: key)
        var orderKey: String? = nil
        if policy.autoLinkStudiesToOrders, let match = await matchingOrder(for: mapped.value) {
            orderKey = match
            await store.link(orderKey: match, studyKey: key)
        }
        if let existing, existing == mapped.value {
            await remember(mapped.provenance, key: key)
            return .init(disposition: .duplicate, key: key, identity: identity, linkedOrderKey: orderKey, linkedStudyKey: key, supersededResultKey: nil, reasons: ["identical study already stored"], provenance: mapped.provenance)
        }
        await store.saveStudy(mapped.value, key: key)
        unknownStudies.remove(key)
        if case .new = identity, let patientKey = Self.patientKey(mapped.value.patient) { await store.saveIdentity(mapped.value.patient, key: patientKey) }
        await remember(mapped.provenance, key: key)
        return .init(disposition: orderKey != nil ? .linked : (existing == nil ? .created : .updated), key: key, identity: identity, linkedOrderKey: orderKey, linkedStudyKey: key, supersededResultKey: nil, reasons: [], provenance: mapped.provenance)
    }

    // MARK: results

    private func matchingOrder(for result: ClinicalResult) async -> String? {
        for (key, order) in await store.allOrders() {
            guard result.patient.compare(with: order.patient) == .same else { continue }
            if let filler = result.fillerOrderNumber, let orderFiller = order.fillerOrderNumber, filler.sameEntity(as: orderFiller) { return key }
            if let placer = result.placerOrderNumber, let orderPlacer = order.placerOrderNumber, placer.sameEntity(as: orderPlacer) { return key }
            if let accession = result.accessionNumber, let orderAccession = order.accessionNumber, accession.sameEntity(as: orderAccession) { return key }
        }
        return nil
    }

    public func ingest(result mapped: Mapped<ClinicalResult>) async -> ClinicalWorkflowOutcome {
        guard let key = mapped.value.idempotencyKey else { return refuse("result:?", identity: .new, reasons: ["result without identifier"]) }
        if let existingKey = await duplicate(of: mapped.provenance) {
            await store.recordProvenance(mapped.provenance, key: existingKey)
            return .init(disposition: .duplicate, key: existingKey, identity: .new, linkedOrderKey: nil, linkedStudyKey: nil, supersededResultKey: nil, reasons: ["same source already ingested"], provenance: mapped.provenance)
        }
        let identity = await decideIdentity(mapped.value.patient)
        if case .conflict(_, let fields) = identity, policy.refuseIdentityConflicts { return refuse(key, identity: identity, reasons: ["identity conflict: " + fields.joined(separator: ", ")]) }
        let orderKey = await matchingOrder(for: mapped.value)
        if orderKey == nil, !policy.acceptResultsWithoutOrder { return refuse(key, identity: identity, reasons: ["no matching order (placer/filler/accession with authority)"]) }
        var studyKey: String? = mapped.value.studyInstanceUID.map { "study:" + $0 }
        if let studyKey, await store.study(key: studyKey) == nil {
            self.noteUnknownStudy(studyKey)
        } else if studyKey == nil, let orderKey { studyKey = await store.links(orderKey: orderKey).first }
        var superseded: String? = nil
        if mapped.value.status == .corrected {
            let previous = await store.allResults().filter { candidate in
                candidate.key != key && mapped.value.patient.compare(with: candidate.result.patient) == .same &&
                    (candidate.result.identifier.map { mapped.value.identifier?.sameEntity(as: $0) ?? false } ?? false ||
                    candidate.result.fillerOrderNumber.map { mapped.value.fillerOrderNumber?.sameEntity(as: $0) ?? false } ?? false)
            }
            superseded = previous.max { $0.result.version < $1.result.version }?.key
        }
        let existing = await store.result(key: key)
        if let existing, existing == mapped.value {
            await remember(mapped.provenance, key: key)
            return .init(disposition: .duplicate, key: key, identity: identity, linkedOrderKey: orderKey, linkedStudyKey: studyKey, supersededResultKey: nil, reasons: ["identical result already stored"], provenance: mapped.provenance)
        }
        await store.saveResult(mapped.value, key: key)
        if case .new = identity, let patientKey = Self.patientKey(mapped.value.patient) { await store.saveIdentity(mapped.value.patient, key: patientKey) }
        await remember(mapped.provenance, key: key)
        return .init(disposition: superseded != nil ? .superseded : (existing == nil ? .created : .updated), key: key, identity: identity, linkedOrderKey: orderKey, linkedStudyKey: studyKey, supersededResultKey: superseded, reasons: [], provenance: mapped.provenance)
    }

    private var unknownStudies: Set<String> = []
    private func noteUnknownStudy(_ key: String) { unknownStudies.insert(key) }
    /// Study UIDs referenced by results that never arrived (for the host to reconcile).
    public var pendingStudies: [String] { unknownStudies.sorted() }
}
