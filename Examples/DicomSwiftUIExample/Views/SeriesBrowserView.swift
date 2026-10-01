//
//  SeriesBrowserView.swift
//  DicomSwiftUIExample
//
//  Series browser view for displaying series within a DICOM study
//
//  This view presents a browsable list of DICOM series within a selected study,
//  showing series metadata including series number, description, modality, and
//  image count. It provides navigation to the image viewer for viewing individual
//  series.
//
//  The view provides a complete series browsing interface including:
//  - Series list with metadata (number, description, modality, image count)
//  - Navigation to image viewer for selected series
//  - Empty state when no series are available
//  - Patient and study information header
//  - Series grouping and organization
//
//  Platform Availability:
//
//  iOS, visionOS, and macOS 26+ - Built with SwiftUI and DicomCore components.
//

import SwiftUI
import DicomCore

/// Series browser view for displaying series within a DICOM study.
///
/// Presents a list of series with metadata and provides navigation to image viewing.
struct SeriesBrowserView: View {

    // MARK: - Properties

    /// The study containing the series to display
    let study: ImportedStudy

    // MARK: - State

    @State private var selectedSeries: SeriesInfo?
    @State private var showingImageViewer = false

    // MARK: - Body

    var body: some View {
        Group {
            if study.series.isEmpty {
                emptyStateView
            } else {
                seriesListView
            }
        }
        .navigationTitle("Series")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Series List View

    /// Main series list view
    private var seriesListView: some View {
        List {
            // Study information header
            studyInfoSection

            // Series list
            Section(header: Text("Series (\(study.series.count))")) {
                ForEach(study.series) { series in
                    NavigationLink(
                        destination: imageViewerDestination(for: series)
                    ) {
                        SeriesRowView(series: series)
                    }
                    .accessibilityLabel(seriesAccessibilityLabel(for: series))
                }
            }
        }
    }

    // MARK: - Study Information Section

    /// Study information header section
    private var studyInfoSection: some View {
        Section(header: Text("Study Information")) {
            VStack(alignment: .leading, spacing: 12) {
                // Patient name and ID
                VStack(alignment: .leading, spacing: 4) {
                    Text(study.displayPatientName)
                        .font(.headline)

                    HStack(spacing: 12) {
                        Label(study.patientID, systemImage: "person.text.rectangle")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if study.patientSex != .unknown {
                            Label(study.patientSex.appDisplayName, systemImage: "person")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Label(study.displayAge, systemImage: "calendar")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                // Study details
                VStack(alignment: .leading, spacing: 4) {
                    if let description = study.studyDescription, !description.isEmpty {
                        HStack {
                            Text("Study:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(description)
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                    }

                    HStack {
                        Text("Date:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(study.displayStudyDate)
                            .font(.caption)
                            .foregroundColor(.primary)
                    }

                    if let institution = study.institutionName, !institution.isEmpty {
                        HStack {
                            Text("Institution:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(institution)
                                .font(.caption)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                    }

                    HStack {
                        Text("Total Images:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(study.totalImageCount)")
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Empty State View

    /// Placeholder shown when no series are available
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Series Available")
                .font(.title2)
                .foregroundColor(.primary)

            Text("This study does not contain any series")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    // MARK: - Helper Methods

    /// Creates destination view for image viewer
    private func imageViewerDestination(for series: SeriesInfo) -> some View {
        DicomSeriesViewer(series: series, study: study)
    }

    /// Creates accessibility label for series row
    private func seriesAccessibilityLabel(for series: SeriesInfo) -> String {
        "\(series.displayName), \(series.modality.appDisplayName), \(series.numberOfImages) images"
    }
}

// MARK: - Series Row View

/// Individual series row displaying series information
private struct SeriesRowView: View {
    let series: SeriesInfo

    var body: some View {
        HStack(spacing: 16) {
            // Thumbnail placeholder
            thumbnailView

            // Series information
            VStack(alignment: .leading, spacing: 6) {
                // Series number and description
                Text(series.displayName)
                    .font(.headline)
                    .foregroundColor(.primary)

                // Modality and image count
                HStack(spacing: 12) {
                    Label(series.modality.appDisplayName, systemImage: "photo.stack")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Label("\(series.numberOfImages) images", systemImage: "number")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Created date
                HStack {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(formattedDate(series.createdAt))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Navigation chevron
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Thumbnail View

    /// Thumbnail image or placeholder
    private var thumbnailView: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 60, height: 60)

            // Icon
            Image(systemName: modalityIconName)
                .font(.title3)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Helper Methods

    /// Icon name for modality
    private var modalityIconName: String {
        switch series.modality {
        case .ct:
            return "cross.vial"
        case .mr:
            return "waveform.path.ecg"
        case .dx, .cr:
            return "xmark.rectangle"
        case .us:
            return "waveform"
        case .mg:
            return "camera.metering.matrix"
        default:
            return "photo.on.rectangle"
        }
    }

    /// Formats date for display
    private func formattedDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Previews

#if DEBUG
struct SeriesBrowserView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // With series
            NavigationView {
                SeriesBrowserView(study: .sample)
            }
            .previewDisplayName("With Series")

            // Empty state
            NavigationView {
                SeriesBrowserView(study: ImportedStudy(
                    studyInstanceUID: "1.2.3.4.5",
                    patientName: "Test^Patient",
                    patientID: "TEST001",
                    series: []
                ))
            }
            .previewDisplayName("Empty State")

            // Multiple series
            NavigationView {
                SeriesBrowserView(study: ImportedStudy(
                    studyInstanceUID: "1.2.3.4.5",
                    patientName: "Doe^John",
                    patientID: "PAT001",
                    patientSex: .male,
                    patientAge: "045Y",
                    studyDate: Date(),
                    studyDescription: "Chest CT with contrast",
                    modality: .ct,
                    bodyPartExamined: "CHEST",
                    institutionName: "General Hospital",
                    series: [
                        SeriesInfo(
                            seriesInstanceUID: "1.2.3.4.5.1",
                            seriesNumber: 1,
                            seriesDescription: "Localizer",
                            modality: .ct,
                            numberOfImages: 1
                        ),
                        SeriesInfo(
                            seriesInstanceUID: "1.2.3.4.5.2",
                            seriesNumber: 2,
                            seriesDescription: "Chest CT",
                            modality: .ct,
                            numberOfImages: 150
                        ),
                        SeriesInfo(
                            seriesInstanceUID: "1.2.3.4.5.3",
                            seriesNumber: 3,
                            seriesDescription: "Reconstructions",
                            modality: .ct,
                            numberOfImages: 50
                        )
                    ],
                    importStatus: .completed,
                    storagePath: "/path/to/study",
                    fileSize: 1024 * 1024 * 80
                ))
            }
            .previewDisplayName("Multiple Series")
        }
    }
}

struct SeriesRowView_Previews: PreviewProvider {
    static var previews: some View {
        List {
            SeriesRowView(series: SeriesInfo(
                seriesInstanceUID: "1.2.3.4.5.1",
                seriesNumber: 1,
                seriesDescription: "Chest CT",
                modality: .ct,
                numberOfImages: 150
            ))

            SeriesRowView(series: SeriesInfo(
                seriesInstanceUID: "1.2.3.4.5.2",
                seriesNumber: 2,
                seriesDescription: "Brain MRI T1",
                modality: .mr,
                numberOfImages: 200
            ))

            SeriesRowView(series: SeriesInfo(
                seriesInstanceUID: "1.2.3.4.5.3",
                seriesNumber: 3,
                seriesDescription: "Chest X-Ray",
                modality: .dx,
                numberOfImages: 1
            ))
        }
        .previewDisplayName("Series Rows")
    }
}
#endif
