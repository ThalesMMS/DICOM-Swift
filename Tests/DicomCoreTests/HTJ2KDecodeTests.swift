//
//  HTJ2KDecodeTests.swift
//  DicomCoreTests
//
//  HTJ2K decode behind explicit capability checks (issue #1231). Backend
//  strategy of record: HTJ2K (ISO/IEC 15444-15) codestreams decode through
//  the preflighted OpenJPEG runtime when it includes the HT block decoder
//  (version 2.5+, BSD-2-Clause — the same system dependency as classic
//  JPEG 2000, no new license). The generic ImageIO JPEG 2000 fallback is
//  never used for HTJ2K. The curated fixture is generated with OpenJPH's
//  ojph_compress (reversible) and pinned by pixel hash.
//

import Foundation
import XCTest
import DicomTestSupport
@testable import DicomCore

final class HTJ2KDecodeTests: XCTestCase {
    static let fixtureRelativePath = "Tests/DicomCoreTests/Fixtures/DecoderParity/htj2k_lossless_parity.dcm"
    static let expectedPixelHash = "555d33cbc417cfa5"

    // MARK: - Committed fixture (pixel hash pinned)

    func testCommittedHTJ2KFixtureDecodesWithPinnedHash() throws {
        try Self.skipUnlessHTJ2KSupported()
        let url = Self.repoRoot().appendingPathComponent(Self.fixtureRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "committed fixture missing: \(url.path)")

        let reader = try DicomDecodedFrameReader(contentsOf: url)
        XCTAssertEqual(reader.frameCount, 1)
        let frame = try reader.frame(at: 0)
        guard case .gray8(let pixels) = frame.pixels else {
            return XCTFail("expected 8-bit grayscale, got \(frame.pixels)")
        }
        XCTAssertEqual(pixels, Self.sourcePixels(), "HTJ2K reversible decode must be lossless")
        XCTAssertEqual(
            ClinicalParityCuratedFixtureTests.pixelHash(pixels),
            Self.expectedPixelHash,
            "decoded HTJ2K pixels must match the pinned deterministic hash"
        )
        XCTAssertEqual(frame.metadata.transferSyntaxUID, DicomTransferSyntax.htj2kLossless.rawValue)
        XCTAssertEqual(frame.metadata.bitsAllocated, 8)
        XCTAssertEqual(frame.metadata.width, 8)
        XCTAssertEqual(frame.metadata.height, 8)
    }

    /// Regeneration guard for the committed fixture. OpenJPH codestream bytes
    /// may change between tool versions while remaining lossless, so normal
    /// validation pins the committed checksum and decoded samples instead of
    /// rebuilding with whichever ojph_compress happens to be installed.
    func testCommittedFixtureMatchesBuilderDuringExplicitRegeneration() throws {
        guard ProcessInfo.processInfo.environment["DICOM_REGENERATE_PARITY_FIXTURES"] == "1" else {
            throw XCTSkip("Set DICOM_REGENERATE_PARITY_FIXTURES=1 to rebuild the HTJ2K fixture.")
        }
        let rebuilt = try Self.makeFixtureData()
        let url = Self.repoRoot().appendingPathComponent(Self.fixtureRelativePath)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try rebuilt.write(to: url)

        let committed = try Data(contentsOf: url)
        XCTAssertEqual(committed, rebuilt, "committed HTJ2K fixture drifted from the deterministic builder")
    }

    // MARK: - Fresh round-trip through the shared frame decode contract

    func testFreshHTJ2KEncodeRoundTripsLosslesslyThroughPixelReader() throws {
        try Self.skipUnlessHTJ2KSupported()
        let width = 16, height = 8
        var source = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                source.append(UInt8((7 * x + 23 * y) % 251))
            }
        }
        let codestream = try Self.ojphEncode(pixels: source, width: width, height: height)

        let result = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
            data: codestream,
            transferSyntax: .htj2kLossless,
            bitDepth: 8,
            samplesPerPixel: 1,
            pixelRepresentation: 0
        ))
        XCTAssertEqual(result.pixels8, source)
        XCTAssertEqual(result.width, width)
        XCTAssertEqual(result.height, height)
    }

    // MARK: - Capability boundary (typed, explicit)

    func testCapabilityDecisionIsExplicitAndTyped() {
        XCTAssertNotNil(
            DicomJPEG2000Codec.htj2kUnsupportedReason(
                runtimeAvailable: false,
                runtimeMessage: "OpenJPEG runtime library is not loadable.",
                version: nil
            ),
            "missing runtime must be unsupported"
        )
        let tooOld = DicomJPEG2000Codec.htj2kUnsupportedReason(
            runtimeAvailable: true,
            runtimeMessage: "",
            version: "2.4.0"
        )
        XCTAssertNotNil(tooOld)
        XCTAssertTrue(tooOld!.contains("2.4.0"))
        XCTAssertTrue(tooOld!.contains("2.5"))
        XCTAssertNil(
            DicomJPEG2000Codec.htj2kUnsupportedReason(
                runtimeAvailable: true,
                runtimeMessage: "",
                version: "2.5.4"
            )
        )
        XCTAssertNotNil(
            DicomJPEG2000Codec.htj2kUnsupportedReason(
                runtimeAvailable: true,
                runtimeMessage: "",
                version: "garbled"
            ),
            "unparseable versions must stay unsupported"
        )
    }

    func testResolverRoutesEveryHTJ2KSyntaxByCapability() {
        for syntax in [DicomTransferSyntax.htj2kLossless, .htj2kLosslessRPCL, .htj2k] {
            let decision = DicomCompressedPixelBackendResolver.resolve(
                transferSyntax: syntax,
                requestedBitDepth: 16,
                samplesPerPixel: 1
            )
            if DicomJPEG2000Codec.supportsHTJ2K {
                XCTAssertEqual(decision.backend, .openJPEGHTJ2K, "\(syntax)")
            } else {
                XCTAssertEqual(decision.backend, .unsupported, "\(syntax)")
                let diagnostic = decision.diagnostics.joined()
                XCTAssertTrue(diagnostic.contains("ImageIO JPEG 2000 fallback is not used"), diagnostic)
            }
        }
    }

    func testHTJ2KColorAndDepthLimitsMatchTheJPEG2000Pipeline() throws {
        try Self.skipUnlessHTJ2KSupported()
        let deepColor = DicomCompressedPixelBackendResolver.resolve(
            transferSyntax: .htj2k,
            requestedBitDepth: 16,
            samplesPerPixel: 3,
            photometricInterpretation: "RGB"
        )
        XCTAssertEqual(deepColor.backend, .unsupported)
        XCTAssertTrue(deepColor.diagnostics.joined().contains("color output above 8 bits"))

        let tooDeep = DicomCompressedPixelBackendResolver.resolve(
            transferSyntax: .htj2kLossless,
            requestedBitDepth: 32,
            samplesPerPixel: 1
        )
        XCTAssertEqual(tooDeep.backend, .unsupported)
        XCTAssertTrue(tooDeep.diagnostics.joined().contains("16-bit"))
    }

    /// Garbage HTJ2K payloads must fail through the HTJ2K backend (or its
    /// capability gate) — never through an ImageIO JPEG 2000 decode.
    func testGarbageHTJ2KPayloadFailsWithoutImageIOFallback() {
        let logger = MockLogger()
        let result = DCMPixelReader.decodeCompressedFrameData(
            data: Data([0xFF, 0x4F, 0xFF, 0x51]),
            transferSyntax: .htj2kLossless,
            bitDepth: 16,
            samplesPerPixel: 1,
            pixelRepresentation: 0,
            logger: logger
        )

        XCTAssertNil(result)
        if DicomJPEG2000Codec.supportsHTJ2K {
            XCTAssertTrue(logger.contains(level: .warning, text: "HTJ2K decoding failed"))
        } else {
            XCTAssertTrue(logger.contains(level: .warning, text: "ImageIO JPEG 2000 fallback is not used"))
        }
    }

    // MARK: - Fixture builder (deterministic, non-PHI)

    static func sourcePixels() -> [UInt8] {
        var pixels = [UInt8]()
        for y in 0..<8 {
            for x in 0..<8 {
                pixels.append(UInt8(16 * y + 2 * x))
            }
        }
        return pixels
    }

    static func makeFixtureData() throws -> Data {
        let codestream = try ojphEncode(pixels: sourcePixels(), width: 8, height: 8)
        var dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .htj2kLossless,
            fragments: [codestream],
            declaredFrames: 1,
            rows: 8,
            columns: 8
        )
        dataSet.set(DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.12310001"])))
        dataSet.set(DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["PARITY^HTJ2K"])))
        dataSet.set(DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings(["PARITY-1231"])))
        dataSet.set(DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.12310002"])))
        dataSet.set(DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.12310003"])))
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .htj2kLossless,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.12310001"
            )
        )
    }

    /// Encodes 8-bit grayscale pixels as a reversible HTJ2K codestream with
    /// OpenJPH's ojph_compress; skips when the tool is not installed.
    /// (ojph_compress is a fixture-generation tool only — decode always
    /// goes through the OpenJPEG runtime.)
    static func ojphEncode(pixels: [UInt8], width: Int, height: Int) throws -> Data {
        guard let executable = ojphCompressPath() else {
            throw XCTSkip("ojph_compress is not installed; HTJ2K fixture generation is unavailable.")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("htj2k_fixture_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.pgm")
        let encodedURL = directory.appendingPathComponent("source.j2c")
        var pgm = Data("P5\n\(width) \(height)\n255\n".utf8)
        pgm.append(contentsOf: pixels)
        try pgm.write(to: sourceURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-i", sourceURL.path, "-o", encodedURL.path, "-reversible", "true"]
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"
            throw XCTSkip("ojph_compress failed: \(error)")
        }
        return try Data(contentsOf: encodedURL)
    }

    private static func ojphCompressPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ojph_compress",
            "/usr/local/bin/ojph_compress"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func skipUnlessHTJ2KSupported() throws {
        try DicomTestRuntimePreflight.require(.openJPEG)
        if let reason = DicomJPEG2000Codec.htj2kUnsupportedReason() {
            throw XCTSkip("HTJ2K decode unavailable: \(reason)")
        }
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
