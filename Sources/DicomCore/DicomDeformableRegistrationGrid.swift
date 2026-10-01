import Foundation
import simd

/// Displacements in millimetres, sampled in the Registered RCS (C.20.3.1.2–3).
public struct DicomDeformableRegistrationGrid: Equatable, Sendable {
    public let imageOrientationPatient: [Double]
    public let imagePositionPatient: SIMD3<Double>
    public let dimensions: SIMD3<Int>
    public let resolution: SIMD3<Double>
    public let vectorGridData: [Float]

    public init(imageOrientationPatient: [Double], imagePositionPatient: SIMD3<Double>, dimensions: SIMD3<Int>,
                resolution: SIMD3<Double>, vectorGridData: [Float]) {
        self.imageOrientationPatient = imageOrientationPatient
        self.imagePositionPatient = imagePositionPatient
        self.dimensions = dimensions
        self.resolution = resolution
        self.vectorGridData = vectorGridData
    }

    /// NaN triples compare by their undefined-vector meaning, including after a Part 10 round-trip.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.imageOrientationPatient == rhs.imageOrientationPatient && lhs.imagePositionPatient == rhs.imagePositionPatient &&
        lhs.dimensions == rhs.dimensions && lhs.resolution == rhs.resolution && lhs.vectorGridData.count == rhs.vectorGridData.count &&
        zip(lhs.vectorGridData, rhs.vectorGridData).allSatisfy { $0 == $1 || ($0.isNaN && $1.isNaN) }
    }

    public var undefinedVectorCount: Int {
        stride(from: 0, to: vectorGridData.count - vectorGridData.count % 3, by: 3).filter {
            vectorGridData[$0].isNaN && vectorGridData[$0 + 1].isNaN && vectorGridData[$0 + 2].isNaN
        }.count
    }

    public var isValid: Bool {
        guard let count = Self.valueCount(dimensions), count == vectorGridData.count,
              resolution.x.isFinite, resolution.y.isFinite, resolution.z.isFinite,
              resolution.x > 0, resolution.y > 0, resolution.z > 0,
              imagePositionPatient.x.isFinite, imagePositionPatient.y.isFinite, imagePositionPatient.z.isFinite,
              Self.validOrientation(imageOrientationPatient) else { return false }
        return stride(from: 0, to: count, by: 3).allSatisfy {
            let v = Array(vectorGridData[$0..<$0 + 3])
            return v.allSatisfy(\.isFinite) || v.allSatisfy(\.isNaN)
        }
    }

    static func valueCount(_ d: SIMD3<Int>) -> Int? {
        guard d.x > 0, d.y > 0, d.z > 0 else { return nil }
        var count = 3
        for dimension in [d.x, d.y, d.z] {
            let (next, overflow) = count.multipliedReportingOverflow(by: dimension)
            guard !overflow else { return nil }
            count = next
        }
        return count
    }

    static func validOrientation(_ values: [Double]) -> Bool {
        guard values.count == 6, values.allSatisfy(\.isFinite) else { return false }
        let row = SIMD3(values[0], values[1], values[2]), column = SIMD3(values[3], values[4], values[5])
        return abs(simd_length_squared(row) - 1) <= 1e-6 && abs(simd_length_squared(column) - 1) <= 1e-6 &&
            abs(simd_dot(row, column)) <= 1e-6
    }

    /// The storage index is k*YD*XD + j*XD + i. Undefined vectors return nil.
    public func vector(i: Int, j: Int, k: Int) -> SIMD3<Float>? {
        guard let count = Self.valueCount(dimensions), count == vectorGridData.count,
              i >= 0, j >= 0, k >= 0, i < dimensions.x, j < dimensions.y, k < dimensions.z else { return nil }
        let index = (k * dimensions.y * dimensions.x + j * dimensions.x + i) * 3
        let value = SIMD3(vectorGridData[index], vectorGridData[index + 1], vectorGridData[index + 2])
        return value.x.isFinite && value.y.isFinite && value.z.isFinite ? value : nil
    }

    /// Trilinear interpolation; nil outside or if a neighbour with nonzero weight is undefined.
    /// Singleton axes and the final voxel centre use repeated boundary neighbours.
    public func displacement(atRegisteredPoint point: SIMD3<Double>) -> SIMD3<Double>? {
        guard isValid, point.x.isFinite, point.y.isFinite, point.z.isFinite else { return nil }
        let o = imageOrientationPatient
        let row = SIMD3(o[0], o[1], o[2]), column = SIMD3(o[3], o[4], o[5])
        let delta = point - imagePositionPatient
        let coordinate = SIMD3(simd_dot(delta, row), simd_dot(delta, column), simd_dot(delta, simd_cross(row, column))) / resolution
        var low = SIMD3<Int>.zero, high = SIMD3<Int>.zero, fraction = SIMD3<Double>.zero
        for axis in 0..<3 {
            guard coordinate[axis] >= 0, coordinate[axis] <= Double(dimensions[axis] - 1) else { return nil }
            low[axis] = Int(floor(coordinate[axis]))
            high[axis] = min(low[axis] + 1, dimensions[axis] - 1)
            fraction[axis] = coordinate[axis] - Double(low[axis])
        }
        var result = SIMD3<Double>.zero
        for k in 0...1 { for j in 0...1 { for i in 0...1 {
            let weight = (i == 0 ? 1-fraction.x : fraction.x) * (j == 0 ? 1-fraction.y : fraction.y) * (k == 0 ? 1-fraction.z : fraction.z)
            guard weight > 0 else { continue }
            guard let v = vector(i: i == 0 ? low.x : high.x, j: j == 0 ? low.y : high.y, k: k == 0 ? low.z : high.z) else { return nil }
            result += SIMD3<Double>(v) * weight
        } } }
        return result
    }
}
