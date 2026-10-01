//
//  ClinicalInteropFixtureExportTests.swift
//  DicomCoreTests
//

import Foundation
import XCTest
@testable import DicomCore

final class ClinicalInteropFixtureExportTests: XCTestCase {
    private static let fixtureDirectory = "Tests/DicomCoreTests/Fixtures/ClinicalInterop"

    func test_committedClinicalObjectFixturesMatchDeterministicBuildersAndParse() throws {
        for fixture in try Self.generatedFixtures() {
            let url = Self.packageRoot.appendingPathComponent(Self.fixtureDirectory)
                .appendingPathComponent(fixture.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                XCTFail(
                    "Missing \(fixture.fileName); regenerate with "
                        + "DICOM_REGENERATE_CLINICAL_INTEROP_FIXTURES=1"
                )
                continue
            }
            XCTAssertEqual(try Data(contentsOf: url), fixture.data, fixture.fileName)
            try fixture.validate(DCMDecoder(data: fixture.data))
        }
    }

    func test_regenerateClinicalInteropFixturesWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["DICOM_REGENERATE_CLINICAL_INTEROP_FIXTURES"] == "1" else {
            throw XCTSkip("Set DICOM_REGENERATE_CLINICAL_INTEROP_FIXTURES=1 to rewrite the fixtures.")
        }
        let directory = Self.packageRoot.appendingPathComponent(Self.fixtureDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for fixture in try Self.generatedFixtures() {
            try fixture.data.write(to: directory.appendingPathComponent(fixture.fileName), options: .atomic)
        }
    }

    func test_exportClinicalInteropFixturesWhenRequested() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["DICOM_INTEROP_OUTPUT_DIR"],
              !outputPath.isEmpty else {
            throw XCTSkip("Set DICOM_INTEROP_OUTPUT_DIR for the DICOMKit interop harness.")
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for fixture in try Self.generatedFixtures() {
            try fixture.data.write(to: output.appendingPathComponent(fixture.fileName), options: .atomic)
        }
        for relativePath in [
            "Tests/DicomCoreTests/Fixtures/StructuredReports/sr_tid1500_measurement_report.dcm",
            "Tests/DicomCoreTests/Fixtures/StructuredReports/kos_key_object_selection.dcm",
            "Tests/DicomCoreTests/Fixtures/StructuredReports/sr_tid1500_roi_measurement_report.dcm"
        ] {
            let source = Self.packageRoot.appendingPathComponent(relativePath)
            try FileManager.default.copyItem(
                at: source,
                to: output.appendingPathComponent(source.lastPathComponent)
            )
        }
    }

    func test_TID1500ROIFixture_matchesBuilderAndRegeneratesWhenRequested() throws {
        let relativePath = "Tests/DicomCoreTests/Fixtures/StructuredReports/sr_tid1500_roi_measurement_report.dcm"
        let url = Self.packageRoot.appendingPathComponent(relativePath)
        let expected = try DicomSRMeasurementReportBuilderTests.fixtureData()
        if ProcessInfo.processInfo.environment["DICOM_REGENERATE_CLINICAL_INTEROP_FIXTURES"] == "1" {
            try expected.write(to: url, options: .atomic)
        }
        XCTAssertEqual(try Data(contentsOf: url), expected)
        let parsed = try XCTUnwrap(DCMDecoder(data: expected).structuredReport)
        XCTAssertTrue(DicomSRTemplateValidator.validate(parsed).errors.isEmpty)
    }

    func test_geometryFixtures_matchBuildersAndRegenerateWhenRequested() throws {
        for fixture in try DicomGeometryCorpusTests.newFixtures() {
            let url = DicomGeometryCorpusTests.fixtureRoot.appendingPathComponent(fixture.name)
            if ProcessInfo.processInfo.environment["DICOM_REGENERATE_CLINICAL_INTEROP_FIXTURES"] == "1" {
                try fixture.data.write(to: url, options: .atomic)
            }
            XCTAssertEqual(try Data(contentsOf: url), fixture.data, fixture.name)
        }
    }

    private static func generatedFixtures() throws -> [GeneratedFixture] {
        [
            GeneratedFixture(fileName: "seg_binary.dcm", data: try segmentationData()) { decoder in
                let segmentation = try XCTUnwrap(decoder.segmentation)
                XCTAssertEqual(segmentation.frames.first?.pixelData, .binary([1, 0, 0, 1]))
            },
            GeneratedFixture(fileName: "rtstruct_contour.dcm", data: try rtStructureSetData()) { decoder in
                let structureSet = try XCTUnwrap(decoder.rtStructureSet)
                XCTAssertEqual(structureSet.rois.first?.name, "PTV")
            },
            GeneratedFixture(fileName: "rtdose_grid.dcm", data: try rtDoseData()) { decoder in
                let dose = try XCTUnwrap(decoder.rtDose)
                XCTAssertEqual(dose.doseValues, [0.1, 0.2, 0.3, 0.4])
            },
            GeneratedFixture(fileName: "gsps_source_ct.dcm", data: try presentationSourceData()) { decoder in
                XCTAssertEqual(decoder.info(for: .sopInstanceUID), "2.25.1435004099")
                XCTAssertEqual(decoder.width, 2)
                XCTAssertEqual(decoder.height, 2)
            },
            GeneratedFixture(fileName: "gsps_annotation.dcm", data: try presentationStateData()) { decoder in
                let presentationState = try XCTUnwrap(decoder.grayscalePresentationState)
                XCTAssertEqual(presentationState.graphicAnnotations.first?.graphicObjects.count, 4)
                XCTAssertEqual(presentationState.graphicAnnotations.first?.textObjects.count, 1)
                XCTAssertEqual(presentationState.displayedAreas.first?.presentationSizeMode, "MAGNIFY")
                XCTAssertEqual(presentationState.shutters.count, 2)
                XCTAssertEqual(presentationState.shutterPresentationValue, 4_096)
            }
        ]
    }

    private static func segmentationData() throws -> Data {
        let segment = DicomSegment(
            number: 1,
            label: "Liver",
            algorithmType: "AUTOMATIC",
            algorithmName: "SyntheticInterop"
        )
        let segmentation = DicomSegmentation(
            sopInstanceUID: "2.25.1435001003",
            segmentationType: .binary,
            rows: 2,
            columns: 2,
            segments: [segment],
            frames: [
                DicomSegmentationFrame(
                    index: 0,
                    segmentNumber: 1,
                    pixelData: .binary([1, 0, 0, 1])
                )
            ]
        )
        let dataSet = DicomSegmentationBuilder.dataSet(
            from: segmentation,
            studyInstanceUID: "2.25.1435001001",
            seriesInstanceUID: "2.25.1435001002",
            options: DicomSegmentationBuildOptions(contentDate: "20260101", contentTime: "000000")
        )
        return try part10Data(
            dataSet,
            sopClassUID: DicomSegmentationBuilder.segmentationStorageSOPClassUID,
            sopInstanceUID: "2.25.1435001003"
        )
    }

    private static func rtStructureSetData() throws -> Data {
        let dataSet = DicomDataSet(elements: [
            string(.sopClassUID, vr: .UI, DicomRTStructureSet.storageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, "2.25.1435002003"),
            string(.studyInstanceUID, vr: .UI, "2.25.1435002001"),
            string(.seriesInstanceUID, vr: .UI, "2.25.1435002002"),
            string(.modality, vr: .CS, "RTSTRUCT"),
            string(.structureSetLabel, vr: .SH, "INTEROP"),
            sequence(.structureSetROISequence, [
                DicomDataSet(elements: [
                    integerString(.roiNumber, 1),
                    string(.referencedFrameOfReferenceUID, vr: .UI, "2.25.1435002099"),
                    string(.roiName, vr: .LO, "PTV"),
                    string(.roiGenerationAlgorithm, vr: .CS, "MANUAL")
                ])
            ]),
            sequence(.roiContourSequence, [
                DicomDataSet(elements: [
                    integerString(.referencedROINumber, 1),
                    integerStrings(.roiDisplayColor, [255, 64, 32]),
                    sequence(.contourSequence, [
                        DicomDataSet(elements: [
                            string(.contourGeometricType, vr: .CS, "CLOSED_PLANAR"),
                            integerString(.numberOfContourPoints, 3),
                            decimalStrings(.contourData, ["0", "0", "0", "1", "0", "0", "0", "1", "0"])
                        ])
                    ])
                ])
            ])
        ])
        return try part10Data(
            dataSet,
            sopClassUID: DicomRTStructureSet.storageSOPClassUID,
            sopInstanceUID: "2.25.1435002003"
        )
    }

    private static func rtDoseData() throws -> Data {
        let dataSet = DicomDataSet(elements: [
            string(.sopClassUID, vr: .UI, DicomRTDoseVolume.storageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, "2.25.1435003003"),
            string(.studyInstanceUID, vr: .UI, "2.25.1435003001"),
            string(.seriesInstanceUID, vr: .UI, "2.25.1435003002"),
            string(.modality, vr: .CS, "RTDOSE"),
            string(.doseUnits, vr: .CS, "GY"),
            string(.doseType, vr: .CS, "PHYSICAL"),
            string(.doseSummationType, vr: .CS, "PLAN"),
            string(.frameOfReferenceUID, vr: .UI, "2.25.1435003099"),
            decimalStrings(.doseGridScaling, ["0.01"]),
            decimalStrings(.gridFrameOffsetVector, ["0"]),
            unsignedShort(.samplesPerPixel, 1),
            string(.photometricInterpretation, vr: .CS, "MONOCHROME2"),
            string(.numberOfFrames, vr: .IS, "1"),
            unsignedShort(.rows, 2),
            unsignedShort(.columns, 2),
            decimalStrings(.pixelSpacing, ["1", "1"]),
            decimalStrings(.imagePositionPatient, ["0", "0", "0"]),
            decimalStrings(.imageOrientationPatient, ["1", "0", "0", "0", "1", "0"]),
            unsignedShort(.bitsAllocated, 16),
            unsignedShort(.bitsStored, 16),
            unsignedShort(.highBit, 15),
            unsignedShort(.pixelRepresentation, 0),
            DicomDataElement(
                tag: DicomTag.pixelData.rawValue,
                vr: .OW,
                value: .bytes(littleEndianUInt16([10, 20, 30, 40]))
            )
        ])
        return try part10Data(
            dataSet,
            sopClassUID: DicomRTDoseVolume.storageSOPClassUID,
            sopInstanceUID: "2.25.1435003003"
        )
    }

    private static func presentationStateData() throws -> Data {
        let image = DicomPresentationReferencedImage(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.1435004099",
            referencedFrameNumbers: [1]
        )
        return try DicomGrayscalePresentationStateBuilder.part10Data(
            referencedSeries: [
                DicomPresentationReferencedSeries(
                    seriesInstanceUID: "2.25.1435004098",
                    images: [image]
                )
            ],
            graphicAnnotations: [
                DicomPresentationGraphicAnnotation(
                    graphicLayer: "MEASUREMENTS",
                    referencedImages: [image],
                    graphicObjects: [
                        DicomPresentationGraphicObject(
                            graphicType: "POINT",
                            graphicData: [0.25, 0.25]
                        ),
                        DicomPresentationGraphicObject(
                            graphicType: "POLYLINE",
                            graphicData: [0, 0, 1, 1]
                        ),
                        DicomPresentationGraphicObject(
                            annotationUnits: "DISPLAY",
                            graphicType: "CIRCLE",
                            graphicData: [0.5, 0.5, 0.75, 0.5],
                            graphicFilled: false
                        ),
                        DicomPresentationGraphicObject(
                            annotationUnits: "DISPLAY",
                            graphicType: "ELLIPSE",
                            graphicData: [0.2, 0.5, 0.8, 0.5, 0.5, 0.3, 0.5, 0.7],
                            graphicFilled: false
                        )
                    ],
                    textObjects: [DicomPresentationTextObject(
                        text: "Synthetic target",
                        boundingBoxAnnotationUnits: "DISPLAY",
                        anchorPoint: SIMD2<Double>(0.5, 0.5),
                        anchorPointAnnotationUnits: "DISPLAY",
                        anchorPointVisible: true,
                        boundingBoxTopLeft: SIMD2<Double>(0.1, 0.05),
                        boundingBoxBottomRight: SIMD2<Double>(0.9, 0.2),
                        boundingBoxHorizontalJustification: "CENTER"
                    )]
                )
            ],
            graphicLayers: [
                DicomPresentationGraphicLayer(
                    name: "MEASUREMENTS",
                    order: 1,
                    recommendedDisplayCIELabValue: [45_000, 30_000, 52_000]
                )
            ],
            options: DicomPresentationStateBuildOptions(
                sopInstanceUID: "2.25.1435004003",
                studyInstanceUID: "2.25.1435004001",
                seriesInstanceUID: "2.25.1435004002",
                patientName: "INTEROP^SYNTHETIC",
                patientID: "INTEROP-1435",
                manufacturer: "DICOM-Swift",
                contentLabel: "INTEROP",
                contentDescription: "Synthetic GSPS interoperability fixture",
                presentationCreationDate: "20260713",
                presentationCreationTime: "120000",
                displayedAreas: [DicomPresentationDisplayedArea(
                    referencedImages: [image],
                    bottomRight: SIMD2<Int32>(2, 2),
                    presentationSizeMode: "MAGNIFY",
                    presentationPixelSpacing: [0.7, 0.8],
                    presentationPixelMagnificationRatio: 1.25
                )],
                spatialTransform: DicomPresentationSpatialTransform(
                    isHorizontallyFlipped: true,
                    rotationDegrees: 90
                ),
                shutters: [
                    .rectangular(left: 1, right: 2, upper: 1, lower: 2),
                    .bitmap(DicomPresentationBitmapShutter(
                        overlayGroup: 0x6000,
                        rows: 2,
                        columns: 2,
                        originRow: 0,
                        originColumn: 0,
                        mask: Data([1, 0, 0, 1])
                    ))
                ],
                shutterPresentationValue: 4_096,
                voiSelections: [DicomPresentationVOISelection(
                    referencedImages: [image],
                    displayTransformProfile: DicomDisplayTransformProfile(
                        windows: [DicomDisplayWindow(
                            settings: WindowSettings(center: 40, width: 400),
                            explanation: "Soft tissue",
                            source: .dicom(index: 0)
                        )]
                    )
                )]
            )
        )
    }

    private static func presentationSourceData() throws -> Data {
        let dataSet = DicomDataSet(elements: [
            string(.sopClassUID, vr: .UI, "1.2.840.10008.5.1.4.1.1.2"),
            string(.sopInstanceUID, vr: .UI, "2.25.1435004099"),
            string(.studyInstanceUID, vr: .UI, "2.25.1435004001"),
            string(.seriesInstanceUID, vr: .UI, "2.25.1435004098"),
            string(.patientName, vr: .PN, "INTEROP^SYNTHETIC"),
            string(.patientID, vr: .LO, "INTEROP-1435"),
            string(.modality, vr: .CS, "CT"),
            unsignedShort(.samplesPerPixel, 1),
            string(.photometricInterpretation, vr: .CS, "MONOCHROME2"),
            unsignedShort(.rows, 2),
            unsignedShort(.columns, 2),
            unsignedShort(.bitsAllocated, 16),
            unsignedShort(.bitsStored, 16),
            unsignedShort(.highBit, 15),
            unsignedShort(.pixelRepresentation, 0),
            decimalStrings(.windowCenter, ["150"]),
            decimalStrings(.windowWidth, ["300"]),
            DicomDataElement(
                tag: DicomTag.pixelData.rawValue,
                vr: .OW,
                value: .bytes(littleEndianUInt16([0, 100, 200, 300]))
            )
        ])
        return try part10Data(
            dataSet,
            sopClassUID: "1.2.840.10008.5.1.4.1.1.2",
            sopInstanceUID: "2.25.1435004099"
        )
    }

    private static func part10Data(
        _ dataSet: DicomDataSet,
        sopClassUID: String,
        sopInstanceUID: String
    ) throws -> Data {
        try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .explicitVRLittleEndian,
                mediaStorageSOPClassUID: sopClassUID,
                mediaStorageSOPInstanceUID: sopInstanceUID
            )
        )
    }

    private static func string(_ tag: DicomTag, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings([value]))
    }

    private static func integerString(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        integerStrings(tag, [value])
    }

    private static func integerStrings(_ tag: DicomTag, _ values: [Int]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .IS, value: .strings(values.map(String.init)))
    }

    private static func decimalStrings(_ tag: DicomTag, _ values: [String]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .DS, value: .strings(values))
    }

    private static func unsignedShort(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([UInt(value)]))
    }

    private static func sequence(_ tag: DicomTag, _ dataSets: [DicomDataSet]) -> DicomDataElement {
        DicomDataElement(
            tag: tag.rawValue,
            vr: .SQ,
            value: .sequence(dataSets.map { DicomSequenceItem(dataSet: $0) })
        )
    }

    private static func littleEndianUInt16(_ values: [UInt16]) -> Data {
        values.reduce(into: Data()) { data, value in
            data.append(UInt8(value & 0xFF))
            data.append(UInt8(value >> 8))
        }
    }

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct GeneratedFixture {
    let fileName: String
    let data: Data
    let validate: (DCMDecoder) throws -> Void
}
