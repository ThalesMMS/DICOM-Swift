import simd

/// PS3.3 C.8.8.3.2: relative offsets follow row × column; absolute-Z requires transverse planes.
public enum DicomRTDoseGridFrameOffsets: Equatable, Sendable {
    case none
    case relative([Double])
    case absoluteZ([Double])

    public var values: [Double] {
        switch self {
        case .none: return []
        case .relative(let values), .absoluteZ(let values): return values
        }
    }

    public var spacings: [Double] { zip(values.dropFirst(), values).map { $0 - $1 } }

    public var isMonotonic: Bool {
        guard values.allSatisfy(\.isFinite) else { return false }
        return spacings.allSatisfy { $0 > 0 } || spacings.allSatisfy { $0 < 0 }
    }

    /// Absolute tolerance in millimetres; descending offsets are supported.
    public func isUniform(tolerance: Double = 1e-6) -> Bool {
        guard tolerance.isFinite, tolerance >= 0, isMonotonic else { return false }
        guard let first = spacings.first else { return true }
        return spacings.allSatisfy { abs($0 - first) <= tolerance }
    }

    public func planePositions(imagePosition: SIMD3<Double>, orientation: DicomPlaneOrientation) -> [SIMD3<Double>]? {
        guard (0..<3).allSatisfy({ imagePosition[$0].isFinite && orientation.row[$0].isFinite && orientation.column[$0].isFinite }) else {
            return nil
        }
        switch self {
        case .none: return [imagePosition]
        case .relative(let values):
            guard values.first == 0, values.allSatisfy(\.isFinite) else { return nil }
            let normal = simd_cross(orientation.row, orientation.column)
            guard simd_length_squared(normal) > 0 else { return nil }
            return values.map { imagePosition + $0 * normal }
        case .absoluteZ(let values):
            guard Self.isTransverse(orientation), values.first == imagePosition.z,
                  values.allSatisfy(\.isFinite) else { return nil }
            return values.map { SIMD3(imagePosition.x, imagePosition.y, $0) }
        }
    }

    static func isTransverse(_ orientation: DicomPlaneOrientation) -> Bool {
        orientation.row == SIMD3(1, 0, 0) && orientation.column == SIMD3(0, 1, 0)
    }
}
