import DicomCodecs
import DicomData
import Foundation

/// How a Segmentation's Pixel Data is written (Isis issue #2513).
public enum DicomSegmentationPixelEncoding: String, CaseIterable, Sendable {
    /// Native frames one after another, in Explicit VR Little Endian.
    case native
    /// Native frames in a dataset deflated as a whole (Deflated Explicit VR Little Endian): a reader inflates the
    /// whole dataset before it reaches a frame.
    case deflatedDataSet
    /// One RLE Lossless fragment per frame (PS3.5 Annex G). Annex G has no one-bit samples, so a BINARY
    /// segmentation stays native.
    case rleLossless
    /// One raw DEFLATE fragment per frame (Deflated Image Frame Compression, PS3.5 8.2.16).
    case deflatedFrames

    public var transferSyntax: DicomTransferSyntax {
        switch self {
        case .native: .explicitVRLittleEndian
        case .deflatedDataSet: .deflatedExplicitVRLittleEndian
        case .rleLossless: .rleLossless
        case .deflatedFrames: .deflatedImageFrameCompression
        }
    }

    /// The encoding a segmentation of `type` is written with: RLE has no one-bit samples and the frames of an
    /// unknown type have no known layout, so those stay native.
    public func applied(to type: DicomSegmentationType) -> DicomSegmentationPixelEncoding {
        switch (self, type) {
        case (.rleLossless, .binary), (.rleLossless, .unknown), (.deflatedFrames, .unknown): .native
        default: self
        }
    }

    var encapsulatesFrames: Bool {
        self == .rleLossless || self == .deflatedFrames
    }
}

extension DicomSegmentationBuilder {
    /// Encapsulated Pixel Data with one fragment per frame, the frames encoded concurrently one at a time; a Basic
    /// Offset Table, or an Extended Offset Table when the fragments pass 4 GiB.
    static func encapsulatedPixelDataElements(from segmentation: DicomSegmentation, bitsAllocated: Int,
                                              encoding: DicomSegmentationPixelEncoding) throws -> [DicomDataElement] {
        let frames = segmentation.frames
        let fragments = EncodedFragments(count: frames.count)
        DispatchQueue.concurrentPerform(iterations: frames.count) { index in
            fragments.set(index, Result {
                let native = pixelData(of: CollectionOfOne(frames[index]), in: segmentation,
                                       wideLabels: bitsAllocated == 16)
                switch encoding {
                case .rleLossless:
                    return try DicomRLECodec.encodeFrame(native, width: segmentation.columns, height: segmentation.rows,
                                                         samplesPerPixel: 1, bytesPerSample: bitsAllocated / 8)
                default:
                    return try DicomDeflatedFrameCodec.encodeFrame(native)
                }
            })
        }
        let encapsulation = try DicomTranscoder.encapsulate(fragments: try fragments.values())
        var elements = [DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(encapsulation.pixelData))]
        if let offsets = encapsulation.extendedOffsetTable, let lengths = encapsulation.extendedOffsetTableLengths {
            elements.append(DicomDataElement(tag: DicomTag.extendedOffsetTable.rawValue, vr: .OV, value: .bytes(offsets)))
            elements.append(DicomDataElement(tag: DicomTag.extendedOffsetTableLengths.rawValue, vr: .OV,
                                             value: .bytes(lengths)))
        }
        return elements
    }

    private final class EncodedFragments: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Result<Data, any Error>?]
        init(count: Int) { storage = Array(repeating: nil, count: count) }
        func set(_ index: Int, _ value: Result<Data, any Error>) { lock.withLock { storage[index] = value } }
        func values() throws -> [Data] {
            try lock.withLock { try storage.map { try ($0 ?? .failure(CancellationError())).get() } }
        }
    }
}

/// Lossless SEG frames decoded to stored little-endian bytes, without display transforms (Isis issue #2520).
struct DicomSegmentationEncapsulatedFrames {
    private let reader: DicomEncapsulatedPixelFrameReader
    private let descriptor: DicomCompressedFrameDescriptor
    private let transferSyntax: DicomTransferSyntax
    private let rows: Int
    private let columns: Int
    private let bitsAllocated: Int

    init(decoder: DCMDecoder, rows: Int, columns: Int, bitsAllocated: Int) throws {
        let uid = decoder.transferSyntaxUID
        guard let syntax = DicomTransferSyntax(uid: uid),
              [.rleLossless, .deflatedImageFrameCompression, .jpegLSLossless, .jpeg2000Lossless,
               .jpeg2000, .htj2kLossless, .htj2kLosslessRPCL].contains(syntax) else {
            throw DicomSegmentationDiagnostic(code: .unsupportedTransferSyntax, transferSyntaxUID: uid)
        }
        guard let encapsulation = decoder.makeEncapsulatedPixelDataDescriptorUnsafe() else {
            throw DicomSegmentationDiagnostic(code: .compressedFrameDecodeFailed, transferSyntaxUID: uid)
        }
        reader = try DicomEncapsulatedPixelFrameReader(descriptor: encapsulation, fileData: decoder.dicomData)
        transferSyntax = syntax
        self.rows = rows
        self.columns = columns
        self.bitsAllocated = bitsAllocated
        let bitsStored = decoder.intValue(for: DicomTag.bitsStored.rawValue) ?? bitsAllocated
        // SEG labels are stored codes even if display or signed-pixel attributes say otherwise (Isis issue #2520).
        descriptor = .init(transferSyntaxUID: uid, rows: rows, columns: columns, bitsAllocated: bitsAllocated,
                           bitsStored: bitsStored, highBit: bitsStored - 1, pixelRepresentation: 0,
                           samplesPerPixel: 1, photometricInterpretation: "MONOCHROME2", planarConfiguration: nil)
    }

    func frame(at index: Int) throws -> Data {
        do {
            return try decode(reader.frameData(at: index))
        } catch let diagnostic as DicomSegmentationDiagnostic {
            throw DicomSegmentationDiagnostic(code: diagnostic.code, frameIndex: index,
                                               transferSyntaxUID: transferSyntax.rawValue)
        } catch {
            throw DicomSegmentationDiagnostic(code: .compressedFrameDecodeFailed, frameIndex: index,
                                               transferSyntaxUID: transferSyntax.rawValue)
        }
    }

    private func decode(_ fragment: Data) throws -> Data {
        guard let byteCount = DicomDeflatedFrameCodec.frameByteCount(rows: rows, columns: columns, samplesPerPixel: 1,
                                                                    bitsAllocated: bitsAllocated) else {
            throw DicomSegmentationDiagnostic(code: .compressedFrameDecodeFailed)
        }
        if transferSyntax == .deflatedImageFrameCompression {
            return try DicomDeflatedFrameCodec.decodeFrame(fragment, expectedByteCount: byteCount)
        }
        if transferSyntax == .rleLossless {
            if bitsAllocated == 1 { return try binaryRLE(fragment) }
            guard bitsAllocated == 8 || bitsAllocated == 16 else {
                throw DicomSegmentationDiagnostic(code: .compressedFrameDecodeFailed)
            }
            let segments = try DicomRLECodec.decodeSegments(fragment, width: columns, height: rows,
                                                           limits: .init(maximumDecodedBytes: byteCount), allowNonzeroPadding: true)
            guard segments.count == bitsAllocated / 8 else {
                throw DicomSegmentationDiagnostic(code: .compressedFrameDecodeFailed)
            }
            if bitsAllocated == 8 { return Data(segments[0]) }
            var bytes = Data(count: byteCount)
            for pixel in 0..<(rows * columns) {
                bytes[2 * pixel] = segments[1][pixel]
                bytes[2 * pixel + 1] = segments[0][pixel]
            }
            return bytes
        }
        guard bitsAllocated == 8 || bitsAllocated == 16 else {
            throw DicomSegmentationDiagnostic(code: .compressedFrameDecodeFailed)
        }
        let bytes: Data
        if transferSyntax == .jpegLSLossless {
            bytes = try DicomJLSwiftBackend.decodeSynchronously(fragment, descriptor: descriptor).buffer.data
        } else {
            let inspection = try DicomJ2KCodestreamInspector.inspect(fragment)
            guard inspection.isLosslessCoding else {
                throw DicomSegmentationDiagnostic(code: .lossySegmentationFrame)
            }
            guard DicomHTJ2KProfile.violation(of: transferSyntax.rawValue, in: fragment) == nil,
                  inspection.width == columns, inspection.height == rows, inspection.components.count == 1,
                  inspection.components[0].precision == descriptor.bitsStored else {
                throw DicomSegmentationDiagnostic(code: .compressedFrameDecodeFailed)
            }
            // This codec returns stored bytes, before the image reader applies presentation/sign handling.
            let decoded = try DicomJPEG2000Codec.decode(fragment)
            guard decoded.width == columns, decoded.height == rows, decoded.componentCount == 1 else {
                throw DicomSegmentationDiagnostic(code: .compressedFrameDecodeFailed)
            }
            bytes = decoded.bytes
        }
        guard bytes.count == byteCount else {
            throw DicomSegmentationDiagnostic(code: .compressedFrameDecodeFailed)
        }
        return bytes
    }

    private func binaryRLE(_ fragment: Data) throws -> Data {
        let pixels = rows * columns
        let packedCount = (pixels + 7) / 8
        var candidates = Set<Data>()
        // Annex G does not define one-bit segments. Only accept unambiguous observed layouts (Isis issue #2520).
        for count in Set([packedCount, packedCount + packedCount % 2, pixels]) {
            guard let segments = try? DicomRLECodec.decodeSegments(fragment, width: count, height: 1,
                                                                   limits: .init(maximumDecodedBytes: count), allowNonzeroPadding: true),
                  segments.count == 1 else { continue }
            let values = segments[0]
            if count == pixels, values.allSatisfy({ $0 <= 1 }) {
                var packed = Data(count: packedCount)
                for pixel in 0..<pixels { packed[pixel / 8] |= values[pixel] << (pixel % 8) }
                candidates.insert(packed)
            }
            if count == packedCount || (count == packedCount + 1 && packedCount % 2 == 1 && values.last == 0) {
                var packed = Data(values.prefix(packedCount))
                if pixels % 8 != 0 { packed[packedCount - 1] &= UInt8((1 << (pixels % 8)) - 1) }
                candidates.insert(packed)
            }
        }
        guard candidates.count == 1, let bytes = candidates.first else {
            throw DicomSegmentationDiagnostic(code: .invalidBinaryRLE)
        }
        return bytes
    }
}
