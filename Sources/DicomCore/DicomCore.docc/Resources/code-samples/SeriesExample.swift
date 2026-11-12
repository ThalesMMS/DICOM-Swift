//
//  SeriesExample.swift
//  DicomCore
//
//  Example 1: Load a DICOM series from a directory.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import DicomCore
import Foundation
import simd

// MARK: - Basic Series Loading

/// Example 1: Load a DICOM series from a directory
func loadBasicSeries() {
    do {
        // Create loader with default decoder factory
        let loader = DicomSeriesLoader()

        // Load series from directory
        let seriesDirectory = URL(fileURLWithPath: "/path/to/series")
        let volume = try loader.loadSeries(in: seriesDirectory)

        // Access volume dimensions
        print("Volume loaded:")
        print("  Dimensions: \(volume.width) × \(volume.height) × \(volume.depth)")
        print("  Description: \(volume.seriesDescription)")

    } catch DicomSeriesLoaderError.noDicomFiles {
        print("No DICOM files found in directory")
    } catch DicomSeriesLoaderError.inconsistentDimensions {
        print("Slices have inconsistent dimensions")
    } catch DicomSeriesLoaderError.unsupportedPixelFormat(let format) {
        print("Unsupported pixel format: \(format)")
    } catch DicomSeriesLoaderError.unsupportedTransferSyntaxForVolume(let format) {
        print("Unsupported transfer syntax for volume assembly: \(format.transferSyntaxUID)")
    } catch {
        print("Loading failed: \(error)")
    }
}

// MARK: - Progress Tracking

/// Example 2: Load series with progress tracking
func loadSeriesWithProgress() {
    do {
        let loader = DicomSeriesLoader()
        let seriesDirectory = URL(fileURLWithPath: "/path/to/series")

        // Load with progress handler
        let volume = try loader.loadSeries(in: seriesDirectory) { progress, sliceCount, currentSlice, url in
            // Update progress UI
            let percentage = Int(progress * 100)
            print("Loading: \(percentage)% - Slice \(currentSlice) of \(sliceCount)")

            // On main thread for UI updates:
            // DispatchQueue.main.async {
            //     progressView.progress = Float(progress)
            //     statusLabel.text = "Loading slice \(currentSlice) of \(sliceCount)"
            // }
        }

        print("Successfully loaded \(volume.depth) slices")

    } catch {
        print("Error: \(error)")
    }
}

// MARK: - Asynchronous Loading

/// Example 3: Load series asynchronously (non-blocking)
func loadSeriesAsync() async {
    do {
        let loader = DicomSeriesLoader()
        let seriesDirectory = URL(fileURLWithPath: "/path/to/series")

        // Load asynchronously without blocking
        let volume = try await loader.loadSeries(in: seriesDirectory) { progress, sliceCount, _, _ in
            print("Progress: \(Int(progress * 100))%")
        }

        print("Async load complete: \(volume.width) × \(volume.height) × \(volume.depth)")

    } catch {
        print("Async loading failed: \(error)")
    }
}

/// Example 4: Stream progress updates during loading
func loadSeriesWithProgressStream() async {
    do {
        let loader = DicomSeriesLoader()
        let seriesDirectory = URL(fileURLWithPath: "/path/to/series")

        // Use async progress stream
        for try await progress in loader.loadSeriesWithProgress(in: seriesDirectory) {
            let percentage = Int(progress.fractionComplete * 100)
            print("Progress: \(percentage)% - Loaded \(progress.slicesCopied) slices")

            // Update UI on main actor:
            // await MainActor.run {
            //     progressView.progress = Float(progress.fractionComplete)
            // }
        }

        print("Series loading complete")

    } catch {
        print("Error: \(error)")
    }
}

// MARK: - Volume Geometry

/// Example 5: Extract geometric metadata from volume
func analyzeVolumeGeometry() {
    do {
        let loader = DicomSeriesLoader()
        let seriesDirectory = URL(fileURLWithPath: "/path/to/series")
        let volume = try loader.loadSeries(in: seriesDirectory)

        // Pixel spacing in millimeters (X, Y, Z)
        print("=== Volume Geometry ===")
        print("Pixel spacing: \(volume.spacing.x) × \(volume.spacing.y) × \(volume.spacing.z) mm")

        // Orientation matrix (3×3)
        print("\nOrientation matrix:")
        print("  [\(volume.orientation[0].x), \(volume.orientation[0].y), \(volume.orientation[0].z)]")
        print("  [\(volume.orientation[1].x), \(volume.orientation[1].y), \(volume.orientation[1].z)]")
        print("  [\(volume.orientation[2].x), \(volume.orientation[2].y), \(volume.orientation[2].z)]")

        // Origin position in patient space
        print("\nOrigin: (\(volume.origin.x), \(volume.origin.y), \(volume.origin.z)) mm")

        // Calculate physical dimensions
        let physicalWidth = Double(volume.width) * volume.spacing.x
        let physicalHeight = Double(volume.height) * volume.spacing.y
        let physicalDepth = Double(volume.depth) * volume.spacing.z

        print("\n=== Physical Dimensions ===")
        print("Physical size: \(physicalWidth) × \(physicalHeight) × \(physicalDepth) mm")
        print("Volume: \(physicalWidth * physicalHeight * physicalDepth) mm³")

        // Rescale parameters for Hounsfield Units
        print("\n=== Rescale Parameters ===")
        print("Slope: \(volume.rescaleSlope)")
        print("Intercept: \(volume.rescaleIntercept)")

    } catch {
        print("Error: \(error)")
    }
}

// MARK: - Voxel Data Access

/// Example 6: Access and process raw voxel data
func processVoxelData() {
    do {
        let loader = DicomSeriesLoader()
        let seriesDirectory = URL(fileURLWithPath: "/path/to/series")
        let volume = try loader.loadSeries(in: seriesDirectory)

        // Access raw voxel buffer
        let voxelData = volume.voxels
        let totalVoxels = volume.width * volume.height * volume.depth
        print("Voxel buffer size: \(voxelData.count) bytes (\(totalVoxels) voxels)")

        // Convert to typed array
        voxelData.withUnsafeBytes { rawBuffer in
            guard let voxels = rawBuffer.baseAddress?.assumingMemoryBound(to: Int16.self) else {
                return
            }

            // Calculate statistics
            var sum: Int64 = 0
            var minValue = Int16.max
            var maxValue = Int16.min

            for i in 0..<totalVoxels {
                let value = voxels[i]
                sum += Int64(value)
                minValue = min(minValue, value)
                maxValue = max(maxValue, value)
            }

            let mean = Double(sum) / Double(totalVoxels)

            print("\n=== Volume Statistics ===")
            print("Mean: \(mean)")
            print("Min: \(minValue)")
            print("Max: \(maxValue)")

            // Apply rescale to convert to Hounsfield Units (for CT)
            let meanHU = mean * volume.rescaleSlope + volume.rescaleIntercept
            print("Mean HU: \(meanHU)")
        }

    } catch {
        print("Error: \(error)")
    }
}

// MARK: - Slice Processing

/// Example 7: Extract and process individual slices
func processIndividualSlice() {
    do {
        let loader = DicomSeriesLoader()
        let seriesDirectory = URL(fileURLWithPath: "/path/to/series")
        let volume = try loader.loadSeries(in: seriesDirectory)

        // Extract middle slice
        let sliceIndex = volume.depth / 2
        let sliceSize = volume.width * volume.height
        let sliceOffset = sliceIndex * sliceSize

        print("Processing slice \(sliceIndex) of \(volume.depth)")

        // Extract slice data
        var slicePixels: [Int16] = []
        volume.voxels.withUnsafeBytes { rawBuffer in
            guard let voxels = rawBuffer.baseAddress?.assumingMemoryBound(to: Int16.self) else {
                return
            }

            slicePixels = Array(UnsafeBufferPointer(start: voxels + sliceOffset, count: sliceSize))
        }

        print("Extracted \(slicePixels.count) pixels from slice")

        // Convert to UInt16 for windowing (assuming non-negative range or proper conversion)
        let pixels16 = slicePixels.map { UInt16(max(0, Int($0) + 32768)) }

        // Apply window/level using optimal calculation
        let optimalSettings = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels16)
        let displayPixels = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: optimalSettings.center,
            width: optimalSettings.width
        )

        print("Applied optimal window: C=\(optimalSettings.center) W=\(optimalSettings.width)")
        print("Created \(displayPixels.count) 8-bit display pixels")

    } catch {
        print("Error: \(error)")
    }
}

/// Example 8: Apply medical presets to slices
func applyPresetsToSlices() {
    do {
        let loader = DicomSeriesLoader()
        let seriesDirectory = URL(fileURLWithPath: "/path/to/ct_series")
        let volume = try loader.loadSeries(in: seriesDirectory)

        // Process each slice with different presets
        let presets: [MedicalPreset] = [.lung, .bone, .softTissue, .brain]

        for (index, preset) in presets.enumerated() {
            guard index < volume.depth else { break }

            // Extract slice
            let sliceSize = volume.width * volume.height
            let sliceOffset = index * sliceSize

            volume.voxels.withUnsafeBytes { rawBuffer in
                guard let voxels = rawBuffer.baseAddress?.assumingMemoryBound(to: Int16.self) else {
                    return
                }

                let slicePixels = Array(UnsafeBufferPointer(start: voxels + sliceOffset, count: sliceSize))
                let pixels16 = slicePixels.map { UInt16(max(0, Int($0) + 32768)) }

                // Get preset values
                let presetSettings = DCMWindowingProcessor.getPresetValuesV2(preset: preset)

                // Apply preset
                let displayPixels = DCMWindowingProcessor.applyWindowLevel(
                    pixels16: pixels16,
                    center: presetSettings.center,
                    width: presetSettings.width
                )

                print("Slice \(index) with \(preset.displayName): \(displayPixels.count) pixels")
            }
        }

    } catch {
        print("Error: \(error)")
    }
}

// MARK: - Dependency Injection

/// Example 9: Use custom decoder for testing or specialized loading
func loadSeriesWithCustomDecoder() {
    do {
        // Create loader with custom decoder factory
        // In tests, use MockDicomDecoder:
        // let loader = DicomSeriesLoader(decoderFactory: { _ in MockDicomDecoder() })

        // In production, use DCMDecoder (default):
        let loader = DicomSeriesLoader(decoderFactory: { _ in DCMDecoder() })

        let seriesDirectory = URL(fileURLWithPath: "/path/to/series")
        let volume = try loader.loadSeries(in: seriesDirectory)

        print("Loaded with custom decoder: \(volume.depth) slices")

    } catch {
        print("Error: \(error)")
    }
}

// MARK: - Complete Workflow

/// Example 10: Complete series processing workflow
func completeSeriesWorkflow() async {
    do {
        print("=== DICOM Series Processing Workflow ===\n")

        // 1. Create loader
        let loader = DicomSeriesLoader()
        let seriesDirectory = URL(fileURLWithPath: "/path/to/ct_series")

        // 2. Load series asynchronously with progress
        print("Loading series...")
        var volume: DicomSeriesVolume?

        for try await progress in loader.loadSeriesWithProgress(in: seriesDirectory) {
            print("  \(Int(progress.fractionComplete * 100))% - \(progress.slicesCopied) slices loaded")

            if progress.fractionComplete >= 1.0 {
                // Volume loading complete
                // Note: In actual implementation, the volume is returned from loadSeries
                // For this example, we'll load it after the progress loop
                break
            }
        }

        // Load the volume (in practice, this would be the result from loadSeries)
        volume = try await loader.loadSeries(in: seriesDirectory)
        guard let volume = volume else { return }

        // 3. Display geometry information
        print("\n=== Volume Information ===")
        print("Dimensions: \(volume.width) × \(volume.height) × \(volume.depth)")
        print("Spacing: \(volume.spacing.x) × \(volume.spacing.y) × \(volume.spacing.z) mm")
        print("Description: \(volume.seriesDescription)")

        let physicalSize = SIMD3<Double>(
            Double(volume.width) * volume.spacing.x,
            Double(volume.height) * volume.spacing.y,
            Double(volume.depth) * volume.spacing.z
        )
        print("Physical size: \(physicalSize.x) × \(physicalSize.y) × \(physicalSize.z) mm")

        // 4. Process middle slice
        print("\n=== Processing Middle Slice ===")
        let midSlice = volume.depth / 2
        let sliceSize = volume.width * volume.height
        let sliceOffset = midSlice * sliceSize

        var sliceData: [UInt16]?
        volume.voxels.withUnsafeBytes { rawBuffer in
            guard let voxels = rawBuffer.baseAddress?.assumingMemoryBound(to: Int16.self) else {
                return
            }

            let slice = Array(UnsafeBufferPointer(start: voxels + sliceOffset, count: sliceSize))
            sliceData = slice.map { UInt16(max(0, Int($0) + 32768)) }
        }

        guard let pixels16 = sliceData else { return }

        // 5. Calculate optimal window/level
        let optimal = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels16)
        print("Optimal window: C=\(optimal.center) W=\(optimal.width)")

        // 6. Get suggested presets
        let suggestions = DCMWindowingProcessor.suggestPresets(for: "CT", bodyPart: "CHEST")
        print("\nSuggested presets for CT CHEST:")
        for preset in suggestions {
            let settings = DCMWindowingProcessor.getPresetValuesV2(preset: preset)
            print("  \(preset.displayName): C=\(settings.center) W=\(settings.width)")
        }

        // 7. Apply lung preset and calculate metrics
        print("\n=== Applying Lung Preset ===")
        let lungSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)
        let displayPixels = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: lungSettings.center,
            width: lungSettings.width,
            processingMode: .auto  // Auto-select GPU/CPU based on image size
        )

        print("Windowed \(displayPixels.count) pixels for display")

        // 8. Calculate quality metrics
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels16)
        print("\n=== Quality Metrics ===")
        print("Mean: \(metrics["mean"] ?? 0)")
        print("Std Dev: \(metrics["std_deviation"] ?? 0)")
        print("SNR: \(metrics["snr"] ?? 0)")
        print("Contrast: \(metrics["contrast"] ?? 0)")

        print("\n✅ Series processing complete!")

    } catch DicomSeriesLoaderError.noDicomFiles {
        print("❌ No DICOM files found in directory")
    } catch DicomSeriesLoaderError.inconsistentDimensions {
        print("❌ Slices have inconsistent dimensions")
    } catch {
        print("❌ Error: \(error)")
    }
}
