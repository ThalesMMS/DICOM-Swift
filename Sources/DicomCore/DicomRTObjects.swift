import Foundation
import simd

/// One RTSTRUCT contour represented in patient coordinates.
public struct DicomRTContour: Equatable, Sendable {
    public let number: Int?
    public let geometricType: String
    public let points: [SIMD3<Double>]
    public let sourceImageReferences: [DicomSourceImageReference]
    public let sourcePixelPlanes: DicomRTSourcePixelPlanes?
    public var knownGeometricType: DicomRTContourGeometricType? { .init(rawValue: geometricType) }

    public init(
        number: Int? = nil,
        geometricType: String,
        points: [SIMD3<Double>],
        sourceImageReferences: [DicomSourceImageReference] = [],
        sourcePixelPlanes: DicomRTSourcePixelPlanes? = nil
    ) {
        self.number = number
        self.geometricType = geometricType
        self.points = points
        self.sourceImageReferences = sourceImageReferences
        self.sourcePixelPlanes = sourcePixelPlanes
    }
    public init(number: Int? = nil, geometricType: DicomRTContourGeometricType, points: [SIMD3<Double>],
                sourceImageReferences: [DicomSourceImageReference] = [], sourcePixelPlanes: DicomRTSourcePixelPlanes? = nil) {
        self.init(number: number, geometricType: geometricType.rawValue, points: points,
                  sourceImageReferences: sourceImageReferences, sourcePixelPlanes: sourcePixelPlanes)
    }

}

/// RTSTRUCT ROI metadata from Structure Set ROI Sequence and ROI observations.
public struct DicomRTROI: Equatable, Sendable {
    public let number: Int
    public let name: String
    public let description: String?
    public let referencedFrameOfReferenceUID: String?
    public let generationDescription: String?
    public let derivationCode: DicomCodedConcept?
    public let generationAlgorithm: String?
    public let observationLabel: String?
    public let interpretedType: String?
    public let interpreter: String?

    public init(
        number: Int,
        name: String,
        description: String? = nil,
        referencedFrameOfReferenceUID: String? = nil,
        generationAlgorithm: String? = nil,
        observationLabel: String? = nil,
        interpretedType: String? = nil,
        interpreter: String? = nil,
        generationDescription: String? = nil,
        derivationCode: DicomCodedConcept? = nil
    ) {
        self.generationDescription = generationDescription
        self.derivationCode = derivationCode
        self.number = number
        self.name = name
        self.description = description?.dicomRTNonEmptyValue
        self.referencedFrameOfReferenceUID = referencedFrameOfReferenceUID?.dicomRTNonEmptyValue
        self.generationAlgorithm = generationAlgorithm?.dicomRTNonEmptyValue
        self.observationLabel = observationLabel?.dicomRTNonEmptyValue
        self.interpretedType = interpretedType?.dicomRTNonEmptyValue
        self.interpreter = interpreter?.dicomRTNonEmptyValue
    }
}

/// Contours and display metadata for one referenced RTSTRUCT ROI.
public struct DicomRTROIContour: Equatable, Sendable {
    public let referencedROINumber: Int
    public let displayColor: [Int]
    public let contours: [DicomRTContour]
    public let sourcePixelPlanes: DicomRTSourcePixelPlanes?

    public init(referencedROINumber: Int, displayColor: [Int] = [], contours: [DicomRTContour],
                sourcePixelPlanes: DicomRTSourcePixelPlanes? = nil) {
        self.referencedROINumber = referencedROINumber
        self.displayColor = displayColor
        self.sourcePixelPlanes = sourcePixelPlanes
        self.contours = contours.map {
            DicomRTContour(number: $0.number, geometricType: $0.geometricType, points: $0.points,
                           sourceImageReferences: $0.sourceImageReferences, sourcePixelPlanes: sourcePixelPlanes)
        }
    }
}

/// Parsed RT Structure Set object.
public struct DicomRTStructureSet: Equatable, Sendable {
    public static let storageSOPClassUID = "1.2.840.10008.5.1.4.1.1.481.3"

    public let sopInstanceUID: String?
    public let label: String?
    public let name: String?
    public let description: String?
    public let referencedSeriesInstanceUIDs: [String]
    public let rois: [DicomRTROI]
    public let roiContours: [DicomRTROIContour]
    public let structureSetDate: String?
    public let structureSetTime: String?
    public let referencedFramesOfReference: [DicomRTReferencedFrameOfReference]
    public let observations: [DicomRTROIObservation]

    public init(
        sopInstanceUID: String? = nil,
        label: String? = nil,
        name: String? = nil,
        description: String? = nil,
        referencedSeriesInstanceUIDs: [String] = [],
        rois: [DicomRTROI],
        roiContours: [DicomRTROIContour],
        structureSetDate: String? = nil,
        structureSetTime: String? = nil,
        referencedFramesOfReference: [DicomRTReferencedFrameOfReference] = [],
        observations: [DicomRTROIObservation] = []
    ) {
        self.sopInstanceUID = sopInstanceUID?.dicomRTNonEmptyValue
        self.label = label?.dicomRTNonEmptyValue
        self.name = name?.dicomRTNonEmptyValue
        self.description = description?.dicomRTNonEmptyValue
        self.referencedSeriesInstanceUIDs = referencedSeriesInstanceUIDs
        self.rois = rois
        self.roiContours = roiContours
        self.structureSetDate = structureSetDate?.dicomRTNonEmptyValue
        self.structureSetTime = structureSetTime?.dicomRTNonEmptyValue
        self.referencedFramesOfReference = referencedFramesOfReference
        self.observations = observations
    }

    public var contoursByROINumber: [Int: [DicomRTContour]] {
        roiContours.reduce(into: [Int: [DicomRTContour]]()) { result, roiContour in
            result[roiContour.referencedROINumber, default: []].append(contentsOf: roiContour.contours)
        }
    }
}

/// Parsed RT Dose pixel volume after applying Dose Grid Scaling.
public struct DicomRTDoseVolume: Equatable, Sendable {
    public static let storageSOPClassUID = "1.2.840.10008.5.1.4.1.1.481.2"

    public let sopInstanceUID: String?
    public let doseUnits: String?
    public let doseType: String?
    public let doseSummationType: String?
    public let doseGridScaling: Double
    public let frameOfReferenceUID: String?
    public let rows: Int
    public let columns: Int
    public let frames: Int
    public let pixelSpacing: SIMD2<Double>?
    public let imagePositionPatient: SIMD3<Double>?
    public let imageOrientationPatient: DicomPlaneOrientation?
    public let gridFrameOffsetVector: [Double]
    public let sliceThickness: Double?
    public let storedValues: [UInt32]
    public let doseValues: [Double]

    public let referencedPlans: [DicomRTDoseReferencedPlan]
    public let referencedStructureSet: DicomSOPReference?
    public let referencedTreatmentRecords: [DicomRTDoseReferencedTreatmentRecord]
    public let spatialTransformOfDose: String?
    public let referencedSpatialRegistrations: [DicomSOPReference]
    public let normalizationPoint: SIMD3<Double>?
    public let doseComment: String?
    public let instanceNumber: Int?
    public let pixelRepresentation: Int?
    public let bitsAllocated: Int?
    public let signedStoredValues: [Int32]?
    public let derivationCodes: [DicomCodedConcept]
    public let referencedInstances: [DicomSourceImageReference]
    public let recommendedIsodoseLevels: [DicomRTRecommendedIsodoseLevel]
    public let dvhs: [DicomRTDVH]
    public let dvhNormalizationPoint: SIMD3<Double>?
    public let dvhNormalizationDoseValue: Double?
    public let diagnostics: [DicomRTDoseDiagnostic]

    public var gridFrameOffsets: DicomRTDoseGridFrameOffsets {
        guard frames > 1 else { return .none }
        return gridFrameOffsetVector.first == 0 ? .relative(gridFrameOffsetVector) : .absoluteZ(gridFrameOffsetVector)
    }

    public init(
        sopInstanceUID: String? = nil,
        doseUnits: String? = nil,
        doseType: String? = nil,
        doseSummationType: String? = nil,
        doseGridScaling: Double,
        frameOfReferenceUID: String? = nil,
        rows: Int,
        columns: Int,
        frames: Int,
        pixelSpacing: SIMD2<Double>? = nil,
        imagePositionPatient: SIMD3<Double>? = nil,
        imageOrientationPatient: DicomPlaneOrientation? = nil,
        gridFrameOffsetVector: [Double] = [],
        sliceThickness: Double? = nil,
        storedValues: [UInt32],
        referencedPlans: [DicomRTDoseReferencedPlan] = [],
        referencedStructureSet: DicomSOPReference? = nil,
        referencedTreatmentRecords: [DicomRTDoseReferencedTreatmentRecord] = [],
        spatialTransformOfDose: String? = nil,
        referencedSpatialRegistrations: [DicomSOPReference] = [],
        normalizationPoint: SIMD3<Double>? = nil,
        doseComment: String? = nil,
        instanceNumber: Int? = nil,
        pixelRepresentation: Int? = nil,
        bitsAllocated: Int? = nil,
        signedStoredValues: [Int32]? = nil,
        derivationCodes: [DicomCodedConcept] = [],
        referencedInstances: [DicomSourceImageReference] = [],
        recommendedIsodoseLevels: [DicomRTRecommendedIsodoseLevel] = [],
        dvhs: [DicomRTDVH] = [],
        dvhNormalizationPoint: SIMD3<Double>? = nil,
        dvhNormalizationDoseValue: Double? = nil,
        diagnostics: [DicomRTDoseDiagnostic] = []
    ) {
        self.sopInstanceUID = sopInstanceUID?.dicomRTNonEmptyValue
        self.doseUnits = doseUnits?.dicomRTNonEmptyValue
        self.doseType = doseType?.dicomRTNonEmptyValue
        self.doseSummationType = doseSummationType?.dicomRTNonEmptyValue
        self.doseGridScaling = doseGridScaling
        self.frameOfReferenceUID = frameOfReferenceUID?.dicomRTNonEmptyValue
        self.rows = rows
        self.columns = columns
        self.frames = frames
        self.pixelSpacing = pixelSpacing
        self.imagePositionPatient = imagePositionPatient
        self.imageOrientationPatient = imageOrientationPatient
        self.gridFrameOffsetVector = gridFrameOffsetVector
        self.sliceThickness = sliceThickness
        self.referencedPlans = referencedPlans
        self.referencedStructureSet = referencedStructureSet
        self.referencedTreatmentRecords = referencedTreatmentRecords
        self.spatialTransformOfDose = spatialTransformOfDose
        self.referencedSpatialRegistrations = referencedSpatialRegistrations
        self.normalizationPoint = normalizationPoint
        self.doseComment = doseComment
        self.instanceNumber = instanceNumber
        self.pixelRepresentation = pixelRepresentation
        self.bitsAllocated = bitsAllocated
        self.signedStoredValues = signedStoredValues
        self.derivationCodes = derivationCodes
        self.referencedInstances = referencedInstances
        self.recommendedIsodoseLevels = recommendedIsodoseLevels
        self.dvhs = dvhs
        self.dvhNormalizationPoint = dvhNormalizationPoint
        self.dvhNormalizationDoseValue = dvhNormalizationDoseValue
        self.diagnostics = diagnostics
        self.storedValues = storedValues
        self.doseValues = signedStoredValues?.map { Double($0) * doseGridScaling } ?? storedValues.map { Double($0) * doseGridScaling }
    }
}

/// One RTPLAN control point with beam geometry metadata useful for inspection.
public struct DicomRTControlPoint: Equatable, Sendable {
    public let index: Int
    public let nominalBeamEnergy: Double?
    public let gantryAngle: Double?
    public let beamLimitingDeviceAngle: Double?
    public let patientSupportAngle: Double?
    public let tableTopEccentricAngle: Double?
    public let isocenterPosition: SIMD3<Double>?
    public let cumulativeMetersetWeight: Double?

    public var referencedDoses: [DicomSOPReference]
    public var gantryRotationDirection: String?
    public var beamLimitingDeviceRotationDirection: String?
    public var patientSupportRotationDirection: String?
    public var tableTopEccentricRotationDirection: String?
    public var gantryPitchAngle: Double?
    public var gantryPitchRotationDirection: String?
    public var tableTopPitchAngle: Double?
    public var tableTopPitchRotationDirection: String?
    public var tableTopRollAngle: Double?
    public var tableTopRollRotationDirection: String?
    public var tableTopVerticalPosition: Double?
    public var tableTopLongitudinalPosition: Double?
    public var tableTopLateralPosition: Double?
    public var sourceToSurfaceDistance: Double?
    public var doseRateSet: Double?
    public var beamLimitingDevicePositions: [DicomRTBeamLimitingDevicePosition]
    public var wedgePositions: [DicomRTWedgePosition]
    public var referencedDoseReferences: [DicomRTControlPointDoseReference]

    public init(
        index: Int,
        nominalBeamEnergy: Double? = nil,
        gantryAngle: Double? = nil,
        beamLimitingDeviceAngle: Double? = nil,
        patientSupportAngle: Double? = nil,
        tableTopEccentricAngle: Double? = nil,
        isocenterPosition: SIMD3<Double>? = nil,
        cumulativeMetersetWeight: Double? = nil,
        referencedDoses: [DicomSOPReference] = [],
        gantryRotationDirection: String? = nil,
        beamLimitingDeviceRotationDirection: String? = nil,
        patientSupportRotationDirection: String? = nil,
        tableTopEccentricRotationDirection: String? = nil,
        gantryPitchAngle: Double? = nil,
        gantryPitchRotationDirection: String? = nil,
        tableTopPitchAngle: Double? = nil,
        tableTopPitchRotationDirection: String? = nil,
        tableTopRollAngle: Double? = nil,
        tableTopRollRotationDirection: String? = nil,
        tableTopVerticalPosition: Double? = nil,
        tableTopLongitudinalPosition: Double? = nil,
        tableTopLateralPosition: Double? = nil,
        sourceToSurfaceDistance: Double? = nil,
        doseRateSet: Double? = nil,
        beamLimitingDevicePositions: [DicomRTBeamLimitingDevicePosition] = [],
        wedgePositions: [DicomRTWedgePosition] = [],
        referencedDoseReferences: [DicomRTControlPointDoseReference] = []
    ) {
        self.referencedDoses = referencedDoses
        self.gantryRotationDirection = gantryRotationDirection
        self.beamLimitingDeviceRotationDirection = beamLimitingDeviceRotationDirection
        self.patientSupportRotationDirection = patientSupportRotationDirection
        self.tableTopEccentricRotationDirection = tableTopEccentricRotationDirection
        self.gantryPitchAngle = gantryPitchAngle
        self.gantryPitchRotationDirection = gantryPitchRotationDirection
        self.tableTopPitchAngle = tableTopPitchAngle
        self.tableTopPitchRotationDirection = tableTopPitchRotationDirection
        self.tableTopRollAngle = tableTopRollAngle
        self.tableTopRollRotationDirection = tableTopRollRotationDirection
        self.tableTopVerticalPosition = tableTopVerticalPosition
        self.tableTopLongitudinalPosition = tableTopLongitudinalPosition
        self.tableTopLateralPosition = tableTopLateralPosition
        self.sourceToSurfaceDistance = sourceToSurfaceDistance
        self.doseRateSet = doseRateSet
        self.beamLimitingDevicePositions = beamLimitingDevicePositions
        self.wedgePositions = wedgePositions
        self.referencedDoseReferences = referencedDoseReferences
        self.index = index
        self.nominalBeamEnergy = nominalBeamEnergy
        self.gantryAngle = gantryAngle
        self.beamLimitingDeviceAngle = beamLimitingDeviceAngle
        self.patientSupportAngle = patientSupportAngle
        self.tableTopEccentricAngle = tableTopEccentricAngle
        self.isocenterPosition = isocenterPosition
        self.cumulativeMetersetWeight = cumulativeMetersetWeight
    }
}

/// One RTPLAN beam with delivery metadata and control points.
public struct DicomRTBeam: Equatable, Sendable {
    public let number: Int
    public let name: String?
    public let description: String?
    public let type: String?
    public let radiationType: String?
    public let treatmentMachineName: String?
    public let primaryDosimeterUnit: String?
    public let sourceAxisDistance: Double?
    public let numberOfControlPoints: Int?
    public let controlPoints: [DicomRTControlPoint]
    public let controlPointSequenceItemCount: Int
    public let referenceImageReferences: [DicomSourceImageReference]

    public var referenceImageNumbers: [Int]
    public var highDoseTechniqueType: String?
    public var treatmentDeliveryType: String?
    public var referencedPatientSetupNumber: Int?
    public var referencedToleranceTableNumber: Int?
    public var numberOfWedges: Int?
    public var numberOfCompensators: Int?
    public var numberOfBoli: Int?
    public var numberOfBlocks: Int?
    public var beamLimitingDevices: [DicomRTBeamLimitingDevice]
    public var finalCumulativeMetersetWeight: Double?
    public var referencedDoseReferences: [DicomRTBeamDoseReference]
    public var wedges: [DicomRTWedge]

    public init(
        number: Int,
        name: String? = nil,
        description: String? = nil,
        type: String? = nil,
        radiationType: String? = nil,
        treatmentMachineName: String? = nil,
        primaryDosimeterUnit: String? = nil,
        sourceAxisDistance: Double? = nil,
        numberOfControlPoints: Int? = nil,
        controlPoints: [DicomRTControlPoint] = [],
        controlPointSequenceItemCount: Int? = nil,
        referenceImageReferences: [DicomSourceImageReference] = [],
        referenceImageNumbers: [Int] = [],
        highDoseTechniqueType: String? = nil,
        treatmentDeliveryType: String? = nil,
        referencedPatientSetupNumber: Int? = nil,
        referencedToleranceTableNumber: Int? = nil,
        numberOfWedges: Int? = nil,
        numberOfCompensators: Int? = nil,
        numberOfBoli: Int? = nil,
        numberOfBlocks: Int? = nil,
        beamLimitingDevices: [DicomRTBeamLimitingDevice] = [],
        finalCumulativeMetersetWeight: Double? = nil,
        referencedDoseReferences: [DicomRTBeamDoseReference] = [],
        wedges: [DicomRTWedge] = []
    ) {
        self.referenceImageNumbers = referenceImageNumbers
        self.highDoseTechniqueType = highDoseTechniqueType
        self.treatmentDeliveryType = treatmentDeliveryType
        self.referencedPatientSetupNumber = referencedPatientSetupNumber
        self.referencedToleranceTableNumber = referencedToleranceTableNumber
        self.numberOfWedges = numberOfWedges
        self.numberOfCompensators = numberOfCompensators
        self.numberOfBoli = numberOfBoli
        self.numberOfBlocks = numberOfBlocks
        self.beamLimitingDevices = beamLimitingDevices
        self.finalCumulativeMetersetWeight = finalCumulativeMetersetWeight
        self.referencedDoseReferences = referencedDoseReferences
        self.wedges = wedges
        self.number = number
        self.name = name?.dicomRTNonEmptyValue
        self.description = description?.dicomRTNonEmptyValue
        self.type = type?.dicomRTNonEmptyValue
        self.radiationType = radiationType?.dicomRTNonEmptyValue
        self.treatmentMachineName = treatmentMachineName?.dicomRTNonEmptyValue
        self.primaryDosimeterUnit = primaryDosimeterUnit?.dicomRTNonEmptyValue
        self.sourceAxisDistance = sourceAxisDistance
        self.numberOfControlPoints = numberOfControlPoints
        self.controlPoints = controlPoints
        self.controlPointSequenceItemCount = controlPointSequenceItemCount ?? controlPoints.count
        self.referenceImageReferences = referenceImageReferences
    }
}

/// Parsed RT Plan object for inspection workflows.
public struct DicomRTPlan: Equatable, Sendable {
    public struct ObjectReference: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            case structureSet
            case dose
            case plan
        }

        public let kind: Kind
        public let sopClassUID: String?
        public let sopInstanceUID: String?
        public let relationship: String?

        public init(
            kind: Kind,
            sopClassUID: String? = nil,
            sopInstanceUID: String? = nil,
            relationship: String? = nil
        ) {
            self.kind = kind
            self.sopClassUID = sopClassUID?.dicomRTNonEmptyValue
            self.sopInstanceUID = sopInstanceUID?.dicomRTNonEmptyValue
            self.relationship = relationship?.dicomRTNonEmptyValue
        }
    }

    public static let storageSOPClassUID = "1.2.840.10008.5.1.4.1.1.481.5"

    public let sopInstanceUID: String?
    public let label: String?
    public let name: String?
    public let description: String?
    public let geometry: String?
    public let beams: [DicomRTBeam]
    public let beamSequenceItemCount: Int
    public let objectReferences: [ObjectReference]
    public let setupImageReferences: [DicomSourceImageReference]

    public var doseReferences: [DicomRTDoseReference]
    public var fractionGroups: [DicomRTFractionGroup]
    public var patientSetups: [DicomRTPatientSetup]
    public var toleranceTables: [DicomRTToleranceTable]
    public var rtPlanDate: String?
    public var rtPlanTime: String?
    public var approvalStatus: String?
    public var reviewDate: String?
    public var reviewTime: String?
    public var reviewerName: String?

    public init(
        sopInstanceUID: String? = nil,
        label: String? = nil,
        name: String? = nil,
        description: String? = nil,
        geometry: String? = nil,
        beams: [DicomRTBeam],
        beamSequenceItemCount: Int? = nil,
        objectReferences: [ObjectReference] = [],
        setupImageReferences: [DicomSourceImageReference] = [],
        doseReferences: [DicomRTDoseReference] = [],
        fractionGroups: [DicomRTFractionGroup] = [],
        patientSetups: [DicomRTPatientSetup] = [],
        toleranceTables: [DicomRTToleranceTable] = [],
        rtPlanDate: String? = nil,
        rtPlanTime: String? = nil,
        approvalStatus: String? = nil,
        reviewDate: String? = nil,
        reviewTime: String? = nil,
        reviewerName: String? = nil
    ) {
        self.doseReferences = doseReferences
        self.fractionGroups = fractionGroups
        self.patientSetups = patientSetups
        self.toleranceTables = toleranceTables
        self.rtPlanDate = rtPlanDate
        self.rtPlanTime = rtPlanTime
        self.approvalStatus = approvalStatus
        self.reviewDate = reviewDate
        self.reviewTime = reviewTime
        self.reviewerName = reviewerName
        self.sopInstanceUID = sopInstanceUID?.dicomRTNonEmptyValue
        self.label = label?.dicomRTNonEmptyValue
        self.name = name?.dicomRTNonEmptyValue
        self.description = description?.dicomRTNonEmptyValue
        self.geometry = geometry?.dicomRTNonEmptyValue
        self.beams = beams
        self.beamSequenceItemCount = beamSequenceItemCount ?? beams.count
        self.objectReferences = objectReferences
        self.setupImageReferences = setupImageReferences
    }
}

extension DCMDecoder {
    public var rtStructureSet: DicomRTStructureSet? {
        synchronized {
            DicomRTObjectParser.makeStructureSet(from: self)
        }
    }

    public var rtDose: DicomRTDoseVolume? {
        synchronized {
            DicomRTObjectParser.makeDoseVolume(from: self)
        }
    }

    public var rtPlan: DicomRTPlan? {
        synchronized {
            DicomRTObjectParser.makePlan(from: self)
        }
    }
}

private enum DicomRTObjectParser {
    static func makeStructureSet(from decoder: DCMDecoder) -> DicomRTStructureSet? {
        guard matches(decoder, sopClassUID: DicomRTStructureSet.storageSOPClassUID, modality: "RTSTRUCT") else {
            return nil
        }

        let observations = parseItems(in: decoder, for: .rtROIObservationsSequence).compactMap {
            observation(from: $0.dataSet)
        }

        let rois = parseItems(in: decoder, for: .structureSetROISequence).compactMap { item in
            roi(from: item.dataSet, observation: observations.last {
                $0.referencedROINumber == item.dataSet.int(for: .roiNumber)
            })
        }
        let roiContours = parseItems(in: decoder, for: .roiContourSequence).compactMap {
            roiContour(from: $0.dataSet)
        }

        guard !rois.isEmpty || !roiContours.isEmpty else { return nil }
        return DicomRTStructureSet(
            sopInstanceUID: decoder.info(for: .sopInstanceUID),
            label: decoder.info(for: .structureSetLabel),
            name: decoder.info(for: .structureSetName),
            description: decoder.info(for: .structureSetDescription),
            referencedSeriesInstanceUIDs: referencedSeriesInstanceUIDs(from: decoder.dataSet),
            rois: rois,
            roiContours: roiContours,
            structureSetDate: decoder.info(for: 0x30060008),
            structureSetTime: decoder.info(for: 0x30060009),
            referencedFramesOfReference: DicomRTStructureSetBuilder.frames(from: decoder.dataSet),
            observations: observations
        )
    }

    static func makeDoseVolume(from decoder: DCMDecoder) -> DicomRTDoseVolume? {
        guard matches(decoder, sopClassUID: DicomRTDoseVolume.storageSOPClassUID, modality: "RTDOSE") else {
            return nil
        }

        let dataSet = decoder.dataSet
        let hasPixels = dataSet.contains(0x7FE00010)
        let rows = hasPixels ? decoder.height : 0
        let columns = hasPixels ? decoder.width : 0
        let frames = hasPixels ? max(1, decoder.nImages) : 0
        let bitsAllocated = decoder.intValue(for: .bitsAllocated) ?? decoder.bitDepth
        var diagnostics: [DicomRTDoseDiagnostic] = []
        let dvhItems = dataSet.sequenceItems(for: 0x30040050)
        let dvhs = dvhItems.enumerated().compactMap {
            DicomRTDVH.parse($0.element.dataSet, index: $0.offset, diagnostics: &diagnostics)
        }
        var storedValues: [UInt32] = []
        if hasPixels {
            guard rows > 0, columns > 0 else { return nil }
            let (planeCount, planeOverflow) = rows.multipliedReportingOverflow(by: columns)
            let (pixelCount, volumeOverflow) = planeCount.multipliedReportingOverflow(by: frames)
            guard !planeOverflow, !volumeOverflow, pixelCount > 0,
                  let values = storedDoseValues(decoder: decoder, count: pixelCount, bitsAllocated: bitsAllocated) else { return nil }
            storedValues = values
        } else if dvhItems.isEmpty {
            return nil
        }
        let representation = dataSet.int(for: .pixelRepresentation)
        let signed: [Int32]? = representation == 1 && hasPixels ? storedValues.map {
            bitsAllocated == 16 ? Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: $0))) : Int32(bitPattern: $0)
        } : nil
        if representation == 1 && decoder.info(for: .doseType).dicomRTTrimmedValue != "ERROR" {
            diagnostics.append(.init(code: .signedNonErrorDose))
        }
        let offsets = dataSet.decimalStrings(for: .gridFrameOffsetVector)
        let planeOrientation = orientation(from: dataSet.decimalStrings(for: .imageOrientationPatient))
        if frames > 1 {
            if offsets.count != frames { diagnostics.append(.init(code: .offsetsCountMismatch)) }
            let grid: DicomRTDoseGridFrameOffsets = offsets.first == 0 ? .relative(offsets) : .absoluteZ(offsets)
            if !grid.isMonotonic { diagnostics.append(.init(code: .nonMonotonicOffsets)) }
            if !offsets.isEmpty && offsets.first != 0 && (planeOrientation.map { !DicomRTDoseGridFrameOffsets.isTransverse($0) } ?? true) {
                diagnostics.append(.init(code: .absoluteZNonTransverseOrientation))
            }
        }
        let spacing = dataSet.decimalStrings(for: .pixelSpacing)
        let pixelSpacing = spacing.count >= 2 ? SIMD2<Double>(spacing[0], spacing[1]) : nil
        return DicomRTDoseVolume(
            sopInstanceUID: decoder.info(for: .sopInstanceUID),
            doseUnits: decoder.info(for: .doseUnits),
            doseType: decoder.info(for: .doseType),
            doseSummationType: decoder.info(for: .doseSummationType),
            doseGridScaling: dataSet.decimalString(for: .doseGridScaling) ?? 1,
            frameOfReferenceUID: decoder.info(for: .frameOfReferenceUID),
            rows: rows,
            columns: columns,
            frames: frames,
            pixelSpacing: pixelSpacing,
            imagePositionPatient: vector3(from: dataSet.decimalStrings(for: .imagePositionPatient)),
            imageOrientationPatient: orientation(from: dataSet.decimalStrings(for: .imageOrientationPatient)),
            gridFrameOffsetVector: dataSet.decimalStrings(for: .gridFrameOffsetVector),
            sliceThickness: dataSet.decimalString(for: .sliceThickness),
            storedValues: storedValues,
            referencedPlans: dataSet.sequenceItems(for: 0x300C0002).compactMap { .init(data: $0.dataSet) },
            referencedStructureSet: dataSet.sequenceItems(for: 0x300C0060).first.flatMap { .init(data: $0.dataSet) },
            referencedTreatmentRecords: dataSet.sequenceItems(for: 0x30080030).compactMap { .init(data: $0.dataSet) },
            spatialTransformOfDose: dataSet.string(for: 0x30040005)?.dicomRTNonEmptyValue,
            referencedSpatialRegistrations: dataSet.sequenceItems(for: 0x00700404).compactMap { .init(data: $0.dataSet) },
            normalizationPoint: vector3(from: dataSet.decimalStrings(for: 0x30040008)),
            doseComment: dataSet.string(for: 0x30040006)?.dicomRTNonEmptyValue,
            instanceNumber: dataSet.int(for: 0x00200013),
            pixelRepresentation: representation,
            bitsAllocated: hasPixels ? bitsAllocated : nil,
            signedStoredValues: signed,
            derivationCodes: dataSet.sequenceItems(for: 0x00089215).compactMap {
                DicomRTStructureSetBuilder.code(in: DicomDataSet(elements: [DicomRTValueCoding.sequence(0x00089215, [$0.dataSet])]), tag: 0x00089215)
            },
            referencedInstances: dataSet.sequenceItems(for: 0x0008114A).map { DicomRTValueCoding.readSourceReference($0.dataSet) },
            recommendedIsodoseLevels: dataSet.sequenceItems(for: 0x30040016).compactMap { .init(data: $0.dataSet) },
            dvhs: dvhs,
            dvhNormalizationPoint: vector3(from: dataSet.decimalStrings(for: 0x30040040)),
            dvhNormalizationDoseValue: dataSet.decimalString(for: 0x30040042),
            diagnostics: diagnostics
        )
    }

    static func makePlan(from decoder: DCMDecoder) -> DicomRTPlan? {
        guard matches(decoder, sopClassUID: DicomRTPlan.storageSOPClassUID, modality: "RTPLAN") else {
            return nil
        }

        let beamItems = parseItems(in: decoder, for: .beamSequence)
        let beams = beamItems.compactMap { beam(from: $0.dataSet) }
        let objectReferences = objectReferences(in: decoder)
        let setupImageReferences = parseItems(in: decoder, for: .patientSetupSequence).flatMap { setup in
            setup.dataSet.sequenceItems(for: .referencedSetupImageSequence).map(sourceImageReference)
        }
        return DicomRTPlan(
            sopInstanceUID: decoder.info(for: .sopInstanceUID),
            label: decoder.info(for: .rtPlanLabel),
            name: decoder.info(for: .rtPlanName),
            description: decoder.info(for: .rtPlanDescription),
            geometry: decoder.info(for: .rtPlanGeometry),
            beams: beams,
            beamSequenceItemCount: beamItems.count,
            objectReferences: objectReferences,
            setupImageReferences: setupImageReferences,
            doseReferences: decoder.dataSet.sequenceItems(for: 0x300A0010).compactMap { DicomRTDoseReference(data: $0.dataSet) },
            fractionGroups: decoder.dataSet.sequenceItems(for: 0x300A0070).compactMap { DicomRTFractionGroup(data: $0.dataSet) },
            patientSetups: decoder.dataSet.sequenceItems(for: 0x300A0180).compactMap { DicomRTPatientSetup(data: $0.dataSet) },
            toleranceTables: decoder.dataSet.sequenceItems(for: 0x300A0040).compactMap { DicomRTToleranceTable(data: $0.dataSet) },
            rtPlanDate: decoder.dataSet.string(for: 0x300A0006)?.dicomRTNonEmptyValue,
            rtPlanTime: decoder.dataSet.string(for: 0x300A0007)?.dicomRTNonEmptyValue,
            approvalStatus: decoder.dataSet.string(for: 0x300E0002)?.dicomRTNonEmptyValue,
            reviewDate: decoder.dataSet.string(for: 0x300E0004)?.dicomRTNonEmptyValue,
            reviewTime: decoder.dataSet.string(for: 0x300E0005)?.dicomRTNonEmptyValue,
            reviewerName: decoder.dataSet.string(for: 0x300E0008)?.dicomRTNonEmptyValue
        )
    }

    private static func objectReferences(in decoder: DCMDecoder) -> [DicomRTPlan.ObjectReference] {
        let groups: [(DicomTag, DicomRTPlan.ObjectReference.Kind)] = [
            (.referencedStructureSetSequence, .structureSet),
            (.referencedDoseSequence, .dose),
            (.referencedRTPlanSequence, .plan)
        ]
        return groups.flatMap { tag, kind in
            parseItems(in: decoder, for: tag).map { item in
                DicomRTPlan.ObjectReference(
                    kind: kind,
                    sopClassUID: item.dataSet.string(for: .referencedSOPClassUID),
                    sopInstanceUID: item.dataSet.string(for: .referencedSOPInstanceUID),
                    relationship: kind == .plan ? item.dataSet.string(for: .rtPlanRelationship) : nil
                )
            }
        }
    }

    private static func matches(_ decoder: DCMDecoder, sopClassUID: String, modality: String) -> Bool {
        decoder.info(for: .sopClassUID).dicomRTTrimmedValue == sopClassUID ||
            decoder.info(for: .modality).dicomRTTrimmedValue == modality
    }

    private static func referencedSeriesInstanceUIDs(from dataSet: DicomDataSet) -> [String] {
        var seen: Set<String> = []
        return dataSet.sequenceItems(for: .referencedFrameOfReferenceSequence).flatMap { frameReference in
            frameReference.dataSet.sequenceItems(for: .rtReferencedStudySequence).flatMap { studyReference in
                studyReference.dataSet.sequenceItems(for: .rtReferencedSeriesSequence).compactMap { seriesReference in
                    seriesReference.dataSet.string(for: .seriesInstanceUID)?.dicomRTNonEmptyValue
                }
            }
        }.filter { seen.insert($0).inserted }
    }

    private static func roi(from dataSet: DicomDataSet, observation: DicomRTROIObservation?) -> DicomRTROI? {
        guard let number = dataSet.int(for: .roiNumber) else { return nil }
        let name = dataSet.string(for: .roiName) ?? ""
        return DicomRTROI(
            number: number,
            name: name,
            description: dataSet.string(for: .roiDescription),
            referencedFrameOfReferenceUID: dataSet.string(for: .referencedFrameOfReferenceUID),
            generationAlgorithm: dataSet.string(for: .roiGenerationAlgorithm),
            observationLabel: observation?.label,
            interpretedType: observation?.interpretedType,
            interpreter: observation?.interpreter,
            generationDescription: dataSet.string(for: 0x30060038),
            derivationCode: DicomRTStructureSetBuilder.code(in: dataSet, tag: 0x00089215)
        )
    }

    private static func observation(from dataSet: DicomDataSet) -> DicomRTROIObservation? {
        guard let roi = dataSet.int(for: .referencedROINumber),
              let number = dataSet.int(for: .observationNumber) else { return nil }
        return DicomRTROIObservation(
            number: number, referencedROINumber: roi,
            label: dataSet.string(for: .roiObservationLabel)?.dicomRTNonEmptyValue,
            interpretedType: dataSet.string(for: .rtROIInterpretedType)?.dicomRTNonEmptyValue,
            interpreter: dataSet.string(for: .roiInterpreter)?.dicomRTNonEmptyValue,
            identificationCode: DicomRTStructureSetBuilder.code(in: dataSet, tag: 0x30060086),
            therapeuticRoleTypeCode: DicomRTStructureSetBuilder.code(in: dataSet, tag: 0x30100065),
            physicalProperties: dataSet.sequenceItems(for: 0x300600B0).compactMap {
                guard let name = $0.dataSet.string(for: 0x300600B2),
                      let value = $0.dataSet.decimalString(for: 0x300600B4) else { return nil }
                return DicomRTPhysicalProperty(name: name, value: value)
            }
        )
    }

    private static func roiContour(from dataSet: DicomDataSet) -> DicomRTROIContour? {
        guard let referencedROINumber = dataSet.int(for: .referencedROINumber) else { return nil }
        let contours = dataSet.sequenceItems(for: .contourSequence).compactMap {
            contour(from: $0.dataSet)
        }
        return DicomRTROIContour(
            referencedROINumber: referencedROINumber,
            displayColor: dataSet.ints(for: .roiDisplayColor),
            contours: contours,
            sourcePixelPlanes: DicomRTStructureSetBuilder.pixelPlanes(from: dataSet)
        )
    }

    private static func contour(from dataSet: DicomDataSet) -> DicomRTContour? {
        let values = dataSet.decimalStrings(for: .contourData)
        let points = stride(from: 0, to: values.count - values.count % 3, by: 3).map {
            SIMD3<Double>(values[$0], values[$0 + 1], values[$0 + 2])
        }
        guard !points.isEmpty else { return nil }
        if let declaredCount = dataSet.int(for: .numberOfContourPoints),
           declaredCount != points.count {
            return nil
        }

        return DicomRTContour(
            number: dataSet.int(for: .contourNumber),
            geometricType: dataSet.string(for: .contourGeometricType) ?? "UNKNOWN",
            points: points,
            sourceImageReferences: dataSet.sequenceItems(for: .contourImageSequence).map(sourceImageReference)
        )
    }

    private static func beam(from dataSet: DicomDataSet) -> DicomRTBeam? {
        guard let number = dataSet.int(for: .beamNumber) else { return nil }
        let controlPointItems = dataSet.sequenceItems(for: .controlPointSequence)
        return DicomRTBeam(
            number: number,
            name: dataSet.string(for: .beamName),
            description: dataSet.string(for: .beamDescription),
            type: dataSet.string(for: .beamType),
            radiationType: dataSet.string(for: .radiationType),
            treatmentMachineName: dataSet.string(for: .treatmentMachineName),
            primaryDosimeterUnit: dataSet.string(for: .primaryDosimeterUnit),
            sourceAxisDistance: dataSet.decimalString(for: .sourceAxisDistance),
            numberOfControlPoints: dataSet.int(for: .numberOfControlPoints),
            controlPoints: controlPointItems.compactMap {
                controlPoint(from: $0.dataSet)
            },
            controlPointSequenceItemCount: controlPointItems.count,
            referenceImageReferences: dataSet.sequenceItems(for: .referencedReferenceImageSequence).map(
                sourceImageReference
            ),
            referenceImageNumbers: dataSet.sequenceItems(for: 0x300C0042).compactMap { $0.dataSet.int(for: 0x300A00C8) },
            highDoseTechniqueType: dataSet.string(for: 0x300A00C7)?.dicomRTNonEmptyValue,
            treatmentDeliveryType: dataSet.string(for: 0x300A00CE)?.dicomRTNonEmptyValue,
            referencedPatientSetupNumber: dataSet.int(for: 0x300C006A),
            referencedToleranceTableNumber: dataSet.int(for: 0x300C00A0),
            numberOfWedges: dataSet.int(for: 0x300A00D0),
            numberOfCompensators: dataSet.int(for: 0x300A00E0),
            numberOfBoli: dataSet.int(for: 0x300A00ED),
            numberOfBlocks: dataSet.int(for: 0x300A00F0),
            beamLimitingDevices: dataSet.sequenceItems(for: 0x300A00B6).compactMap { DicomRTBeamLimitingDevice(data: $0.dataSet) },
            finalCumulativeMetersetWeight: dataSet.decimalString(for: 0x300A010E),
            referencedDoseReferences: dataSet.sequenceItems(for: 0x300C0050).compactMap { DicomRTBeamDoseReference(data: $0.dataSet) },
            wedges: dataSet.sequenceItems(for: 0x300A00D1).compactMap { DicomRTWedge(data: $0.dataSet) }
        )
    }

    private static func controlPoint(from dataSet: DicomDataSet) -> DicomRTControlPoint? {
        guard let index = dataSet.int(for: .controlPointIndex) else { return nil }
        return DicomRTControlPoint(
            index: index,
            nominalBeamEnergy: dataSet.decimalString(for: .nominalBeamEnergy),
            gantryAngle: dataSet.decimalString(for: .gantryAngle),
            beamLimitingDeviceAngle: dataSet.decimalString(for: .beamLimitingDeviceAngle),
            patientSupportAngle: dataSet.decimalString(for: .patientSupportAngle),
            tableTopEccentricAngle: dataSet.decimalString(for: .tableTopEccentricAngle),
            isocenterPosition: vector3(from: dataSet.decimalStrings(for: .isocenterPosition)),
            cumulativeMetersetWeight: dataSet.decimalString(for: .cumulativeMetersetWeight),
            referencedDoses: dataSet.sequenceItems(for: 0x300C0080).compactMap { .init(data: $0.dataSet) },
            gantryRotationDirection: dataSet.string(for: 0x300A011F)?.dicomRTNonEmptyValue,
            beamLimitingDeviceRotationDirection: dataSet.string(for: 0x300A0121)?.dicomRTNonEmptyValue,
            patientSupportRotationDirection: dataSet.string(for: 0x300A0123)?.dicomRTNonEmptyValue,
            tableTopEccentricRotationDirection: dataSet.string(for: 0x300A0126)?.dicomRTNonEmptyValue,
            gantryPitchAngle: dataSet.float(for: 0x300A014A),
            gantryPitchRotationDirection: dataSet.string(for: 0x300A014C)?.dicomRTNonEmptyValue,
            tableTopPitchAngle: dataSet.float(for: 0x300A0140),
            tableTopPitchRotationDirection: dataSet.string(for: 0x300A0142)?.dicomRTNonEmptyValue,
            tableTopRollAngle: dataSet.float(for: 0x300A0144),
            tableTopRollRotationDirection: dataSet.string(for: 0x300A0146)?.dicomRTNonEmptyValue,
            tableTopVerticalPosition: dataSet.decimalString(for: 0x300A0128),
            tableTopLongitudinalPosition: dataSet.decimalString(for: 0x300A0129),
            tableTopLateralPosition: dataSet.decimalString(for: 0x300A012A),
            sourceToSurfaceDistance: dataSet.decimalString(for: 0x300A0130),
            doseRateSet: dataSet.decimalString(for: 0x300A0115),
            beamLimitingDevicePositions: dataSet.sequenceItems(for: 0x300A011A).compactMap { DicomRTBeamLimitingDevicePosition(data: $0.dataSet) },
            wedgePositions: dataSet.sequenceItems(for: 0x300A0116).compactMap { DicomRTWedgePosition(data: $0.dataSet) },
            referencedDoseReferences: dataSet.sequenceItems(for: 0x300C0050).compactMap { DicomRTControlPointDoseReference(data: $0.dataSet) }
        )
    }

    private static func sourceImageReference(from item: DicomSequenceItem) -> DicomSourceImageReference {
        DicomSourceImageReference(
            referencedSOPClassUID: item.dataSet.string(for: .referencedSOPClassUID),
            referencedSOPInstanceUID: item.dataSet.string(for: .referencedSOPInstanceUID),
            referencedFrameNumbers: item.dataSet.ints(for: .referencedFrameNumber)
        )
    }

    private static func storedDoseValues(
        decoder: DCMDecoder,
        count: Int,
        bitsAllocated: Int
    ) -> [UInt32]? {
        guard !decoder.compressedImage,
              let range = pixelDataRange(in: decoder) else {
            return nil
        }

        switch bitsAllocated {
        case 16:
            let (requiredBytes, overflow) = count.multipliedReportingOverflow(by: 2)
            guard !overflow else { return nil }
            guard requiredBytes <= range.upperBound - range.lowerBound else { return nil }
            return (0..<count).map {
                readUInt16(decoder.dicomData, at: range.lowerBound + $0 * 2, littleEndian: decoder.littleEndian)
            }.map(UInt32.init)
        case 32:
            let (requiredBytes, overflow) = count.multipliedReportingOverflow(by: 4)
            guard !overflow else { return nil }
            guard requiredBytes <= range.upperBound - range.lowerBound else { return nil }
            return (0..<count).map {
                readUInt32(decoder.dicomData, at: range.lowerBound + $0 * 4, littleEndian: decoder.littleEndian)
            }
        default:
            return nil
        }
    }

    private static func pixelDataRange(in decoder: DCMDecoder) -> Range<Int>? {
        if let metadata = decoder.tagMetadataCache[DicomTag.pixelData.rawValue],
           metadata.offset >= 0,
           metadata.elementLength >= 0,
           metadata.offset <= decoder.dicomData.count,
           metadata.offset + metadata.elementLength <= decoder.dicomData.count {
            return metadata.offset..<(metadata.offset + metadata.elementLength)
        }
        guard decoder.offset >= 0,
              decoder.offset < decoder.dicomData.count else {
            return nil
        }
        return decoder.offset..<decoder.dicomData.count
    }

    private static func parseItems(in decoder: DCMDecoder, for tag: DicomTag) -> [DicomSequenceItem] {
        guard let metadata = decoder.tagMetadataCache[tag.rawValue],
              metadata.offset >= 0,
              metadata.elementLength >= 0,
              metadata.offset + metadata.elementLength <= decoder.dicomData.count else {
            return []
        }
        let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID) ?? .explicitVRLittleEndian
        return (try? DicomSequenceValueParser.parseItems(
            in: decoder.dicomData,
            valueOffset: metadata.offset,
            valueLength: metadata.elementLength,
            littleEndian: decoder.littleEndian,
            explicitVR: syntax.isExplicitVR,
            characterSet: decoder.activeCharacterSet
        )) ?? []
    }

    private static func vector3(from values: [Double]) -> SIMD3<Double>? {
        guard values.count >= 3 else { return nil }
        return SIMD3<Double>(values[0], values[1], values[2])
    }

    private static func orientation(from values: [Double]) -> DicomPlaneOrientation? {
        guard values.count >= 6 else { return nil }
        return DicomPlaneOrientation(
            row: SIMD3<Double>(values[0], values[1], values[2]),
            column: SIMD3<Double>(values[3], values[4], values[5])
        )
    }

    private static func readUInt16(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt16 {
        let b0 = UInt16(data[offset])
        let b1 = UInt16(data[offset + 1])
        return littleEndian ? (b1 << 8 | b0) : (b0 << 8 | b1)
    }

    private static func readUInt32(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        if littleEndian {
            return b3 << 24 | b2 << 16 | b1 << 8 | b0
        }
        return b0 << 24 | b1 << 16 | b2 << 8 | b3
    }

}

extension String {
    var dicomRTTrimmedValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    var dicomRTNonEmptyValue: String? {
        let trimmed = dicomRTTrimmedValue
        return trimmed.isEmpty ? nil : trimmed
    }
}
