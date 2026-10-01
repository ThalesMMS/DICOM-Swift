import Foundation

public struct DicomWholeSlideOpticalPath: Sendable, Equatable {
    public let identifier: String
    public let description: String?
    public let illuminationTypeCodes: [DicomCodedConcept]
    public let illuminationColorCode: DicomCodedConcept?
    public let illuminationWavelengthNanometers: Double?
    public let lightPathFilterTypeStackCodes: [DicomCodedConcept]
    public let imagePathFilterTypeStackCodes: [DicomCodedConcept]
    public let objectiveLensPower: Double?
    public let objectiveLensNumericalAperture: Double?
    public let iccProfile: Data?
    public let colorSpace: String?
    public let palettePresent: Bool

    public init(
        identifier: String,
        description: String? = nil,
        illuminationTypeCodes: [DicomCodedConcept] = [],
        illuminationColorCode: DicomCodedConcept? = nil,
        illuminationWavelengthNanometers: Double? = nil,
        lightPathFilterTypeStackCodes: [DicomCodedConcept] = [],
        imagePathFilterTypeStackCodes: [DicomCodedConcept] = [],
        objectiveLensPower: Double? = nil,
        objectiveLensNumericalAperture: Double? = nil,
        iccProfile: Data? = nil,
        colorSpace: String? = nil,
        palettePresent: Bool = false
    ) {
        self.identifier = identifier
        self.description = description
        self.illuminationTypeCodes = illuminationTypeCodes
        self.illuminationColorCode = illuminationColorCode
        self.illuminationWavelengthNanometers = illuminationWavelengthNanometers
        self.lightPathFilterTypeStackCodes = lightPathFilterTypeStackCodes
        self.imagePathFilterTypeStackCodes = imagePathFilterTypeStackCodes
        self.objectiveLensPower = objectiveLensPower
        self.objectiveLensNumericalAperture = objectiveLensNumericalAperture
        self.iccProfile = iccProfile
        self.colorSpace = colorSpace
        self.palettePresent = palettePresent
    }
}
