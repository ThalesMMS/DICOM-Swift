//
//  ValueTypesTests.swift
//  DicomCoreTests
//
//  Checks valid window widths and pixel spacing in typed imaging values.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

final class ValueTypesTests: XCTestCase {

    // MARK: - WindowSettings Tests

    func testWindowSettingsBasicInitialization() {
        let settings = WindowSettings(center: 50.0, width: 400.0)

        XCTAssertEqual(settings.center, 50.0, accuracy: 0.001)
        XCTAssertEqual(settings.width, 400.0, accuracy: 0.001)
    }

    func testWindowSettingsIsValidPositiveWidth() {
        let validSettings = WindowSettings(center: 50.0, width: 400.0)
        XCTAssertTrue(validSettings.isValid, "Settings with positive width should be valid")
    }

    func testWindowSettingsIsValidZeroWidth() {
        let invalidSettings = WindowSettings(center: 50.0, width: 0.0)
        XCTAssertFalse(invalidSettings.isValid, "Settings with zero width should be invalid")
    }

    func testWindowSettingsIsValidNegativeWidth() {
        let invalidSettings = WindowSettings(center: 50.0, width: -100.0)
        XCTAssertFalse(invalidSettings.isValid, "Settings with negative width should be invalid")
    }

    func testWindowSettingsEquatable() {
        let settings1 = WindowSettings(center: 50.0, width: 400.0)
        let settings2 = WindowSettings(center: 50.0, width: 400.0)
        let settings3 = WindowSettings(center: 60.0, width: 400.0)
        let settings4 = WindowSettings(center: 50.0, width: 500.0)

        XCTAssertEqual(settings1, settings2, "Identical settings should be equal")
        XCTAssertNotEqual(settings1, settings3, "Settings with different centers should not be equal")
        XCTAssertNotEqual(settings1, settings4, "Settings with different widths should not be equal")
    }

    func testWindowSettingsHashable() {
        let settings1 = WindowSettings(center: 50.0, width: 400.0)
        let settings2 = WindowSettings(center: 50.0, width: 400.0)
        let settings3 = WindowSettings(center: 60.0, width: 400.0)

        var set = Set<WindowSettings>()
        set.insert(settings1)
        set.insert(settings2)
        set.insert(settings3)

        XCTAssertEqual(set.count, 2, "Set should contain only unique settings")
        XCTAssertTrue(set.contains(settings1))
        XCTAssertTrue(set.contains(settings3))
    }

    func testWindowSettingsCodable() throws {
        let originalSettings = WindowSettings(center: 50.0, width: 400.0)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encoded = try encoder.encode(originalSettings)
        let decoded = try decoder.decode(WindowSettings.self, from: encoded)

        XCTAssertEqual(decoded.center, originalSettings.center, accuracy: 0.001)
        XCTAssertEqual(decoded.width, originalSettings.width, accuracy: 0.001)
        XCTAssertEqual(decoded, originalSettings)
    }

    func testWindowSettingsJSONFormat() throws {
        let settings = WindowSettings(center: 50.0, width: 400.0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let encoded = try encoder.encode(settings)
        let jsonString = String(data: encoded, encoding: .utf8)

        XCTAssertNotNil(jsonString)
        XCTAssertTrue(jsonString!.contains("\"center\""), "JSON should contain center key")
        XCTAssertTrue(jsonString!.contains("\"width\""), "JSON should contain width key")
    }

    func testWindowSettingsNegativeCenter() {
        let settings = WindowSettings(center: -500.0, width: 400.0)

        XCTAssertEqual(settings.center, -500.0, accuracy: 0.001)
        XCTAssertTrue(settings.isValid, "Negative center should be valid if width is positive")
    }

    func testWindowSettingsVeryLargeValues() {
        let settings = WindowSettings(center: 10000.0, width: 20000.0)

        XCTAssertEqual(settings.center, 10000.0, accuracy: 0.001)
        XCTAssertEqual(settings.width, 20000.0, accuracy: 0.001)
        XCTAssertTrue(settings.isValid)
    }

    func testWindowSettingsVerySmallPositiveWidth() {
        let settings = WindowSettings(center: 50.0, width: 0.0001)

        XCTAssertTrue(settings.isValid, "Very small positive width should be valid")
    }

    // MARK: - PixelSpacing Tests

    func testPixelSpacingBasicInitialization() {
        let spacing = PixelSpacing(x: 0.5, y: 0.5, z: 1.0)

        XCTAssertEqual(spacing.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(spacing.y, 0.5, accuracy: 0.001)
        XCTAssertEqual(spacing.z, 1.0, accuracy: 0.001)
    }

    func testPixelSpacingIsValidPositiveValues() {
        let validSpacing = PixelSpacing(x: 0.5, y: 0.5, z: 1.0)
        XCTAssertTrue(validSpacing.isValid, "Spacing with all positive values should be valid")
    }

    func testPixelSpacingIsValidZeroX() {
        let invalidSpacing = PixelSpacing(x: 0.0, y: 0.5, z: 1.0)
        XCTAssertFalse(invalidSpacing.isValid, "Spacing with zero x should be invalid")
    }

    func testPixelSpacingIsValidZeroY() {
        let invalidSpacing = PixelSpacing(x: 0.5, y: 0.0, z: 1.0)
        XCTAssertFalse(invalidSpacing.isValid, "Spacing with zero y should be invalid")
    }

    func testPixelSpacingIsValidZeroZ() {
        let invalidSpacing = PixelSpacing(x: 0.5, y: 0.5, z: 0.0)
        XCTAssertFalse(invalidSpacing.isValid, "Spacing with zero z should be invalid")
    }

    func testPixelSpacingIsValidNegativeValues() {
        let invalidSpacing1 = PixelSpacing(x: -0.5, y: 0.5, z: 1.0)
        let invalidSpacing2 = PixelSpacing(x: 0.5, y: -0.5, z: 1.0)
        let invalidSpacing3 = PixelSpacing(x: 0.5, y: 0.5, z: -1.0)

        XCTAssertFalse(invalidSpacing1.isValid, "Spacing with negative x should be invalid")
        XCTAssertFalse(invalidSpacing2.isValid, "Spacing with negative y should be invalid")
        XCTAssertFalse(invalidSpacing3.isValid, "Spacing with negative z should be invalid")
    }

    func testPixelSpacingEquatable() {
        let spacing1 = PixelSpacing(x: 0.5, y: 0.5, z: 1.0)
        let spacing2 = PixelSpacing(x: 0.5, y: 0.5, z: 1.0)
        let spacing3 = PixelSpacing(x: 0.6, y: 0.5, z: 1.0)
        let spacing4 = PixelSpacing(x: 0.5, y: 0.6, z: 1.0)
        let spacing5 = PixelSpacing(x: 0.5, y: 0.5, z: 2.0)

        XCTAssertEqual(spacing1, spacing2, "Identical spacing should be equal")
        XCTAssertNotEqual(spacing1, spacing3, "Spacing with different x should not be equal")
        XCTAssertNotEqual(spacing1, spacing4, "Spacing with different y should not be equal")
        XCTAssertNotEqual(spacing1, spacing5, "Spacing with different z should not be equal")
    }

    func testPixelSpacingHashable() {
        let spacing1 = PixelSpacing(x: 0.5, y: 0.5, z: 1.0)
        let spacing2 = PixelSpacing(x: 0.5, y: 0.5, z: 1.0)
        let spacing3 = PixelSpacing(x: 0.6, y: 0.5, z: 1.0)

        var set = Set<PixelSpacing>()
        set.insert(spacing1)
        set.insert(spacing2)
        set.insert(spacing3)

        XCTAssertEqual(set.count, 2, "Set should contain only unique spacing values")
        XCTAssertTrue(set.contains(spacing1))
        XCTAssertTrue(set.contains(spacing3))
    }

    func testPixelSpacingCodable() throws {
        let originalSpacing = PixelSpacing(x: 0.5, y: 0.5, z: 1.0)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encoded = try encoder.encode(originalSpacing)
        let decoded = try decoder.decode(PixelSpacing.self, from: encoded)

        XCTAssertEqual(decoded.x, originalSpacing.x, accuracy: 0.001)
        XCTAssertEqual(decoded.y, originalSpacing.y, accuracy: 0.001)
        XCTAssertEqual(decoded.z, originalSpacing.z, accuracy: 0.001)
        XCTAssertEqual(decoded, originalSpacing)
    }

    func testPixelSpacingJSONFormat() throws {
        let spacing = PixelSpacing(x: 0.5, y: 0.5, z: 1.0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let encoded = try encoder.encode(spacing)
        let jsonString = String(data: encoded, encoding: .utf8)

        XCTAssertNotNil(jsonString)
        XCTAssertTrue(jsonString!.contains("\"x\""), "JSON should contain x key")
        XCTAssertTrue(jsonString!.contains("\"y\""), "JSON should contain y key")
        XCTAssertTrue(jsonString!.contains("\"z\""), "JSON should contain z key")
    }

    func testPixelSpacingVerySmallPositiveValues() {
        let spacing = PixelSpacing(x: 0.0001, y: 0.0001, z: 0.0001)

        XCTAssertTrue(spacing.isValid, "Very small positive spacing should be valid")
    }

    func testPixelSpacingVeryLargeValues() {
        let spacing = PixelSpacing(x: 100.0, y: 100.0, z: 100.0)

        XCTAssertEqual(spacing.x, 100.0, accuracy: 0.001)
        XCTAssertEqual(spacing.y, 100.0, accuracy: 0.001)
        XCTAssertEqual(spacing.z, 100.0, accuracy: 0.001)
        XCTAssertTrue(spacing.isValid)
    }

    func testPixelSpacingMixedDimensions() {
        let spacing = PixelSpacing(x: 0.25, y: 0.5, z: 5.0)

        XCTAssertEqual(spacing.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(spacing.y, 0.5, accuracy: 0.001)
        XCTAssertEqual(spacing.z, 5.0, accuracy: 0.001)
        XCTAssertTrue(spacing.isValid, "Mixed dimension spacing should be valid")
    }

    // MARK: - RescaleParameters Tests

    func testRescaleParametersBasicInitialization() {
        let rescale = RescaleParameters(intercept: -1024.0, slope: 1.0)

        XCTAssertEqual(rescale.intercept, -1024.0, accuracy: 0.001)
        XCTAssertEqual(rescale.slope, 1.0, accuracy: 0.001)
    }

    func testRescaleParametersIsIdentityTrue() {
        let identityRescale = RescaleParameters(intercept: 0.0, slope: 1.0)
        XCTAssertTrue(identityRescale.isIdentity, "Rescale with slope=1.0 and intercept=0.0 should be identity")
    }

    func testRescaleParametersIsIdentityFalseIntercept() {
        let nonIdentityRescale = RescaleParameters(intercept: -1024.0, slope: 1.0)
        XCTAssertFalse(nonIdentityRescale.isIdentity, "Rescale with non-zero intercept should not be identity")
    }

    func testRescaleParametersIsIdentityFalseSlope() {
        let nonIdentityRescale = RescaleParameters(intercept: 0.0, slope: 2.0)
        XCTAssertFalse(nonIdentityRescale.isIdentity, "Rescale with slope != 1.0 should not be identity")
    }

    func testRescaleParametersIsIdentityFalseBoth() {
        let nonIdentityRescale = RescaleParameters(intercept: 100.0, slope: 2.0)
        XCTAssertFalse(nonIdentityRescale.isIdentity, "Rescale with non-identity values should not be identity")
    }

    func testRescaleParametersApplyIdentity() {
        let identityRescale = RescaleParameters(intercept: 0.0, slope: 1.0)

        XCTAssertEqual(identityRescale.apply(to: 0.0), 0.0, accuracy: 0.001)
        XCTAssertEqual(identityRescale.apply(to: 100.0), 100.0, accuracy: 0.001)
        XCTAssertEqual(identityRescale.apply(to: -50.0), -50.0, accuracy: 0.001)
    }

    func testRescaleParametersApplyWithIntercept() {
        let rescale = RescaleParameters(intercept: -1024.0, slope: 1.0)

        XCTAssertEqual(rescale.apply(to: 0.0), -1024.0, accuracy: 0.001)
        XCTAssertEqual(rescale.apply(to: 1024.0), 0.0, accuracy: 0.001)
        XCTAssertEqual(rescale.apply(to: 2048.0), 1024.0, accuracy: 0.001)
    }

    func testRescaleParametersApplyWithSlope() {
        let rescale = RescaleParameters(intercept: 0.0, slope: 2.0)

        XCTAssertEqual(rescale.apply(to: 0.0), 0.0, accuracy: 0.001)
        XCTAssertEqual(rescale.apply(to: 100.0), 200.0, accuracy: 0.001)
        XCTAssertEqual(rescale.apply(to: -50.0), -100.0, accuracy: 0.001)
    }

    func testRescaleParametersApplyWithBoth() {
        let rescale = RescaleParameters(intercept: 10.0, slope: 0.5)

        XCTAssertEqual(rescale.apply(to: 0.0), 10.0, accuracy: 0.001)
        XCTAssertEqual(rescale.apply(to: 20.0), 20.0, accuracy: 0.001)
        XCTAssertEqual(rescale.apply(to: 100.0), 60.0, accuracy: 0.001)
    }

    func testRescaleParametersApplyNegativeSlope() {
        let rescale = RescaleParameters(intercept: 100.0, slope: -1.0)

        XCTAssertEqual(rescale.apply(to: 0.0), 100.0, accuracy: 0.001)
        XCTAssertEqual(rescale.apply(to: 50.0), 50.0, accuracy: 0.001)
        XCTAssertEqual(rescale.apply(to: 100.0), 0.0, accuracy: 0.001)
    }

    func testRescaleParametersEquatable() {
        let rescale1 = RescaleParameters(intercept: -1024.0, slope: 1.0)
        let rescale2 = RescaleParameters(intercept: -1024.0, slope: 1.0)
        let rescale3 = RescaleParameters(intercept: 0.0, slope: 1.0)
        let rescale4 = RescaleParameters(intercept: -1024.0, slope: 2.0)

        XCTAssertEqual(rescale1, rescale2, "Identical rescale parameters should be equal")
        XCTAssertNotEqual(rescale1, rescale3, "Rescale with different intercepts should not be equal")
        XCTAssertNotEqual(rescale1, rescale4, "Rescale with different slopes should not be equal")
    }

    func testRescaleParametersHashable() {
        let rescale1 = RescaleParameters(intercept: -1024.0, slope: 1.0)
        let rescale2 = RescaleParameters(intercept: -1024.0, slope: 1.0)
        let rescale3 = RescaleParameters(intercept: 0.0, slope: 1.0)

        var set = Set<RescaleParameters>()
        set.insert(rescale1)
        set.insert(rescale2)
        set.insert(rescale3)

        XCTAssertEqual(set.count, 2, "Set should contain only unique rescale parameters")
        XCTAssertTrue(set.contains(rescale1))
        XCTAssertTrue(set.contains(rescale3))
    }

    func testRescaleParametersCodable() throws {
        let originalRescale = RescaleParameters(intercept: -1024.0, slope: 1.0)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encoded = try encoder.encode(originalRescale)
        let decoded = try decoder.decode(RescaleParameters.self, from: encoded)

        XCTAssertEqual(decoded.intercept, originalRescale.intercept, accuracy: 0.001)
        XCTAssertEqual(decoded.slope, originalRescale.slope, accuracy: 0.001)
        XCTAssertEqual(decoded, originalRescale)
    }

    func testRescaleParametersJSONFormat() throws {
        let rescale = RescaleParameters(intercept: -1024.0, slope: 1.0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let encoded = try encoder.encode(rescale)
        let jsonString = String(data: encoded, encoding: .utf8)

        XCTAssertNotNil(jsonString)
        XCTAssertTrue(jsonString!.contains("\"intercept\""), "JSON should contain intercept key")
        XCTAssertTrue(jsonString!.contains("\"slope\""), "JSON should contain slope key")
    }

    func testRescaleParametersZeroSlope() {
        let rescale = RescaleParameters(intercept: 100.0, slope: 0.0)

        XCTAssertEqual(rescale.apply(to: 0.0), 100.0, accuracy: 0.001)
        XCTAssertEqual(rescale.apply(to: 1000.0), 100.0, accuracy: 0.001)
        XCTAssertFalse(rescale.isIdentity, "Zero slope should not be identity")
    }

    func testRescaleParametersVeryLargeValues() {
        let rescale = RescaleParameters(intercept: 10000.0, slope: 100.0)

        XCTAssertEqual(rescale.apply(to: 10.0), 11000.0, accuracy: 0.001)
        XCTAssertFalse(rescale.isIdentity)
    }

    func testRescaleParametersVerySmallSlope() {
        let rescale = RescaleParameters(intercept: 0.0, slope: 0.001)

        XCTAssertEqual(rescale.apply(to: 1000.0), 1.0, accuracy: 0.001)
        XCTAssertFalse(rescale.isIdentity)
    }

    // MARK: - Cross-Type Integration Tests

    func testAllTypesAreSendable() {
        // This test verifies that all types conform to Sendable
        // (compilation success is the test)
        let settings = WindowSettings(center: 50.0, width: 400.0)
        let spacing = PixelSpacing(x: 0.5, y: 0.5, z: 1.0)
        let rescale = RescaleParameters(intercept: -1024.0, slope: 1.0)

        // If this compiles, Sendable conformance is verified
        Task {
            let _ = settings
            let _ = spacing
            let _ = rescale
        }
    }

    func testAllTypesCanBeStoredInCollections() {
        var settingsArray: [WindowSettings] = []
        var spacingDict: [String: PixelSpacing] = [:]
        var rescaleSet: Set<RescaleParameters> = []

        settingsArray.append(WindowSettings(center: 50.0, width: 400.0))
        spacingDict["CT"] = PixelSpacing(x: 0.5, y: 0.5, z: 1.0)
        rescaleSet.insert(RescaleParameters(intercept: -1024.0, slope: 1.0))

        XCTAssertEqual(settingsArray.count, 1)
        XCTAssertEqual(spacingDict.count, 1)
        XCTAssertEqual(rescaleSet.count, 1)
    }

    func testAllTypesJSONRoundTrip() throws {
        struct TestContainer: Codable {
            let settings: WindowSettings
            let spacing: PixelSpacing
            let rescale: RescaleParameters
        }

        let original = TestContainer(
            settings: WindowSettings(center: 50.0, width: 400.0),
            spacing: PixelSpacing(x: 0.5, y: 0.5, z: 1.0),
            rescale: RescaleParameters(intercept: -1024.0, slope: 1.0)
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(TestContainer.self, from: encoded)

        XCTAssertEqual(decoded.settings, original.settings)
        XCTAssertEqual(decoded.spacing, original.spacing)
        XCTAssertEqual(decoded.rescale, original.rescale)
    }
}
