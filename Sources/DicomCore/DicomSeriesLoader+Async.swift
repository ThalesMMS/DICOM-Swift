import Foundation

// MARK: - Async/Await Extensions

/// Progress update structure for async series loading.
///
/// Provides real-time progress information during asynchronous series loading operations.
/// Used by ``DicomSeriesLoader/loadSeriesWithProgress(in:)`` to report loading progress
/// through an `AsyncStream`.
///
/// ## Usage Example
/// ```swift
/// for try await progress in loader.loadSeriesWithProgress(in: directory) {
///     print("Loaded \(progress.slicesCopied) slices (\(Int(progress.fractionComplete * 100))%)")
///     if progress.fractionComplete >= 1.0 {
///         print("Final volume: \(progress.volumeInfo.width)×\(progress.volumeInfo.height)×\(progress.volumeInfo.depth)")
///     }
/// }
/// ```
public struct SeriesLoadProgress: Sendable {
    /// Fraction of loading complete (0.0 to 1.0)
    public let fractionComplete: Double

    /// Number of slices successfully copied to the volume buffer
    public let slicesCopied: Int

    /// Optional pixel data for the current slice being processed
    public let currentSliceData: Data?

    /// Volume descriptor with metadata (includes final data when loading is complete)
    public let volumeInfo: DicomSeriesVolume
}

extension DicomSeriesLoader {

    /// Asynchronously loads a DICOM series from a directory.
    ///
    /// This async method provides the same functionality as the synchronous
    /// ``loadSeries(in:progress:)`` but can be called from async contexts without
    /// blocking the calling thread.
    ///
    /// The file loading and volume assembly is performed on a background thread
    /// using `Task.detached` to avoid blocking the calling thread. Progress callbacks
    /// are still supported for monitoring loading progress.
    ///
    /// ## Example
    /// ```swift
    /// Task {
    ///     do {
    ///         let volume = try await loader.loadSeries(in: directoryURL) { fraction, slices, _, _ in
    ///             print("Loading: \(Int(fraction * 100))% (\(slices) slices)")
    ///         }
    ///         print("Loaded volume: \(volume.width)×\(volume.height)×\(volume.depth)")
    ///     } catch {
    ///         print("Failed to load series: \(error)")
    ///     }
    /// }
    /// ```
    ///
    /// Asynchronously loads a DICOM series from a directory, supporting cancellation and optional progress updates.
    /// - Parameters:
    ///   - directory: URL of the directory containing the DICOM series to load.
    ///   - progress: An optional callback invoked with incremental progress updates during loading.
    /// - Returns: The fully loaded `DicomSeriesVolume`.
    /// - Throws: Any error thrown by the underlying load operation, or an error resulting from task cancellation.
    public func loadSeries(
        in directory: URL,
        progress: ProgressHandler? = nil
    ) async throws -> DicomSeriesVolume {
        try Task.checkCancellation()
        let decoderFactory = self.decoderFactory
        let task = Task.detached(priority: .userInitiated) { () throws -> DicomSeriesVolume in
            try Task.checkCancellation()
            let loader = DicomSeriesLoader(decoderFactory: decoderFactory)
            let volume = try loader.loadSeries(in: directory, progress: progress)
            try Task.checkCancellation()
            return volume
        }

        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    /// Asynchronously loads a DICOM series from a directory with progress reporting via AsyncStream.
    ///
    /// This async method provides the same functionality as the synchronous
    /// ``loadSeries(in:progress:)-17egi`` but can be called from async contexts and
    /// provides progress updates through an `AsyncThrowingStream`.
    ///
    /// The file loading and volume assembly is performed on a background thread
    /// using `Task.detached` to avoid blocking the calling thread. Progress updates
    /// are yielded through the returned stream, allowing callers to monitor
    /// loading progress in real-time using a `for try await` loop.
    ///
    /// ## Example
    /// ```swift
    /// Task {
    ///     for try await progress in loader.loadSeriesWithProgress(in: directoryURL) {
    ///         print("Progress: \(Int(progress.fractionComplete * 100))%")
    ///         if progress.fractionComplete >= 1.0 {
    ///             let volume = progress.volumeInfo
    ///             print("Volume: \(volume.width)×\(volume.height)×\(volume.depth)")
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// Streams incremental progress updates while loading a DICOM series from a directory.
    /// 
    /// Progress updates are produced from a detached background task. If loading completes successfully the stream yields a final progress item with `fractionComplete == 1.0` and the completed `DicomSeriesVolume`. If loading fails or is cancelled, the stream finishes by throwing the encountered error. Terminating the stream cancels the background task that performs the load.
    /// - Parameter directory: The file-system directory URL containing the DICOM series to load.
    /// - Returns: An `AsyncThrowingStream` that yields `SeriesLoadProgress` updates; the stream yields incremental progress items, a final completed progress with the loaded volume, and finishes normally on success or finishes throwing an error if loading fails or is cancelled.
    public func loadSeriesWithProgress(
        in directory: URL
    ) -> AsyncThrowingStream<SeriesLoadProgress, Error> {
        AsyncThrowingStream { continuation in
            let decoderFactory = self.decoderFactory
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try Task.checkCancellation()

                    // Load series using synchronous method with progress callback
                    let loader = DicomSeriesLoader(decoderFactory: decoderFactory)
                    let volume = try loader.loadSeries(in: directory) { fraction, slicesCopied, sliceData, volumeInfo in
                        guard !Task.isCancelled else { return }

                        // Yield progress update through the stream
                        let progress = SeriesLoadProgress(
                            fractionComplete: fraction,
                            slicesCopied: slicesCopied,
                            currentSliceData: sliceData,
                            volumeInfo: volumeInfo
                        )
                        continuation.yield(progress)
                    }

                    try Task.checkCancellation()

                    // Yield final progress update with complete volume
                    let finalProgress = SeriesLoadProgress(
                        fractionComplete: 1.0,
                        slicesCopied: volume.depth,
                        currentSliceData: nil,
                        volumeInfo: volume
                    )
                    continuation.yield(finalProgress)

                    // Complete the stream successfully
                    continuation.finish()
                } catch {
                    // Complete the stream with error
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

}
