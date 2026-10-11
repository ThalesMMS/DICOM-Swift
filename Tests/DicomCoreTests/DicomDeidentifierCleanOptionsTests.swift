import DicomCore
@testable import DicomData
import Foundation
import XCTest

/// Clean Pixel Data and Clean Recognizable Visual Features (PS3.15 E.3.1/E.3.2) and Clean Structured Content
/// guided by Table E.3.4-1 (issue #3020).
final class DicomDeidentifierCleanOptionsTests: XCTestCase {
    private func str(_ tag: Int, _ vr: DicomVR, _ values: [String]) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings(values)) }
    private func num(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers([value])) }
    private func item(_ elements: [DicomDataElement]) -> DicomSequenceItem { .init(dataSet: DicomDataSet(elements: elements)) }

    /// An 8x8 MONOCHROME2 8-bit image filled with 200, with an icon and an overlay plane.
    private func image(burnedIn: String?, modality: String = "OT", ultrasoundRegion: (Int, Int, Int, Int)? = nil,
                       content: [DicomSequenceItem] = [], acquisitionContext: [DicomSequenceItem] = []) throws -> Data {
        var elements: [DicomDataElement] = [
            str(0x00080016, .UI, ["1.2.840.10008.5.1.4.1.1.7"]), str(0x00080018, .UI, ["2.25.30200001"]),
            str(0x0020000D, .UI, ["2.25.30200002"]), str(0x0020000E, .UI, ["2.25.30200003"]),
            str(0x00100010, .PN, ["SENTINEL^PATIENT"]), str(0x00080060, .CS, [modality]), str(0x00080070, .LO, ["Vendor"]),
            str(0x00081090, .LO, ["Model 1"]),
            num(0x00280002, 1), str(0x00280004, .CS, ["MONOCHROME2"]), num(0x00280010, 8), num(0x00280011, 8), num(0x00280100, 8),
            num(0x00280101, 8), num(0x00280102, 7), num(0x00280103, 0),
            DicomDataElement(tag: 0x00880200, vr: .SQ, value: .sequence([item([num(0x00280010, 1), num(0x00280011, 1)])])),
            num(0x60000010, 8), num(0x60000011, 8), str(0x60000040, .CS, ["G"]),
            DicomDataElement(tag: 0x60003000, vr: .OW, value: .bytes(Data(repeating: 0xFF, count: 8))),
            DicomDataElement(tag: 0x7FE00010, vr: .OB, value: .bytes(Data(repeating: 200, count: 64)))
        ]
        if let burnedIn { elements.append(str(0x00280301, .CS, [burnedIn])) }
        if let (x0, y0, x1, y1) = ultrasoundRegion {
            elements.append(DicomDataElement(tag: 0x00186011, vr: .SQ, value: .sequence([item([
                num(0x00186012, 1), num(0x00186014, 1),
                DicomDataElement(tag: 0x00186018, vr: .UL, value: .unsignedIntegers([UInt(x0)])),
                DicomDataElement(tag: 0x0018601A, vr: .UL, value: .unsignedIntegers([UInt(y0)])),
                DicomDataElement(tag: 0x0018601C, vr: .UL, value: .unsignedIntegers([UInt(x1)])),
                DicomDataElement(tag: 0x0018601E, vr: .UL, value: .unsignedIntegers([UInt(y1)]))
            ])])))
        }
        if !content.isEmpty { elements.append(DicomDataElement(tag: 0x0040A730, vr: .SQ, value: .sequence(content))) }
        if !acquisitionContext.isEmpty { elements.append(DicomDataElement(tag: 0x00400555, vr: .SQ, value: .sequence(acquisitionContext))) }
        return try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: elements))
    }

    private func reopen(_ data: Data) throws -> DicomDataSet { try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: data)) }

    private func methodCodes(_ dataSet: DicomDataSet) -> [String?] {
        dataSet[0x00120064]?.sequenceItems.map { $0[0x00080100]?.stringValue } ?? []
    }

    private func pixels(_ dataSet: DicomDataSet) throws -> [UInt8] { Array(try XCTUnwrap(dataSet.element(for: .pixelData)?.bytesValue)) }

    // MARK: - Clean Pixel Data

    func test_cleanPixelData_callerRegions_blankThemAndRecord113101() throws {
        let profile = DicomDeidentificationProfile(options: [.cleanPixelData], pixelRedactionRegions: [.init(x: 0, y: 0, width: 8, height: 2)])
        let (data, report) = try DicomDeidentifier(profile: profile, session: .init()).apply(try image(burnedIn: "YES"))
        let output = try reopen(data)
        let samples = try pixels(output)
        XCTAssertEqual(Array(samples[0..<16]), Array(repeating: 0, count: 16), "the caller's rows are blanked")
        XCTAssertEqual(Array(samples[16...]), Array(repeating: 200, count: 48), "the rest is untouched")
        XCTAssertEqual(output[0x00280301]?.stringValue, "NO")
        XCTAssertNil(output[0x00880200], "the icon is derived from the uncleaned pixels")
        XCTAssertTrue(output.elements.allSatisfy { !(0x6000...0x601E).contains($0.group) }, "overlay planes are removed")
        XCTAssertEqual(methodCodes(output), ["113100", "113101"])
        XCTAssertTrue(output[0x00120063]?.stringValues.contains("Clean Pixel Data Option") == true)
        XCTAssertEqual(report.classification, .deidentifiedPerProfile)
        XCTAssertTrue(report.actions.contains { $0.tag == 0x7FE00010 && $0.note == "Clean Pixel Data: caller regions" })
    }

    func test_cleanPixelData_ultrasoundRegions_blankEverythingOutsideThem() throws {
        let profile = DicomDeidentificationProfile(options: [.cleanPixelData])
        let (data, report) = try DicomDeidentifier(profile: profile, session: .init())
            .apply(try image(burnedIn: nil, modality: "US", ultrasoundRegion: (2, 2, 5, 5)))
        let samples = try pixels(try reopen(data))
        for row in 0..<8 {
            for column in 0..<8 {
                let inside = (2...5).contains(row) && (2...5).contains(column)
                XCTAssertEqual(samples[row * 8 + column], inside ? 200 : 0, "(\(column),\(row))")
            }
        }
        XCTAssertEqual(report.classification, .deidentifiedPerProfile)
        XCTAssertTrue(report.actions.contains { $0.note == "Clean Pixel Data: outside ultrasound regions" })
    }

    func test_cleanPixelData_matchingDeviceTemplate_addsItsRegions() throws {
        XCTAssertTrue(DicomPixelRedactionTemplate.verified.isEmpty, "no template ships without a check on real samples")
        let template = DicomPixelRedactionTemplate(name: "Vendor Model 1", modality: "OT", manufacturer: "vendor", modelName: "MODEL 1",
                                                   regions: [.init(x: 6, y: 0, width: 4, height: 8)])
        let other = DicomPixelRedactionTemplate(name: "Other", modality: "CT", manufacturer: "Vendor", regions: [.init(x: 0, y: 0, width: 8, height: 8)])
        let profile = DicomDeidentificationProfile(options: [.cleanPixelData], pixelRedactionTemplates: [template, other])
        let (data, report) = try DicomDeidentifier(profile: profile, session: .init()).apply(try image(burnedIn: "YES"))
        let samples = try pixels(try reopen(data))
        XCTAssertEqual((0..<8).map { samples[$0 * 8 + 6] }, Array(repeating: 0, count: 8), "clipped to the matrix")
        XCTAssertEqual((0..<8).map { samples[$0 * 8 + 5] }, Array(repeating: 200, count: 8), "only the matching template applies")
        XCTAssertTrue(report.actions.contains { $0.note == "Clean Pixel Data: template Vendor Model 1" })
    }

    func test_cleanPixelData_withoutAnApplicableRule_neverPassesAsClean() throws {
        let session = DicomDeidentificationSession()
        let unknown = try image(burnedIn: nil)
        let (data, report) = try DicomDeidentifier(profile: .init(options: [.cleanPixelData]), session: session).apply(unknown)
        let output = try reopen(data)
        XCTAssertEqual(report.classification, .incomplete)
        XCTAssertTrue(report.findings.contains { $0.kind == .pixelDataNotCleaned })
        XCTAssertEqual(methodCodes(output), ["113100"], "113101 is recorded only for cleaned pixels")
        XCTAssertNil(output[0x00280301])
        XCTAssertEqual(try pixels(output), Array(repeating: 200, count: 64))

        let burned = try image(burnedIn: "YES")
        XCTAssertThrowsError(try DicomDeidentifier(profile: .init(options: [.cleanPixelData]), session: session).apply(burned)) {
            XCTAssertEqual($0 as? DicomDeidentificationError, .rejected(.burnedInAnnotation))
        }
        let accepted = try DicomDeidentifier(profile: .init(options: [.cleanPixelData], burnedInAnnotationPolicy: .accept), session: session).apply(burned)
        XCTAssertEqual(accepted.report.classification, .incomplete, "accepting the pixels does not make them cleaned")
        XCTAssertEqual(accepted.report.findings.map(\.kind), [.pixelDataNotCleaned])
    }

    func test_cleanRecognizableVisualFeatures_isRecordedAs113102() throws {
        let (data, _) = try DicomDeidentifier(profile: .init(options: [.cleanRecognizableVisualFeatures]), session: .init())
            .apply(try image(burnedIn: "NO"))
        XCTAssertEqual(methodCodes(try reopen(data)), ["113100", "113102"])
    }

    // MARK: - Clean Structured Content (Table E.3.4-1)

    private func contentItem(_ valueType: String, code: String, scheme: String = "DCM", version: String? = nil,
                             _ value: DicomDataElement) -> DicomSequenceItem {
        var concept = [str(0x00080100, .SH, [code]), str(0x00080102, .SH, [scheme]), str(0x00080104, .LO, ["concept"])]
        if let version { concept.append(str(0x00080103, .SH, [version])) }
        return item([str(0x0040A010, .CS, ["CONTAINS"]), str(0x0040A040, .CS, [valueType]),
                     DicomDataElement(tag: 0x0040A043, vr: .SQ, value: .sequence([item(concept)])), value])
    }

    func test_table_answersContentItemConceptsByCodeSchemeVersionAndValueType() throws {
        let table = DicomDeidentificationTable.standard
        XCTAssertEqual(table.structuredContentEntries.count, 214)
        XCTAssertEqual(table.structuredContentEntry(codeValue: "121029", scheme: "DCM", valueType: "PNAME")?.basic, .dummy)
        XCTAssertNil(table.structuredContentEntry(codeValue: "121029", scheme: "DCM", valueType: "TEXT"))
        XCTAssertEqual(table.structuredContentEntry(codeValue: "15", scheme: "NCDR", schemeVersion: "2.0b", valueType: "DATETIME")?.meaning,
                       "Admission DateTime")
        XCTAssertNil(table.structuredContentEntry(codeValue: "15", scheme: "NCDR", schemeVersion: "3.0", valueType: "DATETIME"))
        let acquisitionDate = try XCTUnwrap(table.structuredContentEntry(codeValue: "126201", scheme: "dcm", valueType: "DATE"))
        XCTAssertEqual(acquisitionDate.action(with: []), .remove)
        XCTAssertEqual(acquisitionDate.action(with: [.retainLongitudinalModifiedDates]), .clean)
        XCTAssertEqual(acquisitionDate.action(with: [.retainLongitudinalFullDates]), .keep)
    }

    func test_cleanStructuredContent_appliesTableE341ToListedConcepts() throws {
        let content = [
            contentItem("PNAME", code: "121029", str(0x0040A123, .PN, ["SENTINEL^SUBJECT"])),
            contentItem("TEXT", code: "121022", str(0x0040A160, .UT, ["SENTINEL-ACCESSION"])),
            contentItem("DATE", code: "126201", str(0x0040A121, .DA, ["20240115"])),
            contentItem("UIDREF", code: "121012", str(0x0040A124, .UI, ["2.25.30200099"])),
            contentItem("TEXT", code: "53", scheme: "NCDR", version: "2.0b", str(0x0040A160, .UT, ["SENTINEL-NCDR"])),
            contentItem("TEXT", code: "121071", str(0x0040A160, .UT, ["SENTINEL UNLISTED"]))
        ]
        let source = try image(burnedIn: "NO", content: content,
                               acquisitionContext: [contentItem("TEXT", code: "121022", str(0x0040A160, .UT, ["SENTINEL-CONTEXT"]))])
        func run(_ options: Set<DicomDeidentificationTable.Option>) throws -> (DicomDataSet, DicomDeidentificationReport) {
            let (data, report) = try DicomDeidentifier(profile: .init(options: options), session: .init(dateShiftDays: -40)).apply(source)
            return (try reopen(data), report)
        }

        let (basic, report) = try run([.cleanStructuredContent])
        let items = try XCTUnwrap(basic[0x0040A730]?.sequenceItems)
        XCTAssertEqual(items.map { $0[0x0040A040]?.stringValue }, ["PNAME", "UIDREF", "TEXT"],
                       "X removes Accession Number, Acquisition Date and the NCDR procedure number")
        XCTAssertEqual(items[0][0x0040A123]?.stringValue, "ANONYMOUS", "Subject Name is D")
        XCTAssertNotEqual(items[1][0x0040A124]?.stringValue, "2.25.30200099", "Device Observer UID X/D is remapped")
        XCTAssertEqual(items[2][0x0040A160]?.stringValue, "REMOVED", "an unlisted concept falls back to its value type")
        XCTAssertEqual(basic[0x00400555]?.sequenceItems.count, 0, "the Acquisition Context Sequence follows the same table")
        XCTAssertFalse(DicomDeidentifierTests.flatten(basic).contains("SENTINEL"))
        XCTAssertTrue(report.actions.contains { $0.note == "E.3.4-1 Accession Number: X (content item removed)" })
        XCTAssertEqual(methodCodes(basic), ["113100", "113104"])

        let (shifted, _) = try run([.cleanStructuredContent, .retainLongitudinalModifiedDates])
        let date = try XCTUnwrap(shifted[0x0040A730]?.sequenceItems.first { $0[0x0040A040]?.stringValue == "DATE" })
        XCTAssertEqual(date[0x0040A121]?.stringValue, "20231206", "Acquisition Date is C with modified dates")

        let (retained, _) = try run([.cleanStructuredContent, .retainLongitudinalFullDates, .retainUIDs])
        let retainedItems = try XCTUnwrap(retained[0x0040A730]?.sequenceItems)
        XCTAssertEqual(retainedItems.first { $0[0x0040A040]?.stringValue == "DATE" }?[0x0040A121]?.stringValue, "20240115")
        XCTAssertEqual(retainedItems.first { $0[0x0040A040]?.stringValue == "UIDREF" }?[0x0040A124]?.stringValue, "2.25.30200099")
    }
}
