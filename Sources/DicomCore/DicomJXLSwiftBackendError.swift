//
//  DicomJXLSwiftBackendError.swift
//  DicomCore
//

import Foundation

enum DicomJXLSwiftBackendError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedShape(transferSyntaxUID: String, reason: String)
    case metadataMismatch(transferSyntaxUID: String, reason: String)
    case invalidEncodingIntent(transferSyntaxUID: String, reason: String)
    case jpegRecompressionFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedShape(let uid, let reason):
            return "JXLSwift does not support JPEG XL transfer syntax \(uid): \(reason)"
        case .metadataMismatch(let uid, let reason):
            return "JXLSwift output does not match DICOM metadata for transfer syntax \(uid): \(reason)"
        case .invalidEncodingIntent(let uid, let reason):
            return "Invalid JPEG XL encoding intent for transfer syntax \(uid): \(reason)"
        case .jpegRecompressionFailed(let reason):
            return "JPEG XL reversible JPEG transcoding failed: \(reason)"
        }
    }
}
