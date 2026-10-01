// ICCStreamEncoder — writes an ICC profile as the codestream ICC stream
// of ISO/IEC 18181-1 Annex C.3.4 so that a DICOM ICC Profile (0028,2000)
// travels inside the JPEG XL codestream unchanged (issue #2332).
//
// The stream is the entropy-coded output of the ICC prediction transform.
// This writer uses the minimal command set the transform allows — the
// mandatory 128-byte header prediction followed by one `insert` command
// for the remaining bytes — and a single prefix-coded cluster shared by
// the 41 byte contexts. Every conforming decoder (libjxl's `ReadICC`, the
// `ICCStream.decode` of this module) reconstructs the profile byte for
// byte; the encoding is merely less compact than libjxl's tag-aware
// transform, which does not matter for the few kilobytes of a DICOM
// profile.

import Foundation

extension ICCStream {
    /// Encodes `icc` at the current bit position of `w` (immediately after
    /// the image metadata and custom transform data, before the byte
    /// alignment that precedes the first frame).
    package static func encode(_ icc: Data, to w: inout BitWriter) throws {
        guard !icc.isEmpty else {
            throw ICCStreamError.malformed("ICC profile must not be empty")
        }
        guard icc.count <= Int(UInt32.max >> 2) else {
            throw ICCStreamError.malformed("ICC profile is too large")
        }
        let enc = predictMinimal(Array(icc))
        w.writeU64(UInt64(enc.count))

        // Tokens: one byte value per context.
        let uintConfig = HybridUintConfig(splitExponent: 8, msbInToken: 0, lsbInToken: 0)
        var histogram = [Int](repeating: 0, count: 256)
        var maxToken = 0
        for i in 0..<enc.count {
            let t = Int(uintConfig.encode(UInt32(enc[i])).token)
            histogram[t] += 1
            maxToken = max(maxToken, t)
        }
        let alphabet = max(2, maxToken + 1)
        let lengths = lengthLimitedCanonicalHuffman(
            counts: Array(histogram[0..<alphabet]), maxLength: 15, alphabetSize: alphabet
        )
        let table = try PrefixCodeTable(lengths: lengths)
        let codebook = MultiClusterCodebook(huffmanTables: [table], ansCounts: [], alphabetSizes: [alphabet])
        let header = EntropySectionHeader(
            lz77: .disabled, contextMap: ContextMap.trivial(numContexts: numContexts),
            usePrefixCode: true, logAlphaSize: 15, uintConfigs: [uintConfig]
        )
        do {
            try header.write(to: &w, numContexts: numContexts)
            try codebook.write(to: &w, header: header)
            let writer = TokenStreamWriter(header: header, codebook: codebook)
            for i in 0..<enc.count {
                let b1 = i >= 1 ? Int(enc[i - 1]) : 0
                let b2 = i >= 2 ? Int(enc[i - 2]) : 0
                try writer.writeToken(context: iccANSContext(i: i, b1: b1, b2: b2), value: UInt32(enc[i]), to: &w)
            }
        } catch {
            throw ICCStreamError.entropy("\(error)")
        }
    }

    /// The minimal ICC prediction transform: `varint(size) varint(commands)
    /// commands data`, with the header residuals and one `insert`.
    static func predictMinimal(_ icc: [UInt8]) -> [UInt8] {
        let size = icc.count
        var out: [UInt8] = []
        appendVarInt(UInt64(size), &out)
        var commands: [UInt8] = []
        var data: [UInt8] = []
        var header = initialHeaderPrediction
        header[0] = UInt8((size >> 24) & 0xFF)
        header[1] = UInt8((size >> 16) & 0xFF)
        header[2] = UInt8((size >> 8) & 0xFF)
        header[3] = UInt8(size & 0xFF)
        let headerBytes = min(headerSize, size)
        for i in 0..<headerBytes {
            iccPredictHeader(icc, i, &header, i)
            data.append(icc[i] &- header[i])
        }
        if size > headerSize {
            commands.append(0)                    // no tag table prediction
            commands.append(UInt8(kCommandInsert))
            appendVarInt(UInt64(size - headerSize), &commands)
            data.append(contentsOf: icc[headerSize...])
        }
        appendVarInt(UInt64(commands.count), &out)
        out.append(contentsOf: commands)
        out.append(contentsOf: data)
        return out
    }

    private static func appendVarInt(_ valueIn: UInt64, _ out: inout [UInt8]) {
        var value = valueIn
        while value > 127 {
            out.append(UInt8(value & 127) | 128)
            value >>= 7
        }
        out.append(UInt8(value & 127))
    }
}
