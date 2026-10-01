import Foundation
import XCTest
@testable import DicomCore

final class DicomPrintLimitsTests: XCTestCase {
    func test_limitRefusal_doesNotAllocateBitmap() throws {
        var allocations = 0
        XCTAssertThrowsError(try DicomPrintJob(width: 100, height: 100,
            limits: .init(bytesPerImageBox: 10), makeBitmap: {
                allocations += 1
                return try DicomRenderedBitmap(width: 100, height: 100, rgbData: Data(count: 30000))
            }))
        XCTAssertEqual(allocations, 0)
        XCTAssertThrowsError(try DicomPrintLimits().validateDimensions(width: Int.max, height: Int.max))
    }
    func test_batchAndMultipleFilms_admittedBeforeAnyRenderer() throws {
        var allocations = 0
        let input = DicomPrintFilmInput(filmBox: .init(), images: [DicomPrintImageInput(width: 2, height: 2) {
            allocations += 1
            return try DicomRenderedBitmap(width: 2, height: 2, rgbData: Data(count: 12))
        }])
        XCTAssertThrowsError(try DicomPrintJob(inputs: [input, input], limits: .init(bytesPerJob: 23)))
        XCTAssertEqual(allocations, 0)
        XCTAssertThrowsError(try DicomPrintBatch(inputs: [[input], [input]], limits: .init(bytesPerJob: 23)))
        XCTAssertEqual(allocations, 0)
        XCTAssertNoThrow(try DicomPrintBatch(inputs: [[input], [input]], limits: .init(bytesPerJob: 24)))
        XCTAssertEqual(allocations, 2)
    }
    func test_layoutCapacityAndExplicitCount() throws {
        for (wire, count) in [("STANDARD\\2,3", 6), ("ROW\\1,2,3", 6), ("COL\\2,3", 5)] {
            let job = try printTestJob(layout: wire)
            XCTAssertEqual(job.effectiveFilms[0].imageBoxes.count, count)
        }
        for wire in ["SLIDE", "SUPERSLIDE", "CUSTOM\\1"] {
            var film = try printTestJob().films[0]
            film.filmBox.imageDisplayFormat = wire
            XCTAssertThrowsError(try DicomPrintJob(films: [film]))
            film.filmBox.expectedImageBoxCount = 1
            XCTAssertNoThrow(try DicomPrintJob(films: [film]))
        }
        var film = try printTestJob().films[0]
        film.filmBox.imageDisplayFormat = "ROW\\1,x"
        XCTAssertThrowsError(try DicomPrintJob(films: [film]))
    }
    func test_aggregateBudgets_refuseFilmJobAndBatch() throws {
        let films = try printTestJob(films: 2).films
        XCTAssertThrowsError(try DicomPrintJob(films: films, limits: .init(maximumFilmsPerJob: 1)))
        XCTAssertThrowsError(try DicomPrintJob(films: films, limits: .init(bytesPerFilm: 11)))
        XCTAssertThrowsError(try DicomPrintJob(films: films, limits: .init(bytesPerJob: 23)))
        XCTAssertThrowsError(try DicomPrintBatch(jobs: [printTestJob(), printTestJob()], limits: .init(bytesPerJob: 23)))
        XCTAssertNoThrow(try DicomPrintJob(films: films, limits: .init(bytesPerJob: 24)))
    }
    func test_lutDescriptor_validatedBeforeUse() throws {
        XCTAssertThrowsError(try DicomPresentationLUT(descriptor: [256, 1, 10], values: Array(repeating: 0, count: 256)))
        XCTAssertThrowsError(try DicomPresentationLUT(descriptor: [256, 0, 9], values: Array(repeating: 0, count: 256)))
        XCTAssertThrowsError(try DicomPresentationLUT(descriptor: [256, 0, 10], values: Array(repeating: 1024, count: 256)))
        XCTAssertNoThrow(try DicomPresentationLUT(descriptor: [256, 0, 10], values: Array(repeating: 1023, count: 256)))
    }
}
