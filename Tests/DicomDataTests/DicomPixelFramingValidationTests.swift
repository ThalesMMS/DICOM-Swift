import Foundation
import XCTest
@testable import DicomData

final class DicomPixelFramingValidationTests: XCTestCase {
    func test_encapsulatedPixels_shareTheItemBudgetWithSequenceItems() throws {
        let prefix = try DicomDataSetWriter.dataSetData(from: .init(elements: [
            .init(tag: 0x00081115, vr: .SQ, value: .sequence([.init(dataSet: .init())]))
        ]))
        let wire = prefix + encapsulatedPixels()
        let exact = DicomDataSetParseLimits(maximumSequenceDepth: 1, maximumElementCount: 10, maximumItemCount: 3)
        XCTAssertNoThrow(try DicomDataSetParser.read(from: wire, transferSyntax: .rleLossless, limits: exact))
        let limited = DicomDataSetParseLimits(maximumSequenceDepth: 1, maximumElementCount: 10, maximumItemCount: 2)
        for mode in [DicomDataSetReadMode.strict, .recover] {
            XCTAssertThrowsError(try DicomDataSetParser.read(from: wire, transferSyntax: .rleLossless,
                                                            mode: mode, limits: limited)) {
                XCTAssertEqual($0 as? DicomDataSetParseError, .maximumItemCountExceeded(limit: 2))
            }
        }
        XCTAssertThrowsError(try DicomDataSetParser.dataSet(from: wire, transferSyntax: .rleLossless, limits: limited)) {
            XCTAssertEqual($0 as? DicomDataSetParseError, .maximumItemCountExceeded(limit: 2))
        }
    }

    func test_skippedPixelVR_isValidatedAndRecoveryRetainsFollowingMetadata() throws {
        let invalid = DicomDataElement(tag: 0x7FE00010, vr: .LO, value: .strings(["XX"]))
        let following = DicomDataElement(tag: 0xFFFCFFFC, vr: .OB, value: .bytes(Data([1, 2])))
        let wire = try DicomDataSetWriter.dataSetData(from: .init(elements: [invalid, following]))
        XCTAssertThrowsError(try DicomDataSetParser.read(from: wire)) {
            let diagnostic = $0 as? DicomDataSetReadResult.Diagnostic
            XCTAssertEqual(diagnostic?.reason, .incompatibleVR)
            XCTAssertEqual(diagnostic?.path, [.tag(0x7FE00010)])
        }
        let result = try DicomDataSetParser.read(from: wire, mode: .recover)
        XCTAssertEqual(result.diagnostics.map(\.reason), [.incompatibleVR])
        XCTAssertEqual(result.dataSet[0xFFFCFFFC], following)
        XCTAssertFalse(result.dataSet.contains(0x7FE00010))
    }

    func test_boundedSource_validatesTheSkippedPixelHeaderWithoutReadingItsValue() async throws {
        let dataSet = DicomDataSet(elements: [
            .init(tag: 0x7FE00010, vr: .LO, value: .strings(["SYNTHETIC PIXEL VALUE"]))
        ])
        let bytes = try DicomDataSetWriter.part10Data(from: dataSet)
        do {
            _ = try await DicomSourceMetadata.readPart10(from: DicomByteSource(data: bytes), mode: .strict)
            XCTFail("Invalid skipped pixel VR accepted")
        } catch {
            XCTAssertEqual((error as? DicomDataSetReadResult.Diagnostic)?.reason, .incompatibleVR)
        }
        let source = DicomByteSource(data: bytes)
        let recovered = try await DicomSourceMetadata.readPart10(from: source, mode: .recover)
        XCTAssertEqual(recovered.dataSetDiagnostics.map(\.reason), [.incompatibleVR])
        XCTAssertEqual(recovered.dataSetDiagnostics.first?.path, [.tag(0x7FE00010)])
        let pixelRange = try XCTUnwrap(recovered.pixelDataRange)
        let metrics = await source.metrics
        XCTAssertFalse(metrics.ranges.contains { $0.overlaps(pixelRange) })
        XCTAssertFalse(recovered.dataSet.contains(0x7FE00010))
    }

    func test_validatedSources_preserveNativeAndEncapsulatedFramingWithoutPayloadReads() async throws {
        for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .explicitVRBigEndian,
                       .implicitVRLittleEndian, .rleLossless] {
            let wire: Data
            if syntax == .rleLossless {
                wire = encapsulatedPixels()
            } else {
                wire = try DicomDataSetWriter.dataSetData(from: .init(elements: [
                    .init(tag: 0x00280100, vr: .US, value: .unsignedIntegers([16])),
                    .init(tag: 0x7FE00010, vr: .OW, value: .bytes(Data([0, 1, 0, 2])))
                ]), transferSyntax: syntax)
            }
            let bytes = try DicomDataSetWriter.part10Data(fromEncodedDataSet: wire, transferSyntax: syntax,
                mediaStorageSOPClassUID: "1.2.840.10008.5.1.4.1.1.7", mediaStorageSOPInstanceUID: "2.25.23210010")
            let source = DicomByteSource(data: bytes)
            let result = try await DicomSourceMetadata.readPart10(from: source, mode: .strict)
            XCTAssertTrue(result.dataSetDiagnostics.isEmpty)
            XCTAssertEqual(result.transferSyntax, syntax)
            XCTAssertFalse(result.dataSet.contains(0x7FE00010))
            let pixelRange = try XCTUnwrap(result.pixelDataRange)
            let payload = syntax == .rleLossless ? (pixelRange.lowerBound + 16)..<(pixelRange.lowerBound + 18) : pixelRange
            let metrics = await source.metrics
            XCTAssertFalse(metrics.ranges.contains { $0.overlaps(payload) })
            XCTAssertEqual(result.dataSet, try DicomDataSetParser.read(from: wire, transferSyntax: syntax).dataSet)
        }
    }

    private func encapsulatedPixels() -> Data {
        // Framing-only fixture: BOT and one fragment, without claiming a valid RLE codestream.
        Data([0xE0, 0x7F, 0x10, 0, 0x4F, 0x42, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF,
              0xFE, 0xFF, 0, 0xE0, 0, 0, 0, 0,
              0xFE, 0xFF, 0, 0xE0, 2, 0, 0, 0, 0, 0,
              0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0])
    }
}
