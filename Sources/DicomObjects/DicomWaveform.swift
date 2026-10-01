import Foundation
import DicomData

public enum DicomWaveformError: Error, Equatable, LocalizedError, Sendable {
    case invalidChannelReference
    case nonfiniteAnnotationValue
    case emptyMultiplexGroups
    case emptyChannels(group: String?)
    case invalidSamplingFrequency(Double)
    case inconsistentSampleCounts(group: String?)
    case inconsistentDisplayScales
    case sampleOutOfRange(value: Int, interpretation: String)
    case unsupportedSampleInterpretation(String)
    case invalidWaveformData(expectedBytes: Int, actualBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidChannelReference:
            return "Waveform references require positive US group and channel ordinals, or the all-channels selector."
        case .nonfiniteAnnotationValue:
            return "Waveform annotation numeric values and time offsets must be finite."
        case .emptyMultiplexGroups:
            return "Waveform must contain at least one multiplex group."
        case .emptyChannels(let group):
            return "Waveform multiplex group \(group ?? "<unnamed>") must contain at least one channel."
        case .invalidSamplingFrequency(let frequency):
            return "Invalid waveform sampling frequency: \(frequency)."
        case .inconsistentSampleCounts(let group):
            return "Waveform multiplex group \(group ?? "<unnamed>") has inconsistent channel sample counts."
        case .inconsistentDisplayScales:
            return "Waveform multiplex groups must agree on the root display scale."
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
    case multiChannelRespiratory
    case routineScalpEEG
    case electromyogram
    case electrooculogram
    case sleepEEG
    case basicVoiceAudio
    case generalAudio

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
        case .multiChannelRespiratory:
            return DicomWaveform.multiChannelRespiratoryWaveformStorageSOPClassUID
        case .routineScalpEEG:
            return DicomWaveform.routineScalpEEGWaveformStorageSOPClassUID
        case .electromyogram:
            return DicomWaveform.electromyogramWaveformStorageSOPClassUID
        case .electrooculogram:
            return DicomWaveform.electrooculogramWaveformStorageSOPClassUID
        case .sleepEEG:
            return DicomWaveform.sleepEEGWaveformStorageSOPClassUID
        case .basicVoiceAudio:
            return DicomWaveform.basicVoiceAudioWaveformStorageSOPClassUID
        case .generalAudio:
            return DicomWaveform.generalAudioWaveformStorageSOPClassUID
        }
    }

    public var defaultModality: String {
        switch self {
        case .twelveLeadECG, .generalECG, .ambulatoryECG, .general32BitECG:
            return "ECG"
        case .hemodynamic, .arterialPulse:
            // PS3.3 A.34.9: an arterial pulse waveform is a hemodynamic waveform.
            return "HD"
        case .cardiacElectrophysiology:
            return "EPS"
        case .respiratory, .multiChannelRespiratory:
            return "RESP"
        case .routineScalpEEG, .sleepEEG:
            return "EEG"
        case .electromyogram:
            return "EMG"
        case .electrooculogram:
            return "EOG"
        case .basicVoiceAudio, .generalAudio:
            return "AU"
        }
    }

    /// PS3.3 A.34: IODs whose Enhanced General Equipment module is mandatory.
    public var requiresEnhancedGeneralEquipment: Bool {
        switch self {
        case .general32BitECG, .generalAudio, .arterialPulse, .respiratory, .multiChannelRespiratory,
             .routineScalpEEG, .electromyogram, .electrooculogram, .sleepEEG:
            return true
        default:
            return false
        }
    }

    /// PS3.3 A.34: IODs whose Synchronization module is mandatory.
    public var requiresSynchronization: Bool {
        switch self {
        case .generalAudio, .arterialPulse, .respiratory:
            return true
        default:
            return false
        }
    }

    /// PS3.3 A.34.3/A.34.4: Synchronization is required when any multiplex group is ORIGINAL.
    public var synchronizationWhenOriginal: Bool {
        self == .hemodynamic || self == .cardiacElectrophysiology
    }

    public var isAudio: Bool {
        switch self {
        case .basicVoiceAudio, .generalAudio:
            return true
        default:
            return false
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
        case DicomWaveform.multiChannelRespiratoryWaveformStorageSOPClassUID:
            self = .multiChannelRespiratory
        case DicomWaveform.routineScalpEEGWaveformStorageSOPClassUID:
            self = .routineScalpEEG
        case DicomWaveform.electromyogramWaveformStorageSOPClassUID:
            self = .electromyogram
        case DicomWaveform.electrooculogramWaveformStorageSOPClassUID:
            self = .electrooculogram
        case DicomWaveform.sleepEEGWaveformStorageSOPClassUID:
            self = .sleepEEG
        case DicomWaveform.basicVoiceAudioWaveformStorageSOPClassUID:
            self = .basicVoiceAudio
        case DicomWaveform.generalAudioWaveformStorageSOPClassUID:
            self = .generalAudio
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
    case muLaw8 = "MB"
    case aLaw8 = "AB"

    public var bitsAllocated: Int {
        switch self {
        case .signed8, .unsigned8, .muLaw8, .aLaw8:
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
        case .unsigned8, .muLaw8, .aLaw8:
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
    public enum Channel: Equatable, Hashable, Sendable {
        case all
        case channel(Int)
    }
    public let channel: Channel
    public var channelNumber: Int {
        switch channel {
        case .all: 0
        case .channel(let number): number
        }
    }

    public init(multiplexGroupNumber: Int, channel: Channel) {
        self.multiplexGroupNumber = multiplexGroupNumber
        self.channel = channel
    }

    @available(*, deprecated, message: "Use init(multiplexGroupNumber:channel:) with .all or .channel.")

    public init(multiplexGroupNumber: Int, channelNumber: Int) {
        self.multiplexGroupNumber = multiplexGroupNumber
        self.channel = channelNumber == 0 ? .all : .channel(channelNumber)
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
    public let minimumValue: DicomWaveformSampleValue?
    public let maximumValue: DicomWaveformSampleValue?
    public internal(set) var paddingValue: DicomWaveformSampleValue?
    public internal(set) var sampleInterpretation: DicomWaveformSampleInterpretation?
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
        minimumValue: DicomWaveformSampleValue? = nil,
        maximumValue: DicomWaveformSampleValue? = nil,
        paddingValue: DicomWaveformSampleValue? = nil,
        sampleInterpretation: DicomWaveformSampleInterpretation? = nil,
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
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.paddingValue = paddingValue
        self.sampleInterpretation = sampleInterpretation
        self.samples = samples
    }

    public func physicalValue(for sample: Int) -> Double? {
        guard sample != paddingValue?.rawValue, let sensitivity else { return nil }
        let correction = sensitivityCorrectionFactor ?? 1
        let baseline = self.baseline ?? 0
        let linear = sampleInterpretation.flatMap { $0.linearPCM16(from: sample) }.map(Double.init) ?? Double(sample)
        return (linear * sensitivity * correction) + baseline
    }
    public func physicalSamples() -> [Double?] { samples.map { physicalValue(for: $0) } }
}

public struct DicomWaveformMultiplexGroup: Equatable, Sendable {
    public let label: String?
    public let originality: String
    public let samplingFrequency: Double
    public let timeOffsetMilliseconds: Double?
    public let triggerTimeOffsetMilliseconds: Double?
    public let triggerSamplePosition: Int?
    public let sampleInterpretation: DicomWaveformSampleInterpretation
    public let paddingValue: DicomWaveformSampleValue?
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
        paddingValue: DicomWaveformSampleValue? = nil,
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
        self.paddingValue = paddingValue
        self.channels = channels.map {
            var channel = $0
            channel.paddingValue = paddingValue
            channel.sampleInterpretation = sampleInterpretation
            return channel
        }
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
    public var patientBirthDate: String?
    public var patientSex: String?
    public var referringPhysicianName: String?
    public var accessionNumber: String?
    public var acquisitionDateTime: String?
    public var manufacturer: String?
    public var manufacturerModelName: String?
    public var deviceSerialNumber: String?
    public var softwareVersions: String?
    public var synchronizationFrameOfReferenceUID: String?

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
        modality: String? = nil,
        patientBirthDate: String? = nil,
        patientSex: String? = nil,
        referringPhysicianName: String? = nil,
        accessionNumber: String? = nil,
        acquisitionDateTime: String? = nil,
        manufacturer: String? = "DICOM-Swift",
        manufacturerModelName: String? = "DicomWaveformBuilder",
        deviceSerialNumber: String? = "0",
        softwareVersions: String? = nil,
        synchronizationFrameOfReferenceUID: String? = nil
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
        self.patientBirthDate = patientBirthDate?.dicomWaveformNonEmptyValue
        self.patientSex = patientSex?.dicomWaveformNonEmptyValue?.uppercased()
        self.referringPhysicianName = referringPhysicianName?.dicomWaveformNonEmptyValue
        self.accessionNumber = accessionNumber?.dicomWaveformNonEmptyValue
        self.acquisitionDateTime = acquisitionDateTime?.dicomWaveformNonEmptyValue
        self.manufacturer = manufacturer?.dicomWaveformNonEmptyValue
        self.manufacturerModelName = manufacturerModelName?.dicomWaveformNonEmptyValue
        self.deviceSerialNumber = deviceSerialNumber?.dicomWaveformNonEmptyValue
        self.softwareVersions = softwareVersions?.dicomWaveformNonEmptyValue
        self.synchronizationFrameOfReferenceUID = synchronizationFrameOfReferenceUID?.dicomWaveformNonEmptyValue
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
    public static let multiChannelRespiratoryWaveformStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.9.6.2"
    public static let routineScalpEEGWaveformStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.9.7.1"
    public static let electromyogramWaveformStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.9.7.2"
    public static let electrooculogramWaveformStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.9.7.3"
    public static let sleepEEGWaveformStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.9.7.4"
    public static let basicVoiceAudioWaveformStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.9.4.1"
    public static let generalAudioWaveformStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.9.4.2"

    public static let supportedStorageSOPClassUIDs: Set<String> = [
        twelveLeadECGWaveformStorageSOPClassUID,
        generalECGWaveformStorageSOPClassUID,
        ambulatoryECGWaveformStorageSOPClassUID,
        general32BitECGWaveformStorageSOPClassUID,
        hemodynamicWaveformStorageSOPClassUID,
        cardiacElectrophysiologyWaveformStorageSOPClassUID,
        arterialPulseWaveformStorageSOPClassUID,
        respiratoryWaveformStorageSOPClassUID,
        multiChannelRespiratoryWaveformStorageSOPClassUID,
        routineScalpEEGWaveformStorageSOPClassUID,
        electromyogramWaveformStorageSOPClassUID,
        electrooculogramWaveformStorageSOPClassUID,
        sleepEEGWaveformStorageSOPClassUID,
        basicVoiceAudioWaveformStorageSOPClassUID,
        generalAudioWaveformStorageSOPClassUID
    ]

    public let sopClassUID: String
    public let sopInstanceUID: String?
    public let studyInstanceUID: String?
    public let seriesInstanceUID: String?
    public let modality: String?
    public let patientName: DicomPersonName?
    public let patientID: String?
    public let annotations: [DicomWaveformAnnotation]
    public let displayScale: DicomWaveformDisplayScale?
    public let multiplexGroups: [DicomWaveformMultiplexGroup]

    public init(
        sopClassUID: String,
        sopInstanceUID: String? = nil,
        studyInstanceUID: String? = nil,
        seriesInstanceUID: String? = nil,
        modality: String? = nil,
        patientName: DicomPersonName? = nil,
        patientID: String? = nil,
        multiplexGroups: [DicomWaveformMultiplexGroup],
        annotations: [DicomWaveformAnnotation] = [],
        displayScale: DicomWaveformDisplayScale? = nil
    ) {
        self.sopClassUID = sopClassUID.dicomWaveformNonEmptyValue ?? sopClassUID
        self.sopInstanceUID = sopInstanceUID?.dicomWaveformNonEmptyValue
        self.studyInstanceUID = studyInstanceUID?.dicomWaveformNonEmptyValue
        self.seriesInstanceUID = seriesInstanceUID?.dicomWaveformNonEmptyValue
        self.modality = modality?.dicomWaveformNonEmptyValue?.uppercased()
        self.patientName = patientName
        self.patientID = patientID?.dicomWaveformNonEmptyValue
        self.multiplexGroups = multiplexGroups
        self.annotations = annotations
        self.displayScale = displayScale
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
        annotations: [DicomWaveformAnnotation] = [],
        displayScale: DicomWaveformDisplayScale? = nil,
        options: DicomWaveformBuildOptions = DicomWaveformBuildOptions()
    ) throws -> DicomDataSet {
        guard !multiplexGroups.isEmpty else {
            throw DicomWaveformError.emptyMultiplexGroups
        }
        try validate(multiplexGroups, kind: options.kind)
        let references = annotations.flatMap(\.referencedChannels)
            + multiplexGroups.flatMap(\.channels).flatMap(\.sourceWaveformReferences).flatMap(\.referencedWaveformChannels)
            + (displayScale?.presentationGroups.flatMap(\.channels).map(\.reference) ?? [])
        guard references.allSatisfy({ reference in
            guard (1...65535).contains(reference.multiplexGroupNumber) else { return false }
            switch reference.channel {
            case .all: return true
            case .channel(let number): return (1...65535).contains(number)
            }
        }) else {
            throw DicomWaveformError.invalidChannelReference
        }
        guard annotations.allSatisfy({ $0.numericValues.allSatisfy(\.isFinite) && $0.referencedTimeOffsets.allSatisfy(\.isFinite) }) else {
            throw DicomWaveformError.nonfiniteAnnotationValue
        }

        let now = currentDicomDateTime()
        let sopInstanceUID = options.sopInstanceUID ?? DicomDataSetWriter.makeUID()
        let studyInstanceUID = options.studyInstanceUID ?? DicomDataSetWriter.makeUID()
        let seriesInstanceUID = options.seriesInstanceUID ?? DicomDataSetWriter.makeUID()
        let contentDate = options.contentDate ?? now.date
        let contentTime = options.contentTime ?? now.time
        let modality = options.modality ?? options.kind.defaultModality

        // PS3.3 A.34: Patient, General Study, General Series and General Equipment Type 2 attributes are
        // always present; Waveform Identification and the Waveform module are Type 1.
        var elements: [DicomDataElement] = [
            string(.sopClassUID, vr: .UI, options.kind.storageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, sopInstanceUID),
            string(.studyInstanceUID, vr: .UI, studyInstanceUID),
            string(.seriesInstanceUID, vr: .UI, seriesInstanceUID),
            string(.modality, vr: .CS, modality),
            string(.contentDate, vr: .DA, contentDate),
            string(.contentTime, vr: .TM, contentTime),
            optionalString(.patientName, vr: .PN, options.patientName),
            optionalString(.patientID, vr: .LO, options.patientID),
            optionalString(0x00100030, vr: .DA, options.patientBirthDate),
            optionalString(.patientSex, vr: .CS, options.patientSex),
            optionalString(.studyDate, vr: .DA, options.studyDate),
            optionalString(.studyTime, vr: .TM, options.studyTime),
            optionalString(.referringPhysicianName, vr: .PN, options.referringPhysicianName),
            optionalString(.studyID, vr: .SH, options.studyID),
            optionalString(.accessionNumber, vr: .SH, options.accessionNumber),
            options.seriesNumber.map { isValue(.seriesNumber, $0) }
                ?? DicomDataElement(tag: DicomTag.seriesNumber.rawValue, vr: .IS, value: .strings([])),
            optionalString(0x00080070, vr: .LO, options.manufacturer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? options.manufacturer : options.kind.requiresEnhancedGeneralEquipment ? "DICOM-Swift" : options.manufacturer),
            isValue(.instanceNumber, options.instanceNumber ?? 1),
            string(0x0008002A, vr: .DT, options.acquisitionDateTime ?? contentDate + contentTime),
            DicomDataElement(tag: 0x00400555, vr: .SQ, value: .sequence([])),
            sequence(.waveformSequence, try multiplexGroups.map(multiplexGroupDataSet))
        ]

        if options.kind.requiresEnhancedGeneralEquipment {
            elements.append(string(0x00081090, vr: .LO, options.manufacturerModelName ?? "DicomWaveformBuilder"))
            elements.append(string(0x00181000, vr: .LO, options.deviceSerialNumber ?? "0"))
            elements.append(string(0x00181020, vr: .LO, options.softwareVersions ?? softwareVersion))
        }
        let original = multiplexGroups.contains { $0.originality == "ORIGINAL" }
        if options.kind.requiresSynchronization || (options.kind.synchronizationWhenOriginal && original) {
            // C.7.4.2: the UTC synchronization frame of reference, no trigger, unsynchronized acquisition time.
            elements.append(string(0x00200200, vr: .UI, options.synchronizationFrameOfReferenceUID ?? utcSynchronizationUID))
            elements.append(string(0x0018106A, vr: .CS, "NO TRIGGER"))
            elements.append(string(0x00181800, vr: .CS, "N"))
        }

        if !annotations.isEmpty {
            elements.append(DicomDataElement(tag: 0x0040B020, vr: .SQ,
                value: .sequence(annotations.map { .init(dataSet: $0.dataSet) })))
        }
        if let displayScale { elements += displayScale.elements }
        else {
            let scales = multiplexGroups.compactMap(\.waveformDataDisplayScale)
            if let scale = scales.first {
                guard scales.dropFirst().allSatisfy({ $0 == scale }) else {
                    throw DicomWaveformError.inconsistentDisplayScales
                }
                elements.append(fl(.waveformDataDisplayScale, scale))
            }
        }
        appendOptionalStrings(options, to: &elements)
        return DicomDataSet(elements: elements)
    }

    public static func part10Data(
        multiplexGroups: [DicomWaveformMultiplexGroup],
        annotations: [DicomWaveformAnnotation] = [],
        displayScale: DicomWaveformDisplayScale? = nil,
        options: DicomWaveformBuildOptions = DicomWaveformBuildOptions()
    ) throws -> Data {
        let dataSet = try dataSet(multiplexGroups: multiplexGroups, annotations: annotations, displayScale: displayScale, options: options)
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
        annotations: [DicomWaveformAnnotation] = [],
        displayScale: DicomWaveformDisplayScale? = nil,
        options: DicomWaveformBuildOptions = DicomWaveformBuildOptions()
    ) throws {
        let data = try part10Data(multiplexGroups: multiplexGroups, annotations: annotations, displayScale: displayScale, options: options)
        try data.write(to: url, options: [.atomic])
    }

    private static func validate(
        _ groups: [DicomWaveformMultiplexGroup],
        kind: DicomWaveformStorageKind
    ) throws {
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
            if kind == .multiChannelRespiratory,
               [.signed16, .signed32].contains(group.sampleInterpretation) == false {
                throw DicomWaveformError.unsupportedSampleInterpretation(group.sampleInterpretation.rawValue)
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
            sequence(.channelDefinitionSequence, try group.channels.enumerated().map { index, channel in
                try channelDataSet(channel, ordinal: index + 1, group: group)
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
        if let padding = group.paddingValue {
            elements.append(try sampleElement(padding, tag: 0x5400100A, interpretation: group.sampleInterpretation))
        }
        return DicomDataSet(elements: elements)
    }

    private static func channelDataSet(
        _ channel: DicomWaveformChannel,
        ordinal: Int,
        group: DicomWaveformMultiplexGroup
    ) throws -> DicomDataSet {
        var elements: [DicomDataElement] = [
            isValue(.waveformChannelNumber, channel.number ?? ordinal),
            us(.waveformBitsStored, channel.bitsStored ?? group.sampleInterpretation.bitsAllocated)
        ]

        if let minimum = channel.minimumValue {
            elements.append(try sampleElement(minimum, tag: 0x54000110, interpretation: group.sampleInterpretation))
        }
        if let maximum = channel.maximumValue {
            elements.append(try sampleElement(maximum, tag: 0x54000112, interpretation: group.sampleInterpretation))
        }
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
        // C.10.9: correction factor and baseline accompany a sensitivity; one of the skews is always present.
        appendOptionalDS(.channelSensitivityCorrectionFactor,
                         channel.sensitivityCorrectionFactor ?? (channel.sensitivity == nil ? nil : 1), to: &elements)
        appendOptionalDS(.channelBaseline, channel.baseline ?? (channel.sensitivity == nil ? nil : 0), to: &elements)
        if channel.timeSkew == nil, channel.sampleSkew == nil {
            elements.append(ds(.channelTimeSkew, 0))
        }
        appendOptionalDS(.channelTimeSkew, channel.timeSkew, to: &elements)
        appendOptionalDS(.channelSampleSkew, channel.sampleSkew, to: &elements)
        appendOptionalDS(.channelOffset, channel.offset, to: &elements)
        appendOptionalDS(.filterLowFrequency, channel.lowFrequency, to: &elements)
        appendOptionalDS(.filterHighFrequency, channel.highFrequency, to: &elements)
        appendOptionalDS(.notchFilterFrequency, channel.notchFrequency, to: &elements)
        return DicomDataSet(elements: elements)
    }

    private static func sampleElement(_ value: DicomWaveformSampleValue, tag: Int,
                                      interpretation: DicomWaveformSampleInterpretation) throws -> DicomDataElement {
        guard value.interpretation == interpretation else {
            throw DicomWaveformError.unsupportedSampleInterpretation(value.interpretation.rawValue)
        }
        var bytes = Data()
        try appendSample(value.rawValue, as: interpretation, to: &bytes)
        return DicomDataElement(tag: tag, vr: interpretation.bitsAllocated == 8 ? .OB : .OW, value: .bytes(bytes))
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
        case .unsigned8, .muLaw8, .aLaw8:
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

    static let softwareVersion = "1.0"
    /// PS3.3 C.7.4.2: the well-known UTC synchronization frame of reference.
    static let utcSynchronizationUID = "1.2.840.10008.15.1.1"

    private static func appendOptionalStrings(_ options: DicomWaveformBuildOptions, to elements: inout [DicomDataElement]) {
        appendOptionalString(.seriesDate, vr: .DA, options.seriesDate, to: &elements)
        appendOptionalString(.seriesTime, vr: .TM, options.seriesTime, to: &elements)
        appendOptionalString(.seriesDescription, vr: .LO, options.seriesDescription, to: &elements)
    }

    /// A Type 2 attribute: the value when supplied, otherwise a zero-length element.
    private static func optionalString(_ tag: DicomTag, vr: DicomVR, _ value: String?) -> DicomDataElement {
        optionalString(tag.rawValue, vr: vr, value)
    }

    private static func optionalString(_ tag: Int, vr: DicomVR, _ value: String?) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: vr, value: .strings(value.map { [$0] } ?? []))
    }

    private static func string(_ tag: Int, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
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

private extension Array where Element: Equatable {
    func removingDuplicateWaveformElements() -> [Element] {
        var result: [Element] = []
        for element in self where !result.contains(element) {
            result.append(element)
        }
        return result
    }
}

package extension String {
    var dicomWaveformTrimmedValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    var dicomWaveformNonEmptyValue: String? {
        let trimmed = dicomWaveformTrimmedValue
        return trimmed.isEmpty ? nil : trimmed
    }
}
