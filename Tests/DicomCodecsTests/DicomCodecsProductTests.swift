import DicomCodecs
import Foundation
import XCTest

final class DicomCodecsProductTests: XCTestCase {
    func test_rawCodecConsumer_rejectsInvalidStreamWithoutDataOrUIProducts() {
        XCTAssertThrowsError(try JPEGExtendedDecoder.decode(Data([0, 1, 2, 3]))) { error in
            XCTAssertEqual(error as? JPEGExtendedDecoder.DecodeError, .notAJPEGStream)
        }
    }
}
