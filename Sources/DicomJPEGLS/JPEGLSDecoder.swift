// Modified for Isis from JLSwift 299b9a2 (Apache-2.0); the modifications are recorded in Git.

/// High-level JPEG-LS decoder API
/// Modified for Isis #2341: cooperative cancellation through rows and restart workers.
///
/// Provides a simple interface to decode JPEG-LS encoded data to raw pixel data.
/// Handles all aspects of JPEG-LS file decoding including marker parsing, bitstream
/// reading, and pixel reconstruction.

import Foundation

/// Lock-protected accumulator for parallel restart-interval decoding:
/// each worker stores its interval's decoded plane at its own index, and
/// the first error (if any) wins.
private final class IntervalDecodeResults: @unchecked Sendable {
    private let lock = NSLock()
    private var regions: [[UInt16]?]
    private var firstError: Error?

    init(count: Int) {
        self.regions = Array(repeating: nil, count: count)
    }

    func set(_ region: [UInt16], at index: Int) {
        lock.lock()
        regions[index] = region
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        if firstError == nil { firstError = error }
        lock.unlock()
    }

    func finish() throws -> [[UInt16]?] {
        lock.lock()
        defer { lock.unlock() }
        if let firstError { throw firstError }
        return regions
    }
}

/// First error of the restart-interval workers that decode straight into one plane.
private final class IntervalDecodeFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var firstError: Error?

    func fail(_ error: Error) {
        lock.lock()
        if firstError == nil { firstError = error }
        lock.unlock()
    }

    func rethrow() throws {
        lock.lock()
        defer { lock.unlock() }
        if let firstError { throw firstError }
    }
}

/// High-level JPEG-LS decoder
///
/// Decodes JPEG-LS encoded data to multi-component image data per ITU-T.87.
/// Supports all decoding modes (lossless, near-lossless) and interleaving modes.
///
/// **Example usage:**
/// ```swift
/// // Create decoder
/// let decoder = JPEGLSDecoder()
///
/// // Decode JPEG-LS file
/// let imageData = try decoder.decode(jpegLSData)
///
/// // Access pixel data
/// let pixels = imageData.components[0].pixels
/// ```
public struct JPEGLSDecoder: Sendable {
    /// Initialize decoder
    private let checkCancellation: @Sendable () throws -> Void

    /// The checker also runs in restart-interval workers outside the Swift task executor.
    public init(checkCancellation: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }) {
        self.checkCancellation = checkCancellation
    }

    /// Decodes a one-component frame straight into its final sample plane (issue #2903): `rows × columns`
    /// native-endian `Sample`s (`UInt8` for P ≤ 8, `UInt16` otherwise), with no row arrays, widening or repacking.
    /// Restart intervals decode concurrently into their own rows. `finishRow` sees every row once no later
    /// prediction reads it, so a caller can sign-extend in the same pass. Frames with more than one component,
    /// mapping tables or a colour transformation are refused; an interleaved single-component scan takes the
    /// general decoder and is copied.
    public func decodeSingleComponent<Sample: FixedWidthInteger & UnsignedInteger>(
        _ data: Data,
        as sampleType: Sample.Type,
        finishRow: (@Sendable (UnsafeMutableBufferPointer<Sample>) -> Void)? = nil
    ) throws -> (frameHeader: JPEGLSFrameHeader, samples: Data) {
        try checkCancellation()
        let data = data.startIndex == 0 ? data : Data(data)
        let prepared = try prepare(data)
        let header = prepared.frameHeader
        guard header.componentCount == 1, prepared.scanDataList.count == 1,
              prepared.parseResult.mappingTables.isEmpty, prepared.parseResult.colorTransformation == .none else {
            throw JPEGLSError.invalidBitstreamStructure(reason: "The direct plane decode takes one plain component")
        }
        guard prepared.parameters.maxValue <= Int(Sample.max) else {
            throw JPEGLSError.invalidBitstreamStructure(
                reason: "MAXVAL \(prepared.parameters.maxValue) does not fit \(Sample.bitWidth)-bit samples")
        }
        let width = header.width, height = header.height
        var samples = Data(count: width * height * MemoryLayout<Sample>.stride)
        let scan = prepared.firstScanHeader
        guard scan.interleaveMode == .none else {
            let rows = try decode(data).components[0].pixels
            samples.withUnsafeMutableBytes { raw in
                let plane = raw.bindMemory(to: Sample.self)
                for (row, values) in rows.enumerated() {
                    for (column, value) in values.enumerated() {
                        plane[row * width + column] = Sample(truncatingIfNeeded: value)
                    }
                    finishRow?(UnsafeMutableBufferPointer(rebasing: plane[(row * width)..<((row + 1) * width)]))
                }
            }
            return (header, samples)
        }
        let parameters = prepared.parameters, near = scan.near
        let (limit, qbppBits) = computeGolombLimit(parameters: parameters, near: near,
                                                   bitsPerSample: header.bitsPerSample)
        let interval = prepared.scanRestartIntervals.first ?? 0
        try samples.withUnsafeMutableBytes { raw in
            let plane = raw.bindMemory(to: Sample.self)
            guard interval > 0 && interval < height else {
                try decodeRegion(reader: JPEGLSBitstreamReader(data: prepared.scanDataList[0]), rows: height,
                                 width: width, parameters: parameters, near: near, limit: limit, qbppBits: qbppBits,
                                 into: plane, finishRow: finishRow)
                return
            }
            let segments = try splitScanDataAtRestartMarkers(prepared.scanDataList[0])
            let intervalCount = (height + interval - 1) / interval
            guard segments.count == intervalCount else {
                throw JPEGLSError.invalidBitstreamStructure(
                    reason: "Expected \(intervalCount) restart intervals for \(height) lines, found \(segments.count)"
                )
            }
            // Intervals write disjoint rows of the one plane.
            nonisolated(unsafe) let shared = plane
            let failure = IntervalDecodeFailure()
            DispatchQueue.concurrentPerform(iterations: intervalCount) { index in
                let firstRow = index * interval
                let rows = min(interval, height - firstRow)
                do {
                    try decodeRegion(
                        reader: JPEGLSBitstreamReader(data: segments[index]), rows: rows, width: width,
                        parameters: parameters, near: near, limit: limit, qbppBits: qbppBits,
                        into: UnsafeMutableBufferPointer(rebasing: shared[(firstRow * width)..<((firstRow + rows) * width)]),
                        finishRow: finishRow)
                } catch {
                    failure.fail(error)
                }
            }
            try failure.rethrow()
        }
        return (header, samples)
    }

    /// A parsed and validated codestream, ready for scan decoding.
    private struct PreparedScans {
        let parseResult: JPEGLSParseResult
        let parameters: JPEGLSPresetParameters
        let frameHeader: JPEGLSFrameHeader
        let scanDataList: [Data]
        let firstScanHeader: JPEGLSScanHeader
        let scanRestartIntervals: [Int]
    }

    /// Parses and validates `data` (zero-based) and slices its scans.
    private func prepare(_ data: Data) throws -> PreparedScans {
        // Parse JPEG-LS structure
        let parser = JPEGLSParser(data: data)
        let parseResult = try parser.parse()

        // Get preset parameters (default or custom).  The NEAR parameter affects
        // the default thresholds per ITU-T.87 Table C.2, so it must be supplied.
        let near = parseResult.scanHeaders.first?.near ?? 0
        let parameters = try parseResult.presetParameters ?? JPEGLSPresetParameters.defaultParameters(
            bitsPerSample: parseResult.frameHeader.bitsPerSample,
            near: near
        )

        // MAXVAL must satisfy 0 < MAXVAL ≤ 2^P − 1 (ITU-T.87 C.2.4.1.1).
        // A larger value would let the decode pipeline's clamps produce
        // samples outside the frame's sample range.
        let sampleCap = (1 << parseResult.frameHeader.bitsPerSample) - 1
        guard parameters.maxValue <= sampleCap else {
            throw JPEGLSError.invalidBitstreamStructure(
                reason: "MAXVAL \(parameters.maxValue) exceeds 2^P−1 = \(sampleCap) for \(parseResult.frameHeader.bitsPerSample)-bit samples"
            )
        }

        // Reject dimension products that overflow before any buffer sizing
        // arithmetic runs on them (a crafted LSE type-4 segment can declare
        // axes up to 2^32 − 1 each).
        let frameHeader = parseResult.frameHeader
        let (_, dimensionOverflow) = frameHeader.width.multipliedReportingOverflow(by: frameHeader.height)
        guard !dimensionOverflow else {
            throw JPEGLSError.invalidDimensions(width: frameHeader.width, height: frameHeader.height)
        }

        if parseResult.colorTransformation != .none {
            guard parseResult.colorTransformation.isValid(forComponentCount: frameHeader.componentCount) else {
                throw JPEGLSError.invalidBitstreamStructure(
                    reason: "Colour transformation \(parseResult.colorTransformation) is incompatible with component count \(frameHeader.componentCount)"
                )
            }
            let horizontal = frameHeader.components.first?.horizontalSamplingFactor
            let vertical = frameHeader.components.first?.verticalSamplingFactor
            guard frameHeader.components.allSatisfy({
                $0.horizontalSamplingFactor > 0 && $0.verticalSamplingFactor > 0
                    && $0.horizontalSamplingFactor == horizontal && $0.verticalSamplingFactor == vertical
            }) else {
                throw JPEGLSError.invalidBitstreamStructure(
                    reason: "Colour transformation requires full-resolution component planes"
                )
            }
        }

        for scan in parseResult.scanHeaders {
            for component in scan.components where component.mappingTableID != 0 {
                guard parseResult.mappingTables[component.mappingTableID] != nil else {
                    throw JPEGLSError.invalidBitstreamStructure(
                        reason: "Scan component \(component.id) references undefined mapping table \(component.mappingTableID)"
                    )
                }
            }
        }

        // Slice scan data using the ranges the parser recorded during its
        // walk; fall back to a marker walk only for externally-constructed
        // parse results without ranges.
        let scanDataList: [Data]
        if parseResult.scanDataRanges.count == parseResult.scanHeaders.count {
            scanDataList = parseResult.scanDataRanges.map { Data(data[$0]) }
        } else {
            scanDataList = try extractScanData(from: data, parseResult: parseResult)
        }

        // Validate we have the expected number of scans
        guard scanDataList.count == parseResult.scanHeaders.count else {
            throw JPEGLSError.invalidBitstreamStructure(
                reason: "Scan data count (\(scanDataList.count)) doesn't match scan header count (\(parseResult.scanHeaders.count))"
            )
        }

        // Decode based on interleave mode
        guard let firstScanHeader = parseResult.scanHeaders.first else {
            throw JPEGLSError.invalidBitstreamStructure(reason: "No scan headers found")
        }

        // Per-scan restart intervals: the DRI value in effect at each SOS
        // (T.81 B.2.4.4 — a DRI between scans applies to following scans
        // only). Fall back to the file-global value for externally-built
        // parse results.
        let scanRestartIntervals: [Int]
        if parseResult.scanRestartIntervals.count == parseResult.scanHeaders.count {
            scanRestartIntervals = parseResult.scanRestartIntervals
        } else {
            scanRestartIntervals = Array(
                repeating: parseResult.restartInterval ?? 0,
                count: parseResult.scanHeaders.count
            )
        }

        // An interval only takes effect when it is shorter than the frame
        // (DRI ≥ height produces zero RST markers — the scan body is
        // identical to a no-DRI stream).
        func restartActive(_ interval: Int) -> Bool {
            interval > 0 && interval < frameHeader.height
        }

        // Restart intervals (DRI) are supported for non-interleaved scans;
        // reject interleaved streams whose scans would actually contain
        // restart markers rather than decoding them incorrectly.
        if firstScanHeader.interleaveMode != .none,
           let interval = scanRestartIntervals.first, restartActive(interval) {
            throw JPEGLSError.invalidBitstreamStructure(
                reason: "Restart intervals are not supported with \(firstScanHeader.interleaveMode) interleave mode"
            )
        }

        // Scans without an active restart interval must not contain RSTm
        // markers: the bit reader would otherwise absorb them as entropy
        // data and decode garbage silently (e.g. a corrupted stuffed byte).
        for (index, scanData) in scanDataList.enumerated() {
            try checkCancellation()
            let interval = index < scanRestartIntervals.count ? scanRestartIntervals[index] : 0
            let active = restartActive(interval) && firstScanHeader.interleaveMode == .none
            if !active && Self.scanBodyContainsRestartMarker(scanData) {
                throw JPEGLSError.invalidBitstreamStructure(
                    reason: "Restart marker found in scan \(index) without an active restart interval"
                )
            }
        }

        return PreparedScans(parseResult: parseResult, parameters: parameters, frameHeader: frameHeader,
                             scanDataList: scanDataList, firstScanHeader: firstScanHeader,
                             scanRestartIntervals: scanRestartIntervals)
    }

    /// Decode JPEG-LS data to pixel data
    ///
    /// ```swift
    /// let decoder = JPEGLSDecoder()
    ///
    /// // Decode a JPEG-LS file
    /// let data = try Data(contentsOf: URL(fileURLWithPath: "image.jls"))
    /// let imageData = try decoder.decode(data)
    ///
    /// // Access image properties
    /// let width  = imageData.frameHeader.width
    /// let height = imageData.frameHeader.height
    /// let bps    = imageData.frameHeader.bitsPerSample
    ///
    /// // Access pixel values (row-major, one array per component)
    /// let pixels = imageData.components[0].pixels  // [[Int]]
    /// let topLeftPixel = pixels[0][0]
    /// ```
    ///
    /// - Parameter data: JPEG-LS encoded data
    /// - Returns: Decoded multi-component image data
    /// - Throws: `JPEGLSError` if decoding fails
    public func decode(_ data: Data) throws -> MultiComponentImageData {
        try checkCancellation()
        // Rebase slices: all offset bookkeeping below (parser scan ranges,
        // the fallback marker walk) is zero-based, but a Data slice keeps
        // its parent's indices — subscripting it with zero-based ranges
        // would silently read the wrong bytes or trap.
        let data = data.startIndex == 0 ? data : Data(data)

        let prepared = try prepare(data)
        let parseResult = prepared.parseResult
        let parameters = prepared.parameters
        let scanDataList = prepared.scanDataList
        let firstScanHeader = prepared.firstScanHeader
        let scanRestartIntervals = prepared.scanRestartIntervals
        var decodedComponents: [MultiComponentImageData.ComponentData]

        switch firstScanHeader.interleaveMode {
        case .none:
            // Non-interleaved: one scan per component
            decodedComponents = try decodeNoneInterleaved(
                frameHeader: parseResult.frameHeader,
                scanHeaders: parseResult.scanHeaders,
                scanDataList: scanDataList,
                parameters: parameters,
                mappingTables: parseResult.mappingTables,
                restartIntervals: scanRestartIntervals
            )

        case .line:
            // Line-interleaved: all components in one scan, line by line
            decodedComponents = try decodeLineInterleaved(
                frameHeader: parseResult.frameHeader,
                scanHeader: firstScanHeader,
                scanData: scanDataList[0],
                parameters: parameters,
                mappingTables: parseResult.mappingTables
            )

        case .sample:
            // Sample-interleaved: all components in one scan, pixel by pixel
            decodedComponents = try decodeSampleInterleaved(
                frameHeader: parseResult.frameHeader,
                scanHeader: firstScanHeader,
                scanData: scanDataList[0],
                parameters: parameters,
                mappingTables: parseResult.mappingTables
            )
        }

        // Apply inverse colour transform when signalled by APP8 "mrfx" marker
        let colorTransformation = parseResult.colorTransformation
        if colorTransformation != .none
            && colorTransformation.isValid(forComponentCount: decodedComponents.count)
        {
            let maxValue = (1 << parseResult.frameHeader.bitsPerSample) - 1
            decodedComponents = try applyInverseColorTransform(
                decodedComponents,
                transformation: colorTransformation,
                frameHeader: parseResult.frameHeader,
                maxValue: maxValue
            )
        }

        // Every frame component must have been decoded (the parser accepts
        // EOI after any number of scans; a short non-interleaved stream
        // would otherwise yield fewer components than the frame declares).
        guard decodedComponents.count == parseResult.frameHeader.componentCount else {
            throw JPEGLSError.invalidBitstreamStructure(
                reason: "Decoded \(decodedComponents.count) component(s) but the frame header declares \(parseResult.frameHeader.componentCount)"
            )
        }

        // Create result. The decode pipeline clamps every sample to
        // [0, MAXVAL ≤ 2^P−1] by construction and builds rows at exact scan
        // dimensions, so the O(W·H) re-validation in the public initializer
        // adds no information — skip it unless a post-processing step with
        // unbounded outputs ran (mapping tables, colour transform) or the
        // frame is sub-sampled (which the scan decoders do not handle).
        let uniformSampling = parseResult.frameHeader.components.allSatisfy {
            $0.horizontalSamplingFactor == 1 && $0.verticalSamplingFactor == 1
        }
        if uniformSampling && parseResult.mappingTables.isEmpty && colorTransformation == .none {
            return MultiComponentImageData(
                uncheckedComponents: decodedComponents,
                frameHeader: parseResult.frameHeader
            )
        }
        return try MultiComponentImageData(
            components: decodedComponents,
            frameHeader: parseResult.frameHeader
        )
    }

    /// Apply the inverse colour transform to all decoded pixel components.
    private func applyInverseColorTransform(
        _ components: [MultiComponentImageData.ComponentData],
        transformation: JPEGLSColorTransformation,
        frameHeader: JPEGLSFrameHeader,
        maxValue: Int
    ) throws -> [MultiComponentImageData.ComponentData] {
        let count = components.count
        var transformedPixels = components.map { $0.pixels }

        for row in 0..<frameHeader.height {
            try checkCancellation()
            for col in 0..<frameHeader.width {
                let encoded = (0..<count).map { transformedPixels[$0][row][col] }
                let original = try transformation.transformInverse(encoded, maxValue: maxValue)
                for idx in 0..<count {
                    transformedPixels[idx][row][col] = original[idx]
                }
            }
        }

        return components.enumerated().map { (idx, comp) in
            MultiComponentImageData.ComponentData(id: comp.id, pixels: transformedPixels[idx])
        }
    }

    // MARK: - Scan Data Extraction

    /// Extract compressed scan data from JPEG-LS file
    ///
    /// Locates and extracts the bitstream data between SOS marker content and next marker/EOI for each scan.
    ///
    /// - Parameters:
    ///   - data: Complete JPEG-LS file data
    ///   - parseResult: Parsed structure information
    /// - Returns: Array of scan data buffers
    /// - Throws: `JPEGLSError` if scan data cannot be extracted
    private func extractScanData(from data: Data, parseResult: JPEGLSParseResult) throws -> [Data] {
        var scanDataList: [Data] = []
        var position = 0
        let expectedScans = parseResult.scanHeaders.count

        // Parse through the file looking for SOS markers
        while position < data.count - 1 && scanDataList.count < expectedScans {
            // Look for marker prefix
            if data[position] == 0xFF {
                let markerCode = data[position + 1]

                // Check if this is a SOS marker
                if markerCode == JPEGLSMarker.startOfScan.rawValue {
                    // Skip marker (2 bytes)
                    position += 2

                    // Read and skip SOS segment length and content
                    guard position + 2 <= data.count else {
                        throw JPEGLSError.prematureEndOfStream
                    }
                    let sosLength = Int(data[position]) << 8 | Int(data[position + 1])
                    position += sosLength

                    // Now at start of scan data
                    let scanDataStart = position

                    // Find end of scan data (next real marker, not stuffed byte).
                    // Per ISO 14495-1 §9.1: a byte following 0xFF with MSB = 0 (< 0x80)
                    // is a stuffed byte; MSB = 1 (≥ 0x80) is a real marker — except
                    // restart markers (FFD0–FFD7), which are part of the scan body.
                    var scanDataEnd = position
                    while scanDataEnd < data.count - 1 {
                        if data[scanDataEnd] == 0xFF {
                            let nextByte = data[scanDataEnd + 1]
                            if nextByte >= JPEGLSMarker.restart0.rawValue
                                && nextByte <= JPEGLSMarker.restart7.rawValue {
                                // Restart marker inside the scan — keep walking.
                                scanDataEnd += 2
                                continue
                            }
                            if nextByte >= 0x80 {
                                // Real marker — scan data ends here
                                break
                            }
                            // Stuffed byte (nextByte < 0x80) — skip both bytes and continue
                            scanDataEnd += 2
                        } else {
                            scanDataEnd += 1
                        }
                    }

                    // Extract scan data (including byte stuffing - decoder will handle it)
                    let scanData = data[scanDataStart..<scanDataEnd]
                    scanDataList.append(Data(scanData))

                    position = scanDataEnd
                } else {
                    // Some other marker - skip it
                    position += 1
                }
            } else {
                position += 1
            }
        }

        guard scanDataList.count == expectedScans else {
            throw JPEGLSError.invalidBitstreamStructure(
                reason: "Expected \(expectedScans) scans, found \(scanDataList.count)"
            )
        }

        return scanDataList
    }

    // MARK: - Non-Interleaved Decoding

    /// Decode non-interleaved image (one scan per component)
    private func decodeNoneInterleaved(
        frameHeader: JPEGLSFrameHeader,
        scanHeaders: [JPEGLSScanHeader],
        scanDataList: [Data],
        parameters: JPEGLSPresetParameters,
        mappingTables: [UInt8: JPEGLSMappingTable] = [:],
        restartIntervals: [Int] = []
    ) throws -> [MultiComponentImageData.ComponentData] {
        var components: [MultiComponentImageData.ComponentData] = []

        for (scanIndex, scanHeader) in scanHeaders.enumerated() {
            // Decode this component, with the restart interval in effect at
            // this scan's SOS (a DRI between scans applies to later scans only)
            var pixels = try decodeComponent(
                scanData: scanDataList[scanIndex],
                width: frameHeader.width,
                height: frameHeader.height,
                scanHeader: scanHeader,
                parameters: parameters,
                bitsPerSample: frameHeader.bitsPerSample,
                restartInterval: scanIndex < restartIntervals.count ? restartIntervals[scanIndex] : 0
            )

            // Apply mapping table lookup if the component references one
            let tableID = scanHeader.components[0].mappingTableID
            if tableID != 0, let table = mappingTables[tableID] {
                pixels = applyMappingTable(table, to: pixels)
            }

            components.append(MultiComponentImageData.ComponentData(
                id: scanHeader.components[0].id,
                pixels: pixels
            ))
        }

        return components
    }

    // MARK: - Line-Interleaved Decoding

    /// Decode line-interleaved image (all components in one scan, line by line)
    ///
    /// Supports both uniform-resolution images (all components at the full frame dimensions)
    /// and sub-sampled images where components have different dimensions.  For sub-sampled
    /// images the scan data is organised in **stripes**, each covering `vMax` rows of the
    /// reference grid.  Within each stripe, component *i* contributes `V_i` lines of width
    /// `ceil(frameWidth × H_i / Hmax)`, matching the JPEG-LS §C.2 line-interleaved format.
    private func decodeLineInterleaved(
        frameHeader: JPEGLSFrameHeader,
        scanHeader: JPEGLSScanHeader,
        scanData: Data,
        parameters: JPEGLSPresetParameters,
        mappingTables: [UInt8: JPEGLSMappingTable] = [:]
    ) throws -> [MultiComponentImageData.ComponentData] {
        let reader = JPEGLSBitstreamReader(data: scanData)
        let componentCount = scanHeader.componentCount
        let (limit, qbppBits) = computeGolombLimit(parameters: parameters, near: scanHeader.near, bitsPerSample: frameHeader.bitsPerSample)

        // Compute maximum sampling factors across all frame components.
        let hMax = max(1, frameHeader.components.map { Int($0.horizontalSamplingFactor) }.max() ?? 1)
        let vMax = max(1, frameHeader.components.map { Int($0.verticalSamplingFactor) }.max() ?? 1)

        // For each scan component, look up its sampling factors in the frame header and compute
        // its actual pixel dimensions.  For uniform images (all factors == 1) this reduces to the
        // full frame dimensions, preserving existing behaviour.
        let frameCompByID = Dictionary(uniqueKeysWithValues: frameHeader.components.map { ($0.id, $0) })
        var compWidths:   [Int] = []
        var compHeights:  [Int] = []
        var compVFactors: [Int] = []
        for i in 0..<componentCount {
            let scanCompID = scanHeader.components[i].id
            let h = frameCompByID[scanCompID].map { Int($0.horizontalSamplingFactor) } ?? 1
            let v = frameCompByID[scanCompID].map { Int($0.verticalSamplingFactor) } ?? 1
            compWidths.append((frameHeader.width  * h + hMax - 1) / hMax)
            compHeights.append((frameHeader.height * v + vMax - 1) / vMax)
            compVFactors.append(v)
        }

        // Initialize pixel buffers with per-component dimensions.
        var componentPixels = (0..<componentCount).map { i in
            Array(repeating: Array(repeating: 0, count: compWidths[i]), count: compHeights[i])
        }

        // Initialize shared decoder and context (one context shared across all components in interleaved mode)
        let decoder = try JPEGLSRegularModeDecoder(parameters: parameters, near: scanHeader.near)
        let runDecoder = try JPEGLSRunModeDecoder(parameters: parameters, near: scanHeader.near)
        var context = try JPEGLSContextModel(parameters: parameters, near: scanHeader.near)

        // Track left-edge values per component for boundary Rc at col=0.
        var prevRowEdges = Array(repeating: 0, count: componentCount)

        // Per-component RUNindex per ITU-T.87: each component line preserves its own run index.
        var componentRunIndex = Array(repeating: 0, count: componentCount)

        // Per-component row index: tracks the next row to decode within each component's grid.
        var compRowIndex = Array(repeating: 0, count: componentCount)

        // Number of stripes: ceil(frameHeight / vMax).  Each stripe covers vMax reference rows.
        let numStripes = (frameHeader.height + vMax - 1) / vMax

        for _ in 0..<numStripes {
            try checkCancellation()
            for componentIndex in 0..<componentCount {
                let vFactor   = compVFactors[componentIndex]
                let compWidth = compWidths[componentIndex]
                let compHeight = compHeights[componentIndex]

                // Decode vFactor lines for this component within the current stripe.
                for _ in 0..<vFactor {
                    let row = compRowIndex[componentIndex]
                    guard row < compHeight else { break }

                    // Restore this component's run index.
                    context.setRunIndex(componentRunIndex[componentIndex])

                    let edgeForThisRow = prevRowEdges[componentIndex]
                    if row > 0 {
                        prevRowEdges[componentIndex] = componentPixels[componentIndex][row - 1][0]
                    }

                    // Decode one line for this component.
                    try decodeLineForComponent(
                        reader: reader,
                        pixels: &componentPixels[componentIndex],
                        row: row,
                        width: compWidth,
                        decoder: decoder,
                        runDecoder: runDecoder,
                        context: &context,
                        scanHeader: scanHeader,
                        parameters: parameters,
                        limit: limit,
                        qbppBits: qbppBits,
                        prevRowEdge: edgeForThisRow
                    )

                    // Save this component's run index.
                    componentRunIndex[componentIndex] = context.currentRunIndex
                    compRowIndex[componentIndex] += 1
                }
            }
        }

        // Apply mapping table lookups per component
        return (0..<componentCount).map { componentIndex in
            let tableID = scanHeader.components[componentIndex].mappingTableID
            var pixels = componentPixels[componentIndex]
            if tableID != 0, let table = mappingTables[tableID] {
                pixels = applyMappingTable(table, to: pixels)
            }
            return MultiComponentImageData.ComponentData(
                id: scanHeader.components[componentIndex].id,
                pixels: pixels
            )
        }
    }

    // MARK: - Sample-Interleaved Decoding

    /// Decode sample-interleaved image (all components in one scan, pixel by pixel)
    ///
    /// Per ITU-T.87 §C.5, for ILV=2 run mode is entered when ALL components at
    /// the current sample position have zero quantised gradients.  A single run
    /// length is decoded for all components together, and when the run is
    /// interrupted an interruption sample is decoded for each component in turn.
    private func decodeSampleInterleaved(
        frameHeader: JPEGLSFrameHeader,
        scanHeader: JPEGLSScanHeader,
        scanData: Data,
        parameters: JPEGLSPresetParameters,
        mappingTables: [UInt8: JPEGLSMappingTable] = [:]
    ) throws -> [MultiComponentImageData.ComponentData] {
        let reader = JPEGLSBitstreamReader(data: scanData)
        let componentCount = scanHeader.componentCount
        let (limit, qbppBits) = computeGolombLimit(parameters: parameters, near: scanHeader.near, bitsPerSample: frameHeader.bitsPerSample)

        // Initialize pixel buffers for all components
        var componentPixels = (0..<componentCount).map { _ in
            return Array(repeating: Array(repeating: 0, count: frameHeader.width), count: frameHeader.height)
        }

        // Initialize shared decoder and context (one context shared across all components in interleaved mode)
        let decoder = try JPEGLSRegularModeDecoder(parameters: parameters, near: scanHeader.near)
        let runDecoder = try JPEGLSRunModeDecoder(parameters: parameters, near: scanHeader.near)
        var context = try JPEGLSContextModel(parameters: parameters, near: scanHeader.near)

        // Track left-edge values per component for boundary Rc at col=0.
        var prevRowEdges = Array(repeating: 0, count: componentCount)

        // Decode pixel by pixel, cycling through components
        for row in 0..<frameHeader.height {
            try checkCancellation()
            // Note: RUNindex is NOT reset per line. Per ITU-T.87 §A.7.1,
            // RUNindex persists across scan lines; it is only initialised to 0 at scan start.
            // Capture and advance edge values per component.
            let edgesForThisRow = prevRowEdges
            for ci in 0..<componentCount {
                if row > 0 { prevRowEdges[ci] = componentPixels[ci][row - 1][0] }
            }
            var col = 0
            while col < frameHeader.width {
                // Check run mode: ALL components must have zero quantised gradients at (row, col)
                var allGradientsZero = true
                for componentIndex in 0..<componentCount {
                    let (a, b, c, d) = getNeighbors(
                        pixels: componentPixels[componentIndex],
                        row: row, col: col, width: frameHeader.width,
                        prevRowEdge: edgesForThisRow[componentIndex]
                    )
                    let (d1, d2, d3) = decoder.computeGradients(a: a, b: b, c: c, d: d)
                    let q1 = decoder.quantizeGradient(d1)
                    let q2 = decoder.quantizeGradient(d2)
                    let q3 = decoder.quantizeGradient(d3)
                    if q1 != 0 || q2 != 0 || q3 != 0 {
                        allGradientsZero = false
                        break
                    }
                }

                if allGradientsZero {
                    // Run mode: decode ONE run length for all components simultaneously.
                    // The run value for each component is its own left neighbour 'a'.
                    let runValues = (0..<componentCount).map { ci in
                        getNeighbors(
                            pixels: componentPixels[ci],
                            row: row, col: col, width: frameHeader.width,
                            prevRowEdge: edgesForThisRow[ci]
                        ).a
                    }
                    let remainingInLine = frameHeader.width - col

                    // Decode run length (uses component 0's run value as the reference value;
                    // the actual run value per component is stored in runValues).
                    let runLength = try readRunLength(
                        reader: reader,
                        runDecoder: runDecoder,
                        context: &context,
                        remainingInLine: remainingInLine
                    )

                    // Fill run pixels for all components
                    for runOffset in 0..<runLength {
                        let c = col + runOffset
                        for componentIndex in 0..<componentCount {
                            componentPixels[componentIndex][row][c] = runValues[componentIndex]
                        }
                    }
                    var newCol = col + runLength

                    // If run was interrupted (ended before the line), decode one
                    // interruption sample per component.
                    // Per ITU-T.87 triplet handling: all components use riType=0 context,
                    // prediction = rb (from previous row), with sign(rb - ra) correction.
                    if runLength < remainingInLine && newCol < frameHeader.width {
                        let j = runDecoder.computeJ(runIndex: context.currentRunIndex)
                        let adjustedLimit = limit - j - 1

                        for componentIndex in 0..<componentCount {
                            let ra = runValues[componentIndex]
                            let rb: Int
                            if row > 0 && newCol < frameHeader.width {
                                rb = componentPixels[componentIndex][row - 1][newCol]
                            } else {
                                rb = 0
                            }

                            let riType = 0  // Always riType=0 for multi-component
                            let k = context.computeRunInterruptionGolombK(riType: riType)
                            let eMappedErrorValue = try readGolombCode(
                                reader: reader, k: k, limit: adjustedLimit, qbppBits: qbppBits
                            )

                            let errorValue = context.computeRunInterruptionErrorValue(
                                temp: eMappedErrorValue + riType, k: k, riType: riType
                            )

                            let signCorrectedError = errorValue * (rb >= ra ? 1 : -1)
                            let sample = runDecoder.reconstructSample(prediction: rb, error: signCorrectedError)

                            context.updateRunInterruptionContext(
                                errorValue: errorValue,
                                eMappedErrorValue: eMappedErrorValue,
                                riType: riType
                            )
                            componentPixels[componentIndex][row][newCol] = sample
                        }
                        // Per ITU-T.87, decrement RUNindex after the interruption pixel(s).
                        context.decrementRunIndex()
                        newCol += 1
                    }

                    col = newCol
                } else {
                    // Regular mode: decode each component independently at (row, col)
                    for componentIndex in 0..<componentCount {
                        let (a, b, c, d) = getNeighbors(
                            pixels: componentPixels[componentIndex],
                            row: row, col: col, width: frameHeader.width,
                            prevRowEdge: edgesForThisRow[componentIndex]
                        )
                        let (d1, d2, d3) = decoder.computeGradients(a: a, b: b, c: c, d: d)
                        let pixel = try decodeSinglePixel(
                            reader: reader,
                            decoder: decoder,
                            runDecoder: runDecoder,
                            context: &context,
                            a: a, b: b, c: c,
                            q1: decoder.quantizeGradient(d1),
                            q2: decoder.quantizeGradient(d2),
                            q3: decoder.quantizeGradient(d3),
                            parameters: parameters,
                            near: scanHeader.near,
                            limit: limit,
                            qbppBits: qbppBits
                        )
                        componentPixels[componentIndex][row][col] = pixel
                    }
                    col += 1
                }
            }
        }

        // Apply mapping table lookups per component
        return (0..<componentCount).map { componentIndex in
            let tableID = scanHeader.components[componentIndex].mappingTableID
            var pixels = componentPixels[componentIndex]
            if tableID != 0, let table = mappingTables[tableID] {
                pixels = applyMappingTable(table, to: pixels)
            }
            return MultiComponentImageData.ComponentData(
                id: scanHeader.components[componentIndex].id,
                pixels: pixels
            )
        }
    }

    // MARK: - Component Decoding

    /// Decode a single component (used for non-interleaved mode)
    private func decodeComponent(
        scanData: Data,
        width: Int,
        height: Int,
        scanHeader: JPEGLSScanHeader,
        parameters: JPEGLSPresetParameters,
        bitsPerSample: Int,
        restartInterval: Int = 0
    ) throws -> [[Int]] {
        let (limit, qbppBits) = computeGolombLimit(parameters: parameters, near: scanHeader.near, bitsPerSample: bitsPerSample)
        let near = scanHeader.near

        if restartInterval > 0 && restartInterval < height {
            // Restart intervals: split the scan body at its RSTm markers
            // (validating the D0–D7 cycle) and decode the independent
            // intervals concurrently — each restarts coding exactly as at
            // scan start, so a fresh region decode per interval is correct
            // by construction.
            let segments = try splitScanDataAtRestartMarkers(scanData)
            let intervalCount = (height + restartInterval - 1) / restartInterval
            guard segments.count == intervalCount else {
                throw JPEGLSError.invalidBitstreamStructure(
                    reason: "Expected \(intervalCount) restart intervals for \(height) lines, found \(segments.count)"
                )
            }
            let results = IntervalDecodeResults(count: intervalCount)
            DispatchQueue.concurrentPerform(iterations: intervalCount) { idx in
                do {
                    let rows = min(restartInterval, height - idx * restartInterval)
                    let region = try decodeFlatRegion(
                        reader: JPEGLSBitstreamReader(data: segments[idx]),
                        rows: rows, width: width,
                        parameters: parameters, near: near,
                        limit: limit, qbppBits: qbppBits
                    )
                    results.set(region, at: idx)
                } catch {
                    results.fail(error)
                }
            }
            let regions = try results.finish()
            var pixels: [[Int]] = []
            pixels.reserveCapacity(height)
            for (idx, region) in regions.enumerated() {
                guard let region else {
                    throw JPEGLSError.invalidBitstreamStructure(
                        reason: "Restart interval \(idx) produced no rows"
                    )
                }
                pixels.append(contentsOf: widenFlatRows(region, width: width))
            }
            return pixels
        }

        let flat = try decodeFlatRegion(
            reader: JPEGLSBitstreamReader(data: scanData),
            rows: height, width: width,
            parameters: parameters, near: near,
            limit: limit, qbppBits: qbppBits
        )
        return widenFlatRows(flat, width: width)
    }

    /// Whether a scan body contains an RSTm marker (0xFF followed by
    /// 0xD0–0xD7, skipping stuffed pairs). Used to reject stray restart
    /// markers in scans that have no active restart interval.
    private static func scanBodyContainsRestartMarker(_ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            var i = 0
            while i + 1 < raw.count {
                if raw[i] == 0xFF {
                    let next = raw[i + 1]
                    if next >= 0xD0 && next <= 0xD7 {
                        return true
                    }
                    if next < 0x80 {
                        i += 2  // stuffed pair — data
                        continue
                    }
                }
                i += 1
            }
            return false
        }
    }

    /// Split a scan body into its restart-interval segments, removing the
    /// RSTm markers and validating that they cycle FFD0–FFD7. Stuffed bytes
    /// (0xFF followed by < 0x80) are skipped as data; a lone 0xFF before a
    /// non-restart marker byte is treated as data (the encoder's final flush
    /// byte may legitimately be 0xFF).
    private func splitScanDataAtRestartMarkers(_ data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        var segments: [Data] = []
        var segmentStart = 0
        var markerIndex = 0
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 0xFF {
                let next = bytes[i + 1]
                if next >= JPEGLSMarker.restart0.rawValue && next <= JPEGLSMarker.restart7.rawValue {
                    let expected = JPEGLSMarker.restart0.rawValue + UInt8(markerIndex % 8)
                    guard next == expected else {
                        throw JPEGLSError.invalidBitstreamStructure(
                            reason: "Restart marker out of sequence: expected 0xFF\(String(expected, radix: 16, uppercase: true)), found 0xFF\(String(next, radix: 16, uppercase: true))"
                        )
                    }
                    segments.append(Data(bytes[segmentStart..<i]))
                    segmentStart = i + 2
                    markerIndex += 1
                    i += 2
                    continue
                }
                if next < 0x80 {
                    i += 2  // stuffed pair — data
                    continue
                }
                i += 1  // data/fill 0xFF before a non-restart marker byte
                continue
            }
            i += 1
        }
        segments.append(Data(bytes[segmentStart..<bytes.count]))
        return segments
    }

    /// Widen a flat UInt16 plane back to the public [[Int]] row representation.
    private func widenFlatRows(_ flat: [UInt16], width: Int) -> [[Int]] {
        let rows = flat.count / width
        return flat.withUnsafeBufferPointer { buf in
            (0..<rows).map { row -> [Int] in
                let base = row * width
                return [Int](unsafeUninitializedCapacity: width) { out, count in
                    for i in 0..<width {
                        out[i] = Int(buf[base + i])
                    }
                    count = width
                }
            }
        }
    }

    /// Decode `rows` scan lines as one independent coding region with
    /// scan-start semantics (fresh contexts and run state; the first row
    /// uses the zero previous-line boundary rule). A whole scan is one
    /// region; with restart intervals, every interval is one region.
    ///
    /// Decodes into a flat UInt16 plane (samples are clamped to
    /// MAXVAL ≤ 2^16 − 1 by the pipeline) accessed through one unsafe
    /// buffer scoped over the whole region: no nested-array indirection,
    /// no per-access bounds checks, no copy-on-write uniqueness checks
    /// per row, and half the memory traffic of [[Int]].
    private func decodeFlatRegion(
        reader: JPEGLSBitstreamReader,
        rows: Int,
        width: Int,
        parameters: JPEGLSPresetParameters,
        near: Int,
        limit: Int,
        qbppBits: Int
    ) throws -> [UInt16] {
        var flat = [UInt16](repeating: 0, count: width * rows)
        try flat.withUnsafeMutableBufferPointer { buf in
            try decodeRegion(reader: reader, rows: rows, width: width, parameters: parameters, near: near,
                             limit: limit, qbppBits: qbppBits, into: buf, finishRow: nil)
        }
        return flat
    }

    /// The region decoder over caller storage of `rows × width` samples. `finishRow` receives every row once no
    /// later prediction reads it (after the next row, and the last row at the end), so it may rewrite the row.
    /// Pre-specialised: the public caller is generic across modules, and an unspecialised loop runs ~40 % slower.
    @_specialize(where Sample == UInt8)
    @_specialize(where Sample == UInt16)
    private func decodeRegion<Sample: FixedWidthInteger & UnsignedInteger>(
        reader: JPEGLSBitstreamReader,
        rows: Int,
        width: Int,
        parameters: JPEGLSPresetParameters,
        near: Int,
        limit: Int,
        qbppBits: Int,
        into buf: UnsafeMutableBufferPointer<Sample>,
        finishRow: (@Sendable (UnsafeMutableBufferPointer<Sample>) -> Void)?
    ) throws {
        let decoder = try JPEGLSRegularModeDecoder(parameters: parameters, near: near)
        let runDecoder = try JPEGLSRunModeDecoder(parameters: parameters, near: near)
        var context = try JPEGLSContextModel(parameters: parameters, near: near)
        func finish(_ row: Int) {
            guard let finishRow else { return }
            finishRow(UnsafeMutableBufferPointer(rebasing: buf[(row * width)..<((row + 1) * width)]))
        }

        do {
            // Track the left-edge value for boundary Rc at col=0.
            // The edge buffer is previous_line[0], which equals the first pixel
            // of the row decoded two iterations ago (0 for rows 0 and 1).
            var prevRowEdge = 0

            // Decode pixels in raster order
            for row in 0..<rows {
                try checkCancellation()
                // Note: RUNindex is NOT reset per line. Per ITU-T.87 §A.7.1,
                // RUNindex persists across scan lines; it is only initialised to 0 at scan start.
                let rowBase = row * width
                let prevBase = rowBase - width

                // Capture the edge value before this row updates it.
                let edgeForThisRow = prevRowEdge
                if row > 0 {
                    prevRowEdge = Int(buf[prevBase])
                }
                var col = 0
                while col < width {
                    // Causal neighbours per ITU-T.87 §3.2 (same boundary
                    // semantics as getNeighbors, over the flat plane).
                    let a: Int, b: Int, c: Int, d: Int
                    if row == 0 {
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
                    let (d1, d2, d3) = decoder.computeGradients(a: a, b: b, c: c, d: d)
                    let q1 = decoder.quantizeGradient(d1)
                    let q2 = decoder.quantizeGradient(d2)
                    let q3 = decoder.quantizeGradient(d3)

                    if q1 == 0 && q2 == 0 && q3 == 0 {
                        // Run mode: decode run of pixels with value = a.
                        // readRunLength clamps to remainingInLine, so the
                        // fill below cannot overrun the row.
                        let remainingInLine = width - col
                        let runLength = try readRunLength(
                            reader: reader,
                            runDecoder: runDecoder,
                            context: &context,
                            remainingInLine: remainingInLine
                        )
                        if runLength > 0 {
                            let rv = Sample(truncatingIfNeeded: a)
                            for i in (rowBase + col)..<(rowBase + col + runLength) {
                                buf[i] = rv
                            }
                            col += runLength
                        }

                        if runLength < remainingInLine {
                            // Interrupted run: decode the interruption sample
                            // (per ITU-T.87 §A.7.2).
                            let ra = a
                            let rb = row > 0 ? Int(buf[prevBase + col]) : 0
                            let riType = (abs(ra - rb) <= near) ? 1 : 0
                            let k = context.computeRunInterruptionGolombK(riType: riType)
                            let j = runDecoder.computeJ(runIndex: context.currentRunIndex)
                            let adjustedLimit = limit - j - 1
                            let eMappedErrorValue = try readGolombCode(
                                reader: reader, k: k, limit: adjustedLimit, qbppBits: qbppBits
                            )
                            let errorValue = context.computeRunInterruptionErrorValue(
                                temp: eMappedErrorValue + riType, k: k, riType: riType
                            )
                            let sample: Int
                            if riType == 1 {
                                sample = runDecoder.reconstructSample(prediction: ra, error: errorValue)
                            } else {
                                let signCorrectedError = errorValue * (rb >= ra ? 1 : -1)
                                sample = runDecoder.reconstructSample(prediction: rb, error: signCorrectedError)
                            }
                            context.updateRunInterruptionContext(
                                errorValue: errorValue,
                                eMappedErrorValue: eMappedErrorValue,
                                riType: riType
                            )
                            // Per ITU-T.87, decrement RUNindex AFTER the interruption pixel.
                            context.decrementRunIndex()

                            buf[rowBase + col] = Sample(truncatingIfNeeded: sample)
                            col += 1
                        }
                    } else {
                        // Regular mode
                        let pixel = try decodeSinglePixel(
                            reader: reader,
                            decoder: decoder,
                            runDecoder: runDecoder,
                            context: &context,
                            a: a, b: b, c: c,
                            q1: q1, q2: q2, q3: q3,
                            parameters: parameters,
                            near: near,
                            limit: limit,
                            qbppBits: qbppBits
                        )
                        buf[rowBase + col] = Sample(truncatingIfNeeded: pixel)
                        col += 1
                    }
                }
                if row > 0 { finish(row - 1) }
            }
            if rows > 0 { finish(rows - 1) }
        }
    }

    /// Decode a single line for a component (used for line-interleaved mode)
    private func decodeLineForComponent(
        reader: JPEGLSBitstreamReader,
        pixels: inout [[Int]],
        row: Int,
        width: Int,
        decoder: JPEGLSRegularModeDecoder,
        runDecoder: JPEGLSRunModeDecoder,
        context: inout JPEGLSContextModel,
        scanHeader: JPEGLSScanHeader,
        parameters: JPEGLSPresetParameters,
        limit: Int,
        qbppBits: Int,
        prevRowEdge: Int = 0
    ) throws {
        // Note: RUNindex is NOT reset per line. Per ITU-T.87 §A.7.1,
        // RUNindex persists across scan lines; it is only initialised to 0 at scan start.
        var col = 0
        while col < width {
            // Get neighbor pixels
            let (a, b, c, d) = getNeighbors(pixels: pixels, row: row, col: col, width: width, prevRowEdge: prevRowEdge)

            // Check for run mode: all quantized gradients are zero
            let (d1, d2, d3) = decoder.computeGradients(a: a, b: b, c: c, d: d)
            let q1 = decoder.quantizeGradient(d1)
            let q2 = decoder.quantizeGradient(d2)
            let q3 = decoder.quantizeGradient(d3)

            if q1 == 0 && q2 == 0 && q3 == 0 {
                // Run mode: decode run of pixels with value = a (the run value)
                let runResult = try decodeRun(
                    reader: reader,
                    runDecoder: runDecoder,
                    context: &context,
                    runValue: a,
                    row: row,
                    col: col,
                    previousRow: row > 0 ? pixels[row - 1] : nil,
                    remainingInLine: width - col,
                    parameters: parameters,
                    near: scanHeader.near,
                    limit: limit,
                    qbppBits: qbppBits
                )

                // Fill in run result
                col = fillRunResult(
                    runResult: runResult,
                    pixels: &pixels,
                    row: row,
                    col: col,
                    width: width,
                    runValue: a
                )
            } else {
                // Regular mode
                let pixel = try decodeSinglePixel(
                    reader: reader,
                    decoder: decoder,
                    runDecoder: runDecoder,
                    context: &context,
                    a: a, b: b, c: c,
                    q1: q1, q2: q2, q3: q3,
                    parameters: parameters,
                    near: scanHeader.near,
                    limit: limit,
                    qbppBits: qbppBits
                )

                pixels[row][col] = pixel
                col += 1
            }
        }
    }

    // MARK: - Pixel Decoding

    /// Fill decoded run result into pixel buffer, returning the new column position
    private func fillRunResult(
        runResult: (runLength: Int, interruptionPixel: Int?),
        pixels: inout [[Int]],
        row: Int,
        col: Int,
        width: Int,
        runValue: Int
    ) -> Int {
        var newCol = col

        // Fill in run pixels
        for i in 0..<runResult.runLength {
            if newCol + i < width {
                pixels[row][newCol + i] = runValue
            }
        }
        newCol += runResult.runLength

        // If there was an interruption pixel, add it
        if let interruptionPixel = runResult.interruptionPixel {
            if newCol < width {
                pixels[row][newCol] = interruptionPixel
                newCol += 1
            }
        }

        return newCol
    }

    /// Decode a single pixel in regular mode
    private func decodeSinglePixel(
        reader: JPEGLSBitstreamReader,
        decoder: JPEGLSRegularModeDecoder,
        runDecoder: JPEGLSRunModeDecoder,
        context: inout JPEGLSContextModel,
        a: Int, b: Int, c: Int,
        q1: Int, q2: Int, q3: Int,
        parameters: JPEGLSPresetParameters,
        near: Int,
        limit: Int,
        qbppBits: Int
    ) throws -> Int {
        // Get context, reusing the quantized gradients the scan loop already
        // computed for the run-mode test. Bias C[Q], Golomb k, and the k=0
        // error correction come from a single context-record load.
        let (contextIndex, sign) = context.computeContextIndexAndSign(q1: q1, q2: q2, q3: q3)
        let (biasC, k, errorCorrection) = context.pixelCodingState(contextIndex: contextIndex)

        // Read Golomb-Rice encoded error
        let mappedError = try readGolombCode(reader: reader, k: k, limit: limit, qbppBits: qbppBits)

        // Decode pixel using decoder
        let result = decoder.decodePixel(
            mappedError: mappedError,
            a: a, b: b, c: c,
            contextIndex: contextIndex,
            sign: sign,
            biasC: biasC,
            errorCorrection: errorCorrection
        )

        // Update context
        context.updateContext(
            contextIndex: contextIndex,
            predictionError: result.error,
            sign: result.sign
        )

        return result.sample
    }

    /// Decode a run of identical pixels
    private func decodeRun(
        reader: JPEGLSBitstreamReader,
        runDecoder: JPEGLSRunModeDecoder,
        context: inout JPEGLSContextModel,
        runValue: Int,
        row: Int,
        col: Int,
        previousRow: [Int]?,
        remainingInLine: Int,
        parameters: JPEGLSPresetParameters,
        near: Int,
        limit: Int,
        qbppBits: Int
    ) throws -> (runLength: Int, interruptionPixel: Int?) {
        // Read run length (also updates context.runIndex)
        let runLength = try readRunLength(
            reader: reader,
            runDecoder: runDecoder,
            context: &context,
            remainingInLine: remainingInLine
        )

        // If run ends before end of line, decode interruption pixel
        if runLength < remainingInLine {
            let ra = runValue

            // Compute Rb at the interruption position (col + runLength in the previous row)
            let interruptionCol = col + runLength
            let rb: Int
            if let prevRow = previousRow, interruptionCol < prevRow.count {
                rb = prevRow[interruptionCol]
            } else {
                rb = 0  // First row or out of bounds
            }

            // Determine RItype per ITU-T.87: type 1 if |Ra-Rb| <= NEAR
            let riType = (abs(ra - rb) <= near) ? 1 : 0

            // Per ITU-T.87 §4.5.3, the Golomb parameter uses RItype-aware context
            let k = context.computeRunInterruptionGolombK(riType: riType)

            // Per ITU-T.87, the LIMIT for run interruption Golomb code is adjusted:
            // limit_ri = LIMIT - J[RUNindex] - 1
            let j = runDecoder.computeJ(runIndex: context.currentRunIndex)
            let adjustedLimit = limit - j - 1

            // Read Golomb-Rice encoded interruption error (using adjusted limit)
            let eMappedErrorValue = try readGolombCode(
                reader: reader, k: k, limit: adjustedLimit, qbppBits: qbppBits
            )

            // Per ITU-T.87, compute error value with RItype offset:
            // error = compute_error_value(eMappedErrorValue + riType, k)
            let errorValue = context.computeRunInterruptionErrorValue(
                temp: eMappedErrorValue + riType, k: k, riType: riType
            )

            // Prediction and sign correction per ITU-T.87
            let prediction: Int
            let sample: Int
            if riType == 1 {
                // RItype=1: predict from Ra, no sign correction
                prediction = ra
                sample = runDecoder.reconstructSample(prediction: prediction, error: errorValue)
            } else {
                // RItype=0: predict from Rb, apply sign(Rb-Ra)
                prediction = rb
                let signCorrectedError = errorValue * (rb >= ra ? 1 : -1)
                sample = runDecoder.reconstructSample(prediction: prediction, error: signCorrectedError)
            }

            // Update run interruption context statistics per ITU-T.87
            context.updateRunInterruptionContext(
                errorValue: errorValue,
                eMappedErrorValue: eMappedErrorValue,
                riType: riType
            )

            // Per ITU-T.87, decrement RUNindex AFTER the interruption pixel
            // is decoded (not during run-length reading).
            context.decrementRunIndex()

            return (runLength, sample)
        }

        // Full run to end of line
        return (runLength, nil)
    }

    // MARK: - Golomb-Rice Limit Computation

    /// Compute the Golomb-Rice bit-range parameter (qbppBits) and LIMIT for a scan.
    ///
    /// Per ITU-T.87 §4.4, LIMIT = 2 × (bpp + max(8, bpp)) where bpp is the
    /// original bits per sample, and qbppBits = ⌈log₂(RANGE)⌉.
    ///
    /// - Parameters:
    ///   - parameters: Preset coding parameters (MAXVAL, etc.)
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
        // qbppBits = ⌈log₂(range)⌉
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

    // MARK: - Golomb-Rice Decoding

    /// Read Golomb-Rice encoded value from bitstream per ITU-T.87 §6.1.2.
    ///
    /// Implements the limited Golomb-Rice code: reads zeros until a '1' is found.
    /// If the zero count reaches (LIMIT − qbppBits − 1) before the '1', the encoder
    /// switched to a limited binary code; in that case qbppBits bits are read for
    /// MErrval − 1.  Otherwise the standard code (quotient << k) | remainder is used.
    ///
    /// - Parameters:
    ///   - reader: Bitstream reader
    ///   - k: Golomb-Rice parameter
    ///   - limit: LIMIT = 2 × (qbppBits + 8)
    ///   - qbppBits: ⌈log₂(RANGE)⌉ — bits needed to represent the full error range
    /// - Returns: Mapped error value (MErrval)
    /// - Throws: `JPEGLSError` if reading fails
    private func readGolombCode(
        reader: JPEGLSBitstreamReader,
        k: Int,
        limit: Int,
        qbppBits: Int
    ) throws -> Int {
        let limitThreshold = limit - qbppBits - 1
        // Read unary prefix (count zeros until first '1')
        let unaryCount = try reader.readUnaryCount()
        // Per ITU-T.87 §6.1.2: when unaryCount >= limitThreshold the encoder used
        // the limited binary code — read qbppBits bits for MErrval − 1.
        if unaryCount >= limitThreshold {
            let rawValue = Int(try reader.readBits(qbppBits))
            return rawValue + 1
        }
        // Standard Golomb-Rice code
        let remainder = k > 0 ? Int(try reader.readBits(k)) : 0
        return (unaryCount << k) | remainder
    }

    /// Read run length from bitstream
    ///
    /// Decodes variable-length run encoding per ITU-T.87.
    /// Each '1' bit means 2^J pixels of run. A '0' bit terminates the run
    /// and is followed by J remainder bits.
    ///
    /// - Parameters:
    ///   - reader: Bitstream reader
    ///   - runDecoder: Run mode decoder
    ///   - context: Context model (for J parameter)
    ///   - remainingInLine: Pixels remaining in current line
    /// - Returns: Decoded run length
    /// - Throws: `JPEGLSError` if reading fails
    private func readRunLength(
        reader: JPEGLSBitstreamReader,
        runDecoder: JPEGLSRunModeDecoder,
        context: inout JPEGLSContextModel,
        remainingInLine: Int
    ) throws -> Int {
        var runLength = 0
        var runIndex = context.currentRunIndex

        // Read continuation bits per ITU-T.87 §A.7.1.
        // Each '1' bit contributes min(2^J[RUNindex], remaining) pixels.
        // run_index is only incremented when a FULL block is used.
        while true {
            let bit = try reader.readBits(1)
            if bit == 0 {
                break  // Run interrupted
            }
            let j = runDecoder.computeJ(runIndex: runIndex)
            let blockSize = 1 << j  // 2^J
            let count = min(blockSize, remainingInLine - runLength)
            runLength += count

            // Only increment run_index when a full block was consumed
            if count == blockSize && runIndex < 31 {
                runIndex += 1
            }

            if runLength >= remainingInLine {
                break  // Run reached end of line
            }
        }

        if runLength < remainingInLine {
            // Incomplete run — read J[RUNindex] remainder bits.
            // Note: run_index is NOT decremented here; the caller decrements
            // after the interruption pixel is decoded (matching ITU-T.87).
            let j = runDecoder.computeJ(runIndex: runIndex)
            let remainder = j > 0 ? Int(try reader.readBits(j)) : 0
            runLength += remainder
        }

        context.setRunIndex(runIndex)
        return min(runLength, remainingInLine)
    }

    // MARK: - Helper Methods

    /// Apply a mapping table lookup to a decoded pixel buffer.
    ///
    /// Each raw sample value is used as an index into the mapping table, and the
    /// corresponding table entry replaces the raw value.
    ///
    /// - Parameters:
    ///   - table: The mapping table to apply.
    ///   - pixels: Raw decoded pixel buffer (rows of columns).
    /// - Returns: Pixel buffer with mapped values.
    private func applyMappingTable(_ table: JPEGLSMappingTable, to pixels: [[Int]]) -> [[Int]] {
        return pixels.map { row in
            row.map { table.map($0) }
        }
    }

    /// Get neighbor pixels for gradient computation
    ///
    /// Handles boundary conditions per ITU-T.87 Section 3.2.
    /// At col=0, row>0, the top-left (Rc) is the edge pixel from the
    /// previous row — not the first pixel of the previous row.
    ///
    /// - Parameters:
    ///   - pixels: Current pixel buffer
    ///   - row: Current row
    ///   - col: Current column
    ///   - width: Image width (for top-right boundary check)
    ///   - prevRowEdge: The left-edge value of the previous row (Rc at col=0).
    ///                  Equals 0 for row 0–1, then first pixel of row r−2 for row r.
    /// - Returns: Tuple of (a, b, c, d) neighbor pixels
    private func getNeighbors(
        pixels: [[Int]],
        row: Int,
        col: Int,
        width: Int,
        prevRowEdge: Int = 0
    ) -> (a: Int, b: Int, c: Int, d: Int) {
        if row == 0 && col == 0 {
            return (0, 0, 0, 0)
        } else if row == 0 {
            // First row: no scan line above; top/top-left/top-right are 0
            // per ITU-T.87 §3.2 boundary initialisation.
            let left = pixels[row][col - 1]
            return (left, 0, 0, 0)
        } else if col == 0 {
            let top = pixels[row - 1][col]
            let topRight = (col + 1 < width) ? pixels[row - 1][col + 1] : top
            return (top, top, prevRowEdge, topRight)
        } else {
            let a = pixels[row][col - 1]      // Left
            let b = pixels[row - 1][col]      // Top
            let c = pixels[row - 1][col - 1]  // Top-left
            let d = (col + 1 < width) ? pixels[row - 1][col + 1] : b  // Top-right (or top if at edge)
            return (a, b, c, d)
        }
    }
}
