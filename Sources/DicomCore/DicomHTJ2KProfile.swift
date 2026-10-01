//
//  DicomHTJ2KProfile.swift
//  DicomCore
//
//  Per-UID constraints of the JPEG 2000 and HTJ2K frame transfer syntaxes (PS3.5 A.4.4, A.4.x HTJ2K and 10.18.1),
//  checked against the main header of one codestream (issue #2330).
//

import DicomCodecs
import Foundation

enum DicomHTJ2KProfile {
    /// Largest side of the lowest resolution level that PS3.5 10.18.1 allows for `.202` (thumbnail retrieval).
    static let thumbnailSide = 64

    /// Decomposition levels that bring both sides of the base resolution to at most `thumbnailSide` samples.
    static func rpclDecompositionLevels(rows: Int, columns: Int) -> Int {
        var levels = 0
        var side = max(rows, columns)
        while side > thumbnailSide, levels < 10 {
            side = (side + 1) / 2
            levels += 1
        }
        return levels
    }

    /// PS3.5 10.18.1 reads "the width or height of the base resolution"; either side at or below 64 satisfies it.
    static func hasThumbnailResolution(width: Int, height: Int, decompositionLevels: Int) -> Bool {
        let divisor = 1 << max(0, min(30, decompositionLevels))
        let baseWidth = (width + divisor - 1) / divisor
        let baseHeight = (height + divisor - 1) / divisor
        return min(baseWidth, baseHeight) <= thumbnailSide
    }

    /// Returns the first violated constraint of `uid` for `codestream`, or nil when the main header satisfies every
    /// constraint of the transfer syntax: Part 15 capabilities (CAP + HT code-block style) for `.201/.202/.203` and
    /// their absence for `.90/.91`; reversible coding without quantisation for the lossless-only syntaxes; and the
    /// RPCL order, TLM marker segment and thumbnail resolution for `.202`.
    static func violation(of uid: String, in codestream: Data, strictRPCLOptions: Bool = true) -> String? {
        guard let syntax = DicomTransferSyntax(uid: uid), let family = DicomCodecFamily.family(for: syntax),
              family == .jpeg2000 || family == .htj2k else {
            return "\(uid) is not a JPEG 2000 or HTJ2K frame transfer syntax"
        }
        let inspection: DicomJ2KCodestreamInspector.Inspection
        do { inspection = try DicomJ2KCodestreamInspector.inspect(codestream) } catch {
            return "the frame is not a parseable JPEG 2000 codestream"
        }
        return violation(of: uid, inspection: inspection, strictRPCLOptions: strictRPCLOptions)
    }

    /// The same rules over an inspection the caller already holds.
    static func violation(of uid: String, inspection: DicomJ2KCodestreamInspector.Inspection,
                          strictRPCLOptions: Bool = true) -> String? {
        guard let syntax = DicomTransferSyntax(uid: uid), let family = DicomCodecFamily.family(for: syntax),
              family == .jpeg2000 || family == .htj2k else {
            return "\(uid) is not a JPEG 2000 or HTJ2K frame transfer syntax"
        }
        if DicomJ2KPart2Profile.isPart2(uid) {
            return DicomJ2KPart2Profile.violation(of: uid, in: inspection)
        }
        if inspection.usesPart2Extensions || inspection.annexJ != nil {
            return "the codestream uses ISO/IEC 15444-2 extensions, which the Part 1 and Part 15 syntaxes do not permit"
        }
        let highThroughput = family == .htj2k
        if inspection.isHighThroughput != highThroughput {
            return highThroughput
                ? "the codestream does not declare ISO/IEC 15444-15 (HT) capabilities and HT code-blocks"
                : "the codestream uses ISO/IEC 15444-15 (HT) code-blocks, which the Part 1 syntaxes do not permit"
        }
        let losslessOnly = syntax == .jpeg2000Lossless || syntax == .htj2kLossless || syntax == .htj2kLosslessRPCL
        if losslessOnly, !inspection.isLosslessCoding {
            return "a lossless-only transfer syntax requires the reversible 5-3 filter without quantisation"
        }
        if syntax == .htj2kLosslessRPCL, strictRPCLOptions {
            if inspection.progressionOrder != 2 { return "PS3.5 10.18.1 requires the RPCL progression order" }
            if !inspection.hasTileLengthMarkers { return "PS3.5 10.18.1 requires a TLM marker segment" }
            if !hasThumbnailResolution(width: inspection.width, height: inspection.height,
                                       decompositionLevels: inspection.decompositionLevels) {
                return "PS3.5 10.18.1 requires enough decompositions for a base resolution of at most 64 samples"
            }
        }
        return nil
    }
}
