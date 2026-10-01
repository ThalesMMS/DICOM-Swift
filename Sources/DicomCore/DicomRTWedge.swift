import Foundation

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTWedge: Equatable, Sendable {
    public var number: Int
    public var type: String?
    public var id: String?
    public var angle: Int?
    public var factor: Double?
    public var orientation: Double?
    public var sourceToWedgeTrayDistance: Double?

    public init(
        number: Int,
        type: String? = nil,
        id: String? = nil,
        angle: Int? = nil,
        factor: Double? = nil,
        orientation: Double? = nil,
        sourceToWedgeTrayDistance: Double? = nil
    ) {
        self.number = number
        self.type = type
        self.id = id
        self.angle = angle
        self.factor = factor
        self.orientation = orientation
        self.sourceToWedgeTrayDistance = sourceToWedgeTrayDistance
    }

    init?(data: DicomDataSet) {
        guard let number = data.int(for: 0x300A00D2) else { return nil }
        self.init(
            number: number,
            type: data.string(for: 0x300A00D3)?.dicomRTNonEmptyValue,
            id: data.string(for: 0x300A00D4)?.dicomRTNonEmptyValue,
            angle: data.int(for: 0x300A00D5),
            factor: data.decimalString(for: 0x300A00D6),
            orientation: data.decimalString(for: 0x300A00D8),
            sourceToWedgeTrayDistance: data.decimalString(for: 0x300A00DA)
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300A00D2, .IS, String(number)))
        if let value = type { elements.append(DicomRTValueCoding.text(0x300A00D3, .CS, value)) } else { elements.append(DicomRTValueCoding.text(0x300A00D3, .CS, "")) }
        if let value = id { elements.append(DicomRTValueCoding.text(0x300A00D4, .SH, value)) }
        if let value = angle { elements.append(DicomRTValueCoding.text(0x300A00D5, .IS, String(value))) } else { elements.append(DicomRTValueCoding.text(0x300A00D5, .IS, "")) }
        if let value = factor { elements.append(DicomRTValueCoding.decimals(0x300A00D6, [value])) } else { elements.append(DicomRTValueCoding.text(0x300A00D6, .DS, "")) }
        if let value = orientation { elements.append(DicomRTValueCoding.decimals(0x300A00D8, [value])) } else { elements.append(DicomRTValueCoding.text(0x300A00D8, .DS, "")) }
        if let value = sourceToWedgeTrayDistance { elements.append(DicomRTValueCoding.decimals(0x300A00DA, [value])) }
        return DicomDataSet(elements: elements)
    }
}

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTWedgePosition: Equatable, Sendable {
    public var referencedWedgeNumber: Int
    public var position: String

    public init(
        referencedWedgeNumber: Int,
        position: String
    ) {
        self.referencedWedgeNumber = referencedWedgeNumber
        self.position = position
    }

    init?(data: DicomDataSet) {
        guard let referencedWedgeNumber = data.int(for: 0x300C00C0) else { return nil }
        guard let position = data.string(for: 0x300A0118) else { return nil }
        self.init(
            referencedWedgeNumber: referencedWedgeNumber,
            position: position
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300C00C0, .IS, String(referencedWedgeNumber)))
        elements.append(DicomRTValueCoding.text(0x300A0118, .CS, position))
        return DicomDataSet(elements: elements)
    }
}

