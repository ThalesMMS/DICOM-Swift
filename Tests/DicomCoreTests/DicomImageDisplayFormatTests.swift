//
//  DicomImageDisplayFormatTests.swift
//  DicomCoreTests
//
//  The Image Display Format families, strictly (issue #1907).
//

import XCTest
@testable import DicomCore

final class DicomImageDisplayFormatTests: XCTestCase {

    // MARK: - Round trips

    func test_everyFamilyParsesAndRoundTripsToItsWireValue() throws {
        let wireValues = [
            "STANDARD\\2,3",
            "ROW\\1,3,2",
            "COL\\4,2",
            "SLIDE",
            "SUPERSLIDE",
            "CUSTOM\\VENDOR_FORMAT_7"
        ]
        for wire in wireValues {
            let parsed = try DicomImageDisplayFormat(wireValue: wire)
            XCTAssertEqual(parsed.wireValue, wire, "\(wire) must round-trip unchanged")
        }
    }

    func test_paddedWireValueParsesAndSerializesCanonically() throws {
        // DICOM string values may carry even-length padding.
        let parsed = try DicomImageDisplayFormat(wireValue: "STANDARD\\2,3 ")
        XCTAssertEqual(parsed, .standard(columns: 2, rows: 3))
        XCTAssertEqual(parsed.wireValue, "STANDARD\\2,3")
    }

    // MARK: - Capacity

    func test_standardCapacityIsTheGridProduct() throws {
        XCTAssertEqual(try DicomImageDisplayFormat(wireValue: "STANDARD\\4,5").imageBoxCapacity, 20)
    }

    /// `ROW\1,3,2` is one, three, then two images — six boxes in three
    /// non-uniform bands, not a 3×3 grid with holes.
    func test_rowAndColKeepTheirBandsAndSumTheirCapacity() throws {
        let row = try DicomImageDisplayFormat(wireValue: "ROW\\1,3,2")
        XCTAssertEqual(row, .row(imagesPerRow: [1, 3, 2]))
        XCTAssertEqual(row.imageBoxCapacity, 6)

        let col = try DicomImageDisplayFormat(wireValue: "COL\\4,2")
        XCTAssertEqual(col, .col(imagesPerColumn: [4, 2]))
        XCTAssertEqual(col.imageBoxCapacity, 6)
    }

    func test_validatedBandFactories_applyTheWireParserLimitsToProgrammaticValues() throws {
        XCTAssertEqual(
            try DicomImageDisplayFormat.validatedRow(imagesPerRow: [1, 3, 2]),
            .row(imagesPerRow: [1, 3, 2])
        )
        XCTAssertEqual(
            try DicomImageDisplayFormat.validatedCol(imagesPerColumn: [4, 2]),
            .col(imagesPerColumn: [4, 2])
        )

        XCTAssertThrowsError(try DicomImageDisplayFormat.validatedRow(imagesPerRow: []))
        XCTAssertThrowsError(try DicomImageDisplayFormat.validatedRow(imagesPerRow: [0, 1]))
        XCTAssertThrowsError(try DicomImageDisplayFormat.validatedCol(imagesPerColumn: [101]))
    }

    func test_printerDefinedFamiliesHaveNoComputableCapacity() throws {
        XCTAssertNil(try DicomImageDisplayFormat(wireValue: "SLIDE").imageBoxCapacity)
        XCTAssertNil(try DicomImageDisplayFormat(wireValue: "SUPERSLIDE").imageBoxCapacity)
        XCTAssertNil(try DicomImageDisplayFormat(wireValue: "CUSTOM\\X1").imageBoxCapacity)
    }

    func test_capacityOfDirectlyConstructedInvalidValuesIsNilNotACrash() {
        XCTAssertNil(DicomImageDisplayFormat.row(imagesPerRow: [Int.max, Int.max]).imageBoxCapacity)
        XCTAssertNil(DicomImageDisplayFormat.standard(columns: Int.max, rows: 2).imageBoxCapacity)
        XCTAssertNil(DicomImageDisplayFormat.row(imagesPerRow: []).imageBoxCapacity)
        XCTAssertNil(DicomImageDisplayFormat.standard(columns: 0, rows: 3).imageBoxCapacity)
    }

    // MARK: - Refusals the issue names

    func test_rowWithANonNumericTokenIsRefusedWholeNotQuietlyShortened() {
        // The permissive reference implementation compactMaps "ROW\1,x,2"
        // into "ROW\1,2" — a different film.
        XCTAssertThrowsError(try DicomImageDisplayFormat(wireValue: "ROW\\1,x,2")) { error in
            XCTAssertEqual(error as? DicomImageDisplayFormatError, .invalidToken("x"))
        }
    }

    func test_extraSegmentsAreJunkNotIgnored() {
        XCTAssertThrowsError(try DicomImageDisplayFormat(wireValue: "STANDARD\\2,2\\extra")) { error in
            XCTAssertEqual(error as? DicomImageDisplayFormatError,
                           .invalidSegmentCount(family: "STANDARD", expected: 2, found: 3))
        }
    }

    func test_slideWithAPayloadIsRefused() {
        XCTAssertThrowsError(try DicomImageDisplayFormat(wireValue: "SLIDE\\junk")) { error in
            XCTAssertEqual(error as? DicomImageDisplayFormatError,
                           .invalidSegmentCount(family: "SLIDE", expected: 1, found: 2))
        }
    }

    func test_customWithoutAnIdentifierIsRefused() {
        XCTAssertThrowsError(try DicomImageDisplayFormat(wireValue: "CUSTOM\\")) { error in
            XCTAssertEqual(error as? DicomImageDisplayFormatError, .emptyCustomIdentifier)
        }
    }

    // MARK: - Other refusals

    func test_emptyTokensAndWrongArity() {
        XCTAssertThrowsError(try DicomImageDisplayFormat(wireValue: "ROW\\1,,2"))
        XCTAssertThrowsError(try DicomImageDisplayFormat(wireValue: "STANDARD\\2"))
        XCTAssertThrowsError(try DicomImageDisplayFormat(wireValue: "STANDARD\\2,3,4"))
        XCTAssertThrowsError(try DicomImageDisplayFormat(wireValue: "STANDARD"))
        XCTAssertThrowsError(try DicomImageDisplayFormat(wireValue: ""))
        XCTAssertThrowsError(try DicomImageDisplayFormat(wireValue: "   "))
    }

    func test_zeroNegativeOverflowAndExcessiveDimensionsAreRefused() {
        XCTAssertThrowsError(try DicomImageDisplayFormat(wireValue: "STANDARD\\0,3")) { error in
            XCTAssertEqual(error as? DicomImageDisplayFormatError, .nonPositiveDimension(0))
        }
        XCTAssertThrowsError(try DicomImageDisplayFormat(wireValue: "ROW\\1,-2"))
        XCTAssertThrowsError(try DicomImageDisplayFormat(wireValue: "STANDARD\\101,1")) { error in
            XCTAssertEqual(error as? DicomImageDisplayFormatError, .excessiveCapacity)
        }
        XCTAssertThrowsError(try DicomImageDisplayFormat(
            wireValue: "STANDARD\\9999999999999999999,9999999999999999999"))
        XCTAssertThrowsError(try DicomImageDisplayFormat(wireValue: "ROW\\101"))
    }

    func test_unknownAndLowercaseFamiliesAreRefused() {
        XCTAssertThrowsError(try DicomImageDisplayFormat(wireValue: "BOGUS\\1,1")) { error in
            XCTAssertEqual(error as? DicomImageDisplayFormatError, .unknownFamily("BOGUS"))
        }
        // Defined terms are uppercase; "standard" is not a defined term.
        XCTAssertThrowsError(try DicomImageDisplayFormat(wireValue: "standard\\2,2"))
    }

    // MARK: - Film box integration

    func test_filmBoxExposesTheTypedFormatAndTheTypedInitStoresCanonicalWire() throws {
        let typed = DicomFilmBox(displayFormat: .row(imagesPerRow: [2, 1]))
        XCTAssertEqual(typed.imageDisplayFormat, "ROW\\2,1")
        XCTAssertEqual(typed.typedImageDisplayFormat, .row(imagesPerRow: [2, 1]))

        let stringly = DicomFilmBox(imageDisplayFormat: "ROW\\1,x,2")
        XCTAssertNil(stringly.typedImageDisplayFormat, "an invalid stored string types as nil")
    }

    // MARK: - The SCU is bounded by the typed count

    private func bitmap() throws -> DicomRenderedBitmap {
        try DicomRenderedBitmap(width: 2, height: 2, rgbData: Data(repeating: 0x20, count: 12))
    }

    func test_printJobRefusesMoreImagesThanTheTypedLayoutHolds() throws {
        let boxes = try (1...5).map { try DicomImageBox(position: $0, bitmap: bitmap()) }
        XCTAssertThrowsError(try DicomPrintJob(
            filmSession: DicomFilmSession(),
            filmBox: DicomFilmBox(displayFormat: .standard(columns: 2, rows: 2)),
            imageBoxes: boxes
        )) { error in
            XCTAssertEqual(error as? DicomPrintManagementError,
                           .imageCountExceedsLayout(imageCount: 5, capacity: 4))
        }
    }

    func test_printJobRefusesAPositionBeyondTheLastSlot() throws {
        let box = try DicomImageBox(position: 7, bitmap: bitmap())
        XCTAssertThrowsError(try DicomPrintJob(
            filmSession: DicomFilmSession(),
            filmBox: DicomFilmBox(displayFormat: .row(imagesPerRow: [1, 3, 2])),
            imageBoxes: [box]
        )) { error in
            XCTAssertEqual(error as? DicomPrintManagementError, .invalidImagePosition(7))
        }
    }

    func test_printJobAcceptsAFullTypedLayoutAndPrinterDefinedFamilies() throws {
        let boxes = try (1...6).map { try DicomImageBox(position: $0, bitmap: bitmap()) }
        XCTAssertNoThrow(try DicomPrintJob(
            filmSession: DicomFilmSession(),
            filmBox: DicomFilmBox(displayFormat: .row(imagesPerRow: [1, 3, 2])),
            imageBoxes: boxes
        ))
        // Printer-defined families require an explicit capacity.
        for format: DicomImageDisplayFormat in [.slide, .superslide, .custom(identifier: "X1")] {
            var filmBox = DicomFilmBox(displayFormat: format)
            filmBox.expectedImageBoxCount = boxes.count
            XCTAssertNoThrow(try DicomPrintJob(
                filmSession: DicomFilmSession(),
                filmBox: filmBox,
                imageBoxes: boxes
            ))
        }
        XCTAssertThrowsError(try DicomPrintJob(
            filmSession: DicomFilmSession(),
            filmBox: DicomFilmBox(displayFormat: .slide),
            imageBoxes: boxes
        )) { error in
            XCTAssertEqual(error as? DicomPrintManagementError, .expectedImageBoxCountRequired)
        }
    }
}
