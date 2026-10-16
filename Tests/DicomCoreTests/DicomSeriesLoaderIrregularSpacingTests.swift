//
//  DicomSeriesLoaderIrregularSpacingTests.swift
//  DicomCoreTests
//
//  Issue #3116: a series whose slice positions are unevenly spaced (a missing slice, two stacks in one series) builds
//  one grid at the median interval and says so, as GDCM and Horos build one, instead of refusing.
//

import Foundation
import XCTest
@testable import DicomCore

final class DicomSeriesLoaderIrregularSpacingTests: XCTestCase {
    func test_unevenSlicePositions_buildAtTheMedianInterval_andReportIt() throws {
        let directory = try Self.makeSeries(positions: [0, 1.5, 3, 10])
        defer { try? FileManager.default.removeItem(at: directory) }

        let volume = try DicomSeriesLoader().loadSeries(in: directory)

        XCTAssertEqual(volume.depth, 4)
        XCTAssertEqual(volume.spacing.z, 1.5, accuracy: 1e-9)
        XCTAssertEqual(volume.geometryProvenance?.sliceSpacingSource, .irregularImagePositionPatient)
        XCTAssertEqual(Self.voxels(of: volume), (0..<4).flatMap { slice in (0..<16).map { Int16(slice * 100 + $0) } })
    }

    func test_evenSlicePositions_keepTheirMeasuredInterval() throws {
        let directory = try Self.makeSeries(positions: [0, 1.5, 3, 4.5])
        defer { try? FileManager.default.removeItem(at: directory) }

        let volume = try DicomSeriesLoader().loadSeries(in: directory)

        XCTAssertEqual(volume.spacing.z, 1.5, accuracy: 1e-9)
        XCTAssertEqual(volume.geometryProvenance?.sliceSpacingSource, .imagePositionPatient)
    }

    // MARK: - Fixtures

    /// 4×4 unsigned 16-bit slices along +z at `positions`; slice `n` holds `n * 100 + index`.
    private static func makeSeries(positions: [Double]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("series-3116-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (sliceIndex, position) in positions.enumerated() {
            var pixelData = Data()
            for index in 0..<16 {
                let value = UInt16(sliceIndex * 100 + index)
                pixelData.append(UInt8(value & 0xFF))
                pixelData.append(UInt8(value >> 8))
            }
            var dataSet = EncapsulatedFixtureFactory.makeDataSet(
                transferSyntax: .explicitVRLittleEndian, fragments: [], declaredFrames: 1,
                rows: 4, columns: 4, bitsAllocated: 16, bitsStored: 16, highBit: 15, pixelRepresentation: 0
            )
            dataSet.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(pixelData)))
            let uid = "2.25.3116000\(sliceIndex + 1)"
            dataSet.set(DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([uid])))
            dataSet.set(DicomDataElement(tag: DicomTag.instanceNumber.rawValue, vr: .IS,
                                         value: .strings(["\(sliceIndex + 1)"])))
            dataSet.set(DicomDataElement(tag: DicomTag.imagePositionPatient.rawValue, vr: .DS,
                                         value: .strings(["0", "0", "\(position)"])))
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
