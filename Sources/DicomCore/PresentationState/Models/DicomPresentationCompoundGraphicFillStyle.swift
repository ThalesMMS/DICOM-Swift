import Foundation

public struct DicomPresentationCompoundGraphicFillStyle: Equatable, Sendable {
    public let patternOnColorCIELabValue: [UInt16]
    public let patternOffColorCIELabValue: [UInt16]
    public let patternOnOpacity: Double?
    public let patternOffOpacity: Double?
    public let fillMode: String?
    public let fillPattern: Data?

    public init(
        patternOnColorCIELabValue: [UInt16] = [],
        patternOffColorCIELabValue: [UInt16] = [],
        patternOnOpacity: Double? = nil,
        patternOffOpacity: Double? = nil,
        fillMode: String? = nil,
        fillPattern: Data? = nil
    ) {
        self.patternOnColorCIELabValue = Array(patternOnColorCIELabValue.prefix(3))
        self.patternOffColorCIELabValue = Array(patternOffColorCIELabValue.prefix(3))
        self.patternOnOpacity = patternOnOpacity
        self.patternOffOpacity = patternOffOpacity
        self.fillMode = fillMode?.dicomGSPSNonEmptyValue?.uppercased()
        self.fillPattern = fillPattern
    }
}
