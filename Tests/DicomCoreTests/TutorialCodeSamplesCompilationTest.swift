//
//  TutorialCodeSamplesCompilationTest.swift
//  DicomCoreTests
//
//  Test to verify all tutorial code samples compile without errors This test doesn't execute the
//  code (would need real DICOM files) but ensures all APIs used in tutorials exist and have correct
//  signatures.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore
import Foundation
import simd

/// Test to verify all tutorial code samples compile without errors
/// This test doesn't execute the code (would need real DICOM files) but ensures
/// all APIs used in tutorials exist and have correct signatures
final class TutorialCodeSamplesCompilationTest: XCTestCase {

    // MARK: - Basic Usage Tests

    func testBasicLoadingAPIsExist() throws {
        // Verify throwing initializers exist
        let tempURL = URL(fileURLWithPath: "/tmp/test.dcm")

        // These should compile (will throw at runtime without real file)
        _ = try? DCMDecoder(contentsOf: tempURL)
        _ = try? DCMDecoder(contentsOfFile: "/tmp/test.dcm")

        // Verify static factory methods exist
        _ = try? DCMDecoder.load(from: tempURL)
        _ = try? DCMDecoder.load(fromFile: "/tmp/test.dcm")
    }

    func testAsyncLoadingAPIsExist() async throws {
        let tempURL = URL(fileURLWithPath: "/tmp/test.dcm")

        // Verify async initializers exist
        _ = try? await DCMDecoder(contentsOf: tempURL)
        _ = try? await DCMDecoder(contentsOfFile: "/tmp/test.dcm")

        // Verify async static factory methods exist
        _ = try? await DCMDecoder.load(from: tempURL)
        _ = try? await DCMDecoder.load(fromFile: "/tmp/test.dcm")
    }

    func testDicomTagEnumAPIsExist() throws {
        let decoder = DCMDecoder()

        // Verify type-safe DicomTag enum works
        _ = decoder.info(for: .patientName)
        _ = decoder.info(for: .modality)
        _ = decoder.info(for: .studyDate)
        _ = decoder.info(for: .rows)
        _ = decoder.info(for: .columns)
        _ = decoder.info(for: .windowCenter)
        _ = decoder.info(for: .windowWidth)
        _ = decoder.intValue(for: .rows)
        _ = decoder.doubleValue(for: .windowCenter)
    }

    func testV2ValueTypesExist() throws {
        let decoder = DCMDecoder()

        // Verify V2 API structs exist
        let windowSettings = decoder.windowSettingsV2
        XCTAssertNotNil(windowSettings)
        _ = windowSettings.isValid
        _ = windowSettings.center
        _ = windowSettings.width

        let spacing = decoder.pixelSpacingV2
        XCTAssertNotNil(spacing)
        _ = spacing.isValid
        _ = spacing.x
        _ = spacing.y
        _ = spacing.z

        let rescale = decoder.rescaleParametersV2
        XCTAssertNotNil(rescale)
        _ = rescale.isIdentity
        _ = rescale.slope
        _ = rescale.intercept
        _ = rescale.apply(to: 100.0)
    }

    func testPixelDataAPIsExist() throws {
        let decoder = DCMDecoder()

        // Verify pixel data methods exist
        _ = decoder.getPixels16()
        _ = decoder.getPixels8()
        _ = decoder.width
        _ = decoder.height
        _ = decoder.bitDepth
    }

    // MARK: - Window/Level Tests

    func testWindowingProcessorAPIsExist() throws {
        let pixels16: [UInt16] = Array(repeating: 1000, count: 100)

        // Basic windowing
        let windowed = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: 50.0,
            width: 400.0
        )
        XCTAssertNotNil(windowed)

        // Processing modes
        _ = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: 50.0,
            width: 400.0,
            processingMode: .vdsp
        )

        _ = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: 50.0,
            width: 400.0,
            processingMode: .metal
        )

        _ = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: 50.0,
            width: 400.0,
            processingMode: .auto
        )
    }

    func testOptimalWindowCalculationAPIsExist() throws {
        let pixels16: [UInt16] = Array(repeating: 1000, count: 100)

        // V2 optimal calculation
        let optimal = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels16)
        XCTAssertNotNil(optimal)
        _ = optimal.isValid
        _ = optimal.center
        _ = optimal.width

        // Decoder convenience method
        let decoder = DCMDecoder()
        _ = decoder.calculateOptimalWindowV2()
    }

    func testMedicalPresetsAPIsExist() throws {
        // Verify preset enum values exist
        let presets: [MedicalPreset] = [
            .lung, .bone, .softTissue, .liver, .brain,
            .abdomen, .mediastinum, .spine, .pelvis,
            .angiography, .pulmonaryEmbolism, .mammography, .petScan
        ]

        for preset in presets {
            // V2 API
            let settings = DCMWindowingProcessor.getPresetValuesV2(preset: preset)
            XCTAssertNotNil(settings)
            _ = settings.center
            _ = settings.width

            // Display name
            _ = preset.displayName
        }

        // Preset collections
        _ = DCMWindowingProcessor.ctPresets
        _ = DCMWindowingProcessor.allPresets

        // Preset suggestions
        let suggestions = DCMWindowingProcessor.suggestPresets(for: "CT", bodyPart: "CHEST")
        XCTAssertNotNil(suggestions)

        // Preset lookup by name
        _ = DCMWindowingProcessor.getPresetValuesV2(named: "lung")

        // Preset matching
        let settings = WindowSettings(center: -600.0, width: 1500.0)
        _ = DCMWindowingProcessor.getPresetName(settings: settings)
        _ = DCMWindowingProcessor.getPresetName(settings: settings, tolerance: 50.0)
    }

    func testQualityMetricsAPIsExist() throws {
        let pixels16: [UInt16] = Array(repeating: 1000, count: 100)

        // Single image metrics
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels16)
        XCTAssertNotNil(metrics)
        _ = metrics["mean"]
        _ = metrics["std_deviation"]
        _ = metrics["min"]
        _ = metrics["max"]
        _ = metrics["snr"]
        _ = metrics["contrast"]

        // Multiple image metrics (no batch API, process individually)
        for pixels in [pixels16, pixels16] {
            let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels)
            XCTAssertNotNil(metrics["mean"])
        }
    }

    func testBatchProcessingAPIsExist() throws {
        let pixels16: [UInt16] = Array(repeating: 1000, count: 100)

        // Batch optimal window calculation
        let batchSettings = DCMWindowingProcessor.batchCalculateOptimalWindowLevelV2(
            imagePixels: [pixels16, pixels16]
        )
        XCTAssertFalse(batchSettings.isEmpty)
    }

    // MARK: - Series Loading Tests

    func testSeriesLoaderAPIsExist() throws {
        // Basic initialization
        let loader1 = DicomSeriesLoader()
        XCTAssertNotNil(loader1)

        // With decoder factory
        let loader2 = DicomSeriesLoader(decoderFactory: { _ in DCMDecoder() })
        XCTAssertNotNil(loader2)

        // Load method signatures (won't execute without real files)
        let tempURL = URL(fileURLWithPath: "/tmp/series")
        _ = try? loader1.loadSeries(in: tempURL)
        _ = try? loader1.loadSeries(in: tempURL) { _, _, _, _ in }
    }

    func testAsyncSeriesLoadingAPIsExist() async throws {
        let loader = DicomSeriesLoader()
        let tempURL = URL(fileURLWithPath: "/tmp/series")

        // Async loading
        _ = try? await loader.loadSeries(in: tempURL)
        _ = try? await loader.loadSeries(in: tempURL) { _, _, _, _ in }

        // Progress stream
        do {
            for try await progress in loader.loadSeriesWithProgress(in: tempURL) {
                _ = progress.fractionComplete
                _ = progress.slicesCopied
                _ = progress.volumeInfo
                break // Just verify it compiles
            }
        } catch {
            // Expected to fail without real files
        }
    }

    func testSeriesVolumeAPIsExist() throws {
        // Create a mock volume to test API surface
        // We can't create a real one without DICOM files, but we can verify
        // the DicomSeriesVolume type exists and has the expected properties

        // This test verifies the types and properties exist at compile time
        // The actual values will be tested when we have real DICOM files

        // Verify DicomSeriesVolume exists as a type
        let volumeType = DicomSeriesVolume.self
        XCTAssertNotNil(volumeType)

        // The properties will be tested in integration tests with real data
    }

    func testSeriesLoaderErrorsExist() throws {
        // Verify error types exist
        let _: DicomSeriesLoaderError = .noDicomFiles
        let _: DicomSeriesLoaderError = .inconsistentDimensions
        let _: DicomSeriesLoaderError = .unsupportedBitDepth(16)
    }

    // MARK: - Error Handling Tests

    func testDICOMErrorTypesExist() throws {
        // Verify DICOMError cases exist
        do {
            throw DICOMError.fileNotFound(path: "/tmp/test.dcm")
        } catch DICOMError.fileNotFound(let path) {
            XCTAssertEqual(path, "/tmp/test.dcm")
        } catch {
            XCTFail("Wrong error type")
        }

        do {
            throw DICOMError.invalidDICOMFormat(reason: "test reason")
        } catch DICOMError.invalidDICOMFormat(let reason) {
            XCTAssertEqual(reason, "test reason")
        } catch {
            XCTFail("Wrong error type")
        }
    }

    // MARK: - Codable Tests

    func testV2ValueTypesAreCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // WindowSettings
        let windowSettings = WindowSettings(center: 50.0, width: 400.0)
        let windowData = try encoder.encode(windowSettings)
        let decodedWindow = try decoder.decode(WindowSettings.self, from: windowData)
        XCTAssertEqual(windowSettings.center, decodedWindow.center)
        XCTAssertEqual(windowSettings.width, decodedWindow.width)

        // PixelSpacing
        let spacing = PixelSpacing(x: 1.0, y: 1.0, z: 2.0)
        let spacingData = try encoder.encode(spacing)
        let decodedSpacing = try decoder.decode(PixelSpacing.self, from: spacingData)
        XCTAssertEqual(spacing.x, decodedSpacing.x)
        XCTAssertEqual(spacing.y, decodedSpacing.y)
        XCTAssertEqual(spacing.z, decodedSpacing.z)

        // RescaleParameters
        let rescale = RescaleParameters(intercept: 0.0, slope: 1.0)
        let rescaleData = try encoder.encode(rescale)
        let decodedRescale = try decoder.decode(RescaleParameters.self, from: rescaleData)
        XCTAssertEqual(rescale.intercept, decodedRescale.intercept)
        XCTAssertEqual(rescale.slope, decodedRescale.slope)
    }

    // MARK: - Integration Workflow Test

    func testCompleteWorkflowAPIsExist() async throws {
        // This test verifies the complete workflow from tutorials compiles
        // It won't execute successfully without real DICOM files, but it
        // proves all the APIs exist and have correct signatures

        let tempURL = URL(fileURLWithPath: "/tmp/test.dcm")

        // Try to load (will fail but that's ok)
        guard let decoder = try? await DCMDecoder(contentsOf: tempURL) else {
            // Expected - no real file exists
            return
        }

        // If we somehow got a decoder, verify the workflow APIs
        _ = decoder.width
        _ = decoder.height
        _ = decoder.info(for: .modality)
        _ = decoder.info(for: .patientName)

        if let pixels = decoder.getPixels16() {
            let optimal = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels)
            _ = DCMWindowingProcessor.applyWindowLevel(
                pixels16: pixels,
                center: optimal.center,
                width: optimal.width
            )

            _ = DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels)
        }
    }
}
