//
//  MockDicomDecoder.swift
//
//  Shared test fixture used by multiple SwiftPM test targets in this repository
//  (e.g. `DicomCoreTests` and `dicomtoolTests`) via the `DicomTestSupport` target.
//
//  IMPORTANT: Keep this as the single source-of-truth mock implementation.
//  Do not copy/duplicate it into per-target `Mocks/` folders, otherwise the
//  implementations drift and tests become inconsistent.
//
//  Mock implementation of DicomDecoderProtocol for unit testing.
//  Provides configurable properties and methods to simulate various
//  DICOM file scenarios without requiring actual DICOM files.
//
//  Thread Safety:
//
//  All properties and methods are thread-safe using a serial dispatch
//  queue for synchronization. Tests can safely configure and access
//  the mock from multiple threads.
//

import Foundation
import simd
import DicomCore

/// Mock implementation of DicomDecoderProtocol for testing.
/// All properties can be configured to simulate different DICOM scenarios.
/// Methods can be configured to return specific values or behaviors.
public final class MockDicomDecoder: DicomDecoderProtocol, @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.dicomcore.mockdecoder")

    // MARK: - Configurable Properties

    // MARK: - Image Properties

    private var _bitDepth: Int = 16
    public var bitDepth: Int {
        get { queue.sync { _bitDepth } }
        set { queue.sync { _bitDepth = newValue } }
    }

    private var _width: Int = 512
    public var width: Int {
        get { queue.sync { _width } }
        set { queue.sync { _width = newValue } }
    }

    private var _height: Int = 512
    public var height: Int {
        get { queue.sync { _height } }
        set { queue.sync { _height = newValue } }
    }

    private var _offset: Int = 0
    public var offset: Int {
        get { queue.sync { _offset } }
        set { queue.sync { _offset = newValue } }
    }

    private var _nImages: Int = 1
    public var nImages: Int {
        get { queue.sync { _nImages } }
        set { queue.sync { _nImages = newValue } }
    }

    private var _samplesPerPixel: Int = 1
    public var samplesPerPixel: Int {
        get { queue.sync { _samplesPerPixel } }
        set { queue.sync { _samplesPerPixel = newValue } }
    }

    private var _photometricInterpretation: String = "MONOCHROME2"
    public var photometricInterpretation: String {
        get { queue.sync { _photometricInterpretation } }
        set { queue.sync { _photometricInterpretation = newValue } }
    }

    // MARK: - Spatial Properties

    private var _pixelDepth: Double = 1.0
    public var pixelDepth: Double {
        get { queue.sync { _pixelDepth } }
        set { queue.sync { _pixelDepth = newValue } }
    }

    private var _pixelWidth: Double = 1.0
    public var pixelWidth: Double {
        get { queue.sync { _pixelWidth } }
        set { queue.sync { _pixelWidth = newValue } }
    }

    private var _pixelHeight: Double = 1.0
    public var pixelHeight: Double {
        get { queue.sync { _pixelHeight } }
        set { queue.sync { _pixelHeight = newValue } }
    }

    private var _imageOrientation: (row: SIMD3<Double>, column: SIMD3<Double>)?
    public var imageOrientation: (row: SIMD3<Double>, column: SIMD3<Double>)? {
        get { queue.sync { _imageOrientation } }
        set { queue.sync { _imageOrientation = newValue } }
    }

    private var _imagePosition: SIMD3<Double>?
    public var imagePosition: SIMD3<Double>? {
        get { queue.sync { _imagePosition } }
        set { queue.sync { _imagePosition = newValue } }
    }

    // MARK: - Display Properties

    private var _windowCenter: Double = 0.0
    public var windowCenter: Double {
        get { queue.sync { _windowCenter } }
        set { queue.sync { _windowCenter = newValue } }
    }

    private var _windowWidth: Double = 0.0
    public var windowWidth: Double {
        get { queue.sync { _windowWidth } }
        set { queue.sync { _windowWidth = newValue } }
    }

    // MARK: - Status Properties

    private var _dicomFound: Bool = true
    public var dicomFound: Bool {
        get { queue.sync { _dicomFound } }
        set { queue.sync { _dicomFound = newValue } }
    }

    private var _dicomFileReadSuccess: Bool = true
    @available(*, deprecated, message: "Use throwing initializers and error handling instead of dicomFileReadSuccess.")
    public var dicomFileReadSuccess: Bool {
        get { queue.sync { _dicomFileReadSuccess } }
        set { queue.sync { _dicomFileReadSuccess = newValue } }
    }

    /// Non-deprecated view of the legacy success flag for test fixtures that
    /// configure the mock without exercising the deprecated public API.
    public var mockFileReadSucceeded: Bool {
        get { queue.sync { _dicomFileReadSuccess } }
        set { queue.sync { _dicomFileReadSuccess = newValue } }
    }

    private var _compressedImage: Bool = false
    public var compressedImage: Bool {
        get { queue.sync { _compressedImage } }
        set { queue.sync { _compressedImage = newValue } }
    }

    private var _signedImage: Bool = false
    public var signedImage: Bool {
        get { queue.sync { _signedImage } }
        set { queue.sync { _signedImage = newValue } }
    }

    private var _pixelRepresentationTagValue: Int = 0
    public var pixelRepresentationTagValue: Int {
        get { queue.sync { _pixelRepresentationTagValue } }
        set { queue.sync { _pixelRepresentationTagValue = newValue } }
    }

    public var isSignedPixelRepresentation: Bool {
        return pixelRepresentationTagValue == 1
    }

    // MARK: - Configurable Method Returns

    private var _pixels8: [UInt8]?
    private var _pixels16: [UInt16]?
    private var _pixels24: [UInt8]?
    private var _storedPixelValues: [Int]?
    private var _downsampledPixels16: (pixels: [UInt16], width: Int, height: Int)?
    private var _downsampledPixels8: (pixels: [UInt8], width: Int, height: Int)?
    private var _tags: [String: String] = [:]
    private var _validationResult: (isValid: Bool, issues: [String]) = (true, [])

    // MARK: - Error Simulation

    public enum InitializationErrorMode: Sendable {
        case fileNotFound
        case invalidFormat
    }

    private static let initializationErrorState = DicomTestLockedValue((
        next: Optional<InitializationErrorMode>.none,
        byPath: [String: InitializationErrorMode]()
    ))

    /// Configure the next throwing initializer call to throw a specific error (one-shot).
    /// This is static because the throwing initializer creates the instance.
    public static func setNextInitializationErrorMode(_ mode: InitializationErrorMode?) {
        initializationErrorState.withValue { state in
            state.next = mode
        }
    }

    /// Configure the next throwing initializer call for a specific file path.
    public static func setInitializationErrorMode(_ mode: InitializationErrorMode?, forPath path: String) {
        let normalizedPath = normalizedInitializationErrorPath(path)
        initializationErrorState.withValue { state in
            if let mode {
                state.byPath[normalizedPath] = mode
            } else {
                state.byPath.removeValue(forKey: normalizedPath)
            }
        }
    }

    /// Clear all configured throwing initializer errors.
    public static func resetInitializationErrorModes() {
        initializationErrorState.withValue { state in
            state.next = nil
            state.byPath.removeAll()
        }
    }

    // MARK: - Initialization

    public init() {
        // Default initialization with typical DICOM values
    }

    // MARK: - Throwing Initializers

    /// Creates a new decoder instance and loads a DICOM file from a URL.
    ///
    /// - Parameter url: URL pointing to the DICOM file
    /// - Throws: `DICOMError.fileNotFound` if configured to simulate missing file
    /// - Throws: `DICOMError.invalidDICOMFormat` if configured to simulate invalid DICOM
    public convenience init(contentsOf url: URL) throws {
        self.init()
        if let mode = Self.consumeInitializationErrorMode(forPath: url.path) ??
            Self.consumeNextInitializationErrorMode() {
            try Self.throwInitializationError(mode, path: url.path)
        }
    }

    /// Creates a new decoder instance and loads a DICOM file from a file path.
    ///
    /// - Parameter path: File system path to the DICOM file
    /// - Throws: `DICOMError.fileNotFound` if configured to simulate missing file
    /// - Throws: `DICOMError.invalidDICOMFormat` if configured to simulate invalid DICOM
    public convenience init(contentsOfFile path: String) throws {
        self.init()
        if let mode = Self.consumeInitializationErrorMode(forPath: path) ??
            Self.consumeNextInitializationErrorMode() {
            try Self.throwInitializationError(mode, path: path)
        }
    }

    // MARK: - Static Factory Methods

    /// Loads a DICOM file from a URL and returns a decoder instance.
    ///
    /// - Parameter url: URL pointing to the DICOM file
    /// - Returns: A fully initialized decoder instance
    /// - Throws: `DICOMError.fileNotFound` if configured to simulate missing file
    /// - Throws: `DICOMError.invalidDICOMFormat` if configured to simulate invalid DICOM
    public static func load(from url: URL) throws -> Self {
        return try self.init(contentsOf: url)
    }

    /// Loads a DICOM file from a file path and returns a decoder instance.
    ///
    /// - Parameter path: File system path to the DICOM file
    /// - Returns: A fully initialized decoder instance
    /// - Throws: `DICOMError.fileNotFound` if configured to simulate missing file
    /// - Throws: `DICOMError.invalidDICOMFormat` if configured to simulate invalid DICOM
    public static func load(fromFile path: String) throws -> Self {
        return try self.init(contentsOfFile: path)
    }

    // MARK: - Configuration Methods

    /// Configures the mock with 8-bit pixel data
    public func setPixels8(_ pixels: [UInt8]) {
        queue.sync {
            _pixels8 = pixels
        }
    }

    /// Configures the mock with 16-bit pixel data
    public func setPixels16(_ pixels: [UInt16]) {
        queue.sync {
            _pixels16 = pixels
        }
    }

    /// Configures the mock with 24-bit RGB pixel data
    public func setPixels24(_ pixels: [UInt8]) {
        queue.sync {
            _pixels24 = pixels
        }
    }

    /// Configures stored sample values returned by `storedPixelValue`.
    public func setStoredPixelValues(_ values: [Int]) {
        queue.sync {
            _storedPixelValues = values
        }
    }

    /// Configures the mock with downsampled pixel data
    public func setDownsampledPixels16(_ pixels: [UInt16], width: Int, height: Int) {
        queue.sync {
            _downsampledPixels16 = (pixels, width, height)
        }
    }

    /// Configures the mock with downsampled 8-bit pixel data
    public func setDownsampledPixels8(_ pixels: [UInt8], width: Int, height: Int) {
        queue.sync {
            _downsampledPixels8 = (pixels, width, height)
        }
    }

    /// Sets a DICOM tag value
    public func setTag(_ tag: Int, value: String) {
        queue.sync {
            let hexTag = String(format: "%08X", tag)
            _tags[hexTag] = value
        }
    }

    /// Sets validation result
    public func setValidationResult(isValid: Bool, issues: [String] = []) {
        queue.sync {
            _validationResult = (isValid, issues)
        }
    }


    private static func consumeInitializationErrorMode(forPath path: String) -> InitializationErrorMode? {
        let normalizedPath = normalizedInitializationErrorPath(path)
        return initializationErrorState.withValue { state in
            state.byPath.removeValue(forKey: normalizedPath)
        }
    }

    private static func normalizedInitializationErrorPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func consumeNextInitializationErrorMode() -> InitializationErrorMode? {
        return initializationErrorState.withValue { state in
            let mode = state.next
            state.next = nil
            return mode
        }
    }

    private static func throwInitializationError(_ mode: InitializationErrorMode, path: String) throws {
        switch mode {
        case .fileNotFound:
            throw DICOMError.fileNotFound(path: path)
        case .invalidFormat:
            throw DICOMError.invalidDICOMFormat(reason: "Mock configured to simulate invalid format")
        }
    }

    /// Configure the next throwing initializer call to throw `DICOMError.fileNotFound`.
    public func setShouldThrowFileNotFound(_ value: Bool) {
        Self.setNextInitializationErrorMode(value ? .fileNotFound : nil)
    }

    /// Configure the next throwing initializer call to throw `DICOMError.invalidDICOMFormat`.
    public func setShouldThrowInvalidFormat(_ value: Bool) {
        Self.setNextInitializationErrorMode(value ? .invalidFormat : nil)
    }

    // MARK: - Validation Methods

    public func validateDICOMFile(_ filename: String) -> (isValid: Bool, issues: [String]) {
        return queue.sync { _validationResult }
    }

    public func isValid() -> Bool {
        return queue.sync { _dicomFound }
    }

    public func getValidationStatus() -> (isValid: Bool, width: Int, height: Int, hasPixels: Bool, isCompressed: Bool) {
        return queue.sync {
            let hasPixels = _pixels8 != nil || _pixels16 != nil || _pixels24 != nil || _storedPixelValues != nil
            return (_dicomFound, _width, _height, hasPixels, _compressedImage)
        }
    }

    // MARK: - File Loading Methods

    public func setDicomFilename(_ filename: String) {
        // Mock implementation - in a real mock, tests might configure behavior
        queue.sync {
            // Could trigger state changes if needed
        }
    }

    // MARK: - Pixel Data Access Methods

    public func getPixels8() -> [UInt8]? {
        return queue.sync { _pixels8 }
    }

    public func getPixels16() -> [UInt16]? {
        return queue.sync { _pixels16 }
    }

    public func getPixels24() -> [UInt8]? {
        return queue.sync { _pixels24 }
    }

    /// Returns the stored downsampled 16-bit pixel buffer and its dimensions.
    /// - Parameters:
    ///   - maxDimension: Ignored by this mock implementation; present for API compatibility.
    /// - Returns: A tuple `(pixels: [UInt16], width: Int, height: Int)` containing the downsampled pixels and their dimensions, or `nil` if no downsampled data is available.
    public func getDownsampledPixels16(maxDimension: Int) -> (pixels: [UInt16], width: Int, height: Int)? {
        return queue.sync { _downsampledPixels16 }
    }

    /// Returns the stored downsampled 8-bit pixel buffer and its dimensions.
    /// - Parameters:
    ///   - maxDimension: Ignored by this mock implementation; present for API compatibility.
    /// - Returns: A tuple `(pixels: [UInt8], width: Int, height: Int)` containing the downsampled pixels and their dimensions, or `nil` if no downsampled data is available.
    public func getDownsampledPixels8(maxDimension: Int) -> (pixels: [UInt8], width: Int, height: Int)? {
        return queue.sync { _downsampledPixels8 }
    }

    /// Returns a subarray of 8-bit pixel values for the specified pixel index range.
    /// - Parameters:
    ///   - range: The half-open range of pixel indices to retrieve; must be within valid image bounds.
    /// - Returns: An array of `UInt8` for the requested pixel indices, or `nil` if no 8-bit pixels are available, the range is empty, or the range is out of bounds.
    public func getPixels8(range: Range<Int>) -> [UInt8]? {
        return queue.sync {
            guard let pixels = _pixels8, !range.isEmpty else { return nil }
            guard range.lowerBound >= 0, range.upperBound <= pixels.count else { return nil }
            return Array(pixels[range])
        }
    }

    /// Returns a slice of 16-bit pixel samples for the specified pixel index range.
    /// 
    /// The provided `range` is interpreted as indices into the pixel array. If no 16-bit pixel data is available, the range is empty, or the range is out of bounds, the method returns `nil`.
    /// - Parameters:
    ///   - range: The range of pixel indices to retrieve.
    /// - Returns: An array of `UInt16` values corresponding to the requested pixels, or `nil` if pixel data is missing, the range is empty, or the range is out of bounds.
    public func getPixels16(range: Range<Int>) -> [UInt16]? {
        return queue.sync {
            guard let pixels = _pixels16, !range.isEmpty else { return nil }
            guard range.lowerBound >= 0, range.upperBound <= pixels.count else { return nil }
            return Array(pixels[range])
        }
    }

    /// Returns the RGB byte window corresponding to the given pixel index range.
    /// 
    /// The provided `range` is interpreted in pixels (each pixel = 3 bytes: R,G,B). If no 24-bit pixel data is present, the range is empty, or the range is out of bounds, the method returns `nil`.
    /// - Parameters:
    ///   - range: Pixel index range to extract (0-based, end-exclusive).
    /// - Returns: An array of bytes `[R, G, B, ...]` for the requested pixel range, or `nil` if pixel data is missing, the range is empty, or the range is out of bounds.
    public func getPixels24(range: Range<Int>) -> [UInt8]? {
        return queue.sync {
            guard let pixels = _pixels24, !range.isEmpty else { return nil }
            // For RGB, range is in pixels, but array is 3x larger (RGB bytes)
            let pixelCount = pixels.count / 3
            guard range.lowerBound >= 0, range.upperBound <= pixelCount else { return nil }
            let byteStart = range.lowerBound * 3
            let byteEnd = range.upperBound * 3
            return Array(pixels[byteStart..<byteEnd])
        }
    }

    public func storedPixelValue(at pixelIndex: Int, frame: Int, sample: Int) -> Int? {
        return queue.sync {
            guard pixelIndex >= 0, frame >= 0, sample >= 0 else { return nil }
            let pixelsPerFrame = max(0, _width * _height)
            guard pixelsPerFrame > 0, pixelIndex < pixelsPerFrame else { return nil }
            let index = frame * pixelsPerFrame * max(1, _samplesPerPixel) +
                pixelIndex * max(1, _samplesPerPixel) + sample
            if let values = _storedPixelValues {
                guard index < values.count else { return nil }
                return values[index]
            }
            if let pixels = _pixels8, index < pixels.count {
                return Int(pixels[index])
            }
            if let pixels = _pixels16, index < pixels.count {
                return Int(pixels[index])
            }
            return nil
        }
    }

    /// Fetches the stored string value for a DICOM tag.
    /// - Parameters:
    ///   - tag: The DICOM tag expressed as an `Int` (group << 16 | element); converted to an 8-character uppercase hexadecimal key.
    /// - Returns: The tag's string value if present, or an empty string if the tag is missing.

    public func info(for tag: Int) -> String {
        return queue.sync {
            let hexTag = String(format: "%08X", tag)
            return _tags[hexTag] ?? ""
        }
    }

    public func intValue(for tag: Int) -> Int? {
        let value = info(for: tag)
        return Int(value)
    }

    public func doubleValue(for tag: Int) -> Double? {
        let value = info(for: tag)
        return Double(value)
    }

    public func getAllTags() -> [String: String] {
        return queue.sync { _tags }
    }

    public func getPatientInfo() -> [String: String] {
        var info: [String: String] = [:]
        let name = self.info(for: DicomTag.patientName.rawValue)
        if !name.isEmpty {
            info["Name"] = name
        }
        let id = self.info(for: DicomTag.patientID.rawValue)
        if !id.isEmpty {
            info["ID"] = id
        }
        let sex = self.info(for: DicomTag.patientSex.rawValue)
        if !sex.isEmpty {
            info["Sex"] = sex
        }
        let age = self.info(for: DicomTag.patientAge.rawValue)
        if !age.isEmpty {
            info["Age"] = age
        }
        return info
    }

    public func getStudyInfo() -> [String: String] {
        var info: [String: String] = [:]
        let uid = self.info(for: DicomTag.studyInstanceUID.rawValue)
        if !uid.isEmpty {
            info["StudyInstanceUID"] = uid
        }
        let studyID = self.info(for: DicomTag.studyID.rawValue)
        if !studyID.isEmpty {
            info["StudyID"] = studyID
        }
        let date = self.info(for: DicomTag.studyDate.rawValue)
        if !date.isEmpty {
            info["StudyDate"] = date
        }
        let time = self.info(for: DicomTag.studyTime.rawValue)
        if !time.isEmpty {
            info["StudyTime"] = time
        }
        let description = self.info(for: DicomTag.studyDescription.rawValue)
        if !description.isEmpty {
            info["StudyDescription"] = description
        }
        return info
    }

    public func getSeriesInfo() -> [String: String] {
        var info: [String: String] = [:]
        let uid = self.info(for: DicomTag.seriesInstanceUID.rawValue)
        if !uid.isEmpty {
            info["SeriesInstanceUID"] = uid
        }
        let number = self.info(for: DicomTag.seriesNumber.rawValue)
        if !number.isEmpty {
            info["SeriesNumber"] = number
        }
        let description = self.info(for: DicomTag.seriesDescription.rawValue)
        if !description.isEmpty {
            info["SeriesDescription"] = description
        }
        let modality = self.info(for: DicomTag.modality.rawValue)
        if !modality.isEmpty {
            info["Modality"] = modality
        }
        return info
    }

    // MARK: - Convenience Properties

    public var isGrayscale: Bool {
        return samplesPerPixel == 1
    }

    public var isColorImage: Bool {
        return samplesPerPixel == 3
    }

    public var isMultiFrame: Bool {
        return nImages > 1
    }

    public var imageDimensions: (width: Int, height: Int) {
        return (width, height)
    }

    public var pixelSpacing: (width: Double, height: Double, depth: Double) {
        return (pixelWidth, pixelHeight, pixelDepth)
    }

    public var windowSettings: (center: Double, width: Double) {
        return (windowCenter, windowWidth)
    }

    public var rescaleParameters: (intercept: Double, slope: Double) {
        return queue.sync {
            let interceptTag = String(format: "%08X", DicomTag.rescaleIntercept.rawValue)
            let slopeTag = String(format: "%08X", DicomTag.rescaleSlope.rawValue)
            let intercept = Double(_tags[interceptTag] ?? "0") ?? 0.0
            let slope = Double(_tags[slopeTag] ?? "1") ?? 1.0
            return (intercept, slope)
        }
    }

    // MARK: - Type-Safe Value Properties (V2 APIs)

    /// Returns pixel spacing as a type-safe struct
    ///
    /// This property provides physical pixel spacing in all three dimensions (x, y, z)
    /// as millimeters per pixel. Use the `isValid` property to check if spacing values
    /// are physically meaningful (all positive).
    ///
    /// ## Example
    /// ```swift
    /// let spacing = mockDecoder.pixelSpacing
    /// if spacing.isValid {
    ///     print("Pixel spacing: \(spacing.x) × \(spacing.y) × \(spacing.z) mm")
    /// }
    /// ```
    public var pixelSpacingV2: PixelSpacing {
        let tuple = pixelSpacing
        return PixelSpacing(x: tuple.width, y: tuple.height, z: tuple.depth)
    }

    /// Returns window settings as a type-safe struct
    ///
    /// This property provides the default window center and width for display.
    /// Window settings control the mapping of pixel values to display brightness.
    /// Use the `isValid` property to check if settings have a positive width.
    ///
    /// ## Example
    /// ```swift
    /// let settings = mockDecoder.windowSettings
    /// if settings.isValid {
    ///     // Apply windowing with settings.center and settings.width
    /// }
    /// ```
    public var windowSettingsV2: WindowSettings {
        let tuple = windowSettings
        return WindowSettings(center: tuple.center, width: tuple.width)
    }

    /// Returns rescale parameters as a type-safe struct
    ///
    /// This property provides the rescale slope and intercept for converting stored
    /// pixel values to modality units (e.g., Hounsfield Units for CT).
    /// Use the `isIdentity` property to check if rescaling is needed.
    ///
    /// ## Example
    /// ```swift
    /// let rescale = mockDecoder.rescaleParameters
    /// if !rescale.isIdentity {
    ///     let hounsfieldValue = rescale.apply(to: pixelValue)
    /// }
    /// ```
    public var rescaleParametersV2: RescaleParameters {
        let tuple = rescaleParameters
        return RescaleParameters(intercept: tuple.intercept, slope: tuple.slope)
    }

    public var waveform: DicomWaveform? {
        nil
    }

    public var video: DicomVideo? {
        nil
    }

    // MARK: - Utility Methods

    public func applyRescale(to pixelValue: Double) -> Double {
        let params = rescaleParameters
        return pixelValue * params.slope + params.intercept
    }

    public func calculateOptimalWindow() -> (center: Double, width: Double)? {
        return queue.sync {
            if _pixels16 != nil || _pixels8 != nil {
                return (_windowCenter, _windowWidth)
            }
            return nil
        }
    }

    /// Calculates optimal window/level based on pixel data statistics (V2 API)
    ///
    /// Analyzes pixel data to determine optimal window center and width for display.
    /// This method wraps the legacy tuple-based method and returns type-safe WindowSettings
    /// that can be used with windowing processors.
    ///
    /// - Returns: WindowSettings with optimal center and width, or nil if no pixel data
    ///
    /// ## Example
    /// ```swift
    /// if let settings = mockDecoder.calculateOptimalWindowV2() {
    ///     if settings.isValid {
    ///         // Apply optimal windowing
    ///         let displayPixels = DCMWindowingProcessor.applyWindowLevel(
    ///             pixels16: pixels,
    ///             center: settings.center,
    ///             width: settings.width
    ///         )
    ///     }
    /// }
    /// ```
    public func calculateOptimalWindowV2() -> WindowSettings? {
        guard let tuple = calculateOptimalWindow() else {
            return nil
        }
        return WindowSettings(center: tuple.center, width: tuple.width)
    }

    public func getQualityMetrics() -> [String: Double]? {
        return queue.sync {
            if _pixels16 != nil || _pixels8 != nil {
                return [
                    "mean": 1000.0,
                    "stdDev": 200.0,
                    "min": 0.0,
                    "max": 4095.0,
                    "snr": 5.0
                ]
            }
            return nil
        }
    }
}
