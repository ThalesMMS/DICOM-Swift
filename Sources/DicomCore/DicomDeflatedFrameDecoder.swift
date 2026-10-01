import DicomData
import Foundation

/// Native frame bytes of one Deflated Image Frame Compression fragment, ready for the shared pixel readers.
internal enum DicomDeflatedFrameDecoder {
    /// Inflates the fragment to the frame length declared by the Image Pixel attributes and, for planar
    /// colour frames (Planar Configuration 1), re-interleaves the planes so the result matches the
    /// interleaved layout the compressed pixel readers expect. Packed YBR_FULL_422 is converted to RGB8.
    /// Byte order is little endian as the syntax mandates.
    static func interleavedNativeBytes(
        fragment: Data,
        width: Int,
        height: Int,
        bitsAllocated: Int,
        samplesPerPixel: Int,
        planarConfiguration: Int,
        photometricInterpretation: String = ""
    ) throws -> Data {
        guard let expected = DicomDeflatedFrameCodec.frameByteCount(
            rows: height, columns: width, samplesPerPixel: samplesPerPixel, bitsAllocated: bitsAllocated,
            photometricInterpretation: photometricInterpretation
        ) else {
            throw DicomDeflatedFrameError.invalidFrameShape
        }
        let native = try DicomDeflatedFrameCodec.decodeFrame(fragment, expectedByteCount: expected)
        if DicomPhotometricInterpretation(photometricInterpretation) == .ybrFull422 {
            guard bitsAllocated == 8, planarConfiguration == 0 else { throw DicomDeflatedFrameError.invalidFrameShape }
            var rgb = Data(capacity: width * height * 3)
            for offset in stride(from: 0, to: native.count, by: 4) {
                for y in [native[offset], native[offset + 1]] {
                    let pixel = DCMDecoder.ybrToRgb(y: y, cb: native[offset + 2], cr: native[offset + 3])
                    rgb.append(contentsOf: [pixel.0, pixel.1, pixel.2])
                }
            }
            return rgb
        }
        guard samplesPerPixel > 1, planarConfiguration == 1, bitsAllocated.isMultiple(of: 8) else { return native }
        let bytesPerSample = bitsAllocated / 8
        let pixels = width * height
        let planeBytes = pixels * bytesPerSample
        var interleaved = [UInt8](repeating: 0, count: native.count)
        native.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            for sample in 0..<samplesPerPixel {
                let planeBase = sample * planeBytes
                for pixel in 0..<pixels {
                    let from = planeBase + pixel * bytesPerSample
                    let to = (pixel * samplesPerPixel + sample) * bytesPerSample
                    for byte in 0..<bytesPerSample { interleaved[to + byte] = source[from + byte] }
                }
            }
        }
        return Data(interleaved)
    }
}
