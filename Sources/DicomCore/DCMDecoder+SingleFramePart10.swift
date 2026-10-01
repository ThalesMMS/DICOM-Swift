import Foundation

extension DCMDecoder {
    /// Produces internal codec input without decoding other frames. Do not publish this
    /// artifact: it deliberately retains the source identifiers for host compatibility.
    public func singleFramePart10Data(at frameIndex: Int) throws -> Data {
        try synchronized {
            try Task.checkCancellation()
            guard let syntax = DicomTransferSyntax(uid: transferSyntaxUID) else {
                throw DicomSourceFrameIndex.Failure.unsupportedLayout(transferSyntaxUID)
            }
            let layout = pixelDataDescriptor
            let bytes: Data
            var pixelDataTag = DicomTag.pixelData.rawValue
            let floatingPixels = [DicomTag.floatPixelData, .doubleFloatPixelData]
                .compactMap { tagMetadataCache[$0.rawValue] }.first
            if let floatingPixels {
                guard !compressedImage, let layout,
                      layout.bitsAllocated == (floatingPixels.tag == DicomTag.floatPixelData.rawValue ? 32 : 64),
                      let range = layout.byteRange(forFrame: frameIndex) else {
                    throw DicomSourceFrameIndex.Failure.invalidLayout
                }
                let relativeRange = (range.lowerBound - layout.pixelDataOffset)..<(range.upperBound - layout.pixelDataOffset)
                guard floatingPixels.offset >= 0, floatingPixels.offset <= dicomData.count,
                      floatingPixels.elementLength <= dicomData.count - floatingPixels.offset,
                      relativeRange.upperBound <= floatingPixels.elementLength else {
                    throw DicomSourceFrameIndex.Failure.invalidLayout
                }
                guard relativeRange.count <= 64 * 1024 * 1024 else { throw DicomSourceFrameIndex.Failure.frameLimit }
                let start = floatingPixels.offset + relativeRange.lowerBound
                let end = floatingPixels.offset + relativeRange.upperBound
                bytes = Data(dicomData[start..<end])
                pixelDataTag = floatingPixels.tag
            } else if compressedImage {
                let reader = try makeEncapsulatedPixelFrameReader()
                try reader.validateDeclaredFrameCount()
                bytes = try reader.frameData(at: frameIndex)
            } else {
                guard let frame = getFrame(frameIndex) else { throw DicomSourceFrameIndex.Failure.invalidLayout }
                bytes = frame.data
            }
            guard bytes.count <= 64 * 1024 * 1024 else { throw DicomSourceFrameIndex.Failure.frameLimit }
            return try DicomSingleFramePart10Writer.data(
                dataSet: dataSet, transferSyntax: syntax,
                frameCount: max(1, nImages), frame: frameIndex, rawFrame: bytes,
                nativeLayout: layout,
                packedBitOffset: layout.map { (frameIndex * $0.bitsPerFrame) % 8 } ?? 0,
                pixelDataTag: pixelDataTag
            )
        }
    }
}
