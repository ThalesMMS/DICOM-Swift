//
//  DicomEncapsulatedPixelFrameReader.swift
//  DicomCore
//
//  Codec-agnostic encapsulated-frame primitive (issue #1226): returns single compressed frame
//  payloads by index — Basic/Extended Offset Table mapping, empty-BOT fallback, and per-frame
//  fragment assembly come from `DicomEncapsulatedPixelDataParser` — without ever decoding the
//  JPEG/JPEG-LS/JPEG 2000/RLE payload bytes.
//
//  How this layer is consumed: - The codec resolver (decoded frame reader work, #1227+) asks this
//  reader for `frameData(at:)` and hands the bytes to the codec selected by the transfer-syntax
//  support matrix. - `DicomSeriesLoader`'s compressed path (#1233) iterates `frames()` to feed
//  per-slice decoders without materializing the whole Pixel Data.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

public struct DicomEncapsulatedPixelFrameReader: Sendable {
    public enum ReaderError: Error, Equatable, LocalizedError, Sendable {
        /// The dataset has no usable encapsulated Pixel Data element.
        case notEncapsulated
        /// Fragments exist but no safe frame mapping could be derived; the
        /// parser diagnostics carry the deterministic reason.
        case unusableFrameMap([DicomEncapsulatedPixelDataDiagnostic])
        /// The requested frame index is outside the mapped frame range.
        case frameIndexOutOfRange(index: Int, frameCount: Int)
        /// The declared NumberOfFrames disagrees with the mapped frames.
        case declaredFrameCountMismatch(declared: Int, mapped: Int)

        public var errorDescription: String? {
            switch self {
            case .notEncapsulated:
                return "The dataset does not carry encapsulated Pixel Data."
            case .unusableFrameMap(let diagnostics):
                let reasons = diagnostics
                    .filter { $0.severity == .error }
                    .map(\.message)
                    .joined(separator: " ")
                return "Encapsulated Pixel Data has no usable frame mapping: \(reasons)"
            case .frameIndexOutOfRange(let index, let frameCount):
                return "Frame index \(index) is outside the mapped range of \(frameCount) frame(s)."
            case .declaredFrameCountMismatch(let declared, let mapped):
                return "NumberOfFrames declares \(declared) frame(s) but \(mapped) were mapped."
            }
        }
    }

    public let descriptor: DicomEncapsulatedPixelDataDescriptor
    private let fileData: Data

    /// Number of frames actually mapped from the offset tables/fragments.
    public var frameCount: Int {
        descriptor.frameFragmentIndexes.count
    }

    /// The frame count declared by NumberOfFrames (defaulted to 1 when the
    /// tag is absent). Compare with `frameCount` or call
    /// `validateDeclaredFrameCount()` to detect inconsistent declarations.
    public var declaredNumberOfFrames: Int {
        descriptor.numberOfFrames
    }

    /// Non-fatal and fatal parser findings (offset-table fallbacks, length
    /// mismatches, malformed item sequences).
    public var diagnostics: [DicomEncapsulatedPixelDataDiagnostic] {
        descriptor.diagnostics
    }

    /// Creates a reader over a parsed descriptor and the file bytes the
    /// descriptor's ranges refer to.
    /// - Throws: `ReaderError.unusableFrameMap` when fragments exist but no
    ///   safe frame mapping could be derived.
    public init(descriptor: DicomEncapsulatedPixelDataDescriptor, fileData: Data) throws {
        guard !descriptor.frameFragmentIndexes.isEmpty else {
            throw ReaderError.unusableFrameMap(descriptor.diagnostics)
        }
        self.descriptor = descriptor
        self.fileData = fileData
    }

    /// Returns the compressed frame (fragment metadata plus assembled
    /// payload) for a zero-based frame index.
    public func frame(at index: Int) throws -> DicomEncapsulatedPixelFrame {
        guard index >= 0, index < frameCount else {
            throw ReaderError.frameIndexOutOfRange(index: index, frameCount: frameCount)
        }
        guard let frame = descriptor.frame(index, in: fileData) else {
            throw ReaderError.unusableFrameMap(descriptor.diagnostics)
        }
        return frame
    }

    /// Returns the assembled compressed payload for a zero-based frame
    /// index without decoding it.
    public func frameData(at index: Int) throws -> Data {
        try frame(at: index).data
    }

    /// Returns every mapped frame in order.
    public func frames() throws -> [DicomEncapsulatedPixelFrame] {
        try (0..<frameCount).map { try frame(at: $0) }
    }

    /// Throws when the declared NumberOfFrames disagrees with the mapped
    /// frame count (absent declarations default to 1 and are validated the
    /// same way).
    public func validateDeclaredFrameCount() throws {
        guard declaredNumberOfFrames == frameCount else {
            throw ReaderError.declaredFrameCountMismatch(
                declared: declaredNumberOfFrames,
                mapped: frameCount
            )
        }
    }
}
