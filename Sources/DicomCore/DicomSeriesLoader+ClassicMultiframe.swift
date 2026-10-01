//
//  DicomSeriesLoader+ClassicMultiframe.swift
//  DicomCore
//
//  One classic multi-frame NM or Ultrasound object as a volume (issue #2813):
//  frames in stored order, geometry from `DicomSOPClassGeometry`.
//

import Foundation
import simd

extension DicomSeriesLoader {
    /// Assembles a classic multi-frame object of a SOP Class that `DicomSOPClassGeometry` covers into a volume. The
    /// frames stay in stored order, one frame step apart along the normal of the object's orientation (the identity
    /// when it has none); every frame takes the top-level rescale. Grayscale 8/16-bit frames only.
    public func loadClassicMultiframeVolume(at url: URL) throws -> DicomSeriesVolume {
        let anyDecoder = try decoderFactory(url.path)
        let format = enhancedPixelFormat(from: anyDecoder)
        guard let decoder = anyDecoder as? DCMDecoder, format.numberOfFrames > 1,
              format.samplesPerPixel == 1,
              format.photometricInterpretation == "MONOCHROME1" || format.photometricInterpretation == "MONOCHROME2",
              format.bitsAllocated == 8 || format.bitsAllocated == 16,
              let geometry = DicomSOPClassGeometry(dataSet: decoder.dataSet,
                                                   sopClassUID: decoder.info(for: .sopClassUID)) else {
            throw DicomSeriesLoaderError.unsupportedMultiframe(format)
        }
        let width = decoder.width
        let height = decoder.height
        let frameCount = format.numberOfFrames
        let (pixelsPerFrame, frameOverflow) = width.multipliedReportingOverflow(by: height)
        let (voxelCount, volumeOverflow) = pixelsPerFrame.multipliedReportingOverflow(by: frameCount)
        let (byteCount, byteOverflow) = voxelCount.multipliedReportingOverflow(by: MemoryLayout<Int16>.size)
        guard width > 0, height > 0, !frameOverflow, !volumeOverflow, !byteOverflow else {
            throw DicomSeriesLoaderError.unsupportedMultiframe(format)
        }
        if decoder.compressedImage {
            // Encoded bytes do not bound the expanded volume; retain the decoder's decoded-buffer ceiling.
            guard byteCount <= DCMDecoder.maxPixelBufferSize else {
                throw DicomSeriesLoaderError.unsupportedMultiframe(format)
            }
        } else {
            let (storedBytesPerFrame, storedOverflow) =
                pixelsPerFrame.multipliedReportingOverflow(by: format.bitsAllocated / 8)
            let availablePixelBytes = decoder.synchronized { () -> Int? in
                let offset = decoder.offset
                guard offset >= 4, offset <= decoder.dicomData.count,
                      !decoder.isExplicitVRTransferSyntax || decoder.pixelDataVR?.uses32BitLength == true else { return nil }
                let declared = decoder.dicomData.dicomInteger(at: offset - 4, as: UInt32.self,
                                                              littleEndian: decoder.currentLittleEndian())
                guard declared != UInt32.max else { return nil }
                // Bytes after the Pixel Data value do not belong to another frame.
                return min(Int(declared), decoder.dicomData.count - offset)
            }
            guard !storedOverflow, storedBytesPerFrame > 0, let availablePixelBytes,
                  frameCount <= availablePixelBytes / storedBytesPerFrame else {
                throw DicomSeriesLoaderError.failedToDecode(url)
            }
        }
        var voxels = try allocateVoxelData(byteCount)
        let reader = DicomDecodedFrameReader(decoder: decoder)
        try voxels.withUnsafeMutableBytes { rawBuffer in
            let destination = rawBuffer.bindMemory(to: Int16.self)
            for frame in 0..<frameCount {
                try Task.checkCancellation()
                let decoded: DicomDecodedFrame
                do {
                    decoded = try reader.frame(at: frame)
                } catch {
                    throw DicomSeriesLoaderError.failedToDecode(url)
                }
                guard try storeGrayFrame(decoded, format: format, count: pixelsPerFrame, into: destination,
                                         at: frame * pixelsPerFrame, url: url) else {
                    throw DicomSeriesLoaderError.unsupportedMultiframe(format)
                }
            }
        }

        let row = geometry.orientation?.row ?? SIMD3(1, 0, 0)
        let column = geometry.orientation?.column ?? SIMD3(0, 1, 0)
        let rescale = decoder.rescaleParametersV2
        let window = windowCenterWidth(from: decoder)
        func text(_ tag: DicomTag) -> String? {
            let value = decoder.info(for: tag).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return DicomSeriesVolume(
            voxels: voxels,
            width: width,
            height: height,
            depth: frameCount,
            spacing: geometry.spacing,
            orientation: simd_double3x3(columns: (row, column, simd_normalize(simd_cross(row, column)))),
            origin: geometry.origin ?? .zero,
            rescaleSlope: rescale.slope,
            rescaleIntercept: rescale.intercept,
            bitsAllocated: format.bitsAllocated,
            isSignedPixel: format.pixelRepresentation == 1,
            patientName: decoder.info(for: .patientName),
            seriesDescription: decoder.info(for: .seriesDescription),
            studyDescription: text(.studyDescription),
            modality: decoder.info(for: .modality),
            windowCenter: window?.center,
            windowWidth: window?.width,
            studyInstanceUID: text(.studyInstanceUID),
            seriesInstanceUID: text(.seriesInstanceUID),
            frameOfReferenceUID: text(.frameOfReferenceUID),
            sliceRescaleParameters: Array(repeating: .init(slope: rescale.slope, intercept: rescale.intercept),
                                          count: frameCount)
        )
    }
}
