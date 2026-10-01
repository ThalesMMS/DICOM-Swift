import SwiftUI
import DicomSwiftUI
import DicomCore

// Configure this path to point to a directory containing DICOM files.
private let exampleSeriesPath = "/path/to/your/dicom/series"

private func exampleSeriesPath(named name: String) -> String {
    "\(exampleSeriesPath)/\(name)"
}

// MARK: - Basic Series Navigation

/// Presents a simple series viewer composed of a DicomImageView and a SeriesNavigatorView.
///
/// Requires iOS, visionOS, or macOS 26+ because it relies on SwiftUI concurrency and async/await. The view displays the current DICOM image and loads a selected slice into the image view when navigation occurs; it is initialized with 100 sample slice URLs.
/// - Returns: A view containing a DicomImageView and a SeriesNavigatorView wired to load selected images.
func basicSeriesNavigation() -> some View {
    struct BasicSeriesView: View {
        @StateObject private var navigatorVM = SeriesNavigatorViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        let seriesURLs: [URL]

        var body: some View {
            VStack {
                // Display current image
                DicomImageView(viewModel: imageVM)

                // Navigation controls
                SeriesNavigatorView(
                    navigatorViewModel: navigatorVM,
                    onNavigate: { url in
                        Task {
                            await imageVM.loadImage(from: url)
                        }
                    }
                )
            }
            .loadInitialSeries(seriesURLs, navigatorVM: navigatorVM, imageVM: imageVM)
        }
    }

    // BasicSeriesView expects URLs for files that exist on disk.
    let urls = makeSampleSliceURLs(count: 100, seriesPath: exampleSeriesPath)
    return BasicSeriesView(seriesURLs: urls)
}

/// A compact example view that displays a DICOM image alongside a compact series navigator.
/// 
/// The view shows a DicomImageView above a compact SeriesNavigatorView. It initializes the navigator with a set of 50 sample series URLs, loads the first image on appear, and loads the selected image whenever the navigator changes selection.
/// Creates a compact SwiftUI example view that displays a DICOM image alongside a compact series navigator.
/// 
/// The view initializes a SeriesNavigatorViewModel and DicomImageViewModel, sets the navigator with a prebuilt set of 50 sample slice URLs on appear, and loads the first image if available. Tapping or navigating in the navigator loads the selected slice into the image view.
/// Creates a view demonstrating a compact series navigator paired with a DICOM image view.
///
/// The view displays a fixed-height DICOM image above a compact-style series navigator; selecting an item in the navigator loads that slice into the image view. The navigator is initialized with 50 sample URLs.
/// - Returns: A view containing the DICOM image and a compact series navigator preloaded with sample series URLs.
func compactSeriesNavigator() -> some View {
    struct CompactSeriesView: View {
        @StateObject private var navigatorVM = SeriesNavigatorViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        let seriesURLs: [URL]

        var body: some View {
            VStack(spacing: 8) {
                DicomImageView(viewModel: imageVM)
                    .frame(height: 400)

                SeriesNavigatorView(
                    navigatorViewModel: navigatorVM,
                    layout: .compact,
                    onNavigate: { url in
                        Task {
                            await imageVM.loadImage(from: url)
                        }
                    }
                )
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            }
            .loadInitialSeries(seriesURLs, navigatorVM: navigatorVM, imageVM: imageVM)
        }
    }

    let urls = makeSampleSliceURLs(count: 50, seriesPath: exampleSeriesPath)
    return CompactSeriesView(seriesURLs: urls)
}

// MARK: - Loading Series from Directory

/// Creates a view that loads a DICOM series from a local directory and presents it with navigation.
/// 
/// The view scans a predefined directory for files with `.dcm` or `.dicom` extensions, displays a loading indicator while the directory is being read, loads the first image found, and provides a series navigator to load other images in the series.
/// - Returns: A SwiftUI view that loads DICOM files from a local directory, shows a loading state while scanning, and displays the first image along with a series navigator.
func loadSeriesFromDirectory() -> some View {
    struct DirectorySeriesView: View {
        @StateObject private var navigatorVM = SeriesNavigatorViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        @State private var isLoading = true
        let directoryURL: URL

        var body: some View {
            VStack {
                if isLoading {
                    ProgressView("Loading series...")
                } else {
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
            }
            .task {
                await loadSeriesFromDirectory()
            }
        }

        /// Loads DICOM files from `directoryURL`, populates the series navigator, and loads the first image if available.
        ///
        /// The method scans `directoryURL` for files with `.dcm` or `.dicom` extensions, sorts them by filename, and calls `navigatorVM.setSeriesURLs(_:)` with the resulting URLs. If a first URL is available it requests `imageVM` to load that image. The `isLoading` flag is cleared when the operation finishes or if an error occurs; errors are logged to the console.
        private func loadSeriesFromDirectory() async {
            do {
                let fileManager = FileManager.default
                let files = try fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: nil
                )

                // Filter DICOM files
                let dicomFiles = files.filter {
                    $0.pathExtension.lowercased() == "dcm" ||
                    $0.pathExtension.lowercased() == "dicom"
                }.sorted { $0.lastPathComponent < $1.lastPathComponent }

                navigatorVM.setSeriesURLs(dicomFiles)

                if let firstURL = navigatorVM.currentURL {
                    await imageVM.loadImage(from: firstURL)
                }

                isLoading = false
            } catch {
                print("Error loading series: \(error)")
                isLoading = false
            }
        }
    }

    return DirectorySeriesView(directoryURL: URL(fileURLWithPath: exampleSeriesPath))
}

// MARK: - Series with Windowing

/// Demonstrates a SwiftUI example that combines series navigation with windowing controls for DICOM images.
/// Builds a sample SwiftUI view that displays a DICOM series with integrated series navigation and window/level controls.
/// 
/// The returned view shows an image viewer, a compact series navigator that loads the selected slice, and compact windowing controls that apply custom window/level settings to the current image. The view initializes the navigator with a preset series and loads the first slice when it appears.
/// Create a view that displays a DICOM series with a compact navigator and windowing controls.
/// 
/// The view presents the current DICOM image, a compact series navigator for selecting slices, and compact windowing controls; selecting a slice loads it into the image display and adjusting the windowing applies custom center/width windowing to the displayed image.
/// - Returns: A view that presents a DICOM series viewer with navigation and windowing controls.
func seriesWithWindowing() -> some View {
    struct SeriesWindowingView: View {
        @StateObject private var navigatorVM = SeriesNavigatorViewModel()
        @StateObject private var windowingVM = WindowingViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        let seriesURLs: [URL]

        var body: some View {
            VStack(spacing: 0) {
                // Image display
                DicomImageView(viewModel: imageVM)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)

                // Series navigation
                SeriesNavigatorView(
                    navigatorViewModel: navigatorVM,
                    layout: .compact,
                    onNavigate: { url in
                        Task {
                            await imageVM.loadImage(from: url)
                        }
                    }
                )
                .padding(.horizontal)
                .background(platformSystemBackground)

                // Windowing controls
                WindowingControlView(
                    windowingViewModel: windowingVM,
                    layout: .compact,
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
                .padding(.horizontal)
                .background(platformSystemBackground)
            }
            .loadInitialSeries(seriesURLs, navigatorVM: navigatorVM, imageVM: imageVM)
        }
    }

    let urls = makeSampleSliceURLs(count: 150, seriesPath: exampleSeriesPath(named: "ct_series"))
    return SeriesWindowingView(seriesURLs: urls)
}

// MARK: - Keyboard Shortcuts

/// Displays a DICOM series viewer with keyboard arrow-key navigation.
///
/// The view contains a `DicomImageView`, a `SeriesNavigatorView` that loads the selected slice into its `DicomImageViewModel`, and a small caption prompting use of the arrow keys.
/// - Returns: A composed SwiftUI view presenting the image display, series navigator (wired to load images on navigate), and a caption.
func keyboardShortcutNavigation() -> some View {
    struct KeyboardNavigationView: View {
        @StateObject private var navigatorVM = SeriesNavigatorViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        let seriesURLs: [URL]

        var body: some View {
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

                Text("Use arrow keys to navigate")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .loadInitialSeries(seriesURLs, navigatorVM: navigatorVM, imageVM: imageVM)
        }
    }

    let urls = makeSampleSliceURLs(count: 100, seriesPath: exampleSeriesPath)
    return KeyboardNavigationView(seriesURLs: urls)
}

// MARK: - Navigation State Management

/// Presents an example view that tracks and displays recent navigation history while browsing a DICOM series.
/// 
/// The returned view shows the currently loaded DICOM image, a horizontal list of recently visited slice indices (up to 10 entries), and series navigation controls. Selecting a history entry or using the navigator updates the displayed image and the history.
/// Provides a view demonstrating tracked series navigation with a history of visited slice indices.
///
/// The view displays a DICOM image, a horizontal "Navigation History" bar of buttons for previously visited slice indices, and a series navigator. Navigating the series appends the current index to the history (trimmed to at most 10 entries); tapping a history button jumps the navigator to that index and loads the corresponding image. The history is initially seeded with index 0. The view is initialized with 100 sample URLs. 
/// - Returns: A view composed of a `DicomImageView`, a horizontal history bar of up to 10 index buttons, and a `SeriesNavigatorView` that loads images when navigation occurs.
func trackNavigationState() -> some View {
    struct NavigationTrackerView: View {
        @StateObject private var navigatorVM = SeriesNavigatorViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        @State private var navigationHistory: [Int] = []
        let seriesURLs: [URL]

        var body: some View {
            VStack {
                DicomImageView(viewModel: imageVM)

                VStack(spacing: 8) {
                    Text("Navigation History")
                        .font(.headline)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(navigationHistory, id: \.self) { index in
                                Button("\(index + 1)") {
                                    navigatorVM.goToIndex(index)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .frame(height: 40)
                }
                .padding()

                SeriesNavigatorView(
                    navigatorViewModel: navigatorVM,
                    onNavigate: { url in
                        // Track navigation
                        navigationHistory.append(navigatorVM.currentIndex)
                        if navigationHistory.count > 10 {
                            navigationHistory.removeFirst()
                        }

                        Task {
                            await imageVM.loadImage(from: url)
                        }
                    }
                )
            }
            .loadInitialSeries(seriesURLs, navigatorVM: navigatorVM, imageVM: imageVM) { _ in
                if navigationHistory.isEmpty {
                    navigationHistory.append(0)
                }
            }
        }
    }

    let urls = makeSampleSliceURLs(count: 100, seriesPath: exampleSeriesPath)
    return NavigationTrackerView(seriesURLs: urls)
}

// MARK: - Lazy Loading

/// Demonstrates lazy loading of a DICOM series with a bounded in-memory cache during navigation.
/// 
/// Presents a SwiftUI view that displays the current DICOM image, series navigation controls, and a cached-image count. Images are loaded on demand as the user navigates and cached by index to avoid reloading nearby slices.
/// Creates a SwiftUI example view that demonstrates per-slice lazy loading and bounded in-memory caching for a DICOM series.
/// 
/// The returned view combines a DicomImageView, a SeriesNavigatorView, and a small status showing how many slices have been cached. It initializes a navigator with a set of example URLs, loads the first image on appear, and caches loaded `CGImage` objects by series index for reuse when navigating.
func lazyLoadingNavigation() -> some View {
    struct LazyLoadingView: View {
        @StateObject private var navigatorVM = SeriesNavigatorViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        @State private var loadedImages: [Int: CGImage] = [:]
        @State private var loadedDecoders: [Int: DCMDecoder] = [:]
        private let cacheRadius = 10
        let seriesURLs: [URL]

        var body: some View {
            VStack {
                DicomImageView(viewModel: imageVM)

                Text("Cached: \(loadedImages.count) / \(seriesURLs.count) images")
                    .font(.caption)
                    .foregroundColor(.secondary)

                SeriesNavigatorView(
                    navigatorViewModel: navigatorVM,
                    onNavigate: { url in
                        Task {
                            let currentIndex = await MainActor.run { navigatorVM.currentIndex }
                            await loadImageWithCache(url: url, index: currentIndex)
                        }
                    }
                )
            }
            .onAppear {
                Task {
                    let firstURL = await MainActor.run { () -> URL? in
                        navigatorVM.setSeriesURLs(seriesURLs)
                        return navigatorVM.currentURL
                    }
                    if let firstURL {
                        await loadImageWithCache(url: firstURL, index: 0)
                    }
                }
            }
        }

        /// Loads the image for a given series URL and index, preferring a cached image and caching the result.
        /// 
        /// If a cached image/decoder exists for `index`, it re-renders from the cached decoder and returns early. Otherwise it loads and decodes from disk, then stores both the rendered image and decoder in cache dictionaries keyed by `index`.
        /// - Parameters:
        ///   - url: The file URL of the image to load.
        /// Ensures the image for the given URL is available in the in-memory cache and updates the shared image view model.
        /// 
        /// If a cached image exists for `index`, this function short-circuits by loading from the cached decoder so the UI uses cached data instead of re-reading from disk. On cache miss, it decodes from file and stores both decoder and rendered image in cache.
        /// - Parameters:
        ///   - url: The source URL of the DICOM image to load.
        /// Loads a DICOM image for the given URL into `imageVM`, using a cached decoder if available, and updates the in-memory image/decoder caches around `index`.
        /// If a cached decoder exists for `index`, the cached decoder is used to render `imageVM` and the function returns immediately. On cache miss, the function decodes the file at `url`, updates `imageVM` with the decoded image, and stores both the rendered image and decoder in the in-memory caches keyed by `index`. After caching, entries outside the window of `index ± cacheRadius` are evicted to limit memory usage.
        /// - Parameters:
        ///   - url: File URL of the DICOM image to load.
        ///   - index: Index of the image within the series; used as the cache key and to prune cached entries to a neighborhood around this index.
        private func loadImageWithCache(url: URL, index: Int) async {
            // Check cache first
            let cachedDecoder: DCMDecoder? = await MainActor.run {
                guard loadedImages[index] != nil else { return nil }
                return loadedDecoders[index]
            }
            if let cachedDecoder {
                print("Using cached image for index \(index)")
                await imageVM.loadImage(decoder: cachedDecoder)
                return
            }

            // Load and cache
            do {
                let decoder = try await DCMDecoder(contentsOfFile: url.path)
                await imageVM.loadImage(decoder: decoder)

                let renderedImage = await MainActor.run { imageVM.image }
                if let renderedImage {
                    await MainActor.run {
                        loadedImages[index] = renderedImage
                        loadedDecoders[index] = decoder

                        // Keep only nearby slices cached to avoid unbounded memory growth.
                        let lowerBound = max(0, index - cacheRadius)
                        let upperBound = min(seriesURLs.count - 1, index + cacheRadius)
                        let keepRange = lowerBound...upperBound
                        loadedImages = loadedImages.filter { keepRange.contains($0.key) }
                        loadedDecoders = loadedDecoders.filter { keepRange.contains($0.key) }
                    }
                }
            } catch {
                print("Failed to load image at index \(index): \(error)")
            }
        }
    }

    let urls = makeSampleSliceURLs(count: 50, seriesPath: exampleSeriesPath)
    return LazyLoadingView(seriesURLs: urls)
}

// MARK: - Preloading Adjacent Slices

/// A SwiftUI example view that displays a DICOM image and preloads adjacent slices for smoother navigation.
/// 
/// The view renders the current image, a series navigator control, and a small indicator of how many slices have been preloaded. When navigating, it loads the selected slice and asynchronously preloads nearby slices into an in-memory decoder cache, pruning decoders that are far from the current index.
/// Creates a demo view that displays a DICOM image with a series navigator and background preloading of adjacent slices.
/// 
/// The returned view shows the current image, a caption with the number of preloaded decoders, and a navigator; selecting a slice loads it into the image view model and triggers asynchronous preloading of nearby slice decoders (two on each side) while pruning decoders outside a ±5 index window.
/// - Returns: A view containing a `DicomImageView`, a `SeriesNavigatorView` wired to load selected slices, and logic to preload and cache adjacent `DCMDecoder` instances.
func preloadAdjacentSlices() -> some View {
    struct PreloadingView: View {
        @StateObject private var navigatorVM = SeriesNavigatorViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        @State private var preloadedDecoders: [Int: DCMDecoder] = [:]
        let seriesURLs: [URL]

        var body: some View {
            VStack {
                DicomImageView(viewModel: imageVM)

                Text("Preloaded: \(preloadedDecoders.count) images")
                    .font(.caption)
                    .foregroundColor(.secondary)

                SeriesNavigatorView(
                    navigatorViewModel: navigatorVM,
                    onNavigate: { url in
                        Task {
                            await loadWithPreloading(index: navigatorVM.currentIndex)
                        }
                    }
                )
            }
            .onAppear {
                navigatorVM.setSeriesURLs(seriesURLs)
                Task {
                    await loadWithPreloading(index: 0)
                }
            }
        }

        /// Load the image at the given series index, preferring an already preloaded decoder if available, and start background preloading of adjacent slices.
        /// Loads the image for the given slice index into the image view model and begins background preloading of adjacent slices.
        /// - Parameter index: The index of the slice to display within `seriesURLs`. If a decoder for this index exists in `preloadedDecoders`, it will be used; otherwise the image is loaded from the corresponding URL.
        private func loadWithPreloading(index: Int) async {
            // Load current image
            if let decoder = preloadedDecoders[index] {
                await imageVM.loadImage(decoder: decoder)
            } else {
                await imageVM.loadImage(from: seriesURLs[index])
            }

            // Preload adjacent slices in background
            Task {
                await preloadSlices(around: index)
            }
        }

        /// Preloads decoders for image slices near a given index and prunes cached decoders far from that index.
        /// 
        /// Attempts to create and cache a `DCMDecoder` for up to two slices before and after `index`, skipping out-of-bounds indices and indices that are already cached. After preloading, removes cached decoders whose indices are outside the window from `index - 5` to `index + 5`.
        /// Preloads decoder objects for slices near a given index and prunes distant cached decoders.
        /// 
        /// Loads decoder instances for up to two slices before and after the provided `index`, skipping indices that are out of range or already preloaded. Errors during individual preloads are logged but do not stop the overall operation. After preloading, removes cached decoders whose indices are outside the range `index - 5` through `index + 5`.
        /// Preloads DICOM decoders for slices near a given index and prunes distant cached decoders.
        /// 
        /// Attempts to load decoders for indices two slices before through two slices after `index` (when in bounds),
        /// storing successful decoders in `preloadedDecoders`. After preloading, removes any cached decoders whose
        /// indices fall outside five slices before to five slices after `index`.
        /// Failed decoder loads are logged to the console.
        /// - Parameter index: Center index around which decoders will be preloaded and retained.
        private func preloadSlices(around index: Int) async {
            let preloadRange = 2 // Preload 2 slices before and after

            for offset in -preloadRange...preloadRange {
                let targetIndex = index + offset
                guard targetIndex >= 0, targetIndex < seriesURLs.count else {
                    continue
                }

                let shouldPreload = await MainActor.run {
                    preloadedDecoders[targetIndex] == nil
                }
                guard shouldPreload else {
                    continue
                }

                do {
                    let decoder = try await DCMDecoder(contentsOfFile: seriesURLs[targetIndex].path)
                    await MainActor.run {
                        preloadedDecoders[targetIndex] = decoder
                    }
                } catch {
                    print("Failed to preload slice \(targetIndex): \(error)")
                }
            }

            // Clean up distant slices
            let keepRange = (max(0, index - 5))...(min(seriesURLs.count - 1, index + 5))
            await MainActor.run {
                preloadedDecoders = preloadedDecoders.filter { keepRange.contains($0.key) }
            }
        }
    }

    let urls = makeSampleSliceURLs(count: 100, seriesPath: exampleSeriesPath)
    return PreloadingView(seriesURLs: urls)
}

// MARK: - Multi-Series Navigation

/// Presents a UI for switching between and navigating multiple DICOM series.
/// 
/// The view shows a segmented picker to select a series and a paged TabView where each tab contains a DICOM image display and a series navigator. Selecting a series or navigating within a series loads the corresponding image into a shared image view model so the same image view is reused across series tabs.
/// Displays a multi-series DICOM viewer with a segmented series selector and paged tabs.
/// 
/// Each tab presents a DICOM image view paired with a series navigator; selecting a segment or page switches the active series and shows its images.
/// Presents a UI for switching among multiple DICOM series and viewing their images with a shared image view model.
///
/// A segmented picker selects the active series; a paged TabView shows one page per series containing a series navigator and a shared DICOM image viewer.
/// - Returns: A view that displays a segmented series selector and a paged content area where each page shows the selected series' navigator and a shared DICOM image viewer.
func multiSeriesNavigation() -> some View {
    struct MultiSeriesView: View {
        @StateObject private var imageVM = DicomImageViewModel()
        @State private var selectedSeriesIndex = 0
        let allSeries: [[URL]]

        var body: some View {
            VStack(spacing: 0) {
                // Series selector
                Picker("Series", selection: $selectedSeriesIndex) {
                    ForEach(0..<allSeries.count, id: \.self) { index in
                        Text("Series \(index + 1) (\(allSeries[index].count) images)")
                            .tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                .background(platformSystemBackground)

                // Image display with current series navigator
                TabView(selection: $selectedSeriesIndex) {
                    ForEach(0..<allSeries.count, id: \.self) { seriesIndex in
                        SeriesViewTab(
                            seriesURLs: allSeries[seriesIndex],
                            imageVM: imageVM
                        )
                        .tag(seriesIndex)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
    }

    struct SeriesViewTab: View {
        @StateObject private var navigatorVM = SeriesNavigatorViewModel()
        let seriesURLs: [URL]
        @ObservedObject var imageVM: DicomImageViewModel

        var body: some View {
            VStack {
                DicomImageView(viewModel: imageVM)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                SeriesNavigatorView(
                    navigatorViewModel: navigatorVM,
                    onNavigate: { url in
                        Task {
                            await imageVM.loadImage(from: url)
                        }
                    }
                )
            }
            .loadInitialSeries(seriesURLs, navigatorVM: navigatorVM, imageVM: imageVM)
        }
    }

    let series1 = makeSampleSliceURLs(count: 50, seriesPath: exampleSeriesPath(named: "series1"))
    let series2 = makeSampleSliceURLs(count: 75, seriesPath: exampleSeriesPath(named: "series2"))
    let series3 = makeSampleSliceURLs(count: 100, seriesPath: exampleSeriesPath(named: "series3"))

    return MultiSeriesView(allSeries: [series1, series2, series3])
}

// MARK: - Cine Loop (Animated Playback)

/// Creates a view that plays a DICOM series as a cine loop with playback controls and adjustable speed.
/// 
/// The view shows the current DICOM image, a play/pause button, an FPS slider, and a series navigator. When playing, it advances through the series at the selected frames-per-second rate and loops back to the first image after the last.
/// Creates a SwiftUI view that demonstrates cine-style playback of a DICOM series with playback controls and a series navigator.
/// The view loads the first image on appear, provides play/pause and FPS controls, and advances through images at the selected speed, looping to the first image after the last.
/// Creates a view demonstrating cine-loop playback of a DICOM series.
/// 
/// The returned view shows a DICOM image, playback controls (play/pause and FPS slider) and a series navigator. While playing, the navigator advances to the next image at the configured frames-per-second and wraps to the first image when the end is reached.
/// - Returns: A view that displays the cine-loop UI and manages playback of the provided series.
func cineLoopPlayback() -> some View {
    struct CineLoopView: View {
        @StateObject private var navigatorVM = SeriesNavigatorViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        @State private var isPlaying = false
        @State private var playbackSpeed: Double = 10.0 // FPS
        let seriesURLs: [URL]

        var body: some View {
            VStack {
                DicomImageView(viewModel: imageVM)

                // Playback controls
                HStack(spacing: 16) {
                    Button(action: { isPlaying.toggle() }) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderedProminent)

                    VStack {
                        Text("Speed: \(Int(playbackSpeed)) FPS")
                            .font(.caption)

                        Slider(value: $playbackSpeed, in: 1...30, step: 1)
                            .frame(width: 150)
                    }
                }
                .padding()

                SeriesNavigatorView(
                    navigatorViewModel: navigatorVM,
                    onNavigate: { url in
                        Task {
                            await imageVM.loadImage(from: url)
                        }
                    }
                )
            }
            .loadInitialSeries(seriesURLs, navigatorVM: navigatorVM, imageVM: imageVM)
            .onChange(of: isPlaying) { newValue in
                if newValue {
                    startPlayback()
                }
            }
        }

        /// Starts asynchronous playback of the series, advancing to the next image repeatedly at a rate defined by `playbackSpeed`.
        /// Start the cine playback loop, advancing the navigator at the configured playback speed.
        /// 
        /// Starts cine playback for the current series.
        /// 
        /// Advances the series navigator repeatedly at an interval determined by `playbackSpeed` while `isPlaying` remains true, wrapping to the first slice after the last. The playback runs on the main actor and stops if `isPlaying` becomes false or the task is cancelled.
        private func startPlayback() {
            guard isPlaying else { return }

            Task { @MainActor in
                while isPlaying && !Task.isCancelled {
                    navigatorVM.goToNext()

                    if navigatorVM.isAtLast {
                        navigatorVM.goToFirst()
                    }

                    if Task.isCancelled || !isPlaying {
                        break
                    }
                    try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / playbackSpeed))
                }
            }
        }
    }

    let urls = makeSampleSliceURLs(count: 50, seriesPath: exampleSeriesPath)
    return CineLoopView(seriesURLs: urls)
}

// MARK: - Complete Series Viewer

/// Presents a complete DICOM series viewer with image display, navigation, window/level controls, and metadata presentation.
/// 
/// The view shows the current image, a series navigator, compact windowing controls, and an optional series information banner. A toolbar menu provides actions to toggle the series info banner and open a metadata sheet for the current image. When the view appears it initializes the navigator with a provided series and loads the first image.
/// Creates a full-featured example viewer for browsing and inspecting a DICOM series.
/// 
/// The returned view displays a DICOM image, a series navigator, compact window/level controls, an optional series information banner, and a metadata sheet for the current image. The viewer initializes its navigator with a provided list of slice URLs and loads the first image on appear.
/// Builds the complete series viewer UI that displays a DICOM image, series navigator, windowing controls, and metadata tooling.
/// - Returns: A view that presents a DICOM image viewer with an integrated series navigator, compact windowing controls, a metadata sheet, and a toolbar action for series information. 
func completeSeriesViewer() -> some View {
    struct CompleteSeriesViewer: View {
        @StateObject private var navigatorVM = SeriesNavigatorViewModel()
        @StateObject private var windowingVM = WindowingViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        @State private var showingMetadata = false
        @State private var metadataDecoder: DCMDecoder?
        @State private var isLoadingMetadata = false
        @State private var metadataError: Error?
        @State private var showingSeriesInfo = false
        let seriesURLs: [URL]

        var body: some View {
            NavigationView {
                VStack(spacing: 0) {
                    // Image display
                    DicomImageView(viewModel: imageVM)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)

                    // Series information banner
                    if showingSeriesInfo {
                        SeriesInfoBanner(
                            navigatorVM: navigatorVM,
                            isPresented: $showingSeriesInfo
                        )
                    }

                    // Navigation controls
                    SeriesNavigatorView(
                        navigatorViewModel: navigatorVM,
                        onNavigate: { url in
                            Task {
                                await imageVM.loadImage(from: url)
                            }
                        }
                    )
                    .background(platformSystemBackground)

                    // Windowing controls
                    WindowingControlView(
                        windowingViewModel: windowingVM,
                        layout: .compact,
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
                    .background(platformSystemBackground)
                }
                .navigationTitle("Series Viewer")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        SeriesToolbarMenu(
                            showingSeriesInfo: $showingSeriesInfo,
                            showingMetadata: $showingMetadata
                        )
                    }
                }
                .sheet(isPresented: $showingMetadata) {
                    MetadataSheetContent(
                        decoder: metadataDecoder,
                        isLoading: isLoadingMetadata,
                        error: metadataError,
                        isPresented: $showingMetadata
                    )
                }
            }
            .loadInitialSeries(seriesURLs, navigatorVM: navigatorVM, imageVM: imageVM)
            .onChange(of: showingMetadata) { isPresented in
                if isPresented {
                    loadMetadataForCurrentImage()
                } else {
                    metadataDecoder = nil
                    metadataError = nil
                    isLoadingMetadata = false
                }
            }
        }

        private func loadMetadataForCurrentImage() {
            guard let currentURL = navigatorVM.currentURL else {
                metadataDecoder = nil
                metadataError = nil
                isLoadingMetadata = false
                return
            }
            let targetURL = currentURL

            metadataDecoder = nil
            metadataError = nil
            isLoadingMetadata = true

            Task {
                do {
                    let loadedDecoder = try await DCMDecoder(contentsOfFile: targetURL.path)
                    let isStillRelevant = await MainActor.run {
                        showingMetadata && navigatorVM.currentURL?.path == targetURL.path
                    }
                    guard isStillRelevant else { return }

                    await MainActor.run {
                        metadataDecoder = loadedDecoder
                        metadataError = nil
                        isLoadingMetadata = false
                    }
                } catch {
                    let isStillRelevant = await MainActor.run {
                        showingMetadata && navigatorVM.currentURL?.path == targetURL.path
                    }
                    guard isStillRelevant else { return }

                    await MainActor.run {
                        metadataDecoder = nil
                        metadataError = error
                        isLoadingMetadata = false
                    }
                }
            }
        }

    }

    let urls = makeSampleSliceURLs(count: 150, seriesPath: exampleSeriesPath(named: "ct_series"))
    return CompleteSeriesViewer(seriesURLs: urls)
}

// MARK: - Loading Series with DicomSeriesLoader

/// Creates a SwiftUI view that loads DICOM files from a directory and presents the series with an image display and navigation controls.
/// 
/// While the series is being discovered and validated, a progress indicator is shown. After loading completes the view populates the navigator and displays the first image; if loading fails the loading state is cleared and the view stops showing the progress indicator.
/// Loads DICOM files from `seriesDirectory`, validates them with `DicomSeriesLoader`, initializes the navigator with deterministic file ordering, loads the first image into `imageVM` if present, and clears the loading state.
/// 
/// On success, `navigatorVM` is populated with sorted URLs and the first image is loaded into `imageVM`. On failure, the error is printed and `isLoading` is set to `false`.
func orderedSeriesLoading(
    loaderFactory: @escaping () -> DicomSeriesLoaderProtocol = { DicomSeriesLoader() }
) -> some View {
    struct OrderedSeriesView: View {
        @StateObject private var navigatorVM = SeriesNavigatorViewModel()
        @StateObject private var imageVM = DicomImageViewModel()
        @State private var isLoading = true
        let seriesDirectory: URL
        let loaderFactory: () -> DicomSeriesLoaderProtocol

        var body: some View {
            VStack {
                if isLoading {
                    ProgressView("Loading and ordering series...")
                } else {
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
            }
            .task {
                await loadOrderedSeries()
            }
        }

        /// Load DICOM files from `seriesDirectory`, validate the series, and initialize the navigator and image view models.
        ///
        /// Discover and load a DICOM series from the configured directory.
        ///
        /// Scans `seriesDirectory` for files with `.dcm` or `.dicom` extensions, validates and loads volume metadata with `DicomSeriesLoader`, updates `navigatorVM` with deterministic file ordering, and loads the first image into `imageVM` if available. Clears the `isLoading` flag when finished; on failure, clears `isLoading` and prints the encountered error.
        private func loadOrderedSeries() async {
            do {
                // Get all DICOM files in directory
                let fileManager = FileManager.default
                let files = try fileManager.contentsOfDirectory(
                    at: seriesDirectory,
                    includingPropertiesForKeys: nil
                )

                let dicomFiles = files.filter {
                    $0.pathExtension.lowercased() == "dcm" ||
                    $0.pathExtension.lowercased() == "dicom"
                }

                let loader = loaderFactory()
                let seriesInfo = try await loader.loadSeries(in: seriesDirectory)

                // Navigator still needs file URLs; use deterministic name ordering.
                let orderedURLs = dicomFiles.sorted {
                    $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
                }

                navigatorVM.setSeriesURLs(orderedURLs)

                if let firstURL = navigatorVM.currentURL {
                    await imageVM.loadImage(from: firstURL)
                }

                print(
                    """
                    Loaded volume: \(seriesInfo.depth) slices \
                    (\(seriesInfo.width)x\(seriesInfo.height)), \
                    spacing=\(seriesInfo.spacing.x)x\(seriesInfo.spacing.y)x\(seriesInfo.spacing.z)
                    """
                )

                isLoading = false
            } catch {
                print("Error loading series: \(error)")
                isLoading = false
            }
        }
    }

    return OrderedSeriesView(
        seriesDirectory: URL(fileURLWithPath: exampleSeriesPath),
        loaderFactory: loaderFactory
    )
}
