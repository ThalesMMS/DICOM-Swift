/// Stored labels of one LABELMAP frame, kept at the width the object uses:
/// 8 bits for up to 255 labels, 16 bits above. Keeping the stored width halves
/// the memory of a typical label map; `widened` allocates a 16-bit copy.
public enum DicomLabelmapPlane: Sendable, ExpressibleByArrayLiteral {
    case uint8([UInt8])
    case uint16([UInt16])

    public init(arrayLiteral elements: UInt16...) {
        self = .uint16(elements)
    }

    public var count: Int {
        switch self {
        case .uint8(let values): values.count
        case .uint16(let values): values.count
        }
    }

    public var bitsAllocated: Int {
        switch self {
        case .uint8: 8
        case .uint16: 16
        }
    }

    public subscript(index: Int) -> UInt16 {
        switch self {
        case .uint8(let values): UInt16(values[index])
        case .uint16(let values): values[index]
        }
    }

    /// A 16-bit copy of the labels.
    public var widened: [UInt16] {
        switch self {
        case .uint8(let values): values.map(UInt16.init)
        case .uint16(let values): values
        }
    }

    /// The largest stored label, or 0 for an empty plane.
    public var maximum: UInt16 {
        switch self {
        case .uint8(let values): UInt16(values.max() ?? 0)
        case .uint16(let values): values.max() ?? 0
        }
    }

    /// Adds one to `counts[label]` for every voxel. `counts` needs an entry for
    /// every stored value: 256 for an 8-bit plane, 65,536 for a 16-bit plane.
    public func accumulateHistogram(into counts: inout [Int]) {
        counts.withUnsafeMutableBufferPointer { counts in
            switch self {
            case .uint8(let values):
                values.withUnsafeBufferPointer { for value in $0 { counts[Int(value)] += 1 } }
            case .uint16(let values):
                values.withUnsafeBufferPointer { for value in $0 { counts[Int(value)] += 1 } }
            }
        }
    }

    /// The voxels of one label as `label`, every other voxel as 0.
    func isolating(_ label: UInt16) -> [UInt16] {
        switch self {
        case .uint8(let values):
            guard label <= UInt16(UInt8.max) else { return [UInt16](repeating: 0, count: values.count) }
            let stored = UInt8(label)
            return values.map { $0 == stored ? label : 0 }
        case .uint16(let values):
            return values.map { $0 == label ? label : 0 }
        }
    }
}

extension DicomLabelmapPlane: Equatable {
    /// Planes are equal when they hold the same labels, whatever width stores them.
    public static func == (lhs: DicomLabelmapPlane, rhs: DicomLabelmapPlane) -> Bool {
        switch (lhs, rhs) {
        case (.uint8(let left), .uint8(let right)):
            return left == right
        case (.uint16(let left), .uint16(let right)):
            return left == right
        default:
            guard lhs.count == rhs.count else { return false }
            return (0..<lhs.count).allSatisfy { lhs[$0] == rhs[$0] }
        }
    }
}
