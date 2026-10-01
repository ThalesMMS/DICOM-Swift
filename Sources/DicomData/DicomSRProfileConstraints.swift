import Foundation

/// IOD-level content constraints of PS3.3 A.35 for the SR SOP Classes the toolkit offers:
/// the permitted Value Types (A.35.x.3.1.1) and the mandatory root template of Key Object
/// Selection (A.35.4.3.1.3). Relationship tables live in `DicomSRRelationshipConstraints`;
/// template content (TID) is outside this layer.
public enum DicomSRProfileConstraints: String, Sendable, CaseIterable {
    case enhanced = "1.2.840.10008.5.1.4.1.1.88.22"
    case comprehensive3D = "1.2.840.10008.5.1.4.1.1.88.34"
    case comprehensive = "1.2.840.10008.5.1.4.1.1.88.33"
    case keyObjectSelection = "1.2.840.10008.5.1.4.1.1.88.59"

    public init?(sopClassUID: String) { self.init(rawValue: sopClassUID) }

    public var sopClassUID: String { rawValue }

    public var kind: DicomSRDocumentModule.Kind { self == .keyObjectSelection ? .keyObjectSelection : .structuredReport }

    /// A.35.2.3.1.1, A.35.3.3.1.1 and A.35.4.3.1.1 enumerated Value Types.
    public var valueTypes: Set<String> {
        switch self {
        case .enhanced, .comprehensive:
            return ["TEXT", "CODE", "NUM", "DATETIME", "DATE", "TIME", "UIDREF", "PNAME", "SCOORD", "TCOORD", "COMPOSITE",
                    "IMAGE", "WAVEFORM", "CONTAINER"]
        case .comprehensive3D:
            return Self.comprehensive.valueTypes.union(["SCOORD3D"])
        case .keyObjectSelection:
            return ["TEXT", "CODE", "UIDREF", "PNAME", "COMPOSITE", "IMAGE", "WAVEFORM", "CONTAINER", "DATE", "TIME", "DATETIME", "NUM"]
        }
    }

    /// Root template that the IOD mandates; nil when the IOD leaves the template to the author.
    public var rootTemplateIdentifier: String? { self == .keyObjectSelection ? "2010" : nil }

    /// Rules on the root content item for a mandated template identification.
    public func rootTemplateRules() -> [DicomAttributeRule] {
        guard let identifier = rootTemplateIdentifier else { return [] }
        return [
            .init(tag: 0x0040A504, requirement: .type1, itemRules: [
                .init(tag: 0x00080105, requirement: .type1, constraints: [.strings(["DCMR"])]),
                .init(tag: 0x0040DB00, requirement: .type1, constraints: [.strings([identifier])])
            ], constraints: [.itemCount(1...1)])
        ]
    }
}
