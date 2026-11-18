//
//  DicomAnonymizerTests.swift
//  DicomCoreTests
//
//  Safe Part 10 rewrite and anonymization (issue #1236): policy-driven remove/replace/keep/remap
//  with nested sequence traversal, transfer syntax and file meta preservation, byte-for-byte
//  encapsulated Pixel Data pass-through (offset tables intact), deterministic UID remapping with
//  stable relationships, PHI-free audit output, and typed failures on invalid inputs.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
import XCTest
import DicomTestSupport
@testable import DicomCore

final class DicomAnonymizerTests: XCTestCase {
    // MARK: - Uncompressed round trip

    func testDefaultAnonymizationRewritesIdentityAndPreservesPixels() throws {
        let pixels: [UInt8] = [1, 0, 2, 0, 3, 0, 4, 0]
        let source = try Self.makeNativeFile(pixelBytes: Data(pixels))
        let result = try DicomAnonymizer().rewrite(source)

        let decoder = try Self.open(result.fileData)
        XCTAssertEqual(decoder.info(for: .patientName), "ANONYMIZED")
        XCTAssertEqual(decoder.info(for: .patientID), "ANON")
        XCTAssertEqual(decoder.info(for: 0x00100030), "", "birth date must be removed")
        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.explicitVRLittleEndian.rawValue,
                       "transfer syntax must be preserved")
        XCTAssertEqual(decoder.info(for: .sopClassUID),
                       DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID)
        XCTAssertEqual(try XCTUnwrap(decoder.getPixels16()), [1, 2, 3, 4],
                       "pixel values must survive the rewrite")

        let dispositions = Dictionary(grouping: result.audit, by: \.disposition)
        XCTAssertNotNil(dispositions[.changed])
        XCTAssertNotNil(dispositions[.removed])
        XCTAssertNotNil(dispositions[.remapped])
        XCTAssertFalse(result.audit.contains { $0.note?.contains("PHI^PATIENT") == true },
                       "audit must not log original PHI values")
    }

    // MARK: - Compressed byte-for-byte pass-through

    func testCompressedRewritePreservesEncapsulatedPixelDataByteForByte() throws {
        let codestream = makeJPEGLosslessStream(
            planes: [[100, 200, 300, 400]], width: 2, height: 2, precision: 16
        )
        var dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .jpegLosslessFirstOrder,
            fragments: [codestream],
            declaredFrames: 1,
            rows: 2,
            columns: 2,
            bitsAllocated: 16,
            bitsStored: 16,
            highBit: 15
        )
        dataSet.set(DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["PHI^PATIENT"])))
        let source = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .jpegLosslessFirstOrder,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.12360001"
            )
        )

        let result = try DicomAnonymizer().rewrite(source)
        let rewrittenDecoder = try Self.open(result.fileData)

        XCTAssertEqual(rewrittenDecoder.info(for: .transferSyntaxUID),
                       DicomTransferSyntax.jpegLosslessFirstOrder.rawValue)
        XCTAssertEqual(rewrittenDecoder.info(for: .patientName), "ANONYMIZED")

        // Byte-for-byte: the source frame payload and offset-table mapping
        // must be identical after the rewrite.
        let sourceReader = try Self.open(source).makeEncapsulatedPixelFrameReader()
        let rewrittenReader = try rewrittenDecoder.makeEncapsulatedPixelFrameReader()
        XCTAssertEqual(rewrittenReader.frameCount, sourceReader.frameCount)
        XCTAssertEqual(try rewrittenReader.frameData(at: 0), try sourceReader.frameData(at: 0),
                       "compressed frame payload must be preserved byte-for-byte")
        XCTAssertEqual(rewrittenReader.descriptor.basicOffsetTable.offsets,
                       sourceReader.descriptor.basicOffsetTable.offsets,
                       "Basic Offset Table offsets must be preserved")

        let decoded = try DicomDecodedFrameReader(decoder: rewrittenDecoder).frame(at: 0)
        guard case .gray16(let decodedPixels) = decoded.pixels else {
            return XCTFail("expected 16-bit grayscale")
        }
        XCTAssertEqual(decodedPixels, [100, 200, 300, 400], "the preserved payload must still decode")
    }

    // MARK: - Nested sequences and UID relationships

    func testNestedSequenceRulesAndUIDRelationshipsStayConsistent() throws {
        let referenced = DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.referencedSOPClassUID.rawValue, vr: .UI,
                             value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
            DicomDataElement(tag: DicomTag.referencedSOPInstanceUID.rawValue, vr: .UI,
                             value: .strings(["2.25.99990001"])),
            DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["NESTED^PHI"]))
        ])
        var dataSet = Self.makeNativeDataSet(pixelBytes: Data([1, 0, 2, 0, 3, 0, 4, 0]))
        dataSet.set(DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI,
                                     value: .strings(["2.25.99990001"])))
        dataSet.set(DicomDataElement(
            tag: 0x0008_1140, vr: .SQ,
            value: .sequence([DicomSequenceItem(dataSet: referenced)])
        ))
        let source = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.99990001"
            )
        )

        let result = try DicomAnonymizer().rewrite(source)

        let items = result.dataSet.sequenceItems(for: 0x0008_1140)
        XCTAssertEqual(items.count, 1)
        let nested = try XCTUnwrap(items.first?.dataSet)
        XCTAssertEqual(nested.string(for: .patientName), "ANONYMIZED",
                       "anonymization rules must apply inside sequence items")

        let remappedTop = try XCTUnwrap(result.dataSet.string(for: .sopInstanceUID))
        let remappedNested = try XCTUnwrap(nested.string(for: .referencedSOPInstanceUID))
        XCTAssertEqual(remappedTop, remappedNested,
                       "the same original UID must remap to the same value at every nesting level")
        XCTAssertNotEqual(remappedTop, "2.25.99990001")
        XCTAssertEqual(result.uidMap["2.25.99990001"], remappedTop)
        XCTAssertTrue(result.audit.contains { $0.path.contains("[0]/") },
                      "audit paths must record nesting")
    }

    func testUIDRemappingIsDeterministicAcrossOperations() throws {
        let first = try DicomAnonymizer().rewrite(Self.makeNativeFile(pixelBytes: Data([1, 0, 2, 0, 3, 0, 4, 0])))
        let second = try DicomAnonymizer().rewrite(Self.makeNativeFile(pixelBytes: Data([9, 0, 9, 0, 9, 0, 9, 0])))

        XCTAssertEqual(first.uidMap["2.25.12360002"], second.uidMap["2.25.12360002"],
                       "the same study UID must remap identically across operations")
        XCTAssertEqual(
            DicomAnonymizer.deterministicUID(for: "2.25.42", root: "2.25"),
            DicomAnonymizer.deterministicUID(for: "2.25.42", root: "2.25")
        )
        XCTAssertNotEqual(
            DicomAnonymizer.deterministicUID(for: "2.25.42", root: "2.25"),
            DicomAnonymizer.deterministicUID(for: "2.25.43", root: "2.25")
        )
    }

    func testExplicitUIDValueMapRewritesOnlyMappedUIDsRecursively() throws {
        let oldStudyUID = "2.25.17750001"
        let newStudyUID = "2.25.17751001"
        let oldSOPInstanceUID = "2.25.17750002"
        let newSOPInstanceUID = "2.25.17751002"
        let externalSOPInstanceUID = "2.25.17759999"
        let trackingUID = "2.25.17758888"
        let dimensionOrganizationUID = "2.25.17757777"

        var dataSet = Self.makeNativeDataSet(pixelBytes: Data([1, 0, 2, 0, 3, 0, 4, 0]))
        dataSet.set(DicomDataElement(
            tag: DicomTag.studyInstanceUID.rawValue,
            vr: .UI,
            value: .strings([oldStudyUID])
        ))
        dataSet.set(DicomDataElement(
            tag: DicomTag.sopInstanceUID.rawValue,
            vr: .UI,
            value: .strings([oldSOPInstanceUID])
        ))
        dataSet.set(DicomDataElement(
            tag: 0x0062_0021,
            vr: .UI,
            value: .strings([trackingUID])
        ))
        dataSet.set(DicomDataElement(
            tag: 0x0020_9164,
            vr: .UI,
            value: .strings([dimensionOrganizationUID])
        ))
        dataSet.set(DicomDataElement(
            tag: 0x0008_1140,
            vr: .SQ,
            value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: [
                DicomDataElement(
                    tag: DicomTag.referencedSOPInstanceUID.rawValue,
                    vr: .UI,
                    value: .strings([oldSOPInstanceUID, externalSOPInstanceUID])
                )
            ]))])
        ))
        let source = try Self.makeNativeFile(from: dataSet)
        var policy = DicomRewritePolicy(
            actions: [:],
            removePrivateTags: false,
            uidValueReplacements: [
                oldStudyUID: newStudyUID,
                oldSOPInstanceUID: newSOPInstanceUID
            ]
        )
        policy.removeOverlayPlanes = false
        policy.removeTemporalAttributes = false

        let result = try DicomAnonymizer(policy: policy).rewrite(source)

        XCTAssertEqual(result.dataSet.string(for: .studyInstanceUID), newStudyUID)
        XCTAssertEqual(result.dataSet.string(for: .sopInstanceUID), newSOPInstanceUID)
        let referenced = try XCTUnwrap(
            result.dataSet.sequenceItems(for: 0x0008_1140).first?.dataSet
                .element(for: DicomTag.referencedSOPInstanceUID.rawValue)?.stringValues
        )
        XCTAssertEqual(referenced, [newSOPInstanceUID, externalSOPInstanceUID])
        XCTAssertEqual(result.dataSet.string(for: 0x0062_0021), trackingUID)
        XCTAssertEqual(result.dataSet.string(for: 0x0020_9164), dimensionOrganizationUID)
        XCTAssertEqual(result.uidMap, [
            oldStudyUID: newStudyUID,
            oldSOPInstanceUID: newSOPInstanceUID
        ])
        XCTAssertEqual(try Self.open(result.fileData).getPixels16(), [1, 2, 3, 4])
    }

    func testExplicitUIDValueMapPreservesEncapsulatedPayloadAndTransferSyntax() throws {
        let oldSOPInstanceUID = "2.25.17750003"
        let newSOPInstanceUID = "2.25.17751003"
        let codestream = makeJPEGLosslessStream(
            planes: [[100, 200, 300, 400]], width: 2, height: 2, precision: 16
        )
        var dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .jpegLosslessFirstOrder,
            fragments: [codestream],
            declaredFrames: 1,
            rows: 2,
            columns: 2,
            bitsAllocated: 16,
            bitsStored: 16,
            highBit: 15
        )
        dataSet.set(DicomDataElement(
            tag: DicomTag.sopInstanceUID.rawValue,
            vr: .UI,
            value: .strings([oldSOPInstanceUID])
        ))
        let source = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .jpegLosslessFirstOrder,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: oldSOPInstanceUID
            )
        )
        let sourceDecoder = try Self.open(source)
        var policy = DicomRewritePolicy(
            actions: [:],
            removePrivateTags: false,
            uidValueReplacements: [oldSOPInstanceUID: newSOPInstanceUID]
        )
        policy.removeOverlayPlanes = false
        policy.removeTemporalAttributes = false

        let result = try DicomAnonymizer(policy: policy).rewrite(source)
        let rewrittenDecoder = try Self.open(result.fileData)

        XCTAssertEqual(rewrittenDecoder.info(for: .sopInstanceUID), newSOPInstanceUID)
        XCTAssertEqual(
            rewrittenDecoder.info(for: .transferSyntaxUID),
            DicomTransferSyntax.jpegLosslessFirstOrder.rawValue
        )
        XCTAssertEqual(
            try rewrittenDecoder.makeEncapsulatedPixelFrameReader().frameData(at: 0),
            try sourceDecoder.makeEncapsulatedPixelFrameReader().frameData(at: 0)
        )
    }

    // MARK: - UID root budget

    func testOversizedUIDRootFailsTypedBeforeRewriting() throws {
        var policy = DicomRewritePolicy.defaultAnonymization
        policy.uidRoot = "1.2.826.0.1.3680043.991" // 23 characters, one over budget
        let source = try Self.makeNativeFile(pixelBytes: Data([1, 0, 2, 0, 3, 0, 4, 0]))

        XCTAssertThrowsError(try DicomAnonymizer(policy: policy).rewrite(source)) { error in
            guard case DicomRewritePolicyError.uidRootTooLong(let root, let maximumLength) = error else {
                return XCTFail("expected uidRootTooLong, got \(error)")
            }
            XCTAssertEqual(root, policy.uidRoot)
            XCTAssertEqual(maximumLength, 22)
        }
    }

    func testMaximumLengthUIDRootProducesValidUIDs() throws {
        var policy = DicomRewritePolicy.defaultAnonymization
        policy.uidRoot = "1.2.826.0.1.3680043.99" // exactly the 22-character budget
        XCTAssertEqual(policy.uidRoot.count, DicomRewritePolicy.maximumUIDRootLength)

        let result = try DicomAnonymizer(policy: policy)
            .rewrite(Self.makeNativeFile(pixelBytes: Data([1, 0, 2, 0, 3, 0, 4, 0])))

        XCTAssertFalse(result.uidMap.isEmpty)
        for (original, remapped) in result.uidMap {
            XCTAssertLessThanOrEqual(remapped.count, 64,
                                     "remapped UID for \(original) must respect the DICOM 64-character maximum")
            XCTAssertTrue(remapped.hasPrefix(policy.uidRoot + "."))
        }
    }

    // MARK: - Default-policy re-identification vectors

    func testDefaultPolicyRemovesReidentificationVectorsAndRemapsReferenceSequences() throws {
        var dataSet = Self.makeNativeDataSet(pixelBytes: Data([1, 0, 2, 0, 3, 0, 4, 0]))
        dataSet.set(DicomDataElement(tag: DicomTag.studyID.rawValue, vr: .SH, value: .strings(["STUDY-42"])))
        dataSet.set(DicomDataElement(tag: 0x0008_1010, vr: .SH, value: .strings(["STATION-A"])))
        dataSet.set(DicomDataElement(tag: 0x0018_1000, vr: .LO, value: .strings(["SERIAL-123"])))
        dataSet.set(DicomDataElement(tag: 0x0040_1001, vr: .SH, value: .strings(["PROC-9"])))
        dataSet.set(DicomDataElement(
            tag: 0x0008_1110, vr: .SQ,
            value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: [
                DicomDataElement(tag: DicomTag.referencedSOPClassUID.rawValue, vr: .UI,
                                 value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
                DicomDataElement(tag: DicomTag.referencedSOPInstanceUID.rawValue, vr: .UI,
                                 value: .strings(["2.25.88880001"]))
            ]))])
        ))
        dataSet.set(DicomDataElement(
            tag: 0x0008_1115, vr: .SQ,
            value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: [
                DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI,
                                 value: .strings(["2.25.88880002"]))
            ]))])
        ))
        let source = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.12360001"
            )
        )

        let result = try DicomAnonymizer().rewrite(source)

        XCTAssertNil(result.dataSet.element(for: 0x0008_1010), "Station Name must be removed")
        XCTAssertNil(result.dataSet.element(for: 0x0018_1000), "Device Serial Number must be removed")
        XCTAssertNil(result.dataSet.element(for: 0x0040_1001), "Requested Procedure ID must be removed")
        let studyID = try XCTUnwrap(result.dataSet.element(for: DicomTag.studyID.rawValue),
                                    "Study ID is type 2 and must stay present")
        XCTAssertNotEqual(studyID.value, .strings(["STUDY-42"]), "Study ID must be blanked")

        let studyItems = result.dataSet.sequenceItems(for: 0x0008_1110)
        XCTAssertEqual(studyItems.count, 1, "Referenced Study Sequence is retained with remapped UIDs")
        let remappedStudyRef = try XCTUnwrap(studyItems.first?.dataSet.string(for: .referencedSOPInstanceUID))
        XCTAssertEqual(remappedStudyRef, result.uidMap["2.25.88880001"])
        XCTAssertNotEqual(remappedStudyRef, "2.25.88880001")

        let seriesItems = result.dataSet.sequenceItems(for: 0x0008_1115)
        XCTAssertEqual(seriesItems.count, 1, "Referenced Series Sequence is retained with remapped UIDs")
        let remappedSeriesRef = try XCTUnwrap(seriesItems.first?.dataSet.string(for: .seriesInstanceUID))
        XCTAssertEqual(remappedSeriesRef, result.uidMap["2.25.88880002"])
        XCTAssertNotEqual(remappedSeriesRef, "2.25.88880002")

        for leaked in ["STATION-A", "SERIAL-123", "PROC-9", "STUDY-42", "2.25.88880001", "2.25.88880002"] {
            XCTAssertNil(result.fileData.range(of: Data(leaked.utf8)),
                         "\(leaked) must not survive into the rewritten file")
        }
    }

    func testDefaultPolicyRemovesTemporalAttributesRecursivelyAndRecordsPS315Markers() throws {
        let nested = DicomDataSet(elements: [
            DicomDataElement(tag: 0x0008_002A, vr: .DT, value: .strings(["20260722121530-0300"])),
            DicomDataElement(tag: 0x0040_A121, vr: .DA, value: .strings(["20260722"])),
            DicomDataElement(tag: 0x0040_A122, vr: .TM, value: .strings(["121530"])),
            DicomDataElement(tag: 0x0040_A123, vr: .PN, value: .strings(["Reporter^Identity"])),
            DicomDataElement(tag: 0x0040_A160, vr: .UT, value: .strings(["Patient Jane Doe has findings"]))
        ])
        var dataSet = Self.makeNativeDataSet(pixelBytes: Data([1, 0, 2, 0, 3, 0, 4, 0]))
        dataSet.set(DicomDataElement(tag: DicomTag.studyDate.rawValue, vr: .DA, value: .strings(["20260722"])))
        dataSet.set(DicomDataElement(tag: DicomTag.studyTime.rawValue, vr: .TM, value: .strings(["121530"])))
        dataSet.set(DicomDataElement(tag: 0x0008_0201, vr: .SH, value: .strings(["-0300"])))
        dataSet.set(DicomDataElement(
            tag: 0x0040_A730,
            vr: .SQ,
            value: .sequence([DicomSequenceItem(dataSet: nested)])
        ))
        let result = try DicomAnonymizer().rewrite(Self.makeNativeFile(from: dataSet))

        XCTAssertNil(result.dataSet.element(for: DicomTag.studyDate.rawValue))
        XCTAssertNil(result.dataSet.element(for: DicomTag.studyTime.rawValue))
        XCTAssertNil(result.dataSet.element(for: 0x0008_0201), "Timezone Offset From UTC must be removed")
        let rewrittenNested = try XCTUnwrap(result.dataSet.sequenceItems(for: 0x0040_A730).first?.dataSet)
        XCTAssertNil(rewrittenNested.element(for: 0x0008_002A))
        XCTAssertNil(rewrittenNested.element(for: 0x0040_A121))
        XCTAssertNil(rewrittenNested.element(for: 0x0040_A122))
        XCTAssertNil(rewrittenNested.element(for: 0x0040_A123))
        XCTAssertEqual(rewrittenNested.string(for: 0x0040_A160), "REDACTED")
        XCTAssertEqual(result.dataSet.string(for: 0x0012_0062), "YES")
        XCTAssertEqual(result.dataSet.string(for: 0x0028_0303), "REMOVED")
        XCTAssertTrue(result.dataSet.element(for: 0x0012_0063)?.stringValues.contains {
            $0.contains("PS3.15 Basic Confidentiality baseline")
        } == true)
    }

    func testDefaultPolicyRemapsPS315UIDChainsAndHonorsCatalogUIDReplacements() throws {
        let originalSOPInstanceUID = "2.25.12360001"
        let originalStudyUID = "2.25.12360002"
        let originalSeriesUID = "2.25.12360003"
        let originalTrackingUID = "2.25.12360004"
        var dataSet = Self.makeNativeDataSet(pixelBytes: Data([1, 0, 2, 0, 3, 0, 4, 0]))
        dataSet.set(DicomDataElement(tag: 0x0008_0017, vr: .UI, value: .strings([originalTrackingUID])))
        dataSet.set(DicomDataElement(
            tag: 0x0008_1115,
            vr: .SQ,
            value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: [
                DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI,
                                 value: .strings([originalSeriesUID])),
                DicomDataElement(tag: 0x0062_0021, vr: .UI, value: .strings([originalTrackingUID])),
                DicomDataElement(tag: DicomTag.referencedSOPInstanceUID.rawValue, vr: .UI,
                                 value: .strings([originalSOPInstanceUID]))
            ]))])
        ))
        var policy = DicomRewritePolicy.defaultAnonymization
        policy.uidReplacementsByTag = [
            DicomTag.studyInstanceUID.rawValue: "2.25.9001",
            DicomTag.seriesInstanceUID.rawValue: "2.25.9002",
            DicomTag.sopInstanceUID.rawValue: "2.25.9003"
        ]

        let result = try DicomAnonymizer(policy: policy).rewrite(Self.makeNativeFile(from: dataSet))

        XCTAssertEqual(result.dataSet.string(for: .studyInstanceUID), "2.25.9001")
        XCTAssertEqual(result.dataSet.string(for: .seriesInstanceUID), "2.25.9002")
        XCTAssertEqual(result.dataSet.string(for: .sopInstanceUID), "2.25.9003")
        let rewrittenNested = try XCTUnwrap(result.dataSet.sequenceItems(for: 0x0008_1115).first?.dataSet)
        XCTAssertEqual(rewrittenNested.string(for: .seriesInstanceUID), "2.25.9002")
        XCTAssertEqual(rewrittenNested.string(for: .referencedSOPInstanceUID), "2.25.9003")
        let remappedTrackingUID = try XCTUnwrap(result.uidMap[originalTrackingUID])
        XCTAssertNotEqual(remappedTrackingUID, originalTrackingUID)
        XCTAssertEqual(result.dataSet.string(for: 0x0008_0017), remappedTrackingUID)
        XCTAssertEqual(rewrittenNested.string(for: 0x0062_0021), remappedTrackingUID)
        XCTAssertEqual(result.uidMap[originalStudyUID], "2.25.9001")
    }

    func testPixelRiskWarningsReflectBurnedInAnnotation() throws {
        var declared = Self.makeNativeDataSet(pixelBytes: Data([1, 0, 2, 0, 3, 0, 4, 0]))
        declared.set(DicomDataElement(tag: 0x0028_0301, vr: .CS, value: .strings(["YES"])))
        let declaredResult = try DicomAnonymizer().rewrite(Self.makeNativeFile(from: declared))
        XCTAssertEqual(declaredResult.warnings, [.burnedInAnnotationPresent])

        let unknownResult = try DicomAnonymizer().rewrite(
            Self.makeNativeFile(pixelBytes: Data([1, 0, 2, 0, 3, 0, 4, 0]))
        )
        XCTAssertEqual(unknownResult.warnings, [.burnedInAnnotationUnknown])

        var absent = Self.makeNativeDataSet(pixelBytes: Data([1, 0, 2, 0, 3, 0, 4, 0]))
        absent.set(DicomDataElement(tag: 0x0028_0301, vr: .CS, value: .strings(["NO"])))
        let absentResult = try DicomAnonymizer().rewrite(Self.makeNativeFile(from: absent))
        XCTAssertTrue(absentResult.warnings.isEmpty)
    }

    // MARK: - Private tags, blocked fields, invalid inputs

    func testPrivateTagPolicyRemovesOrKeepsCreatorsAndElements() throws {
        var dataSet = Self.makeNativeDataSet(pixelBytes: Data([1, 0, 2, 0, 3, 0, 4, 0]))
        dataSet.set(DicomDataElement(tag: 0x0009_0010, vr: .LO, value: .strings(["CREATOR A"])))
        dataSet.set(DicomDataElement(tag: 0x0009_1001, vr: .LO, value: .strings(["private-value"])))
        let source = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.12360001"
            )
        )

        let removed = try DicomAnonymizer().rewrite(source)
        XCTAssertNil(removed.dataSet.element(for: 0x0009_0010))
        XCTAssertNil(removed.dataSet.element(for: 0x0009_1001))
        XCTAssertTrue(removed.audit.contains {
            $0.tag == 0x0009_1001 && $0.disposition == .removed && $0.note == "private element"
        })

        var keepPolicy = DicomRewritePolicy.defaultAnonymization
        keepPolicy.removePrivateTags = false
        let kept = try DicomAnonymizer(policy: keepPolicy).rewrite(source)
        XCTAssertEqual(kept.dataSet.string(for: 0x0009_0010), "CREATOR A")
        XCTAssertEqual(kept.dataSet.string(for: 0x0009_1001), "private-value")
    }

    func testOverlayPlanePolicyRemovesAllRepeatingGroupElementsByDefault() throws {
        var dataSet = Self.makeNativeDataSet(pixelBytes: Data([1, 0, 2, 0, 3, 0, 4, 0]))
        dataSet.set(DicomDataElement(tag: 0x6000_0010, vr: .US, value: .unsignedIntegers([2])))
        dataSet.set(DicomDataElement(tag: 0x6000_0011, vr: .US, value: .unsignedIntegers([2])))
        dataSet.set(DicomDataElement(tag: 0x6000_3000, vr: .OW, value: .bytes(Data([0x0F, 0x00]))))
        dataSet.set(DicomDataElement(tag: 0x601E_3000, vr: .OW, value: .bytes(Data([0x01, 0x00]))))
        let source = try Self.makeNativeFile(from: dataSet)

        let removed = try DicomAnonymizer().rewrite(source)

        XCTAssertNil(removed.dataSet.element(for: 0x6000_0010))
        XCTAssertNil(removed.dataSet.element(for: 0x6000_0011))
        XCTAssertNil(removed.dataSet.element(for: 0x6000_3000))
        XCTAssertNil(removed.dataSet.element(for: 0x601E_3000))
        XCTAssertTrue(removed.audit.contains {
            $0.tag == 0x6000_3000 && $0.disposition == .removed && $0.note == "overlay plane element"
        })

        var keepPolicy = DicomRewritePolicy.defaultAnonymization
        keepPolicy.removeOverlayPlanes = false
        let kept = try DicomAnonymizer(policy: keepPolicy).rewrite(source)
        XCTAssertNotNil(kept.dataSet.element(for: 0x6000_3000))
        XCTAssertNotNil(kept.dataSet.element(for: 0x601E_3000))
    }

    func testStructuralTagsAreBlockedFromPolicyActions() throws {
        var policy = DicomRewritePolicy.defaultAnonymization
        policy.actions[DicomTag.rows.rawValue] = .remove
        let result = try DicomAnonymizer(policy: policy)
            .rewrite(Self.makeNativeFile(pixelBytes: Data([1, 0, 2, 0, 3, 0, 4, 0])))

        XCTAssertNotNil(result.dataSet.element(for: .rows), "structural elements must survive")
        XCTAssertTrue(result.audit.contains {
            $0.tag == DicomTag.rows.rawValue && $0.disposition == .blocked
        })
    }

    func testInvalidInputFailsTyped() {
        XCTAssertThrowsError(try DicomAnonymizer().rewrite(Data([0x00, 0x01, 0x02, 0x03]))) { error in
            guard error is DICOMError else {
                return XCTFail("expected a typed DICOMError, got \(error)")
            }
        }
    }

    // MARK: - Builders

    private static func makeNativeDataSet(pixelBytes: Data) -> DicomDataSet {
        DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI,
                             value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.12360001"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.12360002"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.12360003"])),
            DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["PHI^PATIENT"])),
            DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings(["PHI-123"])),
            DicomDataElement(tag: 0x0010_0030, vr: .DA, value: .strings(["19700101"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["MONOCHROME2"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([2])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([2])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([16])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([16])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([15])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(pixelBytes))
        ])
    }

    private static func makeNativeFile(pixelBytes: Data) throws -> Data {
        try makeNativeFile(from: makeNativeDataSet(pixelBytes: pixelBytes))
    }

    private static func makeNativeFile(from dataSet: DicomDataSet) throws -> Data {
        try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.12360001"
            )
        )
    }

    private static func open(_ data: Data) throws -> DCMDecoder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anonymizer_test_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }
}
