import Foundation
import XCTest
@testable import DicomCore

/// Isis issue #2513: SEG Pixel Data written in RLE Lossless, with each frame deflated or with the whole dataset
/// deflated reads back bit for bit, one frame at a time for the encapsulated syntaxes.
final class DicomSegmentationPixelEncodingTests: XCTestCase {
    func test_everyEncoding_readsBackEveryTypeBitForBit() throws {
        for model in [labelmap(wide: false), labelmap(wide: true), fractional(), binary()] {
            let native = try part10(model, encoding: .native)
            let nativeErrors = try errors(in: native.bytes)
            for encoding in DicomSegmentationPixelEncoding.allCases {
                let name = "\(model.segmentationType.rawValue) \(encoding.rawValue)"
                let written = try part10(model, encoding: encoding)
                XCTAssertEqual(written.transferSyntax, encoding.applied(to: model.segmentationType).transferSyntax, name)
                let decoder = try DCMDecoder(data: written.bytes)
                XCTAssertEqual(decoder.transferSyntaxUID, written.transferSyntax.rawValue, name)
                let parsed = try XCTUnwrap(decoder.segmentation, name)
                XCTAssertEqual(parsed.frames.map(\.pixelData), model.frames.map(\.pixelData), name)
                XCTAssertEqual(parsed.segments, model.segments, name)
                XCTAssertEqual(try errors(in: written.bytes), nativeErrors, "the validator finds nothing new: \(name)")
            }
        }
    }

    func test_binarySegmentation_staysNativeUnderRLE_andFramesDeflateOneByOne() throws {
        XCTAssertEqual(DicomSegmentationPixelEncoding.rleLossless.applied(to: .binary), .native)
        XCTAssertEqual(DicomSegmentationPixelEncoding.deflatedFrames.applied(to: .binary), .deflatedFrames)
        XCTAssertEqual(DicomSegmentationPixelEncoding.rleLossless.applied(to: .labelmap), .rleLossless)
        let decoder = try DCMDecoder(data: part10(binary(), encoding: .deflatedFrames).bytes)
        XCTAssertEqual(try decoder.makeEncapsulatedPixelFrameReader().frameCount, 3, "one fragment per frame")
    }

    /// A sparse 512 × 512 label map: every frame is its own fragment behind the Basic Offset Table, and both
    /// encapsulated encodings are a small part of the native Pixel Data.
    func test_sparseLabelmap_isOneSmallFragmentPerFrame() throws {
        let model = labelmap(rows: 512, columns: 512, frames: 4) { frame, pixel in
            (pixel / 512) / 64 == frame && pixel % 512 < 100 ? UInt16(frame + 1) : 0
        }
        let nativeSize = try part10(model, encoding: .native).bytes.count
        XCTAssertGreaterThan(nativeSize, 4 * 512 * 512)
        for encoding in [DicomSegmentationPixelEncoding.rleLossless, .deflatedFrames, .deflatedDataSet] {
            let written = try part10(model, encoding: encoding)
            XCTAssertLessThan(written.bytes.count, nativeSize / 20, encoding.rawValue)
            let decoder = try DCMDecoder(data: written.bytes)
            if encoding != .deflatedDataSet {
                let reader = try decoder.makeEncapsulatedPixelFrameReader()
                XCTAssertEqual(reader.frameCount, 4, encoding.rawValue)
                XCTAssertFalse(reader.descriptor.basicOffsetTable.isEmpty, encoding.rawValue)
            }
            XCTAssertEqual(try XCTUnwrap(decoder.segmentation).frames.map(\.pixelData), model.frames.map(\.pixelData))
        }
    }

    /// Isis issue #2516: frames past the per-frame budget are declared unevaluated on the codestream and pixel layers
    /// only; the other layers are evaluated as for a small object.
    func test_encapsulatedFramesPastTheBudget_areDeclaredUnevaluatedWithoutStoppingTheOtherLayers() throws {
        let bytes = try part10(labelmap(wide: false), encoding: .rleLossless).bytes
        let full = try DicomInstanceValidator.validate(bytes)
        XCTAssertFalse(full.diagnostics.contains { $0.code == .evaluationLimitReached })
        let limited = try DicomInstanceValidator.validate(bytes, limits: .init(maximumFrames: 2))
        let limits = limited.diagnostics.filter { $0.code == .evaluationLimitReached }
        XCTAssertEqual(Set(limits.map(\.layer)), [.codestream, .pixelsAndGeometry])
        XCTAssertTrue(limits.allSatisfy { $0.path == [.tag(0x7FE00010), .frame(2)] }, "\(limits)")
        XCTAssertEqual(limited.diagnostics.filter { $0.severity == .error }, full.diagnostics.filter { $0.severity == .error })
        XCTAssertTrue(limited.evaluatedLayers.isSuperset(of: [.structure, .vrAndVM, .attributes]))
    }

    /// Encapsulated frames of a syntax the parser does not decode are refused instead of read as native bytes.
    func test_framesOfAnotherCompressedSyntax_areNotReadAsNativeBytes() throws {
        let model = labelmap(wide: false)
        let encoded = try DicomSegmentationBuilder.encodedDataSet(from: model, studyInstanceUID: "2.25.2513",
                                                                  seriesInstanceUID: "2.25.2514", encoding: .rleLossless)
        let bytes = try DicomDataSetWriter.part10Data(from: encoded.dataSet, options: DicomPart10WriterOptions(
            transferSyntax: .jpegLSLossless, mediaStorageSOPClassUID: DicomSegmentationBuilder.labelMapSegmentationStorageSOPClassUID,
            mediaStorageSOPInstanceUID: "2.25.2515"))
        let parsed = try XCTUnwrap(DCMDecoder(data: bytes).segmentation)
        XCTAssertTrue(parsed.frames.isEmpty)
        XCTAssertEqual(parsed.diagnostics.first?.code, .compressedFrameDecodeFailed)
    }

    // MARK: - Fixtures

    private func part10(_ model: DicomSegmentation, encoding: DicomSegmentationPixelEncoding) throws
        -> (bytes: Data, transferSyntax: DicomTransferSyntax) {
        let encoded = try DicomSegmentationBuilder.encodedDataSet(from: model, studyInstanceUID: "2.25.2513",
                                                                  seriesInstanceUID: "2.25.2514",
                                                                  sopInstanceUID: "2.25.2515", encoding: encoding)
        let sopClassUID = model.segmentationType == .labelmap
            ? DicomSegmentationBuilder.labelMapSegmentationStorageSOPClassUID
            : DicomSegmentationBuilder.segmentationStorageSOPClassUID
        let bytes = try DicomDataSetWriter.part10Data(from: encoded.dataSet, options: DicomPart10WriterOptions(
            transferSyntax: encoded.transferSyntax, mediaStorageSOPClassUID: sopClassUID,
            mediaStorageSOPInstanceUID: "2.25.2515"))
        return (bytes, encoded.transferSyntax)
    }

    private func errors(in bytes: Data) throws -> [DicomValidationReport.Diagnostic] {
        try DicomInstanceValidator.validate(bytes).diagnostics.filter { $0.severity == .error }
    }

    /// 5 × 7 frames, odd so that fragments and rows are padded; labels 1...3 (or up to 300 when `wide`).
    private func labelmap(wide: Bool) -> DicomSegmentation {
        labelmap(rows: 5, columns: 7, frames: 3, maximum: wide ? 300 : 3) { frame, pixel in
            pixel % 4 == frame ? 0 : UInt16((pixel + frame) % (wide ? 301 : 4))
        }
    }

    private func labelmap(rows: Int, columns: Int, frames: Int, maximum: UInt16 = 4,
                          label: (_ frame: Int, _ pixel: Int) -> UInt16) -> DicomSegmentation {
        let segments = (0...Int(maximum)).map { DicomSegment(number: $0, label: "Label \($0)") }
        return DicomSegmentation(segmentationType: .labelmap, rows: rows, columns: columns, segments: segments,
            frames: (0..<frames).map { frame in
                let values = (0..<(rows * columns)).map { label(frame, $0) }
                return DicomSegmentationFrame(index: frame, segmentNumber: 0, geometry: geometry(frame),
                    pixelData: .labelmap(maximum > 255 ? .uint16(values) : .uint8(values.map { UInt8($0) })))
            }, pixelPaddingValue: 0)
    }

    private func fractional() -> DicomSegmentation {
        DicomSegmentation(segmentationType: .fractional, fractionalType: .probability, rows: 5, columns: 7,
            segments: [DicomSegment(number: 1, label: "Probability", algorithmType: "AUTOMATIC", algorithmName: "Model")],
            frames: (0..<3).map { frame in
                DicomSegmentationFrame(index: frame, segmentNumber: 1, geometry: geometry(frame),
                    pixelData: .fractional(values: (0..<35).map { UInt8(($0 * 7 + frame) % 256) }, maximumFractionalValue: 255))
            })
    }

    /// 35 pixels per frame, so native frames share bytes and a frame of its own is padded.
    private func binary() -> DicomSegmentation {
        DicomSegmentation(segmentationType: .binary, rows: 5, columns: 7,
            segments: [DicomSegment(number: 1, label: "Mask", algorithmType: "MANUAL")],
            frames: (0..<3).map { frame in
                DicomSegmentationFrame(index: frame, segmentNumber: 1, geometry: geometry(frame),
                    pixelData: .binary((0..<35).map { UInt8(($0 + frame) % 3 == 0 ? 1 : 0) }))
            })
    }

    private func geometry(_ frame: Int) -> DicomFrameGeometry {
        DicomFrameGeometry(
            frameIndex: frame,
            functionalGroups: DicomFrameFunctionalGroups(
                frameContent: DicomFrameContent(dimensionIndexValues: [frame + 1], stackID: "SEG",
                    inStackPositionNumber: frame + 1, temporalPositionIndex: nil, frameAcquisitionNumber: nil),
                pixelMeasures: DicomPixelMeasures(pixelSpacing: SIMD2<Double>(0.7, 0.7), sliceThickness: 1,
                    spacingBetweenSlices: 1),
                planePosition: DicomPlanePosition(imagePositionPatient: SIMD3<Double>(0, 0, Double(frame))),
                planeOrientation: DicomPlaneOrientation(row: SIMD3<Double>(1, 0, 0), column: SIMD3<Double>(0, 1, 0)),
                derivationImage: nil
            )
        )!
    }
}
