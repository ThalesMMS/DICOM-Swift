import Foundation
import XCTest
@testable import DicomData

final class DicomValidatedWriterTests: XCTestCase {
    func test_binaryCompatibilityCoercion_remainsSeparateFromValidatedWriting() throws {
        for vr in [DicomVR.OB, .UN] {
            let dataSet = DicomDataSet(elements: [.init(tag: 0x77771001, vr: vr, value: .strings(["ABCD", "EFG"]))])
            let encoded = try DicomDataSetWriter.dataSetData(from: dataSet)
            XCTAssertEqual(Data(encoded.dropFirst(12)), Data("ABCD\\EFG".utf8), vr.code)
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: dataSet, purpose: .instance), vr.code)
        }
        for vr in [DicomVR.OW, .OV] {
            let text = DicomDataSet(elements: [.init(tag: 0x77771001, vr: vr, value: .strings(["ABCD", "EFG"]))])
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: text), vr.code)
            let words = DicomDataSet(elements: [.init(tag: 0x77771001, vr: vr, value: .strings(["65", "66"]))])
            let padding = Data(count: vr == .OW ? 1 : 7)
            XCTAssertEqual(Data(try DicomDataSetWriter.dataSetData(from: words).dropFirst(12)),
                           Data([65]) + padding + Data([66]) + padding)
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: words, purpose: .instance), vr.code)
            let dataSet = DicomDataSet(elements: [.init(tag: 0x77771001, vr: vr, value: .bytes(Data([1, 2, 3])))])
            XCTAssertEqual(Data(try DicomDataSetWriter.dataSetData(from: dataSet).dropFirst(12)), Data([1, 2, 3, 0]), vr.code)
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: dataSet, purpose: .instance), vr.code)
        }
    }

    func test_validatedWriter_rejectsLexicalDictionaryAndBinaryConflicts() {
        let cases: [DicomDataElement] = [
            .init(tag: 0x00100010, vr: .LO, value: .strings(["NAME"])),
            .init(tag: 0x00100010, vr: .PN, value: .strings(["A", "B"])),
            .init(tag: 0x00080020, vr: .DA, value: .strings(["20260229"])),
            .init(tag: 0x00100010, vr: .PN, value: .strings(["A=B=C=D"])),
            .init(tag: 0x00280030, vr: .DS, value: .strings(["1"])),
            .init(tag: 0x77771001, vr: .OW, value: .bytes(Data([1])))
        ]
        for element in cases {
            let dataSet = DicomDataSet(elements: [element])
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: dataSet, purpose: .instance))
            XCTAssertThrowsError(try DicomDataSetWriter.part10Data(from: dataSet, options: .init(validationPurpose: .instance)))
            XCTAssertNoThrow(try DicomDataSetWriter.dataSetData(from: dataSet))
        }
    }

    func test_contextualWriter_rejectsImplicitSignChangeAndExplicitContradiction() throws {
        let unsigned = DicomDataSet(elements: [
            .init(tag: 0x00280103, vr: .US, value: .unsignedIntegers([0])),
            .init(tag: 0x00280120, vr: .SS, value: .signedIntegers([-1]))
        ])
        for syntax in syntaxes {
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: unsigned, transferSyntax: syntax, purpose: .instance))
        }
        let signed = DicomDataSet(elements: [
            .init(tag: 0x00280103, vr: .US, value: .unsignedIntegers([1])),
            .init(tag: 0x00280120, vr: .SS, value: .signedIntegers([-1]))
        ])
        for syntax in syntaxes {
            let encoded = try DicomDataSetWriter.dataSetData(from: signed, transferSyntax: syntax, purpose: .instance)
            XCTAssertEqual(try DicomDataSetParser.read(from: encoded, transferSyntax: syntax).dataSet, signed)
        }
    }

    func test_validatedWriter_inheritsPurposeCharsetAndContextAcrossItems() throws {
        let item = DicomDataSet(elements: [
            .init(tag: 0x00080020, vr: .DA, value: .strings(["20240101-20241231"])),
            .init(tag: 0x00100010, vr: .PN, value: .strings(["NAME=漢字"])),
            .init(tag: 0x00280120, vr: .SS, value: .signedIntegers([-7]))
        ])
        let query = DicomDataSet(elements: [
            .init(tag: 0x00080005, vr: .CS, value: .strings(["ISO_IR 192"])),
            .init(tag: 0x00280103, vr: .US, value: .unsignedIntegers([1])),
            .init(tag: 0x00400100, vr: .SQ, value: .sequence([.init(dataSet: item)]))
        ])
        for syntax in syntaxes {
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: query, transferSyntax: syntax, purpose: .instance))
            let encoded = try DicomDataSetWriter.dataSetData(from: query, transferSyntax: syntax, purpose: .query)
            XCTAssertEqual(try DicomDataSetParser.read(from: encoded, transferSyntax: syntax, purpose: .query).dataSet, query)
        }
    }

    func test_structuralLimits_rejectBeforeRecursiveSerialization() throws {
        let item = DicomDataSet(elements: [.init(tag: 0x00100020, vr: .LO, value: .strings(["ID"]))])
        let dataSet = DicomDataSet(elements: [.init(tag: 0x00400100, vr: .SQ,
            value: .sequence([.init(dataSet: item), .init(dataSet: item)]))])
        for limits in [
            DicomDataSetParseLimits(maximumSequenceDepth: 0, maximumElementCount: 10, maximumItemCount: 10),
            .init(maximumSequenceDepth: 2, maximumElementCount: 2, maximumItemCount: 10),
            .init(maximumSequenceDepth: 2, maximumElementCount: 10, maximumItemCount: 1)
        ] {
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: dataSet, purpose: .instance, limits: limits)) { error in
                XCTAssertTrue(error is DicomDataSetParseError)
            }
            XCTAssertThrowsError(try DicomDataSetWriter.part10Data(from: dataSet,
                options: .init(validationPurpose: .instance, validationLimits: limits)))
        }
        XCTAssertNoThrow(try DicomDataSetWriter.dataSetData(from: dataSet, purpose: .instance,
            limits: .init(maximumSequenceDepth: 1, maximumElementCount: 3, maximumItemCount: 2)))
    }

    func test_emptyValuesAndUIDMatchingList_validateMultiplicityWithoutLosingComponents() throws {
        let empty = DicomDataSet(elements: [.init(tag: 0x00100010, vr: .PN, value: .strings(["", "", ""]))])
        let encodedEmpty = try DicomDataSetWriter.dataSetData(from: empty, purpose: .instance)
        XCTAssertEqual(try DicomDataSetParser.read(from: encodedEmpty).dataSet, empty)
        let query = DicomDataSet(elements: [.init(tag: 0x0020000D, vr: .UI, value: .strings(["1.2.3", "1.2.4"]))])
        XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: query, purpose: .instance))
        let encoded = try DicomDataSetWriter.dataSetData(from: query, purpose: .query)
        XCTAssertEqual(try DicomDataSetParser.read(from: encoded, purpose: .query).dataSet, query)
    }

    @MainActor
    func test_part10Validation_checksFileMetaAndRetainsDatasetSyntax() async throws {
        let source = DicomDataSet(elements: [.init(tag: 0x00100020, vr: .LO, value: .strings(["ID"]))])
        XCTAssertThrowsError(try DicomDataSetWriter.part10Data(from: source,
            options: .init(implementationVersionName: String(repeating: "A", count: 17), validationPurpose: .instance)))
        for syntax in syntaxes.filter({ !$0.usesDataSetDeflate }) {
            let bytes = try DicomDataSetWriter.part10Data(from: source,
                options: .init(transferSyntax: syntax, validationPurpose: .instance))
            let metadata = try await DicomSourceMetadata.readPart10(from: DicomByteSource(data: bytes), mode: .strict)
            XCTAssertEqual(metadata.dataSet, source)
            XCTAssertEqual(metadata.transferSyntax, syntax)
        }
    }

    private let syntaxes: [DicomTransferSyntax] = [
        .explicitVRLittleEndian, .explicitVRBigEndian, .implicitVRLittleEndian, .deflatedExplicitVRLittleEndian
    ]
}
