import Foundation

package enum DicomDataValueDecoder {
    package static func binaryValue(
        for vr: DicomVR,
        data: Data,
        littleEndian: Bool
    ) -> DicomDataValue? {
        switch vr {
        case .FD, .OD:
            return .floats(data.dicomFloat64Values(littleEndian: littleEndian))
        case .FL, .OF:
            return .floats(data.dicomFloat32Values(littleEndian: littleEndian).map(Double.init))
        case .SL:
            return .signedIntegers(
                data.dicomIntegerValues(as: UInt32.self, littleEndian: littleEndian)
                    .map { Int(Int32(bitPattern: $0)) }
            )
        case .SV:
            return .signedIntegers(data.dicomIntegerValues(as: Int64.self, littleEndian: littleEndian).map(Int.init))
        case .UV:
            return .unsignedIntegers(data.dicomIntegerValues(as: UInt64.self, littleEndian: littleEndian).map(UInt.init))
        case .SS:
            return .signedIntegers(
                data.dicomIntegerValues(as: UInt16.self, littleEndian: littleEndian)
                    .map { Int(Int16(bitPattern: $0)) }
            )
        case .OL, .UL:
            return .unsignedIntegers(
                data.dicomIntegerValues(as: UInt32.self, littleEndian: littleEndian).map(UInt.init)
            )
        case .US:
            return .unsignedIntegers(
                data.dicomIntegerValues(as: UInt16.self, littleEndian: littleEndian).map(UInt.init)
            )
        case .AT:
            let components = data.dicomIntegerValues(as: UInt16.self, littleEndian: littleEndian)
            guard components.count.isMultiple(of: 2) else { return .empty }
            return .unsignedIntegers(stride(from: 0, to: components.count, by: 2).map { index in
                UInt(components[index]) << 16 | UInt(components[index + 1])
            })
        case .OB, .OW, .OV, .UN:
            return .bytes(Data(data))
        default:
            return nil
        }
    }
}
