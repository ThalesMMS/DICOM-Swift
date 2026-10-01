import Foundation

public struct DicomPresentationCompoundGraphicLineStyle: Equatable, Sendable {
    public let patternOnColorCIELabValue: [UInt16]
    public let patternOffColorCIELabValue: [UInt16]
    public let patternOnOpacity: Double?
    public let patternOffOpacity: Double?
    public let lineThickness: Double?
    public let lineDashingStyle: String?
    public let linePattern: UInt32?
    public let shadowStyle: String?
    public let shadowOffsetX: Double?
    public let shadowOffsetY: Double?
    public let shadowColorCIELabValue: [UInt16]
    public let shadowOpacity: Double?

    public init(
        patternOnColorCIELabValue: [UInt16] = [],
        patternOffColorCIELabValue: [UInt16] = [],
        patternOnOpacity: Double? = nil,
        patternOffOpacity: Double? = nil,
        lineThickness: Double? = nil,
        lineDashingStyle: String? = nil,
        linePattern: UInt32? = nil,
        shadowStyle: String? = nil,
        shadowOffsetX: Double? = nil,
        shadowOffsetY: Double? = nil,
        shadowColorCIELabValue: [UInt16] = [],
        shadowOpacity: Double? = nil
    ) {
        self.patternOnColorCIELabValue = Array(patternOnColorCIELabValue.prefix(3))
        self.patternOffColorCIELabValue = Array(patternOffColorCIELabValue.prefix(3))
        self.patternOnOpacity = patternOnOpacity
        self.patternOffOpacity = patternOffOpacity
        self.lineThickness = lineThickness
        self.lineDashingStyle = lineDashingStyle?.dicomGSPSNonEmptyValue?.uppercased()
        self.linePattern = linePattern
        self.shadowStyle = shadowStyle?.dicomGSPSNonEmptyValue?.uppercased()
        self.shadowOffsetX = shadowOffsetX
        self.shadowOffsetY = shadowOffsetY
        self.shadowColorCIELabValue = Array(shadowColorCIELabValue.prefix(3))
        self.shadowOpacity = shadowOpacity
    }
}
