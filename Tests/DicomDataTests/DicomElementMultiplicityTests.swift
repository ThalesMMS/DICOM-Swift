import Foundation
import XCTest
@testable import DicomData

final class DicomElementMultiplicityTests: XCTestCase {
    func test_sequenceAndOtherNumericVRs_reportElementMultiplicityInsteadOfItemOrSampleCount() {
        for items in [[], [DicomSequenceItem(dataSet: .init()), .init(dataSet: .init())]] {
            XCTAssertEqual(DicomDataElement(tag: 0x77771001, vr: .SQ, value: .sequence(items)).vm.count, 1)
        }
        for vr in [DicomVR.OF, .OD] {
            XCTAssertEqual(DicomDataElement(tag: 0x77771001, vr: vr, value: .floats([1, 2, 3])).vm.count, 1)
            XCTAssertEqual(DicomDataElement(tag: 0x77771001, vr: vr, value: .floats([])).vm.count, 0)
        }
        XCTAssertEqual(DicomDataElement(tag: 0x77771001, vr: .OL, value: .unsignedIntegers([1, 2, 3])).vm.count, 1)
        XCTAssertEqual(DicomDataElement(tag: 0x77771001, vr: .FD, value: .floats([1, 2, 3])).vm.count, 3)
    }
}
