import DicomData
import Foundation
import simd
import XCTest
@testable import DicomCore

/// Issue #2827: a Siemens MOSAIC or United Imaging grid is sliced into the volume its tiles hold.
final class DicomTiledSliceLayoutTests: XCTestCase {
    /// GDCM's `SIEMENS_MOSAIC_12BitsStored-16BitsJPEG.dcm` (opt-in, `ISIS_GDCM_DATA_DIR`). The references are GDCM's
    /// `TestSplitMosaicFilter3.cxx` (64 × 64 × 18, slice normal) and nibabel 5's `MosaicWrapper` affine (first-tile
    /// position, 6.125 mm between slices).
    func test_gdcmSiemensMosaic_matchesGDCMAndNibabelGeometryAndTiles() throws {
        guard let root = ProcessInfo.processInfo.environment["ISIS_GDCM_DATA_DIR"], !root.isEmpty else {
            throw XCTSkip("ISIS_GDCM_DATA_DIR is not set")
        }
        let url = URL(fileURLWithPath: root).appendingPathComponent("SIEMENS_MOSAIC_12BitsStored-16BitsJPEG.dcm")
        let decoder = try DCMDecoder(contentsOf: url)
        let layout = try XCTUnwrap(DicomTiledSliceLayout.detect(in: decoder.dataSet))

        XCTAssertEqual(layout.kind, .siemensMosaic)
        XCTAssertEqual([layout.tileColumns, layout.tileRows, layout.sliceCount], [64, 64, 18])
        XCTAssertEqual(layout.tilesPerRow, 5)
        let normal = simd_normalize(simd_cross(layout.rowDirection, layout.columnDirection))
        assertEqual(normal, SIMD3(-0.03737130908, -0.314588168, 0.9484923141), accuracy: 1e-6)
        assertEqual(layout.tilePositions[0], SIMD3(-106.42153718, -97.81465222, -62.50204515), accuracy: 1e-5)
        XCTAssertEqual(layout.sliceSpacing, 6.1250000080692, accuracy: 1e-9)
        XCTAssertEqual(layout.tilesInVolumeOrder, Array(0 ..< 18), "the slice normal agrees with row × column")

        let pixels = try XCTUnwrap(decoder.getPixels16())
        let volume = try XCTUnwrap(layout.slices(fromImage: pixels.withUnsafeBytes { Data($0) },
                                                 columns: decoder.width, bytesPerSample: 2))
        let voxels = volume.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        XCTAssertEqual(voxels.count, 64 * 64 * 18)
        for (slice, x, y) in [(0, 0, 0), (7, 31, 40), (17, 63, 63), (12, 5, 60)] {
            let tileX = slice % 5 * 64 + x, tileY = slice / 5 * 64 + y
            XCTAssertEqual(voxels[(slice * 64 + y) * 64 + x], pixels[tileY * decoder.width + tileX],
                           "slice \(slice) voxel (\(x), \(y))")
        }
    }

    /// Without the CSA header (an anonymizer dropped it), the count comes from (0019,xx0A), read from bytes when
    /// the object is implicit VR.
    func test_mosaicWithoutCSA_countsFromTheSiemensHeaderElement() throws {
        let layout = try XCTUnwrap(DicomTiledSliceLayout.detect(in: dataSet([
            DicomDataElement(tag: 0x0008_0008, vr: .CS, value: .strings(["ORIGINAL", "PRIMARY", "M", "MOSAIC"])),
            DicomDataElement(tag: 0x0018_0088, vr: .DS, value: .strings(["2.5"])),
            DicomDataElement(tag: 0x0019_0010, vr: .LO, value: .strings(["SIEMENS MR HEADER"])),
            DicomDataElement(tag: 0x0019_100A, vr: .UN, value: .bytes(Data([5, 0])))
        ])))
        XCTAssertEqual([layout.tilesPerRow, layout.tileColumns, layout.tileRows, layout.sliceCount], [3, 32, 32, 5])
        // The mosaic corner is (10, 20, 30) with 1 mm pixels: the first tile is centred, (96 − 32) / 2 mm in.
        assertEqual(layout.tilePositions[0], SIMD3(42, 52, 30), accuracy: 1e-12)
        assertEqual(layout.tilePositions[4], SIMD3(42, 52, 40), accuracy: 1e-12)
        XCTAssertEqual(layout.sliceSpacing, 2.5, accuracy: 1e-12)
    }

    func test_imagesWithoutMosaicTypeOrCount_areNotTiled() {
        XCTAssertNil(DicomTiledSliceLayout.detect(in: dataSet([
            DicomDataElement(tag: 0x0008_0008, vr: .CS, value: .strings(["ORIGINAL", "PRIMARY", "M", "ND"])),
            DicomDataElement(tag: 0x0019_0010, vr: .LO, value: .strings(["SIEMENS MR HEADER"])),
            DicomDataElement(tag: 0x0019_100A, vr: .US, value: .unsignedIntegers([5]))
        ])))
        XCTAssertNil(DicomTiledSliceLayout.detect(in: dataSet([
            DicomDataElement(tag: 0x0008_0008, vr: .CS, value: .strings(["ORIGINAL", "PRIMARY", "M", "MOSAIC"]))
        ])), "no count: GDCM would guess from the acquisition matrix; here the image stays 2D")
    }

    /// A synthetic United Imaging grid of 5 tiles on a 3 × 2 grid, positions listed from the top slice down: the
    /// volume runs from the lowest tile up, and each slice holds its tile's pixels.
    func test_unitedImagingGrid_ordersTilesByTheirPositions() throws {
        let positions = (0 ..< 5).map { SIMD3<Double>(-40, -30, 20 - 4 * Double($0)) }
        let items = positions.map { position in
            DicomSequenceItem(dataSet: DicomDataSet(elements: [
                DicomDataElement(tag: 0x0020_0032, vr: .DS, value: .strings([position.x, position.y, position.z]
                    .map { String($0) }))
            ]))
        }
        let layout = try XCTUnwrap(DicomTiledSliceLayout.detect(in: dataSet(rows: 64, [
            DicomDataElement(tag: 0x0065_0010, vr: .LO, value: .strings(["Image Private Header"])),
            DicomDataElement(tag: 0x0065_1050, vr: .DS, value: .strings(["5"])),
            DicomDataElement(tag: 0x0065_1051, vr: .SQ, value: .sequence(items))
        ])))
        XCTAssertEqual(layout.kind, .unitedImagingGrid)
        XCTAssertEqual([layout.tilesPerRow, layout.tileColumns, layout.tileRows], [3, 32, 32])
        XCTAssertEqual(layout.tilesInVolumeOrder, [4, 3, 2, 1, 0])
        XCTAssertEqual(layout.sliceSpacing, 4, accuracy: 1e-12)

        // Each tile holds its own index in every sample.
        var image = [UInt16](repeating: 0, count: 96 * 64)
        for tile in 0 ..< 5 {
            for y in 0 ..< 32 {
                for x in 0 ..< 32 { image[(tile / 3 * 32 + y) * 96 + tile % 3 * 32 + x] = UInt16(tile + 1) }
            }
        }
        let volume = try XCTUnwrap(layout.slices(fromImage: image.withUnsafeBytes { Data($0) }, columns: 96,
                                                 bytesPerSample: 2))
        let voxels = volume.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        XCTAssertEqual((0 ..< 5).map { voxels[$0 * 32 * 32 + 17] }, [5, 4, 3, 2, 1])
        XCTAssertNil(layout.slices(fromImage: Data(count: 10), columns: 96, bytesPerSample: 2), "too few pixels")
    }

    func test_invalidLayoutDimensions_refuseCopying() {
        for (perRow, width, height, bytes, columns) in [(0, 2, 2, 2, 4), (2, 0, 2, 2, 4),
            (2, 2, 0, 2, 4), (2, 2, 2, 0, 4), (2, 2, 2, 2, 3), (2, 2, 2, Int.max, 4)] {
            let layout = DicomTiledSliceLayout(kind: .siemensMosaic, tilesPerRow: perRow, tileColumns: width,
                tileRows: height, tilePositions: [.zero, SIMD3(0, 0, 1)],
                rowDirection: SIMD3(1, 0, 0), columnDirection: SIMD3(0, 1, 0))
            XCTAssertNil(layout.slices(fromImage: Data(count: 64), columns: columns, bytesPerSample: bytes))
        }
    }

    func test_invalidPrivateTileCounts_areRefused() {
        for count in ["1", "1.5", "1e30", "999999"] {
            let image = dataSet([
                DicomDataElement(tag: 0x0065_0010, vr: .LO, value: .strings(["Image Private Header"])),
                DicomDataElement(tag: 0x0065_1050, vr: .DS, value: .strings([count])),
                DicomDataElement(tag: 0x0065_1051, vr: .SQ, value: .sequence([]))
            ])
            XCTAssertNil(DicomTiledSliceLayout.detect(in: image))
        }
        let mosaic = dataSet([
            DicomDataElement(tag: 0x0008_0008, vr: .CS, value: .strings(["MOSAIC"])),
            DicomDataElement(tag: 0x0019_0010, vr: .LO, value: .strings(["SIEMENS MR HEADER"])),
            DicomDataElement(tag: 0x0019_100A, vr: .IS, value: .strings(["999999"])),
            DicomDataElement(tag: 0x0018_0088, vr: .DS, value: .strings(["1"]))
        ])
        XCTAssertNil(DicomTiledSliceLayout.detect(in: mosaic))
    }

    // MARK: - Fixtures

    /// An axial 96-column image of 1 mm pixels at (10, 20, 30) with the given extra elements.
    private func dataSet(rows: Int = 96, _ extra: [DicomDataElement]) -> DicomDataSet {
        DicomDataSet(elements: [
            DicomDataElement(tag: 0x0020_0032, vr: .DS, value: .strings(["10", "20", "30"])),
            DicomDataElement(tag: 0x0020_0037, vr: .DS, value: .strings(["1", "0", "0", "0", "1", "0"])),
            DicomDataElement(tag: 0x0028_0010, vr: .US, value: .unsignedIntegers([UInt(rows)])),
            DicomDataElement(tag: 0x0028_0011, vr: .US, value: .unsignedIntegers([96])),
            DicomDataElement(tag: 0x0028_0030, vr: .DS, value: .strings(["1", "1"]))
        ] + extra)
    }

    private func assertEqual(_ actual: SIMD3<Double>, _ expected: SIMD3<Double>, accuracy: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_distance(actual, expected), accuracy, "\(actual) vs \(expected)", file: file, line: line)
    }
}
