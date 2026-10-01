//
//  StudyBrowserViewModel.swift
//  DicomSwiftUIExample
//
//  ViewModel for managing DICOM study browser state and operations
//
//  This view model handles the complete lifecycle of study browsing: loading studies
//  from directories, filtering/searching, state management, and error handling. It
//  coordinates StudyDataService to provide a SwiftUI-friendly API with reactive
//  state updates via @Published properties.
//
//  The view model supports asynchronous study loading, search/filter operations,
//  and maintains selection state. It uses dependency injection for testability
//  and follows the protocol-based architecture of the library.
//
//  Thread Safety:
//
//  All methods are marked with @MainActor and run on the main thread, ensuring UI
//  updates are safe. The ViewModel uses structured concurrency for background
//  operations. @Published properties automatically update the UI when changed.
//
//  Performance Characteristics:
//
//  Study loading operations are performed asynchronously using Swift concurrency.
//  Large directory scans are optimized with concurrent file processing. Search and
//  filter operations are performed synchronously but are optimized for typical
//  study collections (10-1000 studies).
//

import Foundation
import SwiftUI
import Combine
import DicomCore

// MARK: - Loading State

/// Loading state for study browser operations.
///
/// Represents the current state of study loading operations.
/// Used by ``StudyBrowserViewModel`` to track progress and communicate status to views.
///
public enum StudyBrowserLoadingState: Equatable {
    /// No operation in progress
    case idle

    /// Loading studies from directory
    case loading

    /// Studies successfully loaded
    case loaded

    /// Error occurred during loading
    case failed(DICOMError)

    /// Refreshing existing studies
    case refreshing

    public static func == (lhs: StudyBrowserLoadingState, rhs: StudyBrowserLoadingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.loaded, .loaded), (.refreshing, .refreshing):
            return true
        case (.failed(let lhsError), .failed(let rhsError)):
            return lhsError == rhsError
        default:
            return false
        }
    }
}

// MARK: - Sort Options

/// Sort options for study list
public enum StudySortOption: String, CaseIterable, Identifiable {
    case studyDateDesc = "Study Date (Newest)"
    case studyDateAsc = "Study Date (Oldest)"
    case patientName = "Patient Name"
    case importDate = "Import Date"

    public var id: String { rawValue }

    var displayName: String { rawValue }
}

// MARK: - Filter Options

/// Filter options for study list
public struct StudyFilterOptions: Equatable {
    /// Filter by modality (nil = show all)
    public var modality: DICOMModality?

    /// Filter by import status (nil = show all)
    public var importStatus: ImportStatus?

    /// Search query for patient name/ID/description
    public var searchQuery: String

    public init(
        modality: DICOMModality? = nil,
        importStatus: ImportStatus? = nil,
        searchQuery: String = ""
    ) {
        self.modality = modality
        self.importStatus = importStatus
        self.searchQuery = searchQuery
    }

    /// Check if any filters are active
    public var hasActiveFilters: Bool {
        modality != nil || importStatus != nil || !searchQuery.isEmpty
    }

    /// Reset all filters
    public mutating func reset() {
        modality = nil
        importStatus = nil
        searchQuery = ""
    }
}

// MARK: - View Model

/// View model for managing DICOM study browser state.
///
/// ## Overview
///
/// ``StudyBrowserViewModel`` provides reactive state management for study browsing
/// in SwiftUI applications. It handles the complete study management pipeline:
/// loading studies from directories, search/filter operations, error handling,
/// and state updates. The view model uses ``StudyDataService`` internally for
/// all data operations.
///
/// **Key Features:**
/// - Reactive state with `@Published` properties
/// - Async/await support for non-blocking operations
/// - Search and filter capabilities
/// - Sort options (date, name, import date)
/// - Selection state management
/// - Comprehensive error handling with recovery suggestions
/// - Thread-safe operations with main actor isolation
/// - Dependency injection for testability
///
/// ## Usage
///
/// Basic usage with study loading:
///
/// ```swift
/// struct StudyBrowserView: View {
///     @StateObject private var viewModel = StudyBrowserViewModel()
///
///     var body: some View {
///         List(viewModel.filteredStudies) { study in
///             StudyRow(study: study)
///         }
///         .searchable(text: $viewModel.filterOptions.searchQuery)
///         .task {
///             await viewModel.loadStudies(from: studyDirectory)
///         }
///         .refreshable {
///             await viewModel.refresh()
///         }
///     }
/// }
/// ```
///
/// Using filters and sorting:
///
/// ```swift
/// @StateObject private var viewModel = StudyBrowserViewModel()
///
/// // Filter by modality
/// viewModel.filterOptions.modality = .ct
///
/// // Search by patient name
/// viewModel.filterOptions.searchQuery = "John"
///
/// // Sort by study date
/// viewModel.sortOption = .studyDateDesc
///
/// // Reset filters
/// viewModel.resetFilters()
/// ```
///
/// With dependency injection for testing:
///
/// ```swift
/// // Production
/// let viewModel = StudyBrowserViewModel(
///     studyDataService: StudyDataService(
///         decoderFactory: { try DCMDecoder(contentsOfFile: $0) }
///     )
/// )
///
/// // Testing
/// let mockService = MockStudyDataService()
/// let testViewModel = StudyBrowserViewModel(
///     studyDataService: mockService
/// )
/// ```
///
/// ## Topics
///
/// ### Creating a View Model
///
/// - ``init(studyDataService:)``
///
/// ### Loading Studies
///
/// - ``loadStudies(from:)``
/// - ``loadStudiesFromMultiplePaths(_:)``
/// - ``refresh()``
/// - ``addStudy(_:)``
/// - ``removeStudy(_:)``
///
/// ### Filtering and Searching
///
/// - ``filterOptions``
/// - ``sortOption``
/// - ``filteredStudies``
/// - ``resetFilters()``
///
/// ### Selection Management
///
/// - ``selectedStudy``
/// - ``selectStudy(_:)``
///
/// ### State Properties
///
/// - ``state``
/// - ``studies``
/// - ``error``
/// - ``isEmpty``
/// - ``studyCount``
///
@MainActor
public final class StudyBrowserViewModel: ObservableObject {

    // MARK: - Published Properties

    /// Current loading state
    @Published public private(set) var state: StudyBrowserLoadingState = .idle

    /// All loaded studies
    @Published public private(set) var studies: [ImportedStudy] = []

    /// Currently selected study (nil when no selection)
    @Published public var selectedStudy: ImportedStudy?

    /// Filter options for study list
    @Published public var filterOptions: StudyFilterOptions = StudyFilterOptions()

    /// Current sort option
    @Published public var sortOption: StudySortOption = .studyDateDesc

    /// Current error (nil when no error)
    @Published public private(set) var error: DICOMError?

    // MARK: - Private Properties

    private let logger: LoggerProtocol
    private let studyDataService: StudyDataService
    private var cancellables = Set<AnyCancellable>()

    private static let dicomDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - Computed Properties

    /// Filtered and sorted studies based on current options
    public var filteredStudies: [ImportedStudy] {
        var filtered = studies

        // Apply modality filter
        if let modality = filterOptions.modality {
            filtered = filtered.filtered(by: modality)
        }

        // Apply status filter
        if let status = filterOptions.importStatus {
            filtered = filtered.filtered(by: status)
        }

        // Apply search query
        if !filterOptions.searchQuery.isEmpty {
            filtered = filtered.search(query: filterOptions.searchQuery)
        }

        // Apply sort
        switch sortOption {
        case .studyDateDesc:
            filtered = filtered.sortedByStudyDate()
        case .studyDateAsc:
            filtered = filtered.sortedByStudyDate().reversed()
        case .patientName:
            filtered = filtered.sortedByPatientName()
        case .importDate:
            filtered = filtered.sortedByImportDate()
        }

        return filtered
    }

    /// Whether the study list is empty
    public var isEmpty: Bool {
        studies.isEmpty
    }

    /// Total number of studies
    public var studyCount: Int {
        studies.count
    }

    /// Number of filtered studies
    public var filteredStudyCount: Int {
        filteredStudies.count
    }

    // MARK: - Initialization

    /// Creates a new study browser view model.
    ///
    /// - Parameter studyDataService: Service for study data operations (uses default if not provided)
    ///
    /// ## Example
    /// ```swift
    /// // Use default service
    /// let viewModel = StudyBrowserViewModel()
    ///
    /// // Use custom service
    /// let customService = StudyDataService(
    ///     decoderFactory: { try DCMDecoder(contentsOfFile: $0) }
    /// )
    /// let viewModel = StudyBrowserViewModel(studyDataService: customService)
    /// ```
    public init(
        studyDataService: StudyDataService? = nil
    ) {
        // Initialize service with default decoder factory if not provided
        self.studyDataService = studyDataService ?? StudyDataService(
            decoderFactory: { path in try DCMDecoder(contentsOfFile: path) }
        )
        self.logger = DicomLogger.make(subsystem: "com.dicomswiftuiexample", category: "StudyBrowser")

        logger.info("📚 StudyBrowserViewModel initialized")

        // Setup reactive updates for filter/sort changes
        setupObservers()
    }

    // MARK: - Public Methods

    /// Load studies from a directory path.
    ///
    /// This method asynchronously scans the specified directory for DICOM files,
    /// extracts metadata, and populates the study list. It replaces any existing
    /// studies in the list.
    ///
    /// - Parameter directoryPath: Absolute path to directory containing DICOM files
    ///
    /// ## Example
    /// ```swift
    /// await viewModel.loadStudies(from: "/path/to/studies")
    /// ```
    ///
    public func loadStudies(from directoryPath: String) async {
        logger.info("📂 Loading studies from: \(directoryPath)")
        state = .loading
        error = nil

        do {
            let metadata = try await studyDataService.scanDICOMFilesWithMetadata(in: directoryPath)
            let groupedStudies = studyDataService.groupStudiesByUID(metadata)

            studies = groupedStudies.values
                .compactMap(makeImportedStudy(from:))
                .sortedByStudyDate()
            state = .loaded
            logger.info("✅ Loaded \(studies.count) studies")
        } catch let dicomError as DICOMError {
            studies = []
            error = dicomError
            state = .failed(dicomError)
            logger.error("❌ Failed to load studies: \(dicomError.localizedDescription)")
        } catch {
            let dicomError = DICOMError.fileReadError(
                path: directoryPath,
                underlyingError: error.localizedDescription
            )
            studies = []
            self.error = dicomError
            state = .failed(dicomError)
            logger.error("❌ Failed to load studies: \(dicomError.localizedDescription)")
        }
    }

    /// Load studies from multiple directory paths.
    ///
    /// This method concurrently scans multiple directories and combines the results.
    /// Useful for loading studies from multiple sources simultaneously.
    ///
    /// - Parameter paths: Array of absolute directory paths
    ///
    /// ## Example
    /// ```swift
    /// await viewModel.loadStudiesFromMultiplePaths([
    ///     "/path/to/studies1",
    ///     "/path/to/studies2"
    /// ])
    /// ```
    public func loadStudiesFromMultiplePaths(_ paths: [String]) async {
        logger.info("📂 Loading studies from \(paths.count) directories")
        state = .loading
        error = nil

        var allStudies: [ImportedStudy] = []

        for path in paths {
            await loadStudies(from: path)
            allStudies.append(contentsOf: studies)
        }

        studies = allStudies
        state = .loaded
        logger.info("✅ Loaded \(studies.count) studies from multiple directories")
    }

    /// Refresh the current study list.
    ///
    /// Re-loads studies from their original storage paths. Useful for pull-to-refresh
    /// functionality in the UI.
    ///
    /// ## Example
    /// ```swift
    /// .refreshable {
    ///     await viewModel.refresh()
    /// }
    /// ```
    public func refresh() async {
        logger.info("🔄 Refreshing study list")
        state = .refreshing

        // Get unique storage paths from current studies
        let paths = Set(studies.map { $0.storagePath })

        if paths.isEmpty {
            state = .loaded
            return
        }

        // Reload from paths
        await loadStudiesFromMultiplePaths(Array(paths))
    }

    /// Add a study to the list.
    ///
    /// - Parameter study: The study to add
    ///
    /// ## Example
    /// ```swift
    /// let newStudy = ImportedStudy(...)
    /// viewModel.addStudy(newStudy)
    /// ```
    public func addStudy(_ study: ImportedStudy) {
        studies.append(study)
        state = .loaded
        logger.info("📚 Added study: \(study.displayPatientName) (total: \(studies.count))")
    }

    /// Report a startup or storage initialization failure through the normal loading state.
    ///
    /// - Parameter error: The DICOM error to surface to observers.
    public func handleStartupError(_ error: DICOMError) {
        self.error = error
        state = .failed(error)
        logger.error("❌ Startup failed: \(error.localizedDescription)")
    }

    /// Clear the current error after it has been presented.
    public func clearError() {
        error = nil
        if case .failed = state {
            state = studies.isEmpty ? .idle : .loaded
        }
    }

    /// Remove a study from the list.
    ///
    /// - Parameter study: The study to remove
    ///
    /// ## Example
    /// ```swift
    /// viewModel.removeStudy(study)
    /// ```
    public func removeStudy(_ study: ImportedStudy) {
        logger.info("➖ Removing study: \(study.studyInstanceUID)")
        studies.removeAll { $0.id == study.id }

        // Clear selection if removed study was selected
        if selectedStudy?.id == study.id {
            selectedStudy = nil
        }
    }

    /// Select a study.
    ///
    /// - Parameter study: The study to select (nil to clear selection)
    ///
    /// ## Example
    /// ```swift
    /// viewModel.selectStudy(study)
    /// ```
    public func selectStudy(_ study: ImportedStudy?) {
        selectedStudy = study

        if let study = study {
            logger.debug("🎯 Selected study: \(study.studyInstanceUID)")
        } else {
            logger.debug("🎯 Cleared study selection")
        }
    }

    /// Reset all filters to default values.
    ///
    /// ## Example
    /// ```swift
    /// viewModel.resetFilters()
    /// ```
    public func resetFilters() {
        logger.info("🔄 Resetting filters")
        filterOptions.reset()
    }

    /// Reset the view model to initial state.
    ///
    /// Clears all studies, selections, and resets state.
    ///
    /// ## Example
    /// ```swift
    /// viewModel.reset()
    /// ```
    public func reset() {
        logger.info("🔄 Resetting view model")
        studies = []
        selectedStudy = nil
        filterOptions.reset()
        sortOption = .studyDateDesc
        state = .idle
        error = nil
    }

    // MARK: - Private Methods

    private func setupObservers() {
        // Automatically clear selection when filters change
        Publishers.CombineLatest3(
            $filterOptions,
            $sortOption,
            $studies
        )
        .dropFirst() // Skip initial values
        .sink { [weak self] _, _, _ in
            // Keep selection if it's still in filtered results
            guard let self = self, let selected = self.selectedStudy else { return }

            if !self.filteredStudies.contains(where: { $0.id == selected.id }) {
                self.selectedStudy = nil
            }
        }
        .store(in: &cancellables)
    }

    private func makeImportedStudy(from metadata: [StudyMetadata]) -> ImportedStudy? {
        guard let first = metadata.first else { return nil }

        let filePaths = metadata.map(\.filePath)
        let series = makeSeriesInfo(from: metadata)
        let totalFileSize = metadata.reduce(Int64(0)) { total, metadata in
            total + metadata.fileSize
        }

        let patientModel = PatientModel(
            patientName: first.patientName,
            patientID: first.patientID,
            patientSex: parsePatientSex(first.patientSex),
            patientAge: normalizedOptional(first.patientAge),
            studyInstanceUID: first.studyInstanceUID,
            studyDate: parseDICOMDate(first.studyDate),
            studyDescription: normalizedOptional(first.studyDescription),
            modality: parseModality(first.modality),
            bodyPartExamined: normalizedOptional(first.bodyPartExamined),
            institutionName: normalizedOptional(first.institutionName),
            numberOfImages: metadata.count,
            fileSize: totalFileSize
        )

        return ImportedStudy.from(
            patientModel: patientModel,
            storagePath: commonDirectory(for: filePaths),
            series: series
        )
    }

    private func makeSeriesInfo(from metadata: [StudyMetadata]) -> [SeriesInfo] {
        let groupedSeries = Dictionary(grouping: metadata, by: \.seriesInstanceUID)
            .map { seriesInstanceUID, seriesMetadata in
                (seriesInstanceUID: seriesInstanceUID, seriesMetadata: seriesMetadata)
            }
            .sorted { lhs, rhs in
                let lhsInstance = lhs.seriesMetadata.map(\.instanceNumber).min() ?? 0
                let rhsInstance = rhs.seriesMetadata.map(\.instanceNumber).min() ?? 0
                if lhsInstance != rhsInstance {
                    return lhsInstance < rhsInstance
                }
                return lhs.seriesInstanceUID < rhs.seriesInstanceUID
            }

        return groupedSeries
            .enumerated()
            .map { index, groupedSeries in
                let seriesMetadata = groupedSeries.seriesMetadata
                let sortedMetadata = seriesMetadata.sorted { lhs, rhs in
                    if lhs.instanceNumber != rhs.instanceNumber {
                        return lhs.instanceNumber < rhs.instanceNumber
                    }
                    return lhs.filePath < rhs.filePath
                }
                let first = sortedMetadata[0]

                return SeriesInfo(
                    seriesInstanceUID: first.seriesInstanceUID,
                    seriesNumber: index + 1,
                    modality: parseModality(first.modality),
                    numberOfImages: sortedMetadata.count,
                    imagePaths: sortedMetadata.map(\.filePath),
                    thumbnailPath: nil
                )
            }
    }

    private func parseModality(_ modalityString: String) -> DICOMModality {
        switch modalityString.uppercased() {
        case "CT": return .ct
        case "MR": return .mr
        case "DX": return .dx
        case "CR": return .cr
        case "US": return .us
        case "MG": return .mg
        case "RF": return .rf
        case "XC": return .xc
        case "SC": return .sc
        case "PT": return .pt
        case "NM": return .nm
        default: return .unknown
        }
    }

    private func parsePatientSex(_ sexString: String) -> PatientSex {
        switch sexString.uppercased() {
        case "M": return .male
        case "F": return .female
        case "O": return .other
        default: return .unknown
        }
    }

    private func parseDICOMDate(_ dateString: String) -> Date? {
        guard dateString.count == 8 else { return nil }

        return Self.dicomDateFormatter.date(from: dateString)
    }

    private func normalizedOptional(_ value: String) -> String? {
        if value.isEmpty || value == "Unknown" || value == "Unknown Date" || value == "Unknown Location" {
            return nil
        }
        return value
    }

    private func commonDirectory(for filePaths: [String]) -> String {
        let directories = filePaths.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().pathComponents
        }

        guard var common = directories.first else {
            return ""
        }

        for components in directories.dropFirst() {
            common = Array(zip(common, components).prefix { pair in
                pair.0 == pair.1
            }.map { $0.0 })
        }

        guard !common.isEmpty else { return "/" }
        return NSString.path(withComponents: common)
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension StudyBrowserViewModel {
    /// Create view model with sample data for previews
    public static var preview: StudyBrowserViewModel {
        let viewModel = StudyBrowserViewModel()
        Task { @MainActor in
            viewModel.studies = ImportedStudy.samples
            viewModel.state = .loaded
        }
        return viewModel
    }
}
#endif
