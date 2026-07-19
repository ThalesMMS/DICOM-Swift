import Foundation

extension Data {
    func dicomIntegerIfPresent<T: FixedWidthInteger>(
        at offset: Int,
        as type: T.Type,
        littleEndian: Bool
    ) -> T? {
        let valueSize = MemoryLayout<T>.size
        guard offset >= 0, offset <= count - valueSize else { return nil }
        let rawValue: T = withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: type)
        }
        return littleEndian ? T(littleEndian: rawValue) : T(bigEndian: rawValue)
    }

    func dicomInteger<T: FixedWidthInteger>(
        at offset: Int,
        as type: T.Type,
        littleEndian: Bool
    ) -> T {
        guard let value = dicomIntegerIfPresent(at: offset, as: type, littleEndian: littleEndian) else {
            preconditionFailure("DICOM integer read exceeds data bounds")
        }
        return value
    }

    func dicomIntegerValues<T: FixedWidthInteger>(
        as type: T.Type,
        littleEndian: Bool
    ) -> [T] {
        let valueSize = MemoryLayout<T>.size
        guard count.isMultiple(of: valueSize) else { return [] }
        let valueCount = count / valueSize
        return withUnsafeBytes { bytes in
            (0..<valueCount).map { index in
                let rawValue = bytes.loadUnaligned(fromByteOffset: index * valueSize, as: type)
                return littleEndian ? T(littleEndian: rawValue) : T(bigEndian: rawValue)
            }
        }
    }

    func dicomFloat32Values(littleEndian: Bool) -> [Float] {
        dicomIntegerValues(as: UInt32.self, littleEndian: littleEndian).map(Float.init(bitPattern:))
    }

    func dicomFloat64Values(littleEndian: Bool) -> [Double] {
        dicomIntegerValues(as: UInt64.self, littleEndian: littleEndian).map(Double.init(bitPattern:))
    }
}
