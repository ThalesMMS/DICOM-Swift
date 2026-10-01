import Foundation

extension DicomWebMediaTypeNegotiator {
    struct Selection: Equatable, Sendable {
        let mediaType: String
        let transferSyntaxUID: String?
        let isMultipart: Bool
    }

    static func rawFrameSelection(
        accept: String?,
        transferSyntax: DicomTransferSyntax,
        isCompressed: Bool
    ) throws -> Selection {
        guard let accept, !accept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DicomWebFrameRouteError.mediaTypeNotAcceptable
        }
        guard DicomCodecCapabilities.preservationDecision(for: transferSyntax.rawValue).canExecute else {
            throw DicomWebFrameRouteError.mediaTypeNotAcceptable
        }
        let sourceMediaType = isCompressed ? compressedMediaType(for: transferSyntax) : "application/octet-stream"
        guard let sourceMediaType else { throw DicomWebFrameRouteError.mediaTypeNotAcceptable }
        if !isCompressed,
           transferSyntax == .explicitVRBigEndian {
            throw DicomWebFrameRouteError.mediaTypeNotAcceptable
        }
        let responseTransferSyntax = isCompressed
            ? transferSyntax.rawValue
            : DicomTransferSyntax.explicitVRLittleEndian.rawValue

        guard let preference = effectivePreference(
            for: sourceMediaType,
            transferSyntaxUID: responseTransferSyntax,
            isMultipart: true,
            ranges: ranges(from: accept)
        ), preference.quality > 0 else {
            throw DicomWebFrameRouteError.mediaTypeNotAcceptable
        }
        return Selection(
            mediaType: sourceMediaType,
            transferSyntaxUID: responseTransferSyntax,
            isMultipart: true
        )
    }

    static func renderedSelection(accept: String?, representationCount: Int) throws -> Selection {
        guard let accept, !accept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DicomWebFrameRouteError.mediaTypeNotAcceptable
        }
        let isMultipart = representationCount > 1
        let ranges = ranges(from: accept)
        let candidates = ["image/jpeg", "image/png", "image/gif"].enumerated().compactMap { offset, mediaType in
            effectivePreference(
                for: mediaType,
                transferSyntaxUID: nil,
                isMultipart: isMultipart,
                ranges: ranges
            ).map { (mediaType: mediaType, preference: $0, offset: offset) }
        }
        guard let selected = candidates
            .filter({ $0.preference.quality > 0 })
            .sorted(by: {
                if $0.preference.quality != $1.preference.quality {
                    return $0.preference.quality > $1.preference.quality
                }
                if $0.preference.specificity != $1.preference.specificity {
                    return $0.preference.specificity > $1.preference.specificity
                }
                if $0.preference.order != $1.preference.order {
                    return $0.preference.order < $1.preference.order
                }
                return $0.offset < $1.offset
            })
            .first else {
            throw DicomWebFrameRouteError.mediaTypeNotAcceptable
        }
        return Selection(mediaType: selected.mediaType, transferSyntaxUID: nil, isMultipart: isMultipart)
    }

    private static func compressedMediaType(for syntax: DicomTransferSyntax) -> String? {
        switch syntax {
        case .jpegBaseline, .jpegExtended, .jpegLossless, .jpegLosslessFirstOrder:
            return "image/jpeg"
        case .jpegLSLossless, .jpegLSNearLossless:
            return "image/jls"
        case .jpeg2000Lossless, .jpeg2000, .jpeg2000Part2MulticomponentLossless,
             .jpeg2000Part2Multicomponent:
            return "image/jp2"
        case .htj2kLossless, .htj2kLosslessRPCL, .htj2k:
            return "image/jphc"
        case .rleLossless:
            return "image/dicom-rle"
        case .deflatedImageFrameCompression:
            // PS3.18 Table 8.7.3-5 (2026c) lists application/x-deflate for 1.2.840.10008.1.2.8.1.
            return "application/x-deflate"
        case .jpegXLLossless, .jpegXLJPEGRecompression, .jpegXL:
            return "image/jxl"
        default:
            return nil
        }
    }

    private static func ranges(from header: String) -> [MediaRange] {
        splitHeader(header).compactMap(MediaRange.init)
    }

    private static func effectivePreference(
        for mediaType: String,
        transferSyntaxUID: String?,
        isMultipart: Bool,
        ranges: [MediaRange]
    ) -> (quality: Double, specificity: Int, order: Int)? {
        ranges.enumerated().compactMap { order, range -> (Double, Int, Int)? in
            guard let specificity = range.specificity(
                for: mediaType,
                transferSyntaxUID: transferSyntaxUID,
                isMultipart: isMultipart
            ) else {
                return nil
            }
            return (range.quality, order, specificity)
        }
        .sorted { lhs, rhs in
            lhs.2 == rhs.2 ? lhs.1 < rhs.1 : lhs.2 > rhs.2
        }
        .first
        .map { (quality: $0.0, specificity: $0.2, order: $0.1) }
    }

    private static func splitHeader(_ header: String) -> [String] {
        DicomWebMediaType.split(header, separator: ",")
    }

    private struct MediaRange {
        let type: String
        let parameters: [String: String]
        let quality: Double

        init?(_ rawValue: String) {
            guard let media = try? DicomWebMediaType(rawValue) else { return nil }
            let quality = media.parameters["q"].flatMap(Double.init) ?? (media.parameters["q"] == nil ? 1 : -1)
            guard quality >= 0, quality <= 1 else { return nil }
            self.type = media.type
            self.parameters = media.parameters
            self.quality = quality
        }

        func specificity(
            for mediaType: String,
            transferSyntaxUID: String?,
            isMultipart: Bool
        ) -> Int? {
            guard parameters["transfer-syntax"] == nil
                || parameters["transfer-syntax"] == "*"
                || parameters["transfer-syntax"] == transferSyntaxUID else {
                return nil
            }
            if isMultipart {
                if type == "*/*" { return 0 }
                if type == "multipart/*" { return 1 }
                guard type == "multipart/related" else { return nil }
                guard let requestedType = parameters["type"]?.lowercased() else { return 2 }
                if requestedType == "*/*" { return 2 }
                return requestedType == mediaType ? 3 : nil
            }
            guard parameters["transfer-syntax"] == nil else { return nil }
            if type == "*/*" { return 0 }
            let components = mediaType.split(separator: "/", maxSplits: 1)
            if components.count == 2, type == "\(components[0])/*" { return 1 }
            return type == mediaType ? 2 : nil
        }
    }
}

