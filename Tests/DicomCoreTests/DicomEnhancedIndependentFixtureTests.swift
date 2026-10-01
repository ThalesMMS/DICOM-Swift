import Foundation
import XCTest
@testable import DicomCore

final class DicomEnhancedIndependentFixtureTests: XCTestCase {
    private struct ExpectedFrame: Decodable {
        let frame: Int
        let coordinates: [Int]
        let z: Double
        let intercept: Double
        let window: Double
        let center_sample: Int
    }

    func test_independentMultidimensionalObjects_matchEveryPartitionAndSourceFrame() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/EnhancedDimensions")
        let expected = try JSONDecoder().decode(
            [ExpectedFrame].self, from: Data(contentsOf: root.appendingPathComponent("manifest.json"))
        )
        for concatenated in [false, true] {
            let urls = concatenated
                ? ["concatenation/member_1.dcm", "concatenation/member_2.dcm"].map(root.appendingPathComponent)
                : [root.appendingPathComponent("single/enhanced_dimensions.dcm")]
            let collection = try DicomEnhancedFrameCollection(sources: urls.map {
                try DicomEnhancedFrameSource(decoder: DCMDecoder(contentsOf: $0))
            })
            XCTAssertEqual(collection.partitions.count, 8)
            if concatenated { XCTAssertEqual(Array(collection.concatenations.values), [.complete]) }
            for partition in collection.partitions {
                let frames = expected.filter { frame in
                    zip(partition.selection.ordinals, frame.coordinates).allSatisfy { ordinal, value in
                        ordinal == nil || ordinal == value
                    }
                }.sorted { $0.z < $1.z }
                XCTAssertEqual(frames.count, 3)
                let volume = try DicomSeriesLoader().loadEnhancedMultiframeVolume(
                    at: urls, selection: partition.selection
                )
                XCTAssertEqual(volume.depth, frames.count)
                XCTAssertEqual(volume.width, 32)
                XCTAssertEqual(volume.height, 32)
                XCTAssertEqual(volume.spacing, SIMD3<Double>(1, 1, 2.5))
                XCTAssertEqual(volume.origin, SIMD3<Double>(0, 0, 0))
                XCTAssertEqual(volume.sliceRescaleParameters.map(\.intercept), frames.map(\.intercept))
                XCTAssertEqual(volume.windowCenter, frames.first?.window)
                let pixels = volume.voxels.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
                for (index, frame) in frames.enumerated() {
                    XCTAssertEqual(pixels[index * 1024 + 16 * 32 + 16], Int16(frame.center_sample))
                    let reference = volume.enhancedFrameReferences[index]
                    XCTAssertEqual(reference.frameIndex, concatenated ? frame.frame % 12 : frame.frame)
                    XCTAssertEqual(reference.concatenationFrameIndex, concatenated ? frame.frame : nil)
                    XCTAssertEqual(reference.sopInstanceUID, concatenated
                        ? "2.25.2342110\(frame.frame / 12 + 1)" : "2.25.23421001")
                }
            }
        }
    }
}
