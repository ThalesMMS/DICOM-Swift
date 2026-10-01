//
//  DicomSeriesLoaderProtocol.swift
//
//  Protocol abstraction for DICOM series loader implementations.
//  Defines the public API for loading and assembling multi-slice
//  DICOM series from directories, ordering slices by Image Position
//  (Patient), computing spatial geometry, and assembling contiguous
//  3D volume buffers.  Implementations must support 16-bit grayscale
//  images and provide progress callbacks during loading operations.
//
//  Thread Safety:
//
//  All protocol methods must be thread-safe and support concurrent
//  access from multiple threads without requiring external
//  synchronization.
//

import Foundation
import simd

/// Protocol defining the public API for DICOM series loading.
///
/// ## Overview
///
/// ``DicomSeriesLoaderProtocol`` abstracts the functionality for loading and assembling multi-slice
/// DICOM series from directories. Implementations must handle directory traversal to find DICOM files,
/// validate slice consistency (dimensions, orientation), order slices by spatial position using
/// Image Position (Patient) tags, compute 3D geometry, and assemble a contiguous volume buffer.
///
/// The protocol enables dependency injection and testability by allowing mock implementations for
/// testing without requiring actual DICOM series. The primary implementation is ``DicomSeriesLoader``,
/// which provides full series assembly capabilities with progress tracking.
///
/// **Thread Safety:** All methods must be thread-safe and support concurrent access without data races.
/// Implementations should use internal locking to ensure data consistency, allowing safe use from
/// multiple threads without external synchronization.
///
/// ## Usage
///
/// Load a series with progress tracking:
///
/// ```swift
/// let loader: DicomSeriesLoaderProtocol = DicomSeriesLoader()
/// do {
///     let volume = try loader.loadSeries(in: directoryURL) { fraction, slices, data, vol in
///         print("Progress: \(Int(fraction * 100))% - \(slices) slices loaded")
///     }
///     print("Loaded: \(volume.width) × \(volume.height) × \(volume.depth)")
/// } catch {
///     print("Failed to load series: \(error)")
/// }
/// ```
///
/// Load asynchronously for non-blocking operation:
///
/// ```swift
/// Task {
///     do {
///         let volume = try await loader.loadSeries(in: directoryURL, progress: nil)
///         // Process volume
///     } catch {
///         print("Error: \(error)")
///     }
/// }
/// ```
///
/// Use async stream for real-time progress updates:
///
/// ```swift
/// Task {
///     for try await progress in loader.loadSeriesWithProgress(in: directoryURL) {
///         print("Loading: \(Int(progress.fractionComplete * 100))%")
///         if progress.fractionComplete >= 1.0 {
///             let volume = progress.volumeInfo
///             print("Complete: \(volume.width) × \(volume.height) × \(volume.depth)")
///         }
///     }
/// }
/// ```
///
/// ## Topics
///
/// ### Creating a Loader
///
/// - ``init()``
///
/// ### Loading Series
///
/// - ``loadSeries(in:progress:)-3nsso``
/// - ``loadSeries(in:progress:)-1oqxk``
/// - ``loadSeriesWithProgress(in:)``
///
/// ### Progress Tracking
///
/// - ``ProgressHandler``
public protocol DicomSeriesLoaderProtocol: AnyObject, Sendable {

    /// Progress callback handler invoked during series loading.
    /// - Parameters:
    ///   - fraction: Completion fraction (0.0 to 1.0)
    ///   - slicesCopied: Number of slices processed so far
    ///   - sliceData: Pixel data for the current slice
    ///   - volume: Partial volume descriptor with geometry metadata
    typealias ProgressHandler = @Sendable (Double, Int, Data?, DicomSeriesVolume) -> Void

    /// Initializes a new series loader instance.
    init()

    /// Loads a DICOM series from a directory, ordering slices by Image Position (Patient).
    ///
    /// This method:
    /// - Scans the directory for DICOM files (.dcm or extensionless)
    /// - Validates that all slices have consistent dimensions and orientation
    /// - Orders slices by their projection onto the normal vector
    /// - Computes spatial geometry (spacing, orientation, origin)
    /// - Assembles a contiguous 16-bit volume buffer
    /// - Invokes progress callbacks during loading
    ///
    /// - Parameters:
    ///   - directory: Directory containing DICOM slices
    ///   - progress: Optional callback invoked with (fractionComplete, slicesCopied, sliceData, volume)
    /// - Returns: `DicomSeriesVolume` with voxel buffer and geometry metadata
    /// - Throws: `DicomSeriesLoaderError` on validation or decoding failures
    func loadSeries(in directory: URL,
                    progress: ProgressHandler?) throws -> DicomSeriesVolume

    /// Asynchronously loads a DICOM series from a directory, ordering slices by Image Position (Patient).
    ///
    /// This async method performs the same operations as the synchronous version but allows
    /// non-blocking execution on background threads. Recommended for UI contexts to avoid
    /// blocking the main thread during long-running series loading operations.
    ///
    /// This method:
    /// - Scans the directory for DICOM files (.dcm or extensionless)
    /// - Validates that all slices have consistent dimensions and orientation
    /// - Orders slices by their projection onto the normal vector
    /// - Computes spatial geometry (spacing, orientation, origin)
    /// - Assembles a contiguous 16-bit volume buffer
    /// - Invokes progress callbacks during loading
    ///
    /// - Parameters:
    ///   - directory: Directory containing DICOM slices
    ///   - progress: Optional callback invoked with (fractionComplete, slicesCopied, sliceData, volume)
    /// - Returns: `DicomSeriesVolume` with voxel buffer and geometry metadata
    /// - Throws: `DicomSeriesLoaderError` on validation or decoding failures
    ///
    /// - Example:
    /// ```swift
    /// Task {
    ///     do {
    ///         let loader = DicomSeriesLoader()
    ///         let volume = try await loader.loadSeries(in: directoryURL) { fraction, slices, data, vol in
    ///             print("Loading: \(Int(fraction * 100))% (\(slices) slices)")
    ///         }
    ///         print("Loaded volume: \(volume.width) x \(volume.height) x \(volume.depth)")
    ///     } catch {
    ///         print("Failed to load series: \(error)")
    ///     }
    /// }
    /// ```
    func loadSeries(in directory: URL,
                    progress: ProgressHandler?) async throws -> DicomSeriesVolume

    /// Asynchronously loads a DICOM series with progress updates via AsyncThrowingStream.
    ///
    /// This method provides real-time progress updates through an async stream, allowing
    /// callers to observe loading progress using Swift's async iteration. Each progress
    /// update includes the current completion fraction, number of slices processed,
    /// current slice data, and partial volume information.
    ///
    /// This method:
    /// - Scans the directory for DICOM files (.dcm or extensionless)
    /// - Validates that all slices have consistent dimensions and orientation
    /// - Orders slices by their projection onto the normal vector
    /// - Computes spatial geometry (spacing, orientation, origin)
    /// - Assembles a contiguous 16-bit volume buffer
    /// - Yields progress updates through the async stream
    ///
    /// - Parameter directory: Directory containing DICOM slices
    /// - Returns: `AsyncThrowingStream` yielding `SeriesLoadProgress` updates
    ///
    /// - Example:
    /// ```swift
    /// Task {
    ///     let loader = DicomSeriesLoader()
    ///     do {
    ///         for try await progress in loader.loadSeriesWithProgress(in: directoryURL) {
    ///             print("Loading: \(Int(progress.fractionComplete * 100))% (\(progress.slicesCopied) slices)")
    ///             if progress.fractionComplete >= 1.0 {
    ///                 print("Complete! Volume: \(progress.volumeInfo.width) x \(progress.volumeInfo.height) x \(progress.volumeInfo.depth)")
    ///             }
    ///         }
    ///     } catch {
    ///         print("Failed to load series: \(error)")
    ///     }
    /// }
    /// ```
    func loadSeriesWithProgress(in directory: URL) -> AsyncThrowingStream<SeriesLoadProgress, Error>
}

/// Protocol for concurrent per-file DICOM probing.
///
/// This keeps study scanning injectable without requiring ``StudyDataService`` to
/// construct a concrete ``DicomSeriesLoader`` internally.
public protocol DicomBatchFileLoading: AnyObject, Sendable {
    /// Load multiple DICOM files concurrently and return one result per input URL.
    /// - Parameters:
    ///   - urls: File URLs to probe.
    ///   - maxConcurrency: Maximum number of concurrent file loads.
    /// - Returns: Results ordered to match the input URLs.
    func batchLoadFiles(urls: [URL], maxConcurrency: Int) async -> [DicomFileResult]
}

extension DicomSeriesLoader: DicomBatchFileLoading {}
