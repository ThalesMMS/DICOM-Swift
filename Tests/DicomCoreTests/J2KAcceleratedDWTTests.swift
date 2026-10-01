@testable import DicomJPEG2000
import XCTest

final class J2KAcceleratedDWTTests: XCTestCase {
    func test_workspaceGather_matchesScalarSplitForOddAndEvenSignals() {
        for count in [1, 2, 3, 31, 32, 33, 128, 129] {
            let input = (0..<count).map { Float(($0 * 17) % 101) - 50 }
            let expected = scalarTransform(input)
            var actual = [Float](repeating: 0, count: count)
            let workspace = AcceleratedDWT2D.DWTWorkspace(maxSignalLength: count)
            input.withUnsafeBufferPointer { source in
                actual.withUnsafeMutableBufferPointer { destination in
                    AcceleratedDWT2D.forward97_1D(
                        source.baseAddress!, destination.baseAddress!, count: count, workspace: workspace
                    )
                }
            }
            for index in input.indices {
                XCTAssertEqual(actual[index], expected[index], accuracy: 0.0001, "count=\(count), index=\(index)")
            }
        }
    }

    func test_parallelStripsAndRows_matchSerialTransformIncludingPartialChunks() async {
        for (width, height) in [(63, 33), (65, 35), (128, 128), (137, 131)] {
            let input = (0..<(width * height)).map { Float(($0 * 17) % 101) - 50 }
            var columns = input
            for column in 0..<width {
                let transformed = scalarTransform((0..<height).map { input[$0 * width + column] })
                for row in 0..<height { columns[row * width + column] = transformed[row] }
            }
            let actual = await AcceleratedDWT2D.forward2D(data: input, width: width, height: height)
            XCTAssertEqual(actual.ll.count + actual.hl.count + actual.lh.count + actual.hh.count, input.count)
            let lowHeight = (height + 1) / 2
            let lowWidth = (width + 1) / 2
            for row in 0..<height {
                let expected = scalarTransform(Array(columns[(row * width)..<((row + 1) * width)]))
                let bandRow = row < lowHeight ? row : row - lowHeight
                let low = row < lowHeight ? actual.ll : actual.lh
                let high = row < lowHeight ? actual.hl : actual.hh
                for column in 0..<width {
                    let value = column < lowWidth
                        ? low[bandRow * lowWidth + column]
                        : high[bandRow * (width / 2) + column - lowWidth]
                    XCTAssertEqual(value, expected[column], accuracy: 0.001, "\(width)x\(height), (\(column),\(row))")
                }
            }
        }
    }

    private func scalarTransform(_ input: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                AcceleratedDWT2D.forward97_1D(source.baseAddress!, destination.baseAddress!, count: input.count)
            }
        }
        return output
    }
}
