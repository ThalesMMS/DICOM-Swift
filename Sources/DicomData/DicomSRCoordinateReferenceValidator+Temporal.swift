import Foundation

extension DicomSRCoordinateReferenceValidator.State {
    private struct MultiplexGroup {
        let instance: String
        let index: Int
        let uid: String?
        let dataSet: DicomDataSet
        let path: [DicomValidationReport.PathComponent]
    }

    mutating func validateTemporal(_ source: DicomSRRelationshipValidator.CoordinateSelection) {
        let path = source.path + [.tag(0x0040A132)]
        guard consume(path: path) else { return }
        let indices = source.path.compactMap { if case .item(let index) = $0 { return index }; return nil }
        checkedPaths.insert(indices)
        let previousDiagnostics = diagnostics.count
        defer {
            if diagnostics.dropFirst(previousDiagnostics).contains(where: { $0.severity == .error }) { failedPaths.insert(indices) }
        }
        var complete = source.isComplete
        var anyWaveform = false
        var hasNonWaveform = false
        var groups: [MultiplexGroup] = []
        var selections: [DicomSRRelationshipValidator.SelectedItem] = []
        for selected in source.targets {
            guard consume(path: selected.path) else { return }
            if DicomSRContentItemMacro.valueType(selected.dataSet) == "SCOORD" {
                guard let spatial = coordinateSelections[DicomSRCoordinateReferenceValidator.itemIndices(selected.path)] else { complete = false; continue }
                complete = complete && spatial.isComplete
                guard consume(spatial.targets.count, path: selected.path) else { return }
                selections += spatial.targets
            } else { selections.append(selected) }
        }
        var identitiesComplete = complete
        for selected in selections {
            guard consume(path: selected.path) else { return }
            let kind: DicomContentReferenceMacro.Kind = DicomSRContentItemMacro.valueType(selected.dataSet) == "WAVEFORM" ? .waveform : .image
            guard let matched = matchedTarget(selected, kind: kind) else { complete = false; identitiesComplete = false; continue }
            complete = complete && matched.selectionComplete
            if kind == .image { hasNonWaveform = true; continue }
            anyWaveform = true
            guard matched.selectionComplete, let resolved = selectedGroups(selected, target: matched.dataSet) else { complete = false; continue }
            groups += resolved
        }
        var facts = DicomTemporalCoordinatesMacro.Conditions()
        facts.referencesWaveform = anyWaveform ? .satisfied : identitiesComplete && hasNonWaveform ? .unsatisfied : .undetermined
        facts.channelsUseSingleMultiplexGroup = singleGroup(groups, complete: complete)
        if !stopped { temporalConditions[indices] = facts }
        guard source.source.contains(0x0040A132) else {
            let tag = source.source.contains(0x0040A138) ? 0x0040A138 : source.source.contains(0x0040A13A) ? 0x0040A13A : 0x0040A132
            record(.temporalAlignmentUnavailable, severity: .limitation, path: source.path + [.tag(tag)])
            return
        }
        if facts.channelsUseSingleMultiplexGroup == .unsatisfied {
            record(.attributeValueContradiction, path: path, requirement: .type1C)
        }
        if !complete || hasNonWaveform || facts.channelsUseSingleMultiplexGroup == .undetermined {
            record(.referenceTargetUnavailable, severity: .limitation, path: path)
        }
        guard !stopped, let element = source.source[0x0040A132], element.vr == .UL,
              case .unsignedIntegers(let samples) = element.value, !samples.isEmpty else {
            record(.valueUnavailable, severity: .limitation, path: path); return
        }
        guard consume(samples.count, path: path) else { return }
        if let invalid = DicomTemporalCoordinateValueValidator.validate(element, dataSet: source.source) {
            record(invalid.code, severity: invalid.severity, path: path, requirement: .type1C); return
        }
        for group in groups {
            guard let count = count(group.dataSet, tag: 0x003A0010, vr: .UL, path: group.path) else { continue }
            guard consume(samples.count, path: path) else { return }
            if samples.contains(where: { $0 > UInt(count) }) { record(.temporalCoordinateOutOfRange, path: path, requirement: .type1C) }
        }
    }

    private mutating func selectedGroups(_ selected: DicomSRRelationshipValidator.SelectedItem,
                                         target: DicomDataSet) -> [MultiplexGroup]? {
        let path = selected.path + [.tag(0x00081199), .item(0)]
        guard consume(path: path) else { return nil }
        guard let pair = selected.dataSet.sequenceItems(for: .referencedSOPSequence).first?.dataSet,
              let element = pair[0x0040A0B0], element.vr == .US,
              let instance = DicomSRReferenceMacro.uid(target, tag: 0x00080018),
              let sequence = target[0x54000100], sequence.vr == .SQ, case .sequence(let items) = sequence.value else {
            record(.valueUnavailable, severity: .limitation, path: path); return nil
        }
        guard consume(element.vm.count, path: path) else { return nil }
        let channels: [Int]
        switch element.value {
        case .unsignedIntegers(let values): channels = values.compactMap(Int.init(exactly:))
        case .signedIntegers(let values): channels = values
        default: record(.valueUnavailable, severity: .limitation, path: path); return nil
        }
        guard !channels.isEmpty, channels.count == element.vm.count, channels.count.isMultiple(of: 2) else {
            record(.referenceSelectionInvalid, path: path, layer: .references); return nil
        }
        var result: [MultiplexGroup] = []
        var seen: Set<Int> = []
        for offset in stride(from: 0, to: channels.count, by: 2) {
            guard consume(path: path) else { return nil }
            let index = channels[offset]
            guard index > 0, index <= items.count else { record(.referenceSelectionOutOfRange, path: path, layer: .references); return nil }
            if seen.insert(index).inserted {
                let group = items[index - 1].dataSet
                let uid = DicomSRReferenceMacro.uid(group, tag: 0x003A0310)
                if group.contains(0x003A0310) && uid == nil { record(.valueUnavailable, severity: .limitation, path: path) }
                result.append(.init(instance: instance, index: index, uid: uid, dataSet: group, path: path))
            }
        }
        return result
    }

    private mutating func singleGroup(_ groups: [MultiplexGroup], complete: Bool) -> DicomAttributeRule.Truth {
        guard !groups.isEmpty else { return .undetermined }
        var firstGroupByInstance: [String: Int] = [:]
        var declaredUIDs: Set<String> = []
        var allHaveUID = true
        var knownDifferent = false
        for group in groups {
            guard consume(path: group.path) else { return .undetermined }
            if let first = firstGroupByInstance[group.instance] {
                knownDifferent = knownDifferent || first != group.index
            } else {
                firstGroupByInstance[group.instance] = group.index
            }
            if let uid = group.uid { declaredUIDs.insert(uid) } else { allHaveUID = false }
        }
        knownDifferent = knownDifferent || declaredUIDs.count > 1
        let knownSame = complete && (firstGroupByInstance.count == 1 || (allHaveUID && declaredUIDs.count == 1))
        return knownDifferent ? .unsatisfied : knownSame ? .satisfied : .undetermined
    }
}
