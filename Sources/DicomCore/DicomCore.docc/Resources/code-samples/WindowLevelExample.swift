//
//  WindowLevelExample.swift
//  DicomCore
//
//  Example 1: Apply window/level using embedded DICOM settings.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import DicomCore
import Foundation

// MARK: - Basic Window/Level

/// Example 1: Apply window/level using embedded DICOM settings
func applyEmbeddedWindowLevel() {
    do {
        let decoder = try DCMDecoder(contentsOfFile: "/path/to/ct_scan.dcm")

        guard let pixels16 = decoder.getPixels16() else {
            print("No pixel data available")
            return
        }

        // Get embedded window settings using V2 API
        let settings = decoder.windowSettingsV2

        if settings.isValid {
            // Apply window/level transformation to convert 16-bit to 8-bit
            let pixels8bit = DCMWindowingProcessor.applyWindowLevel(
                pixels16: pixels16,
                center: settings.center,
                width: settings.width
            )

            print("Applied window/level: center=\(settings.center), width=\(settings.width)")
            print("Converted \(pixels8bit.count) pixels to 8-bit")
        } else {
            print("No valid window settings in DICOM file")
        }

    } catch {
        print("Error: \(error)")
    }
}

/// Example 2: Apply custom window/level values
func applyCustomWindowLevel() {
    do {
        let decoder = try DCMDecoder(contentsOfFile: "/path/to/brain.dcm")

        guard let pixels16 = decoder.getPixels16() else { return }

        // Apply custom window/level for brain tissue
        let brainWindowed = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: 40.0,  // Brain window center
            width: 80.0    // Brain window width
        )

        print("Applied custom brain window")

    } catch {
        print("Error: \(error)")
    }
}

// MARK: - Optimal Window Calculation

/// Example 3: Calculate optimal window/level from image statistics
func calculateOptimalWindow() {
    do {
        let decoder = try DCMDecoder(contentsOfFile: "/path/to/ct_scan.dcm")

        guard let pixels16 = decoder.getPixels16() else { return }

        // Calculate optimal window based on pixel distribution
        let optimal = DCMWindowingProcessor.calculateOptimalWindowLevelV2(
            pixels16: pixels16
        )

        if optimal.isValid {
            print("Optimal window: center=\(optimal.center), width=\(optimal.width)")

            // Apply the optimal settings
            let pixels8bit = DCMWindowingProcessor.applyWindowLevel(
                pixels16: pixels16,
                center: optimal.center,
                width: optimal.width
            )

            print("Applied optimal windowing to \(pixels8bit.count) pixels")
        }

    } catch {
        print("Error: \(error)")
    }
}

/// Example 4: Use decoder convenience method
func useDecoderConvenienceMethod() {
    do {
        let decoder = try DCMDecoder(contentsOfFile: "/path/to/image.dcm")

        guard let pixels16 = decoder.getPixels16() else { return }

        // Use decoder's convenience method
        if let optimal = decoder.calculateOptimalWindow() {
            let windowed = DCMWindowingProcessor.applyWindowLevel(
                pixels16: pixels16,
                center: optimal.center,
                width: optimal.width
            )

            print("Applied optimal window from decoder")
        }

    } catch {
        print("Error: \(error)")
    }
}

// MARK: - Medical Presets

/// Example 5: Apply medical imaging presets
func applyMedicalPresets() {
    do {
        let decoder = try DCMDecoder(contentsOfFile: "/path/to/chest_ct.dcm")

        guard let pixels16 = decoder.getPixels16() else { return }

        // Apply lung preset using V2 API
        let lungSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)
        let lungWindowed = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: lungSettings.center,   // -600
            width: lungSettings.width      // 1500
        )

        print("Applied lung preset")

        // Apply bone preset
        let boneSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .bone)
        let boneWindowed = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: boneSettings.center,   // 400
            width: boneSettings.width      // 1800
        )

        print("Applied bone preset")

    } catch {
        print("Error: \(error)")
    }
}

/// Example 6: Get all available CT presets
func exploreAllPresets() {
    // Get CT-specific presets
    let ctPresets = DCMWindowingProcessor.ctPresets

    print("=== CT Presets ===")
    for preset in ctPresets {
        let settings = DCMWindowingProcessor.getPresetValuesV2(preset: preset)
        print("\(preset.displayName):")
        print("  Center: \(settings.center)")
        print("  Width: \(settings.width)")
    }

    // Get all available presets
    let allPresets = DCMWindowingProcessor.allPresets
    print("\nTotal presets: \(allPresets.count)")
}

/// Example 7: Auto-suggest presets based on DICOM metadata
func autoSuggestPresets() {
    do {
        let decoder = try DCMDecoder(contentsOfFile: "/path/to/ct_scan.dcm")

        let modality = decoder.info(for: .modality)
        let bodyPart = decoder.info(for: .bodyPartExamined)

        let suggestions = DCMWindowingProcessor.suggestPresets(
            for: modality,
            bodyPart: bodyPart
        )

        print("Suggested presets for \(modality) of \(bodyPart):")
        for preset in suggestions {
            print("  - \(preset.displayName)")
        }

        // Apply the first suggestion if available
        if let firstPreset = suggestions.first {
            let settings = DCMWindowingProcessor.getPresetValuesV2(preset: firstPreset)

            if let pixels16 = decoder.getPixels16() {
                let windowed = DCMWindowingProcessor.applyWindowLevel(
                    pixels16: pixels16,
                    center: settings.center,
                    width: settings.width
                )
                print("Applied suggested preset: \(firstPreset.displayName)")
            }
        }

    } catch {
        print("Error: \(error)")
    }
}

/// Example 8: Lookup presets by name
func lookupPresetByName() {
    // Case-insensitive lookup
    if let lungSettings = DCMWindowingProcessor.getPresetValuesV2(named: "lung") {
        print("Lung preset: center=\(lungSettings.center), width=\(lungSettings.width)")
    }

    // Multi-word preset names
    if let tissueSettings = DCMWindowingProcessor.getPresetValuesV2(named: "soft tissue") {
        print("Soft tissue: center=\(tissueSettings.center), width=\(tissueSettings.width)")
    }

    // Handle invalid preset name
    if let invalid = DCMWindowingProcessor.getPresetValuesV2(named: "InvalidPreset") {
        print("Found preset")
    } else {
        print("Preset not found")
    }
}

// MARK: - GPU Acceleration

/// Example 9: Use GPU acceleration for large images
func useGPUAcceleration() {
    do {
        let decoder = try DCMDecoder(contentsOfFile: "/path/to/large_image.dcm")

        guard let pixels16 = decoder.getPixels16() else { return }

        // Explicitly use Metal GPU processing
        let gpuWindowed = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: 40.0,
            width: 400.0,
            processingMode: .metal  // Force GPU acceleration
        )

        print("Applied windowing with GPU acceleration")

    } catch {
        print("Error: \(error)")
    }
}

/// Example 10: Auto-select best processing mode
func autoSelectProcessingMode() {
    do {
        let decoder = try DCMDecoder(contentsOfFile: "/path/to/image.dcm")

        guard let pixels16 = decoder.getPixels16() else { return }

        // Auto mode: Uses Metal for images ≥800×800, vDSP for smaller
        let windowed = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: 50.0,
            width: 350.0,
            processingMode: .auto  // Automatic selection
        )

        print("Applied windowing with auto-selected processing mode")

    } catch {
        print("Error: \(error)")
    }
}

/// Example 11: Force CPU processing
func useCPUProcessing() {
    do {
        let decoder = try DCMDecoder(contentsOfFile: "/path/to/image.dcm")

        guard let pixels16 = decoder.getPixels16() else { return }

        // Use vDSP (CPU) processing
        let cpuWindowed = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: 40.0,
            width: 400.0,
            processingMode: .vdsp  // Force CPU processing
        )

        print("Applied windowing with CPU (vDSP)")

    } catch {
        print("Error: \(error)")
    }
}

// MARK: - Quality Metrics

/// Example 12: Calculate image quality metrics
func calculateQualityMetrics() {
    do {
        let decoder = try DCMDecoder(contentsOfFile: "/path/to/ct_scan.dcm")

        guard let pixels16 = decoder.getPixels16() else { return }

        // Calculate quality metrics for the image
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels16)

        print("=== Image Quality Metrics ===")
        print("Mean: \(metrics.mean)")
        print("Standard Deviation: \(metrics.standardDeviation)")
        print("Min: \(metrics.min)")
        print("Max: \(metrics.max)")
        print("SNR: \(metrics.snr)")
        print("Contrast: \(metrics.contrast)")

    } catch {
        print("Error: \(error)")
    }
}

/// Example 13: Calculate metrics for multiple images
func batchQualityMetrics() {
    do {
        let paths = [
            "/path/to/image1.dcm",
            "/path/to/image2.dcm",
            "/path/to/image3.dcm"
        ]

        for (index, path) in paths.enumerated() {
            let decoder = try DCMDecoder(contentsOfFile: path)

            if let pixels = decoder.getPixels16() {
                let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels)
                print("Image \(index + 1): SNR=\(metrics["snr"] ?? 0), Contrast=\(metrics["contrast"] ?? 0)")
            }
        }

    } catch {
        print("Error: \(error)")
    }
}

// MARK: - Batch Processing

/// Example 14: Batch calculate optimal window/level
func batchCalculateOptimalWindow() {
    do {
        let paths = [
            "/path/to/slice1.dcm",
            "/path/to/slice2.dcm",
            "/path/to/slice3.dcm"
        ]

        var imagePixels: [[UInt16]] = []

        for path in paths {
            let decoder = try DCMDecoder(contentsOfFile: path)
            if let pixels = decoder.getPixels16() {
                imagePixels.append(pixels)
            }
        }

        // Calculate optimal window for all images
        let batchSettings = DCMWindowingProcessor.batchCalculateOptimalWindowLevelV2(
            imagePixels: imagePixels
        )

        // Apply windowing to each image
        for (index, settings) in batchSettings.enumerated() {
            if settings.isValid {
                let windowed = DCMWindowingProcessor.applyWindowLevel(
                    pixels16: imagePixels[index],
                    center: settings.center,
                    width: settings.width
                )
                print("Image \(index + 1): center=\(settings.center), width=\(settings.width)")
            }
        }

    } catch {
        print("Error: \(error)")
    }
}

// MARK: - Preset Matching

/// Example 15: Identify matching presets
func identifyMatchingPreset() {
    do {
        let decoder = try DCMDecoder(contentsOfFile: "/path/to/ct_scan.dcm")

        // Get embedded window settings
        let settings = decoder.windowSettingsV2

        if settings.isValid {
            // Check if settings match a known preset
            if let presetName = DCMWindowingProcessor.getPresetName(
                settings: settings,
                tolerance: 50.0
            ) {
                print("Window settings match preset: \(presetName)")
            } else {
                print("Custom window settings (no preset match)")
            }
        }

    } catch {
        print("Error: \(error)")
    }
}

/// Example 16: Strict preset matching
func strictPresetMatching() {
    // Create custom window settings
    let settings = WindowSettings(center: -600.0, width: 1500.0)

    // Check with default tolerance (50.0)
    if let match = DCMWindowingProcessor.getPresetName(settings: settings) {
        print("Matches preset: \(match)")  // "Lung"
    }

    // Check with strict tolerance
    let nearSettings = WindowSettings(center: -595.0, width: 1510.0)
    if let strictMatch = DCMWindowingProcessor.getPresetName(
        settings: nearSettings,
        tolerance: 10.0
    ) {
        print("Strict match: \(strictMatch)")
    } else {
        print("No match with strict tolerance")
    }
}

// MARK: - Complete Workflow

/// Example 17: Complete window/level workflow
func completeWindowLevelWorkflow() async {
    do {
        // 1. Load DICOM file asynchronously
        let decoder = try await DCMDecoder(contentsOfFile: "/path/to/ct_chest.dcm")

        print("=== DICOM Image Loaded ===")
        print("Dimensions: \(decoder.width) × \(decoder.height)")
        print("Modality: \(decoder.info(for: .modality))")

        guard let pixels16 = decoder.getPixels16() else {
            print("No pixel data")
            return
        }

        // 2. Calculate quality metrics
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels16)
        print("\n=== Quality Metrics ===")
        print("SNR: \(metrics.snr)")
        print("Contrast: \(metrics.contrast)")

        // 3. Get suggested presets
        let suggestions = DCMWindowingProcessor.suggestPresets(
            for: decoder.info(for: .modality),
            bodyPart: decoder.info(for: .bodyPartExamined)
        )

        print("\n=== Suggested Presets ===")
        for preset in suggestions {
            print("  - \(preset.displayName)")
        }

        // 4. Apply optimal windowing with GPU acceleration
        let optimal = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels16)
        let windowed = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: optimal.center,
            width: optimal.width,
            processingMode: .auto
        )

        print("\n=== Windowing Applied ===")
        print("Center: \(optimal.center), Width: \(optimal.width)")
        print("Converted to \(windowed.count) 8-bit pixels")

        // 5. Check if optimal matches a preset
        if let presetName = DCMWindowingProcessor.getPresetName(settings: optimal) {
            print("Optimal settings match preset: \(presetName)")
        }

    } catch {
        print("Error: \(error)")
    }
}
