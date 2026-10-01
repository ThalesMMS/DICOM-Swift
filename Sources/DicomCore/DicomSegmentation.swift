import Foundation

/// DICOM Segmentation Type (0062,0001).
public enum DicomSegmentationType: String, Equatable, Sendable {
    case binary = "BINARY"
    case fractional = "FRACTIONAL"
    case labelmap = "LABELMAP"
    /// The source type was absent or unrecognized; no pixel interpretation is guessed.
    case unknown = "UNKNOWN"
}

/// DICOM Segmentation Fractional Type (0062,0010).
public enum DicomSegmentationFractionalType: String, Equatable, Sendable {
    case probability = "PROBABILITY"
    case occupancy = "OCCUPANCY"
}

/// Metadata for one item in Segment Sequence (0062,0002).
public struct DicomSegment: Equatable, Hashable, Sendable {
    public let number: Int
    public let label: String
    public let description: String?
    public let algorithmType: String?
    public let algorithmName: String?
    public let propertyCategory: DicomCodedConcept?
    public let propertyType: DicomCodedConcept?
    public let trackingID: String?
    public let trackingUID: String?
    public let recommendedDisplayCIELabValue: [UInt16]
    public let algorithmIdentification: DicomSegmentAlgorithmIdentification?
    public let anatomicRegion: DicomCodedConcept?
    public let anatomicRegionModifiers: [DicomCodedConcept]
    public let propertyTypeModifiers: [DicomCodedConcept]
    public let recommendedDisplayGrayscaleValue: UInt16?


    public init(
        number: Int,
        label: String,
        description: String? = nil,
        algorithmType: String? = nil,
        algorithmName: String? = nil,
        propertyCategory: DicomCodedConcept? = nil,
        propertyType: DicomCodedConcept? = nil,
        trackingID: String? = nil,
        trackingUID: String? = nil,
        recommendedDisplayCIELabValue: [UInt16] = [],
        algorithmIdentification: DicomSegmentAlgorithmIdentification? = nil,
        anatomicRegion: DicomCodedConcept? = nil,
        anatomicRegionModifiers: [DicomCodedConcept] = [],
        propertyTypeModifiers: [DicomCodedConcept] = [],
        recommendedDisplayGrayscaleValue: UInt16? = nil
    ) {
        self.number = number
        self.label = label
        self.description = description?.dicomSegNonEmptyValue
        self.algorithmType = algorithmType?.dicomSegNonEmptyValue
        self.algorithmName = algorithmName?.dicomSegNonEmptyValue
        self.propertyCategory = propertyCategory
        self.propertyType = propertyType
        self.trackingID = trackingID?.dicomSegNonEmptyValue
        self.trackingUID = trackingUID?.dicomSegNonEmptyValue
        self.recommendedDisplayCIELabValue = recommendedDisplayCIELabValue
        self.algorithmIdentification = algorithmIdentification
        self.anatomicRegion = anatomicRegion
        self.anatomicRegionModifiers = anatomicRegionModifiers
        self.propertyTypeModifiers = propertyTypeModifiers
        self.recommendedDisplayGrayscaleValue = recommendedDisplayGrayscaleValue

    }
}

/// Row-major pixel data for one SEG frame.
public enum DicomSegmentationPixelData: Equatable, Sendable {
    case binary([UInt8])
    case labelmap(DicomLabelmapPlane)
    case uninterpreted(Data)
    case fractional(values: [UInt8], maximumFractionalValue: Int)

    public var storedValues: [UInt8] {
        switch self {
        case .labelmap, .uninterpreted:
            return []
        case .binary(let values):
            return values
        case .fractional(let values, _):
            return values
        }
    }

    public var maximumFractionalValue: Int? {
        if case .fractional(_, let maximum) = self {
            return maximum
        }
        return nil
    }

    /// Stored labels at their stored width, without copying.
    public var labelmapPlane: DicomLabelmapPlane? {
        if case .labelmap(let plane) = self { return plane }
        return nil
    }

    /// Stored label values, without truncation or fractional conversion. Allocates a
    /// 16-bit copy; use `labelmapPlane` to read the labels at their stored width.
    public var labelmapValues: [UInt16]? {
        labelmapPlane?.widened
    }

    /// Converts stored mask values to a label using an explicit inclusive threshold.
    public func binarized(threshold: UInt8, comparison: DicomSegmentationThresholdComparison = .greaterThanOrEqual,
                          label: UInt16 = 1) -> [UInt16] {
        storedValues.map { $0 >= threshold ? label : 0 }
    }

    @available(*, deprecated, message: "Use binarized(threshold:comparison:label:) explicitly for fractional masks")
    public func labelmapVoxels(label: UInt16) -> [UInt16] {
        binarized(threshold: 1, label: label)
    }
}

/// One decoded SEG frame with its referenced segment and resolved geometry.
public struct DicomSegmentationFrame: Equatable, Sendable {
    public let index: Int
    public let segmentNumber: Int
    public let segmentAttribution: DicomSegmentationSegmentAttribution
    public let geometry: DicomFrameGeometry?
    public let sourceImageReferences: [DicomSourceImageReference]
    public let pixelData: DicomSegmentationPixelData

    public init(
        index: Int,
        segmentNumber: Int,
        geometry: DicomFrameGeometry? = nil,
        sourceImageReferences: [DicomSourceImageReference] = [],
        pixelData: DicomSegmentationPixelData,
        segmentAttribution: DicomSegmentationSegmentAttribution = .declared
    ) {
        self.index = index
        self.segmentNumber = segmentNumber
        self.segmentAttribution = segmentAttribution
        self.geometry = geometry
        self.sourceImageReferences = sourceImageReferences
        self.pixelData = pixelData
    }
}

/// Segment-scoped labelmap assembled from all frames that reference one segment.
public struct DicomSegmentLabelmap: Equatable, Sendable {
    public let segment: DicomSegment
    public let rows: Int
    public let columns: Int
    public let frameIndexes: [Int]
    public let geometry: [DicomFrameGeometry?]
    public let sourceImageReferences: [[DicomSourceImageReference]]
    private let binaryVoxels: [UInt16]
    @available(*, deprecated, message: "Use fractionalVoxels or explicit binarized(threshold:comparison:)")
    public var voxels: [UInt16] {
        fractionalVoxels == nil ? binaryVoxels : binarized(threshold: 1)
    }

    /// Inclusive threshold in stored fractional units; output values use this segment's number.
    public func binarized(threshold: UInt8,
                          comparison: DicomSegmentationThresholdComparison = .greaterThanOrEqual) -> [UInt16] {
        guard let fractionalVoxels else { return binaryVoxels }
        return fractionalVoxels.map { $0 >= threshold ? UInt16(clamping: segment.number) : 0 }
    }
    public let fractionalVoxels: [UInt8]?

    public init(
        segment: DicomSegment,
        rows: Int,
        columns: Int,
        frameIndexes: [Int],
        geometry: [DicomFrameGeometry?],
        sourceImageReferences: [[DicomSourceImageReference]],
        voxels: [UInt16],
        fractionalVoxels: [UInt8]? = nil
    ) {
        self.segment = segment
        self.rows = rows
        self.columns = columns
        self.frameIndexes = frameIndexes
        self.geometry = geometry
        self.sourceImageReferences = sourceImageReferences
        self.binaryVoxels = voxels
        self.fractionalVoxels = fractionalVoxels
    }
}

/// Parsed DICOM Segmentation object with segment metadata, frames, and labelmaps.
public struct DicomSegmentation: Equatable, Sendable {
    public let sopInstanceUID: String?
    /// Frame of Reference UID (0020,0052) of the segmented coordinate system, when the object declares one.
    public let frameOfReferenceUID: String?
    public let segmentationType: DicomSegmentationType
    public let fractionalType: DicomSegmentationFractionalType?
    public let maximumFractionalValue: Int
    public let rows: Int
    public let columns: Int
    public let referencedSeriesInstanceUIDs: [String]
    public let segments: [DicomSegment]
    public let frames: [DicomSegmentationFrame]
    /// LABELMAP planes in source frame order, widened to 16 bits. Sparse positions are never expanded.
    public var labelmapVoxelsByFrame: [[UInt16]] { frames.compactMap { $0.pixelData.labelmapValues } }
    public let segmentsOverlap: DicomSegmentsOverlap?
    public let contentLabel: String?
    public let contentDescription: String?
    public let contentCreatorName: String?
    public let referencedInstancesBySeries: [String: [DicomSourceImageReference]]
    public let sharedFunctionalGroups: Set<DicomSegmentationFunctionalGroup>
    public let diagnostics: [DicomSegmentationDiagnostic]
    public let photometricInterpretation: String
    public let pixelPaddingValue: UInt16?
    public let paletteColorElements: [DicomDataElement]


    public init(
        sopInstanceUID: String? = nil,
        frameOfReferenceUID: String? = nil,
        segmentationType: DicomSegmentationType,
        fractionalType: DicomSegmentationFractionalType? = nil,
        maximumFractionalValue: Int = 255,
        rows: Int,
        columns: Int,
        referencedSeriesInstanceUIDs: [String] = [],
        segments: [DicomSegment],
        frames: [DicomSegmentationFrame],
        segmentsOverlap: DicomSegmentsOverlap? = nil,
        contentLabel: String? = nil,
        contentDescription: String? = nil,
        contentCreatorName: String? = nil,
        referencedInstancesBySeries: [String: [DicomSourceImageReference]] = [:],
        sharedFunctionalGroups: Set<DicomSegmentationFunctionalGroup> = [],
        diagnostics: [DicomSegmentationDiagnostic] = [],
        photometricInterpretation: String = "MONOCHROME2",
        pixelPaddingValue: UInt16? = nil,
        paletteColorElements: [DicomDataElement] = []
    ) {
        self.sopInstanceUID = sopInstanceUID?.dicomSegNonEmptyValue
        self.frameOfReferenceUID = frameOfReferenceUID?.dicomSegNonEmptyValue
        self.segmentationType = segmentationType
        self.fractionalType = fractionalType
        self.maximumFractionalValue = maximumFractionalValue
        self.rows = rows
        self.columns = columns
        self.referencedSeriesInstanceUIDs = referencedSeriesInstanceUIDs.compactMap(\.dicomSegNonEmptyValue)
        self.segments = segments
        self.frames = frames
        self.segmentsOverlap = segmentsOverlap
        self.contentLabel = contentLabel
        self.contentDescription = contentDescription
        self.contentCreatorName = contentCreatorName
        self.referencedInstancesBySeries = referencedInstancesBySeries
        self.sharedFunctionalGroups = sharedFunctionalGroups
        self.diagnostics = diagnostics
        self.photometricInterpretation = photometricInterpretation
        self.pixelPaddingValue = pixelPaddingValue
        self.paletteColorElements = paletteColorElements
    }

    /// Every segment's voxels assembled over its frames. Built on each access: a label map
    /// expands to one full volume per segment, so prefer `labelmap(forSegment:)`.
    public var labelmapsBySegment: [Int: DicomSegmentLabelmap] {
        segments.reduce(into: [:]) { labelmaps, segment in
            labelmaps[segment.number] = labelmap(forSegment: segment.number)
        }
    }

    public var labelmaps: [DicomSegmentLabelmap] {
        segments.compactMap { labelmap(forSegment: $0.number) }
    }

    /// One segment's voxels assembled over the frames that reference it, or nil when the
    /// segment is not declared or has no frames.
    public func labelmap(forSegment number: Int) -> DicomSegmentLabelmap? {
        guard let segment = segments.first(where: { $0.number == number }) else { return nil }
        let segmentFrames = frames.filter {
            $0.pixelData.labelmapPlane != nil || ($0.segmentAttribution != .unattributed && $0.segmentNumber == number)
        }
        guard !segmentFrames.isEmpty else { return nil }
        let label = UInt16(clamping: number)
        let voxels = segmentFrames.flatMap { frame -> [UInt16] in
            if let plane = frame.pixelData.labelmapPlane { return plane.isolating(label) }
            return frame.pixelData.maximumFractionalValue == nil
                ? frame.pixelData.binarized(threshold: 1, label: label) : []
        }
        let fractionalVoxels = segmentFrames.contains { $0.pixelData.maximumFractionalValue != nil }
            ? segmentFrames.flatMap(\.pixelData.storedValues)
            : nil
        return DicomSegmentLabelmap(
            segment: segment,
            rows: rows,
            columns: columns,
            frameIndexes: segmentFrames.map(\.index),
            geometry: segmentFrames.map(\.geometry),
            sourceImageReferences: segmentFrames.map(\.sourceImageReferences),
            voxels: voxels,
            fractionalVoxels: fractionalVoxels
        )
    }

    /// The largest label stored in any LABELMAP frame, or 0 without LABELMAP frames.
    public var maximumLabelValue: UInt16 {
        frames.reduce(0) { max($0, $1.pixelData.labelmapPlane?.maximum ?? 0) }
    }

    /// The declared segment a LABELMAP object treats as background (PS3.3 C.8.20.2.4): the one
    /// whose number is the Pixel Padding Value, else one typed (125040, DCM, "Background").
    public var backgroundSegmentNumber: Int? {
        guard segmentationType == .labelmap else { return nil }
        if let padding = pixelPaddingValue, segments.contains(where: { $0.number == Int(padding) }) {
            return Int(padding)
        }
        return segments.first {
            $0.propertyType?.codeValue == "125040" && $0.propertyType?.codingSchemeDesignator == "DCM"
        }?.number
    }
}

/// Patient, study, equipment and content provenance the Segmentation IOD (PS3.3 A.51) requires
/// beyond the segment model. Type 2 identification defaults to empty values; the Enhanced General
/// Equipment values default to this library; Content Date/Time default to the build time.
public struct DicomSegmentationBuildOptions: Sendable, Equatable {
    public var patientName: String
    public var patientID: String
    public var patientBirthDate: String
    public var patientSex: String
    public var studyDate: String
    public var studyTime: String
    public var referringPhysicianName: String
    public var studyID: String
    public var accessionNumber: String
    public var seriesNumber: Int
    public var instanceNumber: Int
    public var contentDate: String?
    public var contentTime: String?
    public var timezoneOffsetFromUTC: String?
    public var contentDescription: String
    public var contentCreatorName: String?
    public var manufacturer: String
    public var manufacturerModelName: String
    public var deviceSerialNumber: String
    public var softwareVersions: String
    public var positionReferenceIndicator: String
    /// Dimension Organization UID; derived from the SOP Instance UID when nil.
    public var dimensionOrganizationUID: String?
    /// Segment Algorithm Type, property category and type used when a segment does not state them.
    public var defaultAlgorithmType: String?
    public var defaultPropertyCategory: DicomCodedConcept?
    public var defaultPropertyType: DicomCodedConcept?
    /// Referenced Instance Sequence content per referenced series; a single referenced series
    /// collects the frames' source images when this map is empty.
    public var referencedInstancesBySeries: [String: [DicomSourceImageReference]]
    /// Series Description (0008,103E), written when set.
    public var seriesDescription: String?
    /// Specific Character Set (0008,0005), written when set; text values are encoded with it.
    public var specificCharacterSet: String?

    public init(
        patientName: String = "",
        patientID: String = "",
        patientBirthDate: String = "",
        patientSex: String = "",
        studyDate: String = "",
        studyTime: String = "",
        referringPhysicianName: String = "",
        studyID: String = "",
        accessionNumber: String = "",
        seriesNumber: Int = 1,
        instanceNumber: Int = 1,
        contentDate: String? = nil,
        contentTime: String? = nil,
        timezoneOffsetFromUTC: String? = nil,
        contentDescription: String = "",
        contentCreatorName: String? = nil,
        manufacturer: String = "DICOM-Swift",
        manufacturerModelName: String = "DicomSegmentationBuilder",
        deviceSerialNumber: String = "DICOM-Swift",
        softwareVersions: String = "DICOM-Swift",
        positionReferenceIndicator: String = "",
        dimensionOrganizationUID: String? = nil,
        defaultAlgorithmType: String? = nil,
        defaultPropertyCategory: DicomCodedConcept? = nil,
        defaultPropertyType: DicomCodedConcept? = nil,
        referencedInstancesBySeries: [String: [DicomSourceImageReference]] = [:]
    ) {
        self.patientName = patientName
        self.patientID = patientID
        self.patientBirthDate = patientBirthDate
        self.patientSex = patientSex
        self.studyDate = studyDate
        self.studyTime = studyTime
        self.referringPhysicianName = referringPhysicianName
        self.studyID = studyID
        self.accessionNumber = accessionNumber
        self.seriesNumber = seriesNumber
        self.instanceNumber = instanceNumber
        self.contentDate = contentDate?.dicomSegNonEmptyValue
        self.contentTime = contentTime?.dicomSegNonEmptyValue
        self.timezoneOffsetFromUTC = timezoneOffsetFromUTC?.dicomSegNonEmptyValue
        self.contentDescription = contentDescription
        self.contentCreatorName = contentCreatorName?.dicomSegNonEmptyValue
        self.manufacturer = manufacturer
        self.manufacturerModelName = manufacturerModelName
        self.deviceSerialNumber = deviceSerialNumber
        self.softwareVersions = softwareVersions
        self.positionReferenceIndicator = positionReferenceIndicator
        self.dimensionOrganizationUID = dimensionOrganizationUID?.dicomSegNonEmptyValue
        self.defaultAlgorithmType = defaultAlgorithmType?.dicomSegNonEmptyValue
        self.defaultPropertyCategory = defaultPropertyCategory
        self.defaultPropertyType = defaultPropertyType
        self.referencedInstancesBySeries = referencedInstancesBySeries
    }
}

/// Builder for synthetic or application-generated DICOM Segmentation datasets. The output composes
/// the Segmentation IOD (PS3.3 A.51): Patient/Study/Series, Enhanced General Equipment, General
/// Image, Segmentation Series/Image, Multi-frame Functional Groups with Dimension Index and
/// Segment Identification per frame, Derivation Image with the A.51.5.1 codes and Common Instance
/// Reference for the referenced series.
public enum DicomSegmentationBuilder {
    public static let labelMapSegmentationStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.66.7"
    public static let segmentationStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.66.4"
    /// (113076, DCM, "Segmentation") and (121322, DCM, "Source image for image processing operation").
    static let derivationCode = DicomCodedConcept(codeValue: "113076", codingSchemeDesignator: "DCM", codeMeaning: "Segmentation")
    static let sourcePurposeCode = DicomCodedConcept(codeValue: "121322", codingSchemeDesignator: "DCM",
                                                     codeMeaning: "Source image for image processing operation")

    /// The dataset with native Pixel Data, to be written in Explicit VR Little Endian.
    public static func dataSet(
        from segmentation: DicomSegmentation,
        studyInstanceUID: String,
        seriesInstanceUID: String,
        sopInstanceUID: String? = nil,
        contentLabel: String = "SEGMENTATION",
        options: DicomSegmentationBuildOptions = DicomSegmentationBuildOptions()
    ) -> DicomDataSet {
        makeDataSet(from: segmentation, studyInstanceUID: studyInstanceUID, seriesInstanceUID: seriesInstanceUID,
                    sopInstanceUID: sopInstanceUID, contentLabel: contentLabel, options: options) { bitsAllocated in
            [bytes(.pixelData, vr: bitsAllocated == 16 ? .OW : .OB, pixelData(from: segmentation))]
        }
    }

    /// The dataset with its Pixel Data in `encoding` where the segmentation allows it, and the transfer syntax to
    /// write it with (issue #2513). Encapsulated frames are encoded one at a time, so the native Pixel Data is never
    /// held whole.
    public static func encodedDataSet(
        from segmentation: DicomSegmentation,
        studyInstanceUID: String,
        seriesInstanceUID: String,
        sopInstanceUID: String? = nil,
        contentLabel: String = "SEGMENTATION",
        encoding: DicomSegmentationPixelEncoding,
        options: DicomSegmentationBuildOptions = DicomSegmentationBuildOptions()
    ) throws -> (dataSet: DicomDataSet, transferSyntax: DicomTransferSyntax) {
        let applied = encoding.applied(to: segmentation.segmentationType)
        let dataSet = try makeDataSet(from: segmentation, studyInstanceUID: studyInstanceUID,
                                      seriesInstanceUID: seriesInstanceUID, sopInstanceUID: sopInstanceUID,
                                      contentLabel: contentLabel, options: options) { bitsAllocated in
            guard applied.encapsulatesFrames else {
                return [bytes(.pixelData, vr: bitsAllocated == 16 ? .OW : .OB, pixelData(from: segmentation))]
            }
            return try encapsulatedPixelDataElements(from: segmentation, bitsAllocated: bitsAllocated, encoding: applied)
        }
        return (dataSet, applied.transferSyntax)
    }

    static func makeDataSet(
        from segmentation: DicomSegmentation,
        studyInstanceUID: String,
        seriesInstanceUID: String,
        sopInstanceUID: String?,
        contentLabel: String,
        options: DicomSegmentationBuildOptions,
        pixelDataElements: (_ bitsAllocated: Int) throws -> [DicomDataElement]
    ) rethrows -> DicomDataSet {
        let instanceUID = sopInstanceUID?.dicomSegNonEmptyValue
            ?? segmentation.sopInstanceUID
            ?? DicomDataSetWriter.makeUID()
        let isLabelmap = segmentation.segmentationType == .labelmap
        let bitsAllocated = segmentation.segmentationType == .binary ? 1 : (isLabelmap && labelmapNeedsSixteenBits(segmentation) ? 16 : 8)
        let highBit = bitsAllocated - 1
        let now = currentDicomDateTime()
        let dimensionUID = options.dimensionOrganizationUID ?? derivedUID(from: instanceUID, suffix: 1)
        let positions = distinctPositions(in: segmentation)

        var frameItems = segmentation.frames.map { frameDataSet($0, segmentation: segmentation, positions: positions) }
        var sharedElements: [DicomDataElement] = []
        for group in segmentation.sharedFunctionalGroups.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let first = frameItems.first?[group.rawValue],
                  frameItems.allSatisfy({ $0[group.rawValue] == first }) else { continue }
            sharedElements.append(first)
            frameItems = frameItems.map { item in
                DicomDataSet(elements: item.elements.filter { $0.tag != group.rawValue })
            }
        }
        var elements: [DicomDataElement] = [
            string(.sopClassUID, vr: .UI, isLabelmap ? labelMapSegmentationStorageSOPClassUID : segmentationStorageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, instanceUID),
            string(.studyInstanceUID, vr: .UI, studyInstanceUID),
            string(.seriesInstanceUID, vr: .UI, seriesInstanceUID),
            text(0x00100010, vr: .PN, options.patientName),
            text(0x00100020, vr: .LO, options.patientID),
            text(0x00100030, vr: .DA, options.patientBirthDate),
            text(0x00100040, vr: .CS, options.patientSex),
            text(0x00080020, vr: .DA, options.studyDate),
            text(0x00080030, vr: .TM, options.studyTime),
            text(0x00080090, vr: .PN, options.referringPhysicianName),
            text(0x00200010, vr: .SH, options.studyID),
            text(0x00080050, vr: .SH, options.accessionNumber),
            string(.modality, vr: .CS, "SEG"),
            text(0x00200011, vr: .IS, String(options.seriesNumber)),
            text(0x00200013, vr: .IS, String(options.instanceNumber)),
            text(0x00080023, vr: .DA, options.contentDate ?? now.date),
            text(0x00080033, vr: .TM, options.contentTime ?? now.time),
            DicomDataElement(tag: 0x00080008, vr: .CS, value: .strings(["DERIVED", "PRIMARY"])),
            text(0x00080070, vr: .LO, options.manufacturer),
            text(0x00081090, vr: .LO, options.manufacturerModelName),
            text(0x00181000, vr: .LO, options.deviceSerialNumber),
            text(0x00181020, vr: .LO, options.softwareVersions),
            string(.contentLabel, vr: .CS, segmentation.contentLabel ?? contentLabel),
            text(0x00700081, vr: .LO, segmentation.contentDescription ?? options.contentDescription),
            us(.samplesPerPixel, 1),
            string(.photometricInterpretation, vr: .CS, segmentation.photometricInterpretation),
            string(.numberOfFrames, vr: .IS, String(segmentation.frames.count)),
            us(.rows, segmentation.rows),
            us(.columns, segmentation.columns),
            us(.bitsAllocated, bitsAllocated),
            us(.bitsStored, bitsAllocated),
            us(.highBit, highBit),
            us(.pixelRepresentation, 0),
            text(0x00282110, vr: .CS, "00"),
            string(.segmentationType, vr: .CS, segmentation.segmentationType.rawValue),
            sequence(.segmentSequence, segmentation.segments.map { segmentDataSet($0, options: options,
                palette: isLabelmap && segmentation.photometricInterpretation == "PALETTE COLOR") }),
            sequence(0x00209221, [DicomDataSet(elements: [text(0x00209164, vr: .UI, dimensionUID)])]),
            sequence(0x00209222, dimensionIndexItems(dimensionUID: dimensionUID, hasPositions: !positions.isEmpty, labelmap: isLabelmap)),
            sequence(0x52009229, [DicomDataSet(elements: sharedElements)]),
            sequence(.perFrameFunctionalGroupsSequence, frameItems)
        ]
        elements.append(contentsOf: try pixelDataElements(bitsAllocated))
        if let offset = options.timezoneOffsetFromUTC {
            elements.append(text(0x00080201, vr: .SH, offset))
        }
        if let description = options.seriesDescription?.dicomSegNonEmptyValue {
            elements.append(text(0x0008103E, vr: .LO, description))
        }
        if let characterSet = options.specificCharacterSet?.dicomSegNonEmptyValue {
            elements.append(text(0x00080005, vr: .CS, characterSet))
        }
        if let contentCreatorName = segmentation.contentCreatorName ?? options.contentCreatorName {
            elements.append(text(0x00700084, vr: .PN, contentCreatorName))
        }
        if let overlap = isLabelmap ? DicomSegmentsOverlap.no : segmentation.segmentsOverlap {
            elements.append(text(0x00620013, vr: .CS, overlap.rawValue))
        }
        if isLabelmap, let padding = segmentation.pixelPaddingValue {
            elements.append(DicomDataElement(tag: 0x00280120, vr: .US, value: .unsignedIntegers([UInt(padding)])))
        }
        elements.append(contentsOf: segmentation.paletteColorElements)
        if let frameOfReferenceUID = segmentation.frameOfReferenceUID {
            elements.append(text(0x00200052, vr: .UI, frameOfReferenceUID))
            elements.append(text(0x00201040, vr: .LO, options.positionReferenceIndicator))
        }
        let seriesUIDs = segmentation.referencedSeriesInstanceUIDs + segmentation.referencedInstancesBySeries.keys.sorted()
            .filter { !segmentation.referencedSeriesInstanceUIDs.contains($0) }
        let referencedSeries = seriesUIDs.compactMap {
            referencedSeriesDataSet($0, segmentation: segmentation, options: options)
        }
        if !referencedSeries.isEmpty {
            elements.append(sequence(.referencedSeriesSequence, referencedSeries))
        }
        if segmentation.segmentationType == .fractional {
            elements.append(string(
                .segmentationFractionalType,
                vr: .CS,
                segmentation.fractionalType?.rawValue ?? DicomSegmentationFractionalType.probability.rawValue
            ))
            elements.append(us(.maximumFractionalValue, segmentation.maximumFractionalValue))
        }
        return DicomDataSet(elements: elements)
    }

    /// C.7.6.17: the segment index (Referenced Segment Number) and, with geometry, the plane position.
    private static func dimensionIndexItems(dimensionUID: String, hasPositions: Bool, labelmap: Bool) -> [DicomDataSet] {
        var items = [DicomDataSet(elements: [
            text(0x00209164, vr: .UI, dimensionUID),
            DicomDataElement(tag: 0x00209165, vr: .AT, value: .unsignedIntegers([0x0062000B])),
            DicomDataElement(tag: 0x00209167, vr: .AT, value: .unsignedIntegers([0x0062000A]))
        ])]
        if labelmap { items = [] }
        if hasPositions {
            items.append(DicomDataSet(elements: [
                text(0x00209164, vr: .UI, dimensionUID),
                DicomDataElement(tag: 0x00209165, vr: .AT, value: .unsignedIntegers([0x00200032])),
                DicomDataElement(tag: 0x00209167, vr: .AT, value: .unsignedIntegers([0x00209113]))
            ]))
        }
        return items
    }

    /// Distinct Image Position (Patient) values in order of first appearance, indexed from 1.
    private static func distinctPositions(in segmentation: DicomSegmentation) -> [String: Int] {
        // A position dimension is meaningful only when every frame can supply its index.
        guard segmentation.frames.allSatisfy({ $0.geometry?.imagePositionPatient != nil }) else { return [:] }
        var positions: [String: Int] = [:]
        for frame in segmentation.frames {
            guard let position = frame.geometry?.imagePositionPatient else { continue }
            let key = positionKey(position)
            if positions[key] == nil { positions[key] = positions.count + 1 }
        }
        return positions
    }

    private static func positionKey(_ position: SIMD3<Double>) -> String {
        [position.x, position.y, position.z].map { String($0) }.joined(separator: "\\")
    }

    /// C.12.2: the referenced instances of one series, from the options or from the frames when the
    /// segmentation references a single series.
    private static func referencedSeriesDataSet(_ uid: String, segmentation: DicomSegmentation,
                                                options: DicomSegmentationBuildOptions) -> DicomDataSet? {
        var references = (segmentation.referencedInstancesBySeries[uid] ?? options.referencedInstancesBySeries[uid] ?? []).filter {
            $0.referencedSOPClassUID != nil && $0.referencedSOPInstanceUID != nil
        }
        if references.isEmpty, segmentation.referencedInstancesBySeries[uid] == nil,
           segmentation.referencedSeriesInstanceUIDs.count == 1 {
            var seen = Set<String>()
            for reference in segmentation.frames.flatMap(\.sourceImageReferences) {
                guard let instance = reference.referencedSOPInstanceUID, reference.referencedSOPClassUID != nil,
                      seen.insert(instance).inserted else { continue }
                references.append(reference)
            }
        }
        guard !references.isEmpty else { return nil }
        var elements = [string(.seriesInstanceUID, vr: .UI, uid)]
        elements.append(sequence(0x0008114A, references.map { reference in
            var item = [
                string(.referencedSOPClassUID, vr: .UI, reference.referencedSOPClassUID ?? ""),
                string(.referencedSOPInstanceUID, vr: .UI, reference.referencedSOPInstanceUID ?? "")
            ]
            if segmentation.referencedInstancesBySeries[uid] != nil, !reference.referencedFrameNumbers.isEmpty {
                item.append(DicomDataElement(tag: 0x00081160, vr: .IS,
                                             value: .strings(reference.referencedFrameNumbers.map(String.init))))
            }
            return DicomDataSet(elements: item)
        }))
        return DicomDataSet(elements: elements)
    }

    private static func derivedUID(from uid: String, suffix: Int) -> String {
        let candidate = uid + "." + String(suffix)
        return candidate.utf8.count <= 64 ? candidate : DicomDataSetWriter.makeUID()
    }

    private static func currentDicomDateTime() -> (date: String, time: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        let now = Date()
        let date = formatter.string(from: now)
        formatter.dateFormat = "HHmmss"
        return (date, formatter.string(from: now))
    }

    private static func segmentDataSet(_ segment: DicomSegment, options: DicomSegmentationBuildOptions,
                                       palette: Bool) -> DicomDataSet {
        var elements: [DicomDataElement] = [
            us(.segmentNumber, segment.number),
            string(.segmentLabel, vr: .LO, segment.label)
        ]
        if let description = segment.description {
            elements.append(string(.segmentDescription, vr: .ST, description))
        }
        if let algorithmType = segment.algorithmType ?? options.defaultAlgorithmType {
            elements.append(string(.segmentAlgorithmType, vr: .CS, algorithmType))
        }
        if let algorithmName = segment.algorithmName {
            elements.append(string(.segmentAlgorithmName, vr: .LO, algorithmName))
        }
        if let category = segment.propertyCategory ?? options.defaultPropertyCategory {
            elements.append(sequence(.segmentedPropertyCategoryCodeSequence, [codedConceptDataSet(category)]))
        }
        if let type = segment.propertyType ?? options.defaultPropertyType {
            var item = codedConceptDataSet(type).elements
            if !segment.propertyTypeModifiers.isEmpty {
                item.append(sequence(0x00620011, segment.propertyTypeModifiers.map(codedConceptDataSet)))
            }
            elements.append(sequence(.segmentedPropertyTypeCodeSequence, [DicomDataSet(elements: item)]))
        }
        if let trackingID = segment.trackingID {
            elements.append(string(.trackingID, vr: .UT, trackingID))
        }
        if let trackingUID = segment.trackingUID {
            elements.append(string(.trackingUID, vr: .UI, trackingUID))
        }
        if let anatomy = segment.anatomicRegion {
            var item = codedConceptDataSet(anatomy).elements
            if !segment.anatomicRegionModifiers.isEmpty {
                item.append(sequence(0x00082220, segment.anatomicRegionModifiers.map(codedConceptDataSet)))
            }
            elements.append(sequence(0x00082218, [DicomDataSet(elements: item)]))
        }
        if let algorithm = segment.algorithmIdentification {
            var item = [text(0x00660036, vr: .LO, algorithm.name), text(0x00660031, vr: .LO, algorithm.version),
                        sequence(0x0066002F, [codedConceptDataSet(algorithm.family)])]
            if let parameters = algorithm.parameters { item.append(text(0x00660032, vr: .LT, parameters)) }
            elements.append(sequence(0x00620007, [DicomDataSet(elements: item)]))
        }
        if let grayscale = segment.recommendedDisplayGrayscaleValue {
            elements.append(DicomDataElement(tag: 0x0062000C, vr: .US, value: .unsignedIntegers([UInt(grayscale)])))
        }
        if !palette, !segment.recommendedDisplayCIELabValue.isEmpty {
            elements.append(DicomDataElement(
                tag: DicomTag.recommendedDisplayCIELabValue.rawValue,
                vr: .US,
                value: .unsignedIntegers(segment.recommendedDisplayCIELabValue.map(UInt.init))
            ))
        }
        return DicomDataSet(elements: elements)
    }

    private static func frameDataSet(_ frame: DicomSegmentationFrame, segmentation: DicomSegmentation,
                                     positions: [String: Int]) -> DicomDataSet {
        var elements = [
            sequence(.segmentIdentificationSequence, [
                DicomDataSet(elements: [
                    us(.referencedSegmentNumber, frame.segmentNumber)
                ])
            ])
        ]
        if segmentation.segmentationType == .labelmap || frame.segmentAttribution == .unattributed { elements = [] }
        // C.7.6.16.2.2: Dimension Index Values follow the Dimension Index Sequence (segment, then position).
        let dimensionCount = (segmentation.segmentationType == .labelmap ? 0 : 1) + (positions.isEmpty ? 0 : 1)
        var dimensionIndexValues = frame.geometry?.frameContent?.dimensionIndexValues ?? []
        if dimensionIndexValues.count != dimensionCount {
            let segmentIndex = (segmentation.segments.firstIndex { $0.number == frame.segmentNumber } ?? 0) + 1
            dimensionIndexValues = segmentation.segmentationType == .labelmap ? [] : [segmentIndex]
            if let position = frame.geometry?.imagePositionPatient, let positionIndex = positions[positionKey(position)] {
                dimensionIndexValues.append(positionIndex)
            }
        }
        var contentElements = [ul(.dimensionIndexValues, dimensionIndexValues)]
        if let frameContent = frame.geometry?.frameContent {
            if let stackID = frameContent.stackID {
                contentElements.append(string(.stackID, vr: .SH, stackID))
            }
            if let inStackPositionNumber = frameContent.inStackPositionNumber {
                contentElements.append(ul(.inStackPositionNumber, [inStackPositionNumber]))
            }
            if let temporalPositionIndex = frameContent.temporalPositionIndex {
                contentElements.append(ul(.temporalPositionIndex, [temporalPositionIndex]))
            }
            if let frameAcquisitionNumber = frameContent.frameAcquisitionNumber {
                contentElements.append(ul(.frameAcquisitionNumber, [frameAcquisitionNumber]))
            }
        }
        elements.append(sequence(.frameContentSequence, [DicomDataSet(elements: contentElements)]))

        if let geometry = frame.geometry {
            if let position = geometry.imagePositionPatient {
                elements.append(sequence(.planePositionSequence, [
                    DicomDataSet(elements: [
                        ds(.imagePositionPatient, [position.x, position.y, position.z])
                    ])
                ]))
            }
            if let orientation = geometry.imageOrientationPatient {
                elements.append(sequence(.planeOrientationSequence, [
                    DicomDataSet(elements: [
                        ds(.imageOrientationPatient, [
                            orientation.row.x,
                            orientation.row.y,
                            orientation.row.z,
                            orientation.column.x,
                            orientation.column.y,
                            orientation.column.z
                        ])
                    ])
                ]))
            }
            if let measures = geometry.pixelMeasures {
                var measureElements: [DicomDataElement] = []
                if let spacing = measures.pixelSpacing {
                    measureElements.append(ds(.pixelSpacing, [spacing.x, spacing.y]))
                }
                if let thickness = measures.sliceThickness {
                    measureElements.append(ds(.sliceThickness, [thickness]))
                }
                if let spacingBetweenSlices = measures.spacingBetweenSlices {
                    measureElements.append(ds(.sliceSpacing, [spacingBetweenSlices]))
                }
                if !measureElements.isEmpty {
                    elements.append(sequence(.pixelMeasuresSequence, [DicomDataSet(elements: measureElements)]))
                }
            }
        }

        if !frame.sourceImageReferences.isEmpty {
            // A.51.5.1: (113076, DCM, "Segmentation") derivation from (121322, DCM) source images.
            var groups: [(DicomCodedConcept, [DicomSourceImageReference])] = []
            for reference in frame.sourceImageReferences {
                let code = reference.derivationCode ?? derivationCode
                if let last = groups.indices.last, groups[last].0 == code {
                    groups[last].1.append(reference)
                } else {
                    groups.append((code, [reference]))
                }
            }
            elements.append(sequence(.derivationImageSequence, groups.map { code, references in
                DicomDataSet(elements: [
                    sequence(0x00089215, [codedConceptDataSet(code)]),
                    sequence(.sourceImageSequence, references.map(sourceImageDataSet))
                ])
            }))
        }

        return DicomDataSet(elements: elements)
    }

    private static func codedConceptDataSet(_ concept: DicomCodedConcept) -> DicomDataSet {
        var elements = [
            string(.codeValue, vr: .SH, concept.codeValue),
            string(.codingSchemeDesignator, vr: .SH, concept.codingSchemeDesignator)
        ]
        if let meaning = concept.codeMeaning {
            elements.append(string(.codeMeaning, vr: .LO, meaning))
        }
        if let version = concept.codingSchemeVersion {
            elements.append(text(0x00080103, vr: .SH, version))
        }
        return DicomDataSet(elements: elements)
    }

    private static func sourceImageDataSet(_ reference: DicomSourceImageReference) -> DicomDataSet {
        var elements: [DicomDataElement] = []
        if let sopClassUID = reference.referencedSOPClassUID {
            elements.append(string(.referencedSOPClassUID, vr: .UI, sopClassUID))
        }
        if let sopInstanceUID = reference.referencedSOPInstanceUID {
            elements.append(string(.referencedSOPInstanceUID, vr: .UI, sopInstanceUID))
        }
        if !reference.referencedFrameNumbers.isEmpty {
            elements.append(DicomDataElement(
                tag: DicomTag.referencedFrameNumber.rawValue,
                vr: .IS,
                value: .strings(reference.referencedFrameNumbers.map(String.init))
            ))
        }
        elements.append(sequence(0x0040A170, [codedConceptDataSet(reference.purposeOfReferenceCode ?? sourcePurposeCode)]))
        return DicomDataSet(elements: elements)
    }

    /// Labels above 255 (declared or stored) need 16-bit LABELMAP pixels. An 8-bit plane cannot hold one, so only
    /// 16-bit planes are scanned.
    private static func labelmapNeedsSixteenBits(_ segmentation: DicomSegmentation) -> Bool {
        (segmentation.segments.map(\.number).max() ?? 0) > 255 || segmentation.frames.contains { frame in
            guard case .uint16(let values)? = frame.pixelData.labelmapPlane else { return false }
            return values.contains { $0 > 255 }
        }
    }

    private static func pixelData(from segmentation: DicomSegmentation) -> Data {
        pixelData(of: segmentation.frames, in: segmentation, wideLabels: labelmapNeedsSixteenBits(segmentation))
    }

    /// Native bytes of `frames`, one after another: BINARY bits run on from one frame to the next, so one frame on
    /// its own is packed from bit 0.
    static func pixelData(of frames: some Collection<DicomSegmentationFrame>, in segmentation: DicomSegmentation,
                          wideLabels: Bool) -> Data {
        let pixelCount = segmentation.rows * segmentation.columns
        switch segmentation.segmentationType {
        case .binary:
            let bitCount = pixelCount * frames.count
            var bytes = [UInt8](repeating: 0, count: (bitCount + 7) / 8)
            bytes.withUnsafeMutableBufferPointer { bytes in
                var bitIndex = 0
                for frame in frames {
                    let values = frame.pixelData.storedValues
                    let valueCount = min(values.count, pixelCount)
                    values.withUnsafeBufferPointer { values in
                        for pixelIndex in 0..<valueCount where values[pixelIndex] != 0 {
                            let bit = bitIndex + pixelIndex
                            bytes[bit >> 3] |= UInt8(1 << (bit & 7))
                        }
                    }
                    bitIndex += pixelCount
                }
            }
            return Data(bytes)
        case .unknown:
            return frames.reduce(into: Data()) { data, frame in
                if case .uninterpreted(let bytes) = frame.pixelData { data.append(bytes) }
            }
        case .labelmap:
            let wide = wideLabels
            let bytesPerPixel = wide ? 2 : 1
            var data = Data(capacity: frames.count * pixelCount * bytesPerPixel)
            var narrow = [UInt8]()
            var widened = [UInt16]()
            for frame in frames {
                switch (frame.pixelData.labelmapPlane, wide) {
                case (.uint8(let values)?, false):
                    appendPrefix(of: values, count: pixelCount, to: &data)
                case (.uint16(let values)?, false):
                    narrow.removeAll(keepingCapacity: true)
                    narrow.append(contentsOf: values.prefix(pixelCount).lazy.map { UInt8(truncatingIfNeeded: $0) })
                    appendPrefix(of: narrow, count: pixelCount, to: &data)
                case (.uint16(let values)?, true):
                    widened.removeAll(keepingCapacity: true)
                    widened.append(contentsOf: values.prefix(pixelCount).lazy.map { $0.littleEndian })
                    appendPrefix(of: widened, count: pixelCount, to: &data)
                case (.uint8(let values)?, true):
                    widened.removeAll(keepingCapacity: true)
                    widened.append(contentsOf: values.prefix(pixelCount).lazy.map { UInt16($0).littleEndian })
                    appendPrefix(of: widened, count: pixelCount, to: &data)
                case (nil, _):
                    break
                }
                // A frame shorter than Rows × Columns is zero-filled so the next frames stay aligned.
                let written = min(frame.pixelData.labelmapPlane?.count ?? 0, pixelCount)
                if written < pixelCount { data.append(Data(count: (pixelCount - written) * bytesPerPixel)) }
            }
            return data
        case .fractional:
            var data = Data(capacity: frames.count * pixelCount)
            for frame in frames {
                let values = frame.pixelData.storedValues
                appendPrefix(of: values, count: pixelCount, to: &data)
                if values.count < pixelCount { data.append(Data(count: pixelCount - values.count)) }
            }
            return data
        }
    }

    /// Copies the first `count` elements' bytes at once instead of appending them one by one.
    private static func appendPrefix<Element>(of values: [Element], count: Int, to data: inout Data) {
        values.withUnsafeBufferPointer { buffer in
            data.append(UnsafeBufferPointer(rebasing: buffer.prefix(count)))
        }
    }

    private static func sequence(_ tag: DicomTag, _ dataSets: [DicomDataSet]) -> DicomDataElement {
        sequence(tag.rawValue, dataSets)
    }

    private static func sequence(_ tag: Int, _ dataSets: [DicomDataSet]) -> DicomDataElement {
        DicomDataElement(
            tag: tag,
            vr: .SQ,
            value: .sequence(dataSets.map { DicomSequenceItem(dataSet: $0) })
        )
    }

    private static func text(_ tag: Int, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
    }

    private static func string(_ tag: DicomTag, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings([value]))
    }

    private static func us(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([UInt(clamping: value)]))
    }

    private static func ul(_ tag: DicomTag, _ values: [Int]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .UL, value: .unsignedIntegers(values.map { UInt(clamping: $0) }))
    }

    private static func ds(_ tag: DicomTag, _ values: [Double]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .DS, value: .floats(values))
    }

    private static func bytes(_ tag: DicomTag, vr: DicomVR, _ value: Data) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .bytes(value))
    }
}

extension DCMDecoder {
    public var segmentation: DicomSegmentation? {
        synchronized {
            DicomSegmentationParser.makeSegmentation(from: self)
        }
    }

    /// Series Instance UIDs of the Referenced Series Sequence (0008,1115), read without decoding any frame.
    public var segmentationReferencedSeriesInstanceUIDs: [String] {
        synchronized {
            DicomSegmentationParser.referencedSeriesInstanceUIDs(in: self)
        }
    }
}

private enum DicomSegmentationParser {
    static func makeSegmentation(from decoder: DCMDecoder) -> DicomSegmentation? {
        guard isSegmentationObject(decoder) else { return nil }
        let rows = decoder.height
        let columns = decoder.width
        let frameCount = max(1, decoder.nImages)
        let bitsAllocated = decoder.intValue(for: DicomTag.bitsAllocated.rawValue) ?? decoder.bitDepth
        let maximumFractionalValue = decoder.intValue(for: DicomTag.maximumFractionalValue.rawValue) ?? 255

        guard rows > 0, columns > 0, frameCount > 0 else { return nil }
        let segmentationType = DicomSegmentationType(rawValue: decoder.info(for: .segmentationType).dicomSegTrimmedValue) ?? .unknown
        var diagnostics: [DicomSegmentationDiagnostic] = []
        if segmentationType == .unknown { diagnostics.append(.init(code: .unknownSegmentationType)) }

        let segmentItems = parseItems(in: decoder, for: .segmentSequence)
        let segments = segmentItems.compactMap(segment)

        let sharedItems = parseItems(in: decoder, for: .sharedFunctionalGroupsSequence)
        let perFrameItems = parseItems(in: decoder, for: .perFrameFunctionalGroupsSequence)
        let functionalGroups = DicomEnhancedMultiframeParser.makeFunctionalGroups(
            sharedItems: sharedItems,
            perFrameItems: perFrameItems,
            declaredFrameCount: frameCount
        )

        // A refused compressed object retains metadata and diagnostics, but no partial masks (Isis issue #2520).
        var encapsulated: DicomSegmentationEncapsulatedFrames?
        if decoder.compressedImage {
            do {
                encapsulated = try DicomSegmentationEncapsulatedFrames(decoder: decoder, rows: rows, columns: columns,
                                                                       bitsAllocated: bitsAllocated)
            } catch {
                diagnostics.append(error as? DicomSegmentationDiagnostic
                    ?? .init(code: .compressedFrameDecodeFailed, transferSyntaxUID: decoder.transferSyntaxUID))
            }
        }
        var frames: [DicomSegmentationFrame] = []
        frames.reserveCapacity(frameCount)
        for frameIndex in 0..<frameCount {
            if decoder.compressedImage, encapsulated == nil { break }
            let pixelData: DicomSegmentationPixelData
            do {
                guard let decoded = try framePixelData(
                    decoder: decoder,
                    encapsulated: encapsulated,
                    frameIndex: frameIndex,
                    rows: rows,
                    columns: columns,
                    segmentationType: segmentationType,
                    maximumFractionalValue: maximumFractionalValue,
                    bitsAllocated: bitsAllocated
                ) else { return nil }
                pixelData = decoded
            } catch {
                diagnostics.append(error as? DicomSegmentationDiagnostic
                    ?? .init(code: .compressedFrameDecodeFailed, frameIndex: frameIndex,
                             transferSyntaxUID: decoder.transferSyntaxUID))
                frames.removeAll()
                break
            }

            let declared = (perFrameItems[safe: frameIndex]?.dataSet[0x0062000A]
                ?? sharedItems.first?.dataSet[0x0062000A])?.sequenceItems.first?.dataSet.int(for: .referencedSegmentNumber)
            let number = declared ?? (segments.count == 1 ? segments[0].number : 0)
            let attribution: DicomSegmentationSegmentAttribution
            if segmentationType == .labelmap {
                attribution = .unattributed
            } else if let declared, segments.contains(where: { $0.number == declared }) {
                attribution = .declared
            } else if declared == nil, segments.count == 1 {
                attribution = .inferredSingleSegment
            } else {
                attribution = .unattributed
                diagnostics.append(.init(code: .frameWithoutSegment, frameIndex: frameIndex))
            }

            let geometry = functionalGroups?.geometry(forFrame: frameIndex)
            frames.append(DicomSegmentationFrame(
                index: frameIndex,
                segmentNumber: segmentationType == .labelmap ? 0 : number,
                geometry: geometry,
                sourceImageReferences: geometry?.sourceImageReferences ?? [],
                pixelData: pixelData,
                segmentAttribution: attribution
            ))
        }

        var hierarchy: [String: [DicomSourceImageReference]] = [:]
        let seriesItems = parseItems(in: decoder, for: .referencedSeriesSequence)
        for item in seriesItems {
            guard let uid = item.dataSet.string(for: .seriesInstanceUID) else { continue }
            hierarchy[uid, default: []].append(contentsOf: (item.dataSet[0x0008114A]?.sequenceItems ?? []).map {
                DicomSourceImageReference(referencedSOPClassUID: $0.dataSet.string(for: .referencedSOPClassUID),
                    referencedSOPInstanceUID: $0.dataSet.string(for: .referencedSOPInstanceUID),
                    referencedFrameNumbers: $0.dataSet.ints(for: .referencedFrameNumber))
            })
        }
        let overlap = DicomSegmentsOverlap(rawValue: decoder.info(for: 0x00620013).dicomSegTrimmedValue)
        let knownNumbers = Set(segments.map(\.number))
        // Every (SOP Instance UID, SOP Class UID) pair of the hierarchy, looked up once per frame reference (#2516).
        let knownInstances = Set(hierarchy.values.flatMap { $0 }.map {
            DicomSourceImageReferenceIdentity($0, includesFrames: false, includesContentSelectors: false)
        })
        // One histogram pass per plane checks every stored value and records which labels occur.
        var labelBins: [Int] = []
        var presentLabels = Set<Int>()
        for frame in frames {
            if frame.geometry?.imagePositionPatient == nil || frame.geometry?.imageOrientationPatient == nil
                || frame.geometry?.pixelMeasures?.pixelSpacing == nil {
                diagnostics.append(.init(code: .frameGeometryMissing, frameIndex: frame.index))
            }
            if case .fractional(let values, let maximum) = frame.pixelData, values.contains(where: { Int($0) > maximum }) {
                diagnostics.append(.init(code: .fractionalValueAboveMaximum, frameIndex: frame.index))
            }
            if let plane = frame.pixelData.labelmapPlane {
                let binCount = plane.bitsAllocated == 8 ? 256 : 65_536
                if labelBins.count != binCount { labelBins = [Int](repeating: 0, count: binCount) }
                plane.accumulateHistogram(into: &labelBins)
                var undeclared = false
                for value in labelBins.indices where labelBins[value] > 0 {
                    presentLabels.insert(value)
                    if !knownNumbers.contains(value) { undeclared = true }
                    labelBins[value] = 0
                }
                if undeclared {
                    diagnostics.append(.init(code: .labelmapValueWithoutSegment, frameIndex: frame.index))
                }
            }
            if !seriesItems.isEmpty, frame.sourceImageReferences.contains(where: { reference in
                !knownInstances.contains(DicomSourceImageReferenceIdentity(reference, includesFrames: false,
                                                                           includesContentSelectors: false))
            }) {
                diagnostics.append(.init(code: .referencedInstanceNotInReferencedSeries, frameIndex: frame.index))
            }
        }
        for (index, segment) in segments.enumerated() {
            let present = segmentationType == .labelmap
                ? presentLabels.contains(segment.number)
                : frames.contains { $0.segmentAttribution != .unattributed && $0.segmentNumber == segment.number }
            if !present { diagnostics.append(.init(code: .segmentWithoutFrames, segmentIndex: index)) }
        }
        if overlap == .no, segmentationType == .binary || segmentationType == .fractional {
            for (index, frame) in frames.enumerated() {
                guard frame.segmentAttribution != .unattributed, let geometry = frame.geometry,
                      geometry.imagePositionPatient != nil, geometry.imageOrientationPatient != nil,
                      geometry.pixelMeasures?.pixelSpacing != nil else { continue }
                for other in frames.prefix(index) where other.segmentNumber != frame.segmentNumber
                    && other.segmentAttribution != .unattributed {
                    guard let otherGeometry = other.geometry,
                          geometry.imagePositionPatient == otherGeometry.imagePositionPatient,
                          geometry.imageOrientationPatient == otherGeometry.imageOrientationPatient,
                          geometry.pixelMeasures == otherGeometry.pixelMeasures,
                          geometry.frameContent?.temporalPositionIndex == otherGeometry.frameContent?.temporalPositionIndex
                    else { continue }
                    if zip(frame.pixelData.storedValues, other.pixelData.storedValues).contains(where: { $0 != 0 && $1 != 0 }) {
                        diagnostics.append(.init(code: .segmentsOverlapDeclaredNoButOverlapping, frameIndex: frame.index))
                        break
                    }
                }
            }
        }
        let sharedGroups = Set(DicomSegmentationFunctionalGroup.allCases.filter {
            sharedItems.first?.dataSet.contains($0.rawValue) == true
        })
        // Keep the original palette/ICC attributes; DCMDecoder's existing palette handler decodes the LUT.
        let paletteTags = [0x00281101, 0x00281102, 0x00281103, 0x00281199,
                           0x00281201, 0x00281202, 0x00281203, 0x00282000, 0x00282002]
        var paletteElements: [DicomDataElement] = []
        if decoder.info(for: .photometricInterpretation).dicomSegTrimmedValue == "PALETTE COLOR" {
            let start = (try? DicomPart10FileMetaParser.parse(decoder.dicomData).dataSetOffset) ?? 0
            let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID) ?? .explicitVRLittleEndian
            if let metadata = try? DicomDataSetParser.dataSet(from: Data(decoder.dicomData.dropFirst(start)),
                                                             transferSyntax: syntax) {
                paletteElements = paletteTags.compactMap { tag in
                    metadata[tag].map { DicomDataElement(tag: tag, vr: $0.vr, value: $0.value) }
                }
            }
        }

        return DicomSegmentation(
            sopInstanceUID: decoder.info(for: .sopInstanceUID),
            frameOfReferenceUID: decoder.info(for: 0x00200052).dicomSegNonEmptyValue,
            segmentationType: segmentationType,
            fractionalType: fractionalType(from: decoder),
            maximumFractionalValue: maximumFractionalValue,
            rows: rows,
            columns: columns,
            referencedSeriesInstanceUIDs: parseItems(in: decoder, for: .referencedSeriesSequence)
                .compactMap { $0.dataSet.string(for: .seriesInstanceUID)?.dicomSegNonEmptyValue },
            segments: segments,
            frames: frames,
            segmentsOverlap: overlap,
            contentLabel: decoder.info(for: .contentLabel).dicomSegNonEmptyValue,
            contentDescription: decoder.info(for: 0x00700081).dicomSegNonEmptyValue,
            contentCreatorName: decoder.info(for: 0x00700084).dicomSegNonEmptyValue,
            referencedInstancesBySeries: hierarchy,
            sharedFunctionalGroups: sharedGroups,
            diagnostics: diagnostics,
            photometricInterpretation: decoder.info(for: .photometricInterpretation).dicomSegTrimmedValue,
            pixelPaddingValue: decoder.intValue(for: 0x00280120).flatMap(UInt16.init(exactly:)),
            paletteColorElements: paletteElements
        )
    }

    static func referencedSeriesInstanceUIDs(in decoder: DCMDecoder) -> [String] {
        parseItems(in: decoder, for: .referencedSeriesSequence)
            .compactMap { $0.dataSet.string(for: .seriesInstanceUID)?.dicomSegNonEmptyValue }
    }

    private static func isSegmentationObject(_ decoder: DCMDecoder) -> Bool {
        [DicomSegmentationBuilder.segmentationStorageSOPClassUID, DicomSegmentationBuilder.labelMapSegmentationStorageSOPClassUID]
            .contains(decoder.info(for: .sopClassUID).dicomSegTrimmedValue) ||
            decoder.info(for: .modality).dicomSegTrimmedValue == "SEG" ||
            decoder.tagMetadataCache[DicomTag.segmentSequence.rawValue] != nil
    }

    private static func fractionalType(from decoder: DCMDecoder) -> DicomSegmentationFractionalType? {
        DicomSegmentationFractionalType(rawValue: decoder.info(for: .segmentationFractionalType).dicomSegTrimmedValue)
    }

    private static func segment(from item: DicomSequenceItem) -> DicomSegment? {
        let dataSet = item.dataSet
        guard let number = dataSet.int(for: .segmentNumber),
              let label = dataSet.string(for: .segmentLabel)?.dicomSegNonEmptyValue else {
            return nil
        }

        return DicomSegment(
            number: number,
            label: label,
            description: dataSet.string(for: .segmentDescription),
            algorithmType: dataSet.string(for: .segmentAlgorithmType),
            algorithmName: dataSet.string(for: .segmentAlgorithmName),
            propertyCategory: dataSet.sequenceItems(for: .segmentedPropertyCategoryCodeSequence)
                .first
                .flatMap { DicomCodedConcept(dataSet: $0.dataSet) },
            propertyType: dataSet.sequenceItems(for: .segmentedPropertyTypeCodeSequence)
                .first
                .flatMap { DicomCodedConcept(dataSet: $0.dataSet) },
            trackingID: dataSet.string(for: .trackingID),
            trackingUID: dataSet.string(for: .trackingUID),
            recommendedDisplayCIELabValue: dataSet.ints(for: .recommendedDisplayCIELabValue).compactMap { UInt16(exactly: $0) },
            algorithmIdentification: dataSet[0x00620007]?.sequenceItems.first.flatMap { item in
                guard let family = item.dataSet[0x0066002F]?.sequenceItems.first
                    .flatMap({ DicomCodedConcept(dataSet: $0.dataSet) }) else { return nil }
                return DicomSegmentAlgorithmIdentification(name: item.dataSet[0x00660036]?.stringValue ?? "",
                    version: item.dataSet[0x00660031]?.stringValue ?? "", family: family,
                    parameters: item.dataSet[0x00660032]?.stringValue)
            },
            anatomicRegion: dataSet[0x00082218]?.sequenceItems.first.flatMap { DicomCodedConcept(dataSet: $0.dataSet) },
            anatomicRegionModifiers: (dataSet[0x00082218]?.sequenceItems.first?.dataSet[0x00082220]?.sequenceItems ?? [])
                .compactMap { DicomCodedConcept(dataSet: $0.dataSet) },
            propertyTypeModifiers: (dataSet[0x0062000F]?.sequenceItems.first?.dataSet[0x00620011]?.sequenceItems ?? [])
                .compactMap { DicomCodedConcept(dataSet: $0.dataSet) },
            recommendedDisplayGrayscaleValue: dataSet[0x0062000C]?.intValue.flatMap(UInt16.init(exactly:))
        )
    }

    private static func framePixelData(
        decoder: DCMDecoder,
        encapsulated: DicomSegmentationEncapsulatedFrames?,
        frameIndex: Int,
        rows: Int,
        columns: Int,
        segmentationType: DicomSegmentationType,
        maximumFractionalValue: Int,
        bitsAllocated: Int
    ) throws -> DicomSegmentationPixelData? {
        let pixelCount = rows * columns
        func interpret(_ bytes: UnsafeRawBufferPointer, firstBit: Int, bigEndian: Bool) -> DicomSegmentationPixelData? {
            framePixelData(in: bytes, firstBit: firstBit, pixelCount: pixelCount, segmentationType: segmentationType,
                           maximumFractionalValue: maximumFractionalValue, bitsAllocated: bitsAllocated,
                           bigEndian: bigEndian)
        }
        if let encapsulated {
            // A decoded frame is little endian and, when BINARY, packed from its own first bit.
            return try encapsulated.frame(at: frameIndex).withUnsafeBytes { interpret($0, firstBit: 0, bigEndian: false) }
        }
        guard let pixelDataRange = pixelDataRange(in: decoder) else { return nil }
        let bigEndian = !decoder.littleEndian
        // Native BINARY bits run on across frames; other frames start at their own byte.
        let frameStart: Int
        let firstBit: Int
        switch segmentationType {
        case .binary:
            frameStart = pixelDataRange.lowerBound
            firstBit = frameIndex * pixelCount
        case .unknown:
            let byteCount = (pixelCount * bitsAllocated + 7) / 8
            frameStart = min(pixelDataRange.upperBound, pixelDataRange.lowerBound + frameIndex * byteCount)
            firstBit = 0
        case .labelmap, .fractional:
            frameStart = pixelDataRange.lowerBound + frameIndex * pixelCount * max(1, bitsAllocated / 8)
            firstBit = 0
        }
        guard frameStart <= pixelDataRange.upperBound else { return nil }
        return decoder.dicomData.withUnsafeBytes { raw in
            let base = decoder.dicomData.startIndex
            return interpret(UnsafeRawBufferPointer(rebasing: raw[(frameStart - base)..<(pixelDataRange.upperBound - base)]),
                             firstBit: firstBit, bigEndian: bigEndian)
        }
    }

    /// One frame from the bytes that start with it, or with its first bit when BINARY; nil when they are too few.
    private static func framePixelData(
        in bytes: UnsafeRawBufferPointer,
        firstBit: Int,
        pixelCount: Int,
        segmentationType: DicomSegmentationType,
        maximumFractionalValue: Int,
        bitsAllocated: Int,
        bigEndian: Bool
    ) -> DicomSegmentationPixelData? {
        switch segmentationType {
        case .binary:
            guard bitsAllocated == 1, (firstBit + pixelCount + 7) / 8 <= bytes.count else { return nil }
            var values = [UInt8](repeating: 0, count: pixelCount)
            values.withUnsafeMutableBufferPointer { values in
                for pixelIndex in 0..<pixelCount {
                    let bitIndex = firstBit + pixelIndex
                    values[pixelIndex] = (bytes[bitIndex >> 3] >> UInt8(bitIndex & 7)) & 0x01
                }
            }
            return .binary(values)
        case .unknown:
            let byteCount = (pixelCount * bitsAllocated + 7) / 8
            return .uninterpreted(Data(bytes.prefix(byteCount)))
        case .labelmap:
            guard bitsAllocated == 8 || bitsAllocated == 16 else { return nil }
            let bytesPerPixel = bitsAllocated / 8
            guard pixelCount * bytesPerPixel <= bytes.count else { return nil }
            // Planes keep the stored width and are copied in one pass.
            let frame = UnsafeRawBufferPointer(rebasing: bytes.prefix(pixelCount * bytesPerPixel))
            guard bytesPerPixel == 2 else { return .labelmap(.uint8([UInt8](frame))) }
            var values = [UInt16](repeating: 0, count: pixelCount)
            values.withUnsafeMutableBytes { $0.copyMemory(from: frame) }
            if bigEndian == (UInt16(littleEndian: 1) == 1) {
                values = values.map(\.byteSwapped)
            }
            return .labelmap(.uint16(values))
        case .fractional:
            guard bitsAllocated == 8, pixelCount <= bytes.count else { return nil }
            return .fractional(values: [UInt8](bytes.prefix(pixelCount)), maximumFractionalValue: maximumFractionalValue)
        }
    }

    private static func pixelDataRange(in decoder: DCMDecoder) -> Range<Int>? {
        if let metadata = decoder.tagMetadataCache[DicomTag.pixelData.rawValue],
           metadata.offset >= 0,
           metadata.elementLength >= 0,
           metadata.offset <= decoder.dicomData.count,
           metadata.offset + metadata.elementLength <= decoder.dicomData.count {
            return metadata.offset..<(metadata.offset + metadata.elementLength)
        }

        guard decoder.offset >= 0,
              decoder.offset < decoder.dicomData.count else {
            return nil
        }
        return decoder.offset..<decoder.dicomData.count
    }

    private static func parseItems(in decoder: DCMDecoder, for tag: DicomTag) -> [DicomSequenceItem] {
        guard let metadata = decoder.tagMetadataCache[tag.rawValue],
              metadata.offset >= 0,
              metadata.elementLength >= 0,
              metadata.offset + metadata.elementLength <= decoder.dicomData.count else {
            return []
        }

        let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID) ?? .explicitVRLittleEndian
        return (try? DicomSequenceValueParser.parseItems(
            in: decoder.dicomData,
            valueOffset: metadata.offset,
            valueLength: metadata.elementLength,
            littleEndian: decoder.littleEndian,
            explicitVR: syntax.isExplicitVR,
            characterSet: decoder.activeCharacterSet
        )) ?? []
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    var dicomSegTrimmedValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    var dicomSegNonEmptyValue: String? {
        let trimmed = dicomSegTrimmedValue
        return trimmed.isEmpty ? nil : trimmed
    }
}
