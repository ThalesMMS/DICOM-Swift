//
//  DicomSeriesViewer.swift
//  DicomSwiftUIExample
//
//  Interactive DICOM image viewer for viewing series images
//
//  This view provides a complete DICOM image viewing experience, combining
//  DicomImageView for rendering with InteractiveImageView for gesture controls.
//  It demonstrates best practices for medical image viewing including windowing
//  controls, preset application, and series navigation.
//
//  Platform Availability:
//
//  iOS, visionOS, and macOS 26+ - Built with SwiftUI and DicomSwiftUI components.
//

import SwiftUI
import DicomSwiftUI
import DicomCore

/// Interactive DICOM image viewer for series viewing.
///
/// Provides a complete medical image viewing experience with:
/// - Interactive pan, zoom, and windowing gestures
/// - Medical imaging presets (brain, chest, bone, etc.)
/// - Series navigation with slider
/// - Window/level controls
/// - Image metadata display
struct DicomSeriesViewer: View {

    // MARK: - Properties

    /// The series to display
    let series: SeriesInfo

    /// The parent study (for context)
    let study: ImportedStudy

    // MARK: - State

    @State private var currentImageIndex: Int = 0
    @State private var showingPresets = false
    @State private var selectedPreset: MedicalPreset = .abdomen
    @State private var windowSettings: WindowSettings?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Image viewer
            if series.imagePaths.isEmpty {
                emptyStateView
            } else {
                imageViewerContent
            }

            // Series navigation controls
            if series.numberOfImages > 1 {
                seriesNavigationControls
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                    .background(Color.secondary.opacity(0.1))
            }
        }
        .navigationTitle(series.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                presetsButton
            }
        }
        .sheet(isPresented: $showingPresets) {
            presetsSheet
        }
    }

    // MARK: - Image Viewer Content

    /// Main image viewer with gestures
    private var imageViewerContent: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                Color.black
                    .ignoresSafeArea()

                // DICOM image with interactive gestures
                if currentImageIndex < series.imagePaths.count {
                    let imagePath = series.imagePaths[currentImageIndex]

                    InteractiveImageView(
                        minScale: 0.5,
                        maxScale: 8.0,
                        windowSettings: windowSettings,
                        onWindowingChanged: { newSettings in
                            windowSettings = newSettings
                        }
                    ) {
                        DicomImageView(
                            url: URL(fileURLWithPath: imagePath),
                            windowingMode: windowingMode
                        )
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                // Image index overlay
                VStack {
                    HStack {
                        Spacer()

                        imageIndexLabel
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(8)
                            .padding()
                    }

                    Spacer()
                }
            }
        }
    }

    /// Empty state when no images available
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Images")
                .font(.title2)

            Text("This series does not contain any images")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Series Navigation Controls

    /// Navigation controls for multi-image series
    private var seriesNavigationControls: some View {
        VStack(spacing: 12) {
            // Slider for image selection
            HStack {
                Text("Image \(currentImageIndex + 1) of \(series.numberOfImages)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()
            }

            HStack(spacing: 16) {
                // Previous button
                Button(action: previousImage) {
                    Image(systemName: "chevron.left")
                        .font(.title3)
                }
                .disabled(currentImageIndex == 0)

                // Slider
                Slider(
                    value: Binding(
                        get: { Double(currentImageIndex) },
                        set: { currentImageIndex = Int($0) }
                    ),
                    in: 0...Double(series.numberOfImages - 1),
                    step: 1
                )

                // Next button
                Button(action: nextImage) {
                    Image(systemName: "chevron.right")
                        .font(.title3)
                }
                .disabled(currentImageIndex >= series.numberOfImages - 1)
            }
        }
    }

    // MARK: - Presets Controls

    /// Presets button for toolbar
    private var presetsButton: some View {
        Button(action: { showingPresets = true }) {
            Label("Presets", systemImage: "slider.horizontal.3")
        }
    }

    /// Presets selection sheet
    private var presetsSheet: some View {
        NavigationView {
            List {
                Section(header: Text("Windowing Presets")) {
                    ForEach(MedicalPreset.allCases, id: \.self) { preset in
                        Button(action: {
                            selectedPreset = preset
                            windowSettings = DCMWindowingProcessor.getPresetValuesV2(preset: preset)
                            showingPresets = false
                        }) {
                            HStack {
                                Text(preset.displayName)
                                    .foregroundColor(.primary)

                                Spacer()

                                if selectedPreset == preset {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }

                Section(header: Text("Current Settings")) {
                    if let settings = windowSettings {
                        HStack {
                            Text("Window Center:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(String(format: "%.1f", settings.center))
                                .font(.system(.body, design: .monospaced))
                        }

                        HStack {
                            Text("Window Width:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(String(format: "%.1f", settings.width))
                                .font(.system(.body, design: .monospaced))
                        }
                    } else {
                        Text("Auto-calculated from image")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Window Presets")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showingPresets = false
                    }
                }
            }
        }
    }

    // MARK: - Helper Views

    /// Image index label overlay
    private var imageIndexLabel: some View {
        Text("\(currentImageIndex + 1) / \(series.numberOfImages)")
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(.white)
    }

    // MARK: - Helper Properties

    /// Current windowing mode based on selection
    private var windowingMode: DicomImageRenderer.WindowingMode {
        if let settings = windowSettings {
            return .custom(center: settings.center, width: settings.width)
        } else {
            return .preset(selectedPreset)
        }
    }

    // MARK: - Helper Methods

    /// Navigate to previous image in series
    private func previousImage() {
        if currentImageIndex > 0 {
            currentImageIndex -= 1
        }
    }

    /// Navigate to next image in series
    private func nextImage() {
        if currentImageIndex < series.numberOfImages - 1 {
            currentImageIndex += 1
        }
    }
}

// MARK: - Previews

#if DEBUG
struct DicomSeriesViewer_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // Single image series
            NavigationView {
                DicomSeriesViewer(
                    series: SeriesInfo(
                        seriesInstanceUID: "1.2.3.4.5.1",
                        seriesNumber: 1,
                        seriesDescription: "Chest X-Ray",
                        modality: .dx,
                        numberOfImages: 1,
                        imagePaths: ["/path/to/image.dcm"]
                    ),
                    study: .sample
                )
            }
            .previewDisplayName("Single Image")

            // Multi-image series
            NavigationView {
                DicomSeriesViewer(
                    series: SeriesInfo(
                        seriesInstanceUID: "1.2.3.4.5.2",
                        seriesNumber: 2,
                        seriesDescription: "Chest CT",
                        modality: .ct,
                        numberOfImages: 150,
                        imagePaths: Array(repeating: "/path/to/image.dcm", count: 150)
                    ),
                    study: .sample
                )
            }
            .previewDisplayName("Multi-Image Series")

            // Empty series
            NavigationView {
                DicomSeriesViewer(
                    series: SeriesInfo(
                        seriesInstanceUID: "1.2.3.4.5.3",
                        seriesNumber: 3,
                        seriesDescription: "Empty Series",
                        modality: .ct,
                        numberOfImages: 0,
                        imagePaths: []
                    ),
                    study: .sample
                )
            }
            .previewDisplayName("Empty Series")
        }
    }
}
#endif
