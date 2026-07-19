import Foundation

public enum DicomTransferSyntaxCodec: String, Equatable, Sendable {
    case native
    case deflate
    case jpip
    case rle
    case jpegBaseline
    case jpegExtended
    case jpegLossless
    case jpegLS
    case jpeg2000
    case jpeg2000Part2
    case jpegXL
    case mpeg2
    case h264
    case hevc
    case htj2k
}

public enum DicomTransferSyntaxCompression: Equatable, Sendable {
    case none
    case lossless
    case lossy
    case nearLossless

    public var isLossy: Bool {
        switch self {
        case .lossy, .nearLossless:
            return true
        case .none, .lossless:
            return false
        }
    }
}

public enum DicomTransferSyntaxPixelEncoding: Equatable, Sendable {
    case native
    case encapsulated
    case referenced
}

public enum DicomTransferSyntaxFragmentation: Equatable, Sendable {
    case contiguousNative
    case encapsulatedFragments
    case referencedURL
}

public enum DicomCodecSupport: Equatable, Sendable {
    case supported
    case bestEffort(String)
    case unavailable(String)

    public var isSupported: Bool {
        if case .supported = self {
            return true
        }
        return false
    }
}

/// Explicit package behavior for a compressed or referenced pixel transfer syntax.
public enum DicomCompressedPixelSupportStatus: String, Codable, Equatable, Sendable {
    /// DicomCore decodes the compressed frame natively.
    case decoded

    /// DicomCore delegates decode to a platform or optional runtime backend.
    case delegated

    /// DicomCore exposes encoded or referenced data, but does not decode native frames.
    case streamedOnly = "streamed-only"

    /// DicomCore rejects native frame decode with a stable unsupported-transfer diagnostic.
    case unsupported

    /// DicomCore exposes a feature-gated codec route that has not completed clinical qualification.
    case experimental

    /// The syntax is compressed at the dataset level, not a compressed pixel codec.
    case outOfScope = "out-of-scope"
}

/// Support matrix row for a compressed, referenced, or video pixel transfer syntax.
public struct DicomCompressedPixelSupport: Equatable, Sendable {
    /// Transfer syntax covered by this row.
    public let syntax: DicomTransferSyntax

    /// DICOM transfer syntax name.
    public let name: String

    /// Codec family used by the transfer syntax.
    public let codec: DicomTransferSyntaxCodec

    /// Pixel support status.
    public let status: DicomCompressedPixelSupportStatus

    /// Stable diagnostic describing the backend or limitation.
    public let diagnostic: String

    /// Transfer syntax UID.
    public var uid: String {
        syntax.rawValue
    }

    /// Creates a compressed pixel support matrix row.
    public init(
        syntax: DicomTransferSyntax,
        name: String,
        codec: DicomTransferSyntaxCodec,
        status: DicomCompressedPixelSupportStatus,
        diagnostic: String
    ) {
        self.syntax = syntax
        self.name = name
        self.codec = codec
        self.status = status
        self.diagnostic = diagnostic
    }
}

/// Explicit package behavior for writing a dataset with a transfer syntax.
public enum DicomTransferSyntaxWriteStatus: String, Codable, Equatable, Sendable {
    /// DicomCore writes native uncompressed dataset elements directly.
    case nativeDataset = "native-dataset"

    /// DicomCore writes explicit VR little endian dataset elements and deflates the dataset payload.
    case deflatedDataset = "deflated-dataset"

    /// DicomCore preserves caller-provided encapsulated Pixel Data without encoding compressed frames.
    case encapsulatedPassThrough = "encapsulated-pass-through"

    /// DicomCore writes referenced pixel metadata without generating local pixel payloads.
    case referencedDataset = "referenced-dataset"

    /// DicomCore cannot write this transfer syntax.
    case unsupported
}

/// Support matrix row for writing a DICOM dataset with a transfer syntax.
public struct DicomTransferSyntaxWriteSupport: Equatable, Sendable {
    /// Transfer syntax covered by this row.
    public let syntax: DicomTransferSyntax

    /// DICOM transfer syntax name.
    public let name: String

    /// Codec family used by the transfer syntax.
    public let codec: DicomTransferSyntaxCodec

    /// Writer support status.
    public let status: DicomTransferSyntaxWriteStatus

    /// Encoder availability advertised by the registry.
    public let encoderSupport: DicomCodecSupport

    /// Stable diagnostic describing what the writer can and cannot do.
    public let diagnostic: String

    /// Transfer syntax UID.
    public var uid: String {
        syntax.rawValue
    }

    /// True when `DicomDataSetWriter` can write this syntax under the documented conditions.
    public var supportsFileWriting: Bool {
        status != .unsupported
    }

    /// True when writing requires an already encapsulated Pixel Data element.
    public var requiresEncapsulatedPixelData: Bool {
        status == .encapsulatedPassThrough
    }

    /// Creates a transfer syntax writer support matrix row.
    public init(
        syntax: DicomTransferSyntax,
        name: String,
        codec: DicomTransferSyntaxCodec,
        status: DicomTransferSyntaxWriteStatus,
        encoderSupport: DicomCodecSupport,
        diagnostic: String
    ) {
        self.syntax = syntax
        self.name = name
        self.codec = codec
        self.status = status
        self.encoderSupport = encoderSupport
        self.diagnostic = diagnostic
    }
}

public struct DicomTransferSyntaxRegistryEntry: Equatable, Sendable {
    public let syntax: DicomTransferSyntax
    public let name: String
    public let codec: DicomTransferSyntaxCodec
    public let compression: DicomTransferSyntaxCompression
    public let pixelEncoding: DicomTransferSyntaxPixelEncoding
    public let fragmentation: DicomTransferSyntaxFragmentation
    public let decoderSupport: DicomCodecSupport
    public let encoderSupport: DicomCodecSupport

    public init(
        syntax: DicomTransferSyntax,
        name: String,
        codec: DicomTransferSyntaxCodec,
        compression: DicomTransferSyntaxCompression,
        pixelEncoding: DicomTransferSyntaxPixelEncoding,
        fragmentation: DicomTransferSyntaxFragmentation,
        decoderSupport: DicomCodecSupport,
        encoderSupport: DicomCodecSupport
    ) {
        self.syntax = syntax
        self.name = name
        self.codec = codec
        self.compression = compression
        self.pixelEncoding = pixelEncoding
        self.fragmentation = fragmentation
        self.decoderSupport = decoderSupport
        self.encoderSupport = encoderSupport
    }

    public var uid: String {
        syntax.rawValue
    }

    public var isCompressed: Bool {
        compression != .none
    }

    public var isEncapsulated: Bool {
        pixelEncoding == .encapsulated
    }

    public var isLossy: Bool {
        compression.isLossy
    }

    public var isLossless: Bool {
        !compression.isLossy
    }

    public var supportsFragmentation: Bool {
        fragmentation == .encapsulatedFragments
    }
}

public enum DicomTranscodePlanStatus: Equatable, Sendable {
    case supported
    case ambiguous
    case unsupported
}

public enum DicomTranscodeRoute: Equatable, Sendable {
    case passThrough
    case rewriteNative
    case reference
    case decompress
    case compress
    case recompress
}

public enum DicomTranscodeDiagnosticSeverity: Equatable, Sendable {
    case info
    case warning
    case error
}

public struct DicomTranscodeDiagnostic: Equatable, Sendable {
    public let severity: DicomTranscodeDiagnosticSeverity
    public let message: String

    public init(severity: DicomTranscodeDiagnosticSeverity, message: String) {
        self.severity = severity
        self.message = message
    }
}

public struct DicomTranscodePlan: Equatable, Sendable {
    public let source: DicomTransferSyntaxRegistryEntry
    public let destination: DicomTransferSyntaxRegistryEntry
    public let route: DicomTranscodeRoute
    public let status: DicomTranscodePlanStatus
    public let diagnostics: [DicomTranscodeDiagnostic]

    public init(
        source: DicomTransferSyntaxRegistryEntry,
        destination: DicomTransferSyntaxRegistryEntry,
        route: DicomTranscodeRoute,
        status: DicomTranscodePlanStatus,
        diagnostics: [DicomTranscodeDiagnostic]
    ) {
        self.source = source
        self.destination = destination
        self.route = route
        self.status = status
        self.diagnostics = diagnostics
    }

    public var canTranscode: Bool {
        status == .supported
    }

    public var requiresDecompression: Bool {
        route == .decompress || route == .recompress
    }

    public var requiresCompression: Bool {
        route == .compress || route == .recompress
    }
}

public struct DicomTransferSyntaxRegistry: Sendable {
    public static let standard = DicomTransferSyntaxRegistry(entries: standardEntries)

    public let entries: [DicomTransferSyntaxRegistryEntry]
    private let entriesBySyntax: [DicomTransferSyntax: DicomTransferSyntaxRegistryEntry]

    public init(entries: [DicomTransferSyntaxRegistryEntry]) {
        self.entries = entries
        self.entriesBySyntax = Dictionary(uniqueKeysWithValues: entries.map { ($0.syntax, $0) })
    }

    public func entry(for syntax: DicomTransferSyntax) -> DicomTransferSyntaxRegistryEntry? {
        entriesBySyntax[syntax]
    }

    public func entry(forUID uid: String) -> DicomTransferSyntaxRegistryEntry? {
        guard let syntax = DicomTransferSyntax(uid: uid) else { return nil }
        return entry(for: syntax)
    }

    /// Matrix of compressed, referenced, and video pixel transfer syntax behavior.
    public var compressedPixelSupportMatrix: [DicomCompressedPixelSupport] {
        entries.compactMap(DicomCompressedPixelSupport.init(entry:))
    }

    /// Returns the compressed pixel support row for a transfer syntax, if applicable.
    public func compressedPixelSupport(for syntax: DicomTransferSyntax) -> DicomCompressedPixelSupport? {
        guard let entry = entry(for: syntax) else { return nil }
        return DicomCompressedPixelSupport(entry: entry)
    }

    /// Matrix of dataset and Part 10 file writing behavior for every transfer syntax.
    public var writeSupportMatrix: [DicomTransferSyntaxWriteSupport] {
        entries.map(DicomTransferSyntaxWriteSupport.init(entry:))
    }

    /// Returns the writer support row for a transfer syntax.
    public func writeSupport(for syntax: DicomTransferSyntax) -> DicomTransferSyntaxWriteSupport? {
        guard let entry = entry(for: syntax) else { return nil }
        return DicomTransferSyntaxWriteSupport(entry: entry)
    }

    public func canTranscode(from source: DicomTransferSyntax, to destination: DicomTransferSyntax) -> Bool {
        transcodePlan(from: source, to: destination).canTranscode
    }

    public func transcodePlan(from source: DicomTransferSyntax, to destination: DicomTransferSyntax) -> DicomTranscodePlan {
        guard let sourceEntry = entry(for: source), let destinationEntry = entry(for: destination) else {
            preconditionFailure("DicomTransferSyntaxRegistry.standard must cover every DicomTransferSyntax case.")
        }

        if source == destination {
            return DicomTranscodePlan(
                source: sourceEntry,
                destination: destinationEntry,
                route: .passThrough,
                status: .supported,
                diagnostics: [
                    DicomTranscodeDiagnostic(
                        severity: .info,
                        message: "Source and destination transfer syntaxes are identical; no transcode is required."
                    )
                ]
            )
        }

        if sourceEntry.pixelEncoding == .referenced || destinationEntry.pixelEncoding == .referenced {
            return DicomTranscodePlan(
                source: sourceEntry,
                destination: destinationEntry,
                route: .reference,
                status: .unsupported,
                diagnostics: [
                    DicomTranscodeDiagnostic(
                        severity: .error,
                        message: "JPIP referenced transfer syntaxes use Pixel Data Provider URL and are not converted by the local pixel transcode planner."
                    )
                ]
            )
        }

        if !sourceEntry.isCompressed && !destinationEntry.isCompressed {
            return DicomTranscodePlan(
                source: sourceEntry,
                destination: destinationEntry,
                route: .rewriteNative,
                status: .supported,
                diagnostics: [
                    DicomTranscodeDiagnostic(
                        severity: .info,
                        message: "Native uncompressed transfer syntax rewrite is supported."
                    )
                ]
            )
        }

        if sourceEntry.isCompressed && !destinationEntry.isCompressed {
            return makePlan(
                source: sourceEntry,
                destination: destinationEntry,
                route: .decompress,
                requirements: [
                    codecRequirement(.decoder, sourceEntry.decoderSupport, syntaxName: sourceEntry.name),
                    codecRequirement(.encoder, destinationEntry.encoderSupport, syntaxName: destinationEntry.name)
                ]
            )
        }

        if !sourceEntry.isCompressed && destinationEntry.isCompressed {
            return makePlan(
                source: sourceEntry,
                destination: destinationEntry,
                route: .compress,
                requirements: [
                    codecRequirement(.encoder, destinationEntry.encoderSupport, syntaxName: destinationEntry.name)
                ]
            )
        }

        return makePlan(
            source: sourceEntry,
            destination: destinationEntry,
            route: .recompress,
            requirements: [
                codecRequirement(.decoder, sourceEntry.decoderSupport, syntaxName: sourceEntry.name),
                codecRequirement(.encoder, destinationEntry.encoderSupport, syntaxName: destinationEntry.name)
            ]
        )
    }
}

public extension DicomTransferSyntax {
    var registryEntry: DicomTransferSyntaxRegistryEntry {
        guard let entry = DicomTransferSyntaxRegistry.standard.entry(for: self) else {
            preconditionFailure("DicomTransferSyntaxRegistry.standard must cover every DicomTransferSyntax case.")
        }
        return entry
    }

    var isEncapsulated: Bool {
        registryEntry.isEncapsulated
    }

    var isLossy: Bool {
        registryEntry.isLossy
    }

    var isLossless: Bool {
        registryEntry.isLossless
    }

    var decoderSupport: DicomCodecSupport {
        registryEntry.decoderSupport
    }

    var encoderSupport: DicomCodecSupport {
        registryEntry.encoderSupport
    }

    /// Compressed pixel support matrix row for this transfer syntax, if applicable.
    var compressedPixelSupport: DicomCompressedPixelSupport? {
        DicomTransferSyntaxRegistry.standard.compressedPixelSupport(for: self)
    }

    /// Dataset and Part 10 file writing support row for this transfer syntax.
    var writeSupport: DicomTransferSyntaxWriteSupport {
        guard let support = DicomTransferSyntaxRegistry.standard.writeSupport(for: self) else {
            preconditionFailure("DicomTransferSyntaxRegistry.standard must cover every DicomTransferSyntax case.")
        }
        return support
    }

    static func canTranscode(from source: DicomTransferSyntax, to destination: DicomTransferSyntax) -> Bool {
        DicomTransferSyntaxRegistry.standard.canTranscode(from: source, to: destination)
    }

    static func transcodePlan(from source: DicomTransferSyntax, to destination: DicomTransferSyntax) -> DicomTranscodePlan {
        DicomTransferSyntaxRegistry.standard.transcodePlan(from: source, to: destination)
    }
}

private enum CodecRequirementKind {
    case decoder
    case encoder

    var label: String {
        switch self {
        case .decoder:
            return "Decoder"
        case .encoder:
            return "Encoder"
        }
    }
}

private struct CodecRequirement {
    let kind: CodecRequirementKind
    let support: DicomCodecSupport
    let syntaxName: String
}

private extension DicomTransferSyntaxWriteSupport {
    init(entry: DicomTransferSyntaxRegistryEntry) {
        self.init(
            syntax: entry.syntax,
            name: entry.name,
            codec: entry.codec,
            status: Self.status(for: entry),
            encoderSupport: entry.encoderSupport,
            diagnostic: Self.diagnostic(for: entry)
        )
    }

    static func status(for entry: DicomTransferSyntaxRegistryEntry) -> DicomTransferSyntaxWriteStatus {
        if entry.syntax.usesDataSetDeflate && entry.pixelEncoding == .native {
            return .deflatedDataset
        }

        switch entry.pixelEncoding {
        case .native:
            return .nativeDataset
        case .encapsulated:
            return .encapsulatedPassThrough
        case .referenced:
            return .referencedDataset
        }
    }

    static func diagnostic(for entry: DicomTransferSyntaxRegistryEntry) -> String {
        switch status(for: entry) {
        case .nativeDataset:
            return "DicomDataSetWriter serializes native uncompressed dataset elements directly; "
                + "it does not preserve encapsulated compressed Pixel Data as native pixels."
        case .deflatedDataset:
            return "DicomDataSetWriter serializes explicit VR little endian dataset elements and "
                + "deflates the dataset payload with zlib; this is dataset compression, not pixel recompression."
        case .encapsulatedPassThrough:
            return "DicomDataSetWriter does not encode compressed frames; it preserves already encapsulated "
                + "Pixel Data for this transfer syntax and rejects native pixels."
        case .referencedDataset:
            return "DicomDataSetWriter serializes referenced pixel metadata and Pixel Data Provider URL; "
                + "it does not generate JPIP transport payloads or rewrite local Pixel Data."
        case .unsupported:
            return "DicomDataSetWriter cannot write this transfer syntax."
        }
    }
}

private extension DicomCompressedPixelSupport {
    init?(entry: DicomTransferSyntaxRegistryEntry) {
        guard entry.isCompressed || entry.pixelEncoding == .referenced else {
            return nil
        }

        self.init(
            syntax: entry.syntax,
            name: entry.name,
            codec: entry.codec,
            status: Self.status(for: entry),
            diagnostic: Self.diagnostic(for: entry)
        )
    }

    static func status(for entry: DicomTransferSyntaxRegistryEntry) -> DicomCompressedPixelSupportStatus {
        switch entry.codec {
        case .deflate:
            return .outOfScope
        case .jpegLossless, .rle, .jpegExtended:
            return .decoded
        case .jpegBaseline, .jpegLS, .jpeg2000, .jpeg2000Part2:
            return .delegated
        case .jpegXL:
            return .experimental
        case .jpip, .mpeg2, .h264, .hevc:
            return .streamedOnly
        case .htj2k:
            return .delegated
        case .native:
            return .outOfScope
        }
    }

    static func diagnostic(for entry: DicomTransferSyntaxRegistryEntry) -> String {
        switch entry.codec {
        case .deflate:
            return "Dataset deflate is handled by DicomDeflatedDataSetCodec; "
                + "it is not a compressed pixel codec."
        case .jpegLossless:
            return "Decoded natively by JPEGLosslessDecoder, including restart "
                + "intervals and 8-bit interleaved RGB frames; other color shapes "
                + "are rejected with stable diagnostics."
        case .rle:
            return "Decoded natively by DicomRLELosslessDecoder."
        case .jpegBaseline:
            return "Delegated to ImageIO for platform-supported 8-bit JPEG Baseline frames."
        case .jpegExtended:
            return "12-bit grayscale frames are decoded natively by JPEGExtendedDecoder "
                + "without precision loss; <=8-bit frames stay delegated to ImageIO."
        case .jpegLS:
            return "Delegated to the preflighted CharLS runtime when "
                + "DicomCodecRuntimePreflight reports it available."
        case .jpeg2000:
            return "Delegated to the preflighted OpenJPEG runtime up to 16-bit "
                + "grayscale; ImageIO fallback is limited to 8-bit frames."
        case .jpeg2000Part2:
            return "Delegated to DicomJP3DVolumeDocument with the preflighted "
                + "OpenJPEG runtime for volume buffers."
        case .jpip:
            return "Metadata and Pixel Data Provider URL are parsed; "
                + "progressive frame data is streamed through caller-provided transport."
        case .mpeg2, .h264, .hevc:
            return "Encoded video payload is exposed for a player backend; "
                + "DicomCore does not decode native video frames."
        case .htj2k:
            return "Delegated to the preflighted OpenJPEG runtime only when it "
                + "includes the HTJ2K block decoder (version 2.5 or newer); "
                + "ImageIO JPEG 2000 fallback is never used for HTJ2K."
        case .jpegXL:
            return "Experimental JXLSwift route; disabled by default and never negotiated over DIMSE "
                + "without an explicit caller policy."
        case .native:
            return "Native uncompressed transfer syntax is outside the compressed pixel codec matrix."
        }
    }
}

private extension DicomTransferSyntaxRegistry {
    static let standardEntries: [DicomTransferSyntaxRegistryEntry] = [
        native(.implicitVRLittleEndian, name: "Implicit VR Little Endian"),
        native(.explicitVRLittleEndian, name: "Explicit VR Little Endian"),
        DicomTransferSyntaxRegistryEntry(
            syntax: .deflatedExplicitVRLittleEndian,
            name: "Deflated Explicit VR Little Endian",
            codec: .deflate,
            compression: .lossless,
            pixelEncoding: .native,
            fragmentation: .contiguousNative,
            decoderSupport: .supported,
            encoderSupport: .supported
        ),
        native(.explicitVRBigEndian, name: "Explicit VR Big Endian"),
        compressed(
            .jpegBaseline,
            name: "JPEG Baseline (Process 1)",
            codec: .jpegBaseline,
            compression: .lossy,
            decoderSupport: .bestEffort("Explicit ImageIO backend is limited to platform-supported single-frame 8-bit payloads.")
        ),
        compressed(
            .jpegExtended,
            name: "JPEG Extended (Process 2 and 4)",
            codec: .jpegExtended,
            compression: .lossy,
            decoderSupport: .bestEffort("12-bit grayscale payloads decode natively with preserved precision; <=8-bit payloads use the platform ImageIO backend.")
        ),
        compressed(
            .jpegLossless,
            name: "JPEG Lossless, Non-Hierarchical (Process 14)",
            codec: .jpegLossless,
            compression: .lossless,
            decoderSupport: .supported
        ),
        compressed(
            .jpegLosslessFirstOrder,
            name: "JPEG Lossless, Non-Hierarchical, First-Order Prediction",
            codec: .jpegLossless,
            compression: .lossless,
            decoderSupport: .supported
        ),
        compressed(
            .jpegLSLossless,
            name: "JPEG-LS Lossless Image Compression",
            codec: .jpegLS,
            compression: .lossless,
            decoderSupport: .bestEffort("Native JPEG-LS decoding uses the CharLS runtime library when it is available."),
            encoderSupport: .bestEffort("JPEG-LS lossless encoding is executable through DicomTranscoder when the preflighted CharLS runtime is available.")
        ),
        compressed(
            .jpegLSNearLossless,
            name: "JPEG-LS Lossy Near-Lossless Image Compression",
            codec: .jpegLS,
            compression: .nearLossless,
            decoderSupport: .bestEffort("Native JPEG-LS near-lossless decoding uses the CharLS runtime library when it is available.")
        ),
        compressed(
            .jpeg2000Lossless,
            name: "JPEG 2000 Image Compression (Lossless Only)",
            codec: .jpeg2000,
            compression: .lossless,
            decoderSupport: .bestEffort("Explicit OpenJPEG backend decodes single-frame JPEG 2000 up to 16-bit grayscale when the runtime library is available; ImageIO is limited to 8-bit fallback."),
            encoderSupport: .bestEffort("J2KSwift CPU encoding is executable through the async DicomTranscoder route.")
        ),
        compressed(
            .jpeg2000,
            name: "JPEG 2000 Image Compression",
            codec: .jpeg2000,
            compression: .lossy,
            decoderSupport: .bestEffort("Explicit OpenJPEG backend decodes single-frame JPEG 2000 up to 16-bit grayscale when the runtime library is available; ImageIO is limited to 8-bit fallback."),
            encoderSupport: .bestEffort("J2KSwift CPU encoding is executable through the async DicomTranscoder route.")
        ),
        compressed(
            .jpeg2000Part2MulticomponentLossless,
            name: "JPEG 2000 Part 2 Multi-component Image Compression (Lossless Only)",
            codec: .jpeg2000Part2,
            compression: .lossless,
            decoderSupport: .bestEffort("Explicit OpenJPEG backend decodes multi-component volume codestreams into 16-bit DicomSeriesVolume buffers when the runtime library is available.")
        ),
        compressed(
            .jpeg2000Part2Multicomponent,
            name: "JPEG 2000 Part 2 Multi-component Image Compression",
            codec: .jpeg2000Part2,
            compression: .lossy,
            decoderSupport: .bestEffort("Explicit OpenJPEG backend decodes multi-component volume codestreams into 16-bit DicomSeriesVolume buffers when the runtime library is available.")
        ),
        referenced(
            .jpipReferenced,
            name: "DICOM JPIP Referenced Transfer Syntax",
            compression: .none,
            decoderSupport: .bestEffort("Metadata parsing exposes Pixel Data Provider URL; progressive pixel data requires an injected JPIP transport.")
        ),
        referenced(
            .jpipReferencedDeflate,
            name: "DICOM JPIP Referenced Deflate Transfer Syntax",
            compression: .lossless,
            decoderSupport: .bestEffort("Metadata parsing inflates the dataset and exposes Pixel Data Provider URL; progressive pixel data requires an injected JPIP transport.")
        ),
        video(
            .mpeg2MainProfileMainLevel,
            name: "MPEG2 Main Profile / Main Level",
            codec: .mpeg2
        ),
        video(
            .mpeg2MainProfileMainLevelFragmentable,
            name: "Fragmentable MPEG2 Main Profile / Main Level",
            codec: .mpeg2
        ),
        video(
            .mpeg2MainProfileHighLevel,
            name: "MPEG2 Main Profile / High Level",
            codec: .mpeg2
        ),
        video(
            .mpeg2MainProfileHighLevelFragmentable,
            name: "Fragmentable MPEG2 Main Profile / High Level",
            codec: .mpeg2
        ),
        video(
            .mpeg4AVCH264HighProfileLevel41,
            name: "MPEG-4 AVC/H.264 High Profile / Level 4.1",
            codec: .h264
        ),
        video(
            .mpeg4AVCH264HighProfileLevel41Fragmentable,
            name: "Fragmentable MPEG-4 AVC/H.264 High Profile / Level 4.1",
            codec: .h264
        ),
        video(
            .mpeg4AVCH264BDCompatibleHighProfileLevel41,
            name: "MPEG-4 AVC/H.264 BD-compatible High Profile / Level 4.1",
            codec: .h264
        ),
        video(
            .mpeg4AVCH264BDCompatibleHighProfileLevel41Fragmentable,
            name: "Fragmentable MPEG-4 AVC/H.264 BD-compatible High Profile / Level 4.1",
            codec: .h264
        ),
        video(
            .mpeg4AVCH264HighProfileLevel42For2DVideo,
            name: "MPEG-4 AVC/H.264 High Profile / Level 4.2 For 2D Video",
            codec: .h264
        ),
        video(
            .mpeg4AVCH264HighProfileLevel42For2DVideoFragmentable,
            name: "Fragmentable MPEG-4 AVC/H.264 High Profile / Level 4.2 For 2D Video",
            codec: .h264
        ),
        video(
            .mpeg4AVCH264HighProfileLevel42For3DVideo,
            name: "MPEG-4 AVC/H.264 High Profile / Level 4.2 For 3D Video",
            codec: .h264
        ),
        video(
            .mpeg4AVCH264HighProfileLevel42For3DVideoFragmentable,
            name: "Fragmentable MPEG-4 AVC/H.264 High Profile / Level 4.2 For 3D Video",
            codec: .h264
        ),
        video(
            .mpeg4AVCH264StereoHighProfileLevel42,
            name: "MPEG-4 AVC/H.264 Stereo High Profile / Level 4.2",
            codec: .h264
        ),
        video(
            .mpeg4AVCH264StereoHighProfileLevel42Fragmentable,
            name: "Fragmentable MPEG-4 AVC/H.264 Stereo High Profile / Level 4.2",
            codec: .h264
        ),
        video(
            .hevcH265MainProfileLevel51,
            name: "HEVC/H.265 Main Profile / Level 5.1",
            codec: .hevc
        ),
        video(
            .hevcH265Main10ProfileLevel51,
            name: "HEVC/H.265 Main 10 Profile / Level 5.1",
            codec: .hevc
        ),
        compressed(
            .jpegXLLossless,
            name: "JPEG XL Lossless",
            codec: .jpegXL,
            compression: .lossless,
            decoderSupport: .bestEffort("Experimental JXLSwift route is disabled unless DICOM_JXLSWIFT_MODE=experimental."),
            encoderSupport: .bestEffort("Experimental JXLSwift route is executable only through the async DicomTranscoder API with explicit intent.")
        ),
        compressed(
            .jpegXLJPEGRecompression,
            name: "JPEG XL JPEG Recompression",
            codec: .jpegXL,
            compression: .lossless,
            decoderSupport: .bestEffort("Experimental JXLSwift route reconstructs qualified JPEG Baseline frames byte-for-byte when explicitly enabled."),
            encoderSupport: .bestEffort("Experimental JXLSwift route accepts qualified JPEG Baseline 8-bit frames only.")
        ),
        compressed(
            .jpegXL,
            name: "JPEG XL",
            codec: .jpegXL,
            compression: .lossy,
            decoderSupport: .bestEffort("Experimental JXLSwift route is disabled unless DICOM_JXLSWIFT_MODE=experimental."),
            encoderSupport: .bestEffort("Experimental JXLSwift route is executable only through the async DicomTranscoder API with explicit reversible or irreversible intent.")
        ),
        compressed(
            .htj2kLossless,
            name: "HTJ2K Image Compression (Lossless Only)",
            codec: .htj2k,
            compression: .lossless,
            decoderSupport: .bestEffort("HTJ2K decoding requires the preflighted OpenJPEG runtime version 2.5 or newer (HT block decoder); ImageIO JPEG 2000 fallback is not used."),
            encoderSupport: .bestEffort("Conformant J2KSwift CPU encoding is executable through the async DicomTranscoder route.")
        ),
        compressed(
            .htj2kLosslessRPCL,
            name: "HTJ2K Image Compression (Lossless RPCL)",
            codec: .htj2k,
            compression: .lossless,
            decoderSupport: .bestEffort("HTJ2K RPCL decoding requires the preflighted OpenJPEG runtime version 2.5 or newer (HT block decoder); ImageIO JPEG 2000 fallback is not used."),
            encoderSupport: .bestEffort("Conformant J2KSwift CPU RPCL encoding is executable through the async DicomTranscoder route.")
        ),
        compressed(
            .htj2k,
            name: "HTJ2K Image Compression",
            codec: .htj2k,
            compression: .lossy,
            decoderSupport: .bestEffort("HTJ2K decoding requires the preflighted OpenJPEG runtime version 2.5 or newer (HT block decoder); ImageIO JPEG 2000 fallback is not used."),
            encoderSupport: .bestEffort("Conformant J2KSwift CPU encoding is executable through the async DicomTranscoder route.")
        ),
        compressed(
            .rleLossless,
            name: "RLE Lossless",
            codec: .rle,
            compression: .lossless,
            decoderSupport: .supported
        )
    ]

    static func native(_ syntax: DicomTransferSyntax, name: String) -> DicomTransferSyntaxRegistryEntry {
        DicomTransferSyntaxRegistryEntry(
            syntax: syntax,
            name: name,
            codec: .native,
            compression: .none,
            pixelEncoding: .native,
            fragmentation: .contiguousNative,
            decoderSupport: .supported,
            encoderSupport: .supported
        )
    }

    static func compressed(
        _ syntax: DicomTransferSyntax,
        name: String,
        codec: DicomTransferSyntaxCodec,
        compression: DicomTransferSyntaxCompression,
        decoderSupport: DicomCodecSupport,
        encoderSupport: DicomCodecSupport? = nil
    ) -> DicomTransferSyntaxRegistryEntry {
        DicomTransferSyntaxRegistryEntry(
            syntax: syntax,
            name: name,
            codec: codec,
            compression: compression,
            pixelEncoding: .encapsulated,
            fragmentation: .encapsulatedFragments,
            decoderSupport: decoderSupport,
            encoderSupport: encoderSupport ?? .unavailable("DICOM \(name) encoder is not implemented.")
        )
    }

    static func video(
        _ syntax: DicomTransferSyntax,
        name: String,
        codec: DicomTransferSyntaxCodec
    ) -> DicomTransferSyntaxRegistryEntry {
        DicomTransferSyntaxRegistryEntry(
            syntax: syntax,
            name: name,
            codec: codec,
            compression: .lossy,
            pixelEncoding: .encapsulated,
            fragmentation: .encapsulatedFragments,
            decoderSupport: .bestEffort("Encoded video stream is exposed as encapsulated Pixel Data for a player backend; native frame decode is not implemented."),
            encoderSupport: .bestEffort("Video builders can encapsulate caller-provided bitstreams; video encoding is not implemented.")
        )
    }

    static func referenced(
        _ syntax: DicomTransferSyntax,
        name: String,
        compression: DicomTransferSyntaxCompression,
        decoderSupport: DicomCodecSupport
    ) -> DicomTransferSyntaxRegistryEntry {
        DicomTransferSyntaxRegistryEntry(
            syntax: syntax,
            name: name,
            codec: .jpip,
            compression: compression,
            pixelEncoding: .referenced,
            fragmentation: .referencedURL,
            decoderSupport: decoderSupport,
            encoderSupport: .unavailable("DICOM \(name) encoder requires a JPIP pixel data provider.")
        )
    }

    func makePlan(
        source: DicomTransferSyntaxRegistryEntry,
        destination: DicomTransferSyntaxRegistryEntry,
        route: DicomTranscodeRoute,
        requirements: [CodecRequirement]
    ) -> DicomTranscodePlan {
        let diagnostics = requirements.map(diagnostic(for:))
        return DicomTranscodePlan(
            source: source,
            destination: destination,
            route: route,
            status: status(for: diagnostics),
            diagnostics: diagnostics
        )
    }

    func codecRequirement(
        _ kind: CodecRequirementKind,
        _ support: DicomCodecSupport,
        syntaxName: String
    ) -> CodecRequirement {
        CodecRequirement(kind: kind, support: support, syntaxName: syntaxName)
    }

    func diagnostic(for requirement: CodecRequirement) -> DicomTranscodeDiagnostic {
        switch requirement.support {
        case .supported:
            return DicomTranscodeDiagnostic(
                severity: .info,
                message: "\(requirement.kind.label) for \(requirement.syntaxName) is available."
            )
        case .bestEffort(let reason):
            return DicomTranscodeDiagnostic(
                severity: .warning,
                message: "\(requirement.kind.label) for \(requirement.syntaxName) is best-effort: \(reason)"
            )
        case .unavailable(let reason):
            return DicomTranscodeDiagnostic(
                severity: .error,
                message: "\(requirement.kind.label) for \(requirement.syntaxName) is unavailable: \(reason)"
            )
        }
    }

    func status(for diagnostics: [DicomTranscodeDiagnostic]) -> DicomTranscodePlanStatus {
        if diagnostics.contains(where: { $0.severity == .error }) {
            return .unsupported
        }
        if diagnostics.contains(where: { $0.severity == .warning }) {
            return .ambiguous
        }
        return .supported
    }
}
