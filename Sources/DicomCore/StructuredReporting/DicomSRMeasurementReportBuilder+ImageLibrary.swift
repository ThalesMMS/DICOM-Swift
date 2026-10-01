import Foundation

extension DicomSRMeasurementReportBuilder {
    static func imageLibraryItem(_ entry: DicomSRImageLibraryEntry) -> DicomSRContentItem {
        var children: [DicomSRContentItem] = []
        if let value = entry.modality {
            children.append(.init(relationshipType: "HAS ACQ CONTEXT", valueType: "CODE",
                conceptName: code("121139", "Modality"), codeValue: value))
        }
        if let value = entry.studyDate {
            children.append(.init(relationshipType: "HAS ACQ CONTEXT", valueType: "DATE",
                conceptName: code("111060", "Study Date"), dateValue: value))
        }
        if let value = entry.studyTime {
            children.append(.init(relationshipType: "HAS ACQ CONTEXT", valueType: "TIME",
                conceptName: code("111061", "Study Time"), timeValue: value))
        }
        if let value = entry.seriesUID {
            children.append(.init(relationshipType: "HAS ACQ CONTEXT", valueType: "UIDREF",
                conceptName: code("112002", "Series Instance UID"), uidValue: value))
        }
        if let value = entry.seriesNumber {
            children.append(.init(relationshipType: "HAS ACQ CONTEXT", valueType: "TEXT",
                conceptName: code("113607", "Series Number"), textValue: value))
        }
        if let value = entry.seriesDescription {
            children.append(.init(relationshipType: "HAS ACQ CONTEXT", valueType: "TEXT",
                conceptName: code("131563", "Series Description"), textValue: value))
        }
        if let value = entry.frameOfReferenceUID {
            children.append(.init(relationshipType: "HAS ACQ CONTEXT", valueType: "UIDREF",
                conceptName: code("112227", "Frame of Reference UID"), uidValue: value))
        }
        if let value = entry.instanceNumber {
            children.append(.init(relationshipType: "HAS ACQ CONTEXT", valueType: "TEXT",
                conceptName: code("113609", "Instance Number"), textValue: value))
        }
        if let value = entry.contentDate {
            children.append(.init(relationshipType: "HAS ACQ CONTEXT", valueType: "DATE",
                conceptName: code("111018", "Content Date"), dateValue: value))
        }
        if let value = entry.contentTime {
            children.append(.init(relationshipType: "HAS ACQ CONTEXT", valueType: "TIME",
                conceptName: code("111019", "Content Time"), timeValue: value))
        }
        if let value = entry.acquisitionDate {
            children.append(.init(relationshipType: "HAS ACQ CONTEXT", valueType: "DATE",
                conceptName: code("126201", "Acquisition Date"), dateValue: value))
        }
        if let value = entry.acquisitionTime {
            children.append(.init(relationshipType: "HAS ACQ CONTEXT", valueType: "TIME",
                conceptName: code("126202", "Acquisition Time"), timeValue: value))
        }
        if let value = entry.ctAcquisitionType {
            children.append(.init(relationshipType: "HAS ACQ CONTEXT", valueType: "CODE",
                conceptName: code("113820", "CT Acquisition Type"), codeValue: value))
        }
        if let value = entry.ctReconstructionAlgorithm {
            children.append(.init(relationshipType: "HAS ACQ CONTEXT", valueType: "CODE",
                conceptName: code("113961", "Reconstruction Algorithm"), codeValue: value))
        }
        if let value = entry.mrPulseSequenceName {
            children.append(.init(relationshipType: "HAS ACQ CONTEXT", valueType: "TEXT",
                conceptName: code("128230", "Pulse Sequence Name"), textValue: value))
        }
        if let value = entry.rows {
            children.append(descriptor("110910", "Pixel Data Rows", value, "{pixels}"))
        }
        if let value = entry.columns {
            children.append(descriptor("110911", "Pixel Data Columns", value, "{pixels}"))
        }
        if let value = entry.numberOfFrames {
            children.append(descriptor("121140", "Number of Frames", value, "{frames}"))
        }
        if let value = entry.horizontalPixelSpacing {
            children.append(descriptor("111026", "Horizontal Pixel Spacing", value, "mm"))
        }
        if let value = entry.verticalPixelSpacing {
            children.append(descriptor("111066", "Vertical Pixel Spacing", value, "mm"))
        }
        if let value = entry.spacingBetweenSlices {
            children.append(descriptor("112226", "Spacing between slices", value, "mm"))
        }
        if let value = entry.sliceThickness {
            children.append(descriptor("112225", "Slice Thickness", value, "mm"))
        }
        if let value = entry.mrMagneticFieldStrength {
            children.append(descriptor("130542", "Magnetic field strength", value, "T"))
        }
        for (index, value) in entry.imagePosition.prefix(3).enumerated() {
            children.append(descriptor(String(110901 + index), "Image Position (Patient)", value, "mm"))
        }
        for (index, value) in entry.imageOrientation.prefix(6).enumerated() {
            children.append(descriptor(String(110904 + index), "Image Orientation (Patient)", value, "{-1:1}"))
        }
        children += entry.mrDiffusionBValues.map { descriptor("113240", "Source image diffusion b-value", $0, "s/mm2") }
        children += entry.additionalDescriptors
        return .init(relationshipType: "CONTAINS", valueType: "IMAGE", conceptName: code("121112", "Source of Measurement"), referencedSOPs: [entry.reference], children: children)
    }

    private static func descriptor(_ concept: String, _ meaning: String, _ value: Double, _ unit: String) -> DicomSRContentItem {
        .init(relationshipType: "HAS ACQ CONTEXT", valueType: "NUM", conceptName: code(concept, meaning),
              numericValue: value, measurementUnits: code(unit, unit, scheme: "UCUM"))
    }
}
