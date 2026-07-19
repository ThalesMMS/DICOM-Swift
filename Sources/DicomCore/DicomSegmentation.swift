import Foundation

/// DICOM Segmentation Type (0062,0001).
public enum DicomSegmentationType: String, Equatable, Sendable {
    case binary = "BINARY"
    case fractional = "FRACTIONAL"
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
        recommendedDisplayCIELabValue: [UInt16] = []
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
    }
}

/// Row-major pixel data for one SEG frame.
public enum DicomSegmentationPixelData: Equatable, Sendable {
    case binary([UInt8])
    case fractional(values: [UInt8], maximumFractionalValue: Int)

    public var storedValues: [UInt8] {
        switch self {
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

    public func labelmapVoxels(label: UInt16) -> [UInt16] {
        storedValues.map { $0 == 0 ? 0 : label }
    }
}

/// One decoded SEG frame with its referenced segment and resolved geometry.
public struct DicomSegmentationFrame: Equatable, Sendable {
    public let index: Int
    public let segmentNumber: Int
    public let geometry: DicomFrameGeometry?
    public let sourceImageReferences: [DicomSourceImageReference]
    public let pixelData: DicomSegmentationPixelData

    public init(
        index: Int,
        segmentNumber: Int,
        geometry: DicomFrameGeometry? = nil,
        sourceImageReferences: [DicomSourceImageReference] = [],
        pixelData: DicomSegmentationPixelData
    ) {
        self.index = index
        self.segmentNumber = segmentNumber
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
    public let voxels: [UInt16]
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
        self.voxels = voxels
        self.fractionalVoxels = fractionalVoxels
    }
}

/// Parsed DICOM Segmentation object with segment metadata, frames, and labelmaps.
public struct DicomSegmentation: Equatable, Sendable {
    public let sopInstanceUID: String?
    public let segmentationType: DicomSegmentationType
    public let fractionalType: DicomSegmentationFractionalType?
    public let maximumFractionalValue: Int
    public let rows: Int
    public let columns: Int
    public let segments: [DicomSegment]
    public let frames: [DicomSegmentationFrame]
    public let labelmapsBySegment: [Int: DicomSegmentLabelmap]

    public init(
        sopInstanceUID: String? = nil,
        segmentationType: DicomSegmentationType,
        fractionalType: DicomSegmentationFractionalType? = nil,
        maximumFractionalValue: Int = 255,
        rows: Int,
        columns: Int,
        segments: [DicomSegment],
        frames: [DicomSegmentationFrame],
        labelmapsBySegment: [Int: DicomSegmentLabelmap]? = nil
    ) {
        self.sopInstanceUID = sopInstanceUID?.dicomSegNonEmptyValue
        self.segmentationType = segmentationType
        self.fractionalType = fractionalType
        self.maximumFractionalValue = maximumFractionalValue
        self.rows = rows
        self.columns = columns
        self.segments = segments
        self.frames = frames
        self.labelmapsBySegment = labelmapsBySegment ?? Self.makeLabelmaps(
            segments: segments,
            frames: frames,
            rows: rows,
            columns: columns
        )
    }

    public var labelmaps: [DicomSegmentLabelmap] {
        segments.compactMap { labelmapsBySegment[$0.number] }
    }

    private static func makeLabelmaps(
        segments: [DicomSegment],
        frames: [DicomSegmentationFrame],
        rows: Int,
        columns: Int
    ) -> [Int: DicomSegmentLabelmap] {
        var labelmaps: [Int: DicomSegmentLabelmap] = [:]
        for segment in segments {
            let segmentFrames = frames.filter { $0.segmentNumber == segment.number }
            guard !segmentFrames.isEmpty else { continue }
            let voxels = segmentFrames.flatMap {
                $0.pixelData.labelmapVoxels(label: UInt16(clamping: segment.number))
            }
            let fractionalVoxels = segmentFrames.contains { $0.pixelData.maximumFractionalValue != nil }
                ? segmentFrames.flatMap(\.pixelData.storedValues)
                : nil

            labelmaps[segment.number] = DicomSegmentLabelmap(
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
        return labelmaps
    }
}

/// Builder for synthetic or application-generated DICOM Segmentation datasets.
public enum DicomSegmentationBuilder {
    public static let segmentationStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.66.4"

    public static func dataSet(
        from segmentation: DicomSegmentation,
        studyInstanceUID: String,
        seriesInstanceUID: String,
        sopInstanceUID: String? = nil,
        contentLabel: String = "SEGMENTATION"
    ) -> DicomDataSet {
        let instanceUID = sopInstanceUID?.dicomSegNonEmptyValue
            ?? segmentation.sopInstanceUID
            ?? DicomDataSetWriter.makeUID()
        let bitsAllocated = segmentation.segmentationType == .binary ? 1 : 8
        let highBit = bitsAllocated - 1

        var elements: [DicomDataElement] = [
            string(.sopClassUID, vr: .UI, segmentationStorageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, instanceUID),
            string(.studyInstanceUID, vr: .UI, studyInstanceUID),
            string(.seriesInstanceUID, vr: .UI, seriesInstanceUID),
            string(.modality, vr: .CS, "SEG"),
            string(.contentLabel, vr: .LO, contentLabel),
            us(.samplesPerPixel, 1),
            string(.photometricInterpretation, vr: .CS, "MONOCHROME2"),
            string(.numberOfFrames, vr: .IS, String(segmentation.frames.count)),
            us(.rows, segmentation.rows),
            us(.columns, segmentation.columns),
            us(.bitsAllocated, bitsAllocated),
            us(.bitsStored, bitsAllocated),
            us(.highBit, highBit),
            us(.pixelRepresentation, 0),
            string(.segmentationType, vr: .CS, segmentation.segmentationType.rawValue),
            sequence(.segmentSequence, segmentation.segments.map(segmentDataSet)),
            sequence(.perFrameFunctionalGroupsSequence, segmentation.frames.map(frameDataSet)),
            bytes(.pixelData, vr: .OB, pixelData(from: segmentation))
        ]
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

    private static func segmentDataSet(_ segment: DicomSegment) -> DicomDataSet {
        var elements: [DicomDataElement] = [
            us(.segmentNumber, segment.number),
            string(.segmentLabel, vr: .LO, segment.label)
        ]
        if let description = segment.description {
            elements.append(string(.segmentDescription, vr: .ST, description))
        }
        if let algorithmType = segment.algorithmType {
            elements.append(string(.segmentAlgorithmType, vr: .CS, algorithmType))
        }
        if let algorithmName = segment.algorithmName {
            elements.append(string(.segmentAlgorithmName, vr: .LO, algorithmName))
        }
        if let category = segment.propertyCategory {
            elements.append(sequence(.segmentedPropertyCategoryCodeSequence, [codedConceptDataSet(category)]))
        }
        if let type = segment.propertyType {
            elements.append(sequence(.segmentedPropertyTypeCodeSequence, [codedConceptDataSet(type)]))
        }
        if let trackingID = segment.trackingID {
            elements.append(string(.trackingID, vr: .LO, trackingID))
        }
        if let trackingUID = segment.trackingUID {
            elements.append(string(.trackingUID, vr: .UI, trackingUID))
        }
        if !segment.recommendedDisplayCIELabValue.isEmpty {
            elements.append(DicomDataElement(
                tag: DicomTag.recommendedDisplayCIELabValue.rawValue,
                vr: .US,
                value: .unsignedIntegers(segment.recommendedDisplayCIELabValue.map(UInt.init))
            ))
        }
        return DicomDataSet(elements: elements)
    }

    private static func frameDataSet(_ frame: DicomSegmentationFrame) -> DicomDataSet {
        var elements = [
            sequence(.segmentIdentificationSequence, [
                DicomDataSet(elements: [
                    us(.referencedSegmentNumber, frame.segmentNumber)
                ])
            ])
        ]

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
            if let frameContent = geometry.frameContent {
                var contentElements: [DicomDataElement] = []
                if !frameContent.dimensionIndexValues.isEmpty {
                    contentElements.append(ul(.dimensionIndexValues, frameContent.dimensionIndexValues))
                }
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
                if !contentElements.isEmpty {
                    elements.append(sequence(.frameContentSequence, [DicomDataSet(elements: contentElements)]))
                }
            }
        }

        if !frame.sourceImageReferences.isEmpty {
            elements.append(sequence(.derivationImageSequence, [
                DicomDataSet(elements: [
                    sequence(.sourceImageSequence, frame.sourceImageReferences.map(sourceImageDataSet))
                ])
            ]))
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
        return DicomDataSet(elements: elements)
    }

    private static func pixelData(from segmentation: DicomSegmentation) -> Data {
        let pixelCount = segmentation.rows * segmentation.columns
        switch segmentation.segmentationType {
        case .binary:
            var data = Data()
            var currentByte: UInt8 = 0
            var bitIndex = 0
            for frame in segmentation.frames {
                let values = frame.pixelData.storedValues
                for pixelIndex in 0..<pixelCount {
                    if (values[safe: pixelIndex] ?? 0) != 0 {
                        currentByte |= UInt8(1 << (bitIndex % 8))
                    }
                    bitIndex += 1
                    if bitIndex % 8 == 0 {
                        data.append(currentByte)
                        currentByte = 0
                    }
                }
            }
            if bitIndex % 8 != 0 {
                data.append(currentByte)
            }
            return data
        case .fractional:
            var data = Data()
            for frame in segmentation.frames {
                let values = frame.pixelData.storedValues
                for pixelIndex in 0..<pixelCount {
                    data.append(values[safe: pixelIndex] ?? 0)
                }
            }
            return data
        }
    }

    private static func sequence(_ tag: DicomTag, _ dataSets: [DicomDataSet]) -> DicomDataElement {
        DicomDataElement(
            tag: tag.rawValue,
            vr: .SQ,
            value: .sequence(dataSets.map { DicomSequenceItem(dataSet: $0) })
        )
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
        DicomDataElement(tag: tag.rawValue, vr: .DS, value: .strings(values.map { String($0) }))
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
        guard let segmentationType = segmentationType(from: decoder, bitsAllocated: bitsAllocated) else { return nil }

        let segmentItems = parseItems(in: decoder, for: .segmentSequence)
        let segments = segmentItems.compactMap(segment)
        guard !segments.isEmpty else { return nil }

        let sharedItems = parseItems(in: decoder, for: .sharedFunctionalGroupsSequence)
        let perFrameItems = parseItems(in: decoder, for: .perFrameFunctionalGroupsSequence)
        let functionalGroups = DicomEnhancedMultiframeParser.makeFunctionalGroups(
            sharedItems: sharedItems,
            perFrameItems: perFrameItems,
            declaredFrameCount: frameCount
        )

        var frames: [DicomSegmentationFrame] = []
        frames.reserveCapacity(frameCount)
        for frameIndex in 0..<frameCount {
            guard let pixelData = framePixelData(
                decoder: decoder,
                frameIndex: frameIndex,
                rows: rows,
                columns: columns,
                frameCount: frameCount,
                segmentationType: segmentationType,
                maximumFractionalValue: maximumFractionalValue,
                bitsAllocated: bitsAllocated
            ) else {
                return nil
            }

            guard let segmentNumber = segmentNumber(
                frameIndex: frameIndex,
                perFrameItems: perFrameItems,
                fallbackSegments: segments
            ) else {
                return nil
            }

            let geometry = functionalGroups?.geometry(forFrame: frameIndex)
            frames.append(DicomSegmentationFrame(
                index: frameIndex,
                segmentNumber: segmentNumber,
                geometry: geometry,
                sourceImageReferences: geometry?.sourceImageReferences ?? [],
                pixelData: pixelData
            ))
        }

        return DicomSegmentation(
            sopInstanceUID: decoder.info(for: .sopInstanceUID),
            segmentationType: segmentationType,
            fractionalType: fractionalType(from: decoder),
            maximumFractionalValue: maximumFractionalValue,
            rows: rows,
            columns: columns,
            segments: segments,
            frames: frames
        )
    }

    private static func isSegmentationObject(_ decoder: DCMDecoder) -> Bool {
        decoder.info(for: .sopClassUID).dicomSegTrimmedValue == DicomSegmentationBuilder.segmentationStorageSOPClassUID ||
            decoder.info(for: .modality).dicomSegTrimmedValue == "SEG" ||
            decoder.tagMetadataCache[DicomTag.segmentSequence.rawValue] != nil
    }

    private static func segmentationType(from decoder: DCMDecoder, bitsAllocated: Int) -> DicomSegmentationType? {
        if let type = DicomSegmentationType(rawValue: decoder.info(for: .segmentationType).dicomSegTrimmedValue) {
            return type
        }
        if bitsAllocated == 1 {
            return .binary
        }
        if bitsAllocated == 8 {
            return .fractional
        }
        return nil
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
            recommendedDisplayCIELabValue: dataSet.ints(for: .recommendedDisplayCIELabValue).compactMap { UInt16(exactly: $0) }
        )
    }

    private static func segmentNumber(
        frameIndex: Int,
        perFrameItems: [DicomSequenceItem],
        fallbackSegments: [DicomSegment]
    ) -> Int? {
        let segmentNumber = perFrameItems[safe: frameIndex]?.dataSet
            .sequenceItems(for: .segmentIdentificationSequence)
            .first?
            .dataSet
            .int(for: .referencedSegmentNumber)
        return segmentNumber ?? (fallbackSegments.count == 1 ? fallbackSegments[0].number : nil)
    }

    private static func framePixelData(
        decoder: DCMDecoder,
        frameIndex: Int,
        rows: Int,
        columns: Int,
        frameCount: Int,
        segmentationType: DicomSegmentationType,
        maximumFractionalValue: Int,
        bitsAllocated: Int
    ) -> DicomSegmentationPixelData? {
        guard let pixelDataRange = pixelDataRange(in: decoder) else { return nil }
        let pixelCount = rows * columns

        switch segmentationType {
        case .binary:
            guard bitsAllocated == 1 else { return nil }
            let totalBits = pixelCount * frameCount
            let requiredBytes = (totalBits + 7) / 8
            guard pixelDataRange.lowerBound + requiredBytes <= pixelDataRange.upperBound else { return nil }

            var values: [UInt8] = []
            values.reserveCapacity(pixelCount)
            for pixelIndex in 0..<pixelCount {
                let bitIndex = frameIndex * pixelCount + pixelIndex
                let byteOffset = pixelDataRange.lowerBound + bitIndex / 8
                let bit = (decoder.dicomData[byteOffset] >> UInt8(bitIndex % 8)) & 0x01
                values.append(bit)
            }
            return .binary(values)
        case .fractional:
            guard bitsAllocated == 8 else { return nil }
            let frameStart = pixelDataRange.lowerBound + frameIndex * pixelCount
            let frameEnd = frameStart + pixelCount
            guard frameEnd <= pixelDataRange.upperBound else { return nil }
            return .fractional(
                values: Array(decoder.dicomData[frameStart..<frameEnd]),
                maximumFractionalValue: maximumFractionalValue
            )
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
