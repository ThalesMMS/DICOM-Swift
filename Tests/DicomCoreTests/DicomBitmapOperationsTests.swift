import DicomCore
import Foundation
import XCTest

final class DicomBitmapOperationsTests: XCTestCase {
    func test_crop_copiesTheExactRequestedPixels() throws {
        let result = try DicomBitmapOperations.cropped(
            bitmap(values: [1, 2, 3, 4, 5, 6], width: 3),
            x: 1,
            y: 0,
            width: 2,
            height: 2
        )

        XCTAssertEqual(result.width, 2)
        XCTAssertEqual(result.height, 2)
        XCTAssertEqual(greyValues(result), [2, 3, 5, 6])
    }

    func test_rotation_movesEveryPixelClockwise() throws {
        let source = try bitmap(values: [1, 2, 3, 4, 5, 6], width: 3)

        let clockwise = try DicomBitmapOperations.rotated(source, clockwiseQuarterTurns: 1)
        let halfTurn = try DicomBitmapOperations.rotated(source, clockwiseQuarterTurns: 2)
        let counterClockwise = try DicomBitmapOperations.rotated(source, clockwiseQuarterTurns: -1)

        XCTAssertEqual(clockwise.width, 2)
        XCTAssertEqual(clockwise.height, 3)
        XCTAssertEqual(greyValues(clockwise), [4, 1, 5, 2, 6, 3])
        XCTAssertEqual(greyValues(halfTurn), [6, 5, 4, 3, 2, 1])
        XCTAssertEqual(greyValues(counterClockwise), [3, 6, 2, 5, 1, 4])
    }

    func test_flip_mirrorsTheRequestedAxesPixelForPixel() throws {
        let source = try bitmap(values: [1, 2, 3, 4, 5, 6], width: 3)

        let horizontal = try DicomBitmapOperations.flipped(
            source,
            horizontally: true,
            vertically: false
        )
        let vertical = try DicomBitmapOperations.flipped(
            source,
            horizontally: false,
            vertically: true
        )

        XCTAssertEqual(greyValues(horizontal), [3, 2, 1, 6, 5, 4])
        XCTAssertEqual(greyValues(vertical), [4, 5, 6, 1, 2, 3])
    }

    func test_inversion_flipsEveryRGBChannel() throws {
        let source = try DicomRenderedBitmap(
            width: 1,
            height: 2,
            rgbData: Data([0, 10, 20, 200, 250, 255])
        )

        let result = try DicomBitmapOperations.inverted(source)

        XCTAssertEqual(result.rgbData, Data([255, 245, 235, 55, 5, 0]))
    }

    func test_grayscaleExpansion_repeatsEachSampleAcrossRGBChannels() {
        XCTAssertEqual(
            DicomBitmapOperations.rgbData(fromGrayscale: Data([0, 127, 255])),
            Data([0, 0, 0, 127, 127, 127, 255, 255, 255])
        )
    }

    func test_grayscaleConversion_usesDeterministicLuminanceForDataAndBitmap() throws {
        let bitmap = try DicomRenderedBitmap(
            width: 2,
            height: 1,
            rgbData: Data([255, 0, 0, 0, 255, 0])
        )

        let displayBitmap = try DicomBitmapOperations.grayscale(bitmap)

        XCTAssertEqual(displayBitmap.rgbData, Data([76, 76, 76, 149, 149, 149]))
    }

    func test_verticalConcatenation_appendsRowsWithoutChangingPixels() throws {
        let top = try bitmap(values: [1, 2, 3, 4, 5, 6], width: 3)
        let bottom = try bitmap(values: [7, 8, 9], width: 3)

        let result = try DicomBitmapOperations.concatenatingVertically(top, bottom)

        XCTAssertEqual(result.width, 3)
        XCTAssertEqual(result.height, 3)
        XCTAssertEqual(greyValues(result), [1, 2, 3, 4, 5, 6, 7, 8, 9])
    }

    private func bitmap(values: [UInt8], width: Int) throws -> DicomRenderedBitmap {
        let rgb = values.flatMap { [$0, $0, $0] }
        return try DicomRenderedBitmap(
            width: width,
            height: values.count / width,
            rgbData: Data(rgb)
        )
    }

    private func greyValues(_ bitmap: DicomRenderedBitmap) -> [UInt8] {
        stride(from: 0, to: bitmap.rgbData.count, by: 3).map { bitmap.rgbData[$0] }
    }
}
