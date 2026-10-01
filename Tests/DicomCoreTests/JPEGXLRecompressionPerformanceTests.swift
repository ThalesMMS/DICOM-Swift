import Foundation
@testable import DicomJPEGXL
import XCTest

final class JPEGXLRecompressionPerformanceTests: XCTestCase {
    func test_ANSSectionCostMatchesSerializedBitsAcrossFreshGroups() throws {
        let config = HybridUintConfig.raw4
        var frequencies = [Int32](repeating: 64, count: 32)
        frequencies[0] += 2048
        var distribution = BitWriter()
        let wire = try SpecANSDistribution.writeHistogram(frequencies, to: &distribution)
        let contextMap = try ContextMap(numClusters: 2, useMTF: false, map: [0, 1, 0, 1])
        let header = EntropySectionHeader(lz77: .disabled, contextMap: contextMap,
            usePrefixCode: false, logAlphaSize: 5, uintConfigs: [config, config])
        let codebook = MultiClusterCodebook(huffmanTables: [], ansCounts: [wire, wire],
                                           alphabetSizes: [wire.count, wire.count])
        var first: [(context: Int, value: UInt32)] = []
        for i in 0..<997 {
            let value: Int = i % 7 == 0 ? 256 + i : i % 16
            first.append((i % 4, UInt32(value)))
        }
        var second: [(context: Int, value: UInt32)] = []
        for i in 0..<511 {
            let value: Int = i % 3 == 0 ? 16 + i : 0
            second.append(((i + 1) % 4, UInt32(value)))
        }
        for groups in [[first], [first, second, []], [second, first, second]] {
            let counted = try VarDCTBitstreamWriter.estimateBridgeACSectionBits(
                header: header, codebook: codebook, perGroup: groups, contexts: 4)
            var actual = BitWriter()
            try header.write(to: &actual, numContexts: 4)
            try codebook.write(to: &actual, header: header)
            for group in groups {
                var writer = try ANSTokenStreamWriter(header: header, codebook: codebook)
                for token in group { try writer.writeToken(context: token.context, value: token.value) }
                try writer.finish(to: &actual)
            }
            XCTAssertEqual(counted, actual.bitCount, "group state and extra bits must match full serialization")
        }
    }
}
