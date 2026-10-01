import Foundation

/// PS3.18 Annex F DICOM JSON Model ↔ `DicomDataSet`, without silent loss: every VR keeps its storage
/// (DS/IS/SV/UV as text unless asked for numbers, AT as eight hex digits, 64-bit integers, binary as
/// InlineBinary or an explicit reference), `null` and unknown VRs follow the stated policies, and bulk
/// data is never fetched while parsing.
public enum DicomJSONCodec {
    public typealias Options = DicomDataSetRepresentation.EncodingOptions
    public typealias DecodingOptions = DicomDataSetRepresentation.DecodingOptions
    public typealias Decoded = DicomDataSetRepresentation.Decoded
    public typealias Error = DicomDataSetRepresentation.Error
    private typealias Values = DicomDataSetRepresentation.Values
    public typealias Path = DicomDataSetRepresentation.Path

    // MARK: - Encoding

    /// One DICOM JSON Model object per data set, as a JSON array with sorted tag keys.
    public static func encode(_ dataSets: [DicomDataSet], options: Options = .init()) throws -> Data {
        let objects = try dataSets.map { try object(from: $0, path: [], options: options) }
        return try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
    }

    /// A single DICOM JSON Model object.
    public static func encode(_ dataSet: DicomDataSet, options: Options = .init()) throws -> Data {
        try JSONSerialization.data(withJSONObject: try object(from: dataSet, path: [], options: options), options: [.sortedKeys])
    }

    public static func object(from dataSet: DicomDataSet, path: Path = [], options: Options = .init()) throws -> [String: Any] {
        var object: [String: Any] = [:]
        var options = options
        if path.isEmpty, options.transferSyntax == nil {
            options.transferSyntax = dataSet.string(for: .transferSyntaxUID).flatMap(DicomTransferSyntax.init(uid:))
        }
        for element in dataSet.elements where element.element != 0 {
            if case .omit(let tags) = options.binary, tags.contains(element.tag) { continue }
            object[String(format: "%08X", element.tag)] = try jsonElement(element, path: path + [.tag(element.tag)], options: options)
        }
        return object
    }

    private static func jsonElement(_ element: DicomDataElement, path: Path, options: Options) throws -> [String: Any] {
        let key = String(format: "%08X", element.tag)
        var object: [String: Any] = ["vr": Values.code(for: element.vr)]
        switch element.value {
        case .empty:
            break
        case .sequence(let items):
            // A sequence without items is an empty value: no Value member (PS3.18 F.2.5).
            guard !items.isEmpty else { break }
            object["Value"] = try items.enumerated().map { index, item in
                try self.object(from: item.dataSet, path: path + [.item(index)], options: options)
            }
        case .bytes(let data):
            guard !data.isEmpty else { break }
            if case .reference(let resolver) = options.binary, let uri = resolver(path, element) {
                object["BulkDataURI"] = uri
            } else {
                object["InlineBinary"] = Values.representationBytes(of: element, data,
                    encapsulated: path.count == 1 && options.transferSyntax?.registryEntry.isEncapsulated == true).base64EncodedString()
            }
        case .strings, .signedIntegers, .unsignedIntegers, .floats:
            if Values.binaryVRs.contains(element.vr) {
                // Binary VRs stored as numbers (OF/OD parsed values) are re-encoded as their little-endian bytes.
                object["InlineBinary"] = try Values.binaryBytes(of: element, tag: key).base64EncodedString()
                break
            }
            let values = try jsonValues(of: element, tag: key, options: options)
            if !values.isEmpty { object["Value"] = values }
        }
        return object
    }

    private static func jsonValues(of element: DicomDataElement, tag key: String, options: Options) throws -> [Any] {
        switch element.vr {
        case .PN:
            let names = element.stringValues.map { raw -> Any in
                let groups = Values.personNameGroups(raw)
                var object: [String: String] = [:]
                if !groups[0].isEmpty { object["Alphabetic"] = groups[0] }
                if !groups[1].isEmpty { object["Ideographic"] = groups[1] }
                if !groups[2].isEmpty { object["Phonetic"] = groups[2] }
                return object.isEmpty ? NSNull() : object
            }
            return names.count == 1 && names[0] is NSNull ? [] : names
        case .SQ:
            return []
        case .FL, .FD:
            switch element.value {
            case .floats(let values):
                return try values.enumerated().map { index, value in
                    guard value.isFinite else { throw Error.unrepresentableValue(tag: key, index: index, reason: "non-finite floating point") }
                    return value
                }
            default:
                return try Values.texts(of: element).compactMap(Double.init)
            }
        case .SS, .SL, .US, .UL:
            switch element.value {
            case .signedIntegers(let values): return values
            case .unsignedIntegers(let values): return values.map { Int($0) }
            default: return try Values.texts(of: element).compactMap(Int.init)
            }
        case .SV, .UV:
            let texts = try Values.texts(of: element)
            return texts.map { text -> Any in
                // Numbers only inside the exactly representable 53-bit range; strings preserve the rest.
                if let value = Int64(text), value.magnitude <= 1 << 53 { return value }
                if let value = UInt64(text), value <= 1 << 53 { return value }
                return text
            }
        case .DS, .IS:
            let texts = try Values.texts(of: element)
            return texts.map { text -> Any in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return NSNull() }
                switch options.decimals {
                case .preserveText:
                    return text
                case .numbersWhenExact:
                    guard Values.isCanonicalNumber(trimmed) else { return text }
                    if element.vr == .IS, let value = Int64(trimmed), value.magnitude <= 1 << 53 { return value }
                    if element.vr == .DS, let value = Double(trimmed), value.isFinite, String(value) == trimmed { return value }
                    return text
                }
            }
        case .AT:
            return try Values.texts(of: element)
        default:
            let texts = try Values.texts(of: element)
            let values = texts.map { $0.isEmpty ? NSNull() as Any : $0 as Any }
            return values.count == 1 && values[0] is NSNull ? [] : values
        }
    }

    // MARK: - Decoding

    /// Accepts a JSON array of DICOM JSON Model objects or a single object.
    public static func decode(_ data: Data, options: DecodingOptions = .init()) throws -> [Decoded] {
        guard data.count <= options.maximumBytes else { throw Error.inputTooLarge(byteCount: data.count, limit: options.maximumBytes) }
        guard !data.isEmpty else { return [] }
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data, options: []) } catch { throw Error.invalidDocument("not valid JSON") }
        if let array = root as? [Any] {
            return try array.map { entry in
                guard let object = entry as? [String: Any] else { throw Error.invalidDocument("array entries must be objects") }
                return try decode(object: object, options: options)
            }
        }
        if let object = root as? [String: Any] { return [try decode(object: object, options: options)] }
        throw Error.invalidDocument("root must be an object or an array of objects")
    }

    public static func decode(object: [String: Any], options: DecodingOptions = .init()) throws -> Decoded {
        var state = DecodeState(options: options)
        let dataSet = try dataSet(from: object, path: [], depth: 1, state: &state)
        var decoded = Decoded(dataSet: dataSet, bulkData: state.bulkData, diagnostics: state.diagnostics, transferSyntax: options.transferSyntax)
        decoded.dataSet = Values.restoringPixelDelimiter(in: dataSet, transferSyntax: decoded.transferSyntax)
        return decoded
    }

    private struct DecodeState {
        let options: DecodingOptions
        var bulkData: [DicomDataSetRepresentation.BulkDataReference] = []
        var diagnostics: [DicomDataSetRepresentation.Diagnostic] = []
        init(options: DecodingOptions) { self.options = options }
    }

    private static func dataSet(from object: [String: Any], path: Path, depth: Int, state: inout DecodeState) throws -> DicomDataSet {
        guard depth <= state.options.maximumDepth else { throw Error.depthExceeded(limit: state.options.maximumDepth) }
        var elements: [DicomDataElement] = []
        for key in object.keys.sorted() {
            guard let tag = Values.tag(fromKey: key) else { throw Error.malformedTag(key) }
            guard let attribute = object[key] as? [String: Any] else { throw Error.invalidDocument("attribute \(key) is not an object") }
            guard let code = attribute["vr"] as? String else { throw Error.missingVR(tag: key) }
            let elementPath = path + [.tag(tag)]
            let vr: DicomVR
            if let known = Values.vr(fromCode: code) {
                vr = known
            } else if state.options.unknownVRs == .treatAsUnknown {
                vr = .UN
                state.diagnostics.append(.init(code: .unknownVRTreatedAsUnknown, path: elementPath))
            } else {
                throw Error.unsupportedVR(tag: key, vr: code)
            }
            let fields = ["Value", "BulkDataURI", "InlineBinary"].filter { attribute[$0] != nil && !(attribute[$0] is NSNull) }
            guard fields.count <= 1 else { throw Error.conflictingValueFields(tag: key) }
            let value: DicomDataValue
            if let inline = attribute["InlineBinary"] as? String {
                guard let bytes = Data(base64Encoded: inline, options: []) else { throw Error.invalidBase64(tag: key) }
                value = try Values.value(fromInlineBytes: bytes, vr: vr, tag: key)
            } else if let uri = attribute["BulkDataURI"] as? String {
                state.bulkData.append(.init(path: elementPath, tag: tag, vr: vr, uri: uri))
                value = .empty
            } else if let values = attribute["Value"] as? [Any] {
                value = try self.value(from: values, vr: vr, tag: key, path: elementPath, depth: depth, state: &state)
            } else if attribute["Value"] == nil || attribute["Value"] is NSNull {
                value = .empty
            } else {
                throw Error.invalidDocument("Value of \(key) is not an array")
            }
            elements.append(.init(tag: tag, vr: vr, value: value))
        }
        return DicomDataSet(elements: elements)
    }

    private static func value(from values: [Any], vr: DicomVR, tag key: String, path: Path, depth: Int, state: inout DecodeState) throws -> DicomDataValue {
        guard !values.isEmpty else { return .empty }
        if vr == .SQ {
            return .sequence(try values.enumerated().map { index, entry in
                guard let object = entry as? [String: Any] else { throw Error.invalidDocument("sequence item of \(key) is not an object") }
                return DicomSequenceItem(dataSet: try dataSet(from: object, path: path + [.item(index)], depth: depth + 1, state: &state))
            })
        }
        if Values.binaryVRs.contains(vr) { throw Error.invalidDocument("binary VR \(Values.code(for: vr)) of \(key) uses Value instead of InlineBinary") }
        var texts: [String] = []
        var canonicalized = false
        for (index, entry) in values.enumerated() {
            if entry is NSNull {
                // Empty multi-valued strings are representable; empty numbers are not.
                if [.PN, .SS, .SL, .US, .UL, .SV, .UV, .FL, .FD, .AT].contains(vr) && ![.PN].contains(vr) {
                    guard state.options.nulls == .dropWithDiagnostic else { throw Error.nullValue(tag: key, index: index) }
                    state.diagnostics.append(.init(code: .nullValueDropped, path: path))
                    continue
                }
                texts.append("")
                continue
            }
            if vr == .PN {
                if let string = entry as? String { texts.append(string); continue }
                guard let object = entry as? [String: Any] else { throw Error.unrepresentableValue(tag: key, index: index, reason: "person name is not an object") }
                func group(_ name: String) throws -> String? {
                    guard let raw = object[name], !(raw is NSNull) else { return nil }
                    guard let string = raw as? String else { throw Error.unrepresentableValue(tag: key, index: index, reason: "\(name) is not a string") }
                    return string
                }
                texts.append(Values.personName(alphabetic: try group("Alphabetic"), ideographic: try group("Ideographic"), phonetic: try group("Phonetic")))
                continue
            }
            if let string = entry as? String {
                if [.SS, .SL, .US, .UL, .FL, .FD].contains(vr) {
                    throw Error.unrepresentableValue(tag: key, index: index, reason: "\(Values.code(for: vr)) values must be JSON numbers")
                }
                texts.append(string)
            } else if let number = entry as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                guard vr != .AT, ![.AE, .AS, .CS, .DA, .DT, .LO, .LT, .SH, .ST, .TM, .UI, .UR, .UT, .UC].contains(vr) else {
                    throw Error.unrepresentableValue(tag: key, index: index, reason: "\(Values.code(for: vr)) values must be JSON strings")
                }
                // Integers have one canonical text; a decimal string's original format is lost when it arrives as a number.
                if vr == .DS { canonicalized = true }
                texts.append(canonicalText(number, vr: vr))
            } else {
                throw Error.unrepresentableValue(tag: key, index: index, reason: "unsupported JSON value type")
            }
        }
        if canonicalized { state.diagnostics.append(.init(code: .numberCanonicalized, path: path)) }
        guard !texts.isEmpty else { return .empty }
        return try Values.value(fromTexts: texts, vr: vr, tag: key)
    }

    /// Canonical text of a JSON number: integral numbers without a fraction, others in Swift's shortest form.
    private static func canonicalText(_ number: NSNumber, vr: DicomVR) -> String {
        let type = String(cString: number.objCType)
        if ["q", "i", "l", "s", "c", "Q", "I", "L", "S", "C"].contains(type) {
            return type.first!.isUppercase ? String(number.uint64Value) : String(number.int64Value)
        }
        let value = number.doubleValue
        if value == value.rounded(), value.magnitude < 1e15, vr != .DS { return String(Int64(value)) }
        return String(value)
    }
}
