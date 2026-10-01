import Foundation

/// The host supplies the canonical instance, including its study/series ancestry.
/// Representation hashes and transfer syntax choices cannot replace the source authorization.
public struct DicomAuthorizedRepresentationAccess: Sendable {
    public let resource: DicomResourceRef
    public init(representationID: String, instance: DicomResourceRef) {
        resource = .init(kind: .representation, id: representationID, parent: instance)
    }
    public func decide(principal: DicomPrincipal?, authorizer: any DicomAuthorizing,
                       context: DicomAccessContext) async -> DicomAuthorizationDecision {
        guard resource.sourceObject.kind == .instance else {
            return .init(outcome: .deny, reason: .resourceRestricted, policyVersion: await authorizer.policyVersion,
                         evaluatedAt: context.at)
        }
        return await authorizer.decide(principal: principal, operation: .readBytes,
                                       resource: resource.sourceObject, context: context)
    }
}
