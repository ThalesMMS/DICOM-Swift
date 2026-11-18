//
//  JXLDecoder+DICOMContract.swift
//  DicomJPEGXL
//
//  Checks JPEG XL codestream features against the supported DICOM frame contract.
//
//  Thales Matheus Mendonça Santos — November 2026
//

// JXLDecoder+DICOMContract: codestream features the DICOM frame contract cannot carry (issue #3245).
//
// The official libjxl conformance vectors showed that the decoder renders some valid codestreams differently from
// djxl instead of refusing them: an XYB image whose colour target is an embedded ICC profile (libjxl converts to
// that profile through a CMS; the decoder has none), an EXIF orientation other than identity (a DICOM frame has no
// orientation), and an image composed of several layers (the decoder returns the first). A DICOM decode refuses
// these with a typed reason instead of returning other pixels. A codestream that carries JPEG reconstruction data is
// reported so the caller can decode it through the reconstructed JPEG, as `.111` does.

import Foundation

extension JXLDecoder {
    /// A typed reason this codestream cannot be decoded within the DICOM frame contract, or nil.
    package func dicomFrameContractRefusal(_ data: Data) -> String? {
        guard let codestream = codestreamForContract(data) else { return nil }
        var reader = BitReader(codestream, startingAt: 16)
        guard let _ = try? SizeHeader.read(from: &reader),
              let metadata = try? ImageMetadata.read(from: &reader) else { return nil }
        if metadata.orientation != 1 {
            return "the codestream declares EXIF orientation \(metadata.orientation); DICOM frames carry no orientation"
        }
        if metadata.xybEncoded, metadata.colorEncoding.useICC {
            return "an XYB image whose colour target is an embedded ICC profile needs colour management"
        }
        guard (try? CustomTransformData.read(from: &reader, xybEncoded: metadata.xybEncoded)) != nil else { return nil }
        if metadata.colorEncoding.useICC {
            guard (try? ICCStream.decode(from: &reader)) != nil else { return nil }
        }
        guard (try? reader.alignToByte()) != nil else { return nil }
        let context = FrameHeaderContext(
            xybEncoded: metadata.xybEncoded,
            numExtraChannels: metadata.extraChannels.count,
            haveAnimation: metadata.animation != nil,
            haveTimecodes: metadata.animation?.haveTimecodes ?? false)
        guard let frame = try? FrameHeader.read(from: &reader, context: context) else { return nil }
        if metadata.animation == nil, frame.frameType == .regular, !frame.isLast {
            return "the image is composed of several layers; a DICOM frame is one image"
        }
        return nil
    }

    /// Whether a container carries JPEG bitstream reconstruction data (a `jbrd` box).
    package func carriesJPEGReconstruction(_ data: Data) -> Bool {
        guard case .iso(let boxes)? = try? parseJXLContainer(data) else { return false }
        return boxes.contains { $0.type == "jbrd" }
    }

    /// The bare codestream of a naked or ISO-boxed JPEG XL input, or nil when the container cannot be parsed.
    private func codestreamForContract(_ data: Data) -> Data? {
        guard let form = try? parseJXLContainer(data) else { return nil }
        switch form {
        case .naked:
            return data
        case .iso(let boxes):
            return try? extractCodestream(from: boxes, in: data)
        }
    }
}
