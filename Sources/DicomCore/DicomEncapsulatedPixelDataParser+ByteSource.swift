//
//  DicomEncapsulatedPixelDataParser+ByteSource.swift
//  DicomCore
//
//  Adds byte source support to DicomEncapsulatedPixelDataParser.
//
//  Thales Matheus Mendonça Santos — September 2026
//

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
             .jpegLSLossless, .jpegLSNearLossless, .jpeg2000Lossless, .jpeg2000,
             .jpeg2000Part2MulticomponentLossless, .jpeg2000Part2Multicomponent:
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
            // Issue #3053: an odd fragment length breaks PS3.5 A.4, but the item still bounds its bytes exactly;
            // GDCM, DCMTK and pydicom read it, so the fragment is kept as declared.
            guard header.tag == Self.itemTag, header.length != Self.undefinedLength,
                  header.length > 0 else { throw Failure.truncatedItems }
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
        if transferSyntax == .jpeg2000Part2MulticomponentLossless || transferSyntax == .jpeg2000Part2Multicomponent {
            // PS3.5 8.2.4: every fragment is one component collection whose reconstructed components are
            // consecutive frames (issue #3256). An Annex J main header's CBD marker gives that count (T.801 A.2:
            // Nmcbd may differ from the coded Csiz); otherwise the SIZ marker's Csiz (bytes 40–41) does. The
            // offset tables describe fragments, not frames, and are not used.
            /// What a walk of the main header within `prefix` found: CBD's Nmcbd, no CBD before the first tile-part (or
            /// an unwalkable header), or the end of `prefix` before either.
            enum HeaderWalk { case components(Int), absent, truncated }
            /// Walks the main header in memory; one bounded read of the fragment feeds it.
            func reconstructedComponents(in prefix: [UInt8], sizLength: Int, codedComponents: Int) -> HeaderWalk {
                var offset = 4 + sizLength
                for _ in 0..<4096 {
                    guard offset >= 0 else { return .absent }
                    guard prefix.count - offset >= 6 else { return .truncated }
                    let length = Int(prefix[offset + 2]) << 8 | Int(prefix[offset + 3])
                    guard prefix[offset] == 0xFF, ![0x90, 0x93, 0xD9].contains(prefix[offset + 1]), length >= 2 else {
                        return .absent
                    }
                    if prefix[offset + 1] == 0x78 {
                        guard length >= 5 else { return .absent }
                        let ncbd = Int(prefix[offset + 4]) << 8 | Int(prefix[offset + 5])
                        // A shared depth (bit 15) is read as the decoder reads it (J2KPart2CBDMarker.parse).
                        return .components(ncbd & 0x8000 != 0 ? max(ncbd & 0x7FFF, codedComponents) : ncbd)
                    }
                    offset += 2 + length
                }
                return .absent
            }
            /// The main header is read in one bounded chunk per fragment; a header longer than the first chunk (large
            /// MCT arrays) gets one larger read, and a CBD beyond that falls back to Csiz.
            let mainHeaderReadLimits = [64 * 1024, 4 * 1024 * 1024]
            var mapped: [[Int]] = []
            for fragment in fragments {
                try Task.checkCancellation()
                guard fragment.valueRange.count >= 42 else { throw Failure.invalidFragmentation(transferSyntax.rawValue) }
                var coded = 0
                var cbdComponents: Int?
                for limit in mainHeaderReadLimits {
                    let header = [UInt8](try await read(min(fragment.valueRange.count, limit),
                                                        at: fragment.valueRange.lowerBound))
                    guard header.count >= 42, header[0] == 0xFF, header[1] == 0x4F,
                          header[2] == 0xFF, header[3] == 0x51 else {
                        throw Failure.invalidFragmentation(transferSyntax.rawValue)
                    }
                    coded = Int(header[40]) << 8 | Int(header[41])
                    let walk = reconstructedComponents(
                        in: header, sizLength: Int(header[4]) << 8 | Int(header[5]), codedComponents: coded)
                    if case .components(let count) = walk { cbdComponents = count }
                    guard case .truncated = walk, header.count < fragment.valueRange.count else { break }
                }
                let components = cbdComponents ?? coded
                guard components > 0, components <= numberOfFrames - mapped.count else {
                    throw Failure.invalidFragmentation(transferSyntax.rawValue)
                }
                guard components * 8 <= maximumIndexBytes - indexBytes else { throw Failure.indexLimit }
                indexBytes += components * 8
                mapped.append(contentsOf: repeatElement([fragment.index], count: components))
            }
            guard mapped.count == numberOfFrames else { throw Failure.invalidFragmentation(transferSyntax.rawValue) }
            try await source.checkOpen()
            return .init(pixelDataOffset: pixelDataRange.lowerBound, numberOfFrames: numberOfFrames,
                         basicOffsetTable: bot, extendedOffsetTable: extended, fragments: fragments,
                         frameFragmentIndexes: mapped, diagnostics: diagnostics)
        }
        let byOffset = Dictionary(uniqueKeysWithValues: fragments.map { ($0.relativeItemOffset, $0.index) })
        /// Frame boundaries the codestreams themselves mark (JPEG markers, JPEG 2000 codestream ends).
        func codestreamFrames() async throws -> [[Int]] {
            if transferSyntax == .jpeg2000Lossless || transferSyntax == .jpeg2000 {
                return try await DicomJ2KFrameBoundaryScanner.map(
                    source: source, fragments: fragments, numberOfFrames: numberOfFrames,
                    maximumScanBytes: maximumBoundaryScanBytes
                )
            }
            return try await DicomJPEGFrameBoundaryScanner.map(
                source: source, fragments: fragments, numberOfFrames: numberOfFrames,
                syntax: transferSyntax, maximumScanBytes: maximumBoundaryScanBytes
            )
        }
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
            var tableDiagnostics: [DicomEncapsulatedPixelDataDiagnostic] = []
            if bot.offsets.count == numberOfFrames,
               let frames = Self.mapUsingOffsets(bot.offsets.map(UInt64.init), fragmentCount: fragments.count,
                                                  fragmentIndexByRelativeItemOffset: byOffset, diagnostics: &tableDiagnostics) {
                diagnostics += tableDiagnostics
                mapped = frames
            } else if !singleFragment, let frames = try? await codestreamFrames() {
                // Issue #3053: a Basic Offset Table that names no item start is ignored, as GDCM ignores it, only
                // when every frame is a complete codestream whose markers delimit it; any other table is refused.
                diagnostics.append(.init(severity: .warning, message: "The Basic Offset Table does not address the "
                    + "fragments; the codestream markers delimit the \(numberOfFrames) frames."))
                mapped = frames
            } else {
                throw Failure.invalidOffsetTable
            }
        } else if numberOfFrames == 1 {
            mapped = [Array(fragments.indices)]
        } else if fragments.count == numberOfFrames {
            mapped = fragments.map { [$0.index] }
        } else {
            guard !singleFragment else { throw Failure.invalidFragmentation(transferSyntax.rawValue) }
            mapped = try await codestreamFrames()
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
