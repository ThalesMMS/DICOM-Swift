import XCTest
@testable import DicomData

final class DicomContrastBolusModuleTests: XCTestCase {
    func test_additionalDrugSequence_isValidatedAtTheRoot() {
        let code = DicomDataSet(elements: [
            .init(tag: 0x00080100, vr: .SH, value: .strings(["123"])),
            .init(tag: 0x00080102, vr: .SH, value: .strings(["DCM"])),
            .init(tag: 0x00080104, vr: .LO, value: .strings(["Drug"]))
        ])
        for valid in [false, true] {
            let dataSet = DicomDataSet(elements: [
                .init(tag: 0x00180010, vr: .LO, value: .empty),
                .init(tag: 0x0018002A, vr: .SQ, value: .sequence([.init(dataSet: valid ? code : .init())]))
            ])
            let report = DicomContrastBolusModule.validate(dataSet)
            XCTAssertEqual(report[.attributes], valid ? .passed : .failed)
            if !valid { XCTAssertTrue(report.diagnostics.contains { $0.path.starts(with: [.tag(0x0018002A), .item(0)]) }) }
        }
        let onlyDrug = DicomDataSet(elements: [.init(tag: 0x0018002A, vr: .SQ, value: .sequence([.init(dataSet: code)]))])
        XCTAssertTrue(DicomContrastBolusModule.applies(to: onlyDrug))
    }
}
