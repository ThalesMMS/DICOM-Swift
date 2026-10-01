import XCTest
@testable import DicomCore

final class DicomRTContourGeometryValidatorTests: XCTestCase {
    private func model(_ points: [SIMD3<Double>], type: String = "CLOSED_PLANAR") -> DicomRTStructureSet {
        .init(rois: [.init(number: 1, name: "PARITY")], roiContours: [
            .init(referencedROINumber: 1, contours: [.init(geometricType: type, points: points)])])
    }

    func test_obliqueXORAndDisjointLoops_areConsistent() {
        XCTAssertTrue(DicomRTContourGeometryValidator.validate(DicomGeometryCorpusTests.rtStructureSet()).isConsistent)
    }

    func test_invalidContours_reportMeasuredAndTypedDiagnostics() {
        let cases: [(DicomRTStructureSet, DicomRTContourGeometryDiagnostic.Code)] = [
            (model([.init(0, 0, 0), .init(1, 0, 0), .init(1, 1, 0), .init(0, 1, 0.5)]), .nonPlanarContour),
            (model([.init(0, 0, 0), .init(1, 1, 0), .init(0, 1, 0), .init(1, 0, 0)]), .selfIntersection),
            (model([.zero, .init(1, 0, 0)], type: "POINT"), .invalidPointCount),
            (model([.zero, .init(1, 0, 0), .init(1, 1, 0)], type: "CLOSEDPLANAR_XOR"), .xorWithoutCoplanarCompanion),
            (model([.zero, .init(1, 0, 0), .init(2, 0, 0)]), .degenerateClosedContour),
            (model([.zero, .zero, .init(1, 1, 0)]), .consecutiveDuplicatePoints)
        ]
        for (model, code) in cases {
            let report = DicomRTContourGeometryValidator.validate(model)
            XCTAssertFalse(report.isConsistent)
            XCTAssertTrue(report.diagnostics.contains { $0.code == code }, "\(code)")
        }
        XCTAssertEqual(DicomRTContourGeometryValidator.validate(cases[0].0).diagnostics
            .first { $0.code == .nonPlanarContour }?.measuredValue, 0.5)
    }

    func test_intersectionLimit_recordsLimitation() {
        let report = DicomRTContourGeometryValidator.validate(
            model([.zero, .init(1, 0, 0), .init(1, 1, 0)]), maximumPointsForIntersectionTest: 2)
        XCTAssertEqual(report.limitations.first?.code, .intersectionTestPointLimit)
        XCTAssertFalse(report.isConsistent)
    }

    func test_imagePlaneAndFrameOfReferenceMismatches_areReported() {
        let original = DicomGeometryCorpusTests.rtStructureSet()
        let wrong = DicomRTStructureSet(rois: [.init(number: 1, name: "PARITY", referencedFrameOfReferenceUID: "2.25.9")],
            roiContours: [original.roiContours[0]], referencedFramesOfReference: original.referencedFramesOfReference)
        let plane = DicomRTImagePlane(position: DicomGeometryCorpusTests.position(0, 0, 2),
            orientation: DicomGeometryCorpusTests.orientation, spacing: .init(0.7, 0.9), rows: 2, columns: 2)
        let report = DicomRTContourGeometryValidator.validate(wrong, imagePlanes: ["2.25.2346010": plane])
        for code: DicomRTContourGeometryDiagnostic.Code in [.referencedImageOutsideFrameOfReference, .imageOffPlane,
                                                            .imageOutsideExtent] {
            XCTAssertTrue(report.diagnostics.contains { $0.code == code })
        }
    }

    func test_mixedXORAcrossPlanes_reportsMixedROI() {
        let original = DicomGeometryCorpusTests.rtStructureSet()
        let mixed = DicomRTStructureSet(rois: original.rois, roiContours: [.init(referencedROINumber: 1,
            contours: original.roiContours[0].contours + [original.roiContours[1].contours[2]])])
        XCTAssertTrue(DicomRTContourGeometryValidator.validate(mixed).diagnostics.contains { $0.code == .mixedXORROI })
    }
}
