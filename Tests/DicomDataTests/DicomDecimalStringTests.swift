import Foundation
import XCTest
@testable import DicomData

final class DicomDecimalStringTests: XCTestCase {
    func test_newlineTerminatedDSAndIS_areRejectedWithoutTrimmingControls() {
        for vr in [DicomVR.DS, .IS] {
            for value in ["1\n", "1\r", "1\r\n", " 1\n "] {
                XCTAssertThrowsError(try DicomDecimalString.parse(value, vr: vr)) { error in
                    guard case DicomDecimalString.Failure.invalid = error else {
                        return XCTFail("Expected invalid \(vr.code), got \(error)")
                    }
                }
            }
        }
    }

    func test_spacePaddedDSAndIS_preserveValidValues() throws {
        XCTAssertEqual(try DicomDecimalString.parse(" +1.25E1 "), Decimal(string: "12.5"))
        XCTAssertEqual(try DicomDecimalString.parse(" -12 ", vr: .IS), Decimal(-12))
    }
}
