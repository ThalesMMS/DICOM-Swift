import XCTest
@testable import DicomCore

final class DicomCharacterSetTests: XCTestCase {
    func test_longTextVRs_preserveYenInLegacyAndParsedMetadata() throws {
        var source = makeTextDataSet(characterSet: "ISO_IR 13", patientName: "Doe^Jane", studyDescription: "Study")
        let textTags: [(Int, DicomVR)] = [(0x00104000, .LT), (0x00082111, .ST), (0x0040A160, .UT)]
        for (tag, vr) in textTags {
            source.set(.init(tag: tag, vr: vr, value: .strings(["Cost ¥100"])))
        }
        for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .implicitVRLittleEndian] {
            let data = try DicomDataSetWriter.part10Data(from: source, options: .init(transferSyntax: syntax))
            let decoder = try open(data)
            for (tag, _) in textTags {
                XCTAssertEqual(decoder.info(for: tag), "Cost ¥100", syntax.rawValue)
                XCTAssertEqual(decoder.dataSet.string(for: tag), "Cost ¥100", syntax.rawValue)
            }
        }
    }

    func test_unrepresentableText_rejectsEncodingInsteadOfFallingBackToUTF8() {
        for (characterSet, name) in [("ISO_IR 6", "Müller"), ("ISO_IR 100", "山田"), ("ISO_IR 144", "😀")] {
            let dataSet = makeTextDataSet(characterSet: characterSet, patientName: name, studyDescription: "Study")
            XCTAssertThrowsError(try DicomDataSetWriter.part10Data(from: dataSet), characterSet) {
                guard case .unsupportedValue(tag: DicomTag.patientName.rawValue, vr: .PN, reason: _) =
                        $0 as? DicomDataSetWriterError else {
                    return XCTFail("Expected character-set encoding failure, got \($0)")
                }
            }
        }
    }

    private let sopClassUIDTag = 0x00080016

    func testDefaultCharacterSetReadsAsciiText() throws {
        let decoder = try writeAndOpen(makeTextDataSet(characterSet: nil,
                                                       patientName: "Doe^Jane",
                                                       studyDescription: "Head CT"))

        XCTAssertEqual(decoder.specificCharacterSet, ["ISO_IR 6"])
        XCTAssertEqual(decoder.dataSet.personName(for: .patientName)?.familyName, "Doe")
        XCTAssertEqual(decoder.dataSet.personName(for: .patientName)?.givenName, "Jane")
        XCTAssertEqual(decoder.dataSet.string(for: .studyDescription), "Head CT")
    }

    func testLatin1SpecificCharacterSetDecodesAccents() throws {
        let dataSet = makeTextDataSet(characterSet: "ISO_IR 100",
                                      patientName: "García^José",
                                      studyDescription: "Crânio")
        let data = try DicomDataSetWriter.part10Data(from: dataSet)
        XCTAssertTrue(data.contains(0xED), "Latin-1 encoded patient name should contain í as a single byte")

        let decoder = try open(data)
        let personName = decoder.dataSet.personName(for: .patientName)

        XCTAssertEqual(decoder.specificCharacterSet, ["ISO_IR 100"])
        XCTAssertEqual(personName?.familyName, "García")
        XCTAssertEqual(personName?.givenName, "José")
        XCTAssertEqual(decoder.dataSet.string(for: .studyDescription), "Crânio")
    }

    func testUTF8SpecificCharacterSetDecodesPersonNameGroups() throws {
        let decoder = try writeAndOpen(makeTextDataSet(
            characterSet: "ISO_IR 192",
            patientName: "Yamada^Taro=山田^太郎=ヤマダ^タロウ",
            studyDescription: "国際化"
        ))
        let personName = decoder.dataSet.personName(for: .patientName)

        XCTAssertEqual(decoder.specificCharacterSet, ["ISO_IR 192"])
        XCTAssertEqual(personName?.alphabetic, "Yamada^Taro")
        XCTAssertEqual(personName?.familyName, "Yamada")
        XCTAssertEqual(personName?.givenName, "Taro")
        XCTAssertEqual(personName?.ideographic, "山田^太郎")
        XCTAssertEqual(personName?.phonetic, "ヤマダ^タロウ")
        XCTAssertEqual(decoder.dataSet.string(for: .studyDescription), "国際化")
    }

    func testISO2022JapaneseSpecificCharacterSetDecodesCommonEscapes() throws {
        let dataSet = makeTextDataSet(characterSet: "\\ISO 2022 IR 87",
                                      patientName: "Yamada^Taro=山田^太郎",
                                      studyDescription: "検査")
        let data = try DicomDataSetWriter.part10Data(from: dataSet)
        XCTAssertTrue(data.contains(0x1B), "ISO-2022 encoded values should include escape bytes")

        let decoder = try open(data)
        let personName = decoder.dataSet.personName(for: .patientName)

        XCTAssertEqual(decoder.specificCharacterSet, ["", "ISO 2022 IR 87"])
        XCTAssertEqual(personName?.familyName, "Yamada")
        XCTAssertEqual(personName?.givenName, "Taro")
        XCTAssertEqual(personName?.ideographic, "山田^太郎")
        XCTAssertEqual(decoder.dataSet.string(for: .studyDescription), "検査")
    }

    func testCyrillicSpecificCharacterSetDecodesPatientAndStudyMetadata() throws {
        let dataSet = makeTextDataSet(characterSet: "ISO_IR 144",
                                      patientName: "Иванов^Иван",
                                      studyDescription: "Голова")
        let data = try DicomDataSetWriter.part10Data(from: dataSet)
        XCTAssertTrue(data.contains(0xB8), "ISO-8859-5 encoded И should be a single high byte")

        let decoder = try open(data)
        XCTAssertEqual(decoder.specificCharacterSet, ["ISO_IR 144"])
        XCTAssertEqual(decoder.dataSet.personName(for: .patientName)?.familyName, "Иванов")
        XCTAssertEqual(decoder.dataSet.personName(for: .patientName)?.givenName, "Иван")
        XCTAssertEqual(decoder.dataSet.string(for: .studyDescription), "Голова")
    }

    func testGreekSpecificCharacterSetDecodesPatientAndStudyMetadata() throws {
        let dataSet = makeTextDataSet(characterSet: "ISO_IR 126",
                                      patientName: "Παπαδόπουλος^Γιώργος",
                                      studyDescription: "Κεφάλι")
        let data = try DicomDataSetWriter.part10Data(from: dataSet)

        let decoder = try open(data)
        XCTAssertEqual(decoder.dataSet.personName(for: .patientName)?.familyName, "Παπαδόπουλος")
        XCTAssertEqual(decoder.dataSet.string(for: .studyDescription), "Κεφάλι")
    }

    func testGB18030SpecificCharacterSetDecodesPatientAndStudyMetadata() throws {
        let dataSet = makeTextDataSet(characterSet: "GB18030",
                                      patientName: "王^小明",
                                      studyDescription: "头部检查")
        let data = try DicomDataSetWriter.part10Data(from: dataSet)
        XCTAssertTrue(data.contains(0xCD), "GB18030 encoded 王 should use multi-byte non-UTF8 bytes")

        let decoder = try open(data)
        XCTAssertEqual(decoder.dataSet.personName(for: .patientName)?.familyName, "王")
        XCTAssertEqual(decoder.dataSet.personName(for: .patientName)?.givenName, "小明")
        XCTAssertEqual(decoder.dataSet.string(for: .studyDescription), "头部检查")
    }

    func testSingleByteRegionalCharacterSetsRoundTripImportMetadata() throws {
        let cases: [(term: String, name: String, study: String)] = [
            ("ISO_IR 127", "قاسم^سعيد", "رأس"),
            ("ISO_IR 138", "שרון^דבורה", "ראש"),
            ("ISO_IR 148", "Çelik^Gül", "Beyin"),
            ("ISO_IR 110", "Ozols^Ēriks", "Galva"),
            ("ISO_IR 166", "สมชาย^ใจดี", "ศีรษะ")
        ]
        for testCase in cases {
            let decoder = try writeAndOpen(makeTextDataSet(
                characterSet: testCase.term,
                patientName: testCase.name,
                studyDescription: testCase.study
            ))
            XCTAssertEqual(decoder.specificCharacterSet, [testCase.term])
            XCTAssertEqual(decoder.dataSet.string(for: .studyDescription), testCase.study, testCase.term)
            let personName = decoder.dataSet.personName(for: .patientName)
            XCTAssertEqual(
                "\(personName?.familyName ?? "")^\(personName?.givenName ?? "")",
                testCase.name,
                testCase.term
            )
        }
    }

    func testSanitizedDisplayTextRemovesControlsWithoutRedactingContent() {
        let element = DicomDataElement(tag: DicomTag.patientName.rawValue,
                                       vr: .PN,
                                       value: .strings(["Jane\u{0007}\nDoe"]))
        let dataSet = DicomDataSet(elements: [element])

        XCTAssertEqual(DicomTextSanitizer.sanitizedForDisplay("Jane\u{0007}\nDoe"), "Jane Doe")
        XCTAssertEqual(element.sanitizedStringValue, "Jane Doe")
        XCTAssertEqual(dataSet.sanitizedString(for: .patientName), "Jane Doe")
    }

    private func writeAndOpen(_ dataSet: DicomDataSet) throws -> DCMDecoder {
        try open(DicomDataSetWriter.part10Data(from: dataSet))
    }

    private func open(_ data: Data) throws -> DCMDecoder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }

    private func makeTextDataSet(characterSet: String?,
                                 patientName: String,
                                 studyDescription: String) -> DicomDataSet {
        var elements: [DicomDataElement] = [
            DicomDataElement(tag: sopClassUIDTag,
                             vr: .UI,
                             value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue,
                             vr: .UI,
                             value: .strings(["2.25.2171"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue,
                             vr: .UI,
                             value: .strings(["2.25.2172"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue,
                             vr: .UI,
                             value: .strings(["2.25.2173"])),
            DicomDataElement(tag: DicomTag.patientName.rawValue,
                             vr: .PN,
                             value: .strings([patientName])),
            DicomDataElement(tag: DicomTag.studyDescription.rawValue,
                             vr: .LO,
                             value: .strings([studyDescription])),
            DicomDataElement(tag: DicomTag.modality.rawValue,
                             vr: .CS,
                             value: .strings(["CT"])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue,
                             vr: .US,
                             value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue,
                             vr: .CS,
                             value: .strings(["MONOCHROME2"])),
            DicomDataElement(tag: DicomTag.rows.rawValue,
                             vr: .US,
                             value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.columns.rawValue,
                             vr: .US,
                             value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue,
                             vr: .US,
                             value: .unsignedIntegers([16])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue,
                             vr: .US,
                             value: .unsignedIntegers([16])),
            DicomDataElement(tag: DicomTag.highBit.rawValue,
                             vr: .US,
                             value: .unsignedIntegers([15])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue,
                             vr: .US,
                             value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue,
                             vr: .OW,
                             value: .bytes(Data([0x01, 0x00])))
        ]

        if let characterSet {
            elements.append(DicomDataElement(tag: DicomTag.specificCharacterSet.rawValue,
                                             vr: .CS,
                                             value: .strings(characterSet.components(separatedBy: "\\"))))
        }
        return DicomDataSet(elements: elements)
    }
}
