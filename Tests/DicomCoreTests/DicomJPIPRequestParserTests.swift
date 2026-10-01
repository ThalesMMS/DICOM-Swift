import Foundation
import XCTest
@testable import DicomCore

final class DicomJPIPRequestParserTests: XCTestCase {
    func test_windowAndCacheGrammar_preservesSelectionsWithoutExpandingRanges() throws {
        let url = try XCTUnwrap(URL(string: "http://localhost/jpip?target=a.jp2&fsiz=256,128,closest&roff=8,4&rsiz=32,16&layers=2&comps=0-2,5&stream=1-999999999&type=raw,jpp-stream&model=%5B0%5D,Hm,P3:128&cnew=http"))
        let request = try DicomJPIPRequestParser().parse(url)
        XCTAssertEqual(request.window.rounding, .closest)
        XCTAssertEqual(request.window.rsiz, .init(32, 16))
        XCTAssertEqual(request.window.layers, 2)
        XCTAssertEqual(request.streams, [1...999999999])
        XCTAssertEqual(request.window.comps, [0...2, 5...5])
        XCTAssertTrue(request.newChannel)
        XCTAssertEqual(try request.cacheModel.modelDescriptors.count, 2)
    }

    func test_adversarialFields_throwTypedErrors() throws {
        let invalid = ["fsiz=1,0", "fsiz=1,1,bad", "stream=0", "comps=5-1", "layers=-1", "len=9999999999999999999999",
                       "cid=x%0Ay", "cid=x&cid=y", "cnew=udp", "!future=1", "model=P0&need=P1", "align=maybe",
                       "metareq=%5B", "fsiz=10,10&roff=10,0", "fsiz=10,10&rsiz=11,1",
                       "tpmodel=-", "tpmodel=--", "tpmodel=---"]
        for query in invalid {
            let url = try XCTUnwrap(URL(string: "http://localhost/jpip?" + query))
            XCTAssertThrowsError(try DicomJPIPRequestParser().parse(url), query) {
                XCTAssertEqual($0 as? DicomJPIPServerError, .malformedRequest, query)
            }
        }
        XCTAssertThrowsError(try DicomJPIPRequestParser().parse(XCTUnwrap(URL(string: "http://localhost/?type=raw")))) {
            XCTAssertEqual($0 as? DicomJPIPServerError, .unsupportedMediaType)
        }
    }

    func test_limitsAndUnknownOptionalFields() throws {
        let url = try XCTUnwrap(URL(string: "http://localhost/?future=anything&target=x"))
        XCTAssertEqual(try DicomJPIPRequestParser().parse(url).target, "x")
        XCTAssertThrowsError(try DicomJPIPRequestParser(maximumRequestBytes: 10).parse(url))
        XCTAssertThrowsError(try DicomJPIPRequestParser(maximumParameters: 1).parse(url))
    }

    func test_messageWriter_roundTripsBoundaryIntegersAndExtendedClasses() throws {
        let writer = DicomJPIPMessageWriter()
        for bin in [0, 15, 16, 127, 128, 2047, 2048, Int.max] {
            let message = DicomJPIPMessage(classID: 1, codestream: 128, binID: bin, offset: 300,
                                          isComplete: true, auxiliary: 5, body: Data([1, 2, 3]))
            var parser = DicomJPIPMessageParser()
            XCTAssertEqual(try parser.feed(writer.encode(message) + writer.endOfResponse(reason: 2)), [message])
            try parser.finish()
            XCTAssertEqual(parser.endOfResponse?.reason, 2)
        }
        XCTAssertThrowsError(try DicomJPIPMessageWriter(maximumMessageBytes: 2).endOfResponse(reason: 2))
        XCTAssertThrowsError(try writer.encode(.init(classID: 1, codestream: 0, binID: 0, offset: 0, body: Data())))
    }
}
