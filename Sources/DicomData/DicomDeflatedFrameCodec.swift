import Foundation

/// Failures of the Deflated Image Frame Compression frame codec (PS3.5 Section 8.2.16 / Annex A.4.13).
public enum DicomDeflatedFrameError: Error, Equatable, Sendable, LocalizedError {
    /// Rows, Columns, Samples per Pixel or Bits Allocated do not describe a valid native frame.
    case invalidFrameShape
    /// The fragment is empty or shorter than the smallest DEFLATE stream.
    case emptyFragment
    /// zlib rejected the fragment before the end-of-stream marker.
    case inflateFailed(code: Int32)
    /// The inflated byte count differs from the native frame length declared by the Image Pixel attributes.
    case lengthMismatch(expected: Int, actual: Int)
    /// The stream would inflate past the declared frame length; nothing was written.
    case outputExceedsFrame(expected: Int)
    /// Bytes remain after the end-of-stream marker beyond the single NULL pad the standard allows.
    case trailingBytes(count: Int)
    case oddFragmentLength
    case deflateFailed(code: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidFrameShape:
            return "Rows, Columns, Samples per Pixel and Bits Allocated do not describe a valid native frame"
        case .emptyFragment:
            return "the fragment holds no DEFLATE stream"
        case .inflateFailed(let code):
            return "the DEFLATE stream is malformed (zlib \(code))"
        case .lengthMismatch(let expected, let actual):
            return "the fragment inflated to \(actual) bytes but the frame is \(expected) bytes"
        case .outputExceedsFrame(let expected):
            return "the fragment inflates past the \(expected)-byte frame"
        case .trailingBytes(let count):
            return "\(count) byte(s) follow the DEFLATE stream; only one NULL pad byte is allowed"
        case .oddFragmentLength:
            return "the encapsulated fragment has an odd length and requires a NULL pad"
        case .deflateFailed(let code):
            return "deflating the frame failed (zlib \(code))"
        }
    }
}

/// Deflated Image Frame Compression (`1.2.840.10008.1.2.8.1`): every frame is one raw DEFLATE stream
/// (RFC 1951, no zlib or gzip wrapper) in exactly one encapsulated fragment, padded with a single NULL
/// byte when the deflated length is odd. The codec is byte oriented: the frame bytes are the native
/// Pixel Data bytes of that frame at any Bits Allocated, Samples per Pixel and Planar Configuration.
/// Dataset deflate (`1.2.840.10008.1.2.1.99`) is a different mechanism handled by `DicomDeflatedDataSetCodec`.
public enum DicomDeflatedFrameCodec {
    /// Structural findings of one fragment, without materialising the frame.
    public struct Inspection: Equatable, Sendable {
        /// Bytes of the DEFLATE stream itself, without padding.
        public let streamByteCount: Int
        /// Inflated byte count (equals the expected frame length when the fragment is valid).
        public let inflatedByteCount: Int
        /// Bytes after the end-of-stream marker (0 or 1 for a conforming fragment).
        public let trailingByteCount: Int
        /// Whether the fragment length is even as the encapsulation rules require.
        public let fragmentLengthIsEven: Bool
    }

    /// Native byte length of one frame; nil when the attributes do not describe a valid native frame.
    public static func frameByteCount(rows: Int, columns: Int, samplesPerPixel: Int, bitsAllocated: Int,
                                      photometricInterpretation: String = "") -> Int? {
        guard rows > 0, columns > 0, samplesPerPixel > 0, bitsAllocated > 0 else { return nil }
        let subsampled = photometricInterpretation.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "YBR_FULL_422"
        if subsampled {
            guard samplesPerPixel == 3, columns.isMultiple(of: 2), bitsAllocated.isMultiple(of: 8) else { return nil }
        }
        let pixels = rows.multipliedReportingOverflow(by: columns)
        guard !pixels.overflow else { return nil }
        let samples = pixels.partialValue.multipliedReportingOverflow(by: subsampled ? 2 : samplesPerPixel)
        guard !samples.overflow else { return nil }
        let bits = samples.partialValue.multipliedReportingOverflow(by: bitsAllocated)
        guard !bits.overflow, bitsAllocated == 1 || bitsAllocated.isMultiple(of: 8) else { return nil }
        return bits.partialValue / 8 + (bits.partialValue.isMultiple(of: 8) ? 0 : 1)
    }

    /// Deflates the native bytes of one frame and applies the odd-length NULL pad.
    public static func encodeFrame(_ nativeFrame: Data) throws -> Data {
        var deflated: Data
        do {
            deflated = try DicomDeflatedDataSetCodec.deflate(nativeFrame)
        } catch DicomDeflatedDataSetError.deflateFailed(let code) {
            throw DicomDeflatedFrameError.deflateFailed(code: code)
        }
        if !deflated.count.isMultiple(of: 2) { deflated.append(0) }
        return deflated
    }

    /// Inflates one fragment to exactly `expectedByteCount` bytes. Output is bounded by the declared frame
    /// length before any byte is kept; a shorter or longer stream, a malformed stream or more than one
    /// trailing byte is a typed failure and no partial frame is returned.
    public static func decodeFrame(_ fragment: Data, expectedByteCount: Int) throws -> Data {
        let (frame, inspection) = try process(fragment, expectedByteCount: expectedByteCount)
        guard inspection.trailingByteCount <= 1 else {
            throw DicomDeflatedFrameError.trailingBytes(count: inspection.trailingByteCount)
        }
        guard inspection.fragmentLengthIsEven else { throw DicomDeflatedFrameError.oddFragmentLength }
        return frame
    }

    /// Inflates the fragment and reports its structure; the frame bytes are discarded.
    public static func inspect(_ fragment: Data, expectedByteCount: Int) throws -> Inspection {
        try process(fragment, expectedByteCount: expectedByteCount).inspection
    }

    private static func process(_ fragment: Data, expectedByteCount: Int) throws -> (frame: Data, inspection: Inspection) {
        guard expectedByteCount > 0 else { throw DicomDeflatedFrameError.invalidFrameShape }
        guard fragment.count >= 2 else { throw DicomDeflatedFrameError.emptyFragment }
        let inflated: (data: Data, consumedBytes: Int)
        do {
            inflated = try DicomDeflatedDataSetCodec.inflateReportingConsumedBytes(fragment, inflatedSizeLimit: expectedByteCount)
        } catch DicomDeflatedDataSetError.dataSetTooLarge {
            throw DicomDeflatedFrameError.outputExceedsFrame(expected: expectedByteCount)
        } catch DicomDeflatedDataSetError.inflateFailed(let code) {
            throw DicomDeflatedFrameError.inflateFailed(code: code)
        }
        guard inflated.data.count == expectedByteCount else {
            throw DicomDeflatedFrameError.lengthMismatch(expected: expectedByteCount, actual: inflated.data.count)
        }
        let inspection = Inspection(
            streamByteCount: inflated.consumedBytes,
            inflatedByteCount: inflated.data.count,
            trailingByteCount: fragment.count - inflated.consumedBytes,
            fragmentLengthIsEven: fragment.count.isMultiple(of: 2)
        )
        if inspection.trailingByteCount == 1, fragment.last != 0 {
            throw DicomDeflatedFrameError.trailingBytes(count: 1)
        }
        return (inflated.data, inspection)
    }
}
