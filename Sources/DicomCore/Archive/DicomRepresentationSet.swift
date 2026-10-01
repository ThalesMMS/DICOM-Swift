import Foundation

public enum DicomRepresentationValidationError: Error, Equatable, Sendable {
    case originalCount, sourceIdentity, equivalentIdentity, derivedIdentity, geometry, lossHistory
    case sourceFingerprint, duplicateRepresentation, invalidDigest, invalidParameters
}

public struct DicomRepresentationSet: Equatable, Sendable {
    public let representations: [DicomArchiveRepresentation]
    public var original: DicomArchiveRepresentation { representations.first { $0.kind == .original }! }

    public init(_ representations: [DicomArchiveRepresentation]) throws {
        guard representations.filter({ $0.kind == .original }).count == 1,
              let original = representations.first(where: { $0.kind == .original }) else {
            throw DicomRepresentationValidationError.originalCount
        }
        var keys: Set<String> = []
        var derivedUIDs: Set<String> = []
        for item in representations {
            guard item.sourceSOPInstanceUID == original.sourceSOPInstanceUID else {
                throw DicomRepresentationValidationError.sourceIdentity
            }
            for digest in [item.contentSHA256, item.sourceContentSHA256] {
                guard digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                    throw DicomRepresentationValidationError.invalidDigest
                }
            }
            guard keys.insert(item.representationSOPInstanceUID + ":" + item.contentSHA256).inserted else {
                throw DicomRepresentationValidationError.duplicateRepresentation
            }
            // Stale descriptors retain their historical source fingerprint for audit.
            if item.availability != .unavailable(.stale) {
                guard item.sourceContentSHA256 == original.contentSHA256,
                      item.provenance.sourceFingerprint == original.contentSHA256 else {
                    throw DicomRepresentationValidationError.sourceFingerprint
                }
            }
            switch item.kind {
            case .original, .losslessEquivalent:
                guard item.representationSOPInstanceUID == original.sourceSOPInstanceUID else {
                    throw DicomRepresentationValidationError.equivalentIdentity
                }
                if item.kind == .losslessEquivalent {
                    guard item.transferSyntax.registryEntry.isLossless, !item.parameters.intent.isLossy else {
                        throw DicomRepresentationValidationError.invalidParameters
                    }
                    guard item.geometry == original.geometry else { throw DicomRepresentationValidationError.geometry }
                    guard item.quality == original.quality else { throw DicomRepresentationValidationError.lossHistory }
                }
            case .lossyDerived:
                guard item.representationSOPInstanceUID != original.sourceSOPInstanceUID,
                      derivedUIDs.insert(item.representationSOPInstanceUID).inserted else {
                    throw DicomRepresentationValidationError.derivedIdentity
                }
                guard case .lossy(let ratios, let methods) = item.quality,
                      !methods.isEmpty, ratios.count == methods.count,
                      ratios.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                    throw DicomRepresentationValidationError.lossHistory
                }
                if case .lossy(let oldRatios, let oldMethods) = original.quality {
                    guard ratios.starts(with: oldRatios), methods.starts(with: oldMethods),
                          methods.count > oldMethods.count else { throw DicomRepresentationValidationError.lossHistory }
                }
            }
        }
        self.representations = representations.sorted(by: Self.ordered)
    }

    /// Stable preference, independent of registry enumeration and insertion order. Unknown UIDs sort lexically last.
    public static let syntaxRankTable: [DicomTransferSyntax] = [
        .explicitVRLittleEndian, .implicitVRLittleEndian, .explicitVRBigEndian, .deflatedExplicitVRLittleEndian,
        .jpeg2000Lossless, .htj2kLossless, .htj2kLosslessRPCL, .jpegLSLossless,
        .jpegLosslessFirstOrder, .jpegLossless, .rleLossless, .deflatedImageFrameCompression,
        .jpegXLLossless, .jpeg2000Part2MulticomponentLossless, .jpegLSNearLossless,
        .jpegBaseline, .jpegExtended, .jpeg2000, .htj2k, .jpegXL, .jpegXLJPEGRecompression,
        .jpeg2000Part2Multicomponent
    ]

    static func ordered(_ a: DicomArchiveRepresentation, _ b: DicomArchiveRepresentation) -> Bool {
        if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
        let ar = syntaxRankTable.firstIndex(of: a.transferSyntax) ?? Int.max
        let br = syntaxRankTable.firstIndex(of: b.transferSyntax) ?? Int.max
        if ar != br { return ar < br }
        if a.transferSyntax != b.transferSyntax { return a.transferSyntax.rawValue < b.transferSyntax.rawValue }
        return a.contentSHA256 < b.contentSHA256
    }
}
