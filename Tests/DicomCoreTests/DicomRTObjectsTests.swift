import simd
import XCTest
@testable import DicomCore

final class DicomRTObjectsTests: XCTestCase {
    func testRTStructureSetParsesROIsAndContoursInPatientCoordinates() throws {
        let sourceReference = DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.1001",
            referencedFrameNumbers: [3]
        )
        let dataSet = DicomDataSet(elements: [
            string(.sopClassUID, vr: .UI, DicomRTStructureSet.storageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, "2.25.1002"),
            string(.modality, vr: .CS, "RTSTRUCT"),
            string(.structureSetLabel, vr: .SH, "SS1"),
            string(.structureSetName, vr: .LO, "Plan contours"),
            sequence(.referencedFrameOfReferenceSequence, [
                DicomDataSet(elements: [
                    string(.frameOfReferenceUID, vr: .UI, "2.25.1003"),
                    sequence(.rtReferencedStudySequence, [
                        DicomDataSet(elements: [
                            sequence(.rtReferencedSeriesSequence, [
                                DicomDataSet(elements: [
                                    string(.seriesInstanceUID, vr: .UI, "2.25.1004")
                                ])
                            ])
                        ])
                    ])
                ])
            ]),
            sequence(.structureSetROISequence, [
                DicomDataSet(elements: [
                    isValue(.roiNumber, 7),
                    string(.referencedFrameOfReferenceUID, vr: .UI, "2.25.1003"),
                    string(.roiName, vr: .LO, "PTV"),
                    string(.roiDescription, vr: .ST, "Planning target volume"),
                    string(.roiGenerationAlgorithm, vr: .CS, "MANUAL")
                ])
            ]),
            sequence(.roiContourSequence, [
                DicomDataSet(elements: [
                    isValue(.referencedROINumber, 7),
                    isValues(.roiDisplayColor, [255, 64, 32]),
                    sequence(.contourSequence, [
                        DicomDataSet(elements: [
                            isValue(.contourNumber, 1),
                            string(.contourGeometricType, vr: .CS, "CLOSED_PLANAR"),
                            isValue(.numberOfContourPoints, 3),
                            ds(.contourData, ["1", "2", "3", "4", "5", "6", "7", "8", "9"]),
                            sequence(.contourImageSequence, [
                                DicomDataSet(elements: [
                                    string(.referencedSOPClassUID, vr: .UI, sourceReference.referencedSOPClassUID!),
                                    string(.referencedSOPInstanceUID, vr: .UI, sourceReference.referencedSOPInstanceUID!),
                                    isValues(.referencedFrameNumber, sourceReference.referencedFrameNumbers)
                                ])
                            ])
                        ])
                    ])
                ])
            ]),
            sequence(.rtROIObservationsSequence, [
                DicomDataSet(elements: [
                    isValue(.observationNumber, 1),
                    isValue(.referencedROINumber, 7),
                    string(.roiObservationLabel, vr: .SH, "PTV"),
                    string(.rtROIInterpretedType, vr: .CS, "PTV"),
                    string(.roiInterpreter, vr: .PN, "Doe^Physicist")
                ])
            ])
        ])

        let decoder = try open(dataSet: dataSet, sopClassUID: DicomRTStructureSet.storageSOPClassUID)
        let structureSet = try XCTUnwrap(decoder.rtStructureSet)

        XCTAssertEqual(structureSet.sopInstanceUID, "2.25.1002")
        XCTAssertEqual(structureSet.label, "SS1")
        XCTAssertEqual(structureSet.referencedSeriesInstanceUIDs, ["2.25.1004"])
        XCTAssertEqual(structureSet.rois.count, 1)
        XCTAssertEqual(structureSet.rois[0].number, 7)
        XCTAssertEqual(structureSet.rois[0].name, "PTV")
        XCTAssertEqual(structureSet.rois[0].referencedFrameOfReferenceUID, "2.25.1003")
        XCTAssertEqual(structureSet.rois[0].generationAlgorithm, "MANUAL")
        XCTAssertEqual(structureSet.rois[0].interpretedType, "PTV")

        let roiContour = try XCTUnwrap(structureSet.roiContours.first)
        XCTAssertEqual(roiContour.referencedROINumber, 7)
        XCTAssertEqual(roiContour.displayColor, [255, 64, 32])
        XCTAssertEqual(roiContour.contours.first?.geometricType, "CLOSED_PLANAR")
        XCTAssertEqual(roiContour.contours.first?.points, [
            SIMD3<Double>(1, 2, 3),
            SIMD3<Double>(4, 5, 6),
            SIMD3<Double>(7, 8, 9)
        ])
        XCTAssertEqual(roiContour.contours.first?.sourceImageReferences, [sourceReference])
        XCTAssertEqual(structureSet.contoursByROINumber[7]?.count, 1)
    }

    func testRTDoseParsesScaledDoseVolume() throws {
        let storedValues: [UInt16] = [10, 20, 30, 40, 50, 60, 70, 80]
        let dataSet = DicomDataSet(elements: [
            string(.sopClassUID, vr: .UI, DicomRTDoseVolume.storageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, "2.25.2001"),
            string(.modality, vr: .CS, "RTDOSE"),
            string(.doseUnits, vr: .CS, "GY"),
            string(.doseType, vr: .CS, "PHYSICAL"),
            string(.doseSummationType, vr: .CS, "PLAN"),
            string(.frameOfReferenceUID, vr: .UI, "2.25.2000"),
            ds(.doseGridScaling, ["0.01"]),
            ds(.gridFrameOffsetVector, ["0", "2.5"]),
            us(.samplesPerPixel, 1),
            string(.photometricInterpretation, vr: .CS, "MONOCHROME2"),
            string(.numberOfFrames, vr: .IS, "2"),
            us(.rows, 2),
            us(.columns, 2),
            ds(.pixelSpacing, ["1.25", "1.5"]),
            ds(.sliceThickness, ["2.5"]),
            ds(.imagePositionPatient, ["10", "20", "30"]),
            ds(.imageOrientationPatient, ["1", "0", "0", "0", "1", "0"]),
            us(.bitsAllocated, 16),
            us(.bitsStored, 16),
            us(.highBit, 15),
            us(.pixelRepresentation, 0),
            bytes(.pixelData, vr: .OW, uint16Data(storedValues))
        ])

        let decoder = try open(dataSet: dataSet, sopClassUID: DicomRTDoseVolume.storageSOPClassUID)
        let dose = try XCTUnwrap(decoder.rtDose)

        XCTAssertEqual(dose.sopInstanceUID, "2.25.2001")
        XCTAssertEqual(dose.doseUnits, "GY")
        XCTAssertEqual(dose.doseType, "PHYSICAL")
        XCTAssertEqual(dose.doseSummationType, "PLAN")
        XCTAssertEqual(dose.frameOfReferenceUID, "2.25.2000")
        XCTAssertEqual(dose.rows, 2)
        XCTAssertEqual(dose.columns, 2)
        XCTAssertEqual(dose.frames, 2)
        XCTAssertEqual(dose.pixelSpacing, SIMD2<Double>(1.25, 1.5))
        XCTAssertEqual(dose.imagePositionPatient, SIMD3<Double>(10, 20, 30))
        XCTAssertEqual(dose.imageOrientationPatient?.normal, SIMD3<Double>(0, 0, 1))
        XCTAssertEqual(dose.gridFrameOffsetVector, [0, 2.5])
        XCTAssertEqual(dose.sliceThickness, 2.5)
        XCTAssertEqual(dose.storedValues, storedValues.map(UInt32.init))
        assertEqual(dose.doseValues, [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8], accuracy: 1e-12)
    }

    func testRTPlanParsesBeamsAndControlPoints() throws {
        let dataSet = DicomDataSet(elements: [
            string(.sopClassUID, vr: .UI, DicomRTPlan.storageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, "2.25.3001"),
            string(.modality, vr: .CS, "RTPLAN"),
            string(.rtPlanLabel, vr: .SH, "PLAN_A"),
            string(.rtPlanName, vr: .LO, "Reference plan"),
            string(.rtPlanDescription, vr: .ST, "Synthetic inspection plan"),
            string(.rtPlanGeometry, vr: .CS, "PATIENT"),
            sequence(.referencedStructureSetSequence, [
                DicomDataSet(elements: [
                    string(.referencedSOPClassUID, vr: .UI, DicomRTStructureSet.storageSOPClassUID),
                    string(.referencedSOPInstanceUID, vr: .UI, "2.25.3100")
                ])
            ]),
            sequence(.referencedDoseSequence, [
                DicomDataSet(elements: [
                    string(.referencedSOPClassUID, vr: .UI, DicomRTDoseVolume.storageSOPClassUID),
                    string(.referencedSOPInstanceUID, vr: .UI, "2.25.3200")
                ])
            ]),
            sequence(.referencedRTPlanSequence, [
                DicomDataSet(elements: [
                    string(.referencedSOPClassUID, vr: .UI, DicomRTPlan.storageSOPClassUID),
                    string(.referencedSOPInstanceUID, vr: .UI, "2.25.3300"),
                    string(.rtPlanRelationship, vr: .CS, "PREDECESSOR")
                ])
            ]),
            sequence(.patientSetupSequence, [
                DicomDataSet(elements: [
                    sequence(.referencedSetupImageSequence, [
                        DicomDataSet(elements: [
                            string(.referencedSOPClassUID, vr: .UI, "1.2.840.10008.5.1.4.1.1.481.1"),
                            string(.referencedSOPInstanceUID, vr: .UI, "2.25.3400"),
                            isValues(.referencedFrameNumber, [2])
                        ])
                    ])
                ])
            ]),
            sequence(.beamSequence, [
                DicomDataSet(elements: [
                    isValue(.beamNumber, 1),
                    string(.beamName, vr: .LO, "AP"),
                    string(.beamDescription, vr: .ST, "Anterior field"),
                    string(.beamType, vr: .CS, "STATIC"),
                    string(.radiationType, vr: .CS, "PHOTON"),
                    string(.treatmentMachineName, vr: .SH, "LINAC-1"),
                    string(.primaryDosimeterUnit, vr: .CS, "MU"),
                    ds(.sourceAxisDistance, ["1000"]),
                    isValue(.numberOfControlPoints, 2),
                    sequence(.referencedReferenceImageSequence, [
                        DicomDataSet(elements: [
                            string(.referencedSOPClassUID, vr: .UI, "1.2.840.10008.5.1.4.1.1.481.1"),
                            string(.referencedSOPInstanceUID, vr: .UI, "2.25.3500")
                        ])
                    ]),
                    sequence(.controlPointSequence, [
                        DicomDataSet(elements: [
                            isValue(.controlPointIndex, 0),
                            ds(.nominalBeamEnergy, ["6"]),
                            ds(.gantryAngle, ["0"]),
                            ds(.beamLimitingDeviceAngle, ["5"]),
                            ds(.patientSupportAngle, ["0"]),
                            ds(.tableTopEccentricAngle, ["0"]),
                            ds(.isocenterPosition, ["1", "2", "3"]),
                            ds(.cumulativeMetersetWeight, ["0"])
                        ]),
                        DicomDataSet(elements: [
                            isValue(.controlPointIndex, 1),
                            ds(.gantryAngle, ["45"]),
                            ds(.cumulativeMetersetWeight, ["1"])
                        ])
                    ])
                ])
            ])
        ])

        let decoder = try open(dataSet: dataSet, sopClassUID: DicomRTPlan.storageSOPClassUID)
        let plan = try XCTUnwrap(decoder.rtPlan)

        XCTAssertEqual(plan.sopInstanceUID, "2.25.3001")
        XCTAssertEqual(plan.label, "PLAN_A")
        XCTAssertEqual(plan.name, "Reference plan")
        XCTAssertEqual(plan.geometry, "PATIENT")
        XCTAssertEqual(plan.beams.count, 1)
        XCTAssertEqual(plan.beams[0].number, 1)
        XCTAssertEqual(plan.beams[0].name, "AP")
        XCTAssertEqual(plan.beams[0].type, "STATIC")
        XCTAssertEqual(plan.beams[0].radiationType, "PHOTON")
        XCTAssertEqual(plan.beams[0].treatmentMachineName, "LINAC-1")
        XCTAssertEqual(plan.beams[0].sourceAxisDistance, 1000)
        XCTAssertEqual(plan.beams[0].numberOfControlPoints, 2)
        XCTAssertEqual(plan.beams[0].controlPoints[0].nominalBeamEnergy, 6)
        XCTAssertEqual(plan.beams[0].controlPoints[0].isocenterPosition, SIMD3<Double>(1, 2, 3))
        XCTAssertEqual(plan.beams[0].controlPoints[1].gantryAngle, 45)
        XCTAssertEqual(plan.beams[0].controlPoints[1].cumulativeMetersetWeight, 1)
        XCTAssertEqual(plan.beamSequenceItemCount, 1)
        XCTAssertEqual(plan.beams[0].controlPointSequenceItemCount, 2)
        XCTAssertEqual(plan.objectReferences.map(\.kind), [.structureSet, .dose, .plan])
        XCTAssertEqual(plan.objectReferences.map(\.sopInstanceUID), ["2.25.3100", "2.25.3200", "2.25.3300"])
        XCTAssertEqual(plan.objectReferences.last?.relationship, "PREDECESSOR")
        XCTAssertEqual(plan.setupImageReferences.first?.referencedSOPInstanceUID, "2.25.3400")
        XCTAssertEqual(plan.setupImageReferences.first?.referencedFrameNumbers, [2])
        XCTAssertEqual(plan.beams[0].referenceImageReferences.first?.referencedSOPInstanceUID, "2.25.3500")
    }

    func testRTPlanPreservesRecognizedIncompleteObjectForDiagnostics() throws {
        let dataSet = DicomDataSet(elements: [
            string(.sopClassUID, vr: .UI, DicomRTPlan.storageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, "2.25.3600"),
            string(.modality, vr: .CS, "RTPLAN"),
            sequence(.beamSequence, [
                DicomDataSet(elements: [
                    string(.beamName, vr: .LO, "Missing beam number")
                ])
            ]),
            sequence(.referencedStructureSetSequence, [
                DicomDataSet(elements: [
                    string(.referencedSOPClassUID, vr: .UI, DicomRTStructureSet.storageSOPClassUID)
                ])
            ])
        ])

        let decoder = try open(dataSet: dataSet, sopClassUID: DicomRTPlan.storageSOPClassUID)
        let plan = try XCTUnwrap(decoder.rtPlan)

        XCTAssertEqual(plan.sopInstanceUID, "2.25.3600")
        XCTAssertNil(plan.label)
        XCTAssertNil(plan.geometry)
        XCTAssertTrue(plan.beams.isEmpty)
        XCTAssertEqual(plan.beamSequenceItemCount, 1)
        XCTAssertEqual(plan.objectReferences.count, 1)
        XCTAssertNil(plan.objectReferences[0].sopInstanceUID)
    }

    func testSpatialRegistrationParsesOrderedMatricesAndSourceReferences() throws {
        let firstMatrix = [
            "1", "0", "0", "10",
            "0", "1", "0", "0",
            "0", "0", "1", "0",
            "0", "0", "0", "1"
        ]
        let secondMatrix = [
            "0", "-1", "0", "0",
            "1", "0", "0", "0",
            "0", "0", "1", "0",
            "0", "0", "0", "1"
        ]
        let dataSet = DicomDataSet(elements: [
            string(.sopClassUID, vr: .UI, DicomSpatialRegistrationDocument.storageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, "2.25.4001"),
            string(.frameOfReferenceUID, vr: .UI, "2.25.4002"),
            sequence(.registrationSequence, [
                DicomDataSet(elements: [
                    string(.frameOfReferenceUID, vr: .UI, "2.25.4003"),
                    sequence(.referencedImageSequence, [
                        DicomDataSet(elements: [
                            string(.referencedSOPInstanceUID, vr: .UI, "2.25.4004")
                        ])
                    ]),
                    sequence(.matrixRegistrationSequence, [
                        DicomDataSet(elements: [
                            sequence(.matrixSequence, [
                                DicomDataSet(elements: [
                                    string(.frameOfReferenceTransformationMatrixType, vr: .CS, "RIGID"),
                                    ds(.frameOfReferenceTransformationMatrix, firstMatrix)
                                ]),
                                DicomDataSet(elements: [
                                    string(.frameOfReferenceTransformationMatrixType, vr: .CS, "RIGID"),
                                    ds(.frameOfReferenceTransformationMatrix, secondMatrix)
                                ])
                            ])
                        ])
                    ])
                ])
            ])
        ])

        let decoder = try open(
            dataSet: dataSet,
            sopClassUID: DicomSpatialRegistrationDocument.storageSOPClassUID
        )
        let registration = try XCTUnwrap(decoder.spatialRegistration)

        XCTAssertEqual(registration.sopInstanceUID, "2.25.4001")
        XCTAssertEqual(registration.registeredFrameOfReferenceUID, "2.25.4002")
        XCTAssertEqual(registration.registrations.count, 1)
        XCTAssertEqual(registration.registrations[0].sourceFrameOfReferenceUID, "2.25.4003")
        XCTAssertEqual(registration.registrations[0].referencedSOPInstanceUIDs, ["2.25.4004"])
        XCTAssertEqual(registration.registrations[0].matrices.map(\.type), ["RIGID", "RIGID"])
        XCTAssertEqual(registration.registrations[0].matrices[0].rowMajorValues, firstMatrix.compactMap(Double.init))
        XCTAssertEqual(registration.registrations[0].matrices[1].rowMajorValues, secondMatrix.compactMap(Double.init))
    }

    func testSpatialRegistrationRejectsMalformedMatrix() throws {
        let dataSet = DicomDataSet(elements: [
            string(.sopClassUID, vr: .UI, DicomSpatialRegistrationDocument.storageSOPClassUID),
            string(.frameOfReferenceUID, vr: .UI, "2.25.4100"),
            sequence(.registrationSequence, [
                DicomDataSet(elements: [
                    string(.frameOfReferenceUID, vr: .UI, "2.25.4101"),
                    sequence(.matrixRegistrationSequence, [
                        DicomDataSet(elements: [
                            sequence(.matrixSequence, [
                                DicomDataSet(elements: [
                                    string(.frameOfReferenceTransformationMatrixType, vr: .CS, "RIGID"),
                                    ds(.frameOfReferenceTransformationMatrix, ["1", "0", "0"])
                                ])
                            ])
                        ])
                    ])
                ])
            ])
        ])

        let decoder = try open(
            dataSet: dataSet,
            sopClassUID: DicomSpatialRegistrationDocument.storageSOPClassUID
        )

        XCTAssertNil(decoder.spatialRegistration)
    }

    private func open(dataSet: DicomDataSet, sopClassUID: String) throws -> DCMDecoder {
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(mediaStorageSOPClassUID: sopClassUID)
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt_object_\(UUID().uuidString).dcm")
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

    private func string(_ tag: DicomTag, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings([value]))
    }

    private func isValue(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        isValues(tag, [value])
    }

    private func isValues(_ tag: DicomTag, _ values: [Int]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .IS, value: .strings(values.map(String.init)))
    }

    private func us(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([UInt(value)]))
    }

    private func ds(_ tag: DicomTag, _ values: [String]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .DS, value: .strings(values))
    }

    private func bytes(_ tag: DicomTag, vr: DicomVR, _ data: Data) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .bytes(data))
    }

    private func uint16Data(_ values: [UInt16]) -> Data {
        values.reduce(into: Data()) { data, value in
            data.append(UInt8(value & 0x00FF))
            data.append(UInt8((value >> 8) & 0x00FF))
        }
    }

    private func assertEqual(
        _ actual: [Double],
        _ expected: [Double],
        accuracy: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actualValue, expectedValue) in zip(actual, expected) {
            XCTAssertEqual(actualValue, expectedValue, accuracy: accuracy, file: file, line: line)
        }
    }
}
