//
//  DCMDecoderImplicitVRParserRegressionTests.swift
//  DicomCoreTests
//
//  Checks implicit-VR parsing when length bytes resemble explicit VR codes or private sequences
//  precede image metadata.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

final class DCMDecoderImplicitVRParserRegressionTests: XCTestCase {
    func testImplicitVRLengthBytesThatLookLikeOBDoNotDerailParsing() throws {
        let fixture = makeImplicitVRDICOMWithOBLookingLength()
        let url = try writeTemporaryDICOM(fixture.data)

        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertEqual(decoder.width, 3)
        XCTAssertEqual(decoder.height, 2)
        XCTAssertEqual(decoder.offset, fixture.realPixelOffset)
        XCTAssertEqual(decoder.getPixels8(), [1, 2, 3, 4, 5, 6])
    }

    func testImplicitVRPrivateUndefinedSequenceDoesNotOverrideTopLevelImageState() throws {
        let fixture = makeImplicitVRDICOMWithPrivateUndefinedSequence()
        let url = try writeTemporaryDICOM(fixture.data)

        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertEqual(decoder.width, 3)
        XCTAssertEqual(decoder.height, 2)
        XCTAssertEqual(decoder.offset, fixture.realPixelOffset)
        XCTAssertEqual(decoder.getPixels8(), [10, 20, 30, 40, 50, 60])
    }

    private func makeImplicitVRDICOMWithOBLookingLength() -> (data: Data, realPixelOffset: Int) {
        var data = makePart10Header()
        appendRequiredImplicitImageTags(to: &data)

        var unluckyValue = Data(repeating: 0, count: 0x424F)
        unluckyValue.replaceSubrange(0..<4, with: [0, 0, 0, 0])
        appendImplicitElement(group: 0x0019, element: 0x1002, value: unluckyValue, to: &data)

        let realPixelOffset = appendImplicitElement(
            group: 0x7FE0,
            element: 0x0010,
            value: Data([1, 2, 3, 4, 5, 6]),
            to: &data
        )
        return (data, realPixelOffset)
    }

    private func makeImplicitVRDICOMWithPrivateUndefinedSequence() -> (data: Data, realPixelOffset: Int) {
        var data = makePart10Header()
        appendRequiredImplicitImageTags(to: &data)

        appendImplicitElementHeader(group: 0x0019, element: 0x1001, length: UInt32.max, to: &data)
        appendItem(length: UInt32.max, to: &data)
        appendImplicitElement(group: 0x0028, element: 0x0010, value: littleEndianUInt16(99), to: &data)
        appendImplicitElement(group: 0x0028, element: 0x0011, value: littleEndianUInt16(99), to: &data)
        appendImplicitElement(group: 0x7FE0, element: 0x0010, value: Data([0xEE, 0xFF]), to: &data)
        appendItemDelimitation(to: &data)
        appendSequenceDelimitation(to: &data)

        let realPixelOffset = appendImplicitElement(
            group: 0x7FE0,
            element: 0x0010,
            value: Data([10, 20, 30, 40, 50, 60]),
            to: &data
        )
        return (data, realPixelOffset)
    }

    private func makePart10Header() -> Data {
        var data = Data(count: 128)
        data.append(contentsOf: "DICM".utf8)
        appendExplicitElement(
            group: 0x0002,
            element: 0x0010,
            vr: "UI",
            value: Data("\(DicomTransferSyntax.implicitVRLittleEndian.rawValue)\0".utf8),
            to: &data,
            paddingByte: 0x00
        )
        return data
    }

    private func appendRequiredImplicitImageTags(to data: inout Data) {
        appendImplicitElement(group: 0x0008, element: 0x0060, value: Data("CT".utf8), to: &data)
        appendImplicitElement(group: 0x0028, element: 0x0002, value: littleEndianUInt16(1), to: &data)
        appendImplicitElement(group: 0x0028, element: 0x0004, value: Data("MONOCHROME2 ".utf8), to: &data)
        appendImplicitElement(group: 0x0028, element: 0x0010, value: littleEndianUInt16(2), to: &data)
        appendImplicitElement(group: 0x0028, element: 0x0011, value: littleEndianUInt16(3), to: &data)
        appendImplicitElement(group: 0x0028, element: 0x0100, value: littleEndianUInt16(8), to: &data)
        appendImplicitElement(group: 0x0028, element: 0x0101, value: littleEndianUInt16(8), to: &data)
        appendImplicitElement(group: 0x0028, element: 0x0102, value: littleEndianUInt16(7), to: &data)
        appendImplicitElement(group: 0x0028, element: 0x0103, value: littleEndianUInt16(0), to: &data)
    }

    @discardableResult
    private func appendImplicitElement(group: UInt16, element: UInt16, value: Data, to data: inout Data) -> Int {
        appendImplicitElementHeader(group: group, element: element, length: UInt32(value.count), to: &data)
        let valueOffset = data.count
        data.append(value)
        return valueOffset
    }

    private func appendImplicitElementHeader(group: UInt16, element: UInt16, length: UInt32, to data: inout Data) {
        appendUInt16(group, to: &data)
        appendUInt16(element, to: &data)
        appendUInt32(length, to: &data)
    }

    private func appendExplicitElement(
        group: UInt16,
        element: UInt16,
        vr: String,
        value: Data,
        to data: inout Data,
        paddingByte: UInt8 = 0x20
    ) {
        appendUInt16(group, to: &data)
        appendUInt16(element, to: &data)
        data.append(contentsOf: vr.utf8)

        let paddedLength = value.count + (value.count % 2)
        if ["OB", "OD", "OF", "OW", "OV", "SQ", "UN", "UR", "UT"].contains(vr) {
            data.append(contentsOf: [0, 0])
            appendUInt32(UInt32(paddedLength), to: &data)
        } else {
            appendUInt16(UInt16(paddedLength), to: &data)
        }

        data.append(value)
        if value.count % 2 != 0 {
            data.append(paddingByte)
        }
    }

    private func appendItem(length: UInt32, to data: inout Data) {
        appendUInt16(0xFFFE, to: &data)
        appendUInt16(0xE000, to: &data)
        appendUInt32(length, to: &data)
    }

    private func appendItemDelimitation(to data: inout Data) {
        appendUInt16(0xFFFE, to: &data)
        appendUInt16(0xE00D, to: &data)
        appendUInt32(0, to: &data)
    }

    private func appendSequenceDelimitation(to data: inout Data) {
        appendUInt16(0xFFFE, to: &data)
        appendUInt16(0xE0DD, to: &data)
        appendUInt32(0, to: &data)
    }

    private func littleEndianUInt16(_ value: UInt16) -> Data {
        var encoded = value.littleEndian
        return withUnsafeBytes(of: &encoded) { Data($0) }
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        var encoded = value.littleEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var encoded = value.littleEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private func writeTemporaryDICOM(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("dcm")
        try data.write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
