import Foundation

/// Composition of the fifteen waveform IODs the toolkit offers (PS3.3 2026c A.34): the IOD modules
/// over the generated tables, the Synchronization usage of each IOD, the A.34.x.4 content constraints
/// (modality, multiplex group and channel counts, sample count, sampling frequency, sample
/// interpretation), the multiplex group coherence (channel definitions, sample word size, Waveform Data
/// length), the annotation channel references and the referenced instances against supplied targets.
public enum DicomWaveformModules {
    public enum Profile: String, Sendable, CaseIterable {
        case twelveLeadECG = "1.2.840.10008.5.1.4.1.1.9.1.1"
        case generalECG = "1.2.840.10008.5.1.4.1.1.9.1.2"
        case ambulatoryECG = "1.2.840.10008.5.1.4.1.1.9.1.3"
        case general32BitECG = "1.2.840.10008.5.1.4.1.1.9.1.4"
        case hemodynamic = "1.2.840.10008.5.1.4.1.1.9.2.1"
        case cardiacElectrophysiology = "1.2.840.10008.5.1.4.1.1.9.3.1"
        case basicVoiceAudio = "1.2.840.10008.5.1.4.1.1.9.4.1"
        case generalAudio = "1.2.840.10008.5.1.4.1.1.9.4.2"
        case arterialPulse = "1.2.840.10008.5.1.4.1.1.9.5.1"
        case respiratory = "1.2.840.10008.5.1.4.1.1.9.6.1"
        case multichannelRespiratory = "1.2.840.10008.5.1.4.1.1.9.6.2"
        case routineScalpEEG = "1.2.840.10008.5.1.4.1.1.9.7.1"
        case electromyogram = "1.2.840.10008.5.1.4.1.1.9.7.2"
        case electrooculogram = "1.2.840.10008.5.1.4.1.1.9.7.3"
        case sleepEEG = "1.2.840.10008.5.1.4.1.1.9.7.4"

        public var sopClassUID: String { rawValue }

        var key: String {
            switch self {
            case .twelveLeadECG: return "twelveLeadECG"
            case .generalECG: return "generalECG"
            case .ambulatoryECG: return "ambulatoryECG"
            case .general32BitECG: return "general32BitECG"
            case .hemodynamic: return "hemodynamic"
            case .cardiacElectrophysiology: return "cardiacElectrophysiology"
            case .basicVoiceAudio: return "basicVoiceAudio"
            case .generalAudio: return "generalAudio"
            case .arterialPulse: return "arterialPulse"
            case .respiratory: return "respiratory"
            case .multichannelRespiratory: return "multichannelRespiratory"
            case .routineScalpEEG: return "routineScalpEEG"
            case .electromyogram: return "electromyogram"
            case .electrooculogram: return "electrooculogram"
            case .sleepEEG: return "sleepEEG"
            }
        }

        /// A.34.x.4: the Modality value of the IOD.
        public var modality: String {
            switch self {
            case .twelveLeadECG, .generalECG, .ambulatoryECG, .general32BitECG: return "ECG"
            case .hemodynamic, .arterialPulse: return "HD"
            case .cardiacElectrophysiology: return "EPS"
            case .basicVoiceAudio, .generalAudio: return "AU"
            case .respiratory, .multichannelRespiratory: return "RESP"
            case .routineScalpEEG, .sleepEEG: return "EEG"
            case .electromyogram: return "EMG"
            case .electrooculogram: return "EOG"
            }
        }

        /// A.34.x.4 content constraints on the Waveform module.
        struct Constraints {
            var groups: ClosedRange<Int>? = nil
            var channels: ClosedRange<Int>? = nil
            var channelSet: Set<Int>? = nil
            var totalChannels: Int? = nil
            var samples: Int? = nil
            var frequency: ClosedRange<Double>? = nil
            var interpretations: Set<String>
        }

        var constraints: Constraints {
            switch self {
            case .twelveLeadECG:
                return .init(groups: 1...5, channels: 1...13, totalChannels: 13, samples: 16384, frequency: 200...1000, interpretations: ["SS"])
            case .generalECG:
                return .init(groups: 1...4, channels: 1...24, frequency: 200...1000, interpretations: ["SS"])
            case .ambulatoryECG:
                return .init(groups: 1...1, channels: 1...12, frequency: 50...1000, interpretations: ["SB", "SS"])
            case .general32BitECG:
                return .init(groups: 1...4, channels: 1...24, interpretations: ["SS", "SL"])
            case .hemodynamic:
                return .init(groups: 1...4, channels: 1...8, frequency: 0...400, interpretations: ["SS"])
            case .cardiacElectrophysiology:
                return .init(groups: 1...4, frequency: 0...20000, interpretations: ["SS"])
            case .basicVoiceAudio:
                return .init(groups: 1...1, channels: 1...2, frequency: 8000...8000, interpretations: ["UB", "MB", "AB"])
            case .generalAudio:
                return .init(groups: 1...1, channels: 1...2, frequency: 0...44100, interpretations: ["SB", "SS"])
            case .arterialPulse:
                return .init(groups: 1...1, channels: 1...1, frequency: 0...600, interpretations: ["SB", "SS"])
            case .respiratory:
                return .init(groups: 1...1, channels: 1...1, frequency: 0...100, interpretations: ["SB", "SS"])
            case .multichannelRespiratory:
                return .init(interpretations: ["SS", "SL"])
            case .routineScalpEEG:
                return .init(groups: 1...1, channels: 1...64, interpretations: ["SS", "SL"])
            case .electromyogram, .sleepEEG:
                return .init(channels: 1...64, interpretations: ["SS", "SL"])
            case .electrooculogram:
                return .init(channelSet: [2, 4], interpretations: ["SS", "SL"])
            }
        }
    }

    typealias Path = [DicomValidationReport.PathComponent]
    typealias State = DicomEnhancedImageModules.State

    static let handledElsewhere: Set<String> = [
        "Patient", "Clinical Trial Subject", "General Study", "Patient Study", "Clinical Trial Study", "General Series",
        "Clinical Trial Series", "General Equipment", "SOP Common"
    ]

    /// C.10.9.1.4: the sample word size of each Waveform Sample Interpretation.
    static let wordBits: [String: Int] = ["SB": 8, "UB": 8, "MB": 8, "AB": 8, "SS": 16, "US": 16, "SL": 32, "UL": 32, "SV": 64, "UV": 64, "FD": 64]

    public static func validate(_ dataSet: DicomDataSet, profile: Profile, targets: [String: DicomDataSet] = [:],
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        var state = State(limits: limits)
        guard let iod = DicomEnhancedImageTables.iods[profile.key] else {
            state.record(.moduleRuleUnavailable, path: [.tag(0x00080016)], severity: .limitation)
            return state.report
        }
        let context = DicomEnhancedImageTableRules.Context(root: dataSet, sopClassUID: profile.sopClassUID, shared: nil, frame: nil,
                                                            frames: [], facts: .init(), pixelData: .none)
        validateModules(dataSet, iod: iod, context: context, state: &state)
        guard !state.stopped else { return state.report }
        validateConstraints(dataSet, profile: profile, state: &state)
        guard !state.stopped else { return state.report }
        DicomReferenceTargetWalk.validate(dataSet, targets: targets, state: &state)
        return state.report
    }

    // MARK: - Modules

    private static func validateModules(_ dataSet: DicomDataSet, iod: DicomEnhancedImageTables.IOD,
                                        context: DicomEnhancedImageTableRules.Context, state: inout State) {
        for module in iod.modules where !handledElsewhere.contains(module.name) {
            guard !state.stopped else { return }
            // Synchronization keeps its hand-written rules; its usage differs per IOD.
            let synchronization = module.name == "Synchronization"
            let tags = synchronization ? [0x00200200] : DicomEnhancedImageTableRules.topLevelTags(module.table)
            let declared = synchronization ? DicomSynchronizationModule.applies(to: dataSet) : tags.contains(where: dataSet.contains)
            let rules = synchronization ? synchronizationRules(dataSet) : DicomEnhancedImageTableRules.rules(table: module.table, context: context)
            let requirement: (truth: DicomAttributeRule.Truth, mayBePresent: Bool)
            switch module.usage {
            case "M": requirement = (.satisfied, true)
            case "U": requirement = (declared ? .satisfied : .unsatisfied, true)
            default: requirement = DicomEnhancedImageConditions.waveformModuleCondition(module.name, context, declared: declared)
            }
            switch requirement.truth {
            case .satisfied:
                state.evaluate(rules, on: dataSet, path: [])
            case .unsatisfied:
                if declared { state.evaluate(rules, on: dataSet, path: []) }
            case .undetermined:
                if declared {
                    state.evaluate(rules, on: dataSet, path: [])
                } else if let tag = tags.first {
                    state.record(.conditionUndetermined, path: [.tag(tag)], severity: .limitation)
                }
            }
        }
    }

    /// C.7.4.2: Synchronization Channel is required when the trigger is encoded in a waveform of this instance,
    /// which the data set cannot settle unless there is no trigger at all.
    private static func synchronizationRules(_ dataSet: DicomDataSet) -> [DicomAttributeRule] {
        let trigger = DicomEnhancedImageTableRules.Context.trimmed(dataSet[0x0018106A], index: 0)
        return DicomSynchronizationModule.rules().map { rule in
            guard rule.tag == 0x0018106C else { return rule }
            return .init(tag: rule.tag, requirement: rule.requirement, condition: .known(trigger == "NO TRIGGER" ? .unsatisfied : .undetermined),
                         mayBePresentOtherwise: true, constraints: rule.constraints)
        }
    }

    // MARK: - A.34.x.4 constraints and multiplex group coherence

    private static func validateConstraints(_ dataSet: DicomDataSet, profile: Profile, state: inout State) {
        let trimmed = DicomEnhancedImageTableRules.Context.trimmed
        let constraints = profile.constraints
        state.evaluate([.init(tag: 0x00080060, requirement: .type1, constraints: [.strings([profile.modality])])], on: dataSet, path: [])
        let groups = dataSet[0x54000100]?.sequenceItems ?? []
        if let range = constraints.groups, !groups.isEmpty, !range.contains(groups.count) {
            state.record(.sequenceItemCountInvalid, path: [.tag(0x54000100)])
        }
        var total = 0
        var channelCounts: [Int] = []
        for (index, group) in groups.enumerated() {
            guard !state.stopped else { return }
            let path: Path = [.tag(0x54000100), .item(index)]
            let item = group.dataSet
            let channels = item[0x003A0005]?.intValue
            let definitions = item[0x003A0200]?.sequenceItems.count
            if let channels {
                total += channels
                channelCounts.append(channels)
                if let definitions, definitions != channels { state.record(.attributeValueContradiction, path: path + [.tag(0x003A0200)]) }
                if let range = constraints.channels, !range.contains(channels) { state.record(.attributeValueNotAllowed, path: path + [.tag(0x003A0005)]) }
                if let set = constraints.channelSet, !set.contains(channels) { state.record(.attributeValueNotAllowed, path: path + [.tag(0x003A0005)]) }
            } else {
                channelCounts.append(0)
            }
            let samples = item[0x003A0010]?.intValue
            if let samples, let maximum = constraints.samples, samples > maximum { state.record(.attributeValueNotAllowed, path: path + [.tag(0x003A0010)]) }
            if let range = constraints.frequency, let element = item[0x003A001A], element.vr == .DS, case .strings(let values) = element.value,
               values.count == 1, let frequency = try? DicomDecimalString.parse(values[0], vr: .DS),
               !(Decimal(range.lowerBound)...Decimal(range.upperBound)).contains(frequency) {
                state.record(.attributeValueNotAllowed, path: path + [.tag(0x003A001A)])
            }
            let interpretation = trimmed(item[0x54001006], 0)
            if let interpretation, !constraints.interpretations.contains(interpretation) {
                state.record(.attributeValueNotAllowed, path: path + [.tag(0x54001006)])
            }
            let bits = item[0x54001004]?.intValue
            if let interpretation, let bits, let expected = wordBits[interpretation], bits != expected {
                state.record(.attributeValueContradiction, path: path + [.tag(0x54001004)])
            }
            for (channelIndex, channel) in (item[0x003A0200]?.sequenceItems ?? []).enumerated() {
                if let stored = channel.dataSet[0x003A021A]?.intValue, let bits, stored > bits {
                    state.record(.attributeValueContradiction, path: path + [.tag(0x003A0200), .item(channelIndex), .tag(0x003A021A)])
                }
            }
            // C.10.9.1.5: Waveform Data holds samples × channels words of the allocated size.
            if let data = item[0x54001010], let bytes = data.bytesValue, let samples, let channels, let bits {
                let expected = samples * channels * (bits / 8)
                if bytes.count != expected && !(bytes.count == expected + 1 && bytes.last == 0) {
                    state.record(.attributeValueContradiction, path: path + [.tag(0x54001010)])
                }
            }
        }
        if let maximum = constraints.totalChannels, total > maximum { state.record(.attributeValueContradiction, path: [.tag(0x54000100)]) }
        // C.10.10: Referenced Waveform Channels name existing groups and channels (0 = all channels of the group).
        for (index, annotation) in (dataSet[0x0040B020]?.sequenceItems ?? []).enumerated() {
            guard let element = annotation.dataSet[0x0040A0B0], case .unsignedIntegers(let values) = element.value, values.count.isMultiple(of: 2) else { continue }
            for pair in stride(from: 0, to: values.count, by: 2) {
                let group = Int(values[pair]), channel = Int(values[pair + 1])
                guard group >= 1, group <= groups.count, channel >= 0, channel <= channelCounts[group - 1] else {
                    state.record(.referenceSelectionInvalid, path: [.tag(0x0040B020), .item(index), .tag(0x0040A0B0)])
                    break
                }
            }
        }
    }
}
