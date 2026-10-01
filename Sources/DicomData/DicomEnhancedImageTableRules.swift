import Foundation

/// Builds attribute rules from the generated PS3.3 2026c rows of the Enhanced CT/MR/XA tables.
/// Conditions, "may be present otherwise" readings and value constraints come from the curated
/// `DicomEnhancedImageConditions`; a conditional attribute without a curated condition stays
/// undetermined, so it is reported as a limitation and never silently approved.
enum DicomEnhancedImageTableRules {
    typealias Row = DicomEnhancedImageTables.Row

    /// Where a rule is evaluated: the instance root, the shared functional group item or one
    /// per-frame item. Frame-level facts resolve from the frame, then the shared group, then the
    /// per-frame groups when every frame agrees.
    struct Context {
        let root: DicomDataSet
        let sopClassUID: String
        let shared: DicomDataSet?
        let frame: DicomDataSet?
        let frames: [DicomDataSet]
        let facts: DicomCompositeImageModules.Conditions
        /// Which pixel attribute the original bytes carry; the wire pass omits its value from the data set.
        let pixelData: DicomEnhancedImageModules.PixelData

        init(root: DicomDataSet, sopClassUID: String, shared: DicomDataSet?, frame: DicomDataSet?,
             frames: [DicomDataSet], facts: DicomCompositeImageModules.Conditions,
             pixelData: DicomEnhancedImageModules.PixelData = .integer) {
            self.root = root
            self.sopClassUID = sopClassUID
            self.shared = shared
            self.frame = frame
            self.frames = frames
            self.facts = facts
            self.pixelData = pixelData
        }

        func withFrame(_ frame: DicomDataSet?) -> Context {
            .init(root: root, sopClassUID: sopClassUID, shared: shared, frame: frame, frames: frames, facts: facts, pixelData: pixelData)
        }

        var isSegmentation: Bool { sopClassUID == "1.2.840.10008.5.1.4.1.1.66.4" }
        var isPresentationState: Bool { DicomPresentationStateModules.Profile(rawValue: sopClassUID) != nil }
        /// C.10.4: whether any image of the Presentation State Relationship module is a tiled (whole slide) instance.
        var referencesTiledInstance: DicomAttributeRule.Truth {
            let images = (root[0x00081115]?.sequenceItems ?? []).flatMap { $0.dataSet[0x00081140]?.sequenceItems ?? [] }
            return images.contains { Self.trimmed($0.dataSet[0x00081150], index: 0) == "1.2.840.10008.5.1.4.1.1.77.1.6" } ? .satisfied : .unsatisfied
        }
        var isParametricMap: Bool { sopClassUID == "1.2.840.10008.5.1.4.1.1.30" }
        var hasIntegerPixelData: DicomAttributeRule.Truth { pixelDataTruth(.integer) }
        var hasFloatingPixelData: DicomAttributeRule.Truth { Self.any(pixelDataTruth(.float), pixelDataTruth(.double)) }

        func pixelDataTruth(_ kind: DicomEnhancedImageModules.PixelData) -> DicomAttributeRule.Truth {
            pixelData == .undetermined ? .undetermined : pixelData == kind ? .satisfied : .unsatisfied
        }

        /// A.51.5.1/A.75: whether the Frame of Reference is patient-relative; slide coordinates are
        /// evidenced by the Microscope Slide Layer Tile Organization module or a Plane Position (Slide) group.
        var slideCoordinates: Bool {
            root.contains(0x00480006) || root.contains(0x00480102) || macroPresentAnywhere("C.8.12.6.1")
        }
        var frameOfReferencePatientRelative: DicomAttributeRule.Truth {
            root.contains(0x00200052) && !slideCoordinates ? .satisfied : .unsatisfied
        }
        var frameOfReferenceSlide: DicomAttributeRule.Truth {
            root.contains(0x00200052) && slideCoordinates ? .satisfied : .unsatisfied
        }
        /// Presence of a macro in the shared group or any frame, independent of the context frame.
        func macroPresentAnywhere(_ table: String) -> Bool {
            guard let macro = Self.macroTag(table) else { return false }
            return shared?.contains(macro) == true || frames.contains { $0.contains(macro) }
        }
        /// C.8.32.2: Pixel Presentation is Type 3; its absence means MONOCHROME.
        var colorRange: DicomAttributeRule.Truth { rootValue(0x00089205) == "COLOR_RANGE" ? .satisfied : .unsatisfied }
        var isRTObject: Bool { DicomRTModules.Profile(rawValue: sopClassUID) != nil }
        var encapsulatedDocumentProfile: DicomEncapsulatedDocumentModules.Profile? { .init(rawValue: sopClassUID) }
        /// C.10.9: whether any multiplex group declares an ORIGINAL waveform.
        var anyWaveformOriginal: DicomAttributeRule.Truth {
            (root[0x54000100]?.sequenceItems ?? []).contains { Self.trimmed($0.dataSet[0x003A0004], index: 0) == "ORIGINAL" } ? .satisfied : .unsatisfied
        }
        /// C.7.6.6: whether Frame Increment Pointer names the attribute.
        func frameIncrementPointsTo(_ tag: Int) -> DicomAttributeRule.Truth {
            guard let element = root[0x00280009], element.vr == .AT, case .unsignedIntegers(let values) = element.value else { return .unsatisfied }
            return values.contains(UInt(tag)) ? .satisfied : .unsatisfied
        }
        /// C.8.8.3: whether an RT Dose Interpreted Type Code Modifier carries the DCM code.
        func doseModifierContains(_ code: String) -> DicomAttributeRule.Truth {
            let modifiers = (root[0x30040021]?.sequenceItems ?? []).flatMap { $0.dataSet[0x30040022]?.sequenceItems ?? [] }
            return modifiers.contains { Self.trimmed($0.dataSet[0x00080100], index: 0) == code && Self.trimmed($0.dataSet[0x00080102], index: 0) == "DCM" }
                ? .satisfied : .unsatisfied
        }

        static func trimmed(_ element: DicomDataElement?, index: Int) -> String? {
            guard let element, element.vr != .UN, case .strings(let values) = element.value, index < values.count else { return nil }
            let value = values[index].trimmingCharacters(in: CharacterSet(charactersIn: " "))
            return value.isEmpty ? nil : value
        }

        func rootValue(_ tag: Int, index: Int = 0) -> String? { Self.trimmed(root[tag], index: index) }

        func rootInt(_ tag: Int) -> Int? {
            guard let element = root[tag], element.vm.count == 1 else { return nil }
            return element.intValue
        }

        /// The sequence attribute that starts a generated table.
        static func macroTag(_ table: String) -> Int? {
            DicomEnhancedImageTables.tables[table]?.first { $0.include == nil && $0.depth == 0 }?.tag
        }

        private static func value(_ item: DicomDataSet?, macro: Int, tag: Int, index: Int) -> String?? {
            guard let item, item.contains(macro) else { return nil }
            return .some(trimmed(item[macro]?.sequenceItems.first?.dataSet[tag], index: index))
        }

        /// Value of an attribute inside a functional group macro item for this frame.
        func macroValue(_ table: String, _ tag: Int, index: Int = 0) -> String? {
            guard let macro = Self.macroTag(table) else { return nil }
            if let found = Self.value(frame, macro: macro, tag: tag, index: index) { return found }
            if let found = Self.value(shared, macro: macro, tag: tag, index: index) { return found }
            guard frame == nil, !frames.isEmpty else { return nil }
            let values = Set(frames.map { item -> String? in Self.value(item, macro: macro, tag: tag, index: index).flatMap { $0 } })
            return values.count == 1 ? values.first.flatMap { $0 } : nil
        }

        /// Whether the macro is present for this frame (or anywhere, at the root level).
        func macroPresent(_ table: String) -> Bool {
            guard let macro = Self.macroTag(table) else { return false }
            if let frame { return frame.contains(macro) || shared?.contains(macro) == true }
            return shared?.contains(macro) == true || frames.contains { $0.contains(macro) }
        }

        /// A value that any frame (or the shared group) carries in the macro attribute.
        func anyFrameMacroValue(_ table: String, _ tag: Int, index: Int = 0, equals expected: String) -> DicomAttributeRule.Truth {
            guard let macro = Self.macroTag(table), macroPresent(table) else { return .unsatisfied }
            let items = (shared.map { [$0] } ?? []) + frames
            var undetermined = false
            for item in items where item.contains(macro) {
                guard let value = Self.trimmed(item[macro]?.sequenceItems.first?.dataSet[tag], index: index) else { undetermined = true; continue }
                if value == expected { return .satisfied }
            }
            return undetermined ? .undetermined : .unsatisfied
        }

        func truth(_ value: String?, in values: Set<String>) -> DicomAttributeRule.Truth {
            value.map { values.contains($0) ? .satisfied : .unsatisfied } ?? .undetermined
        }

        func rootTruth(_ tag: Int, index: Int = 0, in values: Set<String>) -> DicomAttributeRule.Truth {
            truth(rootValue(tag, index: index), in: values)
        }

        /// Synchronization techniques are declared only when applied; an absent technique reads as NONE.
        func rootTechnique(_ tag: Int, isOtherThan excluded: Set<String>) -> DicomAttributeRule.Truth {
            excluded.contains(rootValue(tag) ?? "NONE") ? .unsatisfied : .satisfied
        }

        /// The functional group carrying Frame Type; Segmentation has none.
        var frameTypeTable: String {
            switch sopClassUID {
            case "1.2.840.10008.5.1.4.1.1.4.1": return "C.8.13.5.1"
            case "1.2.840.10008.5.1.4.1.1.12.1.1": return "C.8.19.6.4"
            case "1.2.840.10008.5.1.4.1.1.30": return "C.8.32.3.1"
            case "1.2.840.10008.5.1.4.1.1.66.4": return ""
            default: return "C.8.15.3.1"
            }
        }

        /// Segmentation frames carry no Frame Type; the root Image Type (DERIVED) stands for every frame.
        func frameType(_ index: Int) -> String? {
            frameTypeTable.isEmpty ? rootValue(0x00080008, index: index) : macroValue(frameTypeTable, 0x00089007, index: index)
        }
        var imageOriginal: DicomAttributeRule.Truth { rootTruth(0x00080008, in: ["ORIGINAL"]) }
        var imageOriginalOrMixed: DicomAttributeRule.Truth { rootTruth(0x00080008, in: ["ORIGINAL", "MIXED"]) }
        var frameOriginal: DicomAttributeRule.Truth { truth(frameType(0), in: ["ORIGINAL"]) }
        var frameOrImageOriginal: DicomAttributeRule.Truth { Self.any(frameOriginal, imageOriginal) }
        /// C.8.15.2: Multi-energy CT Acquisition is Type 3, so its absence means NO.
        var multiEnergy: DicomAttributeRule.Truth { rootValue(0x00189361) == "YES" ? .satisfied : .unsatisfied }
        var dimensionOrganizationNotTiledFull: DicomAttributeRule.Truth { rootValue(0x00209311) == "TILED_FULL" ? .unsatisfied : .satisfied }
        /// Volumetric Properties is carried by the image module root and by the frame type macro.
        var volumetricProperties: String? { rootValue(0x00089206) ?? macroValue(frameTypeTable, 0x00089206) }

        /// Whether the Dimension Index Sequence points at the attribute.
        func dimensionIndexed(_ tag: Int) -> DicomAttributeRule.Truth {
            let pointers = (root[0x00209222]?.sequenceItems ?? []).compactMap { item -> Int? in
                guard let element = item.dataSet[0x00209165], element.vr == .AT,
                      case .unsignedIntegers(let values) = element.value, values.count == 1 else { return nil }
                return Int(values[0])
            }
            return pointers.contains(tag) ? .satisfied : .unsatisfied
        }

        /// C.7.6.16.2.12: whether every contrast agent of the Enhanced Contrast/Bolus module uses an intravenous route.
        var intravenousContrast: DicomAttributeRule.Truth {
            let agents = root[0x00180012]?.sequenceItems ?? []
            guard !agents.isEmpty else { return .unsatisfied }
            var results = Set<Bool>()
            for agent in agents {
                let routes = agent.dataSet[0x00180014]?.sequenceItems ?? []
                guard !routes.isEmpty else { return .undetermined }
                results.insert(routes.contains { route in
                    Self.trimmed(route.dataSet[0x00080100], index: 0) == "47625008"
                        && Self.trimmed(route.dataSet[0x00080102], index: 0) == "SCT"
                })
            }
            return results.count == 1 ? (results.first == true ? .satisfied : .unsatisfied) : .undetermined
        }

        static func any(_ lhs: DicomAttributeRule.Truth, _ rhs: DicomAttributeRule.Truth) -> DicomAttributeRule.Truth {
            if lhs == .satisfied || rhs == .satisfied { return .satisfied }
            if lhs == .unsatisfied && rhs == .unsatisfied { return .unsatisfied }
            return .undetermined
        }

        static func all(_ lhs: DicomAttributeRule.Truth, _ rhs: DicomAttributeRule.Truth) -> DicomAttributeRule.Truth {
            if lhs == .unsatisfied || rhs == .unsatisfied { return .unsatisfied }
            if lhs == .satisfied && rhs == .satisfied { return .satisfied }
            return .undetermined
        }
    }

    static func rules(table: String, context: Context) -> [DicomAttributeRule] {
        guard let rows = DicomEnhancedImageTables.tables[table] else { return [] }
        var index = 0
        return build(rows, index: &index, depth: 0, table: table, context: context, visited: [table])
    }

    /// The tags a table defines at its top level, used to detect declared optional modules.
    static func topLevelTags(_ table: String) -> [Int] {
        (DicomEnhancedImageTables.tables[table] ?? []).flatMap { row -> [Int] in
            guard row.depth == 0 else { return [] }
            if let include = row.include { return includedTopLevelTags(include) }
            return [row.tag]
        }
    }

    private static func includedTopLevelTags(_ ref: String) -> [Int] {
        DicomEnhancedImageTables.tables[ref] == nil ? [] : topLevelTags(ref)
    }

    private static func build(_ rows: [Row], index: inout Int, depth: Int, table: String, context: Context,
                              visited: Set<String>) -> [DicomAttributeRule] {
        var rules: [DicomAttributeRule] = []
        while index < rows.count, rows[index].depth >= depth {
            let row = rows[index]
            index += 1
            guard row.depth == depth else { continue }
            if let include = row.include {
                rules += includedRules(include, context: context, visited: visited)
                continue
            }
            var itemRules: [DicomAttributeRule] = []
            if index < rows.count, rows[index].depth == depth + 1 {
                itemRules = build(rows, index: &index, depth: depth + 1, table: table, context: context, visited: visited)
            }
            // Pixel Data and its offset tables are verified against the original bytes by the native pixel validator.
            guard row.tag >> 16 != 0x7FE0 else { continue }
            rules.append(rule(for: row, table: table, itemRules: itemRules, context: context))
        }
        return rules
    }

    private static func rule(for row: Row, table: String, itemRules: [DicomAttributeRule], context: Context) -> DicomAttributeRule {
        let requirement = DicomAttributeRule.Requirement(rawValue: row.type) ?? .type3
        let key = DicomEnhancedImageConditions.key(table, row.tag)
        var condition: DicomAttributeRule.Condition?
        if requirement == .type1C || requirement == .type2C {
            condition = DicomUltrasoundModules.condition(table: table, tag: row.tag, context: context)
                ?? DicomEnhancedImageConditions.condition(key, context) ?? .undetermined
        }
        var constraints: [DicomAttributeRule.Constraint] = []
        if let items = row.items { constraints.append(.itemCount(items)) }
        constraints += DicomEnhancedImageConditions.constraints(key, context)
        constraints += DicomUltrasoundModules.constraints(table: table, tag: row.tag)
        return .init(tag: row.tag, requirement: requirement, condition: condition,
                     mayBePresentOtherwise: row.mayBePresentOtherwise || DicomEnhancedImageConditions.mayBePresentOtherwise.contains(key),
                     itemRules: itemRules, constraints: constraints)
    }

    private static func includedRules(_ ref: String, context: Context, visited: Set<String>) -> [DicomAttributeRule] {
        switch ref {
        case "table_8.8-1", "table_8.8-1a", "table_8.8-1b": return DicomCodeSequenceMacro.standardRules()
        case "table_10-1": return DicomPersonIdentificationMacro.rules()
        case "table_10-9": return DicomCommonMacros.requestAttributes()
        case "table_10-17": return DicomCommonMacros.hl7HierarchicDesignator()
        // SR content items inside an encapsulated document are outside this composition; the composition reports them.
        case "table_C.17-5", "table_C.17-6": return []
        case "table_10-2", "table_10.2.1-1": return DicomCommonMacros.contentItem()
        case "table_10-3": return DicomCommonMacros.imageSOPInstanceReference()
        case "table_10-11": return DicomCommonMacros.sopInstanceReference()
        case "table_10-19": return DicomCommonMacros.algorithmIdentification()
        case "table_10-25": return DicomCommonMacros.viewCode()
        case "table_10.29-1": return DicomCommonMacros.udi()
        case "table_C.7.6.16-12b":
            return DicomCommonMacros.realWorldValueMapping(hasPixelData: context.hasIntegerPixelData,
                                                           hasFloatPixelData: context.hasFloatingPixelData)
        case "table_C.17-3": return DicomSRReferenceMacro.hierarchicalRules(codeRules: DicomCodeSequenceMacro.standardRules())
        case "table_C.36.2.4.12-1":
            // The optional cone-beam geometry rows are generated from their own table.
            return DicomCommonMacros.treatmentImagingRelations().filter { ![0x3002012E, 0x3002012F].contains($0.tag) }
        default:
            guard !visited.contains(ref), let rows = DicomEnhancedImageTables.tables[ref] else { return [] }
            var index = 0
            return build(rows, index: &index, depth: 0, table: ref, context: context, visited: visited.union([ref]))
        }
    }
}
