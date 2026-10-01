//
//  SeriesNavigatorViewModel.swift
//
//  ViewModel for managing DICOM series navigation state
//
//  This view model handles navigation through a series of DICOM images (slices),
//  tracking the current index, total count, and providing methods for sequential
//  and direct navigation. It supports keyboard shortcuts, thumbnail loading state,
//  and boundary handling for safe navigation.
//
//  The view model uses @Published properties for reactive UI updates and provides
//  computed properties for easy binding to SwiftUI views. Navigation is boundary-safe,
//  with methods that automatically clamp indices to valid ranges.
//
//  Thread Safety:
//
//  All methods marked with @MainActor run on the main thread, ensuring UI updates
//  are safe. The ViewModel uses structured concurrency for async thumbnail loading
//  operations. @Published properties automatically update the UI when changed.
//
//  Usage Patterns:
//
//  Use this view model in conjunction with DicomImageViewModel to provide series
//  navigation controls. When the current index changes, load the corresponding
//  image URL into DicomImageViewModel to display it.
//

import Foundation
import SwiftUI
import Combine
import OSLog
import DicomCore

// MARK: - View Model

/// Thumbnail pixel data for one slice in ``SeriesNavigatorView``.
///
/// The thumbnail stores already-windowed 8-bit grayscale pixels so SwiftUI views
/// can build display images without re-decoding DICOM files on the main thread.
public struct SeriesNavigatorThumbnail: Equatable, Sendable {
    /// Row-major 8-bit grayscale pixels.
    public let pixels: [UInt8]

    /// Thumbnail width in pixels.
    public let width: Int

    /// Thumbnail height in pixels.
    public let height: Int

    /// Creates a validated thumbnail value.
    ///
    /// Returns `nil` when dimensions are invalid or the pixel count does not
    /// match `width * height`.
    public init?(pixels: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0 else {
            return nil
        }

        let (expectedPixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels.count == expectedPixelCount else {
            return nil
        }

        self.pixels = pixels
        self.width = width
        self.height = height
    }
}

/// View model for managing DICOM series navigation state.
///
/// ## Overview
///
/// ``SeriesNavigatorViewModel`` provides reactive state management for navigating through
/// a series of DICOM images (slices) in SwiftUI applications. It tracks the current position
/// within the series, total image count, and provides methods for sequential and direct
/// navigation with boundary safety.
///
/// The view model is designed to work seamlessly with ``DicomImageViewModel``, providing
/// the current file URL while the image view model handles loading and rendering. This
/// separation enables flexible UI architectures where navigation controls are decoupled
/// from image display.
///
/// **Key Features:**
/// - Reactive state with `@Published` properties
/// - Boundary-safe navigation (next, previous, goToIndex)
/// - Support for keyboard shortcuts via navigation methods
/// - Thumbnail loading state tracking
/// - Computed properties for UI binding (canGoNext, canGoPrevious, etc.)
/// - Thread-safe operations with main actor isolation
///
/// ## Usage
///
/// Basic usage with sequential navigation:
///
/// ```swift
/// struct SeriesNavigatorView: View {
///     @StateObject private var navigatorVM = SeriesNavigatorViewModel()
///     @StateObject private var imageVM = DicomImageViewModel()
///     let seriesURLs: [URL]
///
///     var body: some View {
///         VStack {
///             // Display current image
///             if let image = imageVM.image {
///                 Image(decorative: image, scale: 1.0)
///                     .resizable()
///                     .aspectRatio(contentMode: .fit)
///             }
///
///             // Navigation controls
///             HStack {
///                 Button("Previous") {
///                     navigatorVM.goToPrevious()
///                 }
///                 .disabled(!navigatorVM.canGoPrevious)
///
///                 Text("\(navigatorVM.currentIndex + 1) / \(navigatorVM.totalCount)")
///
///                 Button("Next") {
///                     navigatorVM.goToNext()
///                 }
///                 .disabled(!navigatorVM.canGoNext)
///             }
///         }
///         .onAppear {
///             navigatorVM.setSeriesURLs(seriesURLs)
///         }
///         .onChange(of: navigatorVM.currentIndex) { _, newIndex in
///             if let url = navigatorVM.currentURL {
///                 Task {
///                     await imageVM.loadImage(from: url)
///                 }
///             }
///         }
///     }
/// }
/// ```
///
/// Direct navigation with slider:
///
/// ```swift
/// @StateObject private var navigatorVM = SeriesNavigatorViewModel()
/// @StateObject private var imageVM = DicomImageViewModel()
///
/// var body: some View {
///     VStack {
///         // Slider for direct navigation
///         Slider(
///             value: Binding(
///                 get: { Double(navigatorVM.currentIndex) },
///                 set: { navigatorVM.goToIndex(Int($0)) }
///             ),
///             in: 0...Double(max(0, navigatorVM.totalCount - 1)),
///             step: 1
///         )
///
///         Text("Slice \(navigatorVM.currentIndex + 1) of \(navigatorVM.totalCount)")
///     }
/// }
/// ```
///
/// Keyboard shortcuts (SwiftUI 3.0+):
///
/// ```swift
/// var body: some View {
///     ContentView()
///         .onKeyPress(.leftArrow) {
///             navigatorVM.goToPrevious()
///             return .handled
///         }
///         .onKeyPress(.rightArrow) {
///             navigatorVM.goToNext()
///             return .handled
///         }
///         .onKeyPress(.upArrow) {
///             navigatorVM.goToFirst()
///             return .handled
///         }
///         .onKeyPress(.downArrow) {
///             navigatorVM.goToLast()
///             return .handled
///         }
/// }
/// ```
///
/// ## Topics
///
/// ### Creating a View Model
///
/// - ``init()``
/// - ``init(seriesURLs:)``
///
/// ### Managing Series
///
/// - ``setSeriesURLs(_:initialIndex:)``
/// - ``reset()``
///
/// ### Navigation Methods
///
/// - ``goToNext()``
/// - ``goToPrevious()``
/// - ``goToIndex(_:)``
/// - ``goToFirst()``
/// - ``goToLast()``
///
/// ### State Properties
///
/// - ``currentIndex``
/// - ``totalCount``
/// - ``seriesURLs``
/// - ``isLoadingThumbnails``
///
/// ### Computed Properties
///
/// - ``canGoNext``
/// - ``canGoPrevious``
/// - ``currentURL``
/// - ``isEmpty``
/// - ``progressPercentage``
///
@MainActor
public final class SeriesNavigatorViewModel: ObservableObject {

    // MARK: - Published Properties

    /// Current slice index (0-based)
    @Published public private(set) var currentIndex: Int = 0

    /// Total number of images in the series
    @Published public private(set) var totalCount: Int = 0

    /// Array of DICOM file URLs in the series
    @Published public private(set) var seriesURLs: [URL] = []

    /// Whether thumbnail loading is in progress
    @Published public private(set) var isLoadingThumbnails: Bool = false

    /// Windowed thumbnail pixels keyed by slice index.
    @Published public private(set) var thumbnails: [Int: SeriesNavigatorThumbnail] = [:]

    // MARK: - Private Properties

    private let logger: Logger
    private var thumbnailGeneration = 0

    // MARK: - Initialization

    /// Creates a new series navigator view model with empty series.
    ///
    /// Initializes the view model with no series loaded. Call ``setSeriesURLs(_:initialIndex:)``
    /// to load a series for navigation.
    ///
    /// ## Example
    ///
    /// ```swift
    /// struct MyView: View {
    ///     @StateObject private var navigatorVM = SeriesNavigatorViewModel()
    ///
    ///     var body: some View {
    ///         // Use navigatorVM here
    ///     }
    /// }
    /// ```
    ///
    public init() {
        self.logger = Logger(subsystem: "com.dicomswiftui", category: "SeriesNavigatorViewModel")
        logger.info("📊 SeriesNavigatorViewModel initialized")
    }

    /// Creates a new series navigator view model with specified series URLs.
    ///
    /// Initializes the view model with a series of DICOM file URLs and sets the current
    /// index to 0 (first image). This is a convenience initializer for when you have the
    /// series URLs at initialization time.
    ///
    /// - Parameter seriesURLs: Array of DICOM file URLs to navigate through
    ///
    /// ## Example
    ///
    /// ```swift
    /// let urls = [url1, url2, url3]
    /// let navigatorVM = SeriesNavigatorViewModel(seriesURLs: urls)
    /// print("Loaded \(navigatorVM.totalCount) images")
    /// ```
    ///
    public init(seriesURLs: [URL]) {
        self.logger = Logger(subsystem: "com.dicomswiftui", category: "SeriesNavigatorViewModel")
        self.seriesURLs = seriesURLs
        self.totalCount = seriesURLs.count
        self.currentIndex = 0
        logger.info("📊 SeriesNavigatorViewModel initialized with \(seriesURLs.count) images")
    }

    // MARK: - Public Interface - Managing Series

    /// Sets the series URLs for navigation.
    ///
    /// Updates the series with new file URLs and resets the navigation to the specified
    /// initial index (defaults to 0). The index is automatically clamped to the valid
    /// range [0, count-1].
    ///
    /// This method updates ``seriesURLs``, ``totalCount``, and ``currentIndex`` properties.
    ///
    /// - Parameters:
    ///   - urls: Array of DICOM file URLs to navigate through
    ///   - initialIndex: Starting index (defaults to 0, clamped to valid range)
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var navigatorVM = SeriesNavigatorViewModel()
    ///
    /// // Load series
    /// navigatorVM.setSeriesURLs(fileURLs)
    ///
    /// // Load series starting at middle image
    /// navigatorVM.setSeriesURLs(fileURLs, initialIndex: fileURLs.count / 2)
    /// ```
    public func setSeriesURLs(_ urls: [URL], initialIndex: Int = 0) {
        logger.info("📁 Setting series with \(urls.count) images (initial index: \(initialIndex))")

        seriesURLs = urls
        totalCount = urls.count
        thumbnailGeneration += 1
        isLoadingThumbnails = false
        thumbnails = [:]

        // Clamp initial index to valid range
        if totalCount == 0 {
            currentIndex = 0
        } else {
            currentIndex = max(0, min(initialIndex, totalCount - 1))
        }

        logger.debug("✅ Series loaded: \(self.totalCount) images, starting at index \(self.currentIndex)")
    }

    /// Resets the navigator to initial state.
    ///
    /// Clears the series URLs and resets navigation state to empty. Use this when
    /// unloading a series or preparing to load a new one.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // User closes series viewer
    /// navigatorVM.reset()
    ///
    /// // Load new series
    /// navigatorVM.setSeriesURLs(newFileURLs)
    /// ```
    /// Restore the view model to its initial empty state.
    ///
    /// Resets the navigator to an empty state.
    /// 
    /// Clears the series URL list, sets `totalCount` and `currentIndex` to `0`, and sets `isLoadingThumbnails` to `false`.
    public func reset() {
        logger.debug("🔄 Resetting navigator")

        seriesURLs = []
        totalCount = 0
        currentIndex = 0
        thumbnailGeneration += 1
        isLoadingThumbnails = false
        thumbnails = [:]
    }

    // MARK: - Public Interface - Navigation Methods

    /// Navigates to the next image in the series.
    ///
    /// Increments the current index by 1, if not already at the last image. This method
    /// is boundary-safe and will not navigate beyond the last image. Check ``canGoNext``
    /// to determine if navigation is possible before calling.
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var navigatorVM = SeriesNavigatorViewModel()
    ///
    /// Button("Next") {
    ///     navigatorVM.goToNext()
    /// }
    /// .disabled(!navigatorVM.canGoNext)
    /// ```
    /// Advances the navigator to the next image in the series.
    /// 
    /// Advance the navigator to the next image in the series.
    /// If already at the last image, the current index remains unchanged.
    public func goToNext() {
        guard canGoNext else {
            logger.debug("⚠️ Cannot go to next: already at last image")
            return
        }

        currentIndex += 1
        logger.debug("➡️ Navigated to next: index \(self.currentIndex)")
    }

    /// Navigates to the previous image in the series.
    ///
    /// Decrements the current index by 1, if not already at the first image. This method
    /// is boundary-safe and will not navigate before the first image. Check ``canGoPrevious``
    /// to determine if navigation is possible before calling.
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var navigatorVM = SeriesNavigatorViewModel()
    ///
    /// Button("Previous") {
    ///     navigatorVM.goToPrevious()
    /// }
    /// .disabled(!navigatorVM.canGoPrevious)
    /// ```
    /// Move the current index to the previous image in the series.
    /// Moves the navigator to the previous image in the series.
    /// If a previous image exists, decrements `currentIndex`; otherwise leaves the index unchanged.
    public func goToPrevious() {
        guard canGoPrevious else {
            logger.debug("⚠️ Cannot go to previous: already at first image")
            return
        }

        currentIndex -= 1
        logger.debug("⬅️ Navigated to previous: index \(self.currentIndex)")
    }

    /// Navigates to a specific index in the series.
    ///
    /// Sets the current index to the specified value, automatically clamping to the valid
    /// range [0, totalCount-1]. This method is boundary-safe and will never set an invalid
    /// index. If the series is empty, the index is set to 0.
    ///
    /// - Parameter index: The target index (0-based, will be clamped to valid range)
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var navigatorVM = SeriesNavigatorViewModel()
    ///
    /// // Slider for direct navigation
    /// Slider(
    ///     value: Binding(
    ///         get: { Double(navigatorVM.currentIndex) },
    ///         set: { navigatorVM.goToIndex(Int($0)) }
    ///     ),
    ///     in: 0...Double(max(0, navigatorVM.totalCount - 1)),
    ///     step: 1
    /// )
    ///
    /// // Jump to middle image
    /// navigatorVM.goToIndex(navigatorVM.totalCount / 2)
    /// ```
    public func goToIndex(_ index: Int) {
        guard totalCount > 0 else {
            logger.debug("⚠️ Cannot navigate: series is empty")
            currentIndex = 0
            return
        }

        // Clamp to valid range
        let clampedIndex = max(0, min(index, totalCount - 1))

        if clampedIndex != index {
            logger.debug("⚠️ Index \(index) out of bounds, clamped to \(clampedIndex)")
        }

        currentIndex = clampedIndex
        logger.debug("🎯 Navigated to index: \(self.currentIndex)")
    }

    /// Navigates to the first image in the series.
    ///
    /// Sets the current index to 0. This is a convenience method equivalent to
    /// calling ``goToIndex(_:)`` with index 0.
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var navigatorVM = SeriesNavigatorViewModel()
    ///
    /// Button("First") {
    ///     navigatorVM.goToFirst()
    /// }
    /// .disabled(navigatorVM.currentIndex == 0)
    /// ```
    /// Navigates to the first image in the current series.
    /// Navigate to the first image in the series.
    /// 
    /// Sets `currentIndex` to `0`. If the series is empty, `currentIndex` remains `0`.
    public func goToFirst() {
        logger.debug("⏮ Navigating to first image")
        goToIndex(0)
    }

    /// Navigates to the last image in the series.
    ///
    /// Sets the current index to the last valid index (totalCount - 1). This is a
    /// convenience method equivalent to calling ``goToIndex(_:)`` with index totalCount - 1.
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var navigatorVM = SeriesNavigatorViewModel()
    ///
    /// Button("Last") {
    ///     navigatorVM.goToLast()
    /// }
    /// .disabled(navigatorVM.currentIndex == navigatorVM.totalCount - 1)
    /// ```
    /// Navigate to the last image in the series.
    /// Navigates to the last image in the current series.
    /// 
    /// If the series contains one or more URLs, sets `currentIndex` to the index of the last image; if the series is empty, leaves `currentIndex` at `0`.
    public func goToLast() {
        logger.debug("⏭ Navigating to last image")
        goToIndex(totalCount - 1)
    }

    // MARK: - Public Interface - Thumbnail Loading State

    /// Marks thumbnail loading as active.
    ///
    /// Sets ``isLoadingThumbnails`` to true so integrations can coordinate loading
    /// indicators while thumbnail work runs elsewhere. The loading state is cleared
    /// by calling ``completeThumbnailLoading()``.
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var navigatorVM = SeriesNavigatorViewModel()
    ///
    /// Task {
    ///     navigatorVM.startThumbnailLoading()
    ///     // Perform thumbnail loading operations
    ///     navigatorVM.completeThumbnailLoading()
    /// }
    /// ```
    /// Mark the view model as loading thumbnails.
    /// Marks thumbnail loading as started so UI can show a loading indicator.
    /// 
    /// Sets the `isLoadingThumbnails` state to `true`.
    public func startThumbnailLoading() {
        logger.debug("🖼 Starting thumbnail loading")
        isLoadingThumbnails = true
    }

    /// Completes asynchronous thumbnail loading operation.
    ///
    /// Sets ``isLoadingThumbnails`` to false. Call this after thumbnail loading
    /// operations complete (whether successful or failed).
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var navigatorVM = SeriesNavigatorViewModel()
    ///
    /// Task {
    ///     navigatorVM.startThumbnailLoading()
    ///     // Perform thumbnail loading operations
    ///     navigatorVM.completeThumbnailLoading()
    /// }
    /// ```
    /// Marks thumbnail loading as complete by clearing the loading state.
    /// 
    /// Updates the view model to indicate that thumbnail loading has finished.
    public func completeThumbnailLoading() {
        logger.debug("✅ Thumbnail loading complete")
        isLoadingThumbnails = false
    }

    /// Sets or clears a thumbnail for a valid slice index.
    ///
    /// Use this for tests, previews, or callers that generate thumbnails through
    /// their own image pipeline.
    public func setThumbnail(_ thumbnail: SeriesNavigatorThumbnail?, for index: Int) {
        guard index >= 0, index < totalCount else {
            return
        }

        if let thumbnail {
            thumbnails[index] = thumbnail
        } else {
            thumbnails.removeValue(forKey: index)
        }
    }

    /// Returns the thumbnail for a slice index, if one has been generated.
    public func thumbnail(at index: Int) -> SeriesNavigatorThumbnail? {
        thumbnails[index]
    }

    /// Loads thumbnails for selected slice indexes without blocking the main actor.
    ///
    /// Existing thumbnails are preserved. Invalid indexes are ignored, and files
    /// that cannot be decoded keep using the view's unavailable-thumbnail state.
    public func loadThumbnails(for indexes: [Int]? = nil, maxDimension: Int = 50) async {
        let sourceURLs = seriesURLs
        let generation = thumbnailGeneration
        guard maxDimension > 0, !sourceURLs.isEmpty else {
            return
        }

        let targetIndexes = normalizedThumbnailIndexes(indexes, totalCount: sourceURLs.count)
        guard !targetIndexes.isEmpty else {
            return
        }

        startThumbnailLoading()
        defer {
            if thumbnailGeneration == generation {
                completeThumbnailLoading()
            }
        }

        var loadedThumbnails: [Int: SeriesNavigatorThumbnail] = [:]
        for index in targetIndexes where thumbnails[index] == nil {
            guard thumbnailGeneration == generation else {
                return
            }

            if Task.isCancelled {
                return
            }

            if let thumbnail = await Self.makeThumbnail(contentsOf: sourceURLs[index], maxDimension: maxDimension) {
                guard thumbnailGeneration == generation else {
                    return
                }

                loadedThumbnails[index] = thumbnail
            }
        }

        guard thumbnailGeneration == generation else {
            return
        }

        thumbnails.merge(loadedThumbnails) { current, _ in current }
    }

    private func normalizedThumbnailIndexes(_ indexes: [Int]?, totalCount: Int) -> [Int] {
        let rawIndexes = indexes ?? Array(0..<totalCount)
        return Array(Set(rawIndexes.filter { $0 >= 0 && $0 < totalCount })).sorted()
    }

    private nonisolated static func makeThumbnail(contentsOf url: URL, maxDimension: Int) async -> SeriesNavigatorThumbnail? {
        await Task.detached(priority: .utility) {
            guard maxDimension > 0,
                  let decoder = try? DCMDecoder(contentsOf: url) else {
                return nil
            }

            if let thumbnail = decoder.getDownsampledPixels8(maxDimension: maxDimension) {
                return SeriesNavigatorThumbnail(
                    pixels: thumbnail.pixels,
                    width: thumbnail.width,
                    height: thumbnail.height
                )
            }

            guard let thumbnail = decoder.getDownsampledPixels16(maxDimension: maxDimension) else {
                return nil
            }

            let windowSettings = decoder.windowSettingsV2.isValid
                ? decoder.windowSettingsV2
                : DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: thumbnail.pixels)

            guard let pixels8 = DCMWindowingProcessor.applyWindowLevel(
                pixels16: thumbnail.pixels,
                center: windowSettings.center,
                width: windowSettings.width,
                processingMode: .vdsp
            ) else {
                return nil
            }

            return SeriesNavigatorThumbnail(
                pixels: Array(pixels8),
                width: thumbnail.width,
                height: thumbnail.height
            )
        }.value
    }
}

// MARK: - Convenience Computed Properties

extension SeriesNavigatorViewModel {

    /// Returns true if navigation to next image is possible
    public var canGoNext: Bool {
        return currentIndex < totalCount - 1
    }

    /// Returns true if navigation to previous image is possible
    public var canGoPrevious: Bool {
        return currentIndex > 0
    }

    /// Returns the URL of the currently selected image, or nil if series is empty
    public var currentURL: URL? {
        guard !seriesURLs.isEmpty, currentIndex >= 0, currentIndex < seriesURLs.count else {
            return nil
        }
        return seriesURLs[currentIndex]
    }

    /// Returns true if the series is empty
    public var isEmpty: Bool {
        return totalCount == 0
    }

    /// Returns the progress through the series as a percentage (0.0 to 1.0)
    public var progressPercentage: Double {
        guard totalCount > 0 else { return 0.0 }
        return Double(currentIndex + 1) / Double(totalCount)
    }

    /// Returns a human-readable position string (e.g., "3 / 150")
    public var positionString: String {
        guard totalCount > 0 else { return "0 / 0" }
        return "\(currentIndex + 1) / \(totalCount)"
    }

    /// Returns true if currently on the first image
    public var isAtFirst: Bool {
        return currentIndex == 0
    }

    /// Returns true if currently on the last image
    public var isAtLast: Bool {
        return currentIndex == totalCount - 1
    }
}
