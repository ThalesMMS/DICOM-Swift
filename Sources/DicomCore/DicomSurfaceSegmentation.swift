//
//  DicomSurfaceSegmentation.swift
//  DicomCore
//
//  Safe decoding for Surface Segmentation Storage polygonal surfaces.
//

import Foundation

/// A safely decoded DICOM Surface Segmentation Storage document.
public struct DicomSurfaceSegmentation: Equatable, Sendable {
    /// Surface Segmentation Storage SOP Class UID.
    public static let storageSOPClassUID = "1.2.840.10008.5.1.4.1.1.66.5"

    /// SOP Instance UID of the decoded document, when present.
    public let sopInstanceUID: String?
    /// Frame of Reference UID shared by the patient-coordinate surfaces.
    public let frameOfReferenceUID: String?
    /// Explicitly referenced source Series Instance UIDs.
    public let referencedSeriesInstanceUIDs: [String]
    /// Segment semantics and source-instance references.
    public let segments: [DicomSurfaceSegment]
    /// Validated polygonal surfaces in patient coordinates.
    public let surfaces: [DicomSurface]

    public let contentLabel: String?
    public let contentDescription: String?
    public let contentCreatorName: String?
    public let referencedInstancesBySeries: [String: [DicomSourceImageReference]]

    /// Creates a decoded Surface Segmentation document.
    public init(
        sopInstanceUID: String? = nil,
        frameOfReferenceUID: String? = nil,
        referencedSeriesInstanceUIDs: [String] = [],
        segments: [DicomSurfaceSegment] = [],
        surfaces: [DicomSurface],
        contentLabel: String? = nil,
        contentDescription: String? = nil,
        contentCreatorName: String? = nil,
        referencedInstancesBySeries: [String: [DicomSourceImageReference]] = [:]
    ) {
        self.sopInstanceUID = sopInstanceUID
        self.frameOfReferenceUID = frameOfReferenceUID
        self.referencedSeriesInstanceUIDs = referencedSeriesInstanceUIDs
        self.segments = segments
        self.surfaces = surfaces
        self.contentLabel = contentLabel
        self.contentDescription = contentDescription
        self.contentCreatorName = contentCreatorName
        self.referencedInstancesBySeries = referencedInstancesBySeries
    }
}

extension DCMDecoder {
    /// Decodes a Surface Segmentation document when the dataset has the exact SOP Class and valid geometry.
    public var surfaceSegmentation: DicomSurfaceSegmentation? {
        synchronized {
            DicomSurfaceSegmentationParser.makeSurfaceSegmentation(from: self)
        }
    }
}

enum DicomSurfaceSegmentationParser {
    private static let maximumElementBytes = 256 * 1_024 * 1_024
    private static let maximumDecodedBytes = 512 * 1_024 * 1_024

    static func makeSurfaceSegmentation(from decoder: DCMDecoder) -> DicomSurfaceSegmentation? {
        guard decoder.info(for: .sopClassUID).dicomSurfaceTrimmedValue == DicomSurfaceSegmentation.storageSOPClassUID,
              let declaredCount = uint32Value(in: decoder, for: .numberOfSurfaces),
              declaredCount > 0 else {
            return nil
        }

        let surfaceItems = parseItems(in: decoder, for: .surfaceSequence, limitsLargeValues: true)
        guard surfaceItems.count == declaredCount else { return nil }
        var decodedByteCount = 0
        var surfaces: [DicomSurface] = []
        surfaces.reserveCapacity(surfaceItems.count)
        for (index, item) in surfaceItems.enumerated() {
            guard let surface = surface(from: item.dataSet, littleEndian: decoder.littleEndian),
                  surface.number == index + 1,
                  addDecodedBytes(for: surface, to: &decodedByteCount) else {
                return nil
            }
            surfaces.append(surface)
        }

        let segmentItems = parseItems(in: decoder, for: .segmentSequence)
        let segments = segmentItems.compactMap(segment)
        let surfaceNumbers = Set(surfaces.map(\.number))
        guard !segmentItems.isEmpty,
              segments.count == segmentItems.count,
              Set(segments.map(\.number)).count == segments.count,
              segments.allSatisfy({
            !$0.referencedSurfaceNumbers.isEmpty && Set($0.referencedSurfaceNumbers).isSubset(of: surfaceNumbers)
        }) else {
            return nil
        }

        return DicomSurfaceSegmentation(
            sopInstanceUID: decoder.info(for: .sopInstanceUID).dicomSurfaceNonEmptyValue,
            frameOfReferenceUID: decoder.info(for: .frameOfReferenceUID).dicomSurfaceNonEmptyValue,
            referencedSeriesInstanceUIDs: parseItems(in: decoder, for: .referencedSeriesSequence)
                .compactMap { $0.dataSet.string(for: .seriesInstanceUID)?.dicomSurfaceNonEmptyValue },
            segments: segments,
            surfaces: surfaces,
            contentLabel: decoder.dataSet.string(for: 0x00700080),
            contentDescription: decoder.dataSet.string(for: 0x00700081)?.dicomSurfaceNonEmptyValue,
            contentCreatorName: decoder.dataSet.string(for: 0x00700084)?.dicomSurfaceNonEmptyValue,
            referencedInstancesBySeries: decoder.dataSet.sequenceItems(for: 0x00081115).reduce(into: [:]) { result, item in
                if let uid = item.dataSet.string(for: 0x0020000E) {
                    result[uid, default: []].append(contentsOf: item.dataSet.sequenceItems(for: 0x0008114A).map {
                        DicomRTStructureSetBuilder.readReference($0.dataSet)
                    })
                }
            }
        )
    }

    private static func surface(from dataSet: DicomDataSet, littleEndian: Bool) -> DicomSurface? {
        guard let number = dataSet.int(for: .surfaceNumber), number > 0,
              let pointsItem = dataSet.sequenceItems(for: .surfacePointsSequence).first else {
            return nil
        }
        let pointDataSet = pointsItem.dataSet
        guard let pointCount = pointDataSet.int(for: .numberOfSurfacePoints), pointCount > 0 else {
            return nil
        }
        let (coordinateCount, coordinateCountOverflow) = pointCount.multipliedReportingOverflow(by: 3)
        guard !coordinateCountOverflow else { return nil }
        let coordinates = pointDataSet.floats(for: .pointCoordinatesData)
        guard coordinates.count == coordinateCount, coordinates.allSatisfy(\.isFinite) else { return nil }
        let points = stride(from: 0, to: coordinates.count, by: 3).map {
            SIMD3<Float>(Float(coordinates[$0]), Float(coordinates[$0 + 1]), Float(coordinates[$0 + 2]))
        }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }

        let normals: [SIMD3<Float>]
        if let normalsItem = dataSet.sequenceItems(for: .surfacePointsNormalsSequence).first {
            let normalDataSet = normalsItem.dataSet
            let values = normalDataSet.floats(for: .vectorCoordinateData)
            guard normalDataSet.int(for: .numberOfVectors) == pointCount,
                  normalDataSet.int(for: .vectorDimensionality) == 3,
                  values.count == coordinateCount,
                  values.allSatisfy(\.isFinite) else {
                return nil
            }
            normals = stride(from: 0, to: values.count, by: 3).map {
                SIMD3<Float>(Float(values[$0]), Float(values[$0 + 1]), Float(values[$0 + 2]))
            }
            guard normals.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
        } else {
            normals = []
        }

        guard let primitiveItem = dataSet.sequenceItems(for: .surfaceMeshPrimitivesSequence).first,
              let primitives = primitives(
                  from: primitiveItem.dataSet,
                  pointCount: pointCount,
                  littleEndian: littleEndian
              ),
              !primitives.isEmpty else {
            return nil
        }

        let color = dataSet.ints(for: .recommendedDisplayCIELabValue).compactMap(UInt16.init(exactly:))
        guard color.isEmpty || color.count == 3 else { return nil }
        let opacity = dataSet.float(for: .recommendedPresentationOpacity).map(Float.init)
        guard opacity?.isFinite != false,
              opacity.map({ (0...1).contains($0) }) != false else { return nil }
        return DicomSurface(
            number: number,
            comments: dataSet.string(for: .surfaceComments)?.dicomSurfaceNonEmptyValue,
            recommendedDisplayCIELabValue: color,
            recommendedPresentationOpacity: opacity,
            recommendedPresentationType: dataSet.string(for: .recommendedPresentationType)?.dicomSurfaceNonEmptyValue,
            points: points,
            normals: normals,
            primitives: primitives,
            finiteVolume: DicomSurfaceFlag(rawValue: dataSet.string(for: 0x0066000E) ?? "UNKNOWN") ?? .unknown,
            manifold: DicomSurfaceFlag(rawValue: dataSet.string(for: 0x00660010) ?? "UNKNOWN") ?? .unknown,
            surfaceProcessing: dataSet.string(for: 0x00660009).flatMap { $0 == "YES" ? true : ($0 == "NO" ? false : nil) },
            surfaceProcessingRatio: dataSet.float(for: 0x0066000A).map(Float.init),
            surfaceProcessingDescription: dataSet.string(for: 0x0066000B),
            surfaceProcessingAlgorithm: DicomSurfaceSegmentationBuilder.algorithm(in: dataSet, tag: 0x00660035),
            numberOfSurfacePoints: pointCount,
            pointCoordinatesAccuracy: optionalFloats(pointDataSet, 0x00660017),
            meanPointDistance: pointDataSet.float(for: 0x00660018).map(Float.init),
            maximumPointDistance: pointDataSet.float(for: 0x00660019).map(Float.init),
            pointsBoundingBox: optionalFloats(pointDataSet, 0x0066001A)?.map(Double.init),
            axisOfRotation: vector(pointDataSet, 0x0066001B),
            centerOfRotation: vector(pointDataSet, 0x0066001C),
            vectors: dataSet.sequenceItems(for: 0x00660012).map {
                DicomSurfaceVectorSet(dimensionality: $0.dataSet.int(for: 0x0066001F) ?? 3,
                    coordinates: $0.dataSet.floats(for: 0x00660021).map(Float.init),
                    accuracy: optionalFloats($0.dataSet, 0x00660020))
            }
        )
    }

    private static func primitives(
        from dataSet: DicomDataSet,
        pointCount: Int,
        littleEndian: Bool
    ) -> [DicomSurfacePrimitive]? {
        var result: [DicomSurfacePrimitive] = []
        if let values = indices(in: dataSet, long: .longTrianglePointIndexList, retired: .trianglePointIndexList,
                                littleEndian: littleEndian), !values.isEmpty {
            guard values.count.isMultiple(of: 3), validate(values, pointCount: pointCount) else { return nil }
            result.append(.triangles(values))
        }
        if let values = indices(in: dataSet, long: .longEdgePointIndexList, retired: .edgePointIndexList,
                                littleEndian: littleEndian), !values.isEmpty {
            guard values.count.isMultiple(of: 2), validate(values, pointCount: pointCount) else { return nil }
            result.append(.edges(values))
        }
        for item in dataSet.sequenceItems(for: .triangleStripSequence) {
            guard let values = primitiveIndices(in: item.dataSet, littleEndian: littleEndian),
                  values.count >= 3, validate(values, pointCount: pointCount) else { return nil }
            result.append(.triangleStrip(values))
        }
        for item in dataSet.sequenceItems(for: .triangleFanSequence) {
            guard let values = primitiveIndices(in: item.dataSet, littleEndian: littleEndian),
                  values.count >= 3, validate(values, pointCount: pointCount) else { return nil }
            result.append(.triangleFan(values))
        }
        for item in dataSet.sequenceItems(for: .facetSequence) {
            guard let values = primitiveIndices(in: item.dataSet, littleEndian: littleEndian),
                  values.count >= 3, validate(values, pointCount: pointCount) else { return nil }
            result.append(.facet(values))
        }
        for item in dataSet.sequenceItems(for: .lineSequence) {
            guard let values = primitiveIndices(in: item.dataSet, littleEndian: littleEndian),
                  values.count >= 2, validate(values, pointCount: pointCount) else { return nil }
            result.append(.line(values))
        }
        return result
    }

    private static func primitiveIndices(in dataSet: DicomDataSet, littleEndian: Bool) -> [UInt32]? {
        indices(in: dataSet, long: .longPrimitivePointIndexList, retired: .primitivePointIndexList,
                littleEndian: littleEndian)
    }

    private static func indices(
        in dataSet: DicomDataSet,
        long: DicomTag,
        retired: DicomTag,
        littleEndian: Bool
    ) -> [UInt32]? {
        if let element = dataSet.element(for: long) {
            return element.intValues.compactMap(UInt32.init(exactly:))
        }
        guard let bytes = dataSet.element(for: retired)?.bytesValue else { return nil }
        guard bytes.count.isMultiple(of: 2) else { return nil }
        return stride(from: 0, to: bytes.count, by: 2).map { offset in
            let first = UInt16(bytes[offset])
            let second = UInt16(bytes[offset + 1])
            return UInt32(littleEndian ? (second << 8 | first) : (first << 8 | second))
        }
    }

    private static func validate(_ values: [UInt32], pointCount: Int) -> Bool {
        values.allSatisfy { $0 >= 1 && $0 <= UInt32(pointCount) }
    }

    private static func segment(from item: DicomSequenceItem) -> DicomSurfaceSegment? {
        let dataSet = item.dataSet
        guard let number = dataSet.int(for: .segmentNumber), number > 0,
              let label = dataSet.string(for: .segmentLabel)?.dicomSurfaceNonEmptyValue else {
            return nil
        }
        let references = dataSet.sequenceItems(for: .referencedSurfaceSequence)
            .compactMap { $0.dataSet.int(for: .referencedSurfaceNumber) }
        if let declared = dataSet.int(for: .surfaceCount), declared != references.count { return nil }
        let color = dataSet.ints(for: .recommendedDisplayCIELabValue).compactMap(UInt16.init(exactly:))
        guard color.isEmpty || color.count == 3 else { return nil }
        let surfaceReferences = dataSet.sequenceItems(for: .referencedSurfaceSequence)
        let sourceItems = surfaceReferences.flatMap {
            $0.dataSet.sequenceItems(for: .segmentSurfaceSourceInstanceSequence)
        } + dataSet.sequenceItems(for: .segmentSurfaceSourceInstanceSequence)
        var sources: [DicomSourceImageReference] = []
        for item in sourceItems {
            let reference = DicomRTStructureSetBuilder.readReference(item.dataSet)
            if !sources.contains(reference) { sources.append(reference) }
        }
        return DicomSurfaceSegment(
            number: number,
            label: label,
            recommendedDisplayCIELabValue: color,
            referencedSurfaceNumbers: references,
            sourceImageReferences: sources,
            description: dataSet.string(for: 0x00620006),
            propertyCategory: DicomRTStructureSetBuilder.code(in: dataSet, tag: 0x00620003),
            propertyType: DicomRTStructureSetBuilder.code(in: dataSet, tag: 0x0062000F),
            propertyTypeModifiers: modifiers(dataSet, 0x0062000F, 0x00620011),
            anatomicRegion: DicomRTStructureSetBuilder.code(in: dataSet, tag: 0x00082218),
            anatomicRegionModifiers: modifiers(dataSet, 0x00082218, 0x00082220),
            algorithmIdentification: surfaceReferences.first.flatMap {
                DicomSurfaceSegmentationBuilder.algorithm(in: $0.dataSet, tag: 0x0066002D)
            },
            algorithmType: dataSet.string(for: 0x00620008),
            trackingID: dataSet.string(for: 0x00620020),
            trackingUID: dataSet.string(for: 0x00620021)
        )
    }

    private static func optionalFloats(_ data: DicomDataSet, _ tag: Int) -> [Float]? {
        data.element(for: tag).map { $0.floatValues.map(Float.init) }
    }

    private static func vector(_ data: DicomDataSet, _ tag: Int) -> SIMD3<Float>? {
        let values = data.floats(for: tag).map(Float.init)
        return values.count == 3 ? SIMD3(values[0], values[1], values[2]) : nil
    }

    private static func modifiers(_ data: DicomDataSet, _ parent: Int, _ tag: Int) -> [DicomCodedConcept] {
        guard let item = data.sequenceItems(for: parent).first else { return [] }
        return item.dataSet.sequenceItems(for: tag).compactMap {
            DicomRTStructureSetBuilder.code(in: DicomDataSet(elements: [
                DicomRTStructureSetBuilder.sequence(tag, [$0.dataSet])]), tag: tag)
        }
    }

    static func addDecodedBytes(for surface: DicomSurface, to total: inout Int) -> Bool {
        var indexCount = 0
        for primitive in surface.primitives {
            let valuesCount: Int
            switch primitive {
            case .triangles(let values), .triangleStrip(let values), .triangleFan(let values),
                 .facet(let values), .line(let values), .edges(let values):
                valuesCount = values.count
            }
            let (newCount, overflow) = indexCount.addingReportingOverflow(valuesCount)
            guard !overflow else { return false }
            indexCount = newCount
        }
        var buffers = [(surface.points.count, MemoryLayout<SIMD3<Float>>.stride),
            (surface.normals.count, MemoryLayout<SIMD3<Float>>.stride), (indexCount, MemoryLayout<UInt32>.stride),
            (surface.pointCoordinatesAccuracy?.count ?? 0, MemoryLayout<Float>.stride),
            (surface.pointsBoundingBox?.count ?? 0, MemoryLayout<Double>.stride)]
        for vector in surface.vectors {
            buffers.append((vector.coordinates.count, MemoryLayout<Float>.stride))
            buffers.append((vector.accuracy?.count ?? 0, MemoryLayout<Float>.stride))
        }
        var newTotal = total
        for (count, stride) in buffers {
            let (bytes, bytesOverflow) = count.multipliedReportingOverflow(by: stride)
            let (sum, totalOverflow) = newTotal.addingReportingOverflow(bytes)
            guard !bytesOverflow, !totalOverflow, sum <= maximumDecodedBytes else { return false }
            newTotal = sum
        }
        total = newTotal
        return true
    }

    private static func parseItems(
        in decoder: DCMDecoder,
        for tag: DicomTag,
        limitsLargeValues: Bool = false
    ) -> [DicomSequenceItem] {
        guard let metadata = decoder.tagMetadataCache[tag.rawValue],
              metadata.offset >= 0,
              metadata.elementLength >= 0,
              metadata.offset + metadata.elementLength <= decoder.dicomData.count else {
            return []
        }
        let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID) ?? .explicitVRLittleEndian
        let limit: DicomSequenceValueParser.ValueLengthLimit?
        if limitsLargeValues {
            limit = { nestedTag, _, _ in
                switch nestedTag {
                case DicomTag.pointCoordinatesData.rawValue,
                     DicomTag.vectorCoordinateData.rawValue,
                     DicomTag.longPrimitivePointIndexList.rawValue,
                     DicomTag.longTrianglePointIndexList.rawValue,
                     DicomTag.primitivePointIndexList.rawValue,
                     DicomTag.trianglePointIndexList.rawValue:
                    return maximumElementBytes
                default:
                    return nil
                }
            }
        } else {
            limit = nil
        }
        return (try? DicomSequenceValueParser.parseItems(
            in: decoder.dicomData,
            valueOffset: metadata.offset,
            valueLength: metadata.elementLength,
            littleEndian: decoder.littleEndian,
            explicitVR: syntax.isExplicitVR,
            characterSet: decoder.activeCharacterSet,
            valueLengthLimit: limit
        )) ?? []
    }

    private static func uint32Value(in decoder: DCMDecoder, for tag: DicomTag) -> Int? {
        guard let metadata = decoder.tagMetadataCache[tag.rawValue],
              metadata.elementLength == MemoryLayout<UInt32>.size,
              metadata.offset >= 0,
              metadata.offset + MemoryLayout<UInt32>.size <= decoder.dicomData.count else {
            return nil
        }
        let offset = metadata.offset
        let bytes = (0..<4).map { UInt32(decoder.dicomData[offset + $0]) }
        let value = decoder.littleEndian
            ? bytes[3] << 24 | bytes[2] << 16 | bytes[1] << 8 | bytes[0]
            : bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]
        return Int(exactly: value)
    }
}

private extension String {
    var dicomSurfaceTrimmedValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    var dicomSurfaceNonEmptyValue: String? {
        let value = dicomSurfaceTrimmedValue
        return value.isEmpty ? nil : value
    }
}
