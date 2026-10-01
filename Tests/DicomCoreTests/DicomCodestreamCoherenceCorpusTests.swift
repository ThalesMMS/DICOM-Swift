import Foundation
import XCTest
@testable import DicomCore

/// Corpus for metadata↔codestream coherence per transfer syntax (PS3.5 8.2.1, 8.2.3, 8.2.4, 8.2.14, A.5): JPEG-LS,
/// JPEG 2000 and HTJ2K main-header evidence against the pixel attributes, the lossless/near-lossless and Part 1/Part 15
/// syntax profiles, JPEG entropy verification and the Deflate budget at the entry point. Codestreams come from
/// independent encoders (OpenJPEG, CharLS, OpenJPH `ojph_compress -reversible true -prog_order RPCL -tlm_marker true` for the
/// `-tlm` HTJ2K fixture) and the HTJ2K parity fixture; every object is a single-frame SC.
final class DicomCodestreamCoherenceCorpusTests: XCTestCase {

    func test_invalidTilePartOrdering_isRejectedUnderLossyTransferSyntax() throws {
        var stream = try codestream("j2k-mono8-lossy", "j2k")
        let tile = try XCTUnwrap(stream.range(of: Data([0xFF, 0x90]))).lowerBound
        stream[tile + 10] = 1 // The first tile-part must be numbered zero.
        let report = DicomJ2KFrameValidator.validate(try encapsulated(stream, pixels: Pixels()), frame: stream,
                                                   transferSyntax: .jpeg2000)
        XCTAssertEqual(report[.codestream], .failed)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .invalidCodestream && $0.path == frame })
    }

    func test_irreversibleComponentOverride_reportsLosslessProfileMismatch() throws {
        var stream = try codestream("j2k-mono8-lossless", "j2k")
        let tile = try XCTUnwrap(stream.range(of: Data([0xFF, 0x90])))
        // COC for component zero, irreversible 9/7 transform; main COD stays reversible.
        stream.insert(contentsOf: [0xFF, 0x53, 0, 9, 0, 0, 0, 4, 4, 0, 0], at: tile.lowerBound)
        let dataSet = try encapsulated(stream, pixels: Pixels())
        let bytes = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(
            transferSyntax: .jpeg2000Lossless, mediaStorageSOPClassUID: sopClass, mediaStorageSOPInstanceUID: instanceUID))
        let report = try DicomInstanceValidator.validate(bytes, imageConditions: facts)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .codestreamProfileMismatch && $0.path == frame })
    }

    private enum Expectation {
        case passed
        case incomplete([DicomValidationReport.Code])
        case failed(DicomValidationReport.Code, [DicomValidationReport.PathComponent])
    }

    private struct Pixels {
        var rows = 32, columns = 32, samples = 1, photometric = "MONOCHROME2", allocated = 8, stored = 8, representation = 0
        var high: Int { stored - 1 }
    }

    private let facts = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied, nonBipedalAnatomy: .unsatisfied,
        pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied, calibratedImage: .unsatisfied)
    private let requiredLayers = Set(DicomValidationReport.Layer.allCases.filter { $0 != .operation })
    private let frame: [DicomValidationReport.PathComponent] = [.tag(0x7FE00010), .frame(0)]

    func test_originalCorpus_composesCodestreamEvidencePerSyntaxAndBudgetsDeflate() throws {
        let mono12 = Pixels(allocated: 16, stored: 12), signed16 = Pixels(allocated: 16, stored: 16, representation: 1)
        let rgb = Pixels(samples: 3, photometric: "RGB"), rct = Pixels(samples: 3, photometric: "YBR_RCT"), ict = Pixels(samples: 3, photometric: "YBR_ICT")
        let ht = Pixels(rows: 8, columns: 8)
        let header = [codestreamPayloadUnverified], color = [codestreamPayloadUnverified, codestreamColorProfileUnavailable]
        var cases: [(String, DicomTransferSyntax, Data, Pixels, Expectation)] = [
            // JPEG-LS (8.2.3)
            ("jls-mono8-lossless", .jpegLSLossless, try codestream("jls-mono8-lossless", "jls"), Pixels(), .incomplete(header)),
            ("jls-mono12-lossless", .jpegLSLossless, try codestream("jls-mono12-lossless", "jls"), mono12, .incomplete(header)),
            ("jls-rgb-lossless", .jpegLSLossless, try codestream("jls-rgb-lossless", "jls"), rgb, .incomplete(color)),
            ("jls-near-lossless", .jpegLSNearLossless, try codestream("jls-mono8-near2", "jls"), Pixels(), .incomplete(header)),
            ("jls-near-under-lossless", .jpegLSLossless, try codestream("jls-mono8-near2", "jls"), Pixels(), .failed(.codestreamProfileMismatch, frame)),
            ("jls-wrong-rows", .jpegLSLossless, try codestream("jls-mono8-lossless", "jls"), Pixels(rows: 31), .failed(.pixelMetadataContradiction, [.tag(0x00280010), .frame(0)])),
            // A precision that fits Bits Allocated is a warning since #2487 (the frame decodes into the container).
            ("jls-wrong-precision", .jpegLSLossless, try codestream("jls-mono8-lossless", "jls"), mono12, .incomplete([codestreamPayloadUnverified])),
            ("jls-wrong-components", .jpegLSLossless, try codestream("jls-rgb-lossless", "jls"), Pixels(), .failed(.pixelMetadataContradiction, [.tag(0x00280002), .frame(0)])),
            ("jls-truncated", .jpegLSLossless, try codestream("jls-mono8-lossless", "jls").dropLast(2), Pixels(), .failed(.invalidCodestream, frame)),
            ("jls-palette-near-lossless", .jpegLSNearLossless, try codestream("jls-mono8-near2", "jls"), Pixels(photometric: "PALETTE COLOR"),
             .failed(.attributeValueNotAllowed, [.tag(0x00280004)])),
            // JPEG 2000 (8.2.4)
            ("j2k-mono8-lossless", .jpeg2000Lossless, try codestream("j2k-mono8-lossless", "j2k"), Pixels(), .incomplete(header)),
            ("j2k-mono12-lossless", .jpeg2000Lossless, try codestream("j2k-mono12-lossless", "j2k"), mono12, .incomplete(header)),
            ("j2k-mono16-signed-lossless", .jpeg2000Lossless, try codestream("j2k-mono16-signed-lossless", "j2k"), signed16, .incomplete(header)),
            ("j2k-mono8-lossy", .jpeg2000, try codestream("j2k-mono8-lossy", "j2k"), Pixels(), .incomplete(header)),
            ("j2k-lossy-under-lossless", .jpeg2000Lossless, try codestream("j2k-mono8-lossy", "j2k"), Pixels(), .failed(.codestreamProfileMismatch, frame)),
            ("j2k-rgb-rct-lossless", .jpeg2000Lossless, try codestream("j2k-rgb-rct-lossless", "j2k"), rct, .incomplete(color)),
            ("j2k-rct-declared-rgb", .jpeg2000Lossless, try codestream("j2k-rgb-rct-lossless", "j2k"), rgb, .failed(.pixelMetadataContradiction, [.tag(0x00280004), .frame(0)])),
            ("j2k-rgb-ict-lossy", .jpeg2000, try codestream("j2k-rgb-ict-lossy", "j2k"), ict, .incomplete(color)),
            ("j2k-ict-declared-rct", .jpeg2000, try codestream("j2k-rgb-ict-lossy", "j2k"), rct, .failed(.pixelMetadataContradiction, [.tag(0x00280004), .frame(0)])),
            ("j2k-ict-under-lossless", .jpeg2000Lossless, try codestream("j2k-rgb-ict-lossy", "j2k"), ict, .failed(.attributeValueNotAllowed, [.tag(0x00280004)])),
            ("j2k-rgb-without-mct", .jpeg2000Lossless, try codestream("j2k-rgb-nomct-lossless", "j2k"), rgb, .incomplete(color)),
            ("j2k-no-mct-declared-rct", .jpeg2000Lossless, try codestream("j2k-rgb-nomct-lossless", "j2k"), rct, .failed(.pixelMetadataContradiction, [.tag(0x00280004), .frame(0)])),
            ("j2k-signed-declared-unsigned", .jpeg2000Lossless, try codestream("j2k-mono16-signed-lossless", "j2k"), Pixels(allocated: 16, stored: 16),
             .failed(.pixelMetadataContradiction, [.tag(0x00280103), .frame(0)])),
            ("j2k-wrong-columns", .jpeg2000Lossless, try codestream("j2k-mono8-lossless", "j2k"), Pixels(columns: 16), .failed(.pixelMetadataContradiction, [.tag(0x00280011), .frame(0)])),
            ("j2k-wrong-precision", .jpeg2000Lossless, try codestream("j2k-mono12-lossless", "j2k"), Pixels(allocated: 16, stored: 16), .incomplete([codestreamPayloadUnverified])),
            ("j2k-precision-over-allocation", .jpeg2000Lossless, try codestream("j2k-mono12-lossless", "j2k"), Pixels(allocated: 8, stored: 8), .failed(.pixelMetadataContradiction, [.tag(0x00280101), .frame(0)])),
            ("j2k-under-htj2k", .htj2kLossless, try codestream("j2k-mono8-lossless", "j2k"), Pixels(), .failed(.codestreamProfileMismatch, frame)),
            ("j2k-without-eoc", .jpeg2000Lossless, try codestream("j2k-mono8-lossless", "j2k").dropLast(2), Pixels(), .failed(.invalidCodestream, frame)),
            ("j2k-truncated-header", .jpeg2000Lossless, try codestream("j2k-mono8-lossless", "j2k").prefix(20), Pixels(), .failed(.invalidCodestream, frame)),
            // HTJ2K (8.2.14)
            ("htj2k-lossless", .htj2kLossless, try codestream("htj2k-mono8-lossless-rpcl", "jph"), ht, .incomplete(header)),
            // PS3.5 10.18.1: the .202 syntax needs RPCL, a TLM marker segment and a <= 64-sample base resolution (#2330).
            ("htj2k-lossless-rpcl", .htj2kLosslessRPCL, try codestream("htj2k-mono8-lossless-rpcl-tlm", "jph"), ht, .incomplete(header)),
            ("htj2k-rpcl-without-tlm", .htj2kLosslessRPCL, try codestream("htj2k-mono8-lossless-rpcl", "jph"), ht, .failed(.codestreamProfileMismatch, frame)),
            ("htj2k-lossy-syntax", .htj2k, try codestream("htj2k-mono8-lossless-rpcl", "jph"), ht, .incomplete(header)),
            ("htj2k-under-j2k", .jpeg2000Lossless, try codestream("htj2k-mono8-lossless-rpcl", "jph"), ht, .failed(.codestreamProfileMismatch, frame)),
            ("htj2k-lrcp-under-rpcl", .htj2kLosslessRPCL, patchingCOD(try codestream("htj2k-mono8-lossless-rpcl-tlm", "jph"), progression: 0), ht,
             .failed(.codestreamProfileMismatch, frame)),
            ("htj2k-irreversible-under-lossless", .htj2kLossless, patchingCOD(try codestream("htj2k-mono8-lossless-rpcl", "jph"), transform: 0), ht,
             .failed(.codestreamProfileMismatch, frame)),
            ("htj2k-wrong-rows", .htj2kLossless, try codestream("htj2k-mono8-lossless-rpcl", "jph"), Pixels(rows: 9, columns: 8), .failed(.pixelMetadataContradiction, [.tag(0x00280010), .frame(0)])),
            // JPEG lossless (8.2.1): the native decoder verifies the entropy-coded segment.
            ("jpeg-lossless-verified", .jpegLosslessFirstOrder, makeJPEGLosslessStream(planes: [Array(repeating: 100, count: 64)], width: 8, height: 8, precision: 8), ht, .passed),
            ("jpeg-lossless-corrupt-entropy", .jpegLosslessFirstOrder, corruptingEntropy(makeJPEGLosslessStream(planes: [Array(repeating: 100, count: 64)], width: 8, height: 8, precision: 8)), ht,
             .failed(.invalidCodestream, frame))
        ]
        for (name, syntax, codestream, pixels, expectation) in cases {
            let instance = try encapsulated(codestream, pixels: pixels)
            let bytes = try DicomDataSetWriter.part10Data(from: instance, options: .init(transferSyntax: syntax, mediaStorageSOPClassUID: sopClass, mediaStorageSOPInstanceUID: instanceUID))
            let report = try DicomInstanceValidator.validate(bytes, imageConditions: facts)
            try check(name, report: report, expectation: expectation)
            if name.hasSuffix("wrong-precision") {
                XCTAssertTrue(report.diagnostics.contains { $0.code == .pixelMetadataContradiction && $0.severity == .warning && $0.path == [.tag(0x00280101), .frame(0)] }, name)
            }
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes, imageConditions: facts), report, name)
            try writeSidecar(name, bytes: bytes, report: report, syntax: syntax, cliExit: exit(report))
        }
        // Deflated Explicit VR Little Endian (A.5): the inflated data set is validated within an explicit budget.
        let native = try nativeInstance()
        let deflated = try DicomDataSetWriter.part10Data(from: native, options: .init(transferSyntax: .deflatedExplicitVRLittleEndian, mediaStorageSOPClassUID: sopClass, mediaStorageSOPInstanceUID: instanceUID))
        let report = try DicomInstanceValidator.validate(deflated, imageConditions: facts)
        try check("deflate-sc", report: report, expectation: .passed)
        try writeSidecar("deflate-sc", bytes: deflated, report: report, syntax: .deflatedExplicitVRLittleEndian, cliExit: 0)
        let budgeted = try DicomInstanceValidator.validate(deflated, imageConditions: facts, limits: .init(maximumInflatedBytes: 64))
        try check("deflate-over-budget", report: budgeted, expectation: .incomplete([.evaluationLimitReached, .valueUnavailable, .moduleRuleUnavailable]))
        try writeSidecar("deflate-over-budget", bytes: deflated, report: budgeted, syntax: .deflatedExplicitVRLittleEndian, cliExit: 0)
        var corrupt = deflated
        let body = try DicomPart10FileMetaParser.parse(deflated).dataSetOffset
        for offset in stride(from: body + 4, to: min(corrupt.count, body + 64), by: 3) { corrupt[offset] ^= 0xA5 }
        let corruptReport = try DicomInstanceValidator.validate(corrupt, imageConditions: facts)
        try check("deflate-corrupt", report: corruptReport, expectation: .failed(.invalidDeflatedDataSet, []))
        try writeSidecar("deflate-corrupt", bytes: corrupt, report: corruptReport, syntax: .deflatedExplicitVRLittleEndian, cliExit: 1)
    }

    // MARK: - Helpers

    private let sopClass = "1.2.840.10008.5.1.4.1.1.7", instanceUID = "2.25.23299901"
    private let codestreamPayloadUnverified = DicomValidationReport.Code.codestreamPayloadUnverified
    private let codestreamColorProfileUnavailable = DicomValidationReport.Code.codestreamColorProfileUnavailable

    private func check(_ name: String, report: DicomValidationReport, expectation: Expectation) throws {
        let outcome = report.outcome(requiring: requiredLayers)
        let errors = report.diagnostics.filter { $0.severity == .error }
        let limitations = Set(report.diagnostics.filter { $0.severity == .limitation && $0.layer != .operation }.map(\.code))
        switch expectation {
        case .passed:
            XCTAssertEqual(outcome, .passed, "\(name): \(report.diagnostics)")
        case .incomplete(let codes):
            XCTAssertEqual(outcome, .incomplete, "\(name): \(report.diagnostics)")
            XCTAssertTrue(errors.isEmpty, "\(name): \(errors)")
            XCTAssertEqual(limitations, Set(codes), name)
        case .failed(let code, let path):
            XCTAssertEqual(outcome, .failed, "\(name): \(report.diagnostics)")
            XCTAssertTrue(errors.contains { $0.code == code && (path.isEmpty || $0.path == path) }, "\(name): \(report.diagnostics)")
        }
        if outcome == .passed || !errors.contains(where: { $0.code == .invalidDeflatedDataSet }) {
            XCTAssertFalse(report.diagnostics.contains { $0.code == .moduleRuleUnavailable && $0.layer == .attributes && outcome != .incomplete }, name)
        }
    }

    private func exit(_ report: DicomValidationReport) -> Int {
        let outcome = report.outcome(requiring: requiredLayers)
        return outcome == .passed ? 0 : outcome == .failed ? 1 : 2
    }

    private func writeSidecar(_ name: String, bytes: Data, report: DicomValidationReport, syntax: DicomTransferSyntax, cliExit: Int) throws {
        guard let folder = ProcessInfo.processInfo.environment["DICOM_CODESTREAM_CORPUS_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
        let limitations = Set(report.diagnostics.filter { $0.severity == .limitation && $0.layer != .operation }.map(\.code.rawValue))
        try JSONSerialization.data(withJSONObject: ["outcome": report.outcome(requiring: requiredLayers).rawValue, "syntax": syntax.rawValue, "exit": cliExit,
            "errors": Array(Set(report.diagnostics.filter { $0.severity == .error }.map(\.code.rawValue))).sorted(),
            "limitations": limitations.sorted()], options: [.sortedKeys]).write(to: directory.appendingPathComponent(name + ".json"))
    }

    private func codestream(_ name: String, _ ext: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Codestreams/\(name).\(ext)")
        return try Data(contentsOf: url)
    }

    /// Rewrites the COD marker segment of a JPEG 2000 main header.
    private func patchingCOD(_ data: Data, progression: UInt8? = nil, transform: UInt8? = nil) -> Data {
        var bytes = data
        var cursor = 4 + (Int(data[4]) << 8 | Int(data[5]))
        while cursor + 4 <= bytes.count, bytes[cursor] == 0xFF, bytes[cursor + 1] != 0x90 {
            let length = Int(bytes[cursor + 2]) << 8 | Int(bytes[cursor + 3])
            if bytes[cursor + 1] == 0x52 {
                if let progression { bytes[cursor + 5] = progression }
                if let transform { bytes[cursor + 13] = transform }
                return bytes
            }
            cursor += 2 + length
        }
        return bytes
    }

    /// Flips bits inside the entropy-coded segment of a JPEG lossless frame, keeping the markers intact.
    private func corruptingEntropy(_ data: Data) -> Data {
        var bytes = data
        guard let sos = bytes.indices.dropLast(1).first(where: { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xDA }) else { return bytes }
        let start = sos + 2 + (Int(bytes[sos + 2]) << 8 | Int(bytes[sos + 3]))
        for offset in stride(from: start + 1, to: max(start + 1, bytes.count - 4), by: 2) where bytes[offset] != 0xFF && bytes[offset - 1] != 0xFF { bytes[offset] ^= 0x55 }
        return bytes
    }

    private func nativeInstance() throws -> DicomDataSet {
        DicomSecondaryCaptureBuilder.dataSet(
            pixelData: try .rgb8(columns: 2, rows: 2, data: Data(repeating: 1, count: 12)),
            options: .init(sopInstanceUID: instanceUID, studyInstanceUID: "2.25.23299902", seriesInstanceUID: "2.25.23299903", seriesNumber: 1, instanceNumber: 1),
            requiredType2Attributes: .init())
    }

    private func encapsulated(_ codestream: Data, pixels: Pixels) throws -> DicomDataSet {
        var instance = try nativeInstance()
        for (tag, value) in [(0x00280010, pixels.rows), (0x00280011, pixels.columns), (0x00280002, pixels.samples), (0x00280100, pixels.allocated),
                             (0x00280101, pixels.stored), (0x00280102, pixels.high), (0x00280103, pixels.representation)] {
            instance = instance.setting(.init(tag: tag, vr: .US, value: .unsignedIntegers([UInt(value)])))
        }
        instance = instance.setting(.init(tag: 0x00280004, vr: .CS, value: .strings([pixels.photometric])))
        instance = pixels.samples == 3 ? instance.setting(.init(tag: 0x00280006, vr: .US, value: .unsignedIntegers([0]))) : instance.removing(0x00280006)
        let encapsulation = try DicomTranscoder.encapsulate(fragments: [codestream])
        return instance.setting(.init(tag: 0x7FE00010, vr: .OB, value: .bytes(encapsulation.pixelData)))
    }
}
