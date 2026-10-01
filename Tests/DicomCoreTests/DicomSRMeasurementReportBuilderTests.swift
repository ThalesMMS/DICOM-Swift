import Foundation
import XCTest
@testable import DicomCore

final class DicomSRMeasurementReportBuilderTests: XCTestCase {
    static let image = DicomSourceImageReference(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
        referencedSOPInstanceUID: "2.25.2345001", referencedFrameNumbers: [2])
    static let mm = DicomCodedConcept(codeValue: "mm", codingSchemeDesignator: "UCUM", codeMeaning: "millimeter")

    static func code(_ value: String, _ meaning: String = "PARITY", scheme: String = "DCM") -> DicomCodedConcept {
        .init(codeValue: value, codingSchemeDesignator: scheme, codeMeaning: meaning)
    }

    static func fullReport() -> DicomSRMeasurementReport {
        let length = code("410668003", "Length", scheme: "SCT")
        let measure = DicomSRMeasurementValue(concept: length, value: 12, units: mm)
        let polyline = DicomSRImageRegion(graphicType: "POLYLINE", data: [1, 1, 8, 8], image: image)
        let ellipse = DicomSRImageRegion(graphicType: "ELLIPSE", data: [1, 4, 7, 4, 4, 2, 4, 6], image: image)
        let surface = DicomSRVolumeSurface(graphicType: "ELLIPSOID",
            data: [-1, 0, 0, 1, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, -1, 0, 0, 1], frameOfReferenceUID: "2.25.2345099")
        return .init(sopInstanceUID: "2.25.2345003",
            language: .init(code: code("en", "English", scheme: "RFC5646")),
            observers: [.init(kind: .device, name: "PARITY", deviceUID: "2.25.2345010",
                manufacturer: "PARITY", model: "PARITY", serial: "PARITY")],
            procedureStudyInstanceUID: "2.25.2345004",
            proceduresReported: [code("P5-08000", "Computed Tomography", scheme: "SRT")],
            imageLibrary: [.init(reference: image, modality: code("CT", "Computed Tomography"),
                studyDate: DicomDate("20260101"), studyTime: DicomTime("120000"),
                seriesUID: "2.25.2345002", seriesNumber: "1", seriesDescription: "PARITY",
                frameOfReferenceUID: "2.25.2345099", rows: 512, columns: 512, numberOfFrames: 3,
                instanceNumber: "1", contentDate: DicomDate("20260101"), contentTime: DicomTime("120000"),
                acquisitionDate: DicomDate("20260101"), acquisitionTime: DicomTime("120000"),
                horizontalPixelSpacing: 0.7, verticalPixelSpacing: 0.7, sliceThickness: 1, spacingBetweenSlices: 1,
                ctAcquisitionType: code("113804", "Sequenced Acquisition"),
                ctReconstructionAlgorithm: code("113962", "Filtered Back Projection"),
                imagePosition: [0, 0, 0], imageOrientation: [1, 0, 0, 0, 1, 0])],
            measurementGroups: [
                .init(trackingIdentifier: "PARITY-GENERIC", trackingUID: "2.25.2345020", measurements: [
                    .init(concept: length, value: 12, units: mm, derivation: code("R-00317", "Mean", scheme: "SRT"),
                          inferredFrom: [.scoord(polyline)]),
                    .init(concept: length, value: 14, units: mm, derivation: code("R-404FB", "Maximum", scheme: "SRT"),
                          inferredFrom: [.scoord(polyline)])
                ], qualitativeEvaluations: [.code(concept: code("121071", "Finding"), value: code("PARITY"))]),
                .init(kind: .planarROI, trackingIdentifier: "PARITY-PLANAR", trackingUID: "2.25.2345021",
                    region: .imageRegion(ellipse), measurements: [measure]),
                .init(kind: .volumetricROI, trackingIdentifier: "PARITY-VOLUME", trackingUID: "2.25.2345022",
                    region: .volumeSurface([surface]), sourceSeriesUID: "2.25.2345002", measurements: [measure])
            ], qualitativeEvaluations: [.text(concept: code("121071", "Finding"), text: "PARITY")],
            derivedMeasurements: [.init(measurement: measure, groups: [.trackingUID("2.25.2345021")])])
    }

    static func fixtureData() throws -> Data {
        let document = try DicomSRMeasurementReportBuilder.build(fullReport())
        let dataSet = try DicomStructuredReportBuilder.validatedDataSet(from: document,
            studyInstanceUID: "2.25.2345004", seriesInstanceUID: "2.25.2345005")
        return try DicomDataSetWriter.part10Data(from: dataSet, options: .init(
            transferSyntax: .explicitVRLittleEndian,
            mediaStorageSOPClassUID: DicomSRDocument.comprehensive3DSRStorageSOPClassUID,
            mediaStorageSOPInstanceUID: "2.25.2345003"))
    }

    func test_sameInput_producesIdenticalBytesAndPreservesTrackingUIDs() throws {
        XCTAssertEqual(try Self.fixtureData(), try Self.fixtureData())
        let document = try DicomSRMeasurementReportBuilder.build(Self.fullReport())
        XCTAssertEqual(document.root.flattened.filter { $0.conceptName?.codeValue == "112040" }.compactMap(\.uidValue),
                       ["2.25.2345020", "2.25.2345021", "2.25.2345022"])
        let reference = try XCTUnwrap(document.root.flattened.first(where: \.isByReference))
        let target = try XCTUnwrap(DicomSRSemanticValidator.referencedItem(in: document.root,
            identifier: try XCTUnwrap(reference.referencedContentItemIdentifier)))
        XCTAssertEqual(target.valueType, "CONTAINER")
        XCTAssertEqual(target.contentTemplate?.templateIdentifier, "1410")
    }

    func test_segmentSources_preferImagesAndRejectMissingSource() throws {
        var report = Self.fullReport()
        let segment = DicomSourceImageReference(referencedSOPClassUID: DicomSegmentationBuilder.segmentationStorageSOPClassUID,
            referencedSOPInstanceUID: "2.25.2345070", referencedSegmentNumbers: [1])
        report.measurementGroups[2].region = .referencedSegment(segment, sourceImages: [Self.image],
            sourceSeriesUID: "2.25.2345002")
        let document = try DicomSRMeasurementReportBuilder.build(report)
        let group = try XCTUnwrap(document.root.flattened.first { $0.contentTemplate?.templateIdentifier == "1411" })
        XCTAssertEqual(group.children.filter { $0.conceptName?.codeValue == "121233" }.count, 1)
        XCTAssertFalse(group.children.contains { $0.conceptName?.codeValue == "121232" })
        report.measurementGroups[2].region = .referencedSegment(segment, sourceImages: [], sourceSeriesUID: nil)
        report.measurementGroups[2].sourceSeriesUID = nil
        XCTAssertThrowsError(try DicomSRMeasurementReportBuilder.build(report))
    }

    func test_conflictingNumericRepresentations_areRejected() throws {
        var report = Self.fullReport()
        report.measurementGroups[0].measurements[0].floatingPointValue = 13
        XCTAssertThrowsError(try DicomSRMeasurementReportBuilder.build(report)) {
            XCTAssertEqual($0 as? DicomSRMeasurementReportBuilderError, .conflictingNumericRepresentations)
        }
        report.measurementGroups[0].measurements[0].floatingPointValue = 12
        XCTAssertNoThrow(try DicomSRMeasurementReportBuilder.build(report))
        report.derivedMeasurements[0].measurement.floatingPointValue = 13
        XCTAssertThrowsError(try DicomSRMeasurementReportBuilder.build(report)) {
            XCTAssertEqual($0 as? DicomSRMeasurementReportBuilderError, .conflictingNumericRepresentations)
        }
    }

    func test_partialUpdate_preservesOtherItemsAndSOPUID() throws {
        var report = Self.fullReport()
        let before = try DicomSRMeasurementReportBuilder.build(report)
        report.measurementGroups[0].measurements[0].value = 15
        let after = try DicomSRMeasurementReportBuilder.build(report)
        XCTAssertEqual(before.sopInstanceUID, after.sopInstanceUID)
        let a = before.root.flattened
        let b = after.root.flattened
        XCTAssertEqual(a.count, b.count)
        let changed = a.indices.filter { a[$0] != b[$0] }
        XCTAssertEqual(changed.count, 4) // NUM and its three ancestors only.
        XCTAssertEqual(a.filter { $0.valueType != "CONTAINER" && $0.numericValue != 12 },
                       b.filter { $0.valueType != "CONTAINER" && $0.numericValue != 12 && $0.numericValue != 15 })
    }

    func test_scoord3D_requiresComprehensive3DAndDerivedRequiresComprehensive() throws {
        var report = Self.fullReport()
        XCTAssertEqual(try DicomSRMeasurementReportBuilder.build(report).sopClassUID,
                       DicomSRDocument.comprehensive3DSRStorageSOPClassUID)
        report.sopClassUID = DicomSRDocument.enhancedSRStorageSOPClassUID
        XCTAssertThrowsError(try DicomSRMeasurementReportBuilder.build(report)) {
            XCTAssertEqual($0 as? DicomSRMeasurementReportBuilderError, .scoord3DRequiresComprehensive3D)
        }
        report.measurementGroups.removeLast()
        XCTAssertThrowsError(try DicomSRMeasurementReportBuilder.build(report)) {
            XCTAssertEqual($0 as? DicomSRMeasurementReportBuilderError, .byReferenceRequiresComprehensive)
        }
        report.sopClassUID = DicomSRDocument.comprehensiveSRStorageSOPClassUID
        XCTAssertEqual(try DicomSRMeasurementReportBuilder.build(report).sopClassUID, report.sopClassUID)
        report.measurementGroups[0].trackingUID = nil
        XCTAssertThrowsError(try DicomSRMeasurementReportBuilder.build(report)) {
            XCTAssertEqual($0 as? DicomSRMeasurementReportBuilderError, .missingTrackingUID)
        }
    }

    func test_groupIndex_resolvesContainerAndRejectsGenericGroup() throws {
        var report = Self.fullReport()
        report.derivedMeasurements[0].groups = [.index(2)]
        let built = try DicomSRMeasurementReportBuilder.build(report)
        let ref = try XCTUnwrap(built.root.flattened.first(where: \.isByReference))
        let target = DicomSRSemanticValidator.referencedItem(in: built.root,
            identifier: try XCTUnwrap(ref.referencedContentItemIdentifier))
        XCTAssertEqual(target?.contentTemplate?.templateIdentifier, "1411")
        report.derivedMeasurements[0].groups = [.index(0)]
        XCTAssertThrowsError(try DicomSRMeasurementReportBuilder.build(report)) {
            XCTAssertEqual($0 as? DicomSRMeasurementReportBuilderError, .invalidGroupReference)
        }
    }
    func test_multipleObserversAndImages_keepSeparateTemplateInvocations() throws {
        var report = Self.fullReport()
        report.observers.append(.init(kind: .person, name: "PARITY^OBSERVER", organisation: "PARITY"))
        report.imageLibrary.append(report.imageLibrary[0])
        let document = try DicomSRMeasurementReportBuilder.build(report)
        XCTAssertTrue(DicomSRTemplateValidator.validate(document).errors.isEmpty)
    }

}
