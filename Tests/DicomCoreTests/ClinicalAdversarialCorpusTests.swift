import Foundation
import XCTest
@testable import DicomCore

final class ClinicalAdversarialCorpusTests: XCTestCase {
    func test_rleRGB_rejectsSignedSamplesAndPreservesUnsignedSamples() throws {
        var frame = Data(repeating: 0, count: 64)
        frame[0] = 3
        frame[4] = 64
        frame[8] = 66
        frame[12] = 68
        frame.append(contentsOf: [0, 128, 0, 64, 0, 32])
        let decoded = try DicomRLELosslessDecoder.decode(
            frame: frame, width: 1, height: 1, bitsAllocated: 8, samplesPerPixel: 3,
            pixelRepresentation: 0, photometricInterpretation: "RGB"
        )
        XCTAssertEqual(decoded.pixels24, [128, 64, 32])
        XCTAssertThrowsError(try DicomRLELosslessDecoder.decode(
            frame: frame, width: 1, height: 1, bitsAllocated: 8, samplesPerPixel: 3,
            pixelRepresentation: 1, photometricInterpretation: "RGB"
        ))
    }

    func test_rleSliceOffset_preservesAllSamplesAfterOriginalBufferMutation() throws {
        let frame = literalFrame()
        var storage = Data(repeating: 0xA5, count: 97)
        storage.append(frame)
        let slice = storage.dropFirst(97)
        XCTAssertEqual(slice.startIndex, 97)
        let decoded = try decode(slice)
        storage.resetBytes(in: storage.startIndex..<storage.endIndex)
        XCTAssertEqual(decoded.pixels8, (0..<15).map { UInt8($0 * 7) })
    }

    func test_rleTruncationAtEveryByteAndHostileOffsets_throwInsteadOfReturningPartialPixels() {
        let frame = literalFrame()
        let width = 5
        // A segment cut short within its last row reads as GDCM reads it, the missing samples zero (issue
        // #2855); anything shorter throws.
        for length in 0..<frame.count {
            let missing = frame.count - length
            guard missing >= width else {
                let decoded = try? decode(Data(frame.prefix(length)))
                XCTAssertEqual(decoded?.pixels8, (0..<15).map { $0 < 15 - missing ? UInt8($0 * 7) : 0 },
                               "truncation=\(length)")
                continue
            }
            XCTAssertThrowsError(try decode(Data(frame.prefix(length))), "truncation=\(length)")
        }
        for offset: UInt32 in [0, 1, 63, UInt32(frame.count), .max] {
            var mutated = frame
            var little = offset.littleEndian
            mutated.replaceSubrange(4..<8, with: withUnsafeBytes(of: &little) { Data($0) })
            XCTAssertThrowsError(try decode(mutated), "offset=\(offset)")
        }
    }

    func test_rleHostileShape_rejectsBeforeArithmeticOrAllocation() {
        for bits in [Int.min, -1, 0, Int.max] {
            XCTAssertThrowsError(try decode(literalFrame(), bits: bits), "bits=\(bits)")
        }
        XCTAssertThrowsError(try DicomRLELosslessDecoder.decode(
            frame: literalFrame(), width: Int.max, height: Int.max, bitsAllocated: 16,
            samplesPerPixel: Int.max, pixelRepresentation: 0, photometricInterpretation: "MONOCHROME2"
        ))
    }

    func test_seededRLEMutations_boundEverySuccessfulDecodeAndRemainDeterministic() {
        var state: UInt64 = 2366
        let frame = literalFrame()
        var successes = 0
        var failures = 0
        for _ in 0..<256 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            var mutated = frame
            let position = Int(state % UInt64(mutated.count))
            mutated[position] ^= UInt8(truncatingIfNeeded: state >> 32) | 1
            do {
                let decoded = try decode(mutated)
                XCTAssertEqual(decoded.pixels8?.count, 15, "seed=2366 state=\(state)")
                successes += 1
            } catch let error as DICOMError {
                if case .invalidPixelData = error { failures += 1 }
                else { XCTFail("Unexpected error: \(error)") }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertGreaterThan(successes, 0)
        XCTAssertGreaterThan(failures, 0)
        XCTAssertEqual(successes + failures, 256)
    }

    func test_seededDatasetMutations_respectStructuralBudgetsAndTypedFailures() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/IndependentDifferential/gray8.dcm")
        let seed = Data(try Data(contentsOf: url).dropFirst(132))
        let limits = DicomDataSetParseLimits(maximumSequenceDepth: 8, maximumElementCount: 128, maximumItemCount: 64)
        var state: UInt64 = 2366001
        var accepted = 0
        var rejected = 0
        for iteration in 0..<512 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            var mutated = seed
            if iteration.isMultiple(of: 2) {
                mutated = Data(mutated.prefix(Int(state % UInt64(seed.count))))
            } else {
                mutated[Int(state % UInt64(seed.count))] ^= UInt8(truncatingIfNeeded: state >> 32) | 1
            }
            do {
                let parsed = try DicomDataSetParser.dataSet(from: mutated, limits: limits)
                XCTAssertLessThanOrEqual(parsed.count, 128, "seed=2366001 state=\(state)")
                accepted += 1
            } catch is DicomDataSetParseError {
                rejected += 1
            } catch is DicomSequenceValueParserError {
                rejected += 1
            } catch {
                XCTFail("Unexpected error for seed=2366001 state=\(state): \(error)")
            }
        }
        XCTAssertGreaterThan(accepted, 0)
        XCTAssertGreaterThan(rejected, 0)
        XCTAssertEqual(accepted + rejected, 512)
    }

    func test_cancelledDatasetParse_stopsBeforeReadingMalformedBytes() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DicomDataSetParser.dataSet(from: Data([0xFF]))
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled parser returned a dataset")
        } catch is CancellationError {}
    }

    private func literalFrame() -> Data {
        var words = [UInt32](repeating: 0, count: 16)
        words[0] = 1
        words[1] = 64
        var data = Data()
        for word in words {
            var little = word.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(14)
        data.append(contentsOf: (0..<15).map { UInt8($0 * 7) })
        return data
    }

    private func decode(_ data: Data, bits: Int = 8) throws -> DCMPixelReadResult {
        try DicomRLELosslessDecoder.decode(frame: data, width: 5, height: 3, bitsAllocated: bits,
                                          samplesPerPixel: 1, pixelRepresentation: 0,
                                          photometricInterpretation: "MONOCHROME2")
    }
}
