//
//  ContentView.swift
//
//  Main content view for DicomSwiftUI example application
//
//  This view serves as the main app interface, providing DICOM file import
//  capabilities and study browsing functionality. It demonstrates a complete
//  production-quality workflow: import → study browser → series browser → image viewer.
//
//  Platform Availability:
//
//  iOS, visionOS, and macOS 26+ - Built with SwiftUI and DicomSwiftUI components.
//

import SwiftUI
import DicomSwiftUI
import DicomCore

/// Main content view for the DicomSwiftUI example application.
///
/// Provides the primary app interface with DICOM file import and study browsing.
/// The navigation flow is: Import Files → Study Browser → Series Browser → Image Viewer.
///
/// This view demonstrates a production-ready integration of the DicomSwiftUI library,
/// including:
/// - Document picker integration for file import
/// - Study list browsing with search/filter
/// - Series browsing within studies
/// - Interactive image viewing with gestures
struct ContentView: View {

    // MARK: - State

    @StateObject private var studyBrowserViewModel = StudyBrowserViewModel()
    @State private var showingImportPicker = false
    @State private var showingComponentExamples = false
    @State private var showErrorAlert = false
    @State private var errorMessage: String?

    // MARK: - Services

    private let logger = DicomLogger.make(subsystem: "com.dicomswiftuiexample", category: "ContentView")

    // MARK: - Body

    var body: some View {
        NavigationView {
            StudyBrowserView(
                viewModel: studyBrowserViewModel,
                onImportRequested: { showingImportPicker = true }
            )
                .sheet(isPresented: $showingImportPicker) {
                    documentPickerView
                }
                .toolbar {
                    ToolbarItem(placement: toolbarPlacement) {
                        Menu {
                            Button(action: { showingImportPicker = true }) {
                                Label("Import Files", systemImage: "square.and.arrow.down")
                            }

                            Divider()

                            Button(action: { showingComponentExamples = true }) {
                                Label("Component Examples", systemImage: "list.bullet")
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                    }
                }
                .sheet(isPresented: $showingComponentExamples) {
                    NavigationView {
                        ComponentExamplesView()
                    }
                }
                .alert(isPresented: $showErrorAlert) {
                    Alert(
                        title: Text("Import Failed"),
                        message: Text(errorMessage ?? "Unable to import the selected DICOM file."),
                        dismissButton: .default(Text("OK"))
                    )
                }

            // Default detail view for macOS
            DefaultDetailView()
        }
    }

    // MARK: - Platform-Specific Views

    /// iOS document picker for file import
    #if os(iOS)
    private var documentPickerView: some View {
        DocumentPickerView(
            configuration: .mixed,
            onPick: { urls in
                handleImportedFiles(urls)
                showingImportPicker = false
            },
            onCancel: {
                showingImportPicker = false
            }
        )
    }
    #endif

    /// macOS document picker for file import
    #if os(macOS)
    private var documentPickerView: some View {
        DocumentPickerView(
            configuration: .mixed,
            onPick: { urls in
                handleImportedFiles(urls)
                showingImportPicker = false
            },
            onCancel: {
                showingImportPicker = false
            }
        )
    }
    #endif

    // MARK: - Helper Properties

    /// Platform-specific toolbar placement
    private var toolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
        return .navigationBarTrailing
        #else
        return .automatic
        #endif
    }

    // MARK: - Helper Methods

    /// Convert modality string to enum
    /// - Parameter modalityString: DICOM modality code (e.g., "CT", "MR")
    /// - Returns: Corresponding DICOMModality enum value
    private func parseModality(_ modalityString: String) -> DICOMModality {
        switch modalityString.uppercased() {
        case "CT": return .ct
        case "MR": return .mr
        case "DX": return .dx
        case "CR": return .cr
        case "US": return .us
        case "MG": return .mg
        case "RF": return .rf
        case "XC": return .xc
        case "SC": return .sc
        case "PT": return .pt
        case "NM": return .nm
        default: return .unknown
        }
    }

    /// Convert patient sex string to enum
    /// - Parameter sexString: DICOM patient sex code (e.g., "M", "F")
    /// - Returns: Corresponding PatientSex enum value
    private func parsePatientSex(_ sexString: String) -> PatientSex {
        switch sexString.uppercased() {
        case "M": return .male
        case "F": return .female
        case "O": return .other
        default: return .unknown
        }
    }

    /// Parse DICOM date string (YYYYMMDD) to Date
    /// - Parameter dateString: DICOM date in YYYYMMDD format
    /// - Returns: Date object or nil if parsing fails
    private func parseDICOMDate(_ dateString: String) -> Date? {
        guard dateString.count == 8 else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: dateString)
    }

    /// Handle imported files from document picker
    /// - Parameter urls: Array of selected file/directory URLs
    private func handleImportedFiles(_ urls: [URL]) {
        logger.info("📥 Selected \(urls.count) item(s) for import")

        Task {
            for url in urls {
                do {
                    // Start security-scoped access
                    let canAccess = url.startAccessingSecurityScopedResource()
                    defer { if canAccess { url.stopAccessingSecurityScopedResource() } }

                    let fileManager = FileManager.default
                    let decoder = try await DCMDecoder(contentsOfFile: url.path)
                    let destinationURL = try makeImportedDICOMDestinationURL(
                        originalURL: url,
                        decoder: decoder,
                        fileManager: fileManager
                    )

                    if url.standardizedFileURL != destinationURL.standardizedFileURL {
                        if fileManager.fileExists(atPath: destinationURL.path) {
                            try fileManager.removeItem(at: destinationURL)
                        }

                        try fileManager.copyItem(at: url, to: destinationURL)
                    }
                    let filePath = destinationURL.path

                    logger.info("📋 Copied file to: \(filePath)")

                    // Create series info
                    let seriesInfo = SeriesInfo(
                        seriesInstanceUID: decoder.info(for: .seriesInstanceUID).isEmpty ? UUID().uuidString : decoder.info(for: .seriesInstanceUID),
                        seriesNumber: decoder.intValue(for: .seriesNumber) ?? 0,
                        seriesDescription: decoder.info(for: .seriesDescription).isEmpty ? nil : decoder.info(for: .seriesDescription),
                        modality: parseModality(decoder.info(for: .modality)),
                        numberOfImages: 1,
                        imagePaths: [filePath],
                        thumbnailPath: nil
                    )

                    // Create imported study
                    let study = ImportedStudy(
                        studyInstanceUID: decoder.info(for: .studyInstanceUID).isEmpty ? UUID().uuidString : decoder.info(for: .studyInstanceUID),
                        patientName: decoder.info(for: .patientName).isEmpty ? "Unknown" : decoder.info(for: .patientName),
                        patientID: decoder.info(for: .patientID).isEmpty ? "Unknown" : decoder.info(for: .patientID),
                        patientSex: parsePatientSex(decoder.info(for: .patientSex)),
                        patientAge: decoder.info(for: .patientAge).isEmpty ? nil : decoder.info(for: .patientAge),
                        studyDate: parseDICOMDate(decoder.info(for: .studyDate)),
                        studyDescription: decoder.info(for: .studyDescription).isEmpty ? nil : decoder.info(for: .studyDescription),
                        modality: parseModality(decoder.info(for: .modality)),
                        bodyPartExamined: decoder.info(for: .bodyPartExamined).isEmpty ? nil : decoder.info(for: .bodyPartExamined),
                        institutionName: decoder.info(for: .institutionName).isEmpty ? nil : decoder.info(for: .institutionName),
                        series: [seriesInfo],
                        importStatus: .completed,
                        storagePath: filePath,
                        fileSize: (try? fileManager.attributesOfItem(atPath: filePath)[.size] as? Int64) ?? 0
                    )

                    // Add to view model on main actor
                    await MainActor.run {
                        studyBrowserViewModel.addStudy(study)
                    }

                    logger.info("✅ Imported study: \(study.displayPatientName)")
                } catch let error as DICOMError {
                    logger.error("❌ Failed to import \(url.lastPathComponent): \(error)")
                    await MainActor.run {
                        showImportError("Failed to import \(url.lastPathComponent): \(error.localizedDescription)")
                    }
                } catch {
                    logger.error("❌ Failed to import \(url.lastPathComponent): \(error)")
                    await MainActor.run {
                        showImportError("Failed to import \(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func makeImportedDICOMDestinationURL(
        originalURL: URL,
        decoder: DCMDecoder,
        fileManager: FileManager
    ) throws -> URL {
        let studiesURL = try DicomSwiftUIExampleStorage.studiesURL(fileManager: fileManager)
        let studyUID = storageComponent(decoder.info(for: .studyInstanceUID), fallback: UUID().uuidString)
        let seriesUID = storageComponent(decoder.info(for: .seriesInstanceUID), fallback: UUID().uuidString)
        let sopUID = storageComponent(decoder.info(for: .sopInstanceUID), fallback: UUID().uuidString)
        let seriesURL = studiesURL
            .appendingPathComponent(studyUID, isDirectory: true)
            .appendingPathComponent(seriesUID, isDirectory: true)

        try fileManager.createDirectory(at: seriesURL, withIntermediateDirectories: true)

        let storedFilename = "\(sopUID).dcm"
        if originalURL.lastPathComponent == storedFilename {
            return seriesURL.appendingPathComponent(originalURL.lastPathComponent)
        }
        return seriesURL.appendingPathComponent(storedFilename)
    }

    private func storageComponent(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let component = trimmed.isEmpty ? fallback : trimmed
        return component
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private func showImportError(_ message: String) {
        errorMessage = message
        showErrorAlert = true
    }
}

/// Default detail view shown when no study is selected (macOS).
struct DefaultDetailView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "medical.thermometer")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            Text("DICOM Viewer")
                .font(.title)

            Text("Select a study from the sidebar to view series and images")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .navigationTitle("DICOM Viewer")
    }
}

/// Component examples view showing library demonstrations.
///
/// This view provides access to standalone component examples for learning
/// and testing individual DicomSwiftUI components.
struct ComponentExamplesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section(header: Text("Component Examples")) {
                NavigationLink("Image View", destination: ImageViewExample())
                NavigationLink("Windowing Controls", destination: WindowingExample())
                NavigationLink("Series Navigator", destination: SeriesNavigatorExample())
                NavigationLink("Metadata Display", destination: MetadataExample())
            }

            Section(header: Text("About")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("DicomSwiftUI Library")
                        .font(.headline)
                    Text("Demonstrates SwiftUI components for DICOM medical image viewing.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Examples")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

struct DefaultDetailView_Previews: PreviewProvider {
    static var previews: some View {
        DefaultDetailView()
    }
}

struct ComponentExamplesView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ComponentExamplesView()
        }
    }
}
#endif
