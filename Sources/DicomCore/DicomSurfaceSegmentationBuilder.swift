import Foundation

public enum DicomSurfaceSegmentationBuilder {
    private typealias W = DicomRTStructureSetBuilder

    public static func dataSet(
        from segmentation: DicomSurfaceSegmentation,
        studyInstanceUID: String,
        seriesInstanceUID: String,
        sopInstanceUID: String? = nil,
        options: DicomSurfaceSegmentationBuildOptions = .init()
    ) -> DicomDataSet {
        var elements = [
            W.text(0x00080016, .UI, DicomSurfaceSegmentation.storageSOPClassUID),
            W.text(0x00080018, .UI, sopInstanceUID ?? segmentation.sopInstanceUID ?? DicomDataSetWriter.makeUID()),
            W.text(0x0020000D, .UI, studyInstanceUID), W.text(0x0020000E, .UI, seriesInstanceUID),
            W.text(0x00100010, .PN, options.patientName), W.text(0x00100020, .LO, options.patientID),
            W.text(0x00100030, .DA, options.patientBirthDate), W.text(0x00100040, .CS, options.patientSex),
            W.text(0x00080020, .DA, options.studyDate), W.text(0x00080030, .TM, options.studyTime),
            W.text(0x00080090, .PN, options.referringPhysicianName), W.text(0x00200010, .SH, options.studyID),
            W.text(0x00080050, .SH, options.accessionNumber), W.text(0x00080060, .CS, "SEG"),
            W.text(0x00200011, .IS, String(options.seriesNumber)),
            W.text(0x00200013, .IS, String(options.instanceNumber)),
            W.text(0x00080023, .DA, options.contentDate), W.text(0x00080033, .TM, options.contentTime),
            W.text(0x00080070, .LO, options.manufacturer), W.text(0x00081090, .LO, options.manufacturerModelName),
            W.text(0x00181000, .LO, options.deviceSerialNumber), W.text(0x00181020, .LO, options.softwareVersions),
            W.text(0x00200052, .UI, segmentation.frameOfReferenceUID ?? ""),
            W.text(0x00201040, .LO, options.positionReferenceIndicator),
            W.text(0x00700080, .CS, segmentation.contentLabel ?? "SURFACE"),
            W.text(0x00700081, .LO, segmentation.contentDescription ?? ""),
            W.text(0x00700084, .PN, segmentation.contentCreatorName ?? ""),
            uint(0x00660001, segmentation.surfaces.count),
            W.sequence(0x00660002, segmentation.surfaces.map(surface)),
            W.sequence(0x00620002, segmentation.segments.map(segment))
        ]
        let declared = Set(segmentation.referencedSeriesInstanceUIDs)
        let series = segmentation.referencedSeriesInstanceUIDs + segmentation.referencedInstancesBySeries.keys
            .filter { !declared.contains($0) }.sorted()
        if !series.isEmpty {
            elements.append(W.sequence(0x00081115, series.map { uid in
                DicomDataSet(elements: [W.text(0x0020000E, .UI, uid),
                    W.sequence(0x0008114A, (segmentation.referencedInstancesBySeries[uid] ?? []).map(W.reference))])
            }))
        }
        return DicomDataSet(elements: elements)
    }

    private static func segment(_ value: DicomSurfaceSegment) -> DicomDataSet {
        var elements = [uint(0x00620004, value.number, .US), W.text(0x00620005, .LO, value.label),
            W.text(0x00620008, .CS, value.algorithmType ?? "MANUAL"), uint(0x0066002A, value.referencedSurfaceNumbers.count),
            W.sequence(0x0066002B, value.referencedSurfaceNumbers.map { number in
                DicomDataSet(elements: [uint(0x0066002C, number),
                    W.sequence(0x0066002D, value.algorithmIdentification.map { [algorithmDataSet($0)] } ?? []),
                    W.sequence(0x0066002E, value.sourceImageReferences.map(W.reference))])
            })]
        if let description = value.description { elements.append(W.text(0x00620006, .ST, description)) }
        if let code = value.propertyCategory { elements.append(W.sequence(0x00620003, [W.codeDataSet(code)])) }
        if let code = value.propertyType {
            elements.append(W.sequence(0x0062000F, [codeWithModifiers(code, value.propertyTypeModifiers, 0x00620011)]))
        }
        if let code = value.anatomicRegion {
            elements.append(W.sequence(0x00082218, [codeWithModifiers(code, value.anatomicRegionModifiers, 0x00082220)]))
        }
        if let tracking = value.trackingID { elements.append(W.text(0x00620020, .UT, tracking)) }
        if let tracking = value.trackingUID { elements.append(W.text(0x00620021, .UI, tracking)) }
        if !value.recommendedDisplayCIELabValue.isEmpty {
            elements.append(DicomDataElement(tag: 0x0062000D, vr: .US,
                value: .unsignedIntegers(value.recommendedDisplayCIELabValue.map(UInt.init))))
        }
        return DicomDataSet(elements: elements)
    }

    private static func codeWithModifiers(_ code: DicomCodedConcept, _ modifiers: [DicomCodedConcept],
                                          _ tag: Int) -> DicomDataSet {
        var elements = W.codeDataSet(code).elements
        if !modifiers.isEmpty { elements.append(W.sequence(tag, modifiers.map(W.codeDataSet))) }
        return DicomDataSet(elements: elements)
    }

    private static func surface(_ value: DicomSurface) -> DicomDataSet {
        var points = [uint(0x00660015, value.numberOfSurfacePoints),
                      floats(0x00660016, value.points.flatMap { [$0.x, $0.y, $0.z] }, .OF)]
        if let accuracy = value.pointCoordinatesAccuracy { points.append(floats(0x00660017, accuracy)) }
        if let distance = value.meanPointDistance { points.append(floats(0x00660018, [distance])) }
        if let distance = value.maximumPointDistance { points.append(floats(0x00660019, [distance])) }
        if let box = value.pointsBoundingBox { points.append(floats(0x0066001A, box.map(Float.init))) }
        if let axis = value.axisOfRotation { points.append(floats(0x0066001B, [axis.x, axis.y, axis.z])) }
        if let center = value.centerOfRotation { points.append(floats(0x0066001C, [center.x, center.y, center.z])) }
        var primitives: [DicomDataElement] = [indices(0x00660043, [])]
        var sequences: [Int: [DicomDataSet]] = [:]
        var triangles: [UInt32] = [], edges: [UInt32] = []
        for primitive in value.primitives {
            switch primitive {
            case .triangles(let indices): triangles.append(contentsOf: indices)
            case .edges(let indices): edges.append(contentsOf: indices)
            case .triangleStrip(let indices): sequences[0x00660026, default: []].append(indexItem(indices))
            case .triangleFan(let indices): sequences[0x00660027, default: []].append(indexItem(indices))
            case .facet(let indices): sequences[0x00660034, default: []].append(indexItem(indices))
            case .line(let indices): sequences[0x00660028, default: []].append(indexItem(indices))
            }
        }
        primitives.append(indices(0x00660041, triangles))
        primitives.append(indices(0x00660042, edges))
        primitives.append(contentsOf: [0x00660026, 0x00660027, 0x00660028, 0x00660034].map { W.sequence($0, sequences[$0] ?? []) })
        let color = value.recommendedDisplayCIELabValue.isEmpty ? [UInt16(65535), 32768, 32768]
            : value.recommendedDisplayCIELabValue
        var elements = [uint(0x00660003, value.number), W.text(0x0066000E, .CS, value.finiteVolume.rawValue),
            W.text(0x00660010, .CS, value.manifold.rawValue),
            W.text(0x00660009, .CS, value.surfaceProcessing.map { $0 ? "YES" : "NO" } ?? ""),
            uint(0x0062000C, 65535, .US),
            DicomDataElement(tag: 0x0062000D, vr: .US, value: .unsignedIntegers(color.map(UInt.init))),
            floats(0x0066000C, [value.recommendedPresentationOpacity ?? 1]),
            W.text(0x0066000D, .CS, value.recommendedPresentationType ?? "SURFACE"),
            W.sequence(0x00660011, [DicomDataSet(elements: points)]),
            W.sequence(0x00660012, value.vectors.map { vector in
                var item = [uint(0x0066001E, vector.dimensionality > 0
                    ? vector.coordinates.count / vector.dimensionality : 0),
                    uint(0x0066001F, vector.dimensionality, .US), floats(0x00660021, vector.coordinates, .OF)]
                if let accuracy = vector.accuracy { item.append(floats(0x00660020, accuracy)) }
                return DicomDataSet(elements: item)
            }), W.sequence(0x00660013, [DicomDataSet(elements: primitives)])]
        if let comments = value.comments { elements.append(W.text(0x00660004, .LT, comments)) }
        if value.surfaceProcessing == true || value.surfaceProcessingRatio != nil {
            elements.append(floats(0x0066000A, value.surfaceProcessingRatio.map { [$0] } ?? []))
        }
        if value.surfaceProcessing == true || value.surfaceProcessingAlgorithm != nil {
            elements.append(W.sequence(0x00660035, value.surfaceProcessingAlgorithm.map { [algorithmDataSet($0)] } ?? []))
        }
        if let description = value.surfaceProcessingDescription { elements.append(W.text(0x0066000B, .LO, description)) }
        return DicomDataSet(elements: elements)
    }

    static func algorithm(in data: DicomDataSet, tag: Int) -> DicomAlgorithmIdentification? {
        guard let item = data.sequenceItems(for: tag).first?.dataSet,
              let name = item.string(for: 0x00660036), let version = item.string(for: 0x00660031),
              let family = W.code(in: item, tag: 0x0066002F) else { return nil }
        return .init(name: name, version: version, family: family, parameters: item.string(for: 0x00660032))
    }

    static func algorithmDataSet(_ value: DicomAlgorithmIdentification) -> DicomDataSet {
        var elements = [W.text(0x00660036, .LO, value.name), W.text(0x00660031, .LO, value.version),
                        W.sequence(0x0066002F, [W.codeDataSet(value.family)])]
        if let parameters = value.parameters { elements.append(W.text(0x00660032, .LT, parameters)) }
        return DicomDataSet(elements: elements)
    }

    private static func uint(_ tag: Int, _ value: Int, _ vr: DicomVR = .UL) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: vr, value: .unsignedIntegers([UInt(value)]))
    }

    private static func floats(_ tag: Int, _ values: [Float], _ vr: DicomVR = .FL) -> DicomDataElement {
        if vr == .OF {
            let bytes = values.flatMap { value -> [UInt8] in
                let bits = value.bitPattern
                return (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
            }
            return DicomDataElement(tag: tag, vr: vr, value: .bytes(Data(bytes)))
        }
        return DicomDataElement(tag: tag, vr: vr, value: .floats(values.map(Double.init)))
    }

    private static func indices(_ tag: Int, _ values: [UInt32]) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: .OL, value: .unsignedIntegers(values.map(UInt.init)))
    }

    private static func indexItem(_ values: [UInt32]) -> DicomDataSet {
        DicomDataSet(elements: [indices(0x00660040, values)])
    }
}
