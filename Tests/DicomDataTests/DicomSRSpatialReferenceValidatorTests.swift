import Foundation
import XCTest
@testable import DicomData

final class DicomSRSpatialReferenceValidatorTests: XCTestCase {
    func test_frameCoordinates_useColumnRowCornersAndBothBounds() {
        for (point, expected) in [([0.0, 0], DicomValidationReport.Outcome.passed), ([9, 7], .passed), ([10, 7], .failed), ([9, 8], .failed)] {
            let result = validate(root([spatial(point)]))
            XCTAssertEqual(result.report[.pixelsAndGeometry], expected)
            XCTAssertEqual(result.spatialConditions[[0]]?.referencedImageIsTiled, .unsatisfied)
            if expected == .failed {
                XCTAssertTrue(result.report.diagnostics.contains { $0.code == .spatialCoordinateOutOfRange &&
                    $0.path == [.tag(0x0040A730), .item(0), .tag(0x00700022)] })
            }
        }
    }

    func test_tiledFrameAndVolumeOrigins_selectDifferentDimensions() {
        let tiled = target().setting(number(0x00480006, 90, .UL)).setting(number(0x00480007, 70, .UL))
        for (origin, expected) in [("FRAME", DicomValidationReport.Outcome.failed), ("VOLUME", .passed)] {
            let result = validate(root([spatial([50, 60]).setting(text(0x00480301, origin, .CS))]), target: tiled)
            XCTAssertEqual(result.report[.pixelsAndGeometry], expected)
            XCTAssertEqual(result.spatialConditions[[0]]?.referencedImageIsTiled, .satisfied)
        }
        let implicitFrame = validate(root([spatial([9, 7])]), target: tiled)
        XCTAssertEqual(implicitFrame.report[.pixelsAndGeometry], .passed) // Origin presence is a separate attribute requirement.
        XCTAssertEqual(implicitFrame.spatialConditions[[0]]?.referencedImageIsTiled, .satisfied)
        let missingMatrix = validate(root([spatial([1, 1]).setting(text(0x00480301, "VOLUME", .CS))]))
        XCTAssertEqual(missingMatrix.report[.pixelsAndGeometry], .incomplete)
    }

    func test_forwardBackwardAndMultipleImages_keepAllOriginalReferences() {
        let coordinate = spatial([9, 7]).setting(sequence([reference([1, 2])]))
        let forward = validate(root([coordinate, image().setting(text(0x0040A010, "CONTAINS", .CS))]))
        XCTAssertEqual(forward.report[.references], .passed)
        XCTAssertEqual(forward.report[.pixelsAndGeometry], .passed)
        let backwards = spatial([9, 7]).setting(sequence([reference([1, 1])]))
        let backward = validate(root([image().setting(text(0x0040A010, "CONTAINS", .CS)), backwards]))
        XCTAssertEqual(backward.report[.references], .passed)
        XCTAssertEqual(backward.report[.pixelsAndGeometry], .passed)
        let second = image(uid: "2.25.23219992")
        let multi = spatial([8, 6]).setting(sequence([image(), second]))
        let targets = [uid: target(), "2.25.23219992": target(uid: "2.25.23219992").setting(number(0x00280011, 5, .US))]
        let result = DicomSRSpatialReferenceValidator.validate(root([multi]), targets: targets)
        XCTAssertTrue(result.report.diagnostics.contains { $0.code == .spatialCoordinateOutOfRange })
    }

    func test_unavailableOrContradictoryIdentity_neverUsesSuppliedDimensions() {
        let source = root([spatial([1, 1])])
        XCTAssertEqual(DicomSRSpatialReferenceValidator.validate(source).report[.pixelsAndGeometry], .incomplete)
        for bad in [target(uid: "2.25.999"), target().setting(text(0x00080016, "1.2.840.10008.5.1.4.1.1.4", .UI))] {
            let result = validate(source, target: bad)
            XCTAssertEqual(result.report[.references], .failed)
            XCTAssertEqual(result.report[.pixelsAndGeometry], .incomplete)
            XCTAssertTrue(result.report.diagnostics.contains { $0.code == .referenceIdentityContradiction })
            XCTAssertEqual(result.spatialConditions[[0]]?.referencedImageIsTiled, .undetermined)
        }
        XCTAssertEqual(validate(source, target: target().removing(0x00080018)).report[.pixelsAndGeometry], .incomplete)
    }

    func test_partialOpaqueAndInvalidDimensions_doNotBecomeValidBounds() {
        let source = root([spatial([1, 1])])
        for bad in [target().removing(0x00280010), target().setting(.init(tag: 0x00280010, vr: .UN, value: .bytes(Data([0, 0])))),
                    target().setting(number(0x00480006, 100, .UL))] {
            XCTAssertEqual(validate(source, target: bad).report[.pixelsAndGeometry], .incomplete)
        }
        for bad in [target().setting(number(0x00280010, 0, .US)),
                    target().setting(.init(tag: 0x00280011, vr: .US, value: .unsignedIntegers([1, 2])))] {
            XCTAssertEqual(validate(source, target: bad).report[.pixelsAndGeometry], .failed)
        }
        let maximum = target().setting(number(0x00480006, UInt(UInt32.max), .UL)).setting(number(0x00480007, UInt(UInt32.max), .UL))
        let inside = Double(Float(UInt32.max).nextDown)
        XCTAssertEqual(validate(root([spatial([inside, inside]).setting(text(0x00480301, "VOLUME", .CS))]), target: maximum).report[.pixelsAndGeometry], .passed)
        let outside = Double(Float(UInt32.max))
        XCTAssertEqual(validate(root([spatial([outside, inside]).setting(text(0x00480301, "VOLUME", .CS))]), target: maximum).report[.pixelsAndGeometry], .failed)
    }

    func test_explicitFrameSelection_reusesExistingTargetSelectorValidation() {
        let multiClass = "1.2.840.10008.5.1.4.1.1.2.1"
        let pair = DicomDataSet(elements: [text(0x00081150, multiClass, .UI), text(0x00081155, uid, .UI), text(0x00081160, "3", .IS)])
        let selected = image().setting(.init(tag: 0x00081199, vr: .SQ, value: .sequence([.init(dataSet: pair)])))
        let source = root([spatial([1, 1]).setting(sequence([selected]))])
        let target = target().setting(text(0x00080016, multiClass, .UI)).setting(text(0x00280008, "2", .IS))
            .setting(number(0x00480006, 90, .UL)).setting(number(0x00480007, 70, .UL))
        let result = validate(source, target: target)
        XCTAssertEqual(result.report[.references], .failed)
        XCTAssertEqual(result.report[.pixelsAndGeometry], .incomplete)
        XCTAssertTrue(result.report.diagnostics.contains { $0.code == .referenceSelectionOutOfRange })
        XCTAssertEqual(result.spatialConditions[[0]]?.referencedImageIsTiled, .satisfied)
    }

    func test_opaqueOrUnresolvedSelectionGraph_neverApprovesPartialTargets() {
        let opaque = spatial([1, 1]).setting(.init(tag: 0x0040A730, vr: .UN, value: .bytes(Data([0, 0]))))
        let mixed = spatial([1, 1]).setting(sequence([image(), reference([1, 99])]))
        for source in [opaque, mixed] {
            let result = validate(root([source]))
            XCTAssertEqual(result.report[.pixelsAndGeometry], .incomplete)
            XCTAssertEqual(result.spatialConditions[[0]]?.referencedImageIsTiled, .undetermined)
        }
    }

    func test_targetRoleAndAllGraphBudgets_areConservative() {
        let privateClass = "1.2.826.0.1.3680043.10.999.1"
        for (sopClass, expected) in [(privateClass, DicomValidationReport.Outcome.incomplete), ("1.2.840.10008.5.1.4.1.1.88.33", .failed)] {
            let selected = image(sopClass: sopClass)
            let source = root([spatial([1, 1]).setting(sequence([selected]))])
            XCTAssertEqual(validate(source, target: target().setting(text(0x00080016, sopClass, .UI))).report[.references], expected)
        }
        let source = root(Array(repeating: spatial([1, 1]), count: 20))
        for limit in [1, 10, 100] {
            let result = DicomSRSpatialReferenceValidator.validate(source, targets: [uid: target()], limits: .init(maximumRuleEvaluations: limit))
            XCTAssertNotEqual(result.report[.pixelsAndGeometry], .passed)
            XCTAssertLessThanOrEqual(result.evaluations, limit)
            XCTAssertTrue(result.spatialConditions.isEmpty)
        }
    }

    private let uid = "2.25.23219991"
    private func validate(_ source: DicomDataSet, target: DicomDataSet? = nil) -> DicomSRSpatialReferenceValidator.Result {
        DicomSRSpatialReferenceValidator.validate(source, targets: [uid: target ?? self.target()])
    }
    private func target(uid: String = "2.25.23219991") -> DicomDataSet {
        .init(elements: [text(0x00080016, "1.2.840.10008.5.1.4.1.1.2", .UI), text(0x00080018, uid, .UI),
            number(0x00280010, 7, .US), number(0x00280011, 9, .US)])
    }
    private func root(_ children: [DicomDataSet]) -> DicomDataSet {
        .init(elements: [text(0x00080016, "1.2.840.10008.5.1.4.1.1.88.33", .UI), text(0x0040A040, "CONTAINER", .CS), sequence(children)])
    }
    private func spatial(_ point: [Double]) -> DicomDataSet {
        .init(elements: [text(0x0040A040, "SCOORD", .CS), text(0x0040A010, "CONTAINS", .CS), text(0x00700023, "POINT", .CS),
            .init(tag: 0x00700022, vr: .FL, value: .floats(point)), sequence([image()])])
    }
    private func image(uid: String = "2.25.23219991", sopClass: String = "1.2.840.10008.5.1.4.1.1.2") -> DicomDataSet {
        .init(elements: [text(0x0040A040, "IMAGE", .CS), text(0x0040A010, "SELECTED FROM", .CS),
            .init(tag: 0x00081199, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [text(0x00081150, sopClass, .UI), text(0x00081155, uid, .UI)]))]))])
    }
    private func reference(_ values: [UInt]) -> DicomDataSet { .init(elements: [text(0x0040A010, "SELECTED FROM", .CS), .init(tag: 0x0040DB73, vr: .UL, value: .unsignedIntegers(values))]) }
    private func sequence(_ children: [DicomDataSet]) -> DicomDataElement { .init(tag: 0x0040A730, vr: .SQ, value: .sequence(children.map { .init(dataSet: $0) })) }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings([value])) }
    private func number(_ tag: Int, _ value: UInt, _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .unsignedIntegers([value])) }
}
