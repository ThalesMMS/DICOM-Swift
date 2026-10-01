import Foundation
import simd
import XCTest
@testable import DicomCore

final class DicomGeometryCorpusTests: XCTestCase {
    static let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ClinicalInterop")
    static let frameUID = "2.25.23460099"
    static let imageSeriesUID = "2.25.23460098"
    static let orientation = DicomPlaneOrientation(row: SIMD3(sqrt(3) / 2, 0, -0.5), column: SIMD3(0, 1, 0))
    static let category = DicomCodedConcept(codeValue: "91723000", codingSchemeDesignator: "SCT",
                                          codeMeaning: "Anatomical Structure")
    static let property = DicomCodedConcept(codeValue: "85756007", codingSchemeDesignator: "SCT",
                                          codeMeaning: "Tissue")
    static let algorithm = DicomAlgorithmIdentification(name: "PARITY", version: "1",
        family: .init(codeValue: "123101", codingSchemeDesignator: "DCM", codeMeaning: "Neighborhood Analysis"))

    static func imageReference(_ slice: Int) -> DicomSourceImageReference {
        .init(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
              referencedSOPInstanceUID: "2.25.234601\(slice)", referencedFrameNumbers: [])
    }

    static func position(_ x: Double, _ y: Double, _ slice: Double) -> SIMD3<Double> {
        orientation.row * x + orientation.column * y + orientation.normal * (slice * 2.5)
    }

    static func segmentation(_ type: DicomSegmentationType, odd: Bool = false) -> DicomSegmentation {
        let rows = odd ? 3 : 4, columns = odd ? 5 : 4
        let slices = type == .fractional ? [0, 2] : [0, 1, 2]
        let segments = (1...(type == .labelmap ? 3 : (type == .fractional ? 2 : 1))).map {
            DicomSegment(number: $0, label: "PARITY_\($0)", algorithmType: "MANUAL",
                         propertyCategory: category, propertyType: property)
        }
        let frames = slices.enumerated().map { index, slice in
            let pixelData: DicomSegmentationPixelData
            switch type {
            case .labelmap: pixelData = .labelmap(.uint16((0..<(rows * columns)).map { UInt16(($0 + index) % 3 + 1) }))
            case .fractional:
                pixelData = .fractional(values: (0..<(rows * columns)).map { UInt8(($0 * 13 + index) % 201) },
                                        maximumFractionalValue: 200)
            default: pixelData = .binary((0..<(rows * columns)).map { UInt8(($0 + index) % 2) })
            }
            return DicomSegmentationFrame(index: index, segmentNumber: type == .labelmap ? 0 : 1,
                geometry: .init(frameIndex: index, imagePositionPatient: position(0, 0, Double(slice)),
                    imageOrientationPatient: orientation,
                    pixelMeasures: .init(pixelSpacing: SIMD2(0.7, 0.9), sliceThickness: 2.5, spacingBetweenSlices: 2.5)),
                sourceImageReferences: [imageReference(slice)], pixelData: pixelData)
        }
        return DicomSegmentation(sopInstanceUID: "2.25.234602\(type == .labelmap ? 1 : (odd ? 3 : 2))",
            frameOfReferenceUID: frameUID, segmentationType: type,
            fractionalType: type == .fractional ? .probability : nil, maximumFractionalValue: 200,
            rows: rows, columns: columns, referencedSeriesInstanceUIDs: [imageSeriesUID], segments: segments,
            frames: frames, segmentsOverlap: .no, contentLabel: "PARITY",
            referencedInstancesBySeries: [imageSeriesUID: slices.map(imageReference)])
    }

    static func rtStructureSet() -> DicomRTStructureSet {
        func square(_ x: Double, _ y: Double, _ size: Double, _ slice: Int, _ type: String) -> DicomRTContour {
            .init(number: nil, geometricType: type,
                points: [(x, y), (x + size, y), (x + size, y + size), (x, y + size)].map {
                    position($0.0, $0.1, Double(slice))
                }, sourceImageReferences: [imageReference(slice)])
        }
        let roiContours = [
            DicomRTROIContour(referencedROINumber: 1, displayColor: [255, 0, 0], contours: [
                square(1, 1, 10, 0, "CLOSEDPLANAR_XOR"), square(3, 3, 2, 0, "CLOSEDPLANAR_XOR")]),
            DicomRTROIContour(referencedROINumber: 2, displayColor: [0, 255, 0], contours: [
                square(1, 1, 2, 0, "CLOSED_PLANAR"), square(6, 1, 2, 0, "CLOSED_PLANAR"),
                square(1, 1, 2, 1, "CLOSED_PLANAR")]),
            DicomRTROIContour(referencedROINumber: 3, contours: [
                .init(geometricType: "POINT", points: [position(2, 2, 0)], sourceImageReferences: [imageReference(0)])])
        ]
        return .init(sopInstanceUID: "2.25.2346031", label: "PARITY", referencedSeriesInstanceUIDs: [imageSeriesUID],
            rois: (1...3).map { .init(number: $0, name: "PARITY_\($0)", referencedFrameOfReferenceUID: frameUID,
                                    generationAlgorithm: "MANUAL") }, roiContours: roiContours,
            structureSetDate: "20260101", structureSetTime: "000000",
            referencedFramesOfReference: [.init(frameOfReferenceUID: frameUID, studies: [
                .init(referencedSOPClassUID: "1.2.840.10008.3.1.2.3.1", referencedSOPInstanceUID: "2.25.2346001",
                    series: [.init(seriesInstanceUID: imageSeriesUID, instances: [imageReference(0), imageReference(1)])])])])
    }

    static func cube() -> DicomSurfaceSegmentation {
        let points: [SIMD3<Float>] = [.init(0, 0, 0), .init(10, 0, 0), .init(10, 10, 0), .init(0, 10, 0),
                                     .init(0, 0, 10), .init(10, 0, 10), .init(10, 10, 10), .init(0, 10, 10)]
        let triangles: [UInt32] = [1, 3, 2, 1, 4, 3, 5, 6, 7, 5, 7, 8, 1, 2, 6, 1, 6, 5,
                                   2, 3, 7, 2, 7, 6, 3, 4, 8, 3, 8, 7, 4, 1, 5, 4, 5, 8]
        return .init(sopInstanceUID: "2.25.2346041", frameOfReferenceUID: frameUID,
            segments: [.init(number: 1, label: "PARITY_CUBE", referencedSurfaceNumbers: [1],
                propertyCategory: category, propertyType: property, algorithmIdentification: algorithm,
                algorithmType: "MANUAL")], surfaces: [
                    .init(number: 1, recommendedDisplayCIELabValue: [65535, 32768, 32768],
                        recommendedPresentationOpacity: 1, recommendedPresentationType: "SURFACE", points: points,
                        normals: points.map { simd_normalize($0 - SIMD3<Float>(repeating: 5)) },
                        primitives: [.triangles(triangles)], finiteVolume: .yes, manifold: .yes,
                        surfaceProcessing: false)
                ], contentLabel: "PARITY")
    }

    static func bytes(_ dataSet: DicomDataSet) throws -> Data {
        try DicomDataSetWriter.part10Data(from: dataSet, options: .init(
            mediaStorageSOPClassUID: try XCTUnwrap(dataSet.string(for: .sopClassUID)),
            mediaStorageSOPInstanceUID: try XCTUnwrap(dataSet.string(for: .sopInstanceUID))))
    }

    static func surfaceDataSet() -> DicomDataSet {
        var options = DicomSurfaceSegmentationBuildOptions()
        options.patientName = "PARITY^SURFACE"
        options.patientID = "PARITY"
        options.contentDate = "20260101"
        options.contentTime = "000000"
        return DicomSurfaceSegmentationBuilder.dataSet(from: cube(), studyInstanceUID: "2.25.2346001",
            seriesInstanceUID: "2.25.2346042", options: options)
    }

    static func newFixtures() throws -> [(name: String, data: Data)] {
        var options = DicomRTStructureSetBuildOptions()
        options.patientName = "PARITY^RTSTRUCT"
        options.patientID = "PARITY"
        var result: [(name: String, data: Data)] = []
        for (name, type) in [("seg_labelmap.dcm", DicomSegmentationType.labelmap),
                             ("seg_fractional_sparse.dcm", .fractional)] {
            result.append((name, try bytes(DicomSegmentationBuilder.dataSet(from: segmentation(type),
                studyInstanceUID: "2.25.2346001", seriesInstanceUID: "2.25.2346029",
                options: .init(patientName: "PARITY^SEG", patientID: "PARITY", contentDate: "20260101", contentTime: "000000")))))
        }
        result.append(("rtstruct_multiloop_xor.dcm", try bytes(DicomRTStructureSetBuilder.dataSet(
            from: rtStructureSet(), studyInstanceUID: "2.25.2346001", seriesInstanceUID: "2.25.2346032", options: options))))
        result.append(("surface_cube.dcm", try bytes(surfaceDataSet())))
        return result
    }

    func test_segmentationFixtures_preserveObliqueAnisotropicAndSparseGeometry() throws {
        for fixture in try Self.newFixtures() where fixture.name.hasPrefix("seg_") {
            let decoder = try DCMDecoder(data: fixture.data)
            let segmentation = try XCTUnwrap(decoder.segmentation)
            XCTAssertEqual(decoder.intValue(for: .bitsAllocated), 8)
            let geometry = try XCTUnwrap(segmentation.frames.first?.geometry)
            XCTAssertEqual(geometry.imageOrientationPatient?.row.x ?? 0, sqrt(3) / 2, accuracy: 1e-8)
            XCTAssertEqual(geometry.imageOrientationPatient?.row.z ?? 0, -0.5, accuracy: 1e-8)
            XCTAssertEqual(geometry.pixelMeasures?.pixelSpacing, SIMD2(0.7, 0.9))
            XCTAssertEqual(geometry.pixelMeasures?.sliceThickness, 2.5)
            if fixture.name == "seg_labelmap.dcm" {
                XCTAssertEqual(segmentation.frames.count, 3)
                XCTAssertEqual(Set(segmentation.labelmapVoxelsByFrame.flatMap { $0 }), [1, 2, 3])
            } else {
                XCTAssertEqual(segmentation.frames.count, 2)
                XCTAssertEqual(segmentation.maximumFractionalValue, 200)
                XCTAssertEqual(segmentation.fractionalType, .probability)
                XCTAssertEqual(segmentation.frames[1].geometry?.positionAlongNormal ?? 0, 5, accuracy: 1e-8)
                XCTAssertTrue(segmentation.diagnostics.contains { $0.code == .segmentWithoutFrames })
            }
        }
    }

    func test_geometryCorpus_exportsEngineFactsForIndependentOracle() throws {
        var fixtures = try Self.newFixtures()
        for name in ["seg_binary.dcm", "rtstruct_contour.dcm"] {
            fixtures.append((name, try Data(contentsOf: Self.fixtureRoot.appendingPathComponent(name))))
        }
        fixtures.append(("seg_binary_odd.dcm", try Self.bytes(DicomSegmentationBuilder.dataSet(
            from: Self.segmentation(.binary, odd: true), studyInstanceUID: "2.25.2346001", seriesInstanceUID: "2.25.2346029",
            options: .init(patientName: "PARITY^ODD", patientID: "PARITY", contentDate: "20260101", contentTime: "000000")))))
        let output = ProcessInfo.processInfo.environment["DICOM_GEOMETRY_CORPUS_DIRECTORY"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for fixture in fixtures {
            let decoder = try DCMDecoder(data: fixture.data)
            var facts: [String: Any] = ["gaps": [String]()]
            if ["1.2.840.10008.5.1.4.1.1.66.4", "1.2.840.10008.5.1.4.1.1.66.7"].contains(
                decoder.info(for: .sopClassUID)), let segmentation = decoder.segmentation {
                facts["kind"] = "SEG"
                facts["segmentation_type"] = segmentation.segmentationType.rawValue
                facts["frames"] = segmentation.frames.map { frame -> [String: Any] in
                    let values = frame.pixelData.labelmapValues?.map(Int.init) ?? frame.pixelData.storedValues.map(Int.init)
                    var histogram: [String: Int] = [:]
                    for value in values { histogram[String(value), default: 0] += 1 }
                    let segmentCounts = segmentation.segmentationType == .labelmap ? histogram
                        : [String(frame.segmentNumber): values.filter { $0 != 0 }.count]
                    return ["segment": frame.segmentNumber, "values": values, "histogram": histogram,
                            "segment_voxel_counts": segmentCounts,
                            "nonzero_count": values.filter { $0 != 0 }.count, "fractional_sum": values.reduce(0, +)]
                }
                if fixture.name == "seg_fractional_sparse.dcm" {
                    XCTAssertTrue(segmentation.diagnostics.contains { $0.code == .segmentWithoutFrames })
                    facts["gaps"] = ["Segment 2 intentionally has no frames; sparse slices are preserved."]
                }
            } else if let rt = decoder.rtStructureSet {
                facts["kind"] = "RTSTRUCT"
                facts["contours"] = rt.roiContours.flatMap { roi in
                    roi.contours.map { contour -> [String: Any] in
                        ["roi": roi.referencedROINumber, "type": contour.geometricType,
                         "points": contour.points.map { [$0.x, $0.y, $0.z] },
                         "references": contour.sourceImageReferences.compactMap(\.referencedSOPInstanceUID)]
                    }
                }
            } else if let surface = decoder.surfaceSegmentation {
                facts["kind"] = "SURFACE"
                facts["surfaces"] = surface.surfaces.map { surface -> [String: Any] in
                    let triangles = surface.primitives.flatMap { primitive -> [UInt32] in
                        if case .triangles(let values) = primitive { return values }; return []
                    }
                    return ["points": surface.points.map { [$0.x, $0.y, $0.z] },
                            "normals": surface.normals.map { [$0.x, $0.y, $0.z] }, "triangles": triangles,
                            "expected_area": 600.0, "expected_volume": 1000.0]
                }
            } else { XCTFail("No typed geometry for \(fixture.name)") }
            if let output {
                try fixture.data.write(to: output.appendingPathComponent(fixture.name))
                try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys, .prettyPrinted])
                    .write(to: output.appendingPathComponent(fixture.name + ".json"))
            }
        }
        XCTAssertEqual(fixtures.count, 7)
    }
}
