//
//  DicomSeriesLoaderCompressedTests.swift
//  DicomCoreTests
//
//  Volume assembly from compressed slices (issue #1233): JPEG Lossless CT-like series decode
//  through the production frame reader with the same geometry, rescale, ordering, and voxel
//  semantics as uncompressed series; unsupported compressed syntaxes fail typed per slice with the
//  transfer syntax and pixel metadata attached.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
import XCTest
import DicomTestSupport
@testable import DicomCore

final class DicomSeriesLoaderCompressedTests: XCTestCase {
    // MARK: - Compressed CT-like series assembles a volume

    func testJPEGLosslessSignedSeriesAssemblesVolumeWithGeometryAndRescale() throws {
        let directory = try Self.makeSeriesDirectory(compressed: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let volume = try DicomSeriesLoader().loadSeries(in: directory)

        XCTAssertEqual(volume.width, 4)
        XCTAssertEqual(volume.height, 4)
        XCTAssertEqual(volume.depth, 3)
        XCTAssertTrue(volume.isSignedPixel)
        XCTAssertEqual(volume.spacing.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(volume.spacing.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(volume.spacing.z, 2.5, accuracy: 1e-9)
        XCTAssertEqual(volume.rescaleSlope, 1.0, accuracy: 1e-9)
        XCTAssertEqual(volume.rescaleIntercept, -1024.0, accuracy: 1e-9)
        XCTAssertEqual(volume.sliceRescaleParameters.count, 3)
        for parameters in volume.sliceRescaleParameters {
            XCTAssertEqual(parameters.slope, 1.0, accuracy: 1e-9)
            XCTAssertEqual(parameters.intercept, -1024.0, accuracy: 1e-9)
        }

        let voxels = volume.voxels.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(voxels, Self.expectedStoredVoxels(), "decoded compressed voxels must be stored values in IPP order")
    }

    /// Compressed and equivalent uncompressed fixtures must produce
    /// byte-identical volumes (voxels, geometry, rescale).
    func testCompressedAndUncompressedSeriesProduceIdenticalVolumes() throws {
        let compressedDirectory = try Self.makeSeriesDirectory(compressed: true)
        defer { try? FileManager.default.removeItem(at: compressedDirectory) }
        let nativeDirectory = try Self.makeSeriesDirectory(compressed: false)
        defer { try? FileManager.default.removeItem(at: nativeDirectory) }

        let compressed = try DicomSeriesLoader().loadSeries(in: compressedDirectory)
        let native = try DicomSeriesLoader().loadSeries(in: nativeDirectory)

        XCTAssertEqual(compressed.voxels, native.voxels, "compressed volume voxels must match the uncompressed parity series")
        XCTAssertEqual(
            ClinicalParityCuratedFixtureTests.pixelHash([UInt8](compressed.voxels)),
            ClinicalParityCuratedFixtureTests.pixelHash([UInt8](native.voxels)),
            "volume hashes must match between compressed and uncompressed fixtures"
        )
        XCTAssertEqual(compressed.spacing, native.spacing)
        XCTAssertEqual(compressed.origin, native.origin)
        XCTAssertEqual(compressed.orientation, native.orientation)
        XCTAssertEqual(compressed.rescaleSlope, native.rescaleSlope)
        XCTAssertEqual(compressed.rescaleIntercept, native.rescaleIntercept)
        XCTAssertEqual(compressed.sliceRescaleParameters, native.sliceRescaleParameters)
    }

    // MARK: - Typed failures carry transfer syntax and pixel metadata

    func testCompressedSyntaxWithoutDecodeBackendFailsTypedWithMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("series-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .mpeg2MainProfileMainLevel,
            fragments: [Data([0x00, 0x00, 0x01, 0xB3])],
            declaredFrames: 1,
            rows: 4,
            columns: 4
        )
        try file.write(to: directory.appendingPathComponent("slice000.dcm"))

        XCTAssertThrowsError(try DicomSeriesLoader().loadSeries(in: directory)) { error in
            guard case DicomSeriesLoaderError.unsupportedTransferSyntaxForVolume(let format) = error else {
                return XCTFail("expected unsupportedTransferSyntaxForVolume, got \(error)")
            }
            XCTAssertEqual(format.transferSyntaxUID, DicomTransferSyntax.mpeg2MainProfileMainLevel.rawValue)
            XCTAssertEqual(format.bitsAllocated, 8)
            XCTAssertEqual(format.samplesPerPixel, 1)
            XCTAssertTrue(format.isCompressed)
        }
    }

    func testSupportMatrixDeclaresCompressedVolumeSupport() {
        XCTAssertTrue(DicomSeriesLoaderSupportMatrix.standard.supportsCompressedTransferSyntaxes)
    }

    // MARK: - Deterministic series builders (non-PHI)

    /// Stored Int16 slice values: slice k pixel p = sliceBase[k] + p.
    private static let sliceBases: [Int] = [-1000, -500, 0]

    private static func expectedStoredVoxels() -> [Int16] {
        var voxels = [Int16]()
        for base in sliceBases {
            for pixel in 0..<16 {
                voxels.append(Int16(base + pixel))
            }
        }
        return voxels
    }

    private static func makeSeriesDirectory(compressed: Bool) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("series-\(compressed ? "jll" : "native")-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (sliceIndex, base) in sliceBases.enumerated() {
            let storedPatterns = (0..<16).map { UInt16(bitPattern: Int16(base + $0)) }
            let fileData: Data
            if compressed {
                let codestream = makeJPEGLosslessStream(
                    planes: [storedPatterns.map(Int.init)],
                    width: 4,
                    height: 4,
                    precision: 16
                )
                var dataSet = EncapsulatedFixtureFactory.makeDataSet(
                    transferSyntax: .jpegLosslessFirstOrder,
                    fragments: [codestream],
                    declaredFrames: 1,
                    rows: 4,
                    columns: 4,
                    bitsAllocated: 16,
                    bitsStored: 16,
                    highBit: 15,
                    pixelRepresentation: 1
                )
                appendGeometry(to: &dataSet, sliceIndex: sliceIndex)
                fileData = try DicomDataSetWriter.part10Data(
                    from: dataSet,
                    options: DicomPart10WriterOptions(
                        transferSyntax: .jpegLosslessFirstOrder,
                        mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                        mediaStorageSOPInstanceUID: "2.25.1233000\(sliceIndex + 1)"
                    )
                )
            } else {
                var pixelData = Data()
                for pattern in storedPatterns {
                    pixelData.append(UInt8(pattern & 0xFF))
                    pixelData.append(UInt8(pattern >> 8))
                }
                var dataSet = EncapsulatedFixtureFactory.makeDataSet(
                    transferSyntax: .explicitVRLittleEndian,
                    fragments: [],
                    declaredFrames: 1,
                    rows: 4,
                    columns: 4,
                    bitsAllocated: 16,
                    bitsStored: 16,
                    highBit: 15,
                    pixelRepresentation: 1
                )
                dataSet.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(pixelData)))
                appendGeometry(to: &dataSet, sliceIndex: sliceIndex)
                fileData = try DicomDataSetWriter.part10Data(
                    from: dataSet,
                    options: DicomPart10WriterOptions(
                        transferSyntax: .explicitVRLittleEndian,
                        mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                        mediaStorageSOPInstanceUID: "2.25.1233000\(sliceIndex + 1)"
                    )
                )
            }
            try fileData.write(to: directory.appendingPathComponent(String(format: "slice%03d.dcm", sliceIndex)))
        }
        return directory
    }

    private static func appendGeometry(to dataSet: inout DicomDataSet, sliceIndex: Int) {
        dataSet.set(DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI,
                                     value: .strings(["2.25.1233000\(sliceIndex + 1)"])))
        dataSet.set(DicomDataElement(tag: DicomTag.instanceNumber.rawValue, vr: .IS,
                                     value: .strings(["\(sliceIndex + 1)"])))
        dataSet.set(DicomDataElement(tag: DicomTag.imagePositionPatient.rawValue, vr: .DS,
                                     value: .strings(["0", "0", String(format: "%.1f", Double(sliceIndex) * 2.5)])))
        dataSet.set(DicomDataElement(tag: DicomTag.imageOrientationPatient.rawValue, vr: .DS,
                                     value: .strings(["1", "0", "0", "0", "1", "0"])))
        dataSet.set(DicomDataElement(tag: DicomTag.pixelSpacing.rawValue, vr: .DS,
                                     value: .strings(["0.5", "0.5"])))
        dataSet.set(DicomDataElement(tag: DicomTag.rescaleIntercept.rawValue, vr: .DS,
                                     value: .strings(["-1024"])))
        dataSet.set(DicomDataElement(tag: DicomTag.rescaleSlope.rawValue, vr: .DS,
                                     value: .strings(["1"])))
        dataSet.set(DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["CT"])))
        dataSet.set(DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["PARITY^VOLUME"])))
        dataSet.set(DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings(["PARITY-1233"])))
    }
}
