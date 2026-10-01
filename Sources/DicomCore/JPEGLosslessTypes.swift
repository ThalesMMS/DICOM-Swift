import Foundation

// MARK: - JPEG Marker Constants

/// JPEG marker codes used in JPEG Lossless bitstreams
enum JPEGMarker: UInt8, Sendable {
    case soi = 0xD8   // Start of Image
    case eoi = 0xD9   // End of Image
    case sos = 0xDA   // Start of Scan
    case dht = 0xC4   // Define Huffman Table
    case sof3 = 0xC3  // Start of Frame - Lossless (Process 14)
    case dri = 0xDD   // Define Restart Interval

    /// Marker prefix byte (all JPEG markers start with 0xFF)
    static let prefix: UInt8 = 0xFF

    /// Byte stuffing padding (0xFF 0x00 in compressed data represents single 0xFF)
    static let stuffingByte: UInt8 = 0x00

    /// Returns true for restart markers RST0...RST7.
    static func isRestart(_ marker: UInt8) -> Bool {
        marker >= 0xD0 && marker <= 0xD7
    }
}

// MARK: - Data Structures

/// Start of Frame (SOF3) marker data for lossless JPEG
internal struct SOF3Info: Sendable {
    /// Image width in pixels
    let width: Int
    /// Image height in pixels
    let height: Int
    /// Sample precision in bits (typically 8, 12, or 16)
    let precision: Int
    /// Number of image components (1 for grayscale, 3 for RGB)
    let numberOfComponents: Int
    /// Component specifications (ID, sampling factors, quantization table)
    let components: [ComponentSpec]
}

/// Image component specification from SOF3 marker
internal struct ComponentSpec: Sendable {
    /// Component identifier (1 = Y/grayscale, 2 = Cb, 3 = Cr)
    let id: UInt8
    /// Horizontal sampling factor
    let horizontalSamplingFactor: UInt8
    /// Vertical sampling factor
    let verticalSamplingFactor: UInt8
    /// Quantization table selector (unused in lossless mode)
    let quantizationTableSelector: UInt8
}

/// Start of Scan (SOS) marker data
internal struct SOSInfo: Sendable {
    /// Number of components in this scan
    let numberOfComponents: Int
    /// Component selectors with entropy table assignments
    let components: [ScanComponentSelector]
    /// Selection value (predictor ID): 0-7
    /// For Transfer Syntax 1.2.840.10008.1.2.4.70, this must be 1
    let selectionValue: Int
    /// Start of spectral selection (must be 0 for lossless)
    let startSpectral: Int
    /// End of spectral selection (must be 0 for lossless)
    let endSpectral: Int
    /// Successive approximation bit position high (must be 0)
    let successiveApproximationHigh: UInt8
    /// Successive approximation bit position low (must be 0)
    let successiveApproximationLow: UInt8
}

/// Component selector for scan with entropy coding table assignments
internal struct ScanComponentSelector: Sendable {
    /// Component identifier
    let componentId: UInt8
    /// DC entropy coding table selector (0-3)
    let dcTableSelector: UInt8
    /// AC entropy coding table selector (0-3, unused in lossless)
    let acTableSelector: UInt8
}

/// Huffman table for entropy decoding
internal struct HuffmanTable: Sendable {
    /// Table class: 0 = DC, 1 = AC (lossless uses DC tables)
    let tableClass: UInt8
    /// Table destination identifier (0-3)
    let tableId: UInt8
    /// Number of codes of length 1-16 bits (16 entries)
    let symbolCounts: [UInt8]
    /// Huffman symbol values ordered by code length
    let symbolValues: [UInt8]

    // Decoding tables (populated by buildDecodingTables)
    /// Minimum code value for each bit length [1...16]
    var minCode: [Int] = []
    /// Maximum code value for each bit length [1...16]
    var maxCode: [Int] = []
    /// Index into symbolValues for each bit length [1...16]
    var valPtr: [Int] = []
    /// Direct lookup for codes of up to `lookupBits` bits: index = the next `lookupBits` bits of the stream,
    /// value = `length << 8 | symbol`, or 0 when the code is longer (the canonical search then applies).
    var lookup: [UInt16] = []

    static let lookupBits = 9
}

/// Result of JPEG Lossless decoding operation
internal struct JPEGLosslessDecodeResult: Sendable {
    /// Decoded samples: grayscale when `componentCount == 1`, interleaved
    /// (R,G,B per pixel) when `componentCount == 3`.
    let pixels: [UInt16]
    /// Image width in pixels
    let width: Int
    /// Image height in pixels
    let height: Int
    /// Bit depth (8, 12, or 16)
    let bitDepth: Int
    /// Number of image components (1 grayscale, 3 interleaved color)
    let componentCount: Int
}
