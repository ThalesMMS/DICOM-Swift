//
//  SeriesNavigatorExample.swift
//
//  Example demonstrating SeriesNavigatorView usage
//
//  This view demonstrates navigation through a series of DICOM images (slices),
//  including sequential navigation, direct navigation via slider, and keyboard
//  shortcuts. Shows how to integrate SeriesNavigatorView with DicomImageView
//  for a complete series viewing experience.
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

/// Example view demonstrating SeriesNavigatorView usage.
///
/// Shows series navigation with buttons, slider, and real-time image updates.
struct SeriesNavigatorExample: View {

    // MARK: - State

    @StateObject private var imageViewModel = DicomImageViewModel()
    @StateObject private var navigatorViewModel = SeriesNavigatorViewModel()

    @State private var seriesURLs: [URL] = []
    @State private var layoutMode = LayoutMode.expanded
    @State private var showDirectoryPicker = false

    // MARK: - Layout Options

    enum LayoutMode: String, CaseIterable, Identifiable {
        case expanded = "Expanded"
        case compact = "Compact"

        var id: String { rawValue }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Image display area
            imageDisplayView
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Series navigation controls
            navigationControlsView

            Divider()

            // Settings panel
            settingsPanelView
                .padding()
                .background(panelBackgroundColor)
        }
        .navigationTitle("Series Navigator")
#if os(iOS)
        .sheet(isPresented: $showDirectoryPicker) {
            SeriesDirectoryDocumentPicker { url in
                loadSeriesFromDirectory(url)
            }
        }
#endif
        .onAppear {
            // Initialize with series if already loaded
            if !seriesURLs.isEmpty {
                navigatorViewModel.setSeriesURLs(seriesURLs)
                loadCurrentImage()
            }
        }
    }

    // MARK: - Image Display View

    /// Main image display area
    private var imageDisplayView: some View {
        Group {
            if !seriesURLs.isEmpty {
                DicomImageView(viewModel: imageViewModel)
                    .accessibilityLabel("DICOM series image")
            } else {
                placeholderView
            }
        }
    }

    /// Placeholder shown when no series is loaded
    private var placeholderView: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No DICOM Series Loaded")
                .font(.title2)
                .foregroundColor(.primary)

            Text("Load a directory containing DICOM slices to navigate")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Select Series Directory") {
                selectSeriesDirectory()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .background(Color.black)
    }

    // MARK: - Navigation Controls View

    /// Series navigation control panel
    private var navigationControlsView: some View {
        SeriesNavigatorView(
            navigatorViewModel: navigatorViewModel,
            layout: layoutMode == .expanded ? .expanded : .compact,
            onNavigate: { url in
                // Load the new image when navigation occurs
                Task {
                    await imageViewModel.loadImage(
                        from: url,
                        windowingMode: .automatic,
                        processingMode: .auto
                    )
                }
            }
        )
        .background(panelBackgroundColor)
    }

    // MARK: - Settings Panel View

    /// Settings and instructions panel
    private var settingsPanelView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Series info
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Loaded Series:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if seriesURLs.isEmpty {
                        Text("None")
                            .font(.body)
                            .foregroundColor(.primary)
                    } else {
                        Text("\(seriesURLs.count) images")
                            .font(.body)
                            .foregroundColor(.primary)

                        if let firstURL = seriesURLs.first {
                            Text(firstURL.deletingLastPathComponent().lastPathComponent)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                Spacer()

                Button("Select Directory...") {
                    selectSeriesDirectory()
                }
                .buttonStyle(.bordered)
            }

            Divider()

            // Layout mode
            HStack {
                Text("Layout Mode:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Layout", selection: $layoutMode) {
                    ForEach(LayoutMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
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
                Text("Use Previous/Next buttons to navigate sequentially through slices")
            }

            HStack(alignment: .top, spacing: 8) {
                Text("•")
                Text("Click First/Last buttons to jump to the beginning or end of the series")
            }

            HStack(alignment: .top, spacing: 8) {
                Text("•")
                Text("Drag the slider to navigate directly to any slice in the series")
            }

            HStack(alignment: .top, spacing: 8) {
                Text("•")
                Text("Position indicator shows current slice number and progress percentage")
            }
        }
    }

    /// Code example showing SeriesNavigatorView usage
    private var codeExample: String {
        return """
        @StateObject var imageVM = DicomImageViewModel()
        @StateObject var navigatorVM = SeriesNavigatorViewModel()

        VStack {
            DicomImageView(viewModel: imageVM)

            SeriesNavigatorView(
                navigatorViewModel: navigatorVM,
                onNavigate: { url in
                    Task {
                        await imageVM.loadImage(from: url)
                    }
                }
            )
        }
        .onAppear {
            navigatorVM.setSeriesURLs(seriesURLs)
            if let firstURL = navigatorVM.currentURL {
                Task {
                    await imageVM.loadImage(from: firstURL)
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

    /// Presents a system open panel to choose a directory and loads the DICOM series from the selected folder.
    /// 
    /// Presents a folder picker for the user to choose a directory containing DICOM files and loads that series if a directory is selected.
    /// 
    /// The panel is restricted to selecting a single directory. If the user confirms selection, `loadSeriesFromDirectory(_:)` is called with the chosen URL.
    private func selectSeriesDirectory() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.message = "Select a directory containing DICOM files"

        if panel.runModal() == .OK, let url = panel.url {
            loadSeriesFromDirectory(url)
        }
#elseif os(iOS)
        showDirectoryPicker = true
#endif
    }

    /// Loads DICOM (.dcm) files from the specified directory, updates the view state and navigator with the series, and loads the first image for display.
    /// - Parameters:
    ///   - directoryURL: The directory URL to scan for DICOM files. If no `.dcm` files are found, the function logs a message and does nothing further.
    /// 
    /// Loads DICOM files from the given directory and configures the navigator and image view to display the series.
    /// 
    /// Searches the directory for files with the `.dcm` extension. If DICOM files are found, updates `seriesURLs`,
    /// sets the navigator's series (starting at the first file), and attempts to load the first image. If no DICOM
    /// files are present or an I/O error occurs, the function leaves state unchanged and logs the condition.
    ///
    /// - Parameters:
    ///   - directoryURL: The file-system URL of a directory to scan for DICOM (`.dcm`) files.
    private func loadSeriesFromDirectory(_ directoryURL: URL) {
        do {
            let fileManager = FileManager.default
            let contents = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            // Filter for DICOM files (.dcm extension)
            let dicomFiles = contents.filter { url in
                url.pathExtension.lowercased() == "dcm"
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }

            if dicomFiles.isEmpty {
                // Show alert - no DICOM files found
                print("No DICOM files found in directory")
                return
            }

            // Update state
            seriesURLs = dicomFiles
            navigatorViewModel.setSeriesURLs(dicomFiles, initialIndex: 0)

            // Load first image
            loadCurrentImage()

        } catch {
            print("Error loading directory: \(error)")
        }
    }

    /// Loads the image at the navigator view model's current URL into the image view model.
    /// 
    /// Loads the navigator's current URL into the image view model.
    /// 
    /// If the navigator has a current URL, initiates loading that image using automatic windowing and automatic processing. Does nothing if there is no current URL.
    private func loadCurrentImage() {
        if let currentURL = navigatorViewModel.currentURL {
            Task {
                await imageViewModel.loadImage(
                    from: currentURL,
                    windowingMode: .automatic,
                    processingMode: .auto
                )
            }
        }
    }
}

#if os(iOS)
private struct SeriesDirectoryDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            documentTypes: ["public.folder"],
            in: .open
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
struct SeriesNavigatorExample_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            SeriesNavigatorExample()
        }
    }
}
#endif
