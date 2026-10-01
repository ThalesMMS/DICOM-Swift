import XCTest
@testable import DicomCore

final class DicomSurfaceSegmentationBuilderTests: XCTestCase {
    func test_fullSurface_roundTripsProcessingVectorsAndSegmentSemantics() throws {
        let cube = DicomGeometryCorpusTests.cube()
        let source = DicomSourceImageReference(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2.1",
            referencedSOPInstanceUID: "2.25.2346071", referencedFrameNumbers: [1, 3])
        let code = DicomGeometryCorpusTests.category, algorithm = DicomGeometryCorpusTests.algorithm
        let base = cube.surfaces[0]
        let surface = DicomSurface(number: 1, comments: "PARITY", recommendedDisplayCIELabValue: [1, 2, 3],
            recommendedPresentationOpacity: 0.5, recommendedPresentationType: "SURFACE", points: base.points,
            primitives: [.triangles([1, 2, 3]), .edges([1, 2]), .triangleStrip([1, 2, 3, 4]),
                         .triangleFan([1, 2, 3]), .facet([1, 2, 3, 4]), .line([1, 2])],
            finiteVolume: .no, manifold: .unknown, surfaceProcessing: true, surfaceProcessingRatio: 0.5,
            surfaceProcessingDescription: "PARITY processing", surfaceProcessingAlgorithm: algorithm,
            pointCoordinatesAccuracy: [0.1, 0.2, 0.3], meanPointDistance: 1, maximumPointDistance: 10,
            pointsBoundingBox: [0, 0, 0, 10, 10, 10], axisOfRotation: .init(0, 0, 1), centerOfRotation: .zero,
            vectors: [.init(coordinates: base.normals.flatMap { [$0.x, $0.y, $0.z] }, accuracy: [0.01])])
        let model = DicomSurfaceSegmentation(sopInstanceUID: "2.25.2346072", frameOfReferenceUID: "2.25.2346073",
            referencedSeriesInstanceUIDs: ["2.25.2346074"], segments: [
                .init(number: 1, label: "PARITY", recommendedDisplayCIELabValue: [4, 5, 6], referencedSurfaceNumbers: [1],
                    sourceImageReferences: [source], description: "PARITY segment", propertyCategory: code,
                    propertyType: code, propertyTypeModifiers: [code], anatomicRegion: code,
                    anatomicRegionModifiers: [code], algorithmIdentification: algorithm, algorithmType: "AUTOMATIC",
                    trackingID: "PARITY_TRACKING", trackingUID: "2.25.2346075")
            ], surfaces: [surface], contentLabel: "PARITY", contentDescription: "PARITY content",
            contentCreatorName: "PARITY", referencedInstancesBySeries: ["2.25.2346074": [source]])
        XCTAssertTrue(DicomSurfaceSegmentationValidator.validate(model).isConsistent)
        let data = DicomSurfaceSegmentationBuilder.dataSet(from: model, studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
        let parsed = try XCTUnwrap(DCMDecoder(data: DicomGeometryCorpusTests.bytes(data)).surfaceSegmentation)
        XCTAssertEqual(parsed, model)
        let rebuilt = DicomSurfaceSegmentationBuilder.dataSet(from: parsed, studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
        XCTAssertEqual(try DCMDecoder(data: DicomGeometryCorpusTests.bytes(rebuilt)).surfaceSegmentation, parsed)
        XCTAssertEqual(parsed.segments[0].sourceImageReferences[0].referencedFrameNumbers, [1, 3])
    }

    func test_invalidTypedGeometry_reportsCountsIndicesAndVectors() {
        let surface = DicomSurface(number: 2, points: [.zero], primitives: [.triangles([0, 1, 2])],
            numberOfSurfacePoints: 2, vectors: [.init(dimensionality: 2, coordinates: [1, 2]),
                                              .init(coordinates: [1, 2, 3])])
        let model = DicomSurfaceSegmentation(segments: [.init(number: 1, label: "PARITY", referencedSurfaceNumbers: [3])],
            surfaces: [surface])
        let report = DicomSurfaceSegmentationValidator.validate(model)
        XCTAssertFalse(report.isConsistent)
        for code: DicomSurfaceSegmentationDiagnostic.Code in [.surfaceNumber, .pointCount, .indexOutOfBounds,
            .vectorDimensionality, .normalsCount, .multipleVectorSets, .segmentSurfaceReference] {
            XCTAssertTrue(report.diagnostics.contains { $0.code == code }, "\(code)")
        }
    }
}
