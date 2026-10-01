import DicomNetwork
import Foundation
import XCTest

final class DicomNetworkProductTests: XCTestCase {
    func test_wireConsumer_roundTripsReleaseWithoutCodecsOrUI() throws {
        let encoded = try DicomPDUCodec.encode(.releaseRequest)
        XCTAssertEqual(try DicomPDUCodec.decode(encoded), .releaseRequest)
        XCTAssertEqual(encoded.count, 10)
    }

    func test_wireConsumer_rejectsTruncatedPDU() {
        XCTAssertThrowsError(try DicomPDUCodec.decode(Data([0x05, 0x00]))) { error in
            XCTAssertEqual(error as? DicomNetworkError, .invalidPDULength(expected: 4, actual: 0))
        }
    }
}
