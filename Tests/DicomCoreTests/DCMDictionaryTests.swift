import XCTest
@testable import DicomCore

final class DCMDictionaryTests: XCTestCase {

    // MARK: - Properties

    private var dictionary: DCMDictionary!

    // MARK: - Setup/Teardown

    override func setUp() {
        super.setUp()
        dictionary = DCMDictionary()
    }

    override func tearDown() {
        dictionary = nil
        super.tearDown()
    }

    // MARK: - Dictionary Loading Tests

    func testDictionaryLoadsFromBundle() {
        let modalityDescription = dictionary.description(forKey: "00080060")
        XCTAssertNotNil(modalityDescription, "Expected DICOM tag 00080060 to exist in the dictionary")
    }

    func testIntegerTagLookupMatchesHexKeyLookup() {
        let tag = DicomTag.modality.rawValue
        let key = "00080060"

        XCTAssertEqual(dictionary.value(forTag: tag), dictionary.value(forKey: key))
        XCTAssertEqual(dictionary.vrCode(forTag: tag), dictionary.vrCode(forKey: key))
        XCTAssertEqual(dictionary.description(forTag: tag), dictionary.description(forKey: key))
    }

    func testCommonDICOMTags() {
        // Patient Information Tags
        XCTAssertNotNil(dictionary.description(forKey: "00100010"), "Patient Name should exist")
        XCTAssertNotNil(dictionary.description(forKey: "00100020"), "Patient ID should exist")

        // Study Information Tags
        XCTAssertNotNil(dictionary.description(forKey: "0020000D"), "Study Instance UID should exist")
        XCTAssertNotNil(dictionary.description(forKey: "00080020"), "Study Date should exist")

        // Image Information Tags
        XCTAssertNotNil(dictionary.description(forKey: "00280010"), "Rows should exist")
        XCTAssertNotNil(dictionary.description(forKey: "00280011"), "Columns should exist")
    }

    func testEnhancedAndOverlayTagsHaveConcreteVRs() {
        XCTAssertEqual(dictionary.vrCode(forTag: 0x0020_1209), "IS")
        XCTAssertEqual(dictionary.vrCode(forTag: 0x0028_1056), "CS")
        XCTAssertEqual(dictionary.vrCode(forTag: 0x5200_9229), "SQ")
        XCTAssertEqual(dictionary.vrCode(forTag: 0x5200_9230), "SQ")
        XCTAssertEqual(dictionary.vrCode(forTag: 0x6002_0010), "US")
        XCTAssertEqual(dictionary.vrCode(forTag: 0x601E_3000), "OW")
    }

    // MARK: - Decoder Validation Tests

    func test_referencePixelAndOrderNumbers_haveStandardTagsAndVRs() {
        XCTAssertEqual(dictionary.value(forKey: "00186028"), "FDReference Pixel Physical Value X")
        XCTAssertNil(dictionary.value(forKey: "00181628"))
        for (tag, name) in [("00401006", "Placer Order Number / Procedure"),
                             ("00401007", "Filler Order Number / Procedure"),
                             ("00402006", "Placer Order Number / Imaging Service Request (Retired)"),
                             ("00402007", "Filler Order Number / Imaging Service Request (Retired)")] {
            XCTAssertEqual(dictionary.vrCode(forKey: tag), "SH")
            XCTAssertEqual(dictionary.description(forKey: tag), name)
        }
    }

    func testDecoderValidation() {
        let decoder = DCMDecoder()

        // Test initial state
        XCTAssertFalse(decoder.isValid(), "New decoder should not be valid")

        // Test validation status
        let status = decoder.getValidationStatus()
        XCTAssertFalse(status.isValid, "Initial validation should fail")
        XCTAssertFalse(status.hasPixels, "Should have no pixels initially")
    }

    func testDecoderConvenienceMethods() {
        let decoder = DCMDecoder()

        // Test convenience getters
        XCTAssertEqual(decoder.imageDimensions.width, decoder.width)
        XCTAssertEqual(decoder.imageDimensions.height, decoder.height)

        XCTAssertEqual(decoder.pixelSpacingV2.x, decoder.pixelWidth)
        XCTAssertEqual(decoder.pixelSpacingV2.y, decoder.pixelHeight)
        XCTAssertEqual(decoder.pixelSpacingV2.z, decoder.pixelDepth)

        XCTAssertEqual(decoder.windowSettingsV2.center, decoder.windowCenter)
        XCTAssertEqual(decoder.windowSettingsV2.width, decoder.windowWidth)

        XCTAssertEqual(decoder.rescaleParametersV2.intercept, 0.0)
        XCTAssertEqual(decoder.rescaleParametersV2.slope, 1.0)
    }

    func testDecoderImageTypeDetection() {
        let decoder = DCMDecoder()

        // Grayscale should be default
        XCTAssertTrue(decoder.isGrayscale, "Default should be grayscale")
        XCTAssertFalse(decoder.isColorImage, "Default should not be color")
        XCTAssertFalse(decoder.isMultiFrame, "Default should not be multi-frame")
    }

    // MARK: - Windowing Processor Tests

    func testWindowingPresets() {
        // Test all presets have valid values
        for preset in DCMWindowingProcessor.allPresets {
            let values = DCMWindowingProcessor.getPresetValuesV2(preset: preset)
            XCTAssertGreaterThan(values.width, 0, "\(preset.displayName) should have positive width")
        }
    }

    func testCTPresets() {
        let ctPresets = DCMWindowingProcessor.ctPresets
        XCTAssertTrue(ctPresets.contains(.lung), "CT presets should include lung")
        XCTAssertTrue(ctPresets.contains(.bone), "CT presets should include bone")
        XCTAssertTrue(ctPresets.contains(.brain), "CT presets should include brain")
    }

    func testPresetSuggestions() {
        // Test CT modality suggestions
        let ctSuggestions = DCMWindowingProcessor.suggestPresets(for: "CT", bodyPart: "CHEST")
        XCTAssertTrue(ctSuggestions.contains(.lung), "CT chest should suggest lung preset")

        let brainSuggestions = DCMWindowingProcessor.suggestPresets(for: "CT", bodyPart: "BRAIN")
        XCTAssertTrue(brainSuggestions.contains(.brain), "CT brain should suggest brain preset")

        // Test other modalities
        let mgSuggestions = DCMWindowingProcessor.suggestPresets(for: "MG")
        XCTAssertTrue(mgSuggestions.contains(.mammography), "MG should suggest mammography preset")

        let petSuggestions = DCMWindowingProcessor.suggestPresets(for: "PT")
        XCTAssertTrue(petSuggestions.contains(.petScan), "PT should suggest PET scan preset")
    }

    func testPresetValuesByName() {
        // Test case-insensitive name lookup
        XCTAssertNotNil(DCMWindowingProcessor.getPresetValuesV2(named: "lung"))
        XCTAssertNotNil(DCMWindowingProcessor.getPresetValuesV2(named: "LUNG"))
        XCTAssertNotNil(DCMWindowingProcessor.getPresetValuesV2(named: "Lung"))

        // Test multi-word names
        XCTAssertNotNil(DCMWindowingProcessor.getPresetValuesV2(named: "soft tissue"))
        XCTAssertNotNil(DCMWindowingProcessor.getPresetValuesV2(named: "softtissue"))

        // Test invalid name
        XCTAssertNil(DCMWindowingProcessor.getPresetValuesV2(named: "invalid_preset"))
    }

    func testPresetNameRecognition() {
        let lungPreset = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)
        let recognizedName = DCMWindowingProcessor.getPresetName(
            settings: lungPreset,
            tolerance: 10.0
        )
        XCTAssertEqual(recognizedName, "Lung", "Should recognize lung preset values")
    }

    func testHounsfieldConversion() {
        let slope = 1.0
        let intercept = -1024.0

        // Test pixel value to HU conversion
        let hu = DCMWindowingProcessor.pixelValueToHU(
            pixelValue: 1024.0,
            rescaleSlope: slope,
            rescaleIntercept: intercept
        )
        XCTAssertEqual(hu, 0.0, accuracy: 0.01, "1024 pixel value should equal 0 HU")

        // Test HU to pixel value conversion
        let pixelValue = DCMWindowingProcessor.huToPixelValue(
            hu: 0.0,
            rescaleSlope: slope,
            rescaleIntercept: intercept
        )
        XCTAssertEqual(pixelValue, 1024.0, accuracy: 0.01, "0 HU should equal 1024 pixel value")
    }

    func testQualityMetrics() {
        // Create sample pixel data
        let pixels: [UInt16] = Array(0..<1000).map { UInt16($0) }

        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels)

        XCTAssertNotNil(metrics["mean"], "Should have mean value")
        XCTAssertNotNil(metrics["std_deviation"], "Should have standard deviation")
        XCTAssertNotNil(metrics["min_value"], "Should have min value")
        XCTAssertNotNil(metrics["max_value"], "Should have max value")
        XCTAssertNotNil(metrics["contrast"], "Should have contrast value")
        XCTAssertNotNil(metrics["snr"], "Should have SNR value")
        XCTAssertNotNil(metrics["dynamic_range"], "Should have dynamic range")

        // Verify calculated values are reasonable
        XCTAssertGreaterThan(metrics["mean"]!, 0, "Mean should be positive")
        XCTAssertGreaterThan(metrics["std_deviation"]!, 0, "Std dev should be positive")
    }

    func testOptimalWindowCalculation() {
        // Create sample pixel data with known distribution
        let pixels: [UInt16] = Array(repeating: 100, count: 500) +
                               Array(repeating: 200, count: 500)

        let optimal = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels)

        XCTAssertGreaterThan(optimal.center, 0, "Center should be positive")
        XCTAssertGreaterThan(optimal.width, 0, "Width should be positive")
    }

    // MARK: - Error Handling Tests

    func testDICOMErrors() {
        let fileError = DICOMError.fileNotFound(path: "/test/path")
        XCTAssertNotNil(fileError.errorDescription, "Should have error description")
        XCTAssertNotNil(fileError.recoverySuggestion, "Should have recovery suggestion")

        XCTAssertEqual(fileError.category, .file, "Should be file category")
        XCTAssertEqual(fileError.severity, .warning, "File not found should be warning")

        let memoryError = DICOMError.memoryAllocationFailed(requestedSize: 1000000)
        XCTAssertEqual(memoryError.severity, .critical, "Memory error should be critical")
    }

    // MARK: - Performance Tests

    func testWindowingPerformance() {
        // Create large pixel array
        let pixels: [UInt16] = Array(repeating: 1000, count: 512 * 512)

        measure {
            _ = DCMWindowingProcessor.applyWindowLevel(
                pixels16: pixels,
                center: 40.0,
                width: 80.0
            )
        }
    }

    // MARK: - Image Enhancement Tests

    func testHistogramEqualizationApplication() {
        // Create sample 8-bit image data
        let width = 100
        let height = 100
        var pixels = [UInt8](repeating: 0, count: width * height)

        // Create gradient pattern
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = UInt8((x + y) % 256)
            }
        }

        let imageData = Data(pixels)
        let result = DCMWindowingProcessor.applyHistogramEqualization(
            imageData: imageData,
            width: width,
            height: height
        )

        XCTAssertNotNil(result, "Histogram equalization should return result")
        XCTAssertEqual(result?.count, imageData.count, "Result should have same size as input")
    }

    func testHistogramEqualizationInvalidInput() {
        let emptyData = Data()
        let result = DCMWindowingProcessor.applyHistogramEqualization(
            imageData: emptyData,
            width: 0,
            height: 0
        )
        XCTAssertNil(result, "Histogram equalization should return nil for invalid input")

        // Test mismatched dimensions
        let data = Data([UInt8](repeating: 0, count: 100))
        let mismatchResult = DCMWindowingProcessor.applyHistogramEqualization(
            imageData: data,
            width: 10,
            height: 20
        )
        XCTAssertNil(mismatchResult, "Histogram equalization should return nil for mismatched dimensions")
    }

    func testNoiseReduction() {
        let width = 50
        let height = 50
        var pixels = [UInt8](repeating: 128, count: width * height)

        // Add some noise
        for i in 0..<pixels.count where i % 5 == 0 {
            pixels[i] = UInt8.random(in: 0...255)
        }

        let imageData = Data(pixels)
        let result = DCMWindowingProcessor.applyNoiseReduction(
            imageData: imageData,
            width: width,
            height: height,
            strength: 0.5
        )

        XCTAssertNotNil(result, "Noise reduction should return result")
        XCTAssertEqual(result?.count, imageData.count, "Result should have same size")
    }

    func testNoiseReductionStrength() {
        let width = 10
        let height = 10
        let imageData = Data([UInt8](repeating: 100, count: width * height))

        // Test zero strength (should return original)
        let zeroStrength = DCMWindowingProcessor.applyNoiseReduction(
            imageData: imageData,
            width: width,
            height: height,
            strength: 0.0
        )
        XCTAssertEqual(zeroStrength, imageData, "Zero strength should return original data")

        // Test low strength
        let lowStrength = DCMWindowingProcessor.applyNoiseReduction(
            imageData: imageData,
            width: width,
            height: height,
            strength: 0.05
        )
        XCTAssertEqual(lowStrength, imageData, "Very low strength should return original data")

        // Test full strength
        let fullStrength = DCMWindowingProcessor.applyNoiseReduction(
            imageData: imageData,
            width: width,
            height: height,
            strength: 1.0
        )
        XCTAssertNotNil(fullStrength, "Full strength should work")
    }

    func testNoiseReductionInvalidInput() {
        let emptyData = Data()
        let result = DCMWindowingProcessor.applyNoiseReduction(
            imageData: emptyData,
            width: 0,
            height: 0,
            strength: 0.5
        )
        XCTAssertNil(result, "Should return nil for invalid input")
    }

    // MARK: - Batch Processing Tests

    func testBatchCalculateOptimalWindowLevel() {
        let pixels1: [UInt16] = Array(0..<1000).map { UInt16($0) }
        let pixels2: [UInt16] = Array(1000..<2000).map { UInt16($0) }

        let imagePixels = [pixels1, pixels2]
        let results = DCMWindowingProcessor.batchCalculateOptimalWindowLevelV2(imagePixels: imagePixels)

        XCTAssertEqual(results.count, 2, "Should calculate for all images")
        XCTAssertGreaterThan(results[0].center, 0, "First center should be positive")
        XCTAssertGreaterThan(results[0].width, 0, "First width should be positive")
        XCTAssertGreaterThan(results[1].center, 0, "Second center should be positive")
        XCTAssertGreaterThan(results[1].width, 0, "Second width should be positive")
    }

    // MARK: - Additional Preset Tests

    func testAllPresetsAvailable() {
        let allPresets = DCMWindowingProcessor.allPresets
        XCTAssertFalse(allPresets.isEmpty, "Should have presets available")

        // Verify all enum cases are included
        XCTAssertTrue(allPresets.contains(.lung), "Should include lung")
        XCTAssertTrue(allPresets.contains(.bone), "Should include bone")
        XCTAssertTrue(allPresets.contains(.softTissue), "Should include soft tissue")
        XCTAssertTrue(allPresets.contains(.brain), "Should include brain")
        XCTAssertTrue(allPresets.contains(.liver), "Should include liver")
        XCTAssertTrue(allPresets.contains(.mediastinum), "Should include mediastinum")
        XCTAssertTrue(allPresets.contains(.abdomen), "Should include abdomen")
        XCTAssertTrue(allPresets.contains(.spine), "Should include spine")
        XCTAssertTrue(allPresets.contains(.pelvis), "Should include pelvis")
        XCTAssertTrue(allPresets.contains(.angiography), "Should include angiography")
        XCTAssertTrue(allPresets.contains(.pulmonaryEmbolism), "Should include pulmonary embolism")
        XCTAssertTrue(allPresets.contains(.mammography), "Should include mammography")
        XCTAssertTrue(allPresets.contains(.petScan), "Should include PET scan")
        XCTAssertTrue(allPresets.contains(.custom), "Should include custom")
    }

    func testGetPresetByEnumCase() {
        let lungPreset = DCMWindowingProcessor.getPreset(for: .lung)
        XCTAssertEqual(lungPreset.name, "Lung", "Should return correct name")
        XCTAssertEqual(lungPreset.center, -600.0, "Should return correct center")
        XCTAssertEqual(lungPreset.width, 1500.0, "Should return correct width")
        XCTAssertEqual(lungPreset.modality, "CT", "Should return correct modality")

        let brainPreset = DCMWindowingProcessor.getPreset(for: .brain)
        XCTAssertEqual(brainPreset.name, "Brain", "Should return correct name")
        XCTAssertEqual(brainPreset.modality, "CT", "Should return CT modality")

        let mammoPreset = DCMWindowingProcessor.getPreset(for: .mammography)
        XCTAssertEqual(mammoPreset.modality, "MG", "Should return MG modality")
    }

    func testPresetDisplayNames() {
        XCTAssertEqual(MedicalPreset.lung.displayName, "Lung")
        XCTAssertEqual(MedicalPreset.bone.displayName, "Bone")
        XCTAssertEqual(MedicalPreset.softTissue.displayName, "Soft Tissue")
        XCTAssertEqual(MedicalPreset.brain.displayName, "Brain")
        XCTAssertEqual(MedicalPreset.pulmonaryEmbolism.displayName, "Pulmonary Embolism")
        XCTAssertEqual(MedicalPreset.mammography.displayName, "Mammography")
        XCTAssertEqual(MedicalPreset.petScan.displayName, "PET Scan")
    }

    func testPresetAssociatedModalities() {
        XCTAssertEqual(MedicalPreset.lung.associatedModality, "CT")
        XCTAssertEqual(MedicalPreset.bone.associatedModality, "CT")
        XCTAssertEqual(MedicalPreset.mammography.associatedModality, "MG")
        XCTAssertEqual(MedicalPreset.petScan.associatedModality, "PT")
        XCTAssertEqual(MedicalPreset.custom.associatedModality, "OT")
    }

    func testPresetAlternativeNames() {
        // Test PE abbreviation
        XCTAssertNotNil(DCMWindowingProcessor.getPresetValuesV2(named: "pe"))

        // Test mammo abbreviation
        XCTAssertNotNil(DCMWindowingProcessor.getPresetValuesV2(named: "mammo"))

        // Test PET variations
        XCTAssertNotNil(DCMWindowingProcessor.getPresetValuesV2(named: "pet"))
        XCTAssertNotNil(DCMWindowingProcessor.getPresetValuesV2(named: "petscan"))
        XCTAssertNotNil(DCMWindowingProcessor.getPresetValuesV2(named: "pet scan"))
    }

    func testModalitySuggestions() {
        // Test MR modality
        let mrSuggestions = DCMWindowingProcessor.suggestPresets(for: "MR")
        XCTAssertTrue(mrSuggestions.contains(.brain), "MR should suggest brain")
        XCTAssertTrue(mrSuggestions.contains(.softTissue), "MR should suggest soft tissue")

        // Test unknown modality
        let unknownSuggestions = DCMWindowingProcessor.suggestPresets(for: "XX")
        XCTAssertTrue(unknownSuggestions.contains(.custom), "Unknown modality should suggest custom")
    }

    func testBodyPartSpecificSuggestions() {
        // Test spine suggestions
        let spineSuggestions = DCMWindowingProcessor.suggestPresets(for: "CT", bodyPart: "SPINE")
        XCTAssertTrue(spineSuggestions.contains(.spine), "Should suggest spine preset")
        XCTAssertTrue(spineSuggestions.contains(.bone), "Should suggest bone preset")

        // Test pelvis suggestions
        let pelvisSuggestions = DCMWindowingProcessor.suggestPresets(for: "CT", bodyPart: "PELVIS")
        XCTAssertTrue(pelvisSuggestions.contains(.pelvis), "Should suggest pelvis preset")

        // Test liver/abdomen suggestions
        let liverSuggestions = DCMWindowingProcessor.suggestPresets(for: "CT", bodyPart: "LIVER")
        XCTAssertTrue(liverSuggestions.contains(.liver), "Should suggest liver preset")
        XCTAssertTrue(liverSuggestions.contains(.abdomen), "Should suggest abdomen preset")
    }

    // MARK: - Edge Case Tests

    func testWindowLevelWithEmptyArray() {
        let emptyPixels: [UInt16] = []
        let result = DCMWindowingProcessor.applyWindowLevel(
            pixels16: emptyPixels,
            center: 40.0,
            width: 80.0
        )
        XCTAssertNil(result, "Should return nil for empty array")
    }

    func testWindowLevelWithZeroWidth() {
        let pixels: [UInt16] = Array(repeating: 1000, count: 100)
        let result = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels,
            center: 40.0,
            width: 0.0
        )
        XCTAssertNil(result, "Should return nil for zero width")
    }

    func testWindowLevelWithNegativeWidth() {
        let pixels: [UInt16] = Array(repeating: 1000, count: 100)
        let result = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels,
            center: 40.0,
            width: -80.0
        )
        XCTAssertNil(result, "Should return nil for negative width")
    }

    func testOptimalWindowWithEmptyArray() {
        let emptyPixels: [UInt16] = []
        let result = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: emptyPixels)
        XCTAssertEqual(result.center, 0.0, "Empty array should return 0 center")
        XCTAssertEqual(result.width, 0.0, "Empty array should return 0 width")
    }

    func testQualityMetricsWithEmptyArray() {
        let emptyPixels: [UInt16] = []
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: emptyPixels)
        XCTAssertTrue(metrics.isEmpty, "Empty array should return empty metrics")
    }

    func testHistogramWithEmptyArray() {
        let emptyPixels: [UInt16] = []
        var minValue: Double = 0
        var maxValue: Double = 0
        var meanValue: Double = 0

        let histogram = DCMWindowingProcessor.calculateHistogram(
            pixels16: emptyPixels,
            minValue: &minValue,
            maxValue: &maxValue,
            meanValue: &meanValue
        )

        XCTAssertTrue(histogram.isEmpty, "Empty array should return empty histogram")
    }

    func testHounsfieldConversionEdgeCases() {
        // Test with zero slope
        let pixelValue = DCMWindowingProcessor.huToPixelValue(
            hu: 100.0,
            rescaleSlope: 0.0,
            rescaleIntercept: -1024.0
        )
        XCTAssertEqual(pixelValue, 0.0, "Zero slope should return 0")

        // Test round-trip conversion
        let originalHU = 100.0
        let slope = 1.0
        let intercept = -1024.0

        let pixel = DCMWindowingProcessor.huToPixelValue(
            hu: originalHU,
            rescaleSlope: slope,
            rescaleIntercept: intercept
        )
        let convertedHU = DCMWindowingProcessor.pixelValueToHU(
            pixelValue: pixel,
            rescaleSlope: slope,
            rescaleIntercept: intercept
        )

        XCTAssertEqual(convertedHU, originalHU, accuracy: 0.01, "Round-trip conversion should preserve value")
    }

    func testPresetNameRecognitionWithTolerance() {
        let lungPreset = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)

        // Test exact match
        let exactMatch = DCMWindowingProcessor.getPresetName(
            settings: lungPreset,
            tolerance: 10.0
        )
        XCTAssertEqual(exactMatch, "Lung", "Should recognize exact match")

        // Test within tolerance
        let withinToleranceSettings = WindowSettings(
            center: lungPreset.center + 5.0,
            width: lungPreset.width + 5.0
        )
        let withinTolerance = DCMWindowingProcessor.getPresetName(
            settings: withinToleranceSettings,
            tolerance: 10.0
        )
        XCTAssertEqual(withinTolerance, "Lung", "Should recognize within tolerance")

        // Test outside tolerance
        let outsideToleranceSettings = WindowSettings(
            center: lungPreset.center + 100.0,
            width: lungPreset.width + 100.0
        )
        let outsideTolerance = DCMWindowingProcessor.getPresetName(
            settings: outsideToleranceSettings,
            tolerance: 10.0
        )
        XCTAssertNil(outsideTolerance, "Should not recognize outside tolerance")
    }
}
