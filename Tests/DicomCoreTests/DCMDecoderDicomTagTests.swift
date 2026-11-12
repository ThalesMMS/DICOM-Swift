//
//  DCMDecoderDicomTagTests.swift
//  DicomCoreTests
//
//  Checks typed DICOM tag access and its equivalence to raw tag values.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

final class DCMDecoderDicomTagTests: XCTestCase {

    func testDicomTagEnumUsage() throws {
        let decoder = try DCMDecoder(contentsOf: getAnyFixtureDICOMURL())

        let patientName = decoder.info(for: .patientName)
        XCTAssertFalse(patientName.isEmpty, "Should retrieve a non-empty patient name using DicomTag enum")

        let rows = decoder.intValue(for: .rows)
        XCTAssertNotNil(rows, "Should be able to retrieve rows using DicomTag enum")
        if let rowsValue = rows {
            XCTAssertGreaterThan(rowsValue, 0, "Rows value should be greater than 0")
            XCTAssertEqual(rowsValue, decoder.height, "Rows value should match decoder.height")
        }

        let columns = decoder.intValue(for: .columns)
        XCTAssertNotNil(columns, "Should be able to retrieve columns using DicomTag enum")
        if let columnsValue = columns {
            XCTAssertGreaterThan(columnsValue, 0, "Columns value should be greater than 0")
            XCTAssertEqual(columnsValue, decoder.width, "Columns value should match decoder.width")
        }

        let pixelSpacingString = decoder.info(for: .pixelSpacing)
        let pixelSpacing = decoder.pixelSpacingV2
        XCTAssertTrue(pixelSpacing.isValid, "PixelSpacing V2 should be valid")
        XCTAssertGreaterThan(pixelSpacing.x, 0, "Pixel spacing x should be positive")
        XCTAssertGreaterThan(pixelSpacing.y, 0, "Pixel spacing y should be positive")
        let pixelSpacingDouble = decoder.doubleValue(for: .pixelSpacing)
        if let pixelSpacingDouble {
            XCTAssertEqual(pixelSpacingDouble, pixelSpacing.x, accuracy: 0.001)
        } else {
            XCTAssertFalse(pixelSpacingString.isEmpty, "Multi-value pixel spacing should be available as a string")
        }

        XCTAssertNotNil(decoder.doubleValue(for: .rescaleSlope), "Rescale slope should be numeric")
        XCTAssertNotNil(decoder.doubleValue(for: .rescaleIntercept), "Rescale intercept should be numeric")
    }

    func testDicomTagVsRawValueEquivalence() throws {
        let decoder = try DCMDecoder(contentsOf: getAnyFixtureDICOMURL())

        let patientNameEnum = decoder.info(for: .patientName)
        let patientNameHex = decoder.info(for: 0x00100010)
        XCTAssertEqual(patientNameEnum, patientNameHex,
                       "info(for: .patientName) should equal info(for: 0x00100010)")

        let modalityEnum = decoder.info(for: .modality)
        let modalityHex = decoder.info(for: 0x00080060)
        XCTAssertEqual(modalityEnum, modalityHex,
                       "info(for: .modality) should equal info(for: 0x00080060)")

        let rowsEnum = decoder.intValue(for: .rows)
        let rowsHex = decoder.intValue(for: 0x00280010)
        XCTAssertEqual(rowsEnum, rowsHex,
                       "intValue(for: .rows) should equal intValue(for: 0x00280010)")

        let columnsEnum = decoder.intValue(for: .columns)
        let columnsHex = decoder.intValue(for: 0x00280011)
        XCTAssertEqual(columnsEnum, columnsHex,
                       "intValue(for: .columns) should equal intValue(for: 0x00280011)")

        let bitsAllocatedEnum = decoder.intValue(for: .bitsAllocated)
        let bitsAllocatedHex = decoder.intValue(for: 0x00280100)
        XCTAssertEqual(bitsAllocatedEnum, bitsAllocatedHex,
                       "intValue(for: .bitsAllocated) should equal intValue(for: 0x00280100)")

        let rescaleSlopeEnum = decoder.doubleValue(for: .rescaleSlope)
        let rescaleSlopeHex = decoder.doubleValue(for: 0x00281053)
        XCTAssertEqual(rescaleSlopeEnum, rescaleSlopeHex,
                       "doubleValue(for: .rescaleSlope) should equal doubleValue(for: 0x00281053)")

        let rescaleInterceptEnum = decoder.doubleValue(for: .rescaleIntercept)
        let rescaleInterceptHex = decoder.doubleValue(for: 0x00281052)
        XCTAssertEqual(rescaleInterceptEnum, rescaleInterceptHex,
                       "doubleValue(for: .rescaleIntercept) should equal doubleValue(for: 0x00281052)")

        let windowCenterEnum = decoder.doubleValue(for: .windowCenter)
        let windowCenterHex = decoder.doubleValue(for: 0x00281050)
        XCTAssertEqual(windowCenterEnum, windowCenterHex,
                       "doubleValue(for: .windowCenter) should equal doubleValue(for: 0x00281050)")

        let windowWidthEnum = decoder.doubleValue(for: .windowWidth)
        let windowWidthHex = decoder.doubleValue(for: 0x00281051)
        XCTAssertEqual(windowWidthEnum, windowWidthHex,
                       "doubleValue(for: .windowWidth) should equal doubleValue(for: 0x00281051)")
    }
}
