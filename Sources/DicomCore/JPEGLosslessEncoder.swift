//
//  JPEGLosslessEncoder.swift
//  DicomCore
//
//  Own JPEG lossless (ITU-T T.81 Annex H, SOF3 process 14) encoder: predictors 1...7, point transform, restart
//  intervals in whole MCU rows, 2...16-bit samples, one or three interleaved 1x1 components, and optimal
//  length-limited Huffman tables built from the difference statistics (Annex K.2). The codestream decodes
//  exactly in `JPEGLosslessDecoder` and in libjpeg-turbo; DICOM transfer syntax 1.2.840.10008.1.2.4.70 requires
//  predictor 1, which the backend enforces.
//

import Foundation

/// Options of the own SOF3 encoder.
struct JPEGLosslessEncodingParameters: Equatable, Sendable {
    /// Predictor selection value Ss (T.81 Table H.1): 1 = Ra, 2 = Rb, 3 = Rc, 4 = Ra+Rb−Rc, 5 = Ra+((Rb−Rc)>>1),
    /// 6 = Rb+((Ra−Rc)>>1), 7 = (Ra+Rb)>>1.
    var predictor: Int = 1
    /// Point transform Pt (Al): the samples are shifted right by this many bits before prediction (lossy when > 0).
    var pointTransform: Int = 0
    /// Restart interval in MCU rows (0 = none); DRI carries `rows × width` MCUs.
    var restartIntervalRows: Int = 0

    init(predictor: Int = 1, pointTransform: Int = 0, restartIntervalRows: Int = 0) {
        self.predictor = predictor
        self.pointTransform = pointTransform
        self.restartIntervalRows = restartIntervalRows
    }
}

enum JPEGLosslessEncoderError: Error, Equatable, LocalizedError, Sendable {
    case invalidParameters(String)
    case invalidImage(String)

    var errorDescription: String? {
        switch self {
        case .invalidParameters(let reason): return "Invalid JPEG lossless encoding parameters: \(reason)"
        case .invalidImage(let reason): return "Invalid JPEG lossless source image: \(reason)"
        }
    }
}

enum JPEGLosslessEncoder {
    /// Encodes row-major samples (interleaved R,G,B per pixel for three components) into a complete SOF3 codestream.
    static func encode(
        samples: [UInt16],
        width: Int,
        height: Int,
        precision: Int,
        componentCount: Int,
        parameters: JPEGLosslessEncodingParameters = JPEGLosslessEncodingParameters()
    ) throws -> Data {
        guard (1...65535).contains(width), (1...65535).contains(height) else {
            throw JPEGLosslessEncoderError.invalidImage("dimensions \(width)x\(height) must be 1...65535")
        }
        guard (2...16).contains(precision) else {
            throw JPEGLosslessEncoderError.invalidImage("precision \(precision) must be 2...16 bits")
        }
        guard componentCount == 1 || componentCount == 3 else {
            throw JPEGLosslessEncoderError.invalidImage("\(componentCount) components; 1 (grayscale) or 3 (interleaved colour) are encodable")
        }
        let numPixels = width * height
        guard samples.count == numPixels * componentCount else {
            throw JPEGLosslessEncoderError.invalidImage("\(samples.count) samples for \(width)x\(height)x\(componentCount)")
        }
        let sampleLimit = UInt16(truncatingIfNeeded: (1 << precision) - 1)
        if precision < 16, let maximum = samples.max(), maximum > sampleLimit {
            throw JPEGLosslessEncoderError.invalidImage("sample \(maximum) exceeds the \(precision)-bit range")
        }
        guard (1...7).contains(parameters.predictor) else {
            throw JPEGLosslessEncoderError.invalidParameters("predictor \(parameters.predictor) must be 1...7")
        }
        guard (0..<precision).contains(parameters.pointTransform) else {
            throw JPEGLosslessEncoderError.invalidParameters("point transform \(parameters.pointTransform) must be below the precision \(precision)")
        }
        guard parameters.restartIntervalRows >= 0 else {
            throw JPEGLosslessEncoderError.invalidParameters("restart interval rows must not be negative")
        }
        let restartInterval = parameters.restartIntervalRows * width
        guard restartInterval <= 65535 else {
            throw JPEGLosslessEncoderError.invalidParameters(
                "restart interval of \(parameters.restartIntervalRows) rows × \(width) MCUs exceeds the 16-bit DRI field")
        }

        // Plane-major, point-transformed samples.
        let shift = UInt16(parameters.pointTransform)
        var planes = [UInt16](repeating: 0, count: numPixels * componentCount)
        planes.withUnsafeMutableBufferPointer { target in
            samples.withUnsafeBufferPointer { source in
                for component in 0..<componentCount {
                    var sourceIndex = component
                    let planeBase = component * numPixels
                    for pixel in 0..<numPixels {
                        target[planeBase + pixel] = source[sourceIndex] >> shift
                        sourceIndex += componentCount
                    }
                }
            }
        }

        // Pass 1: differences in scan order (x outer, component inner) and category histograms per component.
        let transformedPrecision = precision - parameters.pointTransform
        let initialPredictor = 1 << max(0, transformedPrecision - 1)
        let mode = parameters.predictor
        let rowsPerInterval = parameters.restartIntervalRows
        var categories = [UInt8](repeating: 0, count: numPixels * componentCount)
        var magnitudes = [UInt16](repeating: 0, count: numPixels * componentCount)
        var histogram = [Int](repeating: 0, count: 257 * componentCount)
        planes.withUnsafeMutableBufferPointer { buffer in
            categories.withUnsafeMutableBufferPointer { categories in
                magnitudes.withUnsafeMutableBufferPointer { magnitudes in
                    histogram.withUnsafeMutableBufferPointer { histogram in
                        var scanIndex = 0
                        for y in 0..<height {
                            let firstLine = y == 0 || (rowsPerInterval > 0 && y % rowsPerInterval == 0)
                            let rowBase = y * width
                            for x in 0..<width {
                                for component in 0..<componentCount {
                                    let index = component * numPixels + rowBase + x
                                    let predictor = JPEGLosslessDecoder.predict(buffer: buffer, index: index, x: x, width: width,
                                                                                firstLine: firstLine, mode: mode, initialPredictor: initialPredictor)
                                    let difference = Int(Int16(truncatingIfNeeded: Int(buffer[index]) - predictor))
                                    let (category, bits) = Self.categorize(difference)
                                    categories[scanIndex] = UInt8(category)
                                    magnitudes[scanIndex] = UInt16(truncatingIfNeeded: bits)
                                    histogram[component * 257 + category] += 1
                                    scanIndex += 1
                                }
                            }
                        }
                    }
                }
            }
        }

        // Huffman tables: one per component, optimal length-limited (Annex K.2). Codes are flattened per
        // component × category (value and length; length 0 = no code).
        var tables: [(counts: [UInt8], values: [UInt8])] = []
        var codeValues = [UInt32](repeating: 0, count: 17 * componentCount)
        var codeLengths = [UInt8](repeating: 0, count: 17 * componentCount)
        for component in 0..<componentCount {
            let table = Self.optimalTable(histogram: Array(histogram[(component * 257)..<((component + 1) * 257)]))
            tables.append(table)
            let codes = JPEGLosslessHuffmanCodes.canonical(symbolCounts: table.counts)
            for (index, value) in table.values.enumerated() where Int(value) <= 16 {
                codeValues[component * 17 + Int(value)] = UInt32(codes[index].value)
                codeLengths[component * 17 + Int(value)] = UInt8(codes[index].length)
            }
        }

        // Pass 2: markers and entropy-coded segment.
        var output = Data(capacity: 64 + numPixels * componentCount)
        output.append(contentsOf: [0xFF, JPEGMarker.soi.rawValue])
        var sof: [UInt8] = [0xFF, JPEGMarker.sof3.rawValue]
        sof.append(contentsOf: Self.bigEndian16(8 + 3 * componentCount))
        sof.append(UInt8(precision))
        sof.append(contentsOf: Self.bigEndian16(height))
        sof.append(contentsOf: Self.bigEndian16(width))
        sof.append(UInt8(componentCount))
        for component in 0..<componentCount {
            sof.append(contentsOf: [UInt8(component + 1), 0x11, 0x00])
        }
        output.append(contentsOf: sof)
        var dht: [UInt8] = [0xFF, JPEGMarker.dht.rawValue]
        let dhtLength = 2 + tables.reduce(0) { $0 + 17 + $1.values.count }
        dht.append(contentsOf: Self.bigEndian16(dhtLength))
        for (component, table) in tables.enumerated() {
            dht.append(UInt8(component))
            dht.append(contentsOf: table.counts)
            dht.append(contentsOf: table.values)
        }
        output.append(contentsOf: dht)
        if restartInterval > 0 {
            output.append(contentsOf: [0xFF, JPEGMarker.dri.rawValue, 0x00, 0x04])
            output.append(contentsOf: Self.bigEndian16(restartInterval))
        }
        var sos: [UInt8] = [0xFF, JPEGMarker.sos.rawValue]
        sos.append(contentsOf: Self.bigEndian16(6 + 2 * componentCount))
        sos.append(UInt8(componentCount))
        for component in 0..<componentCount {
            sos.append(contentsOf: [UInt8(component + 1), UInt8(component << 4)])
        }
        sos.append(contentsOf: [UInt8(parameters.predictor), 0x00, UInt8(parameters.pointTransform)])
        output.append(contentsOf: sos)

        var writer = EntropyWriter(capacity: numPixels * componentCount * 2 + 64)
        var scanIndex = 0
        var restartCount = 0
        try categories.withUnsafeBufferPointer { categories in
            try magnitudes.withUnsafeBufferPointer { magnitudes in
                for y in 0..<height {
                    if rowsPerInterval > 0, y > 0, y % rowsPerInterval == 0 {
                        writer.emitRestartMarker(restartCount % 8)
                        restartCount += 1
                    }
                    for _ in 0..<width {
                        for component in 0..<componentCount {
                            let category = Int(categories[scanIndex])
                            let length = Int(codeLengths[component * 17 + category])
                            guard length > 0 else {
                                throw JPEGLosslessEncoderError.invalidImage("no Huffman code for category \(category)")
                            }
                            writer.write(Int(codeValues[component * 17 + category]), bits: length)
                            if category > 0, category < 16 {
                                writer.write(Int(magnitudes[scanIndex]), bits: category)
                            }
                            scanIndex += 1
                        }
                    }
                }
            }
        }
        writer.flush()
        output.append(contentsOf: writer.bytes)
        output.append(contentsOf: [0xFF, JPEGMarker.eoi.rawValue])
        return output
    }

    /// Category SSSS and the SSSS low-order bits of a difference (T.81 Table H.2; −32768 is category 16, no bits).
    @inline(__always)
    static func categorize(_ difference: Int) -> (category: Int, bits: Int) {
        if difference == 0 { return (0, 0) }
        if difference == -32768 { return (16, 0) }
        let magnitude = difference < 0 ? -difference : difference
        let category = Int.bitWidth - magnitude.leadingZeroBitCount
        let bits = difference >= 0 ? difference : difference + (1 << category) - 1
        return (category, bits)
    }

    /// Annex K.2 (Figures K.1–K.4): code lengths from the histogram, limited to 16 bits, reserved all-ones code excluded.
    static func optimalTable(histogram: [Int]) -> (counts: [UInt8], values: [UInt8]) {
        var freq = histogram
        if freq.count < 257 { freq.append(contentsOf: [Int](repeating: 0, count: 257 - freq.count)) }
        freq[256] = 1 // reserved symbol guarantees no code of all ones
        var codeSize = [Int](repeating: 0, count: 257)
        var others = [Int](repeating: -1, count: 257)
        while true {
            var v1 = -1
            var least = Int.max
            for symbol in 0...256 where freq[symbol] > 0 && freq[symbol] <= least {
                least = freq[symbol]
                v1 = symbol
            }
            var v2 = -1
            least = Int.max
            for symbol in 0...256 where freq[symbol] > 0 && freq[symbol] <= least && symbol != v1 {
                least = freq[symbol]
                v2 = symbol
            }
            guard v1 >= 0, v2 >= 0 else { break }
            freq[v1] += freq[v2]
            freq[v2] = 0
            codeSize[v1] += 1
            while others[v1] >= 0 {
                v1 = others[v1]
                codeSize[v1] += 1
            }
            others[v1] = v2
            codeSize[v2] += 1
            while others[v2] >= 0 {
                v2 = others[v2]
                codeSize[v2] += 1
            }
        }
        var bits = [Int](repeating: 0, count: 33)
        for symbol in 0...256 where codeSize[symbol] > 0 {
            bits[codeSize[symbol]] += 1
        }
        var length = 32
        while length > 16 {
            while bits[length] > 0 {
                var shorter = length - 2
                while bits[shorter] == 0 { shorter -= 1 }
                bits[length] -= 2
                bits[length - 1] += 1
                bits[shorter + 1] += 2
                bits[shorter] -= 1
            }
            length -= 1
        }
        while bits[length] == 0 { length -= 1 }
        bits[length] -= 1 // remove the reserved symbol
        let counts = (1...16).map { UInt8(bits[$0]) }
        var values: [UInt8] = []
        for size in 1...32 {
            for symbol in 0..<256 where codeSize[symbol] == size {
                values.append(UInt8(symbol))
            }
        }
        return (counts, values)
    }

    private static func bigEndian16(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// Bit packer with 0xFF byte stuffing and all-ones padding before markers.
    struct EntropyWriter {
        private(set) var bytes: [UInt8] = []
        private var accumulator: UInt64 = 0
        private var bitCount = 0

        init(capacity: Int) {
            bytes.reserveCapacity(capacity)
        }

        @inline(__always)
        mutating func write(_ value: Int, bits: Int) {
            accumulator = (accumulator << UInt64(bits)) | UInt64(value & ((1 << bits) - 1))
            bitCount += bits
            while bitCount >= 8 {
                let byte = UInt8(truncatingIfNeeded: accumulator >> UInt64(bitCount - 8))
                bytes.append(byte)
                if byte == 0xFF { bytes.append(0x00) }
                bitCount -= 8
            }
        }

        mutating func flush() {
            if bitCount > 0 {
                write((1 << (8 - bitCount)) - 1, bits: 8 - bitCount)
            }
            accumulator = 0
            bitCount = 0
        }

        mutating func emitRestartMarker(_ index: Int) {
            flush()
            bytes.append(0xFF)
            bytes.append(0xD0 + UInt8(index))
        }
    }
}
