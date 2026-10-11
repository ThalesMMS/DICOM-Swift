import XCTest
@testable import DicomCore

final class DicomDataSetTests: XCTestCase {
    func testTypedAccessorsParseStringNumericDateAndIdentityValues() {
        let acquisitionDateTime = 0x0008002A
        let dataSet = DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.patientName.rawValue,
                             vr: .PN,
                             value: .strings(["Doe^Jane^^Dr^PhD"]),
                             name: "Patient's Name"),
            DicomDataElement(tag: DicomTag.patientAge.rawValue,
                             vr: .AS,
                             value: .strings(["034Y"]),
                             name: "Patient's Age"),
            DicomDataElement(tag: DicomTag.studyDate.rawValue,
                             vr: .DA,
                             value: .strings(["20260528"]),
                             name: "Study Date"),
            DicomDataElement(tag: DicomTag.studyTime.rawValue,
                             vr: .TM,
                             value: .strings(["143015.250"]),
                             name: "Study Time"),
            DicomDataElement(tag: acquisitionDateTime,
                             vr: .DT,
                             value: .strings(["20260528143015.250-0300"]),
                             name: "Acquisition DateTime"),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue,
                             vr: .UI,
                             value: .strings(["1.2.840.10008.1"]),
                             name: "Study Instance UID"),
            DicomDataElement(tag: DicomTag.pixelSpacing.rawValue,
                             vr: .DS,
                             value: .strings(["0.5", "0.75"]),
                             name: "Pixel Spacing"),
            DicomDataElement(tag: DicomTag.instanceNumber.rawValue,
                             vr: .IS,
                             value: .strings(["42"]),
                             name: "Instance Number")
        ])

        let personName = dataSet.personName(for: .patientName)
        XCTAssertEqual(personName?.familyName, "Doe")
        XCTAssertEqual(personName?.givenName, "Jane")
        XCTAssertEqual(personName?.namePrefix, "Dr")
        XCTAssertEqual(personName?.nameSuffix, "PhD")

        let age = dataSet.age(for: .patientAge)
        XCTAssertEqual(age?.value, 34)
        XCTAssertEqual(age?.unit, .years)

        let date = dataSet.date(for: .studyDate)
        XCTAssertEqual(date?.year, 2026)
        XCTAssertEqual(date?.month, 5)
        XCTAssertEqual(date?.day, 28)

        let time = dataSet.time(for: .studyTime)
        XCTAssertEqual(time?.hour, 14)
        XCTAssertEqual(time?.minute, 30)
        XCTAssertEqual(time?.second, 15)
        XCTAssertEqual(time?.fractionalSeconds ?? 0, 0.250, accuracy: 0.0001)

        let dateTime = dataSet.dateTime(for: acquisitionDateTime)
        XCTAssertEqual(dateTime?.date.year, 2026)
        XCTAssertEqual(dateTime?.time?.hour, 14)
        XCTAssertEqual(dateTime?.timeZoneOffsetMinutes, -180)

        XCTAssertEqual(dataSet.uid(for: .studyInstanceUID)?.rawValue, "1.2.840.10008.1")
        XCTAssertEqual(dataSet.decimalStrings(for: .pixelSpacing), [0.5, 0.75])
        XCTAssertEqual(dataSet.vm(for: .pixelSpacing), DicomVM(count: 2))
        XCTAssertEqual(dataSet.integerString(for: .instanceNumber), 42)
    }

    func testNestedSequenceItemsAreNavigable() {
        let codeValue = 0x00080100
        let codeMeaning = 0x00080104
        let procedureCodeSequence = 0x00081032
        let nestedModifierSequence = 0x00080110

        let nestedItem = DicomSequenceItem(dataSet: DicomDataSet(elements: [
            DicomDataElement(tag: codeMeaning,
                             vr: .LO,
                             value: .strings(["Contrast enhanced"]),
                             name: "Code Meaning")
        ]))
        let procedureItem = DicomSequenceItem(dataSet: DicomDataSet(elements: [
            DicomDataElement(tag: codeValue,
                             vr: .SH,
                             value: .strings(["CTCHEST"]),
                             name: "Code Value"),
            DicomDataElement(tag: nestedModifierSequence,
                             vr: .SQ,
                             value: .sequence([nestedItem]),
                             name: "Modifier Sequence")
        ]))
        let dataSet = DicomDataSet(elements: [
            DicomDataElement(tag: procedureCodeSequence,
                             vr: .SQ,
                             value: .sequence([procedureItem]),
                             name: "Procedure Code Sequence")
        ])

        let item = dataSet.sequenceItems(for: procedureCodeSequence).first
        XCTAssertEqual(item?.dataSet.string(for: codeValue), "CTCHEST")
        XCTAssertEqual(
            item?.dataSet.sequenceItems(for: nestedModifierSequence).first?.dataSet.string(for: codeMeaning),
            "Contrast enhanced"
        )
    }

    func testUnknownPrivateTagIsPreservedAsElement() {
        let privateTag = 0x00111010
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let dataSet = DicomDataSet(elements: [
            DicomDataElement(tag: privateTag, vr: .UN, value: .bytes(payload))
        ])

        let element = dataSet.element(for: privateTag)
        XCTAssertNotNil(element)
        XCTAssertTrue(element?.isPrivate == true)
        XCTAssertEqual(element?.vr, .UN)
        XCTAssertEqual(element?.bytesValue, payload)
    }

    func testDecoderExposesTypedDataSetSnapshot() throws {
        let url = try makeMinimalDICOMFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let dataSet = decoder.dataSet
        let privateTag = 0x00111010

        XCTAssertEqual(dataSet.personName(for: .patientName)?.familyName, "Doe")
        XCTAssertEqual(dataSet.personName(for: .patientName)?.givenName, "Jane")
        XCTAssertEqual(dataSet.age(for: .patientAge)?.value, 45)
        XCTAssertEqual(dataSet.string(for: .modality), "CT")
        XCTAssertEqual(dataSet.int(for: .rows), 1)
        XCTAssertEqual(dataSet.int(for: .columns), 1)
        XCTAssertEqual(dataSet.decimalStrings(for: .pixelSpacing), [0.5, 0.75])
        XCTAssertEqual(dataSet.element(for: privateTag)?.stringValue, "private-value")
        XCTAssertTrue(dataSet.element(for: privateTag)?.isPrivate == true)
    }

    /// PS3.5 7.1 (issue #3015): 0001, 0003, 0005, 0007 and FFFF are odd but not private groups.
    func test_isPrivate_excludesTheOddGroupsThatMayNotBeUsed() {
        for group in [0x0001, 0x0003, 0x0005, 0x0007, 0xFFFF] {
            let element = DicomDataElement(tag: group << 16 | 0x0010, vr: .UN, value: .bytes(Data([0])))
            XCTAssertFalse(element.isPrivate, String(format: "group %04X", group))
        }
        XCTAssertTrue(DicomDataElement(tag: 0x0009_0010, vr: .LO, value: .strings(["CREATOR"])).isPrivate)
        XCTAssertFalse(DicomDataElement(tag: 0x0008_0060, vr: .CS, value: .strings(["CT"])).isPrivate)
    }

    private func makeMinimalDICOMFile() throws -> URL {
        var data = Data(count: 128)
        data.append(contentsOf: "DICM".utf8)

        appendUI(&data, group: 0x0002, element: 0x0010, value: "1.2.840.10008.1.2.1")
        appendString(&data, group: 0x0010, element: 0x0010, vr: "PN", value: "Doe^Jane", padding: 0x20)
        appendString(&data, group: 0x0010, element: 0x1010, vr: "AS", value: "045Y", padding: 0x20)
        appendString(&data, group: 0x0008, element: 0x0060, vr: "CS", value: "CT", padding: 0x20)
        appendString(&data, group: 0x0028, element: 0x0030, vr: "DS", value: "0.5\\0.75", padding: 0x20)
        appendString(&data, group: 0x0011, element: 0x1010, vr: "LO", value: "private-value", padding: 0x20)
        appendUS(&data, group: 0x0028, element: 0x0010, value: 1)
        appendUS(&data, group: 0x0028, element: 0x0011, value: 1)
        appendUS(&data, group: 0x0028, element: 0x0100, value: 16)
        appendUS(&data, group: 0x0028, element: 0x0101, value: 16)
        appendUS(&data, group: 0x0028, element: 0x0102, value: 15)
        appendUS(&data, group: 0x0028, element: 0x0103, value: 0)
        appendUS(&data, group: 0x0028, element: 0x0002, value: 1)
        appendString(&data, group: 0x0028, element: 0x0004, vr: "CS", value: "MONOCHROME2", padding: 0x20)
        appendPixelData(&data, value: 7)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("dcm")
        try data.write(to: url)
        return url
    }

    private func appendUS(_ data: inout Data, group: UInt16, element: UInt16, value: UInt16) {
        appendHeader(&data, group: group, element: element, vr: "US")
        data.append(contentsOf: [0x02, 0x00])
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { data.append(contentsOf: $0) }
    }

    private func appendUI(_ data: inout Data, group: UInt16, element: UInt16, value: String) {
        appendString(&data, group: group, element: element, vr: "UI", value: value, padding: 0x00)
    }

    private func appendString(_ data: inout Data,
                              group: UInt16,
                              element: UInt16,
                              vr: String,
                              value: String,
                              padding: UInt8) {
        appendHeader(&data, group: group, element: element, vr: vr)
        var bytes = Array(value.utf8)
        if bytes.count % 2 != 0 {
            bytes.append(padding)
        }
        let length = UInt16(bytes.count)
        data.append(UInt8(length & 0xFF))
        data.append(UInt8(length >> 8))
        data.append(contentsOf: bytes)
    }

    private func appendPixelData(_ data: inout Data, value: UInt16) {
        appendHeader(&data, group: 0x7FE0, element: 0x0010, vr: "OW")
        data.append(contentsOf: [0x00, 0x00])
        var length = UInt32(2).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        var pixel = value.littleEndian
        withUnsafeBytes(of: &pixel) { data.append(contentsOf: $0) }
    }

    private func appendHeader(_ data: inout Data, group: UInt16, element: UInt16, vr: String) {
        data.append(UInt8(group & 0xFF))
        data.append(UInt8(group >> 8))
        data.append(UInt8(element & 0xFF))
        data.append(UInt8(element >> 8))
        data.append(contentsOf: vr.utf8)
    }
}
