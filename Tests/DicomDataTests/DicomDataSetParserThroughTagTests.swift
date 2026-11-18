//
//  DicomDataSetParserThroughTagTests.swift
//  DicomDataTests
//
//  Checks bounded parsing through a requested tag and stopping when that tag is absent.
//
//  Thales Matheus Mendonça Santos — November 2026
//

import DicomData
import XCTest

final class DicomDataSetParserThroughTagTests: XCTestCase {
    private func element(_ group: UInt16, _ element: UInt16, _ vr: String, _ value: String) -> Data {
        var padded = Data(value.utf8)
        if !padded.count.isMultiple(of: 2) { padded.append(vr == "UI" ? 0x00 : 0x20) }
        var data = Data([UInt8(group & 0xFF), UInt8(group >> 8), UInt8(element & 0xFF), UInt8(element >> 8)])
        data.append(Data(vr.utf8))
        data.append(contentsOf: [UInt8(padded.count & 0xFF), UInt8(padded.count >> 8)])
        data.append(padded)
        return data
    }

    func test_dataSet_throughTag_readsThroughTheTagAndNotWhatFollows() throws {
        var bytes = Data(repeating: 0xAA, count: 3)
        bytes.append(element(0x0008, 0x0016, "UI", "1.2.840.10008.5.1.4.1.1.7"))
        bytes.append(element(0x0008, 0x0018, "UI", "2.25.3277"))
        bytes.append(element(0x0010, 0x0010, "PN", "DOE^JANE"))
        // An element that runs past the data: a whole parse refuses it.
        bytes.append(contentsOf: [0x10, 0x00, 0x20, 0x00, 0x4C, 0x4F, 0xFF, 0x00])

        XCTAssertThrowsError(try DicomDataSetParser.dataSet(from: bytes, startingAt: 3))
        let leading = try DicomDataSetParser.dataSet(from: bytes, startingAt: 3, throughTag: 0x0008_0018)

        XCTAssertEqual(leading.elements.map(\.tag), [0x0008_0016, 0x0008_0018])
        XCTAssertEqual(leading.string(for: 0x0008_0018), "2.25.3277")
    }

    func test_dataSet_throughTag_absentTagEndsAtTheFirstElementPastIt() throws {
        var bytes = element(0x0008, 0x0016, "UI", "1.2.840.10008.5.1.4.1.1.7")
        bytes.append(element(0x0010, 0x0010, "PN", "DOE^JANE"))

        let leading = try DicomDataSetParser.dataSet(from: bytes, startingAt: 0, throughTag: 0x0008_0018)

        XCTAssertEqual(leading.elements.map(\.tag), [0x0008_0016])
    }
}
