import Foundation
import XCTest
@testable import DicomCore

final class DicomNativePixelValidatorTests: XCTestCase {
    func test_nativeWireCorpus_matchesActualValueLengthAcrossAllocations() throws {
        let names = ["gray8", "gray12", "gray24", "gray32", "gray64", "packed1", "packed1-frame-padding", "rgb0", "rgb1",
                     "ybr422", "ybr422-expanded", "ybr422-odd-columns", "ybr422-odd-rows", "float32", "float64", "float-forbidden",
                     "short", "excess", "wrong-ob", "wrong-high-bit", "wrong-allocation", "forbidden-photo"]
        for name in names {
            let fixture = try fixture(name)
            let parsed = try DicomEncodedDataSetValidator.validate(fixture.encoded)
            let report = DicomNativePixelValidator.validate(parsed, transferSyntax: .explicitVRLittleEndian)
            let pixelErrors = ["packed1-frame-padding", "ybr422-expanded", "ybr422-odd-columns", "short", "excess", "wrong-ob", "wrong-allocation", "forbidden-photo"]
            let attributeErrors = ["float-forbidden", "wrong-high-bit"]
            XCTAssertEqual(report[.pixelsAndGeometry], pixelErrors.contains(name) ? .failed : name == "ybr422-odd-rows" ? .incomplete : .passed, name)
            XCTAssertEqual(report[.attributes], attributeErrors.contains(name) ? .failed : .passed, name)
            let instance = try DicomInstanceValidator.validate(fixture.part10)
            XCTAssertEqual(instance[.pixelsAndGeometry], report[.pixelsAndGeometry], name)
            XCTAssertNotEqual(instance[.attributes], .passed, name)
            XCTAssertEqual(report[.codestream], .notEvaluated, name)
            if let folder = ProcessInfo.processInfo.environment["DICOM_NATIVE_VALIDATION_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let path = directory.appendingPathComponent(name)
                try fixture.part10.write(to: path.appendingPathExtension("dcm"))
                try JSONSerialization.data(withJSONObject: ["attributes": report[.attributes].rawValue,
                    "pixels": report[.pixelsAndGeometry].rawValue, "diagnostics": report.diagnostics.map { $0.code.rawValue }])
                    .write(to: path.appendingPathExtension("json"))
            }
        }
    }

    /// Issue #2487: word samples under an OB header read the same bytes under little endian (a warning), while
    /// under big endian the VR decides the byte order (an error).
    func test_wordSamplesUnderAnOBHeader_warnUnderLittleEndianAndFailUnderBigEndian() throws {
        for (syntax, expected) in [(DicomTransferSyntax.explicitVRLittleEndian, DicomValidationReport.Severity.warning),
                                   (.explicitVRBigEndian, .error)] {
            let source = base(bits: 16, rows: 2, columns: 2)
                .setting(.init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data(repeating: 255, count: 8))))
            let encoded = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: syntax, purpose: .instance)
            let parsed = try DicomEncodedDataSetValidator.validate(encoded, transferSyntax: syntax)
            let report = DicomNativePixelValidator.validate(parsed, transferSyntax: syntax)
            let diagnostic = report.diagnostics.first { $0.code == .incompatibleVR && $0.path == [.tag(0x7FE00010)] }
            XCTAssertEqual(diagnostic?.severity, expected, "\(syntax)")
            XCTAssertEqual(report[.pixelsAndGeometry], expected == .error ? .failed : .passed, "\(syntax)")
        }
    }

    func test_endiannessAndImplicitVR_preserveAllocationLengthEvidence() throws {
        for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .implicitVRLittleEndian, .explicitVRBigEndian] {
            for name in ["gray8", "gray12", "packed1", "float32"] {
                let source = try fixture(name, syntax: syntax)
                let parsed = try DicomEncodedDataSetValidator.validate(source.encoded, transferSyntax: syntax)
                XCTAssertEqual(DicomNativePixelValidator.validate(parsed, transferSyntax: syntax)[.pixelsAndGeometry], .passed, "\(name) \(syntax)")
            }
        }
    }

    func test_nestedPixelHeadersAndLimits_neverSubstituteAnIconForMainPixels() throws {
        let nested = DicomDataSet(elements: [.init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data([1, 2])))])
        let source = DicomDataSet(elements: [.init(tag: 0x00880200, vr: .SQ, value: .sequence([.init(dataSet: nested), .init(dataSet: nested)]))])
        let bytes = try DicomDataSetWriter.dataSetData(from: source, purpose: .instance)
        let parsed = try DicomEncodedDataSetValidator.validate(bytes)
        XCTAssertEqual(parsed.pixelDataHeaders.map(\.path), [[.tag(0x00880200), .item(0), .tag(0x7FE00010)], [.tag(0x00880200), .item(1), .tag(0x7FE00010)]])
        XCTAssertEqual(DicomNativePixelValidator.validate(parsed, transferSyntax: .explicitVRLittleEndian)[.pixelsAndGeometry], .incomplete)
        let limited = try DicomEncodedDataSetValidator.validate(bytes, maximumDiagnostics: 1)
        XCTAssertTrue(limited.pixelDataHeadersTruncated)
        XCTAssertEqual(limited.pixelDataHeaders.count, 1)
        XCTAssertEqual(DicomNativePixelValidator.validate(limited, transferSyntax: .explicitVRLittleEndian)[.pixelsAndGeometry], .incomplete)
        let valid = try DicomEncodedDataSetValidator.validate(fixture("gray8").encoded)
        for report in [DicomNativePixelValidator.validate(valid, transferSyntax: .explicitVRLittleEndian, maximumFrames: 0),
                       DicomNativePixelValidator.validate(valid, transferSyntax: .explicitVRLittleEndian, maximumFrameBytes: 0)] {
            XCTAssertEqual(report[.pixelsAndGeometry], .incomplete)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .evaluationLimitReached })
        }
    }

    func test_conflictingPixelAlternativesAndTruncation_areNotApproved() throws {
        let source = try fixture("gray8")
        let float = try DicomDataSetWriter.dataSetData(from: .init(elements: [.init(tag: 0x7FE00008, vr: .OF, value: .floats([1]))]), purpose: .instance)
        let both = try DicomEncodedDataSetValidator.validate(float + source.encoded)
        XCTAssertTrue(DicomNativePixelValidator.validate(both, transferSyntax: .explicitVRLittleEndian).diagnostics.contains { $0.code == .exclusiveAttributeChoiceInvalid })
        let truncated = try DicomEncodedDataSetValidator.validate(Data(source.encoded.dropLast()))
        XCTAssertNil(truncated.dataSet)
        XCTAssertEqual(DicomNativePixelValidator.validate(truncated, transferSyntax: .explicitVRLittleEndian)[.pixelsAndGeometry], .incomplete)
    }

    func test_finalPaddingAndUnusedBits_doNotRequirePerFrameAlignment() throws {
        for bits: UInt in [1, 8] {
            let source = base(bits: bits, rows: 1, columns: 3)
                .setting(.init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data(repeating: 255, count: bits == 1 ? 1 : 3))))
            let bytes = try DicomDataSetWriter.dataSetData(from: source, purpose: .instance)
            let parsed = try DicomEncodedDataSetValidator.validate(bytes)
            XCTAssertEqual(parsed.pixelDataHeaders.first?.valueLength, bits == 1 ? 2 : 4)
            XCTAssertEqual(DicomNativePixelValidator.validate(parsed, transferSyntax: .explicitVRLittleEndian)[.pixelsAndGeometry], .passed)
        }
    }

    func test_oddJPEGExtendedOffsetLength_excludesOnlyActualPadding() throws {
        var jpeg = JPEGExtendedFixtureFactory.makeDCOnlyStream(precision: 8, width: 8, height: 8, blockValues: [100])
        if jpeg.count.isMultiple(of: 2) { jpeg.insert(0xFF, at: jpeg.count - 2) }
        XCTAssertFalse(jpeg.count.isMultiple(of: 2))
        let encapsulated = try DicomTranscoder.encapsulate(fragments: [jpeg], forceExtendedOffsets: true)
        var metadata = base(bits: 8, rows: 8, columns: 8)
        var unpaddedLength = UInt64(jpeg.count).littleEndian
        let lengthData = withUnsafeBytes(of: &unpaddedLength) { Data($0) }
        metadata = metadata.setting(.init(tag: 0x7FE00010, vr: .OB, value: .bytes(encapsulated.pixelData)))
            .setting(.init(tag: 0x7FE00001, vr: .OV, value: .bytes(try XCTUnwrap(encapsulated.extendedOffsetTable))))
            .setting(.init(tag: 0x7FE00002, vr: .OV, value: .bytes(lengthData)))
        let data = try DicomDataSetWriter.part10Data(from: metadata, options: .init(transferSyntax: .jpegExtended))
        let report = try DicomInstanceValidator.validate(data)
        XCTAssertEqual(report[.structure], .passed)
        XCTAssertFalse(report.diagnostics.contains { $0.code == .pixelDataLengthMismatch })
        XCTAssertEqual(report[.codestream], .passed) // The extended frame is decoded natively.
        var invalidPadding = encapsulated.pixelData
        invalidPadding[invalidPadding.count - 9] = 1 // Last value byte before the sequence delimiter.
        let invalid = metadata.setting(.init(tag: 0x7FE00010, vr: .OB, value: .bytes(invalidPadding)))
        let invalidReport = try DicomInstanceValidator.validate(DicomDataSetWriter.part10Data(from: invalid, options: .init(transferSyntax: .jpegExtended)))
        XCTAssertTrue(invalidReport.diagnostics.contains { $0.code == .pixelDataLengthMismatch && $0.layer == .structure })

        let split = try DicomTranscoder.encapsulate(fragments: [Data(jpeg.prefix(2)), Data(jpeg.dropFirst(2))], forceExtendedOffsets: true)
        let multiFragment = metadata.setting(.init(tag: 0x7FE00010, vr: .OB, value: .bytes(split.pixelData)))
        let splitReport = try DicomInstanceValidator.validate(DicomDataSetWriter.part10Data(from: multiFragment, options: .init(transferSyntax: .jpegExtended)))
        XCTAssertTrue(splitReport.diagnostics.contains { $0.code == .invalidDataSetStructure && $0.path == [.tag(0x7FE00001), .frame(0)] })
    }

    private func fixture(_ name: String, syntax: DicomTransferSyntax = .explicitVRLittleEndian) throws -> (encoded: Data, part10: Data) {
        let bits: UInt = name.hasPrefix("packed1") ? 1 : name == "gray12" ? 16 : name == "gray24" ? 24 : name == "gray32" || name == "float32" || name == "float-forbidden" ? 32 : name == "gray64" || name == "float64" ? 64 : name == "wrong-allocation" ? 12 : 8
        let rows: UInt = name.hasPrefix("packed1") || name == "ybr422-odd-rows" ? 1 : 2
        let columns: UInt = name.hasPrefix("packed1") || name == "ybr422-odd-columns" ? 3 : 2
        var source = base(bits: bits, rows: rows, columns: columns)
        if name.hasPrefix("packed1") { source = source.setting(text(0x00280008, "3", .IS)) }
        if name == "gray12" { source = source.setting(number(0x00280101, 12)).setting(number(0x00280102, 11)) }
        if name.hasPrefix("rgb") || name.hasPrefix("ybr") {
            source = source.setting(number(0x00280002, 3)).setting(text(0x00280004, name.hasPrefix("rgb") ? "RGB" : "YBR_FULL_422", .CS))
                .setting(number(0x00280006, name == "rgb1" ? 1 : 0))
        }
        if name == "forbidden-photo" { source = source.setting(text(0x00280004, "YBR_RCT", .CS)) }
        if name == "wrong-high-bit" { source = source.setting(number(0x00280102, 6)) }
        if name.hasPrefix("float") {
            source = source.removing(0x00280101).removing(0x00280102).removing(0x00280103)
                .setting(.init(tag: bits == 32 ? 0x7FE00008 : 0x7FE00009, vr: bits == 32 ? .OF : .OD, value: .floats([.nan, .infinity, -.infinity, 1])))
            if name == "float-forbidden" { source = source.setting(number(0x00280101, 32)) }
        } else {
            let length = name == "packed1" ? 2 : name == "packed1-frame-padding" ? 4 : name.hasPrefix("rgb") || name == "ybr422-expanded" ? 12 : name.hasPrefix("ybr") ? Int(rows * columns * 2) : name == "short" ? 2 : name == "excess" ? 6 : Int(rows * columns * ((bits + 7) / 8))
            source = source.setting(.init(tag: 0x7FE00010, vr: bits <= 8 && syntax.isExplicitVR ? .OB : .OW, value: .bytes(Data(repeating: 255, count: length))))
        }
        var encoded = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: syntax, purpose: .instance)
        var part10 = try DicomDataSetWriter.part10Data(from: source, options: .init(transferSyntax: syntax))
        if name == "wrong-ob" {
            // Eight-bit OW is legal, so make the metadata allocate 16 bits while retaining the original OB header.
            let pattern = Data([0x28, 0, 0, 1, 0x55, 0x53, 2, 0, 8, 0])
            for usePart10 in [false, true] {
                var bytes = usePart10 ? part10 : encoded
                let range = try XCTUnwrap(bytes.range(of: pattern)); bytes[range.upperBound - 2] = 16
                if usePart10 { part10 = bytes } else { encoded = bytes }
            }
        }
        return (encoded, part10)
    }
    private func base(bits: UInt, rows: UInt, columns: UInt) -> DicomDataSet {
        .init(elements: [text(0x00080016, "1.2.840.10008.5.1.4.1.1.7", .UI), text(0x00080018, "2.25.23212501", .UI),
            number(0x00280010, rows), number(0x00280011, columns), number(0x00280002, 1), text(0x00280004, "MONOCHROME2", .CS),
            number(0x00280100, bits), number(0x00280101, bits), number(0x00280102, bits - 1), number(0x00280103, 0)])
    }
    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers([value])) }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings([value])) }
}
