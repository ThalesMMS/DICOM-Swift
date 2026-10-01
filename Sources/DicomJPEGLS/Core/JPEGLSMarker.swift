// Modified for Isis from JLSwift 299b9a2 (Apache-2.0); the modifications are recorded in Git.

/// JPEG-LS marker segment types per ISO/IEC 14495-1:1999 / ITU-T.87
///
/// Markers are two-byte codes that identify different segments in a JPEG-LS bitstream.
/// All markers start with 0xFF followed by a specific marker code.

import Foundation

/// JPEG-LS marker codes
///
/// These markers define the structure of JPEG-LS encoded data streams.
/// Each marker serves a specific purpose in the encoding/decoding process.
public enum JPEGLSMarker: UInt8, Sendable {
    // MARK: - Start and End Markers

    /// Start of Image (SOI) - marks the beginning of a JPEG-LS stream
    case startOfImage = 0xD8

    /// End of Image (EOI) - marks the end of a JPEG-LS stream
    case endOfImage = 0xD9

    // MARK: - Frame Markers

    /// Start of Frame for JPEG-LS (SOF55)
    /// Indicates the start of a JPEG-LS frame with baseline parameters
    case startOfFrameJPEGLS = 0xF7

    /// Start of Scan (SOS)
    /// Marks the beginning of scan header and compressed image data
    case startOfScan = 0xDA

    // MARK: - JPEG-LS Specific Markers

    /// JPEG-LS Preset Parameters (LSE)
    /// Used to specify custom encoding parameters
    case jpegLSExtension = 0xF8

    // MARK: - Application and Comment Markers

    /// Application marker 0-15
    case applicationMarker0 = 0xE0
    case applicationMarker1 = 0xE1
    case applicationMarker2 = 0xE2
    case applicationMarker3 = 0xE3
    case applicationMarker4 = 0xE4
    case applicationMarker5 = 0xE5
    case applicationMarker6 = 0xE6
    case applicationMarker7 = 0xE7
    case applicationMarker8 = 0xE8
    case applicationMarker9 = 0xE9
    case applicationMarker10 = 0xEA
    case applicationMarker11 = 0xEB
    case applicationMarker12 = 0xEC
    case applicationMarker13 = 0xED
    case applicationMarker14 = 0xEE
    case applicationMarker15 = 0xEF

    /// Comment marker (COM)
    case comment = 0xFE

    // MARK: - Restart Markers

    /// Restart marker 0-7 (used for error resilience)
    case restart0 = 0xD0
    case restart1 = 0xD1
    case restart2 = 0xD2
    case restart3 = 0xD3
    case restart4 = 0xD4
    case restart5 = 0xD5
    case restart6 = 0xD6
    case restart7 = 0xD7

    // MARK: - Interval and Line Markers

    /// Define Number of Lines (DNL) - specifies the number of lines when not known at SOF
    case defineNumberOfLines = 0xDC

    /// Define Restart Interval (DRI) - specifies the number of MCUs between restart markers
    case defineRestartInterval = 0xDD

    /// Marker prefix byte (0xFF) - all markers start with this
    public static let markerPrefix: UInt8 = 0xFF

    /// Returns the full two-byte marker sequence
    public var bytes: (UInt8, UInt8) {
        return (JPEGLSMarker.markerPrefix, self.rawValue)
    }

    /// Returns true if this marker has a length field following it
    public var hasLength: Bool {
        switch self {
        case .startOfImage, .endOfImage, .restart0, .restart1, .restart2,
             .restart3, .restart4, .restart5, .restart6, .restart7:
            return false
        default:
            return true
        }
    }
}

/// JPEG-LS Extension (LSE) type codes
///
/// The LSE marker can contain different types of extension data.
public enum JPEGLSExtensionType: UInt8, Sendable {
    /// Preset coding parameters (T1, T2, T3, RESET, MAXVAL)
    case presetCodingParameters = 0x01

    /// Mapping table specification
    case mappingTable = 0x02

    /// Mapping table continuation
    case mappingTableContinuation = 0x03

    /// Extension for X and Y dimensions > 65535
    case extendedDimensions = 0x04
}
