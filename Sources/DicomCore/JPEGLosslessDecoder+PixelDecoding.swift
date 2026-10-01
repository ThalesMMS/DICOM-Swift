import Foundation

extension JPEGLosslessDecoder {
    // MARK: - Pixel Decoding

    /// Decodes the entropy-coded segment of a JPEG lossless (SOF3) stream into row-major samples.
    ///
    /// Samples are reconstructed per T.81 Annex H: the selected predictor (Ss = 0...7) over the point-transformed
    /// samples, modulo 2^16, then shifted left by the point transform (Al) as libjpeg-turbo outputs them. One or
    /// three components with 1x1 sampling in a single interleaved scan are supported; restart intervals are whole
    /// MCU rows (the libjpeg-turbo rule) and reset prediction like the start of a scan.
    /// - Returns: `width × height` samples for one component, or interleaved (R,G,B per pixel) for three.
    /// - Throws: `DICOMError.invalidDICOMFormat` for missing tables, invalid codes, malformed restart framing,
    ///   out-of-range categories or unsupported component layouts.
    func decodePixels(
        data: Data,
        sof3: SOF3Info,
        sos: SOSInfo,
        compressedDataStart: Int
    ) throws -> [UInt16] {
        let width = sof3.width
        let height = sof3.height
        let precision = sof3.precision
        let componentCount = sof3.numberOfComponents

        guard componentCount == 1 || componentCount == 3 else {
            throw DICOMError.invalidDICOMFormat(
                reason: "JPEG Lossless multi-component decode supports 1 (grayscale) or 3 (interleaved color) components; the frame declares \(componentCount)"
            )
        }
        guard sos.components.count == componentCount else {
            throw DICOMError.invalidDICOMFormat(
                reason: "JPEG Lossless multi-component decode requires a single interleaved scan over all \(componentCount) frame components; the scan selects \(sos.components.count)"
            )
        }
        if componentCount > 1 {
            for component in sof3.components where component.horizontalSamplingFactor != 1
                || component.verticalSamplingFactor != 1 {
                throw DICOMError.invalidDICOMFormat(
                    reason: "JPEG Lossless multi-component decode requires 1x1 sampling; component \(component.id) declares "
                        + "\(component.horizontalSamplingFactor)x\(component.verticalSamplingFactor)"
                )
            }
        }

        let pixelCount = width.multipliedReportingOverflow(by: height)
        guard !pixelCount.overflow, pixelCount.partialValue > 0 else {
            throw DICOMError.invalidDICOMFormat(reason: "JPEG Lossless image dimensions overflow: \(width)x\(height)")
        }
        let numPixels = pixelCount.partialValue
        let maxPixelCount = Int(DCMDecoder.maxPixelBufferSize / Int64(MemoryLayout<UInt16>.stride))
        guard numPixels <= maxPixelCount / componentCount else {
            throw DICOMError.invalidDICOMFormat(reason: "JPEG Lossless image pixel count \(numPixels * componentCount) exceeds maximum \(maxPixelCount)")
        }
        if restartInterval > 0, restartInterval % width != 0 {
            throw DICOMError.invalidDICOMFormat(
                reason: "JPEG Lossless restart interval \(restartInterval) must be an integer multiple of "
                    + "the MCU row width \(width)"
            )
        }

        // Huffman table per scan component.
        var componentTables = [HuffmanTable]()
        for componentSelector in sos.components {
            let tableKey = 0 << 4 | Int(componentSelector.dcTableSelector)
            guard var huffmanTable = huffmanTables[tableKey] else {
                throw DICOMError.invalidDICOMFormat(reason: "Huffman table not found: class=0, id=\(componentSelector.dcTableSelector)")
            }
            if huffmanTable.minCode.isEmpty || huffmanTable.lookup.isEmpty {
                buildHuffmanDecodingTables(table: &huffmanTable)
                huffmanTables[tableKey] = huffmanTable
            }
            componentTables.append(huffmanTable)
        }

        if restartInterval == 0 {
            guard !containsRestartMarker(data: data, startIndex: compressedDataStart, endIndex: data.count) else {
                throw DICOMError.invalidDICOMFormat(
                    reason: "JPEG Lossless restart markers (RSTn) appear in the entropy-coded data but no restart interval was defined (missing DRI marker)"
                )
            }
        }

        let pointTransform = Int(sos.successiveApproximationLow)
        let transformedPrecision = precision - pointTransform
        let transformedMask = (1 << transformedPrecision) - 1
        let initialPredictor = 1 << max(0, transformedPrecision - 1)
        let mode = sos.selectionValue
        let rowsPerInterval = restartInterval > 0 ? restartInterval / width : 0

        // Plane-major sample buffer (component c occupies [c * numPixels, (c + 1) * numPixels)). Interleaved
        // scans carry one sample of each component per MCU in raster order.
        var samples = [UInt16](repeating: 0, count: numPixels * componentCount)
        let tables = componentTables.map { JPEGLosslessDecodingTable($0) }
        defer { tables.forEach { $0.deallocate() } }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var reader = JPEGLosslessEntropyReader(bytes: bytes, start: compressedDataStart, end: data.count)
            try samples.withUnsafeMutableBufferPointer { buffer in
                var restartCount = 0
                for y in 0..<height {
                    var firstLine = y == 0
                    if rowsPerInterval > 0, y > 0, y % rowsPerInterval == 0 {
                        let found = try reader.consumeRestartMarker()
                        let expected = restartCount % 8
                        guard found == expected else {
                            throw DICOMError.invalidDICOMFormat(
                                reason: "JPEG Lossless restart marker out of order at MCU \(y * width): expected RST\(expected), found RST\(found)"
                            )
                        }
                        restartCount += 1
                        // T.81 H.1.2.1: prediction restarts as at the beginning of the scan.
                        firstLine = true
                    }
                    let rowBase = y * width
                    if componentCount == 1 {
                        try Self.decodeRow(
                            buffer: buffer, planeBase: 0, rowBase: rowBase, width: width, firstLine: firstLine, mode: mode,
                            initialPredictor: initialPredictor, transformedMask: transformedMask, precision: precision,
                            table: tables[0], reader: &reader
                        )
                    } else {
                        for x in 0..<width {
                            for component in 0..<componentCount {
                                try Self.decodeSample(
                                    buffer: buffer, planeBase: component * numPixels, rowBase: rowBase, x: x, width: width,
                                    firstLine: firstLine, mode: mode, initialPredictor: initialPredictor,
                                    transformedMask: transformedMask, precision: precision,
                                    table: tables[component], reader: &reader
                                )
                            }
                        }
                    }
                }
            }
        }

        if pointTransform > 0 {
            let shift = UInt16(pointTransform)
            samples.withUnsafeMutableBufferPointer { buffer in
                for index in 0..<buffer.count { buffer[index] <<= shift }
            }
        }
        if componentCount == 1 {
            return samples
        }
        // Interleave component planes (R,G,B per pixel).
        var interleaved = [UInt16](repeating: 0, count: numPixels * componentCount)
        interleaved.withUnsafeMutableBufferPointer { output in
            samples.withUnsafeBufferPointer { planes in
                for component in 0..<componentCount {
                    var target = component
                    let planeBase = component * numPixels
                    for pixel in 0..<numPixels {
                        output[target] = planes[planeBase + pixel]
                        target += componentCount
                    }
                }
            }
        }
        return interleaved
    }

    /// Tight single-component row loop.
    @inline(__always)
    private static func decodeRow(
        buffer: UnsafeMutableBufferPointer<UInt16>, planeBase: Int, rowBase: Int, width: Int, firstLine: Bool, mode: Int,
        initialPredictor: Int, transformedMask: Int, precision: Int, table: JPEGLosslessDecodingTable,
        reader: inout JPEGLosslessEntropyReader
    ) throws {
        for x in 0..<width {
            try decodeSample(buffer: buffer, planeBase: planeBase, rowBase: rowBase, x: x, width: width, firstLine: firstLine,
                             mode: mode, initialPredictor: initialPredictor, transformedMask: transformedMask,
                             precision: precision, table: table, reader: &reader)
        }
    }

    @inline(__always)
    private static func decodeSample(
        buffer: UnsafeMutableBufferPointer<UInt16>, planeBase: Int, rowBase: Int, x: Int, width: Int, firstLine: Bool,
        mode: Int, initialPredictor: Int, transformedMask: Int, precision: Int, table: JPEGLosslessDecodingTable,
        reader: inout JPEGLosslessEntropyReader
    ) throws {
        let index = planeBase + rowBase + x
        let predictor = predict(buffer: buffer, index: index, x: x, width: width, firstLine: firstLine,
                                mode: mode, initialPredictor: initialPredictor)
        let category = try reader.decodeSymbol(table)
        // Predictors 4...7 can predict outside the sample range, so a P-bit image legitimately carries categories
        // above P (libjpeg-turbo writes them); only categories above 16 are impossible (T.81 Table H.2).
        guard category <= 16 else {
            throw DICOMError.invalidDICOMFormat(reason: "Invalid SSSS value: \(category) exceeds the maximum difference category 16 (sample precision \(precision))")
        }
        let difference = try reader.readDifference(category: category)
        buffer[index] = UInt16(truncatingIfNeeded: (predictor + difference) & 0xFFFF & transformedMask)
    }

    /// T.81 H.1.2.1 prediction: selection 0 is no prediction; the first line of a scan or restart interval uses
    /// Ra (the initial predictor at its start); later lines use Rb at the line start and the selected predictor elsewhere.
    @inline(__always)
    static func predict(
        buffer: UnsafeMutableBufferPointer<UInt16>, index: Int, x: Int, width: Int, firstLine: Bool,
        mode: Int, initialPredictor: Int
    ) -> Int {
        if mode == 0 { return 0 }
        if firstLine { return x == 0 ? initialPredictor : Int(buffer[index - 1]) }
        if x == 0 { return Int(buffer[index - width]) }
        let ra = Int(buffer[index - 1])
        let rb = Int(buffer[index - width])
        switch mode {
        case 1: return ra
        case 2: return rb
        case 3: return Int(buffer[index - width - 1])
        case 4: return ra + rb - Int(buffer[index - width - 1])
        case 5: return ra + ((rb - Int(buffer[index - width - 1])) >> 1)
        case 6: return rb + ((ra - Int(buffer[index - width - 1])) >> 1)
        default: return (ra + rb) >> 1
        }
    }

    private func containsRestartMarker(data: Data, startIndex: Int, endIndex: Int) -> Bool {
        var index = startIndex
        while index + 1 < endIndex {
            guard data[index] == JPEGMarker.prefix else {
                index += 1
                continue
            }

            var markerIndex = index + 1
            while markerIndex < endIndex && data[markerIndex] == JPEGMarker.prefix {
                markerIndex += 1
            }

            guard markerIndex < endIndex else { return false }

            let marker = data[markerIndex]
            if marker == JPEGMarker.stuffingByte {
                index = markerIndex + 1
                continue
            }

            if JPEGMarker.isRestart(marker) {
                return true
            }

            index = markerIndex + 1
        }

        return false
    }
}
