import XCTest
@testable import DicomCore

final class DicomSegmentedPaletteExpanderTests: XCTestCase {
    func test_discreteSegment_expandsEntries() throws {
        XCTAssertEqual(try DicomSegmentedPaletteExpander.expand(words: [0, 3, 0, 127, 255], entryCount: 3),
                       [0, 127, 255])
    }

    func test_linearSegments_interpolateAscendingAndDescendingEntries() throws {
        XCTAssertEqual(try DicomSegmentedPaletteExpander.expand(
            words: [0, 1, 0, 1, 3, 255, 1, 3, 0], entryCount: 7), [0, 85, 170, 255, 170, 85, 0])
    }

    func test_indirectSegment_copiesSpecifiedSegments() throws {
        XCTAssertEqual(try DicomSegmentedPaletteExpander.expand(
            words: [0, 1, 7, 0, 2, 10, 20, 2, 1, 6, 0], entryCount: 5), [7, 10, 20, 10, 20])
    }

    func test_indirectSegment_rejectsOddAndOutOfRangeByteOffsetsAndCycles() {
        for offset: UInt16 in [1, 8, 10] {
            XCTAssertThrowsError(try DicomSegmentedPaletteExpander.expand(
                words: [2, 1, offset, 0], entryCount: 1)) {
                XCTAssertEqual($0 as? DicomSegmentedPaletteExpander.ExpansionError, .invalidOffset)
            }
        }
        for words: [UInt16] in [[2, 1, 0, 0], [2, 1, 8, 0, 2, 1, 0, 0]] {
            XCTAssertThrowsError(try DicomSegmentedPaletteExpander.expand(words: words, entryCount: 2)) {
                XCTAssertEqual($0 as? DicomSegmentedPaletteExpander.ExpansionError, .invalidOffset)
            }
        }
    }

    func test_indirectSegment_rejectsPayloadOffsetsAndIndirectChains() {
        let payloadOffset: [UInt16] = [0, 4, 0, 1, 7, 9, 2, 1, 4, 0]
        let indirectChain: [UInt16] = [0, 1, 7, 2, 1, 0, 0, 2, 1, 6, 0]
        let copiedIndirect: [UInt16] = [0, 1, 7, 2, 1, 0, 0, 2, 2, 0, 0]
        for words in [payloadOffset, indirectChain, copiedIndirect] {
            XCTAssertThrowsError(try DicomSegmentedPaletteExpander.expand(words: words, entryCount: 20)) {
                XCTAssertEqual($0 as? DicomSegmentedPaletteExpander.ExpansionError, .invalidOffset)
            }
        }
    }

    func test_malformedSegments_throw() {
        for words: [UInt16] in [[0], [0, 2, 1], [1, 1, 2], [0, 0], [3, 1, 0],
                                [2, 1, 0, 0], [2, 1, 100, 0], [2, 1, 0], [0, 2, 1, 2]] {
            XCTAssertThrowsError(try DicomSegmentedPaletteExpander.expand(words: words, entryCount: 1), "\(words)")
        }
        XCTAssertThrowsError(try DicomSegmentedPaletteExpander.expand(words: [0, 1, 7], entryCount: 2))
    }

    func test_excessSegments_rejectsBeforeScanningMalformedTail() {
        XCTAssertThrowsError(try DicomSegmentedPaletteExpander.expand(
            words: [0, 1, 7, 0, 1, 8, 3, 1, 0], entryCount: 1
        )) {
            XCTAssertEqual($0 as? DicomSegmentedPaletteExpander.ExpansionError, .entryCountMismatch)
        }
    }
}
