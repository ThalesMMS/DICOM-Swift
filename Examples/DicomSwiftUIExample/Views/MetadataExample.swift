//
//  MetadataExample.swift
//
//  Example demonstrating MetadataView usage
//
//  This view demonstrates displaying DICOM metadata in a formatted list,
//  including patient information, study details, series information, and
//  image properties. Shows how to integrate MetadataView with DicomImageView
//  for a complete viewing experience with metadata access.
//
//  Platform Availability:
//
//  iOS, visionOS, and macOS 26+ - Built with SwiftUI and DicomSwiftUI components.
//

import SwiftUI
import DicomSwiftUI
import DicomCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Example view demonstrating MetadataView usage.
///
/// Shows formatted DICOM metadata display with both List and Form styles.
struct MetadataExample: View {

    // MARK: - State

    @State private var selectedURL: URL?
    @State private var decoder: DCMDecoder?
    @State private var presentationStyle = PresentationStyle.list
    @State private var showMetadataSheet = false
    @State private var showFilePicker = false

    // MARK: - Presentation Style

    enum PresentationStyle: String, CaseIterable, Identifiable {
        case list = "List Style"
        case form = "Form Style"

        var id: String { rawValue }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
#if os(macOS)
            // Split view: Image on left, metadata on right
            HSplitView {
                // Left side: Image display
                imageDisplayView
                    .frame(minWidth: 300)

                // Right side: Metadata display
                metadataDisplayView
                    .frame(minWidth: 350)
            }
#else
            // iOS fallback layout
            VStack(spacing: 0) {
                imageDisplayView
                    .frame(minHeight: 260)

                Divider()

                metadataDisplayView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
#endif

            Divider()

            // Settings panel
            settingsPanelView
                .padding()
                .background(panelBackgroundColor)
        }
        .navigationTitle("Metadata Display")
#if os(iOS)
        .sheet(isPresented: $showFilePicker) {
            MetadataDocumentPicker { url in
                handleSelectedFile(url)
            }
        }
#endif
        .sheet(isPresented: $showMetadataSheet) {
            // Modal sheet presentation
            NavigationView {
                if let decoder = decoder {
                    MetadataView(decoder: decoder, style: .list)
                        .navigationTitle("DICOM Metadata")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") {
                                    showMetadataSheet = false
                                }
                            }
                        }
                }
            }
        }
    }

    // MARK: - Image Display View

    /// Left side: DICOM image display
    private var imageDisplayView: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Image Preview")
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                if decoder != nil {
                    Button("Show in Sheet") {
                        showMetadataSheet = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(panelBackgroundColor)

            Divider()

            // Image
            Group {
                if let url = selectedURL {
                    DicomImageView(url: url)
                        .accessibilityLabel("DICOM image preview")
                } else {
                    imagePlaceholderView
                }
            }
        }
    }

    /// Placeholder shown when no image is loaded
    private var imagePlaceholderView: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Image Loaded")
                .font(.title3)
                .foregroundColor(.primary)

            Text("Select a DICOM file to view image and metadata")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    // MARK: - Metadata Display View

    /// Right side: Metadata display
    private var metadataDisplayView: some View {
        VStack(spacing: 0) {
            // Title bar with style picker
            HStack {
                Text("Metadata")
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                Picker("Style", selection: $presentationStyle) {
                    ForEach(PresentationStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .controlSize(.small)
            }
            .padding(12)
            .background(panelBackgroundColor)

            Divider()

            // Metadata view
            Group {
                if let decoder = decoder {
                    MetadataView(
                        decoder: decoder,
                        style: presentationStyle == .list ? .list : .form
                    )
                    .accessibilityLabel("DICOM metadata")
                } else {
                    metadataPlaceholderView
                }
            }
        }
    }

    /// Placeholder shown when no metadata is available
    private var metadataPlaceholderView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Metadata Available")
                .font(.title3)
                .foregroundColor(.primary)

            Text("Load a DICOM file to view its metadata")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Settings Panel View

    /// Bottom settings panel
    private var settingsPanelView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // File selection
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected File:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(selectedURL?.lastPathComponent ?? "None")
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button("Select File...") {
                    selectDICOMFile()
                }
                .buttonStyle(.bordered)
            }

            Divider()

            // Instructions
            VStack(alignment: .leading, spacing: 8) {
                Text("Usage Instructions:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                instructionsView
                    .font(.caption)
                    .foregroundColor(.primary)
            }

            // Code example
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Code Example:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(codeExample)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
            }
        }
    }

    /// Instructions text
    private var instructionsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                Text("MetadataView displays patient, study, series, and image information")
            }

            HStack(alignment: .top, spacing: 8) {
                Text("•")
                Text("Switch between List and Form styles using the segmented control")
            }

            HStack(alignment: .top, spacing: 8) {
                Text("•")
                Text("Click 'Show in Sheet' to see modal sheet presentation example")
            }

            HStack(alignment: .top, spacing: 8) {
                Text("•")
                Text("Metadata is organized into logical sections with icons and formatted values")
            }
        }
    }

    /// Code example showing MetadataView usage
    private var codeExample: String {
        return """
        // Async, non-blocking loading
        @State private var decoder: DCMDecoder?
        @State private var loadError: Error?

        func loadDecoder(from url: URL) {
            Task {
                do {
                    decoder = try await DCMDecoder(contentsOfFile: url.path)
                } catch {
                    decoder = nil
                    loadError = error
                }
            }
        }

        Group {
            if let decoder {
                MetadataView(decoder: decoder, style: .form)
                    .navigationTitle("DICOM Info")
            } else if loadError != nil {
                Text("Failed to load DICOM file")
            } else {
                ProgressView("Loading DICOM...")
            }
        }

        // In modal sheet
        .sheet(isPresented: $showMetadata) {
            NavigationView {
                Group {
                    if let decoder {
                        MetadataView(decoder: decoder)
                    } else {
                        ProgressView("Loading DICOM...")
                    }
                }
                .navigationTitle("Metadata")
                .toolbar {
                    ToolbarItem {
                        Button("Done") {
                            showMetadata = false
                        }
                    }
                }
            }
        }
        """
    }

    // MARK: - Helper Methods

    private var panelBackgroundColor: Color {
#if os(macOS)
        return Color(NSColor.controlBackgroundColor)
#elseif os(iOS)
        return Color(UIColor.secondarySystemBackground)
#else
        return Color.secondary.opacity(0.1)
#endif
    }

    /// Presents an open panel to choose a single DICOM (.dcm) file and updates view state with the selection.
    /// 
    /// Prompts the user to select a `.dcm` DICOM file and updates the view state with the chosen file and its metadata decoder.
    /// 
    /// Presents an open panel restricted to files with the `.dcm` extension. When the user picks a file, `selectedURL` is set to the file URL and an attempt is made to initialize `decoder` from that URL; if decoder initialization fails, `decoder` is set to `nil` and the error is logged.
    private func selectDICOMFile() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.init(filenameExtension: "dcm")!]
        panel.message = "Select a DICOM file (.dcm)"

        if panel.runModal() == .OK, let url = panel.url {
            handleSelectedFile(url)
        }
#elseif os(iOS)
        showFilePicker = true
#endif
    }

    @MainActor
    private func handleSelectedFile(_ url: URL) {
        selectedURL = url
        let selectedFileURL = url
        decoder = nil

        // Load decoder asynchronously to avoid blocking the main thread.
        Task {
            let hasSecurityScope = selectedFileURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    selectedFileURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let loadedDecoder = try await DCMDecoder(contentsOfFile: selectedFileURL.path)
                await MainActor.run {
                    // Ignore stale completion if user selected another file.
                    if selectedURL == selectedFileURL {
                        decoder = loadedDecoder
                    }
                }
            } catch {
                print("Error loading DICOM file: \(error)")
                await MainActor.run {
                    if selectedURL == selectedFileURL {
                        decoder = nil
                    }
                }
            }
        }
    }
}

#if os(iOS)
private struct MetadataDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // `public.data` is a broad fallback that includes `.dcm` files.
        let picker = UIDocumentPickerViewController(
            documentTypes: ["org.nema.dicom", "public.data"],
            in: .import
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
#endif

// MARK: - Previews

#if DEBUG
struct MetadataExample_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            MetadataExample()
        }
    }
}
#endif
