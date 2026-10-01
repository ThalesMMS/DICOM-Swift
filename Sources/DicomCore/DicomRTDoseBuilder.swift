import Foundation

/// Native integer RT Dose and DVH serialization. No dose or histogram recomputation is performed.
public enum DicomRTDoseBuilder {
    public enum BuildError: Error, Equatable, Sendable {
        case invalidGrid
        case invalidDose
        case invalidDVH
        case unsupported
    }

    public static func dataSet(
        from dose: DicomRTDoseVolume,
        studyInstanceUID: String,
        seriesInstanceUID: String,
        sopInstanceUID: String? = nil,
        options: DicomRTStructureSetBuildOptions = .init()
    ) throws -> DicomDataSet {
        guard dose.doseUnits == "GY" || dose.doseUnits == "RELATIVE",
              let type = dose.doseType, ["PHYSICAL", "EFFECTIVE", "ERROR"].contains(type),
              let summation = dose.doseSummationType, let frameUID = dose.frameOfReferenceUID, !frameUID.isEmpty else {
            throw BuildError.invalidDose
        }
        guard summation != "PLAN_OVERVIEW" else { throw BuildError.unsupported }
        guard dose.dvhs.allSatisfy({ $0.numberOfBins > 0 && $0.numberOfBins == $0.bins.count && !$0.referencedROIs.isEmpty }),
              dose.dvhs.isEmpty || dose.referencedStructureSet != nil else { throw BuildError.invalidDVH }
        var data = DicomRTValueCoding.common(sopClass: DicomRTDoseVolume.storageSOPClassUID,
            sopInstance: sopInstanceUID ?? dose.sopInstanceUID ?? DicomDataSetWriter.makeUID(),
            study: studyInstanceUID, series: seriesInstanceUID, modality: "RTDOSE", options: options)
        let text = DicomRTValueCoding.text
        let decimals = DicomRTValueCoding.decimals
        let sequence = DicomRTValueCoding.sequence
        for element in [text(0x30040002, .CS, dose.doseUnits!), text(0x30040004, .CS, type),
                        text(0x3004000A, .CS, summation), text(0x00200052, .UI, frameUID), text(0x00201040, .LO, "")] {
            data = data.setting(element)
        }
        for (tag, value) in [(0x30040005, dose.spatialTransformOfDose), (0x30040006, dose.doseComment)] {
            if let value { data = data.setting(text(tag, tag == 0x30040005 ? .CS : .LO, value)) }
        }
        if let number = dose.instanceNumber { data = data.setting(text(0x00200013, .IS, String(number))) }
        for (tag, value) in [(0x30040008, dose.normalizationPoint), (0x30040040, dose.dvhNormalizationPoint)] {
            if let value { data = data.setting(decimals(tag, [value.x, value.y, value.z])) }
        }
        if let value = dose.dvhNormalizationDoseValue { data = data.setting(decimals(0x30040042, [value])) }
        for (tag, items) in [(0x300C0002, dose.referencedPlans.map { $0.dataSet }),
                             (0x30080030, dose.referencedTreatmentRecords.map { $0.dataSet }),
                             (0x00700404, dose.referencedSpatialRegistrations.map { $0.dataSet }),
                             (0x30040050, dose.dvhs.map { $0.dataSet }),
                             (0x30040016, dose.recommendedIsodoseLevels.map { $0.dataSet }),
                             (0x00089215, dose.derivationCodes.map(DicomRTStructureSetBuilder.codeDataSet)),
                             (0x0008114A, dose.referencedInstances.map(DicomRTValueCoding.sourceReference))] {
            if !items.isEmpty { data = data.setting(sequence(tag, items)) }
        }
        if let reference = dose.referencedStructureSet { data = data.setting(sequence(0x300C0060, [reference.dataSet])) }
        if ["RIGID", "NON_RIGID"].contains(dose.spatialTransformOfDose ?? "") && dose.referencedSpatialRegistrations.isEmpty {
            data = data.setting(sequence(0x00700404, []))
        }
        let hasGrid = dose.rows != 0 || dose.columns != 0 || !dose.storedValues.isEmpty || dose.signedStoredValues != nil
        if !hasGrid {
            guard !dose.dvhs.isEmpty else { throw BuildError.invalidDose }
            return data
        }
        let bits = dose.bitsAllocated ?? 16
        let representation = dose.pixelRepresentation ?? (dose.signedStoredValues == nil ? 0 : 1)
        let (planeCount, planeOverflow) = dose.rows.multipliedReportingOverflow(by: dose.columns)
        let (count, countOverflow) = planeCount.multipliedReportingOverflow(by: dose.frames)
        guard !planeOverflow, !countOverflow, dose.rows > 0, dose.columns > 0, dose.frames > 0,
              dose.rows <= 65535, dose.columns <= 65535, bits == 16 || bits == 32,
              representation == 0 || representation == 1, dose.doseGridScaling.isFinite, dose.doseGridScaling > 0,
              let spacing = dose.pixelSpacing, spacing.x > 0, spacing.y > 0,
              let position = dose.imagePositionPatient, let orientation = dose.imageOrientationPatient,
              dose.gridFrameOffsets.planePositions(imagePosition: position, orientation: orientation) != nil,
              dose.frames == 1 || (dose.gridFrameOffsetVector.count == dose.frames && dose.gridFrameOffsets.isMonotonic)
        else { throw BuildError.invalidGrid }
        var words: [UInt32]
        if representation == 1 {
            guard type == "ERROR", let signed = dose.signedStoredValues, signed.count == count,
                  bits == 32 || signed.allSatisfy({ Int16(exactly: $0) != nil }) else { throw BuildError.invalidGrid }
            words = signed.map { bits == 16 ? UInt32(UInt16(bitPattern: Int16($0))) : UInt32(bitPattern: $0) }
        } else {
            guard dose.signedStoredValues == nil, dose.storedValues.count == count,
                  bits == 32 || dose.storedValues.allSatisfy({ $0 <= UInt16.max }) else { throw BuildError.invalidGrid }
            words = dose.storedValues
        }
        let row = orientation.row, column = orientation.column
        for (tag, value) in [(0x00280002, 1), (0x00280010, dose.rows), (0x00280011, dose.columns),
                             (0x00280100, bits), (0x00280101, bits), (0x00280102, bits - 1), (0x00280103, representation)] {
            data = data.setting(DicomDataElement(tag: tag, vr: .US, value: .unsignedIntegers([UInt(value)])))
        }
        for element in [text(0x00280004, .CS, "MONOCHROME2"), DicomDataElement(tag: 0x00080008, vr: .CS, value: .strings(["DERIVED", "SECONDARY"])),
                        text(0x00200013, .IS, dose.instanceNumber.map(String.init) ?? ""),
                        decimals(0x00280030, [spacing.x, spacing.y]), decimals(0x00200032, [position.x, position.y, position.z]),
                        decimals(0x00200037, [row.x, row.y, row.z, column.x, column.y, column.z]),
                        decimals(0x3004000E, [dose.doseGridScaling]),
                        dose.sliceThickness.map { decimals(0x00180050, [$0]) } ?? text(0x00180050, .DS, "")] {
            data = data.setting(element)
        }
        if dose.frames > 1 {
            data = data.setting(text(0x00280008, .IS, String(dose.frames)))
                .setting(DicomDataElement(tag: 0x00280009, vr: .AT, value: .unsignedIntegers([0x3004000C])))
                .setting(decimals(0x3004000C, dose.gridFrameOffsetVector))
        }
        var pixels = Data()
        for word in words {
            for shift in stride(from: 0, to: bits, by: 8) { pixels.append(UInt8(truncatingIfNeeded: word >> shift)) }
        }
        return data.setting(DicomDataElement(tag: 0x7FE00010, vr: .OW, value: .bytes(pixels)))
    }

    /// Combine a grid with DVHs, or pass nil for a DVH-only document.
    public static func dataSet(
        grid: DicomRTDoseVolume?, dvhs: [DicomRTDVH], referencedStructureSet: DicomSOPReference,
        referencedPlans: [DicomRTDoseReferencedPlan], frameOfReferenceUID: String,
        studyInstanceUID: String, seriesInstanceUID: String, sopInstanceUID: String,
        doseUnits: String = "GY", doseType: String = "PHYSICAL", doseSummationType: String = "PLAN"
    ) throws -> DicomDataSet {
        return try dataSet(from: DicomRTDoseVolume(sopInstanceUID: sopInstanceUID, doseUnits: doseUnits,
            doseType: doseType, doseSummationType: doseSummationType, doseGridScaling: grid?.doseGridScaling ?? 1,
            frameOfReferenceUID: frameOfReferenceUID, rows: grid?.rows ?? 0, columns: grid?.columns ?? 0,
            frames: grid?.frames ?? 0, pixelSpacing: grid?.pixelSpacing, imagePositionPatient: grid?.imagePositionPatient,
            imageOrientationPatient: grid?.imageOrientationPatient, gridFrameOffsetVector: grid?.gridFrameOffsetVector ?? [],
            sliceThickness: grid?.sliceThickness, storedValues: grid?.storedValues ?? [],
            referencedPlans: referencedPlans, referencedStructureSet: referencedStructureSet,
            pixelRepresentation: grid?.pixelRepresentation, bitsAllocated: grid?.bitsAllocated,
            signedStoredValues: grid?.signedStoredValues, dvhs: dvhs),
            studyInstanceUID: studyInstanceUID, seriesInstanceUID: seriesInstanceUID)
    }
}
