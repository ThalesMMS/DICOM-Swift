import Foundation
import XCTest
@testable import DicomCore

/// Isis issue #2514: a label map becomes BINARY Segmentation Storage for a receiver without Label Map Segmentation
/// Storage, with one frame per label and slice that holds it.
final class DicomSegmentationLabelmapBinaryConversionTests: XCTestCase {
    func test_labelmap_becomesOneBinaryFramePerLabelAndSlice() throws {
        for wide in [false, true] {
            let high = wide ? 300 : 5
            // Label 7 is declared but absent; label 9 is present but undeclared; 0 is the background.
            let planes: [[Int]] = [
                (0..<35).map { $0 < 10 ? 2 : 0 },
                (0..<35).map { $0 % 2 == 0 ? high : 9 },
                [Int](repeating: 0, count: 35),
                (0..<35).map { $0 < 5 ? 2 : ($0 < 12 ? high : 0) }
            ]
            let labelmap = model(planes: planes, labels: [0, 2, high, 7], wide: wide)
            let plan = try XCTUnwrap(DicomSegmentationBuilder.binaryPlan(forLabelmap: labelmap))
            XCTAssertEqual(plan.labels, [2, high])
            XCTAssertEqual(plan.sourceFrames, [[0, 3], [1, 3]])
            XCTAssertEqual(plan.frameCount, 4)
            XCTAssertEqual(plan.pixelDataByteCount, (4 * 35 + 7) / 8)

            let dataSet = DicomSegmentationBuilder.binaryDataSet(convertingLabelmap: labelmap, plan: plan,
                studyInstanceUID: "2.25.2514.1", seriesInstanceUID: "2.25.2514.2", sopInstanceUID: "2.25.2514.3")
            XCTAssertEqual(dataSet[0x00080016]?.stringValue, DicomSegmentationBuilder.segmentationStorageSOPClassUID)
            XCTAssertEqual(dataSet[0x00620001]?.stringValue, "BINARY")
            XCTAssertEqual(dataSet[0x00620013]?.stringValue, "NO", "labels of one map never overlap")
            XCTAssertNil(dataSet[0x00280120], "no Pixel Padding Value outside a label map")
            let bytes = try DicomDataSetWriter.part10Data(from: dataSet, options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomSegmentationBuilder.segmentationStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.2514.3"))
            let binary = try XCTUnwrap(DCMDecoder(data: bytes).segmentation)
            XCTAssertEqual(binary.segments.map(\.number), [1, 2])
            XCTAssertEqual(binary.segments.map(\.label), ["Label 2", "Label \(high)"])
            XCTAssertEqual(binary.segments.map { $0.propertyType?.codeValue }, ["T2", "T\(high)"])
            XCTAssertEqual(binary.frames.map(\.segmentNumber), [1, 1, 2, 2])
            XCTAssertEqual(binary.frames.map { $0.geometry?.imagePositionPatient?.z }, [0, 3, 1, 3])
            let expected = [(0, 2), (3, 2), (1, high), (3, high)].map { plane, label in
                planes[plane].map { UInt8($0 == label ? 1 : 0) }
            }
            XCTAssertEqual(binary.frames.map { $0.pixelData.storedValues }, expected)
            XCTAssertEqual(binary.frames.map { $0.sourceImageReferences.first?.referencedSOPInstanceUID },
                           ["2.25.2514.30", "2.25.2514.33", "2.25.2514.31", "2.25.2514.33"])
            XCTAssertTrue(binary.diagnostics.isEmpty, "\(binary.diagnostics)")
            let validation = try DicomInstanceValidator.validate(bytes)
            XCTAssertNotEqual(validation.outcome(requiring: Set(DicomValidationReport.Layer.allCases).subtracting([.operation])),
                              .failed, "\(validation.diagnostics.filter { $0.severity == .error })")
        }
    }

    func test_onlyBackgroundOrNotALabelmap_hasNoPlan() {
        XCTAssertNil(DicomSegmentationBuilder.binaryPlan(forLabelmap: model(planes: [[Int](repeating: 0, count: 35)],
                                                                           labels: [0, 1], wide: false)))
        let binary = DicomSegmentation(segmentationType: .binary, rows: 1, columns: 1,
                                       segments: [DicomSegment(number: 1, label: "Mask")],
                                       frames: [.init(index: 0, segmentNumber: 1, pixelData: .binary([1]))])
        XCTAssertNil(DicomSegmentationBuilder.binaryPlan(forLabelmap: binary))
    }

    // MARK: - Fixtures

    /// 5 × 7 planes at z = 0, 1, …, each derived from its own CT instance.
    private func model(planes: [[Int]], labels: [Int], wide: Bool) -> DicomSegmentation {
        let segments = labels.map { label in
            DicomSegment(number: label, label: "Label \(label)", algorithmType: "AUTOMATIC", algorithmName: "Model",
                         propertyCategory: DicomCodedConcept(codeValue: "C", codingSchemeDesignator: "99TEST", codeMeaning: "Category"),
                         propertyType: DicomCodedConcept(codeValue: "T\(label)", codingSchemeDesignator: "99TEST", codeMeaning: "Type"))
        }
        let frames = planes.enumerated().map { index, values in
            let reference = DicomSourceImageReference(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
                                                      referencedSOPInstanceUID: "2.25.2514.3\(index)")
            return DicomSegmentationFrame(
                index: index, segmentNumber: 0,
                geometry: DicomFrameGeometry(frameIndex: index, functionalGroups: DicomFrameFunctionalGroups(
                    frameContent: DicomFrameContent(dimensionIndexValues: [index + 1], stackID: nil, inStackPositionNumber: nil,
                                                    temporalPositionIndex: nil, frameAcquisitionNumber: nil),
                    pixelMeasures: DicomPixelMeasures(pixelSpacing: SIMD2<Double>(0.7, 0.7), sliceThickness: 1,
                                                      spacingBetweenSlices: 1),
                    planePosition: DicomPlanePosition(imagePositionPatient: SIMD3<Double>(0, 0, Double(index))),
                    planeOrientation: DicomPlaneOrientation(row: SIMD3<Double>(1, 0, 0), column: SIMD3<Double>(0, 1, 0)),
                    derivationImage: nil))!,
                sourceImageReferences: [reference],
                pixelData: .labelmap(wide ? .uint16(values.map { UInt16($0) }) : .uint8(values.map { UInt8($0) })))
        }
        return DicomSegmentation(frameOfReferenceUID: "2.25.2514.9", segmentationType: .labelmap, rows: 5, columns: 7,
                                 referencedSeriesInstanceUIDs: ["2.25.2514.8"], segments: segments, frames: frames,
                                 pixelPaddingValue: 0)
    }
}
