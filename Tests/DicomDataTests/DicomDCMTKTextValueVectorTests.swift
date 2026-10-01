import Foundation
import XCTest
@testable import DicomData

/// Isis issue #2845: the value checks of DCMTK's dcmdata tests (`tchval.cc`, `tvrui.cc`), as a table of exact bytes,
/// a VR and an optional VM, against the strict reader's lexical validation and the dictionary multiplicity rule.
/// `Tools/Scripts/dcmtk_vr_vectors.py` writes the table; a case where DICOM-Swift decides otherwise on purpose
/// carries its `decision` and the verdict DICOM-Swift keeps.
final class DicomDCMTKTextValueVectorTests: XCTestCase {
    private struct Table: Decodable {
        struct Fill: Decodable { let byteHex: String; let length: Int; let overrides: [String: String] }
        struct Decision: Decodable { let dicomSwift: String; let reason: String }
        struct Case: Decodable {
            let id: String
            let vr: String
            let valueHex: String?
            let fill: Fill?
            let vm: String?
            let expected: String
            let specificCharacterSet: String?
            let oldFormat: Bool?
            let decision: Decision?
        }
        let schemaVersion: Int
        let dcmtkCommit: String
        let attribution: String
        let cases: [Case]
    }

    func test_everyDCMTKVector_matchesOrIsADocumentedDecision() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/DCMTK/TextValueVectors.json")
        let table = try JSONDecoder().decode(Table.self, from: Data(contentsOf: url))
        XCTAssertEqual(table.schemaVersion, 1)
        XCTAssertTrue(table.attribution.contains("OFFIS"), "BSD-3 attribution travels with the vectors")
        XCTAssertGreaterThanOrEqual(table.cases.count, 200)

        var mismatches: [String] = []
        for entry in table.cases {
            let verdict = try dicomSwiftVerdict(entry)
            let expected = entry.decision?.dicomSwift ?? entry.expected
            if verdict != expected {
                mismatches.append("\(entry.id) \(entry.vr) VM \(entry.vm ?? "1-n"): DCMTK \(entry.expected), "
                                  + "DICOM-Swift \(verdict)")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) divergences:\n" + mismatches.joined(separator: "\n"))
    }

    /// Good when the strict reader accepts the value's bytes and its value count fits the VM.
    private func dicomSwiftVerdict(_ entry: Table.Case) throws -> String {
        let vr = try XCTUnwrap(DicomVR(code: entry.vr), entry.id)
        var value = try bytes(entry)
        if !value.count.isMultiple(of: 2) { value.append(vr == .UI ? 0 : 0x20) }
        var stream = Data()
        if let characterSet = entry.specificCharacterSet {
            stream += element(tag: 0x0008_0005, vr: .CS, value: Data((characterSet.count.isMultiple(of: 2)
                ? characterSet : characterSet + " ").utf8))
        }
        stream += element(tag: 0x7777_1001, vr: vr, value: value)
        guard let parsed = try? DicomDataSetParser.read(from: stream).dataSet[0x7777_1001] else { return "bad" }
        if let vm = entry.vm {
            let definition = try DicomDictionaryDefinition(valueRepresentations: [vr], multiplicity: vm, name: entry.id)
            guard definition.acceptsMultiplicity(of: parsed, purpose: .instance) else { return "bad" }
        }
        return "good"
    }

    private func bytes(_ entry: Table.Case) throws -> Data {
        if let hex = entry.valueHex { return try data(hex: hex) }
        let fill = try XCTUnwrap(entry.fill, entry.id)
        var data = Data(repeating: try self.data(hex: fill.byteHex)[0], count: fill.length)
        for (index, byte) in fill.overrides { data[try XCTUnwrap(Int(index))] = try self.data(hex: byte)[0] }
        return data
    }

    private func data(hex: String) throws -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(try XCTUnwrap(UInt8(hex[index ..< next], radix: 16)))
            index = next
        }
        return data
    }

    private func element(tag: UInt32, vr: DicomVR, value: Data) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt16(tag >> 16))
        append(UInt16(tag & 0xFFFF))
        data.append(contentsOf: vr.code.utf8)
        if vr.uses32BitLength {
            append(UInt16(0))
            append(UInt32(value.count))
        } else {
            append(UInt16(value.count))
        }
        return data + value
    }
}
