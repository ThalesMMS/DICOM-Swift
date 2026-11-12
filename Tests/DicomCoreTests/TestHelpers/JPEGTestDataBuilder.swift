//
//  JPEGTestDataBuilder.swift
//  DicomCoreTests
//
//  Create a minimal, self-contained JPEG byte stream representing a lossless (SOF3) image using the
//  supplied dimensions and encoding parameters.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

/// Create a minimal, self-contained JPEG byte stream representing a lossless (SOF3) image using the supplied dimensions and encoding parameters.
/// - Parameters:
///   - width: Image width in pixels; must be > 0 and ≤ UInt16.max.
///   - height: Image height in pixels; must be > 0 and ≤ UInt16.max.
///   - precision: Sample precision (bits per sample); must be within 0...UInt8.max. Default is 16.
///   - predictionMode: Lossless prediction mode value; must be within 0...7. Default is 1.
/// - Returns: A `Data` buffer containing a minimal JPEG stream (SOI, DHT, SOF3, SOS, compressed payload of zero bytes, EOI) sized for the given image dimensions.
func makeMinimalJPEGLosslessData(
    width: Int,
    height: Int,
    precision: Int = 16,
    predictionMode: Int = 1
) -> Data {
    precondition(width > 0 && width <= Int(UInt16.max))
    precondition(height > 0 && height <= Int(UInt16.max))
    precondition((0...Int(UInt8.max)).contains(precision))
    precondition((0...7).contains(predictionMode))

    var jpegData = Data()

    jpegData.append(contentsOf: [0xFF, 0xD8])

    let symbolCounts: [UInt8] = [1] + Array(repeating: 0, count: 15)
    let symbolValues: [UInt8] = [0]

    jpegData.append(contentsOf: [0xFF, 0xC4])
    jpegData.appendUInt16(2 + 1 + 16 + UInt16(symbolValues.count))
    jpegData.append(0x00)
    jpegData.append(contentsOf: symbolCounts)
    jpegData.append(contentsOf: symbolValues)

    jpegData.append(contentsOf: [0xFF, 0xC3])
    jpegData.appendUInt16(11)
    jpegData.append(UInt8(precision))
    jpegData.appendUInt16(UInt16(height))
    jpegData.appendUInt16(UInt16(width))
    jpegData.append(1)
    jpegData.append(1)
    jpegData.append(0x11)
    jpegData.append(0)

    jpegData.append(contentsOf: [0xFF, 0xDA])
    jpegData.appendUInt16(8)
    jpegData.append(1)
    jpegData.append(1)
    jpegData.append(0x00)
    jpegData.append(UInt8(predictionMode))
    jpegData.append(0)
    jpegData.append(0)

    let pixelCount = width * height
    let compressedByteCount = max(1, (pixelCount + 7) / 8)
    jpegData.append(contentsOf: [UInt8](repeating: 0x00, count: compressedByteCount))

    jpegData.append(contentsOf: [0xFF, 0xD9])

    return jpegData
}

/// Encodes a complete JPEG Lossless (SOF3) stream for the given component
/// planes, mirroring the decoder's T.81 H.1.2 prediction semantics
/// (interval first sample = default, interval first line = Ra, line starts
/// = Rb, interior = selection-value predictor). Supports restart intervals
/// and 1 or 3 interleaved components, so round-trips exercise the real
/// entropy path.
func makeJPEGLosslessStream(
    planes: [[Int]],
    width: Int,
    height: Int,
    precision: Int,
    selectionValue: Int = 1,
    restartInterval: Int = 0
) -> Data {
    precondition(planes.count == 1 || planes.count == 3, "1 or 3 component planes")
    precondition(planes.allSatisfy { $0.count == width * height }, "one sample per pixel per plane")

    var data = Data([0xFF, 0xD8]) // SOI

    // DHT: DC table 0 with categories 0...16, all 5-bit codes.
    let symbolValues: [UInt8] = (0...16).map(UInt8.init)
    var counts = [UInt8](repeating: 0, count: 16)
    counts[4] = UInt8(symbolValues.count) // 17 codes of length 5
    data.append(contentsOf: [0xFF, 0xC4])
    data.appendUInt16(UInt16(2 + 1 + 16 + symbolValues.count))
    data.append(0x00)
    data.append(contentsOf: counts)
    data.append(contentsOf: symbolValues)

    // SOF3
    let componentCount = planes.count
    data.append(contentsOf: [0xFF, 0xC3])
    data.appendUInt16(UInt16(8 + componentCount * 3))
    data.append(UInt8(precision))
    data.appendUInt16(UInt16(height))
    data.appendUInt16(UInt16(width))
    data.append(UInt8(componentCount))
    for component in 0..<componentCount {
        data.append(contentsOf: [UInt8(component + 1), 0x11, 0x00])
    }

    if restartInterval > 0 {
        data.append(contentsOf: [0xFF, 0xDD, 0x00, 0x04])
        data.appendUInt16(UInt16(restartInterval))
    }

    // SOS (single interleaved scan over every component)
    data.append(contentsOf: [0xFF, 0xDA])
    data.appendUInt16(UInt16(6 + componentCount * 2))
    data.append(UInt8(componentCount))
    for component in 0..<componentCount {
        data.append(contentsOf: [UInt8(component + 1), 0x00])
    }
    data.append(UInt8(selectionValue))
    data.append(0)
    data.append(0)

    // Entropy-coded data.
    var writer = JPEGLosslessTestBitWriter()
    var restartCount = 0
    var intervalStartMCU = 0
    var mcuIndex = 0
    let modulo = 1 << precision
    for y in 0..<height {
        for x in 0..<width {
            if restartInterval > 0, mcuIndex > 0, mcuIndex % restartInterval == 0 {
                writer.flushWithOnePadding(into: &data)
                data.append(contentsOf: [0xFF, UInt8(0xD0 + restartCount % 8)])
                restartCount += 1
                intervalStartMCU = mcuIndex
            }
            for plane in planes {
                let predictor = jpegLosslessTestPredictor(
                    plane: plane,
                    x: x,
                    y: y,
                    width: width,
                    precision: precision,
                    selectionValue: selectionValue,
                    intervalStartMCU: intervalStartMCU
                )
                var difference = plane[y * width + x] - predictor
                // T.81 modulo-2^16 difference arithmetic (keep magnitudes small in tests).
                if difference > modulo / 2 { difference -= modulo }
                if difference < -modulo / 2 { difference += modulo }
                let category = jpegLosslessMagnitudeCategory(of: difference)
                writer.append(bits: category, count: 5, into: &data)
                if category > 0, category < 16 {
                    // Category 16 (difference -32768) carries no magnitude bits.
                    let magnitude = difference >= 0
                        ? difference
                        : difference + (1 << category) - 1
                    writer.append(bits: magnitude, count: category, into: &data)
                }
            }
            mcuIndex += 1
        }
    }
    writer.flushWithOnePadding(into: &data)

    data.append(contentsOf: [0xFF, 0xD9]) // EOI
    return data
}

private func jpegLosslessTestPredictor(
    plane: [Int],
    x: Int,
    y: Int,
    width: Int,
    precision: Int,
    selectionValue: Int,
    intervalStartMCU: Int
) -> Int {
    guard selectionValue != 0 else { return 0 }
    let intervalStartY = intervalStartMCU / width
    let intervalStartX = intervalStartMCU % width
    if y == intervalStartY {
        if x == intervalStartX { return 1 << (precision - 1) }
        return plane[y * width + (x - 1)]
    }
    if x == 0 { return plane[(y - 1) * width] }
    let ra = plane[y * width + (x - 1)]
    let rb = plane[(y - 1) * width + x]
    let rc = plane[(y - 1) * width + (x - 1)]
    switch selectionValue {
    case 1: return ra
    case 2: return rb
    case 3: return rc
    case 4: return ra + rb - rc
    case 5: return ra + ((rb - rc) >> 1)
    case 6: return rb + ((ra - rc) >> 1)
    case 7: return (ra + rb) / 2
    default: return ra
    }
}

private func jpegLosslessMagnitudeCategory(of value: Int) -> Int {
    var magnitude = abs(value)
    var category = 0
    while magnitude > 0 {
        magnitude >>= 1
        category += 1
    }
    return category
}

/// Big-endian bit writer with JPEG 0xFF byte stuffing.
private struct JPEGLosslessTestBitWriter {
    private var currentByte: UInt8 = 0
    private var bitCount = 0

    mutating func append(bits value: Int, count: Int, into data: inout Data) {
        for shift in stride(from: count - 1, through: 0, by: -1) {
            currentByte = (currentByte << 1) | UInt8((value >> shift) & 1)
            bitCount += 1
            if bitCount == 8 {
                emit(into: &data)
            }
        }
    }

    mutating func flushWithOnePadding(into data: inout Data) {
        while bitCount != 0 {
            currentByte = (currentByte << 1) | 1
            bitCount += 1
            if bitCount == 8 {
                emit(into: &data)
            }
        }
    }

    private mutating func emit(into data: inout Data) {
        data.append(currentByte)
        if currentByte == 0xFF {
            data.append(0x00)
        }
        currentByte = 0
        bitCount = 0
    }
}

private extension Data {
    /// Appends a 16-bit unsigned integer to the data in big-endian (most-significant byte first) order.
    /// - Parameter value: The `UInt16` value to append as two bytes, most significant byte first.
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }
}
