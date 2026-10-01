import CoreMedia
import DicomAppleMedia
import Foundation
import XCTest

final class DicomH264ElementaryStreamBuilderTests: XCTestCase {
    func test_builder_prefixesParameterSetsAndConvertsMultipleNALUnitsByteForByte() throws {
        let nalUnits = [
            Data([0x65, 0x88, 0x84]),
            Data([0x06, 0x05])
        ]
        let expected = Self.annexB(Self.sps) + Self.annexB(Self.pps)
            + nalUnits.reduce(into: Data()) { $0.append(Self.annexB($1)) }

        for headerLength in [1, 2, 4] {
            let description = try makeFormatDescription(nalUnitHeaderLength: headerLength)
            var builder = try DicomH264ElementaryStreamBuilder(formatDescription: description)

            try builder.append(lengthPrefixedSample: lengthPrefixedSample(
                nalUnits,
                headerLength: headerLength
            ))

            XCTAssertEqual(builder.data, expected, "NAL header length \(headerLength)")
        }
    }

    func test_builder_rejectsZeroLengthNALWithoutMutatingAccumulatedData() throws {
        var builder = try DicomH264ElementaryStreamBuilder(
            formatDescription: makeFormatDescription(nalUnitHeaderLength: 4)
        )
        let original = builder.data

        XCTAssertThrowsError(try builder.append(lengthPrefixedSample: Data([0, 0, 0, 0]))) { error in
            XCTAssertEqual(error as? DicomH264ElementaryStreamError, .zeroLengthNALUnit)
        }
        XCTAssertEqual(builder.data, original)
    }

    func test_builder_rejectsTruncatedNALWithoutMutatingAccumulatedData() throws {
        var builder = try DicomH264ElementaryStreamBuilder(
            formatDescription: makeFormatDescription(nalUnitHeaderLength: 4)
        )
        let original = builder.data

        XCTAssertThrowsError(
            try builder.append(lengthPrefixedSample: Data([0, 0, 0, 4, 0x65]))
        ) { error in
            XCTAssertEqual(
                error as? DicomH264ElementaryStreamError,
                .truncatedNALUnit(declaredLength: 4, availableBytes: 1)
            )
        }
        XCTAssertEqual(builder.data, original)
    }

    func test_builder_rejectsResidualLengthPrefixWithoutMutatingAccumulatedData() throws {
        var builder = try DicomH264ElementaryStreamBuilder(
            formatDescription: makeFormatDescription(nalUnitHeaderLength: 4)
        )
        let original = builder.data
        var sample = lengthPrefixedSample([Data([0x65, 0x88])], headerLength: 4)
        sample.append(contentsOf: [0, 0])

        XCTAssertThrowsError(try builder.append(lengthPrefixedSample: sample)) { error in
            XCTAssertEqual(
                error as? DicomH264ElementaryStreamError,
                .trailingLengthPrefix(byteCount: 2)
            )
        }
        XCTAssertEqual(builder.data, original)
    }

    func test_builder_convertsDataSliceWithNonzeroStartIndex() throws {
        var storage = Data([0xFF])
        storage.append(lengthPrefixedSample([Data([0x65, 0x88])], headerLength: 4))
        let sample = storage.dropFirst()
        XCTAssertGreaterThan(sample.startIndex, 0)

        var builder = try DicomH264ElementaryStreamBuilder(
            formatDescription: makeFormatDescription(nalUnitHeaderLength: 4)
        )
        try builder.append(lengthPrefixedSample: sample)

        XCTAssertEqual(
            builder.data,
            Self.annexB(Self.sps) + Self.annexB(Self.pps) + Self.annexB(Data([0x65, 0x88]))
        )
    }

    func test_append_whenAnnexBExpansionExceedsLimit_throwsWithoutMutatingData() throws {
        var builder = try DicomH264ElementaryStreamBuilder(
            formatDescription: makeFormatDescription(nalUnitHeaderLength: 1)
        )
        let original = builder.data
        let sample = lengthPrefixedSample([Data([0x65])], headerLength: 1)

        XCTAssertThrowsError(
            try builder.append(lengthPrefixedSample: sample, maximumOutputBytes: original.count + 4)
        ) { error in
            XCTAssertEqual(
                error as? DicomH264ElementaryStreamError,
                .outputLimitExceeded(limit: original.count + 4)
            )
        }
        XCTAssertEqual(builder.data, original)
    }

    private func makeFormatDescription(nalUnitHeaderLength: Int) throws -> CMVideoFormatDescription {
        var description: CMFormatDescription?
        let status = Self.sps.withUnsafeBytes { spsBytes in
            Self.pps.withUnsafeBytes { ppsBytes in
                guard let spsBase = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                var pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                var sizes = [Self.sps.count, Self.pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: Int32(nalUnitHeaderLength),
                    formatDescriptionOut: &description
                )
            }
        }
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(description)
    }

    private func lengthPrefixedSample(_ nalUnits: [Data], headerLength: Int) -> Data {
        nalUnits.reduce(into: Data()) { sample, nalUnit in
            let length = UInt32(nalUnit.count)
            for shift in stride(from: (headerLength - 1) * 8, through: 0, by: -8) {
                sample.append(UInt8((length >> UInt32(shift)) & 0xFF))
            }
            sample.append(nalUnit)
        }
    }

    private static func annexB(_ nalUnit: Data) -> Data {
        Data([0, 0, 0, 1]) + nalUnit
    }

    // Extracted from the deterministic H.264 fixture used by DicomVideoRemuxerTests.
    private static let sps = Data([
        0x67, 0x42, 0xC0, 0x0A, 0xDD, 0xEC, 0x04, 0x40,
        0x00, 0x00, 0x03, 0x00, 0x40, 0x00, 0x00, 0x03,
        0x01, 0x23, 0xC4, 0x89, 0xE0
    ])

    private static let pps = Data([0x68, 0xCE, 0x0F, 0x2C, 0x80])
}
