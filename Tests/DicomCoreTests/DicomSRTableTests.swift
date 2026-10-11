import Foundation
import XCTest
@testable import DicomCore

/// TABLE content items read into a typed table and render (PS3.3 C.18.10, issue #3021).
final class DicomSRTableTests: XCTestCase {
    func test_tableContentItem_readsDefinitionsCellsAndRenders() throws {
        let report = try XCTUnwrap(try DCMDecoder(data: Self.reportWithTable()).structuredReport)
        let item = try XCTUnwrap(report.root.flattened.first { $0.valueType == "TABLE" })
        let table = try XCTUnwrap(item.table)

        XCTAssertEqual(table.rowCount, 2)
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertEqual(table.rowDefinition(2)?.conceptName?.codeMeaning, "Lesion 2")
        XCTAssertEqual(table.columnDefinition(1)?.conceptName?.codeMeaning, "Long axis")
        XCTAssertEqual(table.columnDefinition(1)?.measurementUnits?.codeValue, "mm")
        // A single-cell item, a multi-valued column item and a coded cell.
        XCTAssertEqual(table.cell(row: 1, column: 1)?.value, .numeric(12.5))
        XCTAssertEqual(table.cell(row: 2, column: 1)?.value, .numeric(8))
        XCTAssertEqual(table.cell(row: 1, column: 2)?.value, .numeric(7))
        XCTAssertEqual(table.cell(row: 2, column: 2)?.value, .numeric(6))
        XCTAssertEqual(table.units(row: 2, column: 2)?.codeValue, "mm")
        XCTAssertEqual(table.cell(row: 1, column: 3)?.value,
                       .code(DicomCodedConcept(codeValue: "T-28000", codingSchemeDesignator: "SRT", codeMeaning: "Lung")))
        XCTAssertEqual(table.cell(row: 2, column: 3)?.value, .text("Liver"))

        let rows = DicomStructuredReportRenderer.tableRows(table)
        XCTAssertEqual(rows, [
            ["", "Long axis", "Short axis", "Site"],
            ["Lesion 1", "12.5 mm", "7 mm", "Lung"],
            ["Lesion 2", "8 mm", "6 mm", "Liver"],
        ])
        XCTAssertTrue(DicomStructuredReportRenderer.text(report).contains("TABLE Lesions: Lesion 1: Long axis 12.5 mm"))
        XCTAssertTrue(DicomStructuredReportRenderer.html(report).contains("<tr><td>Lesion 2</td><td>8 mm</td><td>6 mm</td><td>Liver</td></tr>"))
    }

    func test_sparseTableAndReferenceCells_areKept() throws {
        let item = DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.valueType.rawValue, vr: .CS, value: .strings(["TABLE"])),
            Self.table(rows: 2, columns: 2, cells: [
                DicomDataSet(elements: [
                    DicomDataElement(tag: 0x0040A804, vr: .UL, value: .unsignedIntegers([2])),
                    DicomDataElement(tag: 0x0040A805, vr: .UL, value: .unsignedIntegers([2])),
                    DicomDataElement(tag: 0x0040DB73, vr: .UL, value: .unsignedIntegers([1, 2])),
                ]),
            ]),
        ])

        let table = try XCTUnwrap(DicomSRTable(contentItem: item))

        XCTAssertNil(table.cell(row: 1, column: 1))
        XCTAssertEqual(table.cell(row: 2, column: 2)?.value, .reference([1, 2]))
    }

    private static func code(_ value: String, _ scheme: String, _ meaning: String) -> DicomDataSet {
        DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.codeValue.rawValue, vr: .SH, value: .strings([value])),
            DicomDataElement(tag: DicomTag.codingSchemeDesignator.rawValue, vr: .SH, value: .strings([scheme])),
            DicomDataElement(tag: DicomTag.codeMeaning.rawValue, vr: .LO, value: .strings([meaning])),
        ])
    }

    private static func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: .SQ, value: .sequence(items.map { DicomSequenceItem(dataSet: $0) }))
    }

    private static func table(rows: Int, columns: Int, rowDefinitions: [DicomDataSet] = [],
                              columnDefinitions: [DicomDataSet] = [], cells: [DicomDataSet]) -> DicomDataElement {
        sequence(0x0040A801, [DicomDataSet(elements: [
            DicomDataElement(tag: 0x0040A802, vr: .UL, value: .unsignedIntegers([UInt(rows)])),
            DicomDataElement(tag: 0x0040A803, vr: .UL, value: .unsignedIntegers([UInt(columns)])),
            sequence(0x0040A806, rowDefinitions),
            sequence(0x0040A807, columnDefinitions),
            sequence(0x0040A808, cells),
        ])])
    }

    static func reportWithTable() throws -> Data {
        let millimetres = code("mm", "UCUM", "millimeter")
        func axis(_ numberTag: Int, _ number: Int, _ concept: DicomDataSet, units: DicomDataSet? = nil) -> DicomDataSet {
            DicomDataSet(elements: [
                DicomDataElement(tag: numberTag, vr: .UL, value: .unsignedIntegers([UInt(number)])),
                sequence(0x0040A043, [concept]),
            ] + (units.map { [sequence(0x004008EA, [$0])] } ?? []))
        }
        let tableItem = DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.relationshipType.rawValue, vr: .CS, value: .strings(["CONTAINS"])),
            DicomDataElement(tag: DicomTag.valueType.rawValue, vr: .CS, value: .strings(["TABLE"])),
            sequence(DicomTag.conceptNameCodeSequence.rawValue, [code("99TBL", "99ISIS", "Lesions")]),
            table(rows: 2, columns: 3,
                  rowDefinitions: [axis(0x0040A804, 1, code("L1", "99ISIS", "Lesion 1")),
                                   axis(0x0040A804, 2, code("L2", "99ISIS", "Lesion 2"))],
                  columnDefinitions: [axis(0x0040A805, 1, code("LA", "99ISIS", "Long axis"), units: millimetres),
                                      axis(0x0040A805, 2, code("SA", "99ISIS", "Short axis"), units: millimetres),
                                      axis(0x0040A805, 3, code("ST", "99ISIS", "Site"))],
                  cells: [
                      DicomDataSet(elements: [
                          DicomDataElement(tag: 0x0040A804, vr: .UL, value: .unsignedIntegers([1])),
                          DicomDataElement(tag: 0x0040A805, vr: .UL, value: .unsignedIntegers([1])),
                          DicomDataElement(tag: 0x00720050, vr: .CS, value: .strings(["DS"])),
                          DicomDataElement(tag: 0x00720072, vr: .DS, value: .strings(["12.5"])),
                      ]),
                      DicomDataSet(elements: [
                          DicomDataElement(tag: 0x0040A804, vr: .UL, value: .unsignedIntegers([2])),
                          DicomDataElement(tag: 0x0040A805, vr: .UL, value: .unsignedIntegers([1])),
                          DicomDataElement(tag: 0x00720050, vr: .CS, value: .strings(["FD"])),
                          DicomDataElement(tag: 0x00720074, vr: .FD, value: .floats([8])),
                      ]),
                      DicomDataSet(elements: [
                          DicomDataElement(tag: 0x0040A805, vr: .UL, value: .unsignedIntegers([2])),
                          DicomDataElement(tag: 0x00720050, vr: .CS, value: .strings(["US"])),
                          DicomDataElement(tag: 0x0072007A, vr: .US, value: .unsignedIntegers([7, 6])),
                      ]),
                      DicomDataSet(elements: [
                          DicomDataElement(tag: 0x0040A804, vr: .UL, value: .unsignedIntegers([1])),
                          DicomDataElement(tag: 0x0040A805, vr: .UL, value: .unsignedIntegers([3])),
                          DicomDataElement(tag: 0x00720050, vr: .CS, value: .strings(["SQ"])),
                          sequence(0x0040A168, [code("T-28000", "SRT", "Lung")]),
                      ]),
                      DicomDataSet(elements: [
                          DicomDataElement(tag: 0x0040A804, vr: .UL, value: .unsignedIntegers([2])),
                          DicomDataElement(tag: 0x0040A805, vr: .UL, value: .unsignedIntegers([3])),
                          DicomDataElement(tag: 0x00720050, vr: .CS, value: .strings(["UC"])),
                          DicomDataElement(tag: 0x0072006F, vr: .UC, value: .strings(["Liver"])),
                      ]),
                  ]),
        ])
        let sopInstanceUID = "2.25.30210001"
        let dataSet = DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI,
                             value: .strings([DicomSRDocument.comprehensiveSRStorageSOPClassUID])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([sopInstanceUID])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.30210002"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.30210003"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["SR"])),
            DicomDataElement(tag: DicomTag.valueType.rawValue, vr: .CS, value: .strings(["CONTAINER"])),
            DicomDataElement(tag: DicomTag.continuityOfContent.rawValue, vr: .CS, value: .strings(["SEPARATE"])),
            sequence(DicomTag.conceptNameCodeSequence.rawValue, [code("126000", "DCM", "Imaging Measurement Report")]),
            DicomDataElement(tag: DicomTag.completionFlag.rawValue, vr: .CS, value: .strings(["COMPLETE"])),
            DicomDataElement(tag: DicomTag.verificationFlag.rawValue, vr: .CS, value: .strings(["UNVERIFIED"])),
            sequence(DicomTag.contentSequence.rawValue, [tableItem]),
        ])
        return try DicomDataSetWriter.part10Data(from: dataSet, options: DicomPart10WriterOptions(
            transferSyntax: .explicitVRLittleEndian,
            mediaStorageSOPClassUID: DicomSRDocument.comprehensiveSRStorageSOPClassUID,
            mediaStorageSOPInstanceUID: sopInstanceUID
        ))
    }
}
