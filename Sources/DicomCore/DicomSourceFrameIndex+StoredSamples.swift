import Foundation

extension DicomSourceFrameIndex {
    /// Issue #3111: native monochrome 8- or 16-bit layouts, whose stored samples are the frame's own bytes, at most
    /// byte-swapped and masked to Bits Stored. Their frames are read at the indexed offset, with no Part 10 copy of
    /// the pixels and no second parse of them. Word-swapped 8-bit samples, 1-bit, wider and floating samples, colour
    /// and every encapsulated syntax keep the decoded path (`DicomSourceFrameSession.frame(at:)`).
    public var readsStoredSamplesDirectly: Bool {
        guard let layout = nativeLayout, metadata.pixelDataTag == DicomTag.pixelData.rawValue,
              layout.samplesPerPixel == 1, layout.bitsAllocated == 8 || layout.bitsAllocated == 16,
              !layout.eightBitSamplesAreWordSwapped,
              layout.pixelRepresentation == 0 || layout.pixelRepresentation == 1 else { return false }
        let photometric = layout.photometricInterpretation
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\0"))).uppercased()
        return photometric == "MONOCHROME1" || photometric == "MONOCHROME2"
    }

    /// The stored samples of one frame of a `readsStoredSamplesDirectly` layout, identical to
    /// `decodeArray(frame:part10:).storedSampleData()` with the same metadata. The metadata comes from the header the
    /// decoded path writes for this frame, without the frame's pixels (`directFrameMetadata`); the samples are read
    /// once at their offset and converted in place, only when the byte order or Bits Stored require it. A header whose
    /// decoded description disagrees with the index falls back to the decoded path.
    func storedSampleFrame(frame: Int, from source: DicomByteSource,
                           maximumFrameBytes: Int) async throws -> DicomStoredSampleFrame {
        guard readsStoredSamplesDirectly, let layout = nativeLayout else {
            throw Failure.unsupportedLayout("Stored samples are read directly only from native monochrome 8/16-bit frames.")
        }
        guard source.revision == metadata.sourceRevision else { throw DicomByteSource.Failure.changed }
        let ranges = try ranges(forFrame: frame)
        guard ranges.count == 1, let range = ranges.first, range.count <= maximumFrameBytes else { throw Failure.frameLimit }
        let frameMetadata = try await directFrameMetadata(frame: frame, layout: layout, source: source)
        let photometric = frameMetadata.photometricInterpretation
        guard frameMetadata.samplesPerPixel == 1, frameMetadata.bitsAllocated == layout.bitsAllocated,
              frameMetadata.pixelRepresentation == layout.pixelRepresentation,
              photometric == "MONOCHROME1" || photometric == "MONOCHROME2" else {
            let raw = try await frameData(at: frame, from: source, maximumFrameBytes: maximumFrameBytes)
            let decoded = try await decodeArray(frame: frame, part10: part10Data(frame: frame, rawFrame: raw))
            return DicomStoredSampleFrame(index: frame, data: decoded.storedSampleData(), metadata: decoded.metadata)
        }
        // The lease is released at the end of this statement, so the samples are converted without a copy.
        var samples = try await source.read(range).retainedData()
        if samples.startIndex != 0 { samples = Data(samples) }
        Self.convertToStoredSamples(&samples, metadata: frameMetadata,
                                    bigEndian: metadata.transferSyntax == .explicitVRBigEndian)
        try await source.checkOpen()
        return DicomStoredSampleFrame(index: frame, data: samples, metadata: frameMetadata)
    }

    /// The decoded path's metadata for `frame`: the header it writes for the frame, with one placeholder word for the
    /// pixels (the header parser needs a Pixel Data value inside the object; no metadata depends on its length), parsed
    /// once per series by `DicomStoredSampleMetadataCache`.
    private func directFrameMetadata(frame: Int, layout: DicomPixelDataDescriptor,
                                     source: DicomByteSource) async throws -> DicomDecodedFrameMetadata {
        let cache = DicomStoredSampleMetadataCache.shared
        let key = DicomStoredSampleMetadataCache.key(
            dataSet: metadata.dataSet, transferSyntax: metadata.transferSyntax, frameCount: frameCount, frame: frame,
            rows: layout.rows, columns: layout.columns)
        if let key, let cached = cache.metadata(for: key) { return cached }
        let header = try part10Data(frame: frame, rawFrame: Data(count: 2))
        await source.recordCompatibilityCopy(header.count)
        let reader = try DicomDecodedFrameReader(decoder: DCMDecoder(data: header))
        let frameMetadata = reader.makeMetadata(width: layout.columns, height: layout.rows,
                                                frameCount: frameCount, frameIndex: 0)
        if let key { cache.insert(frameMetadata, for: key) }
        return frameMetadata
    }

    /// Native samples (host words after the byte order) to the `storedSampleData()` convention: the decoded path's
    /// signed level shift and MONOCHROME1 inversion cancel out, so only the byte order and the Bits Stored mask and
    /// sign extension are applied, with the same expressions. Little-endian whole words are left untouched.
    static func convertToStoredSamples(_ samples: inout Data, metadata: DicomDecodedFrameMetadata, bigEndian: Bool) {
        let signed = metadata.pixelRepresentation == 1
        if metadata.bitsAllocated == 8 {
            let bits = StoredBits(metadata, width: 8)
            guard !bits.isWholeWord else { return }
            samples.withUnsafeMutableBytes { bytes in
                for index in bytes.indices {
                    bytes[index] = UInt8(truncatingIfNeeded: bits.sample(Int(bytes[index]), signed: signed))
                }
            }
            return
        }
        let bits = StoredBits(metadata, width: 16)
        guard bigEndian || !bits.isWholeWord else { return }
        let shift = UInt16(bits.shift)
        let mask = UInt16(truncatingIfNeeded: bits.mask)
        let lead = UInt16(16 - bits.mask.nonzeroBitCount)
        let wholeWord = bits.isWholeWord
        samples.withUnsafeMutableBytes { bytes in
            for offset in stride(from: 0, to: bytes.count - 1, by: 2) {
                let word = bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                var value = bigEndian ? UInt16(bigEndian: word) : UInt16(littleEndian: word)
                if !wholeWord {
                    value = (value &>> shift) & mask
                    if signed { value = UInt16(bitPattern: Int16(bitPattern: value &<< lead) &>> lead) }
                }
                bytes.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt16.self)
            }
        }
    }
}
