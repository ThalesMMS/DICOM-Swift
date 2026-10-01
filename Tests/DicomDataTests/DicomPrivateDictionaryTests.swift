import Foundation
import XCTest
@testable import DicomData

final class DicomPrivateDictionaryTests: XCTestCase {
    func test_privateVRs_followCreatorAndRelocatedBlockWithinEachItem() throws {
        let dictionary = try DicomPrivateDictionary(entries: [
            .init(group: 0x7777, creator: "ISIS_NUM", offset: 1, vr: .US),
            .init(group: 0x7777, creator: "ISIS_NUM", offset: 0x99, vr: .SQ),
            .init(group: 0x7777, creator: "ISIS_TEXT", offset: 1, vr: .LO)
        ])
        let items = [
            DicomDataSet(elements: [creator(0x77770011, "ISIS_TEXT"), text(0x77771101, "item")]),
            DicomDataSet(elements: [.init(tag: 0x77771101, vr: .UN, value: .bytes(Data([42, 0])))]),
            DicomDataSet(elements: [creator(0x777700FE, "ISIS_NUM"), number(0x7777FE01, 321)])
        ]
        let source = DicomDataSet(elements: [
            .init(tag: 0x77771199, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) })),
            creator(0x77770011, "ISIS_NUM"), creator(0x77770012, "ISIS_TEXT"),
            number(0x77771101, 123), text(0x77771201, "root")
        ])
        let wire = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: .implicitVRLittleEndian)
        let parsed = try DicomDataSetParser.dataSet(from: wire, transferSyntax: .implicitVRLittleEndian,
                                                   limits: .default, privateDictionary: dictionary)
        XCTAssertEqual(parsed, source)
        let withoutDictionary = try DicomDataSetParser.dataSet(from: wire, transferSyntax: .implicitVRLittleEndian)
        XCTAssertEqual(withoutDictionary[0x77770011]?.vr, .LO)
        XCTAssertEqual(withoutDictionary.string(for: 0x77770011), "ISIS_NUM")
        XCTAssertEqual(withoutDictionary[0x77771101]?.vr, .UN)
        XCTAssertEqual(withoutDictionary[0x77771101]?.bytesValue, Data([123, 0]))
        for syntax in [DicomTransferSyntax.implicitVRLittleEndian, .explicitVRLittleEndian,
                       .explicitVRBigEndian, .deflatedExplicitVRLittleEndian] {
            let encoded = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: syntax, purpose: .instance)
            XCTAssertEqual(try DicomDataSetParser.read(from: encoded, transferSyntax: syntax,
                privateDictionary: dictionary).dataSet, source)
            if let directory = ProcessInfo.processInfo.environment["DICOM_DIFFERENTIAL_REWRITE_DIR"] {
                let root = URL(fileURLWithPath: directory).appendingPathComponent("data-fidelity")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try DicomDataSetWriter.part10Data(from: source, options: .init(transferSyntax: syntax,
                    mediaStorageSOPInstanceUID: "2.25.2320004", validationPurpose: .instance))
                    .write(to: root.appendingPathComponent("private-\(syntax.rawValue).dcm"))
            }
        }
    }

    func test_privateDictionary_rejectsCollisionsStandardGroupsAndInvalidCreators() throws {
        let entry = DicomPrivateDictionary.Entry(group: 0x7777, creator: "ISIS", offset: 1, vr: .US)
        XCTAssertThrowsError(try DicomPrivateDictionary(entries: [entry, entry])) {
            XCTAssertEqual($0 as? DicomPrivateDictionary.Failure, .duplicateDefinition)
        }
        for group: UInt16 in [0x0001, 0x0007, 0x0010, 0xFFFF] {
            XCTAssertThrowsError(try DicomPrivateDictionary(entries: [.init(group: group, creator: "ISIS", offset: 1, vr: .US)]))
        }
        for creator in ["", " ISIS", "A\\B", "非ASCII"] {
            XCTAssertThrowsError(try DicomPrivateDictionary(entries: [.init(group: 0x7777, creator: creator, offset: 1, vr: .US)]))
        }
        let dictionary = try DicomPrivateDictionary(entries: [entry])
        XCTAssertNil(dictionary.vr(group: 0x7777, creator: "OTHER", offset: 1))
        XCTAssertNil(dictionary.vr(group: 0x7779, creator: "ISIS", offset: 1))
    }

    func test_invalidWireCreators_areOpaqueAndCannotResolvePrivateBlocks() throws {
        let dictionary = try DicomPrivateDictionary(entries: [
            .init(group: 0x7777, creator: "ISIS", offset: 1, vr: .US)
        ])
        let malformed: [(String, [UInt8])] = [
            ("LO", Array("A\\B ".utf8)), ("LO", Array(String(repeating: "A", count: 66).utf8)),
            ("SH", Array("ISIS".utf8)), ("LO", [0x49, 0x09]), ("LO", [0xC3, 0xA9]),
            ("LO", [0x49, 0x00])
        ]
        for (vr, bytes) in malformed {
            let wire = wireElement(tag: 0x77770010, vr: vr, bytes: bytes)
            XCTAssertThrowsError(try DicomDataSetParser.read(from: wire, privateDictionary: dictionary))
            let result = try DicomDataSetParser.read(from: wire, mode: .recover, privateDictionary: dictionary)
            XCTAssertEqual(result.diagnostics.count, 1)
            XCTAssertEqual(result.dataSet[0x77770010]?.vr, .UN)
            XCTAssertEqual(result.dataSet[0x77770010]?.bytesValue, Data(bytes))
        }
        // An invalid implicit LO creator must not reserve a block during recovery.
        let implicit = Data([0x77, 0x77, 0x10, 0x00, 6, 0, 0, 0]) + Data("ISIS\t ".utf8)
            + Data([0x77, 0x77, 0x01, 0x10, 2, 0, 0, 0, 42, 0])
        let recovered = try DicomDataSetParser.read(from: implicit, transferSyntax: .implicitVRLittleEndian,
            mode: .recover, privateDictionary: dictionary)
        XCTAssertEqual(recovered.dataSet[0x77771001]?.vr, .UN)
        XCTAssertEqual(recovered.dataSet[0x77771001]?.bytesValue, Data([42, 0]))
    }

    func test_duplicateCreatorIdentifiers_areRejectedWithinGroupAndAllowedAcrossItemsAndGroups() throws {
        let first = wireElement(tag: 0x77770010, vr: "LO", bytes: Array("ISIS".utf8))
        let second = wireElement(tag: 0x77770011, vr: "LO", bytes: Array(" ISIS ".utf8))
        XCTAssertThrowsError(try DicomDataSetParser.read(from: first + second))
        let result = try DicomDataSetParser.read(from: first + second, mode: .recover)
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(result.dataSet[0x77770011]?.vr, .UN)
        let duplicate = DicomDataSet(elements: [creator(0x77770010, "ISIS"), creator(0x77770011, " ISIS ")])
        XCTAssertNoThrow(try DicomDataSetWriter.dataSetData(from: duplicate))
        XCTAssertNoThrow(try DicomDataSetWriter.part10Data(from: duplicate))
        XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: duplicate, purpose: .instance))
        XCTAssertThrowsError(try DicomDataSetWriter.part10Data(from: duplicate, options: .init(validationPurpose: .instance)))
        let child = DicomDataSet(elements: [creator(0x77770010, "ISIS")])
        let source = DicomDataSet(elements: [
            creator(0x77770010, "ISIS"), creator(0x77790010, "ISIS"),
            .init(tag: 0x00081032, vr: .SQ, value: .sequence([.init(dataSet: child), .init(dataSet: child)]))
        ])
        let wire = try DicomDataSetWriter.dataSetData(from: source, purpose: .instance)
        XCTAssertEqual(try DicomDataSetParser.read(from: wire).dataSet, source)
    }

    func test_validatedWriter_rejectsInvalidCreatorsWhileCompatibilityWritingPreservesThem() throws {
        let malformed: [DicomDataElement] = [
            .init(tag: 0x77770010, vr: .SH, value: .strings(["ISIS"])),
            .init(tag: 0x77770010, vr: .LO, value: .strings(["A", "B"])),
            .init(tag: 0x77770010, vr: .LO, value: .strings(["A\tB"])),
            .init(tag: 0x77770010, vr: .LO, value: .strings([String(repeating: "A", count: 65)])),
            .init(tag: 0x77770010, vr: .US, value: .unsignedIntegers([42])),
            .init(tag: 0x77770010, vr: .SQ, value: .sequence([]))
        ]
        for element in malformed {
            let dataSet = DicomDataSet(elements: [element])
            XCTAssertNoThrow(try DicomDataSetWriter.dataSetData(from: dataSet))
            XCTAssertNoThrow(try DicomDataSetWriter.part10Data(from: dataSet))
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: dataSet, purpose: .instance))
            XCTAssertThrowsError(try DicomDataSetWriter.part10Data(from: dataSet, options: .init(validationPurpose: .instance)))
        }
        // Empty values do not reserve a block; tilde is discouraged but not forbidden.
        let valid = DicomDataSet(elements: [creator(0x77770010, ""), creator(0x77770011, "ISIS~")])
        XCTAssertNoThrow(try DicomDataSetWriter.dataSetData(from: valid, purpose: .instance))
    }

    private func wireElement(tag: UInt32, vr: String, bytes: [UInt8]) -> Data {
        var result = Data([UInt8(truncatingIfNeeded: tag >> 16), UInt8(truncatingIfNeeded: tag >> 24),
                           UInt8(truncatingIfNeeded: tag), UInt8(truncatingIfNeeded: tag >> 8)])
        result.append(contentsOf: vr.utf8)
        result.append(contentsOf: [UInt8(bytes.count), 0])
        result.append(contentsOf: bytes)
        return result
    }

    /// Issue #2795: the standard dictionary (DCMTK private.dic merged with GDCM's) types Implicit VR private
    /// elements of GE, Philips and a GDCM-only creator, which then transcode to Explicit VR without UN.
    func test_standardDictionary_typesImplicitVRPrivateTagsAndTranscodesWithoutUN() throws {
        let standard = DicomPrivateDictionary.standard
        XCTAssertEqual(standard.vr(group: 0x0019, creator: "GEMS_ACQU_01", offset: 0x02), .SL)
        XCTAssertEqual(standard.name(group: 0x0019, creator: "GEMS_ACQU_01", offset: 0x02), "NumberOfCellsInDetector")
        XCTAssertEqual(standard.vr(group: 0x2001, creator: "Philips Imaging DD 001", offset: 0x03), .FL)
        XCTAssertEqual(standard.vr(group: 0x0009, creator: "GEMS_PETD_01", offset: 0x01), .LO, "GDCM-only creator")
        XCTAssertNil(standard.vr(group: 0x0009, creator: "NOT_A_CREATOR", offset: 0x01))

        let source = DicomDataSet(elements: [
            creator(0x00090010, "GEMS_PETD_01"),
            .init(tag: 0x00091001, vr: .LO, value: .strings(["PET"])),
            creator(0x00190010, "GEMS_ACQU_01"),
            .init(tag: 0x00191002, vr: .SL, value: .signedIntegers([888])),
            creator(0x20010010, "Philips Imaging DD 001"),
            .init(tag: 0x20011003, vr: .FL, value: .floats([1000]))
        ])
        let implicit = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: .implicitVRLittleEndian)
        let parsed = try DicomDataSetParser.dataSet(from: implicit, transferSyntax: .implicitVRLittleEndian)
        XCTAssertEqual(parsed[0x00091001]?.vr, .LO)
        XCTAssertEqual(parsed[0x00191002]?.vr, .SL)
        XCTAssertEqual(parsed[0x20011003]?.vr, .FL)
        XCTAssertEqual(parsed, source)

        let explicit = try DicomDataSetWriter.dataSetData(from: parsed, transferSyntax: .explicitVRLittleEndian)
        let reread = try DicomDataSetParser.dataSet(from: explicit, transferSyntax: .explicitVRLittleEndian,
                                                    limits: .default, privateDictionary: .empty)
        XCTAssertFalse(reread.elements.contains { $0.vr == .UN }, "Explicit VR carries the dictionary VRs")
        XCTAssertEqual(reread, source)
    }

    private func creator(_ tag: Int, _ name: String) -> DicomDataElement { text(tag, name) }
    private func text(_ tag: Int, _ value: String) -> DicomDataElement { .init(tag: tag, vr: .LO, value: .strings([value])) }
    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers([value])) }
}
