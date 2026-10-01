import Foundation

public struct DicomPeerRepresentationCapabilities: Sendable {
    public let acceptedTransferSyntaxes: [DicomTransferSyntax]
    public let acceptsLossy: Bool?
    public init(acceptedTransferSyntaxes: [DicomTransferSyntax], acceptsLossy: Bool? = nil) {
        self.acceptedTransferSyntaxes = acceptedTransferSyntaxes; self.acceptsLossy = acceptsLossy
    }
}

public enum DicomRepresentationLossPolicy: Equatable, Sendable {
    case originalOnly, losslessEquivalents, lossyDerivedAllowed(authorization: String)
    var allowsLossy: Bool {
        guard case .lossyDerivedAllowed(let authorization) = self else { return false }
        return !authorization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var hash: String {
        let value: String
        switch self {
        case .originalOnly: value = "originalOnly"
        case .losslessEquivalents: value = "losslessEquivalents"
        case .lossyDerivedAllowed(let authorization): value = "lossyDerivedAllowed:" + authorization
        }
        return DicomArchiveRepresentation.hash(Data(value.utf8))
    }
}

public struct DicomRepresentationCostModel: Sendable {
    public struct Figures: Equatable, Sendable {
        public let bytesToSend: Int
        public let generationWorkingSetBytes: Int
        public let codecAvailable: Bool
        public init(bytesToSend: Int = 0, generationWorkingSetBytes: Int = 0, codecAvailable: Bool = false) {
            self.bytesToSend = max(0, bytesToSend)
            self.generationWorkingSetBytes = max(0, generationWorkingSetBytes)
            self.codecAvailable = codecAvailable
        }
        public init(plan: DicomTranscodeExecutionPlan, estimatedOutputBytes: Int) {
            self.init(bytesToSend: estimatedOutputBytes, generationWorkingSetBytes: plan.cost.workingSetBytes,
                      codecAvailable: true)
        }
    }
    public let generationAllowed: Bool
    public let estimate: @Sendable (DicomArchiveRepresentation) -> Figures
    public init(generationAllowed: Bool = false,
                estimate: @escaping @Sendable (DicomArchiveRepresentation) -> Figures = { _ in .init() }) {
        self.generationAllowed = generationAllowed; self.estimate = estimate
    }
}

public enum DicomRepresentationReasonCode: String, Sendable {
    case originalAccepted, storedEquivalent, authorizedStoredDerivative, generationRequired
    case syntaxNotAccepted, policyExcluded, lossyNotAuthorized, peerRejectsLossy
    case stale, unavailable, generationDisabled, codecUnavailable, higherCostOrRank
}

/// Audit projection deliberately excludes locators, arbitrary authorization strings and codec diagnostics.
public struct DicomRepresentationDecision: Equatable, Sendable {
    public struct Candidate: Equatable, Sendable {
        public let sourceSOPInstanceUID: String
        public let representationSOPInstanceUID: String
        public let contentSHA256: String
        public let transferSyntax: DicomTransferSyntax
        init(_ item: DicomArchiveRepresentation) {
            sourceSOPInstanceUID = item.sourceSOPInstanceUID
            representationSOPInstanceUID = item.representationSOPInstanceUID
            contentSHA256 = item.contentSHA256; transferSyntax = item.transferSyntax
        }
    }
    public struct Rejected: Equatable, Sendable {
        public let candidate: Candidate
        public let reasonCodes: [DicomRepresentationReasonCode]
    }
    public let chosenRepresentation: Candidate
    public let reasonCodes: [DicomRepresentationReasonCode]
    public let rejectedCandidates: [Rejected]
    public let cost: DicomRepresentationCostModel.Figures
    public let policySnapshotHash: String
}

public enum DicomRepresentationRefusal: Error, Equatable, Sendable {
    case noEligibleRepresentation([DicomRepresentationDecision.Rejected])
    case sourceChanged, codecUnavailable, limitReached, generationFailed, cancelled, invalidOutput, missingBytes
    case replacementNotAuthorized, identityMintRequired
}

public enum DicomRepresentationSelector {
    public static func select(set: DicomRepresentationSet, peer: DicomPeerRepresentationCapabilities,
                              policy: DicomRepresentationLossPolicy,
                              cost: DicomRepresentationCostModel = .init()) throws -> DicomRepresentationDecision {
        var eligible: [(DicomArchiveRepresentation, DicomRepresentationCostModel.Figures, Int)] = []
        var rejected: [DicomRepresentationDecision.Rejected] = []
        for item in set.representations {
            var reasons: [DicomRepresentationReasonCode] = []
            let figures = cost.estimate(item)
            if !peer.acceptedTransferSyntaxes.contains(item.transferSyntax) { reasons.append(.syntaxNotAccepted) }
            if policy == .originalOnly && item.kind != .original { reasons.append(.policyExcluded) }
            if item.kind == .lossyDerived && !policy.allowsLossy { reasons.append(.lossyNotAuthorized) }
            if peer.acceptsLossy == false, case .lossy = item.quality { reasons.append(.peerRejectsLossy) }
            let phase: Int
            switch item.availability {
            case .stored: phase = 0
            case .generatable:
                phase = 1
                if !cost.generationAllowed { reasons.append(.generationDisabled) }
                if !figures.codecAvailable { reasons.append(.codecUnavailable) }
            case .unavailable(let reason):
                phase = 2; reasons.append(reason == .stale ? .stale : .unavailable)
            }
            if reasons.isEmpty { eligible.append((item, figures, phase)) }
            else { rejected.append(.init(candidate: .init(item), reasonCodes: reasons)) }
        }
        eligible.sort {
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            if $0.0.kind != $1.0.kind { return $0.0.kind.rawValue < $1.0.kind.rawValue }
            if $0.1.bytesToSend != $1.1.bytesToSend { return $0.1.bytesToSend < $1.1.bytesToSend }
            if $0.1.generationWorkingSetBytes != $1.1.generationWorkingSetBytes {
                return $0.1.generationWorkingSetBytes < $1.1.generationWorkingSetBytes
            }
            return DicomRepresentationSet.ordered($0.0, $1.0)
        }
        guard let chosen = eligible.first else { throw DicomRepresentationRefusal.noEligibleRepresentation(rejected) }
        rejected += eligible.dropFirst().map { .init(candidate: .init($0.0), reasonCodes: [.higherCostOrRank]) }
        rejected.sort {
            let a = $0.candidate; let b = $1.candidate
            return (a.transferSyntax.rawValue, a.contentSHA256, a.representationSOPInstanceUID)
                < (b.transferSyntax.rawValue, b.contentSHA256, b.representationSOPInstanceUID)
        }
        let reason: DicomRepresentationReasonCode = chosen.2 == 1 ? .generationRequired
            : chosen.0.kind == .original ? .originalAccepted
            : chosen.0.kind == .losslessEquivalent ? .storedEquivalent : .authorizedStoredDerivative
        let snapshot = policy.hash + ":generation=" + String(cost.generationAllowed)
        return .init(chosenRepresentation: .init(chosen.0), reasonCodes: [reason], rejectedCandidates: rejected,
                     cost: chosen.1, policySnapshotHash: DicomArchiveRepresentation.hash(Data(snapshot.utf8)))
    }
}
