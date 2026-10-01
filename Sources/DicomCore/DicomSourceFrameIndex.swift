import Foundation

/// Revision-bound frame addresses, independent of materialized pixels. Native indexing
/// stores one stride, even for billions of frames; encapsulated indexing has an explicit budget.
public struct DicomSourceFrameIndex: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case invalidLayout
        case unsupportedLayout(String)
        case invalidOffsetTable
        case invalidFragmentation(String)
        case ambiguousFrameBoundaries
        case truncatedItems
        case indexLimit
        case boundaryScanLimit
        case frameLimit
        case invalidPadding
    }

    public let metadata: DicomSourceMetadata
    public let frameCount: Int
    /// Single-frame storage shape; original frame count remains `frameCount`.
    public let nativeLayout: DicomPixelDataDescriptor?
    public let encapsulatedLayout: DicomEncapsulatedPixelDataDescriptor?

    public static func build(from source: DicomByteSource, metadata: DicomSourceMetadata,
                             maximumIndexBytes: Int = 32 * 1024 * 1024,
                             maximumBoundaryScanBytes: Int = 64 * 1024 * 1024) async throws -> Self {
        guard source.revision == metadata.sourceRevision else { throw DicomByteSource.Failure.changed }
        try await source.checkOpen()
        guard let pixels = metadata.pixelDataRange else { throw DicomDecodedFrameReader.ReadError.noPixelData }
        let dataSet = metadata.dataSet
        let frames = dataSet.int(for: .numberOfFrames) ?? (dataSet[.numberOfFrames] == nil ? 1 : 0)
        guard frames > 0 else { throw Failure.invalidLayout }
        if metadata.pixelDataIsEncapsulated {
            guard metadata.pixelDataTag == DicomTag.pixelData.rawValue else { throw Failure.invalidLayout }
            let descriptor = try await DicomEncapsulatedPixelDataParser().parse(
                source: source, pixelDataRange: pixels, numberOfFrames: frames, transferSyntax: metadata.transferSyntax,
                extendedOffsetTableData: dataSet[.extendedOffsetTable]?.bytesValue,
                extendedOffsetTableLengthsData: dataSet[.extendedOffsetTableLengths]?.bytesValue,
                maximumIndexBytes: maximumIndexBytes, maximumBoundaryScanBytes: maximumBoundaryScanBytes
            )
            return Self(metadata: metadata, frameCount: frames, nativeLayout: nil, encapsulatedLayout: descriptor)
        }
        guard [.implicitVRLittleEndian, .explicitVRLittleEndian, .explicitVRBigEndian].contains(metadata.transferSyntax) else {
            throw Failure.unsupportedLayout(metadata.transferSyntax.rawValue)
        }
        let allocated = dataSet.int(for: .bitsAllocated) ?? 0
        guard [1, 8, 16, 32, 64].contains(allocated) else { throw Failure.invalidLayout }
        let floatWidth: Int? = metadata.pixelDataTag == 0x7FE00008 ? 32 : (metadata.pixelDataTag == 0x7FE00009 ? 64 : nil)
        let stored = dataSet.int(for: .bitsStored) ?? allocated
        let highBit = dataSet.int(for: .highBit) ?? allocated - 1
        guard floatWidth == nil || floatWidth == allocated,
              stored > 0, stored <= allocated, highBit >= stored - 1, highBit < allocated,
              let descriptor = DicomPixelDataDescriptor(
                rows: dataSet.int(for: .rows) ?? 0, columns: dataSet.int(for: .columns) ?? 0,
                numberOfFrames: 1, bitsAllocated: allocated, bitsStored: stored, highBit: highBit,
                pixelRepresentation: dataSet.int(for: .pixelRepresentation) ?? 0,
                samplesPerPixel: dataSet.int(for: .samplesPerPixel) ?? 1,
                planarConfiguration: dataSet.int(for: .planarConfiguration),
                photometricInterpretation: dataSet.string(for: .photometricInterpretation) ?? "MONOCHROME2",
                pixelDataOffset: 0,
                eightBitSamplesAreWordSwapped: metadata.transferSyntax == .explicitVRBigEndian
                    && allocated == 8 && metadata.pixelDataVR == .OW) else { throw Failure.invalidLayout }
        let totalBits = descriptor.bitsPerFrame.multipliedReportingOverflow(by: frames)
        guard !totalBits.overflow else { throw Failure.invalidLayout }
        let totalBytes = totalBits.partialValue / 8 + (totalBits.partialValue % 8 == 0 ? 0 : 1)
        guard totalBytes <= pixels.count, pixels.count - totalBytes <= 1 else { throw Failure.invalidLayout }
        return Self(metadata: metadata, frameCount: frames, nativeLayout: descriptor, encapsulatedLayout: nil)
    }

    /// Exact source ranges for one frame. Native packed-bit ranges may overlap a byte;
    /// `packedBitOffset` identifies the first meaningful bit within the returned bytes.
    public func ranges(forFrame index: Int) throws -> [Range<Int>] {
        guard index >= 0, index < frameCount else {
            throw DicomDecodedFrameReader.ReadError.frameIndexOutOfRange(index: index, frameCount: frameCount)
        }
        if let layout = nativeLayout, let pixels = metadata.pixelDataRange {
            let firstBit = index * layout.bitsPerFrame
            let lastBit = firstBit + layout.bitsPerFrame
            var first = firstBit / 8
            var end = lastBit / 8 + (lastBit % 8 == 0 ? 0 : 1)
            if layout.eightBitSamplesAreWordSwapped {
                // The samples of one frame live in the 16-bit words covering it, which may start one byte
                // before the frame and end one byte after it when the frame length is odd. The range covers
                // those whole words; `wordSwapLeadingBytes(forFrame:)` says where the frame begins in them.
                first -= first % 2
                end += end % 2
            }
            return [(pixels.lowerBound + first)..<(pixels.lowerBound + min(end, pixels.count))]
        }
        guard let layout = encapsulatedLayout else { throw Failure.invalidLayout }
        return layout.frameFragmentIndexes[index].map { layout.fragments[$0].valueRange }
    }

    /// Bytes of the returned frame range that precede the frame's first sample: 1 when the word covering the
    /// frame start also holds the previous frame's last sample, 0 otherwise (and always 0 unless the samples
    /// are word-swapped). Callers restoring the sample order drop this many bytes after unswapping.
    public func wordSwapLeadingBytes(forFrame index: Int) throws -> Int {
        _ = try ranges(forFrame: index)
        guard let layout = nativeLayout, layout.eightBitSamplesAreWordSwapped else { return 0 }
        return (index * layout.bitsPerFrame / 8) % 2
    }

    public func packedBitOffset(forFrame index: Int) throws -> Int {
        _ = try ranges(forFrame: index)
        return nativeLayout.map { (index * $0.bitsPerFrame) % 8 } ?? 0
    }

    /// Materializes just one raw frame. EOT lengths exclude the optional final pad byte.
    public func frameData(at index: Int, from source: DicomByteSource,
                          maximumFrameBytes: Int = 64 * 1024 * 1024) async throws -> Data {
        guard source.revision == metadata.sourceRevision else { throw DicomByteSource.Failure.changed }
        let ranges = try ranges(forFrame: index)
        var length = 0
        for range in ranges {
            guard range.count <= maximumFrameBytes - length else { throw Failure.frameLimit }
            length += range.count
        }
        var result = Data()
        result.reserveCapacity(length)
        for range in ranges {
            try Task.checkCancellation()
            let lease = try await source.read(range)
            result.append(try lease.retainedData())
        }
        await source.recordCompatibilityCopy(length)
        if let exact = encapsulatedLayout?.extendedOffsetTable?.lengths[index], exact < UInt64(result.count) {
            guard result.last == 0 else { throw Failure.invalidPadding }
            result.removeLast()
        }
        try await source.checkOpen()
        return result
    }
}
