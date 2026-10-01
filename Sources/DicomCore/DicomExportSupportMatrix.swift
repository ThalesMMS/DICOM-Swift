import Foundation

/// One row in the export and non-image object support matrix.
public struct DicomExportSupportRow: Equatable, Sendable {
    /// Feature or object family covered by the row.
    public var feature: String
    /// Supported IODs, SOP classes, or helper APIs.
    public var supportedIODs: String
    /// Required tags or required caller-provided values.
    public var requiredTags: String
    /// Supported transfer syntaxes for the row.
    public var transferSyntaxes: String
    /// Pixel, waveform, video, or print payload rules.
    public var payloadRules: String
    /// Metadata that is preserved or caller-owned.
    public var metadataPreservation: String
    /// Known unsupported cases.
    public var unsupportedCases: String
    /// Error type or stable diagnostic used for unsupported paths.
    public var typedFailure: String

    public init(feature: String,
                supportedIODs: String,
                requiredTags: String,
                transferSyntaxes: String,
                payloadRules: String,
                metadataPreservation: String,
                unsupportedCases: String,
                typedFailure: String) {
        self.feature = feature
        self.supportedIODs = supportedIODs
        self.requiredTags = requiredTags
        self.transferSyntaxes = transferSyntaxes
        self.payloadRules = payloadRules
        self.metadataPreservation = metadataPreservation
        self.unsupportedCases = unsupportedCases
        self.typedFailure = typedFailure
    }
}

/// Explicit package support matrix for export, Secondary Capture, print, waveform, and video helpers.
public struct DicomExportSupportMatrix: Equatable, Sendable {
    /// Ordered support rows.
    public var rows: [DicomExportSupportRow]

    public init(rows: [DicomExportSupportRow]) {
        self.rows = rows
    }

    /// Default package matrix used by docs and tests.
    public static let packageDefault = DicomExportSupportMatrix(rows: [
        DicomExportSupportRow(
            feature: "Image export",
            supportedIODs: "Native pixel-bearing image instances through DCMDecoder and DicomImageExporter",
            requiredTags: "Pixel Data, Rows, Columns, Samples per Pixel, Photometric Interpretation, "
                + "Bits Allocated, Bits Stored, High Bit, Pixel Representation",
            transferSyntaxes: "Native uncompressed Part 10 datasets addressable by DicomPixelDataDescriptor",
            payloadRules: "display8 exports PNG/JPEG/TIFF with resize and annotation burn-in; "
                + "native16Bit exports unsigned single-sample TIFF only",
            metadataPreservation: "Optional non-PHI sidecars preserve frame number, modality, dimensions, "
                + "windowing, spacing, and transfer syntax context",
            unsupportedCases: "Native 16-bit RGB, signed native16Bit TIFF, resize/annotations in "
                + "native16Bit mode, compressed/video/referenced pixel export",
            typedFailure: "DicomImageExportError.unsupportedPixelMode or invalidPixelData"
        ),
        DicomExportSupportRow(
            feature: "Secondary Capture",
            supportedIODs: "Secondary Capture Image Storage synthetic snapshots",
            requiredTags: "Clinical export validation requires SOP Instance UID, Study Instance UID, "
                + "Series Instance UID, Patient Name, Patient ID, Study ID, Study Date, "
                + "Series Number, Instance Number, and the Image Pixel module",
            transferSyntaxes: "Explicit VR Little Endian Part 10 with native uncompressed Pixel Data",
            payloadRules: "8/16-bit unsigned MONOCHROME2 or 8-bit interleaved RGB with planar configuration 0",
            metadataPreservation: "Patient, study, series, instance, device, derivation, and "
                + "source image references are preserved when supplied",
            unsupportedCases: "Signed stored pixels, planar RGB, non-RGB three-sample payloads, "
                + "unsupported bit depths, missing clinical context in strict export validation",
            typedFailure: "DicomSecondaryCaptureError.missingRequiredMetadata or unsupportedPixelLayout"
        ),
        DicomExportSupportRow(
            feature: "Print management",
            supportedIODs: "Basic Grayscale and Color Print Management Meta SOP Classes with Basic Film "
                + "Session, Basic Film Box, matching Image Box, Basic Annotation Box, and Printer",
            requiredTags: "Film session copy/priority/medium/destination, film box layout/orientation/size, "
                + "image box position, and grayscale or RGB 8-bit image pixel attributes",
            transferSyntaxes: "Negotiated DIMSE presentation context, defaulting to Explicit VR Little Endian when absent",
            payloadRules: "Grayscale jobs send 8-bit MONOCHROME2; color jobs send interleaved RGB8 with "
                + "Planar Configuration 0; automatic mode prefers color and falls back to grayscale",
            metadataPreservation: "Film session label, film box display settings, queue status, and "
                + "returned image box SOP Instance UIDs are preserved",
            unsupportedCases: "Presentation LUT, Printer Configuration, Print Job monitoring, "
                + "storage commitment, and film boxes for "
                + "which the printer grants fewer image boxes than the job requested",
            typedFailure: "DicomPrintManagementError.unsupportedService or "
                + "printModeNotNegotiated(_:) or insufficientImageBoxes(requested:granted:)"
        ),
        DicomExportSupportRow(
            feature: "Waveform",
            supportedIODs: "12-lead ECG, General ECG, Ambulatory ECG, General 32-bit ECG, Hemodynamic, "
                + "Cardiac Electrophysiology, Arterial Pulse, Respiratory, Routine Scalp EEG, EMG, EOG, "
                + "Sleep EEG, Basic Voice Audio, and General Audio Waveform Storage",
            requiredTags: "Waveform Sequence, Number of Channels, Number of Samples, Sampling Frequency, "
                + "Channel Definition Sequence, Waveform Bits Allocated, Waveform Sample Interpretation, "
                + "and Waveform Data",
            transferSyntaxes: "Native dataset and Part 10 writing through DicomDataSetWriter; "
                + "compressed waveform encodings are not implemented",
            payloadRules: "SB, UB, SS, US, SL, UL, MB, and AB samples are interleaved by sample then channel with range checks",
            metadataPreservation: "Channel labels, source concepts, units, sensitivity, filters, "
                + "timing offsets, and source waveform references are preserved",
            unsupportedCases: "Float/double samples, vendor-specific packed encodings, "
                + "inconsistent channel sample counts, and malformed payload lengths",
            typedFailure: "DicomWaveformError.unsupportedSampleInterpretation, sampleOutOfRange, or invalidWaveformData"
        ),
        DicomExportSupportRow(
            feature: "Video",
            supportedIODs: "Video Endoscopic, Video Microscopic, and Video Photographic Image Storage",
            requiredTags: "SOP Class UID, Rows, Columns, Number of Frames, timing metadata when available, "
                + "transfer syntax UID, and encapsulated Pixel Data",
            transferSyntaxes: "MPEG-2, MPEG-4 AVC/H.264, and HEVC/H.265 DICOM video transfer syntaxes",
            payloadRules: "Encoded streams and indexed encoded frame fragments are preserved for "
                + "caller/player handoff; native frame decode and video encoding are not implemented",
            metadataPreservation: "Codec, timing, frame rate, duration, source references, "
                + "lossy compression method, and raw stream bytes are preserved",
            unsupportedCases: "Non-video transfer syntaxes, native video frame decoding, video transcoding, "
                + "and server-side DICOMweb rendered frames",
            typedFailure: "DicomVideoError.unsupportedTransferSyntax, nativeFrameDecodeUnsupported, "
                + "transcodingUnsupported, or DICOMWEB_RENDERED_FRAME_UNSUPPORTED"
        )
    ])

    /// Returns the row with the requested feature name, ignoring case.
    public func row(feature: String) -> DicomExportSupportRow? {
        rows.first { $0.feature.caseInsensitiveCompare(feature) == .orderedSame }
    }

    /// Markdown table representation used by conformance documentation.
    public var markdown: String {
        var lines = [
            "| Feature | Supported IODs | Required Tags | Transfer Syntaxes | "
                + "Payload Rules | Metadata Preservation | Unsupported Cases | Typed Failure |",
            "| --- | --- | --- | --- | --- | --- | --- | --- |"
        ]
        lines += rows.map { row in
            "| \(row.feature) | \(row.supportedIODs) | \(row.requiredTags) | "
                + "\(row.transferSyntaxes) | \(row.payloadRules) | \(row.metadataPreservation) | "
                + "\(row.unsupportedCases) | \(row.typedFailure) |"
        }
        return lines.joined(separator: "\n")
    }
}
