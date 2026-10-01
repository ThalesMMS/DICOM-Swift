// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.
// Isis modifications are recorded in Git.

/// JPEG marker definitions and marker segment writer.
///
/// Handles writing all JPEG header markers (SOI, APP0, DQT, SOF, DHT, SOS, EOI)
/// that wrap the entropy-coded image data.

// MARK: - JPEG Marker Types

/// Standard JPEG marker codes.
enum JPEGMarker {
    // Start/End
    static let soi: UInt8 = 0xD8   // Start of Image
    static let eoi: UInt8 = 0xD9   // End of Image

    // Frame types
    static let sof0: UInt8 = 0xC0  // Baseline DCT (8-bit only)
    static let sof1: UInt8 = 0xC1  // Extended sequential DCT (8 or 12-bit)
    static let sof2: UInt8 = 0xC2  // Progressive DCT
    static let sof3: UInt8 = 0xC3  // Lossless (sequential, predictive)

    // Huffman tables
    static let dht: UInt8 = 0xC4   // Define Huffman Table

    // Quantization tables
    static let dqt: UInt8 = 0xDB   // Define Quantization Table

    // Scan
    static let sos: UInt8 = 0xDA   // Start of Scan

    // Application segments
    static let app0: UInt8 = 0xE0  // JFIF
    static let app1: UInt8 = 0xE1  // Exif
    static let app2: UInt8 = 0xE2  // ICC Profile

    // Restart
    static let dri: UInt8 = 0xDD   // Define Restart Interval
    static let rst0: UInt8 = 0xD0  // Restart marker 0

    // Comment
    static let com: UInt8 = 0xFE   // Comment

    /// Prefix byte for all JPEG markers.
    static let prefix: UInt8 = 0xFF
}

// MARK: - Marker Writer

/// Writes JPEG marker segments into a byte buffer.
struct MarkerWriter {
    /// The accumulated JPEG output data.
    private(set) var data: [UInt8] = []

    /// Writes the SOI (Start of Image) marker.
    mutating func writeSOI() {
        data.append(JPEGMarker.prefix)
        data.append(JPEGMarker.soi)
    }

    /// Writes the EOI (End of Image) marker.
    mutating func writeEOI() {
        data.append(JPEGMarker.prefix)
        data.append(JPEGMarker.eoi)
    }

    /// Writes the JFIF APP0 marker segment.
    mutating func writeAPP0() {
        data.append(JPEGMarker.prefix)
        data.append(JPEGMarker.app0)

        // Length = 16 (includes length field but not marker)
        writeUInt16(16)

        // "JFIF\0" identifier
        data.append(contentsOf: [0x4A, 0x46, 0x49, 0x46, 0x00])

        // Version 1.01
        data.append(1)  // Major
        data.append(1)  // Minor

        // Units: 0 = no units (aspect ratio only)
        data.append(0)

        // X/Y density (1:1)
        writeUInt16(1)
        writeUInt16(1)

        // No thumbnail
        data.append(0)
        data.append(0)
    }

    /// Writes an Adobe APP14 marker. `transform` 0 = no color transform (the
    /// three components are stored directly, e.g. RGB) — used for lossless RGB so
    /// decoders don't assume YCbCr (as they would from a JFIF 3-component frame).
    mutating func writeAPP14(transform: UInt8) {
        data.append(JPEGMarker.prefix)
        data.append(0xEE)                                   // APP14
        writeUInt16(14)
        data.append(contentsOf: [0x41, 0x64, 0x6F, 0x62, 0x65])  // "Adobe"
        writeUInt16(100)                                    // version
        writeUInt16(0)                                      // flags0
        writeUInt16(0)                                      // flags1
        data.append(transform)
    }

    /// Writes an APP1 Exif segment: `"Exif\0\0"` identifier followed by the raw
    /// Exif (TIFF) payload. Skipped if the payload is too large for one segment
    /// (Exif isn't chunked); the 16-bit length caps the body at 65533 bytes.
    mutating func writeAPP1Exif(_ exif: [UInt8]) {
        let id: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]   // "Exif\0\0"
        guard id.count + exif.count <= 65533 else { return }
        data.append(JPEGMarker.prefix)
        data.append(JPEGMarker.app1)
        writeUInt16(UInt16(2 + id.count + exif.count))
        data.append(contentsOf: id)
        data.append(contentsOf: exif)
    }

    /// Writes the ICC color profile across one or more APP2 segments per the
    /// "ICC profiles in JPEG" convention: each segment carries the 12-byte
    /// `"ICC_PROFILE\0"` identifier, a 1-based sequence number, the total chunk
    /// count, then up to 65519 profile bytes. A profile needing more than 255
    /// chunks (~16 MB) is skipped (unrepresentable in the 1-byte count).
    mutating func writeAPP2ICC(_ profile: [UInt8]) {
        let id: [UInt8] = [0x49, 0x43, 0x43, 0x5F, 0x50, 0x52,
                           0x4F, 0x46, 0x49, 0x4C, 0x45, 0x00]   // "ICC_PROFILE\0"
        let maxChunk = 65519
        let count = (profile.count + maxChunk - 1) / maxChunk
        guard count >= 1, count <= 255 else { return }
        for i in 0..<count {
            let start = i * maxChunk
            let end = min(start + maxChunk, profile.count)
            data.append(JPEGMarker.prefix)
            data.append(JPEGMarker.app2)
            writeUInt16(UInt16(2 + id.count + 2 + (end - start)))
            data.append(contentsOf: id)
            data.append(UInt8(i + 1))       // sequence number (1-based)
            data.append(UInt8(count))       // total chunk count
            data.append(contentsOf: profile[start..<end])
        }
    }

    /// Writes DQT (Define Quantization Table) marker for one or more tables.
    ///
    /// - Parameters:
    ///   - tables: Array of (tableId, quantValues) tuples. Each quantValues has 64 elements in zigzag order.
    mutating func writeDQT(tables: [(id: Int, values: [UInt8])]) {
        data.append(JPEGMarker.prefix)
        data.append(JPEGMarker.dqt)

        // Length = 2 + (1 + 64) per table (8-bit precision)
        let length = 2 + tables.count * 65
        writeUInt16(UInt16(length))

        for table in tables {
            // Precision (0 = 8-bit) | table ID
            data.append(UInt8(table.id & 0x0F))
            data.append(contentsOf: table.values)
        }
    }

    /// Writes SOF0 (Baseline DCT) or SOF2 (Progressive DCT) marker.
    ///
    /// - Parameters:
    ///   - progressive: If true, writes SOF2; otherwise SOF0.
    ///   - precision: Sample precision in bits (typically 8).
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - components: Array of (id, hSampling, vSampling, quantTableId).
    mutating func writeSOF(
        progressive: Bool,
        precision: Int,
        width: Int,
        height: Int,
        components: [(id: UInt8, hSampling: Int, vSampling: Int, quantTableId: Int)],
        lossless: Bool = false,
        extendedSequential: Bool = false
    ) {
        data.append(JPEGMarker.prefix)
        // Baseline SOF0 is 8-bit only; 12-bit requires Extended Sequential (SOF1), and a caller may ask
        // for SOF1 at 8 bits (DICOM's .51 syntax); progressive is SOF2; lossless (predictive) is SOF3.
        let sofMarker: UInt8
        if lossless { sofMarker = JPEGMarker.sof3 }
        else if progressive { sofMarker = JPEGMarker.sof2 }
        else if precision > 8 || extendedSequential { sofMarker = JPEGMarker.sof1 }
        else { sofMarker = JPEGMarker.sof0 }
        data.append(sofMarker)

        let length = 8 + components.count * 3
        writeUInt16(UInt16(length))

        data.append(UInt8(precision))
        writeUInt16(UInt16(height))
        writeUInt16(UInt16(width))
        data.append(UInt8(components.count))

        for comp in components {
            data.append(comp.id)
            data.append(UInt8((comp.hSampling << 4) | comp.vSampling))
            data.append(UInt8(comp.quantTableId))
        }
    }

    /// Writes DHT (Define Huffman Table) marker for one or more tables.
    ///
    /// - Parameters:
    ///   - tables: Array of (tableClass, tableId, bits, values). tableClass: 0=DC, 1=AC.
    mutating func writeDHT(tables: [(tableClass: Int, tableId: Int, bits: [UInt8], values: [UInt8])]) {
        data.append(JPEGMarker.prefix)
        data.append(JPEGMarker.dht)

        var segmentData: [UInt8] = []
        for table in tables {
            // Class (0=DC, 1=AC) | table ID
            segmentData.append(UInt8((table.tableClass << 4) | (table.tableId & 0x0F)))
            segmentData.append(contentsOf: table.bits)
            segmentData.append(contentsOf: table.values)
        }

        writeUInt16(UInt16(2 + segmentData.count))
        data.append(contentsOf: segmentData)
    }

    /// Writes SOS (Start of Scan) marker.
    ///
    /// - Parameters:
    ///   - components: Array of (componentSelector, dcTableId, acTableId).
    ///   - spectralStart: Start of spectral selection (0 for baseline).
    ///   - spectralEnd: End of spectral selection (63 for baseline).
    ///   - successiveApproxHigh: Successive approximation bit position high (0 for baseline).
    ///   - successiveApproxLow: Successive approximation bit position low (0 for baseline).
    mutating func writeSOS(
        components: [(selector: UInt8, dcTableId: Int, acTableId: Int)],
        spectralStart: Int = 0,
        spectralEnd: Int = 63,
        successiveApproxHigh: Int = 0,
        successiveApproxLow: Int = 0
    ) {
        data.append(JPEGMarker.prefix)
        data.append(JPEGMarker.sos)

        let length = 6 + components.count * 2
        writeUInt16(UInt16(length))

        data.append(UInt8(components.count))
        for comp in components {
            data.append(comp.selector)
            data.append(UInt8((comp.dcTableId << 4) | (comp.acTableId & 0x0F)))
        }

        data.append(UInt8(spectralStart))
        data.append(UInt8(spectralEnd))
        data.append(UInt8((successiveApproxHigh << 4) | (successiveApproxLow & 0x0F)))
    }

    /// Writes a DRI (Define Restart Interval) marker: restart every `interval`
    /// MCUs. `interval` 0 conventionally means "no restart markers".
    mutating func writeDRI(interval: Int) {
        data.append(JPEGMarker.prefix)
        data.append(JPEGMarker.dri)
        writeUInt16(4)                       // segment length
        writeUInt16(UInt16(interval))
    }

    /// Appends raw entropy-coded data (already byte-stuffed).
    mutating func writeEntropyData(_ entropyData: [UInt8]) {
        data.append(contentsOf: entropyData)
    }

    /// Writes a 16-bit big-endian unsigned integer.
    private mutating func writeUInt16(_ value: UInt16) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }
}
