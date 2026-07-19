import Foundation

public enum DicomWaveformError: Error, Equatable, LocalizedError, Sendable {
    case emptyMultiplexGroups
    case emptyChannels(group: String?)
    case invalidSamplingFrequency(Double)
    case inconsistentSampleCounts(group: String?)
    case sampleOutOfRange(value: Int, interpretation: String)
    case unsupportedSampleInterpretation(String)
    case invalidWaveformData(expectedBytes: Int, actualBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyMultiplexGroups:
            return "Waveform must contain at least one multiplex group."
        case .emptyChannels(let group):
            return "Waveform multiplex group \(group ?? "<unnamed>") must contain at least one channel."
        case .invalidSamplingFrequency(let frequency):
            return "Invalid waveform sampling frequency: \(frequency)."
        case .inconsistentSampleCounts(let group):
            return "Waveform multiplex group \(group ?? "<unnamed>") has inconsistent channel sample counts."
        case .sampleOutOfRange(let value, let interpretation):
            return "Waveform sample \(value) is outside \(interpretation) range."
        case .unsupportedSampleInterpretation(let interpretation):
            return "Unsupported waveform sample interpretation: \(interpretation)."
        case .invalidWaveformData(let expected, let actual):
            return "Invalid waveform payload: expected \(expected) bytes, found \(actual)."
        }
    }
}

public enum DicomWaveformStorageKind: CaseIterable, Equatable, Hashable, Sendable {
    case twelveLeadECG
    case generalECG
    case ambulatoryECG
    case general32BitECG
    case hemodynamic
    case cardiacElectrophysiology
    case arterialPulse
    case respiratory

    public var storageSOPClassUID: String {
        switch self {
        case .twelveLeadECG:
            return DicomWaveform.twelveLeadECGWaveformStorageSOPClassUID
        case .generalECG:
            return DicomWaveform.generalECGWaveformStorageSOPClassUID
        case .ambulatoryECG:
            return DicomWaveform.ambulatoryECGWaveformStorageSOPClassUID
        case .general32BitECG:
            return DicomWaveform.general32BitECGWaveformStorageSOPClassUID
        case .hemodynamic:
            return DicomWaveform.hemodynamicWaveformStorageSOPClassUID
        case .cardiacElectrophysiology:
            return DicomWaveform.cardiacElectrophysiologyWaveformStorageSOPClassUID
        case .arterialPulse:
            return DicomWaveform.arterialPulseWaveformStorageSOPClassUID
        case .respiratory:
            return DicomWaveform.respiratoryWaveformStorageSOPClassUID
        }
    }

    public var defaultModality: String {
        switch self {
        case .twelveLeadECG, .generalECG, .ambulatoryECG, .general32BitECG:
            return "ECG"
        case .hemodynamic:
            return "HD"
        case .cardiacElectrophysiology:
            return "EPS"
        case .arterialPulse, .respiratory:
            return "WAVEFORM"
        }
    }

    public init?(storageSOPClassUID: String) {
        switch storageSOPClassUID.dicomWaveformTrimmedValue {
        case DicomWaveform.twelveLeadECGWaveformStorageSOPClassUID:
            self = .twelveLeadECG
        case DicomWaveform.generalECGWaveformStorageSOPClassUID:
            self = .generalECG
        case DicomWaveform.ambulatoryECGWaveformStorageSOPClassUID:
            self = .ambulatoryECG
        case DicomWaveform.general32BitECGWaveformStorageSOPClassUID:
            self = .general32BitECG
        case DicomWaveform.hemodynamicWaveformStorageSOPClassUID:
            self = .hemodynamic
        case DicomWaveform.cardiacElectrophysiologyWaveformStorageSOPClassUID:
            self = .cardiacElectrophysiology
        case DicomWaveform.arterialPulseWaveformStorageSOPClassUID:
            self = .arterialPulse
        case DicomWaveform.respiratoryWaveformStorageSOPClassUID:
            self = .respiratory
        default:
            return nil
        }
    }
}

public enum DicomWaveformSampleInterpretation: String, CaseIterable, Equatable, Hashable, Sendable {
    case signed8 = "SB"
    case unsigned8 = "UB"
    case signed16 = "SS"
    case unsigned16 = "US"
    case signed32 = "SL"
    case unsigned32 = "UL"

    public var bitsAllocated: Int {
        switch self {
        case .signed8, .unsigned8:
            return 8
        case .signed16, .unsigned16:
            return 16
        case .signed32, .unsigned32:
            return 32
        }
    }

    public var bytesPerSample: Int {
        bitsAllocated / 8
    }

    public func contains(_ value: Int) -> Bool {
        switch self {
        case .signed8:
            return Int(Int8.min)...Int(Int8.max) ~= value
        case .unsigned8:
            return 0...Int(UInt8.max) ~= value
        case .signed16:
            return Int(Int16.min)...Int(Int16.max) ~= value
        case .unsigned16:
            return 0...Int(UInt16.max) ~= value
        case .signed32:
            return Int(Int32.min)...Int(Int32.max) ~= value
        case .unsigned32:
            return 0...Int(UInt32.max) ~= value
        }
    }
}

public struct DicomWaveformChannelReference: Equatable, Hashable, Sendable {
    public let multiplexGroupNumber: Int
    public let channelNumber: Int

    public init(multiplexGroupNumber: Int, channelNumber: Int) {
        self.multiplexGroupNumber = max(1, multiplexGroupNumber)
        self.channelNumber = max(1, channelNumber)
    }
}

public struct DicomWaveformSourceReference: Equatable, Hashable, Sendable {
    public let referencedSOPClassUID: String?
    public let referencedSOPInstanceUID: String?
    public let referencedWaveformChannels: [DicomWaveformChannelReference]

    public init(
        referencedSOPClassUID: String? = nil,
        referencedSOPInstanceUID: String? = nil,
        referencedWaveformChannels: [DicomWaveformChannelReference] = []
    ) {
        self.referencedSOPClassUID = referencedSOPClassUID?.dicomWaveformNonEmptyValue
        self.referencedSOPInstanceUID = referencedSOPInstanceUID?.dicomWaveformNonEmptyValue
        self.referencedWaveformChannels = referencedWaveformChannels.removingDuplicateWaveformElements()
    }
}

public struct DicomWaveformChannel: Equatable, Sendable {
    public let number: Int?
    public let label: String?
    public let status: [String]
    public let source: DicomCodedConcept?
    public let sourceModifiers: [DicomCodedConcept]
    public let sourceWaveformReferences: [DicomWaveformSourceReference]
    public let derivationDescription: String?
    public let sensitivity: Double?
    public let sensitivityUnits: DicomCodedConcept?
    public let sensitivityCorrectionFactor: Double?
    public let baseline: Double?
    public let timeSkew: Double?
    public let sampleSkew: Double?
    public let offset: Double?
    public let bitsStored: Int?
    public let lowFrequency: Double?
    public let highFrequency: Double?
    public let notchFrequency: Double?
    public let samples: [Int]

    public init(
        number: Int? = nil,
        label: String? = nil,
        status: [String] = [],
        source: DicomCodedConcept? = nil,
        sourceModifiers: [DicomCodedConcept] = [],
        sourceWaveformReferences: [DicomWaveformSourceReference] = [],
        derivationDescription: String? = nil,
        sensitivity: Double? = nil,
        sensitivityUnits: DicomCodedConcept? = nil,
        sensitivityCorrectionFactor: Double? = nil,
        baseline: Double? = nil,
        timeSkew: Double? = nil,
        sampleSkew: Double? = nil,
        offset: Double? = nil,
        bitsStored: Int? = nil,
        lowFrequency: Double? = nil,
        highFrequency: Double? = nil,
        notchFrequency: Double? = nil,
        samples: [Int]
    ) {
        self.number = number
        self.label = label?.dicomWaveformNonEmptyValue
        self.status = status.map { $0.dicomWaveformTrimmedValue.uppercased() }.filter { !$0.isEmpty }
        self.source = source
        self.sourceModifiers = sourceModifiers.removingDuplicateWaveformElements()
        self.sourceWaveformReferences = sourceWaveformReferences.removingDuplicateWaveformElements()
        self.derivationDescription = derivationDescription?.dicomWaveformNonEmptyValue
        self.sensitivity = sensitivity
        self.sensitivityUnits = sensitivityUnits
        self.sensitivityCorrectionFactor = sensitivityCorrectionFactor
        self.baseline = baseline
        self.timeSkew = timeSkew
        self.sampleSkew = sampleSkew
        self.offset = offset
        self.bitsStored = bitsStored
        self.lowFrequency = lowFrequency
        self.highFrequency = highFrequency
        self.notchFrequency = notchFrequency
        self.samples = samples
    }

    public func physicalValue(for sample: Int) -> Double? {
        guard let sensitivity else { return nil }
        let correction = sensitivityCorrectionFactor ?? 1
        let baseline = self.baseline ?? 0
        return (Double(sample) * sensitivity * correction) + baseline
    }
}

public struct DicomWaveformMultiplexGroup: Equatable, Sendable {
    public let label: String?
    public let originality: String
    public let samplingFrequency: Double
    public let timeOffsetMilliseconds: Double?
    public let triggerTimeOffsetMilliseconds: Double?
    public let triggerSamplePosition: Int?
    public let sampleInterpretation: DicomWaveformSampleInterpretation
    public let waveformDataDisplayScale: Double?
    public let channels: [DicomWaveformChannel]

    public init(
        label: String? = nil,
        originality: String = "ORIGINAL",
        samplingFrequency: Double,
        timeOffsetMilliseconds: Double? = nil,
        triggerTimeOffsetMilliseconds: Double? = nil,
        triggerSamplePosition: Int? = nil,
        sampleInterpretation: DicomWaveformSampleInterpretation = .signed16,
        waveformDataDisplayScale: Double? = nil,
        channels: [DicomWaveformChannel]
    ) {
        self.label = label?.dicomWaveformNonEmptyValue
        self.originality = originality.dicomWaveformNonEmptyValue?.uppercased() ?? "ORIGINAL"
        self.samplingFrequency = samplingFrequency
        self.timeOffsetMilliseconds = timeOffsetMilliseconds
        self.triggerTimeOffsetMilliseconds = triggerTimeOffsetMilliseconds
        self.triggerSamplePosition = triggerSamplePosition
        self.sampleInterpretation = sampleInterpretation
        self.waveformDataDisplayScale = waveformDataDisplayScale
        self.channels = channels
    }

    public var numberOfChannels: Int {
        channels.count
    }

    public var numberOfSamples: Int {
        channels.first?.samples.count ?? 0
    }
}

public struct DicomWaveformBuildOptions: Equatable, Sendable {
    public var kind: DicomWaveformStorageKind
    public var sopInstanceUID: String?
    public var studyInstanceUID: String?
    public var seriesInstanceUID: String?
    public var patientName: String?
    public var patientID: String?
    public var studyID: String?
    public var studyDate: String?
    public var studyTime: String?
    public var seriesNumber: Int?
    public var instanceNumber: Int?
    public var seriesDate: String?
    public var seriesTime: String?
    public var seriesDescription: String?
    public var contentDate: String?
    public var contentTime: String?
    public var modality: String?

    public init(
        kind: DicomWaveformStorageKind = .twelveLeadECG,
        sopInstanceUID: String? = nil,
        studyInstanceUID: String? = nil,
        seriesInstanceUID: String? = nil,
        patientName: String? = nil,
        patientID: String? = nil,
        studyID: String? = nil,
        studyDate: String? = nil,
        studyTime: String? = nil,
        seriesNumber: Int? = nil,
        instanceNumber: Int? = nil,
        seriesDate: String? = nil,
        seriesTime: String? = nil,
        seriesDescription: String? = "Waveform",
        contentDate: String? = nil,
        contentTime: String? = nil,
        modality: String? = nil
    ) {
        self.kind = kind
        self.sopInstanceUID = sopInstanceUID?.dicomWaveformNonEmptyValue
        self.studyInstanceUID = studyInstanceUID?.dicomWaveformNonEmptyValue
        self.seriesInstanceUID = seriesInstanceUID?.dicomWaveformNonEmptyValue
        self.patientName = patientName?.dicomWaveformNonEmptyValue
        self.patientID = patientID?.dicomWaveformNonEmptyValue
        self.studyID = studyID?.dicomWaveformNonEmptyValue
        self.studyDate = studyDate?.dicomWaveformNonEmptyValue
        self.studyTime = studyTime?.dicomWaveformNonEmptyValue
        self.seriesNumber = seriesNumber
        self.instanceNumber = instanceNumber
        self.seriesDate = seriesDate?.dicomWaveformNonEmptyValue
        self.seriesTime = seriesTime?.dicomWaveformNonEmptyValue
        self.seriesDescription = seriesDescription?.dicomWaveformNonEmptyValue
        self.contentDate = contentDate?.dicomWaveformNonEmptyValue
        self.contentTime = contentTime?.dicomWaveformNonEmptyValue
        self.modality = modality?.dicomWaveformNonEmptyValue?.uppercased()
    }

    public static func preservingClinicalContext(
        from decoder: DCMDecoder,
        kind: DicomWaveformStorageKind = .twelveLeadECG,
        sopInstanceUID: String? = nil,
        seriesDescription: String? = "Waveform"
    ) -> DicomWaveformBuildOptions {
        DicomWaveformBuildOptions(
            kind: kind,
            sopInstanceUID: sopInstanceUID,
            studyInstanceUID: decoder.info(for: .studyInstanceUID),
            seriesInstanceUID: decoder.info(for: .seriesInstanceUID),
            patientName: decoder.info(for: .patientName),
            patientID: decoder.info(for: .patientID),
            studyID: decoder.info(for: .studyID),
            studyDate: decoder.info(for: .studyDate),
            studyTime: decoder.info(for: .studyTime),
            seriesNumber: decoder.intValue(for: .seriesNumber),
            instanceNumber: 1,
            seriesDate: decoder.info(for: .seriesDate),
            seriesTime: decoder.info(for: .seriesTime),
            seriesDescription: seriesDescription,
            modality: kind.defaultModality
        )
    }
}

public struct DicomWaveform: Equatable, Sendable {
    public static let twelveLeadECGWaveformStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.9.1.1"
    public static let generalECGWaveformStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.9.1.2"
    public static let ambulatoryECGWaveformStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.9.1.3"
    public static let general32BitECGWaveformStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.9.1.4"
    public static let hemodynamicWaveformStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.9.2.1"
    public static let cardiacElectrophysiologyWaveformStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.9.3.1"
    public static let arterialPulseWaveformStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.9.5.1"
    public static let respiratoryWaveformStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.9.6.1"

    public static let supportedStorageSOPClassUIDs: Set<String> = [
        twelveLeadECGWaveformStorageSOPClassUID,
        generalECGWaveformStorageSOPClassUID,
        ambulatoryECGWaveformStorageSOPClassUID,
        general32BitECGWaveformStorageSOPClassUID,
        hemodynamicWaveformStorageSOPClassUID,
        cardiacElectrophysiologyWaveformStorageSOPClassUID,
        arterialPulseWaveformStorageSOPClassUID,
        respiratoryWaveformStorageSOPClassUID
    ]

    public let sopClassUID: String
    public let sopInstanceUID: String?
    public let studyInstanceUID: String?
    public let seriesInstanceUID: String?
    public let modality: String?
    public let patientName: DicomPersonName?
    public let patientID: String?
    public let multiplexGroups: [DicomWaveformMultiplexGroup]

    public init(
        sopClassUID: String,
        sopInstanceUID: String? = nil,
        studyInstanceUID: String? = nil,
        seriesInstanceUID: String? = nil,
        modality: String? = nil,
        patientName: DicomPersonName? = nil,
        patientID: String? = nil,
        multiplexGroups: [DicomWaveformMultiplexGroup]
    ) {
        self.sopClassUID = sopClassUID.dicomWaveformNonEmptyValue ?? sopClassUID
        self.sopInstanceUID = sopInstanceUID?.dicomWaveformNonEmptyValue
        self.studyInstanceUID = studyInstanceUID?.dicomWaveformNonEmptyValue
        self.seriesInstanceUID = seriesInstanceUID?.dicomWaveformNonEmptyValue
        self.modality = modality?.dicomWaveformNonEmptyValue?.uppercased()
        self.patientName = patientName
        self.patientID = patientID?.dicomWaveformNonEmptyValue
        self.multiplexGroups = multiplexGroups
    }

    public var totalChannelCount: Int {
        multiplexGroups.reduce(0) { $0 + $1.numberOfChannels }
    }

    public var kind: DicomWaveformStorageKind? {
        DicomWaveformStorageKind(storageSOPClassUID: sopClassUID)
    }
}

public enum DicomWaveformBuilder {
    public static func dataSet(
        multiplexGroups: [DicomWaveformMultiplexGroup],
        options: DicomWaveformBuildOptions = DicomWaveformBuildOptions()
    ) throws -> DicomDataSet {
        guard !multiplexGroups.isEmpty else {
            throw DicomWaveformError.emptyMultiplexGroups
        }
        try validate(multiplexGroups)

        let now = currentDicomDateTime()
        let sopInstanceUID = options.sopInstanceUID ?? DicomDataSetWriter.makeUID()
        let studyInstanceUID = options.studyInstanceUID ?? DicomDataSetWriter.makeUID()
        let seriesInstanceUID = options.seriesInstanceUID ?? DicomDataSetWriter.makeUID()
        let contentDate = options.contentDate ?? now.date
        let contentTime = options.contentTime ?? now.time
        let modality = options.modality ?? options.kind.defaultModality

        var elements: [DicomDataElement] = [
            string(.sopClassUID, vr: .UI, options.kind.storageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, sopInstanceUID),
            string(.studyInstanceUID, vr: .UI, studyInstanceUID),
            string(.seriesInstanceUID, vr: .UI, seriesInstanceUID),
            string(.modality, vr: .CS, modality),
            string(.contentDate, vr: .DA, contentDate),
            string(.contentTime, vr: .TM, contentTime),
            sequence(.waveformSequence, try multiplexGroups.map(multiplexGroupDataSet))
        ]

        appendOptionalStrings(options, to: &elements)
        return DicomDataSet(elements: elements)
    }

    public static func part10Data(
        multiplexGroups: [DicomWaveformMultiplexGroup],
        options: DicomWaveformBuildOptions = DicomWaveformBuildOptions()
    ) throws -> Data {
        let dataSet = try dataSet(multiplexGroups: multiplexGroups, options: options)
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: options.kind.storageSOPClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
    }

    public static func write(
        multiplexGroups: [DicomWaveformMultiplexGroup],
        to url: URL,
        options: DicomWaveformBuildOptions = DicomWaveformBuildOptions()
    ) throws {
        let data = try part10Data(multiplexGroups: multiplexGroups, options: options)
        try data.write(to: url, options: [.atomic])
    }

    private static func validate(_ groups: [DicomWaveformMultiplexGroup]) throws {
        for group in groups {
            guard group.samplingFrequency.isFinite, group.samplingFrequency > 0 else {
                throw DicomWaveformError.invalidSamplingFrequency(group.samplingFrequency)
            }
            guard !group.channels.isEmpty else {
                throw DicomWaveformError.emptyChannels(group: group.label)
            }
            let sampleCount = group.channels[0].samples.count
            guard group.channels.allSatisfy({ $0.samples.count == sampleCount }) else {
                throw DicomWaveformError.inconsistentSampleCounts(group: group.label)
            }
            for sample in group.channels.flatMap(\.samples) where !group.sampleInterpretation.contains(sample) {
                throw DicomWaveformError.sampleOutOfRange(
                    value: sample,
                    interpretation: group.sampleInterpretation.rawValue
                )
            }
        }
    }

    private static func multiplexGroupDataSet(_ group: DicomWaveformMultiplexGroup) throws -> DicomDataSet {
        let payload = try waveformData(for: group)
        var elements: [DicomDataElement] = [
            string(.waveformOriginality, vr: .CS, group.originality),
            us(.numberOfWaveformChannels, group.numberOfChannels),
            ul(.numberOfWaveformSamples, group.numberOfSamples),
            ds(.samplingFrequency, group.samplingFrequency),
            sequence(.channelDefinitionSequence, group.channels.enumerated().map { index, channel in
                channelDataSet(channel, ordinal: index + 1, group: group)
            }),
            us(.waveformBitsAllocated, group.sampleInterpretation.bitsAllocated),
            string(.waveformSampleInterpretation, vr: .CS, group.sampleInterpretation.rawValue),
            DicomDataElement(
                tag: DicomTag.waveformData.rawValue,
                vr: group.sampleInterpretation.bitsAllocated <= 8 ? .OB : .OW,
                value: .bytes(payload)
            )
        ]

        appendOptionalString(.multiplexGroupLabel, vr: .SH, group.label, to: &elements)
        appendOptionalDS(.multiplexGroupTimeOffset, group.timeOffsetMilliseconds, to: &elements)
        appendOptionalDS(.triggerTimeOffset, group.triggerTimeOffsetMilliseconds, to: &elements)
        if let triggerSamplePosition = group.triggerSamplePosition {
            elements.append(ul(.triggerSamplePosition, triggerSamplePosition))
        }
        if let scale = group.waveformDataDisplayScale {
            elements.append(fl(.waveformDataDisplayScale, scale))
        }
        return DicomDataSet(elements: elements)
    }

    private static func channelDataSet(
        _ channel: DicomWaveformChannel,
        ordinal: Int,
        group: DicomWaveformMultiplexGroup
    ) -> DicomDataSet {
        var elements: [DicomDataElement] = [
            isValue(.waveformChannelNumber, channel.number ?? ordinal),
            us(.waveformBitsStored, channel.bitsStored ?? group.sampleInterpretation.bitsAllocated)
        ]

        appendOptionalString(.channelLabel, vr: .SH, channel.label, to: &elements)
        if !channel.status.isEmpty {
            elements.append(DicomDataElement(
                tag: DicomTag.channelStatus.rawValue,
                vr: .CS,
                value: .strings(channel.status)
            ))
        }
        if let source = channel.source {
            elements.append(sequence(.channelSourceSequence, [codedConceptDataSet(source)]))
        }
        if !channel.sourceModifiers.isEmpty {
            elements.append(sequence(.channelSourceModifiersSequence, channel.sourceModifiers.map(codedConceptDataSet)))
        }
        if !channel.sourceWaveformReferences.isEmpty {
            elements.append(sequence(.sourceWaveformSequence, channel.sourceWaveformReferences.map(sourceReferenceDataSet)))
        }
        appendOptionalString(.channelDerivationDescription, vr: .LO, channel.derivationDescription, to: &elements)
        appendOptionalDS(.channelSensitivity, channel.sensitivity, to: &elements)
        if let units = channel.sensitivityUnits {
            elements.append(sequence(.channelSensitivityUnitsSequence, [codedConceptDataSet(units)]))
        }
        appendOptionalDS(.channelSensitivityCorrectionFactor, channel.sensitivityCorrectionFactor, to: &elements)
        appendOptionalDS(.channelBaseline, channel.baseline, to: &elements)
        appendOptionalDS(.channelTimeSkew, channel.timeSkew, to: &elements)
        appendOptionalDS(.channelSampleSkew, channel.sampleSkew, to: &elements)
        appendOptionalDS(.channelOffset, channel.offset, to: &elements)
        appendOptionalDS(.filterLowFrequency, channel.lowFrequency, to: &elements)
        appendOptionalDS(.filterHighFrequency, channel.highFrequency, to: &elements)
        appendOptionalDS(.notchFilterFrequency, channel.notchFrequency, to: &elements)
        return DicomDataSet(elements: elements)
    }

    private static func waveformData(for group: DicomWaveformMultiplexGroup) throws -> Data {
        var data = Data()
        data.reserveCapacity(group.numberOfChannels * group.numberOfSamples * group.sampleInterpretation.bytesPerSample)
        for sampleIndex in 0..<group.numberOfSamples {
            for channel in group.channels {
                try appendSample(channel.samples[sampleIndex], as: group.sampleInterpretation, to: &data)
            }
        }
        return data
    }

    private static func appendSample(
        _ value: Int,
        as interpretation: DicomWaveformSampleInterpretation,
        to data: inout Data
    ) throws {
        guard interpretation.contains(value) else {
            throw DicomWaveformError.sampleOutOfRange(value: value, interpretation: interpretation.rawValue)
        }
        switch interpretation {
        case .signed8:
            data.append(UInt8(bitPattern: Int8(value)))
        case .unsigned8:
            data.append(UInt8(value))
        case .signed16:
            appendUInt16(UInt16(bitPattern: Int16(value)), to: &data)
        case .unsigned16:
            appendUInt16(UInt16(value), to: &data)
        case .signed32:
            appendUInt32(UInt32(bitPattern: Int32(value)), to: &data)
        case .unsigned32:
            appendUInt32(UInt32(value), to: &data)
        }
    }

    private static func appendOptionalStrings(_ options: DicomWaveformBuildOptions, to elements: inout [DicomDataElement]) {
        appendOptionalString(.patientName, vr: .PN, options.patientName, to: &elements)
        appendOptionalString(.patientID, vr: .LO, options.patientID, to: &elements)
        appendOptionalString(.studyID, vr: .SH, options.studyID, to: &elements)
        appendOptionalString(.studyDate, vr: .DA, options.studyDate, to: &elements)
        appendOptionalString(.studyTime, vr: .TM, options.studyTime, to: &elements)
        appendOptionalString(.seriesDate, vr: .DA, options.seriesDate, to: &elements)
        appendOptionalString(.seriesTime, vr: .TM, options.seriesTime, to: &elements)
        appendOptionalString(.seriesDescription, vr: .LO, options.seriesDescription, to: &elements)
        if let seriesNumber = options.seriesNumber {
            elements.append(isValue(.seriesNumber, seriesNumber))
        }
        if let instanceNumber = options.instanceNumber {
            elements.append(isValue(.instanceNumber, instanceNumber))
        }
    }

    private static func appendOptionalString(
        _ tag: DicomTag,
        vr: DicomVR,
        _ value: String?,
        to elements: inout [DicomDataElement]
    ) {
        guard let value = value?.dicomWaveformNonEmptyValue else { return }
        elements.append(string(tag, vr: vr, value))
    }

    private static func appendOptionalDS(_ tag: DicomTag, _ value: Double?, to elements: inout [DicomDataElement]) {
        guard let value, value.isFinite else { return }
        elements.append(ds(tag, value))
    }

    private static func sourceReferenceDataSet(_ reference: DicomWaveformSourceReference) -> DicomDataSet {
        var elements: [DicomDataElement] = []
        if let sopClassUID = reference.referencedSOPClassUID {
            elements.append(string(.referencedSOPClassUID, vr: .UI, sopClassUID))
        }
        if let sopInstanceUID = reference.referencedSOPInstanceUID {
            elements.append(string(.referencedSOPInstanceUID, vr: .UI, sopInstanceUID))
        }
        if !reference.referencedWaveformChannels.isEmpty {
            let values = reference.referencedWaveformChannels.flatMap {
                [UInt($0.multiplexGroupNumber), UInt($0.channelNumber)]
            }
            elements.append(DicomDataElement(
                tag: DicomTag.referencedWaveformChannels.rawValue,
                vr: .US,
                value: .unsignedIntegers(values)
            ))
        }
        return DicomDataSet(elements: elements)
    }

    private static func codedConceptDataSet(_ concept: DicomCodedConcept) -> DicomDataSet {
        var elements = [
            string(.codeValue, vr: .SH, concept.codeValue),
            string(.codingSchemeDesignator, vr: .SH, concept.codingSchemeDesignator)
        ]
        if let meaning = concept.codeMeaning {
            elements.append(string(.codeMeaning, vr: .LO, meaning))
        }
        return DicomDataSet(elements: elements)
    }

    private static func sequence(_ tag: DicomTag, _ dataSets: [DicomDataSet]) -> DicomDataElement {
        DicomDataElement(
            tag: tag.rawValue,
            vr: .SQ,
            value: .sequence(dataSets.map { DicomSequenceItem(dataSet: $0) })
        )
    }

    private static func string(_ tag: DicomTag, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings([value]))
    }

    private static func us(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([UInt(clamping: value)]))
    }

    private static func ul(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .UL, value: .unsignedIntegers([UInt(clamping: value)]))
    }

    private static func isValue(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .IS, value: .strings([String(value)]))
    }

    private static func ds(_ tag: DicomTag, _ value: Double) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .DS, value: .strings([formatDecimal(value)]))
    }

    private static func fl(_ tag: DicomTag, _ value: Double) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .FL, value: .floats([value]))
    }

    private static func formatDecimal(_ value: Double) -> String {
        String(format: "%.12g", value)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func currentDicomDateTime() -> (date: String, time: String) {
        let date = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyyMMdd"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        timeFormatter.dateFormat = "HHmmss"

        return (dateFormatter.string(from: date), timeFormatter.string(from: date))
    }
}

extension DCMDecoder {
    public var waveform: DicomWaveform? {
        synchronized {
            DicomWaveformParser.makeWaveform(from: self)
        }
    }
}

private enum DicomWaveformParser {
    static func makeWaveform(from decoder: DCMDecoder) -> DicomWaveform? {
        guard matches(decoder) else { return nil }
        let groups = parseItems(in: decoder, for: .waveformSequence).compactMap(multiplexGroup)
        guard !groups.isEmpty else { return nil }

        return DicomWaveform(
            sopClassUID: decoder.info(for: .sopClassUID),
            sopInstanceUID: decoder.info(for: .sopInstanceUID),
            studyInstanceUID: decoder.info(for: .studyInstanceUID),
            seriesInstanceUID: decoder.info(for: .seriesInstanceUID),
            modality: decoder.info(for: .modality),
            patientName: decoder.dataSet.personName(for: .patientName),
            patientID: decoder.info(for: .patientID),
            multiplexGroups: groups
        )
    }

    private static func matches(_ decoder: DCMDecoder) -> Bool {
        let sopClassUID = decoder.info(for: .sopClassUID).dicomWaveformTrimmedValue
        return DicomWaveform.supportedStorageSOPClassUIDs.contains(sopClassUID) ||
            decoder.tagMetadataCache[DicomTag.waveformSequence.rawValue] != nil
    }

    private static func multiplexGroup(from item: DicomSequenceItem) -> DicomWaveformMultiplexGroup? {
        let dataSet = item.dataSet
        guard let channelCount = dataSet.int(for: .numberOfWaveformChannels),
              channelCount > 0,
              let sampleCount = dataSet.int(for: .numberOfWaveformSamples),
              sampleCount >= 0,
              let samplingFrequency = dataSet.float(for: .samplingFrequency),
              samplingFrequency > 0,
              let interpretation = dataSet.string(for: .waveformSampleInterpretation)
                .flatMap(DicomWaveformSampleInterpretation.init(rawValue:)),
              let raw = dataSet.element(for: .waveformData)?.bytesValue else {
            return nil
        }

        let decodedSamples: [[Int]]
        do {
            decodedSamples = try splitSamples(
                raw,
                interpretation: interpretation,
                channelCount: channelCount,
                sampleCount: sampleCount
            )
        } catch {
            return nil
        }

        let channelItems = dataSet.sequenceItems(for: .channelDefinitionSequence)
        let channels = (0..<channelCount).map { index in
            channel(
                from: channelItems[safe: index]?.dataSet,
                fallbackNumber: index + 1,
                samples: decodedSamples[index]
            )
        }

        return DicomWaveformMultiplexGroup(
            label: dataSet.string(for: .multiplexGroupLabel),
            originality: dataSet.string(for: .waveformOriginality) ?? "ORIGINAL",
            samplingFrequency: samplingFrequency,
            timeOffsetMilliseconds: dataSet.float(for: .multiplexGroupTimeOffset),
            triggerTimeOffsetMilliseconds: dataSet.float(for: .triggerTimeOffset),
            triggerSamplePosition: dataSet.int(for: .triggerSamplePosition),
            sampleInterpretation: interpretation,
            waveformDataDisplayScale: dataSet.float(for: .waveformDataDisplayScale),
            channels: channels
        )
    }

    private static func channel(
        from dataSet: DicomDataSet?,
        fallbackNumber: Int,
        samples: [Int]
    ) -> DicomWaveformChannel {
        guard let dataSet else {
            return DicomWaveformChannel(number: fallbackNumber, samples: samples)
        }
        return DicomWaveformChannel(
            number: dataSet.int(for: .waveformChannelNumber) ?? fallbackNumber,
            label: dataSet.string(for: .channelLabel),
            status: dataSet.strings(for: .channelStatus),
            source: dataSet.sequenceItems(for: .channelSourceSequence)
                .first
                .flatMap { DicomCodedConcept(dataSet: $0.dataSet) },
            sourceModifiers: dataSet.sequenceItems(for: .channelSourceModifiersSequence).compactMap {
                DicomCodedConcept(dataSet: $0.dataSet)
            },
            sourceWaveformReferences: dataSet.sequenceItems(for: .sourceWaveformSequence).map(sourceReference),
            derivationDescription: dataSet.string(for: .channelDerivationDescription),
            sensitivity: dataSet.float(for: .channelSensitivity),
            sensitivityUnits: dataSet.sequenceItems(for: .channelSensitivityUnitsSequence)
                .first
                .flatMap { DicomCodedConcept(dataSet: $0.dataSet) },
            sensitivityCorrectionFactor: dataSet.float(for: .channelSensitivityCorrectionFactor),
            baseline: dataSet.float(for: .channelBaseline),
            timeSkew: dataSet.float(for: .channelTimeSkew),
            sampleSkew: dataSet.float(for: .channelSampleSkew),
            offset: dataSet.float(for: .channelOffset),
            bitsStored: dataSet.int(for: .waveformBitsStored),
            lowFrequency: dataSet.float(for: .filterLowFrequency),
            highFrequency: dataSet.float(for: .filterHighFrequency),
            notchFrequency: dataSet.float(for: .notchFilterFrequency),
            samples: samples
        )
    }

    private static func sourceReference(from item: DicomSequenceItem) -> DicomWaveformSourceReference {
        DicomWaveformSourceReference(
            referencedSOPClassUID: item.dataSet.string(for: .referencedSOPClassUID),
            referencedSOPInstanceUID: item.dataSet.string(for: .referencedSOPInstanceUID),
            referencedWaveformChannels: channelReferences(from: item.dataSet.ints(for: .referencedWaveformChannels))
        )
    }

    private static func channelReferences(from values: [Int]) -> [DicomWaveformChannelReference] {
        stride(from: 0, to: values.count - values.count % 2, by: 2).map {
            DicomWaveformChannelReference(multiplexGroupNumber: values[$0], channelNumber: values[$0 + 1])
        }
    }

    private static func splitSamples(
        _ raw: Data,
        interpretation: DicomWaveformSampleInterpretation,
        channelCount: Int,
        sampleCount: Int
    ) throws -> [[Int]] {
        let expectedBytes = channelCount * sampleCount * interpretation.bytesPerSample
        guard raw.count >= expectedBytes else {
            throw DicomWaveformError.invalidWaveformData(expectedBytes: expectedBytes, actualBytes: raw.count)
        }
        var channels = Array(repeating: [Int](), count: channelCount)
        for index in channels.indices {
            channels[index].reserveCapacity(sampleCount)
        }

        for sampleIndex in 0..<sampleCount {
            for channelIndex in 0..<channelCount {
                let flatIndex = (sampleIndex * channelCount + channelIndex) * interpretation.bytesPerSample
                channels[channelIndex].append(sample(at: flatIndex, in: raw, interpretation: interpretation))
            }
        }
        return channels
    }

    private static func sample(
        at offset: Int,
        in data: Data,
        interpretation: DicomWaveformSampleInterpretation
    ) -> Int {
        switch interpretation {
        case .signed8:
            return Int(Int8(bitPattern: data[offset]))
        case .unsigned8:
            return Int(data[offset])
        case .signed16:
            return Int(Int16(bitPattern: data.readUInt16(at: offset)))
        case .unsigned16:
            return Int(data.readUInt16(at: offset))
        case .signed32:
            return Int(Int32(bitPattern: data.readUInt32(at: offset)))
        case .unsigned32:
            return Int(data.readUInt32(at: offset))
        }
    }

    private static func parseItems(in decoder: DCMDecoder, for tag: DicomTag) -> [DicomSequenceItem] {
        guard let metadata = decoder.tagMetadataCache[tag.rawValue],
              metadata.offset >= 0,
              metadata.elementLength >= 0,
              metadata.offset + metadata.elementLength <= decoder.dicomData.count else {
            return []
        }
        let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID) ?? .explicitVRLittleEndian
        return (try? DicomSequenceValueParser.parseItems(
            in: decoder.dicomData,
            valueOffset: metadata.offset,
            valueLength: metadata.elementLength,
            littleEndian: decoder.littleEndian,
            explicitVR: syntax.isExplicitVR,
            characterSet: decoder.activeCharacterSet
        )) ?? []
    }
}

private extension Array where Element: Equatable {
    func removingDuplicateWaveformElements() -> [Element] {
        var result: [Element] = []
        for element in self where !result.contains(element) {
            result.append(element)
        }
        return result
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    var dicomWaveformTrimmedValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    var dicomWaveformNonEmptyValue: String? {
        let trimmed = dicomWaveformTrimmedValue
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func readUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) |
            UInt32(self[offset + 1]) << 8 |
            UInt32(self[offset + 2]) << 16 |
            UInt32(self[offset + 3]) << 24
    }
}
