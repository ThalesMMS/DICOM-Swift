import DicomData
import Foundation

/// How a LABELMAP segmentation becomes BINARY Segmentation Storage (Isis issue #2514), for a receiver that does not
/// accept Label Map Segmentation Storage: one BINARY segment per declared label that some frame holds, numbered
/// from 1 in label order, each with a frame for every label map frame that holds its label.
public struct DicomLabelmapBinaryPlan: Equatable, Sendable {
    /// The label map's segment numbers, in the order they become BINARY segments 1, 2, …
    public let labels: [Int]
    /// For each BINARY segment, the indexes of the label map frames that hold its label.
    public let sourceFrames: [[Int]]
    /// Bytes of the BINARY Pixel Data: one bit per pixel, over every frame.
    public let pixelDataByteCount: Int

    public var frameCount: Int { sourceFrames.reduce(0) { $0 + $1.count } }
}

extension DicomSegmentationBuilder {
    /// The BINARY segments and frames `labelmap` becomes, without building them; nil when it is not a label map
    /// or holds no declared label besides its background.
    public static func binaryPlan(forLabelmap labelmap: DicomSegmentation) -> DicomLabelmapBinaryPlan? {
        guard labelmap.segmentationType == .labelmap else { return nil }
        let background = labelmap.backgroundSegmentNumber
        let declared = Set(labelmap.segments.map(\.number)).subtracting(background.map { [$0] } ?? [])
        var framesByLabel: [Int: [Int]] = [:]
        var counts: [Int] = []
        for (index, frame) in labelmap.frames.enumerated() {
            guard let plane = frame.pixelData.labelmapPlane else { continue }
            let binCount = plane.bitsAllocated == 8 ? 256 : 65_536
            if counts.count != binCount { counts = [Int](repeating: 0, count: binCount) }
            plane.accumulateHistogram(into: &counts)
            for label in counts.indices where counts[label] > 0 {
                if declared.contains(label) { framesByLabel[label, default: []].append(index) }
                counts[label] = 0
            }
        }
        let labels = framesByLabel.keys.sorted()
        guard !labels.isEmpty else { return nil }
        let sourceFrames = labels.map { framesByLabel[$0] ?? [] }
        let bitCount = sourceFrames.reduce(0) { $0 + $1.count } * labelmap.rows * labelmap.columns
        return DicomLabelmapBinaryPlan(labels: labels, sourceFrames: sourceFrames, pixelDataByteCount: (bitCount + 7) / 8)
    }

    /// `labelmap` as BINARY Segmentation Storage: each planned segment keeps its label map segment's description and
    /// codes under its new number, and each frame the geometry and source references of the label map frame it
    /// comes from. The segments cannot overlap. The bits are packed in one pass over the label planes, so no frame is
    /// held unpacked.
    public static func binaryDataSet(
        convertingLabelmap labelmap: DicomSegmentation,
        plan: DicomLabelmapBinaryPlan,
        studyInstanceUID: String,
        seriesInstanceUID: String,
        sopInstanceUID: String? = nil,
        contentLabel: String = "SEGMENTATION",
        options: DicomSegmentationBuildOptions = DicomSegmentationBuildOptions()
    ) -> DicomDataSet {
        let segmentsByNumber = Dictionary(labelmap.segments.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        let segments = plan.labels.enumerated().compactMap { index, label in
            segmentsByNumber[label].map { renumbered($0, as: index + 1) }
        }
        var frames: [DicomSegmentationFrame] = []
        frames.reserveCapacity(plan.frameCount)
        for (segment, sourceIndexes) in plan.sourceFrames.enumerated() {
            for sourceIndex in sourceIndexes {
                let source = labelmap.frames[sourceIndex]
                frames.append(DicomSegmentationFrame(index: frames.count, segmentNumber: segment + 1, geometry: source.geometry,
                                                     sourceImageReferences: source.sourceImageReferences,
                                                     pixelData: .binary([])))
            }
        }
        let binary = DicomSegmentation(
            sopInstanceUID: sopInstanceUID, frameOfReferenceUID: labelmap.frameOfReferenceUID, segmentationType: .binary,
            rows: labelmap.rows, columns: labelmap.columns, referencedSeriesInstanceUIDs: labelmap.referencedSeriesInstanceUIDs,
            segments: segments, frames: frames, segmentsOverlap: .no, contentLabel: labelmap.contentLabel,
            contentDescription: labelmap.contentDescription, contentCreatorName: labelmap.contentCreatorName,
            referencedInstancesBySeries: labelmap.referencedInstancesBySeries,
            sharedFunctionalGroups: labelmap.sharedFunctionalGroups)
        return makeDataSet(from: binary, studyInstanceUID: studyInstanceUID, seriesInstanceUID: seriesInstanceUID,
                           sopInstanceUID: sopInstanceUID, contentLabel: contentLabel, options: options) { _ in
            [DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB,
                              value: .bytes(packedBits(of: labelmap, plan: plan)))]
        }
    }

    private static func renumbered(_ segment: DicomSegment, as number: Int) -> DicomSegment {
        DicomSegment(number: number, label: segment.label, description: segment.description,
                     algorithmType: segment.algorithmType, algorithmName: segment.algorithmName,
                     propertyCategory: segment.propertyCategory, propertyType: segment.propertyType,
                     trackingID: segment.trackingID, trackingUID: segment.trackingUID,
                     recommendedDisplayCIELabValue: segment.recommendedDisplayCIELabValue,
                     algorithmIdentification: segment.algorithmIdentification, anatomicRegion: segment.anatomicRegion,
                     anatomicRegionModifiers: segment.anatomicRegionModifiers,
                     propertyTypeModifiers: segment.propertyTypeModifiers,
                     recommendedDisplayGrayscaleValue: segment.recommendedDisplayGrayscaleValue)
    }

    /// Every BINARY frame's bits, in frame order and running on from one frame to the next: each label map plane is
    /// read once, and a pixel's label names the BINARY frame whose bit it sets.
    private static func packedBits(of labelmap: DicomSegmentation, plan: DicomLabelmapBinaryPlan) -> Data {
        let pixelCount = labelmap.rows * labelmap.columns
        // The BINARY frame of each (label map frame, label) pair.
        var targetsBySource: [Int: [(label: Int, frame: Int)]] = [:]
        var frame = 0
        for (segment, sourceIndexes) in plan.sourceFrames.enumerated() {
            for sourceIndex in sourceIndexes {
                targetsBySource[sourceIndex, default: []].append((plan.labels[segment], frame))
                frame += 1
            }
        }
        // Written in place, so the Pixel Data is never held twice.
        var data = Data(count: plan.pixelDataByteCount)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var frameOfLabel: [Int] = []
            for (sourceIndex, targets) in targetsBySource {
                guard let plane = labelmap.frames[sourceIndex].pixelData.labelmapPlane else { continue }
                let binCount = plane.bitsAllocated == 8 ? 256 : 65_536
                if frameOfLabel.count != binCount { frameOfLabel = [Int](repeating: -1, count: binCount) }
                for target in targets { frameOfLabel[target.label] = target.frame }
                frameOfLabel.withUnsafeBufferPointer { frameOfLabel in
                    func mark(_ pixel: Int, _ label: Int) {
                        let frame = frameOfLabel[label]
                        guard frame >= 0 else { return }
                        let bit = frame * pixelCount + pixel
                        bytes[bit >> 3] |= UInt8(1 << (bit & 7))
                    }
                    switch plane {
                    case .uint8(let values):
                        values.withUnsafeBufferPointer { values in
                            for pixel in 0..<min(values.count, pixelCount) { mark(pixel, Int(values[pixel])) }
                        }
                    case .uint16(let values):
                        values.withUnsafeBufferPointer { values in
                            for pixel in 0..<min(values.count, pixelCount) { mark(pixel, Int(values[pixel])) }
                        }
                    }
                }
                for target in targets { frameOfLabel[target.label] = -1 }
            }
        }
        return data
    }
}
