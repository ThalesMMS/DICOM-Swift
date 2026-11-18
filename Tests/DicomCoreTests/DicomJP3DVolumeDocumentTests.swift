//
//  DicomJP3DVolumeDocumentTests.swift
//  DicomCoreTests
//
//  Checks synthetic multicomponent JP3D volume decoding through the document API.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
import XCTest
import DicomTestSupport
@testable import DicomCore
import simd

final class DicomJP3DVolumeDocumentTests: XCTestCase {
    func testDocumentDecodesSyntheticMultiComponentVolume() throws {
        try DicomTestRuntimePreflight.require(.openJPEG)

        let planes: [[UInt16]] = [
            [10, 20, 30, 40],
            [110, 120, 130, 140],
            [210, 220, 230, 240]
        ]
        let encoded = try makeOpenJPEGLosslessCodestream16(width: 2, height: 2, planes: planes)
        let geometry = DicomJP3DVolumeGeometry(
            dimensions: DicomSeriesDimensions(width: 2, height: 2, depth: 3),
            spacing: SIMD3<Double>(0.5, 0.75, 1.25),
            orientation: matrix_identity_double3x3,
            origin: SIMD3<Double>(10, 20, 30),
            rescaleSlope: 1,
            rescaleIntercept: -100,
            bitsAllocated: 16,
            isSignedPixel: false,
            patientName: "JP3D^Fixture",
            seriesDescription: "Synthetic JP3D volume",
            modality: "CT",
            windowCenter: 40,
            windowWidth: 400,
            studyInstanceUID: "1.2.3",
            seriesInstanceUID: "1.2.3.4",
            frameOfReferenceUID: "1.2.3.4.5"
        )

        let document = try DicomJP3DVolumeDocument(
            compressedData: encoded,
            transferSyntax: .jpeg2000Part2MulticomponentLossless,
            geometry: geometry
        )
        let volume = try document.decodedVolume()
        let decoded = try document.decodedSeries()

        XCTAssertEqual(volume.width, 2)
        XCTAssertEqual(volume.height, 2)
        XCTAssertEqual(volume.depth, 3)
        XCTAssertEqual(volume.spacing, SIMD3<Double>(0.5, 0.75, 1.25))
        XCTAssertEqual(volume.origin, SIMD3<Double>(10, 20, 30))
        XCTAssertEqual(volume.patientName, "JP3D^Fixture")
        XCTAssertEqual(volume.seriesDescription, "Synthetic JP3D volume")
        XCTAssertEqual(volume.modality, "CT")
        XCTAssertEqual(littleEndianUInt16Values(volume.voxels), planes.flatMap { $0 })
        XCTAssertEqual(decoded.dimensions, DicomSeriesDimensions(width: 2, height: 2, depth: 3))
        XCTAssertEqual(decoded.modalityIntensityRange, -90...140)
        XCTAssertEqual(decoded.recommendedWindow, -160...239)
    }

    func testDocumentReadsEncapsulatedDicomObject() throws {
        try DicomTestRuntimePreflight.require(.openJPEG)

        let planes: [[UInt16]] = [
            [1, 2, 3, 4],
            [11, 12, 13, 14],
            [21, 22, 23, 24]
        ]
        let encoded = try makeOpenJPEGLosslessCodestream16(width: 2, height: 2, planes: planes)
        let url = try makeTemporaryJP3DDicom(frame: encoded)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try DicomJP3DVolumeDocument(contentsOf: url)
        let volume = try document.decodedVolume()

        XCTAssertEqual(document.transferSyntax, .jpeg2000Part2MulticomponentLossless)
        XCTAssertEqual(volume.width, 2)
        XCTAssertEqual(volume.height, 2)
        XCTAssertEqual(volume.depth, 3)
        XCTAssertEqual(volume.studyInstanceUID, "1.2.826.0.1.3680043.10.231.1")
        XCTAssertEqual(volume.seriesInstanceUID, "1.2.826.0.1.3680043.10.231.2")
        XCTAssertEqual(volume.frameOfReferenceUID, "1.2.826.0.1.3680043.10.231.3")
        XCTAssertEqual(littleEndianUInt16Values(volume.voxels), planes.flatMap { $0 })
    }

    private func makeOpenJPEGLosslessCodestream16(width: Int, height: Int, planes: [[UInt16]]) throws -> Data {
        XCTAssertFalse(planes.isEmpty)
        for plane in planes {
            XCTAssertEqual(plane.count, width * height)
        }
        let executable = try DicomTestRuntimePreflight.requireExecutable(.opjCompress, named: "opj_compress")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jp3d_fixture_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.ppm")
        let encodedURL = directory.appendingPathComponent("source.j2k")
        var source = Data("P6\n\(width) \(height)\n65535\n".utf8)
        for pixelIndex in 0..<(width * height) {
            for plane in planes {
                let pixel = plane[pixelIndex]
                source.append(UInt8(pixel >> 8))
                source.append(UInt8(pixel & 0xFF))
            }
        }
        try source.write(to: sourceURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-i", sourceURL.path, "-o", encodedURL.path, "-n", "1", "-mct", "0"]
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"
            XCTFail("opj_compress failed: \(error)")
            return Data()
        }
        return try Data(contentsOf: encodedURL)
    }

    private func makeTemporaryJP3DDicom(frame: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jp3d_volume_\(UUID().uuidString).dcm")
        var data = Data(count: 128)
        data.append(contentsOf: "DICM".utf8)

        appendElement(tag: DicomTag.transferSyntaxUID.rawValue, vr: "UI", value: ui(DicomTransferSyntax.jpeg2000Part2MulticomponentLossless.rawValue), to: &data)
        appendElement(tag: DicomTag.samplesPerPixel.rawValue, vr: "US", value: uint16Data(1), to: &data)
        appendElement(tag: DicomTag.photometricInterpretation.rawValue, vr: "CS", value: stringData("MONOCHROME2", padding: 0x20), to: &data)
        appendElement(tag: DicomTag.numberOfFrames.rawValue, vr: "IS", value: stringData("3", padding: 0x20), to: &data)
        appendElement(tag: DicomTag.rows.rawValue, vr: "US", value: uint16Data(2), to: &data)
        appendElement(tag: DicomTag.columns.rawValue, vr: "US", value: uint16Data(2), to: &data)
        appendElement(tag: DicomTag.pixelSpacing.rawValue, vr: "DS", value: stringData("0.75\\0.5", padding: 0x20), to: &data)
        appendElement(tag: DicomTag.sliceThickness.rawValue, vr: "DS", value: stringData("1.25", padding: 0x20), to: &data)
        appendElement(tag: DicomTag.imagePositionPatient.rawValue, vr: "DS", value: stringData("10\\20\\30", padding: 0x20), to: &data)
        appendElement(tag: DicomTag.imageOrientationPatient.rawValue, vr: "DS", value: stringData("1\\0\\0\\0\\1\\0", padding: 0x20), to: &data)
        appendElement(tag: DicomTag.bitsAllocated.rawValue, vr: "US", value: uint16Data(16), to: &data)
        appendElement(tag: DicomTag.bitsStored.rawValue, vr: "US", value: uint16Data(16), to: &data)
        appendElement(tag: DicomTag.highBit.rawValue, vr: "US", value: uint16Data(15), to: &data)
        appendElement(tag: DicomTag.pixelRepresentation.rawValue, vr: "US", value: uint16Data(0), to: &data)
        appendElement(tag: DicomTag.patientName.rawValue, vr: "PN", value: stringData("JP3D^Fixture", padding: 0x20), to: &data)
        appendElement(tag: DicomTag.modality.rawValue, vr: "CS", value: stringData("CT", padding: 0x20), to: &data)
        appendElement(tag: DicomTag.seriesDescription.rawValue, vr: "LO", value: stringData("JP3D fixture", padding: 0x20), to: &data)
        appendElement(tag: DicomTag.studyInstanceUID.rawValue, vr: "UI", value: ui("1.2.826.0.1.3680043.10.231.1"), to: &data)
        appendElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: "UI", value: ui("1.2.826.0.1.3680043.10.231.2"), to: &data)
        appendElement(tag: 0x0020_0052, vr: "UI", value: ui("1.2.826.0.1.3680043.10.231.3"), to: &data)
        appendPixelData(makeEncapsulatedPixelData(frame: frame), to: &data)

        try data.write(to: url)
        return url
    }

    private func makeEncapsulatedPixelData(frame: Data) -> Data {
        var data = Data()
        appendItem(Data(), to: &data)
        appendItem(frame, to: &data)
        appendTag(0xFFFEE0DD, to: &data)
        appendUInt32(0, to: &data)
        return data
    }

    private func appendPixelData(_ value: Data, to data: inout Data) {
        appendTag(DicomTag.pixelData.rawValue, to: &data)
        data.append(contentsOf: "OB".utf8)
        data.append(contentsOf: [0x00, 0x00])
        appendUInt32(0xFFFFFFFF, to: &data)
        data.append(value)
    }

    private func appendElement(tag: Int, vr: String, value: Data, to data: inout Data) {
        appendTag(tag, to: &data)
        data.append(contentsOf: vr.utf8)
        if ["OB", "OW", "OV", "SQ", "UN", "UT"].contains(vr) {
            data.append(contentsOf: [0x00, 0x00])
            appendUInt32(UInt32(value.count), to: &data)
        } else {
            appendUInt16(UInt16(value.count), to: &data)
        }
        data.append(value)
    }

    private func appendItem(_ value: Data, to data: inout Data) {
        appendTag(0xFFFEE000, to: &data)
        appendUInt32(UInt32(value.count), to: &data)
        data.append(value)
    }

    private func appendTag(_ tag: Int, to data: inout Data) {
        appendUInt16(UInt16((tag >> 16) & 0xFFFF), to: &data)
        appendUInt16(UInt16(tag & 0xFFFF), to: &data)
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private func uint16Data(_ value: UInt16) -> Data {
        var data = Data()
        appendUInt16(value, to: &data)
        return data
    }

    private func ui(_ value: String) -> Data {
        stringData(value, padding: 0x00)
    }

    private func stringData(_ value: String, padding: UInt8) -> Data {
        var data = Data(value.utf8)
        if data.count % 2 != 0 {
            data.append(padding)
        }
        return data
    }

    private func littleEndianUInt16Values(_ data: Data) -> [UInt16] {
        stride(from: 0, to: data.count, by: 2).map { offset in
            UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
    }
}
