// Modified for Isis from JLSwift 299b9a2 (Apache-2.0); the modifications are recorded in Git.

/// Comprehensive error types for JPEG-LS encoding and decoding operations
///
/// These errors cover all failure modes defined in ISO/IEC 14495-1:1999 / ITU-T.87
/// as well as implementation-specific error conditions.

import Foundation

/// JPEG-LS error type
public enum JPEGLSError: Error, Sendable {
    // MARK: - Invalid Input Errors

    /// Invalid image dimensions (width or height is zero or exceeds maximum)
    case invalidDimensions(width: Int, height: Int)

    /// Invalid number of components (must be 1-4 for baseline JPEG-LS)
    case invalidComponentCount(count: Int)

    /// Invalid bits per sample (must be 2-16 for JPEG-LS)
    case invalidBitsPerSample(bits: Int)

    /// Invalid interleave mode
    case invalidInterleaveMode(mode: Int)

    /// Invalid NEAR parameter (must be 0-255)
    case invalidNearParameter(near: Int)

    /// Invalid preset parameter values
    case invalidPresetParameters(reason: String)

    // MARK: - Bitstream Errors

    /// Expected marker not found at expected position
    case markerNotFound(expected: JPEGLSMarker)

    /// Invalid marker encountered
    case invalidMarker(byte1: UInt8, byte2: UInt8)

    /// Premature end of bitstream
    case prematureEndOfStream

    /// Invalid segment length
    case invalidSegmentLength(marker: JPEGLSMarker, length: Int)

    /// Corrupted bitstream data
    case corruptedData(reason: String)

    /// Invalid bitstream structure
    case invalidBitstreamStructure(reason: String)

    // MARK: - Frame and Scan Header Errors

    /// Invalid frame header
    case invalidFrameHeader(reason: String)

    /// Invalid scan header
    case invalidScanHeader(reason: String)

    /// Mismatched frame and scan parameters
    case parameterMismatch(reason: String)

    /// Missing required header
    case missingHeader(type: String)

    // MARK: - Encoding Errors

    /// Encoding failed
    case encodingFailed(reason: String)

    /// Buffer overflow during encoding
    case encodingBufferOverflow

    /// Unsupported encoding feature
    case unsupportedEncodingFeature(feature: String)

    // MARK: - Decoding Errors

    /// Decoding failed
    case decodingFailed(reason: String)

    /// Invalid prediction error
    case invalidPredictionError

    /// Context state corruption
    case contextStateCorruption

    /// Unsupported decoding feature
    case unsupportedDecodingFeature(feature: String)

    // MARK: - I/O Errors

    /// File not found
    case fileNotFound(path: String)

    /// Cannot read file
    case cannotReadFile(path: String, underlying: Error?)

    /// Cannot write file
    case cannotWriteFile(path: String, underlying: Error?)

    /// Insufficient buffer size
    case insufficientBuffer(required: Int, available: Int)

    // MARK: - Validation Errors

    /// Round-trip validation failed
    case validationFailed(reason: String)

    /// Checksum mismatch
    case checksumMismatch

    // MARK: - Internal Errors

    /// Internal implementation error (should never happen)
    case internalError(reason: String)
}

extension JPEGLSError: CustomStringConvertible {
    /// Human-readable description of the error
    public var description: String {
        switch self {
        case .invalidDimensions(let width, let height):
            return "Invalid image dimensions: \(width)×\(height)"
        case .invalidComponentCount(let count):
            return "Invalid component count: \(count) (must be 1-4)"
        case .invalidBitsPerSample(let bits):
            return "Invalid bits per sample: \(bits) (must be 2-16)"
        case .invalidInterleaveMode(let mode):
            return "Invalid interleave mode: \(mode)"
        case .invalidNearParameter(let near):
            return "Invalid NEAR parameter: \(near) (must be 0-255)"
        case .invalidPresetParameters(let reason):
            return "Invalid preset parameters: \(reason)"
        case .markerNotFound(let expected):
            return "Expected marker not found: 0xFF\(String(format: "%02X", expected.rawValue))"
        case .invalidMarker(let byte1, let byte2):
            return "Invalid marker: 0x\(String(format: "%02X", byte1))\(String(format: "%02X", byte2))"
        case .prematureEndOfStream:
            return "Premature end of bitstream"
        case .invalidSegmentLength(let marker, let length):
            return "Invalid segment length for marker 0xFF\(String(format: "%02X", marker.rawValue)): \(length)"
        case .corruptedData(let reason):
            return "Corrupted bitstream data: \(reason)"
        case .invalidBitstreamStructure(let reason):
            return "Invalid bitstream structure: \(reason)"
        case .invalidFrameHeader(let reason):
            return "Invalid frame header: \(reason)"
        case .invalidScanHeader(let reason):
            return "Invalid scan header: \(reason)"
        case .parameterMismatch(let reason):
            return "Parameter mismatch: \(reason)"
        case .missingHeader(let type):
            return "Missing required header: \(type)"
        case .encodingFailed(let reason):
            return "Encoding failed: \(reason)"
        case .encodingBufferOverflow:
            return "Encoding buffer overflow"
        case .unsupportedEncodingFeature(let feature):
            return "Unsupported encoding feature: \(feature)"
        case .decodingFailed(let reason):
            return "Decoding failed: \(reason)"
        case .invalidPredictionError:
            return "Invalid prediction error encountered"
        case .contextStateCorruption:
            return "Context state corruption detected"
        case .unsupportedDecodingFeature(let feature):
            return "Unsupported decoding feature: \(feature)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .cannotReadFile(let path, let underlying):
            if let error = underlying {
                return "Cannot read file '\(path)': \(error.localizedDescription)"
            }
            return "Cannot read file: \(path)"
        case .cannotWriteFile(let path, let underlying):
            if let error = underlying {
                return "Cannot write file '\(path)': \(error.localizedDescription)"
            }
            return "Cannot write file: \(path)"
        case .insufficientBuffer(let required, let available):
            return "Insufficient buffer size: required \(required) bytes, available \(available) bytes"
        case .validationFailed(let reason):
            return "Validation failed: \(reason)"
        case .checksumMismatch:
            return "Checksum mismatch"
        case .internalError(let reason):
            return "Internal error: \(reason)"
        }
    }
}
