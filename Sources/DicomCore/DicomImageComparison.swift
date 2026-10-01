//
//  DicomImageComparison.swift
//  DicomCore
//
//  Error metrics between two DICOM images, like DCMTK's dcmicmp (issue #2836).
//

import Foundation

/// Compares a test image with a reference image frame by frame (issue #2836). The metrics follow DCMTK's
/// `dcmicmp` (after Gonzalez and Woods): maximum absolute error, mean absolute error, RMSE, PSNR against the
/// reference's largest squared value, and SNR as the reference's energy over the error's.
public enum DicomImageComparison {
    /// Which values are compared.
    public enum Stage: Equatable, Sendable {
        /// Stored sample values.
        case stored
        /// Stored values through Rescale Slope/Intercept (dcmicmp's default, `+M -W`).
        case modality
        /// Modality values through a linear VOI window (PS3.3 C.11.2.1.2) to the 0...65535 output of an image
        /// stored in more than 8 bits, 0...255 otherwise (dcmicmp `+Ww`). MONOCHROME1 polarity is applied after
        /// windowing. Grayscale only.
        case window(center: Double, width: Double)
    }

    public struct Metrics: Equatable, Sendable {
        public let maximumAbsoluteError: Double
        public let meanAbsoluteError: Double
        public let rootMeanSquareError: Double
        /// +∞ when the images are equal.
        public let peakSignalToNoiseRatio: Double
        /// +∞ when the images are equal.
        public let signalToNoiseRatio: Double
        public let sampleCount: Int
    }

    public struct Result: Equatable, Sendable {
        public let frames: [Metrics]
        public let total: Metrics
        /// Per sample |reference − test| in frame order; empty unless `collectDifferences` is enabled.
        public let absoluteDifferences: [[Double]]
    }

    public enum ComparisonError: Error, Equatable, LocalizedError, Sendable {
        case geometryMismatch(reference: String, test: String)
        case windowOnColor
        case invalidWindow
        case undecodableFrame(index: Int, reason: String)

        public var errorDescription: String? {
            switch self {
            case let .geometryMismatch(reference, test):
                return "The images differ in geometry: reference \(reference), test \(test)."
            case .windowOnColor:
                return "A VOI window compares grayscale images only."
            case .invalidWindow:
                return "The VOI window width must be at least 1."
            case let .undecodableFrame(index, reason):
                return "Frame \(index) cannot be decoded: \(reason)"
            }
        }
    }

    /// Compares every frame of `test` with the same frame of `reference`. Rows, columns, frames and samples per
    /// pixel must match.
    public static func compare(reference: DCMDecoder, test: DCMDecoder, stage: Stage = .modality,
                               collectDifferences: Bool = false) throws -> Result {
        let referenceShape = shape(of: reference)
        let testShape = shape(of: test)
        guard referenceShape == testShape else {
            throw ComparisonError.geometryMismatch(reference: referenceShape.description, test: testShape.description)
        }
        if case let .window(_, width) = stage {
            guard width >= 1 else { throw ComparisonError.invalidWindow }
            guard referenceShape.samples == 1 else { throw ComparisonError.windowOnColor }
        }
        let (pixelsPerFrame, pixelOverflow) = referenceShape.rows.multipliedReportingOverflow(by: referenceShape.columns)
        let (samplesPerFrame, sampleOverflow) = pixelsPerFrame.multipliedReportingOverflow(by: referenceShape.samples)
        guard referenceShape.rows > 0, referenceShape.columns > 0, referenceShape.samples > 0,
              !pixelOverflow, !sampleOverflow else {
            throw ComparisonError.undecodableFrame(index: 0, reason: "Invalid declared frame dimensions.")
        }
        var frames: [Metrics] = []
        var differences: [[Double]] = []
        var totals = Accumulator()
        for index in 0 ..< referenceShape.frames {
            let expected = try values(of: reference, frame: index, stage: stage)
            let actual = try values(of: test, frame: index, stage: stage)
            guard expected.count == samplesPerFrame, actual.count == samplesPerFrame else {
                throw ComparisonError.undecodableFrame(index: index,
                    reason: "Expected \(samplesPerFrame) samples; decoded reference \(expected.count), test \(actual.count).")
            }
            var accumulator = Accumulator()
            var frameDifferences = collectDifferences ? [Double](repeating: 0, count: expected.count) : []
            for sample in 0 ..< samplesPerFrame {
                let difference = abs(expected[sample] - actual[sample])
                if collectDifferences { frameDifferences[sample] = difference }
                accumulator.add(reference: expected[sample], difference: difference)
            }
            totals.merge(accumulator)
            frames.append(accumulator.metrics)
            if collectDifferences { differences.append(frameDifferences) }
        }
        return Result(frames: frames, total: totals.metrics, absoluteDifferences: differences)
    }

    /// The metrics of two equally long sample sequences already at the compared stage (a decoder's frames in
    /// another convention, say); samples past the shorter one are ignored.
    public static func metrics(reference: [Double], test: [Double]) -> Metrics {
        var accumulator = Accumulator()
        for index in 0 ..< min(reference.count, test.count) {
            accumulator.add(reference: reference[index], difference: abs(reference[index] - test[index]))
        }
        return accumulator.metrics
    }

    private struct Shape: Equatable {
        let rows: Int, columns: Int, frames: Int, samples: Int
        var description: String { "\(columns)×\(rows), \(frames) frame(s), \(samples) sample(s)" }
    }

    private static func shape(of decoder: DCMDecoder) -> Shape {
        Shape(rows: decoder.height, columns: decoder.width, frames: max(1, decoder.nImages),
              samples: decoder.samplesPerPixel)
    }

    private struct Accumulator {
        var count = 0
        var maximum = 0.0
        var absoluteSum = 0.0
        var squareErrorSum = 0.0
        var squareReferenceSum = 0.0
        var squareSignalStrength = 0.0

        mutating func add(reference: Double, difference: Double) {
            count += 1
            maximum = max(maximum, difference)
            absoluteSum += difference
            squareErrorSum += difference * difference
            squareReferenceSum += reference * reference
            squareSignalStrength = max(squareSignalStrength, reference * reference)
        }

        mutating func merge(_ other: Accumulator) {
            count += other.count
            maximum = max(maximum, other.maximum)
            absoluteSum += other.absoluteSum
            squareErrorSum += other.squareErrorSum
            squareReferenceSum += other.squareReferenceSum
            squareSignalStrength = max(squareSignalStrength, other.squareSignalStrength)
        }

        var metrics: Metrics {
            let samples = Double(max(count, 1))
            let meanSquareError = squareErrorSum / samples
            return Metrics(
                maximumAbsoluteError: maximum,
                meanAbsoluteError: absoluteSum / samples,
                rootMeanSquareError: meanSquareError.squareRoot(),
                peakSignalToNoiseRatio: meanSquareError == 0 ? .infinity
                    : -10 * log10(meanSquareError / squareSignalStrength),
                signalToNoiseRatio: squareErrorSum == 0 ? .infinity : 10 * log10(squareReferenceSum / squareErrorSum),
                sampleCount: count
            )
        }
    }

    /// One frame's values at `stage`: stored samples in their signed or unsigned range, colour interleaved.
    private static func values(of decoder: DCMDecoder, frame index: Int, stage: Stage) throws -> [Double] {
        let decoded: DicomDecodedFrame
        do {
            decoded = try DicomDecodedFrameReader(decoder: decoder).frame(at: index)
        } catch {
            throw ComparisonError.undecodableFrame(index: index, reason: error.localizedDescription)
        }
        let signed = decoder.pixelRepresentationTagValue == 1
        let stored: [Double]
        switch decoded.pixels {
        case .gray16:
            let samples = decoded.storedSampleData()
            stored = stride(from: 0, to: samples.count, by: 2).map { offset in
                let word = UInt16(samples[offset]) | UInt16(samples[offset + 1]) << 8
                return signed ? Double(Int16(bitPattern: word)) : Double(word)
            }
        case .gray8:
            stored = decoded.storedSampleData().map { signed ? Double(Int8(bitPattern: $0)) : Double($0) }
        case .rgb8(let pixels):
            return pixels.map(Double.init)
        }
        guard stage != .stored else { return stored }
        let rescale = decoder.rescaleParametersV2
        let modality = stored.map { $0 * rescale.slope + rescale.intercept }
        guard case let .window(center, width) = stage else { return modality }
        let bitsStored = decoder.intValue(for: .bitsStored) ?? decoder.bitDepth
        let top = bitsStored > 8 ? 65_535.0 : 255.0
        let inverted = decoded.metadata.photometricInterpretation == "MONOCHROME1"
        // PS3.3 C.11.2.1.2, computed as DCMTK does (offset plus gradient, truncated) so dcmicmp agrees.
        let windowOffset = ((center - 0.5) / (width - 1) + 0.5) * top
        let offset = inverted ? windowOffset : top - windowOffset
        let gradient = (inverted ? -top : top) / (width - 1)
        return modality.map { value in
            if value <= center - 0.5 - (width - 1) / 2 { return inverted ? top : 0 }
            if value > center - 0.5 + (width - 1) / 2 { return inverted ? 0 : top }
            return (offset + value * gradient).rounded(.towardZero)
        }
    }
}
