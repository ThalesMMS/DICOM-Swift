//
//  DicomOverlayPlane.swift
//  DicomCore
//
//  Parses the repeating 60xx Overlay Plane groups, including legacy native overlays embedded in
//  unused Pixel Data bits.
//
//  Thales Matheus Mendonça Santos — July 2026
//

import Foundation

public struct DicomOverlayPlane: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case graphics
        case regionOfInterest
        case other(String)
    }

    public enum Source: Equatable, Sendable {
        case overlayData
        case embeddedPixelData(bitPosition: Int)
    }

    public let group: Int
    public let rows: Int
    public let columns: Int
    /// Zero-based image row where the overlay begins. DICOM encodes this as a
    /// one-based value and permits zero or negative origins.
    public let originRow: Int
    /// Zero-based image column where the overlay begins.
    public let originColumn: Int
    public let kind: Kind
    public let source: Source
    /// One byte per overlay pixel in row-major order, normalized to 0 or 1.
    public let mask: Data

    public init(
        group: Int,
        rows: Int,
        columns: Int,
        originRow: Int,
        originColumn: Int,
        kind: Kind,
        source: Source,
        mask: Data
    ) {
        self.group = group
        self.rows = rows
        self.columns = columns
        self.originRow = originRow
        self.originColumn = originColumn
        self.kind = kind
        self.source = source
        self.mask = mask
    }
}

public extension DCMDecoder {
    /// Returns the Overlay Planes that apply to a zero-based image frame.
    ///
    /// Current DICOM Overlay Data is decoded without loading Pixel Data.
    /// Retired embedded overlays are supported for native, single-sample
    /// Pixel Data so older CAD and annotation objects remain visible.
    func overlayPlanes(forFrame frameIndex: Int = 0) -> [DicomOverlayPlane] {
        guard frameIndex >= 0 else { return [] }
        let dataSet = self.dataSet
        let isLittleEndian = synchronized { littleEndian }
        let needsEmbeddedFrame = stride(from: 0x6000, through: 0x601E, by: 2).contains { group in
            dataSet.element(for: Self.overlayTag(group: group, element: 0x0010)) != nil &&
                dataSet.element(for: Self.overlayTag(group: group, element: 0x3000)) == nil
        }
        let embeddedFrame = needsEmbeddedFrame && !compressedImage ? getFrame(frameIndex) : nil

        return stride(from: 0x6000, through: 0x601E, by: 2).compactMap { group in
            Self.overlayPlane(
                group: group,
                frameIndex: frameIndex,
                dataSet: dataSet,
                embeddedFrame: embeddedFrame,
                littleEndian: isLittleEndian
            )
        }
    }
}

private extension DCMDecoder {
    static func overlayPlane(
        group: Int,
        frameIndex: Int,
        dataSet: DicomDataSet,
        embeddedFrame: DicomPixelFrame?,
        littleEndian: Bool
    ) -> DicomOverlayPlane? {
        let rowsTag = overlayTag(group: group, element: 0x0010)
        let columnsTag = overlayTag(group: group, element: 0x0011)
        let framesTag = overlayTag(group: group, element: 0x0015)
        let typeTag = overlayTag(group: group, element: 0x0040)
        let originTag = overlayTag(group: group, element: 0x0050)
        let imageFrameOriginTag = overlayTag(group: group, element: 0x0051)
        let bitsAllocatedTag = overlayTag(group: group, element: 0x0100)
        let bitPositionTag = overlayTag(group: group, element: 0x0102)
        let dataTag = overlayTag(group: group, element: 0x3000)

        guard let rows = dataSet.int(for: rowsTag), rows > 0,
              let columns = dataSet.int(for: columnsTag), columns > 0,
              let bitsAllocated = dataSet.int(for: bitsAllocatedTag), bitsAllocated > 0,
              let bitPosition = dataSet.int(for: bitPositionTag), bitPosition >= 0 else {
            return nil
        }
        let origin = dataSet.ints(for: originTag)
        guard origin.count >= 2 else { return nil }
        let kind = overlayKind(dataSet.string(for: typeTag))
        let numberOfFrames = dataSet.int(for: framesTag)
        let imageFrameOrigin = dataSet.int(for: imageFrameOriginTag)

        if let element = dataSet.element(for: dataTag),
           let bytes = element.bytesValue {
            guard bitsAllocated == 1, bitPosition == 0,
                  let mask = standaloneMask(
                      bytes: bytes,
                      vr: element.vr,
                      rows: rows,
                      columns: columns,
                      frameIndex: frameIndex,
                      numberOfFrames: numberOfFrames,
                      imageFrameOrigin: imageFrameOrigin,
                      littleEndian: littleEndian
                  ) else {
                return nil
            }
            return DicomOverlayPlane(
                group: group,
                rows: rows,
                columns: columns,
                originRow: origin[0] - 1,
                originColumn: origin[1] - 1,
                kind: kind,
                source: .overlayData,
                mask: mask
            )
        }

        guard overlayFrameIndex(
            frameIndex: frameIndex,
            numberOfFrames: numberOfFrames,
            imageFrameOrigin: imageFrameOrigin
        ) != nil,
              let embeddedFrame,
              embeddedFrame.descriptor.samplesPerPixel == 1,
              bitsAllocated == embeddedFrame.descriptor.bitsAllocated,
              bitPosition < bitsAllocated,
              let mask = embeddedMask(
                  frame: embeddedFrame,
                  rows: rows,
                  columns: columns,
                  originRow: origin[0] - 1,
                  originColumn: origin[1] - 1,
                  bitPosition: bitPosition,
                  littleEndian: littleEndian
              ) else {
            return nil
        }
        return DicomOverlayPlane(
            group: group,
            rows: rows,
            columns: columns,
            originRow: origin[0] - 1,
            originColumn: origin[1] - 1,
            kind: kind,
            source: .embeddedPixelData(bitPosition: bitPosition),
            mask: mask
        )
    }

    static func standaloneMask(
        bytes: Data,
        vr: DicomVR,
        rows: Int,
        columns: Int,
        frameIndex: Int,
        numberOfFrames: Int?,
        imageFrameOrigin: Int?,
        littleEndian: Bool
    ) -> Data? {
        let pixelsPerFrameResult = rows.multipliedReportingOverflow(by: columns)
        guard !pixelsPerFrameResult.overflow else { return nil }
        let pixelsPerFrame = pixelsPerFrameResult.partialValue

        guard let overlayFrameIndex = overlayFrameIndex(
            frameIndex: frameIndex,
            numberOfFrames: numberOfFrames,
            imageFrameOrigin: imageFrameOrigin
        ) else { return nil }

        let startBitResult = pixelsPerFrame.multipliedReportingOverflow(by: overlayFrameIndex)
        guard !startBitResult.overflow else { return nil }
        let startBit = startBitResult.partialValue
        let endBitResult = startBit.addingReportingOverflow(pixelsPerFrame)
        guard !endBitResult.overflow, endBitResult.partialValue <= bytes.count * 8 else { return nil }

        var mask = Data(count: pixelsPerFrame)
        mask.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<pixelsPerFrame {
                let bitIndex = startBit + index
                let logicalByteIndex = bitIndex / 8
                let byteIndex: Int
                if vr == .OW, !littleEndian {
                    let swapped = logicalByteIndex.isMultiple(of: 2)
                        ? logicalByteIndex + 1
                        : logicalByteIndex - 1
                    byteIndex = swapped < bytes.count ? swapped : logicalByteIndex
                } else {
                    byteIndex = logicalByteIndex
                }
                destinationBase[index] = (bytes[byteIndex] >> UInt8(bitIndex % 8)) & 1
            }
        }
        return mask
    }

    static func overlayFrameIndex(
        frameIndex: Int,
        numberOfFrames: Int?,
        imageFrameOrigin: Int?
    ) -> Int? {
        guard let numberOfFrames else {
            // A single-frame overlay without the Multi-frame Overlay attributes
            // applies to every frame in the image.
            return 0
        }
        guard numberOfFrames > 0 else { return nil }
        let overlayFrameIndex = frameIndex - ((imageFrameOrigin ?? 1) - 1)
        guard overlayFrameIndex >= 0, overlayFrameIndex < numberOfFrames else { return nil }
        return overlayFrameIndex
    }

    static func embeddedMask(
        frame: DicomPixelFrame,
        rows: Int,
        columns: Int,
        originRow: Int,
        originColumn: Int,
        bitPosition: Int,
        littleEndian: Bool
    ) -> Data? {
        let descriptor = frame.descriptor
        guard [1, 2, 4].contains(descriptor.bytesPerSample) else { return nil }
        let pixelCountResult = rows.multipliedReportingOverflow(by: columns)
        guard !pixelCountResult.overflow else { return nil }

        var mask = Data(count: pixelCountResult.partialValue)
        frame.data.withUnsafeBytes { source in
            mask.withUnsafeMutableBytes { destination in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress,
                      let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return }
                for overlayRow in 0..<rows {
                    let imageRow = originRow + overlayRow
                    guard imageRow >= 0, imageRow < descriptor.rows else { continue }
                    for overlayColumn in 0..<columns {
                        let imageColumn = originColumn + overlayColumn
                        guard imageColumn >= 0, imageColumn < descriptor.columns else { continue }
                        let pixelIndex = imageRow * descriptor.columns + imageColumn
                        let byteOffset = pixelIndex * descriptor.bytesPerSample
                        var sample: UInt32 = 0
                        for byteIndex in 0..<descriptor.bytesPerSample {
                            let shift = littleEndian
                                ? byteIndex * 8
                                : (descriptor.bytesPerSample - byteIndex - 1) * 8
                            sample |= UInt32(sourceBase[byteOffset + byteIndex]) << UInt32(shift)
                        }
                        let destinationIndex = overlayRow * columns + overlayColumn
                        destinationBase[destinationIndex] = UInt8((sample >> UInt32(bitPosition)) & 1)
                    }
                }
            }
        }
        return mask
    }

    static func overlayTag(group: Int, element: Int) -> Int {
        (group << 16) | element
    }

    static func overlayKind(_ value: String?) -> DicomOverlayPlane.Kind {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "G":
            return .graphics
        case "R":
            return .regionOfInterest
        case let value?:
            return .other(value)
        case nil:
            return .other("")
        }
    }
}
