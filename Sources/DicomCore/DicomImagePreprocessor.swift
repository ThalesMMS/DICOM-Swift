import Foundation

public struct DicomImageSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        width > 0 && height > 0
    }
}

public struct DicomRGBPixel: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct DicomOverlayColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let red = DicomOverlayColor(red: 255, green: 0, blue: 0)
    public static let green = DicomOverlayColor(red: 0, green: 255, blue: 0)
    public static let blue = DicomOverlayColor(red: 0, green: 0, blue: 255)
    public static let white = DicomOverlayColor(red: 255, green: 255, blue: 255)
    public static let black = DicomOverlayColor(red: 0, green: 0, blue: 0)
}

public struct DicomNormalizedImagePoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct DicomNormalizedImageRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum DicomAnnotationOverlay: Equatable, Sendable {
    case line(start: DicomNormalizedImagePoint, end: DicomNormalizedImagePoint, color: DicomOverlayColor, thickness: Int)
    case rectangle(rect: DicomNormalizedImageRect, color: DicomOverlayColor, thickness: Int)
}

public struct DicomRenderedBitmap: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let rgbData: Data

    public init(width: Int, height: Int, rgbData: Data) throws {
        guard width > 0, height > 0 else {
            throw DicomImagePreprocessingError.invalidDimensions(width: width, height: height)
        }
        guard rgbData.count == width * height * 3 else {
            throw DicomImagePreprocessingError.invalidBitmapData(
                "Expected \(width * height * 3) RGB bytes, found \(rgbData.count)."
            )
        }
        self.width = width
        self.height = height
        self.rgbData = rgbData
    }

    public func pixel(x: Int, y: Int) -> DicomRGBPixel? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let offset = (y * width + x) * 3
        return DicomRGBPixel(
            red: rgbData[offset],
            green: rgbData[offset + 1],
            blue: rgbData[offset + 2]
        )
    }
}

public struct DicomImagePreprocessOptions: Sendable {
    public let frameIndex: Int
    public let displaySelection: DicomDisplaySelection?
    public let displayTransformProfile: DicomDisplayTransformProfile?
    public let outputSize: DicomImageSize?
    public let annotations: [DicomAnnotationOverlay]

    public init(
        frameIndex: Int = 0,
        displaySelection: DicomDisplaySelection? = nil,
        displayTransformProfile: DicomDisplayTransformProfile? = nil,
        outputSize: DicomImageSize? = nil,
        annotations: [DicomAnnotationOverlay] = []
    ) {
        self.frameIndex = frameIndex
        self.displaySelection = displaySelection
        self.displayTransformProfile = displayTransformProfile
        self.outputSize = outputSize
        self.annotations = annotations
    }
}

public enum DicomImagePreprocessingError: Error, Equatable, LocalizedError, Sendable {
    case missingPixelData
    case invalidFrame(index: Int, frameCount: Int)
    case invalidDimensions(width: Int, height: Int)
    case invalidBitmapData(String)
    case displayTransformFailed(pixelIndex: Int)

    public var errorDescription: String? {
        switch self {
        case .missingPixelData:
            return "Native uncompressed Pixel Data is not available for preprocessing."
        case .invalidFrame(let index, let frameCount):
            return "Invalid frame \(index). Frame count is \(frameCount)."
        case .invalidDimensions(let width, let height):
            return "Invalid bitmap dimensions: \(width)x\(height)."
        case .invalidBitmapData(let reason):
            return "Invalid bitmap data: \(reason)"
        case .displayTransformFailed(let pixelIndex):
            return "Could not derive display value for pixel \(pixelIndex)."
        }
    }
}

public struct DicomImagePreprocessor {
    public init() {}

    public func render(
        decoder: DCMDecoder,
        options: DicomImagePreprocessOptions = DicomImagePreprocessOptions()
    ) throws -> DicomRenderedBitmap {
        guard let descriptor = decoder.pixelDataDescriptor else {
            throw DicomImagePreprocessingError.missingPixelData
        }
        guard options.frameIndex >= 0, options.frameIndex < descriptor.numberOfFrames else {
            throw DicomImagePreprocessingError.invalidFrame(
                index: options.frameIndex,
                frameCount: descriptor.numberOfFrames
            )
        }

        let source = try makeSourceBitmap(decoder: decoder, descriptor: descriptor, options: options)
        let resized: DicomRenderedBitmap
        if let outputSize = options.outputSize {
            resized = try DicomBitmapResizer.resized(source, to: outputSize)
        } else {
            resized = source
        }

        return try DicomAnnotationRenderer.rendering(options.annotations, onto: resized)
    }

    private func makeSourceBitmap(
        decoder: DCMDecoder,
        descriptor: DicomPixelDataDescriptor,
        options: DicomImagePreprocessOptions
    ) throws -> DicomRenderedBitmap {
        if descriptor.samplesPerPixel != 1 {
            let displayBuffer = try decoder.displayRGBPixelBuffer(frame: options.frameIndex)
            return try DicomRenderedBitmap(
                width: displayBuffer.width,
                height: displayBuffer.height,
                rgbData: displayBuffer.rgbData
            )
        }

        let pixelsPerFrame = descriptor.rows * descriptor.columns
        let profile = options.displayTransformProfile ?? decoder.displayTransformProfile
        let selection = options.displaySelection
            ?? profile.defaultSelection
            ?? decoder.calculatePercentileWindow(lower: 0.01, upper: 0.99).map { .customWindow($0) }

        // Issue #1906: at most 2^BitsStored distinct stored values exist, so
        // the whole presentation chain — Modality LUT/rescale, VOI,
        // presentation inversion, the UInt8 rounding — is evaluated once per
        // value into a cached table instead of once per pixel. The table is
        // built FROM `displayValue`, so it answers exactly what the scalar
        // path would, nil included; the scalar path remains the fallback for
        // configurations no table can represent.
        let displayLUT = DicomDisplayLUTCache.shared.table(
            profile: profile,
            selection: selection,
            bitsStored: descriptor.bitsStored,
            isSigned: descriptor.pixelRepresentation == 1
        )

        var rgb = Data()
        rgb.reserveCapacity(pixelsPerFrame * 3)

        guard let storedValues = decoder.storedPixelValues(frame: options.frameIndex, sample: 0), storedValues.count == pixelsPerFrame else {
            throw DicomImagePreprocessingError.displayTransformFailed(pixelIndex: 0)
        }
        for pixelIndex in 0..<pixelsPerFrame {
            let storedValue = storedValues[pixelIndex]
            let displayValue: UInt8?
            if let displayLUT {
                displayValue = displayLUT.displayValue(forStoredPixelValue: storedValue)
            } else {
                displayValue = profile.displayValue(forStoredPixelValue: Double(storedValue),
                                                    selection: selection)
            }
            guard let displayValue else {
                throw DicomImagePreprocessingError.displayTransformFailed(pixelIndex: pixelIndex)
            }
            rgb.append(displayValue)
            rgb.append(displayValue)
            rgb.append(displayValue)
        }

        return try DicomRenderedBitmap(width: descriptor.columns, height: descriptor.rows, rgbData: rgb)
    }
}

public struct DicomBitmapResizer {
    public static func resized(_ bitmap: DicomRenderedBitmap, to size: DicomImageSize) throws -> DicomRenderedBitmap {
        guard size.isValid else {
            throw DicomImagePreprocessingError.invalidDimensions(width: size.width, height: size.height)
        }
        guard size.width != bitmap.width || size.height != bitmap.height else {
            return bitmap
        }

        var output = Data(count: size.width * size.height * 3)
        let sourceBytes = [UInt8](bitmap.rgbData)

        output.withUnsafeMutableBytes { outputBuffer in
            guard let outputBase = outputBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<size.height {
                let sourceY = min(bitmap.height - 1, Int(Double(y) * Double(bitmap.height) / Double(size.height)))
                for x in 0..<size.width {
                    let sourceX = min(bitmap.width - 1, Int(Double(x) * Double(bitmap.width) / Double(size.width)))
                    let sourceOffset = (sourceY * bitmap.width + sourceX) * 3
                    let destOffset = (y * size.width + x) * 3
                    outputBase[destOffset] = sourceBytes[sourceOffset]
                    outputBase[destOffset + 1] = sourceBytes[sourceOffset + 1]
                    outputBase[destOffset + 2] = sourceBytes[sourceOffset + 2]
                }
            }
        }

        return try DicomRenderedBitmap(width: size.width, height: size.height, rgbData: output)
    }
}

public struct DicomAnnotationRenderer {
    public static func rendering(
        _ annotations: [DicomAnnotationOverlay],
        onto bitmap: DicomRenderedBitmap
    ) throws -> DicomRenderedBitmap {
        guard !annotations.isEmpty else { return bitmap }

        var pixels = [UInt8](bitmap.rgbData)
        for annotation in annotations {
            switch annotation {
            case .line(let start, let end, let color, let thickness):
                drawLine(
                    from: pixelPoint(start, width: bitmap.width, height: bitmap.height),
                    to: pixelPoint(end, width: bitmap.width, height: bitmap.height),
                    color: color,
                    thickness: thickness,
                    width: bitmap.width,
                    height: bitmap.height,
                    pixels: &pixels
                )
            case .rectangle(let rect, let color, let thickness):
                drawRectangle(
                    rect,
                    color: color,
                    thickness: thickness,
                    width: bitmap.width,
                    height: bitmap.height,
                    pixels: &pixels
                )
            }
        }

        return try DicomRenderedBitmap(width: bitmap.width, height: bitmap.height, rgbData: Data(pixels))
    }

    private static func drawRectangle(
        _ rect: DicomNormalizedImageRect,
        color: DicomOverlayColor,
        thickness: Int,
        width: Int,
        height: Int,
        pixels: inout [UInt8]
    ) {
        let topLeft = pixelPoint(DicomNormalizedImagePoint(x: rect.x, y: rect.y), width: width, height: height)
        let bottomRight = pixelPoint(
            DicomNormalizedImagePoint(x: rect.x + rect.width, y: rect.y + rect.height),
            width: width,
            height: height
        )
        let topRight = (x: bottomRight.x, y: topLeft.y)
        let bottomLeft = (x: topLeft.x, y: bottomRight.y)

        drawLine(from: topLeft, to: topRight, color: color, thickness: thickness, width: width, height: height, pixels: &pixels)
        drawLine(from: topRight, to: bottomRight, color: color, thickness: thickness, width: width, height: height, pixels: &pixels)
        drawLine(from: bottomRight, to: bottomLeft, color: color, thickness: thickness, width: width, height: height, pixels: &pixels)
        drawLine(from: bottomLeft, to: topLeft, color: color, thickness: thickness, width: width, height: height, pixels: &pixels)
    }

    private static func drawLine(
        from start: (x: Int, y: Int),
        to end: (x: Int, y: Int),
        color: DicomOverlayColor,
        thickness: Int,
        width: Int,
        height: Int,
        pixels: inout [UInt8]
    ) {
        var x0 = start.x
        var y0 = start.y
        let x1 = end.x
        let y1 = end.y
        let dx = abs(x1 - x0)
        let sx = x0 < x1 ? 1 : -1
        let dy = -abs(y1 - y0)
        let sy = y0 < y1 ? 1 : -1
        var error = dx + dy

        while true {
            blendPixel(x: x0, y: y0, color: color, thickness: thickness, width: width, height: height, pixels: &pixels)
            if x0 == x1 && y0 == y1 { break }
            let doubledError = 2 * error
            if doubledError >= dy {
                error += dy
                x0 += sx
            }
            if doubledError <= dx {
                error += dx
                y0 += sy
            }
        }
    }

    private static func blendPixel(
        x: Int,
        y: Int,
        color: DicomOverlayColor,
        thickness: Int,
        width: Int,
        height: Int,
        pixels: inout [UInt8]
    ) {
        let clampedThickness = max(1, thickness)
        let lowerOffset = -(clampedThickness / 2)
        let upperOffset = lowerOffset + clampedThickness - 1
        for yy in (y + lowerOffset)...(y + upperOffset) {
            for xx in (x + lowerOffset)...(x + upperOffset) {
                guard xx >= 0, xx < width, yy >= 0, yy < height else { continue }
                let offset = (yy * width + xx) * 3
                pixels[offset] = blend(source: pixels[offset], overlay: color.red, alpha: color.alpha)
                pixels[offset + 1] = blend(source: pixels[offset + 1], overlay: color.green, alpha: color.alpha)
                pixels[offset + 2] = blend(source: pixels[offset + 2], overlay: color.blue, alpha: color.alpha)
            }
        }
    }

    private static func blend(source: UInt8, overlay: UInt8, alpha: UInt8) -> UInt8 {
        guard alpha < 255 else { return overlay }
        guard alpha > 0 else { return source }
        let a = Double(alpha) / 255.0
        let value = Double(source) * (1.0 - a) + Double(overlay) * a
        return UInt8(max(0, min(255, Int(value.rounded()))))
    }

    private static func pixelPoint(
        _ point: DicomNormalizedImagePoint,
        width: Int,
        height: Int
    ) -> (x: Int, y: Int) {
        let normalizedX = min(max(point.x, 0.0), 1.0)
        let normalizedY = min(max(point.y, 0.0), 1.0)
        return (
            x: Int((normalizedX * Double(max(0, width - 1))).rounded()),
            y: Int((normalizedY * Double(max(0, height - 1))).rounded())
        )
    }
}
