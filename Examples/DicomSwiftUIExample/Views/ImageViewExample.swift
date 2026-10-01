//
//  ImageViewExample.swift
//
//  Example demonstrating DicomImageView usage
//
//  This view demonstrates various ways to use DicomImageView for displaying
//  DICOM medical images, including automatic windowing, preset selection,
//  custom windowing, and GPU acceleration options.
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

/// Example view demonstrating DicomImageView usage.
///
/// Shows different initialization methods, windowing modes, and processing options
/// for displaying DICOM images in SwiftUI applications.
struct ImageViewExample: View {

    // MARK: - State

    @State private var selectedDemo = Demo.basic
    @State private var showFilePicker = false
    @State private var selectedURL: URL?

    // MARK: - Demo Options

    enum Demo: String, CaseIterable, Identifiable {
        case basic = "Basic Loading"
        case automatic = "Automatic Windowing"
        case lungPreset = "Lung Preset (CT)"
        case bonePreset = "Bone Preset (CT)"
        case brainPreset = "Brain Preset (MR)"
        case custom = "Custom Window/Level"
        case gpuAccelerated = "GPU Accelerated"

        var id: String { rawValue }

        var description: String {
            switch self {
            case .basic:
                return "Simple DicomImageView from URL with default settings"
            case .automatic:
                return "Automatic optimal window/level calculation"
            case .lungPreset:
                return "CT lung preset (C=-600, W=1500)"
            case .bonePreset:
                return "CT bone preset (C=400, W=1800)"
            case .brainPreset:
                return "MR brain preset (C=50, W=100)"
            case .custom:
                return "Custom window center and width values"
            case .gpuAccelerated:
                return "Force Metal GPU acceleration for large images"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Image display area
            imageDisplayView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            Divider()

            // Control panel
            controlPanelView
                .padding()
                .background(controlPanelBackgroundColor)
        }
        .navigationTitle("DicomImageView Examples")
#if os(iOS)
        .sheet(isPresented: $showFilePicker) {
            DICOMDocumentPicker { url in
                selectedURL = url
            }
        }
#endif
    }

    // MARK: - Image Display View

    /// Main image display area showing the selected demo
    private var imageDisplayView: some View {
        Group {
            if let url = selectedURL {
                demoImageView(for: selectedDemo, url: url)
            } else {
                placeholderView
            }
        }
    }

    /// Placeholder shown when no file is selected
    private var placeholderView: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No DICOM File Selected")
                .font(.title2)
                .foregroundColor(.primary)

            Text("Click 'Select DICOM File' to load an image")
                .font(.callout)
                .foregroundColor(.secondary)

            Button("Select DICOM File") {
                selectDICOMFile()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }

    /// Render a `DicomImageView` configured for the specified demo and DICOM file.
    /// - Parameters:
    ///   - demo: The demo mode that determines the image view's windowing and processing configuration.
    ///   - url: The file URL of the DICOM file to display.
    /// Provide a view that displays the given DICOM URL using the selected demo's windowing and processing configuration.
    /// - Parameters:
    ///   - demo: The demo mode selecting windowing preset, custom window/level, or GPU processing.
    ///   - url: The file URL of the DICOM to display.
    /// - Returns: A view that renders the DICOM image configured according to `demo`.
    @ViewBuilder
    private func demoImageView(for demo: Demo, url: URL) -> some View {
        switch demo {
        case .basic:
            // Example 1: Simple usage with URL
            DicomImageView(url: url)
                .accessibilityLabel("Basic DICOM image view")

        case .automatic:
            // Example 2: Automatic optimal windowing
            DicomImageView(
                url: url,
                windowingMode: .automatic
            )
            .accessibilityLabel("DICOM image with automatic windowing")

        case .lungPreset:
            // Example 3: CT lung preset
            DicomImageView(
                url: url,
                windowingMode: .preset(.lung)
            )
            .accessibilityLabel("DICOM image with lung preset")

        case .bonePreset:
            // Example 4: CT bone preset
            DicomImageView(
                url: url,
                windowingMode: .preset(.bone)
            )
            .accessibilityLabel("DICOM image with bone preset")

        case .brainPreset:
            // Example 5: MR brain preset
            DicomImageView(
                url: url,
                windowingMode: .preset(.brain)
            )
            .accessibilityLabel("DICOM image with brain preset")

        case .custom:
            // Example 6: Custom window/level values
            DicomImageView(
                url: url,
                windowingMode: .custom(center: 50.0, width: 400.0)
            )
            .accessibilityLabel("DICOM image with custom windowing")

        case .gpuAccelerated:
            // Example 7: Force GPU acceleration
            DicomImageView(
                url: url,
                windowingMode: .automatic,
                processingMode: .metal
            )
            .accessibilityLabel("DICOM image with GPU acceleration")
        }
    }

    // MARK: - Control Panel View

    /// Control panel with demo selection and file picker
    private var controlPanelView: some View {
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

            // Demo picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Demo Mode:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Demo", selection: $selectedDemo) {
                    ForEach(Demo.allCases) { demo in
                        Text(demo.rawValue).tag(demo)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Text(selectedDemo.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Code snippet
            if selectedURL != nil {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Code Example:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(codeExample(for: selectedDemo))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                        .padding(8)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                }
            }
        }
    }

    // MARK: - Helper Methods

    private var controlPanelBackgroundColor: Color {
#if os(macOS)
        return Color(NSColor.controlBackgroundColor)
#elseif os(iOS)
        return Color(UIColor.secondarySystemBackground)
#else
        return Color.secondary.opacity(0.1)
#endif
    }

    /// Return a Swift code snippet demonstrating how to construct a `DicomImageView` for the given demo.
    /// - Parameters:
    ///   - demo: The demo case for which to generate the example code.
    /// Generate a Swift code snippet that demonstrates initializing a `DicomImageView` for the specified demo mode.
    /// - Parameter demo: The demo mode to produce an example for.
    /// - Returns: A `String` containing a Swift code snippet that initializes `DicomImageView` configured for the selected `Demo`.
    private func codeExample(for demo: Demo) -> String {
        switch demo {
        case .basic:
            return """
            DicomImageView(url: dicomURL)
            """
        case .automatic:
            return """
            DicomImageView(
                url: dicomURL,
                windowingMode: .automatic
            )
            """
        case .lungPreset:
            return """
            DicomImageView(
                url: dicomURL,
                windowingMode: .preset(.lung)
            )
            """
        case .bonePreset:
            return """
            DicomImageView(
                url: dicomURL,
                windowingMode: .preset(.bone)
            )
            """
        case .brainPreset:
            return """
            DicomImageView(
                url: dicomURL,
                windowingMode: .preset(.brain)
            )
            """
        case .custom:
            return """
            DicomImageView(
                url: dicomURL,
                windowingMode: .custom(
                    center: 50.0,
                    width: 400.0
                )
            )
            """
        case .gpuAccelerated:
            return """
            DicomImageView(
                url: dicomURL,
                windowingMode: .automatic,
                processingMode: .metal
            )
            """
        }
    }

    /// Presents an open-file panel configured to select a single DICOM file (.dcm) and, if the user confirms, updates `selectedURL` with the chosen file URL.
    /// 
    /// Presents an open-file dialog restricted to `.dcm` files and updates `selectedURL` with the chosen file's URL.
    /// - Note: The panel allows selecting a single file (no directories or multiple selection).
    private func selectDICOMFile() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.init(filenameExtension: "dcm")!]
        panel.message = "Select a DICOM file (.dcm)"

        if panel.runModal() == .OK {
            selectedURL = panel.url
        }
#elseif os(iOS)
        showFilePicker = true
#endif
    }
}

#if os(iOS)
private struct DICOMDocumentPicker: UIViewControllerRepresentable {
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
struct ImageViewExample_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ImageViewExample()
        }
    }
}
#endif
