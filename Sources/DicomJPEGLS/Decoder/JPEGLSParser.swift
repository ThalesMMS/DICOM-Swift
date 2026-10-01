// Modified for Isis from JLSwift 299b9a2 (Apache-2.0); the modifications are recorded in Git.

/// JPEG-LS bitstream parser per ISO/IEC 14495-1:1999 / ITU-T.87
///
/// Parses JPEG-LS encoded data streams, extracting frame headers, scan headers,
/// preset parameters, and locating compressed image data.
///
/// ## Entropy stuffing and unknown markers
///
/// Within scan data, an `0xFF` byte followed by a byte whose most-significant
/// bit is zero is treated as stuffed entropy data per ITU-T.87 §9.1. Outside a
/// scan, the parser also tolerates low-valued standalone continuation codes in
/// the `0x60...0x7F` range and skips unknown length-prefixed marker segments.

import Foundation

/// Result of parsing a JPEG-LS bitstream
///
/// Contains all metadata needed for decoding the image data.
public struct JPEGLSParseResult: Sendable {
    /// Frame header describing image dimensions and components
    public let frameHeader: JPEGLSFrameHeader

    /// Scan headers for each scan in the image
    public let scanHeaders: [JPEGLSScanHeader]

    /// Preset parameters (if custom parameters were specified via LSE marker)
    public let presetParameters: JPEGLSPresetParameters?

    /// Restart interval in MCUs (if a DRI marker was present, otherwise nil)
    public let restartInterval: Int?

    /// Mapping tables keyed by table ID (parsed from LSE type 2/3 markers).
    ///
    /// When a scan component references a table ID > 0, decoded raw sample
    /// values are used as indices into the corresponding mapping table.
    public let mappingTables: [UInt8: JPEGLSMappingTable]

    /// Application marker data (APP0-APP15)
    public let applicationMarkers: [(marker: JPEGLSMarker, data: Data)]

    /// Comment marker data
    public let comments: [Data]

    /// Colour transformation signalled by an APP8 "mrfx" marker (default: .none).
    ///
    /// The encoder writes an APP8 segment with the four-byte identifier "mrfx"
    /// followed by a single byte containing the transform ID.  The decoder reads
    /// this marker and applies the corresponding inverse transform after decoding.
    public let colorTransformation: JPEGLSColorTransformation

    /// Byte ranges of each scan's entropy-coded body within the parsed data,
    /// one per scan header, in scan order.  The parser already walks every
    /// scan body to find the terminating marker; recording the offsets here
    /// lets the decoder slice the original data directly instead of doing a
    /// second full-file marker walk.  Empty when the result was constructed
    /// without parsing (the decoder then falls back to its own walk).
    public let scanDataRanges: [Range<Int>]

    /// The restart interval (DRI value) in effect at each scan's SOS marker,
    /// one per scan header, in scan order (0 = none).  Per T.81 B.2.4.4 a
    /// DRI segment between scans applies to following scans only, so a
    /// single file-global value cannot represent multi-scan streams that
    /// (re)define it.  Empty when the result was constructed without parsing.
    public let scanRestartIntervals: [Int]

    /// Initialize parse result
    ///
    /// - Parameters:
    ///   - frameHeader: Frame header
    ///   - scanHeaders: Scan headers
    ///   - presetParameters: Optional custom preset parameters
    ///   - restartInterval: Optional restart interval from DRI marker
    ///   - mappingTables: Mapping tables keyed by table ID
    ///   - applicationMarkers: Application markers
    ///   - comments: Comment data
    ///   - colorTransformation: Colour transform from APP8 "mrfx" marker (default: .none)
    ///   - scanDataRanges: Byte ranges of each scan body (default: empty)
    ///   - scanRestartIntervals: Restart interval in effect at each SOS (default: empty)
    public init(
        frameHeader: JPEGLSFrameHeader,
        scanHeaders: [JPEGLSScanHeader],
        presetParameters: JPEGLSPresetParameters? = nil,
        restartInterval: Int? = nil,
        mappingTables: [UInt8: JPEGLSMappingTable] = [:],
        applicationMarkers: [(marker: JPEGLSMarker, data: Data)] = [],
        comments: [Data] = [],
        colorTransformation: JPEGLSColorTransformation = .none,
        scanDataRanges: [Range<Int>] = [],
        scanRestartIntervals: [Int] = []
    ) {
        self.frameHeader = frameHeader
        self.scanHeaders = scanHeaders
        self.presetParameters = presetParameters
        self.restartInterval = restartInterval
        self.mappingTables = mappingTables
        self.applicationMarkers = applicationMarkers
        self.comments = comments
        self.colorTransformation = colorTransformation
        self.scanDataRanges = scanDataRanges
        self.scanRestartIntervals = scanRestartIntervals
    }
}

/// JPEG-LS bitstream parser
///
/// Parses JPEG-LS file format according to ITU-T.87 standard.
/// Validates marker sequence and extracts all necessary metadata for decoding.
public final class JPEGLSParser {
    private let reader: JPEGLSBitstreamReader

    /// Initialize parser with encoded data
    ///
    /// - Parameter data: JPEG-LS encoded data
    public init(data: Data) {
        self.reader = JPEGLSBitstreamReader(data: data)
    }

    /// Parse the JPEG-LS bitstream
    ///
    /// Validates the structure and extracts all metadata.
    ///
    /// The parser handles JPEG-LS marker segments and stuffed entropy data.
    /// Unknown length-prefixed markers and defensive low-valued continuation
    /// codes in the `0x60...0x7F` range are skipped.
    ///
    /// - Returns: Parse result containing frame header, scan headers, and parameters
    /// - Throws: `JPEGLSError` if the bitstream is invalid or corrupted
    public func parse() throws -> JPEGLSParseResult {
        // Parse SOI marker
        try expectMarker(.startOfImage)

        var frameHeader: JPEGLSFrameHeader?
        var scanHeaders: [JPEGLSScanHeader] = []
        var presetParameters: JPEGLSPresetParameters?
        var restartInterval: Int?
        var mappingTables: [UInt8: JPEGLSMappingTable] = [:]
        var applicationMarkers: [(marker: JPEGLSMarker, data: Data)] = []
        var comments: [Data] = []
        var extendedWidth: Int?
        var extendedHeight: Int?
        var colorTransformation: JPEGLSColorTransformation = .none
        var scanDataRanges: [Range<Int>] = []
        var scanRestartIntervals: [Int] = []

        // Parse marker segments until EOI
        while !reader.isAtEnd {
            // Read marker bytes manually to handle unknown markers
            let byte1 = try reader.readByte()
            guard byte1 == JPEGLSMarker.markerPrefix else {
                throw JPEGLSError.invalidBitstreamStructure(
                    reason: "Expected marker prefix (0xFF), got 0x\(String(byte1, radix: 16))"
                )
            }

            var byte2 = try reader.readByte()
            // T.81 B.1.1.2: any number of 0xFF fill bytes may precede a marker. The MEDILAB encoder writes one
            // between the scan and EOI, which CharLS reads (issue #2868).
            while byte2 == JPEGLSMarker.markerPrefix { byte2 = try reader.readByte() }

            // Try to parse as known marker
            guard let marker = JPEGLSMarker(rawValue: byte2) else {
                // Unknown marker - skip it gracefully
                // Some markers have no length field (standalone markers)
                if (byte2 >= 0xD0 && byte2 <= 0xD7) || byte2 == 0xD8 || byte2 == 0xD9 {
                    // RST markers (0xD0-0xD7), SOI (0xD8), and EOI (0xD9) have no length field
                    continue
                } else if byte2 >= 0x60 && byte2 <= 0x7F {
                    // Defensive compatibility: tolerate low-valued standalone
                    // continuation codes without interpreting a length field.
                    continue
                } else {
                    // Read length and skip the marker segment
                    let length = try reader.readUInt16()
                    guard length >= 2 else {
                        throw JPEGLSError.invalidBitstreamStructure(
                            reason: "Invalid marker segment length for unknown marker 0xFF\(String(byte2, radix: 16)): \(length)"
                        )
                    }
                    let skipLength = Int(length) - 2
                    _ = try reader.readBytes(skipLength)
                    continue
                }
            }

            switch marker {
            case .endOfImage:
                // End of JPEG-LS stream
                guard let frame = frameHeader else {
                    throw JPEGLSError.invalidBitstreamStructure(
                        reason: "No frame header found before EOI"
                    )
                }
                guard !scanHeaders.isEmpty else {
                    throw JPEGLSError.invalidBitstreamStructure(
                        reason: "No scan headers found before EOI"
                    )
                }
                return JPEGLSParseResult(
                    frameHeader: frame,
                    scanHeaders: scanHeaders,
                    presetParameters: presetParameters,
                    restartInterval: restartInterval,
                    mappingTables: mappingTables,
                    applicationMarkers: applicationMarkers,
                    comments: comments,
                    colorTransformation: colorTransformation,
                    scanDataRanges: scanDataRanges,
                    scanRestartIntervals: scanRestartIntervals
                )

            case .startOfFrameJPEGLS:
                // Parse frame header
                guard frameHeader == nil else {
                    throw JPEGLSError.invalidBitstreamStructure(
                        reason: "Multiple SOF markers found"
                    )
                }
                frameHeader = try parseFrameHeader(extendedWidth: extendedWidth, extendedHeight: extendedHeight)

            case .startOfScan:
                // Parse scan header
                guard let frame = frameHeader else {
                    throw JPEGLSError.invalidBitstreamStructure(
                        reason: "SOS marker found before SOF"
                    )
                }
                let scanHeader = try parseScanHeader(frameHeader: frame)
                scanHeaders.append(scanHeader)
                // Record the restart interval in effect at this SOS (a DRI
                // between scans applies to following scans only, T.81 B.2.4.4).
                scanRestartIntervals.append(restartInterval ?? 0)

                // Skip scan data until we hit a marker, recording the body's
                // byte range so the decoder can slice it without a second
                // full-file walk.
                // Per ISO 14495-1 §9.1, a byte following 0xFF with MSB = 0 (value < 0x80)
                // is a stuffed byte; with MSB = 1 (value ≥ 0x80) it is a real marker.
                let scanStart = reader.currentPosition
                var scanEnd: Int? = nil
                while !reader.isAtEnd {
                    let byte = try reader.readByte()
                    if byte == JPEGLSMarker.markerPrefix {
                        // Check next byte to determine if it's stuffing or a real marker
                        if let nextByte = reader.peekByte() {
                            if nextByte >= JPEGLSMarker.restart0.rawValue
                                && nextByte <= JPEGLSMarker.restart7.rawValue {
                                // Restart marker (FFD0–FFD7) inside the scan
                                // body: part of the entropy-coded segment, not
                                // a scan terminator. Consume and continue.
                                _ = try reader.readByte()
                                continue
                            }
                            if nextByte >= 0x80 {
                                // Real marker — back up to re-read the FF byte in the outer loop
                                try reader.seek(to: reader.currentPosition - 1)
                                scanEnd = reader.currentPosition
                                break
                            }
                            // nextByte < 0x80: stuffed byte — consume it and continue
                            _ = try reader.readByte()
                        } else {
                            // End of stream: a trailing lone 0xFF is not scan data
                            scanEnd = reader.currentPosition - 1
                            break
                        }
                    }
                }
                scanDataRanges.append(scanStart..<(scanEnd ?? reader.currentPosition))

            case .jpegLSExtension:
                // Parse JPEG-LS extension
                try parseJPEGLSExtension(
                    frameHeader: frameHeader,
                    presetParameters: &presetParameters,
                    mappingTables: &mappingTables,
                    extendedWidth: &extendedWidth,
                    extendedHeight: &extendedHeight
                )

            case .applicationMarker0, .applicationMarker1, .applicationMarker2,
                 .applicationMarker3, .applicationMarker4, .applicationMarker5,
                 .applicationMarker6, .applicationMarker7, .applicationMarker8,
                 .applicationMarker9, .applicationMarker10, .applicationMarker11,
                 .applicationMarker12, .applicationMarker13, .applicationMarker14,
                 .applicationMarker15:
                // Parse application marker payload
                let data = try parseMarkerSegment()
                applicationMarkers.append((marker: marker, data: data))
                // APP8 "mrfx" carries the colour-transform identifier per ISO/IEC 14495-2 Annex A.
                // Format: 4-byte identifier "mrfx" followed by 1-byte transform ID.
                // Use startIndex-relative indexing because the Data may be a slice whose
                // startIndex is not zero.
                if marker == .applicationMarker8 && data.count >= 5 {
                    let i = data.startIndex
                    if data[i] == 0x6D && data[i + 1] == 0x72 && data[i + 2] == 0x66 && data[i + 3] == 0x78 {
                        if let ct = JPEGLSColorTransformation(rawValue: data[i + 4]) {
                            colorTransformation = ct
                        }
                    }
                }

            case .comment:
                // Parse comment
                let data = try parseMarkerSegment()
                comments.append(data)

            case .restart0, .restart1, .restart2, .restart3,
                 .restart4, .restart5, .restart6, .restart7:
                // Restart markers have no length field, just skip
                continue

            case .defineRestartInterval:
                // Parse Define Restart Interval (DRI) marker per ITU-T.87 §5.1
                restartInterval = try parseRestartInterval()

            case .defineNumberOfLines:
                // Parse Define Number of Lines (DNL) marker per ITU-T.87 §5.1.
                // DNL may appear after the first scan to supply the Y value when it was
                // unknown (Y=0) at SOF time. Frame dimensions are already known from the
                // SOF marker in typical usage, so the DNL payload is consumed but not
                // applied. Full DNL-based dimension update is deferred to a future milestone.
                _ = try parseMarkerSegment()

            case .startOfImage:
                throw JPEGLSError.invalidBitstreamStructure(
                    reason: "Unexpected SOI marker"
                )
            }
        }

        throw JPEGLSError.invalidBitstreamStructure(
            reason: "Missing EOI marker"
        )
    }

    // MARK: - Private Parsing Methods

    /// Expect a specific marker
    private func expectMarker(_ expected: JPEGLSMarker) throws {
        let marker = try reader.readMarker()
        guard marker == expected else {
            throw JPEGLSError.invalidBitstreamStructure(
                reason: "Expected \(expected), got \(marker)"
            )
        }
    }

    /// Parse a generic marker segment with length field
    private func parseMarkerSegment() throws -> Data {
        let length = try reader.readUInt16()
        guard length >= 2 else {
            throw JPEGLSError.invalidBitstreamStructure(
                reason: "Invalid marker segment length: \(length)"
            )
        }
        // Length includes the 2 bytes of the length field itself
        let dataLength = Int(length) - 2
        return try reader.readBytes(dataLength)
    }

    /// Parse frame header (SOF marker segment)
    private func parseFrameHeader(extendedWidth: Int? = nil, extendedHeight: Int? = nil) throws -> JPEGLSFrameHeader {
        let length = try reader.readUInt16()

        // Read precision (bits per sample)
        let bitsPerSample = Int(try reader.readByte())

        // Read dimensions from SOF.  When a dimension is 0, the actual value comes
        // from a preceding LSE type 4 (extended dimensions) segment per ITU-T.87 §5.1.1.4.
        let sofHeight = Int(try reader.readUInt16())
        let sofWidth  = Int(try reader.readUInt16())
        let height = (sofHeight == 0) ? (extendedHeight ?? sofHeight) : sofHeight
        let width  = (sofWidth  == 0) ? (extendedWidth  ?? sofWidth)  : sofWidth

        // Read component count
        let componentCount = Int(try reader.readByte())

        // Validate expected length
        let expectedLength = 2 + 1 + 2 + 2 + 1 + (componentCount * 3)
        guard length == expectedLength else {
            throw JPEGLSError.invalidBitstreamStructure(
                reason: "Invalid SOF length: expected \(expectedLength), got \(length)"
            )
        }

        // Read component specifications
        var components: [JPEGLSFrameHeader.ComponentSpec] = []
        components.reserveCapacity(componentCount)

        for _ in 0..<componentCount {
            let id = try reader.readByte()
            let samplingFactors = try reader.readByte()
            let horizontalSampling = samplingFactors >> 4
            let verticalSampling = samplingFactors & 0x0F
            _ = try reader.readByte()  // Quantization table selector (not used in JPEG-LS)

            components.append(JPEGLSFrameHeader.ComponentSpec(
                id: id,
                horizontalSamplingFactor: horizontalSampling,
                verticalSamplingFactor: verticalSampling
            ))
        }

        return try JPEGLSFrameHeader(
            bitsPerSample: bitsPerSample,
            height: height,
            width: width,
            componentCount: componentCount,
            components: components
        )
    }

    /// Parse scan header (SOS marker segment)
    private func parseScanHeader(frameHeader: JPEGLSFrameHeader) throws -> JPEGLSScanHeader {
        let length = try reader.readUInt16()

        // Read component count in this scan
        let componentCount = Int(try reader.readByte())

        // Validate expected length
        let expectedLength = 2 + 1 + (componentCount * 2) + 3
        guard length == expectedLength else {
            throw JPEGLSError.invalidBitstreamStructure(
                reason: "Invalid SOS length: expected \(expectedLength), got \(length)"
            )
        }

        // Read component selectors
        var components: [JPEGLSScanHeader.ComponentSelector] = []
        components.reserveCapacity(componentCount)

        for _ in 0..<componentCount {
            let id = try reader.readByte()
            // Tdi field: mapping table ID per ITU-T.87 §5.1.2.
            // 0 means no mapping table; 1–255 references a mapping table from an LSE type 2/3 marker.
            let mappingTableID = try reader.readByte()
            components.append(JPEGLSScanHeader.ComponentSelector(id: id, mappingTableID: mappingTableID))
        }

        // Read NEAR parameter
        let near = Int(try reader.readByte())

        // Read interleave mode
        let interleaveModeValue = try reader.readByte()
        guard let interleaveMode = JPEGLSInterleaveMode(rawValue: interleaveModeValue) else {
            throw JPEGLSError.invalidBitstreamStructure(
                reason: "Invalid interleave mode: \(interleaveModeValue)"
            )
        }

        // Read point transform
        let pointTransform = Int(try reader.readByte())

        let scanHeader = try JPEGLSScanHeader(
            componentCount: componentCount,
            components: components,
            near: near,
            interleaveMode: interleaveMode,
            pointTransform: pointTransform
        )

        // Validate scan header against frame header
        try scanHeader.validate(against: frameHeader)

        return scanHeader
    }

    /// Parse JPEG-LS extension marker (LSE)
    private func parseJPEGLSExtension(
        frameHeader: JPEGLSFrameHeader?,
        presetParameters: inout JPEGLSPresetParameters?,
        mappingTables: inout [UInt8: JPEGLSMappingTable],
        extendedWidth: inout Int?,
        extendedHeight: inout Int?
    ) throws {
        let length = try reader.readUInt16()
        // Length includes the 2-byte length field and the 1-byte type that
        // follows; anything shorter is structurally invalid (and would make
        // the skip count below negative).
        guard length >= 3 else {
            throw JPEGLSError.invalidBitstreamStructure(
                reason: "LSE segment length \(length) is shorter than its own header"
            )
        }

        // Read extension type
        let extensionTypeByte = try reader.readByte()
        guard let extensionType = JPEGLSExtensionType(rawValue: extensionTypeByte) else {
            // Unknown extension type - skip the rest
            let skipLength = Int(length) - 3  // Length includes itself (2) and type (1)
            _ = try reader.readBytes(skipLength)
            return
        }

        switch extensionType {
        case .presetCodingParameters:
            // Parse preset parameters
            // Length should be 13: 2 (length field) + 1 (type) + 10 (5 x 2-byte params)
            guard length == 13 else {
                throw JPEGLSError.invalidBitstreamStructure(
                    reason: "Invalid LSE preset parameters length: \(length)"
                )
            }

            let maxValue = Int(try reader.readUInt16())
            let threshold1 = Int(try reader.readUInt16())
            let threshold2 = Int(try reader.readUInt16())
            let threshold3 = Int(try reader.readUInt16())
            let reset = Int(try reader.readUInt16())

            presetParameters = try JPEGLSPresetParameters(
                maxValue: maxValue,
                threshold1: threshold1,
                threshold2: threshold2,
                threshold3: threshold3,
                reset: reset
            )

        case .mappingTable:
            // Parse mapping table specification per ITU-T.87 §5.1.1.3.
            // Format: Length(2) + Type(1) + TID(1) + Wt(1) + Entries((Length-5)*1 or (Length-5)/2)
            // Minimum length = 5 (no entries)
            guard length >= 5 else {
                throw JPEGLSError.invalidBitstreamStructure(
                    reason: "Invalid LSE mapping table length: \(length)"
                )
            }
            let tableID = try reader.readByte()
            let entryWidth = Int(try reader.readByte())
            guard entryWidth == 1 || entryWidth == 2 else {
                throw JPEGLSError.invalidBitstreamStructure(
                    reason: "Invalid mapping table entry width: \(entryWidth) (must be 1 or 2)"
                )
            }
            // Data bytes = length - 5 (subtract: 2 for Ll, 1 for Id, 1 for TID, 1 for Wt)
            let dataBytes = Int(length) - 5
            guard dataBytes >= 0 && dataBytes % entryWidth == 0 else {
                throw JPEGLSError.invalidBitstreamStructure(
                    reason: "Mapping table data length \(dataBytes) not a multiple of entry width \(entryWidth)"
                )
            }
            let entryCount = dataBytes / entryWidth
            var entries: [Int] = []
            entries.reserveCapacity(entryCount)
            for _ in 0..<entryCount {
                if entryWidth == 1 {
                    entries.append(Int(try reader.readByte()))
                } else {
                    entries.append(Int(try reader.readUInt16()))
                }
            }
            let table = try JPEGLSMappingTable(id: tableID, entryWidth: entryWidth, entries: entries)
            // If a table with this ID already exists, the new one replaces it
            mappingTables[tableID] = table

        case .mappingTableContinuation:
            // Append additional entries to an existing mapping table per ITU-T.87 §5.1.1.3.
            // Format: Length(2) + Type(1) + TID(1) + Entries((Length-4) bytes or /2)
            guard length >= 4 else {
                throw JPEGLSError.invalidBitstreamStructure(
                    reason: "Invalid LSE mapping table continuation length: \(length)"
                )
            }
            let tableID = try reader.readByte()
            // data bytes = length - 4 (subtract: 2 for Ll, 1 for Id, 1 for TID)
            let dataBytes = Int(length) - 4
            guard let existingTable = mappingTables[tableID] else {
                // No existing table — skip the data gracefully
                _ = try reader.readBytes(dataBytes)
                return
            }
            let entryWidth = existingTable.entryWidth
            guard dataBytes % entryWidth == 0 else {
                throw JPEGLSError.invalidBitstreamStructure(
                    reason: "Mapping table continuation data length \(dataBytes) not a multiple of entry width \(entryWidth)"
                )
            }
            let entryCount = dataBytes / entryWidth
            var additionalEntries: [Int] = []
            additionalEntries.reserveCapacity(entryCount)
            for _ in 0..<entryCount {
                if entryWidth == 1 {
                    additionalEntries.append(Int(try reader.readByte()))
                } else {
                    additionalEntries.append(Int(try reader.readUInt16()))
                }
            }
            let combinedEntries = existingTable.entries + additionalEntries
            let updatedTable = try JPEGLSMappingTable(
                id: tableID,
                entryWidth: existingTable.entryWidth,
                entries: combinedEntries
            )
            mappingTables[tableID] = updatedTable

        case .extendedDimensions:
            // Parse extended X/Y dimensions per ITU-T.87 §5.1.1.4.
            // Format: Ll(2) + Id(1) + Wxy(1) + XSIZE(Wxy bytes) + YSIZE(Wxy bytes)
            // remainingBytes = everything after Ll (2) and Id (1) that has already been read.
            let remainingBytes = Int(length) - 3
            guard remainingBytes >= 1 else {
                throw JPEGLSError.invalidBitstreamStructure(
                    reason: "Invalid LSE extended dimensions segment length: \(length)"
                )
            }
            let wxy = Int(try reader.readByte())
            // Wxy must be 1, 2, or 4 and the remaining bytes must be exactly 1 + 2*Wxy.
            guard (wxy == 1 || wxy == 2 || wxy == 4) && remainingBytes == 1 + 2 * wxy else {
                // Unsupported or malformed — skip remaining bytes gracefully.
                let skipLength = remainingBytes - 1
                if skipLength > 0 {
                    _ = try reader.readBytes(skipLength)
                }
                return
            }
            // Read XSIZE (image width) as Wxy bytes, big-endian.
            var xSize = 0
            for _ in 0..<wxy {
                xSize = (xSize << 8) | Int(try reader.readByte())
            }
            // Read YSIZE (image height) as Wxy bytes, big-endian.
            var ySize = 0
            for _ in 0..<wxy {
                ySize = (ySize << 8) | Int(try reader.readByte())
            }
            extendedWidth  = xSize
            extendedHeight = ySize
        }
    }

    /// Parse Define Restart Interval (DRI) marker segment per ITU-T.87 §5.1
    ///
    /// The DRI segment specifies the number of MCUs between restart markers.
    /// Length field is always 4 (2-byte length + 2-byte interval value).
    ///
    /// - Returns: Restart interval value (0 means restart markers are not used)
    private func parseRestartInterval() throws -> Int {
        let length = try reader.readUInt16()
        guard length == 4 else {
            throw JPEGLSError.invalidBitstreamStructure(
                reason: "Invalid DRI marker length: expected 4, got \(length)"
            )
        }
        return Int(try reader.readUInt16())
    }
}
