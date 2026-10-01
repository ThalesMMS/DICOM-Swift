import Foundation
import XCTest
@testable import DicomData

final class DicomContextualVRTests: XCTestCase {
    func test_voiRescaleContext_doesNotRepairInvalidDecimalDiscriminators() {
        for tag in [0x00281052, 0x00281053] {
            for value in ["\t1", "1\n", String(repeating: " ", count: 16) + "1", "1E-999", "1E999"] {
                var source = DicomDataSet(elements: [
                    unsigned(0x00280101, [12]), unsigned(0x00280103, [0]),
                    .init(tag: 0x00281052, vr: .DS, value: .strings(["0"])),
                    .init(tag: 0x00281053, vr: .DS, value: .strings(["1"]))
                ])
                source.set(.init(tag: tag, vr: .DS, value: .strings([value])))
                XCTAssertNil(DicomPixelValueContext(source).voiInputVR, "tag \(tag)")
            }
        }
    }

    func test_implicitSignedValues_resolveLaterParentContextAndItemOverrides() throws {
        let inherited = DicomDataSet(elements: [signed(0x00280120, [-9])])
        let overridden = DicomDataSet(elements: [unsigned(0x00280103, [0]), unsigned(0x00280120, [65000])])
        let source = DicomDataSet(elements: [
            .init(tag: 0x00081032, vr: .SQ, value: .sequence([.init(dataSet: inherited), .init(dataSet: overridden)])),
            signed(0x00189810, [-3]), unsigned(0x00280103, [1]), signed(0x00280120, [-1024])
        ])
        let bytes = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: .implicitVRLittleEndian)
        let parsed = try DicomDataSetParser.read(from: bytes, transferSyntax: .implicitVRLittleEndian)
        XCTAssertEqual(parsed.dataSet, source)
        XCTAssertTrue(parsed.diagnostics.isEmpty)
        try export(source, name: "context-implicit", syntax: .implicitVRLittleEndian)
    }

    func test_signedLUTDescriptor_preservesUnsignedFirstAndThirdWords() throws {
        let source = DicomDataSet(elements: [unsigned(0x00280103, [1]), signed(0x00283002, [65535, -1, 16])])
        for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .explicitVRBigEndian, .implicitVRLittleEndian] {
            let bytes = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: syntax)
            XCTAssertEqual(try DicomDataSetParser.read(from: bytes, transferSyntax: syntax).dataSet, source)
            try export(source, name: "lut-\(syntax.isBigEndian ? "be" : (syntax.isExplicitVR ? "le" : "implicit"))", syntax: syntax)
        }
    }

    func test_retiredLargeDescriptors_doNotBorrowThreeWordOrPixelSignRules() throws {
        for tag in [0x00281111, 0x00281112, 0x00281113] {
            let source = DicomDataSet(elements: [unsigned(0x00280103, [1]), signed(tag, [-1, -2, 16, 1])])
            for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .explicitVRBigEndian] {
                let bytes = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: syntax)
                XCTAssertEqual(try DicomDataSetParser.read(from: bytes, transferSyntax: syntax).dataSet, source)
            }
            let implicit = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: .implicitVRLittleEndian)
            XCTAssertThrowsError(try DicomDataSetParser.read(from: implicit, transferSyntax: .implicitVRLittleEndian))
            let recovered = try DicomDataSetParser.read(from: implicit, transferSyntax: .implicitVRLittleEndian, mode: .recover)
            XCTAssertEqual(recovered.diagnostics.map(\.reason), [.ambiguousVR])
            XCTAssertEqual(recovered.dataSet[tag]?.vr, .UN)
            XCTAssertEqual(recovered.dataSet[tag]?.bytesValue, Data([0xFF, 0xFF, 0xFE, 0xFF, 16, 0, 1, 0]))
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: .init(elements: [signed(tag, [65535, -1, 16])])))
        }
    }

    func test_explicitVR_conflictingWithPixelContextIsRejected() throws {
        let source = DicomDataSet(elements: [unsigned(0x00280103, [1]), unsigned(0x00280120, [65000])])
        let bytes = try DicomDataSetWriter.dataSetData(from: source)
        XCTAssertThrowsError(try DicomDataSetParser.read(from: bytes))
        let recovered = try DicomDataSetParser.read(from: bytes, mode: .recover)
        XCTAssertEqual(recovered.dataSet[0x00280120]?.vr, .UN)
        XCTAssertEqual(recovered.dataSet[0x00280120]?.bytesValue, Data([0xE8, 0xFD]))
        XCTAssertEqual(recovered.diagnostics.count, 1)
    }

    func test_implicitValue_withoutRequiredContextIsNotGuessed() throws {
        let bytes = try DicomDataSetWriter.dataSetData(from: .init(elements: [signed(0x00280120, [-9])]),
                                                       transferSyntax: .implicitVRLittleEndian)
        XCTAssertThrowsError(try DicomDataSetParser.read(from: bytes, transferSyntax: .implicitVRLittleEndian))
        let recovered = try DicomDataSetParser.read(from: bytes, transferSyntax: .implicitVRLittleEndian, mode: .recover)
        XCTAssertEqual(recovered.dataSet[0x00280120]?.bytesValue, Data([0xF7, 0xFF]))
        XCTAssertEqual(recovered.diagnostics.count, 1)
    }

    func test_voiLUT_usesPostRescaleRangeIncludingNegativeSlope() throws {
        let cases: [(UInt, UInt, String, String, DicomVR, Int)] = [
            (12, 0, "1", "-1024", .SS, -1024), (12, 0, "-1", "4095", .US, 65000),
            (12, 0, "-1", "4094", .SS, -1), (12, 1, "1", "2048", .US, 65000),
            (64, 0, "1", "0", .US, 65000), (64, 1, "1", "0", .SS, -1),
            (12, 0, "1", "0E999", .US, 65000), (12, 0, "1", "0E-999", .US, 65000),
            (32, 0, "-1", "4294967295", .US, 65000), (32, 0, "-1", "4294967294", .SS, -1),
            (12, 0, "0", "-1", .SS, -1), (12, 1, "0", "1", .US, 65000),
            (12, 0, "0", "0", .US, 65000), (12, 1, "0E999", "-1", .SS, -1)
        ]
        for (index, testCase) in cases.enumerated() {
            let (bits, representation, slope, intercept, vr, first) = testCase
            let descriptor = DicomDataElement(tag: 0x00283002, vr: vr,
                value: vr == .SS ? .signedIntegers([65535, first, 16]) : .unsignedIntegers([65535, UInt(first), 16]))
            let source = DicomDataSet(elements: [
                unsigned(0x00280101, [bits]), unsigned(0x00280103, [representation]),
                .init(tag: 0x00281052, vr: .DS, value: .strings([intercept])),
                .init(tag: 0x00281053, vr: .DS, value: .strings([slope])),
                .init(tag: 0x00283010, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [descriptor]))]))
            ])
            for syntax in [DicomTransferSyntax.implicitVRLittleEndian, .explicitVRLittleEndian,
                           .explicitVRBigEndian, .deflatedExplicitVRLittleEndian] {
                let bytes = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: syntax, purpose: .instance)
                XCTAssertEqual(try DicomDataSetParser.read(from: bytes, transferSyntax: syntax).dataSet, source)
                try export(source, name: "voi-\(index)-\(syntax.rawValue)", syntax: syntax)
            }
        }
    }

    func test_voiLUT_modalityLUTOutputIsUnsignedDespiteSignedStoredPixels() throws {
        let source = DicomDataSet(elements: [
            unsigned(0x00280103, [1]),
            .init(tag: 0x00283000, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [
                signed(0x00283002, [1, -1, 16]), unsigned(0x00283006, [0])
            ]))])),
            .init(tag: 0x00283010, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [
                unsigned(0x00283002, [1, 65000, 16])
            ]))]))
        ])
        let bytes = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: .implicitVRLittleEndian)
        let parsed = try DicomDataSetParser.read(from: bytes, transferSyntax: .implicitVRLittleEndian).dataSet
        XCTAssertEqual(parsed.sequenceItems(for: 0x00283010), source.sequenceItems(for: 0x00283010))
    }

    func test_invalidLocalDiscriminator_doesNotInheritParentValue() throws {
        let source = DicomDataSet(elements: [unsigned(0x00280103, [1]),
            .init(tag: 0x0040A730, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [
                .init(tag: 0x00280103, vr: .US, value: .empty), signed(0x00280120, [-1])
            ]))]))
        ])
        let bytes = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: .implicitVRLittleEndian)
        XCTAssertThrowsError(try DicomDataSetParser.read(from: bytes, transferSyntax: .implicitVRLittleEndian))
        let recovered = try DicomDataSetParser.read(from: bytes, transferSyntax: .implicitVRLittleEndian, mode: .recover)
        XCTAssertEqual(recovered.diagnostics.count, 1)
        XCTAssertEqual(recovered.dataSet.sequenceItems(for: 0x0040A730)[0].dataSet[0x00280120]?.vr, .UN)
    }

    func test_waveformVR_usesSyntaxAndLaterBitsAllocatedAcrossChannelItems() throws {
        for bits in [8, 16, 32, 64] {
            for syntax in [DicomTransferSyntax.implicitVRLittleEndian, .explicitVRLittleEndian,
                           .explicitVRBigEndian, .deflatedExplicitVRLittleEndian] {
                let vr: DicomVR = bits == 8 && syntax.isExplicitVR ? .OB : .OW
                let words = (1...max(1, bits / 16)).flatMap { word -> [UInt8] in
                    syntax.isBigEndian ? [1, UInt8(word)] : [UInt8(word), 1]
                }
                let value = DicomDataValue.bytes(Data(words))
                let source = DicomDataSet(elements: [
                    .init(tag: 0x003A0200, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [
                        .init(tag: 0x54000110, vr: vr, value: value), .init(tag: 0x54000112, vr: vr, value: value)
                    ]))])),
                    unsigned(0x54001004, [UInt(bits)]), .init(tag: 0x5400100A, vr: vr, value: value),
                    .init(tag: 0x54001010, vr: vr, value: value)
                ])
                let bytes = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: syntax, purpose: .instance)
                XCTAssertEqual(try DicomDataSetParser.read(from: bytes, transferSyntax: syntax).dataSet, source)
                try export(source, name: "waveform-\(bits)-\(syntax.rawValue)", syntax: syntax)
            }
        }
    }

    func test_waveformExplicitVR_rejectsConflictWithLaterBitsAllocated() throws {
        let source = DicomDataSet(elements: [unsigned(0x54001004, [16]),
            .init(tag: 0x54001010, vr: .OB, value: .bytes(Data([1, 2])))])
        let bytes = try DicomDataSetWriter.dataSetData(from: source)
        XCTAssertThrowsError(try DicomDataSetParser.read(from: bytes))
        let recovered = try DicomDataSetParser.read(from: bytes, mode: .recover)
        XCTAssertEqual(recovered.dataSet[0x54001010]?.vr, .UN)
        XCTAssertEqual(recovered.diagnostics.count, 1)
    }

    func test_otherAmbiguousBinaryVRs_preserveOpaqueWordsWithoutInventingSampleTypes() throws {
        for tag in [0x00143050, 0x00143070, 0x00281200, 0x00283006, 0x5000200C, 0x50023000, 0x60003000, 0x7F020010] {
            let source = DicomDataSet(elements: [.init(tag: tag, vr: .OW, value: .bytes(Data([0xFF, 0xFE, 0x12, 0x34])))])
            for syntax in [DicomTransferSyntax.implicitVRLittleEndian, .explicitVRLittleEndian, .explicitVRBigEndian] {
                let bytes = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: syntax, purpose: .instance)
                XCTAssertEqual(try DicomDataSetParser.read(from: bytes, transferSyntax: syntax).dataSet, source)
            }
        }
    }

    func test_localAmbiguousScalarDefinition_cannotInventAnImplicitSignRule() throws {
        let dictionary = try DCMDictionary(extendingWith: [0x77761001: .init(valueRepresentations: [.US, .SS],
            multiplicity: "1", name: "Synthetic ambiguous scalar")])
        let source = DicomDataSet(elements: [.init(tag: 0x77761001, vr: .SS, value: .signedIntegers([-1]))])
        let implicit = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: .implicitVRLittleEndian)
        XCTAssertThrowsError(try DicomDataSetParser.read(from: implicit, transferSyntax: .implicitVRLittleEndian, dictionary: dictionary))
        let recovered = try DicomDataSetParser.read(from: implicit, transferSyntax: .implicitVRLittleEndian,
            mode: .recover, dictionary: dictionary)
        XCTAssertEqual(recovered.diagnostics.map(\.reason), [.ambiguousVR])
        XCTAssertEqual(recovered.dataSet[0x77761001]?.bytesValue, Data([0xFF, 0xFF]))
        let explicit = try DicomDataSetWriter.dataSetData(from: source)
        XCTAssertEqual(try DicomDataSetParser.read(from: explicit, dictionary: dictionary).dataSet, source)
    }

    private func signed(_ tag: Int, _ values: [Int]) -> DicomDataElement { .init(tag: tag, vr: .SS, value: .signedIntegers(values)) }
    private func unsigned(_ tag: Int, _ values: [UInt]) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers(values)) }
    private func export(_ dataSet: DicomDataSet, name: String, syntax: DicomTransferSyntax) throws {
        guard let directory = ProcessInfo.processInfo.environment["DICOM_DIFFERENTIAL_REWRITE_DIR"] else { return }
        let root = URL(fileURLWithPath: directory).appendingPathComponent("data-fidelity")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: syntax,
            mediaStorageSOPInstanceUID: "2.25.2320002", validationPurpose: .instance)).write(to: root.appendingPathComponent(name + ".dcm"))
    }
}
