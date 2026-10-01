import Foundation

/// Portable, deterministic operations over interleaved 8-bit RGB bitmaps.
public enum DicomBitmapOperations {
    /// Returns the requested rectangular pixel region.
    public static func cropped(
        _ bitmap: DicomRenderedBitmap,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) throws -> DicomRenderedBitmap {
        guard x >= 0,
              y >= 0,
              width > 0,
              height > 0,
              x + width <= bitmap.width,
              y + height <= bitmap.height else {
            throw DicomImagePreprocessingError.invalidBitmapData(
                "Crop (\(x), \(y), \(width), \(height)) exceeds \(bitmap.width)x\(bitmap.height) bitmap."
            )
        }

        var data = Data(capacity: width * height * 3)
        bitmap.rgbData.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let base = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for row in 0..<height {
                let start = ((y + row) * bitmap.width + x) * 3
                data.append(contentsOf: UnsafeBufferPointer(start: base + start, count: width * 3))
            }
        }
        return try DicomRenderedBitmap(width: width, height: height, rgbData: data)
    }

    /// Rotates a bitmap clockwise in 90-degree increments.
    public static func rotated(
        _ bitmap: DicomRenderedBitmap,
        clockwiseQuarterTurns: Int
    ) throws -> DicomRenderedBitmap {
        let turns = ((clockwiseQuarterTurns % 4) + 4) % 4
        guard turns != 0 else { return bitmap }
        let outputWidth = turns.isMultiple(of: 2) ? bitmap.width : bitmap.height
        let outputHeight = turns.isMultiple(of: 2) ? bitmap.height : bitmap.width
        var output = [UInt8](repeating: 0, count: outputWidth * outputHeight * 3)

        bitmap.rgbData.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let base = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for sourceY in 0..<bitmap.height {
                for sourceX in 0..<bitmap.width {
                    let destinationX: Int
                    let destinationY: Int
                    switch turns {
                    case 1:
                        destinationX = outputWidth - 1 - sourceY
                        destinationY = sourceX
                    case 2:
                        destinationX = outputWidth - 1 - sourceX
                        destinationY = outputHeight - 1 - sourceY
                    default:
                        destinationX = sourceY
                        destinationY = outputHeight - 1 - sourceX
                    }
                    let sourceOffset = (sourceY * bitmap.width + sourceX) * 3
                    let destinationOffset = (destinationY * outputWidth + destinationX) * 3
                    output[destinationOffset] = base[sourceOffset]
                    output[destinationOffset + 1] = base[sourceOffset + 1]
                    output[destinationOffset + 2] = base[sourceOffset + 2]
                }
            }
        }
        return try DicomRenderedBitmap(
            width: outputWidth,
            height: outputHeight,
            rgbData: Data(output)
        )
    }

    /// Mirrors a bitmap across either or both axes.
    public static func flipped(
        _ bitmap: DicomRenderedBitmap,
        horizontally: Bool,
        vertically: Bool
    ) throws -> DicomRenderedBitmap {
        guard horizontally || vertically else { return bitmap }
        var output = [UInt8](repeating: 0, count: bitmap.rgbData.count)
        bitmap.rgbData.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let base = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for destinationY in 0..<bitmap.height {
                let sourceY = vertically ? bitmap.height - 1 - destinationY : destinationY
                for destinationX in 0..<bitmap.width {
                    let sourceX = horizontally ? bitmap.width - 1 - destinationX : destinationX
                    let sourceOffset = (sourceY * bitmap.width + sourceX) * 3
                    let destinationOffset = (destinationY * bitmap.width + destinationX) * 3
                    output[destinationOffset] = base[sourceOffset]
                    output[destinationOffset + 1] = base[sourceOffset + 1]
                    output[destinationOffset + 2] = base[sourceOffset + 2]
                }
            }
        }
        return try DicomRenderedBitmap(
            width: bitmap.width,
            height: bitmap.height,
            rgbData: Data(output)
        )
    }

    /// Inverts every RGB channel in a bitmap.
    public static func inverted(_ bitmap: DicomRenderedBitmap) throws -> DicomRenderedBitmap {
        try DicomRenderedBitmap(
            width: bitmap.width,
            height: bitmap.height,
            rgbData: Data(bitmap.rgbData.map { 255 &- $0 })
        )
    }

    /// Expands one 8-bit grayscale sample into three equal RGB channels.
    public static func rgbData(fromGrayscale grayscale: Data) -> Data {
        var rgb = Data(capacity: grayscale.count * 3)
        for value in grayscale {
            rgb.append(value)
            rgb.append(value)
            rgb.append(value)
        }
        return rgb
    }

    /// Converts interleaved RGB pixels to 8-bit luminance samples.
    static func grayscaleData(fromRGB rgb: Data) -> Data {
        var grayscale = Data(capacity: rgb.count / 3)
        rgb.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let base = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for offset in stride(from: 0, to: source.count, by: 3) {
                let red = UInt16(base[offset])
                let green = UInt16(base[offset + 1])
                let blue = UInt16(base[offset + 2])
                grayscale.append(UInt8((77 * red + 150 * green + 29 * blue) / 256))
            }
        }
        return grayscale
    }

    /// Returns the bitmap as display-ready grayscale RGB.
    public static func grayscale(_ bitmap: DicomRenderedBitmap) throws -> DicomRenderedBitmap {
        try DicomRenderedBitmap(
            width: bitmap.width,
            height: bitmap.height,
            rgbData: rgbData(fromGrayscale: grayscaleData(fromRGB: bitmap.rgbData))
        )
    }

    /// Joins two equally wide bitmaps with the first bitmap above the second.
    public static func concatenatingVertically(
        _ top: DicomRenderedBitmap,
        _ bottom: DicomRenderedBitmap
    ) throws -> DicomRenderedBitmap {
        guard top.width == bottom.width else {
            throw DicomImagePreprocessingError.invalidBitmapData(
                "Cannot concatenate bitmap widths \(top.width) and \(bottom.width)."
            )
        }
        var data = Data(capacity: top.rgbData.count + bottom.rgbData.count)
        data.append(top.rgbData)
        data.append(bottom.rgbData)
        return try DicomRenderedBitmap(
            width: top.width,
            height: top.height + bottom.height,
            rgbData: data
        )
    }
}
