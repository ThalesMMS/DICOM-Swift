//
//  DCMDecoderV2APITests.swift
//  DicomCoreTests
//
//  Checks typed pixel spacing, window settings, and rescale parameters before and after file
//  loading.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

final class DCMDecoderV2APITests: XCTestCase {

    func testPixelSpacingV2Property() {
        let decoder = DCMDecoder()
        let spacingV2 = decoder.pixelSpacingV2

        XCTAssertEqual(spacingV2.x, decoder.pixelWidth, "pixelSpacingV2.x should match pixelWidth")
        XCTAssertEqual(spacingV2.y, decoder.pixelHeight, "pixelSpacingV2.y should match pixelHeight")
        XCTAssertEqual(spacingV2.z, decoder.pixelDepth, "pixelSpacingV2.z should match pixelDepth")
        XCTAssertEqual(spacingV2.x, 1.0, "Initial spacing x should be 1.0")
        XCTAssertEqual(spacingV2.y, 1.0, "Initial spacing y should be 1.0")
        XCTAssertEqual(spacingV2.z, 1.0, "Initial spacing z should be 1.0")
    }

    func testWindowSettingsV2Property() {
        let decoder = DCMDecoder()
        let settingsV2 = decoder.windowSettingsV2

        XCTAssertEqual(settingsV2.center, decoder.windowCenter, "windowSettingsV2.center should match windowCenter")
        XCTAssertEqual(settingsV2.width, decoder.windowWidth, "windowSettingsV2.width should match windowWidth")
        XCTAssertEqual(settingsV2.center, 0.0, "Initial window center should be 0.0")
        XCTAssertEqual(settingsV2.width, 0.0, "Initial window width should be 0.0")
    }

    func testRescaleParametersV2Property() {
        let decoder = DCMDecoder()
        let parametersV2 = decoder.rescaleParametersV2

        XCTAssertEqual(parametersV2.intercept, 0.0, "Initial rescale intercept should be 0.0")
        XCTAssertEqual(parametersV2.slope, 1.0, "Initial rescale slope should be 1.0")
        XCTAssertTrue(parametersV2.isIdentity, "Default parameters should be identity transformation")
    }

    func testPixelSpacingV2WithLoadedFile() throws {
        let decoder = try DCMDecoder(contentsOf: getAnyFixtureDICOMURL())
        let spacingV2 = decoder.pixelSpacingV2

        XCTAssertEqual(spacingV2.x, decoder.pixelWidth, "V2 x should match pixelWidth")
        XCTAssertEqual(spacingV2.y, decoder.pixelHeight, "V2 y should match pixelHeight")
        XCTAssertEqual(spacingV2.z, decoder.pixelDepth, "V2 z should match pixelDepth")
    }

    func testWindowSettingsV2WithLoadedFile() throws {
        let decoder = try DCMDecoder(contentsOf: getAnyFixtureDICOMURL())
        let settingsV2 = decoder.windowSettingsV2

        XCTAssertEqual(settingsV2.center, decoder.windowCenter, "V2 center should match windowCenter")
        XCTAssertEqual(settingsV2.width, decoder.windowWidth, "V2 width should match windowWidth")
    }

    func testRescaleParametersV2WithLoadedFile() throws {
        let decoder = try DCMDecoder(contentsOf: getAnyFixtureDICOMURL())
        let parametersV2 = decoder.rescaleParametersV2

        let testValue = 100.0
        let v2Result = parametersV2.apply(to: testValue)
        let decoderResult = decoder.applyRescale(to: testValue)
        XCTAssertEqual(v2Result, decoderResult, accuracy: 0.01, "V2 apply() should match decoder applyRescale()")
    }

    func testCalculateOptimalWindowV2() throws {
        let decoder = try DCMDecoder(contentsOf: getAnyFixtureDICOMURL())

        let settingsV2 = try XCTUnwrap(
            decoder.calculateOptimalWindowV2(),
            "Required bundled fixture must include pixel data for optimal window calculation."
        )

        XCTAssertTrue(settingsV2.isValid, "Calculated settings should be valid")
        XCTAssertGreaterThan(settingsV2.width, 0, "Calculated window width should be positive")
    }

    func testCalculateOptimalWindowV2WithNoPixelData() {
        let decoder = DCMDecoder()
        XCTAssertNil(decoder.calculateOptimalWindowV2(), "V2 API should return nil when no pixel data")
    }

    func testV2APIStructTypeSafety() {
        let decoder = DCMDecoder()

        let spacing: PixelSpacing = decoder.pixelSpacingV2
        let settings: WindowSettings = decoder.windowSettingsV2
        let parameters: RescaleParameters = decoder.rescaleParametersV2

        _ = spacing.isValid
        _ = settings.isValid
        _ = parameters.isIdentity

        XCTAssertNotNil(spacing, "Should compile with PixelSpacing type")
        XCTAssertNotNil(settings, "Should compile with WindowSettings type")
        XCTAssertNotNil(parameters, "Should compile with RescaleParameters type")
    }

    func testV2APIStructCodableConformance() throws {
        let decoder = try DCMDecoder(contentsOf: getAnyFixtureDICOMURL())

        let spacing = decoder.pixelSpacingV2
        let settings = decoder.windowSettingsV2
        let parameters = decoder.rescaleParametersV2

        let encoder = JSONEncoder()
        let jsonDecoder = JSONDecoder()

        let spacingData = try encoder.encode(spacing)
        let spacingDecoded = try jsonDecoder.decode(PixelSpacing.self, from: spacingData)
        XCTAssertEqual(spacing, spacingDecoded, "PixelSpacing should encode/decode correctly")

        let settingsData = try encoder.encode(settings)
        let settingsDecoded = try jsonDecoder.decode(WindowSettings.self, from: settingsData)
        XCTAssertEqual(settings, settingsDecoded, "WindowSettings should encode/decode correctly")

        let parametersData = try encoder.encode(parameters)
        let parametersDecoded = try jsonDecoder.decode(RescaleParameters.self, from: parametersData)
        XCTAssertEqual(parameters, parametersDecoded, "RescaleParameters should encode/decode correctly")
    }
}
