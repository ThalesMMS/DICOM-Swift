import Foundation

extension DicomEncapsulatedPixelDataParser {
    /// Strict, bounded indexing over item headers. Existing buffer APIs retain their
    /// diagnostic compatibility fallbacks; this source API never falls back after a bad table.
    public func parse(source: DicomByteSource, pixelDataRange: Range<Int>, numberOfFrames: Int,
                      transferSyntax: DicomTransferSyntax, extendedOffsetTableData: Data? = nil,
                      extendedOffsetTableLengthsData: Data? = nil,
                      maximumIndexBytes: Int = 32 * 1024 * 1024,
                      maximumBoundaryScanBytes: Int = 64 * 1024 * 1024) async throws -> DicomEncapsulatedPixelDataDescriptor {
        typealias Failure = DicomSourceFrameIndex.Failure
        guard numberOfFrames > 0, maximumIndexBytes >= 128,
              pixelDataRange.lowerBound >= 0, pixelDataRange.upperBound <= source.count else {
            throw Failure.invalidLayout
        }
        let singleFragment: Bool
        switch transferSyntax {
        case .rleLossless, .htj2kLossless, .htj2kLosslessRPCL, .htj2k,
             .jpegXLLossless, .jpegXLJPEGRecompression, .jpegXL, .deflatedImageFrameCompression:
            singleFragment = true
        case .jpegBaseline, .jpegExtended, .jpegLossless, .jpegLosslessFirstOrder,
             .jpegLSLossless, .jpegLSNearLossless, .jpeg2000Lossless, .jpeg2000:
            singleFragment = false
        default: throw Failure.unsupportedLayout(transferSyntax.rawValue)
        }
        var cursor = pixelDataRange.lowerBound
        var indexBytes = 0
        func read(_ count: Int, at offset: Int) async throws -> Data {
            guard count >= 0, offset >= pixelDataRange.lowerBound, offset <= pixelDataRange.upperBound,
                  count <= pixelDataRange.upperBound - offset else { throw Failure.truncatedItems }
            return try await source.read(offset..<(offset + count)).retainedData()
        }
        func item(_ offset: Int) async throws -> (tag: Int, length: Int) {
            let bytes = try await read(8, at: offset)
            return (try Self.readTag(bytes, at: 0), Int(try Self.readUInt32(bytes, at: 4)))
        }
        let botHeader = try await item(cursor)
        guard botHeader.tag == Self.itemTag, botHeader.length % 4 == 0,
              botHeader.length <= maximumIndexBytes / 4 else { throw Failure.invalidOffsetTable }
        cursor += 8
        guard botHeader.length <= pixelDataRange.upperBound - cursor else { throw Failure.truncatedItems }
        let botRange = cursor..<(cursor + botHeader.length)
        var diagnostics: [DicomEncapsulatedPixelDataDiagnostic] = []
        let botBytes = try await read(botHeader.length, at: cursor)
        let bot = DicomBasicOffsetTable(offsets: Self.readUInt32Values(botBytes, diagnostics: &diagnostics), byteRange: botRange)
        cursor = botRange.upperBound
        indexBytes += botHeader.length * 4
        for bytes in [extendedOffsetTableData, extendedOffsetTableLengthsData].compactMap({ $0 }) {
            guard bytes.count <= (maximumIndexBytes - indexBytes) / 4 else { throw Failure.indexLimit }
            indexBytes += bytes.count * 4
        }
        let extended = Self.extendedOffsetTable(offsetsData: extendedOffsetTableData,
                                                lengthsData: extendedOffsetTableLengthsData, diagnostics: &diagnostics)
        guard !diagnostics.contains(where: { $0.severity == .error }) else { throw Failure.invalidOffsetTable }
        var fragments: [DicomEncapsulatedPixelDataFragment] = []
        let firstItem = cursor
        var foundDelimiter = false
        while cursor < pixelDataRange.upperBound {
            try Task.checkCancellation()
            let header = try await item(cursor)
            if header.tag == Self.sequenceDelimiterTag {
                guard header.length == 0, pixelDataRange.upperBound - cursor == 8 else { throw Failure.truncatedItems }
                foundDelimiter = true
                break
            }
            guard header.tag == Self.itemTag, header.length != Self.undefinedLength,
                  header.length > 0, header.length % 2 == 0 else { throw Failure.truncatedItems }
            let start = cursor + 8
            guard header.length <= pixelDataRange.upperBound - start else { throw Failure.truncatedItems }
            // Includes fragment storage, lookup dictionary and frame-map overhead.
            guard 256 <= maximumIndexBytes - indexBytes else { throw Failure.indexLimit }
            indexBytes += 256
            let end = start + header.length
            fragments.append(.init(index: fragments.count, itemRange: cursor..<end,
                                   valueRange: start..<end, relativeItemOffset: cursor - firstItem))
            cursor = end
        }
        guard foundDelimiter, !fragments.isEmpty else { throw Failure.truncatedItems }
        let byOffset = Dictionary(uniqueKeysWithValues: fragments.map { ($0.relativeItemOffset, $0.index) })
        let mapped: [[Int]]
        if let extended {
            guard bot.isEmpty, extended.offsets.count == numberOfFrames, numberOfFrames == fragments.count,
                  let frames = Self.mapUsingOffsets(extended.offsets, fragmentCount: fragments.count,
                                                     fragmentIndexByRelativeItemOffset: byOffset, diagnostics: &diagnostics),
                  frames.allSatisfy({ $0.count == 1 }) else { throw Failure.invalidOffsetTable }
            for (index, length) in extended.lengths.enumerated() {
                let stored = UInt64(fragments[index].length)
                guard length > 0, length <= stored, stored - length <= 1,
                      stored - length == 0 || length % 2 == 1 else { throw Failure.invalidOffsetTable }
            }
            mapped = frames
        } else if !bot.isEmpty {
            guard bot.offsets.count == numberOfFrames,
                  let frames = Self.mapUsingOffsets(bot.offsets.map(UInt64.init), fragmentCount: fragments.count,
                                                     fragmentIndexByRelativeItemOffset: byOffset, diagnostics: &diagnostics) else {
                throw Failure.invalidOffsetTable
            }
            mapped = frames
        } else if numberOfFrames == 1 {
            mapped = [Array(fragments.indices)]
        } else if fragments.count == numberOfFrames {
            mapped = fragments.map { [$0.index] }
        } else {
            guard !singleFragment else { throw Failure.invalidFragmentation(transferSyntax.rawValue) }
            mapped = try await DicomJPEGFrameBoundaryScanner.map(
                source: source, fragments: fragments, numberOfFrames: numberOfFrames,
                syntax: transferSyntax, maximumScanBytes: maximumBoundaryScanBytes
            )
        }
        guard !singleFragment || mapped.allSatisfy({ $0.count == 1 }) else {
            throw Failure.invalidFragmentation(transferSyntax.rawValue)
        }
        try await source.checkOpen()
        return .init(pixelDataOffset: pixelDataRange.lowerBound, numberOfFrames: numberOfFrames,
                     basicOffsetTable: bot, extendedOffsetTable: extended, fragments: fragments,
                     frameFragmentIndexes: mapped, diagnostics: diagnostics)
    }
}
