import CoreGraphics
import DicomJPEG
import Foundation
import ImageIO

public enum DicomImageExportFormat: String, CaseIterable, Codable, Sendable {
    case png
    case jpeg
    case tiff

    public var fileExtension: String {
        switch self {
        case .png:
            return "png"
        case .jpeg:
            return "jpg"
        case .tiff:
            return "tiff"
        }
    }

    var contentTypeIdentifier: CFString {
        switch self {
        case .png:
            return "public.png" as CFString
        case .jpeg:
            return "public.jpeg" as CFString
        case .tiff:
            return "public.tiff" as CFString
        }
    }

    public var description: String {
        switch self {
        case .png:
            return "PNG (Portable Network Graphics)"
        case .jpeg:
            return "JPEG (Joint Photographic Experts Group)"
        case .tiff:
            return "TIFF (Tagged Image File Format)"
        }
    }
}

public enum DicomImageExportPixelMode: Sendable {
    case display8(selection: DicomDisplaySelection?)
    case native16Bit
}

public enum DicomImageExportMetadataPolicy: Equatable, Sendable {
    case none
    case nonPHISidecar
}

public struct DicomImageExportOptions: Sendable {
    public let format: DicomImageExportFormat
    public let quality: Double
    public let overwrite: Bool
    public let pixelMode: DicomImageExportPixelMode
    public let metadataPolicy: DicomImageExportMetadataPolicy
    public let outputSize: DicomImageSize?
    public let annotations: [DicomAnnotationOverlay]
    /// JPEG output as a progressive (SOF2, spectral selection) codestream from the own encoder instead of the
    /// sequential baseline ImageIO writes; 4:4:4 chroma, quality from `quality`.
    public let progressiveJPEG: Bool

    public init(
        format: DicomImageExportFormat = .png,
        quality: Double = 1.0,
        overwrite: Bool = false,
        pixelMode: DicomImageExportPixelMode = .display8(selection: nil),
        metadataPolicy: DicomImageExportMetadataPolicy = .none,
        outputSize: DicomImageSize? = nil,
        annotations: [DicomAnnotationOverlay] = [],
        progressiveJPEG: Bool = false
    ) {
        self.format = format
        self.quality = min(max(quality, 0.0), 1.0)
        self.overwrite = overwrite
        self.pixelMode = pixelMode
        self.metadataPolicy = metadataPolicy
        self.outputSize = outputSize
        self.annotations = annotations
        self.progressiveJPEG = progressiveJPEG
    }
}

public struct DicomImageExportResult: Equatable, Sendable {
    public let imageURL: URL
    public let frameIndex: Int
    public let metadataURL: URL?

    public init(imageURL: URL, frameIndex: Int, metadataURL: URL?) {
        self.imageURL = imageURL
        self.frameIndex = frameIndex
        self.metadataURL = metadataURL
    }
}

public enum DicomImageExportError: Error, Equatable, LocalizedError, Sendable {
    case invalidFrame(index: Int, frameCount: Int)
    case invalidPixelData(String)
    case unsupportedPixelMode(String)
    case outputFileExists(path: String)
    case fileNotWritable(path: String, reason: String)
    case imageCreationFailed(String)
    case metadataEncodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFrame(let index, let frameCount):
            return "Invalid frame \(index). Frame count is \(frameCount)."
        case .invalidPixelData(let reason):
            return "Invalid pixel data: \(reason)"
        case .unsupportedPixelMode(let reason):
            return "Unsupported image export mode: \(reason)"
        case .outputFileExists(let path):
            return "Output file already exists: \(path)"
        case .fileNotWritable(let path, let reason):
            return "File is not writable at \(path): \(reason)"
        case .imageCreationFailed(let reason):
            return "Could not create image for export: \(reason)"
        case .metadataEncodingFailed(let reason):
            return "Could not encode export metadata: \(reason)"
        }
    }
}

public struct DicomImageExporter {
    public init() {}

    public func export(
        decoder: DCMDecoder,
        frame frameIndex: Int = 0,
        to url: URL,
        options: DicomImageExportOptions = DicomImageExportOptions()
    ) throws -> DicomImageExportResult {
        try exportFrame(decoder: decoder, frameIndex: frameIndex, to: url, options: options,
                        sourceFrameIndex: frameIndex, sourceFrameCount: nil)
    }

    /// Export a selected native frame through the same session used by pixel readers.
    /// Sidecars retain the original frame identity rather than the compatibility buffer's frame zero.
    public func export(session: DicomSourceFrameSession, frame frameIndex: Int = 0, to url: URL,
                       options: DicomImageExportOptions = DicomImageExportOptions()) async throws -> DicomImageExportResult {
        let bytes = try await session.part10Data(at: frameIndex)
        try Task.checkCancellation()
        let decoder = try DCMDecoder(data: bytes)
        return try exportFrame(decoder: decoder, frameIndex: 0, to: url, options: options,
                               sourceFrameIndex: frameIndex, sourceFrameCount: session.index.frameCount)
    }

    private func exportFrame(decoder: DCMDecoder, frameIndex: Int, to url: URL, options: DicomImageExportOptions,
                             sourceFrameIndex: Int, sourceFrameCount: Int?) throws -> DicomImageExportResult {
        guard let descriptor = decoder.pixelDataDescriptor else {
            throw DicomImageExportError.invalidPixelData("Native uncompressed Pixel Data is not frame-addressable.")
        }
        guard frameIndex >= 0, frameIndex < descriptor.numberOfFrames else {
            throw DicomImageExportError.invalidFrame(index: frameIndex, frameCount: descriptor.numberOfFrames)
        }

        try validateWritable(url, overwrite: options.overwrite)
        if options.metadataPolicy == .nonPHISidecar {
            try validateWritable(url.appendingPathExtension("json"), overwrite: options.overwrite)
        }
        let image = try makeImage(decoder: decoder, descriptor: descriptor, frameIndex: frameIndex, options: options)
        try writeImage(image, to: url, options: options)

        let metadataURL = try writeMetadataIfNeeded(
            decoder: decoder,
            descriptor: descriptor,
            imageURL: url,
            options: options,
            sourceFrameIndex: sourceFrameIndex,
            sourceFrameCount: sourceFrameCount
        )

        return DicomImageExportResult(imageURL: url, frameIndex: sourceFrameIndex, metadataURL: metadataURL)
    }

    public func exportAllFrames(
        decoder: DCMDecoder,
        to directoryURL: URL,
        baseName: String,
        options: DicomImageExportOptions = DicomImageExportOptions()
    ) throws -> [DicomImageExportResult] {
        guard let descriptor = decoder.pixelDataDescriptor else {
            throw DicomImageExportError.invalidPixelData("Native uncompressed Pixel Data is not frame-addressable.")
        }

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var results: [DicomImageExportResult] = []
        results.reserveCapacity(descriptor.numberOfFrames)

        for frameIndex in 0..<descriptor.numberOfFrames {
            let fileName = Self.fileName(
                baseName: baseName,
                frameIndex: frameIndex,
                frameCount: descriptor.numberOfFrames,
                format: options.format
            )
            let outputURL = directoryURL.appendingPathComponent(fileName)
            let result = try export(decoder: decoder, frame: frameIndex, to: outputURL, options: options)
            results.append(result)
        }

        return results
    }

    public static func fileName(
        baseName: String,
        frameIndex: Int,
        frameCount: Int,
        format: DicomImageExportFormat
    ) -> String {
        let digits = max(4, String(max(frameCount, 1)).count)
        let frameNumber = String(format: "%0\(digits)d", frameIndex + 1)
        return "\(baseName)_frame\(frameNumber).\(format.fileExtension)"
    }

    private func makeImage(
        decoder: DCMDecoder,
        descriptor: DicomPixelDataDescriptor,
        frameIndex: Int,
        options: DicomImageExportOptions
    ) throws -> CGImage {
        switch options.pixelMode {
        case .display8(let selection):
            return try makeDisplay8Image(
                decoder: decoder,
                frameIndex: frameIndex,
                selection: selection,
                outputSize: options.outputSize,
                annotations: options.annotations
            )
        case .native16Bit:
            guard options.format == .tiff else {
                throw DicomImageExportError.unsupportedPixelMode("Native 16-bit export is only supported for TIFF.")
            }
            guard options.outputSize == nil, options.annotations.isEmpty else {
                throw DicomImageExportError.unsupportedPixelMode(
                    "Resize and annotation overlays require display 8-bit export."
                )
            }
            return try makeNative16BitImage(decoder: decoder, descriptor: descriptor, frameIndex: frameIndex)
        }
    }

    private func makeDisplay8Image(
        decoder: DCMDecoder,
        frameIndex: Int,
        selection: DicomDisplaySelection?,
        outputSize: DicomImageSize?,
        annotations: [DicomAnnotationOverlay]
    ) throws -> CGImage {
        let bitmap = try DicomImagePreprocessor().render(
            decoder: decoder,
            options: DicomImagePreprocessOptions(
                frameIndex: frameIndex,
                displaySelection: selection,
                outputSize: outputSize,
                annotations: annotations
            )
        )
        return try makeRGBImage(data: bitmap.rgbData, width: bitmap.width, height: bitmap.height)
    }

    private func makeNative16BitImage(
        decoder: DCMDecoder,
        descriptor: DicomPixelDataDescriptor,
        frameIndex: Int
    ) throws -> CGImage {
        guard descriptor.samplesPerPixel == 1 else {
            throw DicomImageExportError.unsupportedPixelMode("Native 16-bit TIFF export requires one sample per pixel.")
        }
        guard descriptor.bitsAllocated <= 16, descriptor.bytesPerSample <= 2 else {
            throw DicomImageExportError.unsupportedPixelMode("Native TIFF export supports up to 16 bits per sample.")
        }
        guard !descriptor.isSigned else {
            throw DicomImageExportError.unsupportedPixelMode("Native 16-bit TIFF export currently supports unsigned stored pixels.")
        }

        let pixelsPerFrame = descriptor.rows * descriptor.columns
        var data = Data()
        data.reserveCapacity(pixelsPerFrame * 2)

        for pixelIndex in 0..<pixelsPerFrame {
            guard let storedValue = decoder.storedPixelValue(at: pixelIndex, frame: frameIndex, sample: 0),
                  storedValue >= 0,
                  storedValue <= Int(UInt16.max) else {
                throw DicomImageExportError.invalidPixelData("Cannot encode sample \(pixelIndex) as unsigned 16-bit.")
            }
            var value = UInt16(storedValue).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }

        return try makeGrayscaleImage(data: data, width: descriptor.columns, height: descriptor.rows, bitsPerComponent: 16)
    }

    private func makeGrayscaleImage(
        data: Data,
        width: Int,
        height: Int,
        bitsPerComponent: Int
    ) throws -> CGImage {
        guard width > 0, height > 0 else {
            throw DicomImageExportError.invalidPixelData("Image dimensions must be positive.")
        }

        let bytesPerSample = bitsPerComponent / 8
        let expectedCount = width * height * bytesPerSample
        guard data.count == expectedCount else {
            throw DicomImageExportError.invalidPixelData("Expected \(expectedCount) bytes, found \(data.count).")
        }

        guard let provider = CGDataProvider(data: data as CFData) else {
            throw DicomImageExportError.imageCreationFailed("Could not create a data provider.")
        }

        var bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        if bitsPerComponent == 16 {
            bitmapInfo.insert(.byteOrder16Little)
        }

        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerComponent,
            bytesPerRow: width * bytesPerSample,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw DicomImageExportError.imageCreationFailed("CoreGraphics rejected the grayscale image buffer.")
        }

        return image
    }

    private func makeRGBImage(data: Data, width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0 else {
            throw DicomImageExportError.invalidPixelData("Image dimensions must be positive.")
        }
        guard data.count == width * height * 3 else {
            throw DicomImageExportError.invalidPixelData("RGB frame has \(data.count) bytes for \(width)x\(height).")
        }
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw DicomImageExportError.imageCreationFailed("Could not create a data provider.")
        }

        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: width * 3,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw DicomImageExportError.imageCreationFailed("CoreGraphics rejected the RGB image buffer.")
        }

        return image
    }

    private func writeImage(_ image: CGImage, to url: URL, options: DicomImageExportOptions) throws {
        if options.format == .jpeg, options.progressiveJPEG {
            try writeProgressiveJPEG(image, to: url, quality: options.quality)
            return
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            options.format.contentTypeIdentifier,
            1,
            nil
        ) else {
            throw DicomImageExportError.fileNotWritable(path: url.path, reason: "Could not create image destination.")
        }

        var properties: [CFString: Any] = [:]
        if options.format == .jpeg || options.format == .tiff {
            properties[kCGImageDestinationLossyCompressionQuality] = NSNumber(value: options.quality)
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw DicomImageExportError.fileNotWritable(path: url.path, reason: "Could not finalize image write.")
        }
    }

    /// Progressive JPEG through the own encoder: the CGImage is rendered to 8-bit grayscale or RGB samples and
    /// encoded as SOF2 (spectral-selection scan script) at full chroma resolution.
    private func writeProgressiveJPEG(_ image: CGImage, to url: URL, quality: Double) throws {
        let width = image.width, height = image.height
        let grayscale = image.colorSpace?.model == .monochrome && image.bitsPerPixel <= 8
        let components = grayscale ? 1 : 3
        var buffer = [UInt8](repeating: 0, count: width * height * (grayscale ? 1 : 4))
        let space = grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let info = grayscale ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * (grayscale ? 1 : 4), space: space, bitmapInfo: info) else {
            throw DicomImageExportError.imageCreationFailed("CoreGraphics could not render the frame for progressive JPEG.")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var samples: [UInt8]
        if grayscale {
            samples = buffer
        } else {
            samples = []
            samples.reserveCapacity(width * height * 3)
            for pixel in 0..<(width * height) { samples += [buffer[pixel * 4], buffer[pixel * 4 + 1], buffer[pixel * 4 + 2]] }
        }
        let encoded: Data
        do {
            let jli = try JLIImage(width: width, height: height, pixelFormat: .uint8, colorModel: components == 1 ? .grayscale : .rgb, data: samples)
            let configuration = JLIEncoderConfiguration(quality: max(1, min(100, (quality * 100).rounded())), chromaSubsampling: .yuv444,
                                                        colorSpace: .yCbCr, progressive: true, progressiveMode: .spectralSelection,
                                                        optimiseHuffman: true, adaptiveQuantization: false, perceptualQuantTables: false)
            encoded = Data(try JLIEncoder().encode(jli, configuration: configuration))
        } catch {
            throw DicomImageExportError.imageCreationFailed("Progressive JPEG encoding failed: \(error)")
        }
        do { try encoded.write(to: url, options: [.atomic]) } catch {
            throw DicomImageExportError.fileNotWritable(path: url.path, reason: error.localizedDescription)
        }
    }

    private func validateWritable(_ url: URL, overwrite: Bool) throws {
        if FileManager.default.fileExists(atPath: url.path), !overwrite {
            throw DicomImageExportError.outputFileExists(path: url.path)
        }
    }

    private func writeMetadataIfNeeded(
        decoder: DCMDecoder,
        descriptor: DicomPixelDataDescriptor,
        imageURL: URL,
        options: DicomImageExportOptions,
        sourceFrameIndex: Int,
        sourceFrameCount: Int?
    ) throws -> URL? {
        guard options.metadataPolicy == .nonPHISidecar else { return nil }

        let metadataURL = imageURL.appendingPathExtension("json")
        try validateWritable(metadataURL, overwrite: options.overwrite)

        let metadata = NonPHIExportMetadata(
            format: options.format.rawValue,
            frameIndex: sourceFrameIndex,
            frameNumber: sourceFrameIndex + 1,
            rows: descriptor.rows,
            columns: descriptor.columns,
            numberOfFrames: sourceFrameCount ?? descriptor.numberOfFrames,
            bitsAllocated: descriptor.bitsAllocated,
            bitsStored: descriptor.bitsStored,
            samplesPerPixel: descriptor.samplesPerPixel,
            photometricInterpretation: descriptor.photometricInterpretation,
            modality: blankToNil(decoder.info(for: .modality)),
            transferSyntaxUID: blankToNil(decoder.info(for: .transferSyntaxUID)),
            pixelSpacing: pixelSpacing(decoder),
            rescaleSlope: decoder.doubleValue(for: .rescaleSlope),
            rescaleIntercept: decoder.doubleValue(for: .rescaleIntercept),
            rescaleType: blankToNil(decoder.info(for: .rescaleType)),
            displayWindow: displayWindowMetadata(decoder: decoder, options: options)
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
        } catch {
            throw DicomImageExportError.metadataEncodingFailed(error.localizedDescription)
        }

        return metadataURL
    }

    private func displayWindowMetadata(
        decoder: DCMDecoder,
        options: DicomImageExportOptions
    ) -> NonPHIExportMetadata.DisplayWindow? {
        guard case .display8(let selection) = options.pixelMode else {
            return nil
        }

        let profile = decoder.displayTransformProfile
        let resolvedSelection: DicomDisplaySelection?
        let sourceOverride: String?
        if let selection {
            resolvedSelection = selection
            sourceOverride = nil
        } else if let defaultSelection = profile.defaultSelection {
            resolvedSelection = defaultSelection
            sourceOverride = nil
        } else if let autoWindow = decoder.calculatePercentileWindow(lower: 0.01, upper: 0.99) {
            resolvedSelection = .customWindow(autoWindow)
            sourceOverride = "auto-percentile"
        } else {
            resolvedSelection = nil
            sourceOverride = nil
        }

        switch resolvedSelection {
        case .window(let index):
            let windows = profile.windows
            guard windows.indices.contains(index) else { return nil }
            return NonPHIExportMetadata.DisplayWindow(
                center: windows[index].settings.center,
                width: windows[index].settings.width,
                source: "dicom"
            )
        case .preset(let preset):
            let settings = DCMWindowingProcessor.getPresetValuesV2(preset: preset)
            return NonPHIExportMetadata.DisplayWindow(center: settings.center, width: settings.width, source: "preset")
        case .customWindow(let settings):
            return NonPHIExportMetadata.DisplayWindow(
                center: settings.center,
                width: settings.width,
                source: sourceOverride ?? "custom"
            )
        case .voiLUT:
            return NonPHIExportMetadata.DisplayWindow(center: nil, width: nil, source: "voi-lut")
        case nil:
            return nil
        }
    }

    private func pixelSpacing(_ decoder: DCMDecoder) -> [Double]? {
        let spacing = decoder.pixelSpacingV2
        guard spacing.isValid else { return nil }
        return [spacing.x, spacing.y]
    }

    private func blankToNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public extension DCMDecoder {
    func exportImage(
        frame frameIndex: Int = 0,
        to url: URL,
        options: DicomImageExportOptions = DicomImageExportOptions()
    ) throws -> DicomImageExportResult {
        try DicomImageExporter().export(decoder: self, frame: frameIndex, to: url, options: options)
    }

    func exportAllFrames(
        to directoryURL: URL,
        baseName: String,
        options: DicomImageExportOptions = DicomImageExportOptions()
    ) throws -> [DicomImageExportResult] {
        try DicomImageExporter().exportAllFrames(decoder: self, to: directoryURL, baseName: baseName, options: options)
    }
}

private struct NonPHIExportMetadata: Codable {
    struct DisplayWindow: Codable {
        let center: Double?
        let width: Double?
        let source: String
    }

    let format: String
    let frameIndex: Int
    let frameNumber: Int
    let rows: Int
    let columns: Int
    let numberOfFrames: Int
    let bitsAllocated: Int
    let bitsStored: Int
    let samplesPerPixel: Int
    let photometricInterpretation: String
    let modality: String?
    let transferSyntaxUID: String?
    let pixelSpacing: [Double]?
    let rescaleSlope: Double?
    let rescaleIntercept: Double?
    let rescaleType: String?
    let displayWindow: DisplayWindow?
}
