import Foundation

public struct DicomLifecyclePublication: Sendable {
    public let plan: DicomRoutingPlan?
    public let outcome: DicomLifecycleRecordOutcome
    public let dryRun: Bool
}

public actor DicomLifecyclePublisher {
    public enum PublicationError: Error { case missingSubject, invalidDestination, missingObjects }
    private let sink: any DicomLifecycleEventSink
    private let evaluator: DicomRoutingEvaluator?
    private let destinations: [String: DicomRoutingDestination]
    private let subjectProvider: @Sendable (DicomLifecycleEvent) -> DicomRoutingSubject?
    private let objectURLs: @Sendable (DicomLifecycleEvent, DicomRoutingSubject) -> [URL]
    private let idempotency: @Sendable (DicomLifecycleEvent, String) -> String
    private let authorizer: (any DicomAuthorizing)?
    private let principal: DicomPrincipal?
    private let audit: DicomAuditRecorder?
    private let dryRun: Bool

    public init(sink: any DicomLifecycleEventSink, evaluator: DicomRoutingEvaluator? = nil,
                destinations: [String: DicomRoutingDestination] = [:],
                subjectProvider: @escaping @Sendable (DicomLifecycleEvent) -> DicomRoutingSubject? = { _ in nil },
                idempotency: @escaping @Sendable (DicomLifecycleEvent, String) -> String = { "\($0.eventID)@\($1)" },
                dryRun: Bool = false,
                objectURLs: @escaping @Sendable (DicomLifecycleEvent, DicomRoutingSubject) -> [URL] = { _, _ in [] },
                authorizer: (any DicomAuthorizing)? = nil, principal: DicomPrincipal? = nil,
                audit: DicomAuditRecorder? = nil) {
        self.authorizer = authorizer; self.principal = principal; self.audit = audit
        self.sink = sink
        self.evaluator = evaluator
        self.destinations = destinations
        self.subjectProvider = subjectProvider
        self.idempotency = idempotency
        self.dryRun = dryRun
        self.objectURLs = objectURLs
    }

    public func publish(_ event: DicomLifecycleEvent) async throws -> DicomLifecyclePublication {
        var event = event
        var plan: DicomRoutingPlan?
        var obligations: [DicomDeliveryItem] = []
        if let evaluator {
            guard let subject = subjectProvider(event) else { throw PublicationError.missingSubject }
            let evaluated = try await evaluator.evaluate(subject, dryRun: dryRun, now: event.occurredAt,
                authorizer: authorizer, principal: principal, audit: audit)
            plan = evaluated
            event.routingDecisions = evaluated.decisions
            for decision in evaluated.routed where !dryRun {
                guard let id = decision.destinationID, let destination = destinations[id],
                      destination.id == id, destination.enabled else { throw PublicationError.invalidDestination }
                let kind: DicomDeliveryDestinationKind
                let payload: DicomDeliveryItem.Payload
                let byteCount: Int64
                switch destination.kind {
                case .webhook:
                    kind = .webhook
                    let webhook = try event.webhookEvent(source: event.sourceKind)
                    payload = .event(webhook)
                    byteCount = Int64(try DicomWebhookCanonicalJSON.encode(webhook).count)
                case .dimseStore, .stowRS:
                    kind = destination.kind == .dimseStore ? .dimseStore : .stowRS
                    let urls = objectURLs(event, subject)
                    guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { throw PublicationError.missingObjects }
                    payload = .objects(urls)
                    byteCount = try urls.reduce(Int64(0)) { total, url in
                        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                            throw PublicationError.missingObjects
                        }
                        return total + Int64(size)
                    }
                }
                obligations.append(.init(eventID: event.eventID, destinationID: id, destinationKind: kind,
                    idempotencyKey: idempotency(event, id),
                    priority: (decision.priority ?? subject.priority) == .stat ? .stat : .routine,
                    payload: payload, byteCount: byteCount, now: event.occurredAt,
                    resource: .init(kind: .study, id: subject.studyInstanceUID)))
            }
        }
        let outcome = try await sink.record(event, obligations: obligations)
        return .init(plan: plan, outcome: outcome, dryRun: dryRun)
    }
}
