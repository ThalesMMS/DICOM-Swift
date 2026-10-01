//
//  DCMDecoder+Async.swift
//
//  Async/await extensions for DCMDecoder providing modern concurrency
//  support for loading DICOM files and retrieving pixel data.
//
//  All async methods run on detached tasks with appropriate priority
//  levels to avoid blocking the main thread. Cancellation is propagated to
//  those tasks and checked before and after the synchronous decoder work.
//

import Foundation

enum DCMDecoderAsyncOperation {
    static func perform<Value: Sendable>(
        priority: TaskPriority,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let task = Task.detached(priority: priority) { () throws -> Value in
            try Task.checkCancellation()
            let value = try operation()
            try Task.checkCancellation()
            return value
        }

        return try await withTaskCancellationHandler(operation: {
            do {
                let value = try await task.value
                try Task.checkCancellation()
                return value
            } catch {
                try Task.checkCancellation()
                throw error
            }
        }, onCancel: {
            task.cancel()
        })
    }

    static func perform<Value: Sendable>(
        priority: TaskPriority,
        cancellationValue: Value,
        operation: @escaping @Sendable () -> Value
    ) async -> Value {
        guard !Task.isCancelled else { return cancellationValue }
        let task = Task.detached(priority: priority) { () -> Value in
            guard !Task.isCancelled else { return cancellationValue }
            let value = operation()
            guard !Task.isCancelled else { return cancellationValue }
            return value
        }

        return await withTaskCancellationHandler(operation: {
            let value = await task.value
            return Task.isCancelled ? cancellationValue : value
        }, onCancel: {
            task.cancel()
        })
    }
}

// MARK: - Async/Await Extensions

extension DCMDecoder {

    // MARK: - Async Throwing Initializers

    /// Asynchronously initializes a decoder by loading a DICOM file from
    /// the specified URL.  This async throwing initializer provides the
    /// same functionality as ``init(contentsOf:)`` but can be called from
    /// async contexts.
    ///
    /// The file loading is performed on a background thread using Task.detached
    /// to avoid blocking the calling thread.  For UI contexts, this provides
    /// a non-blocking alternative to the synchronous throwing initializer.
    ///
    /// Example usage:
    ///
    ///     Task {
    ///         do {
    ///             let decoder = try await DCMDecoder(contentsOf: fileURL)
    ///             let pixels = decoder.getPixels16()
    ///             // process pixels...
    ///         } catch {
    ///             print("Failed to load DICOM: \(error)")
    ///         }
    ///     }
    ///
    /// - Parameter url: File URL pointing to the DICOM file to load.
    /// - Throws: `CancellationError` if the calling task is cancelled,
    ///   ``DICOMError/fileNotFound(path:)`` if the file does not exist, or
    ///   ``DICOMError/invalidDICOMFormat(reason:)`` if the file cannot be parsed
    ///   as valid DICOM.
    public convenience init(contentsOf url: URL) async throws {
        // Initialize with default state
        self.init()

        try await DCMDecoderAsyncOperation.perform(priority: .userInitiated) {
            // Verify file exists before attempting to load
            let path = url.path
            guard FileManager.default.fileExists(atPath: path) else {
                throw DICOMError.fileNotFound(path: path)
            }

            try self.loadDicomFile(at: path)
        }
    }

    /// Asynchronously initializes a decoder by loading a DICOM file from
    /// the specified file path.  This async throwing initializer provides
    /// the same functionality as ``init(contentsOfFile:)`` but can be called
    /// from async contexts.
    ///
    /// The file loading is performed on a background thread using Task.detached
    /// to avoid blocking the calling thread.  For UI contexts, this provides
    /// a non-blocking alternative to the synchronous throwing initializer.
    ///
    /// Example usage:
    ///
    ///     Task {
    ///         do {
    ///             let decoder = try await DCMDecoder(contentsOfFile: "/path/to/file.dcm")
    ///             let pixels = decoder.getPixels16()
    ///             // process pixels...
    ///         } catch {
    ///             print("Failed to load DICOM: \(error)")
    ///         }
    ///     }
    ///
    /// - Parameter path: Absolute file system path to the DICOM file to load.
    /// - Throws: `CancellationError` if the calling task is cancelled,
    ///   ``DICOMError/fileNotFound(path:)`` if the file does not exist, or
    ///   ``DICOMError/invalidDICOMFormat(reason:)`` if the file cannot be parsed
    ///   as valid DICOM.
    public convenience init(contentsOfFile path: String) async throws {
        // Initialize with default state
        self.init()

        try await DCMDecoderAsyncOperation.perform(priority: .userInitiated) {
            // Verify file exists before attempting to load
            guard FileManager.default.fileExists(atPath: path) else {
                throw DICOMError.fileNotFound(path: path)
            }

            try self.loadDicomFile(at: path)
        }
    }

    // MARK: - Async Static Factory Methods

    /// Asynchronously loads a DICOM file from the specified URL using a
    /// static factory method pattern.  This async throwing factory method
    /// provides the same functionality as `load(from:)` but can be called
    /// from async contexts.
    ///
    /// This is a convenience wrapper around `init(contentsOf:)` that provides
    /// the same functionality with a factory method style.  The file loading is
    /// performed on a background thread using Task.detached to avoid blocking
    /// the calling thread.
    ///
    /// Example usage:
    ///
    ///     Task {
    ///         do {
    ///             let decoder = try await DCMDecoder.load(from: fileURL)
    ///             let pixels = decoder.getPixels16()
    ///             // process pixels...
    ///         } catch {
    ///             print("Failed to load DICOM: \(error)")
    ///         }
    ///     }
    ///
    /// - Parameter url: File URL pointing to the DICOM file to load.
    /// - Returns: Initialized DCMDecoder instance with the loaded DICOM file.
    /// - Throws: `CancellationError` if the calling task is cancelled,
    ///   ``DICOMError/fileNotFound(path:)`` if the file does not exist, or
    ///   ``DICOMError/invalidDICOMFormat(reason:)`` if the file cannot be parsed
    ///   as valid DICOM.
    public static func load(from url: URL) async throws -> Self {
        try await Self(contentsOf: url)
    }

    /// Asynchronously loads a DICOM file from the specified file path using a
    /// static factory method pattern.  This async throwing factory method
    /// provides the same functionality as `load(fromFile:)` but can be called
    /// from async contexts.
    ///
    /// This is a convenience wrapper around `init(contentsOfFile:)` that provides
    /// the same functionality with a factory method style.  The file loading is
    /// performed on a background thread using Task.detached to avoid blocking
    /// the calling thread.
    ///
    /// Example usage:
    ///
    ///     Task {
    ///         do {
    ///             let decoder = try await DCMDecoder.load(fromFile: "/path/to/file.dcm")
    ///             let pixels = decoder.getPixels16()
    ///             // process pixels...
    ///         } catch {
    ///             print("Failed to load DICOM: \(error)")
    ///         }
    ///     }
    ///
    /// - Parameter path: Absolute file system path to the DICOM file to load.
    /// - Returns: Initialized DCMDecoder instance with the loaded DICOM file.
    /// - Throws: `CancellationError` if the calling task is cancelled,
    ///   ``DICOMError/fileNotFound(path:)`` if the file does not exist, or
    ///   ``DICOMError/invalidDICOMFormat(reason:)`` if the file cannot be parsed
    ///   as valid DICOM.
    public static func load(fromFile path: String) async throws -> Self {
        try await Self(contentsOfFile: path)
    }

    // MARK: - Async File Loading Methods

    /// Loads and decodes a DICOM file asynchronously
    /// - Parameter filename: Path to the DICOM file
    /// - Returns: True if the file was successfully loaded and decoded; false
    ///   if loading fails or the calling task is cancelled.
    public func loadDICOMFileAsync(_ filename: String) async -> Bool {
        await DCMDecoderAsyncOperation.perform(priority: .userInitiated, cancellationValue: false) {
            try? self.loadDicomFile(at: filename)
            return self.fileReadSucceeded
        }
    }

    // MARK: - Async Pixel Retrieval Methods

    /// Retrieves 16-bit pixels asynchronously
    /// - Returns: Array of 16-bit pixel values, or nil when unavailable or
    ///   cancelled.
    public func getPixels16Async() async -> [UInt16]? {
        await DCMDecoderAsyncOperation.perform(priority: .userInitiated, cancellationValue: nil) {
            self.getPixels16()
        }
    }

    /// Retrieves 8-bit pixels asynchronously
    /// - Returns: Array of 8-bit pixel values, or nil when unavailable or
    ///   cancelled.
    public func getPixels8Async() async -> [UInt8]? {
        await DCMDecoderAsyncOperation.perform(priority: .userInitiated, cancellationValue: nil) {
            self.getPixels8()
        }
    }

    /// Retrieves 24-bit RGB pixels asynchronously
    /// - Returns: Array of 24-bit pixel values, or nil when unavailable or
    ///   cancelled.
    public func getPixels24Async() async -> [UInt8]? {
        await DCMDecoderAsyncOperation.perform(priority: .userInitiated, cancellationValue: nil) {
            self.getPixels24()
        }
    }

    /// Retrieves downsampled thumbnail pixels asynchronously
    /// - Parameter maxDimension: Maximum dimension for the thumbnail
    /// - Returns: Tuple with downsampled pixels and dimensions, or nil when
    ///   unavailable or cancelled.
    public func getDownsampledPixels16Async(maxDimension: Int = 150) async -> (pixels: [UInt16], width: Int, height: Int)? {
        await DCMDecoderAsyncOperation.perform(priority: .utility, cancellationValue: nil) {
            self.getDownsampledPixels16(maxDimension: maxDimension)
        }
    }

    /// Retrieves an 8-bit downsampled pixel buffer and its dimensions, scaling the image so its longer side does not exceed the given maximum while preserving aspect ratio.
    /// - Parameter maxDimension: Maximum length (in pixels) of the longer image side after downsampling; aspect ratio is preserved. Default is 150.
    /// - Returns: A tuple `(pixels: [UInt8], width: Int, height: Int)` containing
    ///   the downsampled pixel data and its dimensions, or `nil` when unavailable
    ///   or cancelled.
    public func getDownsampledPixels8Async(maxDimension: Int = 150) async -> (pixels: [UInt8], width: Int, height: Int)? {
        await DCMDecoderAsyncOperation.perform(priority: .utility, cancellationValue: nil) {
            self.getDownsampledPixels8(maxDimension: maxDimension)
        }
    }

    // MARK: - Batch Loading API

    /// Loads multiple DICOM files concurrently using structured concurrency.
    /// This method uses TaskGroup to process files in parallel while respecting
    /// the specified concurrency limit.
    ///
    /// The method preserves the input URL ordering in the returned results array.
    /// Partial failures are handled gracefully - each result contains either a
    /// successfully loaded decoder or an error describing what went wrong.
    ///
    /// Example usage:
    ///
    ///     let urls = [url1, url2, url3, url4]
    ///     let results = await DCMDecoder.loadBatch(urls: urls, maxConcurrency: 2)
    ///
    ///     for result in results {
    ///         if let decoder = result.decoder {
    ///             print("Loaded: \(decoder.width) x \(decoder.height)")
    ///         } else if let error = result.error {
    ///             switch error {
    ///             case .fileNotFound(let path):
    ///                 print("Missing file: \(path)")
    ///             default:
    ///                 print("Failed: \(error.localizedDescription)")
    ///             }
    ///         }
    ///     }
    ///
    /// Concurrently loads the provided DICOM file URLs and returns per-file results in the original input order.
    /// - Parameters:
    ///   - urls: The file URLs to load.
    ///   - maxConcurrency: The maximum number of files to load concurrently. Defaults to 4; values less than 1 will effectively behave like a single concurrent task.
    /// - Returns: An array of `DicomBatchResult` corresponding to `urls`, ordered to match the input. An empty `urls` array yields an empty result.
    public static func loadBatch(
        urls: [URL],
        maxConcurrency: Int = 4
    ) async -> [DicomBatchResult] {
        // Early return for empty input
        guard !urls.isEmpty else { return [] }

        // Ensure we always schedule at least one task to avoid waiting on an empty group.
        let concurrency = max(1, maxConcurrency)

        // Create results array with same ordering as input
        var results: [DicomBatchResult] = []
        results.reserveCapacity(urls.count)

        // Use dictionary to maintain ordering
        var resultsByIndex: [Int: DicomBatchResult] = [:]

        await withTaskGroup(of: (Int, DicomBatchResult).self) { group in
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
                    let result = await Self.loadSingleFile(url: url)
                    return (index, result)
                }
            }

            // Collect remaining results
            for await (completedIndex, result) in group {
                resultsByIndex[completedIndex] = result
            }
        }

        // Reconstruct results in original order
        for index in 0..<urls.count {
            if let result = resultsByIndex[index] {
                results.append(result)
            }
        }

        return results
    }

    /// Internal helper to load a single DICOM file and return a result.
    /// This method captures errors and returns them as part of the result
    /// rather than throwing, enabling batch operations to continue despite
    /// individual file failures.
    ///
    /// - Parameter url: File URL pointing to the DICOM file to load.
    /// - Returns: ``DicomBatchResult`` containing either the loaded decoder
    /// Attempts to load a single DICOM file and returns a `DicomBatchResult` describing the outcome.
    /// - Parameters:
    ///   - url: The file `URL` of the DICOM to load.
    /// - Returns: A `DicomBatchResult` containing the original `url` and either a loaded `DCMDecoder` on success or the encountered `DICOMError` on failure.
    private static func loadSingleFile(url: URL) async -> DicomBatchResult {
        do {
            let decoder = try await DCMDecoder(contentsOf: url)
            return DicomBatchResult(url: url, decoder: decoder, error: nil)
        } catch {
            let dicomError = (error as? DICOMError) ?? .unknown(underlyingError: String(describing: error))
            return DicomBatchResult(url: url, decoder: nil, error: dicomError)
        }
    }
}

// MARK: - Batch Loading Result Type

/// Result of loading a single DICOM file in a batch operation.
/// Contains either a successfully loaded decoder or an error describing
/// the failure. This allows batch operations to continue processing
/// remaining files even if some files fail to load.
public struct DicomBatchResult: Sendable {
    /// The file URL that was processed
    public let url: URL

    /// The successfully loaded decoder, or nil if loading failed
    public let decoder: DCMDecoder?

    /// The error that occurred, or nil if loading succeeded
    public let error: DICOMError?

    /// Whether the file loaded successfully
    public var isSuccess: Bool {
        return decoder != nil && error == nil
    }

    /// Whether the file failed to load
    public var isFailure: Bool {
        return !isSuccess
    }
}
