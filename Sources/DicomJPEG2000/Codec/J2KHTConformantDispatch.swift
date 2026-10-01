// J2KHTBlockCoderConformantDispatch.swift
// Dispatch layer between the pipeline's HTBlockEncoder / HTBlockDecoder
// and the ISO/IEC 15444-15 conformant block coder (the only HT block
// wire format this module reads or writes).
//
// Responsibilities:
// - Translate between the pipeline's Int32 sign-magnitude coefficient
//   convention (sign in bit 31, magnitude in the low bits) and the
//   Part-15 encoder's UInt32 convention.
// - Wrap the raw Part-15 bytes produced by
//   `HTBlockEncoderConformant.encode` + `HTBlockLayoutConformant.assemble`
//   in an `HTEncodedBlock`.
// - Invert the wrap for the decoder side.

import Foundation

extension HTBlockEncoder {

    /// Encode a codeblock using the ISO/IEC 15444-15 conformant
    /// cleanup pass. Emits bytes that OpenJPH 0.26+ can decode.
    ///
    /// `missingMSBs` corresponds to the Kmsbs / p-bit convention from
    /// ITU T.814: `p = 30 - missingMSBs`. Pass `0` for the default
    /// 30-bit bit-plane path.
    ///
    /// Input coefficients use the pipeline's `Int32` sign-magnitude
    /// convention: bit 31 is the sign; the magnitude occupies the
    /// low 31 bits and is expected to align to the bit-plane.
    func encodeCleanupConformant(
        coefficients: [Int32],
        missingMSBs: Int = 0
    ) throws -> HTEncodedBlock {
        guard coefficients.count == width * height else {
            throw J2KError.encodingError(
                "coefficient count mismatch (\(coefficients.count) " +
                "vs \(width * height))")
        }

        // Reinterpret Int32 bit pattern as UInt32; sign bit and
        // magnitude bits are identical on a 2's complement platform
        // (which is the only platform Swift supports).
        let input = coefficients.map { UInt32(bitPattern: $0) }

        let (ms, mel, vlc) = HTBlockEncoderConformant.encode(
            coefficients: input,
            width: width, height: height,
            missingMSBs: missingMSBs)
        // v9.2 Path B Phase 3a — Data-returning assemble; one alloc per
        // single-block encode.
        let codedData = try HTBlockLayoutConformant.assembleData(
            magsgn: ms, mel: mel, vlc: vlc)

        return HTEncodedBlock(
            codedData: codedData,
            passType: .htCleanup,
            melLength: mel.count,
            vlcLength: vlc.count,
            magsgnLength: ms.count,
            bitPlane: 30 - missingMSBs,
            width: width,
            height: height)
    }
}

extension HTBlockDecoder {

    /// Block-level Conformant decode. Returns coefficients in the
    /// block coder's raw OpenJPH sign-magnitude convention (bit 31 =
    /// sign, magnitude shifted left so MSB lands at bit `[31 - K_max]`).
    /// Callers that want pipeline-scale integer magnitudes should
    /// use `decodeCleanupConformant(rawBytes:missingMSBs:)` instead.
    func decodeCleanupConformant(
        from block: HTEncodedBlock
    ) throws -> [Int32] {
        let decoded = try HTBlockDecoderConformant.decode(
            block: [UInt8](block.codedData),
            width: width, height: height,
            missingMSBs: 0)
        return decoded.map { Int32(bitPattern: $0) }
    }

    /// Pipeline-level Conformant decode. Unlike `from block:`, this
    /// overload converts the block coder's shifted sign-magnitude
    /// output into the pipeline's Int32 integer-magnitude convention
    /// (sign in bit 31 via 2's complement, integer magnitude in the
    /// low bits).
    func decodeCleanupConformant(
        rawBytes: [UInt8],
        missingMSBs: Int
    ) throws -> [Int32] {
        let decoded = try HTBlockDecoderConformant.decode(
            block: rawBytes,
            width: width, height: height,
            missingMSBs: missingMSBs)
        // K_max = missingMSBs + 1, shift = 31 - K_max = 30 - missingMSBs.
        let shift = 30 - missingMSBs
        return decoded.map { uint in
            let sign = (uint & 0x8000_0000) != 0
            let mag = Int32((uint & 0x7FFF_FFFF) >> shift)
            return sign ? -mag : mag
        }
    }
}
