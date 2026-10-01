import Foundation

/// Native uncompressed Pixel Data layout for frame-addressable access.
public struct DicomPixelDataDescriptor: Equatable, Sendable {
    /// DICOM Rows (0028,0010).
    public let rows: Int
    /// DICOM Columns (0028,0011).
    public let columns: Int
    /// Number of frames, defaulting to one when Number of Frames is absent.
    public let numberOfFrames: Int
    /// Bits Allocated (0028,0100).
    public let bitsAllocated: Int
    /// Bits Stored (0028,0101).
    public let bitsStored: Int
    /// High Bit (0028,0102).
    public let highBit: Int
    /// Pixel Representation (0028,0103), where 1 means signed samples.
    public let pixelRepresentation: Int
    /// Samples per Pixel (0028,0002).
    public let samplesPerPixel: Int
    /// Planar Configuration (0028,0006), when present.
    public let planarConfiguration: Int?
    /// Photometric Interpretation (0028,0004).
    public let photometricInterpretation: String
    /// Absolute byte offset where native Pixel Data begins in the loaded file.
    public let pixelDataOffset: Int
    /// True when the 8-bit samples are stored as byte-swapped 16-bit words (OW Pixel Data under
    /// Explicit VR Big Endian, PS3.5 §7.6.1.1.1). `nativeFrameData(in:frame:)` undoes the swap.
    public let eightBitSamplesAreWordSwapped: Bool
    /// Whole bytes used by each stored sample.
    public let bytesPerSample: Int
    /// Byte count needed for one frame when its first bit is byte-aligned.
    public let bytesPerFrame: Int
    /// Byte count for all complete frames.
    public let totalPixelBytes: Int
    /// Absolute byte containing the first bit of each frame in the loaded file.
    public let frameOffsets: [Int]
    /// Bit length used to advance between frames in native Pixel Data.
    public let bitsPerFrame: Int
    /// Absolute bit offset of each frame in the loaded file.
    public let frameBitOffsets: [Int]

    public init?(rows: Int,
                 columns: Int,
                 numberOfFrames: Int,
                 bitsAllocated: Int,
                 bitsStored: Int,
                 highBit: Int,
                 pixelRepresentation: Int,
                 samplesPerPixel: Int,
                 planarConfiguration: Int?,
                 photometricInterpretation: String,
                 pixelDataOffset: Int,
                 eightBitSamplesAreWordSwapped: Bool = false) {
        guard rows > 0,
              columns > 0,
              numberOfFrames > 0,
              bitsAllocated > 0,
              bitsStored > 0,
              highBit >= 0,
              samplesPerPixel > 0,
              pixelDataOffset >= 0 else {
            return nil
        }

        let bytesPerSample = bitsAllocated / 8 + (bitsAllocated % 8 == 0 ? 0 : 1)
        let pixelsPerFrame = rows.multipliedReportingOverflow(by: columns)
        guard !pixelsPerFrame.overflow else { return nil }

        let samplesPerFrame = pixelsPerFrame.partialValue.multipliedReportingOverflow(by: samplesPerPixel)
        guard !samplesPerFrame.overflow else { return nil }
        let sampleBitsPerFrame = samplesPerFrame.partialValue.multipliedReportingOverflow(by: bitsAllocated)
        guard !sampleBitsPerFrame.overflow else { return nil }

        let bytesPerFrameValue: Int
        if bitsAllocated == 1 {
            let packedBytes = sampleBitsPerFrame.partialValue.addingReportingOverflow(7)
            guard !packedBytes.overflow else { return nil }
            bytesPerFrameValue = packedBytes.partialValue / 8
        } else if photometricInterpretation
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() == "YBR_FULL_422",
           samplesPerPixel == 3 {
            let pairsPerRow = columns / 2 + columns % 2
            let bytesPerPair = 4.multipliedReportingOverflow(by: bytesPerSample)
            guard !bytesPerPair.overflow else { return nil }
            let bytesPerRow = pairsPerRow.multipliedReportingOverflow(by: bytesPerPair.partialValue)
            guard !bytesPerRow.overflow else { return nil }
            let bytesPerFrame = rows.multipliedReportingOverflow(by: bytesPerRow.partialValue)
            guard !bytesPerFrame.overflow else { return nil }
            bytesPerFrameValue = bytesPerFrame.partialValue
        } else {
            let bytesPerFrame = samplesPerFrame.partialValue.multipliedReportingOverflow(by: bytesPerSample)
            guard !bytesPerFrame.overflow else { return nil }
            bytesPerFrameValue = bytesPerFrame.partialValue
        }

        let bitsPerFrameValue: Int
        if bitsAllocated == 1 {
            bitsPerFrameValue = sampleBitsPerFrame.partialValue
        } else {
            let storageBits = bytesPerFrameValue.multipliedReportingOverflow(by: 8)
            guard !storageBits.overflow else { return nil }
            bitsPerFrameValue = storageBits.partialValue
        }
        let totalPixelBits = bitsPerFrameValue.multipliedReportingOverflow(by: numberOfFrames)
        guard !totalPixelBits.overflow else { return nil }
        let totalPixelBytes: Int
        if bitsAllocated == 1 {
            let paddedTotalPixelBits = totalPixelBits.partialValue.addingReportingOverflow(7)
            guard !paddedTotalPixelBits.overflow else { return nil }
            totalPixelBytes = paddedTotalPixelBits.partialValue / 8
        } else {
            let storageBytes = bytesPerFrameValue.multipliedReportingOverflow(by: numberOfFrames)
            guard !storageBytes.overflow else { return nil }
            totalPixelBytes = storageBytes.partialValue
        }

        let pixelDataBitOffset = pixelDataOffset.multipliedReportingOverflow(by: 8)
        guard !pixelDataBitOffset.overflow else { return nil }
        let pixelDataBitEnd = pixelDataBitOffset.partialValue.addingReportingOverflow(totalPixelBits.partialValue)
        guard !pixelDataBitEnd.overflow else { return nil }

        var frameOffsets: [Int] = []
        var frameBitOffsets: [Int] = []
        frameOffsets.reserveCapacity(numberOfFrames)
        frameBitOffsets.reserveCapacity(numberOfFrames)
        for frameIndex in 0..<numberOfFrames {
            let bitOffsetDelta = bitsPerFrameValue.multipliedReportingOverflow(by: frameIndex)
            guard !bitOffsetDelta.overflow else { return nil }
            let frameBitOffset = pixelDataBitOffset.partialValue.addingReportingOverflow(bitOffsetDelta.partialValue)
            guard !frameBitOffset.overflow else { return nil }
            frameBitOffsets.append(frameBitOffset.partialValue)
            frameOffsets.append(frameBitOffset.partialValue / 8)
        }

        self.rows = rows
        self.columns = columns
        self.numberOfFrames = numberOfFrames
        self.bitsAllocated = bitsAllocated
        self.bitsStored = bitsStored
        self.highBit = highBit
        self.pixelRepresentation = pixelRepresentation
        self.samplesPerPixel = samplesPerPixel
        self.planarConfiguration = planarConfiguration
        self.photometricInterpretation = photometricInterpretation
        self.pixelDataOffset = pixelDataOffset
        self.eightBitSamplesAreWordSwapped = eightBitSamplesAreWordSwapped && bitsAllocated == 8
        self.bytesPerSample = bytesPerSample
        self.bytesPerFrame = bytesPerFrameValue
        self.totalPixelBytes = totalPixelBytes
        self.frameOffsets = frameOffsets
        self.bitsPerFrame = bitsPerFrameValue
        self.frameBitOffsets = frameBitOffsets
    }

    public var isSigned: Bool {
        pixelRepresentation == 1
    }

    /// The bytes of one native frame in raster order. Equivalent to `data[byteRange(forFrame:)]` except for
    /// word-swapped 8-bit samples, where each 16-bit word (counted from the start of the Pixel Data value,
    /// so an odd frame length keeps the pairing of the next frame) is swapped back; a trailing byte whose
    /// partner lies beyond the data (missing pad byte) reads as zero.
    public func nativeFrameData(in data: Data, frame index: Int) -> Data? {
        guard let range = byteRange(forFrame: index), range.lowerBound >= data.startIndex,
              range.upperBound <= data.endIndex else { return nil }
        guard eightBitSamplesAreWordSwapped else { return data.subdata(in: range) }
        let base = data.startIndex + pixelDataOffset
        var output = Data(count: range.count)
        output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                for (slot, position) in range.enumerated() {
                    let partner = base + ((position - base) ^ 1)
                    destination[slot] = partner < data.endIndex ? source[partner - data.startIndex] : 0
                }
            }
        }
        return output
    }

    public var isMultiFrame: Bool {
        numberOfFrames > 1
    }

    /// Returns the absolute byte range for a zero-based frame index.
    public func byteRange(forFrame index: Int) -> Range<Int>? {
        guard let bitRange = bitRange(forFrame: index) else { return nil }
        let paddedUpperBound = bitRange.upperBound.addingReportingOverflow(7)
        guard !paddedUpperBound.overflow else { return nil }
        return bitRange.lowerBound / 8..<paddedUpperBound.partialValue / 8
    }

    /// Returns the absolute bit range for a zero-based frame index.
    public func bitRange(forFrame index: Int) -> Range<Int>? {
        guard index >= 0, index < numberOfFrames else { return nil }
        let start = frameBitOffsets[index]
        let end = start.addingReportingOverflow(bitsPerFrame)
        guard !end.overflow else { return nil }
        return start..<end.partialValue
    }

    /// Returns the contiguous absolute byte range for a zero-based frame range.
    public func byteRange(forFrames range: Range<Int>) -> Range<Int>? {
        guard range.lowerBound >= 0,
              range.lowerBound < range.upperBound,
              range.upperBound <= numberOfFrames,
              let firstFrameRange = byteRange(forFrame: range.lowerBound),
              let lastFrameRange = byteRange(forFrame: range.upperBound - 1) else {
            return nil
        }
        return firstFrameRange.lowerBound..<lastFrameRange.upperBound
    }
}

/// Raw native bytes for one uncompressed Pixel Data frame.
public struct DicomPixelFrame: Equatable, Sendable {
    /// Zero-based frame index.
    public let index: Int
    /// Absolute byte range copied from the source file.
    public let byteRange: Range<Int>
    /// Raw native frame bytes.
    public let data: Data
    /// Descriptor used to derive the frame layout.
    public let descriptor: DicomPixelDataDescriptor

    public init(index: Int,
                byteRange: Range<Int>,
                data: Data,
                descriptor: DicomPixelDataDescriptor) {
        self.index = index
        self.byteRange = byteRange
        self.data = data
        self.descriptor = descriptor
    }
}
