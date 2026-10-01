//
//  DicomSwiftUIExampleApp.swift
//
//  Production-quality DICOM viewer example application
//
//  This app demonstrates a complete DICOM viewing workflow with file import,
//  study/series browsing, and interactive image viewing. It showcases the
//  DicomSwiftUI library components in a production-ready implementation,
//  including DicomImageView, WindowingControlView, SeriesNavigatorView,
//  and MetadataView integrated into a cohesive user experience.
//
//  Navigation Flow:
//  1. Import DICOM files from Files app or network shares
//  2. Browse studies with patient information
//  3. View series within studies
//  4. Interactive image viewing with pan/zoom/windowing gestures
//  5. Apply medical presets (lung, bone, brain, etc.)
//
//  Platform Availability:
//
//  iOS, visionOS, and macOS 26+ - Built with SwiftUI and DicomCore framework.
//

import SwiftUI

/// Main entry point for the DicomSwiftUI example application.
///
/// Provides a production-quality DICOM viewer demonstrating the complete
/// integration of the DicomSwiftUI library, from file import through
/// interactive image viewing with medical imaging controls.
///
/// The app starts with the study browser as the initial view, providing
/// immediate access to file import and study management functionality.
@main
struct DicomSwiftUIExampleApp: App {
    var body: some Scene {
        let windowGroup = WindowGroup {
            ContentView()
                .navigationTitle("DICOM Viewer")
        }

        #if os(macOS)
        return windowGroup
            .defaultSize(width: 1200, height: 800)
            .commands {
                // Add standard macOS menu commands
                CommandGroup(replacing: .newItem) {}
            }
        #else
        return windowGroup
        #endif
    }
}
