import Foundation

public struct DicomPresentationCompoundGraphicTextStyle: Equatable, Sendable {
    public let fontName: String?
    public let fontNameType: String?
    public let cssFontName: String?
    public let textColorCIELabValue: [UInt16]
    public let horizontalAlignment: String?
    public let verticalAlignment: String?
    public let shadowStyle: String?
    public let shadowOffsetX: Double?
    public let shadowOffsetY: Double?
    public let shadowColorCIELabValue: [UInt16]
    public let shadowOpacity: Double?
    public let isUnderlined: Bool?
    public let isBold: Bool?
    public let isItalic: Bool?

    public init(
        fontName: String? = nil,
        fontNameType: String? = nil,
        cssFontName: String? = nil,
        textColorCIELabValue: [UInt16] = [],
        horizontalAlignment: String? = nil,
        verticalAlignment: String? = nil,
        shadowStyle: String? = nil,
        shadowOffsetX: Double? = nil,
        shadowOffsetY: Double? = nil,
        shadowColorCIELabValue: [UInt16] = [],
        shadowOpacity: Double? = nil,
        isUnderlined: Bool? = nil,
        isBold: Bool? = nil,
        isItalic: Bool? = nil
    ) {
        self.fontName = fontName?.dicomGSPSNonEmptyValue
        self.fontNameType = fontNameType?.dicomGSPSNonEmptyValue?.uppercased()
        self.cssFontName = cssFontName?.dicomGSPSNonEmptyValue
        self.textColorCIELabValue = Array(textColorCIELabValue.prefix(3))
        self.horizontalAlignment = horizontalAlignment?.dicomGSPSNonEmptyValue?.uppercased()
        self.verticalAlignment = verticalAlignment?.dicomGSPSNonEmptyValue?.uppercased()
        self.shadowStyle = shadowStyle?.dicomGSPSNonEmptyValue?.uppercased()
        self.shadowOffsetX = shadowOffsetX
        self.shadowOffsetY = shadowOffsetY
        self.shadowColorCIELabValue = Array(shadowColorCIELabValue.prefix(3))
        self.shadowOpacity = shadowOpacity
        self.isUnderlined = isUnderlined
        self.isBold = isBold
        self.isItalic = isItalic
    }
}
