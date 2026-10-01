import Foundation
import XCTest
@testable import DicomData

final class DicomValidationPathTests: XCTestCase {
    func test_nestedLexicalFailure_keepsTagItemPathAndWireOffset() throws {
        let valid = DicomDataSet(elements: [.init(tag: 0x0040A040, vr: .CS, value: .strings(["TEXT"]))])
        let invalid = DicomDataSet(elements: [.init(tag: 0x0040A040, vr: .CS, value: .strings(["bad!"]))])
        let dataSet = DicomDataSet(elements: [.init(tag: 0x0040A730, vr: .SQ,
            value: .sequence([.init(dataSet: valid), .init(dataSet: invalid)]))])
        let wire = try DicomDataSetWriter.dataSetData(from: dataSet)
        let recovered = try DicomDataSetParser.read(from: wire, mode: .recover)
        let diagnostic = try XCTUnwrap(recovered.diagnostics.first)
        XCTAssertEqual(diagnostic.reason, .invalidTextValue)
        XCTAssertEqual(diagnostic.path, [.tag(0x0040A730), .item(1), .tag(0x0040A040)])
        XCTAssertEqual(wire.subdata(in: diagnostic.offset..<(diagnostic.offset + 4)), Data("bad!".utf8))
        XCTAssertThrowsError(try DicomDataSetParser.read(from: wire)) { error in
            XCTAssertEqual(error as? DicomDataSetReadResult.Diagnostic, diagnostic)
        }
    }

    func test_deferredContextFailure_keepsItsOriginalNestedPath() throws {
        let item = DicomDataSet(elements: [.init(tag: 0x00280120, vr: .US, value: .unsignedIntegers([7]))])
        let dataSet = DicomDataSet(elements: [.init(tag: 0x0040A730, vr: .SQ,
            value: .sequence([.init(dataSet: item)]))])
        let wire = try DicomDataSetWriter.dataSetData(from: dataSet, transferSyntax: .implicitVRLittleEndian)
        let recovered = try DicomDataSetParser.read(from: wire, transferSyntax: .implicitVRLittleEndian, mode: .recover)
        let diagnostic = try XCTUnwrap(recovered.diagnostics.first)
        XCTAssertEqual(diagnostic.reason, .ambiguousVR)
        XCTAssertEqual(diagnostic.path, [.tag(0x0040A730), .item(0), .tag(0x00280120)])
        XCTAssertEqual(wire.subdata(in: diagnostic.offset..<(diagnostic.offset + 2)), Data([7, 0]))
    }

    func test_fatalSequenceVRConflict_includesItsContainingItem() throws {
        let item = DicomDataSet(elements: [.init(tag: 0x0040A730, vr: .LO, value: .strings(["BAD "]))])
        let dataSet = DicomDataSet(elements: [.init(tag: 0x0040A043, vr: .SQ,
            value: .sequence([.init(dataSet: item)]))])
        let wire = try DicomDataSetWriter.dataSetData(from: dataSet)
        for mode in [DicomDataSetReadMode.strict, .recover] {
            XCTAssertThrowsError(try DicomDataSetParser.read(from: wire, mode: mode)) { error in
                let diagnostic = error as? DicomDataSetReadResult.Diagnostic
                XCTAssertEqual(diagnostic?.reason, .incompatibleVR)
                XCTAssertEqual(diagnostic?.path, [.tag(0x0040A043), .item(0), .tag(0x0040A730)])
            }
        }
    }
}
