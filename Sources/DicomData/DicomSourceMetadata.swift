import Foundation

/// Existing value-type metadata plus source-relative bulk offsets. Values are decoded
/// by DicomDataSetParser; this framing scan never materializes top-level Pixel Data.
public struct DicomSourceMetadata: Sendable {
    public let dataSet: DicomDataSet
    public let fileMetaInformation: DicomDataSet
    public let transferSyntax: DicomTransferSyntax
    public let sourceRevision: UUID
    public let pixelDataRange: Range<Int>?
    public let pixelDataTag: Int?
    /// Value Representation of the Pixel Data element as encoded in the source (OB or OW). Under Explicit VR
    /// Big Endian an OW element holds 16-bit words even for 8-bit samples (PS3.5 §7.6.1.1.1), so readers need
    /// it to restore the sample order.
    public let pixelDataVR: DicomVR?
    public let pixelDataIsEncapsulated: Bool
    /// Bytes appended to the bounded metadata buffers, excluding allocator bookkeeping.
    public let metadataCopiedBytes: Int
    /// Offsets are relative to the compact metadata buffer, which omits pixel values
    /// but retains a zero-length Pixel Data header for VR validation,
    /// rather than the original file. Empty for compatibility-mode reads.
    public let dataSetDiagnostics: [DicomDataSetReadResult.Diagnostic]
    /// Offsets are relative to the separate File Meta Information buffer.
    public let fileMetaDiagnostics: [DicomDataSetReadResult.Diagnostic]

    public enum Failure: Error, Equatable, Sendable {
        case missingPart10Signature
        case missingTransferSyntax
        case nonSeekableTransferSyntax
        case metadataLimit
        case invalidFileMetaLength
        case duplicatePixelData
    }

    public static func readPart10(from source: DicomByteSource,
                                  maximumMetadataBytes: Int = 32 * 1024 * 1024,
                                  limits: DicomDataSetParseLimits = .default) async throws -> Self {
        try await readSource(from: source, maximumMetadataBytes: maximumMetadataBytes, limits: limits,
            mode: nil, privateDictionary: .standard, dictionary: DCMDictionary(), maximumDiagnostics: 128)
    }

    /// Validates both datasets without materializing top-level Pixel Data. The
    /// diagnostic budget is shared by the file-meta and dataset reports.
    public static func readPart10(from source: DicomByteSource, mode: DicomDataSetReadMode,
                                  maximumMetadataBytes: Int = 32 * 1024 * 1024,
                                  limits: DicomDataSetParseLimits = .default,
                                  privateDictionary: DicomPrivateDictionary = .standard,
                                  dictionary: DCMDictionary = DCMDictionary(),
                                  maximumDiagnostics: Int = 128) async throws -> Self {
        try await readSource(from: source, maximumMetadataBytes: maximumMetadataBytes, limits: limits,
            mode: mode, privateDictionary: privateDictionary, dictionary: dictionary, maximumDiagnostics: maximumDiagnostics)
    }

    private static func readSource(from source: DicomByteSource, maximumMetadataBytes: Int,
                                   limits: DicomDataSetParseLimits, mode: DicomDataSetReadMode?,
                                   privateDictionary: DicomPrivateDictionary, dictionary: DCMDictionary,
                                   maximumDiagnostics: Int) async throws -> Self {
        var scanner = Scanner(source: source, maximumBytes: max(0, maximumMetadataBytes), limits: limits)
        let signature = try await scanner.readBytes(132)
        guard signature.suffix(4) == Data("DICM".utf8) else { throw Failure.missingPart10Signature }
        var meta = Data()
        var fileMetaEndOffset: Int?
        while scanner.offset < source.count {
            if scanner.offset == fileMetaEndOffset { break }
            let groupBytes = try await source.read(scanner.offset..<scanner.boundedEnd(4)).retainedData()
            guard groupBytes.dicomInteger(at: 0, as: UInt16.self, littleEndian: true) == 2 else {
                if fileMetaEndOffset != nil { throw Failure.invalidFileMetaLength }
                break
            }
            let header = try await scanner.header(syntax: .explicitVRLittleEndian)
            try scanner.append(header.bytes, to: &meta)
            guard header.length != UInt32.max else { throw DicomSequenceValueParserError.unsupportedUndefinedLengthElement(header.tag) }
            if let end = fileMetaEndOffset {
                guard scanner.offset <= end, Int(header.length) <= end - scanner.offset else { throw Failure.invalidFileMetaLength }
            }
            let value = try await scanner.readMetadataBytes(Int(header.length))
            try scanner.append(value, to: &meta)
            if header.tag == 0x00020000 {
                guard header.vr == .UL, value.count == 4 else { throw Failure.invalidFileMetaLength }
                let length = Int(value.dicomInteger(at: 0, as: UInt32.self, littleEndian: true))
                guard length <= source.count - scanner.offset else { throw Failure.invalidFileMetaLength }
                fileMetaEndOffset = scanner.offset + length
            }
        }
        if mode != nil, fileMetaEndOffset == nil { throw Failure.invalidFileMetaLength }
        if let end = fileMetaEndOffset, scanner.offset != end { throw Failure.invalidFileMetaLength }
        let fileMeta: DicomDataSetReadResult
        if let mode {
            fileMeta = try DicomDataSetParser.read(from: meta, mode: mode, limits: limits,
                maximumDiagnostics: maximumDiagnostics, dictionary: dictionary)
        } else {
            fileMeta = .init(dataSet: try DicomDataSetParser.dataSet(from: meta, limits: limits), diagnostics: [])
        }
        guard let uid = fileMeta.dataSet.string(for: .transferSyntaxUID),
              let syntax = DicomTransferSyntax(rawValue: uid) else { throw Failure.missingTransferSyntax }
        guard !syntax.usesDataSetDeflate else { throw Failure.nonSeekableTransferSyntax }
        var metadata = Data()
        var pixelRange: Range<Int>?
        var pixelTag: Int?
        var pixelVR: DicomVR?
        var encapsulated = false
        while scanner.offset < source.count {
            let header = try await scanner.header(syntax: syntax)
            if [DicomTag.pixelData.rawValue, 0x7FE00008, 0x7FE00009].contains(header.tag) {
                guard pixelRange == nil else { throw Failure.duplicatePixelData }
                let start = scanner.offset
                pixelTag = header.tag
                pixelVR = header.vr
                encapsulated = header.length == UInt32.max
                if encapsulated { try await scanner.skipFragments(syntax: syntax) }
                else { scanner.offset = try scanner.boundedEnd(Int(header.length)) }
                pixelRange = start..<scanner.offset
                if mode != nil, header.tag == DicomTag.pixelData.rawValue {
                    // Reuse the dataset parser's VR checks without copying the bulk value.
                    // Framing/length bounds were checked against the original source above.
                    var validationHeader = header.bytes
                    let lengthWidth = syntax.isExplicitVR && !header.vr.uses32BitLength ? 2 : 4
                    validationHeader.replaceSubrange((validationHeader.endIndex - lengthWidth)..<validationHeader.endIndex,
                                                     with: repeatElement(UInt8(0), count: lengthWidth))
                    try scanner.append(validationHeader, to: &metadata)
                }
            } else {
                try scanner.append(header.bytes, to: &metadata)
                try await scanner.appendValue(header, syntax: syntax, depth: 0, to: &metadata)
            }
        }
        let dataSet: DicomDataSetReadResult
        if let mode {
            dataSet = try DicomDataSetParser.read(from: metadata, transferSyntax: syntax, mode: mode,
                limits: limits, privateDictionary: privateDictionary,
                maximumDiagnostics: max(0, maximumDiagnostics) - fileMeta.diagnostics.count, dictionary: dictionary)
        } else {
            dataSet = .init(dataSet: try DicomDataSetParser.dataSet(from: metadata, transferSyntax: syntax, limits: limits), diagnostics: [])
        }
        try await source.checkOpen()
        return Self(dataSet: dataSet.dataSet, fileMetaInformation: fileMeta.dataSet, transferSyntax: syntax,
                    sourceRevision: source.revision, pixelDataRange: pixelRange,
                    pixelDataTag: pixelTag, pixelDataVR: pixelVR, pixelDataIsEncapsulated: encapsulated,
                    metadataCopiedBytes: scanner.copiedBytes,
                    dataSetDiagnostics: dataSet.diagnostics, fileMetaDiagnostics: fileMeta.diagnostics)
    }

    private struct Scanner {
        struct Header {
            let tag: Int
            let vr: DicomVR
            let length: UInt32
            let bytes: Data
        }
        let source: DicomByteSource
        let maximumBytes: Int
        let limits: DicomDataSetParseLimits
        var offset = 0
        var copiedBytes = 0
        var headers = 0
        var items = 0

        func boundedEnd(_ length: Int) throws -> Int {
            guard length >= 0, offset >= 0, offset <= source.count, length <= source.count - offset else {
                throw DicomSequenceValueParserError.unexpectedEnd
            }
            return offset + length
        }

        mutating func readBytes(_ length: Int) async throws -> Data {
            let end = try boundedEnd(length)
            let lease = try await source.read(offset..<end)
            offset = end
            return try lease.retainedData()
        }

        mutating func readMetadataBytes(_ length: Int) async throws -> Data {
            guard length <= maximumBytes - copiedBytes else { throw Failure.metadataLimit }
            return try await readBytes(length)
        }

        mutating func append(_ bytes: Data, to output: inout Data) throws {
            guard bytes.count <= maximumBytes - copiedBytes else { throw Failure.metadataLimit }
            output.append(bytes)
            copiedBytes += bytes.count
        }

        mutating func header(syntax: DicomTransferSyntax) async throws -> Header {
            try Task.checkCancellation()
            guard headers < limits.maximumElementCount else {
                throw DicomDataSetParseError.maximumElementCountExceeded(limit: limits.maximumElementCount)
            }
            headers += 1
            var bytes = try await readBytes(8)
            var cursor = 0
            let little = !syntax.isBigEndian
            let tag = try DicomSequenceValueParser.readTag(bytes, offset: &cursor, littleEndian: little)
            if tag & 0xFFFF0000 == 0xFFFE0000 {
                if tag == 0xFFFEE000 {
                    guard items < limits.maximumItemCount else {
                        throw DicomDataSetParseError.maximumItemCountExceeded(limit: limits.maximumItemCount)
                    }
                    items += 1
                }
                return Header(tag: tag, vr: .UN, length: bytes.dicomInteger(at: 4, as: UInt32.self, littleEndian: little), bytes: bytes)
            }
            if syntax.isExplicitVR {
                let vr = bytes.withUnsafeBytes { String(decoding: $0[4..<6], as: UTF8.self) }
                if DicomVR(code: vr)?.uses32BitLength == true { bytes.append(try await readBytes(4)) }
            }
            let value = try DicomSequenceValueParser.readElementHeader(bytes, offset: &cursor, tag: tag,
                                                                      littleEndian: little, explicitVR: syntax.isExplicitVR)
            return Header(tag: tag, vr: value.vr, length: value.length, bytes: bytes)
        }

        mutating func appendValue(_ header: Header, syntax: DicomTransferSyntax, depth: Int,
                                  to output: inout Data) async throws {
            if header.length != UInt32.max {
                let value = try await readMetadataBytes(Int(header.length))
                try append(value, to: &output)
                return
            }
            guard header.vr == .SQ || header.vr == .UN else {
                throw DicomSequenceValueParserError.unsupportedUndefinedLengthElement(header.tag)
            }
            let isItem = header.tag == 0xFFFEE000
            guard isItem || depth < limits.maximumSequenceDepth else {
                throw DicomDataSetParseError.maximumSequenceDepthExceeded(limit: limits.maximumSequenceDepth)
            }
            let delimiter = header.tag == 0xFFFEE000 ? 0xFFFEE00D : 0xFFFEE0DD
            let nestedSyntax = header.vr == .UN && header.tag != 0xFFFEE000 ? .implicitVRLittleEndian : syntax
            while true {
                let child = try await self.header(syntax: nestedSyntax)
                try append(child.bytes, to: &output)
                if child.tag == delimiter {
                    guard child.length == 0 else { throw DicomSequenceValueParserError.invalidBounds }
                    return
                }
                try await appendValue(child, syntax: nestedSyntax, depth: isItem ? depth : depth + 1, to: &output)
            }
        }

        mutating func skipFragments(syntax: DicomTransferSyntax) async throws {
            while true {
                let item = try await header(syntax: syntax)
                if item.tag == 0xFFFEE0DD, item.length == 0 { return }
                guard item.tag == 0xFFFEE000, item.length != UInt32.max else {
                    throw DicomSequenceValueParserError.invalidBounds
                }
                offset = try boundedEnd(Int(item.length))
            }
        }
    }
}
