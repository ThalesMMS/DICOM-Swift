import Foundation

extension DCMDecoder {
    public var enhancedMultiframeFunctionalGroups: DicomEnhancedMultiframeFunctionalGroups? {
        synchronized {
            let sharedItems = parseFunctionalGroupItemsUnsafe(for: .sharedFunctionalGroupsSequence)
            let perFrameItems = parseFunctionalGroupItemsUnsafe(for: .perFrameFunctionalGroupsSequence)
            return DicomEnhancedMultiframeParser.makeFunctionalGroups(
                sharedItems: sharedItems,
                perFrameItems: perFrameItems,
                declaredFrameCount: max(1, nImages)
            )
        }
    }

    public func enhancedFrameGeometry(at index: Int) -> DicomFrameGeometry? {
        enhancedMultiframeFunctionalGroups?.geometry(forFrame: index)
    }

    private func parseFunctionalGroupItemsUnsafe(for tag: DicomTag) -> [DicomSequenceItem] {
        guard let metadata = tagMetadataCache[tag.rawValue],
              metadata.offset >= 0,
              metadata.elementLength >= 0,
              metadata.offset + metadata.elementLength <= dicomData.count else {
            return []
        }

        let syntax = DicomTransferSyntax(uid: transferSyntaxUID) ?? .explicitVRLittleEndian
        return (try? DicomSequenceValueParser.parseItems(
            in: dicomData,
            valueOffset: metadata.offset,
            valueLength: metadata.elementLength,
            littleEndian: littleEndian,
            explicitVR: syntax.isExplicitVR,
            characterSet: activeCharacterSet
        )) ?? []
    }
}
