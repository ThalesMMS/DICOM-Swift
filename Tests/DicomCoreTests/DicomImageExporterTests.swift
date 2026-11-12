//
//  DicomImageExporterTests.swift
//  DicomCoreTests
//
//  Checks exported frame names, privacy-safe metadata sidecars, and native 16-bit TIFF precision.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import CoreGraphics
import ImageIO
import XCTest
@testable import DicomCore

final class DicomImageExporterTests: XCTestCase {
    func testExportsSingleFramePNGAndJPEG() throws {
        let url = try makeTemporaryDICOM(
            pixelValues: [0, 100, 200, 300],
            rows: 2,
            columns: 2
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let directory = try temporaryDirectory()

        let pngURL = directory.appendingPathComponent("frame.png")
        let jpegURL = directory.appendingPathComponent("frame.jpg")

        _ = try decoder.exportImage(to: pngURL, options: DicomImageExportOptions(format: .png, overwrite: true))
        _ = try decoder.exportImage(to: jpegURL, options: DicomImageExportOptions(format: .jpeg, quality: 0.85, overwrite: true))

        XCTAssertEqual(try imageDimensions(at: pngURL), ImageDimensions(width: 2, height: 2))
        XCTAssertEqual(try imageDimensions(at: jpegURL), ImageDimensions(width: 2, height: 2))
    }

    func testExportAllFramesUsesPredictableNamesAndNonPHIMetadataSidecars() throws {
        let url = try makeTemporaryDICOM(
            pixelValues: [0, 100, 200, 300, 400, 500],
            rows: 1,
            columns: 2,
            frames: 3,
            extraElements: [
                string(.patientName, vr: .PN, "Private^Patient"),
                string(.patientID, vr: .LO, "PATIENT-42")
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let directory = try temporaryDirectory()
        let results = try decoder.exportAllFrames(
            to: directory,
            baseName: "series",
            options: DicomImageExportOptions(
                format: .png,
                overwrite: true,
                metadataPolicy: .nonPHISidecar
            )
        )

        XCTAssertEqual(results.map { $0.imageURL.lastPathComponent }, [
            "series_frame0001.png",
            "series_frame0002.png",
            "series_frame0003.png"
        ])
        XCTAssertEqual(results.map(\.frameIndex), [0, 1, 2])

        let metadataURL = try XCTUnwrap(results.first?.metadataURL)
        let metadataData = try Data(contentsOf: metadataURL)
        let metadataText = String(decoding: metadataData, as: UTF8.self)
        let metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: metadataData) as? [String: Any]
        )

        XCTAssertEqual(metadata["frameIndex"] as? Int, 0)
        XCTAssertEqual(metadata["frameNumber"] as? Int, 1)
        XCTAssertEqual(metadata["numberOfFrames"] as? Int, 3)
        XCTAssertEqual(metadata["modality"] as? String, "CT")
        XCTAssertFalse(metadataText.contains("Private^Patient"))
        XCTAssertFalse(metadataText.contains("PATIENT-42"))
    }

    func testNative16BitTIFFPreservesComponentDepth() throws {
        let url = try makeTemporaryDICOM(
            pixelValues: [1, 255, 4096, UInt16.max],
            rows: 2,
            columns: 2
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let outputURL = try temporaryDirectory().appendingPathComponent("native.tiff")

        _ = try decoder.exportImage(
            to: outputURL,
            options: DicomImageExportOptions(
                format: .tiff,
                overwrite: true,
                pixelMode: .native16Bit
            )
        )

        let image = try cgImage(at: outputURL)
        XCTAssertEqual(image.bitsPerComponent, 16)
        XCTAssertEqual(image.bitsPerPixel, 16)
    }

    func testNative16BitExportRejectsNonTIFFFormats() throws {
        let url = try makeTemporaryDICOM(pixelValues: [1], rows: 1, columns: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let outputURL = try temporaryDirectory().appendingPathComponent("native.png")

        XCTAssertThrowsError(
            try decoder.exportImage(
                to: outputURL,
                options: DicomImageExportOptions(
                    format: .png,
                    overwrite: true,
                    pixelMode: .native16Bit
                )
            )
        ) { error in
            guard case DicomImageExportError.unsupportedPixelMode = error else {
                XCTFail("Expected unsupported pixel mode error, got \(error)")
                return
            }
        }
    }

    private func makeTemporaryDICOM(
        pixelValues: [UInt16],
        rows: Int,
        columns: Int,
        frames: Int = 1,
        extraElements: [DicomDataElement] = []
    ) throws -> URL {
        XCTAssertEqual(pixelValues.count, rows * columns * frames)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("image_export_\(UUID().uuidString).dcm")

        var elements: [DicomDataElement] = [
            string(0x00080016, vr: .UI, DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, "1.2.826.0.1.3680043.10.225.\(Int.random(in: 1...999999))"),
            string(.modality, vr: .CS, "CT"),
            us(.samplesPerPixel, 1),
            string(.photometricInterpretation, vr: .CS, "MONOCHROME2"),
            us(.rows, rows),
            us(.columns, columns),
            us(.bitsAllocated, 16),
            us(.bitsStored, 16),
            us(.highBit, 15),
            us(.pixelRepresentation, 0),
            ds(.windowCenter, ["250"]),
            ds(.windowWidth, ["500"]),
            bytes(.pixelData, vr: .OW, Data(littleEndianBytes(values: pixelValues)))
        ]

        if frames > 1 {
            let pixelDataIndex = elements.firstIndex { $0.tag == DicomTag.pixelData.rawValue } ?? elements.count
            elements.insert(string(.numberOfFrames, vr: .IS, String(frames)), at: pixelDataIndex)
        }

        let dataSet = DicomDataSet(elements: elements + extraElements)
        let data = try DicomDataSetWriter.part10Data(from: dataSet)
        try data.write(to: url)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dicom-image-export-\(UUID().uuidString)", isDirectory: true)
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

    private func imageDimensions(at url: URL) throws -> ImageDimensions {
        let image = try cgImage(at: url)
        return ImageDimensions(width: image.width, height: image.height)
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

    private func ds(_ tag: DicomTag, _ values: [String]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .DS, value: .strings(values))
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

private struct ImageDimensions: Equatable {
    let width: Int
    let height: Int
}
