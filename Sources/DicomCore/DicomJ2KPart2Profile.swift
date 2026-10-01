//
//  DicomJ2KPart2Profile.swift
//  DicomCore
//
//  Rules of the JPEG 2000 Part 2 Multi-component transfer syntaxes `1.2.840.10008.1.2.4.92/.93` (PS3.5 8.2.4):
//  only the Annex J multiple component transformation extension of ISO/IEC 15444-2, applied across the frames of
//  the object (each frame is a component of a codestream, each fragment carries one component collection), the
//  reversible 5-3 filter with reversible transformations for `.92`, and no other Part 2 annex. Issue #2331.
//

import DicomCodecs
import DicomJPEG2000
import Foundation

enum DicomJ2KPart2Profile {
    static let syntaxUIDs: Set<String> = [
        DicomTransferSyntax.jpeg2000Part2MulticomponentLossless.rawValue,
        DicomTransferSyntax.jpeg2000Part2Multicomponent.rawValue
    ]

    /// Frames per component collection written by the own encoder: every frame of a collection is decoded together,
    /// so the group bounds the working set (64 frames × 16-bit × 512² = 32 MiB of samples).
    static let framesPerCollection = 64
    /// Components the own decoder accepts in one collection (an Annex J stage needs every component in memory).
    static let maximumCollectionComponents = 1024
    /// Decoded bytes of one collection the own decoder is willing to materialise.
    static let maximumCollectionBytes = 1 << 30

    /// Rsiz Part 2 flag and the Annex J extension bit (T.801 Table A.2).
    static let part2Flag = 0x8000
    static let annexJFlag = 0x0001

    static func isPart2(_ uid: String) -> Bool { syntaxUIDs.contains(uid) }

    /// The forward decorrelation matrix the own encoder applies across a collection of `count` frames: every frame is
    /// coded as its difference to the previous frame (unimodular integer matrix, integer inverse = cumulative sums),
    /// which is reversible and keeps the coded range within one extra bit.
    static func differenceMatrix(count: Int) throws -> J2KMCTMatrix {
        var coefficients = [Double](repeating: 0, count: count * count)
        for row in 0..<count {
            coefficients[row * count + row] = 1
            if row > 0 { coefficients[row * count + row - 1] = -1 }
        }
        return try J2KMCTMatrix(size: count, coefficients: coefficients, precision: .integer)
    }

    /// The first violated PS3.5 rule of `uid` for a collection codestream, or nil. Wavelet-based collections are
    /// permitted by PS3.5 and reported by `unsupportedReason` instead.
    static func violation(of uid: String, in inspection: DicomJ2KCodestreamInspector.Inspection) -> String? {
        guard isPart2(uid) else { return nil }
        guard inspection.capabilities & part2Flag != 0 else {
            return "the codestream does not declare ISO/IEC 15444-2 capabilities (Rsiz bit 15)"
        }
        let otherExtensions = inspection.capabilities & 0x3FFF & ~annexJFlag
        guard otherExtensions == 0 else {
            return "the codestream declares Part 2 extensions other than the Annex J multiple component transformation (Rsiz 0x\(String(otherExtensions, radix: 16)))"
        }
        guard inspection.capabilities & annexJFlag != 0 else {
            return "the codestream does not declare the Annex J multiple component transformation extension (Rsiz bit 0)"
        }
        guard let annexJ = inspection.annexJ, annexJ.stageCount > 0 else {
            return "the codestream carries no MCO multiple component transformation ordering"
        }
        if uid == DicomTransferSyntax.jpeg2000Part2MulticomponentLossless.rawValue {
            guard inspection.isLosslessCoding else {
                return "a lossless-only transfer syntax requires the reversible 5-3 filter without quantisation"
            }
            guard annexJ.reversibleCollections == annexJ.arrayBasedCollections + annexJ.waveletBasedCollections else {
                return "a lossless-only transfer syntax requires reversible multiple component transformations"
            }
        }
        if inspection.usesMultipleComponentTransform {
            return "the Annex G RCT/ICT (SGcod 1) cannot be combined with the Annex J transformation of the .92/.93 syntaxes"
        }
        return nil
    }

    /// Why the own codec cannot decode a PS3.5-conformant collection (wavelet-based or dependency transformations).
    static func unsupportedReason(_ inspection: DicomJ2KCodestreamInspector.Inspection) -> String? {
        guard let annexJ = inspection.annexJ else { return nil }
        if annexJ.waveletBasedCollections > 0 {
            return "wavelet-based multiple component transformations (T.801 J.3) are not implemented by the own codec"
        }
        if annexJ.dependencyArrays > 0 {
            return "dependency multiple component transformations (T.801 J.3.2) are not implemented by the own codec"
        }
        if annexJ.componentCount > maximumCollectionComponents {
            return "a collection of \(annexJ.componentCount) components exceeds the \(maximumCollectionComponents)-component bound"
        }
        return nil
    }
}
