import ArgumentParser
import DicomCore
import Foundation
import XCTest
@testable import dicomtool

/// `dicomtool image compare` (#2836): limits exit with status 65, and the difference image holds |reference − test|.
final class ImageCompareCommandTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("image-compare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func secondaryCapture(_ name: String, pixels: [UInt8]) throws -> URL {
        let dataSet = DicomSecondaryCaptureBuilder.dataSet(
            pixelData: try .monochrome8(columns: 2, rows: 2, data: Data(pixels)),
            options: .init(sopInstanceUID: "2.25.28360\(name.count)", studyInstanceUID: "2.25.28361",
                           seriesInstanceUID: "2.25.28362", patientName: "Cli^Case", patientID: "C-1",
                           seriesNumber: 1, instanceNumber: 1),
            requiredType2Attributes: .init())
        let url = directory.appendingPathComponent("\(name).dcm")
        try DicomDataSetWriter.part10Data(from: dataSet).write(to: url)
        return url
    }

    func test_compare_enforcesLimitsAndWritesTheDifferenceImage() throws {
        let reference = try secondaryCapture("reference", pixels: [10, 20, 30, 40])
        let test = try secondaryCapture("test", pixels: [10, 23, 30, 38])
        let difference = directory.appendingPathComponent("difference.dcm")

        var passing = try ImageCompareCommand.parse([reference.path, test.path, "--check-error", "3",
                                                     "--save-diff", difference.path, "--amplify", "10"])
        XCTAssertNoThrow(try passing.run())
        let diff = try DCMDecoder(contentsOf: difference)
        XCTAssertEqual(diff.getPixels16(), [0, 30, 0, 20])

        var failing = try ImageCompareCommand.parse([reference.path, test.path, "--check-error", "2"])
        XCTAssertThrowsError(try failing.run()) { XCTAssertEqual($0 as? ExitCode, ExitCode(65)) }
        var psnr = try ImageCompareCommand.parse([reference.path, test.path, "--check-psnr", "60"])
        XCTAssertThrowsError(try psnr.run()) { XCTAssertEqual($0 as? ExitCode, ExitCode(65)) }
    }
}
