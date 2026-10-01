import XCTest
@testable import DicomCore
import DicomData

final class DicomReformattedImageBuilderTests: XCTestCase {
    private func template(sopClass: String = DicomReformattedImageBuilder.ctImageStorage) -> DicomDataSet {
        func text(_ tag: Int, _ vr: DicomVR, _ value: String) -> DicomDataElement {
            .init(tag: tag, vr: vr, value: .strings([value]))
        }
        return DicomDataSet(elements: [
            text(0x0008_0008, .CS, "ORIGINAL"),
            text(0x0008_0016, .UI, sopClass),
            text(0x0008_0018, .UI, "1.2.3.4.5.100"),
            text(0x0008_0020, .DA, "20050101"),
            text(0x0008_0060, .CS, "CT"),
            text(0x0008_0070, .LO, "Scanner Maker"),
            text(0x0008_103E, .LO, "Head 1mm"),
            text(0x0009_0010, .LO, "PRIVATE CREATOR"),
            text(0x0010_0010, .PN, "Doe^Jane"),
            text(0x0010_0020, .LO, "P-1"),
            text(0x0018_0050, .DS, "1"),
            text(0x0018_0060, .DS, "120"),
            text(0x0018_5100, .CS, "HFS"),
            text(0x0020_000D, .UI, "1.2.3.4.5"),
            text(0x0020_000E, .UI, "1.2.3.4.5.1"),
            text(0x0020_0011, .IS, "3"),
            text(0x0020_0013, .IS, "42"),
            .init(tag: 0x0020_0020, vr: .CS, value: .strings(["L", "P"])),
            .init(tag: 0x0020_0032, vr: .DS, value: .strings(["0", "0", "0"])),
            text(0x0020_0052, .UI, "1.2.3.4.5.9"),
            .init(tag: 0x0028_0010, vr: .US, value: .unsignedIntegers([512])),
            text(0x0028_1052, .DS, "-1024"),
            text(0x0028_1053, .DS, "1"),
            text(0x0028_1054, .LO, "HU"),
            text(0x0028_2110, .CS, "00")
        ])
    }

    private func request(samples: [Float], kind: DicomReformattedImageRequest.SampleKind,
                         projection: DicomReformattedImageRequest.Projection = .none,
                         template: DicomDataSet? = nil) -> DicomReformattedImageRequest {
        DicomReformattedImageRequest(
            template: template ?? self.template(), sopInstanceUID: "2.25.1001", seriesInstanceUID: "2.25.1000",
            frameOfReferenceUID: "1.2.3.4.5.9", seriesNumber: 9_101, instanceNumber: 7,
            seriesDescription: "MPR oblique 3 mm", columns: 3, rows: 2, pixelSpacing: 0.625,
            imagePosition: [-12.5, 40.25, 1_000.125],
            rowDirection: [1, 0, 0], columnDirection: [0, 0.8660254037844387, -0.5],
            sliceThickness: 3, spacingBetweenSlices: 1.5, projection: projection,
            samples: samples, sampleKind: kind, windowCenter: 40, windowWidth: 400,
            sourceInstances: [.init(sopClassUID: DicomReformattedImageBuilder.ctImageStorage, sopInstanceUID: "1.2.3.4.5.100"),
                              .init(sopClassUID: DicomReformattedImageBuilder.ctImageStorage, sopInstanceUID: "1.2.3.4.5.101")],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func reopen(_ image: DicomReformattedImage) throws -> (dataSet: DicomDataSet, pixels: Data) {
        let meta = try DicomPart10FileMetaParser.parse(image.data)
        XCTAssertEqual(meta.transferSyntaxUID, "1.2.840.10008.1.2.1")
        let body = Data(image.data[(image.data.startIndex + meta.dataSetOffset)...])
        let dataSet = try DicomDataSetParser.dataSet(from: body, transferSyntax: .explicitVRLittleEndian)
        // Pixel Data is the last element: tag, "OW", reserved, 32-bit length.
        let count = 3 * 2 * 2
        return (dataSet, Data(image.data.suffix(count)))
    }

    func test_aCTReformat_keepsTheContext_andReplacesIdentityGeometryAndPixels() throws {
        let image = try DicomReformattedImageBuilder.image(request(samples: [-1_000, -0.4, 0.6, 40, 3_071, 99_999], kind: .signedInteger))
        XCTAssertEqual(image.sopClassUID, DicomReformattedImageBuilder.ctImageStorage)
        let (dataSet, pixels) = try reopen(image)

        XCTAssertEqual(dataSet.string(for: 0x0010_0010), "Doe^Jane")
        XCTAssertEqual(dataSet.string(for: 0x0020_000D), "1.2.3.4.5", "same study")
        XCTAssertEqual(dataSet.string(for: 0x0018_0060), "120", "the acquisition's context stays")
        XCTAssertEqual(dataSet.string(for: 0x0018_5100), "HFS", "the patient's acquisition position stays")
        XCTAssertNil(dataSet[0x0020_0020], "the source image's patient orientation does not describe the reformat")
        XCTAssertEqual(dataSet.string(for: 0x0020_0052), "1.2.3.4.5.9", "same frame of reference")
        XCTAssertNil(dataSet[0x0009_0010], "private elements of the source do not vouch for these pixels")

        XCTAssertEqual(dataSet.string(for: 0x0008_0018), "2.25.1001")
        XCTAssertEqual(dataSet.string(for: 0x0020_000E), "2.25.1000")
        XCTAssertEqual(dataSet.strings(for: 0x0008_0008), ["DERIVED", "SECONDARY", "REFORMATTED"])
        XCTAssertEqual(dataSet.string(for: 0x0008_103E), "MPR oblique 3 mm")
        XCTAssertEqual(dataSet.string(for: 0x0020_0013), "7")
        XCTAssertEqual(dataSet.strings(for: 0x0020_0032), ["-12.5", "40.25", "1000.125"])
        // A Decimal String holds 16 characters: the direction keeps 14 significant digits.
        for (text, expected) in zip(dataSet.strings(for: 0x0020_0037), [1, 0, 0, 0, 0.8660254037844387, -0.5]) {
            XCTAssertEqual(Double(text)!, expected, accuracy: 1e-13)
        }
        XCTAssertTrue(dataSet.strings(for: 0x0020_0037).allSatisfy { $0.count <= 16 })
        XCTAssertEqual(dataSet.strings(for: 0x0028_0030), ["0.625", "0.625"])
        XCTAssertEqual(dataSet.string(for: 0x0018_0050), "3")
        XCTAssertEqual(dataSet.string(for: 0x0018_0088), "1.5")
        XCTAssertEqual(dataSet.string(for: 0x0028_1052), "0", "the values are already modality values")
        XCTAssertEqual(dataSet.string(for: 0x0028_1053), "1")
        XCTAssertEqual(dataSet.string(for: 0x0028_1054), "HU")
        XCTAssertEqual(dataSet.string(for: 0x0028_0004), "MONOCHROME2")
        XCTAssertEqual(dataSet.string(for: 0x0028_2110), "00")
        XCTAssertEqual(dataSet.string(for: 0x0028_1050), "40")

        guard case .sequence(let sources)? = dataSet[0x0008_2112]?.value else { return XCTFail("no Source Image Sequence") }
        XCTAssertEqual(sources.map { $0.dataSet.string(for: 0x0008_1155) }, ["1.2.3.4.5.100", "1.2.3.4.5.101"])
        guard case .sequence(let codes)? = dataSet[0x0008_9215]?.value else { return XCTFail("no Derivation Code Sequence") }
        XCTAssertEqual(codes.first?.dataSet.string(for: 0x0008_0100), "113072")

        let words = pixels.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(words, [-1_000, 0, 1, 40, 3_071, 32_767], "rounded, and clamped to what 16 bits hold")
    }

    func test_aDerivationNote_followsTheReformatsOwnDescription() throws {
        var withNote = request(samples: [0, 1, 2, 3, 4, 5], kind: .signedInteger)
        withNote.derivationNote = "Source slice interval 2.50 mm entered by the user."
        let noted = try reopen(try DicomReformattedImageBuilder.image(withNote)).dataSet.string(for: 0x0008_2111) ?? ""
        XCTAssertTrue(noted.hasPrefix("Multiplanar reformat of the source series"), noted)
        XCTAssertTrue(noted.hasSuffix("trilinear interpolation. Source slice interval 2.50 mm entered by the user."), noted)

        let plain = try reopen(try DicomReformattedImageBuilder.image(request(samples: [0, 1, 2, 3, 4, 5], kind: .signedInteger)))
        XCTAssertTrue(plain.dataSet.string(for: 0x0008_2111)?.hasSuffix("trilinear interpolation.") == true)
    }

    /// Issue #2863: no Image Type term names a ray sum; the derivation description says what the values are.
    func test_aSumSlab_isDescribedInTheDerivation_withoutAnImageTypeTerm() throws {
        let dataSet = try reopen(try DicomReformattedImageBuilder.image(
            request(samples: [0, 1, 2, 3, 4, 5], kind: .signedInteger, projection: .sum))).dataSet
        XCTAssertEqual(dataSet.strings(for: 0x0008_0008), ["DERIVED", "SECONDARY", "REFORMATTED"])
        let description = dataSet.string(for: 0x0008_2111) ?? ""
        XCTAssertTrue(description.contains("sum of the values above the volume's minimum, divided by the slab thickness"),
                      description)
    }

    func test_longDerivationNote_limitsTheWholeDescriptionTo1024Scalars() throws {
        var value = request(samples: [0, 1, 2, 3, 4, 5], kind: .signedInteger, projection: .maximum)
        value.template.set(.init(tag: 0x0008_0005, vr: .CS, value: .strings(["ISO_IR 192"])))
        let plain = try XCTUnwrap(reopen(DicomReformattedImageBuilder.image(value)).dataSet.string(for: 0x0008_2111))
        let note = String(repeating: "e\u{301}", count: 1_024)
        value.derivationNote = " \n" + note + " \n"
        let description = try XCTUnwrap(reopen(DicomReformattedImageBuilder.image(value)).dataSet.string(for: 0x0008_2111))
        XCTAssertEqual(description.unicodeScalars.count, 1_024)
        XCTAssertEqual(description, plain + " " + String(note.unicodeScalars.prefix(1_024 - plain.unicodeScalars.count - 1)))
        value.derivationNote = " \n "
        XCTAssertEqual(try reopen(DicomReformattedImageBuilder.image(value)).dataSet.string(for: 0x0008_2111), plain)
    }

    func test_realValues_getTheirOwnRescale_andComeBackWithinOneStep() throws {
        let samples: [Float] = [0, 0.5, 1.25, 2, 7.75, 10]
        var pet = template(sopClass: DicomReformattedImageBuilder.petImageStorage)
        pet.set(.init(tag: 0x0054_1001, vr: .CS, value: .strings(["BQML"])))
        var petRequest = request(samples: samples, kind: .real, projection: .maximum, template: pet)
        petRequest.units = "GML"
        let image = try DicomReformattedImageBuilder.image(petRequest)
        let (dataSet, pixels) = try reopen(image)
        XCTAssertEqual(dataSet.string(for: 0x0028_0103), "0")
        XCTAssertEqual(dataSet.string(for: 0x0054_1001), "GML", "the units are those of the values written")
        XCTAssertEqual(dataSet.strings(for: 0x0008_0008).last, "MAX_IP")
        let slope = Double(dataSet.string(for: 0x0028_1053)!)!
        let intercept = Double(dataSet.string(for: 0x0028_1052)!)!
        XCTAssertEqual(slope, image.rescaleSlope, accuracy: slope * 1e-6)
        let words = pixels.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        for (word, sample) in zip(words, samples) {
            XCTAssertEqual(Double(word) * slope + intercept, Double(sample), accuracy: slope)
        }
    }

    func test_whatCannotBeWrittenIsRefused() {
        let enhanced = template(sopClass: "1.2.840.10008.5.1.4.1.1.2.1")
        XCTAssertThrowsError(try DicomReformattedImageBuilder.image(request(samples: Array(repeating: 0, count: 6), kind: .signedInteger, template: enhanced))) {
            XCTAssertEqual($0 as? DicomReformattedImageError, .unsupportedSourceSOPClass("1.2.840.10008.5.1.4.1.1.2.1"))
        }
        XCTAssertThrowsError(try DicomReformattedImageBuilder.image(request(samples: [1, 2], kind: .signedInteger))) {
            XCTAssertEqual($0 as? DicomReformattedImageError, .sampleCountMismatch(expected: 6, actual: 2))
        }
        var bad = request(samples: Array(repeating: 0, count: 6), kind: .signedInteger)
        bad.pixelSpacing = 0
        XCTAssertThrowsError(try DicomReformattedImageBuilder.image(bad))
    }

    func test_decimalText_fitsADecimalString() {
        XCTAssertEqual(DicomReformattedImageBuilder.decimalText(3), "3")
        XCTAssertEqual(DicomReformattedImageBuilder.decimalText(-0.5), "-0.5")
        for value in [Double.pi * 1e-7, -123_456.789_012_345_6, 1.0 / 3.0, 6.02e23] {
            let text = DicomReformattedImageBuilder.decimalText(value)
            XCTAssertLessThanOrEqual(text.count, 16, text)
            XCTAssertEqual(Double(text)!, value, accuracy: abs(value) * 1e-8)
        }
    }
}
