import Foundation

/// Internal single-frame codec input. Source UIDs are retained, so this is not a derived clinical object.
enum DicomSingleFramePart10Writer {
    static func data(
        dataSet sourceDataSet: DicomDataSet, transferSyntax: DicomTransferSyntax,
        frameCount: Int, frame: Int, rawFrame: Data,
        nativeLayout: DicomPixelDataDescriptor?, packedBitOffset: Int, pixelDataTag: Int?,
        wordSwapLeadingBytes: Int = 0
    ) throws -> Data {
        guard frame >= 0, frame < frameCount else { throw DicomSourceFrameIndex.Failure.invalidLayout }
        var dataSet = sourceDataSet
        dataSet.remove(.pixelData)
        dataSet.remove(0x7FE00008)
        dataSet.remove(0x7FE00009)
        dataSet.set(.init(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["1"])))
        dataSet.remove(.extendedOffsetTable)
        dataSet.remove(.extendedOffsetTableLengths)
        dataSet.remove(0x7FE00003) // Encapsulated Pixel Data Value Total Length no longer describes this frame.
        if let perFrame = dataSet[.perFrameFunctionalGroupsSequence], case .sequence(let items) = perFrame.value {
            guard items.count == frameCount else { throw DicomSourceFrameIndex.Failure.invalidLayout }
            dataSet.set(.init(tag: perFrame.tag, vr: .SQ, value: .sequence([items[frame]])))
        }
        var bytes = rawFrame
        if let nativeLayout {
            if nativeLayout.eightBitSamplesAreWordSwapped {
                // `rawFrame` holds the whole 16-bit words covering the frame (PS3.5 §7.6.1.1.1). Swapping each
                // word back yields the samples in raster order; the frame itself starts `wordSwapLeadingBytes`
                // into them. A word missing its second byte (truncated source) contributes a zero sample.
                guard wordSwapLeadingBytes >= 0, wordSwapLeadingBytes <= 1 else { throw DicomSourceFrameIndex.Failure.invalidLayout }
                var restored = Data(count: bytes.count + bytes.count % 2)
                for pair in stride(from: 0, to: restored.count, by: 2) {
                    restored[pair] = pair + 1 < bytes.count ? bytes[bytes.startIndex + pair + 1] : 0
                    restored[pair + 1] = bytes[bytes.startIndex + pair]
                }
                let start = restored.startIndex + wordSwapLeadingBytes
                let end = start + nativeLayout.bytesPerFrame
                guard end <= restored.endIndex else { throw DicomSourceFrameIndex.Failure.invalidLayout }
                bytes = restored.subdata(in: start..<end)
            }
            if nativeLayout.bitsAllocated == 1 {
                let shift = packedBitOffset
                let count = nativeLayout.bitsPerFrame / 8 + (nativeLayout.bitsPerFrame % 8 == 0 ? 0 : 1)
                var aligned = Data(count: count)
                for byte in 0..<count {
                    let first = bytes[bytes.startIndex + byte] >> shift
                    let next: UInt8 = shift > 0 && byte + 1 < bytes.count
                        ? bytes[bytes.startIndex + byte + 1] << (8 - shift) : 0
                    aligned[byte] = first | next
                }
                if nativeLayout.bitsPerFrame % 8 != 0 {
                    aligned[count - 1] &= UInt8((1 << (nativeLayout.bitsPerFrame % 8)) - 1)
                }
                bytes = aligned
            }
            let tag = pixelDataTag ?? DicomTag.pixelData.rawValue
            let vr: DicomVR = tag == 0x7FE00008 ? .OF : (tag == 0x7FE00009 ? .OD : (nativeLayout.bitsAllocated <= 8 ? .OB : .OW))
            dataSet.set(.init(tag: tag, vr: vr, value: .bytes(bytes)))
            return try encodable(dataSet) {
                try DicomDataSetWriter.part10Data(from: $0, options: .init(transferSyntax: transferSyntax))
            }
        }
        dataSet = try encodable(dataSet) { try DicomDataSetWriter.dataSetData(from: $0); return $0 }
        // Encapsulated syntax headers are Explicit VR Little Endian. Encode metadata
        // with the existing writer, then supply a standard empty BOT and single frame item.
        var encoded = try DicomDataSetWriter.dataSetData(from: dataSet)
        encoded.append(contentsOf: [0xE0, 0x7F, 0x10, 0, 0x4F, 0x42, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
        encoded.append(contentsOf: [0xFE, 0xFF, 0, 0xE0, 0, 0, 0, 0])
        if bytes.count % 2 != 0 { bytes.append(0) }
        guard let length = UInt32(exactly: bytes.count), length != UInt32.max else { throw DicomSourceFrameIndex.Failure.frameLimit }
        encoded.append(contentsOf: [0xFE, 0xFF, 0, 0xE0])
        var littleLength = length.littleEndian
        withUnsafeBytes(of: &littleLength) { encoded.append(contentsOf: $0) }
        encoded.append(bytes)
        encoded.append(contentsOf: [0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0])
        return try DicomDataSetWriter.part10Data(
            fromEncodedDataSet: encoded, transferSyntax: transferSyntax,
            mediaStorageSOPClassUID: dataSet.string(for: .sopClassUID) ?? DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
            mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID) ?? placeholderUID
        )
    }

    /// Stands in for a missing or malformed SOP Instance UID: this file is a codec input that never leaves memory.
    private static let placeholderUID = "2.25.0"

    /// Runs `write` on the dataset as read. A value the writer refuses that has nothing to do with the pixels (an
    /// empty UID, text outside the declared character set, a private DS longer than 16 bytes) must not stop the
    /// frame from decoding (issue #2850): the write is retried without the top-level elements that do not encode,
    /// and with a placeholder SOP Instance UID. The functional groups carry each frame's rescale and geometry, so
    /// one that does not encode refuses the frame rather than decoding it with the wrong values.
    private static func encodable<Result>(
        _ dataSet: DicomDataSet, _ write: (DicomDataSet) throws -> Result
    ) throws -> Result {
        do {
            return try write(dataSet)
        } catch let failure as DicomDataSetWriterError {
            var reduced = DicomDataSet()
            for element in dataSet.elements {
                if element.tag == DicomTag.sopInstanceUID.rawValue {
                    let single = DicomDataSet(elements: [element])
                    let valid = (try? DicomDataSetWriter.dataSetData(from: single)) != nil
                        && element.stringValue?.isEmpty == false
                    reduced.set(valid ? element : .init(tag: element.tag, vr: .UI, value: .strings([placeholderUID])))
                    continue
                }
                guard (try? DicomDataSetWriter.dataSetData(from: DicomDataSet(elements: [element]))) != nil else {
                    let functionalGroups = [DicomTag.perFrameFunctionalGroupsSequence.rawValue,
                                            DicomTag.sharedFunctionalGroupsSequence.rawValue]
                    if functionalGroups.contains(element.tag) { throw failure }
                    continue
                }
                reduced.set(element)
            }
            if reduced[.sopInstanceUID] == nil {
                reduced.set(.init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([placeholderUID])))
            }
            return try write(reduced)
        }
    }
}
