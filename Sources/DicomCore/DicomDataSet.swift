import Foundation

public struct DicomVM: Equatable, Hashable, Sendable {
    public let count: Int

    public init(count: Int) {
        self.count = max(0, count)
    }

    public static let zero = DicomVM(count: 0)
    public static let one = DicomVM(count: 1)
}

public struct DicomUID: Equatable, Hashable, Sendable {
    public let rawValue: String

    public init?(_ rawValue: String) {
        let trimmed = rawValue.dicomTrimmedValue
        guard !trimmed.isEmpty else { return nil }
        self.rawValue = trimmed
    }
}

public struct DicomPersonName: Equatable, Hashable, Sendable {
    public let rawValue: String
    public let alphabetic: String
    public let ideographic: String?
    public let phonetic: String?
    public let familyName: String?
    public let givenName: String?
    public let middleName: String?
    public let namePrefix: String?
    public let nameSuffix: String?

    public init?(_ rawValue: String) {
        let trimmed = rawValue.dicomTrimmedValue
        guard !trimmed.isEmpty else { return nil }
        let representationGroups = trimmed.split(separator: "=", omittingEmptySubsequences: false).map(String.init)
        let alphabetic = representationGroups.first ?? trimmed
        let components = alphabetic.split(separator: "^", omittingEmptySubsequences: false).map(String.init)

        self.rawValue = trimmed
        self.alphabetic = alphabetic
        self.ideographic = representationGroups.count > 1 ? representationGroups[1].nilIfEmpty : nil
        self.phonetic = representationGroups.count > 2 ? representationGroups[2].nilIfEmpty : nil
        self.familyName = components[safe: 0]?.nilIfEmpty
        self.givenName = components[safe: 1]?.nilIfEmpty
        self.middleName = components[safe: 2]?.nilIfEmpty
        self.namePrefix = components[safe: 3]?.nilIfEmpty
        self.nameSuffix = components[safe: 4]?.nilIfEmpty
    }
}

public struct DicomAge: Equatable, Hashable, Sendable {
    public enum Unit: Character, Sendable {
        case days = "D"
        case weeks = "W"
        case months = "M"
        case years = "Y"
    }

    public let rawValue: String
    public let value: Int
    public let unit: Unit

    public init?(_ rawValue: String) {
        let trimmed = rawValue.dicomTrimmedValue
        guard trimmed.count == 4,
              let unitCharacter = trimmed.last,
              let unit = Unit(rawValue: unitCharacter),
              let value = Int(trimmed.prefix(3)) else {
            return nil
        }
        self.rawValue = trimmed
        self.value = value
        self.unit = unit
    }
}

public struct DicomDate: Equatable, Hashable, Sendable {
    public let rawValue: String
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(_ rawValue: String) {
        let trimmed = rawValue.dicomTrimmedValue
        guard trimmed.count == 8,
              let year = Int(trimmed.prefix(4)),
              let month = Int(trimmed.dropFirst(4).prefix(2)),
              let day = Int(trimmed.dropFirst(6).prefix(2)),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }
        self.rawValue = trimmed
        self.year = year
        self.month = month
        self.day = day
    }
}

public struct DicomTime: Equatable, Hashable, Sendable {
    public let rawValue: String
    public let hour: Int
    public let minute: Int?
    public let second: Int?
    public let fractionalSeconds: Double?

    public init?(_ rawValue: String) {
        let trimmed = rawValue.dicomTrimmedValue
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let digits = String(parts[0])
        guard digits.count >= 2,
              digits.count <= 6,
              digits.count % 2 == 0,
              let hour = Int(digits.prefix(2)),
              (0...23).contains(hour) else {
            return nil
        }

        let minute: Int?
        if digits.count >= 4 {
            guard let parsed = Int(digits.dropFirst(2).prefix(2)), (0...59).contains(parsed) else {
                return nil
            }
            minute = parsed
        } else {
            minute = nil
        }

        let second: Int?
        if digits.count == 6 {
            guard let parsed = Int(digits.dropFirst(4).prefix(2)), (0...60).contains(parsed) else {
                return nil
            }
            second = parsed
        } else {
            second = nil
        }

        let fractionalSeconds: Double?
        if parts.count == 2 {
            let fractionDigits = String(parts[1])
            guard !fractionDigits.isEmpty,
                  fractionDigits.allSatisfy({ $0.isNumber }),
                  let parsed = Double("0." + fractionDigits) else {
                return nil
            }
            fractionalSeconds = parsed
        } else {
            fractionalSeconds = nil
        }

        self.rawValue = trimmed
        self.hour = hour
        self.minute = minute
        self.second = second
        self.fractionalSeconds = fractionalSeconds
    }
}

public struct DicomDateTime: Equatable, Hashable, Sendable {
    public let rawValue: String
    public let date: DicomDate
    public let time: DicomTime?
    public let timeZoneOffsetMinutes: Int?

    public init?(_ rawValue: String) {
        let trimmed = rawValue.dicomTrimmedValue
        guard trimmed.count >= 8 else { return nil }

        let zone: String?
        let body: String
        if trimmed.count >= 5 {
            let suffix = trimmed.suffix(5)
            if (suffix.first == "+" || suffix.first == "-") && suffix.dropFirst().allSatisfy({ $0.isNumber }) {
                zone = String(suffix)
                body = String(trimmed.dropLast(5))
            } else {
                zone = nil
                body = trimmed
            }
        } else {
            zone = nil
            body = trimmed
        }

        guard let date = DicomDate(String(body.prefix(8))) else { return nil }
        let timeBody = String(body.dropFirst(8))
        let time = timeBody.isEmpty ? nil : DicomTime(timeBody)
        if !timeBody.isEmpty && time == nil {
            return nil
        }

        let offsetMinutes: Int?
        if let zone {
            let sign = zone.first == "-" ? -1 : 1
            guard let hours = Int(zone.dropFirst().prefix(2)),
                  let minutes = Int(zone.dropFirst(3).prefix(2)),
                  (0...23).contains(hours),
                  (0...59).contains(minutes) else {
                return nil
            }
            offsetMinutes = sign * (hours * 60 + minutes)
        } else {
            offsetMinutes = nil
        }

        self.rawValue = trimmed
        self.date = date
        self.time = time
        self.timeZoneOffsetMinutes = offsetMinutes
    }
}

public indirect enum DicomDataValue: Equatable, Sendable {
    case empty
    case strings([String])
    case signedIntegers([Int])
    case unsignedIntegers([UInt])
    case floats([Double])
    case bytes(Data)
    case sequence([DicomSequenceItem])

    public var vm: DicomVM {
        switch self {
        case .empty:
            return .zero
        case .strings(let values):
            return DicomVM(count: values.count)
        case .signedIntegers(let values):
            return DicomVM(count: values.count)
        case .unsignedIntegers(let values):
            return DicomVM(count: values.count)
        case .floats(let values):
            return DicomVM(count: values.count)
        case .bytes(let data):
            return data.isEmpty ? .zero : .one
        case .sequence(let items):
            return DicomVM(count: items.count)
        }
    }
}

public struct DicomDataElement: Equatable, Sendable {
    public let tag: Int
    public let vr: DicomVR
    public let name: String?
    public let value: DicomDataValue

    public init(tag: Int, vr: DicomVR, value: DicomDataValue, name: String? = nil) {
        self.tag = tag
        self.vr = vr
        self.name = name
        self.value = value
    }

    public var group: Int {
        (tag >> 16) & 0xFFFF
    }

    public var element: Int {
        tag & 0xFFFF
    }

    public var isPrivate: Bool {
        (group & 1) == 1
    }

    public var vm: DicomVM {
        value.vm
    }

    public var stringValue: String? {
        stringValues.first
    }

    public var stringValues: [String] {
        switch value {
        case .empty:
            return []
        case .strings(let values):
            return values
        case .signedIntegers(let values):
            return values.map { String($0) }
        case .unsignedIntegers(let values):
            return values.map { String($0) }
        case .floats(let values):
            return values.map { String($0) }
        case .bytes:
            return []
        case .sequence:
            return []
        }
    }

    public var intValue: Int? {
        intValues.first
    }

    public var intValues: [Int] {
        switch value {
        case .signedIntegers(let values):
            return values
        case .unsignedIntegers(let values):
            return values.compactMap { Int(exactly: $0) }
        default:
            return stringValues.compactMap { Int($0.dicomTrimmedValue) }
        }
    }

    public var floatValue: Double? {
        floatValues.first
    }

    public var floatValues: [Double] {
        switch value {
        case .floats(let values):
            return values
        default:
            return stringValues.compactMap { Double($0.dicomTrimmedValue) }
        }
    }

    public var dateValue: DicomDate? {
        stringValue.flatMap(DicomDate.init)
    }

    public var timeValue: DicomTime? {
        stringValue.flatMap(DicomTime.init)
    }

    public var dateTimeValue: DicomDateTime? {
        stringValue.flatMap(DicomDateTime.init)
    }

    public var personNameValue: DicomPersonName? {
        stringValue.flatMap(DicomPersonName.init)
    }

    public var uidValue: DicomUID? {
        stringValue.flatMap(DicomUID.init)
    }

    public var ageValue: DicomAge? {
        stringValue.flatMap(DicomAge.init)
    }

    public var decimalStringValue: Double? {
        floatValue
    }

    public var decimalStringValues: [Double] {
        floatValues
    }

    public var integerStringValue: Int? {
        intValue
    }

    public var integerStringValues: [Int] {
        intValues
    }

    public var sequenceItems: [DicomSequenceItem] {
        if case .sequence(let items) = value {
            return items
        }
        return []
    }

    public var bytesValue: Data? {
        if case .bytes(let data) = value {
            return data
        }
        return nil
    }
}

public struct DicomSequenceItem: Equatable, Sendable {
    public let dataSet: DicomDataSet

    public init(dataSet: DicomDataSet) {
        self.dataSet = dataSet
    }

    public subscript(tag: Int) -> DicomDataElement? {
        dataSet.element(for: tag)
    }

    public subscript(tag: DicomTag) -> DicomDataElement? {
        dataSet.element(for: tag)
    }
}

public struct DicomDataSet: Equatable, Sendable {
    private var elementsByTag: [Int: DicomDataElement]

    public init(elements: [DicomDataElement] = []) {
        var storage: [Int: DicomDataElement] = [:]
        for element in elements {
            storage[element.tag] = element
        }
        self.elementsByTag = storage
    }

    public var elements: [DicomDataElement] {
        elementsByTag.keys.sorted().compactMap { elementsByTag[$0] }
    }

    public var count: Int {
        elementsByTag.count
    }

    public var isEmpty: Bool {
        elementsByTag.isEmpty
    }

    public subscript(tag: Int) -> DicomDataElement? {
        element(for: tag)
    }

    public subscript(tag: DicomTag) -> DicomDataElement? {
        element(for: tag)
    }

    public func contains(_ tag: Int) -> Bool {
        elementsByTag[tag] != nil
    }

    public func contains(_ tag: DicomTag) -> Bool {
        contains(tag.rawValue)
    }

    public mutating func set(_ element: DicomDataElement) {
        elementsByTag[element.tag] = element
    }

    public func setting(_ element: DicomDataElement) -> DicomDataSet {
        var copy = self
        copy.set(element)
        return copy
    }

    public mutating func remove(_ tag: Int) {
        elementsByTag.removeValue(forKey: tag)
    }

    public mutating func remove(_ tag: DicomTag) {
        remove(tag.rawValue)
    }

    public func removing(_ tag: Int) -> DicomDataSet {
        var copy = self
        copy.remove(tag)
        return copy
    }

    public func removing(_ tag: DicomTag) -> DicomDataSet {
        removing(tag.rawValue)
    }

    public func element(for tag: Int) -> DicomDataElement? {
        elementsByTag[tag]
    }

    public func element(for tag: DicomTag) -> DicomDataElement? {
        element(for: tag.rawValue)
    }

    public func vm(for tag: Int) -> DicomVM? {
        element(for: tag)?.vm
    }

    public func vm(for tag: DicomTag) -> DicomVM? {
        vm(for: tag.rawValue)
    }

    public func string(for tag: Int) -> String? {
        element(for: tag)?.stringValue
    }

    public func string(for tag: DicomTag) -> String? {
        string(for: tag.rawValue)
    }

    public func strings(for tag: Int) -> [String] {
        element(for: tag)?.stringValues ?? []
    }

    public func strings(for tag: DicomTag) -> [String] {
        strings(for: tag.rawValue)
    }

    public func int(for tag: Int) -> Int? {
        element(for: tag)?.intValue
    }

    public func int(for tag: DicomTag) -> Int? {
        int(for: tag.rawValue)
    }

    public func ints(for tag: Int) -> [Int] {
        element(for: tag)?.intValues ?? []
    }

    public func ints(for tag: DicomTag) -> [Int] {
        ints(for: tag.rawValue)
    }

    public func float(for tag: Int) -> Double? {
        element(for: tag)?.floatValue
    }

    public func float(for tag: DicomTag) -> Double? {
        float(for: tag.rawValue)
    }

    public func floats(for tag: Int) -> [Double] {
        element(for: tag)?.floatValues ?? []
    }

    public func floats(for tag: DicomTag) -> [Double] {
        floats(for: tag.rawValue)
    }

    public func date(for tag: Int) -> DicomDate? {
        element(for: tag)?.dateValue
    }

    public func date(for tag: DicomTag) -> DicomDate? {
        date(for: tag.rawValue)
    }

    public func time(for tag: Int) -> DicomTime? {
        element(for: tag)?.timeValue
    }

    public func time(for tag: DicomTag) -> DicomTime? {
        time(for: tag.rawValue)
    }

    public func dateTime(for tag: Int) -> DicomDateTime? {
        element(for: tag)?.dateTimeValue
    }

    public func dateTime(for tag: DicomTag) -> DicomDateTime? {
        dateTime(for: tag.rawValue)
    }

    public func personName(for tag: Int) -> DicomPersonName? {
        element(for: tag)?.personNameValue
    }

    public func personName(for tag: DicomTag) -> DicomPersonName? {
        personName(for: tag.rawValue)
    }

    public func uid(for tag: Int) -> DicomUID? {
        element(for: tag)?.uidValue
    }

    public func uid(for tag: DicomTag) -> DicomUID? {
        uid(for: tag.rawValue)
    }

    public func age(for tag: Int) -> DicomAge? {
        element(for: tag)?.ageValue
    }

    public func age(for tag: DicomTag) -> DicomAge? {
        age(for: tag.rawValue)
    }

    public func decimalString(for tag: Int) -> Double? {
        element(for: tag)?.decimalStringValue
    }

    public func decimalString(for tag: DicomTag) -> Double? {
        decimalString(for: tag.rawValue)
    }

    public func decimalStrings(for tag: Int) -> [Double] {
        element(for: tag)?.decimalStringValues ?? []
    }

    public func decimalStrings(for tag: DicomTag) -> [Double] {
        decimalStrings(for: tag.rawValue)
    }

    public func integerString(for tag: Int) -> Int? {
        element(for: tag)?.integerStringValue
    }

    public func integerString(for tag: DicomTag) -> Int? {
        integerString(for: tag.rawValue)
    }

    public func integerStrings(for tag: Int) -> [Int] {
        element(for: tag)?.integerStringValues ?? []
    }

    public func integerStrings(for tag: DicomTag) -> [Int] {
        integerStrings(for: tag.rawValue)
    }

    public func sequenceItems(for tag: Int) -> [DicomSequenceItem] {
        element(for: tag)?.sequenceItems ?? []
    }

    public func sequenceItems(for tag: DicomTag) -> [DicomSequenceItem] {
        sequenceItems(for: tag.rawValue)
    }
}

public extension DCMDecoder {
    var dataSet: DicomDataSet {
        synchronized {
            let tags = Set(dicomInfoDict.keys).union(tagMetadataCache.keys)
            let elements = tags.compactMap(dataElementUnsafe(for:))
            return DicomDataSet(elements: elements)
        }
    }

    func dataElement(for tag: DicomTag) -> DicomDataElement? {
        dataElement(for: tag.rawValue)
    }

    func dataElement(for tag: Int) -> DicomDataElement? {
        synchronized {
            dataElementUnsafe(for: tag)
        }
    }

    private func dataElementUnsafe(for tag: Int) -> DicomDataElement? {
        guard dicomInfoDict[tag] != nil || tagMetadataCache[tag] != nil else {
            return nil
        }

        let metadata = tagMetadataCache[tag]
        let vr = effectiveVR(for: tag, metadata: metadata)
        let name = dict.description(forTag: tag)
        let value = dataValue(for: tag, vr: vr, metadata: metadata)
        return DicomDataElement(tag: tag, vr: vr, value: value, name: name)
    }

    private func effectiveVR(for tag: Int, metadata: TagMetadata?) -> DicomVR {
        if let metadata, metadata.vr != .implicitRaw && metadata.vr != .unknown {
            return metadata.vr
        }
        return dictionaryVR(for: tag) ?? metadata?.vr ?? .unknown
    }

    private func dictionaryVR(for tag: Int) -> DicomVR? {
        guard let code = dict.vrCode(forTag: tag) else {
            return nil
        }
        return DicomVR(code: code)
    }

    private func dataValue(for tag: Int, vr: DicomVR, metadata: TagMetadata?) -> DicomDataValue {
        if vr == .SQ {
            guard let metadata,
                  metadata.offset >= 0,
                  metadata.elementLength >= 0,
                  metadata.offset + metadata.elementLength <= dicomData.count else {
                return .sequence([])
            }
            let items = (try? DicomSequenceValueParser.parseItems(
                in: dicomData,
                valueOffset: metadata.offset,
                valueLength: metadata.elementLength,
                littleEndian: littleEndian,
                explicitVR: isExplicitVRTransferSyntax,
                characterSet: activeCharacterSet
            )) ?? []
            return .sequence(items)
        }

        if let metadata,
           let raw = rawValueData(for: metadata),
           let value = DicomDataValueDecoder.binaryValue(
               for: vr,
               data: raw,
               littleEndian: littleEndian
           ) {
            return value
        }

        let rawString = infoUnsafe(for: tag)
        let values = rawString.dicomMultiValues
        return values.isEmpty ? .empty : .strings(values)
    }

    private func rawValueData(for metadata: TagMetadata) -> Data? {
        guard metadata.elementLength > 0,
              metadata.offset >= 0,
              metadata.offset <= dicomData.count,
              metadata.offset + metadata.elementLength <= dicomData.count else {
            return nil
        }
        return dicomData[metadata.offset..<(metadata.offset + metadata.elementLength)]
    }
}

public extension DicomVR {
    init?(code: String) {
        let bytes = Array(code.utf8)
        guard bytes.count == 2 else { return nil }
        let rawValue = Int(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        self.init(rawValue: rawValue)
    }

    var code: String {
        guard self != .unknown else { return "UN" }
        let high = UInt8((rawValue >> 8) & 0xFF)
        let low = UInt8(rawValue & 0xFF)
        return String(bytes: [high, low], encoding: .ascii) ?? "UN"
    }
}

private extension String {
    var dicomTrimmedValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    var dicomMultiValues: [String] {
        let trimmed = dicomTrimmedValue
        guard !trimmed.isEmpty else { return [] }
        return trimmed
            .split(separator: "\\", omittingEmptySubsequences: false)
            .map { String($0).dicomTrimmedValue }
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
