import Foundation

/// Immutable, Sendable decoded pixels backed by Foundation Data.
///
/// The Data value retains its bytes for the lifetime of this value and every copy of it. Any pointer obtained from
/// `withUnsafeBytes` is valid only for the duration of that closure. The current backends do not guarantee a stable
/// base-address alignment, so `baseAddressAlignment` is nil and consumers must not bind the bytes to `UInt16`.
public struct DicomDecodedFrameDataBuffer: Equatable, Sendable {
    /// Immutable canonical pixel bytes retained by this value.
    public let data: Data
    /// Pixel and component layout used to interpret `data`.
    public let format: DicomDecodedFrameDataFormat
    /// Byte order of multi-byte component samples.
    public let byteOrder: DicomDecodedFrameByteOrder
    /// Storage retention model reported by the producing backend.
    public let ownership: DicomDecodedFrameDataOwnership
    /// Number of addressable image pixels (`width * height`).
    public let pixelCount: Int
    /// Number of scalar component samples, including all RGB components.
    public let componentSampleCount: Int
    /// Number of tightly packed canonical bytes in one decoded row.
    public let bytesPerRow: Int
    /// Guaranteed base-address alignment, or nil when no stable guarantee exists.
    public let baseAddressAlignment: Int?

    init(
        data: Data,
        format: DicomDecodedFrameDataFormat,
        byteOrder: DicomDecodedFrameByteOrder,
        ownership: DicomDecodedFrameDataOwnership,
        pixelCount: Int,
        componentSampleCount: Int,
        bytesPerRow: Int
    ) {
        self.data = data
        self.format = format
        self.byteOrder = byteOrder
        self.ownership = ownership
        self.pixelCount = pixelCount
        self.componentSampleCount = componentSampleCount
        self.bytesPerRow = bytesPerRow
        self.baseAddressAlignment = nil
    }

    /// Gives temporary read-only access to the decoded bytes without promising alignment.
    public func withUnsafeBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try data.withUnsafeBytes(body)
    }

    /// Copies the canonical bytes into the source-compatible array-backed pixel representation.
    public func copyingToArrayBackedPixels() -> DicomDecodedFramePixelBuffer {
        switch format {
        case .gray8NormalizedUnsigned:
            return .gray8(Array(data))
        case .rgb8Interleaved:
            return .rgb8(interleaved: Array(data))
        case .gray16NormalizedUnsigned:
            let samples = [UInt16](unsafeUninitializedCapacity: componentSampleCount) { buffer, count in
                for index in 0..<componentSampleCount {
                    let byteIndex = index * 2
                    buffer[index] = UInt16(data[byteIndex]) | (UInt16(data[byteIndex + 1]) << 8)
                }
                count = componentSampleCount
            }
            return .gray16(samples)
        }
    }
}
