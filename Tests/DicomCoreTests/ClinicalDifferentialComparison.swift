import Foundation

/// Test-only comparison of complete ordered frames in the declared sample domain.
struct ClinicalDifferentialComparison {
    struct Difference: Codable, Equatable {
        let path: String
        let expected: Double
        let actual: Double
    }

    struct Result: Codable {
        let result: String
        let firstDifference: Difference?
        let samplesCompared: Int
        let maximumAbsoluteError: Double
        let rootMeanSquareError: Double
    }

    static func compare(
        expected: [[Int]], actual: [[Int]], columns: Int, components: Int,
        maximumAbsoluteError allowedError: Double = 0
    ) -> Result {
        var first: Difference?
        var count = 0
        var maximumError = 0.0
        var squaredError = 0.0
        if expected.count != actual.count {
            first = Difference(path: "frameCount", expected: Double(expected.count), actual: Double(actual.count))
        }
        for frame in 0..<min(expected.count, actual.count) {
            if expected[frame].count != actual[frame].count, first == nil {
                first = Difference(path: "frame[\(frame)].sampleCount", expected: Double(expected[frame].count),
                                   actual: Double(actual[frame].count))
            }
            for index in 0..<min(expected[frame].count, actual[frame].count) {
                let reference = Double(expected[frame][index])
                let observed = Double(actual[frame][index])
                let error = abs(reference - observed)
                count += 1
                squaredError += error * error
                maximumError = max(maximumError, error)
                if error > allowedError, first == nil {
                    let pixel = index / components
                    first = Difference(
                        path: "frame[\(frame)].row[\(pixel / columns)].column[\(pixel % columns)].component[\(index % components)]",
                        expected: reference, actual: observed
                    )
                }
            }
        }
        return Result(result: first == nil ? "passed" : "mismatched", firstDifference: first,
                      samplesCompared: count, maximumAbsoluteError: maximumError,
                      rootMeanSquareError: count == 0 ? 0 : sqrt(squaredError / Double(count)))
    }
}
