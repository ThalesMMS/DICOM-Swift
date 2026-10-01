//
//  DicomUltrasoundRegionTests.swift
//  DicomCoreTests
//

import Foundation
import XCTest
@testable import DicomCore

final class DicomUltrasoundRegionTests: XCTestCase {
    func testUltrasoundRegionsParsesDualRegionCalibration() throws {
        let tissue = regionDataSet(
            bounds: (0, 0, 255, 511),
            spatialFormat: 1,
            dataType: 1,
            unitX: 3,
            unitY: 3,
            deltaX: 0.02,
            deltaY: 0.02
        )
        let doppler = regionDataSet(
            bounds: (256, 0, 511, 511),
            spatialFormat: 3,
            dataType: 5,
            unitX: 4,
            unitY: 7,
            deltaX: 0.001,
            deltaY: -0.5
        )
        var dataSet = imageDataSet()
        dataSet.set(DicomDataElement(
            tag: 0x00186011,
            vr: .SQ,
            value: .sequence([
                DicomSequenceItem(dataSet: tissue),
                DicomSequenceItem(dataSet: doppler)
            ])
        ))

        let regions = try open(dataSet).ultrasoundRegions()

        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions[0].minX0, 0)
        XCTAssertEqual(regions[0].maxY1, 511)
        XCTAssertEqual(regions[0].spatialFormat, 1)
        XCTAssertEqual(regions[0].dataType, 1)
        XCTAssertEqual(regions[0].physicalUnitX, .centimeters)
        XCTAssertEqual(regions[0].physicalUnitY, .centimeters)
        XCTAssertEqual(regions[0].physicalDeltaX, 0.02)
        XCTAssertEqual(regions[0].physicalDeltaY, 0.02)
        XCTAssertEqual(regions[1].minX0, 256)
        XCTAssertEqual(regions[1].physicalUnitX, .seconds)
        XCTAssertEqual(regions[1].physicalUnitY, .centimetersPerSecond)
        XCTAssertEqual(regions[1].physicalDeltaY, -0.5)
    }

    func testPhysicalUnitMappingCoversStandardCodesAndPreservesUnknownValues() {
        let expected: [DicomUltrasoundPhysicalUnit] = [
            .none,
            .percent,
            .decibels,
            .centimeters,
            .seconds,
            .hertz,
            .decibelsPerSecond,
            .centimetersPerSecond,
            .squareCentimeters,
            .squareCentimetersPerSecond,
            .cubicCentimeters,
            .cubicCentimetersPerSecond,
            .degrees
        ]

        XCTAssertEqual((0...12).map(DicomUltrasoundPhysicalUnit.init(code:)), expected)
        XCTAssertEqual(DicomUltrasoundPhysicalUnit(code: 99), .other(99))
    }

    func testUltrasoundRegionsSkipsMalformedBoundsWithoutDroppingValidItems() throws {
        let malformed = regionDataSet(
            bounds: (20, 0, 10, 20),
            spatialFormat: 1,
            dataType: 1,
            unitX: 3,
            unitY: 3,
            deltaX: 0.1,
            deltaY: 0.1
        )
        let valid = regionDataSet(
            bounds: (0, 0, 10, 20),
            spatialFormat: 2,
            dataType: 1,
            unitX: 4,
            unitY: 3,
            deltaX: 0.01,
            deltaY: 0.1
        )
        var dataSet = imageDataSet()
        dataSet.set(DicomDataElement(
            tag: 0x00186011,
            vr: .SQ,
            value: .sequence([
                DicomSequenceItem(dataSet: malformed),
                DicomSequenceItem(dataSet: valid)
            ])
        ))

        let regions = try open(dataSet).ultrasoundRegions()

        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].spatialFormat, 2)
    }

    func testUltrasoundRegionsParsesDopplerReferenceAndFlags() throws {
        var doppler = regionDataSet(
            bounds: (100, 50, 200, 150),
            spatialFormat: 3,
            dataType: 5,
            unitX: 4,
            unitY: 7,
            deltaX: 0.01,
            deltaY: -2
        )
        doppler.set(unsignedLong(0x00186016, 4))
        doppler.set(signedLong(0x00186020, 10))
        doppler.set(signedLong(0x00186022, 20))
        doppler.set(DicomDataElement(tag: 0x00186028, vr: .FD, value: .floats([0.5])))
        doppler.set(DicomDataElement(tag: 0x0018602A, vr: .FD, value: .floats([-20])))
        var dataSet = imageDataSet()
        dataSet.set(sequence(0x00186011, [doppler]))

        let region = try XCTUnwrap(open(dataSet).ultrasoundRegions().first)

        XCTAssertEqual(region.regionFlags, 4)
        XCTAssertEqual(region.referencePixelX0, 10)
        XCTAssertEqual(region.referencePixelY0, 20)
        XCTAssertEqual(region.referencePixelPhysicalValueX, 0.5)
        XCTAssertEqual(region.referencePixelPhysicalValueY, -20)
    }

    func testUltrasoundRegionsForFramePrefersFrameThenSharedThenLegacy() throws {
        let legacy = regionDataSet(bounds: (0, 0, 10, 10), spatialFormat: 1, dataType: 1,
                                   unitX: 3, unitY: 3, deltaX: 0.1, deltaY: 0.1)
        let shared = regionDataSet(bounds: (20, 0, 30, 10), spatialFormat: 1, dataType: 1,
                                   unitX: 3, unitY: 3, deltaX: 0.2, deltaY: 0.2)
        let frame = regionDataSet(bounds: (40, 0, 50, 10), spatialFormat: 3, dataType: 5,
                                  unitX: 4, unitY: 7, deltaX: 0.01, deltaY: -1)
        var dataSet = imageDataSet()
        dataSet.set(sequence(0x00186011, [legacy]))
        dataSet.set(sequence(DicomTag.sharedFunctionalGroupsSequence.rawValue, [
            DicomDataSet(elements: [sequence(0x00186011, [shared])])
        ]))
        dataSet.set(sequence(DicomTag.perFrameFunctionalGroupsSequence.rawValue, [
            DicomDataSet(elements: [sequence(0x00186011, [frame])]),
            DicomDataSet()
        ]))
        let decoder = try open(dataSet)

        XCTAssertEqual(decoder.ultrasoundRegions(forFrame: 0).first?.minX0, 40)
        XCTAssertEqual(decoder.ultrasoundRegions(forFrame: 1).first?.minX0, 20)
        XCTAssertEqual(decoder.ultrasoundRegions(forFrame: 2).first?.minX0, 20)
        XCTAssertEqual(decoder.ultrasoundRegions().first?.minX0, 0)
    }

    private func regionDataSet(
        bounds: (minX: Int, minY: Int, maxX: Int, maxY: Int),
        spatialFormat: Int,
        dataType: Int,
        unitX: Int,
        unitY: Int,
        deltaX: Double,
        deltaY: Double
    ) -> DicomDataSet {
        DicomDataSet(elements: [
            unsignedShort(0x00186012, spatialFormat),
            unsignedShort(0x00186014, dataType),
            unsignedLong(0x00186018, bounds.minX),
            unsignedLong(0x0018601A, bounds.minY),
            unsignedLong(0x0018601C, bounds.maxX),
            unsignedLong(0x0018601E, bounds.maxY),
            unsignedShort(0x00186024, unitX),
            unsignedShort(0x00186026, unitY),
            DicomDataElement(tag: 0x0018602C, vr: .FD, value: .floats([deltaX])),
            DicomDataElement(tag: 0x0018602E, vr: .FD, value: .floats([deltaY]))
        ])
    }

    private func imageDataSet() -> DicomDataSet {
        DicomDataSet(elements: [
            DicomDataElement(
                tag: DicomTag.sopClassUID.rawValue,
                vr: .UI,
                value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])
            ),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.1524001"])),
            unsignedShort(DicomTag.rows.rawValue, 512),
            unsignedShort(DicomTag.columns.rawValue, 512),
            unsignedShort(DicomTag.samplesPerPixel.rawValue, 1),
            DicomDataElement(
                tag: DicomTag.photometricInterpretation.rawValue,
                vr: .CS,
                value: .strings(["MONOCHROME2"])
            ),
            unsignedShort(DicomTag.bitsAllocated.rawValue, 8),
            unsignedShort(DicomTag.bitsStored.rawValue, 8),
            unsignedShort(DicomTag.highBit.rawValue, 7),
            unsignedShort(DicomTag.pixelRepresentation.rawValue, 0),
            DicomDataElement(
                tag: DicomTag.pixelData.rawValue,
                vr: .OB,
                value: .bytes(Data(repeating: 0, count: 512 * 512))
            )
        ])
    }

    private func open(_ dataSet: DicomDataSet) throws -> DCMDecoder {
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .explicitVRLittleEndian,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.1524001"
            )
        )
        return try DCMDecoder(data: data)
    }

    private func unsignedShort(_ tag: Int, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: .US, value: .unsignedIntegers([UInt(value)]))
    }

    private func unsignedLong(_ tag: Int, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: .UL, value: .unsignedIntegers([UInt(value)]))
    }

    private func signedLong(_ tag: Int, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: .SL, value: .signedIntegers([value]))
    }

    private func sequence(_ tag: Int, _ dataSets: [DicomDataSet]) -> DicomDataElement {
        DicomDataElement(
            tag: tag,
            vr: .SQ,
            value: .sequence(dataSets.map(DicomSequenceItem.init(dataSet:)))
        )
    }
}
