import XCTest
import CoreGraphics
import DicomTestSupport
@testable import DicomSwiftUI
@testable import DicomCore

#if canImport(SwiftUI)
import SwiftUI
#endif

final class DicomImageRendererTests: XCTestCase {

    // MARK: - Test Helpers

    private final class MockDicomDecoder: DicomImageRendererDecoderProtocol, @unchecked Sendable {
        let width: Int
        let height: Int
        let windowSettingsV2: WindowSettings
        private let pixels16: [UInt16]?

        init(
            width: Int,
            height: Int,
            pixels16: [UInt16]?,
            windowSettings: WindowSettings
        ) {
            self.width = width
            self.height = height
            self.pixels16 = pixels16
            self.windowSettingsV2 = windowSettings
        }

        func getPixels16() -> [UInt16]? {
            pixels16
        }
    }

    private func makeMockDecoder(
        width: Int = 64,
        height: Int = 64,
        windowSettings: WindowSettings = WindowSettings(center: 50, width: 400),
        pixels16: [UInt16]? = nil
    ) -> MockDicomDecoder {
        let defaultPixels = (0..<(width * height)).map { UInt16($0 % 4096) }
        return MockDicomDecoder(
            width: width,
            height: height,
            pixels16: pixels16 ?? defaultPixels,
            windowSettings: windowSettings
        )
    }

    // MARK: - Synchronous Rendering Unit Tests

    func testRenderFromURLWithAutomaticWindowing() throws {
        let decoder = makeMockDecoder()

        let cgImage = try DicomImageRenderer.render(
            decoder: decoder,
            windowingMode: .automatic
        )

        XCTAssertNotNil(cgImage, "Should render CGImage with automatic windowing")
        XCTAssertGreaterThan(cgImage.width, 0, "Image width should be positive")
        XCTAssertGreaterThan(cgImage.height, 0, "Image height should be positive")
        XCTAssertEqual(cgImage.bitsPerComponent, 8, "Should use 8 bits per component")
    }

    func testRenderFromURLWithCustomWindowing() throws {
        let decoder = makeMockDecoder()

        let cgImage = try DicomImageRenderer.render(
            decoder: decoder,
            windowingMode: .custom(center: 50.0, width: 400.0)
        )

        XCTAssertNotNil(cgImage, "Should render CGImage with custom windowing")
        XCTAssertGreaterThan(cgImage.width, 0, "Image width should be positive")
        XCTAssertGreaterThan(cgImage.height, 0, "Image height should be positive")
    }

    func testRenderFromURLWithPresetWindowing() throws {
        let decoder = makeMockDecoder()

        let cgImage = try DicomImageRenderer.render(
            decoder: decoder,
            windowingMode: .preset(.lung)
        )

        XCTAssertNotNil(cgImage, "Should render CGImage with preset windowing")
        XCTAssertGreaterThan(cgImage.width, 0, "Image width should be positive")
        XCTAssertGreaterThan(cgImage.height, 0, "Image height should be positive")
    }

    func testRenderFromURLWithFromDecoderWindowing() throws {
        let decoder = makeMockDecoder(windowSettings: WindowSettings(center: 65, width: 380))

        let cgImage = try DicomImageRenderer.render(
            decoder: decoder,
            windowingMode: .fromDecoder
        )

        XCTAssertNotNil(cgImage, "Should render CGImage with decoder windowing")
        XCTAssertGreaterThan(cgImage.width, 0, "Image width should be positive")
        XCTAssertGreaterThan(cgImage.height, 0, "Image height should be positive")
    }

    func testRenderFromURLWithVDSPProcessing() throws {
        let decoder = makeMockDecoder()

        let cgImage = try DicomImageRenderer.render(
            decoder: decoder,
            windowingMode: .automatic,
            processingMode: .vdsp
        )

        XCTAssertNotNil(cgImage, "Should render CGImage with vDSP processing")
        XCTAssertGreaterThan(cgImage.width, 0, "Image width should be positive")
        XCTAssertGreaterThan(cgImage.height, 0, "Image height should be positive")
    }

    func testRenderFromURLWithMetalProcessing() throws {
        let decoder = makeMockDecoder()

        let cgImage = try DicomImageRenderer.render(
            decoder: decoder,
            windowingMode: .automatic,
            processingMode: .metal
        )

        XCTAssertNotNil(cgImage, "Should render CGImage with Metal processing")
        XCTAssertGreaterThan(cgImage.width, 0, "Image width should be positive")
        XCTAssertGreaterThan(cgImage.height, 0, "Image height should be positive")
    }

    func testRenderFromURLWithAutoProcessing() throws {
        let decoder = makeMockDecoder()

        let cgImage = try DicomImageRenderer.render(
            decoder: decoder,
            windowingMode: .automatic,
            processingMode: .auto
        )

        XCTAssertNotNil(cgImage, "Should render CGImage with auto processing mode")
        XCTAssertGreaterThan(cgImage.width, 0, "Image width should be positive")
        XCTAssertGreaterThan(cgImage.height, 0, "Image height should be positive")
    }

    // MARK: - Synchronous Rendering from Decoder Tests

    func testRenderFromDecoderWithAutomaticWindowing() throws {
        let decoder = makeMockDecoder()

        let cgImage = try DicomImageRenderer.render(
            decoder: decoder,
            windowingMode: .automatic
        )

        XCTAssertNotNil(cgImage, "Should render CGImage from decoder")
        XCTAssertEqual(cgImage.width, decoder.width, "Image width should match decoder")
        XCTAssertEqual(cgImage.height, decoder.height, "Image height should match decoder")
    }

    func testRenderFromDecoderWithCustomWindowing() throws {
        let decoder = makeMockDecoder()

        let cgImage = try DicomImageRenderer.render(
            decoder: decoder,
            windowingMode: .custom(center: 0.0, width: 256.0)
        )

        XCTAssertNotNil(cgImage, "Should render CGImage with custom windowing")
        XCTAssertEqual(cgImage.width, decoder.width, "Image width should match decoder")
        XCTAssertEqual(cgImage.height, decoder.height, "Image height should match decoder")
    }

    func testRenderFromDecoderWithPreset() throws {
        let decoder = makeMockDecoder()

        // Test multiple presets
        let presets: [MedicalPreset] = [.lung, .bone, .brain, .liver, .abdomen]

        for preset in presets {
            let cgImage = try DicomImageRenderer.render(
                decoder: decoder,
                windowingMode: .preset(preset)
            )

            XCTAssertNotNil(cgImage, "Should render CGImage with preset \(preset)")
            XCTAssertEqual(cgImage.width, decoder.width, "Width should match for preset \(preset)")
            XCTAssertEqual(cgImage.height, decoder.height, "Height should match for preset \(preset)")
        }
    }

    func testRenderFromDecoderWithFromDecoderWindowing() throws {
        let decoder = makeMockDecoder(windowSettings: WindowSettings(center: 35, width: 275))

        let cgImage = try DicomImageRenderer.render(
            decoder: decoder,
            windowingMode: .fromDecoder
        )

        XCTAssertNotNil(cgImage, "Should render CGImage using decoder's window values")
        XCTAssertEqual(cgImage.width, decoder.width, "Image width should match decoder")
        XCTAssertEqual(cgImage.height, decoder.height, "Image height should match decoder")
    }

    func testRenderMultipleTimesFromSameDecoder() throws {
        let decoder = makeMockDecoder()

        // Render with different windowing modes
        let autoImage = try DicomImageRenderer.render(
            decoder: decoder,
            windowingMode: .automatic
        )

        let lungImage = try DicomImageRenderer.render(
            decoder: decoder,
            windowingMode: .preset(.lung)
        )

        let customImage = try DicomImageRenderer.render(
            decoder: decoder,
            windowingMode: .custom(center: 100.0, width: 200.0)
        )

        // All should succeed with same dimensions
        XCTAssertEqual(autoImage.width, decoder.width, "Auto image width should match")
        XCTAssertEqual(lungImage.width, decoder.width, "Lung image width should match")
        XCTAssertEqual(customImage.width, decoder.width, "Custom image width should match")

        XCTAssertEqual(autoImage.height, decoder.height, "Auto image height should match")
        XCTAssertEqual(lungImage.height, decoder.height, "Lung image height should match")
        XCTAssertEqual(customImage.height, decoder.height, "Custom image height should match")
    }

    // MARK: - Asynchronous Rendering Tests

    func testRenderAsyncFromURL() async throws {
        let decoder = makeMockDecoder()

        let cgImage = try await DicomImageRenderer.renderAsync(
            decoder: decoder,
            windowingMode: .automatic
        )

        XCTAssertNotNil(cgImage, "Should render CGImage asynchronously")
        XCTAssertGreaterThan(cgImage.width, 0, "Image width should be positive")
        XCTAssertGreaterThan(cgImage.height, 0, "Image height should be positive")
    }

    func testRenderAsyncFromDecoder() async throws {
        let decoder = makeMockDecoder()

        let cgImage = try await DicomImageRenderer.renderAsync(
            decoder: decoder,
            windowingMode: .preset(.bone)
        )

        XCTAssertNotNil(cgImage, "Should render CGImage asynchronously from decoder")
        XCTAssertEqual(cgImage.width, decoder.width, "Image width should match decoder")
        XCTAssertEqual(cgImage.height, decoder.height, "Image height should match decoder")
    }

    func testRenderAsyncMultipleConcurrently() async throws {
        let decoder = makeMockDecoder()

        // Render multiple windowing modes concurrently
        async let autoImage = DicomImageRenderer.renderAsync(
            decoder: decoder,
            windowingMode: .automatic
        )
        async let lungImage = DicomImageRenderer.renderAsync(
            decoder: decoder,
            windowingMode: .preset(.lung)
        )
        async let boneImage = DicomImageRenderer.renderAsync(
            decoder: decoder,
            windowingMode: .preset(.bone)
        )

        let images = try await [autoImage, lungImage, boneImage]

        XCTAssertEqual(images.count, 3, "Should render 3 images")
        for cgImage in images {
            XCTAssertEqual(cgImage.width, decoder.width, "Width should match decoder")
            XCTAssertEqual(cgImage.height, decoder.height, "Height should match decoder")
        }
    }

    // MARK: - Error Handling Tests

    func testRenderFromNonExistentFile() {
        let nonExistentURL = URL(fileURLWithPath: "/nonexistent/file.dcm")

        XCTAssertThrowsError(try DicomImageRenderer.render(
            contentsOf: nonExistentURL,
            windowingMode: .automatic
        )) { error in
            guard let dicomError = error as? DICOMError else {
                XCTFail("Error should be DICOMError")
                return
            }

            if case .fileNotFound = dicomError {
                // Expected error type
            } else {
                XCTFail("Error should be fileNotFound, got \(dicomError)")
            }
        }
    }

    func testRenderAsyncFromNonExistentFile() async {
        let nonExistentURL = URL(fileURLWithPath: "/nonexistent/file.dcm")

        do {
            _ = try await DicomImageRenderer.renderAsync(
                contentsOf: nonExistentURL,
                windowingMode: .automatic
            )
            XCTFail("Should throw error for non-existent file")
        } catch let error as DICOMError {
            if case .fileNotFound = error {
                // Expected error type
            } else {
                XCTFail("Error should be fileNotFound, got \(error)")
            }
        } catch {
            XCTFail("Error should be DICOMError, got \(error)")
        }
    }

    // MARK: - WindowingMode Tests

    func testWindowingModeEquality() {
        // Test that different modes can be created
        let preset = DicomImageRenderer.WindowingMode.preset(.lung)
        let custom = DicomImageRenderer.WindowingMode.custom(center: 50, width: 400)
        let fromDecoder = DicomImageRenderer.WindowingMode.fromDecoder
        let automatic = DicomImageRenderer.WindowingMode.automatic

        // Verify they are different types (no compilation errors)
        XCTAssertNotNil(preset, "Preset mode should be created")
        XCTAssertNotNil(custom, "Custom mode should be created")
        XCTAssertNotNil(fromDecoder, "FromDecoder mode should be created")
        XCTAssertNotNil(automatic, "Automatic mode should be created")
    }

    func testWindowingModePresetValues() throws {
        let decoder = makeMockDecoder()

        // Test that all preset values work
        let allPresets: [MedicalPreset] = [
            .lung, .bone, .brain, .liver, .mediastinum, .abdomen,
            .spine, .pelvis, .angiography, .pulmonaryEmbolism,
            .mammography, .petScan
        ]

        for preset in allPresets {
            let cgImage = try DicomImageRenderer.render(
                decoder: decoder,
                windowingMode: .preset(preset)
            )

            XCTAssertNotNil(cgImage, "Preset \(preset) should produce valid image")
        }
    }

    func testCustomWindowingWithValidValues() throws {
        let decoder = makeMockDecoder()

        // Test various valid custom windowing values
        let testCases: [(center: Double, width: Double)] = [
            (0, 256),
            (128, 256),
            (50, 400),
            (-1000, 2000),
            (1000, 500)
        ]

        for (center, width) in testCases {
            let cgImage = try DicomImageRenderer.render(
                decoder: decoder,
                windowingMode: .custom(center: center, width: width)
            )

            XCTAssertNotNil(cgImage, "Custom windowing (center: \(center), width: \(width)) should succeed")
        }
    }

    func testCustomWindowingWithInvalidWidth() throws {
        let decoder = makeMockDecoder()

        // Test that zero or negative width throws error
        XCTAssertThrowsError(try DicomImageRenderer.render(
            decoder: decoder,
            windowingMode: .custom(center: 50, width: 0)
        )) { error in
            guard let dicomError = error as? DICOMError else {
                XCTFail("Error should be DICOMError")
                return
            }

            if case .invalidWindowLevel = dicomError {
                // Expected error type
            } else {
                XCTFail("Error should be invalidWindowLevel, got \(dicomError)")
            }
        }
    }

    // MARK: - SwiftUI Extension Integration Tests

    #if canImport(SwiftUI)
    // Compatibility coverage: the synchronous Image(dicomURL:) initializer
    // is deprecated but intentionally remains available (issue #1221).
    @available(*, deprecated)
    func testSwiftUIImageExtensionWithValidURL() throws {
        let fileURL = try getAnyDICOMFile()

        let image = Image(
            dicomURL: fileURL,
            windowingMode: .automatic
        )

        XCTAssertNotNil(image, "Should create SwiftUI Image from DICOM URL")
    }

    // Compatibility coverage: the synchronous Image(dicomURL:) initializer
    // is deprecated but intentionally remains available (issue #1221).
    @available(*, deprecated)
    func testSwiftUIImageExtensionWithPreset() throws {
        let fileURL = try getAnyDICOMFile()

        let image = Image(
            dicomURL: fileURL,
            windowingMode: .preset(.lung)
        )

        XCTAssertNotNil(image, "Should create SwiftUI Image with preset windowing")
    }

    // Compatibility coverage: the synchronous Image(dicomURL:) initializer
    // is deprecated but intentionally remains available (issue #1221).
    @available(*, deprecated)
    func testSwiftUIImageExtensionWithCustomWindowing() throws {
        let fileURL = try getAnyDICOMFile()

        let image = Image(
            dicomURL: fileURL,
            windowingMode: .custom(center: 50, width: 400)
        )

        XCTAssertNotNil(image, "Should create SwiftUI Image with custom windowing")
    }

    // Compatibility coverage: the synchronous Image(dicomURL:) initializer
    // is deprecated but intentionally remains available (issue #1221).
    @available(*, deprecated)
    func testSwiftUIImageExtensionWithNonExistentURL() {
        let nonExistentURL = URL(fileURLWithPath: "/nonexistent/file.dcm")

        let image = Image(
            dicomURL: nonExistentURL,
            windowingMode: .automatic
        )

        XCTAssertNil(image, "Should return nil for non-existent file")
    }

    // Compatibility coverage: the synchronous Image(dicomURL:) initializer
    // is deprecated but intentionally remains available (issue #1221).
    @available(*, deprecated)
    func testSwiftUIImageExtensionWithMetalProcessing() throws {
        let fileURL = try getAnyDICOMFile()

        let image = Image(
            dicomURL: fileURL,
            windowingMode: .automatic,
            processingMode: .metal
        )

        XCTAssertNotNil(image, "Should create SwiftUI Image with Metal processing")
    }
    #endif

    // MARK: - Integration Fixture Helpers

    /// Path to DicomCore test fixtures used only by integration tests.
    private func getFixturesPath() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DicomCoreTests")
            .appendingPathComponent("Fixtures")
    }

    /// Finds any fixture DICOM file containing 16-bit pixels for integration tests.
    private func getAnyDICOMFile() throws -> URL {
        try DicomTestRuntimePreflight.require(.bundledSyntheticFixtures)
        let fixturesPath = getFixturesPath()

        guard FileManager.default.fileExists(atPath: fixturesPath.path) else {
            throw DicomRuntimeRequirementError(status: DicomRuntimeStatus(
                capability: .bundledSyntheticFixtures,
                kind: .regression,
                message: "Fixtures directory not found: \(fixturesPath.path)."
            ))
        }

        let enumerator = FileManager.default.enumerator(at: fixturesPath, includingPropertiesForKeys: nil)

        while let fileURL = enumerator?.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            if ext == "dcm" || ext == "dicom" {
                do {
                    let decoder = try DCMDecoder(contentsOf: fileURL)
                    if decoder.getPixels16() != nil {
                        return fileURL
                    }
                } catch {
                    continue
                }
            }
        }

        throw DicomRuntimeRequirementError(status: DicomRuntimeStatus(
            capability: .bundledSyntheticFixtures,
            kind: .regression,
            message: "No bundled DICOM fixture contains 16-bit pixel data."
        ))
    }

    // MARK: - Integration Tests

    func testRenderSameFileWithAllWindowingModes() throws {
        let fileURL = try getAnyDICOMFile()

        // Render with all windowing modes
        let automaticImage = try DicomImageRenderer.render(
            contentsOf: fileURL,
            windowingMode: .automatic
        )

        let fromDecoderImage = try DicomImageRenderer.render(
            contentsOf: fileURL,
            windowingMode: .fromDecoder
        )

        let customImage = try DicomImageRenderer.render(
            contentsOf: fileURL,
            windowingMode: .custom(center: 50, width: 400)
        )

        let lungImage = try DicomImageRenderer.render(
            contentsOf: fileURL,
            windowingMode: .preset(.lung)
        )

        // All should have same dimensions
        XCTAssertEqual(automaticImage.width, fromDecoderImage.width, "Width should match across modes")
        XCTAssertEqual(automaticImage.width, customImage.width, "Width should match across modes")
        XCTAssertEqual(automaticImage.width, lungImage.width, "Width should match across modes")

        XCTAssertEqual(automaticImage.height, fromDecoderImage.height, "Height should match across modes")
        XCTAssertEqual(automaticImage.height, customImage.height, "Height should match across modes")
        XCTAssertEqual(automaticImage.height, lungImage.height, "Height should match across modes")
    }

    func testRenderSameFileWithAllProcessingModes() throws {
        let fileURL = try getAnyDICOMFile()

        // Render with all processing modes
        let vdspImage = try DicomImageRenderer.render(
            contentsOf: fileURL,
            windowingMode: .automatic,
            processingMode: .vdsp
        )

        let metalImage = try DicomImageRenderer.render(
            contentsOf: fileURL,
            windowingMode: .automatic,
            processingMode: .metal
        )

        let autoImage = try DicomImageRenderer.render(
            contentsOf: fileURL,
            windowingMode: .automatic,
            processingMode: .auto
        )

        // All should produce valid images with same dimensions
        XCTAssertEqual(vdspImage.width, metalImage.width, "Width should match across processing modes")
        XCTAssertEqual(vdspImage.width, autoImage.width, "Width should match across processing modes")

        XCTAssertEqual(vdspImage.height, metalImage.height, "Height should match across processing modes")
        XCTAssertEqual(vdspImage.height, autoImage.height, "Height should match across processing modes")
    }

    func testRenderMultipleFilesSequentially() throws {
        let fileURL = try getAnyDICOMFile()

        // Render same file multiple times sequentially
        for i in 1...5 {
            let cgImage = try DicomImageRenderer.render(
                contentsOf: fileURL,
                windowingMode: .automatic
            )

            XCTAssertNotNil(cgImage, "Should render successfully on iteration \(i)")
            XCTAssertGreaterThan(cgImage.width, 0, "Width should be positive on iteration \(i)")
            XCTAssertGreaterThan(cgImage.height, 0, "Height should be positive on iteration \(i)")
        }
    }

    func testAsyncRenderWithDifferentWindowingCombinations() async throws {
        let fileURL = try getAnyDICOMFile()
        let decoder = try await DCMDecoder(contentsOf: fileURL)

        // Test combinations of windowing and processing modes asynchronously
        let combinations: [(windowing: DicomImageRenderer.WindowingMode, processing: ProcessingMode)] = [
            (.automatic, .vdsp),
            (.automatic, .metal),
            (.automatic, .auto),
            (.preset(.lung), .vdsp),
            (.preset(.bone), .metal),
            (.custom(center: 0, width: 256), .auto),
            (.fromDecoder, .vdsp)
        ]

        for (windowingMode, processingMode) in combinations {
            let cgImage = try await DicomImageRenderer.renderAsync(
                decoder: decoder,
                windowingMode: windowingMode,
                processingMode: processingMode
            )

            XCTAssertNotNil(cgImage, "Should render with windowing=\(windowingMode) processing=\(processingMode)")
            XCTAssertEqual(cgImage.width, decoder.width, "Width should match decoder")
            XCTAssertEqual(cgImage.height, decoder.height, "Height should match decoder")
        }
    }

    func testRenderWithAllMedicalPresets() throws {
        let fileURL = try getAnyDICOMFile()
        let decoder = try DCMDecoder(contentsOf: fileURL)

        // Test all available medical presets
        let allPresets: [MedicalPreset] = [
            .lung, .bone, .brain, .liver, .mediastinum, .abdomen,
            .spine, .pelvis, .softTissue, .angiography,
            .pulmonaryEmbolism, .mammography, .petScan
        ]

        for preset in allPresets {
            let cgImage = try DicomImageRenderer.render(
                decoder: decoder,
                windowingMode: .preset(preset)
            )

            XCTAssertNotNil(cgImage, "Should render with \(preset) preset")
            XCTAssertEqual(cgImage.width, decoder.width, "Width should match for \(preset)")
            XCTAssertEqual(cgImage.height, decoder.height, "Height should match for \(preset)")
            XCTAssertEqual(cgImage.bitsPerComponent, 8, "Should use 8 bits per component for \(preset)")
        }
    }

    func testSyncAndAsyncRendersProduceSameDimensions() async throws {
        let fileURL = try getAnyDICOMFile()

        // Render synchronously
        let syncImage = try DicomImageRenderer.render(
            contentsOf: fileURL,
            windowingMode: .automatic
        )

        // Render asynchronously
        let asyncImage = try await DicomImageRenderer.renderAsync(
            contentsOf: fileURL,
            windowingMode: .automatic
        )

        // Both should produce images with same dimensions
        XCTAssertEqual(syncImage.width, asyncImage.width, "Sync and async renders should have same width")
        XCTAssertEqual(syncImage.height, asyncImage.height, "Sync and async renders should have same height")
        XCTAssertEqual(syncImage.bitsPerComponent, asyncImage.bitsPerComponent,
                      "Sync and async renders should have same bits per component")
    }

    func testCustomWindowingWithExtremeValues() throws {
        let fileURL = try getAnyDICOMFile()
        let decoder = try DCMDecoder(contentsOf: fileURL)

        // Test extreme but valid custom windowing values
        let extremeCases: [(center: Double, width: Double)] = [
            (-3000, 6000),  // Very negative center, wide width
            (3000, 6000),   // Very positive center, wide width
            (0, 10000),     // Zero center, very wide width
            (500, 1),       // Narrow width
            (-1000, 100)    // Negative center, normal width
        ]

        for (center, width) in extremeCases {
            let cgImage = try DicomImageRenderer.render(
                decoder: decoder,
                windowingMode: .custom(center: center, width: width)
            )

            XCTAssertNotNil(cgImage, "Should handle extreme custom windowing (center: \(center), width: \(width))")
            XCTAssertEqual(cgImage.width, decoder.width, "Width should match decoder")
            XCTAssertEqual(cgImage.height, decoder.height, "Height should match decoder")
        }
    }

    func testRenderFromDecoderPreservesDecoderState() throws {
        let fileURL = try getAnyDICOMFile()
        let decoder = try DCMDecoder(contentsOf: fileURL)

        // Store original decoder properties
        let originalWidth = decoder.width
        let originalHeight = decoder.height

        // Render multiple times
        for _ in 1...5 {
            _ = try DicomImageRenderer.render(
                decoder: decoder,
                windowingMode: .automatic
            )

            // Decoder properties should remain unchanged
            XCTAssertEqual(decoder.width, originalWidth, "Decoder width should not change")
            XCTAssertEqual(decoder.height, originalHeight, "Decoder height should not change")
        }
    }

    func testConcurrentAsyncRendersFromSameDecoder() async throws {
        let fileURL = try getAnyDICOMFile()
        let decoder = try await DCMDecoder(contentsOf: fileURL)

        // Launch multiple concurrent renders
        let tasks = (1...10).map { _ in
            Task {
                try await DicomImageRenderer.renderAsync(
                    decoder: decoder,
                    windowingMode: .automatic,
                    processingMode: .vdsp
                )
            }
        }

        // Wait for all to complete
        let images = try await tasks.asyncMap { try await $0.value }

        // All should succeed
        XCTAssertEqual(images.count, 10, "All concurrent renders should succeed")
        for cgImage in images {
            XCTAssertEqual(cgImage.width, decoder.width, "Width should match decoder")
            XCTAssertEqual(cgImage.height, decoder.height, "Height should match decoder")
        }
    }
}

// Helper extension for async mapping
extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self {
            try await results.append(transform(element))
        }
        return results
    }
}
