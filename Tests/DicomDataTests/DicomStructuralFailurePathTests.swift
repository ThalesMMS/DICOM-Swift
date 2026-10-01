import Foundation
import XCTest
@testable import DicomData

final class DicomStructuralFailurePathTests: XCTestCase {
    func test_truncatedValueInSecondItem_identifiesTheAttributeAfterStackUnwinding() throws {
        var wire = sequenceHeader()
        wire.append(itemHeader(length: 0))
        wire.append(itemHeader(length: UInt32.max))
        wire.append(Data([0x10, 0, 0x10, 0, 0x50, 0x4E, 4, 0, 0x41, 0x42]))
        try assertFailure(wire, path: [.tag(0x0040A730), .item(1), .tag(0x00100010)])
    }

    func test_missingDelimiters_identifyTheirContainerInsteadOfTheLastChild() throws {
        let value = try DicomDataSetWriter.dataSetData(from: .init(elements: [
            .init(tag: 0x00100010, vr: .PN, value: .strings(["SYNTHETIC"]))
        ]))
        try assertFailure(sequenceHeader() + itemHeader(length: UInt32.max) + value,
                          path: [.tag(0x0040A730), .item(0)])
        try assertFailure(sequenceHeader() + itemHeader(length: UInt32(value.count)) + value,
                          path: [.tag(0x0040A730)])
    }

    func test_invalidItemDelimiter_keepsTheContainingItemPath() throws {
        let invalidDelimiter = Data([0xFE, 0xFF, 0x0D, 0xE0, 1, 0, 0, 0])
        try assertFailure(sequenceHeader() + itemHeader(length: UInt32.max) + invalidDelimiter,
                          path: [.tag(0x0040A730), .item(0)])
    }

    func test_invalidVRInsideNestedSequence_preservesEveryItemAndTag() throws {
        let inner = Data([0x40, 0, 0x43, 0xA0, 0x53, 0x51, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
        let invalidHeader = Data([0x10, 0, 0x10, 0, 0x5A, 0x5A, 0, 0])
        let wire = sequenceHeader() + itemHeader(length: 0) + itemHeader(length: UInt32.max)
            + inner + itemHeader(length: UInt32.max) + invalidHeader
        try assertFailure(wire, path: [.tag(0x0040A730), .item(1), .tag(0x0040A043), .item(0), .tag(0x00100010)])
    }

    func test_incompleteItemAndLongVRHeaders_reportOnlyLocationsKnownFromTheBytes() throws {
        try assertFailure(sequenceHeader() + itemHeader(length: 10), path: [.tag(0x0040A730), .item(0)])
        let incompleteLongHeader = Data([0x40, 0, 0x60, 0xA1, 0x55, 0x54, 0, 0])
        try assertFailure(sequenceHeader() + itemHeader(length: UInt32.max) + incompleteLongHeader,
                          path: [.tag(0x0040A730), .item(0), .tag(0x0040A160)])
        // An incomplete item header cannot establish a new item index.
        try assertFailure(sequenceHeader() + Data([0xFE, 0xFF, 0, 0xE0]), path: [.tag(0x0040A730)])
    }

    func test_itemAndElementBudgets_identifyTheNextUnverifiedLocation() throws {
        let wire = sequenceHeader() + itemHeader(length: 0) + itemHeader(length: 0)
        let itemLimited = try DicomEncodedDataSetValidator.validate(wire,
            limits: .init(maximumSequenceDepth: 1, maximumElementCount: 10, maximumItemCount: 1))
        XCTAssertEqual(itemLimited.report[.structure], .incomplete)
        XCTAssertEqual(itemLimited.report.diagnostics.first?.path, [.tag(0x0040A730), .item(1)])
        let element = try DicomDataSetWriter.dataSetData(from: .init(elements: [
            .init(tag: 0x00100010, vr: .PN, value: .strings(["SYNTHETIC"]))
        ]))
        let elementLimited = try DicomEncodedDataSetValidator.validate(sequenceHeader() + itemHeader(length: UInt32.max) + element,
            limits: .init(maximumSequenceDepth: 1, maximumElementCount: 1, maximumItemCount: 1))
        XCTAssertEqual(elementLimited.report.diagnostics.first?.path, [.tag(0x0040A730), .item(0), .tag(0x00100010)])
    }

    func test_truncatedPixelFragment_identifiesAnItemWithoutInventingAFrameNumber() throws {
        var wire = Data([0xE0, 0x7F, 0x10, 0, 0x4F, 0x42, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
        wire.append(itemHeader(length: 0)) // Basic Offset Table is item zero.
        wire.append(itemHeader(length: 4))
        wire.append(Data([0, 0]))
        try assertFailure(wire, path: [.tag(0x7FE00010), .item(1)], syntax: .rleLossless)
    }

    private func assertFailure(_ wire: Data, path: [DicomValidationReport.PathComponent],
                               syntax: DicomTransferSyntax = .explicitVRLittleEndian) throws {
        let result = try DicomEncodedDataSetValidator.validate(wire, transferSyntax: syntax)
        XCTAssertNil(result.dataSet)
        XCTAssertEqual(result.report[.structure], .failed)
        let failure = try XCTUnwrap(result.report.diagnostics.first { $0.code == .invalidDataSetStructure })
        XCTAssertEqual(failure.path, path)
        XCTAssertThrowsError(try DicomDataSetParser.read(from: wire, transferSyntax: syntax)) {
            XCTAssertTrue($0 is DicomSequenceValueParserError)
        }
    }

    private func sequenceHeader() -> Data {
        Data([0x40, 0, 0x30, 0xA7, 0x53, 0x51, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    private func itemHeader(length: UInt32) -> Data {
        var bytes = Data([0xFE, 0xFF, 0, 0xE0])
        var encoded = length.littleEndian
        withUnsafeBytes(of: &encoded) { bytes.append(contentsOf: $0) }
        return bytes
    }
}
