//
// J2KNumericUtilities.swift
// J2KSwift
//

import Foundation

enum J2KSampleByteOrder {
    case littleEndian
    case bigEndian
}

@inline(__always)
func j2kClampedInt32(_ value: Double) -> Int32 {
    let rounded = value.rounded()
    if rounded.isNaN { return 0 }
    if rounded >= Double(Int32.max) { return Int32.max }
    if rounded <= Double(Int32.min) { return Int32.min }
    return Int32(rounded)
}

@inline(__always)
func j2kHostIsLittleEndian() -> Bool {
    var value: UInt16 = 1
    return withUnsafeBytes(of: &value) { bytes in
        bytes.first == 1
    }
}

func j2kInfer16BitByteOrder(
    in data: Data,
    sampleCount: Int,
    bitDepth: Int,
    signed: Bool
) -> J2KSampleByteOrder {
    guard sampleCount > 0 else {
        return .bigEndian
    }

    // Strided sample across the entire frame. Medical images (mammography,
    // MRI) routinely have zero-filled margins at the top of the raster, so
    // sampling only the first few hundred pixels produces a penalty tie that
    // silently falls back to host byte order. Walking every `stride`-th sample
    // across the whole frame guarantees we hit informative pixels.
    let kInspectedBudget = 4096
    let stride = max(1, sampleCount / kInspectedBudget)
    let inspected = min(sampleCount, kInspectedBudget)

    let lowerBound: Int32
    let upperBound: Int32
    if signed {
        let halfRange = Int32(1 << max(0, min(bitDepth - 1, 30)))
        lowerBound = -halfRange
        upperBound = halfRange - 1
    } else {
        lowerBound = 0
        upperBound = Int32(min((1 << max(0, min(bitDepth, 30))) - 1, Int(Int32.max)))
    }

    var littlePenalty = 0.0
    var bigPenalty = 0.0
    var informativeSamples = 0
    var previousLittle: Int32?
    var previousBig: Int32?

    data.withUnsafeBytes { buffer in
        guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return
        }

        for k in 0..<inspected {
            let i = k * stride
            guard i * 2 + 1 < buffer.count else { break }
            let littleRaw = UInt16(ptr[i * 2]) | (UInt16(ptr[i * 2 + 1]) << 8)
            let bigRaw = (UInt16(ptr[i * 2]) << 8) | UInt16(ptr[i * 2 + 1])

            let littleValue = signed ? Int32(Int16(bitPattern: littleRaw)) : Int32(littleRaw)
            let bigValue = signed ? Int32(Int16(bitPattern: bigRaw)) : Int32(bigRaw)

            // Any sample where the two interpretations diverge is informative.
            if littleRaw != bigRaw {
                informativeSamples += 1
            }

            func rangePenalty(for value: Int32) -> Double {
                if value < lowerBound {
                    return 1000.0 + Double(lowerBound - value)
                }
                if value > upperBound {
                    return 1000.0 + Double(value - upperBound)
                }
                return 0.0
            }

            littlePenalty += rangePenalty(for: littleValue)
            bigPenalty += rangePenalty(for: bigValue)

            if let previousLittle {
                littlePenalty += min(Double(abs(littleValue - previousLittle)), 4096.0) / 32.0
            }
            if let previousBig {
                bigPenalty += min(Double(abs(bigValue - previousBig)), 4096.0) / 32.0
            }

            previousLittle = littleValue
            previousBig = bigValue
        }
    }

    // If we never saw a single informative sample (all bytes palindromic —
    // typically all-zero data) the byte order cannot be decided. Default to
    // big-endian, the conventional canonical layout for image pixel data.
    if informativeSamples == 0 || littlePenalty == bigPenalty {
        return .bigEndian
    }
    return littlePenalty < bigPenalty ? .littleEndian : .bigEndian
}
