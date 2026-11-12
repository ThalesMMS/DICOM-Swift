//
//  DicomMetadataParsingHardeningTests.swift
//  DicomCoreTests
//
//  Metadata parsing hardening (issue #1235). Policy of record for undefined-length elements: an
//  undefined length puts the parser into item-scanning mode (the element's value is never
//  materialized) and scanning continues past the matching delimiter — undefined-length non-SQ
//  elements are safely skipped, never a hard failure. Stray delimiters reset sequence state and are
//  ignored. Unknown explicit VRs skip by their declared length. Oversized declared lengths clamp to
//  the remaining bytes and fail the load typed when they swallow the stream. Metadata for the pixel
//  module, VOI, modality LUT, overlays, and geometry stays readable without pixel decode.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
import XCTest
@testable import DicomCore

final class DicomMetadataParsingHardeningTests: XCTestCase {
    // MARK: - Undefined-length non-SQ elements

    func testUndefinedLengthNonSQElementIsSafelySkippedAndLaterTagsRead() throws {
        var body = Data()
        // (0009,0001) UN, undefined length, item-structured private payload.
        appendTag(&body, group: 0x0009, element: 0x0001)
        body.append(contentsOf: [0x55, 0x4E, 0x00, 0x00]) // "UN" + reserved
        body.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // undefined length
        appendItem(&body, payload: Data())
        appendSequenceDelimiter(&body)
        appendShortString(&body, group: 0x0010, element: 0x0010, vr: "PN", value: "HARDEN^CASE")
        appendShortString(&body, group: 0x0010, element: 0x0020, vr: "LO", value: "HARDEN-1235")

        let decoder = try open(body: body)
        XCTAssertEqual(decoder.info(for: .patientName), "HARDEN^CASE")
        XCTAssertEqual(decoder.info(for: .patientID), "HARDEN-1235")
    }

    func testNestedSequenceContainingUndefinedLengthNonSQValueParses() throws {
        var inner = Data()
        // Item dataset: an undefined-length UN value followed by a normal element.
        appendTag(&inner, group: 0x0009, element: 0x0002)
        inner.append(contentsOf: [0x55, 0x4E, 0x00, 0x00])
        inner.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        appendItem(&inner, payload: Data())
        appendSequenceDelimiter(&inner)
        appendShortString(&inner, group: 0x0008, element: 0x0070, vr: "LO", value: "PARITY")

        var body = Data()
        // (0008,1140) SQ with one defined-length item carrying the inner dataset.
        appendTag(&body, group: 0x0008, element: 0x1140)
        body.append(contentsOf: [0x53, 0x51, 0x00, 0x00]) // "SQ" + reserved
        appendUInt32(&body, UInt32(inner.count + 8))
        appendItem(&body, payload: inner)
        appendShortString(&body, group: 0x0010, element: 0x0010, vr: "PN", value: "NESTED^CASE")

        let decoder = try open(body: body)
        XCTAssertEqual(decoder.info(for: .patientName), "NESTED^CASE",
                       "elements after the nested undefined-length value must stay readable")
    }

    // MARK: - Malformed lengths, stray delimiters, unknown VRs

    /// Policy: a declared length running past the end of the data clamps
    /// to the remaining bytes; when that swallows the rest of the stream
    /// the load fails with a typed invalidDICOMFormat error — never a
    /// crash or a silent partial success.
    func testOversizedDeclaredLengthFailsTypedWithoutCrashing() throws {
        var body = Data()
        appendShortString(&body, group: 0x0008, element: 0x0060, vr: "CS", value: "CT")
        // (0008,103E) LO declaring far more bytes than remain in the file,
        // swallowing everything after it (including Pixel Data).
        appendTag(&body, group: 0x0008, element: 0x103E)
        body.append(contentsOf: [0x4C, 0x4F]) // "LO"
        body.append(contentsOf: [0xFF, 0x7F]) // 32767 declared, only a few remain
        body.append(contentsOf: "TAIL".utf8)

        XCTAssertThrowsError(try open(body: body, appendBaseModule: false)) { error in
            guard case DICOMError.invalidDICOMFormat = error else {
                return XCTFail("expected invalidDICOMFormat, got \(error)")
            }
        }
    }

    func testStraySequenceDelimitersOutsideSequencesAreIgnored() throws {
        var body = Data()
        appendShortString(&body, group: 0x0010, element: 0x0010, vr: "PN", value: "STRAY^CASE")
        // Item delimiter and sequence delimiter with no open sequence.
        appendTag(&body, group: 0xFFFE, element: 0xE00D)
        appendUInt32(&body, 0)
        appendSequenceDelimiter(&body)
        appendShortString(&body, group: 0x0010, element: 0x0020, vr: "LO", value: "STRAY-1235")

        let decoder = try open(body: body)
        XCTAssertEqual(decoder.info(for: .patientName), "STRAY^CASE")
        XCTAssertEqual(decoder.info(for: .patientID), "STRAY-1235")
    }

    func testUnknownExplicitVRSkipsByDeclaredLength() throws {
        var body = Data()
        // (0009,0003) with the bogus VR "XZ" and a 4-byte payload.
        appendTag(&body, group: 0x0009, element: 0x0003)
        body.append(contentsOf: [0x58, 0x5A]) // "XZ"
        body.append(contentsOf: [0x04, 0x00])
        body.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])
        appendShortString(&body, group: 0x0010, element: 0x0010, vr: "PN", value: "UNKNOWN^VR")

        let decoder = try open(body: body)
        XCTAssertEqual(decoder.info(for: .patientName), "UNKNOWN^VR")
    }

    func testLargePrivatePayloadLoadsLazilyWithoutBlockingMetadata() throws {
        var body = Data()
        appendShortString(&body, group: 0x0010, element: 0x0010, vr: "PN", value: "LARGE^CASE")
        // 1 MiB private OB payload before trailing metadata.
        appendTag(&body, group: 0x0009, element: 0x0004)
        body.append(contentsOf: [0x4F, 0x42, 0x00, 0x00]) // "OB" + reserved
        appendUInt32(&body, 1_048_576)
        body.append(Data(count: 1_048_576))
        appendShortString(&body, group: 0x0010, element: 0x0020, vr: "LO", value: "LARGE-1235")

        let decoder = try open(body: body)
        XCTAssertEqual(decoder.info(for: .patientName), "LARGE^CASE")
        XCTAssertEqual(decoder.info(for: .patientID), "LARGE-1235")
        XCTAssertTrue(decoder.pixelsNotLoaded, "metadata reads must not trigger pixel materialization")
    }

    // MARK: - Private creator blocks through read and safe rewrite

    func testMultiplePrivateCreatorBlocksSurviveReadAndRewrite() throws {
        let dataSet = DicomDataSet(elements: [
            DicomDataElement(tag: 0x0008_0016, vr: .UI,
                             value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.12350001"])),
            DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["PRIVATE^CASE"])),
            DicomDataElement(tag: 0x0009_0010, vr: .LO, value: .strings(["CREATOR A"])),
            DicomDataElement(tag: 0x0009_0011, vr: .LO, value: .strings(["CREATOR B"])),
            DicomDataElement(tag: 0x0009_1001, vr: .LO, value: .strings(["alpha-value"])),
            DicomDataElement(tag: 0x0009_1101, vr: .LO, value: .strings(["beta-value"])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["MONOCHROME2"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([2])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([2])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([16])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([16])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([15])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(Data([1, 0, 2, 0, 3, 0, 4, 0])))
        ])
        let rewritten = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.12350001"
            )
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("private_rewrite_\(UUID().uuidString).dcm")
        try rewritten.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let reread = decoder.dataSet
        XCTAssertEqual(reread.string(for: 0x0009_0010), "CREATOR A")
        XCTAssertEqual(reread.string(for: 0x0009_0011), "CREATOR B")
        XCTAssertEqual(reread.string(for: 0x0009_1001), "alpha-value")
        XCTAssertEqual(reread.string(for: 0x0009_1101), "beta-value")
    }

    // MARK: - Metadata available without pixel decode

    func testPixelModuleVOILUTOverlayAndGeometryMetadataNeedNoPixelDecode() throws {
        var body = Data()
        appendShortString(&body, group: 0x0008, element: 0x0060, vr: "CS", value: "CT")
        appendUS(&body, group: 0x0028, element: 0x0002, value: 1)
        appendShortString(&body, group: 0x0028, element: 0x0004, vr: "CS", value: "MONOCHROME2")
        appendUS(&body, group: 0x0028, element: 0x0010, value: 2)
        appendUS(&body, group: 0x0028, element: 0x0011, value: 2)
        appendUS(&body, group: 0x0028, element: 0x0100, value: 16)
        appendUS(&body, group: 0x0028, element: 0x0101, value: 12)
        appendUS(&body, group: 0x0028, element: 0x0102, value: 11)
        appendUS(&body, group: 0x0028, element: 0x0103, value: 0)
        appendShortString(&body, group: 0x0028, element: 0x1050, vr: "DS", value: "40")
        appendShortString(&body, group: 0x0028, element: 0x1051, vr: "DS", value: "400")
        appendShortString(&body, group: 0x0028, element: 0x1052, vr: "DS", value: "-1024")
        appendShortString(&body, group: 0x0028, element: 0x1053, vr: "DS", value: "1")
        appendShortString(&body, group: 0x0020, element: 0x0032, vr: "DS", value: "0\\0\\5")
        appendShortString(&body, group: 0x0020, element: 0x0037, vr: "DS", value: "1\\0\\0\\0\\1\\0")
        appendShortString(&body, group: 0x0028, element: 0x0030, vr: "DS", value: "0.5\\0.5")
        // Overlay rows/columns (6000,0010)/(6000,0011).
        appendUS(&body, group: 0x6000, element: 0x0010, value: 2)
        appendUS(&body, group: 0x6000, element: 0x0011, value: 2)
        // Modality LUT sequence (empty, defined length zero).
        appendTag(&body, group: 0x0028, element: 0x3000)
        body.append(contentsOf: [0x53, 0x51, 0x00, 0x00])
        appendUInt32(&body, 0)
        // Pixel data last.
        appendTag(&body, group: 0x7FE0, element: 0x0010)
        body.append(contentsOf: [0x4F, 0x57, 0x00, 0x00]) // "OW" + reserved
        appendUInt32(&body, 8)
        body.append(Data([1, 0, 2, 0, 3, 0, 4, 0]))

        let decoder = try open(body: body, appendBaseModule: false)

        XCTAssertEqual(decoder.intValue(for: .rows), 2)
        XCTAssertEqual(decoder.intValue(for: .columns), 2)
        XCTAssertEqual(decoder.intValue(for: .bitsStored), 12)
        XCTAssertEqual(decoder.windowSettingsV2, WindowSettings(center: 40, width: 400))
        XCTAssertEqual(decoder.rescaleParametersV2, RescaleParameters(intercept: -1024, slope: 1))
        XCTAssertEqual(decoder.info(for: .imagePositionPatient), "0\\0\\5")
        XCTAssertEqual(decoder.info(for: .imageOrientationPatient), "1\\0\\0\\0\\1\\0")
        XCTAssertEqual(decoder.info(for: .pixelSpacing), "0.5\\0.5")
        XCTAssertEqual(decoder.intValue(for: 0x60000010), 2, "overlay rows must be readable")
        XCTAssertTrue(decoder.pixelsNotLoaded,
                      "pixel module, VOI, LUT, overlay, and geometry reads must not decode pixels")
    }

    // MARK: - Raw explicit-VR little-endian builders

    private func open(body: Data, appendBaseModule: Bool = true) throws -> DCMDecoder {
        var data = Data(count: 128)
        data.append(contentsOf: "DICM".utf8)
        if appendBaseModule {
            var base = Data()
            appendUS(&base, group: 0x0028, element: 0x0002, value: 1)
            appendShortString(&base, group: 0x0028, element: 0x0004, vr: "CS", value: "MONOCHROME2")
            appendUS(&base, group: 0x0028, element: 0x0010, value: 2)
            appendUS(&base, group: 0x0028, element: 0x0011, value: 2)
            appendUS(&base, group: 0x0028, element: 0x0100, value: 16)
            appendUS(&base, group: 0x0028, element: 0x0101, value: 16)
            appendUS(&base, group: 0x0028, element: 0x0102, value: 15)
            appendUS(&base, group: 0x0028, element: 0x0103, value: 0)
            data.append(base)
        }
        data.append(body)
        if appendBaseModule {
            var trailer = Data()
            appendTag(&trailer, group: 0x7FE0, element: 0x0010)
            trailer.append(contentsOf: [0x4F, 0x57, 0x00, 0x00]) // "OW" + reserved
            appendUInt32(&trailer, 8)
            trailer.append(Data([1, 0, 2, 0, 3, 0, 4, 0]))
            data.append(trailer)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hardening_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }

    private func appendTag(_ data: inout Data, group: UInt16, element: UInt16) {
        data.append(UInt8(group & 0xFF))
        data.append(UInt8(group >> 8))
        data.append(UInt8(element & 0xFF))
        data.append(UInt8(element >> 8))
    }

    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendShortString(_ data: inout Data, group: UInt16, element: UInt16, vr: String, value: String) {
        var bytes = Array(value.utf8)
        if bytes.count % 2 != 0 {
            bytes.append(vr == "UI" ? 0x00 : 0x20)
        }
        appendTag(&data, group: group, element: element)
        data.append(contentsOf: Array(vr.utf8))
        data.append(UInt8(bytes.count & 0xFF))
        data.append(UInt8(bytes.count >> 8))
        data.append(contentsOf: bytes)
    }

    private func appendUS(_ data: inout Data, group: UInt16, element: UInt16, value: UInt16) {
        appendTag(&data, group: group, element: element)
        data.append(contentsOf: [0x55, 0x53]) // "US"
        data.append(contentsOf: [0x02, 0x00])
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private func appendItem(_ data: inout Data, payload: Data) {
        appendTag(&data, group: 0xFFFE, element: 0xE000)
        appendUInt32(&data, UInt32(payload.count))
        data.append(payload)
    }

    private func appendSequenceDelimiter(_ data: inout Data) {
        appendTag(&data, group: 0xFFFE, element: 0xE0DD)
        appendUInt32(&data, 0)
    }
}
