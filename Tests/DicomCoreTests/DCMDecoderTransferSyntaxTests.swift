import XCTest
@testable import DicomCore

final class DCMDecoderTransferSyntaxTests: XCTestCase {

    // MARK: - Transfer Syntax Initialization Tests

    func testTransferSyntaxInitializationFromUID() {
        // Test standard uncompressed syntaxes
        let implicitLE = DicomTransferSyntax(uid: "1.2.840.10008.1.2")
        XCTAssertEqual(implicitLE, .implicitVRLittleEndian, "Should initialize Implicit VR Little Endian")

        let explicitLE = DicomTransferSyntax(uid: "1.2.840.10008.1.2.1")
        XCTAssertEqual(explicitLE, .explicitVRLittleEndian, "Should initialize Explicit VR Little Endian")

        let deflatedExplicitLE = DicomTransferSyntax(uid: "1.2.840.10008.1.2.1.99")
        XCTAssertEqual(deflatedExplicitLE, .deflatedExplicitVRLittleEndian, "Should initialize Deflated Explicit VR Little Endian")

        let explicitBE = DicomTransferSyntax(uid: "1.2.840.10008.1.2.2")
        XCTAssertEqual(explicitBE, .explicitVRBigEndian, "Should initialize Explicit VR Big Endian")
    }

    func testTransferSyntaxInitializationWithWhitespace() {
        // Test UID strings with trailing whitespace
        let syntaxWithSpaces = DicomTransferSyntax(uid: "1.2.840.10008.1.2  ")
        XCTAssertEqual(syntaxWithSpaces, .implicitVRLittleEndian, "Should handle trailing spaces")

        let syntaxWithNewline = DicomTransferSyntax(uid: "1.2.840.10008.1.2.1\n")
        XCTAssertEqual(syntaxWithNewline, .explicitVRLittleEndian, "Should handle trailing newline")

        let syntaxWithNull = DicomTransferSyntax(uid: "1.2.840.10008.1.2.2\0")
        XCTAssertEqual(syntaxWithNull, .explicitVRBigEndian, "Should handle null terminator")
    }

    func testTransferSyntaxInitializationWithInvalidUID() {
        // Test unknown/invalid UID
        let unknown = DicomTransferSyntax(uid: "1.2.840.10008.9.9.9")
        XCTAssertNil(unknown, "Should return nil for unknown UID")

        let empty = DicomTransferSyntax(uid: "")
        XCTAssertNil(empty, "Should return nil for empty UID")

        let invalid = DicomTransferSyntax(uid: "not-a-valid-uid")
        XCTAssertNil(invalid, "Should return nil for invalid UID format")
    }

    // MARK: - Little Endian Implicit VR Tests

    func testImplicitVRLittleEndianProperties() {
        let syntax = DicomTransferSyntax.implicitVRLittleEndian

        XCTAssertFalse(syntax.isCompressed, "Implicit VR LE should not be compressed")
        XCTAssertFalse(syntax.isBigEndian, "Implicit VR LE should be little endian")
        XCTAssertFalse(syntax.isExplicitVR, "Implicit VR LE should be implicit VR")
        XCTAssertEqual(syntax.rawValue, "1.2.840.10008.1.2", "Should have correct UID")
    }

    func testImplicitVRLittleEndianMatching() {
        let syntax = DicomTransferSyntax.implicitVRLittleEndian

        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2"), "Should match exact UID")
        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2  "), "Should match UID with trailing spaces")
        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2\0"), "Should match UID with null terminator")
        XCTAssertFalse(syntax.matches("1.2.840.10008.1.2.1"), "Should not match different UID")
    }

    // MARK: - Little Endian Explicit VR Tests

    func testExplicitVRLittleEndianProperties() {
        let syntax = DicomTransferSyntax.explicitVRLittleEndian

        XCTAssertFalse(syntax.isCompressed, "Explicit VR LE should not be compressed")
        XCTAssertFalse(syntax.isBigEndian, "Explicit VR LE should be little endian")
        XCTAssertTrue(syntax.isExplicitVR, "Explicit VR LE should be explicit VR")
        XCTAssertEqual(syntax.rawValue, "1.2.840.10008.1.2.1", "Should have correct UID")
    }

    func testExplicitVRLittleEndianMatching() {
        let syntax = DicomTransferSyntax.explicitVRLittleEndian

        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.1"), "Should match exact UID")
        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.1  "), "Should match UID with trailing spaces")
        XCTAssertFalse(syntax.matches("1.2.840.10008.1.2"), "Should not match different UID")
        XCTAssertFalse(syntax.matches("1.2.840.10008.1.2.2"), "Should not match big endian UID")
    }

    func testDeflatedExplicitVRLittleEndianProperties() {
        let syntax = DicomTransferSyntax.deflatedExplicitVRLittleEndian

        XCTAssertTrue(syntax.isCompressed, "Deflated Explicit VR LE should be compressed at dataset level")
        XCTAssertTrue(syntax.usesDataSetDeflate)
        XCTAssertFalse(syntax.usesPixelDataProviderURL)
        XCTAssertFalse(syntax.isBigEndian, "Deflated Explicit VR LE should be little endian")
        XCTAssertTrue(syntax.isExplicitVR, "Deflated Explicit VR LE should be explicit VR")
        XCTAssertEqual(syntax.rawValue, "1.2.840.10008.1.2.1.99", "Should have correct UID")
    }

    // MARK: - Big Endian Explicit VR Tests

    func testExplicitVRBigEndianProperties() {
        let syntax = DicomTransferSyntax.explicitVRBigEndian

        XCTAssertFalse(syntax.isCompressed, "Explicit VR BE should not be compressed")
        XCTAssertTrue(syntax.isBigEndian, "Explicit VR BE should be big endian")
        XCTAssertTrue(syntax.isExplicitVR, "Explicit VR BE should be explicit VR")
        XCTAssertEqual(syntax.rawValue, "1.2.840.10008.1.2.2", "Should have correct UID")
    }

    func testExplicitVRBigEndianMatching() {
        let syntax = DicomTransferSyntax.explicitVRBigEndian

        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.2"), "Should match exact UID")
        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.2\n"), "Should match UID with newline")
        XCTAssertFalse(syntax.matches("1.2.840.10008.1.2"), "Should not match implicit VR UID")
        XCTAssertFalse(syntax.matches("1.2.840.10008.1.2.1"), "Should not match little endian UID")
    }

    func testDecoderParsesExplicitVRBigEndianDatasetAfterTransferSyntax() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("explicit_big_endian_\(UUID().uuidString).dcm")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        try makeExplicitVRBigEndianDICOM().write(to: tempFile)

        let decoder = try DCMDecoder(contentsOf: tempFile)

        XCTAssertFalse(decoder.currentLittleEndian(), "Dataset should switch to big-endian parsing")
        XCTAssertEqual(decoder.width, 2, "Columns should be parsed from big-endian US value")
        XCTAssertEqual(decoder.height, 2, "Rows should be parsed from big-endian US value")
        XCTAssertEqual(decoder.info(for: .modality), "CT", "First big-endian dataset tag should keep its VR/length")
        let pixels = try XCTUnwrap(decoder.getPixels16())
        XCTAssertEqual(pixels, [1, 2, 3, 4], "Pixel data should be read using big-endian byte order")
    }

    // MARK: - Compressed Transfer Syntax Tests

    func test_oversizedFileMetaGroupLength_preservesLegacyBigEndianFallback() throws {
        var data = makeExplicitVRBigEndianDICOM()
        var groupLength = Data()
        appendExplicitVRTag(to: &groupLength, group: 0x0002, element: 0x0000, vr: "UL",
                            value: Data(repeating: 0xFF, count: 4), littleEndian: true)
        // Legacy headers may place Group Length after the Transfer Syntax element.
        let transferSyntaxEnd = 140 + Int(data.dicomInteger(at: 138, as: UInt16.self, littleEndian: true))
        data.insert(contentsOf: groupLength, at: transferSyntaxEnd)

        let decoder = try DCMDecoder(data: data)

        XCTAssertFalse(decoder.currentLittleEndian())
        XCTAssertEqual(decoder.width, 2)
        XCTAssertEqual(decoder.height, 2)
        XCTAssertEqual(decoder.info(for: .modality), "CT")
        XCTAssertEqual(decoder.getPixels16(), [1, 2, 3, 4])
    }

    func testJPEGBaselineProperties() {
        let syntax = DicomTransferSyntax.jpegBaseline

        XCTAssertTrue(syntax.isCompressed, "JPEG Baseline should be compressed")
        XCTAssertFalse(syntax.isBigEndian, "JPEG Baseline should be little endian")
        XCTAssertTrue(syntax.isExplicitVR, "JPEG Baseline should be explicit VR")
        XCTAssertEqual(syntax.rawValue, "1.2.840.10008.1.2.4.50", "Should have correct UID")
    }

    func testJPEGExtendedProperties() {
        let syntax = DicomTransferSyntax.jpegExtended

        XCTAssertTrue(syntax.isCompressed, "JPEG Extended should be compressed")
        XCTAssertFalse(syntax.isBigEndian, "JPEG Extended should be little endian")
        XCTAssertTrue(syntax.isExplicitVR, "JPEG Extended should be explicit VR")
        XCTAssertEqual(syntax.rawValue, "1.2.840.10008.1.2.4.51", "Should have correct UID")
    }

    func testJPEGLosslessProperties() {
        let syntax = DicomTransferSyntax.jpegLossless

        XCTAssertTrue(syntax.isCompressed, "JPEG Lossless should be compressed")
        XCTAssertFalse(syntax.isBigEndian, "JPEG Lossless should be little endian")
        XCTAssertTrue(syntax.isExplicitVR, "JPEG Lossless should be explicit VR")
        XCTAssertEqual(syntax.rawValue, "1.2.840.10008.1.2.4.57", "Should have correct UID")
    }

    func testJPEGLosslessFirstOrderProperties() {
        let syntax = DicomTransferSyntax.jpegLosslessFirstOrder

        XCTAssertTrue(syntax.isCompressed, "JPEG Lossless First Order should be compressed")
        XCTAssertFalse(syntax.isBigEndian, "JPEG Lossless First Order should be little endian")
        XCTAssertTrue(syntax.isExplicitVR, "JPEG Lossless First Order should be explicit VR")
        XCTAssertEqual(syntax.rawValue, "1.2.840.10008.1.2.4.70", "Should have correct UID")
    }

    func testJPEGLSLosslessProperties() {
        let syntax = DicomTransferSyntax.jpegLSLossless

        XCTAssertTrue(syntax.isCompressed, "JPEG-LS Lossless should be compressed")
        XCTAssertFalse(syntax.isBigEndian, "JPEG-LS Lossless should be little endian")
        XCTAssertTrue(syntax.isExplicitVR, "JPEG-LS Lossless should be explicit VR")
        XCTAssertEqual(syntax.rawValue, "1.2.840.10008.1.2.4.80", "Should have correct UID")
    }

    func testJPEGLSNearLosslessProperties() {
        let syntax = DicomTransferSyntax.jpegLSNearLossless

        XCTAssertTrue(syntax.isCompressed, "JPEG-LS Near-Lossless should be compressed")
        XCTAssertFalse(syntax.isBigEndian, "JPEG-LS Near-Lossless should be little endian")
        XCTAssertTrue(syntax.isExplicitVR, "JPEG-LS Near-Lossless should be explicit VR")
        XCTAssertEqual(syntax.rawValue, "1.2.840.10008.1.2.4.81", "Should have correct UID")
    }

    func testJPEG2000LosslessProperties() {
        let syntax = DicomTransferSyntax.jpeg2000Lossless

        XCTAssertTrue(syntax.isCompressed, "JPEG 2000 Lossless should be compressed")
        XCTAssertFalse(syntax.isBigEndian, "JPEG 2000 Lossless should be little endian")
        XCTAssertTrue(syntax.isExplicitVR, "JPEG 2000 Lossless should be explicit VR")
        XCTAssertEqual(syntax.rawValue, "1.2.840.10008.1.2.4.90", "Should have correct UID")
    }

    func testJPEG2000Properties() {
        let syntax = DicomTransferSyntax.jpeg2000

        XCTAssertTrue(syntax.isCompressed, "JPEG 2000 should be compressed")
        XCTAssertFalse(syntax.isBigEndian, "JPEG 2000 should be little endian")
        XCTAssertTrue(syntax.isExplicitVR, "JPEG 2000 should be explicit VR")
        XCTAssertEqual(syntax.rawValue, "1.2.840.10008.1.2.4.91", "Should have correct UID")
    }

    func testJPEG2000Part2MulticomponentProperties() {
        let syntaxes: [(DicomTransferSyntax, String)] = [
            (.jpeg2000Part2MulticomponentLossless, "1.2.840.10008.1.2.4.92"),
            (.jpeg2000Part2Multicomponent, "1.2.840.10008.1.2.4.93")
        ]

        for (syntax, uid) in syntaxes {
            XCTAssertTrue(syntax.isCompressed, "\(syntax) should be compressed")
            XCTAssertFalse(syntax.isBigEndian, "\(syntax) should be little endian")
            XCTAssertTrue(syntax.isExplicitVR, "\(syntax) should be explicit VR")
            XCTAssertEqual(syntax.rawValue, uid, "\(syntax) should have correct UID")
        }
    }

    func testHTJ2KProperties() {
        let syntaxes: [(DicomTransferSyntax, String)] = [
            (.htj2kLossless, "1.2.840.10008.1.2.4.201"),
            (.htj2kLosslessRPCL, "1.2.840.10008.1.2.4.202"),
            (.htj2k, "1.2.840.10008.1.2.4.203")
        ]

        for (syntax, uid) in syntaxes {
            XCTAssertTrue(syntax.isCompressed, "\(syntax) should be compressed")
            XCTAssertFalse(syntax.isBigEndian, "\(syntax) should be little endian")
            XCTAssertTrue(syntax.isExplicitVR, "\(syntax) should be explicit VR")
            XCTAssertEqual(syntax.rawValue, uid, "\(syntax) should have correct UID")
        }
    }

    func testRLELosslessProperties() {
        let syntax = DicomTransferSyntax.rleLossless

        XCTAssertTrue(syntax.isCompressed, "RLE Lossless should be compressed")
        XCTAssertFalse(syntax.isBigEndian, "RLE Lossless should be little endian")
        XCTAssertTrue(syntax.isExplicitVR, "RLE Lossless should be explicit VR")
        XCTAssertEqual(syntax.rawValue, "1.2.840.10008.1.2.5", "Should have correct UID")
    }

    // MARK: - Compressed Transfer Syntax Matching Tests

    func testJPEGBaselineMatching() {
        let syntax = DicomTransferSyntax.jpegBaseline

        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.4.50"), "Should match exact UID")
        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.4.50  "), "Should match UID with trailing spaces")
        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.4.50\0"), "Should match UID with null terminator")
        XCTAssertFalse(syntax.matches("1.2.840.10008.1.2.4.51"), "Should not match different UID")
    }

    func testJPEGExtendedMatching() {
        let syntax = DicomTransferSyntax.jpegExtended

        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.4.51"), "Should match exact UID")
        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.4.51\n"), "Should match UID with newline")
        XCTAssertFalse(syntax.matches("1.2.840.10008.1.2.4.50"), "Should not match JPEG Baseline UID")
    }

    func testJPEGLosslessMatching() {
        let syntax = DicomTransferSyntax.jpegLossless

        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.4.57"), "Should match exact UID")
        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.4.57 "), "Should match UID with trailing space")
        XCTAssertFalse(syntax.matches("1.2.840.10008.1.2.4.70"), "Should not match First Order UID")
    }

    func testJPEGLosslessFirstOrderMatching() {
        let syntax = DicomTransferSyntax.jpegLosslessFirstOrder

        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.4.70"), "Should match exact UID")
        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.4.70\t"), "Should match UID with tab")
        XCTAssertFalse(syntax.matches("1.2.840.10008.1.2.4.57"), "Should not match JPEG Lossless UID")
    }

    func testJPEGLSLosslessMatching() {
        let syntax = DicomTransferSyntax.jpegLSLossless

        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.4.80"), "Should match exact UID")
        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.4.80  "), "Should match UID with trailing spaces")
        XCTAssertFalse(syntax.matches("1.2.840.10008.1.2.4.81"), "Should not match Near-Lossless UID")
    }

    func testJPEGLSNearLosslessMatching() {
        let syntax = DicomTransferSyntax.jpegLSNearLossless

        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.4.81"), "Should match exact UID")
        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.4.81\r\n"), "Should match UID with CRLF")
        XCTAssertFalse(syntax.matches("1.2.840.10008.1.2.4.80"), "Should not match Lossless UID")
    }

    func testJPEG2000LosslessMatching() {
        let syntax = DicomTransferSyntax.jpeg2000Lossless

        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.4.90"), "Should match exact UID")
        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.4.90 "), "Should match UID with trailing space")
        XCTAssertFalse(syntax.matches("1.2.840.10008.1.2.4.91"), "Should not match JPEG 2000 lossy UID")
    }

    func testJPEG2000Matching() {
        let syntax = DicomTransferSyntax.jpeg2000

        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.4.91"), "Should match exact UID")
        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.4.91\n"), "Should match UID with newline")
        XCTAssertFalse(syntax.matches("1.2.840.10008.1.2.4.90"), "Should not match lossless UID")
    }

    func testJPEG2000Part2MulticomponentMatching() {
        XCTAssertTrue(DicomTransferSyntax.jpeg2000Part2MulticomponentLossless.matches("1.2.840.10008.1.2.4.92"))
        XCTAssertTrue(DicomTransferSyntax.jpeg2000Part2Multicomponent.matches("1.2.840.10008.1.2.4.93  "))
        XCTAssertFalse(DicomTransferSyntax.jpeg2000Part2Multicomponent.matches("1.2.840.10008.1.2.4.92"))
    }

    func testHTJ2KMatching() {
        XCTAssertTrue(DicomTransferSyntax.htj2kLossless.matches("1.2.840.10008.1.2.4.201"))
        XCTAssertTrue(DicomTransferSyntax.htj2kLosslessRPCL.matches("1.2.840.10008.1.2.4.202  "))
        XCTAssertTrue(DicomTransferSyntax.htj2k.matches("1.2.840.10008.1.2.4.203\n"))
        XCTAssertFalse(DicomTransferSyntax.htj2k.matches("1.2.840.10008.1.2.4.201"))
    }

    func testRLELosslessMatching() {
        let syntax = DicomTransferSyntax.rleLossless

        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.5"), "Should match exact UID")
        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.5  "), "Should match UID with trailing spaces")
        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2.5\0"), "Should match UID with null terminator")
        XCTAssertFalse(syntax.matches("1.2.840.10008.1.2.4.91"), "Should not match JPEG 2000 UID")
    }

    // MARK: - Compressed Transfer Syntax Initialization Tests

    func testCompressedTransferSyntaxInitializationFromUID() {
        // Test JPEG variants
        let jpegBaseline = DicomTransferSyntax(uid: "1.2.840.10008.1.2.4.50")
        XCTAssertEqual(jpegBaseline, .jpegBaseline, "Should initialize JPEG Baseline")

        let jpegExtended = DicomTransferSyntax(uid: "1.2.840.10008.1.2.4.51")
        XCTAssertEqual(jpegExtended, .jpegExtended, "Should initialize JPEG Extended")

        let jpegLossless = DicomTransferSyntax(uid: "1.2.840.10008.1.2.4.57")
        XCTAssertEqual(jpegLossless, .jpegLossless, "Should initialize JPEG Lossless")

        let jpegLosslessFirstOrder = DicomTransferSyntax(uid: "1.2.840.10008.1.2.4.70")
        XCTAssertEqual(jpegLosslessFirstOrder, .jpegLosslessFirstOrder, "Should initialize JPEG Lossless First Order")

        // Test JPEG-LS variants
        let jpegLSLossless = DicomTransferSyntax(uid: "1.2.840.10008.1.2.4.80")
        XCTAssertEqual(jpegLSLossless, .jpegLSLossless, "Should initialize JPEG-LS Lossless")

        let jpegLSNearLossless = DicomTransferSyntax(uid: "1.2.840.10008.1.2.4.81")
        XCTAssertEqual(jpegLSNearLossless, .jpegLSNearLossless, "Should initialize JPEG-LS Near-Lossless")

        // Test JPEG 2000 variants
        let jpeg2000Lossless = DicomTransferSyntax(uid: "1.2.840.10008.1.2.4.90")
        XCTAssertEqual(jpeg2000Lossless, .jpeg2000Lossless, "Should initialize JPEG 2000 Lossless")

        let jpeg2000 = DicomTransferSyntax(uid: "1.2.840.10008.1.2.4.91")
        XCTAssertEqual(jpeg2000, .jpeg2000, "Should initialize JPEG 2000")

        let jpeg2000Part2Lossless = DicomTransferSyntax(uid: "1.2.840.10008.1.2.4.92")
        XCTAssertEqual(jpeg2000Part2Lossless, .jpeg2000Part2MulticomponentLossless, "Should initialize JPEG 2000 Part 2 lossless")

        let jpeg2000Part2 = DicomTransferSyntax(uid: "1.2.840.10008.1.2.4.93")
        XCTAssertEqual(jpeg2000Part2, .jpeg2000Part2Multicomponent, "Should initialize JPEG 2000 Part 2")

        // Test HTJ2K variants
        let htj2kLossless = DicomTransferSyntax(uid: "1.2.840.10008.1.2.4.201")
        XCTAssertEqual(htj2kLossless, .htj2kLossless, "Should initialize HTJ2K Lossless")

        let htj2kLosslessRPCL = DicomTransferSyntax(uid: "1.2.840.10008.1.2.4.202")
        XCTAssertEqual(htj2kLosslessRPCL, .htj2kLosslessRPCL, "Should initialize HTJ2K Lossless RPCL")

        let htj2k = DicomTransferSyntax(uid: "1.2.840.10008.1.2.4.203")
        XCTAssertEqual(htj2k, .htj2k, "Should initialize HTJ2K")

        // Test RLE
        let rleLossless = DicomTransferSyntax(uid: "1.2.840.10008.1.2.5")
        XCTAssertEqual(rleLossless, .rleLossless, "Should initialize RLE Lossless")
    }

    func testCompressedTransferSyntaxInitializationWithWhitespace() {
        // Test JPEG with whitespace
        let jpegWithSpaces = DicomTransferSyntax(uid: "1.2.840.10008.1.2.4.50  ")
        XCTAssertEqual(jpegWithSpaces, .jpegBaseline, "Should handle trailing spaces")

        let jpegWithNewline = DicomTransferSyntax(uid: "1.2.840.10008.1.2.4.91\n")
        XCTAssertEqual(jpegWithNewline, .jpeg2000, "Should handle trailing newline")

        let rleWithNull = DicomTransferSyntax(uid: "1.2.840.10008.1.2.5\0")
        XCTAssertEqual(rleWithNull, .rleLossless, "Should handle null terminator")

        let jpegLSWithCRLF = DicomTransferSyntax(uid: "1.2.840.10008.1.2.4.80\r\n")
        XCTAssertEqual(jpegLSWithCRLF, .jpegLSLossless, "Should handle CRLF")
    }

    // MARK: - Transfer Syntax Detection Tests

    func testUncompressedTransferSyntaxes() {
        let uncompressedSyntaxes: [DicomTransferSyntax] = [
            .implicitVRLittleEndian,
            .explicitVRLittleEndian,
            .explicitVRBigEndian
        ]

        for syntax in uncompressedSyntaxes {
            XCTAssertFalse(syntax.isCompressed, "\(syntax) should not be compressed")
        }
    }

    func testCompressedTransferSyntaxes() {
        let compressedSyntaxes: [DicomTransferSyntax] = [
            .deflatedExplicitVRLittleEndian,
            .jpegBaseline,
            .jpegExtended,
            .jpegLossless,
            .jpegLosslessFirstOrder,
            .jpegLSLossless,
            .jpegLSNearLossless,
            .jpeg2000Lossless,
            .jpeg2000,
            .jpeg2000Part2MulticomponentLossless,
            .jpeg2000Part2Multicomponent,
            .htj2kLossless,
            .htj2kLosslessRPCL,
            .htj2k,
            .rleLossless
        ]

        for syntax in compressedSyntaxes {
            XCTAssertTrue(syntax.isCompressed, "\(syntax) should be compressed")
        }
    }

    func testByteOrderDetection() {
        // Only Big Endian Explicit VR should be big endian
        XCTAssertTrue(DicomTransferSyntax.explicitVRBigEndian.isBigEndian, "Explicit VR BE should be big endian")

        // All others should be little endian
        let littleEndianSyntaxes: [DicomTransferSyntax] = [
            .implicitVRLittleEndian,
            .explicitVRLittleEndian,
            .deflatedExplicitVRLittleEndian,
            .jpegBaseline,
            .jpegExtended,
            .jpegLossless,
            .jpegLosslessFirstOrder,
            .jpegLSLossless,
            .jpegLSNearLossless,
            .jpeg2000Lossless,
            .jpeg2000,
            .jpeg2000Part2MulticomponentLossless,
            .jpeg2000Part2Multicomponent,
            .htj2kLossless,
            .htj2kLosslessRPCL,
            .htj2k,
            .rleLossless
        ]

        for syntax in littleEndianSyntaxes {
            XCTAssertFalse(syntax.isBigEndian, "\(syntax) should be little endian")
        }
    }

    func testVREncodingDetection() {
        // Only Implicit VR Little Endian should be implicit VR
        XCTAssertFalse(DicomTransferSyntax.implicitVRLittleEndian.isExplicitVR, "Implicit VR LE should be implicit VR")

        // All others should be explicit VR
        let explicitVRSyntaxes: [DicomTransferSyntax] = [
            .explicitVRLittleEndian,
            .deflatedExplicitVRLittleEndian,
            .explicitVRBigEndian,
            .jpegBaseline,
            .jpegExtended,
            .jpegLossless,
            .jpegLosslessFirstOrder,
            .jpegLSLossless,
            .jpegLSNearLossless,
            .jpeg2000Lossless,
            .jpeg2000,
            .jpeg2000Part2MulticomponentLossless,
            .jpeg2000Part2Multicomponent,
            .htj2kLossless,
            .htj2kLosslessRPCL,
            .htj2k,
            .rleLossless
        ]

        for syntax in explicitVRSyntaxes {
            XCTAssertTrue(syntax.isExplicitVR, "\(syntax) should be explicit VR")
        }
    }

    // MARK: - Decoder Transfer Syntax Integration Tests

    func testDecoderInitialTransferSyntaxState() {
        let decoder = DCMDecoder()

        // Decoder should initialize with no compression
        XCTAssertFalse(decoder.compressedImage, "New decoder should not have compressed image")

        // Note: transferSyntaxUID is private in DCMDecoder, so we can't directly test it
        // but we can verify the decoder's initial state related to transfer syntax
    }

    func testDecoderCompressedImageDetection() {
        let decoder = DCMDecoder()

        // Initial state should be uncompressed
        XCTAssertFalse(decoder.compressedImage, "Initial decoder should not be compressed")

        // Validation status should reflect uncompressed state
        let status = decoder.getValidationStatus()
        XCTAssertFalse(status.isCompressed, "Initial validation status should show uncompressed")
    }

    // MARK: - Edge Cases

    func testTransferSyntaxMatchingWithVariations() {
        let syntax = DicomTransferSyntax.implicitVRLittleEndian

        // Test various whitespace and padding scenarios
        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2"), "Should match clean UID")
        XCTAssertTrue(syntax.matches(" 1.2.840.10008.1.2"), "Should match UID with leading space")
        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2 "), "Should match UID with trailing space")
        XCTAssertTrue(syntax.matches(" 1.2.840.10008.1.2 "), "Should match UID with both spaces")
        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2\t"), "Should match UID with tab")
        XCTAssertTrue(syntax.matches("1.2.840.10008.1.2\r\n"), "Should match UID with CRLF")
    }

    func testAllTransferSyntaxesHaveValidUIDs() {
        let allSyntaxes: [DicomTransferSyntax] = [
            .implicitVRLittleEndian,
            .explicitVRLittleEndian,
            .explicitVRBigEndian,
            .deflatedExplicitVRLittleEndian,
            .jpegBaseline,
            .jpegExtended,
            .jpegLossless,
            .jpegLosslessFirstOrder,
            .jpegLSLossless,
            .jpegLSNearLossless,
            .jpeg2000Lossless,
            .jpeg2000,
            .jpeg2000Part2MulticomponentLossless,
            .jpeg2000Part2Multicomponent,
            .htj2kLossless,
            .htj2kLosslessRPCL,
            .htj2k,
            .rleLossless
        ]

        for syntax in allSyntaxes {
            XCTAssertFalse(syntax.rawValue.isEmpty, "\(syntax) should have non-empty UID")
            XCTAssertTrue(syntax.rawValue.hasPrefix("1.2.840.10008"), "\(syntax) should have valid DICOM UID prefix")
        }
    }

    func testTransferSyntaxRoundTrip() {
        let allSyntaxes: [DicomTransferSyntax] = [
            .implicitVRLittleEndian,
            .explicitVRLittleEndian,
            .explicitVRBigEndian,
            .deflatedExplicitVRLittleEndian,
            .jpegBaseline,
            .jpegExtended,
            .jpegLossless,
            .jpegLosslessFirstOrder,
            .jpegLSLossless,
            .jpegLSNearLossless,
            .jpeg2000Lossless,
            .jpeg2000,
            .jpeg2000Part2MulticomponentLossless,
            .jpeg2000Part2Multicomponent,
            .htj2kLossless,
            .htj2kLosslessRPCL,
            .htj2k,
            .rleLossless
        ]

        for syntax in allSyntaxes {
            // Test that we can round-trip: enum -> UID -> enum
            let uid = syntax.rawValue
            let reconstructed = DicomTransferSyntax(uid: uid)
            XCTAssertEqual(reconstructed, syntax, "\(syntax) should round-trip successfully")
        }
    }

    // MARK: - Performance Tests

    func testTransferSyntaxInitializationPerformance() {
        let uid = "1.2.840.10008.1.2.1"

        measure {
            for _ in 0..<10000 {
                _ = DicomTransferSyntax(uid: uid)
            }
        }
    }

    func testTransferSyntaxMatchingPerformance() {
        let syntax = DicomTransferSyntax.explicitVRLittleEndian
        let uid = "1.2.840.10008.1.2.1  "

        measure {
            for _ in 0..<10000 {
                _ = syntax.matches(uid)
            }
        }
    }

    func testTransferSyntaxPropertyAccessPerformance() {
        let syntaxes: [DicomTransferSyntax] = [
            .implicitVRLittleEndian,
            .explicitVRLittleEndian,
            .explicitVRBigEndian,
            .deflatedExplicitVRLittleEndian,
            .jpegBaseline,
            .jpeg2000
        ]

        measure {
            for _ in 0..<10000 {
                for syntax in syntaxes {
                    _ = syntax.isCompressed
                    _ = syntax.isBigEndian
                    _ = syntax.isExplicitVR
                }
            }
        }
    }

    private func makeExplicitVRBigEndianDICOM() -> Data {
        var data = Data(count: 128)
        data.append(contentsOf: "DICM".utf8)

        appendExplicitVRTag(
            to: &data,
            group: 0x0002,
            element: 0x0010,
            vr: "UI",
            value: Data("1.2.840.10008.1.2.2".utf8),
            littleEndian: true,
            paddingByte: 0x00
        )

        appendExplicitVRTag(
            to: &data,
            group: 0x0008,
            element: 0x0060,
            vr: "CS",
            value: Data("CT".utf8),
            littleEndian: false
        )
        appendExplicitVRTag(to: &data, group: 0x0028, element: 0x0002, vr: "US", value: bigEndianUInt16(1), littleEndian: false)
        appendExplicitVRTag(
            to: &data,
            group: 0x0028,
            element: 0x0004,
            vr: "CS",
            value: Data("MONOCHROME2".utf8),
            littleEndian: false
        )
        appendExplicitVRTag(to: &data, group: 0x0028, element: 0x0010, vr: "US", value: bigEndianUInt16(2), littleEndian: false)
        appendExplicitVRTag(to: &data, group: 0x0028, element: 0x0011, vr: "US", value: bigEndianUInt16(2), littleEndian: false)
        appendExplicitVRTag(to: &data, group: 0x0028, element: 0x0100, vr: "US", value: bigEndianUInt16(16), littleEndian: false)
        appendExplicitVRTag(to: &data, group: 0x0028, element: 0x0101, vr: "US", value: bigEndianUInt16(16), littleEndian: false)
        appendExplicitVRTag(to: &data, group: 0x0028, element: 0x0102, vr: "US", value: bigEndianUInt16(15), littleEndian: false)
        appendExplicitVRTag(to: &data, group: 0x0028, element: 0x0103, vr: "US", value: bigEndianUInt16(0), littleEndian: false)

        let pixels = Data([0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04])
        appendExplicitVRTag(to: &data, group: 0x7FE0, element: 0x0010, vr: "OW", value: pixels, littleEndian: false)

        return data
    }

    private func appendExplicitVRTag(
        to data: inout Data,
        group: UInt16,
        element: UInt16,
        vr: String,
        value: Data,
        littleEndian: Bool,
        paddingByte: UInt8 = 0x20
    ) {
        appendUInt16(group, to: &data, littleEndian: littleEndian)
        appendUInt16(element, to: &data, littleEndian: littleEndian)
        data.append(contentsOf: vr.utf8)

        let paddedLength = value.count + (value.count % 2)
        let longVRs = ["OB", "OW", "SQ", "UN", "UT"]
        if longVRs.contains(vr) {
            data.append(contentsOf: [0x00, 0x00])
            appendUInt32(UInt32(paddedLength), to: &data, littleEndian: littleEndian)
        } else {
            appendUInt16(UInt16(paddedLength), to: &data, littleEndian: littleEndian)
        }

        data.append(value)
        if value.count % 2 != 0 {
            data.append(paddingByte)
        }
    }

    private func bigEndianUInt16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data, littleEndian: Bool) {
        var encoded = littleEndian ? value.littleEndian : value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data, littleEndian: Bool) {
        var encoded = littleEndian ? value.littleEndian : value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
}
