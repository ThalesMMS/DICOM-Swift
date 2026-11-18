//
//  DCMDecoder+EncapsulatedPixelData.swift
//  DicomCore
//
//  Adds encapsulated pixel data support to DCMDecoder.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

extension DCMDecoder {
    public var encapsulatedPixelDataDescriptor: DicomEncapsulatedPixelDataDescriptor? {
        synchronized {
            makeEncapsulatedPixelDataDescriptorUnsafe()
        }
    }

    /// Codec-agnostic frame reader over this file's encapsulated Pixel Data
    /// (issue #1226). Throws `DicomEncapsulatedPixelFrameReader.ReaderError`
    /// with deterministic diagnostics instead of returning nil.
    public func makeEncapsulatedPixelFrameReader() throws -> DicomEncapsulatedPixelFrameReader {
        try synchronized {
            guard let descriptor = makeEncapsulatedPixelDataDescriptorUnsafe() else {
                throw DicomEncapsulatedPixelFrameReader.ReaderError.notEncapsulated
            }
            return try DicomEncapsulatedPixelFrameReader(descriptor: descriptor, fileData: dicomData)
        }
    }

    public func getEncapsulatedFrame(_ index: Int) -> DicomEncapsulatedPixelFrame? {
        synchronized {
            guard let descriptor = makeEncapsulatedPixelDataDescriptorUnsafe() else {
                return nil
            }
            return descriptor.frame(index, in: dicomData)
        }
    }

    func makeEncapsulatedPixelDataDescriptorUnsafe() -> DicomEncapsulatedPixelDataDescriptor? {
        guard dicomFound,
              compressedImage,
              offset >= 0,
              looksLikeEncapsulatedPixelDataUnsafe(at: offset) else {
            return nil
        }

        do {
            return try DicomEncapsulatedPixelDataParser().parse(
                data: dicomData,
                pixelDataOffset: offset,
                numberOfFrames: max(1, nImages),
                extendedOffsetTableData: rawElementDataUnsafe(for: .extendedOffsetTable),
                extendedOffsetTableLengthsData: rawElementDataUnsafe(for: .extendedOffsetTableLengths)
            )
        } catch {
            logger.warning("Encapsulated Pixel Data parsing failed: \(error)")
            return nil
        }
    }

    private func looksLikeEncapsulatedPixelDataUnsafe(at offset: Int) -> Bool {
        guard offset + 4 <= dicomData.count else { return false }
        return dicomData[offset] == 0xFE
            && dicomData[offset + 1] == 0xFF
            && dicomData[offset + 2] == 0x00
            && dicomData[offset + 3] == 0xE0
    }

    private func rawElementDataUnsafe(for tag: DicomTag) -> Data? {
        guard let metadata = tagMetadataCache[tag.rawValue],
              metadata.elementLength > 0,
              metadata.offset >= 0 else {
            return nil
        }
        let end = metadata.offset + metadata.elementLength
        guard end <= dicomData.count else { return nil }
        return Data(dicomData[metadata.offset..<end])
    }
}
