import Foundation
import XCTest
@testable import DicomCore

final class DicomInstanceValidatorTests: XCTestCase {
    func test_wholeObjectBudgets_stopBeforeFrameScaledValidation() throws {
        let data = try fixture(count: "1025")
        for limits in [DicomInstanceValidator.Limits(maximumObjectBytes: data.count - 1),
                       .init(maximumObjectFrames: 1024)] {
            let report = try DicomInstanceValidator.validate(data, limits: limits)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .evaluationLimitReached })
            XCTAssertEqual(report[.attributes], .incomplete)
            XCTAssertEqual(report[.references], .incomplete)
            XCTAssertEqual(report[.codestream], .incomplete)
        }

        let dataSet = DicomDataSet(elements: [text(0x00080016, "2.25.2536", .UI),
            text(0x00080018, "2.25.2536.1", .UI), text(0x00280008, "1", .IS),
            .init(tag: 0x52009230, vr: .SQ, value: .sequence([.init(dataSet: .init()), .init(dataSet: .init())]))])
        let undeclaredFrames = try DicomDataSetWriter.part10Data(from: dataSet)
        let report = try DicomInstanceValidator.validate(undeclaredFrames, limits: .init(maximumObjectFrames: 1))
        XCTAssertTrue(report.diagnostics.contains { $0.code == .evaluationLimitReached },
                      "a false Number of Frames must not bypass the functional-group work limit")
    }

    func test_videoBudget_countsAllFragmentsAndAllowsExactStreamLimit() throws {
        let stream = try DicomVideoStreamInspectorTests.fixture("known-pframes.h264")
        let split = stream.count / 4 * 2
        let pixels = try DicomVideoPixelData(fragments: [Data(stream.prefix(split)), Data(stream.dropFirst(split))],
            transferSyntax: .mpeg4AVCH264HighProfileLevel41Fragmentable,
            columns: 128, rows: 64, numberOfFrames: 96, frameTimeMilliseconds: 1000 / 12)
        let bytes = try DicomVideoBuilder.part10Data(video: pixels)
        let descriptor = try XCTUnwrap(DCMDecoder(data: bytes).encapsulatedPixelDataDescriptor)
        XCTAssertEqual(descriptor.fragments.count, 2)
        let total = descriptor.fragments.reduce(0) { $0 + $1.length }
        let permitted = try DicomInstanceValidator.validate(bytes, limits: .init(maximumFrameBytes: total))
        XCTAssertEqual(permitted[.codestream], .passed)
        for limit in [total - 1, descriptor.fragments.map(\.length).max()!] {
            let bounded = try DicomInstanceValidator.validate(bytes, limits: .init(maximumFrameBytes: limit))
            XCTAssertTrue(bounded.diagnostics.contains { $0.code == .evaluationLimitReached })
            XCTAssertNotEqual(bounded[.codestream], .passed)
        }
    }

    func test_originalMultiframeRLE_composesEveryFrameAndPreservesPaths() throws {
        let data = try fixture(frames: [frame(), frame(extra: true)])
        let report = try DicomInstanceValidator.validate(data)
        XCTAssertEqual(report[.structure], .passed)
        XCTAssertEqual(report[.vrAndVM], .passed) // Every encapsulated fragment was read and framed.
        XCTAssertEqual(report[.attributes], .failed) // Classic SC cannot contain two frames.
        XCTAssertEqual(report[.codestream], .failed)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .invalidCodestream && $0.path == [.tag(0x7FE00010), .frame(1)] })
        XCTAssertEqual(report[.operation], .notEvaluated)
        let engine = DicomCodecWorkflowEngine()
        XCTAssertEqual(try engine.validateInstance(data), report)
        XCTAssertEqual(try engine.validate(data, environment: [:]).conformance, report)
        if let folder = ProcessInfo.processInfo.environment["DICOM_INSTANCE_VALIDATION_CORPUS_DIRECTORY"] {
            let directory = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("invalid.dcm"))
            try fixture().write(to: directory.appendingPathComponent("incomplete.dcm"))
        }
    }

    func test_knownFrameValidity_neverPromotesPartialIODOrOmittedPixelVR() throws {
        let report = try DicomInstanceValidator.validate(fixture())
        XCTAssertEqual(report[.codestream], .passed)
        XCTAssertEqual(report[.pixelsAndGeometry], .passed)
        XCTAssertEqual(report[.attributes], .incomplete)
        XCTAssertEqual(report[.vrAndVM], .passed)
        XCTAssertEqual(report.outcome(requiring: [.structure, .vrAndVM, .attributes, .codestream]), .incomplete)
        // SC is a qualified profile: incompleteness comes from unstated external facts, not a global marker.
        XCTAssertFalse(report.diagnostics.contains { $0.code == .moduleRuleUnavailable && $0.path == [.tag(0x00080016)] })
        XCTAssertTrue(report.diagnostics.contains { $0.code == .conditionUndetermined })
        let ultrasound = try DicomInstanceValidator.validate(fixture(sop: "1.2.840.10008.5.1.4.1.1.6.1"))
        // #2369 qualified the ultrasound IOD; this incomplete SC fixture still cannot pass its modules.
        XCTAssertFalse(ultrasound.diagnostics.contains { $0.code == .moduleRuleUnavailable && $0.path == [.tag(0x00080016)] })
        XCTAssertNotEqual(ultrasound[.attributes], .passed)
        let unqualified = try DicomInstanceValidator.validate(fixture(sop: "2.25.2321699"))
        XCTAssertTrue(unqualified.diagnostics.contains { $0.code == .moduleRuleUnavailable && $0.path == [.tag(0x00080016)] })
    }

    func test_uidMismatchDuplicatesAndFileMetaLength_areNotRepairedByDecoder() throws {
        let good = try fixture()
        var wrongLength = good; wrongLength[140] ^= 1
        XCTAssertEqual(try DicomInstanceValidator.validate(wrongLength)[.structure], .failed)
        let meta = try DicomPart10FileMetaParser.parse(good)
        var duplicate = Data(good.prefix(meta.dataSetOffset))
        let uidElement = try DicomDataSetWriter.dataSetData(from: .init(elements: [text(0x00080016, "1.2.840.10008.5.1.4.1.1.7", .UI)]), purpose: .instance)
        duplicate.append(uidElement); duplicate.append(good.dropFirst(meta.dataSetOffset))
        XCTAssertTrue(try DicomInstanceValidator.validate(duplicate).diagnostics.contains { $0.code == .duplicateElement })
        var mismatch = good
        let declared = try XCTUnwrap(mismatch.range(of: Data("2.25.23212401".utf8), in: meta.dataSetOffset..<mismatch.count))
        mismatch[declared.upperBound - 1] = UInt8(ascii: "2")
        XCTAssertTrue(try DicomInstanceValidator.validate(mismatch).diagnostics.contains { $0.code == .referenceIdentityContradiction })
    }

    func test_invalidFrameCountAndExtendedLengths_areExplicit() throws {
        let badCount = try fixture(count: "-1")
        let countReport = try DicomInstanceValidator.validate(badCount)
        XCTAssertTrue(countReport.diagnostics.contains { $0.code == .referenceSelectionInvalid })
        XCTAssertEqual(countReport[.codestream], .incomplete)
        let eot = try fixture(extended: true, wrongLength: true)
        let report = try DicomInstanceValidator.validate(eot)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .pixelDataLengthMismatch && $0.path == [.tag(0x7FE00002), .frame(0)] })
    }

    func test_resourceCapsSlicesAndCancellation_preserveIncompleteEvidence() async throws {
        let data = try fixture()
        for limits in [DicomInstanceValidator.Limits(maximumInputBytes: 1), .init(maximumFrames: 0), .init(maximumFrameBytes: 1),
                       .init(maximumDiagnostics: 1), .init(parsing: .init(maximumSequenceDepth: 0, maximumElementCount: 0, maximumItemCount: 0))] {
            let report = try DicomInstanceValidator.validate(data, limits: limits)
            XCTAssertNotEqual(report.outcome(requiring: [.structure, .attributes, .codestream]), .passed)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .evaluationLimitReached })
            XCTAssertLessThanOrEqual(report.diagnostics.count, limits.maximumDiagnostics + 7)
        }
        var sliced = Data([1, 2]) + data; sliced.removeFirst(2)
        XCTAssertEqual(try DicomInstanceValidator.validate(sliced), try DicomInstanceValidator.validate(data))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DicomInstanceValidator.validate(data)
        }
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
    }

    func test_moduleDispatchAndUnknownSyntax_doNotClaimFullProfiles() throws {
        for (uid, required) in [("1.2.840.10008.5.1.4.1.1.2", 0x00180060), ("1.2.840.10008.5.1.4.1.1.4", 0x00180020),
                                (DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID, 0x0040A375)] {
            let report = try DicomInstanceValidator.validate(fixture(sop: uid))
            XCTAssertTrue(report.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path == [.tag(required)] })
            XCTAssertNotEqual(report[.attributes], .passed)
        }
        var unknown = try fixture()
        let range = try XCTUnwrap(unknown.range(of: Data(DicomTransferSyntax.rleLossless.rawValue.utf8)))
        unknown[range.upperBound - 1] = UInt8(ascii: "9")
        let unknownReport = try DicomInstanceValidator.validate(unknown)
        XCTAssertEqual(unknownReport[.codestream], .incomplete)
        XCTAssertEqual(unknownReport[.structure], .incomplete)
        XCTAssertEqual(unknownReport[.vrAndVM], .incomplete)
    }

    func test_serializedEvidence_isStablePHIFreeAndRoundTrips() throws {
        let report = try DicomInstanceValidator.validate(fixture())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        XCTAssertEqual(data, try encoder.encode(report))
        XCTAssertEqual(try JSONDecoder().decode(DicomValidationReport.self, from: data), report)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("PRIVATE_TEST_MARKER"))
        XCTAssertFalse(json.contains("2.25.23212401"))
        XCTAssertTrue(json.contains("outcomes"))
        var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        changed["outcomes"] = ["attributes": "passed", "codestream": "passed"]
        let tampered = try JSONDecoder().decode(DicomValidationReport.self, from: JSONSerialization.data(withJSONObject: changed))
        XCTAssertEqual(tampered[.attributes], .incomplete)
    }

    func test_deflatedInput_isInflatedWithinTheBudgetAndRetainedBeyondIt() throws {
        let metadata = DicomDataSet(elements: [text(0x00080016, "1.2.840.10008.5.1.4.1.1.7", .UI), text(0x00080018, "2.25.23212403", .UI)])
        let input = try DicomDataSetWriter.part10Data(from: metadata, options: .init(transferSyntax: .deflatedExplicitVRLittleEndian))
        let report = try DicomInstanceValidator.validate(input)
        XCTAssertEqual(report[.structure], .passed)
        XCTAssertEqual(report[.vrAndVM], .passed)
        XCTAssertEqual(report[.attributes], .failed) // The inflated SC lacks its mandatory modules.
        XCTAssertFalse(report.diagnostics.contains { $0.code == .validationInterrupted || $0.code == .invalidDeflatedDataSet })
        let budgeted = try DicomInstanceValidator.validate(input, limits: .init(maximumInflatedBytes: 8))
        XCTAssertEqual(budgeted[.structure], .incomplete)
        XCTAssertEqual(budgeted[.vrAndVM], .incomplete)
        XCTAssertEqual(budgeted[.attributes], .incomplete) // File-meta prerequisites cannot qualify the unread instance.
        XCTAssertEqual(budgeted[.codestream], .notEvaluated)
        XCTAssertTrue(budgeted.diagnostics.contains { $0.code == .evaluationLimitReached && $0.layer == .structure })
        XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(input), report)
    }

    func test_transcodeOutput_usesTheSameEvidenceEngine() async throws {
        let input = try fixture()
        let result = try await DicomCodecWorkflowEngine().transcode(input, to: .rleLossless, environment: [:], verifyDecodedPixels: false)
        XCTAssertTrue(result.report.success)
        XCTAssertEqual(result.report.conformance, try DicomInstanceValidator.validate(result.data))
        XCTAssertEqual(result.report.conformance?[.attributes], .incomplete)
        XCTAssertTrue(DicomCodecCanonicalRenderer.text(result.report).contains("conformance-attributes: incomplete"))
    }

    private func fixture(frames: [Data]? = nil, count: String? = nil, extended: Bool = false, wrongLength: Bool = false,
                         sop: String = "1.2.840.10008.5.1.4.1.1.7") throws -> Data {
        let frames = frames ?? [frame()]
        let encapsulated = try DicomTranscoder.encapsulate(fragments: frames, forceExtendedOffsets: extended)
        var metadata = DicomDataSet(elements: [text(0x00080016, sop, .UI), text(0x00080018, "2.25.23212401", .UI),
            text(0x00100020, "", .LO), text(0x00100030, "", .DA), text(0x00100040, "", .CS),
            text(0x00080020, "", .DA), text(0x00080030, "", .TM), text(0x00080090, "", .PN),
            text(0x00080050, "", .SH), text(0x00200010, "", .SH), text(0x00200011, "", .IS),
            text(0x00200013, "", .IS), text(0x00200020, "", .CS),
            text(0x0020000D, "2.25.23212402", .UI), text(0x0020000E, "2.25.23212403", .UI), text(0x00080064, "SYN", .CS),
            text(0x00100010, "PRIVATE_TEST_MARKER", .PN), text(0x00280008, count ?? String(frames.count), .IS),
            number(0x00280010, 2), number(0x00280011, 2), number(0x00280002, 1), text(0x00280004, "MONOCHROME2", .CS),
            number(0x00280100, 8), number(0x00280101, 8), number(0x00280102, 7), number(0x00280103, 0),
            .init(tag: 0x7FE00010, vr: .OB, value: .bytes(encapsulated.pixelData))])
        if extended {
            metadata = metadata.setting(.init(tag: 0x7FE00001, vr: .OV, value: .bytes(try XCTUnwrap(encapsulated.extendedOffsetTable))))
            var lengths = try XCTUnwrap(encapsulated.extendedOffsetTableLengths)
            if wrongLength { lengths[0] ^= 1 }
            metadata = metadata.setting(.init(tag: 0x7FE00002, vr: .OV, value: .bytes(lengths)))
        }
        return try DicomDataSetWriter.part10Data(from: metadata, options: .init(transferSyntax: .rleLossless))
    }
    private func frame(extra: Bool = false) -> Data {
        var data = Data(repeating: 0, count: 64); data[0] = 1; data[4] = 64
        data.append(contentsOf: [1, 1, 2, 1, 3, 4])
        if extra { data.append(contentsOf: [0, 9]) }
        return data
    }
    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers([value])) }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings([value])) }
}
