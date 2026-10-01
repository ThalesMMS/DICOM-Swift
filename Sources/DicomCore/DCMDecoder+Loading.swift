import Foundation

extension DCMDecoder {
    /// Convenience initializer that loads a DICOM file from the
    /// specified URL.  This is the recommended Swift-idiomatic way to
    /// create a decoder.  The file is loaded and parsed immediately;
    /// if loading fails an error is thrown.
    ///
    /// Example usage:
    ///
    ///     do {
    ///         let decoder = try DCMDecoder(contentsOf: fileURL)
    ///         let pixels = decoder.getPixels16()
    ///         // process pixels...
    ///     } catch DICOMError.fileNotFound(let path) {
    ///         print("File not found: \(path)")
    ///     } catch DICOMError.invalidDICOMFormat(let reason) {
    ///         print("Invalid DICOM: \(reason)")
    ///     } catch {
    ///         print("Unexpected error: \(error)")
    ///     }
    ///
    /// - Parameter url: File URL pointing to the DICOM file to load.
    /// - Throws: ``DICOMError/fileNotFound(path:)`` if the file does
    ///   not exist, or ``DICOMError/invalidDICOMFormat(reason:)`` if
    ///   the file cannot be parsed as valid DICOM.
    public convenience init(contentsOf url: URL) throws {
        self.init()
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw DICOMError.fileNotFound(path: path)
        }
        try loadDicomFile(at: path)
    }

    /// Convenience initializer that loads a DICOM file from the
    /// specified file path.  This is a Swift-idiomatic alternative
    /// to `init(contentsOf:)` for workflows that work directly with
    /// String paths instead of URL objects.  The file is loaded and
    /// parsed immediately; if loading fails an error is thrown.
    ///
    /// The initializer validates file existence and DICOM format,
    /// throwing descriptive errors if any validation fails.  Unlike
    /// the legacy ``setDicomFilename(_:)`` API, this initializer follows
    /// Swift best practices by throwing errors instead of relying on
    /// boolean success flags.  The underlying file loading mechanism is
    /// identical to `init(contentsOf:)`.
    ///
    /// Example usage:
    ///
    ///     do {
    ///         let decoder = try DCMDecoder(contentsOfFile: "/path/to/file.dcm")
    ///         let pixels = decoder.getPixels16()
    ///         // process pixels...
    ///     } catch DICOMError.fileNotFound(let path) {
    ///         print("File not found: \(path)")
    ///     } catch DICOMError.invalidDICOMFormat(let reason) {
    ///         print("Invalid DICOM: \(reason)")
    ///     } catch {
    ///         print("Unexpected error: \(error)")
    ///     }
    ///
    /// - Parameter path: Absolute file system path to the DICOM file to load.
    /// - Throws: ``DICOMError/fileNotFound(path:)`` if the file does
    ///   not exist, or ``DICOMError/invalidDICOMFormat(reason:)`` if
    ///   the file cannot be parsed as valid DICOM.
    public convenience init(contentsOfFile path: String) throws {
        self.init()
        guard FileManager.default.fileExists(atPath: path) else {
            throw DICOMError.fileNotFound(path: path)
        }
        try loadDicomFile(at: path)
    }

    /// Convenience initializer that loads DICOM Part 10 bytes directly from
    /// memory. The buffer is parsed immediately and retained by the decoder,
    /// so callers do not need to serialize sensitive inputs to a temporary
    /// file before decoding.
    ///
    /// - Parameter data: In-memory DICOM Part 10 bytes to load.
    /// - Throws: ``DICOMError/invalidDICOMFormat(reason:)`` if the buffer
    ///   cannot be parsed as valid DICOM.
    public convenience init(data: Data) throws {
        self.init()
        try loadDicomData(data, sourceDescription: "<in-memory>")
    }

    /// Static factory method that loads a DICOM file from the
    /// specified URL.  This provides an alternative to the throwing
    /// initializer for developers who prefer static factory methods.
    /// The file is loaded and parsed immediately; if loading fails
    /// an error is thrown.
    ///
    /// This method is semantically equivalent to `init(contentsOf:)`
    /// but may be preferred in contexts where factory methods are more
    /// idiomatic (e.g., when chaining with other static methods or
    /// when explicitly showing the allocation step).
    ///
    /// Example usage:
    ///
    ///     do {
    ///         let decoder = try DCMDecoder.load(from: fileURL)
    ///         let pixels = decoder.getPixels16()
    ///         // process pixels...
    ///     } catch DICOMError.fileNotFound(let path) {
    ///         print("File not found: \(path)")
    ///     } catch DICOMError.invalidDICOMFormat(let reason) {
    ///         print("Invalid DICOM: \(reason)")
    ///     } catch {
    ///         print("Unexpected error: \(error)")
    ///     }
    ///
    /// - Parameter url: A file URL pointing to the DICOM file to load.
    /// - Returns: A `DCMDecoder` configured with metadata from the specified file.
    /// - Throws: `DICOMError.fileNotFound(path:)` if the file does not exist; `DICOMError.invalidDICOMFormat(reason:)` if the file cannot be parsed as a valid DICOM.
    public static func load(from url: URL) throws -> Self {
        try Self(contentsOf: url)
    }

    /// Static factory method for loading DICOM files from a String file path.
    ///
    /// Provides an alternative factory pattern for developers who prefer
    /// static method initialization or work primarily with String paths.
    /// This is a convenience wrapper around `init(contentsOfFile:)` that
    /// provides the same functionality with a factory method style.
    ///
    /// **Example:**
    ///
    ///     do {
    ///         let decoder = try DCMDecoder.load(fromFile: "/path/to/scan.dcm")
    ///         let patientName = decoder.info(for: 0x00100010)
    ///         print("Patient: \(patientName)")
    ///     } catch DICOMError.fileNotFound(let path) {
    ///         print("File not found: \(path)")
    ///     } catch DICOMError.invalidDICOMFormat(let reason) {
    ///         print("Invalid DICOM: \(reason)")
    ///     } catch {
    ///         print("Unexpected error: \(error)")
    ///     }
    ///
    /// - Parameter path: Filesystem path to the DICOM file to load.
    /// - Returns: A configured `DCMDecoder` loaded from the specified file.
    /// - Throws: `DICOMError.fileNotFound(path:)` if the file does not exist; `DICOMError.invalidDICOMFormat(reason:)` if the file cannot be parsed as a valid DICOM.
    public static func load(fromFile path: String) throws -> Self {
        try Self(contentsOfFile: path)
    }


    // MARK: - Public API

    /// Loads a DICOM file by filesystem path, parsing header/metadata only.
    ///
    /// A no-op if `filename` is empty, if the same file is already loaded, or if a different file
    /// is already loaded successfully (a warning is logged in that case). Pixel data is decoded
    /// lazily on the first `getPixels*` call.
    ///
    /// - Parameter filename: Filesystem path of the DICOM file to load.
    @available(*, deprecated, message: "Use init(contentsOf:) throws or init(contentsOfFile:) throws instead.")
    public func setDicomFilename(_ filename: String) {
        do {
            try loadDicomFile(at: filename)
        } catch is CancellationError {
            return
        } catch {
            logger.warning("Failed to load file at \(filename): \(error)")
            synchronized {
                dicomFileName = ""
                fileReadSucceeded = false
            }
        }
    }

    /// Loads a DICOM file into the decoder, preserving original I/O errors for throwing APIs.
    func loadDicomFile(at filename: String) throws {
        try synchronized {
            try loadDicomFileUnsafe(at: filename)
        }
    }

    /// Loads in-memory DICOM Part 10 bytes into the decoder.
    func loadDicomData(_ data: Data, sourceDescription: String = "<in-memory>") throws {
        try synchronized {
            try loadDicomDataUnsafe(data, sourceDescription: sourceDescription)
        }
    }

    private func loadDicomFileUnsafe(at filename: String) throws {
        guard !filename.isEmpty else {
            return
        }
        // Avoid re-reading the same file
        if dicomFileName == filename {
            return
        }
        // Prevent loading different file if one is already loaded successfully
        // DCMDecoder is designed for single-file use per instance
        if fileReadSucceeded && !dicomFileName.isEmpty {
            logger.warning("Attempting to load '\(filename)' but decoder already has '\(dicomFileName)' loaded. Create a new DCMDecoder instance for each file.")
            return
        }

        do {
            let fileURL = URL(fileURLWithPath: filename)

            // OPTIMIZATION: Use memory-mapped reading for large files (>10MB)
            let attributes = try FileManager.default.attributesOfItem(atPath: filename)
            fileSize = attributes[.size] as? Int ?? 0

            let startTime = CFAbsoluteTimeGetCurrent()

            let loadedData: Data
            if fileSize > 10_000_000 { // >10MB - use memory mapping
                // Memory-mapped access for large files; dicomData owns the mapping lifetime.
                loadedData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                debugPerfLog("[PERF] Memory-mapped DICOM load: \(String(format: "%.2f", elapsed))ms | size: \(fileSize/1024/1024)MB")
            } else {
                // Regular loading for smaller files
                loadedData = try Data(contentsOf: fileURL)
            }
            try loadDicomDataUnsafe(loadedData, sourceDescription: filename)
        } catch {
            dicomFileName = ""
            fileReadSucceeded = false
            throw error
        }
    }

    private func loadDicomDataUnsafe(_ data: Data, sourceDescription: String) throws {
        do {
            let normalizedData = data.startIndex == 0 ? data : Data(data)
            fileSize = normalizedData.count
            dicomData = try DicomDeflatedDataSetCodec.inflatedPart10DataIfNeeded(normalizedData)
        } catch {
            dicomFileName = ""
            fileReadSucceeded = false
            if error is CancellationError || Task.isCancelled {
                discardCancelledLoadUnsafe()
                throw CancellationError()
            }
            throw error
        }

        // Reset state
        fileReadSucceeded = false
        signedImage = false
        pixelsNotLoaded = true
        pixels8 = nil
        pixels16 = nil
        pixels24 = nil
        location = 0
        windowCenter = 0
        windowWidth = 0
        dicomInfoDict.removeAll()
        cachedInfo.removeAll()
        tagMetadataCache.removeAll()
        // Initialize binary reader with little endian by default
        reader = DCMBinaryReader(data: dicomData, littleEndian: true)
        // Initialize tag parser
        if let reader = reader {
            tagParser = DCMTagParser(data: dicomData, dict: dict, binaryReader: reader)
        }
        // Parse the header (readFileInfo is called within synchronized block)
        let parsed: Bool
        do {
            parsed = try readFileInfoUnsafe()
        } catch is CancellationError {
            discardCancelledLoadUnsafe()
            throw CancellationError()
        }
        if parsed {
            // Pixel payload stays lazy until first getPixels* call.
            pixelsNotLoaded = true
            dicomFileName = sourceDescription
            fileReadSucceeded = true
        } else {
            dicomFileName = ""
            fileReadSucceeded = false
            pixelsNotLoaded = true
            try throwIfLoadFailed()
        }
    }

    // A cancelled header must not be observable as a partially loaded file (#2517).
    private func discardCancelledLoadUnsafe() {
        fileReadSucceeded = false
        dicomFileName = ""
        dicomData = Data()
        fileSize = 0
        location = 0
        reader = nil
        tagParser = nil
        dicomFound = false
        dicomInfoDict.removeAll()
        cachedInfo.removeAll()
        tagMetadataCache.removeAll()
        transferSyntaxUID = ""
        compressedImage = false
        bigEndianTransferSyntax = false
        littleEndian = true
        isExplicitVRTransferSyntax = true
        activeCharacterSet = .defaultCharacterSet
        width = 0
        height = 0
        offset = 0
        pixelDataVR = nil
        imageOrientation = nil
        imagePosition = nil
        bitDepth = 16
        nImages = 1
        samplesPerPixel = 1
        photometricInterpretation = ""
        pixelRepresentation = 0
        pixelWidth = 1
        pixelHeight = 1
        pixelDepth = 1
        rescaleSlope = 1
        rescaleIntercept = 0
        windowCenter = 0
        windowWidth = 0
        reds = nil
        greens = nil
        blues = nil
        redPaletteDescriptor = nil
        greenPaletteDescriptor = nil
        bluePaletteDescriptor = nil
        pixelsNotLoaded = true
        pixels8 = nil
        pixels16 = nil
        pixels24 = nil
        signedImage = false
    }

    /// Throws `DICOMError.invalidDICOMFormat` with a descriptive reason if the last load attempt failed.
    private func throwIfLoadFailed() throws {
        guard !fileReadSucceeded else { return }
        let reason: String
        if !dicomFound {
            reason = "Missing DICM signature or invalid DICOM header"
        } else if width <= 0 || height <= 0 {
            reason = "Invalid image dimensions (width: \(width), height: \(height))"
        } else {
            reason = "File could not be parsed as valid DICOM"
        }
        throw DICOMError.invalidDICOMFormat(reason: reason)
    }

}
