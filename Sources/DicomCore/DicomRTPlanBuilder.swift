import Foundation

/// Builds the modelled external-beam RT Plan modules. Brachy application content remains raw-only.
public enum DicomRTPlanBuilder {
    public enum BuildError: Error, Equatable, Sendable {
        case unsupported
        case invalidLeafJawPositions
    }

    public static func dataSet(
        from plan: DicomRTPlan,
        studyInstanceUID: String,
        seriesInstanceUID: String,
        sopInstanceUID: String? = nil,
        options: DicomRTStructureSetBuildOptions = .init()
    ) throws -> DicomDataSet {
        guard !plan.fractionGroups.contains(where: {
            $0.numberOfBrachyApplicationSetups != 0 || !$0.referencedBrachyApplicationSetups.isEmpty
        }), !plan.beams.contains(where: {
            ($0.numberOfCompensators ?? 0) != 0 || ($0.numberOfBoli ?? 0) != 0 || ($0.numberOfBlocks ?? 0) != 0
        }) else { throw BuildError.unsupported }
        for beam in plan.beams {
            for point in beam.controlPoints {
                for position in point.beamLimitingDevicePositions {
                    let values = position.leafJawPositions
                    guard !values.isEmpty, values.count.isMultiple(of: 2), values.allSatisfy(\.isFinite) else {
                        throw BuildError.invalidLeafJawPositions
                    }
                    if let device = beam.beamLimitingDevices.first(where: { $0.type == position.type }),
                       values.count / 2 != device.numberOfLeafJawPairs {
                        throw BuildError.invalidLeafJawPositions
                    }
                }
            }
        }
        var data = DicomRTValueCoding.common(sopClass: DicomRTPlan.storageSOPClassUID,
            sopInstance: sopInstanceUID ?? plan.sopInstanceUID ?? DicomDataSetWriter.makeUID(),
            study: studyInstanceUID, series: seriesInstanceUID, modality: "RTPLAN", options: options)
        for element in plan.dataSet.elements { data = data.setting(element) }
        return data
    }
}

/// Shared primitive encoding for the RT Plan and Dose modules.
enum DicomRTValueCoding {
    static func text(_ tag: Int, _ vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomRTStructureSetBuilder.text(tag, vr, value)
    }

    static func decimals(_ tag: Int, _ values: [Double]) -> DicomDataElement {
        DicomRTStructureSetBuilder.decimals(tag, values)
    }

    static func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        DicomRTStructureSetBuilder.sequence(tag, items)
    }

    static func vector(_ values: [Double]) -> SIMD3<Double>? {
        guard values.count == 3 else { return nil }
        return SIMD3(values[0], values[1], values[2])
    }

    static func sourceReference(_ reference: DicomSourceImageReference) -> DicomDataSet {
        var data = DicomRTStructureSetBuilder.reference(reference)
        if let code = reference.purposeOfReferenceCode {
            data = data.setting(sequence(0x0040A170, [DicomRTStructureSetBuilder.codeDataSet(code)]))
        }
        return data
    }

    static func readSourceReference(_ data: DicomDataSet) -> DicomSourceImageReference {
        DicomSourceImageReference(referencedSOPClassUID: data.string(for: 0x00081150),
            referencedSOPInstanceUID: data.string(for: 0x00081155), referencedFrameNumbers: data.ints(for: 0x00081160),
            purposeOfReferenceCode: DicomRTStructureSetBuilder.code(in: data, tag: 0x0040A170))
    }

    static func common(sopClass: String, sopInstance: String, study: String, series: String,
                       modality: String, options: DicomRTStructureSetBuildOptions) -> DicomDataSet {
        DicomDataSet(elements: [
            text(0x00080016, .UI, sopClass), text(0x00080018, .UI, sopInstance),
            text(0x0020000D, .UI, study), text(0x0020000E, .UI, series), text(0x00080060, .CS, modality),
            text(0x00100010, .PN, options.patientName), text(0x00100020, .LO, options.patientID),
            text(0x00100030, .DA, options.patientBirthDate), text(0x00100040, .CS, options.patientSex),
            text(0x00080020, .DA, options.studyDate), text(0x00080030, .TM, options.studyTime),
            text(0x00080090, .PN, options.referringPhysicianName), text(0x00200010, .SH, options.studyID),
            text(0x00080050, .SH, options.accessionNumber), text(0x00200011, .IS, String(options.seriesNumber)),
            text(0x00080070, .LO, options.manufacturer), text(0x00081070, .PN, options.operatorsName)
        ])
    }
}

extension DicomRTControlPoint {
    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300A0112, .IS, String(index)))
        if let value = nominalBeamEnergy { elements.append(DicomRTValueCoding.decimals(0x300A0114, [value])) }
        if let value = gantryAngle { elements.append(DicomRTValueCoding.decimals(0x300A011E, [value])) }
        if let value = beamLimitingDeviceAngle { elements.append(DicomRTValueCoding.decimals(0x300A0120, [value])) }
        if let value = patientSupportAngle { elements.append(DicomRTValueCoding.decimals(0x300A0122, [value])) }
        if let value = tableTopEccentricAngle { elements.append(DicomRTValueCoding.decimals(0x300A0125, [value])) }
        if let value = isocenterPosition { elements.append(DicomRTValueCoding.decimals(0x300A012C, [value.x, value.y, value.z])) }
        if let value = cumulativeMetersetWeight { elements.append(DicomRTValueCoding.decimals(0x300A0134, [value])) }
        if let value = gantryRotationDirection { elements.append(DicomRTValueCoding.text(0x300A011F, .CS, value)) }
        if let value = beamLimitingDeviceRotationDirection { elements.append(DicomRTValueCoding.text(0x300A0121, .CS, value)) }
        if let value = patientSupportRotationDirection { elements.append(DicomRTValueCoding.text(0x300A0123, .CS, value)) }
        if let value = tableTopEccentricRotationDirection { elements.append(DicomRTValueCoding.text(0x300A0126, .CS, value)) }
        if let value = gantryPitchAngle { elements.append(DicomDataElement(tag: 0x300A014A, vr: .FL, value: .floats([value]))) }
        if let value = gantryPitchRotationDirection { elements.append(DicomRTValueCoding.text(0x300A014C, .CS, value)) }
        if let value = tableTopPitchAngle { elements.append(DicomDataElement(tag: 0x300A0140, vr: .FL, value: .floats([value]))) }
        if let value = tableTopPitchRotationDirection { elements.append(DicomRTValueCoding.text(0x300A0142, .CS, value)) }
        if let value = tableTopRollAngle { elements.append(DicomDataElement(tag: 0x300A0144, vr: .FL, value: .floats([value]))) }
        if let value = tableTopRollRotationDirection { elements.append(DicomRTValueCoding.text(0x300A0146, .CS, value)) }
        if let value = tableTopVerticalPosition { elements.append(DicomRTValueCoding.decimals(0x300A0128, [value])) }
        if let value = tableTopLongitudinalPosition { elements.append(DicomRTValueCoding.decimals(0x300A0129, [value])) }
        if let value = tableTopLateralPosition { elements.append(DicomRTValueCoding.decimals(0x300A012A, [value])) }
        if let value = sourceToSurfaceDistance { elements.append(DicomRTValueCoding.decimals(0x300A0130, [value])) }
        if let value = doseRateSet { elements.append(DicomRTValueCoding.decimals(0x300A0115, [value])) }
        if !beamLimitingDevicePositions.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300A011A, beamLimitingDevicePositions.map { $0.dataSet })) }
        if !wedgePositions.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300A0116, wedgePositions.map { $0.dataSet })) }
        if !referencedDoseReferences.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300C0050, referencedDoseReferences.map { $0.dataSet })) }
        if cumulativeMetersetWeight == nil { elements.append(DicomRTValueCoding.text(0x300A0134, .DS, "")) }
        if !referencedDoses.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300C0080, referencedDoses.map { $0.dataSet })) }
        if index == 0 {
            for tag in [0x300A0128, 0x300A0129, 0x300A012A, 0x300A012C] where !elements.contains(where: { $0.tag == tag }) {
                elements.append(DicomRTValueCoding.text(tag, .DS, ""))
            }
        }
        return DicomDataSet(elements: elements)
    }
}

extension DicomRTBeam {
    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x300A00C0, .IS, String(number)))
        if let value = name { elements.append(DicomRTValueCoding.text(0x300A00C2, .LO, value)) }
        if let value = description { elements.append(DicomRTValueCoding.text(0x300A00C3, .ST, value)) }
        if let value = type { elements.append(DicomRTValueCoding.text(0x300A00C4, .CS, value)) }
        if let value = radiationType { elements.append(DicomRTValueCoding.text(0x300A00C6, .CS, value)) }
        if let value = treatmentMachineName { elements.append(DicomRTValueCoding.text(0x300A00B2, .SH, value)) }
        if let value = primaryDosimeterUnit { elements.append(DicomRTValueCoding.text(0x300A00B3, .CS, value)) }
        if let value = sourceAxisDistance { elements.append(DicomRTValueCoding.decimals(0x300A00B4, [value])) }
        if let value = numberOfControlPoints { elements.append(DicomRTValueCoding.text(0x300A0110, .IS, String(value))) }
        if !controlPoints.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300A0111, controlPoints.map { $0.dataSet })) }
        if let value = treatmentDeliveryType { elements.append(DicomRTValueCoding.text(0x300A00CE, .CS, value)) }
        if let value = referencedPatientSetupNumber { elements.append(DicomRTValueCoding.text(0x300C006A, .IS, String(value))) }
        if let value = referencedToleranceTableNumber { elements.append(DicomRTValueCoding.text(0x300C00A0, .IS, String(value))) }
        if let value = numberOfWedges { elements.append(DicomRTValueCoding.text(0x300A00D0, .IS, String(value))) }
        if let value = numberOfCompensators { elements.append(DicomRTValueCoding.text(0x300A00E0, .IS, String(value))) }
        if let value = numberOfBoli { elements.append(DicomRTValueCoding.text(0x300A00ED, .IS, String(value))) }
        if let value = numberOfBlocks { elements.append(DicomRTValueCoding.text(0x300A00F0, .IS, String(value))) }
        if !beamLimitingDevices.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300A00B6, beamLimitingDevices.map { $0.dataSet })) }
        if let value = finalCumulativeMetersetWeight { elements.append(DicomRTValueCoding.decimals(0x300A010E, [value])) }
        if !referencedDoseReferences.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300C0050, referencedDoseReferences.map { $0.dataSet })) }
        if !wedges.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300A00D1, wedges.map { $0.dataSet })) }
        for tag in [0x300A00B2, 0x300A00C6] where !elements.contains(where: { $0.tag == tag }) {
            elements.append(DicomRTValueCoding.text(tag, tag == 0x300A00B2 ? .SH : .CS, ""))
        }
        if numberOfControlPoints == nil { elements.append(DicomRTValueCoding.text(0x300A0110, .IS, String(controlPoints.count))) }
        for (tag, value) in [(0x300A00D0, numberOfWedges ?? wedges.count), (0x300A00E0, numberOfCompensators ?? 0),
                             (0x300A00ED, numberOfBoli ?? 0), (0x300A00F0, numberOfBlocks ?? 0)] {
            if !elements.contains(where: { $0.tag == tag }) { elements.append(DicomRTValueCoding.text(tag, .IS, String(value))) }
        }
        if let highDoseTechniqueType { elements.append(DicomRTValueCoding.text(0x300A00C7, .CS, highDoseTechniqueType)) }
        if !referenceImageReferences.isEmpty {
            elements.append(DicomRTValueCoding.sequence(0x300C0042, referenceImageReferences.enumerated().map { index, reference in
                DicomRTValueCoding.sourceReference(reference).setting(DicomRTValueCoding.text(0x300A00C8, .IS, String(referenceImageNumbers.indices.contains(index) ? referenceImageNumbers[index] : index + 1)))
            }))
        }
        return DicomDataSet(elements: elements)
    }
}

extension DicomRTPlan {
    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        if let value = label { elements.append(DicomRTValueCoding.text(0x300A0002, .SH, value)) }
        if let value = name { elements.append(DicomRTValueCoding.text(0x300A0003, .LO, value)) }
        if let value = description { elements.append(DicomRTValueCoding.text(0x300A0004, .ST, value)) }
        if let value = geometry { elements.append(DicomRTValueCoding.text(0x300A000C, .CS, value)) }
        if !beams.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300A00B0, beams.map { $0.dataSet })) }
        if !doseReferences.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300A0010, doseReferences.map { $0.dataSet })) }
        if !fractionGroups.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300A0070, fractionGroups.map { $0.dataSet })) }
        if !patientSetups.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300A0180, patientSetups.map { $0.dataSet })) }
        if !toleranceTables.isEmpty { elements.append(DicomRTValueCoding.sequence(0x300A0040, toleranceTables.map { $0.dataSet })) }
        if let value = rtPlanDate { elements.append(DicomRTValueCoding.text(0x300A0006, .DA, value)) }
        if let value = rtPlanTime { elements.append(DicomRTValueCoding.text(0x300A0007, .TM, value)) }
        if let value = approvalStatus { elements.append(DicomRTValueCoding.text(0x300E0002, .CS, value)) }
        if let value = reviewDate { elements.append(DicomRTValueCoding.text(0x300E0004, .DA, value)) }
        if let value = reviewTime { elements.append(DicomRTValueCoding.text(0x300E0005, .TM, value)) }
        if let value = reviewerName { elements.append(DicomRTValueCoding.text(0x300E0008, .PN, value)) }
        for tag in [0x300A0006, 0x300A0007] where !elements.contains(where: { $0.tag == tag }) {
            elements.append(DicomRTValueCoding.text(tag, tag == 0x300A0006 ? .DA : .TM, ""))
        }
        for (kind, tag) in [(ObjectReference.Kind.structureSet, 0x300C0060), (.dose, 0x300C0080), (.plan, 0x300C0002)] {
            let references = objectReferences.filter { $0.kind == kind }
            if !references.isEmpty {
                elements.append(DicomRTValueCoding.sequence(tag, references.map {
                    var data = DicomDataSet(elements: [DicomRTValueCoding.text(0x00081150, .UI, $0.sopClassUID ?? ""),
                        DicomRTValueCoding.text(0x00081155, .UI, $0.sopInstanceUID ?? "")])
                    if let relationship = $0.relationship { data = data.setting(DicomRTValueCoding.text(0x300A0055, .CS, relationship)) }
                    return data
                }))
            }
        }
        return DicomDataSet(elements: elements)
    }
}
