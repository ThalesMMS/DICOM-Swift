import Foundation

extension DicomSeriesLoader {
    /// Loads multiple DICOM series directories concurrently with progress tracking.
    ///
    /// This method processes multiple series directories in parallel using Swift's TaskGroup,
    /// enabling efficient concurrent loading for batch operations. Each series is loaded
    /// using the asynchronous `loadSeries(in:progress:)` overload and assembled into a complete volume.
    ///
    /// Progress is aggregated across all series and reported through the callback handler.
    /// The progress fraction represents the overall completion (number of series completed
    /// divided by total series count), and the completed count indicates how many series
    /// have been fully loaded.
    ///
    /// ## Performance Characteristics
    ///
    /// - **Concurrency**: Respects `maxConcurrency` limit to avoid overwhelming the system
    /// - **Memory**: Each series loads independently, memory scales with concurrent count
    /// - **Thread-Safe**: Uses TaskGroup for structured concurrency, safe for actor contexts
    /// - **Progress**: Aggregated progress across all series operations
    ///
    /// ## Example
    /// ```swift
    /// let loader = DicomSeriesLoader()
    /// let seriesDirectories = [seriesDir1, seriesDir2, seriesDir3]
    ///
    /// let volumes = try await loader.batchLoadSeries(
    ///     seriesDirectories: seriesDirectories,
    ///     maxConcurrency: 2
    /// ) { fraction, completed in
    ///     print("Progress: \(Int(fraction * 100))% - \(completed) series completed")
    /// }
    ///
    /// for (index, volume) in volumes.enumerated() {
    ///     print("Series \(index): \(volume.width)×\(volume.height)×\(volume.depth)")
    /// }
    /// ```
    ///
    /// Concurrently loads multiple DICOM series from the given directory URLs and returns volumes ordered to match the input.
    /// - Parameters:
    ///   - seriesDirectories: Array of directory `URL`s containing DICOM series to load.
    ///   - maxConcurrency: Maximum number of series load tasks to run concurrently (minimum 1).
    ///   - progressHandler: Optional sendable callback invoked after each series completes with the fraction complete (0.0–1.0) and the number of series completed.
    /// - Returns: An array of `DicomSeriesVolume` in the same order as `seriesDirectories`.
    /// - Throws: `DicomSeriesLoaderError.noDicomFiles` if an expected result is missing when reconstructing the ordered array; errors thrown by individual series loads are propagated.
    public func batchLoadSeries(
        seriesDirectories: [URL],
        maxConcurrency: Int = 2,
        progressHandler: (@Sendable (Double, Int) -> Void)? = nil
    ) async throws -> [DicomSeriesVolume] {
        // Early return for empty input
        guard !seriesDirectories.isEmpty else { return [] }

        // Ensure at least one task is scheduled before awaiting group.next().
        let effectiveMaxConcurrency = max(1, maxConcurrency)

        // Thread-safe counter for progress tracking
        final class Counter: @unchecked Sendable {
            private let lock = DicomLock()
            private var value = 0

            /// Atomically increments the internal counter and returns the updated value.
            /// Atomically increments the counter and returns the new value.
            /// - Returns: The counter's new value after incrementing.
            func increment() -> Int {
                lock.withLock {
                    value += 1
                    return value
                }
            }
        }

        let completedCount = Counter()
        let localDecoderFactory = decoderFactory

        // Store results indexed by original position
        var resultsByIndex: [Int: DicomSeriesVolume] = [:]

        // Use task group to load series concurrently
        try await withThrowingTaskGroup(of: (Int, DicomSeriesVolume).self) { group in
            // Enumerate directories to track ordering
            for (index, directory) in seriesDirectories.enumerated() {
                // Respect concurrency limit
                if index >= effectiveMaxConcurrency {
                    // Wait for one task to complete before adding more
                    guard let (completedIndex, volume) = try await group.next() else {
                        break
                    }
                    resultsByIndex[completedIndex] = volume

                    // Update progress
                    let completed = completedCount.increment()
                    let fraction = Double(completed) / Double(seriesDirectories.count)
                    progressHandler?(fraction, completed)
                }

                // Add task to load this series. Each task gets its own loader so the
                // per-series decoder cache remains scoped to that load operation.
                group.addTask {
                    let loader = DicomSeriesLoader(decoderFactory: localDecoderFactory)
                    let volume = try await loader.loadSeries(in: directory, progress: nil)
                    return (index, volume)
                }
            }

            // Collect remaining results
            for try await (index, volume) in group {
                resultsByIndex[index] = volume

                // Update progress
                let completed = completedCount.increment()
                let fraction = Double(completed) / Double(seriesDirectories.count)
                progressHandler?(fraction, completed)
            }
        }

        // Reconstruct results in original order
        var results: [DicomSeriesVolume] = []
        results.reserveCapacity(seriesDirectories.count)

        for index in 0..<seriesDirectories.count {
            guard let volume = resultsByIndex[index] else {
                // This should never happen, but provide error handling
                throw DicomSeriesLoaderError.noDicomFiles
            }
            results.append(volume)
        }

        return results
    }

    /// Loads multiple DICOM files concurrently using structured concurrency.
    ///
    /// This method processes multiple DICOM files in parallel using Swift's TaskGroup,
    /// enabling efficient concurrent loading for batch operations. Each file is loaded
    /// into a separate decoder instance, respecting the specified concurrency limit.
    ///
    /// The method returns an array of ``DicomFileResult`` instances in the same order
    /// as the input URLs, where each result contains either a successfully loaded decoder
    /// or the error that occurred. This allows callers to handle partial successes and
    /// identify which specific files failed.
    ///
    /// ## Performance Characteristics
    ///
    /// - **Concurrency**: Respects `maxConcurrency` limit to avoid overwhelming the system
    /// - **Memory**: Each decoder is independent, memory scales linearly with concurrent count
    /// - **Thread-Safe**: Uses TaskGroup for structured concurrency, safe for actor contexts
    ///
    /// ## Example
    /// ```swift
    /// let loader = DicomSeriesLoader()
    /// let urls = try FileManager.default.contentsOfDirectory(at: directoryURL,
    ///                                                          includingPropertiesForKeys: nil)
    /// let results = await loader.batchLoadFiles(urls: urls, maxConcurrency: 4)
    /// let successes = results.compactMap { result -> DCMDecoder? in
    ///     if case .success(let decoder) = result.result { return decoder }
    ///     return nil
    /// }
    /// print("Successfully loaded \(successes.count) of \(results.count) files")
    /// ```
    ///
    /// Concurrently loads multiple DICOM files and returns per-file results in the same order as the input URLs.
    /// - Parameters:
    ///   - urls: File URLs of DICOM files to load.
    ///   - maxConcurrency: Maximum number of concurrent file loads; values less than 1 are treated as 1.
    /// - Returns: An array of `DicomFileResult` ordered to match `urls`, where each element contains either the loaded decoder or an error describing that file's failure.
    public func batchLoadFiles(
        urls: [URL],
        maxConcurrency: Int = 4
    ) async -> [DicomFileResult] {
        // Early return for empty input
        guard !urls.isEmpty else { return [] }

        // Ensure at least one task is enqueued before waiting on group.next().
        let concurrency = max(1, maxConcurrency)

        // Create results array with same ordering as input
        var results: [DicomFileResult] = []
        results.reserveCapacity(urls.count)
        let localDecoderFactory = decoderFactory

        // Use dictionary to maintain ordering
        var resultsByIndex: [Int: DicomFileResult] = [:]

        await withTaskGroup(of: (Int, DicomFileResult).self) { group in
            // Enumerate URLs to track ordering
            for (index, url) in urls.enumerated() {
                // Respect concurrency limit
                if index >= concurrency {
                    // Wait for one task to complete before adding more
                    if let (completedIndex, result) = await group.next() {
                        resultsByIndex[completedIndex] = result
                    }
                }

                // Add task to load this file
                group.addTask {
                    let result = await Self.loadSingleFileStatic(
                        url: url,
                        factory: { fileURL in try localDecoderFactory(fileURL.path) }
                    )
                    return (index, result)
                }
            }

            // Collect remaining results
            for await (index, result) in group {
                resultsByIndex[index] = result
            }
        }

        // Reconstruct results in original order
        for index in 0..<urls.count {
            if let result = resultsByIndex[index] {
                results.append(result)
            } else {
                // This should never happen, but provide fallback
                results.append(DicomFileResult(
                    url: urls[index],
                    error: DICOMError.unknown(underlyingError: "Unknown error during batch loading")
                ))
            }
        }

        return results
    }
}


// MARK: - Private Batch Loading Helpers

private extension DicomSeriesLoader {
    /// Loads a single DICOM file, returning a result with either the decoder or an error.
    /// - Parameters:
    ///   - url: The file URL to load.
    ///   - factory: Sendable factory used to instantiate decoders.
    /// Loads a single DICOM file and produces a `DicomFileResult` describing the outcome.
    /// - Parameters:
    ///   - url: File URL of the DICOM file to load.
    ///   - factory: Decoder factory used to create a fresh decoder instance.
    /// Load a single DICOM file at the given URL using a fresh decoder produced by the provided factory.
    /// - Parameters:
    ///   - url: The file URL of the DICOM file to load.
    ///   - factory: A sendable factory that returns an already-loaded decoder for the given URL.
    /// - Returns: A `DicomFileResult` containing the decoder on success, or an error (`.fileNotFound` when the path is missing, otherwise `.invalidDICOMFormat`) on failure.
    static func loadSingleFileStatic(
        url: URL,
        factory: @escaping @Sendable (URL) throws -> DicomDecoderProtocol
    ) async -> DicomFileResult {
        let decoder: DicomDecoderProtocol
        do {
            decoder = try factory(url)
        } catch let error as DICOMError {
            return DicomFileResult(url: url, error: error)
        } catch {
            return DicomFileResult(
                url: url,
                error: DICOMError.unknown(underlyingError: "Decoder factory failed for \(url.path): \(error.localizedDescription)")
            )
        }

        if decoder.isValid() {
            return DicomFileResult(url: url, decoder: decoder)
        } else {
            let error: DICOMError
            if !FileManager.default.fileExists(atPath: url.path) {
                error = .fileNotFound(path: url.path)
            } else {
                error = .invalidDICOMFormat(reason: "Failed to load DICOM file at \(url.path)")
            }
            return DicomFileResult(url: url, error: error)
        }
    }
}
