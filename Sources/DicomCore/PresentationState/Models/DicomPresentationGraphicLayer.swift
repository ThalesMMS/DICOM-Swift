import Foundation

/// One graphic layer used by presentation-state annotations.
public struct DicomPresentationGraphicLayer: Equatable, Sendable {
    public let name: String
    public let order: Int
    public let recommendedDisplayGrayscaleValue: UInt?
    public let recommendedDisplayCIELabValue: [UInt16]
    public let description: String?

    public init(
        name: String,
        order: Int = 1,
        recommendedDisplayGrayscaleValue: UInt? = nil,
        recommendedDisplayCIELabValue: [UInt16] = [],
        description: String? = nil
    ) {
        self.name = name.dicomGSPSLayerName
        self.order = max(0, order)
        self.recommendedDisplayGrayscaleValue = recommendedDisplayGrayscaleValue
        self.recommendedDisplayCIELabValue = recommendedDisplayCIELabValue
        self.description = description?.dicomGSPSNonEmptyValue
    }
}
