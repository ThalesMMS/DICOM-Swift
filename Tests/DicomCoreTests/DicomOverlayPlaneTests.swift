//
//  DicomOverlayPlaneTests.swift
//  DicomCoreTests
//
//  Checks overlay bit packing, frame origins, repeating groups, and application to image frames.
//
//  Thales Matheus Mendonça Santos — July 2026
//

import Foundation
import XCTest
@testable import DicomCore

final class DicomOverlayPlaneTests: XCTestCase {
    func testStandaloneMultiFrameOverlayUsesContinuousLSBFirstBitsAndImageFrameOrigin() throws {
        let first = [UInt8](repeating: 0, count: 6)
        let second: [UInt8] = [1, 0, 1, 0, 1, 1]
        var dataSet = makeImageDataSet(numberOfFrames: 3)
        addOverlay(
            to: &dataSet,
            group: 0x6000,
            rows: 2,
            columns: 3,
            origin: [2, -1],
            numberOfFrames: 2,
            imageFrameOrigin: 2,
            data: packedBits(first + second)
        )

        let decoder = try open(dataSet)
        XCTAssertTrue(decoder.overlayPlanes(forFrame: 0).isEmpty)
        let plane = try XCTUnwrap(decoder.overlayPlanes(forFrame: 2).first)

        XCTAssertEqual(plane.group, 0x6000)
        XCTAssertEqual(plane.rows, 2)
        XCTAssertEqual(plane.columns, 3)
        XCTAssertEqual(plane.originRow, 1)
        XCTAssertEqual(plane.originColumn, -2)
        XCTAssertEqual(plane.kind, .graphics)
        XCTAssertEqual(plane.source, .overlayData)
        XCTAssertEqual(Array(plane.mask), second)
    }

    func testSingleFrameOverlayAppliesToEveryImageFrameAndAllRepeatingGroupsAreParsed() throws {
        let bits: [UInt8] = [1, 0, 0, 1]
        var dataSet = makeImageDataSet(numberOfFrames: 2)
        addOverlay(to: &dataSet, group: 0x6000, rows: 2, columns: 2, data: packedBits(bits))
        addOverlay(
            to: &dataSet,
            group: 0x601E,
            rows: 2,
            columns: 2,
            type: "R",
            data: packedBits([0, 1, 1, 0])
        )

        let decoder = try open(dataSet)
        XCTAssertTrue(decoder.pixelsNotLoaded)
        let planes = decoder.overlayPlanes(forFrame: 1)
        XCTAssertEqual(planes.map(\.group), [0x6000, 0x601E])
        XCTAssertEqual(Array(planes[0].mask), bits)
        XCTAssertEqual(planes[1].kind, .regionOfInterest)
        XCTAssertTrue(decoder.pixelsNotLoaded, "standalone Overlay Data must not decode Pixel Data")
    }

    func testLegacyEmbeddedOverlayReadsTheDeclaredNativePixelBitAtOverlayOrigin() throws {
        var dataSet = makeImageDataSet(
            rows: 2,
            columns: 3,
            bitsAllocated: 16,
            bitsStored: 12,
            pixelBytes: uint16Bytes([0, 0x8000, 0, 0, 0, 0x8000])
        )
        addOverlay(
            to: &dataSet,
            group: 0x6000,
            rows: 2,
            columns: 2,
            origin: [1, 2],
            bitsAllocated: 16,
            bitPosition: 15,
            data: nil
        )

        let plane = try XCTUnwrap(open(dataSet).overlayPlanes().first)
        XCTAssertEqual(plane.source, .embeddedPixelData(bitPosition: 15))
        XCTAssertEqual(Array(plane.mask), [1, 0, 0, 1])
    }

    func testLegacyEmbeddedMultiFrameOverlayHonorsImageFrameOriginAndFrameCount() throws {
        var dataSet = makeImageDataSet(
            rows: 1,
            columns: 1,
            numberOfFrames: 3,
            bitsAllocated: 16,
            bitsStored: 12,
            pixelBytes: uint16Bytes([0, 0x8000, 0x8000])
        )
        addOverlay(
            to: &dataSet,
            group: 0x6000,
            rows: 1,
            columns: 1,
            numberOfFrames: 1,
            imageFrameOrigin: 2,
            bitsAllocated: 16,
            bitPosition: 15,
            data: nil
        )

        let decoder = try open(dataSet)
        XCTAssertTrue(decoder.overlayPlanes(forFrame: 0).isEmpty)
        XCTAssertEqual(Array(try XCTUnwrap(decoder.overlayPlanes(forFrame: 1).first).mask), [1])
        XCTAssertTrue(decoder.overlayPlanes(forFrame: 2).isEmpty)
    }

    func testMalformedOrTruncatedOverlayIsIgnored() throws {
        var dataSet = makeImageDataSet()
        addOverlay(to: &dataSet, group: 0x6000, rows: 8, columns: 8, data: Data([0x01]))

        XCTAssertTrue(try open(dataSet).overlayPlanes().isEmpty)
    }

    func testBigEndianOWOverlayUsesWordByteOrderAndLSBFirstBits() throws {
        var dataSet = makeImageDataSet(rows: 1, columns: 4)
        addOverlay(
            to: &dataSet,
            group: 0x6000,
            rows: 1,
            columns: 4,
            data: Data([0x00, 0x05])
        )

        let plane = try XCTUnwrap(open(
            dataSet,
            transferSyntax: .explicitVRBigEndian
        ).overlayPlanes().first)

        XCTAssertEqual(Array(plane.mask), [1, 0, 1, 0])
    }

    private func open(
        _ dataSet: DicomDataSet,
        transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian
    ) throws -> DCMDecoder {
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: transferSyntax,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.1523001"
            )
        )
        return try DCMDecoder(data: data)
    }

    private func makeImageDataSet(
        rows: Int = 2,
        columns: Int = 3,
        numberOfFrames: Int = 1,
        bitsAllocated: Int = 8,
        bitsStored: Int = 8,
        pixelBytes: Data? = nil
    ) -> DicomDataSet {
        let bytesPerSample = bitsAllocated / 8
        let pixels = pixelBytes ?? Data(repeating: 0, count: rows * columns * numberOfFrames * bytesPerSample)
        return DicomDataSet(elements: [
            element(.sopClassUID, .UI, .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
            element(.sopInstanceUID, .UI, .strings(["2.25.1523001"])),
            element(.rows, .US, .unsignedIntegers([UInt(rows)])),
            element(.columns, .US, .unsignedIntegers([UInt(columns)])),
            element(.numberOfFrames, .IS, .strings([String(numberOfFrames)])),
            element(.samplesPerPixel, .US, .unsignedIntegers([1])),
            element(.photometricInterpretation, .CS, .strings(["MONOCHROME2"])),
            element(.bitsAllocated, .US, .unsignedIntegers([UInt(bitsAllocated)])),
            element(.bitsStored, .US, .unsignedIntegers([UInt(bitsStored)])),
            element(.highBit, .US, .unsignedIntegers([UInt(bitsStored - 1)])),
            element(.pixelRepresentation, .US, .unsignedIntegers([0])),
            element(.pixelData, bitsAllocated > 8 ? .OW : .OB, .bytes(pixels))
        ])
    }

    private func addOverlay(
        to dataSet: inout DicomDataSet,
        group: Int,
        rows: Int,
        columns: Int,
        origin: [Int] = [1, 1],
        type: String = "G",
        numberOfFrames: Int? = nil,
        imageFrameOrigin: Int? = nil,
        bitsAllocated: Int = 1,
        bitPosition: Int = 0,
        data: Data?
    ) {
        dataSet.set(rawElement(group, 0x0010, .US, .unsignedIntegers([UInt(rows)])))
        dataSet.set(rawElement(group, 0x0011, .US, .unsignedIntegers([UInt(columns)])))
        dataSet.set(rawElement(group, 0x0040, .CS, .strings([type])))
        dataSet.set(rawElement(group, 0x0050, .SS, .signedIntegers(origin)))
        dataSet.set(rawElement(group, 0x0100, .US, .unsignedIntegers([UInt(bitsAllocated)])))
        dataSet.set(rawElement(group, 0x0102, .US, .unsignedIntegers([UInt(bitPosition)])))
        if let numberOfFrames {
            dataSet.set(rawElement(group, 0x0015, .IS, .strings([String(numberOfFrames)])))
        }
        if let imageFrameOrigin {
            dataSet.set(rawElement(group, 0x0051, .US, .unsignedIntegers([UInt(imageFrameOrigin)])))
        }
        if let data {
            dataSet.set(rawElement(group, 0x3000, .OW, .bytes(data)))
        }
    }

    private func element(_ tag: DicomTag, _ vr: DicomVR, _ value: DicomDataValue) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: value)
    }

    private func rawElement(_ group: Int, _ element: Int, _ vr: DicomVR, _ value: DicomDataValue) -> DicomDataElement {
        DicomDataElement(tag: (group << 16) | element, vr: vr, value: value)
    }

    private func packedBits(_ bits: [UInt8]) -> Data {
        var bytes = Data(repeating: 0, count: (bits.count + 7) / 8)
        for (index, bit) in bits.enumerated() where bit != 0 {
            bytes[index / 8] |= UInt8(1 << (index % 8))
        }
        return bytes
    }

    private func uint16Bytes(_ values: [UInt16]) -> Data {
        var data = Data()
        for value in values {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8(value >> 8))
        }
        return data
    }
}
