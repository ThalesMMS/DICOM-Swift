import Foundation

/// Composition of the Enhanced CT, Enhanced MR and Enhanced XA Image IODs (PS3.3 2026c A.38, A.36,
/// A.47) and of the Segmentation and Parametric Map IODs (A.51, A.75): the IOD-specific modules, the
/// Multi-frame Functional Groups with their shared/per-frame macro usage, Multi-frame Dimension, Frame
/// Extraction and the per-frame coherence of frame type, dimension indices, plane geometry, segment
/// identification and derivation codes. Common Patient/Study/Series/Equipment/SOP Common rules are
/// composed by `DicomCompositeImageModules`; native pixels by `DicomNativePixelValidator`.
public enum DicomEnhancedImageModules {
    public enum Profile: String, Sendable, CaseIterable {
        case videoEndoscopic = "1.2.840.10008.5.1.4.1.1.77.1.1.1"
        case videoMicroscopic = "1.2.840.10008.5.1.4.1.1.77.1.2.1"
        case videoPhotographic = "1.2.840.10008.5.1.4.1.1.77.1.4.1"
        case vlWholeSlideMicroscopy = "1.2.840.10008.5.1.4.1.1.77.1.6"
        case spatialRegistration = "1.2.840.10008.5.1.4.1.1.66.1"
        case deformableSpatialRegistration = "1.2.840.10008.5.1.4.1.1.66.3"
        case enhancedCT = "1.2.840.10008.5.1.4.1.1.2.1"
        case enhancedMR = "1.2.840.10008.5.1.4.1.1.4.1"
        case enhancedXA = "1.2.840.10008.5.1.4.1.1.12.1.1"
        case labelMapSegmentation = "1.2.840.10008.5.1.4.1.1.66.7"
        case surfaceSegmentation = "1.2.840.10008.5.1.4.1.1.66.5"
        case segmentation = "1.2.840.10008.5.1.4.1.1.66.4"
        case parametricMap = "1.2.840.10008.5.1.4.1.1.30"

        public var sopClassUID: String { rawValue }
        public var isVideo: Bool { self == .videoEndoscopic || self == .videoMicroscopic || self == .videoPhotographic }

        public var kind: DicomCompositeImageModules.Kind {
            switch self {
            case .videoEndoscopic, .videoMicroscopic, .videoPhotographic: return .segmentation
            case .spatialRegistration, .deformableSpatialRegistration: return .waveform
            case .enhancedCT: return .enhancedCT
            case .enhancedMR: return .enhancedMR
            case .enhancedXA: return .enhancedXA
            case .segmentation, .labelMapSegmentation, .surfaceSegmentation: return .segmentation
            // WSI uses the same common General Image/Series composition as SEG.
            case .vlWholeSlideMicroscopy: return .segmentation
            case .parametricMap: return .parametricMap
            }
        }

        var key: String {
            switch self {
            case .videoEndoscopic: return "videoEndoscopic"
            case .videoMicroscopic: return "videoMicroscopic"
            case .videoPhotographic: return "videoPhotographic"
            case .vlWholeSlideMicroscopy: return "vlWholeSlideMicroscopy"
            case .spatialRegistration: return "spatialRegistration"
            case .deformableSpatialRegistration: return "deformableSpatialRegistration"
            case .enhancedCT: return "enhancedCT"
            case .enhancedMR: return "enhancedMR"
            case .enhancedXA: return "enhancedXA"
            case .segmentation, .labelMapSegmentation: return "segmentation"
            case .parametricMap: return "parametricMap"
            case .surfaceSegmentation: return "surfaceSegmentation"
            }
        }
    }

    /// The pixel attribute the original bytes carry at the root: Pixel Data, Float Pixel Data or
    /// Double Float Pixel Data (C.7.6.3, C.7.6.24, C.7.6.25); `none` when the object carries no pixels
    /// and `undetermined` when the wire pass could not enumerate the pixel headers.
    public enum PixelData: Sendable, Equatable {
        case integer, float, double, none, undetermined
    }

    /// Modules composed by the common helpers, the classic image helpers or `DicomFunctionalGroupsModule`.
    static let handledElsewhere: Set<String> = [
        "Patient", "Clinical Trial Subject", "General Study", "Patient Study", "Clinical Trial Study", "General Series",
        "Clinical Trial Series", "General Equipment", "SOP Common", "Frame of Reference", "Synchronization", "Specimen",
        "Device", "ICC Profile", "Enhanced Patient Orientation", "Common Instance Reference",
        "Multi-frame Functional Groups", "Multi-frame Dimension", "Frame Extraction",
        "General Image", "General Reference", "General Acquisition"
    ]

    public static func validate(_ dataSet: DicomDataSet, profile: Profile,
                                conditions: DicomCompositeImageModules.Conditions = .init(),
                                pixelData: PixelData = .integer,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        var state = State(limits: limits)
        guard let iod = DicomEnhancedImageTables.iods[profile.key] else {
            state.record(.moduleRuleUnavailable, path: [.tag(0x00080016)], severity: .limitation)
            return state.report
        }
        let shared = dataSet[0x52009229]?.sequenceItems.first?.dataSet
        let frames = (dataSet[0x52009230]?.sequenceItems ?? []).map(\.dataSet)
        let context = DicomEnhancedImageTableRules.Context(root: dataSet, sopClassUID: profile == .labelMapSegmentation ? Profile.segmentation.sopClassUID : profile.sopClassUID, shared: shared,
                                                            frame: nil, frames: frames, facts: conditions, pixelData: pixelData)
        validateModules(dataSet, iod: iod, profile: profile, context: context, state: &state)
        guard !state.stopped else { return state.report }
        switch profile {
        case .videoEndoscopic, .videoMicroscopic, .videoPhotographic:
            DicomVideoModules.validate(dataSet, profile: profile, conditions: conditions, state: &state)
            return state.report
        case .segmentation, .labelMapSegmentation: validateSegmentationConstraints(dataSet, context: context, state: &state)
        case .spatialRegistration, .deformableSpatialRegistration:
            DicomRegistrationModules.validate(dataSet, deformable: profile == .deformableSpatialRegistration, state: &state)
            return state.report
        case .surfaceSegmentation:
            validateSurfaceConstraints(dataSet, state: &state)
            return state.report
        case .vlWholeSlideMicroscopy:
            DicomWholeSlideModules.validate(dataSet, state: &state)
            validatePixelDataPresence(context, state: &state)
        case .parametricMap: validateParametricMapConstraints(dataSet, context: context, state: &state)
        case .enhancedCT, .enhancedMR, .enhancedXA: validateContentConstraints(dataSet, profile: profile, context: context, state: &state)
        }
        validateRoot(dataSet, profile: profile, state: &state)
        guard !state.stopped else { return state.report }
        validateFunctionalGroups(dataSet, iod: iod, profile: profile, context: context, state: &state)
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
            default: requirement = DicomEnhancedImageConditions.moduleCondition(profile, module.name, context, declared: declared)
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
        // A.47: Frame of Reference and Synchronization are required when the C-arm and tabletop share a reference.
        if profile == .enhancedXA, context.rootValue(0x00189474) == "YES" {
            if !dataSet.contains(0x00200052) { state.record(.requiredAttributeMissing, path: [.tag(0x00200052)], requirement: .type1C) }
            if !dataSet.contains(0x00200200) { state.record(.requiredAttributeMissing, path: [.tag(0x00200200)], requirement: .type1C) }
        }
    }

    // A.57 and C.27: mesh counts and one-based primitive references are evaluated on the raw dataset.
    private static func validateSurfaceConstraints(_ dataSet: DicomDataSet, state: inout State) {
        state.evaluate([.init(tag: 0x00200052, requirement: .type1),
                        .init(tag: 0x00201040, requirement: .type2)], on: dataSet, path: [])
        let surfaces = dataSet.sequenceItems(for: 0x00660002)
        if dataSet.int(for: 0x00660001) != surfaces.count {
            state.record(.attributeValueContradiction, path: [.tag(0x00660001)])
        }
        for (index, item) in surfaces.enumerated() {
            guard !state.stopped else { return }
            let surface = item.dataSet
            let path: [DicomValidationReport.PathComponent] = [.tag(0x00660002), .item(index)]
            if surface.int(for: 0x00660003) != index + 1 {
                state.record(.attributeValueContradiction, path: path + [.tag(0x00660003)])
            }
            let points = surface.sequenceItems(for: 0x00660011).first?.dataSet
            let count = points?.int(for: 0x00660015) ?? 0
            let coordinates = points?.floats(for: 0x00660016) ?? []
            if count <= 0 || coordinates.count / 3 != count || !coordinates.count.isMultiple(of: 3) ||
                !coordinates.allSatisfy(\.isFinite) {
                state.record(.attributeValueContradiction, path: path + [.tag(0x00660011), .item(0), .tag(0x00660016)])
            }
            for (normalIndex, normal) in surface.sequenceItems(for: 0x00660012).enumerated() {
                let values = normal.dataSet.floats(for: 0x00660021)
                if normal.dataSet.int(for: 0x0066001E) != count || normal.dataSet.int(for: 0x0066001F) != 3 ||
                    values.count / 3 != count || !values.count.isMultiple(of: 3) || !values.allSatisfy(\.isFinite) {
                    state.record(.attributeValueContradiction,
                        path: path + [.tag(0x00660012), .item(normalIndex), .tag(0x0066001E)])
                }
            }
            if let primitive = surface.sequenceItems(for: 0x00660013).first?.dataSet {
                let primitivePath = path + [.tag(0x00660013), .item(0)]
                var hasPrimitives = false
                for (tag, width) in [(0x00660043, 1), (0x00660042, 2), (0x00660041, 3)] {
                    let values = primitive.ints(for: tag)
                    hasPrimitives = hasPrimitives || !values.isEmpty
                    if !values.count.isMultiple(of: width) || values.contains(where: { $0 < 1 || $0 > count }) {
                        state.record(.attributeValueContradiction, path: primitivePath + [.tag(tag)])
                    }
                }
                for (tag, minimum) in [(0x00660026, 3), (0x00660027, 3), (0x00660028, 2), (0x00660034, 3)] {
                    for (itemIndex, item) in primitive.sequenceItems(for: tag).enumerated() {
                        let values = item.dataSet.ints(for: 0x00660040)
                        hasPrimitives = hasPrimitives || !values.isEmpty
                        if values.count < minimum || values.contains(where: { $0 < 1 || $0 > count }) {
                            state.record(.attributeValueContradiction,
                                path: primitivePath + [.tag(tag), .item(itemIndex), .tag(0x00660040)])
                        }
                    }
                }
                if !hasPrimitives {
                    state.record(.requiredAttributeMissing, path: primitivePath, requirement: .type1C)
                }
            }
        }
        var segmentNumbers = Set<Int>()
        for (index, segment) in dataSet.sequenceItems(for: 0x00620002).enumerated() {
            let path: [DicomValidationReport.PathComponent] = [.tag(0x00620002), .item(index)]
            if let number = segment.dataSet.int(for: 0x00620004), !segmentNumbers.insert(number).inserted {
                state.record(.attributeValueContradiction, path: path + [.tag(0x00620004)])
            }
            let references = segment.dataSet.sequenceItems(for: 0x0066002B)
            if references.isEmpty || segment.dataSet.int(for: 0x0066002A) != references.count {
                state.record(.attributeValueContradiction, path: path + [.tag(0x0066002A)])
            }
            for (itemIndex, reference) in references.enumerated() {
                if let number = reference.dataSet.int(for: 0x0066002C), number < 1 || number > surfaces.count {
                    state.record(.attributeValueContradiction,
                        path: path + [.tag(0x0066002B), .item(itemIndex), .tag(0x0066002C)])
                }
            }
        }
    }

    // MARK: - Segmentation and Parametric Map content constraints (A.51.4, C.8.20.2, A.75.4, C.8.32.2)

    /// Root modules the two IODs exclude: VOI LUT (C.11.2), Modality LUT (C.11.1) and Overlay Plane (C.9.2).
    private static func validateExcludedModules(_ dataSet: DicomDataSet, extra: [Int] = [], state: inout State) {
        let excluded = [0x00281050, 0x00281051, 0x00283010, 0x00281052, 0x00281053, 0x00281054, 0x00283000] + extra
        for tag in excluded where dataSet.contains(tag) { state.record(.conditionalAttributeForbidden, path: [.tag(tag)]) }
        if let overlay = dataSet.elements.first(where: { ($0.tag >> 16) & 0xFF00 == 0x6000 && ($0.tag >> 16) & 1 == 0 }) {
            state.record(.conditionalAttributeForbidden, path: [.tag(overlay.tag)])
        }
    }

    /// Image Type Value 1 DERIVED and Value 2 PRIMARY (C.8.20.2, C.8.32.2).
    private static func validateDerivedPrimary(_ context: DicomEnhancedImageTableRules.Context, state: inout State) {
        guard context.root.contains(0x00080008), context.rootValue(0x00080008) != nil else { return }
        if context.rootValue(0x00080008) != "DERIVED" || context.rootValue(0x00080008, index: 1) != "PRIMARY" {
            state.record(.attributeValueNotAllowed, path: [.tag(0x00080008)])
        }
    }

    /// Pixel data is required by the pixel module of the IOD; the wire pass evidences which attribute carries it.
    private static func validatePixelDataPresence(_ context: DicomEnhancedImageTableRules.Context, state: inout State) {
        switch context.pixelData {
        case .none: state.record(.requiredAttributeMissing, path: [.tag(0x7FE00010)], requirement: .type1)
        case .undetermined: state.record(.conditionUndetermined, path: [.tag(0x7FE00010)], severity: .limitation)
        case .integer, .float, .double: break
        }
    }

    /// A.51/A.75: Common Instance Reference is required once a functional group references another instance.
    private static func validateInstanceReferenceRequirement(_ context: DicomEnhancedImageTableRules.Context, tables: [String],
                                                             state: inout State) {
        guard tables.contains(where: context.macroPresentAnywhere),
              !context.root.contains(0x00081115), !context.root.contains(0x00081200) else { return }
        state.record(.requiredAttributeMissing, path: [.tag(0x00081115)], requirement: .type1C)
    }

    private static func validateSegmentationConstraints(_ dataSet: DicomDataSet, context: DicomEnhancedImageTableRules.Context,
                                                        state: inout State) {
        var rules: [DicomAttributeRule] = [
            .init(tag: 0x00080008, requirement: .type1, constraints: [.valueCount(2...2)]),
            .init(tag: 0x00280002, requirement: .type1, constraints: [.integers([1])]),
            .init(tag: 0x00280103, requirement: .type1, constraints: [.integers([0])])
        ]
        let labelmap = context.rootValue(0x00620001) == "LABELMAP"
        let palette = context.rootValue(0x00280004) == "PALETTE COLOR"
        rules.append(.init(tag: 0x00280004, requirement: .type1,
                           constraints: [.strings(labelmap ? ["MONOCHROME2", "PALETTE COLOR"] : ["MONOCHROME2"])]))
        rules.append(.init(tag: 0x00620001, requirement: .type1, constraints: [.strings(
            context.rootValue(0x00080016) == "1.2.840.10008.5.1.4.1.1.66.7" ? ["LABELMAP"] : ["BINARY", "FRACTIONAL"])]))
        if labelmap {
            rules.append(.init(tag: 0x00280100, requirement: .type1, constraints: [.integers([8, 16])]))
            rules.append(.init(tag: 0x00620013, requirement: .type3, constraints: [.strings(["NO"])]))
            for tag in [0x0062000E, 0x00620010] where dataSet.contains(tag) {
                state.record(.conditionalAttributeForbidden, path: [.tag(tag)])
            }
            if palette {
                rules.append(.init(tag: 0x00282000, requirement: .type1))
                for (index, item) in (dataSet[0x00620002]?.sequenceItems ?? []).enumerated()
                    where item.dataSet.contains(0x0062000D) {
                    state.record(.conditionalAttributeForbidden, path: [.tag(0x00620002), .item(index), .tag(0x0062000D)])
                }
            }
        }
        // C.8.20.2: Bits Allocated/Stored and High Bit follow the Segmentation Type.
        if let bits: (allocated: Int, high: Int) = context.rootValue(0x00620001).flatMap({ $0 == "BINARY" ? (1, 0) : $0 == "FRACTIONAL" ? (8, 7) : labelmap ? (dataSet[0x00280100]?.intValue ?? 8, (dataSet[0x00280100]?.intValue ?? 8) - 1) : nil }) {
            rules += [.init(tag: 0x00280100, requirement: .type1, constraints: [.integers([bits.allocated])]),
                      .init(tag: 0x00280101, requirement: .type1, constraints: [.integers([bits.allocated])]),
                      .init(tag: 0x00280102, requirement: .type1, constraints: [.integers([bits.high])])]
        }
        state.evaluate(rules, on: dataSet, path: [])
        validateDerivedPrimary(context, state: &state)
        // A.51.4: no pixel padding for BINARY/FRACTIONAL, no padding range limit.
        validateExcludedModules(dataSet, extra: labelmap ? [0x00280121] : [0x00280120, 0x00280121], state: &state)
        validatePixelDataPresence(context, state: &state)
        // A.51: Frame of Reference is required without Derivation Image; Common Instance Reference with it.
        if !context.macroPresentAnywhere("C.7.6.16.2.6"), !dataSet.contains(0x00200052) {
            state.record(.requiredAttributeMissing, path: [.tag(0x00200052)], requirement: .type1C)
        }
        validateInstanceReferenceRequirement(context, tables: ["C.7.6.16.2.6"], state: &state)
        // C.8.20.2.4: Segment Numbers are unique, start at 1 and increase by 1.
        var seen = Set<Int>()
        for (index, item) in (dataSet[0x00620002]?.sequenceItems ?? []).enumerated() {
            guard let element = item.dataSet[0x00620004], element.vr == .US, element.vm.count == 1, let number = element.intValue else { continue }
            if !seen.insert(number).inserted || (!labelmap && number != index + 1) {
                state.record(.attributeValueNotAllowed, path: [.tag(0x00620002), .item(index), .tag(0x00620004)])
                break
            }
        }
    }

    private static func validateParametricMapConstraints(_ dataSet: DicomDataSet, context: DicomEnhancedImageTableRules.Context,
                                                         state: inout State) {
        var rules: [DicomAttributeRule] = [
            .init(tag: 0x00080008, requirement: .type1, constraints: [.valueCount(4...Int.max)]),
            .init(tag: 0x00280002, requirement: .type1, constraints: [.integers([1])])
        ]
        // C.8.32.2: Bits Allocated follows the pixel attribute present.
        let allocated: Int? = switch context.pixelData {
        case .integer: 16
        case .float: 32
        case .double: 64
        case .none, .undetermined: nil
        }
        if let allocated { rules.append(.init(tag: 0x00280100, requirement: .type1, constraints: [.integers([allocated])])) }
        state.evaluate(rules, on: dataSet, path: [])
        validateDerivedPrimary(context, state: &state)
        // A.75.4: the Supplemental Palette module shares its attributes with the permitted Palette module and is not distinguished.
        validateExcludedModules(dataSet, state: &state)
        validatePixelDataPresence(context, state: &state)
        validateInstanceReferenceRequirement(context, tables: ["C.7.6.16.2.5", "C.7.6.16.2.6"], state: &state)
        validateImageTypeSummary(context, state: &state)
    }

    // MARK: - IOD content constraints (A.38.1.3, A.36.2.3, A.47.4.1)

    private static func validateContentConstraints(_ dataSet: DicomDataSet, profile: Profile,
                                                   context: DicomEnhancedImageTableRules.Context, state: inout State) {
        var rules: [DicomAttributeRule] = [
            .init(tag: 0x00280002, requirement: .type1, constraints: [.integers([1])]),
            .init(tag: 0x00280004, requirement: .type1, constraints: [.strings(["MONOCHROME2"])]),
            .init(tag: 0x00280100, requirement: .type1, constraints: [.integers(profile == .enhancedXA ? [8, 16] : [16])]),
            .init(tag: 0x00280102, requirement: .type1, constraints: [.integerEqualsAttribute(0x00280101, offset: -1)]),
            .init(tag: 0x00280103, requirement: .type1, constraints: [.integers(profile == .enhancedXA ? [0] : [0, 1])]),
            .init(tag: 0x00080008, requirement: .type1, constraints: [.valueCount(4...Int.max)])
        ]
        if profile == .enhancedCT { rules.append(.init(tag: 0x00280101, requirement: .type1, constraints: [.integerRange(12...16)])) }
        state.evaluate(rules, on: dataSet, path: [])
        validateImageTypeSummary(context, state: &state)
    }

    /// Image Type Value 1 summarizes the frames: all ORIGINAL, all DERIVED or MIXED.
    private static func validateImageTypeSummary(_ context: DicomEnhancedImageTableRules.Context, state: inout State) {
        guard let imageType = context.rootValue(0x00080008) else { return }
        guard ["ORIGINAL", "DERIVED", "MIXED"].contains(imageType) else {
            state.record(.attributeValueNotAllowed, path: [.tag(0x00080008)])
            return
        }
        let frameTypes = Set(context.frames.map { context.withFrame($0).frameType(0) })
        guard !frameTypes.contains(nil), !frameTypes.isEmpty else { return }
        let expected = frameTypes.count == 1 ? frameTypes.first! : "MIXED"
        if expected != imageType { state.record(.attributeValueContradiction, path: [.tag(0x00080008)]) }
    }

    // MARK: - Functional group roots, dimensions and frame extraction

    private static func validateRoot(_ dataSet: DicomDataSet, profile: Profile, state: inout State) {
        let frames = DicomFunctionalGroupsModule.frameCount(in: dataSet)
        var rules = DicomFunctionalGroupsModule.rootRules(frames: frames)
        // A.32.8.4 expressly permits omission when all WSI macros are shared (TILED_FULL).
        if profile == .vlWholeSlideMicroscopy, dataSet.string(for: 0x00209311) == "TILED_FULL", !dataSet.contains(0x52009230) {
            rules.removeAll { $0.tag == 0x52009230 }
        }
        // C.7.6.17 is mandatory for Enhanced CT/MR and optional for Enhanced XA.
        if profile != .enhancedXA || dataSet.contains(0x00209221) || dataSet.contains(0x00209222) {
            rules += DicomFunctionalGroupsModule.dimensionRules(for: dataSet)
        }
        if dataSet.contains(0x00081164) { rules += DicomFunctionalGroupsModule.frameExtractionRules() }
        state.evaluate(rules, on: dataSet, path: [])
        guard !state.stopped else { return }
        var report = state.report
        var remaining = state.remaining
        let completed = DicomFunctionalGroupsModule.validateDimensionIndexItems(in: dataSet, report: &report, remaining: &remaining,
                                                                                limits: state.limits)
        state.report = report
        state.remaining = remaining
        if !completed { state.stopped = true }
    }

    // MARK: - Functional group macros

    private static func validateFunctionalGroups(_ dataSet: DicomDataSet, iod: DicomEnhancedImageTables.IOD, profile: Profile,
                                                 context: DicomEnhancedImageTableRules.Context, state: inout State) {
        let shared = context.shared
        let frames = context.frames
        let sharedPath: [DicomValidationReport.PathComponent] = [.tag(0x52009229), .item(0)]
        func framePath(_ index: Int) -> [DicomValidationReport.PathComponent] { [.tag(0x52009230), .item(index)] }
        var macroTags: [String: Int] = [:]
        for macro in iod.groupMacros {
            guard let tag = DicomEnhancedImageTableRules.Context.macroTag(macro.table) else { continue }
            macroTags[macro.name] = tag
        }
        let allowedTags = Set(macroTags.values)
        var sharedTables: [String] = []
        var frameTables: [[String]] = Array(repeating: [], count: frames.count)
        for macro in iod.groupMacros {
            guard !state.stopped, let tag = macroTags[macro.name] else { continue }
            let inShared = shared?.contains(tag) == true
            let presence = frames.map { $0.contains(tag) }
            // C.7.6.16.1.1: a functional group is either shared or per-frame, never both.
            if inShared, let index = presence.firstIndex(of: true) {
                state.record(.conditionalAttributeForbidden, path: framePath(index) + [.tag(tag)])
            }
            // Frame Content and the per-frame converted attributes are never shared; the shared converted attributes never per frame.
            let perFrameOnly = macro.name == "Frame Content" || macro.name == "Unassigned Per-Frame Converted Attributes"
            if perFrameOnly, inShared { state.record(.conditionalAttributeForbidden, path: sharedPath + [.tag(tag)]) }
            if macro.name == "Unassigned Shared Converted Attributes", let index = presence.firstIndex(of: true) {
                state.record(.conditionalAttributeForbidden, path: framePath(index) + [.tag(tag)])
            }
            if inShared { sharedTables.append(macro.table) }
            for (index, present) in presence.enumerated() where present { frameTables[index].append(macro.table) }
            // Requirement per frame; the first offending frame is reported for the macro. A shared macro is
            // present for every frame and is reported at the shared group when it is forbidden for one.
            var reported = false
            for index in frames.indices where !reported {
                let frameContext = context.withFrame(frames[index])
                let requirement: (truth: DicomAttributeRule.Truth, mayBePresent: Bool)
                switch macro.usage {
                case "M": requirement = (.satisfied, true)
                case "U": requirement = (.unsatisfied, true)
                default: requirement = DicomEnhancedImageConditions.macroCondition(profile, macro.name, frameContext)
                }
                let path = (inShared && !perFrameOnly ? sharedPath : framePath(index)) + [.tag(tag)]
                switch (requirement.truth, presence[index] || (inShared && !perFrameOnly)) {
                case (.satisfied, false):
                    state.record(.requiredAttributeMissing, path: path, requirement: macro.usage == "M" ? .type1 : .type1C)
                    reported = true
                case (.unsatisfied, true) where !requirement.mayBePresent:
                    state.record(.conditionalAttributeForbidden, path: path)
                    reported = true
                case (.undetermined, false):
                    state.record(.conditionUndetermined, path: path, severity: .limitation)
                    reported = true
                default: break
                }
            }
            if frames.isEmpty, macro.usage == "M", !inShared {
                state.record(.requiredAttributeMissing, path: sharedPath + [.tag(tag)], requirement: .type1)
            }
        }
        // Macros of other IODs shall not be present in this IOD's functional groups.
        let knownTags = Set(DicomEnhancedImageTables.iods.values.flatMap(\.groupMacros).compactMap {
            DicomEnhancedImageTableRules.Context.macroTag($0.table)
        })
        for (item, path) in ([shared].compactMap { $0 }.map { ($0, sharedPath) }) + frames.enumerated().map({ ($0.element, framePath($0.offset)) }) {
            for element in item.elements where knownTags.contains(element.tag) && !allowedTags.contains(element.tag) {
                state.record(.conditionalAttributeForbidden, path: path + [.tag(element.tag)])
                break
            }
        }
        guard !state.stopped else { return }
        if let shared {
            let rules = sharedTables.flatMap { DicomEnhancedImageTableRules.rules(table: $0, context: context) }
            state.evaluate(rules, on: shared, path: sharedPath)
        }
        let dimensionCount = dataSet[0x00209222]?.sequenceItems.count
        let segmentNumbers = Set((dataSet[0x00620002]?.sequenceItems ?? []).compactMap { $0.dataSet[0x00620004]?.intValue })
        if shared != nil, !state.stopped {
            validateSharedCoherence(context, segmentNumbers: segmentNumbers, state: &state)
        }
        var validatedSharedFrameType = false
        for (index, frame) in frames.enumerated() {
            guard !state.stopped else { return }
            let frameContext = context.withFrame(frame)
            let rules = frameTables[index].flatMap { DicomEnhancedImageTableRules.rules(table: $0, context: frameContext) }
            state.evaluate(rules, on: frame, path: framePath(index))
            guard !state.stopped else { return }
            validateFrameCoherence(frameContext, index: index, dimensionCount: dimensionCount, rows: dataSet[0x00280010],
                                   columns: dataSet[0x00280011], segmentNumbers: segmentNumbers, validatedSharedFrameType: &validatedSharedFrameType, state: &state)
        }
    }

    /// Segment identification, derivation codes and the identity transformation when they are shared.
    private static func validateSharedCoherence(_ context: DicomEnhancedImageTableRules.Context, segmentNumbers: Set<Int>, state: inout State) {
        guard let shared = context.shared else { return }
        let path: [DicomValidationReport.PathComponent] = [.tag(0x52009229), .item(0)]
        validateMacroCoherence(shared, path: path, context: context, segmentNumbers: segmentNumbers, state: &state)
    }

    /// Frame Type values, Dimension Index Values cardinality and plane geometry of one frame.
    private static func validateFrameCoherence(_ context: DicomEnhancedImageTableRules.Context, index: Int, dimensionCount: Int?,
                                               rows: DicomDataElement?, columns: DicomDataElement?, segmentNumbers: Set<Int>,
                                               validatedSharedFrameType: inout Bool, state: inout State) {
        let path: [DicomValidationReport.PathComponent] = [.tag(0x52009230), .item(index)]
        if let frameTypeTag = DicomEnhancedImageTableRules.Context.macroTag(context.frameTypeTable) {
            let fromFrame = context.frame?[frameTypeTag] != nil
            let values = (context.frame?[frameTypeTag] ?? context.shared?[frameTypeTag])?.sequenceItems.first?.dataSet[0x00089007]?.stringValues
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")) }
            if let values, fromFrame || !validatedSharedFrameType {
                if !fromFrame { validatedSharedFrameType = true }
                let sourcePath: [DicomValidationReport.PathComponent] = fromFrame ? path : [.tag(0x52009229), .item(0)]
                let location = sourcePath + [.tag(frameTypeTag), .item(0), .tag(0x00089007)]
                if values.count < 4 {
                    state.record(.invalidMultiplicity, path: location)
                } else if !["ORIGINAL", "DERIVED"].contains(values[0]) || !["PRIMARY", "SECONDARY"].contains(values[1]) {
                    state.record(.attributeValueNotAllowed, path: location)
                } else if context.isParametricMap, values.contains("MIXED") {
                    // C.8.32.3.1: MIXED is not allowed in a Parametric Map Frame Type.
                    state.record(.attributeValueNotAllowed, path: location)
                }
            }
        }
        if let frame = context.frame {
            validateMacroCoherence(frame, path: path, context: context, segmentNumbers: segmentNumbers, state: &state)
        }
        if let dimensionCount, let content = context.frame?[0x00209111]?.sequenceItems.first?.dataSet,
           let indices = content[0x00209157], indices.vm.count != dimensionCount {
            state.record(.invalidMultiplicity, path: path + [.tag(0x00209111), .item(0), .tag(0x00209157)])
        }
        guard context.macroPresent("C.7.6.16.2.1"), context.macroPresent("C.7.6.16.2.3"), context.macroPresent("C.7.6.16.2.4") else { return }
        func element(_ table: String, _ tag: Int) -> DicomDataElement? {
            guard let macro = DicomEnhancedImageTableRules.Context.macroTag(table) else { return nil }
            return (context.frame?[macro] ?? context.shared?[macro])?.sequenceItems.first?.dataSet[tag]
        }
        let elements = [element("C.7.6.16.2.1", 0x00280030), element("C.7.6.16.2.1", 0x00180050), element("C.7.6.16.2.1", 0x00180088),
                        element("C.7.6.16.2.3", 0x00200032), element("C.7.6.16.2.4", 0x00200037), rows, columns].compactMap { $0 }
        guard elements.contains(where: { $0.tag == 0x00200037 }) else { return }
        let geometry = DicomImagePlaneModule.geometry(.init(elements: elements), limits: state.limits(remaining: state.remaining))
        state.remaining -= geometry.work
        state.merge(geometry.diagnostics.map {
            .init(code: $0.code, severity: $0.severity, layer: $0.layer, path: path + $0.path, requirement: $0.requirement)
        })
    }

    /// C.8.20.3.1: the referenced segment exists; A.51.5.1: derivation codes of a Segmentation are
    /// (113076, DCM) with (121322, DCM) source purposes; C.7.6.16.2.9b: the Parametric Map rescale is 0 and 1.
    private static func validateMacroCoherence(_ item: DicomDataSet, path: [DicomValidationReport.PathComponent],
                                               context: DicomEnhancedImageTableRules.Context, segmentNumbers: Set<Int>,
                                               state: inout State) {
        func code(_ dataSet: DicomDataSet) -> (String, String)? {
            guard let value = DicomEnhancedImageTableRules.Context.trimmed(dataSet[0x00080100], index: 0),
                  let scheme = DicomEnhancedImageTableRules.Context.trimmed(dataSet[0x00080102], index: 0) else { return nil }
            return (value, scheme)
        }
        if context.isSegmentation {
            if let element = item[0x0062000A]?.sequenceItems.first?.dataSet[0x0062000B], element.vr == .US, element.vm.count == 1,
               let number = element.intValue, !segmentNumbers.contains(number) {
                state.record(.attributeValueContradiction, path: path + [.tag(0x0062000A), .item(0), .tag(0x0062000B)])
            }
            for (index, derivation) in (item[0x00089124]?.sequenceItems ?? []).enumerated() {
                let derivationPath = path + [.tag(0x00089124), .item(index)]
                for (codeIndex, entry) in (derivation.dataSet[0x00089215]?.sequenceItems ?? []).enumerated() {
                    guard let found = code(entry.dataSet), found != ("113076", "DCM") else { continue }
                    state.record(.attributeValueNotAllowed, path: derivationPath + [.tag(0x00089215), .item(codeIndex), .tag(0x00080100)])
                }
                for (sourceIndex, source) in (derivation.dataSet[0x00082112]?.sequenceItems ?? []).enumerated() {
                    guard let purpose = source.dataSet[0x0040A170]?.sequenceItems.first?.dataSet, let found = code(purpose),
                          found != ("121322", "DCM") else { continue }
                    state.record(.attributeValueNotAllowed, path: derivationPath + [.tag(0x00082112), .item(sourceIndex), .tag(0x0040A170), .item(0), .tag(0x00080100)])
                }
            }
        }
        if context.isParametricMap, let transformation = item[0x00289145]?.sequenceItems.first?.dataSet {
            for (tag, expected) in [(0x00281052, Decimal(0)), (0x00281053, Decimal(1))] {
                guard let element = transformation[tag], element.vr == .DS, case .strings(let values) = element.value, values.count == 1,
                      let value = try? DicomDecimalString.parse(values[0], vr: .DS), value != expected else { continue }
                state.record(.attributeValueNotAllowed, path: path + [.tag(0x00289145), .item(0), .tag(tag)])
            }
        }
    }

    // MARK: - Budgeted state

    /// One evaluation and diagnostic budget shared by the module, macro and coherence passes of a composition.
    struct State {
        let limits: DicomAttributeValidator.Limits
        var report = DicomValidationReport(evaluatedLayers: [.attributes])
        var remaining: Int
        var stopped = false

        init(limits: DicomAttributeValidator.Limits) {
            self.limits = limits
            remaining = limits.maximumRuleEvaluations
        }

        func limits(remaining: Int) -> DicomAttributeValidator.Limits {
            .init(maximumDepth: limits.maximumDepth, maximumRuleEvaluations: max(0, remaining),
                  maximumDiagnostics: max(1, limits.maximumDiagnostics - report.diagnostics.count))
        }

        mutating func evaluate(_ rules: [DicomAttributeRule], on dataSet: DicomDataSet, path: [DicomValidationReport.PathComponent]) {
            guard !stopped, !rules.isEmpty else { return }
            guard remaining > 0, report.diagnostics.count < limits.maximumDiagnostics else {
                record(.evaluationLimitReached, path: path, severity: .limitation)
                stopped = true
                return
            }
            let evaluated = DicomAttributeValidator.evaluate(dataSet, rules: rules, limits: limits(remaining: remaining))
            remaining -= evaluated.evaluations
            merge(evaluated.report.diagnostics.map {
                .init(code: $0.code, severity: $0.severity, layer: $0.layer, path: path + $0.path, requirement: $0.requirement)
            })
            if evaluated.report.diagnostics.contains(where: { $0.code == .evaluationLimitReached }) { stopped = true }
        }

        mutating func merge(_ diagnostics: [DicomValidationReport.Diagnostic]) {
            for diagnostic in diagnostics {
                guard report.diagnostics.count < limits.maximumDiagnostics else {
                    if !stopped {
                        report = report.merging(.init(diagnostics: [.init(code: .evaluationLimitReached, severity: .limitation, layer: .attributes)]))
                    }
                    stopped = true
                    return
                }
                report = report.merging(.init(diagnostics: [diagnostic]))
            }
        }

        mutating func record(_ code: DicomValidationReport.Code, path: [DicomValidationReport.PathComponent],
                             severity: DicomValidationReport.Severity = .error, requirement: DicomAttributeRule.Requirement? = nil) {
            merge([.init(code: code, severity: severity, layer: .attributes, path: path, requirement: requirement)])
        }
    }
}
