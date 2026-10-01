import CoreGraphics
import Foundation
import ImageIO
import DicomJPEG
import XCTest
@testable import DicomCore

final class DicomJPEGFrameValidatorTests: XCTestCase {
    func test_actualFrameCorpus_keepsMetadataProfileAndPayloadOutcomesSeparate() throws {
        let baseline = try baselineFrame()
        let extended8 = JPEGExtendedFixtureFactory.makeDCOnlyStream(precision: 8, width: 8, height: 8, blockValues: [100])
        let extended12 = JPEGExtendedFixtureFactory.makeDCOnlyStream(precision: 12, width: 8, height: 8, blockValues: [1000])
        let lossless8 = makeJPEGLosslessStream(planes: [Array(repeating: 100, count: 64)], width: 8, height: 8, precision: 8)
        let predictor7 = makeJPEGLosslessStream(planes: [Array(repeating: 100, count: 64)], width: 8, height: 8, precision: 8, selectionValue: 7)
        let lossless12 = makeJPEGLosslessStream(planes: [Array(repeating: 1000, count: 64)], width: 8, height: 8, precision: 12)
        let lossless16 = makeJPEGLosslessStream(planes: [Array(repeating: 20000, count: 64)], width: 8, height: 8, precision: 16)
        let color = makeJPEGLosslessStream(planes: Array(repeating: Array(repeating: 100, count: 64), count: 3), width: 8, height: 8, precision: 8)
        let fixtures: [(String, Data, DicomTransferSyntax, DicomDataSet)] = [
            ("baseline", baseline, .jpegBaseline, metadata(8)), ("extended8", extended8, .jpegExtended, metadata(8)),
            ("extended12", extended12, .jpegExtended, metadata(12)), ("lossless8", lossless8, .jpegLosslessFirstOrder, metadata(8)),
            ("lossless12", lossless12, .jpegLosslessFirstOrder, metadata(12)), ("lossless16", lossless16, .jpegLosslessFirstOrder, metadata(16)),
            ("predictor7", predictor7, .jpegLossless, metadata(8)), ("wrong-predictor", predictor7, .jpegLosslessFirstOrder, metadata(8)),
            ("wrong-sof0", baseline, .jpegExtended, metadata(8)), ("wrong-sof1", extended8, .jpegBaseline, metadata(8)),
            ("wrong-precision", lossless12, .jpegLosslessFirstOrder, metadata(8)),
            ("wrong-rows", lossless8, .jpegLosslessFirstOrder, metadata(8).setting(number(0x00280010, 9))),
            ("wrong-components", color, .jpegLosslessFirstOrder, metadata(8)),
            ("color", color, .jpegLosslessFirstOrder, metadata(8).setting(number(0x00280002, 3)).setting(text(0x00280004, "RGB", .CS)).setting(number(0x00280006, 0))),
            ("truncated", Data(lossless8.dropLast(2)), .jpegLosslessFirstOrder, metadata(8)),
            ("extra-frame", lossless8 + lossless8, .jpegLosslessFirstOrder, metadata(8))
        ]
        for (name, frame, syntax, metadata) in fixtures {
            let report = DicomJPEGFrameValidator.validate(metadata, frame: frame, transferSyntax: syntax, frameIndex: 2)
            let malformed = ["truncated", "extra-frame"].contains(name)
            let profile = ["wrong-predictor", "wrong-sof0", "wrong-sof1"].contains(name)
            let pixelMismatch = ["wrong-precision", "wrong-rows", "wrong-components"].contains(name)
            XCTAssertEqual(report[.attributes], .passed, name)
            // Lossless, extended and (since #2326) baseline frames are decoded by own decoders, so a valid frame passes
            // the codestream layer.
            XCTAssertEqual(report[.codestream], malformed || profile ? .failed : .passed, name)
            XCTAssertEqual(report[.pixelsAndGeometry], pixelMismatch ? .failed : malformed || name == "color" ? .incomplete : .passed, name)
            XCTAssertEqual(report[.operation], .notEvaluated, name)
            XCTAssertTrue(report.diagnostics.allSatisfy { $0.path.last == .frame(2) }, name)
            if !malformed {
                let info = try DicomJPEGFrameInspector.inspect(frame)
                if info.startOfFrame == 0xC3 {
                    let independent = try JLIDecoder().decode(from: [UInt8](frame))
                    XCTAssertEqual(independent.width, info.width, name)
                    XCTAssertEqual(independent.height, info.height, name)
                    let sample: UInt16 = info.precision == 16 ? 20000 : info.precision == 12 ? 1000 : 100
                    let code: [UInt8] = info.precision > 8 ? [UInt8(sample & 255), UInt8(sample >> 8)] : [UInt8(sample)]
                    XCTAssertEqual(independent.data, Array(repeating: code, count: 64 * info.components.count).flatMap { $0 }, name)
                } else if info.startOfFrame == 0xC1 {
                    let decoded = try JPEGExtendedDecoder.decode(frame)
                    XCTAssertEqual(decoded.precision, info.precision, name)
                    XCTAssertEqual(Set(decoded.pixels), [info.precision == 12 ? 1000 : 100], name)
                } else {
                    XCTAssertNotNil(CGImageSourceCreateWithData(frame as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
                }
            }
            let source = metadata.setting(.init(tag: 0x7FE00010, vr: .OB, value: .bytes(try DicomTranscoder.encapsulate(fragments: [frame]).pixelData)))
            let part10 = try DicomDataSetWriter.part10Data(from: source, options: .init(transferSyntax: syntax))
            let parsed = try DicomEncodedDataSetValidator.validate(DicomDataSetWriter.dataSetData(from: source, transferSyntax: syntax, purpose: .instance), transferSyntax: syntax)
            XCTAssertEqual(parsed.report[.structure], .passed, name)
            XCTAssertEqual(parsed.report[.vrAndVM], .incomplete, name) // Pixel Data is intentionally excluded from metadata parsing.
            let parsedMetadata = try XCTUnwrap(parsed.dataSet)
            let decoder = try DCMDecoder(data: part10)
            let actual = try decoder.makeEncapsulatedPixelFrameReader().frameData(at: 0)
            XCTAssertTrue(actual == frame || actual == frame + Data([0]), name)
            XCTAssertEqual(DicomJPEGFrameValidator.validate(parsedMetadata, frame: actual, transferSyntax: syntax, frameIndex: 2), report, name)
            if let folder = ProcessInfo.processInfo.environment["DICOM_JPEG_VALIDATION_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let path = directory.appendingPathComponent(name)
                try part10.write(to: path.appendingPathExtension("dcm"))
                try JSONSerialization.data(withJSONObject: ["attributes": report[.attributes].rawValue, "codestream": report[.codestream].rawValue,
                    "pixels": report[.pixelsAndGeometry].rawValue, "diagnostics": report.diagnostics.map { $0.code.rawValue }])
                    .write(to: path.appendingPathExtension("json"))
            }
        }
    }

    func test_markerCompleteWithoutEntropy_neverPassesCodestream() throws {
        let encoded = JPEGExtendedFixtureFactory.makeDCOnlyStream(precision: 12, width: 8, height: 8, blockValues: [1000])
        let scan = try XCTUnwrap(encoded.range(of: Data([0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 63, 0])))
        let emptyEntropy = Data(encoded.prefix(scan.upperBound)) + Data([0xFF, 0xD9])
        XCTAssertEqual(try DicomJPEGFrameInspector.inspect(emptyEntropy).precision, 12)
        XCTAssertThrowsError(try JPEGExtendedDecoder.decode(emptyEntropy))
        let report = DicomJPEGFrameValidator.validate(metadata(12), frame: emptyEntropy, transferSyntax: .jpegExtended)
        XCTAssertEqual(report[.pixelsAndGeometry], .passed)
        XCTAssertEqual(report[.codestream], .failed) // The native decoder cannot decode an empty entropy-coded segment.
        XCTAssertEqual(report.diagnostics.map(\.code), [.invalidCodestream])
    }

    func test_missingInvalidMetadataAndUnsupportedSyntax_remainExplicit() throws {
        let frame = try baselineFrame()
        for tag in [0x00280010, 0x00280011, 0x00280002, 0x00280004, 0x00280100, 0x00280101, 0x00280102, 0x00280103] {
            let report = DicomJPEGFrameValidator.validate(metadata(8).removing(tag), frame: frame, transferSyntax: .jpegBaseline)
            XCTAssertEqual(report[.attributes], .failed)
            XCTAssertEqual(report[.pixelsAndGeometry], .incomplete)
        }
        let wrongAllocation = DicomJPEGFrameValidator.validate(metadata(8).setting(number(0x00280100, 16)), frame: frame, transferSyntax: .jpegExtended)
        XCTAssertEqual(wrongAllocation[.pixelsAndGeometry], .failed)
        let signed = metadata(8).setting(number(0x00280103, 1))
        XCTAssertEqual(DicomJPEGFrameValidator.validate(signed, frame: frame, transferSyntax: .jpegBaseline)[.attributes], .failed)
        XCTAssertEqual(DicomJPEGFrameValidator.validate(metadata(8), frame: nil, transferSyntax: .jpegBaseline)[.pixelsAndGeometry], .incomplete)
        XCTAssertEqual(DicomJPEGFrameValidator.validate(metadata(8), frame: frame, transferSyntax: .jpegLSLossless)[.codestream], .incomplete)
    }

    func test_budgetsAndNegativeFrameIndex_neverPromoteMissingEvidence() throws {
        let frame = try baselineFrame()
        for limit in [0, 1, 2] {
            let report = DicomJPEGFrameValidator.validate(DicomDataSet(elements: []), frame: frame, transferSyntax: .jpegBaseline,
                attributeLimits: .init(maximumDiagnostics: limit))
            XCTAssertEqual(report[.codestream], .incomplete)
            XCTAssertLessThanOrEqual(report.diagnostics.count, max(1, limit) + 3)
        }
        XCTAssertEqual(DicomJPEGFrameValidator.validate(metadata(8), frame: frame, transferSyntax: .jpegBaseline, maximumEncodedBytes: 2)[.codestream], .incomplete)
        let invalid = DicomJPEGFrameValidator.validate(metadata(8), frame: frame, transferSyntax: .jpegBaseline, frameIndex: -1)
        XCTAssertEqual(invalid[.pixelsAndGeometry], .failed)
        XCTAssertFalse(invalid.diagnostics.contains { $0.path.contains(.frame(-1)) })
    }

    /// Issue #2487: a codestream precision that differs from Bits Stored but fits Bits Allocated is a warning
    /// (the samples decode into the declared container); one above Bits Allocated stays an error.
    func test_bitsStoredContradiction_isAWarningWhenThePrecisionFitsBitsAllocated() throws {
        let extended12 = JPEGExtendedFixtureFactory.makeDCOnlyStream(precision: 12, width: 8, height: 8, blockValues: [1000])
        let fits = DicomJPEGFrameValidator.validate(metadata(16), frame: extended12, transferSyntax: .jpegExtended)
        XCTAssertEqual(fits[.pixelsAndGeometry], .passed)
        XCTAssertTrue(fits.diagnostics.contains { $0.code == .pixelMetadataContradiction && $0.severity == .warning && $0.path.contains(.tag(0x00280101)) })
        let overflow = DicomJPEGFrameValidator.validate(metadata(8), frame: extended12, transferSyntax: .jpegExtended)
        XCTAssertEqual(overflow[.pixelsAndGeometry], .failed)
        XCTAssertTrue(overflow.diagnostics.contains { $0.code == .pixelMetadataContradiction && $0.severity == .error && $0.path.contains(.tag(0x00280101)) })
    }

    /// Issue #2487: a 4:2:0 baseline frame declared YBR_FULL_422 is what most cine encoders write; the sampling
    /// comes from the frame, so the declaration is a warning, while a wrong component count stays an error.
    func test_chromaSubsamplingContradiction_isAWarning() throws {
        let pixels = [UInt8](repeating: 100, count: 16 * 16 * 3)
        let image = try JLIImage(width: 16, height: 16, pixelFormat: .uint8, colorModel: .rgb, data: pixels)
        var configuration = JLIEncoderConfiguration(quality: 90, chromaSubsampling: .yuv420, colorSpace: .yCbCr, progressive: false,
                                                    restartInterval: 0, optimiseHuffman: true, adaptiveQuantization: false, perceptualQuantTables: false)
        configuration.extendedSequential = false
        let frame = Data(try JLIEncoder().encode(image, configuration: configuration))
        XCTAssertEqual(try DicomJPEGFrameInspector.inspect(frame).chromaSubsampling?.vertical, 2, "the fixture is 4:2:0")
        let color = metadata(8).setting(number(0x00280010, 16)).setting(number(0x00280011, 16)).setting(number(0x00280002, 3))
            .setting(text(0x00280004, "YBR_FULL_422", .CS)).setting(number(0x00280006, 0))
        let report = DicomJPEGFrameValidator.validate(color, frame: frame, transferSyntax: .jpegBaseline)
        XCTAssertNotEqual(report[.pixelsAndGeometry], .failed)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .pixelMetadataContradiction && $0.severity == .warning && $0.path.contains(.tag(0x00280004)) })
        let mono = DicomJPEGFrameValidator.validate(metadata(8).setting(number(0x00280010, 16)).setting(number(0x00280011, 16)), frame: frame, transferSyntax: .jpegBaseline)
        XCTAssertEqual(mono[.pixelsAndGeometry], .failed, "a colour frame declared MONOCHROME2 is still an error")
    }

    private func metadata(_ bits: UInt) -> DicomDataSet {
        .init(elements: [text(0x00080016, "1.2.840.10008.5.1.4.1.1.7", .UI), text(0x00080018, "2.25.23212301", .UI),
            number(0x00280010, 8), number(0x00280011, 8), number(0x00280002, 1), text(0x00280004, "MONOCHROME2", .CS),
            number(0x00280100, bits > 8 ? 16 : 8), number(0x00280101, bits), number(0x00280102, bits - 1), number(0x00280103, 0)])
    }
    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers([value])) }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings([value])) }
    private func baselineFrame() throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(repeating: 100, count: 64) as CFData))
        let image = try XCTUnwrap(CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
