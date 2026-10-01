import Foundation

/// Stable, serializable decision shared by execution, negotiation, and diagnostic clients.
public struct DicomCodecDecision: Equatable, Codable, Sendable {
    public enum Qualification: String, Codable, Sendable {
        case qualified
        case experimental
        case testOnly = "test-only"
        case unavailable
    }

    public enum ReasonCode: String, Codable, Sendable {
        case unknownSyntax = "codec.syntax.unknown"
        case operationUnsupported = "codec.operation.unsupported"
        case invalidMetadata = "codec.metadata.invalid"
        case runtimeUnavailable = "codec.runtime.unavailable"
        case runtimeIncompatible = "codec.runtime.incompatible"
        case profileForbidden = "codec.profile.forbidden"
        case unqualifiedProfile = "codec.profile.unqualified"
        case partialUnsupported = "codec.partial.unsupported"
        case codestreamInvalid = "codec.codestream.invalid"
        case codestreamRequired = "codec.codestream.required"
        case intentUnsupported = "codec.intent.unsupported"
        case ownershipUnsupported = "codec.ownership.unsupported"
    }

    public let operation: DicomCodecOperation
    public let transferSyntaxUID: String
    public let descriptor: DicomCompressedFrameDescriptor
    public let encodingIntent: String
    public let isRecognized: Bool
    public let canExecute: Bool
    public let backendIdentifier: String?
    public let shadowBackendIdentifier: String?
    public let qualification: Qualification
    public let executionClass: DicomCodecExecutionClass?
    public let outputOwnership: DicomCodecOutputOwnership?
    public let reasonCode: ReasonCode?
    public let reason: String?
    public let fallbackReason: String?

    init(
        request: DicomCodecCapabilityRequest,
        backend: DicomFrameCodecCapabilities? = nil,
        shadow: String? = nil,
        qualification: Qualification = .qualified,
        reasonCode: ReasonCode? = nil,
        reason: String? = nil,
        fallbackReason: String? = nil
    ) {
        operation = request.operation
        transferSyntaxUID = request.descriptor.transferSyntaxUID
        descriptor = request.descriptor
        switch request.intent {
        case .reversible: encodingIntent = "reversible"
        case .irreversible(let quality): encodingIntent = "irreversible(quality: \(quality))"
        case .jpegLSNearLossless(let near): encodingIntent = "jpeg-ls-near-lossless(near: \(near))"
        case .jpegLossless(let options):
            encodingIntent = "jpeg-lossless(predictor: \(options.predictor), pointTransform: \(options.pointTransform), "
                + "restartIntervalRows: \(options.restartIntervalRows))"
        case .jpegLS(let options):
            encodingIntent = "jpeg-ls(near: \(options.near), interleave: \(options.interleave?.rawValue ?? "default"), "
                + "restartIntervalLines: \(options.restartIntervalLines))"
        case .jpegXL(let options):
            encodingIntent = "jpeg-xl(distance: \(options.distance), effort: \(options.effort), "
                + "gaborish: \(options.gaborish), adaptiveQuantization: \(options.adaptiveQuantization))"
        }
        isRecognized = DicomTransferSyntax(uid: transferSyntaxUID) != nil
        backendIdentifier = backend?.identifier.rawValue
        canExecute = backend != nil && reasonCode == nil
        shadowBackendIdentifier = shadow
        self.qualification = backend == nil ? .unavailable : qualification
        executionClass = backend?.executionClass
        outputOwnership = backend?.outputOwnership
        self.reasonCode = reasonCode
        self.reason = reason
        self.fallbackReason = fallbackReason
    }
}
