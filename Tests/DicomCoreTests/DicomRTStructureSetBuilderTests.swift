import XCTest
@testable import DicomCore

final class DicomRTStructureSetBuilderTests: XCTestCase {
    func test_fullStructureSet_roundTripsAllObservationsAndReferences() throws {
        let code = DicomGeometryCorpusTests.category
        let reference = DicomSourceImageReference(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2.1",
            referencedSOPInstanceUID: "2.25.2346051", referencedFrameNumbers: [1, 3])
        let planes = DicomRTSourcePixelPlanes(position: .zero, orientation: .init(row: .init(0.8, 0, -0.6), column: .init(0, 1, 0)),
            spacing: .init(0.7, 0.9), rows: 32, columns: 32, spacingBetweenSlices: 2.5, numberOfFrames: 3,
            sliceThickness: 2.5)
        let model = DicomRTStructureSet(sopInstanceUID: "2.25.2346052", label: "PARITY", name: "PARITY",
            description: "PARITY RT", referencedSeriesInstanceUIDs: ["2.25.2346053"],
            rois: [.init(number: 1, name: "PARITY", referencedFrameOfReferenceUID: "2.25.2346054",
                generationAlgorithm: "MANUAL", observationLabel: "SECOND", interpretedType: "CTV",
                interpreter: "PARITY", generationDescription: "PARITY generation", derivationCode: code)],
            roiContours: [.init(referencedROINumber: 1, displayColor: [1, 2, 3], contours: [
                .init(number: 7, geometricType: "FUTURE_TYPE", points: [.zero], sourceImageReferences: [reference])
            ], sourcePixelPlanes: planes)], structureSetDate: "20260101", structureSetTime: "120000",
            referencedFramesOfReference: [.init(frameOfReferenceUID: "2.25.2346054", studies: [
                .init(referencedSOPClassUID: "1.2.840.10008.3.1.2.3.1", referencedSOPInstanceUID: "2.25.2346055",
                    series: [.init(seriesInstanceUID: "2.25.2346053", instances: [reference])])])],
            observations: [
                .init(number: 1, referencedROINumber: 1, label: "FIRST", interpretedType: "PTV", interpreter: "PARITY",
                    identificationCode: code, therapeuticRoleTypeCode: code,
                    physicalProperties: [.init(name: "MEAN_EXCI_ENERGY", value: 75)]),
                .init(number: 2, referencedROINumber: 1, label: "SECOND", interpretedType: "CTV", interpreter: "PARITY")])
        let data = DicomRTStructureSetBuilder.dataSet(from: model, studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
        let parsed = try XCTUnwrap(DCMDecoder(data: DicomGeometryCorpusTests.bytes(data)).rtStructureSet)
        XCTAssertEqual(parsed, model)
        XCTAssertEqual(parsed.observations.count, 2)
        XCTAssertEqual(parsed.observations.first?.physicalProperties.first?.units, "eV")
        XCTAssertEqual(parsed.roiContours.first?.contours.first?.sourcePixelPlanes, planes)
        XCTAssertTrue(DicomRTContourGeometryValidator.validate(parsed).diagnostics.contains { $0.code == .unknownGeometricType })
        let rebuilt = DicomRTStructureSetBuilder.dataSet(from: parsed, studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
        XCTAssertEqual(try DCMDecoder(data: DicomGeometryCorpusTests.bytes(rebuilt)).rtStructureSet, parsed)
        let roiItem = try XCTUnwrap(data.sequenceItems(for: 0x30060039).first?.dataSet)
        XCTAssertEqual(roiItem.sequenceItems(for: 0x3006004A).count, 1)
        XCTAssertFalse(roiItem.sequenceItems(for: 0x30060040)[0].dataSet.contains(0x3006004A))
    }
}
