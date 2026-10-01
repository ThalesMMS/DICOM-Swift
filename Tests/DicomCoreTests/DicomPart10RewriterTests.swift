import Foundation
import XCTest
@testable import DicomCore

final class DicomPart10RewriterTests: XCTestCase {
    func test_metadataRewrite_preservesNativePixelBytesAndIdentityAcrossTransferSyntaxes() throws {
        let pixels = Data([1, 0, 2, 0, 3, 0, 4, 0])
        let sourceDataSet = Self.nativeDataSet(pixelBytes: pixels)
        let comment = "  linha 1\nRenée\\B"
        let commentTag = 0x0032_4000

        for transferSyntax in [
            DicomTransferSyntax.explicitVRLittleEndian,
            .implicitVRLittleEndian,
            .explicitVRBigEndian,
            .deflatedExplicitVRLittleEndian
        ] {
            let source = try Self.part10Data(from: sourceDataSet, transferSyntax: transferSyntax)
            let sourceDecoder = try DCMDecoder(data: source)
            let sourcePixelBytes = try XCTUnwrap(
                DicomPart10PixelDataPreserver.dataSet(from: sourceDecoder)
                    .element(for: .pixelData)?.bytesValue
            )

            let result = try DicomPart10Rewriter().rewrite(
                source,
                replacing: [DicomDataElement(tag: commentTag, vr: .LT, value: .strings([comment]))]
            )
            let reopened = try DCMDecoder(data: result.fileData)
            let reopenedPixelBytes = try XCTUnwrap(
                DicomPart10PixelDataPreserver.dataSet(from: reopened)
                    .element(for: .pixelData)?.bytesValue
            )

            XCTAssertEqual(result.transferSyntax, transferSyntax)
            XCTAssertEqual(reopened.info(for: .transferSyntaxUID), transferSyntax.rawValue)
            XCTAssertEqual(reopened.dataSet.string(for: .studyInstanceUID), "2.25.21120002")
            XCTAssertEqual(reopened.dataSet.string(for: .seriesInstanceUID), "2.25.21120003")
            XCTAssertEqual(reopened.dataSet.string(for: .sopInstanceUID), "2.25.21120001")
            XCTAssertEqual(reopened.dataSet.string(for: .sopClassUID), Self.sopClassUID)
            XCTAssertEqual(reopened.dataSet.element(for: commentTag)?.vr, .LT)
            XCTAssertEqual(reopened.dataSet.string(for: commentTag), comment)
            XCTAssertNil(reopened.dataSet.element(for: 0x0032_0000))
            XCTAssertEqual(reopenedPixelBytes, sourcePixelBytes)
        }
    }

    func test_dataSliceInput_preservesNativePixelBytes() throws {
        let pixels = Data([1, 0, 2, 0, 3, 0, 4, 0])
        let source = try Self.part10Data(
            from: Self.nativeDataSet(pixelBytes: pixels),
            transferSyntax: .explicitVRLittleEndian
        )
        var storage = Data([0xFF])
        storage.append(source)
        let slicedSource = storage.dropFirst()
        XCTAssertGreaterThan(slicedSource.startIndex, 0)

        let result = try DicomPart10Rewriter().rewrite(
            slicedSource,
            replacing: [DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings(["SLICE"]))]
        )
        let reopened = try DCMDecoder(data: result.fileData)

        XCTAssertEqual(reopened.dataSet.string(for: .patientID), "SLICE")
        XCTAssertEqual(
            try DicomPart10PixelDataPreserver.dataSet(from: reopened).element(for: .pixelData)?.bytesValue,
            pixels
        )
    }

    func test_UIDRewrite_replacesOnlyMappedValuesRecursivelyAndPreservesFileMeta() throws {
        let oldSOPUID = "2.25.21120001"
        let newSOPUID = "2.25.21129991"
        let externalUID = "2.25.21129992"
        var dataSet = Self.nativeDataSet(pixelBytes: Data([1, 0, 2, 0, 3, 0, 4, 0]))
        dataSet.set(DicomDataElement(
            tag: 0x0008_1140,
            vr: .SQ,
            value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: [
                DicomDataElement(
                    tag: DicomTag.referencedSOPInstanceUID.rawValue,
                    vr: .UI,
                    value: .strings([oldSOPUID, externalUID, oldSOPUID])
                )
            ]))])
        ))
        let source = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .explicitVRLittleEndian,
                mediaStorageSOPClassUID: Self.sopClassUID,
                mediaStorageSOPInstanceUID: oldSOPUID,
                implementationClassUID: "2.25.2112000099",
                implementationVersionName: "PART10_TEST_1"
            )
        )

        let result = try DicomPart10Rewriter().rewrite(
            source,
            uidValueReplacements: [oldSOPUID: newSOPUID]
        )
        let reopened = try DCMDecoder(data: result.fileData)
        let nestedUIDs = try XCTUnwrap(
            reopened.dataSet.sequenceItems(for: 0x0008_1140).first?.dataSet
                .element(for: .referencedSOPInstanceUID)?.stringValues
        )

        XCTAssertEqual(reopened.dataSet.string(for: .sopInstanceUID), newSOPUID)
        XCTAssertEqual(nestedUIDs, [newSOPUID, externalUID, newSOPUID])
        XCTAssertEqual(reopened.dataSet.string(for: 0x0062_0021), "2.25.21120004")
        XCTAssertEqual(reopened.info(for: .sopClassUID), Self.sopClassUID)
        XCTAssertEqual(reopened.info(for: 0x0002_0012), "2.25.2112000099")
        XCTAssertEqual(reopened.info(for: 0x0002_0013), "PART10_TEST_1")
    }

    func test_UIDRewrite_acceptsIdentityMappingsAndUIDSwaps() throws {
        let sopUID = "2.25.21120001"
        let studyUID = "2.25.21120002"
        let seriesUID = "2.25.21120003"
        let source = try Self.part10Data(
            from: Self.nativeDataSet(pixelBytes: Data([1, 0, 2, 0, 3, 0, 4, 0])),
            transferSyntax: .explicitVRLittleEndian
        )

        let result = try DicomPart10Rewriter().rewrite(
            source,
            uidValueReplacements: [
                sopUID: studyUID,
                studyUID: sopUID,
                seriesUID: seriesUID
            ]
        )

        XCTAssertEqual(result.dataSet.string(for: .sopInstanceUID), studyUID)
        XCTAssertEqual(result.dataSet.string(for: .studyInstanceUID), sopUID)
        XCTAssertEqual(result.dataSet.string(for: .seriesInstanceUID), seriesUID)
    }

    func test_metadataRewrite_preservesEntireUndefinedLengthPixelValueRegion() throws {
        let source = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpegLosslessFirstOrder,
            fragments: [Data([1, 2, 3, 4]), Data([5, 6]), Data([7, 8, 9, 10])],
            declaredFrames: 2,
            extendedOffsetTableFrameStartFragmentIndexes: [0, 2]
        )
        let sourceDecoder = try DCMDecoder(data: source)
        let sourceRegion = try XCTUnwrap(
            DicomPart10PixelDataPreserver.rawEncapsulatedPixelDataRegion(from: sourceDecoder)
        )

        let result = try DicomPart10Rewriter().rewrite(
            source,
            replacing: [DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO,
                                         value: .strings(["REWRITTEN"]))]
        )
        let reopened = try DCMDecoder(data: result.fileData)
        let rewrittenRegion = try XCTUnwrap(
            DicomPart10PixelDataPreserver.rawEncapsulatedPixelDataRegion(from: reopened)
        )

        XCTAssertEqual(reopened.info(for: .transferSyntaxUID), DicomTransferSyntax.jpegLosslessFirstOrder.rawValue)
        XCTAssertEqual(rewrittenRegion, sourceRegion)
    }

    func test_metadataRewrite_rejectsMissingEncapsulatedSequenceDelimiter() throws {
        var source = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpegLosslessFirstOrder,
            fragments: [Data([1, 2, 3, 4])],
            declaredFrames: 1
        )
        let decoder = try DCMDecoder(data: source)
        let region = try XCTUnwrap(
            DicomPart10PixelDataPreserver.rawEncapsulatedPixelDataRegion(from: decoder)
        )
        let delimiterOffset = decoder.offset + region.count - 8
        source[delimiterOffset] = 0

        XCTAssertThrowsError(try DicomPart10Rewriter().rewrite(source)) { error in
            XCTAssertEqual(error as? DicomPart10RewriteError, .pixelDataUnavailable)
        }
    }

    func test_metadataRewrite_supportsObjectsWithoutPixelData() throws {
        let source = try DicomEncapsulatedDocumentBuilder.part10Data(
            documentData: Data("%PDF-1.4\n".utf8),
            options: DicomEncapsulatedDocumentBuildOptions(
                kind: .pdf,
                sopInstanceUID: "2.25.21120001",
                studyInstanceUID: "2.25.21120002",
                seriesInstanceUID: "2.25.21120003",
                patientID: "BEFORE"
            )
        )

        let result = try DicomPart10Rewriter().rewrite(
            source,
            replacing: [DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO,
                                         value: .strings(["AFTER"]))]
        )

        XCTAssertEqual(result.dataSet.string(for: .patientID), "AFTER")
        XCTAssertNil(result.dataSet.element(for: .pixelData))
    }

    func test_metadataRewrite_rejectsUnsafeStructuralEdits() throws {
        let source = try Self.part10Data(
            from: Self.nativeDataSet(pixelBytes: Data([1, 0, 2, 0, 3, 0, 4, 0])),
            transferSyntax: .explicitVRLittleEndian
        )

        XCTAssertThrowsError(try DicomPart10Rewriter().rewrite(
            source,
            replacing: [DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([1]))]
        )) { error in
            XCTAssertEqual(
                error as? DicomPart10RewriteError,
                .disallowedElement(tag: DicomTag.rows.rawValue)
            )
        }
    }

    func test_metadataRewrite_rejectsUnknownTransferSyntaxWithoutFallback() throws {
        var source = try Self.part10Data(
            from: Self.nativeDataSet(pixelBytes: Data([1, 0, 2, 0, 3, 0, 4, 0])),
            transferSyntax: .explicitVRLittleEndian
        )
        let known = Data(DicomTransferSyntax.explicitVRLittleEndian.rawValue.utf8)
        let unknownUID = "9.9.999999999999999"
        let unknown = Data(unknownUID.utf8)
        let range = try XCTUnwrap(source.range(of: known))
        source.replaceSubrange(range, with: unknown)

        XCTAssertThrowsError(try DicomPart10Rewriter().rewrite(source)) { error in
            XCTAssertEqual(error as? DicomPart10RewriteError, .unsupportedTransferSyntax(unknownUID))
        }
    }

    func test_metadataRewrite_rejectsValueChangedByPaddingNormalization() throws {
        let source = try Self.part10Data(
            from: Self.nativeDataSet(pixelBytes: Data([1, 0, 2, 0, 3, 0, 4, 0])),
            transferSyntax: .explicitVRLittleEndian
        )
        let tag = 0x0032_4000

        XCTAssertThrowsError(try DicomPart10Rewriter().rewrite(
            source,
            replacing: [DicomDataElement(tag: tag, vr: .LT, value: .strings(["A "]))]
        )) { error in
            XCTAssertEqual(error as? DicomPart10RewriteError, .editRoundTripFailed(tag: tag))
        }
    }

    private static let sopClassUID = DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID

    private static func nativeDataSet(pixelBytes: Data) -> DicomDataSet {
        DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings([sopClassUID])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI,
                             value: .strings(["2.25.21120001"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI,
                             value: .strings(["2.25.21120002"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI,
                             value: .strings(["2.25.21120003"])),
            DicomDataElement(tag: 0x0062_0021, vr: .UI, value: .strings(["2.25.21120004"])),
            DicomDataElement(tag: 0x0032_0000, vr: .UL, value: .unsignedIntegers([4])),
            DicomDataElement(tag: DicomTag.specificCharacterSet.rawValue, vr: .CS,
                             value: .strings(["ISO_IR 192"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([2])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([2])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS,
                             value: .strings(["MONOCHROME2"])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([16])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([16])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([15])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US,
                             value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(pixelBytes))
        ])
    }

    private static func part10Data(
        from dataSet: DicomDataSet,
        transferSyntax: DicomTransferSyntax
    ) throws -> Data {
        try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: transferSyntax,
                mediaStorageSOPClassUID: sopClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
    }
}
