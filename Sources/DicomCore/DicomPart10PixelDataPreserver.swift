import Foundation

/// Extracts the exact Pixel Data value carried by a decoder.
/// Rebuilds the full data set of a decoded Part 10 file, Pixel Data bytes preserved as read.
public enum DicomPart10PixelDataPreserver {
    public static func dataSet(from decoder: DCMDecoder) throws -> DicomDataSet {
        var source = decoder.dataSet
        guard source.contains(.pixelData) else {
            return source
        }

        if decoder.compressedImage {
            guard let encapsulated = rawEncapsulatedPixelDataRegion(from: decoder) else {
                throw DicomPart10RewriteError.pixelDataUnavailable
            }
            source.set(DicomDataElement(
                tag: DicomTag.pixelData.rawValue,
                vr: .OB,
                value: .bytes(encapsulated)
            ))
            return source
        }

        guard let descriptor = decoder.pixelDataDescriptor else {
            throw DicomPart10RewriteError.pixelDataUnavailable
        }
        let fileData = decoder.dicomDataSnapshot()
        let start = descriptor.pixelDataOffset
        let end = start + descriptor.totalPixelBytes
        guard start >= 0, end >= start, end <= fileData.count else {
            throw DicomPart10RewriteError.pixelDataUnavailable
        }
        source.set(DicomDataElement(
            tag: DicomTag.pixelData.rawValue,
            vr: descriptor.bitsAllocated > 8 ? .OW : .OB,
            value: .bytes(Data(fileData[start..<end]))
        ))
        return source
    }

    /// Includes the Basic Offset Table, fragments, and sequence delimiter.
    public static func rawEncapsulatedPixelDataRegion(from decoder: DCMDecoder) -> Data? {
        guard let descriptor = decoder.encapsulatedPixelDataDescriptor else {
            return nil
        }
        let fileData = decoder.dicomDataSnapshot()
        let start = decoder.offset
        guard start >= 0, start < fileData.count else { return nil }

        let delimiterOffset = descriptor.fragments.map(\.itemRange.upperBound).max()
            ?? descriptor.basicOffsetTable.byteRange.upperBound
        guard delimiterOffset + 8 <= fileData.count,
              fileData[delimiterOffset] == 0xFE, fileData[delimiterOffset + 1] == 0xFF,
              fileData[delimiterOffset + 2] == 0xDD, fileData[delimiterOffset + 3] == 0xE0,
              fileData[(delimiterOffset + 4)..<(delimiterOffset + 8)].allSatisfy({ $0 == 0 }) else {
            return nil
        }
        return Data(fileData[start..<(delimiterOffset + 8)])
    }
}
