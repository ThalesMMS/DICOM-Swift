import Foundation

extension JPEGLosslessDecoder {
    // MARK: - Marker Parsing

    /// Parses all JPEG markers from the bitstream
    /// Extracts SOF3, DHT, and SOS marker data
    /// - Parameter data: JPEG bitstream
    /// Parses JPEG marker segments from the provided Data buffer until the Start of Scan (SOS) marker is encountered and records frame, Huffman table, and scan information for subsequent entropy decoding.
    /// - Parameter data: The complete JPEG marker stream to parse (should begin with the SOI marker).
    /// - Throws: `DICOMError.invalidDICOMFormat` when the stream does not start with SOI, a marker prefix is missing or malformed, a marker length is invalid or extends beyond the buffer, unexpected byte-stuffing (`0xFF 0x00`) appears in the marker section, or the data ends unexpectedly while scanning markers. May rethrow errors produced by `parseSOF3`, `parseDHT`, or `parseSOS`.
    func parseMarkers(data: Data) throws {
        var index = 0
        let endIndex = data.count

        // Expect SOI (Start of Image) marker at beginning
        guard index + 2 <= endIndex,
              data[index] == JPEGMarker.prefix,
              data[index + 1] == JPEGMarker.soi.rawValue else {
            throw DICOMError.invalidDICOMFormat(reason: "JPEG Lossless stream must start with SOI marker (0xFFD8)")
        }
        index += 2

        // Parse markers until SOS (Start of Scan)
        while index < endIndex {
            // Find next marker (0xFF followed by non-zero byte)
            guard index + 1 < endIndex else {
                throw DICOMError.invalidDICOMFormat(reason: "Unexpected end of data while parsing JPEG markers")
            }

            // Verify marker prefix
            guard data[index] == JPEGMarker.prefix else {
                throw DICOMError.invalidDICOMFormat(reason: "Expected marker prefix 0xFF at offset \(index), found 0x\(String(data[index], radix: 16))")
            }

            let markerType = data[index + 1]
            index += 2

            // Handle marker based on type
            if markerType == JPEGMarker.soi.rawValue {
                // SOI has no payload, already handled
                continue
            } else if markerType == JPEGMarker.eoi.rawValue {
                // EOI has no payload, marks end of image
                break
            } else if markerType == JPEGMarker.stuffingByte {
                // 0xFF 0x00 is byte stuffing in compressed data, should not appear here
                throw DICOMError.invalidDICOMFormat(reason: "Unexpected byte stuffing (0xFF 0x00) in marker section")
            }

            // All other markers have length field (2 bytes, big-endian, includes itself)
            guard index + 2 <= endIndex else {
                throw DICOMError.invalidDICOMFormat(reason: "Marker 0xFF\(String(markerType, radix: 16)) missing length field")
            }

            let length = Int(data[index]) << 8 | Int(data[index + 1])
            guard length >= 2 else {
                throw DICOMError.invalidDICOMFormat(reason: "Invalid marker length \(length) at offset \(index)")
            }

            let payloadLength = length - 2
            let payloadStart = index + 2
            let payloadEnd = payloadStart + payloadLength

            guard payloadEnd <= endIndex else {
                let markerName = markerType == JPEGMarker.dri.rawValue
                    ? "DRI marker"
                    : "Marker 0xFF\(String(markerType, radix: 16))"
                throw DICOMError.invalidDICOMFormat(
                    reason: "\(markerName) payload extends beyond data "
                        + "(needs \(payloadLength) bytes, \(endIndex - payloadStart) available)"
                )
            }

            // Parse marker payload
            switch markerType {
            case JPEGMarker.sof3.rawValue:
                sof3Info = try parseSOF3(data: data, offset: payloadStart, length: payloadLength)

            case JPEGMarker.dht.rawValue:
                try parseDHT(data: data, offset: payloadStart, length: payloadLength)

            case JPEGMarker.dri.rawValue:
                guard payloadLength == 2 else {
                    throw DICOMError.invalidDICOMFormat(
                        reason: "DRI marker payload must be exactly 2 bytes, found \(payloadLength)"
                    )
                }
                restartInterval = Int(data[payloadStart]) << 8 | Int(data[payloadStart + 1])

            case JPEGMarker.sos.rawValue:
                sosInfo = try parseSOS(data: data, offset: payloadStart, length: payloadLength)
                // Compressed data starts immediately after SOS header
                compressedDataStart = payloadEnd
                // Stop marker parsing, rest is entropy-coded data
                return

            default:
                // Unknown marker, skip payload
                logger?.debug("Skipping unknown JPEG marker 0xFF\(String(markerType, radix: 16)) with \(payloadLength) bytes")
            }

            index = payloadEnd
        }
    }

    /// Parses Start of Frame (SOF3) marker for lossless JPEG
    /// - Parameters:
    ///   - data: JPEG data
    ///   - offset: Start of SOF3 payload
    ///   - length: Length of SOF3 payload
    /// - Returns: Parsed SOF3 information
    /// Parses an SOF3 (lossless Start Of Frame) segment and returns frame geometry and component specifications.
    /// - Parameters:
    ///   - data: The full JPEG marker segment buffer containing the SOF3 payload.
    ///   - offset: Byte offset in `data` where the SOF3 payload starts.
    ///   - length: Length in bytes of the SOF3 payload starting at `offset`.
    /// - Returns: A `SOF3Info` populated with image `width`, `height`, `precision`, `numberOfComponents`, and per-component `ComponentSpec` entries.
    /// - Throws: `DICOMError.invalidDICOMFormat` when the payload is too short, when `width` or `height` are not greater than zero, when `precision` is not one of 8, 12, or 16, or when the payload does not contain the expected component specification bytes.
    private func parseSOF3(data: Data, offset: Int, length: Int) throws -> SOF3Info {
        guard length >= 6 else {
            throw DICOMError.invalidDICOMFormat(reason: "SOF3 payload too short (\(length) bytes)")
        }

        let precision = Int(data[offset])
        let height = Int(data[offset + 1]) << 8 | Int(data[offset + 2])
        let width = Int(data[offset + 3]) << 8 | Int(data[offset + 4])
        let numberOfComponents = Int(data[offset + 5])

        // Validate dimensions
        guard width > 0, height > 0 else {
            throw DICOMError.invalidDICOMFormat(reason: "Invalid SOF3 dimensions: \(width)×\(height)")
        }

        // Validate precision
        guard (2...16).contains(precision) else {
            throw DICOMError.invalidDICOMFormat(reason: "Unsupported SOF3 precision: \(precision) bits (T.81 lossless allows 2...16)")
        }

        // Parse component specifications
        let componentDataLength = numberOfComponents * 3
        guard length >= 6 + componentDataLength else {
            throw DICOMError.invalidDICOMFormat(reason: "SOF3 payload too short for \(numberOfComponents) components")
        }

        var components: [ComponentSpec] = []
        var pos = offset + 6

        for _ in 0..<numberOfComponents {
            let id = data[pos]
            let samplingFactors = data[pos + 1]
            let qtableSelector = data[pos + 2]

            let hSampling = (samplingFactors >> 4) & 0x0F
            let vSampling = samplingFactors & 0x0F

            components.append(ComponentSpec(
                id: id,
                horizontalSamplingFactor: hSampling,
                verticalSamplingFactor: vSampling,
                quantizationTableSelector: qtableSelector
            ))

            pos += 3
        }

        logger?.debug("SOF3: \(width)×\(height), \(precision)-bit, \(numberOfComponents) component(s)")

        return SOF3Info(
            width: width,
            height: height,
            precision: precision,
            numberOfComponents: numberOfComponents,
            components: components
        )
    }

    /// Parses Define Huffman Table (DHT) marker
    /// May contain multiple Huffman table definitions
    /// - Parameters:
    ///   - data: JPEG data
    ///   - offset: Start of DHT payload
    ///   - length: Length of DHT payload
    /// Parses one or more Huffman table definitions from a DHT marker payload and stores constructed decoding tables in `huffmanTables`.
    /// 
    /// The function reads repeated table definitions starting at `offset` for `length` bytes. For each table it extracts the table class and id, the 16 symbol-count bytes for code lengths 1..16, the symbol value bytes, builds decoding structures via `buildHuffmanDecodingTables(table:)`, and inserts the resulting `HuffmanTable` into `huffmanTables`.
    /// - Parameters:
    ///   - data: The full JPEG segment buffer containing the DHT payload.
    ///   - offset: The start index of the DHT payload within `data`.
    ///   - length: The length in bytes of the DHT payload.
    /// - Throws: `DICOMError.invalidDICOMFormat` if the payload is truncated, if a table declares more than 256 symbols, or if symbol values extend beyond the provided payload.
    private func parseDHT(data: Data, offset: Int, length: Int) throws {
        var pos = offset
        let endPos = offset + length

        // DHT marker can contain multiple table definitions
        while pos < endPos {
            guard pos + 17 <= endPos else {
                throw DICOMError.invalidDICOMFormat(reason: "DHT payload truncated at offset \(pos)")
            }

            // Table class and ID packed in single byte
            let tableInfo = data[pos]
            let tableClass = (tableInfo >> 4) & 0x0F  // High nibble: 0=DC, 1=AC
            let tableId = tableInfo & 0x0F            // Low nibble: 0-3
            pos += 1

            // Read symbol counts for each bit length (1-16)
            var symbolCounts: [UInt8] = []
            var totalSymbols = 0
            for _ in 0..<16 {
                let count = data[pos]
                symbolCounts.append(count)
                totalSymbols += Int(count)
                pos += 1
            }

            // Validate symbol count
            guard totalSymbols <= 256 else {
                throw DICOMError.invalidDICOMFormat(reason: "DHT table has too many symbols: \(totalSymbols) (max 256)")
            }

            // Read symbol values
            guard pos + totalSymbols <= endPos else {
                throw DICOMError.invalidDICOMFormat(reason: "DHT symbol values extend beyond payload")
            }

            var symbolValues: [UInt8] = []
            for _ in 0..<totalSymbols {
                symbolValues.append(data[pos])
                pos += 1
            }

            // Store Huffman table and build decoding tables
            let tableKey = Int(tableClass) << 4 | Int(tableId)
            var table = HuffmanTable(
                tableClass: tableClass,
                tableId: tableId,
                symbolCounts: symbolCounts,
                symbolValues: symbolValues
            )

            // Build Huffman decoding tables (minCode, maxCode, valPtr arrays)
            buildHuffmanDecodingTables(table: &table)

            huffmanTables[tableKey] = table

            logger?.debug("DHT: class=\(tableClass), id=\(tableId), symbols=\(totalSymbols)")
        }
    }

    /// Parses Start of Scan (SOS) marker
    /// - Parameters:
    ///   - data: JPEG data
    ///   - offset: Start of SOS payload
    ///   - length: Length of SOS payload
    /// - Returns: Parsed SOS information
    /// Parses a Start Of Scan (SOS) segment and returns its decoded scan parameters and component selectors.
    /// - Parameters:
    ///   - data: JPEG marker segment buffer containing the SOS payload.
    ///   - offset: Byte offset in `data` where the SOS payload begins.
    ///   - length: Length in bytes of the SOS payload.
    /// - Returns: An `SOSInfo` populated with the number of components, per-component DC/AC table selectors, selection (predictor) value, spectral start/end, and successive approximation high/low values.
    /// - Throws: `DICOMError.invalidDICOMFormat` when the payload is too short, the component count is outside 1...4, or the payload does not contain the declared component selector and scan parameter bytes.
    private func parseSOS(data: Data, offset: Int, length: Int) throws -> SOSInfo {
        guard length >= 4 else {
            throw DICOMError.invalidDICOMFormat(reason: "SOS payload too short (\(length) bytes)")
        }

        let numberOfComponents = Int(data[offset])

        // Validate component count
        guard numberOfComponents > 0, numberOfComponents <= 4 else {
            throw DICOMError.invalidDICOMFormat(reason: "Invalid SOS component count: \(numberOfComponents)")
        }

        // Each component has 2 bytes (ID + entropy table selectors)
        let componentDataLength = numberOfComponents * 2
        guard length >= 1 + componentDataLength + 3 else {
            throw DICOMError.invalidDICOMFormat(reason: "SOS payload too short for \(numberOfComponents) components")
        }

        // Parse component selectors
        var components: [ScanComponentSelector] = []
        var pos = offset + 1

        for _ in 0..<numberOfComponents {
            let componentId = data[pos]
            let entropySelectors = data[pos + 1]

            let dcTable = (entropySelectors >> 4) & 0x0F
            let acTable = entropySelectors & 0x0F

            components.append(ScanComponentSelector(
                componentId: componentId,
                dcTableSelector: dcTable,
                acTableSelector: acTable
            ))

            pos += 2
        }

        // Parse scan parameters
        let startSpectral = Int(data[pos])        // Ss: Selection value (predictor ID)
        let endSpectral = Int(data[pos + 1])      // Se: Must be 0 for lossless
        let successiveApprox = data[pos + 2]      // Ah (high nibble), Al (low nibble)

        let approxHigh = (successiveApprox >> 4) & 0x0F
        let approxLow = successiveApprox & 0x0F

        logger?.debug("SOS: components=\(numberOfComponents), selectionValue=\(startSpectral)")

        return SOSInfo(
            numberOfComponents: numberOfComponents,
            components: components,
            selectionValue: startSpectral,
            startSpectral: startSpectral,
            endSpectral: endSpectral,
            successiveApproximationHigh: approxHigh,
            successiveApproximationLow: approxLow
        )
    }

    // MARK: - Validation

    /// Validates parsed frame parameters against JPEG Lossless requirements
    /// - Parameters:
    ///   - sof3: Start of Frame information
    ///   - sos: Start of Scan information
    /// Validates SOF3 and SOS frame parameters for lossless JPEG and ensures referenced Huffman tables exist.
    /// 
    /// Performs checks required for lossless JPEG decoding: matching component counts, lossless-specific scan parameters,
    /// a valid predictor selection value, and presence of referenced DC Huffman tables. Logs informational messages
    /// for non-fatal conditions (e.g., selection value not equal to 1 or multi-component frames).
    /// - Parameters:
    ///   - sof3: Parsed SOF3 frame information containing precision, dimensions, and component specifications.
    ///   - sos: Parsed SOS scan information containing component selectors and scan parameters.
    /// - Throws: `DICOMError.invalidDICOMFormat` when any of the following conditions are violated:
    ///   - SOF3 and SOS declare a different number of components.
    ///   - SOS `endSpectral` (Se) is not 0 for lossless mode.
    ///   - SOS `successiveApproximationHigh`/`successiveApproximationLow` (Ah/Al) are not both 0.
    ///   - SOS `selectionValue` (predictor) is outside the range 0–7.
    ///   - Any SOS component references an undefined DC Huffman table.
    func validateFrameParameters(sof3: SOF3Info, sos: SOSInfo) throws {
        // Validate component count matches
        guard sof3.numberOfComponents == sos.numberOfComponents else {
            throw DICOMError.invalidDICOMFormat(reason: "Component count mismatch: SOF3=\(sof3.numberOfComponents), SOS=\(sos.numberOfComponents)")
        }

        // Validate lossless mode parameters
        guard sos.endSpectral == 0 else {
            throw DICOMError.invalidDICOMFormat(reason: "SOS Se (end spectral) must be 0 for lossless mode, found \(sos.endSpectral)")
        }

        guard sos.successiveApproximationHigh == 0 else {
            throw DICOMError.invalidDICOMFormat(reason: "SOS Ah (successive approximation high) must be 0 for lossless mode")
        }
        guard Int(sos.successiveApproximationLow) < sof3.precision else {
            throw DICOMError.invalidDICOMFormat(
                reason: "SOS Al (point transform) \(sos.successiveApproximationLow) must be below the sample precision \(sof3.precision)"
            )
        }

        // Validate selection value (predictor ID)
        guard sos.selectionValue >= 0, sos.selectionValue <= 7 else {
            throw DICOMError.invalidDICOMFormat(reason: "Invalid SOS selection value (predictor): \(sos.selectionValue) (must be 0-7)")
        }

        // For DICOM Transfer Syntax 1.2.840.10008.1.2.4.70, selection value must be 1
        // (this is informational, we support other selection values too)
        if sos.selectionValue != 1 {
            logger?.debug("Selection value \(sos.selectionValue) detected (DICOM TS 1.2.840.10008.1.2.4.70 requires 1)")
        }

        // Verify referenced Huffman tables exist
        for component in sos.components {
            let dcTableKey = 0 << 4 | Int(component.dcTableSelector)
            guard huffmanTables[dcTableKey] != nil else {
                throw DICOMError.invalidDICOMFormat(reason: "SOS references undefined Huffman table: class=0, id=\(component.dcTableSelector)")
            }
        }

        // DICOM typically uses single-component (grayscale) for lossless
        if sof3.numberOfComponents > 1 {
            logger?.debug("Multi-component image detected (\(sof3.numberOfComponents) components)")
        }
    }

}
