//
//  DicomPixelRedactionPlan.swift
//
//  Clean Pixel Data Option (PS3.15 E.3.1): which pixels of an instance are blanked, decided from the sources
//  in a fixed order, and the blanking of native pixel data. Detection never shrinks the mask; when no source
//  applies the decision is unresolved, never a silent pass.
//

import Foundation

/// Pixel regions a device is known to burn identifying text into. Only entries checked against real samples
/// belong in `verified`; fractions or coordinates without such a check must not be added.
public struct DicomPixelRedactionTemplate: Equatable, Sendable {
    public var name: String
    /// Matched case-insensitively against Modality (0008,0060), Manufacturer (0008,0070) and Manufacturer's Model
    /// Name (0008,1090); a nil model or matrix matches any.
    public var modality: String
    public var manufacturer: String
    public var modelName: String?
    public var rows: Int?
    public var columns: Int?
    public var regions: [DicomPixelEdit.Region]

    public init(name: String, modality: String, manufacturer: String, modelName: String? = nil, rows: Int? = nil, columns: Int? = nil,
                regions: [DicomPixelEdit.Region]) {
        self.name = name
        self.modality = modality
        self.manufacturer = manufacturer
        self.modelName = modelName
        self.rows = rows
        self.columns = columns
        self.regions = regions
    }

    /// Templates verified on real samples. Empty until such entries exist.
    public static let verified: [DicomPixelRedactionTemplate] = []

    func matches(_ dataSet: DicomDataSet, rows: Int, columns: Int) -> Bool {
        func same(_ tag: Int, _ expected: String) -> Bool {
            (dataSet.string(for: tag) ?? "").trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(expected) == .orderedSame
        }
        return same(0x0008_0060, modality) && same(0x0008_0070, manufacturer) && (modelName.map { same(0x0008_1090, $0) } ?? true)
            && (self.rows ?? rows) == rows && (self.columns ?? columns) == columns
    }
}

/// The pixels to blank, accumulated in this order: regions from the caller (always applied), everything outside
/// the Sequence of Ultrasound Regions when the instance declares where the clinical image is, and the matching
/// device templates. No source means the plan is unresolved.
public struct DicomPixelRedactionPlan: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case caller
        case ultrasoundRegions
        case template(String)
    }

    public let rows: Int
    public let columns: Int
    public let sources: [Source]
    /// Rectangles blanked in every frame (caller and templates), clipped to the matrix.
    let blanked: [DicomPixelEdit.Region]
    /// Per frame, the rectangles kept by the ultrasound inversion; nil when the inversion does not apply. A frame
    /// without a valid region keeps nothing.
    let keptByFrame: [[DicomPixelEdit.Region]]?

    public var isResolved: Bool { !sources.isEmpty }

    /// - Parameter ultrasoundRegions: the valid ultrasound regions that apply to a frame.
    public init(dataSet: DicomDataSet, rows: Int, columns: Int, frames: Int, callerRegions: [DicomPixelEdit.Region],
                templates: [DicomPixelRedactionTemplate], ultrasoundRegions: (Int) -> [DicomUltrasoundRegion]) {
        self.rows = rows
        self.columns = columns
        var sources: [Source] = []
        var blanked: [DicomPixelEdit.Region] = []
        let caller = callerRegions.compactMap { Self.clipped($0, rows: rows, columns: columns) }
        if !caller.isEmpty { sources.append(.caller); blanked += caller }

        let kept = (0..<max(1, frames)).map { frame in
            ultrasoundRegions(frame).compactMap { region in
                Self.clipped(.init(x: region.minX0, y: region.minY0, width: region.maxX1 - region.minX0 + 1,
                                   height: region.maxY1 - region.minY0 + 1), rows: rows, columns: columns)
            }
        }
        if kept.contains(where: { !$0.isEmpty }) {
            sources.append(.ultrasoundRegions)
            keptByFrame = kept
        } else {
            keptByFrame = nil
        }

        for template in templates where template.matches(dataSet, rows: rows, columns: columns) {
            let regions = template.regions.compactMap { Self.clipped($0, rows: rows, columns: columns) }
            if !regions.isEmpty { sources.append(.template(template.name)); blanked += regions }
        }
        self.sources = sources
        self.blanked = blanked
    }

    public init(decoder: DCMDecoder, dataSet: DicomDataSet, callerRegions: [DicomPixelEdit.Region], templates: [DicomPixelRedactionTemplate]) {
        let descriptor = decoder.pixelDataDescriptor
        self.init(dataSet: dataSet, rows: descriptor?.rows ?? 0, columns: descriptor?.columns ?? 0, frames: descriptor?.numberOfFrames ?? 1,
                  callerRegions: callerRegions, templates: templates, ultrasoundRegions: { decoder.ultrasoundRegions(forFrame: $0) })
    }

    /// Row-major mask of the pixels blanked in a frame.
    public func mask(frame: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: rows * columns)
        if let keptByFrame {
            mask = [Bool](repeating: true, count: rows * columns)
            let kept = keptByFrame.indices.contains(frame) ? keptByFrame[frame] : []
            for region in kept { fill(&mask, region, false) }
        }
        for region in blanked { fill(&mask, region, true) }
        return mask
    }

    private func fill(_ mask: inout [Bool], _ region: DicomPixelEdit.Region, _ value: Bool) {
        for row in region.y..<(region.y + region.height) {
            let start = row * columns + region.x
            for index in start..<(start + region.width) { mask[index] = value }
        }
    }

    private static func clipped(_ region: DicomPixelEdit.Region, rows: Int, columns: Int) -> DicomPixelEdit.Region? {
        let x0 = max(0, region.x), y0 = max(0, region.y)
        let x1 = min(columns, region.x + region.width), y1 = min(rows, region.y + region.height)
        guard x1 > x0, y1 > y0 else { return nil }
        return .init(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Blanks the masked pixels of native, uncompressed pixel data with the darkest stored value (the maximum for
    /// MONOCHROME1, zero in every channel for RGB). Returns why the layout cannot be blanked instead of guessing.
    public func blank(_ pixels: inout Data, descriptor: DicomPixelDataDescriptor) -> String? {
        let bytesPerSample = descriptor.bitsAllocated / 8
        let photometric = descriptor.photometricInterpretation.trimmingCharacters(in: .whitespaces).uppercased()
        guard descriptor.rows == rows, descriptor.columns == columns, [1, 2].contains(bytesPerSample), descriptor.bitsAllocated % 8 == 0,
              (descriptor.samplesPerPixel == 1 && ["MONOCHROME1", "MONOCHROME2", "PALETTE COLOR"].contains(photometric))
                || (descriptor.samplesPerPixel == 3 && photometric == "RGB") else {
            return "pixel layout \(photometric) \(descriptor.bitsAllocated)-bit, \(descriptor.samplesPerPixel) samples, cannot be blanked"
        }
        let signed = descriptor.pixelRepresentation == 1
        let bitsStored = max(1, min(descriptor.bitsStored, descriptor.bitsAllocated))
        let value = photometric == "MONOCHROME1" ? (signed ? (1 << (bitsStored - 1)) - 1 : (1 << bitsStored) - 1)
            : (signed && descriptor.samplesPerPixel == 1 ? -(1 << (bitsStored - 1)) : 0)
        let raw = UInt16(truncatingIfNeeded: value)
        let samples = descriptor.samplesPerPixel
        let planar = descriptor.planarConfiguration == 1 && samples == 3
        let frameBytes = rows * columns * samples * bytesPerSample
        let frames = max(1, descriptor.numberOfFrames)
        guard pixels.count >= frames * frameBytes else { return "pixel data is shorter than its declared frames" }
        pixels.withUnsafeMutableBytes { buffer in
            for frame in 0..<frames {
                let mask = mask(frame: frame)
                for pixel in mask.indices where mask[pixel] {
                    for channel in 0..<samples {
                        let sample = planar ? channel * rows * columns + pixel : pixel * samples + channel
                        let offset = frame * frameBytes + sample * bytesPerSample
                        if bytesPerSample == 1 {
                            buffer[offset] = UInt8(truncatingIfNeeded: raw)
                        } else {
                            buffer[offset] = UInt8(raw & 0xFF)
                            buffer[offset + 1] = UInt8(raw >> 8)
                        }
                    }
                }
            }
        }
        return nil
    }
}
