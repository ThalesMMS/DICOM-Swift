import Foundation
import DicomData

/// The media types of frames and bulk data and the transfer syntaxes each one carries (PS3.18 Table 8.7.3-5).
///
/// Lookups by media type also read the spellings servers and clients still use: `image/x-jls`, `image/jhc`,
/// `image/x-dicom-rle` and `video/mpeg2` (as dcm4che's `MediaTypes` and dicomweb-client's `api.js` do). Lookups by
/// transfer syntax answer the PS3.18 spelling.
public enum DicomWebTransferSyntaxMediaTypes {
    /// The media type of `transferSyntaxUID`; nil for a syntax without one, such as Implicit VR Little Endian.
    public static func mediaType(forTransferSyntaxUID transferSyntaxUID: String) -> String? {
        let uid = transferSyntaxUID.trimmingCharacters(in: .whitespaces)
        return table.first { $0.transferSyntaxUIDs.contains(uid) }?.mediaType
    }

    /// The transfer syntaxes `mediaType` carries, its default first; empty for a media type not in the table.
    /// Case, parameters and the alternative spellings are accepted.
    public static func transferSyntaxUIDs(forMediaType mediaType: String) -> [String] {
        guard let type = canonicalMediaType(mediaType) else { return [] }
        return table.first { $0.mediaType == type }?.transferSyntaxUIDs ?? []
    }

    /// The PS3.18 spelling of `mediaType`, without parameters: `image/x-jls` gives `image/jls`. Nil for a media
    /// type not in the table.
    public static func canonicalMediaType(_ mediaType: String) -> String? {
        let type = (try? DicomWebMediaType(mediaType))?.type
            ?? mediaType.trimmingCharacters(in: .whitespaces).lowercased()
        let canonical = alternativeSpellings[type] ?? type
        return table.contains { $0.mediaType == canonical } ? canonical : nil
    }

    private static let alternativeSpellings = [
        "image/x-jls": "image/jls",
        "image/jhc": "image/jphc",
        "image/x-dicom-rle": "image/dicom-rle",
        "video/mpeg2": "video/mpeg"
    ]

    private static let table: [(mediaType: String, transferSyntaxUIDs: [String])] = rows.map { ($0.0, $0.1.map(\.rawValue)) }

    private static let rows: [(String, [DicomTransferSyntax])] = [
        ("application/octet-stream", [.explicitVRLittleEndian]),
        ("image/jpeg", [.jpegLosslessFirstOrder, .jpegBaseline, .jpegExtended, .jpegLossless]),
        ("image/jls", [.jpegLSLossless, .jpegLSNearLossless]),
        ("image/jp2", [.jpeg2000Lossless, .jpeg2000]),
        ("image/jpx", [.jpeg2000Part2MulticomponentLossless, .jpeg2000Part2Multicomponent]),
        ("image/jphc", [.htj2kLossless, .htj2kLosslessRPCL, .htj2k]),
        ("image/jxl", [.jpegXLLossless, .jpegXLJPEGRecompression, .jpegXL]),
        ("image/dicom-rle", [.rleLossless]),
        ("application/x-deflate", [.deflatedImageFrameCompression]),
        ("video/mpeg", [.mpeg2MainProfileMainLevel, .mpeg2MainProfileMainLevelFragmentable,
                        .mpeg2MainProfileHighLevel, .mpeg2MainProfileHighLevelFragmentable]),
        ("video/mp4", [.mpeg4AVCH264HighProfileLevel41, .mpeg4AVCH264HighProfileLevel41Fragmentable,
                       .mpeg4AVCH264BDCompatibleHighProfileLevel41, .mpeg4AVCH264BDCompatibleHighProfileLevel41Fragmentable,
                       .mpeg4AVCH264HighProfileLevel42For2DVideo, .mpeg4AVCH264HighProfileLevel42For2DVideoFragmentable,
                       .mpeg4AVCH264HighProfileLevel42For3DVideo, .mpeg4AVCH264HighProfileLevel42For3DVideoFragmentable,
                       .mpeg4AVCH264StereoHighProfileLevel42, .mpeg4AVCH264StereoHighProfileLevel42Fragmentable,
                       .hevcH265MainProfileLevel51, .hevcH265Main10ProfileLevel51])
    ]
}
