import DicomData
import XCTest

/// Issue #2835: a value over 64 KiB in a 16-bit-length VR is written as UN in Explicit VR, and a public UN whose
/// dictionary gives one VR is read back with that VR.
final class DicomOversizedShortLengthValueTests: XCTestCase {
    /// A structure set's Contour Data (3006,0050, DS) of 6 000 points, about 110 KiB.
    private func contourDataSet() -> (DicomDataSet, [String]) {
        let values = (0..<18_000).map { String(format: "%.3f", Double($0) * 0.125 - 900) }
        let contour = DicomDataSet(elements: [
            DicomDataElement(tag: 0x3006_0042, vr: .CS, value: .strings(["CLOSED_PLANAR"])),
            DicomDataElement(tag: 0x3006_0046, vr: .IS, value: .strings(["6000"])),
            DicomDataElement(tag: 0x3006_0050, vr: .DS, value: .strings(values))
        ])
        let roiContour = DicomDataSet(elements: [
            DicomDataElement(tag: 0x3006_0040, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: contour)]))
        ])
        return (DicomDataSet(elements: [
            DicomDataElement(tag: 0x0008_0016, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.481.3"])),
            DicomDataElement(tag: 0x3006_0039, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: roiContour)]))
        ]), values)
    }

    private func contourValues(_ dataSet: DicomDataSet) -> DicomDataElement? {
        dataSet.sequenceItems(for: 0x3006_0039).first?.dataSet.sequenceItems(for: 0x3006_0040).first?
            .dataSet.element(for: 0x3006_0050)
    }

    func test_largeContourData_implicitToExplicit_roundTripsThroughUN() throws {
        let (source, values) = contourDataSet()
        let implicit = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: .implicitVRLittleEndian)
        let read = try DicomDataSetParser.read(from: implicit, transferSyntax: .implicitVRLittleEndian).dataSet
        XCTAssertEqual(contourValues(read)?.stringValues.count, values.count)

        let explicit = try DicomDataSetWriter.dataSetData(from: read, transferSyntax: .explicitVRLittleEndian)
        XCTAssertNotNil(explicit.range(of: Data([0x06, 0x30, 0x50, 0x00]) + Data("UN".utf8) + Data([0, 0])),
                        "the oversized Contour Data is written as UN with a 32-bit length")

        let reread = try DicomDataSetParser.read(from: explicit, transferSyntax: .explicitVRLittleEndian)
        XCTAssertTrue(reread.diagnostics.isEmpty, "\(reread.diagnostics)")
        let element = try XCTUnwrap(contourValues(reread.dataSet))
        XCTAssertEqual(element.vr, .DS, "the public UN takes the dictionary's single VR back")
        XCTAssertEqual(element.stringValues, values)
    }

    func test_publicUNWithSeveralDictionaryVRs_staysOpaque() throws {
        // LUT Data (0028,3006) is "US or OW": its UN keeps the contextual rules, so it stays bytes.
        let bytes = Data([0x01, 0x00, 0x02, 0x00])
        var explicit = Data([0x28, 0x00, 0x06, 0x30]) + Data("UN".utf8) + Data([0, 0])
        explicit += Data([0x04, 0x00, 0x00, 0x00]) + bytes
        let read = try DicomDataSetParser.read(from: explicit, transferSyntax: .explicitVRLittleEndian).dataSet
        XCTAssertEqual(read.element(for: 0x0028_3006)?.vr, .UN)
    }
}
