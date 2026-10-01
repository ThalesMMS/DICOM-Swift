import Foundation

/// Shared vocabulary of the PS3.18 DICOM JSON and PS3.19 Native DICOM Model XML codecs: the decoded
/// result with its unresolved bulk-data references and diagnostics, the explicit bulk-data resolution
/// contract, the fidelity options and the per-VR text conversions both representations share.
public enum DicomDataSetRepresentation {
    public typealias Path = [DicomValidationReport.PathComponent]

    /// The little-endian value field used by InlineBinary and native bulk-data responses.
    public static func binaryValueBytes(of element: DicomDataElement) throws -> Data {
        if case .bytes(let data) = element.value { return data }
        return try Values.binaryBytes(of: element, tag: String(format: "%08X", element.tag))
    }

    /// A value field that the representation carries by reference (PS3.18 `BulkDataURI`, PS3.19 `BulkData`).
    /// The element stays empty in the decoded data set until the reference is resolved explicitly.
    public struct BulkDataReference: Equatable, Sendable {
        public let path: Path
        public let tag: Int
        public let vr: DicomVR
        public let uri: String

        public init(path: Path, tag: Int, vr: DicomVR, uri: String) {
            self.path = path; self.tag = tag; self.vr = vr; self.uri = uri
        }
    }

    public enum DiagnosticCode: String, Sendable {
        /// A JSON `null` inside a numeric Value array was dropped under `NullPolicy.dropWithDiagnostic`.
        case nullValueDropped
        /// A JSON number for DS/IS/SV/UV was canonicalized to text; its original lexical form is unknown.
        case numberCanonicalized
        /// An unknown VR code was kept as UN under `UnknownVRPolicy.treatAsUnknown`.
        case unknownVRTreatedAsUnknown
        /// An attribute keyword or private creator could not be determined for the XML representation.
        case keywordUnavailable
    }

    public struct Diagnostic: Equatable, Sendable {
        public let code: DiagnosticCode
        public let path: Path
        public init(code: DiagnosticCode, path: Path) { self.code = code; self.path = path }
    }

    /// One decoded data set: the elements, the bulk-data references left unresolved and the diagnostics.
    public struct Decoded: Sendable {
        public var dataSet: DicomDataSet
        public var bulkData: [BulkDataReference]
        public var diagnostics: [Diagnostic]
        public var transferSyntax: DicomTransferSyntax?

        public init(dataSet: DicomDataSet, bulkData: [BulkDataReference] = [], diagnostics: [Diagnostic] = [], transferSyntax: DicomTransferSyntax? = nil) {
            self.dataSet = dataSet; self.bulkData = bulkData; self.diagnostics = diagnostics
            self.transferSyntax = transferSyntax ?? dataSet.string(for: .transferSyntaxUID).flatMap(DicomTransferSyntax.init(uid:))
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidDocument(String)
        case inputTooLarge(byteCount: Int, limit: Int)
        case depthExceeded(limit: Int)
        case malformedTag(String)
        case missingVR(tag: String)
        case unsupportedVR(tag: String, vr: String)
        case conflictingValueFields(tag: String)
        case invalidBase64(tag: String)
        case nullValue(tag: String, index: Int)
        case unrepresentableValue(tag: String, index: Int, reason: String)
        case bulkDataUnresolved(tag: String)
        case bulkDataTooLarge(tag: String, byteCount: Int, limit: Int)
    }

    /// How DS, IS, SV and UV values are written (PS3.18 allows numbers or strings for them).
    public enum DecimalPolicy: Sendable {
        /// Strings that preserve the original lexical form (default).
        case preserveText
        /// JSON numbers whenever the text is a canonical JSON number and exact in 53 bits; strings otherwise.
        case numbersWhenExact
    }

    /// How OB/OD/OF/OL/OV/OW/UN value fields are written.
    public enum BinaryPolicy: Sendable {
        /// Base64 InlineBinary.
        case inline
        /// `BulkDataURI`/`BulkData uri` produced by the closure; elements for which it returns nil stay inline.
        case reference(@Sendable (_ path: Path, _ element: DicomDataElement) -> String?)
        /// Omit the listed tags entirely (for example Pixel Data in a metadata view).
        case omit(Set<Int>)
    }

    public struct EncodingOptions: Sendable {
        public var decimals: DecimalPolicy
        public var binary: BinaryPolicy
        /// Pixel Data encapsulation context when the data set has no File Meta Transfer Syntax UID.
        public var transferSyntax: DicomTransferSyntax?
        public init(decimals: DecimalPolicy = .preserveText, binary: BinaryPolicy = .inline, transferSyntax: DicomTransferSyntax? = nil) {
            self.decimals = decimals; self.binary = binary
            self.transferSyntax = transferSyntax
        }
    }

    public enum NullPolicy: Sendable { case reject, dropWithDiagnostic }
    public enum UnknownVRPolicy: Sendable { case reject, treatAsUnknown }

    public struct DecodingOptions: Sendable {
        public var maximumBytes: Int
        public var maximumDepth: Int
        public var nulls: NullPolicy
        public var unknownVRs: UnknownVRPolicy
        public var transferSyntax: DicomTransferSyntax?
        public init(maximumBytes: Int = 64 * 1024 * 1024, maximumDepth: Int = 64, nulls: NullPolicy = .reject,
                    unknownVRs: UnknownVRPolicy = .reject, transferSyntax: DicomTransferSyntax? = nil) {
            self.maximumBytes = max(0, maximumBytes); self.maximumDepth = max(1, maximumDepth); self.nulls = nulls; self.unknownVRs = unknownVRs
            self.transferSyntax = transferSyntax
        }
    }

    /// Explicit bulk-data resolution: nothing is fetched while a representation is parsed.
    public protocol BulkDataResolver: Sendable {
        func data(for reference: BulkDataReference) async throws -> Data
    }

    public struct BulkDataLimits: Sendable {
        public var maximumBytesPerReference: Int
        public var maximumReferences: Int
        /// Aggregate encoded bytes retained during one resolution call.
        public var maximumTotalBytes: Int
        public init(maximumBytesPerReference: Int = 256 * 1024 * 1024, maximumReferences: Int = 4096,
                    maximumTotalBytes: Int = 256 * 1024 * 1024) {
            self.maximumBytesPerReference = max(0, maximumBytesPerReference); self.maximumReferences = max(0, maximumReferences)
            self.maximumTotalBytes = max(0, maximumTotalBytes)
        }
    }

    /// Resolves every reference through the resolver and stores the value fields in the data set.
    public static func resolvingBulkData(_ decoded: Decoded, using resolver: any BulkDataResolver,
                                         limits: BulkDataLimits = .init()) async throws -> Decoded {
        guard decoded.bulkData.count <= limits.maximumReferences else {
            throw Error.bulkDataTooLarge(tag: "", byteCount: decoded.bulkData.count, limit: limits.maximumReferences)
        }
        var result = decoded
        var totalBytes = 0
        for reference in decoded.bulkData {
            try Task.checkCancellation()
            let bytes = try await resolver.data(for: reference)
            let key = String(format: "%08X", reference.tag)
            guard bytes.count <= limits.maximumBytesPerReference else {
                throw Error.bulkDataTooLarge(tag: key, byteCount: bytes.count, limit: limits.maximumBytesPerReference)
            }
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(bytes.count)
            guard !overflow, newTotal <= limits.maximumTotalBytes else {
                throw Error.bulkDataTooLarge(tag: key, byteCount: overflow ? Int.max : newTotal, limit: limits.maximumTotalBytes)
            }
            totalBytes = newTotal
            let value = try Values.value(fromBulkBytes: bytes, vr: reference.vr, tag: key)
            result.dataSet = try Values.replacing(result.dataSet, at: reference.path, value: value, vr: reference.vr, tag: reference.tag)
        }
        result.bulkData = []
        result.dataSet = Values.restoringPixelDelimiter(in: result.dataSet, transferSyntax: result.transferSyntax)
        return result
    }

    // MARK: - Per-VR conversions shared by both representations

    enum Values {
        static let binaryVRs: Set<DicomVR> = [.OB, .OD, .OF, .OL, .OV, .OW, .UN]
        static let decimalTextVRs: Set<DicomVR> = [.DS, .IS, .SV, .UV]
        static let bulkCapableVRs: Set<DicomVR> = [.DS, .FL, .FD, .IS, .LT, .OB, .OD, .OF, .OL, .OV, .OW, .SL, .SS, .ST, .SV, .UC, .UL, .UN, .US, .UT, .UV]
        static let canonicalNumber = try! NSRegularExpression(pattern: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#)

        static func vr(fromCode code: String) -> DicomVR? {
            let upper = code.uppercased()
            guard upper.count == 2, let first = upper.utf8.first, let last = upper.utf8.last else { return nil }
            let vr = DicomVR(rawValue: Int(first) << 8 | Int(last))
            return vr == .unknown || vr == .implicitRaw ? nil : vr
        }

        static func code(for vr: DicomVR) -> String {
            guard vr != .unknown, vr != .implicitRaw else { return "UN" }
            return String(bytes: [UInt8((vr.rawValue >> 8) & 0xFF), UInt8(vr.rawValue & 0xFF)], encoding: .ascii) ?? "UN"
        }

        static func tag(fromKey key: String) -> Int? {
            guard key.count == 8, key.allSatisfy({ $0.isHexDigit }), let tag = Int(key, radix: 16) else { return nil }
            return tag
        }

        /// The textual values of an element as PS3.18/PS3.19 write them (AT as eight hex digits).
        static func texts(of element: DicomDataElement) throws -> [String] {
            switch element.value {
            case .empty, .bytes, .sequence: return []
            case .strings(let values): return values
            case .signedIntegers(let values): return values.map(String.init)
            case .unsignedIntegers(let values):
                return element.vr == .AT ? values.map { String(format: "%08X", UInt32(truncatingIfNeeded: $0)) } : values.map(String.init)
            case .floats(let values):
                let key = String(format: "%08X", element.tag)
                return try values.enumerated().map { index, value in
                    guard value.isFinite else { throw Error.unrepresentableValue(tag: key, index: index, reason: "non-finite floating point") }
                    return String(value)
                }
            }
        }

        static func isCanonicalNumber(_ text: String) -> Bool {
            canonicalNumber.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }

        /// A single text token into the element value storage of its VR.
        static func value(fromTexts texts: [String], vr: DicomVR, tag key: String) throws -> DicomDataValue {
            guard !texts.isEmpty else { return .empty }
            switch vr {
            case .AT:
                return .unsignedIntegers(try texts.enumerated().map { index, text in
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    guard trimmed.count == 8, let value = UInt(trimmed, radix: 16) else {
                        throw Error.unrepresentableValue(tag: key, index: index, reason: "AT values are eight hexadecimal digits")
                    }
                    return value
                })
            case .SS, .SL:
                let range: ClosedRange<Int> = vr == .SS ? Int(Int16.min)...Int(Int16.max) : Int(Int32.min)...Int(Int32.max)
                return .signedIntegers(try texts.enumerated().map { index, text in
                    guard let value = Int(text.trimmingCharacters(in: .whitespaces)), range.contains(value) else {
                        throw Error.unrepresentableValue(tag: key, index: index, reason: "out of range for \(code(for: vr))")
                    }
                    return value
                })
            case .US, .UL:
                let maximum: UInt = vr == .US ? UInt(UInt16.max) : UInt(UInt32.max)
                return .unsignedIntegers(try texts.enumerated().map { index, text in
                    guard let value = UInt(text.trimmingCharacters(in: .whitespaces)), value <= maximum else {
                        throw Error.unrepresentableValue(tag: key, index: index, reason: "out of range for \(code(for: vr))")
                    }
                    return value
                })
            case .SV:
                return .signedIntegers(try texts.enumerated().map { index, text in
                    guard let value = Int64(text.trimmingCharacters(in: .whitespaces)) else {
                        throw Error.unrepresentableValue(tag: key, index: index, reason: "not a 64-bit signed integer")
                    }
                    return Int(value)
                })
            case .UV:
                return .unsignedIntegers(try texts.enumerated().map { index, text in
                    guard let value = UInt64(text.trimmingCharacters(in: .whitespaces)) else {
                        throw Error.unrepresentableValue(tag: key, index: index, reason: "not a 64-bit unsigned integer")
                    }
                    return UInt(value)
                })
            case .FL, .FD:
                return .floats(try texts.enumerated().map { index, text in
                    guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite else {
                        throw Error.unrepresentableValue(tag: key, index: index, reason: "not a finite floating point number")
                    }
                    return value
                })
            default:
                // Text VRs, DS and IS keep their lexical form; empty strings are empty values.
                return texts.allSatisfy(\.isEmpty) ? .empty : .strings(texts)
            }
        }

        /// InlineBinary bytes into the storage the wire parser uses: OB/OW/UN stay bytes, OF/OD/OL/OV become numbers.
        static func value(fromInlineBytes bytes: Data, vr: DicomVR, tag key: String) throws -> DicomDataValue {
            guard !bytes.isEmpty else { return .empty }
            if [.OB, .OW, .UN].contains(vr) { return .bytes(bytes) }
            guard let value = DicomDataValueDecoder.binaryValue(for: vr, data: bytes, littleEndian: true) else {
                throw Error.unrepresentableValue(tag: key, index: 0, reason: "binary length does not match \(code(for: vr))")
            }
            return value
        }

        /// A bulk-data value field (raw little-endian bytes) into the element value storage of its VR.
        static func value(fromBulkBytes bytes: Data, vr: DicomVR, tag key: String) throws -> DicomDataValue {
            guard !bytes.isEmpty else { return .empty }
            if binaryVRs.contains(vr) { return try value(fromInlineBytes: bytes, vr: vr, tag: key) }
            if let value = DicomDataValueDecoder.binaryValue(for: vr, data: bytes, littleEndian: true) { return value }
            guard let text = String(data: bytes, encoding: .utf8) else {
                throw Error.unrepresentableValue(tag: key, index: 0, reason: "bulk text is not UTF-8")
            }
            let trimmed = text.hasSuffix(" ") || text.hasSuffix("\0") ? String(text.dropLast()) : text
            let values = [.LT, .ST, .UT].contains(vr) ? [trimmed] : trimmed.components(separatedBy: "\\")
            return try value(fromTexts: values, vr: vr, tag: key)
        }

        /// Little-endian bytes of a binary VR held in numeric storage (OF/OD/OL/OV/OW parsed values).
            static func binaryBytes(of element: DicomDataElement, tag key: String) throws -> Data {
            var data = Data()
            switch (element.vr, element.value) {
            case (.OF, .floats(let values)):
                for value in values { withUnsafeBytes(of: Float(value).bitPattern.littleEndian) { data.append(contentsOf: $0) } }
            case (.OD, .floats(let values)):
                for value in values { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
            case (.OL, .unsignedIntegers(let values)):
                for value in values { withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian) { data.append(contentsOf: $0) } }
            case (.OV, .unsignedIntegers(let values)):
                for value in values { withUnsafeBytes(of: UInt64(truncatingIfNeeded: value).littleEndian) { data.append(contentsOf: $0) } }
            case (.OW, .unsignedIntegers(let values)):
                for value in values { withUnsafeBytes(of: UInt16(truncatingIfNeeded: value).littleEndian) { data.append(contentsOf: $0) } }
            default:
                throw DicomDataSetRepresentation.Error.unrepresentableValue(tag: key, index: 0, reason: "binary VR carries non-binary storage")
            }
            return data
        }

        static let sequenceDelimiter = Data([0xFE, 0xFF, 0xDD, 0xE0, 0x00, 0x00, 0x00, 0x00])

        /// The value field of an encapsulated Pixel Data element excludes the Sequence Delimitation Item (PS3.5 A.4);
        /// the wire-preserving reader keeps it, so it is dropped for the representation and restored on decode.
        static func representationBytes(of element: DicomDataElement, _ bytes: Data, encapsulated: Bool) -> Data {
            guard encapsulated, element.tag == 0x7FE00010, bytes.count >= 8, bytes.suffix(8) == sequenceDelimiter else { return bytes }
            return bytes.dropLast(8)
        }

        static func restoringPixelDelimiter(in dataSet: DicomDataSet, transferSyntax: DicomTransferSyntax?) -> DicomDataSet {
            guard transferSyntax?.registryEntry.isEncapsulated == true, let pixel = dataSet[0x7FE00010],
                  case .bytes(let bytes) = pixel.value, !bytes.isEmpty, bytes.suffix(8) != sequenceDelimiter else { return dataSet }
            return dataSet.setting(.init(tag: pixel.tag, vr: pixel.vr, value: .bytes(bytes + sequenceDelimiter), name: pixel.name))
        }

        static func personNameGroups(_ raw: String) -> [String] {
            var groups = raw.split(separator: "=", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            while groups.count < 3 { groups.append("") }
            return groups
        }

        static func personName(alphabetic: String?, ideographic: String?, phonetic: String?) -> String {
            var groups = [alphabetic ?? "", ideographic ?? "", phonetic ?? ""]
            while groups.last?.isEmpty == true { groups.removeLast() }
            return groups.joined(separator: "=")
        }

        static func replacing(_ dataSet: DicomDataSet, at path: Path, value: DicomDataValue, vr: DicomVR, tag: Int) throws -> DicomDataSet {
            guard let head = path.first, case .tag(let headTag) = head else { throw Error.bulkDataUnresolved(tag: String(format: "%08X", tag)) }
            if path.count == 1 {
                return dataSet.setting(.init(tag: headTag, vr: vr, value: value))
            }
            guard path.count >= 3, case .item(let index) = path[1], let sequence = dataSet[headTag],
                  case .sequence(var items) = sequence.value, items.indices.contains(index) else {
                throw Error.bulkDataUnresolved(tag: String(format: "%08X", tag))
            }
            items[index] = DicomSequenceItem(dataSet: try replacing(items[index].dataSet, at: Array(path.dropFirst(2)), value: value, vr: vr, tag: tag))
            return dataSet.setting(.init(tag: headTag, vr: sequence.vr, value: .sequence(items)))
        }

        /// The private creator of a private element, when its creator element is present in the same data set.
        static func privateCreator(of element: DicomDataElement, in dataSet: DicomDataSet) -> String? {
            guard element.isPrivate, element.element > 0xFF else { return nil }
            let creator = dataSet[element.group << 16 | (element.element >> 8)]
            return creator?.stringValue?.trimmingCharacters(in: .whitespaces)
        }
    }
}
