//
// J2KBitPlaneNativeDecoding.swift
// DicomJPEG2000
//
// EBCOT code-block decoding through the C block decoder of DicomJPEG2000NEON (issue #3078).
//

import Foundation
import DicomJPEG2000NEON

extension BitPlaneDecoder {
    /// The codeword segments of a block: each segment's slice of the block data, and the segment of each pass
    /// (Annex D): one per pass under RESTART or `.predictable`, and 10, 2, 1, 2, 1, ... passes under selective bypass.
    /// Both are empty when the block is one segment.
    func segmentPlan(
        passCount: Int,
        passSegmentLengths: [Int],
        dataCount: Int
    ) throws -> (slices: [(offset: Int, count: Int)], segmentOfPass: [Int]) {
        guard !passSegmentLengths.isEmpty else { return ([], []) }
        let totalSegmentLength = passSegmentLengths.reduce(0, +)
        guard totalSegmentLength <= dataCount else {
            throw J2KError.invalidParameter(
                "Pass segment lengths total (\(totalSegmentLength)) exceeds data size (\(dataCount))"
            )
        }
        var slices: [(offset: Int, count: Int)] = []
        slices.reserveCapacity(passSegmentLengths.count)
        var offset = 0
        for length in passSegmentLengths {
            slices.append((offset: offset, count: length))
            offset += length
        }
        var counts = DecoderPipeline.segmentPassCounts(
            numPasses: passCount,
            terminateOnEachPass: options.terminateOnEachPass || options.terminationMode == .predictable,
            bypass: options.bypassEnabled)
        if counts.count != slices.count {
            // A direct code-block caller that terminates every pass hands over one segment per pass; with the
            // lengths in hand there is no packet header whose shape they must follow.
            counts = [Int](repeating: 1, count: min(passCount, slices.count))
        }
        var segmentOfPass: [Int] = []
        for (segment, passes) in counts.enumerated() {
            segmentOfPass.append(contentsOf: repeatElement(segment, count: passes))
        }
        return (slices, segmentOfPass)
    }

    /// `decode` with ISO run-length position coding, run by `j2kt1d_decode_block`. Same output, same errors.
    func decodeNative(
        data: Data,
        passCount: Int,
        bitDepth: Int,
        zeroBitPlanes: Int,
        passSegmentLengths: [Int],
        irreversible: Bool,
        scratch: DecoderScratchBuffers?
    ) throws -> [Int32] {
        let plan = try segmentPlan(passCount: passCount, passSegmentLengths: passSegmentLengths, dataCount: data.count)
        let offsets = plan.slices.map { Int32($0.offset) }
        let lengths = plan.slices.map { Int32($0.count) }
        let segmentOfPass = plan.segmentOfPass.map { Int32($0) }
        let wordCount = j2kt1d_scratch_words(Int32(width), Int32(height))
        var words: [UInt32]
        if let scratch {
            words = scratch.nativeWords
            scratch.nativeWords = []
            if words.count < wordCount { words = [UInt32](repeating: 0, count: wordCount) }
        } else {
            words = [UInt32](repeating: 0, count: wordCount)
        }
        defer { scratch?.nativeWords = words }

        let orientation: Int32
        switch subband {
        case .hl: orientation = Int32(J2KT1D_ORIENT_HL)
        case .hh: orientation = Int32(J2KT1D_ORIENT_HH)
        case .lh, .ll: orientation = Int32(J2KT1D_ORIENT_LL_LH)
        }
        var result = j2kt1d_result_t()
        var status: Int32 = 0
        let count = width * height
        let coefficients = [Int32](unsafeUninitializedCapacity: count) { output, initialized in
            data.withUnsafeBytes { raw in
                offsets.withUnsafeBufferPointer { offsetPtr in
                    lengths.withUnsafeBufferPointer { lengthPtr in
                        segmentOfPass.withUnsafeBufferPointer { passPtr in
                            words.withUnsafeMutableBufferPointer { wordPtr in
                                var params = j2kt1d_params_t(
                                    width: Int32(width),
                                    height: Int32(height),
                                    orientation: orientation,
                                    pass_count: Int32(passCount),
                                    active_bit_planes: Int32(bitDepth - zeroBitPlanes),
                                    irreversible: irreversible ? 1 : 0,
                                    bypass: options.bypassEnabled ? 1 : 0,
                                    reset_each_pass: options.resetContextOnEachPass || options.resetOnEachPass ? 1 : 0,
                                    vertically_causal: options.verticallyCausalContext ? 1 : 0,
                                    segmentation_symbols: options.segmentationSymbols ? 1 : 0,
                                    data: raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                    data_count: Int32(raw.count),
                                    segment_offsets: offsetPtr.baseAddress,
                                    segment_lengths: lengthPtr.baseAddress,
                                    segment_count: Int32(lengthPtr.count),
                                    segment_of_pass: passPtr.baseAddress,
                                    segment_of_pass_count: Int32(passPtr.count))
                                status = j2kt1d_decode_block(
                                    &params, output.baseAddress, wordPtr.baseAddress, wordPtr.count, &result)
                            }
                        }
                    }
                }
            }
            initialized = count
        }
        switch status {
        case Int32(J2KT1D_OK):
            break
        case Int32(J2KT1D_BAD_SEGMENTATION_SYMBOL):
            throw J2KError.decodingError(
                "Segmentation symbol 0x\(String(result.bad_symbol, radix: 16)) after cleanup pass \(result.bad_pass); "
                + "expected 0xA")
        default:
            throw J2KError.internalError("EBCOT block decoder status \(status)")
        }
        if options.checksEntropyIntegrity {
            var integrity = EntropyIntegrity()
            integrity.absorb(declared: Int(result.declared_bytes), consumed: Int(result.consumed_bytes),
                             overRead: Int(result.over_read_count))
            if let anomaly = integrity.anomaly {
                throw J2KError.corruptedEntropyData(anomaly)
            }
        }
        return coefficients
    }
}
