import Foundation
import DicomData

public extension DCMDecoder {
    var dataSet: DicomDataSet {
        synchronized {
            let tags = Set(dicomInfoDict.keys).union(tagMetadataCache.keys)
            let context = contextualVRContextUnsafe()
            let elements = tags.compactMap { dataElementUnsafe(for: $0, context: context) }
            return DicomDataSet(elements: elements)
        }
    }

    func dataElement(for tag: DicomTag) -> DicomDataElement? {
        dataElement(for: tag.rawValue)
    }

    func dataElement(for tag: Int) -> DicomDataElement? {
        synchronized {
            dataElementUnsafe(for: tag, context: contextualVRContextUnsafe())
        }
    }

    private func dataElementUnsafe(for tag: Int, context: DicomPixelValueContext) -> DicomDataElement? {
        guard dicomInfoDict[tag] != nil || tagMetadataCache[tag] != nil else {
            return nil
        }

        let metadata = tagMetadataCache[tag]
        let vr = effectiveVR(for: tag, metadata: metadata)
        let name = dict.description(forTag: tag)
        let value = dataValue(for: tag, vr: vr, metadata: metadata, context: context)
        let element = DicomDataElement(tag: tag, vr: vr, value: value, name: name)
        guard DicomContextualVRResolver.needsContext(tag), let metadata, let bytes = rawValueData(for: metadata) else { return element }
        return DicomContextualVRResolver.resolveLegacyElement(element, bytes: bytes,
            explicitVR: isExplicitVRTransferSyntax, littleEndian: littleEndian, context: context)
    }

    /// Called under the decoder lock. Context contains only small discriminators;
    /// the modality LUT needs a presence marker, not a recursive read of its table.
    internal func contextualVRContextUnsafe() -> DicomPixelValueContext {
        let elements = DicomPixelValueContext.discriminatorTags.compactMap { tag -> DicomDataElement? in
            guard dicomInfoDict[tag] != nil || tagMetadataCache[tag] != nil else { return nil }
            let metadata = tagMetadataCache[tag]
            let vr = effectiveVR(for: tag, metadata: metadata)
            if tag == 0x00283000, vr == .SQ {
                let items: [DicomSequenceItem] = (metadata?.elementLength ?? 0) > 0 ? [.init(dataSet: .init())] : []
                return .init(tag: tag, vr: vr, value: .sequence(items))
            }
            return .init(tag: tag, vr: vr, value: dataValue(for: tag, vr: vr, metadata: metadata, context: .init()))
        }
        return DicomPixelValueContext(.init(elements: elements))
    }

    private func effectiveVR(for tag: Int, metadata: TagMetadata?) -> DicomVR {
        if let metadata, metadata.vr != .implicitRaw && metadata.vr != .unknown {
            return metadata.vr
        }
        return dictionaryVR(for: tag) ?? metadata?.vr ?? .unknown
    }

    private func dictionaryVR(for tag: Int) -> DicomVR? {
        guard let code = dict.vrCode(forTag: tag) else {
            return nil
        }
        return DicomVR(code: code)
    }

    private func dataValue(for tag: Int, vr: DicomVR, metadata: TagMetadata?, context: DicomPixelValueContext) -> DicomDataValue {
        if vr == .SQ {
            guard let metadata,
                  metadata.offset >= 0,
                  metadata.elementLength >= 0,
                  metadata.offset + metadata.elementLength <= dicomData.count else {
                return .sequence([])
            }
            let valueLengthLimit: DicomSequenceValueParser.ValueLengthLimit?
            if tag == DicomTag.voiLUTSequence.rawValue {
                valueLengthLimit = Self.voiLUTValueLengthLimit
            } else {
                valueLengthLimit = nil
            }
            let items = (try? DicomSequenceValueParser.parseItems(
                in: dicomData,
                valueOffset: metadata.offset,
                valueLength: metadata.elementLength,
                littleEndian: littleEndian,
                explicitVR: isExplicitVRTransferSyntax,
                characterSet: activeCharacterSet,
                valueLengthLimit: valueLengthLimit, parentContext: context, parentSequenceTag: tag
            )) ?? []
            return .sequence(items)
        }

        // An implicit-VR element absent from the bundled dictionary has no
        // trustworthy typed interpretation. Preserve its exact value bytes so
        // a later Explicit-VR rewrite can encode it as UN without corrupting
        // private or newly standardized attributes.
        if vr == .implicitRaw, let metadata, let raw = rawValueData(for: metadata) {
            return raw.isEmpty ? .empty : .bytes(raw)
        }

        if let metadata,
           let raw = rawValueData(for: metadata),
           let value = DicomDataValueDecoder.binaryValue(
               for: vr,
               data: raw,
               littleEndian: tag >> 16 == 2 ? true : littleEndian
           ) {
            return value
        }

        // LT, ST and UT are VM 1 and permit significant leading whitespace, line breaks,
        // and a literal backslash. Routing it through `dicomMultiValues` would
        // trim the value and split it as though it were a multi-valued UI
        // string. Remove only the single byte that can be DICOM even-length
        // padding, then preserve the decoded text verbatim.
        if [DicomVR.LT, .ST, .UT].contains(vr), let metadata, let raw = rawValueData(for: metadata) {
            var unpadded = raw
            if let last = unpadded.last, last == 0x20 || last == 0x00 {
                unpadded.removeLast()
            }
            let value = activeCharacterSet.decodePreservingWhitespace(unpadded)
            return value.isEmpty ? .empty : .strings([value])
        }

        let rawString = infoUnsafe(for: tag)
        let values = rawString.dicomMultiValues
        return values.isEmpty ? .empty : .strings(values)
    }

    private func rawValueData(for metadata: TagMetadata) -> Data? {
        guard metadata.elementLength > 0,
              metadata.offset >= 0,
              metadata.offset <= dicomData.count,
              metadata.offset + metadata.elementLength <= dicomData.count else {
            return nil
        }
        return dicomData[metadata.offset..<(metadata.offset + metadata.elementLength)]
    }
}
