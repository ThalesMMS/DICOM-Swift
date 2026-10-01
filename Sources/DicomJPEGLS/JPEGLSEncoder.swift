// Modified for Isis from JLSwift 299b9a2 (Apache-2.0); the modifications are recorded in Git.

/// High-level JPEG-LS encoder API
///
/// Provides a simple interface to encode raw pixel data to JPEG-LS format.
/// Handles all aspects of JPEG-LS file generation including markers, headers,
/// and bitstream encoding.

import Foundation

/// High-level JPEG-LS encoder
///
/// Encodes multi-component image data to JPEG-LS file format per ITU-T.87.
/// Supports all encoding modes (lossless, near-lossless) and interleaving modes.
///
/// **Example usage:**
/// ```swift
/// // Create encoder
/// let encoder = JPEGLSEncoder()
///
/// // Prepare image data
/// let imageData = try MultiComponentImageData.grayscale(
///     pixels: pixels,
///     bitsPerSample: 8
/// )
///
/// // Encode to JPEG-LS
/// let jpegLSData = try encoder.encode(
///     imageData,
///     near: 0,  // Lossless
///     interleaveMode: .none
/// )
/// ```
/// Lock-protected accumulator for parallel restart-interval encoding:
/// each worker stores its interval's bytes at its own index, and the first
/// error (if any) wins.
private final class IntervalEncodeResults: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [Data?]
    private var firstError: Error?

    init(count: Int) {
        self.data = Array(repeating: nil, count: count)
    }

    func set(_ chunk: Data, at index: Int) {
        lock.lock()
        data[index] = chunk
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        if firstError == nil { firstError = error }
        lock.unlock()
    }

    func finish() throws -> [Data?] {
        lock.lock()
        defer { lock.unlock() }
        if let firstError { throw firstError }
        return data
    }
}

public struct JPEGLSEncoder: Sendable {
    /// Configuration for encoding
    public struct Configuration: Sendable {
        /// NEAR parameter for near-lossless encoding (0 = lossless)
        public let near: Int

        /// Interleaving mode for multi-component images
        public let interleaveMode: JPEGLSInterleaveMode

        /// Optional custom preset parameters
        public let presetParameters: JPEGLSPresetParameters?

        /// Colour transformation applied before encoding (default: .none).
        ///
        /// When a transformation other than `.none` is specified the encoder:
        ///   1. Writes an APP8 "mrfx" marker so decoders can invert the transform.
        ///   2. Applies the forward transform (with modular arithmetic) to every
        ///      pixel before the JPEG-LS codec runs.
        public let colorTransformation: JPEGLSColorTransformation

        /// Optional mapping table for palettised (indexed-colour) encoding per ITU-T.87 §5.1.1.3.
        ///
        /// When set the encoder writes an LSE type 2 marker before the scan and sets the
        /// mapping-table ID in every scan component selector so that decoders apply the
        /// palette lookup after decoding.  Use this to encode images whose sample values
        /// are palette indices rather than direct intensities.
        ///
        /// Supported for single- and multi-component images.  All components in the scan
        /// will reference the same mapping table.
        public let mappingTable: JPEGLSMappingTable?

        /// Restart interval in sample lines (0 = no restart markers, the default).
        ///
        /// When > 0 the encoder writes a DRI marker segment and emits an RSTm
        /// marker (cycling FFD0–FFD7) after every `restartInterval` lines of
        /// each scan.  Per ITU-T.87, the coding state — contexts, run state,
        /// bit alignment, and the previous-line prediction — resets at every
        /// interval boundary, which makes intervals independently decodable
        /// (and lets the encoder process them in parallel) at a small
        /// compression-ratio cost.
        ///
        /// Currently supported for lossless (NEAR = 0), non-interleaved scans.
        public let restartInterval: Int

        /// Initialize encoding configuration
        ///
        /// ```swift
        /// // Lossless encoding with sample interleaving and HP1 colour transform
        /// let config = try JPEGLSEncoder.Configuration(
        ///     near: 0,
        ///     interleaveMode: .sample,
        ///     colorTransformation: .hp1
        /// )
        ///
        /// // Near-lossless encoding with custom preset parameters
        /// let preset = try JPEGLSPresetParameters.defaultParameters(bitsPerSample: 8, near: 3)
        /// let nearConfig = try JPEGLSEncoder.Configuration(
        ///     near: 3,
        ///     interleaveMode: .line,
        ///     presetParameters: preset
        /// )
        ///
        /// // Palettised encoding with a 4-entry greyscale mapping table
        /// let palette = try JPEGLSMappingTable(id: 1, entryWidth: 1, entries: [0, 85, 170, 255])
        /// let paletteConfig = try JPEGLSEncoder.Configuration(mappingTable: palette)
        /// ```
        ///
        /// - Parameters:
        ///   - near: NEAR parameter (0 = lossless, 1-255 = near-lossless)
        ///   - interleaveMode: Interleaving mode for multi-component images
        ///   - presetParameters: Optional custom preset parameters (uses defaults if nil)
        ///   - colorTransformation: Colour transform to apply before encoding (default: .none)
        ///   - mappingTable: Optional mapping table for palettised encoding (default: nil)
        ///   - restartInterval: Restart interval in lines (0 = off; lossless non-interleaved only)
        /// - Throws: `JPEGLSError.invalidNearParameter` if NEAR is out of range,
        ///   `JPEGLSError.encodingFailed` if the restart interval is invalid or
        ///   combined with an unsupported mode
        public init(
            near: Int = 0,
            interleaveMode: JPEGLSInterleaveMode = .none,
            presetParameters: JPEGLSPresetParameters? = nil,
            colorTransformation: JPEGLSColorTransformation = .none,
            mappingTable: JPEGLSMappingTable? = nil,
            restartInterval: Int = 0
        ) throws {
            guard near >= 0 && near <= 255 else {
                throw JPEGLSError.invalidNearParameter(near: near)
            }
            guard (0...65535).contains(restartInterval) else {
                throw JPEGLSError.encodingFailed(
                    reason: "Restart interval must be in 0...65535 lines, got \(restartInterval)"
                )
            }
            if restartInterval > 0 {
                guard near == 0 else {
                    throw JPEGLSError.encodingFailed(
                        reason: "Restart intervals are currently supported for lossless (NEAR = 0) encoding only"
                    )
                }
                guard interleaveMode == .none else {
                    throw JPEGLSError.encodingFailed(
                        reason: "Restart intervals are currently supported for non-interleaved scans only"
                    )
                }
            }

            self.near = near
            self.interleaveMode = interleaveMode
            self.presetParameters = presetParameters
            self.colorTransformation = colorTransformation
            self.mappingTable = mappingTable
            self.restartInterval = restartInterval
        }
    }

    /// Initialize encoder
    public init() {}

    /// Encode image data to JPEG-LS format
    ///
    /// ```swift
    /// let encoder = JPEGLSEncoder()
    ///
    /// // Lossless greyscale encoding
    /// let imageData = try MultiComponentImageData.grayscale(pixels: pixels, bitsPerSample: 8)
    /// let config = try JPEGLSEncoder.Configuration(near: 0, interleaveMode: .none)
    /// let jpegLSData = try encoder.encode(imageData, configuration: config)
    ///
    /// // Near-lossless RGB encoding with sample interleaving
    /// let rgbData = try MultiComponentImageData.rgb(
    ///     redPixels: red, greenPixels: green, bluePixels: blue, bitsPerSample: 8
    /// )
    /// let rgbConfig = try JPEGLSEncoder.Configuration(near: 3, interleaveMode: .sample)
    /// let rgbJLS = try encoder.encode(rgbData, configuration: rgbConfig)
    /// ```
    ///
    /// - Parameters:
    ///   - imageData: Multi-component image data to encode
    ///   - configuration: Encoding configuration
    /// - Returns: JPEG-LS encoded data
    /// - Throws: `JPEGLSError` if encoding fails
    public func encode(
        _ imageData: MultiComponentImageData,
        configuration: Configuration
    ) throws -> Data {
        // Colour transforms and scan encoders iterate each plane at the full frame
        // dimensions through unsafe buffers; sub-sampled (narrower/shorter)
        // planes would read out of bounds, so reject them up front.
        let frame = imageData.frameHeader
        for component in imageData.components {
            guard component.pixels.count == frame.height,
                  component.pixels.allSatisfy({ $0.count == frame.width }) else {
                throw JPEGLSError.encodingFailed(
                    reason: "Sub-sampled component planes are not supported by the encoder (component \(component.id) is not \(frame.width)×\(frame.height))"
                )
            }
        }

        // Pre-allocate the bitstream buffer based on raw image size.
        // For lossless encoding the compressed size is at most the raw pixel data size;
        // adding a small fixed overhead for markers and headers avoids reallocation in
        // typical cases.
        let bitsPerSample = imageData.frameHeader.bitsPerSample
        let bytesPerSample = (bitsPerSample + 7) / 8
        let estimatedCapacity = imageData.frameHeader.width *
                                imageData.frameHeader.height *
                                imageData.frameHeader.componentCount *
                                bytesPerSample + 4096
        let writer = JPEGLSBitstreamWriter(capacity: estimatedCapacity)

        // Write SOI marker (Start of Image)
        writer.writeMarker(.startOfImage)

        // Write APP8 "mrfx" colour-transform marker when a transform is requested.
        // This must appear before the SOF so that decoders can read it and invert the transform.
        let colorTransformation = configuration.colorTransformation
        if colorTransformation != .none {
            writeColorTransformMarker(colorTransformation, to: writer)
        }

        // Apply forward colour transform to pixel data (modular arithmetic keeps
        // values within [0, MAXVAL] for storage in MultiComponentImageData).
        let maxValue = (1 << imageData.frameHeader.bitsPerSample) - 1
        let encodingData = colorTransformation != .none
            ? try applyForwardColorTransform(imageData, transformation: colorTransformation, maxValue: maxValue)
            : imageData

        // Resolve preset parameters (custom or default) and validate
        // MAXVAL ≤ 2^P − 1 (ITU-T.87 C.2.4.1.1): LIMIT is derived from the
        // frame's bits-per-sample while qbpp comes from MAXVAL, and a larger
        // MAXVAL makes the limited-code threshold negative (trapping, or
        // emitting a stream no decoder can parse).
        let parameters = try configuration.presetParameters ?? JPEGLSPresetParameters.defaultParameters(
            bitsPerSample: encodingData.frameHeader.bitsPerSample,
            near: configuration.near
        )
        let frameSampleCap = (1 << frame.bitsPerSample) - 1
        guard parameters.maxValue <= frameSampleCap else {
            throw JPEGLSError.invalidPresetParameters(
                reason: "MAXVAL \(parameters.maxValue) exceeds 2^P−1 = \(frameSampleCap) for \(frame.bitsPerSample)-bit samples"
            )
        }

        // Write LSE type 4 (extended dimensions) before SOF when either dimension > 65535
        // per ITU-T.87 §5.1.1.4.
        if frame.width > 65535 || frame.height > 65535 {
            writeExtendedDimensions(frame, to: writer)
        }

        // Write frame header (SOF55)
        try writeFrameHeader(encodingData.frameHeader, to: writer)

        // Write preset parameters if custom or near-lossless
        if configuration.presetParameters != nil || configuration.near > 0 {
            try writePresetParameters(parameters, to: writer)
        }

        // Write mapping table (LSE type 2/3) if a palette is specified (Part 2 §5.1.1.3).
        let mappingTableID: UInt8 = configuration.mappingTable?.id ?? 0
        if let table = configuration.mappingTable {
            writeMappingTable(table, to: writer)
        }

        // Write DRI (define restart interval) when restart markers are enabled.
        if configuration.restartInterval > 0 {
            writer.writeMarker(.defineRestartInterval)
            writer.writeUInt16(4)  // segment length including the length field
            writer.writeUInt16(UInt16(configuration.restartInterval))
        }

        // Encode scan(s) based on interleave mode
        switch configuration.interleaveMode {
        case .none:
            // Non-interleaved: one scan per component
            for component in encodingData.components {
                try encodeScan(
                    imageData: encodingData,
                    componentIDs: [component.id],
                    mappingTableID: mappingTableID,
                    configuration: configuration,
                    parameters: parameters,
                    writer: writer
                )
            }

        case .line, .sample:
            // Interleaved: single scan with all components
            let componentIDs = encodingData.components.map { $0.id }
            try encodeScan(
                imageData: encodingData,
                componentIDs: componentIDs,
                mappingTableID: mappingTableID,
                configuration: configuration,
                parameters: parameters,
                writer: writer
            )
        }

        // Write EOI marker (End of Image)
        writer.writeMarker(.endOfImage)

        return try writer.getData()
    }

    /// Convenience method to encode with individual parameters
    ///
    /// ```swift
    /// let encoder = JPEGLSEncoder()
    /// let imageData = try MultiComponentImageData.grayscale(pixels: pixels, bitsPerSample: 8)
    ///
    /// // Lossless encoding (default)
    /// let lossless = try encoder.encode(imageData)
    ///
    /// // Near-lossless encoding with NEAR=3
    /// let nearLossless = try encoder.encode(imageData, near: 3)
    /// ```
    ///
    /// - Parameters:
    ///   - imageData: Multi-component image data to encode
    ///   - near: NEAR parameter (0 = lossless, 1-255 = near-lossless)
    ///   - interleaveMode: Interleaving mode
    /// - Returns: JPEG-LS encoded data
    /// - Throws: `JPEGLSError` if encoding fails
    public func encode(
        _ imageData: MultiComponentImageData,
        near: Int = 0,
        interleaveMode: JPEGLSInterleaveMode = .none
    ) throws -> Data {
        let config = try Configuration(near: near, interleaveMode: interleaveMode)
        return try encode(imageData, configuration: config)
    }

    // MARK: - Private Methods

    /// Write an APP8 "mrfx" colour-transform marker to the bitstream.
    ///
    /// Format per ISO/IEC 14495-2 Annex A:
    ///   FF E8  — APP8 marker
    ///   00 07  — segment length (7 bytes including the length field)
    ///   "mrfx" — four-byte identifier (0x6D 0x72 0x66 0x78)
    ///   id     — one-byte transform code (matches JPEGLSColorTransformation.rawValue)
    ///
    /// - Parameters:
    ///   - transformation: Colour transform to signal.
    ///   - writer: Destination bitstream writer.
    private func writeColorTransformMarker(
        _ transformation: JPEGLSColorTransformation,
        to writer: JPEGLSBitstreamWriter
    ) {
        var payload = Data()
        // "mrfx" identifier
        payload.append(0x6D)  // 'm'
        payload.append(0x72)  // 'r'
        payload.append(0x66)  // 'f'
        payload.append(0x78)  // 'x'
        // Transform ID
        payload.append(transformation.rawValue)
        writer.writeMarkerSegment(marker: .applicationMarker8, payload: payload)
    }

    /// Apply the forward colour transform to all pixels in the image.
    ///
    /// Returns a new `MultiComponentImageData` whose pixel values are the transformed
    /// versions of the originals.  Modular arithmetic is used so that every value
    /// stays within [0, maxValue] and can be stored in the pixel buffer without
    /// failing the range-validation checks.
    ///
    /// - Parameters:
    ///   - imageData: Original image data with untransformed pixels.
    ///   - transformation: Colour transform to apply.
    ///   - maxValue: MAXVAL for the image (used for modular arithmetic).
    /// - Returns: New image data with transformed pixels.
    /// - Throws: `JPEGLSError` if the transform is not valid for the component count.
    private func applyForwardColorTransform(
        _ imageData: MultiComponentImageData,
        transformation: JPEGLSColorTransformation,
        maxValue: Int
    ) throws -> MultiComponentImageData {
        guard transformation != .none else { return imageData }
        guard transformation.isValid(forComponentCount: imageData.frameHeader.componentCount) else {
            throw JPEGLSError.encodingFailed(
                reason: "Colour transformation \(transformation) is invalid for \(imageData.frameHeader.componentCount) components"
            )
        }

        let componentCount = imageData.components.count
        let height = imageData.frameHeader.height
        let width  = imageData.frameHeader.width

        // Build mutable per-component pixel arrays
        var transformedPixels = imageData.components.map { $0.pixels }

        // Transform each pixel position across all components simultaneously
        for row in 0..<height {
            for col in 0..<width {
                let original = (0..<componentCount).map { transformedPixels[$0][row][col] }
                let result = try transformation.transformForward(original, maxValue: maxValue)
                for idx in 0..<componentCount {
                    transformedPixels[idx][row][col] = result[idx]
                }
            }
        }

        // Reconstruct ComponentData array preserving component IDs
        let transformedComponents = imageData.components.enumerated().map { (idx, comp) in
            MultiComponentImageData.ComponentData(id: comp.id, pixels: transformedPixels[idx])
        }

        return try MultiComponentImageData(
            components: transformedComponents,
            frameHeader: imageData.frameHeader
        )
    }

    private func writeFrameHeader(
        _ frameHeader: JPEGLSFrameHeader,
        to writer: JPEGLSBitstreamWriter
    ) throws {
        writer.writeMarker(.startOfFrameJPEGLS)

        // Length: 8 + 3 * componentCount
        let length = UInt16(8 + 3 * frameHeader.componentCount)
        writer.writeUInt16(length)

        // Precision (bits per sample)
        writer.writeByte(UInt8(frameHeader.bitsPerSample))

        // Dimensions — use 0 for any dimension > 65535 (encoded in preceding LSE type 4)
        writer.writeUInt16(UInt16(frameHeader.height > 65535 ? 0 : frameHeader.height))
        writer.writeUInt16(UInt16(frameHeader.width  > 65535 ? 0 : frameHeader.width))

        // Component count
        writer.writeByte(UInt8(frameHeader.componentCount))

        // Component specifications
        for component in frameHeader.components {
            writer.writeByte(component.id)
            // Sampling factors combined into single byte: (H << 4) | V
            let samplingByte = (component.horizontalSamplingFactor << 4) | component.verticalSamplingFactor
            writer.writeByte(samplingByte)
            writer.writeByte(0)  // Quantization table ID (unused in JPEG-LS, always 0)
        }
    }

    /// Write preset parameters (LSE) to bitstream
    private func writePresetParameters(
        _ parameters: JPEGLSPresetParameters,
        to writer: JPEGLSBitstreamWriter
    ) throws {
        writer.writeMarker(.jpegLSExtension)

        // Length: 13 bytes (marker type + parameters)
        writer.writeUInt16(13)

        // LSE marker type: 1 (preset parameters)
        writer.writeByte(1)

        // MAXVAL
        writer.writeUInt16(UInt16(parameters.maxValue))

        // T1, T2, T3
        writer.writeUInt16(UInt16(parameters.threshold1))
        writer.writeUInt16(UInt16(parameters.threshold2))
        writer.writeUInt16(UInt16(parameters.threshold3))

        // RESET
        writer.writeUInt16(UInt16(parameters.reset))
    }

    /// Write extended dimensions LSE type 4 marker segment per ITU-T.87 §5.1.1.4.
    ///
    /// Emitted before the SOF marker when either image dimension exceeds 65535.
    /// The corresponding SOF fields for those dimensions will contain 0.
    ///
    /// - Parameters:
    ///   - frameHeader: Frame header whose dimensions should be encoded.
    ///   - writer: Destination bitstream writer.
    private func writeExtendedDimensions(_ frameHeader: JPEGLSFrameHeader, to writer: JPEGLSBitstreamWriter) {
        var payload = Data()
        payload.append(JPEGLSExtensionType.extendedDimensions.rawValue)  // Id = 0x04
        payload.append(4)  // Wxy = 4 (32-bit dimensions)
        // XSIZE (width) as 4 bytes big-endian
        payload.append(UInt8((frameHeader.width >> 24) & 0xFF))
        payload.append(UInt8((frameHeader.width >> 16) & 0xFF))
        payload.append(UInt8((frameHeader.width >> 8) & 0xFF))
        payload.append(UInt8(frameHeader.width & 0xFF))
        // YSIZE (height) as 4 bytes big-endian
        payload.append(UInt8((frameHeader.height >> 24) & 0xFF))
        payload.append(UInt8((frameHeader.height >> 16) & 0xFF))
        payload.append(UInt8((frameHeader.height >> 8) & 0xFF))
        payload.append(UInt8(frameHeader.height & 0xFF))
        writer.writeMarkerSegment(marker: .jpegLSExtension, payload: payload)
    }

    /// Write a mapping table (LSE type 2) to the bitstream.
    ///
    /// Emits an LSE marker segment containing the mapping table specification.
    /// If the table has more entries than can fit in a single LSE segment
    /// (maximum payload ≈ 65530 bytes), the remainder is emitted as LSE type 3
    /// (mapping table continuation) segments.
    ///
    /// - Parameters:
    ///   - table: The mapping table to write.
    ///   - writer: Destination bitstream writer.
    func writeMappingTable(
        _ table: JPEGLSMappingTable,
        to writer: JPEGLSBitstreamWriter
    ) {
        let entryWidth = table.entryWidth
        // Maximum entry bytes per segment. Ll is UInt16 (max 65535).
        // Overhead for type 2: 1 (Id) + 1 (TID) + 1 (Wt) = 3 bytes counted in Ll.
        // (Ll itself = 2 bytes also counted.) Max payload = 65535 - 2 - 3 = 65530 bytes.
        let maxDataBytesPerSegment = 65530
        let maxEntriesPerSegment = maxDataBytesPerSegment / entryWidth

        // Always emit at least one LSE type 2 segment (even for an empty table, to
        // declare the table ID and entry width).  Subsequent chunks are emitted as
        // LSE type 3 (mapping table continuation) segments.
        let chunks: [ArraySlice<Int>]
        if table.entries.isEmpty {
            chunks = [table.entries[0..<0]]
        } else {
            var slices: [ArraySlice<Int>] = []
            var start = 0
            while start < table.entries.count {
                let end = min(start + maxEntriesPerSegment, table.entries.count)
                slices.append(table.entries[start..<end])
                start = end
            }
            chunks = slices
        }

        for (chunkIndex, chunk) in chunks.enumerated() {
            // Build the segment payload without byte stuffing.
            // Marker-segment payloads are raw data; stuffing only applies to scan data.
            var payload = Data()
            if chunkIndex == 0 {
                // LSE type 2: Id + TID + Wt + entries
                payload.append(JPEGLSExtensionType.mappingTable.rawValue)
                payload.append(table.id)
                payload.append(UInt8(entryWidth))
            } else {
                // LSE type 3: Id + TID + entries
                payload.append(JPEGLSExtensionType.mappingTableContinuation.rawValue)
                payload.append(table.id)
            }
            for entry in chunk {
                if entryWidth == 1 {
                    payload.append(UInt8(entry & 0xFF))
                } else {
                    payload.append(UInt8((entry >> 8) & 0xFF))
                    payload.append(UInt8(entry & 0xFF))
                }
            }
            // writeMarkerSegment writes raw payload bytes without marker stuffing,
            // which is correct for all JPEG marker-segment payloads.
            writer.writeMarkerSegment(marker: .jpegLSExtension, payload: payload)
        }
    }

    /// Encode a single scan
    private func encodeScan(
        imageData: MultiComponentImageData,
        componentIDs: [UInt8],
        mappingTableID: UInt8 = 0,
        configuration: Configuration,
        parameters: JPEGLSPresetParameters,
        writer: JPEGLSBitstreamWriter
    ) throws {
        // Create scan header
        let scanHeader = try JPEGLSScanHeader(
            componentCount: componentIDs.count,
            components: componentIDs.map { id in
                JPEGLSScanHeader.ComponentSelector(id: id, mappingTableID: mappingTableID)
            },
            near: configuration.near,
            interleaveMode: configuration.interleaveMode,
            pointTransform: 0
        )

        // Write scan header (SOS)
        try writeScanHeader(scanHeader, to: writer)

        // Encode scan data
        try encodeScanData(
            imageData: imageData,
            scanHeader: scanHeader,
            parameters: parameters,
            writer: writer,
            restartInterval: configuration.restartInterval
        )
    }

    /// Write scan header (SOS) to bitstream
    private func writeScanHeader(
        _ scanHeader: JPEGLSScanHeader,
        to writer: JPEGLSBitstreamWriter
    ) throws {
        writer.writeMarker(.startOfScan)

        // Length: 6 + 2 * componentCount
        let length = UInt16(6 + 2 * scanHeader.componentCount)
        writer.writeUInt16(length)

        // Component count
        writer.writeByte(UInt8(scanHeader.componentCount))

        // Component selectors
        for component in scanHeader.components {
            writer.writeByte(component.id)
            // Tdi field: mapping table ID (0 = no mapping table) per ITU-T.87 §5.1.2.
            writer.writeByte(component.mappingTableID)
        }

        // NEAR parameter
        writer.writeByte(UInt8(scanHeader.near))

        // Interleave mode (ILV)
        let ilv: UInt8 = switch scanHeader.interleaveMode {
        case .none: 0
        case .line: 1
        case .sample: 2
        }
        writer.writeByte(ilv)

        // Point transform (0 for lossless)
        writer.writeByte(UInt8(scanHeader.pointTransform))
    }

    /// Encode scan data (the actual pixel encoding)
    private func encodeScanData(
        imageData: MultiComponentImageData,
        scanHeader: JPEGLSScanHeader,
        parameters: JPEGLSPresetParameters,
        writer: JPEGLSBitstreamWriter,
        restartInterval: Int = 0
    ) throws {
        // Create pixel buffer
        let buffer = JPEGLSPixelBuffer(imageData: imageData)

        // Create context model
        var context = try JPEGLSContextModel(parameters: parameters, near: scanHeader.near)

        // Create regular mode encoder
        let regularMode = try JPEGLSRegularMode(
            parameters: parameters,
            near: scanHeader.near
        )

        // Create run mode encoder
        let runMode = try JPEGLSRunMode(
            parameters: parameters,
            near: scanHeader.near
        )

        // Compute Golomb-Rice LIMIT parameters per ITU-T.87 §4.4
        let (limit, qbppBits) = computeGolombLimit(parameters: parameters, near: scanHeader.near, bitsPerSample: imageData.frameHeader.bitsPerSample)

        // Encode based on interleave mode
        switch scanHeader.interleaveMode {
        case .none:
            try encodeNoneInterleaved(
                buffer: buffer,
                scanHeader: scanHeader,
                regularMode: regularMode,
                runMode: runMode,
                context: &context,
                writer: writer,
                limit: limit,
                qbppBits: qbppBits,
                restartInterval: restartInterval
            )

        case .line:
            try encodeLineInterleaved(
                buffer: buffer,
                scanHeader: scanHeader,
                regularMode: regularMode,
                runMode: runMode,
                context: &context,
                writer: writer,
                limit: limit,
                qbppBits: qbppBits
            )

        case .sample:
            try encodeSampleInterleaved(
                buffer: buffer,
                scanHeader: scanHeader,
                regularMode: regularMode,
                runMode: runMode,
                context: &context,
                writer: writer,
                limit: limit,
                qbppBits: qbppBits
            )
        }

        // Flush any remaining bits
        writer.flush()
    }

    /// Compute the Golomb-Rice LIMIT and qbppBits for a scan per ITU-T.87 §4.4.
    ///
    /// LIMIT = 2 × (bpp + max(8, bpp)) where bpp is the original bits per sample.
    ///
    /// - Parameters:
    ///   - parameters: Preset coding parameters
    ///   - near: Near-lossless parameter (0 for lossless)
    ///   - bitsPerSample: Original bits per sample from frame header
    /// - Returns: Tuple of (limit, qbppBits)
    private func computeGolombLimit(
        parameters: JPEGLSPresetParameters,
        near: Int,
        bitsPerSample: Int
    ) -> (limit: Int, qbppBits: Int) {
        let range: Int
        if near == 0 {
            range = parameters.maxValue + 1
        } else {
            let qstep = 2 * near + 1
            range = (parameters.maxValue + 2 * near) / qstep + 1
        }
        var qbppBits = 0
        var r = range - 1
        while r > 0 {
            qbppBits += 1
            r >>= 1
        }
        qbppBits = max(qbppBits, 2)
        let limit = 2 * (bitsPerSample + max(8, bitsPerSample))
        return (limit, qbppBits)
    }

    /// Compute causal neighbours (Ra, Rb, Rc, Rd) for a pixel directly from
    /// hoisted row arrays, replicating `JPEGLSPixelBuffer.getNeighbors`
    /// boundary semantics (ITU-T.87 §3.2 edge handling) without the
    /// per-pixel Dictionary lookup that method performs.
    ///
    /// - `previousRow == nil` means row 0: top/topLeft/topRight are 0.
    /// - At column 0: Ra = Rb = top, Rc = prevRowEdge, Rd = top-right (or top
    ///   when width == 1).
    @inline(__always)
    private func neighbors(
        currentRow: [Int],
        previousRow: [Int]?,
        col: Int,
        width: Int,
        prevRowEdge: Int
    ) -> (actual: Int, a: Int, b: Int, c: Int, d: Int) {
        let actual = currentRow[col]
        guard let prev = previousRow else {
            return (actual, col == 0 ? 0 : currentRow[col - 1], 0, 0, 0)
        }
        if col == 0 {
            let top = prev[0]
            let d = width > 1 ? prev[1] : top
            return (actual, top, top, prevRowEdge, d)
        }
        let b = prev[col]
        let d = col + 1 < width ? prev[col + 1] : b
        return (actual, currentRow[col - 1], b, prev[col - 1], d)
    }

    /// Encode non-interleaved scan (component by component)
    private func encodeNoneInterleaved(
        buffer: JPEGLSPixelBuffer,
        scanHeader: JPEGLSScanHeader,
        regularMode: JPEGLSRegularMode,
        runMode: JPEGLSRunMode,
        context: inout JPEGLSContextModel,
        writer: JPEGLSBitstreamWriter,
        limit: Int,
        qbppBits: Int,
        restartInterval: Int = 0
    ) throws {
        guard scanHeader.componentCount == 1 else {
            throw JPEGLSError.encodingFailed(
                reason: "Non-interleaved mode requires exactly 1 component per scan"
            )
        }

        let componentId = scanHeader.components[0].id
        let near = scanHeader.near

        // Resolve the component's pixel array once per scan: the component is
        // fixed for the whole scan, so the Dictionary lookup must not sit on
        // the per-pixel path.
        guard let componentPixels = buffer.getComponentPixels(componentId: componentId) else {
            throw JPEGLSError.encodingFailed(reason: "Failed to get component pixels")
        }

        // Lossless scans take the flat fast path: no reconstructed-value
        // tracking is needed, so the whole scan can run over a contiguous
        // UInt16 plane.
        if near == 0 {
            try encodeNoneInterleavedLossless(
                componentPixels: componentPixels,
                width: buffer.width,
                height: buffer.height,
                regularMode: regularMode,
                runMode: runMode,
                context: &context,
                writer: writer,
                limit: limit,
                qbppBits: qbppBits,
                restartInterval: restartInterval
            )
            return
        }

        // Track reconstructed values for near-lossless neighbour computation.
        // For lossless (NEAR = 0) this array is never read — every access below
        // is guarded by `near > 0` — so skip the full-frame allocation entirely
        // (a 2048^2 scan would otherwise allocate and zero 32 MB for nothing).
        var reconstructed: [[Int]] = near > 0
            ? Array(repeating: Array(repeating: 0, count: buffer.width), count: buffer.height)
            : []

        // Encode pixels in raster order with run mode support
        var prevRowEdge = 0
        for row in 0..<buffer.height {
            // Note: RUNindex is NOT reset per line. Per ITU-T.87 §A.7.1,
            // RUNindex persists across scan lines; it is only initialised to 0 at scan start.
            let edgeForThisRow = prevRowEdge
            let currentRow = componentPixels[row]
            let previousRow: [Int]? = row > 0 ? componentPixels[row - 1] : nil
            if let previousRow {
                prevRowEdge = previousRow[0]
            }
            var col = 0
            while col < buffer.width {
                let neighbors = self.neighbors(
                    currentRow: currentRow, previousRow: previousRow,
                    col: col, width: buffer.width, prevRowEdge: edgeForThisRow
                )

                // Use reconstructed neighbours for near-lossless; originals for lossless.
                let (a, b, c, d): (Int, Int, Int, Int)
                if near > 0 {
                    (a, b, c, d) = computeReconstructedNeighbors(
                        from: reconstructed, row: row, col: col,
                        width: buffer.width, height: buffer.height
                    )
                } else {
                    (a, b, c, d) = (neighbors.a, neighbors.b, neighbors.c, neighbors.d)
                }

                // Check for run mode: all quantized gradients are zero
                let (d1, d2, d3) = regularMode.computeGradients(a: a, b: b, c: c, d: d)
                let q1 = regularMode.quantizeGradient(d1)
                let q2 = regularMode.quantizeGradient(d2)
                let q3 = regularMode.quantizeGradient(d3)

                if q1 == 0 && q2 == 0 && q3 == 0 {
                    // Run mode: scan ahead for matching pixels.
                    // The run value is the reconstructed left neighbour (a).
                    let runValue = a
                    let runLength = runMode.detectRunLength(
                        pixels: currentRow,
                        startIndex: col,
                        runValue: runValue
                    )

                    let remainingInLine = buffer.width - col
                    let actualRunLength = min(runLength, remainingInLine)

                    // Encode run length
                    let encoded = runMode.encodeRunLength(
                        runLength: actualRunLength,
                        runIndex: context.currentRunIndex
                    )

                    // Write continuation bits (1s)
                    writer.writeOnes(encoded.continuationBits)

                    // Store the run value as reconstructed for every run pixel.
                    if near > 0 {
                        for runCol in col..<col + actualRunLength {
                            reconstructed[row][runCol] = runValue
                        }
                    }

                    // Compute finalRunIndex now so it can be used for the interruption
                    // pixel's adjustedLimit (matching the decoder, which uses the
                    // post-continuation run index when computing J for the limit).
                    let finalRunIndex = min(encoded.runIndex + encoded.continuationBits, 31)

                    if actualRunLength < remainingInLine {
                        // Run was interrupted — write termination and remainder.
                        writeRunTermination(encoded: encoded, writer: writer)

                        // Encode the interruption pixel
                        let interruptionCol = col + actualRunLength
                        if interruptionCol < buffer.width {
                            let interruptionActual = currentRow[interruptionCol]

                            // Compute Rb at the interruption position
                            let encRb: Int
                            if let previousRow {
                                encRb = near > 0 ? reconstructed[row - 1][interruptionCol] : previousRow[interruptionCol]
                            } else {
                                encRb = 0
                            }

                            // Per ITU-T.87: use finalRunIndex (post-continuation)
                            // for J when computing adjustedLimit in the interruption pixel.
                            // The decoder also uses finalRunIndex at this point.
                            context.setRunIndex(finalRunIndex)
                            let rv = writeRunInterruptionBits(
                                interruptionValue: interruptionActual,
                                runValue: runValue,
                                rb: encRb,
                                near: near,
                                context: &context,
                                regularMode: regularMode,
                                runMode: runMode,
                                writer: writer,
                                limit: limit,
                                qbppBits: qbppBits
                            )
                            // Track what the decoder will reconstruct.
                            if near > 0 {
                                reconstructed[row][interruptionCol] = rv
                            }
                            // Decrement RUNindex after the interruption pixel, matching
                            // the decoder which calls decrementRunIndex() at this point.
                            context.setRunIndex(max(finalRunIndex - 1, 0))
                            col = interruptionCol + 1
                        } else {
                            col = interruptionCol
                            context.setRunIndex(max(finalRunIndex - 1, 0))
                        }
                    } else {
                        // Run reaches end of line.
                        // Per ITU-T.87 §A.7.1: for a partial last block at
                        // EOL, write one '1' bit (the partial-continuation bit).  The
                        // decoder reads the '1', adds min(2^J, remaining)=remaining,
                        // sees the line is full, and exits without reading J remainder
                        // bits.  Do NOT write a '0' termination bit or J bits here.
                        // For an exact full-block fill no extra bit is needed — the
                        // decoder exits after the last full-block '1' bit.
                        if encoded.remainder > 0 {
                            writer.writeBits(1, count: 1)
                        }
                        col += actualRunLength
                        context.setRunIndex(finalRunIndex)
                    }
                } else {
                    // Regular mode
                    let rv = encodePixel(
                        actual: neighbors.actual,
                        a: a, b: b, c: c,
                        q1: q1, q2: q2, q3: q3,
                        regularMode: regularMode,
                        context: &context,
                        writer: writer,
                        limit: limit,
                        qbppBits: qbppBits
                    )
                    if near > 0 {
                        reconstructed[row][col] = rv
                    }
                    col += 1
                }
            }
        }
    }

    /// Lossless (NEAR = 0) non-interleaved scan over a flat UInt16 plane.
    ///
    /// Identical coding decisions to the general path — same neighbours,
    /// gradients, run detection, and bit output — but the pixels live in one
    /// contiguous buffer accessed through an unsafe pointer scoped over the
    /// whole scan: no nested-array indirection, no per-access bounds checks,
    /// and the run scan compares against the row directly. Input samples are
    /// validated to [0, MAXVAL ≤ 2^16 − 1] by MultiComponentImageData.
    private func encodeNoneInterleavedLossless(
        componentPixels: [[Int]],
        width: Int,
        height: Int,
        regularMode: JPEGLSRegularMode,
        runMode: JPEGLSRunMode,
        context: inout JPEGLSContextModel,
        writer: JPEGLSBitstreamWriter,
        limit: Int,
        qbppBits: Int,
        restartInterval: Int = 0
    ) throws {
        // Flatten once per scan.
        var flat = [UInt16](repeating: 0, count: width * height)
        flat.withUnsafeMutableBufferPointer { out in
            for row in 0..<height {
                let base = row * width
                componentPixels[row].withUnsafeBufferPointer { src in
                    for i in 0..<width {
                        out[base + i] = UInt16(truncatingIfNeeded: src[i])
                    }
                }
            }
        }

        if restartInterval > 0 && restartInterval < height {
            // Restart intervals: every interval restarts coding exactly as at
            // scan start (fresh contexts, run state, bit alignment, zero
            // previous line), so the intervals are independent and can encode
            // in parallel into per-interval buffers concatenated with RSTm
            // markers (cycling FFD0–FFD7) between them.
            let chunkCount = (height + restartInterval - 1) / restartInterval
            let presetParameters = regularMode.presetParameters
            let plane = flat
            let results = IntervalEncodeResults(count: chunkCount)
            DispatchQueue.concurrentPerform(iterations: chunkCount) { idx in
                do {
                    let lo = idx * restartInterval
                    let hi = min(lo + restartInterval, height)
                    var chunkContext = try JPEGLSContextModel(
                        parameters: presetParameters, near: 0
                    )
                    let chunkWriter = JPEGLSBitstreamWriter(
                        capacity: (hi - lo) * width * 2 + 64
                    )
                    encodeFlatRowsLossless(
                        flat: plane, rowRange: lo..<hi, width: width,
                        regularMode: regularMode, runMode: runMode,
                        context: &chunkContext, writer: chunkWriter,
                        limit: limit, qbppBits: qbppBits
                    )
                    chunkWriter.flush()
                    results.set(try chunkWriter.getData(), at: idx)
                } catch {
                    results.fail(error)
                }
            }
            let chunkData = try results.finish()
            for (idx, data) in chunkData.enumerated() {
                guard let data else {
                    throw JPEGLSError.encodingFailed(reason: "Restart interval \(idx) produced no data")
                }
                writer.writeBytes(data)
                if idx < chunkCount - 1 {
                    let marker = JPEGLSMarker(
                        rawValue: JPEGLSMarker.restart0.rawValue + UInt8(idx % 8)
                    )!
                    writer.writeMarker(marker)
                }
            }
            return
        }

        encodeFlatRowsLossless(
            flat: flat, rowRange: 0..<height, width: width,
            regularMode: regularMode, runMode: runMode,
            context: &context, writer: writer,
            limit: limit, qbppBits: qbppBits
        )
    }

    /// Encode a contiguous range of rows of a flat UInt16 plane as one
    /// independent coding region: the first row of the range uses row-0
    /// boundary semantics (zero previous line), exactly as at scan start.
    /// For a whole-image range this is the plain lossless scan; for restart
    /// encoding each interval is one such range.
    private func encodeFlatRowsLossless(
        flat: [UInt16],
        rowRange: Range<Int>,
        width: Int,
        regularMode: JPEGLSRegularMode,
        runMode: JPEGLSRunMode,
        context: inout JPEGLSContextModel,
        writer: JPEGLSBitstreamWriter,
        limit: Int,
        qbppBits: Int
    ) {
        flat.withUnsafeBufferPointer { buf in
            var prevRowEdge = 0
            let firstRow = rowRange.lowerBound
            for row in rowRange {
                // Note: RUNindex is NOT reset per line. Per ITU-T.87 §A.7.1,
                // RUNindex persists across scan lines; it is only initialised to 0 at scan start.
                let rowBase = row * width
                let prevBase = rowBase - width
                let edgeForThisRow = prevRowEdge
                if row > firstRow {
                    prevRowEdge = Int(buf[prevBase])
                }
                var col = 0
                while col < width {
                    // Causal neighbours per ITU-T.87 §3.2 (same boundary
                    // semantics as the general path). The first row of the
                    // range uses row-0 semantics (zero previous line).
                    let actual = Int(buf[rowBase + col])
                    let a: Int, b: Int, c: Int, d: Int
                    if row == firstRow {
                        a = col == 0 ? 0 : Int(buf[rowBase + col - 1])
                        b = 0; c = 0; d = 0
                    } else if col == 0 {
                        let top = Int(buf[prevBase])
                        a = top
                        b = top
                        c = edgeForThisRow
                        d = width > 1 ? Int(buf[prevBase + 1]) : top
                    } else {
                        a = Int(buf[rowBase + col - 1])
                        b = Int(buf[prevBase + col])
                        c = Int(buf[prevBase + col - 1])
                        d = col + 1 < width ? Int(buf[prevBase + col + 1]) : b
                    }

                    // Check for run mode: all quantized gradients are zero
                    let (d1, d2, d3) = regularMode.computeGradients(a: a, b: b, c: c, d: d)
                    let q1 = regularMode.quantizeGradient(d1)
                    let q2 = regularMode.quantizeGradient(d2)
                    let q3 = regularMode.quantizeGradient(d3)

                    if q1 == 0 && q2 == 0 && q3 == 0 {
                        // Run mode: scan the rest of the row for the run value
                        // (exact equality — lossless) with a 4-way unrolled test.
                        let runValue = a
                        let rv16 = UInt16(truncatingIfNeeded: runValue)
                        let rowEnd = rowBase + width
                        var i = rowBase + col
                        while i + 4 <= rowEnd {
                            if buf[i] != rv16 || buf[i + 1] != rv16
                                || buf[i + 2] != rv16 || buf[i + 3] != rv16 {
                                break
                            }
                            i += 4
                        }
                        while i < rowEnd && buf[i] == rv16 {
                            i += 1
                        }
                        let actualRunLength = i - (rowBase + col)
                        let remainingInLine = width - col

                        // Encode run length
                        let encoded = runMode.encodeRunLength(
                            runLength: actualRunLength,
                            runIndex: context.currentRunIndex
                        )

                        // Write continuation bits (1s)
                        writer.writeOnes(encoded.continuationBits)

                        // Compute finalRunIndex now so it can be used for the interruption
                        // pixel's adjustedLimit (matching the decoder, which uses the
                        // post-continuation run index when computing J for the limit).
                        let finalRunIndex = min(encoded.runIndex + encoded.continuationBits, 31)

                        if actualRunLength < remainingInLine {
                            // Run was interrupted — write termination and remainder.
                            writeRunTermination(encoded: encoded, writer: writer)

                            let interruptionCol = col + actualRunLength
                            let interruptionActual = Int(buf[rowBase + interruptionCol])
                            let encRb = row > firstRow ? Int(buf[prevBase + interruptionCol]) : 0

                            // Per ITU-T.87: use finalRunIndex (post-continuation)
                            // for J when computing adjustedLimit in the interruption pixel.
                            context.setRunIndex(finalRunIndex)
                            _ = writeRunInterruptionBits(
                                interruptionValue: interruptionActual,
                                runValue: runValue,
                                rb: encRb,
                                near: 0,
                                context: &context,
                                regularMode: regularMode,
                                runMode: runMode,
                                writer: writer,
                                limit: limit,
                                qbppBits: qbppBits
                            )
                            // Decrement RUNindex after the interruption pixel, matching
                            // the decoder which calls decrementRunIndex() at this point.
                            context.setRunIndex(max(finalRunIndex - 1, 0))
                            col = interruptionCol + 1
                        } else {
                            // Run reaches end of line: write one '1' bit for a
                            // partial last block; nothing for an exact fill
                            // (per ITU-T.87 §A.7.1).
                            if encoded.remainder > 0 {
                                writer.writeBits(1, count: 1)
                            }
                            col += actualRunLength
                            context.setRunIndex(finalRunIndex)
                        }
                    } else {
                        // Regular mode
                        _ = encodePixel(
                            actual: actual,
                            a: a, b: b, c: c,
                            q1: q1, q2: q2, q3: q3,
                            regularMode: regularMode,
                            context: &context,
                            writer: writer,
                            limit: limit,
                            qbppBits: qbppBits
                        )
                        col += 1
                    }
                }
            }
        }
    }

    /// Encode line-interleaved scan
    private func encodeLineInterleaved(
        buffer: JPEGLSPixelBuffer,
        scanHeader: JPEGLSScanHeader,
        regularMode: JPEGLSRegularMode,
        runMode: JPEGLSRunMode,
        context: inout JPEGLSContextModel,
        writer: JPEGLSBitstreamWriter,
        limit: Int,
        qbppBits: Int
    ) throws {
        let near = scanHeader.near
        // Encode line by line, all components per line
        var prevRowEdges: [UInt8: Int] = [:]
        for component in scanHeader.components { prevRowEdges[component.id] = 0 }
        // Per-component RUNindex per ITU-T.87: each component line preserves its own run index.
        var componentRunIndex: [UInt8: Int] = [:]
        for component in scanHeader.components { componentRunIndex[component.id] = 0 }
        // Resolve each component's pixel array once per scan so the Dictionary
        // lookup never sits on the per-pixel path.
        var componentPixelsById: [UInt8: [[Int]]] = [:]
        for component in scanHeader.components {
            guard let pixels = buffer.getComponentPixels(componentId: component.id) else {
                throw JPEGLSError.encodingFailed(reason: "Failed to get component pixels")
            }
            componentPixelsById[component.id] = pixels
        }
        // Track reconstructed values per component for near-lossless neighbour computation.
        var reconstructedPerComponent: [UInt8: [[Int]]] = [:]
        if near > 0 {
            for component in scanHeader.components {
                reconstructedPerComponent[component.id] = Array(
                    repeating: Array(repeating: 0, count: buffer.width),
                    count: buffer.height
                )
            }
        }
        for row in 0..<buffer.height {
            // Note: RUNindex is NOT reset per line. Per ITU-T.87 §A.7.1,
            // RUNindex persists across scan lines; it is only initialised to 0 at scan start.
            for component in scanHeader.components {
                // Restore this component's run index
                context.setRunIndex(componentRunIndex[component.id] ?? 0)
                let componentPixels = componentPixelsById[component.id]!
                let currentRow = componentPixels[row]
                let previousRow: [Int]? = row > 0 ? componentPixels[row - 1] : nil
                let edgeForThisRow = prevRowEdges[component.id] ?? 0
                if let previousRow {
                    prevRowEdges[component.id] = previousRow[0]
                }
                var col = 0
                while col < buffer.width {
                    let neighbors = self.neighbors(
                        currentRow: currentRow, previousRow: previousRow,
                        col: col, width: buffer.width, prevRowEdge: edgeForThisRow
                    )

                    // Use reconstructed neighbours for near-lossless; originals for lossless.
                    let (a, b, c, d): (Int, Int, Int, Int)
                    if near > 0, let recArray = reconstructedPerComponent[component.id] {
                        (a, b, c, d) = computeReconstructedNeighbors(
                            from: recArray, row: row, col: col,
                            width: buffer.width, height: buffer.height
                        )
                    } else {
                        (a, b, c, d) = (neighbors.a, neighbors.b, neighbors.c, neighbors.d)
                    }

                    // Check for run mode
                    let (d1, d2, d3) = regularMode.computeGradients(a: a, b: b, c: c, d: d)
                    let q1 = regularMode.quantizeGradient(d1)
                    let q2 = regularMode.quantizeGradient(d2)
                    let q3 = regularMode.quantizeGradient(d3)

                    if q1 == 0 && q2 == 0 && q3 == 0 {
                        // Run mode: the run value is the reconstructed left neighbour.
                        let runValue = a
                        let runLength = runMode.detectRunLength(
                            pixels: currentRow,
                            startIndex: col,
                            runValue: runValue
                        )

                        let remainingInLine = buffer.width - col
                        let actualRunLength = min(runLength, remainingInLine)

                        // Store the run value as reconstructed for every run pixel.
                        if near > 0 {
                            for runCol in col..<col + actualRunLength {
                                reconstructedPerComponent[component.id]?[row][runCol] = runValue
                            }
                        }

                        let encoded = runMode.encodeRunLength(
                            runLength: actualRunLength,
                            runIndex: context.currentRunIndex
                        )

                        writer.writeOnes(encoded.continuationBits)

                        let finalRunIndex = min(encoded.runIndex + encoded.continuationBits, 31)

                        if actualRunLength < remainingInLine {
                            writeRunTermination(encoded: encoded, writer: writer)

                            let interruptionCol = col + actualRunLength
                            if interruptionCol < buffer.width {
                                let interruptionActual = currentRow[interruptionCol]

                                // Compute Rb at the interruption position (use reconstructed for near-lossless)
                                let encRb2: Int
                                if let previousRow {
                                    if near > 0, let recArray = reconstructedPerComponent[component.id] {
                                        encRb2 = recArray[row - 1][interruptionCol]
                                    } else {
                                        encRb2 = previousRow[interruptionCol]
                                    }
                                } else {
                                    encRb2 = 0
                                }

                                context.setRunIndex(finalRunIndex)
                                let rv = writeRunInterruptionBits(
                                    interruptionValue: interruptionActual,
                                    runValue: runValue,
                                    rb: encRb2,
                                    near: near,
                                    context: &context,
                                    regularMode: regularMode,
                                    runMode: runMode,
                                    writer: writer,
                                    limit: limit,
                                    qbppBits: qbppBits
                                )
                                if near > 0 {
                                    reconstructedPerComponent[component.id]?[row][interruptionCol] = rv
                                }
                                context.setRunIndex(max(finalRunIndex - 1, 0))
                                col = interruptionCol + 1
                            } else {
                                col = interruptionCol
                                context.setRunIndex(max(finalRunIndex - 1, 0))
                            }
                        } else {
                            // EOL: write one '1' bit for a partial last block; no bit
                            // needed for an exact full-block fill (per ITU-T.87 §A.7.1).
                            if encoded.remainder > 0 {
                                writer.writeBits(1, count: 1)
                            }
                            col += actualRunLength
                            context.setRunIndex(finalRunIndex)
                        }
                    } else {
                        // Regular mode
                        let rv = encodePixel(
                            actual: neighbors.actual,
                            a: a,
                            b: b,
                            c: c,
                            q1: q1, q2: q2, q3: q3,
                            regularMode: regularMode,
                            context: &context,
                            writer: writer,
                            limit: limit,
                            qbppBits: qbppBits
                        )
                        if near > 0 {
                            reconstructedPerComponent[component.id]?[row][col] = rv
                        }
                        col += 1
                    }
                }
                // Save this component's run index
                componentRunIndex[component.id] = context.currentRunIndex
            }
        }
    }

    /// Encode sample-interleaved scan
    ///
    /// Per ITU-T.87 §C.5, run mode is entered when ALL components at a sample
    /// position have zero quantised gradients.  A single run length is then
    /// written for all components, and each component's interruption sample is
    /// encoded individually after the run.
    private func encodeSampleInterleaved(
        buffer: JPEGLSPixelBuffer,
        scanHeader: JPEGLSScanHeader,
        regularMode: JPEGLSRegularMode,
        runMode: JPEGLSRunMode,
        context: inout JPEGLSContextModel,
        writer: JPEGLSBitstreamWriter,
        limit: Int,
        qbppBits: Int
    ) throws {
        let near = scanHeader.near
        let components = scanHeader.components

        // Resolve every component's pixel array once per scan, aligned with
        // the `components` ordering, so the Dictionary lookup never sits on
        // the per-pixel path.
        var componentPixelArrays: [[[Int]]] = []
        componentPixelArrays.reserveCapacity(components.count)
        for component in components {
            guard let pixels = buffer.getComponentPixels(componentId: component.id) else {
                throw JPEGLSError.encodingFailed(reason: "Failed to get component pixels")
            }
            componentPixelArrays.append(pixels)
        }

        // Track left-edge values per component for boundary Rc at col=0.
        var prevRowEdges: [UInt8: Int] = [:]
        for component in components { prevRowEdges[component.id] = 0 }

        // Track reconstructed values per component for near-lossless neighbour computation.
        var reconstructedPerComponent: [UInt8: [[Int]]] = [:]
        if near > 0 {
            for component in components {
                reconstructedPerComponent[component.id] = Array(
                    repeating: Array(repeating: 0, count: buffer.width),
                    count: buffer.height
                )
            }
        }

        // Encode row by row
        for row in 0..<buffer.height {
            // Note: RUNindex is NOT reset per line. Per ITU-T.87 §A.7.1,
            // RUNindex persists across scan lines; it is only initialised to 0 at scan start.
            let currentRows = componentPixelArrays.map { $0[row] }
            let previousRows: [[Int]]? = row > 0 ? componentPixelArrays.map { $0[row - 1] } : nil
            var edgesForThisRow = [Int](repeating: 0, count: components.count)
            for (cIdx, component) in components.enumerated() {
                edgesForThisRow[cIdx] = prevRowEdges[component.id] ?? 0
                if let previousRows {
                    prevRowEdges[component.id] = previousRows[cIdx][0]
                }
            }
            var col = 0
            while col < buffer.width {
                // Check if ALL components have zero quantised gradients at (row, col)
                // using reconstructed neighbours for near-lossless.
                var allGradientsZero = true
                for (cIdx, component) in components.enumerated() {
                    let compA: Int
                    let compB: Int
                    let compC: Int
                    let compD: Int
                    if near > 0, let recArray = reconstructedPerComponent[component.id] {
                        (compA, compB, compC, compD) = computeReconstructedNeighbors(
                            from: recArray, row: row, col: col,
                            width: buffer.width, height: buffer.height
                        )
                    } else {
                        let n = self.neighbors(
                            currentRow: currentRows[cIdx], previousRow: previousRows?[cIdx],
                            col: col, width: buffer.width, prevRowEdge: edgesForThisRow[cIdx]
                        )
                        (compA, compB, compC, compD) = (n.a, n.b, n.c, n.d)
                    }
                    let (d1, d2, d3) = regularMode.computeGradients(a: compA, b: compB, c: compC, d: compD)
                    if regularMode.quantizeGradient(d1) != 0 ||
                       regularMode.quantizeGradient(d2) != 0 ||
                       regularMode.quantizeGradient(d3) != 0 {
                        allGradientsZero = false
                        break
                    }
                }

                if allGradientsZero {
                    // Run mode: detect the run length across all components simultaneously.
                    // The run continues while every component's pixel equals its run value.
                    // The run value is the reconstructed left neighbour of each component.
                    var runValue: [Int] = []
                    for (cIdx, component) in components.enumerated() {
                        let rv: Int
                        if near > 0, let recArray = reconstructedPerComponent[component.id] {
                            let (a, _, _, _) = computeReconstructedNeighbors(
                                from: recArray, row: row, col: col,
                                width: buffer.width, height: buffer.height
                            )
                            rv = a
                        } else {
                            let n = self.neighbors(
                                currentRow: currentRows[cIdx], previousRow: previousRows?[cIdx],
                                col: col, width: buffer.width, prevRowEdge: edgesForThisRow[cIdx]
                            )
                            rv = n.a
                        }
                        runValue.append(rv)
                    }
                    let componentLinePixels = currentRows

                    // Detect run: the minimum run length across all components
                    let remainingInLine = buffer.width - col
                    var runLength = remainingInLine
                    for (cIdx, linePixels) in componentLinePixels.enumerated() {
                        let compRun = runMode.detectRunLength(
                            pixels: linePixels,
                            startIndex: col,
                            runValue: runValue[cIdx]
                        )
                        runLength = min(runLength, compRun)
                    }
                    let actualRunLength = min(runLength, remainingInLine)

                    // Store run value as reconstructed for every run pixel (near-lossless).
                    if near > 0 {
                        for (cIdx, component) in components.enumerated() {
                            for runCol in col..<col + actualRunLength {
                                reconstructedPerComponent[component.id]?[row][runCol] = runValue[cIdx]
                            }
                        }
                    }

                    // Encode run length (same encoding as non-interleaved/line-interleaved)
                    let encoded = runMode.encodeRunLength(
                        runLength: actualRunLength,
                        runIndex: context.currentRunIndex
                    )
                    writer.writeOnes(encoded.continuationBits)

                    let finalRunIndex = min(encoded.runIndex + encoded.continuationBits, 31)

                    if actualRunLength < remainingInLine {
                        // Run interrupted — write termination and remainder
                        writeRunTermination(encoded: encoded, writer: writer)

                        // Encode interruption pixel for EACH component independently
                        let interruptionCol = col + actualRunLength
                        if interruptionCol < buffer.width {
                            context.setRunIndex(finalRunIndex)
                            for (cIdx, component) in components.enumerated() {
                                let interruptionActual = currentRows[cIdx][interruptionCol]
                                // Compute Rb at the interruption position (use reconstructed for near-lossless)
                                let encRb3: Int
                                if let previousRows {
                                    if near > 0, let recArray = reconstructedPerComponent[component.id] {
                                        encRb3 = recArray[row - 1][interruptionCol]
                                    } else {
                                        encRb3 = previousRows[cIdx][interruptionCol]
                                    }
                                } else {
                                    encRb3 = 0
                                }
                                let rv3 = writeRunInterruptionBits(
                                    interruptionValue: interruptionActual,
                                    runValue: runValue[cIdx],
                                    rb: encRb3,
                                    near: near,
                                    context: &context,
                                    regularMode: regularMode,
                                    runMode: runMode,
                                    writer: writer,
                                    limit: limit,
                                    qbppBits: qbppBits,
                                    overrideRiType: 0  // Per ITU-T.87: triplet always uses riType=0
                                )
                                if near > 0 {
                                    reconstructedPerComponent[component.id]?[row][interruptionCol] = rv3
                                }
                            }
                            context.setRunIndex(max(finalRunIndex - 1, 0))
                            col = interruptionCol + 1
                        } else {
                            col = interruptionCol
                            context.setRunIndex(max(finalRunIndex - 1, 0))
                        }
                    } else {
                        // EOL: write one '1' bit for a partial last block; no bit
                        // needed for an exact full-block fill (per ITU-T.87 §A.7.1).
                        if encoded.remainder > 0 {
                            writer.writeBits(1, count: 1)
                        }
                        col += actualRunLength
                        context.setRunIndex(finalRunIndex)
                    }
                } else {
                    // Regular mode: encode each component at (row, col)
                    for (cIdx, component) in components.enumerated() {
                        let compA: Int
                        let compB: Int
                        let compC: Int
                        let compD: Int
                        let actual: Int
                        if near > 0, let recArray = reconstructedPerComponent[component.id] {
                            (compA, compB, compC, compD) = computeReconstructedNeighbors(
                                from: recArray, row: row, col: col,
                                width: buffer.width, height: buffer.height
                            )
                            actual = currentRows[cIdx][col]
                        } else {
                            let n = self.neighbors(
                                currentRow: currentRows[cIdx], previousRow: previousRows?[cIdx],
                                col: col, width: buffer.width, prevRowEdge: edgesForThisRow[cIdx]
                            )
                            (compA, compB, compC, compD) = (n.a, n.b, n.c, n.d)
                            actual = n.actual
                        }
                        let (sd1, sd2, sd3) = regularMode.computeGradients(a: compA, b: compB, c: compC, d: compD)
                        let rv = encodePixel(
                            actual: actual,
                            a: compA,
                            b: compB,
                            c: compC,
                            q1: regularMode.quantizeGradient(sd1),
                            q2: regularMode.quantizeGradient(sd2),
                            q3: regularMode.quantizeGradient(sd3),
                            regularMode: regularMode,
                            context: &context,
                            writer: writer,
                            limit: limit,
                            qbppBits: qbppBits
                        )
                        if near > 0 {
                            reconstructedPerComponent[component.id]?[row][col] = rv
                        }
                    }
                    col += 1
                }
            }
        }
    }

    /// Compute boundary-condition-aware neighbours from a reconstructed-value buffer.
    ///
    /// Mirrors the boundary conditions applied by `JPEGLSPixelBuffer.getNeighbors`
    /// but operates on the encoder's local reconstructed-value array, which is
    /// populated during near-lossless encoding to track the values that the decoder
    /// will reconstruct.
    ///
    /// - Returns: Tuple (a, b, c, d) = (left, top, topLeft, topRight) neighbours.
    private func computeReconstructedNeighbors(
        from reconstructed: [[Int]],
        row: Int,
        col: Int,
        width: Int,
        height: Int
    ) -> (a: Int, b: Int, c: Int, d: Int) {
        if row == 0 && col == 0 {
            return (0, 0, 0, 0)
        } else if row == 0 {
            let left = reconstructed[row][col - 1]
            return (left, 0, 0, 0)
        } else if col == 0 {
            let top = reconstructed[row - 1][col]
            // Per ITU-T.87 §3.2 edge-pixel buffering: Rc at col=0 is
            // the first pixel of two rows above (equivalent to prevRowEdge in the
            // lossless path).  For row 0–1 this equals 0; for row r≥2 it is the
            // reconstructed value at (r−2, 0).
            let topLeft = row >= 2 ? reconstructed[row - 2][col] : 0
            let topRight = (width > 1) ? reconstructed[row - 1][col + 1] : top
            return (top, top, topLeft, topRight)
        } else {
            let left = reconstructed[row][col - 1]
            let top = reconstructed[row - 1][col]
            let topLeft = reconstructed[row - 1][col - 1]
            let topRight = (col + 1 < width) ? reconstructed[row - 1][col + 1] : top
            return (left, top, topLeft, topRight)
        }
    }

    /// Encode a single pixel in regular mode and return its reconstructed value.
    ///
    /// Takes pre-computed neighbour values so that the caller can supply either
    /// original or reconstructed neighbours as appropriate (e.g. for near-lossless
    /// mode the encoder passes reconstructed neighbours; for lossless it uses the
    /// original pixel values directly).
    ///
    /// - Returns: The reconstructed sample value that the decoder will produce,
    ///   which the caller should store for use as a neighbour in subsequent pixels
    ///   when operating in near-lossless mode.
    @discardableResult
    private func encodePixel(
        actual: Int,
        a: Int,
        b: Int,
        c: Int,
        q1: Int,
        q2: Int,
        q3: Int,
        regularMode: JPEGLSRegularMode,
        context: inout JPEGLSContextModel,
        writer: JPEGLSBitstreamWriter,
        limit: Int,
        qbppBits: Int
    ) -> Int {
        // Regular mode encoding, reusing the quantized gradients the scan
        // loop already computed for the run-mode test.
        let (contextIndex, sign) = context.computeContextIndexAndSign(q1: q1, q2: q2, q3: q3)
        let encodedPixel = regularMode.encodePixel(
            actual: actual,
            a: a,
            b: b,
            c: c,
            contextIndex: contextIndex,
            sign: sign,
            context: context
        )

        // Write Golomb-Rice encoded bits
        writeRegularModeBits(encodedPixel, to: writer, limit: limit, qbppBits: qbppBits)

        // Update context
        context.updateContext(
            contextIndex: encodedPixel.contextIndex,
            predictionError: encodedPixel.error,
            sign: encodedPixel.sign
        )

        return encodedPixel.reconstructedValue
    }

    /// Write regular mode encoded bits to bitstream, implementing the Golomb-Rice
    /// LIMIT per ITU-T.87 §6.1.1.  When the unary prefix would equal or exceed
    /// (LIMIT − qbppBits − 1), the limited binary code is written instead:
    /// (LIMIT − qbppBits − 1) zero bits, then '1', then qbppBits bits for MErrval − 1.
    private func writeRegularModeBits(
        _ encoded: EncodedPixel,
        to writer: JPEGLSBitstreamWriter,
        limit: Int,
        qbppBits: Int
    ) {
        let limitThreshold = limit - qbppBits - 1
        if encoded.unaryLength >= limitThreshold {
            // Limited binary code: write limitThreshold zeros + 1, then MErrval−1 in qbppBits.
            writer.writeUnaryCode(limitThreshold)
            writer.writeBits(UInt32(encoded.mappedError - 1), count: qbppBits)
        } else {
            // Standard Golomb-Rice: write unaryLength zeros + 1, then k-bit remainder.
            writer.writeUnaryCode(encoded.unaryLength)
            if encoded.golombK > 0 {
                writer.writeBits(UInt32(encoded.remainder), count: encoded.golombK)
            }
        }
    }

    /// Write run interruption error to bitstream using adaptive Golomb-Rice encoding,
    /// implementing the LIMIT per ITU-T.87 §4.5.3 and §6.1.1.
    ///
    /// - Parameters:
    ///   - mappedError: Non-negative mapped prediction error (MErrval)
    ///   - absError: Absolute value of the signed prediction error (for context update)
    ///   - context: Context model (provides and receives run interruption stats)
    ///   - regularMode: Regular mode encoder (provides golombEncode helper)
    ///   - writer: Bitstream writer
    ///   - limit: LIMIT = 2 × (qbppBits + 8)
    ///   - qbppBits: ⌈log₂(RANGE)⌉
    @discardableResult
    private func writeRunInterruptionBits(
        interruptionValue: Int,
        runValue: Int,
        rb: Int,
        near: Int,
        context: inout JPEGLSContextModel,
        regularMode: JPEGLSRegularMode,
        runMode: JPEGLSRunMode,
        writer: JPEGLSBitstreamWriter,
        limit: Int,
        qbppBits: Int,
        overrideRiType: Int? = nil
    ) -> Int {
        let ra = runValue
        let riType = overrideRiType ?? ((abs(ra - rb) <= near) ? 1 : 0)

        // Prediction and error per ITU-T.87
        let prediction: Int
        let rawError: Int
        if riType == 1 {
            prediction = ra
            rawError = interruptionValue - prediction
        } else {
            prediction = rb
            let raw = interruptionValue - prediction
            rawError = (rb >= ra) ? raw : -raw
        }

        // Quantize and modular-reduce the interruption error per ITU-T.87.
        let params = parameters(regularMode)
        let qbpp = near > 0 ? (2 * near + 1) : 1
        let range: Int
        if near == 0 {
            range = params.maxValue + 1
        } else {
            range = (params.maxValue + 2 * near) / qbpp + 1
        }

        // Quantize for near-lossless (identity for lossless)
        var reducedError: Int
        if near > 0 {
            if rawError >= 0 {
                reducedError = (rawError + near) / qbpp
            } else {
                reducedError = -((abs(rawError) + near) / qbpp)
            }
        } else {
            reducedError = rawError
        }

        // Modular reduction with RANGE
        if reducedError < 0 { reducedError += range }
        if reducedError >= ((range + 1) / 2) { reducedError -= range }

        let k = context.computeRunInterruptionGolombK(riType: riType)
        let map = context.computeRunInterruptionMap(errorValue: reducedError, k: k, riType: riType)

        // Map to the non-negative interruption code per ITU-T.87:
        // e_mapped = 2 * |error| - riType - map
        let eMappedErrorValue = 2 * abs(reducedError) - riType - (map ? 1 : 0)

        // Adjusted limit for run interruption
        let j = runMode.computeJ(runIndex: context.currentRunIndex)
        let adjustedLimit = limit - j - 1
        let limitThreshold = adjustedLimit - qbppBits - 1

        let (unaryLength, remainder) = regularMode.golombEncode(value: eMappedErrorValue, k: k)
        if unaryLength >= limitThreshold {
            writer.writeUnaryCode(limitThreshold)
            writer.writeBits(UInt32(eMappedErrorValue - 1), count: qbppBits)
        } else {
            writer.writeUnaryCode(unaryLength)
            if k > 0 {
                writer.writeBits(UInt32(remainder), count: k)
            }
        }

        context.updateRunInterruptionContext(
            errorValue: reducedError,
            eMappedErrorValue: eMappedErrorValue,
            riType: riType
        )

        // Compute what the decoder will reconstruct
        let dequantized = reducedError * qbpp
        let signedError: Int
        if riType == 1 {
            signedError = dequantized
        } else {
            signedError = dequantized * (rb >= ra ? 1 : -1)
        }
        var rv = prediction + signedError
        let wrapRange = range * qbpp
        if rv < -near { rv += wrapRange }
        else if rv > params.maxValue + near { rv -= wrapRange }
        return max(0, min(params.maxValue, rv))
    }

    /// Helper to extract parameters from regular mode encoder
    private func parameters(_ regularMode: JPEGLSRegularMode) -> JPEGLSPresetParameters {
        regularMode.presetParameters
    }

    /// Write run termination and remainder bits to bitstream
    private func writeRunTermination(
        encoded: EncodedRun,
        writer: JPEGLSBitstreamWriter
    ) {
        writer.writeBits(0, count: 1)  // Termination bit
        if encoded.j > 0 {
            writer.writeBits(UInt32(encoded.remainder), count: encoded.j)
        }
    }
}
