import Foundation

extension DCMWindowingProcessor {
    // MARK: - Preset Management

    /// Returns preset window/level values corresponding to a given
    /// medical preset, using the type-safe ``WindowSettings`` struct.
    /// If the preset is `.custom`, the default 4096-wide window centered at 0 is returned.
    /// These values correspond to standard Hounsfield Unit ranges used
    /// in radiology.
    ///
    /// ## Usage Example
    /// ```swift
    /// let settings = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)
    /// if settings.isValid {
    ///     // Apply windowing to image
    ///     let pixels8bit = DCMWindowingProcessor.applyWindowLevel(
    ///         pixels16: pixels,
    ///         center: settings.center,
    ///         width: settings.width
    ///     )
    /// }
    /// ```
    /// Maps a `MedicalPreset` to the recommended window center and width for image display.
    /// - Parameter preset: The medical preset whose windowing values are requested.
    /// - Returns: A `WindowSettings` containing the `center` and `width` appropriate for the given preset; for `.custom` this returns center `0.0` and width `4096.0`.
    public static func getPresetValuesV2(preset: MedicalPreset) -> WindowSettings {
        let (center, width): (Double, Double)
        switch preset {
        // Original CT Presets
        case .lung:
            (center, width) = (-600.0, 1500.0)  // Enhanced for better lung visualization
        case .bone:
            (center, width) = (400.0, 1800.0)
        case .softTissue:
            (center, width) = (50.0, 350.0)
        case .brain:
            (center, width) = (40.0, 80.0)
        case .liver:
            (center, width) = (120.0, 200.0)

        // Additional CT Presets
        case .mediastinum:
            (center, width) = (50.0, 350.0)
        case .abdomen:
            (center, width) = (60.0, 400.0)
        case .spine:
            (center, width) = (50.0, 250.0)
        case .pelvis:
            (center, width) = (40.0, 400.0)

        // Angiography Presets
        case .angiography:
            (center, width) = (300.0, 600.0)
        case .pulmonaryEmbolism:
            (center, width) = (100.0, 500.0)

        // Other Modalities
        case .mammography:
            (center, width) = (2000.0, 4000.0)  // For digital mammography
        case .petScan:
            (center, width) = (2500.0, 5000.0)  // SUV units

        // Custom/Default
        case .custom:
            (center, width) = (0.0, 4096.0)
        }
        return WindowSettings(center: center, width: width)
    }

    /// Suggests an ordered list of medical window/level presets appropriate for the given imaging modality and optional body part.
    /// - Parameters:
    ///   - modality: Imaging modality code (e.g., `"CT"`, `"MR"`, `"MG"`, `"PT"`); comparison is case-insensitive.
    ///   - bodyPart: Optional body part or region string used to refine `CT` recommendations (e.g., `"lung"`, `"brain"`, `"abdomen"`); comparison is case-insensitive and performed via substring matching.
    /// - Returns: An ordered array of `MedicalPreset` values recommended for the specified modality and body part.
    public static func suggestPresets(for modality: String, bodyPart: String? = nil) -> [MedicalPreset] {
        switch modality.uppercased() {
        case "CT":
            if let part = bodyPart?.lowercased() {
                if part.contains("lung") || part.contains("chest") || part.contains("thorax") {
                    return [.lung, .mediastinum, .bone, .softTissue]
                } else if part.contains("brain") || part.contains("head") {
                    return [.brain, .bone, .softTissue]
                } else if part.contains("abdomen") || part.contains("liver") {
                    return [.abdomen, .liver, .softTissue]
                } else if part.contains("spine") {
                    return [.spine, .bone, .softTissue]
                } else if part.contains("pelvis") {
                    return [.pelvis, .bone, .softTissue]
                }
            }
            return [.softTissue, .bone, .lung, .brain]

        case "MG":
            return [.mammography]

        case "PT":
            return [.petScan]

        case "MR":
            return [.brain, .softTissue]

        default:
            return [.custom]
        }
    }

}

// MARK: - DCMWindowingProcessor Preset Extensions

extension DCMWindowingProcessor {

    /// Get all available medical presets
    public static var allPresets: [MedicalPreset] {
        return MedicalPreset.allCases
    }

    /// Get all CT-specific presets
    public static var ctPresets: [MedicalPreset] {
        return [.lung, .bone, .softTissue, .brain, .liver, .mediastinum,
                .abdomen, .spine, .pelvis, .angiography, .pulmonaryEmbolism]
    }

    /// Returns preset window/level values corresponding to a preset name,
    /// using the type-safe ``WindowSettings`` struct.  This method accepts
    /// common preset names and their variations (e.g., "soft tissue" or
    /// "softtissue").  If the preset name is not recognized nil is returned.
    ///
    /// - Parameter presetName: The preset name (case-insensitive).
    /// - Returns: Window settings with center and width values, or nil if
    ///   the preset name is not recognized.
    ///
    /// ## Usage Example
    /// ```swift
    /// if let settings = DCMWindowingProcessor.getPresetValuesV2(named: "lung") {
    ///     // Apply windowing to image
    ///     let pixels8bit = DCMWindowingProcessor.applyWindowLevel(
    ///         pixels16: pixels,
    ///         center: settings.center,
    ///         width: settings.width
    ///     )
    /// } else {
    ///     print("Unknown preset name")
    /// }
    /// Maps a human-readable preset name to its corresponding window center and width settings.
    /// - Parameter presetName: A case-insensitive preset name or common alias (e.g., "lung", "bone", "soft tissue"/"softtissue", "pulmonary embolism"/"pe", "mammography"/"mammo", "pet"/"petscan").
    /// - Returns: The `WindowSettings` for the recognized preset, or `nil` if the name is not recognized.
    public static func getPresetValuesV2(named presetName: String) -> WindowSettings? {
        switch presetName.lowercased() {
        case "lung": return getPresetValuesV2(preset: .lung)
        case "bone": return getPresetValuesV2(preset: .bone)
        case "soft tissue", "softtissue": return getPresetValuesV2(preset: .softTissue)
        case "brain": return getPresetValuesV2(preset: .brain)
        case "liver": return getPresetValuesV2(preset: .liver)
        case "mediastinum": return getPresetValuesV2(preset: .mediastinum)
        case "abdomen": return getPresetValuesV2(preset: .abdomen)
        case "spine": return getPresetValuesV2(preset: .spine)
        case "pelvis": return getPresetValuesV2(preset: .pelvis)
        case "angiography": return getPresetValuesV2(preset: .angiography)
        case "pulmonary embolism", "pulmonaryembolism", "pe":
            return getPresetValuesV2(preset: .pulmonaryEmbolism)
        case "mammography", "mammo": return getPresetValuesV2(preset: .mammography)
        case "pet", "petscan", "pet scan": return getPresetValuesV2(preset: .petScan)
        default: return nil
        }
    }

    /// Get preset name from window settings (approximate match using type-safe WindowSettings)
    ///
    /// Searches through all available medical presets to find one matching the given
    /// window settings within the specified tolerance. This is useful for identifying
    /// which preset is currently applied or for reverse-mapping custom window values
    /// to standard presets.
    ///
    /// - Parameters:
    ///   - settings: The window settings to match against presets
    ///   - tolerance: Maximum allowed difference for center and width (default: 50.0)
    /// - Returns: The display name of the matching preset, or nil if no match found
    ///
    /// ## Example
    /// ```swift
    /// let settings = WindowSettings(center: -600.0, width: 1500.0)
    /// if let presetName = DCMWindowingProcessor.getPresetName(settings: settings) {
    ///     print("Matches preset: \(presetName)")  // "Matches preset: Lung"
    /// }
    /// Finds the display name of a preset whose center and width match the provided settings within a tolerance.
    /// - Parameters:
    ///   - settings: The `WindowSettings` (center and width) to match against known presets.
    ///   - tolerance: Maximum allowed absolute difference for both center and width to consider a match.
    /// - Returns: The display name of the first matching preset, or `nil` if no preset is within the given tolerance.
    public static func getPresetName(settings: WindowSettings, tolerance: Double = 50.0) -> String? {
        for preset in allPresets {
            let values = getPresetValuesV2(preset: preset)
            if abs(values.center - settings.center) <= tolerance && abs(values.width - settings.width) <= tolerance {
                return preset.displayName
            }
        }
        return nil
    }

    /// Provide the display name, window center, window width, and associated modality for a given preset.
    /// - Returns: A tuple with:
    ///   - name: The preset's human-readable display name.
    ///   - center: Window center value for the preset.
    ///   - width: Window width value for the preset.
    ///   - modality: The modality associated with the preset.
    public static func getPreset(for preset: MedicalPreset) -> (name: String, center: Double, width: Double, modality: String) {
        let values = getPresetValuesV2(preset: preset)
        return (preset.displayName, values.center, values.width, preset.associatedModality)
    }
}
