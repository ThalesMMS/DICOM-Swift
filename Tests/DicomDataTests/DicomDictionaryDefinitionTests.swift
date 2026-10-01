import Foundation
import XCTest
@testable import DicomData

final class DicomDictionaryDefinitionTests: XCTestCase {
    func test_generatedDefinitions_includeModernVRsMultiplicityAndRepeatingGroups() throws {
        let dictionary = DCMDictionary()
        XCTAssertEqual(dictionary.standardEdition, "2024d")
        XCTAssertEqual(dictionary.definition(forTag: 0x00720082)?.valueRepresentations, [.SV])
        XCTAssertEqual(dictionary.definition(forTag: 0x0008040C)?.valueRepresentations, [.UV])
        XCTAssertEqual(dictionary.definition(forTag: 0x00080119)?.valueRepresentations, [.UC])
        XCTAssertEqual(dictionary.definition(forTag: 0x00283002)?.valueRepresentations, [.US, .SS])
        XCTAssertEqual(dictionary.definition(forTag: 0x00283002)?.vm, "3")
        XCTAssertEqual(dictionary.definition(forTag: 0x00281111)?.vm, "4")
        XCTAssertEqual(dictionary.definition(forTag: 0x60020010)?.keyword, "OverlayRows")
        XCTAssertNil(dictionary.definition(forTag: 0x60010010), "Odd groups are private, not repeating public tags")
        XCTAssertNil(dictionary.definition(forTag: 0x60200010), "Only sixteen overlay groups are defined")
        XCTAssertNil(dictionary.value(forTag: 0x00181628), "Correct the old transposed, nonexistent tag")
        XCTAssertEqual(dictionary.vrCode(forTag: 0x00186028), "FD")
    }

    func test_localExtensions_resolveImplicitVRWithoutChangingSharedStandardDictionary() throws {
        let tag = 0x77781001
        let definition = try DicomDictionaryDefinition(valueRepresentations: [.UC], multiplicity: "2", name: "Local measurement labels")
        let dictionary = try DCMDictionary(extendingWith: [tag: definition])
        let source = DicomDataSet(elements: [.init(tag: tag, vr: .UC, value: .strings(["first", "second"]))])
        let bytes = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: .implicitVRLittleEndian)
        XCTAssertEqual(try DicomDataSetParser.read(from: bytes, transferSyntax: .implicitVRLittleEndian,
                                                 dictionary: dictionary).dataSet, source)
        XCTAssertEqual(try DicomDataSetParser.read(from: bytes, transferSyntax: .implicitVRLittleEndian).dataSet[tag]?.vr, .UN)
        XCTAssertNil(DCMDictionary().definition(forTag: tag))
        XCTAssertEqual(dictionary.vrCode(forKey: "77781001"), "UC")
    }

    func test_extensions_rejectStandardShadowingPrivateTagsAndInvalidDefinitions() throws {
        let definition = try DicomDictionaryDefinition(valueRepresentations: [.LO], multiplicity: "1", name: "Local label")
        for tag in [0x00100010, 0x60020010, 0x00111001, -1, Int(UInt32.max) + 1] {
            XCTAssertThrowsError(try DCMDictionary(extendingWith: [tag: definition]))
        }
        for vrs: [DicomVR] in [[], [.US, .US], [.unknown], [.implicitRaw]] {
            XCTAssertThrowsError(try DicomDictionaryDefinition(valueRepresentations: vrs, multiplicity: "1", name: "Invalid"))
        }
        for vm in ["", "0", "1-0", "1-2-3", "+1", "2-3n"] {
            XCTAssertThrowsError(try DicomDictionaryDefinition(valueRepresentations: [.US], multiplicity: vm, name: "Invalid"))
        }
    }

    func test_decodingDefinitions_cannotBypassInitializerValidation() throws {
        let valid = try DicomDictionaryDefinition(valueRepresentations: [.US, .SS], multiplicity: "3", name: "LUT descriptor")
        let encoded = try JSONEncoder().encode(valid)
        XCTAssertEqual(try JSONDecoder().decode(DicomDictionaryDefinition.self, from: encoded), valid)
        let invalid = [
            #"{"vrs": ["ZZ"], "vm": "1", "name": "Invalid", "keyword": "", "retired": false}"#,
            #"{"vrs": ["US", "US"], "vm": "1", "name": "Invalid", "keyword": "", "retired": false}"#,
            #"{"vrs": ["US"], "vm": "2-3n", "name": "Invalid", "keyword": "", "retired": false}"#,
            #"{"vrs": ["US"], "vm": "1", "name": "", "keyword": "", "retired": false}"#
        ]
        for json in invalid {
            XCTAssertThrowsError(try JSONDecoder().decode(DicomDictionaryDefinition.self, from: Data(json.utf8)))
        }
    }

    func test_multiplicityRules_enforceRangesAndGroupsWithoutRejectingEmptyValues() throws {
        let pairs = try DicomDictionaryDefinition(valueRepresentations: [.DS], multiplicity: "2-2n", name: "Pairs")
        for count in [0, 2, 4, 8] { XCTAssertTrue(pairs.acceptsMultiplicity(count)) }
        for count in [-1, 1, 3, 7] { XCTAssertFalse(pairs.acceptsMultiplicity(count)) }
        let range = try DicomDictionaryDefinition(valueRepresentations: [.US], multiplicity: "1-3", name: "Range")
        for count in 0...3 { XCTAssertTrue(range.acceptsMultiplicity(count)) }
        XCTAssertFalse(range.acceptsMultiplicity(4))
    }

    func test_strictReader_rejectsVRAndVMConflictsAndRecoveryDoesNotResurrectInvalidContextualValues() throws {
        let cases: [(DicomDataElement, DicomDataSetReadResult.Diagnostic.Reason)] = [
            (.init(tag: 0x00100010, vr: .LO, value: .strings(["NAME"])), .incompatibleVR),
            (.init(tag: 0x00280120, vr: .US, value: .unsignedIntegers([1, 2])), .invalidMultiplicity)
        ]
        for (element, reason) in cases {
            let source = DicomDataSet(elements: [
                .init(tag: 0x00280103, vr: .US, value: .unsignedIntegers([0])), element
            ])
            let bytes = try DicomDataSetWriter.dataSetData(from: source)
            XCTAssertThrowsError(try DicomDataSetParser.read(from: bytes))
            let recovered = try DicomDataSetParser.read(from: bytes, mode: .recover)
            XCTAssertEqual(recovered.diagnostics.map(\.reason), [reason])
            XCTAssertEqual(recovered.dataSet[element.tag]?.vr, .UN)
            XCTAssertEqual(recovered.dataSet[element.tag]?.bytesValue?.count, 4)
        }
    }
}
