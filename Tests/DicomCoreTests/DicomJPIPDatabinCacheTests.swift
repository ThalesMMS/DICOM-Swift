import Foundation
import XCTest
@testable import DicomCore

final class DicomJPIPDatabinCacheTests: XCTestCase {
    func test_gapsOverlapDuplicatesAndCompletion_accountExactly() throws {
        var cache = DicomJPIPDatabinCache()
        func message(_ offset: Int, _ bytes: [UInt8], complete: Bool = false) -> DicomJPIPMessage {
            .init(classID: 0, codestream: 0, binID: 8, offset: offset, isComplete: complete, body: Data(bytes))
        }
        try cache.insert(message(3, [4, 5], complete: true))
        XCTAssertEqual(cache.bin(codestream: 0, classID: 0, binID: 8)?.gaps, [0..<3])
        try cache.insert(message(0, [1, 2, 3, 4]))
        try cache.insert(message(1, [2, 3]))
        XCTAssertEqual(cache.usefulBytes, 5)
        XCTAssertEqual(cache.redundantBytes, 3)
        XCTAssertEqual(cache.byteCount, 5)
        XCTAssertEqual(cache.bin(codestream: 0, classID: 0, binID: 8)?.isComplete, true)
        XCTAssertEqual(cache.bin(codestream: 0, classID: 0, binID: 8)?.contiguousData, Data([1, 2, 3, 4, 5]))
        XCTAssertThrowsError(try cache.insert(message(0, [9])))
        XCTAssertThrowsError(try cache.insert(message(5, [6])))
        XCTAssertEqual(cache.usefulBytes, 5)
    }

    func test_eviction_pinsActiveHeadersAndWindow() throws {
        var cache = DicomJPIPDatabinCache(maximumBytes: 6, maximumBins: 3)
        func message(_ kind: Int, _ id: Int) -> DicomJPIPMessage {
            .init(classID: kind, codestream: 0, binID: id, offset: 0, body: Data([1, 2]))
        }
        try cache.insert(message(6, 0))
        try cache.insert(message(0, 0))
        try cache.insert(message(0, 1))
        cache.activeWindowBins = [.init(codestream: 0, classID: 0, binID: 1)]
        try cache.insert(message(0, 2))
        XCTAssertNil(cache.bin(codestream: 0, classID: 0, binID: 0))
        XCTAssertNotNil(cache.bin(codestream: 0, classID: 6, binID: 0))
        XCTAssertNotNil(cache.bin(codestream: 0, classID: 0, binID: 1))
        XCTAssertEqual(cache.peakBytes, 6)
        XCTAssertThrowsError(try cache.insert(message(4, 0))) {
            XCTAssertEqual($0 as? DicomJPIPCacheError, .mixedStreamModes)
        }
    }

    func test_cacheModel_onlyAdvertisesContiguousBytes() throws {
        var cache = DicomJPIPDatabinCache()
        try cache.insert(.init(classID: 6, codestream: 0, binID: 0, offset: 0, isComplete: true, body: Data([1])))
        try cache.insert(.init(classID: 0, codestream: 0, binID: 4, offset: 5, isComplete: true, body: Data([1])))
        XCTAssertEqual(DicomJPIPCacheModel(cache: cache).model, "[0],Hm")
        try cache.insert(.init(classID: 0, codestream: 0, binID: 4, offset: 0, body: Data([1, 2])))
        XCTAssertEqual(DicomJPIPCacheModel(cache: cache).model, "[0],P4:2,Hm")
    }
    func test_windowActivation_pinsOverlappingBorderPrecinctsAndHeaders() throws {
        let fixture = try DicomJPIPCodestreamReconstructorTests.indexed("RPCL")
        let budget = fixture.main.count + fixture.header.count + 3
        var cache = DicomJPIPDatabinCache(maximumBytes: budget)
        // x=15 straddles two 16-pixel precincts, so both must be protected.
        let window = try DicomJPIPWindow(fsiz: .init(64, 64), rsiz: .init(2, 2), roff: .init(15, 15))
        try cache.activate(window: window)
        try cache.insert(.init(classID: 6, codestream: 0, binID: 0, offset: 0, isComplete: true, body: fixture.main))
        try cache.insert(.init(classID: 2, codestream: 0, binID: 0, offset: 0, isComplete: true, body: fixture.header))
        func message(_ id: Int) -> DicomJPIPMessage {
            .init(classID: 0, codestream: 0, binID: id, offset: 0, body: Data([1]))
        }
        try cache.insert(message(12)) // resolution 1, (0,0)
        try cache.insert(message(15)) // resolution 1, (16,0), partial edge overlap
        try cache.insert(message(57)) // outside window
        try cache.insert(message(54))
        XCTAssertNil(cache.bin(codestream: 0, classID: 0, binID: 57))
        for id in [12, 15] { XCTAssertNotNil(cache.bin(codestream: 0, classID: 0, binID: id)) }
        XCTAssertNotNil(cache.bin(codestream: 0, classID: 6, binID: 0))
        XCTAssertNotNil(cache.bin(codestream: 0, classID: 2, binID: 0))
        XCTAssertEqual(cache.peakBytes, budget)
    }

    func test_cacheModelImport_parsesRangesCountsAndNeedWithoutInventingBytes() throws {
        var cache = DicomJPIPDatabinCache()
        let model = try DicomJPIPCacheModel(model: "[0-2;5-],Hm,P4:30,-P4:10,P7:L2,t1-3c0r0-1:L1")
        try cache.importCacheModel(model)
        XCTAssertEqual(cache.importedModel.count, 5)
        XCTAssertEqual(cache.importedModel[1].codestreams, [0...2, 5...Int.max])
        XCTAssertEqual(cache.importedModel[1].extent, .bytes(30))
        XCTAssertEqual(cache.importedModel[2].subtractive, true)
        XCTAssertEqual(cache.importedModel[3].extent, .layers(2))
        XCTAssertEqual(cache.importedModel[4].selectors["t"], 1...3)
        XCTAssertEqual(cache.byteCount, 0)
        XCTAssertEqual(DicomJPIPCacheModel(cache: cache).model, "")
        try cache.importCacheModel(.init(need: "[0],H*:20,P5:L2"))
        XCTAssertEqual(cache.importedNeed.count, 2)
        XCTAssertNil(cache.importedNeed[0].binID)
        XCTAssertEqual(cache.importedNeed[0].extent, .bytes(20))
        for invalid in ["[3-1],P0", "P99999999999999999999999", "H0:L2", "t2t3:L1"] {
            XCTAssertThrowsError(try DicomJPIPCacheModel(model: invalid), invalid)
        }
        XCTAssertThrowsError(try DicomJPIPCacheModel(model: "Hm", need: "P0"))
        XCTAssertThrowsError(try DicomJPIPCacheModel(tpmodel: "0.0", need: "P0"))
    }

}
