import Foundation
import XCTest
@testable import DicomCore

final class DicomPixelEditorSafetyTests: XCTestCase {
    func test_partialRedaction_preservesBurnedInStatusAndDeidentificationChecks() throws {
        for status: String? in ["YES", "NO", nil] {
            var source = try CLIParityLibraryTests.gray16(frames: 2)
            source = DicomDataSet(elements: source.elements.filter { $0.tag != 0x0028_0301 })
            if let status { source.set(.init(tag: 0x0028_0301, vr: .CS, value: .strings([status]))) }
            let data = try CLIParityLibraryTests.part10(source)
            let edit = DicomPixelEdit(region: .init(x: 0, y: 0, width: 1, height: 1), sample: 0, frames: [0])
            let output = try DicomPixelEditor.apply(edit, part10: data)
            XCTAssertEqual(output.dataSet.string(for: 0x0028_0301), status)
            let reader = DicomDecodedFrameReader(decoder: try DCMDecoder(data: output.fileData))
            guard case .gray16(let untouched) = try reader.frame(at: 1).pixels else { return XCTFail("expected native frame") }
            XCTAssertEqual(Array(untouched), Array(100...111).map(UInt16.init))
            if status != "NO" {
                let deidentifier = try DicomDeidentifier(profile: .init(unknownBurnedInPolicy: .reject), session: .init())
                XCTAssertThrowsError(try deidentifier.apply(output.fileData))
            }
        }
    }
}
