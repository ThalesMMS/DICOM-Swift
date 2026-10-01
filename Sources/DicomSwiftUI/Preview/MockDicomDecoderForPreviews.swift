//
//  MockDicomDecoderForPreviews.swift
//
//  Preview-only mock implementation of DicomDecoderProtocol.
//  Provides pre-configured sample data for instant Xcode Preview rendering
//  without requiring actual DICOM files or complex configuration.
//  This is supported public preview API only, not a clinical or runtime decoder.
//
//  Thread Safety:
//
//  This mock is optimized for Xcode Previews which run in a single-threaded
//  environment. Thread-safety is provided through immutable data storage.
//
//  Usage:
//
//  Use this mock in SwiftUI previews to render DICOM views without files:
//
//  ```swift
//  #Preview {
//      DicomImageView(decoder: MockDicomDecoderForPreviews.sampleCT())
//  }
//  ```
//

import Foundation
import simd
import DicomCore

/// Preview-only mock DICOM decoder with pre-configured sample data.
///
/// This mock provides instant initialization with reasonable defaults for
/// Xcode Previews. Unlike the test mock (MockDicomDecoder), this version
/// prioritizes simplicity and performance for UI preview rendering.
///
/// Do not use this type for clinical workflows, runtime decoding, validation,
/// or conformance decisions. Production code should use `DCMDecoder` or a
/// caller-owned `DicomDecoderProtocol` implementation backed by real DICOM
/// data.
///
/// ## Sample Data Factories
///
/// The mock includes factory methods for common medical imaging modalities:
///
/// ```swift
/// // CT scan sample (512x512, 16-bit grayscale)
/// let ctDecoder = MockDicomDecoderForPreviews.sampleCT()
///
/// // MRI sample (256x256, 16-bit grayscale)
/// let mriDecoder = MockDicomDecoderForPreviews.sampleMRI()
///
/// // X-ray sample (1024x1024, 16-bit grayscale)
/// let xrayDecoder = MockDicomDecoderForPreviews.sampleXRay()
///
/// // Ultrasound sample (640x480, 8-bit grayscale)
/// let usDecoder = MockDicomDecoderForPreviews.sampleUltrasound()
/// ```
///
/// ## Custom Configuration
///
/// For custom scenarios, create an instance and override specific properties:
///
/// ```swift
/// var decoder = MockDicomDecoderForPreviews.sampleCT()
/// decoder.customPatientName = "Doe, Jane"
/// decoder.customWindowSettings = WindowSettings(center: 40, width: 400)
/// ```
public final class MockDicomDecoderForPreviews: DicomDecoderProtocol, @unchecked Sendable {

    // MARK: - Public Customization Properties

    /// Override patient name for preview customization
    public var customPatientName: String? = nil

    /// Override study description for preview customization
    public var customStudyDescription: String? = nil

    /// Override window settings for preview customization
    public var customWindowSettings: WindowSettings? = nil

    // MARK: - Image Properties

    public let bitDepth: Int
    public let width: Int
    public let height: Int
    public let offset: Int = 0
    public let nImages: Int = 1
    public let samplesPerPixel: Int
    public let photometricInterpretation: String

    // MARK: - Spatial Properties

    public let pixelDepth: Double
    public let pixelWidth: Double
    public let pixelHeight: Double
    public let imageOrientation: (row: SIMD3<Double>, column: SIMD3<Double>)?
    public let imagePosition: SIMD3<Double>?

    // MARK: - Display Properties

    public let windowCenter: Double
    public let windowWidth: Double

    // MARK: - Status Properties

    public let dicomFound: Bool = true
    public let compressedImage: Bool = false
    public let signedImage: Bool = false
    public let pixelRepresentationTagValue: Int = 0

    public var isSignedPixelRepresentation: Bool {
        return pixelRepresentationTagValue == 1
    }

    // MARK: - Private Storage

    private let pixels8: [UInt8]?
    private let pixels16: [UInt16]?
    private let pixels24: [UInt8]?
    private let metadata: [String: String]

    // MARK: - Initialization

    /// Creates a preview mock with specified image properties.
    ///
    /// - Parameters:
    ///   - width: Image width in pixels
    ///   - height: Image height in pixels
    ///   - bitDepth: Bit depth (8 or 16)
    ///   - samplesPerPixel: 1 for grayscale, 3 for RGB
    ///   - windowCenter: Default window center
    ///   - windowWidth: Default window width
    ///   - pixelWidth: Pixel spacing in mm (horizontal)
    ///   - pixelHeight: Pixel spacing in mm (vertical)
    ///   - pixelDepth: Slice thickness in mm
    ///   - metadata: Additional DICOM tags
    public init(
        width: Int,
        height: Int,
        bitDepth: Int = 16,
        samplesPerPixel: Int = 1,
        windowCenter: Double = 40.0,
        windowWidth: Double = 400.0,
        pixelWidth: Double = 1.0,
        pixelHeight: Double = 1.0,
        pixelDepth: Double = 1.0,
        metadata: [String: String] = [:]
    ) {
        self.width = width
        self.height = height
        self.bitDepth = bitDepth
        self.samplesPerPixel = samplesPerPixel
        self.windowCenter = windowCenter
        self.windowWidth = windowWidth
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pixelDepth = pixelDepth
        self.metadata = metadata

        // Set photometric interpretation based on samples per pixel
        if samplesPerPixel == 1 {
            self.photometricInterpretation = "MONOCHROME2"
        } else {
            self.photometricInterpretation = "RGB"
        }

        // Generate sample pixel data
        if samplesPerPixel == 3 {
            // RGB image
            self.pixels24 = Self.generateRGBGradient(width: width, height: height)
            self.pixels16 = nil
            self.pixels8 = nil
        } else if bitDepth == 8 {
            // 8-bit grayscale
            self.pixels8 = Self.generateGrayscaleGradient8(width: width, height: height)
            self.pixels16 = nil
            self.pixels24 = nil
        } else {
            // 16-bit grayscale
            self.pixels16 = Self.generateGrayscaleGradient16(width: width, height: height, center: windowCenter, width: windowWidth)
            self.pixels8 = nil
            self.pixels24 = nil
        }

        // Standard orientation (identity)
        self.imageOrientation = (
            row: SIMD3<Double>(1.0, 0.0, 0.0),
            column: SIMD3<Double>(0.0, 1.0, 0.0)
        )
        self.imagePosition = SIMD3<Double>(0.0, 0.0, 0.0)
    }

    // MARK: - Throwing Initializers

    /// Creates a mock decoder from a URL (for protocol conformance).
    /// Always succeeds with default sample data.
    public convenience init(contentsOf url: URL) throws {
        self.init(width: 512, height: 512)
    }

    /// Creates a mock decoder from a file path (for protocol conformance).
    /// Always succeeds with default sample data.
    public convenience init(contentsOfFile path: String) throws {
        self.init(width: 512, height: 512)
    }

    // MARK: - Static Factory Methods

    /// Creates a sample CT scan decoder (512x512, 16-bit, lung window).
    public static func sampleCT() -> MockDicomDecoderForPreviews {
        return MockDicomDecoderForPreviews(
            width: 512,
            height: 512,
            bitDepth: 16,
            samplesPerPixel: 1,
            windowCenter: -600.0,  // Lung window
            windowWidth: 1500.0,
            pixelWidth: 0.7,
            pixelHeight: 0.7,
            pixelDepth: 5.0,
            metadata: [
                "00100010": "Sample^Patient",  // Patient Name
                "00080060": "CT",              // Modality
                "00081030": "CT Chest",        // Study Description
                "0008103E": "Lung Window",     // Series Description
                "00200011": "1"                // Series Number
            ]
        )
    }

    /// Creates a sample MRI decoder (256x256, 16-bit, brain window).
    public static func sampleMRI() -> MockDicomDecoderForPreviews {
        return MockDicomDecoderForPreviews(
            width: 256,
            height: 256,
            bitDepth: 16,
            samplesPerPixel: 1,
            windowCenter: 600.0,  // Brain window
            windowWidth: 1200.0,
            pixelWidth: 0.9,
            pixelHeight: 0.9,
            pixelDepth: 3.0,
            metadata: [
                "00100010": "Sample^Patient",  // Patient Name
                "00080060": "MR",              // Modality
                "00081030": "MRI Brain",       // Study Description
                "0008103E": "T1 Weighted",     // Series Description
                "00200011": "2"                // Series Number
            ]
        )
    }

    /// Creates a sample X-ray decoder (1024x1024, 16-bit).
    public static func sampleXRay() -> MockDicomDecoderForPreviews {
        return MockDicomDecoderForPreviews(
            width: 1024,
            height: 1024,
            bitDepth: 16,
            samplesPerPixel: 1,
            windowCenter: 2000.0,
            windowWidth: 4000.0,
            pixelWidth: 0.2,
            pixelHeight: 0.2,
            pixelDepth: 1.0,
            metadata: [
                "00100010": "Sample^Patient",  // Patient Name
                "00080060": "CR",              // Modality (Computed Radiography)
                "00081030": "Chest X-Ray",     // Study Description
                "0008103E": "PA View",         // Series Description
                "00200011": "1"                // Series Number
            ]
        )
    }

    /// Creates a sample ultrasound decoder (640x480, 8-bit).
    public static func sampleUltrasound() -> MockDicomDecoderForPreviews {
        return MockDicomDecoderForPreviews(
            width: 640,
            height: 480,
            bitDepth: 8,
            samplesPerPixel: 1,
            windowCenter: 128.0,
            windowWidth: 256.0,
            pixelWidth: 0.1,
            pixelHeight: 0.1,
            pixelDepth: 1.0,
            metadata: [
                "00100010": "Sample^Patient",  // Patient Name
                "00080060": "US",              // Modality
                "00081030": "Ultrasound Exam", // Study Description
                "0008103E": "Abdomen",         // Series Description
                "00200011": "1"                // Series Number
            ]
        )
    }

    /// Loads a decoder from a URL (factory method for protocol conformance).
    public static func load(from url: URL) throws -> Self {
        return try self.init(contentsOf: url)
    }

    /// Loads a decoder from a file path (factory method for protocol conformance).
    public static func load(fromFile path: String) throws -> Self {
        return try self.init(contentsOfFile: path)
    }

    // MARK: - Validation Methods

    public func validateDICOMFile(_ filename: String) -> (isValid: Bool, issues: [String]) {
        return (true, [])
    }

    public func isValid() -> Bool {
        return true
    }

    public func getValidationStatus() -> (isValid: Bool, width: Int, height: Int, hasPixels: Bool, isCompressed: Bool) {
        let hasPixels = pixels8 != nil || pixels16 != nil || pixels24 != nil
        return (true, width, height, hasPixels, false)
    }

    // MARK: - Pixel Data Access Methods

    public func getPixels8() -> [UInt8]? {
        return pixels8
    }

    public func getPixels16() -> [UInt16]? {
        return pixels16
    }

    public func getPixels24() -> [UInt8]? {
        return pixels24
    }

    public func getDownsampledPixels16(maxDimension: Int) -> (pixels: [UInt16], width: Int, height: Int)? {
        guard let pixels = pixels16 else { return nil }

        // Simple downsampling for previews
        let scale = max(width, height) / maxDimension
        if scale <= 1 {
            return (pixels, width, height)
        }

        let newWidth = width / scale
        let newHeight = height / scale
        var downsampled: [UInt16] = []
        downsampled.reserveCapacity(newWidth * newHeight)

        for y in 0..<newHeight {
            for x in 0..<newWidth {
                let srcX = x * scale
                let srcY = y * scale
                let index = srcY * width + srcX
                downsampled.append(pixels[index])
            }
        }

        return (downsampled, newWidth, newHeight)
    }

    public func getDownsampledPixels8(maxDimension: Int) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let pixels = pixels8 else { return nil }

        let scale = max(width, height) / maxDimension
        if scale <= 1 {
            return (pixels, width, height)
        }

        let newWidth = width / scale
        let newHeight = height / scale
        var downsampled: [UInt8] = []
        downsampled.reserveCapacity(newWidth * newHeight)

        for y in 0..<newHeight {
            for x in 0..<newWidth {
                let srcX = x * scale
                let srcY = y * scale
                let index = srcY * width + srcX
                downsampled.append(pixels[index])
            }
        }

        return (downsampled, newWidth, newHeight)
    }

    public func getPixels8(range: Range<Int>) -> [UInt8]? {
        guard let pixels = pixels8, !range.isEmpty else { return nil }
        guard range.lowerBound >= 0, range.upperBound <= pixels.count else { return nil }
        return Array(pixels[range])
    }

    public func getPixels16(range: Range<Int>) -> [UInt16]? {
        guard let pixels = pixels16, !range.isEmpty else { return nil }
        guard range.lowerBound >= 0, range.upperBound <= pixels.count else { return nil }
        return Array(pixels[range])
    }

    public func getPixels24(range: Range<Int>) -> [UInt8]? {
        guard let pixels = pixels24, !range.isEmpty else { return nil }
        let pixelCount = pixels.count / 3
        guard range.lowerBound >= 0, range.upperBound <= pixelCount else { return nil }
        let byteStart = range.lowerBound * 3
        let byteEnd = range.upperBound * 3
        return Array(pixels[byteStart..<byteEnd])
    }

    // MARK: - Metadata Access Methods

    public func info(for tag: Int) -> String {
        let hexTag = String(format: "%08X", tag)
        if let custom = customPatientName, hexTag == "00100010" {
            return custom
        }
        if let custom = customStudyDescription, hexTag == "00081030" {
            return custom
        }
        return metadata[hexTag] ?? ""
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
        return metadata
    }

    public func getPatientInfo() -> [String: String] {
        var info: [String: String] = [:]
        if let name = metadata["00100010"] ?? customPatientName {
            info["Name"] = name
        }
        return info
    }

    public func getStudyInfo() -> [String: String] {
        var info: [String: String] = [:]
        if let description = metadata["00081030"] ?? customStudyDescription {
            info["StudyDescription"] = description
        }
        return info
    }

    public func getSeriesInfo() -> [String: String] {
        var info: [String: String] = [:]
        if let modality = metadata["00080060"] {
            info["Modality"] = modality
        }
        if let description = metadata["0008103E"] {
            info["SeriesDescription"] = description
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

    // MARK: - Type-Safe Value Properties (V2 APIs)

    public var pixelSpacingV2: PixelSpacing {
        return PixelSpacing(x: pixelWidth, y: pixelHeight, z: pixelDepth)
    }

    public var windowSettingsV2: WindowSettings {
        if let custom = customWindowSettings {
            return custom
        }
        return WindowSettings(center: windowCenter, width: windowWidth)
    }

    public var rescaleParametersV2: RescaleParameters {
        // Most preview scenarios use identity rescaling
        return RescaleParameters(intercept: 0.0, slope: 1.0)
    }

    public var waveform: DicomWaveform? {
        nil
    }

    public var video: DicomVideo? {
        nil
    }

    // MARK: - Utility Methods

    public func applyRescale(to pixelValue: Double) -> Double {
        return pixelValue  // Identity transform for previews
    }

    public func calculateOptimalWindowV2() -> WindowSettings? {
        return windowSettingsV2
    }

    public func getQualityMetrics() -> [String: Double]? {
        if pixels16 != nil || pixels8 != nil {
            return [
                "mean": Double(windowCenter),
                "stdDev": Double(windowWidth) / 4.0,
                "min": 0.0,
                "max": bitDepth == 8 ? 255.0 : 4095.0,
                "snr": 10.0
            ]
        }
        return nil
    }

    // MARK: - Pixel Generation Helpers

    /// Generates a 16-bit grayscale gradient for preview visualization.
    private static func generateGrayscaleGradient16(width: Int, height: Int, center: Double, width windowWidth: Double) -> [UInt16] {
        var pixels: [UInt16] = []
        pixels.reserveCapacity(width * height)

        let minValue = UInt16(max(0, center - windowWidth / 2.0))
        let maxValue = UInt16(min(4095, center + windowWidth / 2.0))

        for y in 0..<height {
            for x in 0..<width {
                // Create a radial gradient centered in the image
                let dx = Double(x) / Double(width) - 0.5
                let dy = Double(y) / Double(height) - 0.5
                let distance = sqrt(dx * dx + dy * dy)
                let normalized = 1.0 - min(1.0, distance * 2.0)

                let value = UInt16(Double(minValue) + normalized * Double(maxValue - minValue))
                pixels.append(value)
            }
        }

        return pixels
    }

    /// Generates an 8-bit grayscale gradient for preview visualization.
    private static func generateGrayscaleGradient8(width: Int, height: Int) -> [UInt8] {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height)

        for y in 0..<height {
            for x in 0..<width {
                // Create a diagonal gradient
                let normalized = (Double(x) + Double(y)) / Double(width + height)
                let value = UInt8(normalized * 255.0)
                pixels.append(value)
            }
        }

        return pixels
    }

    /// Generates a 24-bit RGB gradient for preview visualization.
    private static func generateRGBGradient(width: Int, height: Int) -> [UInt8] {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 3)

        for y in 0..<height {
            for x in 0..<width {
                let normalizedX = Double(x) / Double(width)
                let normalizedY = Double(y) / Double(height)

                // RGB gradient: Red varies horizontally, Green vertically, Blue diagonally
                let r = UInt8(normalizedX * 255.0)
                let g = UInt8(normalizedY * 255.0)
                let b = UInt8((normalizedX + normalizedY) / 2.0 * 255.0)

                pixels.append(r)
                pixels.append(g)
                pixels.append(b)
            }
        }

        return pixels
    }
}

// MARK: - DicomImageRendererDecoderProtocol Conformance

/// Conformance to DicomImageRendererDecoderProtocol for preview rendering support.
///
/// This conformance enables MockDicomDecoderForPreviews to be used with
/// DicomImageViewModel and DicomImageRenderer without requiring actual DICOM files.
extension MockDicomDecoderForPreviews: DicomImageRendererDecoderProtocol {
    // All required properties and methods are already implemented in the main class:
    // - width: Int
    // - height: Int
    // - windowSettingsV2: WindowSettings
    // - func getPixels16() -> [UInt16]?
}
