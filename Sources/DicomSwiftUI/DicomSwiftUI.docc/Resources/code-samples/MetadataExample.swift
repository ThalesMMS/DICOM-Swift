import SwiftUI
import DicomSwiftUI
import DicomCore
#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#endif

/// DocC Preface
/// - Platform support: iOS, visionOS, and macOS 26.0+.
/// - Recommended loading pattern: use `Task`/`.task` with `try await DCMDecoder(contentsOfFile:)`.
/// - Deprecated pattern: synchronous `DCMDecoder(contentsOf:)` / `DCMDecoder(contentsOfFile:)`.
/// - Migration hint: move decoder creation into an async function called from `.task`,
///   store the result in `@State`, and render loading/error states while awaiting I/O.

private extension View {
    @ViewBuilder
    func inlineNavigationBarTitle() -> some View {
#if os(iOS) || os(tvOS)
        self.navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }
}

// MARK: - Basic Metadata Display

/// Creates a simple example view that displays DICOM metadata from a local file.
/// 
/// The view attempts to initialize a `DCMDecoder` from the hard-coded file path and presents a `MetadataView` when successful. If decoder initialization fails, the view shows a `Text` describing the loading error.
/// Creates a view that displays DICOM metadata loaded from a local file or an error message if loading fails.
/// Creates a view that loads and displays DICOM metadata for a bundled sample file.
/// 
/// The returned view shows a standardized loading/error UI while the metadata is loaded,
/// and presents `MetadataView` when a decoder becomes available. The sample file path
/// used is "/path/to/ct_scan.dcm".
/// - Returns: A view that displays the metadata loading state and, on success, the decoded metadata.
func simpleMetadataDisplay() -> some View {
    struct SimpleMetadataView: View {
        let filePath: String
        @StateObject private var loader = AsyncDecoderLoader()

        var body: some View {
            DecoderLoadingView(
                loader: loader,
                loadingText: "Loading metadata...",
                errorPrefix: "Failed to load"
            ) { decoder in
                MetadataView(decoder: decoder)
            }
            .task(id: filePath) {
                await loader.load(filePath: filePath)
            }
        }
    }

    return SimpleMetadataView(filePath: "/path/to/ct_scan.dcm")
}

/// Presents DICOM metadata inside a navigation-style view.
/// 
/// Attempts to create a `DCMDecoder` from a bundled file and returns a view that displays `MetadataView` embedded in a `NavigationView` with the title "DICOM Metadata". If the decoder cannot be created, returns a `Text` view showing the error description.
/// Creates a NavigationView that displays DICOM metadata with the title "DICOM Metadata".
/// Creates a NavigationView that loads and displays DICOM metadata for a specific file.
/// The view shows a standardized loading indicator and error text while loading, and presents `MetadataView` when the decoder is available.
/// - Returns: A view containing a navigation-wrapped metadata viewer with built-in loading and error handling.
func metadataInNavigation() -> some View {
    struct MetadataNavigationView: View {
        let filePath: String
        @StateObject private var loader = AsyncDecoderLoader()

        var body: some View {
            NavigationView {
                DecoderLoadingView(
                    loader: loader,
                    loadingText: "Loading metadata...",
                    errorPrefix: "Error"
                ) { decoder in
                    MetadataView(decoder: decoder)
                }
                .navigationTitle("DICOM Metadata")
                .inlineNavigationBarTitle()
            }
            .task(id: filePath) {
                await loader.load(filePath: filePath)
            }
        }
    }

    return MetadataNavigationView(filePath: "/path/to/image.dcm")
}

// MARK: - Presentation Styles

/// Displays DICOM metadata in a form-style NavigationView.
/// 
/// Attempts to initialize a `DCMDecoder` from a bundled file and presents `MetadataView` with the `.form` style inside a `NavigationView`. If the decoder cannot be created, a `Text` view with an error message is returned.
/// Creates a NavigationView presenting DICOM metadata using a form-style layout.
/// Creates a view that presents DICOM metadata using a form-style layout.
///
/// The returned view is a `NavigationView` that asynchronously loads metadata for a sample DICOM file and displays it using `MetadataView` with `.form` presentation. Loading and error states are handled by `DecoderLoadingView`, and the navigation title is set to "DICOM Information".
/// - Returns: A view that loads and displays form-styled metadata for the sample file at "/path/to/mr_scan.dcm".
func formStyleMetadata() -> some View {
    struct FormMetadataView: View {
        let filePath: String
        @StateObject private var loader = AsyncDecoderLoader()

        var body: some View {
            NavigationView {
                DecoderLoadingView(
                    loader: loader,
                    loadingText: "Loading metadata...",
                    errorPrefix: "Error loading metadata"
                ) { decoder in
                    MetadataView(decoder: decoder, style: .form)
                }
                .navigationTitle("DICOM Information")
                .inlineNavigationBarTitle()
            }
            .task(id: filePath) {
                await loader.load(filePath: filePath)
            }
        }
    }

    return FormMetadataView(filePath: "/path/to/mr_scan.dcm")
}

/// Create a SwiftUI view that displays DICOM metadata using a list-style presentation.
/// Creates a navigation-wrapped view that displays DICOM metadata using a list-style presentation.
/// Creates a view that loads DICOM metadata and displays it using a list-style MetadataView.
/// The view presents standardized loading and error states via `DecoderLoadingView` and sets the navigation title to "Metadata".
/// - Returns: A view that loads metadata from a hard-coded file path and presents it inside a `NavigationView` with list-style metadata presentation.
func listStyleMetadata() -> some View {
    struct ListMetadataView: View {
        let filePath: String
        @StateObject private var loader = AsyncDecoderLoader()

        var body: some View {
            NavigationView {
                DecoderLoadingView(
                    loader: loader,
                    loadingText: "Loading metadata...",
                    errorPrefix: "Error loading metadata"
                ) { decoder in
                    MetadataView(decoder: decoder, style: .list)
                }
                .navigationTitle("Metadata")
            }
            .task(id: filePath) {
                await loader.load(filePath: filePath)
            }
        }
    }

    return ListMetadataView(filePath: "/path/to/image.dcm")
}

// MARK: - Modal Presentation

/// Presents a view that displays a DICOM image and lets the user open its metadata in a modal sheet.
/// 
/// The sheet contains a navigation-wrapped MetadataView for the same DICOM file and includes a Done button to dismiss it. The view is initialized with a built-in example DICOM file URL.
/// Display a DICOM image and present its metadata in a modal sheet.
/// Shows a DICOM image with a "Show Metadata" button that presents file metadata in a sheet.
/// 
/// When the sheet is presented, the view loads the DICOM metadata asynchronously and displays it
/// using a standardized loading/error wrapper and a `MetadataView`. The sheet includes a "Done"
/// toolbar button to dismiss it.
/// - Returns: A view that displays the DICOM image and, when the button is tapped, presents a sheet
///            that loads and shows the image's metadata.
func metadataModalSheet() -> some View {
    struct MetadataSheetView: View {
        @State private var showingMetadata = false
        @StateObject private var metadataLoader = AsyncDecoderLoader()
        let dicomURL: URL

        var body: some View {
            VStack {
                DicomImageView(url: dicomURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Button("Show Metadata") {
                    showingMetadata = true
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .sheet(isPresented: $showingMetadata) {
                NavigationView {
                    DecoderLoadingView(
                        loader: metadataLoader,
                        loadingText: "Loading metadata...",
                        errorPrefix: "Failed to load metadata"
                    ) { decoder in
                        MetadataView(decoder: decoder)
                    }
                    .navigationTitle("Metadata")
                    .inlineNavigationBarTitle()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                showingMetadata = false
                            }
                        }
                    }
                }
                .task(id: showingMetadata) {
                    guard showingMetadata else { return }
                    await metadataLoader.load(url: dicomURL)
                }
            }
        }
    }

    return MetadataSheetView(dicomURL: URL(fileURLWithPath: "/path/to/image.dcm"))
}

/// Displays a SwiftUI example that shows a DICOM image with an Info button which presents the image's metadata in a popover.
/// 
/// The view shows a DicomImageView and an "Info" button that opens a popover containing a form-styled MetadataView loaded from a decoder created for the bundled DICOM file.
/// Creates a view that shows a DICOM image with an "Info" button which presents the file's metadata in a popover.
/// 
/// The popover displays a form-styled `MetadataView` wrapped in a `NavigationView` titled "Info" and sized to 400×600.
/// Shows a DICOM image with an "Info" button that presents a popover containing the file's metadata.
/// The metadata is loaded when the popover is presented.
/// - Returns: A view containing a `DicomImageView` and an "Info" button that opens a popover with a metadata form.
func metadataPopover() -> some View {
    struct MetadataPopoverView: View {
        @State private var showingMetadata = false
        @StateObject private var metadataLoader = AsyncDecoderLoader()
        let dicomURL: URL

        var body: some View {
            VStack {
                DicomImageView(url: dicomURL)

                Button("Info") {
                    showingMetadata = true
                }
                .buttonStyle(.bordered)
                .padding()
                .popover(isPresented: $showingMetadata) {
                    DecoderLoadingView(
                        loader: metadataLoader,
                        loadingText: "Loading metadata...",
                        errorPrefix: "Error"
                    ) { decoder in
                        NavigationView {
                            MetadataView(decoder: decoder, style: .form)
                                .navigationTitle("Info")
                                .inlineNavigationBarTitle()
                        }
                    }
                    .frame(width: 400, height: 600)
                }
            }
            .task(id: showingMetadata) {
                guard showingMetadata else { return }
                await metadataLoader.load(url: dicomURL)
            }
        }
    }

    return MetadataPopoverView(dicomURL: URL(fileURLWithPath: "/path/to/ct_scan.dcm"))
}

// MARK: - Integrated Viewers

/// Creates a tabbed SwiftUI view that displays a DICOM image alongside its metadata.
/// 
/// The view presents two tabs: an image viewer that loads the DICOM pixel data and a metadata viewer that initializes a decoder from the same DICOM file.
/// Creates a tabbed view that presents a DICOM image alongside its metadata.
/// 
/// The view has two tabs: an Image tab that shows a DICOM image preview and a Metadata tab that displays the file's metadata.
/// The Metadata tab is shown only if metadata can be loaded from the file URL used to initialize the view model.
/// Presents a tabbed viewer that shows a DICOM image and its extracted metadata.
/// 
/// The view contains two tabs — an Image tab that displays the rendered DICOM image and a Metadata tab that shows parsed DICOM metadata. When the view appears (or when the underlying DICOM URL changes), it loads the image and metadata asynchronously.
/// - Returns: A SwiftUI view composed of the image and metadata tabs.
func integratedMetadataViewer() -> some View {
    struct IntegratedViewer: View {
        @StateObject private var imageVM = DicomImageViewModel()
        @StateObject private var metadataLoader = AsyncDecoderLoader()
        @State private var selectedTab = 0
        let dicomURL: URL

        var body: some View {
            TabView(selection: $selectedTab) {
                // Image tab
                DicomImageView(viewModel: imageVM)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .tabItem {
                        Label("Image", systemImage: "photo")
                    }
                    .tag(0)

                // Metadata tab
                DecoderLoadingView(
                    loader: metadataLoader,
                    loadingText: "Loading metadata...",
                    errorPrefix: "Error"
                ) { decoder in
                    MetadataView(decoder: decoder)
                }
                .tabItem {
                    Label("Metadata", systemImage: "info.circle")
                }
                .tag(1)
            }
            .task(id: dicomURL) {
                await imageVM.loadImage(from: dicomURL)
                await metadataLoader.load(url: dicomURL)
            }
        }
    }

    return IntegratedViewer(dicomURL: URL(fileURLWithPath: "/path/to/image.dcm"))
}

/// Displays a responsive split/stack layout showing a DICOM image alongside its metadata.
///
/// On macOS the view uses a horizontal split with the image on the left and a fixed-width metadata pane on the right. On compact platforms the layout adapts: for widths greater than 600 points it shows a 60/40 horizontal layout, otherwise it stacks the image above the metadata with each occupying half the height. While visible the view loads the image and metadata for the configured DICOM URL and presents the metadata using a form-style pane in side-by-side layouts and a list-style pane in stacked layouts.
/// - Returns: A view containing the adaptive image + metadata UI that loads and displays the DICOM image and its metadata.
func splitViewMetadata() -> some View {
    struct SplitViewMetadata: View {
        @StateObject private var imageVM = DicomImageViewModel()
        @StateObject private var metadataLoader = AsyncDecoderLoader()
        let dicomURL: URL

        var body: some View {
            #if os(macOS)
            HSplitView {
                // Left: Image
                DicomImageView(viewModel: imageVM)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Right: Metadata
                metadataPane(style: .form)
                    .frame(width: 350)
            }
            #else
            // iOS: Use side-by-side layout for larger screens
            GeometryReader { geometry in
                if geometry.size.width > 600 {
                    HStack(spacing: 0) {
                        DicomImageView(viewModel: imageVM)
                            .frame(width: geometry.size.width * 0.6)

                        metadataPane(style: .form)
                            .frame(width: geometry.size.width * 0.4)
                    }
                } else {
                    // Portrait: Stacked layout
                    VStack(spacing: 0) {
                        DicomImageView(viewModel: imageVM)
                            .frame(height: geometry.size.height * 0.5)

                        metadataPane(style: .list)
                            .frame(height: geometry.size.height * 0.5)
                    }
                }
            }
            #endif
            .task(id: dicomURL) {
                await imageVM.loadImage(from: dicomURL)
                await metadataLoader.load(url: dicomURL)
            }
        }

        /// Creates a metadata pane that displays a loader/error state and, when available, the metadata rendered in the given presentation style.
        /// - Parameter style: The `MetadataView.PresentationStyle` used to present the metadata (for example, `.list` or `.form`).
        @ViewBuilder
        private func metadataPane(style: MetadataView.PresentationStyle) -> some View {
            DecoderLoadingView(
                loader: metadataLoader,
                loadingText: "Loading metadata...",
                errorPrefix: "Error"
            ) { decoder in
                MetadataView(decoder: decoder, style: style)
            }
        }
    }

    return SplitViewMetadata(dicomURL: URL(fileURLWithPath: "/path/to/ct_scan.dcm"))
}

// MARK: - Custom Metadata Display

/// Displays a navigation-wrapped list showing selected DICOM metadata fields (Patient, Study, Image) extracted from a local DCM file.
/// Displays selected DICOM metadata fields grouped into Patient, Study, and Image sections, loading a decoder from a bundled DCM file.
/// 
/// The view shows Patient Name and ID, Study Description and Modality, and Image Dimensions and Bit Depth. If the decoder fails to initialize from the file path, a `Text` view containing the error message is returned.
/// Displays selected DICOM metadata organized into Patient, Study, and Image sections.
/// The returned view loads metadata asynchronously from a fixed file path and presents patient name and ID, study description and modality, and image dimensions and bit depth in a navigable list.
/// - Returns: A view configured to load the DICOM file at "/path/to/image.dcm" and display the extracted metadata.
func customMetadataFields() -> some View {
    struct CustomMetadataView: View {
        let decoder: DCMDecoder

        var body: some View {
            List {
                let metadata = DicomMetadataAccessor(decoder: decoder)

                Section(header: Text("Patient")) {
                    MetadataRow(label: "Name", value: metadata.string(.patientName, fallback: "N/A"))
                    MetadataRow(label: "ID", value: metadata.string(.patientID, fallback: "N/A"))
                }

                Section(header: Text("Study")) {
                    MetadataRow(label: "Description", value: metadata.string(.studyDescription, fallback: "N/A"))
                    MetadataRow(label: "Modality", value: DicomDisplayFormatter.modality(metadata.optionalString(.modality)))
                }

                Section(header: Text("Image")) {
                    MetadataRow(label: "Dimensions", value: "\(decoder.width) × \(decoder.height)")
                    MetadataRow(label: "Bit Depth", value: "\(decoder.bitDepth) bits")
                }
            }
            .navigationTitle("DICOM Info")
        }
    }

    struct AsyncCustomMetadataView: View {
        let filePath: String
        @StateObject private var loader = AsyncDecoderLoader()

        var body: some View {
            NavigationView {
                DecoderLoadingView(
                    loader: loader,
                    loadingText: "Loading metadata...",
                    errorPrefix: "Error"
                ) { decoder in
                    CustomMetadataView(decoder: decoder)
                }
                .navigationTitle("DICOM Info")
            }
            .task(id: filePath) {
                await loader.load(filePath: filePath)
            }
        }
    }

    return AsyncCustomMetadataView(filePath: "/path/to/image.dcm")
}

// MARK: - Searchable Metadata

/// Presents a navigation-wrapped DICOM metadata viewer with a searchable interface and asynchronous loading.
/// Metadata is loaded via `AsyncDecoderLoader` for the file path "/path/to/image.dcm", and loading/error states are handled by `DecoderLoadingView`.
/// - Returns: A view that loads DICOM metadata and presents it with a search UI, including standardized loading and error handling.
func searchableMetadata() -> some View {
    struct SearchableMetadataView: View {
        @State private var searchText = ""
        let decoder: DCMDecoder

        var body: some View {
            NavigationView {
                MetadataView(decoder: decoder)
                    .searchable(text: $searchText, prompt: "Search metadata")
                    .navigationTitle("Metadata")
            }
        }
    }

    struct AsyncSearchableMetadataView: View {
        let filePath: String
        @StateObject private var loader = AsyncDecoderLoader()

        var body: some View {
            DecoderLoadingView(
                loader: loader,
                loadingText: "Loading metadata...",
                errorPrefix: "Error loading metadata"
            ) { decoder in
                SearchableMetadataView(decoder: decoder)
            }
            .task(id: filePath) {
                await loader.load(filePath: filePath)
            }
        }
    }

    return AsyncSearchableMetadataView(filePath: "/path/to/image.dcm")
}

// MARK: - Export Metadata

/// Displays DICOM metadata and provides an export action that shares a generated text summary.
///
/// - A view showing the MetadataView for a DCMDecoder with a toolbar export button that presents a share sheet containing a plain-text export of patient, study, and image properties.
/// Presents the export/share sheet by setting its presentation state to true.
/// - Returns: `"No metadata loaded."` if no decoder is available; otherwise a formatted plain-text string containing Patient Information, Study Information, and Image Properties.
func exportableMetadata() -> some View {
    struct ExportableMetadataView: View {
        @State private var showingExportSheet = false
        @StateObject private var loader = AsyncDecoderLoader()
        let filePath: String

        var body: some View {
            NavigationView {
                DecoderLoadingView(
                    loader: loader,
                    loadingText: "Loading metadata...",
                    errorPrefix: "Error loading metadata"
                ) { decoder in
                    MetadataView(decoder: decoder)
                }
                .navigationTitle("Metadata")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: exportMetadata) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(loader.decoder == nil)
                    }
                }
                .sheet(isPresented: $showingExportSheet) {
                    ShareSheet(items: [generateMetadataText()])
                }
            }
            .task(id: filePath) {
                await loader.load(filePath: filePath)
            }
        }

        /// Triggers display of the export sheet.
        /// 
        /// Triggers presentation of the export/share sheet by setting the export sheet state to `true`.
        private func exportMetadata() {
            showingExportSheet = true
        }

        /// Builds a plain-text DICOM metadata summary suitable for sharing.
        /// Builds a plain-text summary of the decoder's patient, study, and image metadata suitable for export.
        /// Produces a plain-text export of the currently loaded DICOM metadata.
        /// If no metadata is loaded, returns a user-facing fallback message.
        /// - Returns: A formatted plain-text string containing patient information, study information, and image properties, or `"No metadata loaded."` when no decoder is available.
        private func generateMetadataText() -> String {
            guard let decoder = loader.decoder else {
                return "No metadata loaded."
            }

            var text = "DICOM Metadata Export\n"
            text += "====================\n\n"

            let metadata = DicomMetadataAccessor(decoder: decoder)

            text += "Patient Information:\n"
            text += "  Name: \(metadata.string(.patientName, fallback: "N/A"))\n"
            text += "  ID: \(metadata.string(.patientID, fallback: "N/A"))\n"
            text += "  Sex: \(DicomDisplayFormatter.sex(metadata.optionalString(.patientSex)))\n"
            text += "  Age: \(metadata.string(.patientAge, fallback: "N/A"))\n\n"

            text += "Study Information:\n"
            text += "  Description: \(metadata.string(.studyDescription, fallback: "N/A"))\n"
            text += "  Date: \(DicomDisplayFormatter.date(metadata.optionalString(.studyDate)))\n"
            text += "  Modality: \(DicomDisplayFormatter.modality(metadata.optionalString(.modality)))\n\n"

            text += "Image Properties:\n"
            text += "  Dimensions: \(decoder.width) × \(decoder.height)\n"
            text += "  Bit Depth: \(decoder.bitDepth)\n"

            return text
        }
    }

    return ExportableMetadataView(filePath: "/path/to/ct_scan.dcm")
}

// MARK: - Metadata with Series Navigation

/// Demonstrates a DICOM series viewer with navigation and per-slice metadata display.
/// 
/// Shows a DicomImageView with a series navigator and a button that presents a sheet containing the metadata for the currently selected slice. The view updates the displayed image and associated metadata when the user navigates the series.
/// - Returns: A SwiftUI view configured with a sample series of slice URLs that provides image navigation and a metadata sheet for the current slice.
func metadataWithSeriesNavigation() -> some View {
    struct MetadataSeriesView: View {
        @StateObject private var navigatorVM = SeriesNavigatorViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        @State private var currentDecoder: DCMDecoder?
        @State private var showingMetadata = false
        let seriesURLs: [URL]

        var body: some View {
            VStack {
                DicomImageView(viewModel: imageVM)

                SeriesNavigatorView(
                    navigatorViewModel: navigatorVM,
                    onNavigate: { url in
                        Task {
                            await loadImageAndMetadata(url: url)
                        }
                    }
                )

                Button("Show Current Slice Metadata") {
                    showingMetadata = true
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .disabled(currentDecoder == nil)
            }
            .onAppear {
                navigatorVM.setSeriesURLs(seriesURLs)
                if let firstURL = navigatorVM.currentURL {
                    Task {
                        await loadImageAndMetadata(url: firstURL)
                    }
                }
            }
            .sheet(isPresented: $showingMetadata) {
                if let decoder = currentDecoder {
                    NavigationView {
                        MetadataView(decoder: decoder)
                            .navigationTitle("Slice \(navigatorVM.currentIndex + 1) Metadata")
                            .inlineNavigationBarTitle()
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") {
                                        showingMetadata = false
                                    }
                                }
                            }
                    }
                }
            }
        }

        /// Loads a DICOM decoder from the given URL, updates `currentDecoder`, and tells the image view model to load the corresponding image.
        /// Loads DICOM metadata and image from the given file URL, updates `currentDecoder`, and instructs the image view model to load the image.
        /// - Parameter url: File URL pointing to a DICOM file to load.
        private func loadImageAndMetadata(url: URL) async {
            do {
                let decoder = try await DCMDecoder(contentsOfFile: url.path)
                await MainActor.run {
                    currentDecoder = decoder
                }
                await imageVM.loadImage(decoder: decoder)
            } catch {
                print("Error loading image: \(error)")
            }
        }
    }

    let urls = (1...50).map { URL(fileURLWithPath: "/path/to/series/slice\($0).dcm") }
    return MetadataSeriesView(seriesURLs: urls)
}

// MARK: - Comparison View

/// Presents a side-by-side UI that loads and compares metadata from two DICOM files.
///
/// The returned view concurrently loads both files, shows a loading indicator while fetching, displays an error message on failure, and presents a list comparing Patient Name, Study Date, and image Dimensions when both decoders are available. Differences between the two files are highlighted in red; matching values use a secondary color.
/// - Returns: A view that compares selected metadata values from two DICOM files.
func compareMetadata() -> some View {
    struct CompareMetadataView: View {
        let url1: URL
        let url2: URL
        @State private var decoder1: DCMDecoder?
        @State private var decoder2: DCMDecoder?
        @State private var isLoading = true
        @State private var loadError: String?

        var body: some View {
            NavigationView {
                Group {
                    if isLoading {
                        ProgressView("Loading metadata...")
                    } else if let loadError = loadError {
                        Text("Error comparing metadata: \(loadError)")
                            .multilineTextAlignment(.center)
                            .padding()
                    } else if let decoder1 = decoder1, let decoder2 = decoder2 {
                        List {
                            Section(header: Text("Patient Name")) {
                                MetadataRow(label: "Image 1", value: displayValue(decoder1.info(for: .patientName)))
                                MetadataRow(
                                    label: "Image 2",
                                    value: displayValue(decoder2.info(for: .patientName)),
                                    valueColor: decoder1.info(for: .patientName) == decoder2.info(for: .patientName)
                                    ? .secondary : .red
                                )
                            }

                            Section(header: Text("Study Date")) {
                                MetadataRow(label: "Image 1", value: displayValue(decoder1.info(for: .studyDate)))
                                MetadataRow(
                                    label: "Image 2",
                                    value: displayValue(decoder2.info(for: .studyDate)),
                                    valueColor: decoder1.info(for: .studyDate) == decoder2.info(for: .studyDate)
                                    ? .secondary : .red
                                )
                            }

                            Section(header: Text("Dimensions")) {
                                MetadataRow(label: "Image 1", value: "\(decoder1.width) × \(decoder1.height)")
                                MetadataRow(
                                    label: "Image 2",
                                    value: "\(decoder2.width) × \(decoder2.height)",
                                    valueColor: decoder1.width == decoder2.width && decoder1.height == decoder2.height
                                    ? .secondary : .red
                                )
                            }
                        }
                    } else {
                        Text("No metadata available.")
                    }
                }
                .navigationTitle("Compare Metadata")
            }
            .task(id: "\(url1.path)|\(url2.path)") {
                await loadDecoders()
            }
        }

        private func loadDecoders() async {
            await MainActor.run {
                isLoading = true
                loadError = nil
                decoder1 = nil
                decoder2 = nil
            }

            do {
                async let first = DCMDecoder(contentsOfFile: url1.path)
                async let second = DCMDecoder(contentsOfFile: url2.path)
                let (loadedDecoder1, loadedDecoder2) = try await (first, second)

                await MainActor.run {
                    decoder1 = loadedDecoder1
                    decoder2 = loadedDecoder2
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                    isLoading = false
                }
            }
        }

        private func displayValue(_ value: String) -> String {
            value.isEmpty ? "N/A" : value
        }
    }

    return CompareMetadataView(
        url1: URL(fileURLWithPath: "/path/to/image1.dcm"),
        url2: URL(fileURLWithPath: "/path/to/image2.dcm")
    )
}

// MARK: - Complete Metadata Application

/// Builds a sample SwiftUI view showcasing a DICOM image preview, a segmented picker to choose metadata presentation style (List or Form), and metadata sections with key information and full details, plus a toolbar export action.
/// Presents a complete metadata exploration UI combining an image preview, a presentation-style picker, metadata display, and metadata export.
/// 
/// The view displays a DICOM image preview, lets the user choose between list and form presentation for metadata, shows key information and full metadata sections extracted from the DICOM file, and provides a toolbar action to export the metadata.
/// - Returns: A view containing the "Key Information" and "All Details" sections; missing values are displayed as `"N/A"`.
func completeMetadataApp() -> some View {
    struct CompleteMetadataApp: View {
        @StateObject private var imageVM = DicomImageViewModel()
        @StateObject private var metadataLoader = AsyncDecoderLoader()
        @State private var presentationStyle: MetadataView.PresentationStyle = .list
        @State private var showingExport = false
        let dicomURL: URL

        var body: some View {
            NavigationView {
                VStack(spacing: 0) {
                    // Image preview
                    DicomImageView(viewModel: imageVM)
                        .frame(height: 250)
                        .background(Color.black)

                    // Style picker
                    Picker("Style", selection: $presentationStyle) {
                        Text("List").tag(MetadataView.PresentationStyle.list)
                        Text("Form").tag(MetadataView.PresentationStyle.form)
                    }
                    .pickerStyle(.segmented)
                    .padding()

                    // Metadata display
                    if let metadataDecoder = metadataLoader.decoder {
                        if presentationStyle == .form {
                            Form {
                                metadataSections(for: metadataDecoder)
                            }
                        } else {
                            List {
                                metadataSections(for: metadataDecoder)
                            }
                        }
                    } else if let metadataLoadError = metadataLoader.loadError {
                        Text("Error loading metadata: \(metadataLoadError)")
                            .padding()
                    } else {
                        ProgressView("Loading metadata...")
                    }
                }
                .navigationTitle("DICOM Analysis")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button(action: { showingExport = true }) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(metadataLoader.decoder == nil)

                    }
                }
            }
            .task(id: dicomURL) {
                await imageVM.loadImage(from: dicomURL)
                await metadataLoader.load(url: dicomURL)
            }
            .sheet(isPresented: $showingExport) {
                ShareSheet(items: [generateMetadataText()])
            }
        }

        /// Builds two view sections displaying selected DICOM metadata and a full-details metadata view when available.
        /// 
        /// The first section shows key information (Patient, Study, Modality) extracted from the provided decoder; missing values are shown as "N/A". The second section attempts to load a full decoder from `dicomURL` and, if successful, embeds a `MetadataView` using the current presentation style.
        /// Builds two grouped sections: a "Key Information" section showing selected patient, study, and modality fields from the provided decoder, and an "All Details" section that attempts to load and display the full metadata using the file at `dicomURL`.
        /// - Parameter decoder: The `DCMDecoder` used to populate the "Key Information" rows.
        /// Builds two metadata sections for the given decoder: a "Key Information" section with selected fields and an "All Details" section containing the full metadata view.
        /// - Parameter decoder: The `DCMDecoder` whose metadata will be displayed.
        /// - Returns: A view containing the "Key Information" and "All Details" sections for the provided decoder.
        @ViewBuilder
        private func metadataSections(for decoder: DCMDecoder) -> some View {
            Section(header: Text("Key Information")) {
                let metadata = DicomMetadataAccessor(decoder: decoder)
                MetadataRow(label: "Patient", value: metadata.string(.patientName, fallback: "N/A"))
                MetadataRow(label: "Study", value: metadata.string(.studyDescription, fallback: "N/A"))
                MetadataRow(label: "Modality", value: DicomDisplayFormatter.modality(metadata.optionalString(.modality)))
            }

            Section(header: Text("All Details")) {
                MetadataView(decoder: decoder, style: presentationStyle)
            }
        }

        private func generateMetadataText() -> String {
            guard let decoder = metadataLoader.decoder else {
                return "No metadata loaded."
            }

            var text = "DICOM Metadata Export\n"
            text += "====================\n\n"
            let metadata = DicomMetadataAccessor(decoder: decoder)
            text += "Patient: \(metadata.string(.patientName, fallback: "N/A"))\n"
            text += "Study: \(metadata.string(.studyDescription, fallback: "N/A"))\n"
            text += "Modality: \(DicomDisplayFormatter.modality(metadata.optionalString(.modality)))\n"
            text += "Dimensions: \(decoder.width) × \(decoder.height)\n"
            text += "Bit Depth: \(decoder.bitDepth)\n"
            return text
        }
    }

    return CompleteMetadataApp(dicomURL: URL(fileURLWithPath: "/path/to/ct_scan.dcm"))
}

// MARK: - Async Metadata Loading

/// Presents a SwiftUI example view that loads DICOM metadata asynchronously and displays it when ready.
/// Loads DICOM metadata from `dicomURL` and updates the view state accordingly.
/// 
/// Requests the view's `AsyncDecoderLoader` to load DICOM metadata from `dicomURL`.
/// - Note: On completion the loader's observable properties (`decoder`, `isLoading`, `error`) are updated to reflect the load result.
func asyncMetadataLoading() -> some View {
    struct AsyncMetadataView: View {
        @StateObject private var loader = AsyncDecoderLoader()
        let dicomURL: URL

        var body: some View {
            NavigationView {
                Group {
                    if loader.isLoading && loader.decoder == nil {
                        VStack(spacing: 16) {
                            ProgressView()
                            Text("Loading metadata...")
                                .foregroundColor(.secondary)
                        }
                    } else if let error = loader.error {
                        VStack(spacing: 16) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundColor(.red)

                            Text("Failed to load metadata")
                                .font(.headline)

                            Text(error.localizedDescription)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                    } else if let decoder = loader.decoder {
                        MetadataView(decoder: decoder)
                    } else {
                        ProgressView("Loading metadata...")
                    }
                }
                .navigationTitle("DICOM Metadata")
            }
            .task {
                await loadMetadata()
            }
        }

        /// Loads a DICOM decoder from `dicomURL` and updates the view state.
        ///
        /// Asynchronously loads DICOM metadata from `dicomURL` and updates the view state.
        /// 
        /// Initiates loading of DICOM metadata for the view's `dicomURL` into the shared decoder loader.
        private func loadMetadata() async {
            await loader.load(url: dicomURL)
        }
    }

    return AsyncMetadataView(dicomURL: URL(fileURLWithPath: "/path/to/large_image.dcm"))
}
