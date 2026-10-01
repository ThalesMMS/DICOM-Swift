import Foundation

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTFractionDoseReference: Equatable, Sendable {
    public var number: Int
    public var constraintWeight: Double?
    public var deliveryMaximumDose: Double?
    public var targetMinimumDose: Double?
    public var targetPrescriptionDose: Double?
    public var targetMaximumDose: Double?
    public var targetUnderdoseVolumeFraction: Double?
    public var organAtRiskFullVolumeDose: Double?
    public var organAtRiskLimitDose: Double?
    public var organAtRiskMaximumDose: Double?
    public var deliveryWarningDose: Double?
    public var organAtRiskOverdoseVolumeFraction: Double?

    public init(
        number: Int,
        constraintWeight: Double? = nil,
        deliveryMaximumDose: Double? = nil,
        targetMinimumDose: Double? = nil,
        targetPrescriptionDose: Double? = nil,
        targetMaximumDose: Double? = nil,
        targetUnderdoseVolumeFraction: Double? = nil,
        organAtRiskFullVolumeDose: Double? = nil,
        organAtRiskLimitDose: Double? = nil,
        organAtRiskMaximumDose: Double? = nil,
        deliveryWarningDose: Double? = nil,
        organAtRiskOverdoseVolumeFraction: Double? = nil
    ) {
        self.number = number
        self.constraintWeight = constraintWeight
        self.deliveryMaximumDose = deliveryMaximumDose
        self.targetMinimumDose = targetMinimumDose
        self.targetPrescriptionDose = targetPrescriptionDose
        self.targetMaximumDose = targetMaximumDose
        self.targetUnderdoseVolumeFraction = targetUnderdoseVolumeFraction
        self.organAtRiskFullVolumeDose = organAtRiskFullVolumeDose
        self.organAtRiskLimitDose = organAtRiskLimitDose
        self.organAtRiskMaximumDose = organAtRiskMaximumDose
        self.deliveryWarningDose = deliveryWarningDose
        self.organAtRiskOverdoseVolumeFraction = organAtRiskOverdoseVolumeFraction
    }

    init?(data: DicomDataSet) {
        guard let number = data.int(for: 0x300C0051) else { return nil }
        self.init(
            number: number,
            constraintWeight: data.decimalString(for: 0x300A0021),
            deliveryMaximumDose: data.decimalString(for: 0x300A0023),
            targetMinimumDose: data.decimalString(for: 0x300A0025),
            targetPrescriptionDose: data.decimalString(for: 0x300A0026),
            targetMaximumDose: data.decimalString(for: 0x300A0027),
            targetUnderdoseVolumeFraction: data.decimalString(for: 0x300A0028),
            organAtRiskFullVolumeDose: data.decimalString(for: 0x300A002A),
            organAtRiskLimitDose: data.decimalString(for: 0x300A002B),
            organAtRiskMaximumDose: data.decimalString(for: 0x300A002C),
            deliveryWarningDose: data.decimalString(for: 0x300A0022),
            organAtRiskOverdoseVolumeFraction: data.decimalString(for: 0x300A002D)
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300C0051, .IS, String(number)))
        if let value = constraintWeight { elements.append(DicomRTValueCoding.decimals(0x300A0021, [value])) }
        if let value = deliveryMaximumDose { elements.append(DicomRTValueCoding.decimals(0x300A0023, [value])) }
        if let value = targetMinimumDose { elements.append(DicomRTValueCoding.decimals(0x300A0025, [value])) }
        if let value = targetPrescriptionDose { elements.append(DicomRTValueCoding.decimals(0x300A0026, [value])) }
        if let value = targetMaximumDose { elements.append(DicomRTValueCoding.decimals(0x300A0027, [value])) }
        if let value = targetUnderdoseVolumeFraction { elements.append(DicomRTValueCoding.decimals(0x300A0028, [value])) }
        if let value = organAtRiskFullVolumeDose { elements.append(DicomRTValueCoding.decimals(0x300A002A, [value])) }
        if let value = organAtRiskLimitDose { elements.append(DicomRTValueCoding.decimals(0x300A002B, [value])) }
        if let value = organAtRiskMaximumDose { elements.append(DicomRTValueCoding.decimals(0x300A002C, [value])) }
        if let value = deliveryWarningDose { elements.append(DicomRTValueCoding.decimals(0x300A0022, [value])) }
        if let value = organAtRiskOverdoseVolumeFraction { elements.append(DicomRTValueCoding.decimals(0x300A002D, [value])) }
        return DicomDataSet(elements: elements)
    }
}

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTReferencedBeam: Equatable, Sendable {
    public var number: Int
    public var beamDose: Double?
    public var beamMeterset: Double?
    public var beamDoseSpecificationPoint: SIMD3<Double>?
    public var beamDeliveryDurationLimit: Double?
    public var beamDoseType: String?
    public var alternateBeamDoseType: String?

    public init(
        number: Int,
        beamDose: Double? = nil,
        beamMeterset: Double? = nil,
        beamDoseSpecificationPoint: SIMD3<Double>? = nil,
        beamDeliveryDurationLimit: Double? = nil,
        beamDoseType: String? = nil,
        alternateBeamDoseType: String? = nil
    ) {
        self.number = number
        self.beamDose = beamDose
        self.beamMeterset = beamMeterset
        self.beamDoseSpecificationPoint = beamDoseSpecificationPoint
        self.beamDeliveryDurationLimit = beamDeliveryDurationLimit
        self.beamDoseType = beamDoseType
        self.alternateBeamDoseType = alternateBeamDoseType
    }

    init?(data: DicomDataSet) {
        guard let number = data.int(for: 0x300C0006) else { return nil }
        self.init(
            number: number,
            beamDose: data.decimalString(for: 0x300A0084),
            beamMeterset: data.decimalString(for: 0x300A0086),
            beamDoseSpecificationPoint: DicomRTValueCoding.vector(data.decimalStrings(for: 0x300A0082)),
            beamDeliveryDurationLimit: data.float(for: 0x300A00C5),
            beamDoseType: data.string(for: 0x300A0090)?.dicomRTNonEmptyValue,
            alternateBeamDoseType: data.string(for: 0x300A0092)?.dicomRTNonEmptyValue
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300C0006, .IS, String(number)))
        if let value = beamDose { elements.append(DicomRTValueCoding.decimals(0x300A0084, [value])) }
        if let value = beamMeterset { elements.append(DicomRTValueCoding.decimals(0x300A0086, [value])) }
        if let value = beamDoseSpecificationPoint { elements.append(DicomRTValueCoding.decimals(0x300A0082, [value.x, value.y, value.z])) }
        if let value = beamDeliveryDurationLimit { elements.append(DicomDataElement(tag: 0x300A00C5, vr: .FD, value: .floats([value]))) }
        if let value = beamDoseType { elements.append(DicomRTValueCoding.text(0x300A0090, .CS, value)) }
        if let value = alternateBeamDoseType { elements.append(DicomRTValueCoding.text(0x300A0092, .CS, value)) }
        return DicomDataSet(elements: elements)
    }
}

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTReferencedBrachyApplicationSetup: Equatable, Sendable {
    public var number: Int
    public var dose: Double?
    public var doseSpecificationPoint: SIMD3<Double>?

    public init(
        number: Int,
        dose: Double? = nil,
        doseSpecificationPoint: SIMD3<Double>? = nil
    ) {
        self.number = number
        self.dose = dose
        self.doseSpecificationPoint = doseSpecificationPoint
    }

    init?(data: DicomDataSet) {
        guard let number = data.int(for: 0x300C000C) else { return nil }
        self.init(
            number: number,
            dose: data.decimalString(for: 0x300A00A4),
            doseSpecificationPoint: DicomRTValueCoding.vector(data.decimalStrings(for: 0x300A00A2))
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300C000C, .IS, String(number)))
        if let value = dose { elements.append(DicomRTValueCoding.decimals(0x300A00A4, [value])) }
        if let value = doseSpecificationPoint { elements.append(DicomRTValueCoding.decimals(0x300A00A2, [value.x, value.y, value.z])) }
        return DicomDataSet(elements: elements)
    }
}

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTFractionGroup: Equatable, Sendable {
    public var number: Int
    public var numberOfBeams: Int
    public var numberOfBrachyApplicationSetups: Int
    public var numberOfFractionsPlanned: Int?
    public var description: String?
    public var numberOfFractionPatternDigitsPerDay: Int?
    public var repeatFractionCycleLength: Int?
    public var fractionPattern: String?
    public var referencedBeams: [DicomRTReferencedBeam]
    public var referencedBrachyApplicationSetups: [DicomRTReferencedBrachyApplicationSetup]
    public var referencedDoseReferences: [DicomRTFractionDoseReference]

    public init(
        number: Int,
        numberOfBeams: Int,
        numberOfBrachyApplicationSetups: Int,
        numberOfFractionsPlanned: Int? = nil,
        description: String? = nil,
        numberOfFractionPatternDigitsPerDay: Int? = nil,
        repeatFractionCycleLength: Int? = nil,
        fractionPattern: String? = nil,
        referencedBeams: [DicomRTReferencedBeam] = [],
        referencedBrachyApplicationSetups: [DicomRTReferencedBrachyApplicationSetup] = [],
        referencedDoseReferences: [DicomRTFractionDoseReference] = []
    ) {
        self.number = number
        self.numberOfBeams = numberOfBeams
        self.numberOfBrachyApplicationSetups = numberOfBrachyApplicationSetups
        self.numberOfFractionsPlanned = numberOfFractionsPlanned
        self.description = description
        self.numberOfFractionPatternDigitsPerDay = numberOfFractionPatternDigitsPerDay
        self.repeatFractionCycleLength = repeatFractionCycleLength
        self.fractionPattern = fractionPattern
        self.referencedBeams = referencedBeams
        self.referencedBrachyApplicationSetups = referencedBrachyApplicationSetups
        self.referencedDoseReferences = referencedDoseReferences
    }

    init?(data: DicomDataSet) {
        guard let number = data.int(for: 0x300A0071) else { return nil }
        guard let numberOfBeams = data.int(for: 0x300A0080) else { return nil }
        guard let numberOfBrachyApplicationSetups = data.int(for: 0x300A00A0) else { return nil }
        self.init(
            number: number,
            numberOfBeams: numberOfBeams,
            numberOfBrachyApplicationSetups: numberOfBrachyApplicationSetups,
            numberOfFractionsPlanned: data.int(for: 0x300A0078),
            description: data.string(for: 0x300A0072)?.dicomRTNonEmptyValue,
            numberOfFractionPatternDigitsPerDay: data.int(for: 0x300A0079),
            repeatFractionCycleLength: data.int(for: 0x300A007A),
            fractionPattern: data.string(for: 0x300A007B)?.dicomRTNonEmptyValue,
            referencedBeams: data.sequenceItems(for: 0x300C0004).compactMap { DicomRTReferencedBeam(data: $0.dataSet) },
            referencedBrachyApplicationSetups: data.sequenceItems(for: 0x300C000A).compactMap { DicomRTReferencedBrachyApplicationSetup(data: $0.dataSet) },
            referencedDoseReferences: data.sequenceItems(for: 0x300C0050).compactMap { DicomRTFractionDoseReference(data: $0.dataSet) }
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300A0071, .IS, String(number)))
        elements.append(DicomRTValueCoding.text(0x300A0080, .IS, String(numberOfBeams)))
        elements.append(DicomRTValueCoding.text(0x300A00A0, .IS, String(numberOfBrachyApplicationSetups)))
        if let value = numberOfFractionsPlanned { elements.append(DicomRTValueCoding.text(0x300A0078, .IS, String(value))) } else { elements.append(DicomRTValueCoding.text(0x300A0078, .IS, "")) }
        if let value = description { elements.append(DicomRTValueCoding.text(0x300A0072, .LO, value)) }
        if let value = numberOfFractionPatternDigitsPerDay { elements.append(DicomRTValueCoding.text(0x300A0079, .IS, String(value))) }
        if let value = repeatFractionCycleLength { elements.append(DicomRTValueCoding.text(0x300A007A, .IS, String(value))) }
        if let value = fractionPattern { elements.append(DicomRTValueCoding.text(0x300A007B, .LT, value)) }
        if !referencedBeams.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300C0004, referencedBeams.map { $0.dataSet })) }
        if !referencedBrachyApplicationSetups.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300C000A, referencedBrachyApplicationSetups.map { $0.dataSet })) }
        if !referencedDoseReferences.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300C0050, referencedDoseReferences.map { $0.dataSet })) }
        return DicomDataSet(elements: elements)
    }
}

