import XCTest
@testable import DicomCore

final class DicomWholeSlidePyramidTests: XCTestCase {
    func test_shuffledUIDGrouping_ordersLevelsRejectsMismatchAndRetainsAuxiliary() throws {
        let fine = instance("fine", spacing: 0.001, size: 1000)
        let coarse = instance("coarse", spacing: 0.002, size: 500)
        let mismatch = instance("wrong-path", spacing: 0.003, size: 333, paths: ["B"])
        let wrongScale = instance("wrong-scale", spacing: 0.004, size: 400)
        let wrongPlanes = instance("wrong-planes", spacing: 0.005, size: 200, planes: [0, 1])
        let label = instance("label", spacing: 1, size: 1, flavor: "LABEL", uid: nil)
        let overview = instance("overview", spacing: 2, size: 1, flavor: "OVERVIEW", uid: nil)
        let thumbnail = instance("thumbnail", spacing: 3, size: 1, flavor: "THUMBNAIL")
        let input = [wrongScale, overview, mismatch, coarse, thumbnail, wrongPlanes, label, fine]
        let pyramids = DicomWholeSlidePyramid.group(input)
        XCTAssertEqual(pyramids, DicomWholeSlidePyramid.group(input.reversed()))
        let pyramid = try XCTUnwrap(pyramids.first)
        XCTAssertEqual(pyramids.count, 1)
        XCTAssertEqual(pyramid.levels.map(\.sopInstanceUID), ["fine", "coarse", "wrong-scale"])
        XCTAssertEqual(pyramid.levels.map(\.scaleFactorFromBase), [1, 2, 4])
        XCTAssertEqual(pyramid.auxiliaryImages.map(\.sopInstanceUID), ["label", "overview", "thumbnail"])
        XCTAssertEqual(pyramid.diagnostics.filter { $0.code == .pyramidLevelMismatch }.count, 2)
        XCTAssertEqual(pyramid.diagnostics.filter { $0.code == .pyramidScaleMismatch }.count, 1)
        XCTAssertEqual(pyramid.levels[0].sopClassUID, DCMDecoder.wholeSlideMicroscopyImageStorageSOPClassUID)
        XCTAssertEqual(pyramid.levels[0].seriesUID, "series")
        XCTAssertEqual(pyramid.levels[0].concatenation?.uid, "concat-fine")
    }

    func test_fallbackGrouping_requiresMatchingPhysicalIdentity() {
        let fine = instance("fine", spacing: 0.001, size: 1000, uid: nil)
        let coarse = instance("coarse", spacing: 0.002, size: 500, uid: nil, originX: 1 + 0.0000001)
        let shifted = instance("shifted", spacing: 0.004, size: 250, uid: nil, originX: 2)
        let otherPath = instance("other", spacing: 0.005, size: 200, uid: nil, paths: ["B"])
        let groups = DicomWholeSlidePyramid.group([shifted, coarse, otherPath, fine])
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].levels.map(\.sopInstanceUID), ["fine", "coarse"])
        XCTAssertEqual(groups, DicomWholeSlidePyramid.group([fine, otherPath, coarse, shifted]))
    }

    func test_missingFlavor_isRetainedAsMatchedOrUnmatchedAuxiliary() {
        let missing = instance("missing", spacing: 1, size: 1, flavor: "")
        XCTAssertNil(missing.imageType.flavor)
        let matched = DicomWholeSlidePyramid.group([instance("base", spacing: 0.001, size: 1000), missing])
        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched[0].auxiliaryImages, [missing])
        let unmatched = DicomWholeSlidePyramid.group([missing])
        XCTAssertEqual(unmatched.count, 1)
        XCTAssertTrue(unmatched[0].levels.isEmpty)
        XCTAssertEqual(unmatched[0].auxiliaryImages, [missing])
    }

    private func instance(
        _ id: String, spacing: Double, size: Int, flavor: String = "VOLUME", uid: String? = "pyramid",
        paths: [String] = ["A"], planes: [Double] = [0], originX: Double = 1
    ) -> DicomWholeSlideMicroscopyMetadata {
        .init(sopInstanceUID: id, matrixWidth: size, matrixHeight: size, tileWidth: 256, tileHeight: 256,
              frameCount: 1, pixelSpacingXMillimeters: spacing, pixelSpacingYMillimeters: spacing,
              opticalPaths: paths.map { .init(identifier: $0) }, focalPlaneOffsetsMillimeters: planes, tiles: [],
              containerIdentifier: "container", imageType: .init(rawValues: ["ORIGINAL", "PRIMARY", flavor, "NONE"]),
              pyramidUID: uid, sopClassUID: DCMDecoder.wholeSlideMicroscopyImageStorageSOPClassUID,
              seriesUID: "series", frameOfReferenceUID: "frame",
              totalPixelMatrixOrigin: .init(xMillimeters: originX, yMillimeters: 2),
              imagedVolume: .init(widthMillimeters: 1, heightMillimeters: 1, depthMicrometers: 1),
              concatenation: .init(uid: "concat-" + id, number: 1, totalNumber: 1, frameOffsetNumber: 0))
    }
}
