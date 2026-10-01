//
//  J2KPart2ComponentTransform.swift
//  DicomJPEG2000
//
//  ISO/IEC 15444-2 | ITU-T T.801 Annex J array-based multiple component transformations as signalled by the
//  MCT (0xFF75), MCC (0xFF77), MCO (0xFF76) and CBD (0xFF78) marker segments (T.801 Figures A.6–A.9). The byte
//  layout follows the standard as implemented by the OpenJPEG reference writer (`opj_j2k_write_mct_record`,
//  `_mcc_record`, `_mco`, `_cbd`); OpenJPEG itself cannot decode the transforms it writes (its reader rejects the
//  SGcod value 2 of T.801 Table A.8), so the inverse is implemented here from the marker semantics: for every stage
//  of the MCO ordering, the decorrelation array of the collection is the *decoding* matrix applied to the coded
//  components (`out = M · in`), the offset array replaces the DC level shift of the produced components, and the
//  CBD marker carries the bit depths of the reconstructed components (the SIZ depths describe the coded ones).
//  Added for Isis issue #2331; wavelet-based (Xmcci = 0) and dependency (Ymct = 0) transforms are recognised but
//  refused typed.
//

import Foundation

/// One MCT marker segment: an array of decorrelation matrix coefficients, dependency coefficients or offsets.
struct J2KPart2MCTArray: Sendable, Equatable {
    enum Kind: Int, Sendable {
        case dependency = 0
        case decorrelation = 1
        case offset = 2
    }

    enum Element: Int, Sendable {
        case int16 = 0
        case int32 = 1
        case float32 = 2
        case float64 = 3

        var byteCount: Int {
            switch self {
            case .int16: return 2
            case .int32, .float32: return 4
            case .float64: return 8
            }
        }
    }

    let index: Int
    let kind: Kind
    let element: Element
    let payload: Data

    var elementCount: Int { payload.count / element.byteCount }

    /// The array values in big-endian storage order.
    func values() -> [Double] {
        let bytes = [UInt8](payload)
        var out: [Double] = []
        out.reserveCapacity(elementCount)
        var cursor = 0
        while cursor + element.byteCount <= bytes.count {
            switch element {
            case .int16:
                out.append(Double(Int16(bitPattern: UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1]))))
            case .int32:
                let word = UInt32(bytes[cursor]) << 24 | UInt32(bytes[cursor + 1]) << 16 | UInt32(bytes[cursor + 2]) << 8 | UInt32(bytes[cursor + 3])
                out.append(Double(Int32(bitPattern: word)))
            case .float32:
                let word = UInt32(bytes[cursor]) << 24 | UInt32(bytes[cursor + 1]) << 16 | UInt32(bytes[cursor + 2]) << 8 | UInt32(bytes[cursor + 3])
                out.append(Double(Float(bitPattern: word)))
            case .float64:
                var word: UInt64 = 0
                for offset in 0..<8 { word = word << 8 | UInt64(bytes[cursor + offset]) }
                out.append(Double(bitPattern: word))
            }
            cursor += element.byteCount
        }
        return out
    }

    /// Parses the segment body after Lmct: Zmct (2), Imct (2: index bits 0–7, Ymct kind bits 8–9, element type bits
    /// 10–11), Ymct (2), then the array bytes. Multi-part arrays (Zmct or Ymct ≠ 0) are refused.
    static func parse(_ body: Data) throws -> J2KPart2MCTArray {
        let bytes = [UInt8](body)
        guard bytes.count >= 6 else { throw J2KError.decodingError("MCT marker segment is too short") }
        let zmct = Int(bytes[0]) << 8 | Int(bytes[1])
        let imct = Int(bytes[2]) << 8 | Int(bytes[3])
        let ymct = Int(bytes[4]) << 8 | Int(bytes[5])
        guard zmct == 0, ymct == 0 else {
            throw J2KError.notImplemented("MCT arrays split across several marker segments are not supported")
        }
        guard let kind = Kind(rawValue: (imct >> 8) & 0x3), let element = Element(rawValue: (imct >> 10) & 0x3) else {
            throw J2KError.decodingError("MCT marker segment uses a reserved array or element type")
        }
        let payload = Data(bytes[6...])
        guard payload.count % element.byteCount == 0 else {
            throw J2KError.decodingError("MCT array size is not a multiple of its element size")
        }
        return J2KPart2MCTArray(index: imct & 0xFF, kind: kind, element: element, payload: payload)
    }

    /// The complete marker segment (marker + length + body).
    func encoded() -> Data {
        var data = Data([0xFF, 0x75])
        let length = 2 + 6 + payload.count
        data.append(UInt8(length >> 8)); data.append(UInt8(length & 0xFF))
        data.append(contentsOf: [0, 0])
        let imct = (index & 0xFF) | (kind.rawValue << 8) | (element.rawValue << 10)
        data.append(UInt8(imct >> 8)); data.append(UInt8(imct & 0xFF))
        data.append(contentsOf: [0, 0])
        data.append(payload)
        return data
    }

    static func float32(index: Int, kind: Kind, values: [Double]) -> J2KPart2MCTArray {
        var payload = Data(capacity: values.count * 4)
        for value in values {
            let word = Float(value).bitPattern
            payload.append(contentsOf: [UInt8(word >> 24), UInt8((word >> 16) & 0xFF), UInt8((word >> 8) & 0xFF), UInt8(word & 0xFF)])
        }
        return J2KPart2MCTArray(index: index, kind: kind, element: .float32, payload: payload)
    }

    static func int32(index: Int, kind: Kind, values: [Int32]) -> J2KPart2MCTArray {
        var payload = Data(capacity: values.count * 4)
        for value in values {
            let word = UInt32(bitPattern: value)
            payload.append(contentsOf: [UInt8(word >> 24), UInt8((word >> 16) & 0xFF), UInt8((word >> 8) & 0xFF), UInt8(word & 0xFF)])
        }
        return J2KPart2MCTArray(index: index, kind: kind, element: .int32, payload: payload)
    }
}

/// One component collection of an MCC marker segment.
struct J2KPart2ComponentCollection: Sendable, Equatable {
    enum Kind: Int, Sendable {
        case waveletBased = 0
        case arrayBased = 1
    }

    let kind: Kind
    let inputs: [Int]
    let outputs: [Int]
    /// Tmcc for array-based collections: decorrelation array index (bits 0–7), offset array index (bits 8–15),
    /// reversible flag (bit 16). Wavelet-based collections keep the raw value.
    let transformParameters: Int

    var decorrelationIndex: Int { transformParameters & 0xFF }
    var offsetIndex: Int { (transformParameters >> 8) & 0xFF }
    var isReversible: Bool { (transformParameters >> 16) & 1 == 1 }
}

/// An MCC marker segment: Zmcc (2), Imcc (1), Ymcc (2), Qmcc (2), then per collection Xmcci (1), Nmcci (2) with
/// bit 15 selecting 16-bit component indices, the input indices, Mmcci (2), the output indices and Tmcci (3).
struct J2KPart2MCCMarker: Sendable, Equatable {
    let index: Int
    let collections: [J2KPart2ComponentCollection]

    static func parse(_ body: Data) throws -> J2KPart2MCCMarker {
        let bytes = [UInt8](body)
        var cursor = 0
        func need(_ count: Int) throws {
            guard cursor + count <= bytes.count else { throw J2KError.decodingError("MCC marker segment is truncated") }
        }
        func u8() throws -> Int { try need(1); defer { cursor += 1 }; return Int(bytes[cursor]) }
        func u16() throws -> Int { try need(2); defer { cursor += 2 }; return Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1]) }
        let zmcc = try u16()
        let index = try u8()
        let ymcc = try u16()
        guard zmcc == 0, ymcc == 0 else {
            throw J2KError.notImplemented("MCC marker segments split across several parts are not supported")
        }
        let count = try u16()
        var collections: [J2KPart2ComponentCollection] = []
        for _ in 0..<count {
            let xmcc = try u8()
            guard let kind = J2KPart2ComponentCollection.Kind(rawValue: xmcc & 0x1) else {
                throw J2KError.decodingError("MCC collection uses a reserved transformation type")
            }
            let nmcc = try u16()
            let inputWide = nmcc & 0x8000 != 0
            var inputs: [Int] = []
            for _ in 0..<(nmcc & 0x7FFF) { inputs.append(inputWide ? try u16() : try u8()) }
            let mmcc = try u16()
            let outputWide = mmcc & 0x8000 != 0
            var outputs: [Int] = []
            for _ in 0..<(mmcc & 0x7FFF) { outputs.append(outputWide ? try u16() : try u8()) }
            try need(3)
            let tmcc = Int(bytes[cursor]) << 16 | Int(bytes[cursor + 1]) << 8 | Int(bytes[cursor + 2])
            cursor += 3
            collections.append(.init(kind: kind, inputs: inputs, outputs: outputs, transformParameters: tmcc))
        }
        guard cursor == bytes.count else { throw J2KError.decodingError("MCC marker segment has trailing bytes") }
        return J2KPart2MCCMarker(index: index, collections: collections)
    }

    func encoded() -> Data {
        var body = Data([0, 0, UInt8(index & 0xFF), 0, 0])
        body.append(UInt8(collections.count >> 8)); body.append(UInt8(collections.count & 0xFF))
        for collection in collections {
            body.append(UInt8(collection.kind.rawValue))
            let wide = (collection.inputs + collection.outputs).contains { $0 > 0xFF }
            for list in [collection.inputs, collection.outputs] {
                let header = list.count | (wide ? 0x8000 : 0)
                body.append(UInt8(header >> 8)); body.append(UInt8(header & 0xFF))
                for component in list {
                    if wide { body.append(UInt8(component >> 8)) }
                    body.append(UInt8(component & 0xFF))
                }
            }
            let tmcc = collection.transformParameters
            body.append(contentsOf: [UInt8((tmcc >> 16) & 0xFF), UInt8((tmcc >> 8) & 0xFF), UInt8(tmcc & 0xFF)])
        }
        var data = Data([0xFF, 0x77])
        let length = body.count + 2
        data.append(UInt8(length >> 8)); data.append(UInt8(length & 0xFF))
        data.append(body)
        return data
    }
}

/// An MCO marker segment: Nmco (1) then one MCC index per transformation stage.
struct J2KPart2MCOMarker: Sendable, Equatable {
    let stages: [Int]

    static func parse(_ body: Data) throws -> J2KPart2MCOMarker {
        let bytes = [UInt8](body)
        guard let count = bytes.first, bytes.count == 1 + Int(count) else {
            throw J2KError.decodingError("MCO marker segment length does not match its stage count")
        }
        return J2KPart2MCOMarker(stages: bytes.dropFirst().map(Int.init))
    }

    func encoded() -> Data {
        var data = Data([0xFF, 0x76])
        let length = 2 + 1 + stages.count
        data.append(UInt8(length >> 8)); data.append(UInt8(length & 0xFF))
        data.append(UInt8(stages.count))
        data.append(contentsOf: stages.map { UInt8($0 & 0xFF) })
        return data
    }
}

/// A CBD marker segment: Ncbd (2; bit 15 = one depth for every component) then BDcbd bytes (bit 7 sign, bits 0–6
/// depth − 1) describing the reconstructed components.
struct J2KPart2CBDMarker: Sendable, Equatable {
    struct Depth: Sendable, Equatable {
        let bitDepth: Int
        let signed: Bool
    }

    let depths: [Depth]

    static func parse(_ body: Data, componentCount: Int) throws -> J2KPart2CBDMarker {
        let bytes = [UInt8](body)
        guard bytes.count >= 3 else { throw J2KError.decodingError("CBD marker segment is too short") }
        let ncbd = Int(bytes[0]) << 8 | Int(bytes[1])
        let shared = ncbd & 0x8000 != 0
        let count = ncbd & 0x7FFF
        let entries = Array(bytes.dropFirst(2))
        if shared {
            guard entries.count == 1 else { throw J2KError.decodingError("CBD marker segment with a shared depth must carry one entry") }
            let depth = Depth(bitDepth: Int(entries[0] & 0x7F) + 1, signed: entries[0] & 0x80 != 0)
            return J2KPart2CBDMarker(depths: Array(repeating: depth, count: max(count, componentCount)))
        }
        guard entries.count == count, count == componentCount else {
            throw J2KError.decodingError("CBD marker segment describes \(count) components, the codestream has \(componentCount)")
        }
        return J2KPart2CBDMarker(depths: entries.map { Depth(bitDepth: Int($0 & 0x7F) + 1, signed: $0 & 0x80 != 0) })
    }

    func encoded() -> Data {
        var data = Data([0xFF, 0x78])
        let length = 2 + 2 + depths.count
        data.append(UInt8(length >> 8)); data.append(UInt8(length & 0xFF))
        data.append(UInt8(depths.count >> 8)); data.append(UInt8(depths.count & 0xFF))
        for depth in depths { data.append(UInt8((depth.signed ? 0x80 : 0) | ((depth.bitDepth - 1) & 0x7F))) }
        return data
    }
}

/// The Annex J transforms of one codestream (main header) and their decoder-side application.
struct J2KPart2ComponentTransforms: Sendable, Equatable {
    var arrays: [J2KPart2MCTArray] = []
    var collections: [J2KPart2MCCMarker] = []
    var order: J2KPart2MCOMarker?
    var bitDepths: J2KPart2CBDMarker?

    /// Whether the codestream applies an Annex J transformation (an MCO ordering with at least one stage).
    var isActive: Bool { !(order?.stages.isEmpty ?? true) }

    /// Highest component-count the decoder accepts for one transformation (memory bound: n² doubles per matrix).
    static let maximumComponents = 4096

    struct Stage: Sendable, Equatable {
        let collection: J2KPart2ComponentCollection
        /// Row-major decoding matrix (`outputs.count` × `inputs.count`).
        let matrix: [Double]
        /// Offsets for the produced components, nil when the collection has no offset array.
        let offsets: [Double]?
    }

    /// Validates the marker set against `componentCount` and resolves every MCO stage; wavelet-based and
    /// dependency transforms are refused typed.
    func resolvedStages(componentCount: Int) throws -> [Stage] {
        guard let order else { return [] }
        guard componentCount <= Self.maximumComponents else {
            throw J2KError.notImplemented("\(componentCount) components exceed the \(Self.maximumComponents)-component transformation bound")
        }
        var stages: [Stage] = []
        for stageIndex in order.stages {
            guard let mcc = collections.first(where: { $0.index == stageIndex }) else {
                throw J2KError.decodingError("MCO references component collection \(stageIndex), which is not defined")
            }
            for collection in mcc.collections {
                guard collection.kind == .arrayBased else {
                    throw J2KError.notImplemented("wavelet-based multiple component transformations (T.801 J.3) are not supported")
                }
                let inputs = collection.inputs, outputs = collection.outputs
                guard !inputs.isEmpty, !outputs.isEmpty,
                      inputs.allSatisfy({ $0 < componentCount }), outputs.allSatisfy({ $0 < componentCount }),
                      Set(inputs).count == inputs.count, Set(outputs).count == outputs.count else {
                    throw J2KError.decodingError("component collection indices are outside the codestream's \(componentCount) components")
                }
                guard let array = arrays.first(where: { $0.index == collection.decorrelationIndex }) else {
                    throw J2KError.decodingError("component collection references MCT array \(collection.decorrelationIndex), which is not defined")
                }
                guard array.kind == .decorrelation else {
                    throw J2KError.notImplemented("dependency multiple component transformations (T.801 J.3.2) are not supported")
                }
                let matrix = array.values()
                guard matrix.count == inputs.count * outputs.count else {
                    throw J2KError.decodingError("MCT array \(array.index) holds \(matrix.count) coefficients for a \(outputs.count)×\(inputs.count) collection")
                }
                guard matrix.allSatisfy(\.isFinite) else { throw J2KError.decodingError("MCT array \(array.index) contains non-finite coefficients") }
                var offsets: [Double]?
                if collection.offsetIndex != 0 {
                    guard let offsetArray = arrays.first(where: { $0.index == collection.offsetIndex }) else {
                        throw J2KError.decodingError("component collection references offset array \(collection.offsetIndex), which is not defined")
                    }
                    guard offsetArray.kind == .offset else { throw J2KError.decodingError("MCT array \(offsetArray.index) is not an offset array") }
                    let values = offsetArray.values()
                    guard values.count == outputs.count else {
                        throw J2KError.decodingError("offset array \(offsetArray.index) holds \(values.count) values for \(outputs.count) components")
                    }
                    offsets = values
                }
                stages.append(Stage(collection: collection, matrix: matrix, offsets: offsets))
            }
        }
        return stages
    }

    /// Applies the inverse transformation to the level-shifted coded components (in place) and returns the DC
    /// shift to add to every component afterwards: the offset array where a stage defines one, otherwise the Part 1
    /// shift of the coded component (2^(depth−1) for unsigned components).
    func applyInverse(
        to components: inout [[Double]],
        codedDepths: [(bitDepth: Int, signed: Bool)]
    ) throws -> [Double] {
        guard codedDepths.count == components.count else {
            throw J2KError.invalidParameter("Coded depths must match the component count")
        }
        var shifts = codedDepths.map { $0.signed ? 0.0 : Double(1 << ($0.bitDepth - 1)) }
        for stage in try resolvedStages(componentCount: components.count) {
            let inputs = stage.collection.inputs, outputs = stage.collection.outputs
            let sampleCount = components[inputs[0]].count
            guard inputs.allSatisfy({ components[$0].count == sampleCount }),
                  outputs.allSatisfy({ components[$0].count == sampleCount }) else {
                throw J2KError.decodingError("the components of a collection do not share their sample count")
            }
            let n = inputs.count, m = outputs.count
            var produced = [[Double]](repeating: [Double](repeating: 0, count: sampleCount), count: m)
            let matrix = stage.matrix
            let reversible = stage.collection.isReversible
            var input = [Double](repeating: 0, count: n)
            for sample in 0..<sampleCount {
                for j in 0..<n { input[j] = components[inputs[j]][sample] }
                for i in 0..<m {
                    var sum = 0.0
                    let row = i * n
                    for j in 0..<n { sum += matrix[row + j] * input[j] }
                    produced[i][sample] = reversible ? sum.rounded() : sum
                }
            }
            for (k, component) in outputs.enumerated() {
                components[component] = produced[k]
                if let offsets = stage.offsets { shifts[component] = offsets[k] }
            }
        }
        return shifts
    }
}

/// Encoder-side description of one array-based transformation over all components (T.801 J.2, single stage).
struct J2KPart2EncodingMarkers: Sendable {
    /// Reconstructed component depths (CBD).
    let outputDepths: [J2KPart2CBDMarker.Depth]
    /// Decoding matrix (inverse of the forward matrix), row-major n×n.
    let decodingMatrix: [Double]
    /// DC offsets of the reconstructed components (2^(depth−1) for unsigned, 0 for signed).
    let offsets: [Int32]
    /// Whether the transformation is reversible (integer forward and decoding matrices).
    let reversible: Bool

    /// The marker segments in codestream order: CBD, MCT (decorrelation, index 1), MCT (offsets, index 2), MCC, MCO.
    func encodedSegments() -> Data {
        let n = outputDepths.count
        var data = J2KPart2CBDMarker(depths: outputDepths).encoded()
        if reversible, decodingMatrix.allSatisfy({ $0 == $0.rounded() && abs($0) < 2_147_483_648 }) {
            data.append(J2KPart2MCTArray.int32(index: 1, kind: .decorrelation, values: decodingMatrix.map { Int32($0) }).encoded())
        } else {
            data.append(J2KPart2MCTArray.float32(index: 1, kind: .decorrelation, values: decodingMatrix).encoded())
        }
        data.append(J2KPart2MCTArray.int32(index: 2, kind: .offset, values: offsets).encoded())
        let collection = J2KPart2ComponentCollection(
            kind: .arrayBased, inputs: Array(0..<n), outputs: Array(0..<n),
            transformParameters: 1 | (2 << 8) | ((reversible ? 1 : 0) << 16)
        )
        data.append(J2KPart2MCCMarker(index: 1, collections: [collection]).encoded())
        data.append(J2KPart2MCOMarker(stages: [1]).encoded())
        return data
    }

    /// Bits needed for the forward-transformed components: the level-shifted inputs span ±2^(depth−1), so a row
    /// grows by log2 of its absolute coefficient sum. One depth (the widest row) is used for every coded component
    /// so the single QCD marker segment signals enough bit-planes for all of them; every coded component is signed.
    static func codedDepth(forwardMatrix: [Double], size: Int, inputDepth: Int) -> [Int] {
        let growth = (0..<size).map { row -> Int in
            let gain = (0..<size).reduce(0.0) { $0 + abs(forwardMatrix[row * size + $1]) }
            return gain <= 1 ? 0 : Int(ceil(log2(gain)))
        }.max() ?? 0
        return Array(repeating: min(38, inputDepth + growth), count: size)
    }
}
