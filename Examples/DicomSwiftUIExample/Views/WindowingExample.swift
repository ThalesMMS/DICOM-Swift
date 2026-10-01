//
//  WindowingExample.swift
//
//  Example demonstrating WindowingControlView usage
//
//  This view demonstrates interactive window/level adjustment for DICOM images,
//  including preset selection, slider controls, and real-time image updates.
//  Shows how to integrate WindowingControlView with DicomImageView for a
//  complete interactive viewing experience.
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

/// Example view demonstrating WindowingControlView usage.
///
/// Shows interactive window/level adjustment with preset buttons, sliders,
/// and real-time image updates.
struct WindowingExample: View {

    // MARK: - State

    @StateObject private var imageViewModel = DicomImageViewModel()
    @StateObject private var windowingViewModel = WindowingViewModel()

    @State private var selectedURL: URL?
    @State private var layoutMode = LayoutMode.expanded
    @State private var showFilePicker = false

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

            // Windowing controls
            windowingControlsView

            Divider()

            // Settings panel
            settingsPanelView
                .padding()
                .background(panelBackgroundColor)
        }
        .navigationTitle("Windowing Controls")
#if os(iOS)
        .sheet(isPresented: $showFilePicker) {
            WindowingDocumentPicker { url in
                loadDICOMFile(from: url)
            }
        }
#endif
    }

    // MARK: - Image Display View

    /// Main image display area
    private var imageDisplayView: some View {
        Group {
            if selectedURL != nil {
                DicomImageView(viewModel: imageViewModel)
                    .accessibilityLabel("DICOM image with adjustable windowing")
            } else {
                placeholderView
            }
        }
    }

    /// Placeholder shown when no file is selected
    private var placeholderView: some View {
        VStack(spacing: 20) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No DICOM File Selected")
                .font(.title2)
                .foregroundColor(.primary)

            Text("Load a DICOM image to adjust window/level settings")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Select DICOM File") {
                selectDICOMFile()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .background(Color.black)
    }

    // MARK: - Windowing Controls View

    /// Windowing control panel
    private var windowingControlsView: some View {
        WindowingControlView(
            windowingViewModel: windowingViewModel,
            layout: layoutMode == .expanded ? .expanded : .compact,
            onPresetSelected: { preset in
                // Update image with selected preset
                Task {
                    await imageViewModel.updateWindowing(
                        windowingMode: .preset(preset),
                        processingMode: .auto
                    )
                }
            },
            onWindowingChanged: { settings in
                // Update image with custom window/level values
                Task {
                    await imageViewModel.updateWindowing(
                        windowingMode: .custom(
                            center: settings.center,
                            width: settings.width
                        ),
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
                Text("Click preset buttons to apply medical imaging presets (Lung, Bone, Brain, etc.)")
            }

            HStack(alignment: .top, spacing: 8) {
                Text("•")
                Text("Use sliders to adjust window center and width manually")
            }

            HStack(alignment: .top, spacing: 8) {
                Text("•")
                Text("Image updates in real-time as you adjust the controls")
            }

            HStack(alignment: .top, spacing: 8) {
                Text("•")
                Text("Try different layout modes: Expanded (full) or Compact (space-saving)")
            }
        }
    }

    /// Code example showing WindowingControlView usage
    private var codeExample: String {
        return """
        @StateObject var imageVM = DicomImageViewModel()
        @StateObject var windowingVM = WindowingViewModel()

        VStack {
            DicomImageView(viewModel: imageVM)

            WindowingControlView(
                windowingViewModel: windowingVM,
                onPresetSelected: { preset in
                    Task {
                        await imageVM.updateWindowing(
                            windowingMode: .preset(preset)
                        )
                    }
                },
                onWindowingChanged: { settings in
                    Task {
                        await imageVM.updateWindowing(
                            windowingMode: .custom(
                                center: settings.center,
                                width: settings.width
                            )
                        )
                    }
                }
            )
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

    /// Presents an open-file panel for choosing a single DICOM (.dcm) file, loads the selected file into the image view model using automatic windowing and auto processing, and syncs any resulting window settings to the windowing view model.
    /// Presents an open panel to choose a DICOM (*.dcm) file and loads the selected file into the image view model.
    /// 
    /// When a file is chosen, updates `selectedURL`, loads the image using automatic windowing and `.auto` processing, and, if the loaded image exposes current window settings, applies those settings to `windowingViewModel`.
    private func selectDICOMFile() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.init(filenameExtension: "dcm")!]
        panel.message = "Select a DICOM file (.dcm)"

        if panel.runModal() == .OK, let url = panel.url {
            loadDICOMFile(from: url)
        }
#elseif os(iOS)
        showFilePicker = true
#endif
    }

    private func loadDICOMFile(from url: URL) {
        selectedURL = url

        // Load the image with automatic windowing
        Task {
            await imageViewModel.loadImage(
                from: url,
                windowingMode: .automatic,
                processingMode: .auto
            )

            // Sync windowing view model with loaded image settings
            if let currentSettings = imageViewModel.currentWindowSettings {
                windowingViewModel.applySettings(currentSettings)
            }
        }
    }
}

#if os(iOS)
private struct WindowingDocumentPicker: UIViewControllerRepresentable {
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
struct WindowingExample_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            WindowingExample()
        }
    }
}
#endif
