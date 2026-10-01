//
//  ClinicalParityCuratedFixtureTests.swift
//  DicomCoreTests
//
//  Curated non-PHI parity fixtures replacing manifest placeholders
//  (issue #1224): SR TID1500 measurement report, Key Object Selection,
//  encapsulated JPEG Lossless (SV1) and encapsulated RLE.
//
//  Provenance: every fixture is generated in-repo by the deterministic
//  builders below (set DICOM_REGENERATE_PARITY_FIXTURES=1 to rewrite the
//  committed files). No external data, no PHI — identifiers use PARITY
//  placeholders only. The drift tests fail whenever the committed bytes,
//  expected UIDs, frame counts, pixel hashes, or SR tree content change.
//

import Foundation
import XCTest
@testable import DicomCore

final class ClinicalParityCuratedFixtureTests: XCTestCase {
    // MARK: - Fixture catalog

    private struct CuratedFixture: Sendable {
        let relativePath: String
        let makeData: @Sendable () throws -> Data
    }

    private static let srTID1500Path = "Tests/DicomCoreTests/Fixtures/StructuredReports/sr_tid1500_measurement_report.dcm"
    private static let kosPath = "Tests/DicomCoreTests/Fixtures/StructuredReports/kos_key_object_selection.dcm"
    private static let jpegLosslessPath = "Tests/DicomCoreTests/Fixtures/DecoderParity/jpeg_lossless_sv1_parity.dcm"
    private static let rlePath = "Tests/DicomCoreTests/Fixtures/DecoderParity/rle_parity.dcm"

    private static let catalog: [CuratedFixture] = [
        CuratedFixture(relativePath: srTID1500Path, makeData: makeSRTID1500FixtureData),
        CuratedFixture(relativePath: kosPath, makeData: makeKOSFixtureData),
        CuratedFixture(relativePath: jpegLosslessPath, makeData: makeJPEGLosslessFixtureData),
        CuratedFixture(relativePath: rlePath, makeData: makeRLEFixtureData)
    ]

    // MARK: - Regeneration (opt-in)

    /// Set DICOM_REGENERATE_PARITY_FIXTURES=1 to rewrite the committed
    /// fixture files from the deterministic builders.
    func testRegenerateCuratedParityFixturesWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["DICOM_REGENERATE_PARITY_FIXTURES"] == "1" else {
            throw XCTSkip("Set DICOM_REGENERATE_PARITY_FIXTURES=1 to rewrite the curated parity fixtures.")
        }
        for fixture in Self.catalog {
            let url = Self.packageRoot().appendingPathComponent(fixture.relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fixture.makeData().write(to: url)
            print("Regenerated \(fixture.relativePath)")
        }
    }

    /// The committed fixture bytes must match the deterministic builders.
    func testCuratedFixtureBytesMatchDeterministicBuilders() throws {
        for fixture in Self.catalog {
            let url = Self.packageRoot().appendingPathComponent(fixture.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                XCTFail("Missing curated fixture \(fixture.relativePath); regenerate with DICOM_REGENERATE_PARITY_FIXTURES=1.")
                continue
            }
            let committed = try Data(contentsOf: url)
            let regenerated = try fixture.makeData()
            XCTAssertEqual(
                committed, regenerated,
                "\(fixture.relativePath) drifted from its deterministic builder."
            )
        }
    }

    // MARK: - SR TID1500 goldens

    func testSRTID1500FixtureExposesExpectedMeasurementTree() throws {
        let decoder = try DCMDecoder(contentsOf: Self.packageRoot().appendingPathComponent(Self.srTID1500Path))

        XCTAssertEqual(decoder.info(for: .sopClassUID), DicomSRDocument.enhancedSRStorageSOPClassUID)
        XCTAssertEqual(decoder.info(for: .studyInstanceUID), "2.25.122400101")
        XCTAssertEqual(decoder.info(for: .seriesInstanceUID), "2.25.122400102")
        XCTAssertEqual(decoder.info(for: .sopInstanceUID), "2.25.122400103")

        let document = try XCTUnwrap(decoder.structuredReport, "fixture must parse as a structured report")
        XCTAssertEqual(document.templateIdentifier, "1500")
        XCTAssertEqual(document.completionFlag, "COMPLETE")
        XCTAssertEqual(document.verificationFlag, "UNVERIFIED")
        XCTAssertEqual(document.root.valueType, "CONTAINER")
        XCTAssertEqual(document.root.conceptName?.codeValue, "126000")
        XCTAssertEqual(document.root.conceptName?.codingSchemeDesignator, "DCM")

        let measurements = document.measurements
        XCTAssertEqual(measurements.count, 1, "TID1500 fixture carries exactly one measurement")
        let measurement = try XCTUnwrap(measurements.first)
        XCTAssertEqual(measurement.value, 12.5)
        XCTAssertEqual(measurement.units?.codeValue, "mm")
        XCTAssertEqual(measurement.units?.codingSchemeDesignator, "UCUM")
        XCTAssertEqual(measurement.trackingID, "PARITY-TRACK-1")
        XCTAssertEqual(
            measurement.sourceImageReferences.first?.referencedSOPInstanceUID,
            "2.25.122400110"
        )

        let findings = document.flattenedContentItems.filter { $0.valueType == "CODE" }
        XCTAssertEqual(findings.first?.codeValue?.codeValue, "RID39056")
    }

    // MARK: - KOS goldens

    func testKOSFixtureExposesKeyObjectSelectionAndEvidence() throws {
        let decoder = try DCMDecoder(contentsOf: Self.packageRoot().appendingPathComponent(Self.kosPath))

        XCTAssertEqual(
            decoder.info(for: .sopClassUID),
            DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID
        )
        let document = try XCTUnwrap(decoder.keyObjectSelection, "fixture must parse as a key object selection")
        XCTAssertEqual(document.modality, "KO")
        XCTAssertEqual(document.root.conceptName?.codeValue, "113000")

        let referencedInstances = document.root.flattened
            .flatMap(\.referencedSOPs)
            .compactMap(\.referencedSOPInstanceUID)
        XCTAssertEqual(referencedInstances, ["2.25.122400110"])

        let evidence = try XCTUnwrap(document.evidenceReferences.first, "KOS fixture must carry evidence")
        XCTAssertEqual(evidence.studyInstanceUID, "2.25.122400104")
        XCTAssertEqual(evidence.seriesInstanceUID, "2.25.122400105")
        XCTAssertEqual(evidence.referencedSOPInstanceUID, "2.25.122400110")
    }

    // MARK: - Compressed-pixel goldens

    func testJPEGLosslessFixtureDecodesWithStablePixelHash() throws {
        let decoder = try DCMDecoder(contentsOf: Self.packageRoot().appendingPathComponent(Self.jpegLosslessPath))

        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.jpegLosslessFirstOrder.rawValue)
        XCTAssertEqual(decoder.width, 2)
        XCTAssertEqual(decoder.height, 2)
        XCTAssertEqual(decoder.info(for: .sopInstanceUID), "2.25.122400120")

        let pixels = try XCTUnwrap(decoder.getPixels16(), "native JPEG Lossless decode must produce 16-bit pixels")
        XCTAssertEqual(pixels.count, 4)
        XCTAssertEqual(
            Self.pixelHash(pixels.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }),
            Self.jpegLosslessExpectedPixelHash,
            "JPEG Lossless decoded pixel hash drifted"
        )
    }

    func testRLEFixtureDecodesWithStablePixelHash() throws {
        let decoder = try DCMDecoder(contentsOf: Self.packageRoot().appendingPathComponent(Self.rlePath))

        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.rleLossless.rawValue)
        XCTAssertEqual(decoder.width, 2)
        XCTAssertEqual(decoder.height, 2)
        XCTAssertEqual(decoder.info(for: .sopInstanceUID), "2.25.122400130")

        let pixels = try XCTUnwrap(decoder.getPixels8(), "native RLE decode must produce 8-bit pixels")
        XCTAssertEqual(Array(pixels), [10, 20, 30, 40])
        XCTAssertEqual(
            Self.pixelHash(Array(pixels)),
            Self.rleExpectedPixelHash,
            "RLE decoded pixel hash drifted"
        )
    }

    /// The manifest must bind the curated fixtures and keep the remaining
    /// placeholders visible for future parity work.
    func testManifestBindsCuratedFixturesAndKeepsPlaceholdersOrdered() throws {
        let manifestURL = Self.packageRoot()
            .appendingPathComponent("Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        let features = try XCTUnwrap(object?["features"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: features.compactMap { feature in
            (feature["id"] as? String).map { ($0, feature) }
        })

        for (id, expectedArtifact) in [
            ("sr-tid1500", Self.srTID1500Path),
            ("kos", Self.kosPath),
            ("jpeg-lossless", Self.jpegLosslessPath),
            ("rle", Self.rlePath)
        ] {
            let feature = try XCTUnwrap(byID[id], "manifest must keep feature \(id)")
            XCTAssertEqual(feature["artifact"] as? String, expectedArtifact, id)
            let label = feature["label"] as? String ?? ""
            XCTAssertFalse(label.localizedCaseInsensitiveContains("placeholder"), "\(id) must no longer be a placeholder")
            XCTAssertNotNil(feature["provenance"] as? String, "\(id) must record provenance")
        }

        // JPEG 2000 stays a placeholder with a documented decision.
        let jpeg2000 = try XCTUnwrap(byID["jpeg-2000"])
        XCTAssertNotNil(
            (jpeg2000["representation"] as? String)?.range(of: "RLE"),
            "the jpeg-2000 placeholder must document why RLE was chosen as the first deterministic compressed pair"
        )

        for remaining in ["seg", "rtstruct", "rtdose", "pr", "hp", "rwv", "pmap", "dicomdir",
                          "encapsulated-pdf", "waveform", "video"] {
            XCTAssertNotNil(byID[remaining], "placeholder \(remaining) must stay visible for future parity work")
        }
    }

    // MARK: - Deterministic builders

    static func makeSRTID1500FixtureData() throws -> Data {
        let imageReference = DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.122400110",
            referencedFrameNumbers: []
        )
        let measurement = DicomSRContentItem(
            relationshipType: "CONTAINS",
            valueType: "NUM",
            conceptName: DicomCodedConcept(codeValue: "410668003", codingSchemeDesignator: "SCT", codeMeaning: "Length"),
            numericValue: 12.5,
            measurementUnits: DicomCodedConcept(codeValue: "mm", codingSchemeDesignator: "UCUM", codeMeaning: "millimeter"),
            referencedSOPs: [imageReference],
            trackingID: "PARITY-TRACK-1",
            trackingUID: "2.25.122400111"
        )
        let finding = DicomSRContentItem(
            relationshipType: "CONTAINS",
            valueType: "CODE",
            conceptName: DicomCodedConcept(codeValue: "121071", codingSchemeDesignator: "DCM", codeMeaning: "Finding"),
            codeValue: DicomCodedConcept(codeValue: "RID39056", codingSchemeDesignator: "RADLEX", codeMeaning: "Nodule")
        )
        let measurementGroup = DicomSRContentItem(
            relationshipType: "CONTAINS",
            valueType: "CONTAINER",
            conceptName: DicomCodedConcept(codeValue: "125007", codingSchemeDesignator: "DCM", codeMeaning: "Measurement Group"),
            continuityOfContent: "SEPARATE",
            children: [measurement, finding]
        )
        let document = DicomSRDocument(
            sopClassUID: DicomSRDocument.enhancedSRStorageSOPClassUID,
            sopInstanceUID: "2.25.122400103",
            modality: "SR",
            completionFlag: "COMPLETE",
            verificationFlag: "UNVERIFIED",
            templateIdentifier: "1500",
            root: DicomSRContentItem(
                valueType: "CONTAINER",
                conceptName: DicomCodedConcept(codeValue: "126000", codingSchemeDesignator: "DCM", codeMeaning: "Imaging Measurement Report"),
                continuityOfContent: "SEPARATE",
                children: [measurementGroup]
            ),
            evidenceReferences: [
                DicomKeyObjectReference(
                    studyInstanceUID: "2.25.122400104",
                    seriesInstanceUID: "2.25.122400105",
                    referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
                    referencedSOPInstanceUID: "2.25.122400110"
                )
            ]
        )
        var dataSet = DicomStructuredReportBuilder.dataSet(
            from: document,
            studyInstanceUID: "2.25.122400101",
            seriesInstanceUID: "2.25.122400102",
            sopInstanceUID: "2.25.122400103"
        )
        appendParityPatientModule(to: &dataSet, name: "PARITY^SR", id: "PARITY-1224-SR")
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomSRDocument.enhancedSRStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.122400103"
            )
        )
    }

    static func makeKOSFixtureData() throws -> Data {
        let imageReference = DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.122400110",
            referencedFrameNumbers: []
        )
        let document = DicomSRDocument(
            sopClassUID: DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID,
            sopInstanceUID: "2.25.122400106",
            modality: "KO",
            root: DicomSRContentItem(
                valueType: "CONTAINER",
                conceptName: DicomCodedConcept(codeValue: "113000", codingSchemeDesignator: "DCM", codeMeaning: "Of Interest"),
                continuityOfContent: "SEPARATE",
                children: [
                    DicomSRContentItem(
                        relationshipType: "CONTAINS",
                        valueType: "IMAGE",
                        referencedSOPs: [imageReference]
                    )
                ]
            ),
            evidenceReferences: [
                DicomKeyObjectReference(
                    studyInstanceUID: "2.25.122400104",
                    seriesInstanceUID: "2.25.122400105",
                    referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
                    referencedSOPInstanceUID: "2.25.122400110"
                )
            ]
        )
        var dataSet = DicomStructuredReportBuilder.dataSet(
            from: document,
            studyInstanceUID: "2.25.122400104",
            seriesInstanceUID: "2.25.122400107",
            sopInstanceUID: "2.25.122400106"
        )
        appendParityPatientModule(to: &dataSet, name: "PARITY^KOS", id: "PARITY-1224-KOS")
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.122400106"
            )
        )
    }

    static func makeJPEGLosslessFixtureData() throws -> Data {
        // Deterministic SOF3 (Process 14, SV1) codestream: 2x2, 16-bit,
        // all-zero entropy payload — the native decoder reconstructs the
        // predictor baseline deterministically.
        let codestream = makeMinimalJPEGLosslessData(width: 2, height: 2, precision: 16, predictionMode: 1)
        let dataSet = makeCompressedImageDataSet(
            sopInstanceUID: "2.25.122400120",
            patientName: "PARITY^JPEGLL",
            patientID: "PARITY-1224-JLL",
            bitsAllocated: 16,
            bitsStored: 16,
            highBit: 15,
            fragments: [codestream]
        )
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .jpegLosslessFirstOrder,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.122400120"
            )
        )
    }

    static func makeRLEFixtureData() throws -> Data {
        // Deterministic RLE: 64-byte header (one segment at offset 64) and a
        // PackBits literal run carrying the four 8-bit samples.
        var rle = Data()
        var header = [UInt32](repeating: 0, count: 16)
        header[0] = 1
        header[1] = 64
        for value in header {
            withUnsafeBytes(of: value.littleEndian) { rle.append(contentsOf: $0) }
        }
        rle.append(contentsOf: [0x03, 10, 20, 30, 40])
        if rle.count % 2 != 0 {
            rle.append(0x00)
        }
        let dataSet = makeCompressedImageDataSet(
            sopInstanceUID: "2.25.122400130",
            patientName: "PARITY^RLE",
            patientID: "PARITY-1224-RLE",
            bitsAllocated: 8,
            bitsStored: 8,
            highBit: 7,
            fragments: [rle]
        )
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .rleLossless,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.122400130"
            )
        )
    }

    // MARK: - Builder helpers

    private static func appendParityPatientModule(to dataSet: inout DicomDataSet, name: String, id: String) {
        dataSet.set(DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings([name])))
        dataSet.set(DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings([id])))
        dataSet.set(DicomDataElement(tag: DicomTag.studyDate.rawValue, vr: .DA, value: .strings(["20260611"])))
        dataSet.set(DicomDataElement(tag: DicomTag.studyTime.rawValue, vr: .TM, value: .strings(["120000"])))
        dataSet.set(DicomDataElement(tag: DicomTag.seriesNumber.rawValue, vr: .IS, value: .strings(["1"])))
        dataSet.set(DicomDataElement(tag: DicomTag.instanceNumber.rawValue, vr: .IS, value: .strings(["1"])))
    }

    private static func makeCompressedImageDataSet(
        sopInstanceUID: String,
        patientName: String,
        patientID: String,
        bitsAllocated: UInt,
        bitsStored: UInt,
        highBit: UInt,
        fragments: [Data]
    ) -> DicomDataSet {
        DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI,
                             value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([sopInstanceUID])),
            DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings([patientName])),
            DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings([patientID])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.122400108"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.122400109"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["MONOCHROME2"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([2])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([2])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([bitsAllocated])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([bitsStored])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([highBit])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["1"])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB,
                             value: .bytes(makeEncapsulatedPixelData(fragments: fragments)))
        ])
    }

    private static func makeEncapsulatedPixelData(fragments: [Data]) -> Data {
        var data = Data()
        var offsets: [UInt32] = []
        var runningOffset: UInt32 = 0
        for fragment in fragments {
            offsets.append(runningOffset)
            runningOffset += UInt32(8 + fragment.count)
        }
        appendItem(offsetTableData(offsets), to: &data)
        for fragment in fragments {
            appendItem(fragment, to: &data)
        }
        appendTag(0xFFFE_E0DD, to: &data)
        appendUInt32(0, to: &data)
        return data
    }

    private static func offsetTableData(_ offsets: [UInt32]) -> Data {
        var data = Data()
        for offset in offsets {
            withUnsafeBytes(of: offset.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func appendItem(_ payload: Data, to data: inout Data) {
        appendTag(0xFFFE_E000, to: &data)
        appendUInt32(UInt32(payload.count), to: &data)
        data.append(payload)
    }

    private static func appendTag(_ tag: UInt32, to data: inout Data) {
        let group = UInt16(tag >> 16)
        let element = UInt16(tag & 0xFFFF)
        withUnsafeBytes(of: group.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: element.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    // MARK: - Pixel hashing (FNV-1a, dependency-free and stable)

    static func pixelHash(_ bytes: [UInt8]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// Expected hashes recorded from the first deterministic generation.
    static let jpegLosslessExpectedPixelHash = "abb9c84a59e62cc5"
    static let rleExpectedPixelHash = "dfd466d299e427e5"

    private static func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
