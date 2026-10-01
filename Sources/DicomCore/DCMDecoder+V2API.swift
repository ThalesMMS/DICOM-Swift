//
//  DCMDecoder+V2API.swift
//
//  Type-safe value helpers for DCMDecoder.
//

import Foundation

extension DCMDecoder {

    /// Returns pixel spacing as a type-safe struct
    public var pixelSpacingV2: PixelSpacing {
        synchronized {
            PixelSpacing(x: pixelWidth, y: pixelHeight, z: pixelDepth)
        }
    }

    /// Returns window settings as a type-safe struct
    public var windowSettingsV2: WindowSettings {
        synchronized {
            WindowSettings(center: windowCenter, width: windowWidth)
        }
    }

    /// Returns rescale parameters as a type-safe struct
    public var rescaleParametersV2: RescaleParameters {
        let parameters = currentRescaleParameters()
        return RescaleParameters(intercept: parameters.intercept, slope: parameters.slope)
    }

    /// Apply DICOM rescale slope and intercept to a raw pixel value.
    /// - Parameter pixelValue: The input pixel sample value before rescale.
    /// - Returns: The rescaled pixel value computed as `rescaleSlope * pixelValue + rescaleIntercept`.
    public func applyRescale(to pixelValue: Double) -> Double {
        let parameters = currentRescaleParameters()
        return parameters.slope * pixelValue + parameters.intercept
    }

    /// Calculates optimal window/level based on pixel data statistics
    /// Computes an optimal window center and width from the decoder's 16-bit pixel data.
    /// - Returns: A tuple `(center: Double, width: Double)` with the computed window center and width, or `nil` if no 16-bit pixel data is available.
    @available(*, deprecated, message: "Use calculateOptimalWindowV2() for type-safe WindowSettings struct")
    public func calculateOptimalWindow() -> (center: Double, width: Double)? {
        guard let pixels = getPixels16() else { return nil }
        let stats = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels)
        return (stats.center, stats.width)
    }

    /// Calculates the optimal window center and width for the decoder's pixel data.
    /// - Returns: A `WindowSettings` containing the calculated `center` and `width`, or `nil` if 16-bit pixel data is not available.
    public func calculateOptimalWindowV2() -> WindowSettings? {
        guard let pixels = getPixels16() else { return nil }
        let stats = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels)
        return WindowSettings(center: stats.center, width: stats.width)
    }

    /// Returns image quality metrics
    /// Compute quality metrics for the decoder's image pixels.
    /// - Returns: A dictionary mapping metric names to numeric values, or `nil` if 16-bit pixel data is unavailable.
    public func getQualityMetrics() -> [String: Double]? {
        guard let pixels = getPixels16() else { return nil }
        return DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels)
    }
}
