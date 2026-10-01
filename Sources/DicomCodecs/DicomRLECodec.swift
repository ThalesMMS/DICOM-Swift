import Foundation

/// Bounded DICOM PS3.5 Annex G header and PackBits processing, shared by inspection and decoding.
public enum DicomRLECodec {
    public enum Failure: Error, Equatable, Sendable {
        case invalidDimensions, limitExceeded, invalidHeader, invalidRun, decodedLengthMismatch, trailingData
    }

    public struct Limits: Sendable {
        public let maximumEncodedBytes: Int
        public let maximumDecodedBytes: Int
        public init(maximumEncodedBytes: Int = 64 * 1024 * 1024, maximumDecodedBytes: Int = 512 * 1024 * 1024) {
            self.maximumEncodedBytes = max(0, maximumEncodedBytes)
            self.maximumDecodedBytes = max(0, maximumDecodedBytes)
        }
    }

    public struct Inspection: Sendable, Equatable {
        public let segmentCount: Int
        public let runsCrossRowBoundaries: Bool
        public let literalTriples: Bool
        public let containsNonBinarySamples: Bool
        /// PS3.5 G.3.1 requires each RLE segment to be even; an odd segment stays decodable.
        public let oddSegmentLength: Bool
    }

    /// Validates every encoded byte without allocating decoded pixel planes.
    public static func inspect(_ data: Data, width: Int, height: Int, limits: Limits = .init()) throws -> Inspection {
        try process(data, width: width, height: height, limits: limits, materialize: false).inspection
    }

    /// Decoder acceptance remains distinct from encoder conformance (for example a run crossing a row).
    /// `allowShortSegments` accepts a segment that ends less than one row short, its last literal run possibly cut
    /// off, and leaves the missing samples zero, as the GDCM reader does (Isis issue #2855: an ultrasound encoder
    /// drops the last byte).
    public static func decodeSegments(_ data: Data, width: Int, height: Int, limits: Limits = .init(),
                                      allowNonzeroPadding: Bool = false,
                                      allowShortSegments: Bool = false) throws -> [[UInt8]] {
        try process(data, width: width, height: height, limits: limits, materialize: true,
                    allowNonzeroPadding: allowNonzeroPadding, allowShortSegments: allowShortSegments).segments
    }

    private static func process(_ data: Data, width: Int, height: Int, limits: Limits,
                                materialize: Bool, allowNonzeroPadding: Bool = false,
                                allowShortSegments: Bool = false) throws -> (inspection: Inspection, segments: [[UInt8]]) {
        let pixels = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !pixels.overflow else { throw Failure.invalidDimensions }
        guard data.count <= limits.maximumEncodedBytes else { throw Failure.limitExceeded }
        guard data.count >= 64 else { throw Failure.invalidHeader }
        return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            func word(_ offset: Int) -> Int {
                Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
            }
            let count = word(0)
            guard (1...15).contains(count), word(4) == 64 else { throw Failure.invalidHeader }
            for index in (count + 1)..<16 where word(index * 4) != 0 { throw Failure.invalidHeader }
            let total = pixels.partialValue.multipliedReportingOverflow(by: count)
            guard !total.overflow, total.partialValue <= limits.maximumDecodedBytes else { throw Failure.limitExceeded }
            let offsets = (1...count).map { word($0 * 4) } + [data.count]
            var planes: [[UInt8]] = []
            var crossRow = false, triples = false, nonBinary = false, oddSegment = false
            for segment in 0..<count {
                let start = offsets[segment], end = offsets[segment + 1]
                guard start >= 64, end <= data.count, start < end else { throw Failure.invalidHeader }
                oddSegment = oddSegment || !(end - start).isMultiple(of: 2)
                var cursor = start, produced = 0
                // Runs are copied or filled in bulk into the whole plane, which also keeps unoptimised builds fast.
                var plane = materialize ? [UInt8](repeating: 0, count: pixels.partialValue) : []
                var previousLiteral: UInt8?, equalLiterals = 0
                try plane.withUnsafeMutableBufferPointer { output in
                    while cursor < end {
                        // dcmjs SEG pads an odd byte segment with the header's segment count (1), not zero (Isis issue #2520).
                        if produced == pixels.partialValue, end - cursor == 1,
                           bytes[cursor] == 0 || (allowNonzeroPadding && (end - start).isMultiple(of: 2)) {
                            cursor += 1
                            break
                        }
                        let control = Int(Int8(bitPattern: bytes[cursor]))
                        cursor += 1
                        if control == -128 { continue }
                        guard produced < pixels.partialValue else { throw Failure.trailingData }
                        var length = control >= 0 ? control + 1 : 1 - control
                        guard length <= pixels.partialValue - produced else { throw Failure.decodedLengthMismatch }
                        crossRow = crossRow || length > width - produced % width
                        if control >= 0 {
                            if length > end - cursor {
                                // A literal run cut off by the end of the segment keeps the bytes it has.
                                guard allowShortSegments else { throw Failure.invalidRun }
                                length = end - cursor
                            }
                            if materialize, let target = output.baseAddress, let source = bytes.baseAddress {
                                UnsafeMutableRawPointer(target + produced).copyMemory(from: source + cursor, byteCount: length)
                            } else {
                                for index in cursor..<(cursor + length) {
                                    let byte = bytes[index]
                                    if (produced + index - cursor).isMultiple(of: width) { previousLiteral = nil; equalLiterals = 0 }
                                    equalLiterals = previousLiteral == byte ? equalLiterals + 1 : 1
                                    previousLiteral = byte
                                    triples = triples || equalLiterals >= 3
                                    nonBinary = nonBinary || byte > 1
                                }
                            }
                            cursor += length
                        } else {
                            guard cursor < end else { throw Failure.invalidRun }
                            let byte = bytes[cursor]
                            cursor += 1
                            nonBinary = nonBinary || byte > 1
                            if materialize, let target = output.baseAddress {
                                (target + produced).update(repeating: byte, count: length)
                            }
                            previousLiteral = nil; equalLiterals = 0
                        }
                        produced += length
                    }
                }
                guard produced == pixels.partialValue
                    || (allowShortSegments && pixels.partialValue - produced < width) else {
                    throw Failure.decodedLengthMismatch
                }
                if materialize { planes.append(plane) }
            }
            return (.init(segmentCount: count, runsCrossRowBoundaries: crossRow, literalTriples: triples,
                          containsNonBinarySamples: nonBinary, oddSegmentLength: oddSegment), planes)
        }
    }

    // MARK: - Encoding (PS3.5 Annex G)

    public enum EncodeFailure: Error, Equatable, Sendable {
        case invalidDimensions
        case tooManySegments(Int)
        case sampleLayoutMismatch(expected: Int, actual: Int)
    }

    /// Encodes one frame of little-endian interleaved stored samples: one byte segment per (sample, byte),
    /// most significant byte first, PackBits runs that never cross a row, every segment padded to an even
    /// length, and the 64-byte header of segment count and offsets.
    public static func encodeFrame(_ stored: Data, width: Int, height: Int, samplesPerPixel: Int, bytesPerSample: Int) throws -> Data {
        let pixels = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !pixels.overflow, samplesPerPixel > 0, bytesPerSample > 0 else { throw EncodeFailure.invalidDimensions }
        let segmentCount = samplesPerPixel * bytesPerSample
        guard segmentCount <= 15 else { throw EncodeFailure.tooManySegments(segmentCount) }
        let expected = pixels.partialValue * segmentCount
        guard stored.count == expected else { throw EncodeFailure.sampleLayoutMismatch(expected: expected, actual: stored.count) }
        var segments: [[UInt8]] = []
        segments.reserveCapacity(segmentCount)
        let pixelStride = samplesPerPixel * bytesPerSample
        stored.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let bytes = bytes.bindMemory(to: UInt8.self)
            // One byte per pixel is already the only plane.
            guard segmentCount > 1 else {
                segments.append(packBits(bytes, rowLength: width))
                return
            }
            var plane = [UInt8](repeating: 0, count: pixels.partialValue)
            for sample in 0..<samplesPerPixel {
                for byte in stride(from: bytesPerSample - 1, through: 0, by: -1) {
                    let base = sample * bytesPerSample + byte
                    plane.withUnsafeMutableBufferPointer { plane in
                        for pixel in 0..<plane.count { plane[pixel] = bytes[pixel * pixelStride + base] }
                    }
                    segments.append(plane.withUnsafeBufferPointer { packBits($0, rowLength: width) })
                }
            }
        }
        return encodeSegments(segments)
    }

    /// Assembles already packed segments behind the Annex G header (offsets relative to the frame start).
    public static func encodeSegments(_ segments: [[UInt8]]) -> Data {
        var header = [UInt8](repeating: 0, count: 64)
        func put(_ value: UInt32, at offset: Int) {
            header[offset] = UInt8(value & 0xFF); header[offset + 1] = UInt8(value >> 8 & 0xFF)
            header[offset + 2] = UInt8(value >> 16 & 0xFF); header[offset + 3] = UInt8(value >> 24 & 0xFF)
        }
        put(UInt32(segments.count), at: 0)
        var body: [UInt8] = []
        var running = 64
        for (index, segment) in segments.enumerated() {
            put(UInt32(running), at: (index + 1) * 4)
            body.append(contentsOf: segment)
            running += segment.count
        }
        return Data(header + body)
    }

    /// PackBits for one plane, restarted at every row so no run crosses a row boundary; padded to an even length.
    static func packBits(_ plane: UnsafeBufferPointer<UInt8>, rowLength: Int) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(plane.count / 2 + 16)
        let raw = UnsafeRawBufferPointer(plane)
        var rowStart = 0
        while rowStart < plane.count {
            let rowEnd = min(rowStart + rowLength, plane.count)
            var cursor = rowStart
            while cursor < rowEnd {
                // Replicate run of the byte at cursor, compared eight bytes at a time while they all match.
                let limit = min(rowEnd, cursor + 128)
                let repeated = UInt64(plane[cursor]) &* 0x0101_0101_0101_0101
                var runEnd = cursor + 1
                while runEnd + 8 <= limit, raw.loadUnaligned(fromByteOffset: runEnd, as: UInt64.self) == repeated { runEnd += 8 }
                while runEnd < limit, plane[runEnd] == plane[cursor] { runEnd += 1 }
                if runEnd - cursor >= 2 {
                    output.append(UInt8(bitPattern: Int8(1 - (runEnd - cursor))))
                    output.append(plane[cursor])
                    cursor = runEnd
                    continue
                }
                // Literal run until a replicate run of at least three bytes starts (or the row ends).
                var literalEnd = cursor + 1
                while literalEnd < rowEnd, literalEnd - cursor < 128 {
                    if literalEnd + 2 < rowEnd, plane[literalEnd] == plane[literalEnd + 1], plane[literalEnd] == plane[literalEnd + 2] { break }
                    literalEnd += 1
                }
                output.append(UInt8(literalEnd - cursor - 1))
                output.append(contentsOf: UnsafeBufferPointer(rebasing: plane[cursor..<literalEnd]))
                cursor = literalEnd
            }
            rowStart = rowEnd
        }
        if !output.count.isMultiple(of: 2) { output.append(0) }
        return output
    }
}
