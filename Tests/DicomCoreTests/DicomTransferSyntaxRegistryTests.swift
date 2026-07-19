import XCTest
@testable import DicomCore

final class DicomTransferSyntaxRegistryTests: XCTestCase {
    func testRegistryCoversRecognizedTransferSyntaxes() {
        let registry = DicomTransferSyntaxRegistry.standard
        let registeredSyntaxes = Set(registry.entries.map(\.syntax))

        XCTAssertEqual(registeredSyntaxes, Set(DicomTransferSyntax.allCases))
        for syntax in DicomTransferSyntax.allCases {
            XCTAssertNotNil(registry.entry(for: syntax), "\(syntax) should have a registry entry")
        }
    }

    func testRegistryReportsCompressionAndFragmentationProperties() throws {
        let native = try XCTUnwrap(DicomTransferSyntaxRegistry.standard.entry(for: .explicitVRLittleEndian))
        XCTAssertFalse(native.isCompressed)
        XCTAssertFalse(native.isEncapsulated)
        XCTAssertFalse(native.supportsFragmentation)
        XCTAssertEqual(native.decoderSupport, .supported)
        XCTAssertEqual(native.encoderSupport, .supported)

        let compressed = try XCTUnwrap(DicomTransferSyntaxRegistry.standard.entry(for: .jpegLosslessFirstOrder))
        XCTAssertTrue(compressed.isCompressed)
        XCTAssertTrue(compressed.isEncapsulated)
        XCTAssertTrue(compressed.isLossless)
        XCTAssertFalse(compressed.isLossy)
        XCTAssertTrue(compressed.supportsFragmentation)
        XCTAssertEqual(compressed.decoderSupport, .supported)

        let rle = try XCTUnwrap(DicomTransferSyntaxRegistry.standard.entry(for: .rleLossless))
        XCTAssertEqual(rle.decoderSupport, .supported)

        let deflated = try XCTUnwrap(DicomTransferSyntaxRegistry.standard.entry(for: .deflatedExplicitVRLittleEndian))
        XCTAssertEqual(deflated.codec, .deflate)
        XCTAssertTrue(deflated.isCompressed)
        XCTAssertFalse(deflated.isEncapsulated)
        XCTAssertEqual(deflated.encoderSupport, .supported)
        XCTAssertTrue(deflated.syntax.usesDataSetDeflate)

        let part2 = try XCTUnwrap(DicomTransferSyntaxRegistry.standard.entry(for: .jpeg2000Part2MulticomponentLossless))
        XCTAssertEqual(part2.codec, .jpeg2000Part2)
        XCTAssertTrue(part2.isEncapsulated)
        XCTAssertEqual(part2.compression, .lossless)
        XCTAssertTrue("\(part2.decoderSupport)".contains("OpenJPEG"))

        let jpip = try XCTUnwrap(DicomTransferSyntaxRegistry.standard.entry(for: .jpipReferenced))
        XCTAssertEqual(jpip.codec, .jpip)
        XCTAssertEqual(jpip.pixelEncoding, .referenced)
        XCTAssertEqual(jpip.fragmentation, .referencedURL)
        XCTAssertFalse(jpip.isCompressed)
        XCTAssertFalse(jpip.supportsFragmentation)
        XCTAssertTrue(jpip.syntax.usesPixelDataProviderURL)

        let htj2k = try XCTUnwrap(DicomTransferSyntaxRegistry.standard.entry(for: .htj2kLossless))
        XCTAssertEqual(htj2k.codec, .htj2k)
        XCTAssertEqual(
            htj2k.decoderSupport,
            .bestEffort("HTJ2K decoding requires the preflighted OpenJPEG runtime version 2.5 or newer (HT block decoder); ImageIO JPEG 2000 fallback is not used.")
        )

        let jpegXLLossless = try XCTUnwrap(
            DicomTransferSyntaxRegistry.standard.entry(for: .jpegXLLossless)
        )
        XCTAssertEqual(jpegXLLossless.codec, .jpegXL)
        XCTAssertEqual(jpegXLLossless.compression, .lossless)
        XCTAssertEqual(DicomTransferSyntax.jpegXLLossless.compressedPixelSupport?.status, .experimental)

        let jpegRecompression = try XCTUnwrap(
            DicomTransferSyntaxRegistry.standard.entry(for: .jpegXLJPEGRecompression)
        )
        XCTAssertEqual(jpegRecompression.codec, .jpegXL)
        XCTAssertEqual(jpegRecompression.compression, .lossless)
        XCTAssertTrue("\(jpegRecompression.decoderSupport)".contains("byte-for-byte"))

        let jpegXL = try XCTUnwrap(DicomTransferSyntaxRegistry.standard.entry(for: .jpegXL))
        XCTAssertEqual(jpegXL.codec, .jpegXL)
        XCTAssertEqual(jpegXL.compression, .lossy)
        XCTAssertTrue("\(jpegXL.encoderSupport)".contains("explicit reversible or irreversible intent"))
    }

    func testWriteSupportMatrixCoversAllRecognizedTransferSyntaxes() throws {
        let registry = DicomTransferSyntaxRegistry.standard
        let matrix = registry.writeSupportMatrix
        let statusesBySyntax = Dictionary(uniqueKeysWithValues: matrix.map { ($0.syntax, $0.status) })

        XCTAssertEqual(Set(statusesBySyntax.keys), Set(DicomTransferSyntax.allCases))
        XCTAssertEqual(statusesBySyntax[.explicitVRLittleEndian], .nativeDataset)
        XCTAssertEqual(statusesBySyntax[.implicitVRLittleEndian], .nativeDataset)
        XCTAssertEqual(statusesBySyntax[.explicitVRBigEndian], .nativeDataset)
        XCTAssertEqual(statusesBySyntax[.deflatedExplicitVRLittleEndian], .deflatedDataset)
        XCTAssertEqual(statusesBySyntax[.jpipReferenced], .referencedDataset)
        XCTAssertEqual(statusesBySyntax[.jpipReferencedDeflate], .referencedDataset)

        let encapsulatedRows = matrix.filter { support in
            registry.entry(for: support.syntax)?.pixelEncoding == .encapsulated
        }
        XCTAssertFalse(encapsulatedRows.isEmpty)
        for support in encapsulatedRows {
            XCTAssertEqual(support.status, .encapsulatedPassThrough, support.name)
            XCTAssertTrue(support.requiresEncapsulatedPixelData, support.name)
            XCTAssertTrue(support.diagnostic.contains("does not encode compressed frames"), support.name)
        }
    }

    func testCanTranscodeSupportsNativeRewrite() {
        let plan = DicomTransferSyntax.transcodePlan(
            from: .implicitVRLittleEndian,
            to: .explicitVRLittleEndian
        )

        XCTAssertTrue(plan.canTranscode)
        XCTAssertEqual(plan.status, .supported)
        XCTAssertEqual(plan.route, .rewriteNative)
        XCTAssertFalse(plan.requiresDecompression)
        XCTAssertFalse(plan.requiresCompression)
    }

    func testCanTranscodeSupportsNativeJPEGLosslessDecompression() {
        let plan = DicomTransferSyntax.transcodePlan(
            from: .jpegLosslessFirstOrder,
            to: .explicitVRLittleEndian
        )

        XCTAssertTrue(plan.canTranscode)
        XCTAssertEqual(plan.status, .supported)
        XCTAssertEqual(plan.route, .decompress)
        XCTAssertTrue(plan.requiresDecompression)
        XCTAssertFalse(plan.requiresCompression)
        XCTAssertTrue(diagnosticText(plan).contains("Decoder for JPEG Lossless"))
    }

    func testCanTranscodeSupportsDatasetDeflateCompressionAndInflation() {
        let compressPlan = DicomTransferSyntax.transcodePlan(
            from: .explicitVRLittleEndian,
            to: .deflatedExplicitVRLittleEndian
        )
        XCTAssertTrue(compressPlan.canTranscode)
        XCTAssertEqual(compressPlan.route, .compress)
        XCTAssertTrue(compressPlan.requiresCompression)

        let inflatePlan = DicomTransferSyntax.transcodePlan(
            from: .deflatedExplicitVRLittleEndian,
            to: .explicitVRLittleEndian
        )
        XCTAssertTrue(inflatePlan.canTranscode)
        XCTAssertEqual(inflatePlan.route, .decompress)
        XCTAssertTrue(inflatePlan.requiresDecompression)
    }

    func testUncompressedToCompressedReportsMissingEncoder() {
        let plan = DicomTransferSyntax.transcodePlan(
            from: .explicitVRLittleEndian,
            to: .rleLossless
        )

        XCTAssertFalse(plan.canTranscode)
        XCTAssertEqual(plan.status, .unsupported)
        XCTAssertEqual(plan.route, .compress)
        XCTAssertFalse(plan.requiresDecompression)
        XCTAssertTrue(plan.requiresCompression)
        XCTAssertTrue(diagnosticText(plan).contains("Encoder for RLE Lossless is unavailable"))
    }

    func testBestEffortDecoderMakesTranscodeAmbiguous() {
        let plan = DicomTransferSyntax.transcodePlan(
            from: .jpegBaseline,
            to: .explicitVRLittleEndian
        )

        XCTAssertFalse(plan.canTranscode)
        XCTAssertEqual(plan.status, .ambiguous)
        XCTAssertEqual(plan.route, .decompress)
        XCTAssertTrue(diagnosticText(plan).contains("best-effort"))
        XCTAssertTrue(diagnosticText(plan).contains("single-frame"))
    }

    func testRecompressionReportsBestEffortDecoderAndJ2KEncoderDiagnostics() {
        let plan = DicomTransferSyntax.transcodePlan(
            from: .jpegLSLossless,
            to: .jpeg2000Lossless
        )

        XCTAssertFalse(plan.canTranscode)
        XCTAssertEqual(plan.status, .ambiguous)
        XCTAssertEqual(plan.route, .recompress)
        XCTAssertTrue(plan.requiresDecompression)
        XCTAssertTrue(plan.requiresCompression)

        let text = diagnosticText(plan)
        XCTAssertTrue(text.contains("Decoder for JPEG-LS Lossless Image Compression is best-effort"))
        XCTAssertTrue(text.contains("Encoder for JPEG 2000 Image Compression (Lossless Only) is best-effort"))
        XCTAssertTrue(text.contains("async DicomTranscoder route"))
    }

    func testSameSyntaxPassThroughDoesNotRequireCodecs() {
        let plan = DicomTransferSyntax.transcodePlan(
            from: .jpegLSLossless,
            to: .jpegLSLossless
        )

        XCTAssertTrue(plan.canTranscode)
        XCTAssertEqual(plan.status, .supported)
        XCTAssertEqual(plan.route, .passThrough)
        XCTAssertFalse(plan.requiresDecompression)
        XCTAssertFalse(plan.requiresCompression)
    }

    func testJPIPReferencedSyntaxDoesNotUseLocalTranscodePlanner() {
        let plan = DicomTransferSyntax.transcodePlan(
            from: .jpipReferenced,
            to: .explicitVRLittleEndian
        )

        XCTAssertFalse(plan.canTranscode)
        XCTAssertEqual(plan.status, .unsupported)
        XCTAssertEqual(plan.route, .reference)
        XCTAssertTrue(diagnosticText(plan).contains("Pixel Data Provider URL"))
    }

    func testUnknownUIDHasNoRegistryEntry() {
        XCTAssertNil(DicomTransferSyntaxRegistry.standard.entry(forUID: "1.2.840.10008.9.9.9"))
    }

    private func diagnosticText(_ plan: DicomTranscodePlan) -> String {
        plan.diagnostics.map(\.message).joined(separator: "\n")
    }
}
