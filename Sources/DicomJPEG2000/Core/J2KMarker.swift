//
// J2KMarker.swift
// J2KSwift
//
/// # J2KMarker
///
/// JPEG 2000 marker definitions and constants.
///
/// This module defines all standard JPEG 2000 codestream markers as specified
/// in ISO/IEC 15444-1 (JPEG 2000 Part 1).

import Foundation

/// Standard JPEG 2000 codestream markers.
///
/// Markers are two-byte sequences starting with 0xFF that delimit various
/// parts of the JPEG 2000 codestream.
///
/// > Important: This is an **internal implementation detail** of the J2KSwift library.
/// > It is exposed as `public` only for cross-module use within the package.
/// > Direct use of this type is not recommended. Use ``J2KDecoder`` or ``J2KFileReader`` instead.
public enum J2KMarker: UInt16, Sendable {
    // MARK: - Delimiting Markers

    /// Start of codestream (SOC).
    case soc = 0xFF4F

    /// Start of tile-part (SOT).
    case sot = 0xFF90

    /// Start of data (SOD).
    case sod = 0xFF93

    /// End of codestream (EOC).
    case eoc = 0xFFD9

    // MARK: - Fixed Information Marker Segments

    /// Image and tile size (SIZ).
    case siz = 0xFF51

    // MARK: - Functional Marker Segments

    /// Coding style default (COD).
    case cod = 0xFF52

    /// Coding style component (COC).
    case coc = 0xFF53

    /// Region of interest (RGN).
    case rgn = 0xFF5E

    /// Quantization default (QCD).
    case qcd = 0xFF5C

    /// Quantization component (QCC).
    case qcc = 0xFF5D

    /// Progression order change (POC).
    case poc = 0xFF5F

    // MARK: - Pointer Marker Segments

    /// Tile-part lengths (TLM).
    case tlm = 0xFF55

    /// Packet length, main header (PLM).
    case plm = 0xFF57

    /// Packet length, tile-part header (PLT).
    case plt = 0xFF58

    /// Packed packet headers, main header (PPM).
    case ppm = 0xFF60

    /// Packed packet headers, tile-part header (PPT).
    case ppt = 0xFF61

    // MARK: - In-Bit-Stream Marker Segments

    /// Start of packet (SOP).
    case sop = 0xFF91

    /// End of packet header (EPH).
    case eph = 0xFF92

    // MARK: - Informational Marker Segments

    /// Component registration (CRG).
    case crg = 0xFF63

    /// Comment (COM).
    case com = 0xFF64

    // MARK: - Part 2 Extension Marker Segments (ISO/IEC 15444-2)

    /// Variable DC offset (DCO) — ISO/IEC 15444-2.
    ///
    /// Signals per-component DC offset values for improved compression
    /// of images with non-zero mean values.
    case dco = 0xFF74

    /// Arbitrary decomposition styles (ADS) — ISO/IEC 15444-2.
    ///
    /// Defines custom wavelet kernels beyond the standard 5/3 and 9/7 filters.
    case ads = 0xFF73

    /// Multi-component transform (MCT) — ISO/IEC 15444-2.
    ///
    /// Defines array-based multi-component transforms for decorrelating
    /// image components.
    case mct = 0xFF75

    /// Multi-component collection (MCC) — ISO/IEC 15444-2.
    ///
    /// Groups components for multi-component transforms.
    case mcc = 0xFF77

    /// Component bit depth definition (T.801 A.3.x, Figure A.6): reconstructed component depths after Annex J transforms.
    case cbd = 0xFF78

    /// Multi-component transform ordering (MCO) — ISO/IEC 15444-2.
    ///
    /// Specifies the order of multi-component transforms.
    case mco = 0xFF76

    // MARK: - HTJ2K (Part 15) Marker Segments

    /// Extended capabilities (CAP) — ISO/IEC 15444-15.
    ///
    /// Signals HTJ2K (High-Throughput JPEG 2000) support and other
    /// extended capabilities in the codestream.
    case cap = 0xFF50

    /// Corresponding profile (CPF) — ISO/IEC 15444-15.
    ///
    /// Specifies the profile to which the codestream conforms, including
    /// HTJ2K-specific profiles.
    case cpf = 0xFF59

    // MARK: - Marker Categories

    /// Returns `true` if this marker has a marker segment (length + data).
    public var hasSegment: Bool {
        switch self {
        case .soc, .sod, .eoc, .eph:
            return false
        default:
            return true
        }
    }

    /// Returns `true` if this is a delimiting marker.
    public var isDelimiting: Bool {
        switch self {
        case .soc, .sot, .sod, .eoc:
            return true
        default:
            return false
        }
    }

    /// Returns `true` if this marker can appear in the main header.
    public var canAppearInMainHeader: Bool {
        switch self {
        case .siz, .cod, .coc, .qcd, .qcc, .rgn, .poc, .tlm, .plm, .ppm, .crg, .com,
             .cap, .cpf, .dco, .ads, .mct, .mcc, .mco:
            return true
        default:
            return false
        }
    }

    /// Returns `true` if this marker can appear in a tile-part header.
    public var canAppearInTileHeader: Bool {
        switch self {
        case .cod, .coc, .qcd, .qcc, .rgn, .poc, .plt, .ppt, .com, .dco, .ads, .mct, .mcc, .mco:
            return true
        default:
            return false
        }
    }

    /// Returns a human-readable name for the marker.
    public var name: String {
        switch self {
        case .soc: return "SOC (Start of codestream)"
        case .sot: return "SOT (Start of tile-part)"
        case .sod: return "SOD (Start of data)"
        case .eoc: return "EOC (End of codestream)"
        case .siz: return "SIZ (Image and tile size)"
        case .cod: return "COD (Coding style default)"
        case .coc: return "COC (Coding style component)"
        case .rgn: return "RGN (Region of interest)"
        case .qcd: return "QCD (Quantization default)"
        case .qcc: return "QCC (Quantization component)"
        case .poc: return "POC (Progression order change)"
        case .tlm: return "TLM (Tile-part lengths)"
        case .plm: return "PLM (Packet length, main header)"
        case .plt: return "PLT (Packet length, tile-part header)"
        case .ppm: return "PPM (Packed packet headers, main header)"
        case .ppt: return "PPT (Packed packet headers, tile-part header)"
        case .sop: return "SOP (Start of packet)"
        case .eph: return "EPH (End of packet header)"
        case .crg: return "CRG (Component registration)"
        case .com: return "COM (Comment)"
        case .dco: return "DCO (Variable DC offset)"
        case .ads: return "ADS (Arbitrary decomposition styles)"
        case .mct: return "MCT (Multi-component transform)"
        case .mcc: return "MCC (Multi-component collection)"
        case .cbd: return "CBD (Component bit depth definition)"
        case .mco: return "MCO (Multi-component transform ordering)"
        case .cap: return "CAP (Extended capabilities)"
        case .cpf: return "CPF (Corresponding profile)"
        }
    }
}

/// Represents a parsed JPEG 2000 marker segment.
///
/// A marker segment consists of a marker (2 bytes), a length field (2 bytes),
/// and the segment data. Markers without segments (SOC, SOD, EOC, EPH) have
/// no length or data.
public struct J2KMarkerSegment: Sendable {
    /// The marker code.
    public let marker: J2KMarker

    /// The position of the marker in the codestream.
    public let position: Int

    /// The segment data (not including marker and length field).
    public let data: Data

    /// The total length of the marker segment in bytes.
    public var totalLength: Int {
        if marker.hasSegment {
            return 2 + 2 + data.count // marker + length field + data
        } else {
            return 2 // marker only
        }
    }

    /// Creates a new marker segment.
    ///
    /// - Parameters:
    ///   - marker: The marker code.
    ///   - position: The position in the codestream.
    ///   - data: The segment data.
    public init(marker: J2KMarker, position: Int, data: Data = Data()) {
        self.marker = marker
        self.position = position
        self.data = data
    }
}

/// A parser for JPEG 2000 marker segments.
///
/// `J2KMarkerParser` provides methods for parsing marker segments from
/// a JPEG 2000 codestream.
///
/// Example:
/// ```swift
/// let parser = J2KMarkerParser(data: codestreamData)
/// let segments = try parser.parseMainHeader()
/// ```
public struct J2KMarkerParser: Sendable {
    /// The codestream data.
    private let data: Data

    /// Creates a new marker parser.
    ///
    /// - Parameter data: The codestream data to parse.
    public init(data: Data) {
        self.data = data
    }

    /// Parses a single marker segment at the specified position.
    ///
    /// - Parameter position: The byte position of the marker.
    /// - Returns: The parsed marker segment.
    /// - Throws: ``J2KError/invalidData(_:)`` if the marker is invalid.
    public func parseMarkerSegment(at position: Int) throws -> J2KMarkerSegment {
        var reader = J2KBitReader(data: data)
        try reader.seek(to: position)

        let markerCode = try reader.readUInt16()
        guard let marker = J2KMarker(rawValue: markerCode) else {
            throw J2KError.invalidData("Unknown marker 0x\(String(markerCode, radix: 16)) at position \(position)")
        }

        if marker.hasSegment {
            let length = Int(try reader.readUInt16())
            guard length >= 2 else {
                throw J2KError.invalidData("Invalid segment length \(length) at position \(position)")
            }
            let segmentData = try reader.readBytes(length - 2)
            return J2KMarkerSegment(marker: marker, position: position, data: segmentData)
        } else {
            return J2KMarkerSegment(marker: marker, position: position, data: Data())
        }
    }

    /// Parses the main header of the codestream.
    ///
    /// The main header starts with SOC and ends with the first SOT marker.
    ///
    /// - Returns: An array of marker segments in the main header.
    /// - Throws: ``J2KError`` if parsing fails.
    public func parseMainHeader() throws -> [J2KMarkerSegment] {
        var segments: [J2KMarkerSegment] = []
        var reader = J2KBitReader(data: data)

        // First marker must be SOC
        let socMarker = try reader.readUInt16()
        guard socMarker == J2KMarker.soc.rawValue else {
            throw J2KError.invalidData("Codestream must start with SOC marker, found 0x\(String(socMarker, radix: 16))")
        }
        segments.append(J2KMarkerSegment(marker: .soc, position: 0))

        var position = 2

        while position < data.count {
            // Read next marker
            if reader.bytesRemaining < 2 {
                break
            }

            let markerCode = try reader.readUInt16()

            // Check for SOT (end of main header)
            if markerCode == J2KMarker.sot.rawValue {
                // SOT marks the end of the main header
                segments.append(J2KMarkerSegment(marker: .sot, position: position))
                break
            }

            guard let marker = J2KMarker(rawValue: markerCode) else {
                throw J2KError.invalidData("Unknown marker 0x\(String(markerCode, radix: 16)) at position \(position)")
            }

            if marker.hasSegment {
                guard reader.bytesRemaining >= 2 else {
                    throw J2KError.invalidData("Unexpected end of data reading segment length at position \(position)")
                }
                let length = Int(try reader.readUInt16())
                guard length >= 2 else {
                    throw J2KError.invalidData("Invalid segment length \(length) at position \(position)")
                }
                guard reader.bytesRemaining >= length - 2 else {
                    throw J2KError.invalidData("Unexpected end of data reading segment at position \(position)")
                }
                let segmentData = try reader.readBytes(length - 2)
                segments.append(J2KMarkerSegment(marker: marker, position: position, data: segmentData))
                position = reader.position
            } else {
                segments.append(J2KMarkerSegment(marker: marker, position: position, data: Data()))
                position = reader.position
            }
        }

        return segments
    }

    /// Validates that the codestream has the required markers.
    ///
    /// - Returns: `true` if the codestream appears valid.
    public func validateBasicStructure() -> Bool {
        guard data.count >= 4 else { return false }

        // Check for SOC marker at start
        let socMarker = UInt16(data[0]) << 8 | UInt16(data[1])
        guard socMarker == J2KMarker.soc.rawValue else { return false }

        // Check for EOC marker at end (if present)
        if data.count >= 2 {
            let lastTwo = UInt16(data[data.count - 2]) << 8 | UInt16(data[data.count - 1])
            if lastTwo == J2KMarker.eoc.rawValue {
                return true
            }
        }

        // Look for SIZ marker (required after SOC)
        if data.count >= 4 {
            let sizMarker = UInt16(data[2]) << 8 | UInt16(data[3])
            return sizMarker == J2KMarker.siz.rawValue
        }

        return false
    }

    /// Finds all occurrences of a specific marker in the codestream.
    ///
    /// - Parameter marker: The marker to search for.
    /// - Returns: Array of byte positions where the marker was found.
    public func findMarkers(_ marker: J2KMarker) -> [Int] {
        var positions: [Int] = []
        let markerBytes = [UInt8(marker.rawValue >> 8), UInt8(marker.rawValue & 0xFF)]

        var index = 0
        while index < data.count - 1 {
            if data[index] == markerBytes[0] && data[index + 1] == markerBytes[1] {
                positions.append(index)
            }
            index += 1
        }

        return positions
    }
}
