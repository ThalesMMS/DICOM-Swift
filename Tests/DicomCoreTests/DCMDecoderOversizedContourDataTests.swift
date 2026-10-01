import DicomCore
import XCTest

/// Issue #2835: a structure set whose Contour Data went out as UN (over 64 KiB, Explicit VR) keeps its contours
/// through `DCMDecoder`, the path the RT loaders read.
final class DCMDecoderOversizedContourDataTests: XCTestCase {
    func test_contourDataWrittenAsUN_readsBackAsDecimalStrings() throws {
        let values = (0..<18_000).map { Double($0) * 0.125 - 900 }
        let contour = DicomDataSet(elements: [
            DicomDataElement(tag: 0x3006_0050, vr: .DS, value: .strings(values.map { String(format: "%.3f", $0) }))
        ])
        let roiContour = DicomDataSet(elements: [
            DicomDataElement(tag: 0x3006_0040, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: contour)]))
        ])
        let sopClassUID = "1.2.840.10008.5.1.4.1.1.481.3"
        let data = try DicomDataSetWriter.part10Data(
            from: DicomDataSet(elements: [
                DicomDataElement(tag: 0x0008_0016, vr: .UI, value: .strings([sopClassUID])),
                DicomDataElement(tag: 0x0008_0018, vr: .UI, value: .strings(["2.25.2835"])),
                DicomDataElement(tag: 0x3006_0039, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: roiContour)]))
            ]),
            options: DicomPart10WriterOptions(transferSyntax: .explicitVRLittleEndian,
                                              mediaStorageSOPClassUID: sopClassUID,
                                              mediaStorageSOPInstanceUID: "2.25.2835")
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rtstruct-2835-\(UUID()).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try DCMDecoder(contentsOf: url)
        let read = decoder.dataSet.sequenceItems(for: 0x3006_0039).first?.dataSet.sequenceItems(for: 0x3006_0040)
            .first?.dataSet.decimalStrings(for: 0x3006_0050)
        XCTAssertEqual(read, values)
    }
}
