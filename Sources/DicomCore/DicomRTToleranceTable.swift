import Foundation

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTBeamLimitingDeviceTolerance: Equatable, Sendable {
    public var type: String
    public var positionTolerance: Double

    public init(
        type: String,
        positionTolerance: Double
    ) {
        self.type = type
        self.positionTolerance = positionTolerance
    }

    init?(data: DicomDataSet) {
        guard let type = data.string(for: 0x300A00B8) else { return nil }
        guard let positionTolerance = data.decimalString(for: 0x300A004A) else { return nil }
        self.init(
            type: type,
            positionTolerance: positionTolerance
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300A00B8, .CS, type))
        elements.append(DicomRTValueCoding.decimals(0x300A004A, [positionTolerance]))
        return DicomDataSet(elements: elements)
    }
}

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTToleranceTable: Equatable, Sendable {
    public var number: Int
    public var label: String?
    public var gantryAngleTolerance: Double?
    public var beamLimitingDeviceAngleTolerance: Double?
    public var patientSupportAngleTolerance: Double?
    public var tableTopEccentricAngleTolerance: Double?
    public var tableTopPitchAngleTolerance: Double?
    public var tableTopRollAngleTolerance: Double?
    public var tableTopVerticalPositionTolerance: Double?
    public var tableTopLongitudinalPositionTolerance: Double?
    public var tableTopLateralPositionTolerance: Double?
    public var beamLimitingDeviceTolerances: [DicomRTBeamLimitingDeviceTolerance]

    public init(
        number: Int,
        label: String? = nil,
        gantryAngleTolerance: Double? = nil,
        beamLimitingDeviceAngleTolerance: Double? = nil,
        patientSupportAngleTolerance: Double? = nil,
        tableTopEccentricAngleTolerance: Double? = nil,
        tableTopPitchAngleTolerance: Double? = nil,
        tableTopRollAngleTolerance: Double? = nil,
        tableTopVerticalPositionTolerance: Double? = nil,
        tableTopLongitudinalPositionTolerance: Double? = nil,
        tableTopLateralPositionTolerance: Double? = nil,
        beamLimitingDeviceTolerances: [DicomRTBeamLimitingDeviceTolerance] = []
    ) {
        self.number = number
        self.label = label
        self.gantryAngleTolerance = gantryAngleTolerance
        self.beamLimitingDeviceAngleTolerance = beamLimitingDeviceAngleTolerance
        self.patientSupportAngleTolerance = patientSupportAngleTolerance
        self.tableTopEccentricAngleTolerance = tableTopEccentricAngleTolerance
        self.tableTopPitchAngleTolerance = tableTopPitchAngleTolerance
        self.tableTopRollAngleTolerance = tableTopRollAngleTolerance
        self.tableTopVerticalPositionTolerance = tableTopVerticalPositionTolerance
        self.tableTopLongitudinalPositionTolerance = tableTopLongitudinalPositionTolerance
        self.tableTopLateralPositionTolerance = tableTopLateralPositionTolerance
        self.beamLimitingDeviceTolerances = beamLimitingDeviceTolerances
    }

    init?(data: DicomDataSet) {
        guard let number = data.int(for: 0x300A0042) else { return nil }
        self.init(
            number: number,
            label: data.string(for: 0x300A0043)?.dicomRTNonEmptyValue,
            gantryAngleTolerance: data.decimalString(for: 0x300A0044),
            beamLimitingDeviceAngleTolerance: data.decimalString(for: 0x300A0046),
            patientSupportAngleTolerance: data.decimalString(for: 0x300A004C),
            tableTopEccentricAngleTolerance: data.decimalString(for: 0x300A004E),
            tableTopPitchAngleTolerance: data.float(for: 0x300A004F),
            tableTopRollAngleTolerance: data.float(for: 0x300A0050),
            tableTopVerticalPositionTolerance: data.decimalString(for: 0x300A0051),
            tableTopLongitudinalPositionTolerance: data.decimalString(for: 0x300A0052),
            tableTopLateralPositionTolerance: data.decimalString(for: 0x300A0053),
            beamLimitingDeviceTolerances: data.sequenceItems(for: 0x300A0048).compactMap { DicomRTBeamLimitingDeviceTolerance(data: $0.dataSet) }
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300A0042, .IS, String(number)))
        if let value = label { elements.append(DicomRTValueCoding.text(0x300A0043, .SH, value)) }
        if let value = gantryAngleTolerance { elements.append(DicomRTValueCoding.decimals(0x300A0044, [value])) }
        if let value = beamLimitingDeviceAngleTolerance { elements.append(DicomRTValueCoding.decimals(0x300A0046, [value])) }
        if let value = patientSupportAngleTolerance { elements.append(DicomRTValueCoding.decimals(0x300A004C, [value])) }
        if let value = tableTopEccentricAngleTolerance { elements.append(DicomRTValueCoding.decimals(0x300A004E, [value])) }
        if let value = tableTopPitchAngleTolerance { elements.append(DicomDataElement(tag: 0x300A004F, vr: .FL, value: .floats([value]))) }
        if let value = tableTopRollAngleTolerance { elements.append(DicomDataElement(tag: 0x300A0050, vr: .FL, value: .floats([value]))) }
        if let value = tableTopVerticalPositionTolerance { elements.append(DicomRTValueCoding.decimals(0x300A0051, [value])) }
        if let value = tableTopLongitudinalPositionTolerance { elements.append(DicomRTValueCoding.decimals(0x300A0052, [value])) }
        if let value = tableTopLateralPositionTolerance { elements.append(DicomRTValueCoding.decimals(0x300A0053, [value])) }
        if !beamLimitingDeviceTolerances.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300A0048, beamLimitingDeviceTolerances.map { $0.dataSet })) }
        return DicomDataSet(elements: elements)
    }
}

