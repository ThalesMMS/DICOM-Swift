//
//  DCMWindowingProcessorPresetsTests.swift
//  DicomCoreTests
//
//  Checks preset window widths and full-range values for custom presets.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

// MARK: - DCMWindowingProcessor Presets Tests

final class DCMWindowingProcessorPresetsTests: XCTestCase {

    // MARK: - getPresetValuesV2(preset:) Tests

    func testPresetLung() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)
        XCTAssertEqual(settings.center, -600.0, accuracy: 0.01, "Lung center should be -600 HU")
        XCTAssertEqual(settings.width, 1500.0, accuracy: 0.01, "Lung width should be 1500 HU")
    }

    func testPresetBone() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(preset: .bone)
        XCTAssertEqual(settings.center, 400.0, accuracy: 0.01, "Bone center should be 400 HU")
        XCTAssertEqual(settings.width, 1800.0, accuracy: 0.01, "Bone width should be 1800 HU")
    }

    func testPresetSoftTissue() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(preset: .softTissue)
        XCTAssertEqual(settings.center, 50.0, accuracy: 0.01, "Soft tissue center should be 50 HU")
        XCTAssertEqual(settings.width, 350.0, accuracy: 0.01, "Soft tissue width should be 350 HU")
    }

    func testPresetBrain() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(preset: .brain)
        XCTAssertEqual(settings.center, 40.0, accuracy: 0.01, "Brain center should be 40 HU")
        XCTAssertEqual(settings.width, 80.0, accuracy: 0.01, "Brain width should be 80 HU")
    }

    func testPresetLiver() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(preset: .liver)
        XCTAssertEqual(settings.center, 120.0, accuracy: 0.01, "Liver center should be 120 HU")
        XCTAssertEqual(settings.width, 200.0, accuracy: 0.01, "Liver width should be 200 HU")
    }

    func testPresetCustomReturnsFullRange() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(preset: .custom)
        XCTAssertEqual(settings.center, 0.0, accuracy: 0.01, "Custom center should be 0.0")
        XCTAssertEqual(settings.width, 4096.0, accuracy: 0.01, "Custom width should be 4096.0")
    }

    func testPresetMediastinum() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(preset: .mediastinum)
        XCTAssertEqual(settings.center, 50.0, accuracy: 0.01, "Mediastinum center should be 50 HU")
        XCTAssertEqual(settings.width, 350.0, accuracy: 0.01, "Mediastinum width should be 350 HU")
    }

    func testPresetAbdomen() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(preset: .abdomen)
        XCTAssertEqual(settings.center, 60.0, accuracy: 0.01, "Abdomen center should be 60 HU")
        XCTAssertEqual(settings.width, 400.0, accuracy: 0.01, "Abdomen width should be 400 HU")
    }

    func testPresetSpine() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(preset: .spine)
        XCTAssertEqual(settings.center, 50.0, accuracy: 0.01, "Spine center should be 50 HU")
        XCTAssertEqual(settings.width, 250.0, accuracy: 0.01, "Spine width should be 250 HU")
    }

    func testPresetAngiography() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(preset: .angiography)
        XCTAssertEqual(settings.center, 300.0, accuracy: 0.01, "Angiography center should be 300 HU")
        XCTAssertEqual(settings.width, 600.0, accuracy: 0.01, "Angiography width should be 600 HU")
    }

    func testPresetMammography() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(preset: .mammography)
        XCTAssertEqual(settings.center, 2000.0, accuracy: 0.01, "Mammography center should be 2000")
        XCTAssertEqual(settings.width, 4000.0, accuracy: 0.01, "Mammography width should be 4000")
    }

    func testPresetPETScan() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(preset: .petScan)
        XCTAssertEqual(settings.center, 2500.0, accuracy: 0.01, "PET scan center should be 2500")
        XCTAssertEqual(settings.width, 5000.0, accuracy: 0.01, "PET scan width should be 5000")
    }

    func testAllPresetsReturnPositiveWidth() {
        for preset in MedicalPreset.allCases {
            let settings = DCMWindowingProcessor.getPresetValuesV2(preset: preset)
            XCTAssertGreaterThan(settings.width, 0, "Preset \(preset) should have positive width")
        }
    }

    // MARK: - getPresetValuesV2(named:) Tests

    func testNamedPresetLung() throws {
        let settings = try XCTUnwrap(DCMWindowingProcessor.getPresetValuesV2(named: "lung"),
                                     "Named preset 'lung' should return settings")
        XCTAssertEqual(settings.center, -600.0, accuracy: 0.01, "Lung center should be -600 HU")
    }

    func testNamedPresetBone() throws {
        let settings = try XCTUnwrap(DCMWindowingProcessor.getPresetValuesV2(named: "bone"),
                                     "Named preset 'bone' should return settings")
        XCTAssertEqual(settings.center, 400.0, accuracy: 0.01, "Bone center should be 400 HU")
    }

    func testNamedPresetSoftTissueTwoWords() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(named: "soft tissue")
        XCTAssertNotNil(settings, "Named preset 'soft tissue' should return settings")
    }

    func testNamedPresetSoftTissueOneWord() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(named: "softtissue")
        XCTAssertNotNil(settings, "Named preset 'softtissue' should return settings")
    }

    func testNamedPresetBrain() throws {
        let settings = try XCTUnwrap(DCMWindowingProcessor.getPresetValuesV2(named: "brain"),
                                     "Named preset 'brain' should return settings")
        XCTAssertEqual(settings.width, 80.0, accuracy: 0.01, "Brain width should be 80 HU")
    }

    func testNamedPresetPulmonaryEmbolism() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(named: "pulmonary embolism")
        XCTAssertNotNil(settings, "Named preset 'pulmonary embolism' should return settings")
    }

    func testNamedPresetPEAlias() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(named: "pe")
        XCTAssertNotNil(settings, "Named preset 'pe' (alias) should return settings")
    }

    func testNamedPresetMammoAlias() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(named: "mammo")
        XCTAssertNotNil(settings, "Named preset 'mammo' (alias) should return settings")
    }

    func testNamedPresetPETAlias() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(named: "pet")
        XCTAssertNotNil(settings, "Named preset 'pet' (alias) should return settings")
    }

    func testNamedPresetCaseInsensitive() {
        let lowerSettings = DCMWindowingProcessor.getPresetValuesV2(named: "lung")
        let upperSettings = DCMWindowingProcessor.getPresetValuesV2(named: "LUNG")
        let mixedSettings = DCMWindowingProcessor.getPresetValuesV2(named: "Lung")

        // The method uses lowercased() comparison
        XCTAssertNotNil(lowerSettings, "Lowercase 'lung' should work")
        XCTAssertNotNil(upperSettings, "Uppercase 'LUNG' should work")
        XCTAssertNotNil(mixedSettings, "Mixed-case 'Lung' should work")
        XCTAssertEqual(upperSettings, lowerSettings, "Uppercase lookup should match lowercase lookup")
        XCTAssertEqual(mixedSettings, lowerSettings, "Mixed-case lookup should match lowercase lookup")
    }

    func testNamedPresetUnknownReturnsNil() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(named: "unknownpresetxyz")
        XCTAssertNil(settings, "Unknown preset name should return nil")
    }

    func testNamedPresetEmptyStringReturnsNil() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(named: "")
        XCTAssertNil(settings, "Empty preset name should return nil")
    }

    // MARK: - suggestPresets(for:bodyPart:) Tests

    func testSuggestPresetsForCT() {
        let presets = DCMWindowingProcessor.suggestPresets(for: "CT")
        XCTAssertFalse(presets.isEmpty, "CT should suggest presets")
        XCTAssertTrue(presets.contains(.softTissue) || presets.contains(.bone) || presets.contains(.lung),
                      "CT should suggest relevant presets")
    }

    func testSuggestPresetsForCTLung() {
        let presets = DCMWindowingProcessor.suggestPresets(for: "CT", bodyPart: "lung")
        XCTAssertFalse(presets.isEmpty, "CT lung should suggest presets")
        XCTAssertTrue(presets.first == .lung, "CT lung should suggest lung preset first")
    }

    func testSuggestPresetsForCTBrain() {
        let presets = DCMWindowingProcessor.suggestPresets(for: "CT", bodyPart: "brain")
        XCTAssertFalse(presets.isEmpty, "CT brain should suggest presets")
        XCTAssertTrue(presets.first == .brain, "CT brain should suggest brain preset first")
    }

    func testSuggestPresetsForCTAbdomen() {
        let presets = DCMWindowingProcessor.suggestPresets(for: "CT", bodyPart: "abdomen")
        XCTAssertFalse(presets.isEmpty, "CT abdomen should suggest presets")
        XCTAssertTrue(presets.contains(.abdomen) || presets.contains(.liver),
                      "CT abdomen should suggest abdomen or liver")
    }

    func testSuggestPresetsForCTSpine() {
        let presets = DCMWindowingProcessor.suggestPresets(for: "CT", bodyPart: "spine")
        XCTAssertFalse(presets.isEmpty, "CT spine should suggest presets")
        XCTAssertTrue(presets.first == .spine, "CT spine should suggest spine preset first")
    }

    func testSuggestPresetsForMG() {
        let presets = DCMWindowingProcessor.suggestPresets(for: "MG")
        XCTAssertEqual(presets, [.mammography], "MG should suggest mammography")
    }

    func testSuggestPresetsForPT() {
        let presets = DCMWindowingProcessor.suggestPresets(for: "PT")
        XCTAssertEqual(presets, [.petScan], "PT should suggest petScan")
    }

    func testSuggestPresetsForMR() {
        let presets = DCMWindowingProcessor.suggestPresets(for: "MR")
        XCTAssertFalse(presets.isEmpty, "MR should suggest presets")
        XCTAssertTrue(presets.contains(.brain) || presets.contains(.softTissue),
                      "MR should suggest brain or soft tissue")
    }

    func testSuggestPresetsForUnknownModalityReturnsCustom() {
        let presets = DCMWindowingProcessor.suggestPresets(for: "XYZ")
        XCTAssertEqual(presets, [.custom], "Unknown modality should suggest custom")
    }

    func testSuggestPresetsModalityIsCaseInsensitive() {
        let upperPresets = DCMWindowingProcessor.suggestPresets(for: "CT")
        let lowerPresets = DCMWindowingProcessor.suggestPresets(for: "ct")
        XCTAssertEqual(upperPresets, lowerPresets, "Modality lookup should be case-insensitive")
    }

    func testSuggestPresetsForCTChest() {
        let presets = DCMWindowingProcessor.suggestPresets(for: "CT", bodyPart: "chest")
        XCTAssertTrue(presets.contains(.lung), "CT chest should suggest lung preset")
    }

    func testSuggestPresetsForCTPelvis() {
        let presets = DCMWindowingProcessor.suggestPresets(for: "CT", bodyPart: "pelvis")
        XCTAssertTrue(presets.contains(.pelvis), "CT pelvis should suggest pelvis preset")
    }

    // MARK: - getPresetName(settings:tolerance:) Tests

    func testGetPresetNameForLungSettings() {
        let lungSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)
        let name = DCMWindowingProcessor.getPresetName(settings: lungSettings)
        XCTAssertNotNil(name, "Should find a name for lung settings")
        XCTAssertEqual(name, MedicalPreset.lung.displayName, "Name should match lung preset display name")
    }

    func testGetPresetNameForBrainSettings() {
        let brainSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .brain)
        let name = DCMWindowingProcessor.getPresetName(settings: brainSettings)
        XCTAssertNotNil(name, "Should find a name for brain settings")
        XCTAssertEqual(name, MedicalPreset.brain.displayName, "Name should match brain preset display name")
    }

    func testGetPresetNameWithTolerance() {
        // Settings close to lung but slightly off
        let almostLung = WindowSettings(center: -605.0, width: 1510.0) // within 50 of lung (-600, 1500)
        let name = DCMWindowingProcessor.getPresetName(settings: almostLung, tolerance: 50.0)
        XCTAssertNotNil(name, "Should match lung preset within tolerance")
    }

    func testGetPresetNameNoMatchReturnsNil() {
        let impossibleSettings = WindowSettings(center: 99999.0, width: 99999.0)
        let name = DCMWindowingProcessor.getPresetName(settings: impossibleSettings)
        XCTAssertNil(name, "Settings far from any preset should return nil")
    }

    func testGetPresetNameDefaultTolerance() {
        // Test that default tolerance is 50.0
        let exactLungSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)
        let name = DCMWindowingProcessor.getPresetName(settings: exactLungSettings)
        XCTAssertNotNil(name, "Exact preset settings should match with default tolerance")
    }

    // MARK: - MedicalPreset Enum Tests

    func testMedicalPresetAllCasesNotEmpty() {
        XCTAssertFalse(MedicalPreset.allCases.isEmpty, "MedicalPreset.allCases should not be empty")
    }

    func testMedicalPresetRawValues() {
        XCTAssertEqual(MedicalPreset.lung.rawValue, 0, "Lung raw value should be 0")
        XCTAssertEqual(MedicalPreset.bone.rawValue, 1, "Bone raw value should be 1")
        XCTAssertEqual(MedicalPreset.softTissue.rawValue, 2, "SoftTissue raw value should be 2")
        XCTAssertEqual(MedicalPreset.brain.rawValue, 3, "Brain raw value should be 3")
        XCTAssertEqual(MedicalPreset.liver.rawValue, 4, "Liver raw value should be 4")
        XCTAssertEqual(MedicalPreset.custom.rawValue, 5, "Custom raw value should be 5")
    }

    func testMedicalPresetDisplayNames() {
        XCTAssertEqual(MedicalPreset.lung.displayName, "Lung", "Lung display name should be 'Lung'")
        XCTAssertEqual(MedicalPreset.bone.displayName, "Bone", "Bone display name should be 'Bone'")
        XCTAssertEqual(MedicalPreset.brain.displayName, "Brain", "Brain display name should be 'Brain'")
    }

    // MARK: - allPresets and ctPresets Properties Tests

    func testAllPresetsReturnsAllCases() {
        XCTAssertEqual(DCMWindowingProcessor.allPresets.count, MedicalPreset.allCases.count,
                       "allPresets should contain all MedicalPreset cases")
    }

    func testCTPresetsContainCTSpecificPresets() {
        let ctPresets = DCMWindowingProcessor.ctPresets
        XCTAssertTrue(ctPresets.contains(.lung), "ctPresets should include lung")
        XCTAssertTrue(ctPresets.contains(.bone), "ctPresets should include bone")
        XCTAssertTrue(ctPresets.contains(.brain), "ctPresets should include brain")
        XCTAssertTrue(ctPresets.contains(.mediastinum), "ctPresets should include mediastinum")
        XCTAssertFalse(ctPresets.contains(.mammography), "ctPresets should not include mammography")
        XCTAssertFalse(ctPresets.contains(.petScan), "ctPresets should not include petScan")
    }

    // MARK: - getPreset(for:) Tests

    func testGetPresetReturnsNameCenterWidthModality() {
        let presetTuple = DCMWindowingProcessor.getPreset(for: .lung)
        XCTAssertEqual(presetTuple.name, MedicalPreset.lung.displayName, "Name should match displayName")
        XCTAssertEqual(presetTuple.center, -600.0, accuracy: 0.01, "Center should match lung preset")
        XCTAssertEqual(presetTuple.width, 1500.0, accuracy: 0.01, "Width should match lung preset")
        XCTAssertFalse(presetTuple.modality.isEmpty, "Modality should not be empty")
    }

    func testGetPresetForBrainConsistency() {
        let settings = DCMWindowingProcessor.getPresetValuesV2(preset: .brain)
        let presetTuple = DCMWindowingProcessor.getPreset(for: .brain)
        XCTAssertEqual(presetTuple.center, settings.center, accuracy: 0.01, "getPreset center should match getPresetValuesV2")
        XCTAssertEqual(presetTuple.width, settings.width, accuracy: 0.01, "getPreset width should match getPresetValuesV2")
    }
}
