import Foundation
import DicomObjects

/// Source-relative addresses. Building the index reads headers and bounded metadata,
/// skips every Waveform Data value, and never allocates a sample array.
public struct DicomWaveformSourceIndex: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case invalidPart10, unsupportedTransferSyntax, invalidStructure, metadataLimit, invalidGroup
    }
    public struct Group: Sendable {
        public let dataRange: Range<Int>
        public let numberOfSamples: Int
        public let metadata: DicomWaveformMultiplexGroup
    }
    public let sourceRevision: UUID
    public let transferSyntax: DicomTransferSyntax
    public let groups: [Group]
    public let annotations: [DicomWaveformAnnotation]
    public var diagnostics: [DicomWaveformDiagnostic] {
        DicomWaveformDiagnostic.evaluate(annotations: annotations, groups: groups.map { ($0.metadata.numberOfChannels, $0.numberOfSamples) })
    }

    public static func build(from source: DicomByteSource, maximumMetadataBytes: Int = 8 * 1024 * 1024) async throws -> Self {
        var walker = Walker(source: source, remaining: max(0, maximumMetadataBytes))
        guard try await walker.read(132).suffix(4) == Data("DICM".utf8) else { throw Failure.invalidPart10 }
        var meta = Data()
        while walker.offset < source.count {
            let probe = Data(try await source.read(walker.offset..<min(source.count, walker.offset + 4)).retainedData())
            guard probe.count == 4 else { throw Failure.invalidStructure }
            if probe[0] != 2 || probe[1] != 0 { break }
            let header = try await walker.header(.explicitVRLittleEndian)
            guard header.length != UInt32.max else { throw Failure.invalidStructure }
            meta.append(header.bytes)
            meta.append(try await walker.read(Int(header.length)))
        }
        let fileMeta = try DicomDataSetParser.dataSet(from: meta)
        guard let uid = fileMeta.string(for: .transferSyntaxUID), let syntax = DicomTransferSyntax(rawValue: uid),
              [.implicitVRLittleEndian, .explicitVRLittleEndian].contains(syntax) else { throw Failure.unsupportedTransferSyntax }
        // Reconstruct only metadata. All sequences/items are emitted undefined-length so
        // removing bulk values cannot invalidate their original explicit lengths.
        let compact = try await walker.dataset(end: source.count, delimiter: nil, syntax: syntax, depth: 0, waveformGroup: false)
        let ds = try DicomDataSetParser.dataSet(from: compact, transferSyntax: syntax)
        let items = ds.sequenceItems(for: .waveformSequence)
        guard !items.isEmpty, items.count == walker.ranges.count else { throw Failure.invalidGroup }
        var groups: [Group] = []
        for (item, range) in zip(items, walker.ranges) {
            let d = item.dataSet
            guard let channels = d.int(for: .numberOfWaveformChannels), channels > 0,
                  let samples = d.int(for: .numberOfWaveformSamples), samples > 0,
                  let frequency = d.float(for: .samplingFrequency), frequency.isFinite, frequency > 0,
                  let interpretation = d.string(for: .waveformSampleInterpretation).flatMap(DicomWaveformSampleInterpretation.init(rawValue:)),
                  d.int(for: .waveformBitsAllocated) == interpretation.bitsAllocated,
                  d.sequenceItems(for: .channelDefinitionSequence).count == channels else { throw Failure.invalidGroup }
            let stride = channels.multipliedReportingOverflow(by: interpretation.bytesPerSample)
            let total = samples.multipliedReportingOverflow(by: stride.partialValue)
            guard !stride.overflow, !total.overflow, total.partialValue <= range.count,
                  range.count - total.partialValue == total.partialValue % 2 else { throw Failure.invalidGroup }
            let channelModels = d.sequenceItems(for: .channelDefinitionSequence).enumerated().map {
                DicomWaveformParser.channel(from: $0.element.dataSet, fallbackNumber: $0.offset + 1, samples: [], interpretation: interpretation)
            }
            let group = DicomWaveformMultiplexGroup(label: d.string(for: .multiplexGroupLabel),
                originality: d.string(for: .waveformOriginality) ?? "ORIGINAL", samplingFrequency: frequency,
                timeOffsetMilliseconds: d.float(for: .multiplexGroupTimeOffset),
                triggerTimeOffsetMilliseconds: d.float(for: .triggerTimeOffset), triggerSamplePosition: d.int(for: .triggerSamplePosition),
                sampleInterpretation: interpretation, waveformDataDisplayScale: ds.float(for: .waveformDataDisplayScale),
                paddingValue: DicomWaveformParser.sampleValue(d, tag: 0x5400100A, interpretation: interpretation), channels: channelModels)
            groups.append(.init(dataRange: range, numberOfSamples: samples, metadata: group))
        }
        try await source.checkOpen()
        return .init(sourceRevision: source.revision, transferSyntax: syntax, groups: groups,
                     annotations: ds.sequenceItems(for: .waveformAnnotationSequence).map { .init(dataSet: $0.dataSet) })
    }

    private struct Walker {
        struct Header { let tag: Int; let vr: DicomVR; let length: UInt32; var bytes: Data }
        let source: DicomByteSource
        var remaining: Int
        var offset = 0
        var ranges: [Range<Int>] = []
        var headers = 0

        mutating func read(_ count: Int) async throws -> Data {
            guard count >= 0, count <= remaining else { throw Failure.metadataLimit }
            guard count <= source.count - offset else { throw Failure.invalidStructure }
            let bytes = Data(try await source.read(offset..<(offset + count)).retainedData())
            offset += count; remaining -= count
            return bytes
        }

        // Same package header primitives used by DicomSourceMetadata's framing scan.
        mutating func header(_ syntax: DicomTransferSyntax) async throws -> Header {
            guard headers < 100_000 else { throw Failure.metadataLimit }
            headers += 1
            var bytes = try await read(8)
            var cursor = 0
            let tag = try DicomSequenceValueParser.readTag(bytes, offset: &cursor, littleEndian: true)
            if tag & 0xFFFF0000 == 0xFFFE0000 {
                let length = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
                return .init(tag: tag, vr: .UN, length: length, bytes: bytes)
            }
            if syntax.isExplicitVR, DicomVR(code: String(decoding: bytes[4..<6], as: UTF8.self))?.uses32BitLength == true {
                bytes.append(try await read(4))
            }
            let value = try DicomSequenceValueParser.readElementHeader(bytes, offset: &cursor, tag: tag, littleEndian: true, explicitVR: syntax.isExplicitVR)
            return .init(tag: tag, vr: value.vr, length: value.length, bytes: bytes)
        }

        mutating func dataset(end: Int, delimiter: Int?, syntax: DicomTransferSyntax, depth: Int,
                              waveformGroup: Bool) async throws -> Data {
            guard depth <= 32 else { throw Failure.metadataLimit }
            var output = Data()
            var foundData = false
            while offset < end {
                var h = try await header(syntax)
                if h.tag == delimiter {
                    guard h.length == 0 else { throw Failure.invalidStructure }
                    if waveformGroup && !foundData { throw Failure.invalidGroup }
                    return output
                }
                guard h.tag & 0xFFFF0000 != 0xFFFE0000 else { throw Failure.invalidStructure }
                let undefined = h.length == UInt32.max
                guard undefined || Int(h.length) <= end - offset else { throw Failure.invalidStructure }
                if h.tag == 0x54001010 {
                    guard waveformGroup, !foundData, !undefined else { throw Failure.invalidGroup }
                    foundData = true
                    ranges.append(offset..<(offset + Int(h.length)))
                    offset += Int(h.length)
                    continue
                }
                if h.vr == .SQ || undefined {
                    let sequenceEnd = undefined ? end : offset + Int(h.length)
                    h.bytes.replaceSubrange((h.bytes.count - 4)..<h.bytes.count, with: [255, 255, 255, 255])
                    output.append(h.bytes)
                    var terminated = !undefined
                    while offset < sequenceEnd {
                        var item = try await header(syntax)
                        if item.tag == 0xFFFEE0DD {
                            guard undefined, item.length == 0 else { throw Failure.invalidStructure }
                            terminated = true; break
                        }
                        guard item.tag == 0xFFFEE000 else { throw Failure.invalidStructure }
                        let itemUndefined = item.length == UInt32.max
                        guard itemUndefined || Int(item.length) <= sequenceEnd - offset else { throw Failure.invalidStructure }
                        let itemEnd = itemUndefined ? sequenceEnd : offset + Int(item.length)
                        item.bytes.replaceSubrange(4..<8, with: [255, 255, 255, 255])
                        output.append(item.bytes)
                        output.append(try await dataset(end: itemEnd, delimiter: itemUndefined ? 0xFFFEE00D : nil,
                            syntax: syntax, depth: depth + 1, waveformGroup: h.tag == 0x54000100))
                        output.append(Data([254,255,13,224,0,0,0,0]))
                    }
                    guard terminated else { throw Failure.invalidStructure }
                    output.append(Data([254,255,221,224,0,0,0,0]))
                } else {
                    output.append(h.bytes)
                    output.append(try await read(Int(h.length)))
                }
            }
            guard delimiter == nil, offset == end else { throw Failure.invalidStructure }
            if waveformGroup && !foundData { throw Failure.invalidGroup }
            return output
        }
    }
}
