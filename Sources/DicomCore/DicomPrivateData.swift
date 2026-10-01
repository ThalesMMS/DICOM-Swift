import Foundation

public struct DicomPrivateCreator: Equatable, Hashable, Sendable {
    public let group: Int
    public let element: Int
    public let identifier: String

    public init(group: Int, element: Int, identifier: String) {
        self.group = group
        self.element = element
        self.identifier = identifier
    }

    public var tag: Int {
        (group << 16) | element
    }

    public var block: Int {
        element & 0x00FF
    }
}

public struct DicomPrivateElement: Equatable, Sendable {
    public let creator: DicomPrivateCreator
    public let element: DicomDataElement

    public init(creator: DicomPrivateCreator, element: DicomDataElement) {
        self.creator = creator
        self.element = element
    }

    public var privateElement: Int {
        element.element & 0x00FF
    }
}

public enum DicomPrivateElementParser: String, Sendable {
    case siemensCSA
}

public struct DicomPrivateDictionaryEntry: Equatable, Sendable {
    public let creator: String
    public let privateElement: Int
    public let vr: DicomVR
    public let name: String
    public let parser: DicomPrivateElementParser?

    public init(creator: String,
                privateElement: Int,
                vr: DicomVR,
                name: String,
                parser: DicomPrivateElementParser? = nil) {
        self.creator = creator
        self.privateElement = privateElement
        self.vr = vr
        self.name = name
        self.parser = parser
    }
}

public struct DicomPrivateDictionary: Sendable {
    public static let standard = DicomPrivateDictionary()

    private let entriesByCreatorAndElement: [String: DicomPrivateDictionaryEntry]

    public init(entries: [DicomPrivateDictionaryEntry]? = nil) {
        var storage: [String: DicomPrivateDictionaryEntry] = [:]
        for entry in entries ?? Self.defaultEntries {
            storage[Self.key(creator: entry.creator, privateElement: entry.privateElement)] = entry
        }
        self.entriesByCreatorAndElement = storage
    }

    public func entry(forCreator creator: String, privateElement: Int) -> DicomPrivateDictionaryEntry? {
        entriesByCreatorAndElement[Self.key(creator: creator, privateElement: privateElement)]
    }

    private static func key(creator: String, privateElement: Int) -> String {
        "\(creator.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())|\(privateElement & 0x00FF)"
    }

    private static let defaultEntries: [DicomPrivateDictionaryEntry] = [
        DicomPrivateDictionaryEntry(creator: "SIEMENS CSA HEADER",
                                   privateElement: 0x10,
                                   vr: .OB,
                                   name: "CSA Image Header Info",
                                   parser: .siemensCSA),
        DicomPrivateDictionaryEntry(creator: "SIEMENS CSA HEADER",
                                   privateElement: 0x20,
                                   vr: .OB,
                                   name: "CSA Series Header Info",
                                   parser: .siemensCSA),
        DicomPrivateDictionaryEntry(creator: "SIEMENS MR HEADER",
                                   privateElement: 0x0C,
                                   vr: .IS,
                                   name: "B Value"),
        DicomPrivateDictionaryEntry(creator: "SIEMENS MR HEADER",
                                   privateElement: 0x0E,
                                   vr: .CS,
                                   name: "Diffusion Directionality"),
        DicomPrivateDictionaryEntry(creator: "SIEMENS MR HEADER",
                                   privateElement: 0x0F,
                                   vr: .DS,
                                   name: "Diffusion Gradient Direction")
    ]
}

public struct SiemensCSATag: Equatable, Sendable {
    public let name: String
    public let vr: String
    public let vm: Int
    public let values: [String]

    public init(name: String, vr: String, vm: Int, values: [String]) {
        self.name = name
        self.vr = vr
        self.vm = vm
        self.values = values
    }
}

public struct SiemensCSAHeader: Equatable, Sendable {
    public let tags: [SiemensCSATag]

    public init(tags: [SiemensCSATag]) {
        self.tags = tags
    }

    public subscript(name: String) -> SiemensCSATag? {
        tags.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public var bValue: Double? {
        numericValues(named: "B_value")?.first ?? numericValues(named: "BValue")?.first
    }

    public var diffusionGradientDirection: [Double]? {
        numericValues(named: "DiffusionGradientDirection")
    }

    public var imageOrientationPatient: [Double]? {
        numericValues(named: "ImageOrientationPatient")
    }

    /// The numbers of a CSA element, backslash-separated values flattened.
    public func numericValues(named name: String) -> [Double]? {
        guard let tag = self[name] else { return nil }
        let values = tag.values
            .flatMap { $0.split(separator: "\\", omittingEmptySubsequences: false).map(String.init) }
            .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return values.isEmpty ? nil : values
    }
}

public enum SiemensCSAParser {
    public static func parse(_ data: Data) -> SiemensCSAHeader? {
        var offset = 0
        if data.count >= 8, String(data: data[0..<4], encoding: .ascii) == "SV10" {
            offset = 8
        }

        guard let tagCount = readUInt32(data, offset: &offset),
              tagCount > 0,
              tagCount < 1024,
              readUInt32(data, offset: &offset) != nil else {
            return nil
        }

        var tags: [SiemensCSATag] = []
        for _ in 0..<tagCount {
            guard let name = readPaddedString(data, offset: &offset, length: 64),
                  let vm = readUInt32(data, offset: &offset),
                  let vr = readPaddedString(data, offset: &offset, length: 4),
                  readUInt32(data, offset: &offset) != nil,
                  let itemCount = readUInt32(data, offset: &offset),
                  itemCount < 1024,
                  readUInt32(data, offset: &offset) != nil else {
                return nil
            }

            var values: [String] = []
            for _ in 0..<itemCount {
                guard let itemLength = readUInt32(data, offset: &offset),
                      readUInt32(data, offset: &offset) != nil,
                      readUInt32(data, offset: &offset) != nil,
                      readUInt32(data, offset: &offset) != nil,
                      itemLength <= UInt32(data.count - offset) else {
                    return nil
                }

                let length = Int(itemLength)
                let rawValue = data[offset..<(offset + length)]
                offset += paddedLength(length)
                guard offset <= data.count else {
                    return nil
                }

                let value = normalizedString(Data(rawValue))
                if !value.isEmpty {
                    values.append(value)
                }
            }

            tags.append(SiemensCSATag(name: name, vr: vr, vm: Int(vm), values: values))
        }
        return SiemensCSAHeader(tags: tags)
    }

    private static func readUInt32(_ data: Data, offset: inout Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let value = UInt32(data[offset]) |
            UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 |
            UInt32(data[offset + 3]) << 24
        offset += 4
        return value
    }

    private static func readPaddedString(_ data: Data, offset: inout Int, length: Int) -> String? {
        guard offset + length <= data.count else { return nil }
        let value = normalizedString(data[offset..<(offset + length)])
        offset += length
        return value
    }

    private static func normalizedString(_ data: Data) -> String {
        var value = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if let nullIndex = value.firstIndex(of: "\0") {
            value = String(value[..<nullIndex])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func paddedLength(_ length: Int) -> Int {
        length + ((4 - (length % 4)) % 4)
    }
}

public extension DicomDataElement {
    var isPrivateCreator: Bool {
        isPrivate && (0x0010...0x00FF).contains(element)
    }

    var privateCreatorBlock: Int? {
        guard isPrivate, element >= 0x1000 else { return nil }
        return (element >> 8) & 0x00FF
    }

    var privateElementIndex: Int? {
        guard isPrivate, element >= 0x1000 else { return nil }
        return element & 0x00FF
    }
}

public extension DicomDataSet {
    var privateCreators: [DicomPrivateCreator] {
        elements.compactMap { element in
            guard element.isPrivateCreator,
                  let identifier = element.stringValue,
                  !identifier.isEmpty else {
                return nil
            }
            return DicomPrivateCreator(group: element.group,
                                       element: element.element,
                                       identifier: identifier)
        }
    }

    func privateCreator(for element: DicomDataElement) -> DicomPrivateCreator? {
        guard let block = element.privateCreatorBlock else { return nil }
        let creatorTag = (element.group << 16) | block
        guard let identifier = string(for: creatorTag), !identifier.isEmpty else {
            return nil
        }
        return DicomPrivateCreator(group: element.group, element: block, identifier: identifier)
    }

    func privateElements(forCreator identifier: String, group: Int? = nil) -> [DicomPrivateElement] {
        let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return elements.compactMap { element in
            guard element.isPrivate,
                  !element.isPrivateCreator,
                  group == nil || element.group == group,
                  let creator = privateCreator(for: element),
                  creator.identifier.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normalizedIdentifier else {
                return nil
            }
            return DicomPrivateElement(creator: creator, element: element)
        }
    }

    func privateElement(group: Int, creator identifier: String, privateElement: Int) -> DicomDataElement? {
        privateElements(forCreator: identifier, group: group)
            .first { $0.privateElement == (privateElement & 0x00FF) }?
            .element
    }

    func privateDictionaryEntry(for element: DicomDataElement,
                                dictionary: DicomPrivateDictionary = .standard) -> DicomPrivateDictionaryEntry? {
        guard let creator = privateCreator(for: element),
              let privateElement = element.privateElementIndex else {
            return nil
        }
        return dictionary.entry(forCreator: creator.identifier, privateElement: privateElement)
    }

    func siemensCSAHeader(for tag: Int) -> SiemensCSAHeader? {
        guard let element = element(for: tag),
              privateDictionaryEntry(for: element)?.parser == .siemensCSA,
              let data = element.bytesValue else {
            return nil
        }
        return SiemensCSAParser.parse(data)
    }

    var siemensCSAHeaders: [Int: SiemensCSAHeader] {
        var headers: [Int: SiemensCSAHeader] = [:]
        for element in elements where privateDictionaryEntry(for: element)?.parser == .siemensCSA {
            if let data = element.bytesValue, let header = SiemensCSAParser.parse(data) {
                headers[element.tag] = header
            }
        }
        return headers
    }
}
