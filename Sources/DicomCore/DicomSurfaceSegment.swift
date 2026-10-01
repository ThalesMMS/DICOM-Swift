//
//  DicomSurfaceSegment.swift
//  DicomCore
//

/// Segment semantics and source references associated with one or more surfaces.
public struct DicomSurfaceSegment: Equatable, Sendable {
    /// The segment number within the Surface Segmentation object.
    public let number: Int
    /// Human-readable segment label.
    public let label: String
    /// Recommended PCS-Value CIELab triplet, when present.
    public let recommendedDisplayCIELabValue: [UInt16]
    /// One-based surface numbers that represent this segment.
    public let referencedSurfaceNumbers: [Int]
    /// Source image instances referenced by the segment.
    public let sourceImageReferences: [DicomSourceImageReference]

    public let description: String?
    public let propertyCategory: DicomCodedConcept?
    public let propertyType: DicomCodedConcept?
    public let propertyTypeModifiers: [DicomCodedConcept]
    public let anatomicRegion: DicomCodedConcept?
    public let anatomicRegionModifiers: [DicomCodedConcept]
    public let algorithmIdentification: DicomAlgorithmIdentification?
    public let algorithmType: String?
    public let trackingID: String?
    public let trackingUID: String?

    /// Creates segment semantics for validated referenced surfaces.
    public init(
        number: Int,
        label: String,
        recommendedDisplayCIELabValue: [UInt16] = [],
        referencedSurfaceNumbers: [Int],
        sourceImageReferences: [DicomSourceImageReference] = [],
        description: String? = nil,
        propertyCategory: DicomCodedConcept? = nil,
        propertyType: DicomCodedConcept? = nil,
        propertyTypeModifiers: [DicomCodedConcept] = [],
        anatomicRegion: DicomCodedConcept? = nil,
        anatomicRegionModifiers: [DicomCodedConcept] = [],
        algorithmIdentification: DicomAlgorithmIdentification? = nil,
        algorithmType: String? = nil,
        trackingID: String? = nil,
        trackingUID: String? = nil
    ) {
        self.number = number
        self.label = label
        self.recommendedDisplayCIELabValue = recommendedDisplayCIELabValue
        self.referencedSurfaceNumbers = referencedSurfaceNumbers
        self.sourceImageReferences = sourceImageReferences
        self.description = description
        self.propertyCategory = propertyCategory
        self.propertyType = propertyType
        self.propertyTypeModifiers = propertyTypeModifiers
        self.anatomicRegion = anatomicRegion
        self.anatomicRegionModifiers = anatomicRegionModifiers
        self.algorithmIdentification = algorithmIdentification
        self.algorithmType = algorithmType
        self.trackingID = trackingID
        self.trackingUID = trackingUID
    }
}
