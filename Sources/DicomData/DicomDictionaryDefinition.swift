import Foundation

public struct DicomDictionaryDefinition: Codable, Equatable, Sendable {
    private let vrs: [String]
    public let vm: String
    public let name: String
    public let keyword: String
    public let retired: Bool

    public enum Failure: Error, Equatable, Sendable { case invalidDefinition }

    public init(valueRepresentations: [DicomVR], multiplicity: String, name: String,
                keyword: String = "", retired: Bool = false) throws {
        guard !valueRepresentations.contains(where: { [.unknown, .implicitRaw, .QQ, .RT].contains($0) }) else {
            throw Failure.invalidDefinition
        }
        vrs = valueRepresentations.map(\.code)
        vm = multiplicity
        self.name = name
        self.keyword = keyword
        self.retired = retired
        guard isValid else { throw Failure.invalidDefinition }
    }

    private enum CodingKeys: String, CodingKey { case vrs, vm, name, keyword, retired }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        vrs = try values.decode([String].self, forKey: .vrs)
        vm = try values.decode(String.self, forKey: .vm)
        name = try values.decode(String.self, forKey: .name)
        keyword = try values.decode(String.self, forKey: .keyword)
        retired = try values.decode(Bool.self, forKey: .retired)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid DICOM dictionary definition"))
        }
    }

    public var valueRepresentations: [DicomVR] { vrs.compactMap(DicomVR.init(code:)) }

    /// Zero length is permitted at the dataset layer; IOD Type 1/2 rules are separate.
    public func acceptsMultiplicity(_ count: Int) -> Bool {
        guard count >= 0, let rule = multiplicityRule else { return false }
        return count == 0 || (count >= rule.minimum && count <= rule.maximum && count.isMultiple(of: rule.step))
    }

    func acceptsMultiplicity(of element: DicomDataElement, purpose: DicomDataSetPurpose) -> Bool {
        // PS3.5 6.4 treats all-empty textual components as an empty value field.
        if case .strings(let values) = element.value, values.allSatisfy({ $0.allSatisfy { $0 == " " } }) { return true }
        // PS3.4 C.2.2.2.2 encodes query UID lists using VM even for a VM-1 attribute.
        if purpose == .query, element.vr == .UI { return true }
        return acceptsMultiplicity(element.vm.count)
    }

    var legacyVR: DicomVR { valueRepresentations.contains(.OW) ? .OW : (valueRepresentations.first ?? .UN) }

    var isValid: Bool {
        !vrs.isEmpty && Set(vrs).count == vrs.count && valueRepresentations.count == vrs.count
            && !valueRepresentations.contains(where: { [.unknown, .implicitRaw, .QQ, .RT].contains($0) })
            && multiplicityRule != nil && !name.isEmpty
    }

    private var multiplicityRule: (minimum: Int, maximum: Int, step: Int)? {
        guard vm.utf8.allSatisfy({ (0x30...0x39).contains($0) || $0 == 0x2D || $0 == 0x6E }) else { return nil }
        let parts = vm.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let minimum = Int(parts[0]), minimum > 0 else { return nil }
        if parts.count == 1 { return (minimum, minimum, 1) }
        if parts[1] == "n" { return (minimum, Int.max, 1) }
        if parts[1].last == "n", let step = Int(parts[1].dropLast()), step == minimum {
            return (minimum, Int.max, step)
        }
        guard let maximum = Int(parts[1]), maximum >= minimum else { return nil }
        return (minimum, maximum, 1)
    }
}
