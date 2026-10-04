import Foundation

extension DicomTranscoder {
    func writeCarryingDataset(decoder: DCMDecoder, destination: DicomTransferSyntax) throws -> Data {
        var dataSet = try DicomPart10PixelDataPreserver.dataSet(from: decoder)
        // Native Pixel Data is carried as the file stored it: between Big and
        // Little Endian its samples change byte order, or every value is read
        // with its bytes swapped (3 becomes 768).
        let source = DicomTransferSyntax(uid: decoder.info(for: .transferSyntaxUID)) ?? .explicitVRLittleEndian
        if !decoder.compressedImage, (source == .explicitVRBigEndian) != (destination == .explicitVRBigEndian),
           let width = decoder.pixelDataDescriptor.map({ $0.bitsAllocated / 8 }), width > 1,
           let element = dataSet[DicomTag.pixelData], case .bytes(let bytes) = element.value {
            dataSet.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: element.vr,
                                         value: .bytes(Self.swappingByteOrder(of: bytes, width: width))))
        }
        return try write(dataSet, decoder: decoder, transferSyntax: destination)
    }

    /// Each `width`-byte value of `bytes` with its bytes reversed; a trailing
    /// partial value is left as it is.
    static func swappingByteOrder(of bytes: Data, width: Int) -> Data {
        guard width > 1 else { return bytes }
        var swapped = Data(bytes)
        swapped.withUnsafeMutableBytes { raw in
            var index = 0
            while index + width <= raw.count {
                var low = index, high = index + width - 1
                while low < high { raw.swapAt(low, high); low += 1; high -= 1 }
                index += width
            }
        }
        return swapped
    }

    func decompressToNative(decoder: DCMDecoder, source: DicomTransferSyntax,
                            destination: DicomTransferSyntax = .explicitVRLittleEndian) throws -> Data {
        let (pixelBytes, samplesPerPixel) = try nativePixelBytes(decoder: decoder, source: source)

        return try writeNativePixelData(pixelBytes, samplesPerPixel: samplesPerPixel, decoder: decoder, destination: destination)
    }

    func decompressToNative(
        decoder: DCMDecoder,
        source: DicomTransferSyntax,
        destination: DicomTransferSyntax = .explicitVRLittleEndian,
        environment: [String: String]
    ) async throws -> Data {
        let frameReader = DicomDecodedFrameReader(decoder: decoder)
        var pixelBytes = Data()
        var samplesPerPixel = 1
        for index in 0..<max(1, frameReader.frameCount) {
            let frame: DicomDecodedFrame
            do {
                frame = try await frameReader.frameExecution(at: index, environment: environment).frame
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw TranscodeError.decodeFailed(
                    sourceUID: source.rawValue,
                    reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )
            }
            if case .rgb8 = frame.pixels { samplesPerPixel = 3 }
            pixelBytes.append(try storedBytes(from: frame, decoder: decoder))
        }
        if !pixelBytes.count.isMultiple(of: 2) {
            pixelBytes.append(0x00)
        }

        return try writeNativePixelData(pixelBytes, samplesPerPixel: samplesPerPixel, decoder: decoder, destination: destination)
    }

    private func writeNativePixelData(
        _ pixelBytes: Data,
        samplesPerPixel: Int,
        decoder: DCMDecoder,
        destination: DicomTransferSyntax = .explicitVRLittleEndian
    ) throws -> Data {
        var dataSet = decoder.dataSet
        dataSet.remove(.extendedOffsetTable)
        dataSet.remove(.extendedOffsetTableLengths)
        dataSet.set(DicomDataElement(
            tag: DicomTag.pixelData.rawValue,
            vr: decoder.bitDepth > 8 ? .OW : .OB,
            value: .bytes(pixelBytes)
        ))
        if samplesPerPixel == 3 {
            dataSet.set(DicomDataElement(
                tag: DicomTag.photometricInterpretation.rawValue,
                vr: .CS,
                value: .strings(["RGB"])
            ))
            dataSet.set(DicomDataElement(
                tag: DicomTag.planarConfiguration.rawValue,
                vr: .US,
                value: .unsignedIntegers([0])
            ))
        }
        return try write(dataSet, decoder: decoder, transferSyntax: destination)
    }

    func storedFrameBytes(
        frameReader: DicomDecodedFrameReader,
        decoder: DCMDecoder,
        frameIndex: Int
    ) throws -> Data {
        let frame: DicomDecodedFrame
        do {
            frame = try frameReader.frame(at: frameIndex)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscodeError.decodeFailed(
                sourceUID: decoder.info(for: .transferSyntaxUID),
                reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }
        return try storedBytes(from: frame, decoder: decoder)
    }

    func storedFrameBytes(
        frameReader: DicomDecodedFrameReader,
        decoder: DCMDecoder,
        frameIndex: Int,
        source: DicomTransferSyntax,
        environment: [String: String]
    ) async throws -> Data {
        if !decoder.compressedImage, decoder.samplesPerPixel == 3 {
            do {
                return try decoder.displayRGBPixelBuffer(frame: frameIndex).rgbData
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw TranscodeError.decodeFailed(
                    sourceUID: source.rawValue,
                    reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )
            }
        }
        let frame: DicomDecodedFrame
        do {
            frame = try await frameReader.frameExecution(at: frameIndex, environment: environment).frame
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscodeError.decodeFailed(
                sourceUID: source.rawValue,
                reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }
        return try storedBytes(from: frame, decoder: decoder)
    }

    func write(
        _ dataSet: DicomDataSet,
        decoder: DCMDecoder,
        transferSyntax: DicomTransferSyntax,
        sopInstanceUID outputSOPInstanceUID: String? = nil
    ) throws -> Data {
        let sopClassUID = decoder.info(for: .sopClassUID)
        let sourceSOPInstanceUID = decoder.info(for: .sopInstanceUID)
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: transferSyntax,
                mediaStorageSOPClassUID: sopClassUID.isEmpty ? nil : sopClassUID,
                mediaStorageSOPInstanceUID: outputSOPInstanceUID
                    ?? (sourceSOPInstanceUID.isEmpty ? nil : sourceSOPInstanceUID)
            )
        )
    }

    /// Width of the Lossy Image Compression Ratio value the streaming executor reserves and patches.
    static let ratioPlaceholderWidth = 16

    static func applyLossyMetadata(
        to dataSet: inout DicomDataSet,
        destination: DicomTransferSyntax,
        uncompressedByteCount: Int,
        encodedByteCount: Int
    ) {
        applyLossyMetadata(to: &dataSet, destination: destination, uncompressedByteCount: uncompressedByteCount,
                           encodedByteCount: encodedByteCount, sourceSOPClassUID: nil, sourceSOPInstanceUID: nil)
    }

    /// Loss history plus derivation provenance: the existing history is kept and extended, the source instance
    /// is named in Source Image Sequence and the operation in Derivation Code Sequence (CID 7203, 113040).
    static func applyLossyMetadata(
        to dataSet: inout DicomDataSet,
        destination: DicomTransferSyntax,
        uncompressedByteCount: Int,
        encodedByteCount: Int,
        sourceSOPClassUID: String?,
        sourceSOPInstanceUID: String?
    ) {
        if let sourceSOPClassUID, let sourceSOPInstanceUID, !sourceSOPClassUID.isEmpty, !sourceSOPInstanceUID.isEmpty {
            var items = dataSet.element(for: .sourceImageSequence)?.sequenceItems ?? []
            items.append(DicomSequenceItem(dataSet: DicomDataSet(elements: [
                DicomDataElement(tag: DicomTag.referencedSOPClassUID.rawValue, vr: .UI, value: .strings([sourceSOPClassUID])),
                DicomDataElement(tag: DicomTag.referencedSOPInstanceUID.rawValue, vr: .UI, value: .strings([sourceSOPInstanceUID])),
                DicomDataElement(tag: 0x0040_A170, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: [
                    DicomDataElement(tag: 0x0008_0100, vr: .SH, value: .strings(["121320"])),
                    DicomDataElement(tag: 0x0008_0102, vr: .SH, value: .strings(["DCM"])),
                    DicomDataElement(tag: 0x0008_0104, vr: .LO, value: .strings(["Uncompressed predecessor"]))
                ]))]))
            ])))
            dataSet.set(DicomDataElement(tag: DicomTag.sourceImageSequence.rawValue, vr: .SQ, value: .sequence(items)))
            var derivations = dataSet.element(for: 0x0008_9215)?.sequenceItems ?? []
            derivations.append(DicomSequenceItem(dataSet: DicomDataSet(elements: [
                DicomDataElement(tag: 0x0008_0100, vr: .SH, value: .strings(["113040"])),
                DicomDataElement(tag: 0x0008_0102, vr: .SH, value: .strings(["DCM"])),
                DicomDataElement(tag: 0x0008_0104, vr: .LO, value: .strings(["Lossy Compression"]))
            ])))
            dataSet.set(DicomDataElement(tag: 0x0008_9215, vr: .SQ, value: .sequence(derivations)))
        }
        dataSet.set(DicomDataElement(
            tag: DicomTag.lossyImageCompression.rawValue,
            vr: .CS,
            value: .strings(["01"])
        ))
        var methods = dataSet.strings(for: .lossyImageCompressionMethod)
        switch destination {
        case .jpegLSNearLossless:
            methods.append("ISO_14495_1")
        case .jpegXL:
            methods.append("ISO_18181_1")
        case .htj2k:
            methods.append("ISO_15444_15")
        case .jpegBaseline, .jpegExtended, .jpegLossless, .jpegLosslessFirstOrder:
            methods.append("ISO_10918_1")
        default:
            methods.append("ISO_15444_1")
        }
        dataSet.set(DicomDataElement(
            tag: DicomTag.lossyImageCompressionMethod.rawValue,
            vr: .CS,
            value: .strings(methods)
        ))
        let ratio = encodedByteCount > 0
            ? Double(uncompressedByteCount) / Double(encodedByteCount)
            : 0
        var ratios = dataSet.strings(for: .lossyImageCompressionRatio)
        // A zero encoded count means the streaming executor patches the value later: reserve its width.
        ratios.append(encodedByteCount > 0 ? String(format: "%.6g", ratio) : String(repeating: " ", count: ratioPlaceholderWidth))
        dataSet.set(DicomDataElement(
            tag: DicomTag.lossyImageCompressionRatio.rawValue,
            vr: .DS,
            value: .strings(ratios)
        ))

        var imageType = dataSet.strings(for: .imageType)
        if imageType.isEmpty {
            imageType = ["DERIVED", "PRIMARY"]
        } else {
            imageType[0] = "DERIVED"
        }
        dataSet.set(DicomDataElement(
            tag: DicomTag.imageType.rawValue,
            vr: .CS,
            value: .strings(imageType)
        ))
        let codecName: String
        switch destination {
        case .jpegLSNearLossless:
            codecName = "JPEG-LS"
        case .jpegXL:
            codecName = "JPEG XL"
        case .htj2k:
            codecName = "HTJ2K"
        case .jpegBaseline, .jpegExtended, .jpegLossless, .jpegLosslessFirstOrder:
            codecName = "JPEG"
        default:
            codecName = "JPEG 2000"
        }
        let operationDescription = "Irreversible \(codecName) transcoding"
        let existingDescription = dataSet.string(for: .derivationDescription)
        let description = existingDescription.map { "\($0); \(operationDescription)" }
            ?? operationDescription
        dataSet.set(DicomDataElement(
            tag: DicomTag.derivationDescription.rawValue,
            vr: .ST,
            value: .strings([description])
        ))
    }

    static func encapsulate(
        fragments: [Data],
        forceExtendedOffsets: Bool = false,
        emptyBasicOffsetTable: Bool = false
    ) throws -> (
        pixelData: Data,
        extendedOffsetTable: Data?,
        extendedOffsetTableLengths: Data?
    ) {
        let paddedFragments = fragments.map { fragment -> Data in
            guard !fragment.count.isMultiple(of: 2) else { return fragment }
            var padded = fragment
            padded.append(0x00)
            return padded
        }
        var offsets: [UInt64] = []
        var running: UInt64 = 0
        for fragment in paddedFragments {
            offsets.append(running)
            let itemLength = UInt64(fragment.count) + 8
            let next = running.addingReportingOverflow(itemLength)
            guard !next.overflow else {
                throw TranscodeError.unsupportedPixelShape(
                    reason: "Encapsulated frame offsets exceed the DICOM 64-bit table range."
                )
            }
            running = next.partialValue
        }
        let useExtendedOffsets = forceExtendedOffsets
            || offsets.contains { $0 > UInt64(UInt32.max) }
        var basicOffsetTable = Data()
        if !useExtendedOffsets, !emptyBasicOffsetTable {
            for offset in offsets {
                let value = UInt32(offset)
                withUnsafeBytes(of: value.littleEndian) {
                    basicOffsetTable.append(contentsOf: $0)
                }
            }
        }

        var data = Data()
        appendItem(basicOffsetTable, to: &data)
        for fragment in paddedFragments {
            appendItem(fragment, to: &data)
        }
        // Sequence delimiter.
        data.append(contentsOf: [0xFE, 0xFF, 0xDD, 0xE0, 0x00, 0x00, 0x00, 0x00])
        guard useExtendedOffsets else { return (data, nil, nil) }
        var extendedOffsets = Data()
        var extendedLengths = Data()
        // EOT lengths exclude item padding; offsets still include the stored items.
        for (offset, fragment) in zip(offsets, fragments) {
            withUnsafeBytes(of: offset.littleEndian) { extendedOffsets.append(contentsOf: $0) }
            let length = UInt64(fragment.count)
            withUnsafeBytes(of: length.littleEndian) { extendedLengths.append(contentsOf: $0) }
        }
        return (data, extendedOffsets, extendedLengths)
    }

    static func replaceEncapsulatedPixelData(
        in dataSet: inout DicomDataSet,
        with encapsulation: (
            pixelData: Data,
            extendedOffsetTable: Data?,
            extendedOffsetTableLengths: Data?
        )
    ) {
        dataSet.remove(.extendedOffsetTable)
        dataSet.remove(.extendedOffsetTableLengths)
        if let offsets = encapsulation.extendedOffsetTable,
           let lengths = encapsulation.extendedOffsetTableLengths {
            dataSet.set(DicomDataElement(
                tag: DicomTag.extendedOffsetTable.rawValue,
                vr: .OV,
                value: .bytes(offsets)
            ))
            dataSet.set(DicomDataElement(
                tag: DicomTag.extendedOffsetTableLengths.rawValue,
                vr: .OV,
                value: .bytes(lengths)
            ))
        }
        dataSet.set(DicomDataElement(
            tag: DicomTag.pixelData.rawValue,
            vr: .OB,
            value: .bytes(encapsulation.pixelData)
        ))
    }

    private func nativePixelBytes(decoder: DCMDecoder, source: DicomTransferSyntax) throws -> (Data, Int) {
        let frameReader = DicomDecodedFrameReader(decoder: decoder)
        var pixelBytes = Data()
        var samplesPerPixel = 1
        for index in 0..<max(1, frameReader.frameCount) {
            let frame: DicomDecodedFrame
            do {
                frame = try frameReader.frame(at: index)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw TranscodeError.decodeFailed(
                    sourceUID: source.rawValue,
                    reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )
            }
            if case .rgb8 = frame.pixels { samplesPerPixel = 3 }
            pixelBytes.append(try storedBytes(from: frame, decoder: decoder))
        }
        if pixelBytes.count % 2 != 0 {
            pixelBytes.append(0x00)
        }
        return (pixelBytes, samplesPerPixel)
    }

    /// Little-endian stored-value bytes of a decoded frame (see `DicomDecodedFrame.storedSampleData()`);
    /// the output dataset keeps Photometric Interpretation and Pixel Representation, so stored values and
    /// the tags stay consistent.
    private func storedBytes(from frame: DicomDecodedFrame, decoder: DCMDecoder) throws -> Data {
        frame.storedSampleData()
    }

    private static func appendItem(_ payload: Data, to data: inout Data) {
        data.append(contentsOf: [0xFE, 0xFF, 0x00, 0xE0])
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
    }
}
