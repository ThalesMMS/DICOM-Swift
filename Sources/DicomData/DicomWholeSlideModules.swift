import Foundation

/// PS3.3 2026c A.32.8, C.8.12 and C.7.6.17.3 constraints beyond the generated tables.
enum DicomWholeSlideModules {
    private static func specimenRules(_ data: DicomDataSet) -> [DicomAttributeRule] {
        DicomSpecimenModule.rules(for: data).map { rule in
            // C.7.6.22 permits an empty Type 2 Container Type Code Sequence. There is then
            // no coded value whose context-group membership needs to be established.
            guard rule.tag == 0x00400518, data.sequenceItems(for: rule.tag).isEmpty else { return rule }
            return .init(tag: rule.tag, requirement: rule.requirement, itemRules: rule.itemRules,
                         constraints: [.itemCount(0...1)])
        }
    }

    static func validate(_ data: DicomDataSet, state: inout DicomEnhancedImageModules.State) {
        let type = data.strings(for: 0x00080008)
        let flavor = type.count > 2 ? type[2] : ""
        let full = data.string(for: 0x00209311) == "TILED_FULL"
        let paths = data.sequenceItems(for: 0x00480105)
        let shared = data.sequenceItems(for: 0x52009229).first?.dataSet ?? .init(elements: [])
        let frames = data.sequenceItems(for: 0x52009230)
        let count = data.int(for: 0x00280008) ?? 0
        let monochrome = data.string(for: 0x00280004) == "MONOCHROME2"
        state.evaluate([
            .init(tag: 0x00080008, requirement: .type1, constraints: [.valueCount(4...4)]),
            .init(tag: 0x00280100, requirement: .type1, constraints: [.integers([8, 16])]),
            .init(tag: 0x00280101, requirement: .type1, constraints: [.integerEqualsAttribute(0x00280100, offset: 0)]),
            .init(tag: 0x00280102, requirement: .type1, constraints: [.integerEqualsAttribute(0x00280101, offset: -1)]),
            .init(tag: 0x00280103, requirement: .type1, constraints: [.integers([0])]),
            .init(tag: 0x00280002, requirement: .type1, constraints: [.integers([monochrome ? 1 : 3])]),
            .init(tag: 0x00280006, requirement: .type1C, condition: .known(monochrome ? .unsatisfied : .satisfied), constraints: [.integers([0])]),
            .init(tag: 0x00480006, requirement: .type1, constraints: [.integerRange(1...Int.max)]),
            .init(tag: 0x00480007, requirement: .type1, constraints: [.integerRange(1...Int.max)]),
            .init(tag: 0x00480303, requirement: .type1C, condition: .known(full ? .satisfied : .unsatisfied),
                  mayBePresentOtherwise: true, constraints: [.integerRange(1...Int.max)]),
            .init(tag: 0x00480013, requirement: .type1C, condition: .stringEquals(0x00480012, "YES"), constraints: [.integerRange(1...Int.max)]),
            .init(tag: 0x00480102, requirement: .type1, constraints: [.valueCount(6...6)]),
            .init(tag: 0x00480010, requirement: .type1, constraints: [.strings([flavor == "LABEL" || flavor == "OVERVIEW" ? "YES" : "NO"])]),
            .init(tag: 0x00200052, requirement: .type1C, condition: .known(["VOLUME", "THUMBNAIL"].contains(flavor) ? .satisfied : .unsatisfied), mayBePresentOtherwise: true)
        ] + specimenRules(data), on: data, path: [])
        if type.count == 4 && (!Set(["ORIGINAL", "DERIVED"]).contains(type[0]) || type[1] != "PRIMARY" ||
            !Set(["VOLUME", "LABEL", "OVERVIEW", "THUMBNAIL"]).contains(type[2]) || !Set(["NONE", "RESAMPLED"]).contains(type[3])) {
            state.record(.attributeValueNotAllowed, path: [.tag(0x00080008)])
        }
        if flavor != "VOLUME", count != 1 { state.record(.attributeValueContradiction, path: [.tag(0x00280008)]) }
        if let depth = data.floats(for: 0x00480003).first, !depth.isFinite || depth == 0 {
            state.record(.attributeValueNotAllowed, path: [.tag(0x00480003)])
        }
        if data.contains(0x00080019), !["VOLUME", "THUMBNAIL"].contains(flavor) {
            state.record(.conditionalAttributeForbidden, path: [.tag(0x00080019)])
        }
        if monochrome {
            for (tag, value) in [(0x00281052, 0.0), (0x00281053, 1.0)] where data.decimalStrings(for: tag) != [value] {
                state.record(.attributeValueNotAllowed, path: [.tag(tag)])
            }
        }
        let sharedPath: [DicomValidationReport.PathComponent] = [.tag(0x52009229), .item(0)]
        for tag in [0x00289110, 0x00400710] {
            if !shared.contains(tag) { state.record(.requiredAttributeMissing, path: sharedPath + [.tag(tag)]) }
            for (index, item) in frames.enumerated() where item.dataSet.contains(tag) {
                state.record(.conditionalAttributeForbidden, path: [.tag(0x52009230), .item(index), .tag(tag)])
            }
        }
        if shared.sequenceItems(for: 0x00400710).first?.dataSet.strings(for: 0x00089007) != type {
            state.record(.attributeValueContradiction, path: sharedPath + [.tag(0x00400710), .item(0), .tag(0x00089007)])
        }
        // A.32.8.4: absence of per-frame groups does not waive a required derivation macro.
        if type.first == "DERIVED", !shared.contains(0x00089124),
           frames.count != count || frames.contains(where: { !$0.dataSet.contains(0x00089124) }) {
            state.record(.requiredAttributeMissing, path: sharedPath + [.tag(0x00089124)])
        }
        let groups = [(shared, sharedPath)] + frames.enumerated().map { ($0.element.dataSet, [.tag(0x52009230), .item($0.offset)]) }
        var identifiers = Set<String>()
        for (index, item) in paths.enumerated() {
            guard !state.stopped else { return }
            let path: [DicomValidationReport.PathComponent] = [.tag(0x00480105), .item(index)]
            if DicomICCProfileModule.applies(to: item.dataSet) {
                let report = DicomICCProfileModule.validate(item.dataSet, limits: state.limits(remaining: state.remaining))
                state.merge(report.diagnostics.map { .init(code: $0.code, severity: $0.severity, layer: $0.layer,
                    path: path + $0.path, requirement: $0.requirement) })
            }
            if let id = item.dataSet.string(for: 0x00480106), !identifiers.insert(id).inserted {
                state.record(.attributeValueContradiction, path: path + [.tag(0x00480106)])
            }
            // Presence and structural ICC checks; applying the profile is outside this toolkit.
            let needed = !monochrome || item.dataSet.contains(0x00480120)
            state.evaluate([.init(tag: 0x00282000, requirement: .type1C,
                condition: .known(needed ? .satisfied : .unsatisfied), mayBePresentOtherwise: true)], on: item.dataSet, path: path)
        }
        for (group, path) in groups {
            if !monochrome, group.contains(0x00409096) { state.record(.conditionalAttributeForbidden, path: path + [.tag(0x00409096)]) }
            for (itemIndex, item) in group.sequenceItems(for: 0x00480207).enumerated() {
                if let id = item.dataSet.string(for: 0x00480106), !identifiers.contains(id) {
                    state.record(.attributeValueContradiction, path: path + [.tag(0x00480207), .item(itemIndex), .tag(0x00480106)])
                }
            }
        }
        if let declared = data.int(for: 0x00480302), declared != paths.count {
            state.record(.attributeValueContradiction, path: [.tag(0x00480302)])
        }
        let cols = data.int(for: 0x00480006) ?? 0, rows = data.int(for: 0x00480007) ?? 0
        let tileCols = data.int(for: 0x00280011) ?? 0, tileRows = data.int(for: 0x00280010) ?? 0
        guard cols > 0, rows > 0, tileCols > 0, tileRows > 0 else { return }
        if full {
            if let overlap = data.string(for: 0x00480304), overlap != "NONE" {
                state.record(.attributeValueContradiction, path: [.tag(0x00480304)])
            }
            var expected = 1
            for factor in [(cols - 1) / tileCols + 1, (rows - 1) / tileRows + 1,
                           data.int(for: 0x00480303) ?? 0, paths.count] {
                let product = expected.multipliedReportingOverflow(by: factor)
                if product.overflow { state.record(.attributeValueContradiction, path: [.tag(0x00280008)]); return }
                expected = product.partialValue
            }
            let offset = data.int(for: 0x00209228) ?? 0
            if flavor == "VOLUME" && (count <= 0 || offset < 0 || offset > expected || count > expected - offset ||
                (!data.contains(0x00209161) && count != expected)) {
                state.record(.attributeValueContradiction, path: [.tag(0x00280008)])
            }
        } else if frames.count != count {
            state.record(.requiredAttributeMissing, path: [.tag(0x52009230)])
        }
        var gridOffset: (Int, Int)?
        for (index, item) in frames.enumerated() {
            let path: [DicomValidationReport.PathComponent] = [.tag(0x52009230), .item(index)]
            if !full {
                for tag in [0x0048021A, 0x00480207] where !item.dataSet.contains(tag) {
                    state.record(.requiredAttributeMissing, path: path + [.tag(tag)])
                }
            }
            guard let pos = (item.dataSet[0x0048021A] ?? shared[0x0048021A])?.sequenceItems.first?.dataSet,
                  let col = pos.int(for: 0x0048021E), let row = pos.int(for: 0x0048021F) else { continue }
            if col < 1 || col > cols || row < 1 || row > rows {
                state.record(.attributeValueContradiction, path: path + [.tag(0x0048021A)])
            }
            let remainder = (col % tileCols, row % tileRows)
            if let gridOffset, remainder != gridOffset { state.record(.attributeValueContradiction, path: path + [.tag(0x0048021A)]) }
            gridOffset = remainder
        }
    }
}
