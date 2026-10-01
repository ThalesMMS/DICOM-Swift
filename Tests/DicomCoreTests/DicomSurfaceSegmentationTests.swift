import XCTest
@testable import DicomCore

final class DicomSurfaceSegmentationTests: XCTestCase {
    func test_decodedQuota_countsRetainedVectorCoordinatesAndAccuracy() {
        let surface = DicomSurface(number: 1, points: [.zero], primitives: [.triangles([1, 1, 1])],
            pointCoordinatesAccuracy: [1, 1, 1], pointsBoundingBox: [0, 0, 0, 1, 1, 1],
            vectors: [.init(coordinates: [0, 0, 1], accuracy: [0.1])])
        // points 16 + normals 16 + indices 12 + point accuracy 12 + bounding box 48 + vectors 12 + accuracy 4.
        let retainedBytes = 120
        let limit = 512 * 1_024 * 1_024
        var atLimit = limit - retainedBytes
        XCTAssertTrue(DicomSurfaceSegmentationParser.addDecodedBytes(for: surface, to: &atLimit))
        XCTAssertEqual(atLimit, limit)
        var overLimit = limit - retainedBytes + 1
        XCTAssertFalse(DicomSurfaceSegmentationParser.addDecodedBytes(for: surface, to: &overLimit))
        XCTAssertEqual(overLimit, limit - retainedBytes + 1)
    }

    func testSurfaceSegmentationDecodesOLPointsPrimitivesAndReferences() throws {
        let decoder = try open(dataSet(indices: [1, 2, 3]))
        let document = try XCTUnwrap(decoder.surfaceSegmentation)

        XCTAssertEqual(document.sopInstanceUID, "2.25.1981")
        XCTAssertEqual(document.frameOfReferenceUID, "2.25.1982")
        XCTAssertEqual(document.referencedSeriesInstanceUIDs, ["2.25.1983"])
        XCTAssertEqual(document.segments.first?.label, "Liver surface")
        XCTAssertEqual(document.segments.first?.referencedSurfaceNumbers, [1])
        XCTAssertEqual(document.segments.first?.sourceImageReferences.first?.referencedSOPInstanceUID, "2.25.1984")
        XCTAssertEqual(document.surfaces.first?.points.count, 3)
        XCTAssertEqual(document.surfaces.first?.normals.count, 3)
        XCTAssertEqual(document.surfaces.first?.primitives, [.triangles([1, 2, 3])])
        XCTAssertEqual(document.surfaces.first?.recommendedDisplayCIELabValue, [40000, 33000, 32000])
        XCTAssertEqual(document.surfaces.first?.recommendedPresentationOpacity, 0.75)
    }

    func testSurfaceSegmentationDecodesImplicitVRLongIndices() throws {
        let decoder = try open(dataSet(indices: [1, 2, 3]), transferSyntax: .implicitVRLittleEndian)

        XCTAssertEqual(decoder.surfaceSegmentation?.surfaces.first?.primitives, [.triangles([1, 2, 3])])
    }

    func testSurfaceSegmentationRejectsOutOfBoundsIndices() throws {
        let decoder = try open(dataSet(indices: [1, 2, 4]))

        XCTAssertNil(decoder.surfaceSegmentation)
    }

    func testSurfaceSegmentationRejectsDeclaredCountMismatch() throws {
        var invalid = dataSet(indices: [1, 2, 3])
        invalid.set(unsigned(.numberOfSurfaces, vr: .UL, [2]))
        let decoder = try open(invalid)

        XCTAssertNil(decoder.surfaceSegmentation)
    }

    func testSurfaceSegmentationRejectsNonFinitePointCoordinate() throws {
        let decoder = try open(dataSet(
            indices: [1, 2, 3],
            pointCoordinates: [0, 0, 0, 10, .nan, 0, 0, 10, 0]
        ))

        XCTAssertNil(decoder.surfaceSegmentation)
    }

    func testSurfaceSegmentationRejectsMalformedSegmentItem() throws {
        var invalid = dataSet(indices: [1, 2, 3])
        invalid.set(sequence(.segmentSequence, [
            DicomDataSet(elements: [unsigned(.segmentNumber, vr: .US, [1])])
        ]))

        XCTAssertNil(try open(invalid).surfaceSegmentation)
    }

    private func dataSet(
        indices: [UInt],
        pointCoordinates: [Double] = [0, 0, 0, 10, 0, 0, 0, 10, 0]
    ) -> DicomDataSet {
        let points = DicomDataSet(elements: [
            unsigned(.numberOfSurfacePoints, vr: .UL, [3]),
            floats(.pointCoordinatesData, vr: .OF, pointCoordinates)
        ])
        let normals = DicomDataSet(elements: [
            unsigned(.numberOfVectors, vr: .UL, [3]),
            unsigned(.vectorDimensionality, vr: .US, [3]),
            floats(.vectorCoordinateData, vr: .OF, [0, 0, 1, 0, 0, 1, 0, 0, 1])
        ])
        let primitives = DicomDataSet(elements: [
            unsigned(.longTrianglePointIndexList, vr: .OL, indices)
        ])
        let surface = DicomDataSet(elements: [
            unsigned(.surfaceNumber, vr: .UL, [1]),
            strings(.surfaceComments, vr: .LT, ["Liver mesh"]),
            unsigned(.recommendedDisplayCIELabValue, vr: .US, [40000, 33000, 32000]),
            floats(.recommendedPresentationOpacity, vr: .FL, [0.75]),
            sequence(.surfacePointsSequence, [points]),
            sequence(.surfacePointsNormalsSequence, [normals]),
            sequence(.surfaceMeshPrimitivesSequence, [primitives])
        ])
        let segment = DicomDataSet(elements: [
            unsigned(.segmentNumber, vr: .US, [1]),
            strings(.segmentLabel, vr: .LO, ["Liver surface"]),
            unsigned(.surfaceCount, vr: .UL, [1]),
            sequence(.referencedSurfaceSequence, [
                DicomDataSet(elements: [unsigned(.referencedSurfaceNumber, vr: .UL, [1])])
            ]),
            sequence(.segmentSurfaceSourceInstanceSequence, [
                DicomDataSet(elements: [
                    strings(.referencedSOPClassUID, vr: .UI, ["1.2.840.10008.5.1.4.1.1.2.1"]),
                    strings(.referencedSOPInstanceUID, vr: .UI, ["2.25.1984"])
                ])
            ])
        ])
        return DicomDataSet(elements: [
            strings(.sopClassUID, vr: .UI, [DicomSurfaceSegmentation.storageSOPClassUID]),
            strings(.sopInstanceUID, vr: .UI, ["2.25.1981"]),
            strings(.studyInstanceUID, vr: .UI, ["2.25.1985"]),
            strings(.seriesInstanceUID, vr: .UI, ["2.25.1986"]),
            strings(.frameOfReferenceUID, vr: .UI, ["2.25.1982"]),
            strings(.modality, vr: .CS, ["SEG"]),
            unsigned(.numberOfSurfaces, vr: .UL, [1]),
            sequence(.surfaceSequence, [surface]),
            sequence(.segmentSequence, [segment]),
            sequence(.referencedSeriesSequence, [
                DicomDataSet(elements: [strings(.seriesInstanceUID, vr: .UI, ["2.25.1983"])])
            ])
        ])
    }

    private func open(
        _ dataSet: DicomDataSet,
        transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian
    ) throws -> DCMDecoder {
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: transferSyntax,
                mediaStorageSOPClassUID: DicomSurfaceSegmentation.storageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.1981"
            )
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("surface-segmentation-\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }

    private func sequence(_ tag: DicomTag, _ dataSets: [DicomDataSet]) -> DicomDataElement {
        DicomDataElement(
            tag: tag.rawValue,
            vr: .SQ,
            value: .sequence(dataSets.map { DicomSequenceItem(dataSet: $0) })
        )
    }

    private func unsigned(_ tag: DicomTag, vr: DicomVR, _ values: [UInt]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .unsignedIntegers(values))
    }

    private func floats(_ tag: DicomTag, vr: DicomVR, _ values: [Double]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .floats(values))
    }

    private func strings(_ tag: DicomTag, vr: DicomVR, _ values: [String]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings(values))
    }
}
