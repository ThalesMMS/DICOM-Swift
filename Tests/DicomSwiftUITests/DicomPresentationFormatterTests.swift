import XCTest
@testable import DicomSwiftUI
import DicomCore

final class DicomPresentationFormatterTests: XCTestCase {

    func testSex_knownValues() {
        XCTAssertEqual(DicomDisplayFormatter.sex("M"), "Male")
        XCTAssertEqual(DicomDisplayFormatter.sex("f"), "Female")
        XCTAssertEqual(DicomDisplayFormatter.sex("O"), "Other")
    }

    func testSex_unknownValue_passthrough() {
        XCTAssertEqual(DicomDisplayFormatter.sex("X"), "X")
    }

    func testSex_nilOrEmpty_returnsNA() {
        XCTAssertEqual(DicomDisplayFormatter.sex(nil), DicomDisplayFormatter.notAvailable)
        XCTAssertEqual(DicomDisplayFormatter.sex(""), DicomDisplayFormatter.notAvailable)
    }

    func testModality_nilOrEmpty_returnsNA() {
        XCTAssertEqual(DicomDisplayFormatter.modality(nil), DicomDisplayFormatter.notAvailable)
        XCTAssertEqual(DicomDisplayFormatter.modality(""), DicomDisplayFormatter.notAvailable)
    }

    func testDate_formatsYYYYMMDD() {
        XCTAssertEqual(DicomDisplayFormatter.date("20250131"), "2025-01-31")
    }

    func testDate_invalidLength_passthroughOrNA() {
        XCTAssertEqual(DicomDisplayFormatter.date("2025"), "2025")
        XCTAssertEqual(DicomDisplayFormatter.date(nil), DicomDisplayFormatter.notAvailable)
    }

    func testTime_formatsHHMMSS() {
        XCTAssertEqual(DicomDisplayFormatter.time("235959"), "23:59:59")
    }

    func testTime_fractionalSeconds_ignoresFraction() {
        XCTAssertEqual(DicomDisplayFormatter.time("010203.1234"), "01:02:03")
    }

    func testTime_invalidLength_passthroughOrNA() {
        XCTAssertEqual(DicomDisplayFormatter.time("12"), "12")
        XCTAssertEqual(DicomDisplayFormatter.time(nil), DicomDisplayFormatter.notAvailable)
    }

    func testDimensions_formatsWithMultiplicationSign() {
        XCTAssertEqual(DicomDisplayFormatter.dimensions(width: 512, height: 256), "512 × 256 pixels")
    }

    func testPixelSpacing_invalid_returnsNA() {
        XCTAssertEqual(DicomDisplayFormatter.pixelSpacing(PixelSpacing(x: 0, y: 0, z: 0)), DicomDisplayFormatter.notAvailable)
    }

    func testPixelSpacing_2D_formatsToTwoDecimals() {
        let spacing = PixelSpacing(x: 0.9765625, y: 0.5, z: 0)
        XCTAssertEqual(DicomDisplayFormatter.pixelSpacing(spacing), "0.98 × 0.50 mm")
    }

    func testPixelSpacing_3D_includesZWhenPresent() {
        let spacing = PixelSpacing(x: 1, y: 2, z: 3)
        XCTAssertEqual(DicomDisplayFormatter.pixelSpacing(spacing), "1.00 × 2.00 × 3.00 mm")
    }

    func testMeasurement_nilOrEmpty_returnsNA() {
        XCTAssertEqual(DicomDisplayFormatter.measurement(nil, unit: "mm"), DicomDisplayFormatter.notAvailable)
        XCTAssertEqual(DicomDisplayFormatter.measurement("", unit: "mm"), DicomDisplayFormatter.notAvailable)
    }

    func testMeasurement_includesUnit() {
        XCTAssertEqual(DicomDisplayFormatter.measurement("10", unit: "mm"), "10 mm")
    }

    func testWindowValue_invalid_returnsNA() {
        XCTAssertEqual(DicomDisplayFormatter.windowValue(123.456, isValid: false), DicomDisplayFormatter.notAvailable)
    }

    func testWindowValue_valid_roundsToOneDecimal() {
        XCTAssertEqual(DicomDisplayFormatter.windowValue(123.44, isValid: true), "123.4")
        XCTAssertEqual(DicomDisplayFormatter.windowValue(123.45, isValid: true), "123.5")
    }
}
