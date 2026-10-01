import Foundation
import XCTest
@testable import HL7MLLP

final class MLLPFramerTests: XCTestCase {
    func test_frame_roundTripsBytesAndEmptyPayload() throws {
        for payload in [Data(), Data([0, 255, 13, 128]), Data("MSH|abc".utf8)] {
            let wire = try MLLPFramer.frame(payload)
            XCTAssertEqual(wire, Data([11]) + payload + Data([28, 13]))
            var parser = MLLPDeframer()
            XCTAssertEqual(try parser.feed(wire).map(\.payload), [payload])
        }
    }

    func test_unsafePayload_refusedUnlessOptedIn() throws {
        for payload in [Data([65, 28, 13, 66]), Data([11]), Data([28])] {
            XCTAssertThrowsError(try MLLPFramer.frame(payload)) {
                XCTAssertEqual(($0 as? MLLPFramingError)?.reason, .unsafePayload)
            }
            XCTAssertEqual(try MLLPFramer.frame(payload, allowUnsafe: true), Data([11]) + payload + Data([28, 13]))
        }
    }

    func test_defaults_matchContract() {
        let limits = MLLPLimits()
        XCTAssertEqual(limits.maxMessageBytes, 16 * 1024 * 1024)
        XCTAssertEqual(limits.maxBufferedBytes, 32 * 1024 * 1024)
        XCTAssertEqual(limits.maxPendingFrames, 64)
        XCTAssertEqual(limits.maxJunkBytesBetweenBlocks, 4096)
        XCTAssertEqual(limits.idleTimeout, 60)
        XCTAssertEqual(limits.recovery, .strict)
    }
}
