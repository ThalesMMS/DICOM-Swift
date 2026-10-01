import DicomCore
import Foundation
import XCTest

final class DicomClassicMultiframeVolumeTests: XCTestCase {
    func test_nativeDeclaredFrames_exceedingPixelDataAreRejectedBeforeAllocation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("classic-short-\(UUID()).dcm")
        defer { try? FileManager.default.removeItem(at: url) }
        for bits: UInt in [8, 16] {
            for trailingBytes in [0, 64] {
                var data = try file(sopClass: DicomSOPClassGeometry.nuclearMedicineSOPClassUID, size: 2,
                                    frames: 1_000_000_000, bits: bits)
                data.append(Data(repeating: 0, count: trailingBytes))
                try data.write(to: url)
                let loader = DicomSeriesLoader(allocateVoxelData: { _ in
                    XCTFail("Native Pixel Data must be validated before allocation")
                    throw NSError(domain: "UnexpectedAllocation", code: 1)
                })
                XCTAssertThrowsError(try loader.loadClassicMultiframeVolume(at: url)) { error in
                    guard case DicomSeriesLoaderError.failedToDecode(url) = error else {
                        return XCTFail("Expected failedToDecode, got \(error)")
                    }
                }
            }
        }
        var truncated = try file(sopClass: DicomSOPClassGeometry.nuclearMedicineSOPClassUID, size: 2, frames: 2)
        truncated.removeLast(4)
        try truncated.write(to: url)
        let loader = DicomSeriesLoader(allocateVoxelData: { _ in
            XCTFail("Truncated Pixel Data must be validated before allocation")
            throw NSError(domain: "UnexpectedAllocation", code: 1)
        })
        XCTAssertThrowsError(try loader.loadClassicMultiframeVolume(at: url)) { error in
            guard case DicomSeriesLoaderError.failedToDecode(url) = error else {
                return XCTFail("Expected failedToDecode, got \(error)")
            }
        }
    }

    func test_encapsulatedDecodedVolume_exceedingSafetyLimitIsRejectedBeforeAllocation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("classic-compressed-limit-\(UUID()).dcm")
        defer { try? FileManager.default.removeItem(at: url) }
        try EncapsulatedFixtureFactory.makeFile(transferSyntax: .rleLossless, fragments: [Data([0]), Data([0])],
            declaredFrames: 2, rows: 32_768, columns: 32_768).write(to: url)
        let loader = DicomSeriesLoader(allocateVoxelData: { _ in
            XCTFail("Decoded volume limit must be checked before allocation")
            throw NSError(domain: "UnexpectedAllocation", code: 1)
        })
        XCTAssertThrowsError(try loader.loadClassicMultiframeVolume(at: url)) { error in
            guard case DicomSeriesLoaderError.unsupportedMultiframe = error else {
                return XCTFail("Expected unsupportedMultiframe, got \(error)")
            }
        }
    }

    func test_validEncapsulatedMultiframe_usesDecodedSizeAndPreservesFrames() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("classic-compressed-valid-\(UUID()).dcm")
        defer { try? FileManager.default.removeItem(at: url) }
        func rle(_ samples: [UInt8]) -> Data {
            var header = Data(repeating: 0, count: 64)
            header[0] = 1
            header[4] = 64
            return header + Data([UInt8(samples.count - 1)]) + Data(samples) + Data([0])
        }
        try EncapsulatedFixtureFactory.makeFile(transferSyntax: .rleLossless,
            fragments: [rle([1, 2, 3, 4]), rle([5, 6, 7, 8])], declaredFrames: 2).write(to: url)
        let volume = try DicomSeriesLoader().loadClassicMultiframeVolume(at: url)
        XCTAssertEqual(volume.voxels.count, 16)
        XCTAssertEqual(volume.voxels.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }, [1, 2, 3, 4, 5, 6, 7, 8])
    }

    func test_largeDeclaredFrameCount_rejectsOverflowBeforeAllocation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("classic-overflow-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for sopClass in [DicomSOPClassGeometry.nuclearMedicineSOPClassUID, "1.2.840.10008.5.1.4.1.1.3.1"] {
            for frameCount in [999_999_999_999, 5_000_000_000] {
                let url = directory.appendingPathComponent("large.dcm")
                try file(sopClass: sopClass, size: 32_768, frames: frameCount).write(to: url)
                XCTAssertEqual(try DCMDecoder(contentsOf: url).nImages, frameCount)
                let loader = DicomSeriesLoader(allocateVoxelData: { _ in
                    XCTFail("Overflow must be rejected before calling the allocator")
                    throw NSError(domain: "UnexpectedAllocation", code: 1)
                })
                XCTAssertThrowsError(try loader.loadClassicMultiframeVolume(at: url)) { error in
                    guard case let DicomSeriesLoaderError.unsupportedMultiframe(format) = error else {
                        return XCTFail("Expected unsupportedMultiframe, got \(error)")
                    }
                    XCTAssertEqual(format.numberOfFrames, frameCount)
                }
            }
        }
    }

    func test_validClassicMultiframe_keepsFrameOrderAndVoxelSize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("classic-valid-\(UUID()).dcm")
        defer { try? FileManager.default.removeItem(at: url) }
        for (bits, syntax) in [(UInt(8), DicomTransferSyntax.explicitVRLittleEndian),
                               (16, .explicitVRLittleEndian), (8, .deflatedExplicitVRLittleEndian)] {
            let pixels = bits == 8 ? Data([1, 2, 3, 4, 5, 6, 7, 8]) : Data([1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8, 0])
            try file(sopClass: DicomSOPClassGeometry.nuclearMedicineSOPClassUID, size: 2, frames: 2,
                     bits: bits, pixels: pixels, syntax: syntax).write(to: url)
            let volume = try DicomSeriesLoader().loadClassicMultiframeVolume(at: url)
            XCTAssertEqual([volume.width, volume.height, volume.depth], [2, 2, 2])
            XCTAssertEqual(volume.voxels.count, 16)
            XCTAssertEqual(volume.voxels.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }, [1, 2, 3, 4, 5, 6, 7, 8])
        }
    }

    private func file(sopClass: String, size: UInt, frames: Int, bits: UInt = 8,
                      pixels: Data = Data([1, 2, 3, 4, 5, 6, 7, 8]),
                      syntax: DicomTransferSyntax = .explicitVRLittleEndian) throws -> Data {
        func text(_ tag: DicomTag, _ vr: DicomVR, _ value: String) -> DicomDataElement {
            .init(tag: tag.rawValue, vr: vr, value: .strings([value]))
        }
        func short(_ tag: DicomTag, _ value: UInt) -> DicomDataElement {
            .init(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([value]))
        }
        return try DicomDataSetWriter.part10Data(from: .init(elements: [
            text(.sopClassUID, .UI, sopClass), text(.sopInstanceUID, .UI, "2.25.281300001"),
            text(.numberOfFrames, .IS, "\(frames)"), text(.photometricInterpretation, .CS, "MONOCHROME2"),
            short(.rows, size), short(.columns, size), short(.samplesPerPixel, 1), short(.bitsAllocated, bits),
            short(.bitsStored, bits), short(.highBit, bits - 1), short(.pixelRepresentation, 0),
            .init(tag: DicomTag.pixelData.rawValue, vr: bits == 8 ? .OB : .OW, value: .bytes(pixels))
        ]), options: .init(transferSyntax: syntax, mediaStorageSOPClassUID: sopClass,
                           mediaStorageSOPInstanceUID: "2.25.281300001"))
    }
}
