//
//  J2KPart2ComponentTransform.swift
//  DicomJPEG2000
//
//  ISO/IEC 15444-2 | ITU-T T.801 Annex J array-based multiple component transformations as
//  signalled by the MCT (0xFF74), MCC (0xFF75), MCO (0xFF77) and CBD (0xFF78) marker segments
//  (T.801 Table A.2, Figures A.6–A.9; the same codes as OpenJPEG's `j2k.h` and Kakadu). Until issue
//  #3246 the codec wrote the J2KSwift-inherited codes MCT 0xFF75, MCC 0xFF77 and MCO 0xFF76 (the
//  NLT code), which no other decoder reads; such a codestream is still read
//  (`J2KPart2LegacyMarkerLayout`). The byte layout follows the standard as implemented by the
//  OpenJPEG reference writer (`opj_j2k_write_mct_record`, `_mcc_record`, `_mco`, `_cbd`) and
//  Kakadu; OpenJPEG itself cannot decode the transforms (its reader rejects the SGcod value 2 of
//  T.801 Table A.8). The inverse (synthesis) kernels of T.801 Annex J.2/J.3, checked against Kakadu
//  8.4.1 (`kdu_expand`, issue #3246): - Xmcc 0, array-based dependency transform: out[0] = in[0] +
//  o[0]; out[k] = in[k] + o[k] + P(out[0..<k]), where P is the row of strictly-lower coefficients
//  (irreversible: real sum; reversible: integer sum rounded by the power-of-two divisor that closes
//  each row, (Σ + d/2) >> log2 d). The predictions use the offset outputs. - Xmcc 1, array-based
//  decorrelation transform: irreversible `out = M · in + o` with an M×N matrix; reversible ones are
//  SERM (single-row elementary reversible matrix) factorisations of (M + 1) integer rows. - Xmcc
//  2/3, wavelet-based transforms: recognised and refused typed. The CBD marker carries the bit
//  depths of the reconstructed components (the SIZ depths describe the coded ones). Added for IsiX
//  issue #2331; dependency, SERM and pass-through collections added for issue #3246, when the own
//  `.92` writer moved from an integer decorrelation matrix (not a T.801 reversible decorrelation)
//  to the reversible dependency transform.
//
//  Thales Matheus Mendonça Santos — September 2026
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

    /// One MCT marker segment of a possibly multi-part array.
    struct Segment: Sendable, Equatable {
        let index: Int
        let kind: Kind
        let element: Element
        /// Zmct: the part number.
        let part: Int
        /// Ymct of part 0: the last part number; nil for the other parts.
        let lastPart: Int?
        let payload: Data
    }

    /// Parses the segment body after Lmct: Zmct (2), Imct (2: index bits 0–7, Ymct kind bits 8–9, element type bits
    /// 10–11), Ymct (2, only in part 0), then the array bytes. Large arrays are split into parts (Kakadu splits them
    /// near 16 KiB); `J2KPart2ComponentTransforms.add(mctSegment:)` joins them.
    static func parseSegment(_ body: Data) throws -> Segment {
        let bytes = [UInt8](body)
        guard bytes.count >= 4 else { throw J2KError.decodingError("MCT marker segment is too short") }
        let zmct = Int(bytes[0]) << 8 | Int(bytes[1])
        let imct = Int(bytes[2]) << 8 | Int(bytes[3])
        guard let kind = Kind(rawValue: (imct >> 8) & 0x3), let element = Element(rawValue: (imct >> 10) & 0x3) else {
            throw J2KError.decodingError("MCT marker segment uses a reserved array or element type")
        }
        var lastPart: Int?
        var start = 4
        if zmct == 0 {
            guard bytes.count >= 6 else { throw J2KError.decodingError("MCT marker segment is too short") }
            lastPart = Int(bytes[4]) << 8 | Int(bytes[5])
            start = 6
        }
        return Segment(index: imct & 0xFF, kind: kind, element: element, part: zmct, lastPart: lastPart, payload: Data(bytes[start...]))
    }

    /// Parses a single-part array (Zmct = Ymct = 0).
    static func parse(_ body: Data) throws -> J2KPart2MCTArray {
        let segment = try parseSegment(body)
        guard segment.part == 0, segment.lastPart == 0 else {
            throw J2KError.decodingError("MCT marker segment is one part of a multi-part array")
        }
        return try J2KPart2MCTArray(index: segment.index, kind: segment.kind, element: segment.element, checkedPayload: segment.payload)
    }

    init(index: Int, kind: Kind, element: Element, payload: Data) {
        self.index = index
        self.kind = kind
        self.element = element
        self.payload = payload
    }

    /// Validating initializer for parsed arrays: throws when the payload is not a whole number of elements.
    init(index: Int, kind: Kind, element: Element, checkedPayload payload: Data) throws {
        guard payload.count % element.byteCount == 0 else {
            throw J2KError.decodingError("MCT array size is not a multiple of its element size")
        }
        self.init(index: index, kind: kind, element: element, payload: payload)
    }

    /// The complete marker segment (marker + length + body).
    func encoded() -> Data {
        var data = Self.marker(.mct)
        let length = 2 + 6 + payload.count
        data.append(UInt8(length >> 8)); data.append(UInt8(length & 0xFF))
        data.append(contentsOf: [0, 0])
        let imct = (index & 0xFF) | (kind.rawValue << 8) | (element.rawValue << 10)
        data.append(UInt8(imct >> 8)); data.append(UInt8(imct & 0xFF))
        data.append(contentsOf: [0, 0])
        data.append(payload)
        return data
    }

    /// The two marker bytes of an Annex J segment, from `J2KMarker` (T.801 Table A.2).
    static func marker(_ marker: J2KMarker) -> Data {
        Data([UInt8(marker.rawValue >> 8), UInt8(marker.rawValue & 0xFF)])
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
    /// Xmcci (T.801 Table A.36): 0 array-based dependency, 1 array-based decorrelation, 2 and 3 wavelet-based.
    enum Kind: Int, Sendable {
        case dependency = 0
        case decorrelation = 1
        case waveletBased = 3

        /// Maps the low two bits of Xmcci to a kind; both wavelet-based codes (2 and 3) become `.waveletBased`.
        init(xmcc: Int) {
            switch xmcc & 0x3 {
            case 0: self = .dependency
            case 1: self = .decorrelation
            default: self = .waveletBased
            }
        }
    }

    let kind: Kind
    let inputs: [Int]
    let outputs: [Int]
    /// Tmcc for array-based collections: transformation (dependency or decorrelation) array index (bits 0–7), offset
    /// array index (bits 8–15), reversible flag (bit 16). Wavelet-based collections keep the raw value.
    let transformParameters: Int

    var isArrayBased: Bool { kind != .waveletBased }
    var decorrelationIndex: Int { transformParameters & 0xFF }
    var offsetIndex: Int { (transformParameters >> 8) & 0xFF }
    var isReversible: Bool { (transformParameters >> 16) & 1 == 1 }
}

/// An MCC marker segment: Zmcc (2), Imcc (1), Ymcc (2), Qmcc (2), then per collection Xmcci (1), Nmcci (2) with
/// bit 15 selecting 16-bit component indices, the input indices, Mmcci (2), the output indices and Tmcci (3).
struct J2KPart2MCCMarker: Sendable, Equatable {
    let index: Int
    let collections: [J2KPart2ComponentCollection]

    /// Parses an MCC marker segment body; refuses segments split across several parts, truncated bodies and trailing
    /// bytes.
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
            let kind = J2KPart2ComponentCollection.Kind(xmcc: try u8())
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

    /// The complete MCC marker segment (marker + length + body); component indices are written 16-bit when any exceeds
    /// 255.
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
        var data = J2KPart2MCTArray.marker(.mcc)
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
        var data = J2KPart2MCTArray.marker(.mco)
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

    /// The complete CBD marker segment (marker + length + body), one signed-flag and bit-depth byte per component.
    func encoded() -> Data {
        var data = J2KPart2MCTArray.marker(.cbd)
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
    /// The segments came under the pre-#3246 Isis codes.
    var usesLegacyMarkerCodes = false
    /// Parts of multi-part MCT arrays still waiting for their siblings, keyed by array type and index.
    private var pendingMCTParts: [Int: [J2KPart2MCTArray.Segment]] = [:]

    /// Adds one MCT marker segment; a multi-part array becomes available in `arrays` once all its parts arrived.
    mutating func add(mctSegment body: Data) throws {
        let segment = try J2KPart2MCTArray.parseSegment(body)
        let key = segment.kind.rawValue << 8 | segment.index
        var parts = pendingMCTParts[key, default: []]
        guard !parts.contains(where: { $0.part == segment.part }) else {
            throw J2KError.decodingError("MCT array \(segment.index) repeats part \(segment.part)")
        }
        parts.append(segment)
        guard let last = parts.first(where: { $0.part == 0 })?.lastPart, parts.count == last + 1 else {
            pendingMCTParts[key] = parts
            return
        }
        pendingMCTParts[key] = nil
        let ordered = parts.sorted { $0.part < $1.part }
        guard ordered.map(\.part) == Array(0...last), ordered.allSatisfy({ $0.element == ordered[0].element }) else {
            throw J2KError.decodingError("MCT array \(segment.index) has inconsistent parts")
        }
        let payload = ordered.reduce(into: Data()) { $0.append($1.payload) }
        arrays.append(try J2KPart2MCTArray(index: segment.index, kind: segment.kind, element: ordered[0].element, checkedPayload: payload))
    }

    /// Fails when a multi-part MCT array is missing parts.
    func validateMCTParts() throws {
        if let key = pendingMCTParts.keys.min() {
            throw J2KError.decodingError("MCT array \(key & 0xFF) is missing parts")
        }
    }

    /// Whether the codestream applies an Annex J transformation (an MCO ordering with at least one stage).
    var isActive: Bool { !(order?.stages.isEmpty ?? true) }

    /// Highest component-count the decoder accepts for one transformation (memory bound: n² doubles per matrix).
    static let maximumComponents = 4096

    /// The synthesis kernel of one array-based collection (T.801 J.2 / J.3).
    enum Kernel: Sendable, Equatable {
        /// Transformation index 0: the inputs pass through (missing outputs are 0) before the offsets.
        case passThrough
        /// Irreversible decorrelation: row-major M×N decoding matrix, `out = M · in`.
        case irreversibleMatrix([Double])
        /// Pre-#3246 own `.92` objects: a reversible n×n integer decoding matrix applied with rounding. Not a T.801
        /// reversible decorrelation (those are SERM factorisations); accepted only under the legacy marker codes.
        case legacyIntegerMatrix([Double])
        /// Reversible dependency: per row k ≥ 1 the integer coefficients of out[0..<k] and the log2 divisor.
        case reversibleDependency(rows: [[Int64]], shifts: [Int])
        /// Irreversible dependency: per row k ≥ 1 the coefficients of out[0..<k].
        case irreversibleDependency(rows: [[Double]])
        /// Reversible SERM decorrelation: M + 1 integer rows, the component each row updates and its log2 divisor.
        case reversibleSERM(rows: [[Int64]], targets: [Int], shifts: [Int])
    }

    struct Stage: Sendable, Equatable {
        let collection: J2KPart2ComponentCollection
        let kernel: Kernel
        /// Offsets of the produced components, nil when the collection has no offset array.
        let offsets: [Double]?
    }

    /// The MCT array of `kind` with `index` (T.801 indexes each array type separately).
    func array(_ kind: J2KPart2MCTArray.Kind, index: Int) -> J2KPart2MCTArray? {
        arrays.first { $0.kind == kind && $0.index == index }
    }

    /// Validates the marker set against `componentCount` and resolves every MCO stage; wavelet-based transforms are
    /// refused typed.
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
                guard collection.isArrayBased else {
                    throw J2KError.notImplemented("wavelet-based multiple component transformations (T.801 J.3) are not supported")
                }
                let inputs = collection.inputs, outputs = collection.outputs
                guard !inputs.isEmpty, !outputs.isEmpty,
                      inputs.allSatisfy({ $0 < componentCount }), outputs.allSatisfy({ $0 < componentCount }),
                      Set(inputs).count == inputs.count, Set(outputs).count == outputs.count else {
                    throw J2KError.decodingError("component collection indices are outside the codestream's \(componentCount) components")
                }
                let kernel: Kernel
                if collection.decorrelationIndex == 0 {
                    kernel = .passThrough
                } else {
                    let arrayKind: J2KPart2MCTArray.Kind = collection.kind == .dependency ? .dependency : .decorrelation
                    guard let array = array(arrayKind, index: collection.decorrelationIndex) else {
                        throw J2KError.decodingError("component collection references \(arrayKind) MCT array \(collection.decorrelationIndex), which is not defined")
                    }
                    let values = array.values()
                    guard values.allSatisfy(\.isFinite) else { throw J2KError.decodingError("MCT array \(array.index) contains non-finite coefficients") }
                    kernel = try Self.kernel(
                        kind: collection.kind, reversible: collection.isReversible, values: values,
                        inputs: inputs.count, outputs: outputs.count, legacy: usesLegacyMarkerCodes, index: array.index
                    )
                }
                var offsets: [Double]?
                if collection.offsetIndex != 0 {
                    guard let offsetArray = array(.offset, index: collection.offsetIndex) else {
                        throw J2KError.decodingError("component collection references offset array \(collection.offsetIndex), which is not defined")
                    }
                    let values = offsetArray.values()
                    guard values.count == outputs.count else {
                        throw J2KError.decodingError("offset array \(offsetArray.index) holds \(values.count) values for \(outputs.count) components")
                    }
                    guard values.allSatisfy(\.isFinite) else { throw J2KError.decodingError("offset array \(offsetArray.index) contains non-finite values") }
                    offsets = values
                }
                stages.append(Stage(collection: collection, kernel: kernel, offsets: offsets))
            }
        }
        return stages
    }

    /// Builds the decoder kernel of one collection from its MCT array, checking the coefficient count and, for
    /// reversible arrays, integer coefficients and power-of-two divisors.
    // swiftlint:disable:next function_parameter_count
    static func kernel(
        kind: J2KPart2ComponentCollection.Kind, reversible: Bool, values: [Double], inputs n: Int, outputs m: Int,
        legacy: Bool, index: Int
    ) throws -> Kernel {
        /// The coefficients as integers; throws when a reversible array holds a non-integer value.
        func integers() throws -> [Int64] {
            guard values.allSatisfy({ $0 == $0.rounded() && abs($0) <= Double(Int32.max) }) else {
                throw J2KError.decodingError("reversible MCT array \(index) holds non-integer coefficients")
            }
            return values.map { Int64($0) }
        }
        /// The right shift a reversible divisor stands for; throws unless it is a power of two up to 2^30.
        func shift(_ divisor: Int64) throws -> Int {
            guard divisor > 0, divisor & (divisor - 1) == 0, divisor.trailingZeroBitCount <= 30 else {
                throw J2KError.decodingError("reversible MCT array \(index) uses the divisor \(divisor), which is not a power of two up to 2^30")
            }
            return divisor.trailingZeroBitCount
        }
        /// Throws unless the array holds exactly `count` coefficients.
        func expect(_ count: Int, _ what: String) throws {
            guard values.count == count else {
                throw J2KError.decodingError("MCT array \(index) holds \(values.count) coefficients; a \(what) needs \(count)")
            }
        }
        switch (kind, reversible) {
        case (.dependency, true):
            guard n == m else { throw J2KError.decodingError("a dependency collection maps \(n) components to \(m)") }
            try expect(m * (m + 1) / 2 - 1, "reversible dependency transformation of \(m) components")
            let ints = try integers()
            var rows: [[Int64]] = [[]], shifts = [0], cursor = 0
            for k in stride(from: 1, to: m, by: 1) {
                rows.append(Array(ints[cursor..<(cursor + k)]))
                shifts.append(try shift(ints[cursor + k]))
                cursor += k + 1
            }
            return .reversibleDependency(rows: rows, shifts: shifts)
        case (.dependency, false):
            guard n == m else { throw J2KError.decodingError("a dependency collection maps \(n) components to \(m)") }
            try expect(m * (m - 1) / 2, "irreversible dependency transformation of \(m) components")
            var rows: [[Double]] = [[]], cursor = 0
            for k in stride(from: 1, to: m, by: 1) {
                rows.append(Array(values[cursor..<(cursor + k)]))
                cursor += k
            }
            return .irreversibleDependency(rows: rows)
        case (.decorrelation, true) where legacy:
            try expect(n * m, "\(m)×\(n) decoding matrix")
            return .legacyIntegerMatrix(values)
        case (.decorrelation, true):
            guard n == m else { throw J2KError.decodingError("a reversible decorrelation collection maps \(n) components to \(m)") }
            try expect((m + 1) * m, "reversible SERM decorrelation of \(m) components")
            let ints = try integers()
            var rows: [[Int64]] = [], targets: [Int] = [], shifts: [Int] = []
            for step in 0...m {
                let row = Array(ints[(step * m)..<((step + 1) * m)])
                let target = step < m ? m - 1 - step : m - 1
                rows.append(row)
                targets.append(target)
                shifts.append(try shift(row[target]))
            }
            return .reversibleSERM(rows: rows, targets: targets, shifts: shifts)
        case (.decorrelation, false):
            try expect(n * m, "\(m)×\(n) decoding matrix")
            return .irreversibleMatrix(values)
        case (.waveletBased, _):
            throw J2KError.notImplemented("wavelet-based multiple component transformations (T.801 J.3) are not supported")
        }
    }

    /// Applies the inverse transformation to the coded components (in place) and returns the DC shift to add to
    /// every component afterwards: 0 for the components a stage produces (its offsets are applied inside the stage,
    /// as the dependency predictions require), the Part 1 shift of the coded component (2^(depth−1) for unsigned
    /// components) for the others.
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
            let produced = Self.synthesise(stage, inputs: inputs.map { components[$0] }, sampleCount: sampleCount)
            for (k, component) in outputs.enumerated() {
                components[component] = produced[k]
                shifts[component] = 0
            }
        }
        return shifts
    }

    /// A coded sample as an integer (reversible kernels work on the integer 5-3 output).
    @inline(__always)
    private static func integer(_ value: Double) -> Int64 {
        value.isFinite ? Int64(Swift.max(-4.0e18, Swift.min(4.0e18, value.rounded()))) : 0
    }

    /// Runs one collection's synthesis row by row over all samples, skipping zero coefficients.
    static func synthesise(_ stage: Stage, inputs: [[Double]], sampleCount: Int) -> [[Double]] {
        let n = inputs.count, m = stage.collection.outputs.count
        let offsets = stage.offsets ?? [Double](repeating: 0, count: m)
        var out = [[Double]](repeating: [Double](repeating: 0, count: sampleCount), count: m)
        switch stage.kernel {
        case .passThrough:
            for k in 0..<m {
                let offset = offsets[k]
                if k < n {
                    let input = inputs[k]
                    out[k].withUnsafeMutableBufferPointer { o in for s in 0..<sampleCount { o[s] = input[s] + offset } }
                } else {
                    out[k] = [Double](repeating: offset, count: sampleCount)
                }
            }
        case .irreversibleMatrix(let matrix), .legacyIntegerMatrix(let matrix):
            let rounds: Bool
            if case .legacyIntegerMatrix = stage.kernel { rounds = true } else { rounds = false }
            for i in 0..<m {
                let terms = (0..<n).compactMap { j -> (Int, Double)? in matrix[i * n + j] == 0 ? nil : (j, matrix[i * n + j]) }
                let offset = offsets[i]
                out[i].withUnsafeMutableBufferPointer { o in
                    for (j, c) in terms {
                        let input = inputs[j]
                        for s in 0..<sampleCount { o[s] += c * input[s] }
                    }
                    for s in 0..<sampleCount { o[s] = (rounds ? o[s].rounded() : o[s]) + offset }
                }
            }
        case .irreversibleDependency(let rows):
            for k in 0..<m {
                var row = inputs[k]
                let offset = offsets[k]
                for s in 0..<sampleCount { row[s] += offset }
                if k > 0 {
                    for (j, c) in rows[k].enumerated() where c != 0 {
                        let previous = out[j]
                        for s in 0..<sampleCount { row[s] += c * previous[s] }
                    }
                }
                out[k] = row
            }
        case .reversibleDependency(let rows, let shifts):
            let integerOffsets = offsets.map(Self.integer)
            var accumulator = [Int64](repeating: 0, count: sampleCount)
            for k in 0..<m {
                let input = inputs[k], offset = integerOffsets[k]
                if k == 0 {
                    out[0].withUnsafeMutableBufferPointer { o in
                        for s in 0..<sampleCount { o[s] = Double(Self.integer(input[s]) &+ offset) }
                    }
                    continue
                }
                let shift = shifts[k]
                let half: Int64 = shift > 0 ? 1 << (shift - 1) : 0
                for s in 0..<sampleCount { accumulator[s] = half }
                for (j, c) in rows[k].enumerated() where c != 0 {
                    let previous = out[j]
                    for s in 0..<sampleCount { accumulator[s] = accumulator[s] &+ c &* Self.integer(previous[s]) }
                }
                out[k].withUnsafeMutableBufferPointer { o in
                    for s in 0..<sampleCount { o[s] = Double(Self.integer(input[s]) &+ offset &+ (accumulator[s] >> shift)) }
                }
            }
        case .reversibleSERM(let rows, let targets, let shifts):
            var vector = inputs.map { $0.map(Self.integer) }
            var accumulator = [Int64](repeating: 0, count: sampleCount)
            for (step, row) in rows.enumerated() {
                let target = targets[step], shift = shifts[step]
                let half: Int64 = shift > 0 ? 1 << (shift - 1) : 0
                for s in 0..<sampleCount { accumulator[s] = half }
                for (j, c) in row.enumerated() where j != target && c != 0 {
                    let source = vector[j]
                    for s in 0..<sampleCount { accumulator[s] = accumulator[s] &+ c &* source[s] }
                }
                vector[target].withUnsafeMutableBufferPointer { v in
                    for s in 0..<sampleCount { v[s] = v[s] &- (accumulator[s] >> shift) }
                }
            }
            let integerOffsets = offsets.map(Self.integer)
            for k in 0..<m {
                let source = vector[k], offset = integerOffsets[k]
                out[k].withUnsafeMutableBufferPointer { o in for s in 0..<sampleCount { o[s] = Double(source[s] &+ offset) } }
            }
        }
        return out
    }
}

/// Encoder-side description of one array-based transformation over all components (T.801 J.2, single stage).
struct J2KPart2EncodingMarkers: Sendable {
    /// Reconstructed component depths (CBD).
    let outputDepths: [J2KPart2CBDMarker.Depth]
    /// The forward matrix applied to the level-shifted components, row-major n×n.
    let forwardMatrix: [Double]
    /// Decoding matrix (inverse of the forward matrix), row-major n×n.
    let decodingMatrix: [Double]
    /// DC level shifts of the reconstructed components (2^(depth−1) for unsigned, 0 for signed).
    let offsets: [Int32]
    /// Whether the transformation is reversible (an integer unit lower triangular forward matrix, reversible coding).
    let reversible: Bool

    /// Whether `matrix` is unit lower triangular (integer when `integer`): the forward matrices a dependency
    /// transformation (T.801 J.2.2) inverts, exactly with divisors of 1 when reversible.
    static func isUnitLowerTriangular(_ matrix: [Double], size n: Int, integer: Bool) -> Bool {
        guard matrix.count == n * n else { return false }
        for row in 0..<n {
            for column in 0..<n {
                let value = matrix[row * n + column]
                guard value.isFinite, abs(value) < 2_147_483_648, !integer || value == value.rounded() else { return false }
                if column == row, value != 1 { return false }
                if column > row, value != 0 { return false }
            }
        }
        return true
    }

    /// The marker segments in codestream order: CBD, MCT (transformation, index 1), MCT (offsets, index 2), MCC, MCO.
    ///
    /// Reversible: the integer unit lower triangular forward matrix F (the own difference matrix) becomes a
    /// dependency collection (Xmcc 0) whose row k carries −F[k][j] for j < k followed by the divisor 1 (int32), with
    /// offsets o′[k] = o[k] + Σ_{j<k} F[k][j]·o[j], since the decoder's predictions use the offset outputs; a single
    /// component needs no coefficients and uses the pass-through transformation (index 0). Irreversible: a float32
    /// decorrelation collection (Xmcc 1) with the decoding matrix and the level shifts as offsets. Irreversible
    /// dependency rows would be smaller, but Kakadu 8.4.1 does not reconstruct them (not even its own) while it
    /// decodes irreversible matrices, so the matrix form is written for interoperability (#3246).
    func encodedSegments() -> Data {
        let n = outputDepths.count
        var data = J2KPart2CBDMarker(depths: outputDepths).encoded()
        let kind: J2KPart2ComponentCollection.Kind
        var transformIndex = 1
        if reversible {
            kind = .dependency
            var coefficients: [Int32] = []
            var dependencyOffsets = offsets.map(Int64.init)
            for k in stride(from: 1, to: n, by: 1) {
                for j in 0..<k {
                    let forward = Int64(forwardMatrix[k * n + j])
                    coefficients.append(Int32(-forward))
                    dependencyOffsets[k] += forward * Int64(offsets[j])
                }
                coefficients.append(1)
            }
            if coefficients.isEmpty {
                transformIndex = 0
            } else {
                data.append(J2KPart2MCTArray.int32(index: 1, kind: .dependency, values: coefficients).encoded())
            }
            data.append(J2KPart2MCTArray.int32(index: 2, kind: .offset, values: dependencyOffsets.map { Int32(clamping: $0) }).encoded())
        } else {
            kind = .decorrelation
            data.append(J2KPart2MCTArray.float32(index: 1, kind: .decorrelation, values: decodingMatrix).encoded())
            data.append(J2KPart2MCTArray.int32(index: 2, kind: .offset, values: offsets).encoded())
        }
        let collection = J2KPart2ComponentCollection(
            kind: kind, inputs: Array(0..<n), outputs: Array(0..<n),
            transformParameters: transformIndex | (2 << 8) | ((reversible ? 1 : 0) << 16)
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

/// The Annex J codes the own codec wrote before issue #3246 — MCT 0xFF75, MCC 0xFF77, MCO 0xFF76 (the NLT code) —
/// against T.801 Table A.2 (MCT 0xFF74, MCC 0xFF75, MCO 0xFF77). A main header with an NLT-position segment and no
/// T.801 MCT is one of those objects: the codec never writes NLT, and a T.801 transformation always has an MCT array.
enum J2KPart2LegacyMarkerLayout {
    /// Whether the main header uses the pre-#3246 Annex J marker codes, by the rule above.
    static func isLegacy(_ codestream: Data) -> Bool {
        codestream.withUnsafeBytes { bytes -> Bool in
            var hasNLTCode = false, hasMCCCode = false, hasMCTCode = false
            var cursor = 2
            while cursor + 4 <= bytes.count, bytes[cursor] == 0xFF, bytes[cursor + 1] != 0x90, bytes[cursor + 1] != 0xD9 {
                switch bytes[cursor + 1] {
                case 0x74: hasMCTCode = true
                case 0x75: hasMCCCode = true
                case 0x76: hasNLTCode = true
                default: break
                }
                cursor += 2 + (Int(bytes[cursor + 2]) << 8 | Int(bytes[cursor + 3]))
            }
            return hasNLTCode && hasMCCCode && !hasMCTCode
        }
    }

    /// The T.801 code of a pre-#3246 Annex J marker when `legacy`; any other marker passes through unchanged.
    static func standardMarker(_ marker: UInt16, legacy: Bool) -> UInt16 {
        guard legacy else { return marker }
        switch marker {
        case 0xFF75: return J2KMarker.mct.rawValue
        case 0xFF77: return J2KMarker.mcc.rawValue
        case 0xFF76: return J2KMarker.mco.rawValue
        default: return marker
        }
    }
}
