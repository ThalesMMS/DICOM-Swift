import Foundation
import CoreGraphics
import XCTest
@testable import DicomCore

final class DicomFilmCompositorTests: XCTestCase {
    func test_fileProvider_twoJobs_replaceExistingDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("print-pdf-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pdf = directory.appendingPathComponent("film.pdf")
        try Data("previous output".utf8).write(to: pdf)
        let provider = DicomFilePrintOutputProvider(directory: directory, pdfURL: pdf, writePNG: false)
        let film = try DicomFilmCompositor().compose(description())
        for pages in 1...2 {
            let control = DicomPrintJobControl(id: "2.25.\(pages)")
            for index in 0..<pages {
                let result = await provider.output(film, metadata: .init(jobID: control.id,
                    filmIndex: index, filmCount: pages, originator: "SCU"), control: control)
                XCTAssertEqual(result, .success)
            }
            XCTAssertEqual(try XCTUnwrap(CGPDFDocument(pdf as CFURL)).numberOfPages, pages)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["film.pdf"])
        }
    }

    func test_fileProvider_publishesOnlyCompleteMultipagePDF() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("print-pdf-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = directory.appendingPathComponent("film.pdf")
        let provider = DicomFilePrintOutputProvider(directory: directory, pdfURL: pdf, writePNG: false)
        let film = try DicomFilmCompositor().compose(description())
        let control = DicomPrintJobControl(id: "2.25.123")
        let first = await provider.output(film, metadata: .init(jobID: control.id, filmIndex: 0, filmCount: 2,
            originator: "SCU"), control: control)
        XCTAssertEqual(first, .success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdf.path))
        let last = await provider.output(film, metadata: .init(jobID: control.id, filmIndex: 1, filmCount: 2,
            originator: "SCU"), control: control)
        XCTAssertEqual(last, .success)
        let document = try XCTUnwrap(CGPDFDocument(pdf as CFURL))
        XCTAssertEqual(document.numberOfPages, 2)
        XCTAssertEqual(try XCTUnwrap(document.page(at: 1)).getBoxRect(.mediaBox).width, 1008, accuracy: 0.01)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["film.pdf"])
    }
    private func description(format: DicomImageDisplayFormat = .standard(columns: 1, rows: 1),
                             width: Int = 2, height: Int = 2) throws -> DicomFilmDescription {
        let bitmap = try DicomRenderedBitmap(width: width, height: height,
            rgbData: Data((0..<(width * height)).flatMap { index in
                [UInt8](repeating: UInt8(index % 256), count: 3)
            }))
        var result = try DicomFilmDescription(film: .init(filmBox: .init(displayFormat: format, filmSizeID: "14INX14IN"),
            imageBoxes: [try .init(bitmap: bitmap)]))
        result.outputWidth = 8
        return result
    }

    func test_geometryEveryFamily_preservesPositionOrder() throws {
        let bounds = DicomFilmRectangle(x: 0, y: 0, width: 12, height: 12)
        let standard = try DicomFilmGeometry.slots(format: .standard(columns: 2, rows: 2), bounds: bounds)
        XCTAssertEqual(standard[1], .init(x: 6, y: 0, width: 6, height: 6))
        let row = try DicomFilmGeometry.slots(format: .row(imagesPerRow: [1, 3]), bounds: bounds)
        XCTAssertEqual(row, [.init(x: 0, y: 0, width: 12, height: 6), .init(x: 0, y: 6, width: 4, height: 6),
                             .init(x: 4, y: 6, width: 4, height: 6), .init(x: 8, y: 6, width: 4, height: 6)])
        let col = try DicomFilmGeometry.slots(format: .col(imagesPerColumn: [1, 3]), bounds: bounds)
        XCTAssertEqual(col[2], .init(x: 6, y: 4, width: 6, height: 4))
        for format in [DicomImageDisplayFormat.slide, .superslide, .custom(identifier: "A")] {
            XCTAssertThrowsError(try DicomFilmGeometry.slots(format: format, bounds: bounds))
            XCTAssertEqual(try DicomFilmGeometry.slots(format: format, bounds: bounds,
                printerDefinedGrid: .standard(columns: 2, rows: 2)), standard)
        }
    }

    func test_geometryRounding_coversAllPixelsWithoutOverlap() throws {
        let rectangles = try DicomFilmGeometry.slots(format: .row(imagesPerRow: [2, 3, 1]),
            bounds: .init(x: 0, y: 0, width: 11, height: 13))
        var pixels = Set<Int>()
        for rect in rectangles {
            for y in rect.y..<(rect.y + rect.height) { for x in rect.x..<(rect.x + rect.width) {
                XCTAssertTrue(pixels.insert(y * 11 + x).inserted)
            } }
        }
        XCTAssertEqual(pixels.count, 11 * 13)
    }

    func test_oversizedImage_reportsFitWarningsAndRefusals() throws {
        var input = try description(width: 16, height: 16)
        let compositor = DicomFilmCompositor()
        XCTAssertEqual(try compositor.compose(input).info.fitByPosition[1]?.warningStatus, 0xB604)
        input.film.imageBoxes[0].requestedDecimateCropBehavior = .crop
        XCTAssertEqual(try compositor.compose(input).info.fitByPosition[1]?.warningStatus, 0xB609)
        input.film.imageBoxes[0].requestedDecimateCropBehavior = .decimate
        XCTAssertEqual(try compositor.compose(input).info.fitByPosition[1]?.warningStatus, 0xB60A)
        input.film.filmBox.magnificationType = "NONE"
        XCTAssertThrowsError(try compositor.compose(input))
        input.film.filmBox.magnificationType = "REPLICATE"
        input.film.imageBoxes[0].requestedDecimateCropBehavior = .fail
        XCTAssertThrowsError(try compositor.compose(input))
    }

    func test_lutAndPolarity_transformRasterDeterministically() throws {
        var input = try description()
        let compositor = DicomFilmCompositor()
        let original = try compositor.compose(input)
        input.presentationLUT = .init(shape: .identity)
        XCTAssertEqual(try compositor.compose(input).pixelData, original.pixelData)
        input.presentationLUT = try .init(descriptor: [256, 0, 10], values: (0..<256).map { UInt16((255 - $0) * 4) })
        let table = try compositor.compose(input)
        XCTAssertGreaterThan(table.pixelData[0], 250)
        input.presentationLUT = .init(shape: .linearOpticalDensity)
        XCTAssertNotEqual(try compositor.compose(input).pixelData, original.pixelData)
        input.presentationLUT = nil
        input.film.imageBoxes[0].polarity = .reverse
        XCTAssertEqual(try compositor.compose(input).pixelData, Data(original.pixelData.map { 255 - $0 }))
        XCTAssertEqual(try compositor.compose(input).fingerprint, try compositor.compose(input).fingerprint)
        XCTAssertEqual(original.fingerprint.count, 64)
    }

    func test_physicalScale_preservesPixelAspectRatio() throws {
        var input = try description()
        input.outputWidth = 20
        input.imagePixelSpacing[1] = (row: 2, column: 1)
        input.film.imageBoxes[0].requestedImageSize = 71.12
        let output = try DicomFilmCompositor().compose(input)
        XCTAssertEqual(output.width, 20)
        XCTAssertEqual(output.info.fitByPosition[1], DicomComposedFilmInfo.Fit.none)
        // 71.12 mm on a 355.6 mm, 20-pixel film is four pixels wide.
        let nonzero = output.pixelData.enumerated().filter { $0.element != 0 }.map(\.offset)
        XCTAssertTrue(nonzero.allSatisfy { (8..<12).contains($0 % 20) })
        XCTAssertTrue(nonzero.allSatisfy { (6..<14).contains($0 / 20) })
    }

    func test_identification_usesStudyUIDPerFilm() throws {
        var input = try description(format: .standard(columns: 2, rows: 1))
        input.outputWidth = 128
        input.textBandHeight = 8
        input.identify = true
        var first = input.film.imageBoxes[0]
        first.originalImage = DicomDataSet(elements: [
            .init(tag: 0x0010_0010, vr: .PN, value: .strings(["SAME"])),
            .init(tag: 0x0020_000D, vr: .UI, value: .strings(["2.25.1"]))
        ])
        var second = first
        second.position = 2
        input.film.imageBoxes = [first, second]
        let compositor = DicomFilmCompositor(textRasterizer: SolidText())
        XCTAssertNotNil(try compositor.compose(input).info.filmIdentification)
        second.originalImage?.set(.init(tag: 0x0020_000D, vr: .UI, value: .strings(["2.25.2"])))
        input.film.imageBoxes[1] = second
        let mixed = try compositor.compose(input)
        XCTAssertNil(mixed.info.filmIdentification)
        XCTAssertEqual(mixed.info.identificationByPosition.count, 2)
    }

    func test_annotationsAndTextFailure_neverSilentlyDropText() throws {
        var input = try description()
        input.outputWidth = 64
        input.annotationRows = 1
        input.textBandHeight = 8
        input.film.annotations = [try .init(position: 1, text: "ANNOTATION")]
        let output = try DicomFilmCompositor(textRasterizer: SolidText()).compose(input)
        XCTAssertEqual(output.slotRectangles[0].height, 56)
        XCTAssertEqual(output.pixelData.suffix(64 * 8), Data(repeating: 255, count: 64 * 8))
        XCTAssertThrowsError(try DicomFilmCompositor(textRasterizer: BrokenText()).compose(input))
        XCTAssertThrowsError(try DicomFilmCompositor(textRasterizer: BlankText()).compose(input))
        XCTAssertFalse(try DicomCoreTextPrintRasterizer().rasterize("PRINT", width: 128, height: 24).allSatisfy { $0 == 0 })
    }

    func test_limitsAndInvalidGeometry_failBeforeAllocation() throws {
        var input = try description()
        input.outputWidth = Int.max
        XCTAssertThrowsError(try DicomFilmCompositor().compose(input))
        input.outputWidth = 8
        input.printerPixelSpacing = (row: .leastNonzeroMagnitude, column: 1)
        XCTAssertThrowsError(try DicomFilmCompositor().compose(input))
        XCTAssertThrowsError(try DicomFilmGeometry.slots(format: .standard(columns: Int.max, rows: 2),
            bounds: .init(x: 0, y: 0, width: 8, height: 8)))
    }

    func test_nativeTwelveBitLUT_preservesAdjacentIndices() throws {
        var input = try description()
        input.outputWidth = 2
        input.nativeGrayscaleSamples[1] = [0, 1, 2, 4095]
        input.nativeBitsStored[1] = 12
        var values = [UInt16](repeating: 0, count: 4096)
        values[1] = 1023
        input.presentationLUT = try .init(descriptor: [4096, 0, 10], values: values)
        XCTAssertEqual(try DicomFilmCompositor().compose(input).pixelData, Data([0, 255, 0, 0]))
    }

    func test_densityTrimAndInterpolation_affectPixels() throws {
        var input = try description()
        input.film.imageBoxes = []
        input.film.filmBox.emptyImageDensity = "100"
        let density = try DicomFilmCompositor().compose(input)
        XCTAssertEqual(Set(density.pixelData).count, 1)
        XCTAssertGreaterThan(density.pixelData[0], 0)
        XCTAssertLessThan(density.pixelData[0], 255)
        input.film.filmBox.trim = true
        let trimmed = try DicomFilmCompositor().compose(input)
        XCTAssertEqual(trimmed.pixelData[0], 255)
        XCTAssertEqual(trimmed.pixelData[9], density.pixelData[0])
        input = try description()
        let nearest = try DicomFilmCompositor().compose(input)
        input.film.filmBox.magnificationType = "BILINEAR"
        let bilinear = try DicomFilmCompositor().compose(input)
        input.film.filmBox.magnificationType = "CUBIC"
        let cubic = try DicomFilmCompositor().compose(input)
        XCTAssertNotEqual(nearest.pixelData, bilinear.pixelData)
        XCTAssertEqual(cubic.width, bilinear.width)
    }

    func test_physicalFilmTable_supportsEveryRequiredIdentifier() throws {
        for identifier in ["8INX10IN", "8_5INX11IN", "10INX12IN", "10INX14IN", "11INX14IN", "11INX17IN",
                           "14INX14IN", "14INX17IN", "24CMX24CM", "24CMX30CM", "A4", "A3"] {
            let size = try DicomPhysicalFilmSize(filmSizeID: identifier)
            XCTAssertGreaterThan(size.widthMillimeters, 0)
            XCTAssertGreaterThanOrEqual(size.heightMillimeters, size.widthMillimeters)
        }
    }

    func test_gsdfInverse_matchesNormativeRangeEndpoints() {
        XCTAssertEqual(DicomFilmCompositor.jndIndex(luminance: 0.05), 1, accuracy: 0.3)
        XCTAssertEqual(DicomFilmCompositor.jndIndex(luminance: 4000), 1023, accuracy: 0.3)
    }

    private struct SolidText: DicomPrintTextRasterizing {
        func rasterize(_ text: String, width: Int, height: Int) throws -> Data { Data(repeating: 255, count: width * height) }
    }
    private struct BlankText: DicomPrintTextRasterizing {
        func rasterize(_ text: String, width: Int, height: Int) throws -> Data { Data(repeating: 0, count: width * height) }
    }
    private struct BrokenText: DicomPrintTextRasterizing {
        func rasterize(_ text: String, width: Int, height: Int) throws -> Data { throw DicomFilmCompositionError.textRasterizationFailed }
    }
}
