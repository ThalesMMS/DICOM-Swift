import Foundation

/// Incremental JPEG/JPEG-LS framing, not an entropy decoder. Length-delimited
/// APP/COM/table payloads are skipped; EOI is recognized only in marker context.
struct DicomJPEGFrameBoundaryScanner {
    private enum Phase {
        case startPrefix, startCode, markerPrefix, markerCode
        case lengthHigh, lengthLow(Int), segment(Int)
        case entropy, entropyPrefix, finished
    }

    private var phase: Phase = .startPrefix
    private let expectedSOF: UInt8
    private let isJPEGLS: Bool
    private var marker: UInt8 = 0
    private var resumeEntropy = false
    private var sawSOF = false
    private var sawScan = false
    private var padding = 0

    private var finished: Bool { if case .finished = phase { true } else { false } }

    private init(syntax: DicomTransferSyntax) throws {
        switch syntax {
        case .jpegBaseline: expectedSOF = 0xC0
        case .jpegExtended: expectedSOF = 0xC1
        case .jpegLossless, .jpegLosslessFirstOrder: expectedSOF = 0xC3
        case .jpegLSLossless, .jpegLSNearLossless: expectedSOF = 0xF7
        default: throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries
        }
        isJPEGLS = expectedSOF == 0xF7
    }

    static func map(source: DicomByteSource, fragments: [DicomEncapsulatedPixelDataFragment],
                    numberOfFrames: Int, syntax: DicomTransferSyntax,
                    maximumScanBytes: Int) async throws -> [[Int]] {
        var scanner = try Self(syntax: syntax)
        var budget = max(0, maximumScanBytes)
        var frames: [[Int]] = []
        var firstFragment = 0
        let chunkSize = min(65536, source.limits.maximumReadBytes)
        guard chunkSize > 0 else { throw DicomByteSource.Failure.readLimit }
        for fragment in fragments {
            guard fragment.length <= budget else { throw DicomSourceFrameIndex.Failure.boundaryScanLimit }
            budget -= fragment.length
            var offset = fragment.valueRange.lowerBound
            while offset < fragment.valueRange.upperBound {
                try Task.checkCancellation()
                let end = offset + min(chunkSize, fragment.valueRange.upperBound - offset)
                let lease = try await source.read(offset..<end)
                try lease.withUnsafeBytes { bytes in
                    for byte in bytes { try scanner.consume(byte) }
                }
                offset = end
            }
            if scanner.finished {
                guard frames.count < numberOfFrames else { throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries }
                frames.append(Array(firstFragment...fragment.index))
                firstFragment = fragment.index + 1
                scanner = try Self(syntax: syntax)
            }
        }
        guard frames.count == numberOfFrames, firstFragment == fragments.count else {
            throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries
        }
        return frames
    }

    private mutating func consume(_ byte: UInt8) throws {
        switch phase {
        case .startPrefix:
            guard byte == 0xFF else { throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries }
            phase = .startCode
        case .startCode:
            guard byte == 0xD8 else { throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries }
            phase = .markerPrefix
        case .markerPrefix:
            guard byte == 0xFF else { throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries }
            phase = .markerCode
        case .markerCode:
            if byte != 0xFF { try startMarker(byte, fromEntropy: false) }
        case .lengthHigh:
            phase = .lengthLow(Int(byte) << 8)
        case .lengthLow(let high):
            let length = high | Int(byte)
            guard length >= 2, (marker != expectedSOF || length >= 8),
                  (marker != 0xDA || length >= 6) else { throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries }
            phase = length == 2 ? (resumeEntropy ? .entropy : .markerPrefix) : .segment(length - 2)
        case .segment(let remaining):
            phase = remaining == 1 ? (resumeEntropy ? .entropy : .markerPrefix) : .segment(remaining - 1)
        case .entropy:
            if byte == 0xFF { phase = .entropyPrefix }
        case .entropyPrefix:
            if byte == 0xFF { return }
            if byte == 0 || (isJPEGLS && byte < 0x80) || (0xD0...0xD7).contains(byte) {
                phase = .entropy
            } else { try startMarker(byte, fromEntropy: true) }
        case .finished:
            guard byte == 0, padding == 0 else { throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries }
            padding += 1
        }
    }

    private mutating func startMarker(_ byte: UInt8, fromEntropy: Bool) throws {
        if byte == 0xD9 {
            guard sawSOF, sawScan else { throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries }
            phase = .finished
            return
        }
        guard byte >= 0xC0, byte != 0xD8, !(0xD0...0xD7).contains(byte) else {
            throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries
        }
        if ((0xC0...0xCF).contains(byte) && ![0xC4, 0xC8, 0xCC].contains(byte)) || byte == 0xF7 {
            guard byte == expectedSOF, !sawSOF else { throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries }
            sawSOF = true
        }
        if byte == 0xDA {
            guard sawSOF else { throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries }
            sawScan = true
        }
        marker = byte
        resumeEntropy = byte == 0xDA || (byte == 0xDC && fromEntropy)
        phase = .lengthHigh
    }
}
