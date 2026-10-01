import Foundation

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTBeamLimitingDevice: Equatable, Sendable {
    public var type: String
    public var numberOfLeafJawPairs: Int
    public var sourceToBeamLimitingDeviceDistance: Double?
    public var leafPositionBoundaries: [Double]

    public init(
        type: String,
        numberOfLeafJawPairs: Int,
        sourceToBeamLimitingDeviceDistance: Double? = nil,
        leafPositionBoundaries: [Double] = []
    ) {
        self.type = type
        self.numberOfLeafJawPairs = numberOfLeafJawPairs
        self.sourceToBeamLimitingDeviceDistance = sourceToBeamLimitingDeviceDistance
        self.leafPositionBoundaries = leafPositionBoundaries
    }

    init?(data: DicomDataSet) {
        guard let type = data.string(for: 0x300A00B8) else { return nil }
        guard let numberOfLeafJawPairs = data.int(for: 0x300A00BC) else { return nil }
        self.init(
            type: type,
            numberOfLeafJawPairs: numberOfLeafJawPairs,
            sourceToBeamLimitingDeviceDistance: data.decimalString(for: 0x300A00BA),
            leafPositionBoundaries: data.decimalStrings(for: 0x300A00BE)
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300A00B8, .CS, type))
        elements.append(DicomRTValueCoding.text(0x300A00BC, .IS, String(numberOfLeafJawPairs)))
        if let value = sourceToBeamLimitingDeviceDistance { elements.append(DicomRTValueCoding.decimals(0x300A00BA, [value])) }
        if type == "MLCX" || type == "MLCY" || !leafPositionBoundaries.isEmpty { elements.append(DicomRTValueCoding.decimals(0x300A00BE, leafPositionBoundaries)) }
        return DicomDataSet(elements: elements)
    }
}

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTBeamLimitingDevicePosition: Equatable, Sendable {
    public var type: String
    public var leafJawPositions: [Double]

    public init(
        type: String,
        leafJawPositions: [Double] = []
    ) {
        self.type = type
        self.leafJawPositions = leafJawPositions
    }

    init?(data: DicomDataSet) {
        guard let type = data.string(for: 0x300A00B8) else { return nil }
        let positions = data.decimalStrings(for: 0x300A011C)
        guard !positions.isEmpty, positions.count.isMultiple(of: 2), positions.allSatisfy(\.isFinite) else { return nil }
        self.init(
            type: type,
            leafJawPositions: positions
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300A00B8, .CS, type))
        if !leafJawPositions.isEmpty { elements.append(DicomRTValueCoding.decimals(0x300A011C, leafJawPositions)) }
        return DicomDataSet(elements: elements)
    }
}
