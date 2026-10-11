import Foundation
import XCTest
@testable import DicomData

/// Issue #3039: recovery ends the root data set where a complete Pixel Data value ends when the bytes that follow do not
/// parse as data elements. Everything else stays a refusal. The wire bytes are hand-encoded (PS3.5 7.1.2), so the
/// expected offsets are counted from the encoding, not from the parser.
final class DicomTrailingBytesRecoveryTests: XCTestCase {
    private let metadata = DicomTrailingBytesRecoveryTests.short(0x00100020, "LO", Array("ID01".utf8))
        + DicomTrailingBytesRecoveryTests.short(0x00280010, "US", [4, 0])

    func test_bytesAfterCompleteNativePixelData_endTheDataSetWithADiagnostic() throws {
        let pixelData = Self.long(0x7FE00010, "OW", length: 8, Array(repeating: 7, count: 8))
        // A rewritten file's leftover: zeros, then 16-bit samples (`\0@` is no VR).
        let wire = metadata + pixelData + Data(count: 6) + Data([0x40, 0x00, 0x3B, 0x00, 0x36, 0x00])
        XCTAssertThrowsError(try DicomDataSetParser.read(from: wire))
        XCTAssertThrowsError(try DicomDataSetParser.dataSet(from: wire))

        let recovered = try DicomDataSetParser.read(from: wire, mode: .recover)
        XCTAssertEqual(recovered.dataSet.string(for: 0x00100020), "ID01")
        XCTAssertEqual(recovered.dataSet[0x00280010]?.value, .unsignedIntegers([4]))
        XCTAssertNil(recovered.dataSet[0x7FE00010], "Pixel Data stays skipped")
        let pixelEnd = metadata.count + pixelData.count
        XCTAssertEqual(recovered.diagnostics, [.init(tag: 0x7FE00010, offset: pixelEnd, reason: .trailingBytesAfterPixelData,
                                                     path: [.tag(0x7FE00010)])])
        XCTAssertEqual(recovered.pixelDataHeader?.valueLength, 8)
        XCTAssertEqual(recovered.pixelDataHeader?.valueOffset, metadata.count + 12)
    }

    func test_bytesAfterEncapsulatedPixelData_endTheDataSetWithADiagnostic() throws {
        let fragments = Self.item([]) + Self.item([0xFF, 0xD8, 0xFF, 0xD9]) + Self.tagHeader(0xFFFEE0DD, length: 0)
        let pixelData = Self.long(0x7FE00010, "OB", length: UInt32.max, Array(fragments))
        let wire = metadata + pixelData + Data([0xDE, 0xAD, 0xBE, 0xEF, 0xDE, 0xAD, 0xBE, 0xEF])
        let recovered = try DicomDataSetParser.read(from: wire, mode: .recover)
        XCTAssertEqual(recovered.dataSet.string(for: 0x00100020), "ID01")
        XCTAssertEqual(recovered.diagnostics.map(\.reason), [.trailingBytesAfterPixelData])
        XCTAssertEqual(recovered.diagnostics.first?.offset, metadata.count + pixelData.count)
        XCTAssertEqual(recovered.pixelDataHeader?.valueLength, UInt32.max)
    }

    func test_leftoverBytesThatParseIntoConflictingElements_endTheDataSet() throws {
        let pixelData = Self.long(0x7FE00010, "OW", length: 8, Array(repeating: 7, count: 8))
        // Zeroed leftovers read as the same element twice, which no data set can hold.
        let leftover = Self.long(0xFFFCFFFC, "OB", length: 2, [0, 0]) + Self.long(0xFFFCFFFC, "OB", length: 2, [0, 0])
        XCTAssertThrowsError(try DicomDataSetParser.read(from: metadata + pixelData + leftover))
        let recovered = try DicomDataSetParser.read(from: metadata + pixelData + leftover, mode: .recover)
        XCTAssertEqual(recovered.diagnostics.map(\.reason), [.trailingBytesAfterPixelData])
        XCTAssertEqual(recovered.diagnostics.first?.offset, metadata.count + pixelData.count)
    }

    func test_implicitVRBytesAfterPixelData_whoseLengthLeavesTheFile_endTheDataSet() throws {
        let metadata = Self.implicit(0x00100020, Array("ID01".utf8))
        let pixelData = Self.implicit(0x7FE00010, Array(repeating: 1, count: 8))
        // Leftover samples read as a tag and a length far beyond the file.
        let wire = metadata + pixelData + Data([0x00, 0x00, 0x00, 0x00, 0x6D, 0x00, 0x68, 0x00, 0x66, 0x00])
        XCTAssertThrowsError(try DicomDataSetParser.read(from: wire, transferSyntax: .implicitVRLittleEndian))
        let recovered = try DicomDataSetParser.read(from: wire, transferSyntax: .implicitVRLittleEndian, mode: .recover)
        XCTAssertEqual(recovered.dataSet.string(for: 0x00100020), "ID01")
        XCTAssertEqual(recovered.diagnostics.first?.offset, metadata.count + pixelData.count)
    }

    func test_incompletePixelData_staysARefusal() throws {
        let fragments = Self.item([]) + Self.item([0xFF, 0xD8, 0xFF, 0xD9])
        let cases: [Data] = [
            // a native value longer than the file
            metadata + Self.long(0x7FE00010, "OW", length: 64, Array(repeating: 7, count: 8)),
            // a fragment longer than the file
            metadata + Self.long(0x7FE00010, "OB", length: UInt32.max, Array(Self.item([]) + Self.tagHeader(0xFFFEE000, length: 64))),
            // no sequence delimiter
            metadata + Self.long(0x7FE00010, "OB", length: UInt32.max, Array(fragments))
        ]
        for wire in cases {
            XCTAssertThrowsError(try DicomDataSetParser.read(from: wire, mode: .recover)) { error in
                XCTAssertTrue(error is DicomSequenceValueParserError, "\(error)")
            }
        }
    }

    func test_corruptionBeforeOrWithoutRootPixelData_staysARefusal() throws {
        let garbage = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x3B, 0x00])
        let pixelData = Self.long(0x7FE00010, "OW", length: 8, Array(repeating: 7, count: 8))
        // An icon's Pixel Data inside a sequence item does not end the root data set.
        let icon = Self.long(0x00880200, "SQ", length: UInt32.max,
                             Array(Self.tagHeader(0xFFFEE000, length: UInt32.max) + pixelData
                                   + Self.tagHeader(0xFFFEE00D, length: 0) + Self.tagHeader(0xFFFEE0DD, length: 0)))
        for wire in [metadata + garbage + pixelData, metadata + icon + garbage] {
            XCTAssertThrowsError(try DicomDataSetParser.read(from: wire, mode: .recover))
        }
        // A spent diagnostic budget after Pixel Data is still a refusal, not trailing bytes.
        let padding = Self.long(0xFFFCFFFC, "OF", length: 4, [0, 0, 0, 0])
        XCTAssertThrowsError(try DicomDataSetParser.read(from: metadata + pixelData + padding, mode: .recover,
                                                         maximumDiagnostics: 0)) { error in
            XCTAssertEqual((error as? DicomDataSetReadResult.Diagnostic)?.reason, .incompatibleVR)
        }
        let within = try DicomDataSetParser.read(from: metadata + pixelData + padding, mode: .recover, maximumDiagnostics: 1)
        XCTAssertEqual(within.diagnostics.map(\.reason), [.incompatibleVR], "a padding element that parses is kept")
    }

    func test_limitsDiagnosticBudgetAndCancellation_stayEffective() async throws {
        let pixelData = Self.long(0x7FE00010, "OW", length: 8, Array(repeating: 7, count: 8))
        let wire = metadata + pixelData + Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x3B, 0x00])
        // Three elements fit; the trailing header is the fourth, which the budget refuses rather than recovery.
        let limits = DicomDataSetParseLimits(maximumSequenceDepth: 4, maximumElementCount: 3, maximumItemCount: 4)
        XCTAssertThrowsError(try DicomDataSetParser.read(from: wire, mode: .recover, limits: limits)) { error in
            XCTAssertEqual(error as? DicomDataSetParseError, .maximumElementCountExceeded(limit: 3))
        }
        XCTAssertThrowsError(try DicomDataSetParser.read(from: wire, mode: .recover, maximumDiagnostics: 0)) { error in
            XCTAssertEqual((error as? DicomDataSetReadResult.Diagnostic)?.reason, .trailingBytesAfterPixelData)
        }
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try DicomDataSetParser.read(from: wire, mode: .recover)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled read returned")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func test_startingAt_parsesInPlaceWithOffsetsIntoTheWholeBuffer() throws {
        let prefix = Data(repeating: 0x55, count: 132)
        let pixelData = Self.long(0x7FE00010, "OW", length: 8, Array(repeating: 7, count: 8))
        let wire = prefix + metadata + pixelData + Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x3B, 0x00])
        let recovered = try DicomDataSetParser.read(from: wire, startingAt: prefix.count, mode: .recover)
        XCTAssertEqual(recovered.dataSet.string(for: 0x00100020), "ID01")
        XCTAssertEqual(recovered.diagnostics.first?.offset, prefix.count + metadata.count + pixelData.count)
        XCTAssertEqual(recovered.pixelDataHeader?.valueOffset, prefix.count + metadata.count + 12)
        let clean = try DicomDataSetParser.read(from: prefix + metadata + pixelData, startingAt: prefix.count)
        XCTAssertTrue(clean.diagnostics.isEmpty)
        XCTAssertEqual(clean.dataSet.string(for: 0x00100020), "ID01")
    }

    // MARK: - Explicit and implicit VR Little Endian encoding (PS3.5 7.1.2, 7.1.3)

    private static func tagHeader(_ tag: UInt32, length: UInt32) -> Data {
        var data = Data()
        for value in [UInt16(truncatingIfNeeded: tag >> 16), UInt16(truncatingIfNeeded: tag)] {
            data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
        }
        data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: length >> (8 * $0)) })
        return data
    }

    private static func item(_ bytes: [UInt8]) -> Data {
        tagHeader(0xFFFEE000, length: UInt32(bytes.count)) + Data(bytes)
    }

    private static func short(_ tag: UInt32, _ vr: String, _ bytes: [UInt8]) -> Data {
        var data = tagHeader(tag, length: 0).prefix(4)
        data.append(contentsOf: vr.utf8)
        data.append(contentsOf: [UInt8(bytes.count & 0xFF), UInt8(bytes.count >> 8)])
        return data + Data(bytes)
    }

    private static func long(_ tag: UInt32, _ vr: String, length: UInt32, _ bytes: [UInt8]) -> Data {
        var data = tagHeader(tag, length: 0).prefix(4)
        data.append(contentsOf: vr.utf8)
        data.append(contentsOf: [0, 0])
        data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: length >> (8 * $0)) })
        return data + Data(bytes)
    }

    private static func implicit(_ tag: UInt32, _ bytes: [UInt8]) -> Data {
        tagHeader(tag, length: UInt32(bytes.count)) + Data(bytes)
    }
}
