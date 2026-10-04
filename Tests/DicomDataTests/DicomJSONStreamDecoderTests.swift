import Foundation
import XCTest
@testable import DicomData

final class DicomJSONStreamDecoderTests: XCTestCase {
    private typealias Rep = DicomDataSetRepresentation

    /// Braces, brackets, quotes and backslashes inside strings must not end a data set early.
    private let document = Data(#"""
        [ {"00104000":{"vr":"LT","Value":["} ] { [ \" \\ \"}"]},"00280010":{"vr":"US","Value":[512]}} ,
          {"0040A730":{"vr":"SQ","Value":[{"00080100":{"vr":"SH","Value":["[x]"]}},{}]}},
          {} ]
        """#.utf8)

    private func read(_ data: Data, sizes: [Int], options: Rep.DecodingOptions = .init()) throws -> [Rep.Decoded] {
        var decoder = DicomJSONStreamDecoder(options: options)
        var result: [Rep.Decoded] = []
        var offset = 0
        var index = 0
        while offset < data.count {
            let end = min(data.count, offset + sizes[index % sizes.count])
            result += try decoder.feed(data[offset..<end])
            offset = end
            index += 1
        }
        try decoder.finish()
        return result
    }

    func test_everySplit_readsTheSameDataSetsAsTheWholeDocument() throws {
        let expected = try DicomJSONCodec.decode(document).map(\.dataSet)
        XCTAssertEqual(expected.count, 3)
        XCTAssertEqual(try read(document, sizes: [1]).map(\.dataSet), expected)
        for split in 1..<document.count {
            XCTAssertEqual(try read(document, sizes: [split, document.count]).map(\.dataSet), expected, "split \(split)")
        }
        let single = Data(#" {"00280010":{"vr":"US","Value":[1]}} "#.utf8)
        XCTAssertEqual(try read(single, sizes: [3]).map(\.dataSet), try DicomJSONCodec.decode(single).map(\.dataSet))
        XCTAssertEqual(try read(Data(" [ ] ".utf8), sizes: [1]).count, 0)
        XCTAssertEqual(try read(Data(), sizes: [1]).count, 0)
    }

    /// The size limit applies to each data set, not to the document.
    func test_limit_boundsEachDataSetAndNotTheDocument() throws {
        let entry = #"{"00104000":{"vr":"LT","Value":["\#(String(repeating: "a", count: 900))"]}}"#
        let many = Data(("[" + Array(repeating: entry, count: 50).joined(separator: ",") + "]").utf8)
        XCTAssertEqual(try read(many, sizes: [4096], options: .init(maximumBytes: 1024)).count, 50)
        let large = Data(("[" + entry.replacingOccurrences(of: "aaaa", with: "aaaaaaaa") + "]").utf8)
        XCTAssertThrowsError(try read(large, sizes: [4096], options: .init(maximumBytes: 1024))) {
            guard case .inputTooLarge(_, let limit)? = $0 as? Rep.Error else { return XCTFail("\($0)") }
            XCTAssertEqual(limit, 1024)
        }
    }

    func test_malformedDocuments_areRejected() {
        for text in ["[1]", "[{},]", "[{}", "[{} {}]", "{}{}", "\"x\"", "[{\"00280010\":}]", "]"] {
            XCTAssertThrowsError(try read(Data(text.utf8), sizes: [1]), text) {
                guard case .invalidDocument? = $0 as? Rep.Error else { return XCTFail("\(text): \($0)") }
            }
        }
    }
}
