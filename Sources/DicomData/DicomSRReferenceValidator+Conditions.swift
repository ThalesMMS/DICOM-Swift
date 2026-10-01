import Foundation

extension DicomSRReferenceValidator.State {
    /// Optional target facts for a single primary content pair whose identity and SOP role have matched.
    /// Unusable geometry leaves the corresponding condition unknown; full target IOD validation is separate.
    mutating func deriveContentConditions(_ reference: DicomSRReferenceValidator.Reference, target: DicomDataSet) {
        guard !stopped, let path = reference.contentPath, case .content(let kind) = reference.role,
              let traits = DicomSOPReferenceTraits.entries[reference.sopClass] else { return }
        var facts = DicomContentReferenceMacro.Conditions()
        facts.isMultiframeImage = traits.isMultiframeImage
        facts.isSegmentation = traits.isSegmentation ? .satisfied : .unsatisfied
        facts.waveformHasMultipleChannels = .unsatisfied
        if kind == .image, facts.isMultiframeImage == .undetermined,
           knownCount(target[0x00280008], vr: .IS) != nil {
            // Presence of usable Number of Frames establishes the conditional Multi-frame module,
            // including a multi-frame container with one frame. Its absence proves neither alternative.
            facts.isMultiframeImage = .satisfied
        }
        if kind == .waveform {
            facts.waveformHasMultipleChannels = multipleWaveformChannels(target, path: reference.path)
        }
        // A stopped traversal cannot publish partially inferred target facts.
        if !stopped { contentReferenceConditions[path] = facts }
    }

    private mutating func multipleWaveformChannels(_ target: DicomDataSet,
                                                   path: [DicomValidationReport.PathComponent]) -> DicomAttributeRule.Truth {
        guard let groups = knownItems(target[0x54000100]), !groups.isEmpty else { return .undetermined }
        var channels = 0
        for group in groups {
            // Point at the source reference, not a fabricated source path containing target-only tags.
            guard visit(path, depth: 1) else { return .undetermined }
            guard let count = knownCount(group.dataSet[0x003A0005], vr: .US),
                  let definitions = knownItems(group.dataSet[0x003A0200]), definitions.count == count else { return .undetermined }
            channels = min(2, channels + count)
        }
        return channels > 1 ? .satisfied : .unsatisfied
    }

    private func knownItems(_ element: DicomDataElement?) -> [DicomSequenceItem]? {
        guard let element, element.vr == .SQ, case .sequence(let items) = element.value else { return nil }
        return items
    }

    func knownCount(_ element: DicomDataElement?, vr: DicomVR) -> Int? {
        guard let element, element.vr == vr else { return nil }
        switch element.value {
        case .strings(let values) where vr == .IS && values.count == 1 && values[0].utf8.count <= 12:
            guard (try? DicomTextValueValidator.validate(values[0], vr: .IS, characterSet: .defaultCharacterSet,
                purpose: .instance, includesPadding: false)) != nil,
                let count = Int(values[0].trimmingCharacters(in: .whitespaces)), count > 0 else { return nil }
            return count
        case .unsignedIntegers(let values) where vr == .US && values.count == 1 && (1...UInt(UInt16.max)).contains(values[0]):
            return Int(values[0])
        case .signedIntegers(let values) where vr == .US && values.count == 1 && (1...Int(UInt16.max)).contains(values[0]):
            return values[0]
        default: return nil
        }
    }
}
