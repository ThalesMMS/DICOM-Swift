import Foundation

/// Composition of the RT Dose, RT Structure Set and RT Plan IODs (PS3.3 2026c A.18–A.20) over the
/// generated tables: the IOD-specific modules with their usage clauses, the grid-based dose pixel
/// description and frame offsets, the ROI/contour/observation coherence of a structure set, the
/// fraction group, beam, control point, accessory and brachy coherence of a plan, and the identity of
/// every referenced instance against supplied targets. Common Patient/Study/Equipment/SOP Common rules
/// are composed by `DicomCompositeImageModules`; RT Series replaces General Series.
public enum DicomRTModules {
    public enum Profile: String, Sendable, CaseIterable {
        case rtDose = "1.2.840.10008.5.1.4.1.1.481.2"
        case rtStructureSet = "1.2.840.10008.5.1.4.1.1.481.3"
        case rtPlan = "1.2.840.10008.5.1.4.1.1.481.5"

        public var sopClassUID: String { rawValue }

        var key: String {
            switch self {
            case .rtDose: return "rtDose"
            case .rtStructureSet: return "rtStructureSet"
            case .rtPlan: return "rtPlan"
            }
        }
    }

    typealias Path = [DicomValidationReport.PathComponent]
    typealias State = DicomEnhancedImageModules.State

    /// Modules composed by the common helpers or by the DicomCore dispatch (General Image, Image Plane).
    static let handledElsewhere: Set<String> = [
        "Patient", "Clinical Trial Subject", "General Study", "Patient Study", "Clinical Trial Study", "Clinical Trial Series",
        "General Equipment", "SOP Common", "Frame of Reference", "Common Instance Reference", "General Reference",
        "General Image", "Image Plane", "Frame Extraction"
    ]

    static func declaresBrachy(_ dataSet: DicomDataSet) -> Bool {
        [0x300A0200, 0x300A0202, 0x300A0206, 0x300A0210, 0x300A0230].contains(where: dataSet.contains)
    }

    /// A.20: whether any fraction group counts beams (300A,0080) or brachy application setups (300A,00A0).
    static func fractionGroupsRequire(_ dataSet: DicomDataSet, countTag: Int) -> Bool {
        (dataSet[0x300A0070]?.sequenceItems ?? []).contains { ($0.dataSet[countTag]?.intValue ?? 0) > 0 }
    }

    public static func validate(_ dataSet: DicomDataSet, profile: Profile, pixelData: DicomEnhancedImageModules.PixelData = .none,
                                targets: [String: DicomDataSet] = [:], limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        var state = State(limits: limits)
        guard let iod = DicomEnhancedImageTables.iods[profile.key] else {
            state.record(.moduleRuleUnavailable, path: [.tag(0x00080016)], severity: .limitation)
            return state.report
        }
        let context = DicomEnhancedImageTableRules.Context(root: dataSet, sopClassUID: profile.sopClassUID, shared: nil, frame: nil,
                                                            frames: [], facts: .init(), pixelData: pixelData)
        validateModules(dataSet, iod: iod, profile: profile, context: context, state: &state)
        guard !state.stopped else { return state.report }
        switch profile {
        case .rtDose: validateDose(dataSet, context: context, state: &state)
        case .rtStructureSet: validateStructureSet(dataSet, state: &state)
        case .rtPlan: validatePlan(dataSet, state: &state)
        }
        guard !state.stopped else { return state.report }
        validateReferences(dataSet, targets: targets, state: &state)
        return state.report
    }

    // MARK: - Modules

    private static func validateModules(_ dataSet: DicomDataSet, iod: DicomEnhancedImageTables.IOD, profile: Profile,
                                        context: DicomEnhancedImageTableRules.Context, state: inout State) {
        for module in iod.modules where !handledElsewhere.contains(module.name) {
            guard !state.stopped else { return }
            let tags = DicomEnhancedImageTableRules.topLevelTags(module.table)
            let declared = tags.contains(where: dataSet.contains)
            let requirement: (truth: DicomAttributeRule.Truth, mayBePresent: Bool)
            switch module.usage {
            case "M": requirement = (.satisfied, true)
            case "U": requirement = (declared ? .satisfied : .unsatisfied, true)
            default: requirement = DicomEnhancedImageConditions.rtModuleCondition(profile, module.name, context, declared: declared)
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
        // A.18: Frame of Reference is mandatory for a dose; C.12.3 applies when declared.
        if profile == .rtDose, !dataSet.contains(0x00200052) {
            state.record(.requiredAttributeMissing, path: [.tag(0x00200052)], requirement: .type1)
        }
        if dataSet.contains(0x00081164) {
            state.evaluate(DicomFunctionalGroupsModule.frameExtractionRules(), on: dataSet, path: [])
        }
    }

    // MARK: - RT Dose (C.8.8.3)

    private static func validateDose(_ dataSet: DicomDataSet, context: DicomEnhancedImageTableRules.Context, state: inout State) {
        if context.pixelData == .integer {
            // C.8.8.3.4: one 16- or 32-bit unsigned MONOCHROME2 sample per voxel; signed samples only for error doses.
            let representation: Set<Int> = context.rootValue(0x30040004) == "ERROR" ? [0, 1] : [0]
            state.evaluate([
                .init(tag: 0x00280002, requirement: .type1, constraints: [.integers([1])]),
                .init(tag: 0x00280004, requirement: .type1, constraints: [.strings(["MONOCHROME2"])]),
                .init(tag: 0x00280100, requirement: .type1, constraints: [.integers([16, 32])]),
                .init(tag: 0x00280101, requirement: .type1, constraints: [.integerEqualsAttribute(0x00280100, offset: 0)]),
                .init(tag: 0x00280102, requirement: .type1, constraints: [.integerEqualsAttribute(0x00280101, offset: -1)]),
                .init(tag: 0x00280103, requirement: .type1, constraints: [.integers(representation)])
            ], on: dataSet, path: [])
        } else if context.pixelData == .float || context.pixelData == .double {
            state.record(.conditionalAttributeForbidden, path: [.tag(context.pixelData == .float ? 0x7FE00008 : 0x7FE00009)])
        }
        // C.8.8.3.2: one offset per frame, strictly increasing or decreasing.
        if let element = dataSet[0x3004000C], element.vr == .DS, case .strings(let values) = element.value {
            let frames = context.rootInt(0x00280008) ?? 1
            let offsets = values.compactMap { try? DicomDecimalString.parse($0, vr: .DS) }
            if values.count != frames || offsets.count != values.count {
                state.record(.attributeValueContradiction, path: [.tag(0x3004000C)])
            } else if offsets.count > 1 {
                let increasing = zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 }
                let decreasing = zip(offsets, offsets.dropFirst()).allSatisfy { $0 > $1 }
                if !increasing, !decreasing { state.record(.attributeValueContradiction, path: [.tag(0x3004000C)]) }
            }
        }
    }

    // MARK: - RT Structure Set (C.8.8.5, C.8.8.6, C.8.8.8)

    private static func validateStructureSet(_ dataSet: DicomDataSet, state: inout State) {
        let trimmed = DicomEnhancedImageTableRules.Context.trimmed
        var rois = Set<Int>()
        let frameOfReferences = Set((dataSet[0x30060010]?.sequenceItems ?? []).compactMap { trimmed($0.dataSet[0x00200052], 0) })
        for (index, item) in (dataSet[0x30060020]?.sequenceItems ?? []).enumerated() {
            let path: Path = [.tag(0x30060020), .item(index)]
            if let number = item.dataSet[0x30060022]?.intValue, !rois.insert(number).inserted {
                state.record(.attributeValueContradiction, path: path + [.tag(0x30060022)])
            }
            if !frameOfReferences.isEmpty, let uid = trimmed(item.dataSet[0x30060024], 0), !frameOfReferences.contains(uid) {
                state.record(.attributeValueContradiction, path: path + [.tag(0x30060024)])
            }
        }
        for (index, item) in (dataSet[0x30060039]?.sequenceItems ?? []).enumerated() {
            let path: Path = [.tag(0x30060039), .item(index)]
            if let number = item.dataSet[0x30060084]?.intValue, !rois.contains(number) {
                state.record(.referenceSelectionInvalid, path: path + [.tag(0x30060084)])
            }
            for (contourIndex, contour) in (item.dataSet[0x30060040]?.sequenceItems ?? []).enumerated() {
                guard let points = contour.dataSet[0x30060046]?.intValue, let data = contour.dataSet[0x30060050], data.vr == .DS else { continue }
                if data.vm.count != points * 3 {
                    state.record(.attributeValueContradiction, path: path + [.tag(0x30060040), .item(contourIndex), .tag(0x30060050)])
                }
            }
        }
        var observations = Set<Int>()
        for (index, item) in (dataSet[0x30060080]?.sequenceItems ?? []).enumerated() {
            let path: Path = [.tag(0x30060080), .item(index)]
            if let number = item.dataSet[0x30060082]?.intValue, !observations.insert(number).inserted {
                state.record(.attributeValueContradiction, path: path + [.tag(0x30060082)])
            }
            if let number = item.dataSet[0x30060084]?.intValue, !rois.contains(number) {
                state.record(.referenceSelectionInvalid, path: path + [.tag(0x30060084)])
            }
        }
    }

    // MARK: - RT Plan (C.8.8.13, C.8.8.14, C.8.8.15)

    private static func validatePlan(_ dataSet: DicomDataSet, state: inout State) {
        let beams = dataSet[0x300A00B0]?.sequenceItems ?? []
        let beamNumbers = Set(beams.compactMap { $0.dataSet[0x300A00C0]?.intValue })
        let setups = Set((dataSet[0x300A0230]?.sequenceItems ?? []).compactMap { $0.dataSet[0x300A0234]?.intValue })
        // C.8.8.13: referenced beams and application setups exist in their modules.
        for (index, group) in (dataSet[0x300A0070]?.sequenceItems ?? []).enumerated() {
            let path: Path = [.tag(0x300A0070), .item(index)]
            if !beams.isEmpty {
                for (beamIndex, reference) in (group.dataSet[0x300C0004]?.sequenceItems ?? []).enumerated() {
                    if let number = reference.dataSet[0x300C0006]?.intValue, !beamNumbers.contains(number) {
                        state.record(.referenceSelectionInvalid, path: path + [.tag(0x300C0004), .item(beamIndex), .tag(0x300C0006)])
                    }
                }
            }
            if !setups.isEmpty {
                for (setupIndex, reference) in (group.dataSet[0x300C000A]?.sequenceItems ?? []).enumerated() {
                    if let number = reference.dataSet[0x300C000C]?.intValue, !setups.contains(number) {
                        state.record(.referenceSelectionInvalid, path: path + [.tag(0x300C000A), .item(setupIndex), .tag(0x300C000C)])
                    }
                }
            }
        }
        var seen = Set<Int>()
        for (index, beam) in beams.enumerated() {
            guard !state.stopped else { return }
            validateBeam(beam.dataSet, path: [.tag(0x300A00B0), .item(index)], seen: &seen, state: &state)
        }
        for (setupIndex, setup) in (dataSet[0x300A0230]?.sequenceItems ?? []).enumerated() {
            for (channelIndex, channel) in (setup.dataSet[0x300A0280]?.sequenceItems ?? []).enumerated() {
                validateChannel(channel.dataSet, path: [.tag(0x300A0230), .item(setupIndex), .tag(0x300A0280), .item(channelIndex)], state: &state)
            }
        }
    }

    /// Unique beam numbers, the control point count, the first control point's geometry, the final meterset
    /// weight and the material-dependent compensator and block attributes (C.8.8.14).
    private static func validateBeam(_ beam: DicomDataSet, path: Path, seen: inout Set<Int>, state: inout State) {
        if let number = beam[0x300A00C0]?.intValue, !seen.insert(number).inserted {
            state.record(.attributeValueContradiction, path: path + [.tag(0x300A00C0)])
        }
        let controlPoints = beam[0x300A0111]?.sequenceItems ?? []
        if let count = beam[0x300A0110]?.intValue, count != controlPoints.count {
            state.record(.attributeValueContradiction, path: path + [.tag(0x300A0110)])
        }
        if let first = controlPoints.first?.dataSet {
            let firstPath = path + [.tag(0x300A0111), .item(0)]
            var required: [(Int, DicomAttributeRule.Requirement)] = [(0x300A011E, .type1C), (0x300A011F, .type1C), (0x300A0120, .type1C),
                (0x300A0121, .type1C), (0x300A0122, .type1C), (0x300A0123, .type1C), (0x300A0125, .type1C), (0x300A0126, .type1C),
                (0x300A0128, .type2C), (0x300A0129, .type2C), (0x300A012A, .type2C), (0x300A012C, .type2C)]
            let enhanced = DicomEnhancedImageTableRules.Context.trimmed(beam[0x300800A3], index: 0) == "YES"
            required.append(enhanced ? (0x300800A2, .type2C) : (0x300A011A, .type1C))
            if (beam[0x300A00D0]?.intValue ?? 0) > 0 { required.append((0x300A0116, .type1C)) }
            for (tag, requirement) in required where !first.contains(tag) {
                state.record(.requiredAttributeMissing, path: firstPath + [.tag(tag)], requirement: requirement)
            }
        }
        let metersets = controlPoints.contains { point in
            guard let weight = point.dataSet[0x300A0134] else { return false }
            if case .empty = weight.value { return false }
            return weight.vm.count > 0
        }
        if metersets, !beam.contains(0x300A010E) {
            state.record(.requiredAttributeMissing, path: path + [.tag(0x300A010E)], requirement: .type1C)
        }
        for (index, compensator) in (beam[0x300A00E3]?.sequenceItems ?? []).enumerated() {
            let itemPath = path + [.tag(0x300A00E3), .item(index)]
            let material = hasValue(compensator.dataSet[0x300A00E1])
            if !material, !compensator.dataSet.contains(0x300A00EB) {
                state.record(.requiredAttributeMissing, path: itemPath + [.tag(0x300A00EB)], requirement: .type1C)
            }
            if material, !compensator.dataSet.contains(0x300A00EC) {
                state.record(.requiredAttributeMissing, path: itemPath + [.tag(0x300A00EC)], requirement: .type1C)
            }
            if material, DicomEnhancedImageTableRules.Context.trimmed(compensator.dataSet[0x300A02E1], index: 0) == "DOUBLE_SIDED",
               !compensator.dataSet.contains(0x300A02E2) {
                state.record(.requiredAttributeMissing, path: itemPath + [.tag(0x300A02E2)], requirement: .type1C)
            }
        }
        for (index, block) in (beam[0x300A00F4]?.sequenceItems ?? []).enumerated() {
            let itemPath = path + [.tag(0x300A00F4), .item(index)]
            let material = hasValue(block.dataSet[0x300A00E1])
            if material, !block.dataSet.contains(0x300A0100) {
                state.record(.requiredAttributeMissing, path: itemPath + [.tag(0x300A0100)], requirement: .type2C)
            }
            if !material, !block.dataSet.contains(0x300A0102) {
                state.record(.requiredAttributeMissing, path: itemPath + [.tag(0x300A0102)], requirement: .type2C)
            }
        }
    }

    /// Transfer tube length with a named tube and the final cumulative time weight (C.8.8.15).
    private static func validateChannel(_ channel: DicomDataSet, path: Path, state: inout State) {
        if hasValue(channel[0x300A02A2]), !channel.contains(0x300A02A4) {
            state.record(.requiredAttributeMissing, path: path + [.tag(0x300A02A4)], requirement: .type2C)
        }
        let weights = (channel[0x300A02D0]?.sequenceItems ?? []).contains { hasValue($0.dataSet[0x300A02D6]) }
        if weights, !channel.contains(0x300A02C8) {
            state.record(.requiredAttributeMissing, path: path + [.tag(0x300A02C8)], requirement: .type1C)
        }
    }

    private static func hasValue(_ element: DicomDataElement?) -> Bool {
        guard let element else { return false }
        if case .empty = element.value { return false }
        if case .strings(let values) = element.value {
            return values.contains { !$0.trimmingCharacters(in: CharacterSet(charactersIn: " ")).isEmpty }
        }
        return element.vm.count > 0
    }

    // MARK: - Referenced instances against supplied targets

    /// Every SOP Instance reference of the object (plans, structure sets, doses, records, images, series and
    /// studies) is checked by `DicomReferenceTargetWalk`.
    private static func validateReferences(_ dataSet: DicomDataSet, targets: [String: DicomDataSet], state: inout State) {
        DicomReferenceTargetWalk.validate(dataSet, targets: targets, state: &state)
    }
}
