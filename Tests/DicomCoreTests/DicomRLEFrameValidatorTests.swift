import Foundation
import XCTest
@testable import DicomCore

final class DicomRLEFrameValidatorTests: XCTestCase {
    func test_wireCorpus_comparesActualPlanesRunsAndMetadata() throws {
        let names = ["gray8", "gray16", "gray12-signed", "mono1", "binary", "palette8", "palette16", "rgb8-planar0",
                     "rgb8-planar1", "rgb16", "ybr8", "ybr16", "segment-count", "row-cross", "literal-triple", "odd-segment16", "trailing", "unused-offset", "nonbinary", "bits-stored"]
        for name in names {
            let fixture = fixture(name)
            let encapsulated = try DicomTranscoder.encapsulate(fragments: [fixture.frame]).pixelData
            let source = fixture.metadata.setting(.init(tag: 0x7FE00010, vr: .OB, value: .bytes(encapsulated)))
            let bytes = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: .rleLossless, purpose: .instance)
            let read = try DicomEncodedDataSetValidator.validate(bytes, transferSyntax: .rleLossless)
            XCTAssertEqual(read.report[.structure], .passed, name)
            XCTAssertEqual(read.report[.vrAndVM], .incomplete, name) // The metadata parser intentionally omits Pixel Data.
            XCTAssertEqual(read.report.diagnostics, [.init(code: .valueUnavailable, severity: .limitation, layer: .vrAndVM, path: [.tag(0x7FE00010)])], name)
            let metadataRead = try DicomEncodedDataSetValidator.validate(DicomDataSetWriter.dataSetData(from: fixture.metadata,
                purpose: .instance)) // Non-pixel RLE attributes use the same Explicit VR Little Endian encoding.
            XCTAssertEqual(metadataRead.report.outcome(requiring: [.structure, .vrAndVM]), .passed, name)
            let part10 = try DicomDataSetWriter.part10Data(from: source, options: .init(transferSyntax: .rleLossless))
            let decoder = try DCMDecoder(data: part10)
            let frame = try decoder.makeEncapsulatedPixelFrameReader().frameData(at: 0)
            XCTAssertEqual(frame, fixture.frame, name)
            let report = DicomRLEFrameValidator.validate(try XCTUnwrap(read.dataSet), frame: frame)
            let badStream = ["row-cross", "literal-triple", "odd-segment16", "trailing", "unused-offset"].contains(name)
            let badPixels = ["segment-count", "nonbinary"].contains(name)
            let missingPixels = ["trailing", "unused-offset"].contains(name)
            XCTAssertEqual(report[.codestream], badStream ? .failed : .passed, name)
            XCTAssertEqual(report[.pixelsAndGeometry], badPixels ? .failed : missingPixels ? .incomplete : .passed, name)
            XCTAssertEqual(report[.attributes], name == "bits-stored" ? .failed : .passed, name)
            XCTAssertEqual(report[.operation], .notEvaluated, name)
            if let directory = ProcessInfo.processInfo.environment["DICOM_RLE_VALIDATION_CORPUS_DIRECTORY"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let path = folder.appendingPathComponent(name)
                try part10.write(to: path.appendingPathExtension("dcm"))
                try JSONSerialization.data(withJSONObject: ["structure": "passed", "metadataVRVM": "passed", "wireVRVM": "incomplete", "attributes": report[.attributes].rawValue,
                    "codestream": report[.codestream].rawValue, "pixels": report[.pixelsAndGeometry].rawValue,
                    "diagnostics": report.diagnostics.map { $0.code.rawValue }]).write(to: path.appendingPathExtension("json"))
            }
        }
    }

    func test_productionDecoder_rejectsPreviouslyDiscardedTrailingPayload() throws {
        let good = fixture("gray8")
        let result = try DicomRLELosslessDecoder.decode(frame: good.frame, width: 2, height: 2, bitsAllocated: 8,
            samplesPerPixel: 1, pixelRepresentation: 0, photometricInterpretation: "MONOCHROME2")
        XCTAssertEqual(result.pixels8, [1, 2, 3, 4])
        let odd = try DicomRLELosslessDecoder.decode(frame: fixture("odd-segment16").frame, width: 2, height: 2, bitsAllocated: 16,
            samplesPerPixel: 1, pixelRepresentation: 0, photometricInterpretation: "MONOCHROME2")
        XCTAssertEqual(odd.pixels16, [0x0101, 0x0202, 0x0303, 0x0404]) // Decoder acceptance: the missing G.3.1 pad byte is a conformance diagnostic, not a decode failure.
        for name in ["trailing", "unused-offset"] {
            XCTAssertThrowsError(try DicomRLELosslessDecoder.decode(frame: fixture(name).frame, width: 2, height: 2, bitsAllocated: 8,
                samplesPerPixel: 1, pixelRepresentation: 0, photometricInterpretation: "MONOCHROME2")) { XCTAssertTrue($0 is DICOMError) }
        }
    }

    func test_missingOpaqueInputsAndBudgets_neverBecomeSuccessfulCodestreamEvidence() {
        let source = fixture("gray8")
        XCTAssertEqual(DicomRLEFrameValidator.validate(source.metadata, frame: nil)[.codestream], .incomplete)
        for missing in [source.metadata.removing(0x00280010), source.metadata.setting(.init(tag: 0x00280011, vr: .UN, value: .bytes(Data([0, 0]))))] {
            XCTAssertEqual(DicomRLEFrameValidator.validate(missing, frame: source.frame)[.codestream], .incomplete)
        }
        for limits in [DicomRLECodec.Limits(maximumEncodedBytes: 65), .init(maximumDecodedBytes: 3)] {
            let report = DicomRLEFrameValidator.validate(source.metadata, frame: source.frame, frameIndex: 4, limits: limits)
            XCTAssertEqual(report[.codestream], .incomplete)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .evaluationLimitReached && $0.path == [.tag(0x7FE00010), .frame(4)] })
        }
        let capped = DicomRLEFrameValidator.validate(source.metadata.setting(number(0x00280002, 3)), frame: fixture("row-cross").frame,
            attributeLimits: .init(maximumDiagnostics: 1))
        XCTAssertNotEqual(capped[.codestream], .passed)
        XCTAssertLessThanOrEqual(capped.diagnostics.count, 4)
        XCTAssertEqual(DicomRLEFrameValidator.validate(source.metadata, frame: source.frame, transferSyntax: .jpegBaseline)[.codestream], .incomplete)
    }

    func test_oversizedEncodedFrame_isRejectedByProductionAndLegacyDecoders() throws {
        let source = fixture("gray8")
        var oversized = source.frame
        oversized.append(Data(repeating: 0x80, count: DicomRLECodec.Limits().maximumEncodedBytes + 2 - oversized.count))
        XCTAssertThrowsError(try DicomRLELosslessDecoder.decode(frame: oversized, width: 2, height: 2, bitsAllocated: 8,
            samplesPerPixel: 1, pixelRepresentation: 0, photometricInterpretation: "MONOCHROME2")) {
            XCTAssertTrue($0 is DICOMError)
        }

        let encapsulated = try DicomTranscoder.encapsulate(fragments: [oversized]).pixelData
        let dataSet = source.metadata.setting(.init(tag: 0x7FE00010, vr: .OB, value: .bytes(encapsulated)))
        let decoder = try DCMDecoder(data: DicomDataSetWriter.part10Data(from: dataSet,
            options: .init(transferSyntax: .rleLossless)))
        XCTAssertNil(decoder.getPixels8())
    }

    func test_photometricAllocationAndSignednessContradictions_keepFrameLocation() {
        let source = fixture("gray8")
        let wrong = source.metadata.setting(text(0x00280004, "RGB", .CS))
        let report = DicomRLEFrameValidator.validate(wrong, frame: source.frame, frameIndex: 3)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .pixelMetadataContradiction && $0.path == [.tag(0x00280002), .frame(3)] })
        let color = fixture("rgb8-planar0")
        XCTAssertEqual(DicomRLEFrameValidator.validate(color.metadata.setting(number(0x00280103, 1)), frame: color.frame)[.pixelsAndGeometry], .failed)
        XCTAssertEqual(DicomRLEFrameValidator.validate(color.metadata.setting(number(0x00280100, 1)), frame: color.frame)[.pixelsAndGeometry], .failed)
    }

    private func fixture(_ name: String) -> (metadata: DicomDataSet, frame: Data) {
        let color = name.hasPrefix("rgb") || name.hasPrefix("ybr") || name == "segment-count"
        let binary = ["binary", "nonbinary"].contains(name)
        let bits: UInt = binary ? 1 : name.contains("16") || name == "gray12-signed" ? 16 : 8
        let stored: UInt = name == "gray12-signed" ? 12 : name == "bits-stored" ? 17 : bits
        let photo = name.hasPrefix("rgb") || name == "segment-count" ? "RGB" : name.hasPrefix("ybr") ? "YBR_FULL" :
            name.hasPrefix("palette") ? "PALETTE COLOR" : name == "mono1" ? "MONOCHROME1" : "MONOCHROME2"
        var source = DicomDataSet(elements: [text(0x00080016, "1.2.840.10008.5.1.4.1.1.7", .UI), text(0x00080018, "2.25.23212201", .UI),
            number(0x00280010, name == "literal-triple" ? 1 : 2), number(0x00280011, name == "literal-triple" ? 3 : 2),
            number(0x00280002, color ? 3 : 1), text(0x00280004, photo, .CS), number(0x00280100, bits), number(0x00280101, stored),
            number(0x00280102, stored - 1), number(0x00280103, name == "gray12-signed" ? 1 : 0)])
        if color { source = source.setting(number(0x00280006, name == "rgb8-planar1" ? 1 : 0)) }
        let count = name == "segment-count" ? 1 : (color ? 3 : 1) * Int((bits + 7) / 8)
        let segment: [UInt8] = name == "row-cross" ? [3, 1, 2, 3, 4, 0] : name == "literal-triple" ? [2, 7, 7, 7] :
            name == "odd-segment16" ? [1, 1, 2, 0, 3, 0, 4] : binary ? [1, 0, name == "nonbinary" ? 2 : 1, 1, 1, 0] : [1, 1, 2, 1, 3, 4]
        var frame = makeFrame(Array(repeating: segment, count: count))
        if name == "trailing" { frame.append(contentsOf: [0, 9]) }
        if name == "unused-offset" { frame[8] = 66 }
        return (source, frame)
    }
    private func makeFrame(_ segments: [[UInt8]]) -> Data {
        var words: [UInt32] = [UInt32(segments.count)]
        var offset = 64
        for segment in segments { words.append(UInt32(offset)); offset += segment.count }
        words += Array(repeating: 0, count: 16 - words.count)
        var data = Data()
        for word in words { withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) } }
        for segment in segments { data.append(contentsOf: segment) }
        return data
    }
    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers([value])) }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings([value])) }
}
