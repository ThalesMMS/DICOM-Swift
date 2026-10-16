@testable import DicomJPEG2000
import Foundation
import XCTest

/// The C EBCOT block decoder (#3078) against the Swift decoder it replaces in the pipeline: same coefficients, or the
/// same error, for encoded blocks and for arbitrary bytes, across block shapes, subbands, code-block styles, pass
/// truncations, segment layouts, 5/3 and 9/7 scales and the entropy-integrity check.
final class J2KBitPlaneNativeDecodingTests: XCTestCase {
    private struct Generator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }

        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func flag() -> Bool { next() & 1 == 1 }
    }

    private static let shapes = [(64, 64), (37, 13), (4, 4), (1, 7), (32, 3), (16, 64), (5, 9)]
    private static let subbands: [J2KSubband] = [.ll, .hl, .lh, .hh]

    func test_encodedBlocks_decodeAlikeAcrossShapesStylesAndTruncations() throws {
        var random = Generator(state: 3078)
        var compared = 0
        for (width, height) in Self.shapes {
            for subband in Self.subbands {
                for encoderStyle in 0..<3 {
                    let encoderOptions: CodingOptions
                    switch encoderStyle {
                    case 0: encoderOptions = .default
                    case 1: encoderOptions = CodingOptions(terminationMode: .predictable)
                    default: encoderOptions = CodingOptions(bypassEnabled: true, terminationMode: .predictable)
                    }
                    let density = 5 + random.below(90)
                    let magnitude = 1 + random.below(1 << (1 + random.below(14)))
                    let source: [Int32] = (0..<(width * height)).map { _ in
                        guard random.below(100) < density else { return 0 }
                        let value = Int32(1 + random.below(magnitude))
                        return random.flag() ? value : -value
                    }
                    let encoded = try BitPlaneCoder(width: width, height: height, subband: subband, options: encoderOptions)
                        .encode(coefficients: source, bitDepth: 16)
                    for passCount in Set([encoded.passCount, max(1, encoded.passCount / 2), 1, encoded.passCount - 1])
                    where passCount > 0 {
                        let options = CodingOptions(
                            bypassEnabled: encoderOptions.bypassEnabled,
                            terminationMode: encoderOptions.terminationMode,
                            checksEntropyIntegrity: passCount == encoded.passCount)
                        let lengths = encoderOptions.terminationMode == .predictable
                            ? Array(encoded.passSegmentLengths.prefix(passCount)) : []
                        try assertAlike(
                            width: width, height: height, subband: subband, options: options, data: encoded.data,
                            passCount: passCount, bitDepth: 16, zeroBitPlanes: encoded.zeroBitPlanes,
                            lengths: lengths, irreversible: false,
                            label: "\(width)x\(height) \(subband) style \(encoderStyle) passes \(passCount)")
                        compared += 1
                    }
                    if encoderStyle == 0 {
                        XCTAssertEqual(try BitPlaneDecoder(width: width, height: height, subband: subband)
                            .decode(data: encoded.data, passCount: encoded.passCount, bitDepth: 16,
                                    zeroBitPlanes: encoded.zeroBitPlanes), source, "\(width)x\(height) \(subband) round trip")
                    }
                }
            }
        }
        XCTAssertGreaterThan(compared, 200)
    }

    func test_arbitraryBytes_decodeAlikeUnderEveryDecodeOption() throws {
        var random = Generator(state: 1_203)
        for round in 0..<600 {
            let (width, height) = Self.shapes[random.below(Self.shapes.count)]
            let subband = Self.subbands[random.below(Self.subbands.count)]
            let data = Data((0..<random.below(400)).map { _ in
                // Plenty of 0xFF, so stuffing and markers inside segments are exercised.
                random.below(6) == 0 ? 0xFF : UInt8(truncatingIfNeeded: random.next())
            })
            let bitDepth = 1 + random.below(20)
            let zeroBitPlanes = random.below(bitDepth + 1)
            let passCount = 1 + random.below(3 * max(1, bitDepth - zeroBitPlanes) + 2)
            var lengths: [Int] = []
            if random.flag() {
                var left = data.count
                for _ in 0..<(1 + random.below(passCount + 2)) {
                    let length = left == 0 ? 0 : random.below(left + 1)
                    lengths.append(length)
                    left -= length
                }
            }
            let options = CodingOptions(
                bypassEnabled: random.flag(),
                terminationMode: random.below(4) == 0 ? .predictable : .default,
                resetContextOnEachPass: random.flag(),
                terminateOnEachPass: random.flag(),
                verticallyCausalContext: random.flag(),
                segmentationSymbols: random.below(4) == 0,
                checksEntropyIntegrity: random.flag())
            try assertAlike(
                width: width, height: height, subband: subband, options: options, data: data,
                passCount: passCount, bitDepth: bitDepth, zeroBitPlanes: zeroBitPlanes, lengths: lengths,
                irreversible: random.flag(), label: "round \(round)")
        }
    }

    func test_reusedScratch_decodesLikeFreshScratch() throws {
        var random = Generator(state: 91)
        let scratch = DecoderScratchBuffers()
        for (width, height) in Self.shapes + Self.shapes.reversed() {
            let source: [Int32] = (0..<(width * height)).map { _ in Int32(random.below(2001)) - 1000 }
            let encoded = try BitPlaneCoder(width: width, height: height, subband: .hh).encode(coefficients: source, bitDepth: 12)
            let decoder = BitPlaneDecoder(width: width, height: height, subband: .hh)
            XCTAssertEqual(try decoder.decode(data: encoded.data, passCount: encoded.passCount, bitDepth: 12,
                                              zeroBitPlanes: encoded.zeroBitPlanes, scratch: scratch),
                           source, "\(width)x\(height)")
        }
    }

    private func assertAlike(
        width: Int, height: Int, subband: J2KSubband, options: CodingOptions, data: Data, passCount: Int,
        bitDepth: Int, zeroBitPlanes: Int, lengths: [Int], irreversible: Bool, label: String
    ) throws {
        let decoder = BitPlaneDecoder(width: width, height: height, subband: subband, options: options)
        let native = Result {
            try decoder.decode(data: data, passCount: passCount, bitDepth: bitDepth, zeroBitPlanes: zeroBitPlanes,
                               passSegmentLengths: lengths, irreversible: irreversible)
        }
        let swift = Result {
            try decoder.decodeInSwift(data: data, passCount: passCount, bitDepth: bitDepth, zeroBitPlanes: zeroBitPlanes,
                                      passSegmentLengths: lengths, irreversible: irreversible)
        }
        switch (native, swift) {
        case let (.success(a), .success(b)):
            XCTAssertEqual(a, b, label)
        case let (.failure(a), .failure(b)):
            XCTAssertEqual(String(describing: a), String(describing: b), label)
        default:
            XCTFail("\(label): native \(native), Swift \(swift)")
        }
    }
}
