import Foundation

/// Composition of the Encapsulated PDF, CDA, STL, OBJ and MTL IODs (PS3.3 2026c A.45/A.85) over the
/// generated tables: the Encapsulated Document Series and Document modules with the modality and
/// MIME type of each IOD, SC Equipment for the document IODs, Enhanced General Equipment, Frame of
/// Reference and Manufacturing 3D Model for the model IODs, the Common Instance Reference condition,
/// the document length and the referenced instances against supplied targets.
public enum DicomEncapsulatedDocumentModules {
    public enum Profile: String, Sendable, CaseIterable {
        case pdf = "1.2.840.10008.5.1.4.1.1.104.1"
        case cda = "1.2.840.10008.5.1.4.1.1.104.2"
        case stl = "1.2.840.10008.5.1.4.1.1.104.3"
        case obj = "1.2.840.10008.5.1.4.1.1.104.4"
        case mtl = "1.2.840.10008.5.1.4.1.1.104.5"

        public var sopClassUID: String { rawValue }

        var key: String {
            switch self {
            case .pdf: return "encapsulatedPDF"
            case .cda: return "encapsulatedCDA"
            case .stl: return "encapsulatedSTL"
            case .obj: return "encapsulatedOBJ"
            case .mtl: return "encapsulatedMTL"
            }
        }

        /// C.24.1: DOC for documents, M3D for manufacturing models.
        public var modality: String { self == .pdf || self == .cda ? "DOC" : "M3D" }

        /// A.45.x: the MIME Type of Encapsulated Document of each IOD.
        public var mimeTypes: Set<String> {
            switch self {
            case .pdf: return ["application/pdf"]
            case .cda: return ["text/XML", "text/xml"]
            case .stl: return ["model/stl"]
            case .obj: return ["model/obj"]
            case .mtl: return ["model/mtl"]
            }
        }

        /// A.85.1/A.85.2: the STL and OBJ IODs carry a Frame of Reference.
        var requiresFrameOfReference: Bool { self == .stl || self == .obj }
    }

    typealias State = DicomEnhancedImageModules.State

    static let handledElsewhere: Set<String> = [
        "Patient", "Clinical Trial Subject", "General Study", "Patient Study", "Clinical Trial Study", "Clinical Trial Series",
        "General Equipment", "SOP Common", "Frame of Reference", "Common Instance Reference", "ICC Profile"
    ]

    public static func validate(_ dataSet: DicomDataSet, profile: Profile, targets: [String: DicomDataSet] = [:],
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        var state = State(limits: limits)
        guard let iod = DicomEnhancedImageTables.iods[profile.key] else {
            state.record(.moduleRuleUnavailable, path: [.tag(0x00080016)], severity: .limitation)
            return state.report
        }
        let context = DicomEnhancedImageTableRules.Context(root: dataSet, sopClassUID: profile.sopClassUID, shared: nil, frame: nil,
                                                            frames: [], facts: .init(), pixelData: .none)
        for module in iod.modules where !handledElsewhere.contains(module.name) {
            guard !state.stopped else { return state.report }
            state.evaluate(DicomEnhancedImageTableRules.rules(table: module.table, context: context), on: dataSet, path: [])
        }
        guard !state.stopped else { return state.report }
        if profile.requiresFrameOfReference, !dataSet.contains(0x00200052) {
            state.record(.requiredAttributeMissing, path: [.tag(0x00200052)], requirement: .type1)
        }
        // A.85.1–A.85.3: Common Instance Reference is required once other instances are referenced.
        if profile != .pdf, profile != .cda, [0x00420013, 0x00081140, 0x0008114A].contains(where: dataSet.contains),
           !dataSet.contains(0x00081115), !dataSet.contains(0x00081200) {
            state.record(.requiredAttributeMissing, path: [.tag(0x00081115)], requirement: .type1C)
        }
        // C.24.2: Encapsulated Document Length counts the document bytes, not the even-length padding.
        if let length = dataSet[0x00420015]?.intValue, let document = dataSet[0x00420011]?.bytesValue {
            if document.count != length && !(length >= 0 && length % 2 == 1 && document.count == length + 1 && document.last == 0) {
                state.record(.attributeValueContradiction, path: [.tag(0x00420015)])
            }
        }
        // SR content items of an encapsulated document are outside this composition.
        if dataSet.contains(0x0040A730) {
            state.record(.conditionUndetermined, path: [.tag(0x0040A730)], severity: .limitation)
        }
        guard !state.stopped else { return state.report }
        DicomReferenceTargetWalk.validate(dataSet, targets: targets, state: &state)
        return state.report
    }
}
