//
//  StudyBrowserView.swift
//  DicomSwiftUIExample
//
//  Main study browser view for displaying and managing imported DICOM studies
//
//  This view presents a browsable list of imported DICOM studies with patient
//  information, study metadata, and navigation to series viewing. It integrates
//  with StudyBrowserViewModel for state management and supports search, filtering,
//  sorting, and pull-to-refresh functionality.
//
//  The view provides a complete study management interface including:
//  - Study list with patient demographics and study information
//  - Search by patient name, ID, or study description
//  - Filter by modality and import status
//  - Sort by study date, patient name, or import date
//  - Navigation to series browser for selected studies
//  - Empty state with import prompts
//  - Refresh capability for reloading studies
//
//  Platform Availability:
//
//  iOS, visionOS, and macOS 26+ - Built with SwiftUI and DicomCore components.
//

import SwiftUI
import DicomCore

enum DicomSwiftUIExampleStorage {
    static func studiesURL(fileManager: FileManager = .default) throws -> URL {
        let appSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let studiesURL = appSupportURL.appendingPathComponent("Studies", isDirectory: true)
        try fileManager.createDirectory(at: studiesURL, withIntermediateDirectories: true)
        return studiesURL
    }
}

/// Main study browser view for displaying imported DICOM studies.
///
/// Presents a searchable, filterable list of studies with patient information
/// and provides navigation to series viewing.
struct StudyBrowserView: View {

    // MARK: - State

    @ObservedObject var viewModel: StudyBrowserViewModel
    private let onImportRequested: () -> Void
    @State private var showingFilterSheet = false

    init(
        viewModel: StudyBrowserViewModel,
        onImportRequested: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.onImportRequested = onImportRequested
    }

    // MARK: - Body

    var body: some View {
        Group {
            if viewModel.isEmpty && viewModel.state == .loaded {
                emptyStateView
            } else {
                studyListView
            }
        }
        .navigationTitle("Studies")
        .toolbar {
            ToolbarItem(placement: toolbarPlacement) {
                toolbarContent
            }
        }
        .sheet(isPresented: $showingFilterSheet) {
            filterSheetView
        }
        .task {
            do {
                let studiesURL = try DicomSwiftUIExampleStorage.studiesURL()
                await viewModel.loadStudies(from: studiesURL.path)
            } catch let dicomError as DICOMError {
                viewModel.handleStartupError(dicomError)
            } catch {
                let dicomError = DICOMError.fileReadError(
                    path: "Application Support/Studies",
                    underlyingError: error.localizedDescription
                )
                viewModel.handleStartupError(dicomError)
            }
        }
        .alert(isPresented: startupErrorAlertBinding) {
            Alert(
                title: Text("Unable to Load Studies"),
                message: Text(viewModel.error?.localizedDescription ?? "Storage could not be initialized."),
                dismissButton: .default(Text("OK")) {
                    viewModel.clearError()
                }
            )
        }
    }

    // MARK: - Study List View

    /// Main study list with search and filter
    private var studyListView: some View {
        List {
            // Filter summary
            if viewModel.filterOptions.hasActiveFilters {
                filterSummarySection
            }

            // Study list
            ForEach(viewModel.filteredStudies) { study in
                NavigationLink(
                    destination: seriesBrowserDestination(for: study)
                ) {
                    StudyRowView(study: study)
                }
                .accessibilityLabel(studyAccessibilityLabel(for: study))
            }
        }
        .searchable(
            text: Binding(
                get: { viewModel.filterOptions.searchQuery },
                set: { viewModel.filterOptions.searchQuery = $0 }
            ),
            prompt: "Search by name, ID, or description"
        )
        .refreshable {
            await viewModel.refresh()
        }
        .overlay {
            if viewModel.state == .loading {
                loadingOverlay
            }
        }
    }

    // MARK: - Empty State View

    /// Placeholder shown when no studies are loaded
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            Text("No Studies")
                .font(.title)

            Text("Import DICOM files to get started")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Import Files") {
                requestImport()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }

    // MARK: - Loading Overlay

    /// Loading indicator overlay
    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)

                Text("Loading studies...")
                    .foregroundColor(.white)
            }
            .padding(24)
            .background(Color.secondary.opacity(0.8))
            .cornerRadius(12)
        }
    }

    // MARK: - Filter Summary Section

    /// Shows active filters with clear button
    private var filterSummarySection: some View {
        Section(header: Text("Active Filters")) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if let modality = viewModel.filterOptions.modality {
                        Text("Modality: \(modality.appDisplayName)")
                            .font(.caption)
                    }

                    if let status = viewModel.filterOptions.importStatus {
                        Text("Status: \(status.displayName)")
                            .font(.caption)
                    }

                    if !viewModel.filterOptions.searchQuery.isEmpty {
                        Text("Search: \"\(viewModel.filterOptions.searchQuery)\"")
                            .font(.caption)
                    }
                }

                Spacer()

                Button("Clear") {
                    viewModel.resetFilters()
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Toolbar Content

    /// Platform-specific toolbar placement
    private var toolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
        return .navigationBarTrailing
        #else
        return .automatic
        #endif
    }

    /// Toolbar buttons for actions
    private var toolbarContent: some View {
        HStack(spacing: 12) {
            // Filter button
            Button(action: { showingFilterSheet = true }) {
                Label("Filter", systemImage: viewModel.filterOptions.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }

            // Import button
            Button(action: { requestImport() }) {
                Label("Import", systemImage: "square.and.arrow.down")
            }
        }
    }

    // MARK: - Filter Sheet View

    private func requestImport() {
        onImportRequested()
    }

    /// Filter and sort options sheet
    private var filterSheetView: some View {
        NavigationView {
            Form {
                Section(header: Text("Sort By")) {
                    Picker("Sort Option", selection: $viewModel.sortOption) {
                        ForEach(StudySortOption.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                }

                Section(header: Text("Filter By Modality")) {
                    Picker("Modality", selection: $viewModel.filterOptions.modality) {
                        Text("All").tag(DICOMModality?.none)
                        ForEach([DICOMModality.ct, .mr, .dx, .cr, .us, .mg], id: \.self) { modality in
                            Text(modality.appDisplayName).tag(DICOMModality?.some(modality))
                        }
                    }
                    .pickerStyle(.inline)
                }

                Section(header: Text("Filter By Status")) {
                    Picker("Import Status", selection: $viewModel.filterOptions.importStatus) {
                        Text("All").tag(ImportStatus?.none)
                        ForEach([ImportStatus.completed, .importing, .failed, .pending], id: \.self) { status in
                            Text(status.displayName).tag(ImportStatus?.some(status))
                        }
                    }
                    .pickerStyle(.inline)
                }

                Section {
                    Button("Reset All Filters") {
                        viewModel.resetFilters()
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Filter & Sort")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showingFilterSheet = false
                    }
                }
            }
        }
    }

    // MARK: - Helper Methods

    /// Creates destination view for series browser
    private func seriesBrowserDestination(for study: ImportedStudy) -> some View {
        SeriesBrowserView(study: study)
    }

    /// Creates accessibility label for study row
    private func studyAccessibilityLabel(for study: ImportedStudy) -> String {
        "\(study.displayPatientName), \(study.displayStudyDate), \(study.studySummary)"
    }

    private var startupErrorAlertBinding: Binding<Bool> {
        Binding(
            get: {
                if case .failed = viewModel.state {
                    return viewModel.error != nil
                }
                return false
            },
            set: { isPresented in
                if !isPresented {
                    viewModel.clearError()
                }
            }
        )
    }
}

// MARK: - Study Row View

/// Individual study row displaying patient and study information
private struct StudyRowView: View {
    let study: ImportedStudy

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Patient name and ID
            HStack {
                Text(study.displayPatientName)
                    .font(.headline)

                Spacer()

                // Import status indicator
                Image(systemName: study.importStatus.iconName)
                    .foregroundColor(statusColor)
                    .accessibilityLabel(study.importStatus.displayName)
            }

            // Patient demographics
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

            // Study information
            VStack(alignment: .leading, spacing: 4) {
                Text(study.studySummary)
                    .font(.subheadline)
                    .foregroundColor(.primary)

                HStack(spacing: 12) {
                    Text(study.displayStudyDate)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let institution = study.institutionName, !institution.isEmpty {
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(institution)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            // File size
            Text(study.displayFileSize)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// Color for status indicator
    private var statusColor: Color {
        switch study.importStatus {
        case .completed:
            return .green
        case .importing:
            return .blue
        case .failed:
            return .red
        case .pending:
            return .orange
        }
    }
}

// MARK: - Previews

#if DEBUG
struct StudyBrowserView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // With studies
            NavigationView {
                StudyBrowserView(
                    viewModel: StudyBrowserViewModel.preview,
                    onImportRequested: {}
                )
            }
            .previewDisplayName("With Studies")

            // Empty state
            NavigationView {
                StudyBrowserView(
                    viewModel: StudyBrowserViewModel(),
                    onImportRequested: {}
                )
            }
            .previewDisplayName("Empty State")
        }
    }
}

struct StudyRowView_Previews: PreviewProvider {
    static var previews: some View {
        List {
            StudyRowView(study: .sample)
            StudyRowView(study: ImportedStudy.samples[1])
            StudyRowView(study: ImportedStudy.samples[2])
        }
        .previewDisplayName("Study Rows")
    }
}
#endif
