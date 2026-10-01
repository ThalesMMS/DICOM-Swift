import XCTest
@testable import DicomCore
import DicomTestSupport

final class DCMDecoderPixelThreadSafetyTests: XCTestCase {

    // MARK: - Thread Safety Tests for Pixel Access

    @MainActor
    func testConcurrentPixelAccess() throws {
        let decoder = try DCMDecoder(contentsOf: getCTSyntheticFixtureURL())
        let expectedPixels16 = try XCTUnwrap(decoder.getPixels16())
        let expectation = self.expectation(description: "Concurrent pixel access")
        expectation.expectedFulfillmentCount = 10
        let results = DicomTestLockedValue((
            pixels16: [[UInt16]?](),
            pixels8: [[UInt8]?](),
            pixels24: [[UInt8]?]()
        ))

        // Test concurrent pixel buffer access
        for _ in 0..<10 {
            DispatchQueue.global().async {
                let pixels8 = decoder.getPixels8()
                let pixels16 = decoder.getPixels16()
                let pixels24 = decoder.getPixels24()
                results.withValue { results in
                    results.pixels8.append(pixels8)
                    results.pixels16.append(pixels16)
                    results.pixels24.append(pixels24)
                }
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 5.0, handler: nil)
        let finalResults = results.value
        XCTAssertEqual(finalResults.pixels16.count, 10)
        XCTAssertTrue(finalResults.pixels16.allSatisfy { $0 == expectedPixels16 }, "All concurrent pixels16 accesses should return the same buffer")
        XCTAssertTrue(finalResults.pixels8.allSatisfy { $0 == nil }, "CT fixture should not expose 8-bit pixels")
        XCTAssertTrue(finalResults.pixels24.allSatisfy { $0 == nil }, "CT fixture should not expose RGB pixels")
    }

    @MainActor
    func testConcurrentPixelAccessConsistency() {
        let decoder = DCMDecoder()
        let expectation = self.expectation(description: "Concurrent pixel access consistency")
        expectation.expectedFulfillmentCount = 20

        let results = DicomTestLockedValue((pixels16: [[UInt16]?](), pixels8: [[UInt8]?]()))

        // Test that concurrent access returns consistent results
        for _ in 0..<20 {
            DispatchQueue.global().async {
                let pixels16 = decoder.getPixels16()
                let pixels8 = decoder.getPixels8()

                results.withValue { results in
                    results.pixels16.append(pixels16)
                    results.pixels8.append(pixels8)
                }

                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 5.0) { _ in
            // All results should be nil and consistent
            XCTAssertTrue(results.value.pixels16.allSatisfy { $0 == nil }, "All concurrent pixels16 accesses should return nil")
            XCTAssertTrue(results.value.pixels8.allSatisfy { $0 == nil }, "All concurrent pixels8 accesses should return nil")
        }
    }

    @MainActor
    func testConcurrentLoadAndPixelAccess() {
        let expectation = self.expectation(description: "Concurrent load and pixel access")
        expectation.expectedFulfillmentCount = 10

        // Test concurrent file loading attempts
        for i in 0..<10 {
            DispatchQueue.global().async {
                let decoder = try? DCMDecoder(contentsOfFile: "/nonexistent/file\(i).dcm")
                XCTAssertNil(decoder, "Decoder should be nil for nonexistent file")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 5.0, handler: nil)
    }
}
