//
//  DicomImagePreprocessorTests.swift
//  DicomCoreTests
//
//  Checks custom windowing and use of preprocessing resize options during export.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import CoreGraphics
import ImageIO
import XCTest
@testable import DicomCore

final class DicomImagePreprocessorTests: XCTestCase {
    func testRenderAppliesCustomWindow() throws {
        let url = try makeTemporaryDICOM(pixelValues: [0, 50, 100], rows: 1, columns: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let bitmap = try DicomImagePreprocessor().render(
            decoder: decoder,
            options: DicomImagePreprocessOptions(
                displaySelection: .customWindow(WindowSettings(center: 50, width: 100))
            )
        )

        XCTAssertEqual(bitmap.pixel(x: 0, y: 0), DicomRGBPixel(red: 0, green: 0, blue: 0))
        XCTAssertEqual(bitmap.pixel(x: 1, y: 0), DicomRGBPixel(red: 128, green: 128, blue: 128))
        XCTAssertEqual(bitmap.pixel(x: 2, y: 0), DicomRGBPixel(red: 255, green: 255, blue: 255))
    }

    func testRenderResizesBitmap() throws {
        let url = try makeTemporaryDICOM(pixelValues: [0, 0, 100, 100], rows: 2, columns: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let bitmap = try DicomImagePreprocessor().render(
            decoder: decoder,
            options: DicomImagePreprocessOptions(
                displaySelection: .customWindow(WindowSettings(center: 50, width: 100)),
                outputSize: DicomImageSize(width: 4, height: 4)
            )
        )

        XCTAssertEqual(bitmap.width, 4)
        XCTAssertEqual(bitmap.height, 4)
        XCTAssertEqual(bitmap.pixel(x: 0, y: 0), DicomRGBPixel(red: 0, green: 0, blue: 0))
        XCTAssertEqual(bitmap.pixel(x: 3, y: 3), DicomRGBPixel(red: 255, green: 255, blue: 255))
    }

    func testRenderBurnsSyntheticLineOverlay() throws {
        let url = try makeTemporaryDICOM(pixelValues: [0, 0, 0, 0], rows: 2, columns: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let bitmap = try DicomImagePreprocessor().render(
            decoder: decoder,
            options: DicomImagePreprocessOptions(
                displaySelection: .customWindow(WindowSettings(center: 50, width: 100)),
                outputSize: DicomImageSize(width: 4, height: 4),
                annotations: [
                    .line(
                        start: DicomNormalizedImagePoint(x: 0, y: 0),
                        end: DicomNormalizedImagePoint(x: 1, y: 1),
                        color: .red,
                        thickness: 1
                    )
                ]
            )
        )

        XCTAssertEqual(bitmap.pixel(x: 0, y: 0), DicomRGBPixel(red: 255, green: 0, blue: 0))
        XCTAssertEqual(bitmap.pixel(x: 3, y: 3), DicomRGBPixel(red: 255, green: 0, blue: 0))
    }

    func testExporterUsesPreprocessorResizeOptions() throws {
        let url = try makeTemporaryDICOM(pixelValues: [0, 0, 100, 100], rows: 2, columns: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let outputURL = try temporaryDirectory().appendingPathComponent("resized.png")

        _ = try decoder.exportImage(
            to: outputURL,
            options: DicomImageExportOptions(
                format: .png,
                overwrite: true,
                pixelMode: .display8(selection: .customWindow(WindowSettings(center: 50, width: 100))),
                outputSize: DicomImageSize(width: 4, height: 4),
                annotations: [
                    .rectangle(
                        rect: DicomNormalizedImageRect(x: 0, y: 0, width: 1, height: 1),
                        color: .green,
                        thickness: 1
                    )
                ]
            )
        )

        let image = try cgImage(at: outputURL)
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 4)
    }

    private func makeTemporaryDICOM(pixelValues: [UInt16], rows: Int, columns: Int) throws -> URL {
        XCTAssertEqual(pixelValues.count, rows * columns)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("image_preprocess_\(UUID().uuidString).dcm")
        let dataSet = DicomDataSet(elements: [
            string(0x00080016, vr: .UI, DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, "1.2.826.0.1.3680043.10.226.\(Int.random(in: 1...999999))"),
            string(.modality, vr: .CS, "CT"),
            us(.samplesPerPixel, 1),
            string(.photometricInterpretation, vr: .CS, "MONOCHROME2"),
            us(.rows, rows),
            us(.columns, columns),
            us(.bitsAllocated, 16),
            us(.bitsStored, 16),
            us(.highBit, 15),
            us(.pixelRepresentation, 0),
            bytes(.pixelData, vr: .OW, Data(littleEndianBytes(values: pixelValues)))
        ])

        let data = try DicomDataSetWriter.part10Data(from: dataSet)
        try data.write(to: url)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dicom-image-preprocess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func cgImage(at url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func string(_ tag: DicomTag, vr: DicomVR, _ value: String) -> DicomDataElement {
        string(tag.rawValue, vr: vr, value)
    }

    private func string(_ tag: Int, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
    }

    private func us(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([UInt(value)]))
    }

    private func bytes(_ tag: DicomTag, vr: DicomVR, _ value: Data) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .bytes(value))
    }

    private func littleEndianBytes(values: [UInt16]) -> [UInt8] {
        values.flatMap { value -> [UInt8] in
            let little = value.littleEndian
            return [UInt8(truncatingIfNeeded: little), UInt8(truncatingIfNeeded: little >> 8)]
        }
    }
}
