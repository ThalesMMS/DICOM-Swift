//
//  BasicUsage.swift
//  DicomCore
//
//  Example 1: Load a DICOM file using the recommended throwing initializer.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import DicomCore
import Foundation

// MARK: - Basic DICOM Loading

/// Example 1: Load a DICOM file using the recommended throwing initializer
func loadDICOMFile() {
    do {
        // Recommended: Use throwing initializer with URL
        let url = URL(fileURLWithPath: "/path/to/image.dcm")
        let decoder = try DCMDecoder(contentsOf: url)

        // Access image properties immediately - no need to check success boolean
        print("Image dimensions: \(decoder.width) x \(decoder.height)")
        print("Bit depth: \(decoder.bitDepth)")

        // Recommended: Use type-safe DicomTag enum
        print("Modality: \(decoder.info(for: .modality))")
        print("Patient: \(decoder.info(for: .patientName))")

    } catch DICOMError.fileNotFound(let path) {
        print("File not found: \(path)")
    } catch DICOMError.invalidDICOMFormat(let reason) {
        print("Invalid DICOM file: \(reason)")
    } catch {
        print("Unexpected error: \(error)")
    }
}

/// Example 2: Load DICOM file from String path
func loadDICOMFromPath() {
    do {
        let decoder = try DCMDecoder(contentsOfFile: "/path/to/ct_scan.dcm")

        print("Successfully loaded: \(decoder.width) x \(decoder.height)")
        print("Modality: \(decoder.info(for: .modality))")

    } catch {
        print("Failed to load: \(error)")
    }
}

// MARK: - Async Loading

/// Example 3: Load DICOM file asynchronously (non-blocking)
func loadDICOMAsync() async {
    do {
        // Load asynchronously without blocking the main thread
        let url = URL(fileURLWithPath: "/path/to/image.dcm")
        let decoder = try await DCMDecoder(contentsOf: url)

        print("Loaded asynchronously: \(decoder.width) x \(decoder.height)")

        // Access pixel data
        if let pixels = decoder.getPixels16() {
            print("Pixel count: \(pixels.count)")
        }

    } catch DICOMError.fileNotFound(let path) {
        print("File not found: \(path)")
    } catch DICOMError.invalidDICOMFormat(let reason) {
        print("Invalid DICOM: \(reason)")
    } catch {
        print("Error: \(error)")
    }
}

// MARK: - Metadata Access

/// Example 4: Access DICOM metadata using type-safe tags
func accessMetadata() {
    do {
        let decoder = try DCMDecoder(contentsOfFile: "/path/to/ct_scan.dcm")

        // Patient information using type-safe tags
        print("=== Patient Information ===")
        print("Name: \(decoder.info(for: .patientName))")
        print("ID: \(decoder.info(for: .patientID))")
        print("Sex: \(decoder.info(for: .patientSex))")
        print("Age: \(decoder.info(for: .patientAge))")

        // Study information
        print("\n=== Study Information ===")
        print("Date: \(decoder.info(for: .studyDate))")
        print("Description: \(decoder.info(for: .studyDescription))")
        print("Modality: \(decoder.info(for: .modality))")

        // Image geometry with typed access
        print("\n=== Image Properties ===")
        if let rows = decoder.intValue(for: .rows),
           let cols = decoder.intValue(for: .columns) {
            print("Dimensions: \(cols) x \(rows)")
        }

        if let bits = decoder.intValue(for: .bitsAllocated) {
            print("Bit depth: \(bits)")
        }

        // Window/level settings using V2 API
        print("\n=== Display Settings ===")
        let windowSettings = decoder.windowSettingsV2
        if windowSettings.isValid {
            print("Window: C=\(windowSettings.center) W=\(windowSettings.width)")
        }

    } catch {
        print("Error loading DICOM: \(error)")
    }
}

// MARK: - Pixel Data and Windowing

/// Example 5: Read pixel data and apply window/level
func readPixelsAndApplyWindowing() {
    do {
        let decoder = try DCMDecoder(contentsOfFile: "/path/to/ct_scan.dcm")

        // Get 16-bit pixel data (most common for CT, MR)
        guard let pixels16 = decoder.getPixels16() else {
            print("No pixel data available")
            return
        }

        print("Loaded \(pixels16.count) 16-bit pixels")

        // Use embedded window settings
        let windowSettings = decoder.windowSettingsV2
        if windowSettings.isValid {
            let windowedData = DCMWindowingProcessor.applyWindowLevel(
                pixels16: pixels16,
                center: windowSettings.center,
                width: windowSettings.width
            )
            print("Applied window/level transformation")
        }

        // Or calculate optimal window
        let optimal = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels16)
        let optimizedData = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: optimal.center,
            width: optimal.width
        )
        print("Applied optimal window: C=\(optimal.center) W=\(optimal.width)")

    } catch {
        print("Error: \(error)")
    }
}

// MARK: - Medical Presets

/// Example 6: Use medical presets for CT visualization
func useMedicalPresets() {
    do {
        let decoder = try DCMDecoder(contentsOfFile: "/path/to/ct_scan.dcm")

        guard let pixels16 = decoder.getPixels16() else { return }

        // Get CT-specific presets using V2 API
        let lungSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)
        let boneSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .bone)
        let softTissueSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .softTissue)

        print("Lung preset: C=\(lungSettings.center) W=\(lungSettings.width)")
        print("Bone preset: C=\(boneSettings.center) W=\(boneSettings.width)")
        print("Soft Tissue preset: C=\(softTissueSettings.center) W=\(softTissueSettings.width)")

        // Apply lung preset for visualization
        let lungImage = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: lungSettings.center,
            width: lungSettings.width
        )

        // Get suggested presets based on modality and body part
        let modality = decoder.info(for: .modality)
        let bodyPart = decoder.info(for: .bodyPartExamined)
        let suggestions = DCMWindowingProcessor.suggestPresets(
            for: modality,
            bodyPart: bodyPart
        )

        print("\nSuggested presets for \(modality) \(bodyPart):")
        for preset in suggestions {
            print("  - \(preset.displayName)")
        }

    } catch {
        print("Error: \(error)")
    }
}

// MARK: - Type-Safe Value Types (V2 APIs)

/// Example 7: Use type-safe value types for better code safety
func useV2APIs() {
    do {
        let decoder = try DCMDecoder(contentsOfFile: "/path/to/ct_scan.dcm")

        // WindowSettings struct (V2 API)
        let windowSettings = decoder.windowSettingsV2
        if windowSettings.isValid {
            print("Window: center=\(windowSettings.center), width=\(windowSettings.width)")

            // Serialize to JSON
            let encoder = JSONEncoder()
            if let jsonData = try? encoder.encode(windowSettings) {
                print("JSON: \(String(data: jsonData, encoding: .utf8)!)")
            }
        }

        // PixelSpacing struct (V2 API)
        let spacing = decoder.pixelSpacingV2
        if spacing.isValid {
            print("Pixel spacing: \(spacing.x) × \(spacing.y) × \(spacing.z) mm")

            // Calculate physical dimensions
            let physicalWidth = Double(decoder.width) * spacing.x
            let physicalHeight = Double(decoder.height) * spacing.y
            print("Physical size: \(physicalWidth) × \(physicalHeight) mm")
        }

        // RescaleParameters struct (V2 API)
        let rescale = decoder.rescaleParametersV2
        if !rescale.isIdentity {
            print("Rescale: slope=\(rescale.slope), intercept=\(rescale.intercept)")

            // Apply rescale transformation
            let storedValue: Double = 1024.0
            let hounsfieldValue = rescale.apply(to: storedValue)
            print("HU value: \(hounsfieldValue)")
        }

    } catch {
        print("Error: \(error)")
    }
}

// MARK: - Complete Example

/// Example 8: Complete workflow from loading to display
func completeWorkflow() async {
    do {
        // Load DICOM file
        let url = URL(fileURLWithPath: "/path/to/ct_scan.dcm")
        let decoder = try await DCMDecoder(contentsOf: url)

        print("=== DICOM File Information ===")
        print("Dimensions: \(decoder.width) × \(decoder.height)")
        print("Modality: \(decoder.info(for: .modality))")
        print("Patient: \(decoder.info(for: .patientName))")

        // Get pixel data
        guard let pixels = decoder.getPixels16() else {
            print("No pixel data available")
            return
        }

        // Calculate optimal window
        let optimal = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels)
        print("\nOptimal window: C=\(optimal.center) W=\(optimal.width)")

        // Apply windowing for display
        let displayData = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels,
            center: optimal.center,
            width: optimal.width
        )

        print("Converted \(displayData?.count ?? 0) pixels to 8-bit display range")

        // Get quality metrics
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels)
        print("\n=== Quality Metrics ===")
        print("Mean: \(metrics["mean"] ?? 0)")
        print("Std Dev: \(metrics["std_deviation"] ?? 0)")
        print("Contrast: \(metrics["contrast"] ?? 0)")
        print("SNR: \(metrics["snr"] ?? 0)")

    } catch {
        print("Error: \(error)")
    }
}
