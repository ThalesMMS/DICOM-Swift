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
            "Tests/DicomCoreTests/Fixtures/StructuredReports/kos_key_object_selection.dcm"
        ] {
            let source = Self.packageRoot.appendingPathComponent(relativePath)
            try FileManager.default.copyItem(
                at: source,
                to: output.appendingPathComponent(source.lastPathComponent)
            )
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
            GeneratedFixture(fileName: "gsps_annotation.dcm", data: try presentationStateData()) { decoder in
                let presentationState = try XCTUnwrap(decoder.grayscalePresentationState)
                XCTAssertEqual(presentationState.graphicAnnotations.first?.graphicObjects.count, 1)
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
            seriesInstanceUID: "2.25.1435001002"
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
            referencedSOPInstanceUID: "2.25.1435004099"
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
                            graphicType: "POLYLINE",
                            graphicData: [0, 0, 1, 1]
                        )
                    ]
                )
            ],
            options: DicomPresentationStateBuildOptions(
                sopInstanceUID: "2.25.1435004003",
                studyInstanceUID: "2.25.1435004001",
                seriesInstanceUID: "2.25.1435004002",
                patientName: "INTEROP^SYNTHETIC",
                patientID: "INTEROP-1435",
                contentLabel: "INTEROP",
                contentDescription: "Synthetic GSPS interoperability fixture",
                presentationCreationDate: "20260713",
                presentationCreationTime: "120000",
                displayedArea: DicomPresentationDisplayedArea(bottomRight: SIMD2<Int32>(2, 2))
            )
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
