import Foundation

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTDoseReference: Equatable, Sendable {
    public var number: Int
    public var structureType: String
    public var type: String
    public var uid: String?
    public var description: String?
    public var referencedROINumber: Int?
    public var pointCoordinates: SIMD3<Double>?
    public var constraintWeight: Double?
    public var deliveryMaximumDose: Double?
    public var targetMinimumDose: Double?
    public var targetPrescriptionDose: Double?
    public var targetMaximumDose: Double?
    public var targetUnderdoseVolumeFraction: Double?
    public var organAtRiskFullVolumeDose: Double?
    public var organAtRiskLimitDose: Double?
    public var organAtRiskMaximumDose: Double?

    public init(
        number: Int,
        structureType: String,
        type: String,
        uid: String? = nil,
        description: String? = nil,
        referencedROINumber: Int? = nil,
        pointCoordinates: SIMD3<Double>? = nil,
        constraintWeight: Double? = nil,
        deliveryMaximumDose: Double? = nil,
        targetMinimumDose: Double? = nil,
        targetPrescriptionDose: Double? = nil,
        targetMaximumDose: Double? = nil,
        targetUnderdoseVolumeFraction: Double? = nil,
        organAtRiskFullVolumeDose: Double? = nil,
        organAtRiskLimitDose: Double? = nil,
        organAtRiskMaximumDose: Double? = nil
    ) {
        self.number = number
        self.structureType = structureType
        self.type = type
        self.uid = uid
        self.description = description
        self.referencedROINumber = referencedROINumber
        self.pointCoordinates = pointCoordinates
        self.constraintWeight = constraintWeight
        self.deliveryMaximumDose = deliveryMaximumDose
        self.targetMinimumDose = targetMinimumDose
        self.targetPrescriptionDose = targetPrescriptionDose
        self.targetMaximumDose = targetMaximumDose
        self.targetUnderdoseVolumeFraction = targetUnderdoseVolumeFraction
        self.organAtRiskFullVolumeDose = organAtRiskFullVolumeDose
        self.organAtRiskLimitDose = organAtRiskLimitDose
        self.organAtRiskMaximumDose = organAtRiskMaximumDose
    }

    init?(data: DicomDataSet) {
        guard let number = data.int(for: 0x300A0012) else { return nil }
        guard let structureType = data.string(for: 0x300A0014) else { return nil }
        guard let type = data.string(for: 0x300A0020) else { return nil }
        self.init(
            number: number,
            structureType: structureType,
            type: type,
            uid: data.string(for: 0x300A0013)?.dicomRTNonEmptyValue,
            description: data.string(for: 0x300A0016)?.dicomRTNonEmptyValue,
            referencedROINumber: data.int(for: 0x30060084),
            pointCoordinates: DicomRTValueCoding.vector(data.decimalStrings(for: 0x300A0018)),
            constraintWeight: data.decimalString(for: 0x300A0021),
            deliveryMaximumDose: data.decimalString(for: 0x300A0023),
            targetMinimumDose: data.decimalString(for: 0x300A0025),
            targetPrescriptionDose: data.decimalString(for: 0x300A0026),
            targetMaximumDose: data.decimalString(for: 0x300A0027),
            targetUnderdoseVolumeFraction: data.decimalString(for: 0x300A0028),
            organAtRiskFullVolumeDose: data.decimalString(for: 0x300A002A),
            organAtRiskLimitDose: data.decimalString(for: 0x300A002B),
            organAtRiskMaximumDose: data.decimalString(for: 0x300A002C)
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300A0012, .IS, String(number)))
        elements.append(DicomRTValueCoding.text(0x300A0014, .CS, structureType))
        elements.append(DicomRTValueCoding.text(0x300A0020, .CS, type))
        if let value = uid { elements.append(DicomRTValueCoding.text(0x300A0013, .UI, value)) }
        if let value = description { elements.append(DicomRTValueCoding.text(0x300A0016, .LO, value)) }
        if let value = referencedROINumber { elements.append(DicomRTValueCoding.text(0x30060084, .IS, String(value))) }
        if let value = pointCoordinates { elements.append(DicomRTValueCoding.decimals(0x300A0018, [value.x, value.y, value.z])) }
        if let value = constraintWeight { elements.append(DicomRTValueCoding.decimals(0x300A0021, [value])) }
        if let value = deliveryMaximumDose { elements.append(DicomRTValueCoding.decimals(0x300A0023, [value])) }
        if let value = targetMinimumDose { elements.append(DicomRTValueCoding.decimals(0x300A0025, [value])) }
        if let value = targetPrescriptionDose { elements.append(DicomRTValueCoding.decimals(0x300A0026, [value])) }
        if let value = targetMaximumDose { elements.append(DicomRTValueCoding.decimals(0x300A0027, [value])) }
        if let value = targetUnderdoseVolumeFraction { elements.append(DicomRTValueCoding.decimals(0x300A0028, [value])) }
        if let value = organAtRiskFullVolumeDose { elements.append(DicomRTValueCoding.decimals(0x300A002A, [value])) }
        if let value = organAtRiskLimitDose { elements.append(DicomRTValueCoding.decimals(0x300A002B, [value])) }
        if let value = organAtRiskMaximumDose { elements.append(DicomRTValueCoding.decimals(0x300A002C, [value])) }
        return DicomDataSet(elements: elements)
    }
}

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTBeamDoseVerificationControlPoint: Equatable, Sendable {
    public var cumulativeMetersetWeight: Double
    public var referencedControlPointIndex: Int?
    public var beamDosePointDepth: Double?
    public var beamDosePointEquivalentDepth: Double?
    public var beamDosePointSSD: Double?

    public init(
        cumulativeMetersetWeight: Double,
        referencedControlPointIndex: Int? = nil,
        beamDosePointDepth: Double? = nil,
        beamDosePointEquivalentDepth: Double? = nil,
        beamDosePointSSD: Double? = nil
    ) {
        self.cumulativeMetersetWeight = cumulativeMetersetWeight
        self.referencedControlPointIndex = referencedControlPointIndex
        self.beamDosePointDepth = beamDosePointDepth
        self.beamDosePointEquivalentDepth = beamDosePointEquivalentDepth
        self.beamDosePointSSD = beamDosePointSSD
    }

    init?(data: DicomDataSet) {
        guard let cumulativeMetersetWeight = data.decimalString(for: 0x300A0134) else { return nil }
        self.init(
            cumulativeMetersetWeight: cumulativeMetersetWeight,
            referencedControlPointIndex: data.int(for: 0x300C00F0),
            beamDosePointDepth: data.float(for: 0x300A0088),
            beamDosePointEquivalentDepth: data.float(for: 0x300A0089),
            beamDosePointSSD: data.float(for: 0x300A008A)
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.decimals(0x300A0134, [cumulativeMetersetWeight]))
        if let value = referencedControlPointIndex { elements.append(DicomRTValueCoding.text(0x300C00F0, .IS, String(value))) }
        if let value = beamDosePointDepth { elements.append(DicomDataElement(tag: 0x300A0088, vr: .FL, value: .floats([value]))) }
        if let value = beamDosePointEquivalentDepth { elements.append(DicomDataElement(tag: 0x300A0089, vr: .FL, value: .floats([value]))) }
        if let value = beamDosePointSSD { elements.append(DicomDataElement(tag: 0x300A008A, vr: .FL, value: .floats([value]))) }
        return DicomDataSet(elements: elements)
    }
}

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTBeamDoseReference: Equatable, Sendable {
    public var number: Int
    public var depthValueAveragingFlag: String?
    public var verificationControlPoints: [DicomRTBeamDoseVerificationControlPoint]

    public init(
        number: Int,
        depthValueAveragingFlag: String? = nil,
        verificationControlPoints: [DicomRTBeamDoseVerificationControlPoint] = []
    ) {
        self.number = number
        self.depthValueAveragingFlag = depthValueAveragingFlag
        self.verificationControlPoints = verificationControlPoints
    }

    init?(data: DicomDataSet) {
        guard let number = data.int(for: 0x300C0051) else { return nil }
        self.init(
            number: number,
            depthValueAveragingFlag: data.string(for: 0x300A0093)?.dicomRTNonEmptyValue,
            verificationControlPoints: data.sequenceItems(for: 0x300A008C).compactMap { DicomRTBeamDoseVerificationControlPoint(data: $0.dataSet) }
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300C0051, .IS, String(number)))
        if let value = depthValueAveragingFlag { elements.append(DicomRTValueCoding.text(0x300A0093, .CS, value)) }
        if !verificationControlPoints.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300A008C, verificationControlPoints.map { $0.dataSet })) }
        return DicomDataSet(elements: elements)
    }
}

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTControlPointDoseReference: Equatable, Sendable {
    public var number: Int
    public var cumulativeDoseReferenceCoefficient: Double?

    public init(
        number: Int,
        cumulativeDoseReferenceCoefficient: Double? = nil
    ) {
        self.number = number
        self.cumulativeDoseReferenceCoefficient = cumulativeDoseReferenceCoefficient
    }

    init?(data: DicomDataSet) {
        guard let number = data.int(for: 0x300C0051) else { return nil }
        self.init(
            number: number,
            cumulativeDoseReferenceCoefficient: data.decimalString(for: 0x300A010C)
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300C0051, .IS, String(number)))
        if let value = cumulativeDoseReferenceCoefficient { elements.append(DicomRTValueCoding.decimals(0x300A010C, [value])) } else { elements.append(DicomRTValueCoding.text(0x300A010C, .DS, "")) }
        return DicomDataSet(elements: elements)
    }
}

