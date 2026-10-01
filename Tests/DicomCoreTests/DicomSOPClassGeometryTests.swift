import DicomCore
import XCTest

/// Issue #2813: the SOP Class rule table for classic Secondary Capture, NM and Ultrasound geometry.
final class DicomSOPClassGeometryTests: XCTestCase {
    private func decimals(_ tag: Int, _ values: [Double]) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: .DS, value: .strings(values.map { "\($0)" }))
    }

    private func region(unitX: UInt, unitY: UInt, deltaX: Double, deltaY: Double) -> DicomDataElement {
        DicomDataElement(tag: 0x0018_6011, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: [
            DicomDataElement(tag: 0x0018_6024, vr: .US, value: .unsignedIntegers([unitX])),
            DicomDataElement(tag: 0x0018_6026, vr: .US, value: .unsignedIntegers([unitY])),
            DicomDataElement(tag: 0x0018_602C, vr: .FD, value: .floats([deltaX])),
            DicomDataElement(tag: 0x0018_602E, vr: .FD, value: .floats([deltaY]))
        ]))]))
    }

    func test_secondaryCapture_prefersPixelSpacingOverNominalScannedSpacing() throws {
        let calibrated = try XCTUnwrap(DicomSOPClassGeometry(dataSet: DicomDataSet(elements: [
            decimals(0x0028_0030, [0.4, 0.5]), decimals(0x0018_2010, [9, 9])
        ]), sopClassUID: DicomSOPClassGeometry.secondaryCaptureSOPClassUID))
        XCTAssertEqual(calibrated.spacing, SIMD3(0.5, 0.4, 1))
        let scanned = try XCTUnwrap(DicomSOPClassGeometry(dataSet: DicomDataSet(elements: [
            decimals(0x0018_2010, [0.25, 0.3]), decimals(0x0018_0050, [2])
        ]), sopClassUID: DicomSOPClassGeometry.secondaryCaptureSOPClassUID))
        XCTAssertEqual(scanned.spacing, SIMD3(0.3, 0.25, 2))
        XCTAssertNil(scanned.origin)
        XCTAssertNil(scanned.orientation)
    }

    func test_nuclearMedicine_readsTheDetectorWhenTheTopLevelHasNoPosition() throws {
        let geometry = try XCTUnwrap(DicomSOPClassGeometry(dataSet: DicomDataSet(elements: [
            decimals(0x0028_0030, [4, 4]), decimals(0x0018_0050, [3]), decimals(0x0018_0088, [4.5]),
            DicomDataElement(tag: 0x0054_0022, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: [
                decimals(0x0020_0032, [-1, -2, -3]), decimals(0x0020_0037, [0, 2, 0, 0, 0, -1])
            ]))]))
        ]), sopClassUID: DicomSOPClassGeometry.nuclearMedicineSOPClassUID))
        XCTAssertEqual(geometry.spacing, SIMD3(4, 4, 4.5))
        XCTAssertEqual(geometry.origin, SIMD3(-1, -2, -3))
        XCTAssertEqual(geometry.orientation?.row, SIMD3(0, 1, 0))
        XCTAssertEqual(geometry.orientation?.column, SIMD3(0, 0, -1))
    }

    func test_ultrasound_countsCentimetreRegionsOnly_asMillimetres() throws {
        let uid = "1.2.840.10008.5.1.4.1.1.3.1"
        let calibrated = try XCTUnwrap(DicomSOPClassGeometry(
            dataSet: DicomDataSet(elements: [region(unitX: 3, unitY: 3, deltaX: 0.02, deltaY: 0.03)]), sopClassUID: uid))
        XCTAssertEqual(calibrated.spacing.x, 0.2, accuracy: 1e-12)
        XCTAssertEqual(calibrated.spacing.y, 0.3, accuracy: 1e-12)
        // A Doppler strip (seconds by cm/s) has no spatial spacing.
        let doppler = try XCTUnwrap(DicomSOPClassGeometry(
            dataSet: DicomDataSet(elements: [region(unitX: 4, unitY: 7, deltaX: 0.01, deltaY: 0.5)]), sopClassUID: uid))
        XCTAssertEqual(doppler.spacing, SIMD3(1, 1, 1))
    }

    func test_otherSOPClasses_areNotCovered() {
        XCTAssertNil(DicomSOPClassGeometry(dataSet: DicomDataSet(elements: [decimals(0x0028_0030, [1, 1])]),
                                           sopClassUID: "1.2.840.10008.5.1.4.1.1.2"))
    }
}
