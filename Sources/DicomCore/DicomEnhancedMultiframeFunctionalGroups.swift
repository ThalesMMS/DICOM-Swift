import Foundation
import simd

/// Parsed Enhanced Multi-frame functional groups with resolved per-frame metadata.
public struct DicomEnhancedMultiframeFunctionalGroups: Equatable, Sendable {
    public let shared: DicomFrameFunctionalGroups?
    public let perFrame: [DicomFrameFunctionalGroups]
    public let declaredFrameCount: Int
    public let frames: [DicomEnhancedFrame]
    public let dimensionOrganization: DicomEnhancedDimensionOrganization?

    public init(
        shared: DicomFrameFunctionalGroups?,
        perFrame: [DicomFrameFunctionalGroups],
        declaredFrameCount: Int,
        dimensionOrganization: DicomEnhancedDimensionOrganization? = nil
    ) {
        let frameCount = max(declaredFrameCount, perFrame.count)
        self.shared = shared
        self.perFrame = perFrame
        self.declaredFrameCount = declaredFrameCount
        self.dimensionOrganization = dimensionOrganization
        self.frames = (0..<frameCount).map { index in
            let resolved = perFrame[safe: index]?.resolving(shared: shared) ?? DicomFrameFunctionalGroups().resolving(shared: shared)
            return DicomEnhancedFrame(index: index, functionalGroups: resolved)
        }
    }

    public var frameCount: Int {
        frames.count
    }

    /// Frames sorted for volume/MPR construction using patient-space position when available.
    public var framesInSpatialOrder: [DicomEnhancedFrame] {
        frames.sorted { lhs, rhs in
            if lhs.functionalGroups.frameContent?.stackID != rhs.functionalGroups.frameContent?.stackID {
                return (lhs.functionalGroups.frameContent?.stackID ?? "") < (rhs.functionalGroups.frameContent?.stackID ?? "")
            }
            if let left = lhs.geometry?.positionAlongNormal,
               let right = rhs.geometry?.positionAlongNormal,
               left != right {
                return left < right
            }
            if let left = lhs.functionalGroups.frameContent?.inStackPositionNumber,
               let right = rhs.functionalGroups.frameContent?.inStackPositionNumber,
               left != right {
                return left < right
            }
            return lhs.index < rhs.index
        }
    }

    /// Frames sorted for cine/playback using temporal frame content when available.
    public var framesInTemporalOrder: [DicomEnhancedFrame] {
        frames.sorted { lhs, rhs in
            if let left = lhs.functionalGroups.frameContent?.temporalPositionIndex,
               let right = rhs.functionalGroups.frameContent?.temporalPositionIndex,
               left != right {
                return left < right
            }
            if let left = lhs.functionalGroups.frameContent?.frameAcquisitionNumber,
               let right = rhs.functionalGroups.frameContent?.frameAcquisitionNumber,
               left != right {
                return left < right
            }
            return lhs.index < rhs.index
        }
    }

    public func geometry(forFrame index: Int) -> DicomFrameGeometry? {
        frames[safe: index]?.geometry
    }
}

/// Dimension Organization and Dimension Index definitions that describe how
/// Enhanced frames are partitioned into logical stacks and other dimensions.
public struct DicomEnhancedDimensionOrganization: Equatable, Sendable {
    public let organizationUIDs: [String]
    public let indexes: [DicomEnhancedDimensionIndex]

    public init(organizationUIDs: [String], indexes: [DicomEnhancedDimensionIndex]) {
        self.organizationUIDs = organizationUIDs
        self.indexes = indexes
    }
}

/// One top-level Dimension Index Sequence item. Optional fields are preserved
/// so the volume validator can reject malformed definitions instead of
/// silently dropping them during parsing.
public struct DicomEnhancedDimensionIndex: Hashable, Sendable {
    public let organizationUID: String?
    public let dimensionIndexPointer: Int?
    public let functionalGroupPointer: Int?
    public let dimensionIndexPrivateCreator: String?
    public let functionalGroupPrivateCreator: String?
    public let descriptionLabel: String?

    public init(
        organizationUID: String?,
        dimensionIndexPointer: Int?,
        functionalGroupPointer: Int?,
        dimensionIndexPrivateCreator: String? = nil,
        functionalGroupPrivateCreator: String? = nil,
        descriptionLabel: String? = nil
    ) {
        self.organizationUID = organizationUID
        self.dimensionIndexPointer = dimensionIndexPointer
        self.functionalGroupPointer = functionalGroupPointer
        self.dimensionIndexPrivateCreator = dimensionIndexPrivateCreator
        self.functionalGroupPrivateCreator = functionalGroupPrivateCreator
        self.descriptionLabel = descriptionLabel
    }
}

/// Functional group macros resolved for one frame.
public struct DicomFrameFunctionalGroups: Equatable, Sendable {
    public let frameContent: DicomFrameContent?
    public let pixelMeasures: DicomPixelMeasures?
    public let planePosition: DicomPlanePosition?
    public let planeOrientation: DicomPlaneOrientation?
    public let derivationImage: DicomDerivationImage?
    public let pixelValueTransformation: DicomPixelValueTransformation?
    public let frameVOI: DicomFrameVOI?

    public init(
        frameContent: DicomFrameContent? = nil,
        pixelMeasures: DicomPixelMeasures? = nil,
        planePosition: DicomPlanePosition? = nil,
        planeOrientation: DicomPlaneOrientation? = nil,
        derivationImage: DicomDerivationImage? = nil,
        pixelValueTransformation: DicomPixelValueTransformation? = nil,
        frameVOI: DicomFrameVOI? = nil
    ) {
        self.frameContent = frameContent
        self.pixelMeasures = pixelMeasures
        self.planePosition = planePosition
        self.planeOrientation = planeOrientation
        self.derivationImage = derivationImage
        self.pixelValueTransformation = pixelValueTransformation
        self.frameVOI = frameVOI
    }

    public func resolving(shared: DicomFrameFunctionalGroups?) -> DicomFrameFunctionalGroups {
        DicomFrameFunctionalGroups(
            frameContent: frameContent ?? shared?.frameContent,
            pixelMeasures: pixelMeasures ?? shared?.pixelMeasures,
            planePosition: planePosition ?? shared?.planePosition,
            planeOrientation: planeOrientation ?? shared?.planeOrientation,
            derivationImage: derivationImage ?? shared?.derivationImage,
            pixelValueTransformation: pixelValueTransformation ?? shared?.pixelValueTransformation,
            frameVOI: frameVOI ?? shared?.frameVOI
        )
    }
}

/// One zero-based Enhanced Multi-frame frame with resolved functional groups.
public struct DicomEnhancedFrame: Equatable, Sendable {
    public let index: Int
    public let functionalGroups: DicomFrameFunctionalGroups
    public let geometry: DicomFrameGeometry?

    public init(index: Int, functionalGroups: DicomFrameFunctionalGroups) {
        self.index = index
        self.functionalGroups = functionalGroups
        self.geometry = DicomFrameGeometry(frameIndex: index, functionalGroups: functionalGroups)
    }
}

/// Frame Content Functional Group values used for spatial and temporal ordering.
public struct DicomFrameContent: Equatable, Sendable {
    public let dimensionIndexValues: [Int]
    public let stackID: String?
    public let inStackPositionNumber: Int?
    public let temporalPositionIndex: Int?
    public let frameAcquisitionNumber: Int?

    public init(
        dimensionIndexValues: [Int],
        stackID: String?,
        inStackPositionNumber: Int?,
        temporalPositionIndex: Int?,
        frameAcquisitionNumber: Int?
    ) {
        self.dimensionIndexValues = dimensionIndexValues
        self.stackID = stackID
        self.inStackPositionNumber = inStackPositionNumber
        self.temporalPositionIndex = temporalPositionIndex
        self.frameAcquisitionNumber = frameAcquisitionNumber
    }
}

/// Pixel Measures Functional Group values for physical pixel geometry.
public struct DicomPixelMeasures: Equatable, Sendable {
    public let pixelSpacing: SIMD2<Double>?
    public let sliceThickness: Double?
    public let spacingBetweenSlices: Double?

    public init(
        pixelSpacing: SIMD2<Double>?,
        sliceThickness: Double?,
        spacingBetweenSlices: Double?
    ) {
        self.pixelSpacing = pixelSpacing
        self.sliceThickness = sliceThickness
        self.spacingBetweenSlices = spacingBetweenSlices
    }
}

/// Pixel Value Transformation Functional Group rescale values.
public struct DicomPixelValueTransformation: Equatable, Sendable {
    public let rescaleIntercept: Double
    public let rescaleSlope: Double

    public init(rescaleIntercept: Double, rescaleSlope: Double) {
        self.rescaleIntercept = rescaleIntercept
        self.rescaleSlope = rescaleSlope
    }
}

/// Plane Position Functional Group values in patient coordinates.
public struct DicomPlanePosition: Equatable, Sendable {
    public let imagePositionPatient: SIMD3<Double>

    public init(imagePositionPatient: SIMD3<Double>) {
        self.imagePositionPatient = imagePositionPatient
    }
}

/// Plane Orientation Functional Group direction cosines in patient coordinates.
public struct DicomPlaneOrientation: Equatable, Sendable {
    public let row: SIMD3<Double>
    public let column: SIMD3<Double>

    public init(row: SIMD3<Double>, column: SIMD3<Double>) {
        self.row = row
        self.column = column
    }

    public var normal: SIMD3<Double> {
        simd_cross(row, column)
    }
}

/// Derivation Image Functional Group source references.
public struct DicomDerivationImage: Equatable, Sendable {
    public let sourceImages: [DicomSourceImageReference]

    public init(sourceImages: [DicomSourceImageReference]) {
        self.sourceImages = sourceImages
    }
}

/// Source image reference for a derived Enhanced Multi-frame frame.
public struct DicomSourceImageReference: Equatable, Sendable {
    public let referencedSOPClassUID: String?
    public let referencedSOPInstanceUID: String?
    public let referencedFrameNumbers: [Int]
    public let referencedSegmentNumbers: [Int]
    public let referencedWaveformChannels: [Int]
    public let derivationCode: DicomCodedConcept?
    public let purposeOfReferenceCode: DicomCodedConcept?

    public init(
        referencedSOPClassUID: String?,
        referencedSOPInstanceUID: String?,
        referencedFrameNumbers: [Int] = [],
        referencedSegmentNumbers: [Int] = [],
        referencedWaveformChannels: [Int] = [],
        derivationCode: DicomCodedConcept? = nil,
        purposeOfReferenceCode: DicomCodedConcept? = nil
    ) {
        self.referencedSOPClassUID = referencedSOPClassUID
        self.referencedSOPInstanceUID = referencedSOPInstanceUID
        self.referencedFrameNumbers = referencedFrameNumbers
        self.referencedSegmentNumbers = referencedSegmentNumbers
        self.referencedWaveformChannels = referencedWaveformChannels
        self.derivationCode = derivationCode
        self.purposeOfReferenceCode = purposeOfReferenceCode
    }
}

/// Resolved frame geometry suitable for volume, MPR, and cine consumers.
public struct DicomFrameGeometry: Equatable, Sendable {
    public let frameIndex: Int
    public let imagePositionPatient: SIMD3<Double>?
    public let imageOrientationPatient: DicomPlaneOrientation?
    public let pixelMeasures: DicomPixelMeasures?
    public let frameContent: DicomFrameContent?
    public let sourceImageReferences: [DicomSourceImageReference]

    public init?(frameIndex: Int, functionalGroups: DicomFrameFunctionalGroups) {
        guard functionalGroups.planePosition != nil ||
              functionalGroups.planeOrientation != nil ||
              functionalGroups.pixelMeasures != nil ||
              functionalGroups.frameContent != nil ||
              functionalGroups.derivationImage != nil else {
            return nil
        }

        self.frameIndex = frameIndex
        self.imagePositionPatient = functionalGroups.planePosition?.imagePositionPatient
        self.imageOrientationPatient = functionalGroups.planeOrientation
        self.pixelMeasures = functionalGroups.pixelMeasures
        self.frameContent = functionalGroups.frameContent
        self.sourceImageReferences = functionalGroups.derivationImage?.sourceImages ?? []
    }

    public init(
        frameIndex: Int,
        imagePositionPatient: SIMD3<Double>? = nil,
        imageOrientationPatient: DicomPlaneOrientation? = nil,
        pixelMeasures: DicomPixelMeasures? = nil,
        frameContent: DicomFrameContent? = nil,
        sourceImageReferences: [DicomSourceImageReference] = []
    ) {
        self.frameIndex = frameIndex
        self.imagePositionPatient = imagePositionPatient
        self.imageOrientationPatient = imageOrientationPatient
        self.pixelMeasures = pixelMeasures
        self.frameContent = frameContent
        self.sourceImageReferences = sourceImageReferences
    }

    public var positionAlongNormal: Double? {
        guard let position = imagePositionPatient,
              let normal = imageOrientationPatient?.normal else {
            return nil
        }
        return simd_dot(position, normal)
    }
}

enum DicomEnhancedMultiframeParser {
    static func makeFunctionalGroups(
        sharedItems: [DicomSequenceItem],
        perFrameItems: [DicomSequenceItem],
        declaredFrameCount: Int,
        dimensionOrganizationItems: [DicomSequenceItem] = [],
        dimensionIndexItems: [DicomSequenceItem] = [],
        littleEndian: Bool = true
    ) -> DicomEnhancedMultiframeFunctionalGroups? {
        guard !sharedItems.isEmpty || !perFrameItems.isEmpty else { return nil }
        return DicomEnhancedMultiframeFunctionalGroups(
            shared: sharedItems.first.map { functionalGroups(from: $0.dataSet, littleEndian: littleEndian) },
            perFrame: perFrameItems.map { functionalGroups(from: $0.dataSet, littleEndian: littleEndian) },
            declaredFrameCount: declaredFrameCount,
            dimensionOrganization: dimensionOrganization(
                organizationItems: dimensionOrganizationItems,
                indexItems: dimensionIndexItems
            )
        )
    }

    private static func dimensionOrganization(
        organizationItems: [DicomSequenceItem],
        indexItems: [DicomSequenceItem]
    ) -> DicomEnhancedDimensionOrganization? {
        guard !organizationItems.isEmpty || !indexItems.isEmpty else { return nil }
        return DicomEnhancedDimensionOrganization(
            organizationUIDs: organizationItems.compactMap {
                $0.dataSet.string(for: .dimensionOrganizationUID)
            },
            indexes: indexItems.map { item in
                DicomEnhancedDimensionIndex(
                    organizationUID: item.dataSet.string(for: .dimensionOrganizationUID),
                    dimensionIndexPointer: item.dataSet.int(for: .dimensionIndexPointer),
                    functionalGroupPointer: item.dataSet.int(for: .functionalGroupPointer),
                    dimensionIndexPrivateCreator: item.dataSet.string(for: 0x0020_9213),
                    functionalGroupPrivateCreator: item.dataSet.string(for: 0x0020_9238),
                    descriptionLabel: item.dataSet.string(for: 0x0020_9421)
                )
            }
        )
    }

    private static func functionalGroups(
        from dataSet: DicomDataSet,
        littleEndian: Bool
    ) -> DicomFrameFunctionalGroups {
        DicomFrameFunctionalGroups(
            frameContent: dataSet.firstNestedDataSet(for: .frameContentSequence).flatMap(frameContent),
            pixelMeasures: dataSet.firstNestedDataSet(for: .pixelMeasuresSequence).flatMap(pixelMeasures),
            planePosition: dataSet.firstNestedDataSet(for: .planePositionSequence).flatMap(planePosition),
            planeOrientation: dataSet.firstNestedDataSet(for: .planeOrientationSequence).flatMap(planeOrientation),
            derivationImage: derivationImage(from: dataSet.sequenceItems(for: .derivationImageSequence)),
            pixelValueTransformation: dataSet.firstNestedDataSet(for: .pixelValueTransformationSequence)
                .flatMap(pixelValueTransformation),
            frameVOI: dataSet.firstNestedDataSet(for: .frameVOILUTSequence).flatMap {
                frameVOI(from: $0, littleEndian: littleEndian)
            }
        )
    }

    private static func frameVOI(
        from dataSet: DicomDataSet,
        littleEndian: Bool
    ) -> DicomFrameVOI? {
        let centers = dataSet.decimalStrings(for: .windowCenter)
        let widths = dataSet.decimalStrings(for: .windowWidth)
        let explanations = dataSet.strings(for: .windowCenterWidthExplanation)
        let windows = (0..<min(centers.count, widths.count)).compactMap { index in
            DicomFrameVOIWindow(
                center: centers[index],
                width: widths[index],
                explanation: explanations[safe: index]
            )
        }
        let voiLUTs = DicomVOILUTValidator.validate(
            items: dataSet.sequenceItems(for: .voiLUTSequence),
            littleEndian: littleEndian
        ).accepted
        guard !windows.isEmpty || !voiLUTs.isEmpty else { return nil }
        let normalizedFunction = dataSet.string(for: .voiLUTFunction)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let lutFunction = normalizedFunction?.isEmpty == false ? normalizedFunction : nil
        return DicomFrameVOI(windows: windows, voiLUTs: voiLUTs, lutFunction: lutFunction)
    }

    private static func pixelValueTransformation(from dataSet: DicomDataSet) -> DicomPixelValueTransformation? {
        let intercept = dataSet.decimalString(for: .rescaleIntercept)
        let slope = dataSet.decimalString(for: .rescaleSlope)
        guard intercept != nil || slope != nil else { return nil }
        return DicomPixelValueTransformation(
            rescaleIntercept: intercept ?? 0,
            rescaleSlope: slope ?? 1
        )
    }

    private static func frameContent(from dataSet: DicomDataSet) -> DicomFrameContent? {
        let dimensionIndexValues = dataSet.ints(for: .dimensionIndexValues)
        let stackID = dataSet.string(for: .stackID)
        let inStackPositionNumber = dataSet.int(for: .inStackPositionNumber)
        let temporalPositionIndex = dataSet.int(for: .temporalPositionIndex)
        let frameAcquisitionNumber = dataSet.int(for: .frameAcquisitionNumber)
        guard !dimensionIndexValues.isEmpty ||
              stackID != nil ||
              inStackPositionNumber != nil ||
              temporalPositionIndex != nil ||
              frameAcquisitionNumber != nil else {
            return nil
        }
        return DicomFrameContent(
            dimensionIndexValues: dimensionIndexValues,
            stackID: stackID,
            inStackPositionNumber: inStackPositionNumber,
            temporalPositionIndex: temporalPositionIndex,
            frameAcquisitionNumber: frameAcquisitionNumber
        )
    }

    private static func pixelMeasures(from dataSet: DicomDataSet) -> DicomPixelMeasures? {
        let spacing = dataSet.decimalStrings(for: .pixelSpacing)
        let pixelSpacing = spacing.count >= 2 ? SIMD2<Double>(spacing[0], spacing[1]) : nil
        let sliceThickness = dataSet.decimalString(for: .sliceThickness)
        let spacingBetweenSlices = dataSet.decimalString(for: .sliceSpacing)
        guard pixelSpacing != nil || sliceThickness != nil || spacingBetweenSlices != nil else {
            return nil
        }
        return DicomPixelMeasures(
            pixelSpacing: pixelSpacing,
            sliceThickness: sliceThickness,
            spacingBetweenSlices: spacingBetweenSlices
        )
    }

    private static func planePosition(from dataSet: DicomDataSet) -> DicomPlanePosition? {
        guard let position = vector3(from: dataSet.decimalStrings(for: .imagePositionPatient)) else {
            return nil
        }
        return DicomPlanePosition(imagePositionPatient: position)
    }

    private static func planeOrientation(from dataSet: DicomDataSet) -> DicomPlaneOrientation? {
        let values = dataSet.decimalStrings(for: .imageOrientationPatient)
        guard values.count >= 6 else { return nil }
        return DicomPlaneOrientation(
            row: SIMD3<Double>(values[0], values[1], values[2]),
            column: SIMD3<Double>(values[3], values[4], values[5])
        )
    }

    private static func derivationImage(from items: [DicomSequenceItem]) -> DicomDerivationImage? {
        let sources = items.flatMap { item in
            item.dataSet.sequenceItems(for: .sourceImageSequence).map { source in
                sourceImageReference(from: source, derivationCode: item.dataSet[0x00089215]?.sequenceItems.first
                    .flatMap { DicomCodedConcept(dataSet: $0.dataSet) })
            }
        }
        return sources.isEmpty ? nil : DicomDerivationImage(sourceImages: sources)
    }

    private static func sourceImageReference(from item: DicomSequenceItem, derivationCode: DicomCodedConcept?) -> DicomSourceImageReference {
        DicomSourceImageReference(
            referencedSOPClassUID: item.dataSet.string(for: .referencedSOPClassUID),
            referencedSOPInstanceUID: item.dataSet.string(for: .referencedSOPInstanceUID),
            referencedFrameNumbers: item.dataSet.ints(for: .referencedFrameNumber),
            referencedSegmentNumbers: item.dataSet.ints(for: 0x0062000B),
            referencedWaveformChannels: item.dataSet.ints(for: 0x0040A0B0),
            derivationCode: derivationCode,
            purposeOfReferenceCode: item.dataSet[0x0040A170]?.sequenceItems.first
                .flatMap { DicomCodedConcept(dataSet: $0.dataSet) }
        )
    }

    private static func vector3(from values: [Double]) -> SIMD3<Double>? {
        guard values.count >= 3 else { return nil }
        return SIMD3<Double>(values[0], values[1], values[2])
    }
}

private extension DicomDataSet {
    func firstNestedDataSet(for tag: DicomTag) -> DicomDataSet? {
        sequenceItems(for: tag).first?.dataSet
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
