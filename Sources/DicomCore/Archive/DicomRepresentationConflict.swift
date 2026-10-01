import Foundation

public enum DicomRepresentationConflict: String, Sendable {
    case identicalBytes, equivalentEncoding, conflictingContent

    /// Conservative classification: equal UIDs alone never establish equivalence.
    /// Optional decoded comparison must also establish equality of the non-encoding attributes.
    public static func classify(existing: DicomArchiveRepresentation, incoming: DicomArchiveRepresentation,
                                verifiedDecodedPixelsAndAttributesEqual: Bool = false) -> Self {
        if existing.contentSHA256 == incoming.contentSHA256 { return .identicalBytes }
        if existing.representationSOPInstanceUID == incoming.representationSOPInstanceUID,
           existing.quality == .lossless, incoming.quality == .lossless,
           existing.transferSyntax.registryEntry.isLossless, incoming.transferSyntax.registryEntry.isLossless,
           existing.geometry == incoming.geometry, verifiedDecodedPixelsAndAttributesEqual { return .equivalentEncoding }
        return .conflictingContent
    }
}

public enum DicomRepresentationConflictPolicy: Sendable {
    case keepExisting
    case keepBoth(mintNewIdentity: Bool)
    case replace(authorization: String)

    public struct Resolution: Sendable {
        public let retainExisting: Bool
        public let incomingBytes: Data?
    }

    /// Returns a reviewable result; never mutates a store or silently replaces its original.
    public func resolve(incoming: Data, creatorIdentifier: String, at date: Date = Date()) throws -> Resolution {
        switch self {
        case .keepExisting: return .init(retainExisting: true, incomingBytes: nil)
        case .replace(let authorization):
            guard !authorization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DicomRepresentationRefusal.replacementNotAuthorized
            }
            return .init(retainExisting: false, incomingBytes: incoming)
        case .keepBoth(let mint):
            guard mint else { throw DicomRepresentationRefusal.identityMintRequired }
            let request = try DicomStoreRequest(part10Data: incoming)
            var set = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: incoming))
            let changedTags = [0x00080018, 0x00080008, 0x00082111, 0x00082112]
            let prior = DicomDataSet(elements: changedTags.compactMap { set.element(for: $0) })
            let newUID = DicomDataSetWriter.makeUID()
            set.set(.init(tag: 0x00080018, vr: .UI, value: .strings([newUID])))
            var imageType = set.strings(for: .imageType)
            if imageType.isEmpty { imageType = ["ORIGINAL", "PRIMARY"] }
            imageType[0] = "DERIVED"
            set.set(.init(tag: 0x00080008, vr: .CS, value: .strings(imageType)))
            let description = [set.string(for: 0x00082111), "New identity assigned to retain conflicting archive content."]
                .compactMap { $0 }.joined(separator: "; ")
            set.set(.init(tag: 0x00082111, vr: .ST, value: .strings([description])))
            var sources = set.element(for: .sourceImageSequence)?.sequenceItems ?? []
            sources.append(.init(dataSet: .init(elements: [
                .init(tag: 0x00081150, vr: .UI, value: .strings([request.sopClassUID])),
                .init(tag: 0x00081155, vr: .UI, value: .strings([request.sopInstanceUID]))
            ])))
            set.set(.init(tag: 0x00082112, vr: .SQ, value: .sequence(sources)))
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMddHHmmss.SSS'+0000'"
            var history = set.element(for: 0x04000561)?.sequenceItems ?? []
            history.append(.init(dataSet: .init(elements: [
                .init(tag: 0x04000562, vr: .DT, value: .strings([formatter.string(from: date)])),
                .init(tag: 0x04000563, vr: .LO, value: .strings([creatorIdentifier])),
                .init(tag: 0x04000564, vr: .LO, value: .strings([""])),
                .init(tag: 0x04000565, vr: .CS, value: .strings(["CORRECT"])),
                .init(tag: 0x04000550, vr: .SQ, value: .sequence([.init(dataSet: prior)]))
            ])))
            set.set(.init(tag: 0x04000561, vr: .SQ, value: .sequence(history)))
            let bytes = try DicomDataSetWriter.part10Data(from: set, options: .init(transferSyntax: request.transferSyntax))
            return .init(retainExisting: true, incomingBytes: bytes)
        }
    }
}
