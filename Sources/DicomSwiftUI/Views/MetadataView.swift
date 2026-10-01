//
//  MetadataView.swift
//
//  SwiftUI view for displaying DICOM metadata in a formatted list
//
//  This view provides a structured display of DICOM metadata tags organized
//  into logical sections (Patient, Study, Series, Image Properties). It uses
//  native SwiftUI components for optimal platform integration and automatically
//  formats DICOM values for human readability.
//
//  The view supports both List and Form presentation styles, making it suitable
//  for modal sheets, detail panels, or inline embedding. All metadata fields
//  include proper labels and accessibility support for VoiceOver.
//
//  Platform Availability:
//
//  Available on the package's iOS, visionOS, and macOS 26 deployment floor.
//  Uses native SwiftUI components for optimal performance and platform integration.
//
//  Accessibility:
//
//  All metadata fields include proper accessibility labels and values for
//  VoiceOver support. Section headers are marked with appropriate traits.
//

import SwiftUI
import DicomCore


/// A SwiftUI view for displaying DICOM metadata.
///
/// ## Overview
///
/// ``MetadataView`` provides a formatted display of DICOM metadata tags organized
/// into logical sections. It extracts and displays patient information, study details,
/// series information, and image properties from a `DicomDecoderProtocol` instance.
///
/// The view automatically handles missing or empty metadata fields by displaying
/// "N/A" fallback values. It supports both `.list` and `.form` presentation styles,
/// allowing seamless integration into different UI contexts.
///
/// **Key Features:**
/// - Organized metadata sections (Patient, Study, Series, Image)
/// - Automatic formatting of DICOM values
/// - Support for List and Form styles
/// - Dark mode support
/// - Full accessibility support for VoiceOver
/// - Handles missing metadata gracefully
///
/// **Displayed Metadata:**
/// - **Patient:** Name, ID, Sex, Age
/// - **Study:** Description, Date, Time, ID, Modality
/// - **Series:** Description, Number, Instance Count
/// - **Image:** Dimensions, Pixel Spacing, Bits, Window/Level
///
/// ## Usage
///
/// Display metadata in a List:
///
/// ```swift
/// struct ContentView: View {
///     let decoder: DCMDecoder
///
///     var body: some View {
///         MetadataView(decoder: decoder)
///     }
/// }
/// ```
///
/// Use Form style for settings-like appearance:
///
/// ```swift
/// MetadataView(decoder: decoder, style: .form)
///     .navigationTitle("DICOM Metadata")
/// ```
///
/// Embed in a modal sheet:
///
/// ```swift
/// struct DicomViewer: View {
///     @State private var showingMetadata = false
///     let decoder: DCMDecoder
///
///     var body: some View {
///         VStack {
///             DicomImageView(decoder: decoder)
///
///             Button("Show Metadata") {
///                 showingMetadata = true
///             }
///         }
///         .sheet(isPresented: $showingMetadata) {
///             NavigationView {
///                 MetadataView(decoder: decoder)
///                     .navigationTitle("Metadata")
///                     .inlineNavigationBarTitle()
///                     .toolbar {
///                         ToolbarItem(placement: .confirmationAction) {
///                             Button("Done") {
///                                 showingMetadata = false
///                             }
///                         }
///                     }
///             }
///         }
///     }
/// }
/// ```
///
/// Access specific sections:
///
/// ```swift
/// // Display only patient and study info
/// List {
///     let metadata = DicomMetadataAccessor(decoder: decoder)
///
///     Section(header: Text("Patient Information")) {
///         MetadataRow(label: "Name", value: metadata.string(.patientName, fallback: "N/A"))
///         MetadataRow(label: "ID", value: metadata.string(.patientID, fallback: "N/A"))
///     }
///
///     Section(header: Text("Study Information")) {
///         MetadataRow(label: "Description", value: metadata.string(.studyDescription, fallback: "N/A"))
///         MetadataRow(label: "Date", value: DicomDisplayFormatter.date(metadata.optionalString(.studyDate)))
///     }
/// }
/// ```
///
/// ### Customization
///
/// Apply standard SwiftUI modifiers:
/// - `.navigationTitle()` - Add title in navigation context
/// - `.navigationBarTitleDisplayMode()` - Configure title display
/// - `.toolbar()` - Add toolbar items
/// - `.background()` - Customize background color
///
/// ## Topics
///
/// ### Creating a View
///
/// - ``init(decoder:style:)``
///
/// ### Presentation Styles
///
/// - ``PresentationStyle``
///
public struct MetadataView: View {

    // MARK: - Presentation Style

    /// Presentation style for the metadata view.
    ///
    /// Controls the visual presentation of metadata sections. Both styles display
    /// the same metadata content but with different visual styling appropriate for
    /// their context.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // List style for browsing
    /// MetadataView(decoder: decoder, style: .list)
    ///
    /// // Form style for detail sheets
    /// MetadataView(decoder: decoder, style: .form)
    ///     .navigationTitle("Details")
    /// ```
    public enum PresentationStyle {
        /// Display in a standard List (scrollable, platform-native).
        ///
        /// Uses SwiftUI's `List` container with platform-native styling. Best for
        /// primary content views where metadata is the main focus. Provides standard
        /// list appearance with section headers and separators.
        case list

        /// Display in a Form (grouped style, better for settings/details).
        ///
        /// Uses SwiftUI's `Form` container with grouped styling. Best for modal sheets,
        /// detail panels, or settings-like interfaces. Provides inset grouped appearance
        /// on iOS and standard form styling on macOS.
        case form
    }

    // MARK: - Properties

    /// DICOM decoder containing metadata
    private let decoder: any DicomDecoderProtocol

    /// Presentation-layer accessor for extracting tag values.
    private let metadata: DicomMetadataAccessor

    /// Presentation style for the view
    private let style: PresentationStyle

    // MARK: - Initializers

    /// Creates a metadata view from a DICOM decoder.
    ///
    /// Displays formatted DICOM metadata organized into logical sections. The view
    /// automatically extracts patient, study, series, and image information from
    /// the decoder and presents it in a readable format.
    ///
    /// - Parameters:
    ///   - decoder: An initialized `DicomDecoderProtocol` with loaded DICOM file
    ///   - style: Presentation style (`.list` or `.form`). Defaults to `.list`
    ///
    /// ## Example
    ///
    /// ```swift
    /// struct MetadataScreen: View {
    ///     @State private var decoder: (any DicomDecoderProtocol)?
    ///     @State private var loadError: String?
    ///     let url: URL
    ///
    ///     var body: some View {
    ///         Group {
    ///             if let decoder = decoder {
    ///                 MetadataView(decoder: decoder, style: .form)
    ///                     .navigationTitle("DICOM Info")
    ///             } else if let loadError = loadError {
    ///                 Text("Failed to load metadata: \(loadError)")
    ///             } else {
    ///                 ProgressView("Loading metadata...")
    ///             }
    ///         }
    ///         .task(id: url) {
    ///             await loadDecoder()
    ///         }
    ///     }
    ///
    ///     private func loadDecoder() async {
    ///         do {
    ///             let loadedDecoder = try await DCMDecoder(contentsOfFile: url.path)
    ///             await MainActor.run {
    ///                 decoder = loadedDecoder
    ///                 loadError = nil
    ///             }
    ///         } catch {
    ///             await MainActor.run {
    ///                 decoder = nil
    ///                 loadError = error.localizedDescription
    ///             }
    ///         }
    ///     }
    /// }
    /// ```
    ///
    public init(decoder: any DicomDecoderProtocol, style: PresentationStyle = .list) {
        self.decoder = decoder
        self.metadata = DicomMetadataAccessor(decoder: decoder)
        self.style = style
    }

    // MARK: - Body

    public var body: some View {
        Group {
            if style == .form {
                Form {
                    metadataSections
                }
            } else {
                List {
                    metadataSections
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("DICOM Metadata")
    }

    // MARK: - Metadata Sections

    /// All metadata sections organized by category.
    ///
    /// Combines all four metadata sections (Patient, Study, Series, Image Properties)
    /// into a single view builder. Sections are displayed in a logical hierarchy
    /// from patient-level information down to image-specific properties.
    @ViewBuilder
    private var metadataSections: some View {
        MetadataPatientSection(metadata: metadata)
        MetadataStudySection(metadata: metadata)
        MetadataSeriesSection(metadata: metadata)
        MetadataImageSection(decoder: decoder, metadata: metadata)
    }
}

// MARK: - Metadata Row Component

/// A single metadata row with label, value, and optional icon.
///
/// Displays a metadata field as a horizontal row with left-aligned label, optional
/// SF Symbols icon, and right-aligned value. The value displays as "N/A" if missing
/// or empty. Includes proper accessibility labels for VoiceOver support.
///
/// ## Usage
///
/// ```swift
/// MetadataRow(
///     label: "Patient Name",
///     value: "John Doe",
///     icon: "person.fill"
/// )
/// ```
struct MetadataRow: View {
    /// The field label displayed on the left
    let label: String

    /// The field value displayed on the right (optional)
    let value: String?

    /// Optional SF Symbols icon name displayed before the label
    let icon: String?

    /// Creates a metadata row.
    ///
    /// - Parameters:
    ///   - label: The field label (e.g., "Patient Name")
    ///   - value: The field value (displays "N/A" if nil or empty)
    ///   - icon: Optional SF Symbols icon name
    init(label: String, value: String?, icon: String? = nil) {
        self.label = label
        self.value = value
        self.icon = icon
    }

    var body: some View {
        HStack {
            if let icon = icon {
                Image(systemName: icon)
                    .foregroundColor(.secondary)
                    .font(.body)
                    .frame(width: 24)
                    .accessibilityHidden(true)
            }

            Text(label)
                .foregroundColor(.primary)

            Spacer()

            Text(displayValue)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(displayValue)")
    }

    /// The display value, returning "N/A" for missing or empty values
    private var displayValue: String {
        if let value = value, !value.isEmpty {
            return value
        }
        return "N/A"
    }
}

// MARK: - Helper Extensions

private extension View {
    /// Applies inline navigation bar title display mode on iOS only.
    ///
    /// Convenience modifier that applies `.navigationBarTitleDisplayMode(.inline)` on iOS
    /// and does nothing on other platforms where this modifier is unavailable. Used in
    /// Applies an inline navigation bar title display mode on iOS; does nothing on other platforms.
    /// Applies an inline navigation bar title display mode on iOS; on other platforms the view is unchanged.
    /// - Returns: The view modified to use an inline navigation bar title display mode on iOS, or the original view on other platforms.
    @ViewBuilder
    func inlineNavigationBarTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

// MARK: - SwiftUI Previews

#if DEBUG
struct MetadataView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // List style with CT sample
            NavigationView {
                MetadataView(decoder: MetadataPreviewFixtures.ct, style: .list)
                    .navigationTitle("CT Scan Metadata")
                    .inlineNavigationBarTitle()
            }
            .previewDisplayName("List Style - CT")

            // Form style with MRI sample
            NavigationView {
                MetadataView(decoder: MetadataPreviewFixtures.mri, style: .form)
                    .navigationTitle("MRI Metadata")
                    .inlineNavigationBarTitle()
            }
            .previewDisplayName("Form Style - MRI")

            // X-Ray in dark mode
            NavigationView {
                MetadataView(decoder: MetadataPreviewFixtures.xray)
                    .navigationTitle("X-Ray Metadata")
                    .inlineNavigationBarTitle()
            }
            .preferredColorScheme(.dark)
            .previewDisplayName("Dark Mode - X-Ray")

            // Ultrasound in light mode
            NavigationView {
                MetadataView(decoder: MetadataPreviewFixtures.ultrasound)
                    .navigationTitle("Ultrasound Metadata")
                    .inlineNavigationBarTitle()
            }
            .preferredColorScheme(.light)
            .previewDisplayName("Light Mode - Ultrasound")

            // Minimal metadata (missing fields)
            NavigationView {
                MetadataView(decoder: MetadataPreviewFixtures.minimal)
                    .navigationTitle("DICOM Metadata")
                    .inlineNavigationBarTitle()
            }
            .previewDisplayName("Minimal Data")
        }
    }
}
#endif
