import Foundation

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomSOPReference: Equatable, Sendable {
    public var sopClassUID: String
    public var sopInstanceUID: String

    public init(
        sopClassUID: String,
        sopInstanceUID: String
    ) {
        self.sopClassUID = sopClassUID
        self.sopInstanceUID = sopInstanceUID
    }

    init?(data: DicomDataSet) {
        guard let sopClassUID = data.string(for: 0x00081150) else { return nil }
        guard let sopInstanceUID = data.string(for: 0x00081155) else { return nil }
        self.init(
            sopClassUID: sopClassUID,
            sopInstanceUID: sopInstanceUID
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x00081150, .UI, sopClassUID))
        elements.append(DicomRTValueCoding.text(0x00081155, .UI, sopInstanceUID))
        return DicomDataSet(elements: elements)
    }
}

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTDoseControlPointRange: Equatable, Sendable {
    public var startIndex: Int
    public var stopIndex: Int

    public init(
        startIndex: Int,
        stopIndex: Int
    ) {
        self.startIndex = startIndex
        self.stopIndex = stopIndex
    }

    init?(data: DicomDataSet) {
        guard let startIndex = data.int(for: 0x300C00F4) else { return nil }
        guard let stopIndex = data.int(for: 0x300C00F6) else { return nil }
        self.init(
            startIndex: startIndex,
            stopIndex: stopIndex
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300C00F4, .IS, String(startIndex)))
        elements.append(DicomRTValueCoding.text(0x300C00F6, .IS, String(stopIndex)))
        return DicomDataSet(elements: elements)
    }
}

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTDoseReferencedBeam: Equatable, Sendable {
    public var number: Int
    public var controlPointRanges: [DicomRTDoseControlPointRange]

    public init(
        number: Int,
        controlPointRanges: [DicomRTDoseControlPointRange] = []
    ) {
        self.number = number
        self.controlPointRanges = controlPointRanges
    }

    init?(data: DicomDataSet) {
        guard let number = data.int(for: 0x300C0006) else { return nil }
        self.init(
            number: number,
            controlPointRanges: data.sequenceItems(for: 0x300C00F2).compactMap { DicomRTDoseControlPointRange(data: $0.dataSet) }
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300C0006, .IS, String(number)))
        if !controlPointRanges.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300C00F2, controlPointRanges.map { $0.dataSet })) }
        return DicomDataSet(elements: elements)
    }
}

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTDoseReferencedBrachyApplicationSetup: Equatable, Sendable {
    public var number: Int

    public init(
        number: Int
    ) {
        self.number = number
    }

    init?(data: DicomDataSet) {
        guard let number = data.int(for: 0x300C000C) else { return nil }
        self.init(
            number: number
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300C000C, .IS, String(number)))
        return DicomDataSet(elements: elements)
    }
}

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTDoseReferencedFractionGroup: Equatable, Sendable {
    public var number: Int
    public var beams: [DicomRTDoseReferencedBeam]
    public var brachyApplicationSetups: [DicomRTDoseReferencedBrachyApplicationSetup]

    public init(
        number: Int,
        beams: [DicomRTDoseReferencedBeam] = [],
        brachyApplicationSetups: [DicomRTDoseReferencedBrachyApplicationSetup] = []
    ) {
        self.number = number
        self.beams = beams
        self.brachyApplicationSetups = brachyApplicationSetups
    }

    init?(data: DicomDataSet) {
        guard let number = data.int(for: 0x300C0022) else { return nil }
        self.init(
            number: number,
            beams: data.sequenceItems(for: 0x300C0004).compactMap { DicomRTDoseReferencedBeam(data: $0.dataSet) },
            brachyApplicationSetups: data.sequenceItems(for: 0x300C000A).compactMap { DicomRTDoseReferencedBrachyApplicationSetup(data: $0.dataSet) }
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300C0022, .IS, String(number)))
        if !beams.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300C0004, beams.map { $0.dataSet })) }
        if !brachyApplicationSetups.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300C000A, brachyApplicationSetups.map { $0.dataSet })) }
        return DicomDataSet(elements: elements)
    }
}

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTDoseReferencedPlan: Equatable, Sendable {
    public var sopClassUID: String
    public var sopInstanceUID: String
    public var referencedPlanOverviewIndex: Int?
    public var fractionGroups: [DicomRTDoseReferencedFractionGroup]

    public init(
        sopClassUID: String,
        sopInstanceUID: String,
        referencedPlanOverviewIndex: Int? = nil,
        fractionGroups: [DicomRTDoseReferencedFractionGroup] = []
    ) {
        self.sopClassUID = sopClassUID
        self.sopInstanceUID = sopInstanceUID
        self.referencedPlanOverviewIndex = referencedPlanOverviewIndex
        self.fractionGroups = fractionGroups
    }

    init?(data: DicomDataSet) {
        guard let sopClassUID = data.string(for: 0x00081150) else { return nil }
        guard let sopInstanceUID = data.string(for: 0x00081155) else { return nil }
        self.init(
            sopClassUID: sopClassUID,
            sopInstanceUID: sopInstanceUID,
            referencedPlanOverviewIndex: data.int(for: 0x300C0118),
            fractionGroups: data.sequenceItems(for: 0x300C0020).compactMap { DicomRTDoseReferencedFractionGroup(data: $0.dataSet) }
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x00081150, .UI, sopClassUID))
        elements.append(DicomRTValueCoding.text(0x00081155, .UI, sopInstanceUID))
        if let value = referencedPlanOverviewIndex { elements.append(DicomRTValueCoding.text(0x300C0118, .US, String(value))) }
        if !fractionGroups.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300C0020, fractionGroups.map { $0.dataSet })) }
        return DicomDataSet(elements: elements)
    }
}

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTDoseReferencedTreatmentRecord: Equatable, Sendable {
    public var sopClassUID: String
    public var sopInstanceUID: String
    public var beams: [DicomRTDoseReferencedBeam]

    public init(
        sopClassUID: String,
        sopInstanceUID: String,
        beams: [DicomRTDoseReferencedBeam] = []
    ) {
        self.sopClassUID = sopClassUID
        self.sopInstanceUID = sopInstanceUID
        self.beams = beams
    }

    init?(data: DicomDataSet) {
        guard let sopClassUID = data.string(for: 0x00081150) else { return nil }
        guard let sopInstanceUID = data.string(for: 0x00081155) else { return nil }
        self.init(
            sopClassUID: sopClassUID,
            sopInstanceUID: sopInstanceUID,
            beams: data.sequenceItems(for: 0x300C0004).compactMap { DicomRTDoseReferencedBeam(data: $0.dataSet) }
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x00081150, .UI, sopClassUID))
        elements.append(DicomRTValueCoding.text(0x00081155, .UI, sopInstanceUID))
        if !beams.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300C0004, beams.map { $0.dataSet })) }
        return DicomDataSet(elements: elements)
    }
}

