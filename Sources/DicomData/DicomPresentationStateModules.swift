import Foundation

/// Composition of the Grayscale, Color, Pseudo-Color and Blending Softcopy Presentation State IODs
/// (PS3.3 2026c A.33.1–A.33.4) over the generated tables: the IOD-specific modules with their usage
/// clauses, the shutters, overlays and their activation, ICC and palette requirements, the A.33.3/A.33.4
/// exclusions, the graphic, layer, displayed area, mask and blending coherence, and the identity of the
/// referenced images against supplied targets. Common Patient/Study/Series/Equipment/SOP Common rules are
/// composed by `DicomCompositeImageModules`; Modality and VOI LUT data are checked by the DicomCore helpers.
public enum DicomPresentationStateModules {
    public enum Profile: String, Sendable, CaseIterable {
        case grayscale = "1.2.840.10008.5.1.4.1.1.11.1"
        case color = "1.2.840.10008.5.1.4.1.1.11.2"
        case pseudoColor = "1.2.840.10008.5.1.4.1.1.11.3"
        case blending = "1.2.840.10008.5.1.4.1.1.11.4"

        public var sopClassUID: String { rawValue }

        var key: String {
            switch self {
            case .grayscale: return "grayscaleSoftcopyPS"
            case .color: return "colorSoftcopyPS"
            case .pseudoColor: return "pseudoColorSoftcopyPS"
            case .blending: return "blendingSoftcopyPS"
            }
        }

        /// A.33.2/A.33.3/A.33.4: the ICC Profile module is mandatory for the color presentation states.
        var requiresICCProfile: Bool { self != .grayscale }
    }

    /// Modules composed by the common helpers or by hand below.
    static let handledElsewhere: Set<String> = [
        "Patient", "Clinical Trial Subject", "General Study", "Patient Study", "Clinical Trial Study", "General Series",
        "Clinical Trial Series", "General Equipment", "SOP Common", "Specimen", "ICC Profile", "Overlay Plane",
        "Overlay Activation", "Display Shutter", "Bitmap Display Shutter"
    ]

    static let overlayElements = [0x0010, 0x0011, 0x0015, 0x0022, 0x0040, 0x0045, 0x0050, 0x0051, 0x0100, 0x0102, 0x1301, 0x1302,
                                  0x1303, 0x1500, 0x3000]

    /// Overlay groups (0x6000...0x601E) declared by the instance, optionally counting an activation layer alone.
    static func overlayGroups(in dataSet: DicomDataSet, includingActivation: Bool) -> [Int] {
        stride(from: 0x6000, through: 0x601E, by: 2).filter { group in
            let base = group << 16
            return overlayElements.contains { dataSet.contains(base | $0) } || (includingActivation && dataSet.contains(base | 0x1001))
        }
    }

    public static func validate(_ dataSet: DicomDataSet, profile: Profile, targets: [String: DicomDataSet] = [:],
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        var state = DicomEnhancedImageModules.State(limits: limits)
        guard let iod = DicomEnhancedImageTables.iods[profile.key] else {
            state.record(.moduleRuleUnavailable, path: [.tag(0x00080016)], severity: .limitation)
            return state.report
        }
        let context = DicomEnhancedImageTableRules.Context(root: dataSet, sopClassUID: profile.sopClassUID, shared: nil, frame: nil,
                                                            frames: [], facts: .init(), pixelData: .none)
        validateModules(dataSet, iod: iod, profile: profile, context: context, state: &state)
        guard !state.stopped else { return state.report }
        validateShuttersAndOverlays(dataSet, profile: profile, context: context, state: &state)
        guard !state.stopped else { return state.report }
        validateExclusions(dataSet, profile: profile, state: &state)
        validateCoherence(dataSet, profile: profile, state: &state)
        guard !state.stopped else { return state.report }
        validateReferences(dataSet, profile: profile, targets: targets, state: &state)
        return state.report
    }

    // MARK: - Modules

    private static func validateModules(_ dataSet: DicomDataSet, iod: DicomEnhancedImageTables.IOD, profile: Profile,
                                        context: DicomEnhancedImageTableRules.Context, state: inout DicomEnhancedImageModules.State) {
        for module in iod.modules where !handledElsewhere.contains(module.name) {
            guard !state.stopped else { return }
            let tags = DicomEnhancedImageTableRules.topLevelTags(module.table)
            let declared = tags.contains(where: dataSet.contains)
            let requirement: (truth: DicomAttributeRule.Truth, mayBePresent: Bool)
            switch module.usage {
            case "M": requirement = (.satisfied, true)
            case "U": requirement = (declared ? .satisfied : .unsatisfied, true)
            default: requirement = DicomEnhancedImageConditions.presentationModuleCondition(profile, module.name, dataSet, declared: declared)
            }
            switch requirement.truth {
            case .satisfied:
                state.evaluate(DicomEnhancedImageTableRules.rules(table: module.table, context: context), on: dataSet, path: [])
            case .unsatisfied:
                if declared, !requirement.mayBePresent, let tag = tags.first(where: dataSet.contains) {
                    state.record(.conditionalAttributeForbidden, path: [.tag(tag)])
                }
            case .undetermined:
                if declared {
                    state.evaluate(DicomEnhancedImageTableRules.rules(table: module.table, context: context), on: dataSet, path: [])
                } else if let tag = tags.first {
                    state.record(.conditionUndetermined, path: [.tag(tag)], severity: .limitation)
                }
            }
        }
        if profile.requiresICCProfile, !dataSet.contains(0x00282000) {
            state.record(.requiredAttributeMissing, path: [.tag(0x00282000)], requirement: .type1)
        }
    }

    // MARK: - Shutters, overlays and their activation (C.7.6.11, C.7.6.15, C.9.2, C.11.7)

    private static func validateShuttersAndOverlays(_ dataSet: DicomDataSet, profile: Profile, context: DicomEnhancedImageTableRules.Context,
                                                    state: inout DicomEnhancedImageModules.State) {
        guard profile != .blending else { return }
        let groups = overlayGroups(in: dataSet, includingActivation: false)
        if dataSet.contains(0x00181623) {
            // A Bitmap Display Shutter names the overlay group that carries its bitmap; that overlay must be present.
            state.evaluate(DicomEnhancedImageTableRules.rules(table: "C.7.6.15", context: context), on: dataSet, path: [])
            if let element = dataSet[0x00181623], element.vr == .US, element.vm.count == 1, let group = element.intValue {
                if (0x6000...0x601E).contains(group), group.isMultiple(of: 2) {
                    if !groups.contains(group) { state.record(.requiredAttributeMissing, path: [.tag(group << 16 | 0x3000)], requirement: .type1C) }
                } else {
                    state.record(.attributeValueNotAllowed, path: [.tag(0x00181623)])
                }
            }
        } else if dataSet.contains(0x00181600) {
            state.evaluate(DicomEnhancedImageTableRules.rules(table: "C.7.6.11", context: context), on: dataSet, path: [])
        }
        guard !state.stopped else { return }
        // C.11.7: every overlay carried by the instance needs its activation layer (Type 2C); a named layer must exist.
        let layers = Set((dataSet[0x00700060]?.sequenceItems ?? []).compactMap { DicomEnhancedImageTableRules.Context.trimmed($0.dataSet[0x00700002], index: 0) })
        for group in overlayGroups(in: dataSet, includingActivation: true) {
            let activation = group << 16 | 0x1001
            guard let element = dataSet[activation] else {
                if groups.contains(group) { state.record(.requiredAttributeMissing, path: [.tag(activation)], requirement: .type2C) }
                continue
            }
            if let layer = DicomEnhancedImageTableRules.Context.trimmed(element, index: 0), !layers.contains(layer) {
                state.record(.attributeValueContradiction, path: [.tag(activation)])
            }
        }
    }

    // MARK: - IOD exclusions (A.33.3, A.33.4)

    private static func validateExclusions(_ dataSet: DicomDataSet, profile: Profile, state: inout DicomEnhancedImageModules.State) {
        let excluded: [Int]
        switch profile {
        case .grayscale, .color: return
        case .pseudoColor: excluded = [0x20500010, 0x20500020]
        case .blending: excluded = [0x20500010, 0x20500020, 0x00281050, 0x00281051, 0x00283010, 0x00283110, 0x00181600, 0x00181623]
        }
        for tag in excluded where dataSet.contains(tag) {
            state.record(.conditionalAttributeForbidden, path: [.tag(tag)])
        }
        if profile == .blending {
            for group in overlayGroups(in: dataSet, includingActivation: true) {
                let base = group << 16
                let tag = overlayElements.map { base | $0 }.first(where: dataSet.contains) ?? (base | 0x1001)
                state.record(.conditionalAttributeForbidden, path: [.tag(tag)])
            }
        }
    }

    // MARK: - Coherence (C.10.4, C.10.5, C.10.7, C.11.11, C.11.13, C.11.14)

    private static func validateCoherence(_ dataSet: DicomDataSet, profile: Profile, state: inout DicomEnhancedImageModules.State) {
        typealias Path = [DicomValidationReport.PathComponent]
        let trimmed = DicomEnhancedImageTableRules.Context.trimmed
        // C.10.7: layer names are unique and every annotation names a declared layer.
        var layers = Set<String>()
        for (index, item) in (dataSet[0x00700060]?.sequenceItems ?? []).enumerated() {
            guard let name = trimmed(item.dataSet[0x00700002], 0) else { continue }
            if !layers.insert(name).inserted { state.record(.attributeValueContradiction, path: [.tag(0x00700060), .item(index), .tag(0x00700002)]) }
        }
        let relationship = referencedImages(in: dataSet)
        func checkReferences(_ item: DicomDataSet, path: Path) {
            for (index, reference) in (item[0x00081140]?.sequenceItems ?? []).enumerated() {
                guard let instance = trimmed(reference.dataSet[0x00081155], 0), !relationship.contains(instance) else { continue }
                state.record(.referenceSelectionInvalid, path: path + [.tag(0x00081140), .item(index), .tag(0x00081155)])
            }
        }
        for (index, item) in (dataSet[0x00700001]?.sequenceItems ?? []).enumerated() {
            let path: Path = [.tag(0x00700001), .item(index)]
            if let name = trimmed(item.dataSet[0x00700002], 0), !layers.contains(name) {
                state.record(.attributeValueContradiction, path: path + [.tag(0x00700002)])
            }
            checkReferences(item.dataSet, path: path)
            for (objectIndex, object) in (item.dataSet[0x00700009]?.sequenceItems ?? []).enumerated() {
                validateGraphicObject(object.dataSet, path: path + [.tag(0x00700009), .item(objectIndex)], state: &state)
            }
        }
        // C.10.4: every displayed area is a non-empty rectangle; its references are listed in the relationship.
        for (index, item) in (dataSet[0x0070005A]?.sequenceItems ?? []).enumerated() {
            let path: Path = [.tag(0x0070005A), .item(index)]
            checkReferences(item.dataSet, path: path)
            if let topLeft = signed(item.dataSet[0x00700052]), let bottomRight = signed(item.dataSet[0x00700053]),
               topLeft.count == 2, bottomRight.count == 2, topLeft[0] > bottomRight[0] || topLeft[1] > bottomRight[1] {
                state.record(.attributeValueContradiction, path: path + [.tag(0x00700053)])
            }
        }
        for (index, item) in (dataSet[0x00283110]?.sequenceItems ?? []).enumerated() {
            checkReferences(item.dataSet, path: [.tag(0x00283110), .item(index)])
        }
        // C.11.11: one SOP Class per referenced series item.
        for (index, series) in (dataSet[0x00081115]?.sequenceItems ?? []).enumerated() {
            let classes = Set((series.dataSet[0x00081140]?.sequenceItems ?? []).compactMap { trimmed($0.dataSet[0x00081150], 0) })
            if classes.count > 1 { state.record(.attributeValueContradiction, path: [.tag(0x00081115), .item(index), .tag(0x00081140)]) }
        }
        // C.11.13: averaging is required when several mask frames are named.
        if let mask = dataSet[0x00286100]?.sequenceItems.first?.dataSet, let frames = mask[0x00286110], frames.vm.count > 1, !mask.contains(0x00286112) {
            state.record(.requiredAttributeMissing, path: [.tag(0x00286100), .item(0), .tag(0x00286112)], requirement: .type1C)
        }
        // C.11.14: one SUPERIMPOSED and one UNDERLYING item; opacity within 0...1.
        if profile == .blending, let items = dataSet[0x00700402]?.sequenceItems {
            let positions = items.compactMap { trimmed($0.dataSet[0x00700405], 0) }
            if positions.count == items.count, Set(positions) != ["SUPERIMPOSED", "UNDERLYING"], items.count == 2 {
                state.record(.attributeValueContradiction, path: [.tag(0x00700402), .item(1), .tag(0x00700405)])
            }
            if let opacity = dataSet[0x00700403], case .floats(let values) = opacity.value, values.count == 1, !(0...1).contains(values[0]) {
                state.record(.attributeValueNotAllowed, path: [.tag(0x00700403)])
            }
        }
    }

    /// C.10.5.1.2: point counts per graphic type, two coordinates per point, and closed polylines declare filling.
    private static func validateGraphicObject(_ object: DicomDataSet, path: [DicomValidationReport.PathComponent],
                                              state: inout DicomEnhancedImageModules.State) {
        guard let type = DicomEnhancedImageTableRules.Context.trimmed(object[0x00700023], index: 0),
              let count = object[0x00700021], count.vr == .US, count.vm.count == 1, let points = count.intValue,
              let data = object[0x00700022], case .floats(let values) = data.value else { return }
        let expected: ClosedRange<Int>? = switch type {
        case "POINT": 1...1
        case "CIRCLE": 2...2
        case "ELLIPSE": 4...4
        case "POLYLINE", "INTERPOLATED": 2...Int.max
        default: nil
        }
        if let expected, !expected.contains(points) { state.record(.attributeValueContradiction, path: path + [.tag(0x00700021)]) }
        if values.count != points * 2 {
            state.record(.attributeValueContradiction, path: path + [.tag(0x00700022)])
            return
        }
        if ["POLYLINE", "INTERPOLATED"].contains(type), points >= 2, values[0] == values[values.count - 2], values[1] == values[values.count - 1],
           !object.contains(0x00700024) {
            state.record(.requiredAttributeMissing, path: path + [.tag(0x00700024)], requirement: .type1C)
        }
    }

    private static func signed(_ element: DicomDataElement?) -> [Int]? {
        guard let element, element.vr == .SL, case .signedIntegers(let values) = element.value else { return nil }
        return values
    }

    /// SOP Instance UIDs listed by the Presentation State Relationship module (and the blending items).
    private static func referencedImages(in dataSet: DicomDataSet) -> Set<String> {
        var result = Set<String>()
        let series = (dataSet[0x00081115]?.sequenceItems ?? []) + (dataSet[0x00700402]?.sequenceItems ?? []).flatMap { $0.dataSet[0x00081115]?.sequenceItems ?? [] }
        for item in series {
            for image in item.dataSet[0x00081140]?.sequenceItems ?? [] {
                if let uid = DicomEnhancedImageTableRules.Context.trimmed(image.dataSet[0x00081155], index: 0) { result.insert(uid) }
            }
        }
        return result
    }

    // MARK: - Referenced image identity against supplied targets (C.11.11, C.11.14)

    private static func validateReferences(_ dataSet: DicomDataSet, profile: Profile, targets: [String: DicomDataSet],
                                           state: inout DicomEnhancedImageModules.State) {
        typealias Path = [DicomValidationReport.PathComponent]
        let trimmed = DicomEnhancedImageTableRules.Context.trimmed
        state.report = state.report.merging(.init(evaluatedLayers: [.references]))
        // With no target supplied, one limitation stands for every reference (Isis issue #2516).
        var unsuppliedRecorded = false
        func check(_ series: DicomSequenceItem, path: Path, study: String?) {
            let seriesUID = trimmed(series.dataSet[0x0020000E], 0)
            for (index, image) in (series.dataSet[0x00081140]?.sequenceItems ?? []).enumerated() {
                let location = path + [.tag(0x00081140), .item(index)]
                guard let instance = trimmed(image.dataSet[0x00081155], 0) else { continue }
                guard let target = targets[instance] else {
                    if !targets.isEmpty {
                        state.merge([.init(code: .referenceTargetUnavailable, severity: .limitation, layer: .references,
                                           path: location + [.tag(0x00081155)])])
                    } else if !unsuppliedRecorded {
                        state.merge([.init(code: .referenceTargetUnavailable, severity: .limitation, layer: .references)])
                        unsuppliedRecorded = true
                    }
                    continue
                }
                if let declared = trimmed(image.dataSet[0x00081150], 0), let actual = trimmed(target[0x00080016], 0), declared != actual {
                    state.merge([.init(code: .referenceIdentityContradiction, severity: .error, layer: .references, path: location + [.tag(0x00081150)])])
                }
                if let seriesUID, let actual = trimmed(target[0x0020000E], 0), seriesUID != actual {
                    state.merge([.init(code: .referenceIdentityContradiction, severity: .error, layer: .references, path: path + [.tag(0x0020000E)])])
                }
                if let study, let actual = trimmed(target[0x0020000D], 0), study != actual {
                    state.merge([.init(code: .referenceIdentityContradiction, severity: .error, layer: .references, path: path + [.tag(0x0020000D)])])
                }
                if let frames = image.dataSet[0x00081160], case .strings(let values) = frames.value {
                    let count = target[0x00280008].flatMap { $0.intValue } ?? 1
                    let numbers = values.compactMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: " "))) }
                    if numbers.contains(where: { $0 < 1 || $0 > count }) {
                        state.merge([.init(code: .referenceSelectionOutOfRange, severity: .error, layer: .references, path: location + [.tag(0x00081160)])])
                    }
                }
            }
        }
        for (index, series) in (dataSet[0x00081115]?.sequenceItems ?? []).enumerated() {
            check(series, path: [.tag(0x00081115), .item(index)], study: trimmed(dataSet[0x0020000D], 0))
        }
        for (blend, item) in (dataSet[0x00700402]?.sequenceItems ?? []).enumerated() {
            for (index, series) in (item.dataSet[0x00081115]?.sequenceItems ?? []).enumerated() {
                check(series, path: [.tag(0x00700402), .item(blend), .tag(0x00081115), .item(index)], study: trimmed(item.dataSet[0x0020000D], 0))
            }
        }
    }
}
