import DicomData
import Foundation
import XCTest

final class DicomDataProductTests: XCTestCase {
    func test_datasetOnlyConsumer_roundTripsWithoutCodecOrUIProducts() throws {
        let source = DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["Synthetic^Only"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([16]))
        ])
        let bytes = try DicomDataSetWriter.dataSetData(from: source)
        let result = try DicomDataSetParser.dataSet(from: bytes)
        XCTAssertEqual(result.string(for: .patientName), "Synthetic^Only")
        XCTAssertEqual(result.int(for: .rows), 16)
        XCTAssertEqual(DCMDictionary().vrCode(forTag: DicomTag.patientName.rawValue), "PN")
    }

    func test_datasetOnlyConsumer_rejectsExceededElementBudget() throws {
        let source = DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([16]))
        ])
        let bytes = try DicomDataSetWriter.dataSetData(from: source)
        let limits = DicomDataSetParseLimits(maximumSequenceDepth: 0, maximumElementCount: 0, maximumItemCount: 0)
        XCTAssertThrowsError(try DicomDataSetParser.dataSet(from: bytes, limits: limits)) { error in
            XCTAssertEqual(error as? DicomDataSetParseError, .maximumElementCountExceeded(limit: 0))
        }
    }
}
