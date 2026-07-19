import Foundation
import simd

extension DCMDecoder {
    /// Reads the next DICOM tag from the data stream and records whether endianness changed.
    ///
    /// Advances `location` via the internal `tagParser`. If the parser's detected endianness differs
    /// from the decoder's current setting, the binary reader is recreated immediately for value reads, while
    /// the parser is rebuilt only after the current tag's VR and length have been consumed.
    /// - Returns: The tag encoded as `(group << 16) | element` and whether byte order changed while parsing it.
    private func getNextTag() -> (tag: Int, endiannessChanged: Bool, wasInSequence: Bool) {
        guard let parser = tagParser else { return (0, false, false) }

        let previousEndianness = littleEndian
        let wasInSequence = parser.isInSequence
        let tag = parser.getNextTag(
            location: &location,
            data: dicomData,
            littleEndian: &littleEndian,
            bigEndianTransferSyntax: bigEndianTransferSyntax,
            explicitVR: isExplicitVRTransferSyntax
        )

        let endiannessChanged = littleEndian != previousEndianness
        if endiannessChanged {
            reader = DCMBinaryReader(data: dicomData, littleEndian: littleEndian)
        }

        return (tag, endiannessChanged, wasInSequence)
    }

    /// Adds a string metadata entry for a DICOM tag into the decoder's metadata dictionary.
    /// - Parameters:
    ///   - tag: The DICOM tag encoded as `group << 16 | element`.
    ///   - stringValue: The string value to associate with the tag, or `nil` if no value is present.
    private func addInfo(tag: Int, stringValue: String?) {
        guard let parser = tagParser else { return }
        parser.addInfo(tag: tag, stringValue: stringValue, location: &location, infoDict: &dicomInfoDict)
    }

    /// Adds an integer metadata entry for the specified DICOM tag into the decoder's metadata dictionary.
    /// If the internal `tagParser` is unavailable, this is a no-op.
    /// - Parameters:
    ///   - tag: The DICOM tag (encoded as `group << 16 | element`).
    ///   - intValue: The integer value to associate with the tag.
    private func addInfo(tag: Int, intValue: Int) {
        guard let parser = tagParser else { return }
        parser.addInfo(tag: tag, intValue: intValue, location: &location, infoDict: &dicomInfoDict)
    }

    /// Buffers metadata additions from tag handlers and applies them after each handler completes.
    ///
    /// This avoids exclusivity conflicts with `inout` parameters (`location`, `dicomInfoDict`) that
    /// would occur if handlers tried to call `addInfo` directly while holding a reference to these.
    private final class InfoAdder {
        private var stringMetadata: [(tag: Int, value: String?)] = []
        private var intMetadata: [(tag: Int, value: Int)] = []

        /// Buffers a string-valued metadata entry for a DICOM tag to be flushed later.
        /// - Parameters:
        ///   - tag: The DICOM tag encoded as an `Int` (group << 16 | element).
        ///   - stringValue: The string value to buffer, or `nil` if no value is present.
        func addInfo(tag: Int, stringValue: String?) {
            stringMetadata.append((tag, stringValue))
        }

        /// Buffers an integer metadata entry for later flushing to the decoder.
        /// - Parameters:
        ///   - tag: The DICOM tag (combined group and element) associated with the value.
        ///   - intValue: The integer metadata value to store.
        func addInfoInt(tag: Int, intValue: Int) {
            intMetadata.append((tag, intValue))
        }

        /// Commits buffered metadata entries into the decoder's metadata dictionary using the provided parser.
        /// 
        /// Applies all queued string and integer metadata to `decoder.dicomInfoDict`, updating `decoder.location` as each entry is added, then clears the internal buffers.
        /// - Parameters:
        ///   - decoder: The `DCMDecoder` whose `dicomInfoDict` and `location` will be updated.
        ///   - parser: The `DCMTagParser` responsible for formatting and inserting each metadata entry.
        func flush(to decoder: DCMDecoder, parser: DCMTagParser) {
            // Apply all buffered metadata to the decoder's info dict
            for (tag, value) in stringMetadata {
                parser.addInfo(tag: tag, stringValue: value, location: &decoder.location, infoDict: &decoder.dicomInfoDict)
            }
            for (tag, value) in intMetadata {
                parser.addInfo(tag: tag, intValue: value, location: &decoder.location, infoDict: &decoder.dicomInfoDict)
            }
            // Clear buffers
            stringMetadata.removeAll()
            intMetadata.removeAll()
        }
    }

    /// Parses the DICOM file header from the current data buffer, populates decoder state, and locates the pixel data offset.
    /// 
    /// This method reads DICOM tags starting at the standard file header location, invokes registered tag handlers, buffers
    /// deferred tag metadata, copies parsed values (dimensions, transfer syntax, pixel calibration, palettes, offsets, etc.)
    /// into the decoder's properties, validates image dimensions and pixel buffer size, and establishes the pixel-data offset
    /// only from an explicit Pixel Data tag.
    /// - Note: The method updates many decoder properties (e.g., `width`, `height`, `bitDepth`, `transferSyntaxUID`,
    ///   `compressedImage`, `pixelWidth`, `pixelHeight`, `reds`, `greens`, `blues`, `offset`, `nImages`) as part of parsing.
    /// - Returns: `true` if header parsing completed, decoder state was populated, and a valid pixel-data offset was determined; `false` otherwise (for example when the DICOM magic marker is missing, required parser/reader is unavailable, image dimension or buffer-size validation fails, or the pixel data location cannot be determined).
    func readFileInfoUnsafe() -> Bool {
        guard let initialReader = reader else { return false }
        var reader = initialReader
        // Reset some state to sane defaults
        tagMetadataCache.removeAll()
        activeCharacterSet = .defaultCharacterSet
        isExplicitVRTransferSyntax = true
        bitDepth = 16
        compressedImage = false
        imageOrientation = nil
        imagePosition = nil
        reds = nil
        greens = nil
        blues = nil
        redPaletteDescriptor = nil
        greenPaletteDescriptor = nil
        bluePaletteDescriptor = nil
        // Move to offset 128 where "DICM" marker resides
        location = 128
        // Read the four magic bytes
        let fileMark = reader.readString(length: 4, location: &location)
        guard fileMark == "DICM" else {
            dicomFound = false
            return false
        }
        dicomFound = true
        samplesPerPixel = 1
        // Create decoder context for tag handlers
        let context = DecoderContext()
        context.specificCharacterSet = activeCharacterSet
        // Create info adder helper for tag handlers
        guard tagParser != nil else { return false }
        let infoAdder = InfoAdder()
        var decodingTags = true
        var tagCount = 0
        let maxTags = 10000  // Safety limit to prevent infinite loops
        func rebuildParserIfNeeded(afterEndiannessChange endiannessChanged: Bool) {
            guard endiannessChanged, let currentReader = self.reader else { return }
            tagParser = DCMTagParser(data: dicomData, dict: dict, binaryReader: currentReader)
        }
        func isSequenceTag(_ tag: Int, parser: DCMTagParser) -> Bool {
            if parser.currentVR == .SQ {
                return true
            }
            return dict.vrCode(forTag: tag) == "SQ"
        }

        while decodingTags && location < dicomData.count {
            tagCount += 1
            if tagCount > maxTags {
                logger.warning("Exceeded max tags at location \(location)")
                // Don't set offset here - we're not at pixel data
                // Let the end of function handle finding pixel data
                break
            }

            let parsedTag = getNextTag()
            let tag = parsedTag.tag
            guard let activeReader = self.reader else { return false }
            reader = activeReader

            // Check for end of data or invalid tag
            if tag == 0 || location >= dicomData.count {
                if offset == 0 {
                    offset = location
                }
                break
            }
            if let parser = tagParser,
               parsedTag.wasInSequence,
               parser.isInSequence == true,
               !isSequenceTag(tag, parser: parser) {
                // Sequence content is handled inside headerInfo
                addInfo(tag: tag, stringValue: nil)
                rebuildParserIfNeeded(afterEndiannessChange: parsedTag.endiannessChanged)
                continue
            }

            // Use handler registry for tag processing
            guard let parser = tagParser else { continue }

            if let handler = handlerRegistry.getHandler(for: tag) {
                // Tag has a registered handler - delegate processing
                let shouldContinue = handler.handle(
                    tag: tag,
                    reader: reader,
                    location: &location,
                    parser: parser,
                    context: context,
                    addInfo: infoAdder.addInfo(tag:stringValue:),
                    addInfoInt: infoAdder.addInfoInt(tag:intValue:)
                )

                // Flush buffered metadata after handler completes
                // This avoids exclusivity conflicts with inout location parameter
                infoAdder.flush(to: self, parser: parser)

                if tag == DicomTag.transferSyntaxUID.rawValue {
                    transferSyntaxUID = context.transferSyntaxUID
                    compressedImage = context.compressedImage
                    bigEndianTransferSyntax = context.bigEndianTransferSyntax
                    isExplicitVRTransferSyntax = DicomTransferSyntax(
                        uid: context.transferSyntaxUID
                    )?.isExplicitVR ?? true
                } else if tag == DicomTag.specificCharacterSet.rawValue {
                    activeCharacterSet = context.specificCharacterSet
                    cachedInfo.removeAll()
                }

                // Check if handler signaled to stop decoding (e.g., PixelDataTagHandler)
                if !shouldContinue || context.shouldStopDecoding {
                    decodingTags = false
                }
                rebuildParserIfNeeded(afterEndiannessChange: parsedTag.endiannessChanged)
            } else {
                // Lazy parsing optimization: Store tag metadata for deferred parsing
                // instead of eagerly parsing all tags to strings. The tag value will
                // be parsed on first access via info(for:) using parseTagOnDemand().
                let metadataVR: DicomVR = isSequenceTag(tag, parser: parser) ? .SQ : parser.currentVR
                let metadataLength: Int
                if metadataVR == .SQ, parser.currentElementLengthIsUndefined {
                    do {
                        let bounds = try DicomSequenceValueParser.undefinedLengthSequenceBounds(
                            in: dicomData,
                            valueOffset: location,
                            end: dicomData.count,
                            littleEndian: littleEndian,
                            explicitVR: isExplicitVRTransferSyntax
                        )
                        metadataLength = bounds.valueLength
                        let metadata = TagMetadata(
                            tag: tag,
                            offset: location,
                            vr: metadataVR,
                            elementLength: metadataLength
                        )
                        tagMetadataCache[tag] = metadata
                        location = bounds.endOffset
                        parser.finishSequenceValue()
                        rebuildParserIfNeeded(afterEndiannessChange: parsedTag.endiannessChanged)
                        continue
                    } catch {
                        logger.warning(
                            "Failed to scan undefined-length sequence \(String(format: "%08X", tag)): \(error)"
                        )
                        break
                    }
                } else {
                    metadataLength = parser.currentElementLength
                }
                let metadata = TagMetadata(
                    tag: tag,
                    offset: location,
                    vr: metadataVR,
                    elementLength: metadataLength
                )
                tagMetadataCache[tag] = metadata
                // Advance location to skip the element value
                location += metadataLength
                rebuildParserIfNeeded(afterEndiannessChange: parsedTag.endiannessChanged)
            }
        }

        // Copy context values back to decoder properties
        width = context.width
        height = context.height
        bitDepth = context.bitDepth
        transferSyntaxUID = context.transferSyntaxUID
        compressedImage = context.compressedImage
        bigEndianTransferSyntax = context.bigEndianTransferSyntax
        isExplicitVRTransferSyntax = DicomTransferSyntax(
            uid: context.transferSyntaxUID
        )?.isExplicitVR ?? true
        activeCharacterSet = context.specificCharacterSet
        samplesPerPixel = context.samplesPerPixel
        photometricInterpretation = context.photometricInterpretation
        pixelRepresentation = context.pixelRepresentation
        windowCenter = context.windowCenter
        windowWidth = context.windowWidth
        pixelWidth = context.pixelWidth
        pixelHeight = context.pixelHeight
        pixelDepth = context.pixelDepth
        imageOrientation = context.imageOrientation
        imagePosition = context.imagePosition
        rescaleIntercept = context.rescaleIntercept
        rescaleSlope = context.rescaleSlope
        reds = context.reds
        greens = context.greens
        blues = context.blues
        redPaletteDescriptor = context.redPaletteDescriptor
        greenPaletteDescriptor = context.greenPaletteDescriptor
        bluePaletteDescriptor = context.bluePaletteDescriptor
        offset = context.offset
        nImages = context.nImages
        // Note: modality and planarConfiguration are stored in context but not
        // copied to decoder properties - they were temporary values in the original
        // implementation, only used for passing to addInfo() metadata callbacks

        // Validate image dimensions and expected pixel buffer size
        if width <= 0 || height <= 0 {
            logger.warning("Invalid image dimensions: width=\(width), height=\(height)")
            return false
        }
        if width > Self.maxImageDimension || height > Self.maxImageDimension {
            logger.warning("Image dimensions exceed maximum allowed: \(width)x\(height) (max \(Self.maxImageDimension))")
            return false
        }
        let width64 = Int64(width)
        let height64 = Int64(height)
        let bytesPerPixel = Int64(max(1, bitDepth / 8)) * Int64(max(1, samplesPerPixel))
        let (pixelCount64, pixelOverflow) = width64.multipliedReportingOverflow(by: height64)
        if pixelOverflow {
            logger.warning("Pixel count overflow for dimensions: \(width)x\(height)")
            return false
        }
        let (totalBytes64, byteOverflow) = pixelCount64.multipliedReportingOverflow(by: bytesPerPixel)
        if byteOverflow || totalBytes64 <= 0 {
            logger.warning("Pixel buffer size overflow for dimensions: \(width)x\(height), bytesPerPixel=\(bytesPerPixel)")
            return false
        }
        if totalBytes64 > Self.maxPixelBufferSize {
            logger.warning("Pixel buffer size \(totalBytes64) bytes exceeds maximum allowed \(Self.maxPixelBufferSize) bytes")
            return false
        }

        // Ensure we have a valid pixel data offset.
        if offset == 0 {
            let sopClassUID = info(for: .sopClassUID)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            let modality = info(for: .modality)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            if sopClassUID == DicomRTStructureSet.storageSOPClassUID ||
                sopClassUID == DicomRTPlan.storageSOPClassUID ||
                DicomSRDocument.structuredReportSOPClassUIDs.contains(sopClassUID) ||
                sopClassUID == DicomGrayscalePresentationState.storageSOPClassUID ||
                DicomEncapsulatedDocument.supportedStorageSOPClassUIDs.contains(sopClassUID) ||
                DicomWaveform.supportedStorageSOPClassUIDs.contains(sopClassUID) ||
                modality == "RTSTRUCT" ||
                modality == "RTPLAN" ||
                modality == "SR" ||
                modality == "KO" ||
                modality == "PR" ||
                modality == "DOC" ||
                tagMetadataCache[DicomTag.waveformSequence.rawValue] != nil {
                return true
            }
            if tagMetadataCache[DicomTag.floatPixelData.rawValue] != nil ||
                tagMetadataCache[DicomTag.doubleFloatPixelData.rawValue] != nil {
                return true
            }
            if let syntax = DicomTransferSyntax(uid: transferSyntaxUID),
               syntax.usesPixelDataProviderURL,
               tagMetadataCache[DicomTag.pixelDataProviderURL.rawValue] != nil ||
               dicomInfoDict[DicomTag.pixelDataProviderURL.rawValue] != nil {
                return true
            }
            if compressedImage {
                logger.warning("Could not determine pixel data location: Pixel Data tag missing for compressed transfer syntax \(transferSyntaxUID)")
            } else if nImages > 1 {
                logger.warning("Could not determine pixel data location: Pixel Data tag missing for multi-frame image with \(nImages) frames")
            } else {
                logger.warning("Could not determine pixel data location: Pixel Data tag missing; refusing to infer pixel offset from file size")
            }
            return false
        }

        return true
    }


}
