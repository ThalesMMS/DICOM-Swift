import Foundation
import XCTest
@testable import DicomData

final class DicomEncodedDataSetValidatorTests: XCTestCase {
    func test_completeMetadata_composesWithAttributesWithoutQualifyingOtherLayers() throws {
        let dataSet = DicomDataSet(elements: [text(0x00100010, "SYNTHETIC^VALID", .PN)])
        for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .explicitVRBigEndian,
                       .implicitVRLittleEndian, .deflatedExplicitVRLittleEndian] {
            let wire = try DicomDataSetWriter.dataSetData(from: dataSet, transferSyntax: syntax)
            let result = try DicomEncodedDataSetValidator.validate(wire, transferSyntax: syntax)
            XCTAssertEqual(result.dataSet, dataSet)
            XCTAssertEqual(result.purpose, .instance)
            XCTAssertEqual(result.report[.structure], .passed)
            XCTAssertEqual(result.report[.vrAndVM], .passed)
            XCTAssertEqual(result.report[.attributes], .notEvaluated)
            let attributes = DicomAttributeValidator.validate(try XCTUnwrap(result.dataSet),
                rules: [.init(tag: 0x00100010, requirement: .type2)])
            let composed = result.report.merging(attributes)
            XCTAssertEqual(composed.outcome(requiring: [.structure, .vrAndVM, .attributes]), .passed)
            XCTAssertEqual(composed.outcome(requiring: Set(DicomValidationReport.Layer.allCases)), .incomplete)
        }
    }

    func test_fatalFraming_preservesEarlierLexicalErrorsAndDoesNotReturnPartialMetadata() throws {
        var wire = try DicomDataSetWriter.dataSetData(from: .init(elements: [text(0x00080060, "bad!", .CS)]))
        wire.append(0)
        let result = try DicomEncodedDataSetValidator.validate(wire)
        XCTAssertNil(result.dataSet)
        XCTAssertEqual(result.report[.structure], .failed)
        XCTAssertEqual(result.report[.vrAndVM], .failed)
        XCTAssertTrue(result.report.diagnostics.contains { $0.code == .invalidTextValue && $0.path == [.tag(0x00080060)] })
        XCTAssertTrue(result.report.diagnostics.contains { $0.code == .invalidDataSetStructure })
        let report = String(decoding: try JSONEncoder().encode(result.report.diagnostics), as: UTF8.self)
        XCTAssertFalse(report.contains("bad!"))
    }

    func test_resourceAndDiagnosticLimits_preserveFailuresAndStayBounded() throws {
        let wire = try DicomDataSetWriter.dataSetData(from: .init(elements: [
            text(0x00080008, "bad!", .CS), text(0x00080060, "also bad!", .CS)
        ]))
        let result = try DicomEncodedDataSetValidator.validate(wire,
            limits: .init(maximumSequenceDepth: 1, maximumElementCount: 1, maximumItemCount: 1))
        XCTAssertNil(result.dataSet)
        XCTAssertEqual(result.report[.structure], .incomplete)
        XCTAssertEqual(result.report[.vrAndVM], .failed)
        let budget = try DicomEncodedDataSetValidator.validate(wire, maximumDiagnostics: 1)
        XCTAssertNil(budget.dataSet)
        XCTAssertEqual(budget.report[.vrAndVM], .failed)
        XCTAssertLessThanOrEqual(budget.report.diagnostics.count, 3)
        XCTAssertTrue(budget.report.diagnostics.contains { $0.code == .validationInterrupted })
    }

    func test_unknownContextAndOpaqueValues_remainIncomplete() throws {
        let ambiguous = try DicomDataSetWriter.dataSetData(from: .init(elements: [
            .init(tag: 0x00280120, vr: .US, value: .unsignedIntegers([7]))
        ]), transferSyntax: .implicitVRLittleEndian)
        let result = try DicomEncodedDataSetValidator.validate(ambiguous, transferSyntax: .implicitVRLittleEndian)
        XCTAssertNotNil(result.dataSet)
        XCTAssertEqual(result.report[.structure], .passed)
        XCTAssertEqual(result.report[.vrAndVM], .incomplete)
        XCTAssertTrue(result.report.diagnostics.contains { $0.code == .ambiguousVR && $0.severity == .limitation })
        let opaque = try DicomDataSetWriter.dataSetData(from: .init(elements: [
            .init(tag: 0x00291001, vr: .UN, value: .bytes(Data([1, 2])))
        ]))
        let unknown = try DicomEncodedDataSetValidator.validate(opaque)
        XCTAssertEqual(unknown.report[.vrAndVM], .incomplete)
        XCTAssertEqual(unknown.report.diagnostics.first?.path, [.tag(0x00291001)])
    }

    func test_omittedPixels_keepNestedPathsAndDoNotPassUnevaluatedValueChecks() throws {
        let item = DicomDataSet(elements: [.init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data([1, 2])))])
        let wire = try DicomDataSetWriter.dataSetData(from: .init(elements: [
            .init(tag: 0x0040A730, vr: .SQ, value: .sequence([.init(dataSet: item)]))
        ]))
        let result = try DicomEncodedDataSetValidator.validate(wire)
        XCTAssertEqual(result.report[.vrAndVM], .incomplete)
        XCTAssertEqual(result.report[.pixelsAndGeometry], .notEvaluated)
        XCTAssertTrue(result.report.diagnostics.contains { $0.code == .valueUnavailable
            && $0.path == [.tag(0x0040A730), .item(0), .tag(0x7FE00010)] })
        XCTAssertFalse(try XCTUnwrap(result.dataSet).sequenceItems(for: 0x0040A730)[0].dataSet.contains(0x7FE00010))
    }

    func test_duplicateTagsAndInvalidDeflate_reportFailuresWithoutCopyingErrorText() throws {
        let element = try DicomDataSetWriter.dataSetData(from: .init(elements: [text(0x00100010, "SYNTHETIC", .PN)]))
        let duplicate = try DicomEncodedDataSetValidator.validate(element + element)
        XCTAssertEqual(duplicate.report[.structure], .failed)
        XCTAssertNil(duplicate.dataSet)
        XCTAssertEqual(duplicate.report.diagnostics.first?.path, [.tag(0x00100010)])
        let deflate = try DicomEncodedDataSetValidator.validate(Data([0xFF, 0xFF, 0xFF]),
            transferSyntax: .deflatedExplicitVRLittleEndian)
        XCTAssertEqual(deflate.report[.structure], .failed)
        XCTAssertTrue(deflate.report.diagnostics.contains { $0.code == .invalidDeflatedDataSet })
    }

    func test_cancellation_propagatesInsteadOfBecomingAFileValidationFailure() async throws {
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try DicomEncodedDataSetValidator.validate(Data())
                return false
            } catch is CancellationError { return true }
        }
        let cancelled = try await work.value
        XCTAssertTrue(cancelled)
    }

    func test_unsupportedCharsetAndQueryPurpose_doNotBecomeInstanceConformance() throws {
        // The writer correctly refuses an unsupported encoding declaration; inject it on the wire.
        var unsupported = Data([8, 0, 5, 0, 0x43, 0x53, 12, 0])
        unsupported.append(Data("ISO_IR 9999 ".utf8))
        unsupported.append(try DicomDataSetWriter.dataSetData(from: .init(elements: [text(0x00100010, "SYNTHETIC", .PN)])))
        let result = try DicomEncodedDataSetValidator.validate(unsupported)
        XCTAssertEqual(result.report[.vrAndVM], .incomplete)
        XCTAssertTrue(result.report.diagnostics.contains { $0.code == .unsupportedCharacterSet && $0.severity == .limitation })
        let query = try DicomDataSetWriter.dataSetData(from: .init(elements: [text(0x00080020, "20260101-20261231", .DA)]))
        let queryResult = try DicomEncodedDataSetValidator.validate(query, purpose: .query)
        XCTAssertEqual(queryResult.purpose, .query)
        XCTAssertEqual(queryResult.report[.vrAndVM], .passed)
        XCTAssertEqual(try DicomEncodedDataSetValidator.validate(query).report[.vrAndVM], .failed)
    }

    func test_manyOmittedValues_stopDiagnosticsWithoutClaimingCompleteValidation() throws {
        let item = DicomDataSet(elements: [.init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data([1, 2])))])
        let wire = try DicomDataSetWriter.dataSetData(from: .init(elements: [
            .init(tag: 0x0040A730, vr: .SQ, value: .sequence(Array(repeating: .init(dataSet: item), count: 3)))
        ]))
        let result = try DicomEncodedDataSetValidator.validate(wire, maximumDiagnostics: 1)
        XCTAssertNotNil(result.dataSet)
        XCTAssertEqual(result.report[.vrAndVM], .incomplete)
        XCTAssertEqual(result.report.diagnostics.count, 2)
        XCTAssertEqual(result.report.diagnostics.last?.code, .evaluationLimitReached)
    }

    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings([value]))
    }
}
