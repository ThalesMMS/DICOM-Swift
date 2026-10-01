import XCTest
@testable import DicomCore

final class DicomRTPlanBuilderTests: XCTestCase {
    static func fullPlan() -> DicomRTPlan {
        let first = DicomRTControlPoint(index: 0, nominalBeamEnergy: 6, gantryAngle: 0,
            beamLimitingDeviceAngle: 0, patientSupportAngle: 0, tableTopEccentricAngle: 0,
            isocenterPosition: .init(1, 2, 3), cumulativeMetersetWeight: 0,
            gantryRotationDirection: "NONE", beamLimitingDeviceRotationDirection: "NONE",
            patientSupportRotationDirection: "NONE", tableTopEccentricRotationDirection: "NONE",
            gantryPitchAngle: 2, gantryPitchRotationDirection: "NONE", tableTopPitchAngle: 3,
            tableTopPitchRotationDirection: "NONE", tableTopRollAngle: 4, tableTopRollRotationDirection: "NONE",
            tableTopVerticalPosition: 10, tableTopLongitudinalPosition: 20, tableTopLateralPosition: 30,
            sourceToSurfaceDistance: 900, doseRateSet: 600,
            beamLimitingDevicePositions: [.init(type: "MLCX", leafJawPositions: [-10, -20, 10, 20])],
            wedgePositions: [.init(referencedWedgeNumber: 1, position: "IN")],
            referencedDoseReferences: [.init(number: 1, cumulativeDoseReferenceCoefficient: 0)])
        let last = DicomRTControlPoint(index: 1, cumulativeMetersetWeight: 1,
            referencedDoseReferences: [.init(number: 1, cumulativeDoseReferenceCoefficient: 1)])
        let beam = DicomRTBeam(number: 1, name: "BEAM", description: "Synthetic beam", type: "STATIC",
            radiationType: "PHOTON", treatmentMachineName: "LINAC", primaryDosimeterUnit: "MU",
            sourceAxisDistance: 1000, numberOfControlPoints: 2, controlPoints: [first, last],
            treatmentDeliveryType: "TREATMENT", referencedPatientSetupNumber: 1, referencedToleranceTableNumber: 1,
            numberOfWedges: 1, numberOfCompensators: 0, numberOfBoli: 0, numberOfBlocks: 0,
            beamLimitingDevices: [.init(type: "MLCX", numberOfLeafJawPairs: 2,
                sourceToBeamLimitingDeviceDistance: 500, leafPositionBoundaries: [-20, 0, 20])],
            finalCumulativeMetersetWeight: 1,
            referencedDoseReferences: [.init(number: 1, depthValueAveragingFlag: "NO", verificationControlPoints: [
                .init(cumulativeMetersetWeight: 0, referencedControlPointIndex: 0,
                    beamDosePointDepth: 100, beamDosePointEquivalentDepth: 90, beamDosePointSSD: 900),
                .init(cumulativeMetersetWeight: 1, referencedControlPointIndex: 1,
                    beamDosePointDepth: 100, beamDosePointEquivalentDepth: 90, beamDosePointSSD: 900)])],
            wedges: [.init(number: 1, type: "STANDARD", id: "W1", angle: 30, factor: 0.7,
                orientation: 90, sourceToWedgeTrayDistance: 650)])
        let prescription = DicomRTDoseReference(number: 1, structureType: "COORDINATES", type: "TARGET",
            uid: "2.25.234710", description: "Prescription", pointCoordinates: .init(1, 2, 3),
            constraintWeight: 1, deliveryMaximumDose: 65, targetMinimumDose: 58, targetPrescriptionDose: 60,
            targetMaximumDose: 64, targetUnderdoseVolumeFraction: 1)
        let organ = DicomRTDoseReference(number: 2, structureType: "VOLUME", type: "ORGAN_AT_RISK",
            referencedROINumber: 2, organAtRiskFullVolumeDose: 10, organAtRiskLimitDose: 20, organAtRiskMaximumDose: 30)
        let fraction = DicomRTFractionGroup(number: 1, numberOfBeams: 1, numberOfBrachyApplicationSetups: 0,
            numberOfFractionsPlanned: 30, description: "Fractions", numberOfFractionPatternDigitsPerDay: 1,
            repeatFractionCycleLength: 1, fractionPattern: "1111100",
            referencedBeams: [.init(number: 1, beamDose: 2, beamMeterset: 200, beamDeliveryDurationLimit: 60)],
            referencedDoseReferences: [.init(number: 1, constraintWeight: 1, deliveryMaximumDose: 65,
                targetMinimumDose: 58, targetPrescriptionDose: 60, targetMaximumDose: 64,
                targetUnderdoseVolumeFraction: 1, organAtRiskFullVolumeDose: 10, organAtRiskLimitDose: 20,
                organAtRiskMaximumDose: 30, deliveryWarningDose: 62, organAtRiskOverdoseVolumeFraction: 2)])
        let setup = DicomRTPatientSetup(number: 1, label: "SETUP", patientPosition: "HFS", setupTechnique: "ISOCENTRIC",
            setupTechniqueDescription: "Synthetic setup", tableTopVerticalSetupDisplacement: 1,
            tableTopLongitudinalSetupDisplacement: 2, tableTopLateralSetupDisplacement: 3,
            fixationDevices: [.init(type: "MASK", label: "MASK", description: "Synthetic mask")],
            shieldingDevices: [.init(type: "EYE", label: "EYE", description: "Synthetic shield")],
            setupDevices: [.init(type: "LASER_POINTER", label: "LASER", description: "Alignment",
                parameter: 10, referenceDescription: "Origin")])
        let tolerance = DicomRTToleranceTable(number: 1, label: "TOLERANCE", gantryAngleTolerance: 1,
            beamLimitingDeviceAngleTolerance: 2, patientSupportAngleTolerance: 3, tableTopEccentricAngleTolerance: 4,
            tableTopPitchAngleTolerance: 5, tableTopRollAngleTolerance: 6, tableTopVerticalPositionTolerance: 7,
            tableTopLongitudinalPositionTolerance: 8, tableTopLateralPositionTolerance: 9,
            beamLimitingDeviceTolerances: [.init(type: "MLCX", positionTolerance: 1)])
        return DicomRTPlan(sopInstanceUID: "2.25.234701", label: "FULL", name: "Synthetic plan",
            description: "Lot A1", geometry: "PATIENT", beams: [beam],
            objectReferences: [.init(kind: .structureSet, sopClassUID: DicomRTStructureSet.storageSOPClassUID,
                sopInstanceUID: "2.25.23279903")], doseReferences: [prescription, organ], fractionGroups: [fraction],
            patientSetups: [setup], toleranceTables: [tolerance], rtPlanDate: "20260910", rtPlanTime: "120000",
            approvalStatus: "APPROVED", reviewDate: "20260910", reviewTime: "130000", reviewerName: "SYNTHETIC")
    }

    func test_fullPlan_roundTripsAndPreservesAbsentControlPointValues() throws {
        let model = Self.fullPlan()
        let data = try DicomRTPlanBuilder.dataSet(from: model, studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
        let parsed = try XCTUnwrap(DCMDecoder(data: DicomGeometryCorpusTests.bytes(data)).rtPlan)
        XCTAssertEqual(parsed, model)
        XCTAssertNil(parsed.beams[0].controlPoints[1].gantryAngle)
        XCTAssertNil(parsed.beams[0].controlPoints[1].gantryRotationDirection)
        XCTAssertNil(parsed.beams[0].controlPoints[1].tableTopPitchAngle)
        XCTAssertTrue(parsed.beams[0].controlPoints[1].beamLimitingDevicePositions.isEmpty)
        let rebuilt = try DicomRTPlanBuilder.dataSet(from: parsed, studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
        XCTAssertEqual(try DCMDecoder(data: DicomGeometryCorpusTests.bytes(rebuilt)).rtPlan, model)
        XCTAssertFalse(data.sequenceItems(for: 0x300A0070)[0].dataSet.sequenceItems(for: 0x300C0004)[0].dataSet.contains(0x300A0082))
    }

    func test_legacyDosePoint_roundTripsOnlyWhenPresent() throws {
        var plan = Self.fullPlan()
        plan.fractionGroups[0].referencedBeams[0].beamDoseSpecificationPoint = .init(10, 20, 30)
        let data = try DicomRTPlanBuilder.dataSet(from: plan, studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
        XCTAssertEqual(try DCMDecoder(data: DicomGeometryCorpusTests.bytes(data)).rtPlan, plan)
    }

    func test_requiredReferenceChildren_andTypeTwoEmptyValues_roundTrip() throws {
        let image = DicomSourceImageReference(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2", referencedSOPInstanceUID: "2.25.234780")
        let point = DicomRTControlPoint(index: 0, referencedDoses: [.init(sopClassUID: DicomRTDoseVolume.storageSOPClassUID,
            sopInstanceUID: "2.25.234781")])
        let beam = DicomRTBeam(number: 1, controlPoints: [point], referenceImageReferences: [image], referenceImageNumbers: [7],
            highDoseTechniqueType: "TBI")
        var plan = DicomRTPlan(sopInstanceUID: "2.25.234782", label: "REFERENCES", geometry: "TREATMENT_DEVICE", beams: [beam],
            setupImageReferences: [image], patientSetups: [.init(number: 1, patientAdditionalPosition: "Synthetic position",
                fixationDevices: [.init(type: "MASK")], setupDevices: [.init(type: "LASER_POINTER")], setupImageReferences: [image])])
        let data = try DicomRTPlanBuilder.dataSet(from: plan, studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
        let parsed = try XCTUnwrap(DCMDecoder(data: DicomGeometryCorpusTests.bytes(data)).rtPlan)
        XCTAssertEqual(parsed.beams[0].referenceImageNumbers, [7])
        XCTAssertEqual(parsed.beams[0].referenceImageReferences, [image])
        XCTAssertEqual(parsed.beams[0].controlPoints[0].referencedDoses, point.referencedDoses)
        XCTAssertEqual(parsed.beams[0].highDoseTechniqueType, "TBI")
        XCTAssertEqual(parsed.patientSetups, plan.patientSetups)
        XCTAssertEqual(parsed.setupImageReferences, [image])
        let device = data.sequenceItems(for: 0x300A0180)[0].dataSet.sequenceItems(for: 0x300A01B4)[0].dataSet
        XCTAssertTrue(device.contains(0x300A01B8))
        XCTAssertTrue(device.contains(0x300A01BC))
        XCTAssertNil(parsed.patientSetups[0].setupDevices[0].parameter)
        plan.fractionGroups = [.init(number: 1, numberOfBeams: 0, numberOfBrachyApplicationSetups: 1,
            referencedBrachyApplicationSetups: [.init(number: 2, dose: 5, doseSpecificationPoint: .init(1, 2, 3))])]
        let raw = plan.dataSet.setting(DicomRTValueCoding.text(0x00080016, .UI, DicomRTPlan.storageSOPClassUID))
            .setting(DicomRTValueCoding.text(0x00080018, .UI, "2.25.234782"))
        XCTAssertEqual(try DCMDecoder(data: DicomGeometryCorpusTests.bytes(raw)).rtPlan?.fractionGroups, plan.fractionGroups)
    }

    func test_brachyPlan_throwsUnsupported() {
        var plan = Self.fullPlan()
        plan.fractionGroups[0].numberOfBrachyApplicationSetups = 1
        XCTAssertThrowsError(try DicomRTPlanBuilder.dataSet(from: plan, studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")) {
            XCTAssertEqual($0 as? DicomRTPlanBuilder.BuildError, .unsupported)
        }
    }

    func test_incompleteLeafJawPositions_refuseTypedParseAndAuthoring() {
        let type = DicomRTValueCoding.text(0x300A00B8, .CS, "MLCX")
        XCTAssertNil(DicomRTBeamLimitingDevicePosition(data: .init(elements: [type])))
        let invalidPositions: [[Double]] = [[], [1], [1, 2], [1, 2, 3, .nan]]
        for positions in invalidPositions {
            let point = DicomRTControlPoint(index: 0,
                beamLimitingDevicePositions: [.init(type: "MLCX", leafJawPositions: positions)])
            let beam = DicomRTBeam(number: 1, controlPoints: [point],
                beamLimitingDevices: [.init(type: "MLCX", numberOfLeafJawPairs: 2)])
            let plan = DicomRTPlan(label: "INVALID", geometry: "PATIENT", beams: [beam])
            XCTAssertThrowsError(try DicomRTPlanBuilder.dataSet(from: plan, studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")) {
                XCTAssertEqual($0 as? DicomRTPlanBuilder.BuildError, .invalidLeafJawPositions)
            }
        }
    }
}
