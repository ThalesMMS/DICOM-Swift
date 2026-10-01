import Foundation

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTFixationDevice: Equatable, Sendable {
    public var type: String
    public var label: String?
    public var description: String?

    public init(
        type: String,
        label: String? = nil,
        description: String? = nil
    ) {
        self.type = type
        self.label = label
        self.description = description
    }

    init?(data: DicomDataSet) {
        guard let type = data.string(for: 0x300A0192) else { return nil }
        self.init(
            type: type,
            label: data.string(for: 0x300A0194)?.dicomRTNonEmptyValue,
            description: data.string(for: 0x300A0196)?.dicomRTNonEmptyValue
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300A0192, .CS, type))
        if let value = label { elements.append(DicomRTValueCoding.text(0x300A0194, .SH, value)) } else { elements.append(DicomRTValueCoding.text(0x300A0194, .SH, "")) }
        if let value = description { elements.append(DicomRTValueCoding.text(0x300A0196, .ST, value)) }
        return DicomDataSet(elements: elements)
    }
}

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTShieldingDevice: Equatable, Sendable {
    public var type: String
    public var label: String?
    public var description: String?

    public init(
        type: String,
        label: String? = nil,
        description: String? = nil
    ) {
        self.type = type
        self.label = label
        self.description = description
    }

    init?(data: DicomDataSet) {
        guard let type = data.string(for: 0x300A01A2) else { return nil }
        self.init(
            type: type,
            label: data.string(for: 0x300A01A4)?.dicomRTNonEmptyValue,
            description: data.string(for: 0x300A01A6)?.dicomRTNonEmptyValue
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300A01A2, .CS, type))
        if let value = label { elements.append(DicomRTValueCoding.text(0x300A01A4, .SH, value)) } else { elements.append(DicomRTValueCoding.text(0x300A01A4, .SH, "")) }
        if let value = description { elements.append(DicomRTValueCoding.text(0x300A01A6, .ST, value)) }
        return DicomDataSet(elements: elements)
    }
}

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTSetupDevice: Equatable, Sendable {
    public var type: String
    public var label: String?
    public var description: String?
    public var parameter: Double?
    public var referenceDescription: String?

    public init(
        type: String,
        label: String? = nil,
        description: String? = nil,
        parameter: Double? = nil,
        referenceDescription: String? = nil
    ) {
        self.type = type
        self.label = label
        self.description = description
        self.parameter = parameter
        self.referenceDescription = referenceDescription
    }

    init?(data: DicomDataSet) {
        guard let type = data.string(for: 0x300A01B6) else { return nil }
        self.init(
            type: type,
            label: data.string(for: 0x300A01B8)?.dicomRTNonEmptyValue,
            description: data.string(for: 0x300A01BA)?.dicomRTNonEmptyValue,
            parameter: data.decimalString(for: 0x300A01BC),
            referenceDescription: data.string(for: 0x300A01D0)?.dicomRTNonEmptyValue
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300A01B6, .CS, type))
        if let value = label { elements.append(DicomRTValueCoding.text(0x300A01B8, .SH, value)) } else { elements.append(DicomRTValueCoding.text(0x300A01B8, .SH, "")) }
        if let value = description { elements.append(DicomRTValueCoding.text(0x300A01BA, .ST, value)) }
        if let value = parameter { elements.append(DicomRTValueCoding.decimals(0x300A01BC, [value])) } else { elements.append(DicomRTValueCoding.text(0x300A01BC, .DS, "")) }
        if let value = referenceDescription { elements.append(DicomRTValueCoding.text(0x300A01D0, .ST, value)) }
        return DicomDataSet(elements: elements)
    }
}

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTPatientSetup: Equatable, Sendable {
    public var number: Int
    public var label: String?
    public var patientPosition: String?
    public var patientAdditionalPosition: String?
    public var setupTechnique: String?
    public var setupTechniqueDescription: String?
    public var tableTopVerticalSetupDisplacement: Double?
    public var tableTopLongitudinalSetupDisplacement: Double?
    public var tableTopLateralSetupDisplacement: Double?
    public var fixationDevices: [DicomRTFixationDevice]
    public var shieldingDevices: [DicomRTShieldingDevice]
    public var setupImageReferences: [DicomSourceImageReference]
    public var setupDevices: [DicomRTSetupDevice]

    public init(
        number: Int,
        label: String? = nil,
        patientPosition: String? = nil,
        patientAdditionalPosition: String? = nil,
        setupTechnique: String? = nil,
        setupTechniqueDescription: String? = nil,
        tableTopVerticalSetupDisplacement: Double? = nil,
        tableTopLongitudinalSetupDisplacement: Double? = nil,
        tableTopLateralSetupDisplacement: Double? = nil,
        fixationDevices: [DicomRTFixationDevice] = [],
        shieldingDevices: [DicomRTShieldingDevice] = [],
        setupDevices: [DicomRTSetupDevice] = [],
        setupImageReferences: [DicomSourceImageReference] = []
    ) {
        self.number = number
        self.label = label
        self.patientPosition = patientPosition
        self.patientAdditionalPosition = patientAdditionalPosition
        self.setupTechnique = setupTechnique
        self.setupTechniqueDescription = setupTechniqueDescription
        self.tableTopVerticalSetupDisplacement = tableTopVerticalSetupDisplacement
        self.tableTopLongitudinalSetupDisplacement = tableTopLongitudinalSetupDisplacement
        self.tableTopLateralSetupDisplacement = tableTopLateralSetupDisplacement
        self.fixationDevices = fixationDevices
        self.shieldingDevices = shieldingDevices
        self.setupDevices = setupDevices
        self.setupImageReferences = setupImageReferences
    }

    init?(data: DicomDataSet) {
        guard let number = data.int(for: 0x300A0182) else { return nil }
        self.init(
            number: number,
            label: data.string(for: 0x300A0183)?.dicomRTNonEmptyValue,
            patientPosition: data.string(for: 0x00185100)?.dicomRTNonEmptyValue,
            patientAdditionalPosition: data.string(for: 0x300A0184)?.dicomRTNonEmptyValue,
            setupTechnique: data.string(for: 0x300A01B0)?.dicomRTNonEmptyValue,
            setupTechniqueDescription: data.string(for: 0x300A01B2)?.dicomRTNonEmptyValue,
            tableTopVerticalSetupDisplacement: data.decimalString(for: 0x300A01D2),
            tableTopLongitudinalSetupDisplacement: data.decimalString(for: 0x300A01D4),
            tableTopLateralSetupDisplacement: data.decimalString(for: 0x300A01D6),
            fixationDevices: data.sequenceItems(for: 0x300A0190).compactMap { DicomRTFixationDevice(data: $0.dataSet) },
            shieldingDevices: data.sequenceItems(for: 0x300A01A0).compactMap { DicomRTShieldingDevice(data: $0.dataSet) },
            setupDevices: data.sequenceItems(for: 0x300A01B4).compactMap { DicomRTSetupDevice(data: $0.dataSet) },
            setupImageReferences: data.sequenceItems(for: 0x300A0401).map { DicomRTValueCoding.readSourceReference($0.dataSet) }
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300A0182, .IS, String(number)))
        if let value = label { elements.append(DicomRTValueCoding.text(0x300A0183, .LO, value)) }
        if let value = patientPosition { elements.append(DicomRTValueCoding.text(0x00185100, .CS, value)) }
        if let value = patientAdditionalPosition { elements.append(DicomRTValueCoding.text(0x300A0184, .LO, value)) }
        if let value = setupTechnique { elements.append(DicomRTValueCoding.text(0x300A01B0, .CS, value)) }
        if let value = setupTechniqueDescription { elements.append(DicomRTValueCoding.text(0x300A01B2, .ST, value)) }
        if let value = tableTopVerticalSetupDisplacement { elements.append(DicomRTValueCoding.decimals(0x300A01D2, [value])) }
        if let value = tableTopLongitudinalSetupDisplacement { elements.append(DicomRTValueCoding.decimals(0x300A01D4, [value])) }
        if let value = tableTopLateralSetupDisplacement { elements.append(DicomRTValueCoding.decimals(0x300A01D6, [value])) }
        if !fixationDevices.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300A0190, fixationDevices.map { $0.dataSet })) }
        if !shieldingDevices.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300A01A0, shieldingDevices.map { $0.dataSet })) }
        if !setupImageReferences.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300A0401, setupImageReferences.map(DicomRTValueCoding.sourceReference))) }
        if !setupDevices.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300A01B4, setupDevices.map { $0.dataSet })) }
        return DicomDataSet(elements: elements)
    }
}

