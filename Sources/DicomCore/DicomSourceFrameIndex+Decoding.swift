import Foundation

extension DicomSourceFrameIndex {
    /// Writes one selected frame through the existing writer, retaining stored sample
    /// representation and selected functional groups. The source frame count lives in this index.
    func part10Data(frame: Int, rawFrame: Data) throws -> Data {
        _ = try ranges(forFrame: frame)
        return try DicomSingleFramePart10Writer.data(
            dataSet: metadata.dataSet, transferSyntax: metadata.transferSyntax,
            frameCount: frameCount, frame: frame, rawFrame: rawFrame,
            nativeLayout: nativeLayout, packedBitOffset: packedBitOffset(forFrame: frame),
            pixelDataTag: metadata.pixelDataTag, wordSwapLeadingBytes: try wordSwapLeadingBytes(forFrame: frame)
        )
    }

    func decodedByteCount() throws -> Int {
        let dataSet = metadata.dataSet
        let allocated = dataSet.int(for: .bitsAllocated) ?? 0
        guard metadata.pixelDataTag == DicomTag.pixelData.rawValue, [1, 8, 16].contains(allocated) else {
            throw Failure.unsupportedLayout("Display decoding requires qualified integer 1/8/16-bit pixels; raw extraction preserves wider and floating samples.")
        }
        let rows = dataSet.int(for: .rows) ?? 0
        let columns = dataSet.int(for: .columns) ?? 0
        let components = dataSet.int(for: .samplesPerPixel) ?? 1
        guard rows > 0, columns > 0, components == 1 || (components == 3 && allocated == 8) else { throw Failure.invalidLayout }
        let pixels = rows.multipliedReportingOverflow(by: columns)
        guard !pixels.overflow else { throw Failure.frameLimit }
        // Palette color expands to RGB, even though its stored component count is one.
        let outputComponents = dataSet.string(for: .photometricInterpretation) == "PALETTE COLOR" ? 3 : components
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: outputComponents * (allocated <= 8 ? 1 : 2))
        guard !bytes.overflow else { throw Failure.frameLimit }
        return bytes.partialValue
    }

    func decode(frame: Int, part10: Data) async throws -> DicomDataBackedDecodedFrame {
        _ = try decodedByteCount()
        let reader = try DicomDecodedFrameReader(decoder: DCMDecoder(data: part10))
        let decoded = try await reader.dataBackedFrame(at: 0)
        return DicomDataBackedDecodedFrame(index: frame, pixels: decoded.pixels,
            metadata: reader.makeMetadata(width: decoded.metadata.width, height: decoded.metadata.height,
                                          frameCount: frameCount, frameIndex: 0,
                                          codestreamPrecision: decoded.metadata.bitsStored,
                                          decodedSampleBits: decoded.metadata.bitsAllocated))
    }

    func decodeArray(frame: Int, part10: Data) async throws -> DicomDecodedFrame {
        _ = try decodedByteCount()
        let reader = try DicomDecodedFrameReader(decoder: DCMDecoder(data: part10))
        let decoded = try await reader.frame(at: 0)
        return DicomDecodedFrame(index: frame, pixels: decoded.pixels,
            metadata: reader.makeMetadata(width: decoded.metadata.width, height: decoded.metadata.height,
                                          frameCount: frameCount, frameIndex: 0,
                                          codestreamPrecision: decoded.metadata.bitsStored,
                                          decodedSampleBits: decoded.metadata.bitsAllocated))
    }

    func decodePartial(frame: Int, part10: Data, request: DicomPartialFrameDecodeRequest) async throws -> DicomPartialFrameDecodeResult {
        _ = try decodedByteCount()
        let reader = try DicomDecodedFrameReader(decoder: DCMDecoder(data: part10))
        let result = try await reader.frame(at: 0, partial: request)
        let decoded = DicomDecodedFrame(index: frame, pixels: result.frame.pixels,
            metadata: reader.makeMetadata(width: result.frame.metadata.width, height: result.frame.metadata.height,
                                          frameCount: frameCount, frameIndex: 0,
                                          codestreamPrecision: result.frame.metadata.bitsStored,
                                          decodedSampleBits: result.frame.metadata.bitsAllocated))
        return DicomPartialFrameDecodeResult(frame: decoded, decodedSourceRegion: result.decodedSourceRegion,
            coordinateTransform: result.coordinateTransform, deliveredQualityLayer: result.deliveredQualityLayer,
            qualityState: result.qualityState, execution: result.execution, codecBytesAvoided: result.codecBytesAvoided)
    }
}
