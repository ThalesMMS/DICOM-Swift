import Foundation

extension DicomDecodedFrame {
    /// The frame as little-endian stored sample bytes: the display normalisation of the typed buffer
    /// (signed level shift to unsigned, MONOCHROME1 full-range inversion) is undone so signed samples are
    /// two's complement again and MONOCHROME1 samples are the values written in the object. Colour frames
    /// are interleaved RGB regardless of the source Planar Configuration. This is the sample contract that
    /// native readers and the GDCM bridge deliver, so consumers can mix providers without a second convention.
    public func storedSampleData() -> Data {
        let inverted = metadata.photometricInterpretation == "MONOCHROME1"
        let signed = metadata.pixelRepresentation == 1
        switch pixels {
        case .gray16(let values):
            let bits = StoredBits(metadata, width: 16)
            var bytes = Data(capacity: values.count * 2)
            for value in values {
                let unInverted = inverted ? UInt16.max - value : value
                let pattern: UInt16 = signed
                    ? UInt16(bitPattern: Int16(truncatingIfNeeded: Int32(unInverted) + Int32(Int16.min)))
                    : unInverted
                let stored = UInt16(truncatingIfNeeded: bits.sample(Int(pattern), signed: signed))
                bytes.append(UInt8(stored & 0xFF))
                bytes.append(UInt8(stored >> 8))
            }
            return bytes
        case .gray8(let values):
            let bits = StoredBits(metadata, width: 8)
            return Data(values.map { value -> UInt8 in
                let unInverted = inverted ? UInt8.max - value : value
                let pattern = signed ? UInt8(bitPattern: Int8(truncatingIfNeeded: Int(unInverted) - 128)) : unInverted
                return UInt8(truncatingIfNeeded: bits.sample(Int(pattern), signed: signed))
            })
        case .rgb8(let interleaved):
            return Data(interleaved)
        }
    }
}

/// PS3.5 8.1.1: only Bits Stored bits, ending at High Bit, belong to a sample; any others in the allocated
/// word are ignored (issue #2851). A signed sample takes its sign from its own top bit.
private struct StoredBits {
    let shift: Int
    let mask: Int
    let signBit: Int
    let isWholeWord: Bool

    init(_ metadata: DicomDecodedFrameMetadata, width: Int) {
        let bitsStored = metadata.bitsStored
        let highBit = metadata.highBit
        let valid = bitsStored > 0 && bitsStored <= width && highBit >= bitsStored - 1 && highBit < width
        shift = valid ? highBit - bitsStored + 1 : 0
        mask = valid ? (1 << bitsStored) - 1 : (1 << width) - 1
        signBit = valid ? 1 << (bitsStored - 1) : 1 << (width - 1)
        isWholeWord = !valid || (bitsStored == width && shift == 0)
    }

    func sample(_ pattern: Int, signed: Bool) -> Int {
        guard !isWholeWord else { return pattern }
        let value = (pattern >> shift) & mask
        return signed && value & signBit != 0 ? value | ~mask : value
    }
}
