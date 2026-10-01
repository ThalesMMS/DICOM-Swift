//
//  DicomSeriesLoaderBitsStoredTests.swift
//  DicomCoreTests
//
//  Issue #2781: series with fewer bits stored than allocated — 12 of 16, as
//  most CT stores them — assemble a volume of their stored values, the unused
//  high bits masked away and a signed sample extended from its top stored bit.
//

import Foundation
import XCTest
@testable import DicomCore

final class DicomSeriesLoaderBitsStoredTests: XCTestCase {
    func test_unsigned12BitSeries_withDirtyHighBits_loadsItsStoredValues() throws {
        let stored: [Int] = [0, 1, 1_024, 2_047, 2_048, 4_095, 300, 3_000, 17, 4_000, 5, 6, 7, 8, 9, 10]
        let directory = try Self.makeSeries(storedValues: stored, pixelRepresentation: 0)
        defer { try? FileManager.default.removeItem(at: directory) }

        let volume = try DicomSeriesLoader().loadSeries(in: directory)

        XCTAssertEqual(volume.depth, 2)
        XCTAssertFalse(volume.isSignedPixel)
        XCTAssertEqual(Self.voxels(of: volume), (stored + stored).map(Int16.init))
    }

    func test_signed12BitSeries_withDirtyHighBits_extendsTheSign() throws {
        let stored: [Int] = [0, 1, -1, -2_048, 2_047, -1_000, 1_000, -2, 2, 100, -100, 512, -512, 7, -7, 0]
        let directory = try Self.makeSeries(storedValues: stored, pixelRepresentation: 1)
        defer { try? FileManager.default.removeItem(at: directory) }

        let volume = try DicomSeriesLoader().loadSeries(in: directory)

        XCTAssertTrue(volume.isSignedPixel)
        XCTAssertEqual(Self.voxels(of: volume), (stored + stored).map(Int16.init))
    }

    func test_unsigned24Of32BitSeries_masksDirtyHighBitsBeforeClamping() throws {
        try assert32BitSeries([0, 1, 65_535, 65_536, 8_388_608, 16_777_215, 300, 3_000,
                              17, 4_000, 5, 6, 7, 8, 9, 10], signed: false)
    }

    func test_signed24Of32BitSeries_extendsTheStoredSignBeforeClamping() throws {
        try assert32BitSeries([0, 1, -1, -8_388_608, 8_388_607, -65_536, 65_536, -2,
                              2, 100, -100, 512, -512, 7, -7, 0], signed: true)
    }

    private func assert32BitSeries(_ stored: [Int], signed: Bool) throws {
        let directory = try Self.makeSeries(storedValues: stored, pixelRepresentation: signed ? 1 : 0,
                                            bitsAllocated: 32, bitsStored: 24)
        defer { try? FileManager.default.removeItem(at: directory) }
        let decoder = try DCMDecoder(contentsOf: directory.appendingPathComponent("slice0.dcm"))
        for (index, expected) in stored.enumerated() {
            XCTAssertEqual(decoder.storedPixelValue(at: index), expected, "sample \(index)")
        }
        let volume = try DicomSeriesLoader().loadSeries(in: directory)
        XCTAssertEqual(volume.isSignedPixel, signed)
        XCTAssertEqual(Self.voxels(of: volume), (stored + stored).map { Int16(clamping: $0) })
    }

    func test_bitsStoredAboveTheAllocation_orNotFromBitZero_isRefused() {
        let matrix = DicomSeriesLoaderSupportMatrix.standard
        func format(bitsAllocated: Int, bitsStored: Int, highBit: Int) -> DicomSeriesLoaderPixelFormat {
            DicomSeriesLoaderPixelFormat(bitsAllocated: bitsAllocated, bitsStored: bitsStored, highBit: highBit,
                                         pixelRepresentation: 0, samplesPerPixel: 1,
                                         photometricInterpretation: "MONOCHROME2", planarConfiguration: nil,
                                         numberOfFrames: 1, transferSyntaxUID: "1.2.840.10008.1.2.1",
                                         isCompressed: false)
        }
        XCTAssertTrue(matrix.supports(format(bitsAllocated: 16, bitsStored: 12, highBit: 11)))
        XCTAssertTrue(matrix.supports(format(bitsAllocated: 16, bitsStored: 10, highBit: 9)))
        XCTAssertFalse(matrix.supports(format(bitsAllocated: 8, bitsStored: 12, highBit: 11)))
        XCTAssertFalse(matrix.supports(format(bitsAllocated: 16, bitsStored: 12, highBit: 15)))
    }

    // MARK: - Fixtures

    /// Two 4×4 slices; unused high bits carry a pattern a reader must drop.
    private static func makeSeries(storedValues: [Int], pixelRepresentation: Int,
                                   bitsAllocated: Int = 16, bitsStored: Int = 12) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("series-12bit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for sliceIndex in 0..<2 {
            var pixelData = Data()
            for value in storedValues {
                let mask = (UInt32(1) << bitsStored) - 1
                let dirtyHighBits: UInt32 = bitsAllocated == 32 ? 0xAA00_0000 : 0xA000
                let word = (UInt32(truncatingIfNeeded: value) & mask) | dirtyHighBits
                for byte in 0..<(bitsAllocated / 8) {
                    pixelData.append(UInt8(truncatingIfNeeded: word >> (byte * 8)))
                }
            }
            var dataSet = EncapsulatedFixtureFactory.makeDataSet(
                transferSyntax: .explicitVRLittleEndian, fragments: [], declaredFrames: 1,
                rows: 4, columns: 4, bitsAllocated: bitsAllocated, bitsStored: bitsStored, highBit: bitsStored - 1,
                pixelRepresentation: pixelRepresentation
            )
            dataSet.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(pixelData)))
            let uid = "2.25.2781000\(sliceIndex + 1)"
            dataSet.set(DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([uid])))
            dataSet.set(DicomDataElement(tag: DicomTag.instanceNumber.rawValue, vr: .IS,
                                         value: .strings(["\(sliceIndex + 1)"])))
            dataSet.set(DicomDataElement(tag: DicomTag.imagePositionPatient.rawValue, vr: .DS,
                                         value: .strings(["0", "0", "\(sliceIndex * 2)"])))
            dataSet.set(DicomDataElement(tag: DicomTag.imageOrientationPatient.rawValue, vr: .DS,
                                         value: .strings(["1", "0", "0", "0", "1", "0"])))
            dataSet.set(DicomDataElement(tag: DicomTag.pixelSpacing.rawValue, vr: .DS, value: .strings(["0.5", "0.5"])))
            dataSet.set(DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["CT"])))
            let data = try DicomDataSetWriter.part10Data(
                from: dataSet,
                options: DicomPart10WriterOptions(
                    transferSyntax: .explicitVRLittleEndian,
                    mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                    mediaStorageSOPInstanceUID: uid
                )
            )
            try data.write(to: directory.appendingPathComponent("slice\(sliceIndex).dcm"))
        }
        return directory
    }

    private static func voxels(of volume: DicomSeriesVolume) -> [Int16] {
        volume.voxels.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }
}
