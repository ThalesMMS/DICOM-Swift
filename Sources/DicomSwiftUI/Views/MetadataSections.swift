//
//  MetadataSections.swift
//
//  Small SwiftUI subviews used by MetadataView.
//

import SwiftUI
import DicomCore

struct MetadataPatientSection: View {
    let metadata: DicomMetadataAccessor

    var body: some View {
        Section(header: Text("Patient Information")
            .accessibilityAddTraits(.isHeader)) {

            MetadataRow(
                label: "Name",
                value: metadata.optionalString(.patientName),
                icon: "person.fill"
            )

            MetadataRow(
                label: "Patient ID",
                value: metadata.optionalString(.patientID),
                icon: "number"
            )

            MetadataRow(
                label: "Sex",
                value: DicomDisplayFormatter.sex(metadata.optionalString(.patientSex)),
                icon: "person.crop.circle"
            )

            MetadataRow(
                label: "Age",
                value: metadata.optionalString(.patientAge),
                icon: "calendar"
            )
        }
    }
}

struct MetadataStudySection: View {
    let metadata: DicomMetadataAccessor

    var body: some View {
        Section(header: Text("Study Information")
            .accessibilityAddTraits(.isHeader)) {

            MetadataRow(
                label: "Description",
                value: metadata.optionalString(.studyDescription),
                icon: "doc.text.fill"
            )

            MetadataRow(
                label: "Study Date",
                value: DicomDisplayFormatter.date(metadata.optionalString(.studyDate)),
                icon: "calendar"
            )

            MetadataRow(
                label: "Study Time",
                value: DicomDisplayFormatter.time(metadata.optionalString(.studyTime)),
                icon: "clock.fill"
            )

            MetadataRow(
                label: "Study ID",
                value: metadata.optionalString(.studyID),
                icon: "number"
            )

            MetadataRow(
                label: "Modality",
                value: DicomDisplayFormatter.modality(metadata.optionalString(.modality)),
                icon: "cross.case.fill"
            )

            MetadataRow(
                label: "Institution",
                value: metadata.optionalString(.institutionName),
                icon: "building.2.fill"
            )
        }
    }
}

struct MetadataSeriesSection: View {
    let metadata: DicomMetadataAccessor

    var body: some View {
        Section(header: Text("Series Information")
            .accessibilityAddTraits(.isHeader)) {

            MetadataRow(
                label: "Description",
                value: metadata.optionalString(.seriesDescription),
                icon: "square.stack.3d.up.fill"
            )

            MetadataRow(
                label: "Series Number",
                value: metadata.optionalString(.seriesNumber),
                icon: "number"
            )

            MetadataRow(
                label: "Instance Number",
                value: metadata.optionalString(.instanceNumber),
                icon: "number.square.fill"
            )

            MetadataRow(
                label: "Instances in Series",
                value: metadata.optionalString(.numberOfSeriesRelatedInstances),
                icon: "square.stack.fill"
            )
        }
    }
}

struct MetadataImageSection: View {
    let decoder: any DicomDecoderProtocol
    let metadata: DicomMetadataAccessor

    var body: some View {
        Section(header: Text("Image Properties")
            .accessibilityAddTraits(.isHeader)) {

            MetadataRow(
                label: "Dimensions",
                value: DicomDisplayFormatter.dimensions(width: decoder.width, height: decoder.height),
                icon: "arrow.up.left.and.arrow.down.right"
            )

            MetadataRow(
                label: "Pixel Spacing",
                value: DicomDisplayFormatter.pixelSpacing(decoder.pixelSpacingV2),
                icon: "ruler.fill"
            )

            MetadataRow(
                label: "Slice Thickness",
                value: DicomDisplayFormatter.measurement(metadata.optionalString(.sliceThickness), unit: "mm"),
                icon: "square.split.2x1.fill"
            )

            MetadataRow(
                label: "Bits Allocated",
                value: metadata.optionalString(.bitsAllocated),
                icon: "scalemass.fill"
            )

            MetadataRow(
                label: "Photometric",
                value: metadata.optionalString(.photometricInterpretation),
                icon: "photo.fill"
            )

            MetadataRow(
                label: "Window Center",
                value: DicomDisplayFormatter.windowValue(
                    decoder.windowSettingsV2.center,
                    isValid: decoder.windowSettingsV2.isValid
                ),
                icon: "slider.horizontal.3"
            )

            MetadataRow(
                label: "Window Width",
                value: DicomDisplayFormatter.windowValue(
                    decoder.windowSettingsV2.width,
                    isValid: decoder.windowSettingsV2.isValid
                ),
                icon: "slider.horizontal.3"
            )
        }
    }
}
