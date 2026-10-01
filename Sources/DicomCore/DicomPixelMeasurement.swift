import Foundation

/// Pixel statistics over a decoded frame or a rectangular region, in stored and rescaled units.
public struct DicomPixelStatistics: Codable, Equatable, Sendable {
    public struct Region: Codable, Equatable, Sendable {
        public var x: Int, y: Int, width: Int, height: Int
        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }
    public let frame: Int
    public let region: Region
    public let sampleCount: Int
    public let minimum: Double
    public let maximum: Double
    public let mean: Double
    public let standardDeviation: Double
    public let rescaleSlope: Double?
    public let rescaleIntercept: Double?
    public let rescaleType: String?
    /// Statistics after Rescale Slope/Intercept when present (e.g. Hounsfield units).
    public let rescaledMinimum: Double?
    public let rescaledMaximum: Double?
    public let rescaledMean: Double?
    public let histogram: [Int]
    public let histogramBinWidth: Double
    public let samplesPerPixel: Int
}

public struct DicomPixelDistance: Codable, Equatable, Sendable {
    public let fromX: Int, fromY: Int, toX: Int, toY: Int
    public let pixels: Double
    public let millimeters: Double?
    public let pixelSpacingRowMM: Double?
    public let pixelSpacingColumnMM: Double?
}

public enum DicomPixelMeasurementError: Error, Equatable, LocalizedError, Sendable {
    case regionOutOfBounds
    case emptyRegion
    public var errorDescription: String? {
        switch self {
        case .regionOutOfBounds: return "Region lies outside the frame"
        case .emptyRegion: return "Region has no pixels"
        }
    }
}

public enum DicomPixelMeasurement {
    /// Statistics of one frame; `region` defaults to the whole frame; colour frames use the luminance of each pixel.
    public static func statistics(frame: DicomDecodedFrame, region: DicomPixelStatistics.Region? = nil, bins: Int = 64) throws -> DicomPixelStatistics {
        let width = frame.metadata.width, height = frame.metadata.height
        let area = region ?? .init(x: 0, y: 0, width: width, height: height)
        guard area.x >= 0, area.y >= 0, area.width > 0, area.height > 0 else { throw DicomPixelMeasurementError.emptyRegion }
        guard area.x + area.width <= width, area.y + area.height <= height else { throw DicomPixelMeasurementError.regionOutOfBounds }
        var values = [Double](repeating: 0, count: area.width * area.height)
        let signed = frame.metadata.pixelRepresentation == 1
        let bitsStored = max(1, min(16, frame.metadata.bitsStored))
        let signBit = 1 << (bitsStored - 1)
        let mask = bitsStored >= 16 ? 0xFFFF : (1 << bitsStored) - 1
        let fullRange = 1 << bitsStored
        values.withUnsafeMutableBufferPointer { output in
            var cursor = 0
            switch frame.pixels {
            case .gray8:
                frame.storedSampleData().withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                    for row in area.y..<(area.y + area.height) {
                        let base = row * width
                        for column in area.x..<(area.x + area.width) {
                            let raw = Int(input[base + column])
                            let masked = raw & mask
                            output[cursor] = signed && masked & signBit != 0 ? Double(masked - fullRange) : Double(masked)
                            cursor += 1
                        }
                    }
                }
            case .gray16:
                frame.storedSampleData().withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                    for row in area.y..<(area.y + area.height) {
                        let base = row * width
                        for column in area.x..<(area.x + area.width) {
                            let offset = (base + column) * 2
                            let raw = Int(input[offset]) | Int(input[offset + 1]) << 8
                            let masked = raw & mask
                            if signed {
                                output[cursor] = masked & signBit != 0 ? Double(masked - fullRange) : Double(masked)
                            } else { output[cursor] = Double(masked) }
                            cursor += 1
                        }
                    }
                }
            case .rgb8(let interleaved):
                interleaved.withUnsafeBufferPointer { input in
                    for row in area.y..<(area.y + area.height) {
                        let base = row * width
                        for column in area.x..<(area.x + area.width) {
                            let offset = (base + column) * 3
                            output[cursor] = 0.299 * Double(input[offset]) + 0.587 * Double(input[offset + 1]) + 0.114 * Double(input[offset + 2])
                            cursor += 1
                        }
                    }
                }
            }
        }
        let count = Double(values.count)
        let minimum = values.min() ?? 0, maximum = values.max() ?? 0
        let mean = values.reduce(0, +) / count
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count
        let width_ = max(1, bins)
        let binWidth = maximum > minimum ? (maximum - minimum) / Double(width_) : 1
        var histogram = [Int](repeating: 0, count: width_)
        for value in values {
            let bin = min(width_ - 1, Int((value - minimum) / binWidth))
            histogram[max(0, bin)] += 1
        }
        let slope = frame.metadata.rescaleParameters.slope
        let intercept = frame.metadata.rescaleParameters.intercept
        let hasRescale = slope != 1 || intercept != 0
        let transformedMinimum = minimum * slope + intercept
        let transformedMaximum = maximum * slope + intercept
        return DicomPixelStatistics(frame: frame.index, region: area, sampleCount: values.count, minimum: minimum, maximum: maximum, mean: mean,
                                    standardDeviation: variance.squareRoot(), rescaleSlope: hasRescale ? slope : nil, rescaleIntercept: hasRescale ? intercept : nil,
                                    rescaleType: frame.metadata.presentationUnits, rescaledMinimum: hasRescale ? min(transformedMinimum, transformedMaximum) : nil,
                                    rescaledMaximum: hasRescale ? max(transformedMinimum, transformedMaximum) : nil, rescaledMean: hasRescale ? mean * slope + intercept : nil,
                                    histogram: histogram, histogramBinWidth: binWidth, samplesPerPixel: frame.metadata.samplesPerPixel)
    }

    /// Euclidean distance between two pixel centres; millimetres only when Pixel Spacing is known (row\\column).
    public static func distance(fromX: Int, fromY: Int, toX: Int, toY: Int, pixelSpacing: (row: Double, column: Double)?) -> DicomPixelDistance {
        let dx = Double(toX - fromX), dy = Double(toY - fromY)
        let pixels = (dx * dx + dy * dy).squareRoot()
        let millimeters = pixelSpacing.map { spacing in ((dx * spacing.column) * (dx * spacing.column) + (dy * spacing.row) * (dy * spacing.row)).squareRoot() }
        return DicomPixelDistance(fromX: fromX, fromY: fromY, toX: toX, toY: toY, pixels: pixels, millimeters: millimeters,
                                  pixelSpacingRowMM: pixelSpacing?.row, pixelSpacingColumnMM: pixelSpacing?.column)
    }

    public static func pixelSpacing(from dataSet: DicomDataSet) -> (row: Double, column: Double)? {
        let values = dataSet.strings(for: .pixelSpacing).compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == 2 else { return nil }
        return (values[0], values[1])
    }
}
