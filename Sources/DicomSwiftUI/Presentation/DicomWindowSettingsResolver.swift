//
//  DicomWindowSettingsResolver.swift
//
//  Pure helper for resolving concrete window/level settings from a requested windowing mode.
//

import Foundation
import DicomCore

/// Resolves concrete `WindowSettings` values for a given ``DicomImageRenderer/WindowingMode``.
///
/// This helper exists to keep ``DicomImageViewModel`` focused on state management and coordination,
/// while the selection logic (automatic/preset/custom/fromDecoder + fallback) remains reusable and
/// testable in isolation.
public enum DicomWindowSettingsResolver {

    /// Resolve concrete window/level settings for the specified windowing mode using the provided decoder.
    ///
    /// - Parameters:
    ///   - mode: The requested windowing mode.
    ///   - decoder: A decoder supplying pixel data and any stored window settings.
    /// - Returns: The resolved `WindowSettings` (center and width) used for rendering.
    /// - Throws: `DICOMError/invalidPixelData(reason:)` when pixel data required for calculation is missing.
    public static func resolve(
        mode: DicomImageRenderer.WindowingMode,
        decoder: any DicomImageRendererDecoderProtocol
    ) throws -> WindowSettings {
        switch mode {
        case .automatic:
            guard let pixels16 = decoder.getPixels16() else {
                throw DICOMError.invalidPixelData(reason: "Missing pixel data for automatic windowing")
            }
            return DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels16)

        case .preset(let medicalPreset):
            return DCMWindowingProcessor.getPresetValuesV2(preset: medicalPreset)

        case .custom(let center, let width):
            return WindowSettings(center: center, width: width)

        case .fromDecoder:
            let settings = decoder.windowSettingsV2
            if settings.isValid {
                return settings
            }

            // Fallback to automatic if metadata invalid
            guard let pixels16 = decoder.getPixels16() else {
                throw DICOMError.invalidPixelData(reason: "Missing pixel data for automatic windowing fallback")
            }
            return DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels16)
        }
    }
}
