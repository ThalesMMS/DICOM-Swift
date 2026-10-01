import Foundation

/// Curated readings of the PS3.3 2026c conditions, usage clauses and Enumerated Values of the
/// Enhanced CT/MR/XA, Segmentation, Parametric Map, Softcopy Presentation State, RT, waveform and
/// encapsulated document tables, keyed by table and tag. Every entry cites the wording it encodes;
/// conditions the instance cannot evidence come from stated facts or stay undetermined.
enum DicomEnhancedImageConditions {
    typealias Context = DicomEnhancedImageTableRules.Context
    typealias C = DicomAttributeRule.Condition
    typealias T = DicomAttributeRule.Truth
    private typealias Rule = @Sendable (Context) -> C

    static func key(_ table: String, _ tag: Int) -> String { table + "/" + String(format: "%08X", tag) }

    static func condition(_ key: String, _ context: Context) -> C? { conditions[key]?(context) }

    static func constraints(_ key: String, _ context: Context) -> [DicomAttributeRule.Constraint] {
        if let values = enumerations[key] { return [.strings(values)] }
        switch key {
        case "C.8.15.1/00080060": return [.strings(["CT"])]
        case "C.8.13.6/00080060": return [.strings(["MR"])]
        case "C.8.19.1/00080060": return [.strings([context.sopClassUID == "1.2.840.10008.5.1.4.1.1.12.1.1" ? "XA" : "RF"])]
        case "C.8.20.1/00080060": return [.strings(["SEG"])]
        // C.8.20.2: Maximum Fractional Value is a stored 8-bit sample; C.8.32.2: integer maps store 16 bits.
        case "C.8.20.2/0062000E": return [.integerRange(1...255)]
        case "C.8.32.2/00280101": return [.integers([16])]
        case "C.8.32.2/00280102": return [.integers([15])]
        // C.7.6.16.2.9b: the identity transformation; the value equality is checked numerically per frame.
        // C.10.5/C.10.6 Presentation State integers: two-dimensional graphics, right-angle rotations, two or more ticks.
        case "C.10.5/00700020": return [.integers([2])]
        case "C.10.5/00700287": return [.itemCount(2...Int.max)]
        case "C.10.6/00700042": return [.integers([0, 90, 180, 270])]
        // C.8.8.1: the RT modality of each IOD; C.8.8.3: one referenced plan unless MULTI_PLAN, plan overview items by type.
        case "C.8.8.1/00080060":
            switch DicomRTModules.Profile(rawValue: context.sopClassUID) {
            case .rtDose: return [.strings(["RTDOSE"])]
            case .rtStructureSet: return [.strings(["RTSTRUCT"])]
            case .rtPlan: return [.strings(["RTPLAN"])]
            case nil: return [.strings(["RTIMAGE", "RTDOSE", "RTSTRUCT", "RTPLAN", "RTRECORD"])]
            }
        case "C.8.8.3/300C0002": return context.rootValue(0x3004000A) == "MULTI_PLAN" ? [.itemCount(1...Int.max)] : [.itemCount(1...1)]
        case "C.8.8.3/300C0116": return context.rootValue(0x3004000A) == "PLAN_OVERVIEW" ? [.itemCount(1...Int.max)] : [.itemCount(1...1)]
        // C.10.9: Waveform Bits Allocated is one of the sample word sizes; C.24.1/C.24.2: the document series modality and
        // MIME type of each encapsulated document IOD (A.45).
        case "C.10.9/54001004": return [.integers([8, 16, 32, 64])]
        case "C.24.1/00080060":
            guard let profile = context.encapsulatedDocumentProfile else { return [] }
            return [.strings([profile.modality])]
        case "C.24.2/00420012":
            guard let profile = context.encapsulatedDocumentProfile else { return [] }
            return [.strings(profile.mimeTypes)]
        default: return []
        }
    }

    // MARK: - Condition patterns

    /// "Required if Frame Type (0008,9007) Value 1 of this Frame is ORIGINAL."
    private static let frameOriginal: Rule = { .known($0.frameOriginal) }
    /// "Required if Frame Type Value 1 of this Frame is ORIGINAL or Image Type Value 1 is ORIGINAL."
    private static let frameOrImageOriginal: Rule = { .known($0.frameOrImageOriginal) }
    /// "Required if Image Type (0008,0008) Value 1 is ORIGINAL or MIXED."
    private static let imageOriginalOrMixed: Rule = { .known($0.imageOriginalOrMixed) }
    /// "Required if SOP Class UID is not a Legacy Converted ... Storage": the qualified SOP Classes are not.
    private static let notLegacy: Rule = { _ in .known(.satisfied) }
    private static let lossy: Rule = { _ in .stringEquals(0x00282110, "01") }

    /// "Required if <attribute> is/equals <value>": an absent attribute does not carry the value.
    private static func equals(_ tag: Int, _ values: String...) -> Rule { { _ in anyOf(tag, values) } }

    private static func anyOf(_ tag: Int, _ values: [String]) -> C {
        .all([.present(tag), values.count == 1 ? .stringEquals(tag, values[0]) : .any(values.map { .stringEquals(tag, $0) })])
    }

    private static func present(_ tag: Int) -> Rule { { _ in .present(tag) } }

    private static func frameOriginalAnd(_ tag: Int, _ values: String...) -> Rule {
        { context in .all([.known(context.frameOriginal), anyOf(tag, values)]) }
    }

    private static func imageOriginalOrMixedAnd(_ tag: Int, _ values: String...) -> Rule {
        { context in .all([.known(context.imageOriginalOrMixed), anyOf(tag, values)]) }
    }

    /// "... and Acquisition Type (0018,9302) is ..." where the type lives in the CT Acquisition Type macro.
    private static func frameOriginalAndAcquisitionType(_ values: Set<String>, negated: Bool = false) -> Rule {
        { context in
            let type = context.truth(context.macroValue("C.8.15.3.2", 0x00189302), in: values)
            return .all([.known(context.frameOriginal), .known(negated ? Self.negate(type) : type)])
        }
    }

    private static func negate(_ truth: T) -> T {
        switch truth {
        case .satisfied: return .unsatisfied
        case .unsatisfied: return .satisfied
        case .undetermined: return .undetermined
        }
    }

    private static func regionShape(_ shapeTag: Int, _ shape: String) -> Rule { { _ in anyOf(shapeTag, [shape]) } }

    // MARK: - Attribute conditions

    private static let conditions: [String: Rule] = {
        var map: [String: Rule] = [:]
        func set(_ table: String, _ tags: [Int], _ rule: @escaping Rule) {
            for tag in tags { map[key(table, tag)] = rule }
        }
        set("C.7.6.5", [0x00181063], present(0x00181063))
        set("C.7.6.5", [0x00181065], present(0x00181065))
        set("C.7.6.5", [0x003A0300], present(0x003A0300))
        set("C.8.12.1", [0x00082218]) { _ in .all([.present(0x00280008), .not(.present(0x00400560))]) }
        set("C.8.12.1", [0x00280006]) { _ in .integerGreaterThan(0x00280002, 1) }
        set("C.8.12.1", [0x00080033], present(0x00080033))
        set("C.8.12.1", [0x00081140], present(0x00081140))
        set("C.8.12.1", [0x00281051], present(0x00281050))
        // C.8.12: WSI conditions are evaluated against the root image or the optical-path item.
        set("C.8.12.3", [0x00081111], present(0x00081111))
        set("C.8.12.4", [0x00480001, 0x00480002, 0x00480003]) { .known($0.rootTruth(0x00080008, index: 2, in: ["VOLUME"])) }
        set("C.8.12.4", [0x00280006]) { _ in .integerGreaterThan(0x00280002, 1) }
        set("C.8.12.4", [0x00282112, 0x00282114], lossy)
        set("C.8.12.4", [0x20500020, 0x00281052, 0x00281053], equals(0x00280004, "MONOCHROME2"))
        set("C.8.12.4", [0x00480013, 0x00480014], equals(0x00480012, "YES"))
        set("C.8.12.5", [0x00480302]) { .known($0.rootTruth(0x00209311, in: ["TILED_FULL"])) }
        set("C.8.12.5", [0x00220055]) { _ in .not(.present(0x00480108)) }
        set("C.8.12.5", [0x00480108]) { _ in .not(.present(0x00220055)) }
        set("C.8.12.5", [0x00282000]) { context in
            .any([.known(context.rootValue(0x00280004) == "MONOCHROME2" ? .unsatisfied : .satisfied), .present(0x00480120)])
        }
        // Sensor channel semantics are not inferable from wavelength/filter metadata. Declared channel
        // descriptions evidence a non-natural interpretation; no claim of spectral calibration is made.
        set("C.8.12.5", [0x0022001A], present(0x0022001A))
        // C.20: absent optional operations mean no pre/post matrix or grid is applied in that item.
        set("C.20.2", [0x00200052]) { _ in .not(.present(0x00081140)) }
        set("C.20.2", [0x00081140]) { _ in .not(.present(0x00200052)) }
        for tag in [0x00081140, 0x0064000F, 0x00640010, 0x00640005] {
            set("C.20.3", [tag], present(tag))
        }
        set("C.27.1", [0x0066000A, 0x00660035], equals(0x00660009, "YES"))
        set("table_C.27-2", [0x0066001C], present(0x0066001B))
        // Series modules: a Performed Procedure Step is evidenced only by the reference itself.
        for table in ["C.8.15.1", "C.8.13.6", "C.8.19.1"] { set(table, [0x00081111], present(0x00081111)) }
        set("C.8.15.1", [0x00080068]) { context in
            .known(["1.2.840.10008.5.1.4.1.1.2.4", "1.2.840.10008.5.1.4.1.1.2.5"].contains(context.sopClassUID) ? .satisfied : .unsatisfied)
        }
        // C.7.6.18.1 Cardiac Synchronization module.
        set("C.7.6.18.1", [0x00189037], imageOriginalOrMixed)
        set("C.7.6.18.1", [0x00189085, 0x00189070, 0x00181083, 0x00181084]) { context in
            .all([.known(context.imageOriginalOrMixed), .not(.stringEquals(0x00189037, "NONE"))])
        }
        set("C.7.6.18.1", [0x00189169, 0x00181081, 0x00181082], imageOriginalOrMixedAnd(0x00189037, "PROSPECTIVE", "RETROSPECTIVE"))
        // "Required if type of framing is not time forward from trigger": only the attribute evidences it.
        set("C.7.6.18.1", [0x00181064], present(0x00181064))
        // C.7.6.18.2 Respiratory and C.7.6.18.3 Bulk Motion Synchronization modules.
        set("C.7.6.18.2", [0x00189170], imageOriginalOrMixed)
        set("C.7.6.18.2", [0x00189171]) { context in .all([.known(context.imageOriginalOrMixed), .not(.stringEquals(0x00189170, "NONE"))]) }
        set("C.7.6.18.2", [0x00209256]) { context in
            .all([.known(context.imageOriginalOrMixed), .not(.any(["NONE", "REALTIME", "BREATH_HOLD"].map { .stringEquals(0x00189170, $0) }))])
        }
        set("C.7.6.18.2", [0x00209250], present(0x00209250))
        set("C.7.6.18.3", [0x00189172], imageOriginalOrMixed)
        set("C.7.6.18.3", [0x00189173]) { context in .all([.known(context.imageOriginalOrMixed), .not(.stringEquals(0x00189172, "NONE"))]) }
        // C.8.15.2 Enhanced CT Image and the MR image/spectroscopy macros (table C.8-83/84).
        for table in ["C.8.15.2", "table_C.8-83"] {
            set(table, [0x0008002A, 0x00189073], imageOriginalOrMixed)
            set(table, [0x00189004], notLegacy)
        }
        set("table_C.8-83", [0x00189100, 0x00189064, 0x00180087], imageOriginalOrMixed)
        set("table_C.8-83", [0x00189174], notLegacy)
        set("table_C.8-84", [0x00089208, 0x00089209], notLegacy)
        for table in ["C.8.15.2", "C.8.13.1"] {
            set(table, [0x00280301, 0x00282110], notLegacy)
            set(table, [0x00282112, 0x00282114], lossy)
        }
        set("C.8.19.2", [0x00282112, 0x00282114], lossy)
        set("C.8.13.1", [0x00280006]) { _ in .integerGreaterThan(0x00280002, 1) }
        set("C.8.13.1", [0x20500020], equals(0x00280004, "MONOCHROME2"))
        // C.7.6.3 Image Pixel (table C.7-11c).
        set("table_C.7-11c", [0x00280006]) { _ in .integerGreaterThan(0x00280002, 1) }
        set("table_C.7-11c", [0x00280034]) { context in
            if DicomEnhancedImageModules.Profile(rawValue: context.sopClassUID)?.isVideo == true,
               context.root.contains(0x00280034) { return .known(.satisfied) }
            // Not required once a physical spacing is given by Pixel Measures or the frame detector properties.
            let spaced = context.root.contains(0x00280030) || context.macroPresent("C.7.6.16.2.1") || context.macroPresent("C.8.19.6.4")
            return .known(spaced ? .unsatisfied : .undetermined)
        }
        set("table_C.7-11c", [0x00281101, 0x00281102, 0x00281103, 0x00281201, 0x00281202, 0x00281203]) { context in
            // Pixel Presentation belongs to the CT/MR/PM image modules; its absence means no palette. A Parametric
            // Map with COLOR_RANGE carries the same attributes through its Palette Color Lookup Table module.
            let presentation: T = context.rootValue(0x00089205).map { ["COLOR", "MIXED", "COLOR_RANGE"].contains($0) ? .satisfied : .unsatisfied } ?? .unsatisfied
            return .any([.stringEquals(0x00280004, "PALETTE COLOR"), .known(presentation)])
        }
        set("C.7.6.3", [0x00287FE0]) { _ in .known(.unsatisfied) }
        set("C.7.6.3", [0x00280121]) { context in
            // A.51.4 permits a LABELMAP background value but forbids a padding range.
            context.rootValue(0x00620001) == "LABELMAP" ? .known(.unsatisfied) : .present(0x00280120)
        }
        // C.8.15.3.x CT functional group macros.
        set("C.8.15.3.2", [0x00189302, 0x00189333, 0x00189334], frameOriginal)
        set("C.8.15.3.2", [0x00189303], frameOriginalAnd(0x00189302, "CONSTANT_ANGLE"))
        for table in ["C.8.15.3.3", "C.8.15.3.6", "C.8.15.3.9"] { set(table, [0x00189378]) { .known($0.multiEnergy) } }
        set("C.8.15.3.3", [0x00181140, 0x00189305]) { context in
            let constantAngle = context.truth(context.macroValue("C.8.15.3.2", 0x00189302), in: ["CONSTANT_ANGLE"])
            return .all([.known(context.frameOrImageOriginal), .known(negate(constantAngle))])
        }
        set("C.8.15.3.3", [0x00189306, 0x00189307, 0x00181130, 0x00181120, 0x00180090], frameOrImageOriginal)
        set("C.8.15.3.4", [0x00189309], frameOriginalAndAcquisitionType(["SPIRAL", "CONSTANT_ANGLE"]))
        set("C.8.15.3.4", [0x00189310, 0x00189311], frameOriginalAndAcquisitionType(["SPIRAL"]))
        set("C.8.15.3.5", [0x00189327, 0x00189313, 0x00189318], frameOriginal)
        set("C.8.15.3.6", [0x00181110, 0x00189335], frameOrImageOriginal)
        set("C.8.15.3.7", [0x00189315, 0x00181210, 0x00189322, 0x00189319, 0x00189320], frameOriginal)
        set("C.8.15.3.7", [0x00189316], present(0x00181210))
        set("C.8.15.3.7", [0x00181100]) { context in .all([.known(context.frameOriginal), .not(.present(0x00189317))]) }
        set("C.8.15.3.7", [0x00189317]) { context in .all([.known(context.frameOriginal), .not(.present(0x00181100))]) }
        set("C.8.15.3.8", [0x00189377]) { .known($0.multiEnergy) }
        set("C.8.15.3.8", [0x00189328]) { context in
            .any([.known(context.frameOriginal), .known(Context.all(context.imageOriginal, context.multiEnergy))])
        }
        set("C.8.15.3.8", [0x00189330, 0x00189332, 0x00189323, 0x00189345], frameOrImageOriginal)
        set("C.8.15.3.8", [0x00181272], present(0x00181271))
        set("C.8.15.3.9", [0x00180060, 0x00181190, 0x00181160], frameOrImageOriginal)
        set("C.8.15.3.9", [0x00187050]) { context in .all([.known(context.frameOrImageOriginal), .not(.stringEquals(0x00181160, "NONE"))]) }
        set("C.8.15.3.9", [0x00189353]) { context in
            .known(Context.any(context.truth(context.frameType(3), in: ["ENERGY_PROP_WT"]),
                               context.rootTruth(0x00080008, index: 3, in: ["ENERGY_PROP_WT"])))
        }
        set("C.8.15.3.11", [0x00189353]) { .known($0.truth($0.frameType(3), in: ["ENERGY_PROP_WT"])) }
        set("C.8.15.3.12", [0x00189364, 0x0018937C]) { context in
            .known(Context.any(context.truth(context.frameType(4), in: ["VMI"]), context.rootTruth(0x00080008, index: 4, in: ["VMI"])))
        }
        set("table_C.8.2.2-2", [0x0018936B], equals(0x00189368, "SWITCHING_SOURCE"))
        set("table_C.8.2.2-3", [0x00189374, 0x00189375], equals(0x00189372, "PHOTON_COUNTING"))
        // C.7.6.16.2.x common functional group macros.
        // An IOD without Volumetric Properties or a third Image Type value is "other than" those values.
        set("C.7.6.16.2.1", [0x00280030]) { context in
            .known(Context.all(negate(context.truth(context.volumetricProperties ?? "", in: ["DISTORTED", "SAMPLED"])),
                               negate(context.truth(context.rootValue(0x00080008, index: 2) ?? "", in: ["LABEL", "OVERVIEW"]))))
        }
        // "... or SOP Class UID is Segmentation Storage and Frame of Reference UID (0020,0052) is present".
        set("C.7.6.16.2.1", [0x00180050]) { context in
            let volumetric = Context.all(context.truth(context.volumetricProperties ?? "", in: ["VOLUME", "SAMPLED"]),
                                         negate(context.truth(context.rootValue(0x00080008, index: 2) ?? "", in: ["LABEL", "OVERVIEW"])))
            let segmentation: T = context.isSegmentation && context.root.contains(0x00200052) ? .satisfied : .unsatisfied
            return .known(Context.any(volumetric, segmentation))
        }
        set("C.7.6.16.2.1", [0x00180088]) { context in
            .known(Context.all(negate(context.dimensionOrganizationNotTiledFull),
                               context.rootInt(0x00480303).map { $0 > 1 ? .satisfied : .unsatisfied } ?? .unsatisfied))
        }
        set("C.7.6.16.2.2", [0x00189151, 0x00189074, 0x00189220]) { context in
            .known(Context.all(context.frameOriginal, context.dimensionOrganizationNotTiledFull))
        }
        set("C.7.6.16.2.2", [0x00209157]) { context in .known(context.root[0x00209222]?.sequenceItems.isEmpty == false ? .satisfied : .unsatisfied) }
        set("C.7.6.16.2.2", [0x00209128, 0x00209056]) { context in .known(context.macroPresent("C.8.13.5.15") ? .satisfied : .unsatisfied) }
        set("C.7.6.16.2.2", [0x00209057]) { context in .any([.present(0x00209056), .known(context.macroPresent("C.8.13.5.15") ? .satisfied : .unsatisfied)]) }
        for table in ["C.7.6.16.2.3", "C.7.6.16.2.4"] {
            set(table, [0x00200032, 0x00200037]) { context in
                .known(Context.all(context.frameOriginal, negate(context.truth(context.volumetricProperties ?? "", in: ["DISTORTED"]))))
            }
        }
        set("C.7.6.16.2.5", [0x0040A170], notLegacy)
        set("C.7.6.16.2.6", [0x00089215, 0x0040A170], notLegacy)
        set("C.7.6.16.2.6", [0x00200020], equals(0x0028135A, "REORIENTED_ONLY"))
        set("C.7.6.16.2.7", [0x00209241]) { .known($0.dimensionIndexed(0x00209241)) }
        set("C.7.6.16.2.7", [0x00209252]) { context in .known(context.rootInt(0x00181083).map { $0 == 1 ? .satisfied : .unsatisfied } ?? .unsatisfied) }
        set("C.7.6.16.2.7", [0x00209251]) { .known($0.rootTechnique(0x00189037, isOtherThan: ["NONE", "REALTIME"])) }
        set("C.7.6.16.2.12", [0x00189344]) { .known($0.intravenousContrast) }
        set("C.7.6.16.2.17", [0x00209254]) { context in
            let time = context.rootValue(0x00209250).map { ["TIME", "BOTH"].contains($0) ? T.satisfied : .unsatisfied } ?? .satisfied
            return .known(Context.all(context.rootTechnique(0x00189170, isOtherThan: ["NONE", "REALTIME"]), time))
        }
        set("C.7.6.16.2.17", [0x00209245]) { .known($0.dimensionIndexed(0x00209245)) }
        set("C.7.6.16.2.17", [0x00209257]) { .known($0.rootTruth(0x00209250, in: ["TIME", "BOTH"])) }
        set("C.7.6.16.2.17", [0x00209246, 0x00209248]) { .known($0.rootTruth(0x00209250, in: ["AMPLITUDE", "BOTH"])) }
        set("C.7.6.16.2.17", [0x00209247], present(0x00209246))
        set("C.7.6.16.2.17", [0x00209249], present(0x00209248))
        // C.8.13.4 MR Pulse Sequence module.
        set("C.8.13.4", [0x00189005, 0x00180023, 0x00189008, 0x00189012, 0x00189014, 0x00189015, 0x00189017, 0x00189018,
                         0x00189024, 0x00189025, 0x00189029, 0x00189032, 0x00189033, 0x00189093], imageOriginalOrMixed)
        set("C.8.13.4", [0x00189011], imageOriginalOrMixedAnd(0x00189008, "SPIN", "BOTH"))
        set("C.8.13.4", [0x00189092], equals(0x00189014, "YES"))
        set("C.8.13.4", [0x00189250]) { .known($0.rootTruth(0x00080008, index: 2, in: ["ASL"])) }
        set("C.8.13.4", [0x00189034], imageOriginalOrMixedAnd(0x00189032, "RECTILINEAR"))
        set("C.8.13.4", [0x00189094], imageOriginalOrMixedAnd(0x00180023, "3D"))
        // C.8.13.5.x MR functional group macros.
        set("C.8.13.5.2", [0x00180080, 0x00181314, 0x00180091, 0x00189240, 0x00189241], frameOriginal)
        set("C.8.13.5.2", [0x00189239]) { .known($0.facts.sarCapable) }
        set("C.8.13.5.2", [0x00189180, 0x00189182]) { .known($0.facts.gradientOutputCapable) }
        set("C.8.13.5.2", [0x00189176]) { .known($0.facts.operatingModeRegulated) }
        set("C.8.13.5.3", [0x00181312, 0x00189058, 0x00189231, 0x00180093, 0x00180094], frameOriginal)
        set("C.8.13.5.3", [0x00189232]) { context in .known(Context.all(context.rootTruth(0x00180023, in: ["3D"]), context.frameOriginal)) }
        set("C.8.13.5.4", [0x00189082], frameOriginal)
        set("C.8.13.5.5", [0x00189009, 0x00189010, 0x00189021, 0x00189026, 0x00189027, 0x00189081, 0x00189077], frameOriginal)
        set("C.8.13.5.5", [0x00189079], frameOriginalAnd(0x00189009, "YES"))
        set("C.8.13.5.5", [0x00189183]) { context in .all([.known(context.frameOriginal), .not(.stringEquals(0x00189010, "NONE"))]) }
        set("C.8.13.5.5", [0x00189016]) { context in .known(Context.all(context.frameOriginal, context.rootTruth(0x00189008, in: ["GRADIENT", "BOTH"]))) }
        set("C.8.13.5.5", [0x00189036], frameOriginalAnd(0x00189081, "YES"))
        set("C.8.13.5.5", [0x00189078, 0x00189069, 0x00189155, 0x00189168], frameOriginalAnd(0x00189077, "YES"))
        set("C.8.13.5.6", [0x00189020, 0x00189022, 0x00189028, 0x00189098, 0x00180095], frameOriginal)
        set("C.8.13.5.6", [0x00189030, 0x00189019, 0x00189035], frameOriginalAnd(0x00189028, "GRID", "LINE"))
        set("C.8.13.5.6", [0x00189218, 0x00189219], frameOriginalAnd(0x00189028, "GRID"))
        set("C.8.13.5.7", [0x00181250, 0x00189041, 0x00189043, 0x00189044], frameOriginal)
        set("C.8.13.5.7", [0x00189045], frameOriginalAnd(0x00189043, "MULTICOIL"))
        set("C.8.13.5.8", [0x00181251, 0x00189050, 0x00189051], frameOriginal)
        set("C.8.13.5.9", [0x00189087, 0x00189075, 0x00189089], frameOriginal)
        set("C.8.13.5.9", [0x00189076], equals(0x00189075, "DIRECTIONAL"))
        set("C.8.13.5.9", [0x00189601], equals(0x00189075, "BMATRIX"))
        set("C.8.13.5.9", [0x00189147]) { .known($0.truth($0.frameType(3), in: ["DIFFUSION_ANISO"])) }
        set("C.8.13.5.10", [0x00180083], frameOriginal)
        set("C.8.13.5.12", [0x00189080], frameOriginal)
        set("C.8.13.5.13", [0x00189090, 0x00189091, 0x00189217], frameOriginal)
        set("C.8.13.5.14", [0x00189257], frameOriginal)
        set("C.8.13.5.14", [0x00189260], equals(0x00189257, "CONTROL", "LABEL"))
        set("C.8.13.5.14", [0x0018925A, 0x0018925B], equals(0x00189259, "YES"))
        set("C.8.13.5.14", [0x0018925D], equals(0x0018925C, "YES"))
        set("C.8.13.5.15", [0x00189624], equals(0x00189622, "YES"))
        // C.8.19.x Enhanced XA modules and macros; positioner and receptor facts live in XA/XRF Acquisition.
        set("C.8.19.2", [0x00189457]) { _ in .not(.stringEquals(0x00189410, "UNDEFINED")) }
        set("C.8.19.2", [0x00540410, 0x00540414]) { _ in .all([.stringEquals(0x00181508, "CARM"), .stringEquals(0x00189474, "YES")]) }
        set("C.8.19.2", [0x00540412], present(0x00540412))
        set("C.8.19.2", [0x00089410], equals(0x00189410, "BIPLANE"))
        set("C.8.19.2", [0x00089092], present(0x00081140))
        set("C.8.19.2", [0x00089154], present(0x00082112))
        set("table_10.42-1", [0x00089092], present(0x00081140))
        set("table_10.42-1", [0x00089154], present(0x00082112))
        set("table_10.42-1", [0x00089237], present(0x00089237))
        set("C.7.6.10", [0x00289416]) { context in
            .known(["1.2.840.10008.5.1.4.1.1.12.1.1", "1.2.840.10008.5.1.4.1.1.12.2.1"].contains(context.sopClassUID) ? .satisfied : .unsatisfied)
        }
        set("C.7.6.10", [0x00286102], equals(0x00286101, "REV_TID"))
        set("C.7.6.10", [0x00286110], equals(0x00286101, "AVG_SUB"))
        set("C.7.6.10", [0x00286120], equals(0x00286101, "TID", "REV_TID"))
        set("C.8.19.5", [0x00189430]) { context in .known(context.macroPresent("C.8.19.6.13") ? .satisfied : .unsatisfied) }
        set("C.8.19.3", [0x00189330, 0x00189328]) { _ in .not(.present(0x00189332)) }
        set("C.8.19.3", [0x00189332]) { _ in .any([.not(.present(0x00189328)), .not(.present(0x00189330))]) }
        set("C.8.19.3", [0x00189474], equals(0x00181508, "CARM"))
        set("C.8.19.7", [0x00289478], equals(0x00281090, "SUB"))
        set("C.8.19.6.12", [0x00181702, 0x00181704, 0x00181706, 0x00181708], regionShape(0x00181700, "RECTANGULAR"))
        set("C.8.19.6.12", [0x00181710, 0x00181712], regionShape(0x00181700, "CIRCULAR"))
        set("C.8.19.6.12", [0x00181720], regionShape(0x00181700, "POLYGONAL"))
        set("C.8.19.6.3", [0x00189436, 0x00189437, 0x00189438, 0x00189439], regionShape(0x00189435, "RECTANGULAR"))
        set("C.8.19.6.3", [0x00189440, 0x00189441], regionShape(0x00189435, "CIRCULAR"))
        set("C.8.19.6.3", [0x00189442], regionShape(0x00189435, "POLYGONAL"))
        set("table_C.7-17a", [0x00181602, 0x00181604, 0x00181606, 0x00181608], regionShape(0x00181600, "RECTANGULAR"))
        set("table_C.7-17a", [0x00181610, 0x00181612], regionShape(0x00181600, "CIRCULAR"))
        set("table_C.7-17a", [0x00181620], regionShape(0x00181600, "POLYGONAL"))
        set("C.8.19.6.2", [0x00187030]) { .known($0.rootTruth(0x00189420, in: ["DIGITAL_DETECTOR"])) }
        set("C.8.19.6.4", [0x00181164]) { .known($0.imageOriginal) }
        set("C.8.19.6.4", [0x00289445], equals(0x00289444, "NON_UNIFORM"))
        set("C.8.19.6.10", [0x00181510, 0x00181511]) { .known($0.rootTruth(0x00181508, in: ["CARM"])) }
        set("C.8.19.6.10", [0x00189447]) { .known($0.rootTruth(0x00181508, in: ["COLUMN"])) }
        set("C.8.19.6.9", [0x00189404], present(0x00189403))
        set("C.8.19.6.9", [0x00181130, 0x00189449]) { .known($0.imageOriginal) }
        // C.8.20 Segmentation Series/Image and the Segment Description macro.
        for table in ["C.8.20.1", "C.8.32.1"] { set(table, [0x00081111], present(0x00081111)) }
        set("C.8.20.2", [0x00282112, 0x00282114], lossy)
        set("C.8.20.2", [0x00620010, 0x0062000E], equals(0x00620001, "FRACTIONAL"))
        // "Required if Segment Algorithm Type (0062,0008) is not MANUAL."
        set("C.8.20.2", [0x00620009]) { _ in .not(anyOf(0x00620008, ["MANUAL"])) }
        set("table_C.8.20-4", [0x00620020], present(0x00620021))
        set("table_C.8.20-4", [0x00620021], present(0x00620020))
        set("table_C.8.20-4", [0x30060084], equals(0x00081150, "1.2.840.10008.5.1.4.1.1.481.3"))
        // C.8.32.2 Parametric Map Image: integer pixels carry Bits Stored/High Bit; COLOR_RANGE needs a palette.
        set("C.8.32.2", [0x00280101, 0x00280102]) { .known($0.hasIntegerPixelData) }
        set("C.8.32.2", [0x00282112, 0x00282114], lossy)
        set("C.8.32.2", [0x00281199]) { context in .all([.known(context.colorRange), .not(.present(0x00281101))]) }
        set("C.8.32.2", [0x00282000]) { .known($0.colorRange) }
        // C.7.6.24/C.7.6.25 floating point pixels: aspect ratio as in C.7.6.3, range limits from the padding value.
        for table in ["C.7.6.24", "C.7.6.25"] {
            set(table, [0x00280034]) { context in
                .known(context.root.contains(0x00280030) || context.macroPresent("C.7.6.16.2.1") ? .unsatisfied : .undetermined)
            }
        }
        set("C.7.6.24", [0x00280124], present(0x00280122))
        set("C.7.6.25", [0x00280125], present(0x00280123))
        // C.7.9: a Segmentation or Presentation State carries the plain tables; other IODs choose plain or segmented data.
        set("table_C.7-22a", [0x00281201, 0x00281202, 0x00281203]) { context in
            context.isSegmentation || context.isPresentationState ? .known(.satisfied) : .not(.present(0x00281221))
        }
        set("table_C.7-22a", [0x00281221, 0x00281222, 0x00281223]) { context in
            context.isSegmentation || context.isPresentationState ? .known(.unsatisfied) : .present(0x00281221)
        }
        // C.10.4 Displayed Area: a subset of the referenced images is evidenced by the sequence itself;
        // a tiled referenced instance is one whose SOP Class is VL Whole Slide Microscopy Image Storage.
        for table in ["C.10.4", "C.10.5", "C.11.8", "C.11.14"] { set(table, [0x00081140], present(0x00081140)) }
        set("C.10.4", [0x00480301]) { .known($0.referencesTiledInstance) }
        set("C.10.4", [0x00700101], equals(0x00700100, "TRUE SIZE"))
        set("C.10.4", [0x00700102]) { _ in .not(.present(0x00700101)) }
        set("C.10.4", [0x00700103], equals(0x00700100, "MAGNIFY"))
        // C.10.5 Graphic Annotation: text or graphic objects (or both); bounding box or anchor point.
        set("C.10.5", [0x00700008]) { _ in .not(.present(0x00700009)) }
        set("C.10.5", [0x00700009]) { _ in .not(.present(0x00700008)) }
        set("C.10.5", [0x00700003, 0x00700012], present(0x00700010))
        set("C.10.5", [0x00700004, 0x00700015], present(0x00700014))
        set("C.10.5", [0x00700010]) { _ in .any([.not(.present(0x00700014)), .present(0x00700011)]) }
        set("C.10.5", [0x00700011]) { _ in .any([.not(.present(0x00700014)), .present(0x00700010)]) }
        set("C.10.5", [0x00700014]) { _ in .not(.all([.present(0x00700010), .present(0x00700011)])) }
        set("C.10.5", [0x00620020], present(0x00620021))
        set("C.10.5", [0x00620021], present(0x00620020))
        // Graphic Filled: closed CIRCLE/ELLIPSE graphics, RECTANGLE/ELLIPSE compound graphics; closed polylines
        // are settled by the composition from their points.
        set("C.10.5", [0x00700024]) { _ in
            .any([anyOf(0x00700023, ["CIRCLE", "ELLIPSE"]), anyOf(0x00700294, ["RECTANGLE", "ELLIPSE"]), .present(0x00700024)])
        }
        set("C.10.5", [0x00700273]) { _ in .any([.present(0x00700230), anyOf(0x00700294, ["CUTLINE", "INFINITELINE"])]) }
        set("C.10.5", [0x00700261], equals(0x00700294, "CUTLINE", "INFINITELINE", "CROSSHAIR"))
        set("C.10.5", [0x00700262], equals(0x00700294, "CROSSHAIR"))
        set("C.10.5", [0x00700287], equals(0x00700294, "AXIS"))
        set("C.10.5", [0x00700274, 0x00700279, 0x00700278], equals(0x00700294, "RULER", "AXIS", "CROSSHAIR"))
        // Text, line and fill styles (tables C.10-5a/b/c). The alignment conditions refer to the enclosing
        // Text Object item, which the style item cannot see; they are read as not required.
        set("table_C.10-5a", [0x00700228], present(0x00700227))
        set("table_C.10-5a", [0x00700242, 0x00700243], present(0x00700010))
        set("table_C.10-5a", [0x00700245, 0x00700246, 0x00700247, 0x00700258]) { _ in .not(.stringEquals(0x00700244, "OFF")) }
        set("table_C.10-5b", [0x00700255], equals(0x00700254, "DASHED"))
        set("table_C.10-5c", [0x00700256], equals(0x00700257, "STIPPELED"))
        // C.11.6 Softcopy Presentation LUT, C.11.12 Shutter, C.11.13 Mask, C.11.14 Blending, C.11-1b Modality LUT.
        set("C.11.6", [0x20500010]) { _ in .not(.present(0x20500020)) }
        set("C.11.6", [0x20500020]) { _ in .not(.present(0x20500010)) }
        set("C.11.12", [0x00181622], present(0x00181600))
        set("C.11.12", [0x00181624]) { context in
            .all([.present(0x00181600), .known(context.sopClassUID == "1.2.840.10008.5.1.4.1.1.11.1" ? .unsatisfied : .satisfied)])
        }
        set("C.11.13", [0x00286100, 0x00281090], present(0x00286100))
        set("C.11.13", [0x00286112], present(0x00286112))
        set("C.11.14", [0x00283110], present(0x00283110))
        set("table_C.11-1b", [0x00283000]) { _ in .not(.present(0x00281052)) }
        set("table_C.11-1b", [0x00281052]) { _ in .not(.present(0x00283000)) }
        set("table_C.11-1b", [0x00281053, 0x00281054], present(0x00281052))
        // C.8.12.14 Microscope Slide Layer Tile Organization.
        set("C.8.12.14", [0x00480303], equals(0x00209311, "TILED_FULL"))
        set("C.8.12.14", [0x0040074A], present(0x0040074A))
        set("C.8.12.14", [0x00480102]) { context in
            .any([.known(context.macroPresentAnywhere("C.8.12.6.1") ? .satisfied : .unsatisfied), anyOf(0x00209311, ["TILED_FULL"])])
        }
        // C.7.6.16.2.25 converted attributes and C.7.6.16.2.10b/C.11-2b VOI LUT choice.
        set("C.7.6.16.2.25.1", [0x00209170], present(0x00209170))
        set("C.7.6.16.2.25.2", [0x00209171], present(0x00209171))
        set("table_C.11-2b", [0x00283010]) { _ in .not(.present(0x00281050)) }
        set("table_C.11-2b", [0x00281050]) { _ in .not(.present(0x00283010)) }
        set("table_C.11-2b", [0x00281051], present(0x00281050))
        // C.8.8.3 RT Dose: pixel description with grid-based doses, coded units/types, transformed and derived doses,
        // and the references each Dose Summation Type requires.
        set("C.8.8.3", [0x00280002, 0x00280004, 0x00280100, 0x00280101, 0x00280102, 0x00280103, 0x3004000E]) { .known($0.hasIntegerPixelData) }
        set("C.8.8.3", [0x30040020], equals(0x30040002, "CODED"))
        set("C.8.8.3", [0x30040021, 0x30040024], equals(0x30040004, "CODED"))
        set("C.8.8.3", [0x30040005]) { .known($0.doseModifierContains("131406")) }
        set("C.8.8.3", [0x00089215]) { .known($0.doseModifierContains("131407")) }
        set("C.8.8.3", [0x00700404]) { _ in .all([.present(0x30040005), anyOf(0x30040005, ["RIGID", "NON_RIGID"])]) }
        set("C.8.8.3", [0x300C0002]) { context in
            .known(context.rootTruth(0x3004000A, in: ["PLAN", "MULTI_PLAN", "FRACTION", "BEAM", "BRACHY", "FRACTION_SESSION", "BEAM_SESSION",
                                                     "BRACHY_SESSION", "CONTROL_POINT"]))
        }
        set("C.8.8.3", [0x300C0118]) { context in .known(context.root.contains(0x300C0116) ? .satisfied : .unsatisfied) }
        set("C.8.8.3", [0x300C0020]) { context in
            .known(context.rootTruth(0x3004000A, in: ["FRACTION", "BEAM", "BRACHY", "FRACTION_SESSION", "BEAM_SESSION", "BRACHY_SESSION", "CONTROL_POINT"]))
        }
        // Referenced Beam Sequence: required in the fraction group for beam-level types; self-evidenced in a treatment record.
        set("C.8.8.3", [0x300C0004]) { context in
            .any([.known(context.rootTruth(0x3004000A, in: ["BEAM", "BEAM_SESSION", "CONTROL_POINT"])), .present(0x300C0004)])
        }
        set("C.8.8.3", [0x300C00F2]) { .known($0.rootTruth(0x3004000A, in: ["CONTROL_POINT"])) }
        set("C.8.8.3", [0x300C000A]) { .known($0.rootTruth(0x3004000A, in: ["BRACHY", "BRACHY_SESSION"])) }
        set("C.8.8.3", [0x30080030, 0x30080022]) { .known($0.rootTruth(0x3004000A, in: ["RECORD"])) }
        set("C.8.8.3", [0x3004000C]) { context in
            .known(Context.all(context.rootInt(0x00280008).map { $0 > 1 ? .satisfied : .unsatisfied } ?? .unsatisfied,
                               context.frameIncrementPointsTo(0x3004000C)))
        }
        set("C.8.8.3", [0x300C0116]) { context in
            .any([.known(context.rootTruth(0x3004000A, in: ["PLAN_OVERVIEW"])),
                  .all([.known(context.rootTruth(0x3004000A, in: ["PLAN", "MULTI_PLAN", "RECORD"])), .present(0x300C0116)])])
        }
        set("C.8.8.3", [0x300C0119]) { .known($0.rootTruth(0x3004000A, in: ["PLAN_OVERVIEW", "PLAN", "MULTI_PLAN"])) }
        set("C.8.8.3", [0x30100038], present(0x30100038))
        set("C.8.8.3", [0x300C0060]) { _ in .not(.present(0x00081140)) }
        set("C.8.8.3", [0x00081140]) { _ in .not(.present(0x300C0060)) }
        // C.8.8.5 Structure Set, C.8.8.8 ROI Observations, C.8.8.9 General Plan, C.8.8.16 Approval.
        set("C.8.8.5", [0x0062000B], equals(0x00081150, "1.2.840.10008.5.1.4.1.1.66.4"))
        set("C.8.8.5", [0x0070031B], equals(0x00081150, "1.2.840.10008.5.1.4.1.1.66.2"))
        set("C.8.8.8", [0x3006004E], present(0x3006004E))
        set("C.8.8.8", [0x300600B6], equals(0x300600B2, "ELEM_FRACTION"))
        set("C.8.8.9", [0x300C0060], equals(0x300A000C, "PATIENT"))
        set("C.8.8.16", [0x300E0004, 0x300E0005, 0x300E0008], equals(0x300E0002, "APPROVED", "REJECTED"))
        // C.8.8.13 Fraction Scheme, C.8.8.10 Prescription, C.8.8.12 Patient Setup.
        set("C.8.8.13", [0x300C0004]) { _ in .integerGreaterThan(0x300A0080, 0) }
        set("C.8.8.13", [0x300C000A]) { _ in .integerGreaterThan(0x300A00A0, 0) }
        set("C.8.8.13", [0x300A0090, 0x300A0092], present(0x300A0091))
        set("C.8.8.13", [0x300C0120]) { _ in .all([anyOf(0x300C0123, ["YES"]), .not(.present(0x300A065A))]) }
        set("C.8.8.13", [0x300A065A]) { _ in .all([anyOf(0x300C0123, ["YES"]), .not(.present(0x300C0120))]) }
        set("C.8.8.10", [0x30060084], equals(0x300A0014, "POINT", "VOLUME"))
        set("C.8.8.10", [0x300A0018], equals(0x300A0014, "COORDINATES"))
        set("C.8.8.12", [0x00185100]) { _ in .not(.present(0x300A0184)) }
        set("C.8.8.12", [0x300A0184]) { _ in .not(.present(0x00185100)) }
        // C.8.8.14 RT Beams. Control point attributes required "for the first Item or when they change", the
        // material-dependent compensator/block data and the final meterset weight are settled by the composition.
        set("C.8.8.14", [0x30020052], equals(0x30020051, "NON_STANDARD"))
        set("C.8.8.14", [0x300A00B6]) { _ in .any([.not(.present(0x300800A3)), .stringEquals(0x300800A3, "NO")]) }
        set("C.8.8.14", [0x300A00BE], equals(0x300A00B8, "MLCX", "MLCY"))
        set("C.8.8.14", [0x300800A1], equals(0x300800A3, "YES"))
        set("C.8.8.14", [0x300A00D1]) { _ in .integerGreaterThan(0x300A00D0, 0) }
        set("C.8.8.14", [0x300A00E3]) { _ in .integerGreaterThan(0x300A00E0, 0) }
        set("C.8.8.14", [0x300A00E4, 0x300A00E1]) { _ in .known(.satisfied) }
        set("C.8.8.14", [0x300C00B0]) { _ in .integerGreaterThan(0x300A00ED, 0) }
        set("C.8.8.14", [0x300A00F4]) { _ in .integerGreaterThan(0x300A00F0, 0) }
        set("C.8.8.14", [0x300A0433], equals(0x300A0432, "SYM_SQUARE", "SYM_CIRCULAR"))
        set("C.8.8.14", [0x300A0434, 0x300A0435], equals(0x300A0432, "SYM_RECTANGLE"))
        for tag in [0x300A00C7, 0x300A00EB, 0x300A00EC, 0x300A02E2, 0x300A0100, 0x300A0102, 0x300A0093, 0x300C00F0, 0x300A0088, 0x300A0089,
                    0x300A008A, 0x300A010E, 0x300C0080, 0x300A0116, 0x300A011A, 0x300800A2, 0x300A011E, 0x300A011F, 0x300A0120, 0x300A0121,
                    0x300A0122, 0x300A0123, 0x300A0125, 0x300A0126, 0x300A0140, 0x300A0142, 0x300A0144, 0x300A0146, 0x300A0128, 0x300A0129,
                    0x300A012A, 0x300A012C] {
            set("C.8.8.14", [tag], present(tag))
        }
        // C.8.8.15 RT Brachy Application Setups.
        set("C.8.8.15", [0x300A0229, 0x300A022B, 0x300A02A4, 0x300A02C8]) { _ in .present(0x300A0229) }
        set("C.8.8.15", [0x300A022B], present(0x300A022B))
        set("C.8.8.15", [0x300A02A4], present(0x300A02A4))
        set("C.8.8.15", [0x300A02C8], present(0x300A02C8))
        set("C.8.8.15", [0x300A028A, 0x300A028C]) { .known($0.rootTruth(0x300A0202, in: ["PDR"])) }
        set("C.8.8.15", [0x300A0291, 0x300A0292, 0x300A0296, 0x30060084], present(0x300A0290))
        set("C.8.8.15", [0x300A0274, 0x300A0272], present(0x300A0271))
        set("C.8.8.15", [0x300A02A0], equals(0x300A0288, "STEPWISE"))
        // Included RT macros.
        set("table_10.33-1", [0x30100007], present(0x30100007))
        set("table_10.38-1", [0x00181631, 0x00181632, 0x00181633, 0x00181634], regionShape(0x00181630, "RECTANGULAR"))
        set("table_10.38-1", [0x00181635, 0x00181636], regionShape(0x00181630, "CIRCULAR"))
        set("table_10.38-1", [0x00181637, 0x00181638], regionShape(0x00181630, "POLYGONAL"))
        set("table_C.17-3b", [0x0040A123, 0x00401101], equals(0x0040A084, "PSN"))
        set("table_C.17-3b", [0x00081010, 0x00181002, 0x00080070, 0x00081090], equals(0x0040A084, "DEV"))
        set("table_C.36.2.1.5-1", [0x30100003, 0x30100005], equals(0x30100002, "YES"))
        for tag in [0x300A0602, 0x300A0647, 0x300A064F, 0x300A0646] { set("table_C.36.2.2.19-1", [tag], present(tag)) }
        set("table_C.36.2.2.19-1", [0x300800A4], equals(0x300A064E, "BINARY"))
        for tag in [0x300A064B, 0x300A064A, 0x300A064C] { set("table_C.36.2.2.20-1", [tag], present(tag)) }
        // C.10.9 Waveform, C.10.10 Waveform Annotation and the filter characteristics macro. Conditions that only
        // the acquisition can settle (trigger, defined units, padding, filter kind) are evidenced by presence.
        set("C.10.9", [0x00181068]) { .known($0.rootValue(0x00181800) == "Y" ? .satisfied : .unsatisfied) }
        for tag in [0x00181069, 0x003A0310, 0x003A0209, 0x003A0210, 0x5400100A] { set("C.10.9", [tag], present(tag)) }
        set("C.10.9", [0x003A0211, 0x003A0212, 0x003A0213], present(0x003A0210))
        set("C.10.9", [0x003A0214]) { _ in .not(.present(0x003A0215)) }
        set("C.10.9", [0x003A0215]) { _ in .not(.present(0x003A0214)) }
        set("C.10.9", [0x003A0220]) { _ in .all([anyOf(0x003A0317, ["AC"]), .not(.present(0x003A0318))]) }
        set("C.10.9", [0x003A0318]) { _ in .all([anyOf(0x003A0317, ["AC"]), .not(.present(0x003A0220))]) }
        set("C.10.9", [0x003A0221]) { _ in .all([.present(0x003A0317), .not(.present(0x003A0319))]) }
        set("C.10.9", [0x003A0319]) { _ in .all([.present(0x003A0317), .not(.present(0x003A0221))]) }
        set("C.10.9", [0x003A0247]) { _ in .not(.present(0x003A0248)) }
        set("C.10.9", [0x003A0248]) { _ in .not(.present(0x003A0247)) }
        set("C.10.10", [0x00700006]) { _ in .not(.present(0x0040A043)) }
        set("C.10.10", [0x0040A043]) { _ in .not(.present(0x00700006)) }
        set("C.10.10", [0x0040A195, 0x0040A130], present(0x0040A195))
        set("C.10.10", [0x0040A130], present(0x0040A130))
        set("C.10.10", [0x0040A132]) { _ in .all([.present(0x0040A130), .not(.present(0x0040A138)), .not(.present(0x0040A13A))]) }
        set("C.10.10", [0x0040A138]) { _ in .all([.present(0x0040A130), .not(.present(0x0040A132)), .not(.present(0x0040A13A))]) }
        set("C.10.10", [0x0040A13A]) { _ in .all([.present(0x0040A130), .not(.present(0x0040A132)), .not(.present(0x0040A138))]) }
        for tag in [0x003A0220, 0x003A0221, 0x003A0222] { set("table_C.10.12-1", [tag], present(tag)) }
        set("table_C.10.12-1", [0x003A0223], present(0x003A0222))
        set("table_C.10.12-1", [0x003A0323], equals(0x003A0322, "ANALOG"))
        set("table_C.10.12-1", [0x003A0326], equals(0x003A0322, "DIGITAL"))
        // C.24.2 Encapsulated Document: CDA identifier, MIME subcomponents, document references and SR content.
        set("C.24.2", [0x00420013, 0x00420014, 0x00687005, 0x0040A504], present(0x00420013))
        for tag in [0x00420014, 0x00687005, 0x0040A504] { set("C.24.2", [tag], present(tag)) }
        set("C.24.2", [0x0040E001]) { context in .known(context.encapsulatedDocumentProfile == .cda ? .satisfied : .unsatisfied) }
        set("C.24.2", [0x0040A040, 0x0040A050], present(0x0040A730))
        // Remaining included macros with instance-local conditions.
        set("table_C.36.2.4.12-1", [0x300A0675]) { _ in .any([.present(0x300A07A1), .present(0x300A07A0)]) }
        set("table_C.36.2.3.4-1", [0x300A0796], present(0x300A0796))
        set("table_C.36.2.2.3-1", [0x300A0615]) { _ in .not(.present(0x300A060E)) }
        set("table_C.36.2.2.3-1", [0x300A060E]) { _ in .not(.present(0x300A0615)) }
        set("table_C.36.2.2.3-1", [0x300A0613], present(0x300A0615))
        set("table_10.36-1", [0x3010001C, 0x3010001D], present(0x3010001B))
        return map
    }()

    /// Conditions whose "may be present otherwise" clause the generator could not read from the row.
    static let mayBePresentOtherwise: Set<String> = [
        key("C.8.13.5.9", 0x00189076), key("C.7.6.16.2.5", 0x0040A170), key("C.7.6.16.2.6", 0x00089215),
        key("C.7.6.16.2.6", 0x0040A170), key("C.7.6.16.2.1", 0x00280030), key("C.7.6.16.2.1", 0x00180050),
        key("C.7.6.16.2.3", 0x00200032), key("C.7.6.16.2.4", 0x00200037), key("C.7.6.16.2.2", 0x00189151),
        key("C.7.6.16.2.2", 0x00189074), key("C.7.6.16.2.2", 0x00189220), key("C.8.15.3.12", 0x00189364),
        key("C.8.15.3.12", 0x0018937C), key("table_10.42-1", 0x00089092), key("table_10.42-1", 0x00089154),
        key("table_C.7-22a", 0x00281201), key("table_C.7-22a", 0x00281202), key("table_C.7-22a", 0x00281203),
        key("C.8.32.2", 0x00281199), key("C.8.32.2", 0x00282000),
        key("C.10.4", 0x00700101), key("C.10.5", 0x00700008), key("C.10.5", 0x00700009), key("C.10.5", 0x00700024),
        key("table_C.10-5a", 0x00700242), key("table_C.10-5a", 0x00700243),
        key("C.8.8.3", 0x300C0002), key("C.8.8.3", 0x300C0004), key("C.8.8.13", 0x300C0120), key("C.8.8.13", 0x300A065A),
        key("C.8.8.14", 0x300A00BE), key("table_C.36.2.2.19-1", 0x300800A4), key("C.10.9", 0x003A0221), key("C.10.9", 0x003A0319)
    ]

    // MARK: - Enumerated Values (PS3.3 2026c); Defined Terms are not closed sets and stay unconstrained.

    private static let yesNo: Set<String> = ["YES", "NO"]

    private static let enumerations: [String: Set<String>] = {
        var map: [String: Set<String>] = [:]
        func set(_ table: String, _ tags: [Int], _ values: Set<String>) { for tag in tags { map[key(table, tag)] = values } }
        set("C.27.1", [0x00660009], yesNo)
        set("C.27.1", [0x0066000E, 0x00660010], ["YES", "NO", "UNKNOWN"])
        set("C.27.1", [0x0066000D], ["SURFACE", "WIREFRAME", "POINTS"])
        set("table_C.8-131", [0x00089205], ["COLOR", "MONOCHROME", "MIXED", "TRUE_COLOR"])
        set("table_C.8-131", [0x00089206], ["VOLUME", "SAMPLED", "DISTORTED", "MIXED"])
        for table in ["C.8.15.2", "C.8.13.1", "C.8.19.2", "table_C.8-83"] {
            set(table, [0x00189004], ["PRODUCT", "RESEARCH", "SERVICE"])
            set(table, [0x00280301], yesNo)
            set(table, [0x00282110], ["00", "01"])
            set(table, [0x20500020], ["IDENTITY"])
            set(table, [0x00280004], ["MONOCHROME2"])
            set(table, [0x00189361], yesNo)
        }
        set("table_C.8-84", [0x00089208], ["MAGNITUDE", "PHASE", "REAL", "IMAGINARY", "MIXED"])
        set("C.7.6.18.1", [0x00189037], ["NONE", "REALTIME", "PROSPECTIVE", "RETROSPECTIVE", "PACED"])
        set("C.7.6.18.2", [0x00189170], ["NONE", "BREATH_HOLD", "REALTIME", "GATING", "TRACKING", "PHASE_ORDERING", "PHASE_RESCAN",
                                          "RETROSPECTIVE", "CORRECTION"])
        set("C.7.6.18.2", [0x00209250], ["TIME", "AMPLITUDE", "BOTH"])
        set("C.7.6.18.3", [0x00189172], ["NONE", "REALTIME", "GATING", "TRACKING", "RETROSPECTIVE", "CORRECTION"])
        set("C.8.15.3.2", [0x00189333, 0x00189334], yesNo)
        set("C.8.15.3.3", [0x00181140], ["CW", "CC"])
        set("C.8.13.4", [0x00180023], ["2D", "3D"])
        set("C.8.13.4", [0x00189008], ["SPIN", "GRADIENT", "BOTH"])
        set("C.8.13.4", [0x00189011, 0x00189012, 0x00189014, 0x00189015, 0x00189018, 0x00189024], yesNo)
        set("C.8.13.4", [0x00189017], ["FREE_PRECESSION", "TRANSVERSE", "TIME_REVERSED", "LONGITUDINAL", "NONE"])
        set("C.8.13.4", [0x00189025], ["WATER", "FAT", "FAT_AND_WATER", "SILICON_GEL", "NONE"])
        set("C.8.13.4", [0x00189029], ["2D", "3D", "NONE"])
        set("C.8.13.4", [0x00189032], ["RECTILINEAR", "RADIAL", "SPIRAL"])
        set("C.8.13.4", [0x00189034], ["LINEAR", "CENTRIC", "SEGMENTED", "REVERSE_LINEAR", "REVERSE_CENTRIC"])
        set("C.8.13.4", [0x00189033], ["SINGLE", "PARTIAL", "FULL"])
        set("C.8.13.4", [0x00189094], ["FULL", "CYLINDRICAL", "ELLIPSOIDAL", "WEIGHTED"])
        set("C.8.13.5.3", [0x00181312], ["ROW", "COLUMN", "OTHER"])
        set("C.8.13.5.5", [0x00189009, 0x00189021, 0x00189081, 0x00189077], yesNo)
        set("C.8.13.5.5", [0x00189016], ["RF", "GRADIENT", "RF_AND_GRADIENT", "NONE"])
        set("C.8.13.5.5", [0x00189026], ["WATER", "FAT", "NONE"])
        set("C.8.13.5.5", [0x00189027], ["SLAB", "NONE"])
        set("C.8.13.5.5", [0x00189036], ["PHASE", "FREQUENCY", "SLICE_SELECT", "COMBINATION"])
        set("C.8.13.5.6", [0x00189020], ["ON_RESONANCE", "OFF_RESONANCE", "NONE"])
        set("C.8.13.5.6", [0x00189022], yesNo)
        set("C.8.13.5.6", [0x00189028], ["GRID", "LINE", "NONE"])
        set("C.8.13.5.7", [0x00189044], yesNo)
        set("C.8.13.5.9", [0x00189075], ["DIRECTIONAL", "BMATRIX", "ISOTROPIC", "NONE"])
        set("C.8.13.5.14", [0x00189259, 0x0018925C], yesNo)
        set("C.8.13.5.15", [0x00189622, 0x00189624], yesNo)
        set("C.8.19.2", [0x00189410], ["UNDEFINED", "SINGLE PLANE", "BIPLANE"])
        set("C.8.19.2", [0x00189457], ["MONOPLANE", "PLANE A", "PLANE B"])
        set("C.8.19.3", [0x00181508], ["CARM", "COLUMN", "MAMMOGRAPHIC", "PANORAMIC", "CEPHALOSTAT", "RIGID", "NONE"])
        set("C.8.19.3", [0x00189474], yesNo)
        set("C.8.19.3", [0x00189420], ["IMG_INTENSIFIER", "DIGITAL_DETECTOR"])
        set("C.7.6.10", [0x00286101], ["AVG_SUB", "TID", "REV_TID"])
        set("C.8.19.7", [0x00281090], ["SUB", "NAT"])
        set("C.8.19.6.12", [0x00181700], ["RECTANGULAR", "CIRCULAR", "POLYGONAL"])
        set("C.8.19.6.3", [0x00189435], ["RECTANGULAR", "CIRCULAR", "POLYGONAL"])
        set("table_C.7-17a", [0x00181600], ["RECTANGULAR", "CIRCULAR", "POLYGONAL", "BITMAP"])
        set("C.8.19.6.4", [0x00289444], ["UNIFORM", "NON_UNIFORM"])
        set("C.7.6.16.2.8", [0x00209072], ["R", "L", "U", "B"])
        // C.8.20.2 Segmentation Image (Segmentation Storage carries BINARY or FRACTIONAL; LABELMAP has its own SOP Class).
        set("C.8.20.2", [0x00280004], ["MONOCHROME2", "PALETTE COLOR"])
        set("C.8.20.2", [0x00282110], ["00", "01"])
        set("C.8.20.2", [0x00620001], ["BINARY", "FRACTIONAL", "LABELMAP"])
        set("C.8.20.2", [0x00620010], ["PROBABILITY", "OCCUPANCY"])
        set("C.8.20.2", [0x00620013], ["YES", "UNDEFINED", "NO"])
        set("table_C.8.20-4", [0x00620008], ["AUTOMATIC", "SEMIAUTOMATIC", "MANUAL"])
        // C.8.32.2 Parametric Map Image and its frame type; C.7.6.24/25 floating point pixels.
        set("C.8.32.2", [0x00089205], ["COLOR_RANGE", "MONOCHROME"])
        set("C.8.32.2", [0x00280004], ["MONOCHROME2"])
        set("C.8.32.2", [0x20500020], ["IDENTITY"])
        set("C.8.32.2", [0x00282110], ["00", "01"])
        set("C.8.32.2", [0x00280301], ["NO"])
        set("C.8.32.2", [0x00280302], yesNo)
        set("C.8.32.2", [0x00189004], ["PRODUCT", "RESEARCH", "SERVICE"])
        for table in ["C.7.6.24", "C.7.6.25"] { set(table, [0x00280004], ["MONOCHROME2"]) }
        set("C.7.6.16.2.9b", [0x00281054], ["US"])
        // Softcopy Presentation States (C.10, C.11).
        set("C.10.4", [0x00700100], ["SCALE TO FIT", "TRUE SIZE", "MAGNIFY"])
        set("C.10.4", [0x00480301], ["FRAME", "VOLUME"])
        set("C.10.5", [0x00700003, 0x00700004, 0x00700005], ["PIXEL", "DISPLAY", "MATRIX"])
        set("C.10.5", [0x00700023], ["POINT", "POLYLINE", "INTERPOLATED", "CIRCLE", "ELLIPSE"])
        set("C.10.5", [0x00700012], ["LEFT", "RIGHT", "CENTER"])
        set("C.10.5", [0x00700015, 0x00700024, 0x00700278], ["Y", "N"])
        set("C.10.5", [0x00700282], ["PIXEL", "DISPLAY"])
        set("C.10.5", [0x00700274], ["BOTTOM", "CENTER", "TOP"])
        set("C.10.5", [0x00700279], ["BOTTOM", "TOP"])
        set("table_C.10-5a", [0x00700242], ["LEFT", "CENTER", "RIGHT"])
        set("table_C.10-5a", [0x00700243], ["TOP", "CENTER", "BOTTOM"])
        for table in ["table_C.10-5a", "table_C.10-5b"] { set(table, [0x00700244], ["NORMAL", "OUTLINED", "OFF"]) }
        set("table_C.10-5a", [0x00700248, 0x00700249, 0x00700250], ["Y", "N"])
        set("table_C.10-5b", [0x00700254], ["SOLID", "DASHED"])
        set("table_C.10-5c", [0x00700257], ["SOLID", "STIPPELED"])
        set("C.10.6", [0x00700041], ["Y", "N"])
        set("C.11.9", [0x00080060], ["PR"])
        set("C.11.6", [0x20500020], ["IDENTITY", "INVERSE"])
        set("C.11.13", [0x00281090], ["SUB"])
        set("C.11.14", [0x00700405], ["SUPERIMPOSED", "UNDERLYING"])
        set("C.7.6.15", [0x00181600], ["BITMAP"])
        // RT Dose, Structure Set and Plan (C.8.8, C.36).
        set("C.7.6.6", [0x00220028], yesNo)
        set("C.8.8.4", [0x30040062], ["INCLUDED", "EXCLUDED"])
        set("C.8.8.4", [0x30040001], ["DIFFERENTIAL", "CUMULATIVE", "NATURAL"])
        set("C.8.8.4", [0x30040002], ["GY", "RELATIVE"])
        set("C.8.8.3", [0x30040002], ["GY", "RELATIVE", "CODED"])
        set("C.8.8.3", [0x30040014], ["IMAGE", "ROI_OVERRIDE", "WATER"])
        set("C.8.8.3", [0x30040084], ["DOSE_TO_WATER", "DOSE_TO_MEDIUM"])
        set("C.8.8.16", [0x300E0002], ["APPROVED", "UNAPPROVED", "REJECTED"])
        set("C.8.8.6", [0x30060042], ["POINT", "OPEN_PLANAR", "OPEN_NONPLANAR", "CLOSED_PLANAR", "CLOSEDPLANAR_XOR"])
        set("C.8.8.14", [0x300A00C4], ["STATIC", "DYNAMIC"])
        set("C.8.8.14", [0x30020051], ["STANDARD", "NON_STANDARD"])
        set("C.8.8.14", [0x300A00B3], ["MU", "MINUTE"])
        set("C.8.8.14", [0x300800A3, 0x300A0093], yesNo)
        for table in ["C.8.8.14", "C.8.8.11"] { set(table, [0x300A00B8], ["X", "Y", "ASYMX", "ASYMY", "MLCX", "MLCY"]) }
        set("C.8.8.14", [0x3002000C], ["NORMAL", "NON_NORMAL"])
        set("C.8.8.14", [0x300A02E0, 0x300A00FA], ["PRESENT", "ABSENT"])
        set("C.8.8.14", [0x300A02E1], ["PATIENT_SIDE", "SOURCE_SIDE", "DOUBLE_SIDED"])
        set("C.8.8.14", [0x300A00FB], ["PATIENT_SIDE", "SOURCE_SIDE"])
        set("C.8.8.14", [0x300A00F8], ["SHIELDING", "APERTURE"])
        set("C.8.8.14", [0x300A0118], ["IN", "OUT"])
        set("C.8.8.14", [0x300A011F, 0x300A014C, 0x300A0121, 0x300A0123, 0x300A0126, 0x300A0142, 0x300A0146], ["CW", "CC", "NONE"])
        set("C.8.8.15", [0x300A0200], ["INTRALUMENARY", "INTRACAVITARY", "INTERSTITIAL", "CONTACT", "INTRAVASCULAR", "PERMANENT"])
        set("C.8.8.15", [0x300A0229], ["AIR_KERMA_RATE", "DOSE_RATE_WATER"])
        set("C.8.8.13", [0x300A008B], ["BEAM_LEVEL", "FRACTION_LEVEL"])
        set("C.8.8.13", [0x300A0090, 0x300A0092], ["PHYSICAL", "EFFECTIVE"])
        set("C.8.8.13", [0x300C0123], yesNo)
        set("C.8.8.10", [0x300A068B], ["NOMINAL", "ACTUAL"])
        set("table_C.36.2.1.5-1", [0x30100002], yesNo)
        set("table_C.36.2.5.1-1", [0x30040082], ["NOT_COMMISSIONED", "COMMISSIONED"])
        set("table_C.17-3b", [0x0040A084], ["PSN", "DEV"])
        set("table_C.36.2.2.19-1", [0x300A064E], ["BINARY", "VARIABLE"])
        set("table_C.36.2.2.19-1", [0x300A064F], ["P", "N"])
        set("table_10.38-1", [0x00181630], ["RECTANGULAR", "CIRCULAR", "POLYGONAL"])
        // Waveforms (C.10.9, C.10.10, C.10.12) and encapsulated documents (C.24.2, C.35.1).
        set("C.10.9", [0x003A0004], ["ORIGINAL", "DERIVED"])
        set("C.10.9", [0x003A0317], ["AC", "DC"])
        set("C.10.9", [0x003A0246], ["NONE", "BASELINE", "ABSOLUTE", "DIFFERENCE"])
        set("C.10.9", [0x54001006], ["SB", "UB", "MB", "AB", "SS", "US", "SL", "UL", "SV", "UV", "FD"])
        set("table_C.10.12-1", [0x003A0322], ["ANALOG", "DIGITAL"])
        set("C.8.12.3", [0x00080060], ["SM"])
        set("C.8.12.4", [0x00280004], ["MONOCHROME2", "RGB", "YBR_FULL_422", "YBR_ICT", "YBR_RCT"])
        set("C.8.12.4", [0x00282110], ["00", "01"])
        set("C.8.12.4", [0x20500020], ["IDENTITY"])
        set("C.8.12.4", [0x00089206], ["VOLUME"])
        set("C.8.12.4", [0x00480010, 0x00280301, 0x00480012], yesNo)
        set("C.8.12.4", [0x00480011], ["AUTO", "MANUAL"])
        set("C.24.2", [0x00200062], ["R", "L", "U", "B"])
        set("C.24.2", [0x00280301, 0x00280302], yesNo)
        set("C.24.2", [0x0040A493], ["UNVERIFIED", "VERIFIED"])
        set("C.35.1", [0x00687001, 0x00687002], yesNo)
        return map
    }()

    // MARK: - IOD usage clauses (PS3.3 A.38-1, A.36-2, A.47-2)

    /// Whether a conditional module of the IOD is required; `declared` is true when any of its
    /// top-level attributes is present. "Was applied" clauses are evidenced only by the module.
    static func moduleCondition(_ profile: DicomEnhancedImageModules.Profile, _ name: String, _ context: Context,
                                declared: Bool) -> (truth: T, mayBePresent: Bool) {
        let declaredOnly: T = declared ? .satisfied : .unsatisfied
        switch name {
        case "Slide Label" where profile == .vlWholeSlideMicroscopy: return (context.rootTruth(0x00080008, index: 2, in: ["LABEL"]), true)
        case "Enhanced Multi-energy CT Acquisition": return (context.multiEnergy, false)
        case "Supplemental Palette Color Lookup Table": return (context.rootTruth(0x00089205, in: ["COLOR", "MIXED"]), false)
        case "MR Pulse Sequence": return (context.imageOriginalOrMixed, true)
        case "XA/XRF Acquisition": return (context.imageOriginal, true)
        case "X-Ray Detector": return (context.rootTruth(0x00189420, in: ["DIGITAL_DETECTOR"]), false)
        case "X-Ray Image Intensifier": return (context.rootTruth(0x00189420, in: ["IMG_INTENSIFIER"]), false)
        // A.51/A.75: pixel modules follow the pixel attribute actually present; their tags overlap, so none is forbidden.
        case "Image Pixel" where profile == .parametricMap: return (context.hasIntegerPixelData, true)
        case "Floating Point Image Pixel": return (context.pixelDataTruth(.float), true)
        case "Double Floating Point Image Pixel": return (context.pixelDataTruth(.double), true)
        case "Palette Color Lookup Table":
            if profile == .segmentation || profile == .labelMapSegmentation { return (context.rootTruth(0x00280004, in: ["PALETTE COLOR"]), false) }
            return (Context.all(context.colorRange, negate(context.root.contains(0x00281199) ? .satisfied : .unsatisfied)), true)
        case "Microscope Slide Layer Tile Organization": return (negate(context.dimensionOrganizationNotTiledFull), true)
        default: return (declaredOnly, true)
        }
    }

    /// Whether a conditional functional group macro is required for the frame of the context.
    static func macroCondition(_ profile: DicomEnhancedImageModules.Profile, _ name: String, _ context: Context) -> (truth: T, mayBePresent: Bool) {
        switch profile {
        case .segmentation, .labelMapSegmentation: return segmentationMacroCondition(name, context)
        case .vlWholeSlideMicroscopy:
            switch name {
            case "Plane Position (Slide)", "Optical Path Identification": return (context.dimensionOrganizationNotTiledFull, true)
            case "Derivation Image": return (context.rootTruth(0x00080008, in: ["DERIVED"]), true)
            default: return (.unsatisfied, true)
            }
        case .parametricMap: return parametricMapMacroCondition(name, context)
        case .videoEndoscopic, .videoMicroscopic, .videoPhotographic, .surfaceSegmentation, .spatialRegistration, .deformableSpatialRegistration: return (.unsatisfied, true)
        case .enhancedCT, .enhancedMR, .enhancedXA: break
        }
        switch name {
        case "CT Acquisition Details", "CT Acquisition Type", "CT Exposure", "CT Geometry", "CT Position", "CT Table Dynamics",
             "CT X-Ray Details", "MR Averages", "MR Echo", "MR Imaging Modifier", "MR Modifier", "MR Receive Coil",
             "MR Timing and Related Parameters", "MR Transmit Coil":
            return (context.imageOriginalOrMixed, true)
        case "CT Reconstruction":
            let constantAngle = context.truth(context.macroValue("C.8.15.3.2", 0x00189302), in: ["CONSTANT_ANGLE"])
            return (Context.all(context.imageOriginalOrMixed, negate(constantAngle)), true)
        case "CT Additional X-Ray Source", "Multi-energy CT Processing", "Referenced Image":
            // Multiple sources, material processing and planning images are evidenced only by the macro.
            return (context.macroPresent(tableName(profile, name)) ? .satisfied : .unsatisfied, true)
        case "Cardiac Synchronization":
            return (Context.all(context.rootTechnique(0x00189037, isOtherThan: ["NONE"]), context.imageOriginalOrMixed), true)
        case "Respiratory Synchronization":
            return (Context.all(context.rootTechnique(0x00189170, isOtherThan: ["NONE", "REALTIME", "BREATH_HOLD"]), context.imageOriginalOrMixed), true)
        case "Contrast/Bolus Usage":
            return (context.root.contains(0x00180012) ? .satisfied : .unsatisfied, false)
        case "Derivation Image":
            // A frame derived from another SOP Instance is one whose Frame Type Value 1 is DERIVED.
            return (context.truth(context.frameType(0), in: ["DERIVED"]), false)
        case "Real World Value Mapping":
            return (context.multiEnergy, true)
        case "MR Arterial Spin Labeling":
            return (context.rootTruth(0x00080008, index: 2, in: ["ASL"]), true)
        case "MR Diffusion":
            return (Context.all(context.anyFrameMacroValue("C.8.13.5.1", 0x00089209, equals: "DIFFUSION"), context.imageOriginalOrMixed), true)
        case "MR FOV/Geometry":
            return (Context.all(context.rootTruth(0x00189032, in: ["RECTILINEAR"]), context.imageOriginalOrMixed), true)
        case "MR Metabolite Map":
            return (context.rootTruth(0x00080008, index: 2, in: ["METABOLITE_MAP"]), true)
        case "MR Spatial Saturation":
            return (Context.all(context.anyFrameMacroValue("C.8.13.5.5", 0x00189027, equals: "SLAB"), context.imageOriginalOrMixed), true)
        case "MR Velocity Encoding":
            return (Context.all(context.rootTruth(0x00189014, in: ["YES"]), context.imageOriginalOrMixed), true)
        case "Pixel Value Transformation":
            return (context.rootTruth(0x00280004, in: ["MONOCHROME2"]), false)
        case "Patient Orientation in Frame", "X-Ray Projection Pixel Calibration":
            return (context.rootTruth(0x00189474, in: ["YES"]), name == "Patient Orientation in Frame")
        case "Pixel Intensity Relationship LUT":
            return (context.truth(context.macroValue("C.8.19.6.4", 0x00281040), in: ["LOG"]), true)
        case "X-Ray Collimator":
            return (context.imageOriginal, true)
        case "X-Ray Field of View":
            return (context.macroPresent("C.8.19.6.13") ? .satisfied : .unsatisfied, true)
        case "X-Ray Frame Detector Parameters":
            return (context.rootTruth(0x00189420, in: ["DIGITAL_DETECTOR"]), false)
        case "X-Ray Geometry":
            return (context.macroPresent("C.8.19.6.9") ? .satisfied : .unsatisfied, true)
        case "X-Ray Positioner", "X-Ray Table Position":
            return (Context.all(context.imageOriginal, context.rootTruth(0x00189474, in: ["YES"])), true)
        default:
            return (.undetermined, true)
        }
    }

    /// Table A.51-2: geometry groups are required without Derivation Image in a patient-relative or slide
    /// Frame of Reference and permitted only within one; Derivation Image is required when they are absent.
    private static func segmentationMacroCondition(_ name: String, _ context: Context) -> (truth: T, mayBePresent: Bool) {
        let derivation: T = context.macroPresent("C.7.6.16.2.6") ? .satisfied : .unsatisfied
        let patient = context.frameOfReferencePatientRelative
        let slide = context.frameOfReferenceSlide
        switch name {
        case "Pixel Measures", "Plane Position (Patient)", "Plane Orientation (Patient)":
            return (Context.all(negate(derivation), patient), patient == .satisfied)
        case "Plane Position (Slide)":
            return (Context.all(Context.all(negate(derivation), slide), context.dimensionOrganizationNotTiledFull), slide == .satisfied)
        case "Derivation Image":
            let geometry: Bool
            if slide == .satisfied {
                geometry = context.macroPresent("C.7.6.16.2.1") && context.macroPresent("C.8.12.6.1")
            } else {
                geometry = context.macroPresent("C.7.6.16.2.1") && context.macroPresent("C.7.6.16.2.3") && context.macroPresent("C.7.6.16.2.4")
            }
            return (patient == .satisfied || slide == .satisfied ? (geometry ? .unsatisfied : .satisfied) : .satisfied, true)
        case "Frame Content":
            // "Required if not empty": the group evidences its own content.
            return (.unsatisfied, true)
        case "Segmentation":
            if context.rootValue(0x00620001) == "LABELMAP" { return (.unsatisfied, false) }
            return (context.dimensionOrganizationNotTiledFull, true)
        default:
            return (.undetermined, true)
        }
    }

    /// Table A.75-2.
    private static func parametricMapMacroCondition(_ name: String, _ context: Context) -> (truth: T, mayBePresent: Bool) {
        switch name {
        case "Plane Position (Patient)", "Plane Orientation (Patient)":
            return (context.frameOfReferencePatientRelative, true)
        case "Plane Position (Slide)":
            return (Context.all(context.frameOfReferenceSlide, context.dimensionOrganizationNotTiledFull), context.frameOfReferenceSlide == .satisfied)
        case "Derivation Image":
            return (context.truth(context.frameType(0), in: ["DERIVED"]), false)
        case "Stored Value Color Range":
            return (context.colorRange, false)
        default:
            return (.undetermined, true)
        }
    }

    // MARK: - Softcopy Presentation State usage clauses (PS3.3 A.33.1-1 to A.33.4-1)

    /// Whether a conditional module of a Presentation State IOD is required. Modules whose condition is
    /// "to be applied to the referenced images" are evidenced only by their own presence.
    static func presentationModuleCondition(_ profile: DicomPresentationStateModules.Profile, _ name: String,
                                            _ dataSet: DicomDataSet, declared: Bool) -> (truth: T, mayBePresent: Bool) {
        let declaredOnly: T = declared ? .satisfied : .unsatisfied
        switch name {
        case "Graphic Layer":
            // Required with Graphic Annotations, and for the image IODs also with overlays or their activation.
            let overlays = profile != .blending && DicomPresentationStateModules.overlayGroups(in: dataSet, includingActivation: true).isEmpty == false
            return (dataSet.contains(0x00700001) || overlays ? .satisfied : .unsatisfied, true)
        default:
            return (declaredOnly, true)
        }
    }

    // MARK: - Waveform and encapsulated document usage clauses (PS3.3 A.34, A.45)

    /// A.34: Synchronization is required for an ORIGINAL hemodynamic or electrophysiology waveform; the
    /// annotation module is evidenced by its own presence. A.45: Common Instance Reference is evidenced by its references.
    static func waveformModuleCondition(_ name: String, _ context: Context, declared: Bool) -> (truth: T, mayBePresent: Bool) {
        switch name {
        case "Synchronization": return (context.anyWaveformOriginal, true)
        default: return (declared ? .satisfied : .unsatisfied, true)
        }
    }

    // MARK: - RT IOD usage clauses (PS3.3 A.18-1, A.19-1, A.20-1)

    /// Whether a conditional module of an RT IOD is required. Grid-based doses are evidenced by Pixel Data;
    /// the beam and brachy modules follow the fraction groups and exclude each other.
    static func rtModuleCondition(_ profile: DicomRTModules.Profile, _ name: String, _ context: Context,
                                  declared: Bool) -> (truth: T, mayBePresent: Bool) {
        let declaredOnly: T = declared ? .satisfied : .unsatisfied
        switch name {
        case "Image Pixel": return (context.hasIntegerPixelData, true)
        case "Multi-frame":
            let frames = context.rootInt(0x00280008) ?? 1
            return (Context.all(context.hasIntegerPixelData, frames > 1 ? .satisfied : .unsatisfied), true)
        case "RT Beams":
            if DicomRTModules.declaresBrachy(context.root) { return (.unsatisfied, false) }
            return (DicomRTModules.fractionGroupsRequire(context.root, countTag: 0x300A0080) ? .satisfied : .unsatisfied, true)
        case "RT Brachy Application Setups":
            if context.root.contains(0x300A00B0) { return (.unsatisfied, false) }
            return (DicomRTModules.fractionGroupsRequire(context.root, countTag: 0x300A00A0) ? .satisfied : .unsatisfied, true)
        default: return (declaredOnly, true)
        }
    }

    private static func tableName(_ profile: DicomEnhancedImageModules.Profile, _ macro: String) -> String {
        DicomEnhancedImageTables.iods[profile.key]?.groupMacros.first { $0.name == macro }?.table ?? ""
    }
}
