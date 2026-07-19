import Foundation
import simd

/// One RTSTRUCT contour represented in patient coordinates.
public struct DicomRTContour: Equatable, Sendable {
    public let number: Int?
    public let geometricType: String
    public let points: [SIMD3<Double>]
    public let sourceImageReferences: [DicomSourceImageReference]

    public init(
        number: Int? = nil,
        geometricType: String,
        points: [SIMD3<Double>],
        sourceImageReferences: [DicomSourceImageReference] = []
    ) {
        self.number = number
        self.geometricType = geometricType
        self.points = points
        self.sourceImageReferences = sourceImageReferences
    }
}

/// RTSTRUCT ROI metadata from Structure Set ROI Sequence and ROI observations.
public struct DicomRTROI: Equatable, Sendable {
    public let number: Int
    public let name: String
    public let description: String?
    public let referencedFrameOfReferenceUID: String?
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
        interpreter: String? = nil
    ) {
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

    public init(referencedROINumber: Int, displayColor: [Int] = [], contours: [DicomRTContour]) {
        self.referencedROINumber = referencedROINumber
        self.displayColor = displayColor
        self.contours = contours
    }
}

/// Parsed RT Structure Set object.
public struct DicomRTStructureSet: Equatable, Sendable {
    public static let storageSOPClassUID = "1.2.840.10008.5.1.4.1.1.481.3"

    public let sopInstanceUID: String?
    public let label: String?
    public let name: String?
    public let description: String?
    public let rois: [DicomRTROI]
    public let roiContours: [DicomRTROIContour]

    public init(
        sopInstanceUID: String? = nil,
        label: String? = nil,
        name: String? = nil,
        description: String? = nil,
        rois: [DicomRTROI],
        roiContours: [DicomRTROIContour]
    ) {
        self.sopInstanceUID = sopInstanceUID?.dicomRTNonEmptyValue
        self.label = label?.dicomRTNonEmptyValue
        self.name = name?.dicomRTNonEmptyValue
        self.description = description?.dicomRTNonEmptyValue
        self.rois = rois
        self.roiContours = roiContours
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
    public let storedValues: [UInt32]
    public let doseValues: [Double]

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
        storedValues: [UInt32]
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
        self.storedValues = storedValues
        self.doseValues = storedValues.map { Double($0) * doseGridScaling }
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

    public init(
        index: Int,
        nominalBeamEnergy: Double? = nil,
        gantryAngle: Double? = nil,
        beamLimitingDeviceAngle: Double? = nil,
        patientSupportAngle: Double? = nil,
        tableTopEccentricAngle: Double? = nil,
        isocenterPosition: SIMD3<Double>? = nil,
        cumulativeMetersetWeight: Double? = nil
    ) {
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
        controlPoints: [DicomRTControlPoint] = []
    ) {
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
    }
}

/// Parsed RT Plan object for inspection workflows.
public struct DicomRTPlan: Equatable, Sendable {
    public static let storageSOPClassUID = "1.2.840.10008.5.1.4.1.1.481.5"

    public let sopInstanceUID: String?
    public let label: String?
    public let name: String?
    public let description: String?
    public let geometry: String?
    public let beams: [DicomRTBeam]

    public init(
        sopInstanceUID: String? = nil,
        label: String? = nil,
        name: String? = nil,
        description: String? = nil,
        geometry: String? = nil,
        beams: [DicomRTBeam]
    ) {
        self.sopInstanceUID = sopInstanceUID?.dicomRTNonEmptyValue
        self.label = label?.dicomRTNonEmptyValue
        self.name = name?.dicomRTNonEmptyValue
        self.description = description?.dicomRTNonEmptyValue
        self.geometry = geometry?.dicomRTNonEmptyValue
        self.beams = beams
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
        }.reduce(into: [Int: ROIObservation]()) { result, observation in
            result[observation.referencedROINumber] = observation
        }

        let rois = parseItems(in: decoder, for: .structureSetROISequence).compactMap {
            roi(from: $0.dataSet, observation: observations[$0.dataSet.int(for: .roiNumber) ?? -1])
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
            rois: rois,
            roiContours: roiContours
        )
    }

    static func makeDoseVolume(from decoder: DCMDecoder) -> DicomRTDoseVolume? {
        guard matches(decoder, sopClassUID: DicomRTDoseVolume.storageSOPClassUID, modality: "RTDOSE") else {
            return nil
        }

        let dataSet = decoder.dataSet
        let rows = decoder.height
        let columns = decoder.width
        let frames = max(1, decoder.nImages)
        let bitsAllocated = decoder.intValue(for: .bitsAllocated) ?? decoder.bitDepth
        let pixelCount = rows * columns * frames
        guard rows > 0, columns > 0, frames > 0, pixelCount > 0 else { return nil }
        guard let storedValues = storedDoseValues(
            decoder: decoder,
            count: pixelCount,
            bitsAllocated: bitsAllocated
        ) else {
            return nil
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
            storedValues: storedValues
        )
    }

    static func makePlan(from decoder: DCMDecoder) -> DicomRTPlan? {
        guard matches(decoder, sopClassUID: DicomRTPlan.storageSOPClassUID, modality: "RTPLAN") else {
            return nil
        }

        let beams = parseItems(in: decoder, for: .beamSequence).compactMap { beam(from: $0.dataSet) }
        guard !beams.isEmpty ||
              !decoder.info(for: .rtPlanLabel).dicomRTTrimmedValue.isEmpty else {
            return nil
        }
        return DicomRTPlan(
            sopInstanceUID: decoder.info(for: .sopInstanceUID),
            label: decoder.info(for: .rtPlanLabel),
            name: decoder.info(for: .rtPlanName),
            description: decoder.info(for: .rtPlanDescription),
            geometry: decoder.info(for: .rtPlanGeometry),
            beams: beams
        )
    }

    private static func matches(_ decoder: DCMDecoder, sopClassUID: String, modality: String) -> Bool {
        decoder.info(for: .sopClassUID).dicomRTTrimmedValue == sopClassUID ||
            decoder.info(for: .modality).dicomRTTrimmedValue == modality
    }

    private static func roi(from dataSet: DicomDataSet, observation: ROIObservation?) -> DicomRTROI? {
        guard let number = dataSet.int(for: .roiNumber),
              let name = dataSet.string(for: .roiName)?.dicomRTNonEmptyValue else {
            return nil
        }
        return DicomRTROI(
            number: number,
            name: name,
            description: dataSet.string(for: .roiDescription),
            referencedFrameOfReferenceUID: dataSet.string(for: .referencedFrameOfReferenceUID),
            generationAlgorithm: dataSet.string(for: .roiGenerationAlgorithm),
            observationLabel: observation?.label,
            interpretedType: observation?.interpretedType,
            interpreter: observation?.interpreter
        )
    }

    private static func observation(from dataSet: DicomDataSet) -> ROIObservation? {
        guard let referencedROINumber = dataSet.int(for: .referencedROINumber) else { return nil }
        return ROIObservation(
            referencedROINumber: referencedROINumber,
            label: dataSet.string(for: .roiObservationLabel),
            interpretedType: dataSet.string(for: .rtROIInterpretedType),
            interpreter: dataSet.string(for: .roiInterpreter)
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
            contours: contours
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
            controlPoints: dataSet.sequenceItems(for: .controlPointSequence).compactMap {
                controlPoint(from: $0.dataSet)
            }
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
            cumulativeMetersetWeight: dataSet.decimalString(for: .cumulativeMetersetWeight)
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
            let requiredBytes = count * 2
            guard range.lowerBound + requiredBytes <= range.upperBound else { return nil }
            return (0..<count).map {
                readUInt16(decoder.dicomData, at: range.lowerBound + $0 * 2, littleEndian: decoder.littleEndian)
            }.map(UInt32.init)
        case 32:
            let requiredBytes = count * 4
            guard range.lowerBound + requiredBytes <= range.upperBound else { return nil }
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

    private struct ROIObservation {
        let referencedROINumber: Int
        let label: String?
        let interpretedType: String?
        let interpreter: String?
    }
}

private extension String {
    var dicomRTTrimmedValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    var dicomRTNonEmptyValue: String? {
        let trimmed = dicomRTTrimmedValue
        return trimmed.isEmpty ? nil : trimmed
    }
}
