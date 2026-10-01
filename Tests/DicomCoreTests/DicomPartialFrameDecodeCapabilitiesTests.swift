import XCTest
@testable import DicomCore

final class DicomPartialFrameDecodeCapabilitiesTests: XCTestCase {
    func test_byteFraction_invalidLayers_returnNil() {
        let capabilities = makeCapabilities(totals: [2, 3, 5])
        for layer in [-2, -1, 3, Int.max] {
            XCTAssertNil(capabilities.byteFraction(throughLayer: layer))
        }
        XCTAssertNil(DicomPartialFrameDecodeCapabilities.unavailable.byteFraction(throughLayer: 0))
        XCTAssertNil(makeCapabilities(totals: []).byteFraction(throughLayer: 0))
        XCTAssertNil(makeCapabilities(totals: [0]).byteFraction(throughLayer: 0))
        XCTAssertEqual(capabilities.byteFraction(throughLayer: 0), 0.2)
        XCTAssertEqual(capabilities.byteFraction(throughLayer: 1), 0.5)
        XCTAssertEqual(capabilities.byteFraction(throughLayer: 2), 1)
    }

    private func makeCapabilities(totals: [Int]) -> DicomPartialFrameDecodeCapabilities {
        .init(supportsRegion: false, supportsResolutionReduction: false, supportsQualityLayers: true,
              supportsCombinedRegionAndResolution: false, supportsQualityWithSpatialReduction: false,
              maximumResolutionReductionLevel: nil, qualityLayerCount: totals.count, qualityLayerByteTotals: totals)
    }
}
