import Darwin
import Foundation
import XCTest
@testable import DicomCore

/// Label maps the size of a TotalSegmentator result (issue #2501): 8-bit planes stay 8-bit,
/// segments are expanded only on request, and Part 10 streams the pixel data to the file.
final class DicomLabelmapSegmentationScaleTests: XCTestCase {
    func test_labelmapPlanes_keepTheirStoredWidthThroughBuildAndParse() throws {
        for maximum: UInt16 in [117, 300] {
            // 18 × 18 voxels per frame hold every label up to 300, so no segment is absent.
            let model = labelmap(rows: 18, columns: 18, frames: 3, maximum: maximum)
            let dataSet = build(model)
            XCTAssertEqual(dataSet[0x00280100]?.intValue, maximum > 255 ? 16 : 8)

            let parsed = try parse(dataSet)
            XCTAssertEqual(parsed.frames.map(\.pixelData), model.frames.map(\.pixelData))
            for frame in parsed.frames {
                XCTAssertEqual(frame.pixelData.labelmapPlane?.bitsAllocated, maximum > 255 ? 16 : 8)
            }
            XCTAssertEqual(parsed.maximumLabelValue, maximum)
            XCTAssertEqual(parsed.backgroundSegmentNumber, 0)
            XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
        }
    }

    func test_labelmapForSegment_isolatesOneSegmentOnRequest() throws {
        let model = labelmap(rows: 2, columns: 3, frames: 2, maximum: 5)
        let isolated = try XCTUnwrap(model.labelmap(forSegment: 4))
        let expected = model.frames.flatMap { frame in
            (frame.pixelData.labelmapPlane?.widened ?? []).map { $0 == 4 ? UInt16(4) : 0 }
        }
        XCTAssertEqual(isolated.binarized(threshold: 1), expected)
        XCTAssertEqual(isolated.frameIndexes, [0, 1])
        XCTAssertNil(model.labelmap(forSegment: 99))
        XCTAssertEqual(model.labelmapsBySegment.keys.sorted(), Array(0...5))
    }

    func test_backgroundSegment_followsPixelPaddingThenTheBackgroundType() {
        let background = DicomCodedConcept(codeValue: "125040", codingSchemeDesignator: "DCM", codeMeaning: "Background")
        func model(segments: [DicomSegment], padding: UInt16?, type: DicomSegmentationType = .labelmap) -> DicomSegmentation {
            DicomSegmentation(segmentationType: type, rows: 1, columns: 2, segments: segments,
                              frames: [.init(index: 0, segmentNumber: 0, pixelData: .labelmap(.uint8([0, 1])))],
                              pixelPaddingValue: padding)
        }
        let zeroAndOne = [DicomSegment(number: 0, label: "Background"), DicomSegment(number: 1, label: "Liver")]
        XCTAssertEqual(model(segments: zeroAndOne, padding: 0).backgroundSegmentNumber, 0)
        XCTAssertNil(model(segments: [DicomSegment(number: 1, label: "Liver")], padding: 0).backgroundSegmentNumber)
        XCTAssertNil(model(segments: zeroAndOne, padding: nil).backgroundSegmentNumber)
        let typed = [DicomSegment(number: 7, label: "Air", propertyType: background), DicomSegment(number: 1, label: "Liver")]
        XCTAssertEqual(model(segments: typed, padding: nil).backgroundSegmentNumber, 7)
        XCTAssertNil(model(segments: zeroAndOne, padding: 0, type: .binary).backgroundSegmentNumber)
    }

    func test_absentLabels_areReportedAsSegmentsWithoutFrames() throws {
        let segments = (0...3).map { DicomSegment(number: $0, label: "Label \($0)") }
        let model = DicomSegmentation(segmentationType: .labelmap, rows: 1, columns: 3, segments: segments,
            frames: [.init(index: 0, segmentNumber: 0, geometry: geometry(frameIndex: 0, z: 1),
                           pixelData: .labelmap(.uint8([0, 1, 3])))],
            pixelPaddingValue: 0)
        let parsed = try parse(build(model))
        XCTAssertEqual(parsed.diagnostics.filter { $0.code == .segmentWithoutFrames }.map(\.segmentIndex), [2])
        XCTAssertFalse(parsed.diagnostics.contains { $0.code == .labelmapValueWithoutSegment })
    }

    func test_streamingWrite_writesTheSameBytesAsPart10Data() throws {
        // 512 × 512 × 5 bytes of Pixel Data crosses the streaming threshold; 4 × 5 × 3 stays in the block path.
        for model in [labelmap(rows: 512, columns: 512, frames: 5, maximum: 117),
                      labelmap(rows: 4, columns: 5, frames: 3, maximum: 117)] {
            let dataSet = build(model)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("labelmap-write-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("seg.dcm")

            try Data("stale".utf8).write(to: url)
            try DicomDataSetWriter.write(dataSet, to: url)
            XCTAssertEqual(try Data(contentsOf: url), try DicomDataSetWriter.part10Data(from: dataSet))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["seg.dcm"])

            let reread = try XCTUnwrap(try DCMDecoder(contentsOf: url).segmentation)
            XCTAssertEqual(reread.frames.map(\.pixelData), model.frames.map(\.pixelData))
        }
    }

    /// Opt-in: `DICOM_SEG_LABELMAP_WORKLOAD=<slices>` builds a 512 × 512 × slices label map with a
    /// background and 117 segments, streams it to a file and parses it back, printing the growth
    /// of the process footprint at each step.
    func test_largeLabelmapWorkload_staysNearOneLabelVolume() throws {
        guard let slices = ProcessInfo.processInfo.environment["DICOM_SEG_LABELMAP_WORKLOAD"].flatMap(Int.init) else {
            throw XCTSkip("Set DICOM_SEG_LABELMAP_WORKLOAD to the slice count, e.g. 300 or 1203")
        }
        let rows = 512, columns = 512
        let volumeBytes = rows * columns * slices
        let start = footprint()
        let model = labelmap(rows: rows, columns: columns, frames: slices, maximum: 117)
        let modelReady = footprint()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("labelmap-\(UUID().uuidString).dcm")
        defer { try? FileManager.default.removeItem(at: url) }
        var peakAfterModel = modelReady
        do {
            let dataSet = build(model)
            peakAfterModel = max(peakAfterModel, footprint())
            try DicomDataSetWriter.write(dataSet, to: url)
            peakAfterModel = max(peakAfterModel, footprint())
        }
        let written = footprint()
        let fileSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        let parsed = try XCTUnwrap(try DCMDecoder(contentsOf: url).segmentation)
        let parsedReady = footprint()
        XCTAssertEqual(parsed.frames.count, slices)
        XCTAssertEqual(parsed.frames[slices / 2].pixelData, model.frames[slices / 2].pixelData)
        XCTAssertTrue(parsed.frames.allSatisfy { $0.pixelData.labelmapPlane?.bitsAllocated == 8 })

        let mib = { (bytes: Int) in bytes >> 20 }
        print("labelmap workload \(rows)x\(columns)x\(slices): volume \(mib(volumeBytes)) MiB, file \(mib(fileSize)) MiB, "
            + "model +\(mib(modelReady - start)) MiB, build+write peak +\(mib(peakAfterModel - modelReady)) MiB, "
            + "after write +\(mib(written - modelReady)) MiB, parse +\(mib(parsedReady - written)) MiB")
        // Building holds the Pixel Data once next to the model; writing streams it; parsing holds one volume.
        XCTAssertLessThan(peakAfterModel - modelReady, volumeBytes + volumeBytes / 2)
        XCTAssertLessThan(parsedReady - written, volumeBytes + volumeBytes / 2)
    }

    /// Isis issue #2516: a label map of 1,203 frames of 512 × 512, above 256 MiB, each frame referencing its own source
    /// CT instance, is validated like a small one, and faults injected into it are found. Every frame shares one
    /// plane, so the model stays small.
    func test_labelmapAbove256MiB_isValidated_andInjectedFaultsAreFound() throws {
        let trustedLimits = DicomInstanceValidator.Limits(maximumInputBytes: .max, maximumFrames: .max,
                                                        maximumObjectBytes: .max, maximumObjectFrames: .max)
        var plane = [UInt8](repeating: 0, count: 512 * 512)
        for pixel in plane.indices where pixel % 512 < 200 { plane[pixel] = pixel / 512 < 256 ? 1 : 2 }
        let anatomy = DicomCodedConcept(codeValue: "123037004", codingSchemeDesignator: "SCT", codeMeaning: "Anatomical Structure")
        let segments = (0...2).map { DicomSegment(number: $0, label: "Structure \($0)", algorithmType: "AUTOMATIC",
            algorithmName: "Model", propertyCategory: anatomy,
            propertyType: DicomCodedConcept(codeValue: "7896100\($0)", codingSchemeDesignator: "SCT", codeMeaning: "Organ \($0)")) }
        let model = DicomSegmentation(frameOfReferenceUID: "2.25.2516.9", segmentationType: .labelmap, rows: 512,
            columns: 512, referencedSeriesInstanceUIDs: ["2.25.2516.1"], segments: segments, frames: (0..<1_203).map { index in
                DicomSegmentationFrame(index: index, segmentNumber: 0, geometry: geometry(frameIndex: index, z: Double(index)),
                    sourceImageReferences: [DicomSourceImageReference(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
                                                                      referencedSOPInstanceUID: "2.25.2516.1.\(index)")],
                    pixelData: .labelmap(.uint8(plane)))
            }, pixelPaddingValue: 0)
        let dataSet = build(model)
        let pixelData = try XCTUnwrap(dataSet[0x7FE00010]?.bytesValue)
        do {
            let bytes = try DicomDataSetWriter.part10Data(from: dataSet)
            XCTAssertGreaterThan(bytes.count, 256 * 1_024 * 1_024)
            let limited = try DicomInstanceValidator.validate(bytes)
            XCTAssertTrue(limited.diagnostics.contains { $0.code == .evaluationLimitReached },
                          "network/import defaults bound whole-object validation work")
            let report = try DicomInstanceValidator.validate(bytes, limits: trustedLimits)
            XCTAssertTrue(report.evaluatedLayers.isSuperset(of: [.structure, .vrAndVM, .attributes, .references,
                                                                 .pixelsAndGeometry]), "\(report.evaluatedLayers)")
            XCTAssertFalse(report.diagnostics.contains { $0.code == .evaluationLimitReached }, "no layer stops at a limit")
            XCTAssertEqual(report.diagnostics.filter { $0.severity == .error }, [])
            // The 1,203 source instances were not supplied as targets: one limitation, not one per reference.
            XCTAssertEqual(report.diagnostics.filter { $0.code == .referenceTargetUnavailable }.map(\.path), [[]])
        }

        // A duplicate Segment Number and a Pixel Data one frame short are both reported.
        var faulty = dataSet
        var items = try XCTUnwrap(dataSet[0x00620002]?.sequenceItems)
        var second = items[2].dataSet
        second.set(DicomDataElement(tag: 0x00620004, vr: .US, value: .unsignedIntegers([1])))
        items[2] = DicomSequenceItem(dataSet: second)
        faulty.set(DicomDataElement(tag: 0x00620002, vr: .SQ, value: .sequence(items)))
        faulty.set(DicomDataElement(tag: 0x7FE00010, vr: .OB, value: .bytes(pixelData.dropLast(512 * 512))))
        let report = try DicomInstanceValidator.validate(try DicomDataSetWriter.part10Data(from: faulty), limits: trustedLimits)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .pixelDataLengthMismatch && $0.severity == .error })
        XCTAssertTrue(report.diagnostics.contains {
            $0.severity == .error && $0.path.contains(.tag(0x00620004))
        }, "\(report.diagnostics.filter { $0.severity == .error })")
    }

    // MARK: - Helpers

    /// Background 0 (the Pixel Padding Value) and segments 1...maximum, with every label present.
    private func labelmap(rows: Int, columns: Int, frames: Int, maximum: UInt16) -> DicomSegmentation {
        let pixelCount = rows * columns
        let segments = [DicomSegment(number: 0, label: "Background")]
            + (1...Int(maximum)).map { DicomSegment(number: $0, label: "Structure \($0)") }
        let planes = (0..<frames).map { frame -> DicomLabelmapPlane in
            if maximum > 255 {
                return .uint16((0..<pixelCount).map { UInt16(($0 + frame) % (Int(maximum) + 1)) })
            }
            return .uint8((0..<pixelCount).map { UInt8(($0 + frame) % (Int(maximum) + 1)) })
        }
        return DicomSegmentation(segmentationType: .labelmap, rows: rows, columns: columns, segments: segments,
            frames: planes.enumerated().map { index, plane in
                DicomSegmentationFrame(index: index, segmentNumber: 0,
                                       geometry: geometry(frameIndex: index, z: Double(index)),
                                       pixelData: .labelmap(plane))
            }, pixelPaddingValue: 0)
    }

    private func build(_ model: DicomSegmentation) -> DicomDataSet {
        DicomSegmentationBuilder.dataSet(from: model, studyInstanceUID: "2.25.2501", seriesInstanceUID: "2.25.2502")
    }

    private func parse(_ dataSet: DicomDataSet) throws -> DicomSegmentation {
        try XCTUnwrap(DCMDecoder(data: try DicomDataSetWriter.part10Data(from: dataSet)).segmentation)
    }

    private func geometry(frameIndex: Int, z: Double) -> DicomFrameGeometry {
        DicomFrameGeometry(
            frameIndex: frameIndex,
            functionalGroups: DicomFrameFunctionalGroups(
                frameContent: DicomFrameContent(dimensionIndexValues: [frameIndex + 1], stackID: "SEG",
                    inStackPositionNumber: frameIndex + 1, temporalPositionIndex: nil, frameAcquisitionNumber: nil),
                pixelMeasures: DicomPixelMeasures(pixelSpacing: SIMD2<Double>(0.7, 0.7), sliceThickness: 1,
                    spacingBetweenSlices: 1),
                planePosition: DicomPlanePosition(imagePositionPatient: SIMD3<Double>(0, 0, z)),
                planeOrientation: DicomPlaneOrientation(row: SIMD3<Double>(1, 0, 0), column: SIMD3<Double>(0, 1, 0)),
                derivationImage: nil
            )
        )!
    }

    private func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
