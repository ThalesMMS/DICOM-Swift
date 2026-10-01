import DicomCodecs
import Foundation
import XCTest
@testable import DicomCore

/// Independent encoders must preserve every stored voxel and its attribution (Isis issue #2520).
final class DicomSegmentationThirdPartyEncodingTests: XCTestCase {
    func test_thirdPartyLosslessFrames_matchNativeValuesSegmentsAndGeometry() throws {
        for kind in ["fractional", "labelmap8", "labelmap16"] {
            let reference = try segmentation("native-\(kind)")
            XCTAssertEqual(reference.frames.count, 3)
            for codec in ["gdcm-jpegls", "gdcm-j2k", "openjph-htj2k"] {
                let name = "\(codec)-\(kind)"
                let decoded = try segmentation(name)
                assertMetadata(decoded, equals: reference, name: name)
                XCTAssertEqual(decoded.segmentationType, reference.segmentationType, name)
                XCTAssertEqual(decoded.fractionalType, reference.fractionalType, name)
                XCTAssertEqual(decoded.maximumFractionalValue, reference.maximumFractionalValue, name)
                XCTAssertEqual(decoded.frames.map(\.pixelData), reference.frames.map(\.pixelData), name)
            }
        }
        let reference = try segmentation("native-fractional")
        let decoded = try segmentation("gdcm-rle-fractional")
        assertMetadata(decoded, equals: reference, name: "gdcm-rle-fractional")
        XCTAssertEqual(decoded.frames.map(\.pixelData), reference.frames.map(\.pixelData))
    }

    func test_binaryRLEForms_matchEveryNativeBit() throws {
        let reference = try segmentation("native-binary")
        XCTAssertEqual(reference.frames.count, 6)
        for name in ["pydicom-rle-binary-packed", "pydicom-rle-binary-bytes"] {
            let decoded = try segmentation(name)
            assertMetadata(decoded, equals: reference, name: name)
            XCTAssertEqual(decoded.segmentationType, .binary)
            XCTAssertEqual(decoded.frames.map(\.pixelData), reference.frames.map(\.pixelData), name)
        }
    }

    func test_dcmjsFractionalRLE_preservesBinaryStoredValues() throws {
        let reference = try segmentation("native-binary")
        let decoded = try segmentation("dcmjs-rle-binary-as-fractional")
        assertMetadata(decoded, equals: reference, name: "dcmjs")
        XCTAssertEqual(decoded.segmentationType, .fractional)
        XCTAssertEqual(decoded.fractionalType, .probability)
        XCTAssertEqual(decoded.maximumFractionalValue, 255)
        XCTAssertEqual(decoded.frames.map { $0.pixelData.storedValues }, reference.frames.map { $0.pixelData.storedValues })
    }

    func test_binaryRLEInvalidLengthNonBinaryValuesAndMultipleSegments_areDiagnosed() throws {
        let source = try decoder("native-binary")
        for (count, value, components) in [(39, UInt8(0), 1), (320, UInt8(2), 1), (40, UInt8(0), 2)] {
            let fragment = try DicomRLECodec.encodeFrame(Data(repeating: value, count: count * components),
                width: count, height: 1, samplesPerPixel: components, bytesPerSample: 1)
            let refused = try rewrite(source, syntax: .rleLossless, fragments: Array(repeating: fragment, count: 6))
            assertRefused(refused, code: .invalidBinaryRLE, syntax: .rleLossless)
        }
    }

    func test_binaryRLEOddPackedLength_acceptsSegmentPadding() throws {
        let source = try decoder("native-binary")
        var dataSet = source.dataSet
        // A 1 x 17 plane has three packed bytes, with an optional decoded padding byte.
        dataSet.set(.init(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([1])))
        dataSet.set(.init(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([17])))
        for values in [Data([1, 128, 1]), Data([1, 128, 1, 0])] {
            let fragment = try DicomRLECodec.encodeFrame(values, width: values.count, height: 1,
                                                       samplesPerPixel: 1, bytesPerSample: 1)
            let parsed = try rewrite(source, syntax: .rleLossless, fragments: Array(repeating: fragment, count: 6),
                                     dataSet: dataSet)
            XCTAssertEqual(parsed.frames.count, 6)
            XCTAssertEqual(parsed.frames.first?.pixelData.storedValues,
                           [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1])
        }
    }

    func test_unsupportedSyntax_keepsDiagnosticWithoutFrames() throws {
        let source = try decoder("gdcm-jpegls-labelmap8")
        for syntax in [DicomTransferSyntax.jpegBaseline, .htj2k] {
            assertRefused(try rewrite(source, syntax: syntax), code: .unsupportedTransferSyntax, syntax: syntax)
        }
    }

    func test_reversibleGeneralJPEG2000_preservesLabelsWithoutPresentationTransforms() throws {
        for name in ["gdcm-j2k-labelmap16", "gdcm-jpegls-labelmap16", "openjph-htj2k-labelmap16"] {
            let source = try decoder(name)
            let reference = try XCTUnwrap(source.segmentation)
            let syntax: DicomTransferSyntax = name.contains("gdcm-j2k") ? .jpeg2000
                : try XCTUnwrap(DicomTransferSyntax(uid: source.transferSyntaxUID))
            for photometric in ["MONOCHROME1", "PALETTE COLOR"] {
                var dataSet = source.dataSet
                dataSet.set(.init(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings([photometric])))
                dataSet.set(.init(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([1])))
                let parsed = try rewrite(source, syntax: syntax, dataSet: dataSet)
                XCTAssertEqual(parsed.frames.map(\.pixelData), reference.frames.map(\.pixelData), name)
            }
        }
    }

    func test_irreversibleJPEG2000_isDiagnosedWithoutPartialFrames() async throws {
        let source = try decoder("native-labelmap8")
        let reference = try XCTUnwrap(source.segmentation)
        let descriptor = DicomCompressedFrameDescriptor(transferSyntaxUID: DicomTransferSyntax.jpeg2000.rawValue,
            rows: 16, columns: 20, bitsAllocated: 8, bitsStored: 8, highBit: 7, pixelRepresentation: 0,
            samplesPerPixel: 1, photometricInterpretation: "MONOCHROME2", planarConfiguration: nil)
        let bytes = Data(try XCTUnwrap(reference.frames.first?.pixelData.labelmapValues).map { UInt8($0) })
        let fragment = try await DicomJ2KSwiftBackend().encode(.init(
            frame: .init(buffer: .owned(bytes), width: 20, height: 16, bitsPerSample: 8, componentCount: 1),
            descriptor: descriptor, targetTransferSyntaxUID: DicomTransferSyntax.jpeg2000.rawValue,
            intent: .irreversible(quality: 0.9)))
        XCTAssertFalse(try DicomJ2KCodestreamInspector.inspect(fragment).isLosslessCoding)
        let good = try decoder("gdcm-j2k-labelmap8").makeEncapsulatedPixelFrameReader().frameData(at: 0)
        let refused = try rewrite(source, syntax: .jpeg2000, fragments: [good, fragment, good])
        assertRefused(refused, code: .lossySegmentationFrame, syntax: .jpeg2000)
        XCTAssertEqual(refused.diagnostics.first?.frameIndex, 1)
    }

    func test_wrongDecodedDimensions_areDiagnosed() throws {
        let source = try decoder("gdcm-jpegls-labelmap8")
        var dataSet = source.dataSet
        dataSet.set(.init(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([19])))
        assertRefused(try rewrite(source, syntax: .jpegLSLossless, dataSet: dataSet),
                      code: .compressedFrameDecodeFailed, syntax: .jpegLSLossless)
    }

    private func decoder(_ name: String) throws -> DCMDecoder {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try DCMDecoder(contentsOf: root.appendingPathComponent("Fixtures/Segmentation/\(name).dcm"))
    }

    private func segmentation(_ name: String) throws -> DicomSegmentation {
        try XCTUnwrap(decoder(name).segmentation, name)
    }

    private func assertMetadata(_ value: DicomSegmentation, equals reference: DicomSegmentation, name: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value.rows, reference.rows, name, file: file, line: line)
        XCTAssertEqual(value.columns, reference.columns, name, file: file, line: line)
        XCTAssertEqual(value.segments, reference.segments, name, file: file, line: line)
        XCTAssertEqual(value.frames.count, reference.frames.count, name, file: file, line: line)
        XCTAssertEqual(value.frames.map(\.index), reference.frames.map(\.index), name, file: file, line: line)
        XCTAssertEqual(value.frames.map(\.segmentNumber), reference.frames.map(\.segmentNumber), name, file: file, line: line)
        XCTAssertEqual(value.frames.map(\.segmentAttribution), reference.frames.map(\.segmentAttribution), name, file: file, line: line)
        XCTAssertEqual(value.frames.map(\.geometry), reference.frames.map(\.geometry), name, file: file, line: line)
        XCTAssertEqual(value.frames.map(\.sourceImageReferences), reference.frames.map(\.sourceImageReferences), name, file: file, line: line)
        XCTAssertEqual(value.referencedInstancesBySeries, reference.referencedInstancesBySeries, name, file: file, line: line)
        XCTAssertEqual(value.frameOfReferenceUID, reference.frameOfReferenceUID, name, file: file, line: line)
        XCTAssertEqual(value.diagnostics, reference.diagnostics, name, file: file, line: line)
    }

    private func assertRefused(_ value: DicomSegmentation, code: DicomSegmentationDiagnostic.Code,
                               syntax: DicomTransferSyntax, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value.frames.isEmpty, file: file, line: line)
        XCTAssertEqual(value.diagnostics.first?.code, code, file: file, line: line)
        XCTAssertEqual(value.diagnostics.first?.transferSyntaxUID, syntax.rawValue, file: file, line: line)
        XCTAssertTrue(value.diagnostics.first?.message.contains(syntax.rawValue) == true, file: file, line: line)
    }

    private func rewrite(_ source: DCMDecoder, syntax: DicomTransferSyntax, fragments: [Data]? = nil,
                         dataSet: DicomDataSet? = nil) throws -> DicomSegmentation {
        var dataSet = dataSet ?? source.dataSet
        let fragments = try fragments ?? (0..<source.nImages).map {
            try source.makeEncapsulatedPixelFrameReader().frameData(at: $0)
        }
        do {
            let encapsulated = try DicomTranscoder.encapsulate(fragments: fragments)
            dataSet.set(.init(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(encapsulated.pixelData)))
        }
        let bytes = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: syntax,
            mediaStorageSOPClassUID: source.info(for: .sopClassUID), mediaStorageSOPInstanceUID: source.info(for: .sopInstanceUID)))
        return try XCTUnwrap(DCMDecoder(data: bytes).segmentation)
    }
}
